// SPDX-License-Identifier: Apache-2.0
/*verilator coverage_off*/
// HBM3 checker: 128 page entries {haddr[10:8] channel, haddr[14:11] pc}, row
// haddr[31:18], 256 words per channel indexed by {channel, column}.
// Per-entry refresh: the k-th REF refreshes entry k mod 128.
// Pins: {ras_n, cas_n, we_n} = 011 ACT, 101 RD, 100 WR, 010 PRE (addr[10]
// set: all banks), 001 REF. Shared page / timing / data model: mem_chk.svh.
`include "cov_macros.svh"
module HBM3_sva (
  input logic        clk, rst_n, hvalid, hready, hdone, ck_t, ck_c, ras_n, cas_n, we_n, cke,
  input logic        trace_valid,
  input logic [2:0]  hcmd, trace_cmd,
  input logic [31:0] haddr, trace_addr,
  input logic [15:0] hwdata, hrdata,
  input logic [16:0] addr,
  input logic [127:0] dq,
  input logic [1:0]  dqs
);
  `COV_CLOCKING(clk, !rst_n)
  localparam int NB = 128, NCELLS = 2048;
  localparam int CL = 10, TRCD = 9, TRP = 9, TRC = 30, TRAS = 20, TRFC = 110, TREFI = 1560;
  localparam int REF_MIN = TREFI - TRAS - TRP - 4;
  localparam int REF_MAX = TREFI + 2 * (TRC + TRP + TRCD + CL) + TRAS + TRP + 8;
  localparam int BUSY_MAX = 2 * (TRC + TRP + TRCD + CL) + TRAS + TRP + TRFC + 8;
  localparam logic [2:0] P_NOP = 0, P_ACT = 1, P_RD = 2, P_WR = 3, P_PRE = 4, P_PREA = 5,
                         P_REF = 6, P_BAD = 7;

  function automatic int bank_of(input logic [31:0] a); return int'({a[10:8], a[14:11]}); endfunction
  function automatic logic [13:0] row_of(input logic [31:0] a); return a[31:18]; endfunction
  function automatic logic [7:0] col_of(input logic [31:0] a); return a[7:0]; endfunction
  function automatic int cellof(input logic [31:0] a); return int'({a[10:8], a[7:0]}); endfunction
  function automatic logic pin_row_ok(input logic [16:0] pa, input logic [13:0] r);
    return pa == {3'b0, r};
  endfunction
  function automatic logic pin_col_ok(input logic [16:0] pa, input logic [7:0] c);
    return pa == {9'b0, c};
  endfunction

  logic [2:0]  q_pc;
  logic [16:0] q_pa;
  logic [127:0] q_dq;
  function automatic logic [15:0] lane(input logic [31:0] a); return q_dq[16 * a[10:8] +: 16]; endfunction
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

  `define MEM_CHK_REF_PB
  localparam int REF_NB = 128;
  function automatic int ref_bank_of(input int k); return k; endfunction
  `include "mem_chk.svh"

  `SVA_INV(a_ck_differential, ck_c == !ck_t)
endmodule

bind HBM3_top HBM3_sva u_sva (.*);
