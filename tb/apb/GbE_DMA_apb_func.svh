// SPDX-License-Identifier: Apache-2.0
// GbE_DMA-specific part of tb/GbE_DMA_apb_tb.sv: a behavioural AXI4 memory
// on the m_* pins and the GMII looped back (gtxd -> grxd). Through the
// registers: rings of 4 TX and 4 RX descriptors, six frames of 20..300
// bytes to the station address sent and received (RX buffer = the TX frame,
// zero padded to 60 bytes; write-backs; HEAD; FRAMES; TX / RX interrupts),
// a frame with no RX descriptor free waiting in the FIFO until one is
// posted, RX_EN off (RX_DROP, DROP interrupt), an AXI error on a TX
// descriptor (STATUS.err, ERR interrupt, CMD.clr_err). The full ring, FIFO
// and truncation checks are in tb/GbE_DMA_tb.sv.
soc_ss_axi_mem axm (
  .clk(PCLK), .rst_n(PRESETN),
  .awid(m_awid), .awaddr(m_awaddr), .awlen(m_awlen), .awsize(m_awsize), .awburst(m_awburst),
  .awprot(m_awprot), .awvalid(m_awvalid), .awready(m_awready),
  .wdata(m_wdata), .wstrb(m_wstrb), .wlast(m_wlast), .wvalid(m_wvalid), .wready(m_wready),
  .bid(m_bid), .bresp(m_bresp), .bvalid(m_bvalid), .bready(m_bready),
  .arid(m_arid), .araddr(m_araddr), .arlen(m_arlen), .arsize(m_arsize), .arburst(m_arburst),
  .arprot(m_arprot), .arvalid(m_arvalid), .arready(m_arready),
  .rid(m_rid), .rdata(m_rdata), .rresp(m_rresp), .rlast(m_rlast), .rvalid(m_rvalid), .rready(m_rready)
);
assign grxd = gtxd;
assign grx_dv = gtx_en;
assign grx_er = gtx_er;
localparam logic [31:0] TXR = 32'h0000_1000, RXR = 32'h0000_2000;
logic [7:0] fr [0:7][0:299];
int         fl [0:7];
function automatic void poke_byte(input logic [31:0] a, input logic [7:0] b);
  logic [31:0] w;
  w = axm.peek({a[31:2], 2'b00}); w[8 * a[1:0] +: 8] = b; axm.poke({a[31:2], 2'b00}, w);
