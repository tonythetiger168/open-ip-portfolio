// SPDX-License-Identifier: Apache-2.0
// DigRF-specific part of tb/DigRF_apb_tb.sv. A second DigRF_top (the peer,
// driven directly) sits on the other end of the lanes; the lane into the
// DUT can be cut or have one bit inverted. Both sides have a register bank
// (the DUT's on the reg_* pins) and a data host / scoreboard on dtx_* /
// drx_*. Covered through the registers: CFG, register writes and reads of
// the peer through CTL / RSP, the peer's accesses to the DUT's bank,
// interrupts both ways through INT_TX / INT_RX, data frames both ways,
// read timeouts, code and frame errors, underruns, every stream overflow,
// STATUS during a burst, every interrupt bit masked, enabled and cleared
// one by one.
logic [1:0] lane_mode = 0;              // 0 normal, 1 cut, 2 invert one bit
logic       flip = 0;
wire        p_tx;
assign rx_p = lane_mode == 1 ? 1'b0 : (p_tx ^ flip);

// peer
logic [3:0] p_sync = 1;
logic [7:0] p_hold = 4, p_tmo = 255;
logic       p_ctl_valid = 0, p_ctl_rd = 0, p_int_valid = 0, p_dtx_valid = 0;
logic [7:0] p_ctl_addr = 0, p_ctl_wdata = 0, p_reg_rdata = 0, p_dtx_data = 0;
logic [4:0] p_int_vec = 0;
logic [2:0] p_dtx_size = 0;
logic [1:0] p_dtx_chan = 0;
wire        p_ctl_ready, p_rsp_valid, p_rsp_timeout, p_reg_we, p_reg_re, p_int_ready, p_int_rx;
wire        p_dtx_ready, p_drx_valid, p_drx_sof, p_drx_eof, p_drx_abort, p_tx_on, p_rx_locked;
wire        p_err_code, p_err_frame, p_tx_underrun;
wire  [7:0] p_rsp_data, p_reg_addr, p_reg_wdata, p_drx_data;
wire  [4:0] p_int_rx_vec;
wire  [1:0] p_drx_chan;
DigRF_top u_peer (
  .clk(PCLK), .rst_n(PRESETN), .tx_p(p_tx), .rx_p(tx_p),
  .cfg_sync(p_sync), .cfg_hold(p_hold), .cfg_timeout(p_tmo),
  .ctl_valid(p_ctl_valid), .ctl_ready(p_ctl_ready), .ctl_rd(p_ctl_rd), .ctl_addr(p_ctl_addr),
  .ctl_wdata(p_ctl_wdata), .rsp_valid(p_rsp_valid), .rsp_data(p_rsp_data), .rsp_timeout(p_rsp_timeout),
  .reg_we(p_reg_we), .reg_re(p_reg_re), .reg_addr(p_reg_addr), .reg_wdata(p_reg_wdata), .reg_rdata(p_reg_rdata),
  .int_valid(p_int_valid), .int_ready(p_int_ready), .int_vec(p_int_vec), .int_rx(p_int_rx),
  .int_rx_vec(p_int_rx_vec),
  .dtx_valid(p_dtx_valid), .dtx_ready(p_dtx_ready), .dtx_data(p_dtx_data), .dtx_size(p_dtx_size),
  .dtx_chan(p_dtx_chan), .drx_valid(p_drx_valid), .drx_data(p_drx_data), .drx_sof(p_drx_sof),
  .drx_eof(p_drx_eof), .drx_chan(p_drx_chan), .drx_abort(p_drx_abort),
  .tx_on(p_tx_on), .rx_locked(p_rx_locked), .err_code(p_err_code), .err_frame(p_err_frame),
  .tx_underrun(p_tx_underrun));

// register banks: [0] the DUT's (reg_* pins), [1] the peer's
logic [7:0] bank [0:1][0:255];
initial begin
  reg_rdata = 0;
  for (int a = 0; a < 256; a++) begin bank[0][a] = 8'(a * 37 + 5); bank[1][a] = 8'(a * 91 + 3); end
