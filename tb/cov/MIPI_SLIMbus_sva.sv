// SPDX-License-Identifier: Apache-2.0
// SLIMbus framer / device: concurrent SVA against an independent reference
// model, plus functional coverage.
//  * CLK: the framer's divider, or the device's two-flop synchroniser;
//    edges act one clock after they are seen.
//  * Rising edge: the next cell's owner (frame sync, FI, the transmit
//    segment) and its NRZI level from the last sampled level.
//  * Falling edge: the decoded bit feeds the frame-sync hunt / check /
//    lock counters, a 32-bit FI register indexed by frame, and the
//    receive segment.
// Every output is compared on every clock.
`include "cov_macros.svh"
module MIPI_SLIMbus_sva (
  input logic        clk, rst_n, cfg_framer,
  input logic [3:0]  cfg_div,
  input logic [7:0]  cfg_fi,
  input logic        sf_set,
  input logic [15:0] sf_set_val,
  input logic [7:0]  cfg_tx_slot,
  input logic [2:0]  cfg_tx_len,
  input logic [7:0]  cfg_rx_slot,
  input logic [2:0]  cfg_rx_len,
  input logic        cfg_err,
  input logic        slim_clk_o, slim_clk_oe, slim_clk_i, slim_dat_o, slim_dat_oe, slim_dat_i,
  input logic        tx_valid, tx_ready,
  input logic [31:0] tx_data,
  input logic        tx_underrun, rx_valid,
  input logic [31:0] rx_data,
  input logic        rx_err, locked, sf_locked, lost_sync, fi_valid,
  input logic [7:0]  fi_info,
  input logic [15:0] sf_count
);
  `COV_CLOCKING(clk, !rst_n)

  // segment [first, last] slots, or invalid
  function automatic bit seg(input logic [7:0] st, input logic [2:0] len, output int first, output int last);
    first = int'(st); last = int'(st) + 2 * int'(len);
    if (len == 0 || len > 4 || st == 0 || st == 96) return 0;
    if (first < 96) return last < 96;
    return last < 192;
  endfunction

  int          d_cnt, pos, fr, fs_run, fs_miss, no_sf;   // fs_run: frame syncs seen in a row while hunting
  bit          m_clk, cs0, cs1, cq, er, ef, lvl, do_, oe, hunting, checking, lk, sfl;
  bit          m_tr, m_tu, m_rv, m_re, m_lost, m_fv;
  logic [31:0] m_rd, fi_word, fi_next, rcv;
  logic [7:0]  m_fi_info;
  logic [15:0] m_sfc, m_cnt;
  logic [2:0]  last3;
  logic [35:0] t_bits;
  logic [3:0]  r_tag;
  // coverage
  bit          v_check_fail, v_miss_ok, v_sfl_lost, v_wrap, v_tx_len [1:4], v_rx_len [1:4], v_rx_empty;
  bit          v_end96, v_end192, v_loop, v_div15, v_no_sf;

  bit          tx_ok, rx_ok;
  logic [3:0]  fr_prev_nib;                  // the FI nibble before this one
  int  tf, tl, rf, rl;
  always_comb begin tx_ok = seg(cfg_tx_slot, cfg_tx_len, tf, tl); rx_ok = seg(cfg_rx_slot, cfg_rx_len, rf, rl); end

  always @(posedge clk or negedge rst_n)
    if (!rst_n) begin
      d_cnt = 0; pos = 767; fr = 7; fs_run = 0; fs_miss = 0; no_sf = 0;
      {m_clk, cs0, cs1, cq, er, ef, lvl, do_, oe, checking, lk, sfl} = '0; hunting = 1;
      {m_tr, m_tu, m_rv, m_re, m_lost, m_fv} = '0;
      m_rd = 0; fi_word = 0; fi_next = 0; rcv = 0; m_fi_info = 0; m_sfc = 0; m_cnt = 0; last3 = 0;
      t_bits = 0; r_tag = 0; fr_prev_nib = 0;
    end else begin : b_step
      bit c_now, e_r, e_f;
      {m_tr, m_tu, m_rv, m_re, m_lost, m_fv} = '0;
      e_r = er; e_f = ef;
      c_now = cfg_framer ? m_clk : cs1;
      cs1 = cs0; cs0 = slim_clk_i;
      if (cfg_framer) begin
        if (d_cnt > 0) d_cnt--;
        else begin d_cnt = int'(cfg_div); m_clk = !m_clk; if (cfg_div == 15) v_div15 = 1; end
      end else d_cnt = 0;
      er = c_now && !cq; ef = !c_now && cq; cq = c_now;
      if (cfg_framer) begin hunting = 0; checking = 0; lk = 1; sfl = 1; end

      if (e_r) begin : b_rise
        int np, s, c;
        bit own, b;
        np = pos == 767 ? 0 : pos + 1;
        s = np / 4; c = np % 4;
        if (np == 0) begin
          if (fr == 7) begin
            fi_next = {8'h96, cfg_fi, m_sfc};
            if (cfg_framer) begin m_sfc++; if (m_sfc == 0) v_wrap = 1; end
          end
          fr = (fr + 1) % 8;
        end
        own = 0; b = 0;
        if (cfg_framer && s == 0) begin own = 1; b = c != 1; end
        else if (cfg_framer && s == 96) begin own = 1; b = fi_next[31 - 4 * fr - c]; end
        else if (sfl && tx_ok && s >= tf && s <= tl) begin
          own = 1;
          if (s == tf && c == 0) begin
            t_bits = tx_valid ? {4'b1000, tx_data << (32 - 8 * int'(cfg_tx_len))} : 36'd0;
            if (tx_valid) m_tr = 1; else m_tu = 1;
            v_tx_len[cfg_tx_len] = 1;
            if (tl == 95) v_end96 = 1;
            if (tl == 191) v_end192 = 1;
            if (rx_ok && cfg_rx_slot == cfg_tx_slot) v_loop = 1;
          end
          b = t_bits[35]; t_bits = t_bits << 1;
        end
        oe = own;
        if (own) do_ = lvl ^ b;
        pos = np;
      end
      if (sf_set) m_sfc = sf_set_val;

      if (e_f) begin : b_fall
        bit b;
        int s, c;
        bit was_lk, was_sfl, was_hunt, was_chk;
        b = slim_dat_i ^ lvl;
        lvl = slim_dat_i; oe = 0;
        s = pos / 4; c = pos % 4;
        was_lk = lk && !hunting && !checking; was_sfl = sfl; was_hunt = hunting; was_chk = checking;
        // frame sync
        if (was_hunt) begin
          if ({last3, b} == 4'b1011) begin hunting = 0; checking = 1; fs_run = 1; pos = 3; end
        end else if (was_chk) begin
          if (pos == 3) begin
            if ({last3, b} != 4'b1011) begin hunting = 1; checking = 0; v_check_fail = 1; end
            else if (fs_run == 1) fs_run = 2;
            else begin checking = 0; lk = 1; fs_miss = 0; no_sf = 0; end
          end
        end else if (pos == 3 && !cfg_framer) begin
          // two misses in a row, or 16 frames without the superframe
          if (!sfl && no_sf == 15) begin hunting = 1; lk = 0; m_lost = 1; fs_miss = 0; v_no_sf = 1; end
          else if ({last3, b} == 4'b1011) begin if (fs_miss == 1) v_miss_ok = 1; fs_miss = 0; end
          else if (fs_miss == 0) fs_miss = 1;
          else begin hunting = 1; lk = 0; sfl = 0; m_lost = 1; fs_miss = 0; end
          no_sf = was_sfl || hunting ? 0 : no_sf + 1;
        end
        last3 = {last3[1:0], b};
        // framing information: bit (4 * frame + cell) of the word, MSB first
        if (was_lk && s == 96) begin
          fi_word[31 - 4 * fr - c] = b;
          if (c == 3) begin
            if (!was_sfl && !cfg_framer) begin
              if (fr_prev_nib == 4'h9 && {fi_word[31 - 4 * fr -: 3], b} == 4'h6) begin sfl = 1; fr = 1; end
            end else if (fr == 7) begin
              m_fv = 1; m_fi_info = fi_word[23:16]; m_cnt = fi_word[15:0];
            end else if ((fr == 0 && fi_word[31:28] != 4'h9) || (fr == 1 && fi_word[27:24] != 4'h6)) begin
              sfl = 0; v_sfl_lost = 1;
            end
            fr_prev_nib = {fi_word[31 - 4 * fr -: 3], b};
          end
        end
        // receive segment
        if (was_sfl && rx_ok && s >= rf && s <= rl) begin
          if (s == rf) r_tag = {r_tag[2:0], b};
          else rcv = {rcv[30:0], b};
          if (s == rl && c == 3) begin
            v_rx_len[cfg_rx_len] = 1;
            if (r_tag[2:0] != 0) m_re = 1;
            else if (r_tag[3]) begin
              m_rv = 1;
              m_rd = cfg_rx_len == 4 ? rcv : rcv & ((32'd1 << (8 * int'(cfg_rx_len))) - 1);
            end else v_rx_empty = 1;
          end
        end
      end
    end

  function automatic int dcls(input logic [31:0] v, input logic [2:0] len);
    logic [31:0] m;
    m = len >= 4 ? '1 : (32'd1 << (8 * int'(len))) - 1;
    v &= m;
    return v == 0 ? 0 : v == m ? 1 : (v == (32'h5555_5555 & m) || v == (32'hAAAA_AAAA & m)) ? 2 : 3;
  endfunction
  // samples by segment length and data class both ways, frame information
  covergroup cg_slim @(negedge clk);
    option.per_instance = 1;
    cp_tlen: coverpoint cfg_tx_len iff (rst_n && tx_valid && tx_ready) { bins l[] = {[1:4]}; }
    cp_tdata: coverpoint dcls(tx_data, cfg_tx_len) iff (rst_n && tx_valid && tx_ready)
      { bins zero = {0}; bins ones = {1}; bins alt = {2}; bins other = {3}; }
    x_tx: cross cp_tlen, cp_tdata;
    cp_rlen: coverpoint cfg_rx_len iff (rst_n && rx_valid && !rx_err) { bins l[] = {[1:4]}; }
    cp_rdata: coverpoint dcls(rx_data, cfg_rx_len) iff (rst_n && rx_valid && !rx_err)
      { bins zero = {0}; bins ones = {1}; bins alt = {2}; bins other = {3}; }
    x_rx: cross cp_rlen, cp_rdata;
    cp_fi: coverpoint fi_info iff (rst_n && fi_valid) { bins zero = {0}; bins ones = {8'hFF}; bins other = {[1:8'hFE]}; }
  endgroup
  cg_slim u_cg_slim = new;

  // ---------------- assertions ----------------
  `SVA_INV(a_cfg_err, cfg_err == ((cfg_tx_len != 0 && !tx_ok) || (cfg_rx_len != 0 && !rx_ok)))
  `SVA_INV(a_clk_oe, slim_clk_oe == cfg_framer)
  `SVA_IMP(a_clk, cfg_framer, slim_clk_o == m_clk)
  `SVA_INV(a_dat_oe, slim_dat_oe == oe)
  `SVA_IMP(a_dat, oe, slim_dat_o == do_)
  `SVA_INV(a_tx_ready, tx_ready == m_tr)
  `SVA_INV(a_underrun, tx_underrun == m_tu)
  `SVA_INV(a_rx_valid, rx_valid == m_rv)
  `SVA_IMP(a_rx_data, m_rv, rx_data == m_rd)
  `SVA_INV(a_rx_err, rx_err == m_re)
  `SVA_INV(a_locked, locked == lk)
  `SVA_INV(a_sf_locked, sf_locked == sfl)
  `SVA_INV(a_lost, lost_sync == m_lost)
  `SVA_INV(a_fi_valid, fi_valid == m_fv)
  `SVA_INV(a_fi, fi_info == m_fi_info && sf_count == m_cnt)
  `SVA_RST(a_reset, 1'b1, !slim_dat_oe && !locked && !tx_ready && !rx_valid && !fi_valid)

  // ---------------- functional coverage ----------------
  `FC(framer, cfg_framer && fi_valid)
  `FC(device_lock, !cfg_framer && $rose(locked))
  `FC(device_superframe_lock, !cfg_framer && $rose(sf_locked))
  `FC(check_fails, v_check_fail)
  `FC(one_miss_survived, v_miss_ok)
  `FC(lost_sync, lost_sync)
  `FC(no_superframe_relock, v_no_sf)
  `FC(superframe_lock_lost, v_sfl_lost)
  `FC(fi_device, !cfg_framer && fi_valid)
  `FC(count_wraps, v_wrap)
  `FC(count_loaded, cfg_framer && sf_set)
  `FC(slow_clk, v_div15)
  `FC(tx_len_1, v_tx_len[1])
  `FC(tx_len_2, v_tx_len[2])
  `FC(tx_len_3, v_tx_len[3])
  `FC(tx_len_4, v_tx_len[4])
  `FC(rx_len_1, v_rx_len[1])
  `FC(rx_len_2, v_rx_len[2])
  `FC(rx_len_3, v_rx_len[3])
  `FC(rx_len_4, v_rx_len[4])
  `FC(underrun, tx_underrun)
  `FC(rx_tag_reserved, rx_err)
  `FC(rx_not_present, v_rx_empty)
  `FC(segment_ends_at_95, v_end96)
  `FC(segment_ends_at_191, v_end192)
  `FC(loopback, v_loop)
  `FC(bad_slot_0, cfg_tx_len != 0 && cfg_tx_slot == 0)
  `FC(bad_slot_96, cfg_tx_len != 0 && cfg_tx_slot == 96)
  `FC(bad_across_96, cfg_tx_len != 0 && cfg_tx_len <= 4 && cfg_tx_slot != 0 && cfg_tx_slot < 96 && !tx_ok)
  `FC(bad_across_192, cfg_rx_len != 0 && cfg_rx_len <= 4 && cfg_rx_slot > 96 && !rx_ok)
  `FC(bad_length, cfg_tx_len > 4)
  `FC_RST(reset_locked, rst_n && locked ##1 !rst_n)
endmodule

bind MIPI_SLIMbus_top MIPI_SLIMbus_sva u_sva (.*);
