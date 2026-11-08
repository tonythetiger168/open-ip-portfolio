// SPDX-License-Identifier: Apache-2.0
// Crypto_DMA-specific part of tb/Crypto_DMA_apb_tb.sv: a behavioural AXI4
// memory on the m_* pins; three messages of tb/Crypto_DMA_vec.svh (AES-128
// encrypt with AAD and text, AES-128 decrypt with a 4-byte tag, AES-256
// decrypt of 257 bytes) programmed and checked through the registers (KEY,
// IV, TAG_IN, LEN, TAG, STATUS.tag_ok, DONE interrupt, output bytes), then
// an AXI read error (STATUS.err, ERR interrupt) and a sideload key that is
// not valid (STATUS.gcm_err, ERR_CODE 4). The full message set is in
// tb/Crypto_DMA_tb.sv.
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
  k = 0;
  while (!irq && k < 50000) begin @(negedge PCLK); k++; end
  if (!irq) fail($sformatf("case %0d: no interrupt", v));
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
task automatic ip_func;
  load_vecs();
  wr(A_IRQ_ENABLE, 32'h3);
  job(4, 0, 4'h1);
  job(10, 0, 4'h1);
  job(8, 0, 4'h1);
  axm.err_lo = 32'h0000_3000; axm.err_hi = 32'h0000_3004;
  job(4, 0, 4'h3);
  rd(A_STATUS); if (rdv[2:1] !== 2'b01) fail($sformatf("STATUS after an AXI error %h", rdv));
  axm.err_lo = '1; axm.err_hi = '1;
  job(4, 1, 4'h3);
  rd(A_STATUS); if (rdv[2] !== 1'b1 || rdv[5:3] !== 3'd4) fail($sformatf("STATUS after a sideload error %h", rdv));
  wr(A_CTRL, 0); wr(A_IRQ_ENABLE, 0);
  if (axm.errors != 0) fail("AXI rule violations");
endtask
