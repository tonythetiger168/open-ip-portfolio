// SPDX-License-Identifier: Apache-2.0
// ============================================================================
// PCIe_top v3.0: PCI Express-style data link layer, one lane (TLP framing
// with sequence numbers and LCRC, Ack/Nak with a replay buffer, replay
// timer and Ack latency timer, DLLPs with CRC-16, flow control for the
// Posted, Non-Posted and Completion credit types with header and data
// credits, ASPM L1 entry and exit)
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
//  - Credit type of a TLP, from its first byte {Fmt[2:0], Type[4:0]}:
//    Completion when Type is 0101x; Posted when Type is 10xxx (messages)
//    or 00000 with Fmt[1] set (memory write); Non-Posted otherwise. It
//    takes one header credit and, when Fmt[1] (with data) is set, one
//    data credit per 16 bytes of the TLP, rounded up (header included:
//    the TLP is not parsed further).
//  - DLLP: SDP, 4 bytes, CRC-16 (100B, initial value all ones, bit 7 first,
//    sent inverted, bits 15:8 first), END. Byte 0 is the type: Ack 00 and
//    Nak 10 (bytes 2..3 = {0000, seq}); InitFC1 40 / 50 / 60, InitFC2
//    C0 / D0 / E0, UpdateFC 80 / 90 / A0 for P / NP / Cpl (bytes 1..3 =
//    {00, HdrFC[7:0], 00, DataFC[11:0]}); PM_Active_State_Request_L1 23,
//    PM_Request_Ack 24 (bytes 1..3 zero). Any other type is unknown.
//  - Flow control initialization: with link_up the layer sends InitFC1 for
//    P, NP and Cpl (HP / DP, HNP / DNP, HC / DC credits) every FC_GAP
//    clocks until it has received an InitFC1 or InitFC2 of every type,
//    then InitFC2 until it receives an InitFC2, an UpdateFC or a good TLP
//    (dl_up). An advertised value of 0 is infinite. Dropping link_up
//    resets the whole layer (buffers emptied, sequence numbers back to 0).
//  - Transmit: a TLP is written into the replay buffer through tlp_* (up
//    to TXN unacknowledged; a TLP longer than MAXLEN is cut), gets the next
//    sequence number and is sent when the receiver has header and data
//    credit of its type, oldest first (credit check as in PCIe: limit -
//    (consumed + needed) mod 2^n below 2^(n-1)). It stays in the buffer
//    until acknowledged. A Nak, or REPLAY_TO clocks without progress,
//    replays from the oldest unacknowledged TLP; the fourth replay without
//    progress pulses retrain. UpdateFC sets the limits of finite credits.
//  - Receive: a good TLP with the expected sequence number goes into the
//    receive buffer and is handed out through rx_*; its Ack is sent ACK_LAT
//    clocks after the first TLP not yet acknowledged (or at once for a
//    duplicate). A duplicate is dropped and acknowledged (ev_tlp_dup); a
//    sequence number ahead, a bad LCRC or a framing error makes a Nak
//    (once until a good TLP arrives; ev_tlp_seq / ev_tlp_bad). A TLP over
//    the credits advertised for its type is dropped, not acknowledged
//    (ev_overflow). Credits are returned (UpdateFC of that type) as each
//    TLP is read out; UpdateFC of every type is also repeated every UPD_GAP
//    clocks while in L0.
//  - ASPM L1 (pm_state 0 L0, 1 requesting, 2 L1): with pm_req, the link
//    up and nothing unacknowledged, written or owed, the layer stops
//    taking TLPs and sends PM_Active_State_Request_L1 every FC_GAP clocks
//    (credits read out are still returned);
//    PM_Request_Ack -> L1; pm_req low or a TLP written -> L0. A request
//    received with aspm_ok and the same idle conditions (no TLP written)
//    is answered by PM_Request_Ack and enters L1; otherwise
//    it is ignored. In L1 nothing is sent but PM_Request_Ack; a TLP
//    written, an Ack, Nak or UpdateFC owed, or any packet received other
//    than a PM DLLP, returns to L0.
//    Packets go out between packets in the order Nak, Ack, PM_Request_Ack,
//    InitFC, PM request, UpdateFC (P, NP, Cpl), TLP.
//  Not implemented: the physical layer (LTSSM, ordered sets, electrical
//  idle, 8b/10b, scrambling, skip), 128b/130b, flit mode, more than one
//  lane, virtual channels other than VC0, credit scale factors, the
//  PM_Active_State_Nak message, PCI-PM L1 / L2 DLLPs, surprise-down and
//  data link feature exchange. Field layouts follow PCIe as we read it;
//  they have not been checked against a compliant device.
// ============================================================================
module PCIe_top #(
  parameter int MAXLEN    = 32,       // bytes in a TLP
  parameter int TXN       = 4,        // unacknowledged TLPs (power of 2)
  parameter int RXN       = 4,        // TLPs in the receive buffer (power of 2, at least HP + HNP + HC)
  parameter int REPLAY_TO = 600,      // replay timer, clocks
  parameter int ACK_LAT   = 16,       // Ack latency, clocks
  parameter int FC_GAP    = 32,       // InitFC and PM request repeat, clocks
  parameter int UPD_GAP   = 1024,     // UpdateFC repeat, clocks
  parameter int HP = 2, HNP = 1, HC = 1,    // header credits advertised
  parameter int DP = 4, DNP = 2, DC = 2     // data credits advertised (16 bytes each)
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
  // power management
  input  logic       pm_req,
  input  logic       aspm_ok,
  output logic [1:0] pm_state,
  // status and events
  output logic       dl_up,
  output logic       retrain,
  output logic       ev_tlp_bad,      // bad LCRC or framing: Nak
  output logic       ev_tlp_seq,      // sequence number ahead: Nak
  output logic       ev_tlp_dup,      // sequence number already received
  output logic       ev_tlp_null,     // nullified TLP dropped
  output logic       ev_overflow,     // TLP over its credits dropped
  output logic       ev_dllp_bad,     // DLLP CRC-16 error
  output logic       ev_dllp_proto,   // Ack / Nak out of range, unknown DLLP type
  output logic       ev_frame,        // framing error
  output logic       ev_nak,          // Nak received
  output logic       ev_replay        // replay timer expired
);
  localparam logic [7:0] STP = 8'hFB, SDP = 8'h5C, ENDS = 8'hFD, EDB = 8'hFE;
  localparam logic [7:0] T_ACK = 8'h00, T_NAK = 8'h10, T_PMREQ = 8'h23, T_PMACK = 8'h24;
  localparam int LW = $clog2(MAXLEN + 8);
  localparam int BW = $clog2(MAXLEN);
  localparam int TW = $clog2(TXN);
  localparam int IW = $clog2(TXN * MAXLEN);
  localparam int RW = $clog2(RXN * MAXLEN);
  localparam int QW = $clog2(RXN);
  localparam int RTW = $clog2(REPLAY_TO + 1);
  localparam int GW = $clog2(UPD_GAP + 1);
  localparam int AW = $clog2(ACK_LAT + 1);
  localparam int PW = $clog2(FC_GAP + 1);
  localparam int DNW = $clog2((MAXLEN + 15) / 16 + 1);
  localparam logic [1:0] P_L0 = 2'd0, P_REQ = 2'd1, P_L1 = 2'd2;

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
  // credit type from the first TLP byte: 0 P, 1 NP, 2 Cpl
  function automatic logic [1:0] ctype(input logic [7:0] b);
    /* verilator lint_off UNUSEDSIGNAL */
    logic [7:0] x;
    /* verilator lint_on UNUSEDSIGNAL */
    x = b;                                      // Fmt[2] and Fmt[0] play no part
    if (x[4:1] == 4'b0101) ctype = 2'd2;
    else if (x[4:3] == 2'b10 || x[4:0] == 5'd0 && x[6]) ctype = 2'd0;
    else ctype = 2'd1;
  endfunction
  // data credits of a TLP: 16-byte units when it carries data
  function automatic logic [DNW-1:0] dneed(input logic data, input logic [LW-1:0] n);
    dneed = data ? DNW'((n + LW'(15)) >> 4) : '0;
  endfunction
  // credits enough: (limit - (consumed + need)) mod 2^n below 2^(n-1)
  function automatic logic hok(input logic [7:0] l, input logic [7:0] c);
    /* verilator lint_off UNUSEDSIGNAL */
    logic [7:0] d;
    /* verilator lint_on UNUSEDSIGNAL */
    d = l - c - 8'd1;
    hok = !d[7];
  endfunction
  function automatic logic dok(input logic [11:0] l, input logic [11:0] c, input logic [DNW-1:0] n);
    /* verilator lint_off UNUSEDSIGNAL */
    logic [11:0] d;
    /* verilator lint_on UNUSEDSIGNAL */
    d = l - c - 12'(n);
    dok = !d[11];
  endfunction
  function automatic logic [7:0] hadv(input logic [1:0] t);
    hadv = t == 2'd0 ? 8'(HP) : t == 2'd1 ? 8'(HNP) : 8'(HC);
  endfunction
  function automatic logic [11:0] dadv(input logic [1:0] t);
    dadv = t == 2'd0 ? 12'(DP) : t == 2'd1 ? 12'(DNP) : 12'(DC);
  endfunction

  // ---------------- link state ----------------
  typedef enum logic [1:0] {DL_INACTIVE, DL_FC1, DL_FC2, DL_ACTIVE} dl_t;
  dl_t           dls;
  logic [GW-1:0] fct;                   // InitFC / UpdateFC timer
  logic [2:0]    fq;                    // InitFC owed, by type
  logic [2:0]    fgot;                  // InitFC received, by type
  assign dl_up = dls == DL_ACTIVE;
  logic [1:0]    pst;                   // ASPM
  logic [PW-1:0] pmt;                   // PM request timer
  logic          pmreq_p, pmack_p;
  assign pm_state = pst;

  // ---------------- transmit state ----------------
  typedef enum logic [1:0] {T_IDLE, T_DLLP, T_TLP} ts_t;
  ts_t           tst;
  logic [LW-1:0] tcnt;
  logic [7:0]    tdt;                   // DLLP type byte
  logic [19:0]   tdv;                   // its {HdrFC, DataFC} or sequence number
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
  logic [7:0]    hcl [0:2], hcc [0:2];  // header credit limit, consumed
  logic [11:0]   dcl [0:2], dcc [0:2];  // data credit limit, consumed
  logic [2:0]    hinf, dinf;            // infinite
  // ---------------- receive state ----------------
  typedef enum logic [1:0] {R_IDLE, R_TLP, R_DLLP} rs_t;
  rs_t           rst;
  logic [LW-1:0] rcnt;                  // data bytes in the packet
  logic [31:0]   rdl;                   // last 4 bytes, [7:0] newest
  logic [15:0]   rd2;                   // DLLP bytes 4..5
  logic [11:0]   rseq, nrs;             // TLP sequence number; next expected
  logic [31:0]   rcrc;
  logic          rlong;                 // TLP too long
  logic [7:0]    rfb;                   // first TLP byte
  logic [7:0]    rf [0:RXN*MAXLEN-1];   // receive buffer
  logic [RW:0]   rwp, rcp, rrp;         // tentative write, committed write, read
  logic [LW-1:0] rq [0:RXN-1];          // lengths of the TLPs in it
  logic [1:0]    rqt [0:RXN-1];         // their credit types
  logic [DNW-1:0] rqd [0:RXN-1];        // their data credits
  logic [QW:0]   rqw, rqr;
  logic [BW-1:0] rgot;                  // bytes read of the TLP at rqr
  logic [7:0]    cah [0:2];             // header credits allocated
  logic [11:0]   cad [0:2];             // data credits allocated
  logic [7:0]    rch [0:2];             // header credits received (mod 256)
  logic [11:0]   rcd [0:2];             // data credits received (mod 4096)
  logic          ack_p, ack_f, nak_p, nak_s;
  logic [AW-1:0] ack_t;
  logic [2:0]    upd_p;

  // ---------------- transmit ----------------
  wire [11:0]  t_eff = rp_req || ahead(ackd + 12'd1, tx_seq) ? ackd + 12'd1 : tx_seq;
  wire         t_new = t_eff == nsent;
  wire [7:0]   t_b0 = rb[IW'(t_eff[TW-1:0]) * IW'(MAXLEN)];
  wire [1:0]   t_ty = ctype(t_b0);
  wire [DNW-1:0] t_dn = dneed(t_b0[6], rlen[t_eff[TW-1:0]]);
  wire         t_cok = (hinf[t_ty] || hok(hcl[t_ty], hcc[t_ty])) && (dinf[t_ty] || dok(dcl[t_ty], dcc[t_ty], t_dn));
  wire         t_tlp = dl_up && pst == P_L0 && t_eff != wr_seq && (!t_new || t_cok);
  wire         t_fc = (dls == DL_FC1 || dls == DL_FC2) && fq != '0;
  wire         t_ack = ack_p && (ack_f || ack_t == AW'(ACK_LAT));
  wire         t_pmr = pst == P_REQ && pmreq_p;
  wire         t_upd = dl_up && pst != P_L1 && upd_p != '0;
  wire         t_go = tst == T_IDLE && (nak_p || t_ack || pmack_p || t_fc || t_pmr || t_upd || t_tlp);
  // UpdateFC / InitFC type: the lowest owed
  wire [1:0]   t_fm = t_fc ? fq[1:0] : upd_p[1:0];
  wire [1:0]   t_ft = t_fm[0] ? 2'd0 : t_fm[1] ? 2'd1 : 2'd2;
  wire [7:0]   t_dt = nak_p ? T_NAK : t_ack ? T_ACK : pmack_p ? T_PMACK : t_fc ? {dls == DL_FC1 ? 2'b01 : 2'b11, t_ft, 4'h0} :
                      t_pmr ? T_PMREQ : {2'b10, t_ft, 4'h0};
  wire [19:0]  t_dv = nak_p || t_ack ? {8'd0, nrs - 12'd1} : t_fc ? {hadv(t_ft), dadv(t_ft)} : {cah[t_ft], cad[t_ft]};
  // DLLP bytes 0..3
  function automatic logic [31:0] dllp(input logic [7:0] t, input logic [19:0] v);
    if (t == T_ACK || t == T_NAK) dllp = {t, 8'd0, 4'd0, v[11:0]};
    else if (t == T_PMREQ || t == T_PMACK) dllp = {t, 24'd0};
    else dllp = {t, 2'b00, v[19:12], 2'b00, v[11:0]};
  endfunction
  function automatic logic [7:0] dbyte(input logic [7:0] t, input logic [19:0] v, input logic [1:0] i);
    logic [31:0] d;
    d = dllp(t, v);
    dbyte = 8'(d >> {~i, 3'b000});
  endfunction
  wire [7:0]   t_byte = rb[IW'(tcur[TW-1:0]) * IW'(MAXLEN) + IW'(BW'(tcnt - LW'(3)))];
  // a free slot, not the one being sent
  assign tlp_ready = dl_up && pst == P_L0 && wr_seq - ackd - 12'd1 < 12'(TXN)
                     && !(tst == T_TLP && wr_seq[TW-1:0] == tcur[TW-1:0]);
  // replay timer
  wire         t_out = nsent != ackd + 12'd1;  // sent, unacknowledged
  // nothing unacknowledged, written or owed
  wire         idle = wr_seq == ackd + 12'd1 && !ack_p && !nak_p && widx == '0;

  // ---------------- receive ----------------
  wire [31:0]  r_nb = {rdl[23:0], rx_sym};     // with the byte now
  wire [31:0]  r_crc_n = crc32_8(rcrc, rdl[31:24]);
  wire [11:0]  r_ack_seq = {rdl[11:8], rdl[7:0]};
  wire [LW-1:0] r_len = rq[rqr[QW-1:0]];
  wire [LW-1:0] r_tn = rcnt - LW'(6);          // TLP bytes at the end symbol
  // room for a TLP of type t needing n data credits: the credits held in the
  // buffer are received (rh, rd) + advertised - allocated (ah, ad)
  function automatic logic rroom(input logic [1:0] t, input logic [DNW-1:0] n, input logic [7:0] rh, ah,
                                 input logic [11:0] rd, ad);
    logic [7:0]  h;
    logic [11:0] d;
    h = rh + hadv(t) - ah;
    d = rd + dadv(t) - ad;
    rroom = h != hadv(t) && d + 12'(n) <= dadv(t);
  endfunction
  wire [1:0]   r_ty = ctype(rfb);
  wire [DNW-1:0] r_dn = dneed(rfb[6], r_tn);
  wire         r_broom = rwp - rrp < (RW+1)'(RXN * MAXLEN);   // byte room
  wire         r_room = rroom(r_ty, r_dn, rch[r_ty], cah[r_ty], rcd[r_ty], cad[r_ty]);
  assign rx_valid = rqw != rqr;
  assign rx_data = rf[rrp[RW-1:0]];
  assign rx_last = LW'(rgot) == r_len - 1'b1;

  always_ff @(posedge clk or negedge rst_n)
    if (!rst_n) begin
      dls <= DL_INACTIVE; fct <= '0; fq <= '0; fgot <= '0; pst <= P_L0; pmt <= '0; pmreq_p <= 1'b0; pmack_p <= 1'b0;
      tst <= T_IDLE; tcnt <= '0; tdt <= '0; tdv <= '0; tdc <= '0; tcur <= '0; tlen <= '0; tcrc <= '0;
      wr_seq <= '0; tx_seq <= '0; nsent <= '0; ackd <= 12'hFFF; widx <= '0; rp_req <= 1'b0; rnum <= '0;
      rtmr <= '0; hinf <= '0; dinf <= '0;
      for (int i = 0; i < 3; i++) begin
        hcl[i] <= '0; hcc[i] <= '0; dcl[i] <= '0; dcc[i] <= '0;
        cah[i] <= hadv(2'(i)); cad[i] <= dadv(2'(i)); rch[i] <= '0; rcd[i] <= '0;
      end
      rst <= R_IDLE; rcnt <= '0; rdl <= '0; rd2 <= '0; rseq <= '0; nrs <= '0; rcrc <= '0; rlong <= 1'b0; rfb <= '0;
      rwp <= '0; rcp <= '0; rrp <= '0; rqw <= '0; rqr <= '0; rgot <= '0;
      ack_p <= 1'b0; ack_f <= 1'b0; ack_t <= '0; nak_p <= 1'b0; nak_s <= 1'b0; upd_p <= '0;
      tx_sym <= '0; tx_k <= 1'b0; retrain <= 1'b0;
      {ev_tlp_bad, ev_tlp_seq, ev_tlp_dup, ev_tlp_null, ev_overflow, ev_dllp_bad, ev_dllp_proto, ev_frame,
       ev_nak, ev_replay} <= '0;
    end else begin : b_main
      logic wake;                                   // something leaves L1
      logic ack_sent;
      wake = 1'b0; ack_sent = 1'b0;
      retrain <= 1'b0;
      {ev_tlp_bad, ev_tlp_seq, ev_tlp_dup, ev_tlp_null, ev_overflow, ev_dllp_bad, ev_dllp_proto, ev_frame,
       ev_nak, ev_replay} <= '0;
      // ---------------- link state ----------------
      fct <= fct == '0 ? GW'(dls == DL_ACTIVE ? UPD_GAP : FC_GAP) : fct - 1'b1;
      if ((dls == DL_FC1 || dls == DL_FC2) && fct == '0) fq <= 3'b111;
      if (dls == DL_ACTIVE && fct == '0 && pst == P_L0) upd_p <= 3'b111;
      if (dls == DL_INACTIVE && link_up) begin dls <= DL_FC1; fct <= '0; end
      if (ack_p && ack_t != AW'(ACK_LAT)) ack_t <= ack_t + 1'b1;
      // ASPM request
      pmt <= pst == P_REQ && pmt != '0 ? pmt - 1'b1 : PW'(FC_GAP);
      if (pst == P_REQ && pmt == '0) pmreq_p <= 1'b1;
      if (pst == P_L0 && pm_req && dl_up && idle && !tlp_valid) begin pst <= P_REQ; pmreq_p <= 1'b1; pmt <= PW'(FC_GAP); end
      if (pst == P_REQ && (!pm_req || tlp_valid)) begin pst <= P_L0; pmreq_p <= 1'b0; end

      // ---------------- transmit ----------------
      tx_sym <= 8'h00; tx_k <= 1'b0;
      if (tst == T_IDLE) begin
        if (t_go && (nak_p || t_ack || pmack_p || t_fc || t_pmr || t_upd)) begin
          tx_sym <= SDP; tx_k <= 1'b1; tst <= T_DLLP; tcnt <= LW'(1);
          tdt <= t_dt; tdv <= t_dv; tdc <= crc16_32(dllp(t_dt, t_dv));
          if (nak_p) begin nak_p <= 1'b0; ack_p <= 1'b0; ack_f <= 1'b0; ack_t <= '0; ack_sent = 1'b1; end
          else if (t_ack) begin ack_p <= 1'b0; ack_f <= 1'b0; ack_t <= '0; ack_sent = 1'b1; end
          else if (pmack_p) pmack_p <= 1'b0;
          else if (t_fc) fq[t_ft] <= 1'b0;
          else if (t_pmr) pmreq_p <= 1'b0;
          else upd_p[t_ft] <= 1'b0;
        end else if (t_go) begin
          tx_sym <= STP; tx_k <= 1'b1; tst <= T_TLP; tcnt <= LW'(1);
          tcur <= t_eff; tlen <= rlen[t_eff[TW-1:0]]; tcrc <= 32'hFFFF_FFFF; rp_req <= 1'b0;
          if (t_new) begin nsent <= nsent + 12'd1; hcc[t_ty] <= hcc[t_ty] + 8'd1; dcc[t_ty] <= dcc[t_ty] + 12'(t_dn); end
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
      if (tlp_valid) wake = 1'b1;

      // ---------------- receive ----------------
      if (!rx_k) begin
        // a data byte
        if (rst != R_DLLP || rcnt < LW'(4)) rdl <= r_nb;
        if (rst == R_TLP) begin
          rcnt <= rcnt + 1'b1;
          if (rcnt == LW'(1)) rseq <= {rdl[3:0], rx_sym};
          if (rcnt == LW'(2)) rfb <= rx_sym;
          // a byte four behind is past the LCRC window: into the CRC (and the
          // buffer for TLP bytes)
          if (rcnt >= LW'(4)) begin
            rcrc <= r_crc_n;
            if (rcnt >= LW'(6)) begin
              if (rcnt - LW'(6) == LW'(MAXLEN)) rlong <= 1'b1;
              else if (r_broom) begin rf[rwp[RW-1:0]] <= rdl[31:24]; rwp <= rwp + 1'b1; end
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
          wake = 1'b1;
          if ((rx_sym == ENDS || rx_sym == EDB) && rcnt >= LW'(7) && !rlong) begin
            if (rx_sym == EDB && rdl == rcrc) ev_tlp_null <= 1'b1;
            else if (rx_sym == EDB || rdl != ~rcrc) tlp_bad = 1'b1;
            else if (ahead(rseq, nrs)) begin ev_tlp_seq <= 1'b1; tlp_bad = 1'b1; end
            else if (rseq != nrs) begin ev_tlp_dup <= 1'b1; ack_p <= 1'b1; ack_f <= 1'b1; end
            else if (!r_room) ev_overflow <= 1'b1;
            else begin
              nrs <= nrs + 12'd1; nak_s <= 1'b0;
              ack_p <= 1'b1;
              if (!ack_p || ack_sent) ack_t <= '0;
              rcp <= rwp; rq[rqw[QW-1:0]] <= r_tn; rqt[rqw[QW-1:0]] <= r_ty; rqd[rqw[QW-1:0]] <= r_dn;
              rqw <= rqw + 1'b1;
              rch[r_ty] <= rch[r_ty] + 8'd1; rcd[r_ty] <= rcd[r_ty] + 12'(r_dn);
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
          logic [7:0]  hdr;
          logic [11:0] dat;
          logic [1:0]  ft;
          // rdl: [31:24] type, [23:16] byte 1, [15:8] byte 2, [7:0] byte 3
          hdr = {rdl[21:16], rdl[15:14]}; dat = rdl[11:0]; ft = rdl[29:28];
          if (rdl[31:24] != T_PMREQ && rdl[31:24] != T_PMACK) wake = 1'b1;
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
            8'h40, 8'h50, 8'h60, 8'hC0, 8'hD0, 8'hE0:   // InitFC1 / InitFC2
              if (dls == DL_FC1) begin
                hcl[ft] <= hdr; hinf[ft] <= hdr == 8'd0; dcl[ft] <= dat; dinf[ft] <= dat == 12'd0;
                fgot[ft] <= 1'b1;
                if ((fgot | (3'b001 << ft)) == 3'b111) dls <= DL_FC2;
              end else if (dls == DL_FC2 && rdl[31]) dls <= DL_ACTIVE;
            8'h80, 8'h90, 8'hA0:                         // UpdateFC
              if (dls == DL_FC2) dls <= DL_ACTIVE;
              else if (dls == DL_ACTIVE) begin
                if (!hinf[ft]) hcl[ft] <= hdr;
                if (!dinf[ft]) dcl[ft] <= dat;
              end
            T_PMREQ:
              if (dl_up && pst != P_L1 && aspm_ok && idle && !tlp_valid) begin
                pmack_p <= 1'b1; pst <= P_L1; pmreq_p <= 1'b0;
              end else if (pst == P_L1) pmack_p <= 1'b1;
            T_PMACK:
              if (pst == P_REQ && pm_req && !tlp_valid) begin pst <= P_L1; pmreq_p <= 1'b0; end
            default: ev_dllp_proto <= 1'b1;
          endcase
        end
      end
      // reading TLPs out: credits back
      if (rx_valid && rx_ready) begin
        rrp <= rrp + 1'b1; rgot <= rgot + 1'b1;
        if (rx_last) begin : b_free
          logic [1:0] t;
          t = rqt[rqr[QW-1:0]];
          rgot <= '0; rqr <= rqr + 1'b1;
          cah[t] <= cah[t] + 8'd1; cad[t] <= cad[t] + 12'(rqd[rqr[QW-1:0]]);
          upd_p[t] <= 1'b1; wake = 1'b1;
        end
      end
      // L1 left: something to send or received
      if (pst == P_L1 && (wake || ack_p || nak_p || upd_p != '0)) pst <= P_L0;

      // the link drops: everything back to the start
      if (!link_up) begin
        dls <= DL_INACTIVE; tst <= T_IDLE; tx_sym <= 8'h00; tx_k <= 1'b0; fq <= '0; fgot <= '0;
        pst <= P_L0; pmreq_p <= 1'b0; pmack_p <= 1'b0;
        wr_seq <= '0; tx_seq <= '0; nsent <= '0; ackd <= 12'hFFF; widx <= '0; rp_req <= 1'b0; rnum <= '0;
        rtmr <= '0; hinf <= '0; dinf <= '0;
        for (int i = 0; i < 3; i++) begin
          hcl[i] <= '0; hcc[i] <= '0; dcl[i] <= '0; dcc[i] <= '0;
          cah[i] <= hadv(2'(i)); cad[i] <= dadv(2'(i)); rch[i] <= '0; rcd[i] <= '0;
        end
        rst <= R_IDLE; nrs <= '0; rwp <= '0; rcp <= '0; rrp <= '0; rqw <= '0; rqr <= '0; rgot <= '0;
        ack_p <= 1'b0; ack_f <= 1'b0; ack_t <= '0; nak_p <= 1'b0; nak_s <= 1'b0; upd_p <= '0;
      end
    end
endmodule
