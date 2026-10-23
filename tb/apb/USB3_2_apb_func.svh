// SPDX-License-Identifier: Apache-2.0
// USB3_2-specific part of tb/USB3_2_apb_tb.sv. A second USB3_2_top (the
// peer, driven directly with random packets) is cross-connected to the DUT's
// symbol pins; a symbol BFM can take the peer's place on the DUT's receive
// side to send any packet or link command, good or not.
// Covered through the registers: packets written through TX checked at the
// peer, packets from the peer checked as the DUT hands them to RX (the bound
// checker checks every RX read against that), TX written while full and
// before the link is up, RX back-pressure, popped as it captures and read
// empty, CTRL and STATUS, each event interrupt (from BFM packets and link
// commands, an LBAD, the pending timer and recovery), every stream event and
// interrupt bit.
localparam int MAXD = 32, RXN = 4, TXN = 4, PL = 12 + MAXD;
localparam logic [7:0] SHP = 8'hFB, SDP = 8'h5C, ENDS = 8'hFD, EDB = 8'h7C, SLC = 8'hDC, EPF = 8'hF7;

// peer
logic        p_link = 0, p_tx_valid = 0, p_tx_last = 0, p_rx_ready = 0;
logic [7:0]  p_tx_data = 0;
wire  [7:0]  p_tx_sym, p_rx_data;
wire         p_tx_k, p_tx_ready, p_rx_valid, p_rx_last, p_rx_err, p_ll_up, p_recovery;
wire         p_ev_hp_bad, p_ev_seq, p_ev_lc_bad, p_ev_dpp_bad, p_ev_frame, p_ev_proto, p_ev_overflow;
wire         p_ev_lbad, p_ev_timeout;
// BFM in the peer's place
bit          bfm = 0;
logic [7:0]  b_sym = 0;
logic        b_k = 0;
assign rx_sym = bfm ? b_sym : p_tx_sym;
assign rx_k = bfm ? b_k : p_tx_k;
USB3_2_top u_peer (
  .clk(PCLK), .rst_n(PRESETN), .link_up(p_link), .recovery(p_recovery), .tx_sym(p_tx_sym), .tx_k(p_tx_k),
  .rx_sym(tx_sym), .rx_k(tx_k), .tx_valid(p_tx_valid), .tx_ready(p_tx_ready), .tx_data(p_tx_data),
  .tx_last(p_tx_last), .rx_valid(p_rx_valid), .rx_ready(p_rx_ready), .rx_data(p_rx_data), .rx_last(p_rx_last),
  .rx_err(p_rx_err), .ll_up(p_ll_up), .ev_hp_bad(p_ev_hp_bad), .ev_seq(p_ev_seq), .ev_lc_bad(p_ev_lc_bad),
  .ev_dpp_bad(p_ev_dpp_bad), .ev_frame(p_ev_frame), .ev_proto(p_ev_proto), .ev_overflow(p_ev_overflow),
  .ev_lbad(p_ev_lbad), .ev_timeout(p_ev_timeout));

// what the DUT must hand to RX, {err, last, byte}: written at the peer or
// sent by the BFM
logic [9:0]  ps [0:8191];
int          psh = 0, pst = 0;
// what the peer must receive: the bytes the host wrote, as delivered
logic [9:0]  hq [0:8191];
int          hqh = 0, hqt = 0;

