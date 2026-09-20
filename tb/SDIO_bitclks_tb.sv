// SPDX-License-Identifier: Apache-2.0
// ============================================================================
// Self-checking BIT_CLKS=4 functional testbench for SDIO_top -- host model
// driving CMD/DAT with each serial bit held for 4 sd_clk cycles; card->host
// direction is sampled once per 4 sd_clk posedges after start-bit detect.
// Checks: reset idle state, CMD52 R/W readback, CMD53 8-byte block write +
//         readback + CRC16, bad CRC7 injection (no response + irq),
//         bad CRC16 injection (block discarded + irq), recovery after errors.
// -- Apache-2.0
// ============================================================================
`timescale 1ns/1ps
module SDIO_bitclks_tb;
  localparam int BC = 4;          // sd_clk cycles per serial bit (DUT setting)

  logic      clk = 0, rst_n = 0, sd_clk = 0;
  tri1       cmd;                 // CMD line with pull-up (open-drain model)
  tri1 [3:0] dat;                 // DAT lines with pull-ups
  logic      irq;

  // host-side line drivers
  logic       host_cmd_oe  = 0, host_cmd_out = 1;
  logic       host_dat_oe  = 0;
  logic [3:0] host_dat_out = 4'bzzzz;

  int  errors = 0;
  bit  irq_seen = 0;

  assign cmd = host_cmd_oe ? host_cmd_out : 1'bz;
  assign dat = host_dat_oe ? host_dat_out : 4'bzzzz;

  SDIO_top #(.BIT_CLKS(BC)) dut (
    .clk(clk), .rst_n(rst_n), .sd_clk(sd_clk),
    .cmd(cmd), .dat(dat), .irq(irq)
  );

  always #5  clk    = ~clk;     // 100 MHz system clock (card core ignores it)
  always #10 sd_clk = ~sd_clk;  // 50 MHz SDIO bus clock (4 cycles per bit)

  // edge-triggered irq monitor: catches the (BC-wide) error pulses
  always @(posedge irq) irq_seen = 1'b1;

  // ---------------- CRC helpers (independent reference model) -------------
  function automatic logic [6:0] crc7_bit(input logic [6:0] c, input logic d);
    logic fb;
    begin
      fb       = c[6] ^ d;
      crc7_bit = {c[5:3], c[2] ^ fb, c[1:0], fb};
    end
  endfunction

  function automatic logic [6:0] crc7_40(input logic [39:0] m);
    logic [6:0] c;
    begin
      c = 7'h00;
      for (int i = 39; i >= 0; i--) c = crc7_bit(c, m[i]);
      crc7_40 = c;
    end
  endfunction

  function automatic logic [15:0] crc16_bit(input logic [15:0] c, input logic d);
    logic fb;
    begin
      fb        = c[15] ^ d;
      crc16_bit = {c[14:12], c[11] ^ fb, c[10:5], c[4] ^ fb, c[3:0], fb};
    end
  endfunction

  // ---------------- host primitives ---------------------------------------
  // drive one 48-bit command frame on CMD, each bit held BC sd_clk cycles
  task automatic host_send_cmd(input logic [5:0] idx, input logic [31:0] arg,
                               input logic corrupt);
    logic [47:0] f;
    logic [6:0]  c;
    begin
      f = {1'b0, 1'b1, idx, arg, 7'h00, 1'b1};
      c = crc7_40(f[47:8]);
      if (corrupt) c = c ^ 7'h55;
      f[7:1] = c;
      @(negedge sd_clk);
      host_cmd_oe = 1'b1;
      for (int i = 47; i >= 0; i--) begin
        host_cmd_out = f[i];
        repeat (BC) @(negedge sd_clk);
      end
      host_cmd_oe  = 1'b0;
      host_cmd_out = 1'b1;
    end
  endtask

  // receive a 48-bit response; sample once per BC posedges after start bit
  // ok=0 on timeout or bad structure/CRC7
  task automatic host_recv_rsp(output logic [47:0] r, output logic ok);
    int k;
    bit saw;
    begin
      r = '0; ok = 0; saw = 0; k = 0;
      while (k < 64*BC && !saw) begin           // wait for start bit
        @(posedge sd_clk); #1;
        if (cmd === 1'b0) saw = 1;
        k++;
      end
      if (saw) begin
        r[47] = 1'b0;
        for (int i = 46; i >= 0; i--) begin
          repeat (BC) @(posedge sd_clk); #1;
          r[i] = cmd;
        end
        if (r[46] === 1'b0 && r[0] === 1'b1 && crc7_40(r[47:8]) === r[7:1])
          ok = 1;
      end
    end
  endtask

  // inter-transaction gap (card returns to IDLE, lines released)
  task automatic gap;
    begin
      repeat (4*BC) @(negedge sd_clk);
    end
  endtask

  // CMD52 IO_RW_DIRECT; rdata/ok valid on return
  task automatic cmd52(input logic rw, input logic [16:0] addr,
                       input logic [7:0] wdata, output logic [7:0] rdata,
                       output logic ok);
    logic [31:0] arg;
    logic [47:0] r;
    begin
      arg = {rw, 3'd1, 1'b0, 1'b0, addr, 1'b0, wdata};
      host_send_cmd(6'd52, arg, 1'b0);
      host_recv_rsp(r, ok);
      rdata = r[15:8];
      if (ok && r[45:40] !== 6'd52) ok = 0;
    end
  endtask

  // shared block buffers (iverilog-friendly, no dynamic arrays)
  logic [7:0] txb [0:31];
  logic [7:0] rxb [0:31];

  // CMD53 write: R5 response, then host shifts block on DAT0 (BC clk/bit)
  task automatic cmd53_write(input logic [16:0] addr, input int n,
                             input logic bad_crc, output logic ok);
    logic [31:0] arg;
    logic [47:0] r;
    logic [15:0] c;
    begin
      arg = {1'b1, 3'd1, 1'b0, 1'b1, addr, n[8:0]};
      host_send_cmd(6'd53, arg, 1'b0);
      host_recv_rsp(r, ok);
      if (ok && r[45:40] !== 6'd53) ok = 0;
      if (ok) begin
        c = 16'h0000;
        for (int i = 0; i < n; i++)
          for (int b = 7; b >= 0; b--) c = crc16_bit(c, txb[i][b]);
        if (bad_crc) c = c ^ 16'h00FF;
        repeat (3*BC) @(negedge sd_clk);
        host_dat_oe  = 1'b1;
        host_dat_out = 4'bzzz0;                 // start bit on DAT0
        repeat (BC) @(negedge sd_clk);
        for (int i = 0; i < n; i++)
          for (int b = 7; b >= 0; b--) begin
            host_dat_out[0] = txb[i][b];
            repeat (BC) @(negedge sd_clk);
          end
        for (int b = 15; b >= 0; b--) begin
          host_dat_out[0] = c[b];               // CRC16, MSB first
          repeat (BC) @(negedge sd_clk);
        end
        host_dat_out = 4'bzzz1;                 // end bit
        repeat (BC) @(negedge sd_clk);
        host_dat_oe = 1'b0;
      end
    end
  endtask

  // CMD53 read: R5 response, then card drives block on DAT[3:0]; sample once
  // per BC posedges (card holds every nibble/CRC bit for BC sd_clk cycles)
  task automatic cmd53_read(input logic [16:0] addr, input int n,
                            output logic ok);
    logic [31:0] arg;
    logic [47:0] r;
    logic [15:0] crc_calc [0:3];
    logic [15:0] crc_rcv  [0:3];
    int k;
    bit saw;
    begin
      arg = {1'b0, 3'd1, 1'b0, 1'b1, addr, n[8:0]};
      host_send_cmd(6'd53, arg, 1'b0);
      host_recv_rsp(r, ok);
      if (ok && r[45:40] !== 6'd53) ok = 0;
      if (ok) begin
        saw = 0; k = 0;
        while (k < 32*BC && !saw) begin         // wait for start 4'b0000
          @(posedge sd_clk); #1;
          if (dat === 4'b0000) saw = 1;
          k++;
        end
        if (!saw) begin
          ok = 0;
        end else begin
          for (int l = 0; l < 4; l++) begin
            crc_calc[l] = 16'h0000;
            crc_rcv[l]  = 16'h0000;
          end
          for (int i = 0; i < n; i++) begin     // 2 nibbles per byte
            repeat (BC) @(posedge sd_clk); #1;
            rxb[i][7:4] = dat;
            repeat (BC) @(posedge sd_clk); #1;
            rxb[i][3:0] = dat;
          end
          for (int i = 0; i < n; i++) begin     // per-line reference CRC16
            for (int l = 0; l < 4; l++)
              crc_calc[l] = crc16_bit(crc_calc[l], rxb[i][4+l]);
            for (int l = 0; l < 4; l++)
              crc_calc[l] = crc16_bit(crc_calc[l], rxb[i][l]);
          end
          for (int b = 0; b < 16; b++) begin    // 16 CRC bits, one per line
            repeat (BC) @(posedge sd_clk); #1;
            for (int l = 0; l < 4; l++)
              crc_rcv[l] = {crc_rcv[l][14:0], dat[l]};
          end
          repeat (BC) @(posedge sd_clk); #1;    // end pattern
          if (dat !== 4'b1111) begin
            ok = 0;
            $display("ERROR: CMD53 read end pattern got=%b exp=1111", dat);
          end
          for (int l = 0; l < 4; l++)
            if (crc_rcv[l] !== crc_calc[l]) begin
              ok = 0;
              $display("ERROR: CMD53 read CRC16 line %0d got=%h exp=%h",
                       l, crc_rcv[l], crc_calc[l]);
            end
        end
      end
    end
  endtask

  // ---------------- test sequence -----------------------------------------
  logic [16:0] a;
  logic [7:0]  d, rd;
  logic        ok;
  logic [47:0] r;

  initial begin
    rst_n = 0;
    repeat (6) @(posedge clk);
    rst_n = 1;
    repeat (6*BC) @(posedge sd_clk);

    // (a) post-reset idle state: irq low, card not driving CMD/DAT
    if (irq !== 1'b0) begin
      errors++; $display("ERROR: irq not low after reset");
    end
    if (cmd !== 1'b1) begin
      errors++; $display("ERROR: CMD line not idle-high after reset");
    end
    if (dat !== 4'b1111) begin
      errors++; $display("ERROR: DAT lines not idle-high after reset");
    end

    // (b) CMD52 write + read-back, 4 rounds, distinct addresses/data
    for (int i = 0; i < 4; i++) begin
      a = 17'h0010 + i[16:0] * 17'h0007;
      d = 8'hA5 ^ (8'(i) * 8'h3C);
      cmd52(1'b1, a, d, rd, ok);
      if (!ok) begin
        errors++; $display("ERROR: CMD52 write %0d: missing/bad R5", i);
      end else if (rd !== d) begin
        errors++; $display("ERROR: CMD52 write %0d echo got=%h exp=%h", i, rd, d);
      end
      gap();
      cmd52(1'b0, a, 8'h00, rd, ok);
      if (!ok) begin
        errors++; $display("ERROR: CMD52 read %0d: missing/bad R5", i);
      end else if (rd !== d) begin
        errors++; $display("ERROR: CMD52 read %0d got=%h exp=%h", i, rd, d);
      end
      gap();
    end

    // (c) CMD53 block write of 8 bytes, then read back and compare (+CRC16)
    for (int i = 0; i < 8; i++) txb[i] = 8'h11 * 8'(i) + 8'h42;
    cmd53_write(17'h0040, 8, 1'b0, ok);
    if (!ok) begin
      errors++; $display("ERROR: CMD53 write: missing/bad R5");
    end
    gap();
    cmd53_read(17'h0040, 8, ok);
    if (!ok) begin
      errors++; $display("ERROR: CMD53 read: missing/bad R5 or CRC16");
    end else begin
      for (int i = 0; i < 8; i++)
        if (rxb[i] !== txb[i]) begin
          errors++;
          $display("ERROR: CMD53 readback byte %0d got=%h exp=%h", i, rxb[i], txb[i]);
        end
    end
    gap();
    // cross-check one CMD53-written byte through CMD52
    cmd52(1'b0, 17'h0043, 8'h00, rd, ok);
    if (!ok || rd !== txb[3]) begin
      errors++; $display("ERROR: CMD52 cross-check of CMD53 data got=%h exp=%h",
                         rd, txb[3]);
    end
    gap();

    // (d) error injection: corrupt CRC7 -> no response + irq pulse
    irq_seen = 0;
    host_send_cmd(6'd52, {1'b0, 3'd1, 1'b0, 1'b0, 17'h0010, 1'b0, 8'h00}, 1'b1);
    host_recv_rsp(r, ok);
    if (ok) begin
      errors++; $display("ERROR: bad-CRC7 command was answered");
    end
    repeat (8*BC) @(posedge sd_clk);
    if (!irq_seen) begin
      errors++; $display("ERROR: bad-CRC7 command did not raise irq");
    end
    gap();

    // (e) error injection: bad CRC16 on CMD53 write -> block discarded + irq
    for (int i = 0; i < 8; i++) txb[i] = 8'hF0 ^ 8'(i);
    irq_seen = 0;
    cmd53_write(17'h0060, 8, 1'b1, ok);
    if (!ok) begin
      errors++; $display("ERROR: CMD53 bad-CRC16 write: missing/bad R5");
    end
    repeat (8*BC) @(posedge sd_clk);
    if (!irq_seen) begin
      errors++; $display("ERROR: bad CRC16 block did not raise irq");
    end
    gap();
    cmd53_read(17'h0060, 8, ok);
    if (!ok) begin
      errors++; $display("ERROR: CMD53 verify read after bad CRC16 failed");
    end else begin
      for (int i = 0; i < 8; i++)
        if (rxb[i] !== 8'h00) begin
          errors++;
          $display("ERROR: bad-CRC16 block was committed: byte %0d got=%h exp=00",
                   i, rxb[i]);
        end
    end
    gap();

    // (f) still healthy after errors: two back-to-back CMD52 round-trips
    for (int i = 0; i < 2; i++) begin
      a = 17'h0070 + i[16:0];
      d = 8'h5A ^ (8'(i) * 8'hA5);
      cmd52(1'b1, a, d, rd, ok);
      if (!ok || rd !== d) begin
        errors++; $display("ERROR: post-error CMD52 write %0d failed", i);
      end
      gap();
      cmd52(1'b0, a, 8'h00, rd, ok);
      if (!ok || rd !== d) begin
        errors++; $display("ERROR: post-error CMD52 read %0d failed", i);
      end
      gap();
    end

    if (errors == 0) $display("TEST PASSED: SDIO_BITCLKS");
    else             $display("TEST FAILED: %0d errors", errors);
    $finish;
  end

  initial begin
    #10_000_000; $display("TIMEOUT"); $finish;
  end
endmodule
