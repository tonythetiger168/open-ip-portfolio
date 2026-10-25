// SPDX-License-Identifier: Apache-2.0
// CCIX-specific part of tb/CCIX_Cache_Coherent_Interconnect_apb_tb.sv. A
// TB peer (BFM) sits on the TLP streams: it parses the TLPs the core sends
// (checking the messages written through TX and counting the credits they
// return), and sends TLPs of its own messages with the credits it grants.
// Covered through the registers: ID_CFG (the IDs every TLP carries),
// messages of each kind written through TX and read back through RX0 /
// RX1, STATUS (credits held), TX written while full, RX read empty, ERR
// (a bad TLP, a bad header written), NOCRD (a Request with no credit),
// OVF (Responses with RX not read), every interrupt bit.
localparam int MAXP = 16, NREQ = 2, NSNP = 2;

// ---------------- BFM receive ----------------
logic [31:0] eb [$];                            // message words written, expected at the BFM
bit          eb_h [$];
int          b_crq = 0, b_csn = 0, b_oq = 0, b_os = 0, r_i = 0, r_len = 0, r_ml = 0, r_mi = 0;
logic [7:0]  r_tag = 0;
bit          chk_ids = 0;
initial begin
  tlp_tx_ready = 0; tlp_rx_valid = 0; tlp_rx_data = 0; tlp_rx_last = 0;
end
always @(negedge PCLK) tlp_tx_ready = $urandom % 4 != 0;
always @(posedge PCLK) if (!PRESETN) begin
  r_i = 0; r_ml = 0; r_tag = 0;
end else if (tlp_tx_valid && tlp_tx_ready) begin : b_rx
  logic [31:0] w, e;
  w = tlp_tx_data;
  case (r_i)
    0: begin
      r_len = w[9:0];
      if (w[31:10] != {8'h72, 14'd0} || r_len == 0 || r_len > MAXP) fail($sformatf("TLP DW0 %h", w));
    end
    1: if (chk_ids && w != {16'h0108, r_tag, 8'h7F}) fail($sformatf("TLP DW1 %h", w));
    2: if (chk_ids && w != {16'h0210, 16'h1E2C}) fail($sformatf("TLP DW2 %h", w));
    3: if (w != 0) fail($sformatf("TLP DW3 %h", w));
    default:
      if (r_ml == 0) begin
        r_ml = w[27:24]; r_mi = 1;
        b_crq += w[23:20]; b_csn += w[19:16];
        if (w[31:28] == 0) r_ml = 0;
        else begin
          if (eb.size() == 0 || !eb_h[0]) fail($sformatf("message %h not written", w));
          else begin
            e = eb.pop_front(); void'(eb_h.pop_front());
            if ((w & 32'hFF00_FFFF) != (e & 32'hFF00_FFFF)) fail($sformatf("message %h, expected %h", w, e));
          end
          if (w[31:28] == 1) b_oq++;              // the BFM frees the buffer at once
          if (w[31:28] == 2) b_os++;
          if (r_ml == 1) r_ml = 0;
        end
      end else begin
        if (eb.size() == 0 || eb_h[0]) fail($sformatf("body word %h not written", w));
        else begin
          e = eb.pop_front(); void'(eb_h.pop_front());
          if (w != e) fail($sformatf("body word %h, expected %h", w, e));
        end
        r_mi++;
        if (r_mi == r_ml) r_ml = 0;
      end
  endcase
  r_i++;
  if (tlp_tx_last) begin r_i = 0; r_ml = 0; r_tag++; end
end

// ---------------- BFM send ----------------
logic [32:0] bq [$];
logic [31:0] bp [$];
always @(negedge PCLK) begin
  tlp_rx_valid = 0; tlp_rx_last = 0; tlp_rx_data = $urandom;
  if (PRESETN && bq.size() != 0) begin : b_tx
    logic [32:0] x;
    x = bq.pop_front();
    tlp_rx_valid = 1; tlp_rx_last = x[32]; tlp_rx_data = x[31:0];
  end
