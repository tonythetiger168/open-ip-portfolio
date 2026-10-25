// SPDX-License-Identifier: Apache-2.0
// CAN-specific part of tb/CAN_apb_tb.sv. A second CAN_top (the peer) shares
// the bus with the DUT: bus = txd & p_txd & line. `line` disturbs the whole
// bus, `ldis` only what the DUT receives. Frames go both ways through the
// TX/RX registers; filter, overflow on both streams, pop at capture, abort,
// arbitration loss, every error kind, error passive (TEC and REC), bus-off
// and recovery, every interrupt bit masked, enabled and cleared one by one.
logic line = 1, ldis = 1;
logic p_rst = 0;
wire  p_txd;
wire  bus = txd & p_txd & line;
assign rxd = bus & ldis;

logic        p_tx_valid = 0, p_tx_ide = 0, p_tx_rtr = 0;
logic [28:0] p_tx_id = 0;
logic [3:0]  p_tx_dlc = 0;
logic [63:0] p_tx_data = 0;
wire         p_tx_ready, p_tx_done, p_rx_valid, p_rx_ide, p_rx_rtr;
wire  [28:0] p_rx_id;
wire  [3:0]  p_rx_dlc;
wire  [63:0] p_rx_data;
wire  [8:0]  p_tec;
wire  [7:0]  p_rec;
wire         p_unused_aborted, p_unused_arb, p_unused_passive, p_unused_bus_off;
wire  [4:0]  p_unused_err;

