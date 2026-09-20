// SPDX-License-Identifier: Apache-2.0
// Self-checking testbench: TB acts as SPMI master -- SystemVerilog
`timescale 1ns/1ps
module SPMI_tb;
  logic clk = 0, rst_n = 0;
  tri1  sdata;
  logic sclk = 0;
  logic m_low = 0;
  logic [7:0] rx_byte, rx_addr;
  logic rx_valid, busy;
  logic rx_seen = 0;
  int errors = 0;

  SPMI_top #(.SPMI_ADDR(4'h5)) dut (
    .clk(clk), .rst_n(rst_n), .sdata(sdata), .sclk(sclk),
    .rx_byte(rx_byte), .rx_addr(rx_addr), .rx_valid(rx_valid),
    .tx_byte(8'hC3), .busy(busy), .irq());

  always #5 clk = ~clk;
  assign sdata = m_low ? 1'b0 : 1'bz;
  always @(posedge clk) if (rx_valid) rx_seen <= 1'b1;

  task automatic ssc;
    begin m_low = 0; sclk = 1; #300;       // SCLK high first
          m_low = 1; #300;                 // SDATA falls while SCLK high
          sclk = 0; #300;
          m_low = 0; #300; end
  endtask
  task automatic sbit(input logic b);
    begin m_low = ~b; #300; sclk = 1; #600; sclk = 0; #300; end
  endtask
  task automatic srelease(output logic b);
    begin m_low = 0; #300; sclk = 1; #300; b = sdata; #300; sclk = 0; #300; end
  endtask

  task automatic spmi_write(input logic [3:0] sa, input logic [7:0] ad,
                            input logic [7:0] data);
    begin
      ssc;
      for (int i = 3; i >= 0; i--) sbit(sa[i]);
      sbit(0); sbit(0); sbit(0); sbit(0);      // CMD = write
      for (int i = 7; i >= 0; i--) sbit(ad[i]);
      for (int i = 7; i >= 0; i--) sbit(data[i]);
      srelease_bit_ack();
      #600;
    end
  endtask

  task automatic spmi_read(input logic [3:0] sa, input logic [7:0] ad,
                           output logic [7:0] data);
    logic b;
    begin
      ssc;
      for (int i = 3; i >= 0; i--) sbit(sa[i]);
      sbit(0); sbit(0); sbit(0); sbit(1);      // CMD = read
      for (int i = 7; i >= 0; i--) sbit(ad[i]);
      for (int i = 7; i >= 0; i--) begin        // slave drives data immediately
        srelease(b);
        data[i] = b;
      end
      #600;
    end
  endtask

  task automatic srelease_bit_ack;
    logic b;
    begin srelease(b); end
  endtask

  logic [7:0] rb;
  initial begin
    rst_n = 0; repeat(10) @(posedge clk);
    rst_n = 1; repeat(10) @(posedge clk);

    spmi_write(4'h5, 8'h03, 8'h5A);
    repeat(5) @(posedge clk);
    if (!rx_seen) begin errors++; $display("ERROR: SPMI rx_valid never pulsed"); end
    if (rx_byte !== 8'h5A) begin errors++; $display("ERROR: SPMI rx=%h exp=5A", rx_byte); end
    if (rx_addr !== 8'h03) begin errors++; $display("ERROR: SPMI rx_addr=%h exp=03", rx_addr); end

    spmi_read (4'h5, 8'h03, rb);
    if (rb !== 8'hC3) begin errors++; $display("ERROR: SPMI read got=%h exp=C3", rb); end

    if (errors == 0) $display("TEST PASSED: SPMI");
    else             $display("TEST FAILED: %0d errors", errors);
    $finish;
  end

  initial begin
    #3_000_000; $display("TIMEOUT"); $finish;
  end
endmodule
