// SPDX-License-Identifier: Apache-2.0
// Self-checking testbench for I2S_top -- SystemVerilog
// The TB is the I2S bus master: free-running BCLK, LRCK changing on BCLK
// falling edges, its own SDIN words sent with the standard one-BCLK delay,
// and SDOUT sampled on BCLK rising edges and checked against the DUT's
// TX registers. Slot lengths of exactly 16 bits and longer (padded) slots
// are both exercised.
`timescale 1ns/1ps
module I2S_tb;
  logic clk = 0, rst_n = 0;
  logic bclk = 0, lrck = 1;
  logic sdin = 0, sdout;
  logic wen = 0, ren = 0;
  logic [3:0] waddr = 0, raddr = 0;
  logic [15:0] wdata = 0, rdata;
  logic irq;
  int errors = 0;

  I2S_top dut (
    .clk(clk), .rst_n(rst_n), .bclk(bclk), .lrck(lrck),
    .sdin(sdin), .sdout(sdout),
    .wen(wen), .waddr(waddr), .wdata(wdata),
    .ren(ren), .raddr(raddr), .rdata(rdata), .irq(irq));

  always #5 clk = ~clk;
  localparam int HB = 50;               // BCLK half period (ns)

  task automatic wr(input logic [3:0] a, input logic [15:0] d);
    begin
      @(negedge clk); wen <= 1'b1; waddr <= a; wdata <= d;
      @(negedge clk); wen <= 1'b0;
    end
  endtask

  task automatic rd(input logic [3:0] a, output logic [15:0] d);
    begin
      @(negedge clk); ren <= 1'b1; raddr <= a;
      #1 d = rdata;
      @(negedge clk); ren <= 1'b0;
    end
  endtask

  // ---- master BFM ----
  // Word w (w = 0, 1, ...) is the left channel when w is even. LRCK is set
  // for word w at falling edge w*slot; its bits sit on falling edges
  // w*slot+1 .. w*slot+16 and are sampled on the rising edge after each.
  // One extra falling edge ends the run (the last word's LSB at slot 16).
  logic [15:0] m_tx [0:63];             // master -> DUT (sdin)
  logic [15:0] m_rx [0:63];             // DUT -> master (sdout)
  task automatic run(input int nw, input int slot);
    int w, b;
    begin
      for (int i = 0; i < nw; i++) m_rx[i] = 16'h0;
      for (int k = 0; k <= nw * slot; k++) begin
        // falling edge k
        bclk = 0;
        if (k < nw * slot) lrck = ((k / slot) % 2 == 1);
        else               lrck = ((nw % 2) == 1);
        w = (k - 1) / slot; b = (k - 1) % slot;
        sdin = (k >= 1 && b < 16) ? m_tx[w][15 - b] : 1'b0;
        #HB bclk = 1;                   // rising edge k: sample sdout
        if (k >= 1 && b < 16) m_rx[w][15 - b] = sdout;
        #HB;
      end
      bclk = 0;
      #(4 * HB);
    end
  endtask

  // run nw words with the given TX registers; check both directions
  task automatic frames(input int nw, input int slot,
                        input logic [15:0] txl, input logic [15:0] txr,
                        input int rxpat = -1);   // 0 / 1 / 2: zero, ones, 5555-AAAA words
    logic [15:0] got;
    begin
      wr(4'd0, txl); wr(4'd1, txr);
      // idle in the right channel so the first word sees an LRCK change
      lrck = 1; #(4 * HB);
      for (int i = 0; i < nw; i++)
        m_tx[i] = (rxpat == 0) ? 16'h0000 : (rxpat == 1) ? 16'hFFFF :
                  (rxpat == 2) ? ((i % 4 < 2) ? 16'h5555 : 16'hAAAA) : 16'($urandom);
      run(nw, slot);
      for (int i = 0; i < nw; i++)
        if (m_rx[i] !== ((i % 2) ? txr : txl)) begin
          errors++;
          $display("ERROR: I2S slot=%0d word %0d sdout=%h exp=%h", slot, i, m_rx[i],
                   (i % 2) ? txr : txl);
        end
      rd(4'd0, got);
      if (got !== m_tx[(nw - 1) & ~1]) begin
        errors++; $display("ERROR: I2S slot=%0d rx_left=%h exp=%h", slot, got, m_tx[(nw - 1) & ~1]);
      end
      rd(4'd1, got);
      if (got !== m_tx[(nw - 1) | 1] && nw >= 2) begin
        errors++; $display("ERROR: I2S slot=%0d rx_right=%h exp=%h", slot, got, m_tx[(nw - 1) | 1]);
      end
    end
  endtask

  logic [15:0] got;
  initial begin
    rst_n = 0; repeat(10) @(posedge clk);
    rst_n = 1; repeat(10) @(posedge clk);

    frames(4, 16, 16'h1234, 16'hABCD);  // 16-bit slots: LSB at the LRCK edge
    frames(4, 32, 16'h55AA, 16'h0FF0);  // 32-bit slots: 16 padding bits
    frames(4, 17, 16'hFFFF, 16'h0000);
    frames(6, 24, 16'h0000, 16'hFFFF);

    // undefined register addresses: writes ignored, reads return 0
    wr(4'd2, 16'hDEAD);
    wr(4'd12, 16'hBEEF);
    rd(4'd2, got);
    if (got !== 16'h0) begin errors++; $display("ERROR: I2S raddr 2 got=%h", got); end
    rd(4'd15, got);
    if (got !== 16'h0) begin errors++; $display("ERROR: I2S raddr 15 got=%h", got); end

    // random data / slot lengths
    for (int t = 0; t < 40; t++) begin
      int slot;
      slot = $urandom_range(16, 32);
      frames(2 * $urandom_range(1, 4), slot, $urandom, $urandom);
    end

    // reset in the middle of a word: outputs and registers return to zero,
    // and the next run is received correctly
    wr(4'd0, 16'hFFFF);
    lrck = 1; #(4 * HB);
    fork
      run(2, 16);
      begin #(10 * HB) @(negedge clk) rst_n = 1'b0; end
    join
    if (sdout !== 1'b0) begin errors++; $display("ERROR: I2S sdout not 0 in reset"); end
    #(2 * HB) rst_n = 1'b1;
    frames(4, 16, 16'hC3C3, 16'h3C3C);

    // data classes in both directions and on both channels; then slots
    // shorter than the word (truncated words are not stored), followed by
    // a normal run
    frames(4, 16, 16'h5555, 16'hAAAA, 0);
    frames(4, 16, 16'hAAAA, 16'h5555, 1);
    frames(8, 16, 16'h0001, 16'h8000, 2);
    lrck = 1; #(4 * HB);
    run(4, 12);
    frames(4, 16, 16'h1357, 16'h2468);

    if (errors == 0) $display("TEST PASSED: I2S");
    else             $display("TEST FAILED: %0d errors", errors);
    $finish;
  end

  initial begin
    repeat (5000) #1000;
    $display("TIMEOUT"); $finish;
  end
endmodule
