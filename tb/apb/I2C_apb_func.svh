// SPDX-License-Identifier: Apache-2.0
// I2C-specific part of tb/I2C_apb_tb.sv. The TB is the I2C controller:
// SCL driven with each phase 4 PCLK clocks, SDA open drain with a pullup.
// Checked: the ACK of our address and of every byte written, no ACK for
// another address, bytes written arriving in RX, bytes read equal to TX
// (changed between bytes), STATUS.busy from our address to the STOP or
// the NACK, a repeated START.
// Covered through the registers: BYTE, RX_AVAIL, RX_OVF (a byte arriving
// while RX is full), every interrupt masked and left pending into reset.
pullup (sda);
logic m_low = 0;                                         // controller pulls SDA low
assign sda = m_low ? 1'b0 : 1'bz;
initial scl = 1;
localparam int H = 4;
task automatic i_start;                                  // from idle or after a byte (repeated)
  if (!scl) begin m_low = 0; cycles(H); scl = 1; end
  cycles(H);
  m_low = 1; cycles(H);
  scl = 0; cycles(H);
endtask
task automatic i_stop;
  m_low = 1; cycles(H);
  scl = 1; cycles(H);
  m_low = 0; cycles(H);
endtask
task automatic i_bit(input bit b, output bit s);
  m_low = !b; cycles(H);
  scl = 1; cycles(H);
  s = sda === 1'b1;
  scl = 0;
endtask
task automatic i_wbyte(input logic [7:0] d, output bit ack);
  bit s;
  for (int i = 7; i >= 0; i--) i_bit(d[i], s);
  i_bit(1, s);
  ack = !s;
  m_low = 0;
endtask
// a byte read; nv: TX written (to v) before the ACK clock, while SCL is
// low, since the target takes the next byte's MSB at that clock's fall
task automatic i_rbyte(input bit ack, output logic [7:0] d, input bit nv = 0, input logic [7:0] v = 0);
  bit s;
  for (int i = 7; i >= 0; i--) begin i_bit(1, s); d[i] = s; end
  if (nv) wr(A_TX, v);
  i_bit(!ack, s);
  m_low = 0;
endtask
task automatic irq_expect(input int b);
  cycles(2);
  rd(A_IRQ_STATUS);
  if (!rdv[b]) fail($sformatf("IRQ bit %0d not set (%h)", b, rdv));
  if (!irq) fail("irq low with an enabled bit set");
  wr(A_IRQ_STATUS, 32'(1) << b);
endtask
// a write transaction: address, then bytes, each read back through RX
task automatic t_write(input logic [31:0] d, input int n);   // bytes d[31:24] first
  bit ack;
  i_start();
  i_wbyte({7'h50, 1'b0}, ack);
  if (!ack) fail("address not acknowledged");
  rd_exp(A_STATUS, 1);
  for (int k = 0; k < n; k++) begin
    i_wbyte(d[31 - 8 * k -: 8], ack);
    if (!ack) fail($sformatf("byte %h not acknowledged", d[31 - 8 * k -: 8]));
    rd_exp(A_FLAGS, 32'(1) << FLAG_RX_AVAIL);
    rd_exp(A_RX, d[31 - 8 * k -: 8]);
  end
  i_stop();
  cycles(2);
  rd_exp(A_STATUS, 0);
endtask
// a read transaction of n bytes, TX changed before each
task automatic t_read(input int n, input bit stop = 1);
  bit ack;
  logic [7:0] v, d;
  v = $urandom;
  wr(A_TX, v);
  i_start();
  i_wbyte({7'h50, 1'b1}, ack);
  if (!ack) fail("address not acknowledged (read)");
  for (int k = 0; k < n; k++) begin : b_byte
    logic [7:0] nv;
    nv = $urandom;
    i_rbyte(k != n - 1, d, k != n - 1, nv);
    if (d !== v) fail($sformatf("read byte %h, expected %h", d, v));
    v = nv;
  end
  cycles(2);
  rd_exp(A_STATUS, 0);                                   // the NACK ends it
  if (stop) i_stop();
endtask

task automatic ip_func;
  logic [31:0] b;
  logic [7:0] r;
  bit ack;
  rd_exp(A_FLAGS, 0);
  rd_exp(A_STATUS, 0);
  rd_exp(A_RX, 0);                                       // empty
  // RX read back to back while bytes arrive: a read in the clock a byte is
  // captured (data not checked here)
  begin : b_race
    bit done;
    done = 0;
    no_idle = 1;
    fork
      begin
        i_start(); i_wbyte(8'hA0, ack);
        for (int k = 0; k < 8; k++) begin i_wbyte(8'($urandom), ack); cycles(k % 2); end   // shift the phase
        i_stop(); done = 1;
      end
      while (!done) rd(A_RX);
    join
    no_idle = 0;
    rd(A_RX);
    // RX full, then read in the clock the next byte is captured: the read
    // started at every offset from that byte's last SCL rise
    for (int off = 0; off < 8; off++) begin
      i_start(); i_wbyte(8'hA0, ack); i_wbyte(8'h5A, ack);
      fork
        i_wbyte(8'hC3, ack);
        begin repeat (8) @(posedge scl); repeat (off) @(negedge PCLK); apb_now(0, A_RX, 0, 0); end
      join
      i_stop();
      rd(A_FLAGS);
      while (rdv[FLAG_RX_AVAIL]) begin rd(A_RX); rd(A_FLAGS); end
    end
    wr(A_IRQ_STATUS, IRQ_ALL);
  end
  wr(A_IRQ_ENABLE, IRQ_ALL);
  b = 32'hFF00_A55A;
  t_write(b, 4);
  irq_expect(IRQ_BYTE);
  irq_expect(IRQ_RX_AVAIL);
  for (int k = 0; k < 6; k++) begin
    b = $urandom;
    t_write(b, 1 + k % 4);
    t_read(1 + k % 3);
  end
  wr(A_TX, 8'hFF); i_start(); i_wbyte(8'hA1, ack); i_rbyte(0, r); i_stop();
  if (r !== 8'hFF) fail("read FF");
  wr(A_TX, 8'h00); i_start(); i_wbyte(8'hA1, ack); i_rbyte(0, r); i_stop();
  if (r !== 8'h00) fail("read 00");
  // a repeated START from a read into a write
  t_read(2, 0);
  b = 32'h3C00_0000;
  t_write(b, 1);
  // another address: no ACK, nothing received, not busy
  i_start();
  i_wbyte({7'h51, 1'b0}, ack);
  if (ack) fail("another address acknowledged");
  rd_exp(A_STATUS, 0);
  i_wbyte(8'h77, ack);
  if (ack) fail("a byte to another address acknowledged");
  i_stop();
  rd_exp(A_FLAGS, 0);
  wr(A_IRQ_STATUS, IRQ_ALL);
  // RX full: the second byte is dropped
  i_start(); i_wbyte(8'hA0, ack); i_wbyte(8'h11, ack); i_wbyte(8'h22, ack); i_stop();
  irq_expect(IRQ_RX_OVF);
  rd_exp(A_RX, 8'h11);
  // masked, left pending into reset
  wr(A_IRQ_ENABLE, 0);
  wr(A_IRQ_STATUS, IRQ_ALL);
  i_start(); i_wbyte(8'hA0, ack); i_wbyte(8'h33, ack); i_wbyte(8'h44, ack); i_stop();
  cycles(2);
  if (irq) fail("irq with every interrupt masked");
  rd_exp(A_IRQ_STATUS, IRQ_ALL);
endtask
