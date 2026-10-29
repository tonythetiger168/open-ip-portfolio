// SPDX-License-Identifier: Apache-2.0
// ============================================================================
// ML_KEM_top v1.1: ML-KEM (FIPS 203) key encapsulation engine for the three
// parameter sets ML-KEM-512, -768 and -1024: KeyGen, Encaps and Decaps
// (with implicit rejection), the internal algorithms of FIPS 203 section 6
// (the random d, z and m come from the host).
// ----------------------------------------------------------------------------
//  - Host side: a byte buffer of 8 KiB, read and written as 32-bit words
//    (little-endian) through an auto-incrementing pointer (hp_load /
//    hp_addr, then hw_* writes and hr_* reads) while the engine is idle.
//    Buffer map (byte offsets; each field sized for k = 4, the smaller sets
//    use the start of it):
//      0x0000 EK  encapsulation key (384k + 32)     KeyGen out, Encaps in
//      0x0620 DK  decapsulation key (768k + 96)     KeyGen out, Decaps in
//      0x1280 C   ciphertext (32 (du k + dv))       Encaps out, Decaps in
//      0x18A0 C'  re-encryption in Decaps (scratch)
//      0x1EC0 d, 0x1EE0 z (KeyGen in), 0x1F00 m (Encaps in),
//      0x1F20 K   shared secret (Encaps and Decaps out); 0x1F40.. scratch
//  - start with op (0 KeyGen, 1 Encaps, 2 Decaps) and pset (0 ML-KEM-512,
//    1 ML-KEM-768, 2 ML-KEM-1024) runs the operation: busy until the done
//    pulse. A reserved op or pset pulses err instead.
//  - Datapath: Keccak-f[1600] at one round per clock for SHA3-256,
//    SHA3-512, SHAKE128 and SHAKE256 (one byte absorbed or squeezed per
//    clock); one NTT butterfly, base-case multiplication pair, addition,
//    sample or packed coefficient per clock on ten 256-coefficient
//    polynomials, through an 8-stage pipeline (v1.1; the polynomial store
//    has registered reads); exact constant-divisor reductions mod q = 3329.
//  - Side channels: the sequence of operations and its length depend only
//    on the parameter set and the public matrix seed rho (rejection
//    sampling of A); in Decaps the re-encryption, the comparison and the
//    key selection always run in full, and whether the ciphertext was
//    rejected is not visible outside (no flag, same clock count).
//  Not implemented: the random-number source (d, z and m are inputs), the
//  input checks of FIPS 203 7.2 / 7.3 (left to the host), masking against
//  power analysis.
// ============================================================================
module ML_KEM_top (
  input  logic        clk,
  input  logic        rst_n,
  input  logic        start,
  input  logic [1:0]  op,
  input  logic [1:0]  pset,
  output logic        busy,
  output logic        done,
  output logic        err,
  // host access to the buffer
  input  logic        hp_load,
  input  logic [10:0] hp_addr,
  input  logic        hw_valid,
  input  logic [31:0] hw_data,
  output logic        hw_ready,
  input  logic        hr_en,
  output logic        hr_valid,
  output logic [31:0] hr_data,
  input  logic        hr_ready
);
  localparam logic [11:0] Q = 12'd3329;
  // buffer map, in 32-byte blocks (every field starts on one and is a whole number of them)
  localparam logic [7:0] A_EK = 8'd0, A_DK = 8'd49, A_C = 8'd148, A_C2 = 8'd197, A_D = 8'd246, A_Z = 8'd247,
                         A_M = 8'd248, A_K = 8'd249, A_R = 8'd250, A_RHO = 8'd251, A_SIG = 8'd252,
                         A_HEK = 8'd253, A_KB = 8'd254, A_MP = 8'd255;
  // polynomial slots: T[0..3], S[0..3], ACC, TMP
  localparam logic [3:0] P_ACC = 4'd8, P_TMP = 4'd9;
  localparam logic [1:0] OP_KG = 2'd0, OP_EN = 2'd1, OP_DE = 2'd2;
  // hash modes
  localparam logic [1:0] H_256 = 2'd0, H_512 = 2'd1, H_X128 = 2'd2, H_X256 = 2'd3;
  // polynomial unit operations
  typedef enum logic [3:0] {U_NONE, U_CBD, U_SAMP, U_NTT, U_INTT, U_BMUL, U_ADD, U_SUB, U_ENC, U_DEC,
                            U_COPY, U_CMP, U_CSEL} uop_t;
  // what follows a step
  typedef enum logic [2:0] {L_NEXT, L_J, L_I, L_JMP, L_END} lp_t;

  // ---------------- arithmetic mod q ----------------
  // x mod q for x < 2^25 is mrem(x, mquo(x)): floor(x / q) = floor(x * 20642679 / 2^36)
  // exactly. The pipeline computes the quotient and the remainder in separate stages.
  function automatic logic [13:0] mquo(input logic [24:0] x);
    mquo = 14'((50'(x) * 50'd20642679) >> 36);
  endfunction
  function automatic logic [11:0] mrem(input logic [24:0] x, input logic [13:0] p);
    mrem = 12'(x - 25'(p) * 25'(Q));
  endfunction
  function automatic logic [11:0] addq(input logic [11:0] a, input logic [11:0] b);
    logic [12:0] s;
    s = 13'(a) + 13'(b);
    addq = s >= 13'(Q) ? 12'(s - 13'(Q)) : s[11:0];
  endfunction
  function automatic logic [11:0] subq(input logic [11:0] a, input logic [11:0] b);
    subq = a >= b ? a - b : a + Q - b;
  endfunction
  // Compress_d(x) = round(2^d x / q) mod 2^d is cmask(cquo(x, d), d): floor(n / q) =
  // floor(n * 10321340 / 2^35) exactly for n < 2^23; the pipeline takes the quotient and
  // the mask in separate stages
  function automatic logic [11:0] cquo(input logic [11:0] x, input logic [3:0] d);
    logic [22:0] n;
    n = (23'(x) << d) + 23'd1664;
    cquo = 12'((47'(n) * 47'd10321340) >> 35);
  endfunction
  function automatic logic [11:0] cmask(input logic [11:0] r, input logic [3:0] d);
    cmask = r & ((12'd1 << d) - 12'd1);
  endfunction
  // Decompress_d(y) = round(q y / 2^d)
  function automatic logic [11:0] decompress(input logic [11:0] y, input logic [3:0] d);
    logic [23:0] n;
    n = 24'(y) * 24'(Q) + (24'd1 << (d - 4'd1));
    decompress = 12'(n >> d);
  endfunction
  function automatic logic [1:0] pop3(input logic [2:0] b, input logic three);
    pop3 = 2'(b[0]) + 2'(b[1]) + (three ? 2'(b[2]) : 2'd0);
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
  function automatic logic [11:0] zeta(input logic [6:0] i);
    case (i)
      7'd0: zeta = 12'd1;
      7'd1: zeta = 12'd1729;
      7'd2: zeta = 12'd2580;
      7'd3: zeta = 12'd3289;
      7'd4: zeta = 12'd2642;
      7'd5: zeta = 12'd630;
      7'd6: zeta = 12'd1897;
      7'd7: zeta = 12'd848;
      7'd8: zeta = 12'd1062;
      7'd9: zeta = 12'd1919;
      7'd10: zeta = 12'd193;
      7'd11: zeta = 12'd797;
      7'd12: zeta = 12'd2786;
      7'd13: zeta = 12'd3260;
      7'd14: zeta = 12'd569;
      7'd15: zeta = 12'd1746;
      7'd16: zeta = 12'd296;
      7'd17: zeta = 12'd2447;
      7'd18: zeta = 12'd1339;
      7'd19: zeta = 12'd1476;
      7'd20: zeta = 12'd3046;
      7'd21: zeta = 12'd56;
      7'd22: zeta = 12'd2240;
      7'd23: zeta = 12'd1333;
      7'd24: zeta = 12'd1426;
      7'd25: zeta = 12'd2094;
      7'd26: zeta = 12'd535;
      7'd27: zeta = 12'd2882;
      7'd28: zeta = 12'd2393;
      7'd29: zeta = 12'd2879;
      7'd30: zeta = 12'd1974;
      7'd31: zeta = 12'd821;
      7'd32: zeta = 12'd289;
      7'd33: zeta = 12'd331;
      7'd34: zeta = 12'd3253;
      7'd35: zeta = 12'd1756;
      7'd36: zeta = 12'd1197;
      7'd37: zeta = 12'd2304;
      7'd38: zeta = 12'd2277;
      7'd39: zeta = 12'd2055;
      7'd40: zeta = 12'd650;
      7'd41: zeta = 12'd1977;
      7'd42: zeta = 12'd2513;
      7'd43: zeta = 12'd632;
      7'd44: zeta = 12'd2865;
      7'd45: zeta = 12'd33;
      7'd46: zeta = 12'd1320;
      7'd47: zeta = 12'd1915;
      7'd48: zeta = 12'd2319;
      7'd49: zeta = 12'd1435;
      7'd50: zeta = 12'd807;
      7'd51: zeta = 12'd452;
      7'd52: zeta = 12'd1438;
      7'd53: zeta = 12'd2868;
      7'd54: zeta = 12'd1534;
      7'd55: zeta = 12'd2402;
      7'd56: zeta = 12'd2647;
      7'd57: zeta = 12'd2617;
      7'd58: zeta = 12'd1481;
      7'd59: zeta = 12'd648;
      7'd60: zeta = 12'd2474;
      7'd61: zeta = 12'd3110;
      7'd62: zeta = 12'd1227;
      7'd63: zeta = 12'd910;
      7'd64: zeta = 12'd17;
      7'd65: zeta = 12'd2761;
      7'd66: zeta = 12'd583;
      7'd67: zeta = 12'd2649;
      7'd68: zeta = 12'd1637;
      7'd69: zeta = 12'd723;
      7'd70: zeta = 12'd2288;
      7'd71: zeta = 12'd1100;
      7'd72: zeta = 12'd1409;
      7'd73: zeta = 12'd2662;
      7'd74: zeta = 12'd3281;
      7'd75: zeta = 12'd233;
      7'd76: zeta = 12'd756;
      7'd77: zeta = 12'd2156;
      7'd78: zeta = 12'd3015;
      7'd79: zeta = 12'd3050;
      7'd80: zeta = 12'd1703;
      7'd81: zeta = 12'd1651;
      7'd82: zeta = 12'd2789;
      7'd83: zeta = 12'd1789;
      7'd84: zeta = 12'd1847;
      7'd85: zeta = 12'd952;
      7'd86: zeta = 12'd1461;
      7'd87: zeta = 12'd2687;
      7'd88: zeta = 12'd939;
      7'd89: zeta = 12'd2308;
      7'd90: zeta = 12'd2437;
      7'd91: zeta = 12'd2388;
      7'd92: zeta = 12'd733;
      7'd93: zeta = 12'd2337;
      7'd94: zeta = 12'd268;
      7'd95: zeta = 12'd641;
      7'd96: zeta = 12'd1584;
      7'd97: zeta = 12'd2298;
      7'd98: zeta = 12'd2037;
      7'd99: zeta = 12'd3220;
      7'd100: zeta = 12'd375;
      7'd101: zeta = 12'd2549;
      7'd102: zeta = 12'd2090;
      7'd103: zeta = 12'd1645;
      7'd104: zeta = 12'd1063;
      7'd105: zeta = 12'd319;
      7'd106: zeta = 12'd2773;
      7'd107: zeta = 12'd757;
      7'd108: zeta = 12'd2099;
      7'd109: zeta = 12'd561;
      7'd110: zeta = 12'd2466;
      7'd111: zeta = 12'd2594;
      7'd112: zeta = 12'd2804;
      7'd113: zeta = 12'd1092;
      7'd114: zeta = 12'd403;
      7'd115: zeta = 12'd1026;
      7'd116: zeta = 12'd1143;
      7'd117: zeta = 12'd2150;
      7'd118: zeta = 12'd2775;
      7'd119: zeta = 12'd886;
      7'd120: zeta = 12'd1722;
      7'd121: zeta = 12'd1212;
      7'd122: zeta = 12'd1874;
      7'd123: zeta = 12'd1029;
      7'd124: zeta = 12'd2110;
      7'd125: zeta = 12'd2935;
      7'd126: zeta = 12'd885;
      7'd127: zeta = 12'd2154;
    endcase
  endfunction
  function automatic logic [11:0] gamma(input logic [6:0] i);
    case (i)
      7'd0: gamma = 12'd17;
      7'd1: gamma = 12'd3312;
      7'd2: gamma = 12'd2761;
      7'd3: gamma = 12'd568;
      7'd4: gamma = 12'd583;
      7'd5: gamma = 12'd2746;
      7'd6: gamma = 12'd2649;
      7'd7: gamma = 12'd680;
      7'd8: gamma = 12'd1637;
      7'd9: gamma = 12'd1692;
      7'd10: gamma = 12'd723;
      7'd11: gamma = 12'd2606;
      7'd12: gamma = 12'd2288;
      7'd13: gamma = 12'd1041;
      7'd14: gamma = 12'd1100;
      7'd15: gamma = 12'd2229;
      7'd16: gamma = 12'd1409;
      7'd17: gamma = 12'd1920;
      7'd18: gamma = 12'd2662;
      7'd19: gamma = 12'd667;
      7'd20: gamma = 12'd3281;
      7'd21: gamma = 12'd48;
      7'd22: gamma = 12'd233;
      7'd23: gamma = 12'd3096;
      7'd24: gamma = 12'd756;
      7'd25: gamma = 12'd2573;
      7'd26: gamma = 12'd2156;
      7'd27: gamma = 12'd1173;
      7'd28: gamma = 12'd3015;
      7'd29: gamma = 12'd314;
      7'd30: gamma = 12'd3050;
      7'd31: gamma = 12'd279;
      7'd32: gamma = 12'd1703;
      7'd33: gamma = 12'd1626;
      7'd34: gamma = 12'd1651;
      7'd35: gamma = 12'd1678;
      7'd36: gamma = 12'd2789;
      7'd37: gamma = 12'd540;
      7'd38: gamma = 12'd1789;
      7'd39: gamma = 12'd1540;
      7'd40: gamma = 12'd1847;
      7'd41: gamma = 12'd1482;
      7'd42: gamma = 12'd952;
      7'd43: gamma = 12'd2377;
      7'd44: gamma = 12'd1461;
      7'd45: gamma = 12'd1868;
      7'd46: gamma = 12'd2687;
      7'd47: gamma = 12'd642;
      7'd48: gamma = 12'd939;
      7'd49: gamma = 12'd2390;
      7'd50: gamma = 12'd2308;
      7'd51: gamma = 12'd1021;
      7'd52: gamma = 12'd2437;
      7'd53: gamma = 12'd892;
      7'd54: gamma = 12'd2388;
      7'd55: gamma = 12'd941;
      7'd56: gamma = 12'd733;
      7'd57: gamma = 12'd2596;
      7'd58: gamma = 12'd2337;
      7'd59: gamma = 12'd992;
      7'd60: gamma = 12'd268;
      7'd61: gamma = 12'd3061;
      7'd62: gamma = 12'd641;
      7'd63: gamma = 12'd2688;
      7'd64: gamma = 12'd1584;
      7'd65: gamma = 12'd1745;
      7'd66: gamma = 12'd2298;
      7'd67: gamma = 12'd1031;
      7'd68: gamma = 12'd2037;
      7'd69: gamma = 12'd1292;
      7'd70: gamma = 12'd3220;
      7'd71: gamma = 12'd109;
      7'd72: gamma = 12'd375;
      7'd73: gamma = 12'd2954;
      7'd74: gamma = 12'd2549;
      7'd75: gamma = 12'd780;
      7'd76: gamma = 12'd2090;
      7'd77: gamma = 12'd1239;
      7'd78: gamma = 12'd1645;
      7'd79: gamma = 12'd1684;
      7'd80: gamma = 12'd1063;
      7'd81: gamma = 12'd2266;
      7'd82: gamma = 12'd319;
      7'd83: gamma = 12'd3010;
      7'd84: gamma = 12'd2773;
      7'd85: gamma = 12'd556;
      7'd86: gamma = 12'd757;
      7'd87: gamma = 12'd2572;
      7'd88: gamma = 12'd2099;
      7'd89: gamma = 12'd1230;
      7'd90: gamma = 12'd561;
      7'd91: gamma = 12'd2768;
      7'd92: gamma = 12'd2466;
      7'd93: gamma = 12'd863;
      7'd94: gamma = 12'd2594;
      7'd95: gamma = 12'd735;
      7'd96: gamma = 12'd2804;
      7'd97: gamma = 12'd525;
      7'd98: gamma = 12'd1092;
      7'd99: gamma = 12'd2237;
      7'd100: gamma = 12'd403;
      7'd101: gamma = 12'd2926;
      7'd102: gamma = 12'd1026;
      7'd103: gamma = 12'd2303;
      7'd104: gamma = 12'd1143;
      7'd105: gamma = 12'd2186;
      7'd106: gamma = 12'd2150;
      7'd107: gamma = 12'd1179;
      7'd108: gamma = 12'd2775;
      7'd109: gamma = 12'd554;
      7'd110: gamma = 12'd886;
      7'd111: gamma = 12'd2443;
      7'd112: gamma = 12'd1722;
      7'd113: gamma = 12'd1607;
      7'd114: gamma = 12'd1212;
      7'd115: gamma = 12'd2117;
      7'd116: gamma = 12'd1874;
      7'd117: gamma = 12'd1455;
      7'd118: gamma = 12'd1029;
      7'd119: gamma = 12'd2300;
      7'd120: gamma = 12'd2110;
      7'd121: gamma = 12'd1219;
      7'd122: gamma = 12'd2935;
      7'd123: gamma = 12'd394;
      7'd124: gamma = 12'd885;
      7'd125: gamma = 12'd2444;
      7'd126: gamma = 12'd2154;
      7'd127: gamma = 12'd1175;
    endcase
  endfunction

  // ---------------- state ----------------
  logic [7:0]  mem [0:8191];            // buffer
  logic [11:0] pm [0:2559];             // polynomials: slot * 256 + index
  logic [10:0] hptr;                    // host word pointer
  // sequencer
  typedef enum logic [1:0] {Q_IDLE, Q_ISSUE, Q_WAIT} qs_t;
  qs_t         qs;
  logic [5:0]  pc;
  logic [1:0]  ci, cj;                  // loop counters i, j
  logic [1:0]  opr, psr;                // operation, parameter set
  logic        diff;                    // Decaps: C != C'
  wire  [2:0]  k = 3'(psr) + 3'd2;
  wire  [1:0]  km1 = psr + 2'd1;        // k - 1
  wire  [1:0]  eta1 = psr == 2'd0 ? 2'd3 : 2'd2;
  wire  [3:0]  du = psr == 2'd2 ? 4'd11 : 4'd10;
  wire  [3:0]  dv = psr == 2'd2 ? 4'd5 : 4'd4;

  // ---------------- the programs ----------------
  // each step: a hash command, a polynomial unit command, or both (a
  // sampler fed by SHAKE), then what follows
  logic        h_on, h_strm;
  logic [1:0]  h_mode, h_ni;
  logic [7:0]  h_a1, h_a2, h_oa;        // blocks
  logic [5:0]  h_l1, h_l2;              // blocks
  logic [1:0]  h_ol;                    // blocks
  logic [7:0]  h_i0, h_i1;
  uop_t        u_op;
  logic [3:0]  u_dst, u_a, u_b;
  logic        u_eta3, u_cmp, u_clr;
  logic [3:0]  u_d;
  logic [7:0]  u_ma, u_mb;              // blocks
  logic [5:0]  u_len;                   // blocks
  lp_t         lp;
  logic [5:0]  back;
  // addresses and lengths that depend on k, in blocks
  wire  [7:0]  k12 = 8'(k) * 8'd12;                      // 384 k bytes
  wire  [5:0]  ekl = 6'(k12) + 6'd1;                     // |ek|
  wire  [7:0]  cu_off = 8'(du) * 8'(k);                  // where v starts in c
  wire  [5:0]  clen = 6'(cu_off) + 6'(dv);               // |c|
  wire  [7:0]  dk_ek = A_DK + k12;
  wire  [7:0]  dk_h = dk_ek + 8'(ekl);
  wire  [7:0]  dk_z = dk_h + 8'd1;
  wire         dec = opr == OP_DE;
  wire  [7:0]  ekb = dec ? dk_ek : A_EK;                 // Encrypt: ek, m, c
  wire  [7:0]  mb = dec ? A_MP : A_M;
  wire  [7:0]  ob = dec ? A_C2 : A_C;
  wire  [7:0]  i12 = 8'(ci) * 8'd12;
  wire  [7:0]  icu = 8'(ci) * 8'(du);
  wire  [3:0]  sti = {2'b00, ci}, ssi = {2'b01, ci}, ssj = {2'b01, cj};

  always_comb begin
    h_on = 1'b0; h_strm = 1'b0; h_mode = H_256; h_ni = 2'd0; h_a1 = '0; h_a2 = '0; h_oa = '0;
    h_l1 = '0; h_l2 = '0; h_ol = '0; h_i0 = '0; h_i1 = '0;
    u_op = U_NONE; u_dst = '0; u_a = '0; u_b = '0; u_eta3 = 1'b0; u_cmp = 1'b0; u_clr = 1'b0; u_d = 4'd12;
    u_ma = '0; u_mb = '0; u_len = '0;
    lp = L_NEXT; back = '0;
    case (pc)
      // ---- KeyGen
      6'd0: begin h_on = 1'b1; h_mode = H_512; h_a1 = A_D; h_l1 = 6'd1; h_ni = 2'd1; h_i0 = 8'(k);
                  h_oa = A_RHO; h_ol = 2'd2; end                                  // (rho, sigma) = G(d || k)
      6'd1: begin h_on = 1'b1; h_strm = 1'b1; h_mode = H_X256; h_a1 = A_SIG; h_l1 = 6'd1; h_ni = 2'd1;
                  h_i0 = 8'(ci); u_op = U_CBD; u_eta3 = eta1 == 2'd3; u_dst = ssi; end   // s[i]
      6'd2: begin u_op = U_NTT; u_dst = ssi; lp = L_I; back = 6'd1; end
      6'd3: begin h_on = 1'b1; h_strm = 1'b1; h_mode = H_X256; h_a1 = A_SIG; h_l1 = 6'd1; h_ni = 2'd1;
                  h_i0 = 8'(k) + 8'(ci); u_op = U_CBD; u_eta3 = eta1 == 2'd3; u_dst = sti; end   // e[i]
      6'd4: begin u_op = U_NTT; u_dst = sti; lp = L_I; back = 6'd3; end
      6'd5: begin h_on = 1'b1; h_strm = 1'b1; h_mode = H_X128; h_a1 = A_RHO; h_l1 = 6'd1; h_ni = 2'd2;
                  h_i0 = 8'(cj); h_i1 = 8'(ci); u_op = U_SAMP; u_dst = P_TMP; end      // A[i][j]
      6'd6: begin u_op = U_BMUL; u_dst = sti; u_a = P_TMP; u_b = ssj; lp = L_J; back = 6'd5; end
      6'd7: begin lp = L_I; back = 6'd5; end
      6'd8: begin u_op = U_ENC; u_a = sti; u_mb = A_EK + i12; lp = L_I; back = 6'd8; end
      6'd9: begin u_op = U_ENC; u_a = ssi; u_mb = A_DK + i12; lp = L_I; back = 6'd9; end
      6'd10: begin u_op = U_COPY; u_ma = A_RHO; u_mb = A_EK + k12; u_len = 6'd1; end
      6'd11: begin u_op = U_COPY; u_ma = A_EK; u_mb = dk_ek; u_len = ekl; end
      6'd12: begin h_on = 1'b1; h_mode = H_256; h_a1 = A_EK; h_l1 = ekl; h_oa = dk_h; h_ol = 2'd1; end
      6'd13: begin u_op = U_COPY; u_ma = A_Z; u_mb = dk_z; u_len = 6'd1; lp = L_END; end
      // ---- Encaps
      6'd15: begin h_on = 1'b1; h_mode = H_256; h_a1 = A_EK; h_l1 = ekl; h_oa = A_HEK; h_ol = 2'd1; end
      6'd16: begin h_on = 1'b1; h_mode = H_512; h_a1 = A_M; h_l1 = 6'd1; h_a2 = A_HEK; h_l2 = 6'd1;
                   h_oa = A_K; h_ol = 2'd2; end                                   // (K, r) = G(m || H(ek))
      6'd17: begin lp = L_JMP; back = 6'd20; end
      // ---- K-PKE.Encrypt(ekb, mb, r) -> ob
      6'd20: begin u_op = U_DEC; u_ma = ekb + i12; u_dst = sti; lp = L_I; back = 6'd20; end   // t
      6'd21: begin h_on = 1'b1; h_strm = 1'b1; h_mode = H_X256; h_a1 = A_R; h_l1 = 6'd1; h_ni = 2'd1;
                   h_i0 = 8'(ci); u_op = U_CBD; u_eta3 = eta1 == 2'd3; u_dst = ssi; end  // y[i]
      6'd22: begin u_op = U_NTT; u_dst = ssi; lp = L_I; back = 6'd21; end
      6'd23: begin h_on = 1'b1; h_strm = 1'b1; h_mode = H_X128; h_a1 = ekb + k12; h_l1 = 6'd1; h_ni = 2'd2;
                   h_i0 = 8'(ci); h_i1 = 8'(cj); u_op = U_SAMP; u_dst = P_TMP; end     // A[j][i]
      6'd24: begin u_op = U_BMUL; u_dst = P_ACC; u_a = P_TMP; u_b = ssj; u_clr = cj == 2'd0; lp = L_J; back = 6'd23; end
      6'd25: begin u_op = U_INTT; u_dst = P_ACC; end
      6'd26: begin h_on = 1'b1; h_strm = 1'b1; h_mode = H_X256; h_a1 = A_R; h_l1 = 6'd1; h_ni = 2'd1;
                   h_i0 = 8'(k) + 8'(ci); u_op = U_CBD; u_dst = P_TMP; end           // e1[i]
      6'd27: begin u_op = U_ADD; u_dst = P_ACC; u_a = P_ACC; u_b = P_TMP; end
      6'd28: begin u_op = U_ENC; u_a = P_ACC; u_d = du; u_cmp = 1'b1; u_mb = ob + icu; lp = L_I; back = 6'd23; end
      6'd29: begin u_op = U_BMUL; u_dst = P_ACC; u_a = sti; u_b = ssi; u_clr = ci == 2'd0; lp = L_I; back = 6'd29; end
      6'd30: begin u_op = U_INTT; u_dst = P_ACC; end
      6'd31: begin h_on = 1'b1; h_strm = 1'b1; h_mode = H_X256; h_a1 = A_R; h_l1 = 6'd1; h_ni = 2'd1;
                   h_i0 = 8'(2 * k); u_op = U_CBD; u_dst = P_TMP; end                // e2
      6'd32: begin u_op = U_ADD; u_dst = P_ACC; u_a = P_ACC; u_b = P_TMP; end
      6'd33: begin u_op = U_DEC; u_ma = mb; u_d = 4'd1; u_cmp = 1'b1; u_dst = P_TMP; end   // mu
      6'd34: begin u_op = U_ADD; u_dst = P_ACC; u_a = P_ACC; u_b = P_TMP; end
      6'd35: begin u_op = U_ENC; u_a = P_ACC; u_d = dv; u_cmp = 1'b1; u_mb = ob + cu_off; end
      6'd36: begin if (dec) lp = L_JMP; else lp = L_END; back = 6'd50; end
      // ---- Decaps: m' = Decrypt(dk, c)
      6'd40: begin u_op = U_DEC; u_ma = A_C + icu; u_d = du; u_cmp = 1'b1; u_dst = P_TMP; end   // u[i]
      6'd41: begin u_op = U_NTT; u_dst = P_TMP; end
      6'd42: begin u_op = U_DEC; u_ma = A_DK + i12; u_dst = 4'd4; end                         // s[i]
      6'd43: begin u_op = U_BMUL; u_dst = P_ACC; u_a = 4'd4; u_b = P_TMP; u_clr = ci == 2'd0; lp = L_I; back = 6'd40; end
      6'd44: begin u_op = U_INTT; u_dst = P_ACC; end
      6'd45: begin u_op = U_DEC; u_ma = A_C + cu_off; u_d = dv; u_cmp = 1'b1; u_dst = P_TMP; end  // v
      6'd46: begin u_op = U_SUB; u_dst = P_TMP; u_a = P_TMP; u_b = P_ACC; end
      6'd47: begin u_op = U_ENC; u_a = P_TMP; u_d = 4'd1; u_cmp = 1'b1; u_mb = A_MP; end
      6'd48: begin h_on = 1'b1; h_mode = H_512; h_a1 = A_MP; h_l1 = 6'd1; h_a2 = dk_h; h_l2 = 6'd1;
                   h_oa = A_K; h_ol = 2'd2; end                                   // (K', r') = G(m' || h)
      6'd49: begin lp = L_JMP; back = 6'd20; end
      6'd50: begin h_on = 1'b1; h_mode = H_X256; h_a1 = dk_z; h_l1 = 6'd1; h_a2 = A_C; h_l2 = clen;
                   h_oa = A_KB; h_ol = 2'd1; end                                  // K_bar = J(z || c)
      6'd51: begin u_op = U_CMP; u_ma = A_C; u_mb = A_C2; u_len = clen; end
      6'd52: begin u_op = U_CSEL; u_ma = A_KB; u_mb = A_K; u_len = 6'd1; lp = L_END; end
      default: lp = L_END;
    endcase
  end

  // ---------------- sequencer ----------------
  logic  ugo;                           // a step starts (units load their counters)
  logic  h_done, p_done;
  wire   step_done = u_op != U_NONE ? p_done : h_on ? h_done : 1'b1;
  wire   bad = op == 2'd3 || pset == 2'd3;
  assign busy = qs != Q_IDLE;
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      qs <= Q_IDLE; pc <= '0; ci <= '0; cj <= '0; opr <= '0; psr <= '0; done <= 1'b0; err <= 1'b0; ugo <= 1'b0;
    end else begin
      done <= 1'b0; err <= 1'b0; ugo <= 1'b0;
      case (qs)
        Q_IDLE:
          if (start && bad) err <= 1'b1;
          else if (start) begin
            opr <= op; psr <= pset; ci <= '0; cj <= '0; qs <= Q_ISSUE;
            pc <= op == OP_KG ? 6'd0 : op == OP_EN ? 6'd15 : 6'd40;
          end
        Q_ISSUE: begin ugo <= 1'b1; qs <= Q_WAIT; end
        Q_WAIT:
          if (!ugo && step_done) begin
            qs <= Q_ISSUE;
            case (lp)
              L_NEXT: pc <= pc + 6'd1;
              L_J: if (cj != km1) begin cj <= cj + 2'd1; pc <= back; end else begin cj <= '0; pc <= pc + 6'd1; end
              L_I: if (ci != km1) begin ci <= ci + 2'd1; pc <= back; end else begin ci <= '0; pc <= pc + 6'd1; end
              L_JMP: pc <= back;
              default: begin qs <= Q_IDLE; done <= 1'b1; end
            endcase
          end
        default: qs <= Q_IDLE;
      endcase
    end
  end

  // ---------------- Keccak sponge ----------------
  typedef enum logic [1:0] {K_IDLE, K_ABS, K_PERM, K_SQZ} ks_t;
  ks_t         hst;
  logic [1599:0] kst;                   // the state, byte b at [8b +: 8]
  logic [7:0]  kpos;                    // byte position in the rate
  logic [4:0]  krnd;
  logic        ksqz;                    // after this permutation: squeeze
  logic [1:0]  kseg;                    // input: 0 first area, 1 second, 2 immediate bytes
  logic [10:0] kidx;
  logic [6:0]  kout;
  wire  [7:0]  rate = h_mode == H_512 ? 8'd72 : h_mode == H_X128 ? 8'd168 : 8'd136;
  wire  [7:0]  kdom = h_mode[1] ? 8'h1F : 8'h06;
  wire  [7:0]  kbyte = kst[{kpos, 3'b000} +: 8];
  // input byte: from the buffer, or an immediate byte
  wire  [12:0] h_ra = {kseg == 2'd0 ? h_a1 : h_a2, 5'd0} + 13'(kidx);
  wire  [5:0]  klen = kseg == 2'd0 ? h_l1 : h_l2;       // blocks
  logic [7:0]  h_rd;                    // mem[h_ra]
  wire         k_in = kseg == 2'd2 ? kidx < 11'(h_ni) : kidx[10:5] < klen;
  wire  [7:0]  k_ib = kseg == 2'd2 ? (kidx == '0 ? h_i0 : h_i1) : h_rd;
  // padding: the domain bits at byte p, the final 1 bit at the last byte of the rate
  function automatic logic [1599:0] kpad(input logic [1599:0] s, input logic [7:0] p, input logic [7:0] r,
                                         input logic [7:0] dom);
    kpad = s;
    kpad[{p, 3'b000} +: 8] = kpad[{p, 3'b000} +: 8] ^ dom;
    kpad[{r - 8'd1, 3'b111}] = ~kpad[{r - 8'd1, 3'b111}];
  endfunction
  // squeezed bytes: to the buffer, or a stream to the samplers
  wire         hs_valid = hst == K_SQZ && h_strm;
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
            kidx <= kidx + 11'd1;
            if (kpos == rate - 8'd1) begin kpos <= '0; hst <= K_PERM; krnd <= '0; ksqz <= 1'b0; end
            else kpos <= kpos + 8'd1;
          end else if (kseg != 2'd2) begin kseg <= kseg + 2'd1; kidx <= '0; end
          else begin
            kst <= kpad(kst, kpos, rate, kdom);
            kpos <= '0; hst <= K_PERM; krnd <= '0; ksqz <= 1'b1;
          end
        K_PERM: begin
          kst <= keccak_round(kst, KRC[64 * krnd +: 64]);
          krnd <= krnd + 5'd1;
          if (krnd == 5'd23) hst <= ksqz ? K_SQZ : K_ABS;
        end
        K_SQZ:
          if (h_strm ? hs_ready : 1'b1) begin
            kout <= kout + 7'd1;
            if (!h_strm && kout == {h_ol, 5'd0} - 7'd1) begin hst <= K_IDLE; h_done <= 1'b1; end
            else if (kpos == rate - 8'd1) begin kpos <= '0; hst <= K_PERM; krnd <= '0; ksqz <= 1'b1; end
            else kpos <= kpos + 8'd1;
          end
        default: ;
      endcase
    end
  end

  // ---------------- polynomial unit ----------------
  // An issue stage walks the step (counters, the bit buffer of Decode and
  // CBD, the byte stream of the samplers) and issues one token per clock: up
  // to six polynomial reads, a value, and up to two coefficient writes or an
  // Encode byte. The polynomial store has registered reads; the arithmetic
  // runs in eight stages (products, Barrett quotient, remainder, butterfly
  // or second product, quotient, remainder, accumulate) and every token
  // writes back from the last one, in issue order. A step is done when its
  // last token has been written (PLAT clocks after it was issued).
  localparam int PLAT = 8;
  // the step's parameters, held while it runs (the program decode is not on the datapath)
  uop_t        c_op;
  logic [3:0]  c_dst, c_a, c_b, c_d;
  logic        c_eta3, c_cmp, c_clr;
  logic [7:0]  c_ma, c_mb;
  logic [5:0]  c_len;
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      c_op <= U_NONE; c_dst <= '0; c_a <= '0; c_b <= '0; c_d <= '0; c_eta3 <= 1'b0; c_cmp <= 1'b0; c_clr <= 1'b0;
      c_ma <= '0; c_mb <= '0; c_len <= '0;
    end else if (ugo) begin
      c_op <= u_op; c_dst <= u_dst; c_a <= u_a; c_b <= u_b; c_d <= u_d; c_eta3 <= u_eta3; c_cmp <= u_cmp;
      c_clr <= u_clr; c_ma <= u_ma; c_mb <= u_mb; c_len <= u_len;
    end
  end
  logic        prun;                    // issuing
  logic [3:0]  pdrn;                    // clocks since the last token was issued
  logic [8:0]  pcnt;                    // coefficient / butterfly / pair index
  logic [2:0]  plyr;                    // NTT layer
  logic        pscl;                    // INTT: the final scaling pass
  logic [17:0] bb;                      // bit buffer (decode, CBD)
  logic [4:0]  nb;                      // bits in bb; Encode: bits the packer will hold
  logic [10:0] pbc;                     // bytes done
  logic [7:0]  sb0, sb1;                // SampleNTT: bytes of the group
  logic [1:0]  sbc;
  logic        spend;                   // SampleNTT: second value to write
  logic [11:0] sval;
  // butterfly indices
  wire  [6:0]  bi = pcnt[6:0];
  logic [7:0]  bj, blen;
  logic [6:0]  bz;
  always_comb begin
    if (c_op == U_NTT) begin
      blen = 8'd128 >> plyr;
      bj = 8'((8'(bi) >> (3'd7 - plyr)) << (4'd8 - 4'(plyr))) + 8'(bi & 7'(blen - 8'd1));
      bz = 7'((7'd1 << plyr) + (bi >> (3'd7 - plyr)));
    end else begin
      blen = 8'd2 << plyr;
      bj = 8'((8'(bi) >> (plyr + 3'd1)) << (plyr + 3'd2)) + 8'(bi & 7'(blen - 8'd1));
      bz = 7'((8'd1 << (3'd7 - plyr)) - 8'd1 - 8'(bi >> (plyr + 3'd1)));
    end
  end
  // packing
  wire  [11:0] dec_r = 12'(bb) & ((12'd1 << c_d) - 12'd1);
  wire  [11:0] dec_q = c_d == 4'd12 && dec_r >= Q ? dec_r - Q : dec_r;
  wire  [4:0]  cbd_n = c_eta3 ? 5'd6 : 5'd4;
  wire  [11:0] cbd_v = subq(12'(pop3(bb[2:0], c_eta3)), 12'(pop3(c_eta3 ? bb[5:3] : {1'b0, bb[3:2]}, c_eta3)));
  // SampleNTT: the group's two candidates
  wire  [7:0]  hs_byte = kbyte;
  wire  [11:0] sd1 = {sb1[3:0], sb0};
  wire  [11:0] sd2 = {hs_byte, sb1[7:4]};
  // buffer access
  wire  [12:0] p_ra = {c_ma, 5'd0} + 13'(pbc);
  wire  [12:0] p_rb = {c_mb, 5'd0} + 13'(pbc);
  logic [7:0]  p_rd_a, p_rd_b;           // mem[p_ra], mem[p_rb]
  wire         last_b = pbc == {c_len, 5'd0} - 11'd1;
  always_comb begin
    hs_ready = 1'b0;
    if (prun && c_op == U_CBD) hs_ready = nb < cbd_n;
    if (prun && c_op == U_SAMP) hs_ready = !spend;
  end
  // the token issued this clock
  typedef struct packed {
    logic        w0, w1;                // coefficient writes
    logic [11:0] a0, a1;                // their addresses
    logic        ld, em;                // Encode: load a coefficient / write a byte
    logic [2:0]  sh;                    // Encode: where the loaded bits go in the packer (fewer than 8 held)
    logic [12:0] ba;                    // Encode: byte address
    logic        sc;                    // INTT scaling pass
  } tok_t;
  logic        iv;
  tok_t        it;
  logic [11:0] ival;                    // CBD, SampleNTT, Decode: the value
  logic [71:0] ira;                     // polynomial reads, 12 bits each
  logic        bmw;                     // buffer write from the issue stage (Copy, Select)
  logic [7:0]  bmw_d;
  always_comb begin
    iv = 1'b0; it = '0; ival = '0; bmw = 1'b0; bmw_d = '0;
    ira = '0;
    if (prun)
      case (c_op)
        U_CBD: if (nb >= cbd_n) begin iv = 1'b1; it.w0 = 1'b1; it.a0 = {c_dst, pcnt[7:0]}; ival = cbd_v; end
        U_SAMP:
          if (spend) begin iv = 1'b1; it.w0 = 1'b1; it.a0 = {c_dst, pcnt[7:0]}; ival = sval; end
          else if (hs_valid && sbc == 2'd2 && sd1 < Q) begin
            iv = 1'b1; it.w0 = 1'b1; it.a0 = {c_dst, pcnt[7:0]}; ival = sd1;
          end
        U_NTT, U_INTT:
          if (pscl) begin
            iv = 1'b1; it.sc = 1'b1; it.w0 = 1'b1; it.a0 = {c_dst, pcnt[7:0]}; ira[0 +: 12] = {c_dst, pcnt[7:0]};
          end else begin
            iv = 1'b1; it.w0 = 1'b1; it.w1 = 1'b1; it.a0 = {c_dst, bj}; it.a1 = {c_dst, bj + blen};
            ira[0 +: 12] = {c_dst, bj}; ira[12 +: 12] = {c_dst, bj + blen};
          end
        U_BMUL: begin
          iv = 1'b1; it.w0 = 1'b1; it.w1 = 1'b1; it.a0 = {c_dst, bi, 1'b0}; it.a1 = {c_dst, bi, 1'b1};
          ira[0 +: 12] = {c_a, bi, 1'b0}; ira[12 +: 12] = {c_a, bi, 1'b1}; ira[24 +: 12] = {c_b, bi, 1'b0}; ira[36 +: 12] = {c_b, bi, 1'b1};
          ira[48 +: 12] = {c_dst, bi, 1'b0}; ira[60 +: 12] = {c_dst, bi, 1'b1};
        end
        U_ADD, U_SUB: begin
          iv = 1'b1; it.w0 = 1'b1; it.a0 = {c_dst, pcnt[7:0]}; ira[0 +: 12] = {c_a, pcnt[7:0]}; ira[24 +: 12] = {c_b, pcnt[7:0]};
        end
        U_ENC:
          if (nb >= 5'd8) begin iv = 1'b1; it.em = 1'b1; it.ba = p_rb; end
          else if (!pcnt[8]) begin iv = 1'b1; it.ld = 1'b1; it.sh = nb[2:0]; ira[0 +: 12] = {c_a, pcnt[7:0]}; end
        U_DEC: if (5'(c_d) <= nb) begin iv = 1'b1; it.w0 = 1'b1; it.a0 = {c_dst, pcnt[7:0]}; ival = dec_q; end
        U_COPY: begin bmw = 1'b1; bmw_d = p_rd_a; end
        U_CSEL: begin bmw = 1'b1; bmw_d = diff ? p_rd_a : p_rd_b; end
        default: ;
      endcase
  end
  // issue stage
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      prun <= 1'b0; pdrn <= '0; pcnt <= '0; plyr <= '0; bb <= '0; nb <= '0; pbc <= '0;
      sb0 <= '0; sb1 <= '0; sbc <= '0; sval <= '0;
      pscl <= 1'b0;
      spend <= 1'b0;
      p_done <= 1'b0;
      diff <= 1'b0;
    end else begin
      p_done <= 1'b0;
      if (pdrn != '0) begin
        pdrn <= pdrn + 4'd1;
        if (pdrn == 4'(PLAT)) begin pdrn <= '0; p_done <= 1'b1; end
      end
      if (ugo) begin
        prun <= u_op != U_NONE;
        pcnt <= '0; plyr <= '0; pscl <= 1'b0; bb <= '0; nb <= '0; pbc <= '0; sbc <= '0; spend <= 1'b0;
        if (u_op == U_CMP) diff <= 1'b0;
      end else if (prun) begin : b_run
        logic fin;
        fin = 1'b0;
        case (c_op)
          U_CBD:
            if (nb >= cbd_n) begin
              bb <= bb >> cbd_n; nb <= nb - cbd_n; pcnt <= pcnt + 9'd1;
              fin = pcnt == 9'd255;
            end else if (hs_valid) begin bb <= bb | (18'(hs_byte) << nb); nb <= nb + 5'd8; end
          U_SAMP:
            if (spend) begin
              spend <= 1'b0; pcnt <= pcnt + 9'd1; fin = pcnt == 9'd255;
            end else if (hs_valid) begin
              if (sbc == 2'd0) begin sb0 <= hs_byte; sbc <= 2'd1; end
              else if (sbc == 2'd1) begin sb1 <= hs_byte; sbc <= 2'd2; end
              else begin
                sbc <= 2'd0;
                if (sd1 < Q) begin pcnt <= pcnt + 9'd1; fin = pcnt == 9'd255; end
                if (sd2 < Q && !fin) begin spend <= 1'b1; sval <= sd2; end
              end
            end
          U_NTT, U_INTT:
            if (pscl) begin pcnt <= pcnt + 9'd1; fin = pcnt == 9'd255; end
            else begin
              pcnt <= pcnt + 9'd1;
              if (pcnt == 9'd127) begin
                pcnt <= '0; plyr <= plyr + 3'd1;
                if (plyr == 3'd6) begin
                  if (c_op == U_NTT) fin = 1'b1;
                  else pscl <= 1'b1;
                end
              end
            end
          U_BMUL: begin pcnt <= pcnt + 9'd1; fin = pcnt == 9'd127; end
          U_ADD, U_SUB: begin pcnt <= pcnt + 9'd1; fin = pcnt == 9'd255; end
          U_ENC:
            if (nb >= 5'd8) begin nb <= nb - 5'd8; pbc <= pbc + 11'd1; end
            else if (!pcnt[8]) begin nb <= nb + 5'(c_d); pcnt <= pcnt + 9'd1; end
            else fin = 1'b1;
          U_DEC:
            if (5'(c_d) <= nb) begin
              bb <= bb >> c_d; nb <= nb - 5'(c_d); pcnt <= pcnt + 9'd1; fin = pcnt == 9'd255;
            end else begin bb <= bb | (18'(p_rd_a) << nb); nb <= nb + 5'd8; pbc <= pbc + 11'd1; end
          U_COPY, U_CSEL: begin pbc <= pbc + 11'd1; fin = last_b; end
          U_CMP: begin diff <= diff | (p_rd_a != p_rd_b); pbc <= pbc + 11'd1; fin = last_b; end
          default: fin = 1'b1;
        endcase
        if (fin) begin prun <= 1'b0; pdrn <= 4'd1; end
      end
    end
  end

  // arithmetic pipeline: stage n registers hold what stage n - 1 computed
  logic [PLAT:1] sv;                    // token valid
  localparam int TW = 45;                // bits of tok_t
  logic [PLAT*TW-1:0] st;               // the tokens, stage n at [TW (n - 1) +: TW]
  logic [11:0] r0, r1, r2, r3, r4, r5;  // stage 1: the polynomial reads
  logic [11:0] z1, val1;                // stage 1: zeta or gamma, the issued value
  logic [23:0] m2a, m3a;                // products to reduce: below q^2
  logic [24:0] m2b, m3b;                //   and sums of two, below 2 q^2
  logic [23:0] m2c, m3c, m4c;           // Basemul: a0 b0
  logic [11:0] v2, v3, v4;              // single-value results
  logic [11:0] fa2, fa3, fa4;           // butterfly: the first input
  logic [11:0] g2, g3, g4;              // Basemul: gamma
  logic [11:0] d0[2:7], d1[2:7];        // Basemul: the accumulator
  logic [11:0] q3a;                     // quotients: below q
  logic [12:0] q3b, q6;                 //   and below 2 q
  logic [11:0] r4a, r4b;
  logic [24:0] y5, y6;                  // Basemul: a0 b0 + (a1 b1 mod q) gamma
  logic [11:0] o0[5:PLAT], o1[5:PLAT];  // the values to write
  logic [17:0] pk;                      // Encode: the packer
  wire         bm = c_op == U_BMUL;
  tok_t        tl;                      // the last stage's token
  assign tl = st[(PLAT - 1) * TW +: TW];
  wire         sc1 = st[0], sc4 = st[3 * TW];   // the scaling flag (bit 0 of a token) in stages 1 and 4
  wire         _unused = tl.sc;
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) sv <= '0;
    else sv <= {sv[PLAT-1:1], iv};
  end
  always_ff @(posedge clk) begin
    st <= {st[(PLAT - 1) * TW - 1:0], it};
    // 1: reads (the store's registered outputs), constants
    r0 <= pm[ira[0 +: 12]]; r1 <= pm[ira[12 +: 12]]; r2 <= pm[ira[24 +: 12]]; r3 <= pm[ira[36 +: 12]]; r4 <= pm[ira[48 +: 12]]; r5 <= pm[ira[60 +: 12]];
    z1 <= bm ? gamma(bi) : zeta(bz);
    val1 <= ival;
    // 2: products; the single-value operations
    m2a <= '0; m2b <= '0; m2c <= '0;
    case (c_op)
      U_NTT: m2a <= 24'(z1) * 24'(r1);
      U_INTT: m2a <= sc1 ? 24'(r0) * 24'd3303 : 24'(z1) * 24'(subq(r1, r0));   // 128^-1 mod q
      U_BMUL: begin
        m2a <= 24'(r1) * 24'(r3);
        m2b <= 25'(r0) * 25'(r3) + 25'(r1) * 25'(r2);
        m2c <= 24'(r0) * 24'(r2);
      end
      default: ;
    endcase
    case (c_op)
      U_INTT: v2 <= addq(r0, r1);
      U_ADD: v2 <= addq(r0, r2);
      U_SUB: v2 <= subq(r0, r2);
      U_ENC: v2 <= c_cmp ? cquo(r0, c_d) : r0;
      U_DEC: v2 <= c_cmp ? decompress(val1, c_d) : val1;
      default: v2 <= val1;
    endcase
    fa2 <= r0; g2 <= z1; d0[2] <= r4; d1[2] <= r5;
    // 3: Barrett quotients
    q3a <= 12'(mquo(25'(m2a))); q3b <= 13'(mquo(m2b));
    m3a <= m2a; m3b <= m2b; m3c <= m2c;
    v3 <= c_op == U_ENC && c_cmp ? cmask(v2, c_d) : v2;
    fa3 <= fa2; g3 <= g2;
    // 4: remainders
    r4a <= mrem(25'(m3a), 14'(q3a)); r4b <= mrem(m3b, 14'(q3b));
    m4c <= m3c; v4 <= v3; fa4 <= fa3; g4 <= g3;
    // 5: butterflies; Basemul: a0 b0 + (a1 b1 mod q) gamma
    case (c_op)
      U_NTT: begin o0[5] <= addq(fa4, r4a); o1[5] <= subq(fa4, r4a); end
      U_INTT: begin o0[5] <= sc4 ? r4a : v4; o1[5] <= r4a; end
      U_BMUL: begin o0[5] <= '0; o1[5] <= r4b; end
      default: begin o0[5] <= v4; o1[5] <= '0; end
    endcase
    y5 <= 25'(m4c) + 25'(r4a) * 25'(g4);
    // 6, 7: its reduction
    q6 <= 13'(mquo(y5)); y6 <= y5;
    o0[6] <= o0[5]; o1[6] <= o1[5]; o1[7] <= o1[6];
    o0[7] <= bm ? mrem(y6, 14'(q6)) : o0[6];
    for (int n = 3; n <= 7; n++) begin d0[n] <= d0[n - 1]; d1[n] <= d1[n - 1]; end
    // 8: Basemul accumulates
    o0[8] <= bm && !c_clr ? addq(d0[7], o0[7]) : o0[7];
    o1[8] <= bm && !c_clr ? addq(d1[7], o1[7]) : o1[7];
  end
  // writes from the last stage
  wire  [11:0] pw0_a = tl.a0, pw1_a = tl.a1;
  wire         pw0 = sv[PLAT] && tl.w0, pw1 = sv[PLAT] && tl.w1;
  wire  [11:0] pw0_d = o0[PLAT], pw1_d = o1[PLAT];
  // Encode: the packer takes the loaded coefficients and writes the bytes
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) pk <= '0;
    else if (ugo) pk <= '0;
    else if (sv[PLAT] && tl.ld) pk <= pk | (18'(o0[PLAT]) << tl.sh);
    else if (sv[PLAT] && tl.em) pk <= pk >> 8;
  end
  wire         pmw = sv[PLAT] && tl.em || bmw;
  wire  [12:0] pmw_a = sv[PLAT] && tl.em ? tl.ba : p_rb;
  wire  [7:0]  pmw_d = sv[PLAT] && tl.em ? pk[7:0] : bmw_d;

  // ---------------- memories ----------------
  assign h_rd = mem[h_ra];
  assign p_rd_a = mem[p_ra];
  assign p_rd_b = mem[p_rb];
  wire        mw = h_wr || pmw;
  wire [12:0] mw_a = h_wr ? {h_oa, 5'd0} + 13'(kout) : pmw_a;
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
    if (pw0) pm[pw0_a] <= pw0_d;
    if (pw1) pm[pw1_a] <= pw1_d;
  end
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) hptr <= '0;
    else if (hp_load) hptr <= hp_addr;
    else if (hw_valid && hw_ready || hr_valid && hr_ready) hptr <= hptr + 11'd1;
  end
endmodule
