// SPDX-License-Identifier: Apache-2.0
// QSPI slave (std / quad, oversampled SCLK): concurrent SVA on what the
// master sees at each SCLK rising edge (MISO bit, quad nibbles, bus
// direction) against an independent shift model + functional coverage.
`include "cov_macros.svh"
module QSPI_sva (
  input logic       clk, rst_n, sclk, csn, wen, ren, irq,
  input logic [3:0] waddr, raddr, io_oe,
  input logic [7:0] wdata, rdata,
  input wire  [3:0] io
);
  `COV_CLOCKING(clk, !rst_n)
  logic       m_sclk_d, m_done, m_dir, m_q;
  logic [1:0] m_mode;
  logic [2:0] m_bit;
  logic [7:0] m_rx, m_tx;
  wire rise = !csn && sclk && !m_sclk_d;
  wire std  = m_mode == 0;
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      m_sclk_d <= 0; m_done <= 0; m_dir <= 0; m_q <= 0; m_mode <= 0; m_bit <= 0;
      m_rx <= 0; m_tx <= 0;
    end else begin
      m_sclk_d <= sclk;
      m_done <= rise && (std ? m_bit == 7 : m_q);
      if (wen && waddr == 0) m_tx <= wdata;
      if (wen && waddr == 2) m_mode <= wdata[1:0];
      if (wen && waddr == 3) m_dir <= wdata[0];
      if (rise) begin
        if (std) begin m_rx <= {m_rx[6:0], io[0]}; m_bit <= m_bit + 1; end
        else begin m_rx <= {m_rx[3:0], io}; m_q <= !m_q; end
      end
      if (csn) begin m_bit <= 0; m_q <= 0; end
    end
  end

  `SVA_RST(a_reset_idle, !rst_n, !irq && io_oe == 4'b0010)
  `SVA_IMP(a_std_miso_bit, rise && std, io_oe == 4'b0010 && io[1] == m_tx[3'd7 - m_bit])
  `SVA_IMP(a_quad_read_nibble, rise && !std && !m_dir,
           io_oe == 4'b1111 && io == (m_q ? m_tx[3:0] : m_tx[7:4]))
  `SVA_IMP(a_quad_write_released, rise && !std && m_dir, io_oe == 4'b0000)
  `SVA_IMP(a_irq_byte_done, 1'b1, irq == m_done)
  `SVA_IMP(a_read_mux, 1'b1, rdata == (raddr == 0 ? m_rx : raddr == 1 ? m_tx : 8'h00))

  covergroup cg_qspi @(posedge clk);
    option.per_instance = 1;
    cp_mode: coverpoint {std, m_dir} iff (rst_n && rise)
      { bins std_ = {2'b10, 2'b11}; bins quad_read = {2'b00}; bins quad_write = {2'b01}; }
    cp_mode_enc: coverpoint m_mode iff (rst_n && rise);
    cp_nibble: coverpoint io iff (rst_n && rise && !std && m_dir);
  endgroup
  cg_qspi u_cg_qspi = new;

  `FC(multi_byte_quad_read, m_done && !std && !m_dir ##[1:20] rise)
  `FC(abort_mid_byte, $rose(csn) && (m_bit != 0 || m_q))
  `FC(mode_switch_while_idle, wen && waddr == 2 && csn)
  `FC_RST(reset_mid_frame, rst_n && !csn ##1 !rst_n)
endmodule

bind QSPI_top QSPI_sva u_sva (.*);
