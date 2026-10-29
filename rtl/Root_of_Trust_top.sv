// SPDX-License-Identifier: Apache-2.0
// ============================================================================
// Root_of_Trust_top v1.0: hardware root of trust for an SoC. It owns the
// device lifecycle, verifies the first boot image before the application CPU
// may run, and derives the device key that the image is bound to.
// ----------------------------------------------------------------------------
//  - OTP: 64 words of 32 bits in a one-time-programmable macro outside the
//    core (programming can only set bits). Map:
//      0-7   UDS, the unique device secret (never readable by software)
//      8-15  boot image digest (SHA-256)          16-23 SHA-256 of the test-exit token
//      24-31 SHA-256 of the RMA token             32    lifecycle word
//      33    scrap word                           34    anti-rollback (thermometer)
//      35-63 spare
//    Secrets are read from the OTP when they are used and are not kept in
//    the core: the UDS only passes through the hash block register while the
//    key is derived, and that register is cleared afterwards.
//  - Lifecycle: RAW, TEST (unlocked), DEV, PROD, RMA, SCRAP. The lifecycle
//    word is a union of four 8-bit groups (RAW 0, TEST A, DEV A|B, PROD A|C,
//    RMA A|B|C|D), so every legal transition only sets bits; any other value
//    (a partly set group, a group set out of order) decodes as INVALID. A set
//    scrap word is SCRAP whatever the lifecycle word says; a partly set one
//    is INVALID. Transitions: RAW -> TEST (a token whose SHA-256 is fixed in
//    the netlist), TEST -> DEV or PROD (the test-exit token), DEV or PROD ->
//    RMA (the RMA token), and any state -> SCRAP (no token). The token is
//    hashed and compared with the stored hash; the new word is programmed
//    and read back, and takes effect at the next reset. Three wrong tokens
//    lock the command port until reset.
//  - Secure boot: in DEV and PROD the first boot image is streamed in as
//    32-bit words (first word: the image version), hashed with SHA-256 and
//    compared with the OTP digest; its version must be at least the number
//    of anti-rollback bits set. Only then is cpu_en raised. TEST and RMA
//    boot without verification; RAW, SCRAP and INVALID do not boot.
//  - Key derivation: after a verified boot, key_out = HMAC-SHA256(UDS,
//    image digest || lifecycle word), a DICE-style compound device
//    identifier, valid on a sideload port for a crypto engine; it is not
//    readable through the command port. TEST and RMA give no key.
//  - Debug: dbg_en in TEST, DEV and RMA only.
//  - Escalation: esc (from a tamper sensor or an alert handler) clears the
//    key, cpu_en and dbg_en and stops the core until reset.
//  - Commands (one at a time, cmd_busy while running): 0 read an OTP word
//    (not the UDS), 1 program an OTP word (the region must be open in the
//    current state), 2 lifecycle transition to cmd_data[2:0] with token.
//  - Alerts: alert pulses with alert_code: 1 invalid lifecycle, 2 boot image
//    rejected, 3 wrong token, 4 access refused (UDS read, region closed),
//    5 OTP program did not read back, 6 escalation, 7 state register fault.
// ============================================================================
module Root_of_Trust_top #(
  parameter int IMG_AW = 14             // image length counter: up to 2^IMG_AW - 1 words
) (
  input  logic         clk,
  input  logic         rst_n,
  // OTP macro: a request is held until ack; a program sets the bits of wdata
  output logic         otp_req,
  output logic         otp_we,
  output logic [5:0]   otp_addr,
  output logic [31:0]  otp_wdata,
  input  logic         otp_ack,
  input  logic [31:0]  otp_rdata,
  // commands
  input  logic         cmd_start,
  input  logic [1:0]   cmd_op,
  input  logic [5:0]   cmd_addr,
  input  logic [31:0]  cmd_data,
  input  logic [127:0] token,
  output logic         cmd_busy,
  output logic         cmd_done,
  output logic         cmd_err,
  output logic [31:0]  cmd_rdata,
  // boot image
  input  logic         img_valid,
  input  logic [31:0]  img_data,
  input  logic         img_last,
  output logic         img_ready,
  // state
  output logic         init_done,
  output logic [2:0]   lc_state,
  output logic         boot_done,
  output logic         boot_ok,
  output logic         cpu_en,
  output logic         dbg_en,
  output logic         key_valid,
  output logic [255:0] key_out,
  output logic         alert,
  output logic [2:0]   alert_code,
  input  logic         esc
);
  // lifecycle states as reported on lc_state
  localparam logic [2:0] S_RAW = 3'd0, S_TEST = 3'd1, S_DEV = 3'd2, S_PROD = 3'd3, S_RMA = 3'd4,
                         S_SCRAP = 3'd5, S_INVALID = 3'd6, S_ESC = 3'd7;
  localparam logic [31:0] LC_A = 32'h0000_00FF, LC_B = 32'h0000_FF00, LC_C = 32'h00FF_0000, LC_D = 32'hFF00_0000;
  function automatic logic [31:0] lc_word(input logic [2:0] s);
    case (s)
      S_TEST: lc_word = LC_A;
      S_DEV: lc_word = LC_A | LC_B;
      S_PROD: lc_word = LC_A | LC_C;
      S_RMA: lc_word = LC_A | LC_B | LC_C | LC_D;
      default: lc_word = '0;
    endcase
  endfunction
  // OTP word addresses
  localparam logic [5:0] O_DIG = 6'd8, O_TTOK = 6'd16, O_RTOK = 6'd24, O_LC = 6'd32, O_SCRAP = 6'd33, O_ARB = 6'd34;
  // SHA-256 of the RAW unlock token ("RAW_UNLOCK_TOKEN")
  localparam logic [255:0] RAW_TOK_HASH = 256'he44f810d65513c0d4f08ccba93fb0f2c4144a6d78d58c871ecdd0edba4c1593e;
  localparam logic [1:0] C_READ = 2'd0, C_PROG = 2'd1, C_TRANS = 2'd2;
  localparam logic [2:0] A_LC = 3'd1, A_BOOT = 3'd2, A_TOKEN = 3'd3, A_ACCESS = 3'd4, A_OTP = 3'd5, A_ESC = 3'd6,
                         A_FAULT = 3'd7;

  // ---------------- SHA-256 ----------------
  localparam logic [32*64-1:0] KT = {
    32'hc67178f2, 32'hbef9a3f7, 32'ha4506ceb, 32'h90befffa,
    32'h8cc70208, 32'h84c87814, 32'h78a5636f, 32'h748f82ee,
    32'h682e6ff3, 32'h5b9cca4f, 32'h4ed8aa4a, 32'h391c0cb3,
    32'h34b0bcb5, 32'h2748774c, 32'h1e376c08, 32'h19a4c116,
    32'h106aa070, 32'hf40e3585, 32'hd6990624, 32'hd192e819,
    32'hc76c51a3, 32'hc24b8b70, 32'ha81a664b, 32'ha2bfe8a1,
    32'h92722c85, 32'h81c2c92e, 32'h766a0abb, 32'h650a7354,
    32'h53380d13, 32'h4d2c6dfc, 32'h2e1b2138, 32'h27b70a85,
    32'h14292967, 32'h06ca6351, 32'hd5a79147, 32'hc6e00bf3,
    32'hbf597fc7, 32'hb00327c8, 32'ha831c66d, 32'h983e5152,
    32'h76f988da, 32'h5cb0a9dc, 32'h4a7484aa, 32'h2de92c6f,
    32'h240ca1cc, 32'h0fc19dc6, 32'hefbe4786, 32'he49b69c1,
    32'hc19bf174, 32'h9bdc06a7, 32'h80deb1fe, 32'h72be5d74,
    32'h550c7dc3, 32'h243185be, 32'h12835b01, 32'hd807aa98,
    32'hab1c5ed5, 32'h923f82a4, 32'h59f111f1, 32'h3956c25b,
    32'he9b5dba5, 32'hb5c0fbcf, 32'h71374491, 32'h428a2f98
  };
  localparam logic [255:0] IV = {32'h6a09e667, 32'hbb67ae85, 32'h3c6ef372, 32'ha54ff53a,
                                 32'h510e527f, 32'h9b05688c, 32'h1f83d9ab, 32'h5be0cd19};
  function automatic logic [31:0] ror(input logic [31:0] x, input int n);
    ror = (x >> n) | (x << (32 - n));
  endfunction
  // the message block, word 0 first (at the top); during a compression it is
  // the schedule window W[t .. t + 15]
  logic [511:0] blk;
  logic [255:0] hh;                     // chaining value, word 0 at the top
  logic [31:0]  sa, sb, sc, sd, se, sf, sg, sh;
  logic [6:0]   srnd;                   // round, 64 = idle
  logic         sha_go, sha_init;       // start a compression (from IV / from hh)
  logic         sha_done;               // the last round: the chaining value is added next
  wire          sha_run = srnd != 7'd64;
  wire          sha_busy = sha_run || sha_done;
  wire  [31:0]  w0 = blk[511:480];
  wire  [31:0]  s0 = ror(blk[479:448], 7) ^ ror(blk[479:448], 18) ^ (blk[479:448] >> 3);   // W[t + 1]
  wire  [31:0]  s1 = ror(blk[63:32], 17) ^ ror(blk[63:32], 19) ^ (blk[63:32] >> 10);        // W[t + 14]
  wire  [31:0]  wnew = s1 + blk[223:192] + s0 + w0;                                          // W[t + 16]
  wire  [31:0]  t1 = sh + (ror(se, 6) ^ ror(se, 11) ^ ror(se, 25)) + ((se & sf) ^ (~se & sg))
                     + KT[32 * srnd[5:0] +: 32] + w0;
  wire  [31:0]  t2 = (ror(sa, 2) ^ ror(sa, 13) ^ ror(sa, 22)) + ((sa & sb) ^ (sa & sc) ^ (sb & sc));

  // ---------------- control ----------------
  typedef enum logic [4:0] {
    M_INIT, M_IDLE, M_RD, M_PG, M_PV, M_TOKH, M_TOKC, M_TRPG, M_TRPV,
    M_IMG, M_IMGH, M_PAD, M_PADH, M_VER, M_KLD, M_KH, M_KMH, M_ESC
  } mst_t;
  mst_t         ms;
  logic [2:0]   lc;                     // decoded at init
  logic [31:0]  lcw;                    // the lifecycle word read at init
  logic [5:0]   arbn;                   // anti-rollback bits set
  logic [3:0]   idx;                    // word index: OTP reads, block fill
  logic [1:0]   tfail;                  // wrong tokens since reset
  logic         lc_pend;                // a transition was programmed: reset needed
  logic [2:0]   tgt;                    // transition target
  logic         tok_otp, tok_rma;       // expected token hash: in the OTP (else the netlist one); the RMA one
  logic [31:0]  pdat;                   // word being programmed
  logic         neq;                    // a compared word differed
  logic [IMG_AW-1:0] nw;                // image words
  logic         nw_ovf;
  logic [31:0]  ver;                    // image version (its first word)
  logic         padw;                   // the 0x80 padding word is still to come
  logic         sfirst;                 // no image block hashed yet
  logic         kouter;                 // key derivation: the outer hash
  logic [255:0] inner;
  wire          boot_dev = lc == S_DEV || lc == S_PROD;

  // permissions of the command port
  function automatic logic prog_ok(input logic [5:0] a, input logic [2:0] s);
    if (a < O_DIG || a >= O_TTOK && a < O_LC) prog_ok = s == S_TEST;                 // UDS, token hashes
    else if (a < O_TTOK) prog_ok = s == S_TEST || s == S_DEV;                         // boot digest
    else if (a == O_ARB) prog_ok = s == S_DEV || s == S_PROD;
    else if (a > O_ARB) prog_ok = s == S_TEST || s == S_DEV || s == S_PROD;           // spare
    else prog_ok = 1'b0;                                                              // lifecycle, scrap
  endfunction
  function automatic logic trans_ok(input logic [2:0] f, input logic [2:0] t);
    case (t)
      S_TEST: trans_ok = f == S_RAW;
      S_DEV, S_PROD: trans_ok = f == S_TEST;
      S_RMA: trans_ok = f == S_DEV || f == S_PROD;
      S_SCRAP: trans_ok = f != S_SCRAP;
      default: trans_ok = 1'b0;
    endcase
  endfunction
  // the expected token hash word idx: from the netlist or the OTP
  wire  [31:0]  thw = tok_otp ? otp_rdata : RAW_TOK_HASH[{3'd7 - idx[2:0], 5'd0} +: 32];
  wire  [31:0]  hw = hh[{3'd7 - idx[2:0], 5'd0} +: 32];

  // lifecycle decode
  function automatic logic [2:0] lc_dec(input logic [31:0] w, input logic [31:0] scr);
    if (scr == 32'hFFFF_FFFF) lc_dec = S_SCRAP;
    else if (scr != '0) lc_dec = S_INVALID;
    else if (w == lc_word(S_RAW)) lc_dec = S_RAW;
    else if (w == lc_word(S_TEST)) lc_dec = S_TEST;
    else if (w == lc_word(S_DEV)) lc_dec = S_DEV;
    else if (w == lc_word(S_PROD)) lc_dec = S_PROD;
    else if (w == lc_word(S_RMA)) lc_dec = S_RMA;
    else lc_dec = S_INVALID;
  endfunction
  function automatic logic [5:0] popc(input logic [31:0] w);
    popc = '0;
    for (int i = 0; i < 32; i++) popc = popc + 6'(w[i]);
  endfunction

  assign lc_state = ms == M_ESC ? S_ESC : lc;
  assign dbg_en = ms != M_ESC && init_done && (lc == S_TEST || lc == S_DEV || lc == S_RMA);
  assign cmd_busy = ms != M_IDLE;
  assign img_ready = ms == M_IMG;

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      ms <= M_INIT; lc <= S_RAW; lcw <= '0; arbn <= '0; idx <= '0; tfail <= '0; lc_pend <= 1'b0;
      tgt <= '0; tok_otp <= 1'b0; tok_rma <= 1'b0; pdat <= '0; neq <= 1'b0; nw <= '0; nw_ovf <= 1'b0; ver <= '0; padw <= 1'b0;
      sfirst <= 1'b0;
      kouter <= 1'b0; inner <= '0;
      otp_req <= 1'b0; otp_we <= 1'b0; otp_addr <= '0; otp_wdata <= '0;
      cmd_done <= 1'b0; cmd_err <= 1'b0; cmd_rdata <= '0;
      init_done <= 1'b0; boot_done <= 1'b0; boot_ok <= 1'b0; cpu_en <= 1'b0; key_valid <= 1'b0; key_out <= '0;
      alert <= 1'b0; alert_code <= '0;
      blk <= '0; sha_go <= 1'b0; sha_init <= 1'b0;
    end else begin
      cmd_done <= 1'b0; cmd_err <= 1'b0; alert <= 1'b0; sha_go <= 1'b0;
      if (otp_ack) otp_req <= 1'b0;
      if (esc && ms != M_ESC) begin
        ms <= M_ESC; otp_req <= 1'b0;
        cpu_en <= 1'b0; key_valid <= 1'b0; key_out <= '0; blk <= '0; inner <= '0;
        alert <= 1'b1; alert_code <= A_ESC;
      end else
        case (ms)
          // read the lifecycle, scrap and anti-rollback words
          M_INIT:
            if (!otp_req) begin
              otp_req <= 1'b1; otp_we <= 1'b0; otp_addr <= O_LC + 6'(idx);
            end else if (otp_ack) begin
              idx <= idx + 4'd1;
              if (idx == 4'd0) lcw <= otp_rdata;
              if (idx == 4'd2) begin
                arbn <= popc(otp_rdata);
                lc <= lc_dec(lcw, pdat);
                init_done <= 1'b1; idx <= '0; ms <= M_IDLE;
                if (lc_dec(lcw, pdat) == S_INVALID) begin alert <= 1'b1; alert_code <= A_LC; end
                // TEST and RMA boot unverified; RAW, SCRAP and INVALID never boot
                case (lc_dec(lcw, pdat))
                  S_TEST, S_RMA: begin boot_done <= 1'b1; boot_ok <= 1'b1; cpu_en <= 1'b1; end
                  S_DEV, S_PROD: ;
                  default: boot_done <= 1'b1;
                endcase
              end
              pdat <= otp_rdata;          // holds the scrap word for the decode above
            end
          M_IDLE:
            if (cmd_start) begin
              if (tfail == 2'd3 || lc_pend && cmd_op != C_READ) begin cmd_done <= 1'b1; cmd_err <= 1'b1; end
              else
                case (cmd_op)
                  C_READ:
                    if (cmd_addr < O_DIG) begin
                      cmd_done <= 1'b1; cmd_err <= 1'b1; alert <= 1'b1; alert_code <= A_ACCESS;
                    end else begin
                      otp_req <= 1'b1; otp_we <= 1'b0; otp_addr <= cmd_addr; ms <= M_RD;
                    end
                  C_PROG:
                    if (!prog_ok(cmd_addr, lc)) begin
                      cmd_done <= 1'b1; cmd_err <= 1'b1; alert <= 1'b1; alert_code <= A_ACCESS;
                    end else begin
                      otp_req <= 1'b1; otp_we <= 1'b1; otp_addr <= cmd_addr; otp_wdata <= cmd_data;
                      pdat <= cmd_data; ms <= M_PG;
                    end
                  C_TRANS:
                    if (!trans_ok(lc, cmd_data[2:0])) begin cmd_done <= 1'b1; cmd_err <= 1'b1; end
                    else begin
                      tgt <= cmd_data[2:0];
                      if (cmd_data[2:0] == S_SCRAP) begin
                        otp_req <= 1'b1; otp_we <= 1'b1; otp_addr <= O_SCRAP; otp_wdata <= 32'hFFFF_FFFF;
                        pdat <= 32'hFFFF_FFFF; ms <= M_TRPG;
                      end else begin
                        tok_otp <= lc != S_RAW; tok_rma <= lc != S_RAW && lc != S_TEST;
                        blk <= {token, 32'h8000_0000, 320'd0, 32'd128};
                        sha_go <= 1'b1; sha_init <= 1'b1; ms <= M_TOKH;
                      end
                    end
                  default: begin cmd_done <= 1'b1; cmd_err <= 1'b1; end
                endcase
            end else if (img_valid && !boot_done && boot_dev) begin
              ms <= M_IMG; idx <= '0; nw <= '0; nw_ovf <= 1'b0; sfirst <= 1'b1;
            end
          // ---- commands
          M_RD:
            if (otp_ack) begin cmd_rdata <= otp_rdata; cmd_done <= 1'b1; ms <= M_IDLE; end
          M_PG:
            if (otp_ack) begin otp_req <= 1'b1; otp_we <= 1'b0; ms <= M_PV; end
          M_PV:
            if (otp_ack) begin
              cmd_done <= 1'b1; ms <= M_IDLE;
              if ((otp_rdata & pdat) != pdat) begin cmd_err <= 1'b1; alert <= 1'b1; alert_code <= A_OTP; end
            end
          // token: hash it, then compare the eight words with the expected hash
          M_TOKH:
            if (!sha_go && !sha_busy) begin ms <= M_TOKC; idx <= '0; neq <= 1'b0; end
          M_TOKC:
            if (tok_otp && !otp_req && !otp_ack) begin
              otp_req <= 1'b1; otp_we <= 1'b0; otp_addr <= (tok_rma ? O_RTOK : O_TTOK) + 6'(idx);
            end else if (!tok_otp || otp_ack) begin
              idx <= idx + 4'd1;
              if (idx == 4'd7) begin
                idx <= '0; blk <= '0;
                if (neq || hw != thw) begin
                  ms <= M_IDLE; cmd_done <= 1'b1; cmd_err <= 1'b1; alert <= 1'b1; alert_code <= A_TOKEN;
                  tfail <= tfail + 2'd1;
                end else begin
                  otp_req <= 1'b1; otp_we <= 1'b1; otp_addr <= O_LC; otp_wdata <= lc_word(tgt);
                  pdat <= lc_word(tgt); ms <= M_TRPG;
                end
              end else neq <= neq | (hw != thw);
            end
          M_TRPG:
            if (otp_ack) begin otp_req <= 1'b1; otp_we <= 1'b0; ms <= M_TRPV; end
          M_TRPV:
            if (otp_ack) begin
              cmd_done <= 1'b1; ms <= M_IDLE; lc_pend <= 1'b1;
              if (otp_rdata != pdat) begin cmd_err <= 1'b1; alert <= 1'b1; alert_code <= A_OTP; end
            end
          // ---- secure boot: fill a block with image words, hash it
          M_IMG:
            if (img_valid) begin
              blk[{4'd15 - idx, 5'd0} +: 32] <= img_data;
              if (nw == '0) ver <= img_data;
              nw <= nw + 1'b1;
              if (&nw) nw_ovf <= 1'b1;
              idx <= idx + 4'd1;
              if (idx == 4'd15) begin
                sha_go <= 1'b1; sha_init <= sfirst; sfirst <= 1'b0; ms <= img_last ? M_PADH : M_IMGH;
              end else if (img_last) ms <= M_PAD;
              padw <= 1'b1;
            end
          M_IMGH:
            if (!sha_go && !sha_busy) ms <= M_IMG;
          // padding: the 0x80 word, zeros, the 64-bit bit length in words 14 and 15
          M_PAD:
            if (padw) begin
              blk[{4'd15 - idx, 5'd0} +: 32] <= 32'h8000_0000; padw <= 1'b0; idx <= idx + 4'd1;
              if (idx == 4'd15) begin sha_go <= 1'b1; sha_init <= sfirst; sfirst <= 1'b0; ms <= M_PADH; end
            end else if (idx == 4'd14) begin
              blk[63:0] <= 64'({nw_ovf, nw}) << 5;
              idx <= '0; sha_go <= 1'b1; sha_init <= sfirst; sfirst <= 1'b0; ms <= M_VER;
            end else begin
              blk[{4'd15 - idx, 5'd0} +: 32] <= '0; idx <= idx + 4'd1;
              if (idx == 4'd15) begin sha_go <= 1'b1; sha_init <= sfirst; sfirst <= 1'b0; ms <= M_PADH; end
            end
          M_PADH:
            if (!sha_go && !sha_busy) ms <= M_PAD;
          // compare the digest with the OTP one, word by word (all eight words, whatever they hold)
          M_VER:
            if (!sha_go && !sha_busy && !otp_req && !otp_ack) begin
              otp_req <= 1'b1; otp_we <= 1'b0; otp_addr <= O_DIG + 6'(idx);
            end else if (otp_ack) begin
              idx <= idx + 4'd1;
              if (idx == 4'd7) begin
                idx <= '0;
                if (neq || hw != otp_rdata || nw_ovf || ver < 32'(arbn)) begin
                  ms <= M_IDLE; boot_done <= 1'b1; alert <= 1'b1; alert_code <= A_BOOT; blk <= '0;
                end else begin
                  inner <= hh; kouter <= 1'b0; ms <= M_KLD;
                end
              end else neq <= neq | (hw != otp_rdata);
            end
          // ---- key: HMAC-SHA256(UDS, digest || lifecycle word); the UDS goes from the OTP
          // into the block register only
          M_KLD:
            if (!otp_req && !otp_ack) begin
              otp_req <= 1'b1; otp_we <= 1'b0; otp_addr <= 6'(idx);
            end else if (otp_ack) begin
              blk[{4'd15 - idx, 5'd0} +: 32] <= otp_rdata ^ (kouter ? 32'h5c5c_5c5c : 32'h3636_3636);
              blk[255:0] <= {8{kouter ? 32'h5c5c_5c5c : 32'h3636_3636}};
              idx <= idx + 4'd1;
              if (idx == 4'd7) begin idx <= '0; sha_go <= 1'b1; sha_init <= 1'b1; ms <= M_KH; end
            end
          M_KH:
            if (!sha_go && !sha_busy) begin
              blk <= kouter ? {inner, 32'h8000_0000, 192'd0, 32'd768}
                            : {inner, lcw, 32'h8000_0000, 160'd0, 32'd800};
              sha_go <= 1'b1; sha_init <= 1'b0; ms <= M_KMH;
            end
          M_KMH:
            if (!sha_go && !sha_busy) begin
              if (!kouter) begin inner <= hh; kouter <= 1'b1; ms <= M_KLD; end
              else begin
                key_out <= hh; key_valid <= 1'b1; blk <= '0; inner <= '0;
                boot_done <= 1'b1; boot_ok <= 1'b1; cpu_en <= 1'b1; ms <= M_IDLE;
              end
            end
          M_ESC: ;
          default: begin ms <= M_ESC; alert <= 1'b1; alert_code <= A_FAULT; end
        endcase
      // the SHA-256 rounds shift the block register
      if (sha_run && !esc) blk <= {blk[479:0], wnew};
    end
  end

  // SHA-256 compression: 64 rounds, one per clock
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      hh <= '0; srnd <= 7'd64; sha_done <= 1'b0;
      sa <= '0; sb <= '0; sc <= '0; sd <= '0; se <= '0; sf <= '0; sg <= '0; sh <= '0;
    end else begin
      sha_done <= 1'b0;
      if (esc) begin
        hh <= '0; srnd <= 7'd64;
        sa <= '0; sb <= '0; sc <= '0; sd <= '0; se <= '0; sf <= '0; sg <= '0; sh <= '0;
      end else if (sha_go) begin
        {sa, sb, sc, sd, se, sf, sg, sh} <= sha_init ? IV : hh;
        if (sha_init) hh <= IV;
        srnd <= '0;
      end else if (sha_run) begin
        sh <= sg; sg <= sf; sf <= se; se <= sd + t1; sd <= sc; sc <= sb; sb <= sa; sa <= t1 + t2;
        srnd <= srnd + 7'd1;
        if (srnd == 7'd63) sha_done <= 1'b1;
      end else if (sha_done) begin
        hh <= {hh[255:224] + sa, hh[223:192] + sb, hh[191:160] + sc, hh[159:128] + sd,
               hh[127:96] + se, hh[95:64] + sf, hh[63:32] + sg, hh[31:0] + sh};
      end
    end
  end
`ifdef FORMAL
  `include "Root_of_Trust_props.svh"
`endif
endmodule
