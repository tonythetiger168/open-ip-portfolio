// SPDX-License-Identifier: Apache-2.0
// ============================================================================
// Self-checking testbench for UFS_top -- SystemVerilog
// The TB is the peer device's link partner: it answers link training,
// sends COMMAND UPIU frames bit-serially on rx_p and checks every RESPONSE /
// DATA UPIU (CRC-32, EOF, task tag, status/sense, data) against a shadow
// of the LUN0 medium. Covered: training timeout + retrain, a bad second
// training dword, TEST UNIT READY, WRITE10 / READ10 at every length and at
// the end of the medium, CRC error, bad EOF, oversize and malformed frames,
// non-zero LUN, WRITE10 length mismatch, out-of-range LBA / length, unknown
// opcodes, non-command UPIUs, a command while the DUT is still transmitting,
// every medium bit 0->1->0, random traffic and a reset mid-response.
// Open IP design implementation v2.5 -- Apache-2.0
// ============================================================================
`timescale 1ns/1ps
module UFS_tb;
  localparam logic [31:0] SOF   = 32'h5546_5301;
  localparam logic [31:0] EOFR  = 32'h5546_5302;
  localparam logic [31:0] TRAIN = 32'hBC3C_5A5A;

  logic clk = 0, rst_n = 0, refclk = 0;
  logic rx_n, rx_p;
  wire  tx_n, tx_p, irq;
  // dut runs 1 clk per bit; dut2 (BIT_CLKS = 2) gets a shorter pass at the
  // end. sel picks the instance the TB talks to, bc its clocks per bit.
  bit   sel = 0;
  int   bc = 1;
  wire  tx1_p, tx1_n, irq1, tx2_p, tx2_n, irq2;
  assign tx_p = sel ? tx2_p : tx1_p;
  assign tx_n = sel ? tx2_n : tx1_n;
  assign irq  = sel ? irq2 : irq1;
  wire [1:0] lp_s   = sel ? dut2.lp_state : dut.lp_state;
  wire       link_s = sel ? dut2.link_up : dut.link_up;
  int   errors = 0;
  logic irq_seen = 0, tx_act = 0;

  logic [31:0] tpay [0:7];       // frame payload to transmit
  logic [31:0] rpay [0:7];       // received frame payload
  logic [31:0] wdata [0:3];      // WRITE10 data pattern
  logic [31:0] shadow [0:255];
  logic [31:0] tb_crc, rcrc, rhdr;
  logic [7:0]  rlen;

  UFS_top dut (
    .clk(clk), .rst_n(rst_n),
    .tx_n(tx1_n), .tx_p(tx1_p), .rx_n(sel ? 1'b0 : rx_n), .rx_p(sel ? 1'b1 : rx_p),
    .refclk(refclk), .irq(irq1)
  );
  UFS_top #(.BIT_CLKS(2)) dut2 (
    .clk(clk), .rst_n(rst_n),
    .tx_n(tx2_n), .tx_p(tx2_p), .rx_n(sel ? rx_n : 1'b0), .rx_p(sel ? rx_p : 1'b1),
    .refclk(refclk), .irq(irq2)
  );

  always #5 clk = ~clk;
  always #3 refclk = ~refclk;

  // monitors: latch irq pulses and any TX activity
  always @(posedge clk) begin
    if (irq)            irq_seen <= 1'b1;
    if (tx_p === 1'b0)  tx_act   <= 1'b1;
  end

  // ------------------------ helpers ------------------------
  function automatic logic [31:0] crc_step(input logic [31:0] c, input logic b);
    logic fb;
    begin
      fb       = c[0] ^ b;
      crc_step = (c >> 1) ^ (fb ? 32'hEDB8_8320 : 32'h0000_0000);
    end
  endfunction

  task automatic check(input bit cond, input string msg);
    if (!cond) begin
      errors++;
      $display("ERROR: %s @%0t", msg, $time);
    end
  endtask

  task automatic send_word(input logic [31:0] wd, input bit upd);
    for (int i = 31; i >= 0; i--) begin
      @(negedge clk); rx_p = wd[i]; rx_n = ~wd[i];
      repeat (bc - 1) @(negedge clk);
      if (upd) tb_crc = crc_step(tb_crc, wd[i]);
    end
  endtask

  task automatic line_idle;
    begin @(negedge clk); rx_p = 1'b1; rx_n = 1'b0; end
  endtask

  // send one frame: SOF HDR payload[0..n-1] CRC32 EOF (n words of tpay)
  task automatic send_raw(input logic [31:0] hdr, input int n, input bit corrupt, input bit bad_eof);
    logic [31:0] c;
    begin
      send_word(SOF, 0);
      tb_crc = 32'hFFFF_FFFF;
      send_word(hdr, 1);
      for (int i = 0; i < n; i++) send_word(tpay[i], 1);
      c = tb_crc ^ 32'hFFFF_FFFF;
      if (corrupt) c = c ^ 32'h0000_0001;
      send_word(c, 0);
      send_word(bad_eof ? 32'h5546_5303 : EOFR, 0);
      line_idle();
    end
  endtask

  task automatic recv_word(output logic [31:0] wd);
    for (int i = 31; i >= 0; i--) begin
      repeat (bc) @(posedge clk); #1; wd[i] = tx_p;
    end
  endtask

  // bit-level scan for SOF so dword alignment is recovered
  task automatic wait_sof;
    logic [31:0] s; int cnt;
    begin
      s = 32'hFFFF_FFFF; cnt = 0;
      while ((s !== SOF) && (cnt < 4000)) begin
        repeat (bc) @(posedge clk); #1; s = {s[30:0], tx_p}; cnt++;
      end
      if (s !== SOF) begin
        errors++;
        $display("ERROR: timeout waiting for response SOF @%0t", $time);
      end
    end
  endtask

  // receive one frame into rhdr/rpay, verify CRC32 and EOF
  task automatic recv_frame(output logic [31:0] hdr);
    logic [31:0] w; logic [31:0] c; logic [31:0] tmp;
    begin
      wait_sof();
      recv_word(hdr);
      c = 32'hFFFF_FFFF;
      for (int i = 31; i >= 0; i--) c = crc_step(c, hdr[i]);
      rlen = hdr[7:0];
      if (rlen > 8) begin
        errors++;
        $display("ERROR: response len %0d out of range", rlen);
      end else begin
        for (int i = 0; i < rlen; i++) begin
          // NB: recv into a temp first -- Icarus vvp crashes when an unpacked
          // array element is passed directly as a task output argument.
          recv_word(tmp);
          rpay[i] = tmp;
          for (int j = 31; j >= 0; j--) c = crc_step(c, tmp[j]);
        end
      end
      recv_word(rcrc);
      check(rcrc === (c ^ 32'hFFFF_FFFF), "response CRC32 mismatch");
      recv_word(w);
      check(w === EOFR, "response EOF marker mismatch");
    end
  endtask

  // wait for the DUT to listen for the training answer, then answer
  task automatic train(input bit bad_second);
    int cnt;
    begin
      cnt = 0;
      while (lp_s !== 2'd2 && cnt < 20000) begin @(posedge clk); cnt++; end
      repeat (40) @(posedge clk);
      send_word(TRAIN, 0);
      send_word(bad_second ? 32'hBC3C_5A5B : TRAIN, 0);
      line_idle();
      repeat (4) @(posedge clk);
      if (!bad_second) check(link_s === 1'b1, "LINKUP not reached after training exchange");
      else             check(link_s === 1'b0, "LINKUP on a bad second training dword");
    end
  endtask

  // COMMAND UPIU: CDB = {op, lba}, {xfer, 0}; WRITE10 data from wdata[]
  task automatic cmd_raw(input logic [7:0] op, input logic [23:0] lba, input logic [7:0] xfer,
                         input logic [7:0] tt, input logic [7:0] lun, input int ndat,
                         input bit corrupt);
    begin
      tpay[0] = {op, lba};
      tpay[1] = {xfer, 24'($urandom)};       // reserved CDB fields: ignored
      tpay[2] = $urandom;
      tpay[3] = $urandom;
      for (int i = 0; i < ndat; i++) tpay[4+i] = wdata[i];
      send_raw({8'h01, tt, lun, 8'(4 + ndat)}, 4 + ndat, corrupt, 0);
    end
  endtask

  task automatic expect_resp(input logic [7:0] tt, input bit good);
    begin
      recv_frame(rhdr);
      check(rhdr === {8'h81, tt, 8'h00, 8'd1} || (!good && rhdr[31:24] === 8'h81 && rhdr[23:16] === tt),
            "RESPONSE UPIU header");
      check(rpay[0] === (good ? 32'h0 : 32'h0005_0001), "RESPONSE status/sense");
    end
  endtask

  // no frame may follow (dropped command)
  task automatic expect_silent(input string what);
    begin
      repeat (2) @(posedge clk);             // let the last EOF bit go by
      tx_act = 0;
      repeat (300) @(posedge clk);
      check(tx_act === 1'b0, {what, ": DUT responded"});
    end
  endtask

  task automatic write10(input int lba, input int n, input logic [7:0] tt);
    begin
      irq_seen = 0;
      cmd_raw(8'h2A, 24'(lba), 8'(n), tt, 8'h00, n, 0);
      expect_resp(tt, 1);
      for (int j = 0; j < n; j++) shadow[lba + j] = wdata[j];
      check(irq_seen === 1'b0, "irq on a good WRITE10");
    end
  endtask

  task automatic read10(input int lba, input int n, input logic [7:0] tt);
    begin
      cmd_raw(8'h28, 24'(lba), 8'(n), tt, 8'h00, 0, 0);
      expect_resp(tt, 1);
      recv_frame(rhdr);
      check(rhdr === {8'h02, tt, 8'h00, 8'(n)}, "DATA UPIU header");
      for (int j = 0; j < n; j++)
        if (rpay[j] !== shadow[lba + j]) begin
          errors++; $display("ERROR: READ10 lba %0d+%0d got %h exp %h", lba, j, rpay[j], shadow[lba + j]);
        end
    end
  endtask

  // a command answered with CHECK CONDITION / ILLEGAL REQUEST + irq
  task automatic illegal(input logic [7:0] op, input logic [23:0] lba, input logic [7:0] xfer,
                         input logic [7:0] lun, input int ndat, input string what);
    begin
      irq_seen = 0;
      cmd_raw(op, lba, xfer, 8'h5C, lun, ndat, 0);
      recv_frame(rhdr);
      check(rhdr === {8'h81, 8'h5C, lun, 8'd1}, {what, ": RESPONSE header"});
      check(rpay[0] === 32'h0005_0001, {what, ": not CHECK / ILLEGAL REQUEST"});
      check(irq_seen === 1'b1, {what, ": no irq"});
    end
  endtask

  // ------------------------ stimulus ------------------------
  initial begin
    rx_p = 1'b1; rx_n = 1'b0;
    rst_n = 0;
    for (int i = 0; i < 256; i++) shadow[i] = 32'h0;
    repeat (8) @(posedge clk);
    check(irq === 1'b0,          "irq asserted during reset");
    check(tx_p === 1'b1,         "tx_p not idle during reset");
    check(link_s === 1'b0,       "link_up asserted before training");
    rst_n = 1;

    // ---- link training: no answer -> retrain; bad 2nd dword; good ----
    repeat (300) @(posedge clk);
    while (lp_s !== 2'd2) @(posedge clk);
    repeat (4200) @(posedge clk);
    check(lp_s === 2'd1 || lp_s === 2'd2, "no retrain after the response timeout");
    train(1);
    train(0);
    repeat (20) @(posedge clk);

    // ---- every medium bit 0 -> 1 -> 0, read back with 8-dword READ10s ----
    for (int j = 0; j < 4; j++) wdata[j] = 32'hFFFF_FFFF;
    for (int a = 0; a < 256; a += 4) write10(a, 4, 8'(a));
    for (int a = 0; a < 256; a += 8) read10(a, 8, 8'(a + 1));
    for (int j = 0; j < 4; j++) wdata[j] = 32'h0;
    for (int a = 0; a < 256; a += 4) write10(a, 4, 8'(a + 2));
    read10(0, 8, 8'h33);

    // ---- directed commands ----
    irq_seen = 0;
    cmd_raw(8'h00, 24'h0, 8'd0, 8'hA5, 8'h00, 0, 0);       // TEST UNIT READY
    expect_resp(8'hA5, 1);
    check(irq_seen === 1'b0, "irq on TEST UNIT READY");
    wdata[0] = 32'hDEAD_BEEF; wdata[1] = 32'h1234_5678;
    wdata[2] = 32'hCAFE_F00D; wdata[3] = 32'h0BAD_5EED;
    for (int n = 1; n <= 4; n++) begin write10(16 * n, n, 8'(n)); read10(16 * n, n, 8'(n + 8)); end
    write10(252, 4, 8'hFC); read10(248, 8, 8'hFD);         // end of the medium
    for (int n = 1; n <= 8; n++) read10(100, n, 8'(n));

    // ---- errors ----
    irq_seen = 0;
    wdata[0] = 32'hFFFF_0000;
    cmd_raw(8'h2A, 24'd16, 8'd1, 8'h04, 8'h00, 1, 1);      // CRC error: dropped
    expect_silent("CRC error");
    check(irq_seen === 1'b1, "no irq on CRC-corrupted frame");
    irq_seen = 0;
    tpay[0] = {8'h00, 24'h0}; for (int i = 1; i < 4; i++) tpay[i] = 0;
    send_raw({8'h01, 8'h05, 8'h00, 8'd4}, 4, 0, 1);         // bad EOF
    expect_silent("bad EOF");
    check(irq_seen === 1'b1, "no irq on bad EOF");
    for (int l = 0; l < 4; l++) begin                       // malformed CDB
      irq_seen = 0;
      send_raw({8'h01, 8'h06, 8'h00, 8'(l)}, l, 0, 0);
      expect_silent("malformed CDB");
      check(irq_seen === 1'b1, "no irq on malformed CDB");
    end
    foreach (wdata[i]) wdata[i] = 32'h0;
    for (int b = 0; b < 8; b++) begin                       // oversize length
      irq_seen = 0;
      send_word(SOF, 0);
      send_word({8'h01, 8'h07, 8'h00, 8'(9 + b) | (8'h1 << b)}, 0);
      for (int j = 0; j < 3; j++) send_word(32'h0, 0);
      line_idle();
      expect_silent("oversize length");
      check(irq_seen === 1'b1, "no irq on oversize length");
    end
    illegal(8'h00, 24'h0, 8'd0, 8'h01, 0, "LUN 1");
    illegal(8'h2A, 24'h0, 8'd1, 8'hFF, 1, "LUN 255");
    illegal(8'h2A, 24'd40, 8'd2, 8'h00, 1, "WRITE10 xfer > data");
    illegal(8'h2A, 24'd40, 8'd0, 8'h00, 3, "WRITE10 xfer < data");
    illegal(8'h2A, 24'd0, 8'd0, 8'h00, 0, "WRITE10 no data");
    illegal(8'h2A, 24'd254, 8'd3, 8'h00, 3, "WRITE10 past the medium");
    illegal(8'h2A, 24'hFFFFFF, 8'd1, 8'h00, 1, "WRITE10 LBA 2^24-1");
    illegal(8'h28, 24'd0, 8'd0, 8'h00, 0, "READ10 length 0");
    illegal(8'h28, 24'd0, 8'd9, 8'h00, 0, "READ10 length 9");
    illegal(8'h28, 24'd0, 8'd255, 8'h00, 0, "READ10 length 255");
    illegal(8'h28, 24'd255, 8'd2, 8'h00, 0, "READ10 past the medium");
    illegal(8'h28, 24'hFFFF00, 8'd1, 8'h00, 0, "READ10 high LBA");
    for (int b = 0; b < 8; b++) illegal(8'h1 << b, 24'h0, 8'd0, 8'h00, 0, "unknown opcode");
    illegal(8'hFF, 24'h0, 8'd0, 8'h00, 0, "unknown opcode FF");
    // non-command UPIUs are ignored without irq
    foreach (tpay[i]) tpay[i] = 32'h0;
    for (int t = 0; t < 3; t++) begin
      irq_seen = 0;
      send_raw({t == 0 ? 8'h02 : t == 1 ? 8'h81 : 8'hFE, 8'h08, 8'h00, 8'd2}, 2, 0, 0);
      expect_silent("non-command UPIU");
      check(irq_seen === 1'b0, "irq on a non-command UPIU");
    end
    // len 8 COMMAND with zero-length data after the CDB fields of a TUR
    cmd_raw(8'h00, 24'h0, 8'd0, 8'h09, 8'h00, 4, 0);
    expect_resp(8'h09, 1);

    // ---- a command arriving while the response is still on the wire ----
    irq_seen = 0;
    fork
      begin
        cmd_raw(8'h28, 24'd248, 8'd8, 8'h71, 8'h00, 0, 0);
        wdata[0] = 32'h1111_2222;
        cmd_raw(8'h2A, 24'd248, 8'd1, 8'h72, 8'h00, 1, 0);   // dropped: busy
      end
      begin
        expect_resp(8'h71, 1);
        recv_frame(rhdr);
        check(rhdr === {8'h02, 8'h71, 8'h00, 8'd8}, "busy: DATA UPIU header / task tag");
        for (int j = 0; j < 8; j++) check(rpay[j] === shadow[248 + j], "busy: DATA UPIU data");
      end
    join
    expect_silent("command while busy");
    check(irq_seen === 1'b1, "no irq on a command while busy");
    read10(248, 8, 8'h73);

    // ---- random traffic ----
    for (int i = 0; i < 150; i++) begin
      int sel, lba, n;
      logic [7:0] tt;
      tt  = 8'($urandom);
      sel = $urandom_range(0, 9);
      n   = $urandom_range(1, 4);
      lba = $urandom_range(0, 256 - n);
      for (int j = 0; j < 4; j++) wdata[j] = $urandom();
      if (sel < 4) write10(lba, n, tt);
      else if (sel < 8) begin n = $urandom_range(1, 8); read10($urandom_range(0, 256 - n), n, tt); end
      else if (sel < 9) begin
        irq_seen = 0;
        cmd_raw(8'h2A, 24'(lba), 8'(n), tt, 8'h00, n, 1);
        expect_silent("random CRC error");
      end else illegal(8'h2A, 24'(256 - n + $urandom_range(1, 8)), 8'(n), 8'h00, n, "random out of range");
    end

    // ---- data classes 0x5555.. / 0xAAAA.., task tag FF ----
    for (int j = 0; j < 4; j++) wdata[j] = j[0] ? 32'hAAAA_AAAA : 32'h5555_5555;
    write10(60, 2, 8'hFF); read10(60, 1, 8'hFF); read10(61, 1, 8'h3C);

    // ---- reset while the DATA UPIU is on the wire, then retrain ----
    cmd_raw(8'h28, 24'd0, 8'd8, 8'h44, 8'h00, 0, 0);
    wait_sof();
    repeat (300) @(posedge clk);
    @(negedge clk) rst_n = 0;
    repeat (3) @(posedge clk);
    check(tx_p === 1'b1 && link_s === 1'b0, "reset did not idle the link");
    @(negedge clk) rst_n = 1;
    train(0);
    repeat (20) @(posedge clk);
    read10(0, 8, 8'h45);                                    // medium is not reset

    // ---- BIT_CLKS = 2 instance: training, commands, errors ----
    sel = 1; bc = 2;
    line_idle();
    train(0);
    repeat (20) @(posedge clk);
    for (int j = 0; j < 4; j++) wdata[j] = $urandom;
    write10(8, 4, 8'h21); read10(8, 4, 8'h22);
    write10(12, 3, 8'h23); read10(8, 7, 8'h24);
    illegal(8'h77, 24'h0, 8'd0, 8'h00, 0, "BIT_CLKS=2 unknown opcode");
    irq_seen = 0;
    cmd_raw(8'h2A, 24'd8, 8'd1, 8'h25, 8'h00, 1, 1);
    expect_silent("BIT_CLKS=2 CRC error");
    check(irq_seen === 1'b1, "BIT_CLKS=2: no irq on CRC error");
    read10(8, 1, 8'h26);

    if (errors == 0) $display("TEST PASSED: UFS");
    else             $display("TEST FAILED: %0d errors", errors);
    $finish;
  end

  initial begin
    repeat (20000) #1000;   // 20 ms in 1-us chunks
    $display("TEST FAILED: TIMEOUT"); $finish;
  end
endmodule
