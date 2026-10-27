// SPDX-License-Identifier: Apache-2.0
// CCIX link layer: concurrent SVA against an independent reference model,
// plus functional coverage.
//  * Transmit: the model keeps the payload being gathered, the credits
//    held and owed, the idle count for a Misc, and plays the TLP word by
//    word; tx_ready and every TLP word are compared on every clock.
//  * Receive: the model checks each TLP word itself, keeps the messages
//    being written apart from those complete (a queue), counts the
//    credits granted and not used, and predicts every event; rx_* and the
//    credit counts are compared on every clock.
`include "cov_macros.svh"
module CCIX_Cache_Coherent_Interconnect_sva #(
  parameter int MAXP = 16, NREQ = 2, NSNP = 2, RXD = 64, CRT = 16
)(
  input logic        clk, rst_n,
  input logic [15:0] rid, tgt_rid,
  input logic        tx_valid, tx_ready,
  input logic [31:0] tx_data,
  input logic        rx_valid, rx_ready,
  input logic [31:0] rx_data,
  input logic        rx_last,
  input logic        tlp_tx_valid, tlp_tx_ready,
  input logic [31:0] tlp_tx_data,
  input logic        tlp_tx_last,
  input logic        tlp_rx_valid,
  input logic [31:0] tlp_rx_data,
  input logic        tlp_rx_last,
  input logic [4:0]  tx_crd_req, tx_crd_snp,
  input logic        ev_err, ev_nocrd, ev_ovf
);
  `COV_CLOCKING(clk, !rst_n)
  // transmit phases
  localparam int T_IDLE = 0, T_BODY = 1, T_GATH = 2, T_SEND = 3;
  // receive phases: 0..3 TLP header words
  localparam int R_MSG = 4, R_BODY = 5, R_SKIP = 6, R_DROP = 7;

  int          t_ph, t_n, t_left, t_i, t_idle;
  logic [31:0] t_pl [0:MAXP-1];
  logic [7:0]  t_tag;
  int          pq, ps, cq, cs, oq, os;      // owed, held, granted not used
  int          r_ph, r_rem, r_cnt, r_cl;
  bit          r_keep, r_good, p_rxv;
  int          r_aq, r_as;
  logic [33:0] fq [$], tq [$];
  bit          o_err, o_nocrd, o_ovf;

  // ---------------- what the DUT must show now ----------------
  wire [3:0] d_ty = tx_data[31:28];
  wire [3:0] d_ln = tx_data[27:24];
  wire       d_bad = !(d_ty >= 4'd1 && d_ty <= 4'd3 && d_ln >= 4'd1 && d_ln <= 4'd8);
  wire       d_crd = !(d_ty == 4'd1 && cq == 0 || d_ty == 4'd2 && cs == 0);
  wire       d_fit = t_n + int'(d_ln) <= MAXP;
  wire       d_misc = (pq > 0 || ps > 0) && t_idle >= CRT;
  logic        e_txr, e_tlast;
  logic [31:0] e_tdat;
  always_comb begin
    e_txr = 1'b0;
    if (t_ph == T_IDLE) e_txr = !d_misc && (d_bad || d_crd);
    if (t_ph == T_BODY) e_txr = 1'b1;
    if (t_ph == T_GATH) e_txr = d_bad || d_crd && d_fit;
    e_tlast = t_i == t_n + 3;
    if (t_i == 0) e_tdat = {3'b011, 5'b10010, 14'd0, 10'(t_n)};
    else if (t_i == 1) e_tdat = {rid, t_tag, 8'h7F};
    else if (t_i == 2) e_tdat = {tgt_rid, 16'h1E2C};
    else if (t_i == 3) e_tdat = '0;
    else e_tdat = t_pl[(t_i - 4) % MAXP];
  end

  // coverage
  bit v_tx_ty [1:3], v_rx_ty [1:3], v_tx_l1, v_tx_l8, v_rx_l1, v_rx_l8, v_full, v_multi;
  bit v_cut_fit, v_cut_crd, v_cut_idle, v_wait_crd, v_misc_tx, v_misc_rx, v_bad_hdr_idle, v_bad_hdr_gath;
  bit v_rx_bad [0:15], v_nocrd_req, v_nocrd_snp, v_ovf, v_crd_ovf, v_partial, v_tx_stall, v_rx_deep, v_pop_cmt;
  bit v_piggy, v_rx_gap;
  // per-step copies for the covergroup (set at posedge, sampled at negedge)
  bit c_tv, c_bv, c_rv, c_rbv, c_sv;
  int c_tty, c_tln, c_rty, c_rln, c_sn;
  logic [31:0] c_bw, c_rbw;

  always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      t_ph = T_IDLE; t_n = 0; t_left = 0; t_i = 0; t_idle = 0; t_tag = 0;
      pq = NREQ; ps = NSNP; cq = 0; cs = 0; oq = 0; os = 0;
      r_ph = 0; r_good = 0; p_rxv = 0; r_rem = 0; r_cnt = 0; r_cl = 0; r_keep = 0; r_aq = 0; r_as = 0;
      fq.delete(); tq.delete();
      o_err = 0; o_nocrd = 0; o_ovf = 0;
    end else begin : b_step
      int          pq0, ps0, oq0, os0, nfq0, tph0;
      bit          txr, misc, bad, done;
      logic [31:0] w;
      pq0 = pq; ps0 = ps; oq0 = oq; os0 = os; nfq0 = fq.size(); tph0 = t_ph;
      txr = e_txr; misc = d_misc;
      o_err = 0; o_nocrd = 0; o_ovf = 0;
      bad = 0; done = 0;
      {c_tv, c_bv, c_rv, c_rbv, c_sv} = '0;
      // ---- receive
      w = tlp_rx_data;
      if (tlp_rx_valid) begin
        if (r_ph == 1 && !p_rxv) v_rx_gap = 1;
        if (r_ph == 0) r_good = 0;
        case (r_ph)
          0: begin
            if (w[31:24] != 8'h72) v_rx_bad[0] = 1;
            if (w[9:0] == 0) v_rx_bad[1] = 1;
            if (int'(w[9:0]) > MAXP) v_rx_bad[2] = 1;
            if (w[31:24] != 8'h72 || w[9:0] == 0 || int'(w[9:0]) > MAXP || tlp_rx_last) bad = 1;
            else begin r_rem = int'(w[9:0]); r_ph = 1; end
          end
          1: begin
            if (w[7:0] != 8'h7F) v_rx_bad[3] = 1;
            if (w[7:0] != 8'h7F || tlp_rx_last) bad = 1; else r_ph = 2;
          end
          2: begin
            if (w[15:0] != 16'h1E2C) v_rx_bad[4] = 1;
            if (w[31:16] != rid) v_rx_bad[5] = 1;
            if (w != {rid, 16'h1E2C} || tlp_rx_last) bad = 1; else r_ph = 3;
          end
          3: begin
            if (w != 0) v_rx_bad[6] = 1;
            if (tlp_rx_last) v_rx_bad[7] = 1;
            if (w != 0 || tlp_rx_last) bad = 1; else r_ph = R_MSG;
          end
          R_MSG: begin : b_msg
            int ty, ln;
            bit room, skip;
            ty = int'(w[31:28]); ln = int'(w[27:24]);
            if (ty > 3) v_rx_bad[8] = 1;
            if (ln == 0) v_rx_bad[9] = 1;
            if (ln > 8) v_rx_bad[10] = 1;
            if (ln <= 8 && ln > r_rem) v_rx_bad[11] = 1;
            if (ty == 0 && ln != 1) v_rx_bad[12] = 1;
            if (ty <= 3 && ln >= 1 && ln <= r_rem && tlp_rx_last != (r_rem == 1)) v_rx_bad[13] = 1;
            if (ty > 3 || ln == 0 || ln > 8 || ln > r_rem || ty == 0 && ln != 1 || tlp_rx_last != (r_rem == 1)) bad = 1;
            else begin
              room = RXD - nfq0 >= ln + 8 * (oq0 + os0 + pq0 + ps0);
              skip = ty == 1 && oq0 == 0 || ty == 2 && os0 == 0 || ty == 3 && !room;
              r_aq = int'(w[23:20]); r_as = int'(w[19:16]); r_cl = ty; r_keep = !skip && ty != 0;
              if (ty != 0) v_rx_ty[ty] = 1;
              if (ty != 0 && ln == 1) v_rx_l1 = 1;
              if (ln == 8) v_rx_l8 = 1;
              if (ty == 0) v_misc_rx = 1;
              if (skip && ty == 3) begin o_ovf = 1; v_ovf = 1; end
              else if (skip) begin
                o_nocrd = 1;
                if (ty == 1) v_nocrd_req = 1; else v_nocrd_snp = 1;
              end
              if (!skip && ty != 0) begin c_rv = 1; c_rty = ty; c_rln = ln; end
              if (r_keep) tq.push_back({ln == 1 ? 2'(ty) : 2'd0, w});
              r_rem--; r_cnt = ln - 1;
              if (ln == 1) done = 1;
              else r_ph = skip ? R_SKIP : R_BODY;
            end
          end
          R_BODY, R_SKIP:
            if (tlp_rx_last != (r_rem == 1)) begin bad = 1; v_rx_bad[14] = 1; end
            else begin
              if (r_ph == R_BODY) begin
                tq.push_back({r_cnt == 1 ? 2'(r_cl) : 2'd0, w});
                c_rbv = 1; c_rbw = w;
              end
              r_rem--; r_cnt--;
              if (r_cnt == 0) done = 1;
            end
          default: if (tlp_rx_last) r_ph = 0;       // R_DROP
        endcase
        if (done) begin
          if (cq + r_aq > 31 || cs + r_as > 31) begin o_err = 1; v_crd_ovf = 1; end
          else begin cq += r_aq; cs += r_as; end
          if (r_keep) begin
            while (tq.size() != 0) fq.push_back(tq.pop_front());
            if (r_cl == 1) oq--;
            if (r_cl == 2) os--;
            if (nfq0 != 0 && rx_ready) v_pop_cmt = 1;
          end
          r_ph = tlp_rx_last ? 0 : R_MSG;
          r_good = 1;
        end
        if (bad) begin
          if (r_good) v_partial = 1;
          o_err = 1; tq.delete();
          r_ph = tlp_rx_last ? 0 : R_DROP;
        end
      end
      p_rxv = tlp_rx_valid;
      if (nfq0 >= RXD - 8) v_rx_deep = 1;
      // ---- the protocol layer reads
      if (nfq0 != 0 && rx_ready) begin : b_pop
        logic [33:0] x;
        x = fq.pop_front();
        if (x[33:32] == 2'd1) pq++;
        if (x[33:32] == 2'd2) ps++;
      end
      // ---- transmit
      case (t_ph)
        T_IDLE:
          if (misc) begin
            t_pl[0] = {8'h01, 4'(pq0), 4'(ps0), 16'h0};
            oq += pq0; os += ps0; pq -= pq0; ps -= ps0;
            t_n = 1; t_i = 0; t_ph = T_SEND;
            v_misc_tx = 1;
          end else if (tx_valid && txr) take(pq0, ps0);
          else if (tx_valid && d_ty == 4'd1 && cq == 0) v_wait_crd = 1;
        T_BODY:
          if (tx_valid) begin
            t_pl[t_n] = tx_data; t_n++; t_left--;
            c_bv = 1; c_bw = tx_data;
            if (t_left == 0) t_ph = T_GATH;
          end
        T_GATH:
          if (tx_valid && txr) take(pq0, ps0);
          else begin
            if (!tx_valid) v_cut_idle = 1;
            else if (!d_fit) v_cut_fit = 1;
            else v_cut_crd = 1;
            if (t_n == MAXP) v_full = 1;
            c_sv = 1; c_sn = t_n;
            t_i = 0; t_ph = T_SEND;
          end
        default:
          if (tlp_tx_ready) begin
            if (t_i == t_n + 3) begin t_ph = T_IDLE; t_n = 0; t_tag++; end
            t_i++;
          end else v_tx_stall = 1;
      endcase
      if (tph0 != T_IDLE || pq == 0 && ps == 0) t_idle = 0;
      else if (t_idle < CRT) t_idle++;
    end
  end

  // a header from the protocol layer, taken (dropped if bad)
  task automatic take(input int q, input int s);
    if (d_bad) begin
      o_err = 1;
      if (t_ph == T_IDLE) v_bad_hdr_idle = 1; else v_bad_hdr_gath = 1;
    end else begin
      if (q != 0 || s != 0) v_piggy = 1;
      t_pl[t_n] = {tx_data[31:24], 4'(q), 4'(s), tx_data[15:0]};
      oq += q; os += s; pq -= q; ps -= s;
      if (d_ty == 4'd1) cq--;
      if (d_ty == 4'd2) cs--;
      v_tx_ty[d_ty] = 1;
      c_tv = 1; c_tty = d_ty; c_tln = d_ln;
      if (d_ln == 4'd1) v_tx_l1 = 1;
      if (d_ln == 4'd8) v_tx_l8 = 1;
      if (t_ph == T_GATH && t_n >= 2) v_multi = 1;
      t_n++; t_left = int'(d_ln) - 1;
      t_ph = d_ln == 4'd1 ? T_GATH : T_BODY;
    end
  endtask

  // ---------------- assertions ----------------
  `SVA_INV(a_tx, tx_ready == e_txr && tlp_tx_valid == (t_ph == T_SEND) &&
                 (!tlp_tx_valid || tlp_tx_data == e_tdat && tlp_tx_last == e_tlast))
  `SVA_INV(a_rx, rx_valid == (fq.size() != 0) && (fq.size() == 0 || rx_data == fq[0][31:0] && rx_last == (fq[0][33:32] != 2'd0)))
  `SVA_INV(a_credits, int'(tx_crd_req) == cq && int'(tx_crd_snp) == cs)
  `SVA_INV(a_events, {ev_err, ev_nocrd, ev_ovf} == {o_err, o_nocrd, o_ovf})
  `SVA_RST(a_reset, !rst_n, !tlp_tx_valid && !rx_valid && tx_crd_req == 0 && tx_crd_snp == 0 && !ev_err && !ev_nocrd && !ev_ovf)

  // ---------------- functional coverage ----------------
  function automatic int dcls(input logic [31:0] v);
    return v == 32'd0 ? 0 : v == '1 ? 1 : (v == 32'h5555_5555 || v == 32'hAAAA_AAAA) ? 2 : 3;
  endfunction
  covergroup cg_ccix @(negedge clk);
    option.per_instance = 1;
    cp_tty: coverpoint c_tty iff (rst_n && c_tv) { bins req = {1}; bins snp = {2}; bins rsp = {3}; }
    cp_tln: coverpoint c_tln iff (rst_n && c_tv) { bins l[] = {[1:8]}; }
    x_tx: cross cp_tty, cp_tln;
    cp_tword: coverpoint dcls(c_bw) iff (rst_n && c_bv)
      { bins zero = {0}; bins ones = {1}; bins alt = {2}; bins other = {3}; }
    cp_tlp: coverpoint c_sn iff (rst_n && c_sv)
      { bins one = {1}; bins some = {[2:MAXP-1]}; bins full = {MAXP}; }
    cp_rty: coverpoint c_rty iff (rst_n && c_rv) { bins req = {1}; bins snp = {2}; bins rsp = {3}; }
    cp_rln: coverpoint c_rln iff (rst_n && c_rv) { bins l[] = {[1:8]}; }
    x_rx: cross cp_rty, cp_rln;
    cp_rword: coverpoint dcls(c_rbw) iff (rst_n && c_rbv)
      { bins zero = {0}; bins ones = {1}; bins alt = {2}; bins other = {3}; }
  endgroup
  cg_ccix u_cg_ccix = new;

  `FC(tx_request, v_tx_ty[1])
  `FC(tx_snoop, v_tx_ty[2])
  `FC(tx_response, v_tx_ty[3])
  `FC(tx_one_word, v_tx_l1)
  `FC(tx_eight_words, v_tx_l8)
  `FC(tx_full_payload, v_full)
  `FC(tx_three_messages_in_a_tlp, v_multi)
  `FC(tx_tlp_closed_no_room, v_cut_fit)
  `FC(tx_tlp_closed_no_credit, v_cut_crd)
  `FC(tx_tlp_closed_no_message, v_cut_idle)
  `FC(tx_waits_for_credit, v_wait_crd)
  `FC(tx_credits_piggybacked, v_piggy)
  `FC(tx_misc, v_misc_tx)
  `FC(tx_tlp_held_off, v_tx_stall)
  `FC(tx_bad_header_idle, v_bad_hdr_idle)
  `FC(tx_bad_header_gathering, v_bad_hdr_gath)
  `FC(rx_request, v_rx_ty[1])
  `FC(rx_snoop, v_rx_ty[2])
  `FC(rx_response, v_rx_ty[3])
  `FC(rx_one_word, v_rx_l1)
  `FC(rx_eight_words, v_rx_l8)
  `FC(rx_misc, v_misc_rx)
  `FC(rx_word_gaps, v_rx_gap)
  `FC(rx_bad_fmt_type, v_rx_bad[0])
  `FC(rx_bad_length_zero, v_rx_bad[1])
  `FC(rx_bad_length_big, v_rx_bad[2])
  `FC(rx_bad_message_code, v_rx_bad[3])
  `FC(rx_bad_vendor, v_rx_bad[4])
  `FC(rx_bad_target, v_rx_bad[5])
  `FC(rx_bad_dw3, v_rx_bad[6])
  `FC(rx_last_in_header, v_rx_bad[7])
  `FC(rx_bad_msgtype, v_rx_bad[8])
  `FC(rx_bad_msglen_zero, v_rx_bad[9])
  `FC(rx_bad_msglen_big, v_rx_bad[10])
  `FC(rx_message_past_payload, v_rx_bad[11])
  `FC(rx_bad_misc_length, v_rx_bad[12])
  `FC(rx_last_wrong_at_header, v_rx_bad[13])
  `FC(rx_last_wrong_in_body, v_rx_bad[14])
  `FC(rx_bad_after_good_message, v_partial)
  `FC(rx_request_no_credit, v_nocrd_req)
  `FC(rx_snoop_no_credit, v_nocrd_snp)
  `FC(rx_response_no_room, v_ovf)
  `FC(rx_credit_overflow, v_crd_ovf)
  `FC(rx_buffer_nearly_full, v_rx_deep)
  `FC(rx_read_while_committing, v_pop_cmt)
  `FC_RST(reset_in_traffic, rst_n && tlp_tx_valid && tlp_rx_valid ##1 !rst_n)
endmodule

bind CCIX_Cache_Coherent_Interconnect_top CCIX_Cache_Coherent_Interconnect_sva #(
  .MAXP(MAXP), .NREQ(NREQ), .NSNP(NSNP), .RXD(RXD), .CRT(CRT)) u_sva (.*);
