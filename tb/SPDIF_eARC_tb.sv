// SPDX-License-Identifier: Apache-2.0
// Self-checking core testbench of SPDIF_eARC_top (TV SoC, AXI4 manager).
// A biphase-mark source sends IEC 60958 blocks (192 frames, B / M / W
// preambles with the right polarity, 24-bit samples, V / U / C bits, even
// parity) with +-1 clk of jitter on every UI. Each 16-word chunk is checked
// against the reference model when its CHUNK interrupt fires; CS0 is checked
// against the 32 channel-status bits sent. Covers: lock after 4 subframes,
// parity errors, a stuck line (lock lost, CODE_ERR_CNT), a corrupted
// preamble, re-lock, ring wrap, ring full and FIFO overflow (OVF_CNT), AXI
// write errors, ENABLE off, UI_CLKS 4 and 8, reset.
`timescale 1ns/1ps
`include "soc_ss_axi_mem.svh"
module SPDIF_eARC_tb;
  `include "soc_ss_tb_common.svh"
  `include "tv_lat_mon.svh"
  logic        spdif_in = 0;
  logic        enable = 0;
  logic [7:0]  ui_clks = 8;
  logic [31:0] ring_base = 32'h0050_0000;
  logic [15:0] ring_words = 64, rd_idx = 0;
  wire         locked, err, chunk, lock_lost, cs, err_irq;
  wire  [31:0] cs0, samples;
  wire  [15:0] wr_idx, perr_cnt, code_err_cnt, ovf_cnt;
  SPDIF_eARC_top dut (.*);

  // ---------------- checker ----------------
  logic [31:0] expq [$];
  int          m_idx = 0, n_chunk = 0, n_lost = 0, n_cs = 0, n_err_irq = 0, nbad = 0;
  bit          auto_consume = 1;
  always @(posedge clk) if (rst_n) begin
    n_lost += lock_lost; n_cs += cs; n_err_irq += err_irq;
    if (chunk) begin
      n_chunk++;
      if (expq.size() < 16) fail("CHUNK without 16 expected words");
      else for (int i = 0; i < 16; i++) begin
        logic [31:0] e, a;
        e = expq.pop_front();
        a = ring_base + 32'(4 * ((m_idx + i) % ring_words));
        if (!err_irq && mem.peek(a) !== e && nbad++ < 8) fail($sformatf("ring word %0d: %h, expected %h", m_idx + i, mem.peek(a), e));
      end
      m_idx = (m_idx + 16) % ring_words;
      if (auto_consume) rd_idx <= 16'(m_idx);
    end
  end

  // ---------------- biphase-mark source ----------------
  int jit = 1;
  bit lvl = 0;
  time last_t = 0;
  bit  m_locked = 0;                                   // model: the receiver is locked
  int  exp_lost = 0;
  // a subframe is decoded only when the transition after its last data
  // interval arrives in time: its expected word waits in pend until then
  logic [31:0] pend_w;
  bit          pend_v = 0, pend_par = 0, pend_en = 0;
  time         last_tr = 0;
  int          skip = 3;                               // subframes not stored (lock-up)
  int          exp_perr = 0;
  task automatic ui(input bit l);
    int n;
    if (l != spdif_in) begin
      if (pend_v && $time - last_tr < 3 * ui_clks * 10 && enable && pend_en) begin
        if (skip > 0) skip--;
        else begin
          m_locked = 1;
          expq.push_back(pend_w);
          if (pend_par) exp_perr++;
        end
      end
      pend_v = 0;
      last_tr = $time;
    end
    last_t = $time;
    n = ui_clks + ((jit != 0) ? int'($urandom % 3) - 1 : 0);
    spdif_in = l;
    repeat (n) @(negedge clk);
  endtask
  // p: preamble 0 B, 1 M, 2 W; returns nothing, updates lvl
  task automatic subframe(input int p, input logic [23:0] smp, input bit v, input bit u, input bit c, input bit bad_par);
    logic [7:0] pat;
    logic [27:0] b;
    pat = (p == 0) ? 8'b11101000 : (p == 1) ? 8'b11100010 : 8'b11100100;
    if (lvl) pat = ~pat;
    for (int i = 7; i >= 0; i--) ui(pat[i]);
    lvl = pat[0];
    b = {1'b0, c, u, v, smp};
    b[27] = ^b[26:0] ^ bad_par;
    for (int i = 0; i < 28; i++) begin
      lvl = !lvl; ui(lvl);
      if (b[i]) lvl = !lvl;
      ui(lvl);
    end
    pend_w = {p == 2, p == 0, v, u, c, bad_par, 2'b00, smp}; pend_par = bad_par; pend_v = 1; pend_en = enable;
  endtask
  logic [31:0] csbits;
  // a line idle for longer than 4.5 UI loses lock: the receiver needs 4
  // subframes (3 not stored) to lock again
  task automatic idle_check;
    if ($time - last_t > (5 * ui_clks + 4) * 10) begin
      if (enable && m_locked) exp_lost++;
      m_locked = 0;
      skip = 3;
    end
  endtask
  task automatic blocks(input int nframes, input int perr_at);
    idle_check();
    for (int f = 0; f < nframes; f++) begin
      subframe(f % 192 == 0 ? 0 : 1, $urandom, $urandom % 16 == 0, $urandom, (f % 192) < 32 ? csbits[f % 192] : 1'b0, f == perr_at);
      subframe(2, $urandom, 0, $urandom, $urandom, 0);
    end
  endtask

  task automatic drain(input string what);
    int t;
    t = 0;
    while (expq.size() >= 16 && t < 20000) begin @(negedge clk); t++; end
    clks(10 * ui_clks);
    idle_check();
    if (expq.size() >= 16) fail($sformatf("%s: %0d words not written", what, expq.size()));
    if (perr_cnt !== 16'(exp_perr)) fail($sformatf("%s: PERR_CNT %0d, expected %0d", what, perr_cnt, exp_perr));
    if (code_err_cnt !== 16'(exp_lost) || n_lost != exp_lost) fail($sformatf("%s: lock lost %0d/%0d, expected %0d", what, code_err_cnt, n_lost, exp_lost));
  endtask

  initial begin
    lat_master = "spdif";
    csbits = 32'h8200_0104;                            // bits 24..27 = 0010 (48 kHz), bit 31 set
    clks(3);
    rst_n = 1;
    clks(2);
    // disabled: nothing
    blocks(4, -1);
    if (locked || samples != 0) fail("active while disabled");
    enable = 1; clks(2);
    // one block plus, random stalls; channel status
    blocks(200, 37);
    if (!locked) fail("not LOCKED");
    drain("block 1");
    if (cs0 !== csbits) fail($sformatf("CS0 %h, expected %h", cs0, csbits));
    if (n_cs == 0) fail("no CS pulse");
    // zero stalls, more blocks
    mem.stall = 0;
    csbits = 32'h0300_0004;
    blocks(200, -1);
    drain("block 2");
    if (cs0 !== csbits) fail($sformatf("CS0 %h, expected %h", cs0, csbits));
    mem.stall = 1;
    // a stuck line: lock lost, then re-lock
    begin
      int c0;
      blocks(4, -1);                                   // locked again after the drain
      c0 = code_err_cnt;
      ui(lvl); repeat (8 * ui_clks) @(negedge clk);
      clks(4);
      if (locked) fail("still LOCKED with a stuck line");
      if (code_err_cnt != c0 + 1) fail("lock loss not counted");
      blocks(40, -1);
      if (!locked) fail("no re-lock");
      drain("re-lock");
    end
    // a corrupted preamble (intervals 3,1,2,2): lock lost, the next one re-hunts
    begin
      int c0;
      logic [7:0] pat;
      blocks(4, -1);
      c0 = code_err_cnt;
      pat = 8'b11101100;
      if (lvl) pat = ~pat;
      for (int i = 7; i >= 0; i--) ui(pat[i]);
      lvl = pat[0];
      // the data of the lost subframe is not sent; the next preamble follows
      skip = 3; exp_lost++; m_locked = 0;
      blocks(30, -1);
      if (code_err_cnt != c0 + 1) fail("bad preamble not counted");
      drain("bad preamble");
    end
    // ring full: the consumer stops, the FIFO fills and overflows
    auto_consume = 0;
    blocks(80, -1);
    if (ovf_cnt == 0) fail("no OVF with the ring full");
    begin
      int k;
      k = ovf_cnt;
      // dropped words are the newest ones: remove them from the prediction
      // (the FIFO keeps the oldest 64 waiting words)
      while (k > 0) begin void'(expq.pop_back()); k--; end
    end
    auto_consume = 1; rd_idx = 16'(m_idx);
    blocks(8, -1);
    drain("ring full");
    // AXI write error
    begin
      int ne0;
      ne0 = n_err_irq;
      mem.err_lo = ring_base + 32'(4 * m_idx) + 8; mem.err_hi = mem.err_lo + 4;
      blocks(16, -1);
      drain("axi error");
      if (n_err_irq != ne0 + 1 || !err) fail("ERR after an AXI error response");
      mem.err_lo = '1; mem.err_hi = '1;
    end
    // ENABLE off clears WR_IDX / ERR / LOCKED and the FIFO
    enable = 0; clks(4);
    if (wr_idx != 0 || err || locked) fail("ENABLE 0 does not clear the state");
    expq.delete(); m_idx = 0; rd_idx = 0; m_locked = 0;
    // UI_CLKS 4 (fast eARC-like link)
    ui_clks = 4; jit = 0;
    enable = 1; clks(2);
    blocks(60, -1);
    drain("UI 4");
    ui_clks = 8; jit = 1;
    // reset
    rst_n = 0; clks(2);
    if (m_awvalid || m_wvalid || locked) fail("not idle in reset");
    rst_n = 1; clks(2);
    expq.delete(); m_idx = 0; rd_idx = 0; exp_perr = 0; skip = 3; exp_lost = 0; n_lost = 0; m_locked = 0;
    blocks(40, -1);
    drain("after reset");
    lat_summary();
    finish("SPDIF_eARC");
  end
endmodule
