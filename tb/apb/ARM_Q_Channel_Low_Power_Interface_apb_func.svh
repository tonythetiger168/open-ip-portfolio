// SPDX-License-Identifier: Apache-2.0
// ARM_Q_Channel_Low_Power_Interface-specific part of
// tb/ARM_Q_Channel_Low_Power_Interface_apb_tb.sv. The TB is the Q-Channel
// controller on qreqn; activity comes from EVENT writes.
// Covered through the registers: STATUS against the pins in every state
// (RUN, STOPPED, EXIT, DENIED), a request accepted and the exit, a request
// denied while active, activity expiring after ACT_CYCLES, both illegal
// controller sequences (ILLEGAL), every interrupt bit masked, raising irq
// and cleared.
localparam logic [31:0] S_ACCEPTN = 32'h1, S_DENY = 32'h2, S_ACTIVE = 32'h4;
initial qreqn = 1;

// STATUS read, checked against the pins and the expected value
task automatic status(input logic [31:0] e);
  rd(A_STATUS);
  if (rdv !== {29'd0, qactive, qdeny, qacceptn}) fail($sformatf("STATUS %h, pins %b%b%b", rdv, qactive, qdeny, qacceptn));
  if (rdv !== e) fail($sformatf("STATUS %h, expected %h", rdv, e));
endtask
task automatic irq_expect(input int b);
  cycles(2);
  rd(A_IRQ_STATUS);
  if (!rdv[b]) fail($sformatf("IRQ bit %0d not set (%h)", b, rdv));
  if (!irq) fail("irq low with an enabled bit set");
  wr(A_IRQ_STATUS, 32'(1) << b);
endtask
task automatic no_irq(input int b);
  rd(A_IRQ_STATUS);
  if (rdv[b]) fail($sformatf("IRQ bit %0d set unexpectedly (%h)", b, rdv));
endtask
// accepted request and exit
task automatic stop_and_exit;
  @(negedge PCLK) qreqn = 0;
  cycles(3);
  if (qacceptn !== 0 || qdeny !== 0) fail("request not accepted");
  status(0);
  @(negedge PCLK) qreqn = 1;
  cycles(1);                              // EXIT: still accepted
  if (qacceptn !== 0) fail("qacceptn rose before the exit completed");
  cycles(2);
  if (qacceptn !== 1) fail("exit did not complete");
  status(S_ACCEPTN);
endtask
task automatic wait_idle;
  int k;
  k = 0;
  while (qactive && k < 40) begin cycles(1); k++; end
  if (qactive) fail("qactive stuck high");
endtask

task automatic ip_func;
  int k;
  wr(A_IRQ_ENABLE, IRQ_ALL);
  status(S_ACCEPTN);
  stop_and_exit();
  no_irq(IRQ_ILLEGAL); no_irq(IRQ_DENIED);
  // activity: qactive for ACT_CYCLES clocks after the last event
  wr(A_EVENT, 1);
  cycles(2);
  if (!qactive) fail("EVENT did not raise qactive");
  status(S_ACCEPTN | S_ACTIVE);
  wait_idle();
  wr(A_EVENT, 0);                         // a write of 0 is no event
  cycles(3);
  if (qactive) fail("EVENT written 0 raised qactive");
  rd_exp(A_FLAGS, 0);
  wr(A_EVENT, 1);
  @(negedge PCLK);
  if (qactive) fail("qactive raised before the event reached the core");
  @(negedge PCLK);
  if (!qactive) fail("qactive not raised in the clock after the event");
  k = 0;
  while (qactive && k < 40) begin @(negedge PCLK); k++; end
  if (k != 16) fail($sformatf("qactive lasted %0d clocks", k));
  status(S_ACCEPTN);
  // denied while active
  wr(A_EVENT, 1);
  @(negedge PCLK) qreqn = 0;
  cycles(3);
  if (qdeny !== 1 || qacceptn !== 1) fail("request not denied");
  status(S_ACCEPTN | S_DENY | S_ACTIVE);
  irq_expect(IRQ_DENIED);
  wait_idle();
  status(S_ACCEPTN | S_DENY);             // stays denied until qreqn rises
  wr(A_IRQ_STATUS, IRQ_ALL);
  @(negedge PCLK) qreqn = 1;
  cycles(2);
  status(S_ACCEPTN);
  wr(A_IRQ_STATUS, IRQ_ALL);
  no_irq(IRQ_DENIED);
  no_irq(IRQ_ILLEGAL);
  // illegal: qreqn rises before the device answers
  @(negedge PCLK) qreqn = 0;
  @(negedge PCLK) qreqn = 1;
  irq_expect(IRQ_ILLEGAL);
  status(S_ACCEPTN);
  // illegal: qreqn falls during the exit, back to STOPPED
  @(negedge PCLK) qreqn = 0;
  cycles(3);
  @(negedge PCLK) qreqn = 1;
  @(negedge PCLK) qreqn = 0;
  repeat (3) @(negedge PCLK) if (qacceptn !== 0) fail("left STOPPED after an aborted exit");
  irq_expect(IRQ_ILLEGAL);
  status(0);
  no_irq(IRQ_DENIED);
  // event while stopped: no effect on the handshake
  wr(A_EVENT, 1);
  cycles(2);
  status(S_ACTIVE);
  wait_idle();
  @(negedge PCLK) qreqn = 1;
  cycles(3);
  status(S_ACCEPTN);
  for (int i = 0; i < 3; i++) stop_and_exit();
  // masked: each event again, left pending into reset
  wr(A_IRQ_STATUS, IRQ_ALL);
  wr(A_IRQ_ENABLE, 0);
  @(negedge PCLK) qreqn = 0;
  @(negedge PCLK) qreqn = 1;
  wr(A_EVENT, 1);
  @(negedge PCLK) qreqn = 0;
  cycles(3);
  @(negedge PCLK) qreqn = 1;
  cycles(3);
  if (irq) fail("irq with every interrupt masked");
  rd_exp(A_IRQ_STATUS, IRQ_ALL);
endtask
