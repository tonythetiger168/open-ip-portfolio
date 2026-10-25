// SPDX-License-Identifier: Apache-2.0
/*verilator coverage_off*/
// GDDR6 checker: 8 banks {haddr[8] channel, haddr[10:9]}, row haddr[31:18],
// 256 words per channel indexed by {channel, column}. A WR to column 0xF2
// sets the width mode (bit 0: x8) and must cause no pin traffic; in x8 mode
// a WR drives and stores only the low byte (the upper byte lanes are not
// part of the write).
// Pins: {ras_n, cas_n, we_n} = 011 ACT, 101 RD, 100 WR, 010 PRE (addr[10]
// set: all banks), 001 REF. Shared page / timing / data model: mem_chk.svh.
`include "cov_macros.svh"
module GDDR6_sva (
  input logic        clk, rst_n, hvalid, hready, hdone, ck_t, ck_c, ras_n, cas_n, we_n, cke,
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
  localparam int CL = 16, TRCD = 14, TRP = 14, TRC = 44, TRAS = 30, TRFC = 140, TREFI = 3900;
  localparam int REF_MIN = TREFI - TRAS - TRP - 4;
  localparam int REF_MAX = TREFI + 2 * (TRC + TRP + TRCD + CL) + TRAS + TRP + 8;
  localparam int BUSY_MAX = 2 * (TRC + TRP + TRCD + CL) + TRAS + TRP + TRFC + 8;
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
    return pa == {9'b0, c};
  endfunction

  logic [2:0]  q_pc;
  logic [16:0] q_pa;
  logic [31:0] q_dq;
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
    q_pa <= addr; q_dq <= dq;
  end

  logic x8_m, e_mb_x8, e_mb_x16, e_x8_wr;
  `define MEM_CHK_WMASK (x8_m ? 16'h00FF : 16'hFFFF)
  `define MEM_CHK_WR_DONE (s_rw || op_a[7:0] == 8'hF2)
  `define MEM_CHK_ON_ACCEPT \
    {e_mb_x8, e_mb_x16} = '0; \
    if (hcmd == 3'd3 && haddr[7:0] == 8'hF2) begin \
      x8_m = hwdata[0]; e_mb_x8 = hwdata[0]; e_mb_x16 = !hwdata[0]; op_v = 0; \
    end
  `define MEM_CHK_EXTRA e_x8_wr = q_pc == P_WR && x8_m;
  always @(posedge clk) if (!rst_n) x8_m = 0;
  initial x8_m = 0;
  `include "mem_chk.svh"

  `FC(mailbox_x8, e_mb_x8)
  `FC(mailbox_x16, e_mb_x16)
  `FC(write_in_x8_mode, e_x8_wr)

  `SVA_INV(a_ck_differential, ck_c == !ck_t)
endmodule

bind GDDR6_top GDDR6_sva u_sva (.*);
