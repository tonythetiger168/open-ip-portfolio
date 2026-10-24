// SPDX-License-Identifier: Apache-2.0
// Interlaken lane: concurrent SVA against an independent reference model,
// plus functional coverage.
//  * Transmitter: 67-clock words from reset, metaframe position, burst
//    state. At each word start the model picks the word from the inputs,
//    builds its 67 line bits (its own bit-serial scrambler, CRC-32C,
//    CRC-24 and disparity count) and the line must carry them.
//  * Receiver: own bit slide / test / lock / window counters, sync word
//    count, own descrambler loaded from the scrambler state words while
//    testing, CRC-32C
//    of the metaframe, CRC-24 and burst / packet state, the held word.
// Every output is compared on every clock.
`include "cov_macros.svh"
module Interlaken_v1_2_sva #(
  parameter int          MF   = 64,
  parameter int          BMAX = 8,
  parameter logic [57:0] SEED = 0
)(
  input logic        clk, rst_n, tx_p, rx_p,
  input logic        tx_valid, tx_ready,
  input logic [63:0] tx_data,
  input logic        tx_sop, tx_eop,
  input logic [2:0]  tx_bytes,
  input logic [7:0]  tx_chan,
  input logic [15:0] tx_fc,
  input logic        rx_valid,
  input logic [63:0] rx_data,
  input logic        rx_sop, rx_eop,
  input logic [2:0]  rx_bytes,
  input logic [7:0]  rx_chan,
  input logic        rx_err,
  input logic [15:0] rx_fc,
  input logic        word_lock, sync_lock,
  input logic [1:0]  peer_status,
  input logic        err_word, err_sync, err_scr, err_crc32, err_crc24, err_proto
);
  `COV_CLOCKING(clk, !rst_n)
  localparam logic [63:0] SYNC = 64'h78F6_78F6_78F6_78F6;
  localparam logic [63:0] SKIP = 64'h1E1E_1E1E_1E1E_1E1E;

  // one generator step: the sequence bit
  function automatic bit g_step(ref bit g [0:57]);
    bit k;
    k = g[0] ^ g[19];                   // g[0] = x^58 tap (oldest), g[19] = x^39 tap
    for (int i = 0; i < 57; i++) g[i] = g[i + 1];
    g[57] = k;
    return k;
  endfunction
  function automatic logic [57:0] g_vec(ref bit g [0:57]);
    for (int i = 0; i < 58; i++) g_vec[57 - i] = g[i];
  endfunction
  function automatic void g_load(ref bit g [0:57], input logic [57:0] v);
    for (int i = 0; i < 58; i++) g[i] = v[57 - i];
  endfunction
  function automatic logic [31:0] c32_bit(input logic [31:0] c, input bit b);
    bit fb;
    fb = c[31] ^ b;
    c = c << 1;
    if (fb) c ^= 32'h1EDC_6F41;
    return c;
  endfunction
  function automatic logic [23:0] c24_bit(input logic [23:0] c, input bit b);
    bit fb;
    fb = c[23] ^ b;
    c = c << 1;
    if (fb) c ^= 24'h32_8B63;
    return c;
  endfunction
  function automatic logic [31:0] c32_word(input logic [31:0] c, input logic [1:0] f, input logic [63:0] p);
    c = c32_bit(c32_bit(c, f[1]), f[0]);
    for (int i = 63; i >= 0; i--) c = c32_bit(c, p[i]);
    return c;
  endfunction
  function automatic logic [23:0] c24_word(input logic [23:0] c, input logic [63:0] p);
    for (int i = 63; i >= 0; i--) c = c24_bit(c, p[i]);
    return c;
  endfunction

  // ---------------- transmitter model ----------------
  int          t_k, t_w, t_rd, t_bc, t_chk;     // t_chk: the word bit on tx_p now
  bit          t_g [0:57];
  bit          t_inb, t_eop;
  logic [2:0]  t_eb;
  logic [31:0] t_c32;
  logic [23:0] t_c24;
  bit          t_line [0:66];                   // [0] first on the line
  bit          m_ready;
  // ---------------- receiver model ----------------
  bit          r_q, r_inv, r_f1, r_f0;
  int          r_k, r_ws, r_vc, r_wc, r_ic;     // r_ws: 0 hunt, 1 test, 2 lock
  int          r_ms, r_pos, r_sc, r_miss, r_sm; // r_ms: 0 hunt, 1 test, 2 lock
  logic [63:0] r_pay;
  bit          r_g [0:57];
  logic [31:0] r_c32;
  logic [23:0] r_c24;
  bit          r_inb, r_pkt, r_sopn, h_v, h_sop;
  logic [7:0]  r_chan, h_chan;
  logic [63:0] h_d;
  bit          m_rv, m_sop, m_eop, m_err, m_ew, m_es, m_esc, m_e32, m_e24, m_ep;
  logic [63:0] m_rd;
  logic [2:0]  m_by;
  logic [7:0]  m_ch;
  logic [15:0] m_fc;
  logic [1:0]  m_ps;
  // coverage
  bit v_inv, v_bc_sop, v_bc_cont, v_idle, v_close_max, v_close_eop, v_close_gap, v_eop_sop;
  bit v_slide, v_test_fail, v_wlock, v_unlock, v_win_reset, v_sync_seen, v_sync_test_fail, v_slock;
  bit v_sync_miss, v_lost_sync, v_scr_err, v_lost_scr, v_lost_word, v_c32_ok, v_c32_err, v_c24_err;
  bit v_data_out, v_eop_nodata, v_sop_in_pkt, v_cont_no_pkt, v_fw_in_prot, v_bad_frame_prot, v_lost_held;
  bit v_pkt_open_idle;
  // per-step copies for the covergroup (set at posedge, sampled at negedge)
  bit c_tv;
  int c_tbc, c_teb;
  bit c_teop;
  logic [63:0] c_td;

  function automatic bit prot(input int w);
    return w > 2 && w != MF - 1;
  endfunction
  assign m_ready = t_k == 0 && prot(t_w) && t_inb && !t_eop && t_bc < BMAX && tx_valid;

  always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      t_k = 0; t_w = 0; t_rd = 0; t_bc = 0; t_chk = -1; t_inb = 0; t_eop = 0; t_eb = 0;
      t_c32 = 0; t_c24 = '1; g_load(t_g, SEED);
      for (int i = 0; i < 67; i++) t_line[i] = 0;
      r_q = 0; r_inv = 0; r_f1 = 0; r_f0 = 0; r_k = 0; r_ws = 0; r_vc = 0; r_wc = 0; r_ic = 0;
      r_ms = 0; r_pos = 0; r_sc = 0; r_miss = 0; r_sm = 0; r_pay = 0; g_load(r_g, 0);
      r_c32 = 0; r_c24 = '1; r_inb = 0; r_pkt = 0; r_sopn = 0; h_v = 0; h_sop = 0; r_chan = 0; h_chan = 0; h_d = 0;
      {m_rv, m_sop, m_eop, m_err, m_ew, m_es, m_esc, m_e32, m_e24, m_ep} = '0;
      m_rd = 0; m_by = 0; m_ch = 0; m_fc = 0; m_ps = 0;
    end else begin : b_step
      bit b;
      c_tv = 0;
      // ---- transmitter
      if (t_k == 0) begin : b_word
        logic [63:0] p;
        logic [1:0]  f;
        bit          dat, scr;
        int          ones;
        dat = m_ready;
        f = dat ? 2'b01 : 2'b10;
        scr = t_w >= 2;
        if (t_w == 0) begin p = SYNC; t_c32 = '1; end
        else if (t_w == 1) p = {6'b001010, g_vec(t_g)};
        else if (t_w == 2) p = SKIP;
        else if (t_w == MF - 1) p = {6'b011001, 24'd0, sync_lock, sync_lock && peer_status[1], 32'd0};
        else if (dat) begin
          p = tx_data;
          t_c24 = c24_word(t_c24, p);
          t_bc++; t_eop = tx_eop; t_eb = tx_eop ? tx_bytes : 3'd0;
          c_tv = 1; c_tbc = t_bc; c_teop = tx_eop; c_teb = tx_bytes; c_td = tx_data;
        end else begin
          p = {1'b1, tx_valid, tx_valid && tx_sop, t_eop, t_eb, 1'b0, tx_fc, tx_valid ? tx_chan : 8'd0, 32'd0};
          t_c24 = c24_word(t_c24, p);
          p[23:0] = t_c24;
          if (t_inb && t_eop) v_close_eop = 1;
          else if (t_inb && t_bc == BMAX) v_close_max = 1;
          else if (t_inb) v_close_gap = 1;
          if (!tx_valid) v_idle = 1;
          else if (tx_sop) v_bc_sop = 1;
          else v_bc_cont = 1;
          if (tx_valid && tx_sop && t_eop) v_eop_sop = 1;
          t_inb = tx_valid; t_bc = 0; t_eop = 0; t_eb = 0; t_c24 = '1;
        end
        if (t_w == 1) t_c32 = c32_word(t_c32, f, {p[63:58], 58'd0});
        else if (t_w == MF - 1) begin
          t_c32 = c32_word(t_c32, f, p);
          p[31:0] = ~t_c32;
        end else t_c32 = c32_word(t_c32, f, p);
        if (scr) for (int i = 63; i >= 0; i--) p[i] = p[i] ^ g_step(t_g);
        ones = 1;
        for (int i = 0; i < 64; i++) ones += p[i];
        // disparity of the word with bit 66 = 0: ones - (67 - ones); the
        // inverted word has 67 - ones ones
        if (t_rd != 0 && (t_rd > 0) == (2 * ones - 67 > 0)) begin
          p = ~p; t_line[0] = 1; t_rd -= 2 * ones - 67; v_inv = 1;
        end else begin
          t_line[0] = 0; t_rd += 2 * ones - 67;
        end
        t_line[1] = f[1]; t_line[2] = f[0];
        for (int i = 0; i < 64; i++) t_line[3 + i] = p[63 - i];
        t_w = (t_w + 1) % MF;
      end
      t_chk = t_k;
      t_k = (t_k + 1) % 67;

      // ---- receiver
      {m_rv, m_ew, m_es, m_esc, m_e32, m_e24, m_ep} = '0;
      b = r_q;
      if (r_k == 0) begin r_inv = b; r_k = 1; end
      else if (r_k == 1) begin r_f1 = b; r_k = 2; end
      else if (r_k == 2) begin : b_frame
        bit ok;
        ok = r_f1 != b;
        r_f0 = b; r_k = 3;
        case (r_ws)
          0: if (ok) begin r_ws = 1; r_vc = 1; end
             else begin r_inv = r_f1; r_f1 = b; r_k = 2; v_slide = 1; end
          1: if (!ok) begin r_ws = 0; r_inv = r_f1; r_f1 = b; r_k = 2; v_test_fail = 1; end
             else begin
               r_vc++;
               if (r_vc == 64) begin r_ws = 2; r_wc = 0; r_ic = 0; v_wlock = 1; end
             end
          default: begin
            if (!ok) m_ew = 1;
            if (!ok && r_ic == 15) begin r_ws = 0; v_unlock = 1; end
            if (r_wc == 63) begin if (r_ic > 0) v_win_reset = 1; r_ic = 0; end
            else r_ic += !ok;
            r_wc = (r_wc + 1) % 64;
          end
        endcase
      end else begin
        r_pay[66 - r_k] = b ^ r_inv;
        if (r_k < 66) r_k++;
        else begin : b_rword
          logic [1:0]  f;
          logic [63:0] raw, d;
          bit          sync, lost;
          r_k = 0;
          f = {r_f1, r_f0};
          raw = r_pay;
          sync = f == 2'b10 && raw == SYNC;
          lost = 0;
          if (r_ws != 2 || r_ms == 0) begin
            if (r_ms == 2) lost = 1;
            if (r_ms == 2) v_lost_word = 1;
            r_ms = 0; r_pos = 0;
            if (r_ws == 2 && sync) begin
              r_ms = 1; r_sc = 1; r_pos = 1; r_c32 = c32_word('1, f, raw); v_sync_seen = 1;
            end
          end else begin : b_aligned
            int pos;
            pos = r_pos;
            r_pos = (r_pos + 1) % MF;
            d = raw;
            if (pos >= 2) for (int i = 63; i >= 0; i--) d[i] = d[i] ^ g_step(r_g);
            if (pos == 0) begin
              r_c32 = c32_word('1, f, raw);
              if (r_ms == 1) begin
                if (!sync) begin r_ms = 0; r_pos = 0; v_sync_test_fail = 1; end
                else begin r_sc++; if (r_sc == 4) begin r_ms = 2; r_miss = 0; r_sm = 0; v_slock = 1; end end
              end else if (!sync) begin
                m_es = 1; r_miss++; v_sync_miss = 1;
                if (r_miss == 4) begin lost = 1; v_lost_sync = 1; end
              end else r_miss = 0;
            end else if (pos == 1) begin
              r_c32 = c32_word(r_c32, f, {raw[63:58], 58'd0});
              if (r_ms == 2) begin
                if (f != 2'b10 || raw[63:58] != 6'b001010 || raw[57:0] != g_vec(r_g)) begin
                  m_esc = 1; r_sm++; v_scr_err = 1;
                  if (r_sm == 3) begin lost = 1; v_lost_scr = 1; end
                end else r_sm = 0;
              end else g_load(r_g, raw[57:0]);
            end else if (pos == MF - 1) begin
              r_c32 = c32_word(r_c32, f, {d[63:32], 32'd0});
              if (r_ms == 2) begin
                if (d[31:0] != ~r_c32) begin m_e32 = 1; v_c32_err = 1; end
                else begin m_ps = d[33:32]; v_c32_ok = 1; end
              end
            end else begin
              r_c32 = c32_word(r_c32, f, d);
              // ---- protocol word
              if (r_ms == 2 && pos != 2) begin
                if (f == 2'b01) begin
                  r_c24 = c24_word(r_c24, d);
                  if (!r_inb) begin m_ep = 1; v_data_out = 1; end
                  else begin
                    if (h_v) begin
                      m_rv = 1; m_rd = h_d; m_sop = h_sop; m_eop = 0; m_by = 0; m_ch = h_chan; m_err = 0;
                    end
                    h_v = 1; h_d = d; h_sop = r_sopn; h_chan = r_chan; r_sopn = 0;
                  end
                end else if (f == 2'b10 && !d[63]) begin
                  m_ep = 1; v_fw_in_prot = 1;
                end else if (f == 2'b10) begin : b_ctl
                  bit ok, still_open;
                  ok = c24_word(r_c24, {d[63:24], 24'd0}) == d[23:0];
                  r_c24 = '1;
                  if (!ok) begin m_e24 = 1; v_c24_err = 1; end
                  else m_fc = d[55:40];
                  if (h_v) begin
                    m_rv = 1; m_rd = h_d; m_sop = h_sop; m_eop = d[60]; m_by = d[60] ? d[59:57] : 0;
                    m_ch = h_chan; m_err = !ok; h_v = 0;
                  end else if (d[60]) begin m_ep = 1; v_eop_nodata = 1; end
                  still_open = r_pkt && !d[60];
                  if (d[62]) begin
                    if (d[61] && still_open) begin m_ep = 1; v_sop_in_pkt = 1; end
                    if (!d[61] && !still_open) begin m_ep = 1; v_cont_no_pkt = 1; end
                    r_inb = 1; r_pkt = 1; r_sopn = d[61]; r_chan = d[39:32];
                  end else begin
                    if (still_open) v_pkt_open_idle = 1;
                    r_inb = 0; r_pkt = still_open;
                  end
                end else v_bad_frame_prot = 1;
              end
            end
          end
          if (lost) begin
            r_ms = 0; r_pos = 0; r_inb = 0; r_pkt = 0; r_c24 = '1;
            if (h_v) begin
              m_rv = 1; m_rd = h_d; m_sop = h_sop; m_eop = 1; m_by = 0; m_ch = h_chan; m_err = 1;
              v_lost_held = 1;
            end
            h_v = 0;
          end
        end
      end
      r_q = rx_p;
    end
  end

  function automatic int dcls(input logic [63:0] v);
    return v == 64'd0 ? 0 : v == '1 ? 1 : (v == {32{2'b01}} || v == {32{2'b10}}) ? 2 : 3;
  endfunction
  covergroup cg_ilkn @(negedge clk);
    option.per_instance = 1;
    cp_tbc: coverpoint c_tbc iff (rst_n && c_tv) { bins n[] = {[1:BMAX]}; }
    cp_teb: coverpoint c_teb iff (rst_n && c_tv && c_teop) { bins b[] = {[0:7]}; }
    cp_tdata: coverpoint dcls(c_td) iff (rst_n && c_tv)
      { bins zero = {0}; bins ones = {1}; bins alt = {2}; bins other = {3}; }
    cp_rkind: coverpoint {rx_sop, rx_eop, rx_err} iff (rst_n && rx_valid)
      { bins mid = {3'b000}; bins sop = {3'b100}; bins eop = {3'b010}; bins sop_eop = {3'b110};
        bins eop_err = {3'b011}; }
    cp_reb: coverpoint rx_bytes iff (rst_n && rx_valid && rx_eop && !rx_err) { bins b[] = {[0:7]}; }
    cp_rdata: coverpoint dcls(rx_data) iff (rst_n && rx_valid)
      { bins zero = {0}; bins ones = {1}; bins alt = {2}; bins other = {3}; }
  endgroup
  cg_ilkn u_cg_ilkn = new;

  // ---------------- assertions ----------------
  `SVA_IMP(a_tx_bit, t_chk >= 0, tx_p == t_line[t_chk])
  `SVA_INV(a_tx_ready, tx_ready == m_ready)
  `SVA_INV(a_locks, word_lock == (r_ws == 2) && sync_lock == (r_ms == 2))
  `SVA_INV(a_errors, {err_word, err_sync, err_scr, err_crc32, err_crc24, err_proto} == {m_ew, m_es, m_esc, m_e32, m_e24, m_ep})
  `SVA_INV(a_rx_valid, rx_valid == m_rv)
  `SVA_IMP(a_rx_word, m_rv, rx_data == m_rd && rx_sop == m_sop && rx_eop == m_eop && rx_bytes == m_by &&
                            rx_chan == m_ch && rx_err == m_err)
  `SVA_INV(a_rx_fc, rx_fc == m_fc && peer_status == m_ps)
  `SVA_INV(a_disparity, t_rd >= -65 && t_rd <= 65)
  `SVA_RST(a_reset, 1'b1, !tx_p && !word_lock && !sync_lock && !rx_valid && rx_fc == 0 && peer_status == 0 &&
                          !err_word && !err_sync && !err_scr && !err_crc32 && !err_crc24 && !err_proto)

  // ---------------- functional coverage ----------------
  `FC(tx_inverted_word, v_inv)
  `FC(tx_burst_sop, v_bc_sop)
  `FC(tx_burst_continued, v_bc_cont)
  `FC(tx_idle, v_idle)
  `FC(tx_burst_ends_at_bmax, v_close_max)
  `FC(tx_burst_ends_at_eop, v_close_eop)
  `FC(tx_burst_ends_without_data, v_close_gap)
  `FC(tx_eop_and_sop_in_one_word, v_eop_sop)
  `FC(word_slide, v_slide)
  `FC(word_test_fails, v_test_fail)
  `FC(word_lock, v_wlock)
  `FC(word_unlock, v_unlock)
  `FC(word_window_reset, v_win_reset)
  `FC(sync_word_found, v_sync_seen)
  `FC(sync_test_fails, v_sync_test_fail)
  `FC(sync_lock, v_slock)
  `FC(sync_word_missing, v_sync_miss)
  `FC(sync_lost_by_sync_words, v_lost_sync)
  `FC(scrambler_state_wrong, v_scr_err)
  `FC(sync_lost_by_scrambler_state, v_lost_scr)
  `FC(sync_lost_with_word_lock, v_lost_word)
  `FC(crc32_ok, v_c32_ok)
  `FC(crc32_error, v_c32_err)
  `FC(crc24_error, v_c24_err)
  `FC(data_outside_burst, v_data_out)
  `FC(eop_without_data, v_eop_nodata)
  `FC(sop_inside_packet, v_sop_in_pkt)
  `FC(burst_without_sop_outside_packet, v_cont_no_pkt)
  `FC(framing_word_in_protocol_slot, v_fw_in_prot)
  `FC(invalid_framing_in_protocol_slot, v_bad_frame_prot)
  `FC(packet_open_across_idle, v_pkt_open_idle)
  `FC(held_word_flushed_at_loss, v_lost_held)
  `FC(rx_error_word, rx_valid && rx_err && !rx_eop)
  `FC(rx_eop_all_bytes, rx_valid && rx_eop && rx_bytes == 3'd0 && !rx_err)
  `FC(rx_sop_eop_one_word, rx_valid && rx_sop && rx_eop && !rx_err)
  `FC(rx_fc_change, rx_fc != $past(rx_fc))
  `FC(link_up, peer_status == 2'b11)
  `FC_RST(reset_while_synced, rst_n && sync_lock ##1 !rst_n)
endmodule

bind Interlaken_v1_2_top Interlaken_v1_2_sva #(.MF(MF), .BMAX(BMAX), .SEED(SEED)) u_sva (.*);
