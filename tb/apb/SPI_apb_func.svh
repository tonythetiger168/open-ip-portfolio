// SPDX-License-Identifier: Apache-2.0
// SPI-specific part of tb/SPI_apb_tb.sv. A TB SPI master (mode 0, MSB
// first) drives csn / sclk / mosi and samples miso.
// Covered through the registers: TX written and read back, shifted out on
// MISO; RX holding the byte shifted in; BYTE once per byte; a transfer cut
// by CSn restarting the bit count; MISO high-Z while CSn is high; a partial write dropped with PSLVERR.
initial begin csn = 1; sclk = 0; mosi = 0; end
// one byte: mosi out, miso in; stop after n bits (8: a whole byte)
task automatic xfer(input logic [7:0] o, output logic [7:0] i, input int n);
  i = 0;
  @(negedge PCLK) csn = 0;
  cycles(2);
  for (int b = 7; b > 7 - n; b--) begin
    mosi = o[b];
    cycles(2);
    i[b] = miso;
    sclk = 1; cycles(3);
    sclk = 0; cycles(2);
  end
  csn = 1; mosi = $urandom;
  cycles(3);
endtask
task automatic irq_expect(input int b);
  cycles(3);
  rd(A_IRQ_STATUS);
  if (!rdv[b]) fail($sformatf("IRQ bit %0d not set (%h)", b, rdv));
  if (!irq) fail("irq low with an enabled bit set");
  wr(A_IRQ_STATUS, 32'(1) << b);
endtask

task automatic ip_func;
  logic [7:0] t, m, got;
`ifndef VERILATOR   // Verilator does not keep Z through the wrapper port (tb/SPI_tb.sv checks it on the core)
  if (miso !== 1'bz) fail("MISO driven while CSn is high");
`endif
  rd_exp(A_FLAGS, 0);
  wr(A_RX, 32'hFF);                                      // read-only: ignored
  rd_exp(A_RX, 0);
  wr(A_TX, 32'hFF); rd_exp(A_TX, 32'hFF);
  wr(A_TX, 32'h00); rd_exp(A_TX, 32'h00);
  apb(1, A_TX, 32'hA5, 4'h2);                            // partial: dropped
  if (!rerr) fail("no PSLVERR on a partial write to TX");
  rd_exp(A_TX, 0);
  wr(A_IRQ_ENABLE, IRQ_ALL);
  for (int k = 0; k < 20; k++) begin
    t = $urandom; m = $urandom;
    if (k == 0) begin t = 8'hFF; m = 8'hFF; end
    if (k == 1) begin t = 8'h00; m = 8'h00; end
    wr(A_TX, t);
    xfer(m, got, 8);
    if (got !== t) fail($sformatf("MISO %h, expected %h", got, t));
    rd_exp(A_RX, m);
    irq_expect(IRQ_BYTE);
  end
  // a transfer cut after 3 bits: no byte; the next one starts afresh
  wr(A_TX, 8'h3C);
  xfer(8'hE0, got, 3);
  rd(A_IRQ_STATUS);
  if (rdv[IRQ_BYTE]) fail("BYTE after 3 bits");
  xfer(8'h96, got, 8);
  if (got !== 8'h3C) fail($sformatf("MISO %h after a cut transfer, expected 3c", got));
  rd_exp(A_RX, 8'h96);
  irq_expect(IRQ_BYTE);
  // masked, left pending into reset
  wr(A_IRQ_ENABLE, 0);
  xfer(8'h11, got, 8);
  if (irq) fail("irq with BYTE masked");
  rd_exp(A_IRQ_STATUS, 32'(1) << IRQ_BYTE);
endtask
