// SPDX-License-Identifier: Apache-2.0
// ============================================================================
// ARM Q-Channel Low Power Interface -- device-side controller
// Full qreqn/qacceptn/qdeny/qactive handshake FSM (Q_RUN, Q_REQUEST,
// Q_STOPPED, Q_EXIT, Q_DENIED), qactive driven by internal activity
// detection (dev_event counter), deny path, illegal-sequence detection -> irq
// IP design implementation v1.0 -- Apache-2.0
// ============================================================================
module ARM_Q_Channel_Low_Power_Interface_top #(
  parameter int DW = 32,            // width of the dev_event statistics counter
  parameter int AW = 32,            // kept for framework interface conformity
  parameter int ACT_CYCLES = 16     // activity persistence after an dev_event
)(
  input  logic clk,
  input  logic rst_n,
  // Q-Channel (device side)
  input  logic qreqn,      // controller request: low = enter low-power state
  output logic qacceptn,   // device accept:    low  = low-power state entered
  output logic qdeny,      // device deny:      high = request refused
  output logic qactive,    // device activity indication
  // activity stimulus (e.g. interrupt/DMA dev_event into the device)
  input  logic dev_event,
  // protocol violation dev_event (illegal qreqn sequence)
  output logic irq
);

  typedef enum logic [2:0] {
    Q_RUN,      // operational:               qreqn=1 qacceptn=1 qdeny=0
    Q_REQUEST,  // request pending decision:  qreqn=0 qacceptn=1 qdeny=0
    Q_STOPPED,  // low-power state:           qreqn=0 qacceptn=0 qdeny=0
    Q_EXIT,     // leaving low-power state:   qreqn=1 qacceptn=0 qdeny=0
    Q_DENIED    // request refused:           qreqn=0 qacceptn=1 qdeny=1
  } state_t;
  state_t state;

  // ------------------------------------------------------------------
  // activity detection: an dev_event keeps the device "active" for
  // ACT_CYCLES clocks; events are also counted for statistics
  // ------------------------------------------------------------------
  logic [7:0]    act_cnt;
  logic [DW-1:0] evt_count;
  wire           active = (act_cnt != 8'd0);

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      act_cnt   <= 8'd0;
      evt_count <= '0;
    end else if (dev_event) begin
      act_cnt   <= ACT_CYCLES[7:0];
      evt_count <= evt_count + 1'b1;
    end else if (active) begin
      act_cnt <= act_cnt - 1'b1;
    end
  end

  // ------------------------------------------------------------------
  // Q-Channel handshake FSM
  // ------------------------------------------------------------------
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) state <= Q_RUN;
    else
      case (state)
        Q_RUN     : state <= qreqn ? Q_RUN  : Q_REQUEST;
        // qreqn must stay low until the device responds; a premature
        // qreqn rise is an illegal sequence (flagged via irq)
        Q_REQUEST : state <= qreqn ? Q_RUN     :
                             active ? Q_DENIED : Q_STOPPED;
        Q_DENIED  : state <= qreqn ? Q_RUN  : Q_DENIED;
        Q_STOPPED : state <= qreqn ? Q_EXIT : Q_STOPPED;
        // qreqn must stay high through the exit; a drop here is illegal
        Q_EXIT    : state <= qreqn ? Q_RUN  : Q_STOPPED;
        default   : state <= Q_RUN;
      endcase
  end

  // ------------------------------------------------------------------
  // outputs (Moore)
  // ------------------------------------------------------------------
  always_comb begin
    qacceptn = (state != Q_STOPPED) && (state != Q_EXIT);
    qdeny    = (state == Q_DENIED);
  end

  assign qactive = active;

  // illegal-sequence dev_event: one-cycle pulse
  assign irq = ((state == Q_REQUEST) && qreqn) ||
               ((state == Q_EXIT)    && !qreqn);

  // AW kept for interface conformity; high dev_event-count bits unused
  wire unused = &{1'b0, evt_count[DW-1:8], 1'b0};

endmodule
