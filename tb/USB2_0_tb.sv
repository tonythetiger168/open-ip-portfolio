// SPDX-License-Identifier: Apache-2.0
// Self-checking testbench: host bit-bangs USB FS packets; device echoes.
`timescale 1ns/1ps
module USB2_0_tb;
  localparam int BIT = 400;
  logic clk = 0, rst_n = 0;
  tri1 dp, dm;
  logic h_oe = 0, h_dp = 1, h_dm = 0;
  int errors = 0;

  USB2_0_top #(.BAUD_DIV(20)) dut (
    .clk(clk), .rst_n(rst_n), .dp(dp), .dm(dm), .busy(), .irq());

  always #5 clk = ~clk;
  assign dp = h_oe ? h_dp : 1'bz;
  assign dm = h_oe ? h_dm : 1'bz;

  logic hl = 1;
  logic [3:0] hrun = 0;
  task automatic h_bit(input logic b);
    begin
      if (!b) hl = ~hl;
      h_oe = 1; h_dp = hl; h_dm = ~hl;
      #(BIT);
    end
  endtask
  task automatic h_bit_stuffed(input logic b);
    begin
      if (hrun == 6) begin h_bit(1'b0); hrun = 1; end
      h_bit(b);
      if (b) hrun = hrun + 1; else hrun = 1;
    end
  endtask

  function automatic logic [15:0] crc(input logic [15:0] cc, input logic b);
    logic fb;
    begin
      fb = cc[0] ^ b;
      crc = cc >> 1;
      if (fb) crc = crc ^ 16'h8005;
    end
  endfunction

  logic [7:0] txp [0:7];
  logic [7:0] rxp [0:7];
  logic [7:0] sync_b, pid_b, pl_b;
  task automatic host_send_data(input logic [3:0] pid, input int len);
    logic [15:0] c;
    begin
      hrun = 0;
      sync_b = 8'h80;
      pid_b  = {~pid, pid};
      for (int i = 0; i < 8; i++) h_bit(sync_b[i]);
      for (int i = 0; i < 8; i++) h_bit_stuffed(pid_b[i]);
      c = 16'hFFFF;
      for (int i = 0; i < len; i++) begin
        pl_b = txp[i];
        for (int j = 0; j < 8; j++) begin
          h_bit_stuffed(pl_b[j]);
          c = crc(c, pl_b[j]);
        end
      end
      c = ~c;
      for (int i = 0; i < 16; i++) h_bit_stuffed(c[i]);
      h_oe = 1; h_dp = 0; h_dm = 0; #(BIT*2);
      hl = 1; h_dp = 1; h_dm = 0; #(BIT);
      h_oe = 0;
    end
  endtask

  task automatic host_recv(output logic [3:0] pid, output int len);
    logic prev, b;
    logic [7:0] sh;
    int n;
    logic [3:0] run;
    begin
      len = 0; pid = 0; n = 0; sh = 0; run = 0;
      wait (dp === 1'b0 && dm === 1'b1);
      #(BIT/2);
      prev = 1'b1;
      for (int i = 0; i < 8; i++) begin
        b = ((dp === 1'b1) == prev);
        prev = (dp === 1'b1);
        #(BIT);
      end
      while (!(dp === 1'b0 && dm === 1'b0)) begin
        b = ((dp === 1'b1) == prev);
        prev = (dp === 1'b1);
        if (run == 6) begin
          run = 1;
        end else begin
          if (b) run = run + 1; else run = 1;
          sh = {b, sh[7:1]};
          if (n % 8 == 7) begin
            if (n / 8 == 0) pid = sh[3:0];
            else if (n/8 <= 8) rxp[(n/8)-1] = sh;
          end
          n = n + 1;
        end
        #(BIT);
      end
      #(BIT*3);
      len = (n / 8) - 3;  // minus PID(1) + CRC16(2) bytes
    end
  endtask

  logic [3:0] rpid;
  int rlen;
  initial begin
    for (int i = 0; i < 8; i++) txp[i] = 8'hA0 + i * 8'h11;
    rst_n = 0; repeat(10) @(posedge clk);
    rst_n = 1; repeat(20) @(posedge clk);

    host_send_data(4'h3, 4);
    host_recv(rpid, rlen);
    if (rpid !== 4'h3) begin errors++; $display("ERROR: USB pid got=%h exp=3", rpid); end
    if (rlen !== 4) begin errors++; $display("ERROR: USB len got=%0d exp=4", rlen); end
    for (int i = 0; i < 4; i++) begin
      if (rxp[i] !== txp[i]) begin errors++; $display("ERROR: USB b%0d got=%h exp=%h", i, rxp[i], txp[i]); end
    end
    if (dut.rx_err !== 1'b0) begin errors++; $display("ERROR: USB rx_err set"); end

    repeat (50) @(posedge clk);

    txp[0] = 8'hFF;
    host_send_data(4'hB, 1);
    host_recv(rpid, rlen);
    if (rpid !== 4'hB) begin errors++; $display("ERROR: USB pid2 got=%h exp=B", rpid); end
    if (rlen !== 1) begin errors++; $display("ERROR: USB len2 got=%0d exp=1", rlen); end
    if (rxp[0] !== 8'hFF) begin errors++; $display("ERROR: USB b0 got=%h exp=FF", rxp[0]); end
    if (dut.rx_err !== 1'b0) begin errors++; $display("ERROR: USB rx_err2 set"); end

    if (errors == 0) $display("TEST PASSED: USB2.0");
    else             $display("TEST FAILED: %0d errors", errors);
    $finish;
  end

  initial begin
    #10_000_000; $display("TIMEOUT"); $finish;
  end
endmodule
