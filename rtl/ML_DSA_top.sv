// SPDX-License-Identifier: Apache-2.0
// ============================================================================
// ML_DSA_top v1.0: ML-DSA (FIPS 204) signature engine for the three
// parameter sets ML-DSA-44, -65 and -87: KeyGen, Sign and Verify, the
// internal algorithms of FIPS 204 section 6 (ML-DSA.KeyGen_internal,
// Sign_internal, Verify_internal; the seed xi and the signing randomness
// rnd come from the host, and the host formats M').
// ----------------------------------------------------------------------------
//  - Host side: a byte buffer of 32 KiB, read and written as 32-bit words
//    (little-endian) through an auto-incrementing pointer (hp_load /
//    hp_addr, then hw_* writes and hr_* reads) while the engine is idle.
//    Buffer map (byte offsets; each field sized for ML-DSA-87, the smaller
//    sets use the start of it):
//      0x0000 PK   public key (32 + 320 k)          KeyGen out, Verify in
//      0x0A20 SK   private key                      KeyGen out, Sign in
//      0x1D40 SIG  signature                        Sign out, Verify in
//      0x2F60 XI   seed xi (32)                     KeyGen in
//      0x2FA0 RND  signing randomness (32; zero for the deterministic variant)
//      0x2FC0 MU   message representative mu (64)  in with ext_mu, else scratch
//      0x3000..0x3FFF scratch
//      0x4000 MSG  M' (mlen bytes, at most 16384)   Sign and Verify in
//  - start with op (0 KeyGen, 1 Sign, 2 Verify) and pset (0 ML-DSA-44,
//    1 ML-DSA-65, 2 ML-DSA-87) runs the operation: busy until the done
//    pulse; fail (Verify: the signature is rejected) and tries (Sign: the
//    number of attempts of the rejection loop) hold from done to the next
//    start. ext_mu: Sign and Verify take mu from the buffer and skip
//    mu = H(tr || M'). A reserved op or pset, or mlen > 16384 without ext_mu,
//    pulses err instead.
//  - Datapath: Keccak-f[1600] at one round per clock for SHAKE128 and
//    SHAKE256 (one byte absorbed per clock; up to three bytes squeezed per
//    clock into the samplers); one NTT butterfly, pointwise product, sample,
//    or packed coefficient per clock on 43 polynomials of 256 coefficients,
//    through a 6-stage pipeline; reduction mod q = 2^23 - 2^13 + 1 by three
//    folds of 2^23 = 2^13 - 1; the matrix A is sampled on the fly into a
//    multiply-accumulate and never stored.
//  Not implemented: the random-number source (xi and rnd are inputs), the
//  message formatting of ML-DSA.Sign / Verify and HashML-DSA (M' is an
//  input), masking against power analysis, fault countermeasures.
// ============================================================================
module ML_DSA_top (
  input  logic        clk,
  input  logic        rst_n,
  input  logic        start,
  input  logic [1:0]  op,
  input  logic [1:0]  pset,
  input  logic        ext_mu,
  input  logic [14:0] mlen,
  output logic        busy,
  output logic        done,
  output logic        err,
  output logic        fail,
  output logic [15:0] tries,
  // host access to the buffer
  input  logic        hp_load,
  input  logic [12:0] hp_addr,
  input  logic        hw_valid,
  input  logic [31:0] hw_data,
  output logic        hw_ready,
  input  logic        hr_en,
  output logic        hr_valid,
  output logic [31:0] hr_data,
  input  logic        hr_ready
);
  localparam logic [22:0] Q = 23'd8380417;
  // buffer map (byte addresses)
  localparam logic [14:0] A_PK = 15'h0000, A_SK = 15'h0A20, A_SIG = 15'h1D40, A_XI = 15'h2F60, A_KC = 15'h2F80,
                          A_MU = 15'h2FC0, A_TR = 15'h3000, A_HO = 15'h3040, A_CT2 = 15'h30C0,
                          A_RPP = 15'h3100, A_W1 = 15'h3140, A_MSG = 15'h4000;
  localparam logic [14:0] MSG_MAX = 15'd16384;
  // polynomial slots: s1^[0..6] 0-6, s2^[0..7] 8-15, t0^[0..7] 16-23, y^ / z^[0..6] 24-30,
  // w[0..7] 32-39, c^ 40, TMP 41, ACC 42
  localparam logic [5:0] P_C = 6'd40, P_TMP = 6'd41, P_ACC = 6'd42;
  localparam int NPOLY = 43;
  localparam logic [1:0] OP_KG = 2'd0, OP_SG = 2'd1, OP_VF = 2'd2;
  // polynomial unit operations
  typedef enum logic [4:0] {U_NONE, U_NTT, U_INTT, U_PMUL, U_ADD, U_SUB, U_SA, U_SS, U_SY, U_SIB, U_CLD,
                            U_DEC, U_ENC, U_HINT, U_HDEC, U_HZ, U_FILL, U_COPY, U_CMP} uop_t;
  // coefficient transforms of Encode / Decode
  typedef enum logic [2:0] {F_OFF, F_SHL, F_P2H, F_P2L, F_HB, F_UH} fn_t;
  // what follows a step
  typedef enum logic [2:0] {L_NEXT, L_IK, L_IL, L_JL, L_REJ, L_END} lp_t;

  // ---------------- arithmetic mod q ----------------
  function automatic logic [22:0] addq(input logic [22:0] a, input logic [22:0] b);
    logic [23:0] s;
    s = 24'(a) + 24'(b);
    addq = s >= 24'(Q) ? 23'(s - 24'(Q)) : s[22:0];
  endfunction
  function automatic logic [22:0] subq(input logic [22:0] a, input logic [22:0] b);
    subq = a >= b ? a - b : 23'(24'(a) + 24'(Q) - 24'(b));
  endfunction
  // x mod q by folding 2^23 = 2^13 - 1 three times (one pipeline stage each):
  // x < 2^47 -> < 2^37 + 2^23 -> < 2^28 + 2^23 -> < 2 q, then one subtraction
  function automatic logic [37:0] fold1(input logic [46:0] x);
    fold1 = (38'(x[46:23]) << 13) - 38'(x[46:23]) + 38'(x[22:0]);
  endfunction
  function automatic logic [28:0] fold2(input logic [37:0] y);
    fold2 = (29'(y[37:23]) << 13) - 29'(y[37:23]) + 29'(y[22:0]);
  endfunction
  function automatic logic [22:0] fold3(input logic [28:0] z);
    logic [23:0] u;
    u = (24'(z[28:23]) << 13) - 24'(z[28:23]) + 24'(z[22:0]);
    fold3 = u >= 24'(Q) ? 23'(u - 24'(Q)) : u[22:0];
  endfunction
  // |x| of x mod q taken in (-(q-1)/2, (q-1)/2]
  function automatic logic [22:0] absq(input logic [22:0] x);
    absq = x > 23'd4190208 ? Q - x : x;
  endfunction
  // Decompose: the quotient r1 = floor((x + gamma2 - 1) / (2 gamma2)) before the
  // wrap fix-up; 2 gamma2 = 93 * 2^11 (ML-DSA-44) or 1023 * 2^9
  function automatic logic [5:0] dquo(input logic [22:0] x, input logic g32);
    logic [23:0] n;
    n = 24'(x) + (g32 ? 24'd261887 : 24'd95231);
    dquo = g32 ? 6'((40'(n[23:9]) * 40'd32801) >> 25) : 6'((40'(n[23:11]) * 40'd2819) >> 18);
  endfunction
  // and r0 = x - r1 2 gamma2, with r1 = m (r+ - r0 = q - 1) folded to r1 = 0, r0 - 1
  function automatic logic [24:0] drem(input logic [22:0] x, input logic [5:0] r1, input logic g32);
    logic [24:0] r0;
    r0 = 25'(x) - 25'(r1) * (g32 ? 25'd523776 : 25'd190464);
    drem = r1 == (g32 ? 6'd16 : 6'd44) ? r0 - 25'd1 : r0;
  endfunction
  function automatic logic [5:0] dhi(input logic [5:0] r1, input logic g32);
    dhi = r1 == (g32 ? 6'd16 : 6'd44) ? 6'd0 : r1;
  endfunction
  function automatic logic [1599:0] keccak_round(input logic [1599:0] s, input logic [63:0] rc);
    logic [63:0] c0, c1, c2, c3, c4, d0, d1, d2, d3, d4;
    logic [1599:0] a, b;
    c0 = s[0 +: 64] ^ s[320 +: 64] ^ s[640 +: 64] ^ s[960 +: 64] ^ s[1280 +: 64];
    c1 = s[64 +: 64] ^ s[384 +: 64] ^ s[704 +: 64] ^ s[1024 +: 64] ^ s[1344 +: 64];
    c2 = s[128 +: 64] ^ s[448 +: 64] ^ s[768 +: 64] ^ s[1088 +: 64] ^ s[1408 +: 64];
    c3 = s[192 +: 64] ^ s[512 +: 64] ^ s[832 +: 64] ^ s[1152 +: 64] ^ s[1472 +: 64];
    c4 = s[256 +: 64] ^ s[576 +: 64] ^ s[896 +: 64] ^ s[1216 +: 64] ^ s[1536 +: 64];
    d0 = c4 ^ {c1[62:0], c1[63]};
    d1 = c0 ^ {c2[62:0], c2[63]};
    d2 = c1 ^ {c3[62:0], c3[63]};
    d3 = c2 ^ {c4[62:0], c4[63]};
    d4 = c3 ^ {c0[62:0], c0[63]};
    a[0 +: 64] = s[0 +: 64] ^ d0;
    a[64 +: 64] = s[64 +: 64] ^ d1;
    a[128 +: 64] = s[128 +: 64] ^ d2;
    a[192 +: 64] = s[192 +: 64] ^ d3;
    a[256 +: 64] = s[256 +: 64] ^ d4;
    a[320 +: 64] = s[320 +: 64] ^ d0;
    a[384 +: 64] = s[384 +: 64] ^ d1;
    a[448 +: 64] = s[448 +: 64] ^ d2;
    a[512 +: 64] = s[512 +: 64] ^ d3;
    a[576 +: 64] = s[576 +: 64] ^ d4;
    a[640 +: 64] = s[640 +: 64] ^ d0;
    a[704 +: 64] = s[704 +: 64] ^ d1;
    a[768 +: 64] = s[768 +: 64] ^ d2;
    a[832 +: 64] = s[832 +: 64] ^ d3;
    a[896 +: 64] = s[896 +: 64] ^ d4;
    a[960 +: 64] = s[960 +: 64] ^ d0;
    a[1024 +: 64] = s[1024 +: 64] ^ d1;
    a[1088 +: 64] = s[1088 +: 64] ^ d2;
    a[1152 +: 64] = s[1152 +: 64] ^ d3;
    a[1216 +: 64] = s[1216 +: 64] ^ d4;
    a[1280 +: 64] = s[1280 +: 64] ^ d0;
    a[1344 +: 64] = s[1344 +: 64] ^ d1;
    a[1408 +: 64] = s[1408 +: 64] ^ d2;
    a[1472 +: 64] = s[1472 +: 64] ^ d3;
    a[1536 +: 64] = s[1536 +: 64] ^ d4;
    b[0 +: 64] = a[0 +: 64];
    b[1024 +: 64] = {a[347:320], a[383:348]};
    b[448 +: 64] = {a[700:640], a[703:701]};
    b[1472 +: 64] = {a[982:960], a[1023:983]};
    b[896 +: 64] = {a[1325:1280], a[1343:1326]};
    b[640 +: 64] = {a[126:64], a[127:127]};
    b[64 +: 64] = {a[403:384], a[447:404]};
    b[1088 +: 64] = {a[757:704], a[767:758]};
    b[512 +: 64] = {a[1042:1024], a[1087:1043]};
    b[1536 +: 64] = {a[1405:1344], a[1407:1406]};
    b[1280 +: 64] = {a[129:128], a[191:130]};
    b[704 +: 64] = {a[505:448], a[511:506]};
    b[128 +: 64] = {a[788:768], a[831:789]};
    b[1152 +: 64] = {a[1136:1088], a[1151:1137]};
    b[576 +: 64] = {a[1410:1408], a[1471:1411]};
    b[320 +: 64] = {a[227:192], a[255:228]};
    b[1344 +: 64] = {a[520:512], a[575:521]};
    b[768 +: 64] = {a[870:832], a[895:871]};
    b[192 +: 64] = {a[1194:1152], a[1215:1195]};
    b[1216 +: 64] = {a[1479:1472], a[1535:1480]};
    b[960 +: 64] = {a[292:256], a[319:293]};
    b[384 +: 64] = {a[619:576], a[639:620]};
    b[1408 +: 64] = {a[920:896], a[959:921]};
    b[832 +: 64] = {a[1271:1216], a[1279:1272]};
    b[256 +: 64] = {a[1585:1536], a[1599:1586]};
    keccak_round[0 +: 64] = b[0 +: 64] ^ (~b[64 +: 64] & b[128 +: 64]);
    keccak_round[320 +: 64] = b[320 +: 64] ^ (~b[384 +: 64] & b[448 +: 64]);
    keccak_round[640 +: 64] = b[640 +: 64] ^ (~b[704 +: 64] & b[768 +: 64]);
    keccak_round[960 +: 64] = b[960 +: 64] ^ (~b[1024 +: 64] & b[1088 +: 64]);
    keccak_round[1280 +: 64] = b[1280 +: 64] ^ (~b[1344 +: 64] & b[1408 +: 64]);
    keccak_round[64 +: 64] = b[64 +: 64] ^ (~b[128 +: 64] & b[192 +: 64]);
    keccak_round[384 +: 64] = b[384 +: 64] ^ (~b[448 +: 64] & b[512 +: 64]);
    keccak_round[704 +: 64] = b[704 +: 64] ^ (~b[768 +: 64] & b[832 +: 64]);
    keccak_round[1024 +: 64] = b[1024 +: 64] ^ (~b[1088 +: 64] & b[1152 +: 64]);
    keccak_round[1344 +: 64] = b[1344 +: 64] ^ (~b[1408 +: 64] & b[1472 +: 64]);
    keccak_round[128 +: 64] = b[128 +: 64] ^ (~b[192 +: 64] & b[256 +: 64]);
    keccak_round[448 +: 64] = b[448 +: 64] ^ (~b[512 +: 64] & b[576 +: 64]);
    keccak_round[768 +: 64] = b[768 +: 64] ^ (~b[832 +: 64] & b[896 +: 64]);
    keccak_round[1088 +: 64] = b[1088 +: 64] ^ (~b[1152 +: 64] & b[1216 +: 64]);
    keccak_round[1408 +: 64] = b[1408 +: 64] ^ (~b[1472 +: 64] & b[1536 +: 64]);
    keccak_round[192 +: 64] = b[192 +: 64] ^ (~b[256 +: 64] & b[0 +: 64]);
    keccak_round[512 +: 64] = b[512 +: 64] ^ (~b[576 +: 64] & b[320 +: 64]);
    keccak_round[832 +: 64] = b[832 +: 64] ^ (~b[896 +: 64] & b[640 +: 64]);
    keccak_round[1152 +: 64] = b[1152 +: 64] ^ (~b[1216 +: 64] & b[960 +: 64]);
    keccak_round[1472 +: 64] = b[1472 +: 64] ^ (~b[1536 +: 64] & b[1280 +: 64]);
    keccak_round[256 +: 64] = b[256 +: 64] ^ (~b[0 +: 64] & b[64 +: 64]);
    keccak_round[576 +: 64] = b[576 +: 64] ^ (~b[320 +: 64] & b[384 +: 64]);
    keccak_round[896 +: 64] = b[896 +: 64] ^ (~b[640 +: 64] & b[704 +: 64]);
    keccak_round[1216 +: 64] = b[1216 +: 64] ^ (~b[960 +: 64] & b[1024 +: 64]);
    keccak_round[1536 +: 64] = b[1536 +: 64] ^ (~b[1280 +: 64] & b[1344 +: 64]);
    keccak_round[63:0] = keccak_round[63:0] ^ rc;
  endfunction
  // round constants, round r at [64 r +: 64]
  localparam logic [64*24-1:0] KRC = {
    64'h8000000080008008,
    64'h0000000080000001,
    64'h8000000000008080,
    64'h8000000080008081,
    64'h800000008000000A,
    64'h000000000000800A,
    64'h8000000000000080,
    64'h8000000000008002,
    64'h8000000000008003,
    64'h8000000000008089,
    64'h800000000000008B,
    64'h000000008000808B,
    64'h000000008000000A,
    64'h0000000080008009,
    64'h0000000000000088,
    64'h000000000000008A,
    64'h8000000000008009,
    64'h8000000080008081,
    64'h0000000080000001,
    64'h000000000000808B,
    64'h8000000080008000,
    64'h800000000000808A,
    64'h0000000000008082,
    64'h0000000000000001};
  function automatic logic [22:0] zeta(input logic [7:0] i);
    case (i)
      8'd0: zeta = 23'd1;
      8'd1: zeta = 23'd4808194;
      8'd2: zeta = 23'd3765607;
      8'd3: zeta = 23'd3761513;
      8'd4: zeta = 23'd5178923;
      8'd5: zeta = 23'd5496691;
      8'd6: zeta = 23'd5234739;
      8'd7: zeta = 23'd5178987;
      8'd8: zeta = 23'd7778734;
      8'd9: zeta = 23'd3542485;
      8'd10: zeta = 23'd2682288;
      8'd11: zeta = 23'd2129892;
      8'd12: zeta = 23'd3764867;
      8'd13: zeta = 23'd7375178;
      8'd14: zeta = 23'd557458;
      8'd15: zeta = 23'd7159240;
      8'd16: zeta = 23'd5010068;
      8'd17: zeta = 23'd4317364;
      8'd18: zeta = 23'd2663378;
      8'd19: zeta = 23'd6705802;
      8'd20: zeta = 23'd4855975;
      8'd21: zeta = 23'd7946292;
      8'd22: zeta = 23'd676590;
      8'd23: zeta = 23'd7044481;
      8'd24: zeta = 23'd5152541;
      8'd25: zeta = 23'd1714295;
      8'd26: zeta = 23'd2453983;
      8'd27: zeta = 23'd1460718;
      8'd28: zeta = 23'd7737789;
      8'd29: zeta = 23'd4795319;
      8'd30: zeta = 23'd2815639;
      8'd31: zeta = 23'd2283733;
      8'd32: zeta = 23'd3602218;
      8'd33: zeta = 23'd3182878;
      8'd34: zeta = 23'd2740543;
      8'd35: zeta = 23'd4793971;
      8'd36: zeta = 23'd5269599;
      8'd37: zeta = 23'd2101410;
      8'd38: zeta = 23'd3704823;
      8'd39: zeta = 23'd1159875;
      8'd40: zeta = 23'd394148;
      8'd41: zeta = 23'd928749;
      8'd42: zeta = 23'd1095468;
      8'd43: zeta = 23'd4874037;
      8'd44: zeta = 23'd2071829;
      8'd45: zeta = 23'd4361428;
      8'd46: zeta = 23'd3241972;
      8'd47: zeta = 23'd2156050;
      8'd48: zeta = 23'd3415069;
      8'd49: zeta = 23'd1759347;
      8'd50: zeta = 23'd7562881;
      8'd51: zeta = 23'd4805951;
      8'd52: zeta = 23'd3756790;
      8'd53: zeta = 23'd6444618;
      8'd54: zeta = 23'd6663429;
      8'd55: zeta = 23'd4430364;
      8'd56: zeta = 23'd5483103;
      8'd57: zeta = 23'd3192354;
      8'd58: zeta = 23'd556856;
      8'd59: zeta = 23'd3870317;
      8'd60: zeta = 23'd2917338;
      8'd61: zeta = 23'd1853806;
      8'd62: zeta = 23'd3345963;
      8'd63: zeta = 23'd1858416;
      8'd64: zeta = 23'd3073009;
      8'd65: zeta = 23'd1277625;
      8'd66: zeta = 23'd5744944;
      8'd67: zeta = 23'd3852015;
      8'd68: zeta = 23'd4183372;
      8'd69: zeta = 23'd5157610;
      8'd70: zeta = 23'd5258977;
      8'd71: zeta = 23'd8106357;
      8'd72: zeta = 23'd2508980;
      8'd73: zeta = 23'd2028118;
      8'd74: zeta = 23'd1937570;
      8'd75: zeta = 23'd4564692;
      8'd76: zeta = 23'd2811291;
      8'd77: zeta = 23'd5396636;
      8'd78: zeta = 23'd7270901;
      8'd79: zeta = 23'd4158088;
      8'd80: zeta = 23'd1528066;
      8'd81: zeta = 23'd482649;
      8'd82: zeta = 23'd1148858;
      8'd83: zeta = 23'd5418153;
      8'd84: zeta = 23'd7814814;
      8'd85: zeta = 23'd169688;
      8'd86: zeta = 23'd2462444;
      8'd87: zeta = 23'd5046034;
      8'd88: zeta = 23'd4213992;
      8'd89: zeta = 23'd4892034;
      8'd90: zeta = 23'd1987814;
      8'd91: zeta = 23'd5183169;
      8'd92: zeta = 23'd1736313;
      8'd93: zeta = 23'd235407;
      8'd94: zeta = 23'd5130263;
      8'd95: zeta = 23'd3258457;
      8'd96: zeta = 23'd5801164;
      8'd97: zeta = 23'd1787943;
      8'd98: zeta = 23'd5989328;
      8'd99: zeta = 23'd6125690;
      8'd100: zeta = 23'd3482206;
      8'd101: zeta = 23'd4197502;
      8'd102: zeta = 23'd7080401;
      8'd103: zeta = 23'd6018354;
      8'd104: zeta = 23'd7062739;
      8'd105: zeta = 23'd2461387;
      8'd106: zeta = 23'd3035980;
      8'd107: zeta = 23'd621164;
      8'd108: zeta = 23'd3901472;
      8'd109: zeta = 23'd7153756;
      8'd110: zeta = 23'd2925816;
      8'd111: zeta = 23'd3374250;
      8'd112: zeta = 23'd1356448;
      8'd113: zeta = 23'd5604662;
      8'd114: zeta = 23'd2683270;
      8'd115: zeta = 23'd5601629;
      8'd116: zeta = 23'd4912752;
      8'd117: zeta = 23'd2312838;
      8'd118: zeta = 23'd7727142;
      8'd119: zeta = 23'd7921254;
      8'd120: zeta = 23'd348812;
      8'd121: zeta = 23'd8052569;
      8'd122: zeta = 23'd1011223;
      8'd123: zeta = 23'd6026202;
      8'd124: zeta = 23'd4561790;
      8'd125: zeta = 23'd6458164;
      8'd126: zeta = 23'd6143691;
      8'd127: zeta = 23'd1744507;
      8'd128: zeta = 23'd1753;
      8'd129: zeta = 23'd6444997;
      8'd130: zeta = 23'd5720892;
      8'd131: zeta = 23'd6924527;
      8'd132: zeta = 23'd2660408;
      8'd133: zeta = 23'd6600190;
      8'd134: zeta = 23'd8321269;
      8'd135: zeta = 23'd2772600;
      8'd136: zeta = 23'd1182243;
      8'd137: zeta = 23'd87208;
      8'd138: zeta = 23'd636927;
      8'd139: zeta = 23'd4415111;
      8'd140: zeta = 23'd4423672;
      8'd141: zeta = 23'd6084020;
      8'd142: zeta = 23'd5095502;
      8'd143: zeta = 23'd4663471;
      8'd144: zeta = 23'd8352605;
      8'd145: zeta = 23'd822541;
      8'd146: zeta = 23'd1009365;
      8'd147: zeta = 23'd5926272;
      8'd148: zeta = 23'd6400920;
      8'd149: zeta = 23'd1596822;
      8'd150: zeta = 23'd4423473;
      8'd151: zeta = 23'd4620952;
      8'd152: zeta = 23'd6695264;
      8'd153: zeta = 23'd4969849;
      8'd154: zeta = 23'd2678278;
      8'd155: zeta = 23'd4611469;
      8'd156: zeta = 23'd4829411;
      8'd157: zeta = 23'd635956;
      8'd158: zeta = 23'd8129971;
      8'd159: zeta = 23'd5925040;
      8'd160: zeta = 23'd4234153;
      8'd161: zeta = 23'd6607829;
      8'd162: zeta = 23'd2192938;
      8'd163: zeta = 23'd6653329;
      8'd164: zeta = 23'd2387513;
      8'd165: zeta = 23'd4768667;
      8'd166: zeta = 23'd8111961;
      8'd167: zeta = 23'd5199961;
      8'd168: zeta = 23'd3747250;
      8'd169: zeta = 23'd2296099;
      8'd170: zeta = 23'd1239911;
      8'd171: zeta = 23'd4541938;
      8'd172: zeta = 23'd3195676;
      8'd173: zeta = 23'd2642980;
      8'd174: zeta = 23'd1254190;
      8'd175: zeta = 23'd8368000;
      8'd176: zeta = 23'd2998219;
      8'd177: zeta = 23'd141835;
      8'd178: zeta = 23'd8291116;
      8'd179: zeta = 23'd2513018;
      8'd180: zeta = 23'd7025525;
      8'd181: zeta = 23'd613238;
      8'd182: zeta = 23'd7070156;
      8'd183: zeta = 23'd6161950;
      8'd184: zeta = 23'd7921677;
      8'd185: zeta = 23'd6458423;
      8'd186: zeta = 23'd4040196;
      8'd187: zeta = 23'd4908348;
      8'd188: zeta = 23'd2039144;
      8'd189: zeta = 23'd6500539;
      8'd190: zeta = 23'd7561656;
      8'd191: zeta = 23'd6201452;
      8'd192: zeta = 23'd6757063;
      8'd193: zeta = 23'd2105286;
      8'd194: zeta = 23'd6006015;
      8'd195: zeta = 23'd6346610;
      8'd196: zeta = 23'd586241;
      8'd197: zeta = 23'd7200804;
      8'd198: zeta = 23'd527981;
      8'd199: zeta = 23'd5637006;
      8'd200: zeta = 23'd6903432;
      8'd201: zeta = 23'd1994046;
      8'd202: zeta = 23'd2491325;
      8'd203: zeta = 23'd6987258;
      8'd204: zeta = 23'd507927;
      8'd205: zeta = 23'd7192532;
      8'd206: zeta = 23'd7655613;
      8'd207: zeta = 23'd6545891;
      8'd208: zeta = 23'd5346675;
      8'd209: zeta = 23'd8041997;
      8'd210: zeta = 23'd2647994;
      8'd211: zeta = 23'd3009748;
      8'd212: zeta = 23'd5767564;
      8'd213: zeta = 23'd4148469;
      8'd214: zeta = 23'd749577;
      8'd215: zeta = 23'd4357667;
      8'd216: zeta = 23'd3980599;
      8'd217: zeta = 23'd2569011;
      8'd218: zeta = 23'd6764887;
      8'd219: zeta = 23'd1723229;
      8'd220: zeta = 23'd1665318;
      8'd221: zeta = 23'd2028038;
      8'd222: zeta = 23'd1163598;
      8'd223: zeta = 23'd5011144;
      8'd224: zeta = 23'd3994671;
      8'd225: zeta = 23'd8368538;
      8'd226: zeta = 23'd7009900;
      8'd227: zeta = 23'd3020393;
      8'd228: zeta = 23'd3363542;
      8'd229: zeta = 23'd214880;
      8'd230: zeta = 23'd545376;
      8'd231: zeta = 23'd7609976;
      8'd232: zeta = 23'd3105558;
      8'd233: zeta = 23'd7277073;
      8'd234: zeta = 23'd508145;
      8'd235: zeta = 23'd7826699;
      8'd236: zeta = 23'd860144;
      8'd237: zeta = 23'd3430436;
      8'd238: zeta = 23'd140244;
      8'd239: zeta = 23'd6866265;
      8'd240: zeta = 23'd6195333;
      8'd241: zeta = 23'd3123762;
      8'd242: zeta = 23'd2358373;
      8'd243: zeta = 23'd6187330;
      8'd244: zeta = 23'd5365997;
      8'd245: zeta = 23'd6663603;
      8'd246: zeta = 23'd2926054;
      8'd247: zeta = 23'd7987710;
      8'd248: zeta = 23'd8077412;
      8'd249: zeta = 23'd3531229;
      8'd250: zeta = 23'd4405932;
      8'd251: zeta = 23'd4606686;
      8'd252: zeta = 23'd1900052;
      8'd253: zeta = 23'd7598542;
      8'd254: zeta = 23'd1054478;
      8'd255: zeta = 23'd7648983;
    endcase
  endfunction

  // ---------------- state ----------------
  logic [7:0]  mem [0:32767];           // buffer
  logic [22:0] pm [0:NPOLY*256-1];      // polynomials: slot * 256 + index
  logic [12:0] hptr;                    // host word pointer
  // sequencer
  typedef enum logic [1:0] {Q_IDLE, Q_ISSUE, Q_WAIT} qs_t;
  qs_t         qs;
  logic [6:0]  pc;
  logic [2:0]  ci, cj;                  // loop counters: i over k or l, j over l
  logic [1:0]  opr, psr;                // operation, parameter set
  logic        extm;                    // ext_mu
  logic [14:0] mln;                     // mlen
  logic [15:0] kap;                     // Sign: kappa
  logic        bad;                     // Sign: this attempt is rejected; Verify: the signature is
  // parameter sets
  wire  [3:0]  k = psr == 2'd0 ? 4'd4 : psr == 2'd1 ? 4'd6 : 4'd8;
  wire  [2:0]  l = psr == 2'd0 ? 3'd4 : psr == 2'd1 ? 3'd5 : 3'd7;
  wire         g32 = psr != 2'd0;                         // gamma2 = (q - 1) / 32, else / 88
  wire  [2:0]  eta = psr == 2'd1 ? 3'd4 : 3'd2;
  wire  [4:0]  ebits = psr == 2'd1 ? 5'd4 : 5'd3;         // bits per s1 / s2 coefficient
  wire  [6:0]  ctl = psr == 2'd0 ? 7'd32 : psr == 2'd1 ? 7'd48 : 7'd64;   // |c~| = lambda / 4
  wire  [4:0]  zbits = psr == 2'd0 ? 5'd18 : 5'd20;       // bits per z coefficient
  wire  [19:0] g1 = psr == 2'd0 ? 20'h20000 : 20'h80000;  // gamma1
  wire  [4:0]  w1bits = g32 ? 5'd4 : 5'd6;
  wire  [7:0]  beta = psr == 2'd0 ? 8'd78 : psr == 2'd1 ? 8'd196 : 8'd120;
  wire  [6:0]  omega = psr == 2'd0 ? 7'd80 : psr == 2'd1 ? 7'd55 : 7'd75;
  wire  [5:0]  tau = psr == 2'd0 ? 6'd39 : psr == 2'd1 ? 6'd49 : 6'd60;
  // buffer addresses and lengths (bytes)
  wire  [14:0] ebytes = 15'(ebits) << 5;                  // one packed s1 / s2 polynomial
  wire  [14:0] zbytes = 15'(zbits) << 5;
  wire  [14:0] w1bytes = 15'(w1bits) << 5;
  wire  [14:0] pklen = 15'd32 + 15'd320 * 15'(k);
  wire  [14:0] sk_s1 = A_SK + 15'd128 + ebytes * 15'(ci);
  wire  [14:0] sk_s2 = A_SK + 15'd128 + ebytes * (15'(l) + 15'(ci));
  wire  [14:0] sk_t0 = A_SK + 15'd128 + ebytes * (15'(l) + 15'(k)) + 15'd416 * 15'(ci);
  wire  [14:0] pk_t1 = A_PK + 15'd32 + 15'd320 * 15'(ci);
  wire  [14:0] sig_z = A_SIG + 15'(ctl) + zbytes * 15'(ci);
  wire  [14:0] sig_h = A_SIG + 15'(ctl) + zbytes * 15'(l);
  wire  [14:0] w1_i = A_W1 + w1bytes * 15'(ci);
  wire  [14:0] w1len = w1bytes * 15'(k);
  wire  [15:0] kci = kap + 16'(ci);                       // ExpandMask counter kappa + r
  wire  [5:0]  s_s1i = {3'd0, ci}, s_s1j = {3'd0, cj}, s_s2 = {3'd1, ci}, s_t0 = {3'd2, ci},
               s_yi = {3'd3, ci}, s_yj = {3'd3, cj}, s_w = {3'd4, ci};

  // ---------------- the programs ----------------
  // each step: a hash command, a polynomial unit command, or both (a
  // sampler fed by SHAKE), then what follows
  logic        h_on, h_strm, h_w3, h_128;
  logic [14:0] h_a1, h_l1, h_a2, h_l2, h_oa;
  logic [1:0]  h_ni;
  logic [7:0]  h_i0, h_i1, h_ol;
  uop_t        u_op;
  logic [5:0]  u_dst, u_a, u_b;
  logic        u_clr, u_add, u_chk;
  fn_t         u_fn;
  logic [4:0]  u_n;
  logic [19:0] u_off;
  logic [14:0] u_ma, u_mb, u_len;
  lp_t         lp;
  logic [6:0]  back;
  always_comb begin
    h_on = 1'b0; h_strm = 1'b0; h_w3 = 1'b0; h_128 = 1'b0; h_a1 = '0; h_l1 = '0; h_a2 = '0; h_l2 = '0;
    h_ni = 2'd0; h_i0 = '0; h_i1 = '0; h_oa = '0; h_ol = '0;
    u_op = U_NONE; u_dst = '0; u_a = '0; u_b = '0; u_clr = 1'b0; u_add = 1'b0; u_chk = 1'b0; u_fn = F_OFF;
    u_n = 5'd0; u_off = '0; u_ma = '0; u_mb = '0; u_len = '0;
    lp = L_NEXT; back = '0;
    case (pc)
      // ---- KeyGen: (rho, rho', K) = H(xi || k || l)
      7'd0: begin h_on = 1'b1; h_a1 = A_XI; h_l1 = 15'd32; h_ni = 2'd2; h_i0 = 8'(k); h_i1 = 8'(l);
                  h_oa = A_HO; h_ol = 8'd128; end
      7'd1: begin u_op = U_COPY; u_ma = A_HO; u_mb = A_PK; u_len = 15'd32; end
      7'd2: begin u_op = U_COPY; u_ma = A_HO; u_mb = A_SK; u_len = 15'd32; end
      7'd3: begin u_op = U_COPY; u_ma = A_HO + 15'd96; u_mb = A_SK + 15'd32; u_len = 15'd32; end
      7'd4: begin h_on = 1'b1; h_strm = 1'b1; h_a1 = A_HO + 15'd32; h_l1 = 15'd64; h_ni = 2'd2; h_i0 = 8'(ci);
                  u_op = U_SS; u_dst = s_s1i; end                                   // s1[i]
      7'd5: begin u_op = U_ENC; u_a = s_s1i; u_fn = F_OFF; u_off = 20'(eta); u_n = ebits; u_mb = sk_s1; end
      7'd6: begin u_op = U_NTT; u_dst = s_s1i; lp = L_IL; back = 7'd4; end
      7'd7: begin h_on = 1'b1; h_strm = 1'b1; h_w3 = 1'b1; h_128 = 1'b1; h_a1 = A_HO; h_l1 = 15'd32; h_ni = 2'd2;
                  h_i0 = 8'(cj); h_i1 = 8'(ci); u_op = U_SA; u_dst = P_ACC; u_b = s_s1j; u_clr = cj == 3'd0;
                  lp = L_JL; back = 7'd7; end                                       // t^ = A^ s1^
      7'd8: begin u_op = U_INTT; u_dst = P_ACC; end
      7'd9: begin h_on = 1'b1; h_strm = 1'b1; h_a1 = A_HO + 15'd32; h_l1 = 15'd64; h_ni = 2'd2;
                  h_i0 = 8'(l) + 8'(ci); u_op = U_SS; u_dst = P_TMP; end            // s2[i]
      7'd10: begin u_op = U_ENC; u_a = P_TMP; u_fn = F_OFF; u_off = 20'(eta); u_n = ebits; u_mb = sk_s2; end
      7'd11: begin u_op = U_ADD; u_dst = P_ACC; u_a = P_ACC; u_b = P_TMP; end
      7'd12: begin u_op = U_ENC; u_a = P_ACC; u_fn = F_P2H; u_n = 5'd10; u_mb = pk_t1; end       // t1
      7'd13: begin u_op = U_ENC; u_a = P_ACC; u_fn = F_P2L; u_off = 20'd4096; u_n = 5'd13; u_mb = sk_t0;
                   lp = L_IK; back = 7'd7; end                                      // t0
      7'd14: begin h_on = 1'b1; h_a1 = A_PK; h_l1 = pklen; h_oa = A_SK + 15'd64; h_ol = 8'd64; lp = L_END; end  // tr
      // ---- Sign: s1^, s2^, t0^ from sk
      7'd16: begin u_op = U_DEC; u_ma = sk_s1; u_fn = F_OFF; u_off = 20'(eta); u_n = ebits; u_dst = s_s1i; end
      7'd17: begin u_op = U_NTT; u_dst = s_s1i; lp = L_IL; back = 7'd16; end
      7'd18: begin u_op = U_DEC; u_ma = sk_s2; u_fn = F_OFF; u_off = 20'(eta); u_n = ebits; u_dst = s_s2; end
      7'd19: begin u_op = U_NTT; u_dst = s_s2; lp = L_IK; back = 7'd18; end
      7'd20: begin u_op = U_DEC; u_ma = sk_t0; u_fn = F_OFF; u_off = 20'd4096; u_n = 5'd13; u_dst = s_t0; end
      7'd21: begin u_op = U_NTT; u_dst = s_t0; lp = L_IK; back = 7'd20; end
      7'd22: begin h_on = !extm; h_a1 = A_SK + 15'd64; h_l1 = 15'd64; h_a2 = A_MSG; h_l2 = mln;
                   h_oa = A_MU; h_ol = 8'd64; end                                   // mu = H(tr || M')
      7'd23: begin u_op = U_COPY; u_ma = A_SK + 15'd32; u_mb = A_KC; u_len = 15'd32; end
      7'd24: begin h_on = 1'b1; h_a1 = A_KC; h_l1 = 15'd128; h_oa = A_RPP; h_ol = 8'd64; end   // rho'' = H(K || rnd || mu)
      // the rejection loop
      7'd25: begin h_on = 1'b1; h_strm = 1'b1; h_w3 = 1'b1; h_a1 = A_RPP; h_l1 = 15'd64; h_ni = 2'd2;
                   h_i0 = kci[7:0]; h_i1 = kci[15:8]; u_op = U_SY; u_n = zbits; u_dst = s_yi; end   // y[i]
      7'd26: begin u_op = U_NTT; u_dst = s_yi; lp = L_IL; back = 7'd25; end
      7'd27: begin h_on = 1'b1; h_strm = 1'b1; h_w3 = 1'b1; h_128 = 1'b1; h_a1 = A_SK; h_l1 = 15'd32; h_ni = 2'd2;
                   h_i0 = 8'(cj); h_i1 = 8'(ci); u_op = U_SA; u_dst = s_w; u_b = s_yj; u_clr = cj == 3'd0;
                   lp = L_JL; back = 7'd27; end                                     // w^ = A^ y^
      7'd28: begin u_op = U_INTT; u_dst = s_w; end
      7'd29: begin u_op = U_ENC; u_a = s_w; u_fn = F_HB; u_n = w1bits; u_mb = w1_i; lp = L_IK; back = 7'd27; end
      7'd30: begin h_on = 1'b1; h_a1 = A_MU; h_l1 = 15'd64; h_a2 = A_W1; h_l2 = w1len;
                   h_oa = A_SIG; h_ol = 8'(ctl); end                                // c~ = H(mu || w1Encode(w1))
      7'd31: begin h_on = 1'b1; h_strm = 1'b1; h_a1 = A_SIG; h_l1 = 15'(ctl); u_op = U_SIB; end
      7'd32: begin u_op = U_CLD; u_dst = P_C; end
      7'd33: begin u_op = U_NTT; u_dst = P_C; end
      7'd34: begin u_op = U_PMUL; u_dst = P_TMP; u_a = P_C; u_b = s_s1i; end
      7'd35: begin u_op = U_INTT; u_dst = P_TMP; end
      7'd36: begin h_on = 1'b1; h_strm = 1'b1; h_w3 = 1'b1; h_a1 = A_RPP; h_l1 = 15'd64; h_ni = 2'd2;
                   h_i0 = kci[7:0]; h_i1 = kci[15:8]; u_op = U_SY; u_n = zbits; u_add = 1'b1; u_dst = P_TMP;
                   u_b = P_TMP; end                                                 // z = y + <<c s1>>
      7'd37: begin u_op = U_ENC; u_a = P_TMP; u_fn = F_OFF; u_off = g1; u_n = zbits; u_chk = 1'b1; u_mb = sig_z;
                   lp = L_IL; back = 7'd34; end
      7'd38: begin u_op = U_FILL; u_mb = sig_h; u_len = 15'(omega) + 15'(k); end
      7'd39: begin u_op = U_PMUL; u_dst = P_TMP; u_a = P_C; u_b = s_s2; end
      7'd40: begin u_op = U_INTT; u_dst = P_TMP; end
      7'd41: begin u_op = U_SUB; u_dst = s_w; u_a = s_w; u_b = P_TMP; end         // w - <<c s2>>
      7'd42: begin u_op = U_PMUL; u_dst = P_TMP; u_a = P_C; u_b = s_t0; end
      7'd43: begin u_op = U_INTT; u_dst = P_TMP; end                               // <<c t0>>
      7'd44: begin u_op = U_HINT; u_a = s_w; u_b = P_TMP; u_ma = sig_h; lp = L_IK; back = 7'd39; end
      7'd45: begin lp = L_REJ; back = 7'd25; end
      // ---- Verify
      7'd48: begin h_on = !extm; h_a1 = A_PK; h_l1 = pklen; h_oa = A_TR; h_ol = 8'd64; end   // tr
      7'd49: begin h_on = !extm; h_a1 = A_TR; h_l1 = 15'd64; h_a2 = A_MSG; h_l2 = mln;
                   h_oa = A_MU; h_ol = 8'd64; end                                   // mu
      7'd50: begin u_op = U_DEC; u_ma = sig_z; u_fn = F_OFF; u_off = g1; u_n = zbits; u_chk = 1'b1; u_dst = s_yi; end
      7'd51: begin u_op = U_NTT; u_dst = s_yi; lp = L_IL; back = 7'd50; end
      7'd52: begin h_on = 1'b1; h_strm = 1'b1; h_a1 = A_SIG; h_l1 = 15'(ctl); u_op = U_SIB; end
      7'd53: begin u_op = U_CLD; u_dst = P_C; end
      7'd54: begin u_op = U_NTT; u_dst = P_C; end
      7'd55: begin h_on = 1'b1; h_strm = 1'b1; h_w3 = 1'b1; h_128 = 1'b1; h_a1 = A_PK; h_l1 = 15'd32; h_ni = 2'd2;
                   h_i0 = 8'(cj); h_i1 = 8'(ci); u_op = U_SA; u_dst = P_ACC; u_b = s_yj; u_clr = cj == 3'd0;
                   lp = L_JL; back = 7'd55; end                                     // A^ z^
      7'd56: begin u_op = U_DEC; u_ma = pk_t1; u_fn = F_SHL; u_n = 5'd10; u_dst = P_TMP; end   // t1 2^d
      7'd57: begin u_op = U_NTT; u_dst = P_TMP; end
      7'd58: begin u_op = U_PMUL; u_dst = P_TMP; u_a = P_C; u_b = P_TMP; end
      7'd59: begin u_op = U_SUB; u_dst = P_ACC; u_a = P_ACC; u_b = P_TMP; end
      7'd60: begin u_op = U_INTT; u_dst = P_ACC; end                               // w'Approx
      7'd61: begin u_op = U_HDEC; u_ma = sig_h; end                                // h[i]
      7'd62: begin u_op = U_ENC; u_a = P_ACC; u_fn = F_UH; u_n = w1bits; u_mb = w1_i; lp = L_IK; back = 7'd55; end
      7'd63: begin u_op = U_HZ; u_ma = sig_h; end
      7'd64: begin h_on = 1'b1; h_a1 = A_MU; h_l1 = 15'd64; h_a2 = A_W1; h_l2 = w1len;
                   h_oa = A_CT2; h_ol = 8'(ctl); end                                // c~'
      7'd65: begin u_op = U_CMP; u_ma = A_SIG; u_mb = A_CT2; u_len = 15'(ctl); lp = L_END; end
      default: lp = L_END;
    endcase
  end

  // ---------------- sequencer ----------------
  logic  ugo;                           // a step starts (units load their counters)
  logic  h_done, p_done;
  wire   step_done = u_op != U_NONE ? p_done : h_on ? h_done : 1'b1;
  wire   reserved = op == 2'd3 || pset == 2'd3 || op != OP_KG && !ext_mu && mlen > MSG_MAX;
  wire   [2:0] km1 = 3'(k - 4'd1), lm1 = l - 3'd1;
  assign busy = qs != Q_IDLE;
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      qs <= Q_IDLE; pc <= '0; ci <= '0; cj <= '0; opr <= '0; psr <= '0; extm <= 1'b0; mln <= '0; kap <= '0;
      tries <= '0; fail <= 1'b0; done <= 1'b0; err <= 1'b0; ugo <= 1'b0;
    end else begin
      done <= 1'b0; err <= 1'b0; ugo <= 1'b0;
      case (qs)
        Q_IDLE:
          if (start && reserved) err <= 1'b1;
          else if (start) begin
            opr <= op; psr <= pset; extm <= ext_mu; mln <= mlen; ci <= '0; cj <= '0; kap <= '0;
            tries <= '0; fail <= 1'b0; qs <= Q_ISSUE;
            pc <= op == OP_KG ? 7'd0 : op == OP_SG ? 7'd16 : 7'd48;
          end
        Q_ISSUE: begin ugo <= 1'b1; qs <= Q_WAIT; end
        Q_WAIT:
          if (!ugo && step_done) begin
            qs <= Q_ISSUE;
            case (lp)
              L_NEXT: pc <= pc + 7'd1;
              L_JL: if (cj != lm1) begin cj <= cj + 3'd1; pc <= back; end else begin cj <= '0; pc <= pc + 7'd1; end
              L_IL: if (ci != lm1) begin ci <= ci + 3'd1; pc <= back; end else begin ci <= '0; pc <= pc + 7'd1; end
              L_IK: if (ci != km1) begin ci <= ci + 3'd1; pc <= back; end else begin ci <= '0; pc <= pc + 7'd1; end
              L_REJ: begin
                tries <= tries + 16'd1;
                if (bad) begin kap <= kap + 16'(l); pc <= back; end
                else begin qs <= Q_IDLE; done <= 1'b1; end
              end
              default: begin qs <= Q_IDLE; done <= 1'b1; fail <= opr == OP_VF && bad; end
            endcase
          end
        default: qs <= Q_IDLE;
      endcase
    end
  end

  // ---------------- Keccak sponge (SHAKE128 / SHAKE256) ----------------
  typedef enum logic [1:0] {K_IDLE, K_ABS, K_PERM, K_SQZ} ks_t;
  ks_t         hst;
  logic [1599:0] kst;                   // the state, byte b at [8b +: 8]
  logic [7:0]  kpos;                    // byte position in the rate
  logic [4:0]  krnd;
  logic        ksqz;                    // after this permutation: squeeze
  logic [1:0]  kseg;                    // input: 0 first area, 1 second, 2 immediate bytes
  logic [14:0] kidx;
  logic [7:0]  kout;
  wire  [7:0]  rate = h_128 ? 8'd168 : 8'd136;
  wire  [7:0]  kbyte = kst[{kpos, 3'b000} +: 8];
  // input byte: from the buffer, or an immediate byte
  wire  [14:0] h_ra = (kseg == 2'd0 ? h_a1 : h_a2) + kidx;
  wire  [14:0] klen = kseg == 2'd0 ? h_l1 : h_l2;
  logic [7:0]  h_rd;                    // mem[h_ra]
  wire         k_in = kseg == 2'd2 ? kidx < 15'(h_ni) : kidx < klen;
  wire  [7:0]  k_ib = kseg == 2'd2 ? (kidx == '0 ? h_i0 : h_i1) : h_rd;
  // padding: the SHAKE domain bits 1111 at byte p, the final 1 bit at the last byte of the rate
  function automatic logic [1599:0] kpad(input logic [1599:0] s, input logic [7:0] p, input logic [7:0] r);
    kpad = s;
    kpad[{p, 3'b000} +: 8] = kpad[{p, 3'b000} +: 8] ^ 8'h1F;
    kpad[{r - 8'd1, 3'b111}] = ~kpad[{r - 8'd1, 3'b111}];
  endfunction
  // squeezed bytes: to the buffer, or a stream of one or three bytes per clock to the samplers
  wire         hs_valid = hst == K_SQZ && h_strm;
  wire  [1:0]  hs_n = h_w3 && rate - kpos >= 8'd3 ? 2'd3 : 2'd1;
  wire  [23:0] hs_data = kst[{kpos, 3'b000} +: 24];
  logic        hs_ready;
  wire         h_wr = hst == K_SQZ && !h_strm;
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      hst <= K_IDLE; kst <= '0; kpos <= '0; krnd <= '0; ksqz <= 1'b0; kseg <= '0; kidx <= '0; kout <= '0;
      h_done <= 1'b0;
    end else begin
      h_done <= 1'b0;
      if (ugo) begin
        hst <= h_on ? K_ABS : K_IDLE;
        kst <= '0; kpos <= '0; kseg <= '0; kidx <= '0; kout <= '0;
      end else if (p_done && h_strm) hst <= K_IDLE;
      else case (hst)
        K_ABS:
          if (k_in) begin
            kst[{kpos, 3'b000} +: 8] <= kbyte ^ k_ib;
            kidx <= kidx + 15'd1;
            if (kpos == rate - 8'd1) begin kpos <= '0; hst <= K_PERM; krnd <= '0; ksqz <= 1'b0; end
            else kpos <= kpos + 8'd1;
          end else if (kseg != 2'd2) begin kseg <= kseg + 2'd1; kidx <= '0; end
          else begin
            kst <= kpad(kst, kpos, rate);
            kpos <= '0; hst <= K_PERM; krnd <= '0; ksqz <= 1'b1;
          end
        K_PERM: begin
          kst <= keccak_round(kst, KRC[64 * krnd +: 64]);
          krnd <= krnd + 5'd1;
          if (krnd == 5'd23) hst <= ksqz ? K_SQZ : K_ABS;
        end
        K_SQZ:
          if (h_strm ? hs_ready : 1'b1) begin
            kout <= kout + 8'd1;
            if (!h_strm && kout == h_ol - 8'd1) begin hst <= K_IDLE; h_done <= 1'b1; end
            else if (kpos + 8'(hs_n) == rate) begin kpos <= '0; hst <= K_PERM; krnd <= '0; ksqz <= 1'b1; end
            else kpos <= kpos + 8'(hs_n);
          end
        default: ;
      endcase
    end
  end

  // ---------------- polynomial unit ----------------
  // An issue stage walks the step (counters, the bit buffer of Decode and
  // the samplers, the byte stream from SHAKE) and issues one token per
  // clock: up to three polynomial reads, values, and up to two coefficient
  // writes, an Encode byte, or a hint byte. The polynomial store has
  // registered reads; the arithmetic runs in six stages (product, three
  // folds, butterfly) and every token writes back from the last one, in
  // issue order. A step is done when its last token has been written.
  localparam int PLAT = 6;
  logic        hcnt;                    // a hint leaves the last stage (counted in hidx)
  // the step's parameters, held while it runs (the program decode is not on the datapath)
  uop_t        c_op;
  logic [5:0]  c_dst, c_a, c_b;
  logic        c_clr, c_add, c_chk;
  fn_t         c_fn;
  logic [4:0]  c_n;
  logic [19:0] c_off;
  logic [14:0] c_ma, c_mb, c_len;
  logic [2:0]  c_i;                     // the row (hint steps)
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      c_op <= U_NONE; c_dst <= '0; c_a <= '0; c_b <= '0; c_clr <= 1'b0; c_add <= 1'b0; c_chk <= 1'b0; c_fn <= F_OFF;
      c_n <= '0; c_off <= '0; c_ma <= '0; c_mb <= '0; c_len <= '0; c_i <= '0;
    end else if (ugo) begin
      c_op <= u_op; c_dst <= u_dst; c_a <= u_a; c_b <= u_b; c_clr <= u_clr; c_add <= u_add; c_chk <= u_chk;
      c_fn <= u_fn; c_n <= u_n; c_off <= u_off; c_ma <= u_ma; c_mb <= u_mb; c_len <= u_len; c_i <= ci;
    end
  end
  logic        prun;                    // issuing
  logic [2:0]  pdrn;                    // clocks since the last token was issued
  logic [8:0]  pcnt;                    // coefficient / butterfly index
  logic [2:0]  plyr;                    // NTT layer
  logic        pscl;                    // INTT: the final scaling pass
  logic [43:0] bb;                      // bit buffer (Decode, ExpandMask)
  logic [5:0]  nb;                      // bits in bb; Encode: bits the packer will hold
  logic [14:0] pbc;                     // bytes done
  logic [7:0]  hidx;                    // hint index (Sign: hints written; Verify: hints read)
  logic [7:0]  hend, hprev;             // HintBitUnpack: the row's end, the last index read
  logic        hph, hfst;               // HintBitUnpack: the row's end is read, no index read yet
  logic [255:0] hv;                     // Verify: the row's hints
  logic [255:0] cnz, cng;               // SampleInBall: c[i] != 0, c[i] = -1
  logic [63:0] sgn;                     // SampleInBall: the sign bits
  logic [3:0]  sgc;                     // SampleInBall: sign bytes taken
  logic [8:0]  sbi;                     // SampleInBall: i
  // butterfly indices: NTT layer L has length 128 >> L and zetas from 2^L; the
  // inverse runs the layers from length 1 and the zetas downwards
  wire  [6:0]  bi = pcnt[6:0];
  logic [7:0]  bj, blen, bz;
  always_comb begin
    if (c_op == U_NTT) begin
      blen = 8'd128 >> plyr;
      bj = 8'((8'(bi) >> (3'd7 - plyr)) << (4'd8 - 4'(plyr))) + (8'(bi) & (blen - 8'd1));
      bz = 8'((9'd1 << plyr) + 9'(bi >> (3'd7 - plyr)));
    end else begin
      blen = 8'd1 << plyr;
      bj = 8'((8'(bi) >> plyr) << (4'd1 + 4'(plyr))) + (8'(bi) & (blen - 8'd1));
      bz = 8'((9'd256 >> plyr) - 9'd1 - 9'(bi >> plyr));
    end
  end
  // samplers
  wire  [22:0] sa_v = {hs_data[22:16] & 7'h7F, hs_data[15:0]};    // RejNTTPoly: three bytes
  function automatic logic [24:0] sabs(input logic [24:0] x);
    sabs = x[24] ? 25'd0 - x : x;
  endfunction
  function automatic logic hb_ok(input logic [3:0] b, input logic e4);
    hb_ok = e4 ? b < 4'd9 : b < 4'd15;
  endfunction
  // CoeffFromHalfByte: eta - b (eta 4) or 2 - (b mod 5) (eta 2), mod q
  function automatic logic [22:0] hb_val(input logic [3:0] b, input logic e4);
    logic [3:0] m;
    m = b >= 4'd10 ? b - 4'd10 : b >= 4'd5 ? b - 4'd5 : b;
    hb_val = e4 ? subq(23'd4, 23'(b)) : subq(23'd2, 23'(m));
  endfunction
  wire         e4 = eta == 3'd4;
  wire  [3:0]  sn0 = hs_data[3:0], sn1 = hs_data[7:4];
  wire         so0 = hb_ok(sn0, e4), so1 = hb_ok(sn1, e4) && !(so0 && pcnt == 9'd255);
  // bit buffer: a coefficient leaves when n bits are held; bytes come in while fewer remain
  wire  [43:0] bmask = (44'd1 << c_n) - 44'd1;
  wire         bemit = nb >= 6'(c_n) && !pcnt[8];
  wire  [5:0]  nbe = bemit ? nb - 6'(c_n) : nb;                  // after this clock's coefficient
  wire  [43:0] bbe = bemit ? bb >> c_n : bb;
  wire  [22:0] bval = 23'(bb & bmask);
  // Decode: the coefficient from its n-bit field
  wire  [22:0] dec_v = c_fn == F_SHL ? bval << 13 : subq(23'(c_off), bval);
  // Decode check (z): |gamma1 - v| >= gamma1 - beta, i.e. v <= beta or v >= 2 gamma1 - beta
  wire         dec_f = c_chk && (bval <= 23'(beta) || bval >= 23'(c_off) * 23'd2 - 23'(beta));
  // buffer access
  logic [7:0]  p_rd_a, p_rd_b;
  wire  [14:0] p_ra = c_op == U_HDEC ? c_ma + (hph ? 15'(hidx) : 15'(omega) + 15'(c_i)) :
                      c_op == U_HZ ? c_ma + 15'(hidx) : c_ma + pbc;
  wire  [14:0] p_rb = c_mb + pbc;
  wire         last_b = pbc == c_len - 15'd1;
  always_comb begin
    hs_ready = 1'b0;
    if (prun)
      case (c_op)
        U_SA, U_SS, U_SIB: hs_ready = 1'b1;
        U_SY: hs_ready = nbe < 6'(c_n);
        default: ;
      endcase
  end
  // the token issued this clock
  typedef struct packed {
    logic        w0, w1;                // coefficient writes
    logic [13:0] a0, a1;                // their addresses
    logic        ld, em;                // Encode: load a coefficient / write a byte
    logic [2:0]  sh;                    // Encode: where the loaded bits go in the packer
    logic [14:0] ba;                    // Encode, hints: byte address
    logic        sc;                    // INTT scaling pass
    logic        hn, he;                // MakeHint coefficient, end of the row
    logic        uh;                    // UseHint: the hint bit
    logic        fb;                    // Decode: the check failed
  } tok_t;
  localparam int TW = 55;               // bits of tok_t
  logic        iv;
  tok_t        it;
  logic [22:0] iv0, iv1;                // values from the issue stage
  logic [13:0] ira, irb, ird;           // polynomial reads
  logic        bmw;                     // buffer write from the issue stage (Copy, Fill)
  logic [7:0]  bmw_d;
  always_comb begin
    iv = 1'b0; it = '0; iv0 = '0; iv1 = '0; ira = '0; irb = '0; ird = '0; bmw = 1'b0; bmw_d = '0;
    if (prun)
      case (c_op)
        U_NTT, U_INTT:
          if (pscl) begin
            iv = 1'b1; it.sc = 1'b1; it.w0 = 1'b1; it.a0 = {c_dst, pcnt[7:0]}; ira = {c_dst, pcnt[7:0]};
          end else begin
            iv = 1'b1; it.w0 = 1'b1; it.w1 = 1'b1; it.a0 = {c_dst, bj}; it.a1 = {c_dst, bj + blen};
            ira = {c_dst, bj}; irb = {c_dst, bj + blen};
          end
        U_PMUL, U_ADD, U_SUB: begin
          iv = 1'b1; it.w0 = 1'b1; it.a0 = {c_dst, pcnt[7:0]}; ira = {c_a, pcnt[7:0]}; irb = {c_b, pcnt[7:0]};
        end
        U_SA:
          if (hs_valid && sa_v < Q) begin
            iv = 1'b1; it.w0 = 1'b1; it.a0 = {c_dst, pcnt[7:0]}; iv0 = sa_v; irb = {c_b, pcnt[7:0]};
            ird = {c_dst, pcnt[7:0]};
          end
        U_SS:
          if (hs_valid && (so0 || so1)) begin
            iv = 1'b1; it.w0 = 1'b1; it.a0 = {c_dst, pcnt[7:0]}; iv0 = so0 ? hb_val(sn0, e4) : hb_val(sn1, e4);
            it.w1 = so0 && so1; it.a1 = {c_dst, pcnt[7:0] + 8'd1}; iv1 = hb_val(sn1, e4);
          end
        U_SY:
          if (bemit) begin
            iv = 1'b1; it.w0 = 1'b1; it.a0 = {c_dst, pcnt[7:0]}; iv0 = subq(23'(g1), bval); irb = {c_b, pcnt[7:0]};
          end
        U_CLD: begin
          iv = 1'b1; it.w0 = 1'b1; it.a0 = {c_dst, pcnt[7:0]};
          iv0 = !cnz[pcnt[7:0]] ? 23'd0 : cng[pcnt[7:0]] ? Q - 23'd1 : 23'd1;
        end
        U_DEC: if (bemit) begin iv = 1'b1; it.w0 = 1'b1; it.a0 = {c_dst, pcnt[7:0]}; iv0 = dec_v; it.fb = dec_f; end
        U_ENC:
          if (nb >= 6'd8 || !pcnt[8]) begin
            iv = 1'b1; it.em = nb >= 6'd8; it.ba = p_rb;
            it.ld = !pcnt[8] && (nb >= 6'd8 ? nb - 6'd8 : nb) < 6'd8;
            it.sh = 3'(nb >= 6'd8 ? nb - 6'd8 : nb);
            it.uh = hv[pcnt[7:0]];
            ira = {c_a, pcnt[7:0]};
          end
        U_HINT: begin
          iv = 1'b1;
          if (!pcnt[8]) begin it.hn = 1'b1; it.a0 = {6'd0, pcnt[7:0]}; ira = {c_a, pcnt[7:0]}; irb = {c_b, pcnt[7:0]}; end
          else begin it.he = 1'b1; it.ba = c_ma + 15'(omega) + 15'(c_i); end
        end
        U_COPY: begin bmw = 1'b1; bmw_d = p_rd_a; end
        U_FILL: bmw = 1'b1;
        default: ;
      endcase
  end
  // issue stage
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      prun <= 1'b0; pdrn <= '0; pcnt <= '0; plyr <= '0; pscl <= 1'b0; bb <= '0; nb <= '0; pbc <= '0;
      hidx <= '0; hend <= '0; hprev <= '0; hph <= 1'b0; hfst <= 1'b0; hv <= '0;
      cnz <= '0; cng <= '0; sgn <= '0; sgc <= '0; sbi <= '0;
      p_done <= 1'b0;
    end else begin
      p_done <= 1'b0;
      if (pdrn != '0) begin
        pdrn <= pdrn + 3'd1;
        if (pdrn == 3'(PLAT)) begin pdrn <= '0; p_done <= 1'b1; end
      end
      if (ugo) begin
        prun <= u_op != U_NONE;
        pcnt <= '0; plyr <= '0; pscl <= 1'b0; bb <= '0; nb <= '0; pbc <= '0; hph <= 1'b0; hfst <= 1'b1;
        if (u_op == U_FILL || u_op == U_HDEC && ci == 3'd0) hidx <= '0;
        if (u_op == U_HDEC) hv <= '0;
        if (u_op == U_SIB) begin cnz <= '0; cng <= '0; sgc <= '0; sbi <= 9'd256 - 9'(tau); end
      end else if (prun) begin : b_run
        logic fin;
        fin = 1'b0;
        case (c_op)
          U_NTT, U_INTT:
            if (pscl) begin pcnt <= pcnt + 9'd1; fin = pcnt == 9'd255; end
            else begin
              pcnt <= pcnt + 9'd1;
              if (pcnt == 9'd127) begin
                pcnt <= '0; plyr <= plyr + 3'd1;
                if (plyr == 3'd7) begin
                  if (c_op == U_NTT) fin = 1'b1;
                  else pscl <= 1'b1;
                end
              end
            end
          U_PMUL, U_ADD, U_SUB, U_CLD: begin pcnt <= pcnt + 9'd1; fin = pcnt == 9'd255; end
          U_SA:
            if (hs_valid && sa_v < Q) begin pcnt <= pcnt + 9'd1; fin = pcnt == 9'd255; end
          U_SS:
            if (hs_valid) begin
              pcnt <= pcnt + 9'(so0) + 9'(so1);
              fin = pcnt + 9'(so0) + 9'(so1) == 9'd256;
            end
          U_SY, U_DEC: begin
            if (bemit) begin pcnt <= pcnt + 9'd1; fin = pcnt == 9'd255; end
            bb <= bbe; nb <= nbe;
            if (c_op == U_SY && hs_valid && hs_ready) begin
              bb <= bbe | (44'(hs_n == 2'd3 ? hs_data : {16'd0, hs_data[7:0]}) << nbe);
              nb <= nbe + (hs_n == 2'd3 ? 6'd24 : 6'd8);
            end
            if (c_op == U_DEC && nbe < 6'(c_n)) begin
              bb <= bbe | (44'(p_rd_a) << nbe); nb <= nbe + 6'd8; pbc <= pbc + 15'd1;
            end
          end
          U_ENC:
            if (nb >= 6'd8 || !pcnt[8]) begin
              nb <= (nb >= 6'd8 ? nb - 6'd8 : nb) + (!pcnt[8] && (nb >= 6'd8 ? nb - 6'd8 : nb) < 6'd8 ? 6'(c_n) : 6'd0);
              if (nb >= 6'd8) pbc <= pbc + 15'd1;
              if (!pcnt[8] && (nb >= 6'd8 ? nb - 6'd8 : nb) < 6'd8) pcnt <= pcnt + 9'd1;
            end else fin = 1'b1;
          U_HINT: begin pcnt <= pcnt + 9'd1; fin = pcnt[8]; end
          U_SIB:
            if (hs_valid) begin
              if (sgc != 4'd8) begin sgc <= sgc + 4'd1; sgn <= {hs_data[7:0], sgn[63:8]}; end
              else if (9'(hs_data[7:0]) <= sbi) begin
                cnz[sbi[7:0]] <= cnz[hs_data[7:0]]; cng[sbi[7:0]] <= cng[hs_data[7:0]];
                cnz[hs_data[7:0]] <= 1'b1; cng[hs_data[7:0]] <= sgn[0];
                sgn <= sgn >> 1; sbi <= sbi + 9'd1; fin = sbi == 9'd255;
              end
            end
          U_HDEC:
            if (!hph) begin
              hph <= 1'b1;
              hend <= p_rd_a < hidx || p_rd_a > 8'(omega) ? hidx : p_rd_a;
            end else if (hidx == hend) fin = 1'b1;
            else begin
              hv[p_rd_a] <= 1'b1; hprev <= p_rd_a; hfst <= 1'b0; hidx <= hidx + 8'd1;
            end
          U_HZ:
            if (hidx == 8'(omega)) fin = 1'b1;
            else hidx <= hidx + 8'd1;
          U_FILL, U_COPY, U_CMP: begin pbc <= pbc + 15'd1; fin = last_b; end
          default: fin = 1'b1;
        endcase
        if (fin) begin prun <= 1'b0; pdrn <= 3'd1; end
      end
      // the last stage's hint bytes count here too
      if (hcnt) hidx <= hidx + 8'd1;
    end
  end
  // checks made in the issue stage: hint encoding (Verify), c~ = c~' (Verify)
  wire  hdec_bad = prun && c_op == U_HDEC && (!hph ? p_rd_a < hidx || p_rd_a > 8'(omega)
                                                    : hidx != hend && !hfst && hprev >= p_rd_a);
  wire  hz_bad = prun && c_op == U_HZ && hidx != 8'(omega) && p_rd_a != 8'd0;
  wire  cmp_bad = prun && c_op == U_CMP && p_rd_a != p_rd_b;

  // arithmetic pipeline: stage n registers hold what stage n - 1 computed
  logic [PLAT:1] sv;                    // token valid
  logic [PLAT*TW-1:0] st;               // the tokens, stage n at [TW (n - 1) +: TW]
  logic [22:0] ra1, rb1, rd1, z1, va1, vb1;     // 1: reads, zeta, issued values
  logic [45:0] p2;                      // 2: the product
  logic [22:0] e2, f2, a2, d2;          // 2: value paths (the value, a second value), butterfly a, accumulator
  logic        k2;                      // 2: Hint: |ct0| >= gamma2
  logic [37:0] y3;
  logic [22:0] e3, f3, a3, d3;
  logic [5:0]  q3e, q3f;                // Decompose quotients
  logic [9:0]  h3;                      // Power2Round: t1
  logic        k3;
  logic [28:0] y4;
  logic [22:0] e4v, f4, a4, d4;
  logic [5:0]  q4e, q4f;
  logic [24:0] r4;                      // Decompose: r0 of the value
  logic [9:0]  h4;
  logic [22:0] o4;                      // Encode: the offset form
  logic        k4;
  logic [22:0] m5, e5, f5, a5, d5;      // 5: the product mod q
  logic        x5, k5;                  // 5: MakeHint, the check failed
  logic [22:0] o0, o1;                  // 6: the values to write
  logic        x6, k6;
  logic [27:0] pk;                      // Encode: the packer
  tok_t        t1, t4, t5, tl;          // the tokens of stages 1, 4, 5 and the last
  assign t1 = st[0 +: TW];
  assign t4 = st[3 * TW +: TW];
  assign t5 = st[4 * TW +: TW];
  assign tl = st[(PLAT - 1) * TW +: TW];
  wire  [22:0] g2m = g32 ? 23'd261888 : 23'd95232;   // gamma2
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) sv <= '0;
    else sv <= {sv[PLAT-1:1], iv};
  end
  always_ff @(posedge clk) begin
    st <= {st[(PLAT - 1) * TW - 1:0], it};
    // 1: reads (the store's registered outputs), the zeta, the issued values
    ra1 <= pm[ira]; rb1 <= pm[irb]; rd1 <= pm[ird];
    z1 <= zeta(bz); va1 <= iv0; vb1 <= iv1;
    // 2: the product; the value paths
    case (c_op)
      U_NTT: p2 <= 46'(z1) * 46'(rb1);
      U_INTT: p2 <= t1.sc ? 46'(ra1) * 46'd8347681 : 46'(z1) * 46'(subq(rb1, ra1));   // 256^-1 mod q
      U_PMUL: p2 <= 46'(ra1) * 46'(rb1);
      U_SA: p2 <= 46'(va1) * 46'(rb1);
      default: p2 <= '0;
    endcase
    case (c_op)
      U_INTT, U_ADD: e2 <= addq(ra1, rb1);
      U_SUB: e2 <= subq(ra1, rb1);
      U_SY: e2 <= c_add ? addq(va1, rb1) : va1;
      U_ENC, U_HINT: e2 <= ra1;
      default: e2 <= va1;
    endcase
    f2 <= c_op == U_HINT ? addq(ra1, rb1) : vb1;
    k2 <= absq(rb1) >= g2m;
    a2 <= ra1; d2 <= rd1;
    // 3: first fold; Decompose quotients, Power2Round t1
    y3 <= fold1(47'(p2));
    q3e <= dquo(e2, g32); q3f <= dquo(f2, g32);
    h3 <= 10'((24'(e2) + 24'd4095) >> 13);
    e3 <= e2; f3 <= f2; a3 <= a2; d3 <= d2; k3 <= k2;
    // 4: second fold; Decompose remainders, Encode offset form
    y4 <= fold2(y3);
    r4 <= drem(e3, q3e, g32);
    q4e <= dhi(q3e, g32); q4f <= dhi(q3f, g32);
    h4 <= h3;
    o4 <= c_fn == F_P2L ? 23'(25'd4096 - 25'(e3) + (25'(h3) << 13)) : subq(23'(c_off), e3);
    e4v <= e3; f4 <= f3; a4 <= a3; d4 <= d3;
    // the checks: z (Encode): |z| >= gamma1 - beta; Hint: |r0| >= gamma2 - beta or |ct0| >= gamma2
    k4 <= c_op == U_ENC ? absq(e3) >= 23'(c_off) - 23'(beta) : k3 || sabs(drem(e3, q3e, g32)) >= 25'(g2m) - 25'(beta);
    // 5: third fold; the Encode value
    m5 <= fold3(y4);
    case (c_fn)
      F_OFF, F_P2L: e5 <= o4;
      F_P2H: e5 <= 23'(h4);
      F_HB: e5 <= 23'(q4e);
      F_UH: e5 <= !t4.uh ? 23'(q4e) :
                  !r4[24] && r4 != '0 ? (q4e == (g32 ? 6'd15 : 6'd43) ? 23'd0 : 23'(q4e) + 23'd1) :
                  (q4e == 6'd0 ? (g32 ? 23'd15 : 23'd43) : 23'(q4e) - 23'd1);
      default: e5 <= e4v;
    endcase
    if (c_op != U_ENC) e5 <= e4v;
    x5 <= q4e != q4f;
    k5 <= k4;
    f5 <= f4; a5 <= a4; d5 <= d4;
    // 6: butterflies, accumulation
    case (c_op)
      U_NTT: begin o0 <= addq(a5, m5); o1 <= subq(a5, m5); end
      U_INTT: begin o0 <= t5.sc ? m5 : e5; o1 <= m5; end
      U_PMUL: begin o0 <= m5; o1 <= '0; end
      U_SA: begin o0 <= c_clr ? m5 : addq(m5, d5); o1 <= '0; end
      default: begin o0 <= e5; o1 <= f5; end
    endcase
    x6 <= x5; k6 <= k5;
  end
  wire  _unused = &{1'b0, tl.sc, tl.uh};
  // writes from the last stage
  wire         pw0 = sv[PLAT] && tl.w0, pw1 = sv[PLAT] && tl.w1;
  // Encode: the packer takes the loaded coefficients and writes the bytes
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) pk <= '0;
    else if (ugo) pk <= '0;
    else if (sv[PLAT] && (tl.ld || tl.em))
      pk <= (tl.em ? pk >> 8 : pk) | (tl.ld ? 28'(o0 & 23'((24'd1 << c_n) - 24'd1)) << tl.sh : 28'd0);
  end
  // MakeHint at the last stage: the index byte while fewer than omega, then the row's end
  wire         hwr = sv[PLAT] && tl.hn && x6 && hidx < 8'(omega);
  assign       hcnt = sv[PLAT] && tl.hn && x6 && hidx != 8'hFF;
  wire         hovf = sv[PLAT] && tl.hn && x6 && hidx >= 8'(omega);
  wire         pmw = sv[PLAT] && (tl.em || tl.he) || hwr || bmw;
  wire  [14:0] pmw_a = sv[PLAT] && tl.em ? tl.ba : sv[PLAT] && tl.he ? tl.ba : hwr ? c_ma + 15'(hidx) : p_rb;
  wire  [7:0]  pmw_d = sv[PLAT] && tl.em ? pk[7:0] : sv[PLAT] && tl.he ? hidx : hwr ? tl.a0[7:0] : bmw_d;
  // the reject / fail flag
  wire         set_bad = hdec_bad || hz_bad || cmp_bad || hovf ||
                         sv[PLAT] && (tl.fb || (tl.hn || tl.ld && c_chk) && k6);
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) bad <= 1'b0;
    else if (start && !busy || ugo && pc == 7'd25 && ci == 3'd0) bad <= 1'b0;
    else if (set_bad) bad <= 1'b1;
  end

  // ---------------- memories ----------------
  assign h_rd = mem[h_ra];
  assign p_rd_a = mem[p_ra];
  assign p_rd_b = mem[p_rb];
  wire        mw = h_wr || pmw;
  wire [14:0] mw_a = h_wr ? h_oa + 15'(kout) : pmw_a;
  wire [7:0]  mw_d = h_wr ? kbyte : pmw_d;
  assign hw_ready = !busy;
  assign hr_valid = hr_en && !busy;
  assign hr_data = {mem[{hptr, 2'd3}], mem[{hptr, 2'd2}], mem[{hptr, 2'd1}], mem[{hptr, 2'd0}]};
  always_ff @(posedge clk) begin
    if (mw) mem[mw_a] <= mw_d;
    if (hw_valid && hw_ready)
      for (int i = 0; i < 4; i++) mem[{hptr, 2'(i)}] <= hw_data[8 * i +: 8];
  end
  always_ff @(posedge clk) begin
    if (pw0) pm[tl.a0] <= o0;
    if (pw1) pm[tl.a1] <= o1;
  end
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) hptr <= '0;
    else if (hp_load) hptr <= hp_addr;
    else if (hw_valid && hw_ready || hr_valid && hr_ready) hptr <= hptr + 13'd1;
  end
endmodule
