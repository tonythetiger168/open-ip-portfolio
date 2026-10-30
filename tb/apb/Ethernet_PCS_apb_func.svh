// SPDX-License-Identifier: Apache-2.0
// Ethernet_PCS-specific part of tb/Ethernet_PCS_apb_tb.sv, entirely through
// the registers (AMP = 4096: the marker group leads the first pair): 32
// groups into TX_IN (one with an invalid sync header), the 17 beats of the
// pair read from TX_OUT, written back to RX_IN with one symbol error in
// each codeword, and the 32 groups read from RX_OUT and compared (the
// invalid one comes back with sync headers 11: ITB); then the same pair
// again (a marker group off its period: AM_ERR), a pair with 20 errors in
// each codeword (UNCORR_A / UNCORR_B), a first beat in the middle of a pair
// (RESYNC), writes while full (overflow) and the correction bypass.
localparam logic [11:0] A_TXO = A_TX_IN0 + 12'd36;      // TX_OUT0
localparam logic [11:0] A_RXI = A_TXO + 12'd84;         // RX_IN0
localparam logic [11:0] A_RXO = A_RXI + 12'd84;         // RX_OUT0
logic [263:0] pg [0:31];
logic [671:0] pb [0:16];                                 // {first, beat} as read
int           nbeat = 0;
logic [263:0] rgq [$];                                   // groups read while waiting to write RX_IN

// the transmitter holds its input while its output is not read: read beats while TX_IN is full
task automatic pcs_tx_read_beat;
  for (int w = 0; w < 21; w++) begin
    rd(A_TXO + 12'(4 * w));
    pb[nbeat][32 * w +: 32] = rdv;
  end
  nbeat++;
endtask
task automatic pcs_tx_group(input logic [263:0] g);
  rd(A_FLAGS);
  while (rdv[FLAG_TX_IN_FULL]) begin
    if (rdv[FLAG_TX_OUT_AVAIL]) pcs_tx_read_beat();
    rd(A_FLAGS);
  end
  for (int w = 0; w < 9; w++) wr(A_TX_IN0 + 12'(4 * w), w == 8 ? {24'd0, g[263:256]} : g[32 * w +: 32]);
