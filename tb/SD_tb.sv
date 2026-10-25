// SPDX-License-Identifier: Apache-2.0
// Self-checking testbench for SD_top -- the DUT is an autonomous SD host;
// this TB is the card. Bus convention (race-free): the host drives and
// samples on the sd_clk rising edge (its internal tick); the card model
// drives and samples on the falling edge. CMD / DAT are tri1 (pull-ups).
// The card receives every command frame (checks CRC7, framing and the
// arguments), answers R7 / R1 / R3 / R2 / R6, takes CMD24 write blocks in
// 4-bit mode (own per-line CRC16, CRC status token, busy) into a 4-block
// store and sends CMD17 read blocks. One-shot fault knobs corrupt a chosen
// response or data phase; each fault must raise irq and the matching
// sticky error flag, and the host must recover (a further round completes).
// Covered: ACMD41 busy polling, standard and high capacity addressing,
// R7 voltage / pattern / framing faults, R3 / R2 / R6 / R1 framing, CRC,
// index and card-status faults, response timeouts, negative / missing CRC
// status, write busy and busy timeout, read data timeout / CRC (each line)
// / end bit / compare faults, resets mid-transfer, the round counter
// wrapping.
`timescale 1ns/1ps

module sd_card (
  input logic      sd_clk,
  inout wire       cmd,
  inout wire [3:0] dat
);
  localparam int F_NONE = 0, F_MUTE = 1, F_R3 = 2, F_R2 = 3, F_CRC7 = 4, F_IDX = 5, F_END = 6,
                 F_TXB = 7, F_STAT = 8, F_TOK = 9, F_TOKMUTE = 10, F_BUSYHOLD = 11, F_RDMUTE = 12,
                 F_RDCRC = 13, F_RDEND = 14, F_RDDATA = 15, F_WCRC = 16, F_R3RES = 17, F_R2RES = 18,
                 F_R7V = 19, F_R7P = 20;
  logic [127:0] cid_base = 128'h0353_4453_4430_3847_8012_3456_7801_5A00;
  logic [15:0]  rca = 16'hB37A;
  logic         ccs = 1;

  logic coe = 0, co = 1;
  logic [3:0] doe = 0, dout = 4'hF;
  assign cmd = coe ? co : 1'bz;
  for (genvar i = 0; i < 4; i++) begin : g_dat
    assign dat[i] = doe[i] ? dout[i] : 1'bz;
  end

  int fault = F_NONE, fault_cmd = -1, crc_line = 0;
  int busy_polls = 2, polls = 0, busy_len = 6;
  logic [31:0] st_err = 32'h0040_0000;     // status bits sent with F_STAT
  logic [31:0] st_ok  = 32'h0000_0900;     // status bits sent otherwise
  logic [15:0] r6_err = 16'h4000;
  int bad_frames = 0, bad_args = 0, n_cmds = 0;
  logic [255:0] mem [0:3];
  logic wr_go = 0, rd_go = 0;
  logic [1:0] dblk;
  int dfault = F_NONE;

  function automatic logic [6:0] crc7(input logic [119:0] d, input int n);
    logic [6:0] c = 0;
    for (int i = 119; i >= 0; i--) if (i < n) c = {c[5:0], 1'b0} ^ ((d[i] ^ c[6]) ? 7'h09 : 7'h00);
    return c;
  endfunction
  // CRC16 of DAT line k of a 4-bit block (nibble j bit k = block bit 255-4j-(3-k))
  function automatic logic [15:0] crc16(input logic [255:0] d, input int k);
    logic [15:0] c = 0;
    logic b;
    for (int j = 0; j < 64; j++) begin
      b = d[255 - 4 * j - (3 - k)];
      c = {c[14:0], 1'b0} ^ ((b ^ c[15]) ? 16'h1021 : 16'h0);
    end
    return c;
  endfunction
  function automatic logic [127:0] cid_val();
    cid_val = cid_base;
    cid_val[7:1] = crc7(cid_base[127:8], 120);
    cid_val[0] = 1'b1;
  endfunction

  task automatic bitw(input int k);
    repeat (k) @(negedge sd_clk);
  endtask

  // drive a response MSB first on CMD
  logic [135:0] rsp;
  task automatic send_rsp(input int len);
    coe <= 1;
    for (int i = len - 1; i >= 0; i--) begin co <= rsp[i]; bitw(1); end
    coe <= 0; co <= 1;
  endtask

  task automatic r48(input logic [5:0] idx, input logic [31:0] arg, input int flt);
    rsp = 0;
    rsp[47:0] = {2'b00, idx, arg, 7'h0, 1'b1};
    rsp[7:1] = crc7({80'h0, rsp[47:8]}, 40);
    if (flt == F_CRC7) rsp[1] = ~rsp[1];
    if (flt == F_IDX)  begin rsp[40] = ~rsp[40]; rsp[7:1] = crc7({80'h0, rsp[47:8]}, 40); end
    if (flt == F_END)  rsp[0] = 1'b0;
    if (flt == F_TXB) begin rsp[46] = 1'b1; rsp[7:1] = crc7({80'h0, rsp[47:8]}, 40); end
    send_rsp(48);
  endtask

  task automatic kill();
    disable run; disable drun;
    coe <= 0; co <= 1; doe <= 0; dout <= 4'hF; wr_go = 0; rd_go = 0; polls = 0;
  endtask

  // ------------------------- command side -------------------------
  initial forever begin : run
    logic [47:0] f;
    logic [5:0] idx;
    logic [31:0] arg;
    int flt;
    @(negedge sd_clk);
    if (cmd === 1'b0 && !coe) begin
      f = 0;
      for (int i = 46; i >= 0; i--) begin bitw(1); f[i] = cmd; end
      idx = f[45:40]; arg = f[39:8];
      n_cmds++;
      if (!f[46] || !f[0] || crc7({80'h0, f[47:8]}, 40) != f[7:1]) bad_frames++;
      else begin
        flt = (fault_cmd == idx) ? fault : F_NONE;
        if (flt != F_NONE) begin fault = F_NONE; fault_cmd = -1; end
        bitw(5);
        if (flt != F_MUTE) case (idx)
          6'd0: polls = 0;
          6'd8: begin
            if (arg != 32'h1AA) bad_args++;
            r48(6'd8, {20'h0, flt == F_R7V ? 4'h2 : 4'h1, flt == F_R7P ? 8'h55 : 8'hAA}, flt);
          end
          6'd41: begin
            if (arg != 32'h40FF_8000) bad_args++;
            rsp = 0;
            rsp[47:0] = {2'b00, 6'h3F, polls >= busy_polls, ccs, 30'h00FF_8000, 8'hFF};
            if (flt == F_R3) rsp[45] = 1'b0;
            if (flt == F_R3RES) rsp[3] = 1'b0;
            polls++;
            send_rsp(48);
          end
          6'd2: begin
            rsp = {2'b00, 6'h3F, cid_val()};
            if (flt == F_R2) rsp[3] = ~rsp[3];
            if (flt == F_R2RES) rsp[130] = 1'b0;
            send_rsp(136);
          end
          6'd3: r48(6'd3, {rca, flt == F_STAT ? r6_err : 16'h0500}, flt);
          default: begin
            if ((idx == 6'd7 || idx == 6'd13) && arg != {rca, 16'h0}) bad_args++;
            if ((idx == 6'd24 || idx == 6'd17) &&
                (ccs ? arg[31:2] != 0 : (arg[31:7] != 0 || arg[4:0] != 0))) bad_args++;
            r48(idx, ((flt == F_STAT) ? (st_ok | st_err) : st_ok) | (idx == 6'd55 ? 32'h20 : 32'h0), flt);
            if (flt == F_NONE || flt >= F_TOK) begin
              dblk = ccs ? arg[1:0] : arg[6:5]; dfault = flt;
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
    logic [15:0] c [4];
    logic [3:0] e;
    logic ok;
    int t;
    @(negedge sd_clk);
    if (wr_go) begin
      wr_go = 0;
      t = 0;
      while (dat !== 4'h0 && t < 200) begin @(negedge sd_clk); t++; end
      for (int j = 0; j < 64; j++) begin bitw(1); d[255 - 4 * j -: 4] = dat; end
      for (int i = 15; i >= 0; i--) begin
        bitw(1);
        for (int k = 0; k < 4; k++) c[k][i] = dat[k];
      end
      bitw(1); e = dat;
      ok = e == 4'hF && dfault != F_WCRC;
      for (int k = 0; k < 4; k++) if (c[k] != crc16(d, k)) ok = 0;
      if (ok) mem[dblk] = d;
      bitw(2);
      if (dfault != F_TOKMUTE) begin
        doe[0] <= 1; dout[0] <= 0; bitw(1);
        dout[0] <= ok && dfault != F_TOK ? 1'b0 : 1'b1; bitw(1);
        dout[0] <= ok && dfault != F_TOK ? 1'b1 : 1'b0; bitw(1);
        dout[0] <= ok && dfault != F_TOK ? 1'b0 : 1'b1; bitw(1);
        dout[0] <= 1; bitw(1);
        dout[0] <= 0; bitw(dfault == F_BUSYHOLD ? 70 : busy_len);
        doe[0] <= 0; dout[0] <= 1;
      end
    end else if (rd_go) begin
      rd_go = 0;
      bitw(2);
      if (dfault != F_RDMUTE) begin
        d = mem[dblk];
        if (dfault == F_RDDATA) d[77] = ~d[77];   // with a matching CRC16
        for (int k = 0; k < 4; k++) c[k] = crc16(d, k);
        if (dfault == F_RDCRC) c[crc_line][crc_line * 3] = ~c[crc_line][crc_line * 3];
        doe <= 4'hF; dout <= 4'h0; bitw(1);
        for (int j = 0; j < 64; j++) begin dout <= d[255 - 4 * j -: 4]; bitw(1); end
        for (int i = 15; i >= 0; i--) begin dout <= {c[3][i], c[2][i], c[1][i], c[0][i]}; bitw(1); end
        dout <= dfault == F_RDEND ? 4'b1110 : 4'hF; bitw(1);
        doe <= 0; dout <= 4'hF;
      end
    end
  end
endmodule

module SD_tb;
  logic clk = 0, rst_n = 0;
  wire  sd_clk;
  tri1  cmd;
  tri1 [3:0] dat;
  wire  irq;
  int errors = 0;

  SD_top dut (.clk(clk), .rst_n(rst_n), .sd_clk(sd_clk), .cmd(cmd), .dat(dat), .irq(irq));
  sd_card card (.sd_clk(sd_clk), .cmd(cmd), .dat(dat));

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

  task automatic wait_rounds(input int n, input string what);
    int t, m0;
    m0 = dut.match_cnt; t = 0;
    while (8'(dut.match_cnt - m0) < n && t < 3000 * n) begin @(posedge sd_clk); t++; end
    check(8'(dut.match_cnt - m0) >= n, {what, ": rounds did not complete"});
  endtask

  // arm a one-shot fault on command idx; expect exactly one irq
  task automatic fault(input int f, input int idx, input string what);
    int i0, t;
    i0 = irqs; t = 0;
    card.fault = f; card.fault_cmd = idx;
    while (irqs == i0 && t < 8000) begin @(posedge sd_clk); t++; end
    repeat (8) @(posedge sd_clk);
    check(irqs == i0 + 1, {what, ": not exactly one irq"});
  endtask

  task automatic reset_host();
    @(negedge clk);
    rst_n = 0;
    card.kill();
    repeat (6) @(negedge clk);
    check(irq === 1'b0 && dut.init_done === 1'b0 && dut.match_cnt == 0 && sd_clk === 1'b0,
          "reset state");
    rst_n = 1;
  endtask

  task automatic wait_init(input string what);
    int t = 0;
    while (!dut.init_done && t < 20000) begin @(posedge sd_clk); t++; end
    check(dut.init_done === 1'b1, {what, ": init did not complete"});
  endtask

  initial begin
    for (int b = 0; b < 4; b++) card.mem[b] = '1;
    card.busy_polls = 3;
    repeat (4) @(negedge clk);
    rst_n = 1;

    // ---- init with ACMD41 busy polling, CID / RCA capture, clean rounds ----
    wait_init("first init");
    check(dut.cid == card.cid_val() && dut.rca == card.rca && dut.ccs, "CID / RCA / CCS");
    wait_rounds(5, "clean rounds");
    // rounds 0..4 ran: block 0 holds round 4, blocks 1..3 rounds 1..3
    for (int b = 0; b < 4; b++) check(card.mem[b] == pat(8'(b == 0 ? 4 : b)), "card store contents");

    // ---- round faults (host stays initialised) ----
    fault(card.F_CRC7, 24, "R1 CRC7 (CMD24)");      check(dut.err_crc7, "err_crc7");   wait_rounds(1, "after CRC7");
    fault(card.F_IDX, 17, "R1 index (CMD17)");      wait_rounds(1, "after index");
    fault(card.F_END, 13, "R1 end bit (CMD13)");    wait_rounds(1, "after end bit");
    fault(card.F_TXB, 17, "R1 transmission bit");   wait_rounds(1, "after tx bit");
    fault(card.F_STAT, 24, "R1 status (CMD24)");    check(dut.err_status, "err_status"); wait_rounds(1, "after status");
    fault(card.F_STAT, 17, "R1 status (CMD17)");    wait_rounds(1, "after status 17");
    fault(card.F_STAT, 13, "R1 status (CMD13)");    wait_rounds(1, "after status 13");
    fault(card.F_MUTE, 24, "no R1 (CMD24)");        check(dut.err_timeout, "err_timeout"); wait_rounds(1, "after mute");
    fault(card.F_MUTE, 17, "no R1 (CMD17)");        wait_rounds(1, "after mute 17");
    fault(card.F_MUTE, 13, "no R1 (CMD13)");        wait_rounds(1, "after mute 13");
    fault(card.F_TOK, 24, "negative CRC status");   check(dut.err_crc16, "err_crc16"); wait_rounds(1, "after token");
    fault(card.F_WCRC, 24, "card sees bad CRC");    wait_rounds(1, "after wcrc");
    fault(card.F_TOKMUTE, 24, "no CRC status");     wait_rounds(1, "after token mute");
    fault(card.F_BUSYHOLD, 24, "busy timeout");     wait_rounds(1, "after busy hold");
    fault(card.F_RDMUTE, 17, "no read data");       wait_rounds(1, "after read mute");
    for (int k = 0; k < 4; k++) begin
      card.crc_line = k;
      fault(card.F_RDCRC, 17, "read CRC16");        wait_rounds(1, "after read crc");
    end
    fault(card.F_RDEND, 17, "read end bit");        wait_rounds(1, "after read end");
    fault(card.F_RDDATA, 17, "read compare");       check(dut.err_cmp, "err_cmp"); wait_rounds(1, "after compare");

    // ---- each card-status error bit alone; the other bits are benign ----
    for (int b = 0; b < 32; b++)
      if (32'hFDF9_8008 & (32'h1 << b)) begin
        card.st_err = 32'h1 << b;
        fault(card.F_STAT, (b % 3 == 0) ? 24 : (b % 3 == 1) ? 17 : 13, $sformatf("status bit %0d", b));
        wait_rounds(1, "after status bit");
      end
    card.st_err = 32'h0040_0000;
    begin
      int i0;
      i0 = irqs;
      card.st_ok = ~32'hFDF9_8008;
      wait_rounds(2, "benign status bits");
      check(irqs == i0, "benign status bits raised irq");
      card.st_ok = 32'h0000_0900;
    end

    // ---- init-phase faults: restart with CMD0 ----
    reset_host();  fault(card.F_R7V, 8, "R7 voltage");     check(dut.err_r7, "err_r7"); wait_init("after R7 voltage");
    reset_host();  fault(card.F_R7P, 8, "R7 pattern");     wait_init("after R7 pattern");
    reset_host();  fault(card.F_CRC7, 8, "R7 CRC");        wait_init("after R7 crc");
    reset_host();  fault(card.F_MUTE, 8, "no R7");         wait_init("after no R7");
    reset_host();  fault(card.F_IDX, 55, "R1 (CMD55)");    wait_init("after CMD55 idx");
    reset_host();  fault(card.F_STAT, 55, "status (CMD55)"); wait_init("after CMD55 status");
    reset_host();  fault(card.F_R3RES, 41, "R3 reserved"); wait_init("after R3 reserved");
    reset_host();  fault(card.F_R3, 41, "R3 framing");     wait_init("after R3");
    reset_host();  fault(card.F_MUTE, 41, "no R3");        wait_init("after no R3");
    reset_host();  fault(card.F_R2RES, 2, "R2 reserved");  wait_init("after R2 reserved");
    reset_host();  fault(card.F_R2, 2, "R2 CID CRC");      wait_init("after R2");
    reset_host();  fault(card.F_MUTE, 2, "no R2");         wait_init("after no R2");
    for (int b = 0; b < 16; b++)
      if (16'hE008 & (16'h1 << b)) begin
        card.r6_err = 16'h1 << b;
        reset_host();  fault(card.F_STAT, 3, "R6 status"); wait_init("after R6 status");
      end
    reset_host();  fault(card.F_END, 3, "R6 end bit");     wait_init("after R6 end");
    reset_host();  fault(card.F_CRC7, 7, "R1 (CMD7)");     wait_init("after CMD7 crc");
    reset_host();  fault(card.F_STAT, 7, "status (CMD7)"); wait_init("after CMD7 status");
    // reset in the middle of a write block
    wait (dut.state == 3'd4 && dut.dphase == 3'd1); repeat (40) @(posedge sd_clk);
    reset_host();  wait_init("after reset in a write");
    // reset in the middle of R2
    reset_host();  wait (dut.state == 3'd2 && dut.cur == 4'd4 && dut.bit_cnt > 8'd20);
    reset_host();  wait_init("after reset in R2");

    // ---- standard capacity card: byte addressing; other RCA / CID ----
    card.ccs = 0; card.rca = ~card.rca; card.cid_base = ~card.cid_base;
    reset_host(); wait_init("standard capacity");
    check(dut.cid == card.cid_val() && dut.rca == card.rca && !dut.ccs, "CID / RCA / CCS 2");
    wait_rounds(6, "byte addressed rounds");
    card.ccs = 1; card.rca = ~card.rca; card.cid_base = ~card.cid_base;
    reset_host(); wait_init("high capacity again");

    // ---- the 8-bit round counter wraps ----
    wait_rounds(255, "round counter wrap");
    check(dut.match_cnt == 8'd255 && dut.round == 8'd255, "counters before wrap");
    wait_rounds(2, "past the wrap");
    check(dut.round == 8'd1, "round wrapped");
    check(card.bad_frames == 0 && card.bad_args == 0, "host command frames / arguments");

    if (errors == 0) $display("TEST PASSED: SD");
    else             $display("TEST FAILED: %0d errors", errors);
    $finish;
  end

  initial begin
    repeat (100000) #1000;
    $display("TEST FAILED: TIMEOUT"); $finish;
  end
endmodule