// packet bytes: the host's at pk[0..63], the peer's at pk[64..127]
logic [7:0]  pk [0:127];
// a packet of n bytes at pk[o], as the far end delivers it: the header
// padded to 12 bytes, a data packet's payload after it
task expect_pk(input int o, input int n);
  int m;
  logic [7:0] x;
  m = pk[o][4:0] == 5'b01000 && n > 12 ? n : 12;
  for (int i = 0; i < m; i++) begin
    x = i < n ? pk[o + i] : 8'h00;
    if (o == 0) begin hq[hqt % 8192] = {1'b0, i == m - 1, x}; hqt++; end
    else begin ps[pst % 8192] = {1'b0, i == m - 1, x}; pst++; end
  end
endtask
// random packet bytes at pk[o]: a data packet (12..44 bytes) or another
// header (1..16)
task new_pk(input int o, output int n);
  bit dp;
  logic [7:0] x;
  dp = $urandom % 3 != 0;
  n = dp ? 12 + $urandom % (MAXD + 1) : 1 + $urandom % 16;
  for (int i = 0; i < n; i++) pk[o + i] = 8'($urandom);
  x = pk[o];
  if (dp) x[4:0] = 5'b01000;
  else if (x[4:0] == 5'b01000) x[4:0] = 5'b00100;
  pk[o] = x;
endtask

// the peer writes packets while p_en; a byte is taken on a posedge with
// valid and ready (sampled there)
bit          p_en = 0, p_tk = 0;
int          p_n = 0, p_i = 0;
always @(posedge PCLK)
  if (PRESETN && p_tx_valid && p_tx_ready) p_tk = 1;
always @(negedge PCLK)
  if (!PRESETN) begin p_tx_valid = 0; p_n = 0; p_i = 0; p_tk = 0; end
  else begin
    if (p_tk) begin p_tx_valid = 0; p_tk = 0; p_i++; if (p_i == p_n) begin p_n = 0; p_i = 0; end end
    if (!p_tx_valid && (p_en || p_n != 0) && $urandom % 4 != 0) begin
      if (p_n == 0) begin new_pk(64, p_n); p_i = 0; expect_pk(64, p_n); end
      p_tx_last = p_i == p_n - 1;
      p_tx_data = pk[64 + p_i];
      p_tx_valid = 1;
    end
    p_rx_ready = $urandom % 4 != 0;
  end
// the peer's receive side: the host's packets in order
always @(posedge PCLK)
  if (PRESETN && p_rx_valid && p_rx_ready) begin
    if (hqh == hqt) fail($sformatf("peer: byte %h, none written", p_rx_data));
    else begin
      if ({p_rx_err, p_rx_last, p_rx_data} !== hq[hqh % 8192])
        fail($sformatf("peer: byte %b %b %h, expected %h", p_rx_err, p_rx_last, p_rx_data, hq[hqh % 8192]));
      hqh++;
    end
  end
// with the peer the link never needs recovery
always @(posedge PCLK)
  if (PRESETN && !bfm && (dut.u_core.recovery || p_recovery)) fail("recovery with the peer");
// the DUT's receive side: what the core hands to the RX register
always @(posedge PCLK)
  if (PRESETN && dut.u_core.rx_valid && dut.u_core.rx_ready) begin
    if (psh == pst) fail($sformatf("RX: byte %h, none sent", dut.u_core.rx_data));
    else begin
      if ({dut.u_core.rx_err, dut.u_core.rx_last, dut.u_core.rx_data} !== ps[psh % 8192])
        fail($sformatf("RX: byte %b %b %h, expected %h", dut.u_core.rx_err, dut.u_core.rx_last,
                       dut.u_core.rx_data, ps[psh % 8192]));
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
function automatic logic [15:0] crc16_8(input logic [15:0] c, input logic [7:0] d);
  for (int i = 7; i >= 0; i--) c = {c[14:0], 1'b0} ^ ((c[15] ^ d[i]) ? 16'h100B : 16'h0);
  return c;
endfunction
function automatic logic [31:0] crc32_8(input logic [31:0] c, input logic [7:0] d);
  for (int i = 7; i >= 0; i--) c = {c[30:0], 1'b0} ^ ((c[31] ^ d[i]) ? 32'h04C1_1DB7 : 32'h0);
  return c;
endfunction
function automatic logic [15:0] w5(input logic [10:0] info);
  logic [4:0] c;
  c = 5'h1F;
  for (int i = 10; i >= 0; i--) c = {c[3:0], 1'b0} ^ ((c[4] ^ info[i]) ? 5'h05 : 5'h00);
  return {~c, info};
endfunction
task automatic bos(input logic [7:0] s);
  bq.push_back({1'b1, s}); bq.push_back({1'b1, s}); bq.push_back({1'b1, s}); bq.push_back({1'b1, EPF});
endtask
// a link command; bad: both copies fail their CRC-5
task automatic blc(input logic [10:0] info, input bit bad = 0);
  logic [15:0] w;
  w = w5(info) ^ (bad ? 16'h0001 : 16'h0);
  bos(SLC);
  bq.push_back({1'b0, w[15:8]}); bq.push_back({1'b0, w[7:0]});
  bq.push_back({1'b0, w[15:8]}); bq.push_back({1'b0, w[7:0]});
endtask
// an advertisement: LGOOD_n, then a credit for each of the DUT's buffers
task automatic badv(input int n);
  blc(11'(n & 7));
  for (int i = 0; i < TXN; i++) blc(11'h080 | 11'(i));
endtask
// a header packet: byte 0 h0, the rest random; mode 0 good, 1 bad CRC-16,
// 2 a K symbol inside; accept: the DUT must deliver it (a data packet's
// header is queued by bdpp)
logic [7:0]  bh [0:11];
int          b_seq = 0;                       // the DUT's next sequence number
task bhp(input logic [7:0] h0, input int mode = 0, input bit accept = 0, input int seq = -1);
  logic [15:0] c, w;
  bh[0] = h0;
  for (int i = 1; i < 12; i++) bh[i] = 8'($urandom);
  bos(SHP);
  c = 16'hFFFF;
  for (int i = 0; i < 12; i++) begin
    bq.push_back({1'b0, bh[i]}); c = crc16_8(c, bh[i]);
    if (mode == 2 && i == 5) bq.push_back({1'b1, SDP});
  end
  c = ~c ^ (mode == 1 ? 16'h0001 : 16'h0);
  w = w5(11'((seq < 0 ? b_seq : seq) & 7));
  bq.push_back({1'b0, c[15:8]}); bq.push_back({1'b0, c[7:0]});
  bq.push_back({1'b0, w[15:8]}); bq.push_back({1'b0, w[7:0]});
  if (accept) begin
    b_seq++;
    if (h0[4:0] != 5'b01000) for (int i = 0; i < 12; i++) begin ps[pst % 8192] = {1'b0, i == 11, bh[i]}; pst++; end
  end
endtask
// a payload of n bytes after a data packet header sent with accept: mode 0
// good, 1 bad CRC-32, 2 aborted with EDB
task bdpp(input int n, input int mode = 0);
  logic [31:0] c;
  logic [7:0]  x;
  bit          ok;
  ok = mode == 0;
  for (int i = 0; i < 12; i++) begin ps[pst % 8192] = {!ok, i == 11 && !(ok && n > 0), bh[i]}; pst++; end
  bos(SDP);
  c = '1;
  for (int i = 0; i < n; i++) begin
    x = 8'($urandom);
    bq.push_back({1'b0, x}); c = crc32_8(c, x);
    if (ok) begin ps[pst % 8192] = {1'b0, i == n - 1, x}; pst++; end
  end
  c = ~c ^ (mode == 1 ? 32'h0000_0100 : 32'h0);
  for (int i = 3; i >= 0; i--) bq.push_back({1'b0, c[8 * i +: 8]});
  bos(mode == 2 ? EDB : ENDS);
endtask

task automatic irq_expect(input int b);
  rd(A_IRQ_STATUS);
  if (!rdv[b]) fail($sformatf("IRQ bit %0d not set (%h)", b, rdv));
endtask
// the host writes a packet, back to back
bit          h_rd = 0;
task h_pkt;
  int n;
  new_pk(0, n);
  if (!bfm) expect_pk(0, n);
  for (int i = 0; i < n; i++) begin
    @(negedge PCLK);
    // RX read while TX waits: the peer's packets keep moving
    while (dut.full_TX)
      if (h_rd && dut.avail_RX) rd(A_RX);
      else @(negedge PCLK);
    apb_now(1, A_TX, {23'd0, i == n - 1, pk[i]}, 4'hF);
  end
endtask
// the host writes a one-byte packet
task automatic h_one(input logic [7:0] d);
  hq[hqt % 8192] = {2'b00, d}; hqt++;
  for (int i = 1; i < 12; i++) begin hq[hqt % 8192] = {1'b0, i == 11, 8'h00}; hqt++; end
  wr(A_TX, {23'd0, 1'b1, d});
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
// the DUT up against the BFM; the advertisement acknowledges all it sent
task automatic bfm_up;
  wr(A_CTRL, 1);
  cycles(20);
  badv(dut.u_core.nsent - 1);
  bwait();
  poll(A_STATUS, 1, 1, 200);
  b_seq = dut.u_core.rxs;
endtask

task automatic ip_func;
  wr(A_IRQ_ENABLE, 0);
  // packets written before the link is up fill the retry buffers, then
  // wait in TX; written again: TX_OVF
  for (int i = 0; i <= TXN; i++) h_one(8'(8'h30 + i));
  wr(A_TX, 32'hFFFF_FFFF);
  irq_expect(IRQ_TX_OVF);
  rd(A_FLAGS);
  if (rdv[1:0] !== 2'b01) fail($sformatf("FLAGS %h with TX waiting", rdv));
  // link up with the peer
  wr(A_CTRL, 1);
  p_link = 1;
  poll(A_STATUS, 1, 1, 2000);
  cycles(1000);
  if (hqh != hqt) fail("the waiting packets did not reach the peer");
  // traffic both ways: the host writes packets, the peer writes back; RX is
  // read while TX waits and after every other packet (back-pressure in
  // between)
  p_en = 1;
  h_rd = 1;
  for (int i = 0; i < 40; i++) begin
    h_pkt();
    // (bounded: the peer keeps writing)
    if (i % 2 == 1) for (int k = 0; k < 100 && dut.avail_RX; k++) rd(A_RX);
  end
  p_en = 0;
  h_rd = 0;
  while (p_n != 0 || p_tx_valid) @(negedge PCLK);
  h_drain();
  rd(A_RX);                                     // empty: the last byte again
  cycles(1000);
  if (hqh != hqt) fail($sformatf("peer missed %0d bytes", hqt - hqh));
  if (psh != pst) fail($sformatf("RX missed %0d bytes", pst - psh));
  irq_expect(IRQ_TX_DONE);
  irq_expect(IRQ_RX_AVAIL);

  // BFM in the peer's place
  link_down();
  rd(A_STATUS);
  if (rdv !== 0) fail($sformatf("STATUS %h with the link down", rdv));
  bfm = 1;
  bfm_up();
  // packets to the DUT: a header, a data packet, a bad CRC-16 and a K
  // symbol inside (each until LRTY), a bad link command, failing payloads
  bhp(8'h04, 0, 1);
  bhp(8'h08, 0, 1); bdpp(20);
  bhp(8'h04, 1);
  blc(11'h100);
  bhp(8'h04, 2);
  blc(11'h100);
  blc(11'h000, 1);
  bhp(8'h08, 0, 1); bdpp(8, 1);
  bhp(8'h08, 0, 1); bdpp(8, 2);
  bwait();
  cycles(20);
  h_drain();
  irq_expect(IRQ_ERR_HP);
  irq_expect(IRQ_ERR_FRAME);
  irq_expect(IRQ_ERR_LC);
  irq_expect(IRQ_ERR_DPP);
  // overflow: RX not read; RXN + 1 more packets (the last is dropped)
  for (int i = 0; i < RXN; i++) bhp(8'h04, 0, 1);
  bhp(8'h04);
  bwait();
  cycles(20);
  irq_expect(IRQ_ERR_OVERFLOW);
  h_drain();
  // a packet to the BFM, an LBAD (sent again), no LGOOD: the pending timer
  // and recovery
  h_pkt();
  while (dut.u_core.t_out == 0) @(negedge PCLK);
  blc(11'h180);
  bwait();
  cycles(50);
  irq_expect(IRQ_LBAD);
  cycles(500);
  irq_expect(IRQ_TIMEOUT);
  irq_expect(IRQ_RECOVERY);
  link_down();
  // up again: an LCRD with the wrong letter
  bfm_up();
  blc(11'h082);
  bwait();
  cycles(20);
  irq_expect(IRQ_ERR_PROTO);
  link_down();
  // up again: a header packet with the wrong sequence number
  bfm_up();
  bhp(8'h04, 0, 0, b_seq + 1);
  bwait();
  cycles(20);
  irq_expect(IRQ_ERR_SEQ);
  link_down();

  // interrupts: masked, raising irq, cleared one by one
  rd(A_IRQ_STATUS);
  if (rdv[12:0] != 13'h1FFF) fail($sformatf("IRQ_STATUS %h, expected every bit", rdv));
  if (irq) fail("irq high with every bit masked");
  wr(A_IRQ_ENABLE, IRQ_ALL);
  if (!irq) fail("irq low with every bit enabled");
  for (int b = 0; b < 13; b++) wr(A_IRQ_STATUS, 1 << b);
  rd(A_IRQ_STATUS);
  if (rdv[12:0] != 0) fail($sformatf("IRQ_STATUS %h after clearing", rdv));
  if (irq) fail("irq high with nothing pending");
  // up again: TX_DONE drives the pin
  wr(A_IRQ_ENABLE, 1 << IRQ_TX_DONE);
  bfm_up();
  h_pkt();
  poll(A_IRQ_STATUS, 1 << IRQ_TX_DONE, 1 << IRQ_TX_DONE, 500);
  if (!irq) fail("irq low with TX_DONE pending");
  cycles(100);
  link_down();
  bfm = 0;
endtask
