// SPDX-License-Identifier: Apache-2.0
// func_avalon_mm_tb.sv -- cycle-exact functional test for Avalon_MM_top,
// ported from open-vip-portfolio. Run: make -f Makefile.Avalon_MM func
//
// Avalon_MM_tb.sv checks data integrity and that backpressure and irq occur
// at all; irq is sticky, so it cannot tell which source raised it. This test
// resets between scenarios and checks:
//   * each irq source on its own (simultaneous read+write, burstcount > 16,
//     out-of-range single write / write-burst beat / read / read burst;
//     out-of-range read beats are still returned, as zero data),
//     and that legal traffic never raises irq;
//   * exact waitrequest cycles: none in the fast window (0x000-0x1FF),
//     exactly one wait state per command / write beat in the slow window
//     (0x200-0x3FF), including the first command after reset and after a read;
//   * exact readdatavalid timing: back-to-back beats in the fast window, a
//     one-cycle bubble before every slow-window beat;
//   * burstcount 0 -> 1 beat, 16 legal, 17+ clamped to 16;
//   * per-lane byteenable merge.

`timescale 1ns/1ps
module func_avalon_mm_tb;
  int checks = 0, fails = 0;

  logic clk = 1'b0, rst_n = 1'b0;
  logic [31:0] av_address = '0, av_writedata = '0, av_readdata;
  logic av_read = 1'b0, av_write = 1'b0;
  logic [3:0] av_byteenable = 4'hF;
  logic [7:0] av_burstcount = 8'd1;
  logic av_readdatavalid, av_waitrequest, irq;

  always #5 clk = ~clk;

  Avalon_MM_top u_dut (.*);

  task automatic chk(input bit ok, input string msg);
    checks++;
    if (!ok) begin fails++; $display("  [FAIL] %s", msg); end
  endtask

  task automatic do_reset();
    @(negedge clk); rst_n = 1'b0;
    av_read = 0; av_write = 0; av_burstcount = 8'd1; av_byteenable = 4'hF;
    @(negedge clk); rst_n = 1'b1;
  endtask

  // hold the current command/beat until accepted; returns the wait cycles.
  // Called at a negedge with the inputs set; returns at the negedge after
  // the accepting posedge.
  task automatic hold(output int waits);
    waits = 0;
    #1;
    while (av_waitrequest && waits <= 20) begin
      waits++;
      @(negedge clk);
      #1;
    end
    @(negedge clk);
  endtask

  // write burst of n beats starting at a; waits[i] per beat, returns idle
  int wwaits [32];
  task automatic wr(input [31:0] a, input int n, input [31:0] seed, input [7:0] bc = 0,
                    input [3:0] be = 4'hF);
    int w;
    @(negedge clk);
    av_address = a; av_write = 1'b1; av_read = 1'b0; av_byteenable = be;
    av_burstcount = (bc != 0) ? bc : 8'(n);
    for (int i = 0; i < n; i++) begin
      av_writedata = seed + i * 32'h0101_0101;
      hold(w);
      wwaits[i] = w;
      #0;
    end
    av_write = 1'b0;
  endtask

  // read command; records the readdatavalid pattern for 40 cycles after the
  // accepting edge (rdv_at[k] for the negedge after posedge k)
  bit   rdv_at [40];
  logic [31:0] rdata [$];
  int   cmd_waits;
  task automatic rd(input [31:0] a, input [7:0] bc, input bit also_write = 0);
    @(negedge clk);
    av_address = a; av_read = 1'b1; av_write = also_write; av_burstcount = bc;
    hold(cmd_waits);
    av_read = 1'b0; av_write = 1'b0;
    rdata.delete();
    for (int k = 0; k < 40; k++) begin
      #1;
      rdv_at[k] = av_readdatavalid;
      if (av_readdatavalid) rdata.push_back(av_readdata);
      @(negedge clk);
    end
  endtask

  function automatic int nbeats();
    int n = 0;
    foreach (rdv_at[k]) n += rdv_at[k];
    return n;
  endfunction
  function automatic bit pattern(input int n, input bit slow);
    // fast: beats at k = 0..n-1; slow: bubble first, beats at k = 1,3,5..
    for (int k = 0; k < 40; k++) begin
      bit exp = slow ? (k % 2 == 1 && k / 2 < n) : (k < n);
      if (rdv_at[k] !== exp) return 0;
    end
    return 1;
  endfunction
  function automatic bit data_is(input [31:0] seed, input int n);
    if (rdata.size() != n) return 0;
    for (int i = 0; i < n; i++) if (rdata[i] !== seed + i * 32'h0101_0101) return 0;
    return 1;
  endfunction

  initial begin
    repeat (2) @(negedge clk);
    rst_n = 1'b1;

    // ---------------- fast window: no wait states, back-to-back data
    wr(32'h0000_0040, 4, 32'h1000_0000);
    chk(wwaits[0] == 0 && wwaits[1] == 0 && wwaits[2] == 0 && wwaits[3] == 0,
        "fast-window write burst: no wait states");
    rd(32'h0000_0040, 8'd4);
    chk(cmd_waits == 0, "fast-window read command: no wait state");
    chk(pattern(4, 0), "fast-window read burst: 4 back-to-back beats right after the command");
    chk(data_is(32'h1000_0000, 4), "fast-window burst data in order");
    chk(irq === 1'b0, "legal fast-window traffic raises no irq");

    // ---------------- slow window, first command after reset
    do_reset();
    wr(32'h0000_0300, 1, 32'h2000_0000);
    chk(wwaits[0] == 1, $sformatf("first slow-window write after reset: exactly 1 wait state (%0d)", wwaits[0]));
    wr(32'h0000_0310, 3, 32'h2100_0000);
    chk(wwaits[0] == 1 && wwaits[1] == 1 && wwaits[2] == 1,
        "slow-window write burst: exactly 1 wait state per beat");
    rd(32'h0000_0310, 8'd3);
    chk(cmd_waits == 1, "slow-window read command: exactly 1 wait state");
    chk(pattern(3, 1), "slow-window read burst: one-cycle bubble before every beat");
    chk(data_is(32'h2100_0000, 3), "slow-window burst data in order");
    wr(32'h0000_0300, 1, 32'h2200_0000);
    chk(wwaits[0] == 1, "slow-window write after a read: exactly 1 wait state");
    rd(32'h0000_0300, 8'd1);
    chk(pattern(1, 1) && rdata.size() == 1 && rdata[0] == 32'h2200_0000, "slow single read returns the new data after one bubble");
    chk(irq === 1'b0, "legal slow-window traffic raises no irq");

    // slow write queued behind a slow read: waits while the read drains,
    // then still exactly one wait state in the slow window
    begin
      int w;
      @(negedge clk);
      av_address = 32'h0000_0300; av_read = 1'b1; av_write = 1'b0; av_burstcount = 8'd1;
      hold(w);                                 // read accepted
      av_read = 1'b0; av_write = 1'b1; av_writedata = 32'h2400_0000;
      hold(w);
      av_write = 1'b0;
      chk(w == 3, $sformatf("slow write behind a slow read: 2 drain + 1 wait-state cycles (%0d)", w));
    end

    // a slow command already presented when reset is released
    @(negedge clk); rst_n = 1'b0;
    av_address = 32'h0000_0304; av_write = 1'b1; av_read = 1'b0; av_burstcount = 8'd1;
    av_writedata = 32'h2500_0000;
    @(negedge clk); rst_n = 1'b1;
    begin
      int w;
      hold(w);
      av_write = 1'b0;
      chk(w == 1, $sformatf("slow command presented at reset release: 1 wait state (%0d)", w));
    end

    // burst crossing fast -> slow window
    wr(32'h0000_01F8, 4, 32'h2300_0000);
    chk(wwaits[0] == 0 && wwaits[1] == 0 && wwaits[2] == 1 && wwaits[3] == 1,
        "write burst crossing into the slow window: wait states only on slow beats");

    // ---------------- burstcount edge cases
    do_reset();
    wr(32'h0000_0080, 16, 32'h3000_0000);
    rd(32'h0000_0080, 8'd16);
    chk(nbeats() == 16 && data_is(32'h3000_0000, 16) && irq === 1'b0, "burstcount 16 is legal: 16 beats, no irq");
    rd(32'h0000_0080, 8'd0);
    chk(pattern(1, 0) && rdata[0] == 32'h3000_0000, "burstcount 0 transfers one beat");
    chk(irq === 1'b0, "burstcount 0 raises no irq");
    rd(32'h0000_0080, 8'd17);
    chk(nbeats() == 16, $sformatf("burstcount 17 clamped to 16 beats (%0d)", nbeats()));
    chk(irq === 1'b1, "burstcount > 16 raises irq");

    // ---------------- each irq source on its own
    do_reset();
    rd(32'h0000_0080, 8'd1, 1'b1);
    chk(irq === 1'b1, "simultaneous read and write raise irq");
    do_reset();
    wr(32'h0000_0400, 1, 32'h4000_0000);
    chk(irq === 1'b1, "out-of-range single write raises irq");
    do_reset();
    wr(32'h0000_03FC, 2, 32'h4100_0000);
    chk(irq === 1'b1, "write burst running past 0x3FF raises irq");
    rd(32'h0000_03FC, 8'd1);
    chk(rdata.size() == 1 && rdata[0] == 32'h4100_0000, "in-range beat of the truncated write burst landed");
    do_reset();
    rd(32'h0000_0400, 8'd1);
    // Avalon: every read returns burstcount beats; out-of-range ones carry 0
    chk(irq === 1'b1 && nbeats() == 1 && rdata[0] === 32'h0, "out-of-range read raises irq and returns one zero beat");
    do_reset();
    rd(32'h0000_03F8, 8'd4);
    chk(irq === 1'b1 && nbeats() == 4 && rdata[2] === 32'h0 && rdata[3] === 32'h0,
        "read burst past 0x3FF: all 4 beats, the out-of-range ones zero, + irq");
    do_reset();
    chk(irq === 1'b0, "reset clears irq");

    // ---------------- byteenable merge per lane
    wr(32'h0000_0020, 1, 32'h0000_0000);
    for (int b = 0; b < 4; b++) wr(32'h0000_0020, 1, 32'h1111_1111 * (b + 1), 0, 4'(1 << b));
    rd(32'h0000_0020, 8'd1);
    chk(rdata.size() == 1 && rdata[0] == 32'h4433_2211, $sformatf("each byte lane written alone (%h)", rdata[0]));
    wr(32'h0000_0020, 1, 32'hFFFF_FFFF, 0, 4'h0);
    rd(32'h0000_0020, 8'd1);
    chk(rdata[0] == 32'h4433_2211, "byteenable 0 writes nothing");

    // ---------------- random single accesses over both windows
    begin
      logic [31:0] m [256];
      bit v [256];
      int bad, wbad;
      bad = 0; wbad = 0;
      foreach (v[i]) v[i] = 0;
      do_reset();
      for (int t = 0; t < 60; t++) begin
        int idx;
        logic [31:0] d;
        idx = $urandom_range(255);
        d = $urandom;
        if ($urandom_range(1)) begin
          wr(32'(idx * 4), 1, d);
          if (wwaits[0] != (idx >= 128)) wbad++;
          v[idx] = 1; m[idx] = d;
        end else begin
          rd(32'(idx * 4), 8'd1);
          if (cmd_waits != (idx >= 128) || !pattern(1, idx >= 128)) wbad++;
          if (v[idx] && rdata[0] !== m[idx]) bad++;
        end
      end
      chk(bad == 0, $sformatf("60 random accesses: data matches the reference (%0d bad)", bad));
      chk(wbad == 0, $sformatf("60 random accesses: wait states/bubbles match the window (%0d bad)", wbad));
      chk(irq === 1'b0, "random legal accesses raise no irq");
    end

    if (fails == 0) $display("TEST PASSED: Avalon_MM_func (%0d checks)", checks);
    else            $display("TEST FAILED: %0d of %0d checks", fails, checks);
    $finish;
  end

  initial begin
    #2000000;
    $display("TEST FAILED: timeout");
    $finish;
  end
endmodule
