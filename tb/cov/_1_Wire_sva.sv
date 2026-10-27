// SPDX-License-Identifier: Apache-2.0
// 1-Wire slave: a timing model on the bus (same 2-flop view of dq as the
// slave) predicts when the slave pulls dq low (presence, read-0 slots),
// and the received command byte; the slot/reset timing constants are the
// datasheet values from the RTL header.
`include "cov_macros.svh"
module _1_Wire_sva #(parameter int US = 10) (
  input logic       clk, rst_n, dq, rx_valid, busy, irq, drv_low,
  input logic [7:0] tx_byte, rx_byte
);
  `COV_CLOCKING(clk, !rst_n)
  localparam int T_RST = 480 * US, T_PDH = 15 * US, T_PDL = 120 * US;
  localparam int T_WS = 30 * US, T_RD = 40 * US;

  logic q1, q2;
  always_ff @(posedge clk or negedge rst_n)
    if (!rst_n) begin q1 <= 1; q2 <= 1; end else begin q1 <= dq; q2 <= q1; end
  wire fall = q2 && !q1;

  // 0 idle, 1 reset low, 2 wait release, 3 presence, 4 write slots,
  // 5 write sample, 6 read slots, 7 read drive
  int         ph, t, lowc, n;
  logic [7:0] sh, m_tx, m_rx;
  logic       m_valid;
  wire        rst_seen = lowc > T_RST;
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      ph <= 0; t <= 0; lowc <= 0; n <= 0; sh <= 0; m_tx <= 0; m_rx <= 0; m_valid <= 0;
    end else begin
      m_valid <= 0;
      lowc <= q1 ? 0 : (rst_seen ? lowc : lowc + 1);
      if (rst_seen && ph >= 4) begin ph <= 2; n <= 0; t <= 0; end
      else case (ph)
        0: if (!q1) begin ph <= 1; t <= 0; end
        1: if (q1) ph <= 0; else if (t > T_RST) ph <= 2; else t <= t + 1;
        2: if (q1) begin ph <= 3; t <= 0; end
        3: if (t >= T_PDH + T_PDL) begin ph <= 4; n <= 0; end else t <= t + 1;
        4: if (fall) begin ph <= 5; t <= 0; end
        5: if (t == T_WS) begin
             sh <= {q1, sh[7:1]};
             if (n == 7) begin
               m_rx <= {q1, sh[7:1]}; m_valid <= 1; m_tx <= tx_byte; n <= 0; ph <= 6;
             end else begin n <= n + 1; ph <= 4; end
           end else t <= t + 1;
        6: if (fall) begin ph <= 7; t <= 0; end
        default: if (t > T_RD) begin
             if (n == 7) begin n <= 0; ph <= 4; end
             else begin n <= n + 1; ph <= 6; m_tx <= m_tx >> 1; end
           end else t <= t + 1;
      endcase
    end
  end
  wire m_drv = (ph == 3 && t >= T_PDH) || (ph == 7 && !m_tx[0]);

  `SVA_RST(a_reset_released, !rst_n, !drv_low && !busy && !rx_valid)
  `SVA_INV(a_drive_model, drv_low == m_drv)
  `SVA_INV(a_rx_valid_model, rx_valid == m_valid)
  `SVA_IMP(a_rx_byte_model, rx_valid, rx_byte == m_rx)
  `SVA_INV(a_busy_model, busy == (ph != 0))
  `SVA_INV(a_irq_is_rx_valid, irq == rx_valid)

  // bit position x value of every write slot and every read slot, the
  // received command (ROM command codes and data classes) and the class
  // of the byte answered in the read slots
  function automatic logic [1:0] bcls(input logic [7:0] v);
    bcls = (v == 8'h00) ? 2'd0 : (v == 8'hFF) ? 2'd1 : (v == 8'h55 || v == 8'hAA) ? 2'd2 : 2'd3;
  endfunction
  covergroup cg_slot @(posedge clk);
    option.per_instance = 1;
    cp_wpos: coverpoint n iff (rst_n && ph == 5 && t == T_WS) { bins b[] = {[0:7]}; }
    cp_wval: coverpoint q1 iff (rst_n && ph == 5 && t == T_WS) { bins zero = {0}; bins one = {1}; }
    x_wslot: cross cp_wpos, cp_wval;
    cp_rpos: coverpoint n iff (rst_n && ph == 7 && t == 0) { bins b[] = {[0:7]}; }
    cp_rval: coverpoint m_tx[0] iff (rst_n && ph == 7 && t == 0) { bins zero = {0}; bins one = {1}; }
    x_rslot: cross cp_rpos, cp_rval;
    cp_cmd: coverpoint m_rx iff (rst_n && m_valid)
      { bins read_rom = {8'h33}; bins match_rom = {8'h55}; bins skip_rom = {8'hCC};
        bins search_rom = {8'hF0}; bins zero = {8'h00}; bins ones = {8'hFF};
        bins other = default; }
    cp_tx: coverpoint bcls(tx_byte) iff (rst_n && m_valid)
      { bins zero = {0}; bins ones = {1}; bins alt = {2}; bins other = {3}; }
  endgroup
  cg_slot u_cg_slot = new;

  `FC(presence_sent, ph == 3 && t == T_PDH)
  `FC(short_low_ignored, ph == 1 && q1)
  `FC(reset_during_write_slots, rst_seen && (ph == 4 || ph == 5))
  `FC(reset_during_read_slots, rst_seen && (ph == 6 || ph == 7))
  `FC(cmd_00, m_valid && m_rx == 8'h00)
  `FC(cmd_ff, m_valid && m_rx == 8'hFF)
  `FC(read_0_slot, ph == 7 && t == 0 && !m_tx[0])
  `FC(read_1_slot, ph == 7 && t == 0 && m_tx[0])
  `FC(back_to_back_commands, ph == 6 ##[1:$] ph == 4 ##[1:$] m_valid)
  `FC_RST(hard_reset_mid_transaction, rst_n && ph >= 4 ##1 !rst_n)
endmodule

bind _1_Wire_top _1_Wire_sva #(.US(US)) u_sva (.*);
