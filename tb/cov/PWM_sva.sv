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

  `FC(period_shrunk_below_count, wen && waddr == 0 && wdata != 0 && m_cnt >= wdata)
  `FC(duty_changed_mid_period, wen && waddr == 1 && m_cnt != 0)
  `FC(disable_while_running, wen && waddr == 0 && wdata == 0 && m_per != 0)
  `FC_RST(reset_while_running, rst_n && m_per != 0 && m_cnt != 0 ##1 !rst_n)
endmodule

bind PWM_top PWM_sva #(.DW(DW)) u_sva (.*);
