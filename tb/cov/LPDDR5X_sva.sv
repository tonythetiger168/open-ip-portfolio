// SPDX-License-Identifier: Apache-2.0
/*verilator coverage_off*/
// LPDDR5X checker: 8 banks ({haddr[8] channel, haddr[10:9]}), row haddr[31:18],
// 256 words per channel indexed by {channel, column}. Per-bank refresh: the
// k-th REF refreshes bank k mod 8. A WR to column 0xF1 is the FSP-OP
// mailbox (bit 0: FSP1) and must cause no pin traffic; it switches the MR
// set, and with it CL = 10 + MR0[3:0] and CWL = 5 + MR1[3:0] (reset: FSP0
// CL 22, FSP1 CL 14, CWL 11). Line commands (RDL / WRL: the BL bit, CA beat
// 0 bit 0, set in the RD / WR frame) and the MR sets as mem_chk.svh
// `MEM_CHK_LINE. wck_t / wck_c run from the clock of a line WR through its
// last data beat (wck_t toggling, starting low) and rest wck_t = 1.
// The internal command bus is checked as usual and the CA frames against it.
// Pins: {ras_n, cas_n, we_n} = 011 ACT, 101 RD, 100 WR, 010 PRE (addr[10]
// set: all banks), 001 REF. Shared page / timing / data model: mem_chk.svh.
`include "cov_macros.svh"
// write-side spacings (rtl/LPDDR5X_top.sv: CWL from the MR set, burst 8
// clocks for a word or a line, tWR 14, tWTR 8)
`define MEM_CHK_LINE
`define MEM_CHK_WR2PRE_L(l) (m_cwl + 8 + 14)
`define MEM_CHK_WR2RD_L(l)  (m_cwl + 8 + 8)
`define MEM_CHK_TCCD   8
`define MEM_CHK_MRSET int'(fs_m)
`define MEM_CHK_CL_OF (10 + m_mrs[m_set][0][3:0])
`define MEM_CHK_MR_RESET m_mrs[0][0] = 8'd12; m_mrs[1][0] = 8'd4; m_mrs[1][1] = 8'(CWL - 5);
`define MEM_CHK_LMODE 1'b0
module LPDDR5X_sva (
  input logic        clk, rst_n, hvalid, hready, hdone, ck_t, ck_c, ras_n, cas_n, we_n, cke,
  input logic        trace_valid,
  input logic [2:0]  hcmd, trace_cmd,
  input logic [31:0] haddr, trace_addr,
  input logic [15:0] hwdata, hrdata,
  input logic [127:0] rdline,
  input logic [16:0] addr,
  input logic [31:0] dq,
  input logic [1:0]  dqs,
  input logic [6:0]  ca,
  input logic        cs_n, wck_t, wck_c
);
  `COV_CLOCKING(clk, !rst_n)
  localparam int NB = 8, NCELLS = 512;
  localparam int CL = 22, CWL = 11;     // reset values of FSP0
  localparam int CLM = 25, TRCD = 14, TRP = 14, TRC = 46, TRAS = 34, TRFC = 140, TREFI = 1560;
  localparam int REF_MIN = TREFI - TRAS - TRP - 4;
  localparam int REF_MAX = TREFI + 2 * (TRC + TRP + TRCD + CLM) + TRAS + TRP + 40;
  localparam int BUSY_MAX = 2 * (TRC + TRP + TRCD + CLM) + TRAS + TRP + TRFC + 40;
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
    return (pa & ~17'h1000) == {9'b0, c};   // addr[12]: the CA BL bit, checked as q_ln
  endfunction

  logic [2:0]  q_pc;
  logic [16:0] q_pa;
  logic [31:0] q_dq;
  logic [1:0]  q_dqs;
  logic        q_ln;                    // BL bit of the RD / WR frame on the CA pins
  function automatic logic [15:0] lane(input logic [31:0] a); return q_dq[16 * a[8] +: 16]; endfunction
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
    q_pa <= addr; q_dq <= dq; q_dqs <= dqs; q_ln <= ca[0];
  end

  `define MEM_CHK_REF_PB
  localparam int REF_NB = 8;
  function automatic int ref_bank_of(input int k); return k; endfunction
  // FSP: the active MR set
  logic fs_m, e_mb_a, e_mb_b, e_rd_b, e_wr_b, e_rdl_b, e_wrl_b, e_mrw_b;
  `define MEM_CHK_WR_DONE (s_rw || !op_ln && op_a[7:0] == 8'hF1)
  `define MEM_CHK_ON_ACCEPT \
    {e_mb_a, e_mb_b} = '0; \
    if (hcmd == 3'd3 && haddr[7:0] == 8'hF1) begin \
      fs_m = hwdata[0]; e_mb_b = hwdata[0]; e_mb_a = !hwdata[0]; op_v = 0; \
    end
  always @(posedge clk) if (!rst_n) fs_m = 0;
  initial fs_m = 0;

  // CA frames (see the RTL): beat 0 = {code, bank, BL} with cs_n low, then
  // the row (ACT) or column (RD / WR) LSB first, CAW bits a beat, cs_n high;
  // the bank is the model's (the refresh target for a refresh PRE / REF);
  // BL (= q_ln, checked against the command by mem_chk) only on a RD / WR
  localparam int CAW = 7, CABW = 3, CAPAD = 1, NA = 2, NC = 2;
  logic [CAW-1:0] q_ca;
  logic           q_cs_n;
  always @(negedge clk) begin q_ca <= ca; q_cs_n <= cs_n; end
  logic [13:0] ca_exp;
  int          ca_left, eb;
  logic        v_ca, v_ca_overlap;
  `define MEM_CHK_EXTRA \
    v_ca = 0; v_ca_overlap = 0; \
    if (is_cmd) begin \
      if (ca_left != 0) v_ca_overlap = 1; \
      eb = (q_pc == P_REF || q_pc == P_PRE && rpre) ? tb : b; \
      if (q_cs_n || q_ca != ((CAW'(q_pc) << (CAW - 3)) | (CAW'(eb) << CAPAD) | \
                             CAW'((q_pc == P_RD || q_pc == P_WR) && q_ln))) v_ca = 1; \
      ca_exp = (q_pc == P_ACT) ? q_pa[13:0] : {6'b0, q_pa[7:0]}; \
      ca_left = (q_pc == P_ACT) ? NA : (q_pc == P_RD || q_pc == P_WR) ? NC : 0; \
    end else begin \
      if (!q_cs_n) v_ca = 1; \
      if (ca_left != 0) begin \
        if (q_ca != ca_exp[CAW-1:0]) v_ca = 1; \
        ca_exp = ca_exp >> CAW; ca_left = ca_left - 1; \
      end else if (q_ca != 0) v_ca = 1; \
    end \
    e_rd_b = q_pc == P_RD && fs_m && !q_ln; e_wr_b = q_pc == P_WR && fs_m && !q_ln; \
    e_rdl_b = q_pc == P_RD && fs_m && q_ln; e_wrl_b = q_pc == P_WR && fs_m && q_ln; \
    e_mrw_b = hvalid && q_hready && m_fill == 0 && hcmd == 3'd7 && !haddr[3] && fs_m;
  always @(posedge clk) if (!rst_n) ca_left = 0;
  initial ca_left = 0;
  `include "mem_chk.svh"

  // ---- WCK: runs from the clock of a line WR through its last data beat
  // (clock WR + CWL + 7), wck_t starting low and toggling every clock
  logic q_wck;
  always @(negedge clk) q_wck <= wck_t;
  int   wc, wck_beg, wck_end;
  logic wck_prev, v_wck;
  always @(posedge clk or negedge rst_n)
    if (!rst_n) begin wc = 0; wck_beg = -1; wck_end = -1; wck_prev = 1; v_wck = 0; end
    else begin
      if (q_pc == P_WR && q_ln) begin wck_beg = wc; wck_end = wc + m_cwl + 7; end
      if (wc >= wck_beg && wc <= wck_end)
        v_wck = (wc == wck_beg) ? q_wck !== 1'b0 : q_wck !== !wck_prev;
      else v_wck = q_wck !== 1'b1;
      wck_prev = q_wck; wc = wc + 1;
    end

  `SVA_INV(a_ca_frame_matches_command, !v_ca)
  `SVA_INV(a_ca_frames_do_not_overlap, !v_ca_overlap)
  `SVA_INV(a_wck_runs_through_line_writes, !v_wck)
  `SVA_INV(a_wck_differential, wck_c == !wck_t)
  `FC(mailbox_fsp0, e_mb_a)
  `FC(mailbox_fsp1, e_mb_b)
  `FC(read_in_fsp1, e_rd_b)
  `FC(write_in_fsp1, e_wr_b)
  `FC(line_read_in_fsp1, e_rdl_b)
  `FC(line_write_in_fsp1, e_wrl_b)
  `FC(mrw_in_fsp1, e_mrw_b)

  `SVA_INV(a_ck_differential, ck_c == !ck_t)
endmodule

`ifdef VERILATOR
bind LPDDR5X_top LPDDR5X_sva u_sva (.*);
`endif
