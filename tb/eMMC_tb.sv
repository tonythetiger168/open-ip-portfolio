// SPDX-License-Identifier: Apache-2.0
// Self-checking testbench for eMMC_top -- the DUT is an autonomous host;
// this TB is the card. The card model receives every command frame (checks
// its CRC7 and framing), answers R3 / R2 / R1, takes CMD24 write blocks
// (own CRC16, CRC status token, busy) into a 4-block store and sends CMD17
// read blocks. One-shot fault knobs corrupt a chosen response or data
// phase; each fault must raise irq and the matching sticky error flag, and
// the host must then recover (a further read-back round must complete).
// Covered: CMD1 busy polling, R3 / R2 / R1 framing and CRC faults, R1
// card-status errors, response timeouts, negative / missing CRC status,
// write busy and busy timeout, read data timeout / CRC / end bit / compare
// faults, eMMC and system resets mid-transfer, the 8-bit round counter
// wrapping, and a second host at BIT_CLKS = 2.
`timescale 1ns/1ps

module emmc_card #(parameter int BC = 1) (
  input logic clk,
  inout wire  cmd,
  inout wire  dat0
);
  localparam int F_NONE = 0, F_MUTE = 1, F_R3 = 2, F_R2 = 3, F_CRC7 = 4, F_IDX = 5, F_END = 6,
                 F_TXB = 7, F_STAT = 8, F_TOK = 9, F_TOKMUTE = 10, F_BUSYHOLD = 11, F_RDMUTE = 12,
                 F_RDCRC = 13, F_RDEND = 14, F_RDDATA = 15, F_WCRC = 16, F_R3RES = 17, F_R2RES = 18;
  logic [127:0] cid_base = 128'h1501_0045_4D4D_4331_3600_1234_5678_9A00;

  logic coe = 0, co = 1, doe = 0, dout = 1;
  assign cmd  = coe ? co : 1'bz;
  assign dat0 = doe ? dout : 1'bz;

  int fault = F_NONE, fault_cmd = -1;
  int busy_polls = 2, polls = 0, busy_len = 6;
  logic [31:0] st_err = 32'h0040_0000;     // status bits sent with F_STAT
  logic [31:0] st_ok  = 32'h0000_0900;     // status bits sent otherwise
  int bad_frames = 0, n_cmds = 0;
  logic [255:0] mem [0:3];
  logic wr_go = 0, rd_go = 0;
  logic [1:0] dblk;
  int dfault = F_NONE;

  function automatic logic [6:0] crc7(input logic [119:0] d, input int n);
    logic [6:0] c = 0;
    for (int i = 119; i >= 0; i--) if (i < n) c = {c[5:0], 1'b0} ^ ((d[i] ^ c[6]) ? 7'h09 : 7'h00);
    return c;
  endfunction
  function automatic logic [15:0] crc16(input logic [255:0] d);
    logic [15:0] c = 0;
    for (int i = 255; i >= 0; i--) c = {c[14:0], 1'b0} ^ ((d[i] ^ c[15]) ? 16'h1021 : 16'h0);
    return c;
  endfunction
  function automatic logic [127:0] cid_val();
    cid_val = cid_base;
    cid_val[7:1] = crc7(cid_base[127:8], 120);
    cid_val[0] = 1'b1;
  endfunction

  task automatic bitw(input int k);
    repeat (k * BC) @(posedge clk);
  endtask

  // drive a response MSB first on CMD
  logic [135:0] rsp;
  task automatic send_rsp(input int len);
    coe <= 1;
    for (int i = len - 1; i >= 0; i--) begin co <= rsp[i]; bitw(1); end
    coe <= 0; co <= 1;
  endtask

  task automatic kill();
    disable run; disable drun;
    coe <= 0; co <= 1; doe <= 0; dout <= 1; wr_go = 0; rd_go = 0; polls = 0;
  endtask

  // ------------------------- command side -------------------------
  initial forever begin : run
    logic [47:0] f;
    logic [5:0] idx;
    int flt;
    @(posedge clk);
    if (cmd === 1'b0 && !coe) begin
      f = 0;
      for (int i = 46; i >= 0; i--) begin bitw(1); f[i] = cmd; end
      idx = f[45:40];
      n_cmds++;
      if (!f[46] || !f[0] || crc7({80'h0, f[47:8]}, 40) != f[7:1]) bad_frames++;
      else begin
        flt = (fault_cmd == idx) ? fault : F_NONE;
        if (flt != F_NONE) begin fault = F_NONE; fault_cmd = -1; end
        bitw(4);
        case (idx)
          6'd0: polls = 0;
          6'd1: if (flt != F_MUTE) begin
            rsp = 0;
            rsp[47:0] = {2'b00, 6'h3F, polls >= busy_polls, 31'h00FF_8080, 8'hFF};
            if (flt == F_R3) rsp[45] = 1'b0;
            if (flt == F_R3RES) rsp[3] = 1'b0;
            polls++;
            send_rsp(48);
          end
          6'd2: if (flt != F_MUTE) begin
            rsp = {2'b00, 6'h3F, cid_val()};
            if (flt == F_R2) rsp[3] = ~rsp[3];
            if (flt == F_R2RES) rsp[130] = 1'b0;
            send_rsp(136);
          end
          default: if (flt != F_MUTE) begin
            logic [31:0] st;
            st = (flt == F_STAT) ? (st_ok | st_err) : st_ok;
            rsp = 0;
            rsp[47:0] = {2'b00, idx, st, 7'h0, 1'b1};
            rsp[7:1] = crc7({80'h0, rsp[47:8]}, 40);
            if (flt == F_CRC7) rsp[1] = ~rsp[1];
            if (flt == F_IDX)  begin rsp[40] = ~rsp[40]; rsp[7:1] = crc7({80'h0, rsp[47:8]}, 40); end
            if (flt == F_END)  rsp[0] = 1'b0;
            if (flt == F_TXB) begin rsp[46] = 1'b1; rsp[7:1] = crc7({80'h0, rsp[47:8]}, 40); end
            send_rsp(48);
            if (flt == F_NONE || flt >= F_TOK) begin
              dblk = f[9:8]; dfault = flt;
              if (idx == 6'd24) wr_go = 1;
              if (idx == 6'd17) rd_go = 1;
            end
          end
        endcase
      end
    end
  end

  // ------------------------- data side -------------------------
  initial forever begin : drun
    logic [255:0] d;
    logic [15:0] c;
    logic e, ok;
    int t;
    @(posedge clk);
    if (wr_go) begin
      wr_go = 0;
      t = 0;
      while (dat0 !== 1'b0 && t < 200) begin @(posedge clk); t++; end
      for (int i = 255; i >= 0; i--) begin bitw(1); d[i] = dat0; end
      for (int i = 15; i >= 0; i--) begin bitw(1); c[i] = dat0; end
      bitw(1); e = dat0;
      ok = e && c == crc16(d) && dfault != F_WCRC;
      if (ok) mem[dblk] = d;
      bitw(2);
      if (dfault != F_TOKMUTE) begin
        doe <= 1; dout <= 0; bitw(1);
        {dout} <= ok && dfault != F_TOK ? 1'b0 : 1'b1; bitw(1);
        dout <= ok && dfault != F_TOK ? 1'b1 : 1'b0; bitw(1);
        dout <= ok && dfault != F_TOK ? 1'b0 : 1'b1; bitw(1);
        dout <= 1; bitw(1);
        dout <= 0; bitw(dfault == F_BUSYHOLD ? 70 : busy_len);
        doe <= 0; dout <= 1;
      end
    end else if (rd_go) begin
      rd_go = 0;
      bitw(2);
      if (dfault != F_RDMUTE) begin
        d = mem[dblk];
        if (dfault == F_RDDATA) d[77] = ~d[77];   // with a matching CRC16
        c = crc16(d);
        if (dfault == F_RDCRC) c[0] = ~c[0];
        doe <= 1; dout <= 0; bitw(1);
        for (int i = 255; i >= 0; i--) begin dout <= d[i]; bitw(1); end
        for (int i = 15; i >= 0; i--) begin dout <= c[i]; bitw(1); end
        dout <= dfault != F_RDEND; bitw(1);
        doe <= 0; dout <= 1;
      end
    end
  end
endmodule

module eMMC_tb;
  logic clk = 0, rst_n = 0, emmc_clk = 0, emmc_rst_n = 0;
  tri1 cmd, cmd2;
  tri1 [7:0] dat, dat2;
  wire irq, irq2;
  int errors = 0;

  eMMC_top dut (.clk(clk), .rst_n(rst_n), .emmc_clk(emmc_clk), .cmd(cmd), .dat(dat),
                .emmc_rst_n(emmc_rst_n), .irq(irq));
  emmc_card #(.BC(1)) card (.clk(emmc_clk), .cmd(cmd), .dat0(dat[0]));
  // DAT[7:1] are unused in 1-bit mode: the TB wiggles them to show that
  logic up_oe = 0;
  assign dat[7:1] = up_oe ? 7'h00 : 7'hzz;
  // second host at half the bit rate, free-running
  logic rst2 = 0;
  eMMC_top #(.BIT_CLKS(2)) dut2 (.clk(clk), .rst_n(rst2), .emmc_clk(emmc_clk), .cmd(cmd2), .dat(dat2),
                                 .emmc_rst_n(1'b1), .irq(irq2));
  emmc_card #(.BC(2)) card2 (.clk(emmc_clk), .cmd(cmd2), .dat0(dat2[0]));

  always #5 clk = ~clk;
  always #7 emmc_clk = ~emmc_clk;

  task automatic check(input bit c, input string m);
    if (!c) begin errors++; $display("ERROR: %s (t=%0t)", m, $time); end
  endtask

  function automatic logic [255:0] pat(input logic [7:0] r);
    for (int i = 0; i < 8; i++)
      pat[255 - i * 32 -: 32] = 32'hA500_3C00 ^ {24'h0, r} ^ ({24'h0, 8'(i)} * 32'h0001_0101);
  endfunction

  int irqs = 0;
  always @(posedge emmc_clk) if (irq) irqs++;

  task automatic wait_rounds(input int n, input string what);
    int t, m0;
    m0 = dut.match_cnt; t = 0;
    while (8'(dut.match_cnt - m0) < n && t < 3000 * n) begin @(posedge emmc_clk); t++; end
    check(8'(dut.match_cnt - m0) >= n, {what, ": rounds did not complete"});
  endtask

  // arm a one-shot fault on command idx; expect exactly one irq and flag
  task automatic fault(input int f, input int idx, input string what);
    int i0, t;
    i0 = irqs; t = 0;
    card.fault = f; card.fault_cmd = idx;
    while (irqs == i0 && t < 8000) begin @(posedge emmc_clk); t++; end
    check(irqs == i0 + 1, {what, ": no irq"});
  endtask

  task automatic reset_host(input bit sys);
    @(negedge emmc_clk);
    if (sys) rst_n = 0; else emmc_rst_n = 0;
    card.kill();
    repeat (3) @(negedge emmc_clk);
    check(irq === 1'b0 && dut.init_done === 1'b0 && dut.match_cnt == 0, "reset state");
    rst_n = 1; emmc_rst_n = 1;
  endtask

  task automatic wait_init(input string what);
    int t = 0;
    while (!dut.init_done && t < 20000) begin @(posedge emmc_clk); t++; end
    check(dut.init_done === 1'b1, {what, ": init did not complete"});
  endtask

  initial begin
    for (int b = 0; b < 4; b++) begin card.mem[b] = '1; card2.mem[b] = '1; end
    card.busy_polls = 3;
    repeat (4) @(negedge emmc_clk);
    rst_n = 1; emmc_rst_n = 1; rst2 = 1;

    // ---- init with CMD1 busy polling, CID capture, clean rounds ----
    wait_init("first init");
    check(dut.cid == card.cid_val(), "CID");
    up_oe = 1;
    wait_rounds(5, "clean rounds (DAT[7:1] held low)");
    up_oe = 0;
    // rounds 0..4 ran: block 0 holds round 4, blocks 1..3 rounds 1..3
    for (int b = 0; b < 4; b++) check(card.mem[b] == pat(8'(b == 0 ? 4 : b)), "card store contents");
    check(card.bad_frames == 0, "host command frame errors");

    // ---- data-phase faults (host stays initialised) ----
    fault(card.F_CRC7, 24, "R1 CRC7 (CMD24)");      check(dut.err_crc7, "err_crc7");   wait_rounds(1, "after CRC7");
    fault(card.F_IDX, 17, "R1 index (CMD17)");      wait_rounds(1, "after index");
    fault(card.F_END, 24, "R1 end bit");            wait_rounds(1, "after end bit");
    fault(card.F_TXB, 17, "R1 transmission bit");   wait_rounds(1, "after tx bit");
    fault(card.F_STAT, 24, "R1 status (CMD24)");    check(dut.err_status, "err_status"); wait_rounds(1, "after status");
    fault(card.F_STAT, 17, "R1 status (CMD17)");    wait_rounds(1, "after status 17");
    fault(card.F_MUTE, 24, "no R1 (CMD24)");        check(dut.err_timeout, "err_timeout"); wait_rounds(1, "after mute");
    fault(card.F_MUTE, 17, "no R1 (CMD17)");        wait_rounds(1, "after mute 17");
    fault(card.F_TOK, 24, "negative CRC status");   check(dut.err_crc16, "err_crc16"); wait_rounds(1, "after token");
    fault(card.F_WCRC, 24, "card sees bad CRC");    wait_rounds(1, "after wcrc");
    fault(card.F_TOKMUTE, 24, "no CRC status");     wait_rounds(1, "after token mute");
    fault(card.F_BUSYHOLD, 24, "busy timeout");     wait_rounds(1, "after busy hold");
    fault(card.F_RDMUTE, 17, "no read data");       wait_rounds(1, "after read mute");
    fault(card.F_RDCRC, 17, "read CRC16");          wait_rounds(1, "after read crc");
    fault(card.F_RDEND, 17, "read end bit");        wait_rounds(1, "after read end");
    fault(card.F_RDDATA, 17, "read compare");       check(dut.err_cmp, "err_cmp"); wait_rounds(1, "after compare");

    // ---- each card-status error bit alone; the other bits are benign ----
    for (int b = 0; b < 32; b++)
      if (32'hFDF9_8080 & (32'h1 << b)) begin
        card.st_err = 32'h1 << b;
        fault(card.F_STAT, (b % 2) ? 24 : 17, $sformatf("status bit %0d", b));
        wait_rounds(1, "after status bit");
      end
    card.st_err = 32'h0040_0000;
    begin
      int i0;
      i0 = irqs;
      card.st_ok = ~32'hFDF9_8080;
      wait_rounds(2, "benign status bits");
      check(irqs == i0, "benign status bits raised irq");
      card.st_ok = 32'h0000_0900;
    end

    // ---- init-phase faults: restart through an eMMC reset ----
    reset_host(0);  fault(card.F_R3RES, 1, "R3 reserved bits"); wait_init("after R3 reserved");
    reset_host(0);  fault(card.F_R2RES, 2, "R2 reserved bits"); wait_init("after R2 reserved");
    reset_host(0);  fault(card.F_R3, 1, "R3 framing");   wait_init("after R3");
    reset_host(0);  fault(card.F_MUTE, 1, "no R3");      wait_init("after no R3");
    reset_host(1);  fault(card.F_R2, 2, "R2 CID CRC");   wait_init("after R2");
    reset_host(0);  fault(card.F_MUTE, 2, "no R2");      wait_init("after no R2");
    reset_host(0);  fault(card.F_CRC7, 3, "R1 (CMD3)");  wait_init("after CMD3 crc");
    reset_host(0);  fault(card.F_STAT, 3, "R1 status (CMD3)"); wait_init("after CMD3 status");
    // reset in the middle of a write block
    wait (dut.state == 3'd4 && dut.dphase == 3'd1); repeat (40) @(posedge emmc_clk);
    reset_host(1);  wait_init("after reset in a write");
    // reset in the middle of a response during init
    reset_host(0);  wait (dut.state == 3'd2 && dut.cur == 3'd2 && dut.bit_cnt > 9'd20);
    reset_host(0);  wait_init("after reset in R2");

    // ---- every CID bit both ways: inverted CID, then the original ----
    card.cid_base = ~card.cid_base; reset_host(1); wait_init("inverted CID");
    check(dut.cid == card.cid_val(), "inverted CID");
    card.cid_base = ~card.cid_base; reset_host(0); wait_init("CID again");
    check(dut.cid == card.cid_val(), "CID again");

    // ---- the 8-bit round counter wraps ----
    wait_rounds(255, "round counter wrap");
    check(dut.match_cnt == 8'd255 && dut.round == 8'd255, "counters before wrap");
    wait_rounds(2, "past the wrap");
    check(dut.round == 8'd1, "round wrapped");
    check(card.bad_frames == 0 && card2.bad_frames == 0, "host command frame errors");
    check(dut2.match_cnt > 0 && dut2.init_done, "BIT_CLKS=2 host made progress");

    if (errors == 0) $display("TEST PASSED: eMMC");
    else             $display("TEST FAILED: %0d errors", errors);
    $finish;
  end

  initial begin
    repeat (20000) #1000;
    $display("TEST FAILED: TIMEOUT"); $finish;
  end
endmodule
