// SPDX-License-Identifier: Apache-2.0
// UCIe-specific part of tb/UCIe_apb_tb.sv. A second UCIe_top (the peer,
// driven directly) is joined to the DUT's main band and sideband through a
// TB physical layer that can corrupt or stop flits and drops phy_up for a
// few clocks on a retrain request.
// Covered through the registers: link bring-up from CTRL and STATUS
// (state, cap), payloads of both stacks written through TX0..TX16 checked
// at the peer, the peer's payloads read through RX0..RX16, STATUS
// (flits outstanding, up to a full replay buffer), TX written while full,
// a payload lost with RX full, CRC and REPLAY from a corrupting link,
// RETRAIN from a cut link, PMNAK and L1 through pm_req, PROTO from an
// unknown sideband message, LINKERR without Retry, every interrupt bit
// masked, raising irq and cleared.
// peer
logic         p_en = 0, p_rty = 1, p_s1 = 1, p_l1ok = 1, p_pm = 0;
logic         p_tv = 0, p_ts = 0;
logic [511:0] p_td = 0;
wire          p_tr, p_rv, p_rs, p_lpr, p_ltv, p_sbtv, p_crc, p_rep, p_ert, p_pmn, p_pro, p_ler;
wire  [511:0] p_rd;
wire  [543:0] p_ltf;
wire  [15:0]  p_sbtm;
wire  [2:0]   p_st;
wire  [1:0]   p_cap;
wire  [3:0]   p_pend;
logic         p_lrv, p_sbv;
logic [543:0] p_lrf;
logic [15:0]  p_sbm;
UCIe_top u_peer (
  .clk(PCLK), .rst_n(PRESETN), .link_en(p_en), .cfg_retry(p_rty), .cfg_stack1(p_s1), .cfg_l1_ok(p_l1ok), .pm_req(p_pm),
  .tx_valid(p_tv), .tx_stack(p_ts), .tx_data(p_td), .tx_ready(p_tr), .rx_valid(p_rv), .rx_stack(p_rs), .rx_data(p_rd),
  .phy_up(phy_up), .lp_retrain(p_lpr), .lt_valid(p_ltv), .lt_flit(p_ltf), .lr_valid(p_lrv), .lr_flit(p_lrf),
  .sb_tx_valid(p_sbtv), .sb_tx_msg(p_sbtm), .sb_rx_valid(p_sbv), .sb_rx_msg(p_sbm),
  .state(p_st), .cap(p_cap), .tx_pend(p_pend), .ev_crc(p_crc), .ev_replay(p_rep), .ev_retrain(p_ert),
  .ev_pmnak(p_pmn), .ev_proto(p_pro), .ev_lerr(p_ler));
// physical layer: corrupt with p_cor percent; cut: no flit reaches the DUT;
// a retrain request drops phy_up for 6 clocks
int  p_cor = 0;
bit  cut = 0, phy_on = 0, rt = 0;
bit  sb_inj = 0;
logic [15:0] sb_jm = 0;
int  fl = -1;
always @(negedge PCLK) fl = $urandom % 100 < p_cor ? int'($urandom % 544) : -1;
logic [15:0] sb_rnd = 0;                       // the sideband between messages
always @(negedge PCLK) sb_rnd = $urandom;
always @(posedge PCLK) if (PRESETN && (lp_retrain || p_lpr)) rt <= 1;
initial forever begin
  @(negedge PCLK);
  if (rt) begin rt = 0; phy_on = 0; cycles(6); phy_on = 1; end
