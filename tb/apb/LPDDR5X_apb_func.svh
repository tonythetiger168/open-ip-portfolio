// SPDX-License-Identifier: Apache-2.0
// LPDDR5X-specific part of tb/LPDDR5X_apb_tb.sv: the address map of the core; the
// tests are the shared tb/apb/mem_apb_common.svh.
localparam int NBU = 8;
function automatic logic [31:0] mk(input int b, input logic [13:0] row, input logic [7:0] col);
  mk = $urandom;
  mk[31:18] = row; mk[8] = b[2]; mk[10:9] = b[1:0]; mk[7:0] = (col == 8'hF1) ? 8'hF2 : col;
endfunction
function automatic int cellof(input logic [31:0] a);
  cellof = {a[8], a[7:0]};
endfunction
// DRAM device (tb/mem_dev.svh): the core keeps no array of its own
localparam int NCH = 2;
localparam int CL = 22, CWL = 11;
localparam int IRQ_RD_DONE = IRQ_DONE;
`define MEM_DEV_RD (!cs_n && ca[6:4] == 3'd2)
`define MEM_DEV_WR (!cs_n && ca[6:4] == 3'd3)
`define MEM_DEV_LINE ca[0]
`define MEM_DEV_CL dut.u_core.cl_now
`define MEM_DEV_CWL dut.u_core.cwl_now
`define MEM_DEV_DQS dqs
`define MEM_LINE
`define MEM_APB_MR0 8'd12             // CL = 10 + MR0[3:0]
`define MEM_DEV_CH(a) int'(a[8])
`include "apb/mem_apb_common.svh"
task automatic ip_func; mem_func(); endtask
