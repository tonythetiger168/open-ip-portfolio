// SPDX-License-Identifier: Apache-2.0
// ============================================================================
// Self-checking testbench for M_PHY_top (MIPI M-PHY lane: full 8b/10b,
// gears, HIBERN8). The TB is the host (byte stream with K28.5 commas) and
// loops the serial line back into the receiver through an injection mux.
// Every looped-back byte and K flag is compared with what was sent.
// Covered: all 256 D-codes and the 12 K-codes at G1 and G2, both comma
// polarities, chained words, the inter-burst gap, an unsupported K-code,
// HIBERN8 enter / wake (TX and injected DIF-Z), a gear change while
// locked, invalid codes, disparity errors, irq_clear and a reset mid-burst.
// ============================================================================
`timescale 1ns/1ps
module M_PHY_tb;
  localparam logic [9:0] K28P_RDN = 10'b0011111010;
  localparam logic [9:0] K28P_RDP = 10'b1100000101;
  localparam logic [9:0] D00_RDN  = 10'b1001110100;

  logic clk = 0, rst_n = 0;
  always #5 clk = ~clk;

  logic       gear = 0, hibern8_req = 0, wake_req = 0, irq_clear = 0;
  logic [7:0] tx_data = 0;
  logic       tx_k = 0, tx_valid = 0;
  wire        tx_ready, hibern8, irq, tx_dif_p, tx_dif_n;
  logic       inj = 0, i_p = 0, i_n = 1;
  wire        rx_dif_p = inj ? i_p : tx_dif_p;
  wire        rx_dif_n = inj ? i_n : tx_dif_n;
  wire        rx_locked, rx_hibern, rx_k, rx_valid;
  wire [7:0]  rx_data;
  int errors = 0;

  M_PHY_top dut (
    .clk(clk), .rst_n(rst_n), .irq(irq), .irq_clear(irq_clear), .gear(gear),
    .hibern8_req(hibern8_req), .wake_req(wake_req), .hibern8(hibern8),
    .tx_data(tx_data), .tx_k(tx_k), .tx_valid(tx_valid), .tx_ready(tx_ready),
    .tx_dif_p(tx_dif_p), .tx_dif_n(tx_dif_n), .rx_dif_p(rx_dif_p), .rx_dif_n(rx_dif_n),
    .rx_locked(rx_locked), .rx_hibern(rx_hibern), .rx_data(rx_data), .rx_k(rx_k),
    .rx_valid(rx_valid)
  );

  task automatic check(input bit cond, input string msg);
    if (!cond) begin errors++; $display("ERROR: %s (time %0t)", msg, $time); end
  endtask

  // received words
  logic [8:0] rxl [0:4095];
  int         rxn = 0;
  always @(posedge clk) if (rx_valid) begin rxl[rxn] = {rx_k, rx_data}; rxn++; end

  // sent words of the current burst
  logic [8:0] sent [0:511];
  int         sn;

  task automatic push(input logic [7:0] d, input logic k);
    begin
      @(negedge clk);
      tx_data = d; tx_k = k; tx_valid = 1;
      @(posedge clk);
      while (!tx_ready) @(posedge clk);
      @(negedge clk);
      tx_valid = 0; tx_k = 0;
    end
  endtask

  task automatic wait_quiet;
    int c;
    begin
      c = 0;
      while ((dut.tstate != 0 || dut.buf_valid || dut.gap_cnt != 0 || rx_locked) && c < 20000) begin
        @(posedge clk); c++;
      end
      repeat (4) @(posedge clk);
    end
  endtask

  // one burst: comma then sn words from sent[1..]; compare the loopback
  task automatic burst;
    int r0;
    begin
      r0 = rxn;
      sent[0] = {1'b1, 8'hBC};
      for (int i = 0; i < sn; i++) push(sent[i][7:0], sent[i][8]);
      wait_quiet();
      check(rxn == r0 + sn, $sformatf("burst: %0d words back, %0d sent", rxn - r0, sn));
      for (int i = 0; i < sn && i < rxn - r0; i++)
        if (rxl[r0 + i] !== sent[i]) begin
          errors++; $display("ERROR: word %0d got %h exp %h", i, rxl[r0 + i], sent[i]);
        end
      check(irq === 1'b0, "irq after a clean burst");
    end
  endtask

  // injection, one bit per clk (G1) or two (G2)
  task automatic inj_word(input logic [9:0] w);
    for (int i = 9; i >= 0; i--) begin
      @(negedge clk); i_p = w[i]; i_n = ~w[i];
      if (gear) @(negedge clk);
    end
  endtask
  task automatic inj_idle(input int n);
    repeat (n) begin @(negedge clk); i_p = 0; i_n = 1; end
  endtask
  task automatic clear_irq;
    begin @(negedge clk); irq_clear = 1; @(negedge clk); irq_clear = 0; end
  endtask

  initial begin
    repeat (4) @(negedge clk);
    check({tx_dif_p, tx_dif_n} === 2'b01 && !hibern8 && !irq && !rx_locked && !rx_valid, "reset state");
    rst_n = 1;
    repeat (4) @(negedge clk);

    // ---- every D-code, both gears ----
    for (int g = 0; g < 2; g++) begin
      gear = g[0];
      repeat (4) @(negedge clk);
      for (int b = 0; b < 256; b += 32) begin
        sn = 33;
        for (int i = 0; i < 32; i++) sent[i + 1] = {1'b0, 8'(b + i)};
        burst();
      end
    end
    gear = 0;
    // ---- every K-code ----
    sn = 13;
    sent[1] = {1'b1, 8'h1C}; sent[2] = {1'b1, 8'h3C}; sent[3] = {1'b1, 8'h5C};
    sent[4] = {1'b1, 8'h7C}; sent[5] = {1'b1, 8'h9C}; sent[6] = {1'b1, 8'hBC};
    sent[7] = {1'b1, 8'hDC}; sent[8] = {1'b1, 8'hFC}; sent[9] = {1'b1, 8'hF7};
    sent[10] = {1'b1, 8'hFB}; sent[11] = {1'b1, 8'hFD}; sent[12] = {1'b1, 8'hFE};
    burst();
    // ---- random bursts (both running disparities on every code) ----
    for (int t = 0; t < 40; t++) begin
      gear = $urandom_range(0, 3) == 0;
      repeat (3) @(negedge clk);
      sn = $urandom_range(2, 60);
      for (int i = 1; i < sn; i++) sent[i] = {1'b0, 8'($urandom)};
      burst();
    end
    gear = 0;
    repeat (4) @(negedge clk);

    // ---- next burst queued during the inter-burst gap, both gears ----
    for (int g = 0; g < 2; g++) begin
      int r0;
      gear = g[0];
      repeat (4) @(negedge clk);
      r0 = rxn;
      push(8'hBC, 1); push(8'h55, 0);
      while (dut.tstate != 0) @(negedge clk);
      push(8'hBC, 1); push(8'h66, 0);
      wait_quiet();
      check(rxn == r0 + 4 && rxl[r0 + 1] === 9'h055 && rxl[r0 + 2] === 9'h1BC && rxl[r0 + 3] === 9'h066,
            "burst queued in the gap");
    end
    gear = 0;

    // ---- unsupported K-code: dropped, irq ----
    push(8'hBC, 1); push(8'h05, 1); push(8'h21, 0);
    wait_quiet();
    check(irq === 1'b1, "unsupported K-code raises irq");
    clear_irq();
    check(irq === 1'b0, "irq_clear");
    // an unsupported K-code waiting while the line is idle
    push(8'h00, 1);
    wait_quiet();
    check(irq === 1'b1, "unsupported K-code at idle raises irq");
    clear_irq();

    // ---- HIBERN8 ----
    @(negedge clk); hibern8_req = 1; @(negedge clk); hibern8_req = 0;
    repeat (6) @(negedge clk);
    check(hibern8 === 1'b1 && {tx_dif_p, tx_dif_n} === 2'b00 && rx_hibern === 1'b1, "HIBERN8 entered");
    check(tx_ready === 1'b0, "tx_ready low in HIBERN8");
    repeat (10) @(negedge clk);
    @(negedge clk); wake_req = 1; @(negedge clk); wake_req = 0;
    repeat (12) @(negedge clk);
    check(hibern8 === 1'b0 && rx_hibern === 1'b0 && {tx_dif_p, tx_dif_n} === 2'b01, "woke up");
    sn = 4; sent[1] = 9'h0A5; sent[2] = 9'h05A; sent[3] = 9'h1FE; burst();
    // HIBERN8 request while a byte is buffered: the byte goes first
    fork
      push(8'hBC, 1);
      begin @(negedge clk); @(negedge clk); hibern8_req = 1; @(negedge clk); hibern8_req = 0; end
    join
    wait_quiet();
    @(negedge clk); wake_req = 1; @(negedge clk); wake_req = 0;
    repeat (12) @(negedge clk);

    // ---- injected line: errors, gear change while locked, DIF-Z ----
    inj = 1;
    inj_idle(12);
    inj_word(K28P_RDN); inj_word(10'b1111100000);           // invalid code
    inj_idle(12);
    check(irq === 1'b1, "invalid code raises irq"); clear_irq();
    inj_word(K28P_RDN); inj_word(D00_RDN);                  // wrong disparity
    inj_idle(12);
    check(irq === 1'b1, "disparity error raises irq"); clear_irq();
    inj_word(K28P_RDP); inj_word(D00_RDN);                  // RD+ comma, then RD- form
    inj_idle(12);
    check(irq === 1'b0, "RD+ comma then a matching code");
    inj_word(K28P_RDN); inj_word(10'b0110001011);           // then a mid-burst gear change
    @(negedge clk); gear = 1;
    repeat (4) @(negedge clk);
    check(rx_locked === 1'b0, "gear change while locked re-hunts");
    inj_idle(4);
    inj_word(K28P_RDP); inj_word(10'b1001110100);           // G2 lock, injected
    inj_idle(30);
    gear = 0;
    inj_idle(4);
    inj_word(K28P_RDN);                                     // DIF-Z while locked
    @(negedge clk); i_p = 0; i_n = 0;
    repeat (6) @(negedge clk);
    check(rx_hibern === 1'b1, "DIF-Z seen as hibernation");
    inj_idle(4);
    check(rx_hibern === 1'b0 && rx_locked === 1'b0, "wake re-hunts");
    inj_word(K28P_RDN); inj_word(10'b0001110100);           // D7.0 RD+ form at RD+
    // irq_clear in the same cycle as a new error: the error wins
    inj_word(10'b1111111111);
    inj_idle(12);
    clear_irq();
    inj = 0;
    repeat (4) @(negedge clk);

    // ---- reset in the middle of a burst ----
    push(8'hBC, 1); push(8'h11, 0); push(8'h22, 0);
    repeat (8) @(negedge clk);
    rst_n = 0; @(negedge clk);
    check({tx_dif_p, tx_dif_n} === 2'b01 && !rx_locked && !irq && tx_ready, "reset mid-burst");
    rst_n = 1; repeat (4) @(negedge clk);
    sn = 3; sent[1] = 9'h033; sent[2] = 9'h0CC; burst();

    if (errors == 0) $display("TEST PASSED: M_PHY");
    else             $display("TEST FAILED: %0d errors", errors);
    $finish;
  end

  initial begin
    repeat (3000) #1000;
    $display("TEST FAILED: TIMEOUT"); $finish;
  end
endmodule
