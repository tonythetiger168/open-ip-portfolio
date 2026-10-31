// SPDX-License-Identifier: Apache-2.0
// TRNG-specific part of tb/TRNG_apb_tb.sv: a noise model on the ring
// oscillator pins (random bits, a stuck source, or long runs); everything
// else goes through the registers. A raw word from the test LFSR is compared
// with the LFSR computed here (the first word after the 1024 start-up
// samples); conditioned seeds from the ring oscillators are read through
// ENT with the FIPS flag; then a repetition count failure and an adaptive
// proportion failure (ALERT, STATUS flags, FAILS, the alert and es_ok pins,
// recovery by clearing and setting en), long runs for the high-water marks,
// and enough forced failures to count FAILS past 128 for each test.
int ro_mode = 0;                        // 0 random, 1 stuck, 2 runs of 250 ones and a zero
int ro_pos = 0;
initial ro_in = 4'h0;
always @(negedge PCLK) begin
  logic b;
  logic [2:0] r;
  r = 3'($urandom);
  b = ro_mode == 0 ? 1'($urandom) : ro_mode == 1 ? 1'b0 : ro_pos < 250;
  ro_pos = ro_pos >= 250 ? 0 : ro_pos + 1;
  ro_in <= {r, b ^ (^r)};
end
int n_alert = 0;
always @(posedge PCLK) if (alert) n_alert++;

