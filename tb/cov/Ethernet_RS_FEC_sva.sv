// SPDX-License-Identifier: Apache-2.0
// Ethernet RS(544,514) FEC: concurrent SVA against independent reference
// models, plus functional coverage. The checker builds its own GF(2^10)
// (log / antilog tables from x^10 + x^3 + 1) and generator polynomial, and:
//  * Encoder: a symbol-serial LFSR (the textbook systematic encoder) follows
//    every beat taken, with its own beat counter and realignment; every beat
//    out must equal the model's (the message passed through, the parity on
//    beat 16).
//  * Decoder: every complete codeword taken is decoded by the classic
//    Berlekamp-Massey algorithm (with inversions), Chien search, Forney and
//    a syndrome check of the result; when the codeword reaches the
//    correction pass, the bypass settings are applied to the model's result
//    and every beat out (data, first, bad) and the event outputs must match.
//    The decoder's riBM / root-count rule must agree with this one.
//  * Ready / valid rules, held outputs, the stage occupancy the 17-clock
//    schedule relies on (each stage free when the next codeword arrives,
//    the buffer slot being written never the one being read), reset values.
`include "cov_macros.svh"
module Ethernet_RS_FEC_sva (
  input logic         clk, rst_n,
  input logic         cfg_bypass_corr, cfg_bypass_ind,
  input logic         e_in_valid, e_in_first, e_in_ready,
  input logic [319:0] e_in_data,
  input logic         e_out_valid, e_out_first, e_out_ready,
  input logic [319:0] e_out_data,
  input logic         d_in_valid, d_in_first, d_in_ready,
  input logic [319:0] d_in_data,
  input logic         d_out_valid, d_out_first, d_out_bad, d_out_ready,
  input logic [319:0] d_out_data,
  input logic         ev_corr, ev_uncorr, ev_eresync, ev_dresync,
  input logic [3:0]   st_nsym,
  // internals: stage timing only
  input logic         dce, dacc, bload, p1load, p1last, p2load, p1long,
  input logic [1:0]   bst, wsl, p2sl,
  input logic         p1st, p2st,
  input logic [4:0]   p2b
);
  `COV_CLOCKING(clk, !rst_n)

  // ---------------- GF(2^10) ----------------
  int ex [0:2045];
  int lg [0:1023];
  int gen [0:30];                              // g(x), lowest degree first
  initial begin
    int x;
    x = 1;
    for (int i = 0; i < 1023; i++) begin
      ex[i] = x; ex[i + 1023] = x; lg[x] = i;
      x = x << 1;
      if (x >= 1024) x = x ^ 'h409;
    end
    gen[0] = 1;
    for (int i = 1; i <= 30; i++) gen[i] = 0;
    for (int j = 0; j < 30; j++)               // times (x - a^j)
      for (int i = j + 1; i >= 0; i--)
        gen[i] = (i > 0 ? gen[i - 1] : 0) ^ gm(gen[i], ex[j]);
  end
  function automatic int gm(input int a, input int b);
    return (a == 0 || b == 0) ? 0 : ex[lg[a] + lg[b]];
  endfunction
  function automatic int gi(input int a);
    return ex[1023 - lg[a]];
  endfunction

  // ---------------- encoder model ----------------
  int  erem [0:29];
  int  ecb;
  logic [320:0] eq [$];                        // {first, beat} expected out
  logic [319:0] eexp;
  bit  e_chk, e_bad, e_ers;
  always @(posedge clk or negedge rst_n)
    if (!rst_n) begin
      ecb <= 0; eq.delete(); e_chk <= 0; e_ers <= 0;
    end else begin
      e_chk <= 0;
      e_ers <= e_in_valid && e_in_ready && e_in_first && ecb != 0;
      if (e_out_valid && e_out_ready) begin
        e_chk <= 1;
        e_bad <= eq.size() == 0 || eq[0] != {e_out_first, e_out_data};
        if (eq.size() != 0) void'(eq.pop_front());
      end
      if (e_in_valid && e_in_ready) begin : b_enc
        int b, fb, n;
        b = e_in_first ? 0 : ecb;
        if (b == 0) for (int i = 0; i < 30; i++) erem[i] = 0;
        n = b == 16 ? 2 : 32;
        for (int k = 0; k < n; k++) begin
          fb = int'(e_in_data[10*k +: 10]) ^ erem[29];
          for (int i = 29; i > 0; i--) erem[i] = erem[i - 1] ^ gm(fb, gen[i]);
          erem[0] = gm(fb, gen[0]);
        end
        eexp = e_in_data;
        if (b == 16) for (int k = 2; k < 32; k++) eexp[10*k +: 10] = 10'(erem[31 - k]);
        eq.push_back({b == 0, eexp});
        ecb <= b == 16 ? 0 : b + 1;
      end
    end

  // ---------------- decoder model ----------------
  int  rx [0:543];
  int  dcb;
  // one entry per codeword: {snz, ok, nsym, corrected, received}
  logic [10886:0] mq [$];
  int  S [0:29], lam [0:30], bpl [0:30], tl [0:30], om [0:29], cor [0:543];

  function automatic bit bm_decode(output int nsym);
    int L, m, bb, d, coef, n, xi, ev, num, den, s;
    for (int j = 0; j < 30; j++) begin
      s = 0;
      for (int i = 0; i < 544; i++) s = gm(s, ex[j]) ^ rx[i];
      S[j] = s;
    end
    for (int i = 0; i < 544; i++) cor[i] = rx[i];
    nsym = 0;
    for (int i = 0; i <= 30; i++) begin lam[i] = 0; bpl[i] = 0; end
    lam[0] = 1; bpl[0] = 1; L = 0; m = 1; bb = 1;
    for (int r = 0; r < 30; r++) begin
      d = S[r];
      for (int i = 1; i <= L; i++) d = d ^ gm(lam[i], S[r - i]);
      if (d == 0) m++;
      else begin
        coef = gm(d, gi(bb));
        for (int i = 0; i <= 30; i++) tl[i] = lam[i];
        for (int i = 0; i + m <= 30; i++) lam[i + m] = lam[i + m] ^ gm(coef, bpl[i]);
        if (2 * L <= r) begin
          L = r + 1 - L; bb = d; m = 1;
          for (int i = 0; i <= 30; i++) bpl[i] = tl[i];
        end else m++;
      end
    end
    if (L > 15) return 0;
    for (int i = 0; i < 30; i++) begin
      om[i] = 0;
      for (int j = 0; j <= i; j++) om[i] = om[i] ^ gm(S[j], lam[i - j]);
    end
    n = 0;
    for (int pos = 0; pos < 544; pos++) begin
      xi = pos == 0 ? 1 : gi(ex[pos]);
      ev = 0;
      for (int i = L; i >= 0; i--) ev = gm(ev, xi) ^ lam[i];
      if (ev == 0) begin
        num = 0;
        for (int i = 29; i >= 0; i--) num = gm(num, xi) ^ om[i];
        den = 0;
        for (int i = 1; i <= L; i += 2) den = den ^ gm(lam[i], i == 1 ? 1 : ex[(lg[xi] * (i - 1)) % 1023]);
        if (den == 0) return 0;
        cor[543 - pos] = cor[543 - pos] ^ gm(ex[pos], gm(num, gi(den)));
        n++;
      end
    end
    if (n != L) return 0;
    for (int j = 0; j < 30; j++) begin
      s = 0;
      for (int i = 0; i < 544; i++) s = gm(s, ex[j]) ^ cor[i];
      if (s != 0) return 0;
    end
    nsym = n;
    return 1;
  endfunction

  int c_ns;
  bit v_ers, v_drs, v_estall, v_dstall, v_egap, v_dgap, v_full, v_long, v_rootmis, v_bpc_clean, v_bpc_bad,
      v_ind_hidden, v_e_first0, v_d_first0, v_par_err, v_first_sym, v_last_sym;
  logic [320:0] dq [$];                        // {bad, beat} expected out
  logic [10886:0] me;
  bit  d_chk, d_bad, d_drs, x_corr, x_unc, n_chk;
  logic [3:0] x_nsym;
  int  dob;                                    // beat out
  always @(posedge clk or negedge rst_n)
    if (!rst_n) begin
      dcb <= 0; mq.delete(); dq.delete(); d_chk <= 0; d_drs <= 0; x_corr <= 0; x_unc <= 0; n_chk <= 0;
      x_nsym <= '0; dob <= 0;
    end else begin
      d_chk <= 0;
      d_drs <= d_in_valid && d_in_ready && d_in_first && dcb != 0;
      // outputs
      if (d_out_valid && d_out_ready) begin
        d_chk <= 1;
        d_bad <= dq.size() == 0 || dq[0] != {d_out_bad, d_out_data} || d_out_first != (dob == 0);
        if (dq.size() != 0) void'(dq.pop_front());
        dob <= dob == 16 ? 0 : dob + 1;
      end
      // a codeword reaches the correction pass: the bypass settings apply
      x_corr <= 0; x_unc <= 0; n_chk <= 0; c_ns <= -1;
      if (p2load && dce) begin
        bit fix, bad;
        logic [5439:0] o;
        if (mq.size() == 0) begin x_unc <= 1; x_corr <= 1; end   // fails a_events
        else begin
          me = mq.pop_front();
          fix = me[5445] && !cfg_bypass_corr;
          bad = cfg_bypass_corr ? me[5446] : !me[5445];
          o = fix ? me[5439:0] : me[10886:5447];
          for (int b = 0; b < 17; b++) dq.push_back({bad && !cfg_bypass_ind, o[320*b +: 320]});
          x_corr <= fix && me[5444:5440] != 0;
          x_unc  <= bad;
          x_nsym <= fix ? me[5443:5440] : 4'd0;
          n_chk  <= 1;
          c_ns   <= me[5445] ? int'(me[5444:5440]) : 16;
          if (!me[5445] && !p1long) v_rootmis <= 1;
          if (cfg_bypass_corr && !me[5446]) v_bpc_clean <= 1;
          if (cfg_bypass_corr && me[5446]) v_bpc_bad <= 1;
          if (cfg_bypass_ind && !cfg_bypass_corr && !me[5445]) v_ind_hidden <= 1;
          if (me[5445] && me[5439:5140] != me[10886:10587]) v_par_err <= 1;
          if (me[5445] && me[9:0] != me[5456:5447]) v_first_sym <= 1;
          if (me[5445] && me[5439:5430] != me[10886:10877]) v_last_sym <= 1;
        end
      end
      // inputs
      if (d_in_valid && d_in_ready) begin : b_dec
        int b, ns;
        bit ok, snz;
        logic [5439:0] cw, rw;
        b = d_in_first ? 0 : dcb;
        for (int k = 0; k < 32; k++) rx[32 * b + k] = int'(d_in_data[10*k +: 10]);
        if (b == 16) begin
          ok = bm_decode(ns);
          snz = 0;
          for (int j = 0; j < 30; j++) if (S[j] != 0) snz = 1;
          for (int i = 0; i < 544; i++) begin cw[10*i +: 10] = 10'(cor[i]); rw[10*i +: 10] = 10'(rx[i]); end
          mq.push_back({rw, snz, ok, 5'(ns), cw});
        end
        dcb <= b == 16 ? 0 : b + 1;
      end
    end

  // ---------------- assertions ----------------
  `SVA_INV(a_e_ready, e_in_ready == (!e_out_valid || e_out_ready))
  `SVA_INV(a_d_ready, d_in_ready == (!d_out_valid || d_out_ready))
  `SVA_NXT(a_e_hold, e_out_valid && !e_out_ready, e_out_valid && $stable(e_out_data) && $stable(e_out_first))
  `SVA_NXT(a_d_hold, d_out_valid && !d_out_ready,
           d_out_valid && $stable(d_out_data) && $stable(d_out_first) && $stable(d_out_bad))
  `SVA_IMP(a_encoder, e_chk, !e_bad)
  `SVA_IMP(a_decoder, d_chk, !d_bad)
  `SVA_INV(a_events, ev_corr == x_corr && ev_uncorr == x_unc)
  `SVA_IMP(a_nsym, n_chk, st_nsym == x_nsym)
  `SVA_INV(a_eresync, ev_eresync == e_ers)
  `SVA_INV(a_dresync, ev_dresync == d_drs)
  `SVA_IMP(a_bm_free, bload, bst != 2'd1)
  `SVA_IMP(a_chien1_free, p1load, !p1st || p1last)
  `SVA_IMP(a_chien2_free, p2load, !p2st || p2b == 5'd16)
  `SVA_IMP(a_buffer_slot, dacc && p2st, wsl != p2sl)
  `SVA_RST(a_reset, 1'b1, !e_out_valid && !d_out_valid && !ev_corr && !ev_uncorr && !ev_eresync && !ev_dresync
                          && st_nsym == 4'd0)

  // ---------------- functional coverage ----------------
  always @(posedge clk) begin
    if (rst_n) begin
      if (ev_eresync) v_ers <= 1;
      if (ev_dresync) v_drs <= 1;
      if (e_out_valid && !e_out_ready && e_in_valid) v_estall <= 1;
      if (d_out_valid && !d_out_ready && d_in_valid) v_dstall <= 1;
      if (!e_in_valid && ecb != 0) v_egap <= 1;
      if (!d_in_valid && dcb != 0) v_dgap <= 1;
      if (bload && p1st && p2st) v_full <= 1;           // all stages busy
      if (p2load && p1long) v_long <= 1;
      if (e_in_valid && e_in_ready && !e_in_first && ecb == 0) v_e_first0 <= 1;
      if (d_in_valid && d_in_ready && !d_in_first && dcb == 0) v_d_first0 <= 1;
    end
  end
  covergroup cg_fec @(negedge clk);
    option.per_instance = 1;
    cp_nsym: coverpoint c_ns iff (c_ns >= 0)
      { bins clean = {0}; bins one = {1}; bins few = {[2:7]}; bins many = {[8:14]}; bins max_t = {15};
        bins uncorrectable = {16}; }
  endgroup
  cg_fec u_cg_fec = new;

  `FC(encoder_realign, v_ers)
  `FC(decoder_realign, v_drs)
  `FC(encoder_stall, v_estall)
  `FC(decoder_stall, v_dstall)
  `FC(encoder_input_gap, v_egap)
  `FC(decoder_input_gap, v_dgap)
  `FC(all_stages_busy, v_full)
  `FC(length_above_t, v_long)
  `FC(root_count_mismatch, v_rootmis)
  `FC(bypass_corr_clean, v_bpc_clean)
  `FC(bypass_corr_errors, v_bpc_bad)
  `FC(bypass_ind_hides_bad, v_ind_hidden)
  `FC(encoder_beat0_without_first, v_e_first0)
  `FC(decoder_beat0_without_first, v_d_first0)
  `FC(parity_symbol_corrected, v_par_err)
  `FC(first_symbol_corrected, v_first_sym)
  `FC(last_symbol_corrected, v_last_sym)
  `FC_RST(reset_while_decoding, rst_n && p2st ##1 !rst_n)
endmodule
bind Ethernet_RS_FEC_top Ethernet_RS_FEC_sva u_sva (.*);
