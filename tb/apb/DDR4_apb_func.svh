// SPDX-License-Identifier: Apache-2.0
// DDR4-specific part of tb/DDR4_apb_tb.sv: the address map of the core; the
// tests are the shared tb/apb/mem_apb_common.svh.
localparam int NBU = 4;
function automatic logic [31:0] mk(input int b, input logic [13:0] row, input logic [7:0] col);
  mk = $urandom;
  mk[31:18] = row; mk[10:9] = b[1:0]; mk[7:0] = col;
endfunction
function automatic int cellof(input logic [31:0] a);
  cellof = a[7:0];
endfunction
localparam int NCH = 1;
localparam int CL = 15, CWL = 11;
localparam int IRQ_RD_DONE = IRQ_DONE;
`define MEM_DEV_RD (!cs_n && act_n && {ras_n, cas_n, we_n} == 3'b101)
`define MEM_DEV_WR (!cs_n && act_n && {ras_n, cas_n, we_n} == 3'b100)
`define MEM_DEV_LINE addr[12]
`define MEM_DEV_CL dut.u_core.cl_now
`define MEM_DEV_CWL dut.u_core.cwl_now
`define MEM_DEV_DQS dqs
`define MEM_LINE
`include "apb/mem_apb_common.svh"
task automatic ip_func; mem_func(); endtask
