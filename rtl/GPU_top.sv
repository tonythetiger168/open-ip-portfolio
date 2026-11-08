// SPDX-License-Identifier: Apache-2.0
// ============================================================================
// GPU: 2D graphics engine of the phone SoC (AXI4 manager, APB4 registers)
// ----------------------------------------------------------------------------
// A blitter on RGBA8888 surfaces (one pixel per 32-bit word): each job
// processes LEN pixels from SRC to DST.
// - MODE 0 COPY: dst = src.
// - MODE 1 FILL: dst = COLOR (no reads), a solid rectangle or a clear.
// - MODE 2 BLEND: each 8-bit channel c of a pixel becomes
// (src.c * ALPHA + COLOR.c * (256 - ALPHA)) >> 8, ALPHA = 0..256 (256: src).
// - MODE 3 INVERT: dst = ~src on the colour channels, alpha (bits 31:24) kept.
// - DONE interrupt when a job ends, ERR as well on an AXI error response.
// - PIXELS counts the pixels written by the last job, CYCLES its length.
// - AXI ID = AXI_ID; bursts of up to 16 beats, never across 4 KB.
// ============================================================================
module GPU_top #(
  parameter logic [3:0] AXI_ID = 4'd1
) (
  input  logic        clk,
  input  logic        rst_n,
  input  logic [31:0] src_addr,
  input  logic [31:0] dst_addr,
  input  logic [15:0] xfer_len,
  input  logic [1:0]  mode,
  input  logic [8:0]  alpha,
  input  logic [31:0] color,
  input  logic        start,
  output logic        busy,
  output logic        err,
  output logic [15:0] pixels,
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
  logic [31:0] rs_data, ws_data, blend;
  logic [1:0]  mode_q;
  logic [8:0]  a;

  wire go = start && !busy;
  soc_ss_axi_engine #(.ID(AXI_ID)) u_eng (
    .clk, .rst_n,
    .start(go), .rd_en(mode != 2'd1), .wr_en(1'b1),
    .src(src_addr), .dst(dst_addr), .len(xfer_len),
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

  assign a = (alpha > 9'd256) ? 9'd256 : alpha;
  always_comb begin
    for (int c = 0; c < 4; c++) begin
      logic [16:0] s;
      s = 17'(rs_data[8*c +: 8]) * 17'(a) + 17'(color[8*c +: 8]) * (17'd256 - 17'(a));
      blend[8*c +: 8] = s[15:8];
    end
  end
  always_comb begin
    case (mode_q)
      2'd1:    ws_data = color;
      2'd2:    ws_data = blend;
      2'd3:    ws_data = {rs_data[31:24], ~rs_data[23:0]};
      default: ws_data = rs_data;
    endcase
  end
  assign ws_valid = (mode_q == 2'd1) ? busy : rs_valid;
  assign rs_ready = ws_ready;

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      mode_q <= '0; pixels <= '0;
    end else if (go) begin
      mode_q <= mode; pixels <= '0;
    end else if (ws_valid && ws_ready) begin
      pixels <= pixels + 16'd1;
    end
  end
  assign done    = e_done;
  assign err_irq = e_done && err;
endmodule
