// SPDX-License-Identifier: Apache-2.0
// SGMII-specific part of tb/SGMII_apb_tb.sv. The ten-bit interface is
// looped back (rx_code = tx_code), so the PCS synchronises on its own
// stream and auto-negotiates with itself: in 1000BASE-X it sees its own
// abilities, in SGMII mode its own 0x0001 (the PHY's link bit clear, so the
// link stays down). GMII packets sent on gtxd come back on grxd.
// Covered through the registers: LINK, AN and ERR, each raised and cleared
// with a write-1, all three raised while masked, and ERR left pending into
// reset.
bit         lb = 0;                     // loopback on (the line is all zeros before)
always @(negedge PCLK) rx_code = lb ? tx_code : 10'h0;
initial begin gtxd = 0; gtx_en = 0; gtx_er = 0; end
logic [7:0] g_rx [0:255];
int         g_n = 0;
bit         g_er = 0;
always @(negedge PCLK) if (grx_dv) begin g_rx[g_n] = grxd; g_er = g_er | grx_er; g_n++; end
// one packet of n bytes (preamble, SFD, a count) with gtx_er on byte er_at;
// a packet that starts on an odd position loses its first preamble byte
task automatic g_send(input int n, input int er_at = -1);
  logic [7:0] tx [0:255];
  cycles(1);                            // drive on the falling edge
  g_n = 0; g_er = 0;
  for (int i = 0; i < n; i++) begin
    tx[i] = i < 7 ? 8'h55 : i == 7 ? 8'hD5 : 8'(i);
    gtx_en = 1; gtxd = tx[i]; gtx_er = i == er_at;
    cycles(1);
  end
  gtx_en = 0; gtx_er = 0;
  cycles(30);
  if (g_n != n && g_n != n - 1) fail($sformatf("loopback: %0d bytes for %0d", g_n, n));
  else
    for (int j = 1; j <= g_n; j++)
      if (n - j != er_at && g_rx[g_n - j] !== tx[n - j])
        fail($sformatf("loopback byte %0d = %h, expected %h", n - j, g_rx[g_n - j], tx[n - j]));
  if (g_er != (er_at >= 0)) fail($sformatf("loopback grx_er %b", g_er));
endtask

task automatic irq_case(input int bitn);
  rd_exp(A_IRQ_STATUS, 32'(1) << bitn);
  if (!irq) fail("irq low with a status bit set");
  wr(A_IRQ_STATUS, 32'(1) << bitn);
  rd_exp(A_IRQ_STATUS, 0);
endtask

task automatic ip_func;
  rd_exp(A_FLAGS, 0);
  rd_exp(A_STATUS, 32'h10);                     // no sync, speed 1000
  wr(A_IRQ_ENABLE, IRQ_ALL);
  lb = 1;
  // 1000BASE-X: sync, AN with itself, link at 1000 full duplex
  poll(A_STATUS, 32'h3F, 32'h37, 1000);
  rd_exp(A_LP_ABILITY, 32'h41A0);
  rd_exp(A_IRQ_STATUS, (32'(1) << IRQ_LINK) | (32'(1) << IRQ_AN));
  if (!irq) fail("irq low after AN");
  wr(A_IRQ_STATUS, 32'(1) << IRQ_LINK);
  irq_case(IRQ_AN);
  // packets loop back; /V/ comes back as grx_er
  g_send(64); g_send(31); g_send(40, 20);
  irq_case(IRQ_ERR);
  // every ability bit, then SGMII mode with AN off reads speed / duplex
  // from that word
  wr(A_CTRL, (32'hFFFF << 2) | 32'h1);
  wr(A_CMD, 1);
  poll(A_STATUS, 32'h3F, 32'h37, 1000);
  rd_exp(A_LP_ABILITY, 32'hFFFF);
  wr(A_CTRL, (32'hFFFF << 2) | 32'h2);
  rd_exp(A_STATUS, 32'h3D);
  wr(A_IRQ_STATUS, IRQ_ALL);
  // half duplex advertised, restarted from CMD
  wr(A_CTRL, (32'h0040 << 2) | 32'h1);
  wr(A_CMD, 1);
  poll(A_STATUS, 32'h3F, 32'h17, 1000);
  rd_exp(A_LP_ABILITY, 32'h4040);
  wr(A_IRQ_STATUS, IRQ_ALL);
  // SGMII: its own 0x0001 has the PHY's link bit clear
  wr(A_CTRL, 32'h3);
  wr(A_CMD, 1);
  poll(A_STATUS, 32'h3F, 32'h03, 1000);
  rd_exp(A_LP_ABILITY, 32'h4001);
  // AN disabled: the link is up with sync alone
  wr(A_IRQ_STATUS, IRQ_ALL);
  wr(A_CTRL, 32'h0);
  rd_exp(A_STATUS, 32'h15);
  irq_case(IRQ_LINK);
  // masked: pending, irq low; then left pending into reset
  wr(A_IRQ_ENABLE, 0);
  wr(A_CTRL, 32'h681);
  poll(A_STATUS, 32'h3F, 32'h37, 1000);
  g_send(20, 9);
  if (irq) fail("irq with LINK, AN and ERR masked");
  rd_exp(A_IRQ_STATUS, IRQ_ALL);
  wr(A_IRQ_ENABLE, IRQ_ALL);
  if (!irq) fail("irq low after unmasking");
  wr(A_IRQ_STATUS, (32'(1) << IRQ_LINK) | (32'(1) << IRQ_AN));
  rd_exp(A_IRQ_STATUS, 32'(1) << IRQ_ERR);
endtask
