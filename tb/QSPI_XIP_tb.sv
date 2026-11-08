// SPDX-License-Identifier: Apache-2.0
// Self-checking core testbench of QSPI_XIP_top against tb/spi_nor_model.svh
// (a behavioural quad-SPI NOR flash with 64 KB of random contents).
// - XIP: 400 random AXI4 read bursts (INCR / FIXED / WRAP, 1..16 beats,
//   AxSIZE 0..2, random IDs) with random RREADY stalls, in quad (0x6B) and
//   single (0x0B) mode at DIV 0..3; every beat is compared with the flash
//   bytes of its word, RID / RLAST / RRESP checked.
// - Stream reuse: a run of bursts at consecutive words issues one read
//   command (XIP_CMDS), and every beat is counted (XIP_BEATS).
// - Command port: JEDEC ID (0x9F), write enable + read status (WEL), page
//   program of 4 bytes (ANDed into the array, read back by XIP), sector
//   erase (0xFF by XIP); commands while the XIP stream is open close it.
// - AXI writes: SLVERR. The flash model checks IO contention, commands with
//   bits not driven and program / erase without WEL.
// - Every burst's latency (AR to RLAST) is printed as "LAT tb QSPI_XIP R <c>".
`timescale 1ns/1ps
`include "spi_nor_model.svh"
module QSPI_XIP_tb;
  logic clk = 0, rst_n = 0;
  always #5 clk = ~clk;
  int errors = 0;
  function automatic void fail(input string m);
    errors++;
    $display("ERROR: %s @%0t", m, $time);
  endfunction
  task automatic clks(input int n); repeat (n) @(negedge clk); endtask

  wire        sclk, csn;
  wire  [3:0] io;
  pullup (io[0]); pullup (io[1]); pullup (io[2]); pullup (io[3]);
  logic [7:0]  div = 1;
  logic        quad = 1;
  logic [7:0]  pc_cmd = 0;
  logic        pc_has_addr = 0, pc_start = 0;
  logic [23:0] pc_addr = 0;
  logic [2:0]  pc_nwr = 0, pc_nrd = 0;
  logic [31:0] pc_wdata = 0;
  wire  [31:0] pc_rdata;
  wire         pc_busy, pc_done;
  wire  [15:0] xip_cmds, xip_beats;
  logic [3:0]  s_awid = 0, s_arid = 0;
  logic [31:0] s_awaddr = 0, s_araddr = 0, s_wdata = 0;
  logic [7:0]  s_awlen = 0, s_arlen = 0;
  logic [2:0]  s_awsize = 2, s_arsize = 2;
  logic [1:0]  s_awburst = 1, s_arburst = 1;
  logic        s_awvalid = 0, s_wvalid = 0, s_wlast = 0, s_bready = 0, s_arvalid = 0, s_rready = 0;
  logic [3:0]  s_wstrb = 4'hF;
  wire         s_awready, s_wready, s_bvalid, s_arready, s_rvalid, s_rlast;
  wire  [3:0]  s_bid, s_rid;
  wire  [1:0]  s_bresp, s_rresp;
  wire  [31:0] s_rdata;
  QSPI_XIP_top dut (.*);
  spi_nor_model flash (.sclk, .csn, .io);

  int unsigned cyc = 0;
  always @(posedge clk) cyc++;
  int n_beats = 0;

  function automatic logic [31:0] beat_addr(input logic [31:0] start, input int sz, input int bt,
                                            input int len, input int n);
    longint unsigned nb, aligned, lower, wsize, a;
    nb = 64'd1 << sz;
    aligned = (start / nb) * nb;
    if (bt == 0 || n == 0) return start;
    if (bt == 1) return 32'(aligned + 64'(n) * nb);
    wsize = nb * 64'(len + 1);
    lower = (64'(start) / wsize) * wsize;
    a = aligned + 64'(n) * nb;
    if (a >= lower + wsize) a = a - wsize;
    return 32'(a);
  endfunction
  function automatic logic [31:0] fword(input logic [31:0] a);
    logic [15:0] w;
    w = {a[15:2], 2'b00};
    return {flash.mem[w + 16'd3], flash.mem[w + 16'd2], flash.mem[w + 16'd1], flash.mem[w]};
  endfunction

  task automatic rd(input logic [31:0] a, input int len, input int sz, input int bt);
    logic [3:0] id;
    int t0;
    id = $urandom;
    @(negedge clk);
    s_arid = id; s_araddr = a; s_arlen = 8'(len); s_arsize = 3'(sz); s_arburst = 2'(bt); s_arvalid = 1;
    t0 = cyc;
    @(posedge clk); while (!s_arready) @(posedge clk);
    @(negedge clk); s_arvalid = 0;
    for (int n = 0; n <= len; n++) begin
      logic [31:0] ba, e;
      if ($urandom % 3 == 0) begin s_rready = 0; repeat ($urandom % 40) @(negedge clk); end
      s_rready = 1;
      @(posedge clk); while (!s_rvalid) @(posedge clk);
      ba = beat_addr(a, sz, bt, len, n); e = fword(ba);
      if (s_rid !== id) fail("RID");
      if (s_rlast !== (n == len)) fail($sformatf("RLAST on beat %0d of %0d", n, len + 1));
      if (s_rresp !== 2'b00) fail("RRESP");
      if (s_rdata !== e) fail($sformatf("XIP %08h (beat %0d, size %0d, burst %0d): %h, expected %h", ba, n, sz, bt, s_rdata, e));
      n_beats++;
      if (n == len) $display("LAT tb QSPI_XIP R %0d", cyc - t0);
      @(negedge clk);
    end
    s_rready = 0;
  endtask

  task automatic pc(input logic [7:0] c, input bit ha, input logic [23:0] a, input int nwr,
                    input logic [31:0] wd, input int nrd);
    int t;
    @(negedge clk);
    pc_cmd = c; pc_has_addr = ha; pc_addr = a; pc_nwr = 3'(nwr); pc_wdata = wd; pc_nrd = 3'(nrd);
    pc_start = 1; @(negedge clk); pc_start = 0;
    t = 0;
    while (pc_busy && t < 100000) begin @(negedge clk); t++; end
    if (pc_busy) fail($sformatf("command %h timed out", c));
  endtask

  task automatic rnd_burst;
    int sz, bt, len;
    logic [31:0] a;
    sz = ($urandom % 4 == 0) ? $urandom % 2 : 2;
    bt = $urandom % 3;
    len = (bt == 2) ? (2 << ($urandom % 3)) - 1 : $urandom % 16;
    a = ($urandom & 32'h0000_FFFF) & ~((32'd1 << sz) - 1);
    if (bt == 1 && 32'(a[15:0]) + 32'((len + 1) << sz) > 32'h1_0000) a = 0;   // stay inside 64 KB
    rd(a, len, sz, bt);
  endtask

  initial begin
    for (int i = 0; i < 65536; i++) flash.mem[i] = $urandom;
    clks(3); rst_n = 1; clks(5);
    rd(32'h0000_0100, 3, 2, 1);
    rd(32'h0000_0110, 3, 2, 1);                            // continues the stream
    rd(32'h0000_0120, 0, 2, 1);
    if (xip_cmds != 1) fail($sformatf("XIP_CMDS %0d after three consecutive bursts", xip_cmds));
    for (int k = 0; k < 400; k++) begin
      if (k % 50 == 0) begin div = $urandom % 4; quad = (k / 50) % 2 == 0; end
      rnd_burst();
    end
    if (xip_beats != 16'(n_beats)) fail($sformatf("XIP_BEATS %0d, expected %0d", xip_beats, n_beats));
    // command port: ID, WEL, program, erase
    quad = 1; div = 1;
    pc(8'h9F, 0, 0, 0, 0, 3);
    if (pc_rdata !== 32'h0018_40EF) fail($sformatf("JEDEC ID %h", pc_rdata));
    rd(32'h0000_2000, 3, 2, 1);                           // stream open
    pc(8'h06, 0, 0, 0, 0, 0);
    pc(8'h05, 0, 0, 0, 0, 1);
    if (pc_rdata[1] !== 1'b1) fail("WEL low after write enable");
    begin
      logic [31:0] old, pd, e;
      old = fword(32'h0000_3004); pd = $urandom;
      pc(8'h02, 1, 24'h003004, 4, pd, 0);
      e = old & pd;
      rd(32'h0000_3004, 0, 2, 1);
      if (fword(32'h0000_3004) !== e) fail("page program did not AND the bytes in");
    end
    pc(8'h05, 0, 0, 0, 0, 1);
    if (pc_rdata[1] !== 1'b0) fail("WEL high after page program");
    pc(8'h06, 0, 0, 0, 0, 0);
    pc(8'h20, 1, 24'h005123, 0, 0, 0);
    rd(32'h0000_5000, 15, 2, 1);
    rd(32'h0000_5FC0, 15, 2, 1);
    if (fword(32'h0000_5000) !== 32'hFFFF_FFFF) fail("sector not erased");
    // AXI write: SLVERR
    @(negedge clk); s_awvalid = 1; s_awlen = 1;
    @(posedge clk); while (!s_awready) @(posedge clk);
    @(negedge clk); s_awvalid = 0; s_wvalid = 1; s_wlast = 0;
    @(posedge clk); while (!s_wready) @(posedge clk);
    @(negedge clk); s_wlast = 1;
    @(posedge clk); while (!s_wready) @(posedge clk);
    @(negedge clk); s_wvalid = 0; s_wlast = 0; s_bready = 1;
    @(posedge clk); while (!s_bvalid) @(posedge clk);
    if (s_bresp !== 2'b10) fail("AXI write not SLVERR");
    @(negedge clk); s_bready = 0;
    rnd_burst();
    clks(20);
    errors += flash.errors;
    $display("QSPI_XIP: %0d beats, %0d XIP read commands, %0d flash commands", n_beats, xip_cmds, flash.n_cmds);
    if (errors == 0) $display("TEST PASSED: QSPI_XIP");
    else $display("TEST FAILED: QSPI_XIP (%0d errors)", errors);
    $finish;
  end
  initial begin #200ms; fail("timeout"); $display("TEST FAILED: timeout"); $finish; end
endmodule
