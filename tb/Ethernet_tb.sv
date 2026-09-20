// SPDX-License-Identifier: Apache-2.0
// PCIe TB: host sends TLP, device echoes, host verifies payload.
`timescale 1ns/1ps
module Ethernet_tb;
  localparam int BIT = 400;
  localparam int HB  = 8;
  logic clk = 0, rst_n = 0;
  logic host_val = 1'b1, host_oe = 1'b0;
  tri1  rx, tx;
  int errors = 0;

  Ethernet_top #(.BAUD_DIV(20)) dut (
    .clk(clk), .rst_n(rst_n), .refclk(clk), .rx(rx), .tx(tx), .busy(), .irq());
  always #5 clk = ~clk;
  assign rx = host_oe ? host_val : tx;

  function automatic logic [31:0] crc32(input logic [31:0] c, input logic b);
    logic fb; begin fb=c[0]^b; crc32=c>>1; if(fb) crc32=crc32^32'hEDB88320; end
  endfunction

  logic [7:0] hdr [0:7];
  logic [7:0] pl  [0:7];
  task automatic send_tlp(input int plen);
    logic [31:0] c; logic [7:0] fb;
    begin
      host_oe = 1; host_val = 1'b0; #(BIT);
      fb = 8'hFB; for (int i=0;i<8;i++) begin host_val=fb[0]; fb=fb>>1; #(BIT); end
      fb = HB + plen; for (int i=0;i<8;i++) begin host_val=fb[0]; fb=fb>>1; #(BIT); end
      c = 32'hFFFFFFFF;
      for (int i=0;i<HB;i++) begin
        fb = hdr[i];
        for (int j=0;j<8;j++) begin host_val=fb[0]; c=crc32(c,fb[0]); fb=fb>>1; #(BIT); end
      end
      for (int i=0;i<plen;i++) begin
        fb = pl[i];
        for (int j=0;j<8;j++) begin host_val=fb[0]; c=crc32(c,fb[0]); fb=fb>>1; #(BIT); end
      end
      c = ~c;
      for (int i=0;i<32;i++) begin host_val=c[0]; c=c>>1; #(BIT); end
      fb = 8'hFD; for (int i=0;i<8;i++) begin host_val=fb[0]; fb=fb>>1; #(BIT); end
      host_oe = 0;
    end
  endtask

  logic b; logic [7:0] sh;
  task automatic recv_tlp(output int plen);
    begin
      plen = 0; sh = 0;
      wait (tx === 1'b0);
      #(BIT + BIT/2);
      for (int i=0;i<8;i++) begin b=tx; sh={b,sh[7:1]}; #(BIT); end
      sh = 0;
      for (int i=0;i<8;i++) begin b=tx; sh={b,sh[7:1]}; if(i==7) plen = sh - HB; #(BIT); end
      for (int i=0;i<HB+plen;i++) begin
        sh = 0;
        for (int j=0;j<8;j++) begin
          b = tx; sh = {b, sh[7:1]};
          if (j == 7) begin
            if (i < HB) hdr[i] = sh;
            else        pl[i-HB] = sh;
          end
          #(BIT);
        end
      end
      #(BIT*40);
    end
  endtask

  int rlen;
  initial begin
    for (int i=0;i<8;i++) begin hdr[i] = 8'h10 + i; pl[i] = 8'hA0 + i * 8'h11; end
    rst_n = 0; repeat(10) @(posedge clk);
    rst_n = 1; repeat(20) @(posedge clk);
    send_tlp(4);
    recv_tlp(rlen);
    if (rlen !== 4) begin errors++; $display("ERROR: Ethernet plen got=%0d exp=4", rlen); end
    for (int i=0;i<4;i++) begin
      if (pl[i] !== 8'hA0 + i * 8'h11) begin
        errors++; $display("ERROR: Ethernet pl[%0d] got=%h exp=%h", i, pl[i], 8'hA0 + i*8'h11);
      end
    end
    if (dut.rx_err !== 1'b0) begin errors++; $display("ERROR: Ethernet rx_err set"); end
    if (errors == 0) $display("TEST PASSED: Ethernet");
    else             $display("TEST FAILED: %0d errors", errors);
    $finish;
  end
  initial begin #10_000_000; $display("TIMEOUT"); $finish; end
endmodule
