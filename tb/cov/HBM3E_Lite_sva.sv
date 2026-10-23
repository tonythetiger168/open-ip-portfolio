// SPDX-License-Identifier: Apache-2.0
/*verilator coverage_off*/
// HBM3E_Lite checker: 32 entries = 8 pseudo-channels (haddr[11:9]) x 4
// banks (haddr[8:7]), row haddr[20:12], line haddr[6:4]; one 128-bit array
// line per {entry, row, line}; haddr[31:21] must be 0. Pins as HBM3E_Lite
// with the pseudo-channel on addr[13:11] and the bank on ba; REF with
// addr[10] = 0 refreshes one entry, with addr[10] = 1 all of them. Shared
// line-controller model lite_chk.svh with the per-entry refresh model
// (LITE_PBREF): entry r falls due at the r-th tREFI of each rotation.
`include "cov_macros.svh"
module HBM3E_Lite_sva (
  input logic        clk, rst_n, hvalid, hready, hdone, irq,
  input logic [2:0]  pc_act,
  input logic        ck_t, ck_c, cke, cs_n, act_n, ras_n, cas_n, we_n,
  input logic        trace_valid,
  input logic [2:0]  hcmd,
  input logic [3:0]  trace_cmd,
  input logic [31:0] haddr, trace_addr,
  input logic [15:0] hwdata, hrdata,
  input logic [1:0]  ba,
  input logic [13:0] addr,
  input logic [15:0] dq,
  input logic [1:0]  dqs,
  input logic        dq_oe, dqs_oe     // output enables (DUT internals)
);
  `COV_CLOCKING(clk, !rst_n)
  localparam int NB = 32, NLINES = 32 * 512 * 8;
  localparam int T_RCD = 6, T_RP = 6, T_RC = 40, T_RAS = 16, T_RRD = 3, T_WR = 8,
                 T_WTR = 8, T_RFC = 40, T_RFC_PB = 20, T_REFI = 150, CL0 = 11, CWL0 = 8;
  localparam int REF_LAT = 2 * (T_RAS + T_RP + T_RCD + 20 + 8 + T_WR) + 16;
  localparam int BUSY_MAX = REF_LAT + T_RFC + 2 * (T_RAS + T_RP + T_RCD + 20 + 8 + T_WR) + 16;

  function automatic int bank_of(input logic [31:0] a); return int'(a[11:7]); endfunction
  function automatic int row_of(input logic [31:0] a); return int'(a[20:12]); endfunction
  function automatic int line_of(input logic [31:0] a); return int'(a[6:4]); endfunction
  function automatic int idx_of(input logic [31:0] a); return int'({a[11:7], a[20:12], a[6:4]}); endfunction
  function automatic logic in_range(input logic [31:0] a); return a[31:21] == 0; endfunction

  logic        q_cs_n, q_act_n, q_ras_n, q_cas_n, q_we_n, q_hready, q_hdone, q_irq, q_tv,
               q_dq_oe, q_dqs_oe;
  logic [1:0]  q_ba, q_dqs;
  logic [13:0] q_addr;
  logic [15:0] q_dq, q_hrdata;
  logic [3:0]  q_tc;
  logic [2:0]  q_pc;
  logic [31:0] q_ta;
  always @(negedge clk) begin
    q_cs_n <= cs_n; q_act_n <= act_n; q_ras_n <= ras_n; q_cas_n <= cas_n; q_we_n <= we_n;
    q_ba <= ba; q_addr <= addr; q_dq <= dq; q_dqs <= dqs;
    q_hready <= hready; q_hdone <= hdone; q_hrdata <= hrdata; q_irq <= irq;
    q_dq_oe <= dq_oe; q_dqs_oe <= dqs_oe;
    q_pc <= pc_act;
    q_tv <= trace_valid; q_tc <= trace_cmd; q_ta <= trace_addr;
  end
  wire [4:0] pin_bank = {q_addr[13:11], q_ba};

  logic v_pc, e_pb_wrap, e_pb_last;
`define LITE_PBREF
`define LITE_ACT_ADDR(a) {a[11:9], 2'b00, a[20:12]}
`define LITE_RW_ADDR(a) {a[11:9], 4'b0000, a[6:4], 4'h0}
`define LITE_PRE_ADDR(b) {3'(b >> 2), 11'h000}
`define LITE_MRW(i, d) d[7:0]
`define LITE_NO_DLL
`define LITE_EXTRA \
      v_pc = (pc == C_ACT || pc == C_RD || pc == C_WR || pc == C_PRE || \
              pc == C_REF && !q_addr[10]) && q_pc !== 3'(b >> 2); \
      e_pb_last = pc == C_REF && !q_addr[10] && b == NB - 1; \
      e_pb_wrap = refi_m == 0 && rot_m == NB - 1;

  `include "lite_chk.svh"

  // clock and clock-enable pins
  `SVA_INV(a_ck_differential, ck_c == !ck_t)
  `SVA_INV(a_cke_high, cke)
  // debug pseudo-channel output follows the entry the pins address
  `SVA_INV(a_pc_act, !v_pc)
  `FC(refresh_last_entry, e_pb_last)
  `FC(refresh_rotation_wraps, e_pb_wrap)
endmodule

bind HBM3E_Lite_top HBM3E_Lite_sva u_sva (.*);
