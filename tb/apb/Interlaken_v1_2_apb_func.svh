// SPDX-License-Identifier: Apache-2.0
// Interlaken-specific part of tb/Interlaken_v1_2_apb_tb.sv. A second
// Interlaken_v1_2_top (the peer, driven directly with random packets and
// flow control) is cross-connected to the DUT's lane pins; bits of the line
// into the DUT can be flipped at chosen positions.
// Covered through the registers: words written through TX0..TX2 checked at
// the peer, words read through RX0..RX2 checked against what the peer sent,
// TX written while full, RX overflowing and popped as it captures, FC and
// RX_FC both ways, STATUS, each error interrupt from a flipped bit, every
// stream event and interrupt bit.
localparam int WCLK = 67, MCLK = 64 * WCLK;
wire         p_tx;
logic        lflip = 0;
assign rx_p = p_tx ^ lflip;

// peer
logic        p_tx_valid = 0, p_tx_sop = 0, p_tx_eop = 0;
logic [63:0] p_tx_data = 0;
logic [2:0]  p_tx_bytes = 0;
logic [7:0]  p_tx_chan = 0;
logic [15:0] p_tx_fc = 0;
wire         p_tx_ready, p_rx_valid, p_rx_sop, p_rx_eop, p_rx_err, p_word_lock, p_sync_lock;
wire         p_err_word, p_err_sync, p_err_scr, p_err_crc32, p_err_crc24, p_err_proto;
wire  [63:0] p_rx_data;
wire  [2:0]  p_rx_bytes;
wire  [7:0]  p_rx_chan;
wire  [15:0] p_rx_fc;
wire  [1:0]  p_peer_status;
Interlaken_v1_2_top #(.SEED(58'h0AB_5A5A_1234_8765)) u_peer (
  .clk(PCLK), .rst_n(PRESETN), .tx_p(p_tx), .rx_p(tx_p),
  .tx_valid(p_tx_valid), .tx_ready(p_tx_ready), .tx_data(p_tx_data), .tx_sop(p_tx_sop), .tx_eop(p_tx_eop),
  .tx_bytes(p_tx_bytes), .tx_chan(p_tx_chan), .tx_fc(p_tx_fc),
  .rx_valid(p_rx_valid), .rx_data(p_rx_data), .rx_sop(p_rx_sop), .rx_eop(p_rx_eop), .rx_bytes(p_rx_bytes),
  .rx_chan(p_rx_chan), .rx_err(p_rx_err), .rx_fc(p_rx_fc), .word_lock(p_word_lock), .sync_lock(p_sync_lock),
  .peer_status(p_peer_status), .err_word(p_err_word), .err_sync(p_err_sync), .err_scr(p_err_scr),
  .err_crc32(p_err_crc32), .err_crc24(p_err_crc24), .err_proto(p_err_proto));

