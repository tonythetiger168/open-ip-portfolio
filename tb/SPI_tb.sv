// SPDX-License-Identifier: Apache-2.0
// Self-checking testbench: TB acts as SPI master (mode 0) -- SystemVerilog
`timescale 1ns/1ps
module SPI_tb;
  logic clk = 0, rst_n = 0;
  logic sclk = 0, mosi = 0, csn = 1;
  logic miso;
  logic wen = 0, ren = 0;
  logic [3:0] waddr = 0, raddr = 0;
  logic [7:0] wdata = 0, rdata;
  int errors = 0;

  SPI_top dut (
    .clk(clk), .rst_n(rst_n), .sclk(sclk), .mosi(mosi), .miso(miso),
    .csn(csn), .wen(wen), .waddr(waddr), .wdata(wdata),
    .ren(ren), .raddr(raddr), .rdata(rdata), .irq());

  always #5 clk = ~clk;

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

  task automatic spi_xfer(input logic [7:0] din, output logic [7:0] dout);
    begin
      csn = 1'b0;
      for (int i = 0; i < 8; i++) begin
        mosi = din[7-i];
        #40 sclk = 1'b1;
        #1 dout[7-i] = miso;
        #39 sclk = 1'b0;
      end
      csn = 1'b1;
      #80;
    end
  endtask

  logic [7:0] d1, d2, got;
  initial begin
    rst_n = 0; repeat(5) @(posedge clk);
    rst_n = 1; repeat(5) @(posedge clk);

    wr(4'd0, 8'h3C);
    spi_xfer(8'h00, d1);
    spi_xfer(8'hA7, d2);
    rd(4'd0, got);

    if (d1 !== 8'h3C) begin errors++; $display("ERROR: SPI MISO xfer1 got=%h exp=3C", d1); end
    if (d2 !== 8'h3C) begin errors++; $display("ERROR: SPI MISO xfer2 got=%h exp=3C", d2); end
    if (got !== 8'hA7) begin errors++; $display("ERROR: SPI MOSI got=%h exp=A7", got); end

    if (errors == 0) $display("TEST PASSED: SPI");
    else             $display("TEST FAILED: %0d errors", errors);
    $finish;
  end

  initial begin
    #500_000; $display("TIMEOUT"); $finish;
  end
endmodule
