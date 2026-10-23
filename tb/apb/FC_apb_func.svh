// SPDX-License-Identifier: Apache-2.0
// FC-specific part of tb/FC_apb_tb.sv. A second FC_top (the peer, driven
// directly) is cross-connected to the DUT's line pins; the TB can take over
// the DUT's receive line with an injector (its own 8b/10b encoder).
// Covered through the registers: frames both ways through TX / RX with
// every delimiter, a TX write while full and a late TX byte (underrun),
// RX overflowing and popped as it captures, credit_used up to 9 and back
// (STATUS), received CRC, length and abort status, a fragment, code and
// word errors, every stream event and interrupt bit.
logic        inj = 0, ij_bit = 0;
wire         p_tx;
assign rx_p = inj ? ij_bit : p_tx;

// peer
logic        p_tx_valid = 0, p_tx_last = 0, p_tx_sofi = 0, p_tx_eoft = 0;
logic [7:0]  p_tx_data = 0;
wire         p_tx_ready, p_tx_done, p_tx_underrun, p_rx_valid, p_rx_last, p_rx_frag, p_rx_sync, p_err_code, p_err_word;
wire  [3:0]  p_credit_used;
wire  [7:0]  p_rx_data;
wire  [4:0]  p_rx_stat;
FC_top u_peer (
  .clk(PCLK), .rst_n(PRESETN), .tx_p(p_tx), .rx_p(tx_p), .cfg_credit(4'd0),
  .tx_valid(p_tx_valid), .tx_ready(p_tx_ready), .tx_data(p_tx_data), .tx_last(p_tx_last),
  .tx_sofi(p_tx_sofi), .tx_eoft(p_tx_eoft), .tx_done(p_tx_done), .tx_underrun(p_tx_underrun),
  .credit_used(p_credit_used), .rx_valid(p_rx_valid), .rx_data(p_rx_data), .rx_last(p_rx_last),
  .rx_stat(p_rx_stat), .rx_frag(p_rx_frag), .rx_sync(p_rx_sync), .err_code(p_err_code), .err_word(p_err_word));

function automatic logic [31:0] crc_b(input logic [31:0] c, input logic [7:0] d);
  for (int i = 0; i < 8; i++) c = (c[0] ^ d[i]) ? (c >> 1) ^ 32'hEDB88320 : c >> 1;
  return c;
endfunction

// what the peer should receive: {last, stat, byte}
logic [13:0] pq [0:4095];
int          pqh = 0, pqt = 0;
bit          p_any = 0;                  // accept anything (frames cut by an underrun)
always @(negedge PCLK) if (PRESETN && p_rx_valid && !p_any) begin
  if (pqh == pqt) fail($sformatf("peer: rx byte %h with none expected", p_rx_data));
  else begin
    if ({p_rx_last, p_rx_last ? p_rx_stat : 5'h0, p_rx_data} !== pq[pqh % 4096])
      fail($sformatf("peer: rx %b %h %h, expected %h", p_rx_last, p_rx_stat, p_rx_data, pq[pqh % 4096]));
    pqh++;
  end
end
// peer transmit: frame bytes in pf, sent as the peer takes them
logic [7:0]  pf [0:2047];
int          pfn = 0, pfi = 0;
bit          p_took = 0;
always @(posedge PCLK) p_took <= p_tx_valid && p_tx_ready;
always @(negedge PCLK) if (PRESETN) begin
  if (p_took) begin pfi++; p_tx_valid = 0; end
  if (pfi < pfn) begin p_tx_valid = 1; p_tx_data = pf[pfi]; p_tx_last = pfi == pfn - 1; end
end

logic [7:0] fr [0:2047];
// the DUT sends fr[0 .. len-1]; the peer expects fill and the delimiters
task automatic h_send(input int len, input bit sofi, input bit eoft);
  int t;
  t = len < 24 ? 24 : (len + 3) / 4 * 4;
  for (int j = 0; j < t; j++) begin
    pq[pqt % 4096] = {j == t - 1, j == t - 1 ? {sofi, eoft, 3'b000} : 5'h0, j < len ? fr[j] : 8'h00}; pqt++;
  end
  for (int j = 0; j < len; j++) begin
    @(negedge PCLK);
    while (dut.full_TX) @(negedge PCLK);
    apb_now(1, A_TX, {21'd0, eoft, sofi, j == len - 1, fr[j]}, 4'hF);
  end
endtask
// the peer sends fr[0 .. len-1]; the DUT's RX is read byte by byte
task automatic p_send(input int len, input bit sofi, input bit eoft);
  for (int j = 0; j < len; j++) pf[j] = fr[j];
  p_tx_sofi = sofi; p_tx_eoft = eoft;
  pfi = 0; pfn = len;
endtask
task automatic h_recv(input int len, input logic [4:0] stat);
  for (int j = 0; j < len; j++) begin
    @(negedge PCLK);
    while (!dut.avail_RX) @(negedge PCLK);
    apb_now(0, A_RX, 0, 0);
    if (rdv[7:0] !== fr[j] || rdv[8] !== (j == len - 1) || (j == len - 1 && rdv[13:9] !== stat))
      fail($sformatf("RX byte %0d: %h, expected %h", j, rdv[13:0], {stat, j == len - 1, fr[j]}));
  end
endtask
task automatic irq_expect(input int b);
  rd(A_IRQ_STATUS);
  if (!rdv[b]) fail($sformatf("IRQ bit %0d not set (%h)", b, rdv));
endtask
task automatic rnd_fr(input int n);
  for (int j = 0; j < n; j++) fr[j] = $urandom;
endtask
task automatic frame_gap;
  repeat (40 * 40) @(negedge PCLK);
endtask

// ---------------- injector ----------------
function automatic logic [11:0] c6(input int x);
  case (x)
    0: return 12'o4730;  1: return 12'o3542;  2: return 12'o5522;  3: return 12'o6161;
    4: return 12'o6512;  5: return 12'o5151;  6: return 12'o3131;  7: return 12'o7007;
    8: return 12'o7106;  9: return 12'o4545;  10: return 12'o2525; 11: return 12'o6464;
    12: return 12'o1515; 13: return 12'o5454; 14: return 12'o3434; 15: return 12'o2750;
    16: return 12'o3344; 17: return 12'o4343; 18: return 12'o2323; 19: return 12'o6262;
    20: return 12'o1313; 21: return 12'o5252; 22: return 12'o3232; 23: return 12'o7205;
    24: return 12'o6314; 25: return 12'o4646; 26: return 12'o2626; 27: return 12'o6611;
    28: return 12'o1616; 29: return 12'o5621; 30: return 12'o3641; 31: return 12'o5324;
    default: return 12'o1760;
  endcase
endfunction
function automatic logic [7:0] c4(input int y);
  case (y)
    0: return 8'hB4; 1: return 8'h99; 2: return 8'h55; 3: return 8'hC3; 4: return 8'hD2;
    5: return 8'hAA; 6: return 8'h66; 7: return 8'hE1; 8: return 8'h78;
    9: return 8'hB4; 10: return 8'h69; 11: return 8'hA5; 12: return 8'hC3; 13: return 8'hD2;
    14: return 8'h5A; 15: return 8'h96; default: return 8'h78;
  endcase
endfunction
function automatic int n1(input logic [5:0] v);
  n1 = 0;
  for (int i = 0; i < 6; i++) n1 += v[i];
endfunction
function automatic logic [10:0] code(input logic [7:0] d, input bit k, input bit rd);
  int x, y, y4;
  logic [11:0] p6;
  logic [7:0]  p4;
  logic [5:0]  s6;
  logic [3:0]  s4;
  x = d[4:0]; y = d[7:5];
  p6 = c6(k && x == 28 ? 32 : x);
  s6 = rd ? p6[5:0] : p6[11:6];
  if (n1(s6) != 3) rd = !rd;
  if (k && x == 28) y4 = 9 + y;
  else if (y == 7 && (k || (!rd && (x == 17 || x == 18 || x == 20)) || (rd && (x == 11 || x == 13 || x == 14)))) y4 = 8;
  else y4 = y;
  p4 = c4(y4);
  s4 = rd ? p4[3:0] : p4[7:4];
  if (n1({2'b0, s4}) != 2) rd = !rd;
  return {rd, s6, s4};
endfunction
localparam logic [23:0] OS_IDLE = 24'h95B5B5, OS_RRDY = 24'h954A4A, OS_SOFI = 24'hB55656, OS_SOFN = 24'hB53636;
bit ij_rd = 0;
task automatic ij_raw(input logic [9:0] b);
  for (int i = 9; i >= 0; i--) begin @(negedge PCLK); ij_bit = b[i]; end
endtask
task automatic ij_char(input bit k, input logic [7:0] d);
  logic [10:0] c;
  c = code(d, k, ij_rd);
  ij_rd = c[10];
  ij_raw(c[9:0]);
endtask
task automatic ij_os(input logic [23:0] o);
  ij_char(1, 8'hBC); ij_char(0, o[23:16]); ij_char(0, o[15:8]); ij_char(0, o[7:0]);
endtask
task automatic ij_idles(input int n);
  for (int i = 0; i < n; i++) ij_os(OS_IDLE);
endtask
// fr[0 .. n-1] and its CRC (bad: one bit off), ended with EOFn / EOFt / EOFa (ty)
task automatic ij_frame(input int n, input bit sofi, input logic [7:0] ty, input bit bad);
  logic [31:0] c;
  c = '1;
  for (int i = 0; i < n; i++) c = crc_b(c, fr[i]);
  c = ~c ^ (bad ? 32'h0000_0100 : 32'h0);
  ij_os(sofi ? OS_SOFI : OS_SOFN);
  for (int i = 0; i < n + 4; i++) ij_char(0, i < n ? fr[i] : c[8 * (i - n) +: 8]);
  ij_os({ij_rd ? 8'hB5 : 8'h95, ty, ty});
endtask
// in the background: ij_frame while the host reads RX (ij_go), or IDLEs
// while the host writes TX (ij_fill)
bit          ij_go = 0, ij_s = 0, ij_b = 0, ij_fill = 0, ij_busy = 0;
int          ij_n = 0;
logic [7:0]  ij_t = 0;
initial forever begin
  if (inj && (ij_go || ij_fill)) begin
    ij_busy = 1;
    if (ij_go) begin ij_frame(ij_n, ij_s, ij_t, ij_b); ij_idles(2); ij_go = 0; end
    else ij_os(OS_IDLE);
    ij_busy = 0;
  end else @(negedge PCLK);
end
task automatic ij_fill_stop;
  ij_fill = 0;
  wait (!ij_busy);
endtask
task automatic ij_bg(input int n, input bit sofi, input logic [7:0] ty, input bit bad);
  ij_n = n; ij_s = sofi; ij_t = ty; ij_b = bad; ij_go = 1;
endtask

task automatic ip_func;
  wr(A_IRQ_ENABLE, 0);
  wr(A_CFG, 0);
  frame_gap();
  wr(A_IRQ_STATUS, IRQ_ALL);
  rd(A_STATUS);
  if (rdv[0] !== 1'b1) fail("no sync with the peer");
  // DUT -> peer: filled to 24 bytes, to a word, not at all; every delimiter
  rnd_fr(20); h_send(20, 1, 0);
  rnd_fr(30); fr[3] = 8'hFF; fr[4] = 8'h00; h_send(30, 0, 1);
  rnd_fr(32); h_send(32, 1, 1);
  frame_gap();
  if (pqh != pqt) fail("peer missed bytes");
  irq_expect(IRQ_TX_SENT);
  irq_expect(IRQ_TX_DONE);
  // peer -> DUT
  rnd_fr(28); p_send(28, 1, 1); h_recv(28, 5'b11000);
  rnd_fr(40); fr[9] = 8'hFF; p_send(40, 0, 0); h_recv(40, 5'b00000);
  frame_gap();
  // TX written while full (the frame then misses a byte): TX_OVF, then a late byte: TX_UNDERRUN
  p_any = 1;
  rnd_fr(40);
  wr(A_TX, {21'd0, 2'b00, 1'b0, fr[0]});
  wr(A_TX, {21'd0, 2'b00, 1'b0, fr[1]});
  irq_expect(IRQ_TX_OVF);
  for (int j = 1; j < 9; j++) begin
    @(negedge PCLK);
    while (dut.full_TX) @(negedge PCLK);
    apb_now(1, A_TX, {21'd0, 2'b00, 1'b0, fr[j]}, 4'hF);
  end
  poll(A_IRQ_STATUS, 1 << IRQ_TX_UNDERRUN, 1 << IRQ_TX_UNDERRUN, 5000);
  frame_gap();
  p_any = 0;
  // RX not read: overflow; then RX popped as it captures
  rnd_fr(40); p_send(40, 0, 0);
  frame_gap();
  irq_expect(IRQ_RX_OVF);
  rd(A_RX);
  rnd_fr(40); p_send(40, 0, 0);
  while (!(dut.u_core.sym_rdy && dut.u_core.rf && dut.u_core.rn == 12'd20 && dut.avail_RX)) @(negedge PCLK);
  apb_now(0, A_RX, 0, 0);
  frame_gap();
  while (dut.avail_RX) rd(A_RX);
  rd(A_RX);                                     // empty: the last byte again
  rd(A_FLAGS);
  if (rdv[1:0] !== 2'b00) fail($sformatf("FLAGS %h with TX and RX empty", rdv));

  // injector: no R_RDYs come back, credit_used climbs to 9 (STATUS)
  p_any = 1;
  inj = 1; ij_rd = 0;
  ij_fill = 1;
  for (int i = 0; i < 9; i++) begin
    rnd_fr(4);
    for (int j = 0; j < 4; j++) begin
      @(negedge PCLK);
      while (dut.full_TX) @(negedge PCLK);
      apb_now(1, A_TX, {21'd0, 2'b00, j == 3, fr[j]}, 4'hF);
    end
  end
  repeat (40 * 40) @(negedge PCLK);
  rd(A_STATUS);
  if (rdv[4:0] !== {4'd9, 1'b1}) fail($sformatf("STATUS %h, expected credit_used 9 and sync", rdv));
  wr(A_CFG, 4);                                 // credit_used 9 >= 4: no frame starts
  ij_fill_stop();
  for (int i = 0; i < 9; i++) ij_os(OS_RRDY);
  ij_fill = 1;
  repeat (100) @(negedge PCLK);
  rd(A_STATUS);
  if (rdv[4:1] !== 4'd0) fail($sformatf("STATUS %h after the R_RDYs", rdv));
  wr(A_CFG, 0);
  // received status: CRC error, too short, EOFa; a fragment; errors
  rnd_fr(36); ij_bg(36, 0, 8'hD5, 1); h_recv(36, 5'b00001); wait (!ij_go);
  rnd_fr(12); ij_bg(12, 1, 8'h75, 0); h_recv(12, 5'b11010); wait (!ij_go);
  rnd_fr(36); ij_bg(36, 0, 8'hF5, 0); h_recv(36, 5'b00100); wait (!ij_go);
  ij_fill_stop();
  ij_os(OS_SOFN); ij_os({ij_rd ? 8'hB5 : 8'h95, 8'hD5, 8'hD5});
  ij_char(0, 8'h00); ij_char(0, 8'h00); ij_char(0, 8'h00); ij_char(0, 8'h00);
  ij_raw(10'b1111111111);
  ij_idles(4);
  ij_fill = 1;
  irq_expect(IRQ_RX_FRAG);
  irq_expect(IRQ_ERR_WORD);
  irq_expect(IRQ_ERR_CODE);
  irq_expect(IRQ_RX_AVAIL);
  ij_fill_stop();
  inj = 0;
  frame_gap();
  p_any = 0;

  // interrupts: masked, raising irq, cleared one by one
  rd(A_IRQ_STATUS);
  if (rdv[8:0] != 9'h1FF) fail($sformatf("IRQ_STATUS %h, expected every bit", rdv));
  if (irq) fail("irq high with every bit masked");
  wr(A_IRQ_ENABLE, IRQ_ALL);
  if (!irq) fail("irq low with every bit enabled");
  for (int b = 0; b < 9; b++) wr(A_IRQ_STATUS, 1 << b);
  rd(A_IRQ_STATUS);
  if (rdv[8:0] != 0) fail($sformatf("IRQ_STATUS %h after clearing", rdv));
  rnd_fr(24); h_send(24, 0, 0);
  poll(A_IRQ_STATUS, 1 << IRQ_TX_SENT, 1 << IRQ_TX_SENT, 5000);
  if (!irq) fail("irq low with TX_SENT pending");
  frame_gap();
  if (pqh != pqt) fail("peer missed bytes");
endtask
