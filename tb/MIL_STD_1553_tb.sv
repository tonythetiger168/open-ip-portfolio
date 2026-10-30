// SPDX-License-Identifier: Apache-2.0
// Self-checking TB of MIL_STD_1553_top: one bus controller and two remote
// terminals (RT 5, RT 26) on dual-redundant buses (wired OR of the
// transmitters), each with its own buffer memory, plus a word-level BFM on
// both buses that plays a faulty BC or RT. Checked: BC-RT, RT-BC, RT-RT and
// broadcast transfers of 1..32 words on both buses (memory contents, status
// words, message reports), every mode code (legal, illegal, broadcast),
// the status bits, transmitter shutdown, superseding commands, every
// receive error at the RT and at the BC, three bit timings, and reset.
`timescale 1ns/1ps
module MIL_STD_1553_tb;
  logic clk = 0, rst_n = 0;
  always #5 clk = ~clk;
  int errors = 0;
  task automatic fail(input string m);
    errors++;
    $display("ERROR: %s @%0t", m, $time);
  endtask
  task automatic cyc(input int n);
    for (int i = 0; i < n; i++) @(negedge clk);
  endtask

  logic [7:0] half = 8, tmo = 28;
  // ---- buses: wired OR of the three terminals and the BFM
  logic f_a_p = 0, f_a_n = 0, f_b_p = 0, f_b_n = 0;
  wire  [2:0] tap, tan, tbp, tbn;
  wire  a_p = |tap | f_a_p, a_n = |tan | f_a_n, b_p = |tbp | f_b_p, b_n = |tbn | f_b_n;
  // ---- per-terminal configuration
  logic [4:0]  c_addr [0:2];
  logic [2:0]  c_bce = 3'b111, c_sr = 0, c_busy = 0, c_ssf = 0, c_tf = 0;
  logic [2:0][15:0] c_vec, c_bit;
  // ---- BC controls (terminal 0)
  logic        bc_start = 0, bc_bus = 0;
  logic [2:0]  bc_type = 0;
  logic [15:0] bc_c1 = 0, bc_c2 = 0;
  initial begin
    c_addr[0] = 5'd0; c_addr[1] = 5'd5; c_addr[2] = 5'd26;
    for (int i = 0; i < 3; i++) begin c_vec[i] = 16'h1000 + i; c_bit[i] = 16'hB000 + i; end
  end

  // one terminal with its memory and report counters (named blocks, not a generate loop,
  // whose instances share one set of toggle points in the coverage tool)
`define TERMINAL(G) \
    logic        hrd = 0, hwr = 0; \
    logic [10:0] haddr = 0; \
    logic [15:0] hwd = 0, hrdat; \
    logic        msg, mbus, merr, mbc, sync, st, rst, sd, bbusy, bdone, enr, ead, ewd, ewc, inh; \
    logic [15:0] mcmd, md, s1, s2; \
    logic [2:0]  mwhy; \
    logic [5:0]  mcnt, bcnt; \
    logic [1:0]  shut; \
    MIL_STD_1553_top u ( \
      .clk, .rst_n, .cfg_half(half), .cfg_bc((G) == 0), .cfg_resp_timeout(tmo), \
      .tx_a_p(tap[G]), .tx_a_n(tan[G]), .tx_b_p(tbp[G]), .tx_b_n(tbn[G]), \
      .rx_a_p(a_p), .rx_a_n(a_n), .rx_b_p(b_p), .rx_b_n(b_n), \
      .host_rd(hrd), .host_wr(hwr), .host_addr(haddr), .host_wdata(hwd), .host_rdata(hrdat), \
      .cfg_rt_addr(c_addr[G]), .cfg_bcast_en(c_bce[G]), .cfg_sr(c_sr[G]), .cfg_busy(c_busy[G]), \
      .cfg_ssf(c_ssf[G]), .cfg_tf(c_tf[G]), .cfg_vector(c_vec[G]), .cfg_bit_word(c_bit[G]), \
      .rt_msg(msg), .rt_msg_cmd(mcmd), .rt_msg_bus(mbus), .rt_msg_err(merr), .rt_msg_why(mwhy), \
      .rt_msg_bcast(mbc), .rt_msg_cnt(mcnt), .mc_sync(sync), .mc_selftest(st), .mc_reset(rst), \
      .mc_sync_data(sd), .mc_data(md), .rt_tx_shut(shut), .rt_tf_inh(inh), \
      .bc_start((G) == 0 ? bc_start : 1'b0), .bc_type(bc_type), .bc_bus(bc_bus), .bc_cmd1(bc_c1), .bc_cmd2(bc_c2), \
      .bc_busy(bbusy), .bc_done(bdone), .bc_err_noresp(enr), .bc_err_addr(ead), .bc_err_word(ewd), \
      .bc_err_wc(ewc), .bc_stat1(s1), .bc_stat2(s2), .bc_cnt(bcnt)); \
 \
    int          n_msg = 0, n_sync = 0, n_st = 0, n_rst = 0, n_sd = 0, n_words = 0, n_mw = 0; \
    logic [15:0] l_cmd, l_md; \
    logic        l_bus, l_err, l_bc; \
    logic [2:0]  l_why; \
    logic [5:0]  l_cnt; \
    always @(negedge clk) begin \
      if (msg) begin n_msg++; l_cmd = mcmd; l_bus = mbus; l_err = merr; l_bc = mbc; l_why = mwhy; l_cnt = mcnt; end \
      if (sync) n_sync++; \
      if (st) n_st++; \
      if (rst) n_rst++; \
      if (sd) begin n_sd++; l_md = md; end \
      if (u.e_last) n_words++; \
      if (u.mem_wr) n_mw++; \
    end
  if (1) begin : T0
`TERMINAL(0)
  end
  if (1) begin : T1
`TERMINAL(1)
  end
  if (1) begin : T2
`TERMINAL(2)
  end

  function automatic logic [15:0] cw(input int rt, input bit tr, input int sa, input int wc);
    return {5'(rt), tr, 5'(sa), 5'(wc)};
  endfunction
  function automatic logic [15:0] stw(input int rt, input bit me = 0, input bit sr = 0, input bit bcr = 0,
                                      input bit busy = 0, input bit ssf = 0, input bit tf = 0);
    return {5'(rt), me, 1'b0, sr, 3'b000, bcr, busy, ssf, 1'b0, tf};
  endfunction
  function automatic int nw(input int wc);
    return wc == 0 ? 32 : wc;
  endfunction

  // ---------------- BC ----------------
  logic        r_enr, r_ead, r_ewd, r_ewc;
  logic [15:0] r_s1, r_s2;
  logic [5:0]  r_cnt;
  task automatic bc_run(input int ty, input bit bus, input logic [15:0] c1, input logic [15:0] c2 = 0);
    int k;
    @(negedge clk);
    bc_type = 3'(ty); bc_bus = bus; bc_c1 = c1; bc_c2 = c2; bc_start = 1;
    @(negedge clk) bc_start = 0;
    k = 0;
    while (!T0.bdone && k < 200000) begin @(negedge clk); k++; end
    if (!T0.bdone) fail("BC: no bc_done");
    if (T0.bbusy) fail("BC: busy with bc_done");
    r_enr = T0.enr; r_ead = T0.ead; r_ewd = T0.ewd; r_ewc = T0.ewc;
    r_s1 = T0.s1; r_s2 = T0.s2; r_cnt = T0.bcnt;
    cyc(16 * half);                                         // the terminals finish their reports
  endtask
  task automatic bc_expect(input string what, input logic [3:0] err, input logic [15:0] s1,
                           input logic [15:0] s2 = 0, input int cnt = 0);
    if ({r_enr, r_ead, r_ewd, r_ewc} !== err) fail($sformatf("%s: BC errors %b, expected %b", what, {r_enr, r_ead, r_ewd, r_ewc}, err));
    if (r_s1 !== s1) fail($sformatf("%s: status 1 %h, expected %h", what, r_s1, s1));
    if (r_s2 !== s2) fail($sformatf("%s: status 2 %h, expected %h", what, r_s2, s2));
    if (r_cnt !== 6'(cnt)) fail($sformatf("%s: BC words %0d, expected %0d", what, r_cnt, cnt));
  endtask

  // ---------------- RT reports ----------------
  int base_msg [0:2], base_words [0:2], base_mw [0:2];
  task automatic mark;
    base_msg[0] = T0.n_msg; base_msg[1] = T1.n_msg; base_msg[2] = T2.n_msg;
    base_words[0] = T0.n_words; base_words[1] = T1.n_words; base_words[2] = T2.n_words;
    base_mw[0] = T0.n_mw; base_mw[1] = T1.n_mw; base_mw[2] = T2.n_mw;
  endtask
  task automatic rt_expect(input string what, input int i, input logic [15:0] cmd, input bit bus,
                           input bit err, input int why, input int cnt, input int words);
    int n, wds;
    logic [15:0] c;
    logic        b, e, bc;
    logic [2:0]  y;
    logic [5:0]  k;
    if (i == 1) begin n = T1.n_msg; c = T1.l_cmd; b = T1.l_bus; e = T1.l_err; y = T1.l_why; k = T1.l_cnt; bc = T1.l_bc; wds = T1.n_words; end
    else begin n = T2.n_msg; c = T2.l_cmd; b = T2.l_bus; e = T2.l_err; y = T2.l_why; k = T2.l_cnt; bc = T2.l_bc; wds = T2.n_words; end
    if (n != base_msg[i] + 1) fail($sformatf("%s: RT%0d reported %0d messages", what, i, n - base_msg[i]));
    else if ({c, b, e, y, k, bc} !== {cmd, bus, err, 3'(why), 6'(cnt), cmd[15:11] == 5'd31})
      fail($sformatf("%s: RT%0d report cmd %h bus %b err %b why %0d cnt %0d", what, i, c, b, e, y, k));
    if (wds - base_words[i] != words) fail($sformatf("%s: RT%0d sent %0d words, expected %0d", what, i, wds - base_words[i], words));
  endtask
  task automatic rt_quiet(input string what, input int i);
    int n;
    n = i == 1 ? T1.n_msg : T2.n_msg;
    if (n != base_msg[i]) fail($sformatf("%s: RT%0d reported a message", what, i));
  endtask

  // ---------------- memories ----------------
  task automatic fill(input int i, input int sa);
    for (int k = 0; k < 32; k++) begin
      logic [15:0] v;
      v = $urandom;
      case (i) 0: T0.u.ram[{1'b1, 5'(sa), 5'(k)}] = v; 1: T1.u.ram[{1'b1, 5'(sa), 5'(k)}] = v; default: T2.u.ram[{1'b1, 5'(sa), 5'(k)}] = v; endcase
    end
  endtask
  function automatic logic [15:0] rdm(input int i, input logic [10:0] a);
    return i == 0 ? T0.u.ram[a] : i == 1 ? T1.u.ram[a] : T2.u.ram[a];
  endfunction
  task automatic mem_cmp(input string what, input int i, input logic [10:0] a, input int j, input logic [10:0] b, input int n);
    int bad;
    bad = -1;
    for (int k = 0; k < n; k++)
      if (bad < 0 && rdm(i, a + 11'(k)) !== rdm(j, b + 11'(k))) bad = k;
    if (bad >= 0) fail($sformatf("%s: word %0d %h != %h", what, bad, rdm(i, a + 11'(bad)), rdm(j, b + 11'(bad))));
  endtask

  // ---------------- word BFM ----------------
  logic f_lvl, f_on, f_bus;
  always @* begin
    f_a_p = f_on && !f_bus && f_lvl;  f_a_n = f_on && !f_bus && !f_lvl;
    f_b_p = f_on && f_bus && f_lvl;   f_b_n = f_on && f_bus && !f_lvl;
  end
  initial begin f_on = 0; f_lvl = 0; f_bus = 0; end
  // a half bit of level l (2: idle)
  task automatic f_half(input int l);
    @(posedge clk); #1;
    f_on = l != 2; f_lvl = l == 1;
    for (int i = 0; i < half - 1; i++) @(posedge clk);
  endtask
  // one word; perr: flip parity; merr: half-bit pair k made equal (Manchester error);
  // serr: the sync's second half broken
  task automatic f_word(input bit bus, input bit cmd, input logic [15:0] d, input bit perr = 0,
                        input int merr = -1, input bit serr = 0);
    logic [16:0] w;
    w = {d, ~^d ^ perr};
    f_bus = bus;
    for (int i = 0; i < 3; i++) f_half(cmd);
    for (int i = 0; i < 3; i++) f_half(serr && i == 1 ? 2 : !cmd);
    for (int i = 0; i < 17; i++) begin
      f_half(w[16 - i]);
      f_half(i == merr ? w[16 - i] : !w[16 - i]);
    end
  endtask
  task automatic f_idle(input int halves);
    for (int i = 0; i < halves; i++) f_half(2);
  endtask
  // wait for the BC's transmission to end
  task automatic bc_tx_end;
    @(negedge clk);
    while (!T0.u.e_act) @(negedge clk);
    while (T0.u.e_act) @(negedge clk);
  endtask

  // =========================================================================
  initial begin
    logic [15:0] c, c2;
    int sa, sa2, wc;
    bit bus;
    cyc(5); rst_n = 1; cyc(5);

    // ---- 1. BC-RT and RT-BC, both RTs, both buses, 1..32 words
    $display("[%0t] 1. BC-RT / RT-BC", $time);
    for (int it = 0; it < 16; it++) begin
      int r;
      r = 1 + it % 2; bus = it[1]; sa = 1 + $urandom % 30; wc = it == 0 ? 0 : it == 1 ? 1 : $urandom % 32;
      fill(0, 0); mark();
      c = cw(c_addr[r], 0, sa, wc);
      bc_run(0, bus, c);
      bc_expect("BC-RT", 4'b0000, stw(c_addr[r]));
      rt_expect("BC-RT", r, c, bus, 0, 0, nw(wc), 1);
      mem_cmp("BC-RT data", r, {1'b0, 5'(sa), 5'd0}, 0, {1'b1, 5'd0, 5'd0}, nw(wc));
      fill(r, sa); mark();
      c = cw(c_addr[r], 1, sa, wc);
      bc_run(1, bus, c);
      bc_expect("RT-BC", 4'b0000, stw(c_addr[r]), 0, nw(wc));
      rt_expect("RT-BC", r, c, bus, 0, 0, nw(wc), 1 + nw(wc));
      mem_cmp("RT-BC data", 0, {1'b0, 5'd0, 5'd0}, r, {1'b1, 5'(sa), 5'd0}, nw(wc));
    end

    // ---- 2. RT-RT both ways, both buses
    $display("[%0t] 2. RT-RT", $time);
    for (int it = 0; it < 6; it++) begin
      int rx, tx;
      rx = 1 + it % 2; tx = 3 - rx; bus = it[1]; sa = 1 + $urandom % 30; sa2 = 1 + $urandom % 30;
      wc = it == 0 ? 0 : 1 + $urandom % 31;
      fill(tx, sa2); mark();
      c = cw(c_addr[rx], 0, sa, wc); c2 = cw(c_addr[tx], 1, sa2, wc);
      bc_run(2, bus, c, c2);
      bc_expect("RT-RT", 4'b0000, stw(c_addr[tx]), stw(c_addr[rx]), nw(wc));
      rt_expect("RT-RT rx", rx, c, bus, 0, 0, nw(wc), 1);
      rt_expect("RT-RT tx", tx, c2, bus, 0, 0, nw(wc), 1 + nw(wc));
      mem_cmp("RT-RT data", rx, {1'b0, 5'(sa), 5'd0}, tx, {1'b1, 5'(sa2), 5'd0}, nw(wc));
    end

    // ---- 3. broadcast
    $display("[%0t] 3. broadcast", $time);
    fill(0, 0); mark();
    c = cw(31, 0, 7, 4);
    bc_run(0, 0, c);
    bc_expect("broadcast", 4'b0000, 0);
    rt_expect("broadcast", 1, c, 0, 0, 0, 4, 0);
    rt_expect("broadcast", 2, c, 0, 0, 0, 4, 0);
    mem_cmp("broadcast RT5", 1, {1'b0, 5'd7, 5'd0}, 0, {1'b1, 5'd0, 5'd0}, 4);
    mem_cmp("broadcast RT26", 2, {1'b0, 5'd7, 5'd0}, 0, {1'b1, 5'd0, 5'd0}, 4);
    mark(); c = cw(5, 1, 0, 2);                             // transmit status word: BCR
    bc_run(3, 0, c);
    bc_expect("status after broadcast", 4'b0000, stw(5, 0, 0, 1));
    rt_expect("status after broadcast", 1, c, 0, 0, 0, 0, 1);
    mark(); c = cw(5, 1, 31, 1);                            // a new message clears BCR
    bc_run(3, 1, c);
    bc_expect("BCR cleared", 4'b0000, stw(5));
    c_bce[2] = 0; mark(); c = cw(31, 0, 3, 2);              // RT26 ignores broadcasts
    bc_run(0, 0, c);
    rt_expect("broadcast off", 1, c, 0, 0, 0, 2, 0); rt_quiet("broadcast off", 2);
    c_bce[2] = 1;
    fill(1, 4); mark(); c = cw(31, 0, 6, 5); c2 = cw(5, 1, 4, 5);   // broadcast RT-RT from RT5
    bc_run(2, 1, c, c2);
    bc_expect("broadcast RT-RT", 4'b0000, stw(5), 0, 5);
    rt_expect("broadcast RT-RT rx", 2, c, 1, 0, 0, 5, 0);
    rt_expect("broadcast RT-RT tx", 1, c2, 1, 0, 0, 5, 6);
    mem_cmp("broadcast RT-RT", 2, {1'b0, 5'd6, 5'd0}, 1, {1'b1, 5'd4, 5'd0}, 5);
    mark(); c = cw(31, 1, 3, 2);                            // broadcast transmit: illegal
    bc_run(1, 0, c);
    bc_expect("broadcast transmit", 4'b0000, 0);            // the BC expects no status either
    rt_expect("broadcast transmit", 1, c, 0, 1, 3, 0, 0);
    rt_expect("broadcast transmit", 2, c, 0, 1, 3, 0, 0);
    mark(); c = cw(5, 1, 31, 2);
    bc_run(3, 0, c);
    bc_expect("status after illegal broadcast", 4'b0000, stw(5, 1, 0, 1));
    rt_expect("status after illegal broadcast", 1, c, 0, 0, 0, 0, 1);

    // ---- 4. mode codes
    $display("[%0t] 4. mode codes", $time);
    begin
      int n0, n1;
      n0 = T1.n_sync; mark(); c = cw(5, 1, 0, 1);
      bc_run(3, 0, c); bc_expect("synchronize", 4'b0000, stw(5)); rt_expect("synchronize", 1, c, 0, 0, 0, 0, 1);
      if (T1.n_sync != n0 + 1) fail("synchronize: no mc_sync");
      n0 = T2.n_st; mark(); c = cw(26, 1, 31, 3);
      bc_run(3, 1, c); bc_expect("self test", 4'b0000, stw(26)); rt_expect("self test", 2, c, 1, 0, 0, 0, 1);
      if (T2.n_st != n0 + 1) fail("self test: no mc_selftest");
      // transmitter shutdown of bus B (from A), then of A (from B), overrides
      mark(); c = cw(5, 1, 0, 4); bc_run(3, 0, c); bc_expect("shutdown B", 4'b0000, stw(5));
      if (T1.shut !== 2'b10) fail("shutdown B");
      fill(0, 0); mark(); c = cw(5, 0, 2, 3); bc_run(0, 1, c);
      bc_expect("on the shut bus", 4'b1000, 0); rt_expect("on the shut bus", 1, c, 1, 0, 0, 3, 0);
      mem_cmp("on the shut bus", 1, {1'b0, 5'd2, 5'd0}, 0, {1'b1, 5'd0, 5'd0}, 3);
      mark(); c = cw(5, 1, 2, 3); bc_run(1, 1, c); bc_expect("transmit on the shut bus", 4'b1000, 0);
      rt_expect("transmit on the shut bus", 1, c, 1, 0, 0, 0, 0);
      mark(); c = cw(5, 1, 31, 5); bc_run(3, 0, c); bc_expect("override B", 4'b0000, stw(5));
      if (T1.shut !== 2'b00) fail("override B");
      mark(); c = cw(5, 1, 0, 4); bc_run(3, 1, c); bc_expect("shutdown A", 4'b0000, stw(5));
      if (T1.shut !== 2'b01) fail("shutdown A");
      mark(); c = cw(5, 1, 0, 1); bc_run(3, 0, c); bc_expect("on the shut bus A", 4'b1000, 0);
      mark(); c = cw(5, 1, 0, 8); bc_run(3, 1, c); bc_expect("reset RT", 4'b0000, stw(5));
      if (T1.shut !== 2'b00 || T1.n_rst != 1) fail("reset RT");
      // terminal flag and its inhibit
      c_tf = 3'b111; mark(); c = cw(5, 1, 0, 1); bc_run(3, 0, c); bc_expect("terminal flag", 4'b0000, stw(5, 0, 0, 0, 0, 0, 1));
      c = cw(5, 1, 0, 6); bc_run(3, 0, c); bc_expect("inhibit TF", 4'b0000, stw(5));
      c = cw(5, 1, 0, 2); bc_run(3, 0, c); bc_expect("TF inhibited", 4'b0000, stw(5));
      c = cw(5, 1, 31, 7); bc_run(3, 0, c); bc_expect("override TF inhibit", 4'b0000, stw(5, 0, 0, 0, 0, 0, 1));
      c_tf = 0;
      // words: vector, synchronize with data, last command, BIT
      for (int k = 0; k < 3; k++) begin                       // every bit 1 and 0 again
        c_vec = {3{k == 2 ? 16'h0000 : k ? 16'h5A3C : 16'hA5C3}};
        mark(); c = cw(5, 1, 0, 16); bc_run(4, k % 2, c); bc_expect("vector", 4'b0000, stw(5), 0, 1);
        rt_expect("vector", 1, c, k % 2, 0, 0, 1, 2);
        if (T0.u.ram[0] !== c_vec[1]) fail("vector word");
      end
      T0.u.ram[11'h400] = 16'h5AA5; n0 = T1.n_sd;
      mark(); c = cw(5, 0, 31, 17); bc_run(5, 1, c); bc_expect("sync with data", 4'b0000, stw(5));
      rt_expect("sync with data", 1, c, 1, 0, 0, 1, 1);
      if (T1.n_sd != n0 + 1 || T1.l_md !== 16'h5AA5) fail("sync with data");
      c2 = c; mark(); c = cw(5, 1, 0, 18); bc_run(4, 0, c); bc_expect("last command", 4'b0000, stw(5), 0, 1);
      if (T0.u.ram[0] !== c2) fail("last command word");
      c = cw(5, 1, 0, 18); bc_run(4, 0, c);
      if (T0.u.ram[0] !== c2) fail("last command: itself not stored");
      for (int k = 0; k < 3; k++) begin
        c_bit = {3{k == 2 ? 16'h0000 : k ? 16'h3CA5 : 16'hC35A}};
        mark(); c = cw(26, 1, 0, 19); bc_run(4, 1, c); bc_expect("BIT word", 4'b0000, stw(26), 0, 1);
        if (T0.u.ram[0] !== c_bit[2]) fail("BIT word");
      end
      // illegal: dynamic bus control, reserved 9..15, T/R = 0 without data, receive with data 20,
      // transmit 21; the status word keeps the message error bit
      for (int k = 0; k < 5; k++) begin
        logic [15:0] ce;
        int ty, s0;
        ce = k == 0 ? cw(5, 1, 0, 0) : k == 1 ? cw(5, 1, 31, 9 + $urandom % 7) : k == 2 ? cw(5, 0, 0, 3)
           : k == 3 ? cw(5, 0, 31, 20) : cw(5, 1, 0, 21);
        ty = k == 3 ? 5 : k == 4 ? 4 : 3;
        n0 = T1.n_sd; s0 = T1.n_st; mark();
        bc_run(ty, k[0], ce);
        if (T1.n_st != s0) fail("illegal mode code 3 (T/R = 0) ran the self test");
        bc_expect($sformatf("illegal %h", ce), 4'b0000, stw(5, 1));
        rt_expect($sformatf("illegal %h", ce), 1, ce, k[0], 1, 3, k == 3 ? 1 : 0, 1);
        if (T1.n_sd != n0) fail("illegal mode code 20 synchronized");
        mark(); c = cw(5, 1, 0, 2); bc_run(3, 0, c);
        bc_expect("status after illegal", 4'b0000, stw(5, 1));
        rt_expect("status after illegal", 1, c, 0, 0, 0, 0, 1);
      end
      // broadcast mode codes: synchronize, sync with data, shutdown / override, reset; illegal ones
      n0 = T1.n_sync; n1 = T2.n_sync; mark(); c = cw(31, 1, 0, 1); bc_run(3, 0, c);
      bc_expect("broadcast sync", 4'b0000, 0);
      if (T1.n_sync != n0 + 1 || T2.n_sync != n1 + 1) fail("broadcast sync");
      rt_expect("broadcast sync", 1, c, 0, 0, 0, 0, 0);
      T0.u.ram[11'h400] = 16'hA55A; n0 = T1.n_sd; n1 = T2.n_sd; c = cw(31, 0, 31, 17); bc_run(5, 0, c);
      if (T1.n_sd != n0 + 1 || T2.n_sd != n1 + 1 || T2.l_md !== 16'hA55A) fail("broadcast sync with data");
      c = cw(31, 1, 0, 4); bc_run(3, 1, c);
      if (T1.shut !== 2'b01 || T2.shut !== 2'b01) fail("broadcast shutdown");
      c = cw(31, 1, 0, 5); bc_run(3, 1, c);
      if (T1.shut !== 2'b00 || T2.shut !== 2'b00) fail("broadcast override");
      c = cw(31, 1, 0, 6); bc_run(3, 0, c);
      if (!T1.inh || !T2.inh) fail("broadcast inhibit TF");
      c = cw(31, 1, 0, 7); bc_run(3, 0, c);
      c = cw(31, 1, 0, 4); bc_run(3, 0, c);
      n0 = T1.n_rst; n1 = T2.n_rst; c = cw(31, 1, 0, 8); bc_run(3, 0, c);
      if (T1.n_rst != n0 + 1 || T2.n_rst != n1 + 1 || T1.shut !== 2'b00) fail("broadcast reset");
      for (int k = 0; k < 3; k++) begin                       // transmit status, vector, dynamic bus control
        mark(); c = cw(31, 1, 0, k == 0 ? 2 : k == 1 ? 16 : 0);
        bc_run(3, 0, c);
        rt_expect("broadcast illegal mode", 1, c, 0, 1, 3, 0, 0);
        rt_expect("broadcast illegal mode", 2, c, 0, 1, 3, 0, 0);
      end
    end

    // ---- 5. status bits, busy
    $display("[%0t] 5. status bits, busy", $time);
    c_sr = 3'b111; c_ssf = 3'b111; c_busy = 3'b111;            // RT5 is not addressed here
    fill(2, 8); mark(); c = cw(26, 1, 8, 6); bc_run(1, 0, c);
    bc_expect("busy RT-BC", 4'b0000, stw(26, 0, 1, 0, 1, 1), 0, 0);
    rt_expect("busy RT-BC", 2, c, 0, 0, 0, 0, 1);
    for (int k = 0; k < 4; k++) T2.u.ram[{1'b0, 5'd8, 5'(k)}] = 16'hDEAD;
    mark(); c = cw(26, 0, 8, 4); bc_run(0, 1, c);
    bc_expect("busy BC-RT", 4'b0000, stw(26, 0, 1, 0, 1, 1));
    rt_expect("busy BC-RT", 2, c, 1, 0, 0, 4, 1);
    if (T2.u.ram[{1'b0, 5'd8, 5'd3}] !== 16'hDEAD || T2.n_mw != base_mw[2]) fail("busy: data stored");
    c_sr = 0; c_ssf = 0; c_busy = 0;

    // ---- 6. receive errors at the RT (the BFM is the BC)
    $display("[%0t] 6. RT receive errors", $time);
    for (int k = 0; k < 17; k++) begin
      int why, cnt;
      bit quiet;
      bus = k[0]; mark(); quiet = 0;
      case (k)
        0: begin c = cw(5, 0, 3, 3); f_word(bus, 1, c); f_word(bus, 0, 1); f_word(bus, 0, 2, 1); f_word(bus, 0, 3); why = 1; cnt = 1; end
        1: begin c = cw(5, 0, 3, 3); f_word(bus, 1, c); f_word(bus, 0, 1, 0, 5); why = 1; cnt = 0; end
        2: begin c = cw(5, 0, 3, 3); f_word(bus, 1, c); f_word(bus, 0, 1); f_word(bus, 0, 2, 0, -1, 1); why = 1; cnt = 1; end
        3: begin c = cw(5, 0, 3, 3); f_word(bus, 1, c); f_word(bus, 0, 1); f_word(bus, 1, 2); why = 2; cnt = 1; end
        4: begin c = cw(5, 0, 3, 3); f_word(bus, 1, c); f_word(bus, 0, 1); f_word(bus, 0, 2); why = 2; cnt = 2; end
        5: begin c = cw(5, 0, 3, 2); f_word(bus, 1, c); f_word(bus, 0, 1); f_word(bus, 0, 2); f_word(bus, 0, 3); why = 2; cnt = 2; end
        6: begin c = cw(5, 1, 3, 2); f_word(bus, 1, c); f_word(bus, 0, 1); why = 2; cnt = 0; end
        7: begin c = cw(5, 0, 3, 2); f_word(bus, 1, c); why = 2; cnt = 0; end
        8: begin c = cw(5, 0, 3, 2); f_word(bus, 1, c); f_word(bus, 1, cw(20, 1, 1, 2)); why = 4; cnt = 0; end
        9: begin c = cw(5, 0, 3, 2); f_word(bus, 1, c); f_word(bus, 1, cw(20, 1, 1, 2)); f_idle(9); f_word(bus, 1, stw(21)); why = 4; cnt = 0; end
        10: begin c = cw(5, 0, 3, 2); f_word(bus, 1, c); f_word(bus, 1, cw(20, 1, 1, 2)); f_idle(9); f_word(bus, 1, stw(20), 1); why = 4; cnt = 0; end
        11: begin c = cw(5, 0, 3, 2); f_word(bus, 1, c); f_word(bus, 1, cw(20, 1, 1, 2)); f_idle(9); f_word(bus, 0, 7); why = 4; cnt = 0; end
        12: begin c = cw(5, 0, 3, 2); f_word(bus, 1, c); f_word(bus, 1, cw(20, 1, 1, 2)); f_idle(9); f_word(bus, 1, stw(20)); f_word(bus, 0, 7, 1); why = 1; cnt = 0; end
        13: begin c = cw(5, 0, 3, 2); f_word(bus, 1, c); f_word(bus, 1, cw(20, 0, 1, 2)); why = 2; cnt = 0; end
        14: begin c = cw(5, 0, 3, 2); f_word(bus, 1, c); c = cw(31, 1, 1, 2); f_word(bus, 1, c); why = 3; cnt = 0; end   // a broadcast transmit command
        15: begin c = cw(5, 0, 3, 2); f_word(bus, 1, c); f_word(bus, 1, cw(20, 1, 1, 2)); f_idle(9); f_word(bus, 1, stw(20)); f_word(bus, 0, 7); why = 2; cnt = 1; end
        default: begin c = cw(5, 0, 3, 2); f_word(bus, 1, c, 1); f_word(bus, 0, 1); f_word(bus, 0, 2); quiet = 1; why = 0; cnt = 0; end
      endcase
      f_idle(200);
      if (quiet) rt_quiet("command with a parity error", 1);
      else rt_expect($sformatf("RT error case %0d", k), 1, c, bus, 1, why, cnt, 0);
      if (k == 4) begin                                    // too few words: the status says so
        mark(); c = cw(5, 1, 0, 2); bc_run(3, 0, c); bc_expect("status after too few words", 4'b0000, stw(5, 1));
      end
    end
    // RT-RT with the BFM as the transmitting RT: good transfer
    mark(); c = cw(5, 0, 12, 2);
    f_word(1, 1, c); f_word(1, 1, cw(20, 1, 1, 2)); f_idle(9); f_word(1, 1, stw(20)); f_word(1, 0, 16'hA1A1); f_word(1, 0, 16'h1A1A);
    f_idle(60);
    rt_expect("RT-RT from the BFM", 1, c, 1, 0, 0, 2, 1);
    if (T1.u.ram[{1'b0, 5'd12, 5'd1}] !== 16'h1A1A) fail("RT-RT from the BFM: data");

    // ---- 7. superseding commands
    $display("[%0t] 7. superseding", $time);
    begin
      int n0;
      fill(0, 0); n0 = T1.n_sync; mark();
      fork
        bc_run(0, 0, cw(5, 0, 3, 20));
        begin cyc(5 * 40 * half); f_word(1, 1, cw(5, 1, 0, 1)); f_idle(1); end
      join
      bc_expect("superseded receive", 4'b1000, 0);
      rt_expect("superseded receive", 1, cw(5, 1, 0, 1), 1, 0, 0, 0, 1);
      if (T1.n_sync != n0 + 1) fail("superseded receive: no sync");
      fill(1, 3); mark();
      fork
        bc_run(1, 0, cw(5, 1, 3, 30));
        begin cyc(8 * 40 * half); f_word(1, 1, cw(5, 1, 0, 1)); f_idle(1); end
      join
      cyc(60 * half);
      if (!r_ewd || r_cnt == 0 || r_cnt >= 30) fail($sformatf("superseded transmit: BC word error %b, %0d words", r_ewd, r_cnt));
      rt_expect("superseded transmit", 1, cw(5, 1, 0, 1), 1, 0, 0, 0, T1.n_words - base_words[1]);
    end

    // ---- 8. BC receive errors (the BFM is RT 20)
    $display("[%0t] 8. BC errors", $time);
    for (int k = 0; k < 10; k++) begin
      logic [3:0] e;
      int n;
      bus = k[0]; c = cw(20, 1, 2, 3);
      fork
        bc_run(1, bus, c);
        if (k != 1) begin
          bc_tx_end(); f_idle(5);
          case (k)
            0: begin f_word(bus, 1, stw(20)); f_word(bus, 0, 1); f_word(bus, 0, 2); f_word(bus, 0, 3); end
            2: f_word(bus, 1, stw(21));
            3: f_word(bus, 1, stw(20), 1);
            4: f_word(bus, 0, stw(20));
            5: begin f_word(bus, 1, stw(20)); f_word(bus, 0, 1); f_word(bus, 0, 2); end
            6: begin f_word(bus, 1, stw(20)); f_word(bus, 0, 1); f_word(bus, 0, 2); f_word(bus, 0, 3); f_word(bus, 0, 4); end
            7: begin f_word(bus, 1, stw(20)); f_word(bus, 0, 1); f_word(bus, 1, 2); end
            8: begin f_word(bus, 1, stw(20)); f_word(bus, 0, 1); f_word(bus, 0, 2, 0, 9); end
            default: f_word(bus, 1, {5'd20, 11'h7FF});       // every status bit: no data follows
          endcase
          f_idle(1);
        end
      join
      e = k == 0 || k == 9 ? 4'b0000 : k == 1 ? 4'b1000 : k == 2 ? 4'b0100 : k == 3 || k == 4 || k == 8 ? 4'b0010 : 4'b0001;
      n = k == 0 || k == 6 ? 3 : k == 5 ? 2 : k == 7 || k == 8 ? 1 : 0;
      if ({r_enr, r_ead, r_ewd, r_ewc} !== e || r_cnt !== 6'(n))
        fail($sformatf("BC error case %0d: errors %b words %0d", k, {r_enr, r_ead, r_ewd, r_ewc}, r_cnt));
      if (k == 0 && T0.u.ram[2] !== 16'd3) fail("BC from the BFM: data");
      f_idle(20);
    end
    // RT-RT: the receiver does not answer
    fill(1, 5); mark(); c = cw(21, 0, 5, 4); c2 = cw(5, 1, 5, 4);
    bc_run(2, 0, c, c2);
    bc_expect("RT-RT receiver missing", 4'b1000, stw(5), 0, 4);
    // RT-RT with the BFM as the receiving RT 21 (every status bit set)
    fill(1, 5); c = cw(21, 0, 5, 2); c2 = cw(5, 1, 5, 2);
    fork
      bc_run(2, 1, c, c2);
      begin
        @(negedge clk); while (!T1.u.e_act) @(negedge clk);
        while (T1.u.e_act) @(negedge clk);
        f_idle(5); f_word(1, 1, {5'd21, 11'h7FF}); f_idle(1);
      end
    join
    bc_expect("RT-RT to the BFM", 4'b0000, stw(5), {5'd21, 11'h7FF}, 2);
    // a response later than the timeout
    tmo = 2; mark(); c = cw(26, 1, 0, 1);
    bc_run(3, 1, c);
    bc_expect("late response", 4'b1000, 0);
    tmo = 255; c = cw(26, 1, 0, 1); bc_run(3, 0, c); bc_expect("long timeout", 4'b0000, stw(26));
    tmo = 28;
    // a start while the BC is busy is ignored, its bus too
    begin
      int g;
      @(negedge clk);
      bc_type = 3'd3; bc_bus = 0; bc_c1 = cw(26, 1, 0, 2); bc_start = 1;
      @(negedge clk) bc_start = 0;
      cyc(20);
      bc_bus = 1; bc_c1 = cw(5, 1, 0, 2); bc_start = 1;
      @(negedge clk) bc_start = 0; bc_bus = 0;
      g = 0;
      while (!T0.bdone && g < 200000) begin @(negedge clk); g++; end
      r_enr = T0.enr; r_ead = T0.ead; r_ewd = T0.ewd; r_ewc = T0.ewc;
      r_s1 = T0.s1; r_s2 = T0.s2; r_cnt = T0.bcnt;
      cyc(16 * half);
      bc_expect("start while busy", 4'b0000, stw(26));
    end

    // ---- 9. other bit timings: 4, 13 and 255 clocks per half bit
    $display("[%0t] 9. timings", $time);
    for (int k = 0; k < 3; k++) begin
      half = k == 0 ? 4 : k == 1 ? 13 : 255;
      fill(0, 0); fill(2, 9); mark();
      c = cw(26, 0, 9, k == 2 ? 1 : 17); bc_run(0, k[0], c);
      bc_expect("timing BC-RT", 4'b0000, stw(26));
      mem_cmp("timing BC-RT", 2, {1'b0, 5'd9, 5'd0}, 0, {1'b1, 5'd0, 5'd0}, k == 2 ? 1 : 17);
      if (k != 2) begin
        c = cw(5, 0, 9, 9); c2 = cw(26, 1, 9, 9); bc_run(2, 1, c, c2);
        bc_expect("timing RT-RT", 4'b0000, stw(26), stw(5), 9);
        mem_cmp("timing RT-RT", 1, {1'b0, 5'd9, 5'd0}, 2, {1'b1, 5'd9, 5'd0}, 9);
      end
    end
    half = 8;

    // ---- 11. host port: writes and reads, a write colliding with the RT's own write
    $display("[%0t] 11. host port", $time);
    for (int k = 0; k < 4; k++) begin
      logic [10:0] a;
      logic [15:0] d;
      a = k[0] ? 11'h5A5 : 11'h2DA; d = k[1] ? 16'hA5C3 : 16'h5A3C;
      @(negedge clk); T1.haddr = a; T1.hwd = d; T1.hwr = 1;
      @(negedge clk); T1.hwr = 0; T1.hrd = 1;
      @(negedge clk); T1.hrd = 0;
      if (T1.hrdat !== d || T1.u.ram[a] !== d) fail($sformatf("host port: %h at %h", T1.hrdat, a));
    end
    fill(0, 0); mark();
    fork
      bc_run(0, 0, cw(5, 0, 4, 3));
      begin
        // on the RT's second write: a host write to the same word (dropped)
        for (int k = 0; k < 2; k++) begin @(negedge clk); while (!T1.u.mem_wr) @(negedge clk); end
        T1.haddr = T1.u.mem_addr; T1.hwd = 16'hBAD0; T1.hwr = 1;
        @(negedge clk) T1.hwr = 0;
        // and on the third one a host write to another word (kept)
        while (!T1.u.mem_wr) @(negedge clk);
        T1.haddr = 11'h7FF; T1.hwd = 16'h0BAD; T1.hwr = 1;
        @(negedge clk) T1.hwr = 0;
      end
    join
    mem_cmp("host write collision", 1, {1'b0, 5'd4, 5'd0}, 0, {1'b1, 5'd0, 5'd0}, 3);
    if (T1.u.ram[11'h7FF] !== 16'h0BAD) fail("host write next to an RT write");

    // ---- 10. reset in the middle of a message
    $display("[%0t] 10. reset", $time);
    @(negedge clk);
    bc_type = 3'd1; bc_bus = 0; bc_c1 = cw(5, 1, 3, 20); bc_start = 1;
    @(negedge clk) bc_start = 0;
    cyc(4 * 40 * 8); rst_n = 0;
    cyc(3);
    if (|{tap, tan, tbp, tbn} || T0.bbusy || T1.shut || T1.inh || T1.mbc) fail("reset values");
    rst_n = 1; cyc(5);
    // the first message after reset: the RT's status word is clear (no message
    // error, no broadcast received) and so is its last command
    mark(); c = cw(5, 1, 0, 2); bc_run(3, 0, c); bc_expect("status after reset", 4'b0000, stw(5));
    fill(0, 0); mark(); c = cw(5, 0, 1, 2); bc_run(0, 1, c);
    bc_expect("after reset", 4'b0000, stw(5));

    $display("[%0t] TEST PART DONE", $time);
    if (errors == 0) $display("TEST PASSED: MIL_STD_1553");
    else $display("TEST FAILED: MIL_STD_1553 (%0d errors)", errors);
    $finish;
  end
  initial begin
    #500ms;
    $display("TEST FAILED: MIL_STD_1553 (timeout)");
    $finish;
  end
endmodule
