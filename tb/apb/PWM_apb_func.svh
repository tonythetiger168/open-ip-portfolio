// SPDX-License-Identifier: Apache-2.0
// PWM-specific part of tb/PWM_apb_tb.sv.
// Covered through the registers: PERIOD and DUTY written (every data bit
// both ways), the output's high time and period measured on the pins for
// several settings (duty 0, duty past the period, period 0 holding the
// output low), pwm_n_out the complement, PERIOD_END once per period, a
// partial write dropped with PSLVERR, the write-only words reading 0.
// measure one period: clocks high, clocks per period (from PERIOD_END)
task automatic measure(input int p, input int d);
  int hi, n;
  bit done;
  // align on the core's period end
  while (!dut.u_core.irq) @(negedge PCLK);
  @(negedge PCLK);
  hi = 0; n = 0;
  // each clock of the next period, up to and including its last
  done = 0;
  while (!done) begin
    if (pwm_out) hi++;
    if (pwm_n_out !== !pwm_out) fail("pwm_n_out not the complement");
    n++;
    done = dut.u_core.irq || n >= 10 * p;
    if (!done) @(negedge PCLK);
  end
  if (n != p) fail($sformatf("period %0d clocks, expected %0d", n, p));
  if (hi != (d < p ? d : p)) fail($sformatf("high %0d clocks, expected %0d (period %0d, duty %0d)", hi, d < p ? d : p, p, d));
endtask
task automatic set(input int p, input int d);
  wr(A_DUTY, d); wr(A_PERIOD, p);
  cycles(p + 2);
endtask
task automatic irq_expect(input int b);
  cycles(3);
  rd(A_IRQ_STATUS);
  if (!rdv[b]) fail($sformatf("IRQ bit %0d not set (%h)", b, rdv));
  if (!irq) fail("irq low with an enabled bit set");
  wr(A_IRQ_STATUS, 32'(1) << b);
endtask

task automatic ip_func;
  rd_exp(A_FLAGS, 0);
  // stopped: output low, no period end
  cycles(5);
  if (pwm_out !== 0 || pwm_n_out !== 1) fail("output not low while stopped");
  rd_exp(A_IRQ_STATUS, 0);
  // every data bit both ways (the core's counter then wraps at once)
  wr(A_DUTY, 32'hFFFF_FFFF); wr(A_PERIOD, 32'hFFFF_FFFF);
  rd_exp(A_PERIOD, 0); rd_exp(A_DUTY, 0);                 // write-only
  apb(1, A_PERIOD, 32'h5, 4'h3);                         // partial: dropped
  if (!rerr) fail("no PSLVERR on a partial write to PERIOD");
  wr(A_DUTY, 0); wr(A_PERIOD, 0);
  cycles(3);
  if (pwm_out !== 0) fail("output not low after PERIOD 0");
  wr(A_IRQ_ENABLE, IRQ_ALL);
  set(10, 3);  measure(10, 3);
  irq_expect(IRQ_PERIOD_END);
  set(7, 0);   measure(7, 0);
  set(6, 6);   measure(6, 6);
  set(5, 9);   measure(5, 9);
  set(1, 1);   measure(1, 1);
  for (int k = 0; k < 8; k++) begin : b_rnd
    int p, d;
    p = 2 + $urandom % 30; d = $urandom % (p + 3);
    set(p, d); measure(p, d);
  end
  // stopped again: low, no period end
  wr(A_PERIOD, 0);
  cycles(3);
  wr(A_IRQ_STATUS, IRQ_ALL);
  cycles(20);
  rd_exp(A_IRQ_STATUS, 0);
  if (pwm_out !== 0) fail("output not low after PERIOD 0");
  // masked, left pending into reset
  wr(A_IRQ_ENABLE, 0);
  set(4, 2);
  if (irq) fail("irq with PERIOD_END masked");
  rd_exp(A_IRQ_STATUS, 32'(1) << IRQ_PERIOD_END);
endtask
