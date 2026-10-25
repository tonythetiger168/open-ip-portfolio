// SPDX-License-Identifier: Apache-2.0
// UEC_top testbench. Part 1: two PDS ends A and B joined by a network
// model per direction that holds frames back (net_tx_ready), and can drop,
// duplicate, reorder and delay them, with byte gaps on delivery. Part 2:
// end A against a TB peer (BFM) that sends any frame and checks A's.
//  - host writers write packets of 1..MAXP bytes and longer ones that get
//    cut, with gaps; readers read with random back-pressure (down to none,
//    so receive buffers run out and packets are NACKed)
//  - receive scoreboards: every packet written at one end is handed out at
//    the other exactly once, in any order (RUD), whole; the PDC is closed
//    and reopened with new start PSNs (across the PSN wrap)
//  - from the BFM: receive window, cumulative and selective state in ACKs,
//    duplicates, packets past the window, no buffer (NACK), every frame
//    error; A's packets, their retransmission on NACK and timeout, ACKs
//    late, partial, selective and bad, NACKs late and bad
// The bound checker (tb/cov/UEC_sva.sv) checks every output of both ends
// on every clock against its own model.
`timescale 1ns/1ps
module UEC_tb;
  localparam int MAXP = 16, W = 4, RXB = 2, RTO = 256;
  logic clk = 0, rst_n = 0;
  always #5 clk = ~clk;
  int errors = 0;
  task automatic fail(input string s);
    errors++;
    $display("ERROR: %s @%0t", s, $time);
  endtask

  // ---------------- ends: index 0 = A, 1 = B ----------------
  logic [1:0]        en = 0, tx_valid = 0, tx_last = 0, rx_ready = 0, ntr = 0, nrv = 0, nrl = 0;
  logic [1:0][15:0]  spt = 0, spr = 0;
  logic [1:0][7:0]   tx_data = 0, nrd = 0;
  wire  [1:0]        tx_ready, rx_valid, rx_last, ntv, ntl;
  wire  [1:0][7:0]   rx_data, ntd;
  wire  [1:0][2:0]   outst;
  wire  [1:0]        ev_rto, ev_nack, ev_dup, ev_nobuf, ev_proto;
  for (genvar e = 0; e < 2; e++) begin : g_end
    UEC_top #(.MAXP(MAXP), .W(W), .RXB(RXB), .RTO(RTO)) u (
      .clk(clk), .rst_n(rst_n), .enable(en[e]), .start_psn_tx(spt[e]), .start_psn_rx(spr[e]),
      .tx_valid(tx_valid[e]), .tx_ready(tx_ready[e]), .tx_data(tx_data[e]), .tx_last(tx_last[e]),
      .rx_valid(rx_valid[e]), .rx_ready(rx_ready[e]), .rx_data(rx_data[e]), .rx_last(rx_last[e]),
      .net_tx_valid(ntv[e]), .net_tx_ready(ntr[e]), .net_tx_data(ntd[e]), .net_tx_last(ntl[e]),
      .net_rx_valid(nrv[e]), .net_rx_data(nrd[e]), .net_rx_last(nrl[e]), .outstanding(outst[e]),
      .ev_rto(ev_rto[e]), .ev_nack(ev_nack[e]), .ev_dup(ev_dup[e]), .ev_nobuf(ev_nobuf[e]), .ev_proto(ev_proto[e]));
  end

  // ---------------- network ----------------
  // channel d carries end d's frames to end 1 - d (or to the BFM for d = 0
  // with bfm set). Frames are kept as bytes (cb0 / cb1) and lengths (cl0 /
  // cl1); Icarus has no arrays of queues.
  bit         bfm = 0;
  logic [7:0] cb0 [$], cb1 [$];
  int         cl0 [$], cl1 [$];
  logic [7:0] cf [0:1][0:63];                    // frame being captured
  int         cn [0:1];
  int         p_drop = 0, p_dup = 0, p_reord = 0, p_hold = 0, p_gap = 0;   // percent
  int         n_frames [0:1];
  initial for (int d = 0; d < 2; d++) begin cn[d] = 0; n_frames[d] = 0; end
  task automatic ch_push(input int d, input int n);
    for (int i = 0; i < n; i++) if (d == 0) cb0.push_back(cf[d][i]); else cb1.push_back(cf[d][i]);
    if (d == 0) cl0.push_back(n); else cl1.push_back(n);
  endtask
  function automatic int ch_n(input int d);
    return d == 0 ? cl0.size() : cl1.size();
  endfunction
  logic [7:0] df [0:1][0:63];                    // frame being delivered
  // take frame i out of channel d into df (k: keep it there as well)
  task automatic ch_take(input int d, input int i, input bit k, output int n);
    int o;
    o = 0;
    for (int j = 0; j < i; j++) o += d == 0 ? cl0[j] : cl1[j];
    n = d == 0 ? cl0[i] : cl1[i];
    for (int j = 0; j < n; j++) df[d][j] = d == 0 ? cb0[o + j] : cb1[o + j];
    if (!k) begin
      for (int j = 0; j < n; j++) if (d == 0) cb0.delete(o); else cb1.delete(o);
      if (d == 0) cl0.delete(i); else cl1.delete(i);
    end
  endtask
  task automatic ch_clear;
    cb0.delete(); cb1.delete(); cl0.delete(); cl1.delete(); cn[0] = 0; cn[1] = 0;
  endtask
  // capture
  always @(posedge clk)
    for (int d = 0; d < 2; d++) begin
      if (!rst_n || !en[d]) cn[d] = 0;
      else if (ntv[d] && ntr[d]) begin
        cf[d][cn[d]] = ntd[d];
        cn[d]++;
        if (ntl[d]) begin
          n_frames[d]++;
          if (d == 0 && bfm) a_frame(cn[d]);
          else ch_push(d, cn[d]);
          cn[d] = 0;
        end
      end
    end
  // delivery to end 1 - d: one frame at a time
  int         dn [0:1], di [0:1];
  initial for (int d = 0; d < 2; d++) begin dn[d] = 0; di[d] = 0; end
  int         ntr_force = -1;                   // A's net_tx_ready forced (directed)
  always @(negedge clk)
    for (int d = 0; d < 2; d++) begin
      ntr[d] = d == 0 && ntr_force >= 0 ? ntr_force[0] : $urandom % 100 >= p_hold;
      if (!(d == 1 && bfm)) begin
        nrv[1 - d] = 0; nrl[1 - d] = 0;
        if (dn[d] == 0 && ch_n(d) != 0 && $urandom % 4 != 0) begin : b_next
          int i, n;
          bit dup;
          i = $urandom % 100 < p_reord && ch_n(d) > 1 ? 1 + $urandom % (ch_n(d) > 2 ? 2 : 1) : 0;
          dup = $urandom % 100 < p_dup;
          ch_take(d, i, dup, n);
          if ($urandom % 100 >= p_drop) begin dn[d] = n; di[d] = 0; end
        end
        if (dn[d] != 0 && $urandom % 100 >= p_gap) begin
          nrv[1 - d] = 1; nrd[1 - d] = df[d][di[d]]; nrl[1 - d] = di[d] == dn[d] - 1;
          di[d]++;
          if (di[d] == dn[d]) dn[d] = 0;
        end
      end
    end

  // ---------------- host writers and scoreboards ----------------
  // packets each end must hand out: {len, bytes} (xp0 / xp1 for end 0 / 1)
  logic [MAXP*8+4:0] xp0 [$], xp1 [$];
  logic [7:0]        wb [0:1][0:63];
  int                wn [0:1], wpos [0:1], wgap [0:1], nrx [0:1], rdy_pct [0:1], gap_max = 6;
  bit                wen [0:1], wact [0:1], wtk [0:1];
  logic [MAXP*8-1:0] rp [0:1];
  int                rn [0:1];
  initial for (int e = 0; e < 2; e++) begin
    wn[e] = 0; wpos[e] = 0; wgap[e] = 0; nrx[e] = 0; rdy_pct[e] = 100; wen[e] = 0; wact[e] = 0; wtk[e] = 0;
    rn[e] = 0; rp[e] = 0;
  end
  task automatic xpush(input int e, input logic [MAXP*8+4:0] x);
    if (e == 0) xp0.push_back(x); else xp1.push_back(x);
  endtask
  function automatic int xsize(input int e);
    return e == 0 ? xp0.size() : xp1.size();
  endfunction
  task automatic x_clear;
    xp0.delete(); xp1.delete();
  endtask
  function automatic logic [MAXP*8+4:0] pkt(input int l, input logic [MAXP*8-1:0] d);
    return {5'(l), d};
  endfunction
  // a new unit of writes at end e; the packets end 1 - e (or the BFM) must
  // get
  task automatic new_unit(input int e);
    int s, l;
    logic [MAXP*8-1:0] d;
    if ($urandom % 100 < 5) wn[e] = MAXP + 1 + $urandom % 20;
    else if ($urandom % 4 == 0) wn[e] = 1 + $urandom % 3;
    else wn[e] = 1 + $urandom % MAXP;
    for (int i = 0; i < wn[e]; i++) wb[e][i] = $urandom;
    s = 0;
    while (s < wn[e]) begin
      l = wn[e] - s > MAXP ? MAXP : wn[e] - s;
      d = 0;
      for (int i = 0; i < l; i++) d[8 * i +: 8] = wb[e][s + i];
      xpush(1 - e, pkt(l, d));
      s += l;
    end
  endtask
  always @(posedge clk)
    for (int e = 0; e < 2; e++) begin
      if (tx_valid[e] && tx_ready[e] && !(bfm && e == 0)) wtk[e] = 1;
      if (rx_valid[e] && rx_ready[e]) begin
        rp[e][8 * rn[e] +: 8] = rx_data[e];
        rn[e]++;
        if (rx_last[e]) begin : b_pkt
          int k;
          logic [MAXP*8+4:0] x;
          x = pkt(rn[e], rp[e]);
          k = -1;
          for (int i = 0; i < xsize(e) && k < 0; i++) if ((e == 0 ? xp0[i] : xp1[i]) === x) k = i;
          if (k < 0) fail($sformatf("end %0d: packet of %0d bytes %h never written (or twice)", e, rn[e], rp[e]));
          else if (e == 0) xp0.delete(k); else xp1.delete(k);
          nrx[e]++;
          rn[e] = 0; rp[e] = 0;
        end
      end
      if (!rst_n || !en[e]) begin rn[e] = 0; rp[e] = 0; end
    end
  always @(negedge clk)
    for (int e = 0; e < 2; e++) begin
      if (wtk[e]) begin
        wtk[e] = 0; tx_valid[e] = 0; wpos[e]++;
        if (wpos[e] == wn[e]) begin wpos[e] = 0; wact[e] = 0; wgap[e] = $urandom % (gap_max + 1); end
      end
      if (rst_n && !tx_valid[e] && (wen[e] || wact[e])) begin
        if (wgap[e] > 0) wgap[e]--;
        else if ($urandom % 8 != 0) begin
          if (!wact[e]) begin new_unit(e); wact[e] = 1; end
          tx_valid[e] = 1; tx_data[e] = wb[e][wpos[e]]; tx_last[e] = wpos[e] == wn[e] - 1;
        end
      end
      rx_ready[e] = $urandom % 100 < rdy_pct[e];
    end

  // ---------------- BFM ----------------
  // frames to A: a byte queue with frame ends marked {last, byte}
  logic [8:0] bq [$];
  int         b_gap = 0, b_wait = 0;
  always @(negedge clk)
    if (bfm) begin
      nrv[0] = 0; nrl[0] = 0;
      if (b_wait > 0) b_wait--;
      else if (bq.size() != 0 && $urandom % 100 >= b_gap) begin : b_send
        logic [8:0] x;
        x = bq.pop_front();
        nrv[0] = 1; nrd[0] = x[7:0]; nrl[0] = x[8];
      end
    end
  task automatic bwait;
    while (bq.size() != 0) @(negedge clk);
    @(negedge clk);
  endtask
  task automatic b_bytes(input int n, input logic [7:0] t);
    for (int i = 0; i < n; i++) bq.push_back({i == n - 1, i == 0 ? t : 8'($urandom)});
  endtask
  // a DATA frame of l bytes; ok: A must hand it out
  logic [MAXP*8-1:0] b_last_d;
  task automatic bdata(input logic [15:0] psn, input int l, input bit ok = 1, input int lf = -1);
    logic [MAXP*8-1:0] d;
    d = 0;
    bq.push_back({1'b0, 8'h10}); bq.push_back({1'b0, psn[15:8]}); bq.push_back({1'b0, psn[7:0]});
    bq.push_back({l == 0, 8'(lf >= 0 ? lf : l)});
    for (int i = 0; i < l; i++) begin
      d[8 * i +: 8] = $urandom;
      bq.push_back({i == l - 1, d[8 * i +: 8]});
    end
    b_last_d = d;
    if (ok) xpush(0, pkt(l, d));
  endtask
  task automatic back(input logic [15:0] cack, input logic [7:0] sack = 0);
    bq.push_back({1'b0, 8'h20}); bq.push_back({1'b0, cack[15:8]}); bq.push_back({1'b0, cack[7:0]});
    bq.push_back({1'b1, sack});
  endtask
  task automatic bnack(input logic [15:0] psn);
    bq.push_back({1'b0, 8'h30}); bq.push_back({1'b0, psn[15:8]}); bq.push_back({1'b1, psn[7:0]});
  endtask
  // A's frames: ACKs (last CACK / SACK), NACKs, DATA (by PSN, checked
  // against what the host wrote: a_exp, oldest first)
  logic [15:0] a_cack = 0, a_nack = 0;
  logic [7:0]  a_sack = 0;
  int          a_nacks = 0, a_acks = 0, a_data = 0, a_ptr = 0;
  logic [15:0] a_psn [$];
  logic [MAXP*8+4:0] a_pk [$];                   // A's packets by PSN from a_base
  logic [15:0] a_base = 0;
  task automatic a_frame(input int n);
    logic [7:0] t;
    t = cf[0][0];
    if (t == 8'h20) begin
      if (n != 4) fail("A: ACK length");
      a_cack = {cf[0][1], cf[0][2]}; a_sack = cf[0][3]; a_acks++;
    end else if (t == 8'h30) begin
      if (n != 3) fail("A: NACK length");
      a_nack = {cf[0][1], cf[0][2]}; a_nacks++;
    end else if (t == 8'h10) begin : b_d
      logic [15:0] p;
      logic [MAXP*8-1:0] d;
      int i;
      p = {cf[0][1], cf[0][2]};
      i = int'(p - a_base);
      d = 0;
      for (int j = 0; j < cf[0][3]; j++) d[8 * j +: 8] = cf[0][4 + j];
      if (n != 4 + cf[0][3]) fail("A: DATA length");
      if (i >= a_pk.size()) fail($sformatf("A: DATA PSN %h, %0d written from %h", p, a_pk.size(), a_base));
      else if (a_pk[i] !== pkt(cf[0][3], d)) fail($sformatf("A: DATA PSN %h: %0d bytes %h, expected %h", p, cf[0][3], d, a_pk[i]));
      a_psn.push_back(p);
      a_data++;
    end else fail($sformatf("A: frame type %h", t));
  endtask
  // the host at A writes a packet of l bytes
  task automatic a_write(input int l);
    logic [MAXP*8-1:0] d;
    d = 0;
    for (int i = 0; i < l; i++) begin
      d[8 * i +: 8] = $urandom;
      tx_valid[0] = 1; tx_data[0] = d[8 * i +: 8]; tx_last[0] = i == l - 1;
      @(posedge clk);
      while (!tx_ready[0]) @(posedge clk);
      @(negedge clk);
      tx_valid[0] = 0; wtk[0] = 0;
    end
    a_pk.push_back(pkt(l, d));
  endtask
  // a write in the background (Icarus: no fork / join_none in tasks)
  int bg_n = 0;
  initial forever begin
    wait (bg_n != 0);
    a_write(bg_n);
    bg_n = 0;
  end
  task automatic a_expect(input logic [15:0] p, input int t = 400);
    int k;
    k = 0;
    while (k < t && !(a_psn.size() != 0 && a_psn[0] == p)) begin
      if (a_psn.size() != 0) void'(a_psn.pop_front());
      @(negedge clk); k++;
    end
    if (k == t) fail($sformatf("A: DATA PSN %h not sent", p));
    else void'(a_psn.pop_front());
  endtask

  // ---------------- helpers ----------------
  task automatic wait_clk(input int n);
    repeat (n) @(negedge clk);
  endtask
  int n_ev [0:4];
  initial for (int i = 0; i < 5; i++) n_ev[i] = 0;
  always @(posedge clk) begin
    n_ev[0] += ev_rto[0] + ev_rto[1]; n_ev[1] += ev_nack[0] + ev_nack[1]; n_ev[2] += ev_dup[0] + ev_dup[1];
    n_ev[3] += ev_nobuf[0] + ev_nobuf[1]; n_ev[4] += ev_proto[0] + ev_proto[1];
  end
  // writing stopped: every packet handed out, nothing outstanding
  task automatic drain(input string ph, input int n = 60000);
    int t;
    wen[0] = 0; wen[1] = 0;
    t = 0;
    while ((wact[0] || wact[1] || xsize(0) + xsize(1) != 0 || outst[0] != 0 || outst[1] != 0) && t < n) begin
      @(negedge clk); t++;
    end
    if (t == n) fail($sformatf("%s: %0d / %0d packets missing, outstanding %0d %0d", ph, xsize(0), xsize(1),
                               outst[0], outst[1]));
    wait_clk(50);
  endtask
  // open the PDC at both ends with PSNs a (A to B) and b (B to A)
  task automatic open_pdc(input logic [15:0] a, input logic [15:0] b);
    spt[0] = a; spr[1] = a; spt[1] = b; spr[0] = b;
    wait_clk(2);
    en = 2'b11;
  endtask
  task automatic close_pdc;
    wen[0] = 0; wen[1] = 0;
    while (wact[0] || wact[1]) @(negedge clk);
    en = 0;
    wait_clk(2);
    ch_clear(); dn[0] = 0; dn[1] = 0;
    x_clear();
  endtask
  task automatic traffic(input int n, input string ph);
    wen[0] = 1; wen[1] = 1;
    wait_clk(n);
    drain(ph);
  endtask

  initial begin
    wait_clk(3);
    rst_n = 1;
    wait_clk(3);
    // clean network
    open_pdc(16'h1234, 16'hFFF0);
    traffic(3000, "clean");
    // loss, duplicates, reordering, back-pressure, gaps
    p_drop = 10; p_dup = 5; p_reord = 20; p_hold = 20; p_gap = 20;
    traffic(8000, "lossy");
    // heavy loss: timeouts
    p_drop = 35; p_dup = 10; p_reord = 40;
    traffic(6000, "heavy loss");
    // slow readers: no receive buffer, NACKs
    p_drop = 0; p_dup = 0; p_reord = 0; p_hold = 0; p_gap = 0;
    rdy_pct[0] = 3; rdy_pct[1] = 3;
    wen[0] = 1; wen[1] = 1;
    wait_clk(3000);
    rdy_pct[0] = 100; rdy_pct[1] = 100;
    drain("no buffer");
    // closed with traffic in flight, opened again across the PSN wrap
    p_drop = 10; p_reord = 20; p_hold = 10;
    wen[0] = 1; wen[1] = 1;
    wait_clk(500);
    close_pdc();
    open_pdc(16'hFFFE, 16'h7FFF);
    traffic(3000, "reopened");
    close_pdc();
    open_pdc($urandom, $urandom);
    p_drop = 20; p_dup = 20; p_reord = 50; p_hold = 30;
    rdy_pct[0] = 40; rdy_pct[1] = 60;
    traffic(6000, "mixed");
    rdy_pct[0] = 100; rdy_pct[1] = 100;
    p_drop = 0; p_dup = 0; p_reord = 0; p_hold = 0;
    close_pdc();

    // ---- BFM in B's place
    bfm = 1;
    b_part();
    bfm = 0;
    en = 0;
    // a reset with traffic in flight
    open_pdc(16'h0F0F, 16'hF0F0);
    wen[0] = 1; wen[1] = 1;
    wait_clk(700);
    wen[0] = 0; wen[1] = 0;
    rst_n = 0;
    wait_clk(3);
    ch_clear(); dn[0] = 0; dn[1] = 0; x_clear(); wact[0] = 0; wact[1] = 0; wpos[0] = 0; wpos[1] = 0;
    tx_valid = 0;
    rst_n = 1;
    wait_clk(3);
    en = 0;
    wait_clk(3);
    open_pdc(16'h0001, 16'h0002);
    traffic(1500, "after reset");

    if (errors == 0) $display("TEST PASSED: UEC (%0d / %0d packets; rto %0d nack %0d dup %0d nobuf %0d proto %0d)",
                              nrx[0], nrx[1], n_ev[0], n_ev[1], n_ev[2], n_ev[3], n_ev[4]);
    else $display("TEST FAILED: UEC (%0d errors)", errors);
    $finish;
  end

  // ---- A against the BFM
  task automatic b_part;
    logic [15:0] r, s;
    r = 16'hABCD;                                 // PSNs the BFM sends
    s = 16'h4321;                                 // PSNs A sends
    spt[0] = s; spr[0] = r;
    a_base = s; a_pk.delete(); a_psn.delete();
    wait_clk(2);
    en[0] = 1;
    // receive: in order, a gap, the gap filled, duplicates (in and behind
    // the window), past the window
    bdata(r, 5);
    bwait(); wait_clk(10);
    if (a_cack != r || a_sack != 0) fail($sformatf("ACK %h %b after PSN %h", a_cack, a_sack, r));
    bdata(r + 2, MAXP);
    bdata(r + 3, 1);
    bwait(); wait_clk(10);
    if (a_cack != r || a_sack != 8'b011) fail($sformatf("ACK %h %b with a gap", a_cack, a_sack));
    bdata(r + 3, 4, 0);
    bdata(r, 4, 0);
    bdata(r + 1, 7);
    bwait(); wait_clk(10);
    if (a_cack != r + 3 || a_sack != 0) fail($sformatf("ACK %h %b with the gap filled", a_cack, a_sack));
    bdata(r + 4 + W, 3, 0);                      // past the window
    bdata(r + 4 + W - 1, 3);                     // the window's last
    bwait(); wait_clk(10);
    if (a_cack != r + 3 || a_sack != 8'b100) fail($sformatf("ACK %h %b, window's last", a_cack, a_sack));
    for (int i = 0; i < W - 1; i++) bdata(r + 4 + i, 2);
    bwait(); wait_clk(30);
    if (a_cack != r + 3 + W) fail($sformatf("ACK %h, window filled", a_cack));
    r = r + 4 + W;
    // no buffer: the reader stopped; NACK for the first one dropped
    rdy_pct[0] = 0;
    wait_clk(40);
    bdata(r, 3);
    bdata(r + 1, 3);
    bdata(r + 2, 3, 0);
    bwait(); wait_clk(10);
    if (a_nack != r + 2) fail($sformatf("NACK %h, expected %h", a_nack, r + 2));
    bdata(r + 3, 3, 0);
    bwait(); wait_clk(10);
    if (a_nack != r + 3) fail($sformatf("NACK %h, expected %h", a_nack, r + 3));
    rdy_pct[0] = 100;
    wait_clk(50);
    bdata(r + 3, 3);
    bdata(r + 2, 3);
    bwait(); wait_clk(10);
    if (a_cack != r + 3) fail($sformatf("ACK %h after the NACKed ones", a_cack));
    r = r + 4;
    // frame errors: type, lengths, LEN 0 / over MAXP / mismatch, a long frame
    b_bytes(4, 8'h40);
    b_bytes(4, 8'hFF);
    bdata(r, 3, 0, 255);
    b_bytes(1, 8'h10);
    b_bytes(3, 8'h20);
    b_bytes(5, 8'h20);
    b_bytes(2, 8'h30);
    b_bytes(4, 8'h30);
    bdata(r, 0, 0);
    bdata(r, 3, 0, MAXP + 1);
    bdata(r, 3, 0, 4);
    bdata(r, 5, 0, 4);
    b_bytes(40, 8'h10);
    bq.push_back({1'b0, 8'h10}); bq.push_back({1'b0, r[15:8]}); bq.push_back({1'b0, r[7:0]});
    bq.push_back({1'b0, 8'(MAXP + 1)});
    b_bytes(MAXP + 1, 8'h00);                    // LEN over MAXP, length matching
    // 40 bytes, the last 8 a DATA frame of LEN 4: the byte count saturates,
    // so they are not taken as a frame of their own
    for (int i = 0; i < 32; i++) bq.push_back({1'b0, i == 0 ? 8'h10 : 8'($urandom)});
    bq.push_back({1'b0, 8'h10}); bq.push_back({1'b0, r[15:8]}); bq.push_back({1'b0, r[7:0]});
    bq.push_back({1'b0, 8'd4});
    for (int i = 0; i < 4; i++) bq.push_back({i == 3, 8'($urandom)});
    b_gap = 30;
    bdata(r, 6);                                 // with gaps: still good
    bwait();
    b_gap = 0;
    wait_clk(10);
    if (a_cack != r) fail("ACK after the frame errors");
    r = r + 1;

    // send: A's packets, ACKed one by one, then a window with no ACK
    // (timeout), NACK, SACK, late and bad ACKs / NACKs
    a_write(3);
    a_expect(s);
    back(s);
    bwait();
    for (int i = 0; i < W; i++) a_write(1 + $urandom % MAXP);
    bg_n = 2;                                    // waits for room
    for (int i = 1; i <= W; i++) a_expect(s + 16'(i));
    a_expect(s + 1, 2 * RTO);                    // timeout: all again
    for (int i = 2; i <= W; i++) a_expect(s + 16'(i));
    bnack(s + 3);
    a_expect(s + 3);
    back(s, 8'b010);                             // SACK: s + 3 only (s + 2 + 1)
    bnack(s + 3);                                // acknowledged, not yet out of the window
    back(s - 5);                                 // late
    bnack(s - 1);                                // late
    bnack(s + W + 3);                            // not sent: proto
    back(s + W + 3);                             // past what was sent: proto
    bwait();
    back(s + 1, 8'b001);                         // s + 1, s + 3 (s + 1 + 2)
    bwait();
    a_expect(s + 5, 400);                        // the waiting one, now in the window
    back(s + 5);
    bwait();
    wait_clk(20);
    if (outst[0] != 0) fail($sformatf("A: %0d outstanding after the last ACK", outst[0]));
    bnack(s + 5);                                // late (acknowledged)
    bwait();
    // a full window sent, then timed out; the first retransmission held on
    // the wire: an ACK for it frees its buffer, which the host may not
    // write until the frame is out; then, with the others marked, an ACK
    // for all whose last byte comes as the transmitter picks the next
    s = s + 6;
    for (int i = 0; i < W; i++) a_write(1 + $urandom % MAXP);
    for (int i = 0; i < W; i++) a_expect(s + 16'(i));
    wait_clk(20);
    ntr_force = 0; ntr[0] = 0;
    begin : b_held
      int k;
      k = 0;
      while (!ntv[0] && k < 2 * RTO) begin @(negedge clk); k++; end
      if (!ntv[0] || ntd[0] != 8'h10) fail("A: no retransmission after the timeout");
    end
    bg_n = 5;
    back(s);
    bwait();
    wait_clk(10);
    while (!(ntv[0] && ntl[0])) begin
      @(negedge clk);
      ntr_force = ntv[0] && ntl[0] ? 0 : 1; ntr[0] = ntr_force[0];
    end
    bq.push_back({1'b0, 8'h20}); bq.push_back({1'b0, 8'(16'(s + 3) >> 8)});
    bq.push_back({1'b0, 8'(s + 3)});
    bwait();
    @(negedge clk);
    b_wait = 1; bq.push_back({1'b1, 8'h00});
    ntr_force = 1; ntr[0] = 1;
    bwait();
    ntr_force = -1;
    a_expect(s + 4, 400);
    back(s + 4);
    bwait();
    wait_clk(20);
    if (outst[0] != 0) fail($sformatf("A: %0d outstanding after the held retransmission", outst[0]));
    // the wire held: one packet picked, two written but not sent; ACKs and
    // NACKs for the unsent ones are bad, SACK bits for them do nothing
    s = s + 5;
    ntr_force = 0; ntr[0] = 0;
    a_write(2); a_write(3); a_write(4);
    wait_clk(5);
    back(s + 2);
    back(s - 1, 8'b011);
    bnack(s + 1);
    bwait();
    wait_clk(5);
    if (outst[0] != 3) fail($sformatf("A: %0d outstanding with the wire held", outst[0]));
    ntr_force = -1;
    for (int i = 0; i < 3; i++) a_expect(s + 16'(i));
    back(s);
    bwait();
    wait_clk(10);
    if (outst[0] != 2) fail($sformatf("A: %0d outstanding, the SACKed unsent ones must stay", outst[0]));
    back(s + 2);
    bwait();
    wait_clk(20);
    if (outst[0] != 0) fail($sformatf("A: %0d outstanding after the held packets", outst[0]));
    // closed with a frame on the way out, a frame coming in and a gap in
    // what was received
    bdata(r + 1, 2);
    bwait();
    a_write(MAXP);
    p_hold = 90;
    bq.push_back({1'b0, 8'h10}); bq.push_back({1'b0, 8'h00}); bq.push_back({1'b0, 8'h00});
    wait_clk(8);
    en[0] = 0;
    wait_clk(3);
    p_hold = 0;
    x_clear();
    bq.delete();
    // opened again: nothing of the last PDC is left
    r = 16'h5000;
    spr[0] = r; spt[0] = 16'h0F00;
    a_base = 16'h0F00; a_pk.delete(); a_psn.delete();
    wait_clk(2);
    en[0] = 1;
    bdata(r + 1, 3);
    bwait(); wait_clk(10);
    if (a_cack != r - 1 || a_sack != 8'b001) fail($sformatf("ACK %h %b after reopening", a_cack, a_sack));
    bdata(r, 2);
    bwait(); wait_clk(10);
    if (a_cack != r + 1) fail($sformatf("ACK %h after reopening", a_cack));
    en[0] = 0;
    wait_clk(3);
    x_clear();
  endtask

  initial begin
    #30ms;
    $display("A: outstanding %0d sbase %h | B: outstanding %0d", outst[0], g_end[0].u.sbase, outst[1]);
    $display("TEST FAILED: UEC (timeout)");
    $finish;
  end
endmodule
