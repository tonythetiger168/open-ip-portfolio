// SPDX-License-Identifier: Apache-2.0
// Ethernet-specific part of tb/Ethernet_apb_tb.sv. A second Ethernet_top
// (the peer, driven directly) is cross-connected to the DUT's GMII pins;
// the TB can take over the DUT's receive lines with an injector.
// Covered through the registers: frames both ways through TX / RX (padded
// and not), a late TX byte (underrun) and a TX write while full, RX
// overflowing and popped as it captures, a PAUSE from the peer
// (STATUS.tx_paused), received CRC, length and grx_er errors, a fragment,
// the station address and promiscuous mode, every stream event and
// interrupt bit.
localparam logic [47:0] DM = 48'h02_DE_AD_BE_EF_01, PM = 48'h02_00_00_00_00_77;
logic        inj = 0, ij_dv = 0, ij_er = 0;
logic [7:0]  ij_d = 0;
wire  [7:0]  p_gtxd;
wire         p_gtx_en, p_gtx_er;
assign grxd = inj ? ij_d : p_gtxd;
assign grx_dv = inj ? ij_dv : p_gtx_en;
assign grx_er = inj ? ij_er : p_gtx_er;

// peer
logic        p_tx_valid = 0, p_tx_last = 0;
logic [7:0]  p_tx_data = 0;
wire         p_tx_ready, p_tx_done, p_tx_underrun, p_tx_paused, p_rx_valid, p_rx_last, p_rx_frag;
wire  [7:0]  p_rx_data;
wire  [3:0]  p_rx_stat;
Ethernet_top u_peer (
  .clk(PCLK), .rst_n(PRESETN), .cfg_div(5'd31), .cfg_mac(PM), .cfg_promisc(1'b0), .cfg_pause_en(1'b1),
  .tx_valid(p_tx_valid), .tx_ready(p_tx_ready), .tx_data(p_tx_data), .tx_last(p_tx_last),
  .tx_done(p_tx_done), .tx_underrun(p_tx_underrun), .tx_paused(p_tx_paused),
  .gtxd(p_gtxd), .gtx_en(p_gtx_en), .gtx_er(p_gtx_er), .grxd(gtxd), .grx_dv(gtx_en), .grx_er(gtx_er),
  .rx_valid(p_rx_valid), .rx_data(p_rx_data), .rx_last(p_rx_last), .rx_stat(p_rx_stat), .rx_frag(p_rx_frag));

function automatic logic [31:0] crc_b(input logic [31:0] c, input logic [7:0] d);
  for (int i = 0; i < 8; i++) c = (c[0] ^ d[i]) ? (c >> 1) ^ 32'hEDB88320 : c >> 1;
  return c;
endfunction

// what the peer should receive: {last, stat, byte}
logic [12:0] pq [0:4095];
int          pqh = 0, pqt = 0;
bit          p_any = 0;                  // accept anything (frames cut by an underrun)
int          p_last_stat = 0;
always @(negedge PCLK) if (PRESETN && p_rx_valid) begin
  if (p_rx_last) p_last_stat = p_rx_stat;
  if (!p_any) begin
    if (pqh == pqt) fail($sformatf("peer: rx byte %h with none expected", p_rx_data));
    else begin
      if ({p_rx_last, p_rx_last ? p_rx_stat : 4'h0, p_rx_data} !== pq[pqh % 4096])
        fail($sformatf("peer: rx %b %h %h, expected %h", p_rx_last, p_rx_stat, p_rx_data, pq[pqh % 4096]));
      pqh++;
    end
  end
end
// peer transmit: frame bytes in pf, sent one per byte time
logic [7:0]  pf [0:2047];
int          pfn = 0, pfi = 0;
bit          p_took = 0;
always @(posedge PCLK) p_took <= p_tx_valid && p_tx_ready;
always @(negedge PCLK) if (PRESETN) begin
  if (p_took) begin pfi++; p_tx_valid = 0; end
  if (pfi < pfn) begin p_tx_valid = 1; p_tx_data = pf[pfi]; p_tx_last = pfi == pfn - 1; end
end

// a frame image: DA, SA, type 0x0800, payload; len bytes
logic [7:0] fr [0:2047];
function automatic void mk_frame(input logic [47:0] da, input logic [47:0] sa, input int len);
  for (int j = 0; j < 6; j++) begin fr[j] = da[47 - 8 * j -: 8]; fr[6 + j] = sa[47 - 8 * j -: 8]; end
  fr[12] = 8'h08; fr[13] = 8'h00;
  for (int j = 14; j < len; j++) fr[j] = $urandom;
endfunction
// the DUT sends fr[0 .. len-1]; the peer expects it padded to 60
task automatic h_send(input int len);
  for (int j = 0; j < (len < 60 ? 60 : len); j++) begin
    pq[pqt % 4096] = {j == (len < 60 ? 60 : len) - 1, 4'h0, j < len ? fr[j] : 8'h00}; pqt++;
  end
  for (int j = 0; j < len; j++) begin
    poll(A_FLAGS, 1 << FLAG_TX_FULL, 0, 20000);
    wr(A_TX, {23'd0, j == len - 1, fr[j]});
  end
  poll(A_IRQ_STATUS, 1 << IRQ_TX_SENT, 1 << IRQ_TX_SENT, 50000);
  wr(A_IRQ_STATUS, 1 << IRQ_TX_SENT);
endtask
// the peer sends fr[0 .. len-1]; the DUT's RX is read byte by byte
task automatic p_send(input int len);
  for (int j = 0; j < len; j++) pf[j] = fr[j];
  pfi = 0; pfn = len;
endtask
task automatic h_recv(input int len, input logic [3:0] stat);
  for (int j = 0; j < len; j++) begin
    poll(A_FLAGS, 1 << FLAG_RX_AVAIL, 1 << FLAG_RX_AVAIL, 50000);
    rd(A_RX);
    if (rdv[7:0] !== fr[j] || rdv[8] !== (j == len - 1) || (j == len - 1 && rdv[12:9] !== stat))
      fail($sformatf("RX byte %0d: %h, expected %h", j, rdv[12:0], {stat, j == len - 1, fr[j]}));
  end
endtask
task automatic irq_expect(input int b);
  rd(A_IRQ_STATUS);
  if (!rdv[b]) fail($sformatf("IRQ bit %0d not set (%h)", b, rdv));
endtask
// the injector: one byte per DUT byte time
task automatic ij_byte(input logic [7:0] d, input bit dv, input bit er);
  @(negedge PCLK);
  while (!dut.u_core.ls) @(negedge PCLK);
  ij_d = d; ij_dv = dv; ij_er = er;
endtask
// fr[0 .. len-1] with preamble and FCS (bad_fcs flips a bit), grx_er on byte er_at
task automatic ij_frame(input int len, input bit bad_fcs, input int er_at);
  logic [31:0] c;
  c = '1;
  for (int j = 0; j < len; j++) c = crc_b(c, fr[j]);
  c = ~c ^ (bad_fcs ? 32'h8000_0000 : 32'h0);
  inj = 1;
  for (int j = 0; j < 7; j++) ij_byte(8'h55, 1, 0);
  ij_byte(8'hD5, 1, 0);
  for (int j = 0; j < len + 4; j++) ij_byte(j < len ? fr[j] : c[8 * (j - len) +: 8], 1, j == er_at);
  for (int j = 0; j < 12; j++) ij_byte(8'h00, 0, 0);
endtask
// ij_frame in the background while the host reads RX
bit ij_go = 0;
int ij_n = 0, ij_e = 0;
bit ij_b = 0;
initial forever begin
  wait (ij_go);
  ij_frame(ij_n, ij_b, ij_e);
  ij_go = 0;
end
task automatic ij_bg(input int len, input bit bad_fcs, input int er_at);
  ij_n = len; ij_b = bad_fcs; ij_e = er_at; ij_go = 1;
endtask
task automatic frame_gap;
  repeat (130 * 32) @(negedge PCLK);            // the longest frame here, and its gap
endtask

task automatic ip_func;
  wr(A_IRQ_ENABLE, 0);
  wr(A_CFG, 32'h5F);                            // div 31, pause_en
  wr(A_MAC0, DM[31:0]); wr(A_MAC1, DM[47:32]);
  frame_gap();
  wr(A_IRQ_STATUS, IRQ_ALL);
  // DUT -> peer: padded, and not
  mk_frame(PM, DM, 20); h_send(20);
  mk_frame(PM, DM, 72); fr[20] = 8'hFF; fr[21] = 8'h00; h_send(72);
  frame_gap();
  if (pqh != pqt) fail("peer missed bytes");
  irq_expect(IRQ_TX_DONE);
  // peer -> DUT
  mk_frame(DM, PM, 64); p_send(64);
  h_recv(64, 4'h0);
  mk_frame(48'hFFFF_FFFF_FFFF, PM, 80); fr[30] = 8'hFF; p_send(80);
  h_recv(80, 4'h0);
  frame_gap();
  // TX written while full (the frame then misses a byte): TX_OVF and TX_UNDERRUN
  p_any = 1;
  mk_frame(PM, DM, 64);
  wr(A_TX, {23'd0, 1'b0, fr[0]});
  wr(A_TX, {23'd0, 1'b0, fr[1]});
  irq_expect(IRQ_TX_OVF);
  for (int j = 1; j < 12; j++) begin poll(A_FLAGS, 1 << FLAG_TX_FULL, 0, 20000); wr(A_TX, {23'd0, 1'b0, fr[j]}); end
  poll(A_IRQ_STATUS, 1 << IRQ_TX_UNDERRUN, 1 << IRQ_TX_UNDERRUN, 50000);
  frame_gap();
  if (p_last_stat[2] !== 1'b1) fail("the peer did not see grx_er after the underrun");
  p_any = 0;
  // RX not read: overflow; then RX popped as it captures
  mk_frame(DM, PM, 64); p_send(64);
  frame_gap();
  irq_expect(IRQ_RX_OVF);
  rd(A_RX);
  mk_frame(DM, PM, 64); p_send(64);
  while (!(dut.u_core.ls && dut.u_core.rs == 3'd2 && grx_dv && dut.u_core.rn == 11'd20 && dut.avail_RX))
    @(negedge PCLK);
  apb_now(0, A_RX, 0, 0);
  frame_gap();
  while (dut.avail_RX) rd(A_RX);
  rd(A_RX);                                     // empty: the last byte again
  // a PAUSE from the peer holds the DUT's transmitter
  mk_frame(48'h0180_C200_0001, PM, 60); fr[12] = 8'h88; fr[13] = 8'h08; fr[14] = 8'h00; fr[15] = 8'h01;
  fr[16] = 8'h00; fr[17] = 8'h03;
  p_send(60);
  h_recv(60, 4'h8);
  poll(A_STATUS, 1, 1, 100);
  poll(A_STATUS, 1, 0, 50000);
  // received errors through the injector: bad FCS, runt, grx_er; a fragment; a station address filter
  mk_frame(DM, PM, 70); ij_bg(70, 1, -1); h_recv(70, 4'h1); wait (!ij_go);
  mk_frame(DM, PM, 40); ij_bg(40, 0, -1); h_recv(40, 4'h2); wait (!ij_go);
  mk_frame(DM, PM, 70); ij_bg(70, 0, 15); h_recv(70, 4'h4); wait (!ij_go);
  ij_byte(8'hD5, 1, 0); ij_byte(8'h01, 1, 0); ij_byte(8'h00, 0, 0);
  irq_expect(IRQ_RX_FRAG);
  mk_frame(48'h02_00_00_00_00_99, PM, 70); ij_frame(70, 0, -1);
  rd(A_FLAGS);
  if (rdv[FLAG_RX_AVAIL]) fail("a frame for another station was kept");
  wr(A_CFG, 32'h7F);                            // promiscuous
  mk_frame(48'h02_00_00_00_00_99, PM, 70); ij_bg(70, 0, -1); h_recv(70, 4'h0); wait (!ij_go);
  wr(A_CFG, 32'h5F);
  inj = 0;
  irq_expect(IRQ_RX_AVAIL);

  // interrupts: masked, raising irq, cleared one by one
  wr(A_IRQ_STATUS, 1 << IRQ_TX_SENT);
  mk_frame(PM, DM, 60); h_send(60);
  wr(A_IRQ_STATUS, 0);
  frame_gap();
  mk_frame(PM, DM, 60);
  for (int j = 0; j < 60; j++) begin pq[pqt % 4096] = {j == 59, 4'h0, fr[j]}; pqt++; end
  for (int j = 0; j < 60; j++) begin poll(A_FLAGS, 1 << FLAG_TX_FULL, 0, 20000); wr(A_TX, {23'd0, j == 59, fr[j]}); end
  poll(A_IRQ_STATUS, 1 << IRQ_TX_SENT, 1 << IRQ_TX_SENT, 50000);
  rd(A_IRQ_STATUS);
  if (rdv[6:0] != 7'h7F) fail($sformatf("IRQ_STATUS %h, expected every bit", rdv));
  if (irq) fail("irq high with every bit masked");
  wr(A_IRQ_ENABLE, IRQ_ALL);
  if (!irq) fail("irq low with every bit enabled");
  for (int b = 0; b < 7; b++) wr(A_IRQ_STATUS, 1 << b);
  rd(A_IRQ_STATUS);
  if (rdv[6:0] != 0) fail($sformatf("IRQ_STATUS %h after clearing", rdv));
  mk_frame(PM, DM, 60); h_send(60);
  if (!irq) fail("irq low with TX_SENT pending");
  frame_gap();
  if (pqh != pqt) fail("peer missed bytes");
endtask
