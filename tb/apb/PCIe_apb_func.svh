// SPDX-License-Identifier: Apache-2.0
// PCIe-specific part of tb/PCIe_apb_tb.sv. A second PCIe_top (the peer,
// driven directly with random TLPs) is cross-connected to the DUT's symbol
// pins; a symbol BFM can take the peer's place on the DUT's receive side to
// send any packet, good or not.
// Covered through the registers: TLPs written through TX checked at the
// peer, TLPs from the peer checked as the DUT hands them to RX (the bound
// checker checks every RX read against that), TX written while full and
// before the link is up, RX back-pressure, popped as it captures and read
// empty, CTRL and STATUS, each event interrupt (from BFM packets, a Nak, the
// replay timer and a retrain), every stream event and interrupt bit.
localparam int MAXLEN = 32, RXN = 4;
localparam logic [7:0] STP = 8'hFB, SDP = 8'h5C, ENDS = 8'hFD, EDB = 8'hFE;

// peer
logic        p_link = 0, p_tlp_valid = 0, p_tlp_last = 0, p_rx_ready = 0;
logic [7:0]  p_tlp_data = 0;
wire  [7:0]  p_tx_sym, p_rx_data;
wire         p_tx_k, p_tlp_ready, p_rx_valid, p_rx_last, p_dl_up, p_retrain;
wire         p_ev_tlp_bad, p_ev_tlp_seq, p_ev_tlp_dup, p_ev_tlp_null, p_ev_overflow, p_ev_dllp_bad;
wire         p_ev_dllp_proto, p_ev_frame, p_ev_nak, p_ev_replay;
// BFM in the peer's place
bit          bfm = 0;
logic [7:0]  b_sym = 0;
logic        b_k = 0;
assign rx_sym = bfm ? b_sym : p_tx_sym;
assign rx_k = bfm ? b_k : p_tx_k;
PCIe_top u_peer (
  .clk(PCLK), .rst_n(PRESETN), .link_up(p_link), .tx_sym(p_tx_sym), .tx_k(p_tx_k), .rx_sym(tx_sym), .rx_k(tx_k),
  .tlp_valid(p_tlp_valid), .tlp_ready(p_tlp_ready), .tlp_data(p_tlp_data), .tlp_last(p_tlp_last),
  .rx_valid(p_rx_valid), .rx_ready(p_rx_ready), .rx_data(p_rx_data), .rx_last(p_rx_last),
  .dl_up(p_dl_up), .retrain(p_retrain), .ev_tlp_bad(p_ev_tlp_bad), .ev_tlp_seq(p_ev_tlp_seq),
  .ev_tlp_dup(p_ev_tlp_dup), .ev_tlp_null(p_ev_tlp_null), .ev_overflow(p_ev_overflow),
  .ev_dllp_bad(p_ev_dllp_bad), .ev_dllp_proto(p_ev_dllp_proto), .ev_frame(p_ev_frame), .ev_nak(p_ev_nak),
  .ev_replay(p_ev_replay));

// what the DUT must hand to RX, {last, byte}: written at the peer or sent
// by the BFM
logic [8:0]  ps [0:8191];
int          psh = 0, pst = 0;
// what the peer must receive: the bytes the host wrote
logic [8:0]  hq [0:8191];
int          hqh = 0, hqt = 0;

// the peer writes TLPs of 1..MAXLEN bytes while p_en; a byte is taken on a
// posedge with valid and ready (sampled there)
bit          p_en = 0, p_tk = 0;
int          p_left = 0;
always @(posedge PCLK)
  if (PRESETN && p_tlp_valid && p_tlp_ready) begin
    ps[pst % 8192] = {p_tlp_last, p_tlp_data}; pst++;
    p_tk = 1;
  end
always @(negedge PCLK)
  if (!PRESETN) begin p_tlp_valid = 0; p_left = 0; p_tk = 0; end
  else begin
    if (p_tk) begin p_tlp_valid = 0; p_tk = 0; end
    if (!p_tlp_valid && (p_en || p_left != 0) && $urandom % 4 != 0) begin
      if (p_left == 0) p_left = 1 + $urandom % MAXLEN;
      p_left--;
      p_tlp_last = p_left == 0;
      p_tlp_data = $urandom;
      p_tlp_valid = 1;
    end
    p_rx_ready = $urandom % 4 != 0;
  end
// the peer's receive side: the host's bytes in order
always @(posedge PCLK)
  if (PRESETN && p_rx_valid && p_rx_ready) begin
    if (hqh == hqt) fail($sformatf("peer: byte %h, none written", p_rx_data));
    else begin
      if ({p_rx_last, p_rx_data} !== hq[hqh % 8192])
        fail($sformatf("peer: byte %b %h, expected %h", p_rx_last, p_rx_data, hq[hqh % 8192]));
      hqh++;
    end
  end
