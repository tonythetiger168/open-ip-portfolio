// SPDX-License-Identifier: Apache-2.0
// Self-checking testbench for MIPI_I3C_top -- I3C master model
// Checks:
//   1. reset state: SDA released high, irq=0, dyn_addr_valid=0
//   2. legacy I2C write/read on the static address (combined format), x2 regs
//   3. ENTDAA full flow: broadcast 0x7E + CCC 0x07 + Sr + 0x7E/R,
//      64-bit {PID,BCR,DCR} compare, dynamic address 0x2A assignment + ACK
//   4. post-ENTDAA write/read via the dynamic address (data compare)
//   5. direct CCC GETPID (0x8C): 6-byte PID readback compare
//   6. IBI: slave pull detected, arbitration address compare, payload compare
//   7. error injection: unknown broadcast CCC -> NACK + irq, cleared by START
//   8. consecutive transactions back-to-back
// The SDA bus is modelled as tri1 (pull-up); both ends drive open-drain/pp.
`timescale 1ns/1ps
module MIPI_I3C_tb;

  localparam int HALF = 60;          // half SCL period in ns (6 clk cycles)

  logic clk = 0, rst_n = 0;
  logic m_scl = 1;                   // master drives SCL (push-pull)
  tri1  sda;                         // bus with pull-up
  logic m_od_low = 0;                // master open-drain pull
  assign sda = m_od_low ? 1'b0 : 1'bz;

  logic       ibi_req = 0;
  logic [7:0] ibi_data = 8'h00;
  logic [6:0] dyn_addr;
  logic       dyn_addr_valid;
  logic       irq;

  int errors = 0;

  localparam logic [6:0]  SADDR = 7'h3C;
  localparam logic [47:0] PID   = 48'h0123_4567_89AB;
  localparam logic [7:0]  BCR   = 8'h06;
  localparam logic [7:0]  DCR   = 8'h5A;
  localparam logic [6:0]  DYN   = 7'h2A;

  MIPI_I3C_top #(.STATIC_ADDR(SADDR), .PID(PID), .BCR(BCR), .DCR(DCR)) dut (
    .clk(clk), .rst_n(rst_n),
    .scl(m_scl), .sda(sda),
    .ibi_req(ibi_req), .ibi_data(ibi_data),
    .dyn_addr(dyn_addr), .dyn_addr_valid(dyn_addr_valid),
    .irq(irq)
  );

  always #5 clk = ~clk;

  // ---------------------------------------------------------------
  // master primitives
  // ---------------------------------------------------------------
  task automatic m_idle;
    begin
      m_od_low = 0; m_scl = 1; #(2*HALF);
    end
  endtask

  task automatic m_start;
    begin
      m_od_low = 0; m_scl = 1; #HALF;
      m_od_low = 1;            #HALF;   // SDA falls while SCL high
      m_scl    = 0;            #HALF;
    end
  endtask

  task automatic m_stop;
    begin
      m_od_low = 1; m_scl = 0; #HALF;
      m_scl    = 1;            #HALF;
      m_od_low = 0;            #HALF;   // SDA rises while SCL high
    end
  endtask

  task automatic m_wbit(input logic b);
    begin
      m_scl    = 0;
      m_od_low = ~b;           #HALF;
      m_scl    = 1;            #HALF;
      m_scl    = 0;            #HALF;
    end
  endtask

  task automatic m_rbit(output logic b);
    begin
      m_od_low = 0;
      m_scl    = 0;            #HALF;
      m_scl    = 1;            #(HALF/2);
      b        = sda;          #(HALF/2);
      m_scl    = 0;            #HALF;
    end
  endtask

  // write byte, return slave ACK (1 = ACK)
  task automatic m_wbyte(input logic [7:0] d, output logic ack);
    begin
      for (int i = 7; i >= 0; i--) m_wbit(d[i]);
      m_od_low = 0;            #HALF;
      m_scl    = 1;            #(HALF/2);
      ack      = (sda === 1'b0);
                               #(HALF/2);
      m_scl    = 0;            #HALF;
    end
  endtask

  // read byte, then drive ACK(0)/NACK(1)
  task automatic m_rbyte(output logic [7:0] d, input logic nack);
    logic b;
    begin
      for (int i = 7; i >= 0; i--) begin m_rbit(b); d[i] = b; end
      m_wbit(nack);
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
  task automatic i2c_write(input logic [6:0] addr, input logic [7:0] regidx,
                           input logic [7:0] data);
    logic ack;
    begin
      m_start;
      m_wbyte({addr, 1'b0}, ack); check(ack, "write: addr NACKed");
      m_wbyte(regidx, ack);     check(ack, "write: regidx NACKed");
      m_wbyte(data, ack);       check(ack, "write: data NACKed");
      m_stop;
    end
  endtask

  task automatic i2c_read(input logic [6:0] addr, input logic [7:0] regidx,
                          input logic [7:0] exp);
    logic ack; logic [7:0] d;
    begin
      m_start;
      m_wbyte({addr, 1'b0}, ack); check(ack, "read: addr(W) NACKed");
      m_wbyte(regidx, ack);     check(ack, "read: regidx NACKed");
      m_start;                               // repeated START
      m_wbyte({addr, 1'b1}, ack); check(ack, "read: addr(R) NACKed");
      m_rbyte(d, 1'b1);                      // single byte + NACK
      m_stop;
      if (d !== exp) begin
        errors++;
        $display("ERROR: read @%02x got=%02x exp=%02x", regidx, d, exp);
      end
    end
  endtask

  // ---------------------------------------------------------------
  // test sequence
  // ---------------------------------------------------------------
  logic       ack;
  logic [7:0] d;
  logic [63:0] daa;
  logic        b;
  logic [7:0]  arb;

  initial begin
    m_scl = 1; m_od_low = 0;
    rst_n = 0; repeat (6) @(posedge clk);
    rst_n = 1; repeat (4) @(posedge clk);

    // -- check 1: reset / idle state ------------------------------
    check(sda === 1'b1, "SDA not released after reset");
    check(irq === 1'b0, "irq asserted after reset");
    check(dyn_addr_valid === 1'b0, "dyn_addr_valid set after reset");

    m_idle;

    // -- check 2: legacy I2C write/read on static address ---------
    i2c_write(SADDR, 8'h03, 8'hA5);
    i2c_write(SADDR, 8'h07, 8'h5C);
    i2c_read (SADDR, 8'h03, 8'hA5);
    i2c_read (SADDR, 8'h07, 8'h5C);

    // -- check 3: ENTDAA full flow --------------------------------
    m_start;
    m_wbyte(8'hFC, ack); check(ack, "ENTDAA: broadcast 7E/W NACKed");
    m_wbyte(8'h07, ack); check(ack, "ENTDAA: CCC 0x07 NACKed");
    m_start;                                   // repeated START
    m_wbyte(8'hFD, ack); check(ack, "ENTDAA: 7E/R NACKed");
    for (int i = 63; i >= 0; i--) begin m_rbit(b); daa[i] = b; end
    if (daa !== {PID, BCR, DCR}) begin
      errors++;
      $display("ERROR: ENTDAA DAA got=%012x exp=%012x", daa, {PID, BCR, DCR});
    end
    m_wbyte({DYN, 1'b0}, ack); check(ack, "ENTDAA: dyn addr NACKed");
    m_stop;
    repeat (4) @(posedge clk);
    check(dyn_addr_valid === 1'b1, "dyn_addr_valid not set after ENTDAA");
    check(dyn_addr === DYN, "dyn_addr mismatch after ENTDAA");

    // -- check 4: read/write via dynamic address ------------------
    i2c_write(DYN, 8'h0A, 8'h3C);
    i2c_read (DYN, 8'h0A, 8'h3C);
    i2c_read (DYN, 8'h03, 8'hA5);   // written earlier via static address

    // -- check 5: GETPID direct CCC -------------------------------
    m_start;
    m_wbyte({DYN, 1'b0}, ack); check(ack, "GETPID: addr(W) NACKed");
    m_wbyte(8'h8C, ack);       check(ack, "GETPID: CCC 0x8C NACKed");
    m_start;
    m_wbyte({DYN, 1'b1}, ack); check(ack, "GETPID: addr(R) NACKed");
    for (int i = 5; i >= 1; i--) begin
      m_rbyte(d, 1'b0);
      if (d !== PID[i*8 +: 8]) begin
        errors++; $display("ERROR: GETPID byte %0d got=%02x", i, d);
      end
    end
    m_rbyte(d, 1'b1);            // last PID byte + NACK
    if (d !== PID[7:0]) begin
      errors++; $display("ERROR: GETPID byte 0 got=%02x exp=%02x", d, PID[7:0]);
    end
    m_stop;

    // -- check 6: IBI ---------------------------------------------
    ibi_data = 8'hA5;
    ibi_req  = 1;
    fork
      begin : wait_pull
        wait (sda === 1'b0);
        disable pull_timeout;
      end
      begin : pull_timeout
        #20000;
        errors++; $display("ERROR: IBI: slave never pulled SDA");
        disable wait_pull;
      end
    join
    ibi_req = 0;
    // slave is pulling SDA; master clocks the arbitration (addr + RnW)
    for (int i = 7; i >= 0; i--) begin m_rbit(b); arb[i] = b; end
    if (arb !== {DYN, 1'b1}) begin
      errors++; $display("ERROR: IBI arb got=%02x exp=%02x", arb, {DYN, 1'b1});
    end
    m_wbit(1'b0);                // master ACKs: IBI accepted
    m_rbyte(d, 1'b0);            // payload byte + ACK
    if (d !== 8'hA5) begin
      errors++; $display("ERROR: IBI payload got=%02x exp=A5", d);
    end
    m_stop;
    m_idle;

    // -- check 7: error injection -- unknown broadcast CCC --------
    m_start;
    m_wbyte(8'hFC, ack); check(ack, "badCCC: broadcast 7E/W NACKed");
    m_wbyte(8'h55, ack); check(!ack, "badCCC: unknown CCC was ACKed");
    m_stop;
    repeat (6) @(posedge clk);
    check(irq === 1'b1, "badCCC: irq not raised for unknown CCC");
    // next valid transaction clears the error flag
    i2c_read(DYN, 8'h0A, 8'h3C);
    repeat (6) @(posedge clk);
    check(irq === 1'b0, "irq not cleared by new START");

    // -- check 8: back-to-back consecutive transactions -----------
    i2c_write(DYN, 8'h01, 8'h11);
    i2c_write(DYN, 8'h02, 8'h22);
    i2c_read (DYN, 8'h01, 8'h11);
    i2c_read (DYN, 8'h02, 8'h22);

    if (errors == 0) $display("TEST PASSED: MIPI_I3C");
    else             $display("TEST FAILED: %0d errors", errors);
    $finish;
  end

  initial begin
    #2000000;
    $display("TIMEOUT");
    $finish;
  end

endmodule
