// SPDX-License-Identifier: Apache-2.0
// CXS port: concurrent SVA against an independent reference model, plus
// functional coverage.
//  * Transmit: the model keeps the flit being filled as words flagged
//    start / end / error, decides when it is full, builds CXSCNTL from the
//    flags when it goes, and follows the link states and credits.
//  * Receive: the model checks a flit by counting, for each word, the
//    packets open before it (the open packet plus the STARTs up to it
//    less the ENDs before it), keeps the flit buffers as a queue of words,
//    and follows the link states and credits granted.
//  Every output is compared on every clock.
`include "cov_macros.svh"
module CXS_CCIX_Stream_Interface_sva #(
  parameter int RXF = 4
)(
  input logic         clk, rst_n, tx_en, rx_en,
  input logic         tx_valid, tx_ready,
  input logic [31:0]  tx_data,
  input logic         tx_last, tx_err,
  input logic         rx_valid, rx_ready,
  input logic [31:0]  rx_data,
  input logic         rx_last, rx_err,
  input logic         cxs_tx_valid,
  input logic [127:0] cxs_tx_data,
  input logic [13:0]  cxs_tx_cntl,
  input logic         cxs_tx_crdgnt, cxs_tx_crdrtn, cxs_tx_activereq, cxs_tx_activeack, cxs_tx_deacthint,
  input logic         cxs_rx_valid,
  input logic [127:0] cxs_rx_data,
  input logic [13:0]  cxs_rx_cntl,
  input logic         cxs_rx_crdgnt, cxs_rx_crdrtn, cxs_rx_activereq, cxs_rx_activeack, cxs_rx_deacthint,
  input logic [1:0]   tx_link, rx_link,
  input logic [3:0]   tx_credits,
  input logic         ev_crd, ev_cntl
);
  `COV_CLOCKING(clk, !rst_n)
  localparam int STOP = 0, ACT = 1, RUN = 2, DEACT = 3;

  // ---------------- transmit model ----------------
  int          t_ln, t_n, t_cr;
  logic [31:0] t_d [0:3];
  bit          t_s [0:3], t_e [0:3], t_r [0:3];
  bit          t_ip;
  bit          o_tv, o_rtn;
  logic [127:0] o_td;
  logic [13:0] o_tc;
  // ---------------- receive model ----------------
  int          r_ln, r_g;
  bit          r_ip;
  logic [33:0] q [$];                    // words to hand out {err, last, data}
  int          qn [$];                   // words per flit buffer
  bit          o_gnt, o_crd, o_cntl;

  function automatic int n_s();
    n_s = 0;
    for (int i = 0; i < t_n; i++) n_s += int'(t_s[i]);
  endfunction
  function automatic int n_e();
    n_e = 0;
    for (int i = 0; i < t_n; i++) n_e += int'(t_e[i]);
  endfunction
  wire e_closed = t_n != 0 && !t_ip && (n_s() == 2 || n_e() == 2);
  wire e_txr = t_n != 4 && !e_closed;

  // the flit on cxs_rx_*, checked by counting
  logic [3:0] k_v, k_l, k_r;
  bit         k_bad, k_ip;
  always_comb begin : b_chk
    int ns, ne, p [0:1], q2 [0:1], a;
    ns = cxs_rx_cntl[13] ? (cxs_rx_cntl[12] ? 2 : -1) : int'(cxs_rx_cntl[12]);
    ne = cxs_rx_cntl[7] ? (cxs_rx_cntl[6] ? 2 : -1) : int'(cxs_rx_cntl[6]);
    p[0] = int'(cxs_rx_cntl[11:10]); p[1] = int'(cxs_rx_cntl[9:8]);
    q2[0] = int'(cxs_rx_cntl[5:4]); q2[1] = int'(cxs_rx_cntl[3:2]);
    k_bad = ns < 0 || ne < 0 || ns == 2 && p[1] <= p[0] || ne == 2 && q2[1] <= q2[0];
    k_v = '0; k_l = '0; k_r = '0;
    for (int w = 0; w < 4; w++) begin
      int sb, sa, eb, ea;
      sb = 0; sa = 0; eb = 0; ea = 0;
      for (int i = 0; i < 2; i++) begin
        if (i < ns && p[i] < w) sb++;
        if (i < ns && p[i] == w) sa++;
        if (i < ne && q2[i] < w) eb++;
        if (i < ne && q2[i] == w) begin ea++; k_r[w] = cxs_rx_cntl[i]; end
      end
      a = int'(r_ip) + sb - eb;                  // open before this word
      if (sa != 0 && a != 0) k_bad = 1;
      a += sa;
      if (a > 1 || ea > a) k_bad = 1;
      k_v[w] = a == 1;
      k_l[w] = ea != 0;
    end
    k_ip = int'(r_ip) + (ns > 0 ? ns : 0) - (ne > 0 ? ne : 0) == 1;
    if (k_v == '0) k_bad = 1;
  end

  // coverage
  bit v_two_s, v_two_e, v_one_word_pkt, v_err_end, v_partial, v_cross, v_wait_mid, v_closed_s, v_closed_e;
  bit v_no_crd_tx, v_crd15, v_crd_ovf_tx, v_rtn, v_deact_hint, v_deact_en, v_act_wait;
  // per-step copies for the covergroup (set at posedge, sampled at negedge)
  bit c_wv, c_fv, c_kv;
  int c_fn, c_fs, c_fe, c_fsp, c_fep, c_kn;
  logic [31:0] c_wd, c_kd;
  bit v_bad [0:5], v_abort, v_rx_nocrd, v_rtn_extra, v_rx_full, v_hint, v_rx_deact_wait, v_skip_word;

  always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      t_ln = STOP; t_n = 0; t_cr = 0; t_ip = 0; o_tv = 0; o_rtn = 0; o_td = 0; o_tc = 0;
      for (int i = 0; i < 4; i++) begin t_d[i] = 0; t_s[i] = 0; t_e[i] = 0; t_r[i] = 0; end
      r_ln = STOP; r_g = 0; r_ip = 0; q.delete(); qn.delete();
      o_gnt = 0; o_crd = 0; o_cntl = 0;
    end else begin : b_step
      bit txr, full, send, ip0;
      int nq0, n0;
      txr = e_txr;
      full = t_n == 4 || e_closed || t_n != 0 && !t_ip && !tx_valid;
      send = full && t_ln == RUN && t_cr > 0;
      nq0 = qn.size(); n0 = t_n; ip0 = t_ip;
      o_tv = 0; o_rtn = 0; o_gnt = 0; o_crd = 0; o_cntl = 0;
      {c_wv, c_fv, c_kv} = '0;
      // ---- transmit
      if (cxs_tx_crdgnt) begin
        if (t_cr == 15) begin o_crd = 1; v_crd_ovf_tx = 1; end
        else t_cr++;
      end
      if (t_cr == 15) v_crd15 = 1;
      if (tx_valid && !txr) begin
        if (t_n != 0 && t_n != 4 && e_closed && n_s() == 2) v_closed_s = 1;
        if (t_n != 0 && t_n != 4 && e_closed && n_e() == 2) v_closed_e = 1;
      end
      if (full && t_ln == RUN && t_cr == 0) v_no_crd_tx = 1;
      if (t_ip && !tx_valid && t_n != 0 && t_n != 4) v_wait_mid = 1;
      if (tx_valid && txr) begin
        t_d[t_n] = tx_data; t_s[t_n] = !t_ip; t_e[t_n] = tx_last; t_r[t_n] = tx_last && tx_err;
        c_wv = 1; c_wd = tx_data;
        if (!t_ip && tx_last) v_one_word_pkt = 1;
        if (tx_last && tx_err) v_err_end = 1;
        t_ip = !tx_last;
        t_n++;
      end
      if (send) begin : b_send
        int s, e, sp [0:1], ep [0:1];
        logic [1:0] er;
        s = 0; e = 0; sp[0] = 0; sp[1] = 0; ep[0] = 0; ep[1] = 0; er = 0;
        for (int i = 0; i < 4; i++) begin
          if (i < t_n && t_s[i]) begin sp[s] = i; s++; end
          if (i < t_n && t_e[i]) begin ep[e] = i; er[e] = t_r[i]; e++; end
        end
        t_cr--;
        o_tv = 1;
        c_fv = 1; c_fn = t_n; c_fs = s; c_fe = e; c_fsp = s != 0 ? sp[0] : -1; c_fep = e != 0 ? ep[0] : -1;
        o_td = {t_d[3], t_d[2], t_d[1], t_d[0]};
        o_tc = {s == 2, s != 0, 2'(sp[0]), 2'(sp[1]), e == 2, e != 0, 2'(ep[0]), 2'(ep[1]), er};
        if (s == 2) v_two_s = 1;
        if (e == 2) v_two_e = 1;
        if (t_n < 4) v_partial = 1;
        if (t_ip) v_cross = 1;
        t_n = 0;
        for (int i = 0; i < 4; i++) begin t_s[i] = 0; t_e[i] = 0; t_r[i] = 0; end
      end
      case (t_ln)
        STOP: if (tx_en && !cxs_tx_activeack) t_ln = ACT;
        ACT: begin
          v_act_wait = 1;
          if (cxs_tx_activeack) t_ln = RUN;
        end
        RUN:
          if ((!tx_en || cxs_tx_deacthint) && !ip0 && n0 == 0) begin
            t_ln = DEACT;
            if (cxs_tx_deacthint) v_deact_hint = 1; else v_deact_en = 1;
          end
        default: begin
          if (t_cr > 0) begin t_cr--; o_rtn = 1; v_rtn = 1; end
          if (!cxs_tx_activeack) begin t_ln = STOP; t_cr = 0; end
        end
      endcase
      // ---- receive
      if (cxs_rx_crdrtn) begin
        if (r_g == 0) begin o_crd = 1; v_rtn_extra = 1; end
        else r_g--;
      end
      if (cxs_rx_valid) begin
        if (r_g == 0) begin o_crd = 1; v_rx_nocrd = 1; end
        else begin
          r_g--;
          if (k_bad) begin
            o_cntl = 1;
            if (r_ip) begin q.push_back({1'b1, 1'b1, 32'd0}); qn.push_back(1); r_ip = 0; v_abort = 1; end
          end else begin : b_keep
            int n;
            n = 0;
            for (int w = 0; w < 4; w++)
              if (k_v[w]) begin q.push_back({k_r[w] && k_l[w], k_l[w], cxs_rx_data[32 * w +: 32]}); n++; end
            if (k_v != 4'b1111 && k_v[0] && k_v[3]) v_skip_word = 1;
            qn.push_back(n);
            r_ip = k_ip;
            c_kv = 1; c_kn = n; c_kd = cxs_rx_data[31:0];
          end
        end
      end
      if (nq0 != 0 && rx_ready) begin
        void'(q.pop_front());
        qn[0]--;
        if (qn[0] == 0) void'(qn.pop_front());
      end
      if (nq0 == RXF) v_rx_full = 1;
      case (r_ln)
        STOP: if (cxs_rx_activereq && rx_en) r_ln = RUN;
        RUN: begin
          if (!rx_en) v_hint = 1;
          if (qn.size() + r_g < RXF) begin o_gnt = 1; r_g++; end
          if (!cxs_rx_activereq) r_ln = DEACT;
        end
        default: begin
          if (r_g != 0) v_rx_deact_wait = 1;
          if (r_g == 0) r_ln = STOP;
        end
      endcase
    end
  end

  // ---------------- assertions ----------------
  `SVA_INV(a_tx, tx_ready == e_txr && cxs_tx_valid == o_tv && (!o_tv || cxs_tx_data == o_td && cxs_tx_cntl == o_tc) &&
                 cxs_tx_crdrtn == o_rtn && cxs_tx_activereq == (t_ln == ACT || t_ln == RUN) &&
                 int'(tx_link) == t_ln && int'(tx_credits) == t_cr)
  `SVA_INV(a_rx, rx_valid == (q.size() != 0) && (q.size() == 0 || {rx_err, rx_last, rx_data} == q[0]) &&
                 cxs_rx_crdgnt == o_gnt && cxs_rx_activeack == (r_ln != STOP) &&
                 cxs_rx_deacthint == (r_ln == RUN && !rx_en) && int'(rx_link) == r_ln)
  `SVA_INV(a_events, ev_crd == o_crd && ev_cntl == o_cntl)
  `SVA_RST(a_reset, !rst_n, !cxs_tx_valid && !cxs_tx_activereq && !cxs_tx_crdrtn && !cxs_rx_activeack && !cxs_rx_crdgnt &&
                          !rx_valid && tx_credits == 0 && !ev_crd && !ev_cntl)

  // ---------------- functional coverage ----------------
  function automatic int dcls(input logic [31:0] v);
    return v == 32'd0 ? 0 : v == '1 ? 1 : (v == 32'h5555_5555 || v == 32'hAAAA_AAAA) ? 2 : 3;
  endfunction
  covergroup cg_cxs @(negedge clk);
    option.per_instance = 1;
    cp_twd: coverpoint dcls(c_wd) iff (rst_n && c_wv)
      { bins zero = {0}; bins ones = {1}; bins alt = {2}; bins other = {3}; }
    cp_fn: coverpoint c_fn iff (rst_n && c_fv) { bins n[] = {[1:4]}; }
    cp_fs: coverpoint c_fs iff (rst_n && c_fv) { bins none = {0}; bins one = {1}; bins two = {2}; }
    cp_fe: coverpoint c_fe iff (rst_n && c_fv) { bins none = {0}; bins one = {1}; bins two = {2}; }
    cp_fsp: coverpoint c_fsp iff (rst_n && c_fv && c_fs != 0) { bins p[] = {[0:3]}; }
    cp_fep: coverpoint c_fep iff (rst_n && c_fv && c_fe != 0) { bins p[] = {[0:3]}; }
    cp_kn: coverpoint c_kn iff (rst_n && c_kv) { bins n[] = {[1:4]}; }
    cp_kd: coverpoint dcls(c_kd) iff (rst_n && c_kv)
      { bins zero = {0}; bins ones = {1}; bins alt = {2}; bins other = {3}; }
  endgroup
  cg_cxs u_cg_cxs = new;

  `FC(tx_two_starts_in_a_flit, v_two_s)
  `FC(tx_two_ends_in_a_flit, v_two_e)
  `FC(tx_one_word_packet, v_one_word_pkt)
  `FC(tx_end_error, v_err_end)
  `FC(tx_partial_flit, v_partial)
  `FC(tx_packet_across_flits, v_cross)
  `FC(tx_packet_waits_mid_flit, v_wait_mid)
  `FC(tx_flit_closed_two_starts, v_closed_s)
  `FC(tx_flit_closed_two_ends, v_closed_e)
  `FC(tx_waits_for_credit, v_no_crd_tx)
  `FC(tx_fifteen_credits, v_crd15)
  `FC(tx_credit_grant_overflow, v_crd_ovf_tx)
  `FC(tx_credits_returned, v_rtn)
  `FC(tx_waits_in_activate, v_act_wait)
  `FC(tx_deactivate_on_hint, v_deact_hint)
  `FC(tx_deactivate_on_enable, v_deact_en)
  `FC(rx_bad_flit_closes_packet, v_abort)
  `FC(rx_flit_without_credit, v_rx_nocrd)
  `FC(rx_credit_returned_beyond, v_rtn_extra)
  `FC(rx_buffers_full, v_rx_full)
  `FC(rx_deacthint, v_hint)
  `FC(rx_deactivate_waits_for_credits, v_rx_deact_wait)
  `FC(rx_unused_word_between, v_skip_word)
  `FC(rx_bad_cntl, ev_cntl)
  `FC_RST(reset_in_traffic, rst_n && cxs_tx_valid && rx_valid ##1 !rst_n)
endmodule

bind CXS_CCIX_Stream_Interface_top CXS_CCIX_Stream_Interface_sva #(.RXF(RXF)) u_sva (.*);
