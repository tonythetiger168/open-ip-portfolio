// SPDX-License-Identifier: Apache-2.0
// _1_Wire-specific part of tb/_1_Wire_apb_tb.sv. The TB is the 1-Wire
// controller on dq (open drain, pullup), timed in microseconds of 10 PCLK
// clocks: reset pulses, write slots, read slots.
// Checked: the presence pulse after every reset (also one in the middle of
// a byte), bytes written arriving in RX, the byte read back equal to TX,
// a short low pulse not taken as a reset, STATUS.busy.
// Covered through the registers: BYTE, RX_AVAIL, RX_OVF, RX read in the
// clock a byte lands, every interrupt masked and left pending into reset.
pullup (dq);
logic m_low = 0;
assign dq = m_low ? 1'b0 : 1'bz;
task automatic us(input int n); cycles(10 * n); endtask
task automatic ow_reset(input bit expect_pres = 1);
  bit seen;
  m_low = 1; us(500);
  m_low = 0; us(5);
  seen = 0;
  for (int t = 0; t < 140; t++) begin us(1); if (dq === 1'b0) seen = 1; end
  if (seen != expect_pres) fail($sformatf("presence pulse %0s", seen ? "seen" : "missing"));
  us(10);
endtask
task automatic ow_wbit(input bit b);
  m_low = 1;
  if (b) begin us(3); m_low = 0; us(60); end
  else begin us(62); m_low = 0; us(3); end
  us(5);
endtask
task automatic ow_rbit(output bit b);
  m_low = 1; us(2);
  m_low = 0; us(10);
  b = dq !== 1'b0;
  us(45);
endtask
task automatic ow_wbyte(input logic [7:0] d);
  for (int i = 0; i < 8; i++) ow_wbit(d[i]);
endtask
task automatic ow_rbyte(output logic [7:0] d);
  bit b;
  for (int i = 0; i < 8; i++) begin ow_rbit(b); d[i] = b; end
endtask
task automatic irq_expect(input int b);
  cycles(2);
  rd(A_IRQ_STATUS);
  if (!rdv[b]) fail($sformatf("IRQ bit %0d not set (%h)", b, rdv));
  if (!irq) fail("irq low with an enabled bit set");
  wr(A_IRQ_STATUS, 32'(1) << b);
endtask
// a byte written, checked in RX, then TX read back
task automatic xfer(input logic [7:0] d, input logic [7:0] t);
  logic [7:0] r;
  wr(A_TX, t);
  ow_wbyte(d);
  rd_exp(A_FLAGS, 32'(1) << FLAG_RX_AVAIL);
  rd_exp(A_RX, d);
  ow_rbyte(r);
  if (r !== t) fail($sformatf("read %h, expected %h", r, t));
endtask

task automatic ip_func;
  logic [7:0] r;
  rd_exp(A_FLAGS, 0);
  rd_exp(A_STATUS, 0);
  rd_exp(A_RX, 0);                                       // empty
  // a short low pulse: not a reset
  m_low = 1; us(50); m_low = 0; us(20);
  rd_exp(A_STATUS, 0);
  wr(A_IRQ_ENABLE, IRQ_ALL);
  ow_reset();
  rd_exp(A_STATUS, 1);
  xfer(8'hFF, 8'h00);
  irq_expect(IRQ_BYTE);
  irq_expect(IRQ_RX_AVAIL);
  xfer(8'h00, 8'hFF);
  for (int k = 0; k < 6; k++) xfer($urandom, $urandom);
  // a reset in the middle of a byte, and in the middle of the read slots
  ow_wbit(1); ow_wbit(0); ow_wbit(1);
  ow_reset();
  xfer(8'hA5, 8'h3C);
  wr(A_TX, 8'h81);
  ow_wbyte(8'h42); rd_exp(A_RX, 8'h42);
  ow_rbit(r[0]); ow_rbit(r[1]);
  ow_reset();
  xfer(8'h5A, 8'hC3);
  wr(A_IRQ_STATUS, IRQ_ALL);
  // RX read in the clock a byte lands: RX full, the read started at every
  // offset around the last write slot's sample point
  for (int off = 0; off < 6; off++) begin
    ow_wbyte(8'h11); ow_rbyte(r);                        // RX full
    for (int i = 0; i < 7; i++) ow_wbit(1);
    fork
      ow_wbit(0);
      begin cycles(300 + off); apb_now(0, A_RX, 0, 0); end
    join
    ow_rbyte(r);
    rd(A_FLAGS);
    while (rdv[FLAG_RX_AVAIL]) begin rd(A_RX); rd(A_FLAGS); end
  end
  wr(A_IRQ_STATUS, IRQ_ALL);
  // RX full: the second byte is dropped
  ow_wbyte(8'h12); ow_rbyte(r);
  ow_wbyte(8'h34); ow_rbyte(r);
  irq_expect(IRQ_RX_OVF);
  rd_exp(A_RX, 8'h12);
  // masked, left pending into reset
  wr(A_IRQ_ENABLE, 0);
  wr(A_IRQ_STATUS, IRQ_ALL);
  ow_wbyte(8'h56); ow_rbyte(r);
  ow_wbyte(8'h78); ow_rbyte(r);
  cycles(2);
  if (irq) fail("irq with every interrupt masked");
  rd_exp(A_IRQ_STATUS, IRQ_ALL);
endtask
