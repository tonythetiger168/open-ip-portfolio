// SPDX-License-Identifier: Apache-2.0
// ============================================================================
// Self-checking testbench for I2S_Audio_top -- SystemVerilog
// Loopback (sd_out -> sd_in) across 3 formats x 3 depths in master mode,
// boundary samples, wclk phase monitor, slave-mode loopback with TB-generated
// bclk/wclk, and a dropped-bclk injection that must raise irq (frame-sync
// error) followed by automatic resynchronization.
// ============================================================================
`timescale 1ns/1ps
module I2S_Audio_tb;

  logic        clk = 1'b0, rst_n = 1'b0;
  logic        cfg_master = 1'b1;
  logic [1:0]  cfg_fmt = 2'd0, cfg_depth = 2'd2;
  logic        bclk_out, wclk_out;
  logic        bclk_in, wclk_in;
  logic [31:0] tx_l = 32'h0, tx_r = 32'h0;
  logic        tx_valid = 1'b0, tx_ready;
  logic [31:0] rx_l, rx_r;
  logic        rx_valid;
  logic        sd_out, sd_in;
  logic        irq;
  int          errors = 0;

  I2S_Audio_top #(.MCLK_DIV(4)) dut (
    .clk(clk), .rst_n(rst_n),
    .cfg_master(cfg_master), .cfg_fmt(cfg_fmt), .cfg_depth(cfg_depth),
    .bclk_out(bclk_out), .wclk_out(wclk_out),
    .bclk_in(bclk_in), .wclk_in(wclk_in),
    .tx_l(tx_l), .tx_r(tx_r), .tx_valid(tx_valid), .tx_ready(tx_ready),
    .rx_l(rx_l), .rx_r(rx_r), .rx_valid(rx_valid),
    .sd_out(sd_out), .sd_in(sd_in), .irq(irq)
  );

  always #5 clk = ~clk;

  assign sd_in = sd_out;          // serial loopback

`ifdef VERILATOR
  // =====================================================================
  // v2.5 CRV instrumentation (Verilator only; iverilog path unchanged)
  // =====================================================================
  // FSM: 4 operating phases {master/slave, left/right slot}
  localparam int I2SA_FSM_TOTAL = 4;
  logic [3:0] fsm_seen = '0;
  always @(posedge clk) fsm_seen[{cfg_master, dut.frame_pos[5]}] <= 1'b1;

  int sva_total = 0, sva_fail = 0;
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

  // output-invariant assertion suite (sampled at posedge, pre-NBA coherent)
  int  rst_cyc = 0;
  logic irq_q = 1'b0;
  always @(posedge clk) begin
    if (!rst_n) begin
      // A1: registers cleared in reset
      if (rst_cyc > 0)
        sva_check((dut.frame_pos === 6'd0) && (dut.tx_word_l === 32'h0) &&
                  (dut.rx_valid === 1'b0) && (dut.irq === 1'b0),
                  "A1 reset: regs cleared");
      rst_cyc++;
    end else begin
      // A2: tx_ready is exactly the frame_pos==63 load window
      sva_check(tx_ready === (dut.frame_pos === 6'd63), "A2 tx_ready window");
      // A3: wclk_out is frame_pos[5] in master mode, 0 in slave mode
      sva_check(wclk_out === (cfg_master ? dut.frame_pos[5] : 1'b0),
                "A3 wclk_out source");
      // A4: irq is a single-cycle pulse
      if (irq_q) sva_check(irq === 1'b0, "A4 irq pulse width");
      // A5: master divider bounded by MCLK_DIV
      sva_check(dut.div_cnt < 4, "A5 div_cnt < MCLK_DIV");
    end
    irq_q <= irq;
  end
`endif

  // ------------------------- helpers ------------------------------
  task automatic chk(input bit cond, input string msg);
    if (!cond) begin
      errors++;
      $display("ERROR: %s (t=%0t)", msg, $time);
    end
  endtask

  function automatic logic [31:0] dmask(input logic [1:0] d);
    begin
      case (d)
        2'd0:    dmask = 32'h0000_FFFF;
        2'd1:    dmask = 32'h00FF_FFFF;
        default: dmask = 32'hFFFF_FFFF;
      endcase
    end
  endfunction

  // drive one stereo frame into the TX sample interface
  task automatic send_frame(input [31:0] l, input [31:0] r);
    int n;
    begin
      n = 0;
      @(negedge clk);
      while (!tx_ready && n <= 5000) begin
        @(negedge clk); n++;
      end
      chk(n <= 5000, "send_frame: tx_ready timeout");
      tx_l = l; tx_r = r; tx_valid = 1'b1;
      @(negedge clk);
      while (tx_ready) @(negedge clk);   // wait until loaded (fp leaves 63)
      tx_valid = 1'b0;
    end
  endtask

  // wait for one received frame and compare against expectations
  task automatic recv_check(input [31:0] exp_l, input [31:0] exp_r,
                            input [1:0] depth);
    int n;
    bit done;
    logic [31:0] m;
    begin
      n = 0; done = 1'b0; m = dmask(depth);
      while (!done) begin
        @(negedge clk);
        if (rx_valid) begin
          chk((rx_l & m) === (exp_l & m),
              $sformatf("rx_l got=%08x exp=%08x (fmt=%0d depth=%0d)",
                        rx_l & m, exp_l & m, cfg_fmt, depth));
          chk((rx_r & m) === (exp_r & m),
              $sformatf("rx_r got=%08x exp=%08x (fmt=%0d depth=%0d)",
                        rx_r & m, exp_r & m, cfg_fmt, depth));
          done = 1'b1;
        end else begin
          n++;
          if (n > 5000) begin
            chk(0, "recv_check: rx_valid timeout");
            done = 1'b1;
          end
        end
      end
    end
  endtask

  // one full loopback frame: the RX path has one frame of pipeline latency
  // (a frame is received while the next one is being loaded), so the same
  // sample pair is sent twice; the rx_valid observed after the second load
  // corresponds to the first transmission, which carries identical data.
  task automatic loopback(input [31:0] l, input [31:0] r, input [1:0] depth);
    begin
      send_frame(l, r);
      send_frame(l, r);
      recv_check(l, r, depth);
    end
  endtask

  // wait for n complete frame periods (64 bclk = 256 clk each in /4 mode)
  task automatic wait_frames(input int n);
    repeat (n * 300) @(negedge clk);
  endtask

  // ------------------------- wclk phase monitor (master) ----------
  // left channel must have wclk = 0, right must have wclk = 1
  bit mon_en = 1'b0;
  int mon_edges = 0;
  always @(negedge bclk_out) begin
    if (mon_en) begin
      mon_edges++;
      if (wclk_out !== dut.frame_pos[5]) begin
        errors++;
        $display("ERROR: wclk phase mismatch wclk=%b fp=%0d (t=%0t)",
                 wclk_out, dut.frame_pos, $time);
      end
    end
  end

  // ------------------------- irq monitor --------------------------
  int irq_cnt = 0;
  always @(posedge irq) irq_cnt++;

  // ------------------------- slave clock generator -----------------
  // bclk = clk/4 aligned to negedge clk; wclk from the TB frame model.
  bit        slave_en = 1'b0;
  bit        drop_pulse = 1'b0;   // inject: drop the next bclk rising pulse
  logic [1:0] sdiv = 2'd0;
  logic [5:0] sft  = 6'd0;        // TB frame-position model (0..63)
  logic [5:0] sft_next;
  logic      bclk_r = 1'b0, wclk_r = 1'b0;

  assign bclk_in = bclk_r;
  assign wclk_in = wclk_r;

  always @(negedge clk) begin
    if (slave_en) begin
      sdiv <= sdiv + 2'd1;
      if (sdiv == 2'd1) begin
        // bclk rising edge happens now (unless the pulse is dropped)
        if (!drop_pulse) bclk_r <= 1'b1;
        sft_next = (sft == 6'd63) ? 6'd0 : sft + 6'd1;
        sft    <= sft_next;
        wclk_r <= sft_next[5];      // 0 = left, 1 = right
      end
      if (sdiv == 2'd3) bclk_r <= 1'b0;
    end
  end

  // ------------------------- stimulus ------------------------------
  int f, d;
  logic [31:0] m;
  int irq_before;

  initial begin
    // ---------------- reset ----------------
    repeat (5) @(negedge clk);
    rst_n = 1'b1;
    repeat (2) @(negedge clk);

    // ---- CHECK 1: reset state ----
    chk(bclk_out === 1'b0, "bclk_out not 0 after reset");
    chk(wclk_out === 1'b0, "wclk_out not 0 after reset (left channel)");
    chk(sd_out   === 1'b0, "sd_out not 0 after reset");
    chk(rx_valid === 1'b0, "rx_valid not 0 after reset");
    chk(tx_ready === 1'b0, "tx_ready not 0 after reset");
    chk(irq      === 1'b0, "irq not 0 after reset");
    $display("INFO: check 1 (reset state) done");

    // ---- CHECK 2: master mode, 3 formats x 3 depths loopback ----
    cfg_master = 1'b1;
    mon_en = 1'b1;
    for (f = 0; f < 3; f++) begin
      for (d = 0; d < 3; d++) begin
        cfg_fmt   = f[1:0];
        cfg_depth = d[1:0];
        m = dmask(d[1:0]);
        wait_frames(2);                      // let cfg change resync settle
        // boundary samples: all-zeros / all-ones / alternating
        loopback(32'h0000_0000, m,            d[1:0]);
        loopback(m,           32'h0000_0000,  d[1:0]);
        loopback(32'hAAAA_AAAA & m, 32'h5555_5555 & m, d[1:0]);
        $display("INFO: master loopback fmt=%0d depth=%0d done", f, d);
      end
    end
    chk(mon_edges > 100, "wclk phase monitor did not run");
    $display("INFO: check 2 (master 9 combo loopback) done, %0d bclk edges monitored", mon_edges);

    // ---- CHECK 3: slave mode loopback (TB generates bclk/wclk) ----
    mon_en = 1'b0;
    cfg_fmt = 2'd0; cfg_depth = 2'd1;
    @(negedge clk);
    cfg_master = 1'b0;                       // switch to slave
    sdiv = 2'd0; sft = 6'd0; bclk_r = 1'b0; wclk_r = 1'b0;
    slave_en = 1'b1;
    wait_frames(3);                          // let DUT sync to external wclk
    // I2S 24-bit
    loopback(32'h00AB_CDEF, 32'h0000_0001, 2'd1);
    // left-justified 24-bit
    cfg_fmt = 2'd1; wait_frames(2);
    loopback(32'h00FF_FFFF, 32'h0012_3456, 2'd1);
    // right-justified 16-bit
    cfg_fmt = 2'd2; cfg_depth = 2'd0; wait_frames(2);
    loopback(32'h0000_FFFF, 32'h0000_AAAA, 2'd0);
    $display("INFO: check 3 (slave mode loopback) done");

    // ---- CHECK 4: error injection -- dropped bclk pulse ----------
    irq_before = irq_cnt;
    @(negedge clk);
    drop_pulse = 1'b1;
    @(negedge clk); @(negedge clk); @(negedge clk); @(negedge clk);
    @(negedge clk);                          // span one bclk period
    drop_pulse = 1'b0;
    wait_frames(2);
    chk(irq_cnt > irq_before, "no irq on dropped bclk pulse (frame sync loss)");
    // DUT must have resynchronized: loopback works again
    loopback(32'h0000_5A5A, 32'h0000_C3C3, 2'd0);
    $display("INFO: check 4 (dropped bclk injection + resync) done");

`ifdef VERILATOR
    // ---- v2.5 CRV random phase (directed tests above untouched) ----
    // 120 randomized loopback transactions: random format (I2S/LJ/RJ),
    // random depth (16/24/32, encodings 2 and 3 both 32-bit), random
    // sample data with all-0/all-1 corners. ~25% slave-mode txns; error
    // classes: dropped bclk pulse (irq + resync) and TX underrun (zeros).
    begin : crv_phase
      logic [31:0] dl, dr;
      logic [1:0]  cf, cd;
      int n_txn = 0, n_slave = 0, n_drop = 0, n_und = 0;
      for (int t = 0; t < 120; t++) begin
        cf = $urandom_range(0, 2);
        cd = $urandom_range(0, 3);
        dl = $urandom(); dr = $urandom();
        if ($urandom_range(0, 9) == 0) dl = 32'h0;
        if ($urandom_range(0, 9) == 0) dl = 32'hFFFF_FFFF;
        if ($urandom_range(0, 9) == 0) dr = 32'h0;
        if ($urandom_range(0, 9) == 0) dr = 32'hFFFF_FFFF;
        m = dmask(cd);
        @(negedge clk);
        cfg_fmt = cf; cfg_depth = cd;
        if ($urandom_range(0, 3) == 0) begin
          // ---- slave-mode transaction (TB clocks) ----
          n_slave++;
          cfg_master = 1'b0;
          sdiv = 2'd0; sft = 6'd0; bclk_r = 1'b0; wclk_r = 1'b0;
          slave_en = 1'b1;
          wait_frames(3);
          loopback(dl & m, dr & m, cd);
          // error injection 1: dropped bclk pulse -> irq + resync
          if ($urandom_range(0, 5) == 0) begin
            n_drop++;
            irq_before = irq_cnt;
            @(negedge clk);
            drop_pulse = 1'b1;
            repeat (5) @(negedge clk);
            drop_pulse = 1'b0;
            wait_frames(2);
            chk(irq_cnt > irq_before, "CRV: no irq on dropped bclk");
            loopback(dl & m, dr & m, cd);   // must resync
          end
        end else begin
          // ---- master-mode transaction ----
          cfg_master = 1'b1;
          slave_en = 1'b0;
          wait_frames(2);
          if ($urandom_range(0, 9) == 0) begin
            // error injection 2: TX underrun -> wire carries zeros
            n_und++;
            wait_frames(2);
            recv_check(32'h0, 32'h0, cd);
          end else begin
            loopback(dl & m, dr & m, cd);
          end
        end
        n_txn++;
      end
      // return to master mode for a clean end state
      @(negedge clk);
      cfg_master = 1'b1; slave_en = 1'b0;
      cfg_fmt = 2'd0; cfg_depth = 2'd2;
      wait_frames(2);
      $display("CRV: %0d txns (%0d slave, %0d bclk-drop, %0d underrun)",
               n_txn, n_slave, n_drop, n_und);
    end
`endif

    // ---------------- result ----------------
    if (errors == 0) $display("TEST PASSED: I2S_Audio");
    else             $display("TEST FAILED: %0d errors", errors);
`ifdef VERILATOR
    begin
      int visited;
      visited = 0;
      for (int s = 0; s < I2SA_FSM_TOTAL; s++) visited += fsm_seen[s];
      $display("FSM_COV: %0d/%0d", visited, I2SA_FSM_TOTAL);
      $display("SVA_CHECKS: %0d/%0d", sva_total - sva_fail, sva_total);
    end
`endif
    $finish;
  end

  // ------------------------- timeout guard -------------------------
`ifdef VERILATOR
  // Chunked into 1-us delays: with Verilator 5.006 a single long-pending
  // #delay event corrupts the --timing delay heap once many short-delay
  // resumptions interleave.
  initial begin
    repeat (40000) #1000;   // 40 ms in 1-us chunks
    $display("TIMEOUT");
    $display("TEST FAILED: %0d errors", errors + 1);
    $finish;
  end
`else
  initial begin
    #20_000_000;
    $display("TIMEOUT");
    $display("TEST FAILED: %0d errors", errors + 1);
    $finish;
  end
`endif

endmodule
