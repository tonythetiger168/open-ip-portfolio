// SPDX-License-Identifier: Apache-2.0
// AES_GCM-specific part of tb/AES_GCM_apb_tb.sv: messages run entirely
// through the registers (CTRL, KEY, IV, TAG_IN, CMD, IN0..IN4, OUT0..OUT4,
// TAG, STATUS, IRQ_STATUS), with the core at its default LEN_W = 36: every
// 16th case of tb/AES_GCM_vec.svh (NIST CAVP, Wycheproof and random
// cases, both key sizes, both directions, right and wrong tags), the key
// from the KEY registers or from the sideload pins, outputs and tags
// compared; then an IN overflow (a beat written while the holding register
// is full), each error class through IRQ ERR and STATUS.err_code, and
// CMD.clr in the middle of a message.
`include "AES_GCM_vec.svh"
initial begin
  sl_key = '0;
  sl_valid = 1'b0;
end

task automatic ag_cfg(input logic k256, input logic dec, input logic ks, input logic [3:0] tl,
                      input logic [255:0] k, input logic [95:0] v, input logic [127:0] ti);
  wr(A_IRQ_STATUS, IRQ_ALL);
  wr(A_CTRL, {25'd0, tl, ks, dec, k256});
  if (ks) begin
    sl_key = k; sl_valid = 1'b1;
    for (int i = 0; i < 8; i++) wr(A_KEY0 + 12'(4 * i), $urandom);
  end else begin
    sl_key = {$urandom, $urandom, $urandom, $urandom, $urandom, $urandom, $urandom, $urandom};
    sl_valid = $urandom;
    for (int i = 0; i < 8; i++) wr(A_KEY0 + 12'(4 * i), k[32 * i +: 32]);
  end
  for (int i = 0; i < 3; i++) wr(A_IV0 + 12'(4 * i), v[32 * i +: 32]);
  for (int i = 0; i < 4; i++) wr(A_TAG_IN0 + 12'(4 * i), ti[32 * i +: 32]);
endtask

// write one block once the IN holding register is free
task automatic ag_in(input logic [127:0] d, input int n, input logic aad, input logic last);
  poll(A_FLAGS, 32'h1 << FLAG_IN_FULL, 0, 200);
  for (int i = 0; i < 4; i++) wr(A_IN0 + 12'(4 * i), d[32 * i +: 32]);
  wr(A_IN4, {25'd0, last, aad, 5'(n)});
endtask

// read one output block and compare it
task automatic ag_out(input logic [127:0] e, input int n, input logic last);
  logic [127:0] d;
  poll(A_FLAGS, 32'h1 << FLAG_OUT_AVAIL, 32'h1 << FLAG_OUT_AVAIL, 200);
  for (int i = 0; i < 4; i++) begin rd(A_OUT0 + 12'(4 * i)); d[32 * i +: 32] = rdv; end
  rd(A_OUT4);
  if (d !== e || rdv[4:0] !== 5'(n) || rdv[5] !== last)
    fail($sformatf("OUT %h / %0d / %0d, expected %h / %0d / %0d", d, rdv[4:0], rdv[5], e, n, last));
endtask

function automatic logic [127:0] ag_mask(input int n);
  logic [127:0] m;
  for (int i = 0; i < 16; i++) m[127 - 8 * i -: 8] = i < n ? 8'hff : 8'h00;
  return m;
endfunction

// lag: read each output block only after the next input block (OUT is then
// popped in the clock the core's next block arrives)
task automatic ag_vec(input int i, input logic lag);
  int na, np;
  logic [127:0] t;
  na = (v_alen[i] + 15) / 16;
  np = (v_plen[i] + 15) / 16;
  ag_cfg(v_k256[i], v_dec[i], i % 3 == 0, v_tlen[i], v_key[i], v_iv[i], v_dec[i] ? v_tag[i] : 128'h0);
  wr(A_CMD, 32'h1);
  for (int j = 0; j < na; j++)
    ag_in(vb[v_ab[i] + j], j == na - 1 ? v_alen[i] - 16 * j : 16, 1'b1, j == na - 1 && np == 0);
  for (int j = 0; j < np; j++) begin
    ag_in(vb[v_xb[i] + j], j == np - 1 ? v_plen[i] - 16 * j : 16, 1'b0, j == np - 1);
    if (!lag) ag_out(vb[v_ob[i] + j] & ag_mask(v_plen[i] - 16 * j), j == np - 1 ? v_plen[i] - 16 * j : 16, j == np - 1);
    else if (j > 0) ag_out(vb[v_ob[i] + j - 1], 16, 1'b0);
  end
  if (lag && np > 0) ag_out(vb[v_ob[i] + np - 1] & ag_mask(v_plen[i] - 16 * (np - 1)), v_plen[i] - 16 * (np - 1), 1'b1);
  if (na + np == 0) ag_in(128'h0, 0, 1'b0, 1'b1);
  poll(A_IRQ_STATUS, 32'h3, 32'h1 << IRQ_DONE, 500);
  for (int k = 0; k < 4; k++) begin rd(A_TAG0 + 12'(4 * k)); t[32 * k +: 32] = rdv; end
  rd(A_STATUS);
  if (rdv[0]) fail($sformatf("case %0d: busy after DONE", i));
  if (v_dec[i] ? t !== 0 || rdv[1] !== v_ok[i] : t !== v_tag[i] || rdv[1] !== 1'b0)
    fail($sformatf("case %0d: TAG %h tag_ok %0d", i, t, rdv[1]));
endtask

// an error: one block (or a start with no sideload key), then IRQ ERR and the code
task automatic ag_err(input int n, input logic aad, input logic last, input logic [2:0] code, input logic ks);
  ag_cfg($urandom, $urandom, ks, 4'd0, {8{$urandom}}, {3{$urandom}}, 128'h0);
  if (ks) sl_valid = 1'b0;
  wr(A_CMD, 32'h1);
  if (!ks) begin
    if (code == 3'd2) ag_in({4{$urandom}}, 9, 1'b1, 1'b0);          // a partial AAD block, then more AAD
    ag_in({4{$urandom}}, n, aad, last);
  end
  poll(A_IRQ_STATUS, 32'h3, 32'h1 << IRQ_ERR, 500);
  rd(A_STATUS);
  if (rdv[0] || rdv[4:2] !== code) fail($sformatf("STATUS %h after error, expected code %0d", rdv, code));
endtask

task automatic ip_func;
  load_vecs();
  // first with every interrupt masked: a message, an IN overflow, an error
  wr(A_IRQ_ENABLE, 0);
  ag_vec(NV - 2, 1'b1);
  ag_ovf();
  ag_err(17, 1'b0, 1'b1, 3'd1, 1'b0);
  if (irq) fail("irq while masked");
  wr(A_IRQ_ENABLE, IRQ_ALL);
  for (int i = 0; i < NV; i += 16) ag_vec(i, i % 32 == 16);
  ag_ovf();
  if (!irq) fail("no irq");
  // errors: format, order, sideload key not valid
  ag_err(17, 1'b0, 1'b1, 3'd1, 1'b0);
  ag_err(16, 1'b1, 1'b0, 3'd2, 1'b0);
  ag_err(0, 1'b0, 1'b0, 3'd4, 1'b1);
  // clr in the middle of a message, with an output block waiting in OUT
  ag_cfg(1'b0, 1'b0, 1'b0, 4'd0, {8{$urandom}}, {3{$urandom}}, 128'h0);
  wr(A_CMD, 32'h1);
  ag_in({4{$urandom}}, 16, 1'b0, 1'b0);
  ag_in({4{$urandom}}, 16, 1'b0, 1'b0);
  wr(A_CMD, 32'h2);
  rd(A_STATUS);
  if (rdv[0]) fail("busy after CMD.clr");
  rd(A_OUT4);
  rd(A_OUT4);                                         // empty: no effect (the checker models it)
  rd(A_IRQ_STATUS);
  if (rdv[IRQ_DONE] || rdv[IRQ_ERR]) fail("DONE or ERR after CMD.clr");
  sl_valid = 1'b0;
  sl_key = '0;
endtask

// IN overflow: an end block written before any message is held (FULL); a
// second write is dropped (IN_OVF); the next message takes the held block
task automatic ag_ovf;
  wr(A_IRQ_STATUS, IRQ_ALL);
  wr(A_IN4, 32'h40);
  wr(A_IN4, 32'h40);
  rd(A_IRQ_STATUS);
  if (!rdv[IRQ_IN_OVF]) fail("IN_OVF not raised");
  ag_cfg(1'b1, 1'b0, 1'b0, 4'd0, {8{$urandom}}, {3{$urandom}}, 128'h0);
  wr(A_CMD, 32'h1);
  poll(A_IRQ_STATUS, 32'h3, 32'h1 << IRQ_DONE, 500);
endtask
