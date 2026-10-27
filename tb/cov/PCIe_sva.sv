// SPDX-License-Identifier: Apache-2.0
// PCIe data link layer: concurrent SVA against an independent reference
// model, plus functional coverage.
//  * Transmit: the model keeps the written TLPs as byte queues (oldest
//    unacknowledged first), picks the next packet between packets by the
//    same priorities, builds all its symbols at once (its own CRCs) and
//    the line must carry them one per clock.
//  * Receive: the model collects a whole packet between its start and end
//    symbols and judges it at the end (framing, CRC, sequence number,
//    room); good TLPs go into a queue of byte queues that rx_* must show.
//  * Ack / Nak / flow control DLLPs update the model's sequence numbers,
//    replay requests and credits.
// Every output is compared on every clock.
`include "cov_macros.svh"
module PCIe_sva #(
  parameter int MAXLEN = 32, TXN = 4, RXN = 4, REPLAY_TO = 600, FC_GAP = 32, UPD_GAP = 1024
)(
  input logic       clk, rst_n, link_up,
  input logic [7:0] tx_sym,
  input logic       tx_k,
  input logic [7:0] rx_sym,
  input logic       rx_k,
  input logic       tlp_valid, tlp_ready,
  input logic [7:0] tlp_data,
  input logic       tlp_last,
  input logic       rx_valid, rx_ready,
  input logic [7:0] rx_data,
  input logic       rx_last,
  input logic       dl_up, retrain,
  input logic       ev_tlp_bad, ev_tlp_seq, ev_tlp_dup, ev_tlp_null, ev_overflow,
  input logic       ev_dllp_bad, ev_dllp_proto, ev_frame, ev_nak, ev_replay
);
  `COV_CLOCKING(clk, !rst_n)
  typedef logic [7:0] bq_t [$];

  function automatic logic [31:0] c32(input logic [31:0] c, input logic [7:0] b);
    for (int i = 7; i >= 0; i--) begin
      bit fb;
      fb = c[31] ^ b[i];
      c = c << 1;
      if (fb) c ^= 32'h04C1_1DB7;
    end
    return c;
  endfunction
  function automatic logic [15:0] c16(input logic [7:0] b0, b1, b2, b3);
    logic [15:0] c;
    logic [31:0] d;
    c = '1; d = {b0, b1, b2, b3};
    for (int i = 31; i >= 0; i--) begin
      bit fb;
      fb = c[15] ^ d[i];
      c = c << 1;
      if (fb) c ^= 16'h100B;
    end
    return c;
  endfunction
  function automatic int sd(input int a, input int b);   // (a - b) mod 4096
    return (a - b) & 12'hFFF;
  endfunction

  // ---------------- model state ----------------
  int     dls, fct;                     // 0 inactive, 1 FC1, 2 FC2, 3 active
  // transmit
  bq_t    tq [$];                       // written, unacknowledged TLPs; tq[0] has sequence ackd + 1
  bq_t    wb;                           // TLP being written
  int     ackd, txs, nsent, rnum, rtmr, cl, cc;
  bit     cinf, rpq, tlp_on;            // tlp_on: a TLP is being sent
  int     tcur;
  logic [8:0] ts [$];                   // {k, symbol} still to send
  logic [8:0] m_sym;                    // what the line carries now
  // receive
  int     rst_, nrs, ca;                // rst_: 0 idle, 1 TLP, 2 DLLP
  logic [7:0] rp [$];                   // bytes of the packet so far
  bq_t    rq [$];                       // TLPs received
  int     rgot;
  bit     ackp, nakp, naks, updp;
  bit     m_rdy, m_rxv, m_rxl;            // outputs from the state after each clock
  logic [7:0] m_rxd;
  bit     m_rt, m_bad, m_seq, m_dup, m_null, m_ovf, m_dbad, m_dpro, m_fr, m_nak, m_rep;
  // coverage
  bit v_cut, v_credit_stall, v_inf_credit, v_replay_nak, v_replay_timer, v_retrain, v_retrain_nak, v_ack_progress;
  bit v_nak_nothing, v_ack_behind, v_ack_ahead, v_dllp_resv, v_unknown_dllp, v_fc2_by_ufc, v_fc2_by_tlp, v_fc1_by_ifc2;
  bit v_ufc_finite, v_tlp_short, v_tlp_long, v_edb_bad, v_dllp_long, v_dllp_short, v_k_in_dllp, v_k_in_tlp;
  bit v_idle_k, v_ovf_room, v_ack_while_sending, v_link_drop_busy, v_upd_timer, v_nak_then_ack, v_dup_after_nak;
  bit v_slot_wait, v_rx_full_read;
  // per-step copies for the covergroup (set at posedge, sampled at negedge)
  bit c_tv, c_rv, c_dv;
  int c_tk, c_tn, c_tq, c_rk, c_rn, c_dk;
  logic [7:0] c_tb, c_rb;

  always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      dls = 0; fct = 0; tq.delete(); wb.delete(); ackd = 12'hFFF; txs = 0; nsent = 0; rnum = 0; rtmr = 0;
      cl = 0; cc = 0; cinf = 0; rpq = 0; tlp_on = 0; tcur = 0; ts.delete(); m_sym = 0;
      rst_ = 0; nrs = 0; ca = RXN; rp.delete(); rq.delete(); rgot = 0; ackp = 0; nakp = 0; naks = 0; updp = 0;
      {m_rt, m_bad, m_seq, m_dup, m_null, m_ovf, m_dbad, m_dpro, m_fr, m_nak, m_rep} = '0;
    end else begin : b_step
      int o_dls, o_ackd, o_nsent, o_rnum, o_fct, o_txs, o_nrs;
      bit o_rpq, o_updp, o_rdy;
      int nq;
      o_dls = dls; o_ackd = ackd; o_nsent = nsent; o_rnum = rnum; o_fct = fct; o_rpq = rpq; o_txs = txs;
      o_nrs = nrs; o_updp = updp; nq = tq.size();
      // tlp_ready as it is now: a free slot, not the one being sent
      o_rdy = dls == 3 && nq < TXN && !(tlp_on && sd(ackd + 1 + nq, tcur) % TXN == 0);
      {m_rt, m_bad, m_seq, m_dup, m_null, m_ovf, m_dbad, m_dpro, m_fr, m_nak, m_rep} = '0;
      {c_tv, c_rv, c_dv} = '0;
      // ---- link state timer
      fct = o_fct == 0 ? (o_dls == 3 ? UPD_GAP : FC_GAP) : o_fct - 1;
      if (o_dls == 3 && o_fct == 0) begin updp = 1; v_upd_timer = 1; end
      if (o_dls == 0 && link_up) begin dls = 1; fct = 0; end

      // ---- transmit: the next symbol, or a new packet
      if (ts.size() != 0) begin
        m_sym = ts.pop_front();
        if (ts.size() == 0 && tlp_on) begin tlp_on = 0; txs = (tcur + 1) & 12'hFFF; end
      end else begin : b_pick
        bit fc, tlp;
        int eff, idx;
        fc = (o_dls == 1 || o_dls == 2) && o_fct == 0;
        eff = o_rpq || sd(o_ackd + 1, o_txs) inside {[1:2047]} ? (o_ackd + 1) & 12'hFFF : o_txs;
        idx = sd(eff, o_ackd + 1);
        tlp = o_dls == 3 && idx < nq && (eff != o_nsent || cinf || ((cl - cc - 1) & 8'hFF) < 128);
        if (o_dls == 3 && idx < nq && eff == o_nsent && !cinf && ((cl - cc - 1) & 8'hFF) >= 128) v_credit_stall = 1;
        m_sym = 9'h000;
        if (nakp || ackp || fc || o_updp && o_dls == 3) begin : b_dllp
          logic [7:0] b [4];
          logic [15:0] c;
          c_tv = 1;
          if (nakp || ackp) begin
            c_tk = nakp ? 1 : 0;
            b[0] = nakp ? 8'h10 : 8'h00; b[1] = 0; b[2] = 8'((o_nrs - 1) >> 8) & 8'h0F; b[3] = 8'(o_nrs - 1);
            nakp = 0; ackp = 0;
          end else begin
            int h;
            h = fc ? RXN : ca;
            b[0] = fc ? (o_dls == 1 ? 8'h40 : 8'hC0) : 8'h80;
            c_tk = fc ? (o_dls == 1 ? 2 : 3) : 4;
            b[1] = 8'(h >> 2) & 8'h3F; b[2] = 8'((h & 3) << 6); b[3] = 0;
            if (!fc) updp = 0;
          end
          c = ~c16(b[0], b[1], b[2], b[3]);
          m_sym = {1'b1, 8'h5C};
          for (int i = 0; i < 4; i++) ts.push_back({1'b0, b[i]});
          ts.push_back({1'b0, c[15:8]}); ts.push_back({1'b0, c[7:0]}); ts.push_back({1'b1, 8'hFD});
        end else if (tlp) begin : b_tlp
          logic [31:0] c;
          logic [7:0]  s0, s1;
          m_sym = {1'b1, 8'hFB};
          s0 = 8'(eff >> 8) & 8'h0F; s1 = 8'(eff);
          c = c32(c32('1, s0), s1);
          ts.push_back({1'b0, s0}); ts.push_back({1'b0, s1});
          foreach (tq[idx][i]) begin ts.push_back({1'b0, tq[idx][i]}); c = c32(c, tq[idx][i]); end
          c = ~c;
          for (int i = 3; i >= 0; i--) ts.push_back({1'b0, c[8 * i +: 8]});
          ts.push_back({1'b1, 8'hFD});
          tlp_on = 1; tcur = eff; rpq = 0;
          c_tv = 1; c_tk = eff == o_nsent ? 5 : 6; c_tn = tq[idx].size(); c_tq = idx; c_tb = tq[idx][c_tn - 1];
          if (eff == o_nsent) begin nsent = (o_nsent + 1) & 12'hFFF; cc = (cc + 1) & 8'hFF; end
        end
      end
      // ---- replay timer
      if (o_nsent == ((o_ackd + 1) & 12'hFFF) || o_rpq) rtmr = 0;
      else if (rtmr == REPLAY_TO) begin
        rtmr = 0; rpq = 1; m_rep = 1; v_replay_timer = 1;
        rnum = (o_rnum + 1) & 3;
        if (o_rnum == 3) begin m_rt = 1; v_retrain = 1; end
      end else rtmr++;
      // ---- writing
      if (tlp_valid && o_rdy) begin
        wb.push_back(tlp_data);
        if (tlp_last || wb.size() == MAXLEN) begin
          if (!tlp_last) v_cut = 1;
          tq.push_back(wb); wb.delete();
        end
      end else if (tlp_valid && dls == 3 && tq.size() < TXN) v_slot_wait = 1;

      // ---- receive
      if (!rx_k) begin
        if (rst_ != 0) rp.push_back(rx_sym);
        if (rst_ == 2 && rp.size() == 7) begin m_fr = 1; rst_ = 0; v_dllp_long = 1; end
      end else begin : b_k
        bit bad, dok;
        bad = 0; dok = 0;
        if (rst_ == 1) begin : b_end
          int n;
          n = rp.size();
          if ((rx_sym == 8'hFD || rx_sym == 8'hFE) && n >= 7 && n - 6 <= MAXLEN) begin : b_tlp_end
            logic [31:0] c, l;
            int s;
            c = '1;
            for (int i = 0; i < n - 4; i++) c = c32(c, rp[i]);
            l = {rp[n - 4], rp[n - 3], rp[n - 2], rp[n - 1]};
            s = {rp[0][3:0], rp[1]};
            c_rv = 1; c_rn = n - 6;
            if (rx_sym == 8'hFE && l == c) begin m_null = 1; c_rk = 1; end
            else if (rx_sym == 8'hFE || l != ~c) begin bad = 1; c_rk = 2; if (rx_sym == 8'hFE) v_edb_bad = 1; end
            else if (sd(s, o_nrs) inside {[1:2047]}) begin m_seq = 1; bad = 1; c_rk = 3; end
            else if (s != o_nrs) begin
              m_dup = 1; ackp = 1; c_rk = 4;
              if (naks) v_dup_after_nak = 1;
            end else if (rq.size() == RXN) begin m_ovf = 1; v_ovf_room = 1; c_rk = 5; end
            else begin : b_good
              bq_t t;
              t.delete();
              for (int i = 2; i < n - 4; i++) t.push_back(rp[i]);
              rq.push_back(t);
              c_rk = 0; c_rb = t[t.size() - 1];
              nrs = (o_nrs + 1) & 12'hFFF; ackp = 1; naks = 0;
              if (o_dls == 2) begin dls = 3; v_fc2_by_tlp = 1; end
            end
          end else begin
            m_fr = 1; bad = 1;
            if (rx_sym != 8'hFD && rx_sym != 8'hFE) v_k_in_tlp = 1;
            else if (n < 7) v_tlp_short = 1;
            else v_tlp_long = 1;
          end
          if (bad) begin
            m_bad = 1;
            if (!naks) begin nakp = 1; naks = 1; end
          end
        end else if (rst_ == 2) begin
          if (rx_sym == 8'hFD && rp.size() == 6) begin
            if ({rp[4], rp[5]} != ~c16(rp[0], rp[1], rp[2], rp[3])) m_dbad = 1;
            else dok = 1;
          end else begin
            m_fr = 1;
            if (rx_sym == 8'hFD) v_dllp_short = 1; else v_k_in_dllp = 1;
          end
        end else if (rx_sym != 8'hFB && rx_sym != 8'h5C) begin m_fr = 1; v_idle_k = 1; end
        rst_ = rx_sym == 8'hFB ? 1 : rx_sym == 8'h5C ? 2 : 0;
        if (dok) begin : b_dllp_rx
          int t, h, s;
          t = rp[0]; h = {rp[1][5:0], rp[2][7:6]}; s = {rp[2][3:0], rp[3]};
          c_dv = 1;
          c_dk = t == 8'h00 ? 0 : t == 8'h10 ? 1 : t == 8'h40 ? 2 : t == 8'hC0 ? 3 : t == 8'h80 ? 4 : 5;
          if (t == 8'h00 || t == 8'h10) begin
            if (o_dls == 3) begin
              if (rp[1] != 0 || rp[2][7:4] != 0) begin m_dpro = 1; v_dllp_resv = 1; end
              else if (sd(s, o_ackd) > sd(o_nsent - 1, o_ackd)) begin
                m_dpro = 1;
                if (sd(o_ackd, s) inside {[1:2047]}) v_ack_behind = 1; else v_ack_ahead = 1;
              end else begin
                int k;
                k = sd(s, o_ackd);
                if (k != 0) begin
                  v_ack_progress = 1;
                  if (tlp_on) v_ack_while_sending = 1;
                  repeat (k) void'(tq.pop_front());
                  ackd = s; rnum = 0; rtmr = 0;
                end
                if (t == 8'h10) begin
                  m_nak = 1;
                  if (s != ((o_nsent - 1) & 12'hFFF)) begin
                    rpq = 1; v_replay_nak = 1;
                    rnum = s != o_ackd ? 1 : (o_rnum + 1) & 3;
                    if (s == o_ackd && o_rnum == 3) begin m_rt = 1; v_retrain_nak = 1; end
                  end else v_nak_nothing = 1;
                end else if (o_rpq) v_nak_then_ack = 1;
              end
            end
          end else if (t == 8'h40 || t == 8'hC0) begin
            if (o_dls == 1 || o_dls == 2 && t == 8'hC0) begin
              cl = h; cinf = h == 0; if (h == 0) v_inf_credit = 1;
              dls = o_dls == 1 ? 2 : 3;
              if (o_dls == 1 && t == 8'hC0) v_fc1_by_ifc2 = 1;
            end
          end else if (t == 8'h80) begin
            if (o_dls == 2) begin dls = 3; v_fc2_by_ufc = 1; end
            else if (o_dls == 3 && !cinf) begin cl = h; v_ufc_finite = 1; end
          end else begin m_dpro = 1; v_unknown_dllp = 1; end
        end
        rp.delete();
      end
      // ---- reading
      if (rx_valid && rx_ready && rq.size() != 0) begin
        rgot++;
        if (rgot == rq[0].size()) begin
          void'(rq.pop_front()); rgot = 0; ca = (ca + 1) & 8'hFF; updp = 1;
          if (rq.size() == RXN - 1) v_rx_full_read = 1;
        end
      end
      // ---- the link drops
      if (!link_up) begin
        if (dls == 3 && (tq.size() != 0 || rq.size() != 0)) v_link_drop_busy = 1;
        dls = 0; ts.delete(); tlp_on = 0;
        tq.delete(); wb.delete(); ackd = 12'hFFF; txs = 0; nsent = 0; rnum = 0; rtmr = 0; rpq = 0;
        cl = 0; cc = 0; cinf = 0; rst_ = 0; rp.delete(); nrs = 0; rq.delete(); rgot = 0; ca = RXN;
        ackp = 0; nakp = 0; naks = 0; updp = 0; m_sym = 0;
      end
    end
    m_rdy = dls == 3 && tq.size() < TXN && !(tlp_on && sd(ackd + 1 + tq.size(), tcur) % TXN == 0);
    m_rxv = rq.size() != 0;
    m_rxd = m_rxv ? rq[0][rgot] : 8'h00;
    m_rxl = m_rxv && rgot == rq[0].size() - 1;
  end

  // ---------------- assertions ----------------
  `SVA_INV(a_tx_sym, {tx_k, tx_sym} == m_sym)
  `SVA_INV(a_tlp_ready, tlp_ready == m_rdy)
  `SVA_INV(a_dl_up, dl_up == (dls == 3))
  `SVA_INV(a_rx_valid, rx_valid == m_rxv)
  `SVA_IMP(a_rx_byte, m_rxv, rx_data == m_rxd && rx_last == m_rxl)
  `SVA_INV(a_events, {retrain, ev_tlp_bad, ev_tlp_seq, ev_tlp_dup, ev_tlp_null, ev_overflow, ev_dllp_bad, ev_dllp_proto,
                      ev_frame, ev_nak, ev_replay} == {m_rt, m_bad, m_seq, m_dup, m_null, m_ovf, m_dbad, m_dpro, m_fr, m_nak, m_rep})
  `SVA_RST(a_reset, 1'b1, tx_sym == 8'h00 && !tx_k && !dl_up && !rx_valid && !tlp_ready && !retrain && !ev_tlp_bad &&
                          !ev_frame && !ev_nak && !ev_replay)

  // ---------------- functional coverage ----------------
  function automatic int dcls(input logic [7:0] v);
    return v == 8'h00 ? 0 : v == 8'hFF ? 1 : (v == 8'h55 || v == 8'hAA) ? 2 : 3;
  endfunction
  covergroup cg_pcie @(negedge clk);
    option.per_instance = 1;
    cp_tx: coverpoint c_tk iff (rst_n && c_tv)
      { bins ack = {0}; bins nak = {1}; bins initfc1 = {2}; bins initfc2 = {3}; bins updatefc = {4};
        bins tlp_new = {5}; bins tlp_replay = {6}; }
    cp_tlen: coverpoint c_tn iff (rst_n && c_tv && c_tk >= 5)
      { bins one = {1}; bins short_ = {[2:3]}; bins mid = {[4:MAXLEN-1]}; bins maxlen = {MAXLEN}; }
    cp_tslot: coverpoint c_tq iff (rst_n && c_tv && c_tk >= 5) { bins s[] = {[0:TXN-1]}; }
    cp_tdata: coverpoint dcls(c_tb) iff (rst_n && c_tv && c_tk >= 5)
      { bins zero = {0}; bins ones = {1}; bins alt = {2}; bins other = {3}; }
    cp_rx: coverpoint c_rk iff (rst_n && c_rv)
      { bins good = {0}; bins nullified = {1}; bins bad = {2}; bins ahead = {3}; bins dup = {4}; bins overflow = {5}; }
    cp_rlen: coverpoint c_rn iff (rst_n && c_rv && c_rk == 0)
      { bins one = {1}; bins short_ = {[2:3]}; bins mid = {[4:MAXLEN-1]}; bins maxlen = {MAXLEN}; }
    cp_rdata: coverpoint dcls(c_rb) iff (rst_n && c_rv && c_rk == 0)
      { bins zero = {0}; bins ones = {1}; bins alt = {2}; bins other = {3}; }
    cp_dllp: coverpoint c_dk iff (rst_n && c_dv)
      { bins ack = {0}; bins nak = {1}; bins initfc1 = {2}; bins initfc2 = {3}; bins updatefc = {4}; bins unknown = {5}; }
  endgroup
  cg_pcie u_cg_pcie = new;

  `FC(tlp_cut_at_maxlen, v_cut)
  `FC(credit_stall, v_credit_stall)
  `FC(infinite_credit, v_inf_credit)
  `FC(finite_credit_update, v_ufc_finite)
  `FC(replay_by_nak, v_replay_nak)
  `FC(replay_by_timer, v_replay_timer)
  `FC(retrain_by_timer, v_retrain)
  `FC(retrain_by_nak, v_retrain_nak)
  `FC(ack_progress, v_ack_progress)
  `FC(ack_while_sending, v_ack_while_sending)
  `FC(nak_with_nothing_to_replay, v_nak_nothing)
  `FC(ack_after_replay_request, v_nak_then_ack)
  `FC(ack_behind, v_ack_behind)
  `FC(ack_ahead, v_ack_ahead)
  `FC(ack_reserved_bits, v_dllp_resv)
  `FC(unknown_dllp, v_unknown_dllp)
  `FC(fc1_to_fc2, dl_up == 0 && dls == 2)
  `FC(fc1_skipped_by_initfc2, v_fc1_by_ifc2)
  `FC(fc2_ended_by_updatefc, v_fc2_by_ufc)
  `FC(fc2_ended_by_tlp, v_fc2_by_tlp)
  `FC(updatefc_by_timer, v_upd_timer)
  `FC(tlp_good, ev_tlp_bad == 0 && rx_valid && rx_ready && rx_last)
  `FC(tlp_bad_lcrc, ev_tlp_bad && !ev_frame && !ev_tlp_seq)
  `FC(tlp_seq_ahead, ev_tlp_seq)
  `FC(tlp_duplicate, ev_tlp_dup)
  `FC(tlp_dup_after_nak, v_dup_after_nak)
  `FC(tlp_nullified, ev_tlp_null)
  `FC(tlp_edb_bad, v_edb_bad)
  `FC(tlp_too_short, v_tlp_short)
  `FC(tlp_too_long, v_tlp_long)
  `FC(tlp_k_inside, v_k_in_tlp)
  `FC(rx_overflow, v_ovf_room)
  `FC(rx_buffer_full_read, v_rx_full_read)
  `FC(dllp_crc_error, ev_dllp_bad)
  `FC(dllp_too_long, v_dllp_long)
  `FC(dllp_too_short, v_dllp_short)
  `FC(dllp_k_inside, v_k_in_dllp)
  `FC(k_symbol_in_idle, v_idle_k)
  `FC(write_waits_for_slot, v_slot_wait)
  `FC(link_drop_with_traffic, v_link_drop_busy)
  `FC_RST(reset_while_up, rst_n && dl_up ##1 !rst_n)
endmodule

bind PCIe_top PCIe_sva #(.MAXLEN(MAXLEN), .TXN(TXN), .RXN(RXN), .REPLAY_TO(REPLAY_TO), .FC_GAP(FC_GAP),
                         .UPD_GAP(UPD_GAP)) u_sva (.*);
