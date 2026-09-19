// SPDX-License-Identifier: Apache-2.0
// DDR6 TB: ch0 read/write + ch1 isolation + channel isolation.
`timescale 1ns/1ps
module DDR6_tb;
  logic clk = 0, rst_n = 0;
  logic hvalid = 0, hready;
  logic [2:0] hcmd = 0;
  logic [31:0] haddr = 0;
  logic [15:0] hwdata = 0, hrdata;
  logic hdone;
  logic ck_t, ck_c;
  logic [16:0] addr; logic ras_n, cas_n, we_n;
  tri [31:0] dq; tri [1:0] dqs; logic cke;
  logic trace_valid; logic [2:0] trace_cmd; logic [31:0] trace_addr;
  int errors = 0;

  DDR6_top dut (.*);
  always #5 clk = ~clk;

  task automatic cmd(input logic [2:0] c, input logic [31:0] a, input logic [15:0] d);
    begin
      wait (hready === 1'b1);
      @(negedge clk);
      hcmd <= c; haddr <= a; hwdata <= d; hvalid <= 1'b1;
      @(negedge clk);
      hvalid <= 1'b0;
    end
  endtask

  logic [15:0] got;
  initial begin
    rst_n = 0; repeat(5) @(posedge clk);
    rst_n = 1; repeat(5) @(posedge clk);
    cmd(3'd1, 32'h000, 16'h0);
    repeat(3) @(posedge clk);
    for (int i = 0; i < 4; i++) cmd(3'd3, i, 16'h1444 + i * 8'h11);
    for (int i = 0; i < 4; i++) begin
      cmd(3'd2, i, 16'h0);
      wait (hdone === 1'b1); @(posedge clk); #1;
      got = hrdata;
      if (got !== 16'h1444 + i * 8'h11) begin
        errors++; $display("ERROR: DDR6 ch0[%0d] got=%h", i, got);
      end
    end
    // channel 1 (haddr[8]=1): distinct data, same column -> isolation check
    cmd(3'd1, 32'h100, 16'h0);
    repeat(3) @(posedge clk);
    cmd(3'd3, 32'h100, 16'h154501);
    cmd(3'd1, 32'h100, 16'h0);
    repeat(3) @(posedge clk);
    cmd(3'd2, 32'h100, 16'h0);
    wait (hdone === 1'b1); @(posedge clk); #1;
    got = hrdata;
    if (got !== 16'h154501) begin
      errors++; $display("ERROR: DDR6 ch1[0] got=%h exp=154501", got);
    end
    // channel 0 data must be untouched
    cmd(3'd1, 32'h000, 16'h0);
    repeat(3) @(posedge clk);
    cmd(3'd2, 32'h000, 16'h0);
    wait (hdone === 1'b1); @(posedge clk); #1;
    got = hrdata;
    if (got !== 16'h1444) begin
      errors++; $display("ERROR: DDR6 ch0[0] after ch1 traffic got=%h exp=1444", got);
    end
    if (errors == 0) $display("TEST PASSED: DDR6");
    else             $display("TEST FAILED: %0d errors", errors);
    $finish;
  end

  initial begin
    #500_000; $display("TIMEOUT"); $finish;
  end
endmodule
