// SPDX-License-Identifier: Apache-2.0
// HBM3 TB: ch0 read/write + ch1 isolation + channel isolation.
`timescale 1ns/1ps
module HBM3_tb;
  logic clk = 0, rst_n = 0;
  logic hvalid = 0, hready;
  logic [2:0] hcmd = 0;
  logic [31:0] haddr = 0;
  logic [15:0] hwdata = 0, hrdata;
  logic hdone;
  logic ck_t, ck_c;
  logic [16:0] addr; logic ras_n, cas_n, we_n;
  tri [127:0] dq; tri [1:0] dqs; logic cke;
  logic trace_valid; logic [2:0] trace_cmd; logic [31:0] trace_addr;
  int errors = 0;

  HBM3_top dut (.*);
  always #5 clk = ~clk;

`ifdef VERILATOR
  // =====================================================================
  // v2.5 CRV instrumentation (Verilator only; iverilog path unchanged)
  // Tool notes (Verilator 5.006): no native FSM/SVA coverage and
  // randomize() ignores constraint blocks -> procedural constraints
  // ($urandom_range + rejection sampling), TB FSM probe, immediate
  // assertions. The timeout guard is chunked (see bottom of file).
  //
  // FSM probe path: HBM3_top is a MEMCH wrapper (no state register of
  // its own); the command FSM lives in MEMCORE_top.dstate (7 states,
  // D_IDLE..D_PRE), reached through the MEMCH channel-0 generate scope:
  //   dut.dstate
  // Output-mux note: hready/hdone/hrdata/trace_* are muxed by the channel
  // select haddr[8 +: CHW], so state-related assertions are only
  // evaluated while channel 0 is selected (crv_sel0).
  // =====================================================================
  localparam int CRV_NCH = 8;         // MEMCH NCH for this wrapper
  localparam int CRV_CHW = (CRV_NCH <= 2) ? 1 : $clog2(CRV_NCH);
  localparam int CRV_FSM_TOTAL = 7;   // D_IDLE..D_PRE (rtl/MEMCORE_top.sv)
  logic [6:0] fsm_seen = '0;          // visited-state bitmap
  wire  [2:0] dut_state = dut.dstate;
  wire        crv_sel0  = (haddr[8 +: CRV_CHW] == '0);  // ch0 selected

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

  // FSM coverage: sample DUT state register every clock
  always @(posedge clk) fsm_seen[dut_state] <= 1'b1;

  // output-invariant assertion suite (sampled coherently pre-NBA)
  logic p_hdone = 0;
  logic rst_seen = 0;   // first reset clock executes the async-reset branch
  always @(posedge clk) begin
    if (!rst_n) begin
      // A1: pins quiescent during reset (checked from the 2nd reset clock
      // on: the pre-NBA sample then reflects the executed reset branch)
      if (rst_seen)
        sva_check(cke === 1'b0 && {ras_n, cas_n, we_n} === 3'b111 &&
                  trace_valid === 1'b0, "A1 reset: pins idle");
      rst_seen <= 1'b1;
    end else begin
      // A2: state register holds a legal enum encoding
      sva_check(dut_state <= 3'd6, "A2 state encoding legal");
      if (crv_sel0) begin
        // A3: hready is exactly the D_IDLE decode
        sva_check(hready === (dut_state == 3'd0), "A3 hready == IDLE");
        // A4: hdone only in the CAS-latency state
        sva_check(!hdone || (dut_state == 3'd4), "A4 hdone only in D_CAS");
        // A5: trace_valid only in ACT/RD/WR states
        sva_check(!trace_valid || (dut_state == 3'd1) || (dut_state == 3'd3) ||
                  (dut_state == 3'd5), "A5 trace_valid only in ACT/RD/WR");
        // A6: trace command code matches the state
        sva_check(!trace_valid ||
                  (trace_cmd === ((dut_state == 3'd1) ? 3'd1 :
                                  (dut_state == 3'd3) ? 3'd2 : 3'd3)),
                  "A6 trace_cmd matches state");
        // A8: hdone is a single-cycle pulse
        sva_check(!(p_hdone && hdone), "A8 hdone single-cycle pulse");
      end
      // A7: cke tracks rst_n out of reset
      sva_check(cke === 1'b1, "A7 cke high out of reset");
    end
    p_hdone <= hdone;
  end
`endif

  task automatic cmd(input logic [2:0] c, input logic [31:0] a, input logic [15:0] d);
    begin
      wait (hready === 1'b1);
      @(negedge clk);
      hcmd <= c; haddr <= a; hwdata <= d; hvalid <= 1'b1;
      @(negedge clk);
      hvalid <= 1'b0;
    end
  endtask

  logic [15:0] got;
  initial begin
    rst_n = 0; repeat(5) @(posedge clk);
    rst_n = 1; repeat(5) @(posedge clk);
    cmd(3'd1, 32'h000, 16'h0);
    repeat(3) @(posedge clk);
    for (int i = 0; i < 4; i++) cmd(3'd3, i, 16'h1999 + i * 8'h11);
    for (int i = 0; i < 4; i++) begin
      cmd(3'd2, i, 16'h0);
      wait (hdone === 1'b1); @(posedge clk); #1;
      got = hrdata;
      if (got !== 16'h1999 + i * 8'h11) begin
        errors++; $display("ERROR: HBM3 ch0[%0d] got=%h", i, got);
      end
    end
    // channel 1 (haddr[8]=1): distinct data, same column -> isolation check
    cmd(3'd1, 32'h100, 16'h0);
    repeat(3) @(posedge clk);
    cmd(3'd3, 32'h100, 16'h9901);
    cmd(3'd1, 32'h100, 16'h0);
    repeat(3) @(posedge clk);
    cmd(3'd2, 32'h100, 16'h0);
    wait (hdone === 1'b1); @(posedge clk); #1;
    got = hrdata;
    if (got !== 16'h9901) begin
      errors++; $display("ERROR: HBM3 ch1[0] got=%h exp=199901", got);
    end
    // channel 0 data must be untouched
    cmd(3'd1, 32'h000, 16'h0);
    repeat(3) @(posedge clk);
    cmd(3'd2, 32'h000, 16'h0);
    wait (hdone === 1'b1); @(posedge clk); #1;
    got = hrdata;
    if (got !== 16'h1999) begin
      errors++; $display("ERROR: HBM3 ch0[0] after ch1 traffic got=%h exp=1999", got);
    end
`ifdef VERILATOR
    // ---- v2.5 CRV random phase (directed tests above untouched) ----
    // 160 randomized transactions over a per-channel scoreboard model:
    // ~40% WR (model update), ~30% RD (readback compare, only against
    // locations the CRV phase itself has written: the directed phase
    // leaves live data in the array), ~15% ACT (random row, toggles
    // haddr row bits), ~10% PRE, ~5% timing-violation injection (early
    // RD during tRCD must be ignored: no hdone, no trace).
    begin : crv_phase
      logic [15:0] model [0:CRV_NCH-1][0:255];
      logic [255:0] written [0:CRV_NCH-1];
      logic [15:0] rcv, d;
      logic [31:0] a;
      int n_wr = 0, n_rd = 0, n_act = 0, n_pre = 0, n_inj = 0;
      int roll, ch, col;
      for (int c = 0; c < CRV_NCH; c++) written[c] = '0;
      for (int t = 0; t < 160; t++) begin
        roll = $urandom_range(0, 19);
        // fully random command address: [31:18]=row (used by ACT),
        // [8 +: CHW]=channel select, [7:0]=column; the unused middle
        // bits are don't-care for the DUT and randomized for toggle
        // coverage of haddr/trace_addr
        a    = $urandom;
        // rejection sampling: over-weight boundary columns 0 and 255
        if ($urandom_range(0, 9) < 2) a[7:0] = ($urandom_range(0, 1) == 0) ? 8'h00 : 8'hFF;
        // channel select must stay in range: for NCH=1 the MEMCH output
        // muxes still index their per-channel arrays with haddr[8], so
        // keep sel=0 (driving it high is an illegal, out-of-model access)
        ch   = (a >> 8) & (CRV_NCH - 1);
        a[8 +: CRV_CHW] = ch[CRV_CHW-1:0];
        col  = a[7:0];
        if (roll < 8) begin
          // random write + scoreboard update
          n_wr++;
          d = $urandom_range(0, 65535);
          cmd(3'd3, a, d);
          model[ch][col] = d;
          written[ch][col] = 1'b1;
        end else if (roll < 14) begin
          // random read + readback compare against the model (only for
          // locations written by this phase)
          n_rd++;
          cmd(3'd2, a, 16'h0);
          wait (hdone === 1'b1); @(posedge clk); #1;
          rcv = hrdata;
          if (written[ch][col] && rcv !== model[ch][col]) begin
            errors++;
            $display("ERROR: CRV RD ch%0d[%0d] got=%h exp=%h",
                     ch, col, rcv, model[ch][col]);
          end
        end else if (roll < 17) begin
          // random activate (row = a[31:18])
          n_act++;
          cmd(3'd1, a, 16'h0);
        end else if (roll < 19) begin
          // random precharge
          n_pre++;
          cmd(3'd4, a, 16'h0);
        end else begin
          // timing-violation injection on ch0: early RD during tRCD busy
          // must be ignored (no hdone, no trace, model unaffected)
          n_inj++;
          cmd(3'd1, 32'h0004_0000, 16'h0);        // ch0 ACT row 1
          @(negedge clk);
          hcmd <= 3'd2; haddr <= 32'(col); hwdata <= 16'h0; hvalid <= 1'b1;
          @(negedge clk);
          hvalid <= 1'b0;
          #1;
          if (hdone !== 1'b0)
            begin errors++; $display("ERROR: CRV hdone from injected early RD"); end
          if (trace_valid !== 1'b0)
            begin errors++; $display("ERROR: CRV trace from injected early RD"); end
          while (hready !== 1'b1) begin
            @(posedge clk); #1;
            if (hdone === 1'b1)
              begin errors++; $display("ERROR: CRV spurious hdone after injection"); end
          end
        end
      end
      // deterministic data toggle closure: per channel, write+readback
      // all-ones then all-zeros so every hrdata/dq bit toggles both
      // directions (random stimulus leaves single-bit misses otherwise)
      for (int c = 0; c < CRV_NCH; c++) begin
        for (int i = 0; i < 2; i++) begin
          d = (i == 0) ? 16'hFFFF : 16'h0000;
          a = '0; a[8 +: CRV_CHW] = c[CRV_CHW-1:0]; a[7:0] = 8'h5A;
          cmd(3'd3, a, d);
          model[c][8'h5A] = d;
          written[c][8'h5A] = 1'b1;
          cmd(3'd2, a, 16'h0);
          wait (hdone === 1'b1); @(posedge clk); #1;
          rcv = hrdata;
          if (rcv !== d) begin
            errors++;
            $display("ERROR: CRV toggle RD ch%0d got=%h exp=%h", c, rcv, d);
          end
        end
      end
      // deterministic FSM closure on channel 0: the epilogue above hits
      // D_WR/D_RD/D_CAS, the injection hits D_ACT/D_RCD; add a ch0 PRE
      // so all 7 MEMCORE states are visited on the probed channel
      cmd(3'd4, 32'h0, 16'h0);
      // settle: let the final PRE state be sampled before FSM_COV print
      repeat(3) @(posedge clk);
      $display("CRV: 160 txns (wr=%0d rd=%0d act=%0d pre=%0d inj=%0d) + %0d toggle txns",
               n_wr, n_rd, n_act, n_pre, n_inj, 4 * CRV_NCH + 1);
    end
`endif

    if (errors == 0) $display("TEST PASSED: HBM3");
    else             $display("TEST FAILED: %0d errors", errors);
`ifdef VERILATOR
    begin
      int visited;
      visited = 0;
      for (int s = 0; s < CRV_FSM_TOTAL; s++) visited += fsm_seen[s];
      $display("FSM_COV: %0d/%0d", visited, CRV_FSM_TOTAL);
      $display("SVA_CHECKS: %0d/%0d", sva_total - sva_fail, sva_total);
    end
`endif
    $finish;
  end

`ifdef VERILATOR
  // Random phase adds bus traffic: extend the guard. The timeout is
  // chunked into 1-us delays: with Verilator 5.006 a single long-pending
  // #delay event corrupts the --timing delay heap once many short-delay
  // resumptions interleave with it (see docs/COVERAGE.md note 1).
  initial begin
    repeat (5000) #1000;    // 5 ms in 1-us chunks
    $display("TIMEOUT"); $finish;
  end
`else
  initial begin
    #500_000; $display("TIMEOUT"); $finish;
  end
`endif
endmodule
