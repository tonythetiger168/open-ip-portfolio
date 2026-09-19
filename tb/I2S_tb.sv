// SPDX-License-Identifier: Apache-2.0
// Self-checking testbench for I2S_top: loopback SDIN=SDOUT -- SystemVerilog
`timescale 1ns/1ps
module I2S_tb;
  logic clk = 0, rst_n = 0;
  logic bclk = 0, lrck = 0;
  logic sdin, sdout;
  logic wen = 0, ren = 0;
  logic [3:0] waddr = 0, raddr = 0;
  logic [15:0] wdata = 0, rdata;
  int errors = 0;

  I2S_top dut (
    .clk(clk), .rst_n(rst_n), .bclk(bclk), .lrck(lrck),
    .sdin(sdin), .sdout(sdout),
    .wen(wen), .waddr(waddr), .wdata(wdata),
    .ren(ren), .raddr(raddr), .rdata(rdata), .irq());

  always #5 clk = ~clk;
  assign sdin = sdout;   // loopback

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

  task automatic channel(input logic lr);
    begin
      if (lrck == lr) lrck = ~lr;   // force a transition so frame-sync fires
      #600;
      lrck = lr;
      #600;
      for (int i = 0; i < 16; i++) begin
        bclk = 1; #300; bclk = 0; #300;
      end
    end
  endtask

  logic [15:0] gotL, gotR;
  initial begin
    rst_n = 0; repeat(10) @(posedge clk);
    rst_n = 1; repeat(10) @(posedge clk);

    wr(4'd0, 16'h1234);   // tx_left
    wr(4'd1, 16'hABCD);   // tx_right

    channel(1'b0);        // left frame:  shifts tx_left out, loops back in
    channel(1'b1);        // right frame: shifts tx_right out

    rd(4'd0, gotL);
    rd(4'd1, gotR);
    if (gotL !== 16'h1234) begin errors++; $display("ERROR: I2S left got=%h exp=1234", gotL); end
    if (gotR !== 16'hABCD) begin errors++; $display("ERROR: I2S right got=%h exp=ABCD", gotR); end

    // second pass: change data, verify again
    wr(4'd0, 16'h55AA);
    channel(1'b0);
    rd(4'd0, gotL);
    if (gotL !== 16'h55AA) begin errors++; $display("ERROR: I2S left2 got=%h exp=55AA", gotL); end

    if (errors == 0) $display("TEST PASSED: I2S");
    else             $display("TEST FAILED: %0d errors", errors);
    $finish;
  end

  initial begin
    #1_000_000; $display("TIMEOUT"); $finish;
  end
endmodule
