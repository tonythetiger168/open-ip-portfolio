// SPDX-License-Identifier: Apache-2.0
// CAN XL-specific part of tb/CAN_XL_apb_tb.sv. A second CAN_XL_top (the
// peer, 2048-byte buffers) shares the bus with the DUT: bus = txd & p_txd &
// line. `line` disturbs the whole bus, `ldis` only what the DUT receives.
// CC and XL frames go both ways through TX_* / RX_* and the BUF words;
// filter, refused and truncated frames, abort, arbitration loss, every
// error kind, a protocol exception (a CAN FD frame bit-banged on the line),
// error passive (TEC and REC), bus-off and recovery, and every interrupt bit
// masked, enabled and cleared one by one.
logic line = 1, ldis = 1;
logic p_rst = 0;
wire  p_txd;
wire  bus = txd & p_txd & line;
assign rxd = bus & ldis;

typedef struct packed {
  logic        xl;
  logic [28:0] id;
  logic        ide, rtr;
  logic [10:0] dlc;
  logic [7:0]  sdt;
  logic        sec;
  logic [7:0]  vcid;
  logic [31:0] af;
} hdr_t;

logic        p_tx_valid = 0, p_hb_wen = 0;
logic [8:0]  p_hb_waddr = 0, p_hb_raddr = 0;
logic [31:0] p_hb_wdata = 0;
wire  [31:0] p_hb_rdata;
hdr_t        p_th = '0, p_rh;
wire         p_tx_ready, p_tx_done, p_rx_valid, p_rx_trunc;
wire         p_unused_fast, p_unused_rfast, p_unused_ab, p_unused_rej, p_unused_arb, p_unused_pexc;
wire  [4:0]  p_unused_err;
wire  [8:0]  p_tec;
wire  [7:0]  p_rec;
wire         p_unused_passive, p_unused_bus_off;

CAN_XL_top #(.MAX_BYTES(2048)) u_peer (
  .clk(PCLK), .rst_n(PRESETN & p_rst), .rxd(bus), .txd(p_txd),
  .tx_fast(p_unused_fast), .rx_fast(p_unused_rfast),
  .cfg_brp(6'd1), .cfg_tseg1(4'd5), .cfg_tseg2(3'd2), .cfg_sjw(2'd1),
  .cfg_dbrp(6'd0), .cfg_dtseg1(4'd3), .cfg_dtseg2(3'd1), .cfg_dsjw(2'd0),
  .acc_code(29'h0), .acc_mask(29'h0),
  .hb_wen(p_hb_wen), .hb_waddr(p_hb_waddr), .hb_wdata(p_hb_wdata), .hb_raddr(p_hb_raddr),
  .hb_rdata(p_hb_rdata),
  .tx_valid(p_tx_valid), .tx_ready(p_tx_ready), .tx_xl(p_th.xl), .tx_id(p_th.id), .tx_ide(p_th.ide),
  .tx_rtr(p_th.rtr), .tx_dlc(p_th.dlc), .tx_sdt(p_th.sdt), .tx_sec(p_th.sec), .tx_vcid(p_th.vcid),
  .tx_af(p_th.af), .tx_abort(1'b0), .tx_done(p_tx_done), .tx_aborted(p_unused_ab),
  .tx_rejected(p_unused_rej),
  .rx_valid(p_rx_valid), .rx_xl(p_rh.xl), .rx_id(p_rh.id), .rx_ide(p_rh.ide), .rx_rtr(p_rh.rtr),
  .rx_dlc(p_rh.dlc), .rx_sdt(p_rh.sdt), .rx_sec(p_rh.sec), .rx_vcid(p_rh.vcid), .rx_af(p_rh.af),
  .rx_trunc(p_rx_trunc), .arb_lost(p_unused_arb),
  .err_bit(p_unused_err[0]), .err_stuff(p_unused_err[1]), .err_crc(p_unused_err[2]),
  .err_form(p_unused_err[3]), .err_ack(p_unused_err[4]), .pexc(p_unused_pexc),
  .tec(p_tec), .rec(p_rec), .err_passive(p_unused_passive), .bus_off(p_unused_bus_off));

