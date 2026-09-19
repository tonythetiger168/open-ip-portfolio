// SPDX-License-Identifier: Apache-2.0
// Self-checking testbench for eCPRI_over_Ethernet_top -- eCPRI message layer.
// TB plays the Ethernet peer: builds full frames (DMAC/SMAC/0xAEFE/eCPRI
// header/payload/FCS CRC32) byte-streamed to the DUT, and captures/parses DUT
// TX frames with independent CRC re-computation.
// Checks: reset / msgtype0 IQ data -> 32x32 buffer pop compare + seq_id gap /
// msgtype4 memory write + read response frame full byte compare (FCS incl.) /
// msgtype5 remote reset -> reset_op + response frame / msgtype6 event with
// ack_req -> ACK frame, event without ack_req -> silence / cpu fault inject ->
// event indication frame / FCS corruption -> drop + irq / unknown msgtype ->
// drop + irq / irq clear / back-to-back frames.
`timescale 1ns/1ps
module eCPRI_over_Ethernet_tb;
  localparam int DW = 32, AW = 32;
  localparam logic [47:0] DUT_DMAC = 48'hAABB_CCDD_EEFF;
  localparam logic [47:0] DUT_SMAC = 48'h1122_3344_5566;
  localparam logic [47:0] PEER_MAC = 48'h9988_7766_5544;

  logic clk = 0, rst_n = 0;
  logic [7:0]  rx_d;
  logic        rx_dv;
  logic [7:0]  tx_d;
  logic        tx_en;
  logic [15:0] reset_op;
  logic        cpu_we, cpu_re;
  logic [3:0]  cpu_addr;
  logic [31:0] cpu_wdata, cpu_rdata;
  logic        irq;

  int errors = 0;

  eCPRI_over_Ethernet_top #(.DW(DW), .AW(AW)) dut (
    .clk(clk), .rst_n(rst_n),
    .rx_d(rx_d), .rx_dv(rx_dv), .tx_d(tx_d), .tx_en(tx_en),
    .reset_op(reset_op),
    .cpu_we(cpu_we), .cpu_re(cpu_re), .cpu_addr(cpu_addr),
    .cpu_wdata(cpu_wdata), .cpu_rdata(cpu_rdata), .irq(irq)
  );

  always #5 clk = ~clk;

  // ------------------------------------------------------------------
  // CRC-32/ISO-HDLC (reflected), independent copy
  // ------------------------------------------------------------------
  function automatic logic [31:0] crc32_byte(input logic [31:0] crc,
                                             input logic [7:0]  d);
    logic [31:0] c;
    begin
      c = crc ^ {24'h0, d};
      for (int i = 0; i < 8; i++)
        c = c[0] ? ((c >> 1) ^ 32'hEDB88320) : (c >> 1);
      crc32_byte = c;
    end
  endfunction

  // ------------------------------------------------------------------
  // frame buffers / tasks
  // ------------------------------------------------------------------
  logic [7:0] pay  [0:63];     // payload staging
  logic [7:0] fbuf [0:255];    // full frame staging
  logic [7:0] exp  [0:255];    // expected tx frame
  int         explen;

  // send one eCPRI frame; payload preloaded in pay[0:plen-1]
  task automatic send_msg(input logic [7:0] mt, input int plen,
                          input bit bad_fcs);
    logic [31:0] crc, fcs;
    int i, n;
    begin
      fbuf[0]  = DUT_DMAC[47:40]; fbuf[1]  = DUT_DMAC[39:32];
      fbuf[2]  = DUT_DMAC[31:24]; fbuf[3]  = DUT_DMAC[23:16];
      fbuf[4]  = DUT_DMAC[15:8];  fbuf[5]  = DUT_DMAC[7:0];
      fbuf[6]  = PEER_MAC[47:40]; fbuf[7]  = PEER_MAC[39:32];
      fbuf[8]  = PEER_MAC[31:24]; fbuf[9]  = PEER_MAC[23:16];
      fbuf[10] = PEER_MAC[15:8];  fbuf[11] = PEER_MAC[7:0];
      fbuf[12] = 8'hAE;           fbuf[13] = 8'hFE;
      fbuf[14] = 8'h10;           fbuf[15] = mt;
      fbuf[16] = plen[15:8];      fbuf[17] = plen[7:0];
      for (i = 0; i < plen; i++) fbuf[18+i] = pay[i];
      crc = 32'hFFFF_FFFF;
      for (i = 0; i < 18 + plen; i++) crc = crc32_byte(crc, fbuf[i]);
      fcs = ~crc;
      if (bad_fcs) fcs = fcs ^ 32'h1;
      n = 18 + plen;
      fbuf[n]   = fcs[7:0];
      fbuf[n+1] = fcs[15:8];
      fbuf[n+2] = fcs[23:16];
      fbuf[n+3] = fcs[31:24];
      for (i = 0; i < n + 4; i++) begin
        @(negedge clk);
        rx_dv = 1'b1;
        rx_d  = fbuf[i];
      end
      @(negedge clk);
      rx_dv = 1'b0;
      rx_d  = 8'h00;
      repeat (4) @(negedge clk);
    end
  endtask

  // build expected DUT tx frame (uses DUT cfg macs) into exp[]
  task automatic build_exp(input logic [7:0] mt, input int plen);
    logic [31:0] crc, fcs;
    int i, n;
    begin
      exp[0]  = DUT_DMAC[47:40]; exp[1]  = DUT_DMAC[39:32];
      exp[2]  = DUT_DMAC[31:24]; exp[3]  = DUT_DMAC[23:16];
      exp[4]  = DUT_DMAC[15:8];  exp[5]  = DUT_DMAC[7:0];
      exp[6]  = DUT_SMAC[47:40]; exp[7]  = DUT_SMAC[39:32];
      exp[8]  = DUT_SMAC[31:24]; exp[9]  = DUT_SMAC[23:16];
      exp[10] = DUT_SMAC[15:8];  exp[11] = DUT_SMAC[7:0];
      exp[12] = 8'hAE;           exp[13] = 8'hFE;
      exp[14] = 8'h10;           exp[15] = mt;
      exp[16] = plen[15:8];      exp[17] = plen[7:0];
      for (i = 0; i < plen; i++) exp[18+i] = pay[i];
      crc = 32'hFFFF_FFFF;
      for (i = 0; i < 18 + plen; i++) crc = crc32_byte(crc, exp[i]);
      fcs = ~crc;
      n = 18 + plen;
      exp[n]   = fcs[7:0];
      exp[n+1] = fcs[15:8];
      exp[n+2] = fcs[23:16];
      exp[n+3] = fcs[31:24];
      explen = n + 4;
    end
  endtask

  // ------------------------------------------------------------------
  // TX frame monitor
  // ------------------------------------------------------------------
  int         capn;
  logic [7:0] cap [0:255];
  bit         frm_rdy;

  initial begin capn = 0; frm_rdy = 0; end

  always @(posedge clk) begin
    if (tx_en) begin
      if (frm_rdy) begin frm_rdy = 0; capn = 0; end
      cap[capn] = tx_d;
      capn = capn + 1;
    end else if (capn > 0) begin
      frm_rdy = 1;
    end
  end

  // wait for a complete DUT tx frame and compare against exp[]
  task automatic check_tx(input logic [7:0] mt, input int plen,
                          input string tag);
    int i, t;
    begin
      build_exp(mt, plen);
      t = 0;
      while (!frm_rdy && t < 400) begin @(negedge clk); t = t + 1; end
      if (!frm_rdy) begin
        errors++;
        $display("ERROR: eCPRI %s: no tx frame within 400 clk", tag);
      end else begin
        if (capn !== explen) begin
          errors++;
          $display("ERROR: eCPRI %s: tx len = %0d exp %0d", tag, capn, explen);
        end else begin
          for (i = 0; i < explen; i++) begin
            if (cap[i] !== exp[i]) begin
              errors++;
              $display("ERROR: eCPRI %s: tx[%0d] = %h exp %h", tag, i, cap[i], exp[i]);
            end
          end
        end
        frm_rdy = 0;
        capn = 0;
      end
    end
  endtask

  // check the DUT stays silent for n cycles
  task automatic check_no_tx(input int ncyc, input string tag);
    int t;
    begin
      t = 0;
      while (t < ncyc) begin
        @(negedge clk);
        if (tx_en || frm_rdy) begin
          errors++;
          $display("ERROR: eCPRI %s: unexpected tx activity @%0d", tag, t);
          t = ncyc;
        end
        t = t + 1;
      end
    end
  endtask

  // ------------------------------------------------------------------
  // cpu port helpers
  // ------------------------------------------------------------------
  task automatic cpu_wr(input logic [3:0] a, input logic [31:0] d);
    begin
      @(negedge clk);
      cpu_we = 1; cpu_addr = a; cpu_wdata = d;
      @(negedge clk);
      cpu_we = 0;
    end
  endtask

  task automatic cpu_rd(input logic [3:0] a, output logic [31:0] d);
    begin
      @(negedge clk);
      cpu_re = 1; cpu_addr = a;
      #1 d = cpu_rdata;
      @(negedge clk);
      cpu_re = 0;
    end
  endtask

  // ------------------------------------------------------------------
  // TIMEOUT guard
  // ------------------------------------------------------------------
  initial begin
    #2000000;
    $display("ERROR: eCPRI TB TIMEOUT");
    $display("TEST FAILED: %0d errors", errors + 1);
    $finish;
  end

  // ------------------------------------------------------------------
  // main test sequence
  // ------------------------------------------------------------------
  logic [31:0] rd;
  int          i;

  initial begin
    cpu_we = 0; cpu_re = 0; cpu_addr = 0; cpu_wdata = 0;
    rx_dv = 0; rx_d = 0;
    repeat (4) @(negedge clk);
    rst_n = 1;
    repeat (4) @(negedge clk);

    // CHECK 1: reset state
    cpu_rd(4'd5, rd);
    if (rd !== 32'h0) begin
      errors++; $display("ERROR: eCPRI status after reset = %h exp 0", rd);
    end
    if (irq !== 1'b0 || tx_en !== 1'b0 || reset_op !== 16'h0) begin
      errors++; $display("ERROR: eCPRI outputs after reset: irq=%b tx_en=%b reset_op=%h",
                         irq, tx_en, reset_op);
    end
    cpu_rd(4'd0, rd);
    if (rd !== 32'hCCDD_EEFF) begin
      errors++; $display("ERROR: eCPRI default dmac_lo = %h", rd);
    end

    // CHECK 2: msgtype 0 IQ data (pc=1, seq=0, 8B -> 2 words) + pop compare
    pay[0]=8'h00; pay[1]=8'h01; pay[2]=8'h00; pay[3]=8'h00;
    pay[4]=8'h10; pay[5]=8'h11; pay[6]=8'h12; pay[7]=8'h13;
    pay[8]=8'h20; pay[9]=8'h21; pay[10]=8'h22; pay[11]=8'h23;
    send_msg(8'd0, 12, 1'b0);
    cpu_rd(4'd5, rd);
    if (rd[5:0] !== 6'd2) begin
      errors++; $display("ERROR: eCPRI iq_cnt = %0d exp 2", rd[5:0]);
    end
    cpu_rd(4'd4, rd);
    if (rd !== 32'h1011_1213) begin
      errors++; $display("ERROR: eCPRI iq[0] = %h exp 10111213", rd);
    end
    cpu_rd(4'd4, rd);
    if (rd !== 32'h2021_2223) begin
      errors++; $display("ERROR: eCPRI iq[1] = %h exp 20212223", rd);
    end
    // second IQ frame, seq=1 (in order): no gap
    pay[0]=8'h00; pay[1]=8'h01; pay[2]=8'h00; pay[3]=8'h01;
    pay[4]=8'hAA; pay[5]=8'hBB; pay[6]=8'hCC; pay[7]=8'hDD;
    send_msg(8'd0, 8, 1'b0);
    cpu_rd(4'd4, rd);
    if (rd !== 32'hAABB_CCDD) begin
      errors++; $display("ERROR: eCPRI iq[2] = %h exp AABBCCDD", rd);
    end
    cpu_rd(4'd5, rd);
    if (rd[15:8] !== 8'd0) begin
      errors++; $display("ERROR: eCPRI seq_gap after in-order seq = %0d exp 0", rd[15:8]);
    end
    cpu_rd(4'd6, rd);
    if (rd !== 32'h0001_0001) begin
      errors++; $display("ERROR: eCPRI last pc/seq = %h exp 00010001", rd);
    end
    // third IQ frame, seq=4 (gap): gap counter must increment
    pay[0]=8'h00; pay[1]=8'h01; pay[2]=8'h00; pay[3]=8'h04;
    pay[4]=8'h55; pay[5]=8'h66; pay[6]=8'h77; pay[7]=8'h88;
    send_msg(8'd0, 8, 1'b0);
    cpu_rd(4'd5, rd);
    if (rd[15:8] !== 8'd1) begin
      errors++; $display("ERROR: eCPRI seq_gap after skipped seq = %0d exp 1", rd[15:8]);
    end
    cpu_rd(4'd4, rd);
    if (rd !== 32'h5566_7788) begin
      errors++; $display("ERROR: eCPRI iq[3] = %h exp 55667788", rd);
    end

    // CHECK 3: msgtype 4 memory write then read -> response frame compare
    pay[0]=8'h00; pay[1]=8'h00; pay[2]=8'h00; pay[3]=8'h10;  // addr 0x10
    pay[4]=8'h01;                                            // write
    pay[5]=8'hDE; pay[6]=8'hAD; pay[7]=8'hBE; pay[8]=8'hEF;
    send_msg(8'd4, 9, 1'b0);
    pay[0]=8'h00; pay[1]=8'h00; pay[2]=8'h00; pay[3]=8'h10;
    pay[4]=8'h00;                                            // read
    send_msg(8'd4, 5, 1'b0);
    pay[0]=8'h00; pay[1]=8'h00; pay[2]=8'h00; pay[3]=8'h10;
    pay[4]=8'h02;                                            // read response
    pay[5]=8'hDE; pay[6]=8'hAD; pay[7]=8'hBE; pay[8]=8'hEF;
    check_tx(8'd4, 9, "mem read resp");
    // back-to-back: second write + read at another address
    pay[0]=8'h00; pay[1]=8'h00; pay[2]=8'h00; pay[3]=8'h24;
    pay[4]=8'h01;
    pay[5]=8'h01; pay[6]=8'h02; pay[7]=8'h03; pay[8]=8'h04;
    send_msg(8'd4, 9, 1'b0);
    pay[0]=8'h00; pay[1]=8'h00; pay[2]=8'h00; pay[3]=8'h24;
    pay[4]=8'h00;
    send_msg(8'd4, 5, 1'b0);
    pay[0]=8'h00; pay[1]=8'h00; pay[2]=8'h00; pay[3]=8'h24;
    pay[4]=8'h02;
    pay[5]=8'h01; pay[6]=8'h02; pay[7]=8'h03; pay[8]=8'h04;
    check_tx(8'd4, 9, "mem read resp #2");

    // CHECK 4: msgtype 5 remote reset request -> reset_op + response
    pay[0]=8'h00; pay[1]=8'h03;
    send_msg(8'd5, 2, 1'b0);
    repeat (2) @(negedge clk);
    if (reset_op !== 16'h0003) begin
      errors++; $display("ERROR: eCPRI reset_op = %h exp 0003", reset_op);
    end
    pay[0]=8'h00; pay[1]=8'h03;
    check_tx(8'd5, 2, "reset resp");
    cpu_wr(4'd9, 32'h1);                                     // cpu clears reset_op
    repeat (2) @(negedge clk);
    if (reset_op !== 16'h0000) begin
      errors++; $display("ERROR: eCPRI reset_op not cleared = %h", reset_op);
    end

    // CHECK 5: msgtype 6 event indication with ack_req -> ACK frame
    pay[0]=8'h42; pay[1]=8'h01;
    send_msg(8'd6, 2, 1'b0);
    pay[0]=8'h42; pay[1]=8'h01;
    check_tx(8'd6, 2, "event ack");
    cpu_rd(4'd7, rd);
    if (rd[7:0] !== 8'h42) begin
      errors++; $display("ERROR: eCPRI last_event = %h exp 42", rd[7:0]);
    end
    // event without ack_req -> no response
    pay[0]=8'h43; pay[1]=8'h00;
    send_msg(8'd6, 2, 1'b0);
    check_no_tx(120, "event no-ack");
    // cpu fault injection -> DUT emits event indication
    cpu_wr(4'd7, 32'h77);
    pay[0]=8'h77; pay[1]=8'h01;
    check_tx(8'd6, 2, "fault event ind");

    // CHECK 6: FCS corruption -> frame dropped + irq, then clear
    pay[0]=8'h00; pay[1]=8'h01; pay[2]=8'h00; pay[3]=8'h05;
    pay[4]=8'h99; pay[5]=8'h99; pay[6]=8'h99; pay[7]=8'h99;
    send_msg(8'd0, 8, 1'b1);                                 // bad FCS
    repeat (4) @(negedge clk);
    if (irq !== 1'b1) begin
      errors++; $display("ERROR: eCPRI no irq after bad FCS");
    end
    cpu_rd(4'd8, rd);
    if (rd[0] !== 1'b1) begin
      errors++; $display("ERROR: eCPRI irq_fcs bit not set (%h)", rd);
    end
    cpu_rd(4'd5, rd);
    if (rd[5:0] !== 6'd0) begin
      errors++; $display("ERROR: eCPRI bad-FCS frame reached IQ buffer (%0d)", rd[5:0]);
    end
    if (rd[31:24] !== 8'd1) begin
      errors++; $display("ERROR: eCPRI rx_err_cnt = %0d exp 1", rd[31:24]);
    end
    cpu_wr(4'd8, 32'h1);
    repeat (2) @(negedge clk);
    if (irq !== 1'b0) begin
      errors++; $display("ERROR: eCPRI irq_fcs not cleared");
    end

    // CHECK 7: unknown msgtype -> drop + irq, no response frame
    pay[0]=8'h00; pay[1]=8'h00;
    send_msg(8'd9, 2, 1'b0);
    repeat (4) @(negedge clk);
    if (irq !== 1'b1) begin
      errors++; $display("ERROR: eCPRI no irq after unknown msgtype");
    end
    cpu_rd(4'd8, rd);
    if (rd[1] !== 1'b1) begin
      errors++; $display("ERROR: eCPRI irq_type bit not set (%h)", rd);
    end
    cpu_wr(4'd8, 32'h2);
    repeat (2) @(negedge clk);
    if (irq !== 1'b0) begin
      errors++; $display("ERROR: eCPRI irq_type not cleared");
    end
    check_no_tx(120, "unknown msgtype");

    // CHECK 8: post-error recovery -- normal IQ frame still works
    pay[0]=8'h00; pay[1]=8'h01; pay[2]=8'h00; pay[3]=8'h05;
    pay[4]=8'hC0; pay[5]=8'hC1; pay[6]=8'hC2; pay[7]=8'hC3;
    send_msg(8'd0, 8, 1'b0);
    cpu_rd(4'd4, rd);
    if (rd !== 32'hC0C1_C2C3) begin
      errors++; $display("ERROR: eCPRI iq after recovery = %h exp C0C1C2C3", rd);
    end

    if (errors == 0) $display("TEST PASSED: eCPRI_over_Ethernet");
    else             $display("TEST FAILED: %0d errors", errors);
    $finish;
  end

endmodule
