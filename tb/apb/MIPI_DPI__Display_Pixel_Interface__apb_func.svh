// SPDX-License-Identifier: Apache-2.0
// IP part of MIPI_DPI__Display_Pixel_Interface__apb_tb: timing set through
// the register window, every output checked position by position against a
// shadow model over whole frames (24 and 18-bit colour, shutdown), refused
// enables (CFG_ERR), and the frame counter wrapping.
  initial pixel = 0;
  int HFP, HSW, HBP, HACT, VFP, VSW, VBP, VACT, HTOT, VTOT, sx, sy;
  bit cm;

  function automatic logic [23:0] pattern(input int x, input int y);
    return {8'(x * 37 + y * 11), 8'(x ^ (y * 5)), 8'(x + y * 3)} ^ ((x + y) % 3 == 0 ? 24'hFFFFFF : 24'h0);
  endfunction

  task automatic set_cfg(input int hfp_, hsw_, hbp_, hact_, vfp_, vsw_, vbp_, vact_);
    HFP = hfp_; HSW = hsw_; HBP = hbp_; HACT = hact_;
    VFP = vfp_; VSW = vsw_; VBP = vbp_; VACT = vact_;
    HTOT = hfp_ + hsw_ + hbp_ + hact_; VTOT = vfp_ + vsw_ + vbp_ + vact_;
    wr(A_HFP, hfp_); wr(A_HSW, hsw_); wr(A_HBP, hbp_); wr(A_HACT, hact_);
    wr(A_VFP, vfp_); wr(A_VSW, vsw_); wr(A_VBP, vbp_); wr(A_VACT, vact_);
  endtask

  // wait for a vertical wrap, then follow the frame from (0,0)
  task automatic resync;
    logic [15:0] fc;
    fc = frame_cnt;
    @(negedge PCLK);
    while (frame_cnt == fc) @(negedge PCLK);
    sx = 0; sy = 0;
    pixel = pattern(0, 0);
  endtask

  task automatic check_frames(input int n);
    bit ehs, evs, eact;
    logic [23:0] ergb;
    for (int i = 0; i < n * HTOT * VTOT; i++) begin
      @(negedge PCLK);
      ehs  = (sx >= HFP) && (sx < HFP + HSW);
      evs  = (sy >= VFP) && (sy < VFP + VSW);
      eact = (sx >= HFP + HSW + HBP) && (sy >= VFP + VSW + VBP);
      ergb = eact ? (pattern(sx, sy) & (cm ? 24'hFCFCFC : 24'hFFFFFF)) : 24'h0;
      if (hsync !== ehs || vsync !== evs || de !== eact || rgb !== ergb || pclk !== 1'b0)
        fail($sformatf("(%0d,%0d) hs %b/%b vs %b/%b de %b/%b rgb %h/%h", sx, sy,
                       hsync, ehs, vsync, evs, de, eact, rgb, ergb));
      if (sx == HTOT - 1) begin sx = 0; sy = (sy == VTOT - 1) ? 0 : sy + 1; end
      else sx++;
      #1 pixel = pattern(sx, sy);
    end
  endtask

  task automatic cfg_err(input string m);
    wr(A_IRQ_STATUS, IRQ_ALL);
    wr(A_CTRL, 1);
    rd_exp(A_CTRL, 0);
    rd(A_IRQ_STATUS); if (!rdv[IRQ_CFG_ERR]) fail({"CFG_ERR: ", m});
    wr(A_IRQ_STATUS, IRQ_ALL);
    rd(A_IRQ_STATUS); if (!rdv[IRQ_CFG_ERR]) fail({"CFG_ERR held: ", m});
    wr(A_CTRL, 0);                                      // accepted: clears the core flag
    wr(A_IRQ_STATUS, IRQ_ALL);
    rd_exp(A_IRQ_STATUS, 0);
  endtask

  task automatic ip_func;
    logic [15:0] f0;
    rd_exp(A_FLAGS, 0);                                 // no streams: always 0
    // ---- register window ----
    for (int a = 0; a < 8; a++) rd_exp(A_HFP + 4 * a, 0);
    rd_exp(A_CTRL, 0); rd_exp(A_FRAME, 0); rd_exp(A_HCNT, 0); rd_exp(A_VCNT, 0);
    for (int a = 0; a < 8; a++) begin
      wr(A_HFP + 4 * a, 32'hFFFF_FFFF); rd_exp(A_HFP + 4 * a, 16'hFFFF);
      wr(A_HFP + 4 * a, 32'h0001_5A5A); rd_exp(A_HFP + 4 * a, 16'h5A5A);
      wr(A_HFP + 4 * a, 0);             rd_exp(A_HFP + 4 * a, 0);
    end
    wr(A_FRAME, 32'hFFFF); wr(A_HCNT, 32'hFFFF); wr(A_VCNT, 32'hFFFF);   // read-only
    rd_exp(A_FRAME, 0); rd_exp(A_HCNT, 0); rd_exp(A_VCNT, 0);
    apb(1, A_HFP, 32'h1234, 4'h3);
    if (!rerr) fail("no PSLVERR on a partial core register write");
    rd_exp(A_HFP, 0);
    // ---- refused enables ----
    cfg_err("all zero");
    set_cfg(16'hFFFF, 1, 1, 1, 1, 1, 1, 1);
    cfg_err("line total above 65536");
    set_cfg(1, 1, 1, 1, 1, 16'hFFFF, 1, 1);
    cfg_err("frame total above 65536");
    // totals of exactly 65536 are accepted, 65537 refused
    set_cfg(16'hFFFD, 1, 1, 1, 1, 16'hFFFD, 1, 1);
    wr(A_CTRL, 1);
    rd_exp(A_CTRL, 1);
    wr(A_CTRL, 0);
    wr(A_HBP, 2);
    cfg_err("line total 65537");
    wr(A_HBP, 1); wr(A_VBP, 2);
    cfg_err("frame total 65537");
    set_cfg(1, 1, 1, 1, 1, 1, 0, 1);
    wr(A_IRQ_ENABLE, IRQ_ALL);
    wr(A_CTRL, 1);
    cycles(2);
    if (!irq) fail("CFG_ERR drives the pin");
    wr(A_CTRL, 0);
    wr(A_IRQ_STATUS, IRQ_ALL);
    if (irq) fail("irq after clear");
    // ---- frames, 24-bit ----
    set_cfg(2, 3, 4, 8, 1, 2, 1, 3);
    cm = 0;
    wr(A_CTRL, 1);
    rd_exp(A_CTRL, 1);
    resync();
    check_frames(3);
    rd(A_FRAME);
    if (rdv !== {16'h0, frame_cnt}) fail("FRAME vs frame_cnt pins");
    // ---- 18-bit colour, another timing ----
    wr(A_CTRL, 0);
    rd_exp(A_HCNT, 0); rd_exp(A_VCNT, 0);
    set_cfg(1, 1, 2, 13, 2, 1, 2, 4);
    cm = 1;
    wr(A_CTRL, 5);
    resync();
    check_frames(2);
    // ---- shutdown: outputs low, position held ----
    wr(A_CTRL, 3);
    cycles(2);
    rd(A_HCNT); f0 = rdv[15:0];
    rd(A_VCNT);
    cycles(5);
    rd_exp(A_HCNT, f0);
    if (hsync || vsync || de || rgb) fail("shutdown outputs");
    wr(A_CTRL, 1);
    cm = 0;
    resync();
    check_frames(1);
    // ---- the frame counter wraps (16-clock frames) ----
    wr(A_CTRL, 0);
    set_cfg(1, 1, 1, 1, 1, 1, 1, 1);
    wr(A_CTRL, 1);
    f0 = frame_cnt;
    cycles(16 * 65536 + 64);
    rd(A_FRAME);
    if (rdv[15:0] !== frame_cnt || frame_cnt > f0 + 16'd8) fail($sformatf("frame counter wrap %h", rdv));
    rd(A_HCNT); rd(A_VCNT);
    wr(A_CTRL, 0);
    // ---- masked, then left pending into reset ----
    wr(A_IRQ_ENABLE, 0);
    wr(A_HFP, 0);
    wr(A_CTRL, 1);
    cycles(2);
    if (irq) fail("masked CFG_ERR drives the pin");
    wr(A_IRQ_ENABLE, IRQ_ALL);
  endtask
