// SPDX-License-Identifier: Apache-2.0
// ============================================================================
// Self-checking testbench for ARM_Q_Channel_Low_Power_Interface_top --
// Q-Channel controller model driving qreqn + dev_event stimulus.
// Checks: reset state / request-accept into low power / request-deny while
//         active / wake via dev_event + exit / illegal qreqn sequence -> irq /
//         repeated accept cycles
// IP design implementation v1.0 -- Apache-2.0
// ============================================================================
`timescale 1ns/1ps
module ARM_Q_Channel_Low_Power_Interface_tb;

  logic clk = 0, rst_n = 0;
  logic qreqn;
  logic qacceptn;
  logic qdeny;
  logic qactive;
  logic dev_event;
  logic irq;

  int errors = 0;

  ARM_Q_Channel_Low_Power_Interface_top dut (
    .clk(clk), .rst_n(rst_n),
    .qreqn(qreqn), .qacceptn(qacceptn), .qdeny(qdeny),
    .qactive(qactive), .dev_event(dev_event), .irq(irq)
  );

  always #5 clk = ~clk;

  task automatic chk(input bit cond, input string msg);
    if (!cond) begin
      errors++;
      $display("ERROR: %s @%0t", msg, $time);
    end
  endtask

  // drive one dev_event pulse (one clk wide)
  task automatic pulse_event;
    @(negedge clk); dev_event = 1'b1;
    @(negedge clk); dev_event = 1'b0; #1;
  endtask

  // request low power and wait for the device response; returns with the
  // device in either Q_STOPPED (accept) or Q_DENIED (deny)
  task automatic q_request(input bit expect_deny);
    int t;
    @(negedge clk); qreqn = 1'b0; #1;
    t = 0;
    while (qacceptn === 1'b1 && qdeny === 1'b0 && t < 10) begin
      @(negedge clk); #1; t++;
    end
    if (expect_deny) begin
      chk(qdeny === 1'b1 && qacceptn === 1'b1, "q_request: deny expected");
    end else begin
      chk(qacceptn === 1'b0 && qdeny === 1'b0, "q_request: accept expected");
    end
  endtask

  // restore qreqn; device must return to Q_RUN (qacceptn=1, qdeny=0),
  // passing through Q_EXIT (one cycle, qacceptn still low) when stopped
  task automatic q_restore;
    int t;
    t = 0;
    @(negedge clk); qreqn = 1'b1; #1;
    while ((qacceptn !== 1'b1 || qdeny !== 1'b0) && t < 6) begin
      @(negedge clk); #1; t++;
    end
    chk(qacceptn === 1'b1 && qdeny === 1'b0, "q_restore: must reach Q_RUN");
  endtask

`ifdef VERILATOR
  // =====================================================================
  // v2.5 CRV instrumentation (Verilator only; iverilog path unchanged)
  // Tool notes (Verilator 5.006): no native FSM/SVA coverage and
  // randomize() ignores constraint blocks -> procedural constraints
  // ($urandom_range + rejection sampling), TB FSM probe, immediate
  // assertions. The timeout guard is chunked (see bottom of file).
  // =====================================================================
  localparam int QCH_FSM_TOTAL = 5;   // Q_RUN..Q_DENIED (rtl enum)
  logic [4:0] fsm_seen = '0;          // visited-state bitmap
  wire  [2:0] dut_state = dut.state;  // hierarchical FSM probe
  wire  [7:0] dut_act   = dut.act_cnt;

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

  // output-invariant assertion suite (Moore outputs checked combinationally
  // against the probed state; sampled coherently pre-NBA)
  always @(posedge clk) begin
    if (!rst_n) begin
      // A1: outputs quiescent during reset (Q_RUN encoding)
      sva_check(qacceptn === 1'b1 && qdeny === 1'b0 && qactive === 1'b0 &&
                irq === 1'b0, "A1 reset: outputs quiescent");
    end else begin
      // A2: FSM holds a legal enum encoding
      sva_check(dut_state <= 3'd4, "A2 state encoding legal");
      // A3: qdeny is exactly the Q_DENIED encoding (Moore)
      sva_check(qdeny === (dut_state == 3'd4), "A3 qdeny == Q_DENIED");
      // A4: qacceptn low exactly in Q_STOPPED/Q_EXIT (Moore)
      sva_check(qacceptn === ((dut_state != 3'd2) && (dut_state != 3'd3)),
                "A4 qacceptn Moore decode");
      // A5: irq is exactly the illegal-sequence decode
      sva_check(irq === (((dut_state == 3'd1) && qreqn) ||
                         ((dut_state == 3'd3) && !qreqn)),
                "A5 irq illegal-sequence decode");
      // A6: qactive reflects the activity counter
      sva_check(qactive === (dut_act != 8'd0), "A6 qactive == act_cnt!=0");
    end
  end
`endif

  initial begin
    qreqn = 1'b1; dev_event = 1'b0;

    // ---------------- 1. reset state ----------------
    rst_n = 0; repeat (4) @(posedge clk);
    #1;
    chk(qacceptn === 1'b1, "reset: qacceptn must be 1 (Q_RUN)");
    chk(qdeny    === 1'b0, "reset: qdeny must be 0");
    chk(qactive  === 1'b0, "reset: qactive must be 0");
    chk(irq      === 1'b0, "reset: irq must be 0");
    rst_n = 1; repeat (2) @(posedge clk);

    // ---------------- 2. request-accept into low power ------------------
    q_request(0);                       // idle device must accept
    // hold stopped for a few cycles: outputs must stay put
    repeat (3) begin
      @(negedge clk); #1;
      chk(qacceptn === 1'b0 && qdeny === 1'b0, "stopped: outputs stable");
      chk(irq === 1'b0, "stopped: no irq");
    end
    q_restore();                        // back to Q_RUN

    // ---------------- 3. request-deny while active ----------------------
    pulse_event();
    @(negedge clk); #1;
    chk(qactive === 1'b1, "deny: qactive must rise after dev_event");
    q_request(1);                       // active device must deny
    chk(irq === 1'b0, "deny: legal deny must not raise irq");
    repeat (2) begin                    // hold denied while qreqn stays low
      @(negedge clk); #1;
      chk(qdeny === 1'b1 && qacceptn === 1'b1, "denied: outputs stable");
    end
    q_restore();                        // controller gives up -> Q_RUN
    chk(qdeny === 1'b0, "deny: qdeny must clear on qreqn high");

    // ---------------- 4. wake via dev_event while stopped -------------------
    // wait for activity to expire, then enter stopped again
    repeat (20) @(negedge clk);
    #1;
    chk(qactive === 1'b0, "wake: activity must expire");
    q_request(0);                       // accept -> Q_STOPPED
    pulse_event();                      // external dev_event wakes the device
    @(negedge clk); #1;
    chk(qactive === 1'b1, "wake: qactive must rise in stopped state");
    chk(qacceptn === 1'b0, "wake: still stopped until qreqn rises");
    q_restore();                        // controller restores -> exit -> run

    // ---------------- 5. illegal sequence: qreqn 1-cycle pulse ----------
    @(negedge clk); qreqn = 1'b0; #1;   // request ...
    @(negedge clk); qreqn = 1'b1; #1;   // ... aborted before response
    chk(irq === 1'b1, "illegal: irq expected on premature qreqn rise");
    @(negedge clk); #1;
    chk(irq === 1'b0, "illegal: irq must clear next cycle");
    chk(qacceptn === 1'b1 && qdeny === 1'b0, "illegal: must return to Q_RUN");

    // ---------------- 6. repeated accept cycles -------------------------
    repeat (20) @(negedge clk);         // let wake-test activity expire
    #1;
    chk(qactive === 1'b0, "repeat: activity must have expired");
    q_request(0);                       // second accept
    q_restore();
    q_request(0);                       // third accept
    q_restore();

    // ---------------- 7. deny path exercised again ----------------------
    pulse_event();
    q_request(1);
    q_restore();

    repeat (2) @(negedge clk);
`ifdef VERILATOR
    // ---- v2.5 CRV random phase (directed tests above untouched) ------
    // 120 randomized low-power cycles mixing: idle accept (request with
    // expired activity), deny (request while active), illegal-sequence
    // injection (premature qreqn rise -> irq), and wake-while-stopped.
    begin : crv_phase
      int n_acc = 0, n_dny = 0, n_ill = 0, n_wk = 0;
      int roll;
      for (int t = 0; t < 120; t++) begin
        roll = $urandom_range(0, 19);
        if (roll < 9) begin
          // idle accept: let any activity expire, then request
          repeat (17) @(negedge clk);
          q_request(0);
          if ($urandom_range(0, 1)) begin
            // hold stopped for a random dwell
            repeat ($urandom_range(1, 4)) begin
              @(negedge clk); #1;
              chk(qacceptn === 1'b0 && qdeny === 1'b0,
                  "crv: stopped outputs stable");
            end
          end
          q_restore();
          n_acc++;
        end else if (roll < 16) begin
          // deny: random activity, then request
          repeat ($urandom_range(1, 3)) pulse_event();
          q_request(1);
          chk(irq === 1'b0, "crv: legal deny must not raise irq");
          q_restore();
          n_dny++;
        end else if (roll < 18) begin
          // error injection: premature qreqn rise -> irq, back to Q_RUN
          repeat (17) @(negedge clk);     // ensure Q_RUN reachable below
          @(negedge clk); qreqn = 1'b0; #1;
          @(negedge clk); qreqn = 1'b1; #1;
          chk(irq === 1'b1, "crv: illegal sequence must raise irq");
          @(negedge clk); #1;
          chk(irq === 1'b0, "crv: irq must clear next cycle");
          chk(qacceptn === 1'b1 && qdeny === 1'b0,
              "crv: must return to Q_RUN after illegal sequence");
          n_ill++;
        end else begin
          // wake while stopped: accept, pulse an dev_event, restore
          repeat (17) @(negedge clk);
          q_request(0);
          pulse_event();
          @(negedge clk); #1;
          chk(qactive === 1'b1, "crv: wake must raise qactive");
          chk(qacceptn === 1'b0, "crv: still stopped until qreqn rises");
          q_restore();
          n_wk++;
        end
      end
      // ---- targeted toggle closure: hold dev_event high so the
      // statistics counter increments every clock through 8192+ values
      // (closes evt_count[12:0]; higher bits need >= 2^13 events, i.e.
      // impractical simulation length, and are waived)
      @(negedge clk); dev_event = 1'b1;
      repeat (8200) @(negedge clk);
      @(negedge clk); dev_event = 1'b0;
      q_restore();   // leave the channel in Q_RUN
      $display("CRV: 120 cycles (accept=%0d deny=%0d illegal=%0d wake=%0d)",
               n_acc, n_dny, n_ill, n_wk);
    end
`endif
    if (errors == 0) $display("TEST PASSED: ARM_Q_Channel_Low_Power_Interface");
    else             $display("TEST FAILED: %0d errors", errors);
`ifdef VERILATOR
    begin
      int visited;
      visited = 0;
      for (int s = 0; s < QCH_FSM_TOTAL; s++) visited += fsm_seen[s];
      $display("FSM_COV: %0d/%0d", visited, QCH_FSM_TOTAL);
      $display("SVA_CHECKS: %0d/%0d", sva_total - sva_fail, sva_total);
    end
`endif
    $finish;
  end

  // timeout guard
`ifdef VERILATOR
  // Chunked timeout: with Verilator 5.006 a single long-pending #delay
  // event corrupts the --timing delay heap once many short-delay
  // resumptions interleave with it (processes lose wakeups and the long
  // event fires early). 1-us chunks keep all heap entries short-lived
  // (verified with a minimal repro).
  initial begin
    repeat (2000) #1000;   // 2 ms in 1-us chunks
    errors++;
    $display("ERROR: TIMEOUT guard fired");
    $display("TEST FAILED: %0d errors", errors);
    $finish;
  end
`else
  initial begin
    #50000;
    errors++;
    $display("ERROR: TIMEOUT guard fired");
    $display("TEST FAILED: %0d errors", errors);
    $finish;
  end
`endif

endmodule
