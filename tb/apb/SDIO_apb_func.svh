// SPDX-License-Identifier: Apache-2.0
// IP part of SDIO_apb_tb: the core TB's SD host model (commands, R5
// checks, 4-bit data blocks with CRC16 and status tokens, a shadow of the
// function 1 registers) drives the card; ERR is checked through the
// registers for every faulty command or data block.
  logic       h_cmd_oe = 0, h_cmd = 1;
  logic       h_dat_oe = 0;
  logic [3:0] h_dat = 4'hF;
  int         bc = 1;
  pullup (cmd);
  pullup (dat[0]); pullup (dat[1]); pullup (dat[2]); pullup (dat[3]);
  assign cmd = h_cmd_oe ? h_cmd : 1'bz;
  assign dat = h_dat_oe ? h_dat : 4'bzzzz;
  initial sd_clk = 0;
  always #10 sd_clk = ~sd_clk;
  bit irq_seen = 0;
  always @(posedge sd_clk) if (dut.c_irq) irq_seen = 1;
  task automatic check(input bit c, input string m);
    if (!c) fail(m);
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
      while (cmd !== 1'b0 && t < 80) begin tick_s(); t++; end
      if (cmd === 1'b0) begin
        got = 1;
        r[47] = 0;
        for (int i = 46; i >= 0; i--) begin tick_s(); r[i] = cmd; end
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
        if (r[23:16] !== fl) fail($sformatf("%s: R5 flags %h exp %h", what, r[23:16], fl));
        if (r[15:8] !== d) fail($sformatf("%s: R5 data %h exp %h", what, r[15:8], d));
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
      while (dat[0] !== 1'b0 && t < 20) begin tick_s(); t++; end
      check(dat[0] === 1'b0, "CRC status start bit");
      for (int i = 2; i >= 0; i--) begin tick_s(); st[i] = dat[0]; end
      tick_s();
      check(dat[0] === 1'b1, "CRC status end bit");
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
      while (dat !== 4'h0 && t < 40) begin tick_s(); t++; end
      check(dat === 4'h0, "read block start bits");
      for (int k = 0; k < 2 * n; k++) begin
        tick_s(); nb = dat;
        for (int l = 0; l < 4; l++) c[l] = crc16_step(c[l], nb[l]);
        if (k % 2 == 0) rblk[k / 2][7:4] = nb; else rblk[k / 2][3:0] = nb;
      end
      for (int i = 15; i >= 0; i--) begin
        tick_s();
        for (int l = 0; l < 4; l++) g[l][i] = dat[l];
      end
      for (int l = 0; l < 4; l++) check(g[l] === c[l], "read block CRC16");
      tick_s();
      check(dat === 4'hF, "read block end bits");
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

  // ERR after a faulty command or block: set (then cleared)
  task automatic err_is(input bit v, input string m);
    rd(A_IRQ_STATUS);
    if (rdv[IRQ_ERR] !== v) fail({"ERR: ", m});
    wr(A_IRQ_STATUS, IRQ_ALL);
  endtask

  task automatic ip_func;
    pend = 0;
    rd_exp(A_FLAGS, 0);
    for (int i = 0; i < 128; i++) shadow[i] = 0;
    for (int a = 0; a < 128; a += 5) cmd52(1, a, 8'(a * 37 + 5), a[0]);
    for (int a = 0; a < 128; a += 15) cmd52(0, a, 8'hEE, 0);
    for (int n = 1; n <= 32; n += 10) begin
      for (int k = 0; k < 32; k++) blk[k] = $urandom;
      cmd53_write(96 - n, n, 1, 0);
      cmd53_read(96 - n, n, 1);
      quiet();
    end
    err_is(0, "clean traffic");
    // errors: no response, ERR (masked first), flag in the next R5
    cmd_none(6'd52, a52(0, 1, 0, 3, 0), 1, "bad CRC7");
    err_is(1, "bad CRC7");
    if (irq) fail("masked ERR drives the pin");
    pend = 8'h80; cmd52(0, 3, 0, 0);
    wr(A_IRQ_ENABLE, IRQ_ALL);
    cmd_none(6'd5, 32'h0, 0, "CMD5 unsupported");
    if (!irq) fail("ERR drives the pin");
    err_is(1, "unsupported command");
    if (irq) fail("irq after clear");
    pend = 8'h40; cmd52(0, 3, 0, 0);
    cmd_r5(6'd52, a52(1, 1, 0, 128, 8'h77), 8'h11, 8'h00, "address 128");
    err_is(0, "out of range is answered");
    // bad data: CRC status 101, block discarded
    for (int k = 0; k < 32; k++) blk[k] = 8'hA5;
    cmd53_write(40, 8, 1, 1); err_is(1, "data CRC16"); cmd53_read(40, 8, 1);
    cmd53_write(40, 8, 1, 2); err_is(1, "data end bits"); cmd53_read(40, 8, 1);
    // a write block that never comes
    cmd_r5(6'd53, a53(1, 1, 0, 1, 10, 2), 8'h10, 8'h00, "write without block");
    repeat (80) tick();
    err_is(1, "missing write block");
    cmd53_read(10, 2, 1);
    err_is(0, "clean again");
    // an error left pending into reset
    cmd_none(6'd52, a52(0, 1, 0, 3, 0), 3, "bad tx bit");
    rd(A_IRQ_STATUS);
    if (!rdv[IRQ_ERR]) fail("ERR pending");
  endtask
