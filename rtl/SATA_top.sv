// SPDX-License-Identifier: Apache-2.0
// ============================================================================
// SATA protocol Open IP -- SATA host: OOB bring-up (COMRESET / COMINIT /
// COMWAKE burst-idle patterns + ALIGNp) and FIS transport (SOFp .. CRC32 ..
// EOFp). Implements Register H2D commands IDENTIFY (8'hEC), READ DMA EXT
// (8'h25) and WRITE DMA EXT (8'h35) against an internal 64x32-bit sector
// buffer. In loopback the DUT plays host and device simultaneously.
// -- Apache-2.0
// Open IP design implementation v2.4
//
// Simplifications (per SPEC):
//  * refclk is kept for interface compatibility only; the line symbol rate is
//    1 bit per clk and all logic runs on clk.
//  * OOB signalling is modelled as burst/idle count patterns on tx_p/rx_p:
//      COMRESET / COMINIT : 2 x ( 64 clk low burst + 192 clk high idle )
//      COMWAKE            : 2 x ( 16 clk low burst +  48 clk high idle )
//    The receiver counts consecutive low symbols: >=48 -> long burst,
//    8..47 -> short burst; two equal bursts in a row raise the detect event.
//  * Host command interface (the port contract has no bus): internal
//    hold-registers host_req / host_cmd / host_lba / hw0..hw3 are poked from
//    TB via hierarchical references (same observability model as eMMC IP).
// ============================================================================
module SATA_top #(
  parameter int DW = 32,       // data width (contract, unused internally)
  parameter int AW = 32,       // address width (contract, unused internally)
  parameter int BIT_CLKS = 1   // clk cycles per serial bit (bit-rate divider)
)(
  input  logic           clk,
  input  logic           rst_n,
  output logic           tx_n,
  output logic           tx_p,
  input  logic           rx_n,   // kept for contract; rx_p carries the data
  input  logic           rx_p,
  input  logic           refclk, // kept for contract; line clock = clk
  output logic           irq
);
  // ------------------------- protocol constants -------------------------
  localparam logic [31:0] PRIM_SOF    = 32'h3737_B57C; // SOFp
  localparam logic [31:0] PRIM_EOF    = 32'hD5D5_B57C; // EOFp
  localparam logic [31:0] PRIM_ALIGN  = 32'h7B4A_4ABC; // ALIGNp
  localparam logic [7:0]  FIS_REG_H2D = 8'h27;
  localparam logic [7:0]  FIS_REG_D2H = 8'h34;
  localparam logic [7:0]  FIS_DATA    = 8'h46;
  localparam logic [7:0]  CMD_IDENTIFY   = 8'hEC;
  localparam logic [7:0]  CMD_READ_DMA   = 8'h25;
  localparam logic [7:0]  CMD_WRITE_DMA  = 8'h35;

  // Bit-traffic timeouts: they must cover frame round-trips at the divided
  // bit rate, so they scale with BIT_CLKS.  BIT_CLKS=1 keeps the legacy
  // values (5000 / 2000) and 14/12-bit counter widths.
  localparam int HS_TMO = 5000 * BIT_CLKS;  // HF_WAIT response timeout (clks)
  localparam int HSW    = 14 + ((BIT_CLKS > 1) ? $clog2(BIT_CLKS) : 0);
  localparam int DS_TMO = 2000 * BIT_CLKS;  // DF_WDAT data timeout (clks)
  localparam int DSW    = 12 + ((BIT_CLKS > 1) ? $clog2(BIT_CLKS) : 0);

  // CRC32: poly 32'h04C11DB7 (reflected 32'hEDB88320), init all-ones,
  // input/output reflected, final XOR all-ones (Ethernet FCS flavour).
  function automatic logic [31:0] crc32_dw(input logic [31:0] c,
                                           input logic [31:0] d);
    logic [31:0] r;
    logic        fb;
    begin
      r = c;
      for (int k = 0; k < 32; k++) begin
        fb = r[0] ^ d[k];
        r  = {1'b0, r[31:1]};
        if (fb) r = r ^ 32'hEDB8_8320;
      end
      crc32_dw = r;
    end
  endfunction

  // fixed IDENTIFY device info, dword i (0..15)
  function automatic logic [31:0] ident_dw(input logic [4:0] i);
    ident_dw = {8'hEC, 8'h5A, {3'b000, i}, ~{3'b000, i}};
  endfunction

  // ------------------------- host command hold-regs -------------------------
  // Driven only from TB (hierarchical poke); the self-assign keeps them as
  // real registers so the host datapath survives synthesis optimization.
  logic        host_req;
  logic [7:0]  host_cmd;
  logic [5:0]  host_lba;
  logic [31:0] hw0, hw1, hw2, hw3;

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      host_req <= 1'b0; host_cmd <= 8'h00; host_lba <= 6'd0;
      hw0 <= 32'h0; hw1 <= 32'h0; hw2 <= 32'h0; hw3 <= 32'h0;
    end else begin
      host_req <= host_req; host_cmd <= host_cmd; host_lba <= host_lba;
      hw0 <= hw0; hw1 <= hw1; hw2 <= hw2; hw3 <= hw3;
    end
  end

  // ------------------------- OOB pattern transmitters -------------------------
  logic htx_req, htx_long, h_oob_act, h_oob_bit, h_oob_done;
  logic dtx_req, dtx_long, d_oob_act, d_oob_bit, d_oob_done;

  sata_oob_tx u_host_oob (
    .clk(clk), .rst_n(rst_n), .req(htx_req), .long_pat(htx_long),
    .act(h_oob_act), .bit_o(h_oob_bit), .done(h_oob_done)
  );
  sata_oob_tx u_dev_oob (
    .clk(clk), .rst_n(rst_n), .req(dtx_req), .long_pat(dtx_long),
    .act(d_oob_act), .bit_o(d_oob_bit), .done(d_oob_done)
  );

  // ------------------------- OOB burst detector (RX) -------------------------
  // zrun counts raw clk cycles: wall-clock OOB timing, intentionally not
  // scaled by BIT_CLKS (OOB burst runs are clk-domain, not bit-domain).
  logic [7:0] zrun;
  logic [1:0] longs, shorts;
  logic       det_long, det_short;
  logic       link_ready;

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      zrun <= 8'd0; longs <= 2'd0; shorts <= 2'd0;
      det_long <= 1'b0; det_short <= 1'b0;
    end else begin
      det_long  <= 1'b0;
      det_short <= 1'b0;
      if (link_ready) begin
        zrun <= 8'd0; longs <= 2'd0; shorts <= 2'd0;
      end else if (rx_p == 1'b0) begin
        zrun <= (zrun == 8'd255) ? 8'd255 : zrun + 8'd1;
      end else begin
        if (zrun >= 8'd48) begin
          if (longs == 2'd1) begin det_long <= 1'b1; longs <= 2'd0; end
          else                      longs <= longs + 2'd1;
          shorts <= 2'd0;
        end else if (zrun >= 8'd8) begin
          if (shorts == 2'd1) begin det_short <= 1'b1; shorts <= 2'd0; end
          else                       shorts <= shorts + 2'd1;
          longs <= 2'd0;
        end
        // short gaps (idle between bursts) must NOT clear the burst counters
        zrun <= 8'd0;
      end
    end
  end

  // ------------------------- host OOB FSM -------------------------
  typedef enum logic [2:0] {
    HOB_RESET, HOB_WAITINIT, HOB_WAKEWAIT, HOB_WAKE, HOB_WAITWAKE,
    HOB_ALIGN, HOB_LINK
  } hob_t;
  hob_t       hstate;
  // OOB retry timer: wall-clock OOB timing, intentionally not scaled by
  // BIT_CLKS (OOB signalling precedes any bit-rate-divided traffic).
  logic [13:0] htmr;
  logic [2:0]  align_cnt;
  logic [31:0] align_sr;
  logic [5:0]  align_bitcnt;
  logic        align_active;

  assign align_active = (hstate == HOB_ALIGN) || link_ready;

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      hstate <= HOB_RESET; htx_req <= 1'b0; htx_long <= 1'b1;
      htmr <= 14'd0; align_cnt <= 3'd0; link_ready <= 1'b0;
    end else begin
      case (hstate)
        HOB_RESET: begin
          htx_req  <= 1'b1;
          htx_long <= 1'b1;                    // COMRESET: long pattern
          if (h_oob_done) begin
            htx_req <= 1'b0;
            hstate  <= HOB_WAITINIT;
            htmr    <= 14'd0;
          end
        end
        HOB_WAITINIT: begin
          htmr <= htmr + 14'd1;
          if (det_long) begin
            hstate <= HOB_WAKEWAIT;           // COMINIT detected
            htmr   <= 14'd0;
          end else if (htmr == 14'd8000) hstate <= HOB_RESET;   // retry
        end
        HOB_WAKEWAIT: begin
          // wait until the device COMINIT pattern has left the wire
          htmr <= htmr + 14'd1;
          if (!d_oob_act)           hstate <= HOB_WAKE;
          else if (htmr == 14'd8000) hstate <= HOB_RESET;
        end
        HOB_WAKE: begin
          htx_req  <= 1'b1;
          htx_long <= 1'b0;                    // COMWAKE: short pattern
          if (h_oob_done) begin
            htx_req <= 1'b0;
            hstate  <= HOB_WAITWAKE;
            htmr    <= 14'd0;
          end
        end
        HOB_WAITWAKE: begin
          htmr <= htmr + 14'd1;
          if (det_short) begin
            hstate    <= HOB_ALIGN;           // COMWAKE echo detected
            align_cnt <= 3'd0;
          end else if (htmr == 14'd8000) hstate <= HOB_RESET;
        end
        HOB_ALIGN: begin
          // send ALIGNp dwords; receiver locks onto the stream meanwhile
          if (align_bitcnt == 6'd31) begin
            if (align_cnt == 3'd7) begin
              link_ready <= 1'b1;
              hstate     <= HOB_LINK;
            end else align_cnt <= align_cnt + 3'd1;
          end
        end
        HOB_LINK: ; // stay; ALIGNp stream keeps running between frames
        default: hstate <= HOB_RESET;
      endcase
    end
  end

  // ------------------------- device OOB responder -------------------------
  typedef enum logic [2:0] {
    DOB_IDLE, DOB_INITWAIT, DOB_INIT, DOB_WAITWAKE, DOB_ECHOWAIT, DOB_ECHO,
    DOB_DONE
  } dob_t;
  dob_t dstate;

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      dstate <= DOB_IDLE; dtx_req <= 1'b0; dtx_long <= 1'b1;
    end else begin
      case (dstate)
        DOB_IDLE:     if (det_long) dstate <= DOB_INITWAIT;  // saw COMRESET
        DOB_INITWAIT: if (!h_oob_act) begin                  // wait line free
                        dtx_req  <= 1'b1;
                        dtx_long <= 1'b1;                    // answer COMINIT
                        dstate   <= DOB_INIT;
                      end
        DOB_INIT:     if (d_oob_done) begin
                        dtx_req <= 1'b0;
                        dstate  <= DOB_WAITWAKE;
                      end
        DOB_WAITWAKE: if (det_short) dstate <= DOB_ECHOWAIT; // saw COMWAKE
        DOB_ECHOWAIT: if (!h_oob_act) begin
                        dtx_req  <= 1'b1;
                        dtx_long <= 1'b0;                    // echo COMWAKE
                        dstate   <= DOB_ECHO;
                      end
        DOB_ECHO:     if (d_oob_done) begin
                        dtx_req <= 1'b0;
                        dstate  <= DOB_DONE;
                      end
        DOB_DONE:     ;
        default: dstate <= DOB_IDLE;
      endcase
    end
  end

  // ------------------------- ALIGNp stream shifter -------------------------
  // Bit-rate divider: per-bit shift/sample logic advances only on bit_tick.
  // BIT_CLKS=1 keeps the legacy 1-bit-per-clk behavior (bit_tick constant 1).
  localparam int BCW = (BIT_CLKS <= 1) ? 1 : $clog2(BIT_CLKS);
  logic [BCW-1:0] bd_cnt;
  wire bit_tick = (BIT_CLKS <= 1) || (bd_cnt == BIT_CLKS-1);
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n)          bd_cnt <= '0;
    else if (bit_tick)   bd_cnt <= '0;
    else                 bd_cnt <= bd_cnt + 1'b1;
  end

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      align_sr <= PRIM_ALIGN; align_bitcnt <= 6'd0;
    end else if (!align_active) begin
      align_sr <= PRIM_ALIGN; align_bitcnt <= 6'd0;
    end else if (bit_tick) begin
      align_sr     <= {align_sr[0], align_sr[31:1]};  // LSB-first rotate
      align_bitcnt <= (align_bitcnt == 6'd31) ? 6'd0 : align_bitcnt + 6'd1;
    end
  end

  // ------------------------- frame TX engine -------------------------
  logic        tx_busy, tx_src_host;
  logic [2:0]  tx_widx;
  logic [5:0]  tx_bitcnt;
  logic [31:0] tshift, tcrc;
  logic [31:0] tbuf [0:4];
  logic        tx_accept, tx_accept_host;
  logic        tx_done,   tx_done_host;
  logic        h_pend, d_pend;
  logic [31:0] hframe [0:4];
  logic [31:0] dframe [0:4];

  wire tx_start = align_active && link_ready && !tx_busy &&
                  (align_bitcnt == 6'd31) && (h_pend || d_pend);

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      tx_busy <= 1'b0; tx_src_host <= 1'b0;
      tx_widx <= 3'd0; tx_bitcnt <= 6'd0;
      tshift <= 32'h0; tcrc <= 32'h0;
      tx_accept <= 1'b0; tx_accept_host <= 1'b0;
      tx_done <= 1'b0;   tx_done_host <= 1'b0;
      for (int i = 0; i < 5; i++) tbuf[i] <= 32'h0;
    end else begin
      tx_accept <= 1'b0;
      tx_done   <= 1'b0;
      if (!tx_busy) begin
        if (tx_start) begin
          tx_busy        <= 1'b1;
          tx_src_host    <= h_pend;
          tx_accept      <= 1'b1;
          tx_accept_host <= h_pend;
          tshift         <= PRIM_SOF;
          tcrc           <= 32'hFFFF_FFFF;
          tx_widx        <= 3'd0;
          tx_bitcnt      <= 6'd0;
          if (h_pend) for (int i = 0; i < 5; i++) tbuf[i] <= hframe[i];
          else        for (int i = 0; i < 5; i++) tbuf[i] <= dframe[i];
        end
      end else begin
        if (bit_tick) begin
        tshift <= {1'b0, tshift[31:1]};             // LSB first
        if (tx_bitcnt == 6'd31) begin
          tx_bitcnt <= 6'd0;
          case (tx_widx)
            3'd0, 3'd1, 3'd2, 3'd3, 3'd4: begin
              tshift  <= tbuf[tx_widx];
              tcrc    <= crc32_dw(tcrc, tbuf[tx_widx]);
              tx_widx <= tx_widx + 3'd1;
            end
            3'd5: begin tshift <= ~tcrc;    tx_widx <= 3'd6; end
            3'd6: begin tshift <= PRIM_EOF; tx_widx <= 3'd7; end
            default: begin
              tx_busy      <= 1'b0;
              tx_done      <= 1'b1;
              tx_done_host <= tx_src_host;
            end
          endcase
        end else tx_bitcnt <= tx_bitcnt + 6'd1;
        end // bit_tick
      end
    end
  end

  // ------------------------- frame RX engine -------------------------
  typedef enum logic [1:0] {XW_HUNT, XW_DATA, XW_CRC, XW_EOF} rxw_t;
  rxw_t        rxw;
  logic [31:0] rshift;
  logic [5:0]  rbitcnt;
  logic        aligned;
  logic [2:0]  wcnt;
  // NOTE: plain scalars instead of an array -- iverilog mis-evaluates
  // mid-word part-selects of memory words (e.g. rbuf[0][23:16]).
  logic [31:0] rb0, rb1, rb2, rb3, rb4;
  logic [31:0] rcrc;
  logic        frm_ok, frm_valid, rx_err;

  wire [31:0] dwd = {rx_p, rshift[31:1]};   // dword completing this cycle

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      rshift <= 32'h0; rbitcnt <= 6'd0; aligned <= 1'b0;
      rxw <= XW_HUNT; wcnt <= 3'd0; rcrc <= 32'h0;
      frm_ok <= 1'b0; frm_valid <= 1'b0; rx_err <= 1'b0;
      rb0 <= 32'h0; rb1 <= 32'h0; rb2 <= 32'h0; rb3 <= 32'h0; rb4 <= 32'h0;
    end else begin
      frm_valid <= 1'b0;
      rx_err    <= 1'b0;
      if (bit_tick) begin
      rshift    <= dwd;
      if (!aligned) begin
        // lock onto the ALIGNp training stream (SATA-style word sync)
        if (dwd == PRIM_ALIGN) begin
          aligned <= 1'b1; rbitcnt <= 6'd0; rxw <= XW_HUNT;
        end
      end else if (rbitcnt == 6'd31) begin
        rbitcnt <= 6'd0;
        case (rxw)
          XW_HUNT: begin
            if (dwd == PRIM_SOF) begin
              rxw  <= XW_DATA;
              wcnt <= 3'd0;
              rcrc <= 32'hFFFF_FFFF;
            end else if (dwd != PRIM_ALIGN) begin
              rx_err <= 1'b1;               // illegal primitive on the wire
            end
          end
          XW_DATA: begin
            case (wcnt)
              3'd0:    rb0 <= dwd;
              3'd1:    rb1 <= dwd;
              3'd2:    rb2 <= dwd;
              3'd3:    rb3 <= dwd;
              default: rb4 <= dwd;
            endcase
            rcrc <= crc32_dw(rcrc, dwd);
            if (wcnt == 3'd4) rxw <= XW_CRC;
            else              wcnt <= wcnt + 3'd1;
          end
          XW_CRC: begin
            if (dwd == ~rcrc) frm_ok <= 1'b1;
            else begin
              frm_ok <= 1'b0;
              rx_err <= 1'b1;               // CRC mismatch: frame dropped
            end
            rxw <= XW_EOF;
          end
          default: begin // XW_EOF
            if (dwd != PRIM_EOF) rx_err <= 1'b1;
            else if (frm_ok) begin
              frm_valid <= 1'b1;
              if (rb0[7:0] != FIS_REG_H2D &&
                  rb0[7:0] != FIS_REG_D2H &&
                  rb0[7:0] != FIS_DATA) rx_err <= 1'b1; // unknown FIS type
            end
            rxw    <= XW_HUNT;
            frm_ok <= 1'b0;
          end
        endcase
      end else rbitcnt <= rbitcnt + 6'd1;
      end // bit_tick
    end
  end

  // ------------------------- host command FSM -------------------------
  typedef enum logic [2:0] {HF_IDLE, HF_CMD, HF_WDAT, HF_WAIT, HF_DONE} hf_t;
  hf_t        hfstate;
  logic [7:0]  hcmd_r;
  logic [HSW-1:0] hstmr;
  logic        haccept;
  logic        host_done, host_errf;
  logic [7:0]  host_status;

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      hfstate <= HF_IDLE; h_pend <= 1'b0; haccept <= 1'b0;
      hcmd_r <= 8'h00; hstmr <= '0;
      host_done <= 1'b0; host_errf <= 1'b0; host_status <= 8'h00;
      for (int i = 0; i < 5; i++) hframe[i] <= 32'h0;
    end else begin
      haccept <= 1'b0;
      if (tx_accept && tx_accept_host) h_pend <= 1'b0;
      case (hfstate)
        HF_IDLE: if (host_req && link_ready) begin
          hcmd_r    <= host_cmd;
          hframe[0] <= {1'b1, 7'h00, host_cmd, 8'h00, FIS_REG_H2D};
          hframe[1] <= {16'h0000, 2'b00, host_lba, 8'd4};
          hframe[2] <= 32'h0; hframe[3] <= 32'h0; hframe[4] <= 32'h0;
          h_pend    <= 1'b1;
          haccept   <= 1'b1;
          host_errf <= 1'b0;
          hfstate   <= HF_CMD;
        end
        HF_CMD: if (tx_done && tx_done_host) begin
          if (hcmd_r == CMD_WRITE_DMA) begin
            hframe[0] <= {1'b0, 15'h0000, 8'h00, FIS_DATA}; // H2D data FIS
            hframe[1] <= hw0; hframe[2] <= hw1;
            hframe[3] <= hw2; hframe[4] <= hw3;
            h_pend  <= 1'b1;
            hfstate <= HF_WDAT;
          end else begin
            hfstate <= HF_WAIT;
            hstmr   <= '0;
          end
        end
        HF_WDAT: if (tx_done && tx_done_host) begin
          hfstate <= HF_WAIT;
          hstmr   <= '0;
        end
        HF_WAIT: begin
          hstmr <= hstmr + 1'b1;
          if (frm_valid && rb0[7:0] == FIS_REG_D2H) begin
            host_status <= rb0[23:16];
            host_errf   <= |rb0[31:24];
            host_done   <= 1'b1;
            hfstate     <= HF_DONE;
          end else if (hstmr == HS_TMO[HSW-1:0]) begin
            host_status <= 8'h7F;                 // timeout status
            host_errf   <= 1'b1;
            host_done   <= 1'b1;
            hfstate     <= HF_DONE;
          end
        end
        HF_DONE: if (!host_req) begin
          host_done <= 1'b0;
          hfstate   <= HF_IDLE;
        end
        default: hfstate <= HF_IDLE;
      endcase
    end
  end

  // ------------------------- host D2H data capture -------------------------
  logic        hseen;        // 1-clk pulse: a D2H data FIS was stored
  logic [7:0]  hseq;         // sequence number of that frame
  logic [5:0]  hnd;          // total dwords captured for current command
  logic [31:0] hrd0, hrd1, hrd2, hrd3;

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      hseen <= 1'b0; hseq <= 8'h00; hnd <= 6'd0;
      hrd0 <= 32'h0; hrd1 <= 32'h0; hrd2 <= 32'h0; hrd3 <= 32'h0;
    end else begin
      hseen <= 1'b0;
      if (haccept) hnd <= 6'd0;
      else if (frm_valid && rb0[7:0] == FIS_DATA && rb0[31]) begin
        hseen <= 1'b1;
        hseq  <= rb0[15:8];   // seq byte of data FIS dw0
        hnd   <= hnd + 6'd4;
        hrd0  <= rb1; hrd1 <= rb2;
        hrd2  <= rb3; hrd3 <= rb4;
      end
    end
  end

  // ------------------------- device command FSM + sector buffer -------------------------
  typedef enum logic [3:0] {
    DF_IDLE, DF_ID_SET, DF_ID_WAIT, DF_RD_SET, DF_RD_WAIT, DF_WDAT,
    DF_STS_SET, DF_STS_WAIT
  } df_t;
  df_t        dfstate;
  logic [1:0]  dseq;
  logic [5:0]  dlba;
  logic        dsts_err;
  logic [DSW-1:0] dtmr;
  logic        e_proto;
  logic [31:0] sector_buf [0:63];

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      dfstate <= DF_IDLE; d_pend <= 1'b0;
      dseq <= 2'd0; dlba <= 6'd0; dsts_err <= 1'b0; dtmr <= '0;
      e_proto <= 1'b0;
      for (int i = 0; i < 5; i++) dframe[i] <= 32'h0;
    end else begin
      e_proto <= 1'b0;
      if (tx_accept && !tx_accept_host) d_pend <= 1'b0;
      // H2D data FIS when no write is in progress -> protocol violation
      if (frm_valid && rb0[7:0] == FIS_DATA && !rb0[31] &&
          dfstate != DF_WDAT) e_proto <= 1'b1;
      case (dfstate)
        DF_IDLE: if (frm_valid && rb0[7:0] == FIS_REG_H2D) begin
          dlba <= rb1[13:8];
          case (rb0[23:16])
            CMD_IDENTIFY:  begin dseq <= 2'd0; dfstate <= DF_ID_SET; end
            CMD_READ_DMA:  dfstate <= DF_RD_SET;
            CMD_WRITE_DMA: begin dtmr <= '0; dfstate <= DF_WDAT; end
            default:       begin dsts_err <= 1'b1; dfstate <= DF_STS_SET; end
          endcase
        end
        DF_ID_SET: begin
          dframe[0] <= {1'b1, 15'h0000, {6'b000000, dseq}, FIS_DATA};
          dframe[1] <= ident_dw({dseq, 2'b00});
          dframe[2] <= ident_dw({dseq, 2'b01});
          dframe[3] <= ident_dw({dseq, 2'b10});
          dframe[4] <= ident_dw({dseq, 2'b11});
          d_pend  <= 1'b1;
          dfstate <= DF_ID_WAIT;
        end
        DF_ID_WAIT: if (tx_done && !tx_done_host) begin
          if (dseq == 2'd3) begin
            dsts_err <= 1'b0;
            dfstate  <= DF_STS_SET;
          end else begin
            dseq    <= dseq + 2'd1;
            dfstate <= DF_ID_SET;
          end
        end
        DF_RD_SET: begin
          dframe[0] <= {1'b1, 15'h0000, 8'h00, FIS_DATA};
          dframe[1] <= sector_buf[dlba];
          dframe[2] <= sector_buf[dlba + 6'd1];
          dframe[3] <= sector_buf[dlba + 6'd2];
          dframe[4] <= sector_buf[dlba + 6'd3];
          d_pend  <= 1'b1;
          dfstate <= DF_RD_WAIT;
        end
        DF_RD_WAIT: if (tx_done && !tx_done_host) begin
          dsts_err <= 1'b0;
          dfstate  <= DF_STS_SET;
        end
        DF_WDAT: begin
          dtmr <= dtmr + 1'b1;
          if (frm_valid && rb0[7:0] == FIS_DATA && !rb0[31]) begin
            sector_buf[dlba]        <= rb1;
            sector_buf[dlba + 6'd1] <= rb2;
            sector_buf[dlba + 6'd2] <= rb3;
            sector_buf[dlba + 6'd3] <= rb4;
            dsts_err <= 1'b0;
            dfstate  <= DF_STS_SET;
          end else if (dtmr == DS_TMO[DSW-1:0]) dfstate <= DF_IDLE;
        end
        DF_STS_SET: begin
          dframe[0] <= {dsts_err ? 8'h04 : 8'h00,
                        dsts_err ? 8'h51 : 8'h50, 8'h00, FIS_REG_D2H};
          dframe[1] <= 32'h0; dframe[2] <= 32'h0;
          dframe[3] <= 32'h0; dframe[4] <= 32'h0;
          d_pend  <= 1'b1;
          dfstate <= DF_STS_WAIT;
        end
        DF_STS_WAIT: if (tx_done && !tx_done_host) dfstate <= DF_IDLE;
        default: dfstate <= DF_IDLE;
      endcase
    end
  end

  // ------------------------- irq + line driver -------------------------
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) irq <= 1'b0;
    else        irq <= rx_err | e_proto;
  end

  wire line_bit = h_oob_act   ? h_oob_bit  :
                  d_oob_act   ? d_oob_bit  :
                  align_active ? (tx_busy ? tshift[0] : align_sr[0]) :
                                 1'b1;
  assign tx_p = line_bit;
  assign tx_n = ~line_bit;

endmodule

// ============================================================================
// OOB burst/idle pattern transmitter: 2 repetitions of (low burst, high idle)
// COMRESET/COMINIT use the long pattern, COMWAKE the short pattern.
// ============================================================================
module sata_oob_tx (
  input  logic clk,
  input  logic rst_n,
  input  logic req,
  input  logic long_pat,
  output logic act,
  output logic bit_o,
  output logic done
);
  localparam logic [7:0] LONG_B  = 8'd64;
  localparam logic [7:0] LONG_I  = 8'd192;
  localparam logic [7:0] SHORT_B = 8'd16;
  localparam logic [7:0] SHORT_I = 8'd48;

  logic [7:0] cnt;
  logic       phase;  // 0 = burst (low), 1 = idle (high)
  logic       rep;
  logic       long_q;
  logic [7:0] limit;

  always_comb begin
    if (long_q) limit = phase ? LONG_I  : LONG_B;
    else        limit = phase ? SHORT_I : SHORT_B;
  end

  assign bit_o = act ? (phase ? 1'b1 : 1'b0) : 1'b1;

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      act <= 1'b0; done <= 1'b0;
      cnt <= 8'd0; phase <= 1'b0; rep <= 1'b0; long_q <= 1'b0;
    end else begin
      if (!req) begin
        act <= 1'b0; done <= 1'b0;
      end else if (!act && !done) begin
        act    <= 1'b1;
        cnt    <= 8'd0;
        phase  <= 1'b0;
        rep    <= 1'b0;
        long_q <= long_pat;
      end else if (act) begin
        if (cnt == limit - 8'd1) begin
          cnt <= 8'd0;
          if (!phase) phase <= 1'b1;
          else begin
            phase <= 1'b0;
            if (rep) begin
              act  <= 1'b0;
              done <= 1'b1;
            end else rep <= 1'b1;
          end
        end else cnt <= cnt + 8'd1;
      end
    end
  end
endmodule
