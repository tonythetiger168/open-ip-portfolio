// SPDX-License-Identifier: Apache-2.0
// TSN egress selection: concurrent SVA against an independent reference
// model, plus functional coverage.
//  * The schedule is modelled by position: pos = ns into the cycle; the
//    current entry is the first k <= gcl_last with pos < (sum of intervals
//    0..k), else the last one (it lasts until the cycle ends). The time to
//    the close of gate c is (start of the first later entry that closes c,
//    or the cycle length) - pos, capped by the cycle length.
//  * The shaper credit and the line (frame clocks remaining) are modelled
//    per clock from the values before the clock.
// Every output is compared on every clock.
`include "cov_macros.svh"
module Ethernet_AVB_TSN_sva (
  input logic        clk, rst_n,
  input logic [7:0]  cfg_inc_ns,
  input logic [15:0] cfg_inc_frac,
  input logic        time_set,
  input logic [63:0] time_set_ns,
  input logic        time_adj,
  input logic [31:0] time_adj_ns,
  input logic [63:0] time_ns,
  input logic        gcl_en,
  input logic [63:0] gcl_base,
  input logic [23:0] gcl_cycle,
  input logic [2:0]  gcl_last,
  input logic        gcl_we,
  input logic [2:0]  gcl_waddr,
  input logic [3:0]  gcl_wgates,
  input logic [23:0] gcl_wivl,
  input logic [3:0]  cbs_en,
  input logic [35:0] cbs_idle,
  input logic [3:0]  q_valid,
  input logic [43:0] q_len,
  input logic [3:0]  q_pop,
  input logic        tx_start,
  input logic [1:0]  tx_tc,
  input logic [10:0] tx_len,
  input logic [63:0] tx_ts,
  input logic        tx_busy,
  input logic        gcl_running,
  input logic [2:0]  gcl_entry,
  input logic [3:0]  gate_state,
  input logic        cycle_start,
  input logic [79:0] cbs_credit
);
  `COV_CLOCKING(clk, !rst_n)

  // ---------------- model state ----------------
  logic [63:0] m_time, m_ts;
  logic [15:0] m_frac;
  logic [3:0]  t_g [0:7];
  longint      t_i [0:7];
  bit          m_run, m_cs;
  longint      pos;
  int          rem;                       // line clocks left in the frame
  int          m_tc, m_len;
  bit          m_start;
  longint      cr [0:3];
  // coverage events
  bit v_tx [0:3];
  bit v_len0, v_len_max, v_b2b, v_guard, v_guard_exact, v_prio_skip, v_cbs_block;
  bit v_hold, v_drop_pos, v_recover, v_sat_hi, v_sat_lo;
  bit v_trunc, v_last_ext, v_entry7, v_rem_carry, v_wait_base, v_restart;
  bit v_set, v_adj_pos, v_adj_neg, v_carry, v_wrap, v_gate_closed_wait;

  function automatic int entry_of(input longint p);
    longint cum;
    cum = 0;
    for (int k = 0; k < 8; k++) begin
      cum += t_i[k];
      if (k == int'(gcl_last) || p < cum) return k;
    end
    return 7;
  endfunction
  function automatic longint start_of(input int k);
    longint s;
    s = 0;
    for (int j = 0; j < k; j++) s += t_i[j];
    return s;
  endfunction

  logic [3:0]  m_gate;
  int          m_ent;
  assign m_ent  = entry_of(pos);
  assign m_gate = m_run ? t_g[m_ent] : 4'hF;

  always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      m_time = 0; m_frac = 0; m_ts = 0; m_run = 0; m_cs = 0; pos = 0; rem = 0;
      m_tc = 0; m_len = 0; m_start = 0;
      for (int k = 0; k < 8; k++) begin t_g[k] = 0; t_i[k] = 0; end
      for (int c = 0; c < 4; c++) cr[c] = 0;
    end else begin : b_step
      logic [63:0] t0;
      bit          run0, busy0;
      int          e0, tc0;
      logic [3:0]  g0, elig;
      longint      cr0 [0:3];
      longint      cyc, inc;
      logic [16:0] fs;
      t0 = m_time; run0 = m_run; e0 = m_ent; g0 = m_gate; busy0 = rem > 0; tc0 = m_tc;
      for (int c = 0; c < 4; c++) cr0[c] = cr[c];
      cyc = longint'(gcl_cycle); inc = longint'(cfg_inc_ns);
      m_start = 0;

      // eligibility from the state before the clock
      for (int c = 0; c < 4; c++) begin : b_el
        longint ttc, ft, close_at;
        close_at = cyc;
        for (int k = e0 + 1; k <= int'(gcl_last); k++)
          if (!t_g[k][c] && close_at == cyc) close_at = start_of(k) < cyc ? start_of(k) : cyc;
        ttc = close_at - pos;
        ft = (longint'(q_len[11*c +: 11]) + 20) * inc;
        elig[c] = q_valid[c] && g0[c] && (!run0 || ttc >= ft) && (!cbs_en[c] || cr0[c] >= 0);
        if (q_valid[c] && g0[c] && run0 && ttc < ft) v_guard = 1;
        if (q_valid[c] && g0[c] && run0 && ttc == ft && !busy0) v_guard_exact = 1;
        if (q_valid[c] && g0[c] && cbs_en[c] && cr0[c] < 0 && !busy0) v_cbs_block = 1;
        if (q_valid[c] && !g0[c] && !busy0) v_gate_closed_wait = 1;
      end

      // shapers
      for (int c = 0; c < 4; c++) begin : b_cr
        longint idle, n;
        idle = longint'(cbs_idle[9*c +: 9]);
        n = cr0[c];
        if (busy0 && tc0 == c) n = n + idle - 256;
        else if (q_valid[c] && g0[c]) n = n + idle;
        else if (q_valid[c]) begin if (cbs_en[c] && n != 0) v_hold = 1; end
        else if (n > 0) begin n = 0; if (cbs_en[c]) v_drop_pos = 1; end
        else if (n < 0) begin n = n + idle > 0 ? 0 : n + idle; if (cbs_en[c] && n == 0) v_recover = 1; end
        if (n > 524287) begin n = 524287; if (cbs_en[c]) v_sat_hi = 1; end
        if (n < -524288) begin n = -524288; if (cbs_en[c]) v_sat_lo = 1; end
        cr[c] = cbs_en[c] ? n : 0;
      end

      // line
      if (rem > 1) rem--;
      else if (elig == 0) rem = 0;
      else begin : b_pick
        int w;
        w = 0;
        for (int c = 0; c < 4; c++) if (elig[c]) w = c;
        for (int c = 0; c < w; c++) if (q_valid[c]) v_prio_skip = 1;
        if (rem == 1) v_b2b = 1;
        m_start = 1; m_tc = w; m_len = int'(q_len[11*w +: 11]); m_ts = t0;
        rem = m_len + 20;
        v_tx[w] = 1;
        if (m_len == 0) v_len0 = 1;
        if (m_len == 2047) v_len_max = 1;
      end

      // time
      fs = {1'b0, m_frac} + {1'b0, cfg_inc_frac};
      if (time_set) begin m_time = time_set_ns; m_frac = 0; v_set = 1; end
      else begin
        m_frac = fs[15:0];
        if (fs[16]) v_carry = 1;
        m_time = m_time + 64'(cfg_inc_ns) + 64'(fs[16]);
        if (time_adj) begin
          m_time = m_time + {{32{time_adj_ns[31]}}, time_adj_ns};
          if (time_adj_ns[31]) v_adj_neg = 1; else v_adj_pos = 1;
        end else if (m_time < t0) v_wrap = 1;
      end

      // schedule
      m_cs = 0;
      if (!gcl_en) m_run = 0;
      else if (!run0) begin
        if (t0 >= gcl_base) begin m_run = 1; pos = 0; m_cs = 1; end
        else v_wait_base = 1;
      end else begin
        pos = pos + inc;
        if (pos >= cyc) begin
          if (e0 < int'(gcl_last)) v_trunc = 1;
          pos = pos - cyc; m_cs = 1;
          if (pos != 0) v_rem_carry = 1;
          v_restart = 1;
        end else if (pos >= start_of(int'(gcl_last) + 1) && e0 == int'(gcl_last)) v_last_ext = 1;
        if (entry_of(pos) == 7) v_entry7 = 1;
      end

      // table (written while the schedule is off)
      if (gcl_we) begin t_g[gcl_waddr] = gcl_wgates; t_i[gcl_waddr] = longint'(gcl_wivl); end
    end
  end

  // ---------------- assertions ----------------
  logic [79:0] m_cr;
  always_comb for (int c = 0; c < 4; c++) m_cr[20*c +: 20] = cr[c][19:0];

  `SVA_INV(a_time, time_ns == m_time)
  `SVA_INV(a_running, gcl_running == m_run)
  `SVA_INV(a_cycle_start, cycle_start == m_cs)
  `SVA_INV(a_gate_state, gate_state == m_gate)
  `SVA_IMP(a_entry, m_run, gcl_entry == 3'(m_ent))
  `SVA_INV(a_credit, cbs_credit == m_cr)
  `SVA_INV(a_start, tx_start == m_start)
  `SVA_INV(a_busy, tx_busy == (rem > 0))
  `SVA_IMP(a_pop, 1'b1, q_pop == (m_start ? 4'b1 << m_tc : 4'b0))
  `SVA_INV(a_frame, tx_tc == 2'(m_tc) && tx_len == 11'(m_len) && tx_ts == m_ts)
  `SVA_RST(a_rst, 1'b1, time_ns == 0 && !tx_busy && !tx_start && q_pop == 0 && !gcl_running
                        && cbs_credit == 0 && !cycle_start && gate_state == 4'hF)

  // frames sent per class and length, schedule entries and gate masks while
  // the schedule runs, shaped classes at a start
  covergroup cg_tsn @(negedge clk);
    option.per_instance = 1;
    cp_tc: coverpoint tx_tc iff (rst_n && tx_start) { bins t[] = {[0:3]}; }
    cp_len: coverpoint tx_len iff (rst_n && tx_start)
      { bins zero = {0}; bins runt = {[1:63]}; bins normal = {[64:1522]}; bins jumbo = {[1523:2047]}; }
    x_tc_len: cross cp_tc, cp_len;
    cp_shaped: coverpoint cbs_en[tx_tc] iff (rst_n && tx_start) { bins off = {0}; bins on = {1}; }
    x_tc_shaped: cross cp_tc, cp_shaped;
    cp_entry: coverpoint gcl_entry iff (rst_n && gcl_running) { bins e[] = {[0:7]}; }
    cp_gates: coverpoint gate_state iff (rst_n && gcl_running) { bins g[] = {[0:15]}; }
  endgroup
  cg_tsn u_cg_tsn = new;

  // ---------------- functional coverage ----------------
  `FC(tx_class0, v_tx[0])
  `FC(tx_class1, v_tx[1])
  `FC(tx_class2, v_tx[2])
  `FC(tx_class3, v_tx[3])
  `FC(frame_len_0, v_len0)
  `FC(frame_len_2047, v_len_max)
  `FC(back_to_back, v_b2b)
  `FC(guard_band_blocks, v_guard)
  `FC(guard_band_exact_fit, v_guard_exact)
  `FC(priority_over_waiting, v_prio_skip)
  `FC(shaper_blocks, v_cbs_block)
  `FC(credit_held_gate_closed, v_hold)
  `FC(credit_positive_dropped, v_drop_pos)
  `FC(credit_recovered_to_0, v_recover)
  `FC(credit_saturated_high, v_sat_hi)
  `FC(credit_saturated_low, v_sat_lo)
  `FC(frame_waits_closed_gate, v_gate_closed_wait)
  `FC(cycle_truncates_list, v_trunc)
  `FC(last_entry_extended, v_last_ext)
  `FC(entry_7_reached, v_entry7)
  `FC(cycle_remainder_carried, v_rem_carry)
  `FC(base_time_in_future, v_wait_base)
  `FC(cycle_restart, v_restart)
  `FC(time_set, v_set)
  `FC(time_adj_positive, v_adj_pos)
  `FC(time_adj_negative, v_adj_neg)
  `FC(time_fraction_carry, v_carry)
  `FC(time_wraps, v_wrap)
  `FC(schedule_stopped_running, gcl_running && !gcl_en)
  `FC(all_gates_closed, gcl_running && gate_state == 4'h0)
  `FC_RST(reset_mid_frame, rst_n && tx_busy ##1 !rst_n)
endmodule

bind Ethernet_AVB_TSN_top Ethernet_AVB_TSN_sva u_sva (.*);
