// SPDX-License-Identifier: Apache-2.0
// ============================================================================
// FC_top v2.0: Fibre Channel FC-1 / FC-2 port (8b/10b, ordered sets,
// class 3 frames, buffer-to-buffer credit)
// ----------------------------------------------------------------------------
//  - Line: one bit per clk, symbol bit a first, 8b/10b coding (the IEEE
//    802.3 clause 36 tables) with running disparity, starting at RD-. The
//    transmitter sends transmission words (4 characters) all the time.
//  - Ordered sets: K28.5 then three data characters:
//      IDLE   D21.4 D21.5 D21.5      R_RDY  D21.4 D10.2 D10.2
//      SOFi3  D21.5 D22.2 D22.2      SOFn3  D21.5 D22.1 D22.1
//      EOFn   Dx    D21.6 D21.6      EOFt   Dx    D21.3 D21.3
//      EOFa   Dx    D21.7 D21.7      (Dx = D21.4 when the running disparity
//                                     before the EOF is negative, D21.5
//                                     when positive; the EOF ends at RD-)
//  - Transmit: a frame (24-byte header and payload, byte by byte) comes
//    from the tx_* stream; tx_sofi with the first byte picks SOFi3 over
//    SOFn3, tx_eoft with the last byte picks EOFt over EOFn. tx_ready is
//    high for one clock when a byte goes out. The port sends SOF, the
//    bytes, zero fill up to a word boundary and at least 24 bytes, the
//    CRC-32 word, EOF; tx_done pulses as the EOF goes out. Without a byte
//    in time it pulses tx_underrun, fills the word with zeros and ends the
//    frame with EOFa. At least six IDLE / R_RDY words separate frames.
//  - Buffer-to-buffer credit: a frame starts only while credit_used (frames
//    sent, less R_RDYs received) is below cfg_credit; cfg_credit = 0 turns
//    the check off (credit_used then saturates at 15). The port sends one
//    R_RDY for each frame it receives (up to 15 waiting), ahead of IDLEs.
//  - Receive: the receiver aligns on K28.5 at any bit offset; three ordered
//    sets later rx_sync goes high. A code violation, a disparity error or a
//    K character other than K28.5 in the first position pulses err_code
//    and drops alignment. Frame bytes go out on rx_* five bytes late,
//    without the CRC; the last one has rx_last and
//    rx_stat = {sofi, eoft, abort, len_err, crc_err}:
//      crc_err  the CRC does not check
//      len_err  fewer than 28 or more than 2140 bytes, CRC included
//      abort    the frame ended with EOFa, another ordered set or a loss of
//               alignment
//    A frame that ends with fewer than 5 bytes pulses rx_frag instead. Data
//    words or an EOF outside a frame pulse err_word.
//  Not implemented: link initialization (NOS / OLS / LR / LRR), classes
//  other than 3, other SOF / EOF delimiters and primitive signals, word
//  synchronization with loss-of-sync hysteresis (one error drops
//  alignment), ACK / end-to-end credit, header parsing. The CRC is sent
//  like an Ethernet FCS (complemented, least significant byte first).
// ============================================================================
module FC_top (
  input  logic       clk,
  input  logic       rst_n,
  // line
  output logic       tx_p,
  input  logic       rx_p,
  // configuration
  input  logic [3:0] cfg_credit,     // BB_credit of the far end (0 = off)
  // transmit host
  input  logic       tx_valid,
  output logic       tx_ready,
  input  logic [7:0] tx_data,
  input  logic       tx_last,
  input  logic       tx_sofi,
  input  logic       tx_eoft,
  output logic       tx_done,
  output logic       tx_underrun,
  output logic [3:0] credit_used,
  // receive host
  output logic       rx_valid,
  output logic [7:0] rx_data,
  output logic       rx_last,
  output logic [4:0] rx_stat,
  output logic       rx_frag,
  // status
  output logic       rx_sync,
  output logic       err_code,
  output logic       err_word
);
  // ---------------- 8b/10b ----------------
  // symbols {a,b,c,d,e,i,f,g,h,j}, a in bit 9; tables give the RD- forms
  function logic [5:0] t6(input logic [4:0] x);
    case (x)
      5'd0:  t6 = 6'b100111; 5'd1:  t6 = 6'b011101; 5'd2:  t6 = 6'b101101; 5'd3:  t6 = 6'b110001;
      5'd4:  t6 = 6'b110101; 5'd5:  t6 = 6'b101001; 5'd6:  t6 = 6'b011001; 5'd7:  t6 = 6'b111000;
      5'd8:  t6 = 6'b111001; 5'd9:  t6 = 6'b100101; 5'd10: t6 = 6'b010101; 5'd11: t6 = 6'b110100;
      5'd12: t6 = 6'b001101; 5'd13: t6 = 6'b101100; 5'd14: t6 = 6'b011100; 5'd15: t6 = 6'b010111;
      5'd16: t6 = 6'b011011; 5'd17: t6 = 6'b100011; 5'd18: t6 = 6'b010011; 5'd19: t6 = 6'b110010;
      5'd20: t6 = 6'b001011; 5'd21: t6 = 6'b101010; 5'd22: t6 = 6'b011010; 5'd23: t6 = 6'b111010;
      5'd24: t6 = 6'b110011; 5'd25: t6 = 6'b100110; 5'd26: t6 = 6'b010110; 5'd27: t6 = 6'b110110;
      5'd28: t6 = 6'b001110; 5'd29: t6 = 6'b101110; 5'd30: t6 = 6'b011110; default: t6 = 6'b101011;
    endcase
  endfunction
  function logic [3:0] t4(input logic [2:0] y, input logic k28);
    case (y)
      3'd0: t4 = 4'b1011;
      3'd1: t4 = k28 ? 4'b0110 : 4'b1001;
      3'd2: t4 = k28 ? 4'b1010 : 4'b0101;
      3'd3: t4 = 4'b1100;
      3'd4: t4 = 4'b1101;
      3'd5: t4 = k28 ? 4'b0101 : 4'b1010;
      3'd6: t4 = k28 ? 4'b1001 : 4'b0110;
      default: t4 = 4'b1110;
    endcase
  endfunction
  function logic unbal6(input logic [5:0] s);
    unbal6 = {2'd0, s[0]} + {2'd0, s[1]} + {2'd0, s[2]} + {2'd0, s[3]} + {2'd0, s[4]} + {2'd0, s[5]} != 3'd3;
  endfunction
  function logic unbal4(input logic [3:0] s);
    unbal4 = {2'd0, s[0]} + {2'd0, s[1]} + {2'd0, s[2]} + {2'd0, s[3]} != 3'd2;
  endfunction
  // {symbol, RD after}; rd = 1: RD+
  function logic [10:0] enc(input logic [7:0] d, input logic k, input logic rd);
    logic [5:0] s6;
    logic [3:0] s4;
    logic       r, k28;
    k28 = k && d[4:0] == 5'd28;
    s6 = k28 ? 6'b001111 : t6(d[4:0]);
    r = rd;
    if (r && (unbal6(s6) || s6 == 6'b111000)) s6 = ~s6;
    if (unbal6(s6)) r = !r;
    if (d[7:5] == 3'd7 && (k || (!r && (d[4:0] == 5'd17 || d[4:0] == 5'd18 || d[4:0] == 5'd20))
                            || (r && (d[4:0] == 5'd11 || d[4:0] == 5'd13 || d[4:0] == 5'd14))))
      s4 = 4'b0111;
    else s4 = t4(d[7:5], k28);
    if (r && (unbal4(s4) || d[7:5] == 3'd3 || k28)) s4 = ~s4;
    if (unbal4(s4)) r = !r;
    enc = {s6, s4, r};
  endfunction
  // 6b -> {valid, x}; both forms
  function logic [5:0] d6(input logic [5:0] s);
    logic [5:0] m;
    d6 = 6'd0;
    for (int x = 0; x < 32; x++) begin : b_d6
      m = t6(5'(x));
      if (s == m || (s == ~m && (unbal6(m) || x == 7))) d6 = {1'b1, 5'(x)};
    end
  endfunction
  // 4b -> y (7 when nothing else matches); K28: the 6b form fixes the
  // column (kinv: 001111 was sent, the RD+ column follows)
  function logic [2:0] d4(input logic [3:0] s, input logic k28, input logic kinv);
    logic [3:0] m;
    d4 = 3'd7;
    for (int y = 0; y < 7; y++) begin : b_d4
      m = t4(3'(y), k28);
      if (k28 ? s == (kinv ? ~m : m) : (s == m || (s == ~m && (unbal4(m) || y == 3)))) d4 = 3'(y);
    end
  endfunction
  function automatic logic [31:0] crc8(input logic [31:0] c, input logic [7:0] d);
    logic [31:0] r;
    r = c;
    for (int i = 0; i < 8; i++) r = (r[0] ^ d[i]) ? (r >> 1) ^ 32'hEDB88320 : r >> 1;
    crc8 = r;
  endfunction

  localparam logic [8:0]  K28_5 = {1'b1, 8'hBC};
  // ordered sets: characters 1..3
  localparam logic [23:0] OS_IDLE = 24'h95B5B5, OS_RRDY = 24'h954A4A,
                          OS_SOFI = 24'hB55656, OS_SOFN = 24'hB53636;
  localparam logic [7:0]  D21_4 = 8'h95, D21_5 = 8'hB5, D21_6 = 8'hD5, D21_3 = 8'h75, D21_7 = 8'hF5;
  localparam logic [31:0] RESIDUE = 32'hDEBB20E3;

  // ---------------- transmitter ----------------
  // ts: what the next character is
  typedef enum logic [2:0] {T_GAP, T_SOF, T_DATA, T_PAD, T_CRC, T_FILL, T_EOF} tst_t;
  tst_t        ts;
  logic [9:0]  tsh;                     // symbol being sent, bit 9 next
  logic [3:0]  tbit;                    // bits left in the symbol - 1
  logic        trd;
  logic [1:0]  tw;                      // position of the next character in its word
  logic [23:0] tos;                     // ordered set characters still to send
  logic [4:0]  tn;                      // frame bytes sent, up to 24
  logic [31:0] tcrc;
  logic [2:0]  tgap;                    // words since the last EOF, up to 6
  logic        teot, tabt;              // EOFt, EOFa
  logic [3:0]  rr_pend;                 // R_RDYs to send

  wire sym_end = tbit == 4'd0;
  wire cr_ok = cfg_credit == 4'd0 || credit_used < cfg_credit;
  wire start = tw == 2'd0 && tgap == 3'd6 && tx_valid && cr_ok;
  assign tx_p = tsh[9];
  assign tx_ready = sym_end && ts == T_DATA && tx_valid;

  // next character
  logic [8:0]  nsym;
  logic        send_rr;
  always_comb begin
    nsym = {1'b0, tos[23:16]}; send_rr = 1'b0;
    unique case (ts)
      T_GAP, T_EOF: if (tw == 2'd0) begin
        nsym = K28_5;
        send_rr = ts == T_GAP && !start && rr_pend != 4'd0;
      end
      T_SOF: ;
      T_DATA: nsym = {1'b0, tx_valid ? tx_data : 8'h00};
      T_PAD, T_FILL: nsym = 9'd0;
      T_CRC: nsym = {1'b0, ~tcrc[8 * tw +: 8]};
    endcase
  end
  wire [10:0] tenc = enc(nsym[7:0], nsym[8], trd);
  wire        pad_end = tw == 2'd3 && tn >= 5'd23;

  always_ff @(posedge clk or negedge rst_n)
    if (!rst_n) begin
      ts <= T_GAP; tsh <= '0; tbit <= '0; trd <= 1'b0; tw <= '0; tos <= '0; tn <= '0; tcrc <= '0;
      tgap <= '0; teot <= 1'b0; tabt <= 1'b0; tx_done <= 1'b0; tx_underrun <= 1'b0;
    end else begin
      tx_done <= 1'b0; tx_underrun <= 1'b0;
      if (!sym_end) begin tbit <= tbit - 4'd1; tsh <= {tsh[8:0], 1'b0}; end
      else begin
        tsh <= tenc[10:1]; trd <= tenc[0]; tbit <= 4'd9; tw <= tw + 2'd1;
        tos <= {tos[15:0], 8'h00};
        unique case (ts)
          T_GAP: if (tw == 2'd0) begin
            if (start) begin ts <= T_SOF; tos <= tx_sofi ? OS_SOFI : OS_SOFN; end
            else begin
              tos <= send_rr ? OS_RRDY : OS_IDLE;
              if (tgap != 3'd6) tgap <= tgap + 3'd1;
            end
          end
          T_SOF: if (tw == 2'd3) begin ts <= T_DATA; tn <= '0; tcrc <= '1; end
          T_DATA: if (tx_valid) begin
            tcrc <= crc8(tcrc, tx_data);
            if (tn != 5'd24) tn <= tn + 5'd1;
            if (tx_last) begin ts <= pad_end ? T_CRC : T_PAD; teot <= tx_eoft; end
          end else begin
            tx_underrun <= 1'b1; tabt <= 1'b1; ts <= tw == 2'd3 ? T_EOF : T_FILL;
          end
          T_PAD: begin
            tcrc <= crc8(tcrc, 8'h00); tn <= tn + 5'd1;
            if (pad_end) ts <= T_CRC;
          end
          T_FILL: if (tw == 2'd3) ts <= T_EOF;
          T_CRC: if (tw == 2'd3) ts <= T_EOF;
          T_EOF: if (tw == 2'd0) begin
            // the RD before the K28.5 picks D21.4 (RD-) or D21.5 (RD+)
            tos <= {trd ? D21_5 : D21_4, {2{tabt ? D21_7 : teot ? D21_3 : D21_6}}};
            if (!tabt) tx_done <= 1'b1;
          end else if (tw == 2'd3) begin ts <= T_GAP; tgap <= '0; tabt <= 1'b0; end
        endcase
      end
    end

  // ---------------- receiver ----------------
  logic        rx_q, raln, rrd, rwk, rf, rsofi;
  logic [9:0]  rsh;
  logic [3:0]  rph;                     // bit position; a symbol is complete at 0
  logic [1:0]  rw;                      // position of the next character in its word
  logic [15:0] rc;                      // ordered set characters 1, 2
  logic [1:0]  rosc;                    // ordered sets since alignment, up to 3
  logic [11:0] rn;                      // frame bytes (saturates)
  logic [31:0] rcrc;
  logic [7:0]  p0, p1, p2, p3, p4;      // five byte delay, p4 oldest

  wire        comma = rsh == 10'b0011111010 || rsh == 10'b1100000101;
  wire        sym_rdy = raln && rph == 4'd0;
  wire [5:0]  dx = d6(rsh[9:4]);
  wire        k28 = rsh[9:4] == 6'b001111 || rsh[9:4] == 6'b110000;
  wire [2:0]  dy = d4(rsh[3:0], k28, rsh[9:4] == 6'b001111);
  wire        kx = k28 || ((dx[4:0] == 5'd23 || dx[4:0] == 5'd27 || dx[4:0] == 5'd29 || dx[4:0] == 5'd30)
                           && (rsh[3:0] == 4'b0111 || rsh[3:0] == 4'b1000));
  wire [7:0]  db = {dy, k28 ? 5'd28 : dx[4:0]};
  wire [10:0] e_same = enc(db, kx, rrd);
  wire        c_ok = (dx[5] || k28) && e_same[10:1] == rsh;
  wire [8:0]  rsym = {kx, db};
  // a good character that fits its place in the word
  wire        ch_ok = c_ok && (rw == 2'd0 ? !kx || rsym == K28_5 : !kx);
  wire        os_end = sym_rdy && ch_ok && rwk && rw == 2'd3;
  wire [23:0] os = {rc, db};
  wire        is_eof = os[15:0] == {2{D21_6}} || os[15:0] == {2{D21_3}} || os[15:0] == {2{D21_7}};
  wire        eof_ok = is_eof && (os[23:16] == D21_4 || os[23:16] == D21_5);
  wire        is_sof = os == OS_SOFI || os == OS_SOFN;
  // a frame ends: an ordered set in a frame, or a bad character
  wire        f_end = rf && sym_rdy && (!ch_ok || os_end);
  wire        f_abt = !ch_ok || !eof_ok || os[15:0] == {2{D21_7}};
  wire        rr_rx = os_end && rx_sync && os == OS_RRDY;

  always_ff @(posedge clk or negedge rst_n)
    if (!rst_n) begin
      rx_q <= 1'b0; rsh <= '0; rph <= '0; rrd <= 1'b0; raln <= 1'b0; rw <= '0; rwk <= 1'b0; rc <= '0;
      rosc <= '0; rx_sync <= 1'b0; rf <= 1'b0; rsofi <= 1'b0; rn <= '0; rcrc <= '0;
      {p0, p1, p2, p3, p4} <= '0;
      err_code <= 1'b0; err_word <= 1'b0;
      rx_valid <= 1'b0; rx_data <= '0; rx_last <= 1'b0; rx_stat <= '0; rx_frag <= 1'b0;
    end else begin
      err_code <= 1'b0; err_word <= 1'b0; rx_valid <= 1'b0; rx_frag <= 1'b0;
      rx_q <= rx_p; rsh <= {rsh[8:0], rx_q};
      rph <= rph == 4'd9 ? 4'd0 : rph + 4'd1;
      if (!raln) begin
        if (comma) begin raln <= 1'b1; rph <= 4'd1; rrd <= !rsh[9]; rw <= 2'd1; rwk <= 1'b1; rosc <= '0; end
      end else if (sym_rdy) begin
        rw <= rw + 2'd1;
        if (!ch_ok) begin
          err_code <= 1'b1; raln <= 1'b0; rx_sync <= 1'b0; rf <= 1'b0;
        end else begin
          rrd <= e_same[0];
          if (rw == 2'd0) rwk <= kx;
          if (rw == 2'd1 || rw == 2'd2) rc <= {rc[7:0], db};
          if (os_end) begin
            if (rosc != 2'd3) rosc <= rosc + 2'd1;
            if (rosc == 2'd2) rx_sync <= 1'b1;
            if (rx_sync) begin
              rf <= is_sof;
              if (is_sof) begin rn <= '0; rcrc <= '1; rsofi <= os == OS_SOFI; end
              if (!rf && eof_ok) err_word <= 1'b1;
            end
          end
          // a data character
          if (!kx && (rw == 2'd0 || !rwk)) begin
            if (rf) begin
              rcrc <= crc8(rcrc, db);
              if (rn != 12'hFFF) rn <= rn + 12'd1;
              {p4, p3, p2, p1, p0} <= {p3, p2, p1, p0, db};
              if (rn >= 12'd5) begin rx_valid <= 1'b1; rx_data <= p4; rx_last <= 1'b0; end
            end else if (rx_sync && rw == 2'd0) err_word <= 1'b1;
          end
        end
        // end of a frame: its last byte and status, or a fragment
        if (f_end) begin
          if (rn >= 12'd5) begin
            rx_valid <= 1'b1; rx_data <= p4; rx_last <= 1'b1;
            rx_stat <= {rsofi, ch_ok && eof_ok && os[15:0] == {2{D21_3}}, f_abt,
                        rn < 12'd28 || rn > 12'd2140, rcrc != RESIDUE};
          end else rx_frag <= 1'b1;
        end
      end
    end

  // ---------------- credit ----------------
  wire sof_tx = sym_end && start && ts == T_GAP;
  always_ff @(posedge clk or negedge rst_n)
    if (!rst_n) begin credit_used <= '0; rr_pend <= '0; end
    else begin
      if (sof_tx && !(rr_rx && credit_used != 4'd0)) begin
        if (credit_used != 4'd15) credit_used <= credit_used + 4'd1;
      end else if (!sof_tx && rr_rx && credit_used != 4'd0) credit_used <= credit_used - 4'd1;
      if (f_end && !(sym_end && send_rr)) begin
        if (rr_pend != 4'd15) rr_pend <= rr_pend + 4'd1;
      end else if (!f_end && sym_end && send_rr) rr_pend <= rr_pend - 4'd1;
    end
endmodule
