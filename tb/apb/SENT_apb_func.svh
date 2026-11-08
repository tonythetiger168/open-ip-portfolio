// SPDX-License-Identifier: Apache-2.0
// SENT-specific part of tb/SENT_apb_tb.sv. The transmitter is looped back to
// the receiver: frames with random TX_FRAME contents (written on every frame)
// must come back in RX0 / RX1 in order, serial messages (enhanced with both
// configuration bits, short) sent with SER_TX / CMD come back in SER_RX. A
// sensor BFM on sent_in then gives frames with the largest calibration
// pulses, both holding registers' overflows and every receive error. Every
// interrupt bit is masked, enabled and cleared one by one.
logic lb = 1, bl = 1;                     // loopback, BFM line
always @* sent_in = lb ? sent_out : bl;

// frames the transmitter started, in order: {status, data masked to the nibbles}
logic [27:0] xq [$];
always @(negedge PCLK)
  if (dut.u_core.tx_frame_start)
    xq.push_back({dut.u_core.t_d & ((24'd1 << (4 * dut.u_core.t_n)) - 24'd1), dut.u_core.t_st});
// serial messages expected: {cfg, enh} in [1:0] as SER_RX lays them out
logic [25:0] sq [$];
int n_rx = 0, n_ser = 0;

task automatic irq_bit(input int b, input string what);
  rd(A_IRQ_STATUS);
  if (!rdv[b]) fail($sformatf("IRQ %s not set", what));
  wr(A_IRQ_ENABLE, 0);
  @(negedge PCLK); if (irq !== 0) fail($sformatf("irq with IRQ_ENABLE = 0 (%s)", what));
  wr(A_IRQ_ENABLE, 32'd1 << b);
  @(negedge PCLK); if (irq !== 1) fail($sformatf("irq not raised by %s", what));
  wr(A_IRQ_STATUS, 32'd1 << b);
  wr(A_IRQ_ENABLE, 0);
  rd(A_IRQ_STATUS); if (rdv[b]) fail($sformatf("IRQ %s not cleared", what));
endtask

// take the next received frame and compare it with the transmitted one
task automatic rx_take(input logic [18:0] cal);
  logic [27:0] e;
  poll(A_FLAGS, 32'h1, 32'h1, 20000);
  rd(A_RX0);
  e = xq.size() ? xq.pop_front() : 28'hx;
  if (rdv !== {4'h0, e}) fail($sformatf("RX0 %h, expected %h", rdv, e));
  rd_exp(A_RX1, {13'd0, cal});
  n_rx++;
endtask
// serial message waiting in SER_RX?
task automatic ser_take;
  rd(A_FLAGS);
  if (rdv[1]) begin
    rd(A_SER_RX);
    if (sq.size() == 0) fail($sformatf("unexpected SER_RX %h", rdv));
    else if (rdv !== {6'd0, sq.pop_front()}) fail($sformatf("SER_RX %h", rdv));
    n_ser++;
  end
endtask
// n looped-back frames, a new random TX_FRAME after each
task automatic serve(input int n, input logic [18:0] cal);
  for (int i = 0; i < n; i++) begin
    rx_take(cal);
    ser_take();
    wr(A_TX_FRAME, $urandom & 32'h0FFF_FFFF);
  end
endtask
task automatic ser_send(input bit enh, input bit cf, input logic [7:0] id, input logic [15:0] d);
  logic [7:0]  eid;
  logic [15:0] ed;
  eid = !enh ? {4'd0, id[3:0]} : cf ? {4'd0, id[3:0]} : id;
  ed  = !enh ? {8'd0, d[7:0]} : cf ? d : {4'd0, d[11:0]};
  wr(A_SER_TX, {6'd0, cf, enh, d, id});
  wr(A_CMD, 1);
  rd_exp(A_STATUS, 1);
  sq.push_back({ed, eid, cf & enh, enh});
endtask

// ---------------- sensor BFM (clock counts) ----------------
task automatic bp(input int clks, input int low);
  @(posedge PCLK); #1 bl = 0;
  for (int i = 0; i < low; i++) @(posedge PCLK);
  #1 bl = 1;
  for (int i = 0; i < clks - low - 1; i++) @(posedge PCLK);
endtask
function automatic logic [3:0] crc4(input logic [23:0] d, input int n, input bit legacy);
  logic [3:0] r;
  r = 4'h5;
  for (int i = 0; i < n; i++)
    for (int k = 3; k >= 0; k--) r = {r[2:0], d[4 * i + k]} ^ (r[3] ? 4'hD : 4'h0);
  if (!legacy) for (int k = 0; k < 4; k++) r = {r[2:0], 1'b0} ^ (r[3] ? 4'hD : 4'h0);
  return r;
endfunction
// one frame with a calibration pulse of cal clocks; ticks scaled from it;
// bad_at: symbol index (0 status) replaced by bad ticks; lw: low ticks
task automatic bfm_frame(input int cal, input logic [3:0] st, input logic [23:0] d, input int n,
                         input int crc = -1, input int bad_at = -1, input int bad = 0, input int lw = 5,
                         input int pause = 0);
  int c;
  c = crc < 0 ? crc4(d, n, 1'b0) : crc;
  bp(cal, lw * cal / 56);
  for (int i = 0; i < n + 2; i++) begin
    int v;
    v = i == 0 ? 12 + st : i <= n ? 12 + d[4 * (i - 1) +: 4] : 12 + c;
    if (i == bad_at) v = bad;
    bp((2 * v * cal + 56) / 112, (i == bad_at ? 2 : lw) * cal / 56);
  end
  if (pause > 0) bp((2 * pause * cal + 56) / 112, lw * cal / 56);
endtask
task automatic bfm_end(input int cal);
  bp(cal, 5 * cal / 56);
  cycles(20);
endtask
task automatic drain;
  cycles(20);
  rd(A_FLAGS);
  if (rdv[0]) begin rd(A_RX0); rd(A_RX1); end
  if (rdv[1]) rd(A_SER_RX);
endtask

task automatic ip_func;
  logic [18:0] cal8 = 19'd448;
  // the CTRL register test started a frame: let it finish
  while (dut.u_core.tst != 0) @(negedge PCLK);
  cycles(100); drain(); xq.delete(); wr(A_IRQ_STATUS, IRQ_ALL);
  // ---- loopback: 8-clock ticks, 6 nibbles, a fixed pause of 20 ticks
  wr(A_RX_CFG, {4'd2, 3'd6, 12'd8});
  wr(A_TX_CFG, {2'd1, 3'd6, 4'd5, 12'd8});
  wr(A_TX_PAUSE, 20);
  wr(A_TX_FRAME, $urandom & 32'h0FFF_FFFF);
  wr(A_CTRL, 32'h5);                                       // tx_en, rx_pause
  poll(A_IRQ_STATUS, 32'd1 << IRQ_TX_FRAME, 32'd1 << IRQ_TX_FRAME, 3000);
  irq_bit(IRQ_TX_FRAME, "TX_FRAME");
  rx_take(cal8);
  irq_bit(IRQ_RX_AVAIL, "RX_AVAIL");
  serve(6, cal8);
  wr(A_TX_FRAME, 32'h0FFF_FFFF); serve(1, cal8);
  wr(A_TX_FRAME, 32'h0000_0000); serve(2, cal8);

  // ---- serial messages: enhanced (C = 0, C = 1, every ID and data bit both ways), short
  ser_send(1, 0, 8'hA5, 16'h05A5);
  serve(19, cal8);
  irq_bit(IRQ_SER_TX_DONE, "SER_TX_DONE");
  irq_bit(IRQ_SER_RX_AVAIL, "SER_RX_AVAIL");
  rd_exp(A_STATUS, 0);
  ser_send(1, 1, 8'h05, 16'hA5A5); serve(19, cal8);
  ser_send(1, 1, 8'h0A, 16'h5A5A); serve(19, cal8);
  ser_send(1, 0, 8'h5A, 16'h0A5A); serve(19, cal8);
  ser_send(0, 0, 8'h03, 16'h005A); serve(17, cal8);
  // a start while busy is ignored
  ser_send(0, 0, 8'h0C, 16'h00A5);
  wr(A_SER_TX, 32'h0300_0000); wr(A_CMD, 1);
  serve(17, cal8);
  // overflow: the next message finds SER_RX full and is dropped
  ser_send(0, 0, 8'h06, 16'h0033);
  for (int i = 0; i < 17; i++) begin rx_take(cal8); wr(A_TX_FRAME, $urandom & 32'h0FFF_FFFF); end
  ser_send(0, 0, 8'h09, 16'h00CC);
  for (int i = 0; i < 17; i++) begin rx_take(cal8); wr(A_TX_FRAME, $urandom & 32'h0FFF_FFFF); end
  irq_bit(IRQ_SER_RX_OVF, "SER_RX_OVF");
  void'(sq.pop_back());
  ser_take();
  if (n_ser != 7 || sq.size() != 0) fail($sformatf("serial messages: %0d received, %0d left", n_ser, sq.size()));
  // reads while empty; pops on the clock a new frame / message is captured
  rx_take(cal8); rd(A_RX1); rd(A_SER_RX);
  poll(A_FLAGS, 32'h1, 32'h1, 20000);
  while (!(dut.u_core.dv_busy && dut.u_core.dv_k == 0 && dut.u_core.rst == 3)) @(negedge PCLK);
  @(negedge PCLK); apb_now(0, A_RX1, 0, 0);                // the CRC nibble's result is due now
  void'(xq.pop_front());
  rx_take(cal8);
  ser_send(0, 0, 8'h0B, 16'h0077);
  for (int i = 0; i < 17; i++) begin rx_take(cal8); wr(A_TX_FRAME, $urandom & 32'h0FFF_FFFF); end
  ser_send(0, 0, 8'h04, 16'h0088);
  while (!(dut.u_core.dv_busy && dut.u_core.dv_k == 0 && dut.u_core.rst == 3 &&
           {dut.u_core.h_b3[14:0], dut.u_core.r_st[3]} == 16'h8000)) @(negedge PCLK);
  @(negedge PCLK); apb_now(0, A_SER_RX, 0, 0);
  if (rdv !== {6'd0, sq.pop_front()}) fail($sformatf("SER_RX %h (popped as the next one came)", rdv));
  cycles(2);
  ser_take();
  if (sq.size() != 0) fail("SER_RX: the message captured with the pop is missing");
  // legacy CRC, 1 nibble, constant frames of 200 ticks (tx and rx stay in step)
  wr(A_CTRL, 32'h4);                                       // stop between frames
  cycles(3000); drain(); xq.delete();
  wr(A_TX_CFG, {2'd2, 3'd1, 4'd5, 12'd8}); wr(A_RX_CFG, {4'd2, 3'd1, 12'd8});
  wr(A_TX_PAUSE, 200); wr(A_IRQ_STATUS, IRQ_ALL);
  wr(A_CTRL, 32'h7);
  serve(4, cal8);
  // the transmitter stops; the receiver flags the last pause (it never ends)
  wr(A_CTRL, 32'h4);
  cycles(4000);
  drain(); xq.delete();

  // ---- sensor BFM: 6 nibbles, 8-clock ticks
  lb = 0;
  wr(A_CTRL, 32'h0); wr(A_RX_CFG, {4'd0, 3'd6, 12'd8});
  wr(A_IRQ_STATUS, IRQ_ALL);
  bfm_frame(448, 4'h3, 24'h123456, 6);
  bfm_frame(448, 4'hC, 24'hFEDCBA, 6);                    // RX is full: dropped
  bfm_end(448);
  irq_bit(IRQ_RX_OVF, "RX_OVF");
  rd_exp(A_RX0, {4'h0, 24'h123456, 4'h3}); rd_exp(A_RX1, 448);
  // the largest calibration pulses (tick 4095): 0x3FFFF and 0x40000 clocks
  wr(A_RX_CFG, {4'd0, 3'd1, 12'd4095});
  bfm_frame(19'h3FFFF, 4'hA, 24'h5, 1);
  bfm_frame(19'h40000, 4'h5, 24'hA, 1);
  bfm_end(19'h40000);
  rd_exp(A_RX0, {4'h0, 24'h5, 4'hA}); rd_exp(A_RX1, 19'h3FFFF);
  bfm_frame(19'h40000, 4'h5, 24'hA, 1);
  bfm_end(19'h40000);
  drain();
  // receive errors, one at a time
  wr(A_RX_CFG, {4'd0, 3'd6, 12'd8});
  wr(A_IRQ_STATUS, IRQ_ALL);
  bfm_frame(448, 4'h1, 24'h111111, 6, -1, 2, 40);         // 40 ticks: no nibble
  bfm_end(448); drain();
  irq_bit(IRQ_ERR_NIBBLE, "ERR_NIBBLE");
  bfm_frame(448, 4'h1, 24'h111111, 6, -1, 3, 14);          // a low part of 2 ticks
  bfm_end(448); drain();
  irq_bit(IRQ_ERR_LOW, "ERR_LOW");
  bfm_frame(448, 4'h1, 24'h111111, 6, 4'(crc4(24'h111111, 6, 0) + 1));
  bfm_end(448); drain();
  irq_bit(IRQ_ERR_CRC, "ERR_CRC");
  bfm_frame(448, 4'h1, 24'h111111, 6);
  bp(20 * 8, 5 * 8);                                       // no calibration pulse after the CRC
  bfm_end(448); drain();
  irq_bit(IRQ_ERR_SYNC, "ERR_SYNC");
  wr(A_CTRL, 32'h8);                                       // drift check
  bfm_frame(448, 4'h1, 24'h111111, 6);
  bfm_frame(470, 4'h1, 24'h111111, 6);                     // 22 / 448 > 1/64
  bfm_end(470); drain();
  irq_bit(IRQ_ERR_CAL, "ERR_CAL");
  wr(A_CTRL, 32'h4);                                       // pause required
  bfm_frame(448, 4'h1, 24'h111111, 6, -1, -1, 0, 5, 10);   // a pause of 10 ticks
  bfm_end(448); drain();
  irq_bit(IRQ_ERR_PAUSE, "ERR_PAUSE");
  // a short serial message with a wrong CRC
  wr(A_CTRL, 32'h0);
  begin
    logic [15:0] b2;
    b2 = {4'h7, 8'h3C, crc4(24'h000C37, 3, 0) ^ 4'h1};      // ID 7, data 0x3C
    for (int f = 0; f < 16; f++) begin
      bfm_frame(448, {f == 0, b2[15 - f], 2'b00}, 24'h0, 6);
    end
    bfm_end(448); drain();
  end
  irq_bit(IRQ_SER_CRC, "SER_CRC");
  lb = 1;
  wr(A_IRQ_STATUS, IRQ_ALL);
  if (n_rx < 100) fail($sformatf("only %0d looped-back frames", n_rx));
  $display("SENT_apb: %0d frames, %0d serial messages looped back", n_rx, n_ser);
endtask
