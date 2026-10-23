// SPDX-License-Identifier: Apache-2.0
/*verilator coverage_off*/
// DDR4_Lite checker: 4 banks (haddr[8:7]), row haddr[17:9], line
// haddr[6:4]; one 128-bit array line per {bank, row, line}; haddr[31:18]
// must be 0. Pins: cs_n low with act_n low = ACT (row on addr); otherwise
// {ras_n, cas_n, we_n} = 010 PRE (addr[10]: all banks), 101 RD, 100 WR,
// 001 REF; RD / WR carry {line, 4'h0} on addr. Shared line-controller
// model: lite_chk.svh.
`include "cov_macros.svh"
module DDR4_Lite_sva (
  input logic        clk, rst_n, hvalid, hready, hdone, irq,
  input logic        ck_t, ck_c, cke, cs_n, act_n, ras_n, cas_n, we_n,
  input logic        trace_valid,
  input logic [2:0]  hcmd, trace_cmd,
  input logic [31:0] haddr, trace_addr,
  input logic [15:0] hwdata, hrdata,
  input logic [127:0] rdline,
  input logic [1:0]  ba,
  input logic [13:0] addr,
  input logic [15:0] dq,
  input logic [1:0]  dqs,
  input logic        dq_oe, dqs_oe     // output enables (DUT internals)
);
  `COV_CLOCKING(clk, !rst_n)
  localparam int NB = 4, NLINES = 4 * 512 * 8;
  localparam int T_RCD = 6, T_RP = 6, T_RC = 40, T_RAS = 16, T_RRD = 3, T_WR = 8,
                 T_WTR = 8, T_RFC = 40, T_REFI = 400, CL0 = 11, CWL0 = 8;
  localparam int REF_LAT = 2 * (T_RAS + T_RP + T_RCD + 20 + 8 + T_WR) + 16;
  localparam int BUSY_MAX = REF_LAT + T_RFC + 2 * (T_RAS + T_RP + T_RCD + 20 + 8 + T_WR) + 16;

  function automatic int bank_of(input logic [31:0] a); return int'(a[8:7]); endfunction
  function automatic int row_of(input logic [31:0] a); return int'(a[17:9]); endfunction
  function automatic int line_of(input logic [31:0] a); return int'(a[6:4]); endfunction
  function automatic int idx_of(input logic [31:0] a); return int'({a[8:7], a[17:9], a[6:4]}); endfunction
  function automatic logic in_range(input logic [31:0] a); return a[31:18] == 0; endfunction

  logic        q_cs_n, q_act_n, q_ras_n, q_cas_n, q_we_n, q_hready, q_hdone, q_irq, q_tv,
               q_dq_oe, q_dqs_oe;
  logic [1:0]  q_ba, q_dqs;
  logic [13:0] q_addr;
  logic [15:0] q_dq, q_hrdata;
  logic [2:0]  q_tc;
  logic [31:0] q_ta;
  always @(negedge clk) begin
    q_cs_n <= cs_n; q_act_n <= act_n; q_ras_n <= ras_n; q_cas_n <= cas_n; q_we_n <= we_n;
    q_ba <= ba; q_addr <= addr; q_dq <= dq; q_dqs <= dqs;
    q_hready <= hready; q_hdone <= hdone; q_hrdata <= hrdata; q_irq <= irq;
    q_dq_oe <= dq_oe; q_dqs_oe <= dqs_oe;
    q_tv <= trace_valid; q_tc <= trace_cmd; q_ta <= trace_addr;
  end
  wire [1:0] pin_bank = q_ba;

  `include "lite_chk.svh"

  // clock and clock-enable pins
  `SVA_INV(a_ck_differential, ck_c == !ck_t)
  `SVA_INV(a_cke_high, cke)
endmodule

bind DDR4_Lite_top DDR4_Lite_sva u_sva (.*);
