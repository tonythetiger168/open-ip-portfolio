// SPDX-License-Identifier: Apache-2.0
// USB3_2_top testbench. Part 1: two ends A and B cross-connected through
// symbol channels that can flip, drop or turn symbols into K symbols, with
// an LTSSM stand-in that drops and raises both links whenever an end asks
// for recovery. Part 2: end A against a TB link partner (BFM) that sends
// any packet or link command, good or not, and watches what A sends.
//  - host writers write packets (DPs with 0..MAXD payload bytes, other
//    header packets, short headers that get padded, writes longer than a
//    buffer that get cut) with gaps; readers read with random back-pressure
//  - receive scoreboards: every packet written at one end must come out at
//    the other exactly once, in order, across retries and recoveries; a
//    packet whose payload the channel broke comes out as its header with
//    rx_err (allowed only while payload faults are injected)
//  - faults: header packet bytes, link control words, K symbols inside,
//    one or both link command copies, payload bytes and end sets, lost
//    packets and LRTYs, three LBADs in a row, links dropped mid-payload,
//    long read stalls (credit timer); from the BFM: every protocol error
//    the layer checks for
// The bound checker (tb/cov/USB3_2_sva.sv) checks every output of both
// ends on every clock.
`timescale 1ns/1ps
module USB3_2_tb;
  localparam int MAXD = 32, TXN = 4, RXN = 4, PEND_TO = 400, CRED_TO = 2000, PL = 12 + MAXD;
  localparam logic [7:0] SHP = 8'hFB, SDP = 8'h5C, ENDS = 8'hFD, EDB = 8'h7C, SLC = 8'hDC, EPF = 8'hF7;
  logic clk = 0, rst_n = 0;
  always #5 clk = ~clk;
  int errors = 0;
  task automatic fail(input string s);
    errors++;
    $display("ERROR: %s @%0t", s, $time);
  endtask

  // ---------------- ends: index 0 = A, 1 = B ----------------
  logic [1:0]      link = 0, tx_valid = 0, tx_last = 0, rx_ready = 0;
  logic [1:0][7:0] tx_data = 0;
  wire  [1:0][7:0] tx_sym, rx_data;
  wire  [1:0]      tx_k, tx_ready, rx_valid, rx_last, rx_err, ll_up, recovery;
  wire  [1:0]      ev_hp_bad, ev_seq, ev_lc_bad, ev_dpp_bad, ev_frame, ev_proto, ev_overflow, ev_lbad, ev_timeout;
  // channels: d = 0 A -> B, d = 1 B -> A; flip bits, flip K, drop (idle)
  logic [1:0][7:0] xs = 0;
  logic [1:0]      xk = 0, dr = 0;
  // BFM in place of B on A's receive side
  bit              bfm = 0;
  logic [7:0]      b_sym = 0;
  logic            b_k = 0;
  wire  [7:0]      rs0 = bfm ? b_sym : dr[1] ? 8'h00 : tx_sym[1] ^ xs[1];
  wire             rk0 = bfm ? b_k : dr[1] ? 1'b0 : tx_k[1] ^ xk[1];
  wire  [7:0]      rs1 = dr[0] ? 8'h00 : tx_sym[0] ^ xs[0];
  wire             rk1 = dr[0] ? 1'b0 : tx_k[0] ^ xk[0];

  USB3_2_top #(.MAXD(MAXD), .TXN(TXN), .RXN(RXN), .PEND_TO(PEND_TO), .CRED_TO(CRED_TO)) u_a (
    .clk(clk), .rst_n(rst_n), .link_up(link[0]), .recovery(recovery[0]), .tx_sym(tx_sym[0]), .tx_k(tx_k[0]),
    .rx_sym(rs0), .rx_k(rk0), .tx_valid(tx_valid[0]), .tx_ready(tx_ready[0]), .tx_data(tx_data[0]),
    .tx_last(tx_last[0]), .rx_valid(rx_valid[0]), .rx_ready(rx_ready[0]), .rx_data(rx_data[0]),
    .rx_last(rx_last[0]), .rx_err(rx_err[0]), .ll_up(ll_up[0]), .ev_hp_bad(ev_hp_bad[0]), .ev_seq(ev_seq[0]),
    .ev_lc_bad(ev_lc_bad[0]), .ev_dpp_bad(ev_dpp_bad[0]), .ev_frame(ev_frame[0]), .ev_proto(ev_proto[0]),
    .ev_overflow(ev_overflow[0]), .ev_lbad(ev_lbad[0]), .ev_timeout(ev_timeout[0]));
  USB3_2_top #(.MAXD(MAXD), .TXN(TXN), .RXN(RXN), .PEND_TO(PEND_TO), .CRED_TO(CRED_TO)) u_b (
    .clk(clk), .rst_n(rst_n), .link_up(link[1]), .recovery(recovery[1]), .tx_sym(tx_sym[1]), .tx_k(tx_k[1]),
    .rx_sym(rs1), .rx_k(rk1), .tx_valid(tx_valid[1]), .tx_ready(tx_ready[1]), .tx_data(tx_data[1]),
    .tx_last(tx_last[1]), .rx_valid(rx_valid[1]), .rx_ready(rx_ready[1]), .rx_data(rx_data[1]),
    .rx_last(rx_last[1]), .rx_err(rx_err[1]), .ll_up(ll_up[1]), .ev_hp_bad(ev_hp_bad[1]), .ev_seq(ev_seq[1]),
    .ev_lc_bad(ev_lc_bad[1]), .ev_dpp_bad(ev_dpp_bad[1]), .ev_frame(ev_frame[1]), .ev_proto(ev_proto[1]),
    .ev_overflow(ev_overflow[1]), .ev_lbad(ev_lbad[1]), .ev_timeout(ev_timeout[1]));

  // ---------------- CRCs ----------------
  function automatic logic [15:0] crc16_8(input logic [15:0] c, input logic [7:0] d);
    for (int i = 7; i >= 0; i--) c = {c[14:0], 1'b0} ^ ((c[15] ^ d[i]) ? 16'h100B : 16'h0);
    return c;
  endfunction
  function automatic logic [31:0] crc32_8(input logic [31:0] c, input logic [7:0] d);
    for (int i = 7; i >= 0; i--) c = {c[30:0], 1'b0} ^ ((c[31] ^ d[i]) ? 32'h04C1_1DB7 : 32'h0);
    return c;
  endfunction
  function automatic logic [15:0] w5(input logic [10:0] info);
    logic [4:0] c;
    c = 5'h1F;
    for (int i = 10; i >= 0; i--) c = {c[3:0], 1'b0} ^ ((c[4] ^ info[i]) ? 5'h05 : 5'h00);
    return {~c, info};
  endfunction

  // ---------------- LTSSM stand-in ----------------
  // on recovery from either end: both links down for a few clocks, then up
  bit auto_rec = 0;
  int rec_t = 0, n_rec = 0;
  always @(negedge clk) if (auto_rec) begin
    if (rec_t > 0) begin rec_t--; if (rec_t == 0) link = 2'b11; end
    else if ((recovery[0] || recovery[1]) && link == 2'b11) begin link = 0; rec_t = 4 + $urandom % 12; n_rec++; end
  end

  // ---------------- host drivers and scoreboards ----------------
  // what end p must deliver: {last, byte} of the packets written at the
  // other end (header padded to 12 bytes, a DP's payload after it)
  logic [8:0] exp0 [$];
  logic [8:0] exp1 [$];
  logic [7:0] wbuf [0:1][0:127];
  int         wn [0:1], wpos [0:1], wgap [0:1], nrx [0:1], nerr [0:1];
  bit         wen [0:1], wtk [0:1];
  int         gap_max = 30, rdy_pct [0:1], wmode = 0;   // wmode 1: long writes only
  bit         allow_err = 0;
  int         drop_err [0:1];                       // payloads cut by a link drop, per receiving end
  initial begin drop_err[0] = 0; drop_err[1] = 0; end
  always @(posedge clk) begin
    if (!link[0] && u_a.dcol) drop_err[0]++;
    if (!link[1] && u_b.dcol) drop_err[1]++;
  end
  initial for (int p = 0; p < 2; p++) begin
    wn[p] = 0; wpos[p] = 0; wgap[p] = 0; nrx[p] = 0; nerr[p] = 0; wen[p] = 0; wtk[p] = 0; rdy_pct[p] = 100;
  end
  // a packet of the unit written at end p, from byte s, l bytes: expected
  // at the other end
  task expect_pkt(input int p, input int s, input int l);
    logic [8:0] e;
    int n;
    n = wbuf[p][s][4:0] == 5'b01000 && l > 12 ? l : 12;
    for (int i = 0; i < n; i++) begin
      e = {i == n - 1, i < l ? wbuf[p][s + i] : 8'h00};
      if (p == 0) exp1.push_back(e); else exp0.push_back(e);
    end
  endtask
  // a new write unit at end p
  task new_unit(input int p);
    int r, s;
    r = $urandom % 100;
    if (wmode == 1 || r < 4) wn[p] = PL + 1 + $urandom % 20;          // cut
    else if (r < 70) wn[p] = 12 + $urandom % (MAXD + 1);               // DP
    else wn[p] = 1 + $urandom % 16;                                    // other / short
    for (int i = 0; i < wn[p]; i++) wbuf[p][i] = $urandom;
    if (r < 70 || wmode == 1) wbuf[p][0][4:0] = 5'b01000;
    else if (wbuf[p][0][4:0] == 5'b01000) wbuf[p][0][4:0] = 5'b00100;
    s = 0;
    while (wn[p] - s > PL) begin expect_pkt(p, s, PL); s += PL; end
    expect_pkt(p, s, wn[p] - s);
  endtask
  // takes and reads, sampled on the posedge
  always @(posedge clk)
    for (int p = 0; p < 2; p++) begin
      if (tx_valid[p] && tx_ready[p]) wtk[p] = 1;
      if (rx_valid[p] && rx_ready[p]) begin : b_read
        logic [8:0] e;
        if ((p == 0 ? exp0.size() : exp1.size()) == 0) fail($sformatf("end %0d: byte %h never written", p, rx_data[p]));
        else begin
          e = p == 0 ? exp0.pop_front() : exp1.pop_front();
          if (rx_err[p]) begin
            if (rx_data[p] !== e[7:0]) fail($sformatf("end %0d: header byte %h, expected %h", p, rx_data[p], e[7:0]));
            // a broken payload: the header alone, the rest of the packet skipped
            if (rx_last[p]) begin
              while (!e[8] && (p == 0 ? exp0.size() : exp1.size()) != 0) e = p == 0 ? exp0.pop_front() : exp1.pop_front();
              nerr[p]++; nrx[p]++;
              if (drop_err[p] > 0) drop_err[p]--;
              else if (!allow_err) fail($sformatf("end %0d: rx_err without payload faults", p));
            end
          end else begin
            if ({rx_last[p], rx_data[p]} !== e) fail($sformatf("end %0d: byte %b %h, expected %b %h", p, rx_last[p], rx_data[p], e[8], e[7:0]));
            if (rx_last[p]) nrx[p]++;
          end
        end
      end
    end
  always @(negedge clk)
    for (int p = 0; p < 2; p++) begin
      if (wtk[p]) begin
        wtk[p] = 0; tx_valid[p] = 0; wpos[p]++;
        if (wpos[p] == wn[p]) begin wpos[p] = 0; wgap[p] = $urandom % (gap_max + 1); end
      end
      // a unit once begun is finished even when writing stops
      if (!tx_valid[p] && (wen[p] || wpos[p] != 0) && rst_n) begin
        if (wgap[p] > 0) wgap[p]--;
        else if ($urandom % 8 != 0) begin
          if (wpos[p] == 0) new_unit(p);
          tx_valid[p] = 1; tx_data[p] = wbuf[p][wpos[p]]; tx_last[p] = wpos[p] == wn[p] - 1;
        end
      end
      rx_ready[p] = ($urandom % 100) < rdy_pct[p];
    end

  // ---------------- BFM ----------------
  // sends queued symbols (data 00 when there are none); watches A
  logic [8:0] bq [$];
  always @(negedge clk) begin
    if (bq.size() != 0) {b_k, b_sym} = bq.pop_front();
    else {b_k, b_sym} = 9'h000;
  end
  task automatic bwait;
    while (bq.size() != 0) @(negedge clk);
    @(negedge clk);
  endtask
  task automatic bos(input logic [7:0] s);
    bq.push_back({1'b1, s}); bq.push_back({1'b1, s}); bq.push_back({1'b1, s}); bq.push_back({1'b1, EPF});
  endtask
  // a link command; bad: bit 0 bad first copy, bit 1 bad second copy
  task automatic blc(input logic [10:0] info, input logic [1:0] bad = 0);
    logic [15:0] w;
    w = w5(info);
    bos(SLC);
    bq.push_back({1'b0, w[15:8]}); bq.push_back({1'b0, w[7:0] ^ {7'd0, bad[0]}});
    bq.push_back({1'b0, w[15:8]}); bq.push_back({1'b0, w[7:0] ^ {7'd0, bad[1]}});
  endtask
  task automatic blgood(input int n); blc(11'(n & 7)); endtask
  task automatic blcrd(input int x); blc(11'h080 | 11'(x & 3)); endtask
  // a header packet: byte 0 h0, the rest random; mode 0 good, 1 bad CRC-16,
  // 2 bad CRC-5, 3 a K symbol inside; accept: A must deliver it (with a
  // payload, if any, given by bdpp)
  logic [7:0] bh [0:11];
  task bhp(input int seq, input logic [7:0] h0, input int mode = 0, input bit accept = 0);
    logic [15:0] c, w;
    bh[0] = h0;
    for (int i = 1; i < 12; i++) bh[i] = $urandom;
    bos(SHP);
    c = 16'hFFFF;
    for (int i = 0; i < 12; i++) begin
      bq.push_back({1'b0, bh[i]}); c = crc16_8(c, bh[i]);
      if (mode == 3 && i == 5) bq.push_back({1'b1, SDP});
    end
    c = ~c ^ (mode == 1 ? 16'h0001 : 16'h0);
    w = w5(11'(seq & 7)) ^ (mode == 2 ? 16'h0800 : 16'h0);
    bq.push_back({1'b0, c[15:8]}); bq.push_back({1'b0, c[7:0]});
    bq.push_back({1'b0, w[15:8]}); bq.push_back({1'b0, w[7:0]});
    if (accept && h0[4:0] != 5'b01000) for (int i = 0; i < 12; i++) exp0.push_back({i == 11, bh[i]});
  endtask
  // a payload of n bytes after a DP header sent with accept: mode 0 good,
  // 1 bad CRC-32, 2 aborted, 3 a K symbol inside, 4 the END set broken,
  // 5 three zero bytes and no CRC; track: A delivers the last DP header with it
  task bdpp(input int n, input int mode = 0, input bit track = 1);
    logic [31:0] c;
    logic [7:0]  x;
    bit          ok;
    ok = mode == 0 && n <= MAXD;
    if (track) for (int i = 0; i < 12; i++) exp0.push_back({i == 11 && !(ok && n > 0), bh[i]});
    bos(SDP);
    if (mode == 5) n = 0;
    c = '1;
    for (int i = 0; i < n; i++) begin
      x = $urandom;
      bq.push_back({1'b0, x}); c = crc32_8(c, x);
      if (track && ok) exp0.push_back({i == n - 1, x});
      if (mode == 3 && i == 1) bq.push_back({1'b1, SHP});
    end
    c = ~c ^ (mode == 1 ? 32'h0000_0100 : 32'h0);
    if (mode == 5) for (int i = 0; i < 3; i++) bq.push_back({1'b0, 8'h00});
    else for (int i = 3; i >= 0; i--) bq.push_back({1'b0, c[8 * i +: 8]});
    if (mode == 4) begin bq.push_back({1'b1, ENDS}); bq.push_back({1'b1, ENDS}); bq.push_back({1'b0, 8'h11}); end
    else bos(mode == 2 ? EDB : ENDS);
  endtask
  // A's transmissions: header packet sequence numbers and link commands seen
  int         a_hps = 0, a_last_seq = 0, a_lcs = 0;
  logic [10:0] a_lc = 0;
  bit         b_autoack = 0, b_autocrd = 0;
  int         b_let = 0, b_next = 0, a_cnt = -1, a_kind = 0;    // a_kind 1 HP, 2 LC; b_next: next new packet
  logic [7:0] a_pk [$];
  always @(posedge clk) if (bfm) begin
    if (tx_k[0]) begin
      if (tx_sym[0] == EPF) begin
        a_cnt = 0; a_pk.delete();
        a_kind = a_kind == 3 ? 1 : a_kind == 4 ? 2 : 0;
      end else if (tx_sym[0] == SHP) a_kind = 3;
      else if (tx_sym[0] == SLC) a_kind = 4;
      else a_kind = 0;
    end else if (a_cnt >= 0 && a_kind != 0) begin
      a_pk.push_back(tx_sym[0]);
      if (a_kind == 1 && a_pk.size() == 16) begin
        a_last_seq = tx_sym[0] & 8'h07; a_hps++; a_cnt = -1;
        if (b_autoack) blgood(a_last_seq);
        // a buffer for each new packet (not for one sent again)
        if (b_autocrd && a_last_seq == b_next) begin blcrd(b_let); b_let++; b_next = (b_next + 1) & 7; end
      end
      if (a_kind == 2 && a_pk.size() == 4) begin
        a_lc = {a_pk[0], a_pk[1]} & 16'h07FF; a_lcs++; a_cnt = -1;
      end
    end
  end
  // an advertisement: LGOOD_n, then LCRD_A.. for nc buffers; the BFM's own
  // credit letters follow on
  task automatic badv(input int n, input int nc = 4);
    b_let = nc; b_next = (n + 1) & 7;
    blgood(n);
    for (int i = 0; i < nc; i++) blcrd(i);
  endtask
  task automatic wait_lc(input logic [10:0] info, input int n = 4000);
    int k, c;
    k = 0; c = a_lcs;
    while (!(a_lcs != c && a_lc == info) && k < n) begin
      if (a_lcs != c) c = a_lcs;
      @(negedge clk); k++;
    end
    if (k >= n) fail($sformatf("A sent no link command %h", info));
  endtask

  // ---------------- helpers ----------------
  task automatic wait_clk(input int n);
    repeat (n) @(negedge clk);
  endtask
  task automatic wait_up(input int p, input int n = 3000);
    int t;
    t = 0;
    while (!ll_up[p] && t < n) begin @(negedge clk); t++; end
    if (!ll_up[p]) fail($sformatf("end %0d: link not up", p));
  endtask
  // writing paused: all written packets delivered both ways
  task automatic drain(input int n = 40000);
    int t;
    bit w [0:1];
    w[0] = wen[0]; w[1] = wen[1]; wen[0] = 0; wen[1] = 0;
    t = 0;
    while ((exp0.size() != 0 || exp1.size() != 0 || wpos[0] != 0 || wpos[1] != 0) && t < n) begin @(negedge clk); t++; end
    if (exp0.size() != 0 || exp1.size() != 0) fail($sformatf("not drained: %0d %0d bytes", exp0.size(), exp1.size()));
    wen[0] = w[0]; wen[1] = w[1];
  endtask
  // channel d: wait for the next packet starting with start (its first
  // start symbol), then k more clocks
  task automatic at_pkt(input int d, input logic [7:0] start, input int k);
    @(negedge clk);
    while (!(tx_k[d] && tx_sym[d] == start)) @(negedge clk);
    wait_clk(k);
  endtask
  task automatic hit(input int d, input logic [7:0] x, input bit kf = 0);
    xs[d] = x; xk[d] = kf; @(negedge clk); xs[d] = 0; xk[d] = 0;
  endtask
  // drop n symbols of channel d from the next packet starting with start
  task automatic drop_pkt(input int d, input logic [7:0] start, input int n);
    at_pkt(d, start, 0);
    dr[d] = 1;
    wait_clk(n);
    dr[d] = 0;
  endtask
  task automatic link_cycle(input int n = 5);
    @(negedge clk);
    link = 0;
    wait_clk(n);
    rec_a = 0;
  endtask
  // A asked for recovery (since the last link cycle)
  bit rec_a = 0;
  always @(posedge clk) if (recovery[0]) rec_a = 1;
  task automatic wait_rec(input int n = 20000);
    int k;
    k = 0;
    while (!rec_a && k < n) begin @(negedge clk); k++; end
    if (!rec_a) fail("A did not ask for recovery");
  endtask

  initial begin
    int ns;
    wait_clk(3);
    rst_n = 1;
    wait_clk(5);
    // ================= part 1: A <-> B =================
    auto_rec = 1;
    link = 2'b11;
    wait_up(0); wait_up(1);
    wen[0] = 1; wen[1] = 1;
    wait_clk(30000);
    // no gaps: sequence numbers wrap many times
    gap_max = 0;
    wait_clk(20000);
    gap_max = 30;
    // long writes, cut at the buffer size
    wmode = 1;
    wait_clk(5000);
    wmode = 0;
    // B reads slowly, then stops past the credit timer: A recovers
    rdy_pct[1] = 10;
    wait_clk(3000);
    rdy_pct[1] = 0;
    wait_clk(CRED_TO + 1500);
    rdy_pct[1] = 100;
    drain();
    // ---- bad header packets: LBAD, LRTY, retry
    for (int i = 0; i < 4; i++) begin at_pkt(0, SHP, 5 + i); hit(0, 8'h20); wait_clk(400); end    // CRC-16
    for (int i = 0; i < 2; i++) begin at_pkt(0, SHP, 18 + i); hit(0, 8'h04); wait_clk(400); end   // CRC-5
    at_pkt(0, SHP, 9); hit(0, 8'h00, 1);                                                          // K inside
    wait_clk(400);
    // LRTY lost: B ignores the retries until its pending HP ... A times out
    at_pkt(0, SHP, 6); hit(0, 8'h20);
    while (!u_a.lrty_p) @(negedge clk);
    drop_pkt(0, SLC, 8);
    wait_clk(3 * PEND_TO);
    // three LBADs in a row: recovery
    at_pkt(0, SHP, 6); hit(0, 8'h20);
    for (int i = 0; i < 2; i++) begin
      while (!u_a.lrty_p) @(negedge clk);
      at_pkt(0, SHP, 6); hit(0, 8'h20);
    end
    wait_clk(1000);
    drain();
    // ---- link commands: one copy broken (the other is used), both broken
    for (int i = 0; i < 4; i++) begin at_pkt(1, SLC, 4 + i % 2); hit(1, 8'h01); wait_clk(200); end
    for (int i = 0; i < 4; i++) begin
      at_pkt(1, SLC, 4); hit(1, 8'h01); wait_clk(1); hit(1, 8'h01);
      wait_clk(2 * PEND_TO);
    end
    at_pkt(1, SLC, 5); hit(1, 8'h00, 1);                                                          // K inside
    wait_clk(2 * PEND_TO);
    drain();
    // ---- a lost header packet: the next one is out of order, or A times out
    for (int i = 0; i < 3; i++) begin drop_pkt(0, SHP, 20); wait_clk(2 * PEND_TO); end
    // ---- ordered sets broken
    at_pkt(0, SHP, 1); hit(0, SHP ^ SDP, 0);                                                      // SHP SDP
    wait_clk(400);
    at_pkt(0, SHP, 3); hit(0, EPF ^ SHP, 0);                                                      // four SHPs
    wait_clk(400);
    at_pkt(0, SHP, 2); hit(0, 8'h00, 1);                                                          // a data byte
    wait_clk(400);
    at_pkt(0, SLC, 0); hit(0, 8'h00, 1);                                                          // SLC lost: SLC SLC EPF
    wait_clk(2 * PEND_TO);
    drain();
    // ---- payloads broken: delivered as their header with rx_err
    allow_err = 1;
    for (int i = 0; i < 3; i++) begin at_pkt(0, SDP, 4); hit(0, 8'h80); wait_clk(300); end        // CRC-32
    at_pkt(0, SDP, 4); hit(0, 8'h00, 1);                                                          // K inside
    wait_clk(300);
    at_pkt(0, ENDS, 1); hit(0, ENDS ^ EDB, 0);                                                    // END set mixed
    wait_clk(300);
    at_pkt(0, ENDS, 0); hit(0, ENDS ^ EDB, 0); hit(0, ENDS ^ EDB, 0); hit(0, ENDS ^ EDB, 0);      // aborted
    wait_clk(300);
    at_pkt(0, ENDS, 3); hit(0, 8'h00, 1);                                                         // END END END data
    wait_clk(300);
    at_pkt(0, SDP, 0); hit(0, SDP ^ SHP, 0);                                                      // SDP lost: missing payload
    wait_clk(2 * PEND_TO);
    drain();
    // the link drops while a payload is received
    at_pkt(0, SDP, 6);
    link_cycle(8);
    link = 2'b11;
    wait_clk(1000);
    drain();
    allow_err = 0;
    // ---- B -> A silent for a while: both time out and recover
    wait_clk(100);
    dr[1] = 1;
    wait_clk(3 * PEND_TO);
    dr[1] = 0;
    drain();
    // ---- the links drop with traffic going on
    for (int i = 0; i < 6; i++) begin
      wait_clk(200 + $urandom % 800);
      link_cycle(3 + $urandom % 10);
      link = 2'b11;
    end
    wait_clk(3000);
    drain();

    // ================= part 2: A against the BFM =================
    wen[0] = 0; wen[1] = 0;
    drain();
    auto_rec = 0;
    link_cycle();
    // from reset: sequence numbers start at 0
    rst_n = 0;
    wait_clk(2);
    rst_n = 1;
    bfm = 1;
    link[0] = 1;
    // no advertisement: A times out
    wait_lc(11'h083);
    wait_rec();
    link_cycle();
    link[0] = 1;
    // an advertisement for a packet never sent: recovery
    wait_lc(11'h083);
    blgood(3);
    bwait();
    wait_rec();
    link_cycle();
    link[0] = 1;
    // advertisement: credits A, B (before the LGOOD), then the LGOOD
    wait_lc(11'h083);
    blcrd(0); blcrd(1);
    blgood(7);
    bwait();
    wait_up(0);
    // A sends: LGOODs and LCRDs from the BFM
    b_autoack = 1; b_autocrd = 1; b_let = 2;
    wen[0] = 1;
    wait_clk(3000);
    // header packets to A
    bhp(0, 8'h04, 0, 1);                        // good
    bhp(1, 8'h08, 0, 1); bdpp(10);              // DP
    bhp(2, 8'h08, 0, 1); bdpp(0);               // DP, empty payload
    bhp(3, 8'h08, 0, 1); bdpp(MAXD);            // DP, full payload
    bwait();
    wait_clk(200);
    bhp(4, 8'h04, 1);                           // bad CRC-16: LBAD
    bhp(4, 8'h04);                              // ignored until LRTY
    bhp(5, 8'h08); bdpp(5, 0, 0);               // (and its payload)
    blc(11'h100);                               // LRTY
    blc(11'h100);                               // LRTY again: ignored
    bhp(4, 8'h04, 2);                           // bad CRC-5
    blc(11'h100);
    bhp(4, 8'h04, 3);                           // K inside
    blc(11'h100);
    bwait();
    // an LBAD goes before a pending LGOOD: a good and a bad header packet
    // while A sends a full data packet
    wmode = 1;
    while (!(u_a.tst == 2 && u_a.tdp && u_a.tlen == PL && u_a.tcnt < 4)) @(negedge clk);
    bhp(4, 8'h04, 0, 1);
    bhp(5, 8'h04, 1);
    bwait();
    wmode = 0;
    blc(11'h100);
    bwait();
    wait_clk(200);
    // payloads broken
    allow_err = 1;
    bhp(5, 8'h08, 0, 1); bdpp(8, 1);            // CRC-32
    bhp(6, 8'h08, 0, 1); bdpp(8, 2);            // aborted
    bhp(7, 8'h08, 0, 1); bdpp(MAXD + 1);        // too long
    bhp(0, 8'h08, 0, 1); bdpp(0, 5);            // three zero bytes, no CRC: too short (sequence 0: the bytes before them are zero too)
    bwait();
    wait_clk(200);
    bhp(1, 8'h08, 0, 1); bdpp(8, 3);            // K inside
    bhp(2, 8'h08, 0, 1); bdpp(8, 4);            // END set broken
    bhp(3, 8'h08, 0, 1);                        // payload missing: a header packet first
    for (int i = 0; i < 12; i++) exp0.push_back({i == 11, bh[i]});
    bhp(4, 8'h04, 0, 1);
    bos(SDP); bos(ENDS);                        // a payload no DP header asked for: skipped
    bwait();
    wait_clk(300);
    allow_err = 0;
    // ordered sets and K symbols out of place
    bq.push_back({1'b1, SHP}); bq.push_back({1'b1, SHP}); bq.push_back({1'b0, 8'h00});    // data inside
    bq.push_back({1'b1, SHP}); bq.push_back({1'b1, SDP});                                // mixed
    bos(SHP); bq.push_back({1'b1, SHP});                                                  // too long (EPF then SHP: K in HP)
    bq.push_back({1'b1, SLC}); bq.push_back({1'b1, SLC}); bq.push_back({1'b1, SLC}); bq.push_back({1'b1, SLC});
    bq.push_back({1'b1, EPF});                                                            // K in idle
    bos(SLC); bq.push_back({1'b0, 8'h12}); bq.push_back({1'b1, SDP});                     // K inside an LC
    bwait();
    blc(11'h100);                               // (the K in the HP sent LBAD)
    bwait();
    wait_clk(300);
    // link commands: second copy used, both bad, unknown
    blc(11'h7FF, 2'b01);                        // unknown, from the second copy
    blc(11'h000, 2'b11);                        // both bad
    bwait();
    wait_clk(300);
    // overflow: A does not read; 5 header packets for 4 buffers
    rdy_pct[0] = 0;
    wait_clk(200);
    for (int i = 0; i < 3; i++) bhp(5 + i, 8'h04, 0, 1);
    allow_err = 1;
    bhp(8, 8'h08, 0, 1);                        // payload missing: taken as the next header starts,
    for (int i = 0; i < 12; i++) exp0.push_back({i == 11, bh[i]});
    bhp(9, 8'h04);                              // which then has no buffer
    bhp(9, 8'h08);                              // no buffer: dropped, and its payload missing
    bhp(9, 8'h08); bdpp(4, 0, 0);               // no buffer: dropped, its payload skipped
    bwait();
    wait_clk(100);
    rdy_pct[0] = 100;
    wait_clk(500);
    // A expects 9 again; 10 is out of order: recovery (with A's packets
    // unacknowledged)
    b_autoack = 0;
    while (u_a.t_out < 2) @(negedge clk);
    bhp(10, 8'h04);
    bwait();
    wait_rec();
    // advertisement after recovery: the BFM acknowledges two
    link_cycle();
    link[0] = 1;
    wait_lc(11'h000);                           // A's LGOOD for the last packet it took (8: LGOOD_0)
    bwait();
    badv(u_a.ackd + 2);                         // acknowledges two
    bwait();
    wait_up(0);
    allow_err = 0;
    b_autoack = 1;
    wait_clk(2000);
    // the link drops as A sends again after an LBAD: the advertisement may
    // still acknowledge all A sent before
    b_autoack = 0;
    while (u_a.t_out < 2) @(negedge clk);
    blc(11'h180);
    bwait();
    ns = u_a.nsent;
    while (!(u_a.tst == 2 && u_a.tcur == 4'(u_a.ackd + 1))) @(negedge clk);
    link_cycle();
    link[0] = 1;
    wait_clk(30);
    badv(ns - 1);
    bwait();
    wait_up(0);
    b_autoack = 1;
    wait_clk(2000);
    // credit timer: no LCRDs
    b_autocrd = 0;
    wait_clk(CRED_TO + 2000);
    link_cycle();
    link[0] = 1;
    wait_clk(30);
    badv(u_a.ackd);
    bwait();
    wait_up(0);
    b_autocrd = 1;
    wait_clk(1000);
    // pending timer: no LGOODs
    b_autoack = 0;
    wait_rec();
    link_cycle();
    link[0] = 1;
    wait_clk(30);
    badv(u_a.ackd);                             // acknowledges none: all sent again
    bwait();
    wait_up(0);
    wait_clk(1000);
    // LGOODs and LCRDs out of order
    while (u_a.t_out == 0) @(negedge clk);
    wen[0] = 0;
    blgood(u_a.ackd + 3);
    bwait();
    wait_rec();
    link_cycle(); link[0] = 1; wait_clk(30);
    badv(u_a.nsent - 1); bwait(); wait_up(0);
    while (wpos[0] != 0) @(negedge clk);         // the writer may have been mid-packet
    blcrd(2);                                   // wrong letter
    bwait();
    wait_rec();
    link_cycle(); link[0] = 1; wait_clk(30);
    badv(u_a.nsent - 1, 5);   // one too many
    bwait();
    wait_rec();
    // LBADs: with nothing sent; retry; three in a row
    link_cycle(); link[0] = 1; wait_clk(30);
    badv(u_a.ackd); bwait(); wait_up(0);
    // acknowledge what is outstanding before the pending timer runs out
    for (int k = 0; k < 500 || u_a.t_out != 0; k++)
      if (u_a.t_out != 0) begin blgood(u_a.ackd + 1); bwait(); end
      else @(negedge clk);
    blc(11'h180);                               // nothing sent
    bwait();
    wait_rec();
    link_cycle(); link[0] = 1; wait_clk(30);
    badv(u_a.ackd); bwait(); wait_up(0);
    wen[0] = 1;
    while (u_a.t_out < 2) @(negedge clk);
    blc(11'h180);
    bwait();
    wait_lc(11'h100);
    wait_clk(200);
    blc(11'h180); bwait(); wait_lc(11'h100);
    blc(11'h180); bwait();
    wait_rec();
    // a retry of the oldest acknowledged as it goes out: the writer waits
    // for the slot
    link_cycle(); link[0] = 1; wait_clk(30);
    b_autocrd = 0;                              // (first round: a retry without credit)
    badv(u_a.ackd); bwait(); wait_up(0);
    for (int i = 0; i < 4; i++) begin
      if (i == 1) begin
        // buffers for the packets of the first round, then one per packet
        while (b_next != (u_a.nsent & 7)) begin blcrd(b_let); b_let++; b_next = (b_next + 1) & 7; end
        b_autocrd = 1;
      end
      while (!(u_a.t_out == 4'd4 && u_a.cnext == u_a.nsent && u_a.tst == 2'd0)) @(negedge clk);
      blc(11'h180);
      bwait();
      while (!(u_a.tst == 2'd2 && u_a.tcur == u_a.ackd + 4'd1 && u_a.tcnt == 6'd5)) @(negedge clk);
      blgood(u_a.ackd + 1);
      bwait();
      wait_clk(200);
      for (int j = 0; j < 3; j++) if (u_a.t_out != 0) begin blgood(u_a.ackd + 1); bwait(); end
    end
    b_autoack = 1;
    wait_clk(2000);
    // the link drops during a payload with a full receive buffer read out
    wen[0] = 0;
    rdy_pct[0] = 0;
    allow_err = 1;
    for (int i = 0; i < 3; i++) bhp(u_a.rxs + i, 8'h04, 0, 1);
    bhp(u_a.rxs + 3, 8'h08, 0, 1);
    for (int i = 0; i < 12; i++) exp0.push_back({i == 11, bh[i]});
    bos(SDP); for (int i = 0; i < 6; i++) bq.push_back({1'b0, 8'h33});
    bwait();
    link_cycle();
    rdy_pct[0] = 100;
    wait_clk(500);
    allow_err = 0;
    wen[0] = 1;
    link[0] = 1;
    wait_clk(30);
    badv(u_a.ackd); bwait(); wait_up(0);
    wait_clk(2000);

    // ---- reset while up
    @(negedge clk);
    rst_n = 0;
    exp0.delete(); exp1.delete(); bq.delete();
    wait_clk(3);
    rst_n = 1;
    wait_clk(20);
    wen[0] = 0;

    if (errors == 0) $display("TEST PASSED: USB3_2 (%0d / %0d packets, %0d recoveries)", nrx[0], nrx[1], n_rec);
    else $display("TEST FAILED: USB3_2 (%0d errors)", errors);
    $finish;
  end

  initial begin
    #60ms;
    $display("A: ll %0d t_out %0d cr %0d wr_seq %0d ackd %0d nsent %0d tx_valid %0d wen %0d tst %0d", u_a.ll, u_a.t_out,
             u_a.cr, u_a.wr_seq, u_a.ackd, u_a.nsent, tx_valid[0], wen[0], u_a.tst);
    $display("TEST FAILED: USB3_2 (timeout)");
    $finish;
  end
endmodule
