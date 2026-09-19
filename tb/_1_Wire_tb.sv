// SPDX-License-Identifier: Apache-2.0
// Self-checking testbench: TB acts as 1-Wire master -- SystemVerilog
`timescale 1ns/1ps
module _1_Wire_tb;
  localparam int US = 10;             // 100ns per unit
  logic clk = 0, rst_n = 0;
  tri1  dq;
  logic m_low = 0;
  logic [7:0] tx_byte, rx_byte;
  logic rx_valid, busy;
  logic rx_seen = 0;
  int errors = 0;

  _1_Wire_top #(.US(US)) dut (
    .clk(clk), .rst_n(rst_n), .dq(dq),
    .tx_byte(tx_byte), .rx_byte(rx_byte), .rx_valid(rx_valid),
    .busy(busy), .irq());

  always #5 clk = ~clk;
  assign dq = m_low ? 1'b0 : 1'bz;
  always @(posedge clk) if (rx_valid) rx_seen <= 1'b1;

  task automatic ow_reset(output logic presence);
    begin
      m_low = 1; #(600*US*10);         // reset pulse >= 480us
      m_low = 0;
      #(30*US*10);                     // presence window
      presence = (dq === 1'b0);
      #(400*US*10);
    end
  endtask

  task automatic ow_write_bit(input logic b);
    begin
      m_low = 1; #(2*US*10);
      if (!b) #(60*US*10);             // hold for 0
      m_low = 0;
      #((80-2)*US*10);                 // slot end
    end
  endtask

  task automatic ow_read_bit(output logic b);
    begin
      m_low = 1; #(2*US*10);
      m_low = 0;
      #(13*US*10);
      b = dq;
      #((80-15)*US*10);
    end
  endtask

  logic presence, b;
  logic [7:0] rb;
  initial begin
    tx_byte = 8'h5A;
    rst_n = 0; repeat(10) @(posedge clk);
    rst_n = 1; repeat(10) @(posedge clk);

    ow_reset(presence);
    if (!presence) begin errors++; $display("ERROR: 1-Wire no presence pulse"); end

    // send command 0xCC (Skip ROM), LSB first
    begin : send_cmd
      logic [7:0] cmd;
      cmd = 8'hCC;
      for (int i = 0; i < 8; i++) ow_write_bit(cmd[i]);
    end
    repeat(5) @(posedge clk);
    if (!rx_seen)  begin errors++; $display("ERROR: 1-Wire rx_valid never pulsed"); end
    if (rx_byte !== 8'hCC) begin errors++; $display("ERROR: 1-Wire rx=%h exp=CC", rx_byte); end

    // read a byte from slave (expect tx_byte=5A), LSB first
    for (int i = 0; i < 8; i++) begin
      ow_read_bit(b);
      rb[i] = b;
    end
    if (rb !== 8'h5A) begin errors++; $display("ERROR: 1-Wire read got=%h exp=5A", rb); end

    if (errors == 0) $display("TEST PASSED: 1-Wire");
    else             $display("TEST FAILED: %0d errors", errors);
    $finish;
  end

  initial begin
    #5_000_000; $display("TIMEOUT"); $finish;
  end
endmodule
