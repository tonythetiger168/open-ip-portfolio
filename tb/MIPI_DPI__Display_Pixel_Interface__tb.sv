// SPDX-License-Identifier: Apache-2.0
// ============================================================================
// Self-checking testbench for MIPI_DPI__Display_Pixel_Interface__top
// TB plays the video source (pixel input) and the display sink: an
// independent shadow timing model predicts hsync/vsync/de/rgb position by
// position and compares every pixel clock cycle.
// Checks: reset state / register write+readback / invalid config (enable
// with zero timing reg) rejected + irq / per-position hsync/vsync/de/rgb
// over full frames (pattern compared pixel by pixel) / shutdown blank+hold
// and resume / reconfiguration changes timing / color mode masking /
// frame_cnt over back-to-back frames.
// ============================================================================
`timescale 1ns/1ps
module MIPI_DPI__Display_Pixel_Interface__tb;

  logic        clk = 0, rst_n = 0;
  logic        irq;
  logic        pclk, hsync, vsync, de;
  logic [23:0] rgb;
  logic [23:0] pixel = 0;
  logic        reg_wr = 0;
  logic [3:0]  reg_addr = 0;
  logic [15:0] reg_wdata = 0;
  logic [15:0] reg_rdata;
  logic [15:0] frame_cnt;

  int errors = 0;

  MIPI_DPI__Display_Pixel_Interface__top dut (
    .clk(clk), .rst_n(rst_n), .irq(irq),
    .pclk(pclk), .hsync(hsync), .vsync(vsync), .de(de), .rgb(rgb),
    .pixel(pixel),
    .reg_wr(reg_wr), .reg_addr(reg_addr), .reg_wdata(reg_wdata),
    .reg_rdata(reg_rdata), .frame_cnt(frame_cnt)
  );

  always #5 clk = ~clk;

  // ------------------------------------------------------------------
  // shadow configuration + model state
  // ------------------------------------------------------------------
  int HFP, HSW, HBP, HACT, VFP, VSW, VBP, VACT;
  int HTOT, VTOT;
  bit cm;                          // color mode expected
  logic [15:0] sx, sy;             // shadow position (matches DUT hcnt/vcnt)

  function automatic logic [23:0] pattern(input logic [15:0] x,
                                          input logic [15:0] y);
    pattern = {8'hA5, y[7:0], x[7:0]};
  endfunction

  task automatic check(input bit cond, input string tag);
    begin
      if (!cond) begin
        errors++;
        $display("ERROR: %s (t=%0t)", tag, $time);
      end
    end
  endtask

  // expected outputs for shadow position (sx,sy)
  task automatic check_outputs(input string tag);
    bit ehs, evs, eact;
    logic [23:0] ergb;
    begin
      ehs  = (sx >= HFP) && (sx < HFP + HSW);
      evs  = (sy >= VFP) && (sy < VFP + VSW);
      eact = (sx >= HFP + HSW + HBP) && (sy >= VFP + VSW + VBP);
      ergb = eact ? (pattern(sx, sy) & (cm ? 24'hFCFCFC : 24'hFFFFFF))
                  : 24'h0;
      if (hsync !== ehs || vsync !== evs || de !== eact || rgb !== ergb) begin
        errors++;
        $display("ERROR: %s @(x=%0d,y=%0d) hs=%b/%b vs=%b/%b de=%b/%b rgb=%h/%h",
                 tag, sx, sy, hsync, ehs, vsync, evs, de, eact, rgb, ergb);
      end
    end
  endtask

  task automatic advance_shadow;
    begin
      if (sx == HTOT - 1) begin
        sx <= 0;
        if (sy == VTOT - 1) sy <= 0;
        else                sy <= sy + 1;
      end else begin
        sx <= sx + 1;
      end
    end
  endtask

  // ------------------------------------------------------------------
  // register tasks
  // ------------------------------------------------------------------
  task automatic reg_write(input logic [3:0] a, input logic [15:0] d);
    begin
      @(negedge clk);
      reg_wr    <= 1'b1;
      reg_addr  <= a;
      reg_wdata <= d;
      @(negedge clk);
      reg_wr    <= 1'b0;
    end
  endtask

  task automatic reg_check(input logic [3:0] a, input logic [15:0] exp,
                           input string tag);
    begin
      reg_addr = a;
      #1;
      if (reg_rdata !== exp) begin
        errors++;
        $display("ERROR: %s reg[%0d] got=%h exp=%h", tag, a, reg_rdata, exp);
      end
    end
  endtask

  task automatic set_cfg(input int hfp_, hsw_, hbp_, hact_,
                         input int vfp_, vsw_, vbp_, vact_);
    begin
      HFP = hfp_; HSW = hsw_; HBP = hbp_; HACT = hact_;
      VFP = vfp_; VSW = vsw_; VBP = vbp_; VACT = vact_;
      HTOT = hfp_ + hsw_ + hbp_ + hact_;
      VTOT = vfp_ + vsw_ + vbp_ + vact_;
      reg_write(4'd0, 16'(hfp_));
      reg_write(4'd1, 16'(hsw_));
      reg_write(4'd2, 16'(hbp_));
      reg_write(4'd3, 16'(hact_));
      reg_write(4'd4, 16'(vfp_));
      reg_write(4'd5, 16'(vsw_));
      reg_write(4'd6, 16'(vbp_));
      reg_write(4'd7, 16'(vact_));
    end
  endtask

  // drive pixel for the position the DUT will sample next
  task automatic feed_pixel;
    begin
      pixel = pattern(sx, sy);
    end
  endtask

  // wait for the next vertical wrap, then anchor the shadow at (0,0)
  task automatic resync;
    logic [15:0] fc;
    begin
      fc = frame_cnt;
      while (frame_cnt == fc)
        @(negedge clk);
      // wrap posedge just happened: DUT sits at (0,0), outputs show the
      // last position of the previous frame
      sx = 0;
      sy = 0;
      feed_pixel();
    end
  endtask

  // check one full frame, position by position
  task automatic check_frame(input logic [15:0] fc_exp, input string tag);
    begin
      for (int i = 0; i < HTOT * VTOT; i++) begin
        @(negedge clk);
        check_outputs(tag);
        advance_shadow();
        #1;
        feed_pixel();
      end
      check(frame_cnt == fc_exp, {tag, " frame_cnt"});
    end
  endtask

  // ------------------------------------------------------------------
  // test sequence
  // ------------------------------------------------------------------
  initial begin
    rst_n = 0;
    repeat (4) @(posedge clk);
    rst_n = 1;
    repeat (2) @(posedge clk);

    // (1) reset state
    check(hsync == 1'b0 && vsync == 1'b0 && de == 1'b0 && rgb == 24'h0 &&
          frame_cnt == 0 && irq == 1'b0, "reset state");
    reg_check(4'd0, 16'h0, "reset reg0");
    reg_check(4'd8, 16'h0, "reset ctrl");

    // (2) error injection: enable with all-zero timing -> reject + irq
    reg_write(4'd8, 16'h1);
    @(negedge clk);
    check(irq == 1'b1, "invalid config raises irq");
    reg_check(4'd8, 16'h0, "enable rejected");
    repeat (4) @(negedge clk);
    check(de == 1'b0 && hsync == 1'b0, "rejected enable stays blank");

    // (3) program config #1, readback, enable (cm=0)
    cm = 0;
    set_cfg(2, 2, 2, 8,   1, 1, 1, 4);
    reg_check(4'd0, 16'd2, "rb hfp");
    reg_check(4'd1, 16'd2, "rb hsw");
    reg_check(4'd2, 16'd2, "rb hbp");
    reg_check(4'd3, 16'd8, "rb hact");
    reg_check(4'd4, 16'd1, "rb vfp");
    reg_check(4'd5, 16'd1, "rb vsw");
    reg_check(4'd6, 16'd1, "rb vbp");
    reg_check(4'd7, 16'd4, "rb vact");
    reg_write(4'd8, 16'h1);          // enable
    @(negedge clk);
    check(irq == 1'b0, "valid enable clears irq");
    reg_check(4'd8, 16'h1, "ctrl enabled");

    // (4) two full frames, position-by-position (back-to-back)
    resync();
    check_frame(16'd2, "cfg1.frame0");
    check_frame(16'd3, "cfg1.frame1");

    // (5) shutdown: blank + hold, then resume at the held position
    drive_shutdown();
    check_resume();

    // (6) reconfigure: new timing + color mode, verify timing changed
    reg_write(4'd8, 16'h0);          // disable
    repeat (3) @(negedge clk);
    check(hsync == 1'b0 && de == 1'b0 && rgb == 24'h0, "disabled blank");
    cm = 1;
    set_cfg(3, 4, 1, 12,   2, 1, 2, 3);
    reg_write(4'd8, 16'h5);          // enable + color_mode
    resync();
    check_frame(16'd5, "cfg2.frame0");
    check_frame(16'd6, "cfg2.frame1");

    // ---- report ----
    if (errors == 0) $display("TEST PASSED: MIPI_DPI__Display_Pixel_Interface_");
    else             $display("TEST FAILED: %0d errors", errors);
    $finish;
  end

  // shutdown injection + resume check, shadow-consistent
  task automatic drive_shutdown;
    begin
      // a few normal steps first (mid-frame)
      repeat (20) begin
        @(negedge clk);
        check_outputs("pre-shutdown");
        advance_shadow();
        #1;
        feed_pixel();
      end
      // negedge K: drive shutdown write; DUT still advances once
      @(negedge clk);
      check_outputs("shutdown.req");
      advance_shadow();
      #1;
      feed_pixel();
      reg_wr    <= 1'b1;
      reg_addr  <= 4'd8;
      reg_wdata <= 16'h3;          // enable + shutdown
      // negedge K+1: write sampled this posedge; outputs still normal,
      // DUT counter advances once more and then holds
      @(negedge clk);
      reg_wr <= 1'b0;
      check_outputs("shutdown.hold_entry");
      advance_shadow();            // track the held counter position
      #1;
      feed_pixel();
      // from the next posedge: blank + counters held
      repeat (12) begin
        @(negedge clk);
        check(hsync == 1'b0 && vsync == 1'b0 && de == 1'b0 && rgb == 24'h0,
              "shutdown blank");
      end
    end
  endtask

  task automatic check_resume;
    begin
      // negedge R: drive resume (enable only)
      @(negedge clk);
      check(hsync == 1'b0 && de == 1'b0, "resume.req blank");
      reg_wr    <= 1'b1;
      reg_addr  <= 4'd8;
      reg_wdata <= 16'h1;
      // negedge R+1: write sampled, still blank
      @(negedge clk);
      reg_wr <= 1'b0;
      check(hsync == 1'b0 && de == 1'b0 && rgb == 24'h0, "resume hold");
      // negedge R+2: DUT resumes at the held shadow position
      repeat (40) begin
        @(negedge clk);
        check_outputs("resume");
        advance_shadow();
        #1;
        feed_pixel();
      end
    end
  endtask

  // timeout guard
  initial begin
    #2000000;
    $display("TEST FAILED: %0d errors", errors + 1);
    $finish;
  end

endmodule
