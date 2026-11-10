// SPDX-License-Identifier: Apache-2.0
// Self-checking core testbench of Modem_top (phone SoC subsystem, AXI4 manager).
// Random jobs of 0 to 600 words at random buffers (low memory, the top of the
// address space, across 4 KB boundaries) against a behavioural AXI4 memory
// with random and zero stalls; every output word and result register is
// compared with a reference model of the datapath (LFSR scrambling, bypass, CRC-32 of the input or the output). Also: START while
// busy is ignored, AXI error responses on a read and on a write set ERR and
// the ERR interrupt, DONE pulses once per job. The memory model checks every
// burst (size, INCR, WLAST, 4 KB, at most 16 beats).
`timescale 1ns/1ps
`include "soc_ss_axi_mem.svh"
module Modem_tb;
  `include "soc_ss_tb_common.svh"
  logic [31:0] src_addr = 0, dst_addr = 0;
  logic [15:0] xfer_len = 0;
  logic        start = 0;
  wire         busy, err, done, err_irq;
  wire  [31:0] cycles;
  logic [31:0] seed = 0;
  logic        crc_sel = 0, bypass = 0;
  wire  [31:0] crc;
  logic [31:0] exp_crc;
  Modem_top dut (.*);

  int n_done = 0, n_err_irq = 0;
  always @(posedge clk) if (rst_n) begin n_done += done; n_err_irq += err_irq; end

  logic [31:0] expw [];
  function automatic logic [31:0] crc32(input logic [31:0] c, input logic [31:0] d);
    for (int b = 0; b < 4; b++) begin
      c ^= 32'(d[8*b +: 8]);
      for (int k = 0; k < 8; k++) c = c[0] ? (c >> 1) ^ 32'hEDB8_8320 : c >> 1;
    end
    return c;
  endfunction
  function automatic void model(input logic [31:0] s, input int n);
    logic [31:0] l, c;
    expw = new[n];
    l = (seed == 0) ? 32'd1 : seed;
    c = 32'hFFFF_FFFF;
    for (int i = 0; i < n; i++) begin
      logic [31:0] x, key;
      x = mem.peek(s + 32'(4 * i));
      for (int k = 0; k < 32; k++) begin key[k] = l[0]; l = l[0] ? (l >> 1) ^ 32'h8020_0003 : l >> 1; end
      expw[i] = x ^ (bypass ? 32'd0 : key);
      c = crc32(c, crc_sel ? expw[i] : x);
    end
    exp_crc = ~c;
  endfunction

  // one job of n words; inject: 1 = read error, 2 = write error at word n/2
  task automatic run(input int n, input int inject, input bit restart);
    logic [31:0] s, d;
    int t, nd0, ne0, nbad;
    bit rd, wr;
    s = pick_addr(n); d = dst_of(s);
    fill_rand(s, n);
    for (int i = 0; i < n; i++) mem.poke(d + 32'(4 * i), 32'hBAD0_0000 ^ i);
    @(negedge clk);
    src_addr = s | 32'($urandom % 4); dst_addr = d | 32'($urandom % 4); xfer_len = 16'(n);   // address bits 1:0 are ignored
    seed = ($urandom % 8 == 0) ? 32'd0 : 32'($urandom); crc_sel = $urandom; bypass = ($urandom % 6 == 0);
    rd = 1; wr = 1;
    if (inject == 1 && !rd) inject = 2;
    if (inject == 2 && !wr) inject = 1;
    model(s, n);
    if (inject != 0 && n != 0) begin
      mem.err_lo = (inject == 1 ? s : d) + 32'(4 * (n / 2));
      mem.err_hi = mem.err_lo + 4;
    end
    nd0 = n_done; ne0 = n_err_irq;
    start = 1;
    @(negedge clk);
    start = 0;
    if (!busy && n != 0) fail("busy low after start");
    if (restart) begin
      clks(2);
      start = 1;
      @(negedge clk);
      start = 0;
    end
    t = 0;
    while (busy && t < 2000000) begin @(negedge clk); t++; end
    if (busy) fail($sformatf("job of %0d words timed out (rstate %0d wstate %0d)", n, dut.u_eng.rstate, dut.u_eng.wstate));
    clks(2);
    if (n_done != nd0 + 1) fail($sformatf("%0d DONE pulses for one job", n_done - nd0));
    if (err !== (inject != 0 && n != 0)) fail($sformatf("ERR = %b, inject %0d", err, inject));
    if (n_err_irq != ne0 + (inject != 0 && n != 0 ? 1 : 0)) fail("ERR interrupt count");
    if (cycles == 0 && n != 0) fail("CYCLES = 0");
    mem.err_lo = '1; mem.err_hi = '1;
    if (inject != 0) return;
    nbad = 0;
    if (wr)
      for (int i = 0; i < n; i++)
        if (mem.peek(d + 32'(4 * i)) !== expw[i]) begin
          if (nbad++ < 5) fail($sformatf("word %0d of %0d at %h: %h, expected %h", i, n, d + 32'(4 * i),
                                         mem.peek(d + 32'(4 * i)), expw[i]));
        end
    if (!wr && mem.peek(d) !== 32'hBAD0_0000 && n != 0) fail("read-only job wrote the destination");
    if (crc !== exp_crc) fail($sformatf("CRC %h, expected %h", crc, exp_crc));
    if (n == 1 && bypass && mem.peek(s) == 32'h3433_3231 && crc !== 32'h9BE3_E0A3) fail("CRC-32 check value");
  endtask

  initial begin
    clks(3);
    rst_n = 1;
    clks(2);
    mem.rand_id = 1;   // the core ignores BID / RID
    run(0, 0, 0);
    run(1, 0, 0);
    run(16, 0, 0);
    run(17, 0, 1);
    for (int k = 0; k < 40; k++) begin
      mem.stall = (k % 4) != 3;
      run(1 + $urandom % 80, 0, k % 7 == 0);
    end
    mem.stall = 1;
    // the write path blocked for a while: the write FIFO fills up and the
    // datapath stalls the read stream
    fork begin clks(30); mem.aw_hold = 1; clks(150); mem.aw_hold = 0; end join_none
    run(600, 0, 0);
    mem.stall = 0;
    run(300, 0, 0);
    mem.stall = 1;
    for (int k = 0; k < 6; k++) begin   // read / write side x EXOKAY, SLVERR, DECERR
      mem.err_resp = 2'(1 + k % 3);
      run(5 + $urandom % 40, 1 + k % 2, 0);
    end
    mem.err_resp = 2'b10;
    // long jobs: the upper bits of the length and of the counters
    mem.stall = 0;
    run(1500, 0, 0);
    run(65535, 0, 0);
    mem.stall = 1;
    run(33, 0, 0);
    // reset in the middle of a job: the core and the bus go idle
    @(negedge clk);
    src_addr = 32'h0000_2000; dst_addr = 32'h4000_2000; xfer_len = 200;
    start = 1; @(negedge clk); start = 0;
    clks(40);
    rst_n = 0; clks(2);
    if (busy || m_awvalid || m_arvalid || m_wvalid) fail("not idle in reset");
    rst_n = 1; clks(10);
    run(20, 0, 0);
    finish("Modem");
  end
endmodule