endtask
task automatic pcs_rx_read_group;
  logic [263:0] g;
  for (int w = 0; w < 9; w++) begin
    rd(A_RXO + 12'(4 * w));
    if (w < 8) g[32 * w +: 32] = rdv; else g[263:256] = rdv[7:0];
  end
  rgq.push_back(g);
endtask
task automatic pcs_rx_beat(input logic [639:0] d, input logic f);
  rd(A_FLAGS);
  while (rdv[FLAG_RX_IN_FULL]) begin
    if (rdv[FLAG_RX_OUT_AVAIL]) pcs_rx_read_group();
    rd(A_FLAGS);
  end
  for (int w = 0; w < 20; w++) wr(A_RXI + 12'(4 * w), d[32 * w +: 32]);
  wr(A_RXI + 12'd80, {31'd0, f});
endtask
task automatic pcs_rx_group(output logic [263:0] g);
  if (rgq.size() == 0) begin
    poll(A_FLAGS, 32'h1 << FLAG_RX_OUT_AVAIL, 32'h1 << FLAG_RX_OUT_AVAIL, 2000);
    pcs_rx_read_group();
  end
  g = rgq.pop_front();
endtask
// beat b of the pair with n symbol errors in each codeword (symbols 2 and 3 of beats 0..n-1)
task automatic pcs_send_pair(input int n);
  logic [639:0] d;
  for (int b = 0; b < 17; b++) begin
    d = pb[b][639:0];
    if (b < n) begin d[29:20] = ~d[29:20]; d[39:30] = ~d[39:30]; end
    if (b < n - 17) begin d[49:40] = ~d[49:40]; d[59:50] = ~d[59:50]; end
    pcs_rx_beat(d, b == 0);
  end
endtask
task automatic pcs_irq(input int b, input logic exp);
  rd(A_IRQ_STATUS);
  if (rdv[b] !== exp) fail($sformatf("IRQ bit %0d: %0d", b, rdv[b]));
endtask

// the 32 groups of the first pair after reset into TX_IN, its 17 beats into pb
task automatic pcs_tx_pair;
  nbeat = 0;
  for (int i = 0; i < 32; i++) pcs_tx_group(pg[i]);
  while (nbeat < 17) begin
    poll(A_FLAGS, 32'h1 << FLAG_TX_OUT_AVAIL, 32'h1 << FLAG_TX_OUT_AVAIL, 200);
    pcs_tx_read_beat();
  end
  for (int b = 0; b < 17; b++) if (pb[b][640] != (b == 0)) fail($sformatf("TX_OUT beat %0d: first %0d", b, pb[b][640]));
endtask

// TX_IN written with TX_OUT not read: the transmitter stops taking groups and TX_IN
// overflows; two pairs into RX_IN with RX_OUT not read: the same for the receiver
task automatic pcs_overflows;
  for (int i = 0; i < 60; i++) wr(A_TX_IN8, 32'h0);
  pcs_irq(IRQ_TX_IN_OVF, 1);
  for (int b = 0; b < 34; b++) wr(A_RXI + 12'd80, {31'd0, b % 17 == 0});
  pcs_irq(IRQ_RX_IN_OVF, 1);
endtask

task automatic ip_func;
  logic [263:0] g;
  wr(A_CTRL, 32'h0);
  for (int i = 0; i < 32; i++) begin
    for (int j = 0; j < 4; j++) begin
      pg[i][66 * j +: 66] = {$urandom, $urandom, $urandom};
      pg[i][66 * j +: 2] = (i + j) % 3 == 0 ? 2'b01 : 2'b10;
      if (pg[i][66 * j +: 2] == 2'b01) pg[i][66 * j + 2 +: 8] = 8'h1E;
    end
  end
  pg[5][1:0] = 2'b00;                                    // invalid sync header
  pcs_tx_pair();
  rd(A_TXO + 12'd80);                                    // TX_OUT read while empty
  // back through the receiver, one symbol error in each codeword
  wr(A_IRQ_STATUS, IRQ_ALL);
  pcs_send_pair(1);
  for (int i = 0; i < 32; i++) begin
    pcs_rx_group(g);
    if (i == 5) begin
      for (int j = 0; j < 4; j++) if (g[66 * j +: 2] != 2'b11) fail("invalid group: sync header");
    end else if (g !== pg[i]) fail($sformatf("RX_OUT group %0d: %h, expected %h", i, g, pg[i]));
  end
  rd(A_STATUS);
  if (!rdv[0]) fail("STATUS: no lock");
  if (rdv[3:1] != 3'd0) fail("STATUS: status bits");
  rd(A_RXO + 12'd32);                                    // RX_OUT read while empty
  pcs_irq(IRQ_ITB, 1); pcs_irq(IRQ_CORR_A, 1); pcs_irq(IRQ_CORR_B, 1);
  pcs_irq(IRQ_UNCORR_A, 0); pcs_irq(IRQ_AM_ERR, 0);
  // the same pair again: a marker group off its period; its 40 blocks come out as data
  wr(A_IRQ_ENABLE, IRQ_ALL);                             // every interrupt drives the pin
  wr(A_IRQ_STATUS, IRQ_ALL);
  pcs_send_pair(0);
  for (int i = 0; i < 40; i++) pcs_rx_group(g);
  pcs_irq(IRQ_AM_ERR, 1);
  if (!irq) fail("irq pin");
  // 20 errors in each codeword: uncorrectable, every block with sync header 11
  wr(A_IRQ_STATUS, IRQ_ALL);
  pcs_send_pair(20);
  for (int i = 0; i < 40; i++) begin
    pcs_rx_group(g);
    for (int j = 0; j < 4; j++) if (g[66 * j +: 2] != 2'b11) fail("uncorrectable pair: sync header");
  end
  pcs_irq(IRQ_UNCORR_A, 1); pcs_irq(IRQ_UNCORR_B, 1);
  // a first beat in the middle of a pair, then a whole pair; RX_IN overflow
  wr(A_IRQ_STATUS, IRQ_ALL);
  for (int b = 0; b < 5; b++) pcs_rx_beat(pb[b][639:0], b == 0);
  pcs_send_pair(0);
  for (int i = 0; i < 40; i++) pcs_rx_group(g);
  pcs_irq(IRQ_RESYNC, 1);
  // 15 errors in each codeword: still corrected
  pcs_send_pair(15);
  for (int i = 0; i < 40; i++) pcs_rx_group(g);
  rd(A_STATUS);
  if (rdv[7:4] != 4'd15 || rdv[11:8] != 4'd15) fail($sformatf("STATUS nsym %h", rdv));
  // correction bypassed (interrupts masked): codewords with errors are uncorrectable
  wr(A_IRQ_ENABLE, 0);
  wr(A_CTRL, 32'h1D);                                    // bypass_corr, tx_am_sf = 7
  rd(A_CTRL);
  if (rdv[4:0] != 5'h1D) fail("CTRL readback");
  wr(A_IRQ_STATUS, IRQ_ALL);
  pcs_send_pair(1);
  for (int i = 0; i < 40; i++) pcs_rx_group(g);
  pcs_irq(IRQ_UNCORR_A, 1); pcs_irq(IRQ_UNCORR_B, 1); pcs_irq(IRQ_CORR_A, 0);
  if (irq) fail("irq pin while masked");
  // overflows, masked here and enabled after the reset below
  pcs_overflows();                                       // left pending through the reset
  // after a reset, the status bits set before the marker group leaves (TX_OUT not read
  // yet holds the transmitter): a pair with tx_am_sf = 7, back through the receiver
  cycles(2);
  PRESETN = 0;
  cycles(3);
  PRESETN = 1;
  cycles(2);
  wr(A_CTRL, 32'h1C);
  wr(A_IRQ_ENABLE, IRQ_ALL);
  rgq.delete();
  pcs_tx_pair();
  pcs_send_pair(0);
  for (int i = 0; i < 32; i++) begin
    pcs_rx_group(g);
    if (i != 5 && g !== pg[i]) fail($sformatf("RX_OUT group %0d after reset", i));
  end
  rd(A_STATUS);
  if (rdv[3:1] != 3'd7) fail("STATUS: status bits 7");
  // the marker group off its period and a realignment, interrupts masked
  wr(A_IRQ_ENABLE, 0);
  wr(A_IRQ_STATUS, IRQ_ALL);
  pcs_send_pair(0);
  for (int i = 0; i < 40; i++) pcs_rx_group(g);
  for (int b = 0; b < 5; b++) pcs_rx_beat(pb[b][639:0], b == 0);
  pcs_send_pair(0);
  for (int i = 0; i < 40; i++) pcs_rx_group(g);
  pcs_irq(IRQ_AM_ERR, 1); pcs_irq(IRQ_RESYNC, 1);
  if (irq) fail("irq pin while masked");
  wr(A_IRQ_STATUS, IRQ_ALL);
  wr(A_IRQ_ENABLE, IRQ_ALL);
  pcs_overflows();
  if (!irq) fail("irq pin on overflow");
  wr(A_IRQ_STATUS, IRQ_ALL);
  wr(A_IRQ_ENABLE, 0);
  wr(A_CTRL, 32'h0);
endtask