end
always @(posedge PCLK) begin
  if (reg_re) reg_rdata <= bank[0][reg_addr];
  if (reg_we) bank[0][reg_addr] <= reg_wdata;
  if (p_reg_re) p_reg_rdata <= bank[1][p_reg_addr];
  if (p_reg_we) bank[1][p_reg_addr] <= p_reg_wdata;
end

// data: side 0 = DUT host -> peer, side 1 = peer host -> DUT. One frame
// at a time per side; the receiver compares against the sender's bytes.
int  d_len [0:1], d_idx [0:1], d_slot [0:1], d_rx [0:1], d_frames [0:1];
logic [7:0] d_buf [0:1][0:255], d_sent [0:1][0:255];
logic [1:0] d_ch [0:1];
bit  d_busy [0:1], d_starve [0:1], d_lax = 0, ab_seen = 0;
initial for (int s = 0; s < 2; s++) begin d_busy[s] = 0; d_starve[s] = 0; d_frames[s] = 0; end
initial begin dtx_valid = 0; dtx_data = 0; dtx_size = 0; dtx_chan = 0; end
task automatic d_send(input int s, input int size, input int chan);
  while (d_busy[s]) @(negedge PCLK);
  d_len[s] = 8 << (size > 5 ? 5 : size); d_ch[s] = 2'(chan);
  for (int i = 0; i < d_len[s]; i++) d_buf[s][i] = $urandom;
  d_idx[s] = 0; d_slot[s] = 0; d_rx[s] = 0; d_busy[s] = 1;
  if (s == 0) begin dtx_size = 3'(size); dtx_chan = 2'(chan); end
  else begin p_dtx_size = 3'(size); p_dtx_chan = 2'(chan); end
endtask
bit took0, took1;
always @(posedge PCLK) begin took0 <= dtx_valid && dtx_ready; took1 <= p_dtx_valid && p_dtx_ready; end
always @(negedge PCLK) if (PRESETN) begin
  // senders
  if (took0) begin d_sent[0][d_slot[0]] = d_buf[0][d_idx[0]]; d_idx[0]++; d_slot[0]++; end
  if (dut.u_core.tx_underrun) begin d_sent[0][d_slot[0]] = 0; d_slot[0]++; end
  if (took1) begin d_sent[1][d_slot[1]] = d_buf[1][d_idx[1]]; d_idx[1]++; d_slot[1]++; end
  if (p_tx_underrun) begin d_sent[1][d_slot[1]] = 0; d_slot[1]++; end
  dtx_valid = d_busy[0] && !d_starve[0] && d_slot[0] < d_len[0];
  dtx_data = dtx_valid ? d_buf[0][d_idx[0]] : 8'($urandom);
  p_dtx_valid = d_busy[1] && !d_starve[1] && d_slot[1] < d_len[1];
  p_dtx_data = p_dtx_valid ? d_buf[1][d_idx[1]] : 8'($urandom);
  // receivers (an underrun byte is 0)
  if (p_drx_valid) rx_byte(0, p_drx_data, p_drx_sof, p_drx_eof, p_drx_chan);
  if (drx_valid) rx_byte(1, drx_data, drx_sof, drx_eof, drx_chan);
  if (drx_abort || p_drx_abort) begin
    if (!d_lax) fail("unexpected data abort");
    if (drx_abort) ab_seen = 1;
    d_busy[drx_abort ? 1 : 0] = 0;
  end
end
// the receiver compares with what the sender put on the lane (taken
// bytes, 0 for underrun slots)
task automatic rx_byte(input int s, input logic [7:0] d, input logic sof, input logic eof, input logic [1:0] ch);
  if (!d_busy[s]) begin
    if (!d_lax) fail($sformatf("data from side %0d outside a frame", s));
  end else begin
    if (sof !== (d_rx[s] == 0) || eof !== (d_rx[s] == d_len[s] - 1) || ch !== d_ch[s])
      fail($sformatf("side %0d byte %0d: sof %b eof %b chan %0d", s, d_rx[s], sof, eof, ch));
    // (in fault tests an inverted bit can make another valid byte)
    if (d !== d_sent[s][d_rx[s]] && !d_lax) fail($sformatf("side %0d byte %0d: %h, expected %h", s, d_rx[s], d, d_sent[s][d_rx[s]]));
    d_rx[s]++;
    if (eof) begin d_busy[s] = 0; d_frames[s]++; end
  end
