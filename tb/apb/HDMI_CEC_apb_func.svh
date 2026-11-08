// SPDX-License-Identifier: Apache-2.0
// HDMI_CEC-specific part of tb/HDMI_CEC_apb_tb.sv. An soc_ss_axi_mem
// subordinate sits on the AXI4 manager pins m_*; the CEC line is modelled as
// open drain (cec_in low when the core or the TB pulls it). Covered through
// the registers: a directed message received and ACKed by the core (RX slot
// in memory, RX_WR, RX_CNT, RX interrupt), a message to another address
// (not stored), RX_RD / ring wrap, a broadcast sent by the core (TX OK), a
// directed message nobody ACKs (TX NACK), TX_DONE interrupts, ERR on an AXI
// read error of the TX message.
`include "apb/tv_apb_common.svh"

logic tb_low = 0;
assign cec_in = !(cec_oe_low || tb_low);
localparam int CEC_TPC = 2;                           // TICK_DIV 1
task automatic c_ticks(input int t); repeat (t * CEC_TPC) @(negedge PCLK); endtask
// one bit from the TB; smp = line level at the sample point
task automatic c_bit(input bit v, output bit smp);
  int lo;
  lo = v ? 12 : 30;
  tb_low = 1; c_ticks(lo); tb_low = 0;
  if (lo < 21) begin c_ticks(21 - lo); smp = cec_in; c_ticks(27); end
  else begin smp = 0; c_ticks(48 - lo); end
endtask
bit c_acks [8];
// bytes b[7:0] first
task automatic c_send(input logic [31:0] b, input int n);
  bit s;
  tb_low = 1; c_ticks(74); tb_low = 0; c_ticks(16);
  for (int i = 0; i < n; i++) begin
    logic [7:0] x;
    x = b[8 * i +: 8];
    for (int j = 7; j >= 0; j--) c_bit(x[j], s);
    c_bit(i == n - 1, s);
    c_bit(1, s);
    c_acks[i] = s;
  end
  c_ticks(60);
endtask

task automatic ip_func;
  logic [31:0] rxb, txa;
  rxb = 32'h8000_0FC0; txa = 32'h0001_0000;           // RX slots cross a 4 KB boundary
  wr(A_TIMING, {6'd0, 10'd7, 16'(CEC_TPC - 1)});       // SFT 7 ticks
  wr(A_RX_BASE, rxb); wr(A_RX_RING, {8'd0, 8'd2});
  wr(A_CTRL, 32'h1 | (32'h4 << 1));                    // LA 4
  c_ticks(20);
  // directed to 4 from 5: stored and ACKed
  c_send(32'h0010_8254, 3);
  for (int i = 0; i < 3; i++) if (c_acks[i] !== 1'b0) fail($sformatf("block %0d not ACKed", i));
  cycles(30);
  if (mem.peek(rxb) !== {16'b0, 5'b0, 1'b0, 1'b1, 1'b0, 3'b0, 5'd3}) fail($sformatf("RX header %h", mem.peek(rxb)));
  if (mem.peek(rxb + 4) !== 32'h0010_8254) fail($sformatf("RX bytes %h", mem.peek(rxb + 4)));
  rd_exp(A_RX_WR, 1);
  tv_irq(IRQ_RX, "message received");
  // to 6: not for us, not ACKed, not stored
  c_send(32'h0000_3656, 2);
  if (c_acks[0] !== 1'b1) fail("message to another address ACKed");
  rd_exp(A_RX_WR, 1);
  tv_no_irq(IRQ_RX, "message to another address");
  // second slot, then the ring is full until RX_RD moves
  wr(A_RX_RING, {8'd1, 8'd2});
  c_send(32'h0000_445F, 2);                           // broadcast
  cycles(30);
  rd_exp(A_RX_WR, 0);
  if (mem.peek(rxb + 32) !== {16'b0, 5'b0, 1'b1, 1'b0, 1'b0, 3'b0, 5'd2}) fail($sformatf("broadcast RX header %h", mem.peek(rxb + 32)));
  rd_exp(A_RX_CNT, 2);
  wr(A_IRQ_STATUS, IRQ_ALL);
  // TX broadcast from 4: nobody objects, OK
  mem.poke(txa, 2); mem.poke(txa + 4, 32'h0000_364F); mem.poke(txa + 8, 0); mem.poke(txa + 12, 0); mem.poke(txa + 16, 0);
  wr(A_TX_ADDR, txa);
  wr(A_CMD, 1);
  rd(A_TX);
  if (rdv[4] !== 1'b1) fail("TX not busy after CMD.tx_start");
  poll(A_TX, 32'h10, 32'h0, 3000);
  rd_exp(A_TX, 32'h1);
  tv_irq(IRQ_TX_DONE, "broadcast sent");
  // TX directed to 9: nobody ACKs
  mem.poke(txa + 4, 32'h0000_0049);
  mem.poke(txa, 1);
  wr(A_CMD, 1);
  poll(A_TX, 32'h10, 32'h0, 3000);
  rd(A_TX);
  if (rdv[3:0] !== 4'b0010) fail($sformatf("TX status %b, expected NACK", rdv[3:0]));
  tv_irq(IRQ_TX_DONE, "NACK");
  // AXI read error fetching the message
  mem.err_lo = txa; mem.err_hi = txa + 4;
  wr(A_CMD, 1);
  poll(A_TX, 32'h10, 32'h0, 3000);
  rd(A_TX);
  if (rdv[3] !== 1'b1) fail($sformatf("TX status %b, expected ERR", rdv[3:0]));
  rd(A_IRQ_STATUS);
  if (rdv[IRQ_ERR] !== 1'b1) fail("no ERR interrupt");
  wr(A_IRQ_STATUS, IRQ_ALL);
  mem.err_lo = '1; mem.err_hi = '1;
  if (mem.errors != 0) fail("AXI rule violations");
endtask
