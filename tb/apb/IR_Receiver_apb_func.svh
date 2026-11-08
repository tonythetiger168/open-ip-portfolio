// SPDX-License-Identifier: Apache-2.0
// IR_Receiver-specific part of tb/IR_Receiver_apb_tb.sv. An soc_ss_axi_mem
// subordinate sits on the AXI4 manager pins m_*; the TB drives ir_in
// (active low). Covered through the registers: NEC codes and an NEC repeat,
// an RC-5 code, LAST and the ring words, WR_IDX / RD_IDX, COUNTS, a NEC
// frame with a bad inverted command (RX_ERR), the ring full (codes wait, then
// arrive after RD_IDX moves), ERR on an AXI write error.
`include "apb/tv_apb_common.svh"

initial ir_in = 1'b1;
localparam int IR_TPC = 2;                            // TICK_DIV 1
task automatic ir_hold(input bit m, input int t);
  ir_in = !m;
  repeat (t * IR_TPC) @(negedge PCLK);
endtask
task automatic ir_nec(input logic [7:0] a, input logic [7:0] c, input bit bad);
  logic [31:0] d;
  d = {bad ? c : ~c, c, ~a, a};
  ir_hold(1, 256); ir_hold(0, 128);
  for (int i = 0; i < 32; i++) begin ir_hold(1, 16); ir_hold(0, d[i] ? 48 : 16); end
  ir_hold(1, 16); ir_hold(0, 500);
endtask
task automatic ir_nec_rep;
  ir_hold(1, 256); ir_hold(0, 64); ir_hold(1, 16); ir_hold(0, 500);
endtask
task automatic ir_rc5(input bit t, input logic [4:0] a, input logic [5:0] c);
  logic [13:0] b;
  b = {1'b1, 1'b1, t, a, c};
  for (int k = 0; k < 14; k++) begin
    if (k != 0) ir_hold(!b[13-k], 25);
    ir_hold(b[13-k], 25);
  end
  ir_hold(0, 1000);
endtask
function automatic logic [31:0] nec_w(input logic [7:0] a, input logic [7:0] c, input bit rep);
  return {2'd0, rep, 1'b0, 4'b0, ~a, a, c};
endfunction

task automatic ip_func;
  logic [31:0] rb;
  rb = 32'h8000_0FF8;                                 // the ring crosses a 4 KB boundary
  wr(A_TICK_DIV, IR_TPC - 1); wr(A_RING_BASE, rb); wr(A_RING_WORDS, 4); wr(A_RD_IDX, 0);
  wr(A_CTRL, 1);                                      // NEC
  ir_hold(0, 200);
  ir_nec(8'h12, 8'h34, 0);
  rd_exp(A_LAST, nec_w(8'h12, 8'h34, 0));
  rd_exp(A_WR_IDX, 1);
  if (mem.peek(rb) !== nec_w(8'h12, 8'h34, 0)) fail($sformatf("ring word 0 = %h", mem.peek(rb)));
  tv_irq(IRQ_CODE, "NEC code");
  ir_nec_rep();
  rd_exp(A_LAST, nec_w(8'h12, 8'h34, 1));
  if (mem.peek(rb + 4) !== nec_w(8'h12, 8'h34, 1)) fail("NEC repeat word");
  // bad inverted command
  ir_nec(8'h55, 8'h66, 1);
  tv_irq(IRQ_RX_ERR, "bad NEC frame");
  rd_exp(A_COUNTS, {16'd1, 16'd2});
  // RC-5: toggle 1, address 7, command 0x15 (S2 = 1: field bit 0)
  wr(A_CTRL, 3);
  ir_hold(0, 200);
  ir_rc5(1, 5'd7, 6'h15);
  rd_exp(A_LAST, {2'd1, 1'b0, 1'b1, 4'b0, 8'h00, 3'b0, 5'd7, 1'b0, 1'b0, 6'h15});
  if (mem.peek(rb + 8) !== {2'd1, 1'b0, 1'b1, 4'b0, 8'h00, 3'b0, 5'd7, 1'b0, 1'b0, 6'h15}) fail("RC-5 ring word");
  rd_exp(A_WR_IDX, 3);
  // the ring is full at WR_IDX 3 with RD_IDX 0: the next code waits
  ir_rc5(0, 5'd9, 6'h01);
  rd_exp(A_WR_IDX, 3);
  wr(A_RD_IDX, 3);
  cycles(50);
  rd_exp(A_WR_IDX, 0);
  if (mem.peek(rb + 12) !== {2'd1, 1'b0, 1'b0, 4'b0, 8'h00, 3'b0, 5'd9, 1'b0, 1'b0, 6'h01}) fail("waiting code not written");
  rd_exp(A_OVF_CNT, 0);
  wr(A_IRQ_STATUS, IRQ_ALL);
  // AXI write error
  mem.err_lo = rb; mem.err_hi = rb + 4;
  ir_rc5(1, 5'd1, 6'h02);
  rd(A_STATUS);
  if (rdv[0] !== 1'b1) fail("no STATUS.err after an AXI error");
  tv_irq(IRQ_ERR, "AXI error");
  mem.err_lo = '1; mem.err_hi = '1;
  if (mem.errors != 0) fail("AXI rule violations");
endtask
