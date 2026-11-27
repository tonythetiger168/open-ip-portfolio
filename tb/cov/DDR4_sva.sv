// SPDX-License-Identifier: Apache-2.0
/*verilator coverage_off*/
// DDR4 checker: 4 banks (haddr[10:9]), row haddr[31:18], 256-word array
// indexed by the column (row and bank select the page, not the storage).
// Pins (cs_n low = a command): act_n low = ACT (ras_n / cas_n / we_n are row
// bits A16..A14 = 0); else {ras_n, cas_n, we_n} = 101 RD, 100 WR, 010 PRE
// (addr[10] set: all banks), 001 REF; addr[12] (BC_n) set on a RD / WR = a
// BL8 line burst; ba = the bank (0 for PREA / REF). Shared page / timing /
// data / line / MR model: mem_chk.svh.
`include "cov_macros.svh"
// write-side spacings (rtl/DDR4_top.sv: CWL from MR1, a BC4 word = 4 clocks,
// a BL8 line = 8 beats, tWR 16, tWTR 8, tCCD 4)
`define MEM_CHK_LINE
`define MEM_CHK_WR2PRE_L(l) (m_cwl + ((l) ? 8 : 4) + 16)
`define MEM_CHK_WR2RD_L(l)  (m_cwl + ((l) ? 8 : 4) + 8)
`define MEM_CHK_TCCD   4
module DDR4_sva (
  input logic        clk, rst_n, hvalid, hready, hdone, ck_t, ck_c, ras_n, cas_n, we_n, cke,
  input logic        cs_n, act_n,
  input logic [1:0]  ba,
  input logic [127:0] rdline,
  input logic        trace_valid,
  input logic [2:0]  hcmd, trace_cmd,
  input logic [31:0] haddr, trace_addr,
  input logic [15:0] hwdata, hrdata,
  input logic [16:0] addr,
  input logic [15:0] dq,
  input logic [1:0]  dqs
);
  `COV_CLOCKING(clk, !rst_n)
  localparam int NB = 4, NCELLS = 256;
  localparam int CL = 15, CWL = 11, TRCD = 14, TRP = 14, TRC = 45, TRAS = 32, TRFC = 160, TREFI = 6240;
  localparam int REF_MIN = TREFI - TRAS - TRP - 4;
  // (CL / CWL up to 20 and an 8-beat line burst on top of the word bounds)
  localparam int REF_MAX = TREFI + 2 * (TRC + TRP + TRCD + 20) + TRAS + TRP + 8 + 40;
  localparam int BUSY_MAX = 2 * (TRC + TRP + TRCD + 20) + TRAS + TRP + TRFC + 8 + 40;
  localparam logic [2:0] P_NOP = 0, P_ACT = 1, P_RD = 2, P_WR = 3, P_PRE = 4, P_PREA = 5,
                         P_REF = 6, P_BAD = 7;

  function automatic int bank_of(input logic [31:0] a); return int'(a[10:9]); endfunction
  function automatic logic [13:0] row_of(input logic [31:0] a); return a[31:18]; endfunction
  function automatic logic [7:0] col_of(input logic [31:0] a); return a[7:0]; endfunction
  function automatic int cellof(input logic [31:0] a); return int'(a[7:0]); endfunction
  function automatic logic pin_row_ok(input logic [16:0] pa, input logic [13:0] r);
    return pa == {3'b0, r};
  endfunction
  function automatic logic pin_col_ok(input logic [16:0] pa, input logic [7:0] c);
    return (pa & ~17'h1000) == {9'b0, c};   // addr[12] = BC_n, checked as q_ln
  endfunction

  logic [2:0]  q_pc;
  logic [16:0] q_pa;
  logic [15:0] q_dq;
  logic        q_ln;
  logic [1:0]  q_dqs, q_ba;
  logic        v_ba;
  function automatic logic [15:0] lane(input logic [31:0] a); return q_dq; endfunction
  always @(negedge clk) begin
    if (cs_n) q_pc <= P_NOP;
    else if (!act_n) q_pc <= ({ras_n, cas_n, we_n} == 3'b000) ? P_ACT : P_BAD;
    else
      case ({ras_n, cas_n, we_n})
        3'b101: q_pc <= P_RD;
        3'b100: q_pc <= P_WR;
        3'b010: q_pc <= addr[10] ? P_PREA : P_PRE;
        3'b001: q_pc <= P_REF;
        default: q_pc <= P_BAD;
      endcase
    q_pa <= addr; q_dq <= dq; q_ln <= addr[12]; q_dqs <= dqs; q_ba <= ba;
  end

  // ba: the bank of ACT / RD / WR / PRE, 0 for PREA / REF
  `define MEM_CHK_EXTRA \
    v_ba = (q_pc == P_ACT || q_pc == P_RD || q_pc == P_WR || q_pc == P_PRE) && q_ba != 2'(b) || \
           (q_pc == P_PREA || q_pc == P_REF) && q_ba != 2'b00;
  `include "mem_chk.svh"

  `SVA_INV(a_bank_pins, !v_ba)
  `SVA_RST(a_reset_cs, !rst_n, cs_n && act_n && ba == 2'b00 && rdline == '0)
  `SVA_INV(a_ck_differential, ck_c == !ck_t)
endmodule

`ifdef VERILATOR
bind DDR4_top DDR4_sva u_sva (.*);
`endif
