// SPDX-License-Identifier: Apache-2.0
// MDIO-specific part of tb/MDIO_apb_tb.sv. The TB is the station
// management entity: MDC with each phase 4 PCLK clocks, MDIO open drain
// with a pullup, Clause 22 frames with a full, short or no preamble.
// Checked against a model of the PHY's 32 registers: writes, reads (the
// turnaround bit driven low, then the data), another PHY address ignored
// on writes and not answered on reads.
// Covered through the registers: FRAME after every frame, masked and left
// pending into reset.
pullup (mdio);
logic m_low = 0;
assign mdio = m_low ? 1'b0 : 1'bz;
initial mdc = 0;
localparam int H = 4;
logic [15:0] preg [0:31];
initial begin for (int i = 0; i < 32; i++) preg[i] = 0; preg[0] = 16'h1140; end
// one MDC clock: the station drives on the low phase, the line is sampled
// just before the rise
task automatic m_bit(input bit drv, input bit b, output bit s);
  m_low = drv && !b; cycles(H);
  s = mdio !== 1'b0;
  mdc = 1; cycles(H);
  mdc = 0;
endtask
task automatic frame(input bit rd, input logic [4:0] pa, input logic [4:0] ra, input logic [15:0] d, input int pre = 32);
  bit s;
  logic [15:0] r;
  logic [31:0] hdr;
  for (int i = 0; i < pre; i++) m_bit(1, 1, s);
  hdr = {2'b01, rd ? 2'b10 : 2'b01, pa, ra, 2'b10, 16'h0};
  for (int i = 31; i >= 18; i--) m_bit(1, hdr[i], s);
  if (rd) begin
    m_bit(0, 1, s);
    m_bit(0, 1, s);
    if (s !== (pa != 5'h0C)) fail($sformatf("turnaround %b (PHY %h)", s, pa));
    for (int i = 15; i >= 0; i--) begin m_bit(0, 1, s); r[i] = s; end
    if (pa == 5'h0C && r !== preg[ra]) fail($sformatf("read reg %0d = %h, expected %h", ra, r, preg[ra]));
    if (pa != 5'h0C && r !== 16'hFFFF) fail("another PHY address answered");
  end else begin
    m_bit(1, 1, s); m_bit(1, 0, s);
    for (int i = 15; i >= 0; i--) m_bit(1, d[i], s);
    if (pa == 5'h0C) preg[ra] = d;
  end
  m_low = 0;
  m_bit(0, 1, s);                                        // idle
endtask
task automatic irq_expect(input int b);
  cycles(2);
  rd(A_IRQ_STATUS);
  if (!rdv[b]) fail($sformatf("IRQ bit %0d not set (%h)", b, rdv));
  if (!irq) fail("irq low with an enabled bit set");
  wr(A_IRQ_STATUS, 32'(1) << b);
endtask

task automatic ip_func;
  rd_exp(A_FLAGS, 0);
  wr(A_IRQ_ENABLE, IRQ_ALL);
  frame(1, 5'h0C, 0, 0);                                 // the ID preset
  irq_expect(IRQ_FRAME);
  frame(0, 5'h0C, 5'h1F, 16'hFFFF); frame(1, 5'h0C, 5'h1F, 0);
  frame(0, 5'h0C, 5'h1F, 16'h0000); frame(1, 5'h0C, 5'h1F, 0);
  for (int k = 0; k < 24; k++) frame($urandom, 5'h0C, $urandom, $urandom, 1 + $urandom % 3);
  for (int i = 0; i < 32; i++) frame(1, 5'h0C, 5'(i), 0, 1);
  // another PHY address (each bit flipped): writes ignored, reads unanswered
  for (int b = 0; b < 5; b++) begin
    frame(0, 5'h0C ^ (5'd1 << b), 5'd3, 16'hDEAD);
    frame(1, 5'h0C ^ (5'd1 << b), 5'd3, 0);
  end
  frame(1, 5'h0C, 5'd3, 0);
  irq_expect(IRQ_FRAME);
  // masked, left pending into reset
  wr(A_IRQ_ENABLE, 0);
  frame(1, 5'h0C, 0, 0);
  cycles(2);
  if (irq) fail("irq with FRAME masked");
  rd_exp(A_IRQ_STATUS, 32'(1) << IRQ_FRAME);
endtask
