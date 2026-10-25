// SPDX-License-Identifier: Apache-2.0
// ============================================================================
// Self-checking testbench for UART_top v2.0
//  * TX: random bytes through the tx_valid/tx_ready handshake (valid held
//    while busy, gaps, back-to-back); an independent line decoder samples
//    txd at bit middles and checks every accepted byte and its stop bit.
//  * RX: loopback (rxd = txd) and a line driver with its own bit timing
//    (+-2 clk jitter per bit) sending good frames, framing errors, start-bit
//    glitches, a break, and back-to-back frames; every rx_valid byte and
//    every framing-error irq is checked against what was sent.
//  * reset in the middle of both directions.
// ============================================================================
`timescale 1ns/1ps
module UART_tb;
  localparam int BAUD = 1_000_000;
  localparam int BIT  = 48;                 // clk per bit: 50 MHz / 1 MBd, 16 x 3

  logic clk = 0, rst_n = 0;
  logic rxd, txd;
  logic [7:0] tx_data = 0;
  logic tx_valid = 0, tx_ready;
  logic [7:0] rx_data;
  logic rx_valid, irq;

  UART_top #(.CLK_FREQ(50_000_000), .BAUD(BAUD)) dut (
    .clk(clk), .rst_n(rst_n), .rxd(rxd), .txd(txd),
    .tx_data(tx_data), .tx_valid(tx_valid), .tx_ready(tx_ready),
    .rx_data(rx_data), .rx_valid(rx_valid), .irq(irq));

  always #10 clk = ~clk;                    // 50 MHz

  int errors = 0;
  function automatic void fail(input string m);
    errors++;
    $display("ERROR: %s @%0t", m, $time);
  endfunction
  task automatic cycles(input int n); repeat (n) @(negedge clk); endtask

  // ------------------------------------------------------------ line select
  bit   loop = 1;
  logic drv = 1;
  assign rxd = loop ? txd : drv;

  // ------------------------------------------------------------ TX side
  logic [7:0] txq [$];                      // accepted, not yet seen on txd
  int n_tx = 0;
  int rst_gen = 0;                          // bumped by hard_reset
  bit ign_rx = 0;                           // line tail after a reset: not checked
  always @(posedge clk) if (rst_n && tx_valid && tx_ready) txq.push_back(tx_data);

  // txd decoder: start edge, then sample each bit middle
  initial begin : txmon
    logic [7:0] b;
    int g;
    forever begin
      @(negedge txd);
      g = rst_gen;
      if (rst_n) begin
        repeat (BIT / 2) @(posedge clk);
        if (txd !== 0) fail("txd start bit");
        for (int i = 0; i < 8; i++) begin repeat (BIT) @(posedge clk); b[i] = txd; end
        repeat (BIT) @(posedge clk);
        if (txd !== 1) fail("txd stop bit");
        if (g != rst_gen) ;           // frame cut by a reset
        else if (txq.size() == 0) fail("byte on txd that was not accepted");
        else begin
          if (b !== txq[0]) fail($sformatf("txd byte %h exp %h", b, txq[0]));
          void'(txq.pop_front());
          n_tx++;
        end
      end
    end
  end

  task automatic send(input logic [7:0] d, input int gap);
    tx_data = d; tx_valid = 1;
    @(posedge clk);
    while (!tx_ready) @(posedge clk);
    @(negedge clk);
    tx_valid = 0; tx_data = $urandom;
    cycles(gap);
  endtask

  // ------------------------------------------------------------ RX side
  logic [7:0] rxq [$];                      // expected bytes, in order
  int n_rx = 0, n_ferr = 0;
  always @(posedge clk) if (rst_n && !ign_rx) begin
    if (rx_valid) begin
      if (rxq.size() == 0) fail($sformatf("unexpected rx byte %h", rx_data));
      else begin
        if (rx_data !== rxq[0]) fail($sformatf("rx byte %h exp %h", rx_data, rxq[0]));
        void'(rxq.pop_front());
      end
      n_rx++;
    end
    if (irq && !rx_valid) n_ferr++;
    if (irq !== (rx_valid || dut.frame_err)) fail("irq");
  end

  // drive one frame on rxd with per-bit jitter; stop bit value given
  task automatic line_frame(input logic [7:0] d, input logic stop);
    drv = 0; cycles(BIT + $urandom_range(0, 4) - 2);
    for (int i = 0; i < 8; i++) begin drv = d[i]; cycles(BIT + $urandom_range(0, 4) - 2); end
    drv = stop; cycles(BIT);
    drv = 1;
  endtask

  task automatic rx_good(input logic [7:0] d, input int idle);
    rxq.push_back(d);
    line_frame(d, 1);
    cycles(idle);
  endtask

  task automatic hard_reset;
    rst_n = 0; rst_gen++;
    cycles(3);
    if (txd !== 1 || tx_ready !== 1 || rx_valid !== 0 || irq !== 0 || rx_data !== 0)
      fail("reset values");
    txq.delete(); rxq.delete();
    tx_valid = 0; drv = 1;
    rst_n = 1;
    cycles(2);
  endtask

  task automatic drain;
    int t;
    t = 0;
    while ((txq.size() > 0 || rxq.size() > 0) && t < 100000) begin @(negedge clk); t++; end
    cycles(2 * BIT);
    if (txq.size() || rxq.size()) fail($sformatf("not drained: tx %0d rx %0d", txq.size(), rxq.size()));
  endtask

  initial begin
    cycles(3);
    if (txd !== 1 || tx_ready !== 1 || rx_valid !== 0 || irq !== 0) fail("reset values");
    rst_n = 1;
    cycles(5);

    // ---- loopback: all byte values, random gaps (0 = back to back)
    loop = 1;
    for (int i = 0; i < 256; i++) begin
      logic [7:0] d;
      d = i[7:0] ^ 8'h5A;
      rxq.push_back(d);
      send(d, ($urandom % 4 == 0) ? $urandom % 200 : 0);
    end
    drain();

    // ---- external line: jittered good frames, errors, glitches, break
    loop = 0;
    drv = 1; cycles(100);
    for (int i = 0; i < 40; i++) rx_good($urandom, $urandom % 3 == 0 ? 0 : $urandom % 100);
    drain();
    begin
      int f0;
      f0 = n_ferr;
      line_frame(8'hA5, 0); cycles(2 * BIT);          // stop bit 0: framing error
      line_frame(8'h00, 0); cycles(2 * BIT);
      if (n_ferr != f0 + 2) fail("framing errors not reported");
      drv = 0; cycles(20 * BIT); drv = 1; cycles(2 * BIT);   // break: one framing error
      if (n_ferr != f0 + 3) fail("break not reported once");
    end
    for (int w = 2; w < 18; w += 3) begin            // start-bit glitches shorter than half a bit
      drv = 0; cycles(w); drv = 1; cycles(2 * BIT);
    end
    if (n_rx != 296) fail($sformatf("rx bytes after glitches: %0d", n_rx));
    rx_good(8'hFF, 0); rx_good(8'h00, 0); rx_good(8'h80, 5);
    drain();

    // ---- both directions at once (external line + TX)
    fork
      for (int i = 0; i < 10; i++) send($urandom, $urandom % 50);
      for (int i = 0; i < 10; i++) rx_good($urandom, $urandom % 50);
    join
    drain();

    // ---- reset in the middle of a TX frame and an RX frame
    fork
      send(8'h3C, 0);
      begin cycles(5); line_frame(8'hC3, 1); end
    join_none
    cycles(4 * BIT);
    ign_rx = 1;
    hard_reset();
    cycles(12 * BIT);
    ign_rx = 0;
    loop = 1;
    for (int i = 0; i < 4; i++) begin logic [7:0] d; d = $urandom; rxq.push_back(d); send(d, 0); end
    drain();

    $display("tx %0d bytes, rx %0d bytes, %0d framing errors", n_tx, n_rx, n_ferr);
    if (errors == 0) $display("TEST PASSED: UART");
    else $display("TEST FAILED: UART (%0d errors)", errors);
    $finish;
  end

  initial begin
    #50ms;
    $display("TEST FAILED: UART (timeout)");
    $finish;
  end
endmodule
