// SPDX-License-Identifier: Apache-2.0
// Self-checking testbench for PWM_top -- SystemVerilog
`timescale 1ns/1ps
module PWM_tb;
  logic clk = 0, rst_n = 0;
  logic wen = 0;
  logic [3:0] waddr = 0;
  logic [31:0] wdata = 0;
  int errors = 0;

  PWM_top dut (
    .clk(clk), .rst_n(rst_n), .wen(wen), .waddr(waddr), .wdata(wdata),
    .pwm_out(), .pwm_n_out(), .irq());

  always #5 clk = ~clk;

  task automatic wr(input logic [3:0] a, input logic [31:0] d);
    begin
      @(negedge clk); wen <= 1'b1; waddr <= a; wdata <= d;
      @(negedge clk); wen <= 1'b0;
    end
  endtask

  task automatic check_duty(input int period, input int duty);
    int high = 0;
    begin
      wr(4'd0, period);
      wr(4'd1, duty);
      wait (dut.counter == 0);
      repeat (period) begin
        @(posedge clk); #1;
        if (dut.pwm_out) high++;
      end
      if (high != duty) begin
        errors++;
        $display("ERROR: PWM period=%0d duty=%0d high_count=%0d", period, duty, high);
      end
    end
  endtask

  initial begin
    rst_n = 0; repeat(5) @(posedge clk);
    rst_n = 1; repeat(5) @(posedge clk);
    check_duty(10, 3);
    check_duty(10, 7);
    check_duty(16, 1);
    check_duty(16, 15);
    if (errors == 0) $display("TEST PASSED: PWM");
    else             $display("TEST FAILED: %0d errors", errors);
    $finish;
  end

  initial begin
    #100_000; $display("TIMEOUT"); $finish;
  end
endmodule
