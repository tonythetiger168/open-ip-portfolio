// SPDX-License-Identifier: Apache-2.0
// Self-checking testbench: TB acts as RFFE master -- SystemVerilog
`timescale 1ns/1ps
module MIPI_SLIMbus_tb;
  logic clk = 0, rst_n = 0;
  tri1  sdata;
  logic sclk = 0;
  logic m_oe = 0, m_val = 1;
  logic [7:0] rx_byte, rx_addr;
  logic rx_valid, busy;
  logic rx_seen = 0;
  int errors = 0;

  MIPI_SLIMbus_top #(.RFFE_ADDR(2'b01)) dut (
    .clk(clk), .rst_n(rst_n), .sdata(sdata), .sclk(sclk),
    .rx_byte(rx_byte), .rx_addr(rx_addr), .rx_valid(rx_valid),
    .tx_byte(8'hC3), .busy(busy), .irq());

  always #5 clk = ~clk;
  assign sdata = m_oe ? m_val : 1'bz;
  always @(posedge clk) if (rx_valid) rx_seen <= 1'b1;

  task automatic rbit(input logic b);
    begin m_oe = 1; m_val = b; #300; sclk = 1; #600; sclk = 0; #300; end
  endtask
  task automatic rrelease_bit(output logic b);
    begin m_oe = 0; #300; sclk = 1; #300; b = sdata; #300; sclk = 0; #300; end
  endtask
  task automatic rssc;
    begin m_oe = 0; m_val = 1; sclk = 1; #300;   // SCLK high first
          m_oe = 1; m_val = 0; #300;             // SDATA falls while SCLK high
          sclk = 0; #300;
          m_oe = 0; #300; end
  endtask

  task automatic rffe_write(input logic [1:0] sa, input logic [4:0] ad,
                            input logic [7:0] data);
    begin
      rssc;
      rbit(sa[1]); rbit(sa[0]); rbit(1'b0);       // PC=0 write
      for (int i = 4; i >= 0; i--) rbit(ad[i]);
      for (int i = 7; i >= 0; i--) rbit(data[i]);
      rbit(1'b1);                                  // bus park
      m_oe = 0; #600;
    end
  endtask

  task automatic rffe_read(input logic [1:0] sa, input logic [4:0] ad,
                           output logic [7:0] data);
    logic b;
    begin
      rssc;
      rbit(sa[1]); rbit(sa[0]); rbit(1'b1);       // PC=1 read
      for (int i = 4; i >= 0; i--) rbit(ad[i]);
      for (int i = 7; i >= 0; i--) begin
        rrelease_bit(b);
        data[i] = b;
      end
      rbit(1'b1);
      m_oe = 0; #600;
    end
  endtask

  logic [7:0] rb;
  initial begin
    rst_n = 0; repeat(10) @(posedge clk);
    rst_n = 1; repeat(10) @(posedge clk);

    rffe_write(2'b01, 5'h03, 8'h5A);
    repeat(5) @(posedge clk);
    if (!rx_seen) begin errors++; $display("ERROR: MIPI SLIMbus rx_valid never pulsed"); end
    if (rx_byte !== 8'h5A) begin errors++; $display("ERROR: MIPI SLIMbus rx=%h exp=5A", rx_byte); end
    if (rx_addr !== 5'h03) begin errors++; $display("ERROR: MIPI SLIMbus rx_addr=%h exp=03", rx_addr); end

    rffe_read (2'b01, 5'h03, rb);
    if (rb !== 8'hC3) begin errors++; $display("ERROR: MIPI SLIMbus read got=%h exp=C3", rb); end

    if (errors == 0) $display("TEST PASSED: MIPI SLIMbus");
    else             $display("TEST FAILED: %0d errors", errors);
    $finish;
  end

  initial begin
    #3_000_000; $display("TIMEOUT"); $finish;
  end
endmodule
