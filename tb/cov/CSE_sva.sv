// SPDX-License-Identifier: Apache-2.0
// CSE AES-128 engine: the checker has its own AES-128 (S-box generated
// at time 0 from the GF(2^8) inverse and the affine map, byte-array
// rounds, separate key schedule), tracks the key register from the write
// port, and predicts busy, the 21-cycle latency, done, dout and the
// protocol-violation irq.
`include "cov_macros.svh"
module CSE_sva (
  input logic         clk, rst_n, key_we, start, enc_dec, busy, done, irq,
  input logic [1:0]   key_widx,
  input logic [31:0]  key,
  input logic [127:0] din, dout
);
  `COV_CLOCKING(clk, !rst_n)

  logic [7:0] SB [0:255], ISB [0:255];
  function automatic logic [7:0] gmul(input logic [7:0] a, input logic [7:0] b);
    logic [7:0] p;
    p = 0;
    for (int i = 0; i < 8; i++) begin
      if (b[i]) p ^= a;
      a = {a[6:0], 1'b0} ^ (a[7] ? 8'h1b : 8'h00);
    end
    return p;
  endfunction
  initial begin
    for (int x = 0; x < 256; x++) begin
      logic [7:0] inv, s;
      inv = 0;
      for (int y = 1; y < 256; y++) if (gmul(8'(x), 8'(y)) == 8'h01) inv = 8'(y);
      s = inv ^ {inv[6:0], inv[7]} ^ {inv[5:0], inv[7:6]} ^ {inv[4:0], inv[7:5]} ^ {inv[3:0], inv[7:4]} ^ 8'h63;
      SB[x] = s; ISB[s] = 8'(x);
    end
  end

  typedef logic [7:0] blk_t [0:15];
  function automatic blk_t unpack(input logic [127:0] v);
    for (int i = 0; i < 16; i++) unpack[i] = v[127 - 8*i -: 8];
  endfunction
  function automatic logic [127:0] pack(input blk_t b);
    for (int i = 0; i < 16; i++) pack[127 - 8*i -: 8] = b[i];
  endfunction

  function automatic logic [127:0] aes(input logic [127:0] k, input logic [127:0] d, input bit enc);
    blk_t rk [0:10];
    blk_t s, t;
    logic [7:0] rc;
    rk[0] = unpack(k); rc = 8'h01;
    for (int r = 1; r <= 10; r++) begin
      for (int i = 0; i < 4; i++) rk[r][i] = rk[r-1][i] ^ SB[rk[r-1][12 + (i + 1) % 4]] ^ (i == 0 ? rc : 8'h00);
      for (int i = 4; i < 16; i++) rk[r][i] = rk[r-1][i] ^ rk[r][i - 4];
      rc = gmul(rc, 8'h02);
    end
    s = unpack(d);
    if (enc) begin
      for (int i = 0; i < 16; i++) s[i] ^= rk[0][i];
      for (int r = 1; r <= 10; r++) begin
        for (int i = 0; i < 16; i++) t[i] = SB[s[(i + 4 * (i % 4)) % 16]];   // SubBytes + ShiftRows
        if (r < 10)
          for (int c = 0; c < 4; c++)
            for (int j = 0; j < 4; j++)
              s[4*c + j] = gmul(t[4*c + j], 2) ^ gmul(t[4*c + (j+1)%4], 3) ^ t[4*c + (j+2)%4] ^ t[4*c + (j+3)%4];
        else s = t;
        for (int i = 0; i < 16; i++) s[i] ^= rk[r][i];
      end
    end else begin
      for (int i = 0; i < 16; i++) s[i] ^= rk[10][i];
      for (int r = 9; r >= 0; r--) begin
        for (int i = 0; i < 16; i++) t[(i + 4 * (i % 4)) % 16] = ISB[s[i]];  // InvShiftRows + InvSubBytes
        for (int i = 0; i < 16; i++) t[i] ^= rk[r][i];
        if (r > 0)
          for (int c = 0; c < 4; c++)
            for (int j = 0; j < 4; j++)
              s[4*c + j] = gmul(t[4*c + j], 14) ^ gmul(t[4*c + (j+1)%4], 11) ^
                           gmul(t[4*c + (j+2)%4], 13) ^ gmul(t[4*c + (j+3)%4], 9);
        else s = t;
      end
    end
    return pack(s);
  endfunction

  logic [127:0] m_key, m_res;
  int           cnt;                  // cycles of busy left
  logic         m_mode;
  logic f_kw_busy, f_st_busy, f_kw_and_start, f_b2b;
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      m_key <= 0; m_res <= 0; cnt <= 0; m_mode <= 0;
      {f_kw_busy, f_st_busy, f_kw_and_start, f_b2b} <= '0;
    end else begin
      {f_kw_busy, f_st_busy, f_kw_and_start, f_b2b} <= '0;
      if (key_we && cnt == 0) m_key[127 - 32*key_widx -: 32] <= key;
      f_kw_busy <= key_we && cnt != 0;
      f_st_busy <= start && cnt != 0;
      if (cnt != 0) cnt <= cnt - 1;
      else if (start) begin
        cnt <= 21; m_mode <= enc_dec; m_res <= aes(m_key, din, enc_dec);
        f_kw_and_start <= key_we; f_b2b <= done;
      end
    end
  end

  `SVA_RST(a_reset_idle, !rst_n, !busy && !done && !irq && dout == 0)
  `SVA_INV(a_busy, busy == (cnt != 0))
  `SVA_NXT(a_done_after_21, cnt == 1, done && dout == m_res)
  `SVA_IMP(a_done_only_at_end, done, $past(cnt) == 1)
  `SVA_NXT(a_irq, 1'b1, irq == $past((key_we || start) && cnt != 0))

  // per operation: direction x plaintext / ciphertext class, direction x
  // key class, direction of the previous operation x this one, every key
  // word written while idle; decrypt of the previous encrypt's result
  // (round trip) and a changed / reused key between operations
  function automatic logic [1:0] bcls(input logic [127:0] v);
    bcls = (v == '0) ? 2'd0 : (v == '1) ? 2'd1 : 2'd2;
  endfunction
  wire op_go = start && cnt == 0;
  logic         m_prev_v, m_prev_mode;
  logic [127:0] m_prev_key, m_prev_res;
  always_ff @(posedge clk or negedge rst_n)
    if (!rst_n) begin m_prev_v <= 0; m_prev_mode <= 0; m_prev_key <= 0; m_prev_res <= 0; end
    else if (op_go) begin
      m_prev_v <= 1; m_prev_mode <= enc_dec; m_prev_key <= m_key; m_prev_res <= aes(m_key, din, enc_dec);
    end
  covergroup cg_op @(posedge clk);
    option.per_instance = 1;
    cp_mode: coverpoint enc_dec iff (rst_n && op_go) { bins dec = {0}; bins enc = {1}; }
    cp_din: coverpoint bcls(din) iff (rst_n && op_go) { bins zero = {0}; bins ones = {1}; bins other = {2}; }
    cp_key: coverpoint bcls(m_key) iff (rst_n && op_go) { bins zero = {0}; bins ones = {1}; bins other = {2}; }
    x_mode_din: cross cp_mode, cp_din;
    x_mode_key: cross cp_mode, cp_key;
    cp_prev: coverpoint m_prev_mode iff (rst_n && op_go && m_prev_v) { bins dec = {0}; bins enc = {1}; }
    x_seq: cross cp_prev, cp_mode;
    cp_kidx: coverpoint key_widx iff (rst_n && key_we && cnt == 0);
  endgroup
  cg_op u_cg_op = new;
  `FC(round_trip_decrypt, op_go && !enc_dec && m_prev_v && m_prev_mode && din == m_prev_res &&
      m_key == m_prev_key)
  `FC(key_changed_between_ops, op_go && m_prev_v && m_key != m_prev_key)
  `FC(key_reused_between_ops, op_go && m_prev_v && m_key == m_prev_key)

  `FC(encrypt_done, done && m_mode)
  `FC(decrypt_done, done && !m_mode)
  `FC(key_write_while_busy, f_kw_busy)
  `FC(start_while_busy, f_st_busy)
  `FC(key_write_and_start_same_cycle, f_kw_and_start)
  `FC(start_in_done_cycle, f_b2b)
  `FC(all_ones_data, start && cnt == 0 && din == '1)
  `FC_RST(reset_while_busy, rst_n && busy ##1 !rst_n)
endmodule

bind CSE_top CSE_sva u_sva (.*);
