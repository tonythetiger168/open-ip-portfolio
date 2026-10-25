// SPDX-License-Identifier: Apache-2.0
// I2S slave: pin-level model of the Philips framing (one-BCLK delay after
// each LRCK change, words shorter than the slot) predicting SDOUT at every
// BCLK rise and the received left/right registers.
`include "cov_macros.svh"
module I2S_sva #(parameter int DW = 16) (
  input logic          clk, rst_n, bclk, lrck, sdin, sdout, wen, irq,
  input logic [3:0]    waddr,
  input logic [DW-1:0] wdata, tx_left, tx_right, rx_left, rx_right
);
  `COV_CLOCKING(clk, !rst_n)

  logic b1, b2, l1, l2, d1;
  always_ff @(posedge clk or negedge rst_n)
    if (!rst_n) begin b1 <= 0; b2 <= 0; l1 <= 0; l2 <= 0; d1 <= 0; end
    else begin b1 <= bclk; b2 <= b1; l1 <= lrck; l2 <= l1; d1 <= sdin; end
  wire rise = b1 && !b2, fall = !b1 && b2, chg = l1 != l2;

  // TX: falls since the last LRCK change (1 = MSB) and the word being sent;
  // the bit put on the line at each fall belongs to the word that was
  // active before that fall (so at an LRCK-change fall it is still the old
  // word's next bit, e.g. its LSB when the slot is exactly DW bits)
  int            t_k;
  logic          t_ch, line;
  logic [DW-1:0] t_word;
  // RX: rises since the last change (1 = MSB), word being assembled
  int          r_k, r_kp;
  logic        r_ch, r_chp;
  logic [DW-1:0] r_w, r_wp, m_left, m_right;
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      t_k <= 99; t_ch <= 0; t_word <= 0; line <= 0;
      r_k <= 99; r_kp <= 99; r_ch <= 0; r_chp <= 0; r_w <= 0; r_wp <= 0;
      m_left <= 0; m_right <= 0;
    end else begin
      if (fall) begin
        automatic int            pk = (t_k >= 99) ? 99 : t_k + 1;
        automatic logic [DW-1:0] w  = (pk == 1) ? (t_ch ? tx_right : tx_left) : t_word;
        line   <= (pk <= DW) ? w[DW - pk] : 1'b0;
        t_word <= w;
        t_k    <= pk;
      end
      if (rise) begin
        if (r_k == 0) begin
          // previous word's last bit (slot of exactly DW bits)
          if (r_kp == DW - 1) begin
            if (r_chp) m_right <= {r_wp[DW-2:0], d1}; else m_left <= {r_wp[DW-2:0], d1};
          end
          r_k <= 1;
        end else if (r_k <= DW) begin
          r_w <= {r_w[DW-2:0], d1};
          if (r_k == DW) begin
            if (r_ch) m_right <= {r_w[DW-2:0], d1}; else m_left <= {r_w[DW-2:0], d1};
          end
          r_k <= r_k + 1;
        end
      end
      if (chg) begin
        t_k <= 0; t_ch <= l1;
        r_kp <= (rise && r_k >= 1 && r_k <= DW) ? r_k : r_k - 1;  // bits taken
        r_wp <= r_w; r_chp <= r_ch; r_k <= 0; r_ch <= l1;
      end
    end
  end

  `SVA_RST(a_reset_quiet, !rst_n, !sdout && rx_left == 0 && rx_right == 0)
  `SVA_IMP(a_sdout_model, rise, sdout == line)
  `SVA_INV(a_rx_model, rx_left == m_left && rx_right == m_right)
  `SVA_INV(a_irq_frame_sync, irq == chg)

  `FC(slot_exact, rise && r_k == 0 && r_kp == DW - 1)
  `FC(slot_padded, rise && r_k > DW)
  `FC(rx_left_word, rise && r_k == DW && !r_ch)
  `FC(rx_right_word, rise && r_k == DW && r_ch)
  `FC(tx_load_left, fall && t_k == 0 && !t_ch)
  `FC(tx_load_right, fall && t_k == 0 && t_ch)
  `FC(tx_lsb_on_lrck_edge, fall && chg && t_k == DW - 1)
  `FC(host_write_mid_word, wen && waddr < 2 && t_k >= 1 && t_k <= DW)
  `FC(lrck_change_without_bclk, chg ##[1:20] chg)
  `FC_RST(reset_mid_word, rst_n && t_k >= 2 && t_k < DW ##1 !rst_n)
endmodule

bind I2S_top I2S_sva #(.DW(DW)) u_sva (.*);
