// SPDX-License-Identifier: Apache-2.0
// ============================================================================
// ISP: camera image signal processor of the phone SoC (AXI4 manager, APB4
// registers)
// ----------------------------------------------------------------------------
// Takes LEN words of 8-bit raw pixels (four per word, byte 0 first) from the
// sensor and writes the processed frame to DST with streaming writes:
// out = min(255, (max(0, p - BLACK) * GAIN) >> 4), GAIN unsigned Q4.4
// (16 = 1.0). STAT_SUM is the sum of the output pixels of the last frame
// (an auto-exposure statistic).
// - SRC_SEL 0: the built-in test pattern generator: pixel b of word x of
// line y is (4x + b + y) ^ SEED, with LINE_WORDS words per line.
// - SRC_SEL 1: the external sensor stream sns_valid / sns_data / sns_ready
// (for example from a CSI-2 receiver), one word of four pixels per beat.
// - DONE interrupt when a frame is written, ERR as well on an AXI error
// response. CYCLES is the length of the last frame in clocks.
// - AXI ID = AXI_ID; bursts of up to 16 beats, never across 4 KB.
// ============================================================================
module ISP_top #(
  parameter logic [3:0] AXI_ID = 4'd3
) (
  input  logic        clk,
  input  logic        rst_n,
  input  logic [31:0] dst_addr,
  input  logic [15:0] xfer_len,
  input  logic [15:0] line_words,
  input  logic        src_sel,
  input  logic [7:0]  seed,
  input  logic [7:0]  black,
  input  logic [7:0]  gain,
  input  logic        start,
  output logic        busy,
  output logic        err,
  output logic [31:0] stat_sum,
  output logic [31:0] cycles,
  output logic        done,
  output logic        err_irq,
  // external sensor stream
  input  logic        sns_valid,
  input  logic [31:0] sns_data,
  output logic        sns_ready,
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
  logic [31:0] rs_data, ws_data, raw, tpg;
  logic        sel_q;
  logic [15:0] x, y;
  logic [9:0]  psum;

  wire go = start && !busy;
  soc_ss_axi_engine #(.ID(AXI_ID)) u_eng (
    .clk, .rst_n,
    .start(go), .rd_en(1'b0), .wr_en(1'b1),
    .src(32'd0), .dst(dst_addr), .len(xfer_len),
    .busy, .done(e_done), .err, .cycles,
    .rs_valid, .rs_data, .rs_ready, .ws_valid, .ws_data, .ws_ready,
    .m_awid(m_awid),
    .m_awaddr(m_awaddr),
    .m_awlen(m_awlen),
    .m_awsize(m_awsize),
    .m_awburst(m_awburst),
    .m_awprot(m_awprot),
    .m_awvalid(m_awvalid),
    .m_awready(m_awready),
    .m_wdata(m_wdata),
    .m_wstrb(m_wstrb),
    .m_wlast(m_wlast),
    .m_wvalid(m_wvalid),
    .m_wready(m_wready),
    .m_bid(m_bid),
    .m_bresp(m_bresp),
    .m_bvalid(m_bvalid),
    .m_bready(m_bready),
    .m_arid(m_arid),
    .m_araddr(m_araddr),
    .m_arlen(m_arlen),
    .m_arsize(m_arsize),
    .m_arburst(m_arburst),
    .m_arprot(m_arprot),
    .m_arvalid(m_arvalid),
    .m_arready(m_arready),
    .m_rid(m_rid),
    .m_rdata(m_rdata),
    .m_rresp(m_rresp),
    .m_rlast(m_rlast),
    .m_rvalid(m_rvalid),
    .m_rready(m_rready)
  );
  assign rs_ready = 1'b0;

  always_comb begin
    for (int b = 0; b < 4; b++) tpg[8*b +: 8] = (8'(x << 2) + 8'(b) + y[7:0]) ^ seed;
  end
  assign raw       = sel_q ? sns_data : tpg;
  assign ws_valid  = busy && (sel_q ? sns_valid : 1'b1);
  assign sns_ready = busy && sel_q && ws_ready;

  always_comb begin
    psum = '0;
    for (int b = 0; b < 4; b++) begin
      logic [8:0]  d;
      logic [15:0] g;
      d = (raw[8*b +: 8] > black) ? 9'(raw[8*b +: 8] - black) : 9'd0;
      g = 16'(d) * 16'(gain);
      ws_data[8*b +: 8] = (g[15:4] > 12'd255) ? 8'hFF : g[11:4];
      psum = psum + 10'(ws_data[8*b +: 8]);
    end
  end

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      sel_q <= 1'b0; x <= '0; y <= '0; stat_sum <= '0;
    end else if (go) begin
      sel_q <= src_sel; x <= '0; y <= '0; stat_sum <= '0;
    end else if (ws_valid && ws_ready) begin
      stat_sum <= stat_sum + 32'(psum);
      if (x + 16'd1 >= line_words) begin x <= '0; y <= y + 16'd1; end
      else x <= x + 16'd1;
    end
  end
  assign done    = e_done;
  assign err_irq = e_done && err;
  wire unused = &{1'b0, rs_valid, rs_data};
endmodule
