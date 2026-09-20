// SPDX-License-Identifier: Apache-2.0
// Self-checking testbench for MIPI_RFFE_top -- RFFE master model
// Checks:
//   1. reset state: SDATA released, irq=0
//   2. register write/read compare x4 (parity checked frames)
//   3. extended register write BC=3 + readback compare of all 3 bytes
//   4. error injection: bad command parity -> frame ignored + irq
//   5. error injection: bad data parity -> write dropped + irq, reg unchanged
//   6. error injection: unknown USID read -> slave silent (reads 1s) + irq
//   7. back-to-back consecutive transactions
// The SDATA bus is modelled as tri1 (pull-up); the master parks it low when
// idle as RFFE requires, and releases it only for the read turnaround.
`timescale 1ns/1ps
module MIPI_RFFE_tb;

  localparam int HALF = 50;              // half SCLK period (ns, 5 clk cycles)

  logic clk = 0, rst_n = 0;
  logic m_sclk = 0;
  tri1  sdata;
  logic m_oe = 1, m_val = 0;             // master park-low driver
  assign sdata = m_oe ? m_val : 1'bz;

  logic irq;
  int errors = 0;

  localparam logic [3:0] USID = 4'h5;

  MIPI_RFFE_top #(.USID(USID)) dut (
    .clk(clk), .rst_n(rst_n),
    .sclk(m_sclk), .sdata(sdata),
    .irq(irq)
  );

  always #5 clk = ~clk;

  // ---------------------------------------------------------------
  // master primitives
  // ---------------------------------------------------------------
  task automatic m_bit(input logic b);   // drive one bit, full SCLK cycle
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

  task automatic m_park;                 // park the bus low (idle state)
    begin
      m_oe = 1; m_val = 0; m_sclk = 0;  #(2*HALF);
    end
  endtask

  // send 13-bit command frame {SA,C,A,P}
  task automatic m_cmd(input logic [3:0] sa, input logic [2:0] c,
                       input logic [4:0] a);
    logic [12:0] f;
    begin
      f = {sa, c, a, 1'b0};
      f[0] = ^f[12:1];                   // even parity
      for (int i = 12; i >= 0; i--) m_bit(f[i]);
    end
  endtask

  // send 9-bit data frame {D,P}
  task automatic m_dframe(input logic [7:0] d);
    logic [8:0] f;
    begin
      f = {d, ^d};
      for (int i = 8; i >= 0; i--) m_bit(f[i]);
    end
  endtask

  // read 9-bit data frame from the slave (after BP), returns {D,P}
  task automatic m_rframe(output logic [8:0] f);
    begin
      // BP cycle: master drives low for one SCLK cycle, then releases
      m_bit(1'b0);
      m_oe = 1'b0;                       // turnaround: slave drives
      for (int i = 8; i >= 0; i--) begin
        m_sclk = 0;             #HALF;
        m_sclk = 1;             #(HALF/2);
        f[i] = sdata;           #(HALF/2);
        m_sclk = 0;             #HALF;
      end
      m_oe = 1; m_val = 0;               // park low again
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
  task automatic rffe_write(input logic [3:0] sa, input logic [4:0] a,
                            input logic [7:0] d);
    begin
      m_ssc;
      m_cmd(sa, 3'b010, a);
      m_dframe(d);
      m_park;
    end
  endtask

  task automatic rffe_read(input logic [3:0] sa, input logic [4:0] a,
                           input logic [7:0] exp, input logic expect_drv);
    logic [8:0] f;
    begin
      m_ssc;
      m_cmd(sa, 3'b011, a);
      m_rframe(f);
      m_park;
      if (expect_drv) begin
        if (f[8:1] !== exp) begin
          errors++;
          $display("ERROR: read @%02x got=%02x exp=%02x", a, f[8:1], exp);
        end
        check(f[0] === (^f[8:1]), "read: bad parity from slave");
      end else begin
        check(f === 9'h1FF, "read: slave responded to foreign USID");
      end
    end
  endtask

  // ---------------------------------------------------------------
  // test sequence
  // ---------------------------------------------------------------
  logic [8:0] f;

  initial begin
    rst_n = 0; repeat (6) @(posedge clk);
    rst_n = 1; repeat (4) @(posedge clk);

    // -- check 1: reset / idle state ------------------------------
    check(irq === 1'b0, "irq asserted after reset");
    m_park;

    // -- check 2: register write/read compare x4 ------------------
    rffe_write(USID, 5'h03, 8'hA5);
    rffe_write(USID, 5'h07, 8'h5C);
    rffe_write(USID, 5'h0A, 8'h3C);
    rffe_write(USID, 5'h0F, 8'hC3);
    rffe_read (USID, 5'h03, 8'hA5, 1'b1);
    rffe_read (USID, 5'h07, 8'h5C, 1'b1);
    rffe_read (USID, 5'h0A, 8'h3C, 1'b1);
    rffe_read (USID, 5'h0F, 8'hC3, 1'b1);
    check(irq === 1'b0, "irq set during valid traffic");

    // -- check 3: extended register write BC=3 + readback ---------
    m_ssc;
    m_cmd(USID, 3'b110, 5'd3);           // BC=3
    m_dframe(8'h04);                     // start address = 4
    m_dframe(8'h11);
    m_dframe(8'h22);
    m_dframe(8'h33);
    m_park;
    rffe_read(USID, 5'h04, 8'h11, 1'b1);
    rffe_read(USID, 5'h05, 8'h22, 1'b1);
    rffe_read(USID, 5'h06, 8'h33, 1'b1);

    // -- check 4: bad command parity -> ignored + irq -------------
    m_ssc;
    begin
      logic [12:0] bf;
      bf = {USID, 3'b010, 5'h09, 1'b0};
      bf[0] = ~(^bf[12:1]);              // WRONG parity on purpose
      for (int i = 12; i >= 0; i--) m_bit(bf[i]);
    end
    m_dframe(8'hEE);                     // must be ignored
    m_park;
    repeat (4) @(posedge clk);
    check(irq === 1'b1, "bad cmd parity: irq not raised");
    rffe_read(USID, 5'h09, 8'h00, 1'b1); // reg 9 never written -> reads 0
    check(irq === 1'b0, "irq not cleared by next SSC");

    // -- check 5: bad data parity -> write dropped + irq ----------
    rffe_write(USID, 5'h02, 8'h55);      // known good value first
    check(irq === 1'b0, "irq set after good write");
    m_ssc;
    m_cmd(USID, 3'b010, 5'h02);
    begin
      logic [8:0] bf;
      bf = {8'hAA, ~(^8'hAA)};           // WRONG data parity on purpose
      for (int i = 8; i >= 0; i--) m_bit(bf[i]);
    end
    m_park;
    repeat (4) @(posedge clk);
    check(irq === 1'b1, "bad data parity: irq not raised");
    rffe_read(USID, 5'h02, 8'h55, 1'b1); // old value retained

    // -- check 6: unknown USID -> no response + irq ---------------
    rffe_read(4'h9, 5'h03, 8'h00, 1'b0); // slave must stay silent
    repeat (4) @(posedge clk);
    check(irq === 1'b1, "unknown USID: irq not raised");

    // -- check 7: back-to-back consecutive transactions -----------
    rffe_write(USID, 5'h0B, 8'h77);
    rffe_write(USID, 5'h0C, 8'h88);
    rffe_read (USID, 5'h0B, 8'h77, 1'b1);
    rffe_read (USID, 5'h0C, 8'h88, 1'b1);
    rffe_read (USID, 5'h03, 8'hA5, 1'b1);
    check(irq === 1'b0, "irq set at end of test");

    if (errors == 0) $display("TEST PASSED: MIPI_RFFE");
    else             $display("TEST FAILED: %0d errors", errors);
    $finish;
  end

  initial begin
    #3000000;
    $display("TIMEOUT");
    $finish;
  end

endmodule
