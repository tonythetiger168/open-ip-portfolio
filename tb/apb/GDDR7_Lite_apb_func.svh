// SPDX-License-Identifier: Apache-2.0
// GDDR7_Lite-specific part of tb/GDDR7_Lite_apb_tb.sv: the address map of the core and
// its own features; the tests are the shared tb/apb/lite_apb_common.svh.
localparam int NLINES = 8 * 512 * 8, NBANK = 8;
localparam logic [31:0] OOR = 32'h0008_0000;
function automatic logic [31:0] mk(input int b, input int row, input int line);
  mk = $urandom;
  mk[31:19] = 0; mk[9:7] = b[2:0]; mk[18:10] = row[8:0]; mk[6:4] = line[2:0];
endfunction
function automatic int lidx(input logic [31:0] a);
  return int'({a[9:7], a[18:10], a[6:4]});
endfunction
`include "apb/lite_apb_common.svh"
task automatic lite_extra;
  // PAM3: lines written and read on the symbol bus, read back in PAM2
  l_mrw(2, 8'h01); rd_exp(A_STATUS, 1);
  for (int b = 0; b < NBANK; b += 3) begin l_wrl(mk(b, 9, b)); l_rdl(mk(b, 9, b)); end
  l_rdl(mk(0, 511, 7));
  l_mrw(2, 8'h00); rd_exp(A_STATUS, 0);
  for (int b = 0; b < NBANK; b += 3) l_rdl(mk(b, 9, b));
endtask
task automatic ip_func; lite_func(); endtask
