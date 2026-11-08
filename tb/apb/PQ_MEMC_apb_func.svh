// SPDX-License-Identifier: Apache-2.0
// PQ_MEMC-specific part of tb/PQ_MEMC_apb_tb.sv. An soc_ss_axi_mem subordinate
// sits on the AXI4 manager pins m_*. Covered through the registers: neutral
// tone curve without MEMC (output = input) at three placements, MEMC with
// MV_FRAC 0 (output = previous frame), metadata load (STATUS.params_ok, TONE),
// LINES, CYCLES, DONE, CFG_ERR on H_ACTIVE 0, ERR on an AXI read error.
// Coverage closure: an AXI write error, two more metadata loads (TONE), an
// address / burst sweep with a MEMC line at 0x7FFF_FFFC and a 1-pixel frame,
// an interrupt left pending for the reset that follows, FLAGS read.
`include "apb/tv_apb_common.svh"

function automatic logic [31:0] place(input int k);
  return (k == 0) ? 32'h0000_0040 : (k == 1) ? 32'h7FFF_F000 : 32'h8000_0FC0;
endfunction
// frame of h x v at base b (cur), b ^ 0x2000_0000 (prev), b ^ 0x4000_0000 (dst)
task automatic pq_frame(input logic [31:0] b, input int h, input int v, input logic [31:0] ctrl);
  for (int i = 0; i < h * v; i++) begin
    mem.poke(b + 32'(4 * i), {2'b00, 30'($urandom)});
    mem.poke((b ^ 32'h2000_0000) + 32'(4 * i), {2'b00, 30'($urandom)});
    mem.poke((b ^ 32'h4000_0000) + 32'(4 * i), 32'hBAD0_0000);
  end
  wr(A_CUR_ADDR, b); wr(A_PREV_ADDR, b ^ 32'h2000_0000); wr(A_DST_ADDR, b ^ 32'h4000_0000);
  wr(A_GEOM, {16'(h), 16'(4 * h)}); wr(A_V_ACTIVE, 32'(v)); wr(A_CTRL, ctrl);
  tv_job(A_CMD, 1, A_STATUS, 0, 400);
endtask

task automatic ip_func;
  // tone off, MEMC off: identity
  for (int k = 0; k < 3; k++) begin
    pq_frame(place(k), 16, 3, 0);
    for (int i = 0; i < 48; i++)
      if (mem.peek((place(k) ^ 32'h4000_0000) + 32'(4 * i)) !== mem.peek(place(k) + 32'(4 * i))) begin
        fail($sformatf("identity placement %0d word %0d", k, i)); break;
      end
    rd_exp(A_LINES, 3);
    rd(A_CYCLES);
    if (rdv == 0) fail("CYCLES 0");
    tv_irq(IRQ_DONE, "identity frame");
  end
  // MEMC with MV_FRAC 0: the previous frame
  pq_frame(32'h0001_0000, 20, 2, 32'h1);
  for (int i = 0; i < 40; i++)
    if (mem.peek(32'h4001_0000 + 32'(4 * i)) !== mem.peek(32'h2001_0000 + 32'(4 * i))) begin
      fail($sformatf("MEMC a=0 word %0d", i)); break;
    end
  wr(A_IRQ_STATUS, IRQ_ALL);
  // HDR10 metadata: 1000-nit content on a 300-nit panel
  rd(A_STATUS);
  if (rdv[3] !== 1'b0) fail("STATUS.params_ok before META_LOAD");
  wr(A_META0, {16'd1000, 16'd1}); wr(A_META1, {16'd4000, 16'd5}); wr(A_META2, {16'd16384, 16'd0}); wr(A_META3, 0);
  wr(A_DISPLAY_PEAK, 300);
  wr(A_CMD, 1);
  poll(A_STATUS, 32'h8, 32'h8, 10);
  rd_exp(A_TONE, {16'd1000, 16'd19660});
  // tone mapping on: a full-scale pixel is compressed, black stays black
  mem.poke(32'h0002_0000, 32'h3FFF_FFFF); mem.poke(32'h0002_0004, 0);
  wr(A_CUR_ADDR, 32'h0002_0000); wr(A_DST_ADDR, 32'h4002_0000);
  wr(A_GEOM, {16'd2, 16'd8}); wr(A_V_ACTIVE, 1); wr(A_CTRL, 32'h200);
  tv_job(A_CMD, 1, A_STATUS, 0, 100);
  if (mem.peek(32'h4002_0000) === 32'h3FFF_FFFF || mem.peek(32'h4002_0000) == 0) fail("full scale not tone mapped");
  if (mem.peek(32'h4002_0004) !== 0) fail("black changed by the tone curve");
  wr(A_IRQ_STATUS, IRQ_ALL);
  // CFG_ERR: H_ACTIVE 0
  wr(A_GEOM, {16'd0, 16'd8});
  tv_job(A_CMD, 1, A_STATUS, 0, 10);
  rd(A_STATUS);
  if (rdv[2] !== 1'b1) fail("no STATUS.cfg_err for H_ACTIVE 0");
  tv_irq(IRQ_DONE, "CFG_ERR");
  // AXI read error
  mem.err_lo = 32'h0001_0010; mem.err_hi = mem.err_lo + 4;
  pq_frame(32'h0001_0000, 8, 1, 0);
  rd(A_STATUS);
  if (rdv[1] !== 1'b1) fail("no STATUS.err after an AXI error");
  tv_irq(IRQ_ERR, "AXI read error");
  // AXI write error on the output
  mem.err_lo = 32'h4001_0008; mem.err_hi = mem.err_lo + 4;
  pq_frame(32'h0001_0000, 8, 1, 0);
  rd(A_STATUS);
  if (rdv[1] !== 1'b1) fail("no STATUS.err after an AXI write error");
  tv_irq(IRQ_ERR, "AXI write error");
  mem.err_lo = '1; mem.err_hi = '1;
  // two more metadata loads: 700-nit panel / 1000-nit content (slope
  // 0xB333), then 300 nits / 64535 nits
  wr(A_META0, {16'd1000, 16'd1}); wr(A_DISPLAY_PEAK, 700);
  wr(A_CMD, 1);
  poll(A_STATUS, 32'h8, 32'h8, 10);
  rd_exp(A_TONE, {16'd1000, 16'hB333});
  wr(A_META0, {16'hFC17, 16'd1}); wr(A_DISPLAY_PEAK, 300);
  wr(A_CMD, 1);
  poll(A_STATUS, 32'h8, 32'h8, 10);
  rd_exp(A_TONE, {16'hFC17, 16'((300 * 65536) / 64535)});
  // address / burst sweep: a 17-pixel MEMC line at 0x7FFF_FFFC (previous
  // frame at 0x5FFF_FFFC, output at 0x3FFF_FFFC) is one beat, then 16
  // beats after the 4 KB split, so every AxADDR bit 2..30 and AxLEN bit
  // 0..3 rises and falls; a 1-pixel line at 0x0000_0004 follows. Its DONE
  // is left pending for the reset that follows.
  pq_frame(32'h7FFF_FFFC, 17, 1, 32'h1);
  for (int i = 0; i < 17; i++)
    if (mem.peek(32'h3FFF_FFFC + 32'(4 * i)) !== mem.peek(32'h5FFF_FFFC + 32'(4 * i))) begin
      fail($sformatf("sweep word %0d", i)); break;
    end
  tv_irq(IRQ_DONE, "sweep frame");
  pq_frame(32'h0000_0004, 1, 1, 0);
  if (mem.peek(32'h4000_0004) !== mem.peek(32'h0000_0004)) fail("1-pixel frame");
  tv_irq_pin(IRQ_DONE, "1-pixel frame");              // left pending for the reset
  rd_exp(A_FLAGS, 0);
  if (mem.errors != 0) fail("AXI rule violations");
endtask
