// SPDX-License-Identifier: Apache-2.0
/*verilator coverage_off*/
// DDR7 checker: 8 banks {haddr[8] channel, haddr[10:9]}, row haddr[31:18],
// 256 words per channel indexed by {channel, column}. Posted writes: the
// checker keeps its own 4-deep merge buffer; a host WR completes without pin
// activity unless the buffer is full, in which case its oldest entry must
// drain (as a WR with that entry's page, column and data) first; a RD must
// see every buffered entry drained, oldest first, before its own RD.
// Pins: {ras_n, cas_n, we_n} = 011 ACT, 101 RD, 100 WR, 010 PRE (addr[10]
// set: all banks), 001 REF. Shared page / timing / data model: mem_chk.svh.
`include "cov_macros.svh"
module DDR7_sva (
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
  localparam int CL = 30, TRCD = 18, TRP = 18, TRC = 68, TRAS = 44, TRFC = 290, TREFI = 9360;
  localparam int REF_MIN = TREFI - TRAS - TRP - 4;
  localparam int REF_MAX = TREFI + 5 * 2 * (TRC + TRP + TRCD + CL) + TRAS + TRP + 8;
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

  // model write buffer (oldest at 0)
  logic [31:0] mwb_a [0:3];
  logic [15:0] mwb_d [0:3];
  int          mwb_n;
  logic        pend;           // host WR waiting for the oldest entry to drain
  logic [31:0] pend_a;
  logic [15:0] pend_d;
  logic        e_merge, e_post, e_overflow, e_rd_flush, e_rd_flush4, e_drain_miss;
  task automatic mwb_push(input logic [31:0] a, input logic [15:0] d);
    mwb_a[mwb_n] = a; mwb_d[mwb_n] = d; mwb_n++;
  endtask
  `define MEM_CHK_DRAINING (mwb_n > 0 && (op_c == 3'd2 || op_c == 3'd3 && pend))
  `define MEM_CHK_DRAIN_A mwb_a[0]
  `define MEM_CHK_DRAIN_D mwb_d[0]
  `define MEM_CHK_DRAIN_POP \
    for (int i = 0; i < 3; i++) begin mwb_a[i] = mwb_a[i+1]; mwb_d[i] = mwb_d[i+1]; end \
    mwb_n--; \
    if (pend) begin mwb_push(pend_a, pend_d); pend = 0; end
  `define MEM_CHK_WR_DONE !pend
  `define MEM_CHK_ON_ACCEPT \
    {e_merge, e_post, e_overflow, e_rd_flush, e_rd_flush4} = '0; \
    if (hcmd == 3'd2) begin e_rd_flush = mwb_n > 0; e_rd_flush4 = mwb_n == 4; end \
    if (hcmd == 3'd3) begin : mwb_acc \
      int f; f = -1; \
      for (int i = 0; i < mwb_n; i++) if (cellof(mwb_a[i]) == cellof(haddr)) f = i; \
      if (f >= 0) begin mwb_a[f] = haddr; mwb_d[f] = hwdata; e_merge = 1; end \
      else if (mwb_n < 4) begin mwb_push(haddr, hwdata); e_post = 1; end \
      else begin pend = 1; pend_a = haddr; pend_d = hwdata; e_overflow = 1; end \
    end
  `define MEM_CHK_EXTRA e_drain_miss = drn && q_pc == P_ACT;
  always @(posedge clk) if (!rst_n) begin mwb_n = 0; pend = 0; end
  initial begin mwb_n = 0; pend = 0; end
  `include "mem_chk.svh"

  `SVA_INV(a_buffer_bound, mwb_n <= 4)
  `FC(write_merged_in_buffer, e_merge)
  `FC(write_posted, e_post)
  `FC(write_into_full_buffer, e_overflow)
  `FC(read_drains_buffer, e_rd_flush)
  `FC(read_drains_full_buffer, e_rd_flush4)
  `FC(drain_page_miss, e_drain_miss)

  `SVA_INV(a_ck_differential, ck_c == !ck_t)
endmodule

bind DDR7_top DDR7_sva u_sva (.*);
