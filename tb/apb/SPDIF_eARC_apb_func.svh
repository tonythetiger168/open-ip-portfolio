// SPDX-License-Identifier: Apache-2.0
// SPDIF_eARC-specific part of tb/SPDIF_eARC_apb_tb.sv. An soc_ss_axi_mem
// subordinate sits on the AXI4 manager pins m_*; the TB drives spdif_in with
// biphase-mark IEC 60958 frames (UI_CLKS 8). Covered through the registers:
// a continuous stream: lock (STATUS.locked), sample words in the ring (preamble flags, V / U / C,
// parity), CHUNK interrupts, SAMPLES, CS0 and the CS interrupt after a full
// block, a parity error (ERRS), lock loss on an idle line (LOCK_LOST), ERR
// on an AXI write error.
// Coverage closure: random V / U bits, a ring at 0x7FFF_FFFC, a second block
// with other channel status bits, samples dropped with the ring full
// (OVF_CNT), an interrupt left pending for the reset that follows, FLAGS read.
`include "apb/tv_apb_common.svh"

initial spdif_in = 1'b0;
localparam int SP_UI = 8;
bit sp_lvl = 0;
logic [31:0] sp_q [$];                                // words sent, in order
task automatic sp_ui(input bit l);
  spdif_in = l;
  repeat (SP_UI) @(negedge PCLK);
endtask
// p: preamble 0 B, 1 M, 2 W
task automatic sp_sub(input int p, input logic [23:0] smp, input bit c, input bit bad_par);
  logic [7:0] pat;
  logic [27:0] b;
  bit v, u;
  pat = (p == 0) ? 8'b11101000 : (p == 1) ? 8'b11100010 : 8'b11100100;
  if (sp_lvl) pat = ~pat;
  for (int i = 7; i >= 0; i--) sp_ui(pat[i]);
  sp_lvl = pat[0];
  v = $urandom; u = $urandom;                        // validity / user bits
  b = {1'b0, c, u, v, smp};
  b[27] = ^b[26:0] ^ bad_par;
  for (int i = 0; i < 28; i++) begin
    sp_lvl = !sp_lvl; sp_ui(sp_lvl);
    if (b[i]) sp_lvl = !sp_lvl;
    sp_ui(sp_lvl);
  end
  sp_q.push_back({p == 2, p == 0, v, u, c, bad_par, 2'b00, smp});
endtask
// background source: while sp_run, frames back to back (frame counter sp_f
// in the 192-frame block, channel A carries cs bit f, parity error at
// sp_perr); the line idles when sp_run is 0
bit          sp_run = 0;
int          sp_f = 190, sp_perr = -1, sp_nf = 0;
logic [31:0] sp_cs = 32'h8204_0A05;
initial forever begin
  if (!sp_run) @(negedge PCLK);
  else begin
    sp_sub(sp_f == 0 ? 0 : 1, $urandom, sp_f < 32 ? sp_cs[sp_f] : 1'b0, sp_nf == sp_perr);
    sp_sub(2, $urandom, 1'b0, 0);
    sp_f = (sp_f + 1) % 192; sp_nf++;
  end
end
task automatic sp_wait(input int n);                  // n more frames
  int t;
  t = sp_nf + n;
  while (sp_nf < t) @(negedge PCLK);
endtask

task automatic ip_func;
  logic [31:0] rb;
  int n, off;
  rb = 32'h7FFF_FFFC;                                 // chunks cross 4 KB and every address bit
  wr(A_RING_BASE, rb); wr(A_RING_WORDS, 64); wr(A_RD_IDX, 0);
  wr(A_CTRL, 32'h1 | (32'(SP_UI) << 1));
  sp_q.delete();
  sp_perr = 40;
  sp_run = 1;
  sp_wait(4);
  rd(A_STATUS);
  if (rdv[0] !== 1'b1) fail("STATUS.locked after 4 frames");
  sp_wait(20);
  rd(A_WR_IDX);
  n = int'(rdv[15:0]);
  if (n == 0 || n % 16 != 0) fail($sformatf("WR_IDX %0d not a whole number of chunks", n));
  tv_irq(IRQ_CHUNK, "chunk");
  // the ring holds the subframes in order from one of the lock-up subframes
  off = -1;
  for (int k = 0; k < 8 && off < 0; k++) if (mem.peek(rb) === sp_q[k]) off = k;
  if (off < 0) fail($sformatf("ring word 0 = %h is none of the first subframes", mem.peek(rb)));
  else for (int i = 0; i < n; i++)
    if (mem.peek(rb + 32'(4 * i)) !== sp_q[off + i]) begin fail($sformatf("ring word %0d", i)); break; end
  // software keeps up with the ring until the next block start: CS0 and CS
  while (sp_nf < 200) begin
    rd(A_WR_IDX); wr(A_RD_IDX, rdv);
  end
  rd_exp(A_CS0, sp_cs);
  tv_irq_pin(IRQ_CS, "channel status change");
  rd(A_ERRS);
  if (rdv[15:0] != 1) fail($sformatf("PERR_CNT %0d", rdv[15:0]));
  rd(A_SAMPLES);
  if (rdv < 300) fail($sformatf("SAMPLES %0d", rdv));
  rd_exp(A_OVF_CNT, 0);
  wr(A_IRQ_STATUS, IRQ_ALL);
  // AXI write error on the next chunk
  rd(A_WR_IDX);
  mem.err_lo = rb + 4 * ((rdv + 2) % 64); mem.err_hi = mem.err_lo + 4;
  wr(A_RD_IDX, rdv);
  sp_wait(12);
  rd(A_STATUS);
  if (rdv[1] !== 1'b1) fail("no STATUS.err after an AXI error");
  mem.err_lo = '1; mem.err_hi = '1;
  // a new block starts early with other channel status bits; the ring
  // moves to 0x0000_0040 and is not consumed: CS0 changes, and once the
  // ring and the 64-word FIFO are full samples are dropped (OVF_CNT)
  sp_cs = ~sp_cs; sp_f = 191;                         // B within the next two frames
  wr(A_RING_BASE, 32'h0000_0040);
  sp_wait(80);
  rd_exp(A_CS0, sp_cs);
  rd(A_OVF_CNT);
  if (rdv == 0) fail("no OVF_CNT with the ring full");
  // idle line: lock lost
  sp_run = 0;
  cycles(128 * SP_UI + 16 * SP_UI);                   // the frame in flight, then idle
  rd(A_STATUS);
  if (rdv[0] !== 1'b0) fail("still locked on an idle line");
  tv_irq_pin(IRQ_LOCK_LOST, "idle line");
  wr(A_IRQ_STATUS, 32'(1) << IRQ_LOCK_LOST);
  tv_irq_pin(IRQ_ERR, "AXI error");
  wr(A_IRQ_STATUS, 32'(1) << IRQ_ERR);                // the job's other interrupt stays
  rd(A_IRQ_STATUS);                                   // pending for the reset that follows
  if (rdv == 0) fail("no interrupt left pending");
  rd_exp(A_FLAGS, 0);
  if (mem.errors != 0) fail("AXI rule violations");
endtask
