// SPDX-License-Identifier: Apache-2.0
// JESD204C-specific part of tb/JESD204C_apb_tb.sv. A second JESD204C_top
// (the peer, driven directly with random blocks and commands) is
// cross-connected to the DUT's lane pins; the line into the DUT can slip by
// a bit or have one bit flipped.
// Covered through the registers: blocks written through TX0 / TX1 checked
// at the peer, blocks read through RX0..RX2 and multiblocks through MB
// checked against what the peer sent, CMD to the peer, TX written while
// full, underruns, RX and MB overflowing and popped as they capture, a CRC
// error, sync header and extended multiblock errors, STATUS, every stream
// event and interrupt bit.
wire         p_tx;
logic [7:0]  sl = 0;                    // line into the DUT, slip by a bit
logic        slip = 0, lflip = 0, kill = 0;
always @(posedge PCLK) sl <= {sl[6:0], p_tx};
assign rx_p = kill ? 1'b0 : (slip ? sl[1] : sl[0]) ^ lflip;

// peer
logic        p_tx_valid = 1;
logic [63:0] p_tx_data = 0;
logic [6:0]  p_tx_cmd = 0;
logic [3:0]  p_cfg_e = 0;
wire         p_tx_ready, p_tx_mb_start, p_tx_underrun, p_rx_valid, p_rx_mb_start, p_rx_emb_start, p_rx_mb_valid;
wire         p_rx_crc_err, p_sh_lock, p_emb_lock, p_err_sh, p_err_emb;
wire  [63:0] p_rx_data;
wire  [6:0]  p_rx_cmd;
JESD204C_top u_peer (
  .clk(PCLK), .rst_n(PRESETN), .tx_p(p_tx), .rx_p(tx_p), .cfg_e(p_cfg_e),
  .tx_valid(p_tx_valid), .tx_ready(p_tx_ready), .tx_data(p_tx_data), .tx_cmd(p_tx_cmd),
  .tx_mb_start(p_tx_mb_start), .tx_underrun(p_tx_underrun), .rx_valid(p_rx_valid), .rx_data(p_rx_data),
  .rx_mb_start(p_rx_mb_start), .rx_emb_start(p_rx_emb_start), .rx_mb_valid(p_rx_mb_valid), .rx_cmd(p_rx_cmd),
  .rx_crc_err(p_rx_crc_err), .sh_lock(p_sh_lock), .emb_lock(p_emb_lock), .err_sh(p_err_sh), .err_emb(p_err_emb));

