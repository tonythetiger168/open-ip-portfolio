// SPDX-License-Identifier: Apache-2.0
// AES-GCM: concurrent SVA against a model built from the ports alone, plus
// functional coverage. The model
//  * has its own AES (the S-box computed from the inverse in GF(2^8) and the
//    affine map, the round keys expanded into a table as FIPS 197 writes
//    the key schedule) and its own GHASH (SP 800-38D algorithm 1, bit by
//    bit);
//  * takes the configuration at start and computes H and E(K, J0);
//  * applies the block rules (format, order, lengths) to every accepted
//    block and predicts each error and its code, each output block, and the
//    tag and tag_ok of done;
//  * checks the handshake rules, the output hold under back-pressure, a
//    bound on the stall time, and that no secret (key, round key, AES
//    state, H, E(K, J0), GHASH state) is left in the core when it is idle.
`include "cov_macros.svh"
module AES_GCM_sva #(parameter int LEN_W = 36) (
  input logic         clk, rst_n,
  input logic         key256, decrypt, key_sel, sl_valid, start, clr, busy,
  input logic [3:0]   tag_len,
  input logic [255:0] key, sl_key,
  input logic [95:0]  iv,
  input logic [127:0] tag_in, in_data, out_data, tag,
  input logic         in_valid, in_ready, in_aad, in_last, out_valid, out_ready, out_last,
  input logic [4:0]   in_bytes, out_bytes,
  input logic         done, tag_ok, err,
  input logic [2:0]   err_code,
  // internal: the secrets, which must be clear whenever the core is idle
  input logic [255:0] kreg, kw,
  input logic [127:0] st, hk, ej0, gz,
  input logic [95:0]  ga
);
  `COV_CLOCKING(clk, !rst_n)

  // ---------------- AES from its definition ----------------
  logic [7:0] sb [0:255];
  function automatic logic [7:0] gm(input logic [7:0] a, input logic [7:0] b);
    logic [7:0] r;
    r = 0;
    for (int i = 0; i < 8; i++) begin
      if (b[i]) r ^= a;
      a = {a[6:0], 1'b0} ^ (a[7] ? 8'h1b : 8'h00);
    end
    return r;
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
  // the state as a 4 x 4 byte matrix: byte 4c + r of the block is row r, column c
  function automatic logic [127:0] aes(input logic [255:0] k, input logic k256, input logic [127:0] blk);
    logic [31:0] w [0:59];
    logic [7:0]  s [0:15], t [0:15];
    logic [7:0]  rc;
    int nk, nr;
    nk = k256 ? 8 : 4;
    nr = nk + 6;
    for (int i = 0; i < nk; i++) w[i] = k[255 - 32 * i -: 32];
    rc = 8'h01;
    for (int i = nk; i < 4 * (nr + 1); i++) begin
      logic [31:0] x;
      x = w[i - 1];
      if (i % nk == 0) begin
        x = {sb[x[23:16]], sb[x[15:8]], sb[x[7:0]], sb[x[31:24]]} ^ {rc, 24'h0};
        rc = gm(rc, 8'h02);
      end else if (nk == 8 && i % nk == 4) x = {sb[x[31:24]], sb[x[23:16]], sb[x[15:8]], sb[x[7:0]]};
      w[i] = w[i - nk] ^ x;
    end
    for (int b = 0; b < 16; b++) s[b] = blk[127 - 8 * b -: 8] ^ w[b / 4][31 - 8 * (b % 4) -: 8];
    for (int r = 1; r <= nr; r++) begin
      for (int c = 0; c < 4; c++)
        for (int row = 0; row < 4; row++) t[4 * c + row] = sb[s[4 * ((c + row) % 4) + row]];
      for (int c = 0; c < 4; c++)
        for (int row = 0; row < 4; row++)
          if (r == nr) s[4 * c + row] = t[4 * c + row];
          else s[4 * c + row] = gm(t[4 * c + row], 8'h02) ^ gm(t[4 * c + (row + 1) % 4], 8'h03)
                                ^ t[4 * c + (row + 2) % 4] ^ t[4 * c + (row + 3) % 4];
      for (int b = 0; b < 16; b++) s[b] ^= w[4 * r + b / 4][31 - 8 * (b % 4) -: 8];
    end
    for (int b = 0; b < 16; b++) aes[127 - 8 * b -: 8] = s[b];
  endfunction
  // ---------------- GF(2^128), SP 800-38D algorithm 1 ----------------
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

  // ---------------- model ----------------
  localparam longint AMAX = (64'd1 << LEN_W) - 1, TMAX = (64'd1 << LEN_W) - 32;
  logic         m_busy, m_k256, m_dec, m_last, m_txt, m_apart, m_lastdec;
  logic [3:0]   m_tlen;
  logic [255:0] m_key;
  logic [95:0]  m_iv;
  logic [127:0] m_h, m_e0, m_s, m_tag;
  longint       m_alen, m_clen;
  logic [31:0]  m_ctr;
  logic         m_ov, m_ol;             // output block expected
  logic [127:0] m_od;
  logic [4:0]   m_ob;
  logic         m_err;                  // an error must be signalled in this clock
  logic [2:0]   m_ecode, m_code_q;      // its code; the code err_code must hold
  int           m_stall, m_fin;
  // events for the coverage
  logic         v_hs, v_err;
  int           c_kind;                 // class of an accepted block (-1 none)
  int           c_res;                  // class of a finished message (-1 none)
  int           c_err;                  // code of an error (-1 none)
  int           c_clr;                  // phase of a clr (-1 none)
  int           m_nblk;                 // blocks taken in this message
  logic         m_bp, m_stl;            // back-pressure / input stall seen in this message

  wire hs = in_valid && in_ready;
  wire [3:0] m_nr = m_k256 ? 4'd14 : 4'd10;
  always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      m_busy <= 0; m_k256 <= 0; m_dec <= 0; m_last <= 0; m_txt <= 0; m_apart <= 0; m_lastdec <= 0;
      m_tlen <= 0; m_key <= 0; m_iv <= 0; m_h <= 0; m_e0 <= 0; m_s <= 0; m_tag <= 0;
      m_alen <= 0; m_clen <= 0; m_ctr <= 0; m_ov <= 0; m_ol <= 0; m_od <= 0; m_ob <= 0;
      m_err <= 0; m_ecode <= 0; m_code_q <= 0; m_stall <= 0; m_fin <= 0;
      c_kind <= -1; c_res <= -1; c_err <= -1; c_clr <= -1; m_nblk <= 0; m_bp <= 0; m_stl <= 0;
    end else begin
      logic [2:0] e;
      logic       ne;
      m_err <= 0;
      c_kind <= -1; c_res <= -1; c_err <= -1; c_clr <= -1;
      if (out_valid && out_ready) m_ov <= 0;
      if (busy && out_valid && !out_ready) m_bp <= 1;
      if (busy && in_valid && !in_ready && !m_last) m_stl <= 1;
      // stall: running, data offered or not, no output pending, but not ready
      m_stall <= m_busy && !m_last && !out_valid && !in_ready && !clr ? m_stall + 1 : 0;
      m_fin <= m_busy && m_last && !out_valid && !done && !clr ? m_fin + 1 : 0;
      if (clr) begin
        if (m_busy) c_clr <= !m_last ? (m_nblk == 0 ? 0 : m_txt ? 2 : 1) : out_valid ? 3 : 4;
        m_busy <= 0; m_ov <= 0;
      end else begin
        if (done) begin
          m_busy <= 0;
          c_res <= {m_k256, m_dec, m_dec && tag_ok} + 0;
        end
        if (start && (!m_busy || done)) begin
          if (key_sel && !sl_valid) begin
            m_err <= 1; m_ecode <= 3'd4; m_code_q <= 3'd4; c_err <= 4;
          end else begin
            logic [255:0] k;
            k = key_sel ? sl_key : key;
            if (!key256) k[127:0] = 0;
            m_busy <= 1; m_k256 <= key256; m_dec <= decrypt; m_lastdec <= decrypt; m_tlen <= tag_len;
            m_key <= k; m_iv <= iv;
            m_h <= aes(k, key256, 128'h0);
            m_e0 <= aes(k, key256, {iv, 32'd1});
            m_s <= 0; m_alen <= 0; m_clen <= 0; m_ctr <= 2; m_last <= 0; m_txt <= 0; m_apart <= 0;
            m_code_q <= 0; m_nblk <= 0; m_bp <= 0; m_stl <= 0;
          end
        end
        if (hs && m_busy) begin
          ne = in_bytes != 0;
          e = in_bytes > 16 || !ne && !in_last ? 3'd1
            : ne && in_aad && (m_txt || m_apart) ? 3'd2
            : ne && !in_aad && in_bytes != 16 && !in_last ? 3'd2
            : ne && in_aad && m_alen + in_bytes > AMAX ? 3'd3
            : ne && !in_aad && m_clen + in_bytes > TMAX ? 3'd3 : 3'd0;
          m_nblk <= m_nblk + 1;
          c_kind <= !ne ? 0 : (in_aad ? 1 : 3) + (in_bytes != 16 ? 1 : 0);
          if (e != 0) begin
            m_err <= 1; m_ecode <= e; m_code_q <= e; c_err <= e; m_busy <= 0; m_ov <= 0;
          end else begin
            logic [127:0] x, s;
            s = m_s;
            if (ne && in_aad) begin
              s = gfmul(s ^ (in_data & bm(in_bytes)), m_h);
              m_alen <= m_alen + in_bytes;
              m_apart <= in_bytes != 16;
            end
            if (ne && !in_aad) begin
              x = (in_data ^ aes(m_key, m_k256, {m_iv, m_ctr})) & bm(in_bytes);
              s = gfmul(s ^ (m_dec ? in_data & bm(in_bytes) : x), m_h);
              m_ctr <= m_ctr + 1;
              m_clen <= m_clen + in_bytes;
              m_txt <= 1;
              m_ov <= 1; m_od <= x; m_ob <= in_bytes; m_ol <= in_last;
            end
            m_s <= s;
            if (in_last) begin
              logic [63:0] la, lc;
              la = 64'(m_alen + (ne && in_aad ? in_bytes : 0)) << 3;
              lc = 64'(m_clen + (ne && !in_aad ? in_bytes : 0)) << 3;
              m_last <= 1;
              m_tag <= gfmul(s ^ {la, lc}, m_h) ^ m_e0;
            end
          end
        end
      end
    end
  end
  wire [127:0] m_tm = bm(m_tlen == 0 ? 16 : int'(m_tlen));

  // ---------------- assertions ----------------
  `SVA_INV(a_busy, done ? !busy && m_busy : busy == m_busy)
  `SVA_IMP(a_ready_only_running, in_ready, busy && !m_last && !out_valid)
  `SVA_INV(a_output_expected, out_valid == m_ov)
  `SVA_IMP(a_output_block, out_valid, out_data == m_od && out_bytes == m_ob && out_last == m_ol)
  `SVA_IMP(a_output_hold, out_valid && !out_ready && !clr, ##1 out_valid && $stable(out_data) && $stable(out_bytes)
                                                          && $stable(out_last))
  `SVA_INV(a_error_pulse, err == m_err)
  `SVA_IMP(a_error_code, err, err_code == m_ecode)
  `SVA_INV(a_error_code_held, err_code == m_code_q)
  `SVA_IMP(a_done_only_at_end, done, m_last && !out_valid)
  `SVA_IMP(a_tag_encrypt, done && !m_dec, tag == m_tag && !tag_ok)
  `SVA_IMP(a_tag_decrypt, done && m_dec, tag == 128'h0 && tag_ok == (((m_tag ^ tag_in) & m_tm) == 0))
  `SVA_IMP(a_result_cleared_in_message, busy, tag == 128'h0 && !tag_ok)
  `SVA_IMP(a_no_tag_after_decrypt, m_lastdec, tag == 128'h0)
  `SVA_IMP(a_result_held, !done && !(start && !busy), ##1 done || $stable(tag) && $stable(tag_ok))
  `SVA_INV(a_stall_bound, m_stall <= 3 * int'(m_nr) + 3)
  `SVA_INV(a_end_bound, m_fin <= 10)
  `SVA_IMP(a_idle_no_secret, !busy, kreg == 0 && kw == 0 && st == 0 && hk == 0 && ej0 == 0 && gz == 0 && ga == 0)
  `SVA_IMP(a_aes128_key_half, busy && !m_k256, kreg[127:0] == 0)
  `SVA_RST(a_reset, 1'b1, !busy && !in_ready && !out_valid && !done && !err && tag == 0 && !tag_ok && err_code == 0)

  // ---------------- functional coverage ----------------
  logic s_k256, s_dec, s_ks, s_tl;
  int   s_tlen;
  always @(posedge clk) if (start && !busy) begin
    s_k256 <= key256; s_dec <= decrypt; s_ks <= key_sel; s_tlen <= tag_len;
  end
  covergroup cg_gcm @(negedge clk);
    option.per_instance = 1;
    // finished messages: key size x direction x tag result
    cp_res: coverpoint c_res iff (c_res >= 0) {
      bins aes128_enc = {0}; bins aes128_dec_fail = {2}; bins aes128_dec_ok = {3};
      bins aes256_enc = {4}; bins aes256_dec_fail = {6}; bins aes256_dec_ok = {7};
    }
    // accepted blocks: empty end block, AAD full / partial, text full / partial
    cp_kind: coverpoint c_kind iff (c_kind >= 0) {
      bins end_block = {0}; bins aad_full = {1}; bins aad_part = {2}; bins text_full = {3}; bins text_part = {4};
    }
    cp_err: coverpoint c_err iff (c_err >= 0) { bins format = {1}; bins order = {2}; bins too_long = {3}; bins key = {4}; }
    cp_clr: coverpoint c_clr iff (c_clr >= 0) {
      bins before_data = {0}; bins in_aad = {1}; bins in_text = {2}; bins end_output_held = {3}; bins end_tag = {4};
    }
    cp_tlen: coverpoint s_tlen iff (c_res >= 0 && s_dec) { bins t[] = {[0:15]}; }
    cp_ks: coverpoint s_ks iff (c_res >= 0) { bins key_port = {0}; bins sideload = {1}; }
    cp_k256: coverpoint s_k256 iff (c_res >= 0);
    x_ks: cross cp_ks, cp_k256;
  endgroup
  cg_gcm u_cg_gcm = new;

  `FC(back_pressure, busy && out_valid && !out_ready)
  `FC(input_stall, busy && in_valid && !in_ready)
  `FC(start_while_busy, start && busy)
  `FC(clr_and_start, clr && start && !busy)
  `FC(aad_limit, done && m_alen == AMAX)
  `FC(text_limit, done && m_clen == TMAX)
  `FC(empty_message, done && m_alen == 0 && m_clen == 0)
  `FC(aad_only, done && m_alen != 0 && m_clen == 0)
  `FC(text_only, done && m_alen == 0 && m_clen != 0)
  `FC(start_after_done, $past(done) && start && !busy)
  `FC(decrypt_truncated_ok, done && m_dec && tag_ok && m_tlen != 0)
  `FC(decrypt_truncated_fail, done && m_dec && !tag_ok && m_tlen != 0)
  `FC_RST(reset_while_busy, rst_n && busy ##1 !rst_n)
endmodule

bind AES_GCM_top AES_GCM_sva #(.LEN_W(LEN_W)) u_sva (.*);
