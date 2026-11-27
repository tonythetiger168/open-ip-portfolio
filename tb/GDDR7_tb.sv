// SPDX-License-Identifier: Apache-2.0
// GDDR7 TB: PAM3 graphics controller (banks = {haddr[8], haddr[10:9]}, row =
// haddr[31:18], 256 columns per channel); read data returns on dq as PAM3
// symbols over two beats, driven by the DRAM device (tb/mem_dev.svh); line
// commands (RDL / WRL: BL8 NRZ, or BL6 PAM3 symbols on {dqx, dq}) and the
// MR file (CL / CWL / PAM3).
// Shared host tests in mem_tb_common.svh; the checker tb/cov/GDDR7_sva.sv
// checks every pin.
`timescale 1ns/1ps
`ifndef VERILATOR
`include "GDDR7_sva.sv"
`define MEM_SVA GDDR7_sva
`endif
module GDDR7_tb;
  logic clk = 0, rst_n = 0;
  logic hvalid, hready;
  logic [2:0] hcmd;
  logic [31:0] haddr;
  logic [15:0] hwdata, hrdata;
  logic [127:0] rdline;
  logic hdone, pam3;
  logic ck_t, ck_c;
  logic [16:0] addr; logic ras_n, cas_n, we_n, cs_n, act_n; logic [2:0] ba;
  tri [31:0] dq, dqx; tri [1:0] dqs; logic cke;
  logic trace_valid; logic [2:0] trace_cmd; logic [31:0] trace_addr;
  int errors = 0;

  GDDR7_top dut (.*);
  always #5 clk = ~clk;

  localparam int NCH = 2, NBU = 8, ROWW = 14, REFI = 3900;
  `define REFCNT dut.ref_cnt
  function automatic logic [31:0] mk(input int b, input logic [13:0] row, input logic [7:0] col);
    mk = $urandom;
    mk[31:18] = row; mk[8] = b[2]; mk[10:9] = b[1:0]; mk[7:0] = col;
  endfunction
  function automatic int cellof(input logic [31:0] a);
    cellof = {a[8], a[7:0]};
  endfunction

  // DRAM device (tb/mem_dev.svh): the core keeps no array of its own. A read
  // word goes out as 12 PAM3 symbols on dq[11:0] of the channel, nibbles 0-1
  // in the clock before hdone, nibbles 2-3 in the hdone clock
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
  // PAM3 lines are played by the block below, the rest by tb/mem_dev.svh
  `define G7_RD (!cs_n && act_n && {ras_n, cas_n, we_n} == 3'b101)
  `define G7_WR (!cs_n && act_n && {ras_n, cas_n, we_n} == 3'b100)
  `define MEM_DEV_RD (`G7_RD && !(addr[12] && dut.pam3))
  `define MEM_DEV_WR (`G7_WR && !(addr[12] && dut.pam3))
  `define MEM_DEV_LINE addr[12]
  `define MEM_DEV_CL dut.cl_now
  `define MEM_DEV_CWL dut.cwl_now
  `define MEM_DEV_DQS dqs
  `define MEM_DEV_CH(a) int'(a[8])
  `define MEM_DEV_BEATS 2
  `define MEM_DEV_BEAT(w, k) (dut.pam3 ? pam3_beat(w, k) : (w))
  `define MEM_LINE
  `define MEM_MR_RESET tb_mr[2] = 8'h01;
  `include "mem_tb_common.svh"

  // every nibble value through the PAM3 read path; every nibble value
  // through a PAM3 line burst in both directions; then the line tests and
  // word reads again with PAM2 (MR2[0] = 0)
  task automatic ip_extra;
    logic [31:0] a;
    for (int v = 0; v < 16; v++) begin
      wr(mk(v % NBU, 14'h40, 8'h80 + 8'(v)), {4'(v), 4'(15 - v), 4'(v), 4'(15 - v)});
      rd(mk(v % NBU, 14'h40, 8'h80 + 8'(v)));
    end
    for (int v = 0; v < 16; v++) begin
      for (int k = 0; k < 8; k++) lw_buf[k] = {4'(v), 4'(15 - v), 4'(v + k), 4'(15 - v - k)};
      a = mk(v % NBU, 14'h41, 8'(v * 8));
      wrl(a, 0); rdl(a);
    end
    mrw(2, 8'h00); mrr(2);                       // PAM2
    line_tests();
    for (int v = 0; v < 16; v++) begin
      wr(mk(v % NBU, 14'h42, 8'h80 + 8'(v)), {4'(v), 4'(15 - v), 4'(v), 4'(15 - v)});
      rd(mk(v % NBU, 14'h42, 8'h80 + 8'(v)));
    end
    mrw(2, 8'hFE); mrr(2); mrw(2, 8'h01); mrr(2);  // back to PAM3
  endtask

  `include "gddr7_pam3_dev.svh"

  initial begin
`ifdef MEM_PERF
    repeat (20000) #10000;   // performance run (tb/perf)
`else
    repeat (400) #10000;
`endif
    $display("TIMEOUT"); $finish;
  end
endmodule
