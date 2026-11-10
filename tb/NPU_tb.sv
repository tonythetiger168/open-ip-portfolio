// SPDX-License-Identifier: Apache-2.0
// Self-checking core testbench of NPU_top (phone SoC subsystem, AXI4 manager).
// Random jobs of 0 to 600 words at random buffers (low memory, the top of the
// address space, across 4 KB boundaries) against a behavioural AXI4 memory
// with random and zero stalls; every output word and result register is
// compared with a reference model of the datapath (int8 4-tap convolution, bias, ReLU, shift, saturation). Also: START while
// busy is ignored, AXI error responses on a read and on a write set ERR and
// the ERR interrupt, DONE pulses once per job. The memory model checks every
// burst (size, INCR, WLAST, 4 KB, at most 16 beats).
`timescale 1ns/1ps
`include "soc_ss_axi_mem.svh"
module NPU_tb;
  `include "soc_ss_tb_common.svh"
  logic [31:0] src_addr = 0, dst_addr = 0;
  logic [15:0] xfer_len = 0;
  logic        start = 0;
  wire         busy, err, done, err_irq;
  wire  [31:0] cycles;
  logic [7:0]  w0 = 0, w1 = 0, w2 = 0, w3 = 0;
  logic [15:0] bias = 0;
  logic [3:0]  shift = 0;
  logic        relu = 0;
  wire  [15:0] saturations;
  int          exp_sat;
  int n_jobs = 0;
  bit sat_all = 0;   // 1: every result saturates (SATURATIONS climbs to 16'hFFFF)
  NPU_top dut (.*);

  int n_done = 0, n_err_irq = 0;
  always @(posedge clk) if (rst_n) begin n_done += done; n_err_irq += err_irq; end

  logic [31:0] expw [];
  function automatic void model(input logic [31:0] s, input int n);
    int x [$];
    expw = new[n];
    exp_sat = 0;
    for (int i = 0; i < 4 * n; i++) begin
      logic [31:0] wv;
      int acc, y;
      wv = mem.peek(s + 32'(4 * (i / 4)));
      x.push_back(int'(signed'(wv[8 * (i % 4) +: 8])));
      acc = int'(signed'(bias)) + int'(signed'(w0)) * x[i]
          + int'(signed'(w1)) * (i >= 1 ? x[i - 1] : 0) + int'(signed'(w2)) * (i >= 2 ? x[i - 2] : 0)
          + int'(signed'(w3)) * (i >= 3 ? x[i - 3] : 0);
      if (relu && acc < 0) acc = 0;
      y = acc >>> shift;
      if (y > 127) begin y = 127; exp_sat++; end
      if (y < -128) begin y = -128; exp_sat++; end
      wv = expw[i / 4];
      wv[8 * (i % 4) +: 8] = 8'(y);
      expw[i / 4] = wv;
    end
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
    w0 = $urandom; w1 = $urandom; w2 = $urandom; w3 = $urandom;
    bias = $urandom; shift = 4'(n_jobs++); relu = $urandom;   // every shift in turn
    if ($urandom % 4 == 0) begin w1 = 0; w2 = 0; w3 = 0; w0 = 1; bias = 0; shift = 0; end   // identity
    if (sat_all) begin w0 = 8'h7F; w1 = 8'h7F; w2 = 8'h7F; w3 = 8'h7F; bias = 16'h7FFF; shift = 0; relu = 0; end
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
    if (saturations !== 16'(exp_sat > 65535 ? 65535 : exp_sat)) fail($sformatf("SATURATIONS %0d, expected %0d", saturations, exp_sat > 65535 ? 65535 : exp_sat));   // saturating count
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
    for (int k = 0; k < 80; k++) begin
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
    sat_all = 1;
    run(65535, 0, 0);
    sat_all = 0;
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
    finish("NPU");
  end
endmodule
