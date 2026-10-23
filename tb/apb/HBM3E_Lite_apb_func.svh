// SPDX-License-Identifier: Apache-2.0
// HBM3E_Lite-specific part of tb/HBM3E_Lite_apb_tb.sv: the address map of the core and
// its own features; the tests are the shared tb/apb/lite_apb_common.svh.
localparam int NLINES = 32 * 512 * 8, NBANK = 32;
localparam logic [31:0] OOR = 32'h0020_0000;
function automatic logic [31:0] mk(input int b, input int row, input int line);
  mk = $urandom;
  mk[31:21] = 0; mk[11:7] = b[4:0]; mk[20:12] = row[8:0]; mk[6:4] = line[2:0];
endfunction
function automatic int lidx(input logic [31:0] a);
  return int'({a[11:7], a[20:12], a[6:4]});
endfunction
`include "apb/lite_apb_common.svh"
task automatic lite_extra;
  // every pseudo-channel through STATUS
  for (int p = 0; p < 8; p++) begin l_rdl(mk(4 * p + 3, 6, 1)); rd(A_STATUS); end
  // idle one whole refresh rotation so the per-entry REFs reach entries 8..31
  repeat (51480) @(posedge PCLK);
endtask
task automatic ip_func; lite_func(); endtask
