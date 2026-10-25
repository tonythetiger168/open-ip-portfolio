// SPDX-License-Identifier: Apache-2.0
// USB4-specific part of tb/USB4_apb_tb.sv. A second USB4_top (the peer,
// driven directly with random packets on both paths) is cross-connected to
// the DUT's byte pins; a byte BFM can take the peer's place on the DUT's
// receive side to send any stream, good or not.
// Covered through the registers: packets written through TX on both paths
// checked at the peer, packets from the peer checked as the DUT hands them
// to RX (the bound checker checks every RX read against that), TX written
// while full and before the link is up, RX back-pressure, popped as it
// captures and read empty, CTRL, HOP0/HOP1 and STATUS, each event interrupt
// (from BFM packets), every stream event and interrupt bit.
localparam int MAXL = 32, RXB = 2, DELTA = 4;
localparam logic [10:0] H_T0 = 11'h2A5, H_T1 = 11'h55A, H_R0 = 11'h0F3, H_R1 = 11'h70C;

// peer: its egress HopIDs are the DUT's ingress ones and the other way
logic        p_link = 0, p_tx_valid = 0, p_tx_last = 0, p_tx_path = 0, p_rx_ready = 0;
logic [7:0]  p_tx_data = 0;
wire  [7:0]  p_tx_sym, p_rx_data;
wire         p_tx_ready, p_rx_valid, p_rx_last, p_rx_path, p_sync;
wire  [1:0]  p_path_up;
wire         p_ev_hec_fix, p_ev_hec_bad, p_ev_proto, p_ev_hop, p_ev_len, p_ev_overflow;
// BFM in the peer's place
bit          bfm = 0;
logic [7:0]  b_sym = 0;
assign rx_sym = bfm ? b_sym : p_tx_sym;
USB4_top u_peer (
  .clk(PCLK), .rst_n(PRESETN), .link_up(p_link), .tx_sym(p_tx_sym), .rx_sym(tx_sym), .path_en(2'b11),
  .hop_tx0(H_R0), .hop_tx1(H_R1), .hop_rx0(H_T0), .hop_rx1(H_T1),
  .tx_valid(p_tx_valid), .tx_ready(p_tx_ready), .tx_data(p_tx_data), .tx_last(p_tx_last), .tx_path(p_tx_path),
  .rx_valid(p_rx_valid), .rx_ready(p_rx_ready), .rx_data(p_rx_data), .rx_last(p_rx_last), .rx_path(p_rx_path),
  .sync(p_sync), .path_up(p_path_up), .ev_hec_fix(p_ev_hec_fix), .ev_hec_bad(p_ev_hec_bad), .ev_proto(p_ev_proto),
  .ev_hop(p_ev_hop), .ev_len(p_ev_len), .ev_overflow(p_ev_overflow));

// byte queues {last, byte} per path (Icarus has no arrays of queues):
// ps0/ps1: what the DUT must hand to RX on path 0/1; hq0/hq1: what the peer
// must receive on path 0/1
logic [8:0]  ps0 [$], ps1 [$], hq0 [$], hq1 [$];
task automatic qpush(input int i, input logic [8:0] x);
  case (i)
    0: ps0.push_back(x); 1: ps1.push_back(x); 2: hq0.push_back(x); default: hq1.push_back(x);
  endcase
endtask
task automatic qpop(input int i, output logic [8:0] x);
  case (i)
    0: x = ps0.pop_front(); 1: x = ps1.pop_front(); 2: x = hq0.pop_front(); default: x = hq1.pop_front();
  endcase
endtask
function automatic int qsize(input int i);
  case (i)
    0: return ps0.size(); 1: return ps1.size(); 2: return hq0.size(); default: return hq1.size();
  endcase
endfunction
task automatic qclear;
  ps0.delete(); ps1.delete(); hq0.delete(); hq1.delete();
endtask

// the peer writes packets of 1..MAXL bytes on random paths while p_en; a
// byte is taken on a posedge with valid and ready (sampled there)
bit          p_en = 0, p_tk = 0;
int          p_n = 0, p_i = 0;
logic [7:0]  pk [0:63];
always @(posedge PCLK)
  if (PRESETN && p_tx_valid && p_tx_ready) p_tk = 1;
always @(negedge PCLK)
  if (!PRESETN) begin p_tx_valid = 0; p_n = 0; p_i = 0; p_tk = 0; end
  else begin
    if (p_tk) begin p_tx_valid = 0; p_tk = 0; p_i++; if (p_i == p_n) begin p_n = 0; p_i = 0; end end
    if (!p_tx_valid && (p_en || p_n != 0) && $urandom % 4 != 0) begin
      if (p_n == 0) begin
        p_n = 1 + $urandom % MAXL; p_i = 0; p_tx_path = $urandom;
        for (int i = 0; i < p_n; i++) begin pk[i] = 8'($urandom); qpush(p_tx_path, {i == p_n - 1, pk[i]}); end
      end
      p_tx_last = p_i == p_n - 1;
      p_tx_data = pk[p_i];
      p_tx_valid = 1;
    end
    p_rx_ready = $urandom % 4 != 0;
  end
// the peer's receive side: the host's packets in order, per path
always @(posedge PCLK)
  if (PRESETN && p_rx_valid && p_rx_ready) begin : b_peer_rx
    logic [8:0] x;
    if (qsize(2 + p_rx_path) == 0) fail($sformatf("peer: byte %h on path %0d, none written", p_rx_data, p_rx_path));
    else begin
      qpop(2 + p_rx_path, x);
      if ({p_rx_last, p_rx_data} !== x) fail($sformatf("peer: byte %b %h, expected %h", p_rx_last, p_rx_data, x));
    end
  end
// the DUT's receive side: what the core hands to the RX register
always @(posedge PCLK)
  if (PRESETN && dut.u_core.rx_valid && dut.u_core.rx_ready) begin : b_dut_rx
    logic [8:0] x;
    if (qsize(dut.u_core.rx_path) == 0) fail($sformatf("RX: byte %h, none sent", dut.u_core.rx_data));
    else begin
      qpop(dut.u_core.rx_path, x);
      if ({dut.u_core.rx_last, dut.u_core.rx_data} !== x)
        fail($sformatf("RX: byte %b %h, expected %h", dut.u_core.rx_last, dut.u_core.rx_data, x));
    end
  end

// ---------------- BFM ----------------
// with nothing queued it sends Idle packets
logic [7:0]  bq [$];
logic [7:0]  fq [$];
always @(negedge PCLK) begin
  if (fq.size() == 0 && bq.size() == 0) begin
    fq.push_back(8'h00); fq.push_back(8'h00); fq.push_back(8'h00); fq.push_back(8'h55);
  end
  if (fq.size() != 0) b_sym = fq.pop_front();
  else b_sym = bq.pop_front();
end
task automatic bwait;
  while (bq.size() != 0) @(negedge PCLK);
  @(negedge PCLK);
endtask
function automatic logic [31:0] mkh(input logic [3:0] pdf, input logic [10:0] hop, input logic [7:0] len);
  logic [23:0] d;
  logic [7:0]  c;
  d = {pdf, 1'b0, hop, len};
  c = 0;
  for (int i = 23; i >= 0; i--) c = {c[6:0], 1'b0} ^ ((c[7] ^ d[i]) ? 8'h07 : 8'h00);
  return {d, c ^ 8'h55};
endfunction
// a header; x: bits flipped
task automatic bhdr(input logic [3:0] pdf, input logic [10:0] hop, input logic [7:0] len, input logic [31:0] x = 0);
  logic [31:0] w;
  w = mkh(pdf, hop, len) ^ x;
  bq.push_back(w[31:24]); bq.push_back(w[23:16]); bq.push_back(w[15:8]); bq.push_back(w[7:0]);
endtask
// a data packet of l bytes (padded); q >= 0: the DUT hands it out on path q
task bdata(input logic [10:0] hop, input int l, input int q = -1);
  logic [7:0] b;
  bhdr(4'h0, hop, 8'(l));
  for (int i = 0; i < (l + 3) / 4 * 4; i++) begin
    b = i < l ? 8'($urandom) : 8'h00;
    bq.push_back(b);
    if (q >= 0 && i < l) qpush(q, {i == l - 1, b});
  end
endtask

task automatic irq_expect(input int b);
  rd(A_IRQ_STATUS);
  if (!rdv[b]) fail($sformatf("IRQ bit %0d not set (%h)", b, rdv));
endtask
// the host writes a packet of n bytes to path p; RX is read while TX
// waits (h_rd), so the peer's packets keep moving
bit          h_rd = 0;
task h_pkt(input int p, input int n);
  logic [7:0] d;
  for (int i = 0; i < n; i++) begin
    d = $urandom;
    if (!bfm) qpush(2 + p, {i == n - 1, d});
    @(negedge PCLK);
    while (dut.full_TX)
      if (h_rd && dut.avail_RX) rd(A_RX);
      else @(negedge PCLK);
    apb_now(1, A_TX, {22'd0, p[0], i == n - 1, d}, 4'hF);
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
  wr(A_CTRL, {29'd0, 2'b11, 1'b0});
  p_link = 0;
  cycles(3);
  qclear();
  bq.delete();
endtask

task automatic ip_func;
  wr(A_IRQ_ENABLE, 0);
  wr(A_HOP0, {10'd0, H_R0, H_T0});
  wr(A_HOP1, {10'd0, H_R1, H_T1});
  // a packet written before the link is up waits in path 0's buffer, the
  // next one in TX; written again: TX_OVF
  hq0.push_back({1'b1, 8'hA5});
  wr(A_TX, {22'd0, 1'b0, 1'b1, 8'hA5});
  hq0.push_back({1'b1, 8'h5A});
  wr(A_TX, {22'd0, 1'b0, 1'b1, 8'h5A});
  wr(A_TX, 32'hFFFF_FFFF);
  irq_expect(IRQ_TX_OVF);
  rd(A_FLAGS);
  if (rdv[1:0] !== 2'b01) fail($sformatf("FLAGS %h with TX waiting", rdv));
  // link up with the peer, both paths
  wr(A_CTRL, {29'd0, 2'b11, 1'b1});
  p_link = 1;
  poll(A_STATUS, 7, 7, 2000);
  cycles(300);
  if (hq0.size() != 0) fail("the waiting packets did not reach the peer");
  // traffic both ways on both paths; RX read while TX waits and after
  // every other packet (bounded: the peer keeps writing)
  p_en = 1;
  h_rd = 1;
  for (int i = 0; i < 40; i++) begin
    h_pkt($urandom % 2, 1 + $urandom % MAXL);
    if (i % 2 == 1) for (int k = 0; k < 100 && dut.avail_RX; k++) rd(A_RX);
  end
  p_en = 0;
  h_rd = 0;
  while (p_n != 0 || p_tx_valid) @(negedge PCLK);
  h_drain();
  rd(A_RX);                                     // empty: the last byte again
  cycles(500);
  if (hq0.size() + hq1.size() != 0) fail($sformatf("peer missed %0d bytes", hq0.size() + hq1.size()));
  if (ps0.size() + ps1.size() != 0) fail($sformatf("RX missed %0d bytes", ps0.size() + ps1.size()));
  irq_expect(IRQ_TX_DONE);
  irq_expect(IRQ_RX_AVAIL);

  // BFM in the peer's place
  link_down();
  rd(A_STATUS);
  if (rdv !== 0) fail($sformatf("STATUS %h with the link down", rdv));
  bfm = 1;
  wr(A_CTRL, {29'd0, 2'b11, 1'b1});
  poll(A_STATUS, 1, 1, 200);
  // packets: good on both paths, a corrected header, an uncorrectable one
  // (then SYNC again), the receive errors
  bdata(H_R0, 7, 0);
  bdata(H_R1, 32, 1);
  bhdr(4'h0, 0, 0, 32'h0000_0400);
  bwait();
  cycles(50);
  h_drain();
  irq_expect(IRQ_HEC_FIX);
  bhdr(4'h0, 0, 0, 32'h0003_0000);
  bwait();
  irq_expect(IRQ_ERR_HEC);
  poll(A_STATUS, 1, 1, 200);
  bhdr(4'h3, 0, 0);                              // HopID 0, unknown PDF
  bdata(11'h123, 8);                             // no such path
  bdata(H_R0, 0);                                // length 0
  bwait();
  cycles(20);
  irq_expect(IRQ_ERR_PROTO);
  irq_expect(IRQ_ERR_HOP);
  irq_expect(IRQ_ERR_LEN);
  // overflow: RX not read; RXB + 1 packets on path 0
  for (int i = 0; i < RXB; i++) bdata(H_R0, 8, 0);
  bdata(H_R0, 8);
  bwait();
  cycles(20);
  irq_expect(IRQ_ERR_OVERFLOW);
  h_drain();
  link_down();
  bfm = 0;

  // interrupts: masked, raising irq, cleared one by one
  rd(A_IRQ_STATUS);
  if (rdv[8:0] != 9'h1FF) fail($sformatf("IRQ_STATUS %h, expected every bit", rdv));
  if (irq) fail("irq high with every bit masked");
  wr(A_IRQ_ENABLE, IRQ_ALL);
  if (!irq) fail("irq low with every bit enabled");
  for (int b = 0; b < 9; b++) wr(A_IRQ_STATUS, 1 << b);
  rd(A_IRQ_STATUS);
  if (rdv[8:0] != 0) fail($sformatf("IRQ_STATUS %h after clearing", rdv));
  if (irq) fail("irq high with nothing pending");
  // up again with the peer: TX_DONE drives the pin
  wr(A_IRQ_ENABLE, 1 << IRQ_TX_DONE);
  wr(A_CTRL, {29'd0, 2'b11, 1'b1});
  p_link = 1;
  poll(A_STATUS, 7, 7, 2000);
  h_pkt(1, 3);
  poll(A_IRQ_STATUS, 1 << IRQ_TX_DONE, 1 << IRQ_TX_DONE, 500);
  if (!irq) fail("irq low with TX_DONE pending");
  cycles(300);
  if (hq1.size() != 0) fail($sformatf("peer missed %0d bytes", hq1.size()));
  link_down();
  wr(A_CTRL, 0);
endtask
