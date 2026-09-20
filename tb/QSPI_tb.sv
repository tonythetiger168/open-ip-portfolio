// SPDX-License-Identifier: Apache-2.0
// Self-checking testbench: TB acts as QSPI master -- SystemVerilog
`timescale 1ns/1ps
module QSPI_tb;
  logic clk = 0, rst_n = 0;
  logic sclk = 0, csn = 1;
  tri  [3:0] io;
  logic [3:0] drv_val = 0;
  logic       drv_en  = 0;
  logic wen = 0, ren = 0;
  logic [3:0] waddr = 0, raddr = 0;
  logic [7:0] wdata = 0, rdata;
  int errors = 0;

  QSPI_top dut (
    .clk(clk), .rst_n(rst_n), .sclk(sclk), .csn(csn), .io(io),
    .wen(wen), .waddr(waddr), .wdata(wdata),
    .ren(ren), .raddr(raddr), .rdata(rdata), .irq());

  always #5 clk = ~clk;
  assign io = drv_en ? drv_val : 4'bzzzz;

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

  task automatic std_xfer(input logic [7:0] din, output logic [7:0] dout);
    begin
      csn = 1'b0; drv_en = 1'b1;
      for (int i = 0; i < 8; i++) begin
        drv_val = {3'bzzz, din[7-i]};
        #40 sclk = 1'b1;
        #1 dout[7-i] = io[1];
        #39 sclk = 1'b0;
      end
      drv_en = 1'b0; csn = 1'b1; #100;
    end
  endtask

  task automatic quad_read(output logic [7:0] dout);
    begin
      csn = 1'b0; drv_en = 1'b0;          // release: slave drives io
      for (int i = 0; i < 2; i++) begin
        #40 sclk = 1'b1;
        #1 dout[7-4*i -: 4] = io[3:0];
        #39 sclk = 1'b0;
      end
      csn = 1'b1; #100;
    end
  endtask

  task automatic quad_write(input logic [7:0] din);
    begin
      csn = 1'b0; drv_en = 1'b1;
      for (int i = 0; i < 2; i++) begin
        drv_val = din[7-4*i -: 4];
        #40 sclk = 1'b1; #1; #39 sclk = 1'b0;
      end
      drv_en = 1'b0; csn = 1'b1; #100;
    end
  endtask

  logic [7:0] d1, q1, q2, got;
  initial begin
    rst_n = 0; repeat(5) @(posedge clk);
    rst_n = 1; repeat(5) @(posedge clk);

    // standard mode
    wr(4'd0, 8'h3C);
    std_xfer(8'h00, d1);
    rd(4'd0, got);
    if (d1 !== 8'h3C) begin errors++; $display("ERROR: QSPI std MISO got=%h exp=3C", d1); end

    // quad mode: read slave tx, then write
    wr(4'd2, 8'h01);
    wr(4'd0, 8'hA7);
    wr(4'd3, 8'h00);          // dir = slave drives (read)
    quad_read(q1);
    wr(4'd3, 8'h01);          // dir = release (write)
    quad_write(8'h5A);
    rd(4'd0, got);
    if (q1 !== 8'hA7) begin errors++; $display("ERROR: QSPI quad read got=%h exp=A7", q1); end
    if (got !== 8'h5A) begin errors++; $display("ERROR: QSPI quad write got=%h exp=5A", got); end

    if (errors == 0) $display("TEST PASSED: QSPI");
    else             $display("TEST FAILED: %0d errors", errors);
    $finish;
  end

  initial begin
    #1_000_000; $display("TIMEOUT"); $finish;
  end
endmodule
