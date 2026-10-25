// SPDX-License-Identifier: Apache-2.0
// ARM Q-Channel device: concurrent SVA against an independent handshake
// model (RUN/REQUEST/STOPPED/EXIT/DENIED, activity window) + functional
// coverage of accept, deny, wake and controller protocol violations.
`include "cov_macros.svh"
module ARM_Q_Channel_Low_Power_Interface_sva #(parameter int ACT_CYCLES = 16) (
  input logic clk, rst_n,
  input logic qreqn, qacceptn, qdeny, qactive, dev_event, irq
);
  `COV_CLOCKING(clk, !rst_n)
  typedef enum logic [2:0] {M_RUN, M_REQ, M_STOP, M_EXIT, M_DENY} mst_t;
  mst_t m_st;
  int   m_act;
  wire  busy = m_act != 0;
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin m_st <= M_RUN; m_act <= 0; end
    else begin
      m_act <= dev_event ? ACT_CYCLES : busy ? m_act - 1 : 0;
      case (m_st)
        M_RUN:  if (!qreqn) m_st <= M_REQ;
        M_REQ:  m_st <= qreqn ? M_RUN : busy ? M_DENY : M_STOP;
        M_DENY: if (qreqn) m_st <= M_RUN;
        M_STOP: if (qreqn) m_st <= M_EXIT;
        M_EXIT: m_st <= qreqn ? M_RUN : M_STOP;
        default: m_st <= M_RUN;
      endcase
    end
  end

  `SVA_RST(a_reset_run, !rst_n, qacceptn && !qdeny && !qactive && !irq)
  `SVA_INV(a_accept_deny_exclusive, !(qdeny && !qacceptn))
  `SVA_IMP(a_qacceptn_model, 1'b1, qacceptn == !(m_st inside {M_STOP, M_EXIT}))
  `SVA_IMP(a_qdeny_model, 1'b1, qdeny == (m_st == M_DENY))
  `SVA_IMP(a_qactive_model, 1'b1, qactive == busy)
  `SVA_NXT(a_idle_request_accepted, m_st == M_REQ && !qreqn && !busy, !qacceptn && !qdeny)
  `SVA_NXT(a_busy_request_denied, m_st == M_REQ && !qreqn && busy, qdeny && qacceptn)
  `SVA_NXT(a_exit_restores_run, m_st == M_EXIT && qreqn, qacceptn && !qdeny)
  `SVA_IMP(a_irq_on_violation, 1'b1, irq == ((m_st == M_REQ && qreqn) || (m_st == M_EXIT && !qreqn)))

  `FC(accept, m_st == M_REQ && !qreqn && !busy)
  `FC(deny, m_st == M_REQ && !qreqn && busy)
  `FC(deny_held, m_st == M_DENY && !qreqn)
  `FC(wake_event_while_stopped, m_st == M_STOP && dev_event)
  `FC(stopped_held, m_st == M_STOP && !qreqn ##1 m_st == M_STOP)
  `FC(withdraw_during_request, m_st == M_REQ && qreqn)
  `FC(drop_during_exit, m_st == M_EXIT && !qreqn)
  `FC(event_retriggers_window, dev_event && busy)
  `FC_RST(reset_while_stopped, rst_n && m_st == M_STOP ##1 !rst_n)
endmodule

bind ARM_Q_Channel_Low_Power_Interface_top ARM_Q_Channel_Low_Power_Interface_sva
  #(.ACT_CYCLES(ACT_CYCLES)) u_sva (.*);
