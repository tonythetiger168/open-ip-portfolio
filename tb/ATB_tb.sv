// SPDX-License-Identifier: Apache-2.0
// Self-checking testbench for ATB_top -- SystemVerilog
`timescale 1ns/1ps
module ATB_tb;
  logic clk = 0, rst_n = 0;
  logic atvalid = 0, atready;
  logic [31:0] atdata = 0;
  logic [6:0] atid = 0;
  logic atlast = 0;
  logic afvalid = 0, afready;
  logic ren = 0;
  logic [3:0] raddr = 0;
  logic [31:0] rdata;
  logic [4:0] count;
  logic [6:0] last_id;
  logic irq;
  logic irq_seen = 0;
  int errors = 0;

  ATB_top dut (
    .clk(clk), .rst_n(rst_n), .atvalid(atvalid), .atready(atready),
    .atdata(atdata), .atid(atid), .atlast(atlast),
    .afvalid(afvalid), .afready(afready),
    .ren(ren), .raddr(raddr), .rdata(rdata), .count(count),
    .last_id(last_id), .irq(irq));

  always #5 clk = ~clk;
  always @(posedge clk) if (irq) irq_seen <= 1'b1;

  task automatic send(input logic [31:0] d, input logic [6:0] id, input logic last);
    begin
      wait (atready === 1'b1);
      @(negedge clk);
      atdata <= d; atid <= id; atlast <= last; atvalid <= 1'b1;
      @(posedge clk); #1;
      @(negedge clk);
      atvalid <= 1'b0; atlast <= 1'b0;
    end
  endtask

  logic [31:0] exp [0:3];
  initial begin
    exp[0] = 32'hDEAD_BEEF; exp[1] = 32'h1234_5678;
    exp[2] = 32'hCAFE_F00D; exp[3] = 32'h0BAD_C0DE;
    rst_n = 0; repeat(5) @(posedge clk);
    rst_n = 1; repeat(5) @(posedge clk);

    // first trace burst, id=0x12
    for (int i = 0; i < 4; i++) send(exp[i], 7'h12, i == 3);
    repeat(2) @(posedge clk);
    if (count !== 5'd4) begin errors++; $display("ERROR: ATB count=%0d exp=4", count); end
    if (!irq_seen) begin errors++; $display("ERROR: ATB irq never fired"); end
    if (last_id !== 7'h12) begin errors++; $display("ERROR: ATB last_id=%h", last_id); end
    for (int i = 0; i < 4; i++) begin
      @(negedge clk); ren <= 1'b1; raddr <= i[3:0];
      #1;
      if (rdata !== exp[i]) begin errors++; $display("ERROR: ATB mem[%0d] got=%h exp=%h", i, rdata, exp[i]); end
      @(negedge clk); ren <= 1'b0;
    end

    // flush with new id -> FIFO empties
    @(negedge clk); afvalid <= 1'b1; atid <= 7'h34;
    @(posedge clk); #1;
    @(negedge clk); afvalid <= 1'b0;
    repeat(2) @(posedge clk);
    if (count !== 5'd0) begin errors++; $display("ERROR: ATB flush count=%0d exp=0", count); end

    if (errors == 0) $display("TEST PASSED: ATB");
    else             $display("TEST FAILED: %0d errors", errors);
    $finish;
  end

  initial begin
    #500_000; $display("TIMEOUT"); $finish;
  end
endmodule
