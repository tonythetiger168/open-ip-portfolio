// SPDX-License-Identifier: Apache-2.0
// HBM3E TB: on-die-ECC controller (256 page entries {channel haddr[10:8],
// pc/bank haddr[15:11]}, row = haddr[31:18], storage = 256 SEC codewords per
// channel); bits of stored codewords are flipped through a backdoor and the
// reads must still return the written data.
// Shared host tests in mem_tb_common.svh; the checker tb/cov/HBM3E_sva.sv
// checks every pin.
`timescale 1ns/1ps
module HBM3E_tb;
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

  HBM3E_top dut (.*);
  always #5 clk = ~clk;

  localparam int NCH = 8, NBU = 256, ROWW = 14, REFI = 1560;
  `define REFCNT dut.ref_cnt
  function automatic logic [31:0] mk(input int b, input logic [13:0] row, input logic [7:0] col);
    mk = $urandom;
    mk[31:18] = row; mk[10:8] = b[7:5]; mk[15:11] = b[4:0]; mk[7:0] = col;
  endfunction
  function automatic int cellof(input logic [31:0] a);
    cellof = {a[10:8], a[7:0]};
  endfunction
  // single-bit upset of a stored codeword (backdoor, like a cell flip)
  task automatic flip(input logic [31:0] a, input int p);
    int c;
    c = cellof(a);
    dut.mem[c][p] = ~dut.mem[c][p];
  endtask
  task automatic ip_extra;
    logic [31:0] a;
    // every one of the 21 codeword positions (data and check bits), on
    // several data patterns, is corrected on the read
    for (int k = 0; k < 4; k++) begin
      a = mk(8 * k + 3, 14'h300, 8'(40 + k));
      near_refresh(REFI / 2);
      wr(a, (k == 0) ? 16'h0000 : (k == 1) ? 16'hFFFF : (k == 2) ? 16'hA5C3 : 16'h5A3C);
      quiesce();                       // the WR has reached the array
      for (int p = 0; p < 21; p++) begin
        flip(a, p); rd(a); flip(a, p);
        if (p % 7 == 6) near_refresh(REFI / 2);
      end
    end
    for (int b = 0; b < 8; b++) act(mk(b, 14'h100 + 14'(b), 0));
    for (int k = 0; k < 10; k++) begin
      near_refresh(REFI / 2); rd(mk(k % 8, 14'h100 + 14'(k % 8), 8'(k)));
    end
    for (int b = 0; b < NBU; b++) pre(mk(b, 0, 0));
    for (int k = 0; k < 3; k++) begin near_refresh(1); idle(10); end
    // ACT the entry the next REF targets just before it falls due: the
    // refresh PRE must then wait out that entry's tRAS
    for (int k = 0; k < 3; k++) begin
      near_refresh(4); act(mk(int'(dut.ref_bank), 14'h123, 0)); idle(60);
    end
    // walk the refresh pointer through all 256 entries (and wrap)
    idle(REFI * 260);
  endtask

  `include "mem_tb_common.svh"

  initial begin
    repeat (6000) #10000;
    $display("TIMEOUT"); $finish;
  end
endmodule
