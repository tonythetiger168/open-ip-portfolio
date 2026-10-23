// SPDX-License-Identifier: Apache-2.0
// DDR7 TB: posted-write controller (banks = {haddr[8], haddr[10:9]}, row =
// haddr[31:18], storage = 256 columns per channel); WRs post into a 4-deep
// merge buffer and drain as real WR commands ahead of a RD or on overflow.
// Shared host tests in mem_tb_common.svh; the checker tb/cov/DDR7_sva.sv
// checks every pin.
`timescale 1ns/1ps
module DDR7_tb;
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

  DDR7_top dut (.*);
  always #5 clk = ~clk;

  localparam int NCH = 2, NBU = 8, ROWW = 14, REFI = 9360;
  `define REFCNT dut.ref_cnt
  function automatic logic [31:0] mk(input int b, input logic [13:0] row, input logic [7:0] col);
    mk = $urandom;
    mk[31:18] = row; mk[8] = b[2]; mk[10:9] = b[1:0]; mk[7:0] = col;
  endfunction
  function automatic int cellof(input logic [31:0] a);
    cellof = {a[8], a[7:0]};
  endfunction
  // buffer: merge, fill, overflow drains, RD drains everything (oldest
  // first, across banks / rows), and a final RD so nothing is left posted
  // before the reset test
  task automatic ip_extra;
    rd(mk(0, 0, 0));
    wr(mk(0, 14'h21, 8'h01), 16'h0101); wr(mk(0, 14'h22, 8'h01), 16'h0202);   // merge
    wr(mk(5, 14'h23, 8'h02), 16'h0303); wr(mk(2, 14'h24, 8'h03), 16'h0404);
    wr(mk(7, 14'h25, 8'h04), 16'h0505);                                     // full
    wr(mk(1, 14'h26, 8'h05), 16'h0606);                                     // overflow
    wr(mk(1, 14'h26, 8'h06), 16'h0707); wr(mk(6, 14'h27, 8'h07), 16'h0808);
    rd(mk(0, 14'h22, 8'h01)); rd(mk(7, 14'h25, 8'h04));
    for (int i = 0; i < 12; i++) wr(mk(i % NBU, rrow(), 8'(i)), 16'(i * 16'h1111));
    for (int i = 0; i < 12; i++) rd(mk(i % NBU, rrow(), 8'(i)));
    near_refresh(3); wr(mk(3, 1, 8'h30), 1); wr(mk(3, 2, 8'h31), 2); wr(mk(3, 3, 8'h32), 3);
    wr(mk(3, 4, 8'h33), 4); wr(mk(4, 5, 8'h34), 5); rd(mk(3, 1, 8'h30));
    wr(mk(2, 7, 8'h40), 7); near_refresh(30); rd(mk(2, 7, 8'h40));
    near_refresh(3); rd(mk(2, 7, 8'h40));            // refresh due in a plain RD
  endtask

  `include "mem_tb_common.svh"

  initial begin
    repeat (400) #10000;
    $display("TIMEOUT"); $finish;
  end
endmodule
