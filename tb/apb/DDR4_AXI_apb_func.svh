// SPDX-License-Identifier: Apache-2.0
// DDR4_AXI-specific part of tb/DDR4_AXI_apb_tb.sv: the shared DDR AXI body
// (tb/apb/ddr_axi_apb_body.svh). The core-level burst checks are in tb/DDR4_AXI_tb.sv.
// DRAM device (tb/mem_dev.svh): the core keeps no array of its own
localparam int NCH = 1;
function automatic int cellof(input logic [31:0] a); return a[7:0]; endfunction
`define MEM_DEV_CLK PCLK
`define MEM_DEV_CL 15
`define MEM_DEV_RD (!cs_n && act_n && {ras_n, cas_n, we_n} == 3'b101)
`define MEM_DEV_WR (!cs_n && act_n && {ras_n, cas_n, we_n} == 3'b100)
`include "mem_dev.svh"
`define DDR_AXI_APB_LP 0
`include "apb/ddr_axi_apb_body.svh"
`undef DDR_AXI_APB_LP