// CTRL value: en, src_sel, cond_bypass, cond_blks, smp_div
function automatic logic [31:0] tr_ctrl(input bit e, input bit src, input bit byp, input logic [1:0] nb,
                                        input logic [7:0] div);
  tr_ctrl = {19'd0, div, nb, byp, src, e};
endfunction
task automatic tr_start(input logic [31:0] c);
  wr(A_CTRL, c & ~32'h1);
  wr(A_IRQ_STATUS, IRQ_ALL);
  wr(A_CTRL, c | 32'h1);
endtask
// read one ENT word once available
task automatic tr_word(output logic [31:0] w);
  poll(A_FLAGS, 32'h1 << FLAG_ENT_AVAIL, 32'h1 << FLAG_ENT_AVAIL, 20000);
  rd(A_ENT);
  w = rdv;
endtask

task automatic ip_func;
  logic [31:0] w, l, exp;
  rd_exp(A_STATUS, 32'h0);                                // IDLE
  rd(A_ENT);                                              // empty: nothing to pop
  // ---- interrupts masked: a raw word sets SEED and ENT_AVAIL, irq stays low
  wr(A_IRQ_ENABLE, 32'h0);
  tr_start(tr_ctrl(1, 0, 1, 2'd0, 8'd0));
  poll(A_IRQ_STATUS, 32'h5, 32'h5, 2000);
  if (irq !== 1'b0) fail("irq with every source masked");
  wr(A_HEALTH, {13'd0, 11'd793, 8'd1});                   // and ALERT
  poll(A_IRQ_STATUS, 32'h2, 32'h2, 100);
  if (irq !== 1'b0) fail("irq with ALERT masked");
  rd(A_ENT);
  wr(A_HEALTH, 32'h31929);
  wr(A_IRQ_ENABLE, IRQ_ALL);
  // ---- a raw word from the test LFSR: samples 1025 to 1056 after the start
  wr(A_LFSR_SEED, 32'hC0FF_EE01);
  tr_start(tr_ctrl(1, 1, 1, 2'd0, 8'd0));
  l = 32'hC0FF_EE01;
  exp = '0;
  for (int k = 1; k <= 1056; k++) begin
    if (k > 1024) exp = {exp[30:0], l[0]};
    l = l[0] ? (l >> 1) ^ 32'h8020_0003 : l >> 1;
  end
  tr_word(w);
  if (w != exp) fail($sformatf("LFSR raw word %h, expected %h", w, exp));
  rd(A_IRQ_STATUS);
  if (!rdv[IRQ_SEED] || rdv[IRQ_ALERT]) fail($sformatf("IRQ_STATUS %h after a raw word", rdv));
  if (irq !== 1'b1) fail("irq low with SEED pending and enabled");
  rd(A_STATUS);
  if (rdv[3] !== 1'b1 || rdv[4] !== 1'b0 || es_ok !== 1'b1) fail($sformatf("STATUS %h in LFSR bypass", rdv));
  for (int i = 0; i < 6; i++) tr_word(w);
  // ---- conditioned seeds from the ring oscillators (one and four blocks)
  tr_start(tr_ctrl(1, 0, 0, 2'd0, 8'd1));
  poll(A_STATUS, 32'h7, 32'h2, 2000);                     // RUN after the start-up window
  rd(A_STATUS);
  if (rdv[4:3] != 2'b11) fail($sformatf("STATUS %h: not running in the FIPS configuration", rdv));
  for (int i = 0; i < 16; i++) tr_word(w);
  tr_start(tr_ctrl(1, 0, 0, 2'd3, 8'd0));
  for (int i = 0; i < 8; i++) tr_word(w);
  rd(A_WATERMARK);
  if (rdv[7:0] == 0 || rdv[7:0] >= 41 || rdv[18:8] == 0) fail($sformatf("WATERMARK %h", rdv));
  // ---- repetition count failure: a stuck source
  wr(A_IRQ_STATUS, IRQ_ALL);
  n_alert = 0;
  ro_mode = 1;
  poll(A_IRQ_STATUS, 32'h1 << IRQ_ALERT, 32'h1 << IRQ_ALERT, 500);
  rd(A_STATUS);
  if (rdv[2:0] != 3'd5 || rdv[6:3] != 4'b0100) fail($sformatf("STATUS %h after an RCT failure", rdv));
  if (n_alert != 1 || es_ok !== 1'b0) fail("alert / es_ok pins after an RCT failure");
  rd_exp(A_FAILS, 32'h0000_0002);
  ro_mode = 0;
  // recovery
  tr_start(tr_ctrl(1, 0, 0, 2'd1, 8'd0));
  for (int i = 0; i < 8; i++) tr_word(w);
  rd(A_STATUS);
  if (rdv[6:5] != 2'b00) fail("alert flags not cleared by a restart");
  // ---- adaptive proportion failure: the cutoff lowered while running
  wr(A_HEALTH, {13'd0, 11'd2, 8'd41});
  poll(A_IRQ_STATUS, 32'h1 << IRQ_ALERT, 32'h1 << IRQ_ALERT, 500);
  rd(A_STATUS);
  if (rdv[2:0] != 3'd5 || rdv[6:5] != 2'b10) fail($sformatf("STATUS %h after an APT failure", rdv));
  rd_exp(A_FAILS, 32'h0000_0102);
  // ---- long runs: high-water marks near the limits
  wr(A_HEALTH, {13'd0, 11'd2047, 8'd255});
  ro_mode = 2;
  tr_start(tr_ctrl(1, 0, 1, 2'd0, 8'd0));
  for (int i = 0; i < 40; i++) tr_word(w);
  rd(A_WATERMARK);
  if (rdv[7:0] < 8'd200 || rdv[18:8] < 11'd900) fail($sformatf("WATERMARK %h after long runs", rdv));
  ro_mode = 0;
  wr(A_CTRL, 32'h8);
  // ---- forced failures (cutoff 1): FAILS counts each test past 128
  wr(A_HEALTH, {13'd0, 11'd793, 8'd1});
  for (int i = 0; i < 130; i++) begin
    tr_start(tr_ctrl(1, 0, 0, 2'd1, 8'd0));
    poll(A_STATUS, 32'h7, 32'h5, 50);
  end
  wr(A_HEALTH, {13'd0, 11'd1, 8'd41});
  for (int i = 0; i < 130; i++) begin
    tr_start(tr_ctrl(1, 0, 0, 2'd1, 8'd0));
    poll(A_STATUS, 32'h7, 32'h5, 50);
  end
  rd_exp(A_FAILS, {16'd0, 8'd131, 8'd132});
  wr(A_HEALTH, 32'h31929);
  wr(A_CTRL, 32'h8);                                      // ALERT left pending into the reset
endtask
