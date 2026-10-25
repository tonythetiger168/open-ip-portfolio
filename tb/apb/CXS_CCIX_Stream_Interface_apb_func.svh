// SPDX-License-Identifier: Apache-2.0
// CXS-specific part of tb/CXS_CCIX_Stream_Interface_apb_tb.sv. A second
// CXS_CCIX_Stream_Interface_top (the peer, driven directly) is joined to
// the DUT's CXS interfaces; for the error tests the TB takes the peer's
// place on the DUT's receive interface for a few flits.
// Covered through the registers: CTRL (both sides activated, deactivated
// with tx_en and with rx_en), packets written through TX0 / TX1 checked at
// the peer, the peer's packets read through RX0 / RX1 (with END_ERROR),
// STATUS (link states, credits held), TX written while full, RX read
// empty, CRD (a flit without a credit) and CNTL (a bad flit cutting a
// packet), every interrupt bit.
// peer
logic        p_txen = 0, p_rxen = 0, p_tv = 0, p_tl = 0, p_te = 0, p_rr = 1;
logic [31:0] p_td = 0;
wire         p_trdy, p_rv, p_rl, p_re;
wire  [31:0] p_rd;
wire         p_ctv, p_ctrtn, p_ctreq, p_crgnt, p_crack, p_crhint;
wire  [127:0] p_ctd;
wire  [13:0] p_ctc;
wire  [1:0]  p_txl, p_rxl;
wire  [3:0]  p_tcr;
wire         p_ev_crd, p_ev_cntl;
CXS_CCIX_Stream_Interface_top u_peer (
  .clk(PCLK), .rst_n(PRESETN), .tx_en(p_txen), .rx_en(p_rxen),
  .tx_valid(p_tv), .tx_ready(p_trdy), .tx_data(p_td), .tx_last(p_tl), .tx_err(p_te),
  .rx_valid(p_rv), .rx_ready(p_rr), .rx_data(p_rd), .rx_last(p_rl), .rx_err(p_re),
  .cxs_tx_valid(p_ctv), .cxs_tx_data(p_ctd), .cxs_tx_cntl(p_ctc), .cxs_tx_crdgnt(cxs_rx_crdgnt),
  .cxs_tx_crdrtn(p_ctrtn), .cxs_tx_activereq(p_ctreq), .cxs_tx_activeack(cxs_rx_activeack), .cxs_tx_deacthint(cxs_rx_deacthint),
  .cxs_rx_valid(cxs_tx_valid), .cxs_rx_data(cxs_tx_data), .cxs_rx_cntl(cxs_tx_cntl), .cxs_rx_crdgnt(p_crgnt),
  .cxs_rx_crdrtn(cxs_tx_crdrtn), .cxs_rx_activereq(cxs_tx_activereq), .cxs_rx_activeack(p_crack), .cxs_rx_deacthint(p_crhint),
  .tx_link(p_txl), .rx_link(p_rxl), .tx_credits(p_tcr), .ev_crd(p_ev_crd), .ev_cntl(p_ev_cntl));
// the DUT's transmit interface sees the peer's receive side
always @* begin
  cxs_tx_crdgnt = p_crgnt | j_gnt; cxs_tx_activeack = p_crack; cxs_tx_deacthint = p_crhint;
end
// the DUT's receive interface: the peer's transmit side, or the TB
bit          inj = 0;
logic        j_v = 0, j_req = 0, j_rtn = 0, j_gnt = 0;
int          j_cr = 0;                          // credits the DUT granted the TB
always @(posedge PCLK) if (inj && cxs_rx_crdgnt) j_cr++;
logic [127:0] j_d = 0;
logic [13:0] j_c = 0;
always @* begin
  cxs_rx_valid = inj ? j_v : p_ctv;
  cxs_rx_data = inj ? j_d : p_ctd;
  cxs_rx_cntl = inj ? j_c : p_ctc;
  cxs_rx_crdrtn = inj ? j_rtn : p_ctrtn;
  cxs_rx_activereq = inj ? j_req : p_ctreq;
end

// the peer stops reading: after 4 one-packet flits the DUT holds no
// credit, and the next flit fills while it waits
task automatic hold_peer();
  p_rr = 0;
  for (int i = 0; i < 4; i++) begin h_pkt(1, 0); cycles(10); end
