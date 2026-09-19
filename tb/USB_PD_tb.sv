// SPDX-License-Identifier: Apache-2.0
// Self-checking testbench for USB_PD_top -- SystemVerilog
// TB plays the USB-PD source (DFP): drives BMC-encoded frames onto the CC
// wire, decodes the sink's GoodCRC/Request replies, checks the full
// Source_Capabilities -> Request(9V) -> Accept -> PS_RDY negotiation,
// bad-CRC injection (no GoodCRC + irq) and HardReset recovery.
// IP design implementation v1.0 -- Apache-2.0
`timescale 1ns/1ps
module USB_PD_tb;
  localparam int DW = 32, AW = 32;

  logic clk = 0, rst_n = 0;
  logic cc_rxd;                 // CC wire level into the DUT
  logic cc_txd, cc_tx_en;       // DUT BMC drive
  logic vbus_ok, irq;
  logic src_drv = 1'b0;         // source-side line driver
  logic line    = 1'b0;         // BMC encoder state (TB side)

  int errors = 0;

  // CC wire: sink owns it while transmitting, source otherwise
  assign cc_rxd = cc_tx_en ? cc_txd : src_drv;

  USB_PD_top #(.DW(DW), .AW(AW)) dut (
    .clk(clk), .rst_n(rst_n),
    .cc_rxd(cc_rxd), .cc_txd(cc_txd), .cc_tx_en(cc_tx_en),
    .vbus_ok(vbus_ok), .irq(irq)
  );

  always #5 clk = ~clk;

  // ------------------------------------------------------------------
  // constants (mirror of DUT)
  // ------------------------------------------------------------------
  localparam logic [4:0] K_SYNC1 = 5'b11000;
  localparam logic [4:0] K_SYNC2 = 5'b10001;
  localparam logic [4:0] K_RST1  = 5'b00111;
  localparam logic [4:0] K_RST2  = 5'b11001;
  localparam logic [4:0] K_EOP   = 5'b01101;

  localparam logic [4:0] MT_GOODCRC = 5'h01;
  localparam logic [4:0] MT_ACCEPT  = 5'h03;
  localparam logic [4:0] MT_PSRDY   = 5'h06;
  localparam logic [4:0] MT_SRCCAP  = 5'h01;
  localparam logic [4:0] MT_REQUEST = 5'h02;

  // fixed-supply PDOs: [19:10]=V/50mV, [9:0]=I/10mA
  localparam logic [31:0] PDO_5V = 32'h0001_9096; // 5V/1.5A
  localparam logic [31:0] PDO_9V = 32'h0002_D0C8; // 9V/2A

  function automatic logic [31:0] crc32_bit(input logic [31:0] c,
                                            input logic        b);
    logic fb;
    begin
      fb        = c[0] ^ b;
      crc32_bit = (c >> 1) ^ (fb ? 32'hEDB8_8320 : 32'h0);
    end
  endfunction

  // source header: powerrole=1 (source), datarole=1 (DFP), specrev=2'b10
  function automatic logic [15:0] mk_hdr(input logic [4:0] mtype,
                                         input logic [2:0] msgid,
                                         input logic [2:0] nobj);
    mk_hdr = {1'b0, nobj, msgid, 1'b1, 2'b10, 1'b1, mtype};
  endfunction

  // ------------------------------------------------------------------
  // BMC source tasks (drive on negedge so DUT samples a stable level)
  // ------------------------------------------------------------------
  task automatic bmc_bit(input logic b);
    begin
      if (b) line = ~line;
      src_drv = line;
      @(negedge clk);
    end
  endtask

  task automatic send_sym(input logic [4:0] s);
    for (int i = 4; i >= 0; i--) bmc_bit(s[i]);
  endtask

  task automatic send_hrst;
    begin
      send_sym(K_RST1); send_sym(K_RST1); send_sym(K_RST1); send_sym(K_RST2);
      repeat (4) @(negedge clk);
    end
  endtask

  // full message: preamble + SOP + header + objects + CRC32 (+opt corrupt)
  task automatic send_msg(input logic [15:0] hdr,
                          input logic [31:0] o0, o1,
                          input logic        corrupt);
    logic [31:0] crc, cf;
    int nobj;
    begin
      crc  = 32'hFFFF_FFFF;
      nobj = hdr[14:12];
      for (int i = 0; i < 16; i++) bmc_bit(i[0]);        // preamble 0101..
      send_sym(K_SYNC1); send_sym(K_SYNC1);
      send_sym(K_SYNC1); send_sym(K_SYNC2);              // SOP
      for (int i = 0; i < 16; i++) begin
        bmc_bit(hdr[i]); crc = crc32_bit(crc, hdr[i]);
      end
      if (nobj >= 1) for (int i = 0; i < 32; i++) begin
        bmc_bit(o0[i]); crc = crc32_bit(crc, o0[i]);
      end
      if (nobj >= 2) for (int i = 0; i < 32; i++) begin
        bmc_bit(o1[i]); crc = crc32_bit(crc, o1[i]);
      end
      cf = crc ^ 32'hFFFF_FFFF;
      if (corrupt) cf = cf ^ 32'h0000_0001;              // error injection
      for (int i = 0; i < 32; i++) bmc_bit(cf[i]);
      send_sym(K_EOP);
      repeat (2) @(negedge clk);
    end
  endtask

  // ------------------------------------------------------------------
  // sink-message decoder (BMC + K-code comma lock, mirrors DUT RX)
  // ------------------------------------------------------------------
  task automatic recv_msg(output logic [15:0] hdr,
                          output logic [31:0] o0, o1,
                          output logic        got,
                          output logic        crc_ok,
                          input  int          max_wait);
    logic prev, cur, b;
    logic [4:0] win;
    logic [15:0] hsr, hf;
    logic [31:0] osr, crc;
    int skip, w, bitcnt, nobj, oc, st, sopc;
    int done;
    begin
      got = 0; crc_ok = 0; hdr = '0; o0 = '0; o1 = '0;
      w = 0;
      while (cc_tx_en === 1'b1 && w < 4) begin    // previous frame tail
        @(negedge clk); w = w + 1;
      end
      w = 0;
      while (cc_tx_en !== 1'b1 && w < max_wait) begin
        @(negedge clk); w = w + 1;
      end
      if (cc_tx_en === 1'b1) begin
        if (w > 20) begin
          errors++;
          $display("ERROR: reply latency %0d clk > 20 (GoodCRC timing)", w);
        end
        prev = src_drv; st = 0; win = '0; skip = 0; sopc = 0;
        bitcnt = 0; crc = 32'hFFFF_FFFF; nobj = 0; oc = 0; hsr = '0; osr = '0;
        done = 0;
        while (!done) begin
          @(negedge clk);
          if (cc_tx_en !== 1'b1) done = 1;    // aborted frame
          else begin
            cur = cc_txd; b = cur ^ prev; prev = cur;
            case (st)
          0: begin                          // hunt SOP
            win = {win[3:0], b};
            if (skip > 0) skip = skip - 1;
            else if (win == K_SYNC1) begin
              sopc = sopc + 1; skip = 4;
            end else if (win == K_SYNC2 && sopc > 0) begin
              st = 1; bitcnt = 0; hsr = '0; crc = 32'hFFFF_FFFF;
            end else sopc = 0;
          end
          1: begin                          // header
            hf = {b, hsr[15:1]}; hsr = hf; crc = crc32_bit(crc, b);
            if (bitcnt == 15) begin
              hdr = hf; nobj = hf[14:12]; bitcnt = 0;
              st = (nobj > 0) ? 2 : 3;
            end else bitcnt = bitcnt + 1;
          end
          2: begin                          // data objects
            osr = {b, osr[31:1]}; crc = crc32_bit(crc, b);
            if (bitcnt == 31) begin
              if (oc == 0) o0 = osr;
              else         o1 = osr;
              bitcnt = 0;
              if (oc == nobj-1) st = 3; else oc = oc + 1;
            end else bitcnt = bitcnt + 1;
          end
          3: begin                          // CRC
            crc = crc32_bit(crc, b);
            if (bitcnt == 31) begin bitcnt = 0; st = 4; win = '0; end
            else bitcnt = bitcnt + 1;
          end
          4: begin                          // EOP
            win = {win[3:0], b};
            if (bitcnt == 4) begin
              if (win == K_EOP) begin
                got    = 1;
                crc_ok = (crc == 32'hDEBB_20E3);
              end
              done = 1;
            end else bitcnt = bitcnt + 1;
          end
            endcase
          end
        end
      end
    end
  endtask

  // expect a GoodCRC echoing exp_id
  task automatic expect_goodcrc(input logic [2:0] exp_id);
    logic [15:0] h; logic [31:0] a, b2; logic g, cok;
    begin
      recv_msg(h, a, b2, g, cok, 200);
      if (!g) begin
        errors++; $display("ERROR: no GoodCRC reply (exp id %0d)", exp_id);
      end else begin
        if (!cok) begin
          errors++; $display("ERROR: GoodCRC bad CRC32 residue");
        end
        if (h[14:12] !== 3'd0 || h[4:0] !== MT_GOODCRC) begin
          errors++;
          $display("ERROR: exp GoodCRC ctrl msg, got hdr=%h", h);
        end
        if (h[11:9] !== exp_id) begin
          errors++;
          $display("ERROR: GoodCRC msgid=%0d exp %0d", h[11:9], exp_id);
        end
      end
    end
  endtask

  // expect the sink Request message selecting the 9V PDO
  task automatic expect_request_9v;
    logic [15:0] h; logic [31:0] a, b2; logic g, cok;
    begin
      recv_msg(h, a, b2, g, cok, 300);
      if (!g) begin
        errors++; $display("ERROR: no Request message from sink");
      end else begin
        if (!cok) begin
          errors++; $display("ERROR: Request bad CRC32 residue");
        end
        if (h[4:0] !== MT_REQUEST || h[14:12] !== 3'd1) begin
          errors++;
          $display("ERROR: exp Request/1obj, got hdr=%h", h);
        end
        if (a[31:28] !== 4'd2) begin
          errors++;
          $display("ERROR: RDO objpos=%0d exp 2 (9V PDO)", a[31:28]);
        end
        if (a[19:10] !== 10'd200 || a[9:0] !== 10'd200) begin
          errors++;
          $display("ERROR: RDO current op=%0d max=%0d exp 200/200",
                   a[19:10], a[9:0]);
        end
      end
    end
  endtask

  // full negotiation run with given source message-id base
  task automatic negotiate(input logic [2:0] id0);
    begin
      send_msg(mk_hdr(MT_SRCCAP, id0, 3'd2), PDO_5V, PDO_9V, 1'b0);
      expect_goodcrc(id0);
      expect_request_9v();
      send_msg(mk_hdr(MT_GOODCRC, 3'd0, 3'd0), 0, 0, 1'b0); // ack Request
      send_msg(mk_hdr(MT_ACCEPT, id0 + 3'd1, 3'd0), 0, 0, 1'b0);
      expect_goodcrc(id0 + 3'd1);
      send_msg(mk_hdr(MT_PSRDY, id0 + 3'd2, 3'd0), 0, 0, 1'b0);
      expect_goodcrc(id0 + 3'd2);
      repeat (4) @(negedge clk);
      if (vbus_ok !== 1'b1) begin
        errors++; $display("ERROR: vbus_ok not set after PS_RDY");
      end
    end
  endtask

  // ------------------------------------------------------------------
  // stimulus
  // ------------------------------------------------------------------
  int i;
  logic tx_seen;
  initial begin
    rst_n = 0; repeat (4) @(posedge clk);
    rst_n = 1; repeat (2) @(posedge clk);

    // CHECK 1: reset state
    if (vbus_ok !== 1'b0 || cc_tx_en !== 1'b0 || irq !== 1'b0) begin
      errors++;
      $display("ERROR: reset state vbus_ok=%b tx_en=%b irq=%b",
               vbus_ok, cc_tx_en, irq);
    end else $display("CHECK 1 PASS: reset state");

    // CHECK 2: full negotiation, per-message compare (incl. GoodCRC timing)
    negotiate(3'd0);
    $display("CHECK 2 done: negotiation #1 (errors=%0d)", errors);

    // CHECK 3: bad-CRC injection -> no GoodCRC, irq asserted
    send_msg(mk_hdr(MT_SRCCAP, 3'd4, 3'd2), PDO_5V, PDO_9V, 1'b1);
    tx_seen = 1'b0;
    for (i = 0; i < 60; i++) begin
      @(negedge clk);
      if (cc_tx_en === 1'b1) tx_seen = 1'b1;
    end
    if (tx_seen) begin
      errors++; $display("ERROR: sink replied to bad-CRC message");
    end
    if (irq !== 1'b1) begin
      errors++; $display("ERROR: irq not asserted after bad CRC");
    end else $display("CHECK 3 PASS: bad CRC -> no reply + irq");

    // CHECK 4: recovery + consecutive negotiation #2 (back-to-back traffic)
    negotiate(3'd1);
    if (irq !== 1'b0) begin
      errors++; $display("ERROR: irq not cleared by valid message");
    end
    $display("CHECK 4 done: negotiation #2 (errors=%0d)", errors);

    // CHECK 5: HardReset ordered set -> back to initial state
    send_hrst();
    repeat (8) @(negedge clk);
    if (vbus_ok !== 1'b0) begin
      errors++; $display("ERROR: vbus_ok still set after HardReset");
    end else $display("CHECK 5 PASS: HardReset drops contract");

    // CHECK 6: negotiation #3 after HardReset
    negotiate(3'd0);
    $display("CHECK 6 done: post-HardReset negotiation (errors=%0d)", errors);

    if (errors == 0) $display("TEST PASSED: USB-PD");
    else             $display("TEST FAILED: %0d errors", errors);
    $finish;
  end

  initial begin
    #500000;
    $display("TIMEOUT");
    $display("TEST FAILED: %0d errors", errors + 1);
    $finish;
  end
endmodule