localparam int BT = 20;                     // clocks per nominal bit with the reset NBTR
localparam int DMAX = 64;                   // the DUT's buffer
task automatic bits(input int n); for (int i = 0; i < n * BT; i++) @(negedge PCLK); endtask

function automatic int nbytes(input hdr_t h);
  if (h.xl) return int'(h.dlc) + 1;
  if (h.rtr) return 0;
  return h.dlc[3:0] > 8 ? 8 : int'(h.dlc[3:0]);
endfunction
// the header as a receiver reports it
function automatic hdr_t norm(input hdr_t h);
  hdr_t g;
  g = h;
  if (g.xl) begin g.id = {18'h0, h.id[10:0]}; g.ide = 0; g.rtr = 0; end
  else begin
    if (!g.ide) g.id = {18'h0, h.id[10:0]};
    g.dlc = {7'h0, h.dlc[3:0]}; g.sdt = 0; g.sec = 0; g.vcid = 0; g.af = 0;
  end
  return g;
endfunction
function automatic hdr_t mk_cc(input logic [28:0] id, input bit ide, input bit rtr, input int dlc);
  hdr_t h;
  h = '0; h.id = id; h.ide = ide; h.rtr = rtr; h.dlc = 11'(dlc);
  return h;
endfunction
function automatic hdr_t mk_xl(input logic [10:0] id, input int nb, input logic [7:0] sdt = 8'h01,
                               input logic [7:0] vcid = 8'h00, input logic [31:0] af = 32'h0,
                               input bit sec = 0);
  hdr_t h;
  h = '0; h.xl = 1; h.id = {18'h0, id}; h.dlc = 11'(nb - 1); h.sdt = sdt; h.vcid = vcid; h.af = af;
  h.sec = sec;
  return h;
endfunction
function automatic hdr_t rnd_cc();
  hdr_t h;
  h = '0; h.ide = $urandom_range(1); h.rtr = $urandom_range(3) == 0;
  h.id = h.ide ? 29'($urandom) : {18'h0, 11'($urandom)};
  h.dlc = 11'($urandom_range(15));
  return h;
endfunction
function automatic hdr_t rnd_xl(input int maxb);
  return mk_xl(11'($urandom), $urandom_range(1, maxb), 8'($urandom), 8'($urandom), $urandom,
               $urandom_range(1));
endfunction

// payload bytes: kind 0 random, 1 zeros, 2 ones, 3 count
logic [7:0] fd [0:2047];
task automatic fill(input int kind);
  for (int i = 0; i < 2048; i++)
    case (kind)
      1: fd[i] = 8'h00;
      2: fd[i] = 8'hFF;
      3: fd[i] = 8'(i);
      default: fd[i] = 8'($urandom);
    endcase
endtask

// what the peer received
hdr_t       p_last;
logic [7:0] p_rd [0:2047];
int         p_cnt = 0;
always @(posedge PCLK)
  if (PRESETN && p_rx_valid) begin
    #1;
    p_last = p_rh; p_cnt++;
    for (int w = 0; w < 512; w++) begin
      p_hb_raddr = 9'(w); #0.01;
      for (int i = 0; i < 4; i++) p_rd[4 * w + i] = p_hb_rdata[8 * i +: 8];
    end
  end

// ---- peer transmit: buffer through its host port, then tx_valid
task automatic p_queue(input hdr_t h);
  @(negedge PCLK);
  while (!p_tx_ready) @(negedge PCLK);
  for (int w = 0; w < (nbytes(h) + 3) / 4; w++) begin
    p_hb_wen = 1; p_hb_waddr = 9'(w);
    p_hb_wdata = {fd[4 * w + 3], fd[4 * w + 2], fd[4 * w + 1], fd[4 * w]};
    @(negedge PCLK);
  end
  p_hb_wen = 0;
  p_th = h; p_tx_valid = 1;
  @(negedge PCLK);
  p_tx_valid = 0;
endtask
task automatic p_wait_done;
  int g;
  g = 0;
  while (!p_tx_done && g < 30000 * BT) begin @(posedge PCLK); g++; end
  if (!p_tx_done) fail("peer frame never sent");
  @(negedge PCLK);
endtask

// ---- DUT transmit through BUF / TX_ID / TX_CTRL / TX_AF / CMD
task automatic d_hdr(input hdr_t h);
  wr(A_TX_ID, {h.xl, h.rtr, h.ide, h.id});
  wr(A_TX_CTRL, {4'h0, h.vcid, h.sec, h.sdt, h.dlc});
  wr(A_TX_AF, h.af);
endtask
task automatic d_queue(input hdr_t h);
  int nb;
  nb = nbytes(h);
  for (int w = 0; w < (nb + 3) / 4 && w < DMAX / 4; w++)
    wr(A_BUF0 + 12'(4 * w), {fd[4 * w + 3], fd[4 * w + 2], fd[4 * w + 1], fd[4 * w]});
  d_hdr(h);
  wr(A_CMD, 1);
endtask
// the peer must have received h with the bytes in fd
task automatic p_check(input hdr_t h, input int c);
  bit bad;
  if (p_cnt != c + 1 || p_last !== norm(h)) fail($sformatf("peer did not receive id %h", h.id));
  else begin
    bad = 0;
    for (int i = 0; i < nbytes(h) && !bad; i++)
      if (p_rd[i] !== fd[i]) begin fail($sformatf("peer byte %0d = %h, expected %h", i, p_rd[i], fd[i])); bad = 1; end
  end
endtask
task automatic d_send(input hdr_t h);
  int c;
  c = p_cnt;
  d_queue(h);
  poll(A_IRQ_STATUS, 32'h1 << IRQ_SENT, 32'h1 << IRQ_SENT, 3000);
  wr(A_IRQ_STATUS, 32'h1 << IRQ_SENT);
  @(negedge PCLK);
  p_check(h, c);
endtask

// ---- DUT receive: header registers and BUF words
task automatic rx_check(input hdr_t h);
  hdr_t g;
  int nb;
  g = norm(h);
  nb = nbytes(h);
  rd_exp(A_RX_ID, {g.xl, g.rtr, g.ide, g.id});
  rd_exp(A_RX_CTRL, {3'h0, g.xl && nb > DMAX, g.vcid, g.sec, g.sdt, g.dlc});
  rd_exp(A_RX_AF, g.af);
  for (int w = 0; w < (nb + 3) / 4 && w < DMAX / 4; w++) begin
    rd(A_BUF0 + 12'(4 * w));
    for (int i = 0; i < 4; i++)
      if (4 * w + i < nb && rdv[8 * i +: 8] !== fd[4 * w + i])
        fail($sformatf("received byte %0d = %h, expected %h", 4 * w + i, rdv[8 * i +: 8], fd[4 * w + i]));
  end
endtask
task automatic p_send(input hdr_t h);
  p_queue(h);
  p_wait_done();
  poll(A_IRQ_STATUS, 32'h1 << IRQ_RX, 32'h1 << IRQ_RX, 100);
  rx_check(h);
  wr(A_IRQ_STATUS, 32'h1 << IRQ_RX);
endtask

task automatic status_exp(input int tec, input int rec);
  rd(A_STATUS);
  if (rdv[9:1] != tec[8:0] || rdv[17:10] != rec[7:0])
    fail($sformatf("TEC/REC %0d/%0d, expected %0d/%0d", rdv[9:1], rdv[17:10], tec, rec));
endtask

// wait (at a negedge) until the DUT's next sample point is de-stuffed bit p
// of the current frame
task automatic at_dut_pos(input int p, input logic tx);
  while (!(dut.u_core.mode == 2 && dut.u_core.is_tx == tx && dut.u_core.pos == p[14:0]))
    @(negedge PCLK);
endtask
// same, for bit k after the last body bit (1 = CRC delimiter / DAH, 2 = ACK slot)
task automatic wait_k(input int k);
  while (!(dut.u_core.mode == 2 && !dut.u_core.is_tx && dut.u_core.body_last != 15'h7FF0
           && dut.u_core.k == k[14:0]))
    @(negedge PCLK);
endtask

// IRQ_STATUS must read m; then every set bit alone: enable, pin, clear
task automatic walk(input logic [31:0] m);
  rd_exp(A_IRQ_STATUS, m);
  if (irq !== 0) fail("irq with all interrupts masked");
  for (int i = 0; i < 13; i++)
    if (m[i]) begin
      wr(A_IRQ_ENABLE, 32'h1 << i);
      if (irq !== 1) fail($sformatf("irq bit %0d does not reach the pin", i));
      wr(A_IRQ_STATUS, 32'h1 << i);
      if (irq !== 0) fail($sformatf("irq bit %0d not cleared", i));
    end
  wr(A_IRQ_ENABLE, 0);
  rd_exp(A_IRQ_STATUS, 0);
endtask

// a CAN FD start on the line: SOF, ID 0x555, RRS, IDE, FDF = 1, res = 0,
// then 12 recessive bits
task automatic fd_frame;
  logic [16:0] s;
  s = {1'b0, 11'h555, 1'b0, 1'b0, 1'b1, 1'b0, 1'b1};
  for (int i = 16; i >= 0; i--) begin line = s[i]; bits(1); end
  line = 1;
  bits(12);
endtask

task automatic ip_func;
  hdr_t h, g;
  int c;
  @(negedge PCLK) p_rst = 1;
  bits(12);
  rd_exp(A_FLAGS, 0);                       // no stream registers
  apb(1, A_BUF0, 32'h1234_5678, 4'h3);      // BUF takes whole words only
  if (!rerr) fail("no PSLVERR on a partial BUF write");
  // ---- phase A, all interrupts masked
  // both directions: CC base/extended, data/remote; XL lengths and field corners
  fill(3); d_send(mk_cc(29'h123, 0, 0, 8));
  fill(2); p_send(mk_cc(29'h1FFF_FFFF, 1, 0, 8));
  fill(1); p_send(mk_cc(29'h0, 1, 1, 0));
  d_send(mk_cc(29'h1FFF_FFFF, 1, 1, 15));
  fill(2); p_send(mk_xl(11'h7FF, 64, 8'hFF, 8'hFF, 32'hFFFF_FFFF, 1));
  fill(1); p_send(mk_xl(11'h000, 1, 8'h00, 8'h00, 32'h0, 0));
  fill(2); d_send(mk_xl(11'h7FF, 64, 8'hFF, 8'hFF, 32'hFFFF_FFFF, 1));
  fill(1); d_send(mk_xl(11'h000, 1, 8'h00, 8'h00, 32'h0, 0));
  for (int i = 0; i < 8; i++) begin
    fill(0);
    d_send(i % 2 ? rnd_cc() : rnd_xl(DMAX));
    p_send(i % 2 ? rnd_xl(DMAX) : rnd_cc());
  end
  // longer than the DUT's buffer: delivered cut at 64 bytes (RX_CTRL.trunc)
  fill(3); p_send(mk_xl(11'h2A5, 2048, 8'h5A, 8'hA5, 32'h1234_5678, 0));
  fill(0); p_send(mk_xl(11'h2A6, 65));
  rd_exp(A_STATUS, 1);

  // acceptance filter: only XL priority ID 0x123
  wr(A_ACC_CODE, 29'h123);
  wr(A_ACC_MASK, 29'h7FF);
  p_queue(mk_xl(11'h124, 4)); p_wait_done();
  bits(2);
  rd_exp(A_IRQ_STATUS, 0);
  p_send(mk_xl(11'h123, 4));
  wr(A_ACC_MASK, 0);
  wr(A_ACC_CODE, 0);

  // refused: an XL frame longer than the buffer
  d_hdr(mk_xl(11'h010, 65));
  wr(A_CMD, 1);
  rd_exp(A_STATUS, 1);
  walk(32'h1 << IRQ_REFUSED);

  // abort: queued while the peer sends, dropped before it starts
  fill(0);
  h = mk_cc(29'h0AA, 0, 0, 8);
  p_queue(h);
  bits(10);
  c = p_cnt;
  d_queue(mk_cc(29'h0BB, 0, 0, 1));
  wr(A_CMD, 2);
  poll(A_IRQ_STATUS, 32'h1 << IRQ_ABORTED, 32'h1 << IRQ_ABORTED, 10);
  p_wait_done();
  rx_check(h);
  bits(20);
  if (p_cnt != c) fail("aborted frame was sent");
  walk(32'h1 << IRQ_ABORTED | 32'h1 << IRQ_RX);
  // too late: the frame is on the bus already, it completes
  h = mk_xl(11'h0CC, 8);
  c = p_cnt;
  d_queue(h);
  at_dut_pos(5, 1);
  wr(A_CMD, 2);
  poll(A_IRQ_STATUS, 32'h1 << IRQ_SENT, 32'h1 << IRQ_SENT, 3000);
  @(negedge PCLK);
  p_check(h, c);
  walk(32'h1 << IRQ_SENT);

  // arbitration: both queued during the peer's first frame, the peer's lower ID wins
  h = mk_xl(11'h300, 2);
  g = mk_xl(11'h050, 2);
  fill(0);
  p_queue(mk_cc(29'h100, 0, 0, 8));
  bits(10);
  d_queue(h);
  p_queue(g);                               // taken at the peer's tx_done
  rx_check(mk_cc(29'h100, 0, 0, 8));
  p_wait_done();
  walk(32'h1 << IRQ_ARB_LOST | 32'h1 << IRQ_RX);
  rx_check(g);
  c = p_cnt;
  poll(A_IRQ_STATUS, 32'h1 << IRQ_SENT, 32'h1 << IRQ_SENT, 3000);
  @(negedge PCLK);
  p_check(h, c);
  status_exp(0, 0);
  wr(A_IRQ_STATUS, IRQ_ALL);

  // ---- errors
  // bit error: the transmitter reads dominant on the recessive ADH bit
  fill(2);
  h = mk_xl(11'h2F0, 8);
  c = p_cnt;
  d_queue(h);
  at_dut_pos(17, 1);
  line = 0; bits(1); line = 1;
  poll(A_IRQ_STATUS, 32'h1 << IRQ_SENT, 32'h1 << IRQ_SENT, 3000);
  @(negedge PCLK);
  p_check(h, c);
  walk(32'h1 << IRQ_SENT | 32'h1 << IRQ_ERR_BIT | 32'h1 << IRQ_ERR_FORM);
  status_exp(7, 0);
  for (int i = 0; i < 7; i++) begin fill(0); d_send(rnd_cc()); end
  status_exp(0, 0);
  wr(A_IRQ_STATUS, IRQ_ALL);

  // stuff error at the receiver: six dominant bits in 0xFF CC data
  fill(2);
  h = mk_cc(29'h2F1, 0, 0, 8);
  p_queue(h);
  at_dut_pos(20, 0);
  line = 0; bits(7); line = 1;
  p_wait_done();
  rx_check(h);
  walk(32'h1 << IRQ_ERR_STUFF | 32'h1 << IRQ_RX);

  // CRC error: an ID bit of an XL frame flipped at the DUT only, so its
  // PCRC fails after the PCRC field
  fill(0);
  h = mk_xl(11'h555, 4);
  p_queue(h);
  at_dut_pos(3, 0);
  ldis = 0; bits(1); ldis = 1;
  p_wait_done();
  rx_check(h);
  walk(32'h1 << IRQ_ERR_CRC | 32'h1 << IRQ_RX);

  // form error: dominant DAH at the DUT only
  h = mk_xl(11'h3C3, 2);
  p_queue(h);
  wait_k(1);
  ldis = 0; bits(1); ldis = 1;
  p_wait_done();
  rx_check(h);
  walk(32'h1 << IRQ_ERR_FORM | 32'h1 << IRQ_RX);

  // protocol exception: a CAN FD frame
  fd_frame();
  walk(32'h1 << IRQ_PEXC);
  status_exp(0, 0);

  // ACK errors with the peer in reset: TEC +8 up to error passive
  @(negedge PCLK) p_rst = 0;
  h = mk_xl(11'h0AC, 3);
  d_queue(h);
  poll(A_STATUS, 32'h1 << 18, 32'h1 << 18, 20000);
  rd_exp(A_IRQ_STATUS, 32'h1 << IRQ_ERR_ACK | 32'h1 << IRQ_ERR_PASSIVE);
  rd_exp(A_STATUS, 32'h1 << 18 | 128 << 1);
  bits(200);                                // passive ACK errors: TEC stays
  rd_exp(A_STATUS, 32'h1 << 18 | 128 << 1);
  c = p_cnt;
  @(negedge PCLK) p_rst = 1;
  poll(A_IRQ_STATUS, 32'h1 << IRQ_SENT, 32'h1 << IRQ_SENT, 3000);
  @(negedge PCLK);
  p_check(h, c);
  rd_exp(A_STATUS, 1 | 127 << 1);
  walk(32'h1 << IRQ_SENT | 32'h1 << IRQ_ERR_ACK | 32'h1 << IRQ_ERR_PASSIVE);

  // bus-off: bit errors until TEC passes 255, then 128 x 11 recessive bits
  fill(2);
  h = mk_xl(11'h2F2, 8);
  c = p_cnt;
  d_queue(h);
  for (int i = 0; i < 20 && dut.u_core.mode != 7; i++) begin
    at_dut_pos(17, 1);
    line = 0; bits(1); line = 1;
    bits(2);
  end
  rd(A_STATUS);
  if (rdv[19] !== 1'b1 || rdv[9:1] < 256) fail($sformatf("no bus-off (%h)", rdv));
  poll(A_IRQ_STATUS, 32'h1 << IRQ_SENT, 32'h1 << IRQ_SENT, 30000);
  @(negedge PCLK);
  p_check(h, c);
  rd(A_STATUS);
  if (rdv[19:18] !== 2'b00 || rdv[9:1] != 0) fail($sformatf("after recovery %h", rdv));
  walk(32'h1 << IRQ_SENT | 32'h1 << IRQ_ERR_BIT | 32'h1 << IRQ_ERR_FORM | 32'h1 << IRQ_ERR_PASSIVE
       | 32'h1 << IRQ_BUS_OFF);

  // REC above 127: dominant glitches with the peer in reset look like SOFs
  // followed by a stuff error
  @(negedge PCLK) p_rst = 0;
  for (int i = 0; i < 130; i++) begin
    ldis = 0; bits(1); ldis = 1;
    bits(30);
  end
  rd_exp(A_STATUS, 1 | 32'h1 << 18 | 130 << 10);
  @(negedge PCLK) p_rst = 1;
  bits(12);
  fill(0); p_send(mk_cc(29'h44, 0, 0, 1));
  rd_exp(A_STATUS, 1 | 120 << 10);
  walk(32'h1 << IRQ_ERR_STUFF | 32'h1 << IRQ_ERR_PASSIVE);

  // ---- phase B, all enabled
  wr(A_IRQ_STATUS, IRQ_ALL);
  wr(A_IRQ_ENABLE, IRQ_ALL);
  for (int i = 0; i < 4; i++) begin
    fill(0);
    h = rnd_xl(DMAX);
    c = p_cnt;
    d_queue(h);
    poll(A_IRQ_STATUS, 32'h1 << IRQ_SENT, 32'h1 << IRQ_SENT, 3000);
    if (irq !== 1) fail("irq after a sent frame");
    @(negedge PCLK);
    p_check(h, c);
    wr(A_IRQ_STATUS, IRQ_ALL);
    h = rnd_cc();
    p_queue(h); p_wait_done();
    poll(A_IRQ_STATUS, 32'h1 << IRQ_RX, 32'h1 << IRQ_RX, 100);
    if (irq !== 1) fail("irq after a received frame");
    rx_check(h);
    wr(A_IRQ_STATUS, IRQ_ALL);
    if (irq !== 0) fail("irq after W1C");
  end
  // a received frame stays pending into the final reset
  p_queue(rnd_xl(16)); p_wait_done();
  bits(2);
endtask
