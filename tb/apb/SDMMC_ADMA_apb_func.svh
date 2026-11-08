// SPDX-License-Identifier: Apache-2.0
// SDMMC_ADMA-specific part of tb/SDMMC_ADMA_apb_tb.sv: a behavioural AXI4
// memory on the m_* pins and the SD card model of tb/sdmmc_card_model.svh on
// the bus pins. Through the registers: SD identification (CMD0, CMD8,
// ACMD41 polling, CMD2 with the CID in RSP3..0, CMD3, CMD7), ACMD6 and
// CFG.bus_w = 4-bit, then a 4-block CMD25 write and a CMD18 read-back over
// two-descriptor ADMA2 tables (XFER_DONE, DMA_INT, BLK_DONE), each ended by
// CMD12, and an invalid descriptor (XFER_ERR, STATUS.d_err bit 4,
// ADMA_CUR). eMMC, 8-bit, the other errors and back-pressure are in
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
// one command; returns STATUS.c_err
task automatic sdc(input logic [5:0] idx, input logic [31:0] arg, input int rt, input bit chk,
                   input int dta, output logic [4:0] e);
  int k;
  wr(A_CMD_ARG, arg);
  wr(A_CMD_CTRL, {20'd0, 2'(dta), chk, chk, 2'(rt), idx});
  wr(A_CMD, 1);
  k = 0;
  while (!irq && k < 200000) begin @(negedge PCLK); k++; end   // the DMA may interrupt first
  poll(A_IRQ_STATUS, 32'h1 << IRQ_CMD_DONE, 32'h1 << IRQ_CMD_DONE, 20000);
  wr(A_IRQ_STATUS, 32'h3);
  rd(A_STATUS); e = rdv[6:2];
endtask
task automatic sdc_ok(input logic [5:0] idx, input logic [31:0] arg, input int rt, input bit chk = 1);
  logic [4:0] e;
  sdc(idx, arg, rt, chk, 0, e);
  if (e != 0) fail($sformatf("CMD%0d: c_err %b", idx, e));
endtask
// two-descriptor table at t: n0 words at a0 (int), the rest at a1 (end)
task automatic table2(input logic [31:0] t, input logic [31:0] a0, input int n0,
                      input logic [31:0] a1, input int n1);
  axm.poke(t,      {16'(n0 * 4), 10'd0, 6'b100101}); axm.poke(t + 4,  a0);
  axm.poke(t + 8,  {16'(n1 * 4), 10'd0, 6'b100011}); axm.poke(t + 12, a1);
endtask
task automatic xfer_wait(input bit want_err, input string what);
  poll(A_IRQ_STATUS, 32'h1 << IRQ_XFER_DONE, 32'h1 << IRQ_XFER_DONE, 20000);
  if (rdv[IRQ_XFER_ERR] !== want_err) fail($sformatf("%s: XFER_ERR %b", what, rdv[IRQ_XFER_ERR]));
endtask
task automatic ip_func;
  logic [4:0]  e;
  logic [15:0] rca;
  logic [31:0] buf_a [2];
  int          t0;
  for (int i = 0; i < 64 * 512; i++) card.mem[i] = $urandom;
  wr(A_IRQ_ENABLE, 32'h1F);
  wr(A_CFG, {19'd0, 2'd0, 1'b1, 10'd3});                 // 1-bit, clk on, DIV 3
  cycles(200);
  sdc_ok(0, 0, 0);
  sdc_ok(8, 32'h1AA, 1); rd_exp(A_RSP0, 32'h1AA);
  begin
    int n;
    n = 0;
    do begin sdc_ok(55, 0, 1); sdc_ok(41, 32'h40FF_8000, 1, 0); rd(A_RSP0); n++; end
    while (!rdv[31] && n < 10);
    if (!rdv[31]) fail("ACMD41 never ready");
  end
  sdc_ok(2, 0, 2);
  rd_exp(A_RSP0, card.cid[31:0]); rd_exp(A_RSP1, card.cid[63:32]);
  rd_exp(A_RSP2, card.cid[95:64]); rd_exp(A_RSP3, card.cid[127:96]);
  sdc_ok(3, 0, 1); rd(A_RSP0); rca = rdv[31:16];
  sdc_ok(7, {rca, 16'h0}, 3);
  sdc_ok(55, {rca, 16'h0}, 1); sdc_ok(6, 2, 1);
  wr(A_CFG, {19'd0, 2'd1, 1'b1, 10'd0});                 // 4-bit, DIV 0
  // write 4 blocks from two buffers, read them back into two others
  buf_a[0] = 32'h0010_0400; buf_a[1] = 32'h0010_2000;
  for (int i = 0; i < 512; i++) axm.poke((i < 200 ? buf_a[0] : buf_a[1] - 800) + 32'(4 * i), $urandom);
  table2(32'h0011_0000, buf_a[0], 200, buf_a[1], 312);
  wr(A_ADMA_ADDR, 32'h0011_0000);
  wr(A_BLK, {4'd0, 16'd4, 12'd512});
  t0 = pcyc;
  sdc(25, 8, 1, 1, 2, e); if (e != 0) fail($sformatf("CMD25: c_err %b", e));
  xfer_wait(0, "write");
  $display("LAT apb SDMMC_ADMA W %0d", pcyc - t0);
  if (!rdv[IRQ_DMA_INT]) fail("no DMA_INT for the int descriptor");
  wr(A_IRQ_STATUS, IRQ_ALL);
  rd_exp(A_BLK_DONE, 4);
  sdc_ok(12, 0, 3);
  for (int i = 0; i < 512; i++) begin
    logic [31:0] m, c;
    int b;
    b = 8 * 512 + 4 * i;
    m = axm.peek((i < 200 ? buf_a[0] : buf_a[1] - 800) + 32'(4 * i));
    c = {card.mem[b + 3], card.mem[b + 2], card.mem[b + 1], card.mem[b]};
    if (m !== c) begin fail($sformatf("write word %0d: card %h, memory %h", i, c, m)); i = 512; end
  end
  table2(32'h0011_0100, 32'h0012_0000, 312, 32'h0012_4000, 200);
  wr(A_ADMA_ADDR, 32'h0011_0100);
  t0 = pcyc;
  sdc(18, 8, 1, 1, 1, e); if (e != 0) fail($sformatf("CMD18: c_err %b", e));
  xfer_wait(0, "read");
  $display("LAT apb SDMMC_ADMA R %0d", pcyc - t0);
  wr(A_IRQ_STATUS, IRQ_ALL);
  sdc_ok(12, 0, 3);
  for (int i = 0; i < 512; i++) begin
    logic [31:0] m, w;
    w = (i < 200 ? buf_a[0] : buf_a[1] - 800) + 32'(4 * i);
    m = axm.peek((i < 312 ? 32'h0012_0000 : 32'h0012_4000 - 32'd1248) + 32'(4 * i));
    if (m !== axm.peek(w)) begin fail($sformatf("read-back word %0d: %h, wrote %h", i, m, axm.peek(w))); i = 512; end
  end
  // invalid descriptor (valid = 0)
  axm.poke(32'h0011_0200, 32'h0200_0020); axm.poke(32'h0011_0204, 32'h0012_8000);
  wr(A_ADMA_ADDR, 32'h0011_0200);
  wr(A_BLK, {4'd0, 16'd1, 12'd512});
  sdc(17, 0, 1, 1, 1, e);
  xfer_wait(1, "invalid descriptor");
  wr(A_IRQ_STATUS, IRQ_ALL);
  rd(A_STATUS); if (!rdv[7 + 4]) fail($sformatf("STATUS %h: d_err bit 4 expected", rdv));
  rd_exp(A_ADMA_CUR, 32'h0011_0200);
  cycles(3000);                                          // the card finishes its block
  if (card.errors != 0) fail($sformatf("%0d card model errors", card.errors));
  if (axm.errors != 0) fail($sformatf("%0d AXI memory errors", axm.errors));
  wr(A_IRQ_ENABLE, 0);
  wr(A_CFG, 32'h0F9); wr(A_BLK, {4'd0, 16'd1, 12'h200}); wr(A_DTO, 32'hFF_FFFF);
  wr(A_ADMA_ADDR, 0); wr(A_CMD_ARG, 0); wr(A_CMD_CTRL, 32'h300);
endtask
