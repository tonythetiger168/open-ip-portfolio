// SPDX-License-Identifier: Apache-2.0
// Self-checking testbench for WTB_top -- IEEE 802.4 style token-bus station.
// TB plays the predecessor and successor stations on the serial bus:
//   injects token/data/claim frames to rx_bit, decodes frames from tx_bit.
// Checks: reset / token pass-through (empty FIFO) / data frame TX from FIFO
//         with payload+CRC compare (2 token rounds, holding window) /
//         bad-CRC frame dropped + irq / token for other station ignored /
//         claim_token contention after bus idle timeout.
`timescale 1ns/1ps
module WTB_tb;
  localparam int DW = 32, AW = 32;

  localparam logic [7:0] MY = 8'h11;   // DUT station address
  localparam logic [7:0] TB = 8'h00;   // TB predecessor address
  localparam logic [7:0] NS = 8'h22;   // next-station address (programmed)
  localparam logic [7:0] DA = 8'h33;   // data-frame destination (programmed)

  logic clk = 0, rst_n = 0;
  logic        rx_bit;
  logic        tx_bit, tx_en;
  logic [7:0]  my_addr;
  logic        cpu_we;
  logic [1:0]  cpu_addr;
  logic [31:0] cpu_wdata;
  logic [3:0]  fifo_count;
  logic        token_held;
  logic        irq;

  int errors = 0;
  reg [7:0] rxbuf [0:31];   // frame decode buffer (module scope: iverilog)

  WTB_top #(.DW(DW), .AW(AW)) dut (
    .clk(clk), .rst_n(rst_n),
    .rx_bit(rx_bit), .tx_bit(tx_bit), .tx_en(tx_en),
    .my_addr(my_addr),
    .cpu_we(cpu_we), .cpu_addr(cpu_addr), .cpu_wdata(cpu_wdata),
    .fifo_count(fifo_count), .token_held(token_held), .irq(irq)
  );

  always #5 clk = ~clk;

  // ------------------------------------------------------------------
  // CRC16 (poly 0x1021, init 0xFFFF), byte-wise -- same as DUT
  // ------------------------------------------------------------------
  function automatic logic [15:0] crc16_byte(input logic [15:0] crc,
                                             input logic [7:0]  data);
    logic [15:0] c;
    begin
      c = crc ^ {data, 8'h00};
      for (int i = 0; i < 8; i++)
        c = c[15] ? ((c << 1) ^ 16'h1021) : (c << 1);
      return c;
    end
  endfunction

  // ------------------------------------------------------------------
  // serial bus driver (predecessor/successor model)
  // ------------------------------------------------------------------
  task automatic send_byte(input logic [7:0] b);
    for (int i = 7; i >= 0; i--) begin
      @(negedge clk);
      rx_bit <= b[i];
    end
  endtask

  // pay: payload bytes, first byte in pay[127:120]
  task automatic send_frame(input logic [7:0] fc, da, sa,
                            input int plen, input logic [127:0] pay,
                            input logic bad_crc, input logic bad_ed);
    logic [15:0] c;
    begin
      c = 16'hFFFF;
      c = crc16_byte(c, fc);
      c = crc16_byte(c, da);
      c = crc16_byte(c, sa);
      c = crc16_byte(c, plen[7:0]);
      for (int i = 0; i < plen; i++)
        c = crc16_byte(c, pay[127 - 8*i -: 8]);
      if (bad_crc) c = c ^ 16'h00FF;
      send_byte(8'h55);
      send_byte(8'h55);
      send_byte(8'hD5);
      send_byte(fc);
      send_byte(da);
      send_byte(sa);
      send_byte(plen[7:0]);
      for (int i = 0; i < plen; i++) send_byte(pay[127 - 8*i -: 8]);
      send_byte(c[15:8]);
      send_byte(c[7:0]);
      send_byte(bad_ed ? 8'h00 : 8'hD4);
      @(negedge clk); rx_bit <= 1'b1;   // idle bus
    end
  endtask

  // ------------------------------------------------------------------
  // frame decoder on tx_bit; status: 0=ok 1=timeout 2=framing 3=crc
  // ------------------------------------------------------------------
  task automatic recv_frame(output logic [7:0] fc, da, sa, len,
                            output logic [127:0] pay, output int status);
    logic [7:0] cur;
    int n, nb, to;
    logic [15:0] c;
    begin
      status = 0; n = 0; nb = 0; to = 0; cur = 0; pay = '0;
      fc = 'x; da = 'x; sa = 'x; len = 'x;
      // wait for tx_en rise; first data bit is valid in the detection cycle
      while (!tx_en && to < 5000) begin @(posedge clk); to++; end
      if (!tx_en) begin
        status = 1;
      end else begin
        cur = {7'b0, tx_bit};   // bit0 of preamble
        nb  = 1;
        // sample remaining bits at posedge while tx_en
        while (tx_en) begin
          @(posedge clk);
          if (tx_en) begin
            cur = {cur[6:0], tx_bit};
            nb++;
            if (nb == 8) begin
              rxbuf[n] = cur;
              n++;
              nb = 0;
              cur = 0;
            end
          end
        end
        // parse
        if (n < 10 || rxbuf[0] != 8'h55 || rxbuf[1] != 8'h55 ||
            rxbuf[2] != 8'hD5 || rxbuf[n-1] != 8'hD4 || n != 10 + rxbuf[6]) begin
          status = 2;
          $display("ERROR: WTB rx frame framing n=%0d b0=%h b1=%h b2=%h ed=%h",
                   n, rxbuf[0], rxbuf[1], rxbuf[2], rxbuf[n-1]);
        end else begin
          fc  = rxbuf[3];
          da  = rxbuf[4];
          sa  = rxbuf[5];
          len = rxbuf[6];
          for (int i = 0; i < len; i++) pay[127 - 8*i -: 8] = rxbuf[7+i];
          c = 16'hFFFF;
          for (int i = 3; i < 7 + len; i++) c = crc16_byte(c, rxbuf[i]);
          if (c != {rxbuf[7+len], rxbuf[8+len]}) begin
            status = 3;
            $display("ERROR: WTB rx frame CRC got=%h exp=%h",
                     {rxbuf[7+len], rxbuf[8+len]}, c);
          end
        end
      end
    end
  endtask

  task automatic cpu_wr(input logic [1:0] a, input logic [31:0] d);
    begin
      @(negedge clk);
      cpu_we <= 1'b1; cpu_addr <= a; cpu_wdata <= d;
      @(negedge clk);
      cpu_we <= 1'b0;
    end
  endtask

  // expect a specific frame; on mismatch count errors
  task automatic expect_frame(input logic [7:0] efc, eda, esa, elen,
                              input logic [127:0] epay, input string tag);
    logic [7:0] fc, da, sa, len;
    logic [127:0] pay;
    int status;
    begin
      recv_frame(fc, da, sa, len, pay, status);
      if (status != 0) begin
        errors++;
        $display("ERROR: WTB %s: no/bad frame status=%0d", tag, status);
      end else begin
        if (fc !== efc || da !== eda || sa !== esa || len !== elen) begin
          errors++;
          $display("ERROR: WTB %s: hdr fc=%h da=%h sa=%h len=%h exp fc=%h da=%h sa=%h len=%h",
                   tag, fc, da, sa, len, efc, eda, esa, elen);
        end
        if (elen > 0 && pay !== epay) begin
          errors++;
          $display("ERROR: WTB %s: payload=%h exp=%h", tag, pay, epay);
        end
      end
    end
  endtask

  // ------------------------------------------------------------------
  // test sequence
  // ------------------------------------------------------------------
  logic [127:0] p;

  initial begin
    rx_bit = 1'b1; my_addr = MY;
    cpu_we = 0; cpu_addr = 0; cpu_wdata = 0;
    rst_n = 0; repeat (4) @(posedge clk);

    // CHECK 1: reset state
    if (tx_en !== 1'b0 || irq !== 1'b0 || token_held !== 1'b0 ||
        fifo_count !== 4'd0) begin
      errors++;
      $display("ERROR: WTB reset state tx_en=%b irq=%b held=%b cnt=%0d",
               tx_en, irq, token_held, fifo_count);
    end
    rst_n = 1; repeat (2) @(posedge clk);

    // configure NS + data DA
    cpu_wr(2'd1, 32'h22);
    cpu_wr(2'd2, 32'h33);

    // CHECK 2: empty FIFO - token in, token passed to NS
    send_frame(8'h01, MY, TB, 0, '0, 1'b0, 1'b0);
    expect_frame(8'h01, NS, MY, 8'd0, '0, "empty token pass");

    // CHECK 3: queue 3 words -> 2 token rounds (holding window <=200 clk)
    cpu_wr(2'd0, 32'hAABB_CC01);
    cpu_wr(2'd0, 32'hAABB_CC02);
    cpu_wr(2'd0, 32'hAABB_CC03);
    if (fifo_count !== 4'd3) begin
      errors++;
      $display("ERROR: WTB fifo_count=%0d exp 3", fifo_count);
    end
    send_frame(8'h01, MY, TB, 0, '0, 1'b0, 1'b0);
    p = {32'hAABB_CC01, 96'h0};
    expect_frame(8'h02, DA, MY, 8'd4, p, "data frame 1");
    p = {32'hAABB_CC02, 96'h0};
    expect_frame(8'h02, DA, MY, 8'd4, p, "data frame 2");
    expect_frame(8'h01, NS, MY, 8'd0, '0, "token after window");
    // second round delivers remaining word
    send_frame(8'h01, MY, TB, 0, '0, 1'b0, 1'b0);
    p = {32'hAABB_CC03, 96'h0};
    expect_frame(8'h02, DA, MY, 8'd4, p, "data frame 3");
    expect_frame(8'h01, NS, MY, 8'd0, '0, "token after round 2");
    if (fifo_count !== 4'd0) begin
      errors++;
      $display("ERROR: WTB fifo not empty after rounds cnt=%0d", fifo_count);
    end

    // CHECK 4: error injection - corrupted CRC token must be dropped + irq
    begin
      logic irq_seen, tx_seen;
      irq_seen = 0; tx_seen = 0;
      fork
        begin
          repeat (500) begin
            @(posedge clk);
            if (irq)   irq_seen = 1;
            if (tx_en) tx_seen = 1;
          end
        end
        begin
          send_frame(8'h01, MY, TB, 0, '0, 1'b1, 1'b0);  // bad CRC
        end
      join
      if (!irq_seen) begin
        errors++;
        $display("ERROR: WTB bad-CRC frame: no irq pulse");
      end
      if (tx_seen) begin
        errors++;
        $display("ERROR: WTB bad-CRC frame: station responded to bad token");
      end
    end

    // CHECK 5: token for another station is ignored
    begin
      logic tx_seen;
      tx_seen = 0;
      fork
        begin
          repeat (300) begin
            @(posedge clk);
            if (tx_en) tx_seen = 1;
          end
        end
        begin
          send_frame(8'h01, 8'h55, TB, 0, '0, 1'b0, 1'b0);
        end
      join
      if (tx_seen) begin
        errors++;
        $display("ERROR: WTB token for other station was accepted");
      end
    end

    // recovery: valid token still works
    send_frame(8'h01, MY, TB, 0, '0, 1'b0, 1'b0);
    expect_frame(8'h01, NS, MY, 8'd0, '0, "token pass after bad frames");

    // CHECK 6: claim_token contention after bus idle timeout
    cpu_wr(2'd3, 32'h1);   // claim_en
    expect_frame(8'h00, 8'hFF, MY, 8'd0, '0, "claim_token");
    // no contender replies -> self-elect -> empty FIFO -> pass token to NS
    expect_frame(8'h01, NS, MY, 8'd0, '0, "self-elect token pass");
    cpu_wr(2'd3, 32'h0);   // stop claiming

    repeat (10) @(posedge clk);
    if (errors == 0) $display("TEST PASSED: WTB");
    else             $display("TEST FAILED: %0d errors", errors);
    $finish;
  end

  initial begin
    #2_000_000;
    $display("TIMEOUT");
    $display("TEST FAILED: %0d errors", errors + 1);
    $finish;
  end
endmodule
