// SPDX-License-Identifier: Apache-2.0
// DDR4_Lite-specific part of tb/DDR4_Lite_apb_tb.sv: the address map of the core and
// its own features; the tests are the shared tb/apb/lite_apb_common.svh.
localparam int NLINES = 4 * 512 * 8, NBANK = 4;
localparam logic [31:0] OOR = 32'h0004_0000;
function automatic logic [31:0] mk(input int b, input int row, input int line);
  mk = $urandom;
  mk[31:18] = 0; mk[8:7] = b[1:0]; mk[17:9] = row[8:0]; mk[6:4] = line[2:0];
endfunction
function automatic int lidx(input logic [31:0] a);
  return int'({a[8:7], a[17:9], a[6:4]});
endfunction
`include "apb/lite_apb_common.svh"
task automatic lite_extra;
  // MR0 bit 7 (DLL reset) self-clears; CL 20 / CWL 20, then the defaults
  l_mrw(0, 8'h8F); l_mrr(0, 8'h0F); l_mrw(1, 8'h0F);
  l_wrl(mk(2, 5, 5)); l_rdl(mk(2, 5, 5));
  l_mrw(0, 8'd6); l_mrw(1, 8'd3); l_mrr(0, 8'd6);
endtask
task automatic ip_func; lite_func(); endtask
