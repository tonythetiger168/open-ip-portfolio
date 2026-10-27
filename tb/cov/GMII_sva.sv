// SPDX-License-Identifier: Apache-2.0
// GMII datapath: concurrent SVA for the clk -> tx_clk TX FIFO (order and
// integrity of transmitted bytes, no transmit from empty) and the
// oversampled RX capture ring (count, read port, irq) + coverage.
`include "cov_macros.svh"
module GMII_sva #(parameter int DEPTH = 16) (
  input logic       clk, rst_n, tx_clk, rx_clk, tx_en, tx_er, rx_dv, rx_er, wen, ren, irq,
  input logic       tx_full,
  input logic [7:0] txd, rxd, wdata, rdata,
  input logic [3:0] waddr, raddr,
  input logic [4:0] count
);
  `COV_CLOCKING(clk, !rst_n)
  wire acc = wen && waddr == 0 && !tx_full;

  // TX reference queue: pushed on accepted host writes, popped when the
  // byte is seen on txd/tx_en (one tx_clk after the DUT pops it)
  logic [7:0] m_q [0:255];
  int         m_wp, m_rp;
  always_ff @(posedge clk or negedge rst_n)
    if (!rst_n) m_wp <= 0;
    else if (acc) begin m_q[m_wp % 256] <= wdata; m_wp <= m_wp + 1; end
  always_ff @(posedge tx_clk or negedge rst_n)
    if (!rst_n) m_rp <= 0;
    else if (tx_en) m_rp <= m_rp + 1;

  // RX reference ring (independent oversampling model)
  logic       m_c1, m_c2, m_dv;
  logic [7:0] m_d;
  logic [4:0] m_wr;
  logic [7:0] m_ring [0:DEPTH-1];
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin m_c1 <= 0; m_c2 <= 0; m_dv <= 0; m_d <= 0; m_wr <= 0; end
    else begin
      m_c1 <= rx_clk; m_c2 <= m_c1; m_dv <= rx_dv; m_d <= rxd;
      if (m_c1 && !m_c2 && m_dv) begin m_ring[m_wr[3:0]] <= m_d; m_wr <= m_wr + 1; end
    end
  end

  `SVA_RST(a_reset_idle, !rst_n, count == 0 && !tx_en)
  `SVA_INV(a_tx_er_low, !tx_er)
  `SVA_IMP_CK(a_tx_byte_order, tx_clk, tx_en, m_rp < m_wp && txd == m_q[m_rp % 256])
  `SVA_IMP(a_full_means_backlog, tx_full, m_wp - m_rp >= 4)
  `SVA_IMP(a_rx_count_model, 1'b1, count == m_wr)
  `SVA_IMP(a_rx_read_model, ren && raddr < m_wr && m_wr <= DEPTH, rdata == m_ring[raddr])
  `SVA_IMP(a_irq_model, 1'b1, irq == (m_wr != 0 && ren))

  // TX backlog at each accepted write, transmitted / captured byte
  // classes, every RX ring slot written and read, rx_er on a captured byte
  function automatic logic [1:0] bcls(input logic [7:0] v);
    bcls = (v == 8'h00) ? 2'd0 : (v == 8'hFF) ? 2'd1 : (v == 8'h55 || v == 8'hAA) ? 2'd2 : 2'd3;
  endfunction
  logic m_er;
  always_ff @(posedge clk or negedge rst_n)
    if (!rst_n) m_er <= 0; else m_er <= rx_er;
  wire m_cap = m_c1 && !m_c2 && m_dv;
  covergroup cg_host @(posedge clk);
    option.per_instance = 1;
    cp_backlog: coverpoint (m_wp - m_rp) iff (rst_n && acc)
      { bins empty = {0}; bins partial = {[1:3]}; bins deep = {[4:16]}; }
    cp_wdata: coverpoint bcls(wdata) iff (rst_n && acc)
      { bins zero = {0}; bins ones = {1}; bins alt = {2}; bins other = {3}; }
    cp_rxdata: coverpoint bcls(m_d) iff (rst_n && m_cap)
      { bins zero = {0}; bins ones = {1}; bins alt = {2}; bins other = {3}; }
    cp_slot: coverpoint m_wr[3:0] iff (rst_n && m_cap) { bins s[] = {[0:DEPTH-1]}; }
    cp_rslot: coverpoint raddr iff (rst_n && ren && m_wr != 0) { bins s[] = {[0:DEPTH-1]}; }
    cp_er: coverpoint m_er iff (rst_n && m_cap) { bins clean = {0}; bins rx_er = {1}; }
  endgroup
  cg_host u_cg_host = new;
  covergroup cg_txd @(posedge tx_clk);
    option.per_instance = 1;
    cp_txd: coverpoint bcls(txd) iff (rst_n && tx_en)
      { bins zero = {0}; bins ones = {1}; bins alt = {2}; bins other = {3}; }
  endgroup
  cg_txd u_cg_txd = new;

  `FC(write_dropped_when_full, wen && waddr == 0 && tx_full)
  `FC(tx_fifo_full, tx_full)
  `FC(write_other_addr, wen && waddr != 0)
  `FC_CK(tx_back_to_back, tx_clk, tx_en ##1 tx_en)
  `FC_CK(tx_gap, tx_clk, tx_en ##1 !tx_en ##1 tx_en)
  `FC(rx_ring_wraps, count == 5'd16 ##[1:200] count == 5'd17)
  `FC_RST(reset_with_tx_pending, rst_n && m_wp != m_rp ##1 !rst_n)
endmodule

bind GMII_top GMII_sva #(.DEPTH(DEPTH)) u_sva (.*);
