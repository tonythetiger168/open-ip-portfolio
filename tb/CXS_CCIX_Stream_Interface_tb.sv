// SPDX-License-Identifier: Apache-2.0
// CXS_CCIX_Stream_Interface_top testbench. Part 1: two ports A and B
// joined back to back (A's transmit interface to B's receive interface
// and the other way). Part 2: a TB peer (BFM) takes B's place on one of
// A's interfaces.
//  - writers send packets of 1..12 words (some ending with tx_err) with
//    gaps; readers take them with random back-pressure; every packet is
//    checked word by word, in order, at the other end
//  - the link is activated, deactivated with tx_en (packets in flight),
//    with rx_en (DEACTHINT), and activated again, many times
//  - BFM as A's peer transmitter: activation, credits counted, flits with
//    two packets starting and ending, every START / END error (with and
//    without a packet open), a flit with no word used, a flit without a
//    credit, a credit returned beyond those granted, deactivation with
//    credits returned
//  - BFM as A's peer receiver: more than 15 credits granted; DEACTHINT;
//    the credits returned counted
//  - reset with traffic in flight
// The bound checker (tb/cov/CXS_CCIX_Stream_Interface_sva.sv) checks every
// output of both ports on every clock against its own model.
`timescale 1ns/1ps
module CXS_CCIX_Stream_Interface_tb;
  localparam int RXF = 4;
  logic clk = 0, rst_n = 0;
  always #5 clk = ~clk;
  int errors = 0;
  task automatic fail(input string s);
    errors++;
    $display("ERROR: %s @%0t", s, $time);
  endtask
  task automatic wait_clk(input int n); repeat (n) @(negedge clk); endtask
  bit both = 0;
  always @(posedge clk) both = ctv[0] && rx_valid[0];

  // ---------------- ports: 0 = A, 1 = B ----------------
  logic [1:0]         tx_en = 0, rx_en = 0, tx_valid = 0, tx_last = 0, tx_err = 0, rx_ready = 0;
  logic [1:0][31:0]   tx_data = 0;
  wire  [1:0]         tx_ready, rx_valid, rx_last, rx_err;
  wire  [1:0][31:0]   rx_data;
  wire  [1:0]         ctv, ctrtn, ctreq, crgnt, crack, crhint;
  wire  [1:0][127:0]  ctd;
  wire  [1:0][13:0]   ctc;
  logic [1:0]         i_tgnt, i_tack, i_thint, i_rv, i_rrtn, i_rreq;
  logic [1:0][127:0]  i_rd;
  logic [1:0][13:0]   i_rc;
  wire  [1:0][1:0]    txl, rxl;
  wire  [1:0][3:0]    tcr;
  wire  [1:0]         ev_crd, ev_cntl;
  for (genvar e = 0; e < 2; e++) begin : g_port
    CXS_CCIX_Stream_Interface_top #(.RXF(RXF)) u (
      .clk(clk), .rst_n(rst_n), .tx_en(tx_en[e]), .rx_en(rx_en[e]),
      .tx_valid(tx_valid[e]), .tx_ready(tx_ready[e]), .tx_data(tx_data[e]), .tx_last(tx_last[e]), .tx_err(tx_err[e]),
      .rx_valid(rx_valid[e]), .rx_ready(rx_ready[e]), .rx_data(rx_data[e]), .rx_last(rx_last[e]), .rx_err(rx_err[e]),
      .cxs_tx_valid(ctv[e]), .cxs_tx_data(ctd[e]), .cxs_tx_cntl(ctc[e]), .cxs_tx_crdgnt(i_tgnt[e]),
      .cxs_tx_crdrtn(ctrtn[e]), .cxs_tx_activereq(ctreq[e]), .cxs_tx_activeack(i_tack[e]), .cxs_tx_deacthint(i_thint[e]),
      .cxs_rx_valid(i_rv[e]), .cxs_rx_data(i_rd[e]), .cxs_rx_cntl(i_rc[e]), .cxs_rx_crdgnt(crgnt[e]),
      .cxs_rx_crdrtn(i_rrtn[e]), .cxs_rx_activereq(i_rreq[e]), .cxs_rx_activeack(crack[e]), .cxs_rx_deacthint(crhint[e]),
      .tx_link(txl[e]), .rx_link(rxl[e]), .tx_credits(tcr[e]), .ev_crd(ev_crd[e]), .ev_cntl(ev_cntl[e]));
  end

  // ---------------- wiring, with the BFM in place of B ----------------
  bit          bfm_r = 0, bfm_t = 0;             // BFM drives A's receive / transmit interface
  logic        b_rv = 0, b_rrtn = 0, b_rreq = 0, b_tgnt = 0, b_tack = 0, b_thint = 0;
  logic [127:0] b_rd = 0;
  logic [13:0] b_rc = 0;
  always @* begin
    // A's receive interface: B's transmit interface or the BFM
    i_rv[0] = bfm_r ? b_rv : ctv[1];
    i_rd[0] = bfm_r ? b_rd : ctd[1];
    i_rc[0] = bfm_r ? b_rc : ctc[1];
    i_rrtn[0] = bfm_r ? b_rrtn : ctrtn[1];
    i_rreq[0] = bfm_r ? b_rreq : ctreq[1];
    i_tgnt[1] = bfm_r ? 1'b0 : crgnt[0];
    i_tack[1] = bfm_r ? 1'b0 : crack[0];
    i_thint[1] = bfm_r ? 1'b0 : crhint[0];
    // A's transmit interface: B's receive interface or the BFM
    i_tgnt[0] = bfm_t ? b_tgnt : crgnt[1];
    i_tack[0] = bfm_t ? b_tack : crack[1];
    i_thint[0] = bfm_t ? b_thint : crhint[1];
    i_rv[1] = bfm_t ? 1'b0 : ctv[0];
    i_rd[1] = ctd[0];
    i_rc[1] = ctc[0];
    i_rrtn[1] = bfm_t ? 1'b0 : ctrtn[0];
    i_rreq[1] = bfm_t ? 1'b0 : ctreq[0];
  end

  // ---------------- events ----------------
  int n_crd = 0, n_cntl = 0, x_crd = 0, x_cntl = 0;
  always @(posedge clk) if (rst_n) begin
    n_crd += ev_crd[0] + ev_crd[1];
    n_cntl += ev_cntl[0] + ev_cntl[1];
  end

  // ---------------- writers and readers ----------------
  // words {err, last, data}; queue d0 / x0: A writes, B reads; d1 / x1:
  // B writes, A reads (or the BFM's packets, x1)
  logic [33:0] w0 [$], w1 [$], x0 [$], x1 [$];
  int          p_tx = 70, p_rx = 70, n_pkt = 0, n_wd = 0;
  longint      f_dp = -1;                        // forced data word (directed)
  task automatic w_pkt(input int e, input int n);
    logic [33:0] x;
    bit er;
    er = $urandom % 5 == 0;
    for (int i = 0; i < n; i++) begin
      x = {i == n - 1 && er, i == n - 1, f_dp >= 0 ? 32'(f_dp) : 32'($urandom)};
      if (e == 0) begin w0.push_back(x); x0.push_back(x); end
      else begin w1.push_back(x); x1.push_back(x); end
    end
    n_pkt++;
  endtask
  always @(posedge clk) if (rst_n) begin
    if (tx_valid[0] && tx_ready[0]) void'(w0.pop_front());
    if (tx_valid[1] && tx_ready[1]) void'(w1.pop_front());
  end
  always @(negedge clk) begin : b_drive
    logic [33:0] x;
    tx_valid[0] = rst_n && w0.size() != 0 && $urandom % 100 < p_tx;
    x = tx_valid[0] ? w0[0] : {$urandom, $urandom};
    tx_data[0] = x[31:0]; tx_last[0] = x[32]; tx_err[0] = x[33];
    tx_valid[1] = rst_n && w1.size() != 0 && $urandom % 100 < p_tx;
    x = tx_valid[1] ? w1[0] : {$urandom, $urandom};
    tx_data[1] = x[31:0]; tx_last[1] = x[32]; tx_err[1] = x[33];
    rx_ready[0] = $urandom % 100 < p_rx;
    rx_ready[1] = $urandom % 100 < p_rx;
  end
  always @(posedge clk) if (rst_n) begin : b_read
    logic [33:0] x;
    if (rx_valid[1] && rx_ready[1]) begin
      if (x0.size() == 0) fail($sformatf("B: word %h not sent", rx_data[1]));
      else begin
        x = x0.pop_front();
        if ({rx_err[1], rx_last[1], rx_data[1]} != x) fail($sformatf("B: %h, expected %h", {rx_err[1], rx_last[1], rx_data[1]}, x));
      end
      n_wd++;
    end
    if (rx_valid[0] && rx_ready[0]) begin
      if (x1.size() == 0) fail($sformatf("A: word %h not sent", rx_data[0]));
      else begin
        x = x1.pop_front();
        if ({rx_err[0], rx_last[0], rx_data[0]} != x) fail($sformatf("A: %h, expected %h", {rx_err[0], rx_last[0], rx_data[0]}, x));
      end
      n_wd++;
    end
  end

  // ---------------- background ----------------
  int bg_n = 0, bg_max = 12;
  bit stop = 0;
  initial forever begin
    @(negedge clk);
    if (!stop && bg_n > 0 && w0.size() < 30 && w1.size() < 30) begin
      w_pkt($urandom % 2, 1 + $urandom % bg_max);
      bg_n--;
    end
  end

  task automatic drain(input string ph);
    int t;
    t = 0;
    while ((bg_n != 0 || w0.size() != 0 || w1.size() != 0 || x0.size() != 0 || x1.size() != 0) && t < 50000) begin
      @(negedge clk); t++;
    end
    if (t == 50000) fail($sformatf("%s: stuck (w %0d %0d x %0d %0d)", ph, w0.size(), w1.size(), x0.size(), x1.size()));
    wait_clk(20);
    if (n_crd != x_crd || n_cntl != x_cntl) fail($sformatf("%s: events crd %0d/%0d cntl %0d/%0d", ph, n_crd, x_crd, n_cntl, x_cntl));
    $display("%s: %0d packets, %0d words", ph, n_pkt, n_wd);
  endtask
  task automatic wait_link(input int e, input int tl, input int rl);
    int t;
    t = 0;
    while ((txl[e] != tl || rxl[1 - e] != rl) && t < 5000) begin @(negedge clk); t++; end
    if (t == 5000) fail($sformatf("link %0d never reached %0d / %0d", e, tl, rl));
  endtask

  // ---------------- BFM: A's peer transmitter ----------------
  int b_cr = 0;                                  // credits A granted the BFM
  always @(posedge clk) if (bfm_r && crgnt[0]) b_cr++;
  // a flit: words d, CNTL c
  task automatic bf_flit(input logic [127:0] d, input logic [13:0] c, input bit crd);
    if (crd) begin
      while (b_cr == 0) @(negedge clk);
      b_cr--;
    end else x_crd++;
    b_rv = 1; b_rd = d; b_rc = c;
    @(negedge clk);
    b_rv = 0; b_rd = {$urandom, $urandom, $urandom, $urandom}; b_rc = $urandom;
  endtask
  // CNTL: starts s (0..2) at p0 / p1, ends n at q0 / q1, errors ee
  function automatic logic [13:0] cn(input int s, input int p0, input int p1, input int n, input int q0, input int q1, input int ee);
    return {s == 2, s != 0, 2'(p0), 2'(p1), n == 2, n != 0, 2'(q0), 2'(q1), 2'(ee)};
  endfunction
  // expect the words of a flit: used words w (bit mask), ends m, errors r
  task automatic bf_exp(input logic [127:0] d, input logic [3:0] w, input logic [3:0] m, input logic [3:0] r);
    for (int i = 0; i < 4; i++) if (w[i]) x1.push_back({r[i], m[i], d[32 * i +: 32]});
  endtask
  task automatic bf_good(input logic [13:0] c, input logic [3:0] w, input logic [3:0] m, input logic [3:0] r);
    logic [127:0] d;
    d = {$urandom, $urandom, $urandom, $urandom};
    bf_exp(d, w, m, r);
    bf_flit(d, c, 1);
  endtask
  task automatic bf_bad(input logic [13:0] c, input bit open);
    bf_flit({$urandom, $urandom, $urandom, $urandom}, c, 1);
    if (open) x1.push_back({1'b1, 1'b1, 32'd0});
    x_cntl++;
  endtask

  initial begin
    wait_clk(3);
    rst_n = 1;
    wait_clk(3);
    // ---- activation: A's transmit side first, then B's
    tx_en[0] = 1;
    wait_clk(10);
    if (txl[0] != 1) fail("A not in ACTIVATE with B's receive side off");
    rx_en = 2'b11;
    wait_link(0, 2, 2);
    tx_en[1] = 1;
    wait_link(1, 2, 2);
    // ---- traffic
    for (int n = 1; n <= 12; n++) begin w_pkt(0, n); w_pkt(1, n); end
    drain("lengths");
    bg_n = 300;
    drain("random");
    // each data pattern both ways
    for (int k = 0; k < 4; k++) begin
      f_dp = k == 0 ? 32'h0000_0000 : k == 1 ? 32'hFFFF_FFFF : k == 2 ? 32'h5555_5555 : 32'hAAAA_AAAA;
      for (int i = 0; i < 3; i++) begin w_pkt(0, 4); w_pkt(1, 4); end
      drain("data patterns");
    end
    f_dp = -1;
    p_tx = 100; p_rx = 100; bg_n = 300;
    drain("fast");
    bg_max = 2; bg_n = 300;
    drain("short packets");
    bg_max = 12; p_tx = 30; p_rx = 30; bg_n = 100;
    drain("slow");
    p_tx = 70; p_rx = 70;
    // ---- deactivation with tx_en, packets in flight, and again
    for (int k = 0; k < 6; k++) begin
      bg_n = 40;
      wait_clk(50 + $urandom % 100);
      tx_en[k % 2] = 0;
      wait_clk(20 + $urandom % 60);
      tx_en[k % 2] = 1;
    end
    drain("tx_en off and on");
    // a whole cycle: STOP after the credits came back
    tx_en[0] = 0;
    wait_link(0, 0, 0);
    if (tcr[0] != 0) fail("credits held in STOP");
    tx_en[0] = 1;
    wait_link(0, 2, 2);
    // ---- DEACTHINT: B's receive side off, A deactivates and waits
    for (int k = 0; k < 4; k++) begin
      bg_n = 40;
      wait_clk(50 + $urandom % 100);
      rx_en[(k + 1) % 2] = 0;
      wait_clk(100 + $urandom % 100);
      if (txl[k % 2] != 1) fail("transmit side not waiting in ACTIVATE");
      rx_en[(k + 1) % 2] = 1;
    end
    drain("rx_en off and on");

    // ---- BFM as A's peer transmitter
    tx_en[1] = 0;
    wait_link(1, 0, 0);
    bfm_r = 1;
    b_cr = 0;
    b_rreq = 1;
    while (!crack[0]) @(negedge clk);
    wait_clk(10);
    if (b_cr != RXF) fail($sformatf("A granted %0d credits", b_cr));
    // two packets in a flit, a packet open across flits, END_ERROR
    bf_good(cn(2, 0, 2, 2, 1, 3, 2), 4'b1111, 4'b1010, 4'b1000);
    bf_good(cn(1, 0, 0, 1, 0, 0, 1), 4'b0001, 4'b0001, 4'b0001);
    bf_good(cn(1, 1, 0, 0, 0, 0, 0), 4'b1110, 4'b0000, 4'b0000);
    bf_good(cn(0, 0, 0, 0, 0, 0, 0), 4'b1111, 4'b0000, 4'b0000);
    bf_good(cn(1, 2, 0, 1, 0, 0, 0), 4'b1101, 4'b0001, 4'b0000);   // word 1 not used
    bf_good(cn(1, 1, 0, 2, 0, 2, 0), 4'b0111, 4'b0101, 4'b0000);   // word 3 not used
    drain("BFM flits");
    // errors, with no packet open, then with one open
    x_crd = 0; x_cntl = 0; n_crd = 0; n_cntl = 0;
    bf_bad(cn(0, 0, 0, 0, 0, 0, 0) | 14'h2000, 0);       // START[1] without START[0]
    bf_bad(cn(1, 0, 0, 1, 0, 0, 0) | 14'h0080, 0);       // END[1] without END[0]
    bf_bad(cn(0, 0, 0, 1, 2, 0, 0), 0);                  // END with no packet
    bf_bad(cn(0, 0, 0, 0, 0, 0, 0), 0);                  // no word used
    bf_bad(cn(2, 2, 1, 2, 2, 3, 0), 0);                  // START1 before START0
    bf_bad(cn(1, 0, 0, 2, 3, 1, 0), 0);                  // END1 before END0
    bf_bad(cn(2, 0, 2, 2, 1, 3, 0) & ~14'h1000, 0);      // START[1] without START[0], else good
    bf_bad(cn(2, 0, 2, 2, 1, 3, 0) & ~14'h0040, 0);      // END[1] without END[0], else good
    bf_good(cn(1, 3, 0, 0, 0, 0, 0), 4'b1000, 4'b0000, 4'b0000);   // a packet open
    bf_bad(cn(1, 1, 0, 0, 0, 0, 0), 1);                  // START with it open
    bf_good(cn(1, 0, 0, 0, 0, 0, 0), 4'b1111, 4'b0000, 4'b0000);
    bf_bad(cn(1, 0, 0, 1, 0, 0, 0), 1);                  // END and START on its words
    bf_good(cn(1, 2, 0, 0, 0, 0, 0), 4'b1100, 4'b0000, 4'b0000);
    bf_bad(cn(0, 0, 0, 2, 1, 1, 0), 1);                  // END twice on a word
    // a flit without a credit, a credit returned beyond those granted
    while (b_cr != RXF || x1.size() != 0) @(negedge clk);
    p_rx = 0;
    bf_good(cn(1, 0, 0, 1, 0, 0, 0), 4'b0001, 4'b0001, 4'b0000);
    bf_good(cn(1, 0, 0, 1, 1, 0, 0), 4'b0011, 4'b0010, 4'b0000);
    bf_good(cn(1, 0, 0, 1, 2, 0, 0), 4'b0111, 4'b0100, 4'b0000);
    bf_good(cn(1, 0, 0, 1, 3, 0, 0), 4'b1111, 4'b1000, 4'b0000);
    wait_clk(10);
    bf_flit(0, cn(1, 0, 0, 1, 0, 0, 0), 0);
    p_rx = 70;
    drain("BFM errors");
    // deactivation: the BFM returns what it holds, then one more
    b_rreq = 0;
    wait_clk(5);
    if (rxl[0] != 3) fail("A's receive side not in DEACTIVATE");
    while (b_cr > 0) begin
      b_rrtn = 1; b_cr--;
      @(negedge clk);
      b_rrtn = 0;
      if ($urandom % 2) @(negedge clk);
    end
    wait_clk(3);
    if (crack[0]) fail("ACTIVEACK held with no credit out");
    b_rrtn = 1; x_crd++;
    @(negedge clk);
    b_rrtn = 0;
    // a flit with no link
    bf_flit(0, cn(1, 0, 0, 1, 0, 0, 0), 0);
    drain("BFM deactivation");
    bfm_r = 0;
    tx_en[1] = 1;
    wait_link(1, 2, 2);

    // ---- BFM as A's peer receiver
    tx_en[0] = 0;
    wait_link(0, 0, 0);
    bfm_t = 1;
    tx_en[0] = 1;
    while (!ctreq[0]) @(negedge clk);
    b_tack = 1;
    wait_clk(3);
    for (int i = 0; i < 16; i++) begin b_tgnt = 1; @(negedge clk); end
    b_tgnt = 0;
    x_crd++;
    wait_clk(3);
    if (tcr[0] != 15) fail($sformatf("A holds %0d credits", tcr[0]));
    // ACTIVEACK falls while A is in RUN: A stays there, then, with tx_en
    // clear, goes through DEACTIVATE to STOP and drops what it holds
    b_tack = 0;
    wait_clk(3);
    if (txl[0] != 2) fail("A left RUN on ACTIVEACK falling");
    tx_en[0] = 0;
    wait_clk(3);
    if (txl[0] != 0 || tcr[0] != 0) fail($sformatf("A in %0d with %0d credits", txl[0], tcr[0]));
    tx_en[0] = 1;
    while (!ctreq[0]) @(negedge clk);
    b_tack = 1;
    wait_clk(3);
    for (int i = 0; i < 15; i++) begin b_tgnt = 1; @(negedge clk); end
    b_tgnt = 0;
    wait_clk(3);
    // DEACTHINT: A deactivates and returns all 15; a packet written
    // meanwhile waits in the flit for the next RUN
    b_thint = 1;
    wait_clk(2);
    w_pkt(0, 1);
    begin : b_ret
      int n, t;
      n = 0; t = 0;
      while (ctreq[0] && t < 100) begin @(negedge clk); t++; end
      while (t < 100) begin if (ctrtn[0]) n++; @(negedge clk); t++; end
      if (n != 15) fail($sformatf("A returned %0d credits", n));
    end
    // ACTIVEACK still up when A is in STOP: A waits for it to fall
    tx_en[0] = 0;
    b_thint = 0; b_tack = 0;
    wait_clk(3);
    if (txl[0] != 0) fail("A not in STOP");
    b_tack = 1;
    tx_en[0] = 1;
    wait_clk(5);
    if (txl[0] != 0) fail("A left STOP with ACTIVEACK up");
    b_tack = 0;
    wait_clk(3);
    if (txl[0] != 1) fail("A not activating again");
    bfm_t = 0;
    wait_link(0, 2, 2);
    drain("BFM receiver");

    // ---- reset with traffic in flight
    bg_n = 200;
    wait_clk(300);
    begin : b_mid
      int t;
      t = 0;
      while (!both && t < 20000) begin @(negedge clk); t++; end
      if (t == 20000) fail("never sending and receiving at once");
    end
    stop = 1;
    rst_n = 0;
    wait_clk(3);
    w0.delete(); w1.delete(); x0.delete(); x1.delete();
    bg_n = 0; stop = 0;
    rst_n = 1;
    wait_link(0, 2, 2);
    wait_link(1, 2, 2);
    bg_n = 50;
    drain("after reset");
    if (errors == 0) $display("TEST PASSED: CXS (%0d packets, %0d words)", n_pkt, n_wd);
    else $display("TEST FAILED: CXS (%0d errors)", errors);
    $finish;
  end

  initial begin
    #20ms;
    $display("TEST FAILED: CXS (timeout)");
    $finish;
  end
endmodule
