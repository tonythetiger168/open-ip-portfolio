// SPDX-License-Identifier: Apache-2.0
// CCIX_Cache_Coherent_Interconnect_top testbench: the DUT's TLP streams
// face a TB peer (BFM) that plays the other end's link layer.
//  - DUT side: a writer sends random Requests, Snoops and Responses of 1..8
//    words (and, in one phase, bad headers) with gaps; a reader takes the
//    received messages with random back-pressure, down to none.
//  - BFM receive: every TLP the DUT sends is parsed (header words, Tag,
//    Length, last word), its messages checked in order against those
//    written (credit fields aside), Misc messages allowed between them, the
//    credits they return counted; a Request or Snoop received owes the DUT
//    a credit back after a random delay. tlp_tx_ready has random gaps.
//  - BFM send: TLPs of 1..n random messages within its credits, with the
//    credits it owes, Misc messages when idle, word gaps; then every TLP
//    and message error, Requests and Snoops without a credit, Responses
//    with the receive buffer full, credit counts overflowing.
//  - Reset with traffic in flight.
// The bound checker (tb/cov/CCIX_Cache_Coherent_Interconnect_sva.sv)
// checks every output on every clock against its own model.
`timescale 1ns/1ps
module CCIX_Cache_Coherent_Interconnect_tb;
  localparam int MAXP = 16, NREQ = 2, NSNP = 2, RXD = 64, CRT = 16;
  localparam int BQ = 3, BS = 3;                 // credits the BFM grants
  logic clk = 0, rst_n = 0;
  always #5 clk = ~clk;
  int errors = 0;
  task automatic fail(input string s);
    errors++;
    $display("ERROR: %s @%0t", s, $time);
  endtask

  logic [15:0] rid = 16'h0108, tgt_rid = 16'h0210;
  logic        tx_valid = 0, rx_ready = 0, tlp_tx_ready = 0, tlp_rx_valid = 0, tlp_rx_last = 0;
  logic [31:0] tx_data = 0, tlp_rx_data = 0;
  wire         tx_ready, rx_valid, rx_last, tlp_tx_valid, tlp_tx_last;
  wire  [31:0] rx_data, tlp_tx_data;
  wire  [4:0]  tx_crd_req, tx_crd_snp;
  wire         ev_err, ev_nocrd, ev_ovf;
  CCIX_Cache_Coherent_Interconnect_top #(.MAXP(MAXP), .NREQ(NREQ), .NSNP(NSNP), .RXD(RXD), .CRT(CRT)) dut (.*);

  task automatic wait_clk(input int n); repeat (n) @(negedge clk); endtask
  bit both = 0;
  always @(posedge clk) both = tlp_tx_valid && tlp_tx_ready && tlp_rx_valid && dut.rs == 5;

  // ---------------- events ----------------
  int n_err = 0, n_nocrd = 0, n_ovf = 0, x_err = 0, x_nocrd = 0, ovf_left = 0;
  always @(posedge clk) if (rst_n) begin
    if (ev_err) n_err++;
    if (ev_nocrd) n_nocrd++;
    if (ev_ovf) begin n_ovf++; ovf_left++; end
  end

  // ---------------- DUT side: writer ----------------
  logic [31:0] wq [$];                           // words to write
  logic [31:0] eb [$];                           // expected at the BFM
  bit          eb_h [$];                         // ... header word
  int          p_tx = 70, p_rx = 70;
  int          n_wmsg = 0;
  task automatic w_msg(input int ty, input int ln, input bit bad);
    logic [31:0] h;
    h = {4'(ty), 4'(ln), 8'($urandom), 16'($urandom)};
    wq.push_back(h);
    if (!bad) begin
      eb.push_back(h); eb_h.push_back(1);
      for (int i = 1; i < ln; i++) begin
        h = $urandom;
        wq.push_back(h); eb.push_back(h); eb_h.push_back(0);
      end
      n_wmsg++;
    end else x_err++;
  endtask
  task automatic w_rnd();
    w_msg(1 + $urandom % 3, 1 + $urandom % 8, 0);
  endtask
  always @(posedge clk) if (rst_n && tx_valid && tx_ready) void'(wq.pop_front());
  always @(negedge clk) begin
    tx_valid = rst_n && wq.size() != 0 && $urandom % 100 < p_tx;
    tx_data = tx_valid ? wq[0] : $urandom;
    rx_ready = $urandom % 100 < p_rx;
  end

  // ---------------- DUT side: reader ----------------
  logic [31:0] ec [$];                           // expected from the DUT
  bit          ec_s [$], ec_r [$], ec_l [$];     // message start, Response, last word
  int          n_rmsg = 0;
  always @(posedge clk) if (rst_n && rx_valid && rx_ready) begin : b_rd
    bit go;
    go = 1;
    // a Response the DUT skipped (ev_ovf) is not there
    while (go) begin
      if (ec.size() != 0 && ec_s[0] && ec_r[0] && ovf_left > 0 && ec[0] != rx_data) begin
        void'(ec.pop_front()); void'(ec_s.pop_front()); void'(ec_r.pop_front()); void'(ec_l.pop_front());
        while (ec.size() != 0 && !ec_s[0]) begin
          void'(ec.pop_front()); void'(ec_s.pop_front()); void'(ec_r.pop_front()); void'(ec_l.pop_front());
        end
        ovf_left--;
      end else go = 0;
    end
    if (ec.size() == 0) fail($sformatf("message word %h not sent", rx_data));
    else begin
      if (rx_data != ec[0] || rx_last != ec_l[0])
        fail($sformatf("received %h last %0d, expected %h last %0d", rx_data, rx_last, ec[0], ec_l[0]));
      if (ec_l[0]) n_rmsg++;
      void'(ec.pop_front()); void'(ec_s.pop_front()); void'(ec_r.pop_front()); void'(ec_l.pop_front());
    end
  end

  // ---------------- BFM receive ----------------
  int          b_crq = 0, b_csn = 0;             // credits the BFM holds (from the DUT)
  int          b_oq = 0, b_os = 0;               // credits the BFM owes the DUT
  int          b_dq [$];                         // ... owed later: clock it is due, class
  int          b_dc [$];
  int          r_i = 0, r_len = 0, r_ml = 0, r_mi = 0;
  logic [7:0]  r_tag = 0;
  int          n_tlp = 0, n_misc = 0, p_trdy = 80;
  int          now = 0;
  always @(posedge clk) now++;
  always @(negedge clk) tlp_tx_ready = $urandom % 100 < p_trdy;
  always @(posedge clk) if (!rst_n) begin
    r_i = 0; r_ml = 0; r_tag = 0;
  end else if (tlp_tx_valid && tlp_tx_ready) begin : b_rx
    logic [31:0] w, e;
    w = tlp_tx_data;
    case (r_i)
      0: begin
        r_len = w[9:0];
        if (w[31:10] != {8'h72, 14'd0} || r_len == 0 || r_len > MAXP) fail($sformatf("TLP DW0 %h", w));
      end
      1: if (w != {rid, r_tag, 8'h7F}) fail($sformatf("TLP DW1 %h, Tag %h expected", w, r_tag));
      2: if (w != {tgt_rid, 16'h1E2C}) fail($sformatf("TLP DW2 %h", w));
      3: if (w != 0) fail($sformatf("TLP DW3 %h", w));
      default:
        if (r_ml == 0) begin                     // a message header
          r_ml = w[27:24]; r_mi = 1;
          b_crq += w[23:20]; b_csn += w[19:16];
          if (w[31:28] == 0) begin
            n_misc++;
            if (w != {8'h01, w[23:16], 16'h0}) fail($sformatf("Misc %h", w));
            if (w[23:16] == 0) fail("Misc with no credits");
            r_ml = 0;
          end else begin
            if (eb.size() == 0 || !eb_h[0]) fail($sformatf("message %h not written", w));
            else begin
              e = eb[0];
              if ((w & 32'hFF00_FFFF) != (e & 32'hFF00_FFFF)) fail($sformatf("message %h, expected %h", w, e));
              void'(eb.pop_front()); void'(eb_h.pop_front());
            end
            if (w[31:28] == 1 || w[31:28] == 2) begin
              b_dq.push_back(now + $urandom % 40); b_dc.push_back(w[31:28]);
            end
            if (r_ml == 1) r_ml = 0;
          end
        end else begin
          if (eb.size() == 0 || eb_h[0]) fail($sformatf("body word %h not written", w));
          else begin
            e = eb[0];
            if (w != e) fail($sformatf("body word %h, expected %h", w, e));
            void'(eb.pop_front()); void'(eb_h.pop_front());
          end
          r_mi++;
          if (r_mi == r_ml) r_ml = 0;
        end
    endcase
    if (tlp_tx_last != (r_i >= 4 && r_i == r_len + 3)) fail($sformatf("TLP last %0d at word %0d of %0d", tlp_tx_last, r_i, r_len));
    if (r_i >= 4 && r_i == r_len + 3 && r_ml != 0) fail("message runs past the TLP");
    r_i++;
    if (tlp_tx_last) begin r_i = 0; r_ml = 0; r_tag++; n_tlp++; end
  end
  // credits the BFM owes fall due
  always @(posedge clk)
    while (b_dq.size() != 0 && b_dq[0] <= now) begin
      if (b_dc[0] == 1) b_oq++; else b_os++;
      void'(b_dq.pop_front()); void'(b_dc.pop_front());
    end

  // ---------------- BFM send ----------------
  logic [32:0] bq [$];                           // {last, word} to send
  logic [31:0] bp [$];                           // payload being built
  int          p_bgap = 0;
  int          bfm_misc_on = 1, b_idle = 0;
  bit          b_nocr = 0;                       // headers carry no credits (error tests)
  always @(negedge clk) begin
    tlp_rx_valid = 0; tlp_rx_last = 0; tlp_rx_data = $urandom;
    if (rst_n && bq.size() != 0 && $urandom % 100 >= p_bgap) begin : b_tx
      logic [32:0] x;
      x = bq.pop_front();
      tlp_rx_valid = 1; tlp_rx_last = x[32]; tlp_rx_data = x[31:0];
    end
  end
  // a message into bp (expected at the reader unless skip); ty 1 / 2 take a credit
  task automatic b_msg(input int ty, input int ln, input bit nocrd);
    logic [31:0] h;
    logic [3:0]  cq, cs;
    cq = b_oq > 15 ? 15 : b_oq; cs = b_os > 15 ? 15 : b_os;
    if (b_nocr && ty != 0) begin cq = 0; cs = 0; end
    b_oq -= cq; b_os -= cs;
    h = {4'(ty), 4'(ln), cq, cs, 16'($urandom)};
    if (ty == 0) h[15:0] = 0;
    bp.push_back(h);
    if (ty == 1 && !nocrd) b_crq--;
    if (ty == 2 && !nocrd) b_csn--;
    if (nocrd) x_nocrd++;
    if (ty != 0 && !nocrd) begin ec.push_back(h); ec_s.push_back(1); ec_r.push_back(ty == 3); ec_l.push_back(ln == 1); end
    for (int i = 1; i < ln; i++) begin
      h = $urandom;
      bp.push_back(h);
      if (ty != 0 && !nocrd) begin ec.push_back(h); ec_s.push_back(0); ec_r.push_back(ty == 3); ec_l.push_back(i == ln - 1); end
    end
  endtask
  // a TLP of what is in bp
  task automatic b_tlp(input logic [15:0] tgt);
    bq.push_back({1'b0, 8'h72, 14'd0, 10'(bp.size())});
    bq.push_back({1'b0, tgt_rid, 8'($urandom), 8'h7F});
    bq.push_back({1'b0, tgt, 16'h1E2C});
    bq.push_back({1'b0, 32'd0});
    while (bp.size() != 0) begin : b_w
      logic [31:0] w;
      w = bp.pop_front();
      bq.push_back({bp.size() == 0, w});
    end
  endtask
  // a TLP of random messages within the BFM's credits
  task automatic b_rnd();
    int n, used;
    n = 1 + $urandom % 4; used = 0;
    for (int i = 0; i < n; i++) begin : b_m
      int ty, ln;
      ty = 1 + $urandom % 3; ln = 1 + $urandom % 8;
      if (ty == 1 && b_crq == 0 || ty == 2 && b_csn == 0) ty = 3;
      if (used + ln <= MAXP) begin b_msg(ty, ln, 0); used += ln; end
    end
    b_tlp(rid);
  endtask
  // a Misc returning what the BFM owes, once idle for a while
  always @(negedge clk) begin
    if (bq.size() != 0 || !rst_n) b_idle = 0;
    else b_idle++;
    if (bfm_misc_on && b_idle > 24 && (b_oq != 0 || b_os != 0)) begin
      b_msg(0, 1, 0);
      b_tlp(rid);
      b_idle = 0;
    end
  end

  // ---------------- background traffic ----------------
  int bg_w = 0, bg_b = 0, bg_gap = 10;
  bit stop = 0;
  initial forever begin
    @(negedge clk);
    if (!stop && bg_w > 0 && wq.size() < 24) begin w_rnd(); bg_w--; end
    if (!stop && bg_b > 0 && bq.size() < 20 && $urandom % bg_gap == 0) begin b_rnd(); bg_b--; end
  end

  task automatic drain(input string ph);
    int t;
    t = 0;
    while ((bg_w != 0 || bg_b != 0 || wq.size() != 0 || bq.size() != 0 || eb.size() != 0 ||
            ec.size() != 0 && !(ovf_left > 0 && !rx_valid) || r_i != 0) && t < 40000) begin
      @(negedge clk); t++;
    end
    if (t == 40000) fail($sformatf("%s: stuck (wq %0d bq %0d eb %0d ec %0d)", ph, wq.size(), bq.size(), eb.size(), ec.size()));
    wait_clk(60);
    // what is left expected was skipped
    while (ec.size() != 0) begin
      if (!(ec_s[0] && ec_r[0] && ovf_left > 0)) begin
        fail($sformatf("%s: message %h never received", ph, ec[0]));
        ec.delete(); ec_s.delete(); ec_r.delete(); ec_l.delete();
      end else begin
        void'(ec.pop_front()); void'(ec_s.pop_front()); void'(ec_r.pop_front()); void'(ec_l.pop_front());
        while (ec.size() != 0 && !ec_s[0]) begin
          void'(ec.pop_front()); void'(ec_s.pop_front()); void'(ec_r.pop_front()); void'(ec_l.pop_front());
        end
        ovf_left--;
      end
    end
    if (ovf_left != 0) fail($sformatf("%s: %0d Responses skipped beyond those sent", ph, ovf_left));
    ovf_left = 0;
    if (n_err != x_err || n_nocrd != x_nocrd)
      fail($sformatf("%s: events err %0d/%0d nocrd %0d/%0d", ph, n_err, x_err, n_nocrd, x_nocrd));
    $display("%s: %0d messages written, %0d read, %0d TLPs, %0d Misc, %0d skipped", ph, n_wmsg, n_rmsg, n_tlp, n_misc, n_ovf);
  endtask

  // a bad TLP: word k (0..3 header, 4.. payload) replaced by w; c cuts the
  // TLP after word c (0: no cut); the TLP's messages are not expected
  // (k2 / w2: a second word replaced, k2 < 0 for none)
  task automatic b_bad(input int k, input logic [31:0] w, input int k2, input logic [31:0] w2, input int c);
    int n;
    logic [32:0] x;
    b_msg(3, 2, 0);
    for (int i = 0; i < 2; i++) begin
      void'(ec.pop_back()); void'(ec_s.pop_back()); void'(ec_r.pop_back()); void'(ec_l.pop_back());
    end
    b_tlp(rid);
    n = bq.size() - 6;
    x = bq[n + k]; x[31:0] = w; bq[n + k] = x;
    if (k2 >= 0) begin x = bq[n + k2]; x[31:0] = w2; bq[n + k2] = x; end
    if (c > 0) begin
      while (bq.size() > n + c) void'(bq.pop_back());
      x = bq.pop_back(); x[32] = 1; bq.push_back(x);
    end
    x_err++;
  endtask

  initial begin
    wait_clk(3);
    rst_n = 1;
    // the DUT's first Misc grants NREQ / NSNP
    wait_clk(40);
    if (b_crq != NREQ || b_csn != NSNP || n_misc != 1) fail($sformatf("credits at start %0d %0d", b_crq, b_csn));
    // the BFM grants its credits
    b_oq = BQ; b_os = BS;
    wait_clk(40);
    if (tx_crd_req != BQ || tx_crd_snp != BS) fail("tx credits after the BFM's grant");
    // ---- one message of each kind and length each way
    for (int t = 1; t <= 3; t++) for (int l = 1; l <= 8; l++) begin w_msg(t, l, 0); wait_clk(10); end
    drain("DUT messages");
    for (int t = 1; t <= 3; t++) for (int l = 1; l <= 8; l++) begin
      while (t == 1 && b_crq == 0 || t == 2 && b_csn == 0) @(negedge clk);
      b_msg(t, l, 0); b_tlp(rid); wait_clk(10);
    end
    drain("BFM messages");
    rid = 16'hA5C3; tgt_rid = 16'h5A3C;           // every ID bit both ways
    // ---- random traffic both ways
    bg_w = 300; bg_b = 150;
    drain("random");
    rid = ~rid; tgt_rid = ~tgt_rid;
    p_tx = 100; p_rx = 100; p_trdy = 100; bg_gap = 1;
    bg_w = 300; bg_b = 150;
    drain("fast");
    rid = 16'h0108; tgt_rid = 16'h0210;
    p_tx = 30; p_rx = 30; p_trdy = 30; p_bgap = 50; bg_gap = 20;
    bg_w = 100; bg_b = 60;
    drain("slow");
    p_tx = 70; p_rx = 70; p_trdy = 80; p_bgap = 0; bg_gap = 10;
    // a full TLP and one past MAXP that is split
    for (int i = 0; i < 2; i++) w_msg(3, 8, 0);
    for (int i = 0; i < 3; i++) w_msg(3, 8, 0);
    drain("full TLPs");
    // ---- the reader stops: Responses fill the buffer and are skipped,
    // Requests and Snoops still fit; the DUT's credits stay with it
    p_rx = 0;
    for (int i = 0; i < 16; i++) begin
      if (b_crq > 0 && i % 4 == 0) b_msg(1, 8, 0);
      else if (b_csn > 0 && i % 4 == 1) b_msg(2, 8, 0);
      else b_msg(3, 1 + $urandom % 8, 0);
      b_tlp(rid);
      wait_clk(5);
    end
    wait_clk(200);
    if (n_ovf == 0) fail("no Response skipped with the buffer full");
    // Responses up to exactly the room left: with no Request or Snoop
    // buffered, 8 words per credit stay reserved
    p_rx = 70;
    drain("before the room edge");
    p_rx = 0;
    n_ovf = 0;
    for (int i = 0; i < 5; i++) begin b_msg(3, 8, 0); b_tlp(rid); wait_clk(20); end
    if (n_ovf != 1) fail($sformatf("%0d Responses skipped at the room edge, expected 1", n_ovf));
    n_ovf = 0;
    p_rx = 70;
    wait_clk(100);
    ec.delete(); ec_s.delete(); ec_r.delete(); ec_l.delete();
    ovf_left = 0;
    p_rx = 0;
    // a Request and a Snoop with no credit left
    while (b_crq > 0) begin b_msg(1, 2, 0); b_tlp(rid); wait_clk(20); end
    while (b_csn > 0) begin b_msg(2, 1, 0); b_tlp(rid); wait_clk(20); end
    wait_clk(50);
    b_msg(1, 3, 1); b_msg(3, 1, 0); b_msg(2, 1, 1); b_tlp(rid);
    wait_clk(100);
    // a Snoop without a credit cut inside its body
    b_msg(2, 3, 1); b_tlp(rid);
    begin : b_cut
      logic [32:0] x;
      void'(bq.pop_back());
      x = bq.pop_back(); x[32] = 1; bq.push_back(x);
    end
    x_err++;
    wait_clk(50);
    p_rx = 70;
    drain("buffer full, no credit");
    // ---- client headers with a bad MsgType or MsgLen
    w_msg(0, 1, 1); w_msg(1, 0, 1); w_msg(4, 2, 1); w_msg(15, 9, 1); w_msg(3, 9, 1); w_rnd();
    for (int i = 0; i < 3; i++) w_rnd();
    wait_clk(3);
    w_msg(2, 15, 1); w_rnd();
    drain("bad client headers");
    // ---- every TLP and message error
    b_nocr = 1;
    b_bad(0, {8'h70, 14'd0, 10'd2}, -1, 0, 0);       // Fmt / Type
    b_bad(0, {8'h73, 14'd0, 10'd2}, -1, 0, 0);
    b_bad(0, {8'h72, 14'd0, 10'd0}, -1, 0, 0);       // Length 0
    b_bad(0, {8'h72, 14'd0, 10'd17}, -1, 0, 0);      // Length above MAXP
    b_bad(0, {8'h72, 14'd0, 10'd2}, -1, 0, 1);       // last on DW0
    b_bad(1, {tgt_rid, 8'h00, 8'h7E}, -1, 0, 0);     // message code
    b_bad(1, {tgt_rid, 8'h00, 8'hFF}, -1, 0, 0);
    b_bad(1, {tgt_rid, 8'h00, 8'h7F}, -1, 0, 2);     // last on DW1
    b_bad(2, {rid, 16'h1E2D}, -1, 0, 0);             // vendor
    b_bad(2, {rid ^ 16'h0001, 16'h1E2C}, -1, 0, 0);  // target
    b_bad(2, {rid, 16'h1E2C}, -1, 0, 3);             // last on DW2
    b_bad(3, 32'h0000_0100, -1, 0, 0);               // DW3
    b_bad(3, 32'd0, -1, 0, 4);                       // last on DW3
    b_bad(0, {8'h72, 14'd0, 10'd3}, -1, 0, 0);       // Length past the last word
    b_bad(0, {8'h72, 14'd0, 10'd1}, 4, {8'h31, 24'h0}, 0);   // last word missing at Length
    b_bad(4, {4'h4, 4'h2, 24'h0}, -1, 0, 0);         // MsgType
    b_bad(4, {4'h3, 4'h0, 24'h0}, -1, 0, 0);         // MsgLen 0
    b_bad(4, {4'h3, 4'h9, 24'h0}, -1, 0, 0);         // MsgLen 9
    b_bad(4, {4'h3, 4'h3, 24'h0}, -1, 0, 0);         // past the payload
    b_bad(4, {4'h0, 4'h2, 24'h0}, -1, 0, 0);         // Misc of 2 words
    b_bad(4, {4'h3, 4'h2, 24'h0}, -1, 0, 5);         // last inside a message
    b_bad(0, {8'h72, 14'd0, 10'd1}, -1, 0, 0);       // Length shorter than the message
    // MsgLen 9 inside a payload long enough for it
    b_msg(3, 8, 0); b_msg(3, 2, 0);
    for (int i = 0; i < 10; i++) begin
      void'(ec.pop_back()); void'(ec_s.pop_back()); void'(ec_r.pop_back()); void'(ec_l.pop_back());
    end
    b_tlp(rid);
    begin : b_l9
      logic [32:0] x;
      x = bq[bq.size() - 10]; x[27:24] = 4'h9; bq[bq.size() - 10] = x;
    end
    x_err++;
    wait_clk(20);
    b_rnd();
    drain("TLP errors");
    // a good message, then a bad one in the same TLP: the first stays
    b_msg(3, 2, 0);
    b_msg(3, 2, 0);
    for (int i = 0; i < 2; i++) begin
      void'(ec.pop_back()); void'(ec_s.pop_back()); void'(ec_r.pop_back()); void'(ec_l.pop_back());
    end
    b_tlp(rid);
    void'(bq.pop_back()); void'(bq.pop_back());
    bq.push_back({1'b0, 4'h3, 4'h6, 24'h0}); bq.push_back({1'b1, 32'h0});
    x_err++;
    // a Request kept, then a bad message: its credit stays used
    while (b_crq == 0) @(negedge clk);
    b_msg(1, 3, 0); b_msg(3, 2, 0);
    for (int i = 0; i < 2; i++) begin
      void'(ec.pop_back()); void'(ec_s.pop_back()); void'(ec_r.pop_back()); void'(ec_l.pop_back());
    end
    b_tlp(rid);
    begin : b_ext
      logic [32:0] x;
      x = bq.pop_back(); x[32] = 0; bq.push_back(x);
    end
    bq.push_back({1'b1, 32'h0});
    x_err++;
    b_nocr = 0;
    drain("bad message after good ones");
    // ---- reset with traffic in flight
    bg_w = 200; bg_b = 100;
    wait_clk(400);
    begin : b_mid
      int t;
      t = 0;
      // a TLP word each way on the last clock
      while (!both && t < 20000) begin @(negedge clk); t++; end
      if (t == 20000) fail("never receiving and sending at once");
    end
    stop = 1;
    rst_n = 0;
    wait_clk(3);
    wq.delete(); eb.delete(); eb_h.delete(); ec.delete(); ec_s.delete(); ec_r.delete(); ec_l.delete();
    bq.delete(); bp.delete(); b_dq.delete(); b_dc.delete();
    b_crq = 0; b_csn = 0; b_oq = 0; b_os = 0; bg_w = 0; bg_b = 0; ovf_left = 0;
    n_err = 0; n_nocrd = 0; n_ovf = 0; x_err = 0; x_nocrd = 0;
    stop = 0;
    rst_n = 1;
    wait_clk(40);
    if (b_crq != NREQ || b_csn != NSNP) fail($sformatf("credits after reset %0d %0d", b_crq, b_csn));
    b_oq = BQ; b_os = BS;
    bg_w = 100; bg_b = 50;
    drain("after reset");
    // ---- credit counts past 31: the excess is refused
    while (b_oq != 0 || b_os != 0 || b_dq.size() != 0) @(negedge clk);
    wait_clk(40);
    bfm_misc_on = 0;
    b_oq = 12; b_os = 12; b_msg(0, 1, 0); b_tlp(rid);
    b_oq = 2; b_os = 2; b_msg(0, 1, 0); b_tlp(rid);
    b_oq = 15; b_os = 0; b_msg(0, 1, 0); b_tlp(rid);
    x_err++;
    b_oq = 0; b_os = 15; b_msg(0, 1, 0); b_tlp(rid);
    x_err++;
    wait_clk(40);
    if (tx_crd_req != BQ + 14 || tx_crd_snp != BS + 14) fail($sformatf("tx credits %0d %0d after overflow", tx_crd_req, tx_crd_snp));
    drain("credit overflow");
    rst_n = 0;
    wait_clk(3);
    rst_n = 1;
    wait_clk(40);
    if (errors == 0) $display("TEST PASSED: CCIX (%0d messages written, %0d read, %0d TLPs)", n_wmsg, n_rmsg, n_tlp);
    else $display("TEST FAILED: CCIX (%0d errors)", errors);
    $finish;
  end

  initial begin
    #20ms;
    $display("TEST FAILED: CCIX (timeout)");
    $finish;
  end
endmodule
