// SPDX-License-Identifier: Apache-2.0
// RGMII datapath: concurrent SVA for the clk -> tx_clk TX FIFO (byte order
// and integrity of the DDR nibble pair, no transmit from empty) and the
// oversampled DDR RX capture (nibble pairing, count, read port, irq).
`include "cov_macros.svh"
module RGMII_sva #(parameter int DEPTH = 16) (
  input logic       clk, rst_n, tx_clk, rx_clk, tx_ctl, rx_ctl, wen, ren, irq,
  input logic       tx_full, tx_ctl_q,
  input logic [3:0] txd, rxd, txd_hi, txd_lo, waddr, raddr,
  input logic [7:0] wdata, rdata,
  input logic [4:0] count
);
  `COV_CLOCKING(clk, !rst_n)
  wire acc = wen && waddr == 0 && !tx_full;

  // TX reference queue: pushed on accepted host writes, popped once the
  // byte has been presented on the DDR pins for one tx_clk cycle
  logic [7:0] m_q [0:255];
  int         m_wp, m_rp;
  always_ff @(posedge clk or negedge rst_n)
    if (!rst_n) m_wp <= 0;
    else if (acc) begin m_q[m_wp % 256] <= wdata; m_wp <= m_wp + 1; end
  always_ff @(posedge tx_clk or negedge rst_n)
    if (!rst_n) m_rp <= 0;
    else if (tx_ctl) m_rp <= m_rp + 1;

  // RX reference: data valid in the half period before each rx_clk edge,
  // high nibble before the falling edge, low nibble before the rising edge
  // (pins sampled twice so the data used is the last value before the edge)
  logic       m_c1, m_c2, m_v1, m_v, m_half, m_ab;
  logic [3:0] m_d1, m_d, m_hi;
  logic [4:0] m_wr;
  logic [7:0] m_ring [0:DEPTH-1];
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      m_c1 <= 0; m_c2 <= 0; m_v1 <= 0; m_v <= 0; m_d1 <= 0; m_d <= 0; m_wr <= 0; m_half <= 0; m_hi <= 0; m_ab <= 0;
    end else begin
      m_c1 <= rx_clk; m_c2 <= m_c1; m_v1 <= rx_ctl; m_v <= m_v1; m_d1 <= rxd; m_d <= m_d1; m_ab <= 0;
      if (m_c1 != m_c2) begin
        if (!m_c1) begin m_hi <= m_d; m_half <= m_v; end
        else begin
          if (m_v && m_half) begin m_ring[m_wr[3:0]] <= {m_hi, m_d}; m_wr <= m_wr + 1; end
          m_ab <= m_half && !m_v;
          m_half <= 0;
        end
      end
    end
  end

  `SVA_RST(a_reset_idle, !rst_n, count == 0 && !tx_ctl)
  `SVA_INV(a_ddr_mux, txd == (tx_clk ? txd_hi : txd_lo))
  `SVA_IMP_CK(a_tx_byte_order, tx_clk, tx_ctl, m_rp < m_wp && {txd_hi, txd_lo} == m_q[m_rp % 256])
  `SVA_IMP(a_full_means_backlog, tx_full, m_wp - m_rp >= 4)
  `SVA_IMP(a_rx_count_model, 1'b1, count == m_wr)
  `SVA_IMP(a_rx_read_model, ren && 5'(raddr) < m_wr, rdata == m_ring[raddr])
  `SVA_IMP(a_irq_model, 1'b1, irq == (m_wr != 0 && ren))

  `FC(write_dropped_when_full, wen && waddr == 0 && tx_full)
  `FC(tx_fifo_full, tx_full)
  `FC(write_other_addr, wen && waddr != 0)
  `FC_CK(tx_back_to_back, tx_clk, tx_ctl ##1 tx_ctl)
  `FC_CK(tx_gap, tx_clk, tx_ctl ##1 !tx_ctl ##1 tx_ctl)
  `FC(rx_half_byte_aborted, m_ab)
  `FC(rx_low_nibble_without_high, m_c1 && !m_c2 && m_v && !m_half)
  `FC(rx_ring_wraps, count == 5'd16 ##[1:400] count == 5'd17)
  `FC_RST(reset_with_tx_pending, rst_n && m_wp != m_rp ##1 !rst_n)
endmodule

bind RGMII_top RGMII_sva #(.DEPTH(DEPTH)) u_sva (.*);
