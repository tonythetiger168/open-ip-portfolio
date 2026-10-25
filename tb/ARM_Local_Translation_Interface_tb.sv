// SPDX-License-Identifier: Apache-2.0
// ARM_Local_Translation_Interface_top testbench: a TB manager on LA / LR /
// LC and a TB host on the table and invalidation ports.
//  - the manager opens the link, counts its credits, sends requests (hits,
//    misses, every permission case, substream and any-substream entries)
//    and returns each context tag on LC after a random delay, or holds
//    them all so responses wait for a free tag
//  - every response is checked in order against a reference table (the
//    table as it stood when the response was decided); tags must be free
//    when handed out
//  - the host rewrites entries under traffic and invalidates (all, by
//    StreamID) under traffic; inv_done is checked against the tags out
//    when the invalidation was taken
//  - link closed and opened again with tags out and requests queued; a
//    request without a credit, a tag returned that is not out; reset with
//    traffic in flight
// The bound checker (tb/cov/ARM_Local_Translation_Interface_sva.sv) checks
// every output on every clock against its own model.
`timescale 1ns/1ps
module ARM_Local_Translation_Interface_tb;
  localparam int NE = 8, RQ = 4, NCT = 8;
  logic clk = 0, rst_n = 0;
  always #5 clk = ~clk;
  int errors = 0;
  task automatic fail(input string s);
    errors++;
    $display("ERROR: %s @%0t", s, $time);
  endtask
  task automatic wait_clk(input int n); repeat (n) @(negedge clk); endtask

  logic        lm_open_req = 0, la_valid = 0, la_ssidv = 0, la_instr = 0, la_priv = 0, lc_valid = 0;
  logic [3:0]  la_id = 0;
  logic [19:0] la_va = 0;
  logic [7:0]  la_sid = 0, la_ssid = 0;
  logic [1:0]  la_rw = 0;
  logic [2:0]  lc_ctag = 0;
  logic        cfg_we = 0, cfg_v = 0, cfg_ssidv = 0, inv_valid = 0, inv_all = 0;
  logic [2:0]  cfg_idx = 0;
  logic [7:0]  cfg_sid = 0, cfg_ssid = 0, cfg_attr = 0, inv_sid = 0;
  logic [19:0] cfg_va = 0, cfg_pa = 0;
  logic [3:0]  cfg_perm = 0;
  wire         lm_open_ack, la_credit, lr_valid, inv_ready, inv_done, ev_fault, ev_proto;
  wire  [3:0]  lr_id;
  wire  [1:0]  lr_resp;
  wire  [19:0] lr_pa;
  wire  [7:0]  lr_attr;
  wire  [2:0]  lr_ctag;
  wire  [3:0]  ctags_out;
  ARM_Local_Translation_Interface_top #(.NE(NE), .RQ(RQ), .NCT(NCT)) dut (.*);

  // ---------------- reference table: now, and as of the clock before ----------------
  bit          t_v [0:NE-1], t_ssidv [0:NE-1], p_v [0:NE-1], p_ssidv [0:NE-1];
  logic [7:0]  t_sid [0:NE-1], t_ssid [0:NE-1], t_attr [0:NE-1], p_sid [0:NE-1], p_ssid [0:NE-1], p_attr [0:NE-1];
  logic [19:0] t_va [0:NE-1], t_pa [0:NE-1], p_va [0:NE-1], p_pa [0:NE-1];
  logic [3:0]  t_perm [0:NE-1], p_perm [0:NE-1];
  initial for (int i = 0; i < NE; i++) begin
    t_v[i] = 0; t_ssidv[i] = 0; t_sid[i] = 0; t_ssid[i] = 0; t_attr[i] = 0; t_va[i] = 0; t_pa[i] = 0; t_perm[i] = 0;
  end

  // ---------------- manager ----------------
  int          m_cr = 0, n_req = 0, n_rsp = 0, n_ok = 0, n_tf = 0, n_pf = 0;
  logic [44:0] mq [$];                           // requests sent, in order
  bit          t_out [0:NCT-1];
  int          lc_due [0:NCT-1];
  int          p_req = 60, p_lc = 100, lc_max = 30;
  int          now = 0;
  int          n_fault = 0, n_proto = 0, x_proto = 0;
  bit          hold_lc = 0;
  // invalidations waiting: tags that must come back first
  bit          s_tag [0:NCT-1];
  bit          s_on = 0, s_snap = 0;
  initial for (int i = 0; i < NCT; i++) begin t_out[i] = 0; lc_due[i] = 0; s_tag[i] = 0; end
  always @(posedge clk) now++;

  task automatic expect_rsp(input logic [44:0] r, output logic [1:0] resp, output logic [19:0] pa, output logic [7:0] at);
    int k;
    logic [3:0] p;
    k = -1;
    for (int i = NE - 1; i >= 0; i--)
      if (p_v[i] && p_sid[i] == r[20:13] && p_va[i] == r[40:21] && (!p_ssidv[i] || r[4] && p_ssid[i] == r[12:5]))
        k = i;
    resp = 1; pa = 0; at = 0;
    if (k >= 0) begin
      p = p_perm[k];
      if ((r[2] && !p[0]) || (r[3] && !p[1]) || (r[1] && !p[2]) || (!r[0] && !p[3])) resp = 2;
      else begin resp = 0; pa = p_pa[k]; at = p_attr[k]; end
    end
  endtask

  always @(posedge clk) if (!rst_n) begin
    m_cr = 0;
  end else begin : b_mon
    logic [44:0] r;
    logic [1:0]  e_resp;
    logic [19:0] e_pa;
    logic [7:0]  e_at;
    if (la_credit) m_cr++;
    if (ev_fault) n_fault++;
    if (ev_proto) n_proto++;
    if (lr_valid) begin
      if (mq.size() == 0) fail("response with no request");
      else begin
        r = mq.pop_front();
        expect_rsp(r, e_resp, e_pa, e_at);
        if (lr_id != r[44:41] || lr_resp != e_resp || lr_pa != e_pa || lr_attr != e_at)
          fail($sformatf("LR id %h resp %0d pa %h attr %h, expected id %h resp %0d pa %h attr %h",
                         lr_id, lr_resp, lr_pa, lr_attr, r[44:41], e_resp, e_pa, e_at));
        if (e_resp == 0) begin
          if (t_out[lr_ctag]) fail($sformatf("tag %0d handed out while out", lr_ctag));
          t_out[lr_ctag] = 1;
          lc_due[lr_ctag] = now + 1 + $urandom % lc_max;
          n_ok++;
        end else if (e_resp == 1) n_tf++; else n_pf++;
        n_rsp++;
      end
    end
    // an invalidation taken on the last clock: the tags out now must come back
    if (s_snap) begin
      for (int i = 0; i < NCT; i++) s_tag[i] = t_out[i];
      s_snap = 0; s_on = 1;
    end
    if (inv_done) begin
      if (!s_on) fail("inv_done with no invalidation");
      for (int i = 0; i < NCT; i++) if (s_tag[i] && t_out[i]) fail($sformatf("inv_done with tag %0d still out", i));
      s_on = 0;
    end
    if (lc_valid && t_out[lc_ctag]) begin t_out[lc_ctag] = 0; s_tag[lc_ctag] = 0; end
    if (inv_valid && inv_ready) s_snap = 1;
    // the table: as of the clock before, then this clock's writes
    for (int i = 0; i < NE; i++) begin
      p_v[i] = t_v[i]; p_ssidv[i] = t_ssidv[i]; p_sid[i] = t_sid[i]; p_ssid[i] = t_ssid[i];
      p_attr[i] = t_attr[i]; p_va[i] = t_va[i]; p_pa[i] = t_pa[i]; p_perm[i] = t_perm[i];
    end
    if (cfg_we) begin
      t_v[cfg_idx] = cfg_v; t_ssidv[cfg_idx] = cfg_ssidv; t_sid[cfg_idx] = cfg_sid; t_ssid[cfg_idx] = cfg_ssid;
      t_attr[cfg_idx] = cfg_attr; t_va[cfg_idx] = cfg_va; t_pa[cfg_idx] = cfg_pa; t_perm[cfg_idx] = cfg_perm;
    end
    if (inv_valid && inv_ready)
      for (int i = 0; i < NE; i++) if (inv_all || t_sid[i] == inv_sid) t_v[i] = 0;
  end

  // requests: {id, va, sid, ssid, ssidv, rw, instr, priv}
  bit req_on = 0, force_nocrd = 0;
  bit go_req = 0;                                         // one request now: StreamID go_sid, page go_va
  logic [7:0] go_sid = 0;
  logic [19:0] go_va = 0;
  int va_max = 18, sid_max = 5, ssid_max = 3;
  bit wide = 0;                                           // full-width table values
  always @(negedge clk) begin
    la_valid = 0;
    {la_id, la_va, la_sid, la_ssid, la_ssidv, la_rw, la_instr, la_priv} = {$urandom, $urandom};
    if (rst_n && go_req && m_cr > 0) begin
      go_req = 0; la_valid = 1; la_sid = go_sid; la_va = go_va; la_ssidv = 0;
      m_cr--;
      mq.push_back({la_id, la_va, la_sid, la_ssid, la_ssidv, la_rw, la_instr, la_priv});
      n_req++;
    end else if (rst_n && (req_on && m_cr > 0 && $urandom % 100 < p_req || force_nocrd)) begin
      la_valid = 1;
      la_va = $urandom % va_max; la_sid = $urandom % sid_max; la_ssid = $urandom % ssid_max;
      if ($urandom % 100 < 75) begin : b_hit                // mostly an entry's StreamID and page
        int i;
        i = $urandom % NE;
        la_sid = t_sid[i]; la_va = t_va[i];
        if (t_ssidv[i] && $urandom % 5 != 0) begin la_ssidv = 1; la_ssid = t_ssid[i]; end
      end
      if (force_nocrd) begin force_nocrd = 0; x_proto++; end
      else begin
        m_cr--;
        mq.push_back({la_id, la_va, la_sid, la_ssid, la_ssidv, la_rw, la_instr, la_priv});
        n_req++;
      end
    end
  end
  // completions
  bit bad_lc = 0;
  int lc_now = -1;                                        // return this tag now, held or not
  always @(negedge clk) begin : b_lc
    int k;
    lc_valid = 0; lc_ctag = $urandom; k = -1;
    for (int i = 0; i < NCT; i++) if (t_out[i] && lc_due[i] <= now && k < 0) k = i;
    if (rst_n && lc_now >= 0) begin
      lc_valid = 1; lc_ctag = lc_now; lc_now = -1;
    end else if (rst_n && bad_lc) begin
      bad_lc = 0;
      for (int i = 0; i < NCT; i++) if (!t_out[i]) k = i;
      lc_valid = 1; lc_ctag = k; x_proto++;
    end else if (rst_n && !hold_lc && k >= 0 && $urandom % 100 < p_lc) begin
      lc_valid = 1; lc_ctag = k;
    end
  end

  // ---------------- host ----------------
  task automatic set_entry(input int i, input bit v, input int sid, input bit ssidv, input int ssid, input int va, input int perm);
    @(negedge clk);
    cfg_we = 1; cfg_idx = i; cfg_v = v; cfg_sid = sid; cfg_ssidv = ssidv; cfg_ssid = ssid; cfg_va = va;
    cfg_pa = $urandom; cfg_perm = perm; cfg_attr = $urandom;
    @(negedge clk);
    cfg_we = 0; {cfg_idx, cfg_v, cfg_sid, cfg_ssidv, cfg_ssid, cfg_va, cfg_pa, cfg_perm, cfg_attr} = {$urandom, $urandom, $urandom};
  endtask
  task automatic rnd_entry(input int i);
    if (wide) set_entry(i, $urandom % 8 != 0, $urandom, $urandom % 2, $urandom, $urandom, $urandom);
    else set_entry(i, $urandom % 8 != 0, $urandom % 4, $urandom % 3 == 0, $urandom % 3, $urandom % 16, $urandom);
  endtask
  task automatic inval(input bit all, input int sid);
    @(negedge clk);
    while (!inv_ready) @(negedge clk);
    inv_valid = 1; inv_all = all; inv_sid = sid;
    @(negedge clk);
    inv_valid = 0; inv_all = $urandom; inv_sid = $urandom;
  endtask

  task automatic drain(input string ph);
    int t;
    t = 0;
    while ((mq.size() != 0 || ctags_out != 0 || s_on || s_snap) && t < 20000) begin @(negedge clk); t++; end
    if (t == 20000) fail($sformatf("%s: stuck (%0d requests, %0d tags out)", ph, mq.size(), ctags_out));
    wait_clk(5);
    if (n_proto != x_proto) fail($sformatf("%s: ev_proto %0d, expected %0d", ph, n_proto, x_proto));
    if (n_fault != n_tf + n_pf) fail($sformatf("%s: ev_fault %0d, faults %0d", ph, n_fault, n_tf + n_pf));
    $display("%s: %0d requests, %0d OK, %0d translation faults, %0d permission faults", ph, n_req, n_ok, n_tf, n_pf);
  endtask

  // invalidations taken in the clock a tag goes out or comes back, one
  // held while another waits, the link closed with a request still queued
  // or arriving
  // flags for the driver blocks are set between a rising and a falling
  // edge, so they act on the falling edge that follows
  task automatic one_tag;                                 // an OK request (entry 1) on this falling edge
    @(posedge clk);
    go_sid = 1; go_va = 1; go_req = 1;
    @(negedge clk);
  endtask
  task automatic tag_out(input int n);
    while (ctags_out != n) @(negedge clk);
    wait_clk(2);
  endtask
  task automatic directed;
    wait_clk(5);
    // the first tag goes out in the clock the invalidation is taken
    one_tag();
    @(negedge clk);
    inv_valid = 1; inv_all = 0; inv_sid = 8'h77;
    @(negedge clk);
    inv_valid = 0;
    drain("invalidation with the first tag");
    // two tags out; a third goes out with the invalidation and stays out
    hold_lc = 1;
    one_tag(); tag_out(1);
    one_tag(); tag_out(2);
    one_tag();
    @(negedge clk);
    inv_valid = 1;
    @(negedge clk);
    inv_valid = 0;
    tag_out(3);
    @(posedge clk); lc_now = 0; wait_clk(2);
    @(posedge clk); lc_now = 1; wait_clk(10);
    if (!s_on) fail("invalidation done with the tag handed out with it still out");
    lc_now = 2; wait_clk(3);
    // the last tag comes back in the clock the invalidation is taken
    one_tag(); tag_out(1);
    @(posedge clk);
    lc_now = 0;
    @(negedge clk);
    inv_valid = 1;
    @(negedge clk);
    inv_valid = 0;
    wait_clk(3);
    // an invalidation held while the one before waits
    one_tag(); tag_out(1);
    inval(0, 8'h77);
    inv_valid = 1; inv_all = 0; inv_sid = 8'h77;
    fork
      begin wait_clk(6); lc_now = 0; end
      begin while (!inv_ready) @(negedge clk); @(negedge clk); inv_valid = 0; end
    join
    hold_lc = 0;
    drain("held invalidation");
    // close with a request still queued, and with one arriving in CLOSING
    @(posedge clk);
    go_sid = 8'hEE; go_va = 0; go_req = 1;
    @(negedge clk);
    lm_open_req = 0;
    while (lm_open_ack) @(negedge clk);
    m_cr = 0;
    lm_open_req = 1;
    while (m_cr != RQ) @(negedge clk);
    wait_clk(2);
    lm_open_req = 0;
    @(posedge clk);
    go_sid = 8'hEE; go_va = 0; go_req = 1;
    @(negedge clk);
    while (lm_open_ack) @(negedge clk);
    m_cr = 0;
    lm_open_req = 1;
    while (m_cr != RQ) @(negedge clk);
    drain("directed");
  endtask

  initial begin
    wait_clk(3);
    rst_n = 1;
    wait_clk(2);
    // a request before the link is open
    force_nocrd = 1;
    wait_clk(3);
    // the table: every permission, substream and any-substream entries
    for (int i = 0; i < NE; i++) set_entry(i, 1, i % 4, i >= 4, i % 3, i, i < 4 ? 15 : $urandom);
    lm_open_req = 1;
    while (!lm_open_ack) @(negedge clk);
    wait_clk(5);
    if (m_cr != RQ) fail($sformatf("%0d credits after open", m_cr));
    req_on = 1;
    wait_clk(500);
    req_on = 0;
    drain("fixed table");
    // random entries and requests, the table rewritten under traffic
    req_on = 1;
    for (int k = 0; k < 60; k++) begin rnd_entry($urandom % NE); wait_clk($urandom % 20); end
    req_on = 0;
    drain("rewrites");
    // full-width StreamIDs, SubstreamIDs and pages; an invalidation with every tag out
    wide = 1; va_max = 1 << 20; sid_max = 256; ssid_max = 256;
    for (int i = 0; i < NE; i++) set_entry(i, 0, 8'hff, 1, 8'hff, 20'hfffff, 15);
    for (int i = 0; i < NE; i++) set_entry(i, 0, 0, 0, 0, 0, 0);
    for (int i = 0; i < NE; i++) rnd_entry(i);
    req_on = 1;
    for (int k = 0; k < 40; k++) begin rnd_entry($urandom % NE); wait_clk($urandom % 20); end
    hold_lc = 1;
    while (ctags_out != NCT) @(negedge clk);
    inval(1, 0);
    hold_lc = 0;
    for (int k = 0; k < 20; k++) begin rnd_entry($urandom % NE); wait_clk($urandom % 20); end
    req_on = 0;
    drain("wide");
    wide = 0; va_max = 18; sid_max = 5; ssid_max = 3;
    p_req = 100; lc_max = 3; req_on = 1;
    wait_clk(500);
    req_on = 0;
    drain("fast");
    // every tag out: responses wait
    hold_lc = 1; req_on = 1;
    wait_clk(200);
    if (ctags_out != NCT) fail("tags not all out");
    hold_lc = 0;
    wait_clk(100);
    req_on = 0; lc_max = 30; p_req = 60;
    drain("tags full");
    // invalidations under traffic
    req_on = 1;
    for (int k = 0; k < 40; k++) begin
      inval($urandom % 4 == 0, $urandom % 5);
      wait_clk($urandom % 30);
      if ($urandom % 2) rnd_entry($urandom % NE);
      if (k % 8 == 0) for (int i = 0; i < NE; i++) rnd_entry(i);
    end
    req_on = 0;
    drain("invalidations");
    // an invalidation with no tag out, and one while a table write lands
    inval(1, 0);
    for (int i = 0; i < NE; i++) rnd_entry(i);
    fork
      inval(0, 2);
      set_entry(2, 1, 2, 0, 0, 3, 15);
    join
    drain("invalidation and write");
    // a tag returned that is not out
    bad_lc = 1;
    wait_clk(3);
    // close with requests queued and tags out, then open again
    for (int i = 0; i < NE; i++) set_entry(i, 1, i % 4, 0, 0, i, 15);
    va_max = 8; sid_max = 4;
    req_on = 1; p_req = 100; hold_lc = 1;
    wait_clk(30);
    req_on = 0;
    lm_open_req = 0;
    wait_clk(20);
    if (!lm_open_ack) fail("link closed with tags out");
    hold_lc = 0;
    while (lm_open_ack) @(negedge clk);
    if (ctags_out != 0) fail("link closed with tags out");
    // the manager still holds credits: they are void
    if (m_cr > 0) begin force_nocrd = 1; m_cr = 0; end
    wait_clk(5);
    lm_open_req = 1;
    while (!lm_open_ack) @(negedge clk);
    req_on = 1; p_req = 60;
    wait_clk(200);
    req_on = 0;
    drain("close and open");
    directed();
    lm_open_req = 0;
    while (lm_open_ack) @(negedge clk);
    m_cr = 0;
    lm_open_req = 1;
    while (!lm_open_ack) @(negedge clk);
    va_max = 18; sid_max = 5;
    // reset with traffic in flight
    req_on = 1; p_req = 100; hold_lc = 0;
    while (!(lr_valid && ctags_out != 0 && dut.rq_n != 0)) @(negedge clk);
    rst_n = 0;
    req_on = 0;
    wait_clk(3);
    mq.delete();
    for (int i = 0; i < NCT; i++) begin t_out[i] = 0; s_tag[i] = 0; end
    for (int i = 0; i < NE; i++) t_v[i] = 0;
    s_on = 0; s_snap = 0; n_proto = 0; x_proto = 0; n_fault = 0; n_tf = 0; n_pf = 0;
    rst_n = 1;
    wait_clk(3);
    for (int i = 0; i < NE; i++) rnd_entry(i);
    while (!lm_open_ack) @(negedge clk);
    req_on = 1;
    wait_clk(200);
    req_on = 0;
    drain("after reset");
    if (errors == 0) $display("TEST PASSED: LTI (%0d requests, %0d responses)", n_req, n_rsp);
    else $display("TEST FAILED: LTI (%0d errors)", errors);
    $finish;
  end

  initial begin
    #10ms;
    $display("TEST FAILED: LTI (timeout)");
    $finish;
  end
endmodule
