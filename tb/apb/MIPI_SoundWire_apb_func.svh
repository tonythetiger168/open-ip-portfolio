// SPDX-License-Identifier: Apache-2.0
// SoundWire-specific part of tb/MIPI_SoundWire_apb_tb.sv. A second
// MIPI_SoundWire_top (the peer, driven directly) shares the bus; DATA has a
// bus keeper and the TB can invert one control bit of a frame. Both ends
// have a register bank on their reg_* pins.
// Covered through the registers: the DUT as a peripheral (lock, READ /
// WRITE / PING from the peer, a bad parity bit, samples both ways through
// TX / RX with a full TX, an underrun, an RX overflow and a pop as RX
// captures, losing the sync when the manager resets), then as the manager
// (commands through CMD with CMD full and held off, responses through RSP
// with an overflow and a pop as RSP captures, PING status in STATUS),
// every stream event and interrupt bit.
// (two drivers are expected only while the register tests write random
// roles and frame shapes into CFG, and while a peripheral resynchronises)
logic        kc = 0, kd = 0, fon = 0, fv = 0, cont_ok = 1;
wire         p_clk_o, p_clk_oe, p_dat_o, p_dat_oe;
wire         bus_c = sw_clk_oe ? sw_clk_o : (p_clk_oe ? p_clk_o : kc);
wire         bus_d = fon ? fv : (sw_dat_oe ? sw_dat_o : (p_dat_oe ? p_dat_o : kd));
assign sw_clk_i = bus_c;
assign sw_dat_i = bus_d;
always @(posedge PCLK) if (!PRESETN) begin kc <= 0; kd <= 0; end else begin kc <= bus_c; kd <= bus_d; end
always @(negedge PCLK) if (PRESETN && sw_dat_oe && p_dat_oe && !fon && !cont_ok) fail("DATA driven by both");

// peer
logic        p_rst = 0, p_mgr = 1, p_cmd_valid = 0, p_tx_valid = 0;
logic [4:0]  p_div = 11;
logic [1:0]  p_cols = 1, p_cmd_op = 0, p_dev_status = 0;
logic [3:0]  p_dev = 5, p_txc = 0, p_rxc = 0, p_cmd_dev = 0;
logic [15:0] p_cmd_addr = 0;
logic [7:0]  p_cmd_wdata = 0;
logic [31:0] p_tx_data = 0;
wire         p_cmd_ready, p_rsp_valid, p_rsp_ack, p_rsp_nak, p_reg_we, p_reg_re;
wire         p_tx_ready, p_tx_underrun, p_rx_valid, p_locked, p_lost, p_par_err;
wire  [7:0]  p_rsp_rdata, p_reg_wdata;
logic [7:0]  p_reg_rdata;
wire  [15:0] p_ping, p_reg_addr;
wire  [31:0] p_rx_data;
MIPI_SoundWire_top u_peer (
  .clk(PCLK), .rst_n(PRESETN && !p_rst), .cfg_manager(p_mgr), .cfg_div(p_div), .cfg_cols(p_cols),
  .cfg_dev(p_dev), .cfg_tx_col(p_txc), .cfg_rx_col(p_rxc),
  .sw_clk_o(p_clk_o), .sw_clk_oe(p_clk_oe), .sw_clk_i(bus_c), .sw_dat_o(p_dat_o), .sw_dat_oe(p_dat_oe), .sw_dat_i(bus_d),
  .cmd_valid(p_cmd_valid), .cmd_ready(p_cmd_ready), .cmd_op(p_cmd_op), .cmd_dev(p_cmd_dev), .cmd_addr(p_cmd_addr),
  .cmd_wdata(p_cmd_wdata), .rsp_valid(p_rsp_valid), .rsp_ack(p_rsp_ack), .rsp_nak(p_rsp_nak), .rsp_rdata(p_rsp_rdata),
  .ping_status(p_ping), .dev_status(p_dev_status), .reg_we(p_reg_we), .reg_re(p_reg_re), .reg_addr(p_reg_addr),
  .reg_wdata(p_reg_wdata), .reg_rdata(p_reg_rdata), .tx_valid(p_tx_valid), .tx_ready(p_tx_ready), .tx_data(p_tx_data),
  .tx_underrun(p_tx_underrun), .rx_valid(p_rx_valid), .rx_data(p_rx_data), .locked(p_locked), .lost_sync(p_lost),
  .par_err(p_par_err));

