// SPDX-License-Identifier: Apache-2.0
// Self-checking testbench for JTAG_top: IDCODE / USER / BYPASS scans
// Reference: OpenCores jtag test sequences -- SystemVerilog
`timescale 1ns/1ps
module JTAG_tb;
  logic clk = 0, rst_n = 0;
  logic tck = 0, tms = 1, tdi = 0, trst_n = 0;
  logic tdo;
  logic tdo_s;
  int errors = 0;

  JTAG_top dut (
    .clk(clk), .rst_n(rst_n), .tck(tck), .tms(tms), .tdi(tdi),
    .trst_n(trst_n), .tdo(tdo), .irq());

  always #5 clk = ~clk;

  task automatic jcyc(input logic tms_v, input logic tdi_v);
    begin
      tms = tms_v; tdi = tdi_v;
      #100 tck = 1'b1; #100;
      tck = 1'b0; #10 tdo_s = tdo; #90;
    end
  endtask

  task automatic goto_rti;
    begin
      for (int i = 0; i < 5; i++) jcyc(1'b1, 1'b0);   // TLR
      jcyc(1'b0, 1'b0);                               // RTI
    end
  endtask

  // shift IR (4 bits, LSB first), last bit exits to UPDATE_IR
  task automatic load_ir(input logic [3:0] op);
    begin
      jcyc(1'b1, 1'b0);                 // SEL_DR
      jcyc(1'b1, 1'b0);                 // SEL_IR
      jcyc(1'b0, 1'b0);                 // -> CAP_IR
      jcyc(1'b0, 1'b0);                 // CAP_IR: capture 0101, -> SH_IR
      jcyc(1'b0, op[0]);                // shift 1
      jcyc(1'b0, op[1]);                // shift 2
      jcyc(1'b0, op[2]);                // shift 3
      jcyc(1'b1, op[3]);                // shift 4 + exit
      jcyc(1'b1, 1'b0);                 // UPD_IR
      jcyc(1'b0, 1'b0);                 // RTI
    end
  endtask

  task automatic scan_dr(input int n, input logic [31:0] din,
                         output logic [31:0] dout);
    logic [31:0] tmp;
    begin
      jcyc(1'b1, 1'b0);                 // SEL_DR
      jcyc(1'b0, 1'b0);                 // -> CAP_DR
      jcyc(1'b0, 1'b0);                 // CAP_DR: capture, -> SH_DR
      for (int k = 0; k < n; k++) begin
        jcyc(k == n-1, din[k]);         // shift bit k, TDO shows pre-shift LSB
        tmp[k] = tdo_s;
      end
      jcyc(1'b1, 1'b0);                 // EX1_DR -> UPD_DR
      jcyc(1'b0, 1'b0);                 // -> RTI
      dout = tmp;
    end
  endtask

  logic [31:0] rd;
  initial begin
    rst_n = 0; trst_n = 0;
    #200;
    rst_n = 1; trst_n = 1;
    #500;

    // ---- IDCODE scan ----
    goto_rti;
    load_ir(4'b0001);                      // IDCODE
    scan_dr(32, 32'h0, rd);
    if (rd !== 32'h1CAF_0001) begin
      errors++; $display("ERROR: JTAG IDCODE got=%h exp=1CAF0001", rd);
    end

    // ---- USER reg write 0xA5 then read back ----
    goto_rti;
    load_ir(4'b0010);                      // USER
    scan_dr(8, 32'h0000_00A5, rd);
    goto_rti;
    load_ir(4'b0010);
    scan_dr(8, 32'h0, rd);
    if (rd[7:0] !== 8'hA5) begin
      errors++; $display("ERROR: JTAG USER got=%h exp=A5", rd[7:0]);
    end

    // ---- BYPASS: scanned value = {din[6:0], capture_bit} = din<<1 ----
    goto_rti;
    load_ir(4'b1111);                      // BYPASS
    scan_dr(8, 32'h0000_003C, rd);         // pattern 00111100 LSB-first
    if (rd[7:0] !== 8'h78) begin           // capture(0) first, then din[0..6]
      errors++; $display("ERROR: JTAG BYPASS got=%h exp=78", rd[7:0]);
    end

    if (errors == 0) $display("TEST PASSED: JTAG");
    else             $display("TEST FAILED: %0d errors", errors);
    $finish;
  end

  initial begin
    #5_000_000; $display("TIMEOUT"); $finish;
  end
endmodule
