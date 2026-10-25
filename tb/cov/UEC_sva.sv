// SPDX-License-Identifier: Apache-2.0
// UEC PDS (RUD): concurrent SVA against an independent reference model,
// plus functional coverage.
//  * Sender: the model keeps the outstanding packets as a queue by PSN
//    (from the oldest) with acknowledged / retransmit flags, the timer, and
//    the frame on the wire as a byte array built whole when it starts.
//  * Receiver: a frame is collected as a byte queue and judged whole at
//    its last byte; the receive state is a cumulative PSN plus a received
//    flag per window position; received packets queue for the host.
//  * Each clock follows the spec's order: frames in, the window moves, the
//    timer, then the next frame out (NACK, ACK, lowest retransmission, new).
// tx_ready, rx_*, net_tx_*, outstanding and the events are compared on
// every clock.
`include "cov_macros.svh"
module UEC_sva #(
  parameter int MAXP = 16, W = 4, RXB = 2, RTO = 256
)(
  input logic        clk, rst_n, enable,
  input logic [15:0] start_psn_tx, start_psn_rx,
  input logic        tx_valid, tx_ready,
  input logic [7:0]  tx_data,
  input logic        tx_last,
  input logic        rx_valid, rx_ready,
  input logic [7:0]  rx_data,
  input logic        rx_last,
  input logic        net_tx_valid, net_tx_ready,
  input logic [7:0]  net_tx_data,
  input logic        net_tx_last,
  input logic        net_rx_valid,
  input logic [7:0]  net_rx_data,
  input logic        net_rx_last,
  input logic [$clog2(W):0] outstanding,
  input logic        ev_rto, ev_nack, ev_dup, ev_nobuf, ev_proto
);
  `COV_CLOCKING(clk, !rst_n)
  localparam int PB = MAXP * 8;

  // ---------------- model ----------------
  // sender
  logic [15:0] m_sbase, m_snew, m_snext;
  int          q_len [$];
  logic [PB-1:0] q_dat [$];
  bit          q_ack [$], q_rtx [$];
  logic [PB-1:0] w_d;
  int          w_n;
  int          m_tmr;
  bit          m_ton, m_tdata;
  int          m_tidx, m_tlen;
  logic [7:0]  m_tf [0:MAXP+3];
  logic [15:0] m_tpsn;
  // receiver
  logic [15:0] m_rbase;
  bit          m_got [0:W-1];
  bit          m_ackp, m_nackp;
  logic [15:0] m_npsn;
  int          r_len [$];
  logic [PB-1:0] r_dat [$];
  int          r_i;
  logic [7:0]  f_b [$];
  bit          f_buf;
  bit          m_rto, m_nack, m_dup, m_nobuf, m_pro;

  function automatic bit m_tx_ready();
    return enable && q_len.size() < W && !(m_ton && m_tdata && m_tpsn[$clog2(W)-1:0] == m_snext[$clog2(W)-1:0]);
  endfunction
  task automatic frame_data(input logic [15:0] psn, input int l, input logic [PB-1:0] d);
    m_ton = 1; m_tdata = 1; m_tidx = 0; m_tlen = 4 + l; m_tpsn = psn;
    m_tf[0] = 8'h10; m_tf[1] = psn[15:8]; m_tf[2] = psn[7:0]; m_tf[3] = 8'(l);
    for (int i = 0; i < l; i++) m_tf[4 + i] = d[8 * i +: 8];
  endtask

  // coverage
  bit v_new_order, v_new_gap, v_win_last, v_run, v_dup_in, v_dup_behind, v_past, v_nobuf_pend, v_ack_cum, v_ack_sack;
  bit v_ack_late, v_ack_beyond, v_ack_none, v_nack_retx, v_nack_late, v_nack_unsent, v_nack_acked, v_rto_many;
  bit v_ack_coal, v_ack_and_due, v_win_full, v_slot_guard, v_cut, v_bad_type, v_bad_short, v_bad_long, v_len0;
  bit v_len_over, v_len_mis, v_long_frame, v_cut_frame, v_swrap, v_rwrap, v_retx_two, v_freed_marked, v_retx_order;
  bit v_rx_cut;

  always @(posedge clk or negedge rst_n) begin
    if (!rst_n || !enable) begin
      m_sbase = start_psn_tx; m_snew = start_psn_tx; m_snext = start_psn_tx;
      if (!rst_n) begin m_sbase = 0; m_snew = 0; m_snext = 0; end
      q_len.delete(); q_dat.delete(); q_ack.delete(); q_rtx.delete(); w_d = 0; w_n = 0; m_tmr = 0;
      if (rst_n && m_ton) v_cut_frame = 1;
      if (rst_n && f_b.size() != 0) v_rx_cut = 1;
      m_ton = 0; m_tdata = 0; m_tidx = 0; m_tlen = 0; m_tpsn = 0;
      m_rbase = rst_n ? start_psn_rx : 16'd0;
      for (int i = 0; i < W; i++) m_got[i] = 0;
      m_ackp = 0; m_nackp = 0; r_len.delete(); r_dat.delete(); r_i = 0; f_b.delete();
      {m_rto, m_nack, m_dup, m_nobuf, m_pro} = '0;
    end else begin : b_step
      logic [15:0] o_sbase, o_snew, o_snext, o_rbase, o_npsn;
      int          o_cnt, o_sent, o_rxn, k, nfr, nmk;
      bit          o_ton, o_ackp, o_nackp, o_ack [0:W-1], o_got [0:W-1], fr [0:W-1], rt [0:W-1];
      bit          an, as, adv, prog, has_new, pop, push;
      int          nl, pl;
      logic [PB-1:0] nd, pd;
      o_sbase = m_sbase; o_snew = m_snew; o_snext = m_snext; o_rbase = m_rbase; o_npsn = m_npsn;
      o_cnt = q_len.size(); o_sent = int'(16'(m_snew - m_sbase)); o_rxn = r_len.size();
      o_ton = m_ton; o_ackp = m_ackp; o_nackp = m_nackp;
      for (int i = 0; i < W; i++) begin
        o_ack[i] = i < o_cnt ? q_ack[i] : 0; rt[i] = i < o_cnt ? q_rtx[i] : 0; fr[i] = 0; o_got[i] = m_got[i];
      end
      an = 0; as = 0; has_new = 0; pop = 0; push = 0;
      {m_rto, m_nack, m_dup, m_nobuf, m_pro} = '0;

      // ---- host write
      if (tx_valid && m_tx_ready()) begin
        w_d[8 * w_n +: 8] = tx_data;
        w_n++;
        if (tx_last || w_n == MAXP) begin
          if (!tx_last) v_cut = 1;
          has_new = 1; nl = w_n; nd = w_d; w_n = 0; w_d = 0;
        end
      end
      if (tx_valid && enable && o_cnt == W) v_win_full = 1;
      if (tx_valid && enable && o_cnt < W && !m_tx_ready()) v_slot_guard = 1;
      // ---- host read
      if (o_rxn != 0 && rx_ready) begin
        if (r_i == r_len[0] - 1) begin pop = 1; r_i = 0; end
        else r_i++;
      end
      // ---- a frame in
      if (net_rx_valid) begin
        if (f_b.size() == 0) f_buf = o_rxn < RXB;
        f_b.push_back(net_rx_data);
        if (net_rx_last) begin : b_frame
          int n;
          logic [7:0]  ty;
          logic [15:0] psn, d;
          n = f_b.size();
          ty = f_b[0];
          psn = n >= 3 ? {f_b[1], f_b[2]} : 16'd0;
          if (n > 32) v_long_frame = 1;
          if (ty == 8'h10 && n >= 4 && f_b[3] != 0 && f_b[3] <= MAXP && n == 4 + f_b[3]) begin
            d = psn - o_rbase;
            if (d < W && !o_got[d]) begin
              if (f_buf) begin
                push = 1; pl = f_b[3]; pd = 0;
                for (int i = 0; i < pl; i++) pd[8 * i +: 8] = f_b[4 + i];
                m_got[d] = 1;
                if (d == 0) v_new_order = 1; else v_new_gap = 1;
                if (d == W - 1) v_win_last = 1;
                if (d == 0 && m_got[1]) v_run = 1;
                while (m_got[0]) begin
                  for (int i = 0; i < W - 1; i++) m_got[i] = m_got[i + 1];
                  m_got[W - 1] = 0;
                  m_rbase++;
                  if (m_rbase == 16'd0) v_rwrap = 1;
                end
                an = 1;
              end else begin
                m_nobuf = 1; an = 1;
                if (!o_nackp) begin m_nackp = 1; m_npsn = psn; end
                else v_nobuf_pend = 1;
              end
            end else if (d < W || d[15]) begin
              m_dup = 1; an = 1;
              if (d[15]) v_dup_behind = 1; else v_dup_in = 1;
            end else begin m_pro = 1; v_past = 1; end
          end else if (ty == 8'h20 && n == 4) begin
            d = psn - o_sbase + 16'd1;
            if (d[15]) v_ack_late = 1;
            else if (d > o_sent) begin m_pro = 1; v_ack_beyond = 1; end
            else begin
              if (d == 0) v_ack_none = 1; else v_ack_cum = 1;
              for (int i = 0; i < W; i++) if (i < d) fr[i] = 1;
              for (int j = 0; j < W - 1; j++)
                if (f_b[3][j] && d + 1 + j < o_sent) begin fr[d + 1 + j] = 1; v_ack_sack = 1; end
            end
          end else if (ty == 8'h30 && n == 3) begin
            d = psn - o_sbase;
            if (d < o_sent) begin
              if (!o_ack[d]) begin rt[d] = 1; m_nack = 1; v_nack_retx = 1; end
              else v_nack_acked = 1;
            end else if (d[15]) v_nack_late = 1;
            else begin m_pro = 1; v_nack_unsent = 1; end
          end else begin
            m_pro = 1;
            if (ty != 8'h10 && ty != 8'h20 && ty != 8'h30) v_bad_type = 1;
            else if (ty == 8'h10 && n >= 4 && f_b[3] == 0) v_len0 = 1;
            else if (ty == 8'h10 && n >= 4 && f_b[3] > MAXP && n == 4 + f_b[3]) v_len_over = 1;
            else if (ty == 8'h10 && n >= 4) v_len_mis = 1;
            else if (n < (ty == 8'h30 ? 3 : 4)) v_bad_short = 1;
            else v_bad_long = 1;
          end
          f_b.delete();
        end
      end
      // ---- the window moves
      adv = o_sbase != o_snew && o_ack[0];
      nfr = 0;
      for (int i = 0; i < W; i++) nfr += fr[i];
      prog = adv || nfr != 0;
      // ---- timer
      if (prog || o_sbase == o_snew) m_tmr = 0;
      else if (m_tmr == RTO - 1) begin
        m_tmr = 0; m_rto = 1; nmk = 0;
        for (int i = 0; i < W; i++) if (i < o_sent && !o_ack[i]) begin rt[i] = 1; nmk++; end
        if (nmk > 1) v_rto_many = 1;
      end else m_tmr++;
      // ---- a frame out
      if (o_ton && net_tx_ready) begin
        m_tidx++;
        if (m_tidx == m_tlen) begin m_ton = 0; m_tdata = 0; end
      end
      if (!o_ton) begin
        int nrt;
        k = -1; nrt = 0;
        for (int i = W - 1; i >= 0; i--)
          if (i < o_sent && rt[i] && !o_ack[i] && !fr[i]) begin k = i; nrt++; end
        for (int i = 0; i < W; i++) if (i < o_sent && rt[i] && fr[i] && !o_ack[i]) v_freed_marked = 1;
        if (o_nackp) begin
          m_ton = 1; m_tdata = 0; m_tidx = 0; m_tlen = 3; m_tpsn = o_npsn;
          m_tf[0] = 8'h30; m_tf[1] = o_npsn[15:8]; m_tf[2] = o_npsn[7:0];
          m_nackp = 0;
        end else if (o_ackp) begin : b_ack
          logic [15:0] c;
          logic [7:0]  sk;
          c = o_rbase - 16'd1;
          sk = 0;
          for (int j = 0; j < W - 1; j++) sk[j] = o_got[j + 1];
          m_ton = 1; m_tdata = 0; m_tidx = 0; m_tlen = 4; m_tpsn = c;
          m_tf[0] = 8'h20; m_tf[1] = c[15:8]; m_tf[2] = c[7:0]; m_tf[3] = sk;
          as = 1;
          if (an) v_ack_and_due = 1;
        end else if (k >= 0) begin
          frame_data(o_sbase + 16'(k), q_len[k], q_dat[k]);
          rt[k] = 0;
          if (nrt > 1) v_retx_two = 1;
          if (k > 0 && nrt == 1) v_retx_order = 1;
        end else if (o_snew != o_snext) begin
          frame_data(o_snew, q_len[o_sent], q_dat[o_sent]);
          m_snew++;
        end
      end
      if (an && o_ackp && !as) v_ack_coal = 1;
      m_ackp = an || o_ackp && !as;
      // ---- apply
      for (int i = 0; i < o_cnt; i++) begin
        q_rtx[i] = rt[i] && !fr[i] && !o_ack[i];
        q_ack[i] = q_ack[i] || fr[i];
      end
      if (adv) begin
        void'(q_len.pop_front()); void'(q_dat.pop_front()); void'(q_ack.pop_front()); void'(q_rtx.pop_front());
        m_sbase++;
        if (m_sbase == 16'd0) v_swrap = 1;
      end
      if (has_new) begin
        q_len.push_back(nl); q_dat.push_back(nd); q_ack.push_back(0); q_rtx.push_back(0);
        m_snext++;
      end
      if (pop) begin void'(r_len.pop_front()); void'(r_dat.pop_front()); end
      if (push) begin r_len.push_back(pl); r_dat.push_back(pd); end
    end
  end

  // ---------------- assertions ----------------
  `SVA_INV(a_tx_ready, tx_ready == m_tx_ready())
  `SVA_INV(a_rx_valid, rx_valid == (r_len.size() != 0))
  `SVA_IMP(a_rx_byte, r_len.size() != 0, rx_data == r_dat[0][8 * r_i +: 8] && rx_last == (r_i == r_len[0] - 1))
  `SVA_INV(a_net_tx, net_tx_valid == m_ton && (!m_ton || net_tx_data == m_tf[m_tidx] &&
                                                net_tx_last == (m_tidx == m_tlen - 1)))
  `SVA_INV(a_outstanding, outstanding == q_len.size())
  `SVA_INV(a_events, {ev_rto, ev_nack, ev_dup, ev_nobuf, ev_proto} == {m_rto, m_nack, m_dup, m_nobuf, m_pro})
  `SVA_RST(a_reset, !rst_n, !net_tx_valid && !rx_valid && !tx_ready && outstanding == 0 &&
                          {ev_rto, ev_nack, ev_dup, ev_nobuf, ev_proto} == 5'b0)

  // ---------------- functional coverage ----------------
  `FC(rx_new_in_order, v_new_order)
  `FC(rx_new_after_gap, v_new_gap)
  `FC(rx_window_last, v_win_last)
  `FC(rx_run_completed, v_run)
  `FC(rx_dup_in_window, v_dup_in)
  `FC(rx_dup_behind, v_dup_behind)
  `FC(rx_past_window, v_past)
  `FC(rx_nobuf, ev_nobuf)
  `FC(rx_nobuf_nack_pending, v_nobuf_pend)
  `FC(rx_psn_wrap, v_rwrap)
  `FC(ack_cumulative, v_ack_cum)
  `FC(ack_selective, v_ack_sack)
  `FC(ack_late, v_ack_late)
  `FC(ack_beyond_sent, v_ack_beyond)
  `FC(ack_nothing_new, v_ack_none)
  `FC(ack_coalesced, v_ack_coal)
  `FC(ack_due_while_sending_ack, v_ack_and_due)
  `FC(nack_retransmit, v_nack_retx)
  `FC(nack_late, v_nack_late)
  `FC(nack_unsent, v_nack_unsent)
  `FC(nack_already_acked, v_nack_acked)
  `FC(rto, ev_rto)
  `FC(rto_several, v_rto_many)
  `FC(retx_lowest_of_several, v_retx_two)
  `FC(retx_not_oldest, v_retx_order)
  `FC(retx_mark_freed_at_once, v_freed_marked)
  `FC(tx_window_full, v_win_full)
  `FC(tx_slot_in_flight, v_slot_guard)
  `FC(tx_cut_at_maxp, v_cut)
  `FC(tx_psn_wrap, v_swrap)
  `FC(net_backpressure, net_tx_valid && !net_tx_ready)
  `FC(rx_backpressure, rx_valid && !rx_ready)
  `FC(frame_bad_type, v_bad_type)
  `FC(frame_short, v_bad_short)
  `FC(frame_long, v_bad_long)
  `FC(frame_len_zero, v_len0)
  `FC(frame_len_over_maxp, v_len_over)
  `FC(frame_len_mismatch, v_len_mis)
  `FC(frame_over_32_bytes, v_long_frame)
  `FC(close_mid_frame_out, v_cut_frame)
  `FC(close_mid_frame_in, v_rx_cut)
  `FC_RST(reset_while_open, rst_n && enable && outstanding != 0 ##1 !rst_n)
endmodule

bind UEC_top UEC_sva #(.MAXP(MAXP), .W(W), .RXB(RXB), .RTO(RTO)) u_sva (.*);
