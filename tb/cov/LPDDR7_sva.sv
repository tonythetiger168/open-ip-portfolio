// SPDX-License-Identifier: Apache-2.0
/*verilator coverage_off*/
// LPDDR7 checker: 8 banks ({haddr[8] channel, haddr[10:9]}), row haddr[31:18],
// 256 words per channel indexed by {channel, column}. Adaptive page: a
// 2-bit hit count per bank (hit +1, miss -1, host PRE clears); an RD / WR
// miss on a bank at count 0 must auto-precharge after its burst, any other
// burst must not. Per-bank refresh: the k-th REF refreshes bank k mod 8.
// Pins: {ras_n, cas_n, we_n} = 011 ACT, 101 RD, 100 WR, 010 PRE (addr[10]
// set: all banks), 001 REF. Shared page / timing / data model: mem_chk.svh.
`include "cov_macros.svh"
module LPDDR7_sva (
  input logic        clk, rst_n, hvalid, hready, hdone, ck_t, ck_c, ras_n, cas_n, we_n, cke,
  input logic        trace_valid,
  input logic [2:0]  hcmd, trace_cmd,
  input logic [31:0] haddr, trace_addr,
  input logic [15:0] hwdata, hrdata,
  input logic [16:0] addr,
  input logic [31:0] dq,
  input logic [1:0]  dqs,
  input logic [7:0]  ca,
  input logic        cs_n
);
  `COV_CLOCKING(clk, !rst_n)
  localparam int NB = 8, NCELLS = 512;
  localparam int CL = 28, TRCD = 15, TRP = 15, TRC = 52, TRAS = 38, TRFC = 160, TREFI = 1560;
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

  `define MEM_CHK_REF_PB
  localparam int REF_NB = 8;
  function automatic int ref_bank_of(input int k); return k; endfunction
  // adaptive page: per-bank 2-bit hit count; ap_m = this burst auto-closes
  int   hc_m [NB];
  logic ap_m, e_cold_close, e_warm_miss, e_hot_hit, e_act_hit;
  `define MEM_CHK_AP_OK ap_m
  `define MEM_CHK_AP_MUST ap_m
  `define MEM_CHK_ON_ACCEPT \
    ap_m = 0; {e_cold_close, e_warm_miss, e_hot_hit, e_act_hit} = '0; \
    case (hcmd) \
      3'd1: if (op_hit) begin \
              e_act_hit = 1; if (hc_m[op_b] != 3) hc_m[op_b] = hc_m[op_b] + 1; \
            end else if (op_open && hc_m[op_b] != 0) hc_m[op_b] = hc_m[op_b] - 1; \
      3'd2, 3'd3: if (op_hit) begin \
              e_hot_hit = hc_m[op_b] == 3; if (hc_m[op_b] != 3) hc_m[op_b] = hc_m[op_b] + 1; \
            end else begin \
              ap_m = hc_m[op_b] == 0; e_cold_close = ap_m; e_warm_miss = !ap_m; \
              if (hc_m[op_b] != 0) hc_m[op_b] = hc_m[op_b] - 1; \
            end \
      3'd4: hc_m[op_b] = 0; \
      default: ; \
    endcase
  always @(posedge clk) if (!rst_n) begin ap_m = 0; for (int i = 0; i < NB; i++) hc_m[i] = 0; end

  // CA frames (see the RTL): beat 0 = {code, bank} with cs_n low, then the
  // row (ACT) or column (RD / WR) LSB first, CAW bits a beat, cs_n high;
  // the bank is the model's (the refresh target for a refresh PRE / REF)
  localparam int CAW = 8, CABW = 3, CAPAD = 2, NA = 2, NC = 1;
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
      if (q_cs_n || q_ca != ((CAW'(q_pc) << (CAW - 3)) | (CAW'(eb) << CAPAD))) v_ca = 1; \
      ca_exp = (q_pc == P_ACT) ? q_pa[13:0] : {6'b0, q_pa[7:0]}; \
      ca_left = (q_pc == P_ACT) ? NA : (q_pc == P_RD || q_pc == P_WR) ? NC : 0; \
    end else begin \
      if (!q_cs_n) v_ca = 1; \
      if (ca_left != 0) begin \
        if (q_ca != ca_exp[CAW-1:0]) v_ca = 1; \
        ca_exp = ca_exp >> CAW; ca_left = ca_left - 1; \
      end else if (q_ca != 0) v_ca = 1; \
    end \
    
  always @(posedge clk) if (!rst_n) ca_left = 0;
  initial ca_left = 0;
  `include "mem_chk.svh"

  `SVA_INV(a_ca_frame_matches_command, !v_ca)
  `SVA_INV(a_ca_frames_do_not_overlap, !v_ca_overlap)
  `FC(auto_precharge_after_burst, e_apre)
  `FC(cold_miss_auto_closed, e_cold_close)
  `FC(warm_miss_stays_open, e_warm_miss)
  `FC(hit_on_hot_bank, e_hot_hit)
  `FC(act_to_open_row_counts_as_hit, e_act_hit)

  `SVA_INV(a_ck_differential, ck_c == !ck_t)
endmodule

bind LPDDR7_top LPDDR7_sva u_sva (.*);
