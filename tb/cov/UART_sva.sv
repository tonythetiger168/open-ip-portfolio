// SPDX-License-Identifier: Apache-2.0
// UART 8N1: concurrent SVA against an independent pin-level model, written
// as tick counters over a whole frame (not per-bit states):
//  * TX: m_tt counts 16x ticks since accept; txd = start for ticks 0..15,
//    data bit k for 16(k+1)..16(k+1)+15, stop for 144..159, idle at 160.
//  * RX: own 2-flop synchroniser; m_rt counts ticks since the start edge;
//    start re-check at tick 7, data bit i at 23+16i, stop at 151.
// + functional coverage of handshake, glitches, errors, break, duplex, reset.
`include "cov_macros.svh"
module UART_sva #(parameter int DIV16 = 27) (
  input logic       clk, rst_n, rxd, txd, tx_valid, tx_ready, rx_valid, irq,
  input logic [7:0] tx_data, rx_data
);
  `COV_CLOCKING(clk, !rst_n)

  // ---- 16x tick
  int   m_div;
  logic m_tick;
  always_ff @(posedge clk or negedge rst_n)
    if (!rst_n) begin m_div <= 0; m_tick <= 0; end
    else begin
      m_tick <= (m_div == DIV16 - 1);
      m_div  <= (m_div == DIV16 - 1) ? 0 : m_div + 1;
    end

  // ---- TX
  logic       m_tbusy;
  logic [7:0] m_tt;
  logic [7:0] m_tsh;
  wire  [3:0] m_tslot = m_tt[7:4];             // 0 start, 1..8 data, 9 stop
  wire        m_txd = !m_tbusy ? 1'b1 : m_tslot == 0 ? 1'b0 :
                      m_tslot == 9 ? 1'b1 : m_tsh[m_tslot - 1];
  always_ff @(posedge clk or negedge rst_n)
    if (!rst_n) begin m_tbusy <= 0; m_tt <= 0; m_tsh <= 0; end
    else if (!m_tbusy) begin
      if (tx_valid) begin m_tbusy <= 1; m_tt <= 0; m_tsh <= tx_data; end
    end else if (m_tick) begin
      m_tt <= m_tt + 1;
      if (m_tt == 159) m_tbusy <= 0;
    end

  // ---- RX
  logic       m_s1, m_s2, m_rbusy, m_rvalid, m_ferr;
  logic [7:0] m_rt, m_rsh, m_rdata;
  logic       v_glitch;                      // start re-check failed this clock
  always_ff @(posedge clk or negedge rst_n)
    if (!rst_n) begin
      m_s1 <= 1; m_s2 <= 1; m_rbusy <= 0; m_rvalid <= 0; m_ferr <= 0;
      m_rt <= 0; m_rsh <= 0; m_rdata <= 0; v_glitch = 0;
    end else begin
      v_glitch = 0;
      m_s1 <= rxd; m_s2 <= m_s1;
      m_rvalid <= 0; m_ferr <= 0;
      if (!m_rbusy) begin
        if (m_s2 && !m_s1) begin m_rbusy <= 1; m_rt <= 0; end
      end else if (m_tick) begin
        m_rt <= m_rt + 1;
        if (m_rt == 7 && m_s1) begin m_rbusy <= 0; v_glitch = 1; end
        if (m_rt >= 23 && m_rt <= 135 && m_rt[3:0] == 4'd7) m_rsh <= {m_s1, m_rsh[7:1]};
        if (m_rt == 151) begin
          m_rbusy <= 0;
          if (m_s1) begin m_rvalid <= 1; m_rdata <= m_rsh; end
          else m_ferr <= 1;
        end
      end
    end

  `SVA_RST(a_reset_idle, !rst_n, txd && tx_ready && !rx_valid && !irq && rx_data == 0)
  `SVA_INV(a_txd_model, txd == m_txd)
  `SVA_INV(a_tx_ready_model, tx_ready == !m_tbusy)
  `SVA_NXT(a_accept_starts_frame, tx_valid && tx_ready, !txd && !tx_ready)
  `SVA_INV(a_rx_valid_model, rx_valid == m_rvalid)
  `SVA_INV(a_rx_data_model, rx_data == m_rdata)
  `SVA_INV(a_irq_model, irq == (m_rvalid || m_ferr))
  `SVA_IMP(a_frame_error_drops_byte, m_ferr, irq && !rx_valid)

  covergroup cg_uart @(posedge clk);
    option.per_instance = 1;
    cp_tx_byte: coverpoint tx_data iff (rst_n && tx_valid && tx_ready);
    cp_rx_byte: coverpoint rx_data iff (rst_n && rx_valid);
  endgroup
  cg_uart u_cg_uart = new;

  `FC(tx_back_to_back, $rose(tx_ready) && tx_valid)
  `FC(tx_valid_held_while_busy, tx_valid && !tx_ready)
  `FC(tx_idle_gap, tx_ready && !tx_valid)
  `FC(rx_start_glitch_rejected, v_glitch)
  `FC(rx_framing_error, m_ferr)
  `FC(rx_break, m_ferr && m_rsh == 8'h00)
  `FC(rx_back_to_back, m_rvalid ##[1:30] (m_s2 && !m_s1))
  `FC(rx_byte_00, m_rvalid && m_rdata == 8'h00)
  `FC(rx_byte_ff, m_rvalid && m_rdata == 8'hFF)
  `FC(full_duplex, m_tbusy && m_rbusy && m_tt > 16 && m_rt > 16)
  `FC_RST(reset_mid_tx, rst_n && m_tbusy && m_tt > 16 ##1 !rst_n)
  `FC_RST(reset_mid_rx, rst_n && m_rbusy && m_rt > 16 ##1 !rst_n)
endmodule

bind UART_top UART_sva #(.DIV16((CLK_FREQ / BAUD) / 16)) u_sva (.*);
