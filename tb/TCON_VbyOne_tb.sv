// SPDX-License-Identifier: Apache-2.0
// Self-checking core testbench of TCON_VbyOne_top (TV SoC, AXI4 manager).
// A panel model samples the 8 lanes at every symbol (vbo_sym), decodes the
// K28.2 / K28.0 line markers and the 4-byte pixel symbols, rebuilds every
// line and compares it with the frame buffer in the AXI4 memory model
// (padding words of a partial last group must be zero). Covers: training
// symbols while unplugged / unlocked, idle symbols, H_ACTIVE multiple of 8
// and not, strides with gaps, SYM_DIV 1..8, random and zero memory stalls
// (UNDERRUN must stay 0 when the memory keeps up), lock lost in a frame,
// AXI read errors, START while busy, V_ACTIVE / H_ACTIVE 0, reset.
`timescale 1ns/1ps
`include "soc_ss_axi_mem.svh"
module TCON_VbyOne_tb;
  `include "soc_ss_tb_common.svh"
  `include "tv_lat_mon.svh"
  localparam int LANES = 8;
  wire  [LANES-1:0][7:0] vbo_lane_d;
  wire  [LANES-1:0]      vbo_lane_k;
  wire                   vbo_sym;
  logic        vbo_htpdn_n = 1, vbo_lockn_n = 1;
  logic [31:0] fb_addr = 0;
  logic [15:0] stride = 0, h_active = 0, v_active = 0;
  logic [7:0]  hblank = 4;
  logic [3:0]  sym_div = 4;
  logic        start = 0;
  wire         busy, err, underrun, lock_lost, locked, done, err_irq, lock_irq;
  wire  [15:0] lines;
  wire  [31:0] cycles;
  TCON_VbyOne_top #(.LANES(LANES), .FIFO_DEPTH(64)) dut (.*);

  int n_done = 0, n_err_irq = 0, n_lock_irq = 0;
  always @(posedge clk) if (rst_n) begin n_done += done; n_err_irq += err_irq; n_lock_irq += lock_irq; end

  // ---------------- panel model ----------------
  int          rx_line = -1, rx_byte = 0, rx_lines = 0, n_train = 0, n_idle = 0, nbad = 0;
  logic [31:0] cur [LANES];
  logic [31:0] rx_q [$];                            // words of the line being received
  bit          check_on = 0;
  task automatic end_line;
    if (rx_line >= 0 && check_on) begin
      int n;
      n = ((h_active + LANES - 1) / LANES) * LANES;
      if (rx_q.size() != n) fail($sformatf("line %0d: %0d words, expected %0d", rx_line, rx_q.size(), n));
      for (int i = 0; i < rx_q.size() && i < n; i++) begin
        logic [31:0] e;
        e = (i < h_active) ? mem.peek(fb_addr + 32'(rx_line) * 32'(stride) + 32'(4 * i)) : 32'h0;
        if (rx_q[i] !== e && nbad++ < 8) fail($sformatf("line %0d pixel %0d: %h, expected %h", rx_line, i, rx_q[i], e));
      end
      rx_lines++;
    end
    rx_q.delete();
  endtask
  always @(posedge clk) if (rst_n && vbo_sym) begin
    if (vbo_lane_k == '0 && vbo_lane_d == {LANES{8'h4A}} && rx_line < 0) n_train++;   // outside a frame only
    else if (vbo_lane_k == '1 && vbo_lane_d[0] == 8'hBC) n_idle++;
    else if (vbo_lane_k == '1) begin
      end_line();
      if (vbo_lane_d[0] == 8'h5C) rx_line = 0;
      else if (vbo_lane_d[0] == 8'h1C) begin
        if (rx_line < 0 && check_on) fail("K28.0 line marker without a K28.2 frame start");
        rx_line++;
      end
      else fail($sformatf("unknown control symbol %h", vbo_lane_d[0]));
      for (int l = 1; l < LANES; l++) if (vbo_lane_d[l] !== vbo_lane_d[0]) fail("lanes disagree on a control symbol");
      rx_byte = 0;
    end else if (vbo_lane_k == '0) begin
      for (int l = 0; l < LANES; l++) cur[l][8*rx_byte +: 8] = vbo_lane_d[l];
      if (rx_byte == 3) for (int l = 0; l < LANES; l++) rx_q.push_back(cur[l]);
      rx_byte = (rx_byte + 1) % 4;
    end else fail("mixed k bits");
  end

  task automatic wait_idle(input string what);
    int t;
    t = 0;
    while (busy && t < 400000) begin @(negedge clk); t++; end
    if (busy) fail({what, ": frame did not finish"});
    clks(4 * 16);
    end_line();
    rx_line = -1;
  endtask

  task automatic frame(input int h, input int v, input bit exp_underrun_free, input string what);
    int nd0;
    fb_addr = 32'h0030_0000 + 32'(($urandom % 64) * 4);
    stride  = 16'(4 * h + 4 * ($urandom % 4));
    h_active = 16'(h); v_active = 16'(v);
    for (int k = 0; k < v; k++) fill_rand(fb_addr + 32'(k) * 32'(stride), h);
    nd0 = n_done; rx_lines = 0; check_on = 1;
    @(negedge clk); start = 1; @(negedge clk); start = 0;
    wait_idle(what);
    if (n_done != nd0 + 1) fail($sformatf("%s: %0d DONE pulses", what, n_done - nd0));
    if (lines !== 16'(h == 0 ? 0 : v)) fail($sformatf("%s: LINES %0d", what, lines));
    if (rx_lines != (h == 0 ? 0 : v)) fail($sformatf("%s: panel saw %0d lines, expected %0d", what, rx_lines, v));
    if (err) fail({what, ": ERR"});
    if (exp_underrun_free && underrun) fail({what, ": UNDERRUN with a fast memory"});
    if (lock_lost) fail({what, ": LOCK_LOST"});
  endtask

  initial begin
    lat_master = "tcon";
    clks(3);
    rst_n = 1;
    clks(2);
    // unplugged / not locked: training symbols, a frame waits for lock
    clks(40);
    if (n_train == 0 || n_idle != 0) fail("no training symbols while unplugged");
    if (locked) fail("LOCKED while unplugged");
    h_active = 8; v_active = 1; fb_addr = 32'h0030_0000; stride = 32;
    fill_rand(fb_addr, 8); check_on = 1;
    @(negedge clk); start = 1; @(negedge clk); start = 0;
    vbo_htpdn_n = 0; clks(100);
    if (rx_lines != 0 || rx_line != -1) fail("pixels sent before lock");
    vbo_lockn_n = 0; clks(2);
    if (!locked) fail("LOCKED low with the panel locked");
    wait_idle("first frame");
    if (rx_lines != 1) fail("first frame not seen");
    begin int i0; i0 = n_idle; clks(40); if (n_idle == i0) fail("no idle symbols when locked"); end
    // frames
    for (int k = 0; k < 20; k++) begin
      int h, v;
      h = 1 + $urandom % 70; v = 1 + $urandom % 4;
      mem.stall = (k % 2) == 1;
      sym_div = mem.stall ? 4'(6 + $urandom % 3) : 4'(4 + $urandom % 5);
      hblank = $urandom % 6;
      frame(h, v, !mem.stall, $sformatf("frame %0d (%0dx%0d, div %0d)", k, h, v, sym_div));
    end
    // fast symbols: underrun, data still correct
    mem.stall = 1; sym_div = 1;
    frame(64, 2, 0, "sym_div 1");
    if (!underrun) fail("no UNDERRUN at one symbol per clock with a stalling memory");
    sym_div = 4; mem.stall = 0;
    // zero sizes
    frame(0, 3, 1, "H_ACTIVE 0");
    frame(8, 0, 1, "V_ACTIVE 0");
    // START while busy is ignored
    begin
      int nd0;
      h_active = 16; v_active = 2; fill_rand(fb_addr, 16); fill_rand(fb_addr + stride, 16);
      nd0 = n_done; rx_lines = 0;
      @(negedge clk); start = 1; @(negedge clk); start = 0;
      clks(5); start = 1; @(negedge clk); start = 0;
      wait_idle("start while busy");
      if (n_done != nd0 + 1 || rx_lines != 2) fail("START while busy restarted the frame");
    end
    // lock lost in the middle of a frame
    begin
      int nl0;
      h_active = 32; v_active = 3; sym_div = 4;
      for (int k = 0; k < 3; k++) fill_rand(fb_addr + 32'(k) * 32'(stride), 32);
      nl0 = n_lock_irq; check_on = 0;
      @(negedge clk); start = 1; @(negedge clk); start = 0;
      clks(150); vbo_lockn_n = 1; clks(30); vbo_lockn_n = 0;
      wait_idle("lock lost");
      if (!lock_lost || n_lock_irq != nl0 + 1) fail("LOCK_LOST not reported");
      check_on = 1;
    end
    // AXI read error
    begin
      int ne0;
      h_active = 16; v_active = 2; stride = 64;
      mem.err_lo = fb_addr + 64 + 12; mem.err_hi = mem.err_lo + 4;
      ne0 = n_err_irq; check_on = 0;
      @(negedge clk); start = 1; @(negedge clk); start = 0;
      wait_idle("axi error");
      if (!err || n_err_irq != ne0 + 1) fail("ERR after an AXI error response");
      mem.err_lo = '1; mem.err_hi = '1; check_on = 1;
    end
    frame(24, 2, 1, "clean after errors");
    // reset in the middle of a frame
    h_active = 64; v_active = 4; check_on = 0;
    @(negedge clk); start = 1; @(negedge clk); start = 0;
    clks(60);
    rst_n = 0; clks(2);
    if (busy || m_arvalid || m_awvalid) fail("not idle in reset");
    rst_n = 1; rx_line = -1; rx_q.delete(); clks(4);
    check_on = 1;
    frame(16, 2, 1, "after reset");
    lat_summary();
    finish("TCON_VbyOne");
  end
endmodule
