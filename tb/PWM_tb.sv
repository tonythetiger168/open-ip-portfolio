// SPDX-License-Identifier: Apache-2.0
// Self-checking testbench for PWM_top -- SystemVerilog
`timescale 1ns/1ps
module PWM_tb;
  logic clk = 0, rst_n = 0;
  logic wen = 0;
  logic [3:0] waddr = 0;
  logic [31:0] wdata = 0;
  int errors = 0;

  PWM_top dut (
    .clk(clk), .rst_n(rst_n), .wen(wen), .waddr(waddr), .wdata(wdata),
    .pwm_out(), .pwm_n_out(), .irq());

  always #5 clk = ~clk;

`ifdef VERILATOR
  // =====================================================================
  // v2.5 CRV instrumentation (tool build only; iverilog path unchanged)
  // PWM_top is a counter + combinational-compare core: NO FSM present, so
  // FSM coverage is N/A (documented in docs/coverage/W6_REST.md).
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

  // output-invariant assertion suite (sampled coherently pre-NBA)
  logic [31:0] period_q_q = '0;   // one-cycle-delayed period sample
  always @(posedge clk) begin
    if (!rst_n) begin
      // A1: outputs quiescent during reset
      sva_check(dut.pwm_out === 1'b0 && dut.pwm_n_out === 1'b1 &&
                dut.irq === 1'b0, "A1 reset: outputs quiescent");
    end else begin
      // A2: complement output is always the inverse
      sva_check(dut.pwm_n_out === ~dut.pwm_out, "A2 pwm_n == ~pwm_out");
      // A3: counter held at zero while period is zero
      sva_check((dut.period_q != 0) || (period_q_q != 0) || (dut.counter == 0),
                "A3 counter zero when period zero");
      // A4: high output requires nonzero period and duty
      sva_check(!dut.pwm_out || (dut.period_q != 0 && dut.duty_q != 0),
                "A4 pwm_out implies nonzero period/duty");
      // A5: output high exactly when counter below duty (compare equation)
      sva_check(dut.pwm_out === ((dut.period_q != 0) && (dut.counter < dut.duty_q)),
                "A5 pwm_out compare equation");
      // A6: irq only in the last count of a nonzero period
      sva_check(!dut.irq ||
                (dut.period_q != 0 && dut.counter == dut.period_q - 1'b1),
                "A6 irq only at terminal count");
    end
    period_q_q <= dut.period_q;
  end
`endif

  task automatic wr(input logic [3:0] a, input logic [31:0] d);
    begin
      @(negedge clk); wen <= 1'b1; waddr <= a; wdata <= d;
      @(negedge clk); wen <= 1'b0;
    end
  endtask

  task automatic check_duty(input int period, input int duty);
    int high = 0;
    begin
      wr(4'd0, period);
      wr(4'd1, duty);
      wait (dut.counter == 0);
      repeat (period) begin
        @(posedge clk); #1;
        if (dut.pwm_out) high++;
      end
      if (high != duty) begin
        errors++;
        $display("ERROR: PWM period=%0d duty=%0d high_count=%0d", period, duty, high);
      end
    end
  endtask

  initial begin
    rst_n = 0; repeat(5) @(posedge clk);
    rst_n = 1; repeat(5) @(posedge clk);
    check_duty(10, 3);
    check_duty(10, 7);
    check_duty(16, 1);
    check_duty(16, 15);

`ifdef VERILATOR
    // ---- v2.5 CRV random phase (directed tests above untouched) ----
    // 110 randomized transactions: random period/duty pairs covering normal
    // operation, boundary (duty==0, duty==period), and the duty>period
    // "always-on" misuse class, plus illegal-address write injection; the
    // self-check model expects min(duty, period) high clocks per period.
    begin : crv_phase
      int n_norm = 0, n_bnd = 0, n_ovf = 0, n_ill = 0;
      int period, duty, high;
      logic [3:0]  ra;
      logic [31:0] junk;
      // deterministic bit flush: toggle every period_q/duty_q bit 0->1->0
      wr(4'd0, 32'hFFFF_FFFF); wr(4'd1, 32'hFFFF_FFFF);
      repeat(4) @(posedge clk);
      wr(4'd0, 32'h0);         wr(4'd1, 32'h0);
      repeat(2) @(posedge clk);
      for (int t = 0; t < 110; t++) begin
        int roll = $urandom_range(0, 9);
        if (roll < 1) begin
          // error injection: write to an unimplemented address, ignored
          n_ill++;
          ra   = $urandom_range(2, 15);
          junk = $urandom;
          wr(ra, junk);
          wr(4'd0, 8); wr(4'd1, 4);
          wait (dut.counter == 0);
          repeat (8) begin
            @(posedge clk); #1;
            if (dut.pwm_out !== 1'b1 && dut.pwm_out !== 1'b0) begin
              errors++; $display("ERROR: CRV X on pwm_out after illegal write");
            end
          end
        end else begin
          period = $urandom_range(1, 200);
          if (roll < 5) begin
            // normal: duty strictly inside the period
            n_norm++;
            duty = $urandom_range(1, period - 1);
          end else if (roll < 8) begin
            // boundary: duty==0 (never high) or duty==period (always high)
            n_bnd++;
            duty = ($urandom_range(0, 1) == 0) ? 0 : period;
          end else begin
            // misuse: duty > period -> output always high
            n_ovf++;
            duty = period + $urandom_range(1, 50);
          end
          wr(4'd0, period);
          wr(4'd1, duty);
          wait (dut.counter == 0);
          high = 0;
          repeat (period) begin
            @(posedge clk); #1;
            if (dut.pwm_out) high++;
          end
          if (high != ((duty > period) ? period : duty)) begin
            errors++;
            $display("ERROR: CRV PWM period=%0d duty=%0d high_count=%0d exp=%0d",
                     period, duty, high, (duty > period) ? period : duty);
          end
        end
      end
      // long-period run: walk the counter through its upper bits
      // (coverage: counter[k] toggles require a >= 2^k single period)
      begin
        int high2;
        wr(4'd0, 32'h0040_0000);      // period = 2^22
        wr(4'd1, 32'h0020_0000);      // duty   = 2^21
        wait (dut.counter == 0);
        high2 = 0;
        repeat (32'h0040_0000) begin
          @(posedge clk); #1;
          if (dut.pwm_out) high2++;
        end
        if (high2 != 32'h0020_0000) begin
          errors++;
          $display("ERROR: CRV PWM long period high_count=%0d exp=%0d",
                   high2, 32'h0020_0000);
        end
      end
      $display("CRV: 110 txns (norm=%0d boundary=%0d ovf=%0d illegal=%0d) + 2^22 long period",
               n_norm, n_bnd, n_ovf, n_ill);
    end
`endif

    if (errors == 0) $display("TEST PASSED: PWM");
    else             $display("TEST FAILED: %0d errors", errors);
`ifdef VERILATOR
    $display("FSM_COV: N/A (no FSM: counter/combinational core)");
    $display("SVA_CHECKS: %0d/%0d", sva_total - sva_fail, sva_total);
`endif
    $finish;
  end

`ifdef VERILATOR
  // chunked timeout guard: a single long-pending #delay event corrupts the
  // 5.006 --timing delay heap once many short-delay resumptions interleave;
  // chunked delays keep all heap entries short-lived (see docs/COVERAGE.md)
  initial begin
    repeat (150000) #1000;  // 150 ms in 1-us chunks (covers the 2^22 run)
    $display("TIMEOUT"); $finish;
  end
`else
  initial begin
    #100_000; $display("TIMEOUT"); $finish;
  end
`endif
endmodule
