// SPDX-License-Identifier: Apache-2.0
// ============================================================================
// HDCP 2.3 Content Protection Open IP -- HDCP 2.3 transmitter (educational slice)
// Full authentication FSM: AKE_Init -> rtx/rxcaps exchange -> master key km
// -> session key derivation -> pairing -> locality check (20 clk challenge)
// -> session key exchange -> repeater-ready (if peer REPEATER bit) ->
// authenticated streaming cipher on the pixel interface.
// IP design implementation v1.1 -- Apache-2.0
// ----------------------------------------------------------------------------
// Crypto is now REAL AES-128 (FIPS-197): the encrypt datapath below
// (SubBytes/ShiftRows/MixColumns/AddRoundKey + key expansion) is copied from
// the FIPS-197-vector-verified CSE_top.sv core. It is packaged here as a
// single-clock combinational function (aes128_enc) -- an educational-slice
// choice; a production core would iterate 1 round/clk like CSE.
//
// Real-AES usage in this slice:
//  - Session key derivation: ks = AES-128-ECB(key=km, pt={rtx,rtx}).  The
//    real HDCP KDF is AES-128 based; this slice uses a single ECB block.
//  - Pairing "encrypted master key": E_km = AES-128-ECB(key=hrx_pad, pt=km),
//    replacing the old XOR placeholder (real HDCP uses RSA-OAEP).
//  - Pairing ack H' = AES-128-ECB(key=km, pt=hrx_pad)[31:0].
//  - Content encryption: AES-128-CTR. Per 32-bit pixel word the keystream is
//    AES-128(key=ks, counter={frame_ctr, blk_ctr})[127:96], XORed with the
//    pixel word. blk_ctr advances per pixel word, frame_ctr per session.
//
// Documented residual simplifications (still NOT production-grade):
//  - Locality check response is L XOR ks[63:0]; the real protocol uses
//    HMAC-SHA256 over (L, receiver id) with the session key. The 20-clock
//    response window models the real locality timer.
//  - SKE carries Eks = ks XOR km (a mask), not the real AES-wrapped Eks.
//  - The DDC/I2C transport of real HDCP is replaced by parallel
//    valid/ready message channels (txm_*/rx_*).
//  - Certificate exchange is collapsed to a single AKE_Send_Cert message
//    carrying rxcaps (REPEATER bit) and a 32-bit rx pubkey-hash placeholder
//    (replicated to a 128-bit AES key for the pairing wrap).
//  - rtx / locality nonces come from a free-running xorshift64, not a TRNG.
// ============================================================================
module HDCP_2_3_Content_Protection_top #(
  parameter int DW = 32,          // pixel data width (CTR keystream word)
  parameter int AW = 32           // address width (reserved, framework contract)
)(
  input  logic         clk,
  input  logic         rst_n,

  // ---------------- register window (8 x 8-bit) ----------------
  input  logic         reg_we,     // write strobe
  input  logic [2:0]   reg_addr,
  input  logic [7:0]   reg_wdata,
  output logic [7:0]   reg_rdata,

  // ---------------- transmitter -> receiver message channel ----
  output logic         txm_valid,
  input  logic         txm_ready,
  output logic [3:0]   txm_type,
  output logic [127:0] txm_data,

  // ---------------- receiver -> transmitter message channel ----
  input  logic         rxm_valid,
  output logic         rxm_ready,
  input  logic [3:0]   rxm_type,
  input  logic [127:0] rxm_data,

  // ---------------- pixel stream (clear in / encrypted out) ----
  input  logic         pix_valid,
  output logic         pix_ready,
  input  logic [DW-1:0] pix_data,
  output logic         enc_valid,
  input  logic         enc_ready,
  output logic [DW-1:0] enc_data,

  output logic         irq         // locality timeout / pairing failure
);

  // ------------------------- constants -------------------------
  // message types (educational names mirror HDCP 2.3 AKE/LC/SKE messages)
  localparam logic [3:0] MT_AKE_INIT = 4'd1;  // TX->RX: rtx
  localparam logic [3:0] MT_AKE_CERT = 4'd2;  // RX->TX: rxcaps + rx pk-hash
  localparam logic [3:0] MT_AKE_EKM  = 4'd3;  // TX->RX: AES-wrapped km
  localparam logic [3:0] MT_PAIR_ACK = 4'd4;  // RX->TX: pairing H' ack
  localparam logic [3:0] MT_LC_INIT  = 4'd5;  // TX->RX: locality challenge L
  localparam logic [3:0] MT_LC_RESP  = 4'd6;  // RX->TX: locality response L'
  localparam logic [3:0] MT_SKE      = 4'd7;  // TX->RX: masked session key
  localparam logic [3:0] MT_RPT_ACK  = 4'd8;  // RX->TX: repeater ready (RxInfo)

  localparam logic [4:0] LC_TIMEOUT  = 5'd20; // locality response window
  localparam logic [7:0] HDCP2_VER   = 8'h23; // hdcp2version register

  // register map
  localparam logic [2:0] REG_CTRL   = 3'd0;   // WO: bit0 start, bit2 irq_clr
  localparam logic [2:0] REG_STATUS = 3'd1;   // RO
  localparam logic [2:0] REG_VER    = 3'd2;   // RO: 0x23
  localparam logic [2:0] REG_ERR    = 3'd3;   // RO: error flags
  localparam logic [2:0] REG_KMIDX  = 3'd4;   // RW: km/ks byte index 0..15
  localparam logic [2:0] REG_KMDAT  = 3'd5;   // RW: km byte at KMIDX
  localparam logic [2:0] REG_STATE  = 3'd6;   // RO: FSM state
  localparam logic [2:0] REG_KSDAT  = 3'd7;   // RO: session-key byte at KMIDX

  // ====================================================================
  // AES-128 (FIPS-197) encrypt datapath -- copied from CSE_top.sv
  // (verified there against FIPS-197 known-answer vectors).  Encryption
  // only: this slice never decrypts.  Byte i of a 128-bit word is
  // s[127-8i -: 8], matching the FIPS-197 mapping state[r][c] = in[4c+r].
  // ====================================================================
  function automatic logic [7:0] sbox(input logic [7:0] x);
    case (x)
      8'h00: sbox=8'h63; 8'h01: sbox=8'h7c; 8'h02: sbox=8'h77; 8'h03: sbox=8'h7b;
      8'h04: sbox=8'hf2; 8'h05: sbox=8'h6b; 8'h06: sbox=8'h6f; 8'h07: sbox=8'hc5;
      8'h08: sbox=8'h30; 8'h09: sbox=8'h01; 8'h0a: sbox=8'h67; 8'h0b: sbox=8'h2b;
      8'h0c: sbox=8'hfe; 8'h0d: sbox=8'hd7; 8'h0e: sbox=8'hab; 8'h0f: sbox=8'h76;
      8'h10: sbox=8'hca; 8'h11: sbox=8'h82; 8'h12: sbox=8'hc9; 8'h13: sbox=8'h7d;
      8'h14: sbox=8'hfa; 8'h15: sbox=8'h59; 8'h16: sbox=8'h47; 8'h17: sbox=8'hf0;
      8'h18: sbox=8'had; 8'h19: sbox=8'hd4; 8'h1a: sbox=8'ha2; 8'h1b: sbox=8'haf;
      8'h1c: sbox=8'h9c; 8'h1d: sbox=8'ha4; 8'h1e: sbox=8'h72; 8'h1f: sbox=8'hc0;
      8'h20: sbox=8'hb7; 8'h21: sbox=8'hfd; 8'h22: sbox=8'h93; 8'h23: sbox=8'h26;
      8'h24: sbox=8'h36; 8'h25: sbox=8'h3f; 8'h26: sbox=8'hf7; 8'h27: sbox=8'hcc;
      8'h28: sbox=8'h34; 8'h29: sbox=8'ha5; 8'h2a: sbox=8'he5; 8'h2b: sbox=8'hf1;
      8'h2c: sbox=8'h71; 8'h2d: sbox=8'hd8; 8'h2e: sbox=8'h31; 8'h2f: sbox=8'h15;
      8'h30: sbox=8'h04; 8'h31: sbox=8'hc7; 8'h32: sbox=8'h23; 8'h33: sbox=8'hc3;
      8'h34: sbox=8'h18; 8'h35: sbox=8'h96; 8'h36: sbox=8'h05; 8'h37: sbox=8'h9a;
      8'h38: sbox=8'h07; 8'h39: sbox=8'h12; 8'h3a: sbox=8'h80; 8'h3b: sbox=8'he2;
      8'h3c: sbox=8'heb; 8'h3d: sbox=8'h27; 8'h3e: sbox=8'hb2; 8'h3f: sbox=8'h75;
      8'h40: sbox=8'h09; 8'h41: sbox=8'h83; 8'h42: sbox=8'h2c; 8'h43: sbox=8'h1a;
      8'h44: sbox=8'h1b; 8'h45: sbox=8'h6e; 8'h46: sbox=8'h5a; 8'h47: sbox=8'ha0;
      8'h48: sbox=8'h52; 8'h49: sbox=8'h3b; 8'h4a: sbox=8'hd6; 8'h4b: sbox=8'hb3;
      8'h4c: sbox=8'h29; 8'h4d: sbox=8'he3; 8'h4e: sbox=8'h2f; 8'h4f: sbox=8'h84;
      8'h50: sbox=8'h53; 8'h51: sbox=8'hd1; 8'h52: sbox=8'h00; 8'h53: sbox=8'hed;
      8'h54: sbox=8'h20; 8'h55: sbox=8'hfc; 8'h56: sbox=8'hb1; 8'h57: sbox=8'h5b;
      8'h58: sbox=8'h6a; 8'h59: sbox=8'hcb; 8'h5a: sbox=8'hbe; 8'h5b: sbox=8'h39;
      8'h5c: sbox=8'h4a; 8'h5d: sbox=8'h4c; 8'h5e: sbox=8'h58; 8'h5f: sbox=8'hcf;
      8'h60: sbox=8'hd0; 8'h61: sbox=8'hef; 8'h62: sbox=8'haa; 8'h63: sbox=8'hfb;
      8'h64: sbox=8'h43; 8'h65: sbox=8'h4d; 8'h66: sbox=8'h33; 8'h67: sbox=8'h85;
      8'h68: sbox=8'h45; 8'h69: sbox=8'hf9; 8'h6a: sbox=8'h02; 8'h6b: sbox=8'h7f;
      8'h6c: sbox=8'h50; 8'h6d: sbox=8'h3c; 8'h6e: sbox=8'h9f; 8'h6f: sbox=8'ha8;
      8'h70: sbox=8'h51; 8'h71: sbox=8'ha3; 8'h72: sbox=8'h40; 8'h73: sbox=8'h8f;
      8'h74: sbox=8'h92; 8'h75: sbox=8'h9d; 8'h76: sbox=8'h38; 8'h77: sbox=8'hf5;
      8'h78: sbox=8'hbc; 8'h79: sbox=8'hb6; 8'h7a: sbox=8'hda; 8'h7b: sbox=8'h21;
      8'h7c: sbox=8'h10; 8'h7d: sbox=8'hff; 8'h7e: sbox=8'hf3; 8'h7f: sbox=8'hd2;
      8'h80: sbox=8'hcd; 8'h81: sbox=8'h0c; 8'h82: sbox=8'h13; 8'h83: sbox=8'hec;
      8'h84: sbox=8'h5f; 8'h85: sbox=8'h97; 8'h86: sbox=8'h44; 8'h87: sbox=8'h17;
      8'h88: sbox=8'hc4; 8'h89: sbox=8'ha7; 8'h8a: sbox=8'h7e; 8'h8b: sbox=8'h3d;
      8'h8c: sbox=8'h64; 8'h8d: sbox=8'h5d; 8'h8e: sbox=8'h19; 8'h8f: sbox=8'h73;
      8'h90: sbox=8'h60; 8'h91: sbox=8'h81; 8'h92: sbox=8'h4f; 8'h93: sbox=8'hdc;
      8'h94: sbox=8'h22; 8'h95: sbox=8'h2a; 8'h96: sbox=8'h90; 8'h97: sbox=8'h88;
      8'h98: sbox=8'h46; 8'h99: sbox=8'hee; 8'h9a: sbox=8'hb8; 8'h9b: sbox=8'h14;
      8'h9c: sbox=8'hde; 8'h9d: sbox=8'h5e; 8'h9e: sbox=8'h0b; 8'h9f: sbox=8'hdb;
      8'ha0: sbox=8'he0; 8'ha1: sbox=8'h32; 8'ha2: sbox=8'h3a; 8'ha3: sbox=8'h0a;
      8'ha4: sbox=8'h49; 8'ha5: sbox=8'h06; 8'ha6: sbox=8'h24; 8'ha7: sbox=8'h5c;
      8'ha8: sbox=8'hc2; 8'ha9: sbox=8'hd3; 8'haa: sbox=8'hac; 8'hab: sbox=8'h62;
      8'hac: sbox=8'h91; 8'had: sbox=8'h95; 8'hae: sbox=8'he4; 8'haf: sbox=8'h79;
      8'hb0: sbox=8'he7; 8'hb1: sbox=8'hc8; 8'hb2: sbox=8'h37; 8'hb3: sbox=8'h6d;
      8'hb4: sbox=8'h8d; 8'hb5: sbox=8'hd5; 8'hb6: sbox=8'h4e; 8'hb7: sbox=8'ha9;
      8'hb8: sbox=8'h6c; 8'hb9: sbox=8'h56; 8'hba: sbox=8'hf4; 8'hbb: sbox=8'hea;
      8'hbc: sbox=8'h65; 8'hbd: sbox=8'h7a; 8'hbe: sbox=8'hae; 8'hbf: sbox=8'h08;
      8'hc0: sbox=8'hba; 8'hc1: sbox=8'h78; 8'hc2: sbox=8'h25; 8'hc3: sbox=8'h2e;
      8'hc4: sbox=8'h1c; 8'hc5: sbox=8'ha6; 8'hc6: sbox=8'hb4; 8'hc7: sbox=8'hc6;
      8'hc8: sbox=8'he8; 8'hc9: sbox=8'hdd; 8'hca: sbox=8'h74; 8'hcb: sbox=8'h1f;
      8'hcc: sbox=8'h4b; 8'hcd: sbox=8'hbd; 8'hce: sbox=8'h8b; 8'hcf: sbox=8'h8a;
      8'hd0: sbox=8'h70; 8'hd1: sbox=8'h3e; 8'hd2: sbox=8'hb5; 8'hd3: sbox=8'h66;
      8'hd4: sbox=8'h48; 8'hd5: sbox=8'h03; 8'hd6: sbox=8'hf6; 8'hd7: sbox=8'h0e;
      8'hd8: sbox=8'h61; 8'hd9: sbox=8'h35; 8'hda: sbox=8'h57; 8'hdb: sbox=8'hb9;
      8'hdc: sbox=8'h86; 8'hdd: sbox=8'hc1; 8'hde: sbox=8'h1d; 8'hdf: sbox=8'h9e;
      8'he0: sbox=8'he1; 8'he1: sbox=8'hf8; 8'he2: sbox=8'h98; 8'he3: sbox=8'h11;
      8'he4: sbox=8'h69; 8'he5: sbox=8'hd9; 8'he6: sbox=8'h8e; 8'he7: sbox=8'h94;
      8'he8: sbox=8'h9b; 8'he9: sbox=8'h1e; 8'hea: sbox=8'h87; 8'heb: sbox=8'he9;
      8'hec: sbox=8'hce; 8'hed: sbox=8'h55; 8'hee: sbox=8'h28; 8'hef: sbox=8'hdf;
      8'hf0: sbox=8'h8c; 8'hf1: sbox=8'ha1; 8'hf2: sbox=8'h89; 8'hf3: sbox=8'h0d;
      8'hf4: sbox=8'hbf; 8'hf5: sbox=8'he6; 8'hf6: sbox=8'h42; 8'hf7: sbox=8'h68;
      8'hf8: sbox=8'h41; 8'hf9: sbox=8'h99; 8'hfa: sbox=8'h2d; 8'hfb: sbox=8'h0f;
      8'hfc: sbox=8'hb0; 8'hfd: sbox=8'h54; 8'hfe: sbox=8'hbb; 8'hff: sbox=8'h16;
    endcase
  endfunction

  // GF(2^8) helpers for MixColumns
  function automatic logic [7:0] xtime(input logic [7:0] a);
    xtime = {a[6:0], 1'b0} ^ (a[7] ? 8'h1b : 8'h00);
  endfunction
  function automatic logic [7:0] mul2(input logic [7:0] a); mul2 = xtime(a); endfunction
  function automatic logic [7:0] mul3(input logic [7:0] a); mul3 = xtime(a) ^ a; endfunction

  // round primitives on the 128-bit state
  function automatic logic [127:0] sub_bytes(input logic [127:0] s);
    for (int i = 0; i < 16; i++) sub_bytes[127-8*i -: 8] = sbox(s[127-8*i -: 8]);
  endfunction

  function automatic logic [127:0] shift_rows(input logic [127:0] s);
    logic [7:0] b [0:15];
    begin
      for (int i = 0; i < 16; i++) b[i] = s[127-8*i -: 8];
      shift_rows = {b[0], b[5], b[10], b[15], b[4], b[9], b[14], b[3],
                    b[8], b[13], b[2], b[7], b[12], b[1], b[6], b[11]};
    end
  endfunction

  function automatic logic [31:0] mix_col(input logic [31:0] c);
    logic [7:0] b0, b1, b2, b3;
    begin
      b0 = c[31:24]; b1 = c[23:16]; b2 = c[15:8]; b3 = c[7:0];
      mix_col = {mul2(b0) ^ mul3(b1) ^ b2 ^ b3,
                 b0 ^ mul2(b1) ^ mul3(b2) ^ b3,
                 b0 ^ b1 ^ mul2(b2) ^ mul3(b3),
                 mul3(b0) ^ b1 ^ b2 ^ mul2(b3)};
    end
  endfunction
  function automatic logic [127:0] mix_columns(input logic [127:0] s);
    mix_columns = {mix_col(s[127:96]), mix_col(s[95:64]),
                   mix_col(s[63:32]), mix_col(s[31:0])};
  endfunction

  // key expansion (FIPS-197 5.2, AES-128: 11 round keys)
  function automatic logic [7:0] rcon(input logic [3:0] r);
    case (r)
      4'd1: rcon = 8'h01; 4'd2: rcon = 8'h02; 4'd3: rcon = 8'h04;
      4'd4: rcon = 8'h08; 4'd5: rcon = 8'h10; 4'd6: rcon = 8'h20;
      4'd7: rcon = 8'h40; 4'd8: rcon = 8'h80; 4'd9: rcon = 8'h1b;
      default: rcon = 8'h36;
    endcase
  endfunction

  function automatic logic [127:0] key_next(input logic [127:0] k,
                                            input logic [3:0] r);
    logic [31:0] w0, w1, w2, w3, t;
    begin
      w0 = k[127:96]; w1 = k[95:64]; w2 = k[63:32]; w3 = k[31:0];
      t  = {sbox(w3[23:16]), sbox(w3[15:8]), sbox(w3[7:0]), sbox(w3[31:24])}
           ^ {rcon(r), 24'h0};
      w0 = w0 ^ t;
      w1 = w1 ^ w0;
      w2 = w2 ^ w1;
      w3 = w3 ^ w2;
      key_next = {w0, w1, w2, w3};
    end
  endfunction

  // Full AES-128 encrypt, single clock (combinational unroll of the 10
  // rounds -- educational-slice packaging; CSE_top iterates 1 round/clk).
  function automatic logic [127:0] aes128_enc(input logic [127:0] key,
                                              input logic [127:0] pt);
    logic [127:0] rk, s;
    begin
      rk = key;
      s  = pt ^ rk;                       // pre-whitening AddRoundKey
      for (int r = 1; r <= 9; r++) begin  // rounds 1..9
        rk = key_next(rk, r[3:0]);
        s  = mix_columns(shift_rows(sub_bytes(s))) ^ rk;
      end
      rk = key_next(rk, 4'd10);           // final round (no MixColumns)
      aes128_enc = shift_rows(sub_bytes(s)) ^ rk;
    end
  endfunction

  // free-running 64-bit nonce generator (xorshift64 -- nonce source only,
  // not a cipher; real silicon would use a TRNG)
  function automatic logic [63:0] xs64(input logic [63:0] s);
    logic [63:0] x;
    begin
      x = s;
      x = x ^ (x >> 12);
      x = x ^ (x << 25);
      x = x ^ (x >> 27);
      xs64 = x;
    end
  endfunction

  // ------------------------- FSM -------------------------------
  typedef enum logic [3:0] {
    ST_IDLE,      // waiting for CTRL.start
    ST_AKE_INIT,  // send AKE_Init(rtx)
    ST_AKE_CERT,  // wait AKE_Send_Cert(rxcaps, hrx)
    ST_PAIR_TX,   // send AKE_Stored_km-style E_km
    ST_PAIR_RX,   // wait + verify pairing ack H'
    ST_LC_TX,     // send LC_Init(L)
    ST_LC_WAIT,   // wait LC_Send_L_prime within 20 clk
    ST_SKE_TX,    // send SKE_Send_Eks
    ST_RPT_WAIT,  // repeater only: wait repeater-ready ack
    ST_AUTH       // authenticated; stream cipher active
  } state_t;
  state_t state;

  // ------------------------- datapath regs ---------------------
  logic [127:0] km;             // master key (register-window configurable)
  logic [3:0]   km_idx;
  logic [63:0]  rng;            // free-running xorshift64 (rtx / L source)
  logic [63:0]  rtx;            // transmitter nonce sent in AKE_Init
  logic [63:0]  rxcaps;         // receiver capabilities (bit0 = REPEATER)
  logic [31:0]  hrx;            // receiver pubkey-hash placeholder
  logic [127:0] ks;             // derived session key: AES-128-ECB(km, rtx)
  logic [63:0]  lc_r_n;         // locality challenge L
  logic [4:0]   lc_cnt;         // locality response countdown
  logic [63:0]  frame_ctr;      // AES-CTR frame counter (per session)
  logic [63:0]  blk_ctr;        // AES-CTR block counter (per pixel word)
  logic         fail;           // sticky authentication-failed flag
  logic [2:0]   err_flags;      // bit0 locality timeout, bit1 pairing fail,
                                // bit2 locality value mismatch

  // ------------------------- AES-based derivations -------------
  wire [127:0] hrx_pad  = {hrx, hrx, hrx, hrx};   // pubkey-hash pad to 128b
  wire         rpt_peer = rxcaps[0];              // REPEATER bit

  // One shared combinational AES-128 encrypt instance, muxed by FSM state
  // (the four uses never overlap in time):
  //   AKE_CERT: session-key KDF    ks = AES-128-ECB(km, {rtx,rtx})
  //   PAIR_TX : pairing wrap       E_km = AES-128-ECB(hrx_pad, km)
  //   PAIR_RX : pairing ack        H' = AES-128-ECB(km, hrx_pad)[31:0]
  //   AUTH    : AES-128-CTR stream AES-128(ks, {frame_ctr, blk_ctr})[127:96]
  wire [127:0] aes_key = (state == ST_PAIR_TX) ? hrx_pad :
                         (state == ST_AUTH)    ? ks      : km;
  wire [127:0] aes_pt  = (state == ST_PAIR_TX) ? km                  :
                         (state == ST_PAIR_RX) ? hrx_pad             :
                         (state == ST_AUTH)    ? {frame_ctr, blk_ctr}
                                               : {rtx, rtx};
  wire [127:0] aes_out = aes128_enc(aes_key, aes_pt);

  wire [127:0] ks_next  = aes_out;              // consumed in ST_AKE_CERT
  wire [127:0] ekm      = aes_out;              // consumed in ST_PAIR_TX
  wire [31:0]  ack_exp  = aes_out[31:0];        // consumed in ST_PAIR_RX
  wire [31:0]  ks_word  = aes_out[127:96];      // consumed in ST_AUTH

  // ------------------------- sequential ------------------------
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      state     <= ST_IDLE;
      km        <= 128'h0;
      km_idx    <= 4'h0;
      rng       <= 64'h9E37_79B9_7F4A_7C15; // golden-ratio seed (nonzero)
      rtx       <= 64'h0;
      rxcaps    <= 64'h0;
      hrx       <= 32'h0;
      ks        <= 128'h0;
      lc_r_n    <= 64'h0;
      lc_cnt    <= 5'h0;
      frame_ctr <= 64'h0;
      blk_ctr   <= 64'h0;
      fail      <= 1'b0;
      err_flags <= 3'b000;
      enc_valid <= 1'b0;
      enc_data  <= '0;
    end else begin
      rng <= xs64(rng);          // free-running nonce source

      // -------- register window writes (any state) --------
      if (reg_we) begin
        case (reg_addr)
          REG_KMIDX: km_idx <= reg_wdata[3:0];
          REG_KMDAT: km[km_idx*8 +: 8] <= reg_wdata;
          REG_CTRL: begin
            if (reg_wdata[2]) begin      // irq / error clear
              err_flags <= 3'b000;
              fail      <= 1'b0;
            end
            if (reg_wdata[0] && (state == ST_IDLE || state == ST_AUTH)) begin
              err_flags <= 3'b000;       // new session clears status
              fail      <= 1'b0;
              state     <= ST_AKE_INIT;
              rtx       <= xs64(rng);    // fresh rtx nonce
            end
          end
          default: ;
        endcase
      end

      // -------- authentication FSM --------
      case (state)
        ST_IDLE: ; // start handled by CTRL write above

        ST_AKE_INIT: if (txm_ready) state <= ST_AKE_CERT;

        ST_AKE_CERT:
          if (rxm_valid && rxm_type == MT_AKE_CERT) begin
            rxcaps <= rxm_data[63:0];
            hrx    <= rxm_data[95:64];
            // derive session key: ks = AES-128-ECB(key=km, pt={rtx,rtx})
            ks     <= ks_next;
            state  <= ST_PAIR_TX;
          end

        ST_PAIR_TX: if (txm_ready) state <= ST_PAIR_RX;

        ST_PAIR_RX:
          if (rxm_valid && rxm_type == MT_PAIR_ACK) begin
            if (rxm_data[31:0] == ack_exp) begin
              state  <= ST_LC_TX;
              lc_r_n <= xs64(rng);       // fresh locality challenge
            end else begin
              err_flags[1] <= 1'b1;      // pairing failure
              fail         <= 1'b1;
              state        <= ST_IDLE;
            end
          end

        ST_LC_TX: if (txm_ready) begin
          state  <= ST_LC_WAIT;
          lc_cnt <= LC_TIMEOUT;          // start 20-clk locality window
        end

        ST_LC_WAIT: begin
          if (rxm_valid && rxm_type == MT_LC_RESP) begin
            if (rxm_data[63:0] == (lc_r_n ^ ks[63:0]))
              state <= ST_SKE_TX;
            else begin
              err_flags[2] <= 1'b1;      // locality value mismatch
              fail         <= 1'b1;
              state        <= ST_IDLE;
            end
          end else if (lc_cnt == 5'd0) begin
            err_flags[0] <= 1'b1;        // locality timeout
            fail         <= 1'b1;
            state        <= ST_IDLE;
          end else
            lc_cnt <= lc_cnt - 5'd1;
        end

        ST_SKE_TX: if (txm_ready)
          state <= rpt_peer ? ST_RPT_WAIT : ST_AUTH;

        ST_RPT_WAIT:
          if (rxm_valid && rxm_type == MT_RPT_ACK) state <= ST_AUTH;

        ST_AUTH: ; // streaming; session ends via CTRL.start (new session)

        default: state <= ST_IDLE;
      endcase

      // -------- AES-128-CTR stream cipher pipeline --------
      // (re)initialise the CTR counters when authentication completes
      if ((state == ST_SKE_TX && txm_ready && !rpt_peer) ||
          (state == ST_RPT_WAIT && rxm_valid && rxm_type == MT_RPT_ACK)) begin
        frame_ctr <= frame_ctr + 64'd1;  // new session -> new frame number
        blk_ctr   <= 64'h0;
      end

      if (state == ST_AUTH) begin
        if (pix_valid && pix_ready) begin
          enc_data  <= pix_data ^ ks_word;  // AES-CTR: XOR keystream word
          enc_valid <= 1'b1;
          blk_ctr   <= blk_ctr + 64'd1;     // advance CTR per pixel word
        end else if (enc_valid && enc_ready)
          enc_valid <= 1'b0;
      end else begin
        enc_valid <= 1'b0;
      end
    end
  end

  // ------------------------- outputs ---------------------------
  always_comb begin
    // message channel: TX->RX
    txm_valid = (state == ST_AKE_INIT) || (state == ST_PAIR_TX) ||
                (state == ST_LC_TX)    || (state == ST_SKE_TX);
    txm_type  = (state == ST_AKE_INIT) ? MT_AKE_INIT :
                (state == ST_PAIR_TX)  ? MT_AKE_EKM  :
                (state == ST_LC_TX)    ? MT_LC_INIT  : MT_SKE;
    txm_data  = (state == ST_AKE_INIT) ? {64'h0, rtx}  :
                (state == ST_PAIR_TX)  ? ekm           :
                (state == ST_LC_TX)    ? {64'h0, lc_r_n} : (ks ^ km);
    // message channel: RX->TX
    rxm_ready = (state == ST_AKE_CERT) || (state == ST_PAIR_RX) ||
                (state == ST_LC_WAIT)  || (state == ST_RPT_WAIT);
    // pixel stream
    pix_ready = (state == ST_AUTH) && (!enc_valid || enc_ready);
    // interrupt: locality timeout / pairing failure / locality mismatch
    irq = (err_flags != 3'b000);

    // register window read
    case (reg_addr)
      REG_CTRL:   reg_rdata = 8'h00;            // write-only action reg
      REG_STATUS: reg_rdata = {3'b000, rpt_peer, fail,
                               (state == ST_AUTH),   // bit2 enc_active
                               (state == ST_AUTH),   // bit1 authenticated
                               (state != ST_IDLE)};  // bit0 busy
      REG_VER:    reg_rdata = HDCP2_VER;
      REG_ERR:    reg_rdata = {5'b00000, err_flags};
      REG_KMIDX:  reg_rdata = {4'h0, km_idx};
      REG_KMDAT:  reg_rdata = km[km_idx*8 +: 8];
      REG_STATE:  reg_rdata = {4'h0, state};
      REG_KSDAT:  reg_rdata = ks[km_idx*8 +: 8];
      default:    reg_rdata = 8'h00;
    endcase
  end

endmodule
