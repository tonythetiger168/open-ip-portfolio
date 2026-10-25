// SPDX-License-Identifier: Apache-2.0
// GDDR5 TB: graphics controller with a tWTR fence (banks = haddr[11:9],
// row = haddr[31:18], storage = 256 columns): a RD waits tWTR after the
// end of a write burst to its bank.
// Shared host tests in mem_tb_common.svh; the checker tb/cov/GDDR5_sva.sv
// checks every pin.
`timescale 1ns/1ps
module GDDR5_tb;
  logic clk = 0, rst_n = 0;
  logic hvalid, hready;
  logic [2:0] hcmd;
  logic [31:0] haddr;
  logic [15:0] hwdata, hrdata;
  logic hdone;
  logic ck_t, ck_c;
  logic [16:0] addr; logic ras_n, cas_n, we_n;
  tri [15:0] dq; tri [1:0] dqs; logic cke;
  logic trace_valid; logic [2:0] trace_cmd; logic [31:0] trace_addr;
  int errors = 0;

  GDDR5_top dut (.*);
  always #5 clk = ~clk;

  localparam int NCH = 1, NBU = 8, ROWW = 14, REFI = 3900;
  `define REFCNT dut.ref_cnt
  function automatic logic [31:0] mk(input int b, input logic [13:0] row, input logic [7:0] col);
    mk = $urandom;
    mk[31:18] = row; mk[11:9] = b[2:0]; mk[7:0] = col;
  endfunction
  function automatic int cellof(input logic [31:0] a);
    cellof = a[7:0];
  endfunction
  // RD right behind a WR to the same bank waits out tWTR; another bank does not
  task automatic ip_extra;
    act(mk(3, 7, 0)); act(mk(4, 7, 0));
    for (int i = 0; i < 4; i++) begin wr(mk(3, 7, 8'(i)), 16'(i)); rd(mk(3, 7, 8'(i))); end
    wr(mk(3, 7, 8'h10), 16'h1010); rd(mk(4, 7, 8'h10));
  endtask

  `include "mem_tb_common.svh"

  initial begin
    repeat (400) #10000;
    $display("TIMEOUT"); $finish;
  end
endmodule