// register banks: [0] behind the DUT's reg_* pins, [1] behind the peer's
logic [7:0] bank [0:1][0:255];
int         n_we [0:1];
initial begin
  for (int a = 0; a < 256; a++) begin bank[0][a] = 8'(a * 3 + 1); bank[1][a] = 8'(a * 5 + 2); end
  n_we[0] = 0; n_we[1] = 0;
end
assign reg_rdata = bank[0][reg_addr[7:0]];
assign p_reg_rdata = bank[1][p_reg_addr[7:0]];
always @(posedge PCLK) begin
  if (reg_we) begin bank[0][reg_addr[7:0]] <= reg_wdata; n_we[0]++; end
  if (p_reg_we) begin bank[1][p_reg_addr[7:0]] <= p_reg_wdata; n_we[1]++; end
end

// samples: [0] DUT -> peer, [1] peer -> DUT
logic [31:0] sq [0:1][0:255];
int          sh [0:1], st [0:1];
initial for (int i = 0; i < 2; i++) begin sh[i] = 0; st[i] = 0; end
bit p_feed = 0;
always @(negedge PCLK) if (PRESETN) begin
  if (p_tx_valid && p_tx_ready) begin sq[1][st[1] % 256] = p_tx_data; st[1]++; p_tx_valid = 0; end
  if (p_feed && !p_tx_valid) begin p_tx_valid = 1; p_tx_data = $urandom; end
  if (p_rx_valid) begin
    if (sh[0] == st[0]) begin if (p_rx_data !== 0) fail($sformatf("peer: unexpected sample %h", p_rx_data)); end
    else begin
      if (p_rx_data !== sq[0][sh[0] % 256]) fail($sformatf("peer: sample %h, expected %h", p_rx_data, sq[0][sh[0] % 256]));
      sh[0]++;
    end
  end
end

