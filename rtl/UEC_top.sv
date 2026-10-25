// SPDX-License-Identifier: Apache-2.0
// ============================================================================
// UEC_top v2.0: Ultra Ethernet Transport-style packet delivery sublayer
// (PDS), one packet delivery context (PDC) in reliable unordered delivery
// (RUD) mode: PSNs, a retransmit window, cumulative + selective ACKs,
// NACKs for no receive buffer, a retransmit timer
// ----------------------------------------------------------------------------
//  - Network side: frames of bytes with valid / last (an Ethernet MAC
//    client: the MAC, IP / UDP headers and the FCS belong below, and a
//    frame with a bad FCS never arrives). net_tx_* has back-pressure
//    (net_tx_ready); net_rx_* has none. Fields go most significant byte
//    first. Frames:
//      DATA  {8'h10, PSN[15:0], LEN[7:0], payload[LEN]}   LEN 1..MAXP
//      ACK   {8'h20, CACK[15:0], SACK[7:0]}  CACK: every PSN up to it was
//            received; SACK bit j: PSN CACK + 2 + j was received (j < W-1)
//      NACK  {8'h30, PSN[15:0]}   PSN was dropped: no receive buffer
//    Any other type byte, a length that does not match the frame or a DATA
//    LEN of 0 or over MAXP: the frame is dropped (ev_proto).
//  - Host side: packets of 1..MAXP bytes written through tx_* (tx_last on
//    the final byte; a write of more than MAXP bytes is cut into packets),
//    received packets read through rx_* in arrival order (unordered with
//    respect to PSN: RUD hands a packet over as soon as it arrives once).
//  - Sender: a packet gets the next PSN (from start_psn_tx) and a slot in
//    the retransmit buffer of W packets; at most W are outstanding. It is
//    sent once, kept until an ACK covers it (CACK or SACK), sent again on
//    a NACK for it, and every sent, unacknowledged packet is sent again
//    when the retransmit timer (RTO clocks without progress) expires
//    (ev_rto). An ACK whose CACK is behind is ignored (late), one past the
//    packets sent is dropped (ev_proto); a NACK for a PSN no longer
//    outstanding is ignored, one for a PSN not sent is dropped (ev_proto).
//  - Receiver: expects PSNs from start_psn_rx; tracks the cumulative PSN
//    and which of the next W - 1 arrived. A new packet goes to one of RXB
//    receive buffers; with none free at its first byte it is dropped and
//    NACKed (ev_nobuf). A packet received before (or behind the window) is
//    dropped (ev_dup). Every DATA frame in or behind the window (new, a
//    duplicate or NACKed) makes an ACK due; one ACK with the state at the
//    time it is sent covers all that are due.
//    A PSN past the window (no sender can send it) is dropped (ev_proto).
//  - Transmit order: NACK, ACK, retransmissions (lowest PSN first), new
//    packets. enable low closes the PDC (it must be low for a clock after
//    reset, to load the start PSNs): everything (buffers, both PSN
//    spaces, a frame in progress: it is cut, and the MAC must drop it) is
//    dropped and starts again from the
//    start PSNs when it rises.
//  Not implemented: PDC establishment and teardown (the PSNs and enable are
//  pins here), the other delivery modes (ROD, RUDI, UUD), the semantic
//  sublayer, congestion control (NSCC / RCCC) and packet spraying,
//  ACK coalescing timers and ACK-CC, the security sublayer, multiple PDCs.
//  Frame layouts are our own; they follow the shape of UET PDS headers but
//  not their encodings.
// ============================================================================
module UEC_top #(
  parameter int MAXP = 16,          // payload bytes in a packet (power of 2, at most 128)
  parameter int W    = 4,           // retransmit window, packets (power of 2, 2..8)
  parameter int RXB  = 2,           // receive buffers (power of 2)
  parameter int RTO  = 256          // retransmit timeout, clocks (power of 2)
)(
  input  logic        clk,
  input  logic        rst_n,
  input  logic        enable,           // the PDC is open
  input  logic [15:0] start_psn_tx,
  input  logic [15:0] start_psn_rx,
  // host
  input  logic        tx_valid,
  output logic        tx_ready,
  input  logic [7:0]  tx_data,
  input  logic        tx_last,
  output logic        rx_valid,
  input  logic        rx_ready,
  output logic [7:0]  rx_data,
  output logic        rx_last,
  // network
  output logic        net_tx_valid,
  input  logic        net_tx_ready,
  output logic [7:0]  net_tx_data,
  output logic        net_tx_last,
  input  logic        net_rx_valid,
  input  logic [7:0]  net_rx_data,
  input  logic        net_rx_last,
  // status, events
  output logic [$clog2(W):0] outstanding,
  output logic        ev_rto,
  output logic        ev_nack,          // a NACK was received: the packet is sent again
  output logic        ev_dup,
  output logic        ev_nobuf,
  output logic        ev_proto
);
  localparam int SW = $clog2(W), PW = $clog2(MAXP), RW = $clog2(RXB), TW = $clog2(RTO);
  localparam int LW = $clog2(MAXP + 5);         // frame byte counts
  localparam logic [7:0] T_DATA = 8'h10, T_ACK = 8'h20, T_NACK = 8'h30;

  // ---------------- sender ----------------
  logic [7:0]    sbuf [0:W*MAXP-1];
  logic [PW:0]   slen [0:W-1];
  logic [W-1:0]  out_f, rtx_f;
  logic [15:0]   sbase, snew, snext;           // oldest outstanding, next to send first, next to assign
  logic [PW-1:0] wpos;
  logic [TW-1:0] tmr;
  wire  [SW:0]   s_cnt = (SW+1)'(snext - sbase);
  wire  [SW:0]   s_sent = (SW+1)'(snew - sbase);
  assign outstanding = s_cnt;

  // transmitter
  logic          t_on;
  logic [1:0]    t_kind;                       // 0 ACK, 1 NACK, 2 DATA
  logic [LW-1:0] t_cnt, t_len;
  logic [15:0]   t_psn;
  logic [PW:0]   t_b3;                         // LEN or SACK
  logic [SW-1:0] t_slot;
  assign tx_ready = rst_n && enable && s_cnt != (SW+1)'(W) && !(t_on && t_kind == 2'd2 && t_slot == snext[SW-1:0]);
  assign net_tx_valid = t_on;
  assign net_tx_last = t_cnt == t_len - 1'b1;
  assign net_tx_data = t_cnt == LW'(0) ? (t_kind == 2'd0 ? T_ACK : t_kind == 2'd1 ? T_NACK : T_DATA) :
                       t_cnt == LW'(1) ? t_psn[15:8] : t_cnt == LW'(2) ? t_psn[7:0] : t_cnt == LW'(3) ? 8'(t_b3) :
                       sbuf[{t_slot, PW'(t_cnt - LW'(4))}];

  // ---------------- receiver ----------------
  logic [15:0]   rbase;                        // next PSN not yet received
  logic [W-1:1]  rbits;                        // rbase + i received
  logic          ack_pend, nack_pend;
  logic [15:0]   nack_psn;
  logic [7:0]    rbuf [0:RXB*MAXP-1];
  logic [PW:0]   rlen [0:RXB-1];
  logic [RW:0]   rw, rr;
  logic [PW-1:0] rgot;
  wire           r_free = (rw - rr) != (RW+1)'(RXB);
  assign rx_valid = rw != rr;
  assign rx_data = rbuf[{rr[RW-1:0], rgot}];
  assign rx_last = (PW+1)'(rgot) == rlen[rr[RW-1:0]] - 1'b1;

  // frame parser
  logic [LW-1:0] p_cnt;                        // bytes so far (saturates)
  logic [7:0]    p_type, p_b3;
  logic [15:0]   p_psn;
  logic          p_buf;                        // a receive buffer was free at the first byte

  always_ff @(posedge clk or negedge rst_n)
    if (!rst_n) begin
      for (int i = 0; i < W; i++) slen[i] <= '0;
      for (int i = 0; i < RXB; i++) rlen[i] <= '0;
      out_f <= '0; rtx_f <= '0; sbase <= '0; snew <= '0; snext <= '0; wpos <= '0;
      tmr <= '0; t_on <= 1'b0; t_kind <= '0; t_cnt <= '0; t_len <= '0; t_psn <= '0; t_b3 <= '0; t_slot <= '0;
      rbase <= '0; rbits <= '0; ack_pend <= 1'b0; nack_pend <= 1'b0; nack_psn <= '0;
      rw <= '0; rr <= '0; rgot <= '0; p_cnt <= '0; p_type <= '0; p_b3 <= '0; p_psn <= '0; p_buf <= 1'b0;
      {ev_rto, ev_nack, ev_dup, ev_nobuf, ev_proto} <= '0;
    end else if (!enable) begin
      out_f <= '0; rtx_f <= '0; sbase <= start_psn_tx; snew <= start_psn_tx; snext <= start_psn_tx; wpos <= '0;
      tmr <= '0; t_on <= 1'b0; t_cnt <= '0;
      rbase <= start_psn_rx; rbits <= '0; ack_pend <= 1'b0; nack_pend <= 1'b0; rw <= '0; rr <= '0; rgot <= '0;
      p_cnt <= '0;
      {ev_rto, ev_nack, ev_dup, ev_nobuf, ev_proto} <= '0;
    end else begin : b_main
      logic [W-1:0] fr, rt;                    // slots freed, marked for retransmission
      logic [15:0]  sb;
      logic         prog, an, as;              // progress, an ACK due now, an ACK sent
      fr = '0; rt = rtx_f; prog = 1'b0; an = 1'b0; as = 1'b0;
      {ev_rto, ev_nack, ev_dup, ev_nobuf, ev_proto} <= '0;

      // ---- host write
      if (tx_valid && tx_ready) begin
        sbuf[{snext[SW-1:0], wpos}] <= tx_data;
        if (tx_last || wpos == PW'(MAXP - 1)) begin
          slen[snext[SW-1:0]] <= (PW+1)'(wpos) + 1'b1;
          snext <= snext + 1'b1;
          wpos <= '0;
        end else wpos <= wpos + 1'b1;
      end

      // ---- host read
      if (rx_valid && rx_ready) begin
        if (rx_last) begin rr <= rr + 1'b1; rgot <= '0; end
        else rgot <= rgot + 1'b1;
      end

      // ---- receive a frame
      if (net_rx_valid) begin
        if (p_cnt == LW'(0)) begin p_type <= net_rx_data; p_buf <= r_free; end
        if (p_cnt == LW'(1)) p_psn[15:8] <= net_rx_data;
        if (p_cnt == LW'(2)) p_psn[7:0] <= net_rx_data;
        if (p_cnt == LW'(3)) p_b3 <= net_rx_data;
        if (p_cnt >= LW'(4) && p_cnt < LW'(4 + MAXP) && p_buf) rbuf[{rw[RW-1:0], PW'(p_cnt - LW'(4))}] <= net_rx_data;
        p_cnt <= net_rx_last ? '0 : &p_cnt ? p_cnt : p_cnt + 1'b1;
        if (net_rx_last) begin : b_frame
          logic [7:0]  b3;
          logic [15:0] psn, d;
          // the frame with this byte (a frame of 1 or 2 bytes is never good)
          psn = {p_psn[15:8], p_cnt == LW'(2) ? net_rx_data : p_psn[7:0]};
          b3 = p_cnt == LW'(3) ? net_rx_data : p_b3;
          if (p_type == T_DATA && b3 != 8'd0 && b3 <= 8'(MAXP) && 8'(p_cnt) == b3 + 8'd3) begin
            d = psn - rbase;
            if (d < 16'(W) && (d == '0 || !rbits[SW'(d)])) begin
              an = 1'b1;
              if (p_buf) begin
                rlen[rw[RW-1:0]] <= (PW+1)'(b3);
                rw <= rw + 1'b1;
                if (d == '0) begin : b_adv
                  logic [W-1:0] m, sh;
                  logic [SW:0]  z;
                  // rbase and the run received after it
                  m = {rbits, 1'b1};
                  z = '0;
                  for (int i = 0; i < W; i++) if (m[i] && z == (SW+1)'(i)) z = (SW+1)'(i + 1);
                  sh = m >> z;
                  rbase <= rbase + 16'(z);
                  rbits <= sh[W-1:1];
                end else rbits[SW'(d)] <= 1'b1;
              end else begin
                ev_nobuf <= 1'b1;
                if (!nack_pend) begin nack_pend <= 1'b1; nack_psn <= psn; end
              end
            end else if (d < 16'(W) || d[15]) begin ev_dup <= 1'b1; an = 1'b1; end
            else ev_proto <= 1'b1;
          end else if (p_type == T_ACK && p_cnt == LW'(3)) begin
            // k: packets newly covered by CACK
            d = psn - sbase + 16'd1;
            if (d[15]) ;                                        // late
            else if (d > 16'(s_sent)) ev_proto <= 1'b1;
            else begin
              for (int i = 0; i < W; i++) begin
                if (16'(i) < d) fr[SW'(sbase + 16'(i))] = 1'b1;
                for (int j = 0; j < W - 1; j++)
                  if (b3[j] && 16'(i) == d + 16'(j + 1) && 16'(i) < 16'(s_sent)) fr[SW'(sbase + 16'(i))] = 1'b1;
              end
            end
          end else if (p_type == T_NACK && p_cnt == LW'(2)) begin
            d = psn - sbase;
            if (d < 16'(s_sent)) begin
              if (out_f[SW'(psn)]) begin rt[SW'(psn)] = 1'b1; ev_nack <= 1'b1; end
            end else if (!d[15]) ev_proto <= 1'b1;
          end else ev_proto <= 1'b1;
        end
      end

      // ---- the oldest slot acknowledged: the window moves
      sb = sbase;
      if (sbase != snew && !out_f[sbase[SW-1:0]]) begin sb = sbase + 1'b1; prog = 1'b1; end
      sbase <= sb;
      if (fr != '0) prog = 1'b1;

      // ---- retransmit timer
      if (prog || sbase == snew) tmr <= '0;
      else if (tmr == TW'(RTO - 1)) begin
        tmr <= '0;
        ev_rto <= 1'b1;
        for (int i = 0; i < W; i++) if ((SW+1)'(i) < s_sent && out_f[SW'(sbase + 16'(i))]) rt[SW'(sbase + 16'(i))] = 1'b1;
      end else tmr <= tmr + 1'b1;

      // ---- transmit
      if (t_on && net_tx_ready) begin
        t_cnt <= t_cnt + 1'b1;
        if (net_tx_last) t_on <= 1'b0;
      end
      if (!t_on) begin : b_pick
        logic [SW-1:0] k;
        logic          kf;
        // the lowest PSN marked for retransmission
        kf = 1'b0; k = '0;
        for (int i = W - 1; i >= 0; i--)
          if ((SW+1)'(i) < s_sent && rt[SW'(sbase + 16'(i))] && !fr[SW'(sbase + 16'(i))])
            begin kf = 1'b1; k = SW'(i); end
        t_cnt <= '0;
        if (nack_pend) begin
          t_on <= 1'b1; t_kind <= 2'd1; t_len <= LW'(3); t_psn <= nack_psn; nack_pend <= 1'b0;
        end else if (ack_pend) begin
          t_on <= 1'b1; t_kind <= 2'd0; t_len <= LW'(4); t_psn <= rbase - 1'b1; t_b3 <= (PW+1)'(rbits);
          as = 1'b1;
        end else if (kf) begin
          t_on <= 1'b1; t_kind <= 2'd2; t_psn <= sbase + 16'(k); t_slot <= SW'(sbase + 16'(k));
          t_len <= LW'(4) + LW'(slen[SW'(sbase + 16'(k))]); t_b3 <= slen[SW'(sbase + 16'(k))];
          rt[SW'(sbase + 16'(k))] = 1'b0;
        end else if (snew != snext) begin
          t_on <= 1'b1; t_kind <= 2'd2; t_psn <= snew; t_slot <= snew[SW-1:0];
          t_len <= LW'(4) + LW'(slen[snew[SW-1:0]]); t_b3 <= slen[snew[SW-1:0]];
          snew <= snew + 1'b1;
        end
      end
      out_f <= out_f & ~fr | ((tx_valid && tx_ready && (tx_last || wpos == PW'(MAXP - 1))) ? W'(1) << snext[SW-1:0] : '0);
      rtx_f <= rt & ~fr;                       // only outstanding slots are ever marked
      ack_pend <= an || ack_pend && !as;
    end
endmodule
