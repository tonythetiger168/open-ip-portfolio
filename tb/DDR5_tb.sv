// SPDX-License-Identifier: Apache-2.0
// DDR5 TB: bank-group controller (banks = {haddr[8], haddr[11:10]}, group = channel, row =
// haddr[31:18], storage = 256 columns per channel). Shared host tests in
// mem_tb_common.svh; the checker tb/cov/DDR5_sva.sv checks every pin.
`timescale 1ns/1ps
module DDR5_tb;
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

  DDR5_top dut (.*);
  always #5 clk = ~clk;

  localparam int NCH = 2, NBU = 8, ROWW = 14, REFI = 9360;
  `define REFCNT dut.ref_cnt
  function automatic logic [31:0] mk(input int b, input logic [13:0] row, input logic [7:0] col);
    mk = $urandom;
    mk[31:18] = row; mk[8] = b[2]; mk[11:10] = b[1:0]; mk[7:0] = col;
  endfunction
  function automatic int cellof(input logic [31:0] a);
    cellof = {a[8], a[7:0]};
  endfunction
  // back-to-back ACTs: same group (tRRD_L), other group (tRRD_S); a RD
  // right behind its ACT waits out tRCD
  task automatic ip_extra;
    for (int b = 0; b < NBU; b++) pre(mk(b, 0, 0));
    act(mk(0, 14'h10, 0)); act(mk(1, 14'h11, 0)); act(mk(4, 14'h12, 0)); act(mk(5, 14'h13, 0));
    act(mk(2, 14'h14, 0)); act(mk(6, 14'h15, 0)); act(mk(3, 14'h16, 0));
    rd(mk(3, 14'h16, 8'h40)); wr(mk(7, 14'h17, 8'h41), 16'h7777);
    act(mk(7, 14'h18, 0)); wr(mk(7, 14'h18, 8'h42), 16'h8888); rd(mk(7, 14'h18, 8'h42));
  endtask

  `include "mem_tb_common.svh"

  initial begin
    repeat (400) #10000;
    $display("TIMEOUT"); $finish;
  end
endmodule
