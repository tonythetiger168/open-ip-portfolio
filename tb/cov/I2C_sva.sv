// SPDX-License-Identifier: Apache-2.0
// I2C slave: concurrent SVA + functional coverage, bound into I2C_top.
`include "cov_macros.svh"
module I2C_sva #(parameter int I2C_ADDR = 7'h50) (
  input logic       clk, rst_n,
  input logic       scl_rise, scl_fall, start_det, stop_det, sda_s,
  input logic [2:0] state,
  input logic [2:0] bit_cnt,
  input logic [7:0] addr_byte, rx_byte, tx_byte,
  input logic       rw, ack_low, txack_done, rx_valid, busy, irq
);
  `COV_CLOCKING(clk, !rst_n)
  localparam logic [2:0] IDLE=0, ADDR=1, ACK=2, RX=3, TX=4, TXACK=5, IGNORE=6;
  wire no_ev = !start_det && !stop_det;
  wire tx_next_bit = tx_byte[3'd6 - bit_cnt];   // bit presented after this SCL fall

  // ---------------- assertions ----------------
  `SVA_RST(a_reset_quiet, !rst_n, !busy && !rx_valid && !ack_low && state == IDLE)
  `SVA_INV(a_state_legal, state <= IGNORE)
    `SVA_INV(a_irq_is_rx_valid, irq == rx_valid)
  `SVA_INV(a_busy_def, busy == (state != IDLE && state != IGNORE))
  `SVA_IMP(a_sda_drive_states, ack_low, state inside {ACK, TX, TXACK})
  `SVA_NXT(a_rx_valid_pulse, rx_valid, !rx_valid)
  `SVA_IMP(a_rx_byte_only_on_valid, $changed(rx_byte), rx_valid)
  `SVA_IMP(a_rx_valid_in_txn, rx_valid, state == ACK)
  `SVA_NXT(a_start_to_addr, start_det, state == ADDR && bit_cnt == 0 && !ack_low)
  `SVA_NXT(a_stop_to_idle, stop_det && !start_det, state == IDLE && !ack_low)
  `SVA_NXT(a_addr_match, state == ADDR && scl_rise && bit_cnt == 7 && no_ev &&
           addr_byte[7:1] == I2C_ADDR[6:0], state == ACK && rw == $past(addr_byte[0]))
  `SVA_NXT(a_addr_mismatch, state == ADDR && scl_rise && bit_cnt == 7 && no_ev &&
           addr_byte[7:1] != I2C_ADDR[6:0], state == IGNORE && !ack_low)
  `SVA_NXT(a_rx_byte_done, state == RX && scl_rise && bit_cnt == 7 && no_ev,
           rx_valid && rx_byte == $past(addr_byte) && state == ACK)
  `SVA_NXT(a_ignore_holds, state == IGNORE && no_ev, state == IGNORE && !ack_low)
  `SVA_NXT(a_master_nack_ends, state == TXACK && !txack_done && scl_rise && sda_s && no_ev,
           state == IDLE)
  `SVA_NXT(a_master_ack_continues, state == TXACK && txack_done && scl_fall && no_ev,
           state == TX && bit_cnt == 0 && ack_low == !$past(tx_byte[7]))
  `SVA_NXT(a_tx_bit_presented, state == TX && scl_fall && bit_cnt < 7 && no_ev,
           ack_low == !$past(tx_next_bit))

  // ---------------- functional coverage ----------------
  // address phase outcome x direction
  covergroup cg_addr @(posedge clk);
    option.per_instance = 1;
    cp_match: coverpoint (addr_byte[7:1] == I2C_ADDR[6:0])
      iff (rst_n && state == ADDR && scl_rise && bit_cnt == 7 && no_ev)
      { bins hit = {1}; bins miss = {0}; }
    cp_rw: coverpoint addr_byte[0]
      iff (rst_n && state == ADDR && scl_rise && bit_cnt == 7 && no_ev)
      { bins wr = {0}; bins rd = {1}; }
    x_match_rw: cross cp_match, cp_rw;
  endgroup
  // received data values
  covergroup cg_rx @(posedge clk);
    option.per_instance = 1;
    cp_data: coverpoint rx_byte iff (rst_n && rx_valid)
      { bins zero = {8'h00}; bins ones = {8'hFF}; bins low = {[8'h01:8'h7F]};
        bins high = {[8'h80:8'hFE]}; }
  endgroup
  // transmitted data: first-bit polarity and master response
  covergroup cg_tx @(posedge clk);
    option.per_instance = 1;
    cp_msb: coverpoint tx_byte[7] iff (rst_n && state == ACK && rw && scl_fall && ack_low)
      { bins msb0 = {0}; bins msb1 = {1}; }
    cp_master_resp: coverpoint sda_s iff (rst_n && state == TXACK && !txack_done && scl_rise && no_ev)
      { bins ack = {0}; bins nack = {1}; }
  endgroup
  cg_addr u_cg_addr = new;
  cg_rx   u_cg_rx   = new;
  cg_tx   u_cg_tx   = new;

  `FC(repeated_start, start_det && state != IDLE && state != IGNORE)
  `FC(stop_in_write_data, stop_det && state == RX)
  `FC(multi_byte_write, rx_valid ##[1:$] rx_valid)
  `FC(read_then_continue, state == TXACK && txack_done ##1 state == TX)
  `FC(wrong_addr_then_stop, state == IGNORE ##[1:$] stop_det)
endmodule

bind I2C_top I2C_sva #(.I2C_ADDR(I2C_ADDR)) u_sva (.*);
