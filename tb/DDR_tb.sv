// SPDX-License-Identifier: Apache-2.0
// DDR TB: legacy dual-bank controller (bank = haddr[8], row = haddr[31:18],
// storage = 256 columns); RD / WR use the bank's open row.
// Shared host tests in mem_tb_common.svh; the checker tb/cov/DDR_sva.sv
// checks every pin.
`timescale 1ns/1ps
module DDR_tb;
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

  DDR_top dut (.*);
  always #5 clk = ~clk;

  localparam int NCH = 1, NBU = 2, ROWW = 14, REFI = 3120;
  `define REFCNT dut.ref_cnt
  function automatic logic [31:0] mk(input int b, input logic [13:0] row, input logic [7:0] col);
    mk = $urandom;
    mk[31:18] = row; mk[8] = b[0]; mk[7:0] = col;
  endfunction
  function automatic int cellof(input logic [31:0] a);
    cellof = a[7:0];
  endfunction
  // RD / WR to an open bank with another row in haddr use the open row
  task automatic ip_extra;
    act(mk(1, 14'h0AA, 0)); wr(mk(1, 14'h155, 8'h61), 16'h6161); rd(mk(1, 14'h3FFF, 8'h61));
  endtask

  `include "mem_tb_common.svh"

  initial begin
    repeat (400) #10000;
    $display("TIMEOUT"); $finish;
  end
endmodule
