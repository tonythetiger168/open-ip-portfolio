// SPDX-License-Identifier: Apache-2.0
// PWM: concurrent SVA against an independent period/duty counter model
// (complementary outputs, end-of-period irq) + functional coverage.
`include "cov_macros.svh"
module PWM_sva #(parameter int DW = 32) (
  input logic          clk, rst_n, wen, pwm_out, pwm_n_out, irq,
  input logic [3:0]    waddr,
  input logic [DW-1:0] wdata
);
  `COV_CLOCKING(clk, !rst_n)
  logic [DW-1:0] m_per, m_duty, m_cnt;
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin m_per <= 0; m_duty <= 0; m_cnt <= 0; end
    else begin
      if (wen && waddr == 0) m_per <= wdata;
      if (wen && waddr == 1) m_duty <= wdata;
      m_cnt <= (m_per == 0 || m_cnt >= m_per - 1) ? '0 : m_cnt + 1;
    end
  end

  `SVA_RST(a_reset_low, !rst_n, !pwm_out && pwm_n_out && !irq)
  `SVA_INV(a_complementary, pwm_n_out == !pwm_out)
  `SVA_IMP(a_pwm_model, 1'b1, pwm_out == (m_per != 0 && m_cnt < m_duty))
  `SVA_IMP(a_irq_model, 1'b1, irq == (m_per != 0 && m_cnt == m_per - 1))
  `SVA_IMP(a_disabled_low, m_per == 0, !pwm_out && !irq)

  covergroup cg_cfg @(posedge clk);
    option.per_instance = 1;
    cp_period: coverpoint m_per iff (rst_n && irq)
      { bins one = {1}; bins short_p = {[2:15]}; bins long_p = {[16:$]}; }
    cp_duty_rel: coverpoint (m_duty == 0 ? 0 : m_duty < m_per ? 1 : m_duty == m_per ? 2 : 3)
                 iff (rst_n && irq)
      { bins zero = {0}; bins in_period = {1}; bins equal = {2}; bins above = {3}; }
    cp_reg: coverpoint waddr iff (rst_n && wen) { bins period = {0}; bins duty = {1}; bins other = {[2:15]}; }
  endgroup
  cg_cfg u_cg_cfg = new;

  // period class x duty class, sampled at the end of each period
  // (period 1 has no duty strictly inside the period, and the max-partial
  // duty of a period of 1 is 0, so those combinations do not exist)
  function automatic logic [1:0] pcls(input logic [DW-1:0] p);
    pcls = (p == 1) ? 2'd0 : (p < 16) ? 2'd1 : 2'd2;
  endfunction
  function automatic logic [2:0] dcls(input logic [DW-1:0] d, input logic [DW-1:0] p);
    dcls = (d == 0) ? 3'd0 : (d == 1 && p > 2) ? 3'd1 : (d == p - 1 && p > 1) ? 3'd2 :
           (d < p) ? 3'd3 : (d == p) ? 3'd4 : 3'd5;
  endfunction
  covergroup cg_combo @(posedge clk);
    option.per_instance = 1;
    cp_combo: coverpoint {pcls(m_per), dcls(m_duty, m_per)} iff (rst_n && irq) {
      bins p1_zero = {5'b00_000}; bins p1_full = {5'b00_100}; bins p1_above = {5'b00_101};
      bins ps_zero = {5'b01_000}; bins ps_one = {5'b01_001}; bins ps_max = {5'b01_010};
      bins ps_mid = {5'b01_011}; bins ps_full = {5'b01_100}; bins ps_above = {5'b01_101};
      bins pl_zero = {5'b10_000}; bins pl_one = {5'b10_001}; bins pl_max = {5'b10_010};
      bins pl_mid = {5'b10_011}; bins pl_full = {5'b10_100}; bins pl_above = {5'b10_101};
    }
  endgroup
  cg_combo u_cg_combo = new;

  `FC(period_shrunk_below_count, wen && waddr == 0 && wdata != 0 && m_cnt >= wdata)
  `FC(duty_changed_mid_period, wen && waddr == 1 && m_cnt != 0)
  `FC(disable_while_running, wen && waddr == 0 && wdata == 0 && m_per != 0)
  `FC_RST(reset_while_running, rst_n && m_per != 0 && m_cnt != 0 ##1 !rst_n)
endmodule

bind PWM_top PWM_sva #(.DW(DW)) u_sva (.*);
