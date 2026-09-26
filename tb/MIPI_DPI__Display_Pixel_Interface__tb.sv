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

  // pxor randomizes the pixel pattern during the Verilator CRV phase;
  // it stays 0 on the directed/iverilog path (behavior byte-identical)
  logic [23:0] pxor = 24'h0;
  function automatic logic [23:0] pattern(input logic [15:0] x,
                                          input logic [15:0] y);
    pattern = {8'hA5, y[7:0], x[7:0]} ^ pxor;
  endfunction

`ifdef VERILATOR
  // =====================================================================
  // v2.5 CRV instrumentation (Verilator only; iverilog path unchanged)
  // Tool notes (Verilator 5.006): no native FSM/SVA coverage and
  // randomize() ignores constraint blocks -> procedural constraints
  // ($urandom_range + rejection sampling), TB FSM probe, immediate
  // assertions.
  // =====================================================================
  // This DUT is counter-based (no state register); the frame FSM is
  // probed as the reachable {hsync,vsync,de} region encodings:
  //   3'b000 blanking, 001 active, 010 vsync, 100 hsync, 110 h+v sync
  localparam int DPI_FSM_TOTAL = 5;
  logic [4:0] fsm_seen = '0;         // visited-region bitmap
  wire  [2:0] dut_region = {hsync, vsync, de};

  int sva_total = 0, sva_fail = 0;
  // counted immediate assertion: every evaluation is one check
  task automatic sva_check(input bit cond, input string name);
    begin
      sva_total++;
      if (!cond) begin
        sva_fail++;
        errors++;
        $display("SVA_FAIL: %s @%0t", name, $time);
      end
    end
  endtask

  // region coverage: sample video-output region every clock
  always @(posedge clk) begin
    case (dut_region)
      3'b000: fsm_seen[0] <= 1'b1;
      3'b001: fsm_seen[1] <= 1'b1;
      3'b010: fsm_seen[2] <= 1'b1;
      3'b100: fsm_seen[3] <= 1'b1;
      3'b110: fsm_seen[4] <= 1'b1;
      default: ;
    endcase
  end

  // output-invariant assertion suite (sampled coherently pre-NBA)
  bit first_cycle = 1;   // skip checks on the very first posedge (DUT
                         // reset values land in that NBA region)
  logic [23:0] pixel_q = '0;
  logic [15:0] fc_q = 0;
  logic [2:0]  ctrl_q = 0;   // blanking lags ctrl by one registered cycle
  always @(posedge clk) begin
    if (first_cycle) begin
      first_cycle <= 0;
    end else if (!rst_n) begin
      // A1: outputs quiescent during reset
      sva_check(hsync === 1'b0 && vsync === 1'b0 && de === 1'b0 &&
                rgb === 24'h0 && irq === 1'b0, "A1 reset: outputs quiescent");
    end else begin
      // A2: disabled -> blank outputs (one cycle after ctrl clears)
      sva_check(ctrl_q[0] || (hsync === 1'b0 && vsync === 1'b0 &&
                de === 1'b0 && rgb === 24'h0), "A2 disabled blank");
      // A3: shutdown -> blank outputs (one cycle after ctrl[1] sets)
      sva_check(!ctrl_q[1] || (hsync === 1'b0 && vsync === 1'b0 &&
                de === 1'b0 && rgb === 24'h0), "A3 shutdown blank");
      // A4: rgb follows the (masked) pixel input in active regions
      sva_check(rgb === (de ? (pixel_q & (dut.ctrl[2] ? 24'hFCFCFC
                                                       : 24'hFFFFFF))
                            : 24'h0), "A4 rgb pipeline");
      // A5: irq only when an enable was rejected (ctrl still disabled)
      sva_check(!irq || (dut.ctrl == 3'b000), "A5 irq implies rejected enable");
      // A6: frame_cnt never decreases (16'hFFFF -> 0 wrap is legal)
      sva_check(frame_cnt >= fc_q || (fc_q == 16'hFFFF && frame_cnt == 16'h0),
                "A6 frame_cnt monotone");
      // A7: sync and active-video never overlap
      sva_check(!(de && (hsync || vsync)), "A7 de excludes syncs");
      // A8: legal region encoding only
      sva_check(dut_region != 3'b011 && dut_region != 3'b101 &&
                dut_region != 3'b111, "A8 region encoding legal");
    end
    pixel_q <= pixel;
    fc_q    <= frame_cnt;
    ctrl_q  <= dut.ctrl;
  end
`endif

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

`ifdef VERILATOR
    // ---- v2.5 CRV random phase (directed tests above untouched) ------
    // 110 randomized configuration transactions: random timing registers
    // (1..4, with 0-injection for the invalid-config path), random color
    // mode, random pixel-pattern seed. Valid configs run one full frame
    // checked position-by-position against the shadow model; invalid
    // configs must be rejected with irq and stay blank. Boundary values
    // (all params = 1) and back-to-back reconfigurations are included.
    begin : crv_phase
      int n_ok = 0, n_bad = 0;
      int tp [0:7];
      logic [15:0] fc0;
      bit bad, ccm;
      for (int t = 0; t < 110; t++) begin
        // ---- randomize a configuration (procedural constraints) ----
        bad = 0;
        for (int i = 0; i < 8; i++) begin
          if (t == 0)      tp[i] = 1;                    // boundary: all-min
          else if ($urandom_range(0, 9) == 0) begin
            tp[i] = 0; bad = 1;                          // error injection
          end else         tp[i] = 1 + $urandom_range(0, 3);
        end
        ccm  = $urandom_range(0, 1);
        pxor = {$urandom_range(0, 255), 16'h0} |
               {8'h0, $urandom_range(0, 255), 8'h0} |
               {16'h0, $urandom_range(0, 255)};
        cm   = ccm;
        // ---- program + (try to) enable ----
        reg_write(4'd8, 16'h0);                          // disable first
        set_cfg(tp[0], tp[1], tp[2], tp[3], tp[4], tp[5], tp[6], tp[7]);
        reg_write(4'd8, ccm ? 16'h5 : 16'h1);
        @(negedge clk);
        if (bad) begin
          // ---- invalid config: rejected + irq, stays blank ----
          n_bad++;
          if (irq !== 1'b1) begin
            errors++; $display("ERROR: CRV invalid config not rejected");
          end
          reg_check(4'd8, 16'h0, "CRV rejected enable");
          repeat (4) @(negedge clk);
          if (de !== 1'b0 || hsync !== 1'b0 || rgb !== 24'h0) begin
            errors++; $display("ERROR: CRV rejected config not blank");
          end
        end else begin
          // ---- valid config: one full frame vs the shadow model ----
          n_ok++;
          if (irq !== 1'b0) begin
            errors++; $display("ERROR: CRV valid config raised irq");
          end
          resync();
          fc0 = frame_cnt;
          check_frame(fc0 + 16'd1, "CRV.frame");
        end
      end
      pxor = 24'h0;
      $display("CRV: 110 config txns (valid=%0d invalid=%0d)", n_ok, n_bad);
    end

    // ---- coverage-closure phase (open items from W3_MIPI.md) -----------
    // (a) reg_rdata mux for addr 9/10/11 (rtl :144-146): read frame_cnt /
    //     hcnt / vcnt while disabled (hcnt/vcnt are 0, frame_cnt held).
    // (b) 16-bit timing-register sweep (0xFFFF/0x5A5A/0xA5A5/0x0000):
    //     toggles every treg / reg_wdata / reg_rdata bit both ways plus
    //     the derived h/v timing wires (hs_start/hs_end/htotal/...).
    // (c) one wide line (HTOT > 16'h8000): hcnt[15:0] walk incl. bit15.
    // (d) one tall frame (VTOT > 16'h8000, min line): vcnt[15:0] walk.
    // (e) free-running tiny frames until frame_cnt wraps 0xFFFF->0:
    //     all 16 frame_cnt bits toggle both directions.
    begin : cov_closure
      reg_write(4'd8, 16'h0);                        // ensure disabled
      repeat (3) @(negedge clk);
      reg_check(4'd9,  frame_cnt, "cc frame_cnt rb");
      reg_check(4'd10, 16'h0,     "cc hcnt rb");
      reg_check(4'd11, 16'h0,     "cc vcnt rb");
      for (int a = 0; a < 8; a++) begin
        reg_write(4'(a), 16'hFFFF);
        reg_write(4'(a), 16'h5A5A);
        reg_write(4'(a), 16'hA5A5);
        reg_write(4'(a), 16'h0000);
      end
      for (int a = 0; a < 8; a++) reg_check(4'(a), 16'h0, "cc sweep0 rb");
      for (int a = 0; a < 8; a++) begin
        reg_write(4'(a), 16'hFFFF);
        reg_check(4'(a), 16'hFFFF, "cc sweep1 rb");
      end
      // wide line: hcnt counts 0..16'h8000 then wraps (bit15 both edges)
      set_cfg(16'h1000, 16'h1000, 16'h1000, 16'h5001, 1, 1, 1, 1);
      reg_write(4'd8, 16'h1);
      repeat (16'h8020) @(negedge clk);
      reg_write(4'd8, 16'h0);
      repeat (2) @(negedge clk);
      // tall frame: vcnt counts 0..16'h8000 (4 cycles per line)
      set_cfg(1, 1, 1, 1, 16'h1000, 16'h1000, 16'h1000, 16'h5001);
      reg_write(4'd8, 16'h1);
      repeat (131200) @(negedge clk);
      reg_write(4'd8, 16'h0);
      repeat (2) @(negedge clk);
      // tiny frames: frame_cnt walks the full 16-bit range and wraps
      set_cfg(1, 1, 1, 1, 1, 1, 1, 1);               // 16 cycles / frame
      reg_write(4'd8, 16'h1);
      repeat (1050000) @(negedge clk);               // > 65536 frames
      reg_write(4'd8, 16'h0);
      repeat (2) @(negedge clk);
      check(irq === 1'b0, "cc: no irq during closure sweeps");
      $display("COV_CLOSURE: reg9-11 readback + reg sweep + wide/tall/tiny frames done (frame_cnt=%0d)", frame_cnt);
    end
`endif

    // ---- report ----
    if (errors == 0) $display("TEST PASSED: MIPI_DPI__Display_Pixel_Interface_");
    else             $display("TEST FAILED: %0d errors", errors);
`ifdef VERILATOR
    begin
      int visited;
      visited = 0;
      for (int s = 0; s < DPI_FSM_TOTAL; s++) visited += fsm_seen[s];
      $display("FSM_COV: %0d/%0d", visited, DPI_FSM_TOTAL);
      $display("SVA_CHECKS: %0d/%0d", sva_total - sva_fail, sva_total);
    end
`endif
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
`ifdef VERILATOR
  // Chunked timeout: with Verilator 5.006 a single long-pending #delay
  // event corrupts the --timing delay heap once many short-delay
  // resumptions interleave with it (processes lose wakeups and the long
  // event fires early). 1-us chunks keep all heap entries short-lived.
  initial begin
    repeat (40000) #1000;   // 40 ms in 1-us chunks (coverage-closure
                            // frame_cnt wrap phase needs ~12 ms sim time)
    $display("TEST FAILED: %0d errors", errors + 1);
    $finish;
  end
`else
  initial begin
    #2000000;
    $display("TEST FAILED: %0d errors", errors + 1);
    $finish;
  end
`endif

endmodule
