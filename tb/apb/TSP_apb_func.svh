// SPDX-License-Identifier: Apache-2.0
// TSP-specific part of tb/TSP_apb_tb.sv. An soc_ss_axi_mem subordinate sits
// on the AXI4 manager pins m_*; packets are built and scrambled by the TS
// packet model of tb/tsp_pkt_model.svh. Covered through the registers:
// keys loaded through KEY0..3 (write-only, read 0) and CMD.key_load
// (STATUS.key_busy), slots through SLOT_SEL / SLOT_CFG / CMD.slot_load, a
// mixed job (even and odd keys, clear packets, a missing key, adaptation
// fields, an unmatched PID, a bad sync byte, routes A / B / both), PCR
// capture, buffers full (OVF), CTRL.keep_tsc, AXI read and write errors (ERR,
// STATUS.err), irq masking.
// Coverage closure: input packets read from 0x7FFF_FFFC and output packets
// written there (1 beat, then 16-beat bursts from 0x8000_0000), PCRs whose
// fields are all ones and all zeros, an interrupt left pending for the
// reset that follows, FLAGS read.
`include "apb/tv_apb_common.svh"
bit tsp_keep = 0;
`define TSP_KEEP_TSC tsp_keep
`include "tsp_pkt_model.svh"

logic [31:0] t_src, t_a, t_b;
logic [15:0] t_amax, t_bmax;
task automatic t_key(input int s, input bit o, input logic [127:0] k);
  logic [31:0] w [4];
  for (int i = 0; i < 16; i++) w[i / 4][8 * (i % 4) +: 8] = k[127 - 8 * i -: 8];
  wr(A_SLOT_SEL, {29'd0, o, 2'(s)});
  wr(A_KEY0, w[0]); wr(A_KEY1, w[1]); wr(A_KEY2, w[2]); wr(A_KEY3, w[3]);
  wr(A_CMD, 2);
  rd(A_STATUS);
  if (rdv[1] !== 1'b1) fail("STATUS.key_busy low right after CMD.key_load");
  poll(A_STATUS, 32'h2, 32'h0, 50);
  if (o) begin kod[s] = k; kod_ok[s] = 1; end else begin kev[s] = k; kev_ok[s] = 1; end
endtask
task automatic t_slot(input int s, input logic [12:0] p, input bit v, input logic [1:0] r);
  wr(A_SLOT_SEL, 32'(s));
  wr(A_SLOT_CFG, {16'd0, r, v, p});
  wr(A_CMD, 4);
  spid[s] = p; sval[s] = v; sroute[s] = r;
endtask
task automatic t_begin(input logic [31:0] src, input logic [31:0] a, input logic [15:0] amax, input logic [31:0] b, input logic [15:0] bmax);
  t_src = src; t_a = a; t_b = b; t_amax = amax; t_bmax = bmax;
  n_pk = 0; exp_a.delete(); exp_b.delete(); a_room = amax; b_room = bmax;
  rd(A_DESC_CNT); e_desc = rdv[15:0]; e_nokey = rdv[31:16];
  rd(A_ERR_CNT); e_sync = rdv[15:0]; e_drop = rdv[31:16];
  rd(A_PKT_CNT); e_ovf = rdv[15:0];
endtask
task automatic t_run(input string what, input bit chk);
  wr(A_SRC_ADDR, t_src); wr(A_PKTS, n_pk);
  wr(A_OUTA_ADDR, t_a); wr(A_OUTA_MAX, t_amax); wr(A_OUTB_ADDR, t_b); wr(A_OUTB_MAX, t_bmax);
  wr(A_CTRL, {30'd0, 1'b1, tsp_keep});
  wr(A_CMD, 1);
  poll(A_STATUS, 32'h1, 32'h0, 20000);
  if (!chk) return;
  rd_exp(A_OUT_CNT, {16'(exp_b.size() / 188), 16'(exp_a.size() / 188)});
  foreach (exp_a[i]) begin
    logic [31:0] w;
    w = mem.peek(t_a + 32'(i & ~3));
    if (w[8 * (i % 4) +: 8] !== exp_a[i]) begin fail($sformatf("%s: A byte %0d = %h, expected %h", what, i, w[8 * (i % 4) +: 8], exp_a[i])); break; end
  end
  foreach (exp_b[i]) begin
    logic [31:0] w;
    w = mem.peek(t_b + 32'(i & ~3));
    if (w[8 * (i % 4) +: 8] !== exp_b[i]) begin fail($sformatf("%s: B byte %0d = %h, expected %h", what, i, w[8 * (i % 4) +: 8], exp_b[i])); break; end
  end
  rd_exp(A_DESC_CNT, {16'(e_nokey), 16'(e_desc)});
  rd_exp(A_ERR_CNT, {16'(e_drop), 16'(e_sync)});
  rd(A_PKT_CNT);
  if (rdv[15:0] !== 16'(e_ovf)) fail($sformatf("%s: OVF_CNT %0d, expected %0d", what, rdv[15:0], e_ovf));
  tv_irq_pin(IRQ_DONE, what);
endtask

task automatic ip_func;
  for (int i = 0; i < 4; i++) begin kev_ok[i] = 0; kod_ok[i] = 0; sval[i] = 0; spid[i] = 0; sroute[i] = 0; end
  if (aes_enc(128'h000102030405060708090a0b0c0d0e0f, 128'h00112233445566778899aabbccddeeff) !== 128'h69c4e0d86a7b0430d8cdb78070b4c55a)
    fail("TB AES model fails FIPS 197");
  wr(A_PCR_PID, 13'h100);
  // keys and slots; keys read back as 0
  t_key(0, 0, {$urandom, $urandom, $urandom, $urandom});
  t_key(0, 1, {$urandom, $urandom, $urandom, $urandom});
  t_key(1, 0, 128'hFFFF_FFFF_FFFF_FFFF_FFFF_FFFF_FFFF_FFFF);
  t_key(2, 1, 128'h0);
  t_key(3, 0, {$urandom, $urandom, $urandom, $urandom});
  rd_exp(A_KEY0, 0); rd_exp(A_KEY3, 0);
  t_slot(0, 13'h100, 1, 2'b01);
  t_slot(1, 13'h1555, 1, 2'b10);
  t_slot(2, 13'h0AAA, 1, 2'b11);
  t_slot(3, 13'h1FFE, 1, 2'b01);
  // a mixed job
  t_begin(32'h0000_0000, 32'h0001_0000, 64, 32'h0002_0000, 64);
  mk(13'h100, 2'b10, 2'b01, 0, 0, 0, 0, 8'h47); put(t_src);
  mk(13'h100, 2'b11, 2'b11, 7, 1, 33'h1_FFFF_FFFF, 9'h1FF, 8'h47); put(t_src);
  mk(13'h100, 2'b00, 2'b01, 0, 0, 0, 0, 8'h47); put(t_src);
  mk(13'h1555, 2'b10, 2'b11, 20, 0, 0, 0, 8'h47); put(t_src);
  mk(13'h1555, 2'b11, 2'b01, 0, 0, 0, 0, 8'h47); put(t_src);       // no odd key in slot 1
  mk(13'h0AAA, 2'b11, 2'b11, 0, 0, 0, 0, 8'h47); put(t_src);
  mk(13'h0AAA, 2'b11, 2'b10, 183, 0, 0, 0, 8'h47); put(t_src);
  mk(13'h1FFE, 2'b10, 2'b11, 168, 0, 0, 0, 8'h47); put(t_src);
  mk(13'h0001, 2'b00, 2'b01, 0, 0, 0, 0, 8'h47); put(t_src);       // unmatched
  mk(13'h100, 2'b10, 2'b01, 0, 0, 0, 0, 8'hB8); put(t_src);        // bad sync
  t_run("mixed", 1);
  rd_exp(A_PCR_BASE, 32'hFFFF_FFFF); rd_exp(A_PCR_EXT, 32'h3FF);
  rd(A_PCR_LOCAL);
  if (rdv == 0) fail("PCR_LOCAL 0");
  tv_irq_pin(IRQ_PCR, "PCR");
  tv_irq_pin(IRQ_NOKEY, "missing key");
  tv_irq(IRQ_SYNC, "bad sync");
  // a second PCR of zeros, keep_tsc, buffers full
  tsp_keep = 1;
  t_begin(32'h0000_0000, 32'h0001_0000, 2, 32'h0002_0000, 1);
  mk(13'h100, 2'b00, 2'b11, 7, 1, 33'h0, 9'h0, 8'h47); put(t_src);
  for (int i = 0; i < 4; i++) begin mk(13'h0AAA, 2'b11, 2'b11, 30 + i, 0, 0, 0, 8'h47); put(t_src); end
  t_run("keep_tsc, OVF", 1);
  rd_exp(A_PCR_BASE, 0); rd_exp(A_PCR_EXT, 0);
  tv_irq_pin(IRQ_OVF, "buffers full");
  wr(A_IRQ_STATUS, IRQ_ALL);
  tsp_keep = 0;
  // address / burst sweep: a packet read from 0x7FFF_FFFC (1 beat, then
  // 16, 16, 14 beats from 0x8000_0000), then one written there
  t_begin(32'h7FFF_FFFC, 32'h0001_0000, 4, 32'h0002_0000, 4);
  mk(13'h100, 2'b10, 2'b11, 7, 1, 33'h1_2345_6789, 9'h0A5, 8'h47); put(t_src);   // a third PCR
  t_run("read sweep", 1);
  wr(A_IRQ_STATUS, IRQ_ALL);
  t_begin(32'h0000_0000, 32'h7FFF_FFFC, 4, 32'h0002_0000, 4);
  mk(13'h1FFE, 2'b10, 2'b01, 0, 0, 0, 0, 8'h47); put(t_src);
  t_run("write sweep", 1);
  wr(A_IRQ_STATUS, IRQ_ALL);
  // AXI errors
  t_begin(32'h0000_0000, 32'h0001_0000, 4, 32'h0002_0000, 4);
  mk(13'h100, 2'b00, 2'b01, 0, 0, 0, 0, 8'h47); put(t_src);
  mem.err_lo = 32'h0000_0010; mem.err_hi = 32'h0000_0014;
  t_run("read error", 0);
  rd(A_STATUS);
  if (rdv[2] !== 1'b1) fail("no STATUS.err after a read error");
  tv_irq(IRQ_ERR, "read error");
  mem.err_lo = 32'h0001_0004; mem.err_hi = 32'h0001_0008;
  t_run("write error", 0);
  tv_irq(IRQ_ERR, "write error");
  mem.err_lo = '1; mem.err_hi = '1;
  // a job left running for the reset that follows, DONE of the last one pending
  t_run("low", 1);
  wr(A_PKTS, 1);
  wr(A_CMD, 1);
  rd_exp(A_FLAGS, 0);
  if (mem.errors != 0) fail("AXI rule violations");
endtask
