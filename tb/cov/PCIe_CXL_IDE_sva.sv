// SPDX-License-Identifier: Apache-2.0
// PCIe_CXL_IDE: concurrent SVA against a model built from the ports, plus
// functional coverage. The model
//  * has its own AES-256 (S-box from the inverse in GF(2^8)) and GHASH (SP
//    800-38D algorithm 1, bit by bit), so every ciphertext / plaintext block
//    and every MAC is recomputed independently of the AES_GCM engines;
//  * keeps its own key slots, counters, key-set and Secure state per
//    direction and stream from the key-management pins, and predicts every
//    km error and code;
//  * applies the documented framing rules (prefix, header / payload order,
//    block sizes, cachemem epochs, Stream ID lookup, key-set switch,
//    counter exhaustion, GCM length limits) to each message, predicts every
//    transmit / receive error with its code and stream, each output block
//    (prefix, header, ciphertext, MAC, plaintext, END and its MAC verdict,
//    nullified MAC / END blocks) and the done pulses;
//  * uses the core's state only for the moment a message is classified
//    (the engine is idle and the first block is offered), and checks the
//    key / counter registers, the handshake rules, output hold under
//    back-pressure and a bound on how long an expected output may wait.
`include "cov_macros.svh"
module PCIe_CXL_IDE_sva #(parameter int NS = 2, parameter int CTR_W = 64, parameter int LEN_W = 16) (
  input logic              clk, rst_n,
  input logic [NS-1:0]     s_en, s_cm,
  input logic [NS*8-1:0]   s_id,
  input logic [NS*32-1:0]  s_ivfix,
  input logic [6:0]        cm_agg,
  input logic              km_dir, km_ks, km_sel, sl_valid, km_prog, km_go, km_stop, clr,
  input logic [1:0]        km_sid, km_sub,
  input logic [255:0]      km_key, sl_key,
  input logic [NS-1:0]     sec_tx, sec_rx, ks_tx, ks_rx,
  input logic [NS*6-1:0]   kv_tx, kv_rx,
  input logic              tx_busy, rx_busy, km_err, tx_done, tx_err, rx_done, rx_err,
  input logic [2:0]        km_code, tx_code, rx_code,
  input logic [1:0]        tx_esid,
  input logic [7:0]        rx_eid,
  input logic              tx_valid, tx_ready, tx_hdr, tx_last, tx_ide,
  input logic [127:0]      tx_data, txo_data, rx_data, rxo_data,
  input logic [4:0]        tx_bytes, txo_bytes, rx_bytes, rxo_bytes,
  input logic [1:0]        tx_sid, tx_sub, txo_kind, rx_kind, rx_sid, rxo_kind,
  input logic              txo_valid, txo_ready, txo_last, txo_bad, txo_cm,
  input logic              rx_valid, rx_ready, rx_last, rx_cm,
  input logic              rxo_valid, rxo_ready, rxo_last, rxo_bad, rxo_cm,
  // internal: the moment a message is classified, and the slot registers
  input logic [3:0]        t, r,
  input logic              gt_err, gr_err,
  input logic [NS*6*256-1:0]   ktx, krx,
  input logic [NS*6*CTR_W-1:0] ctx, crx
);
  `COV_CLOCKING(clk, !rst_n)
  localparam int NSL = NS * 6;
  localparam logic [1:0] K_HDR = 2'd0, K_DATA = 2'd1, K_MAC = 2'd2, K_PFX = 2'd3;
  localparam longint AMAX = (64'd1 << LEN_W) - 1, TMAX = (64'd1 << LEN_W) - 32;
  localparam longint CMAX = (CTR_W == 64) ? -1 : (64'd1 << CTR_W) - 1;
  localparam int QD = 64;

  // ---------------- AES-256 and GHASH from their definitions ----------------
  logic [7:0] sb [0:255];
  function automatic logic [7:0] gm(input logic [7:0] a, input logic [7:0] b);
    logic [7:0] q;
    q = 0;
    for (int i = 0; i < 8; i++) begin
      if (b[i]) q ^= a;
      a = {a[6:0], 1'b0} ^ (a[7] ? 8'h1b : 8'h00);
    end
    return q;
  endfunction
  initial begin
    for (int x = 0; x < 256; x++) begin
      logic [7:0] y, s;
      y = 0;
      for (int c = 1; c < 256; c++) if (gm(8'(x), 8'(c)) == 8'h01) y = 8'(c);
      s = y ^ {y[6:0], y[7]} ^ {y[5:0], y[7:6]} ^ {y[4:0], y[7:5]} ^ {y[3:0], y[7:4]} ^ 8'h63;
      sb[x] = s;
    end
  end
  function automatic logic [127:0] aes(input logic [255:0] k, input logic [127:0] blk);
    logic [31:0] w [0:59];
    logic [7:0]  s [0:15], u [0:15];
    logic [7:0]  rc;
    rc = 8'h01;
    for (int i = 0; i < 8; i++) w[i] = k[255 - 32 * i -: 32];
    for (int i = 8; i < 60; i++) begin
      logic [31:0] x;
      x = w[i - 1];
      if (i % 8 == 0) begin
        x = {sb[x[23:16]], sb[x[15:8]], sb[x[7:0]], sb[x[31:24]]} ^ {rc, 24'h0};
        rc = gm(rc, 8'h02);
      end else if (i % 8 == 4) x = {sb[x[31:24]], sb[x[23:16]], sb[x[15:8]], sb[x[7:0]]};
      w[i] = w[i - 8] ^ x;
    end
    for (int b = 0; b < 16; b++) s[b] = blk[127 - 8 * b -: 8] ^ w[b / 4][31 - 8 * (b % 4) -: 8];
    for (int rd = 1; rd <= 14; rd++) begin
      for (int c = 0; c < 4; c++)
        for (int row = 0; row < 4; row++) u[4 * c + row] = sb[s[4 * ((c + row) % 4) + row]];
      for (int c = 0; c < 4; c++)
        for (int row = 0; row < 4; row++)
          if (rd == 14) s[4 * c + row] = u[4 * c + row];
          else s[4 * c + row] = gm(u[4 * c + row], 8'h02) ^ gm(u[4 * c + (row + 1) % 4], 8'h03)
                                ^ u[4 * c + (row + 2) % 4] ^ u[4 * c + (row + 3) % 4];
      for (int b = 0; b < 16; b++) s[b] ^= w[4 * rd + b / 4][31 - 8 * (b % 4) -: 8];
    end
    for (int b = 0; b < 16; b++) aes[127 - 8 * b -: 8] = s[b];
  endfunction
  function automatic logic [127:0] gfmul(input logic [127:0] x, input logic [127:0] y);
    logic [127:0] z, v;
    z = 0; v = y;
    for (int i = 0; i < 128; i++) begin
      if (x[127 - i]) z ^= v;
      v = v[0] ? (v >> 1) ^ {8'he1, 120'h0} : v >> 1;
    end
    return z;
  endfunction
  function automatic logic [127:0] bm(input int n);    // the first n bytes
    for (int i = 0; i < 16; i++) bm[127 - 8 * i -: 8] = i < n ? 8'hff : 8'h00;
  endfunction

  // ---------------- key slots and streams (index: dir * NSL + slot) ----------------
  logic [255:0] mk [0:2*NSL-1];
  logic         mkv [0:2*NSL-1];
  longint       mc [0:2*NSL-1];
  logic         msec [0:7], mks [0:7];  // dir * 4 + stream
  function automatic int sl(input int s, input int k, input int sub);
    return s * 6 + k * 3 + sub;
  endfunction

  // ---------------- one GCM message of the model ----------------
  // index 0 transmit, 1 receive
  logic [255:0] g_key [0:1];
  logic [127:0] g_h [0:1], g_e0 [0:1], g_s [0:1];
  logic [95:0]  g_iv [0:1];
  longint       g_alen [0:1], g_clen [0:1];
  logic [31:0]  g_ctr [0:1];
  logic [127:0] g_ab [0:1];             // AAD bytes not yet hashed (left-aligned)
  int           g_an [0:1];
  task automatic g_start(input int d, input logic [255:0] k, input logic [95:0] v);
    g_key[d] = k; g_iv[d] = v;
    g_h[d] = aes(k, 128'h0); g_e0[d] = aes(k, {v, 32'd1});
    g_s[d] = 0; g_alen[d] = 0; g_clen[d] = 0; g_ctr[d] = 2; g_ab[d] = 0; g_an[d] = 0;
  endtask
  // AAD bytes (n of them, left-aligned in x)
  task automatic g_aad(input int d, input logic [127:0] x, input int n);
    for (int i = 0; i < n; i++) begin
      g_ab[d][127 - 8 * g_an[d] -: 8] = x[127 - 8 * i -: 8];
      g_an[d]++;
      if (g_an[d] == 16) begin g_s[d] = gfmul(g_s[d] ^ g_ab[d], g_h[d]); g_ab[d] = 0; g_an[d] = 0; end
    end
    g_alen[d] += n;
  endtask
  // a text block: returns the output block (ciphertext or plaintext)
  function automatic logic [127:0] g_txt(input int d, input logic [127:0] x, input int n, input logic dec);
    logic [127:0] o;
    if (g_an[d] != 0) begin g_s[d] = gfmul(g_s[d] ^ g_ab[d], g_h[d]); g_ab[d] = 0; g_an[d] = 0; end
    o = (x ^ aes(g_key[d], {g_iv[d], g_ctr[d]})) & bm(n);
    g_s[d] = gfmul(g_s[d] ^ (dec ? x & bm(n) : o), g_h[d]);
    g_ctr[d]++;
    g_clen[d] += n;
    return o;
  endfunction
  function automatic logic [95:0] g_mac(input int d);
    logic [127:0] s;
    s = g_s[d];
    if (g_an[d] != 0) s = gfmul(s ^ g_ab[d], g_h[d]);
    s = gfmul(s ^ {64'(g_alen[d] * 8), 64'(g_clen[d] * 8)}, g_h[d]) ^ g_e0[d];
    return s[127:32];
  endfunction

  // ---------------- expected outputs and pulses ----------------
  // output queues (0 transmit, 1 receive): data, bytes, kind, last, bad, cm
  logic [127:0] q_d [0:1][0:QD-1];
  logic [4:0]   q_n [0:1][0:QD-1];
  logic [1:0]   q_k [0:1][0:QD-1];
  logic         q_l [0:1][0:QD-1], q_b [0:1][0:QD-1], q_c [0:1][0:QD-1];
  int           q_hd [0:1], q_tl [0:1];
  task automatic push(input int d, input logic [127:0] x, input int n, input logic [1:0] k, input logic l,
                      input logic b, input logic c);
    q_d[d][q_tl[d] % QD] = x; q_n[d][q_tl[d] % QD] = 5'(n); q_k[d][q_tl[d] % QD] = k;
    q_l[d][q_tl[d] % QD] = l; q_b[d][q_tl[d] % QD] = b; q_c[d][q_tl[d] % QD] = c;
    q_tl[d]++;
  endtask
  // expected error pulses: code and stream (transmit index / receive Stream ID)
  logic [2:0]   e_c [0:1][0:7];
  logic [7:0]   e_s [0:1][0:7];
  int           e_hd [0:1], e_tl [0:1], e_age [0:1];
  int           dn_exp [0:1];           // done pulses expected
  int           c_err [0:1];            // coverage: error code (-1 none)
  task automatic experr(input int d, input logic [2:0] c, input logic [7:0] s);
    e_c[d][e_tl[d] % 8] = c; e_s[d][e_tl[d] % 8] = s; e_tl[d]++;
    c_err[d] = int'(c);
  endtask

  // ---------------- model ----------------
  wire [3:0]  en4 = 4'(s_en), cm4 = 4'(s_cm);
  wire [31:0] id4m = 32'(s_id);
  logic       m_kerr_q;
  logic [2:0] m_kcode_q;
  // transmit message state
  logic   tm_act, tm_cm, tm_byp, tm_drop, tm_term, tm_ep, tm_ph, tm_hs, tm_hp;
  int     tm_s, tm_epn;
  // receive message state
  logic   rm_act, rm_cm, rm_byp, rm_drop, rm_term, rm_ep, rm_ph, rm_hs, rm_hp, rm_dp, rm_mac;
  int     rm_s, rm_epn;
  logic [7:0]   rm_id;
  logic [127:0] rm_hd;                  // held partial block (plaintext computed at the MAC)
  int           rm_hn;
  // failure flags (checked by the assertions one clock later)
  logic f_txo, f_rxo, f_txe, f_rxe, f_kme, f_txd, f_rxd, f_slots, f_cnt, f_state, f_kcode;
  // coverage events
  int   c_km, c_tmsg, c_rmsg, c_clr, c_hdr, c_pay;
  logic c_ksw, c_trunc, c_tbp, c_rbp;
  wire [7:0] cagg1 = 8'(cm_agg) + 8'd1;

  task automatic m_reset_keys();
    for (int i = 0; i < 2 * NSL; i++) begin mk[i] = 0; mkv[i] = 0; mc[i] = 0; end
    for (int i = 0; i < 8; i++) begin msec[i] = 0; mks[i] = 0; end
  endtask
  task automatic m_reset_msgs();
    tm_act = 0; tm_byp = 0; tm_drop = 0; tm_term = 0; tm_ep = 0; tm_cm = 0;
    rm_act = 0; rm_byp = 0; rm_drop = 0; rm_term = 0; rm_ep = 0; rm_cm = 0; rm_mac = 0;
    for (int d = 0; d < 2; d++) begin q_hd[d] = 0; q_tl[d] = 0; e_hd[d] = 0; e_tl[d] = 0; dn_exp[d] = 0; end
  endtask

  // transmit: an error on a taken block (the packet's rest is dropped and a
  // nullified MAC block ends it)
  task automatic t_fail(input logic [2:0] c, input logic last);
    experr(0, c, 8'(tm_s));
    tm_act = 0; tm_ep = 0;
    if (last) push(0, 128'h0, 0, K_MAC, 1, 1, tm_cm);
    else begin tm_drop = 1; tm_term = 1; end
  endtask
  task automatic r_fail(input logic [2:0] c, input logic last);
    experr(1, c, rm_id);
    msec[4 + rm_s] = 0;
    rm_act = 0; rm_ep = 0; rm_mac = 0;
    if (last) push(1, 128'h0, 0, K_MAC, 1, 1, rm_cm);
    else begin rm_drop = 1; rm_term = 1; end
  endtask

  always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      m_reset_keys(); m_reset_msgs();
      f_txo <= 0; f_rxo <= 0; f_txe <= 0; f_rxe <= 0; f_kme <= 0; f_txd <= 0; f_rxd <= 0;
      f_slots <= 0; f_cnt <= 0; f_state <= 0; f_kcode <= 0;
      e_age[0] = 0; e_age[1] = 0;
    end else begin
      logic ftxo, frxo, ftxe, frxe, fkme, ftxd, frxd, fsl, fcnt, fst, fkc;
      ftxo = 0; frxo = 0; ftxe = 0; frxe = 0; fkme = 0; ftxd = 0; frxd = 0; fsl = 0; fcnt = 0; fst = 0; fkc = 0;
      c_km = -1; c_tmsg = -1; c_rmsg = -1; c_clr = -1; c_hdr = -1; c_pay = -1;
      c_err[0] = -1; c_err[1] = -1;
      c_ksw = 0; c_trunc = 0; c_tbp = txo_valid && !txo_ready; c_rbp = rxo_valid && !rxo_ready;

      // ---- registers against the model (values of the last clock) ----
      for (int d = 0; d < 2; d++)
        for (int i = 0; i < NSL; i++) begin
          if ((d == 0 ? ktx[256 * i +: 256] : krx[256 * i +: 256]) !== mk[d * NSL + i]) fsl = 1;
          if ((d == 0 ? kv_tx[i] : kv_rx[i]) !== mkv[d * NSL + i]) fsl = 1;
          if (64'(d == 0 ? ctx[CTR_W * i +: CTR_W] : crx[CTR_W * i +: CTR_W]) != 64'(mc[d * NSL + i])) fcnt = 1;
        end
      for (int s = 0; s < NS; s++)
        if (sec_tx[s] !== msec[s] || sec_rx[s] !== msec[4 + s] || ks_tx[s] !== mks[s] || ks_rx[s] !== mks[4 + s])
          fst = 1;

      // ---- outputs against the queues ----
      if (txo_valid && txo_ready) begin
        if (q_hd[0] == q_tl[0]) ftxo = 1;
        else begin
          int h;
          h = q_hd[0] % QD;
          if (txo_data !== q_d[0][h] || txo_bytes !== q_n[0][h] || txo_kind !== q_k[0][h] || txo_last !== q_l[0][h]
              || txo_bad !== q_b[0][h] || txo_cm !== q_c[0][h]) ftxo = 1;
          q_hd[0]++;
        end
      end
      if (rxo_valid && rxo_ready) begin
        if (q_hd[1] == q_tl[1]) frxo = 1;
        else begin
          int h;
          h = q_hd[1] % QD;
          if (rxo_data !== q_d[1][h] || rxo_bytes !== q_n[1][h] || rxo_kind !== q_k[1][h] || rxo_last !== q_l[1][h]
              || rxo_bad !== q_b[1][h] || rxo_cm !== q_c[1][h]) frxo = 1;
          q_hd[1]++;
        end
      end
      // ---- pulses ----
      if (tx_err) begin
        if (e_hd[0] == e_tl[0]) ftxe = 1;
        else begin
          if (tx_code !== e_c[0][e_hd[0] % 8] || 8'(tx_esid) !== e_s[0][e_hd[0] % 8]) ftxe = 1;
          e_hd[0]++;
        end
      end
      if (rx_err) begin
        if (e_hd[1] == e_tl[1]) frxe = 1;
        else begin
          if (rx_code !== e_c[1][e_hd[1] % 8] || rx_eid !== e_s[1][e_hd[1] % 8]) frxe = 1;
          e_hd[1]++;
        end
      end
      if (tx_done) begin if (dn_exp[0] == 0) ftxd = 1; else dn_exp[0]--; end
      if (rx_done) begin if (dn_exp[1] == 0) frxd = 1; else dn_exp[1]--; end

      // ================= transmit =================
      if (t == 4'd0 && tx_valid && !gt_err) begin
        // the engine classifies the offered packet
        int s, k, sub, i;
        logic cont, okst;
        s = int'(tx_sid);
        cont = tm_ep && cm4[s] && s == tm_s;
        okst = en4[s] && (s < NS ? msec[s] : 1'b0);
        if (!tx_ide) tm_byp = 1;
        else if (tm_ep && !cont) begin
          // close the epoch: its MAC goes out now
          push(0, {g_mac(0), 32'h0}, 12, K_MAC, 1, 0, 1);
          dn_exp[0]++;
          tm_ep = 0; c_trunc = 1; c_tmsg = 4;
        end else begin
          logic [2:0] e;
          k = s < NS ? int'(mks[s]) : 0;
          sub = cm4[s] ? 0 : int'(tx_sub);
          i = sl(s, k, sub);
          e = !okst ? 3'd2 : cont ? 3'd0 : !cm4[s] && tx_sub == 2'd3 ? 3'd1 : mc[i] == CMAX ? 3'd4 : 3'd0;
          if (e != 0) begin
            experr(0, e, 8'(s));
            if (e == 3'd4) msec[s] = 0;
            tm_drop = 1; tm_term = cont; tm_ep = 0; tm_s = s; tm_cm = cm4[s];
          end else if (!cont) begin
            g_start(0, mk[i], {s_ivfix[32 * s +: 32], 64'(mc[i])});
            mc[i]++;
            tm_act = 1; tm_cm = cm4[s]; tm_s = s; tm_ph = cm4[s]; tm_hs = 0; tm_hp = 0;
            if (cm4[s]) begin tm_ep = 1; tm_epn = 0; end
            else begin
              logic [31:0] p;
              p = {8'h92, 1'b1, mks[s], 2'b00, tx_sub, 2'b00, s_id[8 * s +: 8], 8'h00};
              push(0, {p, 96'h0}, 4, K_PFX, 0, 0, 0);
              g_aad(0, {p, 96'h0}, 4);
            end
          end else tm_act = 1;
        end
      end
      // a payload block offered after the header: the AAD flush may exceed
      // the GCM limit before the block is taken
      if (tx_valid && !tx_hdr && tm_act && !tm_ph && tm_hs && !tm_drop && g_alen[0] > AMAX) begin
        experr(0, 3'd5, 8'(tm_s));
        tm_act = 0; tm_drop = 1; tm_term = 1;
      end
      if (tx_valid && tx_ready) begin
        logic [127:0] x;
        int n;
        n = int'(tx_bytes);
        x = tx_data & bm(n);
        if (tm_byp) begin
          push(0, tx_data, n, tx_hdr ? K_HDR : K_DATA, tx_last, 0, 0);
          if (tx_last) begin tm_byp = 0; c_tmsg = 5; end
        end else if (tm_drop) begin
          if (tx_last) begin
            tm_drop = 0;
            if (tm_term) push(0, 128'h0, 0, K_MAC, 1, 1, tm_cm);
          end
        end else if (tm_act) begin
          logic bad;
          if (!tm_ph && tx_hdr) begin
            bad = tm_hp || n == 0 || n > 16;
            if (bad) t_fail(3'd1, tx_last);
            else begin
              push(0, x, n, K_HDR, 0, 0, 0);
              c_hdr = n;
              tm_hs = 1; tm_hp = n != 16;
              g_aad(0, x, n);
              if (g_alen[0] - (n > 12 ? n - 12 : 0) > AMAX) t_fail(3'd5, tx_last);
              else if (tx_last) begin
                if (g_alen[0] > AMAX) t_fail(3'd5, 1);
                else begin
                  push(0, {g_mac(0), 32'h0}, 12, K_MAC, 1, 0, 0); dn_exp[0]++;
                  tm_act = 0; c_tmsg = 0;
                end
              end
            end
          end else if (!tm_ph && !tm_hs) t_fail(3'd1, tx_last);
          else begin
            if (!tm_ph && g_alen[0] > AMAX) t_fail(3'd5, tx_last);
            else begin
              tm_ph = 1;
              bad = tx_hdr || n == 0 || n > 16 || n != 16 && (!tx_last || tm_cm);
              if (bad) t_fail(3'd1, tx_last);
              else if (g_clen[0] + n > TMAX) t_fail(3'd5, tx_last);
              else begin
                push(0, g_txt(0, x, n, 0), n, K_DATA, tx_last && tm_cm, 0, tm_cm);
                if (tx_last) begin
                  c_pay = int'(g_clen[0]);
                  if (!tm_cm) begin
                    push(0, {g_mac(0), 32'h0}, 12, K_MAC, 1, 0, 0); dn_exp[0]++;
                    tm_act = 0; c_tmsg = 1 + (n != 16 ? 1 : 0);
                  end else begin
                    tm_epn++;
                    tm_act = 0;
                    if (tm_epn == int'(cagg1)) begin
                      push(0, {g_mac(0), 32'h0}, 12, K_MAC, 1, 0, 1); dn_exp[0]++;
                      tm_ep = 0; c_tmsg = 3;
                    end
                  end
                end
              end
            end
          end
        end
      end

      // ================= receive =================
      if (r == 4'd0 && rx_valid && !gr_err) begin
        int s, k, sub, i;
        logic ide, cont, hit;
        logic [31:0] p;
        p = rx_data[127:96];
        ide = rx_cm || rx_kind == K_PFX;
        cont = rm_ep && rx_cm && int'(rx_sid) == rm_s;
        if (!ide) rm_byp = 1;
        else if (rm_ep && !cont) begin
          experr(1, 3'd1, id4m[8 * rm_s +: 8]);
          msec[4 + rm_s] = 0;
          push(1, 128'h0, 0, K_MAC, 1, 1, 1);
          rm_ep = 0; rm_act = 0; c_trunc = 1;
        end else begin
          logic [2:0] e;
          logic ins;
          ins = 0;
          if (rx_cm) begin
            s = int'(rx_sid);
            k = s < NS ? int'(mks[4 + s]) : 0;
            i = sl(s, k, 0);
            e = rx_kind == K_MAC ? (cont ? 3'd0 : 3'd1) : rx_kind != K_DATA ? 3'd1
              : !(en4[s] && cm4[s] && (s < NS ? msec[4 + s] : 1'b0)) ? 3'd2
              : cont ? (rm_epn == int'(cagg1) ? 3'd1 : 3'd0) : mc[NSL + i] == CMAX ? 3'd4 : 3'd0;
            ins = s < NS;
            rm_id = id4m[8 * s +: 8];
          end else begin
            hit = 0; s = 0;
            for (int j = NS - 1; j >= 0; j--) if (en4[j] && !cm4[j] && s_id[8 * j +: 8] == p[15:8]) begin hit = 1; s = j; end
            k = int'(p[22]); sub = int'(p[19:18]);
            i = sl(s, k, sub);
            e = rx_bytes != 4 || rx_last || p[31:24] != 8'h92 || !p[23] ? 3'd1 : !hit ? 3'd6 : !msec[4 + s] ? 3'd2
              : sub == 3 ? 3'd1 : !mkv[NSL + i] ? 3'd3 : mc[NSL + i] == CMAX ? 3'd4 : 3'd0;
            ins = hit && !(rx_bytes != 4 || rx_last || p[31:24] != 8'h92 || !p[23]);
            rm_id = p[15:8];
          end
          if (e != 0) begin
            experr(1, e, rm_id);
            if (ins) msec[4 + s] = 0;
            rm_drop = 1; rm_term = cont; rm_ep = 0; rm_cm = rx_cm; rm_s = s;
          end else if (rx_cm) begin
            rm_s = s; rm_cm = 1; rm_act = 1;
            if (rx_kind == K_MAC) rm_mac = 1;
            else if (!cont) begin
              g_start(1, mk[NSL + i], {s_ivfix[32 * s +: 32], 64'(mc[NSL + i])});
              mc[NSL + i]++;
              rm_ep = 1; rm_epn = 0; rm_ph = 1;
            end
          end else begin
            if (mks[4 + s] != p[22]) c_ksw = 1;
            mks[4 + s] = p[22];
            g_start(1, mk[NSL + i], {s_ivfix[32 * s +: 32], 64'(mc[NSL + i])});
            mc[NSL + i]++;
            g_aad(1, {p, 96'h0}, 4);
            rm_s = s; rm_cm = 0; rm_act = 1; rm_ph = 0; rm_hs = 0; rm_hp = 0; rm_dp = 0; rm_mac = 0; rm_hn = 0;
            rm_drop = 0; rm_byp = 0;
            // the prefix block is taken in this clock: not a message block
          end
        end
      end
      if (rx_valid && rx_kind != K_HDR && rx_kind != K_PFX && rm_act && !rm_ph && rm_hs && !rm_drop && !rm_mac
          && g_alen[1] > AMAX && r != 4'd0) begin
        experr(1, 3'd5, rm_id);
        msec[4 + rm_s] = 0;
        rm_act = 0; rm_drop = 1; rm_term = 1;
      end
      if (rx_valid && rx_ready && !(r == 4'd0 && !rx_cm)) begin
        logic [127:0] x;
        int n;
        n = int'(rx_bytes);
        x = rx_data & bm(n);
        if (rm_byp) begin
          push(1, rx_data, n, rx_kind == K_HDR ? K_HDR : K_DATA, rx_last, 0, 0);
          if (rx_last) begin rm_byp = 0; c_rmsg = 5; end
        end else if (rm_drop) begin
          if (rx_last) begin
            rm_drop = 0;
            if (rm_term) push(1, 128'h0, 0, K_MAC, 1, 1, rm_cm);
          end
        end else if (rm_act) begin
          logic is_mac;
          is_mac = rm_mac || rx_kind == K_MAC && !rm_cm && (rm_ph || rm_hs);
          if (!rm_ph && !is_mac) begin
            if (rx_kind == K_HDR) begin
              if (rm_hp || n == 0 || n > 16 || rx_last) r_fail(3'd1, rx_last);
              else begin
                push(1, x, n, K_HDR, 0, 0, 0);
                rm_hs = 1; rm_hp = n != 16;
                g_aad(1, x, n);
                if (g_alen[1] - (n > 12 ? n - 12 : 0) > AMAX) r_fail(3'd5, rx_last);
              end
            end else if (rx_kind == K_PFX || !rm_hs) r_fail(3'd1, rx_last);
            else if (g_alen[1] > AMAX) r_fail(3'd5, rx_last);
            else begin
              rm_ph = 1;
              if (rx_kind != K_DATA || n == 0 || n > 16 || rx_last) r_fail(3'd1, rx_last);
              else if (n != 16) begin rm_hd = x; rm_hn = n; rm_dp = 1; end
              else if (g_clen[1] + n > TMAX) r_fail(3'd5, rx_last);
              else push(1, g_txt(1, x, n, 1), n, K_DATA, 0, 0, 0);
            end
          end else if (is_mac) begin
            if (!rm_ph && g_alen[1] > AMAX) r_fail(3'd5, rx_last);
            else if (n != 12 || !rx_last) r_fail(3'd1, rx_last);
            else if (g_clen[1] + rm_hn > TMAX) r_fail(3'd5, 1);
            else begin
              logic [95:0] m;
              logic ok;
              if (rm_dp) push(1, g_txt(1, rm_hd, rm_hn, 1), rm_hn, K_DATA, 0, 0, 0);
              m = g_mac(1);
              ok = m == rx_data[127:32];
              push(1, 128'h0, 0, K_MAC, 1, !ok, rm_cm);
              if (ok) dn_exp[1]++;
              else begin experr(1, 3'd7, rm_id); msec[4 + rm_s] = 0; end
              c_rmsg = {rm_cm, ok} + 0;
              rm_act = 0; rm_ep = 0; rm_mac = 0; rm_dp = 0; rm_hn = 0;
            end
          end else begin
            // payload / flit blocks
            if (rm_cm ? rx_kind != K_DATA || n != 16 : rx_kind != K_DATA || n == 0 || n > 16 || rm_dp || rx_last)
              r_fail(3'd1, rx_last);
            else if (!rm_cm && n != 16) begin rm_hd = x; rm_hn = n; rm_dp = 1; end
            else if (g_clen[1] + n > TMAX) r_fail(3'd5, rx_last);
            else begin
              push(1, g_txt(1, x, n, 1), n, K_DATA, rx_last && rm_cm, 0, rm_cm);
              if (rm_cm && rx_last) begin rm_epn++; rm_act = 0; end
            end
          end
        end
      end

      // ================= key management =================
      begin
        int d, s, b, i;
        logic [2:0] e;
        logic full, use_;
        d = km_dir ? 1 : 0; s = int'(km_sid);
        b = d * NSL + (s < NS ? sl(s, int'(km_ks), 0) : 0);
        i = b + int'(km_sub);
        full = s < NS && mkv[b] && (cm4[s] || mkv[b + 1] && mkv[b + 2]);
        use_ = s < NS && msec[d * 4 + s] && mks[d * 4 + s] == km_ks;
        e = km_prog ? (s >= NS || km_sub == 2'd3 ? 3'd1 : km_sel && !sl_valid ? 3'd3 : use_ ? 3'd4 : 3'd0)
          : km_go ? (s >= NS ? 3'd1 : !full ? 3'd2 : 3'd0)
          : km_stop ? (s >= NS ? 3'd1 : 3'd0) : 3'd0;
        if (km_prog || km_go || km_stop) c_km = (km_prog ? 0 : km_go ? 1 : 2) * 8 + int'(e);
        if (e != 0) ;
        else if (km_prog) begin mk[i] = km_sel ? sl_key : km_key; mkv[i] = 1; mc[i] = 1; end
        else if (km_go) begin msec[d * 4 + s] = 1; mks[d * 4 + s] = km_ks; end
        else if (km_stop) begin
          for (int j = 0; j < 3; j++) begin mk[b + j] = 0; mkv[b + j] = 0; mc[b + j] = 0; end
          if (use_) msec[d * 4 + s] = 0;
        end
        // km_err / km_code one clock later
        f_kme <= km_err !== m_kerr_q;
        f_kcode <= km_err && km_code !== m_kcode_q;
        m_kerr_q <= e != 0;
        if (e != 0) m_kcode_q <= e;
      end
      if (clr) begin
        c_clr = (tm_act || tm_ep ? 1 : 0) + (rm_act || rm_ep ? 2 : 0);
        m_reset_keys();
        tm_act = 0; tm_byp = 0; tm_drop = 0; tm_ep = 0; rm_act = 0; rm_byp = 0; rm_drop = 0; rm_ep = 0; rm_mac = 0;
        rm_dp = 0; rm_hn = 0;
        q_hd[0] = q_tl[0]; q_hd[1] = q_tl[1]; dn_exp[0] = 0; dn_exp[1] = 0;
      end
      for (int d = 0; d < 2; d++) e_age[d] = e_hd[d] != e_tl[d] ? e_age[d] + 1 : 0;
      f_txo <= ftxo; f_rxo <= frxo; f_txe <= ftxe; f_rxe <= frxe; f_txd <= ftxd; f_rxd <= frxd;
      f_slots <= fsl; f_cnt <= fcnt; f_state <= fst;
    end
  end

  // output waiting: an expected block must appear within a bound once the
  // output is free
  int w_tx, w_rx;
  always @(posedge clk or negedge rst_n)
    if (!rst_n) begin w_tx <= 0; w_rx <= 0; end
    else begin
      w_tx <= q_hd[0] != q_tl[0] && !txo_valid ? w_tx + 1 : 0;
      w_rx <= q_hd[1] != q_tl[1] && !rxo_valid ? w_rx + 1 : 0;
    end

  // ---------------- assertions ----------------
  `SVA_INV(a_tx_output, !f_txo)
  `SVA_INV(a_rx_output, !f_rxo)
  `SVA_INV(a_tx_error, !f_txe)
  `SVA_INV(a_rx_error, !f_rxe)
  `SVA_INV(a_tx_done, !f_txd)
  `SVA_INV(a_rx_done, !f_rxd)
  `SVA_INV(a_km_error, !f_kme)
  `SVA_INV(a_km_code, !f_kcode)
  `SVA_INV(a_key_slots, !f_slots)
  `SVA_INV(a_counters, !f_cnt)
  `SVA_INV(a_stream_state, !f_state)
  `SVA_INV(a_tx_error_in_time, e_age[0] <= 64)
  `SVA_INV(a_rx_error_in_time, e_age[1] <= 64)
  `SVA_INV(a_tx_output_in_time, w_tx <= 80)
  `SVA_INV(a_rx_output_in_time, w_rx <= 80)
  `SVA_IMP(a_txo_hold, txo_valid && !txo_ready && !clr, ##1 txo_valid && $stable(txo_data) && $stable(txo_bytes)
                                                      && $stable(txo_kind) && $stable(txo_last) && $stable(txo_bad))
  `SVA_IMP(a_rxo_hold, rxo_valid && !rxo_ready && !clr, ##1 rxo_valid && $stable(rxo_data) && $stable(rxo_bytes)
                                                      && $stable(rxo_kind) && $stable(rxo_last) && $stable(rxo_bad))
  `SVA_IMP(a_busy_tx, t != 4'd0, tx_busy)
  `SVA_IMP(a_busy_rx, r != 4'd0, rx_busy)
  `SVA_IMP(a_mac_bytes, txo_valid && txo_kind == K_MAC, txo_last && (txo_bad ? txo_bytes == 0 : txo_bytes == 12))
  `SVA_IMP(a_end_block, rxo_valid && rxo_kind == 2'd2 && !rxo_last, 1'b0)
  `SVA_IMP(a_clr_clears, clr, ##1 kv_tx == 0 && kv_rx == 0 && sec_tx == 0 && sec_rx == 0 && ktx == 0 && krx == 0
                              && !txo_valid && !rxo_valid)
  `SVA_RST(a_reset, 1'b1, !txo_valid && !rxo_valid && kv_tx == 0 && kv_rx == 0 && sec_tx == 0 && sec_rx == 0
                        && !tx_err && !rx_err && !km_err && !tx_busy && !rx_busy)

  // ---------------- functional coverage ----------------
  int s_tm, s_rm, s_km, s_te, s_re, s_clr, s_hdr, s_pay;
  logic s_ksw, s_trunc;
  always @(posedge clk) begin
    s_tm <= c_tmsg; s_rm <= c_rmsg; s_km <= c_km; s_te <= c_err[0]; s_re <= c_err[1]; s_clr <= c_clr;
    s_hdr <= c_hdr; s_pay <= c_pay; s_ksw <= c_ksw; s_trunc <= c_trunc;
  end
  covergroup cg_ide @(negedge clk);
    option.per_instance = 1;
    // transmit messages: header only, full / partial payload, epoch closed early / full, bypass
    cp_tmsg: coverpoint s_tm iff (s_tm >= 0) {
      bins hdr_only = {0}; bins pay_full = {1}; bins pay_part = {2}; bins epoch_full = {3}; bins epoch_trunc = {4};
      bins bypass = {5};
    }
    // receive messages: TLP bad / good MAC, cachemem bad / good, bypass
    cp_rmsg: coverpoint s_rm iff (s_rm >= 0) {
      bins tlp_bad = {0}; bins tlp_ok = {1}; bins cm_bad = {2}; bins cm_ok = {3}; bins bypass = {5};
    }
    // key management: op x code
    cp_km: coverpoint s_km iff (s_km >= 0) {
      bins prog_ok = {0}; bins prog_bad = {1}; bins prog_sl = {3}; bins prog_use = {4};
      bins go_ok = {8}; bins go_bad = {9}; bins go_part = {10};
      bins stop_ok = {16}; bins stop_bad = {17};
    }
    cp_terr: coverpoint s_te iff (s_te >= 0) { bins fmt = {1}; bins state = {2}; bins ctr = {4}; bins len = {5}; }
    cp_rerr: coverpoint s_re iff (s_re >= 0) {
      bins fmt = {1}; bins state = {2}; bins key = {3}; bins ctr = {4}; bins len = {5}; bins sid = {6}; bins mac = {7};
    }
    cp_clr: coverpoint s_clr iff (s_clr >= 0) { bins idle = {0}; bins tx = {1}; bins rx = {2}; bins both = {3}; }
    // header block sizes and payload length classes
    cp_hdr: coverpoint s_hdr iff (s_hdr >= 0) { bins dw3 = {12}; bins dw4 = {16}; bins small_ = {[1:11]}; bins odd = {13, 14, 15}; }
    cp_pay: coverpoint s_pay iff (s_pay >= 0) { bins one_block = {[1:16]}; bins few = {[17:64]}; bins many = {[65:$]}; }
  endgroup
  cg_ide u_cg_ide = new;

  `FC(rx_key_switch, s_ksw)
  `FC(tx_back_pressure, txo_valid && !txo_ready)
  `FC(rx_back_pressure, rxo_valid && !rxo_ready)
  `FC(rx_epoch_aborted, s_trunc && s_re == 1)
  `FC(both_busy, tx_busy && rx_busy)
  `FC(tx_input_stall, tx_valid && !tx_ready && t == 4'd2)
  `FC(rx_input_stall, rx_valid && !rx_ready && r == 4'd1)
  `FC(km_and_traffic, (km_prog || km_go || km_stop) && tx_busy)
  `FC_RST(reset_while_busy, rst_n && (tx_busy || rx_busy) ##1 !rst_n)
endmodule

bind PCIe_CXL_IDE_top PCIe_CXL_IDE_sva #(.NS(NS), .CTR_W(CTR_W), .LEN_W(LEN_W)) u_sva (.*);
