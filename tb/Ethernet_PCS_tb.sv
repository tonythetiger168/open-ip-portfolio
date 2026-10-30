// SPDX-License-Identifier: Apache-2.0
// Ethernet_PCS_top testbench (AMP = 3 pairs per marker period).
//  1. Transmit vectors (scripts/ethpcs/gen_vec.py from the reference model
//     pcs_ref.py): 9 pairs of groups in, with random gaps, and every beat
//     out compared, with output back-pressure.
//  2. Receive vectors: a stream starting mid-period, with correctable and
//     uncorrectable codewords, invalid transcoded blocks, a marker group
//     off its period, three missing groups and a relock; every group out
//     compared, and the event counts, lock and status bits at the end.
//  3. Loopback: random groups through the transmitter into the receiver,
//     with random symbol errors (at most 15 a codeword) and stalls on every
//     port; the groups out must be the groups in. Then with the correction
//     bypassed (no errors), a realignment (rx_in_first in the middle of a
//     pair) and resets with data in flight.
`timescale 1ns/1ps
module Ethernet_PCS_tb;
  logic clk = 0, rst_n = 0;
  always #5 clk = ~clk;
  int errors = 0;
  task automatic fail(input string s);
    errors++;
    if (errors < 20) $display("ERROR: %s @%0t", s, $time);
  endtask

  logic         cfg_bypass_corr = 0, cfg_bypass_ind = 0;
  logic [2:0]   tx_am_sf = 0;
  logic         tx_in_valid = 0, tx_out_ready = 1, rx_in_valid = 0, rx_in_first = 0, rx_out_ready = 1;
  logic [263:0] tx_in_data = 0;
  logic [639:0] rx_in_data = 0;
  wire          tx_in_ready, tx_out_valid, tx_out_first, rx_in_ready, rx_out_valid;
  wire  [639:0] tx_out_data;
  wire  [263:0] rx_out_data;
  wire          rx_am_lock, ev_am_err, ev_itb, ev_resync;
  wire  [2:0]   rx_am_sf;
  wire          ev_corr_a, ev_corr_b, ev_uncorr_a, ev_uncorr_b;
  wire  [3:0]   st_nsym_a, st_nsym_b;
  Ethernet_PCS_top #(.AMP(3)) dut (.*);

  `include "Ethernet_PCS_vec.svh"
  logic [263:0] vg [0:RX_G0 + N_RXG - 1];
  logic [639:0] vb [0:RX_B0 + N_RXB - 1];
  initial begin
    // from the repository root, sim/, or the coverage build directory
    if ($fopen("tb/Ethernet_PCS_g.hex", "r") != 0) begin
      $readmemh("tb/Ethernet_PCS_g.hex", vg); $readmemh("tb/Ethernet_PCS_b.hex", vb);
    end else if ($fopen("../tb/Ethernet_PCS_g.hex", "r") != 0) begin
      $readmemh("../tb/Ethernet_PCS_g.hex", vg); $readmemh("../tb/Ethernet_PCS_b.hex", vb);
    end else begin
      $readmemh("../../../../tb/Ethernet_PCS_g.hex", vg); $readmemh("../../../../tb/Ethernet_PCS_b.hex", vb);
    end
  end

  // ---------------- stalls ----------------
  int tx_gap = 0, rx_gap = 0, bp = 0;           // % idle clocks on the inputs, % output stalls
  always @(negedge clk) begin
    tx_out_ready <= $urandom_range(0, 99) >= bp;
    rx_out_ready <= $urandom_range(0, 99) >= bp;
  end

  // ---------------- event counters ----------------
  int n_am_err = 0, n_itb = 0, n_resync = 0, n_uncorr = 0;
  always @(posedge clk) if (rst_n) begin
    n_am_err += ev_am_err; n_itb += ev_itb; n_resync += ev_resync; n_uncorr += ev_uncorr_a + ev_uncorr_b;
  end

  // ---------------- drivers ----------------
  task automatic tx_send(input logic [263:0] g);
    while ($urandom_range(0, 99) < tx_gap) @(negedge clk);
    tx_in_valid = 1; tx_in_data = g;
    @(posedge clk);
    while (!tx_in_ready) @(posedge clk);
    @(negedge clk);
    tx_in_valid = 0;
  endtask
  task automatic rx_send(input logic [639:0] b, input bit f);
    while ($urandom_range(0, 99) < rx_gap) @(negedge clk);
    rx_in_valid = 1; rx_in_data = b; rx_in_first = f;
    @(posedge clk);
    while (!rx_in_ready) @(posedge clk);
    @(negedge clk);
    rx_in_valid = 0; rx_in_first = 0;
  endtask

  // ---------------- monitors ----------------
  logic [639:0] tq [$];                         // transmitted beats
  bit           tqf [$];
  logic [263:0] rq [$];                         // received groups
  always @(posedge clk) if (rst_n) begin
    if (tx_out_valid && tx_out_ready) begin tq.push_back(tx_out_data); tqf.push_back(tx_out_first); end
    if (rx_out_valid && rx_out_ready) rq.push_back(rx_out_data);
  end
  task automatic wait_rq(input int n);
    for (int t = 0; t < 200000 && rq.size() < n; t++) @(posedge clk);
    #1;
  endtask

  task automatic do_reset();
    @(negedge clk);
    rst_n = 0; tx_in_valid = 0; rx_in_valid = 0; rx_in_first = 0;
    repeat (3) @(negedge clk);
    rst_n = 1;
    tq.delete(); tqf.delete(); rq.delete();
    n_am_err = 0; n_itb = 0; n_resync = 0; n_uncorr = 0;
  endtask

  // ---------------- random traffic ----------------
  function automatic logic [65:0] rnd_block(input int pctl);
    logic [87:0] t;
    logic [65:0] b;
    t = 88'h1E_78_4B_87_99_AA_B4_CC_D2_E1_FF;           // the 11 block types
    b = {$urandom, $urandom, $urandom};
    if ($urandom_range(0, 99) < pctl) begin b[1:0] = 2'b01; b[9:2] = t[8 * $urandom_range(0, 10) +: 8]; end
    else b[1:0] = 2'b10;
    return b;
  endfunction
  function automatic logic [263:0] rnd_group(input int pctl);
    logic [263:0] g;
    for (int j = 0; j < 4; j++) g[66 * j +: 66] = rnd_block(pctl);
    return g;
  endfunction

  // loopback: the transmitter's beats into the receiver, with symbol errors
  int lb_err = 0;                               // max symbol errors a codeword (0..15)
  bit lb_on = 0;
  int ea, eb, lbeat = 0;
  task automatic loop_beat();
    logic [639:0] b;
    bit f;
    int s;
    b = tq.pop_front(); f = tqf.pop_front();
    if (f) begin ea = $urandom_range(0, lb_err); eb = $urandom_range(0, lb_err); lbeat = 0; end
    // spread the errors: one symbol of A and / or B in the beats that still owe one
    if (ea > 0 && $urandom_range(0, 16 - lbeat) < ea) begin
      s = $urandom_range(0, 31);                // codeword A symbol s of the beat: 16k + 2j + (k odd)
      b[10 * (16 * (s / 8) + 2 * (s % 8) + (s / 8) % 2) +: 10] ^= 10'($urandom_range(1, 1023)); ea--;
    end
    if (eb > 0 && $urandom_range(0, 16 - lbeat) < eb) begin
      s = $urandom_range(0, 31);
      b[10 * (16 * (s / 8) + 2 * (s % 8) + 1 - (s / 8) % 2) +: 10] ^= 10'($urandom_range(1, 1023)); eb--;
    end
    lbeat++;
    rx_send(b, f);
  endtask

  task automatic loopback(input int npairs, input int pctl);
    logic [263:0] sent [$];
    int ng, t;
    ng = npairs * 40 - ((npairs + 2) / 3) * 8;   // groups that fill npairs pairs (AMP = 3, marker first)
    fork
      for (int i = 0; i < ng; i++) begin
        logic [263:0] g;
        g = rnd_group(pctl);
        sent.push_back(g);
        tx_send(g);
      end
      begin
        bit stuck;
        stuck = 0;
        for (int i = 0; i < npairs * 17 && !stuck; i++) begin
          t = 0;
          while (tq.size() == 0 && t < 20000) begin @(negedge clk); t++; end
          if (tq.size() == 0) begin fail("loopback: transmitter stalled"); stuck = 1; end
          else loop_beat();
        end
      end
    join
    wait_rq(ng);
    if (rq.size() != ng) fail($sformatf("loopback: %0d groups out, %0d in", rq.size(), ng));
    for (int i = 0; i < ng && i < rq.size(); i++)
      if (rq[i] !== sent[i]) fail($sformatf("loopback group %0d: %h, expected %h", i, rq[i], sent[i]));
    if (!rx_am_lock) fail("loopback: no lock");
    if (n_am_err != 0 || n_itb != 0 || n_uncorr != 0) fail("loopback: events");
    rq.delete();
  endtask

  initial begin
    repeat (3) @(negedge clk);
    rst_n = 1;
    // ---- 1. transmit vectors
    tx_am_sf = 3'd5; tx_gap = 20; bp = 20;
    for (int i = 0; i < N_TXG; i++) tx_send(vg[i]);
    for (int t = 0; t < 5000 && tq.size() < N_TXB; t++) @(posedge clk);
    if (tq.size() != N_TXB) fail($sformatf("TX: %0d beats", tq.size()));
    for (int i = 0; i < N_TXB && i < tq.size(); i++) begin
      if (tq[i] !== vb[i]) fail($sformatf("TX beat %0d: %h, expected %h", i, tq[i], vb[i]));
      if (tqf[i] != (i % 17 == 0)) fail($sformatf("TX beat %0d: first %0d", i, tqf[i]));
    end
    $display("TX vectors: %0d beats", tq.size());
    // ---- 2. receive vectors
    do_reset();
    rx_gap = 20;
    for (int i = 0; i < N_RXB; i++) rx_send(vb[RX_B0 + i], i % 17 == 0);
    wait_rq(N_RXG);
    repeat (20) @(posedge clk);
    if (rq.size() != N_RXG) fail($sformatf("RX: %0d groups, expected %0d", rq.size(), N_RXG));
    for (int i = 0; i < N_RXG && i < rq.size(); i++)
      if (rq[i] !== vg[RX_G0 + i]) fail($sformatf("RX group %0d: %h, expected %h", i, rq[i], vg[RX_G0 + i]));
    if (n_am_err != RX_AM_ERR || n_itb != RX_ITB) fail($sformatf("RX events: am_err %0d itb %0d", n_am_err, n_itb));
    if (rx_am_lock != RX_LOCK || rx_am_sf != 3'(RX_SF)) fail("RX lock / status");
    if (n_uncorr != 2) fail("RX: uncorrectable codewords not reported");
    $display("RX vectors: %0d groups", rq.size());
    // ---- 3. loopback
    for (int r = 0; r < 4; r++) begin
      do_reset();
      tx_am_sf = 3'(r * 3);
      tx_gap = r == 0 ? 0 : 30; rx_gap = r == 0 ? 0 : 30; bp = r == 0 ? 0 : 25;
      lb_err = r == 0 ? 0 : 15;
      loopback(7, r * 33);
      if (rx_am_sf != 3'(r * 3)) fail("loopback: status bits");
    end
    // a long run: many marker groups (the PRBS9 pad runs on)
    do_reset();
    tx_am_sf = 3'd2; tx_gap = 5; rx_gap = 5; bp = 5; lb_err = 3;
    loopback(40, 25);
    // correction bypassed, no errors
    do_reset();
    cfg_bypass_corr = 1; lb_err = 0;
    loopback(4, 50);
    cfg_bypass_corr = 0;
    // indication bypassed with uncorrectable codewords: the groups pass, no sync header is forced
    do_reset();
    cfg_bypass_ind = 1;
    for (int i = 0; i < 3; i++) begin
      for (int b = 0; b < 17; b++) begin
        logic [639:0] x;
        x = {20{$urandom}};
        rx_send(x, b == 0);
      end
    end
    repeat (100) @(posedge clk);
    cfg_bypass_ind = 0;
    // realignment: half a pair, then a new first beat
    do_reset();
    for (int b = 0; b < 8; b++) rx_send(vb[RX_B0 + b], b == 0);
    for (int b = 0; b < 17; b++) rx_send(vb[RX_B0 + b], b == 0);
    repeat (100) @(posedge clk);
    if (n_resync == 0) fail("no resync event");
    // reset with data in flight, then a clean loopback
    tx_gap = 0; rx_gap = 0; bp = 0;
    fork
      for (int i = 0; i < 60; i++) tx_send(rnd_group(20));
      begin repeat (70) @(negedge clk); end
    join_any
    disable fork;
    do_reset();
    lb_err = 5;
    loopback(4, 10);
    if (errors == 0) $display("TEST PASSED: Ethernet_PCS");
    else $display("TEST FAILED: Ethernet_PCS (%0d errors)", errors);
    $finish;
  end
  initial begin
    #20ms;
    $display("TEST FAILED: Ethernet_PCS (timeout)");
    $finish;
  end
endmodule
