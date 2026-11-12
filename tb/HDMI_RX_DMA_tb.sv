// SPDX-License-Identifier: Apache-2.0
// Self-checking core testbench of HDMI_RX_DMA_top (TV SoC, AXI4 manager).
// A TMDS source model (DVI 8b/10b TMDS encoder with running disparity,
// control tokens for HSYNC / VSYNC, optional video guard bands) sends frames
// of random pixels; every captured line in the behavioural AXI4 memory is
// compared with the pixels sent. Covers: line widths 1..64 and strides with
// gaps, random and zero memory stalls, guard bands on and off, frames with
// short lines (zero padding, LEN_ERR), long lines (cut, LEN_ERR), FIFO
// overflow (OVF), an AXI write error (ERR + ERR interrupt), V_ACTIVE = 0,
// HPD, ARM while busy, reset in the middle of a frame. Prints LAT lines.
`timescale 1ns/1ps
`include "soc_ss_axi_mem.svh"
module HDMI_RX_DMA_tb;
  `include "soc_ss_tb_common.svh"
  `include "tv_lat_mon.svh"
  logic [9:0]  tmds_ch0 = 10'h354, tmds_ch1 = 10'h354, tmds_ch2 = 10'h354;
  logic        hpd_en = 0, arm = 0;
  logic [31:0] fb_addr = 0;
  logic [15:0] stride = 0, h_active = 0, v_active = 0;
  wire         hpd, busy, err, ovf, len_err, vsync, hsync, done, err_irq, ovf_irq;
  wire  [15:0] lines;
  wire  [31:0] cycles;
  HDMI_RX_DMA_top #(.FIFO_DEPTH(64)) dut (.*);

  int n_done = 0, n_err_irq = 0, n_ovf_irq = 0;
  always @(posedge clk) if (rst_n) begin n_done += done; n_err_irq += err_irq; n_ovf_irq += ovf_irq; end

  // ---------------- TMDS source model ----------------
  int disp [3] = '{0, 0, 0};
  function automatic logic [9:0] tmds_enc(input logic [7:0] d, input int c);
    logic [8:0] qm; logic [9:0] q; int n1, n1q, n0q; bit xn;
    n1 = $countones(d);
    xn = (n1 > 4) || (n1 == 4 && d[0] == 1'b0);
    qm[0] = d[0];
    for (int i = 1; i < 8; i++) qm[i] = xn ? ~(qm[i-1] ^ d[i]) : (qm[i-1] ^ d[i]);
    qm[8] = !xn;
    n1q = $countones(qm[7:0]); n0q = 8 - n1q;
    if (disp[c] == 0 || n1q == n0q) begin
      q = {~qm[8], qm[8], qm[8] ? qm[7:0] : ~qm[7:0]};
      disp[c] += qm[8] ? (n1q - n0q) : (n0q - n1q);
    end else if ((disp[c] > 0 && n1q > n0q) || (disp[c] < 0 && n0q > n1q)) begin
      q = {1'b1, qm[8], ~qm[7:0]};
      disp[c] += 2 * int'(qm[8]) + (n0q - n1q);
    end else begin
      q = {1'b0, qm[8], qm[7:0]};
      disp[c] += -2 * int'(!qm[8]) + (n1q - n0q);
    end
    return q;
  endfunction
  function automatic logic [9:0] tok(input logic [1:0] c);
    case (c) 2'b00: return 10'h354; 2'b01: return 10'h0AB; 2'b10: return 10'h154; default: return 10'h2AB; endcase
  endfunction
  task automatic ctl(input bit vs, input bit hs, input int n);
    repeat (n) begin
      @(negedge clk);
      tmds_ch0 = tok({vs, hs}); tmds_ch1 = tok(2'b00); tmds_ch2 = tok(2'b00);
      disp = '{0, 0, 0};                              // control period resets the disparity
    end
  endtask
  task automatic gb;
    repeat (2) begin @(negedge clk); tmds_ch0 = 10'h2CC; tmds_ch1 = 10'h133; tmds_ch2 = 10'h2CC; end
  endtask
  task automatic video(input logic [31:0] px);
    @(negedge clk);
    tmds_ch0 = tmds_enc(px[7:0], 0); tmds_ch1 = tmds_enc(px[15:8], 1); tmds_ch2 = tmds_enc(px[23:16], 2);
  endtask

  // ---------------- one frame ----------------
  logic [31:0] exp_a [$], exp_d [$];                  // expected memory image (address, word)
  // lens[k]: pixels sent on line k; hblank: control characters between lines
  task automatic frame(input int h, input int v, input int lens [], input int hblank, input bit guard,
                       input int inject_line);
    logic [31:0] a;
    exp_a.delete(); exp_d.delete();
    ctl(0, 0, 8);
    ctl(1, 0, 6);                                     // VSYNC
    ctl(0, 0, 10);
    for (int k = 0; k < lens.size(); k++) begin
      ctl(0, 1, 4); ctl(0, 0, hblank);
      if (guard) gb();
      for (int i = 0; i < lens[k]; i++) begin
        logic [31:0] px;
        px = {8'h00, 24'($urandom)};
        video(px);
        if (k < v && i < h) begin exp_a.push_back(fb_addr + 32'(k) * 32'(stride) + 32'(4 * i)); exp_d.push_back(px); end
      end
      if (k < v) for (int i = lens[k]; i < h; i++) begin exp_a.push_back(fb_addr + 32'(k) * 32'(stride) + 32'(4 * i)); exp_d.push_back(0); end
    end
    ctl(0, 0, 4);
  endtask

  task automatic wait_idle(input string what);
    int t;
    t = 0;
    while (busy && t < 200000) begin
      if (t % 64 == 0) ctl(0, 0, 1); else @(negedge clk);
      t++;
    end
    if (busy) fail({what, ": capture did not finish"});
  endtask

  task automatic check_mem(input string what);
    int nbad;
    nbad = 0;
    for (int i = 0; i < exp_a.size(); i++) if (mem.peek(exp_a[i]) !== exp_d[i]) begin
      if (nbad++ < 5) fail($sformatf("%s: word at %h = %h, expected %h", what, exp_a[i], mem.peek(exp_a[i]), exp_d[i]));
    end
  endtask

  // a full capture: arm, send, wait, check
  task automatic capture(input int h, input int v, input int lens [], input int hblank, input bit guard,
                         input bit exp_len_err, input string what);
    int nd0;
    fb_addr = (32'h0010_0000 + 32'(($urandom % 256) * 4)) | ($urandom % 2 ? 32'h4000_0000 : 0);
    stride  = 16'(4 * h + 4 * ($urandom % 8));
    h_active = 16'(h); v_active = 16'(v);
    for (int k = 0; k < v; k++) for (int i = 0; i < h; i++) mem.poke(fb_addr + 32'(k) * 32'(stride) + 32'(4 * i), 32'hBAD0_0000);
    nd0 = n_done;
    @(negedge clk); arm = 1; @(negedge clk); arm = 0;
    if (!busy) fail({what, ": not busy after ARM"});
    frame(h, v, lens, hblank, guard, -1);
    wait_idle(what);
    clks(2);
    if (n_done != nd0 + 1) fail($sformatf("%s: %0d DONE pulses", what, n_done - nd0));
    if (lines !== 16'(v)) fail($sformatf("%s: LINES %0d, expected %0d", what, lines, v));
    if (len_err !== exp_len_err) fail($sformatf("%s: LEN_ERR %b", what, len_err));
    if (ovf) fail({what, ": OVF"});
    if (err) fail({what, ": ERR"});
    if (v != 0 && cycles == 0) fail({what, ": CYCLES 0"});
    check_mem(what);
  endtask

  int lens [];
  initial begin
    lat_master = "hdmirx";
    clks(3);
    rst_n = 1;
    clks(2);
    // hot-plug detect
    if (hpd !== 0) fail("hpd before HPD_EN");
    hpd_en = 1; clks(1);
    if (hpd !== 1) fail("hpd does not follow HPD_EN");
    // sync decode
    ctl(1, 1, 2); @(negedge clk);
    if (vsync !== 1 || hsync !== 1) fail("VSYNC / HSYNC decode");
    // idle: no ARM, frames are ignored
    lens = new[2]; lens = '{8, 8};
    h_active = 8; v_active = 2;
    frame(8, 2, lens, 20, 0, -1);
    if (busy || mem.n_wr_bursts != 0) fail("captured without ARM");
    // basic captures
    for (int k = 0; k < 24; k++) begin
      int h, v;
      h = 1 + $urandom % 64; v = 1 + $urandom % 6;
      mem.stall = (k % 3) != 2;
      lens = new[v];
      foreach (lens[i]) lens[i] = h;
      capture(h, v, lens, 3 * h + 40, k % 2, 0, $sformatf("frame %0d (%0dx%0d)", k, h, v));
    end
    // more lines sent than V_ACTIVE: the extra ones are ignored
    lens = new[5]; lens = '{16, 16, 16, 16, 16};
    capture(16, 3, lens, 90, 1, 0, "extra lines");
    // short and long lines
    mem.stall = 1;
    lens = new[5]; lens = '{20, 7, 20, 31, 19};
    capture(20, 5, lens, 110, 0, 1, "short / long lines");
    // V_ACTIVE = 0: done at once after VSYNC
    lens = new[0];
    capture(8, 0, lens, 20, 0, 0, "V_ACTIVE 0");
    // ARM while busy is ignored (one DONE)
    begin
      int nd0;
      h_active = 4; v_active = 1; fb_addr = 32'h0002_0000; stride = 16;
      nd0 = n_done;
      @(negedge clk); arm = 1; @(negedge clk); arm = 0;
      clks(3); arm = 1; @(negedge clk); arm = 0;
      lens = new[1]; lens = '{4};
      frame(4, 1, lens, 20, 0, -1);
      wait_idle("arm while busy");
      clks(2);
      if (n_done != nd0 + 1) fail("ARM while busy restarted the capture");
    end
    // FIFO overflow: 300-pixel lines at one pixel per clock into a stalling memory
    begin
      h_active = 300; v_active = 2; fb_addr = 32'h0003_0000; stride = 1200;
      mem.stall = 1;
      @(negedge clk); arm = 1; @(negedge clk); arm = 0;
      lens = new[2]; lens = '{300, 300};
      frame(300, 2, lens, 1500, 0, -1);    // blanking long enough to pad: OVF only from the full FIFO
      wait_idle("overflow");
      if (!ovf) fail("no OVF on overflow");
      if (n_ovf_irq == 0) fail("no OVF interrupt");
      if (lines !== 2) fail("overflow frame: LINES");
    end
    // AXI write error on line 1
    begin
      int ne0;
      h_active = 16; v_active = 3; fb_addr = 32'h0004_0000; stride = 64;
      mem.err_lo = 32'h0004_0040 + 8; mem.err_hi = mem.err_lo + 4;
      ne0 = n_err_irq;
      @(negedge clk); arm = 1; @(negedge clk); arm = 0;
      lens = new[3]; lens = '{16, 16, 16};
      frame(16, 3, lens, 90, 0, -1);
      wait_idle("axi error");
      clks(2);
      if (!err) fail("no ERR after an AXI error response");
      if (n_err_irq != ne0 + 1) fail("ERR interrupt count");
      mem.err_lo = '1; mem.err_hi = '1;
    end
    // ERR and OVF clear on the next ARM; a clean frame after the errors
    lens = new[2]; lens = '{12, 12};
    mem.stall = 0;
    capture(12, 2, lens, 60, 1, 0, "clean after errors");
    // reset in the middle of a frame
    h_active = 32; v_active = 4; fb_addr = 32'h0005_0000; stride = 128;
    @(negedge clk); arm = 1; @(negedge clk); arm = 0;
    ctl(1, 0, 4); ctl(0, 0, 4);
    for (int i = 0; i < 20; i++) video($urandom);
    rst_n = 0; clks(2);
    if (busy || m_awvalid || m_arvalid || m_wvalid) fail("not idle in reset");
    rst_n = 1; clks(4);
    lens = new[2]; lens = '{10, 10};
    capture(10, 2, lens, 60, 0, 0, "after reset");
    lat_summary();
    finish("HDMI_RX_DMA");
  end
endmodule
