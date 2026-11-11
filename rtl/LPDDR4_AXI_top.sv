// SPDX-License-Identifier: Apache-2.0
// ============================================================================
// LPDDR4_AXI: LPDDR4_top memory controller with an AXI4 subordinate port
// ----------------------------------------------------------------------------
// The unchanged LPDDR4_top core behind ddr_axi_slv (see that file for the
// AXI rules: INCR / FIXED / WRAP, AxSIZE 0..2, WSTRB read-modify-write,
// SLVERR on AxSIZE > 2 or a misplaced WLAST, one transaction at a time).
// LPDDR4_top keeps 256 16-bit columns per channel (NCH = 2: halfword h maps
// onto channel h[8], column h[7:0]). A write to column 0xF0 is the core's
// MR7 frequency-set write (bit 0 of the halfword: 0 set A, 1 set B); it does
// not change the array.
// ============================================================================
module LPDDR4_AXI_top #(
  parameter int NCH = 2
) (
  input  logic        clk,
  input  logic        rst_n,
  // AXI4 subordinate (s_*): 32-bit address and data, 4-bit ID
  input  logic [3:0]  s_awid,
  input  logic [31:0] s_awaddr,
  input  logic [7:0]  s_awlen,
  input  logic [2:0]  s_awsize,
  input  logic [1:0]  s_awburst,
  input  logic        s_awvalid,
  output logic        s_awready,
  input  logic [31:0] s_wdata,
  input  logic [3:0]  s_wstrb,
  input  logic        s_wlast,
  input  logic        s_wvalid,
  output logic        s_wready,
  output logic [3:0]  s_bid,
  output logic [1:0]  s_bresp,
  output logic        s_bvalid,
  input  logic        s_bready,
  input  logic [3:0]  s_arid,
  input  logic [31:0] s_araddr,
  input  logic [7:0]  s_arlen,
  input  logic [2:0]  s_arsize,
  input  logic [1:0]  s_arburst,
  input  logic        s_arvalid,
  output logic        s_arready,
  output logic [3:0]  s_rid,
  output logic [31:0] s_rdata,
  output logic [1:0]  s_rresp,
  output logic        s_rlast,
  output logic        s_rvalid,
  input  logic        s_rready,
  // DRAM pins of the core
  output logic        ck_t,
  output logic        ck_c,
  output logic [5:0]  ca,
  output logic        cs_n,
  inout  tri [NCH*16-1:0] dq,
  inout  tri [1:0]    dqs,
  output logic        cke,
  // core command trace (as LPDDR4_top)
  output logic        trace_valid,
  output logic [2:0]  trace_cmd,
  output logic [31:0] trace_addr,
  // statistics
  output logic [15:0] n_rd,
  output logic [15:0] n_wr,
  output logic [15:0] n_rmw,
  output logic [15:0] n_err,
  output logic        err_irq
);
  logic        hvalid, hready, hdone;
  logic [2:0]  hcmd;
  logic [31:0] haddr;
  logic [15:0] hwdata, hrdata;

  ddr_axi_slv u_axi (
    .clk, .rst_n,
    .s_awid(s_awid),
    .s_awaddr(s_awaddr),
    .s_awlen(s_awlen),
    .s_awsize(s_awsize),
    .s_awburst(s_awburst),
    .s_awvalid(s_awvalid),
    .s_awready(s_awready),
    .s_wdata(s_wdata),
    .s_wstrb(s_wstrb),
    .s_wlast(s_wlast),
    .s_wvalid(s_wvalid),
    .s_wready(s_wready),
    .s_bid(s_bid),
    .s_bresp(s_bresp),
    .s_bvalid(s_bvalid),
    .s_bready(s_bready),
    .s_arid(s_arid),
    .s_araddr(s_araddr),
    .s_arlen(s_arlen),
    .s_arsize(s_arsize),
    .s_arburst(s_arburst),
    .s_arvalid(s_arvalid),
    .s_arready(s_arready),
    .s_rid(s_rid),
    .s_rdata(s_rdata),
    .s_rresp(s_rresp),
    .s_rlast(s_rlast),
    .s_rvalid(s_rvalid),
    .s_rready(s_rready),
    .hvalid, .hready, .hcmd, .haddr, .hwdata, .hrdata, .hdone,
    .n_rd, .n_wr, .n_rmw, .n_err, .err_irq
  );

  LPDDR4_top #(.NCH(NCH)) u_core (
    .clk, .rst_n,
    .hvalid, .hready, .hcmd, .haddr, .hwdata, .hrdata, .hdone,
    .ck_t, .ck_c, .ca, .cs_n, .dq, .dqs, .cke,
    .trace_valid, .trace_cmd, .trace_addr
  );
endmodule
