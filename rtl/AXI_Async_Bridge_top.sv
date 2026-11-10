// SPDX-License-Identifier: Apache-2.0
// ============================================================================
// AXI_Async_Bridge_top: AXI4 clock-domain crossing
// ----------------------------------------------------------------------------
//  - Subordinate port s_* on s_clk, manager port m_* on m_clk; the two clocks
//    are unrelated (any ratio).
//  - One axi_async_fifo per channel: AW, W and AR from s to m, B and R from
//    m to s, each DEPTH entries (a power of two, at least 4). Channels are
//    independent, so the bridge keeps AXI ordering per channel and adds no
//    ordering of its own. Latency: two to three clocks of the receiving side
//    after a beat is written.
//  - 32-bit data, IDW-bit IDs; the AXI4 signals the SoC fabric uses (no
//    QoS, region, cache, prot, lock or user). A pure pipe: no response is
//    generated or changed.
//  - RESP_ERR (s_clk) pulses for one clock after a B or R beat with SLVERR or
//    DECERR is handed to the s side (an error interrupt for the APB wrapper).
//  - Reset both sides together (s_rst_n and m_rst_n).
// ============================================================================
module AXI_Async_Bridge_top #(
  parameter int IDW   = 8,
  parameter int DEPTH = 8
)(
  input  logic           s_clk,
  input  logic           s_rst_n,
  input  logic [IDW-1:0] s_awid,
  input  logic [31:0]    s_awaddr,
  input  logic [7:0]     s_awlen,
  input  logic [2:0]     s_awsize,
  input  logic [1:0]     s_awburst,
  input  logic           s_awvalid,
  output logic           s_awready,
  input  logic [31:0]    s_wdata,
  input  logic [3:0]     s_wstrb,
  input  logic           s_wlast,
  input  logic           s_wvalid,
  output logic           s_wready,
  output logic [IDW-1:0] s_bid,
  output logic [1:0]     s_bresp,
  output logic           s_bvalid,
  input  logic           s_bready,
  input  logic [IDW-1:0] s_arid,
  input  logic [31:0]    s_araddr,
  input  logic [7:0]     s_arlen,
  input  logic [2:0]     s_arsize,
  input  logic [1:0]     s_arburst,
  input  logic           s_arvalid,
  output logic           s_arready,
  output logic [IDW-1:0] s_rid,
  output logic [31:0]    s_rdata,
  output logic [1:0]     s_rresp,
  output logic           s_rlast,
  output logic           s_rvalid,
  input  logic           s_rready,
  input  logic           m_clk,
  input  logic           m_rst_n,
  output logic [IDW-1:0] m_awid,
  output logic [31:0]    m_awaddr,
  output logic [7:0]     m_awlen,
  output logic [2:0]     m_awsize,
  output logic [1:0]     m_awburst,
  output logic           m_awvalid,
  input  logic           m_awready,
  output logic [31:0]    m_wdata,
  output logic [3:0]     m_wstrb,
  output logic           m_wlast,
  output logic           m_wvalid,
  input  logic           m_wready,
  input  logic [IDW-1:0] m_bid,
  input  logic [1:0]     m_bresp,
  input  logic           m_bvalid,
  output logic           m_bready,
  output logic [IDW-1:0] m_arid,
  output logic [31:0]    m_araddr,
  output logic [7:0]     m_arlen,
  output logic [2:0]     m_arsize,
  output logic [1:0]     m_arburst,
  output logic           m_arvalid,
  input  logic           m_arready,
  input  logic [IDW-1:0] m_rid,
  input  logic [31:0]    m_rdata,
  input  logic [1:0]     m_rresp,
  input  logic           m_rlast,
  input  logic           m_rvalid,
  output logic           m_rready,
  // s_clk: a B or R beat with SLVERR / DECERR went out on the s side (one-clock pulse)
  output logic           resp_err
);
  localparam int AW_W = IDW + 32 + 8 + 3 + 2;
  localparam int W_W  = 32 + 4 + 1;
  localparam int B_W  = IDW + 2;
  localparam int R_W  = IDW + 32 + 2 + 1;

  axi_async_fifo #(.W(AW_W), .DEPTH(DEPTH)) u_aw (
    .w_clk(s_clk), .w_rst_n(s_rst_n), .w_valid(s_awvalid), .w_ready(s_awready),
    .w_data({s_awid, s_awaddr, s_awlen, s_awsize, s_awburst}),
    .r_clk(m_clk), .r_rst_n(m_rst_n), .r_valid(m_awvalid), .r_ready(m_awready),
    .r_data({m_awid, m_awaddr, m_awlen, m_awsize, m_awburst}));
  axi_async_fifo #(.W(W_W), .DEPTH(DEPTH)) u_w (
    .w_clk(s_clk), .w_rst_n(s_rst_n), .w_valid(s_wvalid), .w_ready(s_wready),
    .w_data({s_wdata, s_wstrb, s_wlast}),
    .r_clk(m_clk), .r_rst_n(m_rst_n), .r_valid(m_wvalid), .r_ready(m_wready),
    .r_data({m_wdata, m_wstrb, m_wlast}));
  axi_async_fifo #(.W(AW_W), .DEPTH(DEPTH)) u_ar (
    .w_clk(s_clk), .w_rst_n(s_rst_n), .w_valid(s_arvalid), .w_ready(s_arready),
    .w_data({s_arid, s_araddr, s_arlen, s_arsize, s_arburst}),
    .r_clk(m_clk), .r_rst_n(m_rst_n), .r_valid(m_arvalid), .r_ready(m_arready),
    .r_data({m_arid, m_araddr, m_arlen, m_arsize, m_arburst}));
  axi_async_fifo #(.W(B_W), .DEPTH(DEPTH)) u_b (
    .w_clk(m_clk), .w_rst_n(m_rst_n), .w_valid(m_bvalid), .w_ready(m_bready),
    .w_data({m_bid, m_bresp}),
    .r_clk(s_clk), .r_rst_n(s_rst_n), .r_valid(s_bvalid), .r_ready(s_bready),
    .r_data({s_bid, s_bresp}));
  axi_async_fifo #(.W(R_W), .DEPTH(DEPTH)) u_r (
    .w_clk(m_clk), .w_rst_n(m_rst_n), .w_valid(m_rvalid), .w_ready(m_rready),
    .w_data({m_rid, m_rdata, m_rresp, m_rlast}),
    .r_clk(s_clk), .r_rst_n(s_rst_n), .r_valid(s_rvalid), .r_ready(s_rready),
    .r_data({s_rid, s_rdata, s_rresp, s_rlast}));

  always_ff @(posedge s_clk or negedge s_rst_n) begin
    if (!s_rst_n) resp_err <= 1'b0;
    else          resp_err <= (s_bvalid && s_bready && s_bresp[1]) || (s_rvalid && s_rready && s_rresp[1]);
  end
endmodule
