// SPDX-License-Identifier: Apache-2.0
// SLIMbus-specific part of tb/MIPI_SLIMbus_apb_tb.sv. A second
// MIPI_SLIMbus_top (the peer, driven directly) shares the bus; CLK and DATA
// have bus keepers, and the TB can force DATA for cells of the frame.
// Covered through the registers: the DUT as a device (lock, FI, samples
// both ways through TX / RX, underruns, a TAG with reserved bits, losing
// the sync when the framer resets), then as the framer (SFSET, the count
// wrapping, cfg_err in STATUS), every stream event and interrupt bit.
logic        kc = 0, kd = 0, fon = 0, fv = 0;
wire         p_clk_o, p_clk_oe, p_dat_o, p_dat_oe;
wire         bus_c = slim_clk_oe ? slim_clk_o : (p_clk_oe ? p_clk_o : kc);
wire         bus_d = fon ? fv : (slim_dat_oe ? slim_dat_o : (p_dat_oe ? p_dat_o : kd));
assign slim_clk_i = bus_c;
assign slim_dat_i = bus_d;
always @(posedge PCLK) begin kc <= bus_c; kd <= bus_d; end
always @(negedge PCLK) if (PRESETN && slim_dat_oe && p_dat_oe && !fon) fail("DATA driven by both");

// peer
logic        p_rst = 0, p_framer = 1, p_tx_valid = 0, p_sf_set = 0;
logic [3:0]  p_div = 3;
logic [7:0]  p_fi = 8'hC3, p_txs = 1, p_rxs = 1;
logic [2:0]  p_txl = 0, p_rxl = 0;
logic [31:0] p_tx_data = 0;
logic [15:0] p_sf_val = 0;
wire         p_cfg_err, p_tx_ready, p_tx_underrun, p_rx_valid, p_rx_err, p_locked, p_sf_locked, p_lost, p_fi_valid;
wire  [31:0] p_rx_data;
wire  [7:0]  p_fi_info;
wire  [15:0] p_sf_count;
MIPI_SLIMbus_top u_peer (
  .clk(PCLK), .rst_n(PRESETN && !p_rst), .cfg_framer(p_framer), .cfg_div(p_div), .cfg_fi(p_fi),
  .sf_set(p_sf_set), .sf_set_val(p_sf_val), .cfg_tx_slot(p_txs), .cfg_tx_len(p_txl), .cfg_rx_slot(p_rxs),
  .cfg_rx_len(p_rxl), .cfg_err(p_cfg_err), .slim_clk_o(p_clk_o), .slim_clk_oe(p_clk_oe), .slim_clk_i(bus_c),
  .slim_dat_o(p_dat_o), .slim_dat_oe(p_dat_oe), .slim_dat_i(bus_d), .tx_valid(p_tx_valid), .tx_ready(p_tx_ready),
  .tx_data(p_tx_data), .tx_underrun(p_tx_underrun), .rx_valid(p_rx_valid), .rx_data(p_rx_data), .rx_err(p_rx_err),
  .locked(p_locked), .sf_locked(p_sf_locked), .lost_sync(p_lost), .fi_valid(p_fi_valid), .fi_info(p_fi_info),
  .sf_count(p_sf_count));

// samples: [0] DUT -> peer, [1] peer -> DUT
logic [31:0] sq [0:1][0:255];
int          sh [0:1], st [0:1];
initial for (int i = 0; i < 2; i++) begin sh[i] = 0; st[i] = 0; end
// the peer sends a new sample whenever its last one was taken
bit p_feed = 0;
always @(negedge PCLK) if (PRESETN) begin
  if (p_tx_valid && p_tx_ready) begin sq[1][st[1] % 256] = p_tx_data; st[1]++; p_tx_valid = 0; end
  if (p_feed && !p_tx_valid) begin p_tx_valid = 1; p_tx_data = $urandom; end
  if (p_rx_valid) begin
    if (sh[0] == st[0]) fail($sformatf("peer: unexpected sample %h", p_rx_data));
    else begin
      if (p_rx_data !== sq[0][sh[0] % 256]) fail($sformatf("peer: sample %h, expected %h", p_rx_data, sq[0][sh[0] % 256]));
      sh[0]++;
    end
  end
end

task automatic frames(input int n);
  repeat (n) begin
    @(negedge PCLK);
    while (!(dut.u_core.rise && dut.u_core.cpos == 767)) @(negedge PCLK);
  end
endtask
task automatic wait_status(input logic [31:0] mask, input logic [31:0] val, input int nframes);
  int k;
  k = 0;
  rd(A_STATUS);
  while ((rdv & mask) != val && k < nframes) begin frames(1); rd(A_STATUS); k++; end
  if ((rdv & mask) != val) fail($sformatf("STATUS %h, waiting for %h", rdv, val));
endtask
task automatic irq_expect(input int b);
  rd(A_IRQ_STATUS);
  if (!rdv[b]) fail($sformatf("IRQ bit %0d not set (%h)", b, rdv));
