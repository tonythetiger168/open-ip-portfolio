// SPDX-License-Identifier: Apache-2.0
/*verilator coverage_off*/
// GDDR7_Lite checker: 2 channels x 4 banks (haddr[9] channel, haddr[8:7]
// bank), row haddr[18:10], line haddr[6:4]; one 128-bit array line per
// {channel, bank, row, line}; haddr[31:19] must be 0. Pins as DDR4_Lite,
// with the channel on addr[11] of ACT / RD / WR / PRE. Data: PAM2 (MR2[0]
// = 0) is BL8 on dq[15:0] with dq[31:16] Hi-Z; PAM3 is BL6 on 16 2-bit
// symbol lanes, checked against an arithmetic base-3 expansion of the line
// (32 nibbles -> 96 trits, lane j of beat k = trit 16k+j). The mode is the
// one in MR2 when the RD / WR goes out. Shared model: lite_chk.svh.
`include "cov_macros.svh"
module GDDR7_Lite_sva (
  input logic        clk, rst_n, hvalid, hready, hdone, irq, pam3,
  input logic        ck_t, ck_c, cke, cs_n, act_n, ras_n, cas_n, we_n,
  input logic        trace_valid,
  input logic [2:0]  hcmd,
  input logic [3:0]  trace_cmd,
  input logic [31:0] haddr, trace_addr,
  input logic [15:0] hwdata, hrdata,
  input logic [1:0]  ba,
  input logic [13:0] addr,
  input logic [31:0] dq,
  input logic [1:0]  dqs,
  input logic        dq_oe, dqs_oe, dq_hi_oe     // output enables (DUT internals)
);
  `COV_CLOCKING(clk, !rst_n)
  localparam int NB = 8, NLINES = 8 * 512 * 8;
  localparam int T_RCD = 6, T_RP = 6, T_RC = 40, T_RAS = 16, T_RRD = 3, T_WR = 8,
                 T_WTR = 8, T_RFC = 40, T_REFI = 400, CL0 = 11, CWL0 = 8;
  localparam int REF_LAT = 2 * (T_RAS + T_RP + T_RCD + 20 + 8 + T_WR) + 16;
  localparam int BUSY_MAX = REF_LAT + T_RFC + 2 * (T_RAS + T_RP + T_RCD + 20 + 8 + T_WR) + 16;

  function automatic int bank_of(input logic [31:0] a); return int'(a[9:7]); endfunction
  function automatic int row_of(input logic [31:0] a); return int'(a[18:10]); endfunction
  function automatic int line_of(input logic [31:0] a); return int'(a[6:4]); endfunction
  function automatic int idx_of(input logic [31:0] a); return int'({a[9:7], a[18:10], a[6:4]}); endfunction
  function automatic logic in_range(input logic [31:0] a); return a[31:19] == 0; endfunction
  // the 16 symbols of PAM3 beat k: trit g = 16k + j is digit g % 3 of
  // nibble g / 3 (digit 0 the least significant)
  function automatic logic [31:0] pam3_beat(input logic [127:0] line, input int k);
    for (int j = 0; j < 16; j++) begin
      int g, v, d;
      g = 16 * k + j; v = int'(line[4 * (g / 3) +: 4]); d = g % 3;
      pam3_beat[2*j +: 2] = 2'((d == 0) ? v % 3 : (d == 1) ? (v / 3) % 3 : v / 9);
    end
  endfunction

  logic        q_cs_n, q_act_n, q_ras_n, q_cas_n, q_we_n, q_hready, q_hdone, q_irq, q_tv, q_pam3,
               q_dq_oe, q_dqs_oe, q_dq_hi_oe;
  logic [1:0]  q_ba, q_dqs;
  logic [13:0] q_addr;
  logic [31:0] q_dq;
  logic [15:0] q_hrdata;
  logic [3:0]  q_tc;
  logic [31:0] q_ta;
  always @(negedge clk) begin
    q_cs_n <= cs_n; q_act_n <= act_n; q_ras_n <= ras_n; q_cas_n <= cas_n; q_we_n <= we_n;
    q_ba <= ba; q_addr <= addr; q_dq <= dq; q_dqs <= dqs;
    q_hready <= hready; q_hdone <= hdone; q_hrdata <= hrdata; q_irq <= irq; q_pam3 <= pam3;
    q_dq_oe <= dq_oe; q_dqs_oe <= dqs_oe; q_dq_hi_oe <= dq_hi_oe;
    q_tv <= trace_valid; q_tc <= trace_cmd; q_ta <= trace_addr;
  end
  wire [2:0] pin_bank = {q_addr[11], q_ba};

  logic bst_p;                         // mode of the burst on dq
  logic wmode [NLINES];                // mode each array line was written in
  initial for (int i = 0; i < NLINES; i++) wmode[i] = 0;
  logic v_pam3_pin, e_rd_pam3, e_wr_pam3, e_rd_other_mode, e_ch1_conf;

`define LITE_ACT_ADDR(a) {2'b00, a[9], 2'b00, a[18:10]}
`define LITE_RW_ADDR(a) {2'b00, a[9], 4'b0000, a[6:4], 4'h0}
`define LITE_PRE_ADDR(b) {2'b00, b[2], 11'h000}
`define LITE_BL (mr_m[2][0] ? 6 : 8)
`define LITE_DQ_OK(line, k) (bst_p ? q_dq === pam3_beat(line, k) : \
                             q_dq[15:0] === line[16*(k) +: 16] && q_dq[31:16] === 16'hzzzz)
`define LITE_MRW(i, d) d[7:0]
`define LITE_NO_DLL
`define LITE_EXTRA \
      v_pam3_pin = q_pam3 !== mr_m[2][0]; \
      if (q_dq_hi_oe !== (exp_oe && bst_p)) v_oe = 1; \
      e_rd_pam3 = 0; e_wr_pam3 = 0; e_rd_other_mode = 0; e_ch1_conf = 0; \
      if (pc == C_RD || pc == C_WR) begin \
        bst_p = mr_m[2][0]; \
        e_rd_pam3 = pc == C_RD && bst_p; e_wr_pam3 = pc == C_WR && bst_p; \
        e_rd_other_mode = pc == C_RD && wmode[bst_idx] != bst_p; \
        if (pc == C_WR) wmode[bst_idx] = bst_p; \
      end \
      if (pc == C_PRE && b >= 4) e_ch1_conf = 1;

  `include "lite_chk.svh"

  // clock and clock-enable pins, signaling-mode pin
  `SVA_INV(a_ck_differential, ck_c == !ck_t)
  `SVA_INV(a_cke_high, cke)
  `SVA_INV(a_pam3_pin_is_mr2_0, !v_pam3_pin)
  `FC(read_pam3, e_rd_pam3)
  `FC(write_pam3, e_wr_pam3)
  `FC(read_line_written_in_other_mode, e_rd_other_mode)
  `FC(channel1_row_conflict, e_ch1_conf)
endmodule

bind GDDR7_Lite_top GDDR7_Lite_sva u_sva (.*);