// words as {err, chan, bytes, eop, sop, data}
function automatic logic [77:0] wpack(input logic [63:0] d, input logic s, e, input logic [2:0] b,
                                      input logic [7:0] c, input logic err);
  return {err, c, e ? b : 3'd0, e, s, d};
endfunction

// the peer sends packets of 1..12 words while p_en; it records each word taken
bit          p_en = 0, p_tk = 0;
int          p_left = 0;
logic [77:0] ps [0:4095];
int          psn = 0;
// a word is taken on a posedge with valid and ready (sampled there)
always @(posedge PCLK)
  if (PRESETN && p_tx_valid && p_tx_ready) begin
    ps[psn % 4096] = wpack(p_tx_data, p_tx_sop, p_tx_eop, p_tx_bytes, p_tx_chan, 1'b0); psn++;
    p_tk = 1;
  end
always @(negedge PCLK)
  if (!PRESETN) begin p_tx_valid = 0; p_left = 0; p_tk = 0; end
  else begin
    if (p_tk) begin p_tx_valid = 0; p_tk = 0; end
    if (!p_tx_valid && p_en) begin
      p_tx_sop = p_left == 0;
      if (p_left == 0) begin p_left = 1 + $urandom % 12; p_tx_chan = $urandom; p_tx_bytes = $urandom; end
      p_left--;
      p_tx_eop = p_left == 0;
      p_tx_data = {$urandom, $urandom};
      p_tx_valid = 1;
    end
  end

// what the peer must receive from the DUT: the words the host wrote, in order
logic [77:0] hq [0:1023];
int          hqh = 0, hqt = 0;
always @(negedge PCLK) if (PRESETN && p_rx_valid) begin
  if (hqh == hqt) fail($sformatf("peer: word %h, none sent", p_rx_data));
  else begin
    if (wpack(p_rx_data, p_rx_sop, p_rx_eop, p_rx_bytes, p_rx_chan, p_rx_err) !== hq[hqh % 1024])
      fail($sformatf("peer: word %h, expected %h", wpack(p_rx_data, p_rx_sop, p_rx_eop, p_rx_bytes, p_rx_chan, p_rx_err),
                     hq[hqh % 1024]));
    hqh++;
  end
end

task automatic irq_expect(input int b);
  rd(A_IRQ_STATUS);
  if (!rdv[b]) fail($sformatf("IRQ bit %0d not set (%h)", b, rdv));
endtask
// the host sends a packet of n words, back to back
task automatic h_pkt(input int n);
  logic [63:0] d;
  logic [7:0]  c;
  logic [2:0]  b;
  c = $urandom; b = $urandom;
  for (int i = 0; i < n; i++) begin
    d = {$urandom, $urandom};
    hq[hqt % 1024] = wpack(d, i == 0, i == n - 1, b, c, 1'b0); hqt++;
    @(negedge PCLK);
    while (dut.full_TX) @(negedge PCLK);
    apb_now(1, A_TX0, d[31:0], 4'hF);
    @(negedge PCLK);
    apb_now(1, A_TX1, d[63:32], 4'hF);
    @(negedge PCLK);
    apb_now(1, A_TX2, {19'd0, c, b, i == n - 1, i == 0}, 4'hF);
  end
endtask
// the host reads n words; the first must start a packet and is looked up
// among those the peer sent
int pr = -1;
task automatic h_recv(input int n);
  logic [77:0] v;
  for (int i = 0; i < n; i++) begin
    @(negedge PCLK);
    while (!dut.avail_RX) @(negedge PCLK);
    apb_now(0, A_RX0, 0, 0); v[31:0] = rdv;
    @(negedge PCLK);
    apb_now(0, A_RX1, 0, 0); v[63:32] = rdv;
    @(negedge PCLK);
    apb_now(0, A_RX2, 0, 0); v[77:64] = rdv[13:0];
    if (pr < 0) begin
      if (v[64]) begin
        pr = psn - 1;
        while (pr >= 0 && psn - pr < 4000 && ps[pr % 4096] !== v) pr--;
        if (pr < 0 || ps[pr % 4096] !== v) begin fail($sformatf("RX word %h was never sent", v)); pr = -1; end
      end
    end else if (ps[pr % 4096] !== v) fail($sformatf("RX word %h, expected %h", v, ps[pr % 4096]));
    if (pr >= 0) pr++;
  end
endtask
// drain RX without checking
task automatic h_drain;
  while (dut.avail_RX) rd(A_RX2);
endtask
// flip bit idx of the next word into the DUT at position pos (-1: any
// protocol position): 1 = framing bit 65, 66 - k = payload bit k
task automatic lflip_at(input int pos, input int idx, input int n = 1);
  @(negedge PCLK);
  while (!(dut.u_core.rc == 7'(idx - 1) &&
           (pos >= 0 ? dut.u_core.rpos == 6'(pos) : dut.u_core.rpos > 6'd2 && dut.u_core.rpos != 6'd63)))
    @(negedge PCLK);
  lflip = 1; repeat (n) @(negedge PCLK); lflip = 0;
endtask

task automatic ip_func;
  logic m;
  wr(A_IRQ_ENABLE, 0);
  wr(A_FC, 32'h1234);
  p_tx_fc = 16'hBEEF;
  poll(A_STATUS, 32'hF, 32'hF, 40000);
  rd(A_RX_FC);
  if (rdv !== 32'hBEEF) fail($sformatf("RX_FC %h", rdv));
  if (p_rx_fc !== 16'h1234) fail($sformatf("peer flow control %h", p_rx_fc));
  p_tx_fc = ~16'hBEEF;
  cycles(MCLK / 4);
  rd(A_RX_FC);
  if (rdv !== {16'd0, ~16'hBEEF}) fail($sformatf("RX_FC %h", rdv));
  wr(A_IRQ_STATUS, IRQ_ALL);
  // DUT -> peer
  for (int i = 0; i < 10; i++) h_pkt(1 + $urandom % 10);
  h_pkt(20);
  irq_expect(IRQ_TX_DONE);
  // TX2 written while full: TX_OVF (the second word is dropped)
  while (dut.full_TX) @(negedge PCLK);
  hq[hqt % 1024] = wpack(64'h0123_4567_89AB_CDEF, 1, 1, 3'd5, 8'h77, 1'b0); hqt++;
  wr(A_TX0, 32'h89AB_CDEF); wr(A_TX1, 32'h0123_4567);
  wr(A_TX2, {19'd0, 8'h77, 3'd5, 1'b1, 1'b1});
  wr(A_TX2, 32'hFFFF_FFFF);
  irq_expect(IRQ_TX_OVF);
  cycles(MCLK / 2);
  if (hqh != hqt) fail($sformatf("peer missed %0d words", hqt - hqh));
  // peer -> DUT
  h_drain();
  p_en = 1;
  pr = -1;
  h_recv(120);
  // RX left unread: RX_OVF
  cycles(12 * WCLK);
  irq_expect(IRQ_RX_AVAIL);
  irq_expect(IRQ_RX_OVF);
  h_drain();
  // RX popped as it captures
  for (int i = 0; i < 2; i++) begin
    h_drain();
    while (!(dut.u_core.rc == 7'd66 && dut.u_core.rh_v && dut.u_core.r_prot && dut.u_core.rfr == 2'b01 && dut.avail_RX))
      @(negedge PCLK);
    apb_now(0, A_RX2, 0, 0);
    cycles(3 * WCLK);
  end
  h_drain();
  rd(A_RX2);                                    // empty: the last word again
  rd(A_FLAGS);
  pr = -1;
  h_recv(30);

  // errors on the line into the DUT
  h_drain();
  lflip_at(-1, 66 - 20);                        // payload bit: CRC-24 and CRC-32
  m = 0;
  for (int i = 0; i < 40 && !m; i++) begin      // the word ending that burst: rx_err
    while (!dut.avail_RX) @(negedge PCLK);
    rd(A_RX2);
    m = rdv[13];
  end
  if (!m) fail("no RX word with rx_err after a flipped bit");
  cycles(MCLK);
  irq_expect(IRQ_ERR_CRC24);
  irq_expect(IRQ_ERR_CRC32);
  lflip_at(-1, 1);                              // invalid framing
  cycles(2 * WCLK);
  irq_expect(IRQ_ERR_WORD);
  lflip_at(0, 30);                              // sync word
  cycles(2 * WCLK);
  irq_expect(IRQ_ERR_SYNC);
  lflip_at(1, 30);                              // scrambler state word
  cycles(2 * WCLK);
  irq_expect(IRQ_ERR_SCR);
  p_en = 0;
  while (p_tx_valid) @(negedge PCLK);
  cycles(30 * WCLK);
  lflip_at(-1, 1, 2);                           // idle control -> data outside a burst
  cycles(WCLK);
  irq_expect(IRQ_ERR_PROTO);
  rd(A_STATUS);
  if (rdv[3:0] !== 4'hF) fail($sformatf("STATUS %h after single errors", rdv));
  h_drain();
  cycles(2 * WCLK);
  h_drain();

  // interrupts: masked, raising irq, cleared one by one
  rd(A_IRQ_STATUS);
  if (rdv[9:0] != 10'h3FF) fail($sformatf("IRQ_STATUS %h, expected every bit", rdv));
  if (irq) fail("irq high with every bit masked");
  wr(A_IRQ_ENABLE, IRQ_ALL);
  if (!irq) fail("irq low with every bit enabled");
  for (int b = 0; b < 10; b++) wr(A_IRQ_STATUS, 1 << b);
  rd(A_IRQ_STATUS);
  if (rdv[9:0] != 0) fail($sformatf("IRQ_STATUS %h after clearing", rdv));
  if (irq) fail("irq high with nothing pending");
  wr(A_IRQ_ENABLE, 1 << IRQ_TX_DONE);
  h_pkt(1);
  poll(A_IRQ_STATUS, 1 << IRQ_TX_DONE, 1 << IRQ_TX_DONE, 500);
  if (!irq) fail("irq low with TX_DONE pending");
  cycles(MCLK / 4);
  if (hqh != hqt) fail($sformatf("peer missed %0d words", hqt - hqh));
endtask
