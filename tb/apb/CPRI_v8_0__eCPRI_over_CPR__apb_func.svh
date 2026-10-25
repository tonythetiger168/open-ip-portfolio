// SPDX-License-Identifier: Apache-2.0
// CPRI_v8_0__eCPRI_over_CPR_-specific part of
// tb/CPRI_v8_0__eCPRI_over_CPR__apb_tb.sv. The peer is a second
// CPRI_v8_0__eCPRI_over_CPR__top, configured through its own cpu port,
// whose tx_sym reaches the DUT through a TB link that can replace a symbol
// with an invalid one or cut the peer off (sending idle D0.0 instead).
// Checked: CFG0..CFG7 both ways, HUNT -> ALIGN -> SYNC, the L1 inband
// negotiation (peer version and rate, NEG the smaller of each), the peer's
// vendor byte, IQ words (four consecutive bytes of the peer's IQ pattern),
// IQ_COUNT, the drop counter saturating, IQ read while empty, loss of sync
// after the peer is cut off and the resync.
// Covered through the registers: LINK_EVENT from a code violation and from
// loss of sync, cleared at EVENTS, masked, raising irq and cleared.
logic        p_we = 0;
logic [3:0]  p_addr = 0;
logic [31:0] p_wdata = 0;
wire  [9:0]  p_tx;
wire  [31:0] p_rdata;
wire         p_irq;
CPRI_v8_0__eCPRI_over_CPR__top u_peer (
  .clk(PCLK), .rst_n(PRESETN), .rx_sym(tx_sym), .tx_sym(p_tx),
  .cpu_we(p_we), .cpu_re(1'b0), .cpu_addr(p_addr), .cpu_wdata(p_wdata), .cpu_rdata(p_rdata), .irq(p_irq));
// link: cv = invalid symbol this clock; cut = idle D0.0 at the DUT's disparity
bit cv = 0, cut = 0;
always @* rx_sym = cv ? 10'b1111110000 : cut ? (dut.u_core.rx_rd ? 10'b0110001011 : 10'b1001110100) : p_tx;
task automatic p_cfg(input logic [3:0] a, input logic [7:0] d);
  @(negedge PCLK) begin p_we = 1; p_addr = a; p_wdata = {24'h0, d}; end
  @(negedge PCLK) p_we = 0;
endtask

task automatic irq_expect(input int b);
  cycles(2);
  rd(A_IRQ_STATUS);
  if (!rdv[b]) fail($sformatf("IRQ bit %0d not set (%h)", b, rdv));
  if (!irq) fail("irq low with an enabled bit set");
endtask
// clear EVENTS bits e, then the interrupt; irq must stay low
task automatic events_clear(input logic [31:0] e);
  wr(A_EVENTS, e);
  rd_exp(A_EVENTS, 0);
  wr(A_IRQ_STATUS, IRQ_ALL);
  cycles(2);
  rd_exp(A_IRQ_STATUS, 0);
  if (irq) fail("irq after EVENTS and IRQ_STATUS were cleared");
endtask
task automatic wait_sync;
  int k;
  k = 0;
  rd(A_LINK);
  while (rdv[1:0] != 2 && k < 2000) begin cycles(4); rd(A_LINK); k++; end
  if (rdv[1:0] != 2) fail($sformatf("no SYNC (LINK %h)", rdv));
endtask
// the IQ byte after b in the peer's pattern {frame[3:0], word}: words 1..15
// of each basic frame (3..15 in frame 0, whose number is also 16, 32, 48)
function automatic bit iq_next(input logic [7:0] a, input logic [7:0] b);
  if (a[3:0] != 15) return b == a + 1;
  return b == {a[7:4] + 4'd1, 4'd1} || (a[7:4] == 15 && b == 8'h03);
endfunction
task automatic iq_pop;
  rd(A_IQ_COUNT);
  if (rdv == 0) fail("IQ buffer empty");
  else begin rd(A_IQ); iq_check(rdv); end
endtask
task automatic iq_check(input logic [31:0] w);
  for (int i = 3; i > 0; i--)
    if (!iq_next(w[8*i +: 8], w[8*(i-1) +: 8])) fail($sformatf("IQ word %h: bytes not consecutive", w));
endtask

task automatic ip_func;
  logic [31:0] l;
  wr(A_IRQ_ENABLE, IRQ_ALL);
  rd_exp(A_FLAGS, 0);
  // CFG0..CFG7: every stored bit both ways, then the reset values back
  for (int i = 0; i < 8; i++) begin
    wr(A_CFG0 + 12'(4 * i), 32'hFFFF_FFFF); rd_exp(A_CFG0 + 12'(4 * i), 32'hFF);
    wr(A_CFG0 + 12'(4 * i), 32'h0);         rd_exp(A_CFG0 + 12'(4 * i), 0);
  end
  apb(1, A_CFG3, 32'h12, 4'h1);
  if (!rerr) fail("no PSLVERR on a partial-strobe write");
  rd_exp(A_CFG3, 0);
  wr(A_CFG0, 32'h2A); wr(A_CFG1, 32'h04); wr(A_CFG2, 32'hC9);
  // IQ read while nothing is buffered: no pop
  rd(A_IQ);
  rd_exp(A_IQ_COUNT, 0);
  // the code violations of the start-up are cleared
  cycles(20);
  wr(A_EVENTS, 3);
  wr(A_IRQ_STATUS, IRQ_ALL);
  // peer: version 3, rate 5, vendor 0x5C; link up
  p_cfg(1, 8'h03); p_cfg(0, 8'h15); p_cfg(2, 8'h5C);
  rd(A_LINK);
  if (rdv[1:0] == 2) fail("SYNC before two hyperframes");
  wait_sync();
  rd_exp(A_EVENTS, 0);
  cycles(100);
  // IQ words: four consecutive pattern bytes each, until the buffer drops
  rd(A_IQ_COUNT);
  if (rdv == 0) fail("no IQ word buffered after SYNC");
  for (int i = 0; i < 40; i++) iq_pop();
  cycles(3000);
  rd(A_IQ_COUNT);
  if (rdv != 32) fail($sformatf("IQ_COUNT %0d, expected the buffer full", rdv));
  // L1 inband: 16 hyperframes after SYNC
  rd(A_LINK);
  while (!rdv[2]) begin cycles(200); rd(A_LINK); end
  if (rdv[15:12] != 3) fail($sformatf("peer version %0d in LINK", rdv[15:12]));
  if (rdv[23:16] != 8'hFF) fail($sformatf("drop counter %0d, expected saturated", rdv[23:16]));
  if (rdv[11:6] != 32) fail("LINK IQ count");
  rd_exp(A_NEG, 32'h53);
  rd_exp(A_VENDOR, 32'h5C);
  // read-only words: writes ignored
  wr(A_LINK, 32'hFFFF_FFFF); wr(A_NEG, 0); wr(A_IQ, 0); wr(A_IQ_COUNT, 0); wr(A_VENDOR, 0);
  rd_exp(A_NEG, 32'h53);
  rd_exp(A_VENDOR, 32'h5C);
  rd_exp(A_IQ_COUNT, 32);
  for (int i = 0; i < 40; i++) iq_pop();
  // our side lower: NEG follows
  wr(A_CFG0, 32'h22); wr(A_CFG1, 32'h01);
  rd_exp(A_NEG, 32'h21);
  wr(A_CFG0, 32'h2A); wr(A_CFG1, 32'h04);
  rd_exp(A_EVENTS, 0);
  // a code violation
  @(negedge PCLK) cv = 1;
  @(negedge PCLK) cv = 0;
  irq_expect(IRQ_LINK_EVENT);
  rd(A_EVENTS);
  if (rdv !== 32'h2) fail($sformatf("EVENTS %h after a code violation", rdv));
  wr(A_EVENTS, 1);                         // the other bit: no effect
  rd_exp(A_EVENTS, 2);
  events_clear(2);
  // the peer cut off: loss of sync after four hyperframes, then the resync
  @(negedge PCLK) cut = 1;
  cycles(3000);
  rd(A_LINK);
  if (rdv[1:0] != 2) fail("lost sync too early");
  cycles(2500);
  rd(A_LINK);
  if (rdv[1:0] != 0) fail($sformatf("no loss of sync (LINK %h)", rdv));
  irq_expect(IRQ_LINK_EVENT);
  rd(A_EVENTS);
  if (!rdv[0]) fail($sformatf("EVENTS %h after loss of sync", rdv));
  wr(A_EVENTS, 2);
  rd(A_EVENTS);
  if (!rdv[0]) fail("loss of sync cleared by a write of bit 1");
  @(negedge PCLK) cut = 0;
  wait_sync();
  events_clear(3);                         // the cut's disparity error too
  // drain the buffer
  rd(A_IQ_COUNT);
  for (int i = 0; i < 50; i++) rd(A_IQ);
  // masked: left pending into reset
  wr(A_IRQ_ENABLE, 0);
  @(negedge PCLK) cv = 1;
  @(negedge PCLK) cv = 0;
  cycles(3);
  if (irq) fail("irq with every interrupt masked");
  rd_exp(A_IRQ_STATUS, IRQ_ALL);
endtask
