// SPDX-License-Identifier: Apache-2.0
// ============================================================================
// Self-checking testbench for SDIO_top -- SD host model on CMD / DAT[3:0]
// The host drives on sd_clk falling edges and samples on rising edges. A
// shadow of the function-1 register file predicts every R5 data field and
// every CMD53 read block; every response CRC7, data CRC16 and CRC status
// token is checked. Covered: CMD52 read/write (RAW and not), CMD53 write
// and read in 4-bit mode for 1..32 bytes, incrementing and fixed address,
// R5 flags (COM_CRC_ERROR, ILLEGAL_COMMAND, FUNCTION_NUMBER, OUT_OF_RANGE),
// bad CRC7 / framing, unsupported commands and block mode, bad data CRC16 /
// end bits (CRC status 101), a missing write block, a reset mid-transfer,
// random traffic, and a second card with BIT_CLKS = 2.
// -- Apache-2.0
// Open IP design implementation v2.5
// ============================================================================
`timescale 1ns/1ps
module SDIO_tb;
  logic      clk = 0, rst_n = 0, sd_clk = 0;
  tri1       cmd1, cmd2;
  tri1 [3:0] dat1, dat2;
  wire       irq1, irq2;

  // host drivers, routed to the selected card's bus
  bit         sel = 0;
  int         bc = 1;                    // sd_clk cycles per bit of that card
  logic       h_cmd_oe = 0, h_cmd = 1;
  logic       h_dat_oe = 0;
  logic [3:0] h_dat = 4'hF;
  assign cmd1 = (!sel && h_cmd_oe) ? h_cmd : 1'bz;
  assign cmd2 = ( sel && h_cmd_oe) ? h_cmd : 1'bz;
  for (genvar l = 0; l < 4; l++) begin : g_h
    assign dat1[l] = (!sel && h_dat_oe) ? h_dat[l] : 1'bz;
    assign dat2[l] = ( sel && h_dat_oe) ? h_dat[l] : 1'bz;
  end
  wire       cmd_s = sel ? cmd2 : cmd1;
  wire [3:0] dat_s = sel ? dat2 : dat1;
  wire       irq   = sel ? irq2 : irq1;

  SDIO_top dut (.clk(clk), .rst_n(rst_n), .sd_clk(sd_clk), .cmd(cmd1), .dat(dat1), .irq(irq1));
  SDIO_top #(.BIT_CLKS(2)) dut2 (.clk(clk), .rst_n(rst_n), .sd_clk(sd_clk), .cmd(cmd2), .dat(dat2), .irq(irq2));

  always #5  clk    = ~clk;
  always #10 sd_clk = ~sd_clk;

  int errors = 0;
  bit irq_seen = 0;
  always @(posedge sd_clk) if (irq) irq_seen = 1;

  task automatic check(input bit cond, input string msg);
    if (!cond) begin errors++; $display("ERROR: %s (time %0t)", msg, $time); end
  endtask

  // ---------------- CRCs ----------------
  function automatic logic [6:0] crc7(input logic [39:0] m);
    logic [6:0] c;
    c = 0;
    for (int i = 39; i >= 0; i--) c = {c[5:0], 1'b0} ^ ((c[6] ^ m[i]) ? 7'h09 : 7'h00);
    return c;
  endfunction
  function automatic logic [15:0] crc16_step(input logic [15:0] c, input logic b);
    return {c[14:0], 1'b0} ^ ((c[15] ^ b) ? 16'h1021 : 16'h0000);
  endfunction

  // ---------------- shadow + block buffers ----------------
  logic [7:0] shadow [0:127];
  logic [7:0] blk [0:31];
  logic [7:0] rblk [0:31];

  // one bit time of the selected card
  task automatic tick;
    repeat (bc) @(negedge sd_clk);
  endtask
  task automatic tick_s;                  // sample point: rising edge inside the bit
    begin repeat (bc) @(posedge sd_clk); #1; end
  endtask

  // ---------------- command / response ----------------
  task automatic send_cmd(input logic [5:0] idx, input logic [31:0] arg, input int bad);
    logic [47:0] f;
    begin
      f = {1'b0, 1'b1, idx, arg, 7'h0, 1'b1};
      f[7:1] = crc7(f[47:8]);
      if (bad == 1) f[1] = ~f[1];          // CRC7
      if (bad == 2) f[0] = 1'b0;           // end bit
      if (bad == 3) f[46] = 1'b0;          // transmission bit
      @(negedge sd_clk);
      for (int i = 47; i >= 0; i--) begin h_cmd_oe = 1; h_cmd = f[i]; tick(); end
      h_cmd_oe = 0;
    end
  endtask

  bit rd_next = 0;                        // a read block follows the R5
  task automatic recv_rsp(output logic [47:0] r, output bit got);
    int t;
    begin
      t = 0; got = 0; r = '1;
      #1;                                 // let the host's release settle
      while (cmd_s !== 1'b0 && t < 80) begin tick_s(); t++; end
      if (cmd_s === 1'b0) begin
        got = 1;
        r[47] = 0;
        for (int i = 46; i >= 0; i--) begin tick_s(); r[i] = cmd_s; end
        check(r[46] === 1'b0 && r[0] === 1'b1 && r[7:1] === crc7(r[47:8]), "R5 framing / CRC7");
      end
      if (!rd_next) repeat (8) tick_s();  // N_RC before the next command
    end
  endtask

  // command with an R5: checks index, flags and data
  task automatic cmd_r5(input logic [5:0] idx, input logic [31:0] arg, input logic [7:0] fl,
                        input logic [7:0] d, input string what);
    logic [47:0] r;
    bit got;
    begin
      send_cmd(idx, arg, 0);
      recv_rsp(r, got);
      check(got, {what, ": no R5"});
      if (got) begin
        check(r[45:40] === idx && r[39:24] === 16'h0, {what, ": R5 index"});
        if (r[23:16] !== fl) begin errors++; $display("ERROR: %s: R5 flags %h exp %h", what, r[23:16], fl); end
        if (r[15:8] !== d) begin errors++; $display("ERROR: %s: R5 data %h exp %h", what, r[15:8], d); end
      end
    end
  endtask

  // no response expected
  task automatic cmd_none(input logic [5:0] idx, input logic [31:0] arg, input int bad, input string what);
    logic [47:0] r;
    bit got;
    begin
      irq_seen = 0;
      send_cmd(idx, arg, bad);
      recv_rsp(r, got);
      check(!got, {what, ": unexpected response"});
      check(irq_seen, {what, ": no irq"});
    end
  endtask

  logic [7:0] pend;                       // flags owed to the next R5
  function automatic logic [31:0] a52(input bit wr, input int fn, input bit raw, input int addr, input logic [7:0] d);
    return {wr, 3'(fn), raw, 1'b0, 17'(addr), 1'b0, d};
  endfunction
  function automatic logic [31:0] a53(input bit wr, input int fn, input bit blkm, input bit inc, input int addr, input int n);
    return {wr, 3'(fn), blkm, inc, 17'(addr), 9'(n)};
  endfunction

  task automatic cmd52(input bit wr, input int addr, input logic [7:0] d, input bit raw);
    logic [7:0] exp;
    begin
      if (wr) shadow[addr] = d;
      exp = shadow[addr];
      cmd_r5(6'd52, a52(wr, 1, raw, addr, d), pend | 8'h10, exp, "CMD52");
      pend = 0;
    end
  endtask

  // ---------------- data blocks ----------------
  task automatic send_block(input int n, input int bad);   // bad: 1 CRC, 2 end bits
    logic [15:0] c [0:3];
    begin
      for (int l = 0; l < 4; l++) c[l] = 0;
      @(negedge sd_clk);
      repeat (2) tick();
      h_dat_oe = 1; h_dat = 4'h0; tick();
      for (int k = 0; k < 2 * n; k++) begin
        h_dat = k % 2 ? blk[k / 2][3:0] : blk[k / 2][7:4];
        for (int l = 0; l < 4; l++) c[l] = crc16_step(c[l], h_dat[l]);
        tick();
      end
      if (bad == 1) c[2] = c[2] ^ 16'h0100;
      for (int i = 15; i >= 0; i--) begin
        for (int l = 0; l < 4; l++) h_dat[l] = c[l][i];
        tick();
      end
      h_dat = bad == 2 ? 4'b1101 : 4'b1111; tick();
      h_dat_oe = 0;
    end
  endtask

  task automatic recv_status(input bit ok);
    logic [2:0] st;
    int t;
    begin
      t = 0;
      while (dat_s[0] !== 1'b0 && t < 20) begin tick_s(); t++; end
      check(dat_s[0] === 1'b0, "CRC status start bit");
      for (int i = 2; i >= 0; i--) begin tick_s(); st[i] = dat_s[0]; end
      tick_s();
      check(dat_s[0] === 1'b1, "CRC status end bit");
      check(st === (ok ? 3'b010 : 3'b101), $sformatf("CRC status %b", st));
      repeat (4) tick_s();
    end
  endtask

  task automatic recv_block(input int n);
    logic [15:0] c [0:3];
    logic [15:0] g [0:3];
    logic [3:0] nb;
    int t;
    begin
      for (int l = 0; l < 4; l++) c[l] = 0;
      t = 0;
      while (dat_s !== 4'h0 && t < 40) begin tick_s(); t++; end
      check(dat_s === 4'h0, "read block start bits");
      for (int k = 0; k < 2 * n; k++) begin
        tick_s(); nb = dat_s;
        for (int l = 0; l < 4; l++) c[l] = crc16_step(c[l], nb[l]);
        if (k % 2 == 0) rblk[k / 2][7:4] = nb; else rblk[k / 2][3:0] = nb;
      end
      for (int i = 15; i >= 0; i--) begin
        tick_s();
        for (int l = 0; l < 4; l++) g[l][i] = dat_s[l];
      end
      for (int l = 0; l < 4; l++) check(g[l] === c[l], "read block CRC16");
      tick_s();
      check(dat_s === 4'hF, "read block end bits");
      repeat (4) tick_s();
    end
  endtask

  task automatic cmd53_write(input int addr, input int n, input bit inc, input int bad);
    begin
      cmd_r5(6'd53, a53(1, 1, 0, inc, addr, n), pend | 8'h10, 8'h00, "CMD53 write");
      pend = 0;
      irq_seen = 0;
      send_block(n, bad);
      recv_status(bad == 0);
      check(irq_seen == (bad != 0), "CMD53 write irq");
      if (bad == 0) for (int k = 0; k < n; k++) shadow[inc ? addr + k : addr] = blk[k];
    end
  endtask

  task automatic cmd53_read(input int addr, input int n, input bit inc);
    begin
      rd_next = 1;
      cmd_r5(6'd53, a53(0, 1, 0, inc, addr, n), pend | 8'h10, 8'h00, "CMD53 read");
      rd_next = 0;
      pend = 0;
      recv_block(n);
      for (int k = 0; k < n; k++)
        if (rblk[k] !== shadow[inc ? addr + k : addr]) begin
          errors++; $display("ERROR: CMD53 read %0d+%0d got %h exp %h", addr, k, rblk[k], shadow[inc ? addr + k : addr]);
        end
    end
  endtask

  task automatic quiet;
    repeat (4) tick();
  endtask

  // ---------------- the test ----------------
  task automatic run_card(input bit full);
    begin
      pend = 0;
      for (int i = 0; i < 128; i++) shadow[i] = 0;
      // CMD52 write / read, every register; RAW and not
      for (int a = 0; a < 128; a++) cmd52(1, a, 8'(a * 37 + 5), a[0]);
      for (int a = 0; a < 128; a += full ? 1 : 9) cmd52(0, a, 8'hEE, 0);
      // CMD53: every count, incrementing
      for (int n = 1; n <= 32; n += full ? 1 : 7) begin
        for (int k = 0; k < 32; k++) blk[k] = $urandom;
        cmd53_write(96 - n, n, 1, 0);
        cmd53_read(96 - n, n, 1);
        quiet();
      end
      // fixed address: the last byte wins, a read repeats one register
      for (int k = 0; k < 32; k++) blk[k] = 8'(k + 1);
      cmd53_write(5, 4, 0, 0); cmd53_read(5, 3, 0);
      // up to the last register
      cmd53_write(96, 32, 1, 0); cmd53_read(96, 32, 1);
      // all bits through the block path
      for (int k = 0; k < 32; k++) blk[k] = 8'hFF;
      cmd53_write(0, 32, 1, 0); cmd53_read(0, 32, 1);
      for (int k = 0; k < 32; k++) blk[k] = 8'h00;
      cmd53_write(0, 32, 1, 0); cmd53_read(0, 32, 1);
      for (int k = 0; k < 32; k++) blk[k] = 8'hFF;
      cmd53_write(32, 32, 1, 0); cmd53_write(64, 32, 1, 0); cmd53_write(96, 32, 1, 0);
      for (int k = 0; k < 32; k++) blk[k] = 8'h00;
      cmd53_write(32, 32, 1, 0); cmd53_write(64, 32, 1, 0); cmd53_write(96, 32, 1, 0);

      // errors: no response, flag in the next R5
      cmd_none(6'd52, a52(0, 1, 0, 3, 0), 1, "bad CRC7");      pend = 8'h80; cmd52(0, 3, 0, 0);
      cmd_none(6'd52, a52(0, 1, 0, 3, 0), 2, "bad end bit");   pend = 8'h80; cmd52(0, 3, 0, 0);
      cmd_none(6'd52, a52(0, 1, 0, 3, 0), 3, "bad tx bit");    pend = 8'h80; cmd52(0, 3, 0, 0);
      cmd_none(6'd5,  32'h0, 0, "CMD5 unsupported");            pend = 8'h40; cmd52(0, 3, 0, 0);
      cmd_none(6'd53, a53(1, 1, 1, 1, 0, 1), 0, "block mode");  pend = 8'h40;
      cmd_none(6'd52, a52(0, 1, 0, 3, 0), 1, "bad CRC7 after");  pend = 8'hC0; cmd52(0, 3, 0, 0);
      // answered, not executed
      cmd_r5(6'd52, a52(1, 0, 0, 3, 8'h77), 8'h12, 8'h00, "function 0");
      cmd_r5(6'd52, a52(1, 7, 0, 3, 8'h77), 8'h12, 8'h00, "function 7");
      cmd_r5(6'd52, a52(1, 1, 0, 128, 8'h77), 8'h11, 8'h00, "address 128");
      cmd_r5(6'd52, a52(0, 1, 0, 17'h1FFFF, 0), 8'h11, 8'h00, "address 1FFFF");
      cmd_r5(6'd53, a53(0, 1, 0, 1, 0, 0), 8'h11, 8'h00, "count 0 (512)");
      cmd_r5(6'd53, a53(1, 1, 0, 1, 0, 33), 8'h11, 8'h00, "count 33");
      cmd_r5(6'd53, a53(1, 1, 0, 1, 0, 511), 8'h11, 8'h00, "count 511");
      cmd_r5(6'd53, a53(0, 1, 0, 1, 100, 29), 8'h11, 8'h00, "past address 127");
      cmd_r5(6'd53, a53(0, 2, 0, 1, 200, 40), 8'h13, 8'h00, "function and range");
      cmd53_read(100, 28, 1);                                 // just fits
      cmd53_read(127, 32, 0);                                 // fixed address at 127
      cmd52(0, 3, 0, 0);
      // bad data: CRC status 101, block discarded
      for (int k = 0; k < 32; k++) blk[k] = 8'hA5;
      cmd53_write(40, 8, 1, 1); cmd53_read(40, 8, 1);
      cmd53_write(40, 8, 1, 2); cmd53_read(40, 8, 1);
      // a write block that never comes
      cmd_r5(6'd53, a53(1, 1, 0, 1, 10, 2), 8'h10, 8'h00, "write without block");
      irq_seen = 0;
      repeat (80) tick();
      check(irq_seen, "missing write block: irq");
      cmd53_read(10, 2, 1);

      // random traffic
      for (int t = 0; t < (full ? 60 : 10); t++) begin
        int n, a, r;
        n = $urandom_range(1, 32);
        a = $urandom_range(0, 128 - n);
        r = $urandom_range(0, 3);
        for (int k = 0; k < 32; k++) blk[k] = $urandom;
        case (r)
          0: cmd53_write(a, n, 1, 0);
          1: cmd53_read(a, n, $urandom_range(0, 1));
          2: cmd52(1, $urandom_range(0, 127), 8'($urandom), $urandom_range(0, 1));
          default: cmd52(0, $urandom_range(0, 127), 0, 0);
        endcase
      end
    end
  endtask

  initial begin
    repeat (3) @(negedge sd_clk);
    check(cmd1 === 1'b1 && dat1 === 4'hF && irq1 === 1'b0, "reset: lines released");
    rst_n = 1;
    repeat (3) @(negedge sd_clk);
    run_card(1);

    // reset in the middle of a read block, and of a status token
    for (int k = 0; k < 32; k++) blk[k] = $urandom;
    cmd_r5(6'd53, a53(0, 1, 0, 1, 0, 32), 8'h10, 8'h00, "read before reset");
    repeat (30) tick();
    @(negedge sd_clk) rst_n = 0;
    repeat (2) @(negedge sd_clk);
    check(cmd1 === 1'b1 && dat1 === 4'hF, "reset mid-block releases the lines");
    rst_n = 1;
    repeat (2) @(negedge sd_clk);
    for (int i = 0; i < 128; i++) shadow[i] = 0;
    cmd52(0, 0, 0, 0);
    cmd_r5(6'd53, a53(1, 1, 0, 1, 0, 1), 8'h10, 8'h00, "write before reset");
    send_block(1, 0);
    repeat (3) tick();
    @(negedge sd_clk) rst_n = 0;
    repeat (2) @(negedge sd_clk);
    rst_n = 1;
    repeat (2) @(negedge sd_clk);

    // second card, two sd_clk per bit
    sel = 1; bc = 2;
    quiet();
    run_card(0);

    // classes left by the main run: function errors on a CMD52 read and a
    // CMD53 write, fixed-address CMD53 of one and 32 bytes, CMD52 writes
    // of all zeros and all ones
    cmd_r5(6'd52, a52(0, 0, 0, 3, 0), 8'h12, 8'h00, "read function 0");
    cmd_r5(6'd53, a53(1, 0, 0, 1, 0, 1), 8'h12, 8'h00, "CMD53 write function 0");
    for (int k = 0; k < 32; k++) blk[k] = 8'(k * 3 + 1);
    cmd53_write(7, 1, 0, 0); cmd53_read(7, 1, 0);
    cmd53_write(9, 32, 0, 0); cmd53_read(9, 1, 0);
    cmd52(1, 20, 8'h00, 0); cmd52(1, 21, 8'hFF, 0);
    cmd52(0, 20, 0, 0); cmd52(0, 21, 0, 0);

    if (errors == 0) $display("TEST PASSED: SDIO");
    else             $display("TEST FAILED: %0d errors", errors);
    $finish;
  end

  initial begin
    repeat (200) #100000;
    $display("TEST FAILED: TIMEOUT"); $finish;
  end
endmodule
