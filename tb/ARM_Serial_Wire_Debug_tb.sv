// SPDX-License-Identifier: Apache-2.0
// Self-checking loopback testbench for UART_top -- SystemVerilog
`timescale 1ns/1ps
module ARM_Serial_Wire_Debug_tb;
  localparam int N = 8;
  logic clk = 0, rst_n = 0;
  logic rxd, txd;
  logic [7:0] tx_data;
  logic tx_valid, tx_ready;
  logic [7:0] rx_data;
  logic rx_valid;
  logic [7:0] sent [0:N-1];
  int errors = 0;

  ARM_Serial_Wire_Debug_top #(.CLK_FREQ(50_000_000), .BAUD(1_000_000)) dut (
    .clk(clk), .rst_n(rst_n), .rxd(rxd), .txd(txd),
    .tx_data(tx_data), .tx_valid(tx_valid), .tx_ready(tx_ready),
    .rx_data(rx_data), .rx_valid(rx_valid), .irq());

  always #5 clk = ~clk;
  assign rxd = txd;    // loopback

  initial begin
    tx_valid = 0; tx_data = 0;
    rst_n = 0; repeat(10) @(posedge clk);
    rst_n = 1; repeat(20) @(posedge clk);
    for (int i = 0; i < N; i++) begin
      sent[i] = 8'hA5 ^ (i * 8'h11);
      wait (tx_ready === 1'b1);        // ensure TX is idle before requesting
      @(negedge clk);
      tx_data  <= sent[i];
      tx_valid <= 1'b1;
      wait (tx_ready === 1'b0);        // now this edge means real acceptance
      @(negedge clk);
      tx_valid <= 1'b0;
      wait (rx_valid === 1'b1);
      @(posedge clk); #1;
      if (rx_data !== sent[i]) begin
        errors++;
        $display("ERROR: ARM Serial Wire Debug byte %0d got=%h exp=%h", i, rx_data, sent[i]);
      end
      repeat (40) @(posedge clk);   // inter-frame idle: RX back to IDLE
    end
    if (errors == 0) $display("TEST PASSED: ARM Serial Wire Debug");
    else             $display("TEST FAILED: %0d errors", errors);
    $finish;
  end

  initial begin
    #5_000_000; $display("TIMEOUT"); $finish;
  end
endmodule
