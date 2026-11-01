// SPDX-License-Identifier: Apache-2.0
// ============================================================================
// SHA3_top v1.0: SHA-3 / SHAKE hash engine (FIPS 202): SHA3-224, SHA3-256,
// SHA3-384, SHA3-512, SHAKE128 and SHAKE256 on one Keccak-f[1600] core
// ----------------------------------------------------------------------------
//  - start with mode (0 SHA3-224, 1 SHA3-256, 2 SHA3-384, 3 SHA3-512,
//    4 SHAKE128, 5 SHAKE256) clears the state and opens a message; it is
//    taken in any state, so it also abandons a message or an output stream.
//    A reserved mode (6, 7) pulses err, clears the state and leaves the core
//    idle (the way to wipe a SHAKE state without starting a new message).
//  - Message in: in_valid / in_ready, one 64-bit word (one Keccak lane) per
//    handshake, little-endian (byte 0 of the message is in_data[7:0]).
//    in_bytes (0..8) gives the valid bytes of the word, from byte 0 up; only
//    the in_last word may be short (in_bytes 0 is an empty last word, as
//    for an empty message). A short word without in_last, or in_bytes > 8,
//    is dropped with an err pulse. Bytes above in_bytes are ignored.
//  - Absorbing takes one clock per word; a full rate block (r / 8 words:
//    18, 17, 13, 9, 21, 17 for the six modes) is then permuted in 24
//    clocks (one round per clock) with in_ready low. After in_last the
//    padding (domain bits 01 for SHA3, 1111 for SHAKE, then pad10*1) is
//    applied and the last block permuted.
//  - Digest out: out_valid / out_ready, one 64-bit word per handshake,
//    little-endian. SHA3-d gives ceil(d / 64) words with out_last on the
//    last (for SHA3-224 its upper 32 bits are zero) and then pulses done;
//    SHAKE gives an endless stream (a permutation after every r / 8 words,
//    out_valid low meanwhile) until the next start.
//  - The state is cleared when a digest has been read, on every start and
//    on reset; busy is high from start to done.
//  Not implemented: cSHAKE / KMAC / TupleHash (SP 800-185) framing, which
//  the host can build on SHAKE by prefixing the encoded strings; more than
//  one round per clock; masking against power analysis.
// ============================================================================
module SHA3_top (
  input  logic        clk,
  input  logic        rst_n,
  input  logic        start,
  input  logic [2:0]  mode,
  // message in
  input  logic        in_valid,
  input  logic [63:0] in_data,
  input  logic [3:0]  in_bytes,
  input  logic        in_last,
  output logic        in_ready,
  // digest out
  output logic        out_valid,
  output logic [63:0] out_data,
  output logic        out_last,
  input  logic        out_ready,
  output logic        busy,
  output logic        done,
  output logic        err
);
  // ---------------- Keccak-f[1600] round ----------------
  // lane (x, y) is s[64 (x + 5 y) +: 64]
  function automatic logic [63:0] rotl(input logic [63:0] v, input int n);
    rotl = (n == 0) ? v : ((v << n) | (v >> (64 - n)));
  endfunction
  // rho offsets, indexed x + 5 y
  function automatic int rho(input int i);
    case (i)
      0: rho = 0;   1: rho = 1;   2: rho = 62;  3: rho = 28;  4: rho = 27;
      5: rho = 36;  6: rho = 44;  7: rho = 6;   8: rho = 55;  9: rho = 20;
      10: rho = 3;  11: rho = 10; 12: rho = 43; 13: rho = 25; 14: rho = 39;
      15: rho = 41; 16: rho = 45; 17: rho = 15; 18: rho = 21; 19: rho = 8;
      20: rho = 18; 21: rho = 2;  22: rho = 61; 23: rho = 56; default: rho = 14;
    endcase
  endfunction
  function automatic logic [1599:0] kround(input logic [1599:0] s, input logic [63:0] rc);
    logic [319:0]  c, d;
    logic [1599:0] b, r;
    for (int x = 0; x < 5; x++)
      c[64 * x +: 64] = s[64 * x +: 64] ^ s[64 * (x + 5) +: 64] ^ s[64 * (x + 10) +: 64] ^ s[64 * (x + 15) +: 64] ^ s[64 * (x + 20) +: 64];
    for (int x = 0; x < 5; x++)
      d[64 * x +: 64] = c[64 * ((x + 4) % 5) +: 64] ^ rotl(c[64 * ((x + 1) % 5) +: 64], 1);
    // theta, rho and pi: B[y, 2x + 3y] = rot(A[x, y] ^ D[x], rho[x, y])
    for (int x = 0; x < 5; x++)
      for (int y = 0; y < 5; y++)
        b[64 * (y + 5 * ((2 * x + 3 * y) % 5)) +: 64] = rotl(s[64 * (x + 5 * y) +: 64] ^ d[64 * x +: 64], rho(x + 5 * y));
    // chi
    for (int x = 0; x < 5; x++)
      for (int y = 0; y < 5; y++)
        r[64 * (x + 5 * y) +: 64] = b[64 * (x + 5 * y) +: 64] ^ (~b[64 * ((x + 1) % 5 + 5 * y) +: 64] & b[64 * ((x + 2) % 5 + 5 * y) +: 64]);
    // iota
    r[63:0] = r[63:0] ^ rc;
    kround = r;
  endfunction
  // round constants, round r at [64 r +: 64]
  localparam logic [64*24-1:0] KRC = {
    64'h8000000080008008, 64'h0000000080000001, 64'h8000000000008080, 64'h8000000080008081,
    64'h800000008000000A, 64'h000000000000800A, 64'h8000000000000080, 64'h8000000000008002,
    64'h8000000000008003, 64'h8000000000008089, 64'h800000000000008B, 64'h000000008000808B,
    64'h000000008000000A, 64'h0000000080008009, 64'h0000000000000088, 64'h000000000000008A,
    64'h8000000000008009, 64'h8000000080008081, 64'h0000000080000001, 64'h000000000000808B,
    64'h8000000080008000, 64'h800000000000808A, 64'h0000000000008082, 64'h0000000000000001};

  // ---------------- mode tables ----------------
  localparam logic [2:0] M_224 = 3'd0, M_256 = 3'd1, M_384 = 3'd2, M_512 = 3'd3, M_X128 = 3'd4, M_X256 = 3'd5;
  function automatic logic [4:0] rate_lanes(input logic [2:0] m);
    case (m)
      M_224:   rate_lanes = 5'd18;
      M_256:   rate_lanes = 5'd17;
      M_384:   rate_lanes = 5'd13;
      M_512:   rate_lanes = 5'd9;
      M_X128:  rate_lanes = 5'd21;
      default: rate_lanes = 5'd17;      // SHAKE256
    endcase
  endfunction
  function automatic logic [3:0] digest_words(input logic [2:0] m);
    case (m)
      M_384:   digest_words = 4'd6;
      M_512:   digest_words = 4'd8;
      default: digest_words = 4'd4;     // SHA3-224 (3.5 words), SHA3-256
    endcase
  endfunction

  typedef enum logic [2:0] {S_IDLE, S_ABS, S_PAD, S_PERM, S_SQZ} st_t;
  typedef enum logic [1:0] {R_ABS, R_PAD, R_SQZ} rt_t;   // where a permutation returns to
  st_t           st;
  rt_t           ret;
  logic [1599:0] ks;
  logic [2:0]    md;
  logic [4:0]    li;                    // lane index: absorb position, then squeeze position
  logic [4:0]    rnd;
  logic          xof;
  logic [4:0]    rl, rlm1;           // rate in lanes, and its last lane
  logic [7:0]    dsb;                   // domain bits with the first padding bit
  assign xof = md[2];
  assign rl  = rate_lanes(md);
  assign rlm1 = rl - 5'd1;
  assign dsb = xof ? 8'h1F : 8'h06;

  assign in_ready  = (st == S_ABS);
  assign out_valid = (st == S_SQZ);
  assign out_last  = (st == S_SQZ) && !xof && (li == 5'(digest_words(md) - 4'd1));
  assign out_data  = (out_last && md == M_224) ? {32'h0, ks[{li, 6'd0} +: 32]} : ks[{li, 6'd0} +: 64];
  assign busy      = (st != S_IDLE);

  // next permutation state; for the formal run the round function is cut
  // (a free value each clock): the control properties do not depend on it,
  // and the function itself is checked bit-exact in simulation
  logic [1599:0] knext;
`ifdef FORMAL
  (* anyseq *) logic [1599:0] f_kfree;
  assign knext = f_kfree;
`else
  assign knext = kround(ks, KRC[64 * rnd +: 64]);
`endif

  logic [55:0] bmask;                   // valid bytes of a short last word (0..7 bytes)
  assign bmask = 56'((64'h1 << {in_bytes[2:0], 3'b000}) - 64'h1);
  logic in_bad;
  assign in_bad = (in_bytes > 4'd8) || (!in_last && in_bytes != 4'd8);

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      st <= S_IDLE; ret <= R_ABS; ks <= '0; md <= M_224; li <= '0; rnd <= '0; done <= 1'b0; err <= 1'b0;
    end else begin
      done <= 1'b0;
      err  <= 1'b0;
      if (start) begin
        ks <= '0;
        li <= '0;
        rnd <= '0;
        if (mode <= M_X256) begin md <= mode; st <= S_ABS; end
        else begin err <= 1'b1; st <= S_IDLE; end
      end else begin
        case (st)
          S_ABS: if (in_valid) begin
            if (in_bad) err <= 1'b1;
            else if (!in_last) begin
              ks[{li, 6'd0} +: 64] <= ks[{li, 6'd0} +: 64] ^ in_data;
              if (li == rlm1) begin li <= '0; ret <= R_ABS; st <= S_PERM; end
              else li <= li + 5'd1;
            end else if (in_bytes != 4'd8) begin
              // short last word: data, the domain byte after it, and the final padding bit
              ks[{li, 6'd0} +: 64] <= ks[{li, 6'd0} +: 64] ^ (in_data & {8'h00, bmask}) ^ (64'(dsb) << {in_bytes[2:0], 3'b000})
                                   ^ ((li == rlm1) ? 64'h8000_0000_0000_0000 : 64'h0);
              if (li != rlm1) ks[{rlm1, 6'd0} +: 64] <= ks[{rlm1, 6'd0} +: 64] ^ 64'h8000_0000_0000_0000;
              li <= '0; ret <= R_SQZ; st <= S_PERM;
            end else begin
              // full last word: the padding goes in the next lane (a new block if this one is full)
              ks[{li, 6'd0} +: 64] <= ks[{li, 6'd0} +: 64] ^ in_data;
              if (li == rlm1) begin li <= '0; ret <= R_PAD; st <= S_PERM; end
              else begin li <= li + 5'd1; st <= S_PAD; end
            end
          end
          S_PAD: begin
            ks[{li, 6'd0} +: 64] <= ks[{li, 6'd0} +: 64] ^ 64'(dsb) ^ ((li == rlm1) ? 64'h8000_0000_0000_0000 : 64'h0);
            if (li != rlm1) ks[{rlm1, 6'd0} +: 64] <= ks[{rlm1, 6'd0} +: 64] ^ 64'h8000_0000_0000_0000;
            li <= '0; ret <= R_SQZ; st <= S_PERM;
          end
          S_PERM: begin
            ks <= knext;
            if (rnd == 5'd23) begin rnd <= '0; st <= (ret == R_ABS) ? S_ABS : (ret == R_PAD) ? S_PAD : S_SQZ; end
            else rnd <= rnd + 5'd1;
          end
          S_SQZ: if (out_ready) begin
            if (out_last) begin ks <= '0; li <= '0; done <= 1'b1; st <= S_IDLE; end
            else if (li == rlm1) begin li <= '0; ret <= R_SQZ; st <= S_PERM; end
            else li <= li + 5'd1;
          end
          default: ;                    // S_IDLE: wait for start
        endcase
      end
    end
  end

`ifdef FORMAL
  `include "SHA3_props.svh"
`endif
endmodule
