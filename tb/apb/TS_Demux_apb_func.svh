// SPDX-License-Identifier: Apache-2.0
// TS_Demux-specific part of tb/TS_Demux_apb_tb.sv. An soc_ss_axi_mem
// subordinate sits on the AXI4 manager pins m_*; the TB drives the transport
// stream pins. Covered through the registers: PID filtering (a filtered and
// an unfiltered PID), the 48-word ring slot of each packet (bytes and
// descriptor), WR_IDX / RD_IDX ring wrap, PKTS, a bad sync byte (DROP), a
// continuity error (CC_ERR), a full ring (OVF), ENABLE off, ERR on an AXI
// write error, irq masking.
`include "apb/tv_apb_common.svh"

initial begin ts_valid = 0; ts_sync = 0; ts_data = 0; ts_err = 0; end
logic [7:0] ts_b [188];
task automatic ts_send(input logic [12:0] pid, input logic [3:0] cc, input bit bad_sync);
  ts_b[0] = bad_sync ? 8'h46 : 8'h47;
  ts_b[1] = {3'b010, pid[12:8]};                      // PUSI
  ts_b[2] = pid[7:0];
  ts_b[3] = {4'b0001, cc};                            // payload only
  for (int i = 4; i < 188; i++) ts_b[i] = $urandom;
  for (int i = 0; i < 188; i++) begin
    @(negedge PCLK); ts_valid = 1; ts_sync = (i == 0); ts_data = ts_b[i];
  end
  @(negedge PCLK); ts_valid = 0; ts_sync = 0;
  repeat (300) @(negedge PCLK);                     // the slot is written
endtask
// slot s at RING_BASE b holds the last packet sent (filter f, cc error e)
task automatic ts_check(input logic [31:0] b, input int s, input int f, input bit e, input string what);
  logic [31:0] a;
  a = b + 32'(192 * s);
  for (int i = 0; i < 47; i++)
    if (mem.peek(a + 32'(4 * i)) !== {ts_b[4*i+3], ts_b[4*i+2], ts_b[4*i+1], ts_b[4*i]}) begin
      fail($sformatf("%s: slot %0d word %0d", what, s, i)); break;
    end
  if (mem.peek(a + 188) !== {e, 1'b0, 1'b1, 2'(f), 7'b0, ts_b[3][3:0], 3'b0, ts_b[1][4:0], ts_b[2]})
    fail($sformatf("%s: descriptor %h", what, mem.peek(a + 188)));
endtask

task automatic ip_func;
  logic [31:0] rb;
  rb = 32'h8000_0F00;                                 // slots cross a 4 KB boundary
  wr(A_RING_BASE, rb); wr(A_RING_PKTS, 3); wr(A_RD_IDX, 0);
  wr(A_PID01, {6'd0, 13'h0101, 13'h0100}); wr(A_PID23, {6'd0, 13'h1FFE, 13'h0200});
  wr(A_CTRL, 32'h1 | (32'b0110 << 1));                // filters 1 and 2
  // filter 1 hit, then a PID nobody wants
  ts_send(13'h0101, 0, 0);
  ts_check(rb, 0, 1, 0, "filter 1");
  rd_exp(A_WR_IDX, 1);
  tv_irq(IRQ_PKT, "packet");
  ts_send(13'h0100, 0, 0);                            // filter 0 is off
  rd_exp(A_WR_IDX, 1);
  tv_no_irq(IRQ_PKT, "unfiltered PID");
  // filter 2, then a continuity jump on filter 1 (cc 0 -> 5)
  ts_send(13'h0200, 7, 0);
  ts_check(rb, 1, 2, 0, "filter 2");
  wr(A_RD_IDX, 2);
  ts_send(13'h0101, 5, 0);
  ts_check(rb, 2, 1, 1, "cc error");
  tv_irq(IRQ_CC_ERR, "continuity error");
  rd_exp(A_WR_IDX, 0);                                // wrapped
  // bad sync byte: dropped
  ts_send(13'h0101, 6, 1);
  ts_send(13'h0101, 6, 0);                            // the next sync ends the bad one
  tv_irq(IRQ_DROP, "bad sync");
  // ring full: RD_IDX 1, WR_IDX 1 -> one slot free never used (q_next == rd)
  rd_exp(A_WR_IDX, 1);
  ts_send(13'h0101, 7, 0);
  rd(A_ERRS);
  if (rdv[31:16] != 1) fail($sformatf("OVF_CNT %0d with the ring full", rdv[31:16]));
  rd(A_PKTS);
  if (rdv[15:0] != 4 || rdv[31:16] != 1) fail($sformatf("PKTS %h", rdv));
  rd(A_ERRS);
  if (rdv[15:0] != 1) fail($sformatf("CC_ERR_CNT %0d", rdv[15:0]));
  // AXI write error
  wr(A_RD_IDX, 1);
  mem.err_lo = rb + 192 + 16; mem.err_hi = mem.err_lo + 4;
  ts_send(13'h0101, 8, 0);
  rd(A_STATUS);
  if (rdv[1] !== 1'b1) fail("no STATUS.err after an AXI error");
  tv_irq(IRQ_ERR, "AXI error");
  mem.err_lo = '1; mem.err_hi = '1;
  // enable off: nothing written, WR_IDX cleared
  wr(A_CTRL, 0);
  rd_exp(A_WR_IDX, 0);
  ts_send(13'h0101, 9, 0);
  tv_no_irq(IRQ_PKT, "ENABLE 0");
  if (mem.errors != 0) fail("AXI rule violations");
endtask
