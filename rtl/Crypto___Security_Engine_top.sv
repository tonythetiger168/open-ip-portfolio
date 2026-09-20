// SPDX-License-Identifier: Apache-2.0
// ============================================================================
// Crypto & Security Engine -- real SHA-256 (FIPS 180-4) + HMAC (RFC 2104).
//   * Full SHA-256 compression function, 64 rounds, 1 round/clk, K constant
//     table, on-the-fly message schedule
//   * Message port: 512-bit block written as 4x128 words + msg_len (bytes,
//     0..64); start triggers hashing; padding (0x80 || 0 || len64) is done
//     internally, including the 56..64-byte two-block corner case
//   * HMAC mode: 512-bit key block written as 4x128 words; ipad/opad and the
//     two-pass H(K^opad || H(K^ipad || msg)) are computed automatically
//   * digest[255:0] + done; any start/key/msg write while busy -> irq pulse
// IP design implementation v1.0 -- Apache-2.0
// ============================================================================
module Crypto___Security_Engine_top #(
  parameter int DW = 32,   // word width
  parameter int AW = 32    // (framework) address width
)(
  input  logic         clk,
  input  logic         rst_n,
  // message block port (4 x 128-bit, MSW first)
  input  logic         msg_we,
  input  logic [1:0]   msg_widx,
  input  logic [127:0] msg,
  // HMAC key block port (4 x 128-bit, MSW first, zero-padded by driver)
  input  logic         key_we,
  input  logic [1:0]   key_widx,
  input  logic [127:0] key,
  // command port
  input  logic [6:0]   msg_len,        // message length in bytes (0..64)
  input  logic         start,
  input  logic         mode,           // 0 = SHA-256, 1 = HMAC-SHA-256
  output logic         busy,
  output logic         done,
  output logic [255:0] digest,
  output logic         irq
);

  // ------------------------------------------------------------------
  // SHA-256 constants
  // ------------------------------------------------------------------
  function automatic logic [31:0] kc(input logic [5:0] t);
    case (t)
      6'd0 : kc=32'h428a2f98; 6'd1 : kc=32'h71374491; 6'd2 : kc=32'hb5c0fbcf;
      6'd3 : kc=32'he9b5dba5; 6'd4 : kc=32'h3956c25b; 6'd5 : kc=32'h59f111f1;
      6'd6 : kc=32'h923f82a4; 6'd7 : kc=32'hab1c5ed5; 6'd8 : kc=32'hd807aa98;
      6'd9 : kc=32'h12835b01; 6'd10: kc=32'h243185be; 6'd11: kc=32'h550c7dc3;
      6'd12: kc=32'h72be5d74; 6'd13: kc=32'h80deb1fe; 6'd14: kc=32'h9bdc06a7;
      6'd15: kc=32'hc19bf174; 6'd16: kc=32'he49b69c1; 6'd17: kc=32'hefbe4786;
      6'd18: kc=32'h0fc19dc6; 6'd19: kc=32'h240ca1cc; 6'd20: kc=32'h2de92c6f;
      6'd21: kc=32'h4a7484aa; 6'd22: kc=32'h5cb0a9dc; 6'd23: kc=32'h76f988da;
      6'd24: kc=32'h983e5152; 6'd25: kc=32'ha831c66d; 6'd26: kc=32'hb00327c8;
      6'd27: kc=32'hbf597fc7; 6'd28: kc=32'hc6e00bf3; 6'd29: kc=32'hd5a79147;
      6'd30: kc=32'h06ca6351; 6'd31: kc=32'h14292967; 6'd32: kc=32'h27b70a85;
      6'd33: kc=32'h2e1b2138; 6'd34: kc=32'h4d2c6dfc; 6'd35: kc=32'h53380d13;
      6'd36: kc=32'h650a7354; 6'd37: kc=32'h766a0abb; 6'd38: kc=32'h81c2c92e;
      6'd39: kc=32'h92722c85; 6'd40: kc=32'ha2bfe8a1; 6'd41: kc=32'ha81a664b;
      6'd42: kc=32'hc24b8b70; 6'd43: kc=32'hc76c51a3; 6'd44: kc=32'hd192e819;
      6'd45: kc=32'hd6990624; 6'd46: kc=32'hf40e3585; 6'd47: kc=32'h106aa070;
      6'd48: kc=32'h19a4c116; 6'd49: kc=32'h1e376c08; 6'd50: kc=32'h2748774c;
      6'd51: kc=32'h34b0bcb5; 6'd52: kc=32'h391c0cb3; 6'd53: kc=32'h4ed8aa4a;
      6'd54: kc=32'h5b9cca4f; 6'd55: kc=32'h682e6ff3; 6'd56: kc=32'h748f82ee;
      6'd57: kc=32'h78a5636f; 6'd58: kc=32'h84c87814; 6'd59: kc=32'h8cc70208;
      6'd60: kc=32'h90befffa; 6'd61: kc=32'ha4506ceb; 6'd62: kc=32'hbef9a3f7;
      default: kc=32'hc67178f2;
    endcase
  endfunction

  function automatic logic [31:0] hinit(input logic [2:0] i);
    case (i)
      3'd0: hinit=32'h6a09e667; 3'd1: hinit=32'hbb67ae85;
      3'd2: hinit=32'h3c6ef372; 3'd3: hinit=32'ha54ff53a;
      3'd4: hinit=32'h510e527f; 3'd5: hinit=32'h9b05688c;
      3'd6: hinit=32'h1f83d9ab; default: hinit=32'h5be0cd19;
    endcase
  endfunction

  // ------------------------------------------------------------------
  // SHA-256 round functions
  // ------------------------------------------------------------------
  function automatic logic [31:0] ror(input logic [31:0] x, input integer n);
    ror = (x >> n) | (x << (32 - n));
  endfunction
  function automatic logic [31:0] bs0(input logic [31:0] x);  // big sigma 0
    bs0 = ror(x,2) ^ ror(x,13) ^ ror(x,22);
  endfunction
  function automatic logic [31:0] bs1(input logic [31:0] x);  // big sigma 1
    bs1 = ror(x,6) ^ ror(x,11) ^ ror(x,25);
  endfunction
  function automatic logic [31:0] ss0(input logic [31:0] x);  // small sigma 0
    ss0 = ror(x,7) ^ ror(x,18) ^ (x >> 3);
  endfunction
  function automatic logic [31:0] ss1(input logic [31:0] x);  // small sigma 1
    ss1 = ror(x,17) ^ ror(x,19) ^ (x >> 10);
  endfunction

  // ------------------------------------------------------------------
  // registers
  // ------------------------------------------------------------------
  typedef enum logic [2:0] {S_IDLE, S_BLK, S_RND, S_FIN, S_DONE} sstate_t;
  sstate_t     cs;
  logic        mode_q;             // 1 = HMAC
  logic [6:0]  len_q;
  logic [5:0]  rcnt;               // round counter 0..63
  logic [511:0] msg_q, key_q;
  logic [31:0] H  [0:7];           // hash state
  logic [31:0] A  [0:7];           // working variables a..h
  logic [31:0] W  [0:15];          // message schedule window
  logic [31:0] dr [0:7];           // digest register
  logic [2:0]  blk_type;           // current block being compressed

  localparam logic [2:0] B_NONE  = 3'd0;
  localparam logic [2:0] B_IPAD  = 3'd1;
  localparam logic [2:0] B_MSG0  = 3'd2;
  localparam logic [2:0] B_MSG1  = 3'd3;
  localparam logic [2:0] B_OPAD  = 3'd4;
  localparam logic [2:0] B_OUTER = 3'd5;

  assign busy   = (cs != S_IDLE);
  assign digest = {dr[0], dr[1], dr[2], dr[3], dr[4], dr[5], dr[6], dr[7]};

  // message bit length contribution of the message blocks
  wire [9:0] bitlen = (mode_q ? 10'd512 : 10'd0) + {len_q, 3'b000};

  // ------------------------------------------------------------------
  // padded-block byte construction
  // ------------------------------------------------------------------
  // first (or only) message block: msg bytes || 0x80 || 0 || (len64 if fits)
  function automatic logic [7:0] msg0_byte(input logic [6:0] p);
    begin
      if (p < len_q)           msg0_byte = msg_q[511-8*p -: 8];
      else if (p == len_q)     msg0_byte = 8'h80;
      else if ((len_q <= 7'd55) && (p >= 7'd56))
        msg0_byte = (p == 7'd62) ? {6'h0, bitlen[9:8]} :
                    (p == 7'd63) ? bitlen[7:0] : 8'h00;
      else                     msg0_byte = 8'h00;
    end
  endfunction
  // second message block (len_q >= 56): zeros || len64 (0x80 here if len==64)
  function automatic logic [7:0] msg1_byte(input logic [6:0] p);
    begin
      if ((len_q == 7'd64) && (p == 7'd0)) msg1_byte = 8'h80;
      else if (p >= 7'd56)
        msg1_byte = (p == 7'd62) ? {6'h0, bitlen[9:8]} :
                    (p == 7'd63) ? bitlen[7:0] : 8'h00;
      else                     msg1_byte = 8'h00;
    end
  endfunction
  // HMAC outer block: inner digest || 0x80 || 0 || 64'd768
  function automatic logic [7:0] outer_byte(input logic [6:0] p);
    begin
      if (p < 7'd32)       outer_byte = dr[p[4:0] >> 2][31-8*(p[1:0]) -: 8];
      else if (p == 7'd32) outer_byte = 8'h80;
      else if (p == 7'd62) outer_byte = 8'h03;   // 768 = 0x300
      else                 outer_byte = 8'h00;
    end
  endfunction

  // word wi of the block selected by bt
  function automatic logic [31:0] blk_word(input logic [2:0] bt,
                                           input logic [3:0] wi);
    logic [6:0] p;
    begin
      p = {wi, 2'b00};
      case (bt)
        B_IPAD:  blk_word = key_q[511-32*wi -: 32] ^ 32'h36363636;
        B_OPAD:  blk_word = key_q[511-32*wi -: 32] ^ 32'h5c5c5c5c;
        B_MSG0:  blk_word = {msg0_byte(p), msg0_byte(p+7'd1),
                             msg0_byte(p+7'd2), msg0_byte(p+7'd3)};
        B_MSG1:  blk_word = {msg1_byte(p), msg1_byte(p+7'd1),
                             msg1_byte(p+7'd2), msg1_byte(p+7'd3)};
        B_OUTER: blk_word = {outer_byte(p), outer_byte(p+7'd1),
                             outer_byte(p+7'd2), outer_byte(p+7'd3)};
        default: blk_word = 32'h0;
      endcase
    end
  endfunction

  // next block in the hash programme (all inputs explicit: some simulators
  // do not sensitise continuous assignments to function-referenced globals)
  function automatic logic [2:0] next_blk(input logic [2:0] bt,
                                          input logic [6:0] ln,
                                          input logic       hm);
    begin
      case (bt)
        B_IPAD:  next_blk = B_MSG0;
        B_MSG0:  next_blk = (ln > 7'd55) ? B_MSG1 :
                            (hm ? B_OPAD : B_NONE);
        B_MSG1:  next_blk = hm ? B_OPAD : B_NONE;
        B_OPAD:  next_blk = B_OUTER;
        default: next_blk = B_NONE;
      endcase
    end
  endfunction

  // round combinational terms
  wire [31:0] ch   = (A[4] & A[5]) ^ (~A[4] & A[6]);
  wire [31:0] maj  = (A[0] & A[1]) ^ (A[0] & A[2]) ^ (A[1] & A[2]);
  wire [31:0] t1   = A[7] + bs1(A[4]) + ch + kc(rcnt) + W[0];
  wire [31:0] t2   = bs0(A[0]) + maj;
  wire [31:0] wnew = ss1(W[14]) + W[9] + ss0(W[1]) + W[0];

  wire [2:0] nxt_blk = next_blk(blk_type, len_q, mode_q);

  // ------------------------------------------------------------------
  // sequential control
  // ------------------------------------------------------------------
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      cs       <= S_IDLE;
      mode_q   <= 1'b0;
      len_q    <= 7'd0;
      rcnt     <= 6'd0;
      blk_type <= B_NONE;
      msg_q    <= 512'h0;
      key_q    <= 512'h0;
      for (int i = 0; i < 8; i++) begin
        H[i]  <= 32'h0;
        A[i]  <= 32'h0;
        dr[i] <= 32'h0;
      end
      for (int i = 0; i < 16; i++) W[i] <= 32'h0;
      done <= 1'b0;
      irq  <= 1'b0;
    end else begin
      done <= 1'b0;
      irq  <= 1'b0;

      // register write ports; writes during busy are violations
      if (msg_we) begin
        if (cs != S_IDLE) irq <= 1'b1;
        else msg_q[511-128*msg_widx -: 128] <= msg;
      end
      if (key_we) begin
        if (cs != S_IDLE) irq <= 1'b1;
        else key_q[511-128*key_widx -: 128] <= key;
      end
      if (start && (cs != S_IDLE)) irq <= 1'b1;

      case (cs)
        S_IDLE: if (start) begin
          mode_q   <= mode;
          len_q    <= msg_len;
          blk_type <= mode ? B_IPAD : B_MSG0;
          for (int i = 0; i < 8; i++) H[i] <= hinit(i[2:0]);
          cs       <= S_BLK;
        end
        S_BLK: begin
          for (int i = 0; i < 16; i++) W[i] <= blk_word(blk_type, i[3:0]);
          for (int i = 0; i < 8; i++)  A[i] <= H[i];
          rcnt <= 6'd0;
          cs   <= S_RND;
        end
        S_RND: begin
          // compression round
          A[7] <= A[6];
          A[6] <= A[5];
          A[5] <= A[4];
          A[4] <= A[3] + t1;
          A[3] <= A[2];
          A[2] <= A[1];
          A[1] <= A[0];
          A[0] <= t1 + t2;
          // message schedule window
          for (int i = 0; i < 15; i++) W[i] <= W[i+1];
          W[15] <= wnew;
          if (rcnt == 6'd63) cs <= S_FIN;
          else rcnt <= rcnt + 6'd1;
        end
        S_FIN: begin
          for (int i = 0; i < 8; i++) begin
            if ((nxt_blk == B_OPAD) || (nxt_blk == B_NONE))
              dr[i] <= H[i] + A[i];   // pass-final digest only
            H[i]  <= (nxt_blk == B_OPAD) ? hinit(i[2:0]) : (H[i] + A[i]);
          end
          if (nxt_blk == B_NONE) cs <= S_DONE;
          else begin
            blk_type <= nxt_blk;
            cs       <= S_BLK;
          end
        end
        S_DONE: begin
          done <= 1'b1;
          cs   <= S_IDLE;
        end
        default: cs <= S_IDLE;
      endcase
    end
  end

endmodule
