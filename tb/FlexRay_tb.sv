// SPDX-License-Identifier: Apache-2.0
// Self-checking testbench: CAN loopback (rxd = txd) -- SystemVerilog
`timescale 1ns/1ps
module FlexRay_tb;
  logic clk = 0, rst_n = 0;
  logic rxd, txd;
  logic wen = 0, ren = 0;
  logic [3:0] waddr = 0, raddr = 0;
  logic [7:0] wdata = 0, rdata;
  int errors = 0;

  FlexRay_top #(.BAUD_DIV(20)) dut (
    .clk(clk), .rst_n(rst_n), .rxd(rxd), .txd(txd),
    .wen(wen), .waddr(waddr), .wdata(wdata),
    .ren(ren), .raddr(raddr), .rdata(rdata), .irq());

  always #5 clk = ~clk;
  assign rxd = txd;                          // loopback

  task automatic wr(input logic [3:0] a, input logic [7:0] d);
    begin
      @(negedge clk); wen <= 1'b1; waddr <= a; wdata <= d;
      @(negedge clk); wen <= 1'b0;
    end
  endtask
  task automatic rd(input logic [3:0] a, output logic [7:0] d);
    begin
      @(negedge clk); ren <= 1'b1; raddr <= a;
      #1 d = rdata;
      @(negedge clk); ren <= 1'b0;
    end
  endtask

  logic [7:0] idl, hdr, b0, b1, b2, b3, st;
  task automatic check_frame(input logic [10:0] id, input logic [3:0] dlc,
                             input logic [7:0] d0, input logic [7:0] d1,
                             input logic [7:0] d2, input logic [7:0] d3);
    begin
      wr(4'd0, id[7:0]);
      wr(4'd1, {id[10:8], 1'b0, dlc});
      wr(4'd2, d0); wr(4'd3, d1); wr(4'd4, d2); wr(4'd5, d3);
      wr(4'd10, 8'h01);
      wait (dut.rx_valid === 1'b1);
      @(posedge clk); #1;
      rd(4'd0, idl); rd(4'd1, hdr);
      rd(4'd2, b0); rd(4'd3, b1); rd(4'd4, b2); rd(4'd5, b3);
      rd(4'd10, st);
      if ({hdr[7:5], idl} !== id) begin
        errors++; $display("ERROR: FlexRay id got=%h_%h exp=%h", hdr[7:5], idl, id);
      end
      if (hdr[3:0] !== dlc) begin errors++; $display("ERROR: FlexRay dlc got=%0d exp=%0d", hdr[3:0], dlc); end
      if (dlc >= 1 && b0 !== d0) begin errors++; $display("ERROR: FlexRay b0 got=%h exp=%h", b0, d0); end
      if (dlc >= 2 && b1 !== d1) begin errors++; $display("ERROR: FlexRay b1 got=%h exp=%h", b1, d1); end
      if (dlc >= 3 && b2 !== d2) begin errors++; $display("ERROR: FlexRay b2 got=%h exp=%h", b2, d2); end
      if (dlc >= 4 && b3 !== d3) begin errors++; $display("ERROR: FlexRay b3 got=%h exp=%h", b3, d3); end
      if (st[5] !== 1'b0) begin errors++; $display("ERROR: FlexRay rx_err set (st=%h)", st); end
      repeat (50) @(posedge clk);          // inter-frame gap
    end
  endtask

  initial begin
    rst_n = 0; repeat(10) @(posedge clk);
    rst_n = 1; repeat(20) @(posedge clk);

    check_frame(11'h1AB, 4'd4, 8'h55, 8'hAA, 8'h0F, 8'hF0);  // stuffing-heavy
    check_frame(11'h055, 4'd0, 8'h00, 8'h00, 8'h00, 8'h00);  // dataless
    check_frame(11'h7FF, 4'd2, 8'hFF, 8'hFF, 8'h00, 8'h00);  // worst-case stuff

    if (errors == 0) $display("TEST PASSED: FlexRay");
    else             $display("TEST FAILED: %0d errors", errors);
    $finish;
  end

  initial begin
    #8_000_000; $display("TIMEOUT"); $finish;
  end
endmodule
