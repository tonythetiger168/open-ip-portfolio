// SPDX-License-Identifier: Apache-2.0
// ============================================================================
// SAS protocol Open IP -- SAS initiator (OOB + SSP frame link layer)
// -- Apache-2.0
// Open IP design implementation v2.4
// ============================================================================
// Implementation scope:
//  - OOB FSM: COMRESET-style burst/idle pattern (106 symbol burst + 318 symbol
//    idle), COMINIT exchange detection, then PHY READY.
//  - Link layer: ALIGN idle primitive (32'h7B4A4ABC) inserted between frames,
//    1 bit/clk serialisation, MSB-first per 32-bit dword, tx_n = ~tx_p.
//  - SSP frame: SOF(32'hA5A50001) + HDR{len[31:24],type[23:16],dst[15:8],
//    src[7:0]} + PAYLOAD(len x 32-bit, len<=16) + CRC32 + EOF(32'hA5A50002).
//  - CRC32: poly 32'h04C11DB7 (reflected form 32'hEDB88320), init all-ones,
//    input/output reflected, final XOR all-ones (Ethernet FCS style),
//    processed one 32-bit dword per step over HDR + PAYLOAD.
//  - Functional unit: 16x32-bit register file. type 8'h01 = write,
//    8'h02 = read request, 8'h83 = read response (payload[0] = reg value).
//  - Built-in initiator sequencer issues write / read-verify transactions so
//    the IP exercises itself over the loopback link.
//  - irq: 1-clk pulse on CRC error or protocol violation (oversize len,
//    bad EOF, unknown frame type, bad register address, link timeout).
//  NOTE: refclk is kept for interface compatibility; this simplified model
//  uses clk as the line bit clock (1 bit/clk) and does not use refclk.
//  rx_n is the inverted companion of rx_p and is not used by the simplified
//  receiver (single-ended sampling on rx_p).
// ============================================================================
module SAS_top #(
  parameter int DW = 32,       // data width
  parameter int AW = 32,       // address width
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
  // Link timeout: counts bit-traffic latency, so it scales with BIT_CLKS.
  // BIT_CLKS=1 keeps the legacy value 512 and 10-bit counter width.
  localparam int          SQ_TMO      = 512 * BIT_CLKS;
  localparam int          SQW         = 10 + ((BIT_CLKS > 1) ? $clog2(BIT_CLKS) : 0);
  localparam logic [7:0]  T_WRITE     = 8'h01;        // register write
  localparam logic [7:0]  T_RDREQ     = 8'h02;        // register read request
  localparam logic [7:0]  T_RDRSP     = 8'h83;        // register read response

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
  oob_t        oob_state;
  logic [9:0]  oob_cnt;
  logic        cr_seen, ci_seen;
  logic        phy_ready;

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
  always_comb begin
    oob_drive = (oob_state == OB_CR_BURST) || (oob_state == OB_CI_BURST);
  end

  // ------------------------- TX link layer ----------------------------------
  // TX frames carry at most 1 payload dword (len 0 or 1); RX accepts len<=16.
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

  typedef enum logic [2:0] {
    TS_ALIGN, TS_SOF, TS_HDR, TS_PAY, TS_CRC, TS_EOF
  } tx_t;
  tx_t        tx_state;
  logic [31:0] tx_shift;
  logic [5:0]  tx_bit_cnt;
  logic [4:0]  f_len;
  logic [7:0]  f_type, f_dst, f_src;
  logic [31:0] f_data;
  logic [31:0] crc_acc;

  // request from initiator sequencer
  logic        app_req, app_ack;
  logic [4:0]  app_len;
  logic [7:0]  app_type, app_dst;
  logic [31:0] app_data;
  // request from RX target handler (read response)
  logic        rsp_req_set, rsp_pending;
  logic [7:0]  rsp_dst, rsp_src;
  logic [31:0] rsp_data;

  // observability for TB (payload dword of a write frame on the wire)
  logic        tx_pay_active, cur_is_write;
  always_comb begin
    tx_pay_active = (tx_state == TS_PAY);
    cur_is_write  = (f_type == T_WRITE) &&
                    (tx_state == TS_SOF || tx_state == TS_HDR ||
                     tx_state == TS_PAY || tx_state == TS_CRC ||
                     tx_state == TS_EOF);
  end

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      tx_state   <= TS_ALIGN;
      tx_shift   <= PRIM_ALIGN;
      tx_bit_cnt <= 6'd0;
      f_len      <= 5'd0;
      f_type     <= 8'd0;
      f_dst      <= 8'd0;
      f_src      <= 8'd0;
      f_data     <= 32'd0;
      crc_acc    <= 32'd0;
      app_ack    <= 1'b0;
      rsp_pending <= 1'b0;
    end else if (!phy_ready) begin
      tx_state   <= TS_ALIGN;
      tx_shift   <= PRIM_ALIGN;
      tx_bit_cnt <= 6'd0;
      app_ack    <= 1'b0;
      rsp_pending <= 1'b0;
    end else begin
      app_ack <= 1'b0;
      if (rsp_req_set) rsp_pending <= 1'b1;
      if (bit_tick) begin
      tx_bit_cnt <= tx_bit_cnt + 6'd1;
      tx_shift   <= {tx_shift[30:0], 1'b0};
      if (tx_bit_cnt == 6'd31) begin
        tx_bit_cnt <= 6'd0;
        case (tx_state)
          TS_ALIGN: begin                       // idle primitive; take requests
            if (rsp_pending || rsp_req_set) begin
              f_len    <= 5'd1;
              f_type   <= T_RDRSP;
              f_dst    <= rsp_dst;
              f_src    <= rsp_src;
              f_data   <= rsp_data;
              rsp_pending <= 1'b0;
              tx_shift <= SSP_SOF;
              tx_state <= TS_SOF;
            end else if (app_req) begin
              f_len    <= app_len;
              f_type   <= app_type;
              f_dst    <= app_dst;
              f_src    <= 8'h01;                // initiator SAS address
              f_data   <= app_data;
              app_ack  <= 1'b1;
              tx_shift <= SSP_SOF;
              tx_state <= TS_SOF;
            end else begin
              tx_shift <= PRIM_ALIGN;           // keep sending ALIGN
            end
          end
          TS_SOF: begin                         // SOF on wire -> load HEADER
            tx_shift <= {f_len, f_type, f_dst, f_src};
            crc_acc  <= crc32_dw(32'hFFFF_FFFF, {f_len, f_type, f_dst, f_src});
            tx_state <= TS_HDR;
          end
          TS_HDR: begin                         // HEADER on wire
            if (f_len == 5'd0) begin
              tx_shift <= crc_acc ^ 32'hFFFF_FFFF;
              tx_state <= TS_CRC;
            end else begin
              tx_shift <= f_data;
              crc_acc  <= crc32_dw(crc_acc, f_data);
              tx_state <= TS_PAY;
            end
          end
          TS_PAY: begin                         // PAYLOAD on wire -> load CRC
            tx_shift <= crc_acc ^ 32'hFFFF_FFFF;
            tx_state <= TS_CRC;
          end
          TS_CRC: begin                         // CRC on wire -> load EOF
            tx_shift <= SSP_EOF;
            tx_state <= TS_EOF;
          end
          TS_EOF: begin                         // EOF on wire -> back to ALIGN
            tx_shift <= PRIM_ALIGN;
            tx_state <= TS_ALIGN;
          end
          default: tx_state <= TS_ALIGN;
        endcase
      end
      end // bit_tick
    end
  end

  // serial line drive
  assign tx_p = rst_n ? (phy_ready ? tx_shift[31] : oob_drive) : 1'b0;
  assign tx_n = ~tx_p;

  // ------------------------- RX link layer ----------------------------------
  typedef enum logic [2:0] {
    RS_IDLE, RS_HDR, RS_PAY, RS_CRC, RS_EOF
  } rx_t;
  rx_t         rx_state;
  logic [31:0] rx_sh;
  logic [5:0]  rx_bit_cnt;
  logic [31:0] rx_pay [0:15];
  logic [4:0]  pay_idx;
  logic [4:0]  r_len;
  logic [7:0]  r_type, r_dst, r_src;
  logic [31:0] rcrc;
  logic        crc_ok_flag;

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

  logic [31:0] rx_dw;
  logic        dw_rdy;
  assign rx_dw  = {rx_sh[30:0], rx_p};
  assign dw_rdy = (rx_bit_cnt == 6'd31);

  integer k;
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      rx_state    <= RS_IDLE;
      rx_sh       <= 32'd0;
      rx_bit_cnt  <= 6'd0;
      pay_idx     <= 5'd0;
      r_len       <= 5'd0;
      r_type      <= 8'd0;
      r_dst       <= 8'd0;
      r_src       <= 8'd0;
      rcrc        <= 32'd0;
      crc_ok_flag <= 1'b0;
      wr_evt      <= 1'b0;
      wr_addr     <= 4'd0;
      wr_data     <= 32'd0;
      rsp_evt     <= 1'b0;
      rsp_val     <= 32'd0;
      rsp_req_set <= 1'b0;
      rsp_dst     <= 8'd0;
      rsp_src     <= 8'd0;
      rsp_data    <= 32'd0;
      crc_err_pulse  <= 1'b0;
      proto_err_pulse<= 1'b0;
      crc_err_cnt <= 16'd0;
      for (k = 0; k < 16; k = k + 1) regs[k] <= 32'd0;
    end else if (!phy_ready) begin
      rx_state    <= RS_IDLE;
      rx_sh       <= 32'd0;
      rx_bit_cnt  <= 6'd0;
      wr_evt      <= 1'b0;
      rsp_evt     <= 1'b0;
      rsp_req_set <= 1'b0;
      crc_err_pulse  <= 1'b0;
      proto_err_pulse<= 1'b0;
    end else begin
      wr_evt         <= 1'b0;
      rsp_evt        <= 1'b0;
      rsp_req_set    <= 1'b0;
      crc_err_pulse  <= 1'b0;
      proto_err_pulse<= 1'b0;
      if (bit_tick) begin
      rx_bit_cnt <= rx_bit_cnt + 6'd1;
      rx_sh      <= {rx_sh[30:0], rx_p};
      if (dw_rdy) begin
        rx_bit_cnt <= 6'd0;
        case (rx_state)
          RS_IDLE: begin
            if (rx_dw == SSP_SOF) rx_state <= RS_HDR;
          end
          RS_HDR: begin
            r_len  <= rx_dw[31:24];
            r_type <= rx_dw[23:16];
            r_dst  <= rx_dw[15:8];
            r_src  <= rx_dw[7:0];
            rcrc   <= crc32_dw(32'hFFFF_FFFF, rx_dw);
            if (rx_dw[31:24] > 5'd16) begin     // len violation
              proto_err_pulse <= 1'b1;
              rx_state        <= RS_IDLE;
            end else if (rx_dw[31:24] == 5'd0) begin
              rx_state <= RS_CRC;
            end else begin
              pay_idx  <= 5'd0;
              rx_state <= RS_PAY;
            end
          end
          RS_PAY: begin
            rx_pay[pay_idx] <= rx_dw;
            rcrc            <= crc32_dw(rcrc, rx_dw);
            if (pay_idx == r_len - 5'd1) rx_state <= RS_CRC;
            pay_idx <= pay_idx + 5'd1;
          end
          RS_CRC: begin
            if (rx_dw == (rcrc ^ 32'hFFFF_FFFF)) begin
              crc_ok_flag <= 1'b1;
              case (r_type)
                T_WRITE: begin                  // register write
                  if ((r_len >= 5'd1) && (r_dst < 8'd16)) begin
                    regs[r_dst[3:0]] <= rx_pay[0];
                    wr_evt           <= 1'b1;
                    wr_addr          <= r_dst[3:0];
                    wr_data          <= rx_pay[0];
                  end else proto_err_pulse <= 1'b1;
                end
                T_RDREQ: begin                  // register read request
                  if (r_dst < 8'd16) begin
                    rsp_req_set <= 1'b1;        // queue read response frame
                    rsp_dst     <= r_src;
                    rsp_src     <= r_dst;
                    rsp_data    <= regs[r_dst[3:0]];
                  end else proto_err_pulse <= 1'b1;
                end
                T_RDRSP: begin                  // read response
                  if (r_len >= 5'd1) begin
                    rsp_evt <= 1'b1;
                    rsp_val <= rx_pay[0];
                  end else proto_err_pulse <= 1'b1;
                end
                default: proto_err_pulse <= 1'b1; // unknown frame type
              endcase
            end else begin
              crc_ok_flag    <= 1'b0;
              crc_err_pulse  <= 1'b1;           // bad frame: discard + flag
              crc_err_cnt    <= crc_err_cnt + 16'd1;
            end
            rx_state <= RS_EOF;
          end
          RS_EOF: begin
            if (crc_ok_flag && (rx_dw != SSP_EOF)) proto_err_pulse <= 1'b1;
            rx_state <= RS_IDLE;
          end
          default: rx_state <= RS_IDLE;
        endcase
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
      app_len       <= 5'd0;
      app_type      <= 8'd0;
      app_dst       <= 8'd0;
      app_data      <= 32'd0;
      tmo_err_pulse <= 1'b0;
    end else begin
      tmo_err_pulse <= 1'b0;
      case (sq_state)
        SQ_INIT: begin
          if (phy_ready) begin
            if (gap_cnt == 6'd63) begin
              gap_cnt  <= 6'd0;
              sq_state <= SQ_WR;
            end else gap_cnt <= gap_cnt + 6'd1;
          end
        end
        SQ_WR: begin                          // issue register write frame
          app_req  <= 1'b1;
          app_len  <= 5'd1;
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
          app_len  <= 5'd0;
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

  // ------------------------- interrupt ---------------------------------------
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) irq <= 1'b0;
    else        irq <= crc_err_pulse | proto_err_pulse | tmo_err_pulse;
  end

endmodule
