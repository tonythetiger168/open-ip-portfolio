// SPDX-License-Identifier: Apache-2.0
// SAE J2716 SENT: concurrent SVA against an independent, cycle-accurate
// reference model, plus functional coverage.
//  * Transmitter model: at each frame start it builds the frame as a list of
//    pulse lengths in ticks (sync, status with the serial bits, data, CRC,
//    pause) and plays it out clock by clock; sent_out, tx_frame_start,
//    ser_tx_busy and ser_tx_done are compared with it on every clock.
//  * Receiver model: its own synchroniser / glitch filter, period and low
//    time counters, and a frame decoder that classifies every period at the
//    falling edge that ends it (rounded ticks from 64-bit arithmetic, CRCs
//    as polynomial remainders, not shift registers). The outputs it expects
//    are scheduled for the clock the RTL gives them (the calibration path
//    at once, a divided period after 13 clocks, 2 when it overflows) and
//    every rx_* / ser_rx_* output is compared on every clock.
`include "cov_macros.svh"
module SENT_sva (
  input  logic        clk, rst_n, cfg_crc_legacy,
  input  logic        tx_en,
  input  logic [11:0] cfg_tx_tick_clks,
  input  logic [3:0]  cfg_tx_low_ticks,
  input  logic [2:0]  cfg_tx_nibbles,
  input  logic [1:0]  cfg_tx_pause_mode,
  input  logic [10:0] cfg_tx_pause,
  input  logic [3:0]  tx_status,
  input  logic [23:0] tx_data,
  input  logic        tx_frame_start, sent_out,
  input  logic        ser_tx_start, ser_tx_enh, ser_tx_cfg,
  input  logic [7:0]  ser_tx_id,
  input  logic [15:0] ser_tx_data,
  input  logic        ser_tx_busy, ser_tx_done,
  input  logic        sent_in,
  input  logic [11:0] cfg_rx_tick_clks,
  input  logic [2:0]  cfg_rx_nibbles,
  input  logic        cfg_rx_pause, cfg_rx_cal_check,
  input  logic [3:0]  cfg_rx_filt,
  input  logic        rx_valid,
  input  logic [3:0]  rx_status,
  input  logic [23:0] rx_data,
  input  logic [18:0] rx_cal_clks,
  input  logic        rx_err_nibble, rx_err_low, rx_err_crc, rx_err_pause, rx_err_sync, rx_err_cal,
  input  logic        ser_rx_valid, ser_rx_enh, ser_rx_cfg,
  input  logic [7:0]  ser_rx_id,
  input  logic [15:0] ser_rx_data,
  input  logic        ser_rx_err_crc
);
  `COV_CLOCKING(clk, !rst_n)

  // CRC as the remainder of a polynomial division: the register starts with
  // the seed, so the remainder is that of (seed . x^nb + msg) . x^aug mod g
  function automatic longint pmod(input longint v, input longint g, input int gw);
    for (int i = 62; i >= gw; i--) if (v[i]) v = v ^ (g << (i - gw));
    return v;
  endfunction
  function automatic int crc4m(input longint msg, input int nb, input bit legacy);
    longint v;
    v = (longint'(5) << nb) | msg;
    if (!legacy) v = v << 4;
    return int'(pmod(v, 64'h1D, 4));
  endfunction
  // fast channel CRC: nibble 0 first, MSB first
  function automatic int crc_frame(input logic [23:0] d, input int n, input bit legacy);
    longint m;
    m = 0;
    for (int i = 0; i < n; i++) m = (m << 4) | d[4 * i +: 4];
    return crc4m(m, 4 * n, legacy);
  endfunction
  // enhanced serial CRC over bit 2, bit 3 of frames 7..18 (interleaved)
  function automatic int crc6m(input logic [11:0] b2, input logic [11:0] b3);
    longint m;
    m = 0;
    for (int k = 11; k >= 0; k--) m = (m << 2) | {b2[k], b3[k]};
    return int'(pmod(((longint'(6'h15) << 24) | m) << 6, 64'h59, 6));
  endfunction
  function automatic int clampi(input int v, input int lo, input int hi);
    return v < lo ? lo : v > hi ? hi : v;
  endfunction

  // =========================================================================
  // transmitter model
  // =========================================================================
  bit         m_out, m_fs, m_busy, m_done, m_act;
  int         m_len [0:9];               // pulse lengths (ticks) of the frame
  int         m_np, m_pi, m_c, m_tc, m_low;
  bit         m_s3 [0:17], m_s2 [0:17];  // serial bits still to send, in order
  int         m_sl, m_sp;                // serial frames left, next bit
  // coverage flags, set for one clock
  bit         f_mode [0:3], f_pclamp_lo, f_pclamp_hi, f_fill_min, f_fill_max, f_low_lo, f_low_hi,
              f_tick_min, f_n0, f_n7, f_ser_short, f_ser_enh0, f_ser_enh1, f_ser_refused, f_tx_idle,
              f_tx_b2b, f_ser_frame, f_tx_legacy;
  int         c_tx_n, c_tx_mode;

  task automatic tx_start;
    int n, s, st, sum, pm;
    n  = cfg_tx_nibbles == 0 ? 1 : cfg_tx_nibbles == 7 ? 6 : cfg_tx_nibbles;
    st = tx_status;
    if (m_sl > 0) begin
      st = (st & 3) | (m_s3[m_sp] << 3) | (m_s2[m_sp] << 2);
      m_sp++; m_sl--; f_ser_frame = 1;
      if (m_sl == 0) begin m_busy = 0; m_done = 1; end
    end
    m_len[0] = 56; m_len[1] = 12 + st;
    for (int i = 0; i < n; i++) m_len[2 + i] = 12 + tx_data[4 * i +: 4];
    m_len[2 + n] = 12 + crc_frame(tx_data, n, cfg_crc_legacy);
    m_np = n + 3;
    sum = 0;
    for (int i = 0; i < m_np; i++) sum += m_len[i];
    pm = cfg_tx_pause_mode;
    if (pm == 1) begin
      m_len[m_np] = clampi(cfg_tx_pause, 12, 768); m_np++;
      f_pclamp_lo = cfg_tx_pause < 12; f_pclamp_hi = cfg_tx_pause > 768;
    end else if (pm >= 2) begin
      s = int'(cfg_tx_pause) - sum;
      m_len[m_np] = clampi(s, 12, 768); m_np++;
      f_fill_min = s <= 12; f_fill_max = s > 768;
    end
    m_tc  = cfg_tx_tick_clks < 4 ? 4 : cfg_tx_tick_clks;
    m_low = clampi(cfg_tx_low_ticks, 4, 11);
    m_act = 1; m_pi = 0; m_c = 0; m_out = 0; m_fs = 1;
    f_mode[pm] = 1; f_low_lo = cfg_tx_low_ticks < 4; f_low_hi = cfg_tx_low_ticks > 11;
    f_tick_min = cfg_tx_tick_clks < 4; f_n0 = cfg_tx_nibbles == 0; f_n7 = cfg_tx_nibbles == 7;
    f_tx_legacy = cfg_crc_legacy;
    c_tx_n = n; c_tx_mode = pm;
  endtask

  always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      m_out = 1; m_fs = 0; m_busy = 0; m_done = 0; m_act = 0; m_np = 0; m_pi = 0; m_c = 0;
      m_sl = 0; m_sp = 0; c_tx_n = 0; c_tx_mode = -1;
    end else begin
      bit busy0;
      busy0 = m_busy;
      m_fs = 0; m_done = 0; c_tx_n = 0; c_tx_mode = -1;
      foreach (f_mode[i]) f_mode[i] = 0;
      {f_pclamp_lo, f_pclamp_hi, f_fill_min, f_fill_max, f_low_lo, f_low_hi, f_tick_min, f_n0, f_n7,
       f_ser_short, f_ser_enh0, f_ser_enh1, f_ser_refused, f_tx_idle, f_tx_b2b, f_ser_frame, f_tx_legacy} = '0;
      if (!m_act) begin
        if (tx_en) tx_start();
      end else begin
        m_c++;
        if (m_c == m_len[m_pi] * m_tc) begin
          if (m_pi + 1 < m_np) begin m_pi++; m_c = 0; m_out = 0; end
          else if (tx_en) begin tx_start(); f_tx_b2b = 1; end
          else begin m_act = 0; m_out = 1; f_tx_idle = 1; end
        end else if (m_c == m_low * m_tc) m_out = 1;
      end
      // a serial message is taken when none is being sent (the frame starting
      // on this clock still went out without it)
      if (ser_tx_start && busy0) f_ser_refused = 1;
      if (ser_tx_start && !busy0) begin
        logic [3:0] a, b;
        logic [11:0] d12;
        int c;
        m_busy = 1; m_sp = 0;
        if (ser_tx_enh) begin
          m_sl = 18;
          a   = ser_tx_cfg ? ser_tx_id[3:0] : ser_tx_id[7:4];
          b   = ser_tx_cfg ? ser_tx_data[15:12] : ser_tx_id[3:0];
          d12 = ser_tx_data[11:0];
          for (int i = 0; i < 6; i++) m_s3[i] = 1;
          m_s3[6] = 0; m_s3[7] = ser_tx_cfg;
          for (int i = 0; i < 4; i++) begin m_s3[8 + i] = a[3 - i]; m_s3[13 + i] = b[3 - i]; end
          m_s3[12] = 0; m_s3[17] = 0;
          c = crc6m(d12, {m_s3[6], m_s3[7], m_s3[8], m_s3[9], m_s3[10], m_s3[11], m_s3[12], m_s3[13],
                          m_s3[14], m_s3[15], m_s3[16], m_s3[17]});
          for (int i = 0; i < 6; i++) m_s2[i] = c[5 - i];
          for (int i = 0; i < 12; i++) m_s2[6 + i] = d12[11 - i];
          if (ser_tx_cfg) f_ser_enh1 = 1; else f_ser_enh0 = 1;
        end else begin
          logic [15:0] w;
          m_sl = 16;
          w = {ser_tx_id[3:0], ser_tx_data[7:0], 4'(crc4m({ser_tx_id[3:0], ser_tx_data[7:0]}, 12, cfg_crc_legacy))};
          for (int i = 0; i < 16; i++) begin m_s3[i] = i == 0; m_s2[i] = w[15 - i]; end
          f_ser_short = 1;
        end
      end
    end
  end

  `SVA_INV(a_tx_line, sent_out == m_out)
  `SVA_INV(a_tx_frame_start, tx_frame_start == m_fs)
  `SVA_INV(a_ser_tx_busy, ser_tx_busy == m_busy)
  `SVA_INV(a_ser_tx_done, ser_tx_done == m_done)
  `SVA_IMP(a_tx_frame_starts_low, tx_frame_start, !sent_out)

  `FC(tx_no_pause, f_mode[0])
  `FC(tx_fixed_pause, f_mode[1])
  `FC(tx_constant_frame, f_mode[2])
  `FC(tx_constant_frame_mode3, f_mode[3])
  `FC(tx_pause_clamped_to_12, f_pclamp_lo)
  `FC(tx_pause_clamped_to_768, f_pclamp_hi)
  `FC(tx_constant_frame_pause_min, f_fill_min)
  `FC(tx_constant_frame_pause_max, f_fill_max)
  `FC(tx_low_clamped_to_4, f_low_lo)
  `FC(tx_low_clamped_to_11, f_low_hi)
  `FC(tx_tick_clamped_to_4, f_tick_min)
  `FC(tx_nibbles_0_is_1, f_n0)
  `FC(tx_nibbles_7_is_6, f_n7)
  `FC(tx_legacy_crc, f_tx_legacy)
  `FC(tx_back_to_back_frames, f_tx_b2b)
  `FC(tx_goes_idle, f_tx_idle)
  `FC(ser_tx_short_message, f_ser_short)
  `FC(ser_tx_enhanced_8bit_id, f_ser_enh0)
  `FC(ser_tx_enhanced_4bit_id, f_ser_enh1)
  `FC(ser_tx_start_while_busy, f_ser_refused)
  `FC(ser_tx_frame_carries_bits, f_ser_frame)

  // =========================================================================
  // receiver model
  // =========================================================================
  localparam int H = 0, ST = 1, DA = 2, CR = 3, PA = 4, SY = 5;
  // filtered line
  bit         r_s1, r_s2, r_lv;
  int         r_run;                     // clocks the synchronised line differs from the filtered one
  // period and low time
  int         r_per, r_low, r_lowq;
  bit         r_seen;
  // frame decoder
  int         r_state, r_cal, r_prev, r_ni, r_st;
  bit         r_prev_ok, r_drop;
  logic [23:0] r_d;
  // serial decoder: the status bits of the good frames, newest last
  bit         h3 [$], h2 [$];
  // scheduled outputs: {due, rx_valid, err[5:0], st, d, cal, ser_valid, enh, cfg, id, sdata, ser_crc}
  typedef struct {
    longint      due;
    bit          v;
    bit [5:0]    err;                     // nibble, low, crc, pause, sync, cal
    logic [3:0]  st;
    logic [23:0] d;
    logic [18:0] cal;
    bit          sv, enh, cf, sc;
    logic [7:0]  id;
    logic [15:0] sd;
  } ev_t;
  ev_t        q [$];
  longint     now;
  // outputs expected on this clock, and the held data outputs
  bit         e_v, e_sv, e_sc;
  bit [5:0]   e_err;
  logic [3:0] e_st;
  logic [23:0] e_d;
  logic [18:0] e_cal;
  bit         e_enh, e_cf;
  logic [7:0] e_id;
  logic [15:0] e_sd;
  // coverage flags
  bit         g_err_short, g_err_long, g_err_low, g_err_crc, g_pause_ok, g_pause_short, g_pause_long,
              g_pause_low, g_sync, g_drift, g_drift_ok, g_cut, g_ovf, g_per_sat, g_low_sat, g_glitch,
              g_good, g_legacy, g_ser_short, g_ser_enh0, g_ser_enh1, g_ser_crc_short, g_ser_crc_enh,
              g_ser_restart, g_drop_crc, g_cal_hunt, g_cal_sync, g_filt, g_cal_lo, g_cal_hi, g_pause_cal;
  int         c_rx_n, c_rx_st;

  function automatic ev_t ev0(input int lat);
    ev_t e;
    e = '{default: '0};
    e.due = now + lat;
    return e;
  endfunction

  // a frame ended: shift its status bits into the serial decoder
  task automatic ser_shift(inout ev_t e);
    int n;
    logic [17:0] b3, b2;
    h3.push_back(r_st[3]); h2.push_back(r_st[2]);
    if (h3.size() > 18) begin void'(h3.pop_front()); void'(h2.pop_front()); end
    n = h3.size();
    b3 = '0; b2 = '0;
    for (int i = 0; i < n; i++) begin b3[n - 1 - i] = h3[i]; b2[n - 1 - i] = h2[i]; end
    if (n == 18 && b3[17:12] == 6'h3F && !b3[11] && !b3[5] && !b3[0]) begin
      if (b2[17:12] == 6'(crc6m(b2[11:0], b3[11:0]))) begin
        e.sv = 1; e.enh = 1; e.cf = b3[10];
        e.id = b3[10] ? {4'h0, b3[9:6]} : {b3[9:6], b3[4:1]};
        e.sd = b3[10] ? {b3[4:1], b2[11:0]} : {4'h0, b2[11:0]};
        if (b3[10]) g_ser_enh1 = 1; else g_ser_enh0 = 1;
      end else begin e.sc = 1; g_ser_crc_enh = 1; end
      h3.delete(); h2.delete();
    end else if (n >= 16 && b3[15:0] == 16'h8000) begin
      if (b2[3:0] == 4'(crc4m(b2[15:4], 12, cfg_crc_legacy))) begin
        e.sv = 1; e.id = {4'h0, b2[15:12]}; e.sd = {8'h0, b2[11:4]}; g_ser_short = 1;
      end else begin e.sc = 1; g_ser_crc_short = 1; end
      h3.delete(); h2.delete();
    end
  endtask
  task automatic bad_frame;
    if (h3.size() > 0) g_ser_restart = 1;
    h3.delete(); h2.delete();
  endtask

  always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      r_s1 = 1; r_s2 = 1; r_lv = 1; r_run = 0; r_per = 0; r_low = 0; r_lowq = 0; r_seen = 0;
      r_state = H; r_cal = 0; r_prev = 0; r_ni = 0; r_st = 0; r_prev_ok = 0; r_drop = 0; r_d = '0;
      h3.delete(); h2.delete(); q.delete(); now = 0;
      e_v = 0; e_sv = 0; e_sc = 0; e_err = '0; e_st = '0; e_d = '0; e_cal = '0; e_enh = 0; e_cf = 0;
      e_id = '0; e_sd = '0; c_rx_n = 0; c_rx_st = -1;
    end else begin
      bit fall, rise, lv0;
      int P, L, n, tk, rn, low0;
      longint x;
      ev_t e;
      {g_err_short, g_err_long, g_err_low, g_err_crc, g_pause_ok, g_pause_short, g_pause_long,
       g_pause_low, g_sync, g_drift, g_drift_ok, g_cut, g_ovf, g_per_sat, g_low_sat, g_glitch,
       g_good, g_legacy, g_ser_short, g_ser_enh0, g_ser_enh1, g_ser_crc_short, g_ser_crc_enh,
       g_ser_restart, g_drop_crc, g_cal_hunt, g_cal_sync, g_filt, g_cal_lo, g_cal_hi, g_pause_cal} = '0;
      c_rx_n = 0; c_rx_st = -1;
      now++;
      // ---- filter: the line changes after cfg_rx_filt + 1 clocks of a new level
      lv0 = r_lv; low0 = r_low;
      fall = 0; rise = 0;
      if (r_s2 != r_lv) begin
        if (r_run + 1 > cfg_rx_filt) begin
          fall = r_lv; rise = !r_lv; r_lv = r_s2; r_run = 0; g_filt = cfg_rx_filt != 0;
        end else r_run++;
      end else begin
        g_glitch = r_run != 0;
        r_run = 0;
      end
      r_s2 = r_s1; r_s1 = sent_in;
      // ---- period and low counters (values up to this clock)
      P = r_per; L = r_lowq;
      if (r_per != 22'h3FFFFF) r_per++;
      if (!lv0 && low0 != 15'h7FFF) r_low = low0 + 1;     // counts while the line was low
      if (rise) r_lowq = low0;
      if (fall) begin
        r_per = 1; r_low = 0;
        g_per_sat = r_seen && P == 22'h3FFFFF; g_low_sat = r_seen && L == 15'h7FFF;
      end
      // ---- the period that just ended
      if (fall && r_seen) begin
        tk = cfg_rx_tick_clks;
        if (r_state != PA && 4 * P >= 168 * tk && 4 * P <= 280 * tk) begin
          // calibration pulse: a new frame
          e = ev0(0);
          g_cal_lo = 4 * P < 196 * tk; g_cal_hi = 4 * P > 252 * tk;
          if (r_state == ST || r_state == DA || r_state == CR) begin e.err[5] = 1; g_cut = 1; bad_frame(); end
          g_cal_hunt = r_state == H; g_cal_sync = r_state == SY;
          r_drop = 0;
          if (r_state == SY && cfg_rx_cal_check && r_prev_ok) begin
            if (64 * longint'(P > r_prev ? P - r_prev : r_prev - P) > r_prev) begin
              r_drop = 1; e.err[0] = 1; g_drift = 1; bad_frame();
            end else g_drift_ok = 1;
          end
          if (e.err != 0) q.push_back(e);
          r_cal = P; r_prev = P; r_prev_ok = 1; r_state = ST; r_ni = 0; r_d = '0;
        end else if (r_state == SY) begin
          e = ev0(0); e.err[1] = 1; q.push_back(e);
          r_state = H; r_prev_ok = 0; g_sync = 1; bad_frame();
        end else if (r_state != H) begin
          // ticks = round(56 P / cal); 1024 ticks or more read as 2047
          x = 112 * longint'(P);
          if (x >= 2048 * longint'(r_cal)) begin n = 2047; e = ev0(2); g_ovf = 1; end
          else begin n = int'((x + r_cal) / (2 * r_cal)); e = ev0(13); end
          rn = cfg_rx_nibbles == 0 ? 1 : cfg_rx_nibbles == 7 ? 6 : cfg_rx_nibbles;
          if (r_state == PA) begin
            if (n < 12 || n > 768 || 16 * L < r_cal) begin
              e.err[2] = 1; r_state = H; r_prev_ok = 0;
              g_pause_short = n < 12; g_pause_long = n > 768; g_pause_low = n >= 12 && n <= 768;
            end else begin r_state = SY; g_pause_ok = 1; g_pause_cal = n >= 42 && n <= 70; end
          end else if (n < 12 || n > 27) begin
            e.err[5] = 1; r_state = H; r_prev_ok = 0; bad_frame();
            g_err_short = n < 12; g_err_long = n > 27;
          end else if (16 * L < r_cal) begin
            e.err[4] = 1; r_state = H; r_prev_ok = 0; bad_frame(); g_err_low = 1;
          end else if (r_state == ST) begin
            r_st = n - 12; r_state = DA;
          end else if (r_state == DA) begin
            r_d[4 * r_ni +: 4] = 4'(n - 12);
            if (r_ni == rn - 1) r_state = CR; else r_ni++;
          end else begin
            r_state = cfg_rx_pause ? PA : SY;
            if (r_drop) begin bad_frame(); g_drop_crc = 1; end
            else if (n - 12 == crc_frame(r_d, rn, cfg_crc_legacy)) begin
              e.v = 1; e.st = 4'(r_st); e.d = r_d; e.cal = 19'(r_cal);
              g_good = 1; g_legacy = cfg_crc_legacy; c_rx_n = rn; c_rx_st = r_st;
              ser_shift(e);
            end else begin e.err[3] = 1; g_err_crc = 1; bad_frame(); end
          end
          if (e.v || e.err != 0 || e.sv || e.sc) q.push_back(e);
        end
      end
      if (fall) r_seen = 1;
      // ---- the outputs due on this clock
      e_v = 0; e_sv = 0; e_sc = 0; e_err = '0;
      if (q.size() != 0 && q[0].due == now) begin
        e = q.pop_front();
        e_v = e.v; e_err = e.err; e_sv = e.sv; e_sc = e.sc;
        if (e.v) begin e_st = e.st; e_d = e.d; e_cal = e.cal; end
        if (e.sv) begin e_enh = e.enh; e_cf = e.cf; e_id = e.id; e_sd = e.sd; end
      end
    end
  end

  `SVA_INV(a_rx_valid, rx_valid == e_v)
  `SVA_INV(a_rx_errors, {rx_err_nibble, rx_err_low, rx_err_crc, rx_err_pause, rx_err_sync, rx_err_cal}
                        == {e_err[5], e_err[4], e_err[3], e_err[2], e_err[1], e_err[0]})
  `SVA_INV(a_rx_frame_data, {rx_status, rx_data, rx_cal_clks} == {e_st, e_d, e_cal})
  `SVA_INV(a_ser_rx_valid, ser_rx_valid == e_sv && ser_rx_err_crc == e_sc)
  `SVA_INV(a_ser_rx_data, {ser_rx_enh, ser_rx_cfg, ser_rx_id, ser_rx_data} == {e_enh, e_cf, e_id, e_sd})
  `SVA_INV(a_rx_schedule, q.size() == 0 || q[0].due > now)
  `SVA_IMP(a_rx_one_error, $countones({rx_err_nibble, rx_err_low, rx_err_crc, rx_err_pause, rx_err_sync, rx_err_cal}) != 0,
           $countones({rx_err_nibble, rx_err_low, rx_err_crc, rx_err_pause, rx_err_sync, rx_err_cal}) == 1 && !rx_valid)

  `FC(rx_good_frame, g_good)
  `FC(rx_good_frame_legacy_crc, g_good && g_legacy)
  `FC(rx_nibble_too_short, g_err_short)
  `FC(rx_nibble_too_long, g_err_long)
  `FC(rx_low_too_short, g_err_low)
  `FC(rx_crc_error, g_err_crc)
  `FC(rx_pause_ok, g_pause_ok)
  `FC(rx_pause_of_calibration_length, g_pause_cal)
  `FC(rx_pause_too_short, g_pause_short)
  `FC(rx_pause_too_long, g_pause_long)
  `FC(rx_pause_low_too_short, g_pause_low)
  `FC(rx_sync_missing, g_sync)
  `FC(rx_calibration_drift, g_drift)
  `FC(rx_calibration_drift_within_limit, g_drift_ok)
  `FC(rx_drifted_frame_dropped_at_crc, g_drop_crc)
  `FC(rx_calibration_cuts_frame, g_cut)
  `FC(rx_calibration_from_hunt, g_cal_hunt)
  `FC(rx_calibration_after_frame, g_cal_sync)
  `FC(rx_calibration_short_side, g_cal_lo)
  `FC(rx_calibration_long_side, g_cal_hi)
  `FC(rx_period_of_1024_ticks_or_more, g_ovf)
  `FC(rx_period_counter_saturated, g_per_sat)
  `FC(rx_low_counter_saturated, g_low_sat)
  `FC(rx_glitch_filtered, g_glitch)
  `FC(rx_edge_through_filter, g_filt)
  `FC(ser_rx_short_message, g_ser_short)
  `FC(ser_rx_enhanced_8bit_id, g_ser_enh0)
  `FC(ser_rx_enhanced_4bit_id, g_ser_enh1)
  `FC(ser_rx_short_crc_error, g_ser_crc_short)
  `FC(ser_rx_enhanced_crc_error, g_ser_crc_enh)
  `FC(ser_rx_restarted_by_bad_frame, g_ser_restart)

  covergroup cg_sent @(negedge clk);
    option.per_instance = 1;
    cp_tx_n: coverpoint c_tx_n iff (c_tx_mode >= 0) { bins n[] = {[1:6]}; }
    cp_tx_mode: coverpoint c_tx_mode iff (c_tx_mode >= 0) { bins none = {0}; bins fixed = {1}; bins constant = {2}; }
    x_tx: cross cp_tx_n, cp_tx_mode;
    cp_rx_n: coverpoint c_rx_n iff (c_rx_n != 0) { bins n[] = {[1:6]}; }
    cp_rx_st: coverpoint c_rx_st iff (c_rx_st >= 0) { bins st[] = {[0:15]}; }
  endgroup
  cg_sent u_cg_sent = new;
endmodule

bind SENT_top SENT_sva u_sva (.*);
