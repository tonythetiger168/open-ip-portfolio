// SPDX-License-Identifier: Apache-2.0
// TCON_VbyOne-specific part of tb/TCON_VbyOne_apb_tb.sv. An soc_ss_axi_mem
// subordinate sits on the AXI4 manager pins m_*; a panel model on the 8
// lanes collects the pixels of each line. Covered through the registers:
// training until lock (STATUS.locked), frames at three placements compared
// pixel by pixel (padding of a partial lane group), LINES, CYCLES, DONE,
// lock loss during a frame (LOCK_LOST, LOCK interrupt, the frame ends
// once lock returns), ERR on an AXI read error.
// Coverage closure: STATUS.locked low while vbo_htpdn_n is high (no panel), an
// address / burst sweep with a line at 0x7FFF_FFFC and a 2-pixel line, an
// interrupt left pending for the reset that follows, FLAGS read.
`include "apb/tv_apb_common.svh"

initial begin vbo_htpdn_n = 1'b1; vbo_lockn_n = 1'b1; end    // no panel yet
int          p_line = -1, p_byte = 0, p_lines = 0, p_bad = 0, p_train = 0;
logic [31:0] p_cur [8];
logic [31:0] p_q [$];
logic [31:0] p_fb;
int          p_h, p_stride;
bit          p_on = 1;                              // compare the lines with memory
task automatic p_end_line;
  if (p_line >= 0 && p_on) begin
    if (p_q.size() != ((p_h + 7) / 8) * 8) fail($sformatf("line %0d: %0d words", p_line, p_q.size()));
    for (int i = 0; i < p_q.size(); i++) begin
      logic [31:0] e;
      e = (i < p_h) ? mem.peek(p_fb + 32'(p_line * p_stride + 4 * i)) : 32'h0;
      if (p_q[i] !== e && p_bad++ < 5) fail($sformatf("line %0d pixel %0d: %h, expected %h", p_line, i, p_q[i], e));
    end
    p_lines++;
  end
  p_q.delete();
endtask
always @(posedge PCLK) if (PRESETN && vbo_sym) begin
  if (vbo_lane_k == 8'h00 && vbo_lane_d == {8{8'h4A}}) p_train++;
  else if (vbo_lane_k == 8'hFF && vbo_lane_d[7:0] == 8'hBC) ;
  else if (vbo_lane_k == 8'hFF) begin
    p_end_line();
    p_line = (vbo_lane_d[7:0] == 8'h5C) ? 0 : p_line + 1;
    p_byte = 0;
  end else begin
    for (int l = 0; l < 8; l++) p_cur[l][8*p_byte +: 8] = vbo_lane_d[8*l +: 8];
    if (p_byte == 3) for (int l = 0; l < 8; l++) p_q.push_back(p_cur[l]);
    p_byte = (p_byte + 1) % 4;
  end
end
function automatic logic [31:0] place(input int k);
  return (k == 0) ? 32'h0000_0040 : (k == 1) ? 32'h7FFF_F000 : 32'h8000_0FC0;
endfunction
task automatic t_frame(input logic [31:0] fb, input int h, input int v);
  p_fb = fb; p_h = h; p_stride = 4 * h + 8;
  for (int i = 0; i < v * p_stride / 4; i++) mem.poke(fb + 32'(4 * i), $urandom);
  wr(A_FB_ADDR, fb); wr(A_GEOM, {16'(h), 16'(p_stride)});
  wr(A_TIMING, {4'd0, 4'd4, 8'd6, 16'(v)});           // SYM_DIV 4, HBLANK 6
  p_lines = 0;
  tv_job(A_CMD, 0, A_STATUS, 0, 2000);
  cycles(40);
  p_end_line(); p_line = -1;
endtask

task automatic ip_func;
  // training while the panel is not locked
  cycles(60);
  if (p_train == 0) fail("no training symbols before lock");
  rd(A_STATUS);
  if (rdv[4] !== 1'b0) fail("STATUS.locked before lock");
  vbo_lockn_n = 1'b0; cycles(4);                      // CDR locked, but no panel
  rd(A_STATUS);
  if (rdv[4] !== 1'b0) fail("STATUS.locked with vbo_htpdn_n high");
  vbo_htpdn_n = 1'b0; cycles(4);
  rd(A_STATUS);
  if (rdv[4] !== 1'b1) fail("STATUS.locked does not follow vbo_lockn_n");
  for (int k = 0; k < 3; k++) begin
    t_frame(place(k), (k == 1) ? 13 : 24, 3);         // 13: a partial lane group
    if (p_lines != 3) fail($sformatf("placement %0d: panel saw %0d lines", k, p_lines));
    rd_exp(A_LINES, 3);
    rd(A_STATUS);
    if (rdv[3:1] !== 3'b000) fail($sformatf("placement %0d: STATUS err / underrun / lock_lost %b", k, rdv[3:1]));
    rd(A_CYCLES);
    if (rdv == 0) fail("CYCLES 0");
    tv_irq(IRQ_DONE, "frame");
  end
  // lock lost in the middle of a frame
  p_fb = 32'h0001_0000; p_h = 64; p_stride = 264;
  wr(A_FB_ADDR, p_fb); wr(A_GEOM, {16'd64, 16'd264}); wr(A_TIMING, {4'd0, 4'd2, 8'd6, 16'd8});
  wr(A_CMD, 1);
  cycles(200);
  vbo_lockn_n = 1'b1;
  cycles(50);
  rd(A_STATUS);
  if (rdv[3] !== 1'b1 || rdv[0] !== 1'b1) fail($sformatf("lock lost: STATUS %h (lock_lost, still busy expected)", rdv));
  tv_irq(IRQ_LOCK, "lock lost");
  vbo_lockn_n = 1'b0;                                 // the frame goes on once lock returns
  poll(A_STATUS, 32'h1, 32'h0, 2000);
  rd_exp(A_LINES, 8);
  wr(A_IRQ_STATUS, IRQ_ALL);
  p_line = -1; p_q.delete();
  // AXI read error
  mem.err_lo = 32'h0002_0010; mem.err_hi = mem.err_lo + 4;
  p_on = 0;                                           // the lanes carry DEADBEEF
  t_frame(32'h0002_0000, 16, 1);
  p_on = 1;
  rd(A_STATUS);
  if (rdv[1] !== 1'b1) fail("no STATUS.err after an AXI error");
  tv_irq(IRQ_ERR, "AXI error");
  mem.err_lo = '1; mem.err_hi = '1;
  // address / burst sweep: a 17-pixel line at 0x7FFF_FFFC is read as one
  // beat (ARLEN 0), then 16 beats (ARLEN 15) from 0x8000_0000 after the
  // 4 KB split, so every ARADDR bit 2..31 and ARLEN bit 0..3 rises and
  // falls; a 2-pixel line at 0x0000_0008 follows. Its DONE is left pending
  // for the reset that follows.
  t_frame(32'h7FFF_FFFC, 17, 1);
  if (p_lines != 1) fail($sformatf("sweep: panel saw %0d lines", p_lines));
  tv_irq(IRQ_DONE, "sweep frame");
  t_frame(32'h0000_0008, 2, 1);
  if (p_lines != 1) fail($sformatf("2-pixel line: panel saw %0d lines", p_lines));
  rd(A_STATUS);
  if (rdv[3:1] !== 3'b000) fail($sformatf("2-pixel line: STATUS err / underrun / lock_lost %b", rdv[3:1]));
  tv_irq_pin(IRQ_DONE, "2-pixel line");               // left pending for the reset
  rd_exp(A_FLAGS, 0);
  if (mem.errors != 0) fail("AXI rule violations");
endtask
