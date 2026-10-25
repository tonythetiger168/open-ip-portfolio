// SPDX-License-Identifier: Apache-2.0
// MIPI M-PHY lane: the checker builds its own full 8b/10b encode and
// decode tables (all 256 D-codes, the 12 K-codes, both running
// disparities) and runs a pin-level model of the lane contract: host
// buffer and tx_ready, inter-burst gap, gear timing, HIBERN8 / wake line
// states and the serial bit stream on tx_dif_p/n, plus the receiver
// (comma hunt at both gears, framing, decode, running disparity, idle
// word, gear change, DIF-Z detection) and the sticky irq.
`include "cov_macros.svh"
module M_PHY_sva (
  input logic       clk, rst_n, irq, irq_clear, gear, hibern8_req, wake_req, hibern8,
  input logic [7:0] tx_data, rx_data,
  input logic       tx_k, tx_valid, tx_ready, tx_dif_p, tx_dif_n, rx_dif_p, rx_dif_n,
  input logic       rx_locked, rx_hibern, rx_k, rx_valid
);
  `COV_CLOCKING(clk, !rst_n)

  // ---------------- 8b/10b tables ----------------
  logic [5:0] T6 [0:31];
  logic [3:0] T4 [0:7];
  logic [10:0] etab [0:1023];       // {rd, k, d} -> {valid, word}
  logic        erd  [0:1023];       // running disparity after the word
  logic [9:0]  dtab [0:2047];       // {rd, word} -> {valid, k, d}
  function automatic int n1(input logic [9:0] v, input int w);
    n1 = 0;
    for (int i = 0; i < 10; i++) if (i < w) n1 += int'(v[i]);
  endfunction
  initial begin
    T6 = '{6'b100111, 6'b011101, 6'b101101, 6'b110001, 6'b110101, 6'b101001, 6'b011001, 6'b111000,
           6'b111001, 6'b100101, 6'b010101, 6'b110100, 6'b001101, 6'b101100, 6'b011100, 6'b010111,
           6'b011011, 6'b100011, 6'b010011, 6'b110010, 6'b001011, 6'b101010, 6'b011010, 6'b111010,
           6'b110011, 6'b100110, 6'b010110, 6'b110110, 6'b001110, 6'b101110, 6'b011110, 6'b101011};
    T4 = '{4'b1011, 4'b1001, 4'b0101, 4'b1100, 4'b1101, 4'b1010, 4'b0110, 4'b1110};
    for (int i = 0; i < 2048; i++) dtab[i] = '0;
    for (int rd = 0; rd < 2; rd++)
      for (int k = 0; k < 2; k++)
        for (int b = 0; b < 256; b++) begin
          int x, y, r6, r4;
          logic [5:0] a;
          logic [3:0] f;
          bit ok;
          x = b % 32; y = b / 32;
          ok = k == 0 || x == 28 || (y == 7 && (x == 23 || x == 27 || x == 29 || x == 30));
          a = (k == 1 && x == 28) ? 6'b001111 : T6[x];
          if (rd == 1 && (n1(10'(a), 6) != 3 || (k == 0 && x == 7))) a = ~a;
          r6 = n1(10'(a), 6) == 3 ? rd : int'(n1(10'(a), 6) > 3);
          if (y == 7 && (k == 1 || (r6 == 0 && (x == 17 || x == 18 || x == 20)) ||
                         (r6 == 1 && (x == 11 || x == 13 || x == 14)))) f = 4'b0111;
          else f = T4[y];
          if (k == 1 && x == 28 && (y == 1 || y == 2 || y == 5 || y == 6)) begin
            if (r6 == 0) f = ~f;
          end else if (r6 == 1 && (n1(10'(f), 4) != 2 || y == 3)) f = ~f;
          r4 = n1(10'(f), 4) == 2 ? r6 : int'(n1(10'(f), 4) > 2);
          etab[rd * 512 + k * 256 + b] = {ok, a, f};
          erd[rd * 512 + k * 256 + b]  = r4 != 0;
          if (ok) dtab[rd * 1024 + int'({a, f})] = {1'b1, k[0], b[7:0]};
        end
  end
  function automatic bit rd_after(input bit rd, input logic [9:0] w);
    int a, f;
    bit r6;
    a = n1(w >> 4, 6); f = n1(w, 4);
    r6 = a == 3 ? rd : a > 3;
    return f == 2 ? r6 : f > 2;
  endfunction
  localparam logic [9:0] C_N = 10'b0011111010, C_P = 10'b1100000101;

  // ---------------- TX model ----------------
  localparam int T_IDLE = 0, T_SHIFT = 1, T_SAVE = 2, T_WAKE = 3;
  int          tst, tb, gap, wk;
  logic        tsub, trd, bv, bk, m_etx;
  logic [7:0]  bd;
  logic [9:0]  tw;
  wire  [10:0] e   = etab[{trd, bk, bd}];
  wire         ebit = tw[9];
  wire  exp_ready = !bv && (tst == T_IDLE || tst == T_SHIFT);
  logic f_badk, f_chain, f_gap_wait, f_wake, f_save, f_gap_wait_g2;

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      tst <= T_IDLE; tb <= 0; gap <= 0; wk <= 0; tsub <= 0; trd <= 0; bv <= 0; bk <= 0; bd <= 0;
      tw <= 0; m_etx <= 0; {f_badk, f_chain, f_gap_wait, f_wake, f_save, f_gap_wait_g2} <= '0;
    end else begin
      {f_badk, f_chain, f_gap_wait, f_wake, f_save, f_gap_wait_g2} <= '0;
      if (irq_clear) m_etx <= 0;
      if (tx_valid && exp_ready) begin bv <= 1; bd <= tx_data; bk <= tx_k; end
      case (tst)
        T_IDLE: begin
          tsub <= 0;
          if (gap != 0) gap <= gap - 1;
          if (hibern8_req && !bv) begin tst <= T_SAVE; f_save <= 1; end
          else if (bv) begin
            if (!e[10]) begin m_etx <= 1; bv <= 0; f_badk <= 1; end
            else if (gap == 0) begin tst <= T_SHIFT; tw <= e[9:0]; tb <= 0; trd <= erd[{trd, bk, bd}]; bv <= 0; end
            else begin f_gap_wait <= 1; f_gap_wait_g2 <= gear && gap == 1; end
          end
        end
        T_SHIFT: begin
          if (tsub == gear) begin
            tsub <= 0;
            if (tb == 9) begin
              if (bv && e[10]) begin
                tw <= e[9:0]; tb <= 0; trd <= erd[{trd, bk, bd}]; bv <= 0; f_chain <= 1;
              end else begin
                if (bv) begin m_etx <= 1; bv <= 0; f_badk <= 1; end
                tst <= T_IDLE; tb <= 0; gap <= gear ? 20 : 10;
              end
            end else begin tw <= {tw[8:0], 1'b0}; tb <= tb + 1; end
          end else tsub <= 1;
        end
        T_SAVE: if (wake_req) begin tst <= T_WAKE; wk <= 0; f_wake <= 1; end
        default: if (wk == 7) tst <= T_IDLE; else wk <= wk + 1;
      endcase
    end
  end
  wire [1:0] exp_line = tst == T_SAVE ? 2'b00 : tst == T_SHIFT ? {ebit, !ebit} : 2'b01;

  // ---------------- RX model ----------------
  localparam int R_HUNT = 0, R_LOCK = 1, R_HIB = 2;
  int          rst_, rb, hc;
  logic        rsub, rrd, gq, m_erx, m_val, m_k;
  logic [7:0]  m_d;
  logic [19:0] hs;                    // sample history, newest in bit 0
  logic [9:0]  wbits;
  wire  [19:0] hn = {hs[18:0], rx_dif_p};
  logic [19:0] c2n, c2p;
  always_comb
    for (int i = 0; i < 10; i++) begin c2n[2*i +: 2] = {2{C_N[i]}}; c2p[2*i +: 2] = {2{C_P[i]}}; end
  wire mn = gear ? hn == c2n : hn[9:0] == C_N;
  wire mp = gear ? hn == c2p : hn[9:0] == C_P;
  wire [9:0] fr = {wbits[8:0], rx_dif_p};
  wire [9:0] dd = dtab[{rrd, fr}];
  logic f_lock_n, f_lock_p, f_lock_g2, f_idle_word, f_code_err, f_gear_relock, f_hib_rx, f_rx_k;

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      rst_ <= R_HUNT; rb <= 0; hc <= 0; rsub <= 0; rrd <= 0; gq <= 0; m_erx <= 0; m_val <= 0;
      m_k <= 0; m_d <= 0; hs <= 0; wbits <= 0;
      {f_lock_n, f_lock_p, f_lock_g2, f_idle_word, f_code_err, f_gear_relock, f_hib_rx, f_rx_k} <= '0;
    end else begin
      {f_lock_n, f_lock_p, f_lock_g2, f_idle_word, f_code_err, f_gear_relock, f_hib_rx, f_rx_k} <= '0;
      m_val <= 0;
      gq <= gear;
      if (irq_clear) m_erx <= 0;
      if (!rx_dif_p && !rx_dif_n) begin
        if (hc != 3) hc <= hc + 1;
        if (hc >= 2) begin rst_ <= R_HIB; f_hib_rx <= rst_ != R_HIB; end
      end else hc <= 0;
      case (rst_)
        R_HUNT: begin
          hs <= hn;
          if (mn || mp) begin
            rst_ <= R_LOCK; rb <= 0; rsub <= 0; rrd <= mn; m_d <= 8'hBC; m_k <= 1; m_val <= 1;
            f_lock_n <= mn; f_lock_p <= mp; f_lock_g2 <= gear;
          end
        end
        R_LOCK: begin
          if (gear != gq) begin rst_ <= R_HUNT; f_gear_relock <= 1; end
          else if (!gear || rsub) begin
            rsub <= 0;
            wbits <= fr;
            if (rb == 9) begin
              rb <= 0;
              if (fr == 0) begin rst_ <= R_HUNT; f_idle_word <= 1; end
              else begin
                rrd <= rd_after(rrd, fr);
                if (!dd[9]) begin m_erx <= 1; f_code_err <= 1; end
                else begin m_d <= dd[7:0]; m_k <= dd[8]; m_val <= 1; f_rx_k <= dd[8]; end
              end
            end else rb <= rb + 1;
          end else rsub <= 1;
        end
        default: if (rx_dif_p || rx_dif_n) begin rst_ <= R_HUNT; hs <= 0; end
      endcase
    end
  end

  `SVA_RST(a_reset_idle, !rst_n, {tx_dif_p, tx_dif_n} == 2'b01 && !hibern8 && !irq && !rx_locked && !rx_hibern && !rx_valid)
  `SVA_INV(a_tx_line, {tx_dif_p, tx_dif_n} == exp_line)
  `SVA_INV(a_tx_ready, tx_ready == exp_ready)
  `SVA_INV(a_hibern8, hibern8 == (tst == T_SAVE))
  `SVA_INV(a_irq, irq == (m_etx || m_erx))
  `SVA_INV(a_rx_state, rx_locked == (rst_ == R_LOCK) && rx_hibern == (rst_ == R_HIB))
  `SVA_INV(a_rx_valid, rx_valid == m_val)
  `SVA_IMP(a_rx_word, m_val, rx_data == m_d && rx_k == m_k)

  `FC(tx_unsupported_k, f_badk)
  `FC(tx_word_chained, f_chain)
  `FC(tx_waits_for_gap, f_gap_wait)
  `FC(tx_waits_for_g2_gap_end, f_gap_wait_g2)
  `FC(hibern8_enter, f_save)
  `FC(hibern8_wake, f_wake)
  `FC(rx_lock_rd_minus, f_lock_n)
  `FC(rx_lock_rd_plus, f_lock_p)
  `FC(rx_lock_g2, f_lock_g2)
  `FC(rx_idle_word_rehunt, f_idle_word)
  `FC(rx_code_or_disparity_error, f_code_err)
  `FC(rx_gear_change_relock, f_gear_relock)
  `FC(rx_dif_z_hibern, f_hib_rx)
  `FC(rx_k_code_in_burst, f_rx_k)
  `FC(irq_clear_used, irq_clear && irq)
  `FC_RST(reset_mid_burst, rst_n && tst == T_SHIFT ##1 !rst_n)

  covergroup cg_rx @(posedge clk iff (rst_n && m_val));
    cp_d: coverpoint m_d iff (!m_k) { bins d[] = {[0:255]}; }
    cp_k: coverpoint m_d iff (m_k) {
      bins k28[] = {8'h1C, 8'h3C, 8'h5C, 8'h7C, 8'h9C, 8'hBC, 8'hDC, 8'hFC};
      bins k23_7 = {8'hF7}; bins k27_7 = {8'hFB}; bins k29_7 = {8'hFD}; bins k30_7 = {8'hFE}; }
    cp_rd: coverpoint rrd;
  endgroup
  cg_rx u_cg = new();
endmodule

bind M_PHY_top M_PHY_sva u_sva (.*);
