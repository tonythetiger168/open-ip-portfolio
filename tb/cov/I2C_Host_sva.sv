// SPDX-License-Identifier: Apache-2.0
// I2C_Host (I2C controller, byte commands STA / WR / RD / STO): concurrent
// SVA against an independent decoder of the SCL / SDA pins, + functional
// coverage. The decoder finds START (SDA falls with SCL high), STOP (SDA
// rises with SCL high) and data bits (SDA during an SCL high time, taken at
// the SCL fall), and checks each command at DONE: one START if STA was asked,
// 8 bits of TX_DATA (MSB first) and the target's ACK in RX_ACK for WR, 8
// bits into RX_DATA and ACK (or NACK with NACK = 1) sent for RD, a STOP if
// STO was asked with the bus held; nothing on the wire otherwise. Also: SDA
// only moves with SCL high for START / STOP, SCL stays put for at least
// PRESCALE + 1 clocks, BUS_HELD between START and STOP, BUSY / DONE, a
// command while busy is ignored.
`include "cov_macros.svh"
module I2C_Host_sva (
  input logic        clk, rst_n, scl, sda, busy, bus_held, done, rx_ack,
  input logic        cmd_valid, cmd_sta, cmd_wr, cmd_rd, cmd_sto, cmd_nack,
  input logic [15:0] prescale,
  input logic [7:0]  tx_data, rx_data
);
  `COV_CLOCKING(clk, !rst_n)
  wire         sd = (sda !== 1'b0);
  logic        scl_q, sd_q, held, cond;
  logic        c_sta, c_wr, c_rd, c_sto, c_nack, c_held;
  logic [7:0]  c_tx;
  logic [8:0]  d_bits;
  logic        p_v, p_bit;               // a bit seen at the SCL rise, not yet ended by the fall
  int          d_n, n_sta, n_sto;
  logic [15:0] m_hc;
  wire         go = cmd_valid && !busy;
  wire         start_c = scl && scl_q && sd_q && !sd;
  wire         stop_c  = scl && scl_q && !sd_q && sd;
  wire         fall    = scl_q && !scl;
  wire         rise    = !scl_q && scl;
  // at DONE the last bit may still be in its SCL high time: count it
  wire         p_cnt   = p_v && !cond;
  wire  [8:0]  e_bits  = p_cnt ? {d_bits[7:0], p_bit} : d_bits;
  wire  [31:0] e_n     = d_n + (p_cnt ? 1 : 0);
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      scl_q <= 1; sd_q <= 1; held <= 0; cond <= 0; c_sta <= 0; c_wr <= 0; c_rd <= 0; c_sto <= 0; c_nack <= 0;
      c_held <= 0; c_tx <= 0; d_bits <= 0; p_v <= 0; p_bit <= 0; d_n <= 0; n_sta <= 0; n_sto <= 0; m_hc <= 0;
    end else begin
      scl_q <= scl; sd_q <= sd;
      m_hc <= (scl != scl_q) ? 16'd0 : (m_hc == 16'hFFFF ? m_hc : m_hc + 1);
      if (go) begin
        // (a transfer on a free bus starts with a START)
        c_sta <= cmd_sta || ((cmd_wr || cmd_rd) && !held); c_wr <= cmd_wr; c_rd <= cmd_rd && !cmd_wr; c_sto <= cmd_sto; c_nack <= cmd_nack;
        c_tx <= tx_data; c_held <= held; d_n <= 0; n_sta <= 0; n_sto <= 0;
      end
      if (start_c) begin n_sta <= n_sta + 1; held <= 1; cond <= 1; end
      if (stop_c) begin n_sto <= n_sto + 1; held <= 0; end
      if (rise) begin p_v <= 1; p_bit <= sd; end
      if (start_c || stop_c) p_v <= 0;
      if (fall) begin
        if (!cond && p_v) begin d_bits <= {d_bits[7:0], p_bit}; d_n <= d_n + 1; end
        cond <= 0; p_v <= 0;
      end
    end
  end
  wire xfer = c_wr || c_rd;

  `SVA_RST(a_reset_idle, !rst_n, scl && sd && !busy && !bus_held && !done)
  `SVA_INV(a_sda_moves_with_scl_low, (scl && scl_q && sd != sd_q) -> (start_c ? (c_sta && busy) : (c_sto && busy)))
  `SVA_IMP(a_bus_held, done, bus_held == held)
  `SVA_IMP(a_scl_timing, scl != scl_q && busy, m_hc >= prescale)
  `SVA_IMP(a_done_conditions, done, n_sta == (c_sta ? 1 : 0) && n_sto == ((c_sto && (c_held || c_sta)) ? 1 : 0)
                                    && e_n == (xfer ? 9 : 0))
  `SVA_IMP(a_done_write, done && c_wr, e_bits[8:1] == c_tx && rx_ack == e_bits[0])
  `SVA_IMP(a_done_read, done && c_rd, rx_data == e_bits[8:1] && e_bits[0] == c_nack)
  `SVA_NXT(a_busy, go && (cmd_sta || cmd_wr || cmd_rd || (cmd_sto && held)), busy)
  `SVA_NXT(a_nothing, go && !cmd_sta && !cmd_wr && !cmd_rd && !(cmd_sto && held), done && !busy)

  covergroup cg_i2c_host @(posedge clk);
    option.per_instance = 1;
    cp_cmd: coverpoint {cmd_sta, cmd_wr, cmd_rd, cmd_sto} iff (rst_n && go);
    cp_held: coverpoint held iff (rst_n && go);
    cp_ack: coverpoint rx_ack iff (rst_n && done && c_wr);
    cp_nack: coverpoint c_nack iff (rst_n && done && c_rd);
    cp_pre: coverpoint prescale iff (rst_n && go) { bins min = {[0:3]}; bins mid = {[4:255]}; bins big = {[256:16'hFFFF]}; }
    cx_cmd_held: cross cp_cmd, cp_held;
  endgroup
  cg_i2c_host u_cg_i2c_host = new;

  `FC(repeated_start, start_c && $past(held))
  `FC(cmd_while_busy, cmd_valid && busy)
  `FC(rx_data_all_ones, done && c_rd && e_bits[8:1] == 8'hFF)
  `FC_RST(reset_bus_held, rst_n && held ##1 !rst_n)
endmodule

bind I2C_Host_top I2C_Host_sva u_sva (.*);
