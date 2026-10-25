// SPDX-License-Identifier: Apache-2.0
/*verilator coverage_off*/
// LPDDR checker: 2 banks (haddr[8]), row haddr[31:18], 256-word array indexed
// by the column; RD / WR take the bank's open row. Power-down: cke drops
// only after PD_CNT idle clocks with nothing in flight, must drop by then,
// rises in the clock after a command is taken (or a refresh falls due), and
// no pin command is issued with cke low or in the clock it rises (tXP).
// Pins: {ras_n, cas_n, we_n} = 011 ACT, 101 RD, 100 WR, 010 PRE (addr[10]
// set: all banks), 001 REF. Shared page / timing / data model: mem_chk.svh.
`include "cov_macros.svh"
module LPDDR_sva (
  input logic        clk, rst_n, hvalid, hready, hdone, ck_t, ck_c, ras_n, cas_n, we_n, cke,
  input logic        trace_valid,
  input logic [2:0]  hcmd, trace_cmd,
  input logic [31:0] haddr, trace_addr,
  input logic [15:0] hwdata, hrdata,
  input logic [16:0] addr,
  input logic [15:0] dq,
  input logic [1:0]  dqs
);
  `COV_CLOCKING(clk, !rst_n)
  localparam int NB = 2, NCELLS = 256;
  localparam int CL = 3, TRCD = 3, TRP = 3, TRC = 11, TRAS = 8, TRFC = 90, TREFI = 3900;
  localparam int REF_MIN = TREFI - TRAS - TRP - 4;
  localparam int REF_MAX = TREFI + 2 * (TRC + TRP + TRCD + CL) + TRAS + TRP + 8;
  localparam int BUSY_MAX = 2 * (TRC + TRP + TRCD + CL) + TRAS + TRP + TRFC + 8;
  localparam logic [2:0] P_NOP = 0, P_ACT = 1, P_RD = 2, P_WR = 3, P_PRE = 4, P_PREA = 5,
                         P_REF = 6, P_BAD = 7;

  function automatic int bank_of(input logic [31:0] a); return int'(a[8]); endfunction
  function automatic logic [13:0] row_of(input logic [31:0] a); return a[31:18]; endfunction
  function automatic logic [7:0] col_of(input logic [31:0] a); return a[7:0]; endfunction
  function automatic int cellof(input logic [31:0] a); return int'(a[7:0]); endfunction
  function automatic logic pin_row_ok(input logic [16:0] pa, input logic [13:0] r);
    return pa == {3'b0, r};
  endfunction
  function automatic logic pin_col_ok(input logic [16:0] pa, input logic [7:0] c);
    return pa == {9'b0, c};
  endfunction

  logic [2:0]  q_pc;
  logic [16:0] q_pa;
  logic [15:0] q_dq;
  function automatic logic [15:0] lane(input logic [31:0] a); return q_dq; endfunction
  always @(negedge clk) begin
    case ({ras_n, cas_n, we_n})
      3'b111: q_pc <= P_NOP;
      3'b011: q_pc <= P_ACT;
      3'b101: q_pc <= P_RD;
      3'b100: q_pc <= P_WR;
      3'b010: q_pc <= addr[10] ? P_PREA : P_PRE;
      3'b001: q_pc <= P_REF;
      default: q_pc <= P_BAD;
    endcase
    q_pa <= addr; q_dq <= dq;
  end

  `define MEM_CHK_RW_ANY_ROW
  `define MEM_CHK_CKE_PD
  localparam int PD_CNT = 32;
  logic q_cke, p_cke, w_wake;
  int   ict;
  logic e_rw_other_row, v_pd_cmd, v_pd_busy, v_pd_early, v_pd_late, v_pd_wake, e_pd, e_wake_cmd,
        e_wake_ref, e_pd_noop;
  always @(negedge clk) q_cke <= cke;
  `define MEM_CHK_EXTRA \
    e_rw_other_row = (q_pc == P_RD || q_pc == P_WR) && op_v && row_m[b] != row_of(op_a); \
    {v_pd_cmd, v_pd_busy, v_pd_early, v_pd_late, v_pd_wake, e_pd, e_wake_cmd, e_wake_ref, e_pd_noop} = '0; \
    if (q_pc != P_NOP && (!q_cke || !p_cke)) v_pd_cmd = 1; \
    if (!q_cke && op_v) v_pd_busy = 1; \
    if (p_cke && !q_cke) begin e_pd = 1; if (ict < PD_CNT) v_pd_early = 1; end \
    if (q_cke && ict > PD_CNT) v_pd_late = 1; \
    if (w_wake && !q_cke) v_pd_wake = 1; \
    if (!p_cke && q_cke) begin e_wake_cmd = op_v; e_wake_ref = !op_v; end \
    w_wake = !q_cke && (hvalid && q_hready && hcmd >= 3'd1 && hcmd <= 3'd4 && \
             !(hcmd == 3'd1 && open_m[bank_of(haddr)] && row_m[bank_of(haddr)] == row_of(haddr)) || !q_hready); \
    e_pd_noop = !q_cke && hvalid && q_hready && !w_wake; \
    ict = (q_hready && !hvalid && q_cke) ? ict + 1 : 0; \
    p_cke = q_cke;
  always @(posedge clk) if (!rst_n) begin ict = 0; p_cke = 0; w_wake = 0; end
  `include "mem_chk.svh"

  `SVA_INV(a_no_command_in_power_down_or_txp, !v_pd_cmd)
  `SVA_INV(a_power_down_only_when_idle, !v_pd_busy)
  `SVA_INV(a_power_down_not_before_pd_cnt, !v_pd_early)
  `SVA_INV(a_power_down_by_pd_cnt, !v_pd_late)
  `SVA_INV(a_wake_next_clock, !v_pd_wake)
  `FC(rw_uses_open_row_not_haddr_row, e_rw_other_row)
  `FC(power_down_entered, e_pd)
  `FC(wake_by_command, e_wake_cmd)
  `FC(wake_by_refresh, e_wake_ref)
  `FC(noop_in_power_down, e_pd_noop)

  `SVA_INV(a_ck_differential, ck_c == !ck_t)
endmodule

bind LPDDR_top LPDDR_sva u_sva (.*);
