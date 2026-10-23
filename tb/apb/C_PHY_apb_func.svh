// SPDX-License-Identifier: Apache-2.0
// C_PHY-specific part of tb/C_PHY_apb_tb.sv. The transmit trio is looped
// back to the receive trio through an injection mux; the TB's own encoder
// (rotations and polarity swaps of the {A, B, C} level tuple) predicts
// every wire state of each burst.
// Checked: bursts of 1 to 8 words written through TX (corner and random
// words) against the predicted wires, the looped-back first word in RX
// and the rest dropped (RX_OVF) when RX is not read; injected bursts of
// 1 to 6 words read through RX at the wire rate; every injected error
// (entry not on +x, wrong sync, invalid wire state, missing transition, a
// group above 65535, a stop inside a word, no post-amble, junk after it)
// with CMD.irq_clear; a late word ending the burst; STATUS.rx_active.
// Covered through the registers: TX_SENT, RX_DONE, ERROR, TX_DONE,
// TX_OVF, RX_AVAIL, RX_OVF, masked, raising irq and cleared.
localparam logic [1:0] L = 2'b00, M = 2'b01, H = 2'b10;
localparam logic [5:0] PX = {H, L, M}, MID = {M, M, M};
logic       inj = 0;
logic [5:0] iw = MID;
always @* {r_a, r_b, r_c} = inj ? iw : {t_a, t_b, t_c};

function automatic logic [5:0] swp(input logic [5:0] t);
  logic [5:0] r;
  for (int i = 0; i < 3; i++) r[2*i +: 2] = t[2*i +: 2] == H ? L : t[2*i +: 2] == L ? H : t[2*i +: 2];
  return r;
endfunction
function automatic logic [5:0] step(input logic [5:0] t, input int s);
  logic [5:0] r;
  if (s == 4) return swp(t);
  r = s[1] ? {t[1:0], t[5:2]} : {t[3:0], t[5:4]};
  return s[0] ? swp(r) : r;
endfunction

// TX wire monitor: the states of each burst
logic [5:0] got_w [0:1023];
int         got_n = 0, bursts = 0;
bit         in_burst = 0;
always @(posedge PCLK) begin
  if ({t_a, t_b, t_c} !== MID) begin
    if (!in_burst) got_n = 0;
    in_burst = 1;
    got_w[got_n] = {t_a, t_b, t_c}; got_n++;
  end else if (in_burst) begin in_burst = 0; bursts++; end
end
logic [5:0]  exp_w [0:1023];
int          exp_n;
logic [15:0] w [0:63];
task automatic add_sym(input int s); exp_w[exp_n] = step(exp_w[exp_n - 1], s); exp_n++; endtask
task automatic expect_burst(input int n);
  int v;
  exp_w[0] = PX; exp_n = 1;
  add_sym(3); for (int i = 0; i < 5; i++) add_sym(4); add_sym(3);
  for (int k = 0; k < n; k++) begin
    v = w[k];
    for (int i = 0; i < 7; i++) begin add_sym(v % 5); v = v / 5; end
  end
  for (int i = 0; i < 7; i++) add_sym(4);
