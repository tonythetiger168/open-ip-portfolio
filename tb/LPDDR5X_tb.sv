// SPDX-License-Identifier: Apache-2.0
// LPDDR5X TB: DVFS mobile controller (bank = {haddr[8] channel, haddr[10:9]},
// row = haddr[31:18], storage = 256 columns per channel), per-bank refresh,
// FSP-OP mailbox (WR to column 0xF1: FSP0 CL 22 / FSP1 CL 14); commands
// leave as framed beats on the 7-bit CA bus. Regular traffic avoids 0xF1.
// Line commands (RDL / WRL, BL8 with dqs, WCK through line writes) and one
// MR set per FSP (CL = 10 + MR0[3:0], CWL = 5 + MR1[3:0]).
// Shared host tests in mem_tb_common.svh; the checker tb/cov/LPDDR5X_sva.sv
// checks every pin.
`timescale 1ns/1ps
`ifndef VERILATOR
`include "LPDDR5X_sva.sv"
`define MEM_SVA LPDDR5X_sva
`define MEM_SVA_INTERNAL
`endif
module LPDDR5X_tb;
  logic clk = 0, rst_n = 0;
  logic hvalid, hready;
  logic [2:0] hcmd;
  logic [31:0] haddr;
  logic [15:0] hwdata, hrdata;
  logic [127:0] rdline;
  logic hdone;
  logic ck_t, ck_c;
  logic [6:0] ca; logic cs_n, wck_t, wck_c;
  tri [31:0] dq; tri [1:0] dqs; logic cke;
  logic trace_valid; logic [2:0] trace_cmd; logic [31:0] trace_addr;
  int errors = 0;

  LPDDR5X_top dut (.*);
  always #5 clk = ~clk;

  localparam int NCH = 2, NBU = 8, ROWW = 14, REFI = 1560;
  `define REFCNT dut.ref_cnt
  function automatic logic [31:0] mk(input int b, input logic [13:0] row, input logic [7:0] col);
    mk = $urandom;
    mk[31:18] = row; mk[8] = b[2]; mk[10:9] = b[1:0]; mk[7:0] = (col == 8'hF1) ? 8'hF2 : col;
  endfunction
  function automatic int cellof(input logic [31:0] a);
    cellof = {a[8], a[7:0]};
  endfunction
  // FSP-OP mailbox (no DRAM traffic): switches the MR set
  bit tb_fsp = 0;
  localparam int CL = 22, CWL = 11;
  `define MEM_DEV_RD (!cs_n && ca[6:4] == 3'd2)
  `define MEM_DEV_WR (!cs_n && ca[6:4] == 3'd3)
  `define MEM_DEV_LINE ca[0]
  `define MEM_DEV_CL dut.cl_now
  `define MEM_DEV_CWL dut.cwl_now
  `define MEM_DEV_DQS dqs
  `define MEM_DEV_CH(a) int'(a[8])
  `define MEM_LINE
  `define MEM_MR_SET tb_fsp
  `define MEM_MR_RESET tb_mrs[0][0] = 8'd12; tb_mrs[1][0] = 8'd4; tb_mrs[1][1] = 8'(CWL - 5); tb_fsp = 0;
  `include "mem_tb_common.svh"
  task automatic fspop(input bit setb);
    logic [31:0] m;
    m = $urandom; m[7:0] = 8'hF1;
    cmd(3'd3, m, {15'($urandom), setb});
    tb_fsp = setb;
  endtask
  task automatic ip_extra;
    logic [31:0] a;
    // FSP1 (CL 14): misses, hits, writes, conflicts
    near_refresh(REFI / 2); fspop(1);
    for (int k = 0; k < 60; k++) begin
      a = rnd_addr();
      case ($urandom_range(0, 3))
        0: act(a);
        1: rd(a);
        2: wr(a, 16'($urandom));
        default: pre(a);
      endcase
    end
    for (int b = 0; b < NBU; b++) act(mk(b, 14'h2A0, 0));
    for (int b = 0; b < NBU; b++) rd(mk(b, 14'h2A0, 8'(b)));
    fspop(0);                              // back to FSP0
    for (int k = 0; k < 30; k++) begin a = rnd_addr(); rd(a); end
    // a mailbox write while a refresh is due waits for it
    near_refresh(1); fspop(1); fspop(0);
    // refreshes while idle with every bank closed
    for (int b = 0; b < NBU; b++) pre(mk(b, 0, 0));
    for (int k = 0; k < 3; k++) begin near_refresh(1); idle(300); end
    // ACT the bank the next REF targets just before it falls due: the
    // refresh PRE must then wait out that bank's tRAS
    for (int k = 0; k < 3; k++) begin
      near_refresh(4); act(mk(int'(dut.ref_bank), 14'h123, 0)); idle(60);
    end
    // the two MR sets are separate: FSP1 gets its own CL / CWL, lines run
    // on it, FSP0 keeps its values
    fspop(1); mrr(0); mrr(1);
    for (int i = 0; i < 8; i++) begin mrw(i, 8'hFF); mrr(i); mrw(i, 8'h00); mrr(i); end
    mrw(0, 8'h00); mrw(1, 8'h0F); mrr(0); mrr(1);
    for (int k = 0; k < 6; k++) begin
      a = mk(k % NBU, 14'h2B0, 8'(8 * k));
      rnd_line(); wrl(a, k % 2); rdl(a); rd(a);
    end
    mrw(1, 8'h02);                       // CWL 7
    for (int k = 0; k < 2; k++) begin a = mk(k, 14'h2B2, 8'(8 * k)); rnd_line(); wrl(a, 0); rdl(a); end
    wr(mk(3, 14'h2B2, 8'h10), 16'h1234); rd(mk(3, 14'h2B2, 8'h10));
    mrw(0, 8'h0F); mrw(1, 8'h00); mrr(0);
    for (int k = 0; k < 4; k++) begin a = mk(k, 14'h2B1, 8'(8 * k)); rnd_line(); wrl(a, 0); rdl(a); end
    fspop(0); mrr(0); mrr(1);
    fspop(1); mrw(0, 8'h04); mrw(1, 8'h06); fspop(0);   // back to the reset values
  endtask


  initial begin
`ifdef MEM_PERF
    repeat (20000) #10000;   // performance run (tb/perf)
`else
    repeat (800) #10000;
`endif
    $display("TIMEOUT"); $finish;
  end
endmodule
