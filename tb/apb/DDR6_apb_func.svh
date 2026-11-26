// SPDX-License-Identifier: Apache-2.0
// DDR6-specific part of tb/DDR6_apb_tb.sv: the address map of the core; the
// tests are the shared tb/apb/mem_apb_common.svh.
localparam int NBU = 8;
function automatic logic [31:0] mk(input int b, input logic [13:0] row, input logic [7:0] col);
  mk = $urandom;
  mk[31:18] = row; mk[8] = b[2]; mk[10:9] = b[1:0]; mk[7:0] = col;
endfunction
function automatic int cellof(input logic [31:0] a);
  cellof = {a[8], a[7:0]};
endfunction
// DRAM device (tb/mem_dev.svh): the core keeps no array of its own
localparam int NCH = 2;
`define MEM_DEV_RD ({ras_n, cas_n, we_n} == 3'b101)
`define MEM_DEV_WR ({ras_n, cas_n, we_n} == 3'b100)
`define MEM_DEV_CL 26
`define MEM_DEV_CH(a) int'(a[8])
`include "apb/mem_apb_common.svh"
task automatic ip_func; mem_func(); endtask
