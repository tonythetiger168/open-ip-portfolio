// SPDX-License-Identifier: Apache-2.0
// SDMMC_ADMA-specific part of tb/SDMMC_ADMA_apb_tb.sv: a behavioural AXI4
// memory on the m_* pins and the SD / eMMC card model of
// tb/sdmmc_card_model.svh on the bus pins. Everything through the registers:
// - identification of six cards with random CIDs (CMD2 into RSP3..0, CMD3
//   RCA), then SD init (CMD0, CMD8, ACMD41 polling, CMD7, ACMD6 to 4-bit);
// - command errors: no response, CRC7, index, end bit, busy timeout
//   (STATUS.c_err, CMD_ERR masked and enabled, W1C);
// - ADMA2 transfers, write and read-back, over tables and buffers spread
//   across the address space (CMD24 / 17 / 25 / 18 + CMD12), XFER_DONE,
//   DMA_INT and BLK_DONE, one transfer with every interrupt masked;
// - data errors: data timeout, read CRC16, read end bit, write CRC status,
//   invalid descriptor (ADMA_CUR), AXI SLVERR on either side, table too
//   short, data command failed, DAT_RESET mid-transfer;
// - eMMC: CMD1 polling, CMD3, CMD7, CMD6 to 8-bit, write and read-back;
// - Verilator only: a 65535-block write of 4-byte blocks (BLK_DONE wraps
//   its bits, 65536-byte descriptors), about 5M clocks.
// The core-level checks (back-pressure, random scatter, EXT_CSD) are in
// tb/SDMMC_ADMA_tb.sv.
pullup (cmd);
pullup (dat[0]); pullup (dat[1]); pullup (dat[2]); pullup (dat[3]);
pullup (dat[4]); pullup (dat[5]); pullup (dat[6]); pullup (dat[7]);
soc_ss_axi_mem axm (
  .clk(PCLK), .rst_n(PRESETN),
  .awid(m_awid), .awaddr(m_awaddr), .awlen(m_awlen), .awsize(m_awsize), .awburst(m_awburst),
  .awprot(m_awprot), .awvalid(m_awvalid), .awready(m_awready),
  .wdata(m_wdata), .wstrb(m_wstrb), .wlast(m_wlast), .wvalid(m_wvalid), .wready(m_wready),
  .bid(m_bid), .bresp(m_bresp), .bvalid(m_bvalid), .bready(m_bready),
  .arid(m_arid), .araddr(m_araddr), .arlen(m_arlen), .arsize(m_arsize), .arburst(m_arburst),
  .arprot(m_arprot), .arvalid(m_arvalid), .arready(m_arready),
  .rid(m_rid), .rdata(m_rdata), .rresp(m_rresp), .rlast(m_rlast), .rvalid(m_rvalid), .rready(m_rready)
);
sdmmc_card_model card (.sclk(sd_clk), .cmd, .dat);
int unsigned pcyc = 0;
always @(posedge PCLK) pcyc++;
localparam int R0 = 0, R48 = 1, R136 = 2, R1B = 3;
// one command; returns STATUS.c_err (CMD_DONE / CMD_ERR cleared)
task automatic sdc(input logic [5:0] idx, input logic [31:0] arg, input int rt, input bit chk,
                   input int dta, output logic [4:0] e);
  wr(A_CMD_ARG, arg);
  wr(A_CMD_CTRL, {20'd0, 2'(dta), chk, chk, 2'(rt), idx});
  wr(A_CMD, 1);
  poll(A_IRQ_STATUS, 32'h1 << IRQ_CMD_DONE, 32'h1 << IRQ_CMD_DONE, 40000);
  wr(A_IRQ_STATUS, 32'h3);
  rd(A_STATUS); e = rdv[6:2];
endtask
task automatic sdc_ok(input logic [5:0] idx, input logic [31:0] arg, input int rt, input bit chk = 1);
  logic [4:0] e;
  sdc(idx, arg, rt, chk, 0, e);
  if (e != 0) fail($sformatf("CMD%0d: c_err %b", idx, e));
endtask
task automatic xfer_wait(input bit want_err, input string what, input int lim = 200000);
  poll(A_IRQ_STATUS, 32'h1 << IRQ_XFER_DONE, 32'h1 << IRQ_XFER_DONE, lim);
  if (rdv[IRQ_XFER_ERR] !== want_err) fail($sformatf("%s: XFER_ERR %b", what, rdv[IRQ_XFER_ERR]));
endtask

// ------------------------------------------------------------ scattered buffers
// Everything of one transfer sits in one 1 MB region (no aliasing in the
// memory model's address hash): the segments in one half of it (segment k at
// k * 128 KB plus a random offset), the table anywhere in the other half.
logic [31:0] seg_a [4];
int          seg_w [4];
int          nseg;
task automatic build(input logic [31:0] region, input int words, input bit bad = 0,
                     input bit shrt = 0);
  logic [31:0] t;
  int left;
  logic [31:0] dh, th;
  nseg = 1 + $urandom % 4; if (nseg > words) nseg = words;
  left = words;
  dh = (region & 32'hFFF0_0000) | (region & 32'h8_0000);     // data half
  th = (region & 32'hFFF0_0000) | (~region & 32'h8_0000);    // table half
  for (int k = 0; k < nseg; k++) begin
    seg_w[k] = (k == nseg - 1) ? left : 1 + $urandom % (left - (nseg - 1 - k));
    left -= seg_w[k];
    seg_a[k] = dh + 32'(k) * 32'h2_0000 + 32'(($urandom % 28672) * 4);
  end
  t = th + 32'(($urandom % 131000) * 4);
  wr(A_ADMA_ADDR, t);
  for (int k = 0; k < nseg; k++) begin
    logic [31:0] w0;
    w0 = {16'(seg_w[k] * 4), 10'd0, 2'b10, 1'b0, 1'(k == 0), 1'(k == nseg - 1), 1'b1};
    if (bad && k == nseg - 1) w0[0] = 1'b0;
    if (shrt && k == nseg - 1) begin w0[31:16] = 16'(seg_w[k] * 4 - 4); w0[1] = 1'b1; end
    axm.poke(t, w0); axm.poke(t + 4, seg_a[k]); t = t + 8;
  end
endtask
function automatic logic [31:0] seg_word(input int i);
  int k;
  k = 0;
  while (i >= seg_w[k]) begin i -= seg_w[k]; k++; end
  seg_word = seg_a[k] + 32'(4 * i);
endfunction
// rd: card to memory. Checks the data and BLK_DONE; mul: CMD18 / 25 + CMD12
task automatic xfer(input bit rd_, input logic [31:0] region, input int blk, input int nblk,
                    input bit want_err = 0, input string what = "transfer");
  int words, t0;
  bit mul;
  logic [4:0] e;
  words = nblk * 128;
  build(region, words);
  if (!rd_) for (int i = 0; i < words; i++) axm.poke(seg_word(i), $urandom);
  wr(A_BLK, {4'd0, 16'(nblk), 12'd512});
  mul = nblk > 1;
  t0 = pcyc;
  sdc(rd_ ? (mul ? 6'd18 : 6'd17) : (mul ? 6'd25 : 6'd24), blk, R48, 1, rd_ ? 1 : 2, e);
  if (e != 0) fail($sformatf("%s: data command c_err %b", what, e));
  xfer_wait(want_err, what);
  $display("LAT apb SDMMC_ADMA %s %0d", rd_ ? "R" : "W", pcyc - t0);
  wr(A_IRQ_STATUS, IRQ_ALL);
  if (mul) sdc_ok(12, 0, R1B);
  if (want_err) return;
  rd_exp(A_BLK_DONE, 32'(nblk));
  for (int i = 0; i < words; i++) begin
    logic [31:0] m, c;
    int b;
    b = blk * 512 + 4 * i;
    m = axm.peek(seg_word(i));
    c = {card.mem[b + 3], card.mem[b + 2], card.mem[b + 1], card.mem[b]};
    if (m !== c) begin fail($sformatf("%s word %0d: memory %h, card %h", what, i, m, c)); i = words; end
  end
endtask
// a data error: XFER_ERR with STATUS.d_err bit b
task automatic xbad(input bit rd_, input int nblk, input int b, input string what,
                    input bit bad = 0, input bit shrt = 0);
  logic [4:0] e;
  build(32'h0230_0000, nblk * 128, bad, shrt);
  wr(A_BLK, {4'd0, 16'(nblk), 12'd512});
  sdc(rd_ ? 6'd18 : 6'd25, 2, R48, 1, rd_ ? 1 : 2, e);
  xfer_wait(1, what);
  wr(A_IRQ_STATUS, IRQ_ALL);
  rd(A_STATUS); if (!rdv[7 + b]) fail($sformatf("%s: STATUS %h, d_err bit %0d expected", what, rdv, b));
  sdc_ok(12, 0, R1B);
  cycles(2000);
endtask

task automatic ip_func;
  logic [4:0]  e;
  logic [15:0] rca;
  for (int i = 0; i < 64 * 512; i++) card.mem[i] = $urandom;
  wr(A_IRQ_ENABLE, 32'h1F);
  wr(A_CFG, {19'd0, 2'd0, 1'b1, 10'd3});                 // 1-bit, clk on, DIV 3
  cycles(200);
  // ---------------------------------------------- random CIDs and RCAs
  card.rnd_id = 1;
  for (int k = 0; k < 6; k++) begin
    card.insert();
    sdc_ok(0, 0, R0);
    sdc_ok(2, 0, R136);
    rd_exp(A_RSP0, card.cid[31:0]); rd_exp(A_RSP1, card.cid[63:32]);
    rd_exp(A_RSP2, card.cid[95:64]); rd_exp(A_RSP3, card.cid[127:96]);
    sdc_ok(3, 0, R48); rd(A_RSP0);
    if (rdv[31:16] !== card.sd_rca) fail($sformatf("RCA %h, card %h", rdv[31:16], card.sd_rca));
  end
  card.rnd_id = 0;
  // ---------------------------------------------- SD init
  card.insert();
  sdc_ok(0, 0, R0);
  sdc_ok(8, 32'h1AA, R48); rd_exp(A_RSP0, 32'h1AA);
  sdc_ok(8, 32'h155, R48); rd_exp(A_RSP0, 32'h155);
  begin
    int n;
    n = 0;
    do begin sdc_ok(55, 0, R48); sdc_ok(41, 32'h40FF_8000, R48, 0); rd(A_RSP0); n++; end
    while (!rdv[31] && n < 10);
    if (!rdv[31]) fail("ACMD41 never ready");
  end
  sdc_ok(2, 0, R136);
  rd_exp(A_RSP3, card.cid[127:96]);
  sdc_ok(3, 0, R48); rd(A_RSP0); rca = rdv[31:16];
  sdc_ok(7, {rca, 16'h0}, R1B);
  sdc_ok(55, {rca, 16'h0}, R48); sdc_ok(6, 2, R48);
  wr(A_CFG, {19'd0, 2'd1, 1'b1, 10'd0});                 // 4-bit, DIV 0
  // ---------------------------------------------- command errors
  card.f_mute = 1; sdc(13, {rca, 16'h0}, R48, 1, 0, e);
  if (e !== 5'b00001) fail($sformatf("no response: c_err %b", e));
  wr(A_IRQ_ENABLE, 32'h1E);                              // CMD_DONE masked: CMD_ERR drives the pin
  card.f_rcrc = 1;
  wr(A_CMD_ARG, {rca, 16'h0}); wr(A_CMD_CTRL, {20'd0, 2'd0, 1'b1, 1'b1, 2'd1, 6'd13}); wr(A_CMD, 1);
  poll(A_IRQ_STATUS, 32'h2, 32'h2, 40000);
  if (irq !== 1'b1) fail("irq low with CMD_ERR pending and enabled");
  wr(A_IRQ_STATUS, 32'h3);
  if (irq !== 1'b0) fail("irq high after clearing CMD_ERR");
  rd(A_STATUS); if (rdv[6:2] !== 5'b00010) fail($sformatf("response CRC: c_err %b", rdv[6:2]));
  wr(A_IRQ_ENABLE, 32'h0);                               // everything masked
  card.f_ridx = 1; sdc(13, {rca, 16'h0}, R48, 1, 0, e);
  if (e !== 5'b00100) fail($sformatf("response index: c_err %b", e));
  card.f_rend = 1; sdc(13, {rca, 16'h0}, R48, 1, 0, e);
  if (e !== 5'b01000) fail($sformatf("response end bit: c_err %b", e));
  wr(A_DTO, 300); card.f_busy = 1;
  sdc(7, {rca, 16'h0}, R1B, 1, 0, e);
  if (e !== 5'b10000) fail($sformatf("busy timeout: c_err %b", e));
  wait (dat[0] === 1'b1); cycles(50);
  wr(A_DTO, 32'hFF_FFFF);
  // ---------------------------------------------- transfers, all interrupts masked first
  xfer(0, 32'h0000_0000, 8, 1);
  rd_exp(A_IRQ_STATUS, 0);
  wr(A_IRQ_ENABLE, 32'h1F);
  xfer(1, 32'hFFF8_0000, 8, 1);
  xfer(0, 32'h5550_0000, 20, 3);
  xfer(1, 32'hAAA8_0000, 20, 3);
  xfer(0, 32'h3330_0000, 30, 2);
  xfer(1, 32'hCCC8_0000, 30, 2);
  rd_exp(A_FLAGS, 0);
  // ---------------------------------------------- data errors
  wr(A_DTO, 400);                                        // CMD13 with a data phase: no data comes
  sdc(13, {rca, 16'h0}, R48, 1, 1, e);
  xfer_wait(1, "data timeout"); wr(A_IRQ_STATUS, IRQ_ALL);
  rd(A_STATUS); if (!rdv[7 + 0]) fail($sformatf("data timeout: STATUS %h", rdv));
  wr(A_DTO, 32'hFF_FFFF);
  card.f_rd_crc = 1; xbad(1, 2, 1, "read CRC16");
  card.f_rd_end = 1; xbad(1, 2, 2, "read end bit");
  card.f_wtok = 1;   xbad(0, 2, 3, "write CRC status");
  xbad(1, 2, 4, "invalid descriptor", 1);
  rd(A_ADMA_CUR); if (rdv[31:20] !== 12'h023) fail($sformatf("ADMA_CUR %h", rdv));
  axm.err_lo = 32'h0230_0000; axm.err_hi = 32'h0238_0000; // the buffers only (lower half), the table is in the upper half
  xbad(1, 2, 5, "AXI write error");                      // SLVERR on the data writes
  xbad(0, 2, 5, "AXI read error");                       // SLVERR on the data reads
  axm.err_lo = 32'hFFFF_FFFF; axm.err_hi = 32'hFFFF_FFFF;
  xbad(1, 2, 6, "short table", 0, 1);
  wr(A_IRQ_ENABLE, 32'h17);                              // XFER_ERR masked
  card.f_mute = 1; xbad(1, 1, 7, "data command failed");
  wr(A_IRQ_ENABLE, 32'h1F);
  // DAT_RESET mid-transfer
  build(32'h0240_0000, 4 * 128);
  wr(A_BLK, {4'd0, 16'd4, 12'd512});
  sdc(18, 4, R48, 1, 1, e);
  cycles(1500);
  wr(A_CMD, 32'h2);
  xfer_wait(1, "DAT_RESET"); wr(A_IRQ_STATUS, IRQ_ALL);
  rd(A_STATUS); if (rdv[14:7] !== 8'h00) fail($sformatf("DAT_RESET: d_err %h", rdv[14:7]));
  sdc_ok(12, 0, R1B);
  cycles(3000);
  xfer(0, 32'h0998_0000, 40, 2, 0, "after the errors");
  xfer(1, 32'h0990_0000, 40, 2, 0, "after the errors");
  // ---------------------------------------------- eMMC, 8-bit
  card.emmc = 1; card.insert();
  wr(A_CFG, {19'd0, 2'd0, 1'b1, 10'd3});
  sdc_ok(0, 0, R0);
  begin
    int n;
    n = 0;
    do begin sdc_ok(1, 32'h40FF_FF80, R48, 0); rd(A_RSP0); n++; end while (!rdv[31] && n < 10);
    if (rdv[30:29] !== 2'b10 || rdv[14:13] !== 2'b11) fail($sformatf("CMD1 OCR %h", rdv));
  end
  sdc_ok(2, 0, R136);
  sdc_ok(3, 32'h0001_0000, R48);
  sdc_ok(7, 32'h0001_0000, R1B);
  sdc_ok(6, {6'd0, 2'b11, 8'd183, 8'd2, 8'd0}, R1B);
  wr(A_CFG, {19'd0, 2'd2, 1'b1, 10'd0});                 // 8-bit, DIV 0
  xfer(0, 32'h0770_0000, 10, 3, 0, "eMMC 8-bit");
  xfer(1, 32'h0778_0000, 10, 3, 0, "eMMC 8-bit");
`ifdef VERILATOR
  // 65535 blocks of 4 bytes: BLK_DONE counts to 0xFFFF (descriptors of 65536 bytes)
  sdc_ok(16, 4, R48);
  begin
    logic [31:0] t;
    t = 32'h0E08_0000;
    wr(A_ADMA_ADDR, t);
    for (int k = 0; k < 4; k++) begin
      axm.poke(t + 32'(8 * k), {16'd0, 10'd0, 6'b100001 | ((k == 3) ? 6'b000010 : 6'b0)});
      axm.poke(t + 32'(8 * k) + 4, 32'h0E00_0000 + 32'(k) * 32'h1_0000);
    end
  end
  wr(A_BLK, {4'd0, 16'hFFFF, 12'd4});
  sdc(25, 0, R48, 1, 2, e);
  xfer_wait(0, "65535 blocks", 4000000);
  wr(A_IRQ_STATUS, IRQ_ALL);
  rd_exp(A_BLK_DONE, 32'hFFFF);
  sdc_ok(12, 0, R1B);
  sdc_ok(16, 512, R48);
`endif
  if (card.errors != 0) fail($sformatf("%0d card model errors", card.errors));
  if (axm.errors != 0) fail($sformatf("%0d AXI memory errors", axm.errors));
  // CMD_DONE left pending into the final reset
  wr(A_CMD_ARG, 32'h0001_0000); wr(A_CMD_CTRL, {20'd0, 2'd0, 1'b1, 1'b1, 2'd1, 6'd13}); wr(A_CMD, 1);
  poll(A_IRQ_STATUS, 32'h1, 32'h1, 40000);
  wr(A_CFG, 32'h0F9); wr(A_BLK, {4'd0, 16'd1, 12'h200}); wr(A_DTO, 32'hFF_FFFF);
  wr(A_ADMA_ADDR, 0); wr(A_CMD_ARG, 0); wr(A_CMD_CTRL, 32'h300);
endtask
