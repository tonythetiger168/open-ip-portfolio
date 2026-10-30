// SPDX-License-Identifier: Apache-2.0
// Self-checking testbench for eMMC_top -- the DUT is an autonomous host;
// this TB is the device. The device model runs on the host's CLK and RST_n,
// receives every command frame (checks its CRC7 and framing), answers R3 /
// R2 / R1 at N_CR 2..5, answers CMD24 / CMD17 only after CMD7 selected it,
// takes CMD24 write blocks (own CRC16, CRC status token, busy) into a
// 4-block store and sends CMD17 read blocks. One-shot fault knobs corrupt a chosen response or data
// phase; each fault must raise irq and the matching sticky error flag, and
// the host must then recover (a further read-back round must complete).
// Covered: CMD1 busy polling, R3 / R2 / R1 framing and CRC faults, R1
// card-status errors, response timeouts, negative / missing CRC status,
// write busy and busy timeout, read data timeout / CRC / end bit / compare
// faults, CMD7 R1b busy and its timeout, resets mid-transfer, the 8-bit
// round counter wrapping, and a second host at other clock dividers.
// Monitors check the CLK rate (ID_CLK_DIV until CMD7, CLK_DIV after), that
// CMD / DAT0 change only while CLK is low, and the RST_n pulse.
`timescale 1ns/1ps

module emmc_card #(parameter int BUSY_HOLD = 70) (
  input logic clk,        // the host's CLK
  input logic rst_n,      // the host's RST_n
  inout wire  cmd,
  inout wire  dat0
);
  // JESD84 device in 1-bit mode. It samples CMD / DAT0 on the CLK rising
  // edge and drives them on the falling edge. Commands are answered only in
  // the state they are legal in: CMD1 / CMD2 / CMD3 after CMD0 or RST_n,
  // CMD7 with the assigned RCA, and CMD24 / CMD17 only once CMD7 has
  // selected the device (otherwise no response, as in stand-by).
  localparam int F_NONE = 0, F_MUTE = 1, F_R3 = 2, F_R2 = 3, F_CRC7 = 4, F_IDX = 5, F_END = 6,
                 F_TXB = 7, F_STAT = 8, F_TOK = 9, F_TOKMUTE = 10, F_BUSYHOLD = 11, F_RDMUTE = 12,
                 F_RDCRC = 13, F_RDEND = 14, F_RDDATA = 15, F_WCRC = 16, F_R3RES = 17, F_R2RES = 18,
                 F_SELBUSY = 19;
  logic [127:0] cid_base = 128'h1501_0045_4D4D_4331_3600_1234_5678_9A00;

  logic coe = 0, co = 1, doe = 0, dout = 1;
  assign cmd  = coe ? co : 1'bz;
  assign dat0 = doe ? dout : 1'bz;

  int fault = F_NONE, fault_cmd = -1;
  int busy_polls = 2, polls = 0, busy_len = 6, sel_busy = 3, rd_wait = 2;
  // N_CR of each response: 2 (the minimum) .. ncr_max clocks after the end bit
  int ncr = 2, ncr_max = 5, n_ncr2 = 0;
  logic [31:0] st_err = 32'h0040_0000;     // status bits sent with F_STAT
  logic [31:0] st_ok  = 32'h0000_0900;     // status bits sent otherwise
  int bad_frames = 0, n_cmds = 0, unselected = 0, rst_seen = 0;
  logic [15:0] rca = 0;
  logic selected = 0;
  logic [255:0] mem [0:3];
  logic wr_go = 0, rd_go = 0, sb_go = 0;
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
    repeat (k) @(negedge clk);
  endtask
  task automatic bitr(input int k);
    repeat (k) @(posedge clk);
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
    coe <= 0; co <= 1; doe <= 0; dout <= 1; wr_go = 0; rd_go = 0; sb_go = 0; polls = 0;
    selected = 0; rca = 0;
  endtask
  // RST_n low: back to the idle state
  always @(negedge rst_n) begin rst_seen++; kill(); end

  // ------------------------- command side -------------------------
  initial forever begin : run
    logic [47:0] f;
    logic [5:0] idx;
    int flt;
    @(posedge clk);
    if (cmd === 1'b0 && !coe && rst_n === 1'b1) begin
      f = 0;
      for (int i = 46; i >= 0; i--) begin bitr(1); f[i] = cmd; end
      idx = f[45:40];
      n_cmds++;
      if (!f[46] || !f[0] || crc7({80'h0, f[47:8]}, 40) != f[7:1]) bad_frames++;
      else if ((idx == 6'd24 || idx == 6'd17) && !selected) unselected++;
      else if (idx == 6'd7 && f[39:24] != rca) unselected++;
      else begin
        flt = (fault_cmd == idx) ? fault : F_NONE;
        if (flt != F_NONE) begin fault = F_NONE; fault_cmd = -1; end
        ncr = $urandom_range(ncr_max, 2);
        if (ncr == 2) n_ncr2++;
        bitw(ncr);
        case (idx)
          6'd0: begin polls = 0; selected = 0; rca = 0; end
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
            if (idx == 6'd3) rca = f[39:24];
            if (idx == 6'd7) selected = 1;
            send_rsp(48);
            if (idx == 6'd7) begin dfault = flt; sb_go = 1; end
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
    @(negedge clk);
    if (sb_go) begin                     // CMD7's R1b busy
      sb_go = 0;
      bitw(1);
      doe <= 1; dout <= 0; bitw(dfault == F_SELBUSY ? BUSY_HOLD : sel_busy);
      doe <= 0; dout <= 1;
    end else if (wr_go) begin
      wr_go = 0;
      t = 0;
      // the start bit is sampled on a rising edge (the host may drive it at
      // this very falling edge)
      do begin @(posedge clk); t++; end while (dat0 !== 1'b0 && t < 200);
      for (int i = 255; i >= 0; i--) begin bitr(1); d[i] = dat0; end
      for (int i = 15; i >= 0; i--) begin bitr(1); c[i] = dat0; end
      bitr(1); e = dat0;
      ok = e && c == crc16(d) && dfault != F_WCRC;
      if (ok) mem[dblk] = d;
      bitw(2);
      if (dfault != F_TOKMUTE) begin
        doe <= 1; dout <= 0; bitw(1);
        dout <= ok && dfault != F_TOK ? 1'b0 : 1'b1; bitw(1);
        dout <= ok && dfault != F_TOK ? 1'b1 : 1'b0; bitw(1);
        dout <= ok && dfault != F_TOK ? 1'b0 : 1'b1; bitw(1);
        dout <= 1; bitw(1);
        dout <= 0; bitw(dfault == F_BUSYHOLD ? BUSY_HOLD : busy_len);
        doe <= 0; dout <= 1;
      end
    end else if (rd_go) begin
      rd_go = 0;
      bitw(rd_wait);
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
  localparam int RD_TO = 300, BUSY_TO = 200;
  logic clk = 0, rst_n = 0;
  wire emmc_clk, emmc_clk2, emmc_rst_n, emmc_rst_n2;
  tri1 cmd, cmd2;
  tri1 [7:0] dat, dat2;
  wire irq, irq2;
  int errors = 0;

  eMMC_top #(.CLK_DIV(2), .ID_CLK_DIV(128), .RST_LOW(8), .RST_WAIT(100),
             .RD_TIMEOUT(RD_TO), .BUSY_TIMEOUT(BUSY_TO))
    dut (.clk(clk), .rst_n(rst_n), .emmc_clk(emmc_clk), .cmd(cmd), .dat(dat),
         .emmc_rst_n(emmc_rst_n), .irq(irq));
  emmc_card #(.BUSY_HOLD(BUSY_TO + 20)) card (.clk(emmc_clk), .rst_n(emmc_rst_n), .cmd(cmd), .dat0(dat[0]));
  // DAT[7:1] are unused in 1-bit mode: the TB wiggles them to show that
  logic up_oe = 0;
  assign dat[7:1] = up_oe ? 7'h00 : 7'hzz;
  // second host at other clock dividers, free-running
  logic rst2 = 0;
  eMMC_top #(.CLK_DIV(4), .ID_CLK_DIV(16), .RST_LOW(8), .RST_WAIT(100),
             .RD_TIMEOUT(RD_TO), .BUSY_TIMEOUT(BUSY_TO))
    dut2 (.clk(clk), .rst_n(rst2), .emmc_clk(emmc_clk2), .cmd(cmd2), .dat(dat2),
          .emmc_rst_n(emmc_rst_n2), .irq(irq2));
  emmc_card #(.BUSY_HOLD(BUSY_TO + 20)) card2 (.clk(emmc_clk2), .rst_n(emmc_rst_n2), .cmd(cmd2), .dat0(dat2[0]));

  always #5 clk = ~clk;

  task automatic check(input bit c, input string m);
    if (!c) begin errors++; $display("ERROR: %s (t=%0t)", m, $time); end
  endtask

  function automatic logic [255:0] pat(input logic [7:0] r);
    for (int i = 0; i < 8; i++)
      pat[255 - i * 32 -: 32] = 32'hA500_3C00 ^ {24'h0, r} ^ ({24'h0, 8'(i)} * 32'h0001_0101);
  endfunction

  int irqs = 0;
  always @(posedge irq) irqs++;

  // bus timing monitors: every CLK period is ID_CLK_DIV (128) clocks until
  // CMD7 and CLK_DIV (2) after; identification commands never go out at
  // the fast rate; CMD / DAT0 change only while CLK is low; RST_n is low for
  // RST_LOW clocks after rst_n
  int pcnt = 0, n_id = 0, n_fast = 0;
  logic seen = 0;
  realtime t_rel;
  always @(posedge rst_n) t_rel = $realtime;
  // RST_n rises at the 8th clk edge after rst_n (rst_n moves at a negedge)
  always @(posedge emmc_rst_n) check($realtime - t_rel == 75.0, "RST_n low time");
  logic [3:0] pins_q;
  always @(negedge clk) begin
    if (!rst_n) begin pcnt = 0; seen = 0; end
    else begin
      pcnt++;
      if (dut.tick) begin
        if (seen) check(pcnt == (dut.fast ? 2 : 128), "CLK period");
        if (dut.fast) n_fast++; else n_id++;
        seen = 1; pcnt = 0;
      end
      if (dut.state == 3'd0 && dut.cur <= 3'd3) check(!dut.fast, "identification at the fast rate");
    end
    if ({dut.cmd_oe_p, dut.cmd_out_p, dut.dat0_oe_p, dut.dat0_out_p} !== pins_q && rst_n)
      check(emmc_clk === 1'b0, "CMD / DAT0 changed while CLK is high");
    pins_q = {dut.cmd_oe_p, dut.cmd_out_p, dut.dat0_oe_p, dut.dat0_out_p};
  end

  task automatic wait_rounds(input int n, input string what);
    int t, m0;
    m0 = dut.match_cnt; t = 0;
    while (8'(dut.match_cnt - m0) < n && t < 3000 * n) begin @(posedge emmc_clk); t++; end
    check(8'(dut.match_cnt - m0) >= n, {what, ": rounds did not complete"});
  endtask

  // arm a one-shot fault on command idx; expect an irq
  task automatic fault(input int f, input int idx, input string what);
    int i0, t;
    i0 = irqs; t = 0;
    card.fault = f; card.fault_cmd = idx;
    while (irqs == i0 && t < 8000) begin @(posedge emmc_clk); t++; end
    check(irqs == i0 + 1, {what, ": no irq"});
  endtask

  task automatic reset_host();
    @(negedge clk);
    rst_n = 0;
    card.kill();
    repeat (3) @(negedge clk);
    check(irq === 1'b0 && dut.init_done === 1'b0 && dut.match_cnt == 0 && emmc_rst_n === 1'b0 &&
          emmc_clk === 1'b0, "reset state");
    rst_n = 1;
  endtask

  task automatic wait_init(input string what);
    int t = 0;
    while (!dut.init_done && t < 20000) begin @(posedge emmc_clk); t++; end
    check(dut.init_done === 1'b1, {what, ": init did not complete"});
  endtask

  initial begin
    for (int b = 0; b < 4; b++) begin card.mem[b] = '1; card2.mem[b] = '1; end
    card.busy_polls = 3;
    repeat (4) @(negedge clk);
    rst_n = 1; rst2 = 1;
    // no command before the RST_n pulse, tRSCA and the 74 clocks
    wait (emmc_rst_n === 1'b1);
    check(card.n_cmds == 0 && dut.state == 3'd6, "power-up sequence");

    // ---- init with CMD1 busy polling, CID capture, CMD7, clean rounds ----
    wait_init("first init");
    check(dut.cid == card.cid_val() && card.selected, "CID / selected");
    up_oe = 1;
    wait_rounds(5, "clean rounds (DAT[7:1] held low)");
    up_oe = 0;
    // rounds 0..4 ran: block 0 holds round 4, blocks 1..3 rounds 1..3
    for (int b = 0; b < 4; b++) check(card.mem[b] == pat(8'(b == 0 ? 4 : b)), "card store contents");
    check(card.bad_frames == 0 && card.unselected == 0, "host command frames / selection");

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
    // every R1 fault on the other data command too
    fault(card.F_CRC7, 17, "R1 CRC7 (CMD17)");      wait_rounds(1, "after CRC7 17");
    fault(card.F_IDX, 24, "R1 index (CMD24)");      wait_rounds(1, "after index 24");
    fault(card.F_END, 17, "R1 end bit (CMD17)");    wait_rounds(1, "after end bit 17");
    fault(card.F_TXB, 24, "R1 transmission bit (CMD24)"); wait_rounds(1, "after tx bit 24");
    // read access and write busy longer than the response limit but inside
    // their own limits: no error
    begin
      int i0;
      i0 = irqs;
      card.rd_wait = RD_TO - 20; card.busy_len = BUSY_TO - 20;
      wait_rounds(2, "long read access / busy");
      check(irqs == i0, "long read access / busy raised irq");
      card.rd_wait = 2; card.busy_len = 6;
    end

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

    // ---- init-phase faults: the host restarts with CMD0 ----
    reset_host();  fault(card.F_R3RES, 1, "R3 reserved bits"); wait_init("after R3 reserved");
    reset_host();  fault(card.F_R2RES, 2, "R2 reserved bits"); wait_init("after R2 reserved");
    reset_host();  fault(card.F_R3, 1, "R3 framing");   wait_init("after R3");
    reset_host();  fault(card.F_MUTE, 1, "no R3");      wait_init("after no R3");
    reset_host();  fault(card.F_R2, 2, "R2 CID CRC");   wait_init("after R2");
    reset_host();  fault(card.F_MUTE, 2, "no R2");      wait_init("after no R2");
    reset_host();  fault(card.F_CRC7, 3, "R1 (CMD3)");  wait_init("after CMD3 crc");
    reset_host();  fault(card.F_STAT, 3, "R1 status (CMD3)"); wait_init("after CMD3 status");
    reset_host();  fault(card.F_IDX, 3, "R1 index (CMD3)");   wait_init("after CMD3 index");
    reset_host();  fault(card.F_END, 3, "R1 end bit (CMD3)"); wait_init("after CMD3 end bit");
    reset_host();  fault(card.F_TXB, 3, "R1 tx bit (CMD3)");  wait_init("after CMD3 tx bit");
    reset_host();  fault(card.F_MUTE, 3, "no R1 (CMD3)");     wait_init("after CMD3 mute");
    reset_host();  fault(card.F_CRC7, 7, "R1 (CMD7)");  wait_init("after CMD7 crc");
    reset_host();  fault(card.F_STAT, 7, "R1 status (CMD7)"); wait_init("after CMD7 status");
    reset_host();  fault(card.F_MUTE, 7, "no R1 (CMD7)");     wait_init("after CMD7 mute");
    // CMD7's R1b busy held past BUSY_TIMEOUT: one error, then the round runs
    reset_host();  fault(card.F_SELBUSY, 7, "CMD7 busy timeout");
    check(dut.init_done && dut.err_timeout, "CMD7 busy timeout flags");
    wait_rounds(1, "after CMD7 busy");
    // reset in the middle of a write block
    wait (dut.state == 3'd4 && dut.dphase == 3'd1); repeat (40) @(posedge emmc_clk);
    reset_host();  wait_init("after reset in a write");
    // reset in the middle of a response during init
    reset_host();  wait (dut.state == 3'd2 && dut.cur == 3'd2 && dut.bit_cnt > 9'd20);
    reset_host();  wait_init("after reset in R2");
    // reset again during the power-up sequence (tRSCA)
    reset_host();  repeat (30) @(negedge clk);
    reset_host();  wait_init("after reset in power-up");
    // a device that always answers at N_CR = 2
    card.ncr_max = 2;
    reset_host();  wait_init("N_CR = 2");
    wait_rounds(3, "N_CR = 2 rounds");
    card.ncr_max = 5;

    // ---- every CID bit both ways: inverted CID, then the original ----
    card.cid_base = ~card.cid_base; reset_host(); wait_init("inverted CID");
    check(dut.cid == card.cid_val(), "inverted CID");
    card.cid_base = ~card.cid_base; reset_host(); wait_init("CID again");
    check(dut.cid == card.cid_val(), "CID again");

    // ---- the 8-bit round counter wraps ----
    wait_rounds(255, "round counter wrap");
    check(dut.match_cnt == 8'd255 && dut.round == 8'd255, "counters before wrap");
    wait_rounds(2, "past the wrap");
    check(dut.round == 8'd1, "round wrapped");
    check(card.bad_frames == 0 && card2.bad_frames == 0, "host command frame errors");
    check(card.unselected == 0 && card2.unselected == 0, "CMD24 / CMD17 before CMD7");
    check(card.n_ncr2 > 20 && n_id > 1000 && n_fast > 1000 && card.rst_seen > 20,
          "N_CR = 2 responses / both clock rates / RST_n pulses seen");
    check(dut2.match_cnt > 0 && dut2.init_done, "second host made progress");

    if (errors == 0) $display("TEST PASSED: eMMC");
    else             $display("TEST FAILED: %0d errors", errors);
    $finish;
  end

  initial begin
    repeat (200000) #1000;
    $display("TEST FAILED: TIMEOUT"); $finish;
  end
endmodule
