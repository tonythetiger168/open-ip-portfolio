// SPDX-License-Identifier: Apache-2.0
// Bluetooth5-specific part of tb/Bluetooth5_apb_tb.sv. The TB is a BLE
// central / scanner on the 1 bit per clock baseband (rxd / txd), with a
// reference whitening and CRC24 to decode every packet sent.
// Checked: ADV_IND carrying the payload written through PAY0..PAY15,
// ADV_CTRL off and on, SCAN_RSP and SCAN_CTRL off, a connection set up by
// CONNECT_REQ and empty-PDU answers with SN / NESN in a few events,
// STATUS.tx_act against the pin.
// Covered through the registers: ERROR from a bad CRC, an oversize length,
// a wrong-length CONNECT_REQ, a reserved LLID and a supervision timeout;
// partial-strobe writes refused; masked, raising irq and cleared.
localparam int ADV_INTV = 1200;
localparam logic [31:0] ADV_AA = 32'h8E89BED6;
localparam logic [23:0] ADV_CRCI = 24'h555555;
localparam logic [6:0]  ADV_SEED = 7'h25;
initial rxd = 0;

function automatic logic [6:0] wnext(input logic [6:0] l);
  return {l[5:0], l[6] ^ l[3]};
endfunction
function automatic logic [23:0] cbit(input logic [23:0] c, input logic b);
  return (c[0] ^ b) ? ((c >> 1) ^ 24'h00065B) : (c >> 1);
endfunction
function automatic logic [6:0] dseed(input int ch);
  return 7'(ch) | 7'h01;
endfunction

// TX capture: the bits of each packet, and STATUS.tx_act against the pin
logic cap [0:511];
logic pkt [0:511];
int   cap_n = 0, pkt_n = 0, pkt_cnt = 0;
always @(negedge PCLK) begin
  if (tx_act) begin cap[cap_n] = txd; cap_n++; end
  else if (cap_n > 0) begin
    for (int i = 0; i < cap_n; i++) pkt[i] = cap[i];
    pkt_n = cap_n; cap_n = 0; pkt_cnt++;
  end
end

logic       d_ok;
logic [7:0] d_hdr, d_len;
logic [7:0] d_pay [0:15];
task automatic decode(input logic [31:0] aa, input logic [23:0] ci, input logic [6:0] seed);
  logic [6:0]  l;
  logic [23:0] c;
  logic [7:0]  by;
  logic        b;
  int          k;
  d_ok = 1;
  by = aa[0] ? 8'h55 : 8'hAA;
  for (int j = 0; j < 8; j++) if (pkt[j] !== by[j]) d_ok = 0;
  for (int j = 0; j < 32; j++) if (pkt[8 + j] !== aa[j]) d_ok = 0;
  l = seed; c = ci; k = 40; d_len = 0;
  for (int i = 0; i < 18; i++) begin
    if (i < 2 || i < 2 + d_len) begin
      for (int j = 0; j < 8; j++) begin
        b = pkt[k] ^ l[6]; l = wnext(l); c = cbit(c, b); by[j] = b; k++;
      end
      if (i == 0) d_hdr = by;
      else if (i == 1) begin d_len = by; if (by > 16) d_ok = 0; end
      else d_pay[i - 2] = by;
    end
  end
  for (int j = 0; j < 24; j++) begin
    b = pkt[k] ^ l[6]; l = wnext(l); k++;
    if (b !== c[j]) d_ok = 0;
  end
  if (pkt_n != k) d_ok = 0;
endtask
// the next packet within tmo clocks (got = 0: none), waited to its end
task automatic next_pkt(input int tmo, output logic got);
  int c0;
  c0 = pkt_cnt; got = 0;
  for (int t = 0; t < tmo && !got; t++) begin
    @(negedge PCLK);
    if (tx_act || pkt_cnt != c0) got = 1;
  end
  if (got) while (pkt_cnt == c0) @(negedge PCLK);
endtask

logic [7:0] tpay [0:15];
task automatic c_send(input logic [31:0] aa, input logic [23:0] ci, input logic [6:0] seed,
                      input logic [7:0] hdr, input logic [7:0] len_f, input int npay, input bit bad_crc);
  logic [6:0]  l;
  logic [23:0] c;
  logic [7:0]  by;
  logic        b;
  by = aa[0] ? 8'h55 : 8'hAA;
  for (int j = 0; j < 8; j++) @(negedge PCLK) rxd = by[j];
  for (int j = 0; j < 32; j++) @(negedge PCLK) rxd = aa[j];
  l = seed; c = ci;
  for (int i = 0; i < 2 + npay; i++) begin
    by = (i == 0) ? hdr : (i == 1) ? len_f : tpay[i - 2];
    for (int j = 0; j < 8; j++) begin
      b = by[j]; c = cbit(c, b);
      @(negedge PCLK) rxd = b ^ l[6];
      l = wnext(l);
    end
  end
  if (bad_crc) c[5] = ~c[5];
  for (int j = 0; j < 24; j++) begin @(negedge PCLK) rxd = c[j] ^ l[6]; l = wnext(l); end
  @(negedge PCLK) rxd = 0;
endtask

logic [7:0] adv_model [0:15];
task automatic expect_adv;
  logic got;
  next_pkt(3 * ADV_INTV, got);
  if (!got) fail("no ADV_IND");
  decode(ADV_AA, ADV_CRCI, ADV_SEED);
  if (!(d_ok && d_hdr == 8'h00 && d_len == 8'd16)) fail("ADV_IND format");
  for (int i = 0; i < 16; i++)
    if (d_pay[i] !== adv_model[i]) fail($sformatf("ADV_IND byte %0d = %h, expected %h", i, d_pay[i], adv_model[i]));
endtask
task automatic adv_pdu(input logic [7:0] hdr, input logic [7:0] len_f, input int npay, input bit bad_crc);
  expect_adv();
  @(negedge PCLK);
  c_send(ADV_AA, ADV_CRCI, ADV_SEED, hdr, len_f, npay, bad_crc);
endtask
task automatic irq_expect(input int b);
  cycles(4);
  rd(A_IRQ_STATUS);
  if (!rdv[b]) fail($sformatf("IRQ bit %0d not set (%h)", b, rdv));
  if (!irq) fail("irq low with an enabled bit set");
  wr(A_IRQ_STATUS, 32'(1) << b);
endtask
task automatic no_irq;
  cycles(4);
  rd(A_IRQ_STATUS);
  if (rdv != 0) fail($sformatf("IRQ_STATUS %h, expected 0", rdv));
endtask
task automatic pay_write(input int i, input logic [7:0] v);
  wr(A_PAY0 + 12'(4 * i), {$urandom, v} & 32'hFFFF_FFFF);
  adv_model[i] = v;
endtask

// connection: central model of the peripheral's SN / NESN
logic [31:0] caa;
logic [23:0] cci;
int          dch;
logic        p_rx_sn, p_tx_sn;
task automatic connect(input logic [31:0] aa, input logic [23:0] ci, input logic [15:0] intv,
                       input logic [15:0] tmo, input logic [7:0] ch);
  {tpay[3], tpay[2], tpay[1], tpay[0]} = aa;
  {tpay[6], tpay[5], tpay[4]} = ci;
  {tpay[8], tpay[7]} = intv;
  {tpay[10], tpay[9]} = 16'd0;                     // latency 0
  {tpay[12], tpay[11]} = tmo;
  tpay[13] = 8'd0;                                 // no hopping
  tpay[14] = ch;
  adv_pdu(8'h05, 8'd15, 15, 0);
  caa = aa; cci = ci; dch = ch % 37; p_rx_sn = 0; p_tx_sn = 0;
endtask
// a central data PDU and the empty-PDU answer
task automatic event_tx(input logic [1:0] llid, input logic sn, input logic nesn, input int npay);
  logic got;
  for (int i = 0; i < npay; i++) tpay[i] = $urandom;
  c_send(caa, cci, dseed(dch), {4'h0, sn, nesn, llid}, 8'(npay), npay, 0);
  if (sn == p_rx_sn) p_rx_sn = ~p_rx_sn;
  if (nesn != p_tx_sn) p_tx_sn = ~p_tx_sn;
  next_pkt(30, got);
  if (!got) fail("data PDU not answered");
  decode(caa, cci, dseed(dch));
  if (!(d_ok && d_len == 0 && d_hdr == {4'h0, p_tx_sn, p_rx_sn, 2'b01}))
    fail($sformatf("empty PDU answer: ok %b len %0d hdr %h, expected %h", d_ok, d_len, d_hdr, {4'h0, p_tx_sn, p_rx_sn, 2'b01}));
endtask

task automatic ip_func;
  logic got;
  bit   seen;
  for (int i = 0; i < 16; i++) adv_model[i] = 8'hB0 + 8'(i);
  wr(A_IRQ_ENABLE, IRQ_ALL);
  rd_exp(A_FLAGS, 0);
  for (int i = 0; i < 18; i++) rd_exp(A_PAY0 + 12'(4 * i), 0);   // write only: read 0
  // STATUS.tx_act against the pin, idle and during an ADV_IND
  rd_exp(A_STATUS, 0);
  expect_adv();
  while (!tx_act) @(negedge PCLK);
  rd(A_STATUS);
  if (rdv !== 32'h1) fail($sformatf("STATUS %h during a packet", rdv));
  while (tx_act) @(negedge PCLK);
  // payload through PAY0..PAY15: all ones, all zeros, random
  for (int p = 0; p < 3; p++) begin
    for (int i = 0; i < 16; i++) pay_write(i, p == 0 ? 8'hFF : p == 1 ? 8'h00 : 8'($urandom));
    expect_adv(); expect_adv();
  end
  // a partial-strobe write: PSLVERR, ignored
  apb(1, A_PAY3, 32'h5A, 4'h1);
  if (!rerr) fail("no PSLVERR on a partial-strobe write");
  apb(1, A_PAY3, 32'h5A, 4'hE);
  if (!rerr) fail("no PSLVERR on a partial-strobe write");
  expect_adv(); expect_adv();
  // ADV_CTRL off and on
  wr(A_ADV_CTRL, 0);
  while (tx_act) @(negedge PCLK);
  next_pkt(3 * ADV_INTV, got);
  if (got) fail("ADV_IND with ADV_CTRL off");
  wr(A_ADV_CTRL, 1);
  expect_adv();
  // SCAN_REQ: SCAN_RSP, then none with SCAN_CTRL off
  for (int i = 0; i < 12; i++) tpay[i] = $urandom;
  adv_pdu(8'h03, 8'd12, 12, 0);
  next_pkt(60, got);
  if (!got) fail("no SCAN_RSP");
  decode(ADV_AA, ADV_CRCI, ADV_SEED);
  if (!(d_ok && d_hdr == 8'h04 && d_len == 8'd16)) fail("SCAN_RSP format");
  wr(A_SCAN_CTRL, 0);
  adv_pdu(8'h03, 8'd12, 12, 0);
  next_pkt(60, got);
  if (got) fail("SCAN_RSP with SCAN_CTRL off");
  wr(A_SCAN_CTRL, 1);
  no_irq();
  // ERROR: bad CRC, oversize length, unknown type, wrong CONNECT_REQ length
  adv_pdu(8'h03, 8'd12, 12, 1); irq_expect(IRQ_ERROR);
  adv_pdu(8'h02, 8'd17, 4, 0);  irq_expect(IRQ_ERROR);
  adv_pdu(8'h0F, 8'd6, 6, 0);   irq_expect(IRQ_ERROR);
  adv_pdu(8'h05, 8'd14, 14, 0); irq_expect(IRQ_ERROR);
  adv_pdu(8'h02, 8'd6, 6, 0);   no_irq();          // ADV_NONCONN_IND: ignored
  // a connection: a few events, a reserved LLID, then a supervision timeout
  connect(32'hC1C2C3C4, 24'h123456, 16'd400, 16'd3, 8'd9);
  no_irq();
  for (int e = 0; e < 4; e++) begin
    while (dut.u_core.conn_timer != 0) @(negedge PCLK);
    next_pkt(30, got);                             // the keepalive of a missed event
    repeat (4) @(negedge PCLK);
    event_tx(2'(1 + e % 3), e[0], e[1], 2 * e);
  end
  c_send(caa, cci, dseed(dch), 8'h00, 8'd2, 2, 0);   // reserved LLID
  irq_expect(IRQ_ERROR);
  seen = 0;
  for (int t = 0; t < 3000 && !seen; t++) begin @(negedge PCLK); seen = dut.u_core.ll_state == 0; end
  if (!seen) fail("no supervision timeout");
  irq_expect(IRQ_ERROR);
  while (tx_act) @(negedge PCLK);
  expect_adv();
  // masked: left pending into reset
  wr(A_IRQ_ENABLE, 0);
  adv_pdu(8'h03, 8'd12, 12, 1);
  cycles(4);
  if (irq) fail("irq with every interrupt masked");
  rd_exp(A_IRQ_STATUS, IRQ_ALL);
endtask
