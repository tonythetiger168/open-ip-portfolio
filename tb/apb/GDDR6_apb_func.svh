// SPDX-License-Identifier: Apache-2.0
// GDDR6-specific part of tb/GDDR6_apb_tb.sv: the address map of the core; the
// tests are the shared tb/apb/mem_apb_common.svh.
localparam int NBU = 8;
function automatic logic [31:0] mk(input int b, input logic [13:0] row, input logic [7:0] col);
  mk = $urandom;
  mk[31:18] = row; mk[8] = b[2]; mk[10:9] = b[1:0]; mk[7:0] = (col == 8'hF2) ? 8'hF3 : col;
endfunction
function automatic int cellof(input logic [31:0] a);
  cellof = {a[8], a[7:0]};
endfunction
`include "apb/mem_apb_common.svh"
task automatic ip_func; mem_func(); endtask
