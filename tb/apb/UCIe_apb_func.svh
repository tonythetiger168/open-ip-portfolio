// SPDX-License-Identifier: Apache-2.0
// UCIe-specific part of tb/UCIe_apb_tb.sv. A second UCIe_top (the peer,
// driven directly) is joined to the DUT's flit interfaces through a TB
// link that can corrupt or stop flits.
// Covered through the registers: payloads written through TX0 / TX1
// checked at the peer, the peer's payloads read through RX0 / RX1, STATUS
// (flits outstanding, up to a full replay buffer), TX written while full,
// a payload lost with RX full, CRC and REPLAY from a corrupting link, every
// interrupt bit masked, raising irq and cleared.
// peer
logic        p_tv = 0;
logic [63:0] p_td = 0;
wire         p_tr, p_rv, p_ltv, p_crc, p_rep;
wire  [63:0] p_rd;
wire  [89:0] p_ltf;
wire  [3:0]  p_pend;
logic        p_lrv;
logic [89:0] p_lrf;
UCIe_top u_peer (
  .clk(PCLK), .rst_n(PRESETN), .tx_valid(p_tv), .tx_data(p_td), .tx_ready(p_tr), .rx_valid(p_rv), .rx_data(p_rd),
  .lt_valid(p_ltv), .lt_flit(p_ltf), .lr_valid(p_lrv), .lr_flit(p_lrf), .tx_pend(p_pend), .ev_crc(p_crc), .ev_replay(p_rep));