end
always @* begin
  phy_up = phy_on;
  lr_valid = p_ltv && !cut && phy_on;
  lr_flit = fl >= 0 ? p_ltf ^ (544'd1 << fl) : p_ltf;
  p_lrv = lt_valid && phy_on; p_lrf = lt_flit;
  sb_rx_valid = sb_inj || p_sbtv; sb_rx_msg = sb_inj ? sb_jm : p_sbtv ? p_sbtm : sb_rnd;
  p_sbv = sb_tx_valid; p_sbm = sb_tx_msg;
end

function automatic logic [511:0] r512();
  logic [511:0] r;
  for (int i = 0; i < 16; i++) r[i*32 +: 32] = $urandom;
  return r;
endfunction
// scoreboards ({stack, payload})
logic [512:0] to_peer [$], to_dut [$];
always @(posedge PCLK) if (PRESETN) begin
  if (p_tv && p_tr) begin to_dut.push_back({p_ts, p_td}); p_tv <= 0; end
  if (p_rv) begin
    if (to_peer.size() == 0) fail("peer got a payload never sent");
    else begin : b_chk
      logic [512:0] h;
      h = to_peer.pop_front();
      if (h !== {p_rs, p_rd}) fail($sformatf("peer got %h, expected %h", p_rd[31:0], h[31:0]));
    end
  end
end
task automatic peer_send(input logic s, input logic [511:0] d);
  @(negedge PCLK);
  while (p_tv) @(negedge PCLK);
  p_td = d; p_ts = s; p_tv = 1;
  @(negedge PCLK);
  while (p_tv) @(negedge PCLK);
endtask
// TX0..TX15 then TX16 (the stack) commits
task automatic tx_write(input logic s, input logic [511:0] d);
  for (int i = 0; i < 16; i++) wr(A_TX0 + 12'(4 * i), d[i*32 +: 32]);
  wr(A_TX16, {31'd0, s});
endtask
task automatic send(input logic s, input logic [511:0] d);
  poll(A_FLAGS, 32'(1) << FLAG_TX_FULL, 0, 400);
  to_peer.push_back({s, d});
  tx_write(s, d);
endtask
task automatic recv;
  logic [512:0] g, h;
  poll(A_FLAGS, 32'(1) << FLAG_RX_AVAIL, 32'(1) << FLAG_RX_AVAIL, 400);
  for (int i = 0; i < 16; i++) begin rd(A_RX0 + 12'(4 * i)); g[i*32 +: 32] = rdv; end
  rd(A_RX16); g[512] = rdv[0];
  if (to_dut.size() == 0) fail("RX with nothing sent");
  else begin
    h = to_dut.pop_front();
    if (g !== h) fail($sformatf("RX %h, expected %h", g[31:0], h[31:0]));
  end
endtask
task automatic settle;
  int t;
  t = 0;
  while ((to_peer.size() != 0 || dut.u_core.tx_pend != 0 || p_pend != 0 || to_dut.size() > 2) && t < 6000) begin cycles(1); t++; end
  if (t == 6000) fail("link did not settle");
endtask
task automatic irq_expect(input int b);
  cycles(3);
  rd(A_IRQ_STATUS);
  if (!rdv[b]) fail($sformatf("IRQ bit %0d not set (%h)", b, rdv));
  if (!irq) fail("irq low with an enabled bit set");
  wr(A_IRQ_STATUS, 32'(1) << b);
endtask
// link up: CTRL = {pm_req 0, l1_ok 1, stack1, retry, link_en}
task automatic up(input bit rty, input bit s1);
  p_en = 1; phy_on = 1;
  wr(A_CTRL, {28'd0, 1'b1, s1, rty, 1'b1});
  poll(A_STATUS, 32'h7, 32'd3, 2000);
  rd_exp(A_STATUS, {27'd0, s1 & p_s1, rty & p_rty, 3'd3});
endtask
task automatic down;
  wr(A_CTRL, 32'hE);
  p_en = 0;
  cycles(4);
  to_peer.delete(); to_dut.delete();
endtask
task automatic sb_send(input logic [15:0] m);
  @(negedge PCLK);
  sb_inj = 1; sb_jm = m;
  @(negedge PCLK);
  sb_inj = 0;
endtask

task automatic ip_func;
  wr(A_IRQ_ENABLE, IRQ_ALL);
  up(1, 1);
  // clean link both ways, both stacks
  for (int i = 0; i < 12; i++) send($urandom, r512());
  irq_expect(IRQ_TX_DONE);
  for (int i = 0; i < 12; i++) begin peer_send($urandom, r512()); recv(); end
  irq_expect(IRQ_RX_AVAIL);
  settle();
  rd(A_IRQ_STATUS);
  if (rdv[IRQ_CRC] || rdv[IRQ_REPLAY] || rdv[IRQ_PROTO]) fail("CRC, REPLAY or PROTO on a clean link");
  // the peer's flits stop: the replay buffer fills, TX held, a write
  // dropped; the replays end in a retrain request
  cut = 1;
  for (int i = 0; i < 8; i++) send(0, r512());
  poll(A_STATUS, 32'h1E0, 32'(8) << 5, 100);
  to_peer.push_back({1'b0, 512'hFEED_FACE_0123_4567});
  tx_write(0, 512'hFEED_FACE_0123_4567);                 // held: no room
  rd_exp(A_FLAGS, 32'(1) << FLAG_TX_FULL);
  wr(A_TX16, 32'h0);                                     // dropped
  irq_expect(IRQ_TX_OVF);
  irq_expect(IRQ_REPLAY);                                // the timeout
  poll(A_IRQ_STATUS, 32'(1) << IRQ_RETRAIN, 32'(1) << IRQ_RETRAIN, 2000);
  irq_expect(IRQ_RETRAIN);
  cut = 0;
  settle();
  // a payload lost with RX full
  peer_send(0, 512'h1111_2222_3333_4444);
  peer_send(1, 512'h5555_6666_7777_8888);
  cycles(5);
  irq_expect(IRQ_RX_OVF);
  recv();
  void'(to_dut.pop_front());
  // a corrupting link
  p_cor = 15;
  for (int i = 0; i < 30; i++) begin
    send($urandom, r512());
    if (i % 2) begin peer_send($urandom, r512()); recv(); end
  end
  settle();
  p_cor = 0;
  irq_expect(IRQ_CRC);
  irq_expect(IRQ_REPLAY);
  settle();
  // L1: refused by the peer, then entered, then left by a TX write
  p_l1ok = 0;
  wr(A_CTRL, 32'h1F);
  poll(A_IRQ_STATUS, 32'(1) << IRQ_PMNAK, 32'(1) << IRQ_PMNAK, 50);
  irq_expect(IRQ_PMNAK);
  p_l1ok = 1;
  wr(A_CTRL, 32'h0F); wr(A_CTRL, 32'h1F);
  poll(A_STATUS, 32'h7, 32'd4, 200);
  send(0, r512());
  poll(A_STATUS, 32'h7, 32'd3, 200);
  settle();
  wr(A_CTRL, 32'h0F);
  // an unknown sideband message
  sb_send(16'hEE00);
  irq_expect(IRQ_PROTO);
  // RX popped in the clock a payload is captured, at every offset, and RX
  // read empty (payloads here are not checked)
  for (int k = 0; k < 6; k++) begin
    peer_send(0, r512());
    cycles(8);
    @(negedge PCLK);
    p_td = r512(); p_ts = 0; p_tv = 1;
    repeat (k) @(negedge PCLK);
    apb_now(0, A_RX16, 0, 0);
    cycles(8);
    rd(A_FLAGS);
    while (rdv[FLAG_RX_AVAIL]) begin rd(A_RX16); rd(A_FLAGS); end
  end
  rd(A_RX16);
  to_dut.delete();
  // without Retry a bad CRC is a link error
  down();
  up(0, 1);
  for (int i = 0; i < 4; i++) send($urandom, r512());
  settle();
  p_cor = 100;
  peer_send(0, r512());
  cycles(4);
  p_cor = 0;
  irq_expect(IRQ_CRC);
  irq_expect(IRQ_LINKERR);
  rd_exp(A_STATUS, {27'd0, 2'b10, 3'd6});
  down();
  wr(A_IRQ_STATUS, IRQ_ALL);
  // masked: each event again, left pending into reset
  wr(A_IRQ_ENABLE, 0);
  up(1, 1);
  p_cor = 30;
  for (int i = 0; i < 10; i++) send(0, r512());
  settle();
  p_cor = 0;
  cut = 1;
  for (int i = 0; i < 8; i++) send(0, r512());
  poll(A_STATUS, 32'h1E0, 32'(8) << 5, 100);
  tx_write(0, r512());
  to_peer.push_back({1'b0, dut.u_core.tx_data});
  wr(A_TX16, 0);
  poll(A_IRQ_STATUS, 32'(1) << IRQ_RETRAIN, 32'(1) << IRQ_RETRAIN, 2000);
  cut = 0;
  settle();
  peer_send(0, r512());
  peer_send(0, r512());
  cycles(5);
  p_l1ok = 0; wr(A_CTRL, 32'h1F); cycles(10); wr(A_CTRL, 32'h0F); p_l1ok = 1;
  sb_send(16'hEE00);
  cycles(5);
  p_rty = 0; down(); up(1, 1);
  p_cor = 100; peer_send(0, r512()); cycles(4); p_cor = 0;
  cycles(5);
  if (irq) fail("irq with every interrupt masked");
  rd_exp(A_IRQ_STATUS, IRQ_ALL);
  down();
  p_rty = 1;
  phy_on = 0;
endtask
