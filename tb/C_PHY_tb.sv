// SPDX-License-Identifier: Apache-2.0
// ============================================================================
// Self-checking testbench for C_PHY_top (MIPI C-PHY trio TX + RX decode)
// The TB is the host (16-bit word stream) and loops the trio TX pads back
// into the RX decoder through an injection mux. Its own encoder works on
// level tuples (rotation = rotate {A,B,C}, polarity = swap high/low) and
// predicts every wire state of each burst; the looped-back words are
// compared with the sent ones. Covered: single and multi-word bursts,
// back-to-back bursts, host underrun, all 16-bit corner words and random
// words; injected errors (entry not on +x, wrong sync symbol, invalid wire
// state, missing transition, word overflow, stop inside a word, stop
// without post-amble, junk after the post-amble), a long post-amble,
// irq_clear (also in the same cycle as an error) and a reset mid-burst.
// ============================================================================
`timescale 1ns/1ps
module C_PHY_tb;
  localparam logic [1:0] L = 2'b00, M = 2'b01, H = 2'b10;
  localparam logic [5:0] PX = {H, L, M}, MID = {M, M, M};

  logic clk = 0, rst_n = 0;
  always #5 clk = ~clk;

  logic [15:0] tx_data = 0;
  logic        tx_valid = 0, tx_last = 0, irq_clear = 0;
  wire         tx_ready, tx_done, irq;
  wire  [1:0]  t_a, t_b, t_c;
  logic        inj = 0;
  logic [5:0]  iw = MID;
  wire  [1:0]  r_a = inj ? iw[5:4] : t_a;
  wire  [1:0]  r_b = inj ? iw[3:2] : t_b;
  wire  [1:0]  r_c = inj ? iw[1:0] : t_c;
  wire         rx_active, rx_valid, rx_done;
  wire  [15:0] rx_data;
  int errors = 0;
  logic [15:0] w [0:63];                 // words of the next burst

  C_PHY_top dut (
    .clk(clk), .rst_n(rst_n), .irq(irq), .irq_clear(irq_clear),
    .tx_data(tx_data), .tx_valid(tx_valid), .tx_ready(tx_ready),
    .tx_last(tx_last), .tx_done(tx_done),
    .t_a(t_a), .t_b(t_b), .t_c(t_c),
    .r_a(r_a), .r_b(r_b), .r_c(r_c),
    .rx_active(rx_active), .rx_data(rx_data), .rx_valid(rx_valid),
    .rx_done(rx_done)
  );

  task automatic check(input bit cond, input string msg);
    if (!cond) begin errors++; $display("ERROR: %s (time %0t)", msg, $time); end
  endtask

  // ---------------- tuple encoder ----------------
  function automatic logic [5:0] swp(input logic [5:0] t);
    logic [5:0] r;
    for (int i = 0; i < 3; i++)
      r[2*i +: 2] = t[2*i +: 2] == H ? L : t[2*i +: 2] == L ? H : t[2*i +: 2];
    return r;
  endfunction
  function automatic logic [5:0] step(input logic [5:0] t, input int s);
    logic [5:0] r;
    if (s == 4) return swp(t);
    r = s[1] ? {t[1:0], t[5:2]} : {t[3:0], t[5:4]};   // rotate right = clockwise
    return s[0] ? swp(r) : r;
  endfunction

  // expected wire states of one burst (entry, sync, words, post-amble)
  logic [5:0] exp_w [0:1023];
  int         exp_n;
  logic [5:0] got_w [0:1023];
  int         got_n;
  task automatic add_sym(input int s);
    begin exp_w[exp_n] = step(exp_w[exp_n - 1], s); exp_n++; end
  endtask
  task automatic expect_burst(input int n);
    int v;
    begin
      exp_w[0] = PX; exp_n = 1;
      add_sym(3); for (int i = 0; i < 5; i++) add_sym(4); add_sym(3);
      for (int k = 0; k < n; k++) begin
        v = w[k];
        for (int i = 0; i < 7; i++) begin add_sym(v % 5); v = v / 5; end
      end
      for (int i = 0; i < 7; i++) add_sym(4);
    end
  endtask

  // TX wire monitor: records each burst
  logic in_burst = 0;
  int   bursts = 0;
  always @(posedge clk) begin
    if ({t_a, t_b, t_c} !== MID) begin
      if (!in_burst) got_n = 0;
      in_burst = 1;
      got_w[got_n] = {t_a, t_b, t_c};
      got_n++;
    end else if (in_burst) begin
      in_burst = 0; bursts++;
    end
  end

  // RX word monitor
  logic [15:0] rx_got [0:1023];
  int          rx_n = 0, done_n = 0, txdone_n = 0;
  always @(posedge clk) begin
    if (rx_valid) begin rx_got[rx_n] = rx_data; rx_n++; end
    if (rx_done) done_n++;
    if (tx_done) txdone_n++;
  end

  // ---------------- host ----------------
  task automatic push(input logic [15:0] d, input bit last);
    begin
      @(negedge clk);
      tx_data = d; tx_last = last; tx_valid = 1;
      @(posedge clk);
      while (!tx_ready) @(posedge clk);
      @(negedge clk);
      tx_valid = 0; tx_last = 0;
    end
  endtask

  task automatic wait_idle;
    int c;
    begin
      c = 0;
      while ((in_burst || dut.tstate != 0 || dut.buf_valid) && c < 5000) begin @(posedge clk); c++; end
      repeat (3) @(posedge clk);
    end
  endtask

  // one burst of n words; compare the wires and the looped-back words
  task automatic burst(input int n);   // words in w[]
    int r0, b0, d0, t0;
    begin
      r0 = rx_n; b0 = bursts; d0 = done_n; t0 = txdone_n;
      expect_burst(n);
      for (int k = 0; k < n; k++) push(w[k], k == n - 1);
      wait_idle();
      check(bursts == b0 + 1, "one burst expected");
      check(got_n == exp_n, $sformatf("burst length %0d exp %0d", got_n, exp_n));
      for (int i = 0; i < exp_n; i++)
        if (got_w[i] !== exp_w[i]) begin
          errors++; $display("ERROR: UI %0d wires %b exp %b", i, got_w[i], exp_w[i]);
          i = exp_n;
        end
      check(rx_n == r0 + n, "loopback word count");
      for (int k = 0; k < n; k++) check(rx_got[r0 + k] === w[k], "loopback word");
      check(irq === 1'b0, "irq on a clean burst");
      check(done_n == d0 + 1 && txdone_n == t0 + 1, "rx_done / tx_done once per burst");
    end
  endtask

  // ---------------- injection ----------------
  logic [5:0] iseq [0:127];
  int         in_n;
  task automatic i_start;
    begin iseq[0] = PX; in_n = 1; end
  endtask
  task automatic i_sym(input int s);
    begin iseq[in_n] = step(iseq[in_n - 1], s); in_n++; end
  endtask
  task automatic i_raw(input logic [5:0] w);
    begin iseq[in_n] = w; in_n++; end
  endtask
  task automatic i_sync;
    begin i_sym(3); for (int i = 0; i < 5; i++) i_sym(4); i_sym(3); end
  endtask
  task automatic i_word(input int v);
    begin for (int i = 0; i < 7; i++) begin i_sym(v % 5); v = v / 5; end end
  endtask
  task automatic i_post;
    begin for (int i = 0; i < 7; i++) i_sym(4); end
  endtask
  task automatic i_send(input bit exp_err, input string what);
    begin
      @(negedge clk); inj = 1;
      for (int i = 0; i < in_n; i++) begin iw = iseq[i]; @(negedge clk); end
      iw = MID; @(negedge clk); @(negedge clk);
      check(irq === exp_err, {what, ": irq"});
      if (exp_err) begin
        irq_clear = 1; @(negedge clk); irq_clear = 0;
        check(irq === 1'b0, {what, ": irq_clear"});
      end
      inj = 0;
    end
  endtask

  initial begin
    repeat (4) @(negedge clk);
    check({t_a, t_b, t_c} === MID && tx_ready === 1'b1 && irq === 1'b0 && !rx_active, "reset state");
    rst_n = 1;
    repeat (3) @(negedge clk);

    // corner words, one burst
    w[0] = 16'h0000; w[1] = 16'hFFFF; w[2] = 16'h1234; w[3] = 16'hBEEF;
    w[4] = 16'h8000; w[5] = 16'h7FFF; w[6] = 16'h5555; w[7] = 16'hAAAA;
    burst(8);
    // single-word bursts
    for (int i = 0; i < 4; i++) begin w[0] = 16'(i * 4099); burst(1); end
    // long random bursts
    for (int b = 0; b < 6; b++) begin
      for (int i = 0; i < 64; i++) w[i] = 16'($urandom);
      burst(64);
    end
    // every power-of-5 digit pattern 0..4 at every position
    for (int d = 0; d < 5; d++) begin
      int v; v = 0;
      for (int i = 0; i < 6; i++) v = v * 5 + d;
      w[d] = 16'(v);
    end
    burst(5);

    // host underrun: no tx_last, then a pause -> the burst ends
    begin
      int r0; r0 = rx_n;
      push(16'h0F0F, 0);
      repeat (40) @(negedge clk);
      push(16'hF0F0, 1);
      wait_idle();
      check(rx_n == r0 + 2 && rx_got[r0] === 16'h0F0F && rx_got[r0 + 1] === 16'hF0F0, "underrun words");
      check(irq === 1'b0, "irq after underrun");
    end
    // back-to-back bursts: the next word is waiting when tx_done fires
    begin
      int r0, b0; r0 = rx_n; b0 = bursts;
      fork
        begin for (int i = 0; i < 6; i++) push(16'(i * 1111), 1); end
      join
      wait_idle();
      check(rx_n == r0 + 6 && bursts == b0 + 6, "back-to-back bursts");
    end

    // ---- injected errors ----
    i_start(); i_sync(); i_word(16'h1234); i_post(); i_sym(4); i_sym(4);
    i_send(0, "long post-amble");
    check(rx_got[rx_n - 1] === 16'h1234, "long post-amble word");
    in_n = 0; i_raw({M, H, L} ^ 6'b0); i_send(1, "entry on +y");
    i_start(); i_sym(3); i_sym(4); i_sym(2); i_sym(4); i_sym(1); i_send(1, "wrong sync symbol");
    i_start(); i_sym(3); i_raw({H, H, L}); i_send(1, "invalid state in sync");
    i_start(); i_sync(); i_sym(1); i_raw(iseq[in_n - 1]); i_send(1, "missing transition");
    i_start(); i_sync(); i_sym(0); i_raw({H, 2'b11, L}); i_send(1, "invalid level 11");
    i_start(); i_sync(); i_word(70000); i_send(1, "word overflow");
    i_start(); i_sync(); i_word(5); i_sym(2); i_sym(2); i_send(1, "stop inside a word");
    i_start(); i_sync(); i_word(5); i_send(1, "stop without post-amble");
    i_start(); i_sync(); i_post(); i_sym(1); i_send(1, "junk after post-amble");
    i_start(); i_sync(); i_post(); i_raw(iseq[in_n - 1]); i_send(1, "no transition after post-amble");
    i_start(); i_sym(3); i_sym(4); i_send(1, "stop in sync");
    // error while sticky, and irq_clear in the same cycle as an error
    i_start(); i_sym(1); i_raw(MID); i_raw({M, L, H});
    @(negedge clk); inj = 1;
    for (int i = 0; i < in_n; i++) begin
      iw = iseq[i];
      irq_clear = (i == 1);
      @(negedge clk);
    end
    irq_clear = 0; iw = MID; @(negedge clk);
    check(irq === 1'b1, "error in the irq_clear cycle wins");
    irq_clear = 1; @(negedge clk); irq_clear = 0; inj = 0;
    for (int i = 0; i < 2; i++) begin w[i] = 16'(i + 77); end
    burst(2);

    // reset in the middle of a burst
    push(16'hCAFE, 0); push(16'hBABE, 1);
    repeat (12) @(negedge clk);
    rst_n = 0; @(negedge clk);
    check({t_a, t_b, t_c} === MID && tx_ready === 1'b1 && !rx_active, "reset mid-burst");
    rst_n = 1; repeat (3) @(negedge clk);
    w[0] = 16'h0001; burst(1);

    if (errors == 0) $display("TEST PASSED: C_PHY");
    else             $display("TEST FAILED: %0d errors", errors);
    $finish;
  end

  initial begin
    repeat (2000) #1000;
    $display("TEST FAILED: TIMEOUT"); $finish;
  end
endmodule
