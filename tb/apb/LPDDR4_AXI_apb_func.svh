// SPDX-License-Identifier: Apache-2.0
// LPDDR4_AXI-specific part of tb/LPDDR4_AXI_apb_tb.sv: the shared DDR AXI body
// (tb/apb/ddr_axi_apb_body.svh). The core-level burst checks are in tb/LPDDR4_AXI_tb.sv.
// DRAM device (tb/mem_dev.svh): the core keeps no array of its own
localparam int NCH = 2;
function automatic int cellof(input logic [31:0] a); return {a[8], a[7:0]}; endfunction
`define MEM_DEV_CLK PCLK
`define MEM_DEV_RD (!cs_n && ca[5:3] == 3'd2)
`define MEM_DEV_WR (!cs_n && ca[5:3] == 3'd3)
`define MEM_DEV_CL (dut.u_core.u_core.fset ? 22 : 15)
`define MEM_DEV_CH(a) int'(a[8])
`include "mem_dev.svh"
`define DDR_AXI_APB_LP 1
`include "apb/ddr_axi_apb_body.svh"
`undef DDR_AXI_APB_LP
