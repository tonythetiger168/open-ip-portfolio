// SPDX-License-Identifier: Apache-2.0
// Self-checking core testbench of Interrupt_Controller_top (32 sources, CPU
// interrupt, AXI4 event log). Every clock: PENDING, CLAIM and cpu_irq are
// compared with a reference model of random irq_src / ENABLE / SW_SET. Event
// log: single rising sources give one record each, in order, with the right
// id, rising timestamps and ring wrap at LOG_WORDS; several sources rising
// together are written lowest id first; a source rising again while its
// record waits is merged; LOG_EN 0 writes nothing; an AXI write error sets
// LOG_ERR; reset in the middle of a record write.
`timescale 1ns/1ps
`include "soc_ss_axi_mem.svh"
module Interrupt_Controller_tb;
  `include "soc_ss_tb_common.svh"
  logic [31:0] irq_src = 0, enable = 0, sw_set = 0, log_base = 32'h8000_0F00;
  logic        log_en = 0;
  logic [15:0] log_words = 0;
  wire  [31:0] pending, claim;
  wire  [15:0] log_wp;
  wire         cpu_irq, log_err;
  Interrupt_Controller_top dut (.*);

  // combinational outputs, checked every clock (inputs change at negedges)
  always @(posedge clk) if (rst_n) begin
    logic [31:0] p, c;
    p = (irq_src | sw_set) & enable;
    c = 0;
    for (int i = 31; i >= 0; i--) if (p[i]) c = {1'b1, 26'd0, 5'(i)};
    if (pending !== p) fail($sformatf("PENDING %h, expected %h", pending, p));
    if (claim !== c) fail($sformatf("CLAIM %h, expected %h", claim, c));
    if (cpu_irq !== |p) fail("cpu_irq");
  end
  int n_log_err = 0;
  always @(posedge clk) if (rst_n) n_log_err += log_err;

  task automatic wait_wp(input int n);
    int t;
    t = 0;
    while (log_wp != 16'(n) && t < 2000) begin @(negedge clk); t++; end
    if (log_wp != 16'(n)) fail($sformatf("LOG_WP %0d, expected %0d", log_wp, n));
    clks(2);
  endtask
  function automatic logic [31:0] rec(input int n);
    return mem.peek(log_base + 32'(4 * (n % log_words)));
  endfunction
  function automatic logic [4:0] rid(input int n);   // id field of record n
    logic [31:0] r;
    r = rec(n);
    return r[4:0];
  endfunction
  function automatic logic [23:0] rts(input int n);  // timestamp of record n
    logic [31:0] r;
    r = rec(n);
    return r[31:8];
  endfunction

  initial begin
    int n;
    logic [23:0] last_ts;
    clks(3);
    rst_n = 1;
    clks(2);
    mem.rand_id = 1;   // the core ignores BID
    // routing, priority and masking
    for (int k = 0; k < 400; k++) begin
      @(negedge clk);
      irq_src = $urandom & $urandom; enable = $urandom | $urandom; sw_set = ($urandom % 4 == 0) ? 32'(1 << ($urandom % 32)) : 0;
      if (k % 50 == 0) begin irq_src = 0; sw_set = 0; end
      if (k % 50 == 1) enable = 32'hFFFF_FFFF;
    end
    irq_src = 0; sw_set = 0; enable = 0;
    clks(3);
    if (log_wp !== 0) fail("records written with LOG_EN 0");
    // event log: one source at a time, ring of 5 words
    enable = 32'hFFFF_FFFF; log_words = 5; log_en = 1;
    clks(2);
    n = 0; last_ts = 0;
    for (int k = 0; k < 14; k++) begin
      int id;
      id = (k == 0) ? 31 : (k == 1) ? 0 : $urandom % 32;
      @(negedge clk); irq_src[id] = 1;
      n++;
      wait_wp(n);
      if (rid(n - 1) !== 5'(id) || (rec(n - 1) & 32'hE0) !== 0) fail($sformatf("record %0d: %h, expected id %0d", n - 1, rec(n - 1), id));
      if (rts(n - 1) <= last_ts && k != 0) fail("timestamps not rising");
      last_ts = rts(n - 1);
      @(negedge clk); irq_src[id] = 0;
      if (k == 6) mem.stall = 0;
    end
    mem.stall = 1;
    // several sources together: lowest id first
    @(negedge clk); irq_src = 32'h8001_0410;
    wait_wp(n + 4);
    if (rid(n) !== 4 || rid(n + 1) !== 10 || rid(n + 2) !== 16 || rid(n + 3) !== 31)
      fail($sformatf("several sources: order %0d %0d %0d %0d", rid(n), rid(n + 1), rid(n + 2), rid(n + 3)));
    n += 4;
    @(negedge clk); irq_src = 0;
    // a source rising again while its record waits behind others is merged
    @(negedge clk); irq_src = 32'h0000_000F;
    @(negedge clk); irq_src = 32'h0000_0007;
    @(negedge clk); irq_src = 32'h0000_000F;   // source 3 rises again while waiting
    wait_wp(n + 4);
    clks(30);
    if (log_wp != 16'(n + 4)) fail("merged edge logged twice");
    n += 4;
    irq_src = 0;
    // software interrupt edges are logged too
    @(negedge clk); sw_set = 32'h0000_0100;
    wait_wp(n + 1);
    if (rid(n) !== 8) fail("SW_SET record");
    n++;
    sw_set = 0;
    // masked source: no record
    enable = 32'hFFFF_FFFE;
    @(negedge clk); irq_src = 1;
    clks(40);
    if (log_wp != 16'(n)) fail("masked source logged");
    irq_src = 0;
    enable = 32'hFFFF_FFFF;
    // AXI error on the record write
    mem.err_lo = log_base + 32'(4 * (n % log_words)); mem.err_hi = mem.err_lo + 4;
    @(negedge clk); irq_src = 32'h0000_2000;
    wait_wp(n + 1);
    if (n_log_err != 1) fail("LOG_ERR");
    n++;
    mem.err_lo = '1; mem.err_hi = '1;
    irq_src = 0;
    // LOG_EN 0 drops waiting records
    log_en = 0;
    @(negedge clk); irq_src = 32'h00F0_0000;
    clks(40);
    if (log_wp != 16'(n)) fail("records with LOG_EN 0");
    irq_src = 0;
    log_en = 1;
    // reset in the middle of a record write
    @(negedge clk); irq_src = 32'h0000_0020;
    clks(2);
    rst_n = 0; clks(2);
    if (m_awvalid || m_wvalid || log_wp !== 0) fail("not idle in reset");
    irq_src = 0;
    rst_n = 1; clks(3);
    @(negedge clk); irq_src = 32'h0000_0040;
    wait_wp(1);
    if ((mem.peek(log_base) & 32'h1F) !== 6) fail("record after reset");
    irq_src = 0;
    // LOG_WORDS lowered below the next slot: the record goes to slot 0
    log_words = 8;
    for (int k = 1; k < 5; k++) begin @(negedge clk); irq_src = 32'(1) << k; wait_wp(k + 1); @(negedge clk); irq_src = 0; end
    for (int i = 0; i < 8; i++) mem.poke(log_base + 32'(4 * i), 32'hDEAD_0000 | 32'(i));
    log_words = 3;
    @(negedge clk); irq_src = 32'h0000_0200; wait_wp(6);
    if ((mem.peek(log_base) & 32'h1F) !== 9) fail($sformatf("record after lowering LOG_WORDS at slot 0: %h", mem.peek(log_base)));
    if (mem.peek(log_base + 20) !== 32'hDEAD_0005) fail("record outside the shrunk ring");
    irq_src = 0;
    // other AXI error codes on a record write
    for (int k = 0; k < 2; k++) begin
      mem.err_resp = k ? 2'b11 : 2'b01;
      mem.err_lo = log_base; mem.err_hi = log_base + 12;   // the whole ring
      @(negedge clk); irq_src = 32'h0001_0000 << k; wait_wp(7 + k);
      @(negedge clk); irq_src = 0;
    end
    if (n_log_err != 3) fail("LOG_ERR on EXOKAY / DECERR");
    mem.err_resp = 2'b10; mem.err_lo = '1; mem.err_hi = '1;
    // log base anywhere (every address bit), LOG_WORDS 0 holds the queue
    log_base = 32'hFFFF_F0FF;   // every address bit set (bits 1:0 are dropped)
    log_words = 0;
    @(negedge clk); irq_src = 32'h0000_0400;
    clks(20);
    if (log_wp != 8) fail("record written with LOG_WORDS 0");
    log_words = 4; wait_wp(9);
    irq_src = 0;
    log_base = 32'h0000_0000;
    // a long ring: 65536 records, every source in turn; LOG_WP and the slot
    // climb through all their bits and wrap
    mem.stall = 0;
    log_words = 16'hFFFF;
    for (int k = 0; k < 65536; k++) begin
      logic [15:0] w0;
      w0 = log_wp;
      @(negedge clk); irq_src = 32'(1) << (k % 32);
      if (k % 4096 == 0) begin   // every source rising at once now and then
        sw_set = 32'hFFFF_FFFF; @(negedge clk); sw_set = 0;
      end
      while (log_wp == w0) @(negedge clk);
    end
    @(negedge clk); irq_src = 0;
    clks(200);
    log_words = 3;
    // records with the timestamp's top bits set, then after it wraps
    while (dut.ts < 24'hF0_0000) @(negedge clk);
    for (int k = 0; k < 3; k++) begin
      logic [15:0] w0;
      w0 = log_wp;
      @(negedge clk); irq_src = 32'(1) << k;
      while (log_wp == w0) @(negedge clk);
      @(negedge clk); irq_src = 0;
      if (k == 1) while (dut.ts != 24'h00_0010) @(negedge clk);
    end
    // LOG_EN cleared while records wait (the write path blocked)
    mem.aw_hold = 1;
    @(negedge clk); irq_src = 32'h0000_0700;
    clks(5);
    log_en = 0; clks(3); log_en = 1;
    irq_src = 0;
    // reset while a record write is in progress
    @(negedge clk); irq_src = 32'h0000_0800;
    clks(6);
    rst_n = 0; clks(2);
    mem.aw_hold = 0;
    rst_n = 1; clks(3);
    finish("Interrupt_Controller");
  end
endmodule
