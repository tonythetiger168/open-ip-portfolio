// SPDX-License-Identifier: Apache-2.0
// GDDR7-specific part of tb/GDDR7_apb_tb.sv: the address map of the core; the
// tests are the shared tb/apb/mem_apb_common.svh.
localparam int NBU = 8;
function automatic logic [31:0] mk(input int b, input logic [13:0] row, input logic [7:0] col);
  mk = $urandom;
  mk[31:18] = row; mk[8] = b[2]; mk[10:9] = b[1:0]; mk[7:0] = col;
endfunction
function automatic int cellof(input logic [31:0] a);
  cellof = {a[8], a[7:0]};
endfunction
// DRAM device (tb/mem_dev.svh): the core keeps no array of its own; a read
// word goes out as PAM3 symbols over two beats (see tb/GDDR7_tb.sv)
localparam int NCH = 2;
function automatic logic [23:0] pam3_enc(input logic [15:0] w);
  logic [3:0] v;
  for (int n = 0; n < 4; n++) begin
    v = w[4*n +: 4];
    pam3_enc[6*n +: 2] = 2'(v / 9); pam3_enc[6*n+2 +: 2] = 2'((v % 9) / 3); pam3_enc[6*n+4 +: 2] = 2'(v % 3);
  end
endfunction
function automatic logic [15:0] pam3_beat(input logic [15:0] w, input int k);
  logic [23:0] t;
  t = pam3_enc(w);
  return (k == 0) ? {4'hz, t[11:0]} : {4'hz, t[23:12]};
endfunction
localparam int CL = 18, CWL = 7;
localparam int IRQ_RD_DONE = IRQ_DONE;
`define MEM_DEV_RD (`G7_RD && !(addr[12] && dut.u_core.pam3))   // PAM3 lines: gddr7_pam3_dev.svh
`define MEM_DEV_WR (`G7_WR && !(addr[12] && dut.u_core.pam3))
`define MEM_DEV_LINE addr[12]
`define MEM_DEV_CL dut.u_core.cl_now
`define MEM_DEV_CWL dut.u_core.cwl_now
`define MEM_DEV_DQS dqs
`define MEM_DEV_CH(a) int'(a[8])
`define MEM_DEV_BEATS 2
`define MEM_DEV_BEAT(w, k) (dut.u_core.pam3 ? pam3_beat(w, k) : (w))
`define MEM_LINE
`define G7_RD (!cs_n && act_n && {ras_n, cas_n, we_n} == 3'b101)
`define G7_WR (!cs_n && act_n && {ras_n, cas_n, we_n} == 3'b100)
`define G7_CLK PCLK
`define G7_CORE dut.u_core
`include "apb/mem_apb_common.svh"
`include "gddr7_pam3_dev.svh"
task automatic ip_func; mem_func(); endtask
