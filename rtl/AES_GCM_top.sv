// SPDX-License-Identifier: Apache-2.0
// ============================================================================
// AES_GCM_top v1.0: AES-GCM authenticated encryption engine (NIST SP 800-38D)
// with AES-128 and AES-256 (FIPS 197) and a 96-bit IV.
// ----------------------------------------------------------------------------
//  - AES: one round per clock with the round keys expanded on the fly (four
//    S-boxes for the key, sixteen for the state); a block takes Nr + 1 clocks
//    (11 for AES-128, 15 for AES-256). Only the forward cipher is needed: GCM
//    decrypts with the same key stream.
//  - The AES runs ahead of the data: after H = E(K, 0) and E(K, J0) it
//    encrypts the next counter block while the current one is being used, so
//    text blocks stream at one per Nr + 1 clocks.
//  - GHASH: multiplication by H in GF(2^128), 32 bits of the operand per
//    clock (4 clocks per block); it runs in parallel with the AES of the
//    next counter block. AAD blocks stream at one per 4 clocks.
//  - A message is started with start (key, IV and mode are taken then), then
//    streamed in as 128-bit blocks: first the AAD blocks (in_aad = 1), then
//    the text blocks; only the last block of each kind may be partial
//    (in_bytes 1..15), and in_last marks the last block of the message. A
//    block with in_bytes = 0 and in_last = 1 ends a message without adding
//    data (an empty message, or AAD whose last block was already sent).
//    Data is big-endian: byte 0 of a block is in_data[127:120].
//  - Each text block comes out on the output port (ciphertext when
//    encrypting, plaintext when decrypting), bytes past out_bytes zero.
//  - Encrypt: done pulses with the 128-bit tag on tag. Decrypt: the tag is
//    computed, compared in constant time with the first tag_len bytes of
//    tag_in, and only the result (tag_ok) is given: the computed tag of a
//    decryption is never output, so the engine cannot be used to forge a
//    tag. The plaintext comes out before the tag is checked: it must be held
//    back until tag_ok.
//  - Key: from the key port, or (key_sel = 1) from a sideload port that a
//    key manager (e.g. Root_of_Trust key_out) drives and software cannot
//    read. The key, H, E(K, J0), the AES and GHASH state are cleared when a
//    message ends (done, an error, or clr).
//  - Errors (err pulses, err_code holds the cause, the message is dropped):
//    1 format (in_bytes > 16, or 0 without in_last), 2 order (AAD after text,
//    a block after a partial block of its kind), 3 too long (AAD over
//    2^LEN_W - 1 bytes, text over 2^LEN_W - 32 bytes: at LEN_W = 36 the
//    SP 800-38D limit of 2^32 - 2 counter blocks), 4 sideload key not valid.
// ============================================================================
module AES_GCM_top #(
  parameter int LEN_W = 36              // AAD and text byte counters (8..36)
) (
  input  logic         clk,
  input  logic         rst_n,
  // configuration, taken at start (tag_in is used when the message ends)
  input  logic         key256,           // 0 AES-128 (key[255:128]), 1 AES-256
  input  logic         decrypt,
  input  logic         key_sel,          // 0 key, 1 sideload key
  input  logic [3:0]   tag_len,          // bytes of tag_in compared (decrypt), 0 = 16
  input  logic [255:0] key,
  input  logic [95:0]  iv,
  input  logic [127:0] tag_in,
  // sideload key
  input  logic [255:0] sl_key,
  input  logic         sl_valid,
  // commands
  input  logic         start,            // ignored while busy
  input  logic         clr,              // abort and clear
  output logic         busy,
  // input blocks
  input  logic         in_valid,
  output logic         in_ready,
  input  logic [127:0] in_data,
  input  logic [4:0]   in_bytes,
  input  logic         in_aad,
  input  logic         in_last,
  // output text blocks
  output logic         out_valid,
  input  logic         out_ready,
  output logic [127:0] out_data,
  output logic [4:0]   out_bytes,
  output logic         out_last,
  // result
  output logic         done,
  output logic [127:0] tag,
  output logic         tag_ok,
  output logic         err,
  output logic [2:0]   err_code
);
  localparam int CW = LEN_W - 4;        // counter block number width
  localparam logic [LEN_W-1:0] TXT_MAX = LEN_W'((64'd1 << LEN_W) - 64'd32);
  localparam logic [1:0] E_FMT = 2'd1, E_ORDER = 2'd2, E_LEN = 2'd3;   // block errors; 4: sideload key

  // ---------------- AES primitives ----------------
  // S-box table: entry x is SB[8x+7:8x]
  wire [2047:0] SB = {
    256'h16bb54b00f2d99416842e6bf0d89a18cdf2855cee9871e9b948ed9691198f8e1,
    256'h9e1dc186b95735610ef6034866b53e708a8bbd4b1f74dde8c6b4a61c2e2578ba,
    256'h08ae7a65eaf4566ca94ed58d6d37c8e779e4959162acd3c25c2406490a3a32e0,
    256'hdb0b5ede14b8ee4688902a22dc4f816073195d643d7ea7c41744975fec130ccd,
    256'hd2f3ff1021dab6bcf5389d928f40a351a89f3c507f02f94585334d43fbaaefd0,
    256'hcf584c4a39becb6a5bb1fc20ed00d153842fe329b3d63b52a05a6e1b1a2c8309,
    256'h75b227ebe28012079a059618c323c7041531d871f1e5a534ccf73f362693fdb7,
    256'hc072a49cafa2d4adf04759fa7dc982ca76abd7fe2b670130c56f6bf27b777c63};
`ifdef FORMAL
  // The formal run (scripts/formal/run_formal.sh) proves control and
  // secret-handling properties, none of which depends on the cipher's
  // values: it uses the identity S-box and 2 / 3 AES rounds so the solver
  // reaches whole messages. Simulation and synthesis use the real ones.
  function automatic logic [7:0] sbox(input logic [7:0] x);
    sbox = x ^ SB[7:0];
  endfunction
  localparam logic [3:0] NR128 = 4'd2, NR256 = 4'd3;
`else
  function automatic logic [7:0] sbox(input logic [7:0] x);
    sbox = SB[8 * x +: 8];
  endfunction
  localparam logic [3:0] NR128 = 4'd10, NR256 = 4'd14;
`endif
  function automatic logic [7:0] xt(input logic [7:0] x);
    xt = {x[6:0], 1'b0} ^ (x[7] ? 8'h1b : 8'h00);
  endfunction
  function automatic logic [31:0] subw(input logic [31:0] w);
    subw = {sbox(w[31:24]), sbox(w[23:16]), sbox(w[15:8]), sbox(w[7:0])};
  endfunction
  // SubBytes and ShiftRows (byte 4c + r of a block is row r, column c)
  function automatic logic [127:0] subshift(input logic [127:0] s);
    for (int c = 0; c < 4; c++)
      for (int r = 0; r < 4; r++)
        subshift[127 - 8 * (4 * c + r) -: 8] = sbox(s[127 - 8 * (4 * ((c + r) % 4) + r) -: 8]);
  endfunction
  function automatic logic [127:0] mixcol(input logic [127:0] s);
    logic [7:0] a0, a1, a2, a3;
    for (int c = 0; c < 4; c++) begin
      a0 = s[127 - 32 * c -: 8]; a1 = s[119 - 32 * c -: 8]; a2 = s[111 - 32 * c -: 8]; a3 = s[103 - 32 * c -: 8];
      mixcol[127 - 32 * c -: 8] = xt(a0) ^ xt(a1) ^ a1 ^ a2 ^ a3;
      mixcol[119 - 32 * c -: 8] = a0 ^ xt(a1) ^ xt(a2) ^ a2 ^ a3;
      mixcol[111 - 32 * c -: 8] = a0 ^ a1 ^ xt(a2) ^ xt(a3) ^ a3;
      mixcol[103 - 32 * c -: 8] = xt(a0) ^ a0 ^ a1 ^ a2 ^ xt(a3);
    end
  endfunction
  // ---------------- GF(2^128) (GCM bit order: bit 127 is x^0) ----------------
  function automatic logic [127:0] mulx(input logic [127:0] v);
    mulx = {1'b0, v[127:1]} ^ (v[0] ? {8'he1, 120'h0} : 128'h0);
  endfunction

  // the first n bytes of a block
  function automatic logic [127:0] bytemask(input logic [4:0] n);
    for (int i = 0; i < 16; i++) bytemask[127 - 8 * i -: 8] = 5'(i) < n ? 8'hff : 8'h00;
  endfunction
  // one GHASH digit: z x^32 + (sum d[i] x^(31-i)) h, the 32 partial products
  // added in a balanced tree
  function automatic logic [127:0] gstep(input logic [127:0] z, input logic [31:0] d, input logic [127:0] h);
    logic [127:0] hx, zx;
    logic [32*128-1:0] tt;
    hx = h;
    zx = z;
    for (int j = 0; j < 32; j++) begin
      tt[128 * (31 - j) +: 128] = d[31 - j] ? hx : 128'h0;     // d[i] takes h x^(31-i)
      hx = mulx(hx);
    end
    for (int k = 16; k >= 1; k = k / 2)
      for (int i = 0; i < k; i++) tt[128 * i +: 128] = tt[256 * i +: 128] ^ tt[256 * i + 128 +: 128];
    for (int j = 0; j < 32; j++) zx = mulx(zx);
    gstep = zx ^ tt[127:0];
  endfunction

  // ---------------- control ----------------
  typedef enum logic [1:0] {M_IDLE, M_RUN, M_LEN, M_FIN} m_t;
  m_t m;
  localparam logic [1:0] J_H = 2'd0, J_J0 = 2'd1, J_KS = 2'd2;
  logic           k256, dec;
  logic [3:0]     tlen;
  logic [255:0]   kreg;                 // the message key (AES-128: low half zero)
  logic [95:0]    ivr;
  // AES
  logic           a_act, a_vld;         // running; key stream block ready in st
  logic [3:0]     a_rnd;
  logic [1:0]     a_job;
  logic [127:0]   st;
  logic [255:0]   kw;                   // {previous, current} round key
  logic [7:0]     rcon;
  logic [CW-1:0]  kctr;                 // counter of the next key stream block
  logic           h_ok, j_ok;
  logic [127:0]   hk, ej0;
  // GHASH
  logic [1:0]     g_cnt;
  logic [95:0]    ga;                   // operand digits still to multiply
  logic [127:0]   gz;
  // message
  logic [LEN_W-1:0] alen, clen;
  logic           txt, apart;           // a text block was taken; the last AAD block was partial
  logic           take_txt;             // a text block is taken

  wire a_fin = a_rnd == (k256 ? NR256 : NR128);    // the last round
  assign busy = m != M_IDLE;

  // ---------------- key expansion step ----------------
  // next round key from p (the round key Nk words back) and q (the current
  // one): w0 = p0 ^ f(q3), wi = p_i ^ w_{i-1}; f = SubWord(RotWord()) ^ Rcon
  // or, for the odd AES-256 steps, SubWord() alone
  wire          a_load = m == M_RUN && !a_act && (!a_vld || take_txt) && !clr;
  wire          ex_rot = a_load || !k256 || a_rnd[0];
  wire [127:0]  ex_p = a_load ? kreg[255:128] : (k256 ? kw[255:128] : kw[127:0]);
  wire [31:0]   ex_q = a_load ? kreg[159:128] : kw[31:0];        // its last word
  wire [31:0]   ex_s = subw(ex_rot ? {ex_q[23:0], ex_q[31:24]} : ex_q);
  wire [7:0]    ex_rc = a_load ? 8'h01 : rcon;
  wire [31:0]   ex_w0 = ex_p[127:96] ^ ex_s ^ (ex_rot ? {ex_rc, 24'h0} : 32'h0);
  wire [31:0]   ex_w1 = ex_p[95:64] ^ ex_w0;
  wire [31:0]   ex_w2 = ex_p[63:32] ^ ex_w1;
  wire [127:0]  ex_n = {ex_w0, ex_w1, ex_w2, ex_p[31:0] ^ ex_w2};
  wire [127:0] a_ss  = subshift(st);
  wire [127:0] a_out = (a_fin ? a_ss : mixcol(a_ss)) ^ kw[127:0];

  // ---------------- block intake ----------------
  wire [127:0]  bmask = bytemask(in_bytes);    // the first in_bytes bytes
  wire          g_busy  = g_cnt != 2'd0;
  assign in_ready = m == M_RUN && a_vld && !g_busy && !out_valid;
  wire          take    = in_valid && in_ready && !clr;
  wire          nonempty = in_bytes != 5'd0;
  wire [LEN_W:0] alen_n = {1'b0, alen} + (LEN_W + 1)'(in_bytes);
  wire [LEN_W-1:0] clen_n = clen + LEN_W'(in_bytes);   // no carry: clen <= TXT_MAX, in_bytes < 32
  wire          a_ovf = alen_n[LEN_W];
  wire [1:0]    in_err = in_bytes > 5'd16 || !nonempty && !in_last ? E_FMT
                       : nonempty && in_aad && (txt || apart) ? E_ORDER
                       : nonempty && !in_aad && in_bytes != 5'd16 && !in_last ? E_ORDER
                       : nonempty && in_aad && a_ovf ? E_LEN
                       : nonempty && !in_aad && clen_n > TXT_MAX ? E_LEN : 2'd0;
  wire          take_ok  = take && in_err == 2'd0;
  assign        take_txt = take_ok && nonempty && !in_aad;
  wire [127:0]  ks_txt  = (in_data ^ st) & bmask;
  wire [127:0]  in_m    = in_data & bmask;
  // GHASH input block: AAD, ciphertext, or the length block
  wire [127:0]  g_x = m == M_LEN ? {(64)'({alen, 3'b000}), (64)'({clen, 3'b000})}
                                 : (in_aad || dec ? in_m : ks_txt);
  wire          g_start = (take_ok && nonempty) || (m == M_LEN && !g_busy && !clr);

  // ---------------- GHASH step ----------------
  // Horner over 32-bit digits, highest degree first: Z = Z x^32 + D H with
  // D = sum d[i] x^(31-i); the 32 products are added in a balanced tree
  wire [127:0]  g_a = gz ^ g_x;         // first operand digit at start
  wire [31:0]   g_d = g_start ? g_a[31:0] : ga[31:0];
  wire [127:0]  g_n = gstep(g_start ? 128'h0 : gz, g_d, hk);

  // ---------------- tag ----------------
  wire [127:0] t_full = gz ^ ej0;
  wire [127:0] tmask = bytemask(tlen == 4'd0 ? 5'd16 : {1'b0, tlen});
  wire fin = m == M_FIN && !g_busy && !out_valid && !clr;
  wire st_bad = start && !busy && key_sel && !sl_valid;

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      m <= M_IDLE; k256 <= 1'b0; dec <= 1'b0; tlen <= '0; kreg <= '0; ivr <= '0;
      a_act <= 1'b0; a_vld <= 1'b0; a_rnd <= '0; a_job <= J_H; st <= '0; kw <= '0; rcon <= '0;
      kctr <= '0; h_ok <= 1'b0; j_ok <= 1'b0; hk <= '0; ej0 <= '0;
      g_cnt <= '0; ga <= '0; gz <= '0; alen <= '0; clen <= '0; txt <= 1'b0; apart <= 1'b0;
      out_valid <= 1'b0; out_data <= '0; out_bytes <= '0; out_last <= 1'b0;
      done <= 1'b0; tag <= '0; tag_ok <= 1'b0; err <= 1'b0; err_code <= '0;
    end else begin
      done <= 1'b0;
      err <= 1'b0;
      if (out_valid && out_ready) out_valid <= 1'b0;
      // AES
      if (a_load) begin
        st <= (!h_ok ? 128'h0 : {ivr, !j_ok ? 32'd1 : 32'(kctr)}) ^ kreg[255:128];   // 0, J0, counter block
        kw <= k256 ? kreg : {kreg[255:128], ex_n};
        rcon <= k256 ? 8'h01 : 8'h02;
        a_rnd <= 4'd1;
        a_act <= 1'b1;
        a_vld <= 1'b0;
        a_job <= !h_ok ? J_H : !j_ok ? J_J0 : J_KS;
        if (h_ok && j_ok) kctr <= kctr + 1'b1;
      end else if (a_act) begin
        st <= a_out;
        kw <= {kw[127:0], ex_n};
        if (ex_rot) rcon <= xt(rcon);
        a_rnd <= a_rnd + 1'b1;
        if (a_fin) begin
          a_act <= 1'b0;
          case (a_job)
            J_H: begin hk <= a_out; h_ok <= 1'b1; end
            J_J0: begin ej0 <= a_out; j_ok <= 1'b1; end
            default: a_vld <= 1'b1;
          endcase
        end
      end
      // GHASH
      if (g_start) begin
        ga <= g_a[127:32];
        gz <= g_n;
        g_cnt <= 2'd1;
      end else if (g_busy) begin
        ga <= {32'h0, ga[95:32]};
        gz <= g_n;
        g_cnt <= g_cnt + 1'b1;
      end
      // blocks
      if (take_ok) begin
        if (nonempty && in_aad) begin
          alen <= alen_n[LEN_W-1:0];
          apart <= in_bytes != 5'd16;
        end
        if (take_txt) begin
          clen <= clen_n;
          txt <= 1'b1;
          out_valid <= 1'b1;
          out_data <= ks_txt;
          out_bytes <= in_bytes;
          out_last <= in_last;
        end
        if (in_last) m <= M_LEN;
      end
      if (m == M_LEN && !g_busy) m <= M_FIN;
      if (fin) begin
        done <= 1'b1;
        tag <= dec ? 128'h0 : t_full;
        tag_ok <= dec && ((t_full ^ tag_in) & tmask) == 128'h0;
      end
      if (start && !busy && !clr && !st_bad) begin
        m <= M_RUN;
        k256 <= key256; dec <= decrypt; tlen <= tag_len; ivr <= iv;
        kreg <= {key_sel ? sl_key[255:128] : key[255:128],
                 key256 ? (key_sel ? sl_key[127:0] : key[127:0]) : 128'h0};
        kctr <= CW'(2);
        tag <= '0; tag_ok <= 1'b0; err_code <= '0;
      end
      if (st_bad && !clr) begin err <= 1'b1; err_code <= 3'd4; end
      // end of a message: clear the secrets
      if (clr || fin || take && in_err != 2'd0) begin
        m <= M_IDLE; kreg <= '0; ivr <= '0; k256 <= 1'b0; dec <= 1'b0; tlen <= '0;
        a_act <= 1'b0; a_vld <= 1'b0; a_rnd <= '0; a_job <= J_H; st <= '0; kw <= '0; rcon <= '0;
        kctr <= '0; h_ok <= 1'b0; j_ok <= 1'b0; hk <= '0; ej0 <= '0;
        g_cnt <= '0; ga <= '0; gz <= '0; alen <= '0; clen <= '0; txt <= 1'b0; apart <= 1'b0;
      end
      if (take && in_err != 2'd0) begin err <= 1'b1; err_code <= {1'b0, in_err}; end
      if (clr || take && in_err != 2'd0) begin
        out_valid <= 1'b0; out_data <= '0; out_bytes <= '0; out_last <= 1'b0;
      end
    end
  end

`ifdef FORMAL
  `include "AES_GCM_props.svh"
`endif
endmodule
