// SPDX-License-Identifier: Apache-2.0
// HSI-specific part of tb/HSI_apb_tb.sv. A second HSI_top (the peer, driven
// directly) sits on the other end of the lines; a bit-level BFM can take
// over the lines into the DUT. Covered through the registers: CFG, frames
// both ways through TX / RX with every channel bit set, READY holding the
// DUT's transmitter (TX backpressure, write while full), the core's FIFO
// draining through RX (pop and capture in one clock, read while empty),
// breaks both ways through CMD, every receive error, STATUS while busy,
// every interrupt bit masked, raising irq and cleared one by one.
logic        bfm = 0, b_d = 0, b_f = 0;
wire         p_tx_data, p_tx_flag;
assign rx_data = bfm ? b_d : p_tx_data;
assign rx_flag = bfm ? b_f : p_tx_flag;

// peer
logic [7:0]  p_div = 7;
logic [2:0]  p_chbits = 4;
logic        p_rx_en = 1, p_txq_valid = 0, p_brk = 0;
logic [3:0]  p_txq_ch = 0;
logic [31:0] p_txq_data = 0;
wire         p_txq_ready, p_tx_busy, p_tx_done, p_rxq_valid, p_rx_break;
wire         p_ovf, p_stray, p_ds, p_tmo;
wire  [3:0]  p_rxq_ch;
wire  [31:0] p_rxq_data;
HSI_top u_peer (
  .clk(PCLK), .rst_n(PRESETN), .tx_data(p_tx_data), .tx_flag(p_tx_flag), .tx_ready_in(rx_ready_out),
  .tx_wake(rx_wake), .rx_data(tx_data), .rx_flag(tx_flag), .rx_ready_out(tx_ready_in), .rx_wake(tx_wake),
  .cfg_div(p_div), .cfg_chbits(p_chbits), .cfg_rx_en(p_rx_en), .cfg_wake(1'b0),
  .txq_valid(p_txq_valid), .txq_ready(p_txq_ready), .txq_ch(p_txq_ch), .txq_data(p_txq_data),
  .tx_brk(p_brk), .tx_busy(p_tx_busy), .tx_done(p_tx_done),
  .rxq_valid(p_rxq_valid), .rxq_ready(1'b1), .rxq_ch(p_rxq_ch), .rxq_data(p_rxq_data),
  .rx_break(p_rx_break), .err_overflow(p_ovf), .err_stray(p_stray), .err_ds(p_ds), .err_timeout(p_tmo));

// expected frames: [0] DUT -> peer, [1] peer / BFM -> DUT
logic [35:0] fx [0:1][0:255];
int          fh [0:1], ft [0:1], p_brks = 0, p_errs = 0;
initial for (int s = 0; s < 2; s++) begin fh[s] = 0; ft[s] = 0; end
function automatic logic [35:0] fexp(input logic [3:0] ch, input logic [31:0] d);
  int cb;
  cb = p_chbits > 4 ? 4 : int'(p_chbits);
  return {ch & 4'((1 << cb) - 1), d};
endfunction
// the peer takes every frame at once and checks it
always @(negedge PCLK) if (PRESETN) begin
  if (p_rxq_valid) begin
    if (fh[0] == ft[0]) fail($sformatf("peer: unexpected frame %h", {p_rxq_ch, p_rxq_data}));
    else begin
      if ({p_rxq_ch, p_rxq_data} !== fx[0][fh[0] % 256])
        fail($sformatf("peer: frame %h, expected %h", {p_rxq_ch, p_rxq_data}, fx[0][fh[0] % 256]));
      fh[0]++;
    end
  end
  if (p_rx_break) p_brks++;
  if (p_ovf || p_stray || p_ds || p_tmo) p_errs++;
end

// DUT transmits through TX0 (channel) / TX1 (data, commits)
task automatic h_send(input logic [3:0] ch, input logic [31:0] d);
  fx[0][ft[0] % 256] = fexp(ch, d); ft[0]++;
  wr(A_TX0, 32'(ch)); wr(A_TX1, d);
endtask
// peer transmits
task automatic p_send(input logic [3:0] ch, input logic [31:0] d);
  @(negedge PCLK);
  while (!p_txq_ready) @(negedge PCLK);
  fx[1][ft[1] % 256] = fexp(ch, d); ft[1]++;
  p_txq_valid = 1; p_txq_ch = ch; p_txq_data = d;
  @(negedge PCLK);
  p_txq_valid = 0;
endtask
// background sender for the FIFO test: p_burst frames A000_0000 + i
int p_burst = 0;
initial forever begin
  wait (p_burst > 0);
  p_send(4'(6 - p_burst), 32'hA000_0000 + 6 - p_burst);
  p_burst--;
end
// read one frame from RX and check it
task automatic h_recv;
  logic [3:0] ch;
  poll(A_FLAGS, 1 << FLAG_RX_AVAIL, 1 << FLAG_RX_AVAIL, 5000);
  rd(A_RX0); ch = rdv[3:0];
  rd(A_RX1);
  if (fh[1] == ft[1]) fail($sformatf("RX: unexpected frame %h", {ch, rdv}));
  else begin
    if ({ch, rdv} !== fx[1][fh[1] % 256]) fail($sformatf("RX: frame %h, expected %h", {ch, rdv}, fx[1][fh[1] % 256]));
    fh[1]++;
  end
endtask
task automatic wait_quiet;
  int g;
  g = 0;
  while ((dut.u_core.tx_busy || p_tx_busy || fh[0] != ft[0] || dut.u_core.hold || dut.full_TX) && g < 200_000) begin
    @(negedge PCLK); g++;
  end
  if (g >= 200_000) fail("link did not go quiet");
  cycles(20);
endtask
task automatic irq_expect(input int b);
  rd(A_IRQ_STATUS);
  if (!rdv[b]) fail($sformatf("IRQ bit %0d not set (%h)", b, rdv));
endtask

// ---------------- BFM into the DUT ----------------
task automatic b_bit(input bit v);
  if (v != b_d) b_d = v; else b_f = !b_f;
  repeat (p_div + 1) @(negedge PCLK);
endtask
task automatic b_frame(input logic [3:0] ch, input logic [31:0] d, input bit exp);
  if (exp) begin fx[1][ft[1] % 256] = fexp(ch, d); ft[1]++; end
  b_bit(1);
  for (int i = 3; i >= 0; i--) b_bit(ch[i]);
  for (int i = 31; i >= 0; i--) b_bit(d[i]);
endtask
// the peer sends a break first so DATA is 0 at both hand-overs; the BFM
// ends with a break of its own and the peer's FLAG level
task automatic b_take;
  @(negedge PCLK) p_brk = 1; @(negedge PCLK) p_brk = 0;
  while (p_tx_busy) @(negedge PCLK);
  cycles(10);
  b_d = p_tx_data; b_f = p_tx_flag; bfm = 1;
endtask
task automatic b_give;
  repeat (40) b_bit(0);
  if (b_f != p_tx_flag) b_bit(0);
  cycles(10);
  bfm = 0;
endtask

task automatic ip_func;
  logic [31:0] d;
  wr(A_IRQ_ENABLE, 0);
  wr(A_CFG, 32'h0C03);                         // div 3, 4 channel bits, receiver on
  p_div = 3;
  rd(A_STATUS);
  if (rdv != 0) fail("STATUS busy while idle");

  // frames both ways, every channel and data bit
  for (int i = 0; i < 16; i++) begin
    d = $urandom;
    h_send(4'(i), d);
    p_send(4'(15 - i), ~d);
    h_recv();
  end
  h_send(4'hF, 32'hFFFF_FFFF); h_send(4'h0, 32'h0);
  p_send(4'hF, 32'hFFFF_FFFF); p_send(4'h0, 32'h0);
  h_recv(); h_recv();
  wait_quiet();
  // STATUS while sending
  h_send(4'h5, 32'h1234_5678);
  while (!dut.u_core.tx_busy) @(negedge PCLK);
  rd(A_STATUS);
  if (rdv != 1) fail("STATUS not busy while sending");
  wait_quiet();

  // the peer's READY holds the DUT's transmitter: the core holds one frame,
  // TX another, and a third write is dropped (TX_OVF)
  p_rx_en = 0;
  h_send(4'h1, 32'h1111_0001);
  h_send(4'h2, 32'h1111_0002);
  rd(A_FLAGS);
  if (!rdv[FLAG_TX_FULL]) fail("TX not full while READY is low");
  wr(A_TX0, 32'h3); wr(A_TX1, 32'h1111_0003);
  irq_expect(IRQ_TX_OVF);
  cycles(100);
  p_rx_en = 1;
  wait_quiet();

  // the peer sends 6 frames: the core FIFO holds 4, RX one, READY holds the
  // last; reading RX pops and captures the next in one clock
  p_burst = 6;
  cycles(3000);
  rd(A_FLAGS);
  if (!rdv[FLAG_RX_AVAIL]) fail("RX empty with frames waiting");
  for (int i = 0; i < 6; i++) h_recv();
  rd_exp(A_RX1, 32'hA000_0005);                // empty: the last value, no pop
  rd(A_FLAGS);
  if (rdv[FLAG_RX_AVAIL]) fail("RX not empty");
  wait (p_burst == 0);

  // breaks both ways
  wr(A_CMD, 1);
  cycles(3);
  wait_quiet();
  if (p_brks != 1) fail($sformatf("peer saw %0d breaks", p_brks));
  @(negedge PCLK) p_brk = 1; @(negedge PCLK) p_brk = 0;
  cycles(200);
  irq_expect(IRQ_RX_BREAK);

  // receive errors from the BFM
  b_take();
  b_frame(4'h7, 32'h7777_0001, 1);
  repeat (3) b_bit(0);                         // stray zeros
  b_frame(4'h8, 32'h7777_0002, 1);
  b_bit(1); b_bit(1);
  b_d = !b_d; b_f = !b_f; cycles(40);          // both lines change, then the frame stops
  repeat (40) b_bit(0);
  h_recv(); h_recv();
  // 7 frames ignoring READY: FIFO 4 + RX 1, two dropped
  for (int i = 0; i < 7; i++) b_frame(4'(i), 32'hB000_0000 + i, i < 5);
  b_give();
  irq_expect(IRQ_ERR_STRAY); irq_expect(IRQ_ERR_DS); irq_expect(IRQ_ERR_TIMEOUT); irq_expect(IRQ_ERR_OVERFLOW);
  for (int i = 0; i < 5; i++) h_recv();
  if (p_errs != 0) fail("peer saw receive errors");

  // every interrupt: set, masked, raising irq, cleared one by one
  rd(A_IRQ_STATUS);
  if (rdv[8:0] != 9'h1FF) fail($sformatf("IRQ_STATUS %h, expected every bit", rdv));
  if (irq) fail("irq high with every bit masked");
  wr(A_IRQ_ENABLE, IRQ_ALL);
  if (!irq) fail("irq low with every bit enabled");
  for (int b = 0; b < 9; b++) begin
    wr(A_IRQ_STATUS, 1 << b);
    rd(A_IRQ_STATUS);
    if (rdv[8:0] != 9'(9'h1FF << (b + 1))) fail($sformatf("IRQ_STATUS %h after clearing bit %0d", rdv, b));
  end
  if (irq) fail("irq high with nothing pending");
  // a frame with interrupts enabled; its interrupts stay pending into the
  // final reset
  h_send(4'hA, 32'hCAFE_0001);
  wait_quiet();
  if (!irq) fail("irq low after a frame was sent");
endtask
