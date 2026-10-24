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

  // completed bytes per transfer kind with the data classes that kind moves
  // (std: both directions; quad read: TX only; quad write: RX only), and
  // where a frame was aborted
  function automatic logic [1:0] dcls(input logic [7:0] v);
    dcls = (v == 8'h00) ? 2'd0 : (v == 8'hFF) ? 2'd1 :
           (v == 8'h55 || v == 8'hAA) ? 2'd2 : 2'd3;
  endfunction
  logic [7:0] m_tx_byte;
  logic [1:0] m_kind, m_abort_kind;     // 0 std, 1 quad read, 2 quad write
  logic [2:0] m_abort_pos;
  logic       m_abort, m_csn_d;
  wire  [1:0] kind_now = std ? 2'd0 : m_dir ? 2'd2 : 2'd1;
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      m_tx_byte <= 0; m_kind <= 0; m_abort <= 0; m_abort_kind <= 0; m_abort_pos <= 0; m_csn_d <= 1;
    end else begin
      if (rise && m_bit == 0 && !m_q) begin m_tx_byte <= m_tx; m_kind <= kind_now; end
      m_csn_d <= csn;
      m_abort <= csn && !m_csn_d && (m_bit != 0 || m_q);
      m_abort_kind <= kind_now;
      m_abort_pos <= std ? m_bit : 3'd0;
    end
  end
  covergroup cg_qspi_xfer @(posedge clk);
    option.per_instance = 1;
    cp_byte: coverpoint {m_kind, dcls(m_rx), dcls(m_tx_byte)} iff (rst_n && m_done) {
      bins std_rx_zero_tx_zero = {6'b00_00_00};
      bins std_rx_zero_tx_ones = {6'b00_00_01};
      bins std_rx_zero_tx_alt = {6'b00_00_10};
      bins std_rx_zero_tx_other = {6'b00_00_11};
      bins std_rx_ones_tx_zero = {6'b00_01_00};
      bins std_rx_ones_tx_ones = {6'b00_01_01};
      bins std_rx_ones_tx_alt = {6'b00_01_10};
      bins std_rx_ones_tx_other = {6'b00_01_11};
      bins std_rx_alt_tx_zero = {6'b00_10_00};
      bins std_rx_alt_tx_ones = {6'b00_10_01};
      bins std_rx_alt_tx_alt = {6'b00_10_10};
      bins std_rx_alt_tx_other = {6'b00_10_11};
      bins std_rx_other_tx_zero = {6'b00_11_00};
      bins std_rx_other_tx_ones = {6'b00_11_01};
      bins std_rx_other_tx_alt = {6'b00_11_10};
      bins std_rx_other_tx_other = {6'b00_11_11};
      bins qread_tx_zero = {[6'b01_00_00:6'b01_11_00]} with (item[1:0] == 2'd0);
      bins qread_tx_ones = {[6'b01_00_01:6'b01_11_01]} with (item[1:0] == 2'd1);
      bins qread_tx_alt = {[6'b01_00_10:6'b01_11_10]} with (item[1:0] == 2'd2);
      bins qread_tx_other = {[6'b01_00_11:6'b01_11_11]} with (item[1:0] == 2'd3);
      bins qwrite_rx_zero = {[6'b10_00_00:6'b10_00_11]};
      bins qwrite_rx_ones = {[6'b10_01_00:6'b10_01_11]};
      bins qwrite_rx_alt = {[6'b10_10_00:6'b10_10_11]};
      bins qwrite_rx_other = {[6'b10_11_00:6'b10_11_11]};
    }
    cp_abort: coverpoint {m_abort_kind, m_abort_pos} iff (rst_n && m_abort) {
      bins std_at[] = {[5'b00_001:5'b00_111]};
      bins quad_read_half = {5'b01_000};
      bins quad_write_half = {5'b10_000};
    }
  endgroup
  cg_qspi_xfer u_cg_qspi_xfer = new;

  `FC(multi_byte_quad_read, m_done && !std && !m_dir ##[1:20] rise)
  `FC(abort_mid_byte, $rose(csn) && (m_bit != 0 || m_q))
  `FC(mode_switch_while_idle, wen && waddr == 2 && csn)
  `FC_RST(reset_mid_frame, rst_n && !csn ##1 !rst_n)
endmodule

bind QSPI_top QSPI_sva u_sva (.*);
