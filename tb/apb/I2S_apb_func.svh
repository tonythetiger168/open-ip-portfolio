// SPDX-License-Identifier: Apache-2.0
// I2S-specific part of tb/I2S_apb_tb.sv. A TB I2S master drives BCLK,
// LRCK and SDIN (Philips timing, slots of 16 to 32 BCLKs) and samples
// SDOUT.
// Covered through the registers: TX_LEFT / TX_RIGHT sent in their slots,
// RX_LEFT / RX_RIGHT holding the samples received, FRAME on each LRCK
// change, a partial write dropped with PSLVERR, the write-only words
// reading 0.
localparam int HB = 3;                         // clocks per BCLK phase
logic [15:0] m_tx [0:15], m_rx [0:15];
initial begin bclk = 0; lrck = 1; sdin = 0; end
// word w is left when w is even; LRCK set on falling edge w*slot, its bits
// on falling edges w*slot+1 .. w*slot+16, sampled on the next rising edge
task automatic run(input int nw, input int slot);
  int w, b;
  for (int i = 0; i < nw; i++) m_rx[i] = 0;
  for (int k = 0; k <= nw * slot; k++) begin
    bclk = 0;
    lrck = k < nw * slot ? (k / slot) % 2 == 1 : nw % 2 == 1;
    w = (k - 1) / slot; b = (k - 1) % slot;
    sdin = k >= 1 && b < 16 ? m_tx[w][15 - b] : 1'b0;
    cycles(HB);
    bclk = 1;
    if (k >= 1 && b < 16) m_rx[w][15 - b] = sdout;
    cycles(HB);
  end
  bclk = 0;
  cycles(4 * HB);
endtask
task automatic frames(input int nw, input int slot, input logic [15:0] l, input logic [15:0] r);
  wr(A_TX_LEFT, l); wr(A_TX_RIGHT, r);
  lrck = 1; cycles(4 * HB);
  for (int i = 0; i < nw; i++) m_tx[i] = $urandom;
  run(nw, slot);
  for (int i = 0; i < nw; i++)
    if (m_rx[i] !== (i % 2 ? r : l)) fail($sformatf("slot %0d word %0d: SDOUT %h, expected %h", slot, i, m_rx[i], i % 2 ? r : l));
  rd_exp(A_RX_LEFT, m_tx[(nw - 1) & ~1]);
  rd_exp(A_RX_RIGHT, m_tx[(nw - 1) | 1]);
endtask
task automatic irq_expect(input int b);
  cycles(3);
  rd(A_IRQ_STATUS);
  if (!rdv[b]) fail($sformatf("IRQ bit %0d not set (%h)", b, rdv));
  if (!irq) fail("irq low with an enabled bit set");
  wr(A_IRQ_STATUS, 32'(1) << b);
endtask

task automatic ip_func;
  rd_exp(A_FLAGS, 0);
  rd_exp(A_TX_LEFT, 0); rd_exp(A_TX_RIGHT, 0);           // write-only: read 0
  wr(A_RX_LEFT, 32'hFFFF); wr(A_RX_RIGHT, 32'hFFFF);     // read-only: ignored
  apb(1, A_TX_LEFT, 32'h1234, 4'h1);                     // partial: dropped
  if (!rerr) fail("no PSLVERR on a partial write to TX_LEFT");
  wr(A_IRQ_STATUS, IRQ_ALL);
  wr(A_IRQ_ENABLE, IRQ_ALL);
  frames(4, 16, 16'hFFFF, 16'h0000);
  irq_expect(IRQ_FRAME);
  frames(4, 16, 16'h0000, 16'hFFFF);
  for (int i = 0; i < 4; i++) m_tx[i] = 0;
  frames(2, 32, 16'h55AA, 16'h0FF0);
  for (int t = 0; t < 10; t++) frames(2 * (1 + $urandom % 3), 16 + $urandom % 17, $urandom, $urandom);
  irq_expect(IRQ_FRAME);
  // masked, left pending into reset
  wr(A_IRQ_ENABLE, 0);
  frames(2, 16, $urandom, $urandom);
  if (irq) fail("irq with FRAME masked");
  rd_exp(A_IRQ_STATUS, 32'(1) << IRQ_FRAME);
endtask
