// SPDX-License-Identifier: Apache-2.0
// SPI_Host (SPI master, modes 0..3, 8-bit frames): concurrent SVA against an
// independent decoder of the SPI pins, + functional coverage. The decoder
// follows SCLK from the mode taken at START: CPHA 0 samples on the leading
// edge (the first MOSI bit is out before it), CPHA 1 on the trailing edge;
// it collects the 8 MOSI bits and the 8 MISO bits at the sampling edges and
// checks them against TX_DATA (MSB first) and RX_DATA at DONE. Also: MOSI
// only moves at shift edges (never at a sampling edge), 16 SCLK edges per
// frame, each half period at least DIV + 1 clocks, SCLK at CPOL while idle,
// CSN = ~CS, BUSY / DONE, START ignored while busy.
`include "cov_macros.svh"
module SPI_Host_sva #(parameter int NCS = 2) (
  input logic           clk, rst_n, sclk, mosi, miso, cpol, cpha, start, busy, done,
  input logic [NCS-1:0] csn, cs,
  input logic [15:0]    div,
  input logic [7:0]     tx_data, rx_data,
  input logic [4:0]     edge_n
);
  `COV_CLOCKING(clk, !rst_n)
  logic        sclk_q, miso_q, mosi_q, f_pol, f_pha;
  logic [7:0]  f_tx, d_mosi, d_miso;
  logic [4:0]  n_edge;
  logic [15:0] f_div, m_hc;
  wire         go = start && !busy;
  wire         edge_seen = busy && sclk != sclk_q;              // an edge happened at the last clock
  wire         lead = edge_seen && (sclk != f_pol);             // SCLK left its idle level
  wire         samp = edge_seen && (lead != f_pha);
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      sclk_q <= 0; miso_q <= 0; mosi_q <= 0; f_pol <= 0; f_pha <= 0; f_tx <= 0; d_mosi <= 0; d_miso <= 0;
      n_edge <= 0; f_div <= 0; m_hc <= 0;
    end else begin
      sclk_q <= sclk; miso_q <= miso; mosi_q <= mosi;
      m_hc <= (sclk != sclk_q) ? 16'd0 : (m_hc == 16'hFFFF ? m_hc : m_hc + 1);
      if (go) begin f_pol <= cpol; f_pha <= cpha; f_tx <= tx_data; n_edge <= 0; f_div <= div; m_hc <= 0; end
      if (edge_seen) begin
        n_edge <= n_edge + 1;
        // the edge was made at the last clock: MISO and MOSI as they were then
        if (samp) begin d_miso <= {d_miso[6:0], miso_q}; d_mosi <= {d_mosi[6:0], mosi_q}; end
      end
    end
  end

  `SVA_RST(a_reset_idle, !rst_n, !busy && !done && !sclk)
  `SVA_INV(a_csn, csn == ~cs)
  `SVA_NXT(a_start, go, busy)
  `SVA_NXT(a_start_ignored, start && busy && !done, !busy || edge_n >= $past(edge_n))
  `SVA_INV(a_idle_level, (!busy && $past(!busy) && $past(rst_n)) -> sclk == $past(cpol))
  `SVA_IMP(a_half_period, edge_seen && n_edge != 0, m_hc >= f_div)
  `SVA_IMP(a_mosi_hold, samp, mosi == mosi_q)          // MOSI does not move at a sampling edge
  `SVA_IMP(a_first_bit, busy && $past(go) && !f_pha, mosi == f_tx[7])
  `SVA_IMP(a_done, done, n_edge == 16 && d_mosi == f_tx && rx_data == d_miso && !busy)
  `SVA_INV(a_edges, n_edge <= 16)

  covergroup cg_spi_host @(posedge clk);
    option.per_instance = 1;
    cp_mode: coverpoint {cpol, cpha} iff (rst_n && go);
    cp_div: coverpoint div iff (rst_n && go) { bins zero = {0}; bins one = {1}; bins small_ = {[2:7]}; bins big = {[8:16'hFFFF]}; }
    cp_cs: coverpoint cs iff (rst_n && go);
    cx_mode_div: cross cp_mode, cp_div;
  endgroup
  cg_spi_host u_cg_spi_host = new;

  `FC(start_while_busy, start && busy)
  `FC(back_to_back, done ##[0:1] go)
  `FC(mode_change_while_busy, busy && (cpol != f_pol || cpha != f_pha))
  `FC_RST(reset_mid_frame, rst_n && busy ##1 !rst_n)
endmodule

bind SPI_Host_top SPI_Host_sva #(.NCS(NCS)) u_sva (.*);
