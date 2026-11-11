// SPDX-License-Identifier: Apache-2.0
// Crypto_DMA-specific part of tb/Crypto_DMA_apb_tb.sv: a behavioural AXI4
// memory on the m_* pins and a key-manager sideload port driven by the TB.
// Through the registers:
// - three messages of tb/Crypto_DMA_vec.svh (AES-128 encrypt with AAD and
//   text, AES-128 decrypt with a 4-byte tag, AES-256 decrypt of 257 bytes)
//   checked against their expected text and tag (KEY, IV, TAG_IN, LEN, TAG,
//   STATUS.tag_ok, DONE interrupt, output bytes); one of them again with the
//   key on the sideload port;
// - 16 random round trips (AES-128 / 256, random key, IV, lengths, buffers
//   anywhere in memory): encrypt, then decrypt with the TAG read back
//   (TAG_OK = 1, plaintext restored) and with one tag bit flipped
//   (TAG_OK = 0); some with the interrupts masked;
// - an AXI read error and an AXI write error (STATUS.err, ERR interrupt),
//   a sideload key that is not valid (STATUS.gcm_err, ERR_CODE 4);
// - Verilator only: a round trip of the largest message (65535 AAD bytes,
//   65535 text bytes).
// The full message set is in tb/Crypto_DMA_tb.sv.
`include "Crypto_DMA_vec.svh"
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
initial begin sl_key = 0; sl_valid = 0; end
function automatic int up16(input int n); return (n + 15) / 16 * 16; endfunction
function automatic void poke_byte(input logic [31:0] a, input logic [7:0] b);
  logic [31:0] w;
  w = axm.peek({a[31:2], 2'b00}); w[8 * a[1:0] +: 8] = b; axm.poke({a[31:2], 2'b00}, w);
endfunction
function automatic logic [7:0] peek_byte(input logic [31:0] a);
  logic [31:0] w;
  w = axm.peek({a[31:2], 2'b00}); return w[8 * a[1:0] +: 8];
endfunction
task automatic job(input int v, input logic ksel, input logic [3:0] exp_irq);
  logic [31:0] s, d;
  int al, pl, k;
  al = v_alen[v]; pl = v_plen[v]; s = 32'h0000_3000; d = 32'h0001_0000;
  for (int i = 0; i < al; i++) poke_byte(s + 32'(i), vd[v_off[v] + i]);
  for (int i = al; i < up16(al); i++) poke_byte(s + 32'(i), 8'h00);
  for (int i = 0; i < pl; i++) poke_byte(s + 32'(up16(al) + i), vd[v_off[v] + al + i]);
  wr(A_CTRL, {25'd0, v_tlen[v], ksel, v_dec[v], v_k256[v]});
  for (int i = 0; i < 8; i++) wr(A_KEY0 + 12'(4 * i), v_key[v][32 * i +: 32]);
  for (int i = 0; i < 3; i++) wr(A_IV0 + 12'(4 * i), v_iv[v][32 * i +: 32]);
  for (int i = 0; i < 4; i++) wr(A_TAG_IN0 + 12'(4 * i), v_tag[v][32 * i +: 32]);
  rd_exp(A_KEY3, 0);                                         // write-only
  wr(A_SRC_ADDR, s); wr(A_DST_ADDR, d); wr(A_LEN, {16'(pl), 16'(al)});
  wr(A_CMD, 32'h1);
  poll(A_IRQ_STATUS, 32'h1, 32'h1, 50000);
  rd_exp(A_IRQ_STATUS, 32'(exp_irq));
  wr(A_IRQ_STATUS, 32'h3);
  rd(A_STATUS); if (rdv[0] !== 1'b0) fail("STATUS.busy high after DONE");
  if (exp_irq != 4'h1) return;
  for (int i = 0; i < pl; i++)
    if (peek_byte(d + 32'(i)) !== vd[v_off[v] + al + pl + i]) fail($sformatf("case %0d byte %0d", v, i));
  if (!v_dec[v]) for (int i = 0; i < 4; i++) rd_exp(A_TAG0 + 12'(4 * i), v_tag[v][32 * i +: 32]);
  else if (rdv[6] !== v_ok[v]) fail($sformatf("case %0d STATUS.tag_ok %b", v, rdv[6]));
  rd(A_CYCLES); if (rdv == 0) fail("CYCLES = 0");
endtask
// wait for DONE (IRQ_STATUS, so it also works with the interrupts masked)
task automatic gwait(input logic [31:0] st, input int lim = 50000);
  poll(A_IRQ_STATUS, 32'h1, 32'h1, lim);
  rd_exp(A_IRQ_STATUS, st);
  wr(A_IRQ_STATUS, 32'h3);
endtask
int rt_n = 0;
// encrypt al AAD bytes + pl text bytes from s to d, then decrypt d back to e
// with the tag read from TAG, and once more with a flipped tag bit
task automatic rtrip(input logic [31:0] reg_, input int al, input int pl, input bit k256,
                     input logic [3:0] tlen, input int lim = 50000);
  logic [31:0] s, d, s2, e, h0;
  logic [255:0] key;
  logic [95:0]  iv;
  logic [127:0] tag;
  logic [7:0]   aad [];
  logic [7:0]   pt [];
  aad = new[al]; pt = new[pl];
  for (int i = 0; i < 8; i++) key[32 * i +: 32] = $urandom;
  for (int i = 0; i < 3; i++) iv[32 * i +: 32] = $urandom;
  // four buffers in one 1 MB region, in its four 256 KB quarters (no
  // aliasing in the memory model), each at a random word offset
  h0 = reg_ & 32'hFFF0_0000;
  begin
    logic [1:0] q [4];
    for (int i = 0; i < 4; i++) q[i] = 2'(i);
    for (int i = 3; i > 0; i--) begin      // random order of the four quarters
      int j; logic [1:0] x;
      j = $urandom % (i + 1); x = q[i]; q[i] = q[j]; q[j] = x;
    end
    s  = h0 | {12'd0, q[0], 18'd0};
    d  = h0 | {12'd0, q[1], 18'd0};
    s2 = h0 | {12'd0, q[2], 18'd0};
    e  = h0 | {12'd0, q[3], 18'd0};
  end
  if (pl < 1024 && rt_n == 0) begin        // 5 and 6 words before a 4 KB boundary: short bursts
    s  = s  | 32'h0_0FEC; d  = d  | 32'h0_1FE8;
    s2 = s2 | 32'h0_2FE8; e  = e  | 32'h0_3FEC;
  end else if (pl < 1024) begin
    s  = s  | 32'(($urandom % 65400) * 4);
    d  = d  | 32'(($urandom % 65400) * 4);
    s2 = s2 | 32'(($urandom % 65400) * 4);
    e  = e  | 32'(($urandom % 65400) * 4);
  end
  rt_n++;
  for (int i = 0; i < al; i++) aad[i] = $urandom;
  for (int i = 0; i < pl; i++) pt[i] = $urandom;
  for (int i = 0; i < al; i++) begin poke_byte(s + 32'(i), aad[i]); poke_byte(s2 + 32'(i), aad[i]); end
  for (int i = al; i < up16(al); i++) begin poke_byte(s + 32'(i), 8'h00); poke_byte(s2 + 32'(i), 8'h00); end
  for (int i = 0; i < pl; i++) poke_byte(s + 32'(up16(al) + i), pt[i]);
  for (int i = 0; i < 8; i++) wr(A_KEY0 + 12'(4 * i), key[32 * i +: 32]);
  for (int i = 0; i < 3; i++) wr(A_IV0 + 12'(4 * i), iv[32 * i +: 32]);
  wr(A_CTRL, {25'd0, tlen, 1'b0, 1'b0, k256});
  wr(A_SRC_ADDR, s); wr(A_DST_ADDR, d); wr(A_LEN, {16'(pl), 16'(al)});
  wr(A_CMD, 32'h1);
  gwait(32'h1, lim);
  for (int i = 0; i < 4; i++) begin rd(A_TAG0 + 12'(4 * i)); tag[32 * i +: 32] = rdv; end
  for (int i = 0; i < pl; i++) poke_byte(s2 + 32'(up16(al) + i), peek_byte(d + 32'(i)));
  for (int f = 0; f < 2; f++) begin
    logic [127:0] t;
    t = tag;
    if (f == 1) begin
      int b;
      b = 127 - int'($urandom % (tlen == 0 ? 128 : 8 * int'(tlen)));     // the compared bytes are the top ones
      t[b] = ~t[b];
    end
    for (int i = 0; i < 4; i++) wr(A_TAG_IN0 + 12'(4 * i), t[32 * i +: 32]);
    for (int i = 0; i < 8; i++) wr(A_KEY0 + 12'(4 * i), key[32 * i +: 32]);
    for (int i = 0; i < 3; i++) wr(A_IV0 + 12'(4 * i), iv[32 * i +: 32]);
    wr(A_CTRL, {25'd0, tlen, 1'b0, 1'b1, k256});
    wr(A_SRC_ADDR, s2); wr(A_DST_ADDR, e); wr(A_LEN, {16'(pl), 16'(al)});
    wr(A_CMD, 32'h1);
    gwait(32'h1, lim);
    rd(A_STATUS);
    if (rdv[6] !== (f == 0)) fail($sformatf("round trip %0d+%0d: TAG_OK %b with tag %s (tlen %0d, tag %h, sent %h)", al, pl, rdv[6], f ? "flipped" : "as read", tlen, tag, t));
    if (f == 0) for (int i = 0; i < pl; i++)
      if (peek_byte(e + 32'(i)) !== pt[i]) begin fail($sformatf("round trip %0d+%0d: byte %0d %h, expected %h (e %h)", al, pl, i, peek_byte(e + 32'(i)), pt[i], e)); i = pl; end
  end
endtask
task automatic ip_func;
  load_vecs();
  // the sideload port: every bit both ways, the valid strobe as well
  sl_key = '1; sl_valid = 1; cycles(2); sl_key = '0; sl_valid = 0; cycles(2);
  wr(A_IRQ_ENABLE, 32'h3);
  job(4, 0, 4'h1);
  job(10, 0, 4'h1);
  job(8, 0, 4'h1);
  sl_key = v_key[4]; sl_valid = 1;
  for (int i = 0; i < 8; i++) v_key[4][32 * i +: 32] = $urandom;   // KEY regs hold junk now
  job(4, 1, 4'h1);
  sl_valid = 0; sl_key = '0;
  for (int r = 0; r < 16; r++) begin
    wr(A_IRQ_ENABLE, (r % 4 == 3) ? 32'h0 : 32'h3);
    rtrip($urandom, 1 + $urandom % 70, 40 + $urandom % 300, r % 2, 4'(r % 3 == 0 ? 0 : 1 + $urandom % 15));
  end
  rd_exp(A_FLAGS, 0);
  wr(A_IRQ_ENABLE, 32'h3);
  load_vecs();
  axm.err_lo = 32'h0000_3000; axm.err_hi = 32'h0000_3004;
  job(4, 0, 4'h3);
  rd(A_STATUS); if (rdv[2:1] !== 2'b01) fail($sformatf("STATUS after an AXI read error %h", rdv));
  wr(A_IRQ_ENABLE, 32'h0);                                   // masked: DONE and ERR latch, irq low
  axm.err_lo = 32'h0001_0010; axm.err_hi = 32'h0001_0014;
  wr(A_CTRL, {25'd0, v_tlen[4], 1'b0, v_dec[4], v_k256[4]});
  wr(A_SRC_ADDR, 32'h0000_3000); wr(A_DST_ADDR, 32'h0001_0000); wr(A_LEN, {16'(v_plen[4]), 16'(v_alen[4])});
  wr(A_CMD, 32'h1);
  poll(A_IRQ_STATUS, 32'h1, 32'h1, 50000);
  rd_exp(A_IRQ_STATUS, 32'h3);
  if (irq !== 1'b0) fail("irq high with DONE / ERR masked");
  rd(A_STATUS); if (rdv[2:1] !== 2'b01) fail($sformatf("STATUS after an AXI write error %h", rdv));
  wr(A_IRQ_STATUS, 32'h3);
  wr(A_IRQ_ENABLE, 32'h3);
  axm.err_lo = '1; axm.err_hi = '1;
  job(4, 1, 4'h3);
  rd(A_STATUS); if (rdv[2] !== 1'b1 || rdv[5:3] !== 3'd4) fail($sformatf("STATUS after a sideload error %h", rdv));
`ifdef VERILATOR
  rtrip(32'h0A50_0000, 65535, 65535, 1, 4'd0, 4000000);
`endif
  if (axm.errors != 0) fail("AXI rule violations");
  // DONE left pending into the final reset, with the interrupts masked
  wr(A_IRQ_ENABLE, 0);
  wr(A_CTRL, 0); wr(A_LEN, 32'h0001_0000); wr(A_CMD, 32'h1);
  poll(A_IRQ_STATUS, 32'h1, 32'h1, 50000);
endtask
