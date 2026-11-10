// SPDX-License-Identifier: Apache-2.0
// Self-checking core testbench of Sensor_Hub_top (phone SoC subsystem, AXI4
// manager). A sensor model offers 16-bit samples with random gaps; every job
// is checked against a reference model of the averaging and packing: the
// words in memory, LAST_AVG, the WAKE interrupt (at most once per job), and
// that no sample is taken after the batch is complete. A job fed one sample
// per clock against a stalling memory must drop words (DROPS > 0) and still
// write only valid packed words, in order. Also: AXI write errors set ERR,
// reset in the middle of a batch, and the memory model's burst checks.
`timescale 1ns/1ps
`include "soc_ss_axi_mem.svh"
module Sensor_Hub_tb;
  `include "soc_ss_tb_common.svh"
  logic [31:0] dst_addr = 0;
  logic [15:0] xfer_len = 0, threshold = 0;
  logic [2:0]  avg_log2 = 0;
  logic        wake_en = 0, start = 0;
  logic        sns_valid = 0;
  logic [15:0] sns_data = 0;
  wire         busy, err, done, err_irq, wake;
  wire  [15:0] last_avg, drops;
  wire  [31:0] cycles;
  int n_jobs = 0;
  int gap_force = -1;     // >= 0: sensor gap percentage of the next batches
  int k_force = -1;       // >= 0: AVG_LOG2 of the next batches
  int flood_extra = 16;   // flood: extra samples per word of the batch
  bit all_max = 0;        // 1: every sample 16'hFFFF (the accumulator's top bits)
  Sensor_Hub_top dut (.*);

  int n_done = 0, n_err_irq = 0, n_wake = 0, n_taken = 0, gap_pct = 70;
  logic [15:0] sq [$];
  always @(posedge clk) if (rst_n) begin n_done += done; n_err_irq += err_irq; n_wake += wake; end
  // sensor model: the head of sq, offered with probability 100 - gap_pct
  always @(posedge clk) begin
    if (rst_n && sns_valid && busy && dut.nwords != dut.len_q) begin void'(sq.pop_front()); n_taken++; end
    #1;
    sns_valid = (sq.size() != 0) && ($urandom % 100 >= gap_pct);
    sns_data  = sns_valid ? sq[0] : 16'($urandom);
  end

  logic [31:0] expw [];
  logic [15:0] exp_last;
  bit          exp_wake;
  function automatic void model(input int n);
    int g, k;
    expw = new[n];
    g = 1 << avg_log2; k = 0; exp_wake = 0;
    for (int i = 0; i < 2 * n; i++) begin
      int s;
      logic [15:0] a;
      logic [31:0] w;
      s = 0;
      for (int j = 0; j < g; j++) s += int'(sq[k++]);
      a = 16'(s >> avg_log2);
      if (wake_en && a > threshold) exp_wake = 1;
      w = expw[i / 2];
      if (i % 2) w[31:16] = a; else w[15:0] = a;
      expw[i / 2] = w;
      exp_last = a;
    end
  endfunction

  // one batch of n words; inject: AXI write error at word n/2
  task automatic run(input int n, input bit inject, input bit flood);
    logic [31:0] d;
    int t, nd0, ne0, nw0, extra, take0;
    d = pick_addr(n);
    for (int i = 0; i < n; i++) mem.poke(d + 32'(4 * i), 32'hBAD0_0000 ^ i);
    @(negedge clk);
    dst_addr = d | 32'($urandom % 4); xfer_len = 16'(n);   // address bits 1:0 are ignored
    avg_log2 = flood ? 3'd0 : k_force >= 0 ? 3'(k_force) : 3'(n_jobs);   // every AVG_LOG2 in turn
    n_jobs++;
    wake_en = $urandom;
    case ($urandom % 4)
      0: threshold = 16'd0;
      1: threshold = 16'hFFFF;
      default: threshold = $urandom;
    endcase
    sq.delete();
    for (int i = 0; i < 2 * n * (1 << avg_log2); i++)
      case ($urandom % 6)
        0: sq.push_back(16'hFFFF);
        1: sq.push_back(16'h0000);
        2, 3: sq.push_back(16'($urandom));
        default: sq.push_back(16'(16'h1000 + $urandom % 64));
      endcase
    if (all_max) for (int i = 0; i < sq.size(); i++) sq[i] = 16'hFFFF;
    if (flood) for (int i = 0; i < flood_extra * n; i++) sq.push_back(16'(i));   // words get dropped: feed more
    extra = 1 + $urandom % 5;
    for (int i = 0; i < extra; i++) sq.push_back(16'hFFFF);    // must not be taken
    model(n);
    if (inject && n != 0) begin mem.err_lo = d + 32'(4 * (n / 2)); mem.err_hi = mem.err_lo + 4; end
    gap_pct = flood ? 0 : gap_force >= 0 ? gap_force : 20 + $urandom % 70;
    nd0 = n_done; ne0 = n_err_irq; nw0 = n_wake; take0 = n_taken;
    start = 1;
    @(negedge clk);
    start = 0;
    t = 0;
    while (busy && t < 2000000) begin @(negedge clk); t++; end
    if (busy) fail($sformatf("batch of %0d words timed out", n));
    clks(5);
    if (n_done != nd0 + 1) fail("DONE pulses");
    if (err !== (inject && n != 0)) fail($sformatf("ERR = %b", err));
    if (n_err_irq != ne0 + (inject && n != 0 ? 1 : 0)) fail("ERR interrupt count");
    mem.err_lo = '1; mem.err_hi = '1;
    if (flood) begin
      if (drops == 0) fail("no DROPS with one sample per clock and a stalling memory");
      if (n_taken - take0 <= 2 * n) fail("flood: too few samples taken");
      for (int i = 0; i < n; i++) begin   // every word of the batch is written
        if (mem.peek(d + 32'(4 * i)) === (32'hBAD0_0000 ^ i)) fail($sformatf("flood: word %0d not written", i));
      end
      return;
    end
    if (n_taken - take0 != 2 * n * (1 << avg_log2)) fail($sformatf("%0d samples taken, expected %0d", n_taken - take0, 2 * n * (1 << avg_log2)));
    if (sq.size() != extra) fail("samples taken after the batch was complete");
    if (drops !== 0) fail($sformatf("DROPS %0d", drops));
    if (n_wake - nw0 != int'(exp_wake)) fail($sformatf("%0d WAKE interrupts, expected %0d", n_wake - nw0, exp_wake));
    if (inject) return;
    if (n != 0 && last_avg !== exp_last) fail($sformatf("LAST_AVG %h, expected %h", last_avg, exp_last));
    for (int i = 0; i < n; i++)
      if (mem.peek(d + 32'(4 * i)) !== expw[i]) begin
        fail($sformatf("word %0d of %0d: %h, expected %h", i, n, mem.peek(d + 32'(4 * i)), expw[i]));
        break;
      end
  endtask

  initial begin
    clks(3);
    rst_n = 1;
    clks(2);
    mem.rand_id = 1;   // the core ignores BID
    run(0, 0, 0);
    run(1, 0, 0);
    run(17, 0, 0);
    for (int k = 0; k < 25; k++) begin
      mem.stall = (k % 4) != 3;
      run(1 + $urandom % 40, 0, 0);
    end
    mem.stall = 0;
    run(200, 0, 0);
    mem.stall = 1;
    run(40, 1, 0);
    run(25, 1, 0);
    // AXI error codes
    mem.err_resp = 2'b01; run(30, 1, 0);
    mem.err_resp = 2'b11; run(30, 1, 0);
    mem.err_resp = 2'b10;
    // long batches: the word count's top bits, and the accumulator full
    mem.stall = 0; gap_pct = 0;
    k_force = 0; gap_force = 0; run(65535, 0, 0); run(1500, 0, 0); gap_force = -1;
    k_force = 7; all_max = 1; run(20, 0, 0); all_max = 0;
    k_force = -1;
    // flood: one sample per clock, slow memory
    mem.stall = 1;
    run(300, 0, 1);
    // flood with the write path blocked for 140000 clocks: DROPS saturates
    fork begin clks(20); mem.aw_hold = 1; clks(140000); mem.aw_hold = 0; end join_none
    flood_extra = 4000;
    run(40, 0, 1);
    flood_extra = 16;
    run(9, 0, 0);
    // reset in the middle of a batch
    @(negedge clk);
    dst_addr = 32'h0000_3000; xfer_len = 100; avg_log2 = 0;
    sq.delete(); for (int i = 0; i < 400; i++) sq.push_back(16'(i));
    gap_pct = 0;
    start = 1; @(negedge clk); start = 0;
    clks(30);
    start = 1; @(negedge clk); start = 0;   // ignored while busy
    clks(30);
    rst_n = 0; clks(2);
    if (busy || m_awvalid || m_wvalid) fail("not idle in reset");
    rst_n = 1; clks(10);
    run(12, 0, 0);
    finish("Sensor_Hub");
  end
endmodule
