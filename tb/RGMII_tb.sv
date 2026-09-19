// SPDX-License-Identifier: Apache-2.0
// Self-checking testbench: RGMII loopback (rxd=txd, rx_ctl=tx_ctl, rx_clk=tx_clk)
`timescale 1ns/1ps
module RGMII_tb;
  logic clk = 0, rst_n = 0;
  logic tx_clk = 0, rx_clk;
  logic [3:0] txd, rxd;
  logic tx_ctl, rx_ctl;
  logic wen = 0, ren = 0;
  logic [3:0] waddr = 0, raddr = 0;
  logic [7:0] wdata = 0, rdata;
  logic [4:0] count;
  int errors = 0;

  RGMII_top dut (
    .clk(clk), .rst_n(rst_n), .tx_clk(tx_clk), .txd(txd), .tx_ctl(tx_ctl),
    .rx_clk(rx_clk), .rxd(rxd), .rx_ctl(rx_ctl),
    .wen(wen), .waddr(waddr), .wdata(wdata),
    .ren(ren), .raddr(raddr), .rdata(rdata), .count(count), .irq());

  always #5 clk = ~clk;
  always #40 tx_clk = ~tx_clk;         // 12.5 MHz -> 25 MHz nibble rate
  assign rx_clk  = tx_clk;
  assign rxd     = txd;
  assign rx_ctl  = tx_ctl;

  task automatic wr(input logic [7:0] d);
    begin
      @(negedge clk); wen <= 1'b1; waddr <= 4'd0; wdata <= d;
      @(negedge clk); wen <= 1'b0;
    end
  endtask
  task automatic rd(input logic [3:0] a, output logic [7:0] d);
    begin
      @(negedge clk); ren <= 1'b1; raddr <= a;
      #1 d = rdata;
      @(negedge clk); ren <= 1'b0;
    end
  endtask

  logic [7:0] got;
  logic [7:0] exp [0:7];
  initial begin
    for (int i = 0; i < 8; i++) exp[i] = 8'h10 + i * 8'h11;
    rst_n = 0; repeat(5) @(posedge clk);
    rst_n = 1; repeat(5) @(posedge clk);

    for (int i = 0; i < 8; i++) wr(exp[i]);
    // wait for all 8 bytes received (2 nibbles each -> 16 edges)
    wait (count == 5'd8);
    repeat(10) @(posedge clk);
    for (int i = 0; i < 8; i++) begin
      rd(i[3:0], got);
      if (got !== exp[i]) begin
        errors++; $display("ERROR: RGMII rxq[%0d] got=%h exp=%h", i, got, exp[i]);
      end
    end

    if (errors == 0) $display("TEST PASSED: RGMII");
    else             $display("TEST FAILED: %0d errors", errors);
    $finish;
  end

  initial begin
    #2_000_000; $display("TIMEOUT"); $finish;
  end
endmodule
