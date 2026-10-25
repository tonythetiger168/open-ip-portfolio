// SPDX-License-Identifier: Apache-2.0
// HBM2 TB: pseudo-channel controller (64 page entries {channel haddr[10:8],
// pc haddr[13:11]}, row = haddr[31:18], storage = 256 columns per channel;
// RD / WR use the pc's open row); per-entry refresh over all 64.
// Shared host tests in mem_tb_common.svh; the checker tb/cov/HBM2_sva.sv
// checks every pin.
`timescale 1ns/1ps
module HBM2_tb;
  logic clk = 0, rst_n = 0;
  logic hvalid, hready;
  logic [2:0] hcmd;
  logic [31:0] haddr;
  logic [15:0] hwdata, hrdata;
  logic hdone;
  logic ck_t, ck_c;
  logic [16:0] addr; logic ras_n, cas_n, we_n;
  tri [127:0] dq; tri [1:0] dqs; logic cke;
  logic trace_valid; logic [2:0] trace_cmd; logic [31:0] trace_addr;
  int errors = 0;

  HBM2_top dut (.*);
  always #5 clk = ~clk;

  localparam int NCH = 8, NBU = 64, ROWW = 14, REFI = 1560;
  `define REFCNT dut.ref_cnt
  function automatic logic [31:0] mk(input int b, input logic [13:0] row, input logic [7:0] col);
    mk = $urandom;
    mk[31:18] = row; mk[10:8] = b[5:3]; mk[13:11] = b[2:0]; mk[7:0] = col;
  endfunction
  function automatic int cellof(input logic [31:0] a);
    cellof = {a[10:8], a[7:0]};
  endfunction
  // pages stay open in neighbouring pcs across per-entry refreshes; RD / WR
  // to an open pc with another row in haddr use the open row
  task automatic ip_extra;
    for (int b = 0; b < 8; b++) act(mk(b, 14'h100 + 14'(b), 0));
    for (int k = 0; k < 10; k++) begin
      near_refresh(REFI / 2); rd(mk(k % 8, 14'h3FFF, 8'(k)));
    end
    for (int b = 0; b < NBU; b++) pre(mk(b, 0, 0));
    for (int k = 0; k < 3; k++) begin near_refresh(1); idle(10); end
  endtask

  `include "mem_tb_common.svh"

  initial begin
    repeat (400) #10000;
    $display("TIMEOUT"); $finish;
  end
endmodule
