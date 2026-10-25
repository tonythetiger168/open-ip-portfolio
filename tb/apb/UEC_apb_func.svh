// SPDX-License-Identifier: Apache-2.0
// UEC-specific part of tb/UEC_apb_tb.sv. A second UEC_top (the peer, driven
// directly) is joined to the DUT's network pins; each direction can drop
// whole frames, and a frame BFM can take the peer's place on the DUT's
// receive side.
// Covered through the registers: packets written through TX checked at the
// peer, packets from the peer checked (in any order) as the DUT hands them
// to RX, CTRL and PSN (PDCs opened with new start PSNs), STATUS, TX written
// while full, RX popped as it captures and read empty, each event
// interrupt (lost ACKs: RTO and DUP, the peer's buffers full: NACK, RX not
// read: NOBUF, BFM frames: ERR_PROTO), every stream event and interrupt bit.
localparam int MAXP = 16, W = 4;

// peer
logic        p_en = 0, p_tx_valid = 0, p_tx_last = 0, p_rx_ready = 0;
logic [7:0]  p_tx_data = 0;
logic [15:0] p_spt = 0, p_spr = 0;
wire  [7:0]  p_rx_data, p_ntd;
wire         p_tx_ready, p_rx_valid, p_rx_last, p_ntv, p_ntl;
wire  [2:0]  p_out;
wire         p_ev_rto, p_ev_nack, p_ev_dup, p_ev_nobuf, p_ev_proto;
// the network: DUT -> peer and peer -> DUT, a frame dropped whole while
// cut_d2p / cut_p2d is set at its first byte
bit          cut_d2p = 0, cut_p2d = 0, in_d2p = 0, in_p2d = 0, cut_d2p_f = 0, cut_p2d_f = 0;
logic        drop_d2p, drop_p2d;
bit          bfm = 0;
logic [8:0]  bq [$];
logic        b_v = 0, b_l = 0;
logic [7:0]  b_d = 0;
UEC_top u_peer (
  .clk(PCLK), .rst_n(PRESETN), .enable(p_en), .start_psn_tx(p_spt), .start_psn_rx(p_spr),
  .tx_valid(p_tx_valid), .tx_ready(p_tx_ready), .tx_data(p_tx_data), .tx_last(p_tx_last),
  .rx_valid(p_rx_valid), .rx_ready(p_rx_ready), .rx_data(p_rx_data), .rx_last(p_rx_last),
  .net_tx_valid(p_ntv), .net_tx_ready(1'b1), .net_tx_data(p_ntd), .net_tx_last(p_ntl),
  .net_rx_valid(net_tx_valid && net_tx_ready && !drop_d2p), .net_rx_data(net_tx_data), .net_rx_last(net_tx_last),
  .outstanding(p_out), .ev_rto(p_ev_rto), .ev_nack(p_ev_nack), .ev_dup(p_ev_dup), .ev_nobuf(p_ev_nobuf),
  .ev_proto(p_ev_proto));
// a frame is dropped from its first byte when cut_* was set
assign drop_d2p = in_d2p ? cut_d2p_f : cut_d2p;
assign drop_p2d = in_p2d ? cut_p2d_f : cut_p2d;
always @(posedge PCLK) begin
  if (net_tx_valid && net_tx_ready) begin
    if (!in_d2p) cut_d2p_f = cut_d2p;
    in_d2p = !net_tx_last;
  end
  if (p_ntv) begin
    if (!in_p2d) cut_p2d_f = cut_p2d;
    in_p2d = !p_ntl;
  end
  if (!PRESETN) begin in_d2p = 0; in_p2d = 0; end
end
assign net_rx_valid = bfm ? b_v : p_ntv && !drop_p2d;
assign net_rx_data = bfm ? b_d : p_ntd;
assign net_rx_last = bfm ? b_l : p_ntl;
always @(negedge PCLK) begin
  net_tx_ready = $urandom % 4 != 0;
  b_v = 0; b_l = 0;
  if (bq.size() != 0) begin : b_send
    logic [8:0] x;
    x = bq.pop_front();
    b_v = 1; b_d = x[7:0]; b_l = x[8];
  end
end

// packets each side must receive: {len, bytes}; xd: the DUT, xp: the peer
logic [MAXP*8+4:0] xd [$], xp [$];
function automatic logic [MAXP*8+4:0] pkt(input int l, input logic [MAXP*8-1:0] d);
  return {5'(l), d};
endfunction
task automatic x_take(input bit dut_side, input logic [MAXP*8+4:0] x);
  int k;
  k = -1;
  if (dut_side) begin
    for (int i = 0; i < xd.size() && k < 0; i++) if (xd[i] === x) k = i;
    if (k < 0) fail($sformatf("RX: packet %h never sent by the peer", x));
    else xd.delete(k);
  end else begin
    for (int i = 0; i < xp.size() && k < 0; i++) if (xp[i] === x) k = i;
    if (k < 0) fail($sformatf("peer: packet %h never written to TX", x));
    else xp.delete(k);
  end
endtask
// collectors: the DUT core's receive side, the peer's
logic [MAXP*8-1:0] cd = 0, cp = 0;
int                nd = 0, np = 0;
always @(posedge PCLK)
  if (!PRESETN) begin nd = 0; np = 0; cd = 0; cp = 0; end
  else begin
    if (dut.u_core.rx_valid && dut.u_core.rx_ready) begin
      cd[8 * nd +: 8] = dut.u_core.rx_data; nd++;
      if (dut.u_core.rx_last) begin x_take(1, pkt(nd, cd)); nd = 0; cd = 0; end
    end
    if (p_rx_valid && p_rx_ready) begin
      cp[8 * np +: 8] = p_rx_data; np++;
      if (p_rx_last) begin x_take(0, pkt(np, cp)); np = 0; cp = 0; end
    end
  end
// the peer writes packets of 1..MAXP bytes while p_wr; reads with
// p_rd_pct back-pressure
bit          p_wr = 0, p_tk = 0;
int          p_n = 0, p_i = 0, p_rd_pct = 75;
logic [MAXP*8-1:0] p_pk = 0;
always @(posedge PCLK)
  if (PRESETN && p_tx_valid && p_tx_ready) p_tk = 1;
always @(negedge PCLK)
  if (!PRESETN) begin p_tx_valid = 0; p_n = 0; p_i = 0; p_tk = 0; end
  else begin
    if (p_tk) begin p_tx_valid = 0; p_tk = 0; p_i++; if (p_i == p_n) begin p_n = 0; p_i = 0; end end
    if (!p_tx_valid && (p_wr || p_n != 0) && $urandom % 4 != 0) begin
      if (p_n == 0) begin
        p_n = 1 + $urandom % MAXP; p_i = 0; p_pk = 0;
        for (int i = 0; i < p_n; i++) p_pk[8 * i +: 8] = $urandom;
        xd.push_back(pkt(p_n, p_pk));
      end
      p_tx_last = p_i == p_n - 1;
      p_tx_data = p_pk[8 * p_i +: 8];
      p_tx_valid = 1;
    end
    p_rx_ready = $urandom % 100 < p_rd_pct;
  end

task automatic irq_expect(input int b);
  rd(A_IRQ_STATUS);
  if (!rdv[b]) fail($sformatf("IRQ bit %0d not set (%h)", b, rdv));
endtask
// the host writes a packet of n bytes through TX; RX is read while TX
// waits (h_rd)
bit h_rd = 0;
task automatic h_pkt(input int n);
  logic [MAXP*8-1:0] d;
  d = 0;
  for (int i = 0; i < n; i++) d[8 * i +: 8] = $urandom;
  xp.push_back(pkt(n, d));
  for (int i = 0; i < n; i++) begin
    @(negedge PCLK);
    while (dut.full_TX)
      if (h_rd && dut.avail_RX) rd(A_RX);
      else @(negedge PCLK);
    apb_now(1, A_TX, {23'd0, i == n - 1, d[8 * i +: 8]}, 4'hF);
  end
endtask
// the host reads RX until it stays empty for a while
task automatic h_drain;
  int k;
  k = 0;
  while (k < 300) begin
    if (dut.avail_RX) begin rd(A_RX); k = 0; end
    else begin @(negedge PCLK); k++; end
  end
endtask
// open both ends: a = DUT's first PSN, b = the peer's
task automatic open_pdc(input logic [15:0] a, input logic [15:0] b);
  wr(A_PSN, {b, a});
  p_spt = b; p_spr = a;
  cycles(2);
  wr(A_CTRL, 1);
  p_en = 1;
endtask
task automatic close_pdc;
  wr(A_CTRL, 0);
  p_en = 0;
  cycles(3);
  xd.delete(); xp.delete();
  bq.delete();
endtask
// both sides quiet: every packet delivered, nothing outstanding
task automatic settle(input string s);
  int k;
  k = 0;
  while ((xd.size() + xp.size() != 0 || p_out != 0 || dut.u_core.outstanding != 0 || p_n != 0) && k < 20000) begin
    if (dut.avail_RX) rd(A_RX); else @(negedge PCLK);
    k++;
  end
  if (k == 20000) fail($sformatf("%s: %0d / %0d packets missing", s, xd.size(), xp.size()));
  h_drain();
endtask

task automatic ip_func;
  wr(A_IRQ_ENABLE, 0);
  // a byte written before the PDC is open waits in TX; written again: TX_OVF
  xp.push_back(pkt(1, 128'hA5));
  wr(A_TX, {23'd0, 1'b1, 8'hA5});
  wr(A_TX, 32'h1FF);
  irq_expect(IRQ_TX_OVF);
  rd(A_FLAGS);
  if (rdv[1:0] !== 2'b01) fail($sformatf("FLAGS %h with TX waiting", rdv));
  open_pdc(16'hFFFC, 16'h8000);
  // traffic both ways; RX read while TX waits and in between
  p_wr = 1;
  h_rd = 1;
  for (int i = 0; i < 30; i++) begin
    h_pkt(1 + $urandom % MAXP);
    if (i % 3 == 2) for (int k = 0; k < 40 && dut.avail_RX; k++) rd(A_RX);
  end
  p_wr = 0;
  h_rd = 0;
  settle("traffic");
  rd(A_RX);                                     // empty: the last byte again
  rd(A_STATUS);
  if (rdv !== 0) fail($sformatf("STATUS %h when idle", rdv));
  irq_expect(IRQ_TX_DONE);
  irq_expect(IRQ_RX_AVAIL);
  // lost ACKs both ways: the DUT times out, the peer's retransmissions are
  // duplicates at the DUT
  cut_p2d = 1;
  h_pkt(4);
  cycles(30);
  rd(A_STATUS);
  if (rdv !== 1) fail($sformatf("STATUS %h with one packet unacknowledged", rdv));
  poll(A_IRQ_STATUS, 1 << IRQ_RTO, 1 << IRQ_RTO, 400);
  cut_p2d = 0;
  settle("RTO");
  cut_d2p = 1;
  p_wr = 1;
  cycles(60);
  p_wr = 0;
  h_drain();                                    // the peer's timer runs out meanwhile
  cut_d2p = 0;
  poll(A_IRQ_STATUS, 1 << IRQ_DUP, 1 << IRQ_DUP, 600);
  settle("DUP");
  // the peer stops reading: its buffers fill, it NACKs the DUT's packets
  p_rd_pct = 0;
  for (int i = 0; i < 4; i++) h_pkt(3);
  poll(A_IRQ_STATUS, 1 << IRQ_NACK, 1 << IRQ_NACK, 400);
  p_rd_pct = 75;
  settle("NACK");
  // RX not read: the DUT's buffers fill, it NACKs the peer's packets
  p_wr = 1;
  cycles(400);
  p_wr = 0;
  irq_expect(IRQ_NOBUF);
  settle("NOBUF");
  // frames from the BFM: a bad type, a bad length, an ACK for nothing sent
  bfm = 1;
  bq.push_back({1'b0, 8'h55}); bq.push_back({1'b1, 8'h00});
  bq.push_back({1'b0, 8'h10}); bq.push_back({1'b0, 8'h00}); bq.push_back({1'b1, 8'h00});
  cycles(10);
  bfm = 0;
  irq_expect(IRQ_ERR_PROTO);
  // closed and opened again with other PSNs
  close_pdc();
  open_pdc(16'h0123, 16'hFEDC);
  p_wr = 1;
  for (int i = 0; i < 8; i++) h_pkt(1 + $urandom % MAXP);
  p_wr = 0;
  settle("reopened");
  close_pdc();

  // interrupts: masked, raising irq, cleared one by one
  rd(A_IRQ_STATUS);
  if (rdv[7:0] != 8'hFF) fail($sformatf("IRQ_STATUS %h, expected every bit", rdv));
  if (irq) fail("irq high with every bit masked");
  wr(A_IRQ_ENABLE, IRQ_ALL);
  if (!irq) fail("irq low with every bit enabled");
  for (int b = 0; b < 8; b++) wr(A_IRQ_STATUS, 1 << b);
  rd(A_IRQ_STATUS);
  if (rdv[7:0] != 0) fail($sformatf("IRQ_STATUS %h after clearing", rdv));
  if (irq) fail("irq high with nothing pending");
  // TX_DONE drives the pin
  wr(A_IRQ_ENABLE, 1 << IRQ_TX_DONE);
  open_pdc(16'h7777, 16'h3333);
  h_pkt(2);
  poll(A_IRQ_STATUS, 1 << IRQ_TX_DONE, 1 << IRQ_TX_DONE, 200);
  if (!irq) fail("irq low with TX_DONE pending");
  settle("last");
  close_pdc();
  wr(A_PSN, 0);
endtask
