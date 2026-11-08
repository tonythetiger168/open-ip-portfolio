// SPDX-License-Identifier: Apache-2.0
// Video_Codec_8K-specific part of tb/Video_Codec_8K_apb_tb.sv. An
// soc_ss_axi_mem subordinate sits on the AXI4 manager pins m_*. Covered
// through the registers: a 2 x 1 CTU picture (CTU 16, PU 16, one reference)
// with the reconstruction checked in memory, CTUS, WR_WORDS, RD_WORDS,
// RD_SUM, CYCLES, DONE, CTU_GAP 1 (every CTU LATE, LATE interrupt), CTU_LIMIT,
// CFG_ERR, ERR on an AXI read error.
`include "apb/tv_apb_common.svh"

localparam logic [31:0] V8_SEED = 32'h5EED_0001;
task automatic v8_setup(input logic [31:0] codings, input logic [31:0] rate);
  wr(A_BS_ADDR, 32'h1000_0000); wr(A_REF0_ADDR, 32'h2000_0000); wr(A_REF1_ADDR, 32'h3000_0000);
  wr(A_RECON_ADDR, 32'h4000_0000); wr(A_CHROMA_ADDR, 32'h5000_0000);
  wr(A_PIC, {8'd1, 8'd2, 16'd32});                   // 2 x 1 CTUs, stride 32
  wr(A_CODING, codings); wr(A_RATE, rate); wr(A_SEED, V8_SEED);
endtask
// CTU 16 (4), PU 16 (4), 1 reference, MV 2^2, 4 bitstream words
localparam logic [31:0] V8_CODING = 32'(4) | (32'(4) << 3) | (32'(1) << 6) | (32'(2) << 8) | (32'(4) << 11);

task automatic ip_func;
  for (int i = 0; i < 64; i++) mem.poke(32'h1000_0000 + 32'(4 * i), $urandom);
  for (int i = 0; i < 16 * 8; i++) mem.poke(32'h2000_0000 + 32'(4 * i), $urandom);
  v8_setup(V8_CODING, 0);
  tv_job(A_CMD, 0, A_STATUS, 0, 2000);
  rd_exp(A_CTUS, 2);
  rd_exp(A_WR_WORDS, 2 * (16 + 8) * 4);
  rd(A_RD_WORDS);
  if (rdv < 2 * (4 + 23 * 6) || rdv > 2 * (4 + 23 * 7)) fail($sformatf("RD_WORDS %0d", rdv));
  rd(A_RD_SUM);
  if (rdv == 0) fail("RD_SUM 0");
  rd(A_CYCLES);
  if (rdv == 0) fail("CYCLES 0");
  for (int r = 0; r < 16; r++) for (int x = 0; x < 8; x++) begin
    logic [31:0] a;
    a = 32'h4000_0000 + 32'(32 * r + 4 * x);
    if (mem.peek(a) !== (a ^ V8_SEED)) begin fail($sformatf("luma word at %h", a)); break; end
  end
  for (int r = 0; r < 8; r++) for (int x = 0; x < 8; x++) begin
    logic [31:0] a;
    a = 32'h5000_0000 + 32'(32 * r + 4 * x);
    if (mem.peek(a) !== (a ^ V8_SEED)) begin fail($sformatf("chroma word at %h", a)); break; end
  end
  tv_no_irq(IRQ_LATE, "no CTU_GAP");
  tv_irq(IRQ_DONE, "picture");
  // a 1-clock CTU slot: both CTUs late; CTU_LIMIT 1 stops after one
  v8_setup(V8_CODING, {16'd0, 16'd1});
  tv_job(A_CMD, 0, A_STATUS, 0, 2000);
  rd_exp(A_CTUS, {16'd2, 16'd2});
  tv_irq(IRQ_LATE, "CTU_GAP 1");
  v8_setup(V8_CODING, {16'd1, 16'd0});
  tv_job(A_CMD, 0, A_STATUS, 0, 2000);
  rd_exp(A_CTUS, 1);
  wr(A_IRQ_STATUS, IRQ_ALL);
  // CFG_ERR: CTU_LOG2 3
  v8_setup(V8_CODING & ~32'h7 | 32'h3, 0);
  tv_job(A_CMD, 0, A_STATUS, 0, 10);
  rd(A_STATUS);
  if (rdv[2] !== 1'b1) fail("no STATUS.cfg_err for CTU_LOG2 3");
  tv_irq(IRQ_DONE, "CFG_ERR");
  // AXI read error on the bitstream
  mem.err_lo = 32'h1000_0004; mem.err_hi = mem.err_lo + 4;
  v8_setup(V8_CODING, 0);
  tv_job(A_CMD, 0, A_STATUS, 0, 2000);
  rd(A_STATUS);
  if (rdv[1] !== 1'b1) fail("no STATUS.err after an AXI error");
  tv_irq(IRQ_ERR, "AXI error");
  mem.err_lo = '1; mem.err_hi = '1;
  if (mem.errors != 0) fail("AXI rule violations");
endtask
