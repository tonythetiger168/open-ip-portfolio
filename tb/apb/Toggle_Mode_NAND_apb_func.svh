// SPDX-License-Identifier: Apache-2.0
// IP part of Toggle_Mode_NAND_apb_tb: a toggle-mode NAND host model (SDR
// command / address on we_n, DDR data in on dqs, DDR data out on re_n with
// dqs echoed) and a shadow array predicting every page read. Read ID, page
// program / read on every page, 1 -> 0 semantics, column wrap, block erase,
// the protected block, Read Status while busy, return to data with 00h,
// every protocol error through IRQ_STATUS.PROTO (masked and enabled),
// FFh during program / erase / read, ce_n gating, PRESETN mid-program, and
// STATUS.READY against the rb_n pin.
  localparam logic [39:0] DEV_ID = {8'h2C, 8'hA5, 8'h90, 8'h16, 8'h54};
  logic       h_oe = 0, h_dqs_oe = 0, h_dqs = 0;
  logic [7:0] h_dq = 0;
  assign dq  = h_oe ? h_dq : 8'hzz;
  assign dqs = h_dqs_oe ? h_dqs : 1'bz;
  pullup   pu0 (dq[0]), pu1 (dq[1]), pu2 (dq[2]), pu3 (dq[3]),
           pu4 (dq[4]), pu5 (dq[5]), pu6 (dq[6]), pu7 (dq[7]);
  pulldown pd0 (dqs);
  initial begin ce_n = 1; cle = 0; ale = 0; we_n = 1; re_n = 1; end

  logic [7:0] shadow [0:1023];
  logic [7:0] wbuf [0:127];
  logic [7:0] rbuf [0:127];

  // ---------------- SDR command / address ----------------
  task automatic cmd(input logic [7:0] c);
    begin
      ce_n = 0; cle = 1; ale = 0; h_oe = 1; h_dq = c;
      we_n = 0; cycles(4); we_n = 1; cycles(4);
      cle = 0; h_oe = 0;
    end
  endtask
  task automatic addr(input logic [7:0] a);
    begin
      ce_n = 0; ale = 1; cle = 0; h_oe = 1; h_dq = a;
      we_n = 0; cycles(4); we_n = 1; cycles(4);
      ale = 0; h_oe = 0;
    end
  endtask
  task automatic addr5(input int col, input int page);
    begin addr(8'(col)); addr(8'h00); addr(8'(page)); addr(8'h00); addr(8'h00); end
  endtask

  // ---------------- DDR data ----------------
  task automatic din(input int n);
    begin
      h_dqs_oe = 1; h_dqs = 0; h_oe = 1; cycles(3);
      for (int i = 0; i < n; i++) begin
        h_dq = wbuf[i]; cycles(2);
        h_dqs = ~h_dqs; cycles(2);
      end
      cycles(2); h_oe = 0; h_dqs = 0; cycles(1); h_dqs_oe = 0;
    end
  endtask
  // n bytes, one per re_n edge; dqs must follow re_n
  task automatic dout(input int n);
    begin
      for (int i = 0; i < n; i++) begin
        re_n = ~re_n; cycles(5);
        rbuf[i] = dq;
        if (!(dqs === re_n)) fail("dqs does not echo re_n");
      end
      if (!re_n) begin re_n = 1; cycles(5); end
    end
  endtask

  task automatic wait_ready;
    int t;
    begin
      t = 0;
      cycles(4);
      while (rb_n !== 1'b1 && t < 3000) begin cycles(1); t++; end
      if (!(rb_n === 1'b1)) fail("rb_n stuck busy");
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
      if (!(rb_n === 1'b0 || dut.u_core.busy)) fail("program: busy");
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

  bit rd_irq_en = 0;
  // protocol error: PROTO set (and held while the core flag is), FFh clears
  // the core flag, then the w1c clears the register bit
  task automatic expect_irq(input string what);
    cycles(2);
    rd_exp(A_IRQ_STATUS, 1 << IRQ_PROTO);
    wr(A_IRQ_STATUS, 1 << IRQ_PROTO);
    rd_exp(A_IRQ_STATUS, 1 << IRQ_PROTO);             // still held by the core
    if (irq !== rd_irq_en) fail({what, ": irq pin vs enable"});
    cmd(8'hFF); wait_ready();
    if (dut.c_irq !== 1'b0) fail({what, ": FFh did not clear the core flag"});
    wr(A_IRQ_STATUS, 1 << IRQ_PROTO);
    rd_exp(A_IRQ_STATUS, 0);
    if (irq !== 1'b0) fail({what, ": irq pin after clear"});
  endtask

  task automatic ip_func;
    for (int i = 0; i < 1024; i++) shadow[i] = 8'hFF;
    rd_exp(A_STATUS, 1);
    rd_exp(A_FLAGS, 0);
    if (rb_n !== 1'b1 || dq !== 8'hFF) fail("idle bus");

    // ---- Read ID, with wrap ----
    cmd(8'h90); addr(8'h00); dout(7);
    for (int i = 0; i < 7; i++)
      if (rbuf[i] !== DEV_ID[39 - 8 * (i % 5) -: 8]) fail("Read ID byte");

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
    for (int i = 0; i < 64; i++) wbuf[i] = 8'hF0 ^ 8'(i);
    program_page(2, 60, 10);
    read_page(2, 56, 16);
    read_page(5, 63, 3);
    for (int i = 0; i < 64; i++) wbuf[i] = 8'h00;
    program_page(13, 0, 64);
    read_page(13, 0, 64);
    erase(3);

    // ---- STATUS register vs rb_n, status while busy, 00h back to data ----
    cmd(8'h00); addr5(4, 7); cmd(8'h30);
    cycles(3);
    rd_exp(A_STATUS, 0);
    if (rb_n !== 1'b0) fail("rb_n while reading");
    status(8'h80, "status while reading");
    poll(A_STATUS, 1, 1, 50);
    if (rb_n !== 1'b1) fail("rb_n after the read");
    dout(1);
    if (rbuf[0] !== 8'hE0) fail("status kept after the read completes");
    cmd(8'h00);
    dout(8);
    for (int i = 0; i < 8; i++) if (rbuf[i] !== shadow[7 * 64 + 4 + i]) fail("data after 00h");
    for (int i = 0; i < 64; i++) wbuf[i] = 8'h0F;
    cmd(8'h80); addr5(0, 8); din(64); cmd(8'h10);
    status(8'h80, "status while programming");
    wait_ready();
    for (int i = 0; i < 64; i++) shadow[8 * 64 + i] &= 8'h0F;
    status(8'hE0, "status after programming");
    cmd(8'h90); addr(0); dout(1); cmd(8'h00); addr5(0, 8); cmd(8'h30); wait_ready(); dout(4);
    for (int i = 0; i < 4; i++) if (rbuf[i] !== shadow[8 * 64 + i]) fail("read after 00h");

    // ---- protocol errors: first half masked, second half on the irq pin ----
    cmd(8'hAB);                          expect_irq("unknown command");
    cmd(8'h30);                          expect_irq("30h out of sequence");
    cmd(8'h00); addr5(0, 1); cmd(8'h31); expect_irq("wrong read confirm");
    cmd(8'h80); addr5(0, 1); din(2); cmd(8'h11); expect_irq("wrong program confirm");
    cmd(8'h60); addr(4); addr(0); addr(0); cmd(8'hD1); expect_irq("wrong erase confirm");
    wr(A_IRQ_ENABLE, 1 << IRQ_PROTO); rd_irq_en = 1;
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
    cmd(8'h80); addr5(0, 9); din(64); cmd(8'h10); cycles(20); cmd(8'hFF); wait_ready();
    read_page(9, 0, 64);
    cmd(8'h60); addr(8'(9)); addr(0); addr(0); cmd(8'hD0); cycles(50); cmd(8'hFF); wait_ready();
    read_page(9, 0, 4);
    cmd(8'h00); addr5(0, 9); cmd(8'h30); cycles(5); cmd(8'hFF); wait_ready();
    dout(1);
    if (rbuf[0] !== 8'hFF) fail("no data output after a reset read");

    // ---- chip enable gates the bus ----
    ce_n = 1; cle = 1; h_oe = 1; h_dq = 8'hAB; we_n = 0; cycles(4); we_n = 1; cycles(4); cle = 0; h_oe = 0;
    rd_exp(A_IRQ_STATUS, 0);
    cmd(8'h90); addr(0); ce_n = 1; re_n = 0; cycles(5);
    if (dq !== 8'hFF) fail("drives with ce_n high");
    re_n = 1; cycles(5);

    // ---- PRESETN during a program ----
    for (int i = 0; i < 64; i++) wbuf[i] = 8'h00;
    cmd(8'h80); addr5(0, 10); din(4); cmd(8'h10); cycles(10);
    PRESETN = 0; cycles(2);
    if (rb_n !== 1'b1 || irq !== 1'b0 || dq !== 8'hFF) fail("PRESETN mid-program");
    PRESETN = 1; cycles(2);
    check_reset_values();
    for (int i = 0; i < 1024; i++) shadow[i] = 8'hFF;
    read_page(10, 0, 8);

    // leave PROTO pending (masked) for the final reset
    cmd(8'hAB); cycles(2);
    rd_exp(A_IRQ_STATUS, 1 << IRQ_PROTO);
    if (irq !== 1'b0) fail("masked PROTO drives the pin");
  endtask
