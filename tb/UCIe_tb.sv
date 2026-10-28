// SPDX-License-Identifier: Apache-2.0
// UCIe_top testbench: two Adapters (A, B) joined by a TB physical layer:
// a main band with a variable delay that corrupts and drops flits, a
// sideband with its own delay, and phy_up per side (dropped for a few
// clocks on a retrain request).
//  - each side's protocol layer offers payloads for both stacks at a
//    variable rate; the payloads delivered on the far side are checked in
//    order, each exactly once (scoreboards both ways)
//  - bring-up (capability exchange, Active handshake) with every mix of
//    Retry and stack 1; clean link, delays, corrupted and dropped flits,
//    retrain with traffic (also with skewed phy_up), the retrain request
//    after NR replays, L1 entry from either side, crossed requests, PMNAK,
//    L1 exit
//  - Retry off: a corrupted flit takes the receiver to LINKERROR
//  - handshake timeouts, phy_up lost in PARAM, link_en low in every state
//  - the TB takes B's place on A's receive side to send crafted flits and
//    sideband messages (unexpected messages, FinCap mismatch, ACK outside
//    what is outstanding, duplicates, SEQ ahead, Nak, RTY mismatch,
//    stack 1 not negotiated)
//  - reset with traffic in flight
// The bound checker (tb/cov/UCIe_sva.sv) checks every output of both
// Adapters on every clock against its own model.
`timescale 1ns/1ps
module UCIe_tb;
  localparam int RB = 8, TO = 64, NR = 4, HT = 512;
  localparam logic [2:0] RESET = 0, PARAM = 1, ACTREQ = 2, ACTIVE = 3, L1 = 4, RETRAIN = 5, LINKERR = 6;
  logic clk = 0, rst_n = 0;
  always #5 clk = ~clk;
  int errors = 0;
  task automatic fail(input string s);
    errors++;
    $display("ERROR: %s @%0t", s, $time);
  endtask
  task automatic wait_clk(input int n); repeat (n) @(negedge clk); endtask

  function automatic logic [15:0] crc16(input logic [527:0] d);
    logic [15:0] c;
    c = 16'hFFFF;
    for (int i = 527; i >= 0; i--) begin
      if (c[15] ^ d[i]) c = (c << 1) ^ 16'h1021; else c = c << 1;
    end
    return c;
  endfunction
  function automatic logic [511:0] rnd512();
    logic [511:0] r;
    for (int i = 0; i < 16; i++) r[i*32 +: 32] = $urandom;
    return r;
  endfunction

  // ---------------- the two Adapters ----------------
  logic        a_en = 0, b_en = 0, a_rty = 1, b_rty = 1, a_s1 = 1, b_s1 = 1, a_l1ok = 1, b_l1ok = 1, a_pm = 0, b_pm = 0;
  logic        a_phy = 0, b_phy = 0;
  logic        a_tv = 0, b_tv = 0, a_ts = 0, b_ts = 0;
  logic [511:0] a_td = 0, b_td = 0;
  logic        a_lrv = 0, b_lrv = 0, a_sbv = 0, b_sbv = 0;
  logic [543:0] a_lrf = 0, b_lrf = 0;
  logic [15:0] a_sbm = 0, b_sbm = 0;
  wire         a_tr, b_tr, a_rv, b_rv, a_rs, b_rs, a_lpr, b_lpr, a_ltv, b_ltv, a_sbtv, b_sbtv;
  wire [511:0] a_rd, b_rd;
  wire [543:0] a_ltf, b_ltf;
  wire [15:0]  a_sbtm, b_sbtm;
  wire [2:0]   a_st, b_st;
  wire [1:0]   a_cap, b_cap;
  wire [3:0]   a_pend, b_pend;
  wire         a_crc, b_crc, a_rep, b_rep, a_ert, b_ert, a_pmn, b_pmn, a_pro, b_pro, a_ler, b_ler;
  UCIe_top #(.RB(RB), .TO(TO), .NR(NR), .HT(HT)) u_a (
    .clk, .rst_n, .link_en(a_en), .cfg_retry(a_rty), .cfg_stack1(a_s1), .cfg_l1_ok(a_l1ok), .pm_req(a_pm),
    .tx_valid(a_tv), .tx_stack(a_ts), .tx_data(a_td), .tx_ready(a_tr), .rx_valid(a_rv), .rx_stack(a_rs), .rx_data(a_rd),
    .phy_up(a_phy), .lp_retrain(a_lpr), .lt_valid(a_ltv), .lt_flit(a_ltf), .lr_valid(a_lrv), .lr_flit(a_lrf),
    .sb_tx_valid(a_sbtv), .sb_tx_msg(a_sbtm), .sb_rx_valid(a_sbv), .sb_rx_msg(a_sbm),
    .state(a_st), .cap(a_cap), .tx_pend(a_pend), .ev_crc(a_crc), .ev_replay(a_rep), .ev_retrain(a_ert),
    .ev_pmnak(a_pmn), .ev_proto(a_pro), .ev_lerr(a_ler));
  UCIe_top #(.RB(RB), .TO(TO), .NR(NR), .HT(HT)) u_b (
    .clk, .rst_n, .link_en(b_en), .cfg_retry(b_rty), .cfg_stack1(b_s1), .cfg_l1_ok(b_l1ok), .pm_req(b_pm),
    .tx_valid(b_tv), .tx_stack(b_ts), .tx_data(b_td), .tx_ready(b_tr), .rx_valid(b_rv), .rx_stack(b_rs), .rx_data(b_rd),
    .phy_up(b_phy), .lp_retrain(b_lpr), .lt_valid(b_ltv), .lt_flit(b_ltf), .lr_valid(b_lrv), .lr_flit(b_lrf),
    .sb_tx_valid(b_sbtv), .sb_tx_msg(b_sbtm), .sb_rx_valid(b_sbv), .sb_rx_msg(b_sbm),
    .state(b_st), .cap(b_cap), .tx_pend(b_pend), .ev_crc(b_crc), .ev_replay(b_rep), .ev_retrain(b_ert),
    .ev_pmnak(b_pmn), .ev_proto(b_pro), .ev_lerr(b_ler));

  // ---------------- protocol layers ----------------
  int  p_tx = 70, p_stk = 50;
  bit  a_on = 0, b_on = 0;
  bit  lossy = 0;                                // payloads may be lost (Retry off)
  int  pat = -1;                                 // >= 0: payload class (0, all ones, 0x55.., 0xAA..)
  function automatic logic [511:0] pl();
    case (pat)
      0: return '0;
      1: return '1;
      2: return {256{2'b01}};
      3: return {256{2'b10}};
      default: return rnd512();
    endcase
  endfunction
  logic [512:0] sb_ab [$], sb_ba [$];            // {stack, payload} sent, not yet delivered
  int  n_ab = 0, n_ba = 0, n_crc = 0, n_rep = 0, n_lost = 0, n_sdrop = 0;
  // a payload is taken on the rising edge where valid and ready are both high
  always @(posedge clk) if (rst_n) begin
    if (a_tv && a_tr) begin
      if (a_ts && !a_cap[1]) n_sdrop++; else sb_ab.push_back({a_ts, a_td});
      a_tv <= 0;
    end
    if (b_tv && b_tr) begin
      if (b_ts && !b_cap[1]) n_sdrop++; else sb_ba.push_back({b_ts, b_td});
      b_tv <= 0;
    end
  end
  // a delivery checked against the scoreboard of its direction (iverilog
  // takes no queue arguments)
  task automatic check_rx(input bit ab, input logic [512:0] got);
    int k, sz;
    logic [512:0] h;
    k = -1;
    sz = ab ? sb_ab.size() : sb_ba.size();
    for (int i = 0; i < sz; i++) begin
      h = ab ? sb_ab[i] : sb_ba[i];
      if (k < 0 && h === got) k = i;
    end
    h = sz == 0 ? '0 : ab ? sb_ab[0] : sb_ba[0];
    if (sz == 0) fail({ab ? "B" : "A", " delivered a payload never sent"});
    else if (k == 0 || lossy && k > 0) begin
      for (int i = 0; i <= k; i++) if (ab) void'(sb_ab.pop_front()); else void'(sb_ba.pop_front());
      n_lost += k;
      if (ab) n_ab++; else n_ba++;
    end else fail($sformatf("%s delivered %h, expected %h", ab ? "B" : "A", got[63:0], h[63:0]));
  endtask
  always @(negedge clk) if (rst_n) begin
    if (!a_tv && a_on && $urandom % 100 < p_tx) begin a_tv = 1; a_td = pl(); a_ts = $urandom % 100 < p_stk; end
    else if (!a_tv) begin a_td = rnd512(); a_ts = $urandom; end
    if (!b_tv && b_on && $urandom % 100 < p_tx) begin b_tv = 1; b_td = pl(); b_ts = $urandom % 100 < p_stk; end
    else if (!b_tv) begin b_td = rnd512(); b_ts = $urandom; end
    if (b_rv) check_rx(1, {b_rs, b_rd});
    if (a_rv) check_rx(0, {a_rs, a_rd});
    n_crc += int'(a_crc) + int'(b_crc);
    n_rep += int'(a_rep) + int'(b_rep);
  end

  // ---------------- physical layer ----------------
  int  dly = 0, p_cor = 0, p_drop_ab = 0, p_drop_ba = 0;
  int  sdly = 2;
  bit  auto_rt = 1;                               // a retrain request drops phy_up for RT_CLK clocks
  int  n_rt = 0;
  bit  rt_req = 0;
  bit  inj = 0, sinj = 0;                         // the TB drives A's main band / sideband receive side
  bit  cut_rsp_ba = 0;                            // drop B's Rsp.Active on the sideband
  logic        j_v = 0, js_v = 0;
  logic [543:0] j_f = 0;
  logic [15:0] js_m = 0;
  logic [544:0] p_ab [$], p_ba [$];
  logic [16:0] s_ab [$], s_ba [$];
  always @(posedge clk) if (rst_n && auto_rt && (a_lpr || b_lpr)) begin rt_req <= 1; n_rt++; end
  always @(negedge clk) if (rt_req) begin
    rt_req = 0;
    a_phy = 0; b_phy = 0;
    wait_clk(6);
    a_phy = 1; b_phy = 1;
  end
  always @(negedge clk) begin : b_link
    logic [544:0] x;
    logic [16:0]  y;
    if (!rst_n || !a_phy || !b_phy) begin p_ab.delete(); p_ba.delete(); a_lrv = 0; b_lrv = 0; end
    else begin
      p_ab.push_back({a_ltv, a_ltf});
      p_ba.push_back({b_ltv, b_ltf});
      b_lrv = 0; b_lrf = {rnd512(), $urandom};
      if (p_ab.size() > dly) begin
        x = p_ab.pop_front();
        if (x[544]) begin
          b_lrv = 1; b_lrf = x[543:0];
          if ($urandom % 100 < p_cor) b_lrf[$urandom % 544] ^= 1'b1;
          else if ($urandom % 100 < p_drop_ab) b_lrv = 0;
        end
      end
      a_lrv = 0; a_lrf = {rnd512(), $urandom};
      if (p_ba.size() > dly) begin
        x = p_ba.pop_front();
        if (x[544] && !inj) begin
          a_lrv = 1; a_lrf = x[543:0];
          if ($urandom % 100 < p_cor) a_lrf[$urandom % 544] ^= 1'b1;
          else if ($urandom % 100 < p_drop_ba) a_lrv = 0;
        end
      end
    end
    if (inj && j_v) begin a_lrv = 1; a_lrf = j_f; end
    // sideband: always up
    if (!rst_n) begin s_ab.delete(); s_ba.delete(); a_sbv = 0; b_sbv = 0; end
    else begin
      s_ab.push_back({a_sbtv, a_sbtm});
      s_ba.push_back({b_sbtv && !(cut_rsp_ba && b_sbtm[15:8] == 8'h04), b_sbtm});
      b_sbv = 0; b_sbm = $urandom;
      while (s_ab.size() > sdly) begin
        y = s_ab.pop_front();
        if (y[16]) begin b_sbv = 1; b_sbm = y[15:0]; end
      end
      a_sbv = 0; a_sbm = $urandom;
      while (s_ba.size() > sdly) begin
        y = s_ba.pop_front();
        if (y[16] && !sinj) begin a_sbv = 1; a_sbm = y[15:0]; end
      end
    end
    if (sinj && js_v) begin a_sbv = 1; a_sbm = js_m; end
  end

  // ---------------- tasks ----------------
  task automatic wait_st(input logic [2:0] sa, input logic [2:0] sb, input string ph);
    int t;
    t = 0;
    while (!(a_st == sa && b_st == sb) && t < 5000) begin @(negedge clk); t++; end
    if (t == 5000) fail($sformatf("%s: states %0d / %0d, expected %0d / %0d", ph, a_st, b_st, sa, sb));
  endtask
  task automatic link_up(input bit ra, input bit rb_, input bit sa, input bit sb, input string ph);
    a_rty = ra; b_rty = rb_; a_s1 = sa; b_s1 = sb;
    a_phy = 1; b_phy = 1; a_en = 1; b_en = 1;
    wait_st(ACTIVE, ACTIVE, ph);
    if (a_cap != {sa & sb, ra & rb_} || b_cap != a_cap) fail($sformatf("%s: cap %b / %b", ph, a_cap, b_cap));
  endtask
  task automatic link_down();
    a_on = 0; b_on = 0;
    wait_clk(1);
    a_en = 0; b_en = 0; a_tv = 0; b_tv = 0;
    wait_clk(sdly + 4);
    sb_ab.delete(); sb_ba.delete();
  endtask
  task automatic drain(input string ph);
    int t;
    t = 0;
    while ((sb_ab.size() != 0 || sb_ba.size() != 0 || a_pend != 0 || b_pend != 0 || a_tv || b_tv) && t < 20000) begin
      @(negedge clk); t++;
    end
    if (t == 20000) fail($sformatf("%s: stuck (%0d / %0d undelivered, %0d / %0d outstanding, states %0d / %0d)",
                                   ph, sb_ab.size(), sb_ba.size(), a_pend, b_pend, a_st, b_st));
    wait_clk(5);
    $display("%s: %0d A->B, %0d B->A, %0d CRC errors, %0d replays, %0d retrains", ph, n_ab, n_ba, n_crc, n_rep, n_rt);
  endtask
  task automatic run(input int n, input string ph);
    a_on = 1; b_on = 1;
    wait_clk(n);
    a_on = 0; b_on = 0;
    drain(ph);
  endtask
  // one payload offered at once
  task automatic poke(input bit a);
    if (a) begin a_tv = 1; a_td = rnd512(); a_ts = $urandom; end
    else begin b_tv = 1; b_td = rnd512(); b_ts = $urandom; end
    @(negedge clk);
  endtask
  // a crafted flit on A's receive side
  task automatic j_send(input bit d, input bit stk, input bit nak, input bit rty, input logic [5:0] seq,
                        input logic [5:0] ack, input logic [511:0] p, input bit bad);
    logic [527:0] h;
    h = {d, stk, nak, rty, seq, ack, p};
    j_v = 1; j_f = {h, crc16(h) ^ {15'd0, bad}};
    @(negedge clk);
    j_v = 0;
  endtask
  // a crafted sideband message on A's receive side
  task automatic js_send(input logic [7:0] code, input logic [7:0] d);
    js_v = 1; js_m = {code, d};
    @(negedge clk);
    js_v = 0;
  endtask
  // retrain with traffic: phy_up lost on both sides (B later by skew)
  task automatic retrain(input int skew, input string ph);
    a_on = 1; b_on = 1;
    wait_clk(200);
    while (!(a_pend > 1 && b_pend > 1)) @(negedge clk);
    a_phy = 0; b_phy = 0;
    wait_clk(5);
    a_phy = 1;
    wait_clk(skew);
    b_phy = 1;
    wait_clk(200);
    a_on = 0; b_on = 0;
    drain(ph);
  endtask

  initial begin
    wait_clk(3);
    rst_n = 1;
    wait_clk(3);
    // ---- bring-up: B late (A's AdvCap kept in RESET)
    a_phy = 1; b_phy = 1; a_en = 1;
    wait_clk(20);
    if (a_st != PARAM) fail("A not in PARAM while B is disabled");
    b_en = 1;
    wait_st(ACTIVE, ACTIVE, "bring-up");
    run(1000, "clean");
    dly = 6; p_tx = 100;
    run(1000, "long delay");
    dly = 2; p_tx = 70; p_cor = 5;
    run(3000, "corrupted");
    p_cor = 0; p_drop_ab = 5; p_drop_ba = 5;
    run(3000, "dropped");
    p_cor = 10; p_drop_ab = 10; p_drop_ba = 10; dly = 4;
    run(3000, "both");
    p_cor = 0; p_drop_ab = 0; p_drop_ba = 0; dly = 0; p_tx = 100;
    run(1000, "fast");
    for (int k = 0; k < 4; k++) begin pat = k; run(40, "payload class"); end
    pat = -1; p_tx = 70; dly = 2;

    // ---- retrain with traffic, then with skewed phy_up and a long sideband
    retrain(0, "retrain");
    sdly = 6;
    retrain(4, "retrain, skewed");
    retrain(12, "retrain, skewed more");
    sdly = 2;
    // ---- NR replays without progress: retrain request
    p_drop_ab = 100;
    a_on = 1; wait_clk(30); a_on = 0;
    while (n_rt == 0) @(negedge clk);
    p_drop_ab = 0;
    drain("retrain request");
    p_drop_ba = 100; b_on = 1; wait_clk(30); b_on = 0;
    while (n_rt < 2) @(negedge clk);
    p_drop_ba = 0;
    drain("retrain request B");

    // ---- L1
    a_pm = 1;
    wait_st(L1, L1, "L1 from A");
    poke(0);                                         // B wakes the link
    wait_st(ACTIVE, ACTIVE, "L1 exit by B");
    drain("L1 exit by B");
    wait_clk(20);
    if (a_st != ACTIVE) fail("A asked for L1 again without pm_req dropping");
    a_pm = 0; wait_clk(1); a_pm = 1;
    wait_st(L1, L1, "L1 again");
    poke(1);                                         // A wakes the link
    wait_st(ACTIVE, ACTIVE, "L1 exit by A");
    drain("L1 exit by A");
    a_pm = 0; b_l1ok = 0; wait_clk(2); a_pm = 1;    // B refuses: PMNAK
    wait_clk(30);
    if (a_st != ACTIVE || b_st != ACTIVE) fail("L1 refused, but not ACTIVE");
    b_l1ok = 1; a_pm = 0; wait_clk(2);
    a_pm = 1; b_pm = 1;                              // crossed requests
    wait_st(L1, L1, "crossed L1");
    poke(1);
    wait_st(ACTIVE, ACTIVE, "crossed L1 exit");
    drain("crossed L1 exit");
    a_pm = 0; b_pm = 0; wait_clk(2);
    a_on = 1; b_on = 1; p_tx = 100;                  // a request while the far side is busy: PMNAK
    wait_clk(20);
    b_pm = 1;
    wait_clk(40);
    b_pm = 0; a_pm = 1;
    wait_clk(40);
    a_on = 0; b_on = 0; a_pm = 0; p_tx = 70;
    drain("L1 while busy");
    b_on = 1; b_pm = 1; wait_clk(1); b_pm = 0;      // armed, but B is offering a payload
    wait_clk(5); b_on = 0;
    drain("L1 with tx_valid");
    // phy_up lost in L1
    a_pm = 1; wait_st(L1, L1, "L1 before retrain");
    a_phy = 0; b_phy = 0; wait_clk(4); a_phy = 1; b_phy = 1;
    wait_st(ACTIVE, ACTIVE, "retrain from L1");
    a_pm = 0;
    run(200, "after L1 retrain");

    // ---- crafted sideband messages on A (B's are not delivered)
    sinj = 1;
    wait_clk(sdly + 2);
    js_send(8'h00, 8'h00);                           // unknown code
    js_send(8'hFF, 8'h5A);
    js_send(8'h02, 8'h03);                           // FinCap in ACTIVE
    js_send(8'h04, 8'h00);                           // Rsp.Active in ACTIVE
    js_send(8'h06, 8'h00);                           // Rsp.L1 without a request
    js_send(8'h07, 8'h00);                           // Rsp.PMNAK without a request
    js_send(8'h03, 8'h00);                           // Req.Active in ACTIVE: A re-handshakes
    wait_clk(sdly + 4);
    if (a_st != ACTREQ) fail("crafted Req.Active: A not in ACTREQ");
    a_phy = 0; b_phy = 0; wait_clk(3); a_phy = 1; b_phy = 1;  // phy_up lost in ACTREQ
    wait_clk(sdly + 4);
    js_send(8'h03, 8'h00);                           // again in ACTREQ
    js_send(8'h04, 8'h00);
    wait_clk(2);
    if (a_st != ACTIVE) fail("crafted Rsp.Active: A not ACTIVE");
    sinj = 0;
    wait_st(ACTIVE, ACTIVE, "crafted Req.Active");
    run(100, "after crafted sideband");

    // ---- crafted flits on A's receive side: B's flits are not delivered to A
    inj = 1;
    wait_clk(3);
    b_on = 0;
    for (int k = 0; k < 6; k++) begin poke(1); while (a_tv) @(negedge clk); end
    wait_clk(2);
    j_send(1, 0, 0, 1, u_a.exp - 6'd1, u_a.ws - 6'd17, 512'h1, 0);  // duplicate; ACK not outstanding
    j_send(1, 0, 0, 1, u_a.exp + 6'd2, u_a.as - 6'd1, 512'h2, 0);   // SEQ ahead
    j_send(0, 0, 0, 1, 0, u_a.as - 6'd1, 0, 1);                    // bad CRC: no second Nak
    j_send(1, 0, 0, 0, u_a.exp, u_a.as - 6'd1, 512'h3, 0);          // RTY clear: dropped
    sb_ba.push_back({1'b1, 512'hC0FF_EE00_1234_5678});
    j_send(1, 1, 0, 1, u_a.exp, u_a.as, 512'hC0FF_EE00_1234_5678, 0); // the expected one, ACK one
    if (a_pend < 3) fail("crafted: too few flits outstanding");
    j_send(0, 0, 1, 1, 0, u_a.as - 6'd1, 0, 0);                    // NAK: replay the rest
    j_send(0, 0, 0, 1, 0, u_a.ws - 6'd1, 0, 0);                    // ACK everything mid-replay
    wait_clk(3);
    inj = 0;
    drain("crafted");

    // ---- stack 1 not negotiated
    link_down();
    link_up(1, 1, 1, 0, "no stack 1");
    run(500, "no stack 1");
    inj = 1; wait_clk(3);
    j_send(1, 1, 0, 1, u_a.exp, u_a.as - 6'd1, 512'h4, 0);          // stack 1: dropped, SEQ counted
    wait_clk(2);
    inj = 0;
    drain("stack 1 flit");
    link_down();
    link_up(1, 1, 0, 1, "no stack 1, A");
    run(300, "no stack 1, A");

    // ---- Retry off
    link_down();
    link_up(0, 1, 1, 1, "Retry off");
    run(500, "Retry off");
    inj = 1; wait_clk(3);
    j_send(0, 0, 0, 0, 0, 0, 0, 0);                                // NOP without Retry
    j_send(1, 0, 0, 1, 0, 0, 512'h5, 0);                           // RTY set
    sb_ba.push_back({1'b0, 512'h6});
    j_send(1, 0, 0, 0, 0, 0, 512'h6, 0);
    j_send(1, 0, 0, 0, 0, 0, 512'h7, 1);                           // bad CRC: LINKERROR
    wait_clk(2);
    if (a_st != LINKERR) fail("Retry off, bad CRC: A not in LINKERROR");
    inj = 0;
    j_send(1, 0, 0, 0, 0, 0, 512'h8, 0);                           // in LINKERROR: dropped
    link_down();
    link_up(1, 0, 1, 1, "Retry off at B");
    lossy = 1; p_cor = 2; dly = 1;
    a_on = 1; b_on = 1;
    wait_clk(1500);
    a_on = 0; b_on = 0;
    wait_clk(50);
    if (a_st != LINKERR && b_st != LINKERR) fail("Retry off with corruption: no LINKERROR");
    p_cor = 0; dly = 2; lossy = 0;
    link_down();
    link_up(0, 0, 0, 0, "Retry, stack 1 off");
    run(300, "Retry, stack 1 off");

    // ---- handshake timeouts
    link_down();
    a_rty = 1; b_rty = 1; a_s1 = 1; b_s1 = 1;
    a_en = 1;
    wait_clk(HT + 20);
    if (a_st != LINKERR) fail("PARAM timeout: A not in LINKERROR");
    a_en = 0; wait_clk(2);
    b_en = 1;
    wait_clk(10);
    a_en = 1;
    wait_st(ACTIVE, ACTIVE, "A late");
    link_down();
    cut_rsp_ba = 1;
    a_en = 1; b_en = 1;
    wait_clk(HT + 40);
    if (a_st != LINKERR) fail("ACTREQ timeout: A not in LINKERROR");
    cut_rsp_ba = 0;
    link_down();
    // FinCap mismatch, and messages out of place while negotiating
    sinj = 1;
    wait_clk(3);
    js_send(8'h02, 8'h03);                           // FinCap in RESET
    js_send(8'h04, 8'h00);                           // Rsp.Active in RESET
    js_send(8'h03, 8'h00);                           // Req.Active in RESET
    a_en = 1; wait_clk(2);
    js_send(8'h03, 8'h00);                           // Req.Active in PARAM: kept
    js_send(8'h01, 8'h03);
    js_send(8'h02, 8'h01);                           // FinCap 01, A's is 11
    wait_clk(3);
    if (a_st != LINKERR) fail("FinCap mismatch: A not in LINKERROR");
    js_send(8'h03, 8'h00);                           // in LINKERROR
    js_send(8'h01, 8'h03);                           // AdvCap in LINKERROR
    a_en = 0; wait_clk(3);
    a_en = 1; wait_clk(2);
    js_send(8'h02, 8'h03);                           // FinCap before AdvCap
    js_send(8'h01, 8'h03);
    js_send(8'h03, 8'h00);                           // Req.Active, then Rsp.Active
    wait_clk(2);
    js_send(8'h04, 8'h00);
    wait_clk(2);
    if (a_st != ACTIVE) fail("crafted bring-up: A not ACTIVE");
    inj = 1; j_v = 1; j_f = {16'h1000 | 16'(u_a.ws - 6'd1), 512'd0, crc16({16'h1000 | 16'(u_a.ws - 6'd1), 512'd0})};
    js_send(8'h05, 8'h00);                           // Req.L1 as a flit arrives: refused
    j_v = 0; inj = 0;
    wait_clk(3);
    js_send(8'h05, 8'h00);                           // Req.L1, accepted
    wait_clk(2);
    if (a_st != L1) fail("crafted Req.L1: A not in L1");
    js_send(8'h06, 8'h00);                           // Rsp.L1 in L1: ignored
    js_send(8'h07, 8'h00);                           // PMNAK in L1
    js_send(8'h05, 8'h00);                           // Req.L1 in L1
    inj = 1;
    j_send(1, 0, 0, 1, 0, 0, 512'h9, 0);           // a flit in L1
    inj = 0;
    js_send(8'h03, 8'h00);                           // Req.Active in L1
    js_send(8'h04, 8'h00);
    wait_clk(2);
    if (a_st != ACTIVE) fail("crafted L1 exit: A not ACTIVE");
    poke(1);                                         // owed while a Req.L1 arrives
    js_send(8'h05, 8'h00);
    inj = 1; j_send(0, 0, 0, 1, 0, u_a.ws - 6'd1, 0, 0); inj = 0;  // B is disabled: the TB acknowledges
    wait_clk(10);
    a_l1ok = 0; js_send(8'h05, 8'h00); a_l1ok = 1;  // refused
    a_pm = 1; wait_clk(3);
    js_send(8'h06, 8'h00);                           // Rsp.L1 to A's request
    wait_clk(2);
    if (a_st != L1) fail("crafted Rsp.L1: A not in L1");
    a_phy = 0; wait_clk(2);
    js_send(8'h03, 8'h00);                           // Req.Active in RETRAIN: kept
    js_send(8'h02, 8'h00);                           // FinCap in RETRAIN
    a_phy = 1; wait_clk(2);
    js_send(8'h04, 8'h00);
    wait_clk(2);
    if (a_st != ACTIVE) fail("crafted retrain: A not ACTIVE");
    a_pm = 0; wait_clk(1); a_pm = 1; wait_clk(3);
    js_send(8'h07, 8'h00);                           // PMNAK to A's request
    a_pm = 0;
    sinj = 0;
    link_down();
    // phy_up lost in PARAM (a long sideband keeps both in PARAM)
    sdly = 20;
    a_en = 1; b_en = 1;
    wait_clk(5);
    a_phy = 0; b_phy = 0; wait_clk(3); a_phy = 1; b_phy = 1;
    sdly = 2;
    wait_st(ACTIVE, ACTIVE, "after PARAM phy loss");
    // link_en low in ACTREQ and RETRAIN
    a_phy = 0; b_phy = 0; wait_clk(2);
    a_en = 0; wait_clk(2); a_phy = 1; b_phy = 1; a_en = 1;
    wait_st(ACTIVE, ACTIVE, "disable in RETRAIN");
    sinj = 1; js_send(8'h03, 8'h00); wait_clk(1);
    a_en = 0; wait_clk(2); sinj = 0; b_en = 0; wait_clk(sdly + 4);
    link_up(1, 1, 1, 1, "disable in ACTREQ");
    a_pm = 1; wait_st(L1, L1, "L1 before disable");
    a_pm = 0; a_en = 0; wait_clk(3); a_en = 1;      // A restarts: B gets an AdvCap in L1
    wait_st(ACTIVE, ACTIVE, "restart from L1");
    a_en = 0; wait_clk(3); a_en = 1;                // ... and in ACTIVE
    wait_st(ACTIVE, ACTIVE, "restart from ACTIVE");
    a_phy = 0; b_phy = 0; wait_clk(2);              // ... and in RETRAIN
    a_en = 0; wait_clk(2); a_en = 1; a_phy = 1; wait_clk(sdly + 4); b_phy = 1;
    wait_st(ACTIVE, ACTIVE, "restart from RETRAIN");
    link_down();
    link_up(1, 1, 1, 1, "after disable in L1");
    a_on = 1; b_on = 1; wait_clk(100);
    link_down();                                     // with traffic
    link_up(1, 1, 1, 1, "after disable in ACTIVE");
    run(300, "after disable in ACTIVE");

    // ---- reset with traffic in flight
    dly = 3; p_cor = 5; a_on = 1; b_on = 1;
    while (!(a_pend > 2 && b_pend > 2 && b_rv)) @(negedge clk);
    rst_n = 0;
    a_on = 0; b_on = 0;
    wait_clk(3);
    sb_ab.delete(); sb_ba.delete(); a_tv = 0; b_tv = 0;
    rst_n = 1;
    p_cor = 0; dly = 1;
    wait_st(ACTIVE, ACTIVE, "after reset");
    run(1000, "after reset");
    if (errors == 0) $display("TEST PASSED: UCIe (%0d A->B, %0d B->A payloads, %0d replays, %0d retrains)", n_ab, n_ba, n_rep, n_rt);
    else $display("TEST FAILED: UCIe (%0d errors)", errors);
    $finish;
  end

  initial begin
    #20ms;
    $display("TEST FAILED: UCIe (timeout)");
    $finish;
  end
endmodule
