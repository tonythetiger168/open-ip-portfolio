// SPDX-License-Identifier: Apache-2.0
// GbE_DMA-specific part of tb/GbE_DMA_apb_tb.sv: a behavioural AXI4 memory
// on the m_* pins and the GMII looped back (gtxd -> grxd; grx_er can be
// forced by the TB). Through the registers:
// - rings of 4 TX and 4 RX descriptors, six frames of 20..300 bytes to the
//   station address sent and received (RX buffer = the TX frame, zero padded
//   to 60 bytes; write-backs; HEAD; FRAMES; TX / RX interrupts);
// - 12 frames with the rings and buffers moved to random addresses, some
//   with the interrupts masked;
// - a PAUSE frame received with PAUSE_EN (STATUS.tx_paused holds the next
//   frame), a frame with grx_er (phy_err in the RX write-back);
// - a frame with no RX descriptor free waiting in the FIFO until one is
//   posted, RX_EN off (RX_DROP, DROP interrupt);
// - Verilator only: rings of 34000 entries, 33000 frames with RX_EN off
//   (TX_HEAD, TX FRAMES and RX_DROP above 0x8000), then 2100 looped back;
// - AXI errors on a TX descriptor read and an RX buffer write (STATUS.err,
//   ERR interrupt, CMD.clr_err).
// The full ring, FIFO and truncation checks are in tb/GbE_DMA_tb.sv.
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
logic inj_er = 0;
int unsigned pcyc = 0;
always @(posedge PCLK) pcyc++;
int last_tx = -1, t_move = 0;
assign grxd = gtxd;
assign grx_dv = gtx_en;
assign grx_er = gtx_er | inj_er;
// ring bases, frame buffers (one per ring entry modulo 4)
logic [31:0] txr = 32'h0000_1000, rxr = 32'h0000_2000;
logic [31:0] txb = 32'h0000_4000, rxb = 32'h0000_8000;
logic [7:0]  fr [0:23][0:299];
int          fl [0:23];
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
  axm.poke(rxr + 32'(8 * (i % 4)), rxb + 32'(i % 4) * 32'h400);
  axm.poke(rxr + 32'(8 * (i % 4)) + 4, 32'd512);
  wr(A_RX_TAIL, 32'((i + 1) % 4));
endtask
task automatic send(input int i);
  logic [31:0] b;
  b = txb + 32'(i % 4) * 32'h400;
  for (int k = 0; k < fl[i]; k++) poke_byte(b + 32'(k), fr[i][k]);
  axm.poke(txr + 32'(8 * (i % 4)), b); axm.poke(txr + 32'(8 * (i % 4)) + 4, 32'(fl[i]));
  wr(A_TX_TAIL, 32'((i + 1) % 4));
endtask
task automatic check_rx(input int i, input logic [3:0] stat = 4'h0);
  logic [31:0] b, w;
  int n;
  b = rxb + 32'(i % 4) * 32'h400; n = fl[i] < 60 ? 60 : fl[i];
  w = axm.peek(rxr + 32'(8 * (i % 4)) + 4);
  if (w !== {12'h800, stat, 16'(n)}) fail($sformatf("RX write-back %0d: %h", i, w));
  for (int k = 0; k < n; k++)
    if (peek_byte(b + 32'(k)) !== (k < fl[i] ? fr[i][k] : 8'h00)) begin fail($sformatf("frame %0d byte %0d", i, k)); k = n; end
  w = axm.peek(txr + 32'(8 * (i % 4)) + 4);
  if (w !== {16'h8000, 16'(fl[i])}) fail($sformatf("TX write-back %0d: %h", i, w));
endtask
// frame i sent and received, its RX descriptor posted first
task automatic loop1(input int i, input logic [3:0] stat = 4'h0);
  post_rx(i);
  send(i);
  poll(A_HEAD, 32'hFFFF_FFFF, {16'((i + 1) % 4), 16'((i + 1) % 4)}, 20000);
  check_rx(i, stat);
  rd(A_IRQ_STATUS);
  if (rdv[3:0] !== 4'h3) fail($sformatf("frame %0d: IRQ_STATUS %h", i, rdv));
  wr(A_IRQ_STATUS, 32'hF);
endtask
// wait for HEAD during the soak, with a progress line every 1M clocks
task automatic soak_wait(input logic [31:0] m, input logic [31:0] v);
  int t0, last;
  t0 = pcyc; last = -1;
  do begin
    cycles(500); rd(A_HEAD);
    if ((pcyc - t0) / 1000000 != last) begin last = (pcyc - t0) / 1000000; $display("soak: HEAD %h after %0d clocks", rdv, pcyc - t0); end
    if (rdv[15:0] == last_tx && pcyc - t_move > 200000) begin fail($sformatf("soak stalled at HEAD %h", rdv)); return; end
    if (rdv[15:0] != last_tx) begin last_tx = rdv[15:0]; t_move = pcyc; end
  end while ((rdv & m) != v);
endtask
task automatic ip_func;
  logic [47:0] mac;
  int th, rh, tn;
  mac = 48'h02_12_34_56_78_9A;
  for (int i = 0; i < 24; i++) begin
    fl[i] = (i == 1) ? 20 : 60 + $urandom % 240;
    for (int k = 0; k < 300; k++) fr[i][k] = (k < 6) ? mac[47 - 8 * k -: 8] : 8'($urandom);
  end
  wr(A_MAC0, mac[31:0]); wr(A_MAC1, {16'd0, mac[47:32]});
  wr(A_TX_BASE, txr); wr(A_TX_NUM, 4); wr(A_RX_BASE, rxr); wr(A_RX_NUM, 4);
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
  // rings and buffers anywhere in memory: four 256 KB quarters of one 1 MB
  // region in a random order (no aliasing in the memory model)
  for (int j = 0; j < 12; j++) begin
    logic [31:0] h;
    logic [1:0]  q [4];
    h = $urandom & 32'hFFF0_0000;
    for (int i = 0; i < 4; i++) q[i] = 2'(i);
    for (int i = 3; i > 0; i--) begin
      int k; logic [1:0] x;
      k = $urandom % (i + 1); x = q[i]; q[i] = q[k]; q[k] = x;
    end
    txr = h | {12'd0, q[0], 18'd0} | 32'(($urandom % 60000) * 4);
    rxr = h | {12'd0, q[1], 18'd0} | 32'(($urandom % 60000) * 4);
    txb = h | {12'd0, q[2], 18'd0} | 32'(($urandom % 60000) * 4);
    rxb = h | {12'd0, q[3], 18'd0} | 32'(($urandom % 60000) * 4);
    wr(A_TX_BASE, txr); wr(A_RX_BASE, rxr);
    wr(A_IRQ_ENABLE, (j % 3 == 2) ? 32'h0 : 32'hF);
    loop1(6 + j);
  end
  rd_exp(A_FRAMES, {16'd18, 16'd18});
  rd_exp(A_FLAGS, 0);
  wr(A_IRQ_ENABLE, 32'hF);
  // PAUSE frame (quanta 8, PAUSE_EN): the next frame waits while tx_paused
  wr(A_CTRL, {23'd0, 5'd1, 1'b1, 1'b0, 1'b1, 1'b1});
  fl[18] = 60;
  begin
    logic [7:0] p [18];
    p = '{8'h01, 8'h80, 8'hC2, 8'h00, 8'h00, 8'h01, 8'h02, 8'h00, 8'h00, 8'h00, 8'h00, 8'h01,
          8'h88, 8'h08, 8'h00, 8'h01, 8'h00, 8'h08};
    for (int k = 0; k < 60; k++) fr[18][k] = (k < 18) ? p[k] : 8'h00;
  end
  loop1(18, 4'h8);
  rd(A_STATUS); if (rdv[1] !== 1'b1) fail("STATUS.tx_paused low after a PAUSE frame");
  post_rx(19); send(19);
  cycles(200);
  rd(A_HEAD); if (rdv[15:0] !== 16'd3) fail("frame sent during a PAUSE");
  poll(A_STATUS, 32'h2, 32'h0, 4000);
  poll(A_HEAD, 32'hFFFF_FFFF, {16'd0, 16'd0}, 20000);
  check_rx(19);
  wr(A_IRQ_STATUS, 32'hF);
  wr(A_CTRL, {23'd0, 5'd1, 1'b0, 1'b0, 1'b1, 1'b1});
  // grx_er during a frame: phy_err
  post_rx(20); send(20);
  wait (gtx_en === 1'b1); cycles(40);
  inj_er = 1; cycles(2); inj_er = 0;
  poll(A_HEAD, 32'hFFFF_FFFF, {16'd1, 16'd1}, 20000);
  check_rx(20, 4'h4);
  wr(A_IRQ_STATUS, 32'hF);
  // no RX descriptor free: the frame waits in the FIFO
  send(21);
  cycles(3000);
  rd(A_HEAD); if (rdv[31:16] != 16'd1) fail("frame stored without a descriptor");
  post_rx(21);
  poll(A_HEAD, 32'hFFFF_0000, {16'd2, 16'd0}, 2000);
  check_rx(21);
  wr(A_IRQ_STATUS, 32'hF);
  // RX_EN off: dropped (the interrupts masked)
  wr(A_IRQ_ENABLE, 32'h0);
  wr(A_CTRL, {23'd0, 5'd1, 1'b0, 1'b0, 1'b0, 1'b1});
  send(22);
  cycles(3000);
  rd_exp(A_RX_DROP, 1);
  rd(A_IRQ_STATUS); if (!rdv[2]) fail("no DROP interrupt");
  if (irq !== 1'b0) fail("irq high with the interrupts masked");
  wr(A_IRQ_STATUS, 32'hF);
  wr(A_IRQ_ENABLE, 32'h4);                               // DROP alone drives the pin
  send(23);
  cycles(3000);
  rd_exp(A_RX_DROP, 2);
  if (irq !== 1'b1) fail("irq low with DROP pending and enabled");
  wr(A_IRQ_STATUS, 32'hF);
  wr(A_IRQ_ENABLE, 32'hF);
  wr(A_CTRL, {23'd0, 5'd1, 1'b0, 1'b0, 1'b1, 1'b1});
  // heads: TX 0, RX 2
`ifdef VERILATOR
  // rings of 34000 entries in one 1 MB region, every entry a 60-byte frame
  // to the station address from one buffer, into one RX buffer
  begin
    localparam int N = 34000;
    logic [31:0] r0;
    r0 = 32'h0300_0000;
    txr = r0; rxr = r0 + 32'h4_4000; txb = r0 + 32'h9_0000; rxb = r0 + 32'h9_8000;   // rings of 0x4_2680 bytes
    for (int k = 0; k < 60; k++) poke_byte(txb + 32'(k), fr[0][k]);
    for (int e = 0; e < N; e++) begin
      axm.poke(txr + 32'(8 * e), txb); axm.poke(txr + 32'(8 * e) + 4, 32'd60);
      axm.poke(rxr + 32'(8 * e), rxb); axm.poke(rxr + 32'(8 * e) + 4, 32'd64);
    end
    wr(A_IRQ_ENABLE, 0);
    axm.stall = 0;                       // the engine keeps up with one byte per clock
    wr(A_TX_BASE, txr); wr(A_RX_BASE, rxr); wr(A_TX_NUM, N); wr(A_RX_NUM, N);
    // 33000 frames with RX_EN off, one byte per clock
    wr(A_CTRL, {23'd0, 5'd0, 1'b0, 1'b0, 1'b0, 1'b1});
    th = 33000; wr(A_TX_TAIL, th);
    soak_wait(32'h0000_FFFF, 32'(th));
    rd(A_RX_DROP); if (rdv < 33000) fail($sformatf("RX_DROP %0d after 33000 frames with RX_EN off", rdv));
    // 2100 frames looped back
    for (int e = 0; e < N; e++) axm.poke(txr + 32'(8 * e) + 4, 32'd60);
    wr(A_CTRL, {23'd0, 5'd0, 1'b0, 1'b0, 1'b1, 1'b1});
    rh = (2 + 2200) % N; wr(A_RX_TAIL, rh);
    th = (th + 2100) % N; wr(A_TX_TAIL, th);
    soak_wait(32'hFFFF_FFFF, {16'((2 + 2100) % N), 16'(th)});
    rd(A_FRAMES); if (rdv[31:16] != 16'(18 + 2 + 2 + 2100)) fail($sformatf("FRAMES %h after the loop-back soak", rdv));
    wr(A_IRQ_STATUS, 32'hF);
    wr(A_IRQ_ENABLE, 32'hF);
    wr(A_CTRL, {23'd0, 5'd1, 1'b0, 1'b0, 1'b1, 1'b1});
    axm.stall = 1;
    tn = N;
  end
`else
  th = 0; rh = 2; tn = 4;
`endif
  // AXI error on the next TX descriptor (the interrupts masked)
  wr(A_IRQ_ENABLE, 32'h0);
  for (int k = 0; k < 60; k++) poke_byte(txb + 32'(k), fr[0][k]);
  axm.poke(txr + 32'(8 * th), txb); axm.poke(txr + 32'(8 * th) + 4, 32'd60);
  axm.err_lo = txr + 32'(8 * th); axm.err_hi = txr + 32'(8 * th) + 8;
  th = (th + 1) % tn; wr(A_TX_TAIL, th);
  cycles(300);
  rd(A_STATUS); if (!rdv[0]) fail("STATUS.err low after an AXI read error");
  rd(A_IRQ_STATUS); if (!rdv[3]) fail("no ERR interrupt");
  if (irq !== 1'b0) fail("irq high with the interrupts masked");
  wr(A_CMD, 32'h1);
  rd(A_STATUS); if (rdv[0]) fail("CMD.clr_err did not clear STATUS.err");
  axm.err_lo = '1; axm.err_hi = '1;
  wr(A_IRQ_STATUS, 32'hF);
  wr(A_IRQ_ENABLE, 32'hF);
  if (axm.errors != 0) fail("AXI rule violations");
  // AXI error on an RX buffer write, left pending into the final reset
  begin
    logic [31:0] h;
    rd(A_HEAD); h = rdv;
    axm.poke(rxr + 32'(8 * h[31:16]), rxb); axm.poke(rxr + 32'(8 * h[31:16]) + 4, 32'd512);
    axm.err_lo = rxb; axm.err_hi = rxb + 4;
    wr(A_RX_TAIL, (h[31:16] + 1) % tn);
    axm.poke(txr + 32'(8 * h[15:0]), txb); axm.poke(txr + 32'(8 * h[15:0]) + 4, 32'd60);
    wr(A_TX_TAIL, (h[15:0] + 1) % tn);
    poll(A_STATUS, 32'h1, 32'h1, 20000);
    rd(A_IRQ_STATUS); if (!rdv[3]) fail("no ERR interrupt after an AXI write error");
  end
  wr(A_CTRL, 0);
endtask
`include "soc_ss_axi_mem.svh"
