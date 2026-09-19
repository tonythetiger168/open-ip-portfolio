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
    if (errors == 0) $display("TEST PASSED: ARM_Q_Channel_Low_Power_Interface");
    else             $display("TEST FAILED: %0d errors", errors);
    $finish;
  end

  // timeout guard
  initial begin
    #50000;
    errors++;
    $display("ERROR: TIMEOUT guard fired");
    $display("TEST FAILED: %0d errors", errors);
    $finish;
  end

endmodule
