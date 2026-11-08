// SPDX-License-Identifier: Apache-2.0
// PCIe_CXL_IDE-specific part of tb/PCIe_CXL_IDE_apb_tb.sv: everything runs
// through the registers (CFG, SID, IVFIX, KM, KEY, CMD, TX0..TX4, TXO0..TXO4,
// RX0..RX4, RXO0..RXO4, STATUS, KV, IRQ_STATUS), with the core at its
// defaults (NS = 2, CTR_W = 64, LEN_W = 16): every known-answer case of
// tb/PCIe_CXL_IDE_vec.svh (TLPs and cachemem epochs, keys from the KEY
// registers or the sideload pins) sent through the transmit side, compared,
// then looped back through the receive side and compared; then each error
// class through its interrupt and STATUS, TX / RX overflows, a tampered
// message, CMD.clr in the middle of a message and the interrupt mask.
`include "PCIe_CXL_IDE_vec.svh"
initial begin
  sl_key = '0;
  sl_valid = 1'b0;
end

localparam logic [1:0] IK_HDR = 2'd0, IK_DATA = 2'd1, IK_MAC = 2'd2, IK_PFX = 2'd3;
logic [10:0] ide_cfg;                   // CFG shadow
logic [15:0] ide_sid;

function automatic logic [127:0] ide_r128();
  return {$urandom, $urandom, $urandom, $urandom};
endfunction
function automatic logic [127:0] ide_mask(input int n);
  logic [127:0] m;
  for (int i = 0; i < 16; i++) m[127 - 8 * i -: 8] = i < n ? 8'hff : 8'h00;
  return m;
endfunction

// output blocks read so far (transmit 0, receive 1)
logic [127:0] oq_d [0:1][0:255];
logic [4:0]   oq_n [0:1][0:255];
logic [1:0]   oq_k [0:1][0:255];
logic         oq_l [0:1][0:255], oq_b [0:1][0:255], oq_c [0:1][0:255];
int           oqn [0:2];
task automatic ide_pop(input int d);
  logic [11:0] a;
  logic [127:0] x;
  a = d == 0 ? A_TXO0 : A_RXO0;
  for (int i = 0; i < 4; i++) begin rd(a + 12'(4 * i)); x[32 * i +: 32] = rdv; end
  rd(a + 12'd16);
  oq_d[d][oqn[d] % 256] = x; oq_n[d][oqn[d] % 256] = rdv[4:0]; oq_k[d][oqn[d] % 256] = rdv[6:5];
  oq_l[d][oqn[d] % 256] = rdv[7]; oq_b[d][oqn[d] % 256] = rdv[8]; oq_c[d][oqn[d] % 256] = rdv[9];
  oqn[d]++;
endtask
// read output blocks of direction d until there are n (or none come)
task automatic ide_drain(input int d, input int n);
  int t;
  t = 0;
  while (oqn[d] < n && t < 400) begin
    rd(A_FLAGS);
    if (rdv[d == 0 ? FLAG_TXO_AVAIL : FLAG_RXO_AVAIL]) begin ide_pop(d); t = 0; end
    else t++;
  end
  if (oqn[d] < n) fail($sformatf("%s: %0d output blocks, expected %0d", d == 0 ? "TXO" : "RXO", oqn[d], n));
endtask
// write one input block once the holding register is free, reading outputs meanwhile
task automatic ide_in(input int d, input logic [127:0] x, input logic [31:0] w4);
  logic [11:0] a;
  int t;
  a = d == 0 ? A_TX0 : A_RX0;
  t = 0;
  rd(A_FLAGS);
  while (rdv[d == 0 ? FLAG_TX_FULL : FLAG_RX_FULL] && t < 400) begin
    if (rdv[d == 0 ? FLAG_TXO_AVAIL : FLAG_RXO_AVAIL]) ide_pop(d);
    rd(A_FLAGS); t++;
  end
  if (t >= 400) fail("input holding register stays full");
  for (int i = 0; i < 4; i++) wr(a + 12'(4 * i), x[32 * i +: 32]);
  wr(a + 12'd16, w4);
endtask
task automatic ide_tx(input logic [127:0] x, input int n, input logic hdr, input logic last, input logic ide,
                      input logic [1:0] sid, input logic [1:0] sub);
  ide_in(0, x, {20'd0, sub, sid, ide, last, hdr, 5'(n)});
endtask
task automatic ide_rx(input logic [127:0] x, input int n, input logic [1:0] k, input logic last, input logic cm,
                      input logic [1:0] sid);
  ide_in(1, x, {21'd0, sid, cm, last, k, 5'(n)});
endtask
task automatic ide_chk(input int d, input int i, input logic [127:0] x, input int n, input logic [1:0] k,
                       input logic l, input logic b, input logic c, input string what);
  int j;
  j = i % 256;
  if ((oq_d[d][j] & ide_mask(oq_n[d][j])) !== (x & ide_mask(n)) || oq_n[d][j] !== 5'(n) || oq_k[d][j] !== k
      || oq_l[d][j] !== l || oq_b[d][j] !== b || oq_c[d][j] !== c)
    fail($sformatf("%s: %h / %0d k%0d l%0d b%0d c%0d, expected %h / %0d k%0d l%0d b%0d c%0d", what,
                   oq_d[d][j], oq_n[d][j], oq_k[d][j], oq_l[d][j], oq_b[d][j], oq_c[d][j], x, n, k, l, b, c));
endtask

// ---------------- configuration and key management ----------------
task automatic ide_stream(input int s, input logic en, input logic cm, input logic [7:0] id, input logic [31:0] fix);
  ide_cfg[s] = en; ide_cfg[2 + s] = cm; ide_sid[8 * s +: 8] = id;
  wr(A_CFG, {21'd0, ide_cfg});
  wr(A_SID, {16'd0, ide_sid});
  wr(s == 0 ? A_IVFIX0 : A_IVFIX1, fix);
endtask
task automatic ide_agg(input int agg);
  ide_cfg[10:4] = 7'(agg);
  wr(A_CFG, {21'd0, ide_cfg});
endtask
// op: 0 prog, 1 go, 2 stop, 3 clr; ec: the km_code expected (0 none)
task automatic ide_km(input int op, input logic dir, input logic [1:0] sid, input logic ks, input logic [1:0] sub,
                      input logic [255:0] key, input logic sel, input logic [2:0] ec);
  wr(A_IRQ_STATUS, 32'h1 << IRQ_KM_ERR);
  wr(A_KM, {25'd0, sel, sub, ks, sid, dir});
  if (op == 0) begin
    if (sel) begin
      sl_key = key; sl_valid = ec != 3'd3;
      for (int i = 0; i < 8; i++) wr(A_KEY0 + 12'(4 * i), $urandom);
    end else begin
      sl_key = {ide_r128(), ide_r128()}; sl_valid = $urandom;
      for (int i = 0; i < 8; i++) wr(A_KEY0 + 12'(4 * i), key[32 * i +: 32]);
    end
  end
  wr(A_CMD, 32'h1 << op);
  cycles(2);
  rd(A_IRQ_STATUS);
  if (rdv[IRQ_KM_ERR] !== (ec != 3'd0)) fail($sformatf("km op %0d: KM_ERR %0d, expected code %0d", op, rdv[IRQ_KM_ERR], ec));
  rd(A_STATUS);
  if (ec != 3'd0 && rdv[12:10] !== ec) fail($sformatf("km op %0d: km_code %0d, expected %0d", op, rdv[12:10], ec));
endtask
task automatic ide_load(input int s, input logic ks, input logic [255:0] key);
  for (int d = 0; d < 2; d++) begin
    for (int sub = 0; sub < 3; sub++) ide_km(0, d, 2'(s), ks, 2'(sub), key, $urandom_range(0, 2) == 0, 3'd0);
    ide_km(1, d, 2'(s), ks, 2'd0, '0, 1'b0, 3'd0);
  end
  rd(A_STATUS);
  if (!rdv[s] || !rdv[2 + s] || rdv[4 + s] !== ks || rdv[6 + s] !== ks) fail($sformatf("stream %0d not Secure", s));
endtask

// ---------------- known-answer cases ----------------
task automatic ide_case(input int i);
  int s, t0, r0, nb, np, nh;
  s = c_s[i];
  if (c_prog[i] != 0) begin
    ide_stream(s, 1'b1, c_cm[i] != 0, c_id[i], c_fix[i]);
    ide_agg(c_agg[i]);
    ide_load(s, c_ks[i] != 0, c_key[i]);
  end
  nh = c_nh[i]; np = c_np[i];
  t0 = oqn[0]; r0 = oqn[1];
  wr(A_IRQ_STATUS, IRQ_ALL);
  if (c_cm[i] != 0) begin
    for (int f = 0; f <= c_agg[i]; f++)
      for (int j = 0; j < 4; j++) ide_tx(vb[c_ib[i] + 4 * f + j], 16, 1'b0, j == 3, 1'b1, 2'(s), 2'($urandom));
    nb = np + 1;
  end else begin
    for (int j = 0; j < nh; j++)
      ide_tx(vb[c_ib[i] + j], j == nh - 1 ? c_hb[i] : 16, 1'b1, j == nh - 1 && np == 0, 1'b1, 2'(s), 2'(c_sub[i]));
    for (int j = 0; j < np; j++)
      ide_tx(vb[c_ib[i] + nh + j], j == np - 1 ? c_pb[i] : 16, 1'b0, j == np - 1, 1'b1, 2'(s), 2'(c_sub[i]));
    nb = 1 + nh + np + 1;
  end
  ide_drain(0, t0 + nb);
  if (c_cm[i] == 0) begin
    ide_chk(0, t0, {c_pfx[i], 96'h0}, 4, IK_PFX, 0, 0, 0, $sformatf("case %0d prefix", i));
    for (int j = 0; j < nh; j++)
      ide_chk(0, t0 + 1 + j, vb[c_ib[i] + j], j == nh - 1 ? c_hb[i] : 16, IK_HDR, 0, 0, 0, $sformatf("case %0d header", i));
    for (int j = 0; j < np; j++)
      ide_chk(0, t0 + 1 + nh + j, vb[c_ob[i] + j], j == np - 1 ? c_pb[i] : 16, IK_DATA, 0, 0, 0,
              $sformatf("case %0d payload", i));
  end else
    for (int j = 0; j < np; j++)
      ide_chk(0, t0 + j, vb[c_ob[i] + j], 16, IK_DATA, j % 4 == 3, 0, 1, $sformatf("case %0d flit", i));
  ide_chk(0, t0 + nb - 1, {c_mac[i], 32'h0}, 12, IK_MAC, 1, 0, c_cm[i] != 0, $sformatf("case %0d MAC", i));
  rd(A_IRQ_STATUS);
  if (!rdv[IRQ_TX_MSG] || rdv[IRQ_TX_ERR]) fail($sformatf("case %0d: IRQ_STATUS %h after transmit", i, rdv));
  // back through the receive side
  for (int j = 0; j < nb; j++)
    ide_rx(oq_d[0][(t0 + j) % 256] | (ide_r128() & ~ide_mask(oq_n[0][(t0 + j) % 256])), oq_n[0][(t0 + j) % 256],
           oq_k[0][(t0 + j) % 256], oq_l[0][(t0 + j) % 256], oq_c[0][(t0 + j) % 256], 2'(s));
  ide_drain(1, r0 + nh + np + 1);
  for (int j = 0; j < nh; j++)
    ide_chk(1, r0 + j, vb[c_ib[i] + j], j == nh - 1 ? c_hb[i] : 16, IK_HDR, 0, 0, 0, $sformatf("case %0d rx header", i));
  for (int j = 0; j < np; j++)
    ide_chk(1, r0 + nh + j, vb[c_ib[i] + nh + j], j == np - 1 ? c_pb[i] : 16, IK_DATA, c_cm[i] != 0 && j % 4 == 3, 0,
            c_cm[i] != 0, $sformatf("case %0d rx data", i));
  ide_chk(1, r0 + nh + np, 128'h0, 0, IK_MAC, 1, 0, c_cm[i] != 0, $sformatf("case %0d rx end", i));
  rd(A_IRQ_STATUS);
  if (!rdv[IRQ_RX_MSG] || rdv[IRQ_RX_ERR]) fail($sformatf("case %0d: IRQ_STATUS %h after receive", i, rdv));
endtask

// expect error IRQ bit b with STATUS[hi:lo] == c
task automatic ide_err(input int b, input int lo, input logic [2:0] c, input string what);
  poll(A_IRQ_STATUS, 32'h1 << b, 32'h1 << b, 500);
  rd(A_STATUS);
  if (rdv[lo +: 3] !== c) fail($sformatf("%s: code %0d, expected %0d", what, rdv[lo +: 3], c));
  wr(A_IRQ_STATUS, IRQ_ALL);
endtask

task automatic ip_func;
  load_vecs();
  ide_cfg = '0; ide_sid = '0;
  oqn[0] = 0; oqn[1] = 0;
  wr(A_CMD, 32'h8);                                   // CMD.clr: no key left by the register tests
  // first with every interrupt masked: messages, errors, overflows
  wr(A_IRQ_ENABLE, 0);
  ide_misc(1'b0);
  if (irq) fail("irq while masked");
  wr(A_IRQ_ENABLE, 32'h1 << IRQ_KM_ERR);
  ide_km(1, 1'b0, 2'd0, 1'b0, 2'd0, '0, 1'b0, 3'd2);
  if (!irq) fail("no irq");
  wr(A_IRQ_STATUS, IRQ_ALL);
  wr(A_IRQ_ENABLE, IRQ_ALL);
  for (int i = 0; i < NC; i++) ide_case(i);
  ide_misc(1'b1);
  if (!irq) fail("no irq");                          // left pending for the final reset
  wr(A_CFG, 0);
  sl_valid = 1'b0;
  sl_key = '0;
endtask

// errors, overflows, a good and a tampered message, clr; long: an epoch over
// the length limit
task automatic ide_misc(input logic long);
  logic [255:0] k0;
  int t0, r0;
  rd(A_KV);
  if (long && rdv === 0) fail("KV: no slot loaded after the known-answer cases");
  ide_km(3, 1'b0, 2'd0, 1'b0, 2'd0, '0, 1'b0, 3'd0);
  ide_km(1, 1'b0, 2'd0, 1'b0, 2'd0, '0, 1'b0, 3'd2);
  // key management errors: stream 3, sideload key not valid, key set in use
  ide_km(0, 1'b1, 2'd3, 1'b0, 2'd0, {ide_r128(), ide_r128()}, 1'b0, 3'd1);
  ide_km(0, 1'b0, 2'd0, 1'b1, 2'd1, {ide_r128(), ide_r128()}, 1'b1, 3'd3);
  // a TLP stream 0 with a fresh key set 0 and a cachemem stream 1
  k0 = {ide_r128(), ide_r128()};
  for (int d = 0; d < 2; d++) for (int k = 0; k < 2; k++) ide_km(2, d, 2'd0, k, 2'd0, '0, 1'b0, 3'd0);
  ide_stream(0, 1'b1, 1'b0, 8'h77, 32'h0102_0304);
  ide_load(0, 1'b0, k0);
  ide_km(0, 1'b1, 2'd0, 1'b0, 2'd2, {ide_r128(), ide_r128()}, 1'b0, 3'd4);
  // transmit errors: a protected TLP for stream 3, a header block in the payload
  t0 = oqn[0];
  ide_tx(ide_r128(), 16, 1'b1, 1'b1, 1'b1, 2'd3, 2'd0);
  ide_err(IRQ_TX_ERR, 13, 3'd2, "transmit on stream 3");
  rd(A_STATUS);
  if (rdv[17:16] !== 2'd3) fail("tx_esid");
  ide_tx(ide_r128(), 16, 1'b1, 1'b0, 1'b1, 2'd0, 2'd1);
  ide_tx(ide_r128(), 16, 1'b0, 1'b0, 1'b1, 2'd0, 2'd1);
  ide_tx(ide_r128(), 16, 1'b1, 1'b1, 1'b1, 2'd0, 2'd1);
  ide_err(IRQ_TX_ERR, 13, 3'd1, "header block in the payload");
  ide_drain(0, t0 + 4);
  ide_chk(0, t0 + 3, 128'h0, 0, IK_MAC, 1, 1, 0, "nullified MAC");
  // receive: a good message, then a tampered one (MAC mismatch, stream Insecure)
  ide_load(0, 1'b1, k0);
  t0 = oqn[0]; r0 = oqn[1];
  ide_tx(ide_r128(), 12, 1'b1, 1'b0, 1'b1, 2'd0, 2'd0);
  ide_tx(ide_r128(), 7, 1'b0, 1'b1, 1'b1, 2'd0, 2'd0);
  ide_drain(0, t0 + 4);
  for (int j = 0; j < 4; j++)
    ide_rx(oq_d[0][(t0 + j) % 256], oq_n[0][(t0 + j) % 256], oq_k[0][(t0 + j) % 256], oq_l[0][(t0 + j) % 256], 1'b0, 2'd0);
  ide_drain(1, r0 + 3);
  ide_chk(1, r0 + 2, 128'h0, 0, IK_MAC, 1, 0, 0, "good END");
  t0 = oqn[0]; r0 = oqn[1];
  ide_tx(ide_r128(), 12, 1'b1, 1'b0, 1'b1, 2'd0, 2'd2);
  ide_tx(ide_r128(), 16, 1'b0, 1'b1, 1'b1, 2'd0, 2'd2);
  ide_drain(0, t0 + 4);
  for (int j = 0; j < 4; j++)
    ide_rx(oq_d[0][(t0 + j) % 256] ^ (j == 2 ? 128'h1 << 100 : 128'h0), oq_n[0][(t0 + j) % 256],
           oq_k[0][(t0 + j) % 256], oq_l[0][(t0 + j) % 256], 1'b0, 2'd0);
  ide_err(IRQ_RX_ERR, 18, 3'd7, "tampered message");
  ide_drain(1, r0 + 3);
  ide_chk(1, r0 + 2, 128'h0, 0, IK_MAC, 1, 1, 0, "bad END");
  rd(A_STATUS);
  if (rdv[2] || rdv[28:21] !== 8'h77) fail("receive stream still Secure / rx_eid");
  // an unknown Stream ID
  ide_rx({8'h92, 1'b1, 1'b0, 6'd0, 8'h88, 8'h0, 96'h0}, 4, IK_PFX, 1'b0, 1'b0, 2'd0);
  ide_err(IRQ_RX_ERR, 18, 3'd6, "unknown Stream ID");
  ide_rx(ide_r128(), 16, IK_HDR, 1'b1, 1'b0, 2'd0);   // the rest of that TLP is dropped
  cycles(20);
  rd(A_FLAGS);
  if (rdv[FLAG_RXO_AVAIL]) fail("output after an unknown Stream ID");
  // TX / RX overflow: a bypass TLP whose output is not read until both
  // holding registers stay full; one more write is dropped
  for (int d = 0; d < 2; d++) begin
    int n0;
    wr(A_IRQ_STATUS, IRQ_ALL);
    n0 = oqn[d];
    for (int j = 0; j < 4; j++) begin
      for (int i = 0; i < 4; i++) wr((d == 0 ? A_TX0 : A_RX0) + 12'(4 * i), $urandom);
      wr(d == 0 ? A_TX4 : A_RX4, d == 0 ? {25'd0, 1'b0, 1'b0, 5'd16} : {25'd0, 2'd0, 5'd16});
    end
    rd(A_IRQ_STATUS);
    if (!rdv[d == 0 ? IRQ_TX_OVF : IRQ_RX_OVF]) fail("no overflow");
    if (!rdv[d == 0 ? IRQ_TXO_AVAIL : IRQ_RXO_AVAIL]) fail("no output");
    // the rest of the TLP: a last block
    if (d == 0) ide_tx(ide_r128(), 16, 1'b1, 1'b1, 1'b0, 2'd0, 2'd0);
    else ide_rx(ide_r128(), 16, IK_HDR, 1'b1, 1'b0, 2'd0);
    ide_drain(d, n0 + 4);
    for (int j = 0; j < 8; j++) begin rd(A_FLAGS); if (rdv[d == 0 ? FLAG_TXO_AVAIL : FLAG_RXO_AVAIL]) ide_pop(d); end
    wr(A_IRQ_STATUS, IRQ_ALL);
  end
  rd(A_RXO4);                                          // empty: no effect
  // a cachemem flit for stream 3
  ide_rx(ide_r128(), 16, IK_DATA, 1'b1, 1'b1, 2'd3);
  ide_err(IRQ_RX_ERR, 18, 3'd2, "flit for stream 3");
  // CMD.clr in the middle of a message, with output waiting in TXO
  ide_stream(1, 1'b1, 1'b1, 8'h62, 32'h5);
  ide_agg(3);
  ide_load(1, 1'b0, {ide_r128(), ide_r128()});
  for (int j = 0; j < 3; j++) ide_tx(ide_r128(), 16, 1'b0, j == 2, 1'b1, 2'd1, 2'd0);
  rd(A_STATUS);
  if (!rdv[8]) fail("not busy in an epoch");
  ide_km(3, 1'b0, 2'd0, 1'b0, 2'd0, '0, 1'b0, 3'd0);
  rd(A_STATUS);
  if (rdv[9:0] !== 0) fail($sformatf("STATUS %h after CMD.clr", rdv));
  rd(A_KV);
  if (rdv !== 0) fail("KV after CMD.clr");
  for (int j = 0; j < 8; j++) begin rd(A_FLAGS); if (rdv[FLAG_TXO_AVAIL]) ide_pop(0); end
  rd(A_TXO4);                                          // empty: no effect
  if (long) begin
    // an epoch of 128 flits of 32 blocks is over the 2^16 - 1 byte limit
    ide_load(1, 1'b1, {ide_r128(), ide_r128()});
    ide_agg(127);
    for (int j = 0; j < 4096; j++) ide_tx(ide_r128(), 16, 1'b0, j % 32 == 31, 1'b1, 2'd1, 2'd0);
    ide_err(IRQ_TX_ERR, 13, 3'd5, "epoch over the length limit");
    for (int j = 0; j < 8; j++) begin rd(A_FLAGS); if (rdv[FLAG_TXO_AVAIL]) ide_pop(0); end
    ide_km(3, 1'b0, 2'd0, 1'b0, 2'd0, '0, 1'b0, 3'd0);
  end
  ide_agg(0);
endtask
