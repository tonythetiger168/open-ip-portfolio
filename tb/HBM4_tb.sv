// SPDX-License-Identifier: Apache-2.0
// HBM4 TB: two-level pseudo-channel controller (128 page entries {channel
// haddr[11:8], pc haddr[14:12]}, 2 pc-groups by haddr[14], row = haddr[31:18],
// storage = 256 columns per channel); group-aware tRRD; per-entry refresh.
// Shared host tests in mem_tb_common.svh; the checker tb/cov/HBM4_sva.sv
// checks every pin.
`timescale 1ns/1ps
module HBM4_tb;
  logic clk = 0, rst_n = 0;
  logic hvalid, hready;
  logic [2:0] hcmd;
  logic [31:0] haddr;
  logic [15:0] hwdata, hrdata;
  logic hdone;
  logic ck_t, ck_c;
  logic [16:0] addr; logic ras_n, cas_n, we_n;
  tri [255:0] dq; tri [1:0] dqs; logic cke;
  logic trace_valid; logic [2:0] trace_cmd; logic [31:0] trace_addr;
  int errors = 0;

  HBM4_top dut (.*);
  always #5 clk = ~clk;

  localparam int NCH = 16, NBU = 128, ROWW = 14, REFI = 1560;
  `define REFCNT dut.ref_cnt
  function automatic logic [31:0] mk(input int b, input logic [13:0] row, input logic [7:0] col);
    mk = $urandom;
    mk[31:18] = row; mk[11:8] = b[6:3]; mk[14:12] = b[2:0]; mk[7:0] = col;
  endfunction
  function automatic int cellof(input logic [31:0] a);
    cellof = {a[11:8], a[7:0]};
  endfunction
  task automatic ip_extra;
    // back-to-back ACTs: same pc-group (tRRD_L) then the other group (tRRD_S)
    for (int k = 0; k < 4; k++) begin
      near_refresh(REFI / 2);
      act(mk(8 * k + 0, 14'h200 + 14'(k), 0)); act(mk(8 * k + 1, 14'h200 + 14'(k), 0));
      act(mk(8 * k + 5, 14'h200 + 14'(k), 0)); act(mk(8 * k + 2, 14'h200 + 14'(k), 0));
      wr(mk(8 * k + 6, 14'h210, 8'(k)), 16'(k)); rd(mk(8 * k + 3, 14'h210, 8'(k)));
    end
    for (int b = 0; b < 8; b++) act(mk(b, 14'h100 + 14'(b), 0));
    for (int k = 0; k < 10; k++) begin
      near_refresh(REFI / 2); rd(mk(k % 8, 14'h100 + 14'(k % 8), 8'(k)));
    end
    for (int b = 0; b < NBU; b++) pre(mk(b, 0, 0));
    for (int k = 0; k < 3; k++) begin near_refresh(1); idle(10); end
    // walk the refresh pointer through all 128 entries (and wrap)
    idle(REFI * 70);
  endtask

  `include "mem_tb_common.svh"

  initial begin
    repeat (1200) #10000;
    $display("TIMEOUT"); $finish;
  end
endmodule
