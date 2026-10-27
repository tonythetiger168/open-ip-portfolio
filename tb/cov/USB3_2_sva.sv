// SPDX-License-Identifier: Apache-2.0
// USB 3.2 link layer: concurrent SVA against an independent reference model,
// plus functional coverage.
//  * Transmit: the model keeps the written packets as byte queues (oldest
//    unacknowledged first), picks the next packet between packets by the
//    same priorities, builds all its symbols at once (its own CRCs, padding
//    and payload) and the line must carry them one per clock.
//  * Receive: the model collects a header packet's 16 bytes, a link
//    command's 4 bytes or a payload up to its end set and judges them
//    whole; packets go into a queue of byte queues that rx_* must show.
//  * Link commands update the model's sequence numbers, credits, retry and
//    advertisement state; its own timers decide recovery.
// Every output is compared on every clock.
`include "cov_macros.svh"
module USB3_2_sva #(
  parameter int MAXD = 32, TXN = 4, RXN = 4, PEND_TO = 400, CRED_TO = 2000
)(
  input logic       clk, rst_n, link_up, recovery,
  input logic [7:0] tx_sym,
  input logic       tx_k,
  input logic [7:0] rx_sym,
  input logic       rx_k,
  input logic       tx_valid, tx_ready,
  input logic [7:0] tx_data,
  input logic       tx_last,
  input logic       rx_valid, rx_ready,
  input logic [7:0] rx_data,
  input logic       rx_last, rx_err, ll_up,
  input logic       ev_hp_bad, ev_seq, ev_lc_bad, ev_dpp_bad, ev_frame, ev_proto, ev_overflow, ev_lbad, ev_timeout
);
  `COV_CLOCKING(clk, !rst_n)
  typedef logic [7:0] bq_t [$];
  localparam int PL = 12 + MAXD;

  function automatic logic [31:0] c32(input logic [31:0] c, input logic [7:0] b);
    for (int i = 7; i >= 0; i--) begin
      bit fb;
      fb = c[31] ^ b[i];
      c = c << 1;
      if (fb) c ^= 32'h04C1_1DB7;
    end
    return c;
  endfunction
  function automatic logic [15:0] c16(input logic [15:0] c, input logic [7:0] b);
    for (int i = 7; i >= 0; i--) begin
      bit fb;
      fb = c[15] ^ b[i];
      c = c << 1;
      if (fb) c ^= 16'h100B;
    end
    return c;
  endfunction
  // {CRC-5, info}
  function automatic logic [15:0] w5(input logic [10:0] info);
    logic [4:0] c;
    c = '1;
    for (int i = 10; i >= 0; i--) begin
      bit fb;
      fb = c[4] ^ info[i];
      c = c << 1;
      if (fb) c ^= 5'h05;
    end
    return {~c, info};
  endfunction
  function automatic int m16(input int a);
    return a & 15;
  endfunction

  // ---------------- model state ----------------
  int     ll;                           // 0 down, 1 advertising, 2 up, 3 recovery
  // transmit
  bq_t    tq [$];                       // written, unacknowledged packets; tq[0] has sequence ackd + 1
  bq_t    wb;                           // packet being written
  int     ackd, txs, nsent, cnext, cr, tlet, ptmr, ctmr, lbn, tcur;
  bit     rpq, lrty, tlp_on;            // tlp_on: a header packet (and payload) is being sent
  logic [8:0] ts [$];                   // {k, symbol} still to send
  logic [8:0] m_sym;
  // receive
  int     rs, oc, rxs, lgc, lcc, rlet, rgot;   // rs: 0 idle, 1 ordered set, 2 HP, 3 payload, 4 end set, 5 LC
  logic [7:0] ost;
  logic [7:0] rp [$];                   // bytes of the packet so far
  bit     waitr, dpw, dcol, hroom, lgadv, lbadp;
  bq_t    hdr;                          // the open DP's header
  bq_t    rq [$];                       // packets received
  bit     rqe [$];                      // their payload failed
  bit     m_rdy, m_rxv, m_rxl, m_rxe, m_rec;
  logic [7:0] m_rxd;
  bit     m_hpbad, m_seq, m_lcbad, m_dpp, m_fr, m_pro, m_ovf, m_lbad, m_to;
  // coverage
  bit v_cut, v_pad, v_dp, v_dp_empty, v_dp_max, v_credit_wait, v_retry, v_retry_nocredit, v_lbad3, v_to_pend, v_to_cred;
  bit v_to_adv, v_adv_acks, v_adv_none, v_lgood_bad, v_lcrd_bad, v_lcrd_over, v_lbad_none, v_unknown_lc, v_lc_copy2;
  bit v_lrty_ignored, v_hp_ignored, v_dpp_crc, v_dpp_abort, v_dpp_long, v_dpp_short, v_dpp_missing, v_dpp_k;
  bit v_dpp_stray, v_os_data, v_os_long, v_os_bad, v_idle_k, v_hp_k, v_lc_k, v_ovf_dp, v_drop_busy, v_drop_dp;
  bit v_slot_wait, v_ack_while_sending, v_rx_full_read, v_rec_busy;
  // per-step copies for the covergroup (set at posedge, sampled at negedge)
  bit c_lv, c_hv, c_hrt, c_hdp, c_rv, c_rdp, c_pv;
  int c_lk, c_let, c_hseq, c_hlen, c_rseq, c_plen;

  always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      ll = 0; tq.delete(); wb.delete(); ackd = 15; txs = 0; nsent = 0; cnext = 0; cr = 0; tlet = 0;
      ptmr = 0; ctmr = 0; lbn = 0; tcur = 0; rpq = 0; lrty = 0; tlp_on = 0; ts.delete(); m_sym = 0;
      rs = 0; oc = 0; rxs = 0; lgc = 0; lcc = 0; rlet = 0; rgot = 0; ost = 0; rp.delete();
      waitr = 0; dpw = 0; dcol = 0; hroom = 0; lgadv = 0; lbadp = 0; hdr.delete(); rq.delete(); rqe.delete();
      {m_rec, m_hpbad, m_seq, m_lcbad, m_dpp, m_fr, m_pro, m_ovf, m_lbad, m_to} = '0;
      {c_lv, c_hv, c_hrt, c_hdp, c_rv, c_rdp, c_pv} = '0; c_lk = 0; c_let = 0; c_hseq = 0; c_hlen = 0; c_rseq = 0; c_plen = 0;
    end else begin : b_step
      int o_ll, o_ackd, o_nsent, o_txs, o_cnext, o_cr, o_lbn, o_rqn, o_tout, nq, eff, idx;
      bit o_rdy, avail, need, rec, commit, cerr, linc, cinc;
      o_ll = ll; o_ackd = ackd; o_nsent = nsent; o_txs = txs; o_cnext = cnext; o_cr = cr; o_lbn = lbn;
      o_rqn = rq.size(); nq = tq.size();
      o_tout = m16(o_nsent - o_ackd - 1);
      o_rdy = nq < TXN && !(tlp_on && m16(o_ackd + 1 + nq - tcur) % TXN == 0);
      eff = rpq || m16(o_ackd + 1 - o_txs) inside {[1:7]} ? m16(o_ackd + 1) : o_txs;
      idx = m16(eff - o_ackd - 1);
      avail = idx < nq;
      need = eff == o_cnext;
      rec = 0; commit = 0; cerr = 0; linc = 0; cinc = 0;
      {c_lv, c_hv, c_rv, c_pv} = '0;
      {m_rec, m_hpbad, m_seq, m_lcbad, m_dpp, m_fr, m_pro, m_ovf, m_lbad, m_to} = '0;

      // ---- transmit: the next symbol, or a new packet
      if (ts.size() != 0) begin
        m_sym = ts.pop_front();
        if (ts.size() == 0 && tlp_on) begin tlp_on = 0; txs = m16(tcur + 1); end
      end else begin : b_pick
        m_sym = 9'h000;
        if ((o_ll == 1 || o_ll == 2) && (lgadv || lrty || lbadp || lgc != 0 || lcc != 0)) begin : b_lc
          logic [10:0] info;
          logic [15:0] w;
          c_lv = 1;
          if (lgadv) begin info = 11'(m16(rxs - 1) & 7); lgadv = 0; c_lk = 0; end
          else if (lrty) begin info = 11'h100; lrty = 0; c_lk = 1; end
          else if (lbadp) begin info = 11'h180; lbadp = 0; c_lk = 2; end
          else if (lgc != 0) begin info = 11'((rxs - lgc) & 7); lgc--; c_lk = 3; end
          else begin info = 11'h080 | 11'(rlet); lcc--; c_lk = 4; c_let = rlet; rlet = (rlet + 1) & 3; end
          w = w5(info);
          m_sym = {1'b1, 8'hDC};
          ts.push_back({1'b1, 8'hDC}); ts.push_back({1'b1, 8'hDC}); ts.push_back({1'b1, 8'hF7});
          for (int i = 0; i < 2; i++) begin ts.push_back({1'b0, w[15:8]}); ts.push_back({1'b0, w[7:0]}); end
        end else if (o_ll == 2 && avail && (!need || o_cr != 0)) begin : b_hp
          logic [15:0] c, w;
          logic [31:0] d;
          logic [7:0]  b;
          int n;
          n = tq[idx].size();
          m_sym = {1'b1, 8'hFB};
          ts.push_back({1'b1, 8'hFB}); ts.push_back({1'b1, 8'hFB}); ts.push_back({1'b1, 8'hF7});
          c = '1;
          for (int i = 0; i < 12; i++) begin
            b = i < n ? tq[idx][i] : 8'h00;
            ts.push_back({1'b0, b}); c = c16(c, b);
          end
          c = ~c;
          ts.push_back({1'b0, c[15:8]}); ts.push_back({1'b0, c[7:0]});
          w = w5(11'(eff & 7));
          ts.push_back({1'b0, w[15:8]}); ts.push_back({1'b0, w[7:0]});
          if (tq[idx][0][4:0] == 5'b01000) begin
            v_dp = 1;
            if (n <= 12) v_dp_empty = 1;
            if (n == PL) v_dp_max = 1;
            for (int i = 0; i < 3; i++) ts.push_back({1'b1, 8'h5C});
            ts.push_back({1'b1, 8'hF7});
            d = '1;
            for (int i = 12; i < n; i++) begin ts.push_back({1'b0, tq[idx][i]}); d = c32(d, tq[idx][i]); end
            d = ~d;
            for (int i = 3; i >= 0; i--) ts.push_back({1'b0, d[8 * i +: 8]});
            for (int i = 0; i < 3; i++) ts.push_back({1'b1, 8'hFD});
            ts.push_back({1'b1, 8'hF7});
          end
          tlp_on = 1; tcur = eff; rpq = 0;
          c_hv = 1; c_hseq = eff & 7; c_hrt = !need && eff != o_nsent; c_hdp = tq[idx][0][4:0] == 5'b01000;
          c_hlen = n <= 12 ? 0 : (n == PL ? 2 : 1);
          if (eff == o_nsent) nsent = m16(o_nsent + 1);
          if (need) begin cnext = m16(o_cnext + 1); cr = o_cr - 1; end
          else if (eff != o_nsent) begin v_retry = 1; if (o_cr == 0) v_retry_nocredit = 1; end
        end else if (o_ll == 2 && avail && need && o_cr == 0) v_credit_wait = 1;
      end
      // ---- writing
      if (tx_valid && o_rdy) begin
        wb.push_back(tx_data);
        if (tx_last || wb.size() == PL) begin
          if (!tx_last) v_cut = 1;
          if (wb.size() < 12) v_pad = 1;
          tq.push_back(wb); wb.delete();
        end
      end else if (tx_valid && nq < TXN) v_slot_wait = 1;
      // ---- timers
      if (!(o_ll == 1 || o_ll == 2 && o_tout != 0)) ptmr = 0;
      else if (ptmr == PEND_TO) begin
        ptmr = 0; m_to = 1; rec = 1;
        if (o_ll == 1) v_to_adv = 1; else v_to_pend = 1;
      end else ptmr++;
      if (!(o_ll == 2 && avail && need && o_cr == 0)) ctmr = 0;
      else if (ctmr == CRED_TO) begin ctmr = 0; m_to = 1; rec = 1; v_to_cred = 1; end
      else ctmr++;

      // ---- receive
      if (!link_up) ;
      else if (!rx_k) begin
        if (rs == 2 || rs == 3 || rs == 5) rp.push_back(rx_sym);
        if (rs == 2 && rp.size() == 16) begin
          rs = 0;
          if (waitr) v_hp_ignored = 1;
          else begin : b_hp_rx
            logic [15:0] c, w;
            c = '1;
            for (int i = 0; i < 12; i++) c = c16(c, rp[i]);
            w = {rp[14], rp[15]};
            if ({rp[12], rp[13]} != ~c || w5(w[10:0]) != w) begin m_hpbad = 1; lbadp = 1; waitr = 1; end
            else if (w[2:0] != 3'(rxs)) begin m_seq = 1; rec = 1; end
            else if (!hroom) begin
              m_ovf = 1; dpw = rp[0][4:0] == 5'b01000;
              if (dpw) v_ovf_dp = 1;
            end else begin
              c_rv = 1; c_rseq = rxs; c_rdp = rp[0][4:0] == 5'b01000;
              rxs = (rxs + 1) & 7; linc = 1;
              hdr.delete();
              for (int i = 0; i < 12; i++) hdr.push_back(rp[i]);
              if (rp[0][4:0] == 5'b01000) begin dpw = 1; dcol = 1; end
              else commit = 1;
            end
          end
        end else if (rs == 5 && rp.size() == 4) begin : b_lc_rx
          logic [15:0] w1, w2, w;
          rs = 0;
          w1 = {rp[0], rp[1]}; w2 = {rp[2], rp[3]};
          w = w5(w1[10:0]) == w1 ? w1 : w2;
          if (w5(w1[10:0]) != w1 && w5(w2[10:0]) == w2) v_lc_copy2 = 1;
          if (w5(w[10:0]) != w) m_lcbad = 1;
          else if (o_ll == 1 || o_ll == 2) begin
            if (w[10:3] == 0) begin
              if (o_ll == 1) begin
                int k;
                k = (w[2:0] - o_ackd) & 7;
                if (k <= o_tout) begin
                  ll = 2;
                  repeat (k) void'(tq.pop_front());
                  ackd = m16(o_ackd + k); txs = m16(ackd + 1); cnext = txs;
                  if (k != 0) v_adv_acks = 1; else if (o_tout != 0) v_adv_none = 1;
                end else begin m_pro = 1; rec = 1; v_lgood_bad = 1; end
              end else if (o_tout != 0 && w[2:0] == 3'((o_ackd + 1) & 7)) begin
                void'(tq.pop_front()); ackd = m16(o_ackd + 1); lbn = 0; ptmr = 0;
                if (tlp_on) v_ack_while_sending = 1;
              end else begin m_pro = 1; rec = 1; v_lgood_bad = 1; end
            end else if (w[10:2] == 9'h020) begin
              if (w[1:0] == 2'(tlet) && cr != RXN) begin cr++; tlet = (tlet + 1) & 3; ctmr = 0; end
              else begin
                m_pro = 1; rec = 1;
                if (w[1:0] != 2'(tlet)) v_lcrd_bad = 1; else v_lcrd_over = 1;
              end
            end else if (w[10:0] == 11'h100) begin
              if (!waitr) v_lrty_ignored = 1;
              waitr = 0;
            end else if (w[10:0] == 11'h180) begin
              if (o_ll == 2 && o_tout != 0) begin
                m_lbad = 1; lrty = 1; rpq = 1; ptmr = 0; lbn = (o_lbn + 1) & 3;
                if (o_lbn == 2) begin rec = 1; v_lbad3 = 1; end
              end else begin m_pro = 1; rec = 1; v_lbad_none = 1; end
            end else begin m_pro = 1; v_unknown_lc = 1; end
          end
        end else if (rs == 1 || rs == 4) begin
          m_fr = 1; v_os_data = 1;
          if (rs == 4 && dcol) begin commit = 1; cerr = 1; m_dpp = 1; end
          rs = 0;
        end
      end else begin
        if (rs == 0) begin
          if (rx_sym inside {8'hFB, 8'h5C, 8'hDC}) begin rs = 1; ost = rx_sym; oc = 1; end
          else begin m_fr = 1; v_idle_k = 1; end
        end else if (rs == 1 || rs == 4) begin
          if (rx_sym == ost && oc != 3) oc++;
          else if (rx_sym == 8'hF7 && oc == 3) begin
            if (rs == 4) begin
              if (dcol) begin : b_dpp_end
                int n;
                logic [31:0] d;
                n = rp.size();
                commit = 1;
                if (ost == 8'h7C) begin cerr = 1; v_dpp_abort = 1; end
                else if (n < 4) begin cerr = 1; v_dpp_short = 1; end
                else if (n - 4 > MAXD) begin cerr = 1; v_dpp_long = 1; end
                else begin
                  d = '1;
                  for (int i = 0; i < n - 4; i++) d = c32(d, rp[i]);
                  if ({rp[n - 4], rp[n - 3], rp[n - 2], rp[n - 1]} != ~d) begin cerr = 1; v_dpp_crc = 1; end
                  else begin
                    for (int i = 0; i < n - 4; i++) hdr.push_back(rp[i]);
                    c_pv = 1; c_plen = n - 4 == 0 ? 0 : (n - 4 == MAXD ? 2 : 1);
                  end
                end
                if (cerr) m_dpp = 1;
              end
              rs = 0;
            end else begin
              if (dpw && ost != 8'h5C) begin
                dpw = 0;
                if (dcol) begin commit = 1; cerr = 1; m_dpp = 1; v_dpp_missing = 1; end
              end
              if (ost == 8'hFB) begin rs = 2; hroom = o_rqn + int'(commit) < RXN; end
              else if (ost == 8'hDC) rs = 5;
              else begin
                if (!dpw) v_dpp_stray = 1;
                rs = 3; dpw = 0;
              end
            end
            rp.delete();
          end else begin
            m_fr = 1;
            if (rx_sym == ost || rx_sym == 8'hF7) v_os_long = 1; else v_os_bad = 1;
            if (rs == 4 && dcol) begin commit = 1; cerr = 1; m_dpp = 1; end
            rs = 0;
          end
        end else if (rs == 3 && (rx_sym == 8'hFD || rx_sym == 8'h7C)) begin rs = 4; ost = rx_sym; oc = 1; end
        else begin
          m_fr = 1;
          if (rs == 2) begin
            v_hp_k = 1;
            if (!waitr) begin m_hpbad = 1; lbadp = 1; waitr = 1; end
          end else if (rs == 3) begin
            v_dpp_k = 1;
            if (dcol) begin commit = 1; cerr = 1; m_dpp = 1; end
          end else v_lc_k = 1;
          rs = 0;
        end
      end
      // ---- reading
      if (rx_valid && rx_ready && rq.size() != 0) begin
        rgot++;
        if (rgot == rq[0].size()) begin
          void'(rq.pop_front()); void'(rqe.pop_front()); rgot = 0; cinc = 1;
          if (o_rqn == RXN) v_rx_full_read = 1;
        end
      end
      // ---- the link
      if (!link_up) begin
        if (o_ll == 2 && (o_tout != 0 || tlp_on)) v_drop_busy = 1;
        ll = 0; ts.delete(); tlp_on = 0; m_sym = 0; rs = 0; dpw = 0; rp.delete();
        if (dcol) begin commit = 1; cerr = 1; v_drop_dp = 1; end
      end else if (o_ll == 0) begin
        ll = 1; lgadv = 1; lrty = 0; lbadp = 0; waitr = 0; rpq = 0; lbn = 0; cr = 0; tlet = 0; rlet = 0;
        ptmr = 0; ctmr = 0;
      end else if (rec && o_ll != 3) begin
        if (ll == 2 && o_tout != 0) v_rec_busy = 1;
        ll = 3; m_rec = 1;
      end
      // a packet into the receive buffers: the header, and a DP's good payload
      if (commit) begin
        bq_t t;
        t.delete();
        for (int i = 0; i < hdr.size(); i++) if (!cerr || i < 12) t.push_back(hdr[i]);
        rq.push_back(t); rqe.push_back(cerr);
        dcol = 0;
      end
      if (link_up && o_ll == 0) begin lgc = 0; lcc = RXN - rq.size(); end
      else begin lgc += int'(linc); lcc += int'(cinc); end
    end
    m_rdy = tq.size() < TXN && !(tlp_on && m16(ackd + 1 + tq.size() - tcur) % TXN == 0);
    m_rxv = rq.size() != 0;
    m_rxd = m_rxv ? rq[0][rgot] : 8'h00;
    m_rxl = m_rxv && rgot == rq[0].size() - 1;
    m_rxe = m_rxv && rqe[0];
  end

  // ---------------- assertions ----------------
  `SVA_INV(a_tx_sym, {tx_k, tx_sym} == m_sym)
  `SVA_INV(a_tx_ready, tx_ready == m_rdy)
  `SVA_INV(a_ll_up, ll_up == (ll == 2))
  `SVA_INV(a_rx_valid, rx_valid == m_rxv)
  `SVA_IMP(a_rx_byte, m_rxv, rx_data == m_rxd && rx_last == m_rxl && rx_err == m_rxe)
  `SVA_INV(a_events, {recovery, ev_hp_bad, ev_seq, ev_lc_bad, ev_dpp_bad, ev_frame, ev_proto, ev_overflow, ev_lbad,
                      ev_timeout} == {m_rec, m_hpbad, m_seq, m_lcbad, m_dpp, m_fr, m_pro, m_ovf, m_lbad, m_to})
  `SVA_RST(a_reset, 1'b1, tx_sym == 8'h00 && !tx_k && !ll_up && !rx_valid && !recovery && !ev_hp_bad &&
                          !ev_frame && !ev_timeout)

  // ---------------- functional coverage ----------------
  // link command sent (advertisement, LRTY, LBAD, LGOOD, LCRD x letter),
  // header packet sent x new / retry, its SEQ and DP payload length class,
  // header packet accepted x SEQ x DP or not, good DPP length class
  covergroup cg_link @(negedge clk);
    option.per_instance = 1;
    cp_lc: coverpoint c_lk iff (rst_n && c_lv)
      { bins advert = {0}; bins lrty = {1}; bins lbad = {2}; bins lgood = {3}; bins lcrd = {4}; }
    cp_let: coverpoint c_let iff (rst_n && c_lv && c_lk == 4) { bins l[] = {[0:3]}; }
    cp_hseq: coverpoint c_hseq iff (rst_n && c_hv) { bins s[] = {[0:7]}; }
    cp_hrt: coverpoint c_hrt iff (rst_n && c_hv) { bins first = {0}; bins retry = {1}; }
    cp_hdp: coverpoint c_hdp ? 1 + c_hlen : 0 iff (rst_n && c_hv)
      { bins header_only = {0}; bins dp_empty = {1}; bins dp_mid = {2}; bins dp_max = {3}; }
    x_hdp_rt: cross cp_hdp, cp_hrt;
    cp_rseq: coverpoint c_rseq iff (rst_n && c_rv) { bins s[] = {[0:7]}; }
    cp_rdp: coverpoint c_rdp iff (rst_n && c_rv) { bins header_only = {0}; bins dp = {1}; }
    cp_plen: coverpoint c_plen iff (rst_n && c_pv) { bins empty = {0}; bins mid = {1}; bins max = {2}; }
  endgroup
  cg_link u_cg_link = new;

  `FC(write_cut_at_maxd, v_cut)
  `FC(header_padded, v_pad)
  `FC(dp_sent, v_dp)
  `FC(dp_empty_payload, v_dp_empty)
  `FC(dp_full_payload, v_dp_max)
  `FC(write_waits_for_slot, v_slot_wait)
  `FC(credit_wait, v_credit_wait)
  `FC(retry_sent, v_retry)
  `FC(retry_without_credit, v_retry_nocredit)
  `FC(lgood_while_sending, v_ack_while_sending)
  `FC(lbad_third_recovery, v_lbad3)
  `FC(pending_timeout, v_to_pend)
  `FC(credit_timeout, v_to_cred)
  `FC(advertisement_timeout, v_to_adv)
  `FC(advertisement_acks, v_adv_acks)
  `FC(advertisement_resend, v_adv_none)
  `FC(lgood_out_of_order, v_lgood_bad)
  `FC(lcrd_wrong_letter, v_lcrd_bad)
  `FC(lcrd_too_many, v_lcrd_over)
  `FC(lbad_nothing_sent, v_lbad_none)
  `FC(unknown_link_command, v_unknown_lc)
  `FC(lc_second_copy_used, v_lc_copy2)
  `FC(lc_both_copies_bad, ev_lc_bad)
  `FC(lrty_not_waiting, v_lrty_ignored)
  `FC(hp_ignored_until_lrty, v_hp_ignored)
  `FC(hp_bad, ev_hp_bad && !ev_frame)
  `FC(hp_k_inside, v_hp_k)
  `FC(hp_seq_unexpected, ev_seq)
  `FC(hp_overflow, ev_overflow)
  `FC(hp_overflow_dp, v_ovf_dp)
  `FC(dpp_good, rx_valid && rx_ready && rx_last && !rx_err)
  `FC(dpp_crc_error, v_dpp_crc)
  `FC(dpp_abort, v_dpp_abort)
  `FC(dpp_too_long, v_dpp_long)
  `FC(dpp_too_short, v_dpp_short)
  `FC(dpp_missing, v_dpp_missing)
  `FC(dpp_k_inside, v_dpp_k)
  `FC(dpp_stray, v_dpp_stray)
  `FC(lc_k_inside, v_lc_k)
  `FC(ordered_set_data, v_os_data)
  `FC(ordered_set_too_long, v_os_long)
  `FC(ordered_set_bad, v_os_bad)
  `FC(k_symbol_in_idle, v_idle_k)
  `FC(rx_buffer_full_read, v_rx_full_read)
  `FC(recovery_with_traffic, v_rec_busy)
  `FC(link_drop_with_traffic, v_drop_busy)
  `FC(link_drop_in_payload, v_drop_dp)
  `FC_RST(reset_while_up, rst_n && ll_up ##1 !rst_n)
endmodule

bind USB3_2_top USB3_2_sva #(.MAXD(MAXD), .TXN(TXN), .RXN(RXN), .PEND_TO(PEND_TO), .CRED_TO(CRED_TO)) u_sva (.*);
