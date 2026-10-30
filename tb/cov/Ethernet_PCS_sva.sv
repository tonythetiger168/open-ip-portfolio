// SPDX-License-Identifier: Apache-2.0
// Ethernet 400GBASE-R PCS: concurrent SVA against independent reference
// models, plus functional coverage. The checker has its own copy of the
// alignment marker table (Table 119-2) and builds the interleaved marker
// group, the transcoding, the scrambler and the RS(544,514) encoder (its
// own GF(2^10) tables and generator polynomial) bit by bit, from the rules
// of clause 119:
//  * Transmit: every group taken is transcoded and scrambled, the marker
//    group (with its own PRBS9 pad and tx_am_sf) is put in at the start of
//    every AMP-th pair, every pair is split into the two messages, encoded,
//    and interleaved; every beat out must equal the model's. tx_in_ready
//    must be low exactly in the marker slots (the core's marker strobe is
//    used only to time the slot), output data held while stalled.
//  * Receive: the beats the core takes from its two RS decoders (verified
//    as an IP of their own) are merged into the pair stream by the model;
//    each time the core consumes a 257-bit block (internal strobe, for
//    timing only) the model takes its own next block, runs the marker lock
//    (hunt, lock, three misses), removes the marker group, descrambles and
//    reverse-transcodes it, and the output group, ev_am_err, ev_itb,
//    rx_am_lock and rx_am_sf on the next clock must be the model's.
`include "cov_macros.svh"
module Ethernet_PCS_sva #(parameter int AMP = 4096) (
  input logic         clk, rst_n,
  input logic [2:0]   tx_am_sf,
  input logic         tx_in_valid, tx_in_ready,
  input logic [263:0] tx_in_data,
  input logic         tx_out_valid, tx_out_first, tx_out_ready,
  input logic [639:0] tx_out_data,
  input logic         rx_in_valid, rx_in_first, rx_in_ready,
  input logic         rx_out_valid, rx_out_ready,
  input logic [263:0] rx_out_data,
  input logic         rx_am_lock, ev_am_err, ev_itb, ev_resync,
  input logic [2:0]   rx_am_sf,
  input logic         ev_uncorr_a, ev_uncorr_b,
  // internals: the decoders' outputs (verified IP) and timing strobes
  input logic         tload, tam, rblk, rtake,
  input logic         a_d_out_valid, a_d_out_first, a_d_out_bad, b_d_out_bad,
  input logic [319:0] a_d_out_data, b_d_out_data
);
  `COV_CLOCKING(clk, !rst_n)

  // ---------------- GF(2^10), generator ----------------
  int ex [0:2045];
  int lg [0:1023];
  int gen [0:30];
  function automatic int gm(input int a, input int b);
    return (a == 0 || b == 0) ? 0 : ex[lg[a] + lg[b]];
  endfunction
  // ---------------- alignment markers (Table 119-2) ----------------
  logic [119:0] amx [0:15];
  logic [1919:0] amf;                            // am_mapped<1919:0>
  initial begin
    int x;
    logic [7:0] t [0:15][0:14];
    x = 1;
    for (int i = 0; i < 1023; i++) begin
      ex[i] = x; ex[i + 1023] = x; lg[x] = i;
      x = x << 1;
      if (x >= 1024) x = x ^ 'h409;
    end
    gen[0] = 1;
    for (int i = 1; i <= 30; i++) gen[i] = 0;
    for (int j = 0; j < 30; j++)
      for (int i = j + 1; i >= 0; i--)
        gen[i] = (i > 0 ? gen[i - 1] : 0) ^ gm(gen[i], ex[j]);
    // {CM0, CM1, CM2, UP0, CM3, CM4, CM5, UP1, UM0, UM1, UM2, UP2, UM3, UM4, UM5}: the common
    // bytes, then UP0 / UP1 and UM0..UM2 per lane; the rest are their inverses
    begin
      logic [7:0] up0 [0:15], up1 [0:15];
      logic [23:0] um [0:15];
      up0 = '{8'hB6, 8'h04, 8'h46, 8'h5A, 8'hE1, 8'hF2, 8'h3D, 8'h22, 8'h60, 8'h6B, 8'hFA, 8'h6C, 8'h18, 8'h14, 8'hD0, 8'hB4};
      up1 = '{8'hD9, 8'h67, 8'hFE, 8'h84, 8'h19, 8'h4E, 8'hEE, 8'h32, 8'h9F, 8'hA2, 8'h04, 8'h71, 8'h5B, 8'hCC, 8'hB1, 8'h56};
      um = '{24'h01_71_F3, 24'h5A_DE_7E, 24'h3E_F3_56, 24'h86_80_D0, 24'h2A_51_F2, 24'h12_4F_D1, 24'h42_9C_A1,
             24'hD6_76_5B, 24'hE1_73_75, 24'h71_C4_3C, 24'h95_EB_D8, 24'h22_66_38, 24'hA2_F6_95, 24'h31_97_C3,
             24'hCA_FB_A6, 24'hA6_BA_79};
      for (int l = 0; l < 16; l++) begin
        t[l][0] = 8'h9A; t[l][1] = 8'h4A; t[l][2] = 8'h26; t[l][3] = up0[l];
        t[l][4] = ~t[l][0]; t[l][5] = ~t[l][1]; t[l][6] = ~t[l][2]; t[l][7] = up1[l];
        t[l][8] = um[l][23:16]; t[l][9] = um[l][15:8]; t[l][10] = um[l][7:0]; t[l][11] = ~up1[l];
        t[l][12] = ~t[l][8]; t[l][13] = ~t[l][9]; t[l][14] = ~t[l][10];
        for (int o = 0; o < 15; o++) amx[l][8 * o +: 8] = t[l][o];   // octet o, sent LSB first
      end
    end
    // 10-bit interleave: for row k, lanes 2j and 2j+1 (swapped on odd rows)
    for (int k = 0; k < 12; k++)
      for (int j = 0; j < 8; j++) begin
        amf[160 * k + 20 * j +: 10]      = amx[k % 2 == 0 ? 2 * j : 2 * j + 1][10 * k +: 10];
        amf[160 * k + 20 * j + 10 +: 10] = amx[k % 2 == 0 ? 2 * j + 1 : 2 * j][10 * k +: 10];
      end
  end

  // ---------------- bit-serial PCS functions ----------------
  logic [57:0] sh_t, sh_r;                       // scrambler histories (newest in bit 57)
  function automatic logic [256:0] xcode_m(input logic [263:0] g, output int kind);
    // kind: 0 all data, 1..4 first control block at c = kind - 1, 5 invalid sync header
    logic [256:0] o;
    int c, n;
    bit ok, alld;
    ok = 1; alld = 1; c = -1;
    for (int j = 0; j < 4; j++) begin
      if (g[66 * j +: 2] != 2'b10 && g[66 * j +: 2] != 2'b01) ok = 0;
      if (g[66 * j +: 2] != 2'b10) alld = 0;
      if (c < 0 && g[66 * j +: 2] == 2'b01) c = j;
    end
    o = '0;
    if (ok && alld) begin
      o[0] = 1;
      for (int j = 0; j < 4; j++) for (int i = 0; i < 64; i++) o[1 + 64 * j + i] = g[66 * j + 2 + i];
      kind = 0;
    end else begin
      if (!ok) c = 0;
      for (int j = 0; j < 4; j++) o[1 + j] = ok ? g[66 * j + 1] : 1'b1;
      n = 5;
      for (int j = 0; j < 4; j++)
        for (int i = 0; i < 64; i++)
          if (!(j == c && i >= 4 && i < 8)) begin o[n] = g[66 * j + 2 + i]; n++; end
      kind = ok ? c + 1 : 5;
    end
    return o;
  endfunction
  function automatic logic [256:0] scr_m(input logic [256:0] x, input bit de, inout logic [57:0] h);
    logic [256:0] o;
    for (int i = 0; i < 257; i++) begin
      o[i] = x[i] ^ h[19] ^ h[0];
      h = {de ? x[i] : o[i], h[57:1]};
    end
    return o;
  endfunction
  // the 11 clause 82 block types, by their first nibble
  function automatic int btf_m(input logic [3:0] n);
    logic [7:0] t [0:10];
    t = '{8'h1E, 8'h78, 8'h4B, 8'h87, 8'h99, 8'hAA, 8'hB4, 8'hCC, 8'hD2, 8'hE1, 8'hFF};
    for (int i = 0; i < 11; i++) if (t[i][3:0] == n) return int'(t[i]);
    return -1;
  endfunction
  // kind: 0 header 1, 1..4 first control block c = kind - 1, 5 flags all 1, 6 unknown type nibble
  function automatic logic [263:0] rxcode_m(input logic [256:0] x, output int kind);
    logic [263:0] g;
    int c, n, bt;
    g = '0;
    if (x[0]) begin
      for (int j = 0; j < 4; j++) begin
        g[66 * j +: 2] = 2'b10;
        for (int i = 0; i < 64; i++) g[66 * j + 2 + i] = x[1 + 64 * j + i];
      end
      kind = 0;
    end else if (x[4:1] == 4'hF) begin
      for (int j = 0; j < 4; j++) begin
        g[66 * j +: 2] = 2'b11;
        for (int i = 0; i < 64; i++) g[66 * j + 2 + i] = (64 * j + i < 252) ? x[5 + 64 * j + i] : 1'b0;
      end
      kind = 5;
    end else begin
      c = 0;
      while (x[1 + c]) c++;
      bt = btf_m(x[5 + 64 * c +: 4]);
      n = 5;
      for (int j = 0; j < 4; j++) begin
        g[66 * j +: 2] = bt < 0 ? 2'b11 : x[1 + j] ? 2'b10 : 2'b01;
        for (int i = 0; i < 64; i++)
          if (j == c && i >= 4 && i < 8) g[66 * j + 2 + i] = bt < 0 ? 1'b0 : 1'(bt >> i);
          else begin g[66 * j + 2 + i] = x[n]; n++; end
      end
      kind = bt < 0 ? 6 : c + 1;
    end
    return g;
  endfunction

  // ---------------- transmit model ----------------
  int  tpb, tpc;
  logic [8:0] prbs;
  logic [10279:0] tpair;
  logic [639:0] txq [$];
  logic [639:0] t_exp;
  logic [639:0] gotq [$];
  bit  t_chk, t_bad, t_ord, t_ochk, t_ovf;
  int  t_kind, t_btf;
  bit  t_am_slot;
  always_comb t_am_slot = tpc == 0 && tpb < 8;
  function automatic void tx_block(input logic [256:0] b);
    int ca [0:543], cb [0:543], rem [0:29], fb;
    tpair[257 * tpb +: 257] = b;
    if (tpb == 39) begin
      for (int w = 0; w < 2; w++) begin
        for (int i = 0; i < 30; i++) rem[i] = 0;
        for (int i = 0; i < 514; i++) begin
          int m;
          m = int'(tpair[20 * i + 10 * w +: 10]);
          if (w == 0) ca[i] = m; else cb[i] = m;
          fb = m ^ rem[29];
          for (int r = 29; r > 0; r--) rem[r] = rem[r - 1] ^ gm(fb, gen[r]);
          rem[0] = gm(fb, gen[0]);
        end
        for (int i = 0; i < 30; i++) if (w == 0) ca[514 + i] = rem[29 - i]; else cb[514 + i] = rem[29 - i];
      end
      for (int bt = 0; bt < 17; bt++) begin
        logic [639:0] v;
        for (int kk = 0; kk < 4; kk++)
          for (int j = 0; j < 8; j++) begin
            int k, p;
            k = 4 * bt + kk; p = 8 * k + j;
            v[10 * (16 * kk + 2 * j) +: 10]     = 10'(k % 2 == 0 ? ca[p] : cb[p]);
            v[10 * (16 * kk + 2 * j + 1) +: 10] = 10'(k % 2 == 0 ? cb[p] : ca[p]);
          end
        txq.push_back(v);
      end
    end
  endfunction
  int tob;                                       // beat of the pair out
  always @(posedge clk or negedge rst_n)
    if (!rst_n) begin
      tpb <= 0; tpc <= 0; prbs <= '1; sh_t <= '1; txq.delete(); gotq.delete(); t_chk <= 0; t_ochk <= 0; t_ovf <= 0; tob <= 0; t_kind <= -1; t_btf <= -1;
    end else begin : b_tx
      logic [256:0] b;
      logic [57:0] h;
      int kind;
      bit adv;
      t_chk <= 0; t_kind <= -1; t_btf <= -1;
      adv = 0;
      if (tload && tam) begin                    // a marker slot
        if (tpb < 7) b = amf[257 * tpb +: 257];
        else begin : b_last                      // the last 121 marker bits, the PRBS9 pad, the status
          logic [8:0] s;
          b[120:0] = amf[1799 +: 121];
          s = prbs;
          for (int i = 0; i < 133; i++) begin
            b[121 + i] = s[8] ^ s[4];
            s = {s[7:0], s[8] ^ s[4]};
          end
          b[256:254] = tx_am_sf;
          prbs <= s;
        end
        tx_block(b);
        adv = 1;
      end else if (tx_in_valid && tx_in_ready) begin
        h = sh_t;
        b = scr_m(xcode_m(tx_in_data, kind), 0, h);
        sh_t <= h;
        tx_block(b);
        t_kind <= kind;
        t_btf <= -1;
        for (int j = 3; j >= 0; j--) if (tx_in_data[66 * j +: 2] == 2'b01) t_btf <= int'(tx_in_data[66 * j + 2 +: 8]);
        adv = 1;
      end
      if (adv) begin
        tpb <= tpb == 39 ? 0 : tpb + 1;
        if (tpb == 39) tpc <= tpc == AMP - 1 ? 0 : tpc + 1;
      end
      // a beat out is compared once the model has its pair (the message beats
      // leave before the pair's last block is in)
      if (tx_out_valid && tx_out_ready) begin
        gotq.push_back(tx_out_data);
        t_ord <= tx_out_first == (tob == 0);
        tob <= tob == 16 ? 0 : tob + 1;
      end
      t_ochk <= tx_out_valid && tx_out_ready;
      if (txq.size() != 0 && gotq.size() != 0) begin
        t_chk <= 1;
        t_bad <= txq[0] != gotq[0];
        void'(txq.pop_front());
        void'(gotq.pop_front());
      end
      t_ovf <= gotq.size() > 17;
    end

  `SVA_INV(a_tx_beat, !t_chk || !t_bad)
  `SVA_INV(a_tx_first, !t_ochk || t_ord)
  `SVA_INV(a_tx_not_ahead, !t_ovf)
  `SVA_IMP(a_tx_am_slot, tload && tam, t_am_slot)
  `SVA_IMP(a_tx_no_input_in_am_slot, t_am_slot, !tx_in_ready)
  `SVA_IMP(a_tx_out_held, tx_out_valid && !tx_out_ready, ##1 tx_out_valid && $stable(tx_out_data) && $stable(tx_out_first))

  // ---------------- receive model ----------------
  logic [1023:0] racc;
  int  rfill, rbeat, rpb, rpc, miss;
  bit  rlock, ramacc, cur_bad;
  bit  pbq [$];
  logic [256:0] rbq [$];
  bit  rbbq [$];                                 // bad flag per block
  logic [2:0] rsf;
  // expected on the clock after a block is consumed
  bit  e_v, e_am_err, e_itb, e_chk;
  logic [263:0] e_g;
  int  r_kind, r_ev;                             // for coverage: reverse transcode kind; lock event
  always @(posedge clk or negedge rst_n)
    if (!rst_n) begin
      racc <= '0; rfill <= 0; rbeat <= 0; rpb <= 0; rpc <= 0; miss <= 0; rlock <= 0; ramacc <= 0; cur_bad <= 0;
      pbq.delete(); rbq.delete(); rbbq.delete(); sh_r <= '1; rsf <= '0; e_chk <= 0; e_v <= 0;
      e_am_err <= 0; e_itb <= 0; r_kind <= -1; r_ev <= 0;
    end else begin : b_rx
      logic [1023:0] acc;
      int fill, bt, nb, pb2;
      bit cb;
      acc = racc; fill = rfill; cb = cur_bad; pb2 = 0;
      e_chk <= 0; e_am_err <= 0; e_itb <= 0; r_kind <= -1; r_ev <= 0;
      // the decoders' beats into the stream: symbol k of A then of B
      if (a_d_out_valid && rtake) begin
        bt = a_d_out_first ? 0 : rbeat;
        if (bt == 0) pbq.push_back(a_d_out_bad || b_d_out_bad);
        nb = bt == 16 ? 2 : 32;
        for (int k = 0; k < nb; k++) begin
          acc[fill +: 10] = a_d_out_data[10 * k +: 10];
          acc[fill + 10 +: 10] = b_d_out_data[10 * k +: 10];
          fill += 20;
        end
        rbeat <= bt == 16 ? 0 : bt + 1;
      end
      while (fill >= 257) begin
        rbq.push_back(acc[256:0]);
        acc = acc >> 257; fill -= 257;
      end
      racc <= acc; rfill <= fill;
      // a block consumed by the core: the model's next block
      if (rblk) begin : b_blk
        logic [256:0] b, d;
        logic [263:0] g;
        logic [57:0] h;
        bit slot, m, bad;
        int kind;
        if (rpb == 0) begin
          cb = pbq.size() != 0 ? pbq[0] : 1'b0;
          if (pbq.size() != 0) void'(pbq.pop_front());
        end
        bad = cb;
        b = rbq.size() != 0 ? rbq[0] : '0;
        if (rbq.size() != 0) void'(rbq.pop_front());
        m = rpb < 7 ? b == amf[257 * rpb +: 257] : rpb == 7 ? b[120:0] == amf[1799 +: 121] : 1'b0;
        slot = rpb < 8 && (!rlock || rpc == 0);
        if (rpb == 7) begin
          if (!rlock) begin
            if (ramacc && m) begin rlock <= 1; rpc <= 0; miss <= 0; rsf <= b[256:254]; r_ev <= 1; end
          end else if (rpc == 0) begin
            if (ramacc && m) begin miss <= 0; rsf <= b[256:254]; r_ev <= miss != 0 ? 2 : 3; end
            else if (!bad) begin
              e_am_err <= 1; miss <= miss + 1;
              r_ev <= miss == 2 ? 5 : 4;
              if (miss == 2) rlock <= 0;
            end else r_ev <= 6;
          end else if (ramacc && m && !bad) begin e_am_err <= 1; r_ev <= 7; end
        end
        ramacc <= (rpb == 0 || ramacc) && m;
        if (rpb == 39) rpc <= rpc == AMP - 1 ? 0 : rpc + 1;
        rpb <= rpb == 39 ? 0 : rpb + 1;
        e_v <= 0;
        if (!slot && (rlock || rpb >= 8)) begin
          h = sh_r;
          d = scr_m(b, 1, h);
          sh_r <= h;
          g = rxcode_m(d, kind);
          if (rlock) begin
            e_v <= 1;
            for (int j = 0; j < 4; j++) if (bad) g[66 * j +: 2] = 2'b11;
            e_g <= g;
            e_itb <= (kind >= 5) && !bad;
            r_kind <= bad ? 7 : kind;
          end
        end
        e_chk <= 1;
      end
      cur_bad <= cb;
    end

  bit rv_q;                                      // rx_out_valid held from before
  always @(posedge clk or negedge rst_n)
    if (!rst_n) rv_q <= 0;
    else rv_q <= rx_out_valid && !rx_out_ready;
  `SVA_IMP(a_rx_block_available, rblk, rbq.size() != 0)
  `SVA_IMP(a_rx_out, e_chk && e_v, rx_out_valid && rx_out_data == e_g)
  `SVA_IMP(a_rx_no_out, e_chk && !e_v, rx_out_valid == rv_q)
  `SVA_IMP(a_rx_out_held, rx_out_valid && !rx_out_ready && !rblk, ##1 rx_out_valid && $stable(rx_out_data))
  `SVA_INV(a_rx_events, (e_chk ? (ev_am_err == e_am_err && ev_itb == e_itb) : (!ev_am_err && !ev_itb)))
  `SVA_INV(a_rx_lock, rx_am_lock == rlock)
  `SVA_INV(a_rx_sf, rx_am_sf == rsf)
  `SVA_RST(a_reset_outputs, 1'b1, !tx_out_valid && !rx_out_valid && !rx_am_lock && !ev_am_err && !ev_itb)

  // ---------------- functional coverage ----------------
  covergroup cg_pcs @(negedge clk);
    option.per_instance = 1;
    cp_tx_kind: coverpoint t_kind iff (t_kind >= 0)
      { bins all_data = {0}; bins ctrl_at[] = {[1:4]}; bins bad_sync = {5}; }
    cp_tx_btf: coverpoint t_btf iff (t_btf >= 0)
      { bins t[] = {8'h1E, 8'h78, 8'h4B, 8'h87, 8'h99, 8'hAA, 8'hB4, 8'hCC, 8'hD2, 8'hE1, 8'hFF}; }
    cp_rx_kind: coverpoint r_kind iff (r_kind >= 0)
      { bins all_data = {0}; bins ctrl_at[] = {[1:4]}; bins flags_all_1 = {5}; bins bad_type = {6};
        bins uncorrectable = {7}; }
    cp_lock: coverpoint r_ev iff (r_ev != 0)
      { bins acquire = {1}; bins recover = {2}; bins in_step = {3}; bins miss = {4}; bins lost = {5};
        bins bad_marker_pair = {6}; bins off_period = {7}; }
  endgroup
  cg_pcs u_cg_pcs = new;

  `FC(tx_input_held_by_marker, t_am_slot && tx_in_valid)
  `FC(tx_output_stall, tx_out_valid && !tx_out_ready)
  `FC(tx_input_gap, !tx_in_valid && tx_in_ready)
  `FC(rx_output_stall, rx_out_valid && !rx_out_ready)
  `FC(rx_decoder_held, a_d_out_valid && !rtake)
  `FC(rx_input_held, rx_in_valid && !rx_in_ready)
  `FC(rx_resync, ev_resync)
  `FC(rx_both_uncorrectable, ev_uncorr_a && ev_uncorr_b)
  `FC(tx_status_bits, tload && tam && tpb == 7 && tx_am_sf != 0)
endmodule

bind Ethernet_PCS_top Ethernet_PCS_sva #(.AMP(AMP)) u_sva (.*);
