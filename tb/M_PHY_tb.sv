// SPDX-License-Identifier: Apache-2.0
// ============================================================================
// Self-checking testbench for M_PHY_top (MIPI M-PHY lane: 8b/10b, gears,
// HIBERN8). The TB plays the host (byte stream incl. K28.5 comma) and loops
// the serial TX line back into the RX decoder through an injection mux.
// Checks:
//   1. reset state: line DIF-N idle, hibern8/rx_locked/irq low
//   2. G1 burst: K28.5 comma acquires rx_locked; D0.0..D7.0 (all eight
//      implemented D-codes) looped back and compared with k flags
//   3. back-to-back second burst right after the first
//   4. gear switch G1->G2 while idle, burst compare (data integrity after
//      the rate change), then switch back to G1
//   5. HIBERN8: hibern8_req -> SAVE (hibern8 flag, line DIF-Z, rx_hibern),
//      wake_req -> wake burst -> normal idle, transfer works afterwards
//   6. error injection: invalid 10-bit code after comma -> irq
//   7. error injection: valid code with wrong running disparity -> irq;
//      irq_clear clears the sticky flag after each injection
// ============================================================================
`timescale 1ns/1ps
module M_PHY_tb;

  localparam logic [9:0] K28P_RDN = 10'b0011111010; // K28.5 RD- form
  localparam logic [9:0] D00_RDN  = 10'b1001110100; // D0.0  RD- form

  logic clk = 0, rst_n = 0;
  always #5 clk = ~clk;

  logic       gear = 0;
  logic       hibern8_req = 0;
  logic       wake_req = 0;
  wire        hibern8;
  logic [7:0] tx_data = 0;
  logic       tx_k = 0;
  logic       tx_valid = 0;
  wire        tx_ready;
  logic       irq_clear = 0;
  wire        irq;

  wire tx_dif_p, tx_dif_n;

  // injection mux
  logic inj = 0;
  logic i_p = 0, i_n = 1;
  wire rx_dif_p = inj ? i_p : tx_dif_p;
  wire rx_dif_n = inj ? i_n : tx_dif_n;

  wire       rx_locked, rx_hibern;
  wire [7:0] rx_data;
  wire       rx_k, rx_valid;

  int errors = 0;

  M_PHY_top #(.DW(32), .AW(32)) dut (
    .clk(clk), .rst_n(rst_n), .irq(irq), .irq_clear(irq_clear),
    .gear(gear),
    .hibern8_req(hibern8_req), .wake_req(wake_req), .hibern8(hibern8),
    .tx_data(tx_data), .tx_k(tx_k), .tx_valid(tx_valid),
    .tx_ready(tx_ready),
    .tx_dif_p(tx_dif_p), .tx_dif_n(tx_dif_n),
    .rx_dif_p(rx_dif_p), .rx_dif_n(rx_dif_n),
    .rx_locked(rx_locked), .rx_hibern(rx_hibern),
    .rx_data(rx_data), .rx_k(rx_k), .rx_valid(rx_valid)
  );

  // ------------------------------------------------------------------
  // helpers
  // ------------------------------------------------------------------
  task automatic check(input bit cond, input string msg);
    if (!cond) begin
      errors++;
      $display("ERROR: %s (time %0t)", msg, $time);
    end
  endtask

  // RX capture: {k, data}
  logic [8:0] rxq [0:63];
  int         rxn = 0;
  int         rxn_mark;

  always @(posedge clk) begin
    if (rx_valid) begin
      rxq[rxn] = {rx_k, rx_data};
      rxn = rxn + 1;
    end
  end

  // acceptance flag for the byte-stream handshake
  logic acc_tx;
  always @(posedge clk) acc_tx <= tx_valid & tx_ready;

  task automatic tx_push(input logic [7:0] d, input logic k);
    begin
      @(negedge clk);
      tx_data  <= d;
      tx_k     <= k;
      tx_valid <= 1'b1;
      do @(negedge clk); while (acc_tx !== 1'b1);
      tx_valid <= 1'b0;
      tx_k     <= 1'b0;
    end
  endtask

  // wait until rxn reaches target (bounded)
  task automatic wait_rxn(input int target);
    int to;
    begin
      to = 0;
      while (rxn < target && to < 1000) begin
        @(negedge clk);
        to++;
      end
      check(to < 1000, $sformatf("rx word count target %0d (got %0d)", target, rxn));
    end
  endtask

  task automatic check_word(input int idx, input logic [8:0] exp, input string tag);
    check(rxq[idx] === exp,
          $sformatf("%s: rxq[%0d] got={k=%b,d=%h} exp={k=%b,d=%h}",
                    tag, idx, rxq[idx][8], rxq[idx][7:0], exp[8], exp[7:0]));
  endtask

  // injection: one bit (G1 rate, 1 clk), bit 'a' (word[9]) first
  task automatic inj_bit(input logic b);
    begin
      @(negedge clk);
      i_p <= b;
      i_n <= ~b;
    end
  endtask

  task automatic inj_word(input logic [9:0] w);
    for (int i = 9; i >= 0; i--) inj_bit(w[i]);
  endtask

  // ------------------------------------------------------------------
  // stimulus
  // ------------------------------------------------------------------
  initial begin
    // ---- reset ----
    rst_n = 0;
    repeat (4) @(posedge clk);
    rst_n = 1;
    repeat (2) @(posedge clk);

    // check 1: reset state
    check({tx_dif_p, tx_dif_n} === 2'b01, "reset: line idle DIF-N");
    check(hibern8 === 1'b0, "reset: hibern8 low");
    check(rx_locked === 1'b0, "reset: rx_locked low");
    check(irq === 1'b0, "reset: irq low");

    // ---- check 2: G1 burst, comma + all 8 D-codes ----
    rxn_mark = rxn;
    tx_push(8'hBC, 1'b1);              // K28.5 comma
    for (int b = 0; b < 8; b++) tx_push(8'(b), 1'b0);
    wait_rxn(rxn_mark + 9);
    check(rx_locked === 1'b1 || rxn == rxn_mark + 9, "G1 burst decoded");
    check_word(rxn_mark + 0, {1'b1, 8'hBC}, "burst #1 comma");
    for (int b = 0; b < 8; b++)
      check_word(rxn_mark + 1 + b, {1'b0, 8'(b)}, "burst #1 D-code");

    // ---- check 3: back-to-back burst #2 ----
    repeat (12) @(negedge clk);        // let RX fall back to hunt
    check(rx_locked === 1'b0, "rx back to hunt after idle word");
    rxn_mark = rxn;
    tx_push(8'hBC, 1'b1);
    tx_push(8'h07, 1'b0);
    tx_push(8'h06, 1'b0);
    tx_push(8'h05, 1'b0);
    tx_push(8'h04, 1'b0);
    wait_rxn(rxn_mark + 5);
    check_word(rxn_mark + 0, {1'b1, 8'hBC}, "burst #2 comma");
    check_word(rxn_mark + 1, {1'b0, 8'h07}, "burst #2");
    check_word(rxn_mark + 2, {1'b0, 8'h06}, "burst #2");
    check_word(rxn_mark + 3, {1'b0, 8'h05}, "burst #2");
    check_word(rxn_mark + 4, {1'b0, 8'h04}, "burst #2");

    // ---- check 4: gear switch to G2, data integrity ----
    repeat (12) @(negedge clk);
    gear <= 1'b1;
    @(negedge clk);
    rxn_mark = rxn;
    tx_push(8'hBC, 1'b1);
    tx_push(8'h03, 1'b0);
    tx_push(8'h02, 1'b0);
    tx_push(8'h01, 1'b0);
    wait_rxn(rxn_mark + 4);
    check_word(rxn_mark + 0, {1'b1, 8'hBC}, "G2 burst comma");
    check_word(rxn_mark + 1, {1'b0, 8'h03}, "G2 burst");
    check_word(rxn_mark + 2, {1'b0, 8'h02}, "G2 burst");
    check_word(rxn_mark + 3, {1'b0, 8'h01}, "G2 burst");
    repeat (24) @(negedge clk);
    gear <= 1'b0;                      // back to G1 while idle
    @(negedge clk);

    // ---- check 5: HIBERN8 enter / exit ----
    @(negedge clk);
    hibern8_req <= 1'b1;
    @(negedge clk);
    hibern8_req <= 1'b0;
    repeat (2) @(negedge clk);
    check(hibern8 === 1'b1, "HIBERN8: SAVE flag raised");
    check({tx_dif_p, tx_dif_n} === 2'b00, "HIBERN8: line DIF-Z");
    repeat (3) @(negedge clk);
    check(rx_hibern === 1'b1, "HIBERN8: rx_hibern detected");
    check(rx_locked === 1'b0, "HIBERN8: rx unlocked");
    @(negedge clk);
    wake_req <= 1'b1;
    @(negedge clk);
    wake_req <= 1'b0;
    repeat (12) @(negedge clk);        // wake burst (8 clk) + settle
    check(hibern8 === 1'b0, "wake: SAVE flag cleared");
    check({tx_dif_p, tx_dif_n} === 2'b01, "wake: line back to DIF-N idle");
    check(rx_hibern === 1'b0, "wake: rx_hibern cleared");
    // transfer after wake
    rxn_mark = rxn;
    tx_push(8'hBC, 1'b1);
    tx_push(8'h05, 1'b0);
    wait_rxn(rxn_mark + 2);
    check_word(rxn_mark + 0, {1'b1, 8'hBC}, "post-wake comma");
    check_word(rxn_mark + 1, {1'b0, 8'h05}, "post-wake byte");

    // ---- check 6: inject invalid 10-bit code -> irq ----
    repeat (12) @(negedge clk);
    rxn_mark = rxn;
    @(negedge clk);
    inj <= 1'b1;
    inj_word(K28P_RDN);                // lock the RX
    inj_word(10'b1111100000);          // not a valid code
    @(negedge clk);
    i_p <= 1'b0;                       // back to idle levels
    i_n <= 1'b1;
    @(negedge clk);
    inj <= 1'b0;
    repeat (3) @(negedge clk);
    check(irq === 1'b1, "error injection: invalid code raises irq");
    check(rxn === rxn_mark + 1, "invalid code: only the comma was decoded");
    @(negedge clk);
    irq_clear <= 1'b1;
    @(negedge clk);
    irq_clear <= 1'b0;
    @(negedge clk);
    check(irq === 1'b0, "irq cleared by irq_clear");

    // ---- check 7: inject disparity violation (valid code, wrong RD) ----
    @(negedge clk);
    inj <= 1'b1;
    inj_word(K28P_RDN);                // RD- comma -> RX running disparity RD+
    inj_word(D00_RDN);                 // RD- form of D0.0: +2 block needs RD-
    @(negedge clk);
    i_p <= 1'b0;
    i_n <= 1'b1;
    @(negedge clk);
    inj <= 1'b0;
    repeat (3) @(negedge clk);
    check(irq === 1'b1, "error injection: disparity violation raises irq");
    @(negedge clk);
    irq_clear <= 1'b1;
    @(negedge clk);
    irq_clear <= 1'b0;
    @(negedge clk);
    check(irq === 1'b0, "irq cleared after disparity injection");

    // ---- recovery: normal traffic still works ----
    rxn_mark = rxn;
    tx_push(8'hBC, 1'b1);
    tx_push(8'h02, 1'b0);
    wait_rxn(rxn_mark + 2);
    check_word(rxn_mark + 1, {1'b0, 8'h02}, "post-error byte");

    repeat (4) @(negedge clk);
    if (errors == 0) $display("TEST PASSED: M-PHY");
    else             $display("TEST FAILED: %0d errors", errors);
    $finish;
  end

  // timeout guard
  initial begin
    #300000;
    $display("TIMEOUT");
    $display("TEST FAILED: %0d errors", errors + 1);
    $finish;
  end

endmodule
