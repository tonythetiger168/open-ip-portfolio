// SPDX-License-Identifier: Apache-2.0
// ============================================================================
// SAS-4 (Serial Attached SCSI, 24G) -- 128b/150b-style block-coded link layer
// initiator IP.  Distinct from SAS_top (v1.7 NRZ + dword link): this core
// implements a 128b/150b-style block code and a self-synchronous scrambler.
//
// Implementation scope (simplified, NOT the full SPL specification):
//  - Block code: 2-bit sync header (2'b01 = data block, 2'b10 = control
//    block) + 128-bit payload block = 130 bits/block, MSB first, 1 bit/clk.
//    Sync header bits are never scrambled (64b/66b-style); payloads are.
//  - Scrambler: self-synchronous.  SAS-4 specifies x^58+x^39+1; simplified
//    here to x^16+x^5+1 (noted): obit = dbit ^ s[15] ^ s[4], s <<= obit.
//    The same LFSR stream runs continuously across all block payloads
//    (idle blocks included), so the line never carries plaintext.
//  - Frame format: SOF control block + header data block {type,dst,src,len}
//    (one 32-bit dword per field, value in low 8 bits) + payload data
//    block(s) (len <= 8 dwords, zero padded to 4-dword blocks) + CRC32 data
//    block (dword0 = CRC, poly 0x04C11DB7 reflected, init/xorout all-ones,
//    covering header + padded payload blocks) + EOF control block.
//    Idle control blocks are sent between frames.
//  - OOB: SNW-style burst/idle handshake (106 clk burst, 318 clk idle,
//    >=64 clk run detect) -> PHY READY (link_up).
//  - Loss of sync: 8 consecutive invalid sync headers (2'b00/2'b11) while
//    locked -> loss_sync: irq pulse, link_down and full re-OOB.
//  - Functional unit: 16x32 register file.  type 8'h01 = write (payload[0]),
//    8'h02 = read request, 8'h83 = read response (payload[0] = reg value).
//    A built-in initiator sequencer loops write + read-verify transactions
//    over the loopback link.
//  - irq: 1-clk pulse on CRC error, protocol violation, link timeout or
//    loss of sync.
//  NOTE: clk is used as the line bit clock (1 bit/clk).  rx_n is the
//  inverted companion of rx_p and is unused by this single-ended model.
// IP design implementation v1.0 -- Apache-2.0
// ============================================================================
module SAS_4__Serial_Attached_SCSI__top #(
  parameter int DW = 32,       // data width
  parameter int AW = 32,       // address width
  parameter int BIT_CLKS = 1   // clk cycles per serial bit (bit-rate divider)
)(
  input  logic           clk,
  input  logic           rst_n,
  output logic           tx_p,
  output logic           tx_n,
  input  logic           rx_p,
  input  logic           rx_n,
  output logic           link_up,
  output logic           irq
);

  // ------------------------- constants -------------------------------------
  localparam logic [1:0]  SH_DATA   = 2'b01;        // data block sync header
  localparam logic [1:0]  SH_CTRL   = 2'b10;        // control block sync header
  localparam logic [31:0] CODE_IDLE = 32'hA5C3_0000; // idle control block code
  localparam logic [31:0] CODE_SOF  = 32'hA5C3_0001; // SOF control block code
  localparam logic [31:0] CODE_EOF  = 32'hA5C3_0002; // EOF control block code
  localparam logic [15:0] SCR_SEED  = 16'hACE1;      // scrambler seed
  // OOB burst/idle timing is wall-clock (raw clk), intentionally not scaled
  // by BIT_CLKS: OOB signalling precedes any bit-rate-divided traffic.
  localparam int          OOB_BURST   = 106;         // OOB burst length (clks)
  localparam int          OOB_IDLE    = 318;         // OOB idle length (clks)
  localparam int          OOB_DET_MIN = 64;          // min burst run to detect
  // Link timeout: counts bit-traffic latency, so it scales with BIT_CLKS.
  // BIT_CLKS=1 keeps the legacy value 4095 and 12-bit counter width.
  localparam int          SQ_TMO      = 4095 * BIT_CLKS;
  localparam int          SQW         = 12 + ((BIT_CLKS > 1) ? $clog2(BIT_CLKS) : 0);
  localparam logic [7:0]  T_WRITE     = 8'h01;       // register write
  localparam logic [7:0]  T_RDREQ     = 8'h02;       // register read request
  localparam logic [7:0]  T_RDRSP     = 8'h83;       // register read response

  // ------------------------- CRC32 (poly 04C11DB7 reflected) ----------------
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

  // CRC step over one 128-bit data-block payload (4 dwords)
  function automatic logic [31:0] crc4(input logic [31:0] crc,
                                       input logic [31:0] d0,
                                       input logic [31:0] d1,
                                       input logic [31:0] d2,
                                       input logic [31:0] d3);
    crc4 = crc32_dw(crc32_dw(crc32_dw(crc32_dw(crc, d0), d1), d2), d3);
  endfunction

  // ------------------------- OOB FSM ----------------------------------------
  typedef enum logic [2:0] {
    OB_CR_BURST, OB_CR_IDLE, OB_CI_BURST, OB_CI_IDLE, OB_DONE
  } oob_t;
  oob_t        oob_state;
  logic [9:0]  oob_cnt;
  logic        cr_seen, ci_seen;
  logic        phy_ready;
  logic        loss_sync;             // from RX: 8 bad sync headers

  // RX burst-run monitor (used during OOB)
  logic [7:0]  brun;
  logic        oob_det;

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      brun    <= 8'd0;
      oob_det <= 1'b0;
    end else begin
      oob_det <= 1'b0;
      if (rx_p) begin
        if (brun != 8'hFF) brun <= brun + 8'd1;
      end else begin
        if (brun >= OOB_DET_MIN[7:0]) oob_det <= 1'b1;
        brun <= 8'd0;
      end
    end
  end

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      oob_state <= OB_CR_BURST;
      oob_cnt   <= 10'd0;
      cr_seen   <= 1'b0;
      ci_seen   <= 1'b0;
      phy_ready <= 1'b0;
    end else if (loss_sync) begin      // loss of sync -> full re-OOB
      oob_state <= OB_CR_BURST;
      oob_cnt   <= 10'd0;
      cr_seen   <= 1'b0;
      ci_seen   <= 1'b0;
      phy_ready <= 1'b0;
    end else begin
      case (oob_state)
        OB_CR_BURST: begin                    // transmit COMRESET burst
          if (oob_cnt == OOB_BURST-1) begin
            oob_cnt   <= 10'd0;
            cr_seen   <= 1'b0;
            oob_state <= OB_CR_IDLE;
          end else oob_cnt <= oob_cnt + 10'd1;
        end
        OB_CR_IDLE: begin                     // idle, watch for COMINIT
          if (oob_det) cr_seen <= 1'b1;
          if (oob_cnt == OOB_IDLE-1) begin
            oob_cnt   <= 10'd0;
            oob_state <= cr_seen ? OB_CI_BURST : OB_CR_BURST;
          end else oob_cnt <= oob_cnt + 10'd1;
        end
        OB_CI_BURST: begin                    // transmit COMINIT burst
          if (oob_cnt == OOB_BURST-1) begin
            oob_cnt   <= 10'd0;
            ci_seen   <= 1'b0;
            oob_state <= OB_CI_IDLE;
          end else oob_cnt <= oob_cnt + 10'd1;
        end
        OB_CI_IDLE: begin                     // idle, watch for COMINIT ack
          if (oob_det) ci_seen <= 1'b1;
          if (oob_cnt == OOB_IDLE-1) begin
            oob_cnt <= 10'd0;
            if (ci_seen) begin
              oob_state <= OB_DONE;
              phy_ready <= 1'b1;
            end else oob_state <= OB_CI_BURST;
          end else oob_cnt <= oob_cnt + 10'd1;
        end
        OB_DONE: begin
          phy_ready <= 1'b1;
        end
        default: oob_state <= OB_CR_BURST;
      endcase
    end
  end

  // OOB line drive: constant burst pattern, idle otherwise
  logic oob_drive;
  assign oob_drive = (oob_state == OB_CR_BURST) || (oob_state == OB_CI_BURST);

  // ------------------------- TX block engine --------------------------------
  // Built-in sequencer only issues len 0/1 frames; the datapath supports
  // len <= 8 (two payload blocks, upper dwords zero padded).
  typedef enum logic [2:0] {
    TX_IDLE, TX_SOF, TX_HDR, TX_PAY0, TX_PAY1, TX_CRC, TX_EOF
  } tx_t;
  tx_t         tx_state;
  logic [7:0]  tx_cnt;                // bit position in block (0..129)
  logic [1:0]  tx_sync;
  logic [127:0] tx_pld;               // payload shift register (MSB first)
  logic [15:0] scr;                   // self-synchronous scrambler state
  logic        tx_bit;
  logic [31:0] crc_acc;
  logic [7:0]  f_type, f_dst, f_src, f_len;
  logic [31:0] f_data;

  // request from initiator sequencer
  logic        app_req, app_ack;
  logic [7:0]  app_len;
  logic [7:0]  app_type, app_dst;
  logic [31:0] app_data;
  // request from RX target handler (read response)
  logic        rsp_req_set, rsp_pending;
  logic [7:0]  rsp_dst, rsp_src;
  logic [31:0] rsp_data;

  logic        scr_obit;
  assign scr_obit = tx_pld[127] ^ scr[15] ^ scr[4];

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
      tx_state <= TX_IDLE;
      tx_cnt   <= 8'd0;
      tx_sync  <= SH_CTRL;
      tx_pld   <= {CODE_IDLE, 96'd0};
      scr      <= SCR_SEED;
      tx_bit   <= 1'b0;
      crc_acc  <= 32'd0;
      f_type   <= 8'd0;
      f_dst    <= 8'd0;
      f_src    <= 8'd0;
      f_len    <= 8'd0;
      f_data   <= 32'd0;
      app_ack  <= 1'b0;
      rsp_pending <= 1'b0;
    end else if (!phy_ready) begin
      tx_state <= TX_IDLE;
      tx_cnt   <= 8'd0;
      tx_sync  <= SH_CTRL;
      tx_pld   <= {CODE_IDLE, 96'd0};
      scr      <= SCR_SEED;
      tx_bit   <= 1'b0;
      app_ack  <= 1'b0;
      rsp_pending <= 1'b0;
    end else begin
      app_ack <= 1'b0;
      if (rsp_req_set) rsp_pending <= 1'b1;
      if (bit_tick) begin
      if (tx_cnt == 8'd0) begin
        tx_bit <= tx_sync[1];               // sync header MSB first, clear
        tx_cnt <= 8'd1;
      end else if (tx_cnt == 8'd1) begin
        tx_bit <= tx_sync[0];
        tx_cnt <= 8'd2;
      end else begin
        tx_bit <= scr_obit;                 // scrambled payload bit
        scr    <= {scr[14:0], scr_obit};
        tx_pld <= {tx_pld[126:0], 1'b0};
        if (tx_cnt == 8'd129) begin
          tx_cnt <= 8'd0;
          case (tx_state)                   // load next block
            TX_IDLE: begin
              if (rsp_pending || rsp_req_set) begin
                f_type <= T_RDRSP;
                f_dst  <= rsp_dst;
                f_src  <= rsp_src;
                f_len  <= 8'd1;
                f_data <= rsp_data;
                rsp_pending <= rsp_req_set; // keep any just-queued request
                tx_pld   <= {CODE_SOF, 96'd0};
                tx_sync  <= SH_CTRL;
                tx_state <= TX_SOF;
              end else if (app_req) begin
                f_type <= app_type;
                f_dst  <= app_dst;
                f_src  <= 8'h01;            // initiator SAS address
                f_len  <= app_len;
                f_data <= app_data;
                app_ack  <= 1'b1;
                tx_pld   <= {CODE_SOF, 96'd0};
                tx_sync  <= SH_CTRL;
                tx_state <= TX_SOF;
              end else begin
                tx_pld  <= {CODE_IDLE, 96'd0};
                tx_sync <= SH_CTRL;
              end
            end
            TX_SOF: begin                   // SOF on wire -> header block
              tx_pld   <= {24'd0, f_type, 24'd0, f_dst, 24'd0, f_src, 24'd0, f_len};
              tx_sync  <= SH_DATA;
              crc_acc  <= crc4(32'hFFFF_FFFF, {24'd0, f_type}, {24'd0, f_dst},
                               {24'd0, f_src}, {24'd0, f_len});
              tx_state <= TX_HDR;
            end
            TX_HDR: begin                   // header on wire
              tx_sync <= SH_DATA;
              if (f_len == 8'd0) begin
                tx_pld   <= {crc_acc ^ 32'hFFFF_FFFF, 96'd0};
                tx_state <= TX_CRC;
              end else begin
                tx_pld   <= {f_data, 96'd0};
                crc_acc  <= crc4(crc_acc, f_data, 32'd0, 32'd0, 32'd0);
                tx_state <= TX_PAY0;
              end
            end
            TX_PAY0: begin                  // payload block 0 on wire
              tx_sync <= SH_DATA;
              if (f_len <= 8'd4) begin
                tx_pld   <= {crc_acc ^ 32'hFFFF_FFFF, 96'd0};
                tx_state <= TX_CRC;
              end else begin
                tx_pld   <= 128'd0;         // upper payload dwords (unused)
                crc_acc  <= crc4(crc_acc, 32'd0, 32'd0, 32'd0, 32'd0);
                tx_state <= TX_PAY1;
              end
            end
            TX_PAY1: begin                  // payload block 1 on wire
              tx_sync  <= SH_DATA;
              tx_pld   <= {crc_acc ^ 32'hFFFF_FFFF, 96'd0};
              tx_state <= TX_CRC;
            end
            TX_CRC: begin                   // CRC on wire -> EOF
              tx_pld   <= {CODE_EOF, 96'd0};
              tx_sync  <= SH_CTRL;
              tx_state <= TX_EOF;
            end
            TX_EOF: begin                   // EOF on wire -> idle
              tx_pld   <= {CODE_IDLE, 96'd0};
              tx_sync  <= SH_CTRL;
              tx_state <= TX_IDLE;
            end
            default: tx_state <= TX_IDLE;
          endcase
        end else begin
          tx_cnt <= tx_cnt + 8'd1;
        end
      end
      end // bit_tick
    end
  end

  // serial line drive
  assign tx_p = rst_n ? (phy_ready ? tx_bit : oob_drive) : 1'b0;
  assign tx_n = ~tx_p;

  // ------------------------- RX block engine --------------------------------
  typedef enum logic {RX_HUNT, RX_LOCK} rxl_t;
  rxl_t        rx_lock;
  logic [7:0]  rx_cnt;                // bit position in block (0..129)
  logic [1:0]  rx_sync_r;             // captured sync header
  logic [127:0] rx_pld;               // descrambled payload shift register
  logic [15:0] dscr;                  // descrambler state
  logic [3:0]  viol_cnt;              // consecutive bad sync headers
  logic [2:0]  hunt_good;             // consecutive good syncs while hunting
  logic        hunt_code;             // legal control code seen while hunting

  // block frame FSM
  typedef enum logic [2:0] {RF_SOF, RF_HDR, RF_PAY, RF_CRC, RF_EOF} rf_t;
  rf_t         rf_state;
  logic [7:0]  r_type, r_dst, r_src, r_len;
  logic [31:0] rcrc;
  logic [31:0] rx_pay [0:7];
  logic        pay_blk;

  // functional unit: 16x32-bit register file
  logic [31:0] regs [0:15];

  // observability / event pulses
  logic        wr_evt;
  logic [3:0]  wr_addr;
  logic [31:0] wr_data;
  logic        rsp_evt;
  logic [31:0] rsp_val;
  logic        crc_err_pulse, proto_err_pulse;
  logic [15:0] crc_err_cnt;

  // current line bit / descrambled bit / completed block
  logic        rx_db;
  logic [127:0] blk;
  assign rx_db = rx_p ^ dscr[15] ^ dscr[4];
  assign blk   = {rx_pld[126:0], rx_db};

  integer k;
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      rx_lock    <= RX_HUNT;
      rx_cnt     <= 8'd0;
      rx_sync_r  <= 2'b00;
      rx_pld     <= 128'd0;
      dscr       <= SCR_SEED;
      viol_cnt   <= 4'd0;
      hunt_good  <= 3'd0;
      hunt_code  <= 1'b0;
      loss_sync  <= 1'b0;
      rf_state   <= RF_SOF;
      r_type     <= 8'd0;
      r_dst      <= 8'd0;
      r_src      <= 8'd0;
      r_len      <= 8'd0;
      rcrc       <= 32'd0;
      pay_blk    <= 1'b0;
      wr_evt     <= 1'b0;
      wr_addr    <= 4'd0;
      wr_data    <= 32'd0;
      rsp_evt    <= 1'b0;
      rsp_val    <= 32'd0;
      rsp_req_set<= 1'b0;
      rsp_dst    <= 8'd0;
      rsp_src    <= 8'd0;
      rsp_data   <= 32'd0;
      crc_err_pulse   <= 1'b0;
      proto_err_pulse <= 1'b0;
      crc_err_cnt     <= 16'd0;
      for (k = 0; k < 16; k = k + 1) regs[k] <= 32'd0;
    end else if (!phy_ready) begin
      rx_lock    <= RX_HUNT;
      rx_cnt     <= 8'd0;
      rx_sync_r  <= 2'b00;
      dscr       <= SCR_SEED;
      viol_cnt   <= 4'd0;
      hunt_good  <= 3'd0;
      hunt_code  <= 1'b0;
      loss_sync  <= 1'b0;
      rf_state   <= RF_SOF;
      wr_evt     <= 1'b0;
      rsp_evt    <= 1'b0;
      rsp_req_set<= 1'b0;
      crc_err_pulse   <= 1'b0;
      proto_err_pulse <= 1'b0;
    end else begin
      wr_evt          <= 1'b0;
      rsp_evt         <= 1'b0;
      rsp_req_set     <= 1'b0;
      crc_err_pulse   <= 1'b0;
      proto_err_pulse <= 1'b0;
      loss_sync       <= 1'b0;
      if (bit_tick) begin
      if (rx_cnt == 8'd0) begin
        rx_sync_r[1] <= rx_p;               // sync header MSB
        rx_cnt       <= 8'd1;
      end else if (rx_cnt == 8'd1) begin
        rx_sync_r[0] <= rx_p;               // sync header LSB
        if ({rx_sync_r[1], rx_p} == SH_DATA || {rx_sync_r[1], rx_p} == SH_CTRL) begin
          rx_cnt <= 8'd2;                   // valid sync: capture payload
          if (rx_lock == RX_HUNT) begin
            // lock after 4 consecutive good syncs AND a legal control code
            // (protects against false lock on scrambled idle payload bits)
            if (hunt_good == 3'd3 && hunt_code) begin
              rx_lock  <= RX_LOCK;
              viol_cnt <= 4'd0;
            end else hunt_good <= hunt_good + 3'd1;
          end else begin
            viol_cnt <= 4'd0;               // valid sync re-arms loss detect
          end
        end else begin
          if (rx_lock == RX_HUNT) begin
            hunt_good    <= 3'd0;
            hunt_code    <= 1'b0;
            rx_sync_r[1] <= rx_p;           // bit slip: retry at +1 offset
            rx_cnt       <= 8'd1;
          end else begin
            rx_cnt   <= 8'd2;               // stay aligned, drop this block
            viol_cnt <= viol_cnt + 4'd1;
            if (viol_cnt == 4'd7) begin     // 8 consecutive violations
              loss_sync <= 1'b1;
              rx_lock   <= RX_HUNT;
              hunt_good <= 3'd0;
              rf_state  <= RF_SOF;
            end
          end
        end
      end else begin
        dscr   <= {dscr[14:0], rx_p};       // self-synchronous descrambler
        rx_pld <= {rx_pld[126:0], rx_db};
        if (rx_cnt == 8'd129) begin
          rx_cnt <= 8'd0;
          if (rx_lock == RX_HUNT) begin
            // descrambled control code check (block-alignment evidence)
            if (rx_sync_r == SH_CTRL &&
                (blk[127:96] == CODE_IDLE || blk[127:96] == CODE_SOF ||
                 blk[127:96] == CODE_EOF))
              hunt_code <= 1'b1;
          end else if (rx_sync_r == SH_DATA || rx_sync_r == SH_CTRL) begin
            case (rf_state)
              RF_SOF: begin                 // wait for SOF control block
                if (rx_sync_r == SH_CTRL && blk[127:96] == CODE_SOF) begin
                  rcrc     <= 32'hFFFF_FFFF;
                  rf_state <= RF_HDR;
                end
              end
              RF_HDR: begin                 // header data block
                if (rx_sync_r != SH_DATA || blk[7:0] > 8'd8) begin
                  proto_err_pulse <= 1'b1;
                  rf_state        <= RF_SOF;
                end else begin
                  r_type <= blk[103:96];
                  r_dst  <= blk[71:64];
                  r_src  <= blk[39:32];
                  r_len  <= blk[7:0];
                  rcrc   <= crc4(32'hFFFF_FFFF, blk[127:96], blk[95:64],
                                 blk[63:32], blk[31:0]);
                  if (blk[7:0] == 8'd0) rf_state <= RF_CRC;
                  else begin
                    pay_blk  <= 1'b0;
                    rf_state <= RF_PAY;
                  end
                end
              end
              RF_PAY: begin                 // payload data block(s)
                if (rx_sync_r != SH_DATA) begin
                  proto_err_pulse <= 1'b1;
                  rf_state        <= RF_SOF;
                end else begin
                  rx_pay[{pay_blk, 2'b00}]        <= blk[127:96];
                  rx_pay[{pay_blk, 2'b00} + 3'd1] <= blk[95:64];
                  rx_pay[{pay_blk, 2'b00} + 3'd2] <= blk[63:32];
                  rx_pay[{pay_blk, 2'b00} + 3'd3] <= blk[31:0];
                  rcrc <= crc4(rcrc, blk[127:96], blk[95:64],
                               blk[63:32], blk[31:0]);
                  if (r_len <= 8'd4 || pay_blk == 1'b1) rf_state <= RF_CRC;
                  else pay_blk <= 1'b1;
                end
              end
              RF_CRC: begin                 // CRC data block
                if (rx_sync_r != SH_DATA) begin
                  proto_err_pulse <= 1'b1;
                end else if (blk[127:96] == (rcrc ^ 32'hFFFF_FFFF)) begin
                  case (r_type)
                    T_WRITE: begin          // register write
                      if (r_len >= 8'd1 && r_dst < 8'd16) begin
                        regs[r_dst[3:0]] <= rx_pay[0];
                        wr_evt           <= 1'b1;
                        wr_addr          <= r_dst[3:0];
                        wr_data          <= rx_pay[0];
                      end else proto_err_pulse <= 1'b1;
                    end
                    T_RDREQ: begin          // register read request
                      if (r_dst < 8'd16) begin
                        rsp_req_set <= 1'b1;
                        rsp_dst     <= r_src;
                        rsp_src     <= r_dst;
                        rsp_data    <= regs[r_dst[3:0]];
                      end else proto_err_pulse <= 1'b1;
                    end
                    T_RDRSP: begin          // read response
                      if (r_len >= 8'd1) begin
                        rsp_evt <= 1'b1;
                        rsp_val <= rx_pay[0];
                      end else proto_err_pulse <= 1'b1;
                    end
                    default: proto_err_pulse <= 1'b1; // unknown frame type
                  endcase
                end else begin
                  crc_err_pulse <= 1'b1;    // bad frame: discard + flag
                  crc_err_cnt   <= crc_err_cnt + 16'd1;
                end
                rf_state <= RF_EOF;
              end
              RF_EOF: begin                 // EOF control block expected
                if (!(rx_sync_r == SH_CTRL && blk[127:96] == CODE_EOF))
                  proto_err_pulse <= 1'b1;
                rf_state <= RF_SOF;
              end
              default: rf_state <= RF_SOF;
            endcase
          end
        end else begin
          rx_cnt <= rx_cnt + 8'd1;
        end
      end
      end // bit_tick
    end
  end

  // ------------------------- initiator sequencer -----------------------------
  typedef enum logic [2:0] {
    SQ_INIT, SQ_WR, SQ_WR_WAIT, SQ_RD, SQ_RD_WAIT, SQ_GAP
  } sq_t;
  sq_t         sq_state;
  logic [SQW-1:0] sq_tmo;
  // inter-transaction gap in raw clks (wall-clock pacing, not scaled)
  logic [5:0]  gap_cnt;
  logic [3:0]  sq_addr;
  logic [31:0] sq_wdata;
  logic [15:0] ok_cnt, mm_cnt;
  logic        tmo_err_pulse;

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      sq_state      <= SQ_INIT;
      sq_tmo        <= '0;
      gap_cnt       <= 6'd0;
      sq_addr       <= 4'd0;
      sq_wdata      <= 32'h5A5A_0000;
      ok_cnt        <= 16'd0;
      mm_cnt        <= 16'd0;
      app_req       <= 1'b0;
      app_len       <= 8'd0;
      app_type      <= 8'd0;
      app_dst       <= 8'd0;
      app_data      <= 32'd0;
      tmo_err_pulse <= 1'b0;
    end else if (!phy_ready) begin
      sq_state      <= SQ_INIT;
      sq_tmo        <= '0;
      gap_cnt       <= 6'd0;
      app_req       <= 1'b0;
      tmo_err_pulse <= 1'b0;
    end else begin
      tmo_err_pulse <= 1'b0;
      case (sq_state)
        SQ_INIT: begin
          if (rx_lock == RX_LOCK) begin       // RX block-locked before traffic
            if (gap_cnt == 6'd63) begin
              gap_cnt  <= 6'd0;
              sq_state <= SQ_WR;
            end else gap_cnt <= gap_cnt + 6'd1;
          end else gap_cnt <= 6'd0;
        end
        SQ_WR: begin                          // issue register write frame
          app_req  <= 1'b1;
          app_len  <= 8'd1;
          app_type <= T_WRITE;
          app_dst  <= {4'd0, sq_addr};
          app_data <= sq_wdata;
          if (app_ack) begin
            app_req  <= 1'b0;
            sq_tmo   <= '0;
            sq_state <= SQ_WR_WAIT;
          end
        end
        SQ_WR_WAIT: begin                     // wait for looped-back write
          if (wr_evt) begin
            sq_state <= SQ_RD;
          end else if (sq_tmo == SQ_TMO[SQW-1:0]) begin
            tmo_err_pulse <= 1'b1;
            sq_state      <= SQ_RD;
          end else sq_tmo <= sq_tmo + 1'b1;
        end
        SQ_RD: begin                          // issue register read request
          app_req  <= 1'b1;
          app_len  <= 8'd0;
          app_type <= T_RDREQ;
          app_dst  <= {4'd0, sq_addr};
          if (app_ack) begin
            app_req  <= 1'b0;
            sq_tmo   <= '0;
            sq_state <= SQ_RD_WAIT;
          end
        end
        SQ_RD_WAIT: begin                     // verify read response
          if (rsp_evt) begin
            if (rsp_val === sq_wdata) ok_cnt <= ok_cnt + 16'd1;
            else                      mm_cnt <= mm_cnt + 16'd1;
            sq_wdata <= sq_wdata + 32'h0001_0101;
            sq_addr  <= sq_addr + 4'd1;
            gap_cnt  <= 6'd0;
            sq_state <= SQ_GAP;
          end else if (sq_tmo == SQ_TMO[SQW-1:0]) begin
            tmo_err_pulse <= 1'b1;
            sq_wdata      <= sq_wdata + 32'h0001_0101;
            sq_addr       <= sq_addr + 4'd1;
            gap_cnt       <= 6'd0;
            sq_state      <= SQ_GAP;
          end else sq_tmo <= sq_tmo + 1'b1;
        end
        SQ_GAP: begin                         // inter-transaction gap
          if (gap_cnt == 6'd31) begin
            gap_cnt  <= 6'd0;
            sq_state <= SQ_WR;
          end else gap_cnt <= gap_cnt + 6'd1;
        end
        default: sq_state <= SQ_INIT;
      endcase
    end
  end

  // ------------------------- outputs -----------------------------------------
  assign link_up = phy_ready;

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) irq <= 1'b0;
    else        irq <= crc_err_pulse | proto_err_pulse | tmo_err_pulse | loss_sync;
  end

endmodule
