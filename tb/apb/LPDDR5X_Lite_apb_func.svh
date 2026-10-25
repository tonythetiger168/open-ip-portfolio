// SPDX-License-Identifier: Apache-2.0
// LPDDR5X_Lite-specific part of tb/LPDDR5X_Lite_apb_tb.sv: the address map of the core and
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
  // bank refresh on request, open and closed banks
  l_rdl(mk(3, 4, 4)); l_imm(3'd6, mk(3, 0, 0)); l_imm(3'd6, mk(3, 0, 0)); l_rdl(mk(3, 4, 4));
  // FSP1 with its own CL / CWL; FSP0 untouched
  wr(A_IRQ_STATUS, M_DONE); m_send(3'd7, 0, 16'h0001); l_wait(); rd_exp(A_STATUS, 1);
  l_mrw(0, 8'h02); l_mrw(1, 8'h0C); l_mrr(1, 8'h0C);
  l_wrl(mk(5, 7, 2)); l_rdl(mk(5, 7, 2));
  wr(A_IRQ_STATUS, M_DONE); m_send(3'd7, 0, 16'hFFFE); l_wait(); rd_exp(A_STATUS, 0);
  l_mrr(1, 8'd3); l_rdl(mk(5, 7, 2));
  // idle one whole refresh rotation so the per-entry REFs reach banks 4..7
  repeat (35100) @(posedge PCLK);
endtask
task automatic ip_func; lite_func(); endtask
