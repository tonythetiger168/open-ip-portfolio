// SPDX-License-Identifier: Apache-2.0
// LPDDR5 TB: dual-rank mobile controller (bank = {haddr[17] rank, haddr[8]
// channel, haddr[10:9]}, row = haddr[31:18], storage = 256 columns per
// rank and channel), per-bank refresh over all 16; commands leave as framed
// beats on the 7-bit CA bus.
// Shared host tests in mem_tb_common.svh; the checker tb/cov/LPDDR5_sva.sv
// checks every pin.
`timescale 1ns/1ps
module LPDDR5_tb;
  logic clk = 0, rst_n = 0;
  logic hvalid, hready;
  logic [2:0] hcmd;
  logic [31:0] haddr;
  logic [15:0] hwdata, hrdata;
  logic hdone;
  logic ck_t, ck_c;
  logic [6:0] ca; logic cs_n;
  tri [31:0] dq; tri [1:0] dqs; logic cke;
  logic trace_valid; logic [2:0] trace_cmd; logic [31:0] trace_addr;
  int errors = 0;

  LPDDR5_top dut (.*);
  always #5 clk = ~clk;

  localparam int NCH = 2, NBU = 16, ROWW = 14, REFI = 1560;
  `define REFCNT dut.ref_cnt
  function automatic logic [31:0] mk(input int b, input logic [13:0] row, input logic [7:0] col);
    mk = $urandom;
    mk[31:18] = row; mk[17] = b[3]; mk[8] = b[2]; mk[10:9] = b[1:0]; mk[7:0] = col;
  endfunction
  function automatic int cellof(input logic [31:0] a);
    cellof = {a[17], a[8], a[7:0]};
  endfunction
  task automatic ip_extra;
    // the two ranks are separate devices: same channel / bank / row /
    // column in rank 0 and rank 1 hold different words
    for (int k = 0; k < 4; k++) begin
      near_refresh(REFI / 2);
      wr(mk(k, 14'h0C0, 8'(k + 9)), 16'(16'h1100 + k));
      wr(mk(8 + k, 14'h0C0, 8'(k + 9)), 16'(16'h2200 + k));
      rd(mk(k, 14'h0C0, 8'(k + 9))); rd(mk(8 + k, 14'h0C0, 8'(k + 9)));
    end
    // ACT the bank the next REF targets just before it falls due: the
    // refresh PRE must then wait out that bank's tRAS
    for (int k = 0; k < 3; k++) begin
      near_refresh(4); act(mk(int'(dut.ref_bank), 14'h123, 0)); idle(60);
    end
    // walk the refresh pointer through all 16 banks (and wrap)
    idle(REFI * 18);
  endtask

  `include "mem_tb_common.svh"

  initial begin
    repeat (1200) #10000;
    $display("TIMEOUT"); $finish;
  end
endmodule
