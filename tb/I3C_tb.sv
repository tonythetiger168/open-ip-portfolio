// SPDX-License-Identifier: Apache-2.0
// Self-checking testbench: TB acts as I3C master; checks IBI (int_n)
// Reuses the I2C bit-bang master pattern -- SystemVerilog
`timescale 1ns/1ps
module I3C_tb;
  logic clk = 0, rst_n = 0;
  tri1 sda;
  logic scl = 1;
  logic master_low = 0;
  logic [7:0] tx_byte, rx_byte;
  logic rx_valid, int_n, busy;
  int errors = 0;

  I3C_top #(.I3C_ADDR(7'h2A)) dut (
    .clk(clk), .rst_n(rst_n), .sda(sda), .scl(scl),
    .tx_byte(tx_byte), .rx_byte(rx_byte), .rx_valid(rx_valid),
    .int_n(int_n), .busy(busy), .irq());

  always #5 clk = ~clk;
  assign sda = master_low ? 1'b0 : 1'bz;

  task automatic i3c_start;
    begin master_low = 0; scl = 1; #300; master_low = 1; #300; scl = 0; #300; end
  endtask
  task automatic i3c_stop;
    begin master_low = 1; #300; scl = 1; #300; master_low = 0; #600; end
  endtask
  task automatic i3c_wbyte(input logic [7:0] d, output logic ack);
    begin
      for (int i = 0; i < 8; i++) begin
        master_low = ~d[7-i]; #300; scl = 1; #600; scl = 0; #300;
      end
      master_low = 0; #300; scl = 1; #300;
      ack = (sda === 1'b0);
      #300; scl = 0; #600;
    end
  endtask
  task automatic i3c_rbyte(input logic send_ack, output logic [7:0] d);
    begin
      master_low = 0;
      for (int i = 0; i < 8; i++) begin
        #300; scl = 1; #300; d[7-i] = sda; #300; scl = 0; #300;
      end
      master_low = send_ack; #300; scl = 1; #600; scl = 0; #300; master_low = 0; #300;
    end
  endtask

  logic ack;
  logic [7:0] rb;
  initial begin
    tx_byte = 8'hC3;
    rst_n = 0; repeat(10) @(posedge clk);
    rst_n = 1; repeat(10) @(posedge clk);
    if (int_n !== 1'b1) begin errors++; $display("ERROR: I3C int_n not idle-high"); end

    // write 0x5A -> IBI should assert after STOP
    i3c_start;
    i3c_wbyte(8'h54, ack);                  // addr 0x2A + W
    if (!ack) begin errors++; $display("ERROR: I3C no ACK addr W"); end
    i3c_wbyte(8'h5A, ack);
    if (!ack) begin errors++; $display("ERROR: I3C no ACK data"); end
    i3c_stop;
    repeat(5) @(posedge clk);
    if (rx_byte !== 8'h5A) begin errors++; $display("ERROR: I3C rx=%h exp=5A", rx_byte); end
    if (int_n !== 1'b0) begin errors++; $display("ERROR: I3C IBI (int_n) not asserted after write"); end

    // read clears IBI via START
    i3c_start;
    if (int_n !== 1'b1) begin errors++; $display("ERROR: I3C IBI not cleared by START"); end
    i3c_wbyte(8'h55, ack);                  // addr 0x2A + R
    if (!ack) begin errors++; $display("ERROR: I3C no ACK addr R"); end
    i3c_rbyte(1'b0, rb);
    if (rb !== 8'hC3) begin errors++; $display("ERROR: I3C read got=%h exp=C3", rb); end
    i3c_stop;

    if (errors == 0) $display("TEST PASSED: I3C");
    else             $display("TEST FAILED: %0d errors", errors);
    $finish;
  end

  initial begin
    #3_000_000; $display("TIMEOUT"); $finish;
  end
endmodule
