// SPDX-License-Identifier: Apache-2.0
// Self-checking core testbench of DDR4_AXI_top (DDR4_top behind the AXI4
// subordinate front end ddr_axi_slv). The checks are in tb/ddr_axi_tb.svh.
`timescale 1ns/1ps
`define DDR_AXI_NAME "DDR4_AXI"
`define DDR_AXI_NCH 1
`define DDR_AXI_LP  0
module DDR4_AXI_tb;
  `include "ddr_axi_tb.svh"
  DDR4_AXI_top dut (
    .clk, .rst_n,
    .s_awid, .s_awaddr, .s_awlen, .s_awsize, .s_awburst, .s_awvalid, .s_awready,
    .s_wdata, .s_wstrb, .s_wlast, .s_wvalid, .s_wready,
    .s_bid, .s_bresp, .s_bvalid, .s_bready,
    .s_arid, .s_araddr, .s_arlen, .s_arsize, .s_arburst, .s_arvalid, .s_arready,
    .s_rid, .s_rdata, .s_rresp, .s_rlast, .s_rvalid, .s_rready,
    .ck_t(), .ck_c(), .addr(), .ras_n(), .cas_n(), .we_n(), .dq(), .dqs(), .cke(),
    .trace_valid, .trace_cmd, .trace_addr,
    .n_rd, .n_wr, .n_rmw, .n_err, .err_irq
  );
endmodule
