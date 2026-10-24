// SPDX-License-Identifier: Apache-2.0
// GPIO: concurrent SVA against an independent register/pin model (per-pin
// output enable, one-cycle input sample, read mux, level irq) + coverage.
`include "cov_macros.svh"
module GPIO_sva (
  input logic       clk, rst_n, wen, ren, irq,
  input logic [3:0] waddr, raddr,
  input logic [7:0] wdata, rdata, gpio_oe,
  input wire  [7:0] gpio
);
  `COV_CLOCKING(clk, !rst_n)
  logic [7:0] m_out, m_in;
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin m_out <= 0; m_in <= 0; end
    else begin
      if (wen && waddr == 0) m_out <= wdata;
      m_in <= gpio;
    end
  end

  `SVA_RST(a_reset_clear, !rst_n, rdata == 0 && !irq)
  `SVA_IMP(a_pins_driven, gpio_oe != 0, (gpio & gpio_oe) === (m_out & gpio_oe))
  `SVA_IMP(a_read_mux, 1'b1, rdata === (raddr == 0 ? m_in : raddr == 1 ? m_out : 8'h00))
  `SVA_IMP(a_irq_level, 1'b1, irq == |m_in)

  covergroup cg_io @(posedge clk);
    option.per_instance = 1;
    cp_oe: coverpoint gpio_oe iff (rst_n)
      { bins all_in = {8'h00}; bins all_out = {8'hFF}; bins mixed = default; }
    cp_waddr: coverpoint waddr iff (rst_n && wen) { bins out_reg = {0}; bins other = {[1:15]}; }
    cp_raddr: coverpoint raddr iff (rst_n && ren) { bins in_reg = {0}; bins out_reg = {1}; bins other = {[2:15]}; }
    cp_wdata: coverpoint dcls(wdata) iff (rst_n && wen && waddr == 0) { bins zero = {0}; bins ones = {1}; bins alt = {2}; bins other = {3}; }
    cp_rdata: coverpoint dcls(rdata) iff (rst_n && ren && raddr <= 1) { bins zero = {0}; bins ones = {1}; bins alt = {2}; bins other = {3}; }
    cp_rreg: coverpoint raddr iff (rst_n && ren && raddr <= 1) { bins in_reg = {0}; bins out_reg = {1}; }
    x_read: cross cp_rreg, cp_rdata;
  endgroup
  function automatic int dcls(input logic [7:0] v);
    dcls = v == 0 ? 0 : v == 8'hFF ? 1 : (v == 8'h55 || v == 8'hAA) ? 2 : 3;
  endfunction
  cg_io u_cg_io = new;

  `FC(irq_rises, $rose(irq))
  `FC(irq_falls, $fell(irq))
  `FC(input_changes_mixed_oe, gpio_oe != 0 && gpio_oe != 8'hFF && $changed(m_in))

  // per pin: driven low and high as an output, rising and falling edge as an
  // input (oe low), and the pin alone holding the level irq
  logic [7:0] m_in_d, m_oe_d;
  always_ff @(posedge clk or negedge rst_n)
    if (!rst_n) begin m_in_d <= 0; m_oe_d <= 0; end else begin m_in_d <= m_in; m_oe_d <= gpio_oe; end
  `FC(pin0_drive_0, gpio_oe[0] && m_out[0] == 1'b0)
  `FC(pin0_drive_1, gpio_oe[0] && m_out[0] == 1'b1)
  `FC(pin0_input_rise, !m_oe_d[0] && m_in[0] && !m_in_d[0])
  `FC(pin0_input_fall, !m_oe_d[0] && !m_in[0] && m_in_d[0])
  `FC(pin0_sole_irq_source, m_in == 8'h01 && irq)
  `FC(pin1_drive_0, gpio_oe[1] && m_out[1] == 1'b0)
  `FC(pin1_drive_1, gpio_oe[1] && m_out[1] == 1'b1)
  `FC(pin1_input_rise, !m_oe_d[1] && m_in[1] && !m_in_d[1])
  `FC(pin1_input_fall, !m_oe_d[1] && !m_in[1] && m_in_d[1])
  `FC(pin1_sole_irq_source, m_in == 8'h02 && irq)
  `FC(pin2_drive_0, gpio_oe[2] && m_out[2] == 1'b0)
  `FC(pin2_drive_1, gpio_oe[2] && m_out[2] == 1'b1)
  `FC(pin2_input_rise, !m_oe_d[2] && m_in[2] && !m_in_d[2])
  `FC(pin2_input_fall, !m_oe_d[2] && !m_in[2] && m_in_d[2])
  `FC(pin2_sole_irq_source, m_in == 8'h04 && irq)
  `FC(pin3_drive_0, gpio_oe[3] && m_out[3] == 1'b0)
  `FC(pin3_drive_1, gpio_oe[3] && m_out[3] == 1'b1)
  `FC(pin3_input_rise, !m_oe_d[3] && m_in[3] && !m_in_d[3])
  `FC(pin3_input_fall, !m_oe_d[3] && !m_in[3] && m_in_d[3])
  `FC(pin3_sole_irq_source, m_in == 8'h08 && irq)
  `FC(pin4_drive_0, gpio_oe[4] && m_out[4] == 1'b0)
  `FC(pin4_drive_1, gpio_oe[4] && m_out[4] == 1'b1)
  `FC(pin4_input_rise, !m_oe_d[4] && m_in[4] && !m_in_d[4])
  `FC(pin4_input_fall, !m_oe_d[4] && !m_in[4] && m_in_d[4])
  `FC(pin4_sole_irq_source, m_in == 8'h10 && irq)
  `FC(pin5_drive_0, gpio_oe[5] && m_out[5] == 1'b0)
  `FC(pin5_drive_1, gpio_oe[5] && m_out[5] == 1'b1)
  `FC(pin5_input_rise, !m_oe_d[5] && m_in[5] && !m_in_d[5])
  `FC(pin5_input_fall, !m_oe_d[5] && !m_in[5] && m_in_d[5])
  `FC(pin5_sole_irq_source, m_in == 8'h20 && irq)
  `FC(pin6_drive_0, gpio_oe[6] && m_out[6] == 1'b0)
  `FC(pin6_drive_1, gpio_oe[6] && m_out[6] == 1'b1)
  `FC(pin6_input_rise, !m_oe_d[6] && m_in[6] && !m_in_d[6])
  `FC(pin6_input_fall, !m_oe_d[6] && !m_in[6] && m_in_d[6])
  `FC(pin6_sole_irq_source, m_in == 8'h40 && irq)
  `FC(pin7_drive_0, gpio_oe[7] && m_out[7] == 1'b0)
  `FC(pin7_drive_1, gpio_oe[7] && m_out[7] == 1'b1)
  `FC(pin7_input_rise, !m_oe_d[7] && m_in[7] && !m_in_d[7])
  `FC(pin7_input_fall, !m_oe_d[7] && !m_in[7] && m_in_d[7])
  `FC(pin7_sole_irq_source, m_in == 8'h80 && irq)
  `FC_RST(reset_with_output_set, rst_n && m_out != 0 ##1 !rst_n)
endmodule

bind GPIO_top GPIO_sva u_sva (.*);
