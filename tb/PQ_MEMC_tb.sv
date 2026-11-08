// SPDX-License-Identifier: Apache-2.0
// Self-checking core testbench of PQ_MEMC_top (TV SoC picture quality,
// AXI4 manager). Random 10-bit RGB frames are placed in the behavioural AXI4
// memory; after each job every destination word is compared with an
// independent model of the l0 / l1 / l2d arithmetic (metadata decode, EETF
// knee / slope, trim gain / offset with clamp, MEMC blend). Covers: tone
// mapping off (identity), SDR / HDR10 / Dolby Vision metadata, MEMC on with
// a = 0, 255 and random, long write-channel stalls (output FIFO
// back-pressure), line widths 1..MAXW and strides with gaps, random
// and zero memory stalls, CFG_ERR (H_ACTIVE 0 or above MAXW), V_ACTIVE 0, an
// AXI read error (ERR + ERR interrupt), START while busy, reset in the middle
// of a job. The trim gain is kept at or below 1.0 (see rtl/pq/README.md).
// Prints LAT lines.
`timescale 1ns/1ps
`include "soc_ss_axi_mem.svh"
module PQ_MEMC_tb;
  `include "soc_ss_tb_common.svh"
  `include "tv_lat_mon.svh"
  localparam int MAXW = 64;
  logic [31:0] cur_addr = 0, prev_addr = 0, dst_addr = 0, meta0 = 0, meta1 = 0, meta2 = 0, meta3 = 0;
  logic [15:0] stride = 0, h_active = 0, v_active = 0, display_peak = 300;
  logic        memc_en = 0, tone_en = 0, meta_load = 0, start = 0;
  logic [7:0]  mv_frac = 0;
  wire         busy, err, cfg_err, params_ok, done, err_irq;
  wire  [15:0] tone_slope, content_max, lines;
  wire  [31:0] cycles;
  PQ_MEMC_top #(.MAXW(MAXW)) dut (.*);

  int n_done = 0, n_err_irq = 0;
  always @(posedge clk) if (rst_n) begin n_done += done; n_err_irq += err_irq; end
  // the output FIFO must never be pushed while full (white-box: a lost pixel
  // would also show as a data mismatch, this names the cause)
  always @(posedge clk) if (rst_n && dut.u_out.push && dut.u_out.full) fail("output FIFO pushed while full");
  // long write-channel stalls: hide W from the memory and hold WREADY low
  // together, so both sides see the same stall
  bit wstall = 0;
  initial forever begin
    @(negedge clk);
    if (wstall && $urandom % 8 == 0) begin
      force m_wvalid = 1'b0; force m_wready = 1'b0;
      repeat (10 + $urandom % 30) @(negedge clk);
      release m_wvalid; release m_wready;
    end
  end

  // ---------------- reference model ----------------
  logic [15:0] r_knee = 16'hFFFF, r_slope = 16'hFFFF, r_gain = 16384, r_off = 0, r_cmax = 0;
  bit          r_loaded = 0;
  task automatic model_meta(input logic [127:0] m, input logic [15:0] peak);
    longint s;
    r_knee = 16'hC000;
    if (m[15:0] == 0) begin
      r_slope = 16'hFFFF; r_gain = 16384; r_off = 0; r_cmax = 100;
    end else begin
      s = (longint'(65536) * peak) / (m[31:16] == 0 ? 1 : m[31:16]);
      r_slope = s >= 65536 ? 16'hFFFF : 16'(s);
      r_gain = m[95:80]; r_off = m[111:96]; r_cmax = m[31:16];
    end
    r_loaded = 1;
  endtask
  function automatic logic [15:0] eetf(input logic [15:0] x);
    logic [15:0] kn, sl, gn, of, y;
    longint tr, sm;
    bit use_l0;
    use_l0 = tone_en && r_loaded;
    kn = use_l0 ? r_knee : 16'hFFFF; sl = use_l0 ? r_slope : 16'hFFFF;
    gn = use_l0 ? r_gain : 16'd16384; of = use_l0 ? r_off : 16'd0;
    if (x > kn) y = kn + 16'((longint'(x - kn) * sl) >> 16);
    else y = x;
    tr = (longint'(y) * gn) >> 14;
    sm = tr + of;
    return sm > 65535 ? 16'hFFFF : 16'(sm);
  endfunction
  function automatic logic [31:0] model_px(input logic [31:0] cw, input logic [31:0] pw);
    logic [31:0] o;
    o = 0;
    for (int ch = 0; ch < 3; ch++) begin
      logic [9:0] c10, p10;
      logic [15:0] c, p, m;
      longint mix;
      c10 = cw[10*ch +: 10]; p10 = pw[10*ch +: 10];
      c = eetf({c10, c10[9:4]});
      if (memc_en) begin
        p = eetf({p10, p10[9:4]});                    // both frames go through the tone curve
        mix = longint'(p) * (256 - mv_frac) + longint'(c) * mv_frac;
        m = 16'(mix >> 8);
      end else m = c;
      o[10*ch +: 10] = m[15:6];
    end
    return o;
  endfunction

  // ---------------- one job ----------------
  task automatic wait_idle(input string what);
    int t;
    t = 0;
    while (busy && t < 400000) begin @(negedge clk); t++; end
    if (busy) fail({what, ": job did not finish"});
  endtask
  task automatic go;
    @(negedge clk); start = 1; @(negedge clk); start = 0;
  endtask
  task automatic job(input int h, input int v, input string what);
    int nd0, nbad;
    logic [31:0] base;
    base = 32'h0010_0000 + 32'(($urandom % 64) * 4);
    stride = 16'(4 * h + 4 * ($urandom % 4));
    cur_addr = base; prev_addr = base + 32'h0004_0000; dst_addr = base + 32'h0008_0000;
    if ($urandom % 3 == 0) prev_addr = prev_addr + 32'h4000_0000;   // anywhere in the map
    h_active = 16'(h); v_active = 16'(v);
    for (int k = 0; k < v; k++) for (int i = 0; i < h; i++) begin
      logic [31:0] o;
      o = 32'(k) * 32'(stride) + 32'(4 * i);
      mem.poke(cur_addr + o, {2'b00, 30'($urandom)});
      mem.poke(prev_addr + o, {2'b00, 30'($urandom)});
      mem.poke(dst_addr + o, 32'hBAD0_0000);
    end
    nd0 = n_done;
    go();
    if (!busy) fail({what, ": not busy after START"});
    wait_idle(what);
    clks(2);
    if (n_done != nd0 + 1) fail($sformatf("%s: %0d DONE pulses", what, n_done - nd0));
    if (lines !== 16'(v)) fail($sformatf("%s: LINES %0d, expected %0d", what, lines, v));
    if (err || cfg_err) fail({what, ": ERR / CFG_ERR"});
    if (v != 0 && cycles == 0) fail({what, ": CYCLES 0"});
    nbad = 0;
    for (int k = 0; k < v; k++) for (int i = 0; i < h; i++) begin
      logic [31:0] o, e, g;
      o = 32'(k) * 32'(stride) + 32'(4 * i);
      e = model_px(mem.peek(cur_addr + o), mem.peek(prev_addr + o));
      g = mem.peek(dst_addr + o);
      if (g !== e && nbad++ < 5)
        fail($sformatf("%s: line %0d px %0d = %h, expected %h (cur %h prev %h)", what, k, i, g, e,
                       mem.peek(cur_addr + o), mem.peek(prev_addr + o)));
    end
  endtask

  task automatic load_meta(input logic [15:0] fmt, input logic [15:0] cmax, input logic [15:0] gain,
                           input logic [15:0] off, input logic [15:0] peak);
    logic [127:0] m;
    m = {16'd0, off, gain, 16'd0, 16'd4000, 16'd5, cmax, fmt};
    {meta3, meta2, meta1, meta0} = m;
    display_peak = peak;
    @(negedge clk); meta_load = 1; @(negedge clk); meta_load = 0;
    if (params_ok) fail("PARAMS_OK not cleared by META_LOAD");
    clks(4);
    model_meta(m, peak);
    if (!params_ok) fail("PARAMS_OK not set after META_LOAD");
    if (tone_slope !== r_slope) fail($sformatf("TONE_SLOPE %h, expected %h", tone_slope, r_slope));
    if (content_max !== r_cmax) fail($sformatf("CONTENT_MAX %0d, expected %0d", content_max, r_cmax));
  endtask

  initial begin
    lat_master = "pq";
    clks(3);
    rst_n = 1;
    clks(2);
    if (params_ok) fail("PARAMS_OK out of reset");
    // tone mapping and MEMC off: identity
    mem.stall = 0;
    for (int k = 0; k < 4; k++) job(1 + $urandom % MAXW, 1 + $urandom % 4, $sformatf("identity %0d", k));
    // TONE_EN without metadata: still neutral
    tone_en = 1;
    job(17, 2, "tone_en without metadata");
    // MEMC only: a = 0 (previous frame), 255, random
    memc_en = 1;
    tone_en = 0;
    mv_frac = 0;   job(20, 3, "memc a=0");
    mv_frac = 255; job(33, 2, "memc a=255");
    for (int k = 0; k < 6; k++) begin
      mem.stall = k % 2;
      mv_frac = 8'($urandom);
      job(1 + $urandom % MAXW, 1 + $urandom % 4, $sformatf("memc random %0d", k));
    end
    // metadata: SDR, HDR10 (compression), DV with trim gain / offset
    tone_en = 1;
    load_meta(0, 1000, 16384, 0, 300);
    memc_en = 0; job(24, 2, "SDR metadata");
    load_meta(1, 1000, 16384, 0, 300);
    for (int k = 0; k < 4; k++) begin
      mem.stall = k % 2; memc_en = k[1]; mv_frac = 8'($urandom);
      job(1 + $urandom % MAXW, 1 + $urandom % 3, $sformatf("HDR10 %0d", k));
    end
    load_meta(2, 4000, 12000, 16'h2000, 600);         // offset pushes bright pixels into the clamp
    for (int k = 0; k < 4; k++) begin
      mem.stall = k % 2; memc_en = k[0]; mv_frac = 8'($urandom);
      job(1 + $urandom % MAXW, 1 + $urandom % 3, $sformatf("DV trim %0d", k));
    end
    load_meta(1, 200, 16384, 0, 300);                 // display brighter than content: slope 1.0
    job(MAXW, 2, "HDR10 no compression, full MAXW");
    // tone mapping off again while metadata stays loaded
    tone_en = 0; memc_en = 0;
    job(9, 1, "tone_en 0 with metadata loaded");
    // long write stalls: the read side must wait for output FIFO space
    wstall = 1; tone_en = 1; memc_en = 1;
    for (int k = 0; k < 4; k++) begin
      mem.stall = k % 2; mv_frac = 8'($urandom);
      job(MAXW - $urandom % 8, 2, $sformatf("write stalls %0d", k));
    end
    wstall = 0; tone_en = 0; memc_en = 0;
    // CFG_ERR: H_ACTIVE 0 and above MAXW
    begin
      int nd0;
      for (int t = 0; t < 2; t++) begin
        h_active = t == 0 ? 0 : MAXW + 1; v_active = 2;
        nd0 = n_done;
        go(); clks(3);
        if (busy) fail("busy after CFG_ERR");
        if (!cfg_err) fail($sformatf("no CFG_ERR for H_ACTIVE %0d", h_active));
        if (n_done != nd0 + 1) fail("CFG_ERR: DONE");
        if (lines !== 0) fail("CFG_ERR: LINES");
      end
    end
    // V_ACTIVE 0: DONE at once, nothing moved
    begin
      int nb0, nd0;
      h_active = 8; v_active = 0;
      nb0 = mem.n_rd_bursts; nd0 = n_done;
      go(); clks(3);
      if (busy || cfg_err || n_done != nd0 + 1 || mem.n_rd_bursts != nb0) fail("V_ACTIVE 0");
    end
    // START while busy is ignored (one DONE)
    begin
      int nd0;
      memc_en = 1; mv_frac = 100;
      h_active = 32; v_active = 3; cur_addr = 32'h0002_0000; prev_addr = 32'h0003_0000;
      dst_addr = 32'h0004_0000; stride = 128;
      nd0 = n_done;
      go(); clks(10); go();
      wait_idle("start while busy"); clks(2);
      if (n_done != nd0 + 1) fail("START while busy restarted the job");
    end
    // AXI read error on line 1 of the previous frame
    begin
      int ne0;
      mem.err_lo = 32'h0003_0000 + 128 + 8; mem.err_hi = mem.err_lo + 4;
      ne0 = n_err_irq;
      go(); wait_idle("axi error"); clks(2);
      if (!err) fail("no ERR after an AXI error response");
      if (n_err_irq != ne0 + 1) fail("ERR interrupt count");
      if (lines !== 3) fail("AXI error: LINES");
      mem.err_lo = '1; mem.err_hi = '1;
    end
    // ERR clears on the next START
    mem.stall = 1;
    job(12, 2, "clean after error");
    // reset in the middle of a job
    h_active = 64; v_active = 4;
    go(); clks(40);
    rst_n = 0; clks(2);
    if (busy || m_awvalid || m_arvalid || m_wvalid) fail("not idle in reset");
    if (params_ok) fail("PARAMS_OK after reset");
    rst_n = 1; clks(4);
    r_loaded = 0;
    tone_en = 1; memc_en = 1; mv_frac = 77;
    job(40, 2, "after reset");
    lat_summary();
    finish("PQ_MEMC");
  end
endmodule
