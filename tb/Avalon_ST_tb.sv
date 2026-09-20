// SPDX-License-Identifier: Apache-2.0
// Self-checking testbench for Avalon_ST_top -- SystemVerilog
`timescale 1ns/1ps
module Avalon_ST_tb;
  logic clk = 0, rst_n = 0;
  logic av_valid = 0, av_ready;
  logic [31:0] av_data = 0;
  logic av_eop = 0;
  logic ren = 0;
  logic [3:0] raddr = 0;
  logic [31:0] rdata;
  logic [4:0] count;
  logic irq;
  logic irq_seen = 0;
  int errors = 0;

  Avalon_ST_top dut (
    .clk(clk), .rst_n(rst_n), .av_valid(av_valid), .av_ready(av_ready),
    .av_data(av_data), .av_eop(av_eop), .ren(ren), .raddr(raddr),
    .rdata(rdata), .count(count), .irq(irq));

  always #5 clk = ~clk;
  always @(posedge clk) if (irq) irq_seen <= 1'b1;

  task automatic send(input logic [31:0] d, input logic eop);
    begin
      wait (av_ready === 1'b1);
      @(negedge clk);
      av_data <= d; av_eop <= eop; av_valid <= 1'b1;
      @(posedge clk); #1;
      @(negedge clk);
      av_valid <= 1'b0; av_eop <= 1'b0;
    end
  endtask

  logic [31:0] exp [0:3];
  initial begin
    exp[0] = 32'h1111_2222; exp[1] = 32'h3333_4444;
    exp[2] = 32'h5555_6666; exp[3] = 32'h7777_8888;
  end

`ifdef VERILATOR
  // =====================================================================
  // v2.5 CRV instrumentation (tool build only; iverilog path unchanged)
  // No FSM in the DUT (FIFO datapath only) -> FSM_COV reported as 0/0.
  // =====================================================================
  int sva_total = 0, sva_fail = 0;
  // counted immediate assertion: every evaluation is one check
  task automatic sva_check(input bit cond, input string name);
    begin
      sva_total++;
      if (!cond) begin
        sva_fail++;
        errors++;
        $display("SVA_FAIL: %s @%0t", name, $time);
      end
    end
  endtask

  // output-invariant assertion suite (level/comb checks, negedge-sampled
  // so all NBA updates are settled; no history-dependent properties)
  logic rst_n_q = 1'b1;
  always @(negedge clk) begin
    if (!rst_n) begin
      // A1: outputs quiescent during reset (one cycle for regs to init)
      if (!rst_n_q)
        sva_check(count === 5'd0 && av_ready === 1'b1 && irq === 1'b0,
                  "A1 reset: count 0, ready, no irq");
    end else begin
      // A2: av_ready exactly reflects FIFO-not-full
      sva_check(av_ready === (dut.wr_ptr < 5'd16), "A2 ready == !full");
      // A3: count output mirrors the write pointer
      sva_check(count === dut.wr_ptr, "A3 count == wr_ptr");
      // A4: irq is exactly the eop write strobe
      sva_check(irq === (av_valid && av_ready && av_eop), "A4 irq == eop write");
      // A5: write pointer never exceeds the FIFO depth
      sva_check(dut.wr_ptr <= 5'd16, "A5 wr_ptr <= DEPTH");
    end
    rst_n_q <= rst_n;
  end
`endif

  initial begin
    rst_n = 0; repeat(5) @(posedge clk);
    rst_n = 1; repeat(5) @(posedge clk);

    for (int i = 0; i < 4; i++) send(exp[i], i == 3);

    repeat(2) @(posedge clk);
    if (count !== 5'd4) begin
      errors++; $display("ERROR: Avalon-ST count got=%0d exp=4", count);
    end
    if (!irq_seen) begin
      errors++; $display("ERROR: Avalon-ST irq never fired");
    end
    for (int i = 0; i < 4; i++) begin
      @(negedge clk); ren <= 1'b1; raddr <= i[3:0];
      #1;
      if (rdata !== exp[i]) begin
        errors++; $display("ERROR: Avalon-ST mem[%0d] got=%h exp=%h", i, rdata, exp[i]);
      end
      @(negedge clk); ren <= 1'b0;
    end

`ifdef VERILATOR
    // ---- v2.5 CRV random phase (directed tests above untouched) ----
    // 14 rounds x (1..16 beats + readback), ~112 push transactions total.
    // Each round resets the FIFO (wr_ptr has no other clear), pushes k
    // random beats with eop on the last (irq checked in-line), attempts
    // overflow pushes when full (must be dropped, count unchanged), then
    // reads back and verifies every captured word. Fully inlined; the only
    // wait is a bounded ready poll (can never expire: 16-deep FIFO, TB
    // drains by reset every round).
    begin : crv_phase
      int n_push = 0, n_ovf = 0, n_rd = 0;
      int k, wt;
      logic [31:0] dv;
      logic [31:0] expq [0:15];
      for (int t = 0; t < 14; t++) begin
        // round reset (wr_ptr clears only via rst_n)
        @(negedge clk); rst_n <= 1'b0;
        repeat (10) @(posedge clk);
        @(negedge clk); rst_n <= 1'b1;
        repeat (5) @(posedge clk);
        irq_seen = 1'b0;
        k = (t % 3 == 0) ? 16 : 1 + $urandom_range(0, 15);
        for (int i = 0; i < k; i++) begin
          dv = $urandom;
          if (t % 5 == 0)      dv = 32'h0000_0000;   // boundary patterns
          if (t % 7 == 0)      dv = 32'hFFFF_FFFF;
          expq[i] = dv;
          wt = 0;
          while (av_ready !== 1'b1 && wt < 100) begin @(posedge clk); wt++; end
          if (wt >= 100) begin
            errors++; $display("ERROR: CRV ready timeout t=%0d i=%0d", t, i);
          end
          @(negedge clk);
          av_data <= dv; av_eop <= (i == k-1); av_valid <= 1'b1;
          @(posedge clk); #1;
          if (irq !== ((i == k-1) && av_ready)) begin
            errors++; $display("ERROR: CRV irq t=%0d i=%0d got=%b", t, i, irq);
          end
          @(negedge clk);
          av_valid <= 1'b0; av_eop <= 1'b0;
          n_push++;
        end
        if (count !== k[4:0]) begin
          errors++; $display("ERROR: CRV count t=%0d got=%0d exp=%0d", t, count, k);
        end
        if (!irq_seen) begin
          errors++; $display("ERROR: CRV irq never fired t=%0d", t);
        end
        // overflow attempts on full rounds: must be dropped
        if (k == 16) begin
          for (int i = 0; i < 2; i++) begin
            if (av_ready !== 1'b0) begin
              errors++; $display("ERROR: CRV ready high when full t=%0d", t);
            end
            @(negedge clk);
            av_data <= $urandom; av_eop <= 1'b1; av_valid <= 1'b1;
            @(posedge clk); #1;
            @(negedge clk);
            av_valid <= 1'b0; av_eop <= 1'b0;
            n_ovf++;
          end
          if (count !== 5'd16) begin
            errors++; $display("ERROR: CRV count changed by overflow t=%0d", t);
          end
        end
        // readback of every captured word
        for (int i = 0; i < k; i++) begin
          @(negedge clk); ren <= 1'b1; raddr <= i[3:0];
          #1;
          if (rdata !== expq[i]) begin
            errors++; $display("ERROR: CRV mem[%0d] t=%0d got=%h exp=%h", i, t, rdata, expq[i]);
          end
          @(negedge clk); ren <= 1'b0;
          n_rd++;
        end
      end
      $display("CRV: %0d pushes + %0d overflow drops + %0d readbacks over 14 rounds",
               n_push, n_ovf, n_rd);
    end
`endif

    if (errors == 0) $display("TEST PASSED: Avalon-ST");
    else             $display("TEST FAILED: %0d errors", errors);
`ifdef VERILATOR
    $display("FSM_COV: 0/0");
    $display("SVA_CHECKS: %0d/%0d", sva_total - sva_fail, sva_total);
`endif
    $finish;
  end

`ifdef VERILATOR
  // chunked timeout guard: a single long-pending #delay event corrupts the
  // 5.006 --timing delay heap once many short-delay resumptions interleave
  initial begin
    repeat (2000) #1000;   // 2 ms in 1-us chunks
    $display("TIMEOUT"); $finish;
  end
`else
  initial begin
    #500_000; $display("TIMEOUT"); $finish;
  end
`endif
endmodule