endtask
task automatic irq_expect(input int b);
  cycles(2);
  rd(A_IRQ_STATUS);
  if (!rdv[b]) fail($sformatf("IRQ bit %0d not set (%h)", b, rdv));
  if (!irq) fail("irq low with an enabled bit set");
  wr(A_IRQ_STATUS, 32'(1) << b);
endtask
task automatic wait_tx_idle;
  int c;
  c = 0;
  while ((in_burst || dut.u_core.tstate != 0 || dut.u_core.buf_valid || dut.full_TX) && c < 5000) begin
    @(posedge PCLK); c++;
  end
  cycles(3);
endtask
// a burst of n words from w[] written through TX at the wire rate; the
// wires compared; RX holds the first looped-back word (the rest dropped)
task automatic tx_burst(input int n);
  int b0, k;
  b0 = bursts;
  expect_burst(n);
  no_idle = 1;
  k = 0;
  while (k < n) begin
    rd(A_FLAGS);
    if (!rdv[FLAG_TX_FULL]) begin wr(A_TX, {15'd0, k == n - 1, w[k]}); k++; end
  end
  no_idle = 0;
  wait_tx_idle();
  if (bursts != b0 + 1) fail($sformatf("%0d bursts for %0d words", bursts - b0, n));
  if (got_n != exp_n) fail($sformatf("burst of %0d states, expected %0d", got_n, exp_n));
  for (int i = 0; i < exp_n; i++)
    if (got_w[i] !== exp_w[i]) begin fail($sformatf("state %0d %b, expected %b", i, got_w[i], exp_w[i])); i = exp_n; end
  irq_expect(IRQ_TX_SENT);
  irq_expect(IRQ_RX_DONE);
  rd_exp(A_RX, w[0]);
  rd(A_IRQ_STATUS);
  if (rdv[IRQ_RX_OVF] !== (n > 1)) fail($sformatf("RX_OVF %b after %0d words", rdv[IRQ_RX_OVF], n));
  if (rdv[IRQ_ERROR]) fail("ERROR on a clean burst");
  wr(A_IRQ_STATUS, IRQ_ALL);
endtask

// injection: a sequence of wire states driven on the receive trio
logic [5:0] iseq [0:255];
int         in_n;
task automatic i_start; iseq[0] = PX; in_n = 1; endtask
task automatic i_sym(input int s); iseq[in_n] = step(iseq[in_n - 1], s); in_n++; endtask
task automatic i_raw(input logic [5:0] x); iseq[in_n] = x; in_n++; endtask
task automatic i_sync; i_sym(3); for (int i = 0; i < 5; i++) i_sym(4); i_sym(3); endtask
task automatic i_word(input int v); for (int i = 0; i < 7; i++) begin i_sym(v % 5); v = v / 5; end endtask
task automatic i_post; for (int i = 0; i < 7; i++) i_sym(4); endtask
task automatic i_drive;
  @(negedge PCLK) inj = 1;
  for (int i = 0; i < in_n; i++) begin iw = iseq[i]; @(negedge PCLK); end
  iw = MID; @(negedge PCLK); @(negedge PCLK);
  inj = 0;
endtask
// an injected burst of n words, RX read at the wire rate alongside
task automatic rx_burst(input int n);
  logic [15:0] got [0:63];
  int k;
  bit go;
  i_start(); i_sync();
  for (int j = 0; j < n; j++) i_word(w[j]);
  i_post();
  k = 0;
  fork
    i_drive();
    begin
      no_idle = 1;
      @(negedge PCLK);
      while (!inj) @(negedge PCLK);
      cycles(3);
      rd_exp(A_STATUS, 1);                   // decoding
      go = 1;
      while (go) begin
        rd(A_FLAGS);
        if (rdv[FLAG_RX_AVAIL]) begin rd(A_RX); got[k] = rdv[15:0]; k++; end
        else if (!inj) go = 0;
      end
      no_idle = 0;
    end
  join
  rd_exp(A_STATUS, 0);
  if (k != n) fail($sformatf("%0d words read of %0d", k, n));
  for (int j = 0; j < k && j < n; j++) if (got[j] !== w[j]) fail($sformatf("RX word %0d %h, expected %h", j, got[j], w[j]));
  rd(A_IRQ_STATUS);
  if (!rdv[IRQ_RX_DONE] || rdv[IRQ_RX_OVF] || rdv[IRQ_ERROR]) fail($sformatf("IRQ_STATUS %h after a clean injected burst", rdv));
  wr(A_IRQ_STATUS, IRQ_ALL);
endtask
// an injected error: ERROR set (and set again while sticky), CMD clears it
task automatic i_err;
  i_drive();
  irq_expect(IRQ_ERROR);
  rd(A_IRQ_STATUS);
  if (!rdv[IRQ_ERROR]) fail("ERROR not held by the sticky core flag");
  wr(A_CMD, 1);
  wr(A_IRQ_STATUS, IRQ_ALL);
  rd(A_IRQ_STATUS);
  if (rdv[IRQ_ERROR]) fail("ERROR after CMD.irq_clear");
  rd(A_FLAGS);
  if (rdv[FLAG_RX_AVAIL]) rd(A_RX);
  wr(A_IRQ_STATUS, IRQ_ALL);
endtask

task automatic ip_func;
  wr(A_IRQ_ENABLE, IRQ_ALL);
  rd_exp(A_FLAGS, 0);
  rd_exp(A_STATUS, 0);
  rd(A_RX);                                  // read empty
  // corner words, then single words and random bursts through TX
  w[0] = 16'h0000; w[1] = 16'hFFFF; w[2] = 16'h1234; w[3] = 16'hBEEF;
  w[4] = 16'h8000; w[5] = 16'h7FFF; w[6] = 16'h5555; w[7] = 16'hAAAA;
  tx_burst(8);
  for (int i = 0; i < 3; i++) begin w[0] = $urandom; tx_burst(1); end
  for (int b = 0; b < 3; b++) begin
    for (int k = 0; k < 5; k++) w[k] = $urandom;
    tx_burst(2 + b);
  end
  // a write to TX while full: dropped
  wr(A_TX, {15'd0, 1'b0, 16'h1111});
  wr(A_TX, {15'd0, 1'b0, 16'h2222});
  wr(A_TX, {15'd0, 1'b1, 16'h3333});
  irq_expect(IRQ_TX_OVF);
  wait_tx_idle();
  wr(A_IRQ_STATUS, IRQ_ALL);
  rd(A_FLAGS);
  if (rdv[FLAG_RX_AVAIL]) rd(A_RX);
  // last set with the next word already waiting: two bursts
  begin
    int b0;
    b0 = bursts;
    wr(A_TX, {15'd0, 1'b1, 16'h7777});
    wr(A_TX, {15'd0, 1'b1, 16'h8888});
    wait_tx_idle();
    if (bursts != b0 + 2) fail($sformatf("%0d bursts for two last words", bursts - b0));
    rd(A_FLAGS);
    if (rdv[FLAG_RX_AVAIL]) rd(A_RX);
    wr(A_IRQ_STATUS, IRQ_ALL);
  end
  // a late second word: the burst ends after the first
  w[0] = 16'h0F0F;
  expect_burst(1);
  wr(A_TX, {15'd0, 1'b0, 16'h0F0F});
  wait_tx_idle();
  if (got_n != exp_n) fail("burst not ended by a late word");
  rd_exp(A_RX, 16'h0F0F);
  wr(A_IRQ_STATUS, IRQ_ALL);
  // received bursts read at the wire rate
  for (int n = 1; n <= 6; n++) begin
    for (int k = 0; k < n; k++) w[k] = $urandom;
    rx_burst(n);
  end
  // RX popped in the clock the next word is captured, at every offset
  for (int o = 0; o < 8; o++) begin
    for (int k = 0; k < 3; k++) w[k] = $urandom;
    i_start(); i_sync(); for (int j = 0; j < 3; j++) i_word(w[j]); i_post();
    fork
      i_drive();
      begin
        @(posedge PCLK); while (!dut.c_rx_valid) @(posedge PCLK);
        repeat (o) @(negedge PCLK);
        @(negedge PCLK);
        apb_now(0, A_RX, 0, 0);
      end
    join
    rd(A_FLAGS);
    if (rdv[FLAG_RX_AVAIL]) rd(A_RX);
    wr(A_IRQ_STATUS, IRQ_ALL);
  end
  // injected errors
  i_start(); iseq[0] = step(PX, 1); i_sync(); i_word(5); i_post(); i_err();          // entry not on +x
  i_start(); i_sym(4); i_sym(4); i_err();                                            // wrong sync
  i_start(); i_sync(); i_sym(1); i_raw({H, H, L}); i_err();                         // invalid state
  i_start(); i_sync(); i_sym(2); i_raw(iseq[in_n - 1]); i_err();                    // no transition
  i_start(); i_sync(); i_sym(4); i_sym(4); i_sym(4); i_sym(4); i_sym(4); i_sym(4); i_sym(3); i_err(); // above 65535
  i_start(); i_sync(); i_sym(1); i_sym(2); i_err();                                 // stop inside a word
  i_start(); i_sync(); i_word(1234); i_err();                                       // no post-amble
  i_start(); i_sync(); i_word(99); i_post(); i_sym(1); i_err();                     // junk after
  // masked: left pending into reset
  wr(A_IRQ_ENABLE, 0);
  w[0] = 16'hA5A5; w[1] = 16'h5A5A;
  begin
    wr(A_TX, {15'd0, 1'b0, 16'hA5A5});
    wr(A_TX, {15'd0, 1'b0, 16'h5A5A});
    wr(A_TX, {15'd0, 1'b1, 16'h1234});
    wr(A_TX, {15'd0, 1'b1, 16'h4321});
    wait_tx_idle();
  end
  i_start(); i_sym(4); i_drive();
  cycles(3);
  if (irq) fail("irq with every interrupt masked");
  rd_exp(A_IRQ_STATUS, IRQ_ALL);
endtask
