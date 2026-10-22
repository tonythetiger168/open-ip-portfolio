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
  endgroup
  cg_io u_cg_io = new;

  `FC(irq_rises, $rose(irq))
  `FC(irq_falls, $fell(irq))
  `FC(input_changes_mixed_oe, gpio_oe != 0 && gpio_oe != 8'hFF && $changed(m_in))
  `FC_RST(reset_with_output_set, rst_n && m_out != 0 ##1 !rst_n)
endmodule

bind GPIO_top GPIO_sva u_sva (.*);
