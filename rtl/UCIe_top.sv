// SPDX-License-Identifier: Apache-2.0
// ============================================================================
// UCIe_top v3.0: a UCIe-style Die-to-Die Adapter: 68-byte flits carrying
// 64-byte payloads for two protocol stacks, capability negotiation and the
// Adapter link state machine over the sideband, L1 entry and exit, retrain,
// and Retry (CRC, sequence numbers, Ack / Nak, replay buffer and timer)
// ----------------------------------------------------------------------------
//  - Protocol side (FDI-like, 64-byte width): tx_valid / tx_ready /
//    tx_stack / tx_data, one flit payload per transfer; rx_valid /
//    rx_stack / rx_data, payloads delivered once each, in order.
//  - Main band (RDI-like): lt_valid / lt_flit out, lr_valid / lr_flit in,
//    one 68-byte flit per transfer:
//      [543:528] header {DATA, STACK, NAK, RTY, SEQ[5:0], ACK[5:0]}
//      [527:16]  payload (64 bytes; zero in a NOP flit)
//      [15:0]    CRC-16 (polynomial 0x1021, seed 0xFFFF, MSB first) of
//                bits 543:16
//    phy_up: the physical layer is up. lp_retrain: a one-clock request to
//    the physical layer to retrain the link.
//  - Sideband: sb_tx_* / sb_rx_*, one 16-bit message {CODE[7:0],
//    DATA[7:0]} per transfer. Codes: 01 AdvCap and 02 FinCap (DATA[1:0] =
//    {stack 1, Retry}), 03 Req.Active, 04 Rsp.Active, 05 Req.L1,
//    06 Rsp.L1, 07 Rsp.PMNAK. Other DATA bits are ignored. When several
//    messages are owed, one goes out per clock in that order: AdvCap,
//    FinCap, Rsp.Active, Req.Active, Rsp.L1, Rsp.PMNAK, Req.L1.
//  - Link state (state): RESET 0, PARAM 1, ACTREQ 2, ACTIVE 3, L1 4,
//    RETRAIN 5, LINKERROR 6.
//      RESET -> PARAM: link_en and phy_up. The Adapter takes its
//        capabilities from {cfg_stack1, cfg_retry} and sends AdvCap. An
//        AdvCap from the far side is kept in RESET too.
//      PARAM: with the far AdvCap, cap = own AND far, sent in FinCap (again
//        for each later AdvCap). Once both FinCaps have crossed: equal ->
//        ACTREQ (Req.Active sent), different -> LINKERROR.
//      An AdvCap in ACTREQ, ACTIVE, L1 or RETRAIN: the far side started a
//        new session; -> RESET (everything cleared, the AdvCap kept).
//      ACTREQ -> ACTIVE: a Req.Active received (answered by Rsp.Active)
//        and a Rsp.Active received. Entering ACTIVE replays every flit
//        still outstanding. A Req.Active received in PARAM or RETRAIN is
//        answered on entering ACTREQ; one received in ACTIVE or L1 moves
//        to ACTREQ (both messages sent).
//      ACTIVE -> L1: pm_req (armed: it was low since the last request)
//        with nothing outstanding or owed and no tx_valid: Req.L1 is sent
//        and new flits wait. Rsp.L1 -> L1; Rsp.PMNAK -> stay (ev_pmnak). A
//        Req.L1 from the far side is accepted (Rsp.L1, -> L1) under the
//        same conditions with cfg_l1_ok and no flit arriving, else
//        answered by Rsp.PMNAK.
//      L1 -> ACTREQ: tx_valid (Req.Active sent).
//      phy_up low: PARAM -> RESET; ACTREQ, ACTIVE, L1 -> RETRAIN, keeping
//        the negotiated capabilities and the Retry state; RETRAIN ->
//        ACTREQ when phy_up returns.
//      PARAM or ACTREQ for HT clocks -> LINKERROR (handshake timeout).
//      link_en low: any state -> RESET; everything is cleared.
//      LINKERROR is left only through RESET (link_en low).
//    A sideband message not expected in the state is dropped (ev_proto).
//  - Flits are sent in ACTIVE only and received in ACTREQ and ACTIVE (any
//    other state: dropped, ev_proto). A flit whose RTY bit differs from
//    the negotiated Retry, or a DATA flit for stack 1 when stack 1 was not
//    negotiated, is dropped (ev_proto); with Retry its SEQ still counts as
//    received. A payload offered for stack 1 without it is taken and
//    dropped (ev_proto).
//  - Retry negotiated: every flit carries ACK (the last SEQ received in
//    order) and NAK. Transmit: a replay in progress first, then a new
//    payload (tx_ready: the RB-entry replay buffer has room, no replay
//    running), then a NOP when an Ack or Nak is owed. Receive: a bad CRC
//    is dropped (ev_crc) and a Nak is owed; the expected SEQ is delivered
//    and an Ack is owed; an old SEQ (a replayed duplicate) is dropped and
//    an Ack is owed; a SEQ ahead is dropped and a Nak is owed; one Nak
//    until the expected flit arrives. An ACK frees the buffer up to it (one
//    that is not within what is outstanding is ignored); NAK set replays
//    all outstanding. A replay also starts after TO clocks in ACTIVE
//    without progress while flits are outstanding (ev_replay). NR replays
//    without an Ack in between request a retrain (lp_retrain, ev_retrain).
//  - Retry not negotiated: DATA flits with SEQ, ACK, NAK and RTY 0; no
//    buffer, no Acks. A flit with a bad CRC is dropped (ev_crc) and the
//    Adapter enters LINKERROR (ev_lerr), since the payload is lost.
//  - cap: the negotiated {stack 1, Retry} (0 in RESET). tx_pend: flits
//    outstanding. ev_lerr: LINKERROR entered.
//  Not implemented: the 256-byte flit formats, the spec's flit header,
//  CRC and sideband packet formats (fields here are ours, not checked
//  against another Adapter), raw format, more than two stacks, L2, link
//  reset and disable messages, parity and runtime link testing, the
//  physical layer.
// ============================================================================
module UCIe_top #(
  parameter int RB = 8,                 // replay buffer entries, power of 2, 2..32
  parameter int TO = 64,                // replay timeout, clocks
  parameter int NR = 4,                 // replays without progress before a retrain request
  parameter int HT = 512                // sideband handshake timeout, clocks
)(
  input  logic          clk,
  input  logic          rst_n,
  // link control
  input  logic          link_en,
  input  logic          cfg_retry,
  input  logic          cfg_stack1,
  input  logic          cfg_l1_ok,
  input  logic          pm_req,
  // protocol side
  input  logic          tx_valid,
  input  logic          tx_stack,
  input  logic [511:0]  tx_data,
  output logic          tx_ready,
  output logic          rx_valid,
  output logic          rx_stack,
  output logic [511:0]  rx_data,
  // physical layer: main band
  input  logic          phy_up,
  output logic          lp_retrain,
  output logic          lt_valid,
  output logic [543:0]  lt_flit,
  input  logic          lr_valid,
  input  logic [543:0]  lr_flit,
  // sideband
  output logic          sb_tx_valid,
  output logic [15:0]   sb_tx_msg,
  input  logic          sb_rx_valid,
  /* verilator lint_off UNUSEDSIGNAL */
  input  logic [15:0]   sb_rx_msg,      // DATA[7:2] ignored
  /* verilator lint_on UNUSEDSIGNAL */
  // status and events
  output logic [2:0]    state,
  output logic [1:0]    cap,
  output logic [$clog2(RB):0] tx_pend,
  output logic          ev_crc,
  output logic          ev_replay,
  output logic          ev_retrain,
  output logic          ev_pmnak,
  output logic          ev_proto,
  output logic          ev_lerr
);
  localparam int BW = $clog2(RB);
  localparam int PW = $clog2(RB) + 1;
  localparam int TW = $clog2(TO);
  localparam int HW = $clog2(HT);
  localparam int NW = $clog2(NR);
  localparam logic [7:0] M_ADV = 8'h01, M_FIN = 8'h02, M_REQ = 8'h03, M_RSP = 8'h04,
                         M_L1REQ = 8'h05, M_L1RSP = 8'h06, M_PMNAK = 8'h07;

  typedef enum logic [2:0] {S_RESET, S_PARAM, S_ACTREQ, S_ACTIVE, S_L1, S_RETRAIN, S_LINKERR} lsm_t;
  lsm_t st;
  assign state = st;

  function automatic logic [15:0] crc16(input logic [527:0] d);
    logic [15:0] c;
    c = 16'hFFFF;
    for (int i = 527; i >= 0; i--)
      c = {c[14:0], 1'b0} ^ ((c[15] ^ d[i]) ? 16'h1021 : 16'h0000);
    crc16 = c;
  endfunction

  // ---------------- link state ----------------
  logic [1:0]  oc, fc, far_adv, far_fin;  // own, negotiated, far AdvCap, far FinCap
  logic        got_adv, got_fin, fin_sent, req_got, rsp_got, l1_wait, pm_arm;
  logic        p_adv, p_fin, p_rsp, p_req, p_l1rsp, p_pmnak, p_l1req;  // sideband owed
  logic [HW-1:0] ht;
  assign cap = fc;

  // ---------------- Retry ----------------
  logic [512:0] rb [0:RB-1];             // {stack, payload}
  logic [5:0]  ws, as, rp;               // next new, oldest outstanding, next to send
  logic [5:0]  exp;                      // next SEQ expected
  logic [TW-1:0] tmr;
  logic [NW-1:0] nrc;                    // replays without progress
  logic        ack_owed, nak_owed, nak_sent;
  wire  [PW-1:0] outst = PW'(ws - as);          // at most RB
  wire         replaying = rp != ws;
  assign tx_pend = outst;
  assign tx_ready = st == S_ACTIVE && !l1_wait && (!fc[0] || outst != PW'(RB) && !replaying);

  // received flit
  wire         r_ok = crc16(lr_flit[543:16]) == lr_flit[15:0];
  wire         r_data = lr_flit[543];
  wire         r_stk = lr_flit[542];
  wire         r_nak = lr_flit[541];
  wire         r_rty = lr_flit[540];
  wire  [5:0]  r_seq = lr_flit[539:534];
  wire  [5:0]  r_ack = lr_flit[533:528];
  wire  [5:0]  r_n = r_ack + 6'd1 - as;  // flits this ACK frees
  wire  [5:0]  r_behind = exp - r_seq;
  wire         sb_l1_ok = outst == '0 && !ack_owed && !nak_owed && !tx_valid;

  always_ff @(posedge clk or negedge rst_n)
    if (!rst_n) begin
      st <= S_RESET;
      oc <= '0; fc <= '0; far_adv <= '0; far_fin <= '0;
      got_adv <= 1'b0; got_fin <= 1'b0; fin_sent <= 1'b0; req_got <= 1'b0; rsp_got <= 1'b0;
      l1_wait <= 1'b0; pm_arm <= 1'b0;
      p_adv <= 1'b0; p_fin <= 1'b0; p_rsp <= 1'b0; p_req <= 1'b0; p_l1rsp <= 1'b0; p_pmnak <= 1'b0; p_l1req <= 1'b0;
      ht <= '0;
      for (int i = 0; i < RB; i++) rb[i] <= '0;
      ws <= '0; as <= '0; rp <= '0; exp <= '0; tmr <= '0; nrc <= '0;
      ack_owed <= 1'b0; nak_owed <= 1'b0; nak_sent <= 1'b0;
      lt_valid <= 1'b0; lt_flit <= '0; rx_valid <= 1'b0; rx_stack <= 1'b0; rx_data <= '0;
      sb_tx_valid <= 1'b0; sb_tx_msg <= '0; lp_retrain <= 1'b0;
      ev_crc <= 1'b0; ev_replay <= 1'b0; ev_retrain <= 1'b0; ev_pmnak <= 1'b0; ev_proto <= 1'b0; ev_lerr <= 1'b0;
    end else begin : b_main
      lsm_t        n_st;
      logic        ga, gf, fs, rq, rs, lw, arm;
      logic        pa, pf, pr, pq, pl, pn, pk;
      logic [5:0]  as_n, rp_n, ws_n, ex_n;
      logic        ack_n, nak_n, nks_n, prog, rep, proto, lerr, snd, adv_rs;
      logic [15:0] hdr;
      logic [511:0] pl_;
      n_st = st;
      ga = got_adv; gf = got_fin; fs = fin_sent; rq = req_got; rs = rsp_got; lw = l1_wait;
      arm = pm_arm || !pm_req;
      pa = p_adv; pf = p_fin; pr = p_rsp; pq = p_req; pl = p_l1rsp; pn = p_pmnak; pk = p_l1req;
      as_n = as; rp_n = rp; ws_n = ws; ex_n = exp;
      ack_n = ack_owed; nak_n = nak_owed; nks_n = nak_sent;
      prog = 1'b0; rep = 1'b0; proto = 1'b0; adv_rs = 1'b0; lerr = 1'b0; snd = 1'b0; hdr = '0; pl_ = '0;
      lt_valid <= 1'b0; rx_valid <= 1'b0; sb_tx_valid <= 1'b0; lp_retrain <= 1'b0;
      ev_crc <= 1'b0; ev_replay <= 1'b0; ev_retrain <= 1'b0; ev_pmnak <= 1'b0;

      // ---- sideband transmit: one owed message per clock
      if (p_adv | p_fin | p_rsp | p_req | p_l1rsp | p_pmnak | p_l1req) begin
        sb_tx_valid <= 1'b1;
        if (p_adv)        begin sb_tx_msg <= {M_ADV, 6'd0, oc}; pa = 1'b0; end
        else if (p_fin)   begin sb_tx_msg <= {M_FIN, 6'd0, fc}; pf = 1'b0; end
        else if (p_rsp)   begin sb_tx_msg <= {M_RSP, 8'd0};     pr = 1'b0; end
        else if (p_req)   begin sb_tx_msg <= {M_REQ, 8'd0};     pq = 1'b0; end
        else if (p_l1rsp) begin sb_tx_msg <= {M_L1RSP, 8'd0};   pl = 1'b0; end
        else if (p_pmnak) begin sb_tx_msg <= {M_PMNAK, 8'd0};   pn = 1'b0; end
        else              begin sb_tx_msg <= {M_L1REQ, 8'd0};   pk = 1'b0; end
      end

      // ---- sideband receive
      if (sb_rx_valid)
        case (sb_rx_msg[15:8])
          M_ADV:
            if (st == S_LINKERR) proto = 1'b1;
            else begin
              far_adv <= sb_rx_msg[1:0]; ga = 1'b1;
              if (st == S_PARAM && fin_sent) fs = 1'b0;                     // FinCap again
              else if (st != S_RESET && st != S_PARAM) begin n_st = S_RESET; adv_rs = 1'b1; end  // far side restarted
            end
          M_FIN:
            if (st == S_PARAM) begin far_fin <= sb_rx_msg[1:0]; gf = 1'b1; end
            else proto = 1'b1;
          M_REQ:
            case (st)
              S_PARAM, S_RETRAIN: rq = 1'b1;
              S_ACTREQ: begin rq = 1'b1; pr = 1'b1; end
              S_ACTIVE, S_L1: begin n_st = S_ACTREQ; rq = 1'b1; rs = 1'b0; pr = 1'b1; pq = 1'b1; lw = 1'b0; end
              default: proto = 1'b1;
            endcase
          M_RSP:
            if (st == S_ACTREQ) rs = 1'b1;
            else proto = 1'b1;
          M_L1REQ:
            if (st == S_ACTIVE) begin
              if (cfg_l1_ok && sb_l1_ok && !lr_valid) begin pl = 1'b1; n_st = S_L1; lw = 1'b0; end
              else pn = 1'b1;
            end else proto = 1'b1;
          M_L1RSP:
            if (st == S_ACTIVE && l1_wait) begin n_st = S_L1; lw = 1'b0; end
            else if (st != S_L1) proto = 1'b1;
          M_PMNAK:
            if (st == S_ACTIVE && l1_wait) begin lw = 1'b0; ev_pmnak <= 1'b1; end
            else proto = 1'b1;
          default: proto = 1'b1;
        endcase

      // ---- main band transmit, ACTIVE only
      if (st == S_ACTIVE) begin
        if (fc[0]) begin
          if (replaying) begin
            snd = 1'b1; hdr[15] = 1'b1; hdr[14] = rb[rp[BW-1:0]][512]; hdr[11:6] = rp;
            pl_ = rb[rp[BW-1:0]][511:0]; rp_n = rp + 1'b1;
          end else if (tx_valid && tx_ready) begin
            if (tx_stack && !fc[1]) proto = 1'b1;
            else begin
              snd = 1'b1; hdr[15] = 1'b1; hdr[14] = tx_stack; hdr[11:6] = ws; pl_ = tx_data;
              rb[ws[BW-1:0]] <= {tx_stack, tx_data}; ws_n = ws + 1'b1; rp_n = rp + 1'b1;
            end
          end else if (ack_owed || nak_owed) snd = 1'b1;
          if (snd) begin
            hdr[13] = nak_owed; hdr[12] = 1'b1; hdr[5:0] = exp - 6'd1;
            ack_n = 1'b0; nak_n = 1'b0;
          end
        end else if (tx_valid && tx_ready) begin
          if (tx_stack && !fc[1]) proto = 1'b1;
          else begin snd = 1'b1; hdr[15] = 1'b1; hdr[14] = tx_stack; pl_ = tx_data; end
        end
        if (snd) begin
          lt_valid <= 1'b1;
          lt_flit <= {hdr, pl_, crc16({hdr, pl_})};
        end
      end

      // ---- main band receive, ACTREQ and ACTIVE
      if (lr_valid) begin
        if (st != S_ACTREQ && st != S_ACTIVE) proto = 1'b1;
        else if (!r_ok) begin
          ev_crc <= 1'b1;
          if (!fc[0]) lerr = 1'b1;
          else if (!nak_sent) begin nak_n = 1'b1; nks_n = 1'b1; end
        end else if (r_rty != fc[0]) proto = 1'b1;
        else if (fc[0]) begin
          if (r_n <= 6'(outst)) begin as_n = as + r_n; prog = r_n != '0; end
          if (r_nak) begin rp_n = as_n; rep = 1'b1; end
          if (r_data) begin
            if (r_seq == exp) begin
              ex_n = exp + 1'b1; ack_n = 1'b1; nks_n = 1'b0;
              if (r_stk && !fc[1]) proto = 1'b1;
              else begin rx_valid <= 1'b1; rx_stack <= r_stk; rx_data <= lr_flit[527:16]; end
            end else if (r_behind <= 6'(RB)) ack_n = 1'b1;          // an old SEQ (behind 0 is the expected one)
            else if (!nak_sent) begin nak_n = 1'b1; nks_n = 1'b1; end
          end
        end else if (!r_data || r_stk && !fc[1]) proto = 1'b1;
        else begin rx_valid <= 1'b1; rx_stack <= r_stk; rx_data <= lr_flit[527:16]; end
      end

      // ---- replay timer and retrain escalation (Retry, ACTIVE)
      if (st != S_ACTIVE || !fc[0] || prog || ws == as || replaying) tmr <= '0;
      else if (32'(tmr) == TO - 1) begin tmr <= '0; rep = 1'b1; rp_n = as_n; end
      else tmr <= tmr + 1'b1;
      if (rep) ev_replay <= 1'b1;
      if (prog) nrc <= '0;
      else if (rep) begin
        if (32'(nrc) == NR - 1) begin nrc <= '0; lp_retrain <= 1'b1; ev_retrain <= 1'b1; end
        else nrc <= nrc + 1'b1;
      end
      // a replay never resends what is acknowledged
      if (rp_n - as_n > ws_n - as_n) rp_n = as_n;

      // ---- link state
      case (st)
        S_RESET:
          if (link_en && phy_up) begin
            n_st = S_PARAM; oc <= {cfg_stack1, cfg_retry}; pa = 1'b1;
          end
        S_PARAM: begin
          if (ga && !fin_sent) begin fc <= oc & (sb_rx_valid && sb_rx_msg[15:8] == M_ADV ? sb_rx_msg[1:0] : far_adv); pf = 1'b1; fs = 1'b1; end
          if (fin_sent && gf) begin
            if ((sb_rx_valid && sb_rx_msg[15:8] == M_FIN ? sb_rx_msg[1:0] : far_fin) == fc) begin
              n_st = S_ACTREQ; pq = 1'b1; pr = rq; rs = 1'b0;
            end else lerr = 1'b1;
          end
        end
        S_ACTREQ:
          if (rq && rs) begin n_st = S_ACTIVE; rq = 1'b0; rs = 1'b0; rp_n = as_n; end
        S_ACTIVE:
          if (n_st == S_ACTIVE && !lw && pm_req && pm_arm && sb_l1_ok) begin pk = 1'b1; lw = 1'b1; arm = 1'b0; end
        S_L1:
          if (n_st == S_L1 && tx_valid) begin n_st = S_ACTREQ; pq = 1'b1; rs = 1'b0; end
        S_RETRAIN:
          if (phy_up) begin n_st = S_ACTREQ; pq = 1'b1; pr = rq; rs = 1'b0; end
        default: ;
      endcase
      if (n_st == S_L1 && st != S_L1) arm = 1'b0;

      // handshake timeout
      if (n_st == st && (st == S_PARAM || st == S_ACTREQ)) begin
        if (32'(ht) == HT - 1) lerr = 1'b1;
        else ht <= ht + 1'b1;
      end else ht <= '0;

      // physical layer down
      if (!phy_up)
        case (st)
          S_PARAM: n_st = S_RESET;
          S_ACTREQ, S_ACTIVE, S_L1: begin
            n_st = S_RETRAIN; rq = 1'b0; rs = 1'b0; lw = 1'b0;
            {pa, pf, pr, pq, pl, pn, pk} = '0;
            tmr <= '0; nrc <= '0; lerr = 1'b0;
          end
          default: ;
        endcase
      if (lerr && n_st != S_RESET) begin
        n_st = S_LINKERR; ev_lerr <= 1'b1; lw = 1'b0;
        {pa, pf, pr, pq, pl, pn, pk} = '0;
      end else ev_lerr <= 1'b0;

      // link disabled, or a new session: everything cleared
      if (!link_en && st != S_RESET || n_st == S_RESET && st != S_RESET) begin
        n_st = S_RESET;
        fc <= '0; ga = 1'b0; gf = 1'b0; fs = 1'b0; rq = 1'b0; rs = 1'b0; lw = 1'b0;
        {pa, pf, pr, pq, pl, pn, pk} = '0;
        as_n = '0; rp_n = '0; ws_n = '0; ex_n = '0; ack_n = 1'b0; nak_n = 1'b0; nks_n = 1'b0;
        tmr <= '0; nrc <= '0; ev_lerr <= 1'b0; ht <= '0;
        if (adv_rs && link_en) ga = 1'b1;                             // kept for the new session
      end

      ev_proto <= proto;
      st <= n_st;
      got_adv <= ga; got_fin <= gf; fin_sent <= fs; req_got <= rq; rsp_got <= rs; l1_wait <= lw; pm_arm <= arm;
      p_adv <= pa; p_fin <= pf; p_rsp <= pr; p_req <= pq; p_l1rsp <= pl; p_pmnak <= pn; p_l1req <= pk;
      as <= as_n; rp <= rp_n; ws <= ws_n; exp <= ex_n;
      ack_owed <= ack_n; nak_owed <= nak_n; nak_sent <= nks_n;
    end
endmodule
