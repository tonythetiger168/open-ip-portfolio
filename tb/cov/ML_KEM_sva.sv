// SPDX-License-Identifier: Apache-2.0
// ML-KEM engine: concurrent SVA against independent reference models, plus
// functional coverage. The end-to-end results (keys, ciphertexts, shared
// secrets) are checked by the testbench against FIPS 203 vectors; this
// checker checks every step the engine takes on its own:
//  * Keccak: the bytes each hash step absorbs are collected; at the padding
//    the model runs its own sponge (textbook Keccak-f[1600] from the
//    rotation and round-constant rules of FIPS 202) and every byte the
//    engine squeezes, to the buffer or to a sampler, must equal the model's.
//  * Polynomial unit: at the start of a step the model takes a copy of the
//    inputs (polynomials and buffer bytes) and computes the step the way
//    FIPS 203 writes it (Algorithms 5-12, with % for the reductions and its
//    own zeta tables); at the end of the step the polynomial or buffer
//    bytes it wrote must equal the model's. CBD and SampleNTT use the bytes
//    the hash streamed into them.
//  * Every coefficient written is below q.
//  * Host port: ready / valid rules, the pointer and a mirror of the buffer
//    for the read data; start, busy, done and err.
`include "cov_macros.svh"
module ML_KEM_sva (
  input logic        clk, rst_n, start,
  input logic [1:0]  op, pset,
  input logic        busy, done, err,
  input logic        hp_load,
  input logic [10:0] hp_addr,
  input logic        hw_valid,
  input logic [31:0] hw_data,
  input logic        hw_ready,
  input logic        hr_en, hr_valid,
  input logic [31:0] hr_data,
  input logic        hr_ready,
  // internals
  input logic [7:0]  mem [0:8191],
  input logic [11:0] pm [0:2559],
  input logic        ugo, p_done, h_done, diff,
  input logic [3:0]  u_op, u_dst, u_a, u_b, u_d,
  input logic        u_eta3, u_cmp, u_clr,
  input logic [7:0]  u_ma, u_mb,
  input logic [5:0]  u_len,
  input logic        h_on, h_strm,
  input logic [1:0]  h_mode, hst, kseg,
  input logic [1:0]  h_ol,
  input logic [6:0]  kout,
  input logic        k_in, h_wr, hs_valid, hs_ready,
  input logic [7:0]  k_ib, kbyte, kpos, rate,
  input logic        pw0, pw1,
  input logic [11:0] pw0_d, pw1_d,
  input logic        spend,
  input logic [1:0]  sbc,
  input logic [11:0] sd1, sd2,
  input logic [8:0]  pcnt,
  input logic        mw,
  input logic [12:0] mw_a,
  input logic [7:0]  mw_d
);
  `COV_CLOCKING(clk, !rst_n)
  localparam int Q = 3329;
  localparam logic [3:0] U_NONE = 0, U_CBD = 1, U_SAMP = 2, U_NTT = 3, U_INTT = 4, U_BMUL = 5, U_ADD = 6,
                         U_SUB = 7, U_ENC = 8, U_DEC = 9, U_COPY = 10, U_CMP = 11, U_CSEL = 12;
  localparam logic [1:0] K_ABS = 2'd1, K_SQZ = 2'd3;

  // ---------------- tables from their definitions ----------------
  int zt [0:127];                       // 17^BitRev7(i) mod q
  int gt [0:127];                       // 17^(2 BitRev7(i) + 1) mod q
  function automatic int brv7(input int i);
    brv7 = 0;
    for (int b = 0; b < 7; b++) if (i & (1 << b)) brv7 |= 1 << (6 - b);
  endfunction
  function automatic int pw17(input int e);
    pw17 = 1;
    for (int n = 0; n < e; n++) pw17 = pw17 * 17 % Q;
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
    for (int i = 0; i < 128; i++) begin zt[i] = pw17(brv7(i)); gt[i] = pw17(2 * brv7(i) + 1); end
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
  function automatic logic [7:0] msb(input int i);
    msb = 8'(ms[i / 8] >> (8 * (i % 8)));
  endfunction
  // one hash step: absorbed bytes, then the model's output
  logic [7:0] hin [0:4095];
  int hn, hrate, hpos, hcnt, hbad, hstep;
  logic [1:0] hmd;
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
    ms[p / 8] ^= 64'(hmd[1] ? 8'h1F : 8'h06) << (8 * (p % 8));
    ms[(hrate - 1) / 8] ^= 64'h80 << (8 * ((hrate - 1) % 8));
    kf();
    hpos = 0; hfin = 1;
  endtask
  function automatic logic [7:0] hnext();
    hnext = msb(hpos);
  endfunction
  task automatic hadv();
    hpos++; hcnt++;
    if (hpos == hrate) begin kf(); hpos = 0; end
  endtask

  // ---------------- polynomial unit model ----------------
  int ra [0:255], rb [0:255], rd [0:255], rr [0:255];
  logic [7:0] ib [0:1567], ib2 [0:1567], ob [0:1567];
  logic [7:0] sbytes [0:2047];
  int sn;
  logic [3:0] sop, sdst, sd;
  logic [12:0] sma, smb;
  logic [11:0] slen;
  bit scmp, sclr, seta3, sdiff;
  int chk_op, chk_bad;
  function automatic int cmpr(input int x, input int d);
    cmpr = ((x << (d + 1)) + Q) / (2 * Q) % (1 << d);
  endfunction
  function automatic int dcmp(input int y, input int d);
    dcmp = (Q * y * 2 + (1 << d)) >> (d + 1);
  endfunction
  task automatic snap();
    sop = u_op; sdst = u_dst; sd = u_d; sma = {u_ma, 5'd0}; smb = {u_mb, 5'd0}; slen = {1'b0, u_len, 5'd0};
    scmp = u_cmp; sclr = u_clr; seta3 = u_eta3; sn = 0;
    for (int i = 0; i < 256; i++) begin
      ra[i] = int'(pm[{u_a, 8'(i)}]); rb[i] = int'(pm[{u_b, 8'(i)}]); rd[i] = int'(pm[{u_dst, 8'(i)}]);
    end
    for (int i = 0; i < 1568; i++) begin ib[i] = mem[13'(sma + 13'(i))]; ib2[i] = mem[13'(smb + 13'(i))]; end
  endtask
  // the result the step should leave (rr: polynomial; ob: bytes)
  task automatic model();
    int i, len, s, j, z, t, nbit, x, y;
    case (sop)
      U_NTT: begin
        for (i = 0; i < 256; i++) rr[i] = rd[i];
        i = 1;
        for (len = 128; len >= 2; len /= 2)
          for (s = 0; s < 256; s += 2 * len) begin
            z = zt[i]; i++;
            for (j = s; j < s + len; j++) begin
              t = z * rr[j + len] % Q;
              rr[j + len] = (rr[j] - t + Q) % Q;
              rr[j] = (rr[j] + t) % Q;
            end
          end
      end
      U_INTT: begin
        for (i = 0; i < 256; i++) rr[i] = rd[i];
        i = 127;
        for (len = 2; len <= 128; len *= 2)
          for (s = 0; s < 256; s += 2 * len) begin
            z = zt[i]; i--;
            for (j = s; j < s + len; j++) begin
              t = rr[j];
              rr[j] = (t + rr[j + len]) % Q;
              rr[j + len] = z * (rr[j + len] - t + Q) % Q;
            end
          end
        for (i = 0; i < 256; i++) rr[i] = rr[i] * 3303 % Q;
      end
      U_BMUL:
        for (i = 0; i < 128; i++) begin
          x = (ra[2 * i] * rb[2 * i] + ra[2 * i + 1] * rb[2 * i + 1] % Q * gt[i]) % Q;
          y = (ra[2 * i] * rb[2 * i + 1] + ra[2 * i + 1] * rb[2 * i]) % Q;
          rr[2 * i] = sclr ? x : (rd[2 * i] + x) % Q;
          rr[2 * i + 1] = sclr ? y : (rd[2 * i + 1] + y) % Q;
        end
      U_ADD: for (i = 0; i < 256; i++) rr[i] = (ra[i] + rb[i]) % Q;
      U_SUB: for (i = 0; i < 256; i++) rr[i] = (ra[i] - rb[i] + Q) % Q;
      U_CBD: begin
        nbit = seta3 ? 3 : 2;
        for (i = 0; i < 256; i++) begin
          x = 0; y = 0;
          for (j = 0; j < nbit; j++) begin
            x += int'(sbytes[(2 * i * nbit + j) / 8] >> ((2 * i * nbit + j) % 8)) & 1;
            y += int'(sbytes[(2 * i * nbit + nbit + j) / 8] >> ((2 * i * nbit + nbit + j) % 8)) & 1;
          end
          rr[i] = (x - y + Q) % Q;
        end
      end
      U_SAMP: begin
        j = 0; i = 0;
        while (j < 256 && i + 3 <= sn) begin
          x = int'(sbytes[i]) + 256 * (int'(sbytes[i + 1]) % 16);
          y = int'(sbytes[i + 1]) / 16 + 16 * int'(sbytes[i + 2]);
          if (x < Q) begin rr[j] = x; j++; end
          if (y < Q && j < 256) begin rr[j] = y; j++; end
          i += 3;
        end
        if (j < 256 || i != sn) chk_bad = 1;            // must consume exactly the bytes it needs
      end
      U_ENC: begin
        for (i = 0; i < 32 * int'(sd); i++) ob[i] = '0;
        for (i = 0; i < 256; i++) begin
          x = scmp ? cmpr(ra[i], int'(sd)) : ra[i];
          for (j = 0; j < int'(sd); j++)
            if ((x >> j) & 1) ob[(i * int'(sd) + j) / 8] |= 8'(1 << ((i * int'(sd) + j) % 8));
        end
      end
      U_DEC:
        for (i = 0; i < 256; i++) begin
          x = 0;
          for (j = 0; j < int'(sd); j++)
            x |= (int'(ib[(i * int'(sd) + j) / 8] >> ((i * int'(sd) + j) % 8)) & 1) << j;
          if (sd == 4'd12) x = x % Q;
          rr[i] = scmp ? dcmp(x, int'(sd)) : x;
        end
      U_COPY: for (i = 0; i < int'(slen); i++) ob[i] = ib[i];
      U_CSEL: for (i = 0; i < int'(slen); i++) ob[i] = sdiff ? ib[i] : ib2[i];
      default: ;
    endcase
  endtask
  task automatic compare();
    int n;
    case (sop)
      U_ENC, U_COPY, U_CSEL: begin
        n = sop == U_ENC ? 32 * int'(sd) : int'(slen);
        for (int i = 0; i < n; i++) if (mem[13'(smb + 13'(i))] != ob[i]) chk_bad = 1;
      end
      U_CMP: begin
        bit dd;
        dd = 0;
        for (int i = 0; i < int'(slen); i++) if (ib[i] != ib2[i]) dd = 1;
        if (diff != dd) chk_bad = 1;
      end
      default: for (int i = 0; i < 256; i++) if (int'(pm[{sdst, 8'(i)}]) != rr[i]) chk_bad = 1;
    endcase
  endtask

  always @(posedge clk) begin
    chk_op <= -1;
    hstep <= 0;
    if (!rst_n) begin
      hn = 0; hfin = 0; sn = 0;
    end else begin
      if (ugo) begin
        hn = 0; hfin = 0; hcnt = 0; hbad = 0; hmd = h_mode; hstr = h_strm;
        hrate = h_mode == 2'd1 ? 72 : h_mode == 2'd2 ? 168 : 136;
        if (u_op != U_NONE) begin
          snap();
          sdiff = diff;
        end
      end else begin
        if (hst == K_ABS && k_in) begin hin[hn] = k_ib; hn++; end
        if (hst == K_ABS && !k_in && kseg == 2'd2) hfinish();
        if (h_wr || hs_valid && hs_ready) begin
          if (!hfin || kbyte != hnext()) hbad = 1;
          hadv();
          if (hs_valid && hs_ready && sn < 2048) begin sbytes[sn] = kbyte; sn++; end
        end
        if (h_done) begin
          // the buffer sink got exactly h_ol bytes
          if (hcnt != 32 * int'(h_ol)) hbad = 1;
          hstep <= 1;
        end
        if (p_done) begin
          chk_bad = 0;
          if (sop == U_CMP) ; else model();
          compare();
          chk_op <= int'(sop);
          if (hstr) hstep <= 2;
        end
      end
    end
  end
  bit hbad_q;
  always @(posedge clk) hbad_q <= hbad != 0;
  wire hash_ok = !hbad_q;
  wire poly_ok = chk_bad == 0;

  `SVA_IMP(a_hash_to_buffer, hstep == 1, hash_ok)
  `SVA_IMP(a_hash_to_sampler, hstep == 2, hash_ok)
  `SVA_IMP(a_ntt, chk_op == int'(U_NTT), poly_ok)
  `SVA_IMP(a_intt, chk_op == int'(U_INTT), poly_ok)
  `SVA_IMP(a_basemul, chk_op == int'(U_BMUL), poly_ok)
  `SVA_IMP(a_add, chk_op == int'(U_ADD), poly_ok)
  `SVA_IMP(a_sub, chk_op == int'(U_SUB), poly_ok)
  `SVA_IMP(a_cbd, chk_op == int'(U_CBD), poly_ok)
  `SVA_IMP(a_sample_ntt, chk_op == int'(U_SAMP), poly_ok)
  `SVA_IMP(a_encode, chk_op == int'(U_ENC), poly_ok)
  `SVA_IMP(a_decode, chk_op == int'(U_DEC), poly_ok)
  `SVA_IMP(a_copy, chk_op == int'(U_COPY), poly_ok)
  `SVA_IMP(a_compare, chk_op == int'(U_CMP), poly_ok)
  `SVA_IMP(a_select, chk_op == int'(U_CSEL), poly_ok)
  `SVA_IMP(a_coeff0_below_q, pw0, int'(pw0_d) < Q)
  `SVA_IMP(a_coeff1_below_q, pw1, int'(pw1_d) < Q)

  // ---------------- host port, control ----------------
  logic [7:0] mir [0:8191];
  logic [10:0] mp;
  logic [1:0] mop, mps;
  bit e_err, m_busy;
  wire m_bsy = m_busy && !done;        // the engine ends with its done pulse
  always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      mp <= '0; e_err <= 0; m_busy <= 0; mop <= '0; mps <= '0;
    end else begin
      e_err <= start && !m_bsy && (op == 2'd3 || pset == 2'd3);
      if (start && !m_bsy && op != 2'd3 && pset != 2'd3) begin m_busy <= 1; mop <= op; mps <= pset; end
      if (done) m_busy <= 0;
      if (hp_load) mp <= hp_addr;
      else if (hw_valid && !m_bsy || hr_en && hr_ready && !m_bsy) mp <= mp + 11'd1;
    end
  end
  // the mirror follows host writes and the engine's own buffer writes (checked above)
  always @(posedge clk) begin
    if (hw_valid && hw_ready) for (int i = 0; i < 4; i++) mir[{mp, 2'(i)}] <= hw_data[8 * i +: 8];
    if (mw) mir[mw_a] <= mw_d;
  end
  wire [31:0] mword = {mir[{mp, 2'd3}], mir[{mp, 2'd2}], mir[{mp, 2'd1}], mir[{mp, 2'd0}]};

  `SVA_INV(a_hw_ready, hw_ready == !m_bsy)
  `SVA_INV(a_hr_valid, hr_valid == (hr_en && !m_bsy))
  `SVA_INV(a_busy, busy == m_bsy)
  `SVA_IMP(a_hr_data, hr_valid, hr_data == mword)
  `SVA_INV(a_err, err == e_err)
  `SVA_IMP(a_done_only_busy, done, $past(m_busy) && !busy)
  `SVA_RST(a_reset, 1'b1, !busy && !done && !err && hst == 2'd0)

  // ---------------- functional coverage ----------------
  int c_opps, c_uop, c_ed, c_dd, c_hm;
  bit v_rej, v_acc, v_sd1_rej, v_sd2_rej, v_spend_last, v_d2_dropped, v_start_busy, v_err_op, v_err_ps,
      v_hw_busy, v_hr_busy, v_hr_stall, v_hw_gap, v_multi_abs, v_multi_sqz, v_reset_busy;
  always @(posedge clk) begin
    c_opps <= done ? int'(mop) * 3 + int'(mps) : -1;
    c_uop <= ugo ? int'(u_op) : -1;
    c_ed <= ugo && u_op == U_ENC ? int'(u_d) : -1;
    c_dd <= ugo && u_op == U_DEC ? int'(u_d) * 2 + int'(u_cmp) : -1;
    c_hm <= ugo && h_on ? int'(h_mode) * 2 + int'(h_strm) : -1;
    if (rst_n) begin
      if (p_done && sop == U_CSEL) begin if (sdiff) v_rej <= 1; else v_acc <= 1; end
      if (hs_valid && hs_ready && sbc == 2'd2 && !spend && sd1 >= 12'(Q)) v_sd1_rej <= 1;
      if (hs_valid && hs_ready && sbc == 2'd2 && !spend && sd2 >= 12'(Q)) v_sd2_rej <= 1;
      if (spend && pcnt == 9'd255) v_spend_last <= 1;
      if (hs_valid && hs_ready && sbc == 2'd2 && !spend && pcnt == 9'd255 && sd1 < 12'(Q) && sd2 < 12'(Q))
        v_d2_dropped <= 1;
      if (start && m_bsy) v_start_busy <= 1;
      if (start && !m_bsy && op == 2'd3) v_err_op <= 1;
      if (start && !m_bsy && op != 2'd3 && pset == 2'd3) v_err_ps <= 1;
      if (hw_valid && m_bsy) v_hw_busy <= 1;
      if (hr_en && m_bsy) v_hr_busy <= 1;
      if (hr_valid && !hr_ready) v_hr_stall <= 1;
      if (hst == K_ABS && k_in && kpos == rate - 8'd1) v_multi_abs <= 1;
      if (hs_valid && hs_ready && kpos == rate - 8'd1) v_multi_sqz <= 1;
    end
  end
  covergroup cg_mlkem @(negedge clk);
    option.per_instance = 1;
    cp_op: coverpoint c_opps iff (c_opps >= 0)
      { bins keygen_512 = {0}; bins keygen_768 = {1}; bins keygen_1024 = {2};
        bins encaps_512 = {3}; bins encaps_768 = {4}; bins encaps_1024 = {5};
        bins decaps_512 = {6}; bins decaps_768 = {7}; bins decaps_1024 = {8}; }
    cp_uop: coverpoint c_uop iff (c_uop >= 0)
      { bins hash = {0}; bins cbd = {1}; bins samp = {2}; bins ntt = {3}; bins intt = {4}; bins bmul = {5};
        bins add = {6}; bins sub = {7}; bins enc = {8}; bins dec = {9}; bins copy = {10}; bins cmp = {11};
        bins csel = {12}; }
    cp_enc_d: coverpoint c_ed iff (c_ed >= 0)
      { bins d1 = {1}; bins d4 = {4}; bins d5 = {5}; bins d10 = {10}; bins d11 = {11}; bins d12 = {12}; }
    cp_dec_d: coverpoint c_dd iff (c_dd >= 0)
      { bins d1 = {3}; bins d4 = {9}; bins d5 = {11}; bins d10 = {21}; bins d11 = {23}; bins d12 = {24}; }
    cp_hash: coverpoint c_hm iff (c_hm >= 0)
      { bins sha3_256 = {0}; bins sha3_512 = {2}; bins shake128_stream = {5}; bins shake256_stream = {7};
        bins shake256_buffer = {6}; }
  endgroup
  cg_mlkem u_cg_mlkem = new;

  `FC(decaps_reject, v_rej)
  `FC(decaps_accept, v_acc)
  `FC(sample_reject_first, v_sd1_rej)
  `FC(sample_reject_second, v_sd2_rej)
  `FC(sample_last_from_second, v_spend_last)
  `FC(sample_second_dropped_at_end, v_d2_dropped)
  `FC(start_while_busy, v_start_busy)
  `FC(reserved_op, v_err_op)
  `FC(reserved_pset, v_err_ps)
  `FC(host_write_while_busy, v_hw_busy)
  `FC(host_read_while_busy, v_hr_busy)
  `FC(host_read_stall, v_hr_stall)
  `FC(absorb_more_than_a_block, v_multi_abs)
  `FC(squeeze_more_than_a_block, v_multi_sqz)
  `FC_RST(reset_while_busy, rst_n && busy ##1 !rst_n)
endmodule

bind ML_KEM_top ML_KEM_sva u_sva (.*);
