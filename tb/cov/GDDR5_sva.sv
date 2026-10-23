// SPDX-License-Identifier: Apache-2.0
/*verilator coverage_off*/
// GDDR5 checker: 8 banks (haddr[11:9]), row haddr[31:18], 256-word array indexed
// by the column. Write-to-read: a RD to a bank waits tWTR after the end of
// the last write burst to it (WR command + CL).
// Pins: {ras_n, cas_n, we_n} = 011 ACT, 101 RD, 100 WR, 010 PRE (addr[10]
// set: all banks), 001 REF. Shared page / timing / data model: mem_chk.svh.
`include "cov_macros.svh"
module GDDR5_sva (
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
  localparam int NB = 8, NCELLS = 256;
  localparam int CL = 13, TRCD = 13, TRP = 13, TRC = 39, TRAS = 26, TRFC = 100, TREFI = 3900;
  localparam int REF_MIN = TREFI - TRAS - TRP - 4;
  localparam int REF_MAX = TREFI + 2 * (TRC + TRP + TRCD + CL) + TRAS + TRP + 8;
  localparam int BUSY_MAX = 2 * (TRC + TRP + TRCD + CL) + TRAS + TRP + TRFC + 8;
  localparam logic [2:0] P_NOP = 0, P_ACT = 1, P_RD = 2, P_WR = 3, P_PRE = 4, P_PREA = 5,
                         P_REF = 6, P_BAD = 7;

  function automatic int bank_of(input logic [31:0] a); return int'(a[11:9]); endfunction
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

  localparam int TWTR = 7;
  longint t_wend [0:7];
  logic   v_twtr, e_wtr_bound;
  `define MEM_CHK_EXTRA \
    v_twtr = 0; e_wtr_bound = 0; \
    if (q_pc == P_WR && op_v) t_wend[b] = n + CL; \
    if (q_pc == P_RD && op_v) begin \
      if (n < t_wend[b] + TWTR) v_twtr = 1; \
      e_wtr_bound = n <= t_wend[b] + TWTR + 2; \
    end
  always @(posedge clk) if (!rst_n) for (int i = 0; i < 8; i++) t_wend[i] = -1000;
  `include "mem_chk.svh"

  `SVA_INV(a_twtr_same_bank, !v_twtr)
  `FC(read_held_by_twtr, e_wtr_bound)

  `SVA_INV(a_ck_differential, ck_c == !ck_t)
endmodule

bind GDDR5_top GDDR5_sva u_sva (.*);
