// SPDX-License-Identifier: Apache-2.0
// Self-checking testbench for MIPI_I3C_top -- I3C master model plus a second
// (competing) open-drain slave on the bus.
// Covered: legacy I2C register writes / combined-format reads on the static
// address, pointer out of range, address NACK, broadcast CCCs (ENTDAA with
// the 64-bit {PID,BCR,DCR} answer, a parity error on the assigned address,
// losing the ENTDAA arbitration to another slave and retrying, the
// "nothing left" 7E/R, RSTDAA, GETPID, unknown CCC), 7E/R outside ENTDAA,
// transfers on the dynamic address, IBI (delivered, NACKed and retried,
// arbitration lost, held while no dynamic address), reset mid-transfer.
`timescale 1ns/1ps
module MIPI_I3C_tb;

  localparam int HALF = 60;          // half SCL period in ns (6 clk cycles)

  logic clk = 0, rst_n = 0;
  logic m_scl = 1;                   // master drives SCL (push-pull)
  tri1  sda;                         // bus with pull-up
  logic m_od_low = 0;                // master open-drain pull
  logic o_od = 0;                    // the other slave's open-drain pull
  assign sda = m_od_low ? 1'b0 : 1'bz;
  assign sda = o_od ? 1'b0 : 1'bz;

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

  MIPI_I3C_top #(.STATIC_ADDR(SADDR), .PID(PID), .BCR(BCR), .DCR(DCR)) dut (
    .clk(clk), .rst_n(rst_n),
    .scl(m_scl), .sda(sda),
    .ibi_req(ibi_req), .ibi_data(ibi_data),
    .dyn_addr(dyn_addr), .dyn_addr_valid(dyn_addr_valid),
    .irq(irq)
  );

  always #5 clk = ~clk;

  task automatic check(input logic cond, input string msg);
    if (!cond) begin errors++; $display("ERROR: %s (time %0t)", msg, $time); end
  endtask

  // ---------------------------------------------------------------
  // master primitives
  // ---------------------------------------------------------------
  task automatic m_start;
    m_od_low = 0; m_scl = 1; #HALF;
    m_od_low = 1;            #HALF;   // SDA falls while SCL high
    m_scl    = 0;            #HALF;
  endtask
  task automatic m_stop;
    m_od_low = 1; m_scl = 0; #HALF;
    m_scl    = 1;            #HALF;
    m_od_low = 0;            #(2*HALF); // SDA rises while SCL high
  endtask
  task automatic m_wbit(input logic b);
    m_scl = 0; m_od_low = ~b; #HALF;
    m_scl = 1;                #HALF;
    m_scl = 0;                #HALF;
  endtask
  task automatic m_rbit(output logic b);
    m_od_low = 0;
    m_scl = 0; #HALF;
    m_scl = 1; #(HALF/2);
    b = sda;   #(HALF/2);
    m_scl = 0; #HALF;
  endtask
  // write a byte, return the slave's ACK (1 = ACK)
  task automatic m_wbyte(input logic [7:0] d, output logic ack);
    for (int i = 7; i >= 0; i--) m_wbit(d[i]);
    m_od_low = 0; #HALF;
    m_scl = 1;    #(HALF/2);
    ack = (sda === 1'b0); #(HALF/2);
    m_scl = 0;    #HALF;
  endtask
  // read a byte, then ACK (nack = 0) or NACK (nack = 1)
  task automatic m_rbyte(output logic [7:0] d, input logic nack);
    logic b;
    for (int i = 7; i >= 0; i--) begin m_rbit(b); d[i] = b; end
    m_wbit(nack);
  endtask

  logic ack;
  logic [7:0] rd;
  logic [7:0] model [0:15];

  task automatic wr_regs(input logic [6:0] a, input logic [3:0] p, input int n, input logic [7:0] seed);
    m_start;
    m_wbyte({a, 1'b0}, ack); check(ack, "write address ACK");
    m_wbyte({4'h0, p}, ack); check(ack, "pointer ACK");
    for (int i = 0; i < n; i++) begin
      logic [7:0] v;
      v = seed ^ 8'(i * 37);
      m_wbyte(v, ack); check(ack, "data ACK");
      model[4'(p + i)] = v;
    end
    m_stop;
  endtask

  task automatic rd_regs(input logic [6:0] a, input logic [3:0] p, input int n);
    m_start;
    m_wbyte({a, 1'b0}, ack); check(ack, "write address ACK");
    m_wbyte({4'h0, p}, ack); check(ack, "pointer ACK");
    m_start;                                  // repeated START
    m_wbyte({a, 1'b1}, ack); check(ack, "read address ACK");
    for (int i = 0; i < n; i++) begin
      m_rbyte(rd, i == n - 1);
      check(rd == model[4'(p + i)], $sformatf("register %0d read %h exp %h", 4'(p + i), rd, model[4'(p + i)]));
    end
    m_stop;
  endtask

  // ENTDAA: returns 1 if the DUT took the address. other: a competing
  // slave's 64-bit ID (0 = none); bad_par sends a wrong parity bit
  task automatic entdaa_round(input logic [63:0] other, input logic [6:0] addr, input logic bad_par,
                              output logic took);
    logic [63:0] got;
    logic b;
    m_start;                                  // repeated START
    m_wbyte({7'h7E, 1'b1}, ack);
    took = 0;
    if (ack) begin
      for (int i = 63; i >= 0; i--) begin
        m_od_low = 0; m_scl = 0;
        o_od = other != 0 && !other[i];
        #HALF; m_scl = 1; #(HALF/2); b = sda; #(HALF/2); m_scl = 0;
        got[i] = b;
      end
      o_od = 0;
      if (other == 0) check(got == {PID, BCR, DCR}, "ENTDAA 64-bit answer");
      m_wbyte({addr, ~(^addr) ^ bad_par}, ack);
      took = ack && other == 0 && !bad_par;
    end
  endtask

  task automatic ccc(input logic [7:0] code, input logic exp_ack);
    m_start;
    m_wbyte({7'h7E, 1'b0}, ack); check(ack, "7E/W ACK");
    m_wbyte(code, ack); check(ack == exp_ack, $sformatf("CCC %h ACK", code));
  endtask

  task automatic full_entdaa(input logic [6:0] addr);
    logic took;
    ccc(8'h07, 1);
    entdaa_round(0, addr, 0, took);
    check(took, "ENTDAA address taken");
    entdaa_round(0, addr, 0, took);           // nothing left: silent NACK
    check(!took && !irq, "second 7E/R NACKed without irq");
    m_stop;
    check(dyn_addr_valid && dyn_addr == addr, "dynamic address");
  endtask

  // IBI: wait for the slave's pull, run the header; returns the payload
  task automatic ibi_serve(input logic nack, input logic [6:0] beat, output logic [7:0] data,
                           output logic seen);
    logic [7:0] hdr;
    int t;
    t = 0;
    while (sda !== 1'b0 && t < 200) begin #10; t++; end
    seen = sda === 1'b0;
    data = 0;
    if (seen) begin
    #HALF; m_scl = 0; #HALF;
    for (int i = 7; i >= 0; i--) begin
      logic b;
      m_od_low = 0; m_scl = 0;
      // a higher-priority address pulls its 0 bits (open-drain)
      if (beat != 0 && i > 0) m_od_low = !beat[i - 1];
      #HALF; m_scl = 1; #(HALF/2); b = sda; #(HALF/2); m_scl = 0;
      hdr[i] = b;
    end
    m_od_low = 0;
    if (beat == 0) check(hdr == {dyn_addr, 1'b1}, "IBI arbitration header");
    m_wbit(nack || beat != 0);
    if (!nack && beat == 0) m_rbyte(data, 1);
    m_stop;
    end
  endtask

  initial begin
    logic took, seen;
    for (int i = 0; i < 16; i++) model[i] = 0;
    #100 rst_n = 1;
    #200;
    check(sda === 1'b1 && !irq && !dyn_addr_valid, "reset state");

    // ---- legacy I2C on the static address ----
    wr_regs(SADDR, 4'd0, 16, 8'hA5);
    rd_regs(SADDR, 4'd0, 16);
    wr_regs(SADDR, 4'd0, 16, 8'h5A);          // every bit both ways
    wr_regs(SADDR, 4'd0, 16, 8'hA5);
    wr_regs(SADDR, 4'd14, 4, 8'h00);          // pointer wraps
    rd_regs(SADDR, 4'd13, 5);
    // pointer out of range -> NACK + irq; the next START clears irq
    m_start; m_wbyte({SADDR, 1'b0}, ack); m_wbyte(8'h10, ack);
    check(!ack, "pointer 0x10 NACKed"); m_stop; check(irq, "irq for bad pointer");
    m_start; check(!irq, "START clears irq"); m_wbyte({7'h11, 1'b0}, ack);
    check(!ack, "other address NACKed"); m_stop;
    // 7E/R outside ENTDAA; unknown CCC
    m_start; m_wbyte({7'h7E, 1'b1}, ack); check(!ack, "7E/R NACK"); m_stop;
    check(irq, "irq for 7E/R outside ENTDAA");
    ccc(8'h55, 0); m_stop; check(irq, "irq for unknown CCC");
    // IBI request before any dynamic address: held
    ibi_data = 8'hC3; ibi_req = 1; #20 ibi_req = 0;
    #1000; check(sda === 1'b1, "no IBI without a dynamic address");

    // ---- ENTDAA: lost arbitration, bad parity, then success ----
    ccc(8'h07, 1);
    entdaa_round({PID ^ 48'h0000_0000_0001, BCR, DCR} & ~64'h0000_0000_0100_0000, 7'h11, 0, took);
    check(!took && !dyn_addr_valid, "ENTDAA lost to the other slave");
    entdaa_round(0, 7'h2A, 1, took);
    check(!took && !dyn_addr_valid && irq, "ENTDAA parity error");
    entdaa_round(0, 7'h2A, 0, took);
    check(took, "ENTDAA after the retries");
    entdaa_round(0, 7'h2A, 0, took);
    check(!took, "nothing left");
    m_stop;
    check(dyn_addr_valid && dyn_addr == 7'h2A, "dynamic address 2A");

    // ---- the held IBI goes out now ----
    ibi_serve(0, 0, rd, seen);
    check(seen && rd == 8'hC3, "held IBI delivered");

    // ---- transfers on the dynamic address ----
    wr_regs(7'h2A, 4'd3, 3, 8'h3C);
    rd_regs(7'h2A, 4'd3, 3);

    // ---- GETPID: 6 PID bytes, then the last byte repeats ----
    ccc(8'h8C, 1);
    m_start; m_wbyte({7'h2A, 1'b1}, ack); check(ack, "GETPID read ACK");
    for (int i = 0; i < 8; i++) begin
      m_rbyte(rd, i == 7);
      check(rd == (i < 6 ? PID[47 - 8 * i -: 8] : PID[7:0]), $sformatf("PID byte %0d", i));
    end
    m_stop;

    // ---- IBI: NACK keeps the request, then delivered; arbitration lost ----
    ibi_data = 8'h96; ibi_req = 1; #20 ibi_req = 0;
    ibi_serve(1, 0, rd, seen); check(seen && !irq, "IBI NACKed");
    ibi_serve(0, 0, rd, seen); check(seen && rd == 8'h96, "IBI retried and delivered");
    ibi_data = 8'h69; ibi_req = 1; #20 ibi_req = 0;
    ibi_serve(0, 7'h05, rd, seen); check(seen && irq, "IBI arbitration lost");
    #2000; check(sda === 1'b1, "lost IBI is dropped");

    // ---- RSTDAA, then a new dynamic address (every address bit both ways) ----
    ccc(8'h06, 1); m_stop; check(!dyn_addr_valid, "RSTDAA");
    full_entdaa(7'h55);
    ccc(8'h06, 1); m_stop;
    full_entdaa(7'h2A);
    ccc(8'h07, 1);                            // already assigned: no answer
    entdaa_round(0, 7'h33, 0, took); check(!took, "assigned slave stays out of ENTDAA");
    m_stop;

    // ---- reset in the middle of a read ----
    m_start; m_wbyte({SADDR, 1'b1}, ack);
    m_rbit(rd[0]); m_rbit(rd[0]);
    rst_n = 0; #50;
    check(sda === 1'b1 && !dyn_addr_valid && !irq, "reset mid-read");
    for (int i = 0; i < 16; i++) model[i] = 0;
    m_scl = 1; m_od_low = 0; #100 rst_n = 1; #200;
    rd_regs(SADDR, 4'd0, 2);                  // register file cleared
    ibi_data = 8'h00;

    if (errors == 0) $display("TEST PASSED: MIPI_I3C");
    else             $display("TEST FAILED: %0d errors", errors);
    $finish;
  end

  initial begin
    #5000000;
    $display("TEST FAILED: TIMEOUT"); $finish;
  end
endmodule
