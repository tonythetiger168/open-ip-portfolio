// SPDX-License-Identifier: Apache-2.0
// CHI subordinate node: concurrent SVA against an independent reference
// model, plus functional coverage.
//  * The model keeps memory as bytes, the request slots as a queue of
//    flits, the two write buffers as records, and every credit count. Each
//    clock it takes the credits and flits that arrive, picks the TXRSP flit
//    (a Comp owed first, then the head request's response), sends the
//    head's CompData beat, and grants credits for free slots.
//  * Both lcrdv outputs, every TXRSP and TXDAT flit and the event pulses
//    are compared on every clock.
`include "cov_macros.svh"
module CHI_sva #(
  parameter int LINES = 16, RQ = 4, NDC = 2
)(
  input logic         clk, rst_n,
  input logic         rxreqflitv,
  input logic [40:0]  rxreqflit,
  input logic         rxreqlcrdv,
  input logic         rxdatflitv,
  input logic [157:0] rxdatflit,
  input logic         rxdatlcrdv,
  input logic         txrspflitv,
  input logic [28:0]  txrspflit,
  input logic         txrsplcrdv,
  input logic         txdatflitv,
  input logic [146:0] txdatflit,
  input logic         txdatlcrdv,
  input logic         ev_err, ev_proto
);
  `COV_CLOCKING(clk, !rst_n)

  logic [7:0]   mb [0:LINES*64-1];
  logic [40:0]  q [$];
  int           g, dg, cr, cd;               // credits: requester's REQ / DAT, node's RSP / DAT
  bit           rc;                          // ReadReceipt sent for the head
  int           bt;                          // CompData beats sent for the head
  // write buffers
  bit           wv [0:1], wptl [0:1], werr [0:1], wcomp [0:1];
  logic [6:0]   wtgt [0:1];
  logic [7:0]   wtxn [0:1];
  int           wln [0:1];
  bit           wneed [0:1][0:3], wgot [0:1][0:3];
  // outputs, as registered
  bit           m_rl, m_dl, m_rv, m_dv, m_err, m_pro;
  logic [28:0]  m_rf;
  logic [146:0] m_df;

  // coverage
  bit v_rd_size [0:7], v_wr_size [0:7], v_rcpt, v_full, v_unsup, v_full_badsize, v_derr_rd, v_derr_wr;
  bit v_comp_first, v_both_busy, v_interleave, v_bad_op, v_bad_dbid, v_bad_id, v_dup_id, v_nocrd_req, v_nocrd_dat;
  bit v_cr15, v_rsp_starve, v_dat_starve, v_q_full, v_be_part, v_be_none, v_both_comp;
  int last_s = -1;
  // per-step copies for the covergroup (set at posedge, sampled at negedge)
  bit c_qv, c_qin, c_wv, c_dv;
  int c_qk, c_qln, c_wid, c_did;
  logic [127:0] c_wd, c_rd;

  always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      for (int i = 0; i < LINES * 64; i++) mb[i] = 8'h00;
      q.delete();
      g = 0; dg = 0; cr = 0; cd = 0; rc = 0; bt = 0;
      for (int i = 0; i < 2; i++) begin wv[i] = 0; wcomp[i] = 0; end
      {m_rl, m_dl, m_rv, m_dv, m_err, m_pro} = '0;
      m_rf = '0; m_df = '0;
    end else begin : b_step
      bit          push, pop, comp, rspg, datg, hv, hrd, hwr, hin, hord;
      int          o_cr, o_cd;
      logic [40:0] hd;
      logic [5:0]  hop;
      int          hs, hln, hd0, hnb, cslot, wfree;
      {m_rl, m_dl, m_rv, m_dv, m_err, m_pro} = '0;
      push = 0; pop = 0;
      {c_qv, c_wv, c_dv} = '0;
      o_cr = cr; o_cd = cd;
      if (cr == 15) v_cr15 = 1;
      if (txrsplcrdv) cr = (cr + 1) % 16;
      if (txdatlcrdv) cd = (cd + 1) % 16;
      // ---- the head, as it stands this clock
      hv = q.size() != 0;
      hd = hv ? q[0] : '0;
      hop = hd[25:20]; hord = hd[19]; hs = hd[18:16];
      hin = hd[15:6] < LINES;
      hln = hd[15:6];
      hrd = hop == 6'h04;
      hwr = hop == 6'h1C && hs != 7 || hop == 6'h1D && hs == 6;
      hd0 = hs == 6 ? 0 : hs == 5 ? {hd[5], 1'b0} : hd[5:4];
      hnb = hrd && hs == 7 ? 1 : hs == 6 ? 4 : hs == 5 ? 2 : 1;
      wfree = !wv[0] ? 0 : !wv[1] ? 1 : -1;
      comp = (wcomp[0] || wcomp[1]) && o_cr != 0;
      if (wcomp[0] && wcomp[1]) v_both_comp = 1;
      cslot = wcomp[0] ? 0 : 1;
      // ---- RXREQ
      if (rxreqflitv) begin
        if (g == 0) begin m_pro = 1; v_nocrd_req = 1; end
        else begin g--; push = 1; end
      end
      // ---- RXDAT
      if (rxdatflitv) begin : b_dat
        logic [7:0] t;
        int         s, id;
        bit         ok;
        t = rxdatflit[157:150]; s = t[7]; id = rxdatflit[145:144];
        ok = rxdatflit[149:146] == 4'h3 && wv[s] && t[6:0] == wtxn[s][6:0] && wneed[s][id] && !wgot[s][id];
        if (dg == 0) v_nocrd_dat = 1;
        if (dg != 0 && !ok) begin
          if (rxdatflit[149:146] != 4'h3) v_bad_op = 1;
          else if (!wv[s] || t[6:0] != wtxn[s][6:0]) v_bad_dbid = 1;
          else if (!wneed[s][id]) v_bad_id = 1;
          else v_dup_id = 1;
        end
        if (dg == 0 || !ok) m_pro = 1;
        else begin : b_wr
          bit all;
          wgot[s][id] = 1;
          if (!werr[s] && rxdatflit[143:128] == 16'hFFFF) begin c_wv = 1; c_wid = id; c_wd = rxdatflit[127:0]; end
          if (last_s >= 0 && last_s != s) v_interleave = 1;
          last_s = s;
          if (rxdatflit[143:128] == 16'hFFFF) ; else if (rxdatflit[143:128] == 0) v_be_none = 1; else v_be_part = 1;
          if (!werr[s])
            for (int b = 0; b < 16; b++) if (rxdatflit[128 + b]) mb[wln[s] * 64 + id * 16 + b] = rxdatflit[8 * b +: 8];
          all = 1;
          for (int i = 0; i < 4; i++) if (wneed[s][i] && !wgot[s][i]) all = 0;
          if (all) begin
            if (wptl[s]) wcomp[s] = 1;
            else wv[s] = 0;
          end
        end
        if (dg != 0) dg--;
      end
      // ---- TXRSP: a Comp owed first
      if (comp) begin
        cr--;
        m_rv = 1;
        m_rf = {wtgt[cslot], wtxn[cslot], 4'h4, werr[cslot] ? 2'b10 : 2'b00, 8'h00};
        wcomp[cslot] = 0; wv[cslot] = 0;
      end
      datg = hv && hrd && !(hord && !rc) && o_cd != 0;
      if (hv && hrd && !(hord && !rc) && o_cd == 0) v_dat_starve = 1;
      // the head's response (computed from the buffers before this clock's changes)
      rspg = hv && (hrd ? hord && !rc : !hwr || wfree >= 0) && !comp && o_cr != 0;
      if (hv && (hrd ? hord && !rc : !hwr || wfree >= 0) && comp) v_comp_first = 1;
      if (hv && hwr && wfree < 0) v_both_busy = 1;
      if (hv && (hrd ? hord && !rc : !hwr || wfree >= 0) && !comp && o_cr == 0) v_rsp_starve = 1;
      if (rspg) begin
        cr--;
        m_rv = 1;
        c_qv = !hrd; c_qin = hin; c_qln = hln; c_qk = hwr ? (hop == 6'h1D ? 1 : 0) : 2;
        if (hrd) begin
          m_rf = {hd[40:26], 4'h8, 2'b00, 8'h00};
          rc = 1;
          v_rcpt = 1;
        end else if (hwr) begin
          m_rf = {hd[40:26], hop == 6'h1D ? 4'h5 : 4'h6, hin ? 2'b00 : 2'b10, 1'(wfree), hd[32:26]};
          wv[wfree] = 1; wptl[wfree] = hop == 6'h1C; werr[wfree] = !hin; wcomp[wfree] = 0;
          wtgt[wfree] = hd[40:34]; wtxn[wfree] = hd[33:26]; wln[wfree] = hln % LINES;
          for (int i = 0; i < 4; i++) begin wneed[wfree][i] = i >= hd0 && i < hd0 + hnb; wgot[wfree][i] = 0; end
          if (!hin) begin m_err = 1; v_derr_wr = 1; end
          v_wr_size[hs] = 1;
          if (hop == 6'h1D) v_full = 1;
          void'(q.pop_front()); pop = 1;
        end else begin
          m_rf = {hd[40:26], 4'h4, 2'b11, 8'h00};
          m_err = 1;
          if (hop == 6'h1D) v_full_badsize = 1; else v_unsup = 1;
          void'(q.pop_front()); pop = 1;
        end
      end
      // ---- TXDAT: the head's CompData beat
      if (datg) begin : b_cd
        logic [127:0] d;
        int id;
        cd--;
        id = (hd0 + bt) % 4;
        for (int b = 0; b < 16; b++) d[8 * b +: 8] = hin && hs != 7 ? mb[hln * 64 + id * 16 + b] : 8'h00;
        m_dv = 1;
        if (bt == 0) begin c_qv = 1; c_qin = hin && hs != 7; c_qln = hln; c_qk = 3; end
        if (hin && hs != 7) begin c_dv = 1; c_did = id; c_rd = d; end
        m_df = {hd[40:26], hs == 7 ? 2'b11 : hin ? 2'b00 : 2'b10, 2'(id), d};
        if (bt == 0 && (!hin || hs == 7)) begin m_err = 1; v_derr_rd = 1; end
        bt++;
        if (bt == hnb) begin
          bt = 0; rc = 0;
          v_rd_size[hs] = 1;
          void'(q.pop_front()); pop = 1;
        end
      end
      if (push) q.push_back(rxreqflit);
      if (q.size() == RQ) v_q_full = 1;
      // ---- credits out (the slots counted before this clock's pop)
      if (g + q.size() + int'(pop) < RQ) begin m_rl = 1; g++; end
      if (dg != NDC) begin m_dl = 1; dg++; end
    end
  end

  // ---------------- assertions ----------------
  `SVA_INV(a_credits, rxreqlcrdv == m_rl && rxdatlcrdv == m_dl)
  `SVA_INV(a_rsp, txrspflitv == m_rv && (!m_rv || txrspflit == m_rf))
  `SVA_INV(a_dat, txdatflitv == m_dv && (!m_dv || txdatflit == m_df))
  `SVA_INV(a_events, ev_err == m_err && ev_proto == m_pro)
  `SVA_RST(a_reset, !rst_n, !rxreqlcrdv && !rxdatlcrdv && !txrspflitv && !txdatflitv && !ev_err && !ev_proto)

  // ---------------- functional coverage ----------------
  function automatic int dcls(input logic [127:0] v);
    return v == 128'd0 ? 0 : v == '1 ? 1 : (v == {64{2'b01}} || v == {64{2'b10}}) ? 2 : 3;
  endfunction
  covergroup cg_chi @(negedge clk);
    option.per_instance = 1;
    cp_req: coverpoint c_qk iff (rst_n && c_qv)
      { bins write_ptl = {0}; bins write_full = {1}; bins unsupported = {2}; bins read = {3}; }
    cp_range: coverpoint c_qin iff (rst_n && c_qv) { bins in_range = {1}; bins out_of_range = {0}; }
    x_req: cross cp_req, cp_range { ignore_bins na = binsof(cp_req.unsupported); }
    cp_rline: coverpoint c_qln iff (rst_n && c_qv && c_qk == 3 && c_qin) { bins l[] = {[0:LINES-1]}; }
    cp_wline: coverpoint c_qln iff (rst_n && c_qv && c_qk < 2 && c_qin) { bins l[] = {[0:LINES-1]}; }
    cp_wid: coverpoint c_wid iff (rst_n && c_wv) { bins d[] = {[0:3]}; }
    cp_wdata: coverpoint dcls(c_wd) iff (rst_n && c_wv)
      { bins zero = {0}; bins ones = {1}; bins alt = {2}; bins other = {3}; }
    cp_rid: coverpoint c_did iff (rst_n && c_dv) { bins d[] = {[0:3]}; }
    cp_rdata: coverpoint dcls(c_rd) iff (rst_n && c_dv)
      { bins zero = {0}; bins ones = {1}; bins alt = {2}; bins other = {3}; }
  endgroup
  cg_chi u_cg_chi = new;

  `FC(read_size_0, v_rd_size[0])
  `FC(read_size_4, v_rd_size[4])
  `FC(read_size_5, v_rd_size[5])
  `FC(read_size_6, v_rd_size[6])
  `FC(read_size_7_nderr, v_rd_size[7])
  `FC(write_ptl_size_0, v_wr_size[0])
  `FC(write_ptl_size_5, v_wr_size[5])
  `FC(write_size_6, v_wr_size[6])
  `FC(read_receipt, v_rcpt)
  `FC(write_full, v_full)
  `FC(write_full_bad_size, v_full_badsize)
  `FC(unsupported_opcode, v_unsup)
  `FC(read_derr, v_derr_rd)
  `FC(write_derr, v_derr_wr)
  `FC(comp_before_head, v_comp_first)
  `FC(both_comps_owed, v_both_comp)
  `FC(write_buffers_full, v_both_busy)
  `FC(data_interleaved, v_interleave)
  `FC(byte_enables_partial, v_be_part)
  `FC(byte_enables_none, v_be_none)
  `FC(data_bad_opcode, v_bad_op)
  `FC(data_bad_dbid, v_bad_dbid)
  `FC(data_dataid_not_expected, v_bad_id)
  `FC(data_dataid_twice, v_dup_id)
  `FC(request_without_credit, v_nocrd_req)
  `FC(data_without_credit, v_nocrd_dat)
  `FC(rsp_credits_at_15, v_cr15)
  `FC(rsp_waits_for_credit, v_rsp_starve)
  `FC(dat_waits_for_credit, v_dat_starve)
  `FC(request_slots_full, v_q_full)
  `FC_RST(reset_in_read_data, rst_n && bt != 0 ##1 !rst_n)
endmodule

bind CHI_top CHI_sva #(.LINES(LINES), .RQ(RQ), .NDC(NDC)) u_sva (.*);
