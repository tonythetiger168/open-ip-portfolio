// SPDX-License-Identifier: Apache-2.0
// HBM2 TB (MEMCH-wrapper style, template: tb/DDR4_tb.sv, 8-channel).
// Checks: reset pin state / ACT bus pulse + trace + tRCD enforcement /
// write->readback x4 with CL timing / DQ pin drive per channel slice /
// timing-violation injection (early CMD while busy must be ignored) /
// PRE bus pulse + re-ACT recovery / 8-channel isolation (ch3 vs ch7 vs ch0).
`timescale 1ns/1ps
module HBM2_tb;
  localparam int CL = 14, TRCD = 7, TRP = 7;
  logic clk = 0, rst_n = 0;
  logic hvalid = 0, hready;
  logic [2:0] hcmd = 0;
  logic [31:0] haddr = 0;
  logic [15:0] hwdata = 0, hrdata;
  logic hdone;
  logic ck_t, ck_c;
  logic [16:0] addr; logic ras_n, cas_n, we_n;
  tri [127:0] dq; tri [1:0] dqs; logic cke;
  logic trace_valid; logic [2:0] trace_cmd; logic [31:0] trace_addr;
  int errors = 0;
  int cyc;
  logic [15:0] got;

  HBM2_top dut (.*);
  always #5 clk = ~clk;

  // host command; channel select is haddr[10:8], column haddr[7:0]
  task automatic cmd(input logic [2:0] c, input logic [31:0] a, input logic [15:0] d);
    begin
      wait (hready === 1'b1);
      @(negedge clk);
      hcmd <= c; haddr <= a; hwdata <= d; hvalid <= 1'b1;
      @(negedge clk);
      hvalid <= 1'b0;
    end
  endtask

  task automatic rd_cmp(input logic [31:0] a, input logic [15:0] exp, input string tag);
    begin
      cmd(3'd2, a, 16'h0);
      wait (hdone === 1'b1); @(posedge clk); #1;
      got = hrdata;
      if (got !== exp) begin errors++; $display("ERROR: HBM2 %s got=%h exp=%h", tag, got, exp); end
    end
  endtask

  initial begin
    // ---------------- check 1: reset / idle pin state ----------------
    rst_n = 0; repeat(5) @(posedge clk); #1;
    if (cke !== 1'b0)                    begin errors++; $display("ERROR: HBM2 cke high during reset"); end
    if ({ras_n, cas_n, we_n} !== 3'b111) begin errors++; $display("ERROR: HBM2 cmd bus not idle in reset"); end
    if (trace_valid !== 1'b0)            begin errors++; $display("ERROR: HBM2 trace_valid in reset"); end
    rst_n = 1; repeat(2) @(posedge clk); #1;
    if (cke !== 1'b1)                    begin errors++; $display("ERROR: HBM2 cke low after reset"); end
    if (hready !== 1'b1)                 begin errors++; $display("ERROR: HBM2 hready low after reset"); end

    // ---------------- check 2: ACT trace + bus pulse + tRCD enforcement ----------------
    cmd(3'd1, 32'h0004_0000, 16'h0);            // ch0 ACT row = haddr[31:18] = 1
    #1;
    if (!(trace_valid === 1'b1 && trace_cmd === 3'd1 && trace_addr === 32'h0004_0000))
      begin errors++; $display("ERROR: HBM2 ACT trace v=%b cmd=%0d addr=%h", trace_valid, trace_cmd, trace_addr); end
    if (hready !== 1'b0) begin errors++; $display("ERROR: HBM2 hready not low after ACT (tRCD not enforced)"); end
    cyc = 0;
    while (hready !== 1'b1) begin @(posedge clk); #1; cyc++; end
    if (cyc !== TRCD + 2) begin errors++; $display("ERROR: HBM2 tRCD busy cycles=%0d exp=%0d", cyc, TRCD + 2); end

    // ---------------- check 3: 4x WR back-to-back, trace + DQ slice drive ----------------
    for (int i = 0; i < 4; i++) begin
      cmd(3'd3, i, 16'h1700 + i * 8'h11);
      if (i == 0) begin
        #1;
        if (!(trace_valid === 1'b1 && trace_cmd === 3'd3 && trace_addr === 32'h0))
          begin errors++; $display("ERROR: HBM2 WR trace v=%b cmd=%0d addr=%h", trace_valid, trace_cmd, trace_addr); end
        if (dq[15:0] !== 16'h1700) begin errors++; $display("ERROR: HBM2 dq[15:0] not driven during WR, dq=%h", dq[15:0]); end
        if (dq[127:16] !== 112'hzzzz_zzzz_zzzz_zzzz_zzzz_zzzz_zzzz)
          begin errors++; $display("ERROR: HBM2 idle channel dq slices not Hi-Z during ch0 WR"); end
      end
    end

    // ---------------- check 4: 4x RD, CL timing + readback compare ----------------
    for (int i = 0; i < 4; i++) begin
      cmd(3'd2, i, 16'h0);
      if (i == 0) begin
        #1;
        if (!(trace_valid === 1'b1 && trace_cmd === 3'd2 && trace_addr === 32'h0))
          begin errors++; $display("ERROR: HBM2 RD trace v=%b cmd=%0d addr=%h", trace_valid, trace_cmd, trace_addr); end
      end
      cyc = 0;
      while (hdone !== 1'b1) begin @(posedge clk); #1; cyc++; end
      if (i == 0 && cyc !== CL + 1)
        begin errors++; $display("ERROR: HBM2 CL latency cycles=%0d exp=%0d", cyc, CL + 1); end
      @(posedge clk); #1;
      got = hrdata;
      if (got !== 16'h1700 + i * 8'h11)
        begin errors++; $display("ERROR: HBM2 ch0[%0d] got=%h exp=%h", i, got, 16'h1700 + i * 8'h11); end
    end

    // ---------------- check 5: timing-violation injection ----------------
    // issue RD while controller is busy in tRCD: must be ignored, no spurious
    // hdone, memory/readback unaffected
    cmd(3'd1, 32'h0008_0000, 16'h0);            // ch0 ACT row 2
    @(negedge clk);
    hcmd <= 3'd2; haddr <= 32'h2; hwdata <= 16'h0; hvalid <= 1'b1;  // early RD
    @(negedge clk);
    hvalid <= 1'b0;
    #1;
    if (hdone !== 1'b0)       begin errors++; $display("ERROR: HBM2 hdone pulse from injected early RD"); end
    if (trace_valid !== 1'b0) begin errors++; $display("ERROR: HBM2 trace from injected early RD"); end
    while (hready !== 1'b1) begin
      @(posedge clk); #1;
      if (hdone === 1'b1) begin errors++; $display("ERROR: HBM2 spurious hdone after injection"); end
    end
    rd_cmp(32'h2, 16'h1722, "ch0[2] after injection");

    // ---------------- check 6: PRE bus pulse + re-ACT recovery ----------------
    cmd(3'd4, 32'h0, 16'h0);                    // ch0 PRE
    @(posedge clk); #1;
    if (!(ras_n === 1'b0 && cas_n === 1'b1 && we_n === 1'b0))
      begin errors++; $display("ERROR: HBM2 PRE not on bus ras_n=%b cas_n=%b we_n=%b", ras_n, cas_n, we_n); end
    cmd(3'd1, 32'h000C_0000, 16'h0);            // ch0 re-ACT row 3
    @(posedge clk); #1;
    if (!(ras_n === 1'b0 && cas_n === 1'b1 && we_n === 1'b1))
      begin errors++; $display("ERROR: HBM2 ACT not on bus ras_n=%b cas_n=%b we_n=%b", ras_n, cas_n, we_n); end
    @(posedge clk); #1;
    if (ras_n !== 1'b1) begin errors++; $display("ERROR: HBM2 RAS not recovered after ACT"); end

    // ---------------- check 7: channel isolation across the 8 channels ----------------
    // write distinct data to same column of ch3 and ch7; verify no aliasing
    // between channels and that ch0 is untouched
    cmd(3'd1, 32'h0000_0300, 16'h0);            // ch3 ACT row 0
    cmd(3'd3, 32'h0000_0305, 16'hC303);         // ch3 WR col 5
    #1;
    if (dq[63:48] !== 16'hC303) begin errors++; $display("ERROR: HBM2 dq[63:48] not driven during ch3 WR"); end
    cmd(3'd1, 32'h0000_0700, 16'h0);            // ch7 ACT row 0
    cmd(3'd3, 32'h0000_0705, 16'hC707);         // ch7 WR col 5
    #1;
    if (dq[127:112] !== 16'hC707) begin errors++; $display("ERROR: HBM2 dq[127:112] not driven during ch7 WR"); end
    rd_cmp(32'h0000_0305, 16'hC303, "ch3[5]");
    rd_cmp(32'h0000_0705, 16'hC707, "ch7[5]");
    rd_cmp(32'h0000_0005, 16'h0000, "ch0[5] untouched");
    rd_cmp(32'h0000_0000, 16'h1700, "ch0[0] intact after ch3/ch7 traffic");

    if (errors == 0) $display("TEST PASSED: HBM2");
    else             $display("TEST FAILED: %0d errors", errors);
    $finish;
  end

  initial begin
    #500_000; $display("TIMEOUT"); $finish;
  end
endmodule