CAN_top u_peer (
  .clk(PCLK), .rst_n(PRESETN & p_rst), .rxd(bus), .txd(p_txd),
  .cfg_brp(6'd1), .cfg_tseg1(4'd5), .cfg_tseg2(3'd2), .cfg_sjw(2'd1),
  .acc_code(29'h0), .acc_mask(29'h0),
  .tx_valid(p_tx_valid), .tx_ready(p_tx_ready), .tx_id(p_tx_id), .tx_ide(p_tx_ide),
  .tx_rtr(p_tx_rtr), .tx_dlc(p_tx_dlc), .tx_data(p_tx_data), .tx_abort(1'b0),
  .tx_done(p_tx_done), .tx_aborted(p_unused_aborted),
  .rx_valid(p_rx_valid), .rx_id(p_rx_id), .rx_ide(p_rx_ide), .rx_rtr(p_rx_rtr),
  .rx_dlc(p_rx_dlc), .rx_data(p_rx_data), .arb_lost(p_unused_arb),
  .err_bit(p_unused_err[0]), .err_stuff(p_unused_err[1]), .err_crc(p_unused_err[2]),
  .err_form(p_unused_err[3]), .err_ack(p_unused_err[4]),
  .tec(p_tec), .rec(p_rec), .err_passive(p_unused_passive), .bus_off(p_unused_bus_off));

localparam int BT = 20;                     // clocks per bit with the reset BTR
task automatic bits(input int n); cycles(n * BT); endtask

typedef struct packed {
  logic [28:0] id;
  logic        ide, rtr;
  logic [3:0]  dlc;
  logic [63:0] data;
} frame_t;

function automatic frame_t mkf(input logic [28:0] id, input logic ide, input logic rtr,
                               input logic [3:0] dlc, input logic [63:0] data);
  frame_t f;
  logic [63:0] d;
  d = rtr ? 64'h0 : data;
  // bytes past the DLC are not sent
  for (int i = 0; i < 8; i++) if (i >= dlc) d[8*i +: 8] = 8'h0;
  f.id = ide ? id : {18'h0, id[10:0]}; f.ide = ide; f.rtr = rtr; f.dlc = dlc;
  f.data = d;
  return f;
endfunction

function automatic frame_t rnd_frame;
  logic ide;
  ide = $urandom;
  return mkf({$urandom, $urandom}, ide, ($urandom % 8) == 0, $urandom, {$urandom, $urandom});
endfunction

// frames the peer received
frame_t p_last;
int     p_cnt = 0;
always @(posedge PCLK)
  if (p_rx_valid) begin
    p_last <= {p_rx_id, p_rx_ide, p_rx_rtr, p_rx_dlc, p_rx_data};
    p_cnt  <= p_cnt + 1;
  end

// peer transmit: hold valid until the peer takes the frame
task automatic p_queue(input frame_t f);
  @(negedge PCLK);
  {p_tx_id, p_tx_ide, p_tx_rtr, p_tx_dlc, p_tx_data} = f;
  p_tx_valid = 1;
  @(posedge PCLK);
  while (!p_tx_ready) @(posedge PCLK);
  @(negedge PCLK) p_tx_valid = 0;
endtask
task automatic p_wait_done;
  int g;
  g = 0;
  while (!p_tx_done && g < 400 * BT) begin @(posedge PCLK); g++; end
  if (!p_tx_done) fail("peer frame never sent");
  @(negedge PCLK);
endtask

// DUT transmit through TX0..TX3
task automatic d_queue(input frame_t f);
  wr(A_TX0, f.data[31:0]);
  wr(A_TX1, f.data[63:32]);
  wr(A_TX2, {1'b0, f.rtr, f.ide, f.id});
  wr(A_TX3, {28'h0, f.dlc});
endtask

localparam logic [31:0] AV = 32'h1 << FLAG_RX_AVAIL;
localparam logic [31:0] TF = 32'h1 << FLAG_TX_FULL;

task automatic rx_check(input frame_t f);
  rd_exp(A_RX0, f.data[31:0]);
  rd_exp(A_RX1, f.data[63:32]);
  rd_exp(A_RX2, {1'b0, f.rtr, f.ide, f.id});
  rd_exp(A_RX3, {28'h0, f.dlc});            // pops
endtask

// DUT -> peer
task automatic d_send(input frame_t f);
  int c;
  c = p_cnt;
  d_queue(f);
  poll(A_IRQ_STATUS, 32'h1 << IRQ_SENT, 32'h1 << IRQ_SENT, 3000);
  wr(A_IRQ_STATUS, 32'h1 << IRQ_SENT);
  @(negedge PCLK);
  if (p_cnt != c + 1 || p_last !== f) fail($sformatf("peer did not receive id %h", f.id));
endtask

// peer -> DUT
task automatic p_send(input frame_t f);
  p_queue(f);
  p_wait_done();
  poll(A_FLAGS, AV, AV, 100);
  rx_check(f);
endtask

task automatic status_exp(input int tec, input int rec);
  rd(A_STATUS);
  if (rdv[8:0] != tec[8:0] || rdv[16:9] != rec[7:0])
    fail($sformatf("TEC/REC %0d/%0d, expected %0d/%0d", rdv[8:0], rdv[16:9], tec, rec));
endtask

// wait (at a negedge) until the DUT's next sample point is de-stuffed bit p
// of the current frame
task automatic at_dut_pos(input int p, input logic tx);
  while (!(dut.u_core.mode == 2 && dut.u_core.is_tx == tx && dut.u_core.pos == p[7:0]))
    @(negedge PCLK);
endtask

// same, for bit k after the last CRC bit (1 = CRC delimiter, 2 = ACK slot)
task automatic wait_crc_k(input int k);
  while (!(dut.u_core.mode == 2 && !dut.u_core.is_tx && dut.u_core.known
           && 8'(dut.u_core.pos - dut.u_core.crc_ls) == k[7:0]))
    @(negedge PCLK);
endtask

// IRQ_STATUS must read m; then every set bit alone: enable, pin, clear
task automatic walk(input logic [31:0] m);
  rd_exp(A_IRQ_STATUS, m);
  if (irq !== 0) fail("irq with all interrupts masked");
  for (int i = 0; i < 14; i++)
    if (m[i]) begin
      wr(A_IRQ_ENABLE, 32'h1 << i);
      if (irq !== 1) fail($sformatf("irq bit %0d does not reach the pin", i));
      wr(A_IRQ_STATUS, 32'h1 << i);
      if (irq !== 0) fail($sformatf("irq bit %0d not cleared", i));
    end
  wr(A_IRQ_ENABLE, 0);
  rd_exp(A_IRQ_STATUS, 0);
endtask

task automatic ip_func;
  frame_t f, g;
  int c;
  @(negedge PCLK) p_rst = 1;
  bits(12);
  rd_exp(A_RX3, 0);                         // empty: reads the reset value, no pop
  // ---- phase A, all interrupts masked
  // both directions, base/extended, data/remote, DLC 0..15
  d_send(mkf(29'h123, 0, 0, 8, 64'h0807_0605_0403_0201));
  p_send(mkf(29'h1ABC_DEF0, 1, 0, 8, 64'hFFFF_FFFF_FFFF_FFFF));
  d_send(mkf(29'h1FFF_FFFF, 1, 1, 15, 0));
  p_send(mkf(29'h7FF, 0, 1, 4, 0));
  for (int i = 0; i < 24; i++) begin
    d_send(rnd_frame());
    p_send(rnd_frame());
  end
  p_send(mkf(29'h0, 0, 0, 0, 0));
  p_send(mkf(29'h0, 1, 0, 0, 0));

  // acceptance filter: only id 0x123 with the base-ID mask
  wr(A_ACC_CODE, 29'h123);
  wr(A_ACC_MASK, 29'h7FF);
  p_queue(mkf(29'h124, 0, 0, 1, 64'h11));
  p_wait_done();
  bits(2);
  rd_exp(A_FLAGS, 0);
  p_send(mkf(29'h123, 0, 0, 1, 64'h22));
  wr(A_ACC_MASK, 0);
  wr(A_ACC_CODE, 0);

  // TX overflow: the core takes A, B waits in TX0..TX3, C is dropped
  wr(A_IRQ_STATUS, IRQ_ALL);
  f = rnd_frame(); g = rnd_frame();
  c = p_cnt;
  d_queue(f);
  d_queue(g);
  rd_exp(A_FLAGS, TF);
  d_queue(mkf(29'h5A5, 0, 0, 2, 64'hBAD));
  poll(A_FLAGS, TF, 0, 3000);
  poll(A_IRQ_STATUS, 32'h1 << IRQ_TX_OVF, 32'h1 << IRQ_TX_OVF, 10);
  while (p_cnt < c + 2) @(negedge PCLK);
  @(negedge PCLK);
  if (p_last !== g) fail("second queued frame");
  bits(4);
  if (p_cnt != c + 2) fail("overflowed frame was sent");
  walk(32'h1 << IRQ_SENT | 32'h1 << IRQ_TX_DONE | 32'h1 << IRQ_TX_OVF);

  // RX overflow: two frames arrive, none read; the second is dropped
  wr(A_IRQ_STATUS, IRQ_ALL);
  f = rnd_frame(); g = rnd_frame();
  p_queue(f); p_wait_done();
  p_queue(g); p_wait_done();
  walk(32'h1 << IRQ_RX_OVF | 32'h1 << IRQ_RX_AVAIL);
  rx_check(f);
  rd_exp(A_FLAGS, 0);

  // pop RX3 in the very clock the next frame is captured
  f = rnd_frame(); g = rnd_frame();
  p_queue(f); p_wait_done();
  poll(A_FLAGS, AV, AV, 10);
  wr(A_IRQ_STATUS, IRQ_ALL);
  rd_exp(A_RX0, f.data[31:0]);
  p_queue(g);
  while (!(dut.u_core.sample && dut.u_core.mode == 2 && !dut.u_core.is_tx && dut.u_core.known
           && 8'(dut.u_core.pos - dut.u_core.crc_ls) == 8'd9))
    @(negedge PCLK);
  apb_now(0, A_RX3, 0, 0);                  // access phase sees rx_valid
  if (rdv !== {28'h0, f.dlc}) fail("pop at capture: first frame");
  rd_exp(A_FLAGS, AV);
  walk(32'h1 << IRQ_RX_AVAIL);
  rx_check(g);
  bits(4);                                  // the peer's EOF and intermission

  // abort: queued while the peer sends, dropped before it starts
  f = mkf(29'h0AA, 0, 0, 8, 64'h1);
  p_queue(f);
  bits(10);
  c = p_cnt;
  d_queue(mkf(29'h0BB, 0, 0, 1, 64'h2));
  wr(A_CMD, 1);
  poll(A_IRQ_STATUS, 32'h1 << IRQ_ABORTED, 32'h1 << IRQ_ABORTED, 10);
  p_wait_done();
  rx_check(f);
  bits(20);
  if (p_cnt != c) fail("aborted frame was sent");
  walk(32'h1 << IRQ_ABORTED | 32'h1 << IRQ_TX_DONE | 32'h1 << IRQ_RX_AVAIL);
  // too late: the frame is on the bus already, it completes
  f = mkf(29'h0CC, 0, 0, 8, 64'h3);
  d_queue(f);
  at_dut_pos(5, 1);
  wr(A_CMD, 1);
  poll(A_IRQ_STATUS, 32'h1 << IRQ_SENT, 32'h1 << IRQ_SENT, 3000);
  if (p_last !== f) fail("late abort dropped the frame");
  rd(A_IRQ_STATUS);
  bits(4);

  // arbitration: both start after the peer's first frame, the peer's lower ID wins
  wr(A_IRQ_STATUS, IRQ_ALL);
  f = mkf(29'h300, 0, 0, 2, 64'h33);
  g = mkf(29'h050, 0, 0, 2, 64'h55);
  p_queue(mkf(29'h100, 0, 0, 8, 64'h1));
  bits(10);
  d_queue(f);
  p_queue(g);                               // taken at the peer's tx_done
  rx_check(mkf(29'h100, 0, 0, 8, 64'h1));
  p_wait_done();
  walk(32'h1 << IRQ_ARB_LOST | 32'h1 << IRQ_RX_AVAIL | 32'h1 << IRQ_TX_DONE);
  rx_check(g);
  poll(A_IRQ_STATUS, 32'h1 << IRQ_SENT, 32'h1 << IRQ_SENT, 3000);
  if (p_last !== f) fail("frame after lost arbitration");
  status_exp(0, 0);

  // ---- errors
  wr(A_IRQ_STATUS, IRQ_ALL);
  // bit error: transmitter reads dominant on recessive data bit 0
  d_queue(mkf(29'h2F0, 0, 0, 8, 64'hFFFF_FFFF_FFFF_FFFF));
  at_dut_pos(19, 1);
  line = 0; cycles(BT); line = 1;
  poll(A_IRQ_STATUS, 32'h1 << IRQ_SENT, 32'h1 << IRQ_SENT, 3000);
  walk(32'h1 << IRQ_SENT | 32'h1 << IRQ_ERR_BIT | 32'h1 << IRQ_TX_DONE);
  status_exp(7, 0);
  for (int i = 0; i < 7; i++) d_send(rnd_frame());
  status_exp(0, 0);
  wr(A_IRQ_STATUS, IRQ_ALL);

  // stuff error at the receiver: six dominant bits in 0xFF data
  f = mkf(29'h2F1, 0, 0, 8, 64'hFFFF_FFFF_FFFF_FFFF);
  p_queue(f);
  at_dut_pos(20, 0);
  line = 0; cycles(7 * BT); line = 1;
  p_wait_done();
  rx_check(f);
  walk(32'h1 << IRQ_ERR_STUFF | 32'h1 << IRQ_RX_AVAIL);

  // CRC error: data bit 3 of 0x55 flipped at the DUT only; the TB gives the
  // ACK the DUT holds back, so the error shows after the ACK delimiter
  f = mkf(29'h555, 0, 0, 8, 64'h5555_5555_5555_5555);
  p_queue(f);
  at_dut_pos(22, 0);
  ldis = 0; cycles(BT); ldis = 1;
  wait_crc_k(2);
  line = 0; cycles(BT); line = 1;
  p_wait_done();
  rx_check(f);
  walk(32'h1 << IRQ_ERR_CRC | 32'h1 << IRQ_RX_AVAIL);

  // form error: dominant CRC delimiter at the DUT only
  f = mkf(29'h3C3, 0, 0, 1, 64'h5A);
  p_queue(f);
  wait_crc_k(1);
  ldis = 0; cycles(BT); ldis = 1;
  p_wait_done();
  rx_check(f);
  walk(32'h1 << IRQ_ERR_FORM | 32'h1 << IRQ_RX_AVAIL);

  // ACK errors with the peer in reset: TEC +8 up to error passive
  @(negedge PCLK) p_rst = 0;
  f = mkf(29'h0AC, 0, 0, 1, 64'hAC);
  d_queue(f);
  poll(A_STATUS, 32'h1 << 17, 32'h1 << 17, 20000);
  rd_exp(A_IRQ_STATUS, 32'h1 << IRQ_ERR_ACK | 32'h1 << IRQ_ERR_PASSIVE | 32'h1 << IRQ_TX_DONE);
  rd_exp(A_STATUS, 32'h1 << 17 | 128);
  bits(200);                                // passive ACK errors: TEC stays
  rd_exp(A_STATUS, 32'h1 << 17 | 128);
  @(negedge PCLK) p_rst = 1;
  poll(A_IRQ_STATUS, 32'h1 << IRQ_SENT, 32'h1 << IRQ_SENT, 3000);
  if (p_last !== f) fail("frame after error passive");
  rd_exp(A_STATUS, 127);
  walk(32'h1 << IRQ_SENT | 32'h1 << IRQ_ERR_ACK | 32'h1 << IRQ_ERR_PASSIVE | 32'h1 << IRQ_TX_DONE);

  // bus-off: bit errors until TEC passes 255, then 128 x 11 recessive bits
  f = mkf(29'h2F2, 0, 0, 8, 64'hFFFF_FFFF_FFFF_FFFF);
  d_queue(f);
  for (int i = 0; i < 20 && dut.u_core.mode != 7; i++) begin
    at_dut_pos(19, 1);
    line = 0; cycles(BT); line = 1;
    bits(2);
  end
  rd(A_STATUS);
  if (rdv[18] !== 1'b1 || rdv[8:0] < 256) fail($sformatf("no bus-off (%h)", rdv));
  poll(A_IRQ_STATUS, 32'h1 << IRQ_SENT, 32'h1 << IRQ_SENT, 30000);
  if (p_last !== f) fail("frame after bus-off recovery");
  rd(A_STATUS);
  if (rdv[18:17] !== 2'b00 || rdv[8:0] != 0) fail($sformatf("after recovery %h", rdv));
  walk(32'h1 << IRQ_SENT | 32'h1 << IRQ_ERR_BIT | 32'h1 << IRQ_ERR_PASSIVE
       | 32'h1 << IRQ_BUS_OFF | 32'h1 << IRQ_TX_DONE);

  // REC above 127: dominant glitches with the peer in reset look like SOFs
  // followed by a stuff error
  @(negedge PCLK) p_rst = 0;
  for (int i = 0; i < 130; i++) begin
    ldis = 0; cycles(BT); ldis = 1;
    bits(30);
  end
  rd_exp(A_STATUS, 32'h1 << 17 | 130 << 9);
  @(negedge PCLK) p_rst = 1;
  p_send(mkf(29'h44, 0, 0, 1, 64'h4));
  rd_exp(A_STATUS, 120 << 9);
  walk(32'h1 << IRQ_ERR_STUFF | 32'h1 << IRQ_ERR_PASSIVE | 32'h1 << IRQ_RX_AVAIL);

  // ---- phase B, all enabled
  wr(A_IRQ_STATUS, IRQ_ALL);
  wr(A_IRQ_ENABLE, IRQ_ALL);
  for (int i = 0; i < 6; i++) begin
    d_send(rnd_frame());
    if (irq !== 1) fail("irq after a sent frame");
    wr(A_IRQ_STATUS, IRQ_ALL);
    p_send(rnd_frame());
    if (irq !== 1) fail("irq after a received frame");
    wr(A_IRQ_STATUS, IRQ_ALL);
    if (irq !== 0) fail("irq after W1C");
  end
  // a received frame stays pending into the final reset
  p_queue(rnd_frame()); p_wait_done();
endtask
`ifdef CAN_DBG
always @(posedge PCLK) begin
  if (u_peer.tx_done) $display("%0t P tx_done %h", $time, u_peer.b_id);
  if (u_peer.arb_lost) $display("%0t P arb_lost", $time);
  if (p_rx_valid) $display("%0t P rx %h", $time, p_rx_id);
  if (|p_unused_err) $display("%0t P err %b", $time, p_unused_err);
  if (dut.u_core.tx_done) $display("%0t D tx_done %h", $time, dut.u_core.b_id);
  if (dut.u_core.arb_lost) $display("%0t D arb_lost", $time);
  if (dut.u_core.rx_valid) $display("%0t D rx %h", $time, dut.u_core.rx_id);
  if (dut.u_core.tx_valid && dut.u_core.tx_ready) $display("%0t D accept %h", $time, dut.u_core.tx_id);
  if (p_tx_valid && p_tx_ready) $display("%0t P accept %h", $time, p_tx_id);
  if (dut.u_core.err_bit|dut.u_core.err_stuff|dut.u_core.err_crc|dut.u_core.err_form|dut.u_core.err_ack)
    $display("%0t D err %b%b%b%b%b", $time, dut.u_core.err_bit,dut.u_core.err_stuff,dut.u_core.err_crc,dut.u_core.err_form,dut.u_core.err_ack);
end
`endif
