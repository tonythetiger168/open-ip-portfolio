// SPDX-License-Identifier: Apache-2.0
// DDR4 TB: 4-bank open-page controller (banks = haddr[10:9], row =
// haddr[31:18], 256 columns), with line commands (RDL / WRL: one BL8 burst
// of 8 columns) and the MR file (CL / CWL). Shared host tests in mem_tb_common.svh; the
// DRAM device (the array) is tb/mem_dev.svh; the checker tb/cov/DDR4_sva.sv
// checks every pin.
`timescale 1ns/1ps
`ifndef VERILATOR
`include "DDR4_sva.sv"
`define MEM_SVA DDR4_sva
`endif
module DDR4_tb;
  logic clk = 0, rst_n = 0;
  logic hvalid, hready;
  logic [2:0] hcmd;
  logic [31:0] haddr;
  logic [15:0] hwdata, hrdata;
  logic [127:0] rdline;
  logic hdone;
  logic ck_t, ck_c;
  logic [16:0] addr; logic ras_n, cas_n, we_n, cs_n, act_n; logic [1:0] ba;
  tri [15:0] dq; tri [1:0] dqs; logic cke;
  logic trace_valid; logic [2:0] trace_cmd; logic [31:0] trace_addr;
  int errors = 0;

  DDR4_top dut (.*);
  always #5 clk = ~clk;

  localparam int NCH = 1, NBU = 4, ROWW = 14, REFI = 6240;
  `define REFCNT dut.ref_cnt
  function automatic logic [31:0] mk(input int b, input logic [13:0] row, input logic [7:0] col);
    mk = $urandom;
    mk[31:18] = row; mk[10:9] = b[1:0]; mk[7:0] = col;
  endfunction
  function automatic int cellof(input logic [31:0] a);
    cellof = a[7:0];
  endfunction
  task automatic ip_extra; endtask
  localparam int CL = 15, CWL = 11;
  `define MEM_DEV_RD (!cs_n && act_n && {ras_n, cas_n, we_n} == 3'b101)
  `define MEM_DEV_WR (!cs_n && act_n && {ras_n, cas_n, we_n} == 3'b100)
  `define MEM_DEV_LINE addr[12]
  `define MEM_DEV_CL dut.cl_now
  `define MEM_DEV_CWL dut.cwl_now
  `define MEM_DEV_DQS dqs
  `define MEM_LINE

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
