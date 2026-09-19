// SPDX-License-Identifier: Apache-2.0
// Self-checking testbench for AXI_Stream_top -- SystemVerilog
`timescale 1ns/1ps
module AXI_Stream_tb;
  logic clk = 0, rst_n = 0;
  logic tvalid = 0, tready;
  logic [31:0] tdata = 0;
  logic tlast = 0;
  logic ren = 0;
  logic [3:0] raddr = 0;
  logic [31:0] rdata;
  logic [4:0] count;
  logic irq;
  logic irq_seen = 0;
  int errors = 0;

  AXI_Stream_top dut (
    .clk(clk), .rst_n(rst_n), .tvalid(tvalid), .tready(tready),
    .tdata(tdata), .tlast(tlast), .ren(ren), .raddr(raddr),
    .rdata(rdata), .count(count), .irq(irq));

  always #5 clk = ~clk;
  always @(posedge clk) if (irq) irq_seen <= 1'b1;

  task automatic send(input logic [31:0] d, input logic last);
    begin
      wait (tready === 1'b1);
      @(negedge clk);
      tdata <= d; tlast <= last; tvalid <= 1'b1;
      @(posedge clk); #1;
      if (tready !== 1'b1) begin
        errors++; $display("ERROR: AXIS tready dropped mid-beat");
      end
      @(negedge clk);
      tvalid <= 1'b0; tlast <= 1'b0;
    end
  endtask

  logic [31:0] exp [0:4];
  initial begin
    exp[0] = 32'hDEAD_BEEF; exp[1] = 32'h1234_5678;
    exp[2] = 32'hA5A5_5A5A; exp[3] = 32'h0BAD_F00D;
    exp[4] = 32'hC001_D00D;
  end
  initial begin
    rst_n = 0; repeat(5) @(posedge clk);
    rst_n = 1; repeat(5) @(posedge clk);

    for (int i = 0; i < 5; i++) send(exp[i], i == 4);

    repeat(2) @(posedge clk);
    if (count !== 5'd5) begin
      errors++; $display("ERROR: AXIS count got=%0d exp=5", count);
    end
    if (!irq_seen) begin
      errors++; $display("ERROR: AXIS irq never fired");
    end
    for (int i = 0; i < 5; i++) begin
      @(negedge clk); ren <= 1'b1; raddr <= i[3:0];
      #1;
      if (rdata !== exp[i]) begin
        errors++; $display("ERROR: AXIS mem[%0d] got=%h exp=%h", i, rdata, exp[i]);
      end
      @(negedge clk); ren <= 1'b0;
    end

    if (errors == 0) $display("TEST PASSED: AXI-Stream");
    else             $display("TEST FAILED: %0d errors", errors);
    $finish;
  end

  initial begin
    #500_000; $display("TIMEOUT"); $finish;
  end
endmodule
