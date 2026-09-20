// SPDX-License-Identifier: Apache-2.0
// Self-checking testbench for MIPI_SPMI_top -- SPMI master model
// Checks:
//   1. reset state: SDATA released, irq=0
//   2. register 0 write/read compare x2 (cmd 0x0 / 0x2)
//   3. extended register write BC=3 (cmd 0x3) + extended read BC=3 (cmd 0x8)
//   4. error injection: bad data parity -> write dropped + irq, reg unchanged
//   5. error injection: illegal command -> NACK (no response) + irq
//   6. A-bit arbitration: read with A=1 -> slave yields (silent), then
//      normal read with A=0 works again
//   7. error injection: unknown USID -> no response + irq
//   8. back-to-back consecutive transactions
// The SDATA bus is modelled as tri1 (pull-up); the master parks it low when
// idle and releases it only while the slave drives read data.
`timescale 1ns/1ps
module MIPI_SPMI_tb;

  localparam int HALF = 50;              // half SCLK period (ns, 5 clk cycles)

  logic clk = 0, rst_n = 0;
  logic m_sclk = 0;
  tri1  sdata;
  logic m_oe = 1, m_val = 0;             // master park-low driver
  assign sdata = m_oe ? m_val : 1'bz;

  logic irq;
  int errors = 0;

  localparam logic [3:0] USID = 4'h5;

  MIPI_SPMI_top #(.USID(USID)) dut (
    .clk(clk), .rst_n(rst_n),
    .sclk(m_sclk), .sdata(sdata),
    .irq(irq)
  );

  always #5 clk = ~clk;

  // ---------------------------------------------------------------
  // master primitives
  // ---------------------------------------------------------------
  task automatic m_bit(input logic b);   // one bit, full SCLK cycle
    begin
      m_sclk = 0; #1;
      m_oe   = 1; m_val = b;  #HALF;
      m_sclk = 1;             #HALF;
      m_sclk = 0;             #HALF;
    end
  endtask

  task automatic m_ssc;                  // long SDATA-high pulse while SCLK low
    begin
      m_sclk = 0; #1;
      m_oe   = 1; m_val = 1;  #(8*HALF);
    end
  endtask

  task automatic m_park;                 // bus-park cycle + park low
    begin
      m_bit(1'b0);                       // BP: SDATA low for one SCLK cycle
      m_oe = 1; m_val = 0; m_sclk = 0;  #(2*HALF);
    end
  endtask

  // 12-bit command frame {SA,C,A} + A-bit
  task automatic m_cmd(input logic [3:0] sa, input logic [3:0] c,
                       input logic [3:0] a, input logic abit);
    logic [11:0] f;
    begin
      f = {sa, c, a};
      for (int i = 11; i >= 0; i--) m_bit(f[i]);
      m_bit(abit);
    end
  endtask

  // 9-bit data frame {D,P} (even parity), optionally with wrong parity
  task automatic m_dframe(input logic [7:0] d, input logic bad_par);
    logic [8:0] f;
    begin
      f = {d, (^d) ^ bad_par};
      for (int i = 8; i >= 0; i--) m_bit(f[i]);
    end
  endtask

  // read n 9-bit data frames from the slave into rbuf
  logic [8:0] rbuf [0:7];
  task automatic m_rframes(input int n);
    begin
      m_oe = 1'b0;                       // turnaround: slave drives
      for (int k = 0; k < n; k++) begin
        for (int i = 8; i >= 0; i--) begin
          m_sclk = 0;           #HALF;
          m_sclk = 1;           #(HALF/2);
          rbuf[k][i] = sdata;   #(HALF/2);
          m_sclk = 0;           #HALF;
        end
      end
      m_oe = 1; m_val = 0;
    end
  endtask

  task automatic check(input logic cond, input string msg);
    begin
      if (!cond) begin errors++; $display("ERROR: %s (time %0t)", msg, $time); end
    end
  endtask

  // ---------------------------------------------------------------
  // compound transactions
  // ---------------------------------------------------------------
  task automatic spmi_r0_write(input logic [7:0] d, input logic bad_par);
    begin
      m_ssc;
      m_cmd(USID, 4'h0, 4'h0, 1'b1);     // write: master keeps bus (A=1)
      m_dframe(d, bad_par);
      m_park;
    end
  endtask

  task automatic spmi_r0_read(input logic [7:0] exp);
    begin
      m_ssc;
      m_cmd(USID, 4'h2, 4'h0, 1'b0);     // read: grant bus to slave (A=0)
      m_rframes(1);
      m_park;
      if (rbuf[0][8:1] !== exp) begin
        errors++;
        $display("ERROR: reg0 read got=%02x exp=%02x", rbuf[0][8:1], exp);
      end
      check(rbuf[0][0] === (^rbuf[0][8:1]), "reg0 read: bad parity from slave");
    end
  endtask

  // ---------------------------------------------------------------
  // test sequence
  // ---------------------------------------------------------------

  initial begin
    rst_n = 0; repeat (6) @(posedge clk);
    rst_n = 1; repeat (4) @(posedge clk);

    // -- check 1: reset / idle state ------------------------------
    check(irq === 1'b0, "irq asserted after reset");
    m_park;

    // -- check 2: register 0 write/read compare x2 ----------------
    spmi_r0_write(8'hA5, 1'b0);
    spmi_r0_read (8'hA5);
    spmi_r0_write(8'h5C, 1'b0);
    spmi_r0_read (8'h5C);
    check(irq === 1'b0, "irq set during valid traffic");

    // -- check 3: extended write BC=3 + extended read BC=3 --------
    m_ssc;
    m_cmd(USID, 4'h3, 4'd3, 1'b1);       // EXT write, BC=3, A=1
    m_dframe(8'h05, 1'b0);               // start address = 5
    m_dframe(8'h11, 1'b0);
    m_dframe(8'h22, 1'b0);
    m_dframe(8'h33, 1'b0);
    m_park;
    m_ssc;
    m_cmd(USID, 4'h8, 4'd3, 1'b0);       // EXT read, BC=3, A=0
    m_dframe(8'h05, 1'b0);               // start address = 5
    m_rframes(3);
    m_park;
    if (rbuf[0][8:1] !== 8'h11 || rbuf[1][8:1] !== 8'h22 || rbuf[2][8:1] !== 8'h33) begin
      errors++;
      $display("ERROR: ext read got=%02x %02x %02x exp=11 22 33",
               rbuf[0][8:1], rbuf[1][8:1], rbuf[2][8:1]);
    end
    check(rbuf[0][0] === (^rbuf[0][8:1]) && rbuf[1][0] === (^rbuf[1][8:1]) &&
          rbuf[2][0] === (^rbuf[2][8:1]), "ext read: bad parity from slave");

    // -- check 4: bad data parity -> write dropped + irq ----------
    spmi_r0_write(8'h77, 1'b0);          // known good value
    check(irq === 1'b0, "irq set after good write");
    spmi_r0_write(8'hAA, 1'b1);          // bad parity: must be dropped
    repeat (4) @(posedge clk);
    check(irq === 1'b1, "bad data parity: irq not raised");
    spmi_r0_read (8'h77);                // old value retained, clears irq
    repeat (4) @(posedge clk);
    check(irq === 1'b0, "irq not cleared by next SSC");

    // -- check 5: illegal command -> NACK (no response) + irq -----
    m_ssc;
    m_cmd(USID, 4'h5, 4'h0, 1'b0);       // illegal command, read-style
    m_rframes(1);                        // slave must stay silent
    m_park;
    check(rbuf[0] === 9'h1FF, "illegal cmd: slave responded");
    repeat (4) @(posedge clk);
    check(irq === 1'b1, "illegal cmd: irq not raised");

    // -- check 6: A-bit arbitration -- read with A=1 -> yield -----
    m_ssc;
    m_cmd(USID, 4'h2, 4'h0, 1'b1);       // read but master keeps bus
    m_rframes(1);                        // slave must yield (silent)
    m_park;
    check(rbuf[0] === 9'h1FF, "A-bit: slave did not yield to master");
    spmi_r0_read(8'h77);                 // normal read (A=0) still works

    // -- check 7: unknown USID -> no response + irq ---------------
    m_ssc;
    m_cmd(4'h9, 4'h2, 4'h0, 1'b0);       // foreign USID read
    m_rframes(1);
    m_park;
    check(rbuf[0] === 9'h1FF, "unknown USID: slave responded");
    repeat (4) @(posedge clk);
    check(irq === 1'b1, "unknown USID: irq not raised");

    // -- check 8: back-to-back consecutive transactions -----------
    spmi_r0_write(8'hC3, 1'b0);
    spmi_r0_read (8'hC3);
    spmi_r0_write(8'h3C, 1'b0);
    spmi_r0_read (8'h3C);
    check(irq === 1'b0, "irq set at end of test");

    if (errors == 0) $display("TEST PASSED: MIPI_SPMI");
    else             $display("TEST FAILED: %0d errors", errors);
    $finish;
  end

  initial begin
    #3000000;
    $display("TIMEOUT");
    $finish;
  end

endmodule
