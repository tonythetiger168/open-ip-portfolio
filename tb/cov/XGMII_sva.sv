// SPDX-License-Identifier: Apache-2.0
// XGMII datapath: concurrent SVA for the byte packer + clk -> tx_clk word
// FIFO (column contents, lane padding, order) and the RX lane-compacting
// capture ring (count, read port, irq), with an independent model of each.
`include "cov_macros.svh"
module XGMII_sva #(parameter int DEPTH = 16) (
  input logic        clk, rst_n, tx_clk, rx_clk, wen, ren, irq, tx_full,
  input logic [31:0] txd, rxd,
  input logic [3:0]  txc, rxc, waddr, raddr,
  input logic [7:0]  wdata, rdata,
  input logic [4:0]  count
);
  `COV_CLOCKING(clk, !rst_n)
  wire wr_byte = wen && waddr == 0;
  wire wr_eof  = wen && waddr == 1;

  // TX model: packer + queue of expected columns
  logic [31:0] m_pk;
  int          m_pn;
  logic [31:0] m_qd [0:255];
  logic [3:0]  m_qc [0:255];
  int          m_wp, m_rp;
  function automatic logic [3:0] ctl_of(int n);   // control lanes above n bytes
    return 4'hF << n;
  endfunction
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin m_pk <= 0; m_pn <= 0; m_wp <= 0; end
    else if (wr_byte && m_pn == 3) begin
      if (!tx_full) begin
        m_qd[m_wp % 256] <= {wdata, m_pk[23:0]}; m_qc[m_wp % 256] <= 4'h0;
        m_wp <= m_wp + 1; m_pn <= 0;
      end
    end else if (wr_byte) begin
      m_pk[8*m_pn +: 8] <= wdata; m_pn <= m_pn + 1;
    end else if (wr_eof && m_pn != 0 && !tx_full) begin
      for (int l = 0; l < 4; l++)
        m_qd[m_wp % 256][8*l +: 8] <= (l < m_pn) ? m_pk[8*l +: 8] : 8'h07;
      m_qc[m_wp % 256] <= ctl_of(m_pn);
      m_wp <= m_wp + 1; m_pn <= 0;
    end
  end
  always_ff @(posedge tx_clk or negedge rst_n)
    if (!rst_n) m_rp <= 0;
    else if (txc != 4'hF) m_rp <= m_rp + 1;

  // RX model: data lanes of each rx_clk column, compacted in lane order
  logic        m_c1, m_c2;
  logic [31:0] m_d;
  logic [3:0]  m_c;
  logic [4:0]  m_wr;
  logic [7:0]  m_ring [0:DEPTH-1];
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin m_c1 <= 0; m_c2 <= 0; m_d <= 0; m_c <= 4'hF; m_wr <= 0; end
    else begin
      m_c1 <= rx_clk; m_c2 <= m_c1; m_d <= rxd; m_c <= rxc;
      if (m_c1 && !m_c2) begin
        automatic logic [4:0] w = m_wr;
        for (int l = 0; l < 4; l++)
          if (!m_c[l]) begin m_ring[w[3:0]] <= m_d[8*l +: 8]; w = w + 1; end
        m_wr <= w;
      end
    end
  end

  // the tx_clk domain resets on its own clock until rst_n first falls
  logic txclk_seen = 1'b0;
  always @(posedge tx_clk) txclk_seen <= 1'b1;
  `SVA_RST(a_reset_idle, !rst_n && txclk_seen, count == 0 && txc == 4'hF)
  `SVA_INV(a_idle_lanes, (txc[0] -> txd[7:0] == 8'h07) && (txc[1] -> txd[15:8] == 8'h07) &&
                         (txc[2] -> txd[23:16] == 8'h07) && (txc[3] -> txd[31:24] == 8'h07))
  `SVA_IMP_CK(a_tx_column, tx_clk, txc != 4'hF,
              m_rp < m_wp && txd == m_qd[m_rp % 256] && txc == m_qc[m_rp % 256])
  `SVA_IMP(a_full_means_backlog, tx_full, m_wp - m_rp >= 2)
  `SVA_IMP(a_rx_count_model, 1'b1, count == m_wr)
  `SVA_IMP(a_rx_read_model, ren, rdata == m_ring[raddr])
  `SVA_IMP(a_irq_model, 1'b1, irq == (m_wr != 0 && ren))

  `FC(byte_dropped_when_full, wr_byte && m_pn == 3 && tx_full)
  `FC(eof_held_when_full, wr_eof && m_pn != 0 && tx_full)
  `FC(eof_with_empty_packer, wr_eof && m_pn == 0)
  `FC(write_other_addr, wen && waddr > 1)
  `FC_CK(tx_full_column, tx_clk, txc == 4'h0)
  `FC_CK(tx_3_bytes, tx_clk, txc == 4'h8)
  `FC_CK(tx_2_bytes, tx_clk, txc == 4'hC)
  `FC_CK(tx_1_byte,  tx_clk, txc == 4'hE)
  `FC_CK(tx_back_to_back, tx_clk, txc != 4'hF ##1 txc != 4'hF)
  `FC(rx_sparse_lanes, m_c1 && !m_c2 && m_c inside {4'b0101, 4'b1010, 4'b0110, 4'b1001})
  `FC(rx_ring_wraps, count == 5'd16 ##[1:400] count[4] == 1'b0)
  `FC_RST(reset_with_tx_pending, rst_n && (m_wp != m_rp || m_pn != 0) ##1 !rst_n)
endmodule

bind XGMII_top XGMII_sva #(.DEPTH(DEPTH)) u_sva (.*);
