// SPDX-License-Identifier: Apache-2.0
// LPDDR6 TB: bank-group mobile controller (bank = {haddr[8] channel,
// haddr[11:9]}, group = haddr[11], row = haddr[31:18], storage = 256
// columns per channel), group-aware tRRD, per-bank refresh over all 16;
// commands leave as framed beats on the 8-bit CA bus.
// Shared host tests in mem_tb_common.svh; the checker tb/cov/LPDDR6_sva.sv
// checks every pin.
`timescale 1ns/1ps
module LPDDR6_tb;
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

  LPDDR6_top dut (.*);
  always #5 clk = ~clk;

  localparam int NCH = 2, NBU = 16, ROWW = 14, REFI = 1560;
  `define REFCNT dut.ref_cnt
  function automatic logic [31:0] mk(input int b, input logic [13:0] row, input logic [7:0] col);
    mk = $urandom;
    mk[31:18] = row; mk[8] = b[3]; mk[11:9] = b[2:0]; mk[7:0] = col;
  endfunction
  function automatic int cellof(input logic [31:0] a);
    cellof = {a[8], a[7:0]};
  endfunction
  task automatic ip_extra;
    // back-to-back ACTs: same bank group (tRRD_L) then the other (tRRD_S)
    for (int k = 0; k < 4; k++) begin
      near_refresh(REFI / 2);
      act(mk(8 * (k % 2) + 0, 14'h200 + 14'(k), 0)); act(mk(8 * (k % 2) + 1, 14'h200 + 14'(k), 0));
      act(mk(8 * (k % 2) + 5, 14'h200 + 14'(k), 0)); act(mk(8 * (k % 2) + 2, 14'h200 + 14'(k), 0));
      wr(mk(8 * (k % 2) + 6, 14'h210, 8'(k)), 16'(k)); rd(mk(8 * (k % 2) + 3, 14'h210, 8'(k)));
    end
    // refreshes while idle with every bank closed
    for (int b = 0; b < NBU; b++) pre(mk(b, 0, 0));
    for (int k = 0; k < 3; k++) begin near_refresh(1); idle(300); end
    // ACT the bank the next REF targets just before it falls due: the
    // refresh PRE must then wait out that bank's tRAS
    for (int k = 0; k < 3; k++) begin
      near_refresh(4); act(mk(int'(dut.ref_bank), 14'h123, 0)); idle(60);
    end
    idle(REFI * 18);
  endtask

  `include "mem_tb_common.svh"

  initial begin
    repeat (1200) #10000;
    $display("TIMEOUT"); $finish;
  end
endmodule
