// SPDX-License-Identifier: Apache-2.0
// GDDR6 TB: dual-width graphics controller (banks = {haddr[8], haddr[10:9]},
// row = haddr[31:18], storage = 256 columns per channel); a WR to column
// 0xF2 is the x8 / x16 mode mailbox (no DRAM traffic). Regular traffic
// avoids column 0xF2; x8 writes store the low byte only.
// Shared host tests in mem_tb_common.svh; the checker tb/cov/GDDR6_sva.sv
// checks every pin.
`timescale 1ns/1ps
module GDDR6_tb;
  logic clk = 0, rst_n = 0;
  logic hvalid, hready;
  logic [2:0] hcmd;
  logic [31:0] haddr;
  logic [15:0] hwdata, hrdata;
  logic hdone;
  logic ck_t, ck_c;
  logic [16:0] addr; logic ras_n, cas_n, we_n;
  tri [31:0] dq; tri [1:0] dqs; logic cke;
  logic trace_valid; logic [2:0] trace_cmd; logic [31:0] trace_addr;
  int errors = 0;

  GDDR6_top dut (.*);
  always #5 clk = ~clk;

  localparam int NCH = 2, NBU = 8, ROWW = 14, REFI = 3900;
  `define REFCNT dut.ref_cnt
  function automatic logic [31:0] mk(input int b, input logic [13:0] row, input logic [7:0] col);
    mk = $urandom;
    mk[31:18] = row; mk[8] = b[2]; mk[10:9] = b[1:0]; mk[7:0] = (col == 8'hF2) ? 8'hF3 : col;
  endfunction
  function automatic int cellof(input logic [31:0] a);
    cellof = {a[8], a[7:0]};
  endfunction
  // width mailbox: x8 writes keep the upper byte; back to x16
  task automatic mailbox(input bit x8);
    logic [31:0] m;
    m = $urandom; m[7:0] = 8'hF2;
    cmd(3'd3, m, {15'($urandom), x8});
  endtask
  task automatic ip_extra;
    logic [31:0] a;
    int c;
    a = mk(5, 14'h33, 8'h44); c = cellof(a);
    wr(a, 16'hABCD);
    mailbox(1);
    cmd(3'd3, a, 16'h1234); sb[c][7:0] = 8'h34;
    rd(a);
    for (int i = 0; i < 8; i++) begin
      a = mk(i, rrow(), 8'(i)); c = cellof(a);
      cmd(3'd3, a, ~16'(i)); sb[c][7:0] = ~8'(i); sbv[c] = 1;
      rd(a);
    end
    a = mk(5, 14'h33, 8'h44);
    cmd(3'd3, a, 16'h00FF); sb[cellof(a)][7:0] = 8'hFF; rd(a);
    cmd(3'd3, a, 16'hFF00); sb[cellof(a)][7:0] = 8'h00; rd(a);
    mailbox(0);
    wr(a, 16'h5678); rd(a);
  endtask

  `include "mem_tb_common.svh"

  initial begin
    repeat (400) #10000;
    $display("TIMEOUT"); $finish;
  end
endmodule
