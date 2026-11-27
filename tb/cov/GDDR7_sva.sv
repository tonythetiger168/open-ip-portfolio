// SPDX-License-Identifier: Apache-2.0
/*verilator coverage_off*/
// GDDR7 checker: 8 banks {haddr[8] channel, haddr[10:9]}, row haddr[31:18],
// 256 words per channel indexed by {channel, column}. PAM3 read data: the
// clock before hdone and the hdone clock carry 6 two-bit symbol codes each
// on the channel's dq[11:0]; the checker decodes them (v = 9*t0 + 3*t1 + t2
// per nibble) and compares the word with its own array, and no code may be
// 11 or decode above 15.
// With MR2[0] = 0 a read word comes NRZ in the hdone clock (checked through
// hrdata by the shared model).
// Pins (cs_n low = a command): act_n low = ACT (ras_n / cas_n / we_n = 0);
// else {ras_n, cas_n, we_n} = 101 RD, 100 WR, 010 PRE (addr[10] set: all
// banks), 001 REF; addr[12] set on a RD / WR = a line burst; ba = the bank
// entry (0 for PREA / REF). Line bursts: PAM2 (MR2[0] = 0) BL8 NRZ on the
// channel's dq, PAM3 BL6 of 16 symbols {dqx[p], dq[p]} per beat (the line's
// 96 trits, beat b = trits 16b..16b+15). Shared page / timing / data / line
// / MR model: mem_chk.svh.
`include "cov_macros.svh"
// write-side spacings (rtl/GDDR7_top.sv: CWL from MR1, a word burst 2
// clocks, a line 8 (PAM2) / 6 (PAM3) beats, tWR 15, tWTR 7)
`define MEM_CHK_LINE
`define MEM_CHK_LMODE m_mr[2][0]
`define MEM_CHK_MR_RESET m_mr[2] = 8'h01;
`define MEM_CHK_LNB (op_lm ? 6 : 8)
`define MEM_CHK_LW_OK(k) (op_lm ? sym_of(q_dqx[16 * op_a[8] +: 16], lane(op_a)) === lsym(k) : lane(op_a) === op_ld[k])
`define MEM_CHK_WR2PRE_L(l) (m_cwl + ((l) ? (m_mr[2][0] ? 6 : 8) : 2) + 15)
`define MEM_CHK_WR2RD_L(l)  (m_cwl + ((l) ? (m_mr[2][0] ? 6 : 8) : 2) + 7)
`define MEM_CHK_TCCD   2
module GDDR7_sva (
  input logic        clk, rst_n, hvalid, hready, hdone, ck_t, ck_c, ras_n, cas_n, we_n, cke,
  input logic        cs_n, act_n, pam3,
  input logic [2:0]  ba,
  input logic [127:0] rdline,
  input logic [31:0] dqx,
  input logic        trace_valid,
  input logic [2:0]  hcmd, trace_cmd,
  input logic [31:0] haddr, trace_addr,
  input logic [15:0] hwdata, hrdata,
  input logic [16:0] addr,
  input logic [31:0] dq,
  input logic [1:0]  dqs
);
  `COV_CLOCKING(clk, !rst_n)
  localparam int NB = 8, NCELLS = 512;
  localparam int CL = 18, CWL = 7, TRCD = 15, TRP = 15, TRC = 46, TRAS = 32, TRFC = 150, TREFI = 3900;
  localparam int REF_MIN = TREFI - TRAS - TRP - 4;
  // (CL / CWL up to 20 and an 8-beat line burst on top of the word bounds)
  localparam int REF_MAX = TREFI + 2 * (TRC + TRP + TRCD + 20) + TRAS + TRP + 8 + 40;
  localparam int BUSY_MAX = 2 * (TRC + TRP + TRCD + 20) + TRAS + TRP + TRFC + 8 + 40;
  localparam logic [2:0] P_NOP = 0, P_ACT = 1, P_RD = 2, P_WR = 3, P_PRE = 4, P_PREA = 5,
                         P_REF = 6, P_BAD = 7;

  function automatic int bank_of(input logic [31:0] a); return int'({a[8], a[10:9]}); endfunction
  function automatic logic [13:0] row_of(input logic [31:0] a); return a[31:18]; endfunction
  function automatic logic [7:0] col_of(input logic [31:0] a); return a[7:0]; endfunction
  function automatic int cellof(input logic [31:0] a); return int'({a[8], a[7:0]}); endfunction
  function automatic logic pin_row_ok(input logic [16:0] pa, input logic [13:0] r);
    return pa == {3'b0, r};
  endfunction
  function automatic logic pin_col_ok(input logic [16:0] pa, input logic [7:0] c);
    return (pa & ~17'h1000) == {9'b0, c};   // addr[12] = line, checked as q_ln
  endfunction

  logic [2:0]  q_pc;
  logic [16:0] q_pa;
  logic [31:0] q_dq, q_dqx;
  logic        q_ln, q_p3;
  logic [1:0]  q_dqs;
  logic [2:0]  q_ba;
  logic        v_ba, v_pam3pin;
  // PAM3 line symbols: beat k of the line in op_ld, as 16 2-bit codes
  function automatic logic [31:0] sym_of(input logic [15:0] x, input logic [15:0] d);
    for (int j = 0; j < 16; j++) sym_of[2*j +: 2] = {x[j], d[j]};
  endfunction
  function automatic logic [15:0] lane(input logic [31:0] a); return q_dq[16 * a[8] +: 16]; endfunction
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
    q_pa <= addr; q_dq <= dq; q_dqx <= dqx; q_ln <= addr[12]; q_dqs <= dqs; q_ba <= ba; q_p3 <= pam3;
  end

  logic [15:0] p_rl, rl, pw;
  logic        v_pam3, v_pam3_code, e_pam3_rd;
  logic [15:0] e_nib;
  function automatic logic [16:0] pam3_dec(input logic [23:0] t);
    logic bad; logic [15:0] w; int v;
    bad = 0; w = 0;
    for (int n = 0; n < 4; n++) begin
      if (t[6*n +: 2] == 3 || t[6*n+2 +: 2] == 3 || t[6*n+4 +: 2] == 3) bad = 1;
      v = 9 * t[6*n +: 2] + 3 * t[6*n+2 +: 2] + t[6*n+4 +: 2];
      if (v > 15) bad = 1;
      w[4*n +: 4] = 4'(v);
    end
    return {bad, w};
  endfunction
  `define MEM_CHK_EXTRA \
    {v_pam3, v_pam3_code, e_pam3_rd} = '0; e_nib = '0; \
    rl = lane(op_a); \
    v_ba = (q_pc == P_ACT || q_pc == P_RD || q_pc == P_WR || q_pc == P_PRE) && q_ba != 3'(b) || \
           (q_pc == P_PREA || q_pc == P_REF) && q_ba != 3'b000; \
    v_pam3pin = q_p3 !== m_mr[2][0]; \
    if (q_hdone && op_v && op_c == 3'd2 && !op_ln && m_mr[2][0]) begin \
      {v_pam3_code, pw} = pam3_dec({rl[11:0], p_rl[11:0]}); \
      v_pam3 = pw !== arr[cellof(op_a)]; e_pam3_rd = 1; \
      for (int n = 0; n < 4; n++) e_nib[pw[4*n +: 4]] = 1; \
    end \
    p_rl = rl;
  `include "mem_chk.svh"

  function automatic logic [31:0] lsym(input int k);
    logic [191:0] t; logic [3:0] v;
    for (int i = 0; i < 32; i++) begin
      v = op_ld[i / 4][4 * (i % 4) +: 4];
      t[6*i +: 6] = {2'(v % 3), 2'((v % 9) / 3), 2'(v / 9)};   // t0 low
    end
    return t[32*k +: 32];
  endfunction

  `SVA_INV(a_bank_pins, !v_ba)
  `SVA_INV(a_pam3_pin_is_mr2, !v_pam3pin)
  `SVA_RST(a_reset_cs, !rst_n, cs_n && act_n && ba == 3'b000 && rdline == '0)
  `SVA_INV(a_pam3_read_word, !v_pam3)
  `SVA_INV(a_pam3_legal_symbols, !v_pam3_code)
  `FC(pam3_read, e_pam3_rd)
  `FC(pam3_nibble_0, e_nib[0])
  `FC(pam3_nibble_1, e_nib[1])
  `FC(pam3_nibble_2, e_nib[2])
  `FC(pam3_nibble_3, e_nib[3])
  `FC(pam3_nibble_4, e_nib[4])
  `FC(pam3_nibble_5, e_nib[5])
  `FC(pam3_nibble_6, e_nib[6])
  `FC(pam3_nibble_7, e_nib[7])
  `FC(pam3_nibble_8, e_nib[8])
  `FC(pam3_nibble_9, e_nib[9])
  `FC(pam3_nibble_10, e_nib[10])
  `FC(pam3_nibble_11, e_nib[11])
  `FC(pam3_nibble_12, e_nib[12])
  `FC(pam3_nibble_13, e_nib[13])
  `FC(pam3_nibble_14, e_nib[14])
  `FC(pam3_nibble_15, e_nib[15])

  `SVA_INV(a_ck_differential, ck_c == !ck_t)
endmodule

`ifdef VERILATOR
bind GDDR7_top GDDR7_sva u_sva (.*);
`endif
