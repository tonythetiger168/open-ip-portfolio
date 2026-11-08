// SPDX-License-Identifier: Apache-2.0
// I2S_DMA-specific part of tb/I2S_DMA_apb_tb.sv: a behavioural AXI4 memory on
// the m_* pins and an I2S master (BCLK = 2 * bh PCLK, 16-bit slots) on the
// I2S pins. Through the registers:
// - a TX + RX job of 12 frames (the RX words are 12 consecutive frames sent
//   after START, TX plays the 12 words in order, FRAMES = 12, XRUN = 0,
//   DONE interrupt, START ignored while busy);
// - 24 jobs of 1..40 words at random buffer addresses, TX + RX, TX only or
//   RX only, each checked word for word; some with the interrupts masked;
// - AXI SLVERR on a TX read and on an RX write (STATUS.err, ERR, masked too);
// - LEN = 0 (DONE at once, no AXI traffic);
// - Verilator only: a 32768-word TX + RX job with both AXI paths blocked for
//   its first 33000 frames (XRUN counts above 0x8000 on both sides), BCLK =
//   4 PCLK, about 9M clocks.
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
localparam int NF = 4096;                 // frames recorded / sent with known data
logic [31:0] smp [NF];
logic [31:0] got [NF];
int          falls = 0;
int          bh = 4;                      // half BCLK period, PCLK cycles
initial begin
  bclk = 0; lrck = 0; sdin = 0;
  for (int f = 0; f < NF; f++) smp[f] = $urandom;
  @(posedge PRESETN);
  forever begin
    repeat (bh) @(posedge PCLK); #1 bclk = 1;
    if (falls >= 1 && (falls - 1) / 32 < NF) begin
      int s, b; s = (falls - 1) / 16; b = 15 - (falls - 1) % 16;
      got[s / 2][(s % 2) * 16 + b] = sdout;
    end
    repeat (bh) @(posedge PCLK); #1 bclk = 0;
    falls++;
    if (falls % 16 == 0) lrck = (falls / 16) % 2;
    begin
      int s, b; s = (falls - 1) / 16; b = 15 - (falls - 1) % 16;
      if (s / 2 < NF) sdin = smp[s / 2][(s % 2) * 16 + b];
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
// wait for DONE through IRQ_STATUS (works with the interrupts masked)
task automatic job_wait(input logic [31:0] st);
  poll(A_IRQ_STATUS, 32'h1, 32'h1, 40000);
  rd_exp(A_IRQ_STATUS, st);
endtask
// one checked job: n words, TX from s, RX to d
task automatic job_chk(input logic [31:0] s, input logic [31:0] d, input int n, input bit tx,
                       input bit rx);
  int f0;
  for (int i = 0; i < n; i++) begin
    axm.poke(s + 32'(4 * i), $urandom);
    axm.poke(d + 32'(4 * i), 32'hBAD0_0000);
  end
  i2s_job(s, d, n, tx, rx, f0);
  job_wait(32'h1);
  rd_exp(A_FRAMES, 32'(n));
  rd_exp(A_XRUN, 0);
  wr(A_IRQ_STATUS, 32'h3);
  while (falls < 32 * (f0 + n + 3)) @(negedge PCLK);
  for (int i = 0; i < n; i++) begin
    if (rx && axm.peek(d + 32'(4 * i)) !== smp[f0 + 1 + i])
      fail($sformatf("RX word %0d %h, frame %h", i, axm.peek(d + 32'(4 * i)), smp[f0 + 1 + i]));
    if (tx && got[f0 + 1 + i] !== axm.peek(s + 32'(4 * i)))
      fail($sformatf("TX frame %0d %h, word %h", i, got[f0 + 1 + i], axm.peek(s + 32'(4 * i))));
  end
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
  // random buffers: every address bit, burst lengths 1..16, the three modes
  for (int j = 0; j < 24; j++) begin
    logic [31:0] s;
    int n, m;
    s = $urandom & 32'hFFFF_FFFC; if (s > 32'hFFFF_FE00) s -= 32'h200;
    if (j < 2) s = (j == 0) ? 32'hFFFF_F000 : 32'h0000_0F00;
    n = 1 + $urandom % 40;
    m = j % 3;
    wr(A_IRQ_ENABLE, (j % 4 == 3) ? 32'h0 : 32'h3);
    job_chk(s, ~s & 32'hFFFF_FFFC, n, m != 2, m != 1);
  end
  rd_exp(A_FLAGS, 0);
  wr(A_IRQ_ENABLE, 32'h3);
  // AXI error on a TX read: STATUS.err, ERR interrupt
  axm.err_lo = 32'h0000_1008; axm.err_hi = 32'h0000_100C;
  i2s_job(32'h0000_1000, 32'h0000_8000, 4, 1, 0, f0);
  k = 0;
  while (!irq && k < 20000) begin @(negedge PCLK); k++; end
  rd_exp(A_IRQ_STATUS, 32'h3);
  rd(A_STATUS); if (rdv[1] !== 1'b1) fail("STATUS.err low after an SLVERR");
  wr(A_IRQ_STATUS, 32'h3);
  // AXI error on an RX write, interrupts masked
  wr(A_IRQ_ENABLE, 32'h0);
  axm.err_lo = 32'h0000_8000; axm.err_hi = 32'h0000_8010;
  i2s_job(32'h0000_1000, 32'h0000_8000, 4, 0, 1, f0);
  job_wait(32'h3);
  if (irq !== 1'b0) fail("irq high with DONE / ERR masked");
  rd(A_STATUS); if (rdv[1] !== 1'b1) fail("STATUS.err low after a write SLVERR");
  wr(A_IRQ_STATUS, 32'h3);
  axm.err_lo = '1; axm.err_hi = '1;
  wr(A_IRQ_ENABLE, 32'h3);
  // LEN = 0: DONE at once, no AXI traffic
  k = axm.n_rd_bursts;
  i2s_job(32'h0000_1000, 32'h0000_8000, 0, 1, 1, f0);
  cycles(20);
  rd_exp(A_IRQ_STATUS, 32'h1);
  if (axm.n_rd_bursts != k) fail("LEN = 0 job read memory");
  wr(A_IRQ_STATUS, 32'h3);
`ifdef VERILATOR
  // 32768 words with both AXI paths blocked for the first 33000 frames
  bh = 2;
  axm.ar_hold = 1; axm.aw_hold = 1;
  i2s_job(32'h0010_0000, 32'h0020_0000, 32768, 1, 1, f0);
  while (falls < 32 * (f0 + 33000)) @(negedge PCLK);
  axm.ar_hold = 0; axm.aw_hold = 0;
  poll(A_IRQ_STATUS, 32'h1, 32'h1, 4000000);
  rd_exp(A_FRAMES, 32768);
  rd(A_XRUN);
  if (rdv[15:0] < 16'h8000 || rdv[31:16] < 16'h8000) fail($sformatf("XRUN %h after the blocked paths", rdv));
  wr(A_IRQ_STATUS, 32'h3);
  bh = 4;
`endif
  if (axm.errors != 0) fail("AXI rule violations");
  // DONE left pending into the final reset, with the interrupts masked
  wr(A_IRQ_ENABLE, 0);
  i2s_job(32'h0000_1000, 32'h0000_8000, 2, 1, 0, f0);
  poll(A_IRQ_STATUS, 32'h1, 32'h1, 40000);
endtask