endtask
// DUT transmits (3-byte segments)
task automatic h_send(input logic [31:0] d);
  poll(A_FLAGS, 1 << FLAG_TX_FULL, 0, 20000);
  sq[0][st[0] % 256] = d & 32'h00FF_FFFF; st[0]++;
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
// force cells from the DUT's frame position, NRZI from the line
task automatic force_cells(input int pos, input logic [3:0] bits);
  while (!(dut.u_core.rise && dut.u_core.cnext == 10'(pos))) @(negedge PCLK);
  for (int i = 0; i < 4; i++) begin
    @(negedge PCLK);
    fv = (i == 0 ? kd : fv) ^ bits[3 - i]; fon = 1;
    while (!dut.u_core.rise) @(negedge PCLK);
  end
  @(negedge PCLK) fon = 0;
endtask
// CHAN word: tx slot [7:0], tx len [10:8], rx slot [18:11], rx len [21:19]
function automatic logic [31:0] chanw(input int ts, input int tl, input int rs, input int rl);
  return 32'(ts) | (32'(tl) << 8) | (32'(rs) << 11) | (32'(rl) << 19);
endfunction
// CFG word: framer [0], div [4:1], fi [12:5]
function automatic logic [31:0] cfgw(input bit fr, input int dv, input int fi);
  return 32'(fr) | (32'(dv) << 1) | (32'(fi) << 5);
endfunction

task automatic ip_func;
  wr(A_IRQ_ENABLE, 0);
  // ---- DUT as a device
  // the register tests left the DUT locked to its own frame as a framer:
  // as a device it drops that lock and finds the peer's frame
  wr(A_CFG, cfgw(0, 3, 0));
  begin : b_drop
    int k;
    k = 0;
    rd(A_STATUS);
    while (rdv[0] && k < 10) begin frames(1); rd(A_STATUS); k++; end
  end
  wait_status(3, 3, 60);
  wr(A_IRQ_STATUS, IRQ_ALL);
  poll(A_IRQ_STATUS, 1 << IRQ_FI, 1 << IRQ_FI, 20000);
  rd(A_STATUS);
  if (rdv[10:3] != p_fi) fail($sformatf("FI info %h", rdv[10:3]));
  // samples both ways: DUT TX at slot 20 (3 bytes) -> peer, peer at slot 130 (4 bytes) -> DUT
  p_rxs = 20; p_rxl = 3; p_txs = 130; p_txl = 4;
  wr(A_CHAN, chanw(20, 3, 130, 4));
  for (int i = 0; i < 6; i++) h_send($urandom);
  h_send(32'hFFFF_FFFF); h_send(32'h0);
  p_feed = 1;
  for (int i = 0; i < 10; i++) h_recv();
  // TX full: a write while full is dropped
  h_send($urandom);
  wr(A_TX, 32'h1234_5678);
  wr(A_TX, 32'h1234_5678);
  irq_expect(IRQ_TX_OVF);
  frames(3);
  irq_expect(IRQ_TX_UNDERRUN);
  // RX not read: the next sample overflows; then RX is popped as it captures
  frames(3);
  irq_expect(IRQ_RX_OVF);
  p_feed = 0;
  frames(2);
  rd(A_RX);                                     // the sample captured first
  sh[1] = st[1];
  rd(A_RX);                                     // empty
  p_feed = 1;
  frames(1);
  while (!(dut.u_core.fall && dut.u_core.slot == 8'd138 && dut.u_core.ccell == 2'd3 && dut.u_core.rtag[3] && dut.avail_RX))
    @(negedge PCLK);
  apb_now(0, A_RX, 0, 0);
  p_feed = 0;
  frames(2);
  sh[1] = st[1];
  while (dut.avail_RX) rd(A_RX);
  // a TAG with reserved bits
  force_cells(130 * 4, 4'b0011);
  frames(1);
  irq_expect(IRQ_RX_ERR);
  // the framer resets: the DUT loses the frame sync and finds it again
  @(negedge PCLK) p_rst = 1; @(negedge PCLK) p_rst = 0;
  wait_status(1, 0, 10);
  irq_expect(IRQ_LOST_SYNC);
  wait_status(3, 3, 60);
  wr(A_CHAN, 0);
  p_rxl = 0; p_txl = 0;

  // ---- DUT as the framer, the peer a device
  p_framer = 0;
  @(negedge PCLK) p_rst = 1; @(negedge PCLK) p_rst = 0;
  wr(A_CFG, cfgw(1, 3, 8'h3C));
  wait (p_sf_locked);
  wr(A_SFSET, 32'hFFFF);
  frames(8 * 3);
  rd(A_STATUS);
  if (rdv[26:11] > 16'h0002) fail($sformatf("count %h did not wrap", rdv[26:11]));
  if (p_sf_count != rdv[26:11]) fail("peer count differs");
  wr(A_SFSET, 32'h0);
  frames(8 * 2);
  // samples DUT -> peer as the framer
  p_rxs = 101; p_rxl = 4; sh[0] = st[0];
  wr(A_CHAN, chanw(101, 4, 1, 0));
  for (int i = 0; i < 3; i++) begin
    poll(A_FLAGS, 1 << FLAG_TX_FULL, 0, 20000);
    sq[0][st[0] % 256] = 32'hA5A5_0000 + i; st[0]++;
    wr(A_TX, 32'hA5A5_0000 + i);
  end
  frames(3);
  if (sh[0] != st[0]) fail("peer missed samples");
  // a bad segment shows in STATUS
  wr(A_CHAN, chanw(96, 1, 1, 0));
  rd(A_STATUS);
  if (!rdv[2]) fail("cfg_err not in STATUS");
  wr(A_CHAN, 0);

  // interrupts: masked, raising irq, cleared one by one
  rd(A_IRQ_STATUS);
  if (rdv[7:0] != 8'hFF) fail($sformatf("IRQ_STATUS %h, expected every bit", rdv));
  if (irq) fail("irq high with every bit masked");
  wr(A_IRQ_ENABLE, IRQ_ALL);
  if (!irq) fail("irq low with every bit enabled");
  for (int b = 0; b < 8; b++) wr(A_IRQ_STATUS, 1 << b);
  rd(A_IRQ_STATUS);
  if (rdv[7:1] != 0) fail($sformatf("IRQ_STATUS %h after clearing", rdv));
  frames(8);
  irq_expect(IRQ_FI);
  if (!irq) fail("irq low with FI pending");
endtask
