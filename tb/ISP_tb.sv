// SPDX-License-Identifier: Apache-2.0
// Self-checking core testbench of ISP_top (phone SoC subsystem, AXI4 manager).
// Random jobs of 0 to 600 words at random buffers (low memory, the top of the
// address space, across 4 KB boundaries) against a behavioural AXI4 memory
// with random and zero stalls; every output word and result register is
// compared with a reference model of the datapath (test pattern and sensor-stream sources, black level, Q4.4 gain, exposure sum). Also: START while
// busy is ignored, AXI error responses on a read and on a write set ERR and
// the ERR interrupt, DONE pulses once per job. The memory model checks every
// burst (size, INCR, WLAST, 4 KB, at most 16 beats).
`timescale 1ns/1ps
`include "soc_ss_axi_mem.svh"
module ISP_tb;
  `include "soc_ss_tb_common.svh"
  logic [31:0] src_addr = 0, dst_addr = 0;   // src_addr: unused by the ISP (no reads)
  logic [15:0] xfer_len = 0;
  logic        start = 0;
  wire         busy, err, done, err_irq;
  wire  [31:0] cycles;
  logic [15:0] line_words = 0;
  logic        src_sel = 0;
  logic [7:0]  seed = 0, black = 0, gain = 16;
  logic        sns_valid = 0;
  logic [31:0] sns_data = 0;
  wire         sns_ready;
  wire  [31:0] stat_sum;
  logic [31:0] exp_sum;
  // sensor model: offers the words of sns_q with random gaps
  logic [31:0] sns_q [$];
  always @(posedge clk) begin
    if (sns_valid && sns_ready) void'(sns_q.pop_front());
    #1;
    sns_valid = (sns_q.size() != 0) && ($urandom % 3 != 0);
    sns_data  = sns_valid ? sns_q[0] : $urandom;
  end
  ISP_top dut (.*);

  int n_done = 0, n_err_irq = 0;
  always @(posedge clk) if (rst_n) begin n_done += done; n_err_irq += err_irq; end

  logic [31:0] expw [];
  function automatic void model(input logic [31:0] s, input int n);
    int x, y;
    expw = new[n];
    exp_sum = 0; x = 0; y = 0;
    for (int i = 0; i < n; i++) begin
      logic [31:0] r, o;
      for (int b = 0; b < 4; b++) r[8*b +: 8] = 8'(4 * x + b + y) ^ seed;
      if (src_sel) r = sns_q[i];
      for (int b = 0; b < 4; b++) begin
        int d, g;
        d = (int'(r[8*b +: 8]) > int'(black)) ? int'(r[8*b +: 8]) - int'(black) : 0;
        g = (d * int'(gain)) >> 4;
        o[8*b +: 8] = 8'(g > 255 ? 255 : g);
        exp_sum += 32'(o[8*b +: 8]);
      end
      expw[i] = o;
      if (x + 1 >= line_words) begin x = 0; y++; end else x++;
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
    src_addr = s; dst_addr = d; xfer_len = 16'(n);
    line_words = 16'($urandom % 12); src_sel = $urandom; seed = $urandom; black = ($urandom % 2) ? 8'($urandom) : 8'd0;
    gain = ($urandom % 3 == 0) ? 8'd16 : 8'($urandom);
    sns_q.delete();
    if (src_sel) for (int i = 0; i < n; i++) sns_q.push_back($urandom);
    rd = 0; wr = 1;
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
    while (busy && t < 100000) begin @(negedge clk); t++; end
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
    if (stat_sum !== exp_sum) fail($sformatf("STAT_SUM %0d, expected %0d", stat_sum, exp_sum));
    if (src_sel && sns_q.size() != 0) fail("sensor words left over");
  endtask

  initial begin
    clks(3);
    rst_n = 1;
    clks(2);
    run(0, 0, 0);
    run(1, 0, 0);
    run(16, 0, 0);
    run(17, 0, 1);
    for (int k = 0; k < 40; k++) begin
      mem.stall = (k % 4) != 3;
      run(1 + $urandom % 80, 0, k % 7 == 0);
    end
    mem.stall = 1;
    run(600, 0, 0);
    mem.stall = 0;
    run(300, 0, 0);
    mem.stall = 1;
    for (int k = 0; k < 6; k++) run(5 + $urandom % 40, 1 + k % 2, 0);
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
    finish("ISP");
  end
endmodule
