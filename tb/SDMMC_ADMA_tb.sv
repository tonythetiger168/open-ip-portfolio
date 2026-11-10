// SPDX-License-Identifier: Apache-2.0
// Self-checking core testbench of SDMMC_ADMA_top: the host against the
// behavioural card of tb/sdmmc_card_model.svh, AXI4 memory soc_ss_axi_mem.
// - SD: CMD0, CMD8, ACMD41 polling, CMD2 (CID checked), CMD3, CMD7, ACMD6 to
//   4-bit, then random transfers. eMMC: CMD1 polling, CMD2, CMD3, CMD7,
//   CMD8 EXT_CSD read in 1-bit, CMD6 to 8-bit, random transfers, EXT_CSD
//   again (BUS_WIDTH = 2).
// - Random transfers: read / write, 1..8 blocks of 64..512 bytes (CMD16),
//   sometimes with a last descriptor longer than the transfer,
//   CMD17 / 24 or CMD18 / 25 + CMD12, scattered over 1..5 ADMA2 tran
//   descriptors (word-sized pieces, buffers across 4 KB) with nop and link
//   descriptors and int bits; card array and memory compared, BLK_DONE,
//   DMA_INT count, no error bits.
// - Back-pressure: AWREADY held low during an 8-block read: sd_clk stops
//   with the buffer full and the data still arrives intact.
// - Errors: no response, response CRC, busy timeout, read CRC16, write CRC
//   status, invalid descriptor, descriptor table too short, AXI SLVERR,
//   DAT_RESET mid-transfer; each with the right C_ERR / D_ERR bit, and the
//   host keeps working afterwards.
// - LAT lines: "LAT tb SDMMC_ADMA R <cycles>" for card reads and "W" for
//   card writes, from C_START to XFER_DONE.
`timescale 1ns/1ps
`include "soc_ss_axi_mem.svh"
`include "sdmmc_card_model.svh"
module SDMMC_ADMA_tb;
  `include "soc_ss_tb_common.svh"
  wire        sd_clk;
  tri         cmd;
  tri   [7:0] dat;
  pullup (cmd);
  genvar gi;
  generate for (gi = 0; gi < 8; gi++) begin : g_pu
    pullup (dat[gi]);
  end endgenerate
  logic [9:0]  clk_div = 3;
  logic        clk_en = 0;
  logic [1:0]  bus_w = 0;
  logic [11:0] blksz = 512;
  logic [15:0] blkcnt = 1;
  logic [23:0] dto = 24'd20000;
  logic [31:0] adma_addr = 0;
  logic [5:0]  c_idx = 0;
  logic [31:0] c_arg = 0;
  logic [1:0]  c_rsp = 0;
  logic        c_crc_chk = 1, c_idx_chk = 1;
  logic [1:0]  c_data = 0;
  logic        c_start = 0, dat_reset = 0;
  wire  [31:0] rsp0, rsp1, rsp2, rsp3, adma_cur;
  wire         cmd_busy, dat_busy, cmd_done, cmd_err, xfer_done, xfer_err, dma_int;
  wire  [4:0]  c_err;
  wire  [7:0]  d_err;
  wire  [15:0] blk_done;
  SDMMC_ADMA_top dut (.*);
  sdmmc_card_model card (.sclk(sd_clk), .cmd, .dat);

  int n_dma_int = 0, n_xfer = 0;
  always @(posedge clk) if (rst_n) begin n_dma_int += dma_int; n_xfer += xfer_done; end
  int unsigned cyc = 0;
  always @(posedge clk) cyc++;

  localparam int R0 = 0, R48 = 1, R136 = 2, R1B = 3;
  logic [15:0] rca;

  task automatic sdcmd(input logic [5:0] idx, input logic [31:0] arg, input int rt,
                       input bit chk, input logic [1:0] dta, output logic [4:0] err);
    int t;
    while (cmd_busy) @(negedge clk);
    @(negedge clk);
    c_idx = idx; c_arg = arg; c_rsp = 2'(rt); c_crc_chk = chk; c_idx_chk = chk; c_data = dta;
    c_start = 1; @(negedge clk); c_start = 0;
    if (!cmd_busy) fail($sformatf("CMD%0d not started", idx));
    t = 0;
    while (cmd_busy && t < 2000000) begin @(negedge clk); t++; end
    err = c_err;
  endtask
  task automatic cmd_ok(input logic [5:0] idx, input logic [31:0] arg, input int rt, input bit chk = 1);
    logic [4:0] e;
    sdcmd(idx, arg, rt, chk, 0, e);
    if (e != 0) fail($sformatf("CMD%0d: C_ERR %b", idx, e));
  endtask
  task automatic wait_xfer;
    int t;
    t = 0;
    while (dat_busy && t < 4000000) begin @(negedge clk); t++; end
    if (dat_busy) fail("transfer did not end");
  endtask

  // ---------------------------------------------------------------- ADMA2 tables
  localparam logic [31:0] DT0 = 32'h0808_0000, DT1 = 32'h0808_0800;   // same MB as the buffers: no mem hash aliasing
  logic [31:0] seg_a [8];
  int          seg_w [8];
  int          nseg, n_int_exp;
  task automatic desc(inout logic [31:0] p, input logic [31:0] w0, input logic [31:0] w1);
    mem.poke(p, w0); mem.poke(p + 4, w1); p = p + 8;
  endtask
  // spread `words` over 1..5 segments and write the table at DT0 (maybe linking to DT1)
  task automatic build(input int words, input bit end_short = 0, input bit bad_valid = 0, input bit extra = 0);
    logic [31:0] p;
    int left, lk;
    nseg = 1 + $urandom % 5; if (nseg > words) nseg = words;
    left = words; n_int_exp = 0;
    for (int k = 0; k < nseg; k++) begin
      seg_w[k] = (k == nseg - 1) ? left : 1 + $urandom % (left - (nseg - 1 - k));
      left -= seg_w[k];
      seg_a[k] = 32'h0800_0000 + 32'(k) * 32'h0000_2000 + 32'(($urandom % 1024) * 4);
    end
    p = DT0; lk = $urandom % (nseg + 1);
    for (int k = 0; k < nseg; k++) begin
      bit ib, eb;
      if (k == lk && k != 0) begin desc(p, 32'h0000_0031, DT1); p = DT1; end   // link
      if ($urandom % 5 == 0) desc(p, 32'h0000_0001, 32'h0);                     // nop
      ib = $urandom % 2; eb = (k == nseg - 1) && ($urandom % 2 || end_short);
      if (ib) n_int_exp++;
      desc(p, {16'((seg_w[k] + ((extra && k == nseg - 1) ? 16 : 0)) * 4), 10'd0, 2'b10, 1'b0, ib, eb, !(bad_valid && k == nseg - 1)}, seg_a[k]);
    end
    if (end_short) begin   // the last segment never comes: shorten the transfer table
      mem.poke(p - 8, {16'(seg_w[nseg - 1] * 4 - 4), 10'd0, 2'b10, 4'b0011});
    end
    adma_addr = DT0;
  endtask
  function automatic logic [31:0] seg_word(input int i);   // i-th word of the scattered buffer
    int k;
    k = 0;
    while (i >= seg_w[k]) begin i -= seg_w[k]; k++; end
    return seg_a[k] + 32'(4 * i);
  endfunction

  // one transfer: rd = card to memory
  task automatic xfer(input bit rd, input int blk, input int nblk, input int bsz, input bit chk = 1);
    int words, t0;
    bit mul;
    logic [4:0] e;
    words = nblk * bsz / 4;
    if (bsz != card.blklen) cmd_ok(16, bsz, R48);
    build(words, 0, 0, $urandom % 4 == 0);   // sometimes a last descriptor longer than needed
    if (!rd) for (int i = 0; i < words; i++) mem.poke(seg_word(i), $urandom);
    blksz = 12'(bsz); blkcnt = 16'(nblk);
    mul = nblk > 1 || $urandom % 2;
    n_dma_int = 0;
    t0 = cyc;
    sdcmd(rd ? (mul ? 6'd18 : 6'd17) : (mul ? 6'd25 : 6'd24), blk, R48, 1, rd ? 2'd1 : 2'd2, e);
    if (e != 0) fail($sformatf("data command: C_ERR %b", e));
    wait_xfer();
    $display("LAT tb SDMMC_ADMA %s %0d", rd ? "R" : "W", cyc - t0);
    if (mul) cmd_ok(12, 0, R1B);
    if (!chk) return;
    if (d_err != 0) fail($sformatf("%s %0d x %0d: D_ERR %b", rd ? "read" : "write", nblk, bsz, d_err));
    if (blk_done != 16'(nblk)) fail($sformatf("BLK_DONE %0d, expected %0d", blk_done, nblk));
    if (n_dma_int != n_int_exp) fail($sformatf("%0d DMA_INT, expected %0d", n_dma_int, n_int_exp));
    begin
      int nbad;
      nbad = 0;
      for (int i = 0; i < words; i++) begin
        logic [31:0] m, c;
        int b;
        b = blk * bsz + 4 * i;
        m = mem.peek(seg_word(i));
        c = {card.mem[b + 3], card.mem[b + 2], card.mem[b + 1], card.mem[b]};
        if (m !== c && nbad < 3) begin
          nbad++;
          fail($sformatf("%s word %0d (block %0d, %0d bytes, width %0d): memory %h, card %h",
                         rd ? "read" : "write", i, blk, bsz, card.width, m, c));
          if (nbad == 1) for (int q = 0; q < nseg; q++)
            $display("  segment %0d: %h, %0d words (word %h)", q, seg_a[q], seg_w[q], seg_word(i));
        end
      end
    end
  endtask
  task automatic rnd_xfer;
    int bsz, nblk;
    bsz = ($urandom % 2) ? 512 : 4 * (1 << (4 + $urandom % 4));    // 64..512
    nblk = 1 + $urandom % 8;
    xfer($urandom % 2, $urandom % (64 * 512 / bsz - nblk), nblk, bsz);
  endtask
  bit xfer_err_seen;
  always @(posedge clk) if (xfer_done) xfer_err_seen = xfer_err;

  initial begin
    logic [4:0] e;
    for (int i = 0; i < 64 * 512; i++) card.mem[i] = $urandom;
    clks(3); rst_n = 1; clks(5);
    clk_en = 1; clks(200);
    // ------------------------------------------------ SD
    cmd_ok(0, 0, R0);
    cmd_ok(8, 32'h1AA, R48);
    if (rsp0[11:0] !== 12'h1AA) fail($sformatf("R7 %h", rsp0));
    begin
      int n;
      n = 0;
      do begin cmd_ok(55, 0, R48); cmd_ok(41, 32'h40FF_8000, R48, 0); n++; end while (!rsp0[31] && n < 10);
      if (!rsp0[31] || !rsp0[30]) fail($sformatf("ACMD41 OCR %h", rsp0));
    end
    cmd_ok(2, 0, R136);
    if ({rsp3, rsp2, rsp1, rsp0} !== card.cid) fail($sformatf("CID %h, card %h", {rsp3, rsp2, rsp1, rsp0}, card.cid));
    cmd_ok(3, 0, R48); rca = rsp0[31:16];
    if (rca !== 16'hB37A) fail($sformatf("RCA %h", rca));
    cmd_ok(7, {rca, 16'h0}, R1B);
    xfer(0, 5, 1, 512); xfer(1, 5, 1, 512);                  // 1-bit write and read
    cmd_ok(55, {rca, 16'h0}, R48); cmd_ok(6, 2, R48);
    bus_w = 1; clk_div = 0;
    for (int k = 0; k < ($test$plusargs("quick") ? 2 : 14); k++) begin
      if (k == 7 || k == 1) clk_div = 1 + $urandom % 3;
      rnd_xfer();
    end
    clk_div = 0;
    // back-pressure: 8 x 512 read with AWREADY held low for a while
    fork
      xfer(1, 3, 8, 512);
      begin
        int sc, t;
        wait (dat_busy); clks(100); mem.aw_hold = 1;
        wait (dut.hold || !dat_busy);
        clks(50);
        sc = 0; t = 0;
        fork : watch
          begin @(sd_clk); sc++; end
          clks(400);
        join_any
        disable watch;
        if (sc != 0) fail("sd_clk ran with the buffer full");
        if (!dut.hold) fail("HOLD low with the buffer full");
        mem.aw_hold = 0;
      end
    join
    // errors
    card.f_mute = 1;
    sdcmd(13, {rca, 16'h0}, R48, 1, 0, e); if (e !== 5'b00001) fail($sformatf("no response: C_ERR %b", e));
    card.f_rcrc = 1;
    sdcmd(13, {rca, 16'h0}, R48, 1, 0, e); if (e !== 5'b00010) fail($sformatf("response CRC: C_ERR %b", e));
    dto = 300; card.f_busy = 1;
    sdcmd(7, {rca, 16'h0}, R1B, 1, 0, e); if (e !== 5'b10000) fail($sformatf("busy timeout: C_ERR %b", e));
    wait (dat[0] === 1'b1); dto = 24'd20000;
    clks(20);
    card.f_rd_crc = 1; xfer(1, 2, 3, 512, 0);
    if (!xfer_err_seen || !d_err[1]) fail($sformatf("read CRC: D_ERR %b", d_err));
    card.f_wtok = 1; xfer(0, 2, 3, 512, 0);
    if (!xfer_err_seen || !d_err[3]) fail($sformatf("write CRC status: D_ERR %b", d_err));
    // invalid descriptor, short table, SLVERR, DAT_RESET (reads, stopped by CMD12)
    for (int c = 0; c < 4; c++) begin
      int t0;
      build(2 * 128, c == 1, c == 0);
      blksz = 512; blkcnt = 2;
      if (c == 2) begin mem.err_lo = seg_a[0]; mem.err_hi = seg_a[0] + 4; end
      sdcmd(18, 4, R48, 1, 2'd1, e);
      if (c == 3) begin clks(300); @(negedge clk); dat_reset = 1; @(negedge clk); dat_reset = 0; end
      wait_xfer();
      cmd_ok(12, 0, R1B);
      mem.err_lo = 32'hFFFF_FFFF; mem.err_hi = 32'hFFFF_FFFF;
      if (!xfer_err_seen) fail($sformatf("abort case %0d: no XFER_ERR", c));
      case (c)
        0: if (!d_err[4]) fail($sformatf("invalid descriptor: D_ERR %b", d_err));
        1: if (!d_err[6]) fail($sformatf("short table: D_ERR %b", d_err));
        2: if (!d_err[5]) fail($sformatf("SLVERR: D_ERR %b", d_err));
        default: if (d_err != 0) fail($sformatf("DAT_RESET: D_ERR %b", d_err));
      endcase
      clks(200);
    end
    for (int k = 0; k < 4; k++) rnd_xfer();                     // still working
    // ------------------------------------------------ eMMC
    card.emmc = 1; card.insert(); bus_w = 0; clk_div = 2;
    cmd_ok(0, 0, R0);
    begin
      int n;
      n = 0;
      do begin cmd_ok(1, 32'h40FF_8080, R48, 0); n++; end while (!rsp0[31] && n < 10);
      if (rsp0[30:29] !== 2'b10) fail($sformatf("CMD1 OCR %h", rsp0));
    end
    cmd_ok(2, 0, R136);
    if ({rsp3, rsp2, rsp1, rsp0} !== card.cid) fail("eMMC CID");
    rca = 16'h0001;
    cmd_ok(3, {rca, 16'h0}, R48);
    cmd_ok(7, {rca, 16'h0}, R1B);
    for (int pass = 0; pass < 2; pass++) begin
      build(128);
      blksz = 512; blkcnt = 1;
      sdcmd(8, 0, R48, 1, 2'd1, e);
      wait_xfer();
      if (d_err != 0) fail($sformatf("EXT_CSD read: D_ERR %b", d_err));
      for (int i = 0; i < 128; i++) begin
        logic [31:0] m;
        m = mem.peek(seg_word(i));
        if (m !== {card.ext_csd[4 * i + 3], card.ext_csd[4 * i + 2], card.ext_csd[4 * i + 1], card.ext_csd[4 * i]})
          begin fail($sformatf("EXT_CSD word %0d: %h", i, m)); break; end
      end
      if (pass == 1 && mem.peek(seg_word(183 / 4)) >> 24 !== 32'd2) fail("EXT_CSD[183] not 2 after the switch");
      if (pass == 0) begin
        cmd_ok(6, {6'd0, 2'b11, 8'd183, 8'd2, 8'd0}, R1B);
        bus_w = 2; clk_div = 0;
      end
    end
    for (int k = 0; k < 10; k++) rnd_xfer();
    card.f_rd_crc = 1; xfer(1, 1, 2, 512, 0);
    if (!d_err[1]) fail($sformatf("eMMC read CRC: D_ERR %b", d_err));
    for (int k = 0; k < 2; k++) rnd_xfer();
    // ------------------------------------------------ more corners (eMMC, 8-bit)
    mem.rand_id = 1;
    if (card.blklen != 512) cmd_ok(16, 512, R48);   // the card's block length must match BLKSZ
    // a reserved descriptor (skipped), then one tran of length 0 (65536
    // bytes) capped at the transfer; BLKCNT 0 counts as 1
    for (int c = 0; c < 2; c++) begin
      logic [31:0] p;
      p = DT0;
      desc(p, {16'd0, 10'd0, 2'b01, 4'b0001}, 32'h0);
      desc(p, {16'd0, 10'd0, 2'b10, 4'b0011}, 32'h0810_0000);
      adma_addr = DT0; blksz = 512; blkcnt = c ? 16'd0 : 16'd2;
      sdcmd(c ? 6'd17 : 6'd18, 0, R48, 1, 2'd1, e);
      wait_xfer();
      if (!c) cmd_ok(12, 0, R1B);
      if (d_err != 0 || blk_done != (c ? 16'd1 : 16'd2)) fail($sformatf("65536-byte descriptor: D_ERR %b BLK_DONE %0d", d_err, blk_done));
    end
    // response with the wrong index, response end bit 0
    card.f_ridx = 1; sdcmd(13, {rca, 16'h0}, R48, 1, 0, e); if (e !== 5'b00100) fail($sformatf("index: C_ERR %b", e));
    card.f_rend = 1; sdcmd(13, {rca, 16'h0}, R48, 1, 0, e); if (!e[3]) fail($sformatf("end bit: C_ERR %b", e));
    clks(50);
    // read block end bit 0; data timeout (a command with no data); the
    // data command failing
    build(128); blksz = 512; blkcnt = 1;
    card.f_rd_end = 1; sdcmd(17, 0, R48, 1, 2'd1, e); wait_xfer();
    if (!d_err[2]) fail($sformatf("read end bit: D_ERR %b", d_err));
    dto = 300;
    build(128); sdcmd(13, {rca, 16'h0}, R48, 1, 2'd1, e); wait_xfer();
    if (!d_err[0]) fail($sformatf("data timeout: D_ERR %b", d_err));
    dto = 24'd20000;
    build(128); card.f_mute = 1; sdcmd(17, 0, R48, 1, 2'd1, e); wait_xfer();
    if (!d_err[7]) fail($sformatf("data command failed: D_ERR %b", d_err));
    clks(200);
    // EXOKAY and DECERR from memory
    for (int c = 0; c < 2; c++) begin
      build(128); blksz = 512; blkcnt = 1;
      mem.err_resp = c ? 2'b11 : 2'b01; mem.err_lo = seg_a[0]; mem.err_hi = seg_a[0] + 4;
      sdcmd(17, 0, R48, 1, 2'd1, e); wait_xfer();
      mem.err_lo = 32'hFFFF_FFFF; mem.err_hi = 32'hFFFF_FFFF; mem.err_resp = 2'b10;
      if (!d_err[5]) fail($sformatf("response %0d: D_ERR %b", c ? 3 : 1, d_err));
      cmd_ok(12, 0, R1B);   // the host stopped early: stop the card's block too
      clks(200);
    end
    // DAT_RESET during a write; SD_CLK gated during a read; a command and
    // an ignored data command while a read runs
    build(4 * 128); blksz = 512; blkcnt = 4;
    for (int i = 0; i < 4 * 128; i++) mem.poke(seg_word(i), $urandom);
    card.expect_bad = 1;   // the host stops in the middle of a block on purpose: the card sees a broken block
    sdcmd(25, 8, R48, 1, 2'd2, e);
    clks(400); @(negedge clk); dat_reset = 1; @(negedge clk); dat_reset = 0;
    wait_xfer(); cmd_ok(12, 0, R1B);
    clks(4000);            // the card clocks out the rest of its broken block and its CRC status
    card.expect_bad = 0;
    if (!xfer_err_seen) fail("DAT_RESET during a write: no XFER_ERR");
    clks(200);
    build(8 * 128); blksz = 512; blkcnt = 8;
    sdcmd(18, 16, R48, 1, 2'd1, e);
    clks(300); @(negedge clk); clk_en = 0; clks(100); clk_en = 1;
    clks(300);
    @(negedge clk); c_idx = 17; c_data = 2'd1; c_start = 1; @(negedge clk); c_start = 0; c_data = 0;
    cmd_ok(13, {rca, 16'h0}, R48);
    wait_xfer(); cmd_ok(12, 0, R1B);
    if (d_err != 0) fail($sformatf("gated / overlapped read: D_ERR %b", d_err));
    // the slowest and a mid SD_CLK
    clk_div = 10'h3FF; cmd_ok(13, {rca, 16'h0}, R48);
    clk_div = 12; xfer(1, 2, 1, 64);
    clk_div = 0;
    // ------------------------------------------------ register and field sweeps (eMMC, 8-bit)
    // every command argument bit, random CIDs (R2 bits), OCR bits 14:8
    // echoed by CMD1
    cmd_ok(16, 512, R48);
    sdcmd(6'd63, 32'hFFFF_FFFF, R0, 1, 0, e); sdcmd(6'd63, 32'h0, R0, 1, 0, e);   // ignored index, no response
    begin
      logic [127:0] cid0;
      cid0 = card.cid;
      for (int k = 0; k < 6; k++) begin
        logic [119:0] body;
        body = {$urandom, $urandom, $urandom, $urandom};
        if (k == 0) body = '1;
        if (k == 1) body = '0;
        card.cid = {body, card.crc7({16'd0, body}, 119, 0), 1'b1};
        cmd_ok(2, 0, R136);
        if ({rsp3, rsp2, rsp1, rsp0} !== card.cid) fail($sformatf("random CID %0d: %h", k, {rsp3, rsp2, rsp1, rsp0}));
      end
      card.cid = cid0;
    end
    cmd_ok(1, 32'h40FF_FF80, R48, 0);
    if (rsp0[14:8] !== 7'h7F) fail($sformatf("CMD1 OCR echo %h", rsp0));
    cmd_ok(13, {rca, 16'h0}, R48);
    // an unaligned table address; a descriptor fetch error (DECERR); a nop
    // descriptor with the end bit before the transfer is done
    for (int c = 0; c < 3; c++) begin
      logic [31:0] p;
      build(128); blksz = 512; blkcnt = 1;
      if (c == 0) adma_addr = 32'hFFFF_FFFF;
      if (c == 1) begin mem.err_resp = 2'b11; mem.err_lo = DT0; mem.err_hi = DT0 + 8; end
      if (c == 2) begin p = DT0; desc(p, 32'h0000_0003, 32'h0); end
      sdcmd(17, 0, R48, 1, 2'd1, e);
      wait_xfer();
      cmd_ok(12, 0, R1B);
      mem.err_lo = 32'hFFFF_FFFF; mem.err_hi = 32'hFFFF_FFFF; mem.err_resp = 2'b10;
      if (!xfer_err_seen || d_err != (c == 0 ? 8'h10 : c == 1 ? 8'h20 : 8'h40))
        fail($sformatf("table error %0d: D_ERR %b", c, d_err));
      clks(2000);   // the card finishes its block
    end
    // write: no CRC status token; busy longer than DTO
    for (int c = 0; c < 2; c++) begin
      build(128); blksz = 512; blkcnt = 1;
      for (int i = 0; i < 128; i++) mem.poke(seg_word(i), $urandom);
      dto = 300;
      if (c == 0) card.f_wnotok = 1; else card.f_wbusy = 1;
      sdcmd(24, 3, R48, 1, 2'd2, e);
      wait_xfer();
      dto = 24'd20000;
      if (!xfer_err_seen || d_err != 8'h01) fail($sformatf("write %s: D_ERR %b", c ? "busy" : "token", d_err));
      wait (dat[0] === 1'b1); clks(20);
      cmd_ok(13, {rca, 16'h0}, R48);
    end
    // the largest block (BLKSZ 12'hFFF: bits 1:0 and 11:10 are ignored, 1020
    // bytes), on a table high in the address space with reserved and
    // attribute bits set in skipped descriptors, nop lengths that are not
    // word multiples, and the buffer high in memory
    cmd_ok(16, 1020, R48);
    begin
      logic [31:0] p, hb, hb2;
      p = 32'hFFFF_FFC4; hb = 32'hFFFE_F804; hb2 = 32'hFFFF_7404;
      desc(p, {16'hFFFF, 10'h3FF, 2'b00, 4'b1101}, 32'hFFFF_FFFF);   // nop, int, attribute bit 3 and 15:6
      desc(p, {16'hE000, 10'h000, 2'b01, 4'b0001}, 32'h0);            // reserved
      desc(p, {16'h0000, 10'h000, 2'b00, 4'b0001}, 32'h5555_5554);    // nop, length 0
      desc(p, {16'd1020, 10'h000, 2'b10, 4'b0101}, hb);               // tran, int
      desc(p, {16'd1020, 10'h000, 2'b10, 4'b0011}, hb2);             // tran, end (FFFF_FFE4..EB)
      adma_addr = 32'hFFFF_FFC4; blksz = 12'hFFF; blkcnt = 2;
      n_dma_int = 0;
      sdcmd(18, 1, R48, 1, 2'd1, e);
      wait_xfer(); cmd_ok(12, 0, R1B);
      if (d_err != 0 || blk_done != 2 || n_dma_int != 1) fail($sformatf("high table: D_ERR %b BLK_DONE %0d DMA_INT %0d", d_err, blk_done, n_dma_int));
      for (int i = 0; i < 510; i++) begin
        int b;
        logic [31:0] a;
        b = 1020 + 4 * i;
        a = (i < 255) ? hb + 32'(4 * i) : hb2 + 32'(4 * (i - 255));
        if (mem.peek(a) !== {card.mem[b + 3], card.mem[b + 2], card.mem[b + 1], card.mem[b]}) begin
          fail($sformatf("high buffer word %0d: %h", i, mem.peek(a))); break;
        end
      end
    end
    // the longest descriptors (65532 and 65536 bytes) and the largest
    // transfers (1020 x 65535 and 1020 x 32768 bytes): started, then
    // stopped by DAT_RESET once the descriptor's job runs (the engine
    // finishes it with dummy data)
    for (int c = 0; c < 2; c++) begin
      logic [31:0] p;
      p = DT0;
      desc(p, {c ? 16'h0000 : 16'hFFFC, 10'h000, 2'b10, 4'b0001}, 32'h0010_0000);
      adma_addr = DT0; blksz = 12'd1020; blkcnt = c ? 16'h8000 : 16'hFFFF;
      sdcmd(18, 0, R48, 1, 2'd1, e);
      wait (dut.as_q == dut.A_XWAIT || !dat_busy); clks(50);
      @(negedge clk); dat_reset = 1; @(negedge clk); dat_reset = 0;
      wait_xfer(); cmd_ok(12, 0, R1B);
      if (!xfer_err_seen) fail($sformatf("long descriptor %0d: no XFER_ERR", c));
      clks(3000);
    end
    if ($test$plusargs("cov_long")) begin
      // 4-byte blocks until BLK_DONE passes 32768, then stopped
      logic [31:0] p;
      cmd_ok(16, 4, R48);
      p = DT0;
      for (int k = 0; k < 3; k++) desc(p, {16'h0000, 10'h000, 2'b10, 4'b0001}, 32'h0010_0000 + 32'(k) * 32'h0001_0000);
      adma_addr = DT0; blksz = 12'd4; blkcnt = 16'hFFFF;
      sdcmd(18, 0, R48, 1, 2'd1, e);
      wait (blk_done[15] || !dat_busy);
      if (!blk_done[15]) fail($sformatf("4-byte blocks: stopped at %0d, D_ERR %b", blk_done, d_err));
      @(negedge clk); dat_reset = 1; @(negedge clk); dat_reset = 0;
      wait_xfer(); cmd_ok(12, 0, R1B);
      clks(1000);
    end
    cmd_ok(16, 512, R48);
    if ($test$plusargs("cov_long")) begin
      // the longest timeouts (DTO 2^24 - 1 SD_CLK periods): a read with no
      // data, and an R1b busy that outlasts it
      int t;
      dto = 24'hFFFFFF;
      build(128); blksz = 512; blkcnt = 1;
      sdcmd(13, {rca, 16'h0}, R48, 1, 2'd1, e);
      t = 0; while (dat_busy && t < 40000000) begin @(negedge clk); t++; end
      if (dat_busy || !d_err[0]) fail($sformatf("longest data timeout: D_ERR %b", d_err));
      card.busy_long = 24'hFFFFFF + 100; card.f_busy = 1;
      @(negedge clk); c_idx = 7; c_arg = {rca, 16'h0}; c_rsp = 2'(R1B); c_crc_chk = 1; c_idx_chk = 1; c_data = 0;
      c_start = 1; @(negedge clk); c_start = 0;
      t = 0; while (cmd_busy && t < 40000000) begin @(negedge clk); t++; end
      if (cmd_busy || c_err !== 5'b10000) fail($sformatf("longest busy timeout: C_ERR %b", c_err));
      wait (dat[0] === 1'b1); card.busy_long = 5000;
      clks(20);
    end
    dto = 24'hFFFFFF; clks(5); dto = 0; clks(5); dto = 24'd20000;
    // reset in the middle of a transfer
    build(4 * 128); blksz = 512; blkcnt = 4;
    sdcmd(18, 0, R48, 1, 2'd1, e);
    clks(500);
    rst_n = 0; clks(3);
    if (dat_busy || cmd_busy) fail("not idle in reset");
    rst_n = 1; clks(10);
    bus_w = 0; adma_addr = 0; clks(5);
    errors += card.errors;
    $display("SDMMC_ADMA: %0d transfers, card %0d commands, %0d blocks read, %0d written",
             n_xfer, card.n_cmds, card.n_rd_blk, card.n_wr_blk);
    finish("SDMMC_ADMA");
  end
  initial begin #400ms; fail("timeout"); $display("TEST FAILED: timeout"); $finish; end
endmodule