// the peer sends a new random block each time one is taken, a new command
// each multiblock; it records them
logic [63:0] ps [0:4095];               // blocks sent
logic [6:0]  pc [0:4095];               // command of each block's multiblock
int          psn = 0;
logic [6:0]  p_cmd_cur = 0;
always @(posedge PCLK) if (PRESETN && u_peer.tc == 7'd0) begin
  if (u_peer.tj == 5'd0) p_cmd_cur = p_tx_cmd;
  ps[psn % 4096] = p_tx_data; pc[psn % 4096] = p_cmd_cur; psn++;
end
always @(negedge PCLK) begin
  if (p_tx_ready || !PRESETN) p_tx_data = {$urandom, $urandom};
  if (p_tx_mb_start) p_tx_cmd = $urandom;
end

// what the peer must receive from the DUT: the blocks the host wrote, in
// order, from the first one it sees (zeros in between are underruns)
logic [63:0] hq [0:1023];
int          hqh = 0, hqt = 0;
always @(negedge PCLK) if (PRESETN && p_rx_valid && p_rx_data != 64'd0 && hqh != hqt) begin
  if (p_rx_data !== hq[hqh % 1024]) fail($sformatf("peer: block %h, expected %h", p_rx_data, hq[hqh % 1024]));
  hqh++;
end
// the command: the one in CMD, or the one before it while it changes
logic [6:0] dut_cmd = 0, dut_cmd_old = 0;
always @(negedge PCLK) if (PRESETN && p_rx_mb_valid)
  if (p_rx_cmd !== dut_cmd && p_rx_cmd !== dut_cmd_old || p_rx_crc_err)
    fail($sformatf("peer: command %h crc_err %b, expected %h", p_rx_cmd, p_rx_crc_err, dut_cmd));
task automatic set_cmd(input logic [6:0] c);
  dut_cmd_old = dut_cmd; dut_cmd = c;
  wr(A_CMD, c);
endtask

task automatic irq_expect(input int b);
  rd(A_IRQ_STATUS);
  if (!rdv[b]) fail($sformatf("IRQ bit %0d not set (%h)", b, rdv));
endtask
task automatic mbs(input int n);
  repeat (n * 2112) @(negedge PCLK);
endtask
// the host sends n blocks back to back
task automatic h_send(input int n);
  logic [63:0] d;
  for (int i = 0; i < n; i++) begin
    d = {$urandom, $urandom};
    if (d == 64'd0) d = 1;
    hq[hqt % 1024] = d; hqt++;
    @(negedge PCLK);
    while (dut.full_TX) @(negedge PCLK);
    apb_now(1, A_TX0, d[31:0], 4'hF);
    @(negedge PCLK);
    apb_now(1, A_TX1, d[63:32], 4'hF);
  end
endtask
// the host reads n blocks; the first is looked up among those the peer sent
int pr = -1;
task automatic h_recv(input int n);
  logic [65:0] v;
  for (int i = 0; i < n; i++) begin
    @(negedge PCLK);
    while (!dut.avail_RX) @(negedge PCLK);
    apb_now(0, A_RX0, 0, 0); v[31:0] = rdv;
    @(negedge PCLK);
    apb_now(0, A_RX1, 0, 0); v[63:32] = rdv;
    @(negedge PCLK);
    apb_now(0, A_RX2, 0, 0); v[65:64] = rdv[1:0];
    if (pr < 0) begin
      pr = psn - 1;
      while (pr >= 0 && psn - pr < 4000 && ps[pr % 4096] !== v[63:0]) pr--;
      if (pr < 0 || ps[pr % 4096] !== v[63:0]) begin fail($sformatf("RX block %h was never sent", v[63:0])); pr = -1; end
    end else if (ps[pr % 4096] !== v[63:0]) fail($sformatf("RX block %h, expected %h", v[63:0], ps[pr % 4096]));
    if (pr >= 0) pr++;
  end
endtask

task automatic ip_func;
  logic [7:0] m;
  wr(A_IRQ_ENABLE, 0);
  wr(A_CFG, 1); p_cfg_e = 1;
  set_cmd(7'h55);
  mbs(8);
  rd(A_STATUS);
  if (rdv[1:0] !== 2'b11) fail($sformatf("STATUS %h, expected both locks", rdv));
  wr(A_IRQ_STATUS, IRQ_ALL);
  // DUT -> peer; CMD changes
  h_send(40);
  set_cmd(7'h2A);
  mbs(2);
  h_send(40);
  irq_expect(IRQ_TX_DONE);
  irq_expect(IRQ_TX_MB);
  irq_expect(IRQ_TX_UNDERRUN);
  // TX1 written while full: TX_OVF (the second block is dropped)
  hq[hqt % 1024] = 64'h0123_4567_89AB_CDEF; hqt++;
  while (dut.full_TX) @(negedge PCLK);
  wr(A_TX0, 32'h89AB_CDEF); wr(A_TX1, 32'h0123_4567);
  wr(A_TX1, 32'hFFFF_FFFF);
  irq_expect(IRQ_TX_OVF);
  mbs(1);
  if (hqh != hqt) fail($sformatf("peer missed %0d blocks", hqt - hqh));
  // peer -> DUT: blocks and multiblocks
  while (dut.avail_RX) rd(A_RX2);
  pr = -1;
  h_recv(70);
  rd(A_MB);
  mbs(1);
  for (int i = 0; i < 3; i++) begin
    while (!dut.avail_MB) @(negedge PCLK);
    rd(A_MB);
    if (rdv[7] !== 1'b0) fail($sformatf("MB %h: CRC error on a clean line", rdv));
  end
  irq_expect(IRQ_RX_OVF);
  irq_expect(IRQ_MB_OVF);
  // RX and MB popped as they capture
  while (!(dut.u_core.rc == 7'd65 && dut.u_core.es == 2'd2 && dut.avail_RX)) @(negedge PCLK);
  apb_now(0, A_RX2, 0, 0);
  while (!(dut.u_core.rc == 7'd65 && dut.u_core.rj == 5'd31 && dut.u_core.es == 2'd2 && dut.avail_MB)) @(negedge PCLK);
  apb_now(0, A_MB, 0, 0);
  mbs(1);
  while (dut.avail_RX) rd(A_RX2);
  rd(A_RX2);                                    // empty: the last block again
  while (dut.avail_MB) rd(A_MB);
  rd(A_MB);
  rd(A_FLAGS);
  // a payload bit flipped: a CRC error
  while (dut.u_core.rc != 7'd30) @(negedge PCLK);
  lflip = 1; @(negedge PCLK); lflip = 0;
  m = 0;
  for (int i = 0; i < 3; i++) begin
    while (!dut.avail_MB) @(negedge PCLK);
    rd(A_MB);
    m |= rdv[7:0];
  end
  if (!m[7]) fail("no CRC error after a flipped bit");
  // cfg_e differs from the peer: ERR_EMB; the line slips a bit: ERR_SH and unlock
  wr(A_CFG, 3);
  mbs(6);
  irq_expect(IRQ_ERR_EMB);
  wr(A_CFG, 1);
  slip = 1;
  mbs(2);
  rd(A_STATUS);
  if (rdv[1] !== 1'b0) fail($sformatf("STATUS %h after a slip", rdv));
  irq_expect(IRQ_ERR_SH);
  mbs(8);
  rd(A_STATUS);
  if (rdv[1:0] !== 2'b11) fail($sformatf("STATUS %h, no relock", rdv));
  irq_expect(IRQ_RX_AVAIL);
  irq_expect(IRQ_MB_AVAIL);

  // interrupts: masked, raising irq, cleared one by one; the line into the
  // DUT goes dead first (no more receive events); the transmitter keeps
  // underrunning and starting multiblocks
  kill = 1;
  mbs(2);
  rd(A_IRQ_STATUS);
  if (rdv[9:0] != 10'h3FF) fail($sformatf("IRQ_STATUS %h, expected every bit", rdv));
  if (irq) fail("irq high with every bit masked");
  wr(A_IRQ_ENABLE, IRQ_ALL);
  if (!irq) fail("irq low with every bit enabled");
  for (int b = 0; b < 10; b++) wr(A_IRQ_STATUS, 1 << b);
  rd(A_IRQ_STATUS);
  if ((rdv[9:0] & ~((1 << IRQ_TX_UNDERRUN) | (1 << IRQ_TX_MB))) != 0) fail($sformatf("IRQ_STATUS %h after clearing", rdv));
  wr(A_IRQ_ENABLE, 1 << IRQ_TX_MB);
  poll(A_IRQ_STATUS, 1 << IRQ_TX_MB, 1 << IRQ_TX_MB, 5000);
  if (!irq) fail("irq low with TX_MB pending");
endtask
