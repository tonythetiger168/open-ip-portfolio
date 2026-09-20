// SPDX-License-Identifier: Apache-2.0
// Self-checking testbench for GPIO_top -- SystemVerilog
`timescale 1ns/1ps
module GPIO_tb;
  logic clk = 0, rst_n = 0;
  logic wen = 0, ren = 0;
  logic [3:0] waddr = 0, raddr = 0;
  logic [7:0] wdata = 0, rdata;
  logic [7:0] gpio_oe = 0;
  logic [7:0] drive_val = 0;
  logic       drive_en = 0;
  tri  [7:0]  gpio;
  int errors = 0;

  GPIO_top dut (
    .clk(clk), .rst_n(rst_n), .wen(wen), .waddr(waddr), .wdata(wdata),
    .ren(ren), .raddr(raddr), .rdata(rdata),
    .gpio(gpio), .gpio_oe(gpio_oe), .irq());

  always #5 clk = ~clk;
  assign gpio = drive_en ? drive_val : 8'hzz;

  task automatic wr(input logic [3:0] a, input logic [7:0] d);
    begin
      @(negedge clk); wen <= 1'b1; waddr <= a; wdata <= d;
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
  initial begin
    rst_n = 0; repeat(5) @(posedge clk);
    rst_n = 1; repeat(5) @(posedge clk);

    gpio_oe = 8'hFF;
    wr(4'd0, 8'hA5);
    repeat(2) @(posedge clk); #1;
    if (gpio !== 8'hA5) begin
      errors++; $display("ERROR: GPIO output got=%h exp=A5", gpio);
    end

    rd(4'd0, got);
    if (got !== 8'hA5) begin
      errors++; $display("ERROR: GPIO loopback got=%h exp=A5", got);
    end

    gpio_oe = 8'h00;
    drive_en = 1'b1; drive_val = 8'h3C;
    repeat(2) @(posedge clk);
    rd(4'd0, got);
    if (got !== 8'h3C) begin
      errors++; $display("ERROR: GPIO input got=%h exp=3C", got);
    end

    rd(4'd1, got);
    if (got !== 8'hA5) begin
      errors++; $display("ERROR: GPIO out_reg got=%h exp=A5", got);
    end

    if (errors == 0) $display("TEST PASSED: GPIO");
    else             $display("TEST FAILED: %0d errors", errors);
    $finish;
  end

  initial begin
    #100_000; $display("TIMEOUT"); $finish;
  end
endmodule
