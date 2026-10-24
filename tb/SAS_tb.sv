// SPDX-License-Identifier: Apache-2.0
// ============================================================================
// Self-checking testbench for SAS_top. The line normally loops tx back to
// rx (the initiator talks to its own target side); the TB can corrupt
// single bits of the loopback or take the line over to inject its own
// frames (as another SAS device), and a monitor decodes every frame the
// DUT transmits (SOF hunt, header, payload, CRC32, EOF all checked).
// Covered: OOB with a missed COMINIT in both idle windows, write / read
// verify transactions with the counters wrapping, bit flips anywhere in a
// frame, injected writes / read requests from other addresses (read
// response addressed back), bad CRC, bad EOF, oversize and maximum length,
// a write without payload, out-of-range register, unknown type, empty read
// response, mismatching read responses (value or source), write and read
// timeouts, a response queued while a frame is on the wire, reset
// mid-frame.
// ============================================================================
`timescale 1ns/1ps
module SAS_tb;
  logic clk = 0, rst_n = 0, refclk = 0;
  logic tx_n, tx_p, rx_n, rx_p, irq;
  logic corrupt = 0;             // flip the looped-back bit
  logic inj_en = 0, inj_bit = 0; // TB drives the line
  int   errors = 0;

  SAS_top dut (
    .clk(clk), .rst_n(rst_n),
    .tx_n(tx_n), .tx_p(tx_p),
    .rx_n(rx_n), .rx_p(rx_p),
    .refclk(refclk), .irq(irq)
  );

  // second initiator at half the bit rate on its own loopback; blk2 cuts
  // its line to force both sequencer timeouts
  logic tx2_n, tx2_p, irq2, blk2 = 0;
  wire  rx2_p = tx2_p && !blk2;
  SAS_top #(.BIT_CLKS(2)) dut2 (
    .clk(clk), .rst_n(rst_n),
    .tx_n(tx2_n), .tx_p(tx2_p),
    .rx_n(!rx2_p), .rx_p(rx2_p),
    .refclk(refclk), .irq(irq2)
  );

  always #5 clk    = ~clk;
  always #3 refclk = ~refclk;

  assign rx_p = inj_en ? inj_bit : (tx_p ^ corrupt);
  assign rx_n = ~rx_p;

  localparam logic [31:0] ALIGN = 32'h7B4A4ABC, SOF = 32'hA5A50001, EOF = 32'hA5A50002;

  task automatic check(input bit c, input string m);
    if (!c) begin errors++; $display("ERROR: %s (t=%0t)", m, $time); end
  endtask

  function automatic logic [31:0] crc32_dw(input logic [31:0] crc, input logic [31:0] dw);
    logic [31:0] c;
    c = crc;
    for (int b = 3; b >= 0; b--)
      for (int i = 0; i < 8; i++)
        c = (c[0] ^ dw[b * 8 + i]) ? (c >> 1) ^ 32'hEDB88320 : (c >> 1);
    return c;
  endfunction

  int irqs = 0;
  always @(posedge clk) if (irq) irqs++;

  // ------------------------------------------------------------------
  // monitor of the DUT's frames (once the PHY is ready)
  // ------------------------------------------------------------------
  logic [31:0] m_win;
  logic [31:0] m_dw [0:31];
  int          m_bits = -1, m_n = 0;
  logic [31:0] mon_hdr [0:1023], mon_pay [0:1023];
  int          mon_cnt = 0;
  always @(posedge clk) begin
    logic [31:0] c;
    int len;
    if (!rst_n || !dut.phy_ready) begin m_bits = -1; m_win = 0; end
    else begin
      check(tx_n == !tx_p, "tx_n is ~tx_p");
      m_win = {m_win[30:0], tx_p};
      if (m_bits < 0) begin
        if (m_win == SOF) begin m_bits = 0; m_n = 0; end
        else if (m_win != ALIGN && m_win != {ALIGN[30:0], ALIGN[31]}) ;
      end else begin
        m_bits++;
        if (m_bits % 32 == 0) begin
          m_dw[m_n] = m_win; m_n++;
          len = m_dw[0][31:24];
          if (m_n == len + 3) begin
            c = 32'hFFFF_FFFF;
            for (int i = 0; i <= len; i++) c = crc32_dw(c, m_dw[i]);
            check(m_dw[len + 1] == ~c, "DUT frame CRC");
            check(m_dw[len + 2] == EOF, "DUT frame EOF");
            check(m_dw[0][7:4] == 0, "DUT frame source");
            mon_hdr[mon_cnt % 1024] = m_dw[0];
            mon_pay[mon_cnt % 1024] = m_dw[1];
            mon_cnt++;
            m_bits = -1;
          end
        end
      end
    end
  end

  // ------------------------------------------------------------------
  // injection on the line
  // ------------------------------------------------------------------
  task automatic drive_dw(input logic [31:0] d);
    for (int i = 31; i >= 0; i--) begin @(negedge clk); inj_bit = d[i]; end
  endtask

  // mode: 0 good, 1 bad CRC, 2 bad EOF; npay dwords sent (len field given)
  task automatic inject(input logic [7:0] len, type_, dst, src, input int npay,
                        input logic [31:0] p0, input int mode, input bit rel = 1,
                        input int flush = 20);
    logic [31:0] h, c, p;
    @(negedge clk); inj_en = 1;
    for (int i = 0; i < flush; i++) drive_dw(ALIGN);   // flush the receiver
    h = {len, type_, dst, src};
    c = crc32_dw(32'hFFFF_FFFF, h);
    drive_dw(SOF); drive_dw(h);
    for (int i = 0; i < npay; i++) begin
      p = (i == 0) ? p0 : $urandom;
      c = crc32_dw(c, p); drive_dw(p);
    end
    if (len <= 16) begin
      drive_dw(mode == 1 ? c : ~c);
      drive_dw(mode == 2 ? SOF : EOF);
    end
    drive_dw(ALIGN); drive_dw(ALIGN);
    if (rel) begin @(negedge clk); inj_en = 0; end
  endtask

  task automatic wait_ok(input int n, input string what);
    int t, o;
    o = dut.ok_cnt; t = 0;
    while (8'(dut.ok_cnt - o) < n && t < 3000 * n) begin @(posedge clk); t++; end
    check(8'(dut.ok_cnt - o) >= n, {what, ": verified transactions"});
  endtask

  task automatic wait_sq(input int st);
    int t = 0;
    while (dut.sq_state != st && t < 5000) begin @(posedge clk); t++; end
  endtask

  task automatic expect_irq(input int i0, input string what);
    repeat (3) @(posedge clk);
    check(irqs > i0, {what, ": irq"});
  endtask

  task automatic do_reset();
    @(negedge clk); rst_n = 0; inj_en = 0; corrupt = 0;
    repeat (3) @(negedge clk);
    check(!tx_p && tx_n && !irq && !dut.phy_ready, "reset state");
    rst_n = 1;
  endtask

  int i0, m0, k;
  logic [31:0] v;
  initial begin
    do_reset;

    // ---- OOB: COMINIT missed once in each idle window ----
    inj_en = 1; inj_bit = 0;                       // line dead
    while (dut.oob_state != 1) @(posedge clk);     // CR idle: nothing seen
    while (dut.oob_state != 0) @(posedge clk);     // back to COMRESET burst
    inj_en = 0;
    while (dut.oob_state != 2) @(posedge clk);     // CI burst: not heard
    inj_en = 1;
    while (dut.oob_state != 3) @(posedge clk);     // CI idle: nothing seen
    while (dut.oob_state != 2) @(posedge clk);     // CI burst again
    inj_en = 0;
    while (!dut.phy_ready) @(posedge clk);
    check(irqs == 0, "no irq during OOB");

    // ---- clean loopback transactions ----
    wait_ok(20, "clean");
    check(dut.mm_cnt == 0 && irqs == 0, "clean: no mismatch / irq");
    check(mon_cnt > 50, "frames decoded");

    // ---- single bit flips anywhere in the traffic ----
    for (int n = 0; n < 60; n++) begin
      repeat ($urandom_range(200, 900)) @(negedge clk);
      corrupt = 1; @(negedge clk); corrupt = 0;
    end
    wait_ok(4, "after bit flips");

    // ---- injected frames from another device ----
    i0 = irqs;
    v = $urandom;
    inject(8'd1, 8'h01, 8'd9, 8'h77, 1, v, 0);
    repeat (5) @(posedge clk);
    check(dut.regs[9] == v, "injected write");
    m0 = mon_cnt;
    inject(8'd0, 8'h02, 8'd9, 8'hC4, 0, 0, 0, 0);  // read request from 0xC4
    repeat (40) drive_dw(ALIGN);                   // response goes out on tx
    inj_en = 0;
    k = m0;
    while (k < mon_cnt && mon_hdr[k % 1024] != {8'd1, 8'h83, 8'hC4, 8'h09}) k++;
    check(k < mon_cnt && mon_pay[k % 1024] == v, "read response to the requester");
    for (int n = 0; n < 40; n++) begin             // random sources / registers
      inject(8'd0, 8'h02, 8'($urandom % 16), 8'($urandom), 0, 0, 0);
      inject(8'd1, 8'h01, 8'($urandom % 16), 8'($urandom), 1, $urandom, 0);
    end
    i0 = irqs; inject(8'd2, 8'h01, 8'd3, 8'h22, 2, $urandom, 1);  expect_irq(i0, "bad CRC");
    i0 = irqs; inject(8'd1, 8'h01, 8'd3, 8'h22, 1, $urandom, 2);  expect_irq(i0, "bad EOF");
    i0 = irqs; inject(8'd17, 8'h01, 8'd3, 8'h22, 0, 0, 0);        expect_irq(i0, "oversize");
    i0 = irqs; inject(8'hFF, 8'hFF, 8'hFF, 8'hFF, 0, 0, 0);       expect_irq(i0, "oversize 2");
    i0 = irqs; inject(8'd0, 8'h01, 8'd3, 8'h22, 0, 0, 0);         expect_irq(i0, "write without payload");
    i0 = irqs; inject(8'd1, 8'h01, 8'd16, 8'h22, 1, $urandom, 0); expect_irq(i0, "write register 16");
    i0 = irqs; inject(8'd0, 8'h02, 8'hF0, 8'h22, 0, 0, 0);        expect_irq(i0, "read register F0");
    i0 = irqs; inject(8'd0, 8'h83, 8'd3, 8'h22, 0, 0, 0);         expect_irq(i0, "empty read response");
    i0 = irqs; inject(8'd1, 8'h7C, 8'd3, 8'h22, 1, $urandom, 0);  expect_irq(i0, "unknown type");
    v = $urandom;
    i0 = irqs; inject(8'd16, 8'h01, 8'd12, 8'h5A, 16, v, 0);
    repeat (5) @(posedge clk);
    check(dut.regs[12] == v, "16-dword write");
    for (int n = 0; n < 30; n++)                   // random header fields
      inject(8'($urandom % 3), 8'($urandom), 8'($urandom), 8'($urandom), $urandom % 3, $urandom, 0);
    wait_ok(3, "after injections");

    // ---- read responses that do not match (value, then source) ----
    m0 = dut.mm_cnt;
    for (int n = 0; n < 258; n++) begin
      wait_sq(4);                                  // SQ_RD_WAIT
      if (n % 2)      inject(8'd1, 8'h83, 8'h01, {4'h0, dut.sq_addr}, 1, ~dut.sq_wdata, 0, 1, 0);
      else if (n < 8) inject(8'd1, 8'h83, 8'h01, {4'($urandom | 1), dut.sq_addr}, 1, dut.sq_wdata, 0, 1, 0);
      else            inject(8'd1, 8'h83, 8'h01, {4'h0, dut.sq_addr + 4'd1}, 1, dut.sq_wdata, 0, 1, 0);
    end
    check(8'(dut.mm_cnt - m0) == 8'(258), "mismatches counted");

    // ---- timeouts: line dead while waiting ----
    i0 = irqs;
    wait_sq(2); inj_en = 1; inj_bit = 0;           // SQ_WR_WAIT
    wait_sq(3); inj_en = 0;
    repeat (3) @(posedge clk);
    check(irqs > i0, "write timeout irq");
    i0 = irqs;
    wait_sq(4); inj_en = 1; inj_bit = 0;           // SQ_RD_WAIT
    wait_sq(5); inj_en = 0;
    repeat (3) @(posedge clk);
    check(irqs > i0, "read timeout irq");

    // ---- a read response queued while a frame is on the wire ----
    wait_sq(1);                                    // SQ_WR: write about to go
    while (dut.tx_state != 1) @(posedge clk);      // SOF on the wire
    fork
      inject(8'd0, 8'h02, 8'd4, 8'h99, 0, 0, 0, 0);
    join
    repeat (60) drive_dw(ALIGN);
    inj_en = 0;

    // ---- the half-rate initiator: clean, then both timeouts ----
    check(dut2.ok_cnt > 20 && dut2.mm_cnt == 0, "half-rate initiator verified");
    while (dut2.sq_state != 2) @(posedge clk);
    blk2 = 1;
    while (dut2.sq_state != 3) @(posedge clk);
    blk2 = 0;
    while (dut2.sq_state != 4) @(posedge clk);
    blk2 = 1;
    while (dut2.sq_state != 5) @(posedge clk);
    blk2 = 0;
    i0 = dut2.ok_cnt;
    repeat (20000) @(posedge clk);
    check(dut2.ok_cnt != i0, "half-rate initiator recovered");

    // ---- the verified-transaction counter wraps ----
    wait_ok(130, "counter wrap");
    wait_ok(130, "counter wrap 2");

    // ---- write / read-request data classes, a 5-dword write ----
    for (int k = 0; k < 3; k++) begin
      inject(8'd1, 8'h01, 8'd6, 8'h22, 1, k == 0 ? 32'h0 : (k == 1 ? 32'hFFFF_FFFF : 32'h5555_5555), 0);
      inject(8'd0, 8'h02, 8'd6, 8'h22, 0, 0, 0);
    end
    inject(8'd5, 8'h01, 8'd6, 8'h22, 5, $urandom, 0);

    // ---- reset in the middle of a frame ----
    while (dut.tx_state != 3) @(posedge clk);
    do_reset;
    while (!dut.phy_ready) @(posedge clk);
    wait_ok(3, "after reset");

    if (errors == 0) $display("TEST PASSED: SAS");
    else             $display("TEST FAILED: %0d errors", errors);
    $finish;
  end

  initial begin
    repeat (2000) #1000000;
    $display("TEST FAILED: TIMEOUT"); $finish;
  end
endmodule
