// SPDX-License-Identifier: Apache-2.0
// Self-checking testbench for Toggle_Mode_NAND_top -- toggle-mode NAND host
// Commands and addresses are SDR (we_n rising edge); data is DDR: the host
// drives dqs edges for data input, and toggles re_n for data output while
// the target echoes re_n on dqs. A shadow array predicts every page read.
// Covered: Read ID with wrap, page program / read on every page, 1 -> 0
// program semantics, column offsets and wrap at the page end, block erase,
// the protected block (FAIL), Read Status while busy and after, return to
// read data with 00h, unknown and out-of-sequence commands, address cycles
// out of place, commands while busy, reset (FFh) during program / erase /
// read, chip enable gating and an rst_n during an operation.
`timescale 1ns/1ps
module Toggle_Mode_NAND_tb;
  logic clk = 0, rst_n = 0;
  logic ce_n = 1, cle = 0, ale = 0, we_n = 1, re_n = 1;
  tri1  [7:0] dq;
  tri0        dqs;
  wire        rb_n, irq;
  logic       h_oe = 0, h_dqs_oe = 0, h_dqs = 0;
  logic [7:0] h_dq = 0;
  assign dq  = h_oe ? h_dq : 8'hzz;
  assign dqs = h_dqs_oe ? h_dqs : 1'bz;

  int errors = 0;
  localparam logic [39:0] DEV_ID = {8'h2C, 8'hA5, 8'h90, 8'h16, 8'h54};

  Toggle_Mode_NAND_top dut (
    .clk(clk), .rst_n(rst_n),
    .ce_n(ce_n), .cle(cle), .ale(ale), .we_n(we_n), .re_n(re_n),
    .dq(dq), .dqs(dqs), .rb_n(rb_n), .irq(irq)
  );
  always #5 clk = ~clk;

  task automatic check(input bit cond, input string msg);
    if (!cond) begin errors++; $display("ERROR: %s (time %0t)", msg, $time); end
  endtask

  logic [7:0] shadow [0:1023];
  logic [7:0] wbuf [0:127];
  logic [7:0] rbuf [0:127];

  task automatic wclk(input int n);
    repeat (n) @(negedge clk);
  endtask

  // ---------------- SDR command / address ----------------
  task automatic cmd(input logic [7:0] c);
    begin
      ce_n = 0; cle = 1; ale = 0; h_oe = 1; h_dq = c;
      we_n = 0; wclk(4); we_n = 1; wclk(4);
      cle = 0; h_oe = 0;
    end
  endtask
  task automatic addr(input logic [7:0] a);
    begin
      ce_n = 0; ale = 1; cle = 0; h_oe = 1; h_dq = a;
      we_n = 0; wclk(4); we_n = 1; wclk(4);
      ale = 0; h_oe = 0;
    end
  endtask
  task automatic addr5(input int col, input int page);
    begin addr(8'(col)); addr(8'h00); addr(8'(page)); addr(8'h00); addr(8'h00); end
  endtask

  // ---------------- DDR data ----------------
  task automatic din(input int n);
    begin
      h_dqs_oe = 1; h_dqs = 0; h_oe = 1; wclk(3);
      for (int i = 0; i < n; i++) begin
        h_dq = wbuf[i]; wclk(2);
        h_dqs = ~h_dqs; wclk(2);
      end
      wclk(2); h_oe = 0; h_dqs = 0; wclk(1); h_dqs_oe = 0;
    end
  endtask
  // n bytes, one per re_n edge; dqs must follow re_n
  task automatic dout(input int n);
    begin
      for (int i = 0; i < n; i++) begin
        re_n = ~re_n; wclk(5);
        rbuf[i] = dq;
        check(dqs === re_n, "dqs does not echo re_n");
      end
      if (!re_n) begin re_n = 1; wclk(5); end
    end
  endtask

  task automatic wait_ready;
    int t;
    begin
      t = 0;
      wclk(4);
      while (rb_n !== 1'b1 && t < 3000) begin wclk(1); t++; end
      check(rb_n === 1'b1, "rb_n stuck busy");
    end
  endtask

  task automatic status(input logic [7:0] exp, input string what);
    begin
      cmd(8'h70);
      dout(1);
      if (rbuf[0] !== exp) begin errors++; $display("ERROR: %s: status %h exp %h", what, rbuf[0], exp); end
    end
  endtask

  task automatic program_page(input int page, input int col, input int n);
    begin
      cmd(8'h80); addr5(col, page); din(n); cmd(8'h10);
      check(rb_n === 1'b0 || dut.busy, "program: busy");
      wait_ready();
      if (page < 12) for (int i = 0; i < n; i++) shadow[page * 64 + (col + i) % 64] &= wbuf[i];
      status(page < 12 ? 8'hE0 : 8'hE1, "after program");
    end
  endtask

  task automatic read_page(input int page, input int col, input int n);
    begin
      cmd(8'h00); addr5(col, page); cmd(8'h30);
      wait_ready();
      dout(n);
      for (int i = 0; i < n; i++)
        if (rbuf[i] !== shadow[page * 64 + (col + i) % 64]) begin
          errors++; $display("ERROR: read page %0d col %0d+%0d got %h exp %h", page, col, i, rbuf[i],
                             shadow[page * 64 + (col + i) % 64]);
        end
    end
  endtask

  task automatic erase(input int blk);
    begin
      cmd(8'h60); addr(8'(blk * 4)); addr(8'h00); addr(8'h00); cmd(8'hD0);
      wait_ready();
      if (blk != 3) for (int i = 0; i < 256; i++) shadow[blk * 256 + i] = 8'hFF;
      status(blk != 3 ? 8'hE0 : 8'hE1, "after erase");
    end
  endtask

  task automatic expect_irq(input string what);
    begin
      wclk(2);
      check(irq === 1'b1, {what, ": no irq"});
      cmd(8'hFF); wait_ready();
      check(irq === 1'b0, {what, ": FFh did not clear irq"});
    end
  endtask

  initial begin
    for (int i = 0; i < 1024; i++) shadow[i] = 8'hFF;
    wclk(4);
    check(rb_n === 1'b1 && irq === 1'b0 && dq === 8'hFF, "reset state");
    rst_n = 1;
    wclk(4);

    // ---- Read ID, with wrap ----
    cmd(8'h90); addr(8'h00); dout(7);
    for (int i = 0; i < 7; i++) check(rbuf[i] === DEV_ID[39 - 8 * (i % 5) -: 8], "Read ID byte");

    // ---- every page: program 0x00 and erase (all bits), then patterns ----
    for (int p = 0; p < 16; p++) begin
      for (int i = 0; i < 64; i++) wbuf[i] = 8'h00;
      program_page(p, 0, 64);
    end
    for (int p = 0; p < 16; p += 5) read_page(p, 0, 64);
    for (int b = 0; b < 4; b++) erase(b);
    read_page(1, 0, 64);
    for (int p = 0; p < 12; p++) begin
      for (int i = 0; i < 64; i++) wbuf[i] = $urandom;
      program_page(p, 0, 64);
      read_page(p, 0, 64);
    end
    // 1 -> 0 only, column offset with wrap at the page end, short reads
    for (int i = 0; i < 64; i++) wbuf[i] = 8'hF0 ^ 8'(i);
    program_page(2, 60, 10);
    read_page(2, 56, 16);
    read_page(5, 63, 3);
    // protected block
    for (int i = 0; i < 64; i++) wbuf[i] = 8'h00;
    program_page(13, 0, 64);
    read_page(13, 0, 64);
    erase(3);

    // ---- status while busy, return to data with 00h ----
    cmd(8'h00); addr5(4, 7); cmd(8'h30);
    status(8'h80, "status while reading");
    wait_ready();
    dout(1);
    check(rbuf[0] === 8'hE0, "status kept after the read completes");
    cmd(8'h00);
    dout(8);
    for (int i = 0; i < 8; i++) check(rbuf[i] === shadow[7 * 64 + 4 + i], "data after 00h");
    for (int i = 0; i < 64; i++) wbuf[i] = 8'h0F;
    cmd(8'h80); addr5(0, 8); din(64); cmd(8'h10);
    status(8'h80, "status while programming");
    wait_ready();
    for (int i = 0; i < 64; i++) shadow[8 * 64 + i] &= 8'h0F;
    status(8'hE0, "status after programming");
    // 00h with no read done: just starts a read sequence
    cmd(8'h90); addr(0); dout(1); cmd(8'h00); addr5(0, 8); cmd(8'h30); wait_ready(); dout(4);
    for (int i = 0; i < 4; i++) check(rbuf[i] === shadow[8 * 64 + i], "read after 00h");

    // ---- protocol errors ----
    cmd(8'hAB);                          expect_irq("unknown command");
    cmd(8'h30);                          expect_irq("30h out of sequence");
    cmd(8'h00); addr5(0, 1); cmd(8'h31); expect_irq("wrong read confirm");
    cmd(8'h80); addr5(0, 1); din(2); cmd(8'h11); expect_irq("wrong program confirm");
    cmd(8'h60); addr(4); addr(0); addr(0); cmd(8'hD1); expect_irq("wrong erase confirm");
    cmd(8'h00); addr(0); cmd(8'h90);     expect_irq("command inside an address phase");
    cmd(8'h60); addr(4); cmd(8'h70);     dout(1); expect_irq("70h inside an address phase");
    cmd(8'h90); cmd(8'h90);              expect_irq("90h without address");
    addr(8'h12);                         expect_irq("address with no command");
    cmd(8'h90); addr(0); dout(2);
    addr(8'h12);                         expect_irq("address while driving ID");
    cmd(8'h60); addr(8); addr(0); addr(0); cmd(8'hD0);
    cmd(8'h90);                          expect_irq("command while busy");
    erase(1);

    // ---- reset during operations ----
    for (int i = 0; i < 64; i++) wbuf[i] = 8'h00;
    cmd(8'h80); addr5(0, 9); din(64); cmd(8'h10); wclk(20); cmd(8'hFF); wait_ready();
    read_page(9, 0, 64);
    cmd(8'h60); addr(8'(9)); addr(0); addr(0); cmd(8'hD0); wclk(50); cmd(8'hFF); wait_ready();
    read_page(9, 0, 4);
    cmd(8'h00); addr5(0, 9); cmd(8'h30); wclk(5); cmd(8'hFF); wait_ready();
    dout(1);
    check(rbuf[0] === 8'hFF, "no data output after a reset read");

    // ---- chip enable gates the bus ----
    ce_n = 1; cle = 1; h_oe = 1; h_dq = 8'hAB; we_n = 0; wclk(4); we_n = 1; wclk(4); cle = 0; h_oe = 0;
    check(irq === 1'b0, "strobe with ce_n high was taken");
    cmd(8'h90); addr(0); ce_n = 1; re_n = 0; wclk(5); check(dq === 8'hFF, "drives with ce_n high"); re_n = 1; wclk(5);

    // ---- rst_n during a program ----
    for (int i = 0; i < 64; i++) wbuf[i] = 8'h00;
    cmd(8'h80); addr5(0, 10); din(4); cmd(8'h10); wclk(10);
    rst_n = 0; wclk(2);
    check(rb_n === 1'b1 && irq === 1'b0 && dq === 8'hFF, "rst_n mid-program");
    rst_n = 1; wclk(2);
    for (int i = 0; i < 1024; i++) shadow[i] = 8'hFF;
    read_page(10, 0, 8);

    if (errors == 0) $display("TEST PASSED: Toggle_Mode_NAND");
    else             $display("TEST FAILED: %0d errors", errors);
    $finish;
  end

  initial begin
    repeat (3000) #1000;
    $display("TEST FAILED: TIMEOUT"); $finish;
  end
endmodule
