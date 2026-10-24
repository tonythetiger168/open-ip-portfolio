// SPDX-License-Identifier: Apache-2.0
// LTI translation unit: concurrent SVA against an independent reference
// model, plus functional coverage.
//  * The model keeps its own table, a queue of requests, the set of tags
//    out, the tags an invalidation waits for, the link state and the
//    credits out, and predicts every response (first matching entry,
//    permission check, lowest free tag), credit, inv_done and event.
//  Every output is compared on every clock.
`include "cov_macros.svh"
module ARM_Local_Translation_Interface_sva #(
  parameter int NE = 8, RQ = 4, NCT = 8
)(
  input logic        clk, rst_n, lm_open_req, lm_open_ack,
  input logic        la_valid,
  input logic [3:0]  la_id,
  input logic [19:0] la_va,
  input logic [7:0]  la_sid, la_ssid,
  input logic        la_ssidv,
  input logic [1:0]  la_rw,
  input logic        la_instr, la_priv, la_credit,
  input logic        lr_valid,
  input logic [3:0]  lr_id,
  input logic [1:0]  lr_resp,
  input logic [19:0] lr_pa,
  input logic [7:0]  lr_attr,
  input logic [$clog2(NCT)-1:0] lr_ctag,
  input logic        lc_valid,
  input logic [$clog2(NCT)-1:0] lc_ctag,
  input logic        cfg_we,
  input logic [$clog2(NE)-1:0] cfg_idx,
  input logic        cfg_v,
  input logic [7:0]  cfg_sid, cfg_ssid,
  input logic        cfg_ssidv,
  input logic [19:0] cfg_va, cfg_pa,
  input logic [3:0]  cfg_perm,
  input logic [7:0]  cfg_attr,
  input logic        inv_valid, inv_ready, inv_all,
  input logic [7:0]  inv_sid,
  input logic        inv_done,
  input logic [$clog2(NCT):0] ctags_out,
  input logic        ev_fault, ev_proto
);
  `COV_CLOCKING(clk, !rst_n)
  localparam int CLOSED = 0, OPEN = 1, CLOSING = 2;

  bit          m_v [0:NE-1], m_ssidv [0:NE-1];
  logic [7:0]  m_sid [0:NE-1], m_ssid [0:NE-1], m_attr [0:NE-1];
  logic [19:0] m_va [0:NE-1], m_pa [0:NE-1];
  logic [3:0]  m_perm [0:NE-1];
  logic [44:0] q [$];
  bit          tag [0:NCT-1], wt [0:NCT-1];
  bit          waiting;
  int          ln, cr, opens;
  logic [7:0]  o_sid [0:NE-1];
  bit          o_lr, o_crd, o_done, o_fault, o_proto;
  logic [3:0]  o_id;
  logic [1:0]  o_resp;
  logic [19:0] o_pa;
  logic [7:0]  o_attr;
  int          o_tag;

  function automatic int n_tags();
    n_tags = 0;
    for (int i = 0; i < NCT; i++) n_tags += int'(tag[i]);
  endfunction

  // coverage
  bit v_ok, v_tf, v_pf [0:3], v_ssid_match, v_ssid_any, v_two_hit, v_tags_full, v_wait_tag, v_inv_wait, v_inv_now;
  bit v_inv_all, v_inv_sid, v_inv_write, v_close_wait, v_nocrd, v_bad_lc, v_reopen, v_lc_with_lr;

  // per-step copies for the covergroup (set at posedge, sampled at negedge)
  bit c_av, c_pv;
  int c_rw, c_ip, c_resp, c_hit, c_tag, c_id, c_dep;

  always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      {c_av, c_pv} = '0; c_rw = 0; c_ip = 0; c_resp = 0; c_hit = 0; c_tag = 0; c_id = 0; c_dep = 0;
      for (int i = 0; i < NE; i++) begin
        m_v[i] = 0; m_ssidv[i] = 0; m_sid[i] = 0; m_ssid[i] = 0; m_attr[i] = 0; m_va[i] = 0; m_pa[i] = 0; m_perm[i] = 0;
      end
      q.delete();
      for (int i = 0; i < NCT; i++) begin tag[i] = 0; wt[i] = 0; end
      waiting = 0; ln = CLOSED; cr = 0; opens = 0;
      {o_lr, o_crd, o_done, o_fault, o_proto} = '0;
      o_id = 0; o_resp = 0; o_pa = 0; o_attr = 0; o_tag = 0;
    end else begin : b_step
      int  nq0, hit, free;
      bit  pushed, answered, ok;
      logic [44:0] r;
      nq0 = q.size(); pushed = 0; answered = 0;
      {c_av, c_pv} = '0;
      {o_lr, o_crd, o_done, o_fault, o_proto} = '0;
      // ---- the head request, on the table as it stands
      if (nq0 != 0) begin
        r = q[0];
        hit = -1;
        for (int i = 0; i < NE; i++)
          if (hit < 0 && m_v[i] && m_sid[i] == r[20:13] && m_va[i] == r[40:21] && (!m_ssidv[i] || r[4] && m_ssid[i] == r[12:5]))
            hit = i;
        if (hit >= 0) begin
          for (int i = hit + 1; i < NE; i++)
            if (m_v[i] && m_sid[i] == r[20:13] && m_va[i] == r[40:21] && (!m_ssidv[i] || r[4] && m_ssid[i] == r[12:5]))
              v_two_hit = 1;
          if (m_ssidv[hit]) v_ssid_match = 1; else v_ssid_any = 1;
        end
        ok = hit >= 0 && !(r[2] && !m_perm[hit][0]) && !(r[3] && !m_perm[hit][1]) && !(r[1] && !m_perm[hit][2]) &&
             !(!r[0] && !m_perm[hit][3]);
        free = -1;
        for (int i = 0; i < NCT; i++) if (free < 0 && !tag[i]) free = i;
        if (ok && free < 0) v_wait_tag = 1;
        else begin
          answered = 1;
          void'(q.pop_front());
          o_lr = 1; o_id = r[44:41];
          c_av = 1; c_rw = int'(r[3:2]); c_ip = int'(r[1:0]); c_id = int'(r[44:41]); c_hit = hit;
          c_resp = hit < 0 ? 1 : (!ok ? 2 : 0); c_tag = free;
          if (hit < 0) begin o_resp = 1; o_pa = 0; o_attr = 0; o_tag = 0; o_fault = 1; v_tf = 1; end
          else if (!ok) begin
            o_resp = 2; o_pa = 0; o_attr = 0; o_tag = 0; o_fault = 1;
            if (r[2] && !m_perm[hit][0]) v_pf[0] = 1;
            if (r[3] && !m_perm[hit][1]) v_pf[1] = 1;
            if (r[1] && !m_perm[hit][2]) v_pf[2] = 1;
            if (!r[0] && !m_perm[hit][3]) v_pf[3] = 1;
          end else begin
            o_resp = 0; o_pa = m_pa[hit]; o_attr = m_attr[hit]; o_tag = free; v_ok = 1;
          end
        end
      end
      if (n_tags() == NCT) v_tags_full = 1;
      // ---- LA
      if (la_valid) begin
        if (cr == 0) begin o_proto = 1; v_nocrd = 1; end
        else begin
          cr--; pushed = 1;
          q.push_back({la_id, la_va, la_sid, la_ssid, la_ssidv, la_rw, la_instr, la_priv});
          c_pv = 1; c_dep = q.size();
        end
      end
      // ---- LC, then the tag handed out now
      if (lc_valid) begin
        if (!tag[lc_ctag]) begin o_proto = 1; v_bad_lc = 1; end
        else tag[lc_ctag] = 0;
        if (answered && o_resp == 0) v_lc_with_lr = 1;
      end
      if (answered && o_resp == 0) tag[o_tag] = 1;
      // ---- table write, then invalidation (matched on the StreamIDs before the write)
      for (int i = 0; i < NE; i++) o_sid[i] = m_sid[i];
      if (cfg_we) begin
        m_v[cfg_idx] = cfg_v; m_ssidv[cfg_idx] = cfg_ssidv; m_sid[cfg_idx] = cfg_sid; m_ssid[cfg_idx] = cfg_ssid;
        m_va[cfg_idx] = cfg_va; m_pa[cfg_idx] = cfg_pa; m_perm[cfg_idx] = cfg_perm; m_attr[cfg_idx] = cfg_attr;
      end
      if (inv_valid && !waiting) begin
        if (inv_all) v_inv_all = 1; else v_inv_sid = 1;
        if (cfg_we) v_inv_write = 1;
        for (int i = 0; i < NE; i++) if (inv_all || o_sid[i] == inv_sid) m_v[i] = 0;
        if (n_tags() == 0) begin o_done = 1; v_inv_now = 1; end
        else begin
          waiting = 1;
          for (int i = 0; i < NCT; i++) wt[i] = tag[i];
          v_inv_wait = 1;
        end
      end else if (waiting) begin : b_w
        bit any;
        any = 0;
        for (int i = 0; i < NCT; i++) begin wt[i] = wt[i] && tag[i]; any |= wt[i]; end
        if (!any) begin waiting = 0; o_done = 1; end
      end
      // ---- link and credits
      case (ln)
        CLOSED: if (lm_open_req) begin ln = OPEN; opens++; if (opens > 1) v_reopen = 1; end
        OPEN: begin
          if (cr + q.size() < RQ) begin o_crd = 1; cr++; end
          if (!lm_open_req) ln = CLOSING;
        end
        default: begin
          if (nq0 == 0 && !pushed && n_tags() == 0) begin ln = CLOSED; cr = 0; end
          else v_close_wait = 1;
        end
      endcase
    end
  end

  // ---------------- assertions ----------------
  `SVA_INV(a_lr, lr_valid == o_lr && (!o_lr || lr_id == o_id && lr_resp == o_resp && lr_pa == o_pa && lr_attr == o_attr &&
                                       int'(lr_ctag) == o_tag))
  `SVA_INV(a_link, lm_open_ack == (ln != CLOSED) && la_credit == o_crd)
  `SVA_INV(a_inv, inv_ready == !waiting && inv_done == o_done && int'(ctags_out) == n_tags())
  `SVA_INV(a_events, ev_fault == o_fault && ev_proto == o_proto)
  `SVA_RST(a_reset, !rst_n, !lm_open_ack && !la_credit && !lr_valid && inv_ready && !inv_done && ctags_out == 0 &&
                          !ev_fault && !ev_proto)

  // ---------------- functional coverage ----------------
  // request access kind (read / write bits, instruction / privileged
  // bits) x response, entry hit and tag handed out by OK responses,
  // response ID, request queue depth
  covergroup cg_lti @(negedge clk);
    option.per_instance = 1;
    cp_resp: coverpoint c_resp iff (rst_n && c_av) { bins ok = {0}; bins tfault = {1}; bins pfault = {2}; }
    cp_rw: coverpoint c_rw iff (rst_n && c_av) { bins none = {0}; bins rd = {1}; bins wr = {2}; bins rdwr = {3}; }
    cp_ip: coverpoint c_ip iff (rst_n && c_av) { bins data_user = {0}; bins data_priv = {1}; bins instr_user = {2}; bins instr_priv = {3}; }
    x_rw_resp: cross cp_rw, cp_resp;
    x_ip_resp: cross cp_ip, cp_resp;
    cp_hit: coverpoint c_hit iff (rst_n && c_av && c_resp == 0) { bins e[] = {[0:NE-1]}; }
    cp_tag: coverpoint c_tag iff (rst_n && c_av && c_resp == 0) { bins t[] = {[0:NCT-1]}; }
    cp_id: coverpoint c_id iff (rst_n && c_av) { bins i[] = {[0:15]}; }
    cp_depth: coverpoint c_dep iff (rst_n && c_pv) { bins d[] = {[1:RQ]}; }
  endgroup
  cg_lti u_cg_lti = new;

  `FC(translation_ok, v_ok)
  `FC(translation_fault, v_tf)
  `FC(permission_fault_read, v_pf[0])
  `FC(permission_fault_write, v_pf[1])
  `FC(permission_fault_instruction, v_pf[2])
  `FC(permission_fault_unprivileged, v_pf[3])
  `FC(entry_for_one_substream, v_ssid_match)
  `FC(entry_for_any_substream, v_ssid_any)
  `FC(two_entries_match, v_two_hit)
  `FC(every_tag_out, v_tags_full)
  `FC(response_waits_for_tag, v_wait_tag)
  `FC(tag_back_as_one_goes_out, v_lc_with_lr)
  `FC(invalidate_all, v_inv_all)
  `FC(invalidate_stream, v_inv_sid)
  `FC(invalidate_with_table_write, v_inv_write)
  `FC(invalidation_waits_for_tags, v_inv_wait)
  `FC(invalidation_done_at_once, v_inv_now)
  `FC(close_waits, v_close_wait)
  `FC(request_without_credit, v_nocrd)
  `FC(tag_returned_not_out, v_bad_lc)
  `FC(link_opened_again, v_reopen)
  // a response going out with tags out as reset lands (taken on the
  // falling edge, before the asynchronous reset clears them)
  bit busy_n = 0;
  always @(negedge clk) busy_n <= lr_valid && ctags_out != 0;
  `FC_RST(reset_in_traffic, !rst_n && busy_n)
endmodule

bind ARM_Local_Translation_Interface_top ARM_Local_Translation_Interface_sva #(.NE(NE), .RQ(RQ), .NCT(NCT)) u_sva (.*);