endfunction
function automatic logic [7:0] peek_byte(input logic [31:0] a);
  logic [31:0] w;
  w = axm.peek({a[31:2], 2'b00}); return w[8 * a[1:0] +: 8];
endfunction
task automatic wait_irq(input int n);
  int k;
  k = 0;
  while (!irq && k < n) begin @(negedge PCLK); k++; end
endtask
task automatic post_rx(input int i);
  axm.poke(RXR + 32'(8 * (i % 4)), 32'h0000_8000 + 32'(i % 4) * 32'h400);
  axm.poke(RXR + 32'(8 * (i % 4)) + 4, 32'd512);
  wr(A_RX_TAIL, 32'((i + 1) % 4));
endtask
task automatic send(input int i);
  logic [31:0] b;
  b = 32'h0000_4000 + 32'(i % 4) * 32'h400;
  for (int k = 0; k < fl[i]; k++) poke_byte(b + 32'(k), fr[i][k]);
  axm.poke(TXR + 32'(8 * (i % 4)), b); axm.poke(TXR + 32'(8 * (i % 4)) + 4, 32'(fl[i]));
  wr(A_TX_TAIL, 32'((i + 1) % 4));
endtask
task automatic check_rx(input int i);
  logic [31:0] b, w;
  int n;
  b = 32'h0000_8000 + 32'(i % 4) * 32'h400; n = fl[i] < 60 ? 60 : fl[i];
  w = axm.peek(RXR + 32'(8 * (i % 4)) + 4);
  if (w !== {16'h8000, 16'(n)}) fail($sformatf("RX write-back %0d: %h", i, w));
  for (int k = 0; k < n; k++)
    if (peek_byte(b + 32'(k)) !== (k < fl[i] ? fr[i][k] : 8'h00)) begin fail($sformatf("frame %0d byte %0d", i, k)); break; end
  w = axm.peek(TXR + 32'(8 * (i % 4)) + 4);
  if (w !== {16'h8000, 16'(fl[i])}) fail($sformatf("TX write-back %0d: %h", i, w));
endtask
task automatic ip_func;
  logic [47:0] mac;
  mac = 48'h02_12_34_56_78_9A;
  for (int i = 0; i < 8; i++) begin
    fl[i] = (i == 1) ? 20 : 60 + $urandom % 240;
    for (int k = 0; k < 300; k++) fr[i][k] = (k < 6) ? mac[47 - 8 * k -: 8] : 8'($urandom);
  end
  wr(A_MAC0, mac[31:0]); wr(A_MAC1, {16'd0, mac[47:32]});
  wr(A_TX_BASE, TXR); wr(A_TX_NUM, 4); wr(A_RX_BASE, RXR); wr(A_RX_NUM, 4);
  wr(A_CTRL, {23'd0, 5'd1, 1'b0, 1'b0, 1'b1, 1'b1});
  wr(A_IRQ_ENABLE, 32'hF);
  for (int i = 0; i < 6; i++) begin
    post_rx(i);
    send(i);
    // TX, then RX interrupt
    for (int e = 0; e < 2; e++) begin
      wait_irq(20000);
      rd(A_IRQ_STATUS);
      wr(A_IRQ_STATUS, rdv);
      if (rdv[3:2] != 0) fail($sformatf("frame %0d: IRQ_STATUS %h", i, rdv));
      rd(A_HEAD);
      if (rdv[31:16] == 16'((i + 1) % 4) && rdv[15:0] == 16'((i + 1) % 4)) break;
    end
    poll(A_HEAD, 32'hFFFF_FFFF, {16'((i + 1) % 4), 16'((i + 1) % 4)}, 2000);
    check_rx(i);
  end
  rd_exp(A_FRAMES, {16'd6, 16'd6});
  // no RX descriptor free: the frame waits in the FIFO
  send(6);
  cycles(3000);
  rd(A_HEAD); if (rdv[31:16] != 16'd2) fail("frame stored without a descriptor");
  post_rx(6);
  poll(A_HEAD, 32'hFFFF_0000, {16'd3, 16'd0}, 2000);
  check_rx(6);
  wr(A_IRQ_STATUS, 32'hF);
  // RX_EN off: dropped
  wr(A_CTRL, {23'd0, 5'd1, 1'b0, 1'b0, 1'b0, 1'b1});
  send(7);
  cycles(3000);
  rd_exp(A_RX_DROP, 1);
  rd(A_IRQ_STATUS); if (!rdv[2]) fail("no DROP interrupt");
  wr(A_IRQ_STATUS, 32'hF);
  // AXI error on the next TX descriptor
  axm.err_lo = TXR; axm.err_hi = TXR + 8;
  wr(A_TX_TAIL, 32'd1);
  cycles(300);
  rd(A_STATUS); if (!rdv[0]) fail("STATUS.err low after an AXI error");
  rd(A_IRQ_STATUS); if (!rdv[3]) fail("no ERR interrupt");
  wr(A_CMD, 32'h1);
  rd(A_STATUS); if (rdv[0]) fail("CMD.clr_err did not clear STATUS.err");
  axm.err_lo = '1; axm.err_hi = '1;
  wr(A_IRQ_STATUS, 32'hF); wr(A_IRQ_ENABLE, 0); wr(A_CTRL, 0);
  if (axm.errors != 0) fail("AXI rule violations");
endtask
