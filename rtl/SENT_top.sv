// SPDX-License-Identifier: Apache-2.0
// ============================================================================
// SENT_top v1.0: SAE J2716 SENT (Single Edge Nibble Transmission) transmitter
// and receiver, with the slow serial channel
// ----------------------------------------------------------------------------
//  - Line coding: every pulse starts with a falling edge, stays low for at
//    least 4 ticks and high for the rest; the time between two falling
//    edges carries the symbol. A frame is a 56-tick calibration (sync)
//    pulse, the status & communication nibble, 1..6 data nibbles and the
//    CRC nibble (each nibble 12 + value ticks, 12..27), optionally followed
//    by a pause pulse (12..768 ticks).
//  - CRC: 4 bits, x^4 + x^3 + x^2 + 1, seed 0101, over the data nibbles
//    (not the status nibble); the recommended form appends a zero nibble,
//    cfg_crc_legacy = 1 leaves it out (pre-2010 sensors).
//  - Slow serial channel in bits 3:2 of the status nibble:
//      * short message: 16 frames, bit 3 = 1 0 0 .. 0, bit 2 = 4-bit ID,
//        8-bit data and a 4-bit CRC of ID and data (same CRC and form as
//        the fast channel);
//      * enhanced message: 18 frames, bit 3 = 1 1 1 1 1 1 0 C a3..a0 0
//        b3..b0 0, bit 2 = a 6-bit CRC (frames 1..6) then 12 data bits
//        (frames 7..18), all MSB first; C = 0: 8-bit ID {a, b} and 12-bit
//        data, C = 1: 4-bit ID a and 16-bit data {b, 12 bits}. The CRC
//        (x^6 + x^4 + x^3 + 1, seed 010101, a zero 6-bit word appended)
//        covers bit 2 then bit 3 of frames 7..18.
//  - Transmitter (sensor side): tick = cfg_tx_tick_clks clocks, low part
//    cfg_tx_low_ticks; frames back to back while tx_en. tx_status /
//    tx_data are taken at tx_frame_start (the sync pulse's falling edge);
//    data nibble i is tx_data[4i+3:4i]. Pause: cfg_tx_pause_mode 0 none,
//    1 a pause of cfg_tx_pause ticks, 2 a constant frame of cfg_tx_pause
//    ticks (the pause fills it up, at least 12 ticks). ser_tx_start sends
//    a serial message from the next frame on; it owns status bits 3:2 for
//    16 / 18 frames (ser_tx_busy, then ser_tx_done).
//  - Receiver (ECU side): sent_in is synchronised and glitch filtered
//    (stable for cfg_rx_filt clocks). Any period within +-25 % of 56
//    nominal ticks (cfg_rx_tick_clks) is a calibration pulse and sets the
//    tick; every other period is rounded to whole ticks of that pulse.
//    A frame with valid nibbles, low parts >= 4 ticks and the right CRC
//    gives rx_valid (data nibbles past cfg_rx_nibbles read 0); errors
//    pulse rx_err_* and the receiver hunts for the
//    next calibration pulse. cfg_rx_pause: a pause pulse must follow the
//    CRC nibble. cfg_rx_cal_check: a calibration pulse that differs from
//    the one before by more than 1/64 drops its frame (rx_err_cal). The
//    serial decoder checks the last 16 / 18 good frames after every frame
//    (ser_rx_valid / ser_rx_err_crc); a bad frame restarts it.
//  Limits: cfg_*_tick_clks 4..4095 clocks (a period counter of 22 bits
//  saturates, so longer idle times read as one long period).
//  Not implemented: SPC (short PWM code) master triggers, the J2716 APR
//  2016 tick-time variants beyond the configurable tick, and the fast
//  channel message formats (H.1..H.7) which are only data interpretations.
// ============================================================================
module SENT_top (
  input  logic        clk,
  input  logic        rst_n,
  input  logic        cfg_crc_legacy,
  // ---- transmitter
  input  logic        tx_en,
  input  logic [11:0] cfg_tx_tick_clks,
  input  logic [3:0]  cfg_tx_low_ticks,   // 4..11 (other values are clamped)
  input  logic [2:0]  cfg_tx_nibbles,     // 1..6 data nibbles (0 = 1, 7 = 6)
  input  logic [1:0]  cfg_tx_pause_mode,
  input  logic [10:0] cfg_tx_pause,
  input  logic [3:0]  tx_status,
  input  logic [23:0] tx_data,
  output logic        tx_frame_start,
  output logic        sent_out,
  input  logic        ser_tx_start,
  input  logic        ser_tx_enh,
  input  logic        ser_tx_cfg,
  input  logic [7:0]  ser_tx_id,
  input  logic [15:0] ser_tx_data,
  output logic        ser_tx_busy,
  output logic        ser_tx_done,
  // ---- receiver
  input  logic        sent_in,
  input  logic [11:0] cfg_rx_tick_clks,
  input  logic [2:0]  cfg_rx_nibbles,
  input  logic        cfg_rx_pause,
  input  logic        cfg_rx_cal_check,
  input  logic [3:0]  cfg_rx_filt,
  output logic        rx_valid,
  output logic [3:0]  rx_status,
  output logic [23:0] rx_data,
  output logic [18:0] rx_cal_clks,        // calibration pulse of the last frame, in clocks
  output logic        rx_err_nibble,      // a period that is no nibble (and no calibration pulse)
  output logic        rx_err_low,         // a low part shorter than 4 ticks
  output logic        rx_err_crc,
  output logic        rx_err_pause,       // a pause outside 12..768 ticks
  output logic        rx_err_sync,        // no calibration pulse where one was due
  output logic        rx_err_cal,         // calibration pulse more than 1/64 off the previous one
  output logic        ser_rx_valid,
  output logic        ser_rx_enh,
  output logic        ser_rx_cfg,
  output logic [7:0]  ser_rx_id,
  output logic [15:0] ser_rx_data,
  output logic        ser_rx_err_crc
);
  // CRC remainder after feeding bit b (MSB first) into r
  function automatic logic [3:0] crc4_bit(input logic [3:0] r, input logic b);
    crc4_bit = {r[2:0], b} ^ (r[3] ? 4'hD : 4'h0);
  endfunction
  function automatic logic [5:0] crc6_bit(input logic [5:0] r, input logic b);
    crc6_bit = {r[4:0], b} ^ (r[5] ? 6'h19 : 6'h0);
  endfunction
  // fast channel CRC of n nibbles of d (nibble 0 first)
  function automatic logic [3:0] crc_fast(input logic [23:0] d, input logic [2:0] n, input logic legacy);
    logic [3:0] r;
    r = 4'h5;
    for (int i = 0; i < 6; i++)
      if (i < n) for (int k = 3; k >= 0; k--) r = crc4_bit(r, d[4 * i + k]);
    if (!legacy) for (int k = 0; k < 4; k++) r = crc4_bit(r, 1'b0);
    crc_fast = r;
  endfunction
  // short serial message CRC of {id, data}
  function automatic logic [3:0] crc_short(input logic [11:0] m, input logic legacy);
    logic [3:0] r;
    r = 4'h5;
    for (int k = 11; k >= 0; k--) r = crc4_bit(r, m[k]);
    if (!legacy) for (int k = 0; k < 4; k++) r = crc4_bit(r, 1'b0);
    crc_short = r;
  endfunction
  // enhanced serial message CRC of {bit 2, bit 3} of frames 7..18
  function automatic logic [5:0] crc_enh(input logic [11:0] b2, input logic [11:0] b3);
    logic [5:0] r;
    r = 6'h15;
    for (int k = 11; k >= 0; k--) begin r = crc6_bit(r, b2[k]); r = crc6_bit(r, b3[k]); end
    for (int k = 0; k < 6; k++) r = crc6_bit(r, 1'b0);
    crc_enh = r;
  endfunction
  function automatic logic [2:0] nib_n(input logic [2:0] c);
    nib_n = c == 3'd0 ? 3'd1 : c == 3'd7 ? 3'd6 : c;
  endfunction

  // =========================================================================
  // transmitter
  // =========================================================================
  typedef enum logic [2:0] {T_IDLE, T_SYNC, T_STATUS, T_DATA, T_CRC, T_PAUSE} tst_t;
  tst_t        tst;
  logic [11:0] tclk;             // clocks into the tick
  logic [9:0]  tick;             // ticks into the pulse
  logic [9:0]  tlen;             // ticks of the pulse
  logic [2:0]  tni;              // data nibble index
  logic [8:0]  tsum;             // ticks of the frame so far (at most 56 + 8 x 27)
  logic [3:0]  t_st;
  logic [23:0] t_d;
  logic [2:0]  t_n;
  logic [3:0]  t_crc;
  // serial message transmitter: bits 3:2 for frames 0..17
  logic [17:1] s_b3;
  logic [17:0] s_b2;
  logic [4:0]  s_left;           // frames still to send
  wire  [3:0]  low_t = cfg_tx_low_ticks < 4'd4 ? 4'd4 : cfg_tx_low_ticks > 4'd11 ? 4'd11 : cfg_tx_low_ticks;
  wire         tk_end = tclk == (cfg_tx_tick_clks < 12'd4 ? 12'd3 : cfg_tx_tick_clks - 12'd1);
  wire         p_end  = tk_end && tick == tlen - 10'd1;
  // pause length when the CRC nibble ends
  wire  [10:0] fill   = cfg_tx_pause - {2'b00, tsum};
  wire  [9:0]  pause_t = cfg_tx_pause_mode == 2'd1 ? (cfg_tx_pause < 11'd12 ? 10'd12 : cfg_tx_pause > 11'd768 ? 10'd768 : 10'(cfg_tx_pause))
                       : (cfg_tx_pause <= {2'b00, tsum} + 11'd12 ? 10'd12 : fill > 11'd768 ? 10'd768 : 10'(fill));
  // serial message bits, first frame in the MSB: bit 3 (frames 1..17; frame 18 sends 0) and bit 2
  function automatic logic [17:1] ser_b3(input logic enh, input logic cf, input logic [7:0] id, input logic [15:0] d);
    ser_b3 = enh ? {6'b111111, 1'b0, cf, cf ? id[3:0] : id[7:4], 1'b0, cf ? d[15:12] : id[3:0]} : {1'b1, 16'd0};
  endfunction
  function automatic logic [17:0] ser_b2(input logic enh, input logic cf, input logic [7:0] id, input logic [15:0] d,
                                         input logic legacy);
    logic [17:0] b3;
    b3 = {ser_b3(enh, cf, id, d), 1'b0};
    ser_b2 = enh ? {crc_enh(d[11:0], b3[11:0]), d[11:0]}
                 : {id[3:0], d[7:0], crc_short({id[3:0], d[7:0]}, legacy), 2'b00};
  endfunction

  // a new frame starts: from idle, after the pause, or after the CRC nibble without one
  wire nxt = tst == T_IDLE || (p_end && (tst == T_PAUSE || (tst == T_CRC && cfg_tx_pause_mode == 2'd0)));
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      tst <= T_IDLE; tclk <= '0; tick <= '0; tlen <= '0; tni <= '0; tsum <= '0;
      t_st <= '0; t_d <= '0; t_n <= 3'd1; t_crc <= '0; sent_out <= 1'b1; tx_frame_start <= 1'b0;
      s_b3 <= '0; s_b2 <= '0; s_left <= '0; ser_tx_busy <= 1'b0; ser_tx_done <= 1'b0;
    end else begin
      tx_frame_start <= 1'b0; ser_tx_done <= 1'b0;
      if (ser_tx_start && !ser_tx_busy) begin
        ser_tx_busy <= 1'b1; s_left <= ser_tx_enh ? 5'd18 : 5'd16;
        s_b3 <= ser_b3(ser_tx_enh, ser_tx_cfg, ser_tx_id, ser_tx_data);
        s_b2 <= ser_b2(ser_tx_enh, ser_tx_cfg, ser_tx_id, ser_tx_data, cfg_crc_legacy);
      end
      if (tst != T_IDLE) begin
        tclk <= tk_end ? 12'd0 : tclk + 12'd1;
        if (tk_end) tick <= tick + 10'd1;
        if (tk_end && tick == 10'(low_t) - 10'd1) sent_out <= 1'b1;   // end of the low part
      end
      if (nxt) begin
        tclk <= '0; tick <= '0;
        if (tx_en) begin
          logic [3:0] st;
          st = tx_status;
          if (s_left != 5'd0) begin                                 // serial message bits
            st[3:2] = {s_b3[17], s_b2[17]};
            s_b3 <= {s_b3[16:1], 1'b0}; s_b2 <= {s_b2[16:0], 1'b0}; s_left <= s_left - 5'd1;
            if (s_left == 5'd1) begin ser_tx_busy <= 1'b0; ser_tx_done <= 1'b1; end
          end
          tst <= T_SYNC; tlen <= 10'd56; sent_out <= 1'b0; tx_frame_start <= 1'b1; tsum <= 9'd56;
          t_st <= st; t_d <= tx_data; t_n <= nib_n(cfg_tx_nibbles);
          t_crc <= crc_fast(tx_data, nib_n(cfg_tx_nibbles), cfg_crc_legacy);
        end else begin
          tst <= T_IDLE; sent_out <= 1'b1;
        end
      end else if (p_end) begin
        tclk <= '0; tick <= '0; sent_out <= 1'b0;
        case (tst)
          T_SYNC: begin
            tst <= T_STATUS; tlen <= 10'd12 + 10'(t_st); tsum <= tsum + 9'd12 + 9'(t_st);
          end
          T_STATUS: begin
            tst <= T_DATA; tni <= '0;
            tlen <= 10'd12 + 10'(t_d[3:0]); tsum <= tsum + 9'd12 + 9'(t_d[3:0]);
          end
          T_DATA: begin
            if (tni == t_n - 3'd1) begin
              tst <= T_CRC; tlen <= 10'd12 + 10'(t_crc); tsum <= tsum + 9'd12 + 9'(t_crc);
            end else begin
              tni <= tni + 3'd1;
              tlen <= 10'd12 + 10'(t_d[4 * (tni + 3'd1) +: 4]); tsum <= tsum + 9'd12 + 9'(t_d[4 * (tni + 3'd1) +: 4]);
            end
          end
          T_CRC: begin tst <= T_PAUSE; tlen <= pause_t; end      // with a pause
        endcase
      end
    end
  end

  // =========================================================================
  // receiver
  // =========================================================================
  // synchroniser and glitch filter
  logic       s1, s2, lv;
  logic [3:0] fcnt;
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      s1 <= 1'b1; s2 <= 1'b1; lv <= 1'b1; fcnt <= '0;
    end else begin
      s1 <= sent_in; s2 <= s1;
      if (s2 == lv) fcnt <= '0;
      else if (fcnt >= cfg_rx_filt) begin lv <= s2; fcnt <= '0; end
      else fcnt <= fcnt + 4'd1;
    end
  end
  wire fall = lv && !s2 && fcnt >= cfg_rx_filt;
  wire rise = !lv && s2 && fcnt >= cfg_rx_filt;

  typedef enum logic [2:0] {R_HUNT, R_STATUS, R_DATA, R_CRC, R_PAUSE, R_SYNC} rst_t;
  rst_t        rst;
  logic [21:0] per;              // clocks since the last falling edge (saturates)
  logic [14:0] low, low_q;       // low part of the pulse (saturates above 3.5 ticks)
  logic        seen;             // a falling edge was seen since reset
  logic [18:0] cal, cal_prev;    // a calibration pulse is at most 70 x 4095 clocks
  logic        cal_prev_ok;
  logic [2:0]  rni;
  logic [3:0]  r_st;
  logic [23:0] r_d;
  // divider: q2 = floor(112 P / cal) for the period just ended; round(56 P / cal) = (q2 + 1) / 2
  logic        dv_busy, dv_done;
  logic [3:0]  dv_k;
  logic [28:0] dv_rem;
  logic [10:0] dv_q;
  logic        dv_ovf;           // 112 P >= 2048 cal: 1024 ticks or more
  logic [14:0] dv_low;
  logic        r_drop;           // the frame's calibration pulse failed the drift check
  wire  [29:0] dv_den = {11'd0, cal} << dv_k;                // cal 2^k
  // calibration window: 0.75 * 56 * T <= P <= 1.25 * 56 * T
  wire         is_cal = {per, 2'b00} >= 24'(cfg_rx_tick_clks) * 24'd168 && {per, 2'b00} <= 24'(cfg_rx_tick_clks) * 24'd280;
  // the drift check: |cal - cal_prev| * 64 <= cal_prev
  wire         drift = cfg_rx_cal_check && cal_prev_ok &&
                       {(per > {3'd0, cal_prev} ? per - {3'd0, cal_prev} : {3'd0, cal_prev} - per), 6'd0} > {9'd0, cal_prev};
  // serial decoder history (index 0 = newest frame)
  logic [17:0] h_b3, h_b2;
  logic [4:0]  h_n;
  // decision on the divided period
  wire  [11:0] q2p1 = {1'b0, dv_q} + 12'd1;
  wire  [10:0] q    = dv_ovf ? 11'h7FF : q2p1[11:1];
  wire         nib_ok = q >= 11'd12 && q <= 11'd27;
  wire         low_ok = {dv_low, 4'd0} >= cal;                     // L >= 3.5 ticks (16 L >= cal)
  wire  [3:0]  nv   = 4'(q - 11'd12);
  wire  [2:0]  r_n  = nib_n(cfg_rx_nibbles);

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      rst <= R_HUNT; per <= '0; low <= '0; low_q <= '0; seen <= 1'b0; cal <= '0; cal_prev <= '0;
      cal_prev_ok <= 1'b0; r_drop <= 1'b0; rni <= '0; r_st <= '0; r_d <= '0;
      dv_busy <= 1'b0; dv_done <= 1'b0; dv_k <= '0; dv_rem <= '0; dv_q <= '0; dv_ovf <= 1'b0; dv_low <= '0;
      rx_valid <= 1'b0; rx_status <= '0; rx_data <= '0; rx_cal_clks <= '0;
      rx_err_nibble <= 1'b0; rx_err_low <= 1'b0; rx_err_crc <= 1'b0; rx_err_pause <= 1'b0;
      rx_err_sync <= 1'b0; rx_err_cal <= 1'b0;
      h_b3 <= '0; h_b2 <= '0; h_n <= '0;
      ser_rx_valid <= 1'b0; ser_rx_enh <= 1'b0; ser_rx_cfg <= 1'b0; ser_rx_id <= '0; ser_rx_data <= '0;
      ser_rx_err_crc <= 1'b0;
    end else begin
      logic bad_frame, good_frame;
      bad_frame = 1'b0; good_frame = 1'b0;
      rx_valid <= 1'b0; rx_err_nibble <= 1'b0; rx_err_low <= 1'b0; rx_err_crc <= 1'b0;
      rx_err_pause <= 1'b0; rx_err_sync <= 1'b0; rx_err_cal <= 1'b0;
      ser_rx_valid <= 1'b0; ser_rx_err_crc <= 1'b0;
      dv_done <= 1'b0;
      if (per != '1) per <= per + 22'd1;
      if (!lv && low != '1) low <= low + 15'd1;
      if (rise) low_q <= low;
      // ---- a falling edge ends a period
      if (fall) begin
        per <= 22'd1; low <= '0; seen <= 1'b1;
        if (seen) begin
          if ((rst == R_HUNT || rst == R_SYNC || rst == R_STATUS || rst == R_DATA || rst == R_CRC) && is_cal) begin
            // a calibration pulse: a new frame (cutting short the one being received)
            if (rst == R_STATUS || rst == R_DATA || rst == R_CRC) begin rx_err_nibble <= 1'b1; bad_frame = 1'b1; end
            cal <= 19'(per); cal_prev <= 19'(per); rst <= R_STATUS; rni <= '0; r_d <= '0;
            r_drop <= drift && rst == R_SYNC;
            if (drift && rst == R_SYNC) begin rx_err_cal <= 1'b1; bad_frame = 1'b1; end
            cal_prev_ok <= 1'b1;
          end else if (rst == R_SYNC) begin
            rx_err_sync <= 1'b1; rst <= R_HUNT; cal_prev_ok <= 1'b0; bad_frame = 1'b1;
          end else if (rst != R_HUNT) begin
            // a nibble or the pause: round(56 P / cal) in the divider
            dv_busy <= 1'b1; dv_k <= 4'd11; dv_q <= '0; dv_ovf <= 1'b0; dv_low <= low_q;
            dv_rem <= {per, 7'd0} - {3'd0, per, 4'd0};                       // 112 P
          end
        end
      end
      // ---- divider, one quotient bit per clock (a period is at least 36 clocks)
      if (dv_busy) begin
        if (dv_k == 4'd11) begin
          if (dv_rem >= dv_den) begin dv_ovf <= 1'b1; dv_busy <= 1'b0; dv_done <= 1'b1; end
          else dv_k <= 4'd10;
        end else begin
          if (dv_rem >= dv_den) begin dv_rem <= dv_rem - dv_den; dv_q[dv_k] <= 1'b1; end
          if (dv_k == 4'd0) begin dv_busy <= 1'b0; dv_done <= 1'b1; end
          else dv_k <= dv_k - 4'd1;
        end
      end
      // ---- a divided symbol
      if (dv_done && rst != R_PAUSE && (!nib_ok || !low_ok)) begin
        if (!nib_ok) rx_err_nibble <= 1'b1; else rx_err_low <= 1'b1;
        rst <= R_HUNT; cal_prev_ok <= 1'b0; bad_frame = 1'b1;
      end else if (dv_done) begin
        case (rst)
          R_STATUS: begin r_st <= nv; rst <= R_DATA; rni <= '0; end
          R_DATA: begin
            r_d[4 * rni +: 4] <= nv;
            if (rni == r_n - 3'd1) rst <= R_CRC; else rni <= rni + 3'd1;
          end
          R_CRC: begin
            rst <= cfg_rx_pause ? R_PAUSE : R_SYNC;
            if (r_drop) bad_frame = 1'b1;                          // rx_err_cal was given
            else if (nv == crc_fast(r_d, r_n, cfg_crc_legacy)) begin
              rx_valid <= 1'b1; rx_status <= r_st; rx_data <= r_d; rx_cal_clks <= cal; good_frame = 1'b1;
            end else begin
              rx_err_crc <= 1'b1; bad_frame = 1'b1;
            end
          end
          R_PAUSE: begin
            if (q < 11'd12 || q > 11'd768 || !low_ok) begin
              rx_err_pause <= 1'b1; rst <= R_HUNT; cal_prev_ok <= 1'b0;
            end else rst <= R_SYNC;
          end
        endcase
      end
      // ---- serial channel: shift in the frame, look for a message
      if (bad_frame) h_n <= '0;
      else if (good_frame) begin
        logic [17:0] b3, b2;
        logic [4:0]  n;
        b3 = {h_b3[16:0], r_st[3]}; b2 = {h_b2[16:0], r_st[2]};
        n  = h_n == 5'd18 ? 5'd18 : h_n + 5'd1;
        h_b3 <= b3; h_b2 <= b2; h_n <= n;
        if (n == 5'd18 && b3[17:12] == 6'b111111 && !b3[11] && !b3[5] && !b3[0]) begin
          if (b2[17:12] == crc_enh(b2[11:0], b3[11:0])) begin
            ser_rx_valid <= 1'b1; ser_rx_enh <= 1'b1; ser_rx_cfg <= b3[10];
            ser_rx_id   <= b3[10] ? {4'd0, b3[9:6]} : {b3[9:6], b3[4:1]};
            ser_rx_data <= b3[10] ? {b3[4:1], b2[11:0]} : {4'd0, b2[11:0]};
          end else ser_rx_err_crc <= 1'b1;
          h_n <= '0;
        end else if (n >= 5'd16 && b3[15:0] == 16'h8000) begin
          if (b2[3:0] == crc_short(b2[15:4], cfg_crc_legacy)) begin
            ser_rx_valid <= 1'b1; ser_rx_enh <= 1'b0; ser_rx_cfg <= 1'b0;
            ser_rx_id <= {4'd0, b2[15:12]}; ser_rx_data <= {8'd0, b2[11:4]};
          end else ser_rx_err_crc <= 1'b1;
          h_n <= '0;
        end
      end
    end
  end
endmodule
