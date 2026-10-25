// SPDX-License-Identifier: Apache-2.0
// AVSBus__Adaptive_Voltage_Scaling_-specific part of
// tb/AVSBus__Adaptive_Voltage_Scaling__apb_tb.sv. The TB is the AVSBus
// master: sclk with 60 ns phases, sdat open drain with a pullup.
// Checked: the ACK of good frames and the NACK of bad ones, GET readback
// and its CRC, STATUS against the pins, the ramp seen through STATUS
// (busy, vdac moving monotonically to the target), a frame abandoned
// mid-way and dropped after the timeout.
// Covered through the registers: ERROR from a bad CRC, an unknown command
// and a SET code out of range (none from another address), masked, raising
// irq and cleared.
pullup (sdat);
logic m_oe = 0, m_bit = 0;
assign sdat = (m_oe && !m_bit) ? 1'b0 : 1'bz;
initial sclk = 0;
localparam logic [7:0] C_SET = 8'h01, C_GET = 8'h02;

function automatic logic [3:0] c4(input logic [3:0] c, input logic b);
  logic fb;
  fb = b ^ c[3];
  return {c[2], c[1], c[0] ^ fb, fb};
endfunction
function automatic logic [3:0] crc_n(input logic [30:0] d, input int n);
  logic [3:0] c;
  c = 0;
  for (int i = n - 1; i >= 0; i--) c = c4(c, d[i]);
  return c;
endfunction
task automatic m_tx(input logic b);
  m_oe = 1; m_bit = b;
  #60 sclk = 1;
  #60 sclk = 0;
  #20;
endtask
task automatic m_rx(output logic b);
  m_oe = 0;
  #60 sclk = 1;
  #20 b = sdat;
  #40 sclk = 0;
  #20;
endtask
// a frame; bad: CRC corrupted
task automatic frame(input logic [6:0] a, input logic [7:0] c, input logic [15:0] d, input bit bad,
                     output bit ack, output logic [15:0] r);
  logic [30:0] p;
  logic [3:0]  k, rk;
  logic        b;
  p = {a, c, d};
  k = crc_n(p, 31) ^ {3'b0, bad};
  r = 0;
  m_tx(1);
  for (int i = 30; i >= 0; i--) m_tx(p[i]);
  for (int i = 3; i >= 0; i--) m_tx(k[i]);
  m_rx(b);
  ack = b === 1'b0;
  if (ack && c == C_GET) begin
    for (int i = 15; i >= 0; i--) begin m_rx(b); r[i] = b; end
    for (int i = 3; i >= 0; i--) begin m_rx(b); rk[i] = b; end
    if (rk !== crc_n({15'd0, r}, 16)) fail($sformatf("GET readback CRC %h for %h", rk, r));
  end
  m_oe = 0;
  cycles(4);
endtask
task automatic status_pins;
  rd(A_STATUS);
  if (rdv !== {19'd0, busy, vdac}) fail($sformatf("STATUS %h, pins busy %b vdac %h", rdv, busy, vdac));
endtask
task automatic irq_expect(input int b);
  cycles(2);
  rd(A_IRQ_STATUS);
  if (!rdv[b]) fail($sformatf("IRQ bit %0d not set (%h)", b, rdv));
  if (!irq) fail("irq low with an enabled bit set");
  wr(A_IRQ_STATUS, 32'(1) << b);
endtask
task automatic no_irq;
  cycles(2);
  rd(A_IRQ_STATUS);
  if (rdv != 0) fail($sformatf("IRQ_STATUS %h, expected 0", rdv));
endtask
// SET, the ramp watched through STATUS, then GET
task automatic set_code(input logic [11:0] v);
  bit ack;
  logic [15:0] r;
  logic [11:0] last;
  int k, s0;
  s0 = vdac;
  frame(7'h55, C_SET, {4'h0, v}, 0, ack, r);
  if (!ack) fail($sformatf("SET %h not acknowledged", v));
  rd(A_STATUS);
  last = rdv[11:0];
  k = 0;
  while (rdv[12] && k < 200) begin
    rd(A_STATUS);
    if (v > last ? (rdv[11:0] < last || rdv[11:0] > v) : (rdv[11:0] > last || rdv[11:0] < v))
      fail($sformatf("vdac %h not moving from %h toward %h", rdv[11:0], last, v));
    if (rdv[12] && (int'(rdv[11:0]) - s0) % 10 != 0)
      fail($sformatf("vdac %h not a 10-code step from %h", rdv[11:0], s0));
    last = rdv[11:0]; k++;
  end
  if (rdv !== {19'd0, 1'b0, v}) fail($sformatf("STATUS %h after the ramp to %h", rdv, v));
  status_pins();
  frame(7'h55, C_GET, 0, 0, ack, r);
  if (!ack || r !== {4'h0, v}) fail($sformatf("GET %b %h, expected %h", ack, r, v));
endtask

task automatic ip_func;
  bit ack;
  logic [15:0] r;
  wr(A_IRQ_ENABLE, IRQ_ALL);
  rd_exp(A_STATUS, 0);
  rd_exp(A_FLAGS, 0);
  set_code(12'hFFF);
  set_code(12'h000);
  set_code(12'hA5A);
  set_code(12'h5A5);
  for (int i = 0; i < 3; i++) set_code(12'($urandom));
  no_irq();
  // NACKed frames to our address: ERROR, voltage unchanged
  frame(7'h55, C_SET, 16'h0123, 1, ack, r);
  if (ack) fail("bad CRC acknowledged");
  irq_expect(IRQ_ERROR);
  frame(7'h55, 8'h7E, 16'h0123, 0, ack, r);
  if (ack) fail("unknown command acknowledged");
  irq_expect(IRQ_ERROR);
  frame(7'h55, C_SET, 16'h1123, 0, ack, r);
  if (ack) fail("SET out of range acknowledged");
  irq_expect(IRQ_ERROR);
  status_pins();
  if (busy) fail("busy after NACKed frames");
  // another address: no ACK, no ERROR
  frame(7'h2A, C_SET, 16'h0123, 0, ack, r);
  if (ack) fail("another address acknowledged");
  frame(7'h2A, C_SET, 16'h0123, 1, ack, r);
  no_irq();
  // abandoned frame: dropped after the timeout, the next one decoded
  m_tx(1);
  for (int i = 0; i < 10; i++) m_tx(1);
  m_oe = 0;
  cycles(1100);
  set_code(12'h321);
  // masked: left pending into reset
  wr(A_IRQ_ENABLE, 0);
  frame(7'h55, C_SET, 16'h0456, 1, ack, r);
  cycles(3);
  if (irq) fail("irq with every interrupt masked");
  rd_exp(A_IRQ_STATUS, IRQ_ALL);
  // reset in the middle of a ramp
  frame(7'h55, C_SET, 16'h0FF0, 0, ack, r);
  rd(A_STATUS);
  if (!rdv[12]) fail("busy low right after a SET");
endtask
