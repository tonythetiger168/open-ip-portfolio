// SPDX-License-Identifier: Apache-2.0
// ============================================================================
// USB3_2_top v2.0: USB 3.2-style SuperSpeed link layer, one lane (header
// packets with sequence numbers, CRC-16 and a CRC-5 link control word, data
// packet payloads with CRC-32, link commands, header buffer credits, retry
// and recovery)
// ----------------------------------------------------------------------------
//  - Line: a PIPE-style symbol interface, one symbol per clk (8b/10b,
//    scrambling and the LTSSM belong to the PHY). tx_k / rx_k mark K
//    symbols: SHP (FB), SDP (5C), END (FD), EDB (7C), SLC (DC), EPF (F7).
//    Between packets the transmitter sends data 00 (logical idle).
//    Multi-byte fields are sent most significant byte first.
//  - Header packet (HP): SHP SHP SHP EPF, 12 header bytes, CRC-16 of them
//    (100B, initial value all ones, bit 7 of each byte first, sent
//    inverted), link control word. Link control word = {CRC-5, 8'h00,
//    seq[2:0]}; CRC-5 (x^5+x^2+1, initial value all ones, bit 10 first,
//    inverted) covers bits 10:0.
//  - Data packet: a header packet whose type (header byte 0, bits 4:0) is
//    01000 (DP) is followed at once by its payload (DPP): SDP SDP SDP EPF,
//    0..MAXD bytes, CRC-32 of them (04C11DB7, initial value all ones, bit 7
//    first, sent inverted), END END END EPF. EDB EDB EDB EPF in place of
//    the END set aborts the payload.
//  - Link command (LC): SLC SLC SLC EPF, then the link command word twice.
//    Link command word = {CRC-5, info[10:0]}; info: LGOOD_n 000_0000_0nnn,
//    LCRD_x 000_1000_00xx, LRTY 001_0000_0000, LBAD 001_1000_0000. The
//    first copy with a good CRC-5 is used; both bad: ev_lc_bad.
//  - Link: link_up is U0 from the LTSSM. On link_up the layer advertises:
//    it sends LGOOD_n for the last header packet it received (Header
//    Sequence Number Advertisement), then LCRD_A, LCRD_B, ... for each free
//    receive buffer (credit letters restart at A on both sides). ll_up
//    comes once the partner's LGOOD advertisement arrives: header packets
//    it acknowledges are released, the rest are sent again. Dropping
//    link_up keeps every buffer and sequence number. The layer pulses
//    recovery (the LTSSM is expected to drop link_up and raise it again)
//    and stops sending on: no advertisement or LGOOD for PEND_TO clocks
//    (PENDING_HP_TIMER), no credit for CRED_TO clocks while a header
//    packet waits for one (CREDIT_HP_TIMER), an LGOOD, LCRD or LBAD out of
//    order or with nothing to cover, a header packet with an unexpected
//    sequence number, or the third LBAD in a row.
//  - Transmit: packets are written into the replay buffer through tx_*
//    (up to TXN unacknowledged): 12 header bytes (fewer are padded with
//    zeros), then for a DP the payload (cut after MAXD bytes; the bytes
//    after the header of any other packet are dropped). A header packet
//    goes out when the link is up and the partner has a free buffer
//    (LCRD credit; a packet sent again in a retry does not take a new
//    one). It stays in the replay buffer until the LGOOD with its sequence
//    number arrives. An LBAD sends LRTY, then every unacknowledged packet
//    from the oldest.
//  - Receive: a good header packet with the expected sequence number is
//    stored in one of RXN buffers and acknowledged with LGOOD_n; one with a
//    bad CRC-16 / CRC-5 or a framing error sends LBAD, after which header
//    packets are ignored until LRTY arrives (ev_hp_bad). A DP's payload is
//    stored with it; a payload with a bad CRC-32, too long, aborted, cut
//    by a framing error or missing (another packet first) marks the packet
//    with rx_err (ev_dpp_bad; payloads are not retried by the link layer).
//    Packets are handed out through rx_* (header bytes, then payload); a
//    buffer is returned to the partner with LCRD_x once read out. A header
//    packet without a free buffer is dropped and not acknowledged
//    (ev_overflow). Link commands go out between packets, before header
//    packets.
//  Not implemented: the LTSSM, LFPS, ordered sets other than the packet
//  framing (SKP, TS1/TS2), 8b/10b and 128b/132b, power management link
//  commands (LGO_Ux, LAU, LXU, LPMA, LUP, LDN), the 3-of-4 symbol framing
//  tolerance, more than one lane, hub depth / delayed / deferred bits.
//  Field layouts follow the USB 3.2 link layer as we read it; they have
//  not been checked against a compliant device.
// ============================================================================
module USB3_2_top #(
  parameter int MAXD    = 32,       // payload bytes in a data packet
  parameter int TXN     = 4,        // unacknowledged header packets (power of 2, at most 4)
  parameter int RXN     = 4,        // receive header buffers (power of 2, at most 4)
  parameter int PEND_TO = 400,      // PENDING_HP_TIMER, clocks
  parameter int CRED_TO = 2000      // CREDIT_HP_TIMER, clocks
)(
  input  logic       clk,
  input  logic       rst_n,
  input  logic       link_up,         // U0
  output logic       recovery,        // pulse: enter Recovery
  output logic [7:0] tx_sym,
  output logic       tx_k,
  input  logic [7:0] rx_sym,
  input  logic       rx_k,
  input  logic       tx_valid,        // packet bytes in
  output logic       tx_ready,
  input  logic [7:0] tx_data,
  input  logic       tx_last,
  output logic       rx_valid,        // packet bytes out
  input  logic       rx_ready,
  output logic [7:0] rx_data,
  output logic       rx_last,
  output logic       rx_err,          // the packet's payload failed
  output logic       ll_up,           // advertisement done
  output logic       ev_hp_bad,       // header packet failed: LBAD sent
  output logic       ev_seq,          // header packet with an unexpected sequence number
  output logic       ev_lc_bad,       // link command with both copies bad
  output logic       ev_dpp_bad,      // payload failed
  output logic       ev_frame,        // framing error
  output logic       ev_proto,        // link command out of order or unknown
  output logic       ev_overflow,     // header packet without a free buffer
  output logic       ev_lbad,         // LBAD received: retry
  output logic       ev_timeout       // PENDING_HP_TIMER or CREDIT_HP_TIMER expired
);
  localparam logic [7:0] SHP = 8'hFB, SDP = 8'h5C, ENDS = 8'hFD, EDB = 8'h7C, SLC = 8'hDC, EPF = 8'hF7;
  localparam int PL = 12 + MAXD;                // bytes in a buffer
  localparam int LW = $clog2(MAXD + 13);
  localparam int TW = $clog2(TXN);
  localparam int QW = $clog2(RXN);
  localparam int IW = $clog2(TXN * PL);
  localparam int JW = $clog2(RXN * PL);
  localparam int PW = $clog2(PEND_TO + 1);
  localparam int CW = $clog2(CRED_TO + 1);

  function automatic logic [15:0] crc16_8(input logic [15:0] c, input logic [7:0] d);
    crc16_8 = c;
    for (int i = 7; i >= 0; i--)
      crc16_8 = {crc16_8[14:0], 1'b0} ^ ((crc16_8[15] ^ d[i]) ? 16'h100B : 16'h0);
  endfunction
  function automatic logic [31:0] crc32_8(input logic [31:0] c, input logic [7:0] d);
    crc32_8 = c;
    for (int i = 7; i >= 0; i--)
      crc32_8 = {crc32_8[30:0], 1'b0} ^ ((crc32_8[31] ^ d[i]) ? 32'h04C1_1DB7 : 32'h0);
  endfunction
  // a link command / control word: {CRC-5, info}
  function automatic logic [15:0] lcw(input logic [10:0] info);
    logic [4:0] c;
    c = 5'h1F;
    for (int i = 10; i >= 0; i--) c = {c[3:0], 1'b0} ^ ((c[4] ^ info[i]) ? 5'h05 : 5'h00);
    lcw = {~c, info};
  endfunction
  // byte hi / lo of a link command word (t: 0 LGOOD_v, 1 LCRD_v, 2 LRTY,
  // 3 LBAD); a header packet's link control word is LGOOD's
  function automatic logic [7:0] lcb(input logic [1:0] t, input logic [2:0] v, input logic hi);
    logic [15:0] w;
    case (t)
      2'd0:    w = lcw({8'd0, v});
      2'd1:    w = lcw({9'h020, v[1:0]});
      2'd2:    w = lcw(11'h100);
      default: w = lcw(11'h180);
    endcase
    lcb = hi ? w[15:8] : w[7:0];
  endfunction
  // a byte in the receive buffers
  function automatic logic [JW-1:0] ridx(input logic [QW-1:0] s, input logic [LW-1:0] o);
    ridx = JW'(s) * JW'(PL) + JW'(o);
  endfunction
  function automatic logic lcw_ok(input logic [15:0] w);
    lcw_ok = lcw(w[10:0]) == w;
  endfunction
  // a - b in 1..7 (mod 16): a is ahead of b
  function automatic logic ahead(input logic [3:0] a, input logic [3:0] b);
    logic [3:0] d;
    d = a - b;
    ahead = d != 4'd0 && !d[3];
  endfunction

  // ---------------- link state ----------------
  typedef enum logic [1:0] {L_DOWN, L_ADV, L_UP, L_REC} ll_t;
  ll_t           ll;
  assign ll_up = ll == L_UP;

  // ---------------- transmit state ----------------
  typedef enum logic [1:0] {T_IDLE, T_LC, T_HP, T_DPP} ts_t;
  ts_t           tst;
  logic [LW-1:0] tcnt;
  logic [1:0]    tlt;                   // link command being sent: 0 LGOOD, 1 LCRD, 2 LRTY, 3 LBAD
  logic [2:0]    tlv;                   // its sequence number / letter
  logic [3:0]    tcur;                  // header packet being sent
  logic [LW-1:0] tlen;                  // its bytes in the buffer
  logic          tdp;                   // it has a payload
  logic [15:0]   tc16;
  logic [31:0]   tc32;
  logic [7:0]    rb [0:TXN*PL-1];       // replay buffer
  logic [LW-1:0] rlen [0:TXN-1];
  logic [3:0]    wr_seq, tx_seq, nsent, ackd, cnext;  // next written; next sent; next new; last acknowledged; next to take a credit
  logic [LW-1:0] widx;
  logic          rp_req, lrty_p;
  logic [1:0]    lbn;                   // LBADs in a row
  logic [2:0]    cr;                    // credits
  logic [1:0]    tlet;                  // next credit letter expected
  logic [PW-1:0] ptmr;
  logic [CW-1:0] ctmr;
  // ---------------- receive state ----------------
  typedef enum logic [2:0] {R_IDLE, R_OS, R_HP, R_DPP, R_DE, R_LC} rs_t;
  rs_t           rst;
  logic [7:0]    ost;                   // ordered set symbol
  logic [1:0]    oc;                    // its count
  logic [LW-1:0] rcnt;
  logic [31:0]   rdl;                   // last 4 bytes, [7:0] newest
  logic [15:0]   rc16;
  logic [31:0]   rc32;
  logic          rlong;
  logic [2:0]    rxs;                   // next sequence number expected
  logic          wait_lrty;
  logic          dcol;                  // collecting a payload into the open buffer
  logic          hroom;                 // a free buffer when the header packet started
  logic          rdp;                   // the header packet is a DP
  logic [7:0]    rf [0:RXN*PL-1];       // receive buffers
  logic [LW-1:0] rq_len [0:RXN-1];
  logic          rq_err [0:RXN-1];
  logic [QW:0]   rqw, rqr;
  logic [LW-1:0] rgot;
  logic          lg_adv, lbad_p;
  logic [2:0]    lg_cnt, lc_cnt;        // LGOODs / LCRDs to send
  logic [1:0]    rlet;                  // next credit letter to send

  // ---------------- transmit ----------------
  wire [3:0]   t_eff = rp_req || ahead(ackd + 4'd1, tx_seq) ? ackd + 4'd1 : tx_seq;
  wire         t_need = t_eff == cnext;
  wire [3:0]   t_out = nsent - ackd - 4'd1;     // sent, unacknowledged
  wire         t_hp = ll == L_UP && t_eff != wr_seq && (!t_need || cr != 3'd0);
  wire         t_lc = (ll == L_ADV || ll == L_UP) && (lg_adv || lrty_p || lbad_p || lg_cnt != 3'd0 || lc_cnt != 3'd0);
  // link command chosen when idle
  wire [1:0]   t_lt = lg_adv || !lrty_p && !lbad_p && lg_cnt != 3'd0 ? 2'd0 : lrty_p ? 2'd2 : lbad_p ? 2'd3 : 2'd1;
  wire [2:0]   t_lv = lg_adv ? rxs - 3'd1 : lg_cnt != 3'd0 ? rxs - lg_cnt : {1'b0, rlet};
  wire [TW-1:0] t_slot = t_eff[TW-1:0];
  wire [7:0]   t_hb = LW'(tcnt - LW'(4)) < tlen ? rb[IW'(tcur[TW-1:0]) * IW'(PL) + IW'(LW'(tcnt - LW'(4)))] : 8'h00;
  wire [7:0]   t_db = rb[IW'(tcur[TW-1:0]) * IW'(PL) + IW'(LW'(tcnt - LW'(4)) + LW'(12))];
  wire [LW-1:0] t_dn = tlen > LW'(12) ? LW'(tlen - LW'(12)) : '0;   // payload bytes
  // a free slot, not the one being sent
  assign tx_ready = wr_seq - ackd - 4'd1 < 4'(TXN) &&
                    !((tst == T_HP || tst == T_DPP) && wr_seq[TW-1:0] == tcur[TW-1:0]);

  // ---------------- receive ----------------
  wire [31:0]  r_nb = {rdl[23:0], rx_sym};      // with the byte now
  wire [15:0]  r_w1 = r_nb[31:16], r_w2 = r_nb[15:0];
  wire [JW-1:0] r_rd = JW'(rqr[QW-1:0]) * JW'(PL) + JW'(rgot);
  assign rx_valid = rqw != rqr;
  assign rx_data = rf[r_rd];
  assign rx_last = rgot == rq_len[rqr[QW-1:0]] - 1'b1;
  assign rx_err = rq_err[rqr[QW-1:0]];

  always_ff @(posedge clk or negedge rst_n)
    if (!rst_n) begin
      ll <= L_DOWN;
      tst <= T_IDLE; tcnt <= '0; tlt <= '0; tlv <= '0; tcur <= '0; tlen <= '0; tdp <= 1'b0; tc16 <= '0; tc32 <= '0;
      wr_seq <= '0; tx_seq <= '0; nsent <= '0; ackd <= 4'hF; cnext <= '0; widx <= '0;
      rp_req <= 1'b0; lrty_p <= 1'b0; lbn <= '0; cr <= '0; tlet <= '0; ptmr <= '0; ctmr <= '0;
      rst <= R_IDLE; ost <= '0; oc <= '0; rcnt <= '0; rdl <= '0; rc16 <= '0; rc32 <= '0; rlong <= 1'b0;
      rxs <= '0; wait_lrty <= 1'b0; dcol <= 1'b0; hroom <= 1'b0; rdp <= 1'b0; rqw <= '0; rqr <= '0; rgot <= '0;
      lg_adv <= 1'b0; lbad_p <= 1'b0; lg_cnt <= '0; lc_cnt <= '0; rlet <= '0;
      tx_sym <= '0; tx_k <= 1'b0; recovery <= 1'b0;
      {ev_hp_bad, ev_seq, ev_lc_bad, ev_dpp_bad, ev_frame, ev_proto, ev_overflow, ev_lbad, ev_timeout} <= '0;
    end else begin : b_main
      logic rec, lg_inc, lc_inc, lg_dec, lc_dec, cr_inc, cr_dec, commit, cerr;
      rec = 1'b0; lg_inc = 1'b0; lc_inc = 1'b0; lg_dec = 1'b0; lc_dec = 1'b0; cr_inc = 1'b0; cr_dec = 1'b0;
      commit = 1'b0; cerr = 1'b0;
      recovery <= 1'b0;
      {ev_hp_bad, ev_seq, ev_lc_bad, ev_dpp_bad, ev_frame, ev_proto, ev_overflow, ev_lbad, ev_timeout} <= '0;

      // ---------------- transmit ----------------
      tx_sym <= 8'h00; tx_k <= 1'b0;
      if (tst == T_IDLE) begin
        if (t_lc) begin
          tx_sym <= SLC; tx_k <= 1'b1; tst <= T_LC; tcnt <= LW'(1); tlt <= t_lt; tlv <= t_lv;
          if (lg_adv) lg_adv <= 1'b0;
          else if (lrty_p) lrty_p <= 1'b0;
          else if (lbad_p) lbad_p <= 1'b0;
          else if (lg_cnt != 3'd0) lg_dec = 1'b1;
          else begin lc_dec = 1'b1; rlet <= rlet + 2'd1; end
        end else if (t_hp) begin
          tx_sym <= SHP; tx_k <= 1'b1; tst <= T_HP; tcnt <= LW'(1);
          tcur <= t_eff; tlen <= rlen[t_slot]; tdp <= rb[IW'(t_slot) * IW'(PL)][4:0] == 5'b01000;
          tc16 <= 16'hFFFF; rp_req <= 1'b0;
          if (t_eff == nsent) nsent <= nsent + 4'd1;
          if (t_need) begin cnext <= cnext + 4'd1; cr_dec = 1'b1; end
        end
      end else if (tst == T_LC) begin
        tcnt <= tcnt + 1'b1;
        case (tcnt)
          LW'(1), LW'(2): begin tx_sym <= SLC; tx_k <= 1'b1; end
          LW'(3): begin tx_sym <= EPF; tx_k <= 1'b1; end
          LW'(4), LW'(6): tx_sym <= lcb(tlt, tlv, 1'b1);
          LW'(5): tx_sym <= lcb(tlt, tlv, 1'b0);
          default: begin tx_sym <= lcb(tlt, tlv, 1'b0); tst <= T_IDLE; end
        endcase
      end else if (tst == T_HP) begin
        tcnt <= tcnt + 1'b1;
        if (tcnt < LW'(3)) begin tx_sym <= SHP; tx_k <= 1'b1; end
        else if (tcnt == LW'(3)) begin tx_sym <= EPF; tx_k <= 1'b1; end
        else if (tcnt < LW'(16)) begin tx_sym <= t_hb; tc16 <= crc16_8(tc16, t_hb); end
        else if (tcnt == LW'(16)) tx_sym <= ~tc16[15:8];
        else if (tcnt == LW'(17)) tx_sym <= ~tc16[7:0];
        else if (tcnt == LW'(18)) tx_sym <= lcb(2'd0, tcur[2:0], 1'b1);
        else begin
          tx_sym <= lcb(2'd0, tcur[2:0], 1'b0);
          if (tdp) begin tst <= T_DPP; tcnt <= '0; tc32 <= 32'hFFFF_FFFF; end
          else begin tst <= T_IDLE; tx_seq <= tcur + 4'd1; end
        end
      end else begin
        // payload: SDP x3, EPF, t_dn bytes, CRC-32, END x3, EPF
        tcnt <= tcnt + 1'b1;
        if (tcnt < LW'(3)) begin tx_sym <= SDP; tx_k <= 1'b1; end
        else if (tcnt == LW'(3)) begin tx_sym <= EPF; tx_k <= 1'b1; end
        else if (tcnt < t_dn + LW'(4)) begin tx_sym <= t_db; tc32 <= crc32_8(tc32, t_db); end
        else if (tcnt < t_dn + LW'(8)) tx_sym <= 8'(~tc32 >> {2'(LW'(7) - (tcnt - t_dn)), 3'b000});
        else if (tcnt < t_dn + LW'(11)) begin tx_sym <= ENDS; tx_k <= 1'b1; end
        else begin tx_sym <= EPF; tx_k <= 1'b1; tst <= T_IDLE; tx_seq <= tcur + 4'd1; end
      end
      // writing packets into the replay buffer
      if (tx_valid && tx_ready) begin
        rb[IW'(wr_seq[TW-1:0]) * IW'(PL) + IW'(widx)] <= tx_data;
        widx <= widx + 1'b1;
        if (tx_last || widx == LW'(PL - 1)) begin
          rlen[wr_seq[TW-1:0]] <= widx + 1'b1; widx <= '0; wr_seq <= wr_seq + 4'd1;
        end
      end
      // timers
      if (!(ll == L_ADV || ll == L_UP && t_out != 4'd0)) ptmr <= '0;
      else if (ptmr == PW'(PEND_TO)) begin ptmr <= '0; ev_timeout <= 1'b1; rec = 1'b1; end
      else ptmr <= ptmr + 1'b1;
      if (!(ll == L_UP && t_eff != wr_seq && t_need && cr == 3'd0)) ctmr <= '0;
      else if (ctmr == CW'(CRED_TO)) begin ctmr <= '0; ev_timeout <= 1'b1; rec = 1'b1; end
      else ctmr <= ctmr + 1'b1;

      // ---------------- receive ----------------
      if (!link_up) ;
      else if (!rx_k) begin
        // a data byte
        if (rst == R_HP || rst == R_LC || rst == R_DPP) begin
          rdl <= r_nb; rcnt <= rcnt + 1'b1;
        end
        if (rst == R_HP) begin
          if (rcnt < LW'(12)) begin
            rc16 <= crc16_8(rc16, rx_sym);
            if (rcnt == '0) rdp <= rx_sym[4:0] == 5'b01000;
            if (hroom) rf[ridx(rqw[QW-1:0], rcnt)] <= rx_sym;
          end
          if (rcnt == LW'(15)) begin
            rst <= R_IDLE;
            // (ignored while waiting for LRTY)
            if (!wait_lrty) begin
              if (r_nb[31:16] != ~rc16 || !lcw_ok(r_nb[15:0])) begin
                ev_hp_bad <= 1'b1; lbad_p <= 1'b1; wait_lrty <= 1'b1;
              end else if (r_nb[2:0] != rxs) begin ev_seq <= 1'b1; rec = 1'b1; end
              else if (!hroom) ev_overflow <= 1'b1;
              else begin
                rxs <= rxs + 3'd1; lg_inc = 1'b1;
                if (rdp) dcol <= 1'b1;
                else commit = 1'b1;
              end
            end
          end
        end else if (rst == R_DPP) begin
          // a byte four behind is past the CRC window
          if (rcnt >= LW'(4)) begin
            rc32 <= crc32_8(rc32, rdl[31:24]);
            if (rcnt - LW'(4) == LW'(MAXD)) rlong <= 1'b1;
            else if (dcol && !rlong) rf[ridx(rqw[QW-1:0], LW'(rcnt - LW'(4) + LW'(12)))] <= rdl[31:24];
          end
        end else if (rst == R_LC) begin
          if (rcnt == LW'(3)) begin : b_lc
            logic [10:0] i;
            logic [2:0]  k;                     // packets an advertisement acknowledges
            rst <= R_IDLE;
            i = lcw_ok(r_w1) ? r_w1[10:0] : r_w2[10:0];
            k = i[2:0] - ackd[2:0];
            if (!lcw_ok(r_w1) && !lcw_ok(r_w2)) ev_lc_bad <= 1'b1;
            else if (ll == L_ADV || ll == L_UP) begin
              if (i[10:3] == 8'h00) begin
                // LGOOD_n
                if (ll == L_ADV) begin
                  if ({1'b0, k} <= t_out) begin
                    ll <= L_UP; ackd <= ackd + {1'b0, k};
                    tx_seq <= ackd + {1'b0, k} + 4'd1;
                    cnext <= ackd + {1'b0, k} + 4'd1;
                  end else begin ev_proto <= 1'b1; rec = 1'b1; end
                end else if (t_out != 4'd0 && i[2:0] == 3'(ackd + 4'd1)) begin
                  ackd <= ackd + 4'd1; lbn <= '0; ptmr <= '0;
                end else begin ev_proto <= 1'b1; rec = 1'b1; end
              end else if (i[10:2] == 9'h020) begin
                // LCRD_x
                if (i[1:0] == tlet && cr != 3'(RXN)) begin cr_inc = 1'b1; tlet <= tlet + 2'd1; ctmr <= '0; end
                else begin ev_proto <= 1'b1; rec = 1'b1; end
              end else if (i == 11'h100) begin
                // LRTY
                wait_lrty <= 1'b0;
              end else if (i == 11'h180) begin
                // LBAD
                if (ll == L_UP && t_out != 4'd0) begin
                  ev_lbad <= 1'b1; lrty_p <= 1'b1; rp_req <= 1'b1; ptmr <= '0; lbn <= lbn + 2'd1;
                  if (lbn == 2'd2) rec = 1'b1;
                end else begin ev_proto <= 1'b1; rec = 1'b1; end
              end else ev_proto <= 1'b1;
            end
          end
        end else if (rst == R_OS || rst == R_DE) begin
          // a data byte inside an ordered set
          ev_frame <= 1'b1; rst <= R_IDLE;
          if (rst == R_DE && dcol) begin commit = 1'b1; cerr = 1'b1; ev_dpp_bad <= 1'b1; end
        end
      end else begin
        // a K symbol: ordered sets
        if (rst == R_IDLE) begin
          if (rx_sym == SHP || rx_sym == SDP || rx_sym == SLC) begin rst <= R_OS; ost <= rx_sym; oc <= 2'd1; end
          else ev_frame <= 1'b1;
        end else if (rst == R_OS || rst == R_DE) begin
          if (rx_sym == ost && oc != 2'd3) oc <= oc + 2'd1;
          else if (rx_sym == EPF && oc == 2'd3) begin
            rcnt <= '0; rst <= R_IDLE;
            if (rst == R_DE) begin
              // the payload's end
              if (dcol) begin
                commit = 1'b1;
                if (ost == EDB || rcnt < LW'(4) || rlong || rdl != ~rc32) begin cerr = 1'b1; ev_dpp_bad <= 1'b1; end
              end
            end else begin
              // a packet's start; a DP's payload must come first
              if (dcol && ost != SDP) begin commit = 1'b1; cerr = 1'b1; ev_dpp_bad <= 1'b1; end
              if (ost == SHP) begin rst <= R_HP; rc16 <= 16'hFFFF; hroom <= (QW+1)'(rqw - rqr) + (QW+1)'(commit) < (QW+1)'(RXN); end
              else if (ost == SLC) rst <= R_LC;
              else begin
                // a payload; one no DP header asked for is skipped
                rst <= R_DPP; rc32 <= 32'hFFFF_FFFF; rlong <= 1'b0;
              end
            end
          end else begin
            ev_frame <= 1'b1; rst <= R_IDLE;
            if (rst == R_DE && dcol) begin commit = 1'b1; cerr = 1'b1; ev_dpp_bad <= 1'b1; end
          end
        end else if (rst == R_DPP && (rx_sym == ENDS || rx_sym == EDB)) begin
          rst <= R_DE; ost <= rx_sym; oc <= 2'd1;
        end else begin
          // a K symbol inside a packet
          ev_frame <= 1'b1; rst <= R_IDLE;
          if (rst == R_HP && !wait_lrty) begin ev_hp_bad <= 1'b1; lbad_p <= 1'b1; wait_lrty <= 1'b1; end
          if (rst == R_DPP && dcol) begin commit = 1'b1; cerr = 1'b1; ev_dpp_bad <= 1'b1; end
        end
      end
      // reading packets out
      if (rx_valid && rx_ready) begin
        rgot <= rgot + 1'b1;
        if (rx_last) begin rgot <= '0; rqr <= rqr + 1'b1; lc_inc = 1'b1; end
      end

      // the link
      if (!link_up) begin
        ll <= L_DOWN; tst <= T_IDLE; tx_sym <= 8'h00; tx_k <= 1'b0; rst <= R_IDLE;
        if (dcol) begin commit = 1'b1; cerr = 1'b1; end
      end else if (ll == L_DOWN) begin
        // advertisement: LGOOD, then LCRD for each free buffer
        ll <= L_ADV; lg_adv <= 1'b1; lrty_p <= 1'b0; lbad_p <= 1'b0; wait_lrty <= 1'b0; rp_req <= 1'b0; lbn <= '0;
        tlet <= '0; rlet <= '0; ptmr <= '0; ctmr <= '0;
      end else if (rec && ll != L_REC) begin
        ll <= L_REC; recovery <= 1'b1;
      end
      // a packet into the receive buffers: the header, and a DP's payload
      // unless it failed
      if (commit) begin
        rq_len[rqw[QW-1:0]] <= dcol && !cerr ? LW'(12) + LW'(rcnt - LW'(4)) : LW'(12);
        rq_err[rqw[QW-1:0]] <= cerr;
        rqw <= rqw + 1'b1; dcol <= 1'b0;
      end
      if (link_up && ll == L_DOWN) begin
        cr <= '0; lg_cnt <= '0;
        lc_cnt <= 3'(RXN) - 3'(rqw - rqr) - 3'(commit) + 3'(lc_inc);
      end else begin
        cr <= cr + 3'(cr_inc) - 3'(cr_dec);
        lg_cnt <= lg_cnt + 3'(lg_inc) - 3'(lg_dec);
        lc_cnt <= lc_cnt + 3'(lc_inc) - 3'(lc_dec);
      end
    end
endmodule
