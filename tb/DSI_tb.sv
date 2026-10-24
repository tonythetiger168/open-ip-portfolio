// SPDX-License-Identifier: Apache-2.0
// ============================================================================
// Self-checking testbench for DSI_top (MIPI DSI host TX + BTA)
// The TB plays the DSI peripheral: it decodes the host serial packet stream
// (SoT, header, ECC, payload, CRC-16 checked with independent reference
// models) and answers DCS read requests after the bus turn-around.
// Covered: every command op (raw short packet, DCS short writes with 0 / 1
// parameter, DCS long write of 0..32 bytes, video line HSS/HSE/HBP/HACT
// with empty and 64 KiB blanking, DCS read), rejected commands (invalid op,
// RAM payload over 32 bytes, HACT not a multiple of 3), BTA responses
// (clean, every single-bit header error corrected, uncorrectable, bad SoT,
// timeout, answer just before the timeout, acknowledge-and-error report),
// commands offered while busy, pkt_cnt wrap, reset mid-packet and mid-BTA.
// ============================================================================
`timescale 1ns/1ps
module DSI_tb;

  localparam int BTA_TO = 512;

  logic        clk = 0, rst_n = 0;
  logic        irq;
  logic        tx_bit, tx_valid, tx_oe;
  logic        rx_bit = 1;
  logic        cmd_valid = 0;
  logic [2:0]  cmd_op = 0;
  logic [5:0]  cmd_dt = 0;
  logic [7:0]  cmd_dcs = 0;
  logic [15:0] cmd_len = 0, cmd_len2 = 0;
  logic        cmd_busy;
  logic        pl_we = 0;
  logic [4:0]  pl_addr = 0;
  logic [7:0]  pl_wdata = 0;
  logic        bta_done;
  logic [23:0] bta_data;
  logic [15:0] pkt_cnt;

  int errors = 0;

  DSI_top #(.BTA_TO(BTA_TO)) dut (
    .clk(clk), .rst_n(rst_n), .irq(irq),
    .tx_bit(tx_bit), .tx_valid(tx_valid), .tx_oe(tx_oe), .rx_bit(rx_bit),
    .cmd_valid(cmd_valid), .cmd_op(cmd_op), .cmd_dt(cmd_dt),
    .cmd_dcs(cmd_dcs), .cmd_len(cmd_len), .cmd_len2(cmd_len2),
    .cmd_busy(cmd_busy),
    .pl_we(pl_we), .pl_addr(pl_addr), .pl_wdata(pl_wdata),
    .bta_done(bta_done), .bta_data(bta_data), .pkt_cnt(pkt_cnt)
  );

  always #5 clk = ~clk;

  localparam logic [2:0] OP_SPKT   = 3'd0;
  localparam logic [2:0] OP_DCS_S0 = 3'd1;
  localparam logic [2:0] OP_DCS_S1 = 3'd2;
  localparam logic [2:0] OP_DCS_L  = 3'd3;
  localparam logic [2:0] OP_VLINE  = 3'd4;
  localparam logic [2:0] OP_DCS_RD = 3'd5;

  // decoded packet record
  logic [7:0]  rx_dt;
  logic [15:0] rx_len;
  logic [7:0]  rx_pay [0:31];
  logic [7:0]  ram [0:31];           // model of the payload RAM
  int          pcnt = 0;             // model of pkt_cnt

  // irq / bta_done pulse counters
  int irq_cnt = 0, done_cnt = 0;
  always @(posedge clk) begin
    if (irq) irq_cnt++;
    if (bta_done) done_cnt++;
  end

  // ------------------------------------------------------------------
  // reference models (independent copies of the spec math)
  // ------------------------------------------------------------------
  function automatic logic [5:0] ecc24(input logic [23:0] d);
    ecc24[0] = d[0]^d[1]^d[2]^d[4]^d[5]^d[7]^d[10]^d[11]^d[13]^d[16]^d[20]^d[21]^d[22]^d[23];
    ecc24[1] = d[0]^d[1]^d[3]^d[4]^d[6]^d[8]^d[10]^d[12]^d[14]^d[17]^d[20]^d[21]^d[22]^d[23];
    ecc24[2] = d[0]^d[2]^d[3]^d[5]^d[6]^d[9]^d[11]^d[12]^d[15]^d[18]^d[20]^d[21]^d[22];
    ecc24[3] = d[1]^d[2]^d[3]^d[7]^d[8]^d[9]^d[13]^d[14]^d[15]^d[19]^d[20]^d[21]^d[23];
    ecc24[4] = d[4]^d[5]^d[6]^d[7]^d[8]^d[9]^d[16]^d[17]^d[18]^d[19]^d[20]^d[22]^d[23];
    ecc24[5] = d[10]^d[11]^d[12]^d[13]^d[14]^d[15]^d[16]^d[17]^d[18]^d[19]^d[21]^d[22]^d[23];
  endfunction

  function automatic logic [15:0] crc16_byte(input logic [15:0] c, input logic [7:0] d);
    logic [15:0] v;
    v = c ^ {8'h00, d};
    for (int k = 0; k < 8; k++)
      v = v[0] ? {1'b0, v[15:1]} ^ 16'h8408 : {1'b0, v[15:1]};
    crc16_byte = v;
  endfunction

  task automatic check(input logic cond, input string tag);
    if (!cond) begin errors++; $display("ERROR: %s (time %0t)", tag, $time); end
  endtask

  // ------------------------------------------------------------------
  // peripheral receive tasks (sample host bits at negedge)
  // ------------------------------------------------------------------
  task automatic recv_byte(output logic [7:0] b, input string tag);
    for (int i = 0; i < 8; i++) begin
      @(negedge clk);
      b[i] = tx_bit;
      check(tx_valid === 1'b1 && tx_oe === 1'b1, {tag, " tx_valid dropped mid-byte"});
    end
  endtask

  // receive one packet: SoT, ECC, CRC checked; long = expected format
  task automatic recv_packet(input logic is_long, input string tag);
    logic [7:0]  b, b0, b1, b2, be, cl, ch;
    logic [15:0] c;
    while (tx_valid !== 1'b1) @(negedge clk);
    // the first bit is already on the lane at this negedge
    b[0] = tx_bit;
    for (int i = 1; i < 8; i++) begin @(negedge clk); b[i] = tx_bit; end
    check(b == 8'hB8, {tag, " SoT"});
    recv_byte(b0, tag); recv_byte(b1, tag); recv_byte(b2, tag); recv_byte(be, tag);
    check(be == {2'b00, ecc24({b2, b1, b0})}, {tag, " header ECC"});
    rx_dt  = b0;
    rx_len = {b2, b1};
    if (is_long) begin
      c = 16'hFFFF;
      for (int i = 0; i < rx_len; i++) begin
        recv_byte(b, tag);
        if (i < 32) rx_pay[i] = b;
        c = crc16_byte(c, b);
      end
      recv_byte(cl, tag); recv_byte(ch, tag);
      check({ch, cl} == c, {tag, " payload CRC-16"});
    end
    @(negedge clk);
    check(tx_valid === 1'b0 && tx_bit === 1'b1, {tag, " gap after packet"});
    pcnt++;
  endtask

  // ------------------------------------------------------------------
  // host-side command helpers
  // ------------------------------------------------------------------
  task automatic do_cmd(input logic [2:0] op, input logic [5:0] dt, input logic [7:0] dcs,
                        input logic [15:0] len, input logic [15:0] len2);
    @(negedge clk);
    cmd_op = op; cmd_dt = dt; cmd_dcs = dcs; cmd_len = len; cmd_len2 = len2;
    cmd_valid = 1'b1;
    @(negedge clk);
    cmd_valid = 1'b0;
  endtask

  task automatic pl_write(input int n);
    for (int i = 0; i < n; i++) begin
      @(negedge clk);
      pl_we = 1'b1; pl_addr = 5'(i); pl_wdata = ram[i];
    end
    @(negedge clk);
    pl_we = 1'b0;
  endtask

  task automatic wait_idle;
    while (cmd_busy) @(negedge clk);
    @(negedge clk);
  endtask

  // short packet command and its check
  task automatic short_cmd(input logic [2:0] op, input logic [5:0] dt, input logic [7:0] dcs,
                           input logic [15:0] len, input logic [7:0] exp_dt,
                           input logic [15:0] exp_data, input string tag);
    do_cmd(op, dt, dcs, len, 16'h0);
    recv_packet(0, tag);
    check(rx_dt == exp_dt && rx_len == exp_data, {tag, " header"});
    wait_idle;
    check(pkt_cnt == 16'(pcnt), {tag, " pkt_cnt"});
  endtask

  task automatic dcs_long(input logic [7:0] dcs, input int n, input int pat = -1);
    for (int i = 0; i < n; i++) ram[i] = pat >= 0 ? 8'(pat) : 8'($urandom);
    if (n > 0) ram[0] = dcs;
    pl_write(n);
    do_cmd(OP_DCS_L, 6'h0, 8'h00, 16'(n), 16'h0);
    recv_packet(1, "DCS long write");
    check(rx_dt == 8'h39 && rx_len == 16'(n), "DCS long write header");
    for (int i = 0; i < n; i++) check(rx_pay[i] == ram[i], "DCS long write payload");
    wait_idle;
  endtask

  task automatic vline(input int hact, input int hbp);
    for (int i = 0; i < hact; i++) ram[i] = $urandom;
    pl_write(hact);
    do_cmd(OP_VLINE, 6'h0, 8'h00, 16'(hact), 16'(hbp));
    recv_packet(0, "HSS"); check(rx_dt == 8'h21 && rx_len == 0, "HSS header");
    recv_packet(0, "HSE"); check(rx_dt == 8'h31 && rx_len == 0, "HSE header");
    recv_packet(1, "HBP");
    check(rx_dt == 8'h19 && rx_len == 16'(hbp), "HBP header");
    for (int i = 0; i < hbp && i < 32; i++) check(rx_pay[i] == 8'h00, "HBP blanking payload");
    recv_packet(1, "HACT");
    check(rx_dt == 8'h3E && rx_len == 16'(hact), "HACT header");
    for (int i = 0; i < hact; i++) check(rx_pay[i] == ram[i], "HACT payload");
    wait_idle;
  endtask

  task automatic reject(input logic [2:0] op, input logic [15:0] len, input string tag);
    int c0;
    c0 = irq_cnt;
    do_cmd(op, 6'h0, 8'h00, len, 16'h0);
    repeat (3) @(negedge clk);
    check(irq_cnt == c0 + 1 && !cmd_busy && !tx_valid, {tag, " rejected with irq"});
  endtask

  // ------------------------------------------------------------------
  // BTA: read request, trigger byte, peripheral answer
  // ------------------------------------------------------------------
  task automatic read_req(input logic [7:0] dcs);
    logic [7:0] b;
    do_cmd(OP_DCS_RD, 6'h0, dcs, 16'h0, 16'h0);
    recv_packet(0, "DCS read");
    check(rx_dt == 8'h06 && rx_len == {8'h00, dcs}, "DCS read header");
    while (tx_valid !== 1'b1) @(negedge clk);
    b[0] = tx_bit;
    for (int i = 1; i < 8; i++) begin @(negedge clk); b[i] = tx_bit; end
    check(b == 8'h84, "BTA trigger byte");
    @(negedge clk); @(negedge clk);
    check(tx_oe === 1'b0 && tx_valid === 1'b0, "lane released for BTA");
  endtask

  // send the 5 response bytes after dly clocks
  task automatic send_resp(input logic [7:0] sot, input logic [23:0] hdr, input logic [7:0] ecc,
                           input int dly);
    logic [7:0] r [0:4];
    r[0] = sot; r[1] = hdr[7:0]; r[2] = hdr[15:8]; r[3] = hdr[23:16]; r[4] = ecc;
    repeat (dly) @(negedge clk);
    for (int j = 0; j < 5; j++)
      for (int i = 0; i < 8; i++) begin @(negedge clk); rx_bit = r[j][i]; end
    @(negedge clk); rx_bit = 1'b1;
  endtask

  // syndrome of a single flipped bit k (0..23 data, 24..29 parity)
  function automatic logic [5:0] col(input int k);
    col = (k < 24) ? ecc24(24'h1 << k) : 6'(1 << (k - 24));
  endfunction

  // full read: hdr sent with err (24 data + 6 parity bit mask) flipped
  task automatic read_txn(input logic [23:0] hdr, input logic [29:0] err, input int dly);
    logic [23:0] h;
    logic [5:0]  e, syn;
    int          c0, d0, k;
    logic        corr;
    h = hdr ^ err[23:0];
    e = ecc24(hdr) ^ err[29:24];
    syn = ecc24(h) ^ e;
    corr = (syn == 0); k = -1;
    for (int j = 0; j < 30; j++) if (syn != 0 && col(j) == syn) begin corr = 1; k = j; end
    c0 = irq_cnt; d0 = done_cnt;
    read_req(8'h0A);
    send_resp(8'hB8, h, {2'b00, e}, dly);
    wait_idle;
    if (corr) begin
      check(done_cnt == d0 + 1, "BTA response accepted");
      check(bta_data == ((k >= 0 && k < 24) ? h ^ (24'h1 << k) : h), "BTA response data");
      check(irq_cnt == c0 + ((bta_data[7:0] == 8'h02 && bta_data[23:8] != 0) ? 1 : 0),
            "BTA irq only for an error report");
    end else begin
      check(done_cnt == d0 && irq_cnt == c0 + 1, "uncorrectable BTA response -> irq");
    end
    check(tx_oe === 1'b1, "lane back to the host");
  endtask

  // ------------------------------------------------------------------
  // test sequence
  // ------------------------------------------------------------------
  int c0;
  logic [29:0] em;

  initial begin
    repeat (3) @(negedge clk);
    check(!tx_valid && tx_oe && tx_bit && !cmd_busy && !irq && !bta_done &&
          pkt_cnt == 0 && bta_data == 0, "reset state");
    rst_n = 1;
    repeat (2) @(negedge clk);

    // ---- payload RAM: every bit both ways ----
    for (int i = 0; i < 32; i++) ram[i] = 8'hFF;
    pl_write(32);
    for (int i = 0; i < 32; i++) ram[i] = 8'h00;
    pl_write(32);

    // ---- short packets ----
    short_cmd(OP_SPKT, 6'h3F, 8'h00, 16'hFFFF, 8'h3F, 16'hFFFF, "raw short 3F");
    short_cmd(OP_SPKT, 6'h00, 8'h00, 16'h0000, 8'h00, 16'h0000, "raw short 00");
    short_cmd(OP_SPKT, 6'h2A, 8'h00, 16'h5AA5, 8'h2A, 16'h5AA5, "raw short 2A");
    short_cmd(OP_DCS_S0, 6'h3F, 8'h29, 16'hFFFF, 8'h05, 16'h0029, "set_display_on");
    short_cmd(OP_DCS_S0, 6'h00, 8'hFF, 16'h0000, 8'h05, 16'h00FF, "DCS S0 FF");
    ram[0] = 8'h77; pl_write(1);
    short_cmd(OP_DCS_S1, 6'h00, 8'h3A, 16'h0000, 8'h15, 16'h773A, "set_pixel_format");
    ram[0] = 8'hFF; pl_write(1);
    short_cmd(OP_DCS_S1, 6'h00, 8'h00, 16'h1234, 8'h15, 16'hFF00, "DCS S1 FF");
    ram[0] = 8'h00; pl_write(1);
    short_cmd(OP_DCS_S1, 6'h00, 8'hFF, 16'h0000, 8'h15, 16'h00FF, "DCS S1 00");
    // command in the same clock as a RAM write: S1 takes the old ram[0]
    @(negedge clk);
    pl_we = 1; pl_addr = 5'd0; pl_wdata = 8'h99;
    cmd_op = OP_DCS_S1; cmd_dcs = 8'h51; cmd_valid = 1;
    @(negedge clk);
    pl_we = 0; cmd_valid = 0; ram[0] = 8'h99;
    recv_packet(0, "S1 with a RAM write");
    check(rx_dt == 8'h15 && rx_len == 16'h0051, "S1 used ram[0] before the write");
    wait_idle;

    // ---- DCS long writes ----
    dcs_long(8'h2A, 0);
    dcs_long(8'h2A, 1);
    dcs_long(8'h2A, 5);
    dcs_long(8'h2C, 32);
    for (int k = 0; k < 4; k++) dcs_long(8'h2C, 2 + $urandom_range(0, 30));
    dcs_long(8'h3C, 8, 8'h00); dcs_long(8'h3C, 8, 8'hFF); dcs_long(8'h3C, 8, 8'h55); dcs_long(8'h3C, 8, 8'hAA);

    // ---- video lines ----
    vline(0, 0);
    vline(3, 1);
    vline(30, 7);
    vline(18, 32);

    // ---- rejected commands ----
    reject(3'd6, 16'h0, "op 6");
    reject(3'd7, 16'h0, "op 7");
    reject(OP_DCS_L, 16'd33, "long write 33");
    reject(OP_DCS_L, 16'hFFFF, "long write FFFF");
    reject(OP_VLINE, 16'd4, "HACT 4");
    reject(OP_VLINE, 16'd5, "HACT 5");
    reject(OP_VLINE, 16'd33, "HACT 33");
    check(pkt_cnt == 16'(pcnt), "rejected commands send nothing");

    // ---- a command offered while busy is ignored ----
    do_cmd(OP_SPKT, 6'h11, 8'h00, 16'h1111, 16'h0);
    fork
      begin
        repeat (3) @(negedge clk);
        do_cmd(OP_SPKT, 6'h22, 8'h00, 16'h2222, 16'h0);  // during the first packet
      end
      recv_packet(0, "first of two");
    join
    check(rx_dt == 8'h11, "first command sent");
    wait_idle;
    repeat (60) @(negedge clk);
    check(!tx_valid && pkt_cnt == 16'(pcnt), "second command dropped while busy");

    // ---- DCS read + BTA ----
    read_txn(24'h00AB21, 30'h0, 4);                  // clean 1-byte read response
    read_txn(24'hFFFF22, 30'h0, 0);
    read_txn(24'h000002, 30'h0, 2);                  // ack-error report, no errors
    read_txn(24'h800002, 30'h0, 2);                  // ack-error report with an error
    read_txn(24'h000021, 30'h0, 1);                  // read data patterns
    read_txn(24'h555522, 30'h0, 1);
    for (int k = 0; k < 30; k++)                     // each single-bit error corrected
      read_txn(24'(($urandom << 8) | 8'h21), 30'h1 << k, 1);
    read_txn(24'h123421, 30'h3, 1);                  // double errors
    read_txn(24'h123421, 30'h3000000, 1);
    for (int k = 0; k < 6; k++) begin
      em = $urandom; em[29:24] = 6'h3F;
      read_txn(24'($urandom), em, 1);
    end
    read_txn(24'h5A5A21, 30'h0, BTA_TO - 6);         // answer just before the timeout
    // bad SoT
    c0 = irq_cnt;
    read_req(8'h0B);
    send_resp(8'hB9, 24'h0, 8'h00, 3);
    wait_idle;
    check(irq_cnt == c0 + 1, "bad BTA SoT -> irq");
    c0 = irq_cnt;
    read_req(8'h0B);
    send_resp(8'h38, 24'h0, 8'h00, 3);              // only bit 7 wrong
    wait_idle;
    check(irq_cnt == c0 + 1, "bad BTA SoT bit 7 -> irq");
    // no answer
    c0 = irq_cnt;
    read_req(8'h0C);
    repeat (BTA_TO - 10) @(negedge clk);
    check(cmd_busy && !tx_oe, "still waiting for the response");
    wait_idle;
    check(irq_cnt == c0 + 1 && tx_oe, "BTA timeout -> irq");

    // ---- 64 KiB - 1 blanking packet ----
    vline(3, 65535);

    // ---- pkt_cnt wrap ----
    while (pkt_cnt != 16'hFFFF) begin
      @(negedge clk);
      cmd_op = OP_SPKT; cmd_valid = !cmd_busy;
    end
    cmd_valid = 0;
    wait_idle;
    pcnt = 16'hFFFF;
    short_cmd(OP_SPKT, 6'h01, 8'h00, 16'h0, 8'h01, 16'h0, "pkt_cnt wrap");
    check(pkt_cnt == 16'h0, "pkt_cnt wrapped");
    pcnt = 0;

    // ---- reset during a long packet ----
    do_cmd(OP_VLINE, 6'h0, 8'h00, 16'd30, 16'd20);
    repeat (150) @(negedge clk);
    rst_n = 0; @(negedge clk);
    check(!tx_valid && tx_oe && !cmd_busy && pkt_cnt == 0, "reset mid-packet");
    rst_n = 1; pcnt = 0;
    // ---- reset during BTA ----
    read_req(8'h0D);
    repeat (5) @(negedge clk);
    rst_n = 0; @(negedge clk);
    check(tx_oe && !cmd_busy && bta_data == 0, "reset mid-BTA");
    rst_n = 1; pcnt = 0;
    short_cmd(OP_DCS_S0, 6'h0, 8'h28, 16'h0, 8'h05, 16'h0028, "after reset");

    if (errors == 0) $display("TEST PASSED: DSI");
    else             $display("TEST FAILED: %0d errors", errors);
    $finish;
  end

  initial begin
    #200000000;
    $display("TEST FAILED: TIMEOUT"); $finish;
  end
endmodule
