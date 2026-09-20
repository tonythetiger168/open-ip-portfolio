// SPDX-License-Identifier: Apache-2.0
// Self-checking TB: master drives req flit with credits; checks rsp flit.
`timescale 1ns/1ps
module ARM_Local_Translation_Interface_tb;
  logic clk = 0, rst_n = 0;
  logic [43:0] txreqflit = '0;
  logic        txreqflitv = 0;
  logic        txreqlcrdv;
  logic [33:0] rxrspflit;
  logic        rxrspflitv;
  logic        rxrsplcrdv = 0;
  int errors = 0;

  ARM_Local_Translation_Interface_top dut (
    .clk(clk), .rst_n(rst_n),
    .txreqflit(txreqflit), .txreqflitv(txreqflitv), .txreqlcrdv(txreqlcrdv),
    .rxrspflit(rxrspflit), .rxrspflitv(rxrspflitv), .rxrsplcrdv(rxrsplcrdv),
    .busy(), .irq());

  always #5 clk = ~clk;

  // grant response credits periodically (master side)
  initial begin
    rxrsplcrdv = 0;
    repeat(4) @(posedge clk);
    forever begin
      repeat(8) @(posedge clk);
      rxrsplcrdv <= 1;
      @(posedge clk);
      rxrsplcrdv <= 0;
    end
  end

  task automatic send_req(input logic [11:0] txn, input logic [31:0] addr);
    begin
      // wait for an acceptance credit from the slave
      @(posedge clk);
      while (!txreqlcrdv) @(posedge clk);
      txreqflit  <= {txn, addr};
      txreqflitv <= 1'b1;
      @(posedge clk);
      txreqflitv <= 1'b0;
      txreqflit  <= '0;
    end
  endtask

  task automatic expect_rsp(input logic [11:0] txn, input logic [15:0] data);
    logic [33:0] r;
    begin
      r = '0;
      wait (rxrspflitv === 1'b1);
      @(posedge clk); #1;
      r = rxrspflit;
      if (r[28:17] !== txn) begin
        errors++; $display("ERROR: ARM Local Translation Interface rsp txn got=%h exp=%h", r[28:17], txn);
      end
      if (r[16:1] !== data) begin
        errors++; $display("ERROR: ARM Local Translation Interface rsp data got=%h exp=%h", r[16:1], data);
      end
      if (r[33:29] !== 5'b00001) begin
        errors++; $display("ERROR: ARM Local Translation Interface rsp opcode got=%b", r[33:29]);
      end
    end
  endtask

  initial begin
    rst_n = 0; repeat(10) @(posedge clk);
    rst_n = 1; repeat(20) @(posedge clk);

    send_req(12'hA5A, 32'hDEAD_BEEF);
    expect_rsp(12'hA5A, 16'hBEEF);
    repeat(10) @(posedge clk);
    send_req(12'h123, 32'hCAFE_0001);
    expect_rsp(12'h123, 16'h0001);

    if (errors == 0) $display("TEST PASSED: ARM Local Translation Interface");
    else             $display("TEST FAILED: %0d errors", errors);
    $finish;
  end

  initial begin
    #500_000; $display("TIMEOUT"); $finish;
  end
endmodule
