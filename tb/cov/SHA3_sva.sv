// SPDX-License-Identifier: Apache-2.0
// SHA3: concurrent SVA against a model built from the ports alone, plus
// functional coverage. The model
//  * has its own Keccak-f[1600] written from FIPS 202 section 3: the round
//    constants come from the rc(t) LFSR (algorithm 5), the rho offsets from
//    the (x, y) -> (y, 2x + 3y) walk, pi and chi from their definitions;
//  * absorbs every accepted word (deciding itself which words are legal),
//    pads the message with the domain bits and pad10*1 and computes the
//    whole expected output stream, one rate block at a time;
//  * knows the clock count of every permutation (24 clocks, plus one for a
//    padding-only lane) and so predicts in_ready, out_valid, out_last,
//    busy, done and err on every clock;
//  * checks that the state register is clear whenever the core is idle.
`include "cov_macros.svh"
module SHA3_sva (
  input logic          clk, rst_n,
  input logic          start,
  input logic [2:0]    mode,
  input logic          in_valid,
  input logic [63:0]   in_data,
  input logic [3:0]    in_bytes,
  input logic          in_last,
  input logic          in_ready,
  input logic          out_valid,
  input logic [63:0]   out_data,
  input logic          out_last,
  input logic          out_ready,
  input logic          busy, done, err,
  // internal: the Keccak state, which must be clear when the core is idle
  input logic [1599:0] ks
);
  `COV_CLOCKING(clk, !rst_n)

  // ---------------- Keccak-f[1600] from FIPS 202 ----------------
  typedef logic [63:0] lane_t;
  lane_t rcs [0:23];
  int    roff [0:4][0:4];
  // rc(t), FIPS 202 algorithm 5, with R[0..8] as an array of bits
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
    int x, y;
    for (int ir = 0; ir < 24; ir++) begin
      rcs[ir] = '0;
      for (int j = 0; j <= 6; j++) rcs[ir][(1 << j) - 1] = rc_bit(j + 7 * ir);
    end
    roff[0][0] = 0;
    x = 1; y = 0;
    for (int t = 0; t < 24; t++) begin
      int nx;
      roff[x][y] = ((t + 1) * (t + 2) / 2) % 64;
      nx = y; y = (2 * x + 3 * y) % 5; x = nx;
    end
  end
  function automatic lane_t rl64(input lane_t v, input int n);
    return (n == 0) ? v : ((v << n) | (v >> (64 - n)));
  endfunction
  function automatic logic [1599:0] keccak_f(input logic [1599:0] s0);
    lane_t a [0:4][0:4];
    lane_t b [0:4][0:4];
    lane_t c [0:4];
    lane_t d [0:4];
    logic [1599:0] s;
    for (int x = 0; x < 5; x++) for (int y = 0; y < 5; y++) a[x][y] = s0[64 * (x + 5 * y) +: 64];
    for (int ir = 0; ir < 24; ir++) begin
      for (int x = 0; x < 5; x++) c[x] = a[x][0] ^ a[x][1] ^ a[x][2] ^ a[x][3] ^ a[x][4];
      for (int x = 0; x < 5; x++) d[x] = c[(x + 4) % 5] ^ rl64(c[(x + 1) % 5], 1);
      for (int x = 0; x < 5; x++) for (int y = 0; y < 5; y++) a[x][y] = a[x][y] ^ d[x];
      for (int x = 0; x < 5; x++) for (int y = 0; y < 5; y++) b[y][(2 * x + 3 * y) % 5] = rl64(a[x][y], roff[x][y]);
      for (int x = 0; x < 5; x++) for (int y = 0; y < 5; y++) a[x][y] = b[x][y] ^ (~b[(x + 1) % 5][y] & b[(x + 2) % 5][y]);
      a[0][0] = a[0][0] ^ rcs[ir];
    end
    for (int x = 0; x < 5; x++) for (int y = 0; y < 5; y++) s[64 * (x + 5 * y) +: 64] = a[x][y];
    return s;
  endfunction

  // ---------------- sponge model ----------------
  function automatic int rate_b(input logic [2:0] m);   // rate in bytes
    case (m)
      3'd0: return 144; 3'd1: return 136; 3'd2: return 104; 3'd3: return 72; 3'd4: return 168; default: return 136;
    endcase
  endfunction
  logic [1599:0] m_s;          // model state
  logic [2:0]    m_md;
  bit            m_abs, m_sqz; // absorbing / squeezing (busy = either)
  int            m_pos;        // absorb or squeeze position in lanes
  int            m_wait;       // clocks until the core is ready again
  int            m_ow;         // output words given
  bit            m_err_n, m_done_n;   // err / done expected on the next clock
  // coverage samples
  int c_mode = -1, c_tb = -1, c_ow = -1;
  bit v_padlane, v_fullend, v_empty, v_xofblk, v_sabs, v_sperm, v_ssqz, v_bad, v_bp, v_gapin, v_multi, v_zero_last;
  bit v_wipe;
  always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      m_s <= '0; m_abs <= 0; m_sqz <= 0; m_pos <= 0; m_wait <= 0; m_ow <= 0; m_err_n <= 0; m_done_n <= 0; m_md <= '0;
    end else begin
      logic [1599:0] s;
      int r, w, pos, ow;
      bit abs, sqz;
      s = m_s; pos = m_pos; w = m_wait; abs = m_abs; sqz = m_sqz; ow = m_ow;
      m_err_n <= 0; m_done_n <= 0;
      c_mode <= -1; c_tb <= -1; c_ow <= -1;
      if (w > 0) w--;                   // the gating below uses m_wait, the count before this clock
      if (start) begin
        if (abs && m_wait > 0) v_sperm <= 1; else if (abs) v_sabs <= 1;
        if (sqz) v_ssqz <= 1;
        s = '0; pos = 0; w = 0; ow = 0; sqz = 0;
        if (mode <= 3'd5) begin abs = 1; m_md <= mode; end
        else begin abs = 0; m_err_n <= 1; if (m_abs || m_sqz) v_wipe <= 1; end
      end else if (abs && m_wait == 0 && in_valid) begin
        r = rate_b(m_md) / 8;
        if (in_bytes > 4'd8 || (!in_last && in_bytes != 4'd8)) begin m_err_n <= 1; v_bad <= 1; end
        else begin
          logic [63:0] msk;
          msk = (in_bytes == 4'd8) ? '1 : ((64'h1 << (8 * int'(in_bytes))) - 1);
          s[64 * pos +: 64] = s[64 * pos +: 64] ^ (in_data & msk);
          if (!in_last) begin
            pos++;
            if (pos == r) begin s = keccak_f(s); pos = 0; w = 24; v_multi <= 1; end
          end else begin
            int padw;
            padw = 0;
            c_mode <= int'(m_md); c_tb <= int'(in_bytes);
            if (in_bytes == 4'd8) begin   // padding in the next lane, a new block if this one was full
              pos++; padw = 1;
              if (pos == r) begin s = keccak_f(s); pos = 0; padw = 25; v_fullend <= 1; end
            end
            if (in_bytes == 4'd0) v_zero_last <= 1;
            if (pos == r - 1) v_padlane <= 1;
            s[64 * pos + 8 * (int'(in_bytes) % 8) +: 8] ^= m_md[2] ? 8'h1F : 8'h06;
            s[64 * (r - 1) + 56 +: 8] ^= 8'h80;
            s = keccak_f(s);
            pos = 0; w = 24 + padw; abs = 0; sqz = 1;
          end
        end
      end else if (sqz && m_wait == 0 && out_ready) begin
        r = rate_b(m_md) / 8;
        ow++;
        if (!m_md[2] && pos == ((m_md == 3'd2) ? 5 : (m_md == 3'd3) ? 7 : 3)) begin
          sqz = 0; s = '0; m_done_n <= 1; c_ow <= -1;
        end else begin
          pos++;
          if (pos == r) begin s = keccak_f(s); pos = 0; w = 24; v_xofblk <= 1; end
        end
      end
      if (abs && in_ready && !in_valid) v_gapin <= 1;
      if (sqz && out_valid && !out_ready) v_bp <= 1;
      m_s <= s; m_pos <= pos; m_wait <= w; m_abs <= abs; m_sqz <= sqz; m_ow <= ow;
    end
  end
  wire        e_last = m_sqz && !m_md[2] && (m_pos == ((m_md == 3'd2) ? 5 : (m_md == 3'd3) ? 7 : 3));
  wire [63:0] e_data = (e_last && m_md == 3'd0) ? {32'h0, m_s[64 * m_pos +: 32]} : m_s[64 * m_pos +: 64];

  // ---------------- assertions ----------------
  `SVA_INV(a_in_ready, in_ready == (m_abs && m_wait == 0))
  `SVA_INV(a_out_valid, out_valid == (m_sqz && m_wait == 0))
  `SVA_IMP(a_out_data, out_valid, out_data == e_data)
  `SVA_IMP(a_out_last, out_valid, out_last == e_last)
  `SVA_INV(a_busy, busy == (m_abs || m_sqz))
  `SVA_INV(a_err, err == m_err_n)
  `SVA_INV(a_done, done == m_done_n)
  `SVA_INV(a_exclusive, !(in_ready && out_valid))
  `SVA_INV(a_wipe_idle, busy || ks == '0)
  `SVA_NXT(a_start_restarts, start, !out_valid && !done)
  `SVA_RST(a_reset, 1'b1, !busy && !in_ready && !out_valid && !done && !err && ks == '0)

  // ---------------- functional coverage ----------------
  covergroup cg_sha3 @(negedge clk);
    option.per_instance = 1;
    cp_mode: coverpoint c_mode iff (c_mode >= 0) { bins m[] = {[0:5]}; }
    // valid bytes of the last word (8: a full last word, 0: an empty one)
    cp_tail: coverpoint c_tb iff (c_mode >= 0) { bins b[] = {[0:8]}; }
    x_mode_tail: cross cp_mode, cp_tail;
  endgroup
  cg_sha3 u_cg_sha3 = new;
  `FC(sha3_224_done, done && m_md == 3'd0)
  `FC(sha3_256_done, done && m_md == 3'd1)
  `FC(sha3_384_done, done && m_md == 3'd2)
  `FC(sha3_512_done, done && m_md == 3'd3)
  `FC(shake128_block2, v_xofblk && m_md == 3'd4 && out_valid)
  `FC(shake256_block2, v_xofblk && m_md == 3'd5 && out_valid)
  `FC(multi_block_message, v_multi)
  `FC(padding_in_last_lane, v_padlane)
  `FC(full_block_then_pad_block, v_fullend)
  `FC(empty_last_word, v_zero_last)
  `FC(start_while_absorbing, v_sabs)
  `FC(start_while_permuting, v_sperm)
  `FC(start_while_squeezing, v_ssqz)
  `FC(reserved_mode_wipe, v_wipe)
  `FC(bad_word, v_bad)
  `FC(input_gap, v_gapin)
  `FC(output_backpressure, v_bp)
  `FC_RST(reset_while_busy, rst_n && busy ##1 !rst_n)
endmodule

bind SHA3_top SHA3_sva u_sva (.*);
