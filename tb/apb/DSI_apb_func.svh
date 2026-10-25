// SPDX-License-Identifier: Apache-2.0
// DSI-specific part of tb/DSI_apb_tb.sv. The TB is the peripheral: it
// decodes every packet on tx_bit / tx_valid (SoT, header ECC, CRC-16) and
// answers DCS reads on rx_bit after the bus turn-around.
// Checked: raw short packets, DCS short writes (with PL0 as parameter),
// DCS long writes from PL0..PL31, video lines (HSS, HSE, HBP, HACT),
// STATUS (busy, tx_oe, pkt_cnt), a DCS read with BTA and the response in
// BTA (clean, one data bit and one parity bit corrected), GO while busy
// ignored; under Verilator pkt_cnt wraps.
// Covered through the registers: BTA_DONE; ERROR from rejected commands
// (ops 6 and 7, payload above 32 bytes, HACT not a multiple of 3), an
// error report, a response timeout, a bad SoT and an uncorrectable
// response; masked, raising irq and cleared.
localparam logic [2:0] OP_SPKT = 0, OP_DCS_S0 = 1, OP_DCS_S1 = 2, OP_DCS_L = 3, OP_VLINE = 4, OP_DCS_RD = 5;
initial rx_bit = 1;
function automatic logic [5:0] ecc24(input logic [23:0] d);
  ecc24[0] = d[0]^d[1]^d[2]^d[4]^d[5]^d[7]^d[10]^d[11]^d[13]^d[16]^d[20]^d[21]^d[22]^d[23];
  ecc24[1] = d[0]^d[1]^d[3]^d[4]^d[6]^d[8]^d[10]^d[12]^d[14]^d[17]^d[20]^d[21]^d[22]^d[23];
  ecc24[2] = d[0]^d[2]^d[3]^d[5]^d[6]^d[9]^d[11]^d[12]^d[15]^d[18]^d[20]^d[21]^d[22];
  ecc24[3] = d[1]^d[2]^d[3]^d[7]^d[8]^d[9]^d[13]^d[14]^d[15]^d[19]^d[20]^d[21]^d[23];
  ecc24[4] = d[4]^d[5]^d[6]^d[7]^d[8]^d[9]^d[16]^d[17]^d[18]^d[19]^d[20]^d[22]^d[23];
  ecc24[5] = d[10]^d[11]^d[12]^d[13]^d[14]^d[15]^d[16]^d[17]^d[18]^d[19]^d[21]^d[22]^d[23];
