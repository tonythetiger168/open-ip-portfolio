// SPDX-License-Identifier: Apache-2.0
// ============================================================================
// I2S_DMA: I2S audio port with an AXI4 DMA (AXI4 manager, APB4 registers)
// ----------------------------------------------------------------------------
// The unchanged I2S_top core (slave: BCLK and LRCK come from the codec),
// fed and drained by soc_ss_axi_engine. One 32-bit word per stereo frame:
// bits 15:0 left, bits 31:16 right.
// - TX (TX_EN): the job reads LEN words from SRC. A word is taken at each
//   left-to-right LRCK change: its left half is written to the core then,
//   its right half at the next frame start, so word k plays in the frame
//   after the one it was taken in. With no word ready the frame repeats the
//   previous one and TX_UNDERRUN counts it.
// - RX (RX_EN): the job writes LEN words to DST, one per frame received
//   entirely after START (the frame running at START is skipped). The
//   frame is taken one BCLK rise after the next frame start, when its right
//   word has its LSB. A word not accepted by the engine before the next
//   frame ends is replaced by it, and RX_OVERRUN counts the lost frame;
//   the job still writes LEN words.
// - DONE interrupt when the job ends; ERR as well on an AXI error response.
//   FRAMES counts the frames played or received by the job.
// - AXI ID = AXI_ID; bursts of up to 16 beats, never across 4 KB.
// ============================================================================
module I2S_DMA_top #(
  parameter logic [3:0] AXI_ID = 4'd8
) (
  input  logic        clk,
  input  logic        rst_n,
  // I2S pins (slave)
  input  logic        bclk,
  input  logic        lrck,
  input  logic        sdin,
  output logic        sdout,
  // job
  input  logic [31:0] src_addr,
  input  logic [31:0] dst_addr,
  input  logic [15:0] xfer_len,
  input  logic        tx_en,
  input  logic        rx_en,
  input  logic        start,
  output logic        busy,
  output logic        err,
  output logic [15:0] frames,
  output logic [15:0] tx_underrun,
  output logic [15:0] rx_overrun,
  output logic [31:0] cycles,
  output logic        done,
  output logic        err_irq,
  // AXI4 manager (m_*): 32-bit address and data, 4-bit ID
  output logic [3:0]  m_awid,
  output logic [31:0] m_awaddr,
  output logic [7:0]  m_awlen,
  output logic [2:0]  m_awsize,
  output logic [1:0]  m_awburst,
  output logic [2:0]  m_awprot,
  output logic        m_awvalid,
  input  logic        m_awready,
  output logic [31:0] m_wdata,
  output logic [3:0]  m_wstrb,
  output logic        m_wlast,
  output logic        m_wvalid,
  input  logic        m_wready,
  input  logic [3:0]  m_bid,
  input  logic [1:0]  m_bresp,
  input  logic        m_bvalid,
  output logic        m_bready,
  output logic [3:0]  m_arid,
  output logic [31:0] m_araddr,
  output logic [7:0]  m_arlen,
  output logic [2:0]  m_arsize,
  output logic [1:0]  m_arburst,
  output logic [2:0]  m_arprot,
  output logic        m_arvalid,
  input  logic        m_arready,
  input  logic [3:0]  m_rid,
  input  logic [31:0] m_rdata,
  input  logic [1:0]  m_rresp,
  input  logic        m_rlast,
  input  logic        m_rvalid,
  output logic        m_rready
);
  logic        rs_valid, rs_ready, ws_valid, ws_ready, e_done;
  logic [31:0] rs_data;
  logic        wen;
  logic [3:0]  waddr;
  logic [15:0] wdata, rdata_c;
  logic [3:0]  raddr;
  logic        fsync;
  logic [31:0] rx_word;

  wire go = start && !busy && (tx_en || rx_en);
  soc_ss_axi_engine #(.ID(AXI_ID)) u_eng (
    .clk, .rst_n,
    .start(go), .rd_en(tx_en), .wr_en(rx_en),
    .src(src_addr), .dst(dst_addr), .len(xfer_len),
    .busy, .done(e_done), .err, .cycles,
    .rs_valid, .rs_data, .rs_ready, .ws_valid, .ws_data(rx_word), .ws_ready,
    .m_awid, .m_awaddr, .m_awlen, .m_awsize, .m_awburst, .m_awprot, .m_awvalid, .m_awready,
    .m_wdata, .m_wstrb, .m_wlast, .m_wvalid, .m_wready,
    .m_bid, .m_bresp, .m_bvalid, .m_bready,
    .m_arid, .m_araddr, .m_arlen, .m_arsize, .m_arburst, .m_arprot, .m_arvalid, .m_arready,
    .m_rid, .m_rdata, .m_rresp, .m_rlast, .m_rvalid, .m_rready
  );

  I2S_top #(.DW(16)) u_i2s (
    .clk, .rst_n, .bclk, .lrck, .sdin, .sdout,
    .wen, .waddr, .wdata, .ren(1'b0), .raddr, .rdata(rdata_c), .irq(fsync)
  );

  // the same 2-flop synchronizers as the core: these edges line up with its own
  logic bclk_s, bclk_d, lrck_s;
  always_ff @(posedge clk or negedge rst_n)
    if (!rst_n) begin bclk_s <= 1'b0; bclk_d <= 1'b0; lrck_s <= 1'b0; end
    else begin bclk_s <= bclk; bclk_d <= bclk_s; lrck_s <= lrck; end
  wire bclk_rise = bclk_s & ~bclk_d;
  wire to_right  = fsync &  lrck_s;     // left slot ended
  wire to_left   = fsync & ~lrck_s;     // frame start

  // ------------------------------------------------------------------ TX
  logic        tx_on, tx_have;
  logic [15:0] tx_r;                    // right half, written at frame start
  logic        tx_take;
  assign tx_take  = tx_on && to_right && rs_valid;
  assign rs_ready = tx_take;

  // ------------------------------------------------------------------ RX
  logic        rx_on, rx_armed, rx_wait, rx_get, rx_full;
  logic [15:0] rx_l;
  logic [1:0]  rd_step;                 // 1: read left, 2: read right
  assign ws_valid = rx_full;

  // core register port: TX writes have priority; RX reads are combinational
  always_comb begin
    wen = 1'b0; waddr = 4'd0; wdata = '0;
    if (tx_take)                        begin wen = 1'b1; waddr = 4'd0; wdata = rs_data[15:0]; end
    else if (to_left && tx_have) begin wen = 1'b1; waddr = 4'd1; wdata = tx_r; end
    raddr = (rd_step == 2'd2) ? 4'd1 : 4'd0;
  end

  logic [15:0] fr_cnt, tx_cnt, rx_cnt;
  logic        tx_mode;
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      tx_on <= 1'b0; tx_have <= 1'b0; tx_r <= '0; tx_underrun <= '0; tx_cnt <= '0; tx_mode <= 1'b0;
      rx_on <= 1'b0; rx_armed <= 1'b0; rx_wait <= 1'b0; rx_get <= 1'b0; rx_full <= 1'b0;
      rx_l <= '0; rx_word <= '0; rd_step <= '0; rx_overrun <= '0; rx_cnt <= '0; fr_cnt <= '0;
    end else begin
      rx_get <= 1'b0;
      if (go) begin
        tx_on <= tx_en && (xfer_len != 0); tx_have <= 1'b0; tx_underrun <= '0; tx_cnt <= '0;
        tx_mode <= tx_en;
        rx_on <= rx_en && (xfer_len != 0); rx_armed <= 1'b0; rx_wait <= 1'b0; rx_full <= 1'b0;
        rx_overrun <= '0; rx_cnt <= '0; fr_cnt <= '0; rd_step <= '0;
      end else begin
        // TX: a word per left-to-right change, its right half at the next
        // frame start (also after the last word of the job)
        if (tx_take) begin
          tx_r <= rs_data[31:16]; tx_have <= 1'b1; tx_cnt <= tx_cnt + 16'd1;
          if (tx_mode) fr_cnt <= fr_cnt + 16'd1;
          if (tx_cnt + 16'd1 == xfer_len) tx_on <= 1'b0;
        end else if (tx_on && to_right) tx_underrun <= tx_underrun + 16'd1;
        if (to_left && tx_have) tx_have <= 1'b0;
        // RX: a frame start ends the previous frame; it is complete one
        // BCLK rise later
        if (rx_on && to_left) begin
          if (rx_armed) rx_wait <= 1'b1;
          rx_armed <= 1'b1;
        end
        if (rx_wait && bclk_rise) begin rx_wait <= 1'b0; rx_get <= 1'b1; end
        if (rx_get) rd_step <= 2'd1;          // the core has updated rx_right now
        if (rd_step == 2'd1) begin rx_l <= rdata_c; rd_step <= 2'd2; end
        // rx_cnt counts the words loaded for the engine (an overrun
        // replaces the waiting word and is not counted again)
        if (rd_step == 2'd2) begin
          rd_step <= 2'd0;
          if (rx_on) begin
            rx_word <= {rdata_c, rx_l}; rx_full <= 1'b1;
            if (rx_full && !ws_ready) rx_overrun <= rx_overrun + 16'd1;
            else begin
              rx_cnt <= rx_cnt + 16'd1;
              if (!tx_mode) fr_cnt <= fr_cnt + 16'd1;
            end
          end else if (rx_full && ws_ready) rx_full <= 1'b0;
        end else if (rx_full && ws_ready) rx_full <= 1'b0;
        if (rx_on && rx_cnt == xfer_len) rx_on <= 1'b0;
      end
    end
  end
  assign frames  = fr_cnt;
  assign done    = e_done;
  assign err_irq = e_done && err;
endmodule
