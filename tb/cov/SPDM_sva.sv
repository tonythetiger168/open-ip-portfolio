// SPDX-License-Identifier: Apache-2.0
// SPDM: concurrent SVA against a model built from the ports, plus
// functional coverage. The model
//  * has its own SHA3-384 (Keccak-f[1600] from FIPS 202: round constants
//    from the rc(t) LFSR, rho offsets from the (x, y) walk) and keeps the
//    VCA, M1 and L1 transcripts as byte queues, so the certificate chain
//    digest, the measurement summary hashes and every transcript hash are
//    recomputed independently of the three SHA3 engines;
//  * shadows the certificate chain and measurement stores from the st_*
//    pins and decides every request itself from DSP0274 1.2 (the error code
//    and its order, the connection state, the negotiated algorithms, the
//    requester's DataTransferSize), building the whole expected response:
//    every byte but the signature, with the responder nonce taken from the
//    random words the core accepted;
//  * shadows the ML-DSA buffer from the host-port pins and checks, when an
//    operation starts, that the buffer holds the seed (KeyGen) or M' =
//    0, 0, the combined SPDM prefix and the transcript hash, and rnd (Sign);
//    that the seed is wiped after KeyGen and the key area after clr;
//  * checks the handshakes (response hold under back-pressure, no response
//    byte outside a response, no random word taken outside a nonce / rnd
//    fetch, the public-key stream length), the done / error pulses,
//    err_code, conn, key_ok, cmd_err and the clr abort (nothing more is sent
//    after the clock of clr; the connection and the key are gone once the
//    core is idle again).
`include "cov_macros.svh"
module SPDM_sva #(parameter int NM = 4, parameter int CC_AW = 14) (
  input logic              clk, rst_n,
  input logic [7:0]        ct_exp,
  input logic [31:0]       asym_id,
  input logic [1:0]        pset,
  input logic [CC_AW:0]    cc_len,
  input logic [NM-1:0]     m_en, m_tcb,
  input logic [NM*8-1:0]   m_type,
  input logic              st_we, st_sel,
  input logic [CC_AW-3:0]  st_addr,
  input logic [31:0]       st_data,
  input logic              kg_start, kg_sel, sl_valid, pk_open, clr,
  input logic [255:0]      seed, sl_seed,
  input logic              pk_valid, pk_last, pk_ready,
  input logic [31:0]       pk_data,
  input logic              rn_valid, rn_ready,
  input logic [31:0]       rn_data,
  input logic              rq_valid, rq_last, rq_ready,
  input logic [7:0]        rq_data,
  input logic              rs_valid, rs_last, rs_ready,
  input logic [7:0]        rs_data,
  input logic              busy, key_ok, rsp_done, rsp_err, kg_done, cmd_err,
  input logic [1:0]        conn, key_pset,
  input logic [7:0]        err_code,
  // internal: the ML-DSA engine's host port and controls
  input logic              hp_load, hw_valid, hw_ready, hr_valid, hr_ready,
  input logic [12:0]       hp_addr,
  input logic [31:0]       hw_data, hr_data,
  input logic              ml_start, ml_done, ml_busy,
  input logic [1:0]        ml_op,
  input logic [4:0]        st
);
  `COV_CLOCKING(clk, !rst_n)

  // ---------------- SHA3-384 from FIPS 202 ----------------
  logic [63:0] rcs [0:23];
  int          roff [0:24];
  function automatic bit rc_bit(input int t);
    bit r [0:8];
    for (int k = 0; k < 9; k++) r[k] = (k == 0);
    for (int i = 1; i <= t % 255; i++) begin
      for (int k = 8; k > 0; k--) r[k] = r[k - 1];
      r[0] = 1'b0;
      r[0] ^= r[8]; r[4] ^= r[8]; r[5] ^= r[8]; r[6] ^= r[8];
    end
    return r[0];
  endfunction
  initial begin
    int x, y, nx;
    for (int ir = 0; ir < 24; ir++) begin
      rcs[ir] = '0;
      for (int j = 0; j <= 6; j++) rcs[ir][(1 << j) - 1] = rc_bit(j + 7 * ir);
    end
    roff[0] = 0;
    x = 1; y = 0;
    for (int t = 0; t < 24; t++) begin
      roff[x + 5 * y] = ((t + 1) * (t + 2) / 2) % 64;
      nx = y; y = (2 * x + 3 * y) % 5; x = nx;
    end
  end
  function automatic logic [63:0] rot(input logic [63:0] v, input int n);
    return n == 0 ? v : (v << n) | (v >> (64 - n));
  endfunction
  function automatic logic [1599:0] keccak(input logic [1599:0] a);
    logic [63:0] s [0:24];
    logic [63:0] b [0:24];
    logic [63:0] c [0:4];
    logic [63:0] d;
    for (int i = 0; i < 25; i++) s[i] = a[64 * i +: 64];
    for (int ir = 0; ir < 24; ir++) begin
      for (int x = 0; x < 5; x++) c[x] = s[x] ^ s[x + 5] ^ s[x + 10] ^ s[x + 15] ^ s[x + 20];
      for (int x = 0; x < 5; x++) begin
        d = c[(x + 4) % 5] ^ rot(c[(x + 1) % 5], 1);
        for (int y = 0; y < 5; y++) s[x + 5 * y] ^= d;
      end
      for (int x = 0; x < 5; x++)
        for (int y = 0; y < 5; y++) b[y + 5 * ((2 * x + 3 * y) % 5)] = rot(s[x + 5 * y], roff[x + 5 * y]);
      for (int x = 0; x < 5; x++)
        for (int y = 0; y < 5; y++) s[x + 5 * y] = b[x + 5 * y] ^ (~b[(x + 1) % 5 + 5 * y] & b[(x + 2) % 5 + 5 * y]);
      s[0] ^= rcs[ir];
    end
    for (int i = 0; i < 25; i++) keccak[64 * i +: 64] = s[i];
  endfunction
  // SHA3-384 (rate 104 bytes) of the module-level queue hq; digest byte i at [8i +: 8]
  byte unsigned hq [$];
  function automatic logic [383:0] sha3_hq();
    logic [1599:0] s;
    int n, nb;
    logic [7:0] v;
    s = '0;
    n = hq.size();
    nb = n / 104 + 1;
    for (int blk = 0; blk < nb; blk++) begin
      for (int i = 0; i < 104; i++) begin
        int p;
        p = blk * 104 + i;
        v = p < n ? 8'(hq[p]) : 8'h00;
        if (p == n) v = v | 8'h06;
        if (i == 103 && blk == nb - 1) v = v | 8'h80;
        s[8 * i +: 8] ^= v;
      end
      s = keccak(s);
    end
    return s[383:0];
  endfunction

  // ---------------- shadows ----------------
  localparam int CCW = 1 << (CC_AW - 2);
  logic [31:0] ccs [0:CCW-1];
  logic [31:0] mvs [0:NM*12-1];
  logic [31:0] mls [0:8191];             // ML-DSA buffer words written
  logic [12:0] hptr;
  always @(posedge clk) begin
    if (st_we && !st_sel) ccs[st_addr] = st_data;
    if (st_we && st_sel && (st_addr >> 4) < NM && st_addr[3:0] < 4'd12) mvs[(st_addr >> 4) * 12 + st_addr[3:0]] = st_data;
  end
  always @(posedge clk or negedge rst_n) begin
    if (!rst_n) hptr <= '0;
    else begin
      if (hw_valid && hw_ready) mls[hptr] <= hw_data;
      if (hp_load) hptr <= hp_addr;
      else if (hw_valid && hw_ready || hr_valid && hr_ready) hptr <= hptr + 13'd1;
    end
  end
  function automatic logic [7:0] ccb(input int i);
    return 8'(ccs[i / 4] >> (8 * (i % 4)));
  endfunction
  function automatic logic [7:0] mbb(input int s, input int j);   // byte j of measurement block s
    case (j)
      0: return 8'(s + 1);
      1: return 8'h01;
      2: return 8'd51;
      3: return 8'h00;
      4: return m_type[8 * s +: 8];
      5: return 8'd48;
      6: return 8'h00;
      default: return 8'(mvs[s * 12 + (j - 7) / 4] >> (8 * ((j - 7) % 4)));
    endcase
  endfunction

  // ---------------- protocol model ----------------
  function automatic int slen(input logic [1:0] p);
    return p == 2'd0 ? 2420 : p == 2'd1 ? 3309 : 4627;
  endfunction
  localparam int DTS = (8 + 55 * NM + 34 + 4627) > 4761 ? (8 + 55 * NM + 34 + 4627) : 4761;
  byte unsigned rq [$];                  // request being received
  byte unsigned vcaq [$], tmq [$], tlq [$];
  byte unsigned obs [$];                 // response bytes sent
  logic [7:0]  exp [0:8191];
  int          e_n, e_sig, e_non;        // length, first signature byte, nonce offset (-1: none)
  int          ridx;
  logic        m_act;                    // a response is expected / being sent
  logic        m_sent;                   // ... all of it was sent, rsp_done due
  logic        m_iserr, m_sgn, m_cm, m_vca, m_tm, m_tl, m_rstv;
  logic [7:0]  m_ecode;
  logic [1:0]  m_conn;
  logic        m_hash, m_asym, m_meas;
  int          m_dts;
  logic        m_key;
  logic [1:0]  m_kps;
  logic        m_drain, m_clr, m_rx;
  int          rn_need, rn_got;
  logic [31:0] rnw [0:15];
  logic [383:0] m_h;                     // transcript hash of the signed response
  logic [255:0] m_seed;
  int          pk_n, pk_cnt;
  logic        m_kg, m_pk;               // KeyGen / public-key readout running
  // check results (one-clock flags)
  logic        f_sign_bad, f_kg_bad, f_wipe_bad, f_xi_bad, f_rn_extra, f_rn_left;
  int          sdone_wait;
  // coverage classes, set when a request is decided (-1 otherwise)
  int          c_code, c_err;
  logic [7:0]  v_code, v_p2;
  logic        v_sig, v_clip_dts, v_clip_rem, v_clip_len, v_zero, v_tcb0, v_ms;

  function automatic logic [7:0] q(input int i);
    return i < rq.size() ? 8'(rq[i]) : 8'h00;
  endfunction
  function automatic int popc(input logic [NM-1:0] m);
    int n;
    n = 0;
    for (int i = 0; i < NM; i++) n += int'(m[i]);
    return n;
  endfunction

  // the error code of the request in rq (0: none)
  function automatic logic [7:0] decide();
    int n, a, e, len, off, nb;
    logic [7:0] c, ver, p1, p2;
    logic cr, slot, s;
    logic [31:0] dts, msz;
    n = rq.size();
    if (n > 128 || n < 4) return 8'h01;
    ver = q(0); c = q(1); p1 = q(2); p2 = q(3);
    if (c == 8'h84) return ver != 8'h10 ? 8'h41 : n != 4 ? 8'h01 : 8'h00;
    if (!(c == 8'hE1 || c == 8'hE3 || c == 8'h81 || c == 8'h82 || c == 8'h83 || c == 8'hE0)) return 8'h07;
    if (m_conn == 2'd0) return 8'h04;
    if (ver != 8'h12) return 8'h41;
    cr = m_conn == 2'd3 && m_hash && m_asym;
    slot = cc_len != '0 && m_key;
    case (c)
      8'hE1: begin
        if (m_conn != 2'd1) return 8'h04;
        dts = {q(15), q(14), q(13), q(12)}; msz = {q(19), q(18), q(17), q(16)};
        return n != 20 || dts < 42 || msz < dts ? 8'h01 : 8'h00;
      end
      8'hE3: begin
        if (m_conn != 2'd2) return 8'h04;
        len = int'({q(5), q(4)}); a = int'(q(28)); e = int'(q(29));
        return n < 32 || len != n || a + e > 20 || len < 32 + 4 * (a + e) ? 8'h01 : 8'h00;
      end
      default: ;
    endcase
    if (!cr) return 8'h04;
    case (c)
      8'h81: return n != 4 ? 8'h01 : slot && m_dts < 52 ? 8'h0D : 8'h00;
      8'h82: begin
        off = int'({q(5), q(4)});
        return n != 8 || p1[3:0] != 0 || !slot || off >= int'(cc_len) ? 8'h01 : 8'h00;
      end
      8'h83: begin
        if (n != 36 || p1 != 0 || !slot || !(p2 == 0 || p2 == 1 || p2 == 8'hFF)) return 8'h01;
        return 86 + (p2 != 0 ? 48 : 0) + slen(m_kps) > m_dts ? 8'h0D : 8'h00;
      end
      default: begin
        if (!m_meas) return 8'h07;
        s = p1[0];
        if (n != (s ? 37 : 4)) return 8'h01;
        if (!(p2 == 0 || p2 == 8'hFF || (int'(p2) <= NM && m_en[int'(p2) - 1]))) return 8'h01;
        if (s && (q(36) != 0 || !slot)) return 8'h01;
        nb = p2 == 0 ? 0 : p2 == 8'hFF ? popc(m_en) : 1;
        return 42 + 55 * nb + (s ? slen(m_kps) : 0) > m_dts ? 8'h0D : 8'h00;
      end
    endcase
  endfunction

  task automatic put(input logic [7:0] b);
    exp[e_n] = b; e_n++;
  endtask
  task automatic put16(input int v);
    put(8'(v)); put(8'(v >> 8));
  endtask
  task automatic put_dig(input logic [383:0] d);
    for (int i = 0; i < 48; i++) put(d[8 * i +: 8]);
  endtask
  task automatic hq_blocks(input logic [NM-1:0] m);
    for (int s = 0; s < NM; s++) if (m[s]) for (int j = 0; j < 55; j++) hq.push_back(mbb(s, j));
  endtask

  // build the expected response to the request in rq, update the model state
  task automatic respond();
    logic [7:0] e, c, p1, p2;
    int n, off, len, av, por, a;
    logic [31:0] dts;
    logic hit;
    logic [NM-1:0] mk;
    e = decide();
    n = rq.size();
    c = q(1); p1 = q(2); p2 = q(3);
    e_n = 0; e_non = -1; ridx = 0; m_sgn = 1'b0; m_vca = 1'b0; m_tm = 1'b0; m_tl = 1'b0; m_rstv = 1'b0;
    m_iserr = e != 0; m_ecode = e; rn_need = 0; rn_got = 0;
    obs.delete();
    c_code = c == 8'h84 ? 0 : c == 8'hE1 ? 1 : c == 8'hE3 ? 2 : c == 8'h81 ? 3 : c == 8'h82 ? 4 :
             c == 8'h83 ? 5 : c == 8'hE0 ? 6 : 7;
    if (n < 2) c_code = 7;
    c_err = e == 0 ? 0 : e == 8'h01 ? 1 : e == 8'h04 ? 2 : e == 8'h07 ? 3 : e == 8'h0D ? 4 : 5;
    v_code = c; v_p2 = p2; v_sig = 1'b0;
    v_clip_dts = 1'b0; v_clip_rem = 1'b0; v_clip_len = 1'b0; v_zero = 1'b0; v_tcb0 = 1'b0; v_ms = 1'b0;
    if (e != 0) begin
      put((m_conn == 2'd0 || c == 8'h84 || n < 2) ? 8'h10 : 8'h12);
      put(8'h7F); put(e); put(e == 8'h07 ? c : 8'h00);
    end else begin
      put(c == 8'h84 ? 8'h10 : 8'h12); put(c & 8'h7F);
      case (c)
        8'h84: begin
          put(0); put(0); put(0); put(1); put(8'h00); put(8'h12);
          m_conn = 2'd1; m_hash = 1'b0; m_asym = 1'b0; m_meas = 1'b0;
          m_rstv = 1'b1; m_vca = 1'b1;
        end
        8'hE1: begin
          put(0); put(0); put(0); put(ct_exp); put(0); put(0);
          put(8'h16); put(0); put(0); put(0);
          put16(DTS); put(0); put(0); put16(DTS); put(0); put(0);
          dts = {q(15), q(14), q(13), q(12)};
          m_dts = dts < DTS ? int'(dts) : DTS;
          m_conn = 2'd2; m_vca = 1'b1;
        end
        8'hE3: begin
          a = int'(q(28));
          hit = 1'b0;
          for (int i = 0; i < a; i++) if ({q(35 + 4 * i), q(34 + 4 * i), q(33 + 4 * i), q(32 + 4 * i)} == asym_id) hit = 1'b1;
          m_hash = q(12)[4]; m_asym = hit; m_meas = q(6)[0];
          put(0); put(0); put16(hit ? 40 : 36);
          put({7'd0, m_meas}); put(0); put(m_meas ? 8'h20 : 8'h00); put(0); put(0); put(0);
          for (int i = 0; i < 4; i++) put(0);
          put(m_hash ? 8'h10 : 8'h00); put(0); put(0); put(0);
          for (int i = 0; i < 12; i++) put(0);
          put({7'd0, hit}); put(0); put(0); put(0);
          if (hit) for (int i = 0; i < 4; i++) put(asym_id[8 * i +: 8]);
          m_conn = 2'd3; m_vca = 1'b1;
        end
        8'h81: begin
          put(0); put({7'd0, cc_len != '0 && m_key});
          if (cc_len != '0 && m_key) begin
            hq.delete();
            for (int i = 0; i < int'(cc_len); i++) hq.push_back(ccb(i));
            put_dig(sha3_hq());
          end
          m_tm = 1'b1;
        end
        8'h82: begin
          off = int'({q(5), q(4)}); len = int'({q(7), q(6)});
          av = int'(cc_len) - off;
          por = len < av ? len : av;
          v_clip_len = len < av && len <= m_dts - 8;
          v_clip_rem = av <= len && av <= m_dts - 8;
          v_clip_dts = por > m_dts - 8;
          if (por > m_dts - 8) por = m_dts - 8;
          v_zero = por == 0;
          put(0); put(0); put16(por); put16(av - por);
          for (int i = 0; i < por; i++) put(ccb(off + i));
          m_tm = 1'b1;
        end
        8'h83: begin
          put(0); put(1);
          hq.delete();
          for (int i = 0; i < int'(cc_len); i++) hq.push_back(ccb(i));
          put_dig(sha3_hq());
          e_non = e_n; for (int i = 0; i < 32; i++) put(0);
          if (p2 != 0) begin
            mk = p2 == 8'h01 ? m_en & m_tcb : m_en;
            v_tcb0 = mk == '0; v_ms = 1'b1;
            hq.delete(); hq_blocks(mk);
            put_dig(sha3_hq());
          end
          put(0); put(0);
          m_sgn = 1'b1; m_cm = 1'b0; m_tm = 1'b1; rn_need = 16;
        end
        default: begin
          v_sig = p1[0];
          mk = p2 == 0 ? '0 : p2 == 8'hFF ? m_en : NM'(1) << (int'(p2) - 1);
          put(p2 == 0 ? 8'(popc(m_en)) : 8'h00); put(0);
          put(8'(popc(mk))); put16(55 * popc(mk)); put(0);
          for (int s = 0; s < NM; s++) if (mk[s]) for (int j = 0; j < 55; j++) put(mbb(s, j));
          e_non = e_n; for (int i = 0; i < 32; i++) put(0);
          put(0); put(0);
          m_sgn = p1[0]; m_cm = 1'b1; m_tl = 1'b1; rn_need = p1[0] ? 16 : 8;
        end
      endcase
    end
    e_sig = e_n;
    if (m_sgn) e_n += slen(m_kps);
    if (m_rstv) vcaq.delete();
    if (m_rstv) begin tmq.delete(); tlq.delete(); end
    m_act = 1'b1;
  endtask

  // the expected response byte at ridx (the nonce from the random words)
  logic [7:0] e_byte;
  always_comb begin
    e_byte = exp[ridx_q[12:0]];
    if (e_non >= 0 && ridx_q >= e_non && ridx_q < e_non + 32)
      e_byte = 8'(rnw[(ridx_q - e_non) / 4] >> (8 * ((ridx_q - e_non) % 4)));
  end

  function automatic logic [7:0] mp(input int k);
    logic [127:0] pre;
    logic [255:0] sc;
    logic [239:0] sm;
    pre = "dmtf-spdm-v1.2.*";
    sc = "responder-challenge_auth signing";
    sm = "responder-measurements signing";
    if (k < 2) return 8'h00;
    if (k < 66) return pre[127 - 8 * ((k - 2) % 16) -: 8];
    if (k < 102) begin
      if (!m_cm) return k - 66 < 4 ? 8'h00 : sc[255 - 8 * (k - 70) -: 8];
      return k - 66 < 6 ? 8'h00 : sm[239 - 8 * (k - 72) -: 8];
    end
    if (k < 150) return m_h[8 * (k - 102) +: 8];
    return 8'h00;
  endfunction

  logic        clr_seen;                  // clr in this clock (the abort follows)
  logic        busy_q;
  always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      rq.delete(); vcaq.delete(); tmq.delete(); tlq.delete(); obs.delete();
      m_act = 1'b0; m_sent = 1'b0; m_conn = '0; m_hash = 1'b0; m_asym = 1'b0; m_meas = 1'b0; m_dts = 0;
      m_key = 1'b0; m_kps = '0; m_drain = 1'b0; m_clr = 1'b0; m_rx = 1'b0; rn_need = 0; rn_got = 0;
      m_iserr = 1'b0; m_ecode = '0; m_sgn = 1'b0; m_cm = 1'b0; e_n = 0; e_sig = 0; e_non = -1; ridx = 0;
      m_kg = 1'b0; m_pk = 1'b0; pk_n = 0; pk_cnt = 0; m_seed = '0; m_h = '0; sdone_wait = 0;
      f_sign_bad = 1'b0; f_kg_bad = 1'b0; f_wipe_bad = 1'b0; f_xi_bad = 1'b0; f_rn_extra = 1'b0; f_rn_left = 1'b0;
      c_code = -1; c_err = -1;
      for (int i = 0; i < 16; i++) rnw[i] = '0;
    end else begin
      f_sign_bad = 1'b0; f_kg_bad = 1'b0; f_wipe_bad = 1'b0; f_xi_bad = 1'b0; f_rn_extra = 1'b0; f_rn_left = 1'b0;
      c_code = -1; c_err = -1;
      clr_seen = clr;
      // random words
      if (rn_valid && rn_ready) begin
        if (rn_got >= rn_need) f_rn_extra = 1'b1;
        else rnw[rn_got] = rn_data;
        rn_got++;
      end
      // response bytes
      if (rs_valid && rs_ready && m_act) begin
        obs.push_back(rs_data);
        ridx++;
        if (ridx == e_sig && m_sgn) begin
          hq.delete();
          for (int i = 0; i < vcaq.size(); i++) hq.push_back(vcaq[i]);
          if (!m_cm) for (int i = 0; i < tmq.size(); i++) hq.push_back(tmq[i]);
          else for (int i = 0; i < tlq.size(); i++) hq.push_back(tlq[i]);
          for (int i = 0; i < rq.size(); i++) hq.push_back(rq[i]);
          for (int i = 0; i < obs.size(); i++) hq.push_back(obs[i]);
          m_h = sha3_hq();
        end
        if (ridx == e_n) begin
          m_act = 1'b0; m_sent = 1'b1;
          if (!m_iserr) begin
            if (m_sgn) begin
              if (m_cm) tlq.delete(); else tmq.delete();
            end else begin
              for (int i = 0; i < rq.size(); i++) begin
                if (m_vca) vcaq.push_back(rq[i]);
                if (m_tm) tmq.push_back(rq[i]);
                if (m_tl) tlq.push_back(rq[i]);
              end
              for (int i = 0; i < obs.size(); i++) begin
                if (m_vca) vcaq.push_back(obs[i]);
                if (m_tm) tmq.push_back(obs[i]);
                if (m_tl) tlq.push_back(obs[i]);
              end
            end
          end
        end
      end
      if (rsp_done) begin
        m_sent = 1'b0;
        if (rn_got != rn_need) f_rn_left = 1'b1;
        rn_need = 0; rn_got = 0;
        rq.delete();
      end
      // ML-DSA operations: the buffer contents when they start
      if (ml_start && !ml_busy && ml_op == 2'd1) begin
        for (int w = 0; w < 38; w++) begin
          logic [31:0] x;
          for (int b = 0; b < 4; b++) x[8 * b +: 8] = mp(4 * w + b);
          if (mls[13'h1000 + w] != x) f_sign_bad = 1'b1;
        end
        for (int w = 0; w < 8; w++) if (mls[13'h0BE8 + w] != rnw[8 + w]) f_sign_bad = 1'b1;
      end
      if (ml_start && !ml_busy && ml_op == 2'd0)
        for (int w = 0; w < 8; w++) if (mls[13'h0BD8 + w] != m_seed[32 * w +: 32]) f_kg_bad = 1'b1;
      if (kg_done) begin
        for (int w = 0; w < 8; w++) if (mls[13'h0BD8 + w] != '0) f_xi_bad = 1'b1;
        m_kg = 1'b0; m_key = 1'b1;
      end
      // requests
      if (rq_valid && rq_ready) begin
        if (m_drain) begin
          if (rq_last) m_drain = 1'b0;
        end else if (!clr_seen) begin
          rq.push_back(rq_data);
          m_rx = !rq_last;
          if (rq_last) respond();
        end else if (!rq_last) m_drain = 1'b1;
      end else if (clr_seen && m_rx) m_drain = 1'b1;
      // key commands accepted in idle
      if (!busy && !m_drain && !m_clr && !clr && kg_start && pset != 2'd3 && (!kg_sel || sl_valid)) begin
        m_kg = 1'b1; m_key = 1'b0; m_kps = pset; m_seed = kg_sel ? sl_seed : seed;
      end
      if (!busy && !m_drain && !m_clr && !clr && !kg_start && pk_open && key_ok) begin
        m_pk = 1'b1; pk_cnt = 0;
        pk_n = m_kps == 2'd0 ? 328 : m_kps == 2'd1 ? 488 : 648;
      end
      if (pk_valid && pk_ready) begin
        pk_cnt++;
        if (pk_last) m_pk = 1'b0;
      end
      // clr: everything is abandoned; the core is idle again once it is done
      if (clr_seen) begin
        m_clr = 1'b1; m_act = 1'b0; m_sent = 1'b0; m_rx = 1'b0; m_kg = 1'b0; m_pk = 1'b0;
        rn_need = 0; rn_got = 0; rq.delete();
        m_key = 1'b0; m_conn = '0; m_hash = 1'b0; m_asym = 1'b0; m_meas = 1'b0;
        vcaq.delete(); tmq.delete(); tlq.delete();
      end else if (m_clr && !busy && busy_q) begin
        m_clr = 1'b0;
        for (int w = 13'h0288; w < 13'h0BF0; w++) if (mls[w] != '0) f_wipe_bad = 1'b1;
      end
      if (m_sent && m_sgn) sdone_wait++; else sdone_wait = 0;
    end
    // the model as the assertions see it: published at the clock edge (the
    // core's outputs also change then)
    busy_q <= rst_n && busy;
    m_act_q <= m_act; m_sent_q <= m_sent; ridx_q <= ridx; e_n_q <= e_n; e_sig_q <= e_sig;
    m_iserr_q <= m_iserr; m_ecode_q <= m_ecode; m_sgn_q <= m_sgn; m_drain_q <= m_drain; m_clr_q <= m_clr;
    m_rx_q <= m_rx; m_kg_q <= m_kg; m_pk_q <= m_pk; m_key_q <= m_key; m_kps_q <= m_kps;
    pk_cnt_q <= pk_cnt; pk_n_q <= pk_n; sdone_q <= sdone_wait;
    f_q <= {f_sign_bad, f_kg_bad, f_wipe_bad, f_xi_bad, f_rn_extra, f_rn_left};
    c_code_q <= c_code; c_err_q <= c_err; rq_n_q <= rq.size();
    m_conn_q <= m_conn; m_conn_qq <= m_conn_q;
  end
  logic        m_act_q, m_sent_q, m_iserr_q, m_sgn_q, m_drain_q, m_clr_q, m_rx_q, m_kg_q, m_pk_q, m_key_q;
  int          ridx_q, e_n_q, e_sig_q, pk_cnt_q, pk_n_q, sdone_q, c_code_q, c_err_q, rq_n_q;
  logic [7:0]  m_ecode_q;
  logic [1:0]  m_kps_q, m_conn_q, m_conn_qq;
  logic [5:0]  f_q;

  // ---------------- assertions ----------------
  wire in_clr = m_clr_q || clr;
  wire sgn_start = ml_start && !ml_busy && ml_op == 2'd1;
  `SVA_IMP(a_rs_expected, rs_valid && !in_clr, m_act_q)
  `SVA_IMP(a_rs_data, rs_valid && m_act_q && ridx_q < e_sig_q, rs_data == e_byte)
  `SVA_IMP(a_rs_last, rs_valid && m_act_q, rs_last == (ridx_q == e_n_q - 1))
  `SVA_IMP(a_rs_sig_data, rs_valid && m_act_q && ridx_q >= e_sig_q, rs_data == hr_data[8 * ((ridx_q - e_sig_q) % 4) +: 8])
  `SVA_NXT(a_rs_hold, rs_valid && !rs_ready && !clr, rs_valid && $stable(rs_data) && $stable(rs_last))
  `SVA_NXT(a_rs_clr_stop, clr, !rs_valid)
  `SVA_IMP(a_no_rs_after_clr, m_clr_q, !rs_valid)
  `SVA_IMP(a_done_due, rsp_done, m_sent_q && !in_clr)
  `SVA_IMP(a_done_err, rsp_done, rsp_err == m_iserr_q)
  `SVA_NXT(a_done_next, rs_valid && rs_ready && m_act_q && ridx_q == e_n_q - 1 && !m_sgn_q && !clr, rsp_done)
  `SVA_INV(a_done_bound, sdone_q < 600)
  `SVA_IMP(a_err_code, rsp_done && m_iserr_q, err_code == m_ecode_q)
  `SVA_IMP(a_err_hold, !rsp_done, $stable(err_code))
  `SVA_IMP(a_rq_hold_off, m_act_q || m_sent_q, !rq_ready)
  `SVA_IMP(a_rq_open, !busy && !clr && !m_clr_q && !kg_start && !pk_open, rq_ready)
  `SVA_IMP(a_rq_drain, m_drain_q, rq_ready || m_clr_q || clr)
  `SVA_IMP(a_busy_answer, m_act_q || m_sent_q && !rsp_done || m_rx_q || m_kg_q && !kg_done || m_pk_q, busy)
  `SVA_IMP(a_conn, !in_clr && !$past(m_clr_q), conn == m_conn_qq)
  `SVA_IMP(a_conn_clr, !busy && !in_clr && $past(m_clr_q), conn == 2'd0 && !key_ok)
  `SVA_INV(a_rn_only_when_asked, !f_q[1])
  `SVA_INV(a_rn_all_taken, !f_q[0])
  `SVA_INV(a_sign_input, !f_q[5])
  `SVA_INV(a_keygen_input, !f_q[4])
  `SVA_INV(a_key_wiped, !f_q[3])
  `SVA_INV(a_seed_wiped, !f_q[2])
  `SVA_IMP(a_kg_done, kg_done, m_kg_q && key_ok && key_pset == m_kps_q)
  `SVA_IMP(a_key_ok, !in_clr && !kg_done, key_ok == m_key_q)
  `SVA_IMP(a_ml_sign, sgn_start, key_pset == m_kps_q && m_sgn_q && m_act_q && ridx_q == e_sig_q)
  `SVA_NXT(a_cmd_busy, (kg_start || pk_open) && busy, cmd_err)
  `SVA_NXT(a_cmd_bad_kg, kg_start && !busy && !clr && !m_clr_q && (pset == 2'd3 || kg_sel && !sl_valid || m_drain_q), cmd_err)
  `SVA_NXT(a_cmd_bad_pk, pk_open && !kg_start && !busy && !clr && !m_clr_q && (!key_ok || m_drain_q), cmd_err)
  `SVA_NXT(a_cmd_ok, (kg_start && pset != 2'd3 && (!kg_sel || sl_valid) || !kg_start && pk_open && key_ok) &&
                     !busy && !clr && !m_clr_q && !m_drain_q, !cmd_err && busy)
  `SVA_IMP(a_cmd_cause, cmd_err, $past(kg_start || pk_open))
  `SVA_IMP(a_pk_count, pk_valid && pk_ready, m_pk_q && pk_last == (pk_cnt_q == pk_n_q - 1))
  `SVA_IMP(a_pk_data, pk_valid, pk_data == hr_data)
  `SVA_IMP(a_idle_quiet, !busy, !rs_valid && !pk_valid && !rn_ready && !ml_busy)
  `SVA_RST(a_reset, 1'b1, !busy && conn == 2'd0 && !key_ok && !rs_valid && !rsp_done && !cmd_err && !kg_done)

  // ---------------- functional coverage ----------------
  int cv_code, cv_err;
  always @(posedge clk) begin cv_code <= c_code_q; cv_err <= c_err_q; end
  covergroup cg_spdm @(negedge clk);
    option.per_instance = 1;
    cp_code: coverpoint cv_code iff (cv_code >= 0) {
      bins gver = {0}; bins gcap = {1}; bins neg = {2}; bins gdig = {3}; bins gcrt = {4}; bins chal = {5};
      bins gmeas = {6}; bins other = {7}; }
    cp_err: coverpoint cv_err iff (cv_code >= 0) {
      bins ok = {0}; bins invalid = {1}; bins unexpected = {2}; bins unsupported = {3}; bins too_large = {4};
      bins version = {5}; }
  endgroup
  cg_spdm u_cg = new;
  // request code x outcome, as cover properties (the combinations that exist)
  `FC(ver_ok, c_code_q == 0 && c_err_q == 0)
  `FC(ver_invalid, c_code_q == 0 && c_err_q == 1)
  `FC(ver_mismatch, c_code_q == 0 && c_err_q == 5)
  `FC(cap_ok, c_code_q == 1 && c_err_q == 0)
  `FC(cap_invalid, c_code_q == 1 && c_err_q == 1)
  `FC(cap_unexpected, c_code_q == 1 && c_err_q == 2)
  `FC(cap_version, c_code_q == 1 && c_err_q == 5)
  `FC(neg_ok, c_code_q == 2 && c_err_q == 0)
  `FC(neg_invalid, c_code_q == 2 && c_err_q == 1)
  `FC(neg_unexpected, c_code_q == 2 && c_err_q == 2)
  `FC(dig_ok_slot, c_code_q == 3 && c_err_q == 0 && cc_len != '0 && m_key_q)
  `FC(dig_ok_empty, c_code_q == 3 && c_err_q == 0 && !(cc_len != '0 && m_key_q))
  `FC(dig_invalid, c_code_q == 3 && c_err_q == 1)
  `FC(dig_unexpected, c_code_q == 3 && c_err_q == 2)
  `FC(dig_too_large, c_code_q == 3 && c_err_q == 4)
  `FC(crt_ok, c_code_q == 4 && c_err_q == 0)
  `FC(crt_invalid, c_code_q == 4 && c_err_q == 1)
  `FC(crt_clip_len, c_code_q == 4 && c_err_q == 0 && v_clip_len)
  `FC(crt_clip_rem, c_code_q == 4 && c_err_q == 0 && v_clip_rem)
  `FC(crt_clip_dts, c_code_q == 4 && c_err_q == 0 && v_clip_dts)
  `FC(crt_zero, c_code_q == 4 && c_err_q == 0 && v_zero)
  `FC(chal_none, c_code_q == 5 && c_err_q == 0 && v_p2 == 8'h00)
  `FC(chal_tcb, c_code_q == 5 && c_err_q == 0 && v_p2 == 8'h01)
  `FC(chal_all, c_code_q == 5 && c_err_q == 0 && v_p2 == 8'hFF)
  `FC(chal_tcb_empty, c_code_q == 5 && c_err_q == 0 && v_tcb0 && v_ms)
  `FC(chal_invalid, c_code_q == 5 && c_err_q == 1)
  `FC(chal_unexpected, c_code_q == 5 && c_err_q == 2)
  `FC(chal_too_large, c_code_q == 5 && c_err_q == 4)
  `FC(meas_count, c_code_q == 6 && c_err_q == 0 && v_p2 == 8'h00)
  `FC(meas_all, c_code_q == 6 && c_err_q == 0 && v_p2 == 8'hFF && !v_sig)
  `FC(meas_one, c_code_q == 6 && c_err_q == 0 && v_p2 != 8'h00 && v_p2 != 8'hFF && !v_sig)
  `FC(meas_all_signed, c_code_q == 6 && c_err_q == 0 && v_p2 == 8'hFF && v_sig)
  `FC(meas_one_signed, c_code_q == 6 && c_err_q == 0 && v_p2 != 8'h00 && v_p2 != 8'hFF && v_sig)
  `FC(meas_count_signed, c_code_q == 6 && c_err_q == 0 && v_p2 == 8'h00 && v_sig)
  `FC(meas_none_present, c_code_q == 6 && c_err_q == 0 && v_p2 == 8'hFF && m_en == '0)
  `FC(meas_invalid, c_code_q == 6 && c_err_q == 1)
  `FC(meas_unexpected, c_code_q == 6 && c_err_q == 2)
  `FC(meas_unsupported, c_code_q == 6 && c_err_q == 3)
  `FC(meas_too_large, c_code_q == 6 && c_err_q == 4)
  `FC(meas_version, c_code_q == 6 && c_err_q == 5)
  `FC(other_unsupported, c_code_q == 7 && c_err_q == 3)
  `FC(short_request, c_code_q == 7 && c_err_q == 1)
  `FC(long_request, c_code_q >= 0 && rq_n_q > 128)
  `FC(sign_44, ml_start && !ml_busy && ml_op == 2'd1 && key_pset == 2'd0)
  `FC(sign_65, ml_start && !ml_busy && ml_op == 2'd1 && key_pset == 2'd1)
  `FC(sign_87, ml_start && !ml_busy && ml_op == 2'd1 && key_pset == 2'd2)
  `FC(keygen_seed, kg_start && !busy && !kg_sel && pset != 2'd3)
  `FC(keygen_sideload, kg_start && !busy && kg_sel && sl_valid && pset != 2'd3)
  `FC(pk_stream, pk_valid && pk_ready && pk_last)
  `FC(pk_backpressure, pk_valid && !pk_ready)
  `FC(rs_backpressure, rs_valid && !rs_ready && m_act_q && ridx_q < e_sig_q)
  `FC(rs_sig_backpressure, rs_valid && !rs_ready && m_act_q && ridx_q >= e_sig_q)
  `FC(rn_gap, rn_ready && !rn_valid)
  `FC(rq_gap, busy && m_rx_q && !rq_valid)
  `FC(cmd_while_busy, (kg_start || pk_open) && busy)
  `FC(clr_in_request, clr && m_rx_q)
  `FC(clr_in_sign, clr && ml_busy && !m_kg_q)
  `FC(clr_in_keygen, clr && m_kg_q)
  `FC(clr_in_response, clr && m_act_q && ridx_q > 0)
  `FC(clr_idle, clr && !busy)
  `FC(drain_bytes, m_drain_q && rq_valid && rq_ready)
  `FC(req_held_by_cmd, rq_valid && !rq_ready && !busy)
  `FC_RST(reset_in_request, rst_n && m_rx_q ##1 !rst_n)
endmodule

bind SPDM_top SPDM_sva #(.NM(NM), .CC_AW(CC_AW)) u_sva (.*);