task automatic frames(input int n);
  repeat (n) begin
    @(negedge PCLK);
    if (p_mgr) while (!(u_peer.edge_now && u_peer.row == 47 && u_peer.col == {u_peer.lastc_hi, 1'b1})) @(negedge PCLK);
    else while (!(dut.u_core.edge_now && dut.u_core.row == 47 && dut.u_core.col == {dut.u_core.lastc_hi, 1'b1})) @(negedge PCLK);
  end
endtask
task automatic irq_expect(input int b);
  rd(A_IRQ_STATUS);
  if (!rdv[b]) fail($sformatf("IRQ bit %0d not set (%h)", b, rdv));
endtask
// invert control bit ci of the manager's next frame (NRZI from the line)
task automatic force_ctl(input int ci);
  logic [47:0] w;
  if (p_mgr) while (!(u_peer.m_mid && u_peer.row == 6'(47 - ci) && u_peer.col == 0)) @(negedge PCLK);
  else while (!(dut.u_core.m_mid && dut.u_core.row == 6'(47 - ci) && dut.u_core.col == 0)) @(negedge PCLK);
  @(negedge PCLK);
  w = p_mgr ? {1'b0, u_peer.cw, 2'b00, 8'hB1, u_peer.dyn_m, 2'b00}
            : {1'b0, dut.u_core.cw, 2'b00, 8'hB1, dut.u_core.dyn_m, 2'b00};
  fv = kd ^ !w[ci]; fon = 1;
  while (!(p_mgr ? u_peer.m_edge : dut.u_core.m_edge)) @(negedge PCLK);
  @(negedge PCLK) fon = 0;
endtask
// peer manager command; returns {ack, nak, rdata}
task automatic p_cmd(input logic [1:0] op, input logic [3:0] dv, input logic [15:0] a, input logic [7:0] wd,
                     output logic [9:0] r);
  int g;
  @(negedge PCLK) while (!p_cmd_ready) @(negedge PCLK);
  p_cmd_valid = 1; p_cmd_op = op; p_cmd_dev = dv; p_cmd_addr = a; p_cmd_wdata = wd;
  @(negedge PCLK) p_cmd_valid = 0;
  g = 0;
  while (!p_rsp_valid && g < 100_000) begin @(negedge PCLK); g++; end
  r = {p_rsp_ack, p_rsp_nak, p_rsp_rdata};
endtask
// CFG word: manager [0], div [5:1], cols [7:6], dev [11:8], tx col [15:12], rx col [19:16], status [21:20]
function automatic logic [31:0] cfgw(input bit m, input int dv, input int cl, input int dev, input int tc, input int rc, input int s);
  return 32'(m) | (32'(dv) << 1) | (32'(cl) << 6) | (32'(dev) << 8) | (32'(tc) << 12) | (32'(rc) << 16) | (32'(s) << 20);
endfunction
// CMD word: op [1:0], dev [5:2], addr [21:6], wdata [29:22]
function automatic logic [31:0] cmdw(input int op, input int dev, input int a, input int wd);
  return 32'(op) | (32'(dev) << 2) | (32'(a) << 6) | (32'(wd) << 22);
endfunction
task automatic h_send(input logic [31:0] d);
  poll(A_FLAGS, 1 << FLAG_TX_FULL, 0, 20000);
  sq[0][st[0] % 256] = d; st[0]++;
  wr(A_TX, d);
endtask
task automatic h_recv;
  poll(A_FLAGS, 1 << FLAG_RX_AVAIL, 1 << FLAG_RX_AVAIL, 20000);
  rd(A_RX);
  if (sh[1] == st[1]) fail($sformatf("RX: unexpected sample %h", rdv));
  else begin
    if (rdv !== sq[1][sh[1] % 256]) fail($sformatf("RX: sample %h, expected %h", rdv, sq[1][sh[1] % 256]));
    sh[1]++;
  end
endtask
// DUT manager command through CMD, response through RSP
task automatic h_cmd(input int op, input int dev, input int a, input int wd, input logic [9:0] e);
  poll(A_FLAGS, 1 << FLAG_CMD_FULL, 0, 20000);
  wr(A_CMD, cmdw(op, dev, a, wd));
  poll(A_FLAGS, 1 << FLAG_RSP_AVAIL, 1 << FLAG_RSP_AVAIL, 50000);
  rd(A_RSP);
  if (rdv[9:0] !== {e[7:0], e[8], e[9]}) fail($sformatf("RSP %h, expected ack/nak/data %h", rdv, e));
endtask

task automatic ip_func;
  logic [9:0] r;
  int w;
  wr(A_IRQ_ENABLE, 0);
  // ---- DUT as peripheral (device 1), the peer the manager
  wr(A_CFG, cfgw(0, 11, 1, 1, 1, 2, 2));
  @(negedge PCLK) p_rst = 1; @(negedge PCLK) p_rst = 0;
  // the register tests left the DUT locked as a manager: as a peripheral it
  // drops that lock and finds the peer's frame
  begin : b_drop
    int k;
    k = 0;
    rd(A_STATUS);
    while (rdv[0] && k < 10) begin frames(1); rd(A_STATUS); k++; end
  end
  poll(A_STATUS, 1, 1, 20000);
  frames(1);
  cont_ok = 0;
  wr(A_IRQ_STATUS, IRQ_ALL);
  // READ, WRITE, PING
  p_cmd(2, 1, 16'h0012, 0, r);
  if (r !== {2'b10, bank[0][8'h12]}) fail($sformatf("READ response %h", r));
  p_cmd(3, 1, 16'h0034, 8'hC5, r);
  if (r !== {2'b10, 8'hC5} || bank[0][8'h34] !== 8'hC5) fail($sformatf("WRITE response %h", r));
  frames(2);
  if (p_ping[15:14] !== 2'd2) fail($sformatf("PING status %h", p_ping));
  wr(A_CFG, cfgw(0, 11, 1, 1, 1, 2, 1));
  frames(2);
  if (p_ping[15:14] !== 2'd1) fail($sformatf("PING status %h", p_ping));
  // a bad parity bit: NAK, PAR_ERR, no write
  w = n_we[0];
  fork
    p_cmd(3, 1, 16'h0035, 8'h11, r);
    begin frames(1); force_ctl(16); end
  join
  if (r !== {2'b01, 8'h11} || n_we[0] != w) fail($sformatf("bad parity: response %h", r));
  irq_expect(IRQ_PAR_ERR);
  // random READs and WRITEs over the whole address space
  for (int i = 0; i < 12; i++) begin : b_rnd
    logic [15:0] a;
    logic [7:0]  d;
    a = $urandom; d = $urandom;
    if (i % 2) begin
      p_cmd(3, 1, a, d, r);
      if (r !== {2'b10, d} || bank[0][a[7:0]] !== d) fail($sformatf("WRITE %h response %h", a, r));
    end else begin
      p_cmd(2, 1, a, 0, r);
      if (r !== {2'b10, bank[0][a[7:0]]}) fail($sformatf("READ %h response %h", a, r));
    end
  end
  // samples both ways: DUT TX column 1 -> peer, peer column 2 -> DUT
  p_rxc = 1; p_txc = 2;
  frames(2);
  sh[0] = st[0];
  for (int i = 0; i < 5; i++) h_send($urandom);
  h_send(32'hFFFF_FFFF); h_send(32'h0);
  p_feed = 1;
  frames(1);
  sh[1] = st[1];
  while (dut.avail_RX) rd(A_RX);
  for (int i = 0; i < 6; i++) h_recv();
  // TX full: writes while full are dropped
  h_send($urandom);
  wr(A_TX, 32'h1234_5678);
  wr(A_TX, 32'h1234_5678);
  irq_expect(IRQ_TX_OVF);
  frames(3);
  irq_expect(IRQ_TX_UNDERRUN);
  irq_expect(IRQ_TX_DONE);
  // RX not read: the next sample overflows; then RX is popped as it captures
  frames(3);
  irq_expect(IRQ_RX_OVF);
  p_feed = 0;
  frames(2);
  rd(A_RX);
  rd(A_RX);
  p_feed = 1;
  frames(1);
  while (!(dut.u_core.edge_now && dut.u_core.col == 4'd2 && dut.u_core.row == 6'd31 && dut.avail_RX)) @(negedge PCLK);
  apb_now(0, A_RX, 0, 0);
  p_feed = 0;
  frames(2);
  while (dut.avail_RX) rd(A_RX);
  irq_expect(IRQ_RX_AVAIL);
  sh[1] = st[1];
  // the manager resets: the DUT loses the sync and finds it again
  // (until the DUT drops its lock it may drive into the new frame)
  cont_ok = 1;
  @(negedge PCLK) p_rst = 1; @(negedge PCLK) p_rst = 0;
  poll(A_STATUS, 1, 0, 20000);
  cont_ok = 0;
  irq_expect(IRQ_LOST_SYNC);
  poll(A_STATUS, 1, 1, 50000);
  p_rxc = 0; p_txc = 0;

  // ---- DUT as manager, the peer a peripheral (device 5)
  p_mgr = 0; p_dev = 5; p_dev_status = 3; p_cols = 2;
  @(negedge PCLK) p_rst = 1; @(negedge PCLK) p_rst = 0;
  wr(A_CFG, cfgw(1, 11, 2, 0, 0, 0, 0));
  begin : b_plock
    int g;
    g = 0;
    while (!p_locked && g < 200_000) begin @(negedge PCLK); g++; end
    if (!p_locked) fail("peer did not lock");
  end
  frames(2);
  rd(A_STATUS);
  if (rdv[0] !== 1'b1 || rdv[8:7] !== 2'd3) fail($sformatf("manager STATUS %h", rdv));
  h_cmd(2, 5, 16'h0207, 0, {2'b10, bank[1][8'h07]});
  h_cmd(3, 5, 16'hFF40, 8'h3C, {2'b10, 8'h3C});
  if (bank[1][8'h40] !== 8'h3C) fail("peer bank not written");
  h_cmd(2, 7, 16'h0001, 0, 10'h000);
  h_cmd(0, 0, 16'h0000, 8'hFF, 10'h000);
  for (int i = 0; i < 12; i++) begin : b_rnd2
    logic [15:0] a;
    logic [7:0]  d;
    logic [3:0]  dv;
    a = $urandom; d = $urandom; dv = i % 3 == 2 ? 4'(8 + i) : 4'd5;
    if (i % 2) begin
      h_cmd(3, dv, a, d, {dv == 5, 1'b0, d});
      if (dv == 5 && bank[1][a[7:0]] !== d) fail("peer bank not written");
    end else h_cmd(2, dv, a, 0, dv == 5 ? {2'b10, bank[1][a[7:0]]} : 10'h000);
  end
  // a bad parity bit: the peer answers NAK
  poll(A_FLAGS, 1 << FLAG_CMD_FULL, 0, 20000);
  wr(A_CMD, cmdw(3, 5, 16'h0066, 8'hC3));
  frames(1); force_ctl(16);
  poll(A_FLAGS, 1 << FLAG_RSP_AVAIL, 1 << FLAG_RSP_AVAIL, 50000);
  rd(A_RSP);
  if (rdv[9:0] !== {8'hC3, 2'b10}) fail($sformatf("NAK response %h", rdv));
  rd(A_RSP);                                    // empty: the last response again
  // every PING slot: the peer moves through device numbers 1 to 8
  for (int d = 1; d <= 8; d++) begin
    p_dev = 4'(d); p_dev_status = 3; frames(2);
    rd(A_STATUS);
    if (rdv[18 - 2 * d -: 2] !== 2'd3) fail($sformatf("PING status %h, device %0d", rdv, d));
    p_dev_status = 0; frames(2);
  end
  p_dev = 5; p_dev_status = 3; frames(2);
  // CMD full and held off; RSP not read: the second response overflows
  wr(A_CMD, cmdw(2, 5, 1, 0));
  wr(A_CMD, cmdw(2, 5, 2, 0));
  wr(A_CMD, cmdw(2, 5, 3, 0));
  irq_expect(IRQ_CMD_OVF);
  frames(4);
  irq_expect(IRQ_RSP_OVF);
  irq_expect(IRQ_CMD_DONE);
  rd(A_RSP);
  if (rdv[9:0] !== {bank[1][8'h01], 2'b01}) fail($sformatf("RSP after overflow %h", rdv));
  // RSP popped as it captures
  wr(A_CMD, cmdw(2, 5, 4, 0));
  frames(1);
  wr(A_CMD, cmdw(2, 5, 5, 0));
  while (!(dut.u_core.edge_now && dut.u_core.col == 4'd0 && dut.u_core.row == 6'd33 && dut.u_core.f_host && dut.avail_RSP))
    @(negedge PCLK);
  apb_now(0, A_RSP, 0, 0);
  if (rdv[9:0] !== {bank[1][8'h04], 2'b01}) fail($sformatf("RSP %h", rdv));
  frames(1);
  rd(A_RSP);
  if (rdv[9:0] !== {bank[1][8'h05], 2'b01}) fail($sformatf("RSP %h after a pop at capture", rdv));
  irq_expect(IRQ_RSP_AVAIL);

  // interrupts: masked, raising irq, cleared one by one
  rd(A_IRQ_STATUS);
  if (rdv[10:0] != 11'h7FF) fail($sformatf("IRQ_STATUS %h, expected every bit", rdv));
  if (irq) fail("irq high with every bit masked");
  wr(A_IRQ_ENABLE, IRQ_ALL);
  if (!irq) fail("irq low with every bit enabled");
  for (int b = 0; b < 11; b++) wr(A_IRQ_STATUS, 1 << b);
  rd(A_IRQ_STATUS);
  if (rdv[10:0] != 0) fail($sformatf("IRQ_STATUS %h after clearing", rdv));
  wr(A_CMD, cmdw(2, 5, 6, 0));
  poll(A_IRQ_STATUS, 1 << IRQ_RSP_AVAIL, 1 << IRQ_RSP_AVAIL, 50000);
  if (!irq) fail("irq low with RSP_AVAIL pending");
  rd(A_RSP);
  cont_ok = 1;
  wr(A_CFG, cfgw(0, 11, 0, 1, 0, 0, 0));
endtask
