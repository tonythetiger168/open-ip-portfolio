// SPDX-License-Identifier: Apache-2.0
// ============================================================================
// Self-checking testbench for Avalon_MM_top (Avalon-MM slave, burst capable)
// TB acts as an Avalon master model: single/burst read & write, waitrequest
// observance, byteenable merge, out-of-range burst truncation + irq.
// ============================================================================
`timescale 1ns/1ps
module Avalon_MM_tb;
  localparam int DW = 32, AW = 32;

  logic clk = 0, rst_n = 0;
  logic [AW-1:0] av_address;
  logic          av_read, av_write;
  logic [DW-1:0] av_writedata;
  logic [3:0]    av_byteenable;
  logic [7:0]    av_burstcount;
  logic [DW-1:0] av_readdata;
  logic          av_readdatavalid, av_waitrequest, irq;

  int errors = 0;
  int wr_seen = 0;          // waitrequest observance counter

  Avalon_MM_top #(.DW(DW), .AW(AW)) dut (
    .clk(clk), .rst_n(rst_n),
    .av_address(av_address), .av_read(av_read), .av_write(av_write),
    .av_writedata(av_writedata), .av_byteenable(av_byteenable),
    .av_burstcount(av_burstcount),
    .av_readdata(av_readdata), .av_readdatavalid(av_readdatavalid),
    .av_waitrequest(av_waitrequest), .irq(irq)
  );

  always #5 clk = ~clk;

  // ------------------------------------------------------------------
  // in-order read-data scoreboard
  // ------------------------------------------------------------------
  logic [31:0] exp_q [0:127];
  int exp_n = 0, rd_i = 0;

  always @(posedge clk) begin
    if (av_waitrequest) wr_seen++;
    if (av_readdatavalid) begin
      if (rd_i >= exp_n) begin
        errors++; $display("ERROR: unexpected readdatavalid data=%h @%0t", av_readdata, $time);
      end else if (av_readdata !== exp_q[rd_i]) begin
        errors++; $display("ERROR: readdata mismatch beat %0d exp %h got %h",
                           rd_i, exp_q[rd_i], av_readdata);
      end
      rd_i++;
    end
  end

  // ------------------------------------------------------------------
  // master-model tasks (drive on negedge, sample on posedge)
  // ------------------------------------------------------------------
  task automatic av_idle;
    begin
      @(negedge clk);
      av_read <= 1'b0; av_write <= 1'b0; av_burstcount <= 8'd1;
    end
  endtask

  // single write (burstcount=1)
  task automatic av_write1(input logic [AW-1:0] a, input logic [DW-1:0] d,
                           input logic [3:0] be);
    int to;
    begin
      @(negedge clk);
      av_address <= a; av_writedata <= d; av_byteenable <= be;
      av_burstcount <= 8'd1; av_write <= 1'b1; av_read <= 1'b0;
      to = 0;
      while (to < 50) begin
        @(posedge clk);
        if (!av_waitrequest) to = 100; else to++;
      end
      if (to != 100) begin errors++; $display("ERROR: write timeout @%h", a); end
      av_idle();
    end
  endtask

  // write burst of n beats, data = base + i
  task automatic av_write_burst(input logic [AW-1:0] a, input int n,
                                input logic [DW-1:0] base);
    int i, to;
    begin
      for (i = 0; i < n; i++) begin
        @(negedge clk);
        av_address <= a;                 // address only meaningful on beat 0
        av_writedata <= base + i;
        av_byteenable <= 4'hF;
        av_burstcount <= n[7:0];
        av_write <= 1'b1; av_read <= 1'b0;
        to = 0;
        while (to < 50) begin
          @(posedge clk);
          if (!av_waitrequest) to = 100; else to++;
        end
        if (to != 100) begin
          errors++; $display("ERROR: write burst timeout beat %0d @%h", i, a);
          i = n;                         // abort burst
        end
      end
      av_idle();
    end
  endtask

  // single read, expected data pushed to scoreboard, waits for the beat
  task automatic av_read1(input logic [AW-1:0] a, input logic [DW-1:0] exp);
    int to, target;
    begin
      target = rd_i + 1;
      exp_q[exp_n] = exp; exp_n++;
      @(negedge clk);
      av_address <= a; av_burstcount <= 8'd1;
      av_read <= 1'b1; av_write <= 1'b0; av_writedata <= '0; av_byteenable <= 4'hF;
      to = 0;
      while (to < 50) begin
        @(posedge clk);
        if (!av_waitrequest) to = 100; else to++;
      end
      if (to != 100) begin errors++; $display("ERROR: read cmd timeout @%h", a); end
      av_idle();
      to = 0;
      while (rd_i < target && to < 100) begin
        @(posedge clk); to++;
      end
      if (rd_i < target) begin
        errors++; $display("ERROR: readdatavalid never arrived @%h", a);
      end
    end
  endtask

  // read burst of n beats, expected = base + i, in order
  task automatic av_read_burst(input logic [AW-1:0] a, input int n,
                               input logic [DW-1:0] base);
    int i, to, target;
    begin
      target = rd_i + n;
      for (i = 0; i < n; i++) begin exp_q[exp_n] = base + i; exp_n++; end
      @(negedge clk);
      av_address <= a; av_burstcount <= n[7:0];
      av_read <= 1'b1; av_write <= 1'b0; av_byteenable <= 4'hF;
      to = 0;
      while (to < 50) begin
        @(posedge clk);
        if (!av_waitrequest) to = 100; else to++;
      end
      if (to != 100) begin errors++; $display("ERROR: read burst cmd timeout @%h", a); end
      av_idle();
      to = 0;
      while (rd_i < target && to < 200) begin
        @(posedge clk); to++;
      end
      if (rd_i < target) begin
        errors++; $display("ERROR: read burst @%h got %0d/%0d beats", a, rd_i - (target - n), n);
      end
    end
  endtask

  // ------------------------------------------------------------------
  // test sequence
  // ------------------------------------------------------------------
  int i;
  int rd_mark;

  initial begin
    av_address = 0; av_read = 0; av_write = 0; av_writedata = 0;
    av_byteenable = 4'hF; av_burstcount = 8'd1;
    repeat (4) @(negedge clk);
    rst_n = 1;
    @(negedge clk);

    // CHECK 1: reset / idle state
    if (av_waitrequest !== 1'b0 || av_readdatavalid !== 1'b0 || irq !== 1'b0) begin
      errors++; $display("ERROR: bad reset state wr=%b rdv=%b irq=%b",
                         av_waitrequest, av_readdatavalid, irq);
    end

    // CHECK 2: single write + read data path (fast window)
    av_write1(32'h0000_0010, 32'hDEAD_BEEF, 4'hF);
    av_read1 (32'h0000_0010, 32'hDEAD_BEEF);
    av_write1(32'h0000_0014, 32'h1234_5678, 4'hF);
    av_read1 (32'h0000_0014, 32'h1234_5678);

    // CHECK 3: byteenable partial-write merge
    av_write1(32'h0000_0020, 32'hAABB_CCDD, 4'hF);
    av_write1(32'h0000_0020, 32'h0000_1234, 4'b0011);
    av_read1 (32'h0000_0020, 32'hAABB_1234);

    // CHECK 4: slow window (0x200+) -> waitrequest backpressure really seen
    wr_seen = 0;
    av_write1(32'h0000_0200, 32'h5555_0001, 4'hF);
    av_read1 (32'h0000_0200, 32'h5555_0001);
    if (wr_seen == 0) begin
      errors++; $display("ERROR: waitrequest never asserted on slow window");
    end

    // CHECK 5: write burst len 8 (fast window) + read burst len 8 in order
    av_write_burst(32'h0000_0040, 8, 32'hB000_0000);
    av_read_burst (32'h0000_0040, 8, 32'hB000_0000);

    // CHECK 6: back-to-back bursts (consecutive transactions)
    av_write_burst(32'h0000_0080, 4, 32'hC000_0000);
    av_write_burst(32'h0000_0090, 4, 32'hD000_0000);
    av_read_burst (32'h0000_0080, 4, 32'hC000_0000);
    av_read_burst (32'h0000_0090, 4, 32'hD000_0000);

    // CHECK 7: slow-window write burst -> waitrequest during burst beats
    wr_seen = 0;
    av_write_burst(32'h0000_0210, 4, 32'hE000_0000);
    av_read_burst (32'h0000_0210, 4, 32'hE000_0000);
    if (wr_seen == 0) begin
      errors++; $display("ERROR: waitrequest never asserted in slow burst");
    end

    // CHECK 8: out-of-range write burst is truncated + irq
    //   start 0x3F0 len 8 -> only words 0x3F0..0x3FC written, rest dropped
    av_write_burst(32'h0000_03F0, 8, 32'hF000_0000);
    repeat (4) @(posedge clk);
    if (irq !== 1'b1) begin
      errors++; $display("ERROR: irq not set after out-of-range write burst");
    end
    av_read_burst(32'h0000_03F0, 4, 32'hF000_0000);   // valid part intact

    // CHECK 9: out-of-range read burst truncated -> fewer beats + irq
    //   start 0x3F8 len 8 -> only 2 beats returned
    rd_mark = rd_i;
    begin
      int to;
      exp_q[exp_n] = 32'hF000_0002; exp_n++;   // 0x3F8 holds F000_0002
      exp_q[exp_n] = 32'hF000_0003; exp_n++;   // 0x3FC holds F000_0003
      @(negedge clk);
      av_address <= 32'h0000_03F8; av_burstcount <= 8'd8;
      av_read <= 1'b1; av_write <= 1'b0;
      to = 0;
      while (to < 50) begin
        @(posedge clk);
        if (!av_waitrequest) to = 100; else to++;
      end
      av_idle();
      to = 0;
      while (rd_i < rd_mark + 2 && to < 100) begin @(posedge clk); to++; end
      repeat (6) @(posedge clk);               // no more beats may follow
    end
    if (rd_i != rd_mark + 2) begin
      errors++; $display("ERROR: truncated read burst beats %0d (exp 2)", rd_i - rd_mark);
    end
    if (irq !== 1'b1) begin
      errors++; $display("ERROR: irq not set after truncated read burst");
    end

    // CHECK 10: error injection -- out-of-range single write + read
    av_write1(32'h0000_0800, 32'hFFFF_FFFF, 4'hF);
    rd_mark = rd_i;
    begin
      int to;
      @(negedge clk);
      av_address <= 32'h0000_0800; av_burstcount <= 8'd1;
      av_read <= 1'b1; av_write <= 1'b0;
      to = 0;
      while (to < 50) begin
        @(posedge clk);
        if (!av_waitrequest) to = 100; else to++;
      end
      av_idle();
      repeat (8) @(posedge clk);
    end
    if (rd_i != rd_mark) begin
      errors++; $display("ERROR: out-of-range read returned data");
    end
    if (irq !== 1'b1) begin
      errors++; $display("ERROR: irq not set after out-of-range single access");
    end

    // scoreboard drained
    if (rd_i != exp_n) begin
      errors++; $display("ERROR: %0d expected read beats missing", exp_n - rd_i);
    end

    repeat (2) @(posedge clk);
    if (errors == 0) $display("TEST PASSED: Avalon_MM");
    else             $display("TEST FAILED: %0d errors", errors);
    $finish;
  end

  // TIMEOUT guard
  initial begin
    #300000;
    $display("TEST FAILED: TIMEOUT");
    $finish;
  end

endmodule
