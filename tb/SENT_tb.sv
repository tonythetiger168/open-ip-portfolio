// SPDX-License-Identifier: Apache-2.0
// ============================================================================
// Self-checking testbench for SENT_top v1.0
//  * Transmitter: every pulse on sent_out is measured in clocks and compared
//    with the frame the TB expects from tx_status / tx_data at
//    tx_frame_start (sync 56, status, data, CRC from the TB's own table
//    form of the CRC, pause by mode), low part = cfg_tx_low_ticks (clamped
//    to 4..11) ticks. Serial messages: the TB builds the bit 3 / bit 2
//    sequences itself (its own CRC-4 / CRC-6 tables) and expects them in the
//    status nibbles of the following frames.
//  * Receiver: a reference receiver at pulse level gets every period the
//    line carries (from the TB's sensor BFM, or the DUT's own transmitter
//    in loopback) and predicts the receiver's events in order: frames,
//    nibble / low / CRC / pause / sync / calibration errors and serial
//    messages; they are compared with what the DUT reports.
//  * BFM: ticks off by up to +-20 % (a calibration pulse outside +-25 % is
//    no calibration pulse), wrong nibbles (11 / 28 ticks), short low parts,
//    bad CRCs, pauses out of range, missing calibration pulses, drift above
//    1/64, a calibration pulse in the middle of a frame, glitches shorter
//    than the filter, serial messages (good, bad CRC, broken by an error).
//  * All nibble counts, pause modes, low times, legacy / recommended CRC,
//    tx_en stop and restart, reset in the middle of a frame.
// ============================================================================
`timescale 1ns/1ps
module SENT_tb;
  logic clk = 0, rst_n = 0;
  always #5 clk = ~clk;

  logic        cfg_crc_legacy = 0;
  logic        tx_en = 0;
  logic [11:0] cfg_tx_tick_clks = 8;
  logic [3:0]  cfg_tx_low_ticks = 5;
  logic [2:0]  cfg_tx_nibbles = 6;
  logic [1:0]  cfg_tx_pause_mode = 0;
  logic [10:0] cfg_tx_pause = 0;
  logic [3:0]  tx_status = 0;
  logic [23:0] tx_data = 0;
  wire         tx_frame_start, sent_out;
  logic        ser_tx_start = 0, ser_tx_enh = 0, ser_tx_cfg = 0;
  logic [7:0]  ser_tx_id = 0;
  logic [15:0] ser_tx_data = 0;
  wire         ser_tx_busy, ser_tx_done;
  logic [11:0] cfg_rx_tick_clks = 8;
  logic [2:0]  cfg_rx_nibbles = 6;
  logic        cfg_rx_pause = 0, cfg_rx_cal_check = 0;
  logic [3:0]  cfg_rx_filt = 1;
  wire         rx_valid, rx_err_nibble, rx_err_low, rx_err_crc, rx_err_pause, rx_err_sync, rx_err_cal;
  wire  [3:0]  rx_status;
  wire  [23:0] rx_data;
  wire  [18:0] rx_cal_clks;
  wire         ser_rx_valid, ser_rx_enh, ser_rx_cfg, ser_rx_err_crc;
  wire  [7:0]  ser_rx_id;
  wire  [15:0] ser_rx_data;

  logic bfm_line = 1, use_bfm = 1;
  wire  sent_in = use_bfm ? bfm_line : sent_out;

  SENT_top dut (.*);

  int errors = 0;
  function automatic void fail(input string m);
    errors++;
    $display("ERROR: %s @%0t", m, $time);
  endfunction
  task automatic cyc(input int n); for (int i = 0; i < n; i++) @(negedge clk); endtask

  // ---------------- reference CRCs (table form) ----------------
  int T4 [0:15];
  int T6 [0:63];
  initial begin
    T4[0] = 0; T4[1] = 13; T4[2] = 7; T4[3] = 10; T4[4] = 14; T4[5] = 3; T4[6] = 9; T4[7] = 4;
    T4[8] = 1; T4[9] = 12; T4[10] = 6; T4[11] = 11; T4[12] = 15; T4[13] = 2; T4[14] = 8; T4[15] = 5;
    for (int c = 0; c < 64; c++) begin
      int v;
      v = c;
      for (int k = 0; k < 6; k++) begin v = v << 1; if (v & 64) v = v ^ 'h59; end
      T6[c] = v;
    end
  end
  function automatic int ref_crc4(input logic [23:0] d, input int n, input bit legacy);
    int c;
    c = 5;
    for (int i = 0; i < n; i++) c = d[4 * i +: 4] ^ T4[c];
    if (!legacy) c = T4[c];
    return c;
  endfunction
  function automatic int ref_crc6(input logic [11:0] b2, input logic [11:0] b3);
    logic [23:0] m;
    int c;
    for (int k = 0; k < 12; k++) begin m[23 - 2 * k] = b2[11 - k]; m[22 - 2 * k] = b3[11 - k]; end
    c = 21;
    for (int i = 0; i < 4; i++) c = m[23 - 6 * i -: 6] ^ T6[c];
    return T6[c];
  endfunction
  function automatic int nib_n(input int c); return c == 0 ? 1 : c == 7 ? 6 : c; endfunction
  // serial message bits (index 17 = first frame) for an id / data
  task automatic ser_bits(input bit enh, input bit cf, input logic [7:0] id, input logic [15:0] d,
                          output logic [17:0] b3, output logic [17:0] b2, output int len);
    logic [3:0] a, b;
    if (enh) begin
      a = cf ? id[3:0] : id[7:4];
      b = cf ? d[15:12] : id[3:0];
      b3 = {6'b111111, 1'b0, cf, a, 1'b0, b, 1'b0};
      b2[11:0] = d[11:0];
      b2[17:12] = 6'(ref_crc6(d[11:0], b3[11:0]));
      len = 18;
    end else begin
      b3 = {1'b1, 17'd0};
      // CRC over the nibbles id, d[7:4], d[3:0]
      b2 = {id[3:0], d[7:0], 4'(ref_crc4({12'd0, d[3:0], d[7:4], id[3:0]}, 3, cfg_crc_legacy)), 2'b00};
      len = 16;
    end
  endtask

  // ---------------- receiver events ----------------
  // 1 frame, 2 nibble error, 3 low, 4 CRC, 5 pause, 6 sync, 7 calibration, 8 serial, 9 serial CRC
  int          got_c [0:4095], exp_c [0:4095];
  logic [63:0] got_v [0:4095], exp_v [0:4095];
  int          got_n = 0, exp_n = 0, chk_n = 0;
  int          n_ev [1:9];
  initial for (int i = 1; i <= 9; i++) n_ev[i] = 0;
  task automatic got(input int c, input logic [63:0] v);
    got_c[got_n % 4096] = c; got_v[got_n % 4096] = v; got_n++; n_ev[c]++;
  endtask
  always @(negedge clk) if (rst_n) begin
    if (rx_err_cal) got(7, 0);
    if (rx_err_nibble) got(2, 0);
    if (rx_err_sync) got(6, 0);
    if (rx_err_low) got(3, 0);
    if (rx_err_pause) got(5, 0);
    if (rx_err_crc) got(4, 0);
    if (rx_valid) got(1, {17'd0, rx_cal_clks, rx_status, rx_data});
    if (ser_rx_err_crc) got(9, 0);
    if (ser_rx_valid) got(8, {38'd0, ser_rx_enh, ser_rx_cfg, ser_rx_id, ser_rx_data});
  end
  function automatic void expect_ev(input int c, input logic [63:0] v);
    exp_c[exp_n % 4096] = c; exp_v[exp_n % 4096] = v; exp_n++;
  endfunction
  task automatic check_ev(input string what);
    bit bad;
    cyc(30);                                              // the divider and the serial decoder
    if (got_n != exp_n) fail($sformatf("%s: %0d receiver events, expected %0d", what, got_n - chk_n, exp_n - chk_n));
    bad = 0;
    for (int i = chk_n; i < got_n && i < exp_n && !bad; i++)
      if (got_c[i % 4096] != exp_c[i % 4096] || got_v[i % 4096] !== exp_v[i % 4096]) begin
        fail($sformatf("%s: event %0d is %0d %h, expected %0d %h", what, i - chk_n,
                       got_c[i % 4096], got_v[i % 4096], exp_c[i % 4096], exp_v[i % 4096]));
        bad = 1;
      end
    if (got_n > exp_n) exp_n = got_n;
    got_n = exp_n; chk_n = exp_n;
  endtask

  // ---------------- reference receiver (pulse level) ----------------
  localparam int M_HUNT = 0, M_STATUS = 1, M_DATA = 2, M_CRC = 3, M_PAUSE = 4, M_SYNC = 5;
  int          m_st = M_HUNT, m_cal = 0, m_prev = 0, m_ni = 0;
  bit          m_seen = 0, m_prev_ok = 0, m_drop = 0;
  logic [3:0]  m_status;
  logic [23:0] m_data;
  logic [17:0] h3, h2;
  int          hn = 0;
  task automatic m_reset;
    m_st = M_HUNT; m_seen = 0; m_prev_ok = 0; m_drop = 0; hn = 0;
  endtask
  task automatic m_frame_bad; hn = 0; endtask
  task automatic m_frame_good(input logic [3:0] st);
    h3 = {h3[16:0], st[3]}; h2 = {h2[16:0], st[2]};
    if (hn < 18) hn++;
    if (hn == 18 && h3[17:12] == 6'b111111 && !h3[11] && !h3[5] && !h3[0]) begin
      if (h2[17:12] == 6'(ref_crc6(h2[11:0], h3[11:0])))
        expect_ev(8, {38'd0, 1'b1, h3[10], h3[10] ? {4'd0, h3[9:6]} : {h3[9:6], h3[4:1]},
                      h3[10] ? {h3[4:1], h2[11:0]} : {4'd0, h2[11:0]}});
      else expect_ev(9, 0);
      hn = 0;
    end else if (hn >= 16 && h3[15:0] == 16'h8000) begin
      if (h2[3:0] == 4'(ref_crc4({12'd0, h2[7:4], h2[11:8], h2[15:12]}, 3, cfg_crc_legacy)))
        expect_ev(8, {38'd0, 1'b0, 1'b0, 4'd0, h2[15:12], 8'd0, h2[11:4]});
      else expect_ev(9, 0);
      hn = 0;
    end
  endtask
  // one period between falling edges, p clocks, of which the first lw (pulse before) were low
  task automatic m_period(input int p, input int lw);
    bit is_cal, nib_ok, low_ok;
    int q;
    if (p > 4194303) p = 4194303;                         // the period counter saturates
    if (lw > 32767) lw = 32767;
    is_cal = 4 * p >= 168 * cfg_rx_tick_clks && 4 * p <= 280 * cfg_rx_tick_clks;
    q = (112 * p + m_cal) / (2 * (m_cal == 0 ? 1 : m_cal));
    if (q > 1023) q = 2047;
    nib_ok = q >= 12 && q <= 27;
    low_ok = 16 * lw >= m_cal;
    if (!m_seen) m_seen = 1;
    else if (m_st != M_PAUSE && is_cal) begin
      if (m_st == M_STATUS || m_st == M_DATA || m_st == M_CRC) begin expect_ev(2, 0); m_frame_bad(); end
      m_drop = cfg_rx_cal_check && m_prev_ok && m_st == M_SYNC && 64 * (p > m_prev ? p - m_prev : m_prev - p) > m_prev;
      if (m_drop) begin expect_ev(7, 0); m_frame_bad(); end
      m_cal = p; m_prev = p; m_prev_ok = 1; m_st = M_STATUS; m_ni = 0; m_data = 0;
    end else if (m_st == M_SYNC) begin
      expect_ev(6, 0); m_st = M_HUNT; m_prev_ok = 0; m_frame_bad();
    end else if (m_st == M_PAUSE) begin
      if (q < 12 || q > 768 || !low_ok) begin expect_ev(5, 0); m_st = M_HUNT; m_prev_ok = 0; end
      else m_st = M_SYNC;
    end else if (m_st != M_HUNT) begin
      if (!nib_ok) begin expect_ev(2, 0); m_st = M_HUNT; m_prev_ok = 0; m_frame_bad(); end
      else if (!low_ok) begin expect_ev(3, 0); m_st = M_HUNT; m_prev_ok = 0; m_frame_bad(); end
      else if (m_st == M_STATUS) begin m_status = 4'(q - 12); m_st = M_DATA; m_ni = 0; end
      else if (m_st == M_DATA) begin
        m_data[4 * m_ni +: 4] = 4'(q - 12);
        if (m_ni == nib_n(cfg_rx_nibbles) - 1) m_st = M_CRC; else m_ni++;
      end else begin
        m_st = cfg_rx_pause ? M_PAUSE : M_SYNC;
        if (m_drop) m_frame_bad();
        else if (q - 12 == ref_crc4(m_data, nib_n(cfg_rx_nibbles), cfg_crc_legacy)) begin
          expect_ev(1, {17'd0, 19'(m_cal), m_status, m_data}); m_frame_good(m_status);
        end else begin expect_ev(4, 0); m_frame_bad(); end
      end
    end
  endtask
  // the line as the receiver samples it: periods and low parts in clocks
  int clk_n = 0, ml_last = 0, ml_low = 0;
  bit ml_prev = 1, mon_off = 0;
  always @(posedge clk) begin
    clk_n++;
    if (rst_n && !mon_off) begin
      if (ml_prev && !sent_in) begin m_period(clk_n - ml_last, ml_low); ml_last = clk_n; ml_low = 0; end
      if (!sent_in) ml_low++;
      ml_prev = sent_in;
    end
  end

  // ---------------- sensor BFM ----------------
  int bfm_tk = 8;                         // clocks per tick
  // a pulse of t ticks with lw ticks low (the period ends at the next pulse)
  task automatic bfm_pulse(input int t, input int lw, input int extra = 0);
    @(posedge clk); #2;
    bfm_line = 0;
    for (int i = 0; i < lw * bfm_tk; i++) @(posedge clk);
    #2 bfm_line = 1;
    for (int i = 0; i < (t - lw) * bfm_tk - 1 + extra; i++) @(posedge clk);
  endtask
  // the falling edge that ends the last pulse of a burst, then idle
  task automatic bfm_end;
    bfm_pulse(20, 5);
    cyc(10);
  endtask
  // one frame: nibble values (or raw ticks when > 15), CRC override (-1: right one)
  task automatic bfm_frame(input logic [3:0] st, input logic [23:0] d, input int n, input int crc = -1,
                           input int bad_at = -1, input int bad_ticks = 0, input int pause = 0,
                           input int lw = 5, input int short_at = -1, input int sx = 0);
    int c;
    c = crc < 0 ? ref_crc4(d, n, cfg_crc_legacy) : crc;
    bfm_pulse(56, lw, sx);                                  // sx: clocks off whole ticks
    for (int i = 0; i < n + 2; i++) begin
      int v;
      v = i == 0 ? 12 + st : i <= n ? 12 + d[4 * (i - 1) +: 4] : 12 + c;
      if (i == bad_at) v = bad_ticks;
      bfm_pulse(v, i == short_at ? 3 : lw);
    end
    if (pause > 0) bfm_pulse(pause, short_at == n + 2 ? 3 : lw);
  endtask

  // ---------------- transmitter checker ----------------
  int          tq [0:255];                // expected pulse ticks, FIFO
  int          tq_h = 0, tq_t = 0;
  int          t_last = -1, t_low = 0, n_pulses = 0;
  bit          prev_out = 1;
  logic [17:0] sb3, sb2;                  // serial bits the TB expects in the next frames
  int          s_len = 0;
  bit          s_armed = 0;
  logic [17:0] a3, a2;
  int          a_len;
  int          n_frames = 0, n_ser_done = 0;
  function automatic int low_t;
    return cfg_tx_low_ticks < 4 ? 4 : cfg_tx_low_ticks > 11 ? 11 : cfg_tx_low_ticks;
  endfunction
  function automatic int tk_t;
    return cfg_tx_tick_clks < 4 ? 4 : cfg_tx_tick_clks;
  endfunction
  always @(negedge clk) if (rst_n) begin
    // the transmitter's frame: what it must send
    if (tx_frame_start) begin
      logic [3:0] st;
      int n, c, sum, pz;
      n_frames++;
      st = tx_status;
      if (s_armed) begin sb3 = a3; sb2 = a2; s_len = a_len; s_armed = 0; end
      if (s_len > 0) begin
        st[3:2] = {sb3[17], sb2[17]}; sb3 = sb3 << 1; sb2 = sb2 << 1; s_len--;
        if (s_len == 0 && !ser_tx_done) fail("ser_tx_done missing");
      end else if (ser_tx_done) fail("ser_tx_done without a message");
      n = nib_n(cfg_tx_nibbles);
      c = ref_crc4(tx_data, n, cfg_crc_legacy);
      tq[tq_t % 256] = 56; tq_t++;
      tq[tq_t % 256] = 12 + st; tq_t++;
      sum = 56 + 12 + st + 12 + c;
      for (int i = 0; i < n; i++) begin tq[tq_t % 256] = 12 + tx_data[4 * i +: 4]; tq_t++; sum += 12 + tx_data[4 * i +: 4]; end
      tq[tq_t % 256] = 12 + c; tq_t++;
      if (cfg_tx_pause_mode != 0) begin
        if (cfg_tx_pause_mode == 1) pz = cfg_tx_pause < 12 ? 12 : cfg_tx_pause > 768 ? 768 : cfg_tx_pause;
        else pz = cfg_tx_pause <= sum + 12 ? 12 : cfg_tx_pause - sum > 768 ? 768 : cfg_tx_pause - sum;
        tq[tq_t % 256] = pz; tq_t++;
      end
    end else if (ser_tx_done) fail("ser_tx_done outside a frame start");
    if (ser_tx_done) n_ser_done++;
    // the line
    if (prev_out && !sent_out) begin
      if (t_last >= 0) begin
        if (tq_h == tq_t) fail($sformatf("transmitter pulse not expected (%0d clocks)", clk_n - t_last));
        else begin
          if (clk_n - t_last != tq[tq_h % 256] * tk_t()) fail($sformatf("pulse of %0d clocks, expected %0d ticks of %0d",
                                                                         clk_n - t_last, tq[tq_h % 256], tk_t()));
          if (t_low != low_t() * tk_t()) fail($sformatf("low part of %0d clocks, expected %0d", t_low, low_t() * tk_t()));
          tq_h++; n_pulses++;
        end
      end
      t_last = clk_n; t_low = 0;
    end
    if (!sent_out) t_low++;
    prev_out = sent_out;
  end
  // queue a serial message on the transmitter (just after a frame start)
  task automatic ser_send(input bit enh, input bit cf, input logic [7:0] id, input logic [15:0] d,
                          input bit refused = 0);
    @(posedge tx_frame_start); @(negedge clk); #1;          // after the checker took the frame
    if (ser_tx_busy != refused) fail("serial transmitter busy");
    if (!refused) begin ser_bits(enh, cf, id, d, a3, a2, a_len); s_armed = 1; end
    ser_tx_enh = enh; ser_tx_cfg = cf; ser_tx_id = id; ser_tx_data = d; ser_tx_start = 1;
    @(negedge clk); ser_tx_start = 0; ser_tx_id = $urandom; ser_tx_data = $urandom;
    if (!ser_tx_busy) fail("ser_tx_busy not set");
  endtask
  // n frames of random data from the transmitter
  task automatic tx_frames(input int n);
    for (int i = 0; i < n; i++) begin
      @(posedge tx_frame_start); @(negedge clk); #1;         // after the checker took the frame
      tx_status = $urandom; tx_data = $urandom;
    end
  endtask
  // stop the transmitter after its frame, check its pulses
  task automatic tx_stop;
    @(posedge tx_frame_start); @(negedge clk); #1;
    tx_en = 0;
    while (!(dut.tst == 0)) @(negedge clk);
    cyc(5);
    // the last pulse of the frame has no end
    if (tq_t - tq_h != 1) fail($sformatf("%0d transmitter pulses missing", tq_t - tq_h - 1));
    tq_h = tq_t; t_last = -1;              // the last pulse runs into the idle line
  endtask

  // ---------------- scenarios ----------------
  initial begin
    logic [23:0] d;
    cyc(3);
    rst_n = 1;
    cyc(3);

    // 1. loopback: the transmitter feeds the receiver
    $display("[%0t] section 1: loopback", $time);
    use_bfm = 0; m_reset();
    for (int n = 0; n < 8; n++) begin
      cfg_tx_nibbles = n; cfg_rx_nibbles = n;
      cfg_tx_pause_mode = n % 3; cfg_rx_pause = n % 3 != 0;
      cfg_tx_pause = n % 3 == 1 ? 11'(12 + 50 * n) : 11'(250 + 20 * n);
      cfg_tx_low_ticks = 4'(n + 3);
      cfg_crc_legacy = n[0];
      tx_status = $urandom; tx_data = $urandom;
      tx_en = 1;
      tx_frames(6);
      tx_stop();
      check_ev($sformatf("loopback %0d", n));
    end
    // every data nibble count in every pause mode, all-ones frames first
    // (the longest frame: the tick sum passes 255)
    cfg_crc_legacy = 0; cfg_tx_low_ticks = 5;
    for (int n = 1; n <= 6; n++)
      for (int pm = 0; pm < 3; pm++) begin
        cfg_tx_nibbles = n; cfg_rx_nibbles = n;
        cfg_tx_pause_mode = pm; cfg_rx_pause = pm != 0;
        cfg_tx_pause = pm == 1 ? 11'(12 + 50 * n) : 11'(250 + 20 * n);
        tx_status = 4'hF; tx_data = 24'hFF_FFFF;
        tx_en = 1;
        tx_frames(2);
        tx_stop();
        check_ev($sformatf("nibbles %0d pause mode %0d", n, pm));
      end
    cfg_crc_legacy = 0; cfg_tx_low_ticks = 5; cfg_tx_nibbles = 6; cfg_rx_nibbles = 6;
    cfg_tx_pause_mode = 0; cfg_rx_pause = 0;
    // pause limits: fixed 0 (12), 2047 (768); constant length too short (12), too long (768);
    // mode 3 is a constant frame length as well
    for (int i = 0; i < 5; i++) begin
      cfg_tx_pause_mode = i < 2 ? 1 : i < 4 ? 2 : 3; cfg_rx_pause = 1;
      cfg_tx_pause = i == 0 ? 0 : i == 1 ? 2047 : i == 2 ? 100 : i == 3 ? 2047 : 400;
      tx_en = 1; tx_frames(3); tx_stop();
      check_ev($sformatf("pause limit %0d", i));
    end
    cfg_tx_pause_mode = 0; cfg_rx_pause = 0;
    // tick lengths: the minimum (and below it), long ticks; low part clamped
    for (int i = 0; i < 4; i++) begin
      cfg_tx_tick_clks = i == 0 ? 2 : i == 1 ? 4 : i == 2 ? 13 : 61;
      cfg_rx_tick_clks = cfg_tx_tick_clks < 4 ? 4 : cfg_tx_tick_clks;
      cfg_tx_low_ticks = i == 0 ? 0 : i == 1 ? 15 : 4'(i + 6);
      tx_en = 1; tx_frames(3); tx_stop();
      check_ev($sformatf("tick %0d", cfg_tx_tick_clks));
    end
    cfg_tx_tick_clks = 8; cfg_rx_tick_clks = 8; cfg_tx_low_ticks = 5;

    // 2. serial messages through the loop
    $display("[%0t] section 2: serial messages", $time);
    for (int lg = 0; lg < 2; lg++) begin
      cfg_crc_legacy = lg;                                  // only while the line is idle
      tx_en = 1;
      for (int i = 0; i < (lg ? 3 : 7); i++) begin
        // 8-bit IDs FF, 00, FF and 16-bit data FFFF, 0000, FFFF: every bit falls
        ser_send(i % 3 != 0, i % 3 == 2, i == 1 ? 8'hFF : i == 4 ? 8'h00 : 8'($urandom),
                 i == 2 ? 16'hFFFF : i == 5 ? 16'h0000 : 16'($urandom));
        while (ser_tx_busy) begin @(posedge tx_frame_start); @(negedge clk); #1 tx_status = $urandom; tx_data = $urandom; end
        tx_frames(i % 2);                                   // a frame or none between messages
      end
      if (!lg) begin
        ser_send(0, 0, 8'h0F, 16'h00FF);
        ser_send(1, 0, 8'hFF, 16'h0FFF, 1);                 // queued while busy: refused
        while (ser_tx_busy) @(negedge clk);
      end
      tx_frames(2);
      tx_stop();
      check_ev("serial messages");
    end
    if (n_ev[8] != 11) fail($sformatf("%0d serial messages received", n_ev[8]));
    cfg_crc_legacy = 0;
    use_bfm = 1;
    cyc(20);

    // 3. receiver: tick drift within the window, legacy CRC, all nibble counts
    $display("[%0t] section 3: receiver", $time);
    for (int i = 0; i < 6; i++) begin
      bfm_tk = i == 0 ? 7 : i == 1 ? 10 : i == 2 ? 8 : i == 3 ? 9 : 8;
      cfg_rx_nibbles = 3'(i + 1);
      cfg_crc_legacy = i == 3;
      for (int k = 0; k < 4; k++) bfm_frame(4'($urandom), 24'($urandom), i + 1, -1, -1, 0, 0, 5, -1, k + i);
      bfm_end();
      check_ev($sformatf("receiver %0d", i));
    end
    cfg_crc_legacy = 0; cfg_rx_nibbles = 6; bfm_tk = 8;
    // calibration pulses outside +-25 %: no frame
    bfm_tk = 6; bfm_frame(1, 24'h123456, 6); bfm_end(); check_ev("tick -25 %");    // just inside
    bfm_tk = 5; bfm_frame(1, 24'h123456, 6); bfm_end(); check_ev("tick -37 %");
    bfm_tk = 11; bfm_frame(1, 24'h123456, 6); bfm_end(); check_ev("tick +37 %");
    bfm_tk = 8;
    // a realistic tick: 3 us at 100 MHz
    cfg_rx_tick_clks = 300; bfm_tk = 300;
    bfm_frame(4'hA, 24'hFEDCBA, 6); bfm_frame(4'h5, 24'h012345, 6); bfm_end();
    check_ev("3 us tick");
    cfg_rx_tick_clks = 600; bfm_tk = 600; cfg_rx_nibbles = 1;
    bfm_frame(4'hA, 24'h00000B, 1); bfm_frame(4'h5, 24'h000004, 1, -1, -1, 0, 0, 5, -1, 7); bfm_end();
    check_ev("6 us tick");
    cfg_rx_nibbles = 6;
    cfg_rx_tick_clks = 8; bfm_tk = 8;

    // 4. receiver errors
    $display("[%0t] section 4: receiver errors", $time);
    bfm_frame(0, 24'h111111, 6, -1, 3, 11); bfm_frame(1, 24'h222222, 6); bfm_end(); check_ev("nibble 11 ticks");
    bfm_frame(0, 24'h111111, 6, -1, 0, 28); bfm_frame(1, 24'h222222, 6); bfm_end(); check_ev("status 28 ticks");
    bfm_frame(0, 24'h111111, 6, -1, 7, 40); bfm_frame(1, 24'h222222, 6); bfm_end(); check_ev("CRC 40 ticks");
    bfm_frame(0, 24'h333333, 6, -1, 4, 56); bfm_frame(1, 24'h222222, 6); bfm_end(); check_ev("sync in a frame");
    bfm_frame(0, 24'h333333, 6, -1, -1, 0, 0, 5, 2); bfm_frame(2, 24'h444444, 6); bfm_end(); check_ev("short low");
    bfm_frame(0, 24'h555555, 6, 4'hF); bfm_frame(3, 24'h666666, 6); bfm_end(); check_ev("bad CRC");
    bfm_frame(0, 24'h777777, 6); bfm_pulse(20, 5); bfm_frame(4, 24'h888888, 6); bfm_end(); check_ev("no sync");
    // pauses
    cfg_rx_pause = 1;
    bfm_frame(0, 24'h123456, 6, -1, -1, 0, 12); bfm_frame(1, 24'h654321, 6, -1, -1, 0, 768); bfm_frame(2, 24'h0, 6, -1, -1, 0, 100);
    bfm_end(); check_ev("pauses");
    bfm_frame(0, 24'h123456, 6, -1, -1, 0, 11); bfm_frame(1, 24'h654321, 6, -1, -1, 0, 50); bfm_end(); check_ev("pause 11");
    bfm_frame(0, 24'h123456, 6, -1, -1, 0, 769); bfm_frame(1, 24'h654321, 6, -1, -1, 0, 50); bfm_end(); check_ev("pause 769");
    bfm_frame(0, 24'h123456, 6, -1, -1, 0, 1100); bfm_frame(1, 24'h654321, 6, -1, -1, 0, 50); bfm_end(); check_ev("pause 1100");
    bfm_frame(0, 24'h123456, 6, -1, -1, 0, 100, 5, 8); bfm_frame(1, 24'h654321, 6, -1, -1, 0, 50); bfm_end(); check_ev("pause low");
    cfg_rx_pause = 0;
    // successive calibration pulses: 1/64 limit
    cfg_rx_cal_check = 1;
    bfm_tk = 64; cfg_rx_tick_clks = 64;
    bfm_frame(1, 24'h1, 6); bfm_tk = 65; bfm_frame(2, 24'h2, 6); bfm_tk = 67; bfm_frame(3, 24'h3, 6);
    bfm_frame(4, 24'h4, 6); bfm_end(); check_ev("calibration drift");
    cfg_rx_cal_check = 0;
    bfm_tk = 64; bfm_frame(1, 24'h1, 6); bfm_tk = 67; bfm_frame(3, 24'h3, 6); bfm_end(); check_ev("drift unchecked");
    bfm_tk = 8; cfg_rx_tick_clks = 8;
    // glitches shorter than the filter, then a filter of 0
    cfg_rx_filt = 3;
    fork
      begin bfm_frame(4'h9, 24'hABCDEF, 6); bfm_end(); end
      begin
        cyc(100); mon_off = 1; #1 bfm_line = 0; #20 bfm_line = 1;   // in a high part: 2 clocks
        cyc(3); mon_off = 0;
      end
    join
    check_ev("glitch");
    cfg_rx_filt = 0;
    bfm_frame(4'h9, 24'hABCDEF, 6); bfm_end(); check_ev("no filter");
    cfg_rx_filt = 15;
    bfm_frame(4'h3, 24'h13579B, 6); bfm_end(); check_ev("filter 15");
    cfg_rx_filt = 1;

    // 5. serial messages from the BFM: good, bad CRC, broken by an error
    $display("[%0t] section 5: serial receive", $time);
    begin
      logic [17:0] b3, b2;
      int len;
      for (int i = 0; i < 6; i++) begin
        ser_bits(i % 3 != 0, i % 3 == 2, 8'($urandom), 16'($urandom), b3, b2, len);
        if (i == 4) b2[17] = !b2[17];                        // enhanced CRC wrong
        if (i == 3) b2[4] = !b2[4];                          // short CRC wrong
        for (int f = 0; f < len; f++) begin
          bfm_frame({b3[17 - f], b2[17 - f], 2'($urandom)}, 24'($urandom), 6, i == 5 && f == 9 ? 0 : -1);
        end
        for (int f = 0; f < 2; f++) bfm_frame(4'b0000, 24'($urandom), 6);
      end
      bfm_end();
      check_ev("serial receive");
      // bit 3 pattern broken: frame 7 of an enhanced message with bit 3 = 1
      ser_bits(1, 0, 8'h5A, 16'h0A5A, b3, b2, len);
      b3[11] = 1;
      for (int f = 0; f < 18; f++) bfm_frame({b3[17 - f], b2[17 - f], 2'b00}, 24'h0, 6);
      bfm_end();
      check_ev("enhanced pattern");
    end

    // 7. the longest tick, 4095 clocks, both ways; a calibration pulse of 4700-clock
    //    ticks (the largest one); low parts above the low counter; a pause past
    //    1024 ticks (the period counter saturates)
    $display("[%0t] section 7: long ticks", $time);
    use_bfm = 0; cfg_tx_tick_clks = 4095; cfg_rx_tick_clks = 4095; cfg_tx_nibbles = 1; cfg_rx_nibbles = 1;
    tx_en = 1; tx_frames(1); tx_stop();
    check_ev("tick 4095");
    use_bfm = 1; cyc(5);
    bfm_tk = 4700; bfm_end();                               // ends the transmitter's last CRC nibble
    check_ev("tick 4095, last frame");
    cfg_rx_pause = 1;
    bfm_frame(4'h5, 24'h00000A, 1, -1, -1, 0, 1100, 10);
    bfm_frame(4'h6, 24'h000003, 1, -1, -1, 0, 150);         // 705000-clock period
    bfm_end();
    check_ev("tick 4700, pause 1100 and 150");
    cfg_rx_pause = 0; bfm_tk = 8; cfg_rx_tick_clks = 8; cfg_tx_tick_clks = 8; cfg_tx_nibbles = 6; cfg_rx_nibbles = 6;
    bfm_frame(4'h1, 24'h0, 6); bfm_frame(4'h2, 24'hFFFFFF, 6); bfm_end();
    check_ev("tick 8 again");
    // a pause just under 1024 ticks: the rounded quotient is 1024 (11 bits plus carry)
    cfg_rx_pause = 1;
    bfm_frame(4'h3, 24'h123456, 6); bfm_pulse(1023, 5, 6); bfm_end();
    check_ev("pause of 1023.75 ticks");
    cfg_rx_pause = 0;

    // 6. reset in the middle of a frame (transmitter and receiver)
    $display("[%0t] section 6: reset", $time);
    use_bfm = 0; tx_en = 1;
    tx_frames(1);
    cyc(200);
    rst_n = 0; cyc(3);
    if (sent_out !== 1 || ser_tx_busy || {tx_frame_start, ser_tx_done, rx_valid, rx_err_nibble, rx_err_low, rx_err_crc,
        rx_err_pause, rx_err_sync, rx_err_cal, ser_rx_valid, ser_rx_err_crc} !== '0) fail("reset values");
    tx_en = 0; tq_h = tq_t; t_last = -1; m_reset(); ml_prev = 1;
    rst_n = 1;
    tx_en = 1; tx_frames(3); tx_stop();
    check_ev("after reset");
    // a reset with the line high must not look like a falling edge: a frame whose
    // calibration pulse starts one calibration period after it is the first frame
    use_bfm = 1; cfg_rx_filt = 0; cyc(20);
    rst_n = 0; cyc(3); m_reset(); ml_prev = 1; rst_n = 1;
    cyc(56 * 8 - 3);
    bfm_frame(4'h9, 24'h13579B, 6); bfm_end();
    check_ev("first frame after reset");

    $display("frames: tx %0d, rx %0d, pulses %0d, serial tx %0d rx %0d; errors seen: nib %0d low %0d crc %0d pause %0d sync %0d cal %0d ser %0d",
             n_frames, n_ev[1], n_pulses, n_ser_done, n_ev[8], n_ev[2], n_ev[3], n_ev[4], n_ev[5], n_ev[6], n_ev[7], n_ev[9]);
    if (errors == 0) $display("TEST PASSED: SENT");
    else $display("TEST FAILED: SENT (%0d errors)", errors);
    $finish;
  end
  initial begin
    #500ms;
    $display("TEST FAILED: SENT (timeout)");
    $finish;
  end
endmodule
