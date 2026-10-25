// SPDX-License-Identifier: Apache-2.0
// QSPI-specific part of tb/QSPI_apb_tb.sv. A TB QSPI master drives csn /
// sclk and the io bits it owns (MOSI in standard mode, all four in a quad
// write) and samples the others.
// Covered through the registers: TX written and read back; standard
// transfers (MISO out, MOSI in), quad reads (TX out on io[3:0]) and quad
// writes (RX in from io[3:0]) selected through MODE and DIR; BYTE per
// byte; a partial write dropped with PSLVERR.
logic [3:0] m_oe = 0, m_v = 0;
for (genvar i = 0; i < 4; i++) begin : g_m
  assign io[i] = m_oe[i] ? m_v[i] : 1'bz;
end
initial begin csn = 1; sclk = 0; end
task automatic sclk_pulse;
  sclk = 1; cycles(3);
  sclk = 0; cycles(3);
endtask
task automatic std_xfer(input logic [7:0] o, output logic [7:0] i);
  @(negedge PCLK) csn = 0; m_oe = 4'b0001;
  cycles(2);
  for (int b = 7; b >= 0; b--) begin
    m_v = {3'b0, o[b]};
    cycles(2);
    i[b] = io[1];
    sclk_pulse();
  end
  csn = 1; m_oe = 0;
  cycles(3);
endtask
task automatic quad_read(output logic [7:0] i);
  @(negedge PCLK) csn = 0; m_oe = 0;
  cycles(2);
  for (int n = 1; n >= 0; n--) begin
    cycles(1);
    i[4*n +: 4] = io;
    sclk_pulse();
  end
  csn = 1;
  cycles(3);
endtask
task automatic quad_write(input logic [7:0] o);
  @(negedge PCLK) csn = 0; m_oe = 4'hF;
  cycles(2);
  for (int n = 1; n >= 0; n--) begin
    m_v = o[4*n +: 4];
    cycles(2);
    sclk_pulse();
  end
  csn = 1; m_oe = 0;
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
  rd_exp(A_FLAGS, 0);
  wr(A_RX, 32'hFF);                                      // read-only: ignored
  rd_exp(A_MODE, 0); rd_exp(A_DIR, 0);                   // write-only: read 0
  wr(A_TX, 32'hFF); rd_exp(A_TX, 32'hFF);
  wr(A_TX, 32'h00); rd_exp(A_TX, 32'h00);
  apb(1, A_MODE, 32'h1, 4'h1 << 1);                      // partial: dropped
  if (!rerr) fail("no PSLVERR on a partial write to MODE");
  wr(A_IRQ_ENABLE, IRQ_ALL);
  // standard
  for (int k = 0; k < 8; k++) begin
    t = k == 0 ? 8'hFF : k == 1 ? 8'h00 : 8'($urandom);
    m = k == 0 ? 8'hFF : k == 1 ? 8'h00 : 8'($urandom);
    wr(A_TX, t);
    std_xfer(m, got);
    if (got !== t) fail($sformatf("MISO %h, expected %h", got, t));
    rd_exp(A_RX, m);
    irq_expect(IRQ_BYTE);
  end
  // quad read, then quad write
  wr(A_MODE, 32'hFF); wr(A_DIR, 0);
  for (int k = 0; k < 8; k++) begin
    t = k == 0 ? 8'hFF : k == 1 ? 8'h00 : 8'($urandom);
    wr(A_TX, t);
    quad_read(got);
    if (got !== t) fail($sformatf("quad read %h, expected %h", got, t));
    irq_expect(IRQ_BYTE);
  end
  wr(A_DIR, 32'hFFFF_FFFF);
  for (int k = 0; k < 8; k++) begin
    m = k == 0 ? 8'hFF : k == 1 ? 8'h00 : 8'($urandom);
    quad_write(m);
    rd_exp(A_RX, m);
    irq_expect(IRQ_BYTE);
  end
  wr(A_DIR, 0); wr(A_MODE, 0);
  // masked, left pending into reset
  wr(A_IRQ_ENABLE, 0);
  std_xfer(8'h42, got);
  if (irq) fail("irq with BYTE masked");
  rd_exp(A_IRQ_STATUS, 32'(1) << IRQ_BYTE);
endtask
