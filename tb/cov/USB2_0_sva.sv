// SPDX-License-Identifier: Apache-2.0
// USB 2.0 FS echo engine. RX model: at the DUT's mid-bit sample strobe it
// decodes NRZI/SYNC/stuffing into a bit buffer and judges each frame (PID
// check, length, alignment, CRC16 residual over the buffer) to predict irq
// and rx_err. TX monitor: decodes the device's own drive at its bit edges
// and checks SYNC, stuffing, the 2-bit SE0 + J EOP, and that the echo is
// bit-for-bit the last good frame.
`include "cov_macros.svh"
module USB2_0_sva #(parameter int MAXB = 8) (
  input logic       clk, rst_n, dp, dm, busy, irq,
  input logic       rsamp, line_j, line_k, line_se0, rx_err, oe_q, tedge,
  input logic [2:0] tstate
);
  `COV_CLOCKING(clk, !rst_n)
  localparam int NB = MAXB + 3;                // PID + payload + CRC16 bytes
  localparam int MB = NB * 8;

  function automatic logic [15:0] resid(input logic b [0:MB-1], input int n);
    logic [15:0] c;
    c = 16'hFFFF;
    for (int i = 8; i < MB; i++)
      if (i < n) c = (c >> 1) ^ ((c[0] ^ b[i]) ? 16'hA001 : 16'h0);
    return c;
  endfunction

  // ---------------- RX model ----------------
  localparam int M_IDLE = 0, M_SYNC = 1, M_PKT = 2, M_EOP = 3, M_WAIT = 4;
  int   m_st, m_z, m_ones, m_n, m_j8, m_ln;
  logic m_prev, m_err, m_done;
  logic m_bits [0:MB-1];
  logic m_last [0:MB-1];                       // last good frame
  // error causes (one-cycle, for functional coverage)
  logic e_sync_se0, e_sync_short, e_stuff, e_pid, e_long, e_eop_k, e_bad_end;
  logic g_frame, s_rx_stuff, m_tail_eop;
  wire  mb   = (line_j == m_prev);
  wire  m_ok = m_n % 8 == 0 && m_n >= 24 && resid(m_bits, m_n) == 16'hB001;
  logic [7:0] m_pidb;
  always_comb for (int i = 0; i < 8; i++) m_pidb[i] = m_bits[i];

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      m_st <= M_IDLE; m_z <= 0; m_ones <= 0; m_n <= 0; m_j8 <= 0; m_prev <= 1;
      m_err <= 0; m_done <= 0; m_ln <= 0;
      {e_sync_se0, e_sync_short, e_stuff, e_pid, e_long, e_eop_k, e_bad_end} <= '0;
      {g_frame, s_rx_stuff} <= '0;
    end else begin
      m_done <= 0;
      {e_sync_se0, e_sync_short, e_stuff, e_pid, e_long, e_eop_k, e_bad_end} <= '0;
      {g_frame, s_rx_stuff} <= '0;
      if (rsamp) begin
        case (m_st)
          M_IDLE: if (line_k && tstate == 3'd0) begin m_st <= M_SYNC; m_prev <= 0; m_z <= 1; end
          M_SYNC: begin
            m_prev <= line_j;
            if (line_se0) begin m_st <= M_WAIT; m_err <= 1; m_j8 <= 0; e_sync_se0 <= 1; end
            else if (!mb) m_z <= m_z + 1;
            else if (m_z >= 5) begin m_st <= M_PKT; m_ones <= 1; m_n <= 0; end
            else begin m_st <= M_WAIT; m_err <= 1; m_j8 <= 0; e_sync_short <= 1; end
          end
          M_PKT: begin
            m_prev <= line_j;
            if (line_se0) m_st <= M_EOP;
            else if (m_ones == 6) begin
              m_ones <= 0; s_rx_stuff <= 1;
              if (mb) begin m_st <= M_WAIT; m_err <= 1; m_j8 <= 0; e_stuff <= 1; end
            end else begin
              m_ones <= mb ? m_ones + 1 : 0;
              if (m_n < MB) m_bits[m_n] <= mb;
              m_n <= m_n + 1;
              if (m_n == 7 && {mb, m_pidb[6:4]} != ~m_pidb[3:0]) begin
                m_st <= M_WAIT; m_err <= 1; m_j8 <= 0; e_pid <= 1;
              end
              if (m_n == MB + 7) begin m_st <= M_WAIT; m_err <= 1; m_j8 <= 0; e_long <= 1; end
            end
          end
          M_EOP: if (line_j) begin
            m_st <= M_IDLE;
            if (m_ok) begin
              m_done <= 1; g_frame <= 1; m_ln <= m_n; m_last <= m_bits;
            end else begin m_err <= 1; e_bad_end <= 1; end
          end else if (line_k) begin m_st <= M_WAIT; m_err <= 1; m_j8 <= 0; e_eop_k <= 1; end
          default: begin                       // M_WAIT: 8 J samples
            m_j8 <= line_j ? m_j8 + 1 : 0;
            if (line_j && m_j8 == 7) m_st <= M_IDLE;
          end
        endcase
      end
    end
  end

  // ---------------- TX monitor ----------------
  logic t_prev, t_ls;                         // t_ls: last bit was a stuff
  int   t_ones, t_n, t_se0;
  logic t_bits [0:MB-1];
  wire  t_samp = tedge && oe_q;
  wire  t_se0n = !dp && !dm;
  wire  t_b    = (dp == t_prev);
  wire  t_stf  = t_ones == 6;
  logic t_match;
  always_comb begin
    t_match = (t_n == m_ln);
    for (int i = 0; i < MB; i++) if (i < m_ln && t_bits[i] != m_last[i]) t_match = 1'b0;
  end
  wire t_end = t_samp && t_se0 > 0 && !t_se0n;

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      t_prev <= 1; t_ls <= 0; t_ones <= 0; t_n <= -8; t_se0 <= 0; m_tail_eop <= 0;
    end else begin
      m_tail_eop <= 0;
      if (t_samp) begin
        if (t_se0n) begin
          t_se0 <= t_se0 + 1;
          if (t_se0 == 0 && t_ls) m_tail_eop <= 1;
        end else if (t_se0 > 0) begin            // J after EOP: frame over
          t_prev <= 1; t_ones <= 0; t_n <= -8; t_se0 <= 0; t_ls <= 0;
        end else begin
          t_prev <= dp;
          if (t_n >= 0 && t_stf) begin t_ones <= 0; t_ls <= 1; end   // stuffed 0
          else begin
            t_ls <= 0;
            t_ones <= t_b ? t_ones + 1 : 0;
            if (t_n >= 0 && t_n < MB) t_bits[t_n] <= t_b;
            t_n <= t_n + 1;
          end
        end
      end
    end
  end

  `SVA_RST(a_reset_idle, !rst_n, !busy && !irq)
  `SVA_INV(a_irq_model, irq == m_done)
  `SVA_INV(a_rx_err_model, rx_err == m_err)
  `SVA_INV(a_busy_model, busy == (m_st != M_IDLE || tstate != 3'd0))
  `SVA_INV(a_no_se1, !(dp && dm))
  `SVA_IMP(a_tx_sync, t_samp && !t_se0n && t_n < 0, t_b == (t_n == -1))
  `SVA_IMP(a_tx_stuffing, t_samp && !t_se0n && t_se0 == 0 && t_n >= 0 && t_stf, !t_b)
  `SVA_IMP(a_tx_eop, t_end, t_se0 == 2 && dp && !dm)
  `SVA_IMP(a_tx_echo, t_end, t_match)
  `SVA_IMP(a_no_tx_while_rx, oe_q, m_st == M_IDLE)
  `SVA_NXT(a_irq_pulse, irq, !irq)

  `FC(err_se0_in_sync, e_sync_se0)
  `FC(err_short_sync, e_sync_short)
  `FC(err_stuffing, e_stuff)
  `FC(err_pid_check, e_pid)
  `FC(err_too_long, e_long)
  `FC(err_k_after_se0, e_eop_k)
  `FC(err_misaligned, e_bad_end && m_n % 8 != 0)
  `FC(err_too_short, e_bad_end && m_n % 8 == 0 && m_n < 24)
  `FC(err_crc, e_bad_end && m_n % 8 == 0 && m_n >= 24)
  `FC(rx_stuff_bit, s_rx_stuff)
  `FC(long_sync, m_st == M_SYNC && rsamp && m_z >= 8)
  `FC(tx_stuff_before_eop, m_tail_eop)
  `FC(tx_echo_max, t_end && m_ln == MB)
  `FC(tx_echo_empty, t_end && m_ln == 24)
  `FC(frame_during_wait_ignored, m_st == M_WAIT && rsamp && line_k)
  `FC_RST(reset_during_echo, rst_n && oe_q ##1 !rst_n)

  logic [3:0] g_pid;
  int         g_len;
  always_comb for (int i = 0; i < 4; i++) g_pid[i] = m_bits[i];
  assign g_len = m_n / 8 - 3;
  covergroup cg_frame @(posedge clk iff (rst_n && g_frame));
    coverpoint g_pid { bins p[16] = {[0:15]}; }
    coverpoint g_len { bins l0 = {0}; bins l1 = {1}; bins l2 = {2}; bins l3 = {3}; bins l4 = {4};
                       bins l5 = {5}; bins l6 = {6}; bins l7 = {7}; bins l8 = {8}; }
  endgroup
  cg_frame u_cg = new();
endmodule

bind USB2_0_top USB2_0_sva #(.MAXB(MAXB)) u_sva (.*);
