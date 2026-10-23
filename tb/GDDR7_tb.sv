// SPDX-License-Identifier: Apache-2.0
// GDDR7 TB: PAM3 graphics controller (banks = {haddr[8], haddr[10:9]}, row =
// haddr[31:18], storage = 256 columns per channel); read data returns on dq
// as PAM3 symbols over two beats.
// Shared host tests in mem_tb_common.svh; the checker tb/cov/GDDR7_sva.sv
// checks every pin.
`timescale 1ns/1ps
module GDDR7_tb;
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

  GDDR7_top dut (.*);
  always #5 clk = ~clk;

  localparam int NCH = 2, NBU = 8, ROWW = 14, REFI = 3900;
  `define REFCNT dut.ref_cnt
  function automatic logic [31:0] mk(input int b, input logic [13:0] row, input logic [7:0] col);
    mk = $urandom;
    mk[31:18] = row; mk[8] = b[2]; mk[10:9] = b[1:0]; mk[7:0] = col;
  endfunction
  function automatic int cellof(input logic [31:0] a);
    cellof = {a[8], a[7:0]};
  endfunction
  // every nibble value through the PAM3 read path
  task automatic ip_extra;
    for (int v = 0; v < 16; v++) begin
      wr(mk(v % NBU, 14'h40, 8'h80 + 8'(v)), {4'(v), 4'(15 - v), 4'(v), 4'(15 - v)});
      rd(mk(v % NBU, 14'h40, 8'h80 + 8'(v)));
    end
  endtask

  `include "mem_tb_common.svh"

  initial begin
    repeat (400) #10000;
    $display("TIMEOUT"); $finish;
  end
endmodule
