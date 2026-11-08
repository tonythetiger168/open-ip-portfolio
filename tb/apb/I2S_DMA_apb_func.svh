// SPDX-License-Identifier: Apache-2.0
// I2S_DMA-specific part of tb/I2S_DMA_apb_tb.sv: a behavioural AXI4 memory on
// the m_* pins and an I2S master (BCLK = 8 PCLK, 16-bit slots) on the I2S
// pins. Through the registers: a TX + RX job of 12 frames (the RX words are
// 12 consecutive frames sent after START, TX plays the 12 words in order,
// FRAMES = 12, XRUN = 0, DONE interrupt), then a TX job over an SLVERR
// region (STATUS.err and the ERR interrupt), LEN = 0 and START while busy.
// The full frame-timing, underrun and overrun checks are in tb/I2S_DMA_tb.sv.
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
logic [31:0] smp [1024];
logic [31:0] got [1024];
int          falls = 0;
initial begin
  bclk = 0; lrck = 0; sdin = 0;
  for (int f = 0; f < 1024; f++) smp[f] = $urandom;
  @(posedge PRESETN);
  forever begin
    repeat (4) @(posedge PCLK); #1 bclk = 1;
    if (falls >= 1 && (falls - 1) / 32 < 1024) begin
      int s, b; s = (falls - 1) / 16; b = 15 - (falls - 1) % 16;
      got[s / 2][(s % 2) * 16 + b] = sdout;
    end
    repeat (4) @(posedge PCLK); #1 bclk = 0;
    falls++;
    if (falls % 16 == 0) lrck = (falls / 16) % 2;
    begin
      int s, b; s = (falls - 1) / 16; b = 15 - (falls - 1) % 16;
      if (s / 2 < 1024) sdin = smp[s / 2][(s % 2) * 16 + b];
    end
  end
end
task automatic i2s_job(input logic [31:0] s, input logic [31:0] d, input int n,
                       input bit tx, input bit rx, output int f0);
  wr(A_SRC_ADDR, s); wr(A_DST_ADDR, d); wr(A_LEN, 32'(n));
  wr(A_CTRL, {30'd0, rx, tx});
  f0 = falls / 32 + 1;
  while (falls != 32 * f0 + 2) @(negedge PCLK);
  apb_now(1, A_CMD, 32'h1, 4'hF);
endtask
task automatic ip_func;
  int f0, k;
  wr(A_IRQ_ENABLE, 32'h3);
  for (int i = 0; i < 12; i++) begin
    axm.poke(32'h0000_1000 + 32'(4 * i), $urandom);
    axm.poke(32'h0000_8000 + 32'(4 * i), 32'hBAD0_0000);
  end
  i2s_job(32'h0000_1000, 32'h0000_8000, 12, 1, 1, f0);
  rd(A_STATUS); if (rdv[0] !== 1'b1) fail("STATUS.busy low after start");
  apb(1, A_CMD, 32'h1, 4'hF);                                // ignored while busy
  k = 0;
  while (!irq && k < 20000) begin @(negedge PCLK); k++; end
  if (!irq) fail("no DONE interrupt");
  rd_exp(A_IRQ_STATUS, 32'h1);
  rd_exp(A_FRAMES, 12);
  rd_exp(A_XRUN, 0);
  rd(A_CYCLES); if (rdv == 0) fail("CYCLES = 0");
  wr(A_IRQ_STATUS, 32'h3);
  while (falls < 32 * (f0 + 15)) @(negedge PCLK);
  for (int i = 0; i < 12; i++) begin
    if (axm.peek(32'h0000_8000 + 32'(4 * i)) !== smp[f0 + 1 + i])
      fail($sformatf("RX word %0d %h, frame %h", i, axm.peek(32'h0000_8000 + 32'(4 * i)), smp[f0 + 1 + i]));
    if (got[f0 + 1 + i] !== axm.peek(32'h0000_1000 + 32'(4 * i)))
      fail($sformatf("TX frame %0d %h, word %h", i, got[f0 + 1 + i], axm.peek(32'h0000_1000 + 32'(4 * i))));
  end
  // AXI error on a TX read: STATUS.err, ERR interrupt
  axm.err_lo = 32'h0000_1008; axm.err_hi = 32'h0000_100C;
  i2s_job(32'h0000_1000, 32'h0000_8000, 4, 1, 0, f0);
  k = 0;
  while (!irq && k < 20000) begin @(negedge PCLK); k++; end
  rd_exp(A_IRQ_STATUS, 32'h3);
  rd(A_STATUS); if (rdv[1] !== 1'b1) fail("STATUS.err low after an SLVERR");
  wr(A_IRQ_STATUS, 32'h3);
  axm.err_lo = '1; axm.err_hi = '1;
  // LEN = 0: DONE at once, no AXI traffic
  k = axm.n_rd_bursts;
  i2s_job(32'h0000_1000, 32'h0000_8000, 0, 1, 1, f0);
  cycles(20);
  rd_exp(A_IRQ_STATUS, 32'h1);
  if (axm.n_rd_bursts != k) fail("LEN = 0 job read memory");
  wr(A_IRQ_STATUS, 32'h3); wr(A_IRQ_ENABLE, 0);
  if (axm.errors != 0) fail("AXI rule violations");
endtask