endfunction
function automatic logic [15:0] crc16(input logic [15:0] c, input logic [7:0] d);
  logic [15:0] v;
  v = c ^ {8'h00, d};
  for (int k = 0; k < 8; k++) v = v[0] ? (v >> 1) ^ 16'h8408 : (v >> 1);
  return v;
endfunction

// peripheral: packets decoded from the lane, sampled at the falling edge
logic [7:0]  p_dt;
logic [15:0] p_len;
logic [7:0]  p_pay [0:31];
logic [7:0]  ram [0:31];
int          pcnt = 0;
task automatic recv_byte(output logic [7:0] b);
  for (int i = 0; i < 8; i++) begin
    @(negedge PCLK);
    b[i] = tx_bit;
    if (tx_valid !== 1 || tx_oe !== 1) fail("tx_valid or tx_oe dropped inside a packet");
  end
endtask
task automatic recv_packet(input bit is_long);
  logic [7:0]  b, b0, b1, b2, be, cl, ch;
  logic [15:0] c;
  while (tx_valid !== 1) @(negedge PCLK);
  b[0] = tx_bit;
  for (int i = 1; i < 8; i++) begin @(negedge PCLK); b[i] = tx_bit; end
  if (b !== 8'hB8) fail($sformatf("SoT %h", b));
  recv_byte(b0); recv_byte(b1); recv_byte(b2); recv_byte(be);
  if (be !== {2'b00, ecc24({b2, b1, b0})}) fail("header ECC");
  p_dt = b0; p_len = {b2, b1};
  if (is_long) begin
    c = 16'hFFFF;
    for (int i = 0; i < p_len; i++) begin recv_byte(b); if (i < 32) p_pay[i] = b; c = crc16(c, b); end
    recv_byte(cl); recv_byte(ch);
    if ({ch, cl} !== c) fail("payload CRC-16");
  end
  @(negedge PCLK);
  if (tx_valid !== 0 || tx_bit !== 1) fail("no gap after a packet");
  pcnt++;
endtask

task automatic irq_expect(input int b);
  cycles(2);
  rd(A_IRQ_STATUS);
  if (!rdv[b]) fail($sformatf("IRQ bit %0d not set (%h)", b, rdv));
  if (!irq) fail("irq low with an enabled bit set");
  wr(A_IRQ_STATUS, 32'(1) << b);
endtask
task automatic go(input logic [2:0] op, input logic [5:0] dt, input logic [7:0] dcs,
                  input logic [15:0] len, input logic [15:0] len2);
  wr(A_CMD, {15'd0, dcs, dt, op});
  wr(A_LEN, {len2, len});
  wr(A_GO, 1);
endtask
task automatic pl_write(input int n);
  for (int i = 0; i < n; i++) wr(A_PL0 + 12'(4 * i), {$urandom, ram[i]} & 32'hFFFF_FFFF);
endtask
// STATUS: idle, the lane ours, pkt_cnt as counted
task automatic idle_check;
  poll(A_STATUS, 1, 0, 200);
  if (rdv !== {14'd0, 16'(pcnt), 2'b10}) fail($sformatf("STATUS %h, expected pkt_cnt %0d", rdv, pcnt));
endtask
task automatic short_cmd(input logic [2:0] op, input logic [5:0] dt, input logic [7:0] dcs,
                         input logic [15:0] len, input logic [7:0] e_dt, input logic [15:0] e_data);
  go(op, dt, dcs, len, 0);
  recv_packet(0);
  if (p_dt !== e_dt || p_len !== e_data) fail($sformatf("short packet %h %h, expected %h %h", p_dt, p_len, e_dt, e_data));
  idle_check();
endtask
task automatic dcs_long(input logic [7:0] dcs, input int n);
  for (int i = 0; i < n; i++) ram[i] = $urandom;
  if (n > 0) ram[0] = dcs;
  pl_write(n);
  go(OP_DCS_L, 0, 0, 16'(n), 0);
  recv_packet(1);
  if (p_dt !== 8'h39 || p_len !== 16'(n)) fail("DCS long write header");
  for (int i = 0; i < n; i++) if (p_pay[i] !== ram[i]) fail($sformatf("DCS long write byte %0d", i));
  idle_check();
endtask
task automatic vline(input int hact, input int hbp);
  for (int i = 0; i < hact; i++) ram[i] = $urandom;
  pl_write(hact);
  go(OP_VLINE, 0, 0, 16'(hact), 16'(hbp));
  recv_packet(0); if (p_dt !== 8'h21 || p_len !== 0) fail("HSS");
  recv_packet(0); if (p_dt !== 8'h31 || p_len !== 0) fail("HSE");
  recv_packet(1); if (p_dt !== 8'h19 || p_len !== 16'(hbp)) fail("HBP");
  for (int i = 0; i < hbp && i < 32; i++) if (p_pay[i] !== 0) fail("HBP payload");
  recv_packet(1); if (p_dt !== 8'h3E || p_len !== 16'(hact)) fail("HACT");
  for (int i = 0; i < hact; i++) if (p_pay[i] !== ram[i]) fail("HACT payload");
  idle_check();
endtask
task automatic reject(input logic [2:0] op, input logic [15:0] len);
  go(op, 0, 0, len, 0);
  irq_expect(IRQ_ERROR);
  rd_exp(A_STATUS, {14'd0, 16'(pcnt), 2'b10});
endtask

// DCS read: request, trigger byte, lane released, the response
task automatic read_req(input logic [7:0] dcs);
  logic [7:0] b;
  go(OP_DCS_RD, 0, dcs, 0, 0);
  recv_packet(0);
  if (p_dt !== 8'h06 || p_len !== {8'h00, dcs}) fail("DCS read header");
  while (tx_valid !== 1) @(negedge PCLK);
  b[0] = tx_bit;
  for (int i = 1; i < 8; i++) begin @(negedge PCLK); b[i] = tx_bit; end
  if (b !== 8'h84) fail("BTA trigger byte");
  @(negedge PCLK); @(negedge PCLK);
  if (tx_oe !== 0 || tx_valid !== 0) fail("lane not released for the turn-around");
  rd(A_STATUS);
  if (rdv[1:0] !== 2'b01) fail($sformatf("STATUS %h during the turn-around", rdv));
endtask
task automatic send_resp(input logic [7:0] sot, input logic [23:0] hdr, input logic [7:0] ecc);
  logic [7:0] r [0:4];
  r[0] = sot; r[1] = hdr[7:0]; r[2] = hdr[15:8]; r[3] = hdr[23:16]; r[4] = ecc;
  for (int j = 0; j < 5; j++)
    for (int i = 0; i < 8; i++) begin @(negedge PCLK); rx_bit = r[j][i]; end
  @(negedge PCLK); rx_bit = 1;
endtask
// a read whose response has the bits of err flipped (24 data + 6 parity)
task automatic read_txn(input logic [23:0] hdr, input logic [29:0] err, input logic [23:0] e_data,
                        input bit e_done, input bit e_err);
  read_req(8'h0A);
  send_resp(8'hB8, hdr ^ err[23:0], {2'b00, ecc24(hdr) ^ err[29:24]});
  idle_check();
  rd(A_IRQ_STATUS);
  if (rdv[IRQ_BTA_DONE] !== e_done || rdv[IRQ_ERROR] !== e_err) fail($sformatf("IRQ_STATUS %h after a read", rdv));
  wr(A_IRQ_STATUS, IRQ_ALL);
  if (e_done) rd_exp(A_BTA, e_data);
endtask

task automatic ip_func;
  wr(A_IRQ_ENABLE, IRQ_ALL);
  rd_exp(A_FLAGS, 0);
  for (int i = 0; i < 32; i++) rd_exp(A_PL0 + 12'(4 * i), 0);   // write only
  idle_check();
  rd_exp(A_BTA, 0);
  short_cmd(OP_SPKT, 6'h03, 0, 16'hA55A, 8'h03, 16'hA55A);
  short_cmd(OP_SPKT, 6'h3C, 0, 16'h5AA5, 8'h3C, 16'h5AA5);
  short_cmd(OP_DCS_S0, 0, 8'h29, 0, 8'h05, 16'h0029);
  ram[0] = 8'h77; pl_write(1);
  short_cmd(OP_DCS_S1, 0, 8'h36, 0, 8'h15, 16'h7736);
  dcs_long(8'h2C, 32);
  dcs_long(8'h3C, 5);
  for (int i = 0; i < 32; i++) ram[i] = 8'hFF;
  pl_write(32);
  for (int i = 0; i < 32; i++) ram[i] = 8'h00;
  pl_write(32);
  dcs_long(8'h00, 0);
  vline(30, 12);
  vline(3, 0);
  // GO while busy: ignored
  go(OP_SPKT, 6'h01, 0, 16'h1234, 0);
  wr(A_GO, 1);
  recv_packet(0);
  idle_check();
  if (tx_valid) fail("a second packet after GO while busy");
  // a partial-strobe payload write
  apb(1, A_PL3, 32'h12, 4'h1);
  if (!rerr) fail("no PSLVERR on a partial-strobe write");
  // rejected commands
  reject(3'd6, 0);
  reject(3'd7, 0);
  reject(OP_DCS_L, 33);
  reject(OP_VLINE, 31);
  reject(OP_VLINE, 16'hFFFF);
  // reads: clean, corrected data bit, corrected parity bit, error report,
  // uncorrectable, bad SoT, no response
  read_txn(24'h00C31A, 0, 24'h00C31A, 1, 0);
  read_txn(24'hFFFF21, 30'h1 << 13, 24'hFFFF21, 1, 0);
  read_txn(24'h12341C, 30'h1 << 27, 24'h12341C, 1, 0);
  read_txn(24'h5678DC, 0, 24'h5678DC, 1, 0);           // VC 3
  read_txn(24'h000402, 0, 24'h000402, 1, 1);
  read_txn(24'h000011, 30'h3, 0, 0, 1);
  read_req(8'h0B);
  send_resp(8'hB9, 24'h000011, 0);
  idle_check();
  irq_expect(IRQ_ERROR);
  read_req(8'h0C);
  cycles(600);
  idle_check();
  irq_expect(IRQ_ERROR);
  rd_exp(A_IRQ_STATUS, 0);
`ifdef VERILATOR
  // pkt_cnt wraps (Verilator only: 65536 packets)
  wr(A_CMD, {15'd0, 8'd0, 6'h01, OP_SPKT});
  wr(A_LEN, 0);
  no_idle = 1;
  while (pcnt != 65536) begin
    wr(A_GO, 1);
    pcnt++;
    rd(A_STATUS);
    while (rdv[0]) rd(A_STATUS);
  end
  no_idle = 0;
  pcnt = 0;
  idle_check();
`endif
  // masked: left pending into reset
  wr(A_IRQ_ENABLE, 0);
  go(3'd7, 0, 0, 0, 0);
  read_req(8'h0D);
  send_resp(8'hB8, 24'h001234, {2'b00, ecc24(24'h001234)});
  idle_check();
  if (irq) fail("irq with every interrupt masked");
  rd_exp(A_IRQ_STATUS, IRQ_ALL);
endtask