end
logic [31:0] ec [$];                            // expected through RX0 / RX1
bit          ec_l [$];
task automatic b_msg(input int ty, input int ln, input bit exp);
  logic [31:0] h;
  int cq, cs;
  cq = b_oq > 15 ? 15 : b_oq; cs = b_os > 15 ? 15 : b_os;
  b_oq -= cq; b_os -= cs;
  h = {4'(ty), 4'(ln), 4'(cq), 4'(cs), 16'($urandom)};
  if (ty == 0) h[15:0] = 0;
  if (ty == 1) b_crq--;
  if (ty == 2) b_csn--;
  bp.push_back(h);
  if (exp) begin ec.push_back(h); ec_l.push_back(ln == 1); end
  for (int i = 1; i < ln; i++) begin
    h = $urandom;
    bp.push_back(h);
    if (exp) begin ec.push_back(h); ec_l.push_back(i == ln - 1); end
  end
endtask
task automatic b_tlp(input logic [31:0] dw0);
  bq.push_back({1'b0, dw0 | 32'(bp.size())});
  bq.push_back({1'b0, 16'h0210, 8'($urandom), 8'h7F});
  bq.push_back({1'b0, 16'h0108, 16'h1E2C});
  bq.push_back({1'b0, 32'd0});
  while (bp.size() != 0) begin : b_w
    logic [31:0] w;
    w = bp.pop_front();
    bq.push_back({bp.size() == 0, w});
  end
endtask

// ---------------- host ----------------
task automatic h_put(input logic [31:0] w);
  poll(A_FLAGS, 1 << FLAG_TX_FULL, 0, 2000);
  wr(A_TX, w);
endtask
task automatic h_msg(input int ty, input int ln);
  logic [31:0] h;
  h = {4'(ty), 4'(ln), 8'($urandom), 16'($urandom)};
  h_put(h); eb.push_back(h); eb_h.push_back(1);
  for (int i = 1; i < ln; i++) begin
    h = $urandom;
    h_put(h); eb.push_back(h); eb_h.push_back(0);
  end
endtask
task automatic h_get();
  logic [31:0] e;
  bit          l;
  poll(A_FLAGS, 1 << FLAG_RX_AVAIL, 1 << FLAG_RX_AVAIL, 2000);
  e = ec.pop_front(); l = ec_l.pop_front();
  rd_exp(A_RX0, e);
  rd_exp(A_RX1, 32'(l));
endtask
task automatic irq_expect(input int b);
  cycles(3);
  rd(A_IRQ_STATUS);
  if (!rdv[b]) fail($sformatf("IRQ bit %0d not set (%h)", b, rdv));
endtask

task automatic ip_func;
  wr(A_IRQ_ENABLE, 0);
  wr(A_ID_CFG, {16'h0210, 16'h0108});
  chk_ids = 1;
  // the core's Misc came during the register tests; the BFM grants 3 / 3
  if (b_crq != NREQ || b_csn != NSNP) fail($sformatf("credits from the core %0d %0d", b_crq, b_csn));
  b_oq = 3; b_os = 3;
  b_msg(0, 1, 0); b_tlp({8'h72, 24'd0});
  cycles(30);
  rd_exp(A_STATUS, {22'd0, 5'd3, 5'd3});
  // messages of each kind through TX, checked at the BFM: every Request
  // credit spent
  h_msg(1, 3); h_msg(2, 1); h_msg(3, 8); h_msg(1, 2); h_msg(1, 1);
  cycles(60);
  if (eb.size() != 0) fail("messages not sent");
  rd_exp(A_STATUS, {22'd0, 5'd2, 5'd0});
  // TX written while full: a Request waits for a credit
  h_msg(1, 1);
  cycles(5);
  rd(A_FLAGS);
  if (!rdv[FLAG_TX_FULL]) fail("TX not held with no Request credit");
  wr(A_TX, 32'h3100_0000);
  irq_expect(IRQ_TX_OVF);
  // messages from the BFM through RX0 / RX1 (the first header returns
  // the credits the BFM owes: the held Request goes)
  b_msg(1, 2, 1); b_msg(3, 1, 1); b_msg(2, 4, 1); b_tlp({8'h72, 24'd0});
  cycles(40);
  irq_expect(IRQ_RX_AVAIL);
  for (int i = 0; i < 7; i++) h_get();
  rd(A_RX1);                                    // empty
  poll(A_FLAGS, 1 << FLAG_TX_FULL, 0, 2000);
  cycles(60);
  if (eb.size() != 0) fail("held Request not sent");
  // ERR: a bad TLP (vendor), a bad header written
  bq.push_back({1'b0, 8'h72, 24'd1});
  bq.push_back({1'b0, 16'h0210, 16'h007F});
  bq.push_back({1'b0, 16'h0108, 16'h1E2D});
  bq.push_back({1'b0, 32'd0});
  bq.push_back({1'b1, 32'h3100_0000});
  irq_expect(IRQ_ERR);
  wr(A_IRQ_STATUS, 1 << IRQ_ERR);
  h_put(32'h4100_0000);
  irq_expect(IRQ_ERR);
  // NOCRD: RX not read, so the core's credits stay with it; a Request
  // beyond them
  while (b_crq != NREQ) cycles(1);               // the core's returns are in
  while (b_crq > 0) b_msg(1, 1, 1);
  b_tlp({8'h72, 24'd0});
  b_msg(1, 1, 0); b_tlp({8'h72, 24'd0});
  cycles(30);
  irq_expect(IRQ_NOCRD);
  // OVF: Responses fill what RX has room for
  for (int i = 0; i < 12; i++) begin b_msg(3, 8, 1); b_tlp({8'h72, 24'd0}); end
  cycles(200);
  irq_expect(IRQ_OVF);
  // read what was taken (the skipped Responses are not there)
  while (ec.size() != 0) begin : b_drain
    rd(A_FLAGS);
    if (!rdv[FLAG_RX_AVAIL]) begin ec.delete(); ec_l.delete(); end
    else begin
      rd(A_RX0);
      if (rdv !== ec[0]) begin                  // a skipped Response: drop its words
        while (!ec_l[0]) begin void'(ec.pop_front()); void'(ec_l.pop_front()); end
        void'(ec.pop_front()); void'(ec_l.pop_front());
      end else begin
        rd_exp(A_RX1, 32'(ec_l[0]));
        void'(ec.pop_front()); void'(ec_l.pop_front());
      end
    end
  end
  cycles(60);
  // STATUS through large grants: twice 12 of each
  begin : b_big
    logic [31:0] st;
    rd(A_STATUS); st = rdv;
    b_oq = 12; b_os = 12; b_msg(0, 1, 0); b_tlp({8'h72, 24'd0});
    cycles(30);
    b_oq = 12; b_os = 12; b_msg(0, 1, 0); b_tlp({8'h72, 24'd0});
    cycles(30);
    rd_exp(A_STATUS, {22'd0, st[9:5] + 5'd24, st[4:0] + 5'd24});
  end

  // interrupts: masked, raising irq, cleared one by one
  rd(A_IRQ_STATUS);
  if (rdv[5:0] != 6'h3F) fail($sformatf("IRQ_STATUS %h, expected every bit", rdv));
  if (irq) fail("irq high with every bit masked");
  wr(A_IRQ_ENABLE, IRQ_ALL);
  if (!irq) fail("irq low with every bit enabled");
  for (int b = 0; b < 6; b++) wr(A_IRQ_STATUS, 1 << b);
  rd(A_IRQ_STATUS);
  if (rdv[5:0] != 0) fail($sformatf("IRQ_STATUS %h after clearing", rdv));
  if (irq) fail("irq high with nothing pending");
  wr(A_IRQ_ENABLE, 1 << IRQ_ERR);
  h_put(32'h0000_0000);
  cycles(5);
  if (!irq) fail("irq low with ERR pending");
  wr(A_IRQ_ENABLE, 0);
  chk_ids = 0;                                  // ID_CFG goes back to 0 with the reset that follows
endtask
