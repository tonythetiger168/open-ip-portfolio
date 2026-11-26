// SPDX-License-Identifier: Apache-2.0
// DDR6 TB: closed-page controller (banks = {haddr[8], haddr[10:9]}, row =
// haddr[31:18], storage = 256 columns per channel); every RD / WR closes
// its bank with a PRE after the burst.
// Shared host tests in mem_tb_common.svh; the checker tb/cov/DDR6_sva.sv
// checks every pin.
`timescale 1ns/1ps
`ifndef VERILATOR
`include "DDR6_sva.sv"
`define MEM_SVA DDR6_sva
`endif
module DDR6_tb;
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

  DDR6_top dut (.*);
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
  task automatic ip_extra; endtask

  // DRAM device (tb/mem_dev.svh): the core keeps no array of its own
  `define MEM_DEV_RD ({ras_n, cas_n, we_n} == 3'b101)
  `define MEM_DEV_WR ({ras_n, cas_n, we_n} == 3'b100)
  `define MEM_DEV_CL 26
  `define MEM_DEV_CH(a) int'(a[8])
  `include "mem_tb_common.svh"

  initial begin
`ifdef MEM_PERF
    repeat (20000) #10000;   // performance run (tb/perf)
`else
    repeat (400) #10000;
`endif
    $display("TIMEOUT"); $finish;
  end
endmodule
