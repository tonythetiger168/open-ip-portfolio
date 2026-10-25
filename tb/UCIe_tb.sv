// SPDX-License-Identifier: Apache-2.0
// UCIe_top testbench: two Adapters (A, B) joined by a TB link with a
// variable delay that corrupts and drops flits.
//  - each side's protocol layer offers payloads at a variable rate; the
//    payloads delivered on the far side are checked in order, each exactly
//    once (scoreboards both ways)
//  - clean link, short and long delays (replay buffer full), corrupted DATA
//    and NOP flits (Nak, replay), dropped flits (SEQ ahead, lost Acks and
//    Naks recovered by the replay timeout)
//  - the TB takes B's place on A's receive side to send crafted flits: an
//    ACK outside what is outstanding, a duplicate, a SEQ ahead, a Nak
//  - reset with traffic in flight
// The bound checker (tb/cov/UCIe_sva.sv) checks every output of both
// Adapters on every clock against its own model.
`timescale 1ns/1ps
module UCIe_tb;
  localparam int RB = 8, TO = 32;
  logic clk = 0, rst_n = 0;
  always #5 clk = ~clk;
  int errors = 0;
  task automatic fail(input string s);
    errors++;
    $display("ERROR: %s @%0t", s, $time);
  endtask
  task automatic wait_clk(input int n); repeat (n) @(negedge clk); endtask

  function automatic logic [15:0] crc16(input logic [73:0] d);
    logic [15:0] c;
    c = 16'hFFFF;
    for (int i = 73; i >= 0; i--) begin
      if (c[15] ^ d[i]) c = (c << 1) ^ 16'h1021; else c = c << 1;
    end
    return c;
  endfunction

  logic        a_tv = 0, b_tv = 0, a_lrv = 0, b_lrv = 0;
  logic [63:0] a_td = 0, b_td = 0;
  logic [89:0] a_lrf = 0, b_lrf = 0;
  wire         a_tr, b_tr, a_rv, b_rv, a_ltv, b_ltv, a_crc, b_crc, a_rep, b_rep;
  wire  [63:0] a_rd, b_rd;
  wire  [89:0] a_ltf, b_ltf;
  wire  [3:0]  a_pend, b_pend;
  UCIe_top #(.RB(RB), .TO(TO)) u_a (
    .clk, .rst_n, .tx_valid(a_tv), .tx_data(a_td), .tx_ready(a_tr), .rx_valid(a_rv), .rx_data(a_rd),
    .lt_valid(a_ltv), .lt_flit(a_ltf), .lr_valid(a_lrv), .lr_flit(a_lrf), .tx_pend(a_pend), .ev_crc(a_crc), .ev_replay(a_rep));
  UCIe_top #(.RB(RB), .TO(TO)) u_b (
    .clk, .rst_n, .tx_valid(b_tv), .tx_data(b_td), .tx_ready(b_tr), .rx_valid(b_rv), .rx_data(b_rd),
    .lt_valid(b_ltv), .lt_flit(b_ltf), .lr_valid(b_lrv), .lr_flit(b_lrf), .tx_pend(b_pend), .ev_crc(b_crc), .ev_replay(b_rep));

  // ---------------- protocol layers ----------------
  int  p_tx = 70;
  bit  tx_on = 0, b_off = 0;
  logic [63:0] sb_ab [$], sb_ba [$];             // sent, not yet delivered
  int  n_ab = 0, n_ba = 0, n_crc = 0, n_rep = 0;
  // a payload is taken on the rising edge where valid and ready are both high
  always @(posedge clk) if (rst_n) begin
    if (a_tv && a_tr) begin sb_ab.push_back(a_td); a_tv <= 0; end
    if (b_tv && b_tr) begin sb_ba.push_back(b_td); b_tv <= 0; end
  end
  always @(negedge clk) if (rst_n) begin
    if (!a_tv && tx_on && $urandom % 100 < p_tx) begin a_tv = 1; a_td = {$urandom, $urandom}; end
    else if (!a_tv) a_td = {$urandom, $urandom};
    if (!b_tv && tx_on && !b_off && $urandom % 100 < p_tx) begin b_tv = 1; b_td = {$urandom, $urandom}; end
    else if (!b_tv) b_td = {$urandom, $urandom};
    if (b_rv) begin
      if (sb_ab.size() == 0) fail("B delivered a payload never sent");
      else if (sb_ab[0] !== b_rd) fail($sformatf("B delivered %h, expected %h", b_rd, sb_ab[0]));
      else begin void'(sb_ab.pop_front()); n_ab++; end
    end
    if (a_rv) begin
      if (sb_ba.size() == 0) fail("A delivered a payload never sent");
      else if (sb_ba[0] !== a_rd) fail($sformatf("A delivered %h, expected %h", a_rd, sb_ba[0]));
      else begin void'(sb_ba.pop_front()); n_ba++; end
    end
    n_crc += int'(a_crc) + int'(b_crc);
    n_rep += int'(a_rep) + int'(b_rep);
  end

  // ---------------- link ----------------
  int  dly = 0, p_cor = 0, p_drop = 0;
  bit  inj = 0;                                  // the TB drives A's receive side
  logic        j_v = 0;
  logic [89:0] j_f = 0;
  logic [90:0] p_ab [$], p_ba [$];
  always @(negedge clk) begin : b_link
    logic [90:0] x;
    if (!rst_n) begin p_ab.delete(); p_ba.delete(); a_lrv = 0; b_lrv = 0; end
    else begin
      p_ab.push_back({a_ltv, a_ltf});
      p_ba.push_back({b_ltv, b_ltf});
      b_lrv = 0; b_lrf = {$urandom, $urandom, $urandom};
      if (p_ab.size() > dly) begin
        x = p_ab.pop_front();
        if (x[90]) begin
          b_lrv = 1; b_lrf = x[89:0];
          if ($urandom % 100 < p_cor) b_lrf[$urandom % 90] ^= 1'b1;
          else if ($urandom % 100 < p_drop) b_lrv = 0;
        end
      end
      a_lrv = 0; a_lrf = {$urandom, $urandom, $urandom};
      if (p_ba.size() > dly) begin
        x = p_ba.pop_front();
        if (x[90] && !inj) begin
          a_lrv = 1; a_lrf = x[89:0];
          if ($urandom % 100 < p_cor) a_lrf[$urandom % 90] ^= 1'b1;
          else if ($urandom % 100 < p_drop) a_lrv = 0;
        end
      end
      if (inj && j_v) begin a_lrv = 1; a_lrf = j_f; end
    end
  end

  task automatic drain(input string ph);
    int t;
    t = 0;
    while ((sb_ab.size() != 0 || sb_ba.size() != 0 || a_pend != 0 || b_pend != 0 || a_tv || b_tv) && t < 20000) begin
      @(negedge clk); t++;
    end
    if (t == 20000) fail($sformatf("%s: stuck (%0d / %0d undelivered, %0d / %0d outstanding)", ph, sb_ab.size(), sb_ba.size(), a_pend, b_pend));
    wait_clk(5);
    $display("%s: %0d A->B, %0d B->A, %0d CRC errors, %0d replays", ph, n_ab, n_ba, n_crc, n_rep);
  endtask
  task automatic run(input int n, input string ph);
    tx_on = 1;
    wait_clk(n);
    tx_on = 0;
    drain(ph);
  endtask
  // a crafted flit on A's receive side
  task automatic j_send(input bit d, input logic [3:0] seq, input logic [3:0] ack, input bit nak, input logic [63:0] pl, input bit bad);
    j_v = 1; j_f = {d, seq, ack, nak, pl, crc16({d, seq, ack, nak, pl}) ^ {15'd0, bad}};
    @(negedge clk);
    j_v = 0;
  endtask

  initial begin
    wait_clk(3);
    rst_n = 1;
    wait_clk(3);
    run(1000, "clean");
    dly = 6; p_tx = 100;
    run(1000, "long delay");
    dly = 2; p_tx = 70; p_cor = 5;
    run(3000, "corrupted");
    p_cor = 0; p_drop = 5;
    run(3000, "dropped");
    p_cor = 10; p_drop = 10; dly = 4;
    run(3000, "both");
    p_cor = 0; p_drop = 0; dly = 0; p_tx = 100;
    run(1000, "fast");
    // reset with traffic in flight
    dly = 3; p_cor = 5; tx_on = 1;
    while (!(a_pend > 2 && b_pend > 2 && b_rv)) @(negedge clk);
    rst_n = 0;
    tx_on = 0;
    wait_clk(3);
    sb_ab.delete(); sb_ba.delete(); a_tv = 0; b_tv = 0;
    rst_n = 1;
    p_cor = 0; dly = 1;
    run(1000, "after reset");
    // crafted flits on A's receive side: B's flits are not delivered to A
    inj = 1;
    wait_clk(3);
    // A sends: nothing comes back, then a duplicate, an ACK outside what is
    // outstanding, a SEQ ahead, a bad CRC, a NAK
    b_off = 1;
    tx_on = 1; wait_clk(6); tx_on = 0;
    while (a_tv) @(negedge clk);
    wait_clk(2);
    j_send(1, u_a.exp - 4'd1, u_a.ws - 4'd9, 0, 64'h1, 0);  // duplicate; ACK not outstanding
    j_send(1, u_a.exp + 4'd2, u_a.as - 4'd1, 0, 64'h2, 0);  // SEQ ahead
    j_send(0, 0, u_a.as - 4'd1, 0, 0, 1);                   // bad CRC: no second Nak
    sb_ba.push_back(64'hC0FF_EE00_1234_5678);
    j_send(1, u_a.exp, u_a.as, 0, 64'hC0FF_EE00_1234_5678, 0); // the expected one, ACK one
    if (a_pend < 3) fail("crafted: too few flits outstanding");
    j_send(0, 0, u_a.as - 4'd1, 1, 0, 0);                   // NAK: replay the rest
    j_send(0, 0, u_a.ws - 4'd1, 0, 0, 0);                   // ACK everything mid-replay
    wait_clk(3);
    inj = 0;
    drain("crafted");
    if (errors == 0) $display("TEST PASSED: UCIe (%0d A->B, %0d B->A payloads, %0d replays)", n_ab, n_ba, n_rep);
    else $display("TEST FAILED: UCIe (%0d errors)", errors);
    $finish;
  end

  initial begin
    #10ms;
    $display("TEST FAILED: UCIe (timeout)");
    $finish;
  end
endmodule
