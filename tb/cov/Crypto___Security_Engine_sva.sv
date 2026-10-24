// SPDX-License-Identifier: Apache-2.0
// SHA-256 / HMAC-SHA-256 engine: the checker keeps its own copy of the
// message and key blocks from the write ports and, on each accepted start,
// computes the expected digest with a behavioural SHA-256 (byte-array
// padding, 64-entry schedule, no shared code with the RTL). It checks the
// digest at done, the done latency, busy, and the irq rules.
`include "cov_macros.svh"
module Crypto___Security_Engine_sva (
  input logic         clk, rst_n, msg_we, key_we, start, mode, busy, done, irq,
  input logic [1:0]   msg_widx, key_widx,
  input logic [127:0] msg, key,
  input logic [6:0]   msg_len,
  input logic [255:0] digest
);
  `COV_CLOCKING(clk, !rst_n)

  localparam logic [31:0] K [0:63] = '{
    32'h428a2f98, 32'h71374491, 32'hb5c0fbcf, 32'he9b5dba5, 32'h3956c25b, 32'h59f111f1, 32'h923f82a4, 32'hab1c5ed5,
    32'hd807aa98, 32'h12835b01, 32'h243185be, 32'h550c7dc3, 32'h72be5d74, 32'h80deb1fe, 32'h9bdc06a7, 32'hc19bf174,
    32'he49b69c1, 32'hefbe4786, 32'h0fc19dc6, 32'h240ca1cc, 32'h2de92c6f, 32'h4a7484aa, 32'h5cb0a9dc, 32'h76f988da,
    32'h983e5152, 32'ha831c66d, 32'hb00327c8, 32'hbf597fc7, 32'hc6e00bf3, 32'hd5a79147, 32'h06ca6351, 32'h14292967,
    32'h27b70a85, 32'h2e1b2138, 32'h4d2c6dfc, 32'h53380d13, 32'h650a7354, 32'h766a0abb, 32'h81c2c92e, 32'h92722c85,
    32'ha2bfe8a1, 32'ha81a664b, 32'hc24b8b70, 32'hc76c51a3, 32'hd192e819, 32'hd6990624, 32'hf40e3585, 32'h106aa070,
    32'h19a4c116, 32'h1e376c08, 32'h2748774c, 32'h34b0bcb5, 32'h391c0cb3, 32'h4ed8aa4a, 32'h5b9cca4f, 32'h682e6ff3,
    32'h748f82ee, 32'h78a5636f, 32'h84c87814, 32'h8cc70208, 32'h90befffa, 32'ha4506ceb, 32'hbef9a3f7, 32'hc67178f2};

  function automatic logic [31:0] rotr(input logic [31:0] x, input int n);
    return (x >> n) | (x << (32 - n));
  endfunction

  // SHA-256 of buf[0:n-1] (n <= 128)
  function automatic logic [255:0] sha(input logic [7:0] b [0:191], input int n);
    logic [7:0]  p [0:191];
    logic [31:0] h [0:7], w [0:63];
    logic [31:0] a, bb, c, d, e, f, g, hh, s0, s1, t1, t2;
    int nb;
    logic [63:0] bits;
    h = '{32'h6a09e667, 32'hbb67ae85, 32'h3c6ef372, 32'ha54ff53a,
          32'h510e527f, 32'h9b05688c, 32'h1f83d9ab, 32'h5be0cd19};
    nb = (n + 9 + 63) / 64;
    bits = 64'(n) * 8;
    for (int i = 0; i < 192; i++)
      p[i] = i < n ? b[i] : i == n ? 8'h80 : 8'h00;
    for (int i = 0; i < 8; i++) p[nb * 64 - 1 - i] = bits[8 * i +: 8];
    for (int blk = 0; blk < 3; blk++) if (blk < nb) begin
      for (int t = 0; t < 64; t++)
        if (t < 16) w[t] = {p[blk*64+4*t], p[blk*64+4*t+1], p[blk*64+4*t+2], p[blk*64+4*t+3]};
        else begin
          s0 = rotr(w[t-15], 7) ^ rotr(w[t-15], 18) ^ (w[t-15] >> 3);
          s1 = rotr(w[t-2], 17) ^ rotr(w[t-2], 19) ^ (w[t-2] >> 10);
          w[t] = w[t-16] + s0 + w[t-7] + s1;
        end
      {a, bb, c, d, e, f, g, hh} = {h[0], h[1], h[2], h[3], h[4], h[5], h[6], h[7]};
      for (int t = 0; t < 64; t++) begin
        t1 = hh + (rotr(e, 6) ^ rotr(e, 11) ^ rotr(e, 25)) + ((e & f) ^ (~e & g)) + K[t] + w[t];
        t2 = (rotr(a, 2) ^ rotr(a, 13) ^ rotr(a, 22)) + ((a & bb) ^ (a & c) ^ (bb & c));
        hh = g; g = f; f = e; e = d + t1; d = c; c = bb; bb = a; a = t1 + t2;
      end
      h[0] += a; h[1] += bb; h[2] += c; h[3] += d; h[4] += e; h[5] += f; h[6] += g; h[7] += hh;
    end
    return {h[0], h[1], h[2], h[3], h[4], h[5], h[6], h[7]};
  endfunction

  // shadow blocks, byte 0 first
  logic [7:0] m_msg [0:63], m_key [0:63];
  logic [255:0] m_exp;
  logic m_busy, m_hm;
  int   m_cyc, m_lat;
  logic [6:0] m_len;
  wire  bz   = m_busy && !done;        // done rises as the engine goes idle
  wire  acc  = start && !bz && msg_len <= 7'd64;
  wire  rej  = start && !bz && msg_len > 7'd64;
  wire  viol = (start || msg_we || key_we) && bz;

  function automatic logic [255:0] expect_digest(input logic hm, input int n);
    logic [7:0] b [0:191];
    logic [255:0] inner;
    for (int i = 0; i < 192; i++) b[i] = 8'h00;
    if (!hm) begin
      for (int i = 0; i < 64; i++) b[i] = m_msg[i];
      return sha(b, n);
    end
    for (int i = 0; i < 64; i++) b[i] = m_key[i] ^ 8'h36;
    for (int i = 0; i < 64; i++) b[64 + i] = m_msg[i];
    inner = sha(b, 64 + n);
    for (int i = 0; i < 192; i++) b[i] = 8'h00;
    for (int i = 0; i < 64; i++) b[i] = m_key[i] ^ 8'h5c;
    for (int i = 0; i < 32; i++) b[64 + i] = inner[255 - 8 * i -: 8];
    return sha(b, 96);
  endfunction

  // blocks compressed: (HMAC key block) + 1 or 2 message blocks (+ 2 outer)
  function automatic int nblocks(input logic hm, input logic [6:0] n);
    return (hm ? 3 : 0) + (n > 55 ? 2 : 1);
  endfunction

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      m_busy <= 0; m_cyc <= 0; m_lat <= 0; m_hm <= 0; m_len <= 0; m_exp <= '0;
      for (int i = 0; i < 64; i++) begin m_msg[i] <= 0; m_key[i] <= 0; end
    end else begin
      if (msg_we && !bz) for (int i = 0; i < 16; i++) m_msg[16 * msg_widx + i] <= msg[127 - 8 * i -: 8];
      if (key_we && !bz) for (int i = 0; i < 16; i++) m_key[16 * key_widx + i] <= key[127 - 8 * i -: 8];
      m_cyc <= m_cyc + 1;
      if (done) m_busy <= 0;
      if (acc) begin
        m_busy <= 1; m_cyc <= 1; m_hm <= mode; m_len <= msg_len;
        m_lat <= 2 + 66 * nblocks(mode, msg_len);
      end
      if (m_busy && m_cyc == 1) m_exp <= expect_digest(m_hm, int'(m_len));
    end
  end

  `SVA_RST(a_reset_quiet, !rst_n, !busy && !done && !irq && digest == '0)
  `SVA_INV(a_busy_model, busy == bz)
  `SVA_IMP(a_digest, done, digest == m_exp)
  `SVA_IMP(a_latency, done, m_cyc == m_lat)
  `SVA_IMP(a_done_only_when_busy, done, m_busy)
  `SVA_NXT(a_violation_irq, viol || rej, irq)
  `SVA_NXT(a_no_spurious_irq, !viol && !rej, !irq)
  `SVA_NXT(a_reject_stays_idle, rej, !busy)

  `FC(sha_len0, acc && !mode && msg_len == 0)
  `FC(sha_len55, acc && !mode && msg_len == 55)
  `FC(sha_len56, acc && !mode && msg_len == 56)
  `FC(sha_len64, acc && !mode && msg_len == 64)
  `FC(hmac_len0, acc && mode && msg_len == 0)
  `FC(hmac_len56, acc && mode && msg_len == 56)
  `FC(hmac_len64, acc && mode && msg_len == 64)
  `FC(start_while_busy, start && bz)
  `FC(msg_write_while_busy, msg_we && bz)
  `FC(key_write_while_busy, key_we && bz)
  `FC(len_rejected, rej)
  `FC(back_to_back, done ##[1:12] acc)
  `FC_RST(reset_while_hashing, rst_n && busy ##1 !rst_n)

  covergroup cg_len @(posedge clk iff (rst_n && acc));
    coverpoint msg_len { bins zero = {0}; bins one_block[] = {1, 55}; bins two_block[] = {56, 63, 64};
                         bins mid = {[2:53]}; bins tail = {[57:62]}; }
    coverpoint mode;
    cp_mode: coverpoint mode { bins sha = {0}; bins hmac = {1}; }
    cp_lcls: coverpoint msg_len { bins zero = {0}; bins one_block = {[1:55]}; bins two_block = {[56:64]}; }
    x_mode_len: cross cp_mode, cp_lcls;
  endgroup
  cg_len u_cg = new();
  // message / key loads: every word slot with each data class
  function automatic int dcls(input logic [127:0] v);
    dcls = v == 0 ? 0 : &v ? 1 : (v == {4{32'h5555_5555}} || v == {4{32'hAAAA_AAAA}}) ? 2 : 3;
  endfunction
  covergroup cg_load @(posedge clk);
    cp_midx: coverpoint msg_widx iff (rst_n && msg_we && !bz) { bins w[] = {[0:3]}; }
    cp_mdat: coverpoint dcls(msg) iff (rst_n && msg_we && !bz) { bins zero = {0}; bins ones = {1}; bins alt = {2}; bins other = {3}; }
    x_msg: cross cp_midx, cp_mdat;
    cp_kidx: coverpoint key_widx iff (rst_n && key_we && !bz) { bins w[] = {[0:3]}; }
    cp_kdat: coverpoint dcls(key) iff (rst_n && key_we && !bz) { bins zero = {0}; bins ones = {1}; bins alt = {2}; bins other = {3}; }
    x_key: cross cp_kidx, cp_kdat;
  endgroup
  cg_load u_cg_load = new();
endmodule

bind Crypto___Security_Engine_top Crypto___Security_Engine_sva u_sva (.*);
