// SPDX-License-Identifier: Apache-2.0
// ============================================================================
// PCIe_top v2.0: PCI Express-style data link layer, one lane (TLP framing
// with sequence numbers and LCRC, Ack/Nak with a replay buffer and replay
// timer, DLLPs with CRC-16, flow control initialization and header credits)
// ----------------------------------------------------------------------------
//  - Line: a PIPE-style symbol interface, one symbol per clk (8b/10b and
//    scrambling belong to the PHY). tx_k / rx_k mark K symbols: STP (FB),
//    SDP (5C), END (FD), EDB (FE). Between packets the transmitter sends
//    data 00 (logical idle) for at least one symbol.
//  - TLP: STP, {0000, seq[11:8]}, seq[7:0], 1..MAXLEN bytes, LCRC, END.
//    LCRC = CRC-32 (04C11DB7, initial value all ones, bit 7 of each byte
//    first) of the two sequence bytes and the TLP bytes, sent inverted,
//    bits 31:24 first. A TLP ended by EDB whose LCRC is not inverted is
//    nullified and dropped silently.
//  - DLLP: SDP, 4 bytes, CRC-16 (100B, initial value all ones, bit 7 first,
//    sent inverted, bits 15:8 first), END. Byte 0 is the type: Ack 00 and
//    Nak 10 (bytes 2..3 = {0000, seq}), InitFC1-P 40, InitFC2-P C0,
//    UpdateFC-P 80 (bytes 1..2 = {00, HdrFC[7:0], 00, DataFC[11:8]},
//    byte 3 = DataFC[7:0]). Only header credits are used; DataFC is sent
//    as 0 (infinite) and ignored on receipt.
//  - Link: dl_up comes once flow control is initialized: with link_up the
//    layer sends InitFC1 every FC_GAP clocks until it receives an InitFC1
//    or InitFC2, then InitFC2 until it receives an InitFC2, an UpdateFC or
//    a good TLP. Dropping link_up resets the whole layer (both buffers are
//    emptied, sequence numbers restart at 0).
//  - Transmit: a TLP is written into the replay buffer through tlp_* (up
//    to TXN unacknowledged; a TLP longer than MAXLEN is cut), gets the next
//    sequence number and is sent when the link is up and the receiver has
//    header credit (none needed when its InitFC advertised 0). It stays in
//    the replay buffer until an Ack or Nak covers it. A Nak, or the replay
//    timer (REPLAY_TO clocks with unacknowledged TLPs and no progress),
//    sends again every unacknowledged TLP from the oldest; the 4th replay
//    without progress pulses retrain. An Ack / Nak for a sequence number
//    not sent pulses ev_dllp_proto.
//  - Receive: a good TLP with the expected sequence number is acknowledged
//    and handed out through rx_* once its LCRC is checked; one already
//    received is dropped and acknowledged again (ev_tlp_dup); one ahead of
//    it, a bad LCRC or a framing error makes a Nak (once until a good TLP
//    arrives; ev_tlp_seq / ev_tlp_bad). The receive buffer holds RXN TLPs;
//    RXN header credits are advertised and one is returned (UpdateFC) as
//    each TLP is read out; UpdateFC is also repeated every UPD_GAP clocks.
//    A TLP without room is dropped and not acknowledged (ev_overflow).
//    Acks and Naks are sent between packets, before anything else.
//  Not implemented: the physical layer (LTSSM, ordered sets, 8b/10b,
//  scrambling, skip), 128b/130b, flits, more than one lane, non-posted and
//  completion credits, data credits, virtual channels, power management
//  DLLPs, the AckNak latency timer (Acks go out as soon as possible),
//  surprise-down and data link feature exchange. Field layouts follow
//  PCIe as we read it; they have not been checked against a compliant
//  device.
// ============================================================================
module PCIe_top #(
  parameter int MAXLEN    = 32,       // bytes in a TLP
  parameter int TXN       = 4,        // unacknowledged TLPs (power of 2)
  parameter int RXN       = 4,        // TLPs in the receive buffer (power of 2)
  parameter int REPLAY_TO = 600,      // replay timer, clocks
  parameter int FC_GAP    = 32,       // InitFC repeat, clocks
  parameter int UPD_GAP   = 1024      // UpdateFC repeat, clocks
)(
  input  logic       clk,
  input  logic       rst_n,
  // PHY
  input  logic       link_up,
  output logic [7:0] tx_sym,
  output logic       tx_k,
  input  logic [7:0] rx_sym,
  input  logic       rx_k,
  // transmit TLPs
  input  logic       tlp_valid,
  output logic       tlp_ready,
  input  logic [7:0] tlp_data,
  input  logic       tlp_last,
  // received TLPs
  output logic       rx_valid,
  input  logic       rx_ready,
  output logic [7:0] rx_data,
  output logic       rx_last,
  // status and events
  output logic       dl_up,
  output logic       retrain,
  output logic       ev_tlp_bad,      // bad LCRC or framing: Nak
  output logic       ev_tlp_seq,      // sequence number ahead: Nak
  output logic       ev_tlp_dup,      // sequence number already received
  output logic       ev_tlp_null,     // nullified TLP dropped
  output logic       ev_overflow,     // TLP without room dropped
  output logic       ev_dllp_bad,     // DLLP CRC-16 error
  output logic       ev_dllp_proto,   // Ack / Nak out of range, unknown DLLP type
  output logic       ev_frame,        // framing error
  output logic       ev_nak,          // Nak received
  output logic       ev_replay        // replay timer expired
);
  localparam logic [7:0] STP = 8'hFB, SDP = 8'h5C, ENDS = 8'hFD, EDB = 8'hFE;
  localparam logic [7:0] T_ACK = 8'h00, T_NAK = 8'h10, T_IFC1 = 8'h40, T_IFC2 = 8'hC0, T_UFC = 8'h80;
  localparam int LW = $clog2(MAXLEN + 8);
  localparam int BW = $clog2(MAXLEN);
  localparam int TW = $clog2(TXN);
  localparam int IW = $clog2(TXN * MAXLEN);
  localparam int RW = $clog2(RXN * MAXLEN);
  localparam int QW = $clog2(RXN);
  localparam int RTW = $clog2(REPLAY_TO + 1);
  localparam int GW = $clog2(UPD_GAP + 1);

  function automatic logic [31:0] crc32_8(input logic [31:0] c, input logic [7:0] d);
    crc32_8 = c;
    for (int i = 7; i >= 0; i--)
      crc32_8 = {crc32_8[30:0], 1'b0} ^ ((crc32_8[31] ^ d[i]) ? 32'h04C1_1DB7 : 32'h0);
  endfunction
  function automatic logic [15:0] crc16_32(input logic [31:0] d);
    crc16_32 = 16'hFFFF;
    for (int i = 31; i >= 0; i--)
      crc16_32 = {crc16_32[14:0], 1'b0} ^ ((crc16_32[15] ^ d[i]) ? 16'h100B : 16'h0);
  endfunction
  // a - b in 1..2047 (mod 4096): a is ahead of b
  function automatic logic ahead(input logic [11:0] a, input logic [11:0] b);
    logic [11:0] d;
    d = a - b;
    ahead = d != 12'd0 && !d[11];
  endfunction

  // ---------------- link state ----------------
  typedef enum logic [1:0] {DL_INACTIVE, DL_FC1, DL_FC2, DL_ACTIVE} dl_t;
  dl_t         dls;
  logic [GW-1:0] fct;                   // InitFC / UpdateFC timer
  assign dl_up = dls == DL_ACTIVE;

  // ---------------- transmit state ----------------
  typedef enum logic [1:0] {T_IDLE, T_DLLP, T_TLP} ts_t;
  ts_t           tst;
  logic [LW-1:0] tcnt;
  logic [2:0]    tdt;                   // DLLP: 0 Ack, 1 Nak, 2 InitFC1, 3 InitFC2, 4 UpdateFC
  logic [11:0]   tdv;                   // its sequence number or header credits
  logic [15:0]   tdc;                   // its CRC, sent inverted
  logic [11:0]   tcur;                  // TLP being sent
  logic [LW-1:0] tlen;                  // its length
  logic [31:0]   tcrc;
  logic [7:0]    rb [0:TXN*MAXLEN-1];   // replay buffer, MAXLEN bytes a TLP
  logic [LW-1:0] rlen [0:TXN-1];
  logic [11:0]   wr_seq, tx_seq, nsent, ackd;  // next written; next sent; next new; last acknowledged
  logic [BW-1:0] widx;
  logic          rp_req;
  logic [1:0]    rnum;                  // replays without progress
  logic [RTW-1:0] rtmr;
  logic [7:0]    cl, cc;                // credit limit, credits consumed
  logic          cinf;                  // infinite header credit
  // ---------------- receive state ----------------
  typedef enum logic [1:0] {R_IDLE, R_TLP, R_DLLP} rs_t;
  rs_t           rst;
  logic [LW-1:0] rcnt;                  // data bytes in the packet
  logic [31:0]   rdl;                   // last 4 bytes, [7:0] newest
  logic [15:0]   rd2;                   // DLLP bytes 4..5
  logic [11:0]   rseq, nrs;             // TLP sequence number; next expected
  logic [31:0]   rcrc;
  logic          rlong;                 // TLP too long
  logic [7:0]    rf [0:RXN*MAXLEN-1];   // receive buffer
  logic [RW:0]   rwp, rcp, rrp;         // tentative write, committed write, read
  logic [LW-1:0] rq [0:RXN-1];          // lengths of the TLPs in it
  logic [QW:0]   rqw, rqr;
  logic [BW-1:0] rgot;                  // bytes read of the TLP at rqr
  logic [7:0]    ca;                    // credits allocated
  logic          ack_p, nak_p, nak_s, upd_p;

  // ---------------- transmit ----------------
  wire [11:0]  t_eff = rp_req || ahead(ackd + 12'd1, tx_seq) ? ackd + 12'd1 : tx_seq;
  wire         t_new = t_eff == nsent;
  // credit: (limit - (consumed + 1)) mod 256 below 128
  function automatic logic cred(input logic [7:0] l, input logic [7:0] c);
    /* verilator lint_off UNUSEDSIGNAL */
    logic [7:0] d;
    /* verilator lint_on UNUSEDSIGNAL */
    d = l - c - 8'd1;
    cred = !d[7];
  endfunction
  wire         t_cok = cinf || cred(cl, cc);
  wire         t_tlp = dl_up && t_eff != wr_seq && (!t_new || t_cok);
  wire         t_fc = (dls == DL_FC1 || dls == DL_FC2) && fct == '0;
  wire         t_go = tst == T_IDLE && (nak_p || ack_p || t_fc || upd_p && dl_up || t_tlp);
  // DLLP chosen when idle
  wire [2:0]   t_dt = nak_p ? 3'd1 : ack_p ? 3'd0 : t_fc ? (dls == DL_FC1 ? 3'd2 : 3'd3) : 3'd4;
  wire [11:0]  t_dv = nak_p || ack_p ? nrs - 12'd1 : {4'd0, ca};  // ca is RXN until the link is up
  // DLLP bytes 0..3
  function automatic logic [31:0] dllp(input logic [2:0] t, input logic [11:0] v);
    case (t)
      3'd0, 3'd1: dllp = {t[0] ? T_NAK : T_ACK, 8'd0, 4'd0, v};
      3'd2:       dllp = {T_IFC1, 2'b00, v[7:0], 14'd0};
      3'd3:       dllp = {T_IFC2, 2'b00, v[7:0], 14'd0};
      default:    dllp = {T_UFC, 2'b00, v[7:0], 14'd0};
    endcase
  endfunction
  function automatic logic [7:0] dbyte(input logic [2:0] t, input logic [11:0] v, input logic [1:0] i);
    logic [31:0] d;
    d = dllp(t, v);
    dbyte = 8'(d >> {~i, 3'b000});
  endfunction
  wire [7:0]   t_byte = rb[IW'(tcur[TW-1:0]) * IW'(MAXLEN) + IW'(BW'(tcnt - LW'(3)))];
  // a free slot, not the one being sent
  assign tlp_ready = dl_up && wr_seq - ackd - 12'd1 < 12'(TXN) && !(tst == T_TLP && wr_seq[TW-1:0] == tcur[TW-1:0]);
  // replay timer
  wire         t_out = nsent != ackd + 12'd1;  // sent, unacknowledged

  // ---------------- receive ----------------
  wire [31:0]  r_nb = {rdl[23:0], rx_sym};     // with the byte now
  wire [31:0]  r_crc_n = crc32_8(rcrc, rdl[31:24]);
  wire         r_room = rwp - rrp < (RW+1)'(RXN * MAXLEN);
  wire [11:0]  r_ack_seq = {rdl[11:8], rdl[7:0]};
  wire         r_rq_full = rqw - rqr == (QW+1)'(RXN);
  wire [LW-1:0] r_len = rq[rqr[QW-1:0]];
  assign rx_valid = rqw != rqr;
  assign rx_data = rf[rrp[RW-1:0]];
  assign rx_last = LW'(rgot) == r_len - 1'b1;

  always_ff @(posedge clk or negedge rst_n)
    if (!rst_n) begin
      dls <= DL_INACTIVE; fct <= '0;
      tst <= T_IDLE; tcnt <= '0; tdt <= '0; tdv <= '0; tdc <= '0; tcur <= '0; tlen <= '0; tcrc <= '0;
      wr_seq <= '0; tx_seq <= '0; nsent <= '0; ackd <= 12'hFFF; widx <= '0; rp_req <= 1'b0; rnum <= '0;
      rtmr <= '0; cl <= '0; cc <= '0; cinf <= 1'b0;
      rst <= R_IDLE; rcnt <= '0; rdl <= '0; rd2 <= '0; rseq <= '0; nrs <= '0; rcrc <= '0; rlong <= 1'b0;
      rwp <= '0; rcp <= '0; rrp <= '0; rqw <= '0; rqr <= '0; rgot <= '0; ca <= 8'(RXN);
      ack_p <= 1'b0; nak_p <= 1'b0; nak_s <= 1'b0; upd_p <= 1'b0;
      tx_sym <= '0; tx_k <= 1'b0; retrain <= 1'b0;
      {ev_tlp_bad, ev_tlp_seq, ev_tlp_dup, ev_tlp_null, ev_overflow, ev_dllp_bad, ev_dllp_proto, ev_frame,
       ev_nak, ev_replay} <= '0;
    end else begin
      retrain <= 1'b0;
      {ev_tlp_bad, ev_tlp_seq, ev_tlp_dup, ev_tlp_null, ev_overflow, ev_dllp_bad, ev_dllp_proto, ev_frame,
       ev_nak, ev_replay} <= '0;
      // ---------------- link state ----------------
      fct <= fct == '0 ? GW'(dls == DL_ACTIVE ? UPD_GAP : FC_GAP) : fct - 1'b1;
      if (dls == DL_ACTIVE && fct == '0) upd_p <= 1'b1;
      if (dls == DL_INACTIVE && link_up) begin dls <= DL_FC1; fct <= '0; end

      // ---------------- transmit ----------------
      tx_sym <= 8'h00; tx_k <= 1'b0;
      if (tst == T_IDLE) begin
        if (t_go && (nak_p || ack_p || t_fc || upd_p && dl_up)) begin
          tx_sym <= SDP; tx_k <= 1'b1; tst <= T_DLLP; tcnt <= LW'(1);
          tdt <= t_dt; tdv <= t_dv; tdc <= crc16_32(dllp(t_dt, t_dv));
          if (nak_p) begin nak_p <= 1'b0; ack_p <= 1'b0; end
          else if (ack_p) ack_p <= 1'b0;
          else if (!t_fc) upd_p <= 1'b0;
        end else if (t_go) begin
          tx_sym <= STP; tx_k <= 1'b1; tst <= T_TLP; tcnt <= LW'(1);
          tcur <= t_eff; tlen <= rlen[t_eff[TW-1:0]]; tcrc <= 32'hFFFF_FFFF; rp_req <= 1'b0;
          if (t_new) begin nsent <= nsent + 12'd1; cc <= cc + 8'd1; end
        end
      end else if (tst == T_DLLP) begin
        tcnt <= tcnt + 1'b1;
        case (tcnt)
          LW'(1), LW'(2), LW'(3), LW'(4): tx_sym <= dbyte(tdt, tdv, 2'(tcnt - LW'(1)));
          LW'(5): tx_sym <= ~tdc[15:8];
          LW'(6): tx_sym <= ~tdc[7:0];
          default: begin tx_sym <= ENDS; tx_k <= 1'b1; tst <= T_IDLE; end
        endcase
      end else begin
        tcnt <= tcnt + 1'b1;
        if (tcnt == LW'(1)) begin tx_sym <= {4'd0, tcur[11:8]}; tcrc <= crc32_8(tcrc, {4'd0, tcur[11:8]}); end
        else if (tcnt == LW'(2)) begin tx_sym <= tcur[7:0]; tcrc <= crc32_8(tcrc, tcur[7:0]); end
        else if (tcnt < tlen + LW'(3)) begin tx_sym <= t_byte; tcrc <= crc32_8(tcrc, t_byte); end
        else if (tcnt < tlen + LW'(7)) tx_sym <= 8'(~tcrc >> {2'(LW'(6) - (tcnt - tlen)), 3'b000});
        else begin tx_sym <= ENDS; tx_k <= 1'b1; tst <= T_IDLE; tx_seq <= tcur + 12'd1; end
      end
      // replay timer
      if (!t_out || rp_req) rtmr <= '0;
      else if (rtmr == RTW'(REPLAY_TO)) begin
        rtmr <= '0; rp_req <= 1'b1; ev_replay <= 1'b1;
        rnum <= rnum + 2'd1;
        if (rnum == 2'd3) retrain <= 1'b1;
      end else rtmr <= rtmr + 1'b1;
      // writing TLPs into the replay buffer
      if (tlp_valid && tlp_ready) begin
        rb[IW'(wr_seq[TW-1:0]) * IW'(MAXLEN) + IW'(widx)] <= tlp_data;
        widx <= widx + 1'b1;
        if (tlp_last || widx == BW'(MAXLEN - 1)) begin
          rlen[wr_seq[TW-1:0]] <= LW'(widx) + 1'b1; widx <= '0; wr_seq <= wr_seq + 12'd1;
        end
      end

      // ---------------- receive ----------------
      if (!rx_k) begin
        // a data byte
        if (rst != R_DLLP || rcnt < LW'(4)) rdl <= r_nb;
        if (rst == R_TLP) begin
          rcnt <= rcnt + 1'b1;
          if (rcnt == LW'(1)) rseq <= {rdl[3:0], rx_sym};
          // a byte four behind is past the LCRC window: into the CRC (and the
          // buffer for TLP bytes)
          if (rcnt >= LW'(4)) begin
            rcrc <= r_crc_n;
            if (rcnt >= LW'(6)) begin
              if (rcnt - LW'(6) == LW'(MAXLEN)) rlong <= 1'b1;
              else if (r_room) begin rf[rwp[RW-1:0]] <= rdl[31:24]; rwp <= rwp + 1'b1; end
            end
          end
        end else if (rst == R_DLLP) begin
          rcnt <= rcnt + 1'b1;
          if (rcnt >= LW'(4)) rd2 <= {rd2[7:0], rx_sym};
          if (rcnt == LW'(6)) begin ev_frame <= 1'b1; rst <= R_IDLE; end
        end
      end else begin : b_k
        // a K symbol: ends or starts a packet
        logic tlp_bad, dllp_ok;
        tlp_bad = 1'b0; dllp_ok = 1'b0;
        if (rst == R_TLP) begin
          if ((rx_sym == ENDS || rx_sym == EDB) && rcnt >= LW'(7) && !rlong) begin
            if (rx_sym == EDB && rdl == rcrc) ev_tlp_null <= 1'b1;
            else if (rx_sym == EDB || rdl != ~rcrc) tlp_bad = 1'b1;
            else if (ahead(rseq, nrs)) begin ev_tlp_seq <= 1'b1; tlp_bad = 1'b1; end
            else if (rseq != nrs) begin ev_tlp_dup <= 1'b1; ack_p <= 1'b1; end
            else if (r_rq_full) ev_overflow <= 1'b1;
            else begin
              nrs <= nrs + 12'd1; ack_p <= 1'b1; nak_s <= 1'b0;
              rcp <= rwp; rq[rqw[QW-1:0]] <= rcnt - LW'(6); rqw <= rqw + 1'b1;
              if (dls == DL_FC2) dls <= DL_ACTIVE;
            end
          end else begin ev_frame <= 1'b1; tlp_bad = 1'b1; end
          if (tlp_bad) begin
            ev_tlp_bad <= 1'b1;
            if (!nak_s) begin nak_p <= 1'b1; nak_s <= 1'b1; end
          end
        end else if (rst == R_DLLP) begin
          if (rx_sym == ENDS && rcnt == LW'(6)) begin
            if (rd2 != ~crc16_32(rdl)) ev_dllp_bad <= 1'b1;
            else dllp_ok = 1'b1;
          end else ev_frame <= 1'b1;
        end else if (rx_sym != STP && rx_sym != SDP) ev_frame <= 1'b1;
        rst <= rx_sym == STP ? R_TLP : rx_sym == SDP ? R_DLLP : R_IDLE;
        rcnt <= '0; rcrc <= 32'hFFFF_FFFF; rlong <= 1'b0; rwp <= rcp;
        if (dllp_ok) begin : b_dllp
          logic [7:0] hdr;
          hdr = {rdl[21:16], rdl[15:14]};
          // rdl: [31:24] type, [23:16] byte 1, [15:8] byte 2, [7:0] byte 3
          case (rdl[31:24])
            T_ACK, T_NAK:
              if (dl_up) begin
                // the last acknowledged TLP or one sent since
                if (rdl[23:12] != 12'd0 || r_ack_seq - ackd > nsent - 12'd1 - ackd) ev_dllp_proto <= 1'b1;
                else begin
                  if (r_ack_seq != ackd) begin ackd <= r_ack_seq; rnum <= '0; rtmr <= '0; end
                  if (rdl[31:24] == T_NAK) begin
                    ev_nak <= 1'b1;
                    if (r_ack_seq != nsent - 12'd1) begin
                      rp_req <= 1'b1;
                      rnum <= r_ack_seq != ackd ? 2'd1 : rnum + 2'd1;
                      if (r_ack_seq == ackd && rnum == 2'd3) retrain <= 1'b1;
                    end
                  end
                end
              end
            T_IFC1, T_IFC2:
              if (dls == DL_FC1 || dls == DL_FC2 && rdl[31:24] == T_IFC2) begin
                cl <= hdr; cinf <= hdr == 8'd0;
                dls <= dls == DL_FC1 ? DL_FC2 : DL_ACTIVE;
              end
            T_UFC:
              if (dls == DL_FC2) dls <= DL_ACTIVE;
              else cl <= hdr;                           // (unused while cinf; InitFC sets it again)
            default: ev_dllp_proto <= 1'b1;
          endcase
        end
      end
      // reading TLPs out
      if (rx_valid && rx_ready) begin
        rrp <= rrp + 1'b1; rgot <= rgot + 1'b1;
        if (rx_last) begin rgot <= '0; rqr <= rqr + 1'b1; ca <= ca + 8'd1; upd_p <= 1'b1; end
      end

      // the link drops: everything back to the start
      if (!link_up) begin
        dls <= DL_INACTIVE; tst <= T_IDLE; tx_sym <= 8'h00; tx_k <= 1'b0;
        wr_seq <= '0; tx_seq <= '0; nsent <= '0; ackd <= 12'hFFF; widx <= '0; rp_req <= 1'b0; rnum <= '0;
        rtmr <= '0; cl <= '0; cc <= '0; cinf <= 1'b0;
        rst <= R_IDLE; nrs <= '0; rwp <= '0; rcp <= '0; rrp <= '0; rqw <= '0; rqr <= '0; rgot <= '0;
        ca <= 8'(RXN); ack_p <= 1'b0; nak_p <= 1'b0; nak_s <= 1'b0; upd_p <= 1'b0;
      end
    end
endmodule