// the DUT's receive side: what the core hands to the RX register
always @(posedge PCLK)
  if (PRESETN && dut.u_core.rx_valid && dut.u_core.rx_ready) begin
    if (psh == pst) fail($sformatf("RX: byte %h, none sent", dut.u_core.rx_data));
    else begin
      if ({dut.u_core.rx_last, dut.u_core.rx_data} !== ps[psh % 8192])
        fail($sformatf("RX: byte %b %h, expected %h", dut.u_core.rx_last, dut.u_core.rx_data, ps[psh % 8192]));
      psh++;
    end
  end

// ---------------- BFM ----------------
logic [8:0]  bq [$];
always @(negedge PCLK) begin
  if (bq.size() != 0) {b_k, b_sym} = bq.pop_front();
  else {b_k, b_sym} = 9'h000;
end
task automatic bwait;
  while (bq.size() != 0) @(negedge PCLK);
  @(negedge PCLK);
endtask
function automatic logic [15:0] dcrc(input logic [31:0] d);
  logic [15:0] c;
  c = '1;
  for (int i = 31; i >= 0; i--) c = {c[14:0], 1'b0} ^ ((c[15] ^ d[i]) ? 16'h100B : 16'h0);
  return c;
endfunction
task automatic bdllp(input logic [7:0] b0, b1, b2, b3, input bit bad = 0);
  logic [15:0] c;
  c = ~dcrc({b0, b1, b2, b3}) ^ (bad ? 16'h0001 : 16'h0);
  bq.push_back({1'b1, SDP}); bq.push_back({1'b0, b0}); bq.push_back({1'b0, b1}); bq.push_back({1'b0, b2});
  bq.push_back({1'b0, b3}); bq.push_back({1'b0, c[15:8]}); bq.push_back({1'b0, c[7:0]}); bq.push_back({1'b1, ENDS});
  bq.push_back(9'h000);
endtask
task automatic back(input bit nak, input logic [11:0] seq);
  bdllp(nak ? 8'h10 : 8'h00, 8'h00, {4'd0, seq[11:8]}, seq[7:0]);
endtask
task automatic bfc(input logic [7:0] t, input logic [7:0] hdr);
  bdllp(t, {2'b00, hdr[7:2]}, {hdr[1:0], 6'd0}, 8'd0);
endtask
// a TLP of n random bytes; mode 0 good, 1 bad LCRC, 2 nullified, 3 a K
// symbol inside; accept: the DUT must deliver it
logic [7:0]  bt [$];
task btlp(input logic [11:0] seq, input int n, input int mode = 0, input bit accept = 0);
  logic [31:0] c;
  logic [7:0]  x;
  bt.delete();
  bt.push_back({4'd0, seq[11:8]}); bt.push_back(seq[7:0]);
  for (int i = 0; i < n; i++) bt.push_back(8'($urandom));
  c = '1;
  for (int j = 0; j < bt.size(); j++) begin
    x = bt[j];
    for (int i = 7; i >= 0; i--) c = {c[30:0], 1'b0} ^ ((c[31] ^ x[i]) ? 32'h04C1_1DB7 : 32'h0);
  end
  if (mode != 2) c = ~c;
  if (mode == 1) c ^= 32'h0100;
  bq.push_back({1'b1, STP});
  for (int j = 0; j < bt.size(); j++) begin
    bq.push_back({1'b0, bt[j]});
    if (mode == 3 && j == 3) bq.push_back({1'b1, SDP});
  end
  for (int i = 3; i >= 0; i--) bq.push_back({1'b0, c[8 * i +: 8]});
  bq.push_back({1'b1, mode == 2 ? EDB : ENDS});
  bq.push_back(9'h000);
  if (accept) for (int j = 2; j < bt.size(); j++) begin ps[pst % 8192] = {j == bt.size() - 1, bt[j]}; pst++; end
endtask

task automatic irq_expect(input int b);
  rd(A_IRQ_STATUS);
  if (!rdv[b]) fail($sformatf("IRQ bit %0d not set (%h)", b, rdv));
endtask
// the host writes a TLP of n bytes, back to back
task automatic h_tlp(input int n);
  logic [7:0] d;
  for (int i = 0; i < n; i++) begin
    d = $urandom;
    if (!bfm) begin hq[hqt % 8192] = {i == n - 1, d}; hqt++; end
    @(negedge PCLK);
    while (dut.full_TX) @(negedge PCLK);
    apb_now(1, A_TX, {23'd0, i == n - 1, d}, 4'hF);
  end
endtask
// the host reads RX until it stays empty for a while
task automatic h_drain;
  int k;
  k = 0;
  while (k < 200) begin
    if (dut.avail_RX) begin rd(A_RX); k = 0; end
    else begin @(negedge PCLK); k++; end
  end
endtask
// both ends drop the link; the queues start again
task automatic link_down;
  wr(A_CTRL, 0);
  p_link = 0;
  cycles(3);
  psh = pst; hqh = hqt;
  bq.delete();
endtask

task automatic ip_func;
  wr(A_IRQ_ENABLE, 0);
  // a TLP written before the link is up waits in TX; written again: TX_OVF
  hq[hqt % 8192] = {1'b1, 8'hA5}; hqt++;
  wr(A_TX, {23'd0, 1'b1, 8'hA5});
  wr(A_TX, 32'hFFFF_FFFF);
  irq_expect(IRQ_TX_OVF);
  rd(A_FLAGS);
  if (rdv[1:0] !== 2'b01) fail($sformatf("FLAGS %h with TX waiting", rdv));
  // link up with the peer
  wr(A_CTRL, 1);
  p_link = 1;
  poll(A_STATUS, 1, 1, 2000);
  cycles(200);
  if (hqh != hqt) fail("the waiting TLP did not reach the peer");
  // traffic both ways: the host writes TLPs, the peer writes back; RX is
  // read after each TLP (back-pressure in between)
  p_en = 1;
  for (int i = 0; i < 40; i++) begin
    h_tlp(1 + $urandom % MAXLEN);
    if (i % 4 == 3) begin
      while (dut.avail_RX) rd(A_RX);
    end
  end
  p_en = 0;
  while (p_left != 0 || p_tlp_valid) @(negedge PCLK);
  h_drain();
  rd(A_RX);                                     // empty: the last byte again
  cycles(500);
  if (hqh != hqt) fail($sformatf("peer missed %0d bytes", hqt - hqh));
  if (psh != pst) fail($sformatf("RX missed %0d bytes", pst - psh));
  irq_expect(IRQ_TX_DONE);
  irq_expect(IRQ_RX_AVAIL);

  // BFM in the peer's place: flow-control init with infinite credit
  link_down();
  rd(A_STATUS);
  if (rdv !== 0) fail($sformatf("STATUS %h with the link down", rdv));
  bfm = 1;
  wr(A_CTRL, 1);
  cycles(50);
  bfc(8'h40, 8'd0);
  bfc(8'hC0, 8'd0);
  bwait();
  poll(A_STATUS, 1, 1, 200);
  // TLPs to the DUT: good, duplicate, ahead, bad LCRC, nullified, K inside
  btlp(12'd0, 10, 0, 1);
  btlp(12'd0, 6);                               // duplicate
  btlp(12'd5, 6);                               // ahead: Nak
  btlp(12'd1, 6, 1);                            // bad LCRC
  btlp(12'd1, 6, 2);                            // nullified
  btlp(12'd1, 6, 3);                            // K inside
  btlp(12'd1, 12, 0, 1);
  bwait();
  // DLLPs: bad CRC, unknown type
  bdllp(8'h00, 8'h00, 8'h00, 8'h00, 1);
  bdllp(8'h30, 8'h00, 8'h00, 8'h00);
  bwait();
  cycles(20);
  h_drain();
  irq_expect(IRQ_TLP_DUP);
  irq_expect(IRQ_ERR_SEQ);
  irq_expect(IRQ_ERR_TLP);
  irq_expect(IRQ_TLP_NULL);
  irq_expect(IRQ_ERR_FRAME);
  irq_expect(IRQ_ERR_DLLP);
  irq_expect(IRQ_ERR_PROTO);
  // overflow: RX not read; RXN + 1 more TLPs (the last is dropped)
  for (int i = 0; i < RXN; i++) btlp(12'(2 + i), MAXLEN, 0, 1);
  btlp(12'(2 + RXN), MAXLEN);
  bwait();
  cycles(20);
  irq_expect(IRQ_ERR_OVERFLOW);
  h_drain();
  // a TLP to the BFM, a Nak (replayed), no Acks: the replay timer, then a
  // retrain after the fourth replay without progress
  h_tlp(20);
  cycles(100);
  back(1, 12'hFFF);
  bwait();
  cycles(100);
  irq_expect(IRQ_NAK);
  cycles(5 * 620);
  irq_expect(IRQ_REPLAY);
  irq_expect(IRQ_RETRAIN);
  back(0, 12'd0);
  bwait();
  link_down();
  bfm = 0;

  // interrupts: masked, raising irq, cleared one by one
  rd(A_IRQ_STATUS);
  if (rdv[13:0] != 14'h3FFF) fail($sformatf("IRQ_STATUS %h, expected every bit", rdv));
  if (irq) fail("irq high with every bit masked");
  wr(A_IRQ_ENABLE, IRQ_ALL);
  if (!irq) fail("irq low with every bit enabled");
  for (int b = 0; b < 14; b++) wr(A_IRQ_STATUS, 1 << b);
  rd(A_IRQ_STATUS);
  if (rdv[13:0] != 0) fail($sformatf("IRQ_STATUS %h after clearing", rdv));
  if (irq) fail("irq high with nothing pending");
  // up again with the peer: TX_DONE drives the pin
  wr(A_IRQ_ENABLE, 1 << IRQ_TX_DONE);
  wr(A_CTRL, 1);
  p_link = 1;
  poll(A_STATUS, 1, 1, 2000);
  h_tlp(3);
  poll(A_IRQ_STATUS, 1 << IRQ_TX_DONE, 1 << IRQ_TX_DONE, 500);
  if (!irq) fail("irq low with TX_DONE pending");
  cycles(300);
  if (hqh != hqt) fail($sformatf("peer missed %0d bytes", hqt - hqh));
  link_down();
endtask
