// SPDX-License-Identifier: Apache-2.0
// Self-checking testbench for Avalon_ST_top -- SystemVerilog
`timescale 1ns/1ps
module Avalon_ST_tb;
  logic clk = 0, rst_n = 0;
  logic av_valid = 0, av_ready;
  logic [31:0] av_data = 0;
  logic av_eop = 0;
  logic ren = 0;
  logic [3:0] raddr = 0;
  logic [31:0] rdata;
  logic [4:0] count;
  logic irq;
  logic irq_seen = 0;
  int errors = 0;

  Avalon_ST_top dut (
    .clk(clk), .rst_n(rst_n), .av_valid(av_valid), .av_ready(av_ready),
    .av_data(av_data), .av_eop(av_eop), .ren(ren), .raddr(raddr),
    .rdata(rdata), .count(count), .irq(irq));

  always #5 clk = ~clk;
  always @(posedge clk) if (irq) irq_seen <= 1'b1;

  task automatic send(input logic [31:0] d, input logic eop);
    begin
      wait (av_ready === 1'b1);
      @(negedge clk);
      av_data <= d; av_eop <= eop; av_valid <= 1'b1;
      @(posedge clk); #1;
      @(negedge clk);
      av_valid <= 1'b0; av_eop <= 1'b0;
    end
  endtask

  logic [31:0] exp [0:3];
  initial begin
    exp[0] = 32'h1111_2222; exp[1] = 32'h3333_4444;
    exp[2] = 32'h5555_6666; exp[3] = 32'h7777_8888;
  end
  initial begin
    rst_n = 0; repeat(5) @(posedge clk);
    rst_n = 1; repeat(5) @(posedge clk);

    for (int i = 0; i < 4; i++) send(exp[i], i == 3);

    repeat(2) @(posedge clk);
    if (count !== 5'd4) begin
      errors++; $display("ERROR: Avalon-ST count got=%0d exp=4", count);
    end
    if (!irq_seen) begin
      errors++; $display("ERROR: Avalon-ST irq never fired");
    end
    for (int i = 0; i < 4; i++) begin
      @(negedge clk); ren <= 1'b1; raddr <= i[3:0];
      #1;
      if (rdata !== exp[i]) begin
        errors++; $display("ERROR: Avalon-ST mem[%0d] got=%h exp=%h", i, rdata, exp[i]);
      end
      @(negedge clk); ren <= 1'b0;
    end

    if (errors == 0) $display("TEST PASSED: Avalon-ST");
    else             $display("TEST FAILED: %0d errors", errors);
    $finish;
  end

  initial begin
    #500_000; $display("TIMEOUT"); $finish;
  end
endmodule