endtask
// peer writer and reader
logic [33:0] pw [$], pe [$], de [$];             // peer writes, expected at the peer, expected through RX
always @(posedge PCLK) if (PRESETN && p_tv && p_trdy) void'(pw.pop_front());
always @(negedge PCLK) begin : b_pdrv
  logic [33:0] x;
  p_tv = PRESETN && pw.size() != 0 && $urandom % 4 != 0;
  x = p_tv ? pw[0] : {$urandom, $urandom};
  p_td = x[31:0]; p_tl = x[32]; p_te = x[33];
end
always @(posedge PCLK) if (PRESETN && p_rv && p_rr) begin : b_prd
  logic [33:0] x;
  if (pe.size() == 0) fail($sformatf("peer: word %h not written", p_rd));
  else begin
    x = pe.pop_front();
    if ({p_re, p_rl, p_rd} != x) fail($sformatf("peer: %h, expected %h", {p_re, p_rl, p_rd}, x));
  end
end
task automatic p_pkt(input int n, input bit er);
  logic [33:0] x;
  for (int i = 0; i < n; i++) begin
    x = {i == n - 1 && er, i == n - 1, 32'($urandom)};
    pw.push_back(x); de.push_back(x);
  end
endtask
task automatic h_pkt(input int n, input bit er);
  logic [33:0] x;
  for (int i = 0; i < n; i++) begin
    x = {i == n - 1 && er, i == n - 1, 32'($urandom)};
    poll(A_FLAGS, 1 << FLAG_TX_FULL, 0, 2000);
    wr(A_TX0, x[31:0]);
    wr(A_TX1, {30'd0, x[33:32]});
    pe.push_back(x);
  end
endtask
task automatic h_get();
  logic [33:0] x;
  poll(A_FLAGS, 1 << FLAG_RX_AVAIL, 1 << FLAG_RX_AVAIL, 2000);
  x = de.pop_front();
  rd_exp(A_RX0, x[31:0]);
  rd_exp(A_RX1, {30'd0, x[33:32]});
endtask
task automatic irq_expect(input int b);
  cycles(3);
  rd(A_IRQ_STATUS);
  if (!rdv[b]) fail($sformatf("IRQ bit %0d not set (%h)", b, rdv));
endtask
task automatic inj_flit(input logic [127:0] d, input logic [13:0] c);
  @(negedge PCLK);
  j_v = 1; j_d = d; j_c = c;
  @(negedge PCLK);
  j_v = 0; j_d = {$urandom, $urandom, $urandom, $urandom}; j_c = $urandom;
endtask

task automatic ip_func;
  wr(A_IRQ_ENABLE, 0);
  // the DUT's transmit side waits in ACTIVATE until the peer accepts
  wr(A_CTRL, 32'h1);
  cycles(10);
  rd_exp(A_STATUS, 32'h01);
  p_rxen = 1;
  cycles(20);
  rd_exp(A_STATUS, 32'h42);                     // RUN, 4 credits
  wr(A_CTRL, 32'h3);
  p_txen = 1;
  cycles(20);
  rd_exp(A_STATUS, 32'h4A);
  // packets both ways
  for (int n = 1; n <= 6; n++) h_pkt(n, n == 3);
  for (int n = 1; n <= 6; n++) p_pkt(n, n == 5);
  cycles(60);
  irq_expect(IRQ_RX_AVAIL);
  while (de.size() != 0) h_get();
  rd(A_RX1);                                    // empty
  cycles(40);
  if (pe.size() != 0) fail("packets not received at the peer");
  // TX written while full: the peer's receive side off, the DUT deactivates
  p_rxen = 0;
  cycles(60);
  rd_exp(A_STATUS, 32'h09);                     // ACTIVATE, receive side RUN
  h_pkt(4, 0);                                  // one flit waits, then the holding register
  h_pkt(1, 0);
  rd(A_FLAGS);
  if (!rdv[FLAG_TX_FULL]) fail("TX not full with the link down");
  wr(A_TX1, 32'h1);
  irq_expect(IRQ_TX_OVF);
  p_rxen = 1;
  cycles(60);
  if (pe.size() != 0) fail("held packets not received");
  // several packets in a flit, written while the DUT waits for a credit
  hold_peer();
  h_pkt(1, 1); h_pkt(2, 1);                     // START at 0 and 1, END at 0 and 2, both END_ERROR
  p_rr = 1;
  cycles(60);
  p_rr = 0;
  for (int i = 0; i < 3; i++) begin h_pkt(1, 0); cycles(10); end
  h_pkt(7, 0); h_pkt(1, 0);                     // the 7-word packet ends at 2, the next starts at 3
  p_rr = 1;
  cycles(60);
  hold_peer();
  h_pkt(2, 0); h_pkt(1, 0);                     // START at 0 and 2
  p_rr = 1;
  cycles(60);
  if (pe.size() != 0) fail("packed packets not received");
  // the TB in place of the peer's transmit side: CNTL (a packet left
  // open, then a bad flit), CRD (a flit with the link down)
  p_txen = 0;
  while (p_txl != 0) @(negedge PCLK);
  inj = 1; j_cr = 0; j_req = 1;
  while (j_cr == 0) @(negedge PCLK);
  j_cr--;
  inj_flit({$urandom, $urandom, $urandom, $urandom}, {2'b01, 2'd3, 2'd0, 2'b00, 2'd0, 2'd0, 2'b00});
  while (j_cr == 0) @(negedge PCLK);
  j_cr--;
  inj_flit(0, {2'b01, 2'd1, 2'd0, 2'b00, 2'd0, 2'd0, 2'b00});
  irq_expect(IRQ_CNTL);
  poll(A_FLAGS, 1 << FLAG_RX_AVAIL, 1 << FLAG_RX_AVAIL, 2000);
  rd_exp(A_RX1, 32'h0);                          // the open packet's word
  de.push_back({2'b11, 32'd0});
  h_get();                                       // the word that closes it
  cycles(10);
  j_req = 0;
  cycles(3);
  rd(A_STATUS);
  if (rdv[3:2] != 2'd3) fail($sformatf("STATUS %h: receive side not in DEACTIVATE", rdv));
  while (j_cr > 0) begin
    @(negedge PCLK); j_rtn = 1; j_cr--;
    @(negedge PCLK); j_rtn = 0;
  end
  cycles(5);
  rd(A_STATUS);
  if (rdv[3:2] != 2'd0) fail($sformatf("STATUS %h: receive side not in STOP", rdv));
  inj_flit(0, {2'b01, 2'd0, 2'd0, 2'b01, 2'd0, 2'd0, 2'b00});
  irq_expect(IRQ_CRD);
  inj = 0;
  p_txen = 1;
  cycles(60);
  // more credits than the peer grants: 12 held, all returned on deactivation
  for (int i = 0; i < 8; i++) begin @(negedge PCLK); j_gnt = 1; @(negedge PCLK); j_gnt = 0; end
  cycles(3);
  rd(A_STATUS);
  if (rdv[7:4] != 4'd12) fail($sformatf("STATUS %h: 12 credits expected", rdv));
  // deactivation with tx_en: STOP once the credits are back
  wr(A_CTRL, 32'h2);
  cycles(60);
  rd(A_STATUS);
  if (rdv[1:0] != 0 || rdv[7:4] != 0) fail($sformatf("STATUS %h after tx_en off", rdv));
  wr(A_CTRL, 32'h3);
  cycles(40);
  p_pkt(2, 0);
  cycles(30);
  while (de.size() != 0) h_get();

  // interrupts: masked, raising irq, cleared one by one
  rd(A_IRQ_STATUS);
  if (rdv[4:0] != 5'h1F) fail($sformatf("IRQ_STATUS %h, expected every bit", rdv));
  if (irq) fail("irq high with every bit masked");
  wr(A_IRQ_ENABLE, IRQ_ALL);
  if (!irq) fail("irq low with every bit enabled");
  for (int b = 0; b < 5; b++) wr(A_IRQ_STATUS, 1 << b);
  rd(A_IRQ_STATUS);
  if (rdv[4:0] != 0) fail($sformatf("IRQ_STATUS %h after clearing", rdv));
  if (irq) fail("irq high with nothing pending");
  wr(A_IRQ_ENABLE, 1 << IRQ_RX_AVAIL);
  p_pkt(1, 0);
  cycles(30);
  if (!irq) fail("irq low with RX_AVAIL pending");
  h_get();
  wr(A_IRQ_ENABLE, 0);
  wr(A_CTRL, 0);
  p_txen = 0; p_rxen = 0;
  cycles(60);
endtask
