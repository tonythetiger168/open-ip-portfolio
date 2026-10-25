// SPDX-License-Identifier: Apache-2.0
// LPDDR7 TB: adaptive-page mobile controller (bank = {haddr[8] channel,
// haddr[10:9]}, row = haddr[31:18], storage = 256 columns per channel); a
// cold bank (hit count 0) that misses is auto-closed after its burst;
// per-bank refresh; commands leave as framed beats on the 8-bit CA bus.
// Shared host tests in mem_tb_common.svh; the checker tb/cov/LPDDR7_sva.sv
// checks every pin.
`timescale 1ns/1ps
module LPDDR7_tb;
  logic clk = 0, rst_n = 0;
  logic hvalid, hready;
  logic [2:0] hcmd;
  logic [31:0] haddr;
  logic [15:0] hwdata, hrdata;
  logic hdone;
  logic ck_t, ck_c;
  logic [7:0] ca; logic cs_n;
  tri [31:0] dq; tri [1:0] dqs; logic cke;
  logic trace_valid; logic [2:0] trace_cmd; logic [31:0] trace_addr;
  int errors = 0;

  LPDDR7_top dut (.*);
  always #5 clk = ~clk;

  localparam int NCH = 2, NBU = 8, ROWW = 14, REFI = 1560;
  `define REFCNT dut.ref_cnt
  function automatic logic [31:0] mk(input int b, input logic [13:0] row, input logic [7:0] col);
    mk = $urandom;
    mk[31:18] = row; mk[8] = b[2]; mk[10:9] = b[1:0]; mk[7:0] = col;
  endfunction
  function automatic int cellof(input logic [31:0] a);
    cellof = {a[8], a[7:0]};
  endfunction
  task automatic ip_extra;
    logic [31:0] a;
    // walk a bank's hit count: cold miss (auto-closed), ACT then ACT to the
    // open row (a hit, no pin traffic), hits up to hot, a warm miss (stays
    // open), an ACT conflict (miss evidence)
    for (int k = 0; k < 2; k++) begin
      near_refresh(REFI / 2);
      a = mk(k, 14'h0A0, 8'h10);
      pre(a); rd(a);
      act(a); act(a);
      rd(a); wr(a, 16'h7000 + 16'(k)); rd(a); rd(a); act(a);
      near_refresh(REFI / 2);
      rd(mk(k, 14'h0A1, 8'h10)); rd(mk(k, 14'h0A1, 8'h11));
      act(mk(k, 14'h0A2, 0)); wr(mk(k, 14'h0A3, 8'h12), 16'h0BAD);
      // a miss at count 1 is warm too
      pre(a); act(a); act(a); rd(mk(k, 14'h0A4, 8'h13)); rd(mk(k, 14'h0A4, 8'h13));
    end
    // refreshes while idle with every bank closed
    for (int b = 0; b < NBU; b++) pre(mk(b, 0, 0));
    for (int k = 0; k < 3; k++) begin near_refresh(1); idle(300); end
    // ACT the bank the next REF targets just before it falls due: the
    // refresh PRE must then wait out that bank's tRAS
    for (int k = 0; k < 3; k++) begin
      near_refresh(4); act(mk(int'(dut.ref_bank), 14'h123, 0)); idle(60);
    end
  endtask

  `include "mem_tb_common.svh"

  initial begin
    repeat (800) #10000;
    $display("TIMEOUT"); $finish;
  end
endmodule
