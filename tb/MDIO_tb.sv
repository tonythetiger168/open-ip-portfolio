// SPDX-License-Identifier: Apache-2.0
// Self-checking testbench: TB acts as MDIO master (Clause 22) -- SystemVerilog
`timescale 1ns/1ps
module MDIO_tb;
  logic clk = 0, rst_n = 0;
  tri1  mdio;
  logic mdc = 0;
  logic m_low = 0;
  logic md_s;
  int errors = 0;

  MDIO_top #(.PHY_ADDR(5'h0C)) dut (
    .clk(clk), .rst_n(rst_n), .mdio(mdio), .mdc(mdc), .irq());

  always #5 clk = ~clk;
  assign mdio = m_low ? 1'b0 : 1'bz;

  task automatic mdc_bit(input logic bit_v);
    begin
      m_low = ~bit_v; #300;         // bit 0 -> pull low, bit 1 -> release (tri1)
      mdc = 1; #1;                  // sample at the rising edge: slave holds the
      md_s = mdio;                  // pre-edge drive; it advances ~30ns after
      #299;                         // the edge (sync + cnt increment)
      mdc = 0; #300;
    end
  endtask

  task automatic mdio_write(input logic [4:0] pa, input logic [4:0] ra,
                            input logic [15:0] data);
    logic b;
    begin
      for (int i = 0; i < 32; i++) begin
        b = (i == 0) ? 1'b0 :                    // ST = 01
            (i == 1) ? 1'b1 :
            (i == 2) ? 1'b0 :                    // OP = 01 (write)
            (i == 3) ? 1'b1 :
            (i <  9) ? pa[8-i] :                 // PHYAD: i=4..8
            (i < 14) ? ra[13-i] :                // REGAD: i=9..13
            (i == 14) ? 1'b1 :                   // TA = 10
            (i == 15) ? 1'b0 :
                       data[31-i];               // DATA: i=16..31
        mdc_bit(b);
      end
      m_low = 0; #600;
    end
  endtask

  task automatic mdio_read(input logic [4:0] pa, input logic [4:0] ra,
                           output logic [15:0] data);
    logic b;
    begin
      for (int i = 0; i < 14; i++) begin
        b = (i == 0) ? 1'b0 : (i == 1) ? 1'b1 :
            (i == 2) ? 1'b1 : (i == 3) ? 1'b0 :  // OP = 10 (read)
            (i <  9) ? pa[8-i] :                 // PHYAD
                       ra[13-i];                 // REGAD
        mdc_bit(b);
      end
      mdc_bit(1'b1);                            // TA bit 1: master releases
      mdc_bit(1'b1);                            // TA bit 2: slave begins driving
      for (int i = 0; i < 16; i++) begin
        mdc_bit(1'b1);                          // keep released, sample read data
        data[15-i] = md_s;
      end
      m_low = 0; #600;
    end
  endtask

  logic [15:0] rdata;
  initial begin
    rst_n = 0; repeat(10) @(posedge clk);
    rst_n = 1; repeat(10) @(posedge clk);

    mdio_write(5'h0C, 5'h03, 16'hBEEF);
    repeat(10) @(posedge clk);
    mdio_read (5'h0C, 5'h03, rdata);
    if (rdata !== 16'hBEEF) begin
      errors++; $display("ERROR: MDIO rw got=%h exp=BEEF", rdata);
    end

    mdio_read (5'h0C, 5'h00, rdata);            // preset PHY ID reg
    if (rdata !== 16'h1140) begin
      errors++; $display("ERROR: MDIO reg0 got=%h exp=1140", rdata);
    end

    if (errors == 0) $display("TEST PASSED: MDIO");
    else             $display("TEST FAILED: %0d errors", errors);
    $finish;
  end

  initial begin
    #3_000_000; $display("TIMEOUT"); $finish;
  end
endmodule
