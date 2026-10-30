// SPDX-License-Identifier: Apache-2.0
// ML-DSA engine: concurrent SVA against independent reference models, plus
// functional coverage. The end-to-end results (keys, signatures, verify
// results) are checked by the testbench against FIPS 204 vectors; this
// checker checks every step the engine takes on its own:
//  * Keccak: the bytes each hash step absorbs are collected; at the padding
//    the model runs its own sponge (textbook Keccak-f[1600] from the
//    rotation and round-constant rules of FIPS 202) and every byte the
//    engine squeezes, to the buffer or to a sampler, must equal the model's.
//  * Polynomial unit: at the start of a step the model takes a copy of the
//    inputs (polynomials, buffer bytes, the hint vector) and computes the
//    step the way FIPS 204 writes it (NTT, NTT^-1, RejNTTPoly,
//    RejBoundedPoly, ExpandMask's BitUnpack, SampleInBall, BitPack /
//    SimpleBitPack, Power2Round, Decompose, MakeHint, UseHint,
//    HintBitPack / HintBitUnpack with their malformed-input checks), with %
//    for the reductions and zetas from 1753^BitRev8(i); at the end of the
//    step the polynomial, buffer bytes, hints and reject flag it left must
//    equal the model's. The samplers use the bytes the hash streamed into
//    them, and must take exactly as many as they need.
//  * Every coefficient written is below q.
//  * Control: the Sign loop restarts exactly when an attempt was rejected;
//    Verify's fail is the reject flag at the end; the host port: ready /
//    valid rules, the pointer and a mirror of the buffer for the read data;
//    start, busy, done and err.
`include "cov_macros.svh"
module ML_DSA_sva (
  input logic        clk, rst_n, start,
  input logic [1:0]  op, pset,
  input logic        ext_mu,
  input logic [14:0] mlen,
  input logic        busy, done, err, fail,
  input logic [15:0] tries,
  input logic        hp_load,
  input logic [12:0] hp_addr,
  input logic        hw_valid,
  input logic [31:0] hw_data,
  input logic        hw_ready,
  input logic        hr_en, hr_valid,
  input logic [31:0] hr_data,
  input logic        hr_ready,
  // internals
  input logic [7:0]  mem [0:32767],
  input logic [22:0] pm [0:11007],
  input logic        ugo, p_done, h_done, bad,
  input logic [6:0]  pc,
  input logic [2:0]  ci,
  input logic [1:0]  psr, opr,
  input logic [4:0]  u_op,
  input logic [5:0]  u_dst, u_a, u_b,
  input logic        u_clr, u_add, u_chk,
  input logic [2:0]  u_fn,
  input logic [4:0]  u_n,
  input logic [19:0] u_off,
  input logic [13:0] u_ma, u_mb,
  input logic [6:0]  u_len,
  input logic        h_on, h_strm, h_128,
  input logic [7:0]  h_ol,
  input logic [1:0]  hst, kseg,
  input logic        k_in, h_wr, hs_valid, hs_ready,
  input logic [1:0]  hs_n,
  input logic [23:0] hs_data,
  input logic [7:0]  k_ib, kbyte, kpos, rate,
  input logic [7:0]  kout,
  input logic        pw0, pw1,
  input logic [22:0] o0, o1,
  input logic [255:0] cnz, cng, hv,
  input logic [6:0]  hidx,
  input logic [15:0] kap,
  input logic        mw,
  input logic [13:0] mw_a,
  input logic [7:0]  mw_d
);
  `COV_CLOCKING(clk, !rst_n)
  localparam longint Q = 8380417;
  localparam logic [4:0] U_NONE = 0, U_NTT = 1, U_INTT = 2, U_PMUL = 3, U_ADD = 4, U_SUB = 5, U_SA = 6, U_SS = 7,
                         U_SY = 8, U_SIB = 9, U_CLD = 10, U_DEC = 11, U_ENC = 12, U_HINT = 13, U_HDEC = 14,
                         U_HZ = 15, U_FILL = 16, U_COPY = 17, U_CMP = 18;
  localparam logic [2:0] F_OFF = 0, F_SHL = 1, F_P2H = 2, F_P2L = 3, F_HB = 4, F_UH = 5;
  localparam logic [1:0] K_ABS = 2'd1, K_SQZ = 2'd3;

  // ---------------- parameter sets (FIPS 204 table 1) ----------------
  function automatic int pk_(input int ps); pk_ = ps == 0 ? 4 : ps == 1 ? 6 : 8; endfunction
  function automatic int pl_(input int ps); pl_ = ps == 0 ? 4 : ps == 1 ? 5 : 7; endfunction
  function automatic longint pg2(input int ps); pg2 = ps == 0 ? (Q - 1) / 88 : (Q - 1) / 32; endfunction
  function automatic int pbeta(input int ps); pbeta = ps == 0 ? 78 : ps == 1 ? 196 : 120; endfunction
  function automatic int pomega(input int ps); pomega = ps == 0 ? 80 : ps == 1 ? 55 : 75; endfunction
  function automatic int ptau(input int ps); ptau = ps == 0 ? 39 : ps == 1 ? 49 : 60; endfunction
  function automatic int peta(input int ps); peta = ps == 1 ? 4 : 2; endfunction
  function automatic longint pg1(input int ps); pg1 = ps == 0 ? 64'd1 << 17 : 64'd1 << 19; endfunction

  // ---------------- tables from their definitions ----------------
  longint zt [0:255];                   // 1753^BitRev8(i) mod q
  function automatic int brv8(input int i);
    brv8 = 0;
    for (int b = 0; b < 8; b++) if (i & (1 << b)) brv8 |= 1 << (7 - b);
  endfunction
  function automatic longint pw(input longint b, input int e);
    pw = 1;
    for (int n = 0; n < e; n++) pw = pw * b % Q;
  endfunction
  // Keccak rotation offsets and round constants (FIPS 202, 3.2.2 and 3.2.5)
  int rho [0:24];
  logic [63:0] rcs [0:23];
  function automatic bit rcb(input int t);
    logic [7:0] r;
    r = 8'h01;
    for (int n = 0; n < t % 255; n++) r = {r[6:0], 1'b0} ^ (r[7] ? 8'h71 : 8'h00);
    rcb = r[0];
  endfunction
  initial begin
    int x, y, tx;
    for (int i = 0; i < 256; i++) zt[i] = pw(1753, brv8(i));
    rho[0] = 0; x = 1; y = 0;
    for (int t = 0; t < 24; t++) begin
      rho[x + 5 * y] = ((t + 1) * (t + 2) / 2) % 64;
      tx = x; x = y; y = (2 * tx + 3 * y) % 5;
    end
    for (int r = 0; r < 24; r++) begin
      rcs[r] = '0;
      for (int j = 0; j < 7; j++) rcs[r][(1 << j) - 1] = rcb(j + 7 * r);
    end
  end

  // ---------------- Keccak model ----------------
  logic [63:0] ms [0:24];
  task automatic kf();
    logic [63:0] c [0:4];
    logic [63:0] b [0:24];
    for (int r = 0; r < 24; r++) begin
      for (int x = 0; x < 5; x++) c[x] = ms[x] ^ ms[x + 5] ^ ms[x + 10] ^ ms[x + 15] ^ ms[x + 20];
      for (int x = 0; x < 5; x++)
        for (int y = 0; y < 5; y++)
          ms[x + 5 * y] ^= c[(x + 4) % 5] ^ ((c[(x + 1) % 5] << 1) | (c[(x + 1) % 5] >> 63));
      for (int x = 0; x < 5; x++)
        for (int y = 0; y < 5; y++) begin
          logic [63:0] v;
          v = ms[x + 5 * y];
          if (rho[x + 5 * y] != 0) v = (v << rho[x + 5 * y]) | (v >> (64 - rho[x + 5 * y]));
          b[y + 5 * ((2 * x + 3 * y) % 5)] = v;
        end
      for (int x = 0; x < 5; x++)
        for (int y = 0; y < 5; y++)
          ms[x + 5 * y] = b[x + 5 * y] ^ (~b[(x + 1) % 5 + 5 * y] & b[(x + 2) % 5 + 5 * y]);
      ms[0] ^= rcs[r];
    end
  endtask
  // one hash step: absorbed bytes, then the model's output
  logic [7:0] hin [0:16511];
  int hn, hrate, hpos, hcnt, hbad, hstep, hol;
  bit hstr, hfin;
  task automatic hfinish();
    int p;
    for (int i = 0; i < 25; i++) ms[i] = '0;
    p = 0;
    for (int i = 0; i < hn; i++) begin
      ms[p / 8] ^= 64'(hin[i]) << (8 * (p % 8));
      p++;
      if (p == hrate) begin kf(); p = 0; end
    end
    ms[p / 8] ^= 64'h1F << (8 * (p % 8));
    ms[(hrate - 1) / 8] ^= 64'h80 << (8 * ((hrate - 1) % 8));
    kf();
    hpos = 0; hfin = 1;
  endtask
  // the next squeezed byte, then advance
  function automatic logic [7:0] hnext();
    hnext = 8'(ms[hpos / 8] >> (8 * (hpos % 8)));
  endfunction
  task automatic hadv();
    hpos++; hcnt++;
    if (hpos == hrate) begin kf(); hpos = 0; end
  endtask

  // ---------------- polynomial unit model ----------------
  longint ra [0:255], rb [0:255], rd [0:255], rr [0:255];
  logic [7:0] ib [0:1023], ib2 [0:1023], ob [0:1023];
  logic [7:0] sbytes [0:4095];          // the bytes streamed into a sampler
  int sn;
  logic [4:0] sop;
  logic [5:0] sdst;
  logic [2:0] sfn;
  int sn_bits, sps, srow, slen, sh0;
  longint soff;
  logic [14:0] sma, smb;
  bit sclr, sadd, schk, sb0, sbclr;
  logic [255:0] shv;
  bit mc_nz [0:255], mc_ng [0:255];      // the model's c from the last SampleInBall
  logic [255:0] mhv;                    // HintBitUnpack: the model's hints
  int mhidx;                            // the model's hint index after the step
  int chk_op, chk_bad;
  bit sbad;                             // the step should set the reject flag
  // reasons, for coverage
  bit r_z, r_r0, r_ct0, r_hcnt, r_hend, r_hord, r_hpad, r_ct, r_zdec, r_sa_rej, r_ss_rej, r_sib_rej, r_sib_eq;
  function automatic longint md(input longint x);
    md = ((x % Q) + Q) % Q;
  endfunction
  function automatic longint cen(input longint x);     // x mod+- q
    cen = x > (Q - 1) / 2 ? x - Q : x;
  endfunction
  function automatic longint labs(input longint x);
    labs = x < 0 ? -x : x;
  endfunction
  // Decompose (Algorithm 36): r1, r0
  function automatic longint dhigh(input longint r, input int ps);
    longint g, r0;
    g = pg2(ps);
    r = md(r);
    r0 = r % (2 * g);
    if (r0 > g) r0 -= 2 * g;
    dhigh = r - r0 == Q - 1 ? 0 : (r - r0) / (2 * g);
  endfunction
  function automatic longint dlow(input longint r, input int ps);
    longint g, r0;
    g = pg2(ps);
    r = md(r);
    r0 = r % (2 * g);
    if (r0 > g) r0 -= 2 * g;
    dlow = r - r0 == Q - 1 ? r0 - 1 : r0;
  endfunction
  function automatic longint usehint(input bit h, input longint r, input int ps);
    longint m, r1, r0;
    m = (Q - 1) / (2 * pg2(ps));
    r1 = dhigh(r, ps); r0 = dlow(r, ps);
    usehint = !h ? r1 : r0 > 0 ? (r1 + 1) % m : (r1 - 1 + m) % m;
  endfunction
  function automatic longint getbits(input int pos, input int n, input bit from_stream);
    getbits = 0;
    for (int j = 0; j < n; j++)
      getbits |= longint'((from_stream ? sbytes[(pos + j) / 8] : ib[(pos + j) / 8]) >> ((pos + j) % 8) & 1) << j;
  endfunction
  task automatic snap();
    sop = u_op; sdst = u_dst; sfn = u_fn; sn_bits = int'(u_n); soff = longint'(u_off); sma = u_ma; smb = u_mb;
    slen = int'(u_len); sclr = u_clr; sadd = u_add; schk = u_chk; sps = int'(psr); srow = int'(ci); sn = 0;
    sh0 = u_op == U_HDEC && ci == 3'd0 ? 0 : int'(hidx);
    shv = hv; sb0 = bad; sbclr = pc == 7'd25 && ci == 3'd0;
    for (int i = 0; i < 256; i++) begin
      ra[i] = longint'(pm[{u_a, 8'(i)}]); rb[i] = longint'(pm[{u_b, 8'(i)}]); rd[i] = longint'(pm[{u_dst, 8'(i)}]);
    end
    for (int i = 0; i < 1024; i++) begin ib[i] = mem[15'(u_ma + 15'(i))]; ib2[i] = mem[15'(u_mb + 15'(i))]; end
  endtask
  // the result the step should leave (rr: polynomial; ob: bytes; sbad; mhv / mhidx)
  task automatic model();
    int i, len, s, j, m, nb, nh, om;
    longint t, x, z;
    sbad = 0; mhidx = int'(hidx); om = pomega(sps);
    case (sop)
      U_NTT: begin
        for (i = 0; i < 256; i++) rr[i] = rd[i];
        m = 0;
        for (len = 128; len >= 1; len /= 2)
          for (s = 0; s < 256; s += 2 * len) begin
            m++; z = zt[m];
            for (j = s; j < s + len; j++) begin
              t = z * rr[j + len] % Q;
              rr[j + len] = md(rr[j] - t);
              rr[j] = (rr[j] + t) % Q;
            end
          end
      end
      U_INTT: begin
        for (i = 0; i < 256; i++) rr[i] = rd[i];
        m = 256;
        for (len = 1; len < 256; len *= 2)
          for (s = 0; s < 256; s += 2 * len) begin
            m--; z = Q - zt[m];
            for (j = s; j < s + len; j++) begin
              t = rr[j];
              rr[j] = (t + rr[j + len]) % Q;
              rr[j + len] = z * md(t - rr[j + len]) % Q;
            end
          end
        for (i = 0; i < 256; i++) rr[i] = rr[i] * 8347681 % Q;
      end
      U_PMUL: for (i = 0; i < 256; i++) rr[i] = ra[i] * rb[i] % Q;
      U_ADD: for (i = 0; i < 256; i++) rr[i] = (ra[i] + rb[i]) % Q;
      U_SUB: for (i = 0; i < 256; i++) rr[i] = md(ra[i] - rb[i]);
      U_SA: begin                       // RejNTTPoly, multiplied into the accumulator
        j = 0; i = 0;
        while (j < 256 && i + 3 <= sn) begin
          x = longint'(sbytes[i]) | longint'(sbytes[i + 1]) << 8 | longint'(sbytes[i + 2] & 8'h7F) << 16;
          if (x < Q) begin rr[j] = sclr ? x * rb[j] % Q : (rd[j] + x * rb[j]) % Q; j++; end
          else r_sa_rej = 1;
          i += 3;
        end
        if (j < 256 || i != sn) chk_bad = 1;            // must take exactly the bytes it needs
      end
      U_SS: begin                       // RejBoundedPoly
        j = 0; i = 0;
        while (j < 256 && i < sn) begin
          for (int h = 0; h < 2; h++) begin
            x = longint'(sbytes[i] >> (4 * h)) & 15;
            if (j < 256 && (peta(sps) == 2 && x < 15 || peta(sps) == 4 && x < 9)) begin
              rr[j] = md(peta(sps) == 2 ? 2 - x % 5 : 4 - x); j++;
            end else r_ss_rej = 1;
          end
          i++;
        end
        if (j < 256 || i != sn) chk_bad = 1;
      end
      U_SY: begin                       // ExpandMask: BitUnpack(gamma1 - 1, gamma1)
        for (i = 0; i < 256; i++) begin
          x = md(pg1(sps) - getbits(i * sn_bits, sn_bits, 1));
          rr[i] = sadd ? (x + rb[i]) % Q : x;
        end
        if (sn < 32 * sn_bits || sn > 32 * sn_bits + 2) chk_bad = 1;   // the bytes it needs, in groups of three
      end
      U_SIB: begin                      // SampleInBall
        for (i = 0; i < 256; i++) begin mc_nz[i] = 0; mc_ng[i] = 0; end
        nb = 8;
        for (i = 256 - ptau(sps); i < 256; i++) begin
          j = int'(sbytes[nb]); nb++;
          while (j > i && nb < sn) begin r_sib_rej = 1; j = int'(sbytes[nb]); nb++; end
          if (j == i) r_sib_eq = 1;
          mc_nz[i] = mc_nz[j]; mc_ng[i] = mc_ng[j];
          mc_nz[j] = 1; mc_ng[j] = sbytes[(i + ptau(sps) - 256) / 8][(i + ptau(sps) - 256) % 8];
        end
        if (nb != sn) chk_bad = 1;
      end
      U_CLD: for (i = 0; i < 256; i++) rr[i] = !mc_nz[i] ? 0 : mc_ng[i] ? Q - 1 : 1;
      U_DEC:
        for (i = 0; i < 256; i++) begin
          x = getbits(i * sn_bits, sn_bits, 0);
          rr[i] = sfn == F_SHL ? x << 13 : md(soff - x);
          if (schk && labs(soff - x) >= soff - pbeta(sps)) begin sbad = 1; r_zdec = 1; end
        end
      U_ENC: begin
        for (i = 0; i < 32 * sn_bits; i++) ob[i] = '0;
        for (i = 0; i < 256; i++) begin
          case (sfn)
            F_P2H: x = (ra[i] - cen2(ra[i])) >> 13;
            F_P2L: x = 4096 - cen2(ra[i]);
            F_HB: x = dhigh(ra[i], sps);
            F_UH: x = usehint(shv[i], ra[i], sps);
            default: x = soff - cen(ra[i]);
          endcase
          if (schk && labs(cen(ra[i])) >= soff - pbeta(sps)) begin sbad = 1; r_z = 1; end
          for (j = 0; j < sn_bits; j++)
            if ((x >> j) & 1) ob[(i * sn_bits + j) / 8] |= 8'(1 << ((i * sn_bits + j) % 8));
        end
      end
      U_HINT: begin                     // MakeHint(-<<c t0>>, w - <<c s2>> + <<c t0>>) and HintBitPack
        nh = sh0;
        for (i = 0; i < om; i++) ob[i] = ib[i];
        for (i = 0; i < 256; i++) begin
          if (labs(dlow(ra[i], sps)) >= pg2(sps) - pbeta(sps)) begin sbad = 1; r_r0 = 1; end
          if (labs(cen(rb[i])) >= pg2(sps)) begin sbad = 1; r_ct0 = 1; end
          if (dhigh(ra[i] + rb[i], sps) != dhigh(ra[i] + rb[i] - rb[i], sps)) begin
            if (nh < om) ob[nh] = 8'(i);
            else begin sbad = 1; r_hcnt = 1; end
            if (nh <= om) nh++;       // the count saturates at omega + 1
          end
        end
        mhidx = nh;
      end
      U_HDEC: begin                     // HintBitUnpack, one row
        mhv = '0; nh = sh0; mhidx = sh0;
        x = longint'(ib[om + srow]);
        if (x < nh || x > om) begin sbad = 1; r_hend = 1; end
        else begin
          for (i = nh; i < int'(x); i++) begin
            if (i > nh && ib[i - 1] >= ib[i]) begin sbad = 1; r_hord = 1; end
            mhv[ib[i]] = 1;
          end
          mhidx = int'(x);
        end
      end
      U_HZ: begin
        for (i = sh0; i < om; i++) if (ib[i] != 0) begin sbad = 1; r_hpad = 1; end
        mhidx = om;
      end
      U_FILL: begin for (i = 0; i < slen; i++) ob[i] = '0; mhidx = 0; end
      U_COPY: for (i = 0; i < slen; i++) ob[i] = ib[i];
      U_CMP: for (i = 0; i < slen; i++) if (ib[i] != ib2[i]) begin sbad = 1; r_ct = 1; end
      default: ;
    endcase
  endtask
  // Power2Round's r0 = r mod+- 2^13
  function automatic longint cen2(input longint r);
    cen2 = r % 8192;
    if (cen2 > 4096) cen2 -= 8192;
  endfunction
  task automatic compare();
    case (sop)
      U_ENC: for (int i = 0; i < 32 * sn_bits; i++) if (mem[15'(smb + 15'(i))] != ob[i]) chk_bad = 1;
      U_COPY, U_FILL: for (int i = 0; i < slen; i++) if (mem[15'(smb + 15'(i))] != ob[i]) chk_bad = 1;
      U_HINT: begin
        for (int i = 0; i < pomega(sps); i++) if (mem[15'(sma + 15'(i))] != ob[i]) chk_bad = 1;
        if (int'(mem[15'(sma + 15'(pomega(sps) + srow))]) != mhidx) chk_bad = 1;
      end
      U_SIB: for (int i = 0; i < 256; i++) if (cnz[i] != mc_nz[i] || cnz[i] && cng[i] != mc_ng[i]) chk_bad = 1;
      U_HDEC: if (hv != mhv) chk_bad = 1;
      U_HZ, U_CMP: ;
      default: for (int i = 0; i < 256; i++) if (longint'(pm[{sdst, 8'(i)}]) != rr[i]) chk_bad = 1;
    endcase
    if (sop inside {U_HINT, U_HDEC, U_HZ, U_FILL} && int'(hidx) != mhidx) chk_bad = 1;
    if (bad != ((sb0 && !sbclr) || sbad)) chk_bad = 1;
  endtask

  bit hbusy;
  always @(posedge clk) begin
    chk_op <= -1;
    hstep <= 0;
    if (!rst_n) begin
      hn = 0; hfin = 0; sn = 0; hbusy = 0;
    end else begin
      if (ugo) begin
        hn = 0; hfin = 0; hcnt = 0; hbad = 0; hstr = h_strm; hol = int'(h_ol); hbusy = h_on;
        hrate = h_128 ? 168 : 136;
        if (u_op != U_NONE) snap();
      end else begin
        if (hst == K_ABS && k_in) begin hin[hn] = k_ib; hn++; end
        if (hst == K_ABS && !k_in && kseg == 2'd2) hfinish();
        if (h_wr) begin
          if (!hfin || kbyte != hnext()) hbad = 1;
          hadv();
        end
        if (hs_valid && hs_ready)
          for (int b = 0; b < int'(hs_n); b++) begin
            if (!hfin || hs_data[8 * b +: 8] != hnext()) hbad = 1;
            hadv();
            if (sn < 4096) begin sbytes[sn] = hs_data[8 * b +: 8]; sn++; end
          end
        if (h_done) begin
          if (hcnt != hol) hbad = 1;    // the buffer sink got exactly h_ol bytes
          hstep <= 1;
        end
        if (p_done) begin
          chk_bad = 0;
          model();
          compare();
          chk_op <= int'(sop);
          if (hstr) hstep <= 2;
        end
      end
    end
  end
  bit hbad_q, p_done_q;
  always @(posedge clk) p_done_q <= p_done;
  always @(posedge clk) hbad_q <= hbad != 0;
  wire hash_ok = !hbad_q;
  wire poly_ok = chk_bad == 0;

  `SVA_IMP(a_hash_to_buffer, hstep == 1, hash_ok)
  `SVA_IMP(a_hash_to_sampler, hstep == 2, hash_ok)
  `SVA_IMP(a_ntt, chk_op == int'(U_NTT), poly_ok)
  `SVA_IMP(a_intt, chk_op == int'(U_INTT), poly_ok)
  `SVA_IMP(a_pointwise, chk_op == int'(U_PMUL), poly_ok)
  `SVA_IMP(a_add, chk_op == int'(U_ADD), poly_ok)
  `SVA_IMP(a_sub, chk_op == int'(U_SUB), poly_ok)
  `SVA_IMP(a_rej_ntt_poly_mac, chk_op == int'(U_SA), poly_ok)
  `SVA_IMP(a_rej_bounded_poly, chk_op == int'(U_SS), poly_ok)
  `SVA_IMP(a_expand_mask, chk_op == int'(U_SY), poly_ok)
  `SVA_IMP(a_sample_in_ball, chk_op == int'(U_SIB), poly_ok)
  `SVA_IMP(a_load_c, chk_op == int'(U_CLD), poly_ok)
  `SVA_IMP(a_decode, chk_op == int'(U_DEC), poly_ok)
  `SVA_IMP(a_encode, chk_op == int'(U_ENC), poly_ok)
  `SVA_IMP(a_make_hint, chk_op == int'(U_HINT), poly_ok)
  `SVA_IMP(a_hint_unpack, chk_op == int'(U_HDEC), poly_ok)
  `SVA_IMP(a_hint_padding, chk_op == int'(U_HZ), poly_ok)
  `SVA_IMP(a_fill, chk_op == int'(U_FILL), poly_ok)
  `SVA_IMP(a_copy, chk_op == int'(U_COPY), poly_ok)
  `SVA_IMP(a_compare, chk_op == int'(U_CMP), poly_ok)
  `SVA_IMP(a_coeff0_below_q, pw0, longint'(o0) < Q)
  `SVA_IMP(a_coeff1_below_q, pw1, longint'(o1) < Q)

  // ---------------- control, host port ----------------
  logic [7:0] mir [0:32767];
  logic [12:0] mp;
  logic [1:0] mop, mps;
  bit e_err, m_busy;
  wire m_bsy = m_busy && !done;        // the engine ends with its done pulse
  wire m_res = op == 2'd3 || pset == 2'd3 || op != 2'd0 && !ext_mu && mlen > 15'd16384;
  always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      mp <= '0; e_err <= 0; m_busy <= 0; mop <= '0; mps <= '0;
    end else begin
      e_err <= start && !m_bsy && m_res;
      if (start && !m_bsy && !m_res) begin m_busy <= 1; mop <= op; mps <= pset; end
      if (done) m_busy <= 0;
      if (hp_load) mp <= hp_addr;
      else if (hw_valid && !m_bsy || hr_en && hr_ready && !m_bsy) mp <= mp + 13'd1;
    end
  end
  // the mirror follows host writes and the engine's own buffer writes (checked above)
  always @(posedge clk) begin
    if (hw_valid && hw_ready) for (int i = 0; i < 4; i++) mir[{mp, 2'(i)}] <= hw_data[8 * i +: 8];
    if (mw) mir[15'(mw_a)] <= mw_d;
  end
  wire [31:0] mword = {mir[{mp, 2'd3}], mir[{mp, 2'd2}], mir[{mp, 2'd1}], mir[{mp, 2'd0}]};
  // the Sign loop: the last step of an attempt (pc 45)
  wire at_end = busy && ugo && pc == 7'd45;

  `SVA_INV(a_hw_ready, hw_ready == !m_bsy)
  `SVA_INV(a_hr_valid, hr_valid == (hr_en && !m_bsy))
  `SVA_INV(a_busy, busy == m_bsy)
  `SVA_IMP(a_hr_data, hr_valid, hr_data == mword)
  `SVA_INV(a_err, err == e_err)
  `SVA_IMP(a_done_only_busy, done, $past(m_busy) && !busy)
  `SVA_NXT(a_sign_retry, at_end && bad, ##2 busy && pc == 7'd25 && kap == $past(kap, 2) + 16'(pl_(int'(psr))))
  `SVA_NXT(a_sign_done, at_end && !bad, ##1 done)
  `SVA_IMP(a_verify_result, done && opr == 2'd2, fail == bad)
  `SVA_IMP(a_no_fail_but_verify, done && opr != 2'd2, !fail)
  `SVA_NXT(a_results_held, !busy && !start, fail == $past(fail) && tries == $past(tries))
  `SVA_RST(a_reset, 1'b1, !busy && !done && !err && !fail && hst == 2'd0)

  // ---------------- functional coverage ----------------
  int c_opps, c_uop, c_enc, c_dec, c_hm;
  bit v_start_busy, v_err_op, v_err_ps, v_err_len, v_hw_busy, v_hr_busy, v_hr_stall, v_multi_abs, v_multi_sqz,
      v_retry, v_tries3, v_vok, v_vfail, v_sqz1, v_empty_msg, v_hint_full, v_two_areas;
  always @(posedge clk) begin
    c_opps <= done ? int'(mop) * 3 + int'(mps) : -1;
    c_uop <= ugo ? int'(u_op) : -1;
    c_enc <= ugo && u_op == U_ENC ? int'(u_fn) * 32 + int'(u_n) : -1;
    c_dec <= ugo && u_op == U_DEC ? int'(u_fn) * 32 + int'(u_n) : -1;
    c_hm <= ugo && h_on ? int'(h_128) * 2 + int'(h_strm) : -1;
    if (rst_n) begin
      if (at_end && bad) v_retry <= 1;
      if (done && opr == 2'd1 && tries >= 16'd3) v_tries3 <= 1;
      if (done && opr == 2'd2 && !bad) v_vok <= 1;
      if (done && opr == 2'd2 && bad) v_vfail <= 1;
      if (start && m_bsy) v_start_busy <= 1;
      if (start && !m_bsy && op == 2'd3) v_err_op <= 1;
      if (start && !m_bsy && op != 2'd3 && pset == 2'd3) v_err_ps <= 1;
      if (start && !m_bsy && op != 2'd3 && pset != 2'd3 && m_res) v_err_len <= 1;
      if (start && !m_bsy && !m_res && op != 2'd0 && !ext_mu && mlen == '0) v_empty_msg <= 1;
      if (hw_valid && m_bsy) v_hw_busy <= 1;
      if (hr_en && m_bsy) v_hr_busy <= 1;
      if (hr_valid && !hr_ready) v_hr_stall <= 1;
      if (hst == K_ABS && k_in && kpos == rate - 8'd1) v_multi_abs <= 1;
      if (hs_valid && hs_ready && kpos + 8'(hs_n) == rate) v_multi_sqz <= 1;
      if (hs_valid && hs_ready && hs_n == 2'd1 && hstr && rate == 8'd136 && kpos == 8'd135) v_sqz1 <= 1;
      if (hst == K_ABS && !k_in && kseg == 2'd1 && hn > 0) v_two_areas <= 1;
      if (p_done_q && chk_op == int'(U_HINT) && mhidx == pomega(sps)) v_hint_full <= 1;   // model() ran at p_done
    end
  end
  covergroup cg_mldsa @(negedge clk);
    option.per_instance = 1;
    cp_op: coverpoint c_opps iff (c_opps >= 0)
      { bins keygen_44 = {0}; bins keygen_65 = {1}; bins keygen_87 = {2};
        bins sign_44 = {3}; bins sign_65 = {4}; bins sign_87 = {5};
        bins verify_44 = {6}; bins verify_65 = {7}; bins verify_87 = {8}; }
    cp_uop: coverpoint c_uop iff (c_uop >= 0)
      { bins hash = {0}; bins ntt = {1}; bins intt = {2}; bins pmul = {3}; bins add = {4}; bins sub = {5};
        bins rej_ntt = {6}; bins rej_bounded = {7}; bins expand_mask = {8}; bins sample_in_ball = {9};
        bins load_c = {10}; bins dec = {11}; bins enc = {12}; bins make_hint = {13}; bins hint_unpack = {14};
        bins hint_pad = {15}; bins fill = {16}; bins copy = {17}; bins cmp = {18}; }
    cp_enc: coverpoint c_enc iff (c_enc >= 0)
      { bins s_eta2 = {3}; bins s_eta4 = {4}; bins z18 = {18}; bins z20 = {20}; bins t1 = {74}; bins t0 = {109};
        bins w1_6 = {134}; bins w1_4 = {132}; bins usehint_6 = {166}; bins usehint_4 = {164}; }
    cp_dec: coverpoint c_dec iff (c_dec >= 0)
      { bins s_eta2 = {3}; bins s_eta4 = {4}; bins t0 = {13}; bins z18 = {18}; bins z20 = {20}; bins t1 = {42}; }
    cp_hash: coverpoint c_hm iff (c_hm >= 0)
      { bins shake256_buffer = {0}; bins shake256_stream = {1}; bins shake128_stream = {3}; }
  endgroup
  cg_mldsa u_cg_mldsa = new;

  `FC(sign_retry, v_retry)
  `FC(sign_three_attempts, v_tries3)
  `FC(sign_reject_z, r_z)
  `FC(sign_reject_r0, r_r0)
  `FC(sign_reject_ct0, r_ct0)
  `FC(sign_reject_hint_count, r_hcnt)
  `FC(sign_hints_exactly_omega, v_hint_full)
  `FC(verify_accept, v_vok)
  `FC(verify_reject, v_vfail)
  `FC(verify_reject_z, r_zdec)
  `FC(verify_reject_hint_end, r_hend)
  `FC(verify_reject_hint_order, r_hord)
  `FC(verify_reject_hint_padding, r_hpad)
  `FC(verify_reject_challenge, r_ct)
  `FC(rej_ntt_candidate_rejected, r_sa_rej)
  `FC(rej_bounded_nibble_rejected, r_ss_rej)
  `FC(sample_in_ball_byte_rejected, r_sib_rej)
  `FC(sample_in_ball_j_equals_i, r_sib_eq)
  `FC(start_while_busy, v_start_busy)
  `FC(reserved_op, v_err_op)
  `FC(reserved_pset, v_err_ps)
  `FC(message_too_long, v_err_len)
  `FC(empty_message, v_empty_msg)
  `FC(host_write_while_busy, v_hw_busy)
  `FC(host_read_while_busy, v_hr_busy)
  `FC(host_read_stall, v_hr_stall)
  `FC(absorb_more_than_a_block, v_multi_abs)
  `FC(squeeze_more_than_a_block, v_multi_sqz)
  `FC(squeeze_one_byte_at_block_end, v_sqz1)
  `FC(absorb_two_areas, v_two_areas)
  `FC_RST(reset_while_busy, rst_n && busy ##1 !rst_n)
endmodule

bind ML_DSA_top ML_DSA_sva u_sva (.*);
