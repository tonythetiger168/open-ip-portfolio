// SPDX-License-Identifier: Apache-2.0
// Self-checking core testbench of LPDDR4_AXI_top (LPDDR4_top behind the AXI4
// subordinate front end ddr_axi_slv). The checks are in tb/ddr_axi_tb.svh;
// the DRAM device is tb/mem_dev.svh.
`timescale 1ns/1ps
`define DDR_AXI_NAME "LPDDR4_AXI"
`define DDR_AXI_NCH 2
`define DDR_AXI_LP  1
module LPDDR4_AXI_tb;
  `include "ddr_axi_tb.svh"
  // DRAM pins and the device (tb/mem_dev.svh): the core keeps no array
  localparam int NCH = 2;
  wire ck_t, ck_c, cs_n, cke;
  wire [5:0] ca;
  tri  [31:0] dq;
  tri  [1:0]  dqs;
  function automatic int cellof(input logic [31:0] a); return {a[8], a[7:0]}; endfunction
  `define MEM_DEV_RD (!cs_n && ca[5:3] == 3'd2)
  `define MEM_DEV_WR (!cs_n && ca[5:3] == 3'd3)
  `define MEM_DEV_CL (dut.u_core.fset ? 22 : 15)
  `define MEM_DEV_CH(a) int'(a[8])
  `include "mem_dev.svh"
  LPDDR4_AXI_top dut (
    .clk, .rst_n,
    .s_awid, .s_awaddr, .s_awlen, .s_awsize, .s_awburst, .s_awvalid, .s_awready,
    .s_wdata, .s_wstrb, .s_wlast, .s_wvalid, .s_wready,
    .s_bid, .s_bresp, .s_bvalid, .s_bready,
    .s_arid, .s_araddr, .s_arlen, .s_arsize, .s_arburst, .s_arvalid, .s_arready,
    .s_rid, .s_rdata, .s_rresp, .s_rlast, .s_rvalid, .s_rready,
    .ck_t, .ck_c, .ca, .cs_n, .dq, .dqs, .cke,
    .trace_valid, .trace_cmd, .trace_addr,
    .n_rd, .n_wr, .n_rmw, .n_err, .err_irq
  );
endmodule
