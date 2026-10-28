// SPDX-License-Identifier: Apache-2.0
// PCIe_top testbench. Part 1: two ends A and B cross-connected through
// symbol channels that can flip, drop or turn symbols into K symbols.
// Part 2: end A against a TB link partner (BFM) that sends any packet,
// good or not, and watches what A sends.
//  - host drivers write TLPs of random length (some longer than MAXLEN, so
//    the core cuts them) with gaps, and read with random back-pressure
//  - receive scoreboards: every TLP written at one end must come out at the
//    other exactly once, in order, whatever the channel did (the link
//    replays), until the link drops
//  - errors: bad LCRC, dropped TLPs, nullified and bad EDB TLPs, lost start
//    and end symbols, K symbols inside packets, bad DLLPs, Acks lost long
//    enough for the replay timer and a retrain; from the BFM: duplicates,
//    sequence numbers ahead, short / long TLPs and DLLPs, Acks behind and
//    ahead, reserved bits, unknown DLLPs, overflow, the three ways out of
//    FC2, finite and infinite credits, Naks without progress (retrain)
// The bound checker (tb/cov/PCIe_sva.sv) checks every output of both ends
// on every clock.
`timescale 1ns/1ps
module PCIe_tb;
  localparam int MAXLEN = 32, TXN = 4, RXN = 4, REPLAY_TO = 600;
  localparam logic [7:0] STP = 8'hFB, SDP = 8'h5C, ENDS = 8'hFD, EDB = 8'hFE;
  logic clk = 0, rst_n = 0;
  always #5 clk = ~clk;
  int errors = 0;
  task automatic fail(input string s);
    errors++;
    $display("ERROR: %s @%0t", s, $time);
  endtask

  // ---------------- ends: index 0 = A, 1 = B ----------------
  logic [1:0]      link = 0, tlp_valid = 0, tlp_last = 0, rx_ready = 0;
  logic [1:0][7:0] tlp_data = 0;
  logic [1:0]      pm_req = 0, aspm_ok = 2'b11;
  wire  [1:0][1:0] pm_state;
  wire  [1:0][7:0] tx_sym, rx_data;
  wire  [1:0]      tx_k, tlp_ready, rx_valid, rx_last, dl_up, retrain;
  wire  [1:0]      ev_tlp_bad, ev_tlp_seq, ev_tlp_dup, ev_tlp_null, ev_overflow, ev_dllp_bad, ev_dllp_proto;
  wire  [1:0]      ev_frame, ev_nak, ev_replay;
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

  PCIe_top #(.MAXLEN(MAXLEN), .TXN(TXN), .RXN(RXN), .REPLAY_TO(REPLAY_TO), .DP(3)) u_a (
    .clk(clk), .rst_n(rst_n), .link_up(link[0]), .tx_sym(tx_sym[0]), .tx_k(tx_k[0]), .rx_sym(rs0), .rx_k(rk0),
    .tlp_valid(tlp_valid[0]), .tlp_ready(tlp_ready[0]), .tlp_data(tlp_data[0]), .tlp_last(tlp_last[0]),
    .rx_valid(rx_valid[0]), .rx_ready(rx_ready[0]), .rx_data(rx_data[0]), .rx_last(rx_last[0]),
    .dl_up(dl_up[0]), .retrain(retrain[0]), .ev_tlp_bad(ev_tlp_bad[0]), .ev_tlp_seq(ev_tlp_seq[0]),
    .ev_tlp_dup(ev_tlp_dup[0]), .ev_tlp_null(ev_tlp_null[0]), .ev_overflow(ev_overflow[0]),
    .ev_dllp_bad(ev_dllp_bad[0]), .ev_dllp_proto(ev_dllp_proto[0]), .ev_frame(ev_frame[0]), .ev_nak(ev_nak[0]),
    .ev_replay(ev_replay[0]), .pm_req(pm_req[0]), .aspm_ok(aspm_ok[0]), .pm_state(pm_state[0]));
  PCIe_top #(.MAXLEN(MAXLEN), .TXN(TXN), .RXN(RXN), .REPLAY_TO(REPLAY_TO), .DP(3)) u_b (
    .clk(clk), .rst_n(rst_n), .link_up(link[1]), .tx_sym(tx_sym[1]), .tx_k(tx_k[1]), .rx_sym(rs1), .rx_k(rk1),
    .tlp_valid(tlp_valid[1]), .tlp_ready(tlp_ready[1]), .tlp_data(tlp_data[1]), .tlp_last(tlp_last[1]),
    .rx_valid(rx_valid[1]), .rx_ready(rx_ready[1]), .rx_data(rx_data[1]), .rx_last(rx_last[1]),
    .dl_up(dl_up[1]), .retrain(retrain[1]), .ev_tlp_bad(ev_tlp_bad[1]), .ev_tlp_seq(ev_tlp_seq[1]),
    .ev_tlp_dup(ev_tlp_dup[1]), .ev_tlp_null(ev_tlp_null[1]), .ev_overflow(ev_overflow[1]),
    .ev_dllp_bad(ev_dllp_bad[1]), .ev_dllp_proto(ev_dllp_proto[1]), .ev_frame(ev_frame[1]), .ev_nak(ev_nak[1]),
    .ev_replay(ev_replay[1]), .pm_req(pm_req[1]), .aspm_ok(aspm_ok[1]), .pm_state(pm_state[1]));

  // ---------------- CRCs ----------------
  function automatic logic [15:0] dcrc(input logic [31:0] d);
    logic [15:0] c;
    c = '1;
    for (int i = 31; i >= 0; i--) c = {c[14:0], 1'b0} ^ ((c[15] ^ d[i]) ? 16'h100B : 16'h0);
    return c;
  endfunction

  // ---------------- host drivers ----------------
  // what end p must deliver: {last, byte} written at the other end
  logic [8:0] exp0 [$];
  logic [8:0] exp1 [$];
  int         wlen [0:1], wcnt [0:1], wgap [0:1], nrx [0:1];
  bit         wen [0:1], wtk [0:1];
  int         gap_max = 40, len_min = 1, len_max = 40, rdy_pct [0:1];
  bit         bulk = 0;                // every TLP a write with data: P, NP or Cpl
  bit         wrapd [0:1][0:2];        // data credits allocated wrapped past 4095
  logic [11:0] cadp [0:1][0:2];
  always @(negedge clk)
    for (int i = 0; i < 3; i++) begin
      if (u_a.cad[i] < cadp[0][i]) wrapd[0][i] = 1;
      if (u_b.cad[i] < cadp[1][i]) wrapd[1][i] = 1;
      cadp[0][i] = u_a.cad[i]; cadp[1][i] = u_b.cad[i];
    end
  initial for (int p = 0; p < 2; p++) begin
    wlen[p] = 0; wcnt[p] = 0; wgap[p] = 0; nrx[p] = 0; wen[p] = 0; wtk[p] = 0; rdy_pct[p] = 100;
  end
  // takes, sampled on the posedge
  always @(posedge clk)
    for (int p = 0; p < 2; p++) begin
      if (tlp_valid[p] && tlp_ready[p]) begin : b_take
        logic [8:0] e;
        wcnt[p]++;
        e = {tlp_last[p] || wcnt[p] % MAXLEN == 0, tlp_data[p]};
        if (p == 0) exp1.push_back(e); else exp0.push_back(e);
        wtk[p] = 1;
      end
      // (a read as the link drops is of a buffer being emptied)
      if (rx_valid[p] && rx_ready[p] && link[p]) begin : b_read
        logic [8:0] e;
        if ((p == 0 ? exp0.size() : exp1.size()) == 0) fail($sformatf("end %0d: byte %h never written", p, rx_data[p]));
        else begin
          e = p == 0 ? exp0.pop_front() : exp1.pop_front();
          if ({rx_last[p], rx_data[p]} !== e) fail($sformatf("end %0d: byte %b %h, expected %b %h", p, rx_last[p], rx_data[p], e[8], e[7:0]));
          if (rx_last[p]) nrx[p]++;
        end
      end
    end
  always @(negedge clk)
    for (int p = 0; p < 2; p++) begin
      if (wtk[p]) begin
        wtk[p] = 0; tlp_valid[p] = 0;
        if (tlp_last[p]) begin wcnt[p] = 0; wgap[p] = $urandom % (gap_max + 1); end
      end
      // a TLP once begun is finished even when writing stops
      if (!tlp_valid[p] && (wen[p] || wcnt[p] != 0)) begin
        if (wgap[p] > 0) wgap[p]--;
        else if ($urandom % 8 != 0) begin
          if (wcnt[p] == 0) wlen[p] = len_min + $urandom % (len_max - len_min + 1);
          tlp_valid[p] = 1; tlp_data[p] = $urandom; tlp_last[p] = wcnt[p] + 1 == wlen[p];
          if (bulk && wcnt[p] == 0) tlp_data[p] = $urandom % 3 == 0 ? 8'h40 : $urandom % 2 ? 8'h44 : 8'h4A;
        end
      end
      rx_ready[p] = ($urandom % 100) < rdy_pct[p];
    end
  // the link drops: the core forgets everything
  always @(negedge clk)
    for (int p = 0; p < 2; p++)
      if (!link[p] || !rst_n) begin
        // A's link: its receive buffer and A's written TLPs are lost; B's
        // link: the same for B (A's TLPs from the BFM stay)
        if (p == 0) begin exp0.delete(); exp1.delete(); end
        else begin exp1.delete(); if (!bfm) exp0.delete(); end
        if (!tlp_valid[p] || !link[p]) wcnt[p] = 0;
        tlp_valid[p] = 0;
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
  task automatic bdllp(input logic [7:0] b0, b1, b2, b3, input bit bad = 0);
    logic [15:0] c;
    c = ~dcrc({b0, b1, b2, b3}) ^ (bad ? 16'h0001 : 16'h0);
    bq.push_back({1'b1, SDP}); bq.push_back({1'b0, b0}); bq.push_back({1'b0, b1}); bq.push_back({1'b0, b2});
    bq.push_back({1'b0, b3}); bq.push_back({1'b0, c[15:8]}); bq.push_back({1'b0, c[7:0]}); bq.push_back({1'b1, ENDS});
    bq.push_back(9'h000);
  endtask
  task automatic back(input bit nak, input logic [11:0] seq, input logic [7:0] resv = 0);
    bdllp(nak ? 8'h10 : 8'h00, resv, {4'd0, seq[11:8]}, seq[7:0]);
  endtask
  // flow control DLLP t (type in bits 5:4), hdr header and dat data credits
  task automatic bfc(input logic [7:0] t, input logic [7:0] hdr, input logic [11:0] dat = 0);
    bdllp(t, {2'b00, hdr[7:2]}, {hdr[1:0], 2'b00, dat[11:8]}, dat[7:0]);
  endtask
  // the same for P, NP and Cpl
  task automatic bfc3(input logic [7:0] t, input logic [7:0] hdr, input logic [11:0] dat = 0);
    for (int i = 0; i < 3; i++) bfc(t | 8'(i << 4), hdr, dat);
  endtask
  // a TLP of n random bytes; mode 0 good, 1 bad LCRC, 2 nullified, 3 EDB
  // with a good LCRC; accept: A must deliver it; fb: the first byte (its
  // credit type), random when negative
  int bseq = 0;
  task btlp(input logic [11:0] seq, input int n, input int mode = 0, input bit accept = 0, input int fb = -1);
    logic [7:0]  b [$];
    logic [31:0] c;
    logic [7:0]  x;
    b.delete();
    b.push_back({4'd0, seq[11:8]}); b.push_back(seq[7:0]);
    for (int i = 0; i < n; i++) b.push_back(8'($urandom));
    if (fb >= 0) b[2] = 8'(fb);
    c = '1;
    for (int j = 0; j < b.size(); j++) begin
      x = b[j];
      for (int i = 7; i >= 0; i--) c = {c[30:0], 1'b0} ^ ((c[31] ^ x[i]) ? 32'h04C1_1DB7 : 32'h0);
    end
    if (mode != 2) c = ~c;
    if (mode == 1) c ^= 32'h0100;
    bq.push_back({1'b1, STP});
    foreach (b[i]) bq.push_back({1'b0, b[i]});
    for (int i = 3; i >= 0; i--) bq.push_back({1'b0, c[8 * i +: 8]});
    bq.push_back({1'b1, mode >= 2 ? EDB : ENDS});
    if (accept) for (int i = 2; i < b.size(); i++) exp0.push_back({i == b.size() - 1, b[i]});
    bq.push_back(9'h000);
    // a random type: idle until A has read it out, so that the next one
    // finds credit for whatever type it is
    if (fb < 0) repeat (n) bq.push_back(9'h000);
  endtask
  // A's transmissions: TLP sequence numbers and DLLPs seen
  int         a_tlps = 0, a_last_seq = -1, a_dllps = 0;
  logic [7:0] a_dllp [4];
  bit         b_autoack = 0;
  int         a_cnt = -1;
  logic [7:0] a_pk [$];
  always @(posedge clk) if (bfm) begin
    if (tx_k[0]) begin
      if (tx_sym[0] == ENDS && a_cnt >= 0) begin
        if (a_pk.size() == 6) begin
          for (int i = 0; i < 4; i++) a_dllp[i] = a_pk[i];
          a_dllps++;
        end else begin
          begin logic [7:0] h; h = a_pk[0]; a_last_seq = {h[3:0], a_pk[1]}; end
          a_tlps++;
          if (b_autoack) back(0, a_last_seq);
        end
      end
      a_cnt = tx_sym[0] == STP || tx_sym[0] == SDP ? 0 : -1;
      a_pk.delete();
    end else if (a_cnt >= 0) a_pk.push_back(tx_sym[0]);
  end
  task automatic wait_dllp(input logic [7:0] t, input int n = 4000);
    int k;
    k = 0;
    @(negedge clk);
    while (!(tx_k[0] && tx_sym[0] == ENDS && a_pk.size() == 6 && a_pk[0] == t) && k < n) begin @(negedge clk); k++; end
    if (k >= n) fail($sformatf("A sent no DLLP %h", t));
    @(negedge clk);
  endtask

  // ---------------- helpers ----------------
  task automatic wait_clk(input int n);
    repeat (n) @(negedge clk);
  endtask
  task automatic wait_up(input int p, input int n = 3000);
    int t;
    t = 0;
    while (!dl_up[p] && t < n) begin @(negedge clk); t++; end
    if (!dl_up[p]) fail($sformatf("end %0d: link not up", p));
  endtask
  // writing paused: all written TLPs delivered both ways
  task automatic drain(input int n = 20000);
    int t;
    bit w [0:1];
    w[0] = wen[0]; w[1] = wen[1]; wen[0] = 0; wen[1] = 0;
    t = 0;
    while ((exp0.size() != 0 || exp1.size() != 0 || wcnt[0] != 0 || wcnt[1] != 0) && t < n) begin @(negedge clk); t++; end
    if (exp0.size() != 0 || exp1.size() != 0) begin
      fail($sformatf("not drained: %0d %0d bytes", exp0.size(), exp1.size()));
      for (int i = 0; i < 3; i++)
        $display("  A t%0d hcl %0d hcc %0d dcl %0d dcc %0d | B cah %0d cad %0d rch %0d rcd %0d", i, u_a.hcl[i], u_a.hcc[i],
                 u_a.dcl[i], u_a.dcc[i], u_b.cah[i], u_b.cad[i], u_b.rch[i], u_b.rcd[i]);
      $display("  A wr %0d nsent %0d ackd %0d tst %0d pst %0d dls %0d | B dls %0d pst %0d nrs %0d", u_a.wr_seq, u_a.nsent,
               u_a.ackd, u_a.tst, u_a.pst, u_a.dls, u_b.dls, u_b.pst, u_b.nrs);
      $display("  B wr %0d nsent %0d ackd %0d tst %0d tlp_valid %b ready %b | A nrs %0d rx_valid %b ackp %b",
               u_b.wr_seq, u_b.nsent, u_b.ackd, u_b.tst, tlp_valid[1], tlp_ready[1], u_a.nrs, rx_valid[0], u_a.ack_p);
      for (int i = 0; i < 3; i++)
        $display("  B t%0d hcl %0d hcc %0d dcl %0d dcc %0d | A cah %0d cad %0d rch %0d rcd %0d", i, u_b.hcl[i], u_b.hcc[i],
                 u_b.dcl[i], u_b.dcc[i], u_a.cah[i], u_a.cad[i], u_a.rch[i], u_a.rcd[i]);
    end
    wen[0] = w[0]; wen[1] = w[1];
  endtask
  // channel d: act on symbol k (0 = the start symbol) of the next packet
  // starting with start (STP or SDP)
  task automatic at_pkt(input int d, input logic [7:0] start, input int k);
    while (!(d == 0 ? tx_k[0] && tx_sym[0] == start : tx_k[1] && tx_sym[1] == start)) @(negedge clk);
    wait_clk(k);
  endtask
  task automatic hit(input int d, input logic [7:0] x, input bit kf = 0);
    xs[d] = x; xk[d] = kf; @(negedge clk); xs[d] = 0; xk[d] = 0;
  endtask
  // drop the next packet starting with start on channel d
  task automatic drop_pkt(input int d, input logic [7:0] start);
    at_pkt(d, start, 0);
    dr[d] = 1;
    @(negedge clk);
    while (!(d == 0 ? tx_k[0] && (tx_sym[0] == ENDS) : tx_k[1] && tx_sym[1] == ENDS)) @(negedge clk);
    @(negedge clk);
    dr[d] = 0;
  endtask
  // wait until end p is in ASPM state st
  task automatic pm_wait(input int p, input int st, input int n = 3000);
    int t;
    t = 0;
    while (pm_state[p] != 2'(st) && t < n) begin @(negedge clk); t++; end
    if (pm_state[p] != 2'(st)) fail($sformatf("end %0d: pm_state %0d, expected %0d", p, pm_state[p], st));
  endtask
  task automatic link_cycle;
    @(negedge clk);
    link = 0;
    wait_clk(5);
  endtask

  initial begin
    wait_clk(3);
    rst_n = 1;
    wait_clk(5);
    // ================= part 1: A <-> B =================
    link = 2'b11;
    wait_up(0); wait_up(1);
    wen[0] = 1; wen[1] = 1;
    wait_clk(30000);
    // short TLPs, no gaps: sequence numbers and credits wrap
    len_max = 4; gap_max = 0;
    while (nrx[1] < 4300 || nrx[0] < 4300) @(negedge clk);
    len_max = 40; gap_max = 40;
    // B stops reading: A runs out of credit, then goes on
    rdy_pct[1] = 0;
    wait_clk(4000);
    rdy_pct[1] = 30;
    wait_clk(4000);
    rdy_pct[1] = 100;
    drain();

    // ---- bulk data: 32-byte writes of every type wrap the data credit
    // counters
    bulk = 1; len_min = MAXLEN; len_max = MAXLEN; gap_max = 0;
    for (int i = 0; i < 3; i++) begin wrapd[0][i] = 0; wrapd[1][i] = 0; end
    while (!(wrapd[0][0] && wrapd[0][1] && wrapd[0][2] && wrapd[1][0] && wrapd[1][1] && wrapd[1][2])) @(negedge clk);
    wait_clk(200);
    bulk = 0; len_min = 1; len_max = 40; gap_max = 40;
    drain();

    // ---- A -> B: bad TLPs; B -> A: bad DLLPs; the link replays
    for (int i = 0; i < 4; i++) begin at_pkt(0, STP, 5 + i); hit(0, 8'h40); wait_clk(300); end   // LCRC
    for (int i = 0; i < 3; i++) begin at_pkt(0, STP, 1 + i); hit(0, 8'h01); wait_clk(300); end   // sequence number
    for (int i = 0; i < 3; i++) begin drop_pkt(0, STP); wait_clk(400); end                       // a lost TLP
    at_pkt(0, STP, 0); while (tx_sym[0] != ENDS) @(negedge clk); hit(0, ENDS ^ EDB, 0);         // EDB
    wait_clk(300);
    // nullified: EDB and the LCRC not inverted
    at_pkt(0, STP, 0);
    while (!(tx_k[0] && tx_sym[0] == ENDS)) begin
      if (u_a.tcnt >= u_a.tlen + 4 && u_a.tst == 2'd2) xs[0] = 8'hFF; else xs[0] = 0;
      @(negedge clk);
    end
    hit(0, ENDS ^ EDB, 0);
    wait_clk(400);
    at_pkt(0, STP, 0); hit(0, 8'h00, 1);                                    // STP lost: END alone
    wait_clk(300);
    at_pkt(0, STP, 4); hit(0, 8'h00, 1);                                    // a K symbol inside
    wait_clk(300);
    for (int i = 0; i < 3; i++) begin at_pkt(1, SDP, 2 + i); hit(1, 8'h10); wait_clk(200); end   // DLLP CRC
    at_pkt(1, SDP, 0); hit(1, 8'h00, 1);                                    // SDP lost
    wait_clk(200);
    at_pkt(1, SDP, 3); hit(1, 8'h00, 1);                                    // a K symbol inside
    wait_clk(200);
    drain();
    // ---- B -> A silent for a while: A's replay timer, B's duplicates, retrain
    wait_clk(100);
    dr[1] = 1;
    wait_clk(6 * REPLAY_TO);
    dr[1] = 0;
    drain();
    // ---- the link drops with traffic going on
    wait_clk(500);
    link_cycle();
    link = 2'b11;
    wait_up(0); wait_up(1);
    wait_clk(3000);
    drain();

    // ---- ASPM L1: both ends ask for L1 whenever idle, with traffic going on
    pm_req = 2'b11;
    wait_clk(20000);
    wen[0] = 0; wen[1] = 0;
    drain();
    pm_wait(0, 2); pm_wait(1, 2);
    wait_clk(200);
    wen[1] = 1;                                 // B writes: both wake
    pm_wait(0, 0);
    wait_clk(1000);
    wen[1] = 0;
    drain();
    pm_wait(0, 2);
    // B refuses: A keeps asking, then gives up
    pm_req = 2'b00;
    wen[0] = 1;
    wait_clk(500);
    wen[0] = 0;
    drain();
    wait_clk(100);
    aspm_ok[1] = 0;
    pm_req[0] = 1;
    wait_clk(300);
    if (pm_state[0] != 2'd1 || pm_state[1] != 2'd0) fail("refused L1 request");
    pm_req[0] = 0;
    aspm_ok[1] = 1;
    wait_clk(50);
    wen[0] = 1; wen[1] = 1;
    wait_clk(2000);

    // ================= part 2: A against the BFM =================
    wen[0] = 0; wen[1] = 0;
    drain();
    link_cycle();
    bfm = 1;
    link[0] = 1;
    // InitFC2 straight away (FC1 -> FC2), infinite credit; UpdateFC ends FC2
    wait_dllp(8'h40);
    bfc3(8'hC0, 8'd0);
    bwait();
    wait_clk(50);
    bfc(8'h40, 8'd3);                           // InitFC1 in FC2: ignored
    back(0, 12'd0);                             // an Ack before the link is up: ignored
    bfc(8'h80, 8'd0);
    bwait();
    wait_up(0);
    bfc(8'h40, 8'd5);                           // InitFC1 and UpdateFC once up: ignored
    bfc(8'h80, 8'd7);
    bwait();
    b_autoack = 1;
    wen[0] = 1;
    wait_clk(2000);
    // TLPs to A: good, duplicate, ahead, bad LCRC, nullified, bad EDB, short,
    // long, K inside
    bseq = 0;
    for (int i = 0; i < 3; i++) begin btlp(bseq, 1 + $urandom % MAXLEN, 0, 1); bseq++; end
    btlp(bseq - 2, 8);                          // duplicate
    btlp(bseq + 1, 8);                          // ahead: Nak
    btlp(bseq, 8, 1);                           // bad LCRC (Nak already sent)
    btlp(bseq, 8, 0, 1); bseq++;                // good: Nak cleared
    btlp(bseq, 8, 1);                           // bad LCRC: Nak
    btlp(bseq, 8, 2);                           // nullified
    btlp(bseq, 8, 3);                           // EDB, LCRC good: bad
    btlp(bseq - 1, 4);                          // duplicate after a Nak
    bq.push_back({1'b1, STP}); bq.push_back(9'h000); bq.push_back(9'h001); bq.push_back(9'h0AA); bq.push_back(9'h055); bq.push_back(9'h011); bq.push_back(9'h022); bq.push_back({1'b1, ENDS}); bq.push_back(9'h000);   // short
    btlp(bseq, MAXLEN + 1);                     // long
    btlp(bseq, MAXLEN, 0, 1); bseq++;           // longest
    bq.push_back({1'b1, STP}); bq.push_back(9'h000); bq.push_back(9'h001); bq.push_back(9'h0AA); bq.push_back({1'b1, SDP}); bq.push_back(9'h000);                           // K inside
    bq.push_back(9'h0FF); bq.push_back({1'b1, ENDS}); bq.push_back({1'b1, 8'hBC}); bq.push_back({1'b1, EDB}); bq.push_back(9'h000);                            // K in idle
    bwait();
    wait_clk(200);
    // DLLPs to A: bad CRC, long, short, K inside, unknown type, reserved
    // bits, Acks behind and ahead, Naks
    bdllp(8'h00, 0, 0, 0, 1);
    bq.push_back({1'b1, SDP}); bq.push_back(9'h000); bq.push_back(9'h000); bq.push_back(9'h000); bq.push_back(9'h000); bq.push_back(9'h011); bq.push_back(9'h022); bq.push_back(9'h033); bq.push_back({1'b1, ENDS}); bq.push_back(9'h000);
    bq.push_back({1'b1, SDP}); bq.push_back(9'h000); bq.push_back(9'h000); bq.push_back(9'h000); bq.push_back(9'h000); bq.push_back(9'h011); bq.push_back({1'b1, ENDS}); bq.push_back(9'h000);
    bq.push_back({1'b1, SDP}); bq.push_back(9'h000); bq.push_back(9'h000); bq.push_back({1'b1, STP}); bq.push_back(9'h000);
    bq.push_back({1'b1, SDP}); bq.push_back(9'h000); bq.push_back(9'h000); bq.push_back(9'h000); bq.push_back(9'h000); bq.push_back(9'h011); bq.push_back(9'h022); bq.push_back({1'b1, 8'hBC}); bq.push_back(9'h000);
    bdllp(8'h30, 0, 0, 0);
    bwait();
    b_autoack = 0;
    wait_clk(300);
    back(0, a_last_seq, 8'h01);                 // reserved bits
    back(0, a_last_seq + 10);                   // ahead
    back(0, a_last_seq - 10);                   // behind
    back(1, a_last_seq);                        // Nak, nothing to replay
    bwait();
    // writing paused: an Ack of the next TLP, not sent yet; Naks of all sent
    // TLPs (nothing to replay, no retrain)
    wen[0] = 0;
    wait_clk(300);
    back(0, u_a.nsent);
    for (int i = 0; i < 5; i++) back(1, u_a.nsent - 12'd1);
    bwait();
    wait_clk(100);
    wen[0] = 1;
    // a Nak with progress: the rest is replayed
    while (u_a.nsent - u_a.ackd - 12'd1 < 12'd2) @(negedge clk);
    back(1, u_a.ackd + 12'd1);
    bwait();
    wait_clk(300);
    // a Nak, then an Ack while A still sends a long TLP: the replay request
    // stays; the Ack frees the slot of the TLP being replayed, which a new
    // TLP must not take while it goes out
    len_min = 24; len_max = MAXLEN + 8;
    for (int i = 0; i < 6; i++) begin
      back(0, u_a.nsent - 12'd1);
      bwait();
      while (!(u_a.tst == 2'd2 && u_a.tcnt == 6'd2 && u_a.tlen >= 6'd24 && u_a.nsent - u_a.ackd - 12'd1 >= 12'd2))
        @(negedge clk);
      back(1, u_a.ackd);
      back(0, u_a.ackd + 12'd1);
      bwait();
      wait_clk(100);
      while (!(u_a.tst == 2'd2 && u_a.tcnt == 6'd2 && u_a.tlen >= 6'd24 && u_a.nsent - u_a.ackd - 12'd1 == 12'd4))
        @(negedge clk);
      back(0, u_a.nsent - 12'd1);
      bwait();
      wait_clk(100);
    end
    len_min = 1; len_max = 40;
    // Naks without progress: replays, the 4th one retrains
    wait_clk(100);
    back(0, u_a.nsent - 12'd1);
    bwait();
    while (!tlp_ready[0]) @(negedge clk);
    wait_clk(400);
    // two Naks without progress, one with: the count starts again
    for (int i = 0; i < 4; i++) begin
      back(1, u_a.ackd + (i == 2 ? 12'd1 : 12'd0));
      bwait();
      wait_clk(150);
    end
    for (int i = 0; i < 5; i++) begin
      back(1, u_a.ackd);
      bwait();
      wait_clk(150);
    end
    b_autoack = 1;
    back(0, a_last_seq);
    bwait();
    wait_clk(1000);
    // overflow: A does not read; RXN + 1 longest TLPs
    rdy_pct[0] = 0;
    wait_clk(100);
    // the buffer full: two Posted messages, a Non-Posted read, a Completion;
    // then a Completion and a Posted message over their header credits
    btlp(bseq, MAXLEN, 0, 1, 8'h10); bseq++;
    btlp(bseq, MAXLEN, 0, 1, 8'h30); bseq++;
    btlp(bseq, MAXLEN, 0, 1, 8'h00); bseq++;
    btlp(bseq, MAXLEN, 0, 1, 8'h0A); bseq++;
    btlp(bseq, 8, 0, 0, 8'h4A);
    btlp(bseq, 8, 0, 0, 8'h70);
    bwait();
    wait_clk(100);
    rdy_pct[0] = 100;
    wait_clk(500);
    // data credits: two 32-byte memory writes take 4 of the 3 Posted data
    // credits; the second is dropped with header credit to spare
    rdy_pct[0] = 0;
    btlp(bseq, MAXLEN, 0, 1, 8'h40); bseq++;
    btlp(bseq, MAXLEN, 0, 0, 8'h60);
    btlp(bseq, 16, 0, 1, 8'h40); bseq++;
    bwait();
    wait_clk(100);
    rdy_pct[0] = 100;
    wait_clk(500);
    btlp(bseq, 5, 0, 1); bseq++;
    bwait();
    wait_clk(300);
    // finite credit: InitFC1 / InitFC2 with 2 headers; UpdateFC raises it
    wen[0] = 0;
    wait_clk(500);
    link_cycle();
    exp0.delete();
    link[0] = 1;
    b_autoack = 0;
    // P: 2 headers, 3 data credits; NP: 2 headers, infinite data; Cpl
    // infinite
    wait_dllp(8'h40);
    bfc(8'h40, 8'd2, 12'd3); bfc(8'h50, 8'd2); bfc(8'h60, 8'd0);
    bwait();
    wait_dllp(8'hC0);
    bfc(8'hC0, 8'd2, 12'd3); bfc(8'hD0, 8'd2); bfc(8'hE0, 8'd0);
    bwait();
    wait_up(0);
    b_autoack = 1;
    wen[0] = 1;
    wait_clk(1500);
    bfc(8'h80, 8'd6, 12'd8); bfc(8'h90, 8'd5);
    bwait();
    wait_clk(1500);
    bfc(8'h80, 8'd20, 12'd60); bfc(8'h90, 8'd40); bfc(8'hA0, 8'd9, 12'd9);
    bwait();
    wait_clk(1500);
    // a TLP ends FC2
    wen[0] = 0;
    wait_clk(500);
    link_cycle();
    exp0.delete();
    link[0] = 1;
    wait_dllp(8'h40);
    bfc(8'h80, 8'd3);                           // UpdateFC in FC1: ignored
    bfc3(8'h40, 8'd8);
    bwait();
    wait_dllp(8'hC0);
    bseq = 0;
    btlp(bseq, 6, 0, 1); bseq++;
    bwait();
    wait_up(0);
    wen[0] = 1;
    wait_clk(2000);
    // ---- ASPM against the BFM (credit enough for the rest)
    bfc3(8'h80, 8'd100, 12'd1000);
    wen[0] = 0;
    wait_clk(400);
    bdllp(8'h24, 0, 0, 0);                      // PM_Request_Ack in L0: ignored
    bwait();
    // A asks (twice), the BFM acknowledges; a request in L1 is acknowledged
    // again; an Ack wakes A, which asks again
    pm_req[0] = 1;
    wait_dllp(8'h23); wait_dllp(8'h23);
    bdllp(8'h24, 0, 0, 0);
    bwait();
    pm_wait(0, 2);
    bdllp(8'h23, 0, 0, 0);
    wait_dllp(8'h24);
    if (pm_state[0] != 2'd2) fail("L1 left on a request");
    back(0, a_last_seq);
    bwait();
    pm_wait(0, 1);
    // crossed requests: the BFM's request while A asks
    bdllp(8'h23, 0, 0, 0);
    wait_dllp(8'h24);
    pm_wait(0, 2);
    // a TLP received wakes A
    btlp(bseq, 6, 0, 1); bseq++;
    bwait();
    pm_wait(0, 0, 50);
    pm_wait(0, 1);
    bdllp(8'h24, 0, 0, 0);
    bwait();
    pm_wait(0, 2);
    // a write wakes A; a write while A asks stops asking
    wen[0] = 1;
    pm_wait(0, 0, 50);
    wen[0] = 0;
    pm_wait(0, 1);
    wen[0] = 1;
    pm_wait(0, 0, 50);
    wait_clk(300);
    wen[0] = 0;
    // A asks and withdraws
    pm_wait(0, 1);
    pm_req[0] = 0;
    pm_wait(0, 0, 5);
    // refused: aspm_ok low, or A not idle
    aspm_ok[0] = 0;
    wait_clk(200);
    bdllp(8'h23, 0, 0, 0);
    bwait();
    aspm_ok[0] = 1;
    wait_clk(50);
    if (pm_state[0] != 2'd0) fail("L1 entered with aspm_ok low");
    // a TLP waiting to be read: the BFM's request enters L1, reading wakes A
    rdy_pct[0] = 0;
    btlp(bseq, 9, 0, 1); bseq++;
    bwait();
    wait_clk(100);
    bdllp(8'h23, 0, 0, 0);
    wait_dllp(8'h24);
    pm_wait(0, 2);
    rdy_pct[0] = 100;
    pm_wait(0, 0, 50);
    wait_clk(200);
    wen[0] = 1;
    wait_clk(500);

    // ---- reset while up
    @(negedge clk);
    rst_n = 0;
    wait_clk(3);
    rst_n = 1;
    bfm = 0; b_autoack = 0;
    wen[0] = 0;
    link = 2'b11;
    wait_up(0); wait_up(1);
    wen[0] = 1; wen[1] = 1;
    wait_clk(3000);
    wen[0] = 0; wen[1] = 0;
    drain();

    if (errors == 0) $display("TEST PASSED: PCIe");
    else $display("TEST FAILED: PCIe (%0d errors)", errors);
    $finish;
  end

  initial begin
    #60ms;
    $display("TEST FAILED: PCIe (timeout)");
    $finish;
  end
endmodule