endtask

`define B(N) (32'h1 << IRQ_``N)
task automatic irq_check(input logic [31:0] m, input string what);
  rd(A_IRQ_STATUS);
  if (rdv !== m) fail($sformatf("%s: IRQ_STATUS %h, expected %h", what, rdv, m));
  if (irq !== 0) fail("irq with all interrupts masked");
  for (int i = 0; i < 32; i++)
    if (m[i]) begin
      wr(A_IRQ_ENABLE, 32'h1 << i);
      if (irq !== 1) fail($sformatf("irq bit %0d does not reach the pin", i));
      wr(A_IRQ_STATUS, 32'h1 << i);
      if (irq !== 0) fail($sformatf("irq bit %0d not cleared", i));
    end
  wr(A_IRQ_ENABLE, 0);
  rd_exp(A_IRQ_STATUS, 0);
endtask

// a register access of the peer through CTL / RSP
task automatic acc(input bit rdq, input logic [7:0] a, input logic [7:0] d);
  poll(A_FLAGS, 32'h1 << FLAG_CTL_FULL, 0, 2000);
  wr(A_CTL, {15'd0, rdq, a, d});
  if (rdq) begin
    poll(A_FLAGS, 32'h1 << FLAG_RSP_AVAIL, 32'h1 << FLAG_RSP_AVAIL, 2000);
    rd_exp(A_RSP, {24'd0, bank[1][a]});
  end
endtask
task automatic quiet;
  int g;
  g = 0;
  while ((dut.u_core.tx_on || p_tx_on || d_busy[0] || d_busy[1] || !p_ctl_ready || !p_int_ready) && g < 200_000) begin
    @(negedge PCLK); g++;
  end
  if (g >= 200_000) fail("link did not go quiet");
  cycles(30);
endtask
task automatic p_ctl(input bit rdq, input logic [7:0] a, input logic [7:0] d);
  @(negedge PCLK);
  while (!p_ctl_ready) @(negedge PCLK);
  p_ctl_valid = 1; p_ctl_rd = rdq; p_ctl_addr = a; p_ctl_wdata = d;
  @(negedge PCLK) p_ctl_valid = 0;
  if (rdq) begin
    while (!p_rsp_valid && !p_rsp_timeout) @(negedge PCLK);
    if (!p_rsp_valid || p_rsp_data !== bank[0][a]) fail($sformatf("peer read of %h: %h, expected %h", a, p_rsp_data, bank[0][a]));
  end
endtask
task automatic p_irq(input logic [4:0] v);
  @(negedge PCLK);
  while (!p_int_ready) @(negedge PCLK);
  p_int_valid = 1; p_int_vec = v;
  @(negedge PCLK) p_int_valid = 0;
endtask

task automatic ip_func;
  irq_check(0, "idle");
  rd_exp(A_STATUS, 0);
  rd_exp(A_RSP, 0); rd_exp(A_INT_RX, 0);             // empty
  irq_check(0, "empty reads");
  wr(A_CFG, {12'd0, 8'd255, 8'd4, 4'd2});

  // register accesses of the peer, every address
  for (int a = 0; a < 256; a++) begin
    acc(0, a, $urandom);
    acc(1, $urandom, 0);
  end
  quiet();
  irq_check(`B(CTL_DONE) | `B(RSP_AVAIL), "accesses");
  // the peer accesses the DUT's bank; a write / read pair per address
  for (int a = 0; a < 256; a += 3) begin
    p_ctl(0, a, $urandom); p_ctl(1, a, 0);
  end
  quiet();
  // STATUS during a burst
  wr(A_CFG, {12'd0, 8'd60, 8'd200, 4'd15});
  p_hold = 200; p_sync = 15;
  wr(A_CTL, {15'd0, 1'b1, 8'h10, 8'h00});
  poll(A_STATUS, 32'h3, 32'h3, 500);
  poll(A_FLAGS, 32'h1 << FLAG_RSP_AVAIL, 32'h1 << FLAG_RSP_AVAIL, 2000);
  rd_exp(A_RSP, {24'd0, bank[1][8'h10]});
  quiet();
  p_hold = 4; p_sync = 1;
  wr(A_CFG, {12'd0, 8'd255, 8'd4, 4'd2});
  wr(A_IRQ_STATUS, IRQ_ALL);

  // interrupts both ways
  for (int i = 0; i < 32; i++) begin
    poll(A_FLAGS, 32'h1 << FLAG_INT_TX_FULL, 0, 200);
    wr(A_INT_TX, i);
    @(negedge PCLK);
    p_irq(5'(31 - i));
    poll(A_FLAGS, 32'h1 << FLAG_INT_RX_AVAIL, 32'h1 << FLAG_INT_RX_AVAIL, 2000);
    rd_exp(A_INT_RX, 31 - i);
  end
  quiet();
  irq_check(`B(INT_TX_DONE) | `B(INT_RX_AVAIL), "interrupts");

  // data frames both ways, every size and channel
  for (int i = 0; i < 16; i++) begin
    fork d_send(0, i % 8, i % 4); d_send(1, (i + 3) % 8, (i + 1) % 4); join
    quiet();
  end
  if (d_frames[0] != 16 || d_frames[1] != 16) fail($sformatf("frames %0d / %0d", d_frames[0], d_frames[1]));
  // an underrun on the DUT side
  d_send(0, 1, 2);
  cycles(25);
  d_starve[0] = 1;
  while (!dut.u_core.tx_underrun) @(negedge PCLK);
  d_starve[0] = 0;
  quiet();
  irq_check(`B(UNDERRUN), "underrun");

  // read timeout (lane into the DUT cut), then a late response
  lane_mode = 1;
  wr(A_CTL, {15'd0, 1'b1, 8'h33, 8'h00});
  poll(A_IRQ_STATUS, `B(RSP_TIMEOUT), `B(RSP_TIMEOUT), 2000);
  lane_mode = 0;
  quiet();
  wr(A_CFG, {12'd0, 8'd0, 8'd4, 4'd2});
  wr(A_CTL, {15'd0, 1'b1, 8'h34, 8'h00});
  poll(A_IRQ_STATUS, `B(ERR_FRAME), `B(ERR_FRAME), 2000);
  quiet();
  wr(A_CFG, {12'd0, 8'd255, 8'd4, 4'd2});
  irq_check(`B(RSP_TIMEOUT) | `B(ERR_FRAME) | `B(CTL_DONE), "timeouts");
  // a code error: one inverted bit in a burst into the DUT
  p_irq(5'h11);                                       // takes one clock; the
  while (!dut.u_core.rx_locked) @(negedge PCLK);      // burst starts after it
  cycles(3); flip = 1; @(negedge PCLK); flip = 0;
  quiet();
  rd(A_IRQ_STATUS);
  if (!rdv[IRQ_ERR_CODE] && !rdv[IRQ_ERR_FRAME]) fail("inverted bit not flagged");
  if (rdv[IRQ_INT_RX_AVAIL]) rd(A_INT_RX);
  wr(A_IRQ_STATUS, IRQ_ALL);
  // until a code error is flagged (a flipped bit may land in a filler)
  rdv = 0;
  for (int i = 0; i < 20 && !rdv[IRQ_ERR_CODE]; i++) begin
    p_irq(5'h12);
    while (!dut.u_core.rx_locked) @(negedge PCLK);
    cycles($urandom % 10); flip = 1; @(negedge PCLK); flip = 0;
    quiet();
    rd(A_FLAGS);
    if (rdv[FLAG_INT_RX_AVAIL]) rd(A_INT_RX);
    rd(A_IRQ_STATUS);
  end
  rd(A_IRQ_STATUS);
  if (!rdv[IRQ_ERR_CODE]) fail("no code error flagged");
  irq_check(rdv, "code errors");
  // a data frame into the DUT broken by a code error
  d_lax = 1;
  rdv = 0;
  for (int i = 0; i < 20 && !rdv[0]; i++) begin
    d_send(1, 3, 2);
    while (!drx_valid) @(negedge PCLK);
    cycles($urandom % 20); flip = 1; @(negedge PCLK); flip = 0;
    cycles(200);
    rdv[0] = ab_seen;
    d_busy[1] = 0;
    quiet();
  end
  if (!ab_seen) fail("no data abort");
  d_lax = 0;
  rd(A_FLAGS);
  if (rdv[FLAG_INT_RX_AVAIL]) rd(A_INT_RX);
  wr(A_IRQ_STATUS, IRQ_ALL);

  // a stream popped in the clock its next item is captured
  wr(A_CTL, {15'd0, 1'b1, 8'h51, 8'h00});
  poll(A_FLAGS, 32'h1 << FLAG_RSP_AVAIL, 32'h1 << FLAG_RSP_AVAIL, 2000);
  wr(A_CTL, {15'd0, 1'b1, 8'h52, 8'h00});
  while (!(dut.u_core.rx_locked && dut.u_core.rph == 0 && dut.u_core.rs == 2 && dut.u_core.rlct == 3))
    @(negedge PCLK);
  apb_now(0, A_RSP, 0, 0);
  if (rdv !== {24'd0, bank[1][8'h51]}) fail($sformatf("RSP popped at capture: %h", rdv));
  rd_exp(A_RSP, {24'd0, bank[1][8'h52]});
  p_irq(5'h07);
  poll(A_FLAGS, 32'h1 << FLAG_INT_RX_AVAIL, 32'h1 << FLAG_INT_RX_AVAIL, 2000);
  p_irq(5'h08);
  while (!(dut.u_core.rx_locked && dut.u_core.rph == 0 && dut.u_core.rs == 1 && dut.u_core.c_ok
           && dut.u_core.rsym[8:5] == 4'd4))
    @(negedge PCLK);
  apb_now(0, A_INT_RX, 0, 0);
  if (rdv !== 32'h7) fail($sformatf("INT_RX popped at capture: %h", rdv));
  rd_exp(A_INT_RX, 8);
  quiet();
  wr(A_IRQ_STATUS, IRQ_ALL);

  // stream overflows: CTL written while full, RSP / INT_RX not read,
  // INT_TX written twice
  wr(A_CTL, {15'd0, 1'b1, 8'h41, 8'h00});
  wr(A_CTL, {15'd0, 1'b0, 8'h42, 8'h66});            // waits for the read
  wr(A_CTL, {15'd0, 1'b0, 8'h43, 8'h77});            // dropped
  poll(A_FLAGS, 32'h1 << FLAG_RSP_AVAIL, 32'h1 << FLAG_RSP_AVAIL, 2000);
  poll(A_FLAGS, 32'h1 << FLAG_CTL_FULL, 0, 2000);
  wr(A_CTL, {15'd0, 1'b1, 8'h42, 8'h00});
  quiet();
  cycles(100);
  rd_exp(A_RSP, {24'd0, bank[1][8'h41]});              // the second response was dropped
  wr(A_INT_TX, 1); wr(A_INT_TX, 2); wr(A_INT_TX, 3);
  p_irq(5'h05); p_irq(5'h06);
  quiet();
  rd_exp(A_INT_RX, 5);
  irq_check(`B(CTL_DONE) | `B(CTL_OVF) | `B(RSP_AVAIL) | `B(RSP_OVF) | `B(INT_TX_DONE) | `B(INT_TX_OVF)
            | `B(INT_RX_AVAIL) | `B(INT_RX_OVF), "overflows");
  if (bank[1][8'h43] === 8'h77) fail("dropped CTL write reached the peer");
  wr(A_INT_TX, 9);                                    // pending through the final reset
  quiet();
endtask