// link: corrupt with p_cor percent; cut: nothing reaches the DUT
int p_cor = 0;
bit cut = 0;
// corruption: one bit of the flit to the DUT, chosen on the falling edge
int fl = -1;
always @(negedge PCLK) fl = $urandom % 100 < p_cor ? int'($urandom % 90) : -1;
always @* begin
  lr_valid = p_ltv && !cut;
  lr_flit = fl >= 0 ? p_ltf ^ (90'd1 << fl) : p_ltf;
  p_lrv = lt_valid; p_lrf = lt_flit;
end

// scoreboards
logic [63:0] to_peer [$], to_dut [$];
always @(posedge PCLK) if (PRESETN) begin
  if (p_tv && p_tr) begin to_dut.push_back(p_td); p_tv <= 0; end
  if (p_rv) begin
    if (to_peer.size() == 0) fail("peer got a payload never sent");
    else if (to_peer[0] !== p_rd) fail($sformatf("peer got %h, expected %h", p_rd, to_peer[0]));
    else void'(to_peer.pop_front());
  end
end
task automatic peer_send(input logic [63:0] d);
  @(negedge PCLK);
  while (p_tv) @(negedge PCLK);
  p_td = d; p_tv = 1;
  @(negedge PCLK);
  while (p_tv) @(negedge PCLK);
endtask
task automatic send(input logic [63:0] d);
  poll(A_FLAGS, 32'(1) << FLAG_TX_FULL, 0, 200);
  to_peer.push_back(d);
  wr(A_TX0, d[31:0]); wr(A_TX1, d[63:32]);
endtask
// no wait for room
task automatic send_raw(input logic [63:0] d);
  to_peer.push_back(d);
  wr(A_TX0, d[31:0]); wr(A_TX1, d[63:32]);
endtask
task automatic recv;
  logic [31:0] lo;
  poll(A_FLAGS, 32'(1) << FLAG_RX_AVAIL, 32'(1) << FLAG_RX_AVAIL, 200);
  rd(A_RX0); lo = rdv;
  rd(A_RX1);
  if (to_dut.size() == 0) fail("RX with nothing sent");
  else begin
    if ({rdv, lo} !== to_dut[0]) fail($sformatf("RX %h, expected %h", {rdv, lo}, to_dut[0]));
    void'(to_dut.pop_front());
  end
endtask
task automatic settle;
  int t;
  t = 0;
  while ((to_peer.size() != 0 || dut.u_core.tx_pend != 0 || p_pend != 0 || to_dut.size() > 2) && t < 3000) begin cycles(1); t++; end
  if (t == 3000) fail("link did not settle");
endtask
task automatic irq_expect(input int b);
  cycles(3);
  rd(A_IRQ_STATUS);
  if (!rdv[b]) fail($sformatf("IRQ bit %0d not set (%h)", b, rdv));
  if (!irq) fail("irq low with an enabled bit set");
  wr(A_IRQ_STATUS, 32'(1) << b);
endtask

task automatic ip_func;
  wr(A_IRQ_ENABLE, IRQ_ALL);
  // clean link both ways
  for (int i = 0; i < 24; i++) send({$urandom, $urandom});
  irq_expect(IRQ_TX_DONE);
  for (int i = 0; i < 24; i++) begin peer_send({$urandom, $urandom}); recv(); end
  irq_expect(IRQ_RX_AVAIL);
  settle();
  rd(A_IRQ_STATUS);
  if (rdv[IRQ_CRC] || rdv[IRQ_REPLAY]) fail("CRC or REPLAY on a clean link");
  // the peer's flits stop: the replay buffer fills, TX held, a write dropped
  cut = 1;
  for (int i = 0; i < 8; i++) send({$urandom, $urandom});
  poll(A_STATUS, 32'hF, 8, 50);
  to_peer.push_back(64'hFEED_FACE_0123_4567);
  wr(A_TX0, 32'h0123_4567); wr(A_TX1, 32'hFEED_FACE);  // held: no room
  rd_exp(A_FLAGS, 32'(1) << FLAG_TX_FULL);
  wr(A_TX1, 32'h0);                                      // dropped
  irq_expect(IRQ_TX_OVF);
  irq_expect(IRQ_REPLAY);                                // the timeout
  cut = 0;
  settle();
  // a payload lost with RX full
  peer_send(64'h1111_2222_3333_4444);
  peer_send(64'h5555_6666_7777_8888);
  cycles(5);
  irq_expect(IRQ_RX_OVF);
  recv();
  void'(to_dut.pop_front());
  // a corrupting link
  p_cor = 15;
  for (int i = 0; i < 40; i++) begin
    send({$urandom, $urandom});
    if (i % 2) begin peer_send({$urandom, $urandom}); recv(); end
  end
  settle();
  p_cor = 0;
  irq_expect(IRQ_CRC);
  irq_expect(IRQ_REPLAY);
  settle();
  // RX popped in the clock a payload is captured, at every offset, and RX
  // read empty (payloads here are not checked)
  for (int k = 0; k < 6; k++) begin
    peer_send({$urandom, $urandom});
    cycles(8);
    @(negedge PCLK);
    p_td = {$urandom, $urandom}; p_tv = 1;
    repeat (k) @(negedge PCLK);
    apb_now(0, A_RX1, 0, 0);
    cycles(8);
    rd(A_FLAGS);
    while (rdv[FLAG_RX_AVAIL]) begin rd(A_RX1); rd(A_FLAGS); end
  end
  rd(A_RX1);
  to_dut.delete();
  wr(A_IRQ_STATUS, IRQ_ALL);
  // masked: each event again, left pending into reset
  wr(A_IRQ_STATUS, IRQ_ALL);
  wr(A_IRQ_ENABLE, 0);
  p_cor = 30;
  for (int i = 0; i < 10; i++) send({$urandom, $urandom});
  settle();
  p_cor = 0;
  cut = 1;
  for (int i = 0; i < 8; i++) send({$urandom, $urandom});
  poll(A_STATUS, 32'hF, 8, 50);
  send_raw({$urandom, $urandom});
  wr(A_TX1, 0);
  cut = 0;
  settle();
  peer_send({$urandom, $urandom});
  peer_send({$urandom, $urandom});
  cycles(5);
  if (irq) fail("irq with every interrupt masked");
  rd_exp(A_IRQ_STATUS, IRQ_ALL);
  if (to_peer.size() != 0) fail("payloads not delivered to the peer");
endtask
