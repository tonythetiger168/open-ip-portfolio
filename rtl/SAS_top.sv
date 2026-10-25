// SPDX-License-Identifier: Apache-2.0
// ============================================================================
// SAS protocol Open IP -- SAS initiator (OOB + SSP frame link layer)
// -- Apache-2.0
// Open IP design implementation v2.5
// ============================================================================
// Implementation scope:
//  - OOB FSM: COMRESET-style burst/idle pattern (106 symbol burst + 318 symbol
//    idle), COMINIT exchange detection, then PHY READY. A burst is detected
//    when at least 64 consecutive '1's end.
//  - Link layer: ALIGN idle primitive (32'h7B4A4ABC) inserted between frames,
//    1 bit per bit time, MSB-first per 32-bit dword, tx_n = ~tx_p.
//  - The receiver hunts SOF bit by bit (dword alignment) and then takes
//    whole dwords until EOF.
//  - SSP frame: SOF(32'hA5A50001) + HDR{len[31:24],type[23:16],dst[15:8],
//    src[7:0]} + PAYLOAD(len x 32-bit, len<=16) + CRC32 + EOF(32'hA5A50002).
//  - CRC32: poly 32'h04C11DB7 (reflected form 32'hEDB88320), init all-ones,
//    input/output reflected, final XOR all-ones (Ethernet FCS style),
//    processed one 32-bit dword per step over HDR + PAYLOAD.
//  - Functional unit: 16x32-bit register file. type 8'h01 = write,
//    8'h02 = read request, 8'h83 = read response (payload[0] = reg value).
//    Only payload dword 0 is used; further dwords are CRC-checked only.
//  - Built-in initiator sequencer (SAS address 8'h01) issues write /
//    read-verify transactions with pseudo-random data (xorshift32) so the
//    IP exercises itself over the loopback link; a read response must come
//    from the register just written and carry the written value.
//  - irq: 1-clk pulse on CRC error or protocol violation (oversize len,
//    bad EOF, unknown frame type, bad register address, missing payload,
//    link timeout).
//  NOTE: refclk is kept for interface compatibility; this simplified model
//  uses clk as the line bit clock and does not use refclk. rx_n is the
//  inverted companion of rx_p and is not used by the simplified receiver
//  (single-ended sampling on rx_p).
// ============================================================================
module SAS_top #(
  parameter int BIT_CLKS = 1   // clk cycles per serial bit (bit-rate divider)
)(
  input  logic           clk,
  input  logic           rst_n,
  output logic           tx_n,
  output logic           tx_p,
  input  logic           rx_n,
  input  logic           rx_p,
  input  logic           refclk,
  output logic           irq
);

  // ------------------------- constants -------------------------------------
  localparam logic [31:0] PRIM_ALIGN  = 32'h7B4A4ABC; // ALIGN idle primitive
  localparam logic [31:0] SSP_SOF     = 32'hA5A50001; // SSP frame SOF
  localparam logic [31:0] SSP_EOF     = 32'hA5A50002; // SSP frame EOF
  // OOB burst/idle timing is wall-clock (raw clk), intentionally not scaled
  // by BIT_CLKS: OOB signalling precedes any bit-rate-divided traffic.
  localparam int          OOB_BURST   = 106;          // COMRESET/COMINIT burst
  localparam int          OOB_IDLE    = 318;          // inter-burst idle
  localparam int          OOB_DET_MIN = 64;           // min burst run to detect
  localparam int          OCW         = $clog2(OOB_IDLE);
  localparam int          BRW         = $clog2(OOB_DET_MIN + 1);
  // Link timeout: counts bit-traffic latency, so it scales with BIT_CLKS.
  localparam int          SQ_TMO      = 512 * BIT_CLKS;
  localparam int          SQW         = $clog2(SQ_TMO + 1);
  localparam logic [7:0]  T_WRITE     = 8'h01;        // register write
  localparam logic [7:0]  T_RDREQ     = 8'h02;        // register read request
  localparam logic [7:0]  T_RDRSP     = 8'h83;        // register read response
  localparam logic [7:0]  MY_ADDR     = 8'h01;        // initiator SAS address

  // ------------------------- CRC32 (Ethernet FCS style) ---------------------
  // poly 04C11DB7 reflected -> EDB88320, init/xorout all-ones, per-dword step
  function automatic logic [31:0] crc32_dw(input logic [31:0] crc,
                                           input logic [31:0] dw);
    logic [31:0] c;
    begin
      c = crc;
      for (int b = 3; b >= 0; b--) begin          // dword bytes, MSB byte first
        for (int i = 0; i < 8; i++) begin         // LSB-first within byte
          if (c[0] ^ dw[b*8+i]) c = (c >> 1) ^ 32'hEDB88320;
          else                  c = (c >> 1);
        end
      end
      crc32_dw = c;
    end
  endfunction

  // ------------------------- OOB FSM ----------------------------------------
  typedef enum logic [2:0] {
    OB_CR_BURST, OB_CR_IDLE, OB_CI_BURST, OB_CI_IDLE, OB_DONE
  } oob_t;
  oob_t           oob_state;
  logic [OCW-1:0] oob_cnt;
  logic           cr_seen, ci_seen;
  logic           phy_ready;

  // RX burst-run monitor (used during OOB): run length saturates at the
  // detection threshold
  logic [BRW-1:0] brun;
  logic           oob_det;

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      brun    <= '0;
      oob_det <= 1'b0;
    end else begin
      oob_det <= !rx_p && (brun == BRW'(OOB_DET_MIN));
      if (!rx_p)                           brun <= '0;
      else if (brun != BRW'(OOB_DET_MIN))  brun <= brun + 1'b1;
    end
  end

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      oob_state <= OB_CR_BURST;
      oob_cnt   <= '0;
      cr_seen   <= 1'b0;
      ci_seen   <= 1'b0;
      phy_ready <= 1'b0;
    end else begin
      case (oob_state)
        OB_CR_BURST: begin                    // transmit COMRESET burst
          oob_cnt <= oob_cnt + 1'b1;
          if (oob_cnt == OCW'(OOB_BURST-1)) begin
            oob_cnt   <= '0;
            cr_seen   <= 1'b0;
            oob_state <= OB_CR_IDLE;
          end
        end
        OB_CR_IDLE: begin                     // idle, watch for COMINIT
          if (oob_det) cr_seen <= 1'b1;
          oob_cnt <= oob_cnt + 1'b1;
          if (oob_cnt == OCW'(OOB_IDLE-1)) begin
            oob_cnt   <= '0;
            oob_state <= (cr_seen || oob_det) ? OB_CI_BURST : OB_CR_BURST;
          end
        end
        OB_CI_BURST: begin                    // transmit COMINIT burst
          oob_cnt <= oob_cnt + 1'b1;
          if (oob_cnt == OCW'(OOB_BURST-1)) begin
            oob_cnt   <= '0;
            ci_seen   <= 1'b0;
            oob_state <= OB_CI_IDLE;
          end
        end
        OB_CI_IDLE: begin                     // idle, watch for COMINIT ack
          if (oob_det) ci_seen <= 1'b1;
          oob_cnt <= oob_cnt + 1'b1;
          if (oob_cnt == OCW'(OOB_IDLE-1)) begin
            oob_cnt <= '0;
            if (ci_seen || oob_det) begin
              oob_state <= OB_DONE;
              phy_ready <= 1'b1;
            end else oob_state <= OB_CI_BURST;
          end
        end
        default: ;                            // OB_DONE
      endcase
    end
  end

  // OOB line drive: constant burst pattern, idle otherwise
  wire oob_drive = (oob_state == OB_CR_BURST) || (oob_state == OB_CI_BURST);

  // ------------------------- TX link layer ----------------------------------
  // Bit-rate divider: per-bit shift/sample logic advances only on bit_tick.
  localparam int BCW = (BIT_CLKS <= 1) ? 1 : $clog2(BIT_CLKS);
  logic [BCW-1:0] bd_cnt;
  wire bit_tick = (BIT_CLKS <= 1) || (bd_cnt == BCW'(BIT_CLKS-1));
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n)          bd_cnt <= '0;
    else if (bit_tick)   bd_cnt <= '0;
    else                 bd_cnt <= bd_cnt + 1'b1;
  end

  typedef enum logic [2:0] {
    TS_ALIGN, TS_SOF, TS_HDR, TS_PAY, TS_CRC, TS_EOF
  } tx_t;
  // frame kinds the initiator sends
  localparam logic [1:0] K_WR = 2'd0, K_RQ = 2'd1, K_RS = 2'd2;
  tx_t         tx_state;
  logic [31:0] tx_shift;
  logic [4:0]  tx_bit_cnt;
  logic [1:0]  f_kind;
  logic [7:0]  f_dst;
  logic [3:0]  f_src;               // own address 1 or the register read
  logic [31:0] f_data;
  logic [31:0] crc_acc;

  // header dword of a frame kind
  function automatic logic [31:0] hdr(input logic [1:0] k, input logic [7:0] d,
                                      input logic [3:0] s);
    case (k)
      K_WR:    hdr = {8'd1, T_WRITE, d, 4'h0, s};
      K_RQ:    hdr = {8'd0, T_RDREQ, d, 4'h0, s};
      default: hdr = {8'd1, T_RDRSP, d, 4'h0, s};
    endcase
  endfunction

  // request from initiator sequencer
  logic        app_req, app_ack, app_rd;
  logic [3:0]  app_addr;
  logic [31:0] app_data;
  // request from RX target handler (read response)
  logic        rsp_req_set, rsp_pending;
  logic [7:0]  rsp_dst;
  logic [3:0]  rsp_src;
  logic [31:0] rsp_data;

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      tx_state    <= TS_ALIGN;
      tx_shift    <= PRIM_ALIGN;
      tx_bit_cnt  <= '0;
      f_kind      <= K_WR;
      f_dst       <= 8'd0;
      f_src       <= 4'd0;
      f_data      <= 32'd0;
      crc_acc     <= 32'd0;
      app_ack     <= 1'b0;
      rsp_pending <= 1'b0;
    end else if (!phy_ready) begin
      tx_state    <= TS_ALIGN;
      tx_shift    <= PRIM_ALIGN;
      tx_bit_cnt  <= '0;
    end else begin
      app_ack <= 1'b0;
      if (rsp_req_set) rsp_pending <= 1'b1;
      if (bit_tick) begin
        tx_bit_cnt <= tx_bit_cnt + 5'd1;
        tx_shift   <= {tx_shift[30:0], 1'b0};
        if (tx_bit_cnt == 5'd31) begin
          case (tx_state)
            TS_ALIGN: begin                     // idle primitive; take requests
              if (rsp_pending || rsp_req_set) begin
                f_kind   <= K_RS;
                f_dst    <= rsp_dst;
                f_src    <= rsp_src;
                f_data   <= rsp_data;
                rsp_pending <= 1'b0;
                tx_shift <= SSP_SOF;
                tx_state <= TS_SOF;
              end else if (app_req && !app_ack) begin
                f_kind   <= app_rd ? K_RQ : K_WR;
                f_dst    <= {4'd0, app_addr};
                f_src    <= MY_ADDR[3:0];
                f_data   <= app_data;
                app_ack  <= 1'b1;
                tx_shift <= SSP_SOF;
                tx_state <= TS_SOF;
              end else begin
                tx_shift <= PRIM_ALIGN;         // keep sending ALIGN
              end
            end
            TS_SOF: begin                       // SOF on wire -> load HEADER
              tx_shift <= hdr(f_kind, f_dst, f_src);
              crc_acc  <= crc32_dw(32'hFFFF_FFFF, hdr(f_kind, f_dst, f_src));
              tx_state <= TS_HDR;
            end
            TS_HDR: begin                       // HEADER on wire
              if (f_kind == K_RQ) begin
                tx_shift <= ~crc_acc;
                tx_state <= TS_CRC;
              end else begin
                tx_shift <= f_data;
                crc_acc  <= crc32_dw(crc_acc, f_data);
                tx_state <= TS_PAY;
              end
            end
            TS_PAY: begin                       // PAYLOAD on wire -> load CRC
              tx_shift <= ~crc_acc;
              tx_state <= TS_CRC;
            end
            TS_CRC: begin                       // CRC on wire -> load EOF
              tx_shift <= SSP_EOF;
              tx_state <= TS_EOF;
            end
            default: begin                      // TS_EOF on wire -> ALIGN
              tx_shift <= PRIM_ALIGN;
              tx_state <= TS_ALIGN;
            end
          endcase
        end
      end
    end
  end

  // serial line drive
  assign tx_p = rst_n && (phy_ready ? tx_shift[31] : oob_drive);   // idle in reset
  assign tx_n = ~tx_p;

  // ------------------------- RX link layer ----------------------------------
  typedef enum logic [2:0] {
    RS_IDLE, RS_HDR, RS_PAY, RS_CRC, RS_EOF
  } rx_t;
  rx_t         rx_state;
  logic [30:0] rx_sh;
  logic [4:0]  rx_bit_cnt;
  logic [31:0] rx_pay0;           // payload dword 0
  logic [4:0]  pay_idx;
  logic [4:0]  r_len;
  logic [7:0]  r_type, r_dst, r_src;
  logic [31:0] rcrc;
  logic        crc_ok_flag;

  // functional unit: 16x32-bit register file
  logic [31:0] regs [0:15];

  // event pulses
  logic        wr_evt;
  logic        rsp_evt;
  logic [31:0] rsp_val;
  logic [7:0]  rsp_from;
  logic        crc_err_pulse, proto_err_pulse;

  wire [31:0] rx_dw  = {rx_sh, rx_p};
  wire        dw_rdy = (rx_bit_cnt == 5'd31);

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      rx_state    <= RS_IDLE;
      rx_sh       <= '0;
      rx_bit_cnt  <= '0;
      pay_idx     <= '0;
      r_len       <= '0;
      r_type      <= '0;
      r_dst       <= '0;
      r_src       <= '0;
      rcrc        <= '0;
      rx_pay0     <= '0;
      crc_ok_flag <= 1'b0;
      wr_evt      <= 1'b0;
      rsp_evt     <= 1'b0;
      rsp_val     <= '0;
      rsp_from    <= '0;
      rsp_req_set <= 1'b0;
      rsp_dst     <= '0;
      rsp_src     <= '0;
      rsp_data    <= '0;
      crc_err_pulse   <= 1'b0;
      proto_err_pulse <= 1'b0;
      for (int k = 0; k < 16; k++) regs[k] <= 32'd0;
    end else if (!phy_ready) begin
      rx_state    <= RS_IDLE;
      rx_sh       <= '0;
    end else begin
      wr_evt          <= 1'b0;
      rsp_evt         <= 1'b0;
      rsp_req_set     <= 1'b0;
      crc_err_pulse   <= 1'b0;
      proto_err_pulse <= 1'b0;
      if (bit_tick) begin
        rx_bit_cnt <= rx_bit_cnt + 5'd1;
        rx_sh      <= rx_dw[30:0];
        case (rx_state)
          RS_IDLE: begin                        // hunt SOF on every bit
            if (rx_dw == SSP_SOF) begin
              rx_state   <= RS_HDR;
              rx_bit_cnt <= '0;
            end
          end
          RS_HDR: if (dw_rdy) begin
            // clamp the stored length; a violation drops the frame
            r_len  <= rx_dw[28:24];
            r_type <= rx_dw[23:16];
            r_dst  <= rx_dw[15:8];
            r_src  <= rx_dw[7:0];
            rcrc   <= crc32_dw(32'hFFFF_FFFF, rx_dw);
            pay_idx <= '0;
            if (rx_dw[31:24] > 8'd16) begin     // len violation
              proto_err_pulse <= 1'b1;
              rx_state        <= RS_IDLE;
            end else if (rx_dw[31:24] == 8'd0) rx_state <= RS_CRC;
            else                               rx_state <= RS_PAY;
          end
          RS_PAY: if (dw_rdy) begin
            if (pay_idx == 5'd0) rx_pay0 <= rx_dw;
            rcrc    <= crc32_dw(rcrc, rx_dw);
            pay_idx <= pay_idx + 5'd1;
            if (pay_idx == r_len - 5'd1) rx_state <= RS_CRC;
          end
          RS_CRC: if (dw_rdy) begin
            crc_ok_flag <= (rx_dw == ~rcrc);
            if (rx_dw != ~rcrc) crc_err_pulse <= 1'b1;   // bad frame: discard
            rx_state <= RS_EOF;
          end
          default: if (dw_rdy) begin            // RS_EOF: act on a good frame
            rx_state <= RS_IDLE;
            if (crc_ok_flag) begin
              if (rx_dw != SSP_EOF) proto_err_pulse <= 1'b1;
              else case (r_type)
                T_WRITE: begin                  // register write
                  if (r_len != 5'd0 && r_dst < 8'd16) begin
                    regs[r_dst[3:0]] <= rx_pay0;
                    wr_evt           <= 1'b1;
                  end else proto_err_pulse <= 1'b1;
                end
                T_RDREQ: begin                  // register read request
                  if (r_dst < 8'd16) begin
                    rsp_req_set <= 1'b1;        // queue read response frame
                    rsp_dst     <= r_src;
                    rsp_src     <= r_dst[3:0];
                    rsp_data    <= regs[r_dst[3:0]];
                  end else proto_err_pulse <= 1'b1;
                end
                T_RDRSP: begin                  // read response
                  if (r_len != 5'd0) begin
                    rsp_evt  <= 1'b1;
                    rsp_val  <= rx_pay0;
                    rsp_from <= r_src;
                  end else proto_err_pulse <= 1'b1;
                end
                default: proto_err_pulse <= 1'b1; // unknown frame type
              endcase
            end
          end
        endcase
      end
    end
  end

  // ------------------------- initiator sequencer -----------------------------
  typedef enum logic [2:0] {
    SQ_INIT, SQ_WR, SQ_WR_WAIT, SQ_RD, SQ_RD_WAIT, SQ_GAP
  } sq_t;
  sq_t            sq_state;
  logic [SQW-1:0] sq_tmo;
  // inter-transaction gap in raw clks (wall-clock pacing, not scaled)
  logic [5:0]     gap_cnt;
  logic [3:0]     sq_addr;
  logic [31:0]    sq_wdata;
  logic [7:0]     ok_cnt, mm_cnt;   // verified / mismatching read-backs
  logic           tmo_err_pulse;

  function automatic logic [31:0] xs32(input logic [31:0] x);
    logic [31:0] y;
    y = x ^ (x << 13);
    y = y ^ (y >> 17);
    xs32 = y ^ (y << 5);
  endfunction

  assign app_req = (sq_state == SQ_WR) || (sq_state == SQ_RD);
  assign app_rd  = (sq_state == SQ_RD);
  assign app_addr = sq_addr;
  assign app_data = sq_wdata;

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      sq_state      <= SQ_INIT;
      sq_tmo        <= '0;
      gap_cnt       <= 6'd0;
      sq_addr       <= 4'd0;
      sq_wdata      <= 32'h5A5A_C3C3;
      ok_cnt        <= 8'd0;
      mm_cnt        <= 8'd0;
      tmo_err_pulse <= 1'b0;
    end else begin
      tmo_err_pulse <= 1'b0;
      case (sq_state)
        SQ_INIT: begin
          if (phy_ready) begin
            gap_cnt <= gap_cnt + 6'd1;
            if (gap_cnt == 6'd63) sq_state <= SQ_WR;
          end
        end
        SQ_WR: if (app_ack) begin             // write frame taken
          sq_tmo   <= '0;
          sq_state <= SQ_WR_WAIT;
        end
        SQ_WR_WAIT: begin                     // wait for looped-back write
          sq_tmo <= sq_tmo + 1'b1;
          if (wr_evt) sq_state <= SQ_RD;
          else if (sq_tmo == SQW'(SQ_TMO)) begin
            tmo_err_pulse <= 1'b1;
            sq_state      <= SQ_RD;
          end
        end
        SQ_RD: if (app_ack) begin             // read request taken
          sq_tmo   <= '0;
          sq_state <= SQ_RD_WAIT;
        end
        SQ_RD_WAIT: begin                     // verify read response
          sq_tmo <= sq_tmo + 1'b1;
          if (rsp_evt || sq_tmo == SQW'(SQ_TMO)) begin
            if (!rsp_evt)
              tmo_err_pulse <= 1'b1;
            else if (rsp_val == sq_wdata && rsp_from == {4'd0, sq_addr})
              ok_cnt <= ok_cnt + 8'd1;
            else
              mm_cnt <= mm_cnt + 8'd1;
            sq_wdata <= xs32(sq_wdata);
            sq_addr  <= sq_addr + 4'd1;
            gap_cnt  <= 6'd0;
            sq_state <= SQ_GAP;
          end
        end
        default: begin                        // SQ_GAP: inter-transaction gap
          gap_cnt <= gap_cnt + 6'd1;
          if (gap_cnt == 6'd31) sq_state <= SQ_WR;
        end
      endcase
    end
  end

  // ------------------------- interrupt ---------------------------------------
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) irq <= 1'b0;
    else        irq <= crc_err_pulse | proto_err_pulse | tmo_err_pulse;
  end

  wire _unused = &{1'b0, rx_n, refclk, ok_cnt, mm_cnt};

endmodule
