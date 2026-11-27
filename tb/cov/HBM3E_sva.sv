// SPDX-License-Identifier: Apache-2.0
/*verilator coverage_off*/
// HBM3E checker: 256 page entries {haddr[10:8] channel, haddr[15:11] pc/bank},
// row haddr[31:18], 256 words per channel indexed by {channel, column}.
// Per-entry refresh: the k-th REF refreshes entry k mod 256. hrdata is the
// SEC-corrected word, so it must match what was written.
// Pins (cs_n low = a command): act_n low = ACT (ras_n / cas_n / we_n = 0);
// else {ras_n, cas_n, we_n} = 101 RD, 100 WR, 010 PRE, 001 REF; addr[12]
// set on a RD / WR = a BL8 line burst; ba = the page entry (of the refresh
// for its PRE / REF). A line write beat carries the beat's data on dq and
// its 5 SEC check bits on ecc (checked against this checker's own
// encoder). Shared page / timing / data / line / MR model: mem_chk.svh.
`include "cov_macros.svh"
// write-side spacings (rtl/HBM3E_top.sv: CWL from MR1, a word burst 4
// clocks, a line 8 beats, tWR 10, tWTR 5)
`define MEM_CHK_LINE
`define MEM_CHK_LW_OK(k) (lane(op_a) === op_ld[k] && q_ecc[5 * op_a[10:8] +: 5] === chk5(op_ld[k]))
`define MEM_CHK_WR2PRE_L(l) (m_cwl + ((l) ? 8 : 4) + 10)
`define MEM_CHK_WR2RD_L(l)  (m_cwl + ((l) ? 8 : 4) + 5)
`define MEM_CHK_TCCD   4
module HBM3E_sva (
  input logic        clk, rst_n, hvalid, hready, hdone, ck_t, ck_c, ras_n, cas_n, we_n, cke,
  input logic        cs_n, act_n,
  input logic [7:0]  ba,
  input logic [127:0] rdline,
  input logic [39:0] ecc,
  input logic        trace_valid,
  input logic [2:0]  hcmd, trace_cmd,
  input logic [31:0] haddr, trace_addr,
  input logic [15:0] hwdata, hrdata,
  input logic [16:0] addr,
  input logic [127:0] dq,
  input logic [1:0]  dqs
);
  `COV_CLOCKING(clk, !rst_n)
  localparam int NB = 256, NCELLS = 2048;
  localparam int CL = 12, CWL = 10, TRCD = 10, TRP = 10, TRC = 34, TRAS = 22, TRFC = 130, TREFI = 1560;
  localparam int REF_MIN = TREFI - TRAS - TRP - 4;
  // (CL / CWL up to 20 and an 8-beat line burst on top of the word bounds)
  localparam int REF_MAX = TREFI + 2 * (TRC + TRP + TRCD + 20) + TRAS + TRP + 8 + 40;
  localparam int BUSY_MAX = 2 * (TRC + TRP + TRCD + 20) + TRAS + TRP + TRFC + 8 + 40;
  localparam logic [2:0] P_NOP = 0, P_ACT = 1, P_RD = 2, P_WR = 3, P_PRE = 4, P_PREA = 5,
                         P_REF = 6, P_BAD = 7;

  function automatic int bank_of(input logic [31:0] a); return int'({a[10:8], a[15:11]}); endfunction
  function automatic logic [13:0] row_of(input logic [31:0] a); return a[31:18]; endfunction
  function automatic logic [7:0] col_of(input logic [31:0] a); return a[7:0]; endfunction
  function automatic int cellof(input logic [31:0] a); return int'({a[10:8], a[7:0]}); endfunction
  function automatic logic pin_row_ok(input logic [16:0] pa, input logic [13:0] r);
    return pa == {3'b0, r};
  endfunction
  function automatic logic pin_col_ok(input logic [16:0] pa, input logic [7:0] c);
    return (pa & ~17'h1000) == {9'b0, c};   // addr[12] = line, checked as q_ln
  endfunction
  // SEC check bits of a data word: data bit i at codeword position pos(i)
  // (positions 1..21 that are not a power of two), check j = parity of the
  // data bits whose position has bit j set
  function automatic logic [4:0] chk5(input logic [15:0] d);
    int p, i;
    chk5 = 0; i = 0;
    for (p = 1; p <= 21; p++)
      if (p != 1 && p != 2 && p != 4 && p != 8 && p != 16) begin
        if (d[i]) chk5 = chk5 ^ 5'(p);
        i++;
      end
  endfunction

  logic [2:0]  q_pc;
  logic [16:0] q_pa;
  logic [127:0] q_dq;
  logic [39:0] q_ecc;
  logic        q_ln;
  logic [1:0]  q_dqs;
  logic [7:0]  q_ba;
  logic        v_ba;
  function automatic logic [15:0] lane(input logic [31:0] a); return q_dq[16 * a[10:8] +: 16]; endfunction
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
    q_pa <= addr; q_dq <= dq; q_ecc <= ecc; q_ln <= addr[12]; q_dqs <= dqs; q_ba <= ba;
  end

  `define MEM_CHK_REF_PB
  localparam int REF_NB = 256;
  function automatic int ref_bank_of(input int k); return k; endfunction
  `define MEM_CHK_EXTRA \
    v_ba = (q_pc == P_ACT || q_pc == P_RD || q_pc == P_WR) && q_ba != 8'(b) || \
           q_pc == P_PRE && q_ba != 8'(rpre ? tb : b) || q_pc == P_REF && q_ba != 8'(tb);
  `include "mem_chk.svh"

  `SVA_INV(a_bank_pins, !v_ba)
  `SVA_RST(a_reset_cs, !rst_n, cs_n && act_n && ba == 8'h00 && rdline == '0)
  `SVA_INV(a_ck_differential, ck_c == !ck_t)
endmodule

`ifdef VERILATOR
bind HBM3E_top HBM3E_sva u_sva (.*);
`endif
