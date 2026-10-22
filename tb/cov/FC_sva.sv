// SPDX-License-Identifier: Apache-2.0
// Fibre Channel port: concurrent SVA against an independent reference
// model, plus functional coverage.
//  * 8b/10b by table search: a character is the (k, byte) whose code for
//    the current running disparity matches; the code for the other
//    disparity is a disparity error, no match a code violation.
//  * Transmitter: character slots of 10 clocks from reset, words of four
//    slots. At each word start the model picks the word (SOF when the host
//    offers a byte, six words passed since the EOF and credit allows;
//    otherwise R_RDY while it owes one, else IDLE), then data, zero fill,
//    CRC and EOF; the next 10 line bits must be the code of its character.
//  * Receiver: own comma hunt, decoder, word parser, sync count, frame
//    delay line, CRC, length and status; the credit and R_RDY counters
//    from its own transmit and receive events.
// Every output is compared on every clock.
`include "cov_macros.svh"
module FC_sva (
  input logic       clk, rst_n, tx_p, rx_p,
  input logic [3:0] cfg_credit,
  input logic       tx_valid, tx_ready,
  input logic [7:0] tx_data,
  input logic       tx_last, tx_sofi, tx_eoft, tx_done, tx_underrun,
  input logic [3:0] credit_used,
  input logic       rx_valid,
  input logic [7:0] rx_data,
  input logic       rx_last,
  input logic [4:0] rx_stat,
  input logic       rx_frag, rx_sync, err_code, err_word
);
  `COV_CLOCKING(clk, !rst_n)

  // ---------------- 8b/10b tables ----------------
  function automatic logic [11:0] c6(input int x);   // {RD-, RD+}
    case (x)
      0: return 12'o4730;  1: return 12'o3542;  2: return 12'o5522;  3: return 12'o6161;
      4: return 12'o6512;  5: return 12'o5151;  6: return 12'o3131;  7: return 12'o7007;
      8: return 12'o7106;  9: return 12'o4545;  10: return 12'o2525; 11: return 12'o6464;
      12: return 12'o1515; 13: return 12'o5454; 14: return 12'o3434; 15: return 12'o2750;
      16: return 12'o3344; 17: return 12'o4343; 18: return 12'o2323; 19: return 12'o6262;
      20: return 12'o1313; 21: return 12'o5252; 22: return 12'o3232; 23: return 12'o7205;
      24: return 12'o6314; 25: return 12'o4646; 26: return 12'o2626; 27: return 12'o6611;
      28: return 12'o1616; 29: return 12'o5621; 30: return 12'o3641; 31: return 12'o5324;
      default: return 12'o1760;                       // K28
    endcase
  endfunction
  function automatic logic [7:0] c4(input int y);    // {RD-, RD+}; 8 = A7, 9.. = K28.y
    case (y)
      0: return 8'hB4; 1: return 8'h99; 2: return 8'h55; 3: return 8'hC3; 4: return 8'hD2;
      5: return 8'hAA; 6: return 8'h66; 7: return 8'hE1; 8: return 8'h78;
      9: return 8'hB4; 10: return 8'h69; 11: return 8'hA5; 12: return 8'hC3; 13: return 8'hD2;
      14: return 8'h5A; 15: return 8'h96; default: return 8'h78;
    endcase
  endfunction
  function automatic int n1(input logic [5:0] v);
    n1 = 0;
    for (int i = 0; i < 6; i++) n1 += v[i];
  endfunction
  // {rd after, symbol}
  function automatic logic [10:0] code(input logic [7:0] d, input bit k, input bit rd);
    int x, y, y4;
    logic [11:0] p6;
    logic [7:0]  p4;
    logic [5:0]  s6;
    logic [3:0]  s4;
    x = d[4:0]; y = d[7:5];
    p6 = c6(k && x == 28 ? 32 : x);
    s6 = rd ? p6[5:0] : p6[11:6];
    if (n1(s6) != 3) rd = !rd;
    if (k && x == 28) y4 = 9 + y;
    else if (y == 7 && (k || (!rd && (x == 17 || x == 18 || x == 20)) || (rd && (x == 11 || x == 13 || x == 14)))) y4 = 8;
    else y4 = y;
    p4 = c4(y4);
    s4 = rd ? p4[3:0] : p4[7:4];
    if (n1({2'b0, s4}) != 2) rd = !rd;
    return {rd, s6, s4};
  endfunction
  // 0: ok, 1: disparity error, 2: code violation; {k, byte} and rd after
  function automatic int dec(input logic [9:0] s, input bit rd, output logic [8:0] sym, output bit rd_n);
    logic [10:0] c;
    dec = 2; sym = 0; rd_n = rd;
    for (int k = 0; k < 2; k++)
      for (int d = 0; d < 256; d++) begin
        if (k == 1 && !(d[4:0] == 28 || (d[7:5] == 7 && (d[4:0] == 23 || d[4:0] == 27 || d[4:0] == 29 || d[4:0] == 30))))
          continue;
        c = code(d, k, rd);
        if (c[9:0] == s) begin dec = 0; sym = {1'(k), 8'(d)}; rd_n = c[10]; return dec; end
        c = code(d, k, !rd);
        if (c[9:0] == s) dec = 1;
      end
  endfunction
  function automatic logic [31:0] crc_b(input logic [31:0] c, input logic [7:0] d);
    for (int i = 0; i < 8; i++) c = (c[0] ^ d[i]) ? (c >> 1) ^ 32'hEDB88320 : c >> 1;
    return c;
  endfunction

  localparam logic [8:0] K285 = 9'h1BC;
  // ordered set characters 1..3
  localparam logic [23:0] IDLE = {8'h95, 8'hB5, 8'hB5}, RRDY = {8'h95, 8'h4A, 8'h4A},
                          SOFI = {8'hB5, 8'h56, 8'h56}, SOFN = {8'hB5, 8'h36, 8'h36};

  // ---------------- transmitter model ----------------
  int          t_cnt, t_w, t_ph, t_n, t_gap;   // t_ph: 0 gap, 1 SOF, 2 data, 3 fill to 24 / word, 4 CRC, 5 underrun fill, 6 EOF
  logic [23:0] t_os;
  logic [31:0] t_crc;
  bit          t_rd, t_eot, t_abt;
  logic [9:0]  t_bits;
  bit          m_done, m_ur;
  int          m_cu, m_rp;                       // credit used, R_RDYs owed
  // ---------------- receiver model ----------------
  bit          r_q, r_aln, r_rd, r_os, r_in, r_sofi, r_sync;
  logic [9:0]  r_sh;
  int          r_ph, r_w, r_osc, r_n;
  logic [7:0]  r_c [0:3];
  logic [7:0]  r_dl [0:4];                       // r_dl[4] oldest
  logic [31:0] r_crc;
  bit          m_rv, m_rl, m_fr, m_ec, m_ew;
  logic [7:0]  m_rd;
  logic [4:0]  m_rs;
  // coverage
  bit v_sofi, v_sofn, v_eoft, v_eofn, v_eof_neg, v_eof_pos, v_ur [0:3], v_pad24, v_padw, v_nopad;
  bit v_rrdy_tx, v_cr_wait, v_cr_sat, v_rp_sat, v_rr_extra, v_sof_over_rr;
  bit v_disp, v_viol, v_kpos, v_kother, v_sync, v_rr_rx, v_dat_out, v_eof_out, v_unk_os;
  bit v_ab_eofa, v_ab_os, v_ab_sof, v_ab_code, v_crc, v_short, v_long, v_sat, v_good, v_rx_eoft, v_rx_sofi, v_frag;

  wire exp_ready = t_cnt == 0 && t_ph == 2 && tx_valid;

  always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      t_cnt = 0; t_w = 0; t_ph = 0; t_n = 0; t_gap = 0; t_os = 0; t_crc = 0; t_rd = 0; t_eot = 0; t_abt = 0;
      t_bits = 0; m_done = 0; m_ur = 0; m_cu = 0; m_rp = 0;
      r_q = 0; r_aln = 0; r_rd = 0; r_os = 0; r_in = 0; r_sofi = 0; r_sync = 0; r_sh = 0;
      r_ph = 0; r_w = 0; r_osc = 0; r_n = 0; r_crc = 0;
      for (int i = 0; i < 4; i++) r_c[i] = 0;
      for (int i = 0; i < 5; i++) r_dl[i] = 0;
      {m_rv, m_rl, m_fr, m_ec, m_ew} = '0; m_rd = 0; m_rs = 0;
    end else begin : b_step
      bit          sof_tx, rr_tx, f_end, rr_rx;
      logic [8:0]  s;
      logic [10:0] c;
      sof_tx = 0; rr_tx = 0; f_end = 0; rr_rx = 0;
      m_done = 0; m_ur = 0;

      // ---- transmitter
      if (t_cnt == 0) begin
        s = {1'b0, t_os[23:16]};
        t_os = t_os << 8;
        case (t_ph)
          0: if (t_w == 0) begin
            s = K285;
            if (t_gap == 6 && tx_valid && (cfg_credit == 0 || m_cu < int'(cfg_credit))) begin
              sof_tx = 1; t_ph = 1; t_os = tx_sofi ? SOFI : SOFN;
              if (tx_sofi) v_sofi = 1; else v_sofn = 1;
              if (m_rp > 0) v_sof_over_rr = 1;
            end else begin
              if (t_gap == 6 && tx_valid) v_cr_wait = 1;
              rr_tx = m_rp > 0; t_os = rr_tx ? RRDY : IDLE;
              if (rr_tx) v_rrdy_tx = 1;
              if (t_gap < 6) t_gap++;
            end
          end
          1: if (t_w == 3) begin t_ph = 2; t_n = 0; t_crc = '1; end
          2: if (tx_valid) begin
            s = {1'b0, tx_data}; t_crc = crc_b(t_crc, tx_data); t_n++;
            if (tx_last) begin
              t_eot = tx_eoft;
              if (t_w == 3 && t_n >= 24) begin t_ph = 4; v_nopad = 1; end
              else begin t_ph = 3; if (t_n < 24) v_pad24 = 1; else v_padw = 1; end
            end
          end else begin
            s = 0; m_ur = 1; t_abt = 1; v_ur[t_w] = 1;
            t_ph = t_w == 3 ? 6 : 5;
          end
          3: begin
            s = 0; t_crc = crc_b(t_crc, 8'h00); t_n++;
            if (t_w == 3 && t_n >= 24) t_ph = 4;
          end
          4: begin s = {1'b0, ~t_crc[8 * t_w +: 8]}; if (t_w == 3) t_ph = 6; end
          5: begin s = 0; if (t_w == 3) t_ph = 6; end
          default: if (t_w == 0) begin
            s = K285;
            t_os = {t_rd ? 8'hB5 : 8'h95, {2{t_abt ? 8'hF5 : t_eot ? 8'h75 : 8'hD5}}};
            if (t_rd) v_eof_pos = 1; else v_eof_neg = 1;
            if (!t_abt) begin m_done = 1; if (t_eot) v_eoft = 1; else v_eofn = 1; end
          end else if (t_w == 3) begin t_ph = 0; t_gap = 0; t_abt = 0; end
        endcase
        c = code(s[7:0], s[8], t_rd);
        t_rd = c[10]; t_bits = c[9:0];
        t_w = (t_w + 1) % 4;
      end else t_bits = {t_bits[8:0], 1'b0};
      t_cnt = t_cnt == 0 ? 9 : t_cnt - 1;

      // ---- receiver
      {m_rv, m_fr, m_ec, m_ew} = '0;
      if (!r_aln) begin
        if (r_sh == 10'b0011111010 || r_sh == 10'b1100000101) begin
          r_aln = 1; r_ph = 1; r_rd = !r_sh[9]; r_w = 1; r_os = 1; r_osc = 0;
        end
      end else begin
        if (r_ph == 0) begin : b_rx
          logic [8:0] y;
          bit rdn, ok, os_end, eof, abt;
          int e, n0;
          n0 = r_n;
          e = dec(r_sh, r_rd, y, rdn);
          ok = e == 0 && (r_w == 0 ? (!y[8] || y == K285) : !y[8]);
          os_end = 0; abt = 1; eof = 0;
          if (!ok) begin
            m_ec = 1; r_aln = 0;
            if (e == 1) v_disp = 1; else if (e == 2) v_viol = 1;
            else if (r_w != 0) v_kpos = 1; else v_kother = 1;
            if (r_in) begin f_end = 1; v_ab_code = 1; end
            r_sync = 0; r_in = 0;
          end else begin
            r_rd = rdn;
            if (r_w == 0) r_os = y[8];
            r_c[r_w] = y[7:0];
            if (r_os && r_w == 3) begin : b_os
              logic [23:0] o;
              o = {r_c[1], r_c[2], r_c[3]};
              os_end = 1;
              eof = (o[23:16] == 8'h95 || o[23:16] == 8'hB5) && (o[15:0] == 16'hD5D5 || o[15:0] == 16'h7575 || o[15:0] == 16'hF5F5);
              if (r_osc < 3) r_osc++;
              if (r_sync) begin
                if (r_in) begin
                  f_end = 1; abt = !eof || o[15:0] == 16'hF5F5;
                  if (eof && o[15:0] == 16'hF5F5) v_ab_eofa = 1;
                  else if (o == SOFI || o == SOFN) v_ab_sof = 1;
                  else if (!eof) v_ab_os = 1;
                end else if (eof) begin m_ew = 1; v_eof_out = 1; end
                if (o == RRDY) begin rr_rx = 1; v_rr_rx = 1; end
                if (!eof && o != RRDY && o != IDLE && o != SOFI && o != SOFN) v_unk_os = 1;
                if (f_end) begin
                  m_rs = {r_sofi, eof && o[15:0] == 16'h7575, abt, r_n < 28 || r_n > 2140, r_crc != 32'hDEBB20E3};
                  if (!abt && r_n >= 28 && r_n <= 2140 && r_crc == 32'hDEBB20E3) v_good = 1;
                  if (m_rs[3]) v_rx_eoft = 1;
                end
                r_in = o == SOFI || o == SOFN;
                if (r_in) begin r_n = 0; r_crc = '1; r_sofi = o == SOFI; end
              end
              if (r_osc == 3 && !r_sync) begin r_sync = 1; v_sync = 1; end
            end
            if (!y[8] && (r_w == 0 || !r_os)) begin
              if (r_in) begin
                r_crc = crc_b(r_crc, y[7:0]);
                if (r_n >= 5) begin m_rv = 1; m_rd = r_dl[4]; m_rl = 0; end
                for (int i = 4; i > 0; i--) r_dl[i] = r_dl[i - 1];
                r_dl[0] = y[7:0];
                if (r_n < 4095) r_n++; else v_sat = 1;
              end else if (r_sync && r_w == 0) begin m_ew = 1; v_dat_out = 1; end
            end
          end
          if (f_end) begin
            if (!ok) m_rs = {r_sofi, 1'b0, 1'b1, n0 < 28 || n0 > 2140, r_crc != 32'hDEBB20E3};
            if (n0 >= 5) begin
              m_rv = 1; m_rd = r_dl[4]; m_rl = 1;
              if (m_rs[0]) v_crc = 1;
              if (n0 < 28) v_short = 1;
              if (n0 > 2140) v_long = 1;
              if (m_rs[4]) v_rx_sofi = 1;
            end else begin m_fr = 1; v_frag = 1; end
          end
          r_w = (r_w + 1) % 4;
        end
        r_ph = r_ph == 9 ? 0 : r_ph + 1;
      end
      r_sh = {r_sh[8:0], r_q};
      r_q = rx_p;

      // ---- credit, R_RDYs owed
      if (sof_tx && rr_rx && m_cu > 0) ;           // one out, one back
      else if (sof_tx) begin if (m_cu < 15) m_cu++; else v_cr_sat = 1; end
      else if (rr_rx) begin if (m_cu > 0) m_cu--; else v_rr_extra = 1; end
      if (f_end && rr_tx) ;
      else if (f_end) begin if (m_rp < 15) m_rp++; else v_rp_sat = 1; end
      else if (rr_tx) m_rp--;
    end
  end

  // ---------------- assertions ----------------
  `SVA_INV(a_tx_bit, tx_p == t_bits[9])
  `SVA_INV(a_tx_ready, tx_ready == exp_ready)
  `SVA_INV(a_tx_events, tx_done == m_done && tx_underrun == m_ur)
  `SVA_INV(a_credit, credit_used == 4'(m_cu))
  `SVA_INV(a_sync, rx_sync == r_sync)
  `SVA_INV(a_errors, err_code == m_ec && err_word == m_ew)
  `SVA_INV(a_rx_valid, rx_valid == m_rv && rx_frag == m_fr)
  `SVA_IMP(a_rx_data, m_rv, rx_data == m_rd && rx_last == m_rl)
  `SVA_IMP(a_rx_stat, m_rv && m_rl, rx_stat == m_rs)
  `SVA_RST(a_reset, 1'b1, !tx_p && !tx_ready && !rx_valid && !rx_sync && credit_used == 4'd0 && !tx_done)

  // ---------------- functional coverage ----------------
  `FC(tx_sofi, v_sofi)
  `FC(tx_sofn, v_sofn)
  `FC(tx_eoft, v_eoft)
  `FC(tx_eofn, v_eofn)
  `FC(tx_eof_from_rd_neg, v_eof_neg)
  `FC(tx_eof_from_rd_pos, v_eof_pos)
  `FC(underrun_char0, v_ur[0])
  `FC(underrun_char1, v_ur[1])
  `FC(underrun_char2, v_ur[2])
  `FC(underrun_char3, v_ur[3])
  `FC(fill_to_24, v_pad24)
  `FC(fill_to_word, v_padw)
  `FC(no_fill, v_nopad)
  `FC(rrdy_sent, v_rrdy_tx)
  `FC(sof_before_owed_rrdy, v_sof_over_rr)
  `FC(credit_wait, v_cr_wait)
  `FC(credit_saturates, v_cr_sat)
  `FC(rrdy_owed_saturates, v_rp_sat)
  `FC(rrdy_without_credit_used, v_rr_extra)
  `FC(rx_sync, v_sync)
  `FC(rx_rrdy, v_rr_rx)
  `FC(rx_disparity_error, v_disp)
  `FC(rx_code_violation, v_viol)
  `FC(rx_k_in_word, v_kpos)
  `FC(rx_other_k_char, v_kother)
  `FC(rx_data_outside_frame, v_dat_out)
  `FC(rx_eof_outside_frame, v_eof_out)
  `FC(rx_unknown_ordered_set, v_unk_os)
  `FC(rx_good_frame, v_good)
  `FC(rx_eoft, v_rx_eoft)
  `FC(rx_sofi, v_rx_sofi)
  `FC(rx_abort_eofa, v_ab_eofa)
  `FC(rx_abort_ordered_set, v_ab_os)
  `FC(rx_abort_sof, v_ab_sof)
  `FC(rx_abort_code_error, v_ab_code)
  `FC(rx_crc_error, v_crc)
  `FC(rx_too_short, v_short)
  `FC(rx_too_long, v_long)
  `FC(rx_count_saturates, v_sat)
  `FC(rx_fragment, v_frag)
  `FC(credit_at_limit, cfg_credit != 0 && credit_used == cfg_credit)
  `FC_RST(reset_in_frame, rst_n && t_ph == 2 ##1 !rst_n)
endmodule

bind FC_top FC_sva u_sva (.*);
