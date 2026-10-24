// SPDX-License-Identifier: Apache-2.0
// USB4 transport layer: concurrent SVA against an independent reference
// model, plus functional coverage.
//  * Transmit: the model keeps each path's written packet as a byte queue,
//    picks the next packet when the last one is out (Idle lead, grants,
//    then data by round robin), builds all its bytes at once (its own HEC,
//    padding and grant payload) and the line must carry them one per clock.
//  * Receive: the model collects 4 header bytes or a whole payload and
//    judges them whole. Delineation hunts on its own byte history; a header
//    in SYNC is corrected by trying every single-bit flip (not a syndrome
//    table). Packets go into per-path queues of byte queues, with an arrival
//    order queue, that rx_* must show.
//  * Credit grants update the model's credit limits; its own counters decide
//    the grants it sends.
// Every output is compared on every clock.
`include "cov_macros.svh"
module USB4_sva #(
  parameter int MAXL = 32, RXB = 2, DELTA = 4, REFRESH = 128
)(
  input logic        clk, rst_n, link_up,
  input logic [7:0]  tx_sym, rx_sym,
  input logic [1:0]  path_en,
  input logic [10:0] hop_tx0, hop_tx1, hop_rx0, hop_rx1,
  input logic        tx_valid, tx_ready,
  input logic [7:0]  tx_data,
  input logic        tx_last, tx_path,
  input logic        rx_valid, rx_ready,
  input logic [7:0]  rx_data,
  input logic        rx_last, rx_path, sync,
  input logic [1:0]  path_up,
  input logic        ev_hec_fix, ev_hec_bad, ev_proto, ev_hop, ev_len, ev_overflow
);
  `COV_CLOCKING(clk, !rst_n)
  typedef logic [7:0] bq_t [$];
  localparam int LEAD = 2 * DELTA;

  function automatic logic [31:0] mkh(input int pdf, input int hop, input int len);
    logic [23:0] d;
    logic [7:0]  c;
    d = {4'(pdf), 1'b0, 11'(hop), 8'(len)};
    c = 0;
    for (int i = 23; i >= 0; i--) begin
      bit fb;
      fb = c[7] ^ d[i];
      c = c << 1;
      if (fb) c ^= 8'h07;
    end
    return {d, c ^ 8'h55};
  endfunction
  // a header's HEC covers bits 31:8 (SuppID too)
  function automatic bit good(input logic [31:0] w);
    logic [7:0] c;
    c = 0;
    for (int i = 31; i >= 8; i--) begin
      bit fb;
      fb = c[7] ^ w[i];
      c = c << 1;
      if (fb) c ^= 8'h07;
    end
    return (c ^ 8'h55) == w[7:0];
  endfunction
  function automatic int pad(input int l);
    return (l + 3) / 4 * 4;
  endfunction

  // ---------------- model state ----------------
  // transmit
  bq_t    buff [0:1];                    // a written packet per path (full when not empty)
  bq_t    wb [0:1];                      // packets being written
  logic [7:0] ts [$];                    // bytes of the packet being sent still to go
  int     t_kind, t_path, lead, rr;
  bit     t_on;
  int     snt [0:1], lmt [0:1];
  bit     pup [0:1];
  logic [7:0] m_sym;
  // receive
  int     dst, dc, rleft, rm, rp, rlen;   // dst: 0 HUNT, 1 PRESYNC, 2 SYNC; rm: 0 skip, 1 data, 2 grant
  logic [7:0] hist [$];                  // HUNT: the last bytes
  logic [7:0] hb [$], pb [$];            // a header, a payload so far
  bq_t    rq [0:1][$];                   // packets per path
  int     ord [$];                       // their paths in arrival order
  int     rgot, adv [0:1], gtm;
  bit     gq [0:1];                      // grants to send
  bit     m_fix, m_bad, m_pro, m_hop, m_len, m_ovf;
  // coverage
  bit v_cut, v_pad [0:3], v_maxl, v_switch, v_rr, v_credit_wait, v_up_wait, v_disabled_wait, v_drop_data, v_drop_grant;
  bit v_grant_refresh, v_grant_read, v_false_lock, v_pre_bad, v_fix_hec, v_fix_hdr, v_hunt_lost;
  bit v_pro_pdf, v_pro_idle, v_pro_glen, v_g_res, v_g_mid, v_g_hop, v_g_over, v_g_same, v_g_dup, v_g_disabled;
  bit v_hop_unknown, v_hop_disabled, v_len0, v_len_long, v_len_255, v_ovf_other, v_rx_same, v_drop_rx, v_full_read;
  bit v_both_paths_rx, v_grant_while_data;
  // per-step copies for the covergroup (set at posedge, sampled at negedge)
  bit c_dv, c_dp, c_rv, c_rp, c_gv, c_gp;
  int c_dn, c_rn;
  logic [7:0] c_db, c_rb;

  always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      for (int p = 0; p < 2; p++) begin
        buff[p].delete(); wb[p].delete(); snt[p] = 0; lmt[p] = 0; pup[p] = 0; rq[p].delete(); adv[p] = RXB;
        gq[p] = 1;
      end
      ts.delete(); t_kind = 0; t_path = 0; lead = 0; rr = 0; t_on = 0; m_sym = 0;
      dst = 0; dc = 0; rleft = 0; rm = 0; rp = 0; rlen = 0; hist.delete(); hb.delete(); pb.delete();
      for (int i = 0; i < 4; i++) hist.push_back(8'h00);
      ord.delete(); rgot = 0; gtm = 0;
      {m_fix, m_bad, m_pro, m_hop, m_len, m_ovf} = '0;
    end else begin : b_step
      int o_snt [0:1], o_lmt [0:1], o_adv [0:1], o_occ [0:1], o_dst, o_gtm;
      bit o_pup [0:1], o_gq [0:1], o_full [0:1], fr [0:1], put [0:1], gsent [0:1];
      for (int p = 0; p < 2; p++) begin
        o_snt[p] = snt[p]; o_lmt[p] = lmt[p]; o_pup[p] = pup[p]; o_adv[p] = adv[p]; o_occ[p] = rq[p].size();
        o_gq[p] = gq[p]; o_full[p] = buff[p].size() != 0; fr[p] = 0; put[p] = 0; gsent[p] = 0;
      end
      o_dst = dst; o_gtm = gtm;
      {m_fix, m_bad, m_pro, m_hop, m_len, m_ovf} = '0;
      {c_dv, c_rv, c_gv} = '0;

      // ---- transmit
      if (!link_up) begin
        if (t_on && t_kind == 2) v_drop_data = 1;
        if (t_on && t_kind == 1) v_drop_grant = 1;
        m_sym = 0; ts.delete(); t_on = 0; lead = 0;
        for (int p = 0; p < 2; p++) begin snt[p] = 0; lmt[p] = 0; pup[p] = 0; end
      end else if (ts.size() != 0) m_sym = ts.pop_front();
      else begin : b_pick
        bit c [0:1];
        logic [31:0] h;
        int dp;
        // the last packet is out: its buffer is free
        if (t_on && t_kind == 2) buff[t_path].delete();
        for (int p = 0; p < 2; p++)
          c[p] = buff[p].size() != 0 && path_en[p] && o_pup[p] && o_lmt[p] != o_snt[p];
        dp = c[rr] ? rr : c[1 - rr] ? 1 - rr : -1;
        t_on = 1;
        if (lead != LEAD) begin
          lead++; t_kind = 0; h = mkh(0, 0, 0);
        end else if ((o_gq[0] && path_en[0] || o_gq[1] && path_en[1]) && o_dst == 2) begin
          logic [10:0] hp;
          t_kind = 1; t_path = o_gq[0] && path_en[0] ? 0 : 1; gsent[t_path] = 1;
          c_gv = 1; c_gp = t_path;
          hp = t_path ? hop_rx1 : hop_rx0;
          h = mkh(1, 0, 4);
          ts.push_back({5'd0, hp[10:8]}); ts.push_back(hp[7:0]); ts.push_back(8'h00); ts.push_back(8'(o_adv[t_path]));
          if (dp >= 0) v_grant_while_data = 1;
        end else if (dp >= 0) begin
          int n;
          if (c[0] && c[1]) v_rr = 1;
          t_kind = 2; t_path = dp; rr = 1 - dp; snt[dp] = (o_snt[dp] + 1) & 255;
          n = buff[dp].size();
          c_dv = 1; c_dp = dp; c_dn = n; c_db = buff[dp][n - 1];
          h = mkh(0, dp ? hop_tx1 : hop_tx0, n);
          for (int i = 0; i < pad(n); i++) ts.push_back(i < n ? buff[dp][i] : 8'h00);
          v_pad[n % 4] = 1;
          if (n == MAXL) v_maxl = 1;
        end else begin
          t_kind = 0; h = mkh(0, 0, 0);
          for (int p = 0; p < 2; p++) if (buff[p].size() != 0) begin
            if (!path_en[p]) v_disabled_wait = 1;
            else if (!o_pup[p]) v_up_wait = 1;
            else v_credit_wait = 1;
          end
        end
        m_sym = h[31:24];
        for (int i = 0; i < 3; i++) ts.push_front(h[8 * i +: 8]);
      end
      // ---- writing
      if (tx_valid && !o_full[tx_path]) begin
        if (wb[1 - tx_path].size() != 0) v_switch = 1;
        wb[tx_path].push_back(tx_data);
        if (tx_last || wb[tx_path].size() == MAXL) begin
          if (!tx_last) v_cut = 1;
          buff[tx_path] = wb[tx_path]; wb[tx_path].delete();
        end
      end

      // ---- receive (hist: the last 4 bytes since the link came up, zeros
      // before)
      if (link_up) begin
        hist.push_back(rx_sym);
        if (hist.size() > 4) void'(hist.pop_front());
      end
      if (!link_up) begin
        if (rm == 1 && dst != 0) v_drop_rx = 1;
        dst = 0; hist.delete(); hb.delete(); pb.delete(); rleft = 0; rm = 0;
        for (int i = 0; i < 4; i++) hist.push_back(8'h00);
      end else if (dst == 0) begin
        logic [31:0] w;
        w = {hist[0], hist[1], hist[2], hist[3]};
        if (good(w)) begin
          dst = 1; dc = 1; rm = 0; rleft = pad(w[15:8]); hb.delete(); pb.delete();
        end
      end else if (rleft != 0) begin
        pb.push_back(rx_sym);
        rleft--;
        if (rleft == 0) begin
          if (rm == 1) begin
            bq_t t;
            t.delete();
            for (int i = 0; i < rlen; i++) t.push_back(pb[i]);
            rq[rp].push_back(t); ord.push_back(rp); put[rp] = 1;
            c_rv = 1; c_rp = rp; c_rn = rlen; c_rb = t[rlen - 1];
          end else if (rm == 2) begin : b_grant
            int q, d;
            bit m0, m1;
            m0 = path_en[0] && {pb[0][2:0], pb[1]} == hop_tx0 && hop_tx0 != 0;
            m1 = path_en[1] && {pb[0][2:0], pb[1]} == hop_tx1 && hop_tx1 != 0;
            q = m0 ? 0 : 1;
            d = (pb[3] - o_snt[q]) & 255;
            if (m0 && m1) v_g_same = 1;
            if (pb[0][7:3] != 0) begin m_pro = 1; v_g_res = 1; end
            else if (pb[2] != 0) begin m_pro = 1; v_g_mid = 1; end
            else if (!(m0 || m1)) begin
              m_pro = 1;
              if ({pb[0][2:0], pb[1]} == hop_tx0 && hop_tx0 != 0 || {pb[0][2:0], pb[1]} == hop_tx1 && hop_tx1 != 0)
                v_g_disabled = 1;
              else v_g_hop = 1;
            end else if (d > RXB) begin m_pro = 1; v_g_over = 1; end
            else begin
              if (pb[3] == o_lmt[q] && o_pup[q]) v_g_dup = 1;
              lmt[q] = pb[3]; pup[q] = 1;
            end
          end
          pb.delete(); rm = 0;
        end
      end else begin
        hb.push_back(rx_sym);
        if (hb.size() == 4) begin : b_hdr
          logic [31:0] w, h;
          bit ok, fx;
          w = {hb[0], hb[1], hb[2], hb[3]};
          hb.delete();
          ok = good(w); fx = 0; h = w;
          if (!ok && dst == 2)
            for (int i = 0; i < 32; i++) if (good(w ^ (32'd1 << i))) begin fx = 1; h = w ^ (32'd1 << i); end
          if (!ok && !fx) begin
            if (dst == 2) begin m_bad = 1; v_hunt_lost = 1; end
            else v_pre_bad = 1;
            if (dst == 1 && dc == 1) v_false_lock = 1;
            dst = 0;
          end else begin
            rleft = pad(h[15:8]); rm = 0;
            if (dst == 1) begin
              dc++;
              if (dc == DELTA) dst = 2;
            end else begin
              if (fx) begin m_fix = 1; if ((h ^ w) & 32'hFF) v_fix_hec = 1; else v_fix_hdr = 1; end
              if (h[26:16] == 0) begin
                if (h[31:28] == 1 && h[15:8] == 4) rm = 2;
                else if (!(h[31:28] == 0 && h[15:8] == 0)) begin
                  m_pro = 1;
                  if (h[31:28] == 0) v_pro_idle = 1; else if (h[31:28] == 1) v_pro_glen = 1; else v_pro_pdf = 1;
                end
              end else if (!(path_en[0] && h[26:16] == hop_rx0) && !(path_en[1] && h[26:16] == hop_rx1)) begin
                m_hop = 1;
                if (h[26:16] == hop_rx0 || h[26:16] == hop_rx1) v_hop_disabled = 1; else v_hop_unknown = 1;
              end else begin
                int q;
                q = path_en[0] && h[26:16] == hop_rx0 ? 0 : 1;
                if (path_en[0] && path_en[1] && hop_rx0 == hop_rx1) v_rx_same = 1;
                if (h[15:8] == 0 || h[15:8] > MAXL) begin
                  m_len = 1;
                  if (h[15:8] == 0) v_len0 = 1; else v_len_long = 1;
                  if (pad(h[15:8]) == 256) v_len_255 = 1;
                end else if (o_occ[q] == RXB) begin
                  m_ovf = 1;
                  if (o_occ[1 - q] < RXB) v_ovf_other = 1;
                end else begin rm = 1; rp = q; rlen = h[15:8]; end
              end
            end
          end
        end
      end
      // ---- reading
      if (rx_valid && rx_ready && ord.size() != 0) begin
        int p;
        p = ord[0];
        rgot++;
        if (rgot == rq[p][0].size()) begin
          if (o_occ[p] == RXB) v_full_read = 1;
          void'(rq[p].pop_front()); void'(ord.pop_front()); rgot = 0; fr[p] = 1;
        end
      end
      if (rq[0].size() != 0 && rq[1].size() != 0) v_both_paths_rx = 1;
      // ---- credits and grants
      for (int p = 0; p < 2; p++) begin
        if (!link_up) adv[p] = RXB - rq[p].size();
        else if (fr[p]) begin adv[p] = (o_adv[p] + 1) & 255; v_grant_read = 1; end
      end
      for (int p = 0; p < 2; p++) gq[p] = o_gq[p] && !gsent[p] || fr[p];
      if (!link_up || o_dst == 2 && o_gtm == 0) begin
        if (link_up && o_dst == 2 && (gq[0] == 0 || gq[1] == 0)) v_grant_refresh = 1;
        gq[0] = 1; gq[1] = 1;
      end
      if (link_up && o_dst == 2) gtm = (o_gtm + 1) % REFRESH;
      else gtm = 0;
    end
  end

  // ---------------- assertions ----------------
  `SVA_INV(a_tx_sym, tx_sym == m_sym)
  `SVA_INV(a_tx_ready, tx_ready == (buff[tx_path].size() == 0))
  `SVA_INV(a_status, sync == (dst == 2) && path_up == {pup[1], pup[0]})
  `SVA_INV(a_rx_valid, rx_valid == (ord.size() != 0))
  `SVA_IMP(a_rx_byte, ord.size() != 0, rx_path == ord[0] && rx_data == rq[ord[0]][0][rgot] &&
                                       rx_last == (rgot == rq[ord[0]][0].size() - 1))
  `SVA_INV(a_events, {ev_hec_fix, ev_hec_bad, ev_proto, ev_hop, ev_len, ev_overflow} ==
                     {m_fix, m_bad, m_pro, m_hop, m_len, m_ovf})
  `SVA_RST(a_reset, 1'b1, tx_sym == 8'h00 && !rx_valid && !sync && path_up == 2'b00 && tx_ready)

  // ---------------- functional coverage ----------------
  function automatic int dcls(input logic [7:0] v);
    return v == 8'h00 ? 0 : v == 8'hFF ? 1 : (v == 8'h55 || v == 8'hAA) ? 2 : 3;
  endfunction
  covergroup cg_usb4 @(negedge clk);
    option.per_instance = 1;
    cp_tpath: coverpoint c_dp iff (rst_n && c_dv) { bins p[] = {0, 1}; }
    cp_tlen: coverpoint c_dn iff (rst_n && c_dv)
      { bins one = {1}; bins short_ = {[2:3]}; bins mid = {[4:MAXL-1]}; bins maxl = {MAXL}; }
    x_tx: cross cp_tpath, cp_tlen;
    cp_tdata: coverpoint dcls(c_db) iff (rst_n && c_dv)
      { bins zero = {0}; bins ones = {1}; bins alt = {2}; bins other = {3}; }
    cp_rpath: coverpoint c_rp iff (rst_n && c_rv) { bins p[] = {0, 1}; }
    cp_rlen: coverpoint c_rn iff (rst_n && c_rv)
      { bins one = {1}; bins short_ = {[2:3]}; bins mid = {[4:MAXL-1]}; bins maxl = {MAXL}; }
    x_rx: cross cp_rpath, cp_rlen;
    cp_rdata: coverpoint dcls(c_rb) iff (rst_n && c_rv)
      { bins zero = {0}; bins ones = {1}; bins alt = {2}; bins other = {3}; }
    cp_grant: coverpoint c_gp iff (rst_n && c_gv) { bins p[] = {0, 1}; }
  endgroup
  cg_usb4 u_cg_usb4 = new;

  `FC(write_cut_at_maxl, v_cut)
  `FC(write_paths_interleaved, v_switch)
  `FC(data_len_mod4_0, v_pad[0])
  `FC(data_len_mod4_1, v_pad[1])
  `FC(data_len_mod4_2, v_pad[2])
  `FC(data_len_mod4_3, v_pad[3])
  `FC(data_len_maxl, v_maxl)
  `FC(round_robin_both_ready, v_rr)
  `FC(grant_before_data, v_grant_while_data)
  `FC(wait_for_credit, v_credit_wait)
  `FC(wait_for_first_grant, v_up_wait)
  `FC(wait_on_disabled_path, v_disabled_wait)
  `FC(link_drop_in_data, v_drop_data)
  `FC(link_drop_in_grant, v_drop_grant)
  `FC(link_drop_in_rx_data, v_drop_rx)
  `FC(grant_on_read, v_grant_read)
  `FC(grant_refresh, v_grant_refresh)
  `FC(grant_duplicate, v_g_dup)
  `FC(grant_reserved_bits, v_g_res)
  `FC(grant_middle_byte, v_g_mid)
  `FC(grant_unknown_hop, v_g_hop)
  `FC(grant_disabled_path, v_g_disabled)
  `FC(grant_over_rxb, v_g_over)
  `FC(grant_same_hop_both_paths, v_g_same)
  `FC(hunt_false_lock, v_false_lock)
  `FC(presync_bad_header, v_pre_bad)
  `FC(sync_reached, sync)
  `FC(fix_hec_bit, v_fix_hec)
  `FC(fix_header_bit, v_fix_hdr)
  `FC(sync_lost, v_hunt_lost)
  `FC(proto_pdf, v_pro_pdf)
  `FC(proto_idle_len, v_pro_idle)
  `FC(proto_grant_len, v_pro_glen)
  `FC(hop_unknown, v_hop_unknown)
  `FC(hop_disabled, v_hop_disabled)
  `FC(rx_same_hop_both_paths, v_rx_same)
  `FC(len_zero, v_len0)
  `FC(len_over_maxl, v_len_long)
  `FC(len_skip_256, v_len_255)
  `FC(overflow, ev_overflow)
  `FC(overflow_other_path_free, v_ovf_other)
  `FC(rx_full_read, v_full_read)
  `FC(rx_both_paths_queued, v_both_paths_rx)
  `FC(both_paths_up, path_up == 2'b11)
  `FC_RST(reset_while_up, rst_n && sync ##1 !rst_n)
endmodule

bind USB4_top USB4_sva #(.MAXL(MAXL), .RXB(RXB), .DELTA(DELTA), .REFRESH(REFRESH)) u_sva (.*);
