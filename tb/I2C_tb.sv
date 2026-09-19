// SPDX-License-Identifier: Apache-2.0
// Self-checking testbench: TB acts as I2C master (bit-bang) -- SystemVerilog
`timescale 1ns/1ps
module I2C_tb;
  logic clk = 0, rst_n = 0;
  tri1 sda;                      // open-drain bus with pullup
  logic scl = 1;
  logic master_low = 0;          // open-drain: TB pulls low or releases
  logic [7:0] tx_byte, rx_byte;
  logic rx_valid, busy;
  logic rx_seen = 0;
  int errors = 0;

  I2C_top #(.I2C_ADDR(7'h50)) dut (
    .clk(clk), .rst_n(rst_n), .sda(sda), .scl(scl),
    .tx_byte(tx_byte), .rx_byte(rx_byte), .rx_valid(rx_valid),
    .busy(busy), .irq());

  always #5 clk = ~clk;
  assign sda = master_low ? 1'b0 : 1'bz;
  always @(posedge clk) if (rx_valid) rx_seen <= 1'b1;

  task automatic i2c_start;
    begin
      master_low = 0; scl = 1; #300;
      master_low = 1;        #300;   // SDA falls while SCL high
      scl = 0;               #300;
    end
  endtask

  task automatic i2c_stop;
    begin
      master_low = 1;        #300;
      scl = 1;               #300;
      master_low = 0;        #300;   // SDA rises while SCL high
      #300;
    end
  endtask

  task automatic i2c_wbyte(input logic [7:0] d, output logic ack);
    begin
      for (int i = 0; i < 8; i++) begin
        master_low = ~d[7-i];  #300;
        scl = 1;               #600;
        scl = 0;               #300;
      end
      master_low = 0;          #300;   // release for ACK
      scl = 1;                 #300;
      ack = (sda === 1'b0);
      #300; scl = 0;           #600;
    end
  endtask

  task automatic i2c_rbyte(input logic send_ack, output logic [7:0] d);
    begin
      master_low = 0;
      for (int i = 0; i < 8; i++) begin
        #300; scl = 1; #300;
        d[7-i] = sda;
        #300; scl = 0; #300;
      end
      master_low = send_ack;   #300;   // ACK = pull low
      scl = 1;                 #600;
      scl = 0;                 #300;
      master_low = 0;          #300;
    end
  endtask

  // ---- full read transaction with data check (MSB=0 vectors catch
  //      first-byte MSB loss at the ST_ACK->ST_TX transition) ----
  task automatic i2c_read_check(input logic [7:0] v);
    logic ack_t;
    logic [7:0] rd;
    begin
      tx_byte = v;
      i2c_start;
      i2c_wbyte(8'hA1, ack_t);               // addr 0x50 + R
      if (!ack_t) begin errors++; $display("ERROR: I2C no ACK on addr R (v=%h)", v); end
      i2c_rbyte(1'b0, rd);                   // NACK after byte
      if (rd !== v) begin errors++; $display("ERROR: I2C read got=%h exp=%h", rd, v); end
      i2c_stop;
      #300;
    end
  endtask

  // ---- multi-byte read coverage: exercises the ST_TXACK->ST_TX re-entry
  //      path (DUT resends tx_byte after a master ACK) ----
  // txn1: classic single-byte read terminated by a master NACK
  // txn2: master ACKs byte1, DUT walks ST_TXACK->ST_TX and resends tx_byte;
  //       byte2 must equal byte1 (tx_byte is fixed), then master NACKs
  task automatic i2c_read2_check(input logic [7:0] v1, input logic [7:0] v2);
    logic ack_t;
    logic [7:0] rd1, rd2;
    begin
      // txn1: single byte read terminated by master NACK
      tx_byte = v1;
      i2c_start;
      i2c_wbyte(8'hA1, ack_t);               // addr 0x50 + R
      if (!ack_t) begin errors++; $display("ERROR: I2C read2 no ACK on addr R (v=%h)", v1); end
      i2c_rbyte(1'b0, rd1);                  // NACK after byte
      if (rd1 !== v1) begin errors++; $display("ERROR: I2C read2 byte1 got=%h exp=%h", rd1, v1); end
      i2c_stop;
      #300;

      // txn2: master ACKs byte1 -> DUT re-enters ST_TX and resends tx_byte
      tx_byte = v2;
      i2c_start;
      i2c_wbyte(8'hA1, ack_t);               // addr 0x50 + R
      if (!ack_t) begin errors++; $display("ERROR: I2C read2 no ACK on addr R (v=%h)", v2); end
      i2c_rbyte(1'b1, rd1);                  // ACK byte1: request another byte
      if (rd1 !== v2) begin errors++; $display("ERROR: I2C read2 byte1 got=%h exp=%h", rd1, v2); end
      i2c_rbyte(1'b0, rd2);                  // NACK after byte2
      if (rd2 !== v2) begin errors++; $display("ERROR: I2C read2 byte2 got=%h exp=%h", rd2, v2); end
      i2c_stop;
      #300;
    end
  endtask

  // ---- 3-byte read in a single transaction (ACK, ACK, NACK) ----
  //      byte2/byte3 must match byte1: tx_byte is fixed and resent each time
  task automatic i2c_read3_check(input logic [7:0] v);
    logic ack_t;
    logic [7:0] rd1, rd2, rd3;
    begin
      tx_byte = v;
      i2c_start;
      i2c_wbyte(8'hA1, ack_t);               // addr 0x50 + R
      if (!ack_t) begin errors++; $display("ERROR: I2C read3 no ACK on addr R (v=%h)", v); end
      i2c_rbyte(1'b1, rd1);                  // ACK byte1
      if (rd1 !== v) begin errors++; $display("ERROR: I2C read3 byte1 got=%h exp=%h", rd1, v); end
      i2c_rbyte(1'b1, rd2);                  // ACK byte2
      if (rd2 !== v) begin errors++; $display("ERROR: I2C read3 byte2 got=%h exp=%h", rd2, v); end
      i2c_rbyte(1'b0, rd3);                  // NACK byte3: end of transaction
      if (rd3 !== v) begin errors++; $display("ERROR: I2C read3 byte3 got=%h exp=%h", rd3, v); end
      i2c_stop;
      #300;
    end
  endtask

  logic ack, rdata;
  logic [7:0] rb;
  initial begin
    tx_byte = 8'hC3;
    rst_n = 0; repeat(10) @(posedge clk);
    rst_n = 1; repeat(10) @(posedge clk);

    // ---- write 0x5A to slave ----
    i2c_start;
    i2c_wbyte(8'hA0, ack);                 // addr 0x50 + W
    if (!ack) begin errors++; $display("ERROR: I2C no ACK on addr W"); end
    i2c_wbyte(8'h5A, ack);
    if (!ack) begin errors++; $display("ERROR: I2C no ACK on data"); end
    i2c_stop;
    repeat(10) @(posedge clk);
    if (!rx_seen)  begin errors++; $display("ERROR: I2C rx_valid never pulsed"); end
    if (rx_byte !== 8'h5A) begin errors++; $display("ERROR: I2C rx_byte=%h exp=5A", rx_byte); end

    // ---- read back (tx_byte) ----
    i2c_start;
    i2c_wbyte(8'hA1, ack);                 // addr 0x50 + R
    if (!ack) begin errors++; $display("ERROR: I2C no ACK on addr R"); end
    i2c_rbyte(1'b0, rb);                   // NACK after byte
    if (rb !== 8'hC3) begin errors++; $display("ERROR: I2C read got=%h exp=C3", rb); end
    i2c_stop;

    // ---- MSB=0 read vectors (first-byte MSB must not be lost) ----
    i2c_read_check(8'h73);
    i2c_read_check(8'h00);
    i2c_read_check(8'h7F);

    // ---- multi-byte reads: ST_TXACK->ST_TX re-entry coverage ----
    i2c_read2_check(8'hC3, 8'h73);
    i2c_read2_check(8'h00, 8'hFF);
    i2c_read3_check(8'hA5);

    // ---- wrong address must NACK ----
    i2c_start;
    i2c_wbyte(8'hA2, ack);                 // addr 0x51: not us
    if (ack) begin errors++; $display("ERROR: I2C wrong addr ACKed"); end
    i2c_stop;

    if (errors == 0) $display("TEST PASSED: I2C");
    else             $display("TEST FAILED: %0d errors", errors);
    $finish;
  end

  initial begin
    #2_000_000; $display("TIMEOUT"); $finish;
  end
endmodule
