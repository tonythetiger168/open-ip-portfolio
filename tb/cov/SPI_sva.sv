// SPDX-License-Identifier: Apache-2.0
// SPI slave (mode 0, oversampled SCLK): concurrent SVA against an
// independent shift model (rising-edge capture, MSB-first MISO, byte-done
// irq, CSn abort) + functional coverage.
`include "cov_macros.svh"
module SPI_sva (
  input logic       clk, rst_n, sclk, mosi, miso, csn, wen, ren, irq,
  input logic [3:0] waddr, raddr,
  input logic [7:0] wdata, rdata
);
  `COV_CLOCKING(clk, !rst_n)
  logic       m_sclk_d, m_done;
  logic [2:0] m_bit;
  logic [7:0] m_rx, m_tx;
  wire rise = !csn && sclk && !m_sclk_d;
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin m_sclk_d <= 0; m_done <= 0; m_bit <= 0; m_rx <= 0; m_tx <= 0; end
    else begin
      m_sclk_d <= sclk;
      m_done <= rise && m_bit == 7;
      if (wen && waddr == 0) m_tx <= wdata;
      if (rise) begin m_rx <= {m_rx[6:0], mosi}; m_bit <= m_bit + 1; end
      if (csn) m_bit <= 0;
    end
  end

  `SVA_RST(a_reset_idle, !rst_n, !irq && rdata == 0 && miso == 0)
  `SVA_IMP(a_miso_model, 1'b1, miso == m_tx[3'd7 - m_bit])
  `SVA_IMP(a_read_mux, 1'b1, rdata == (raddr == 0 ? m_rx : raddr == 1 ? m_tx : 8'h00))
  `SVA_IMP(a_irq_byte_done, 1'b1, irq == m_done)
  `SVA_NXT(a_csn_resets_count, csn, miso == m_tx[7])

  covergroup cg_spi @(posedge clk);
    option.per_instance = 1;
    cp_bit: coverpoint m_bit iff (rst_n && rise);
    cp_mosi: coverpoint mosi iff (rst_n && rise);
  endgroup
  cg_spi u_cg_spi = new;

  `FC(back_to_back_bytes, m_done && !csn ##[1:40] rise)
  `FC(abort_mid_byte, $rose(csn) && m_bit != 0)
  `FC(tx_write_during_transfer, wen && waddr == 0 && !csn && m_bit != 0)
  `FC(sclk_while_deselected, csn && sclk && !m_sclk_d)
  `FC_RST(reset_mid_byte, rst_n && !csn && m_bit != 0 ##1 !rst_n)
endmodule

bind SPI_top SPI_sva u_sva (.*);
