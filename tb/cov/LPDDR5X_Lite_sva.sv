// SPDX-License-Identifier: Apache-2.0
/*verilator coverage_off*/
// LPDDR5X_Lite checker: 8 banks (haddr[9:7]), row haddr[18:10], line
// haddr[6:4]; one 128-bit array line per {bank, row, line}; haddr[31:19]
// must be 0 for READ / WRITE. Pins as DDR4_Lite with a 3-bit ba; REF with
// addr[10] = 0 refreshes one bank, with addr[10] = 1 all of them. Shared
// line-controller model lite_chk.svh with the per-entry refresh model
// (LITE_PBREF) and host bank refresh (hcmd 6); here: two FSP register
// sets (the model swaps the active and the other set on FSPW, so CL / CWL
// and MRR follow the active set), the fsp pin, and WCK: wck_t toggles on
// every clock from the clock after a WR through its last data beat (CWL +
// 7 clocks after the WR) and is high otherwise; wck_c = !wck_t.
`include "cov_macros.svh"
module LPDDR5X_Lite_sva (
  input logic        clk, rst_n, hvalid, hready, hdone, irq,
  input logic        fsp, wck_t, wck_c,
  input logic        ck_t, ck_c, cke, cs_n, act_n, ras_n, cas_n, we_n,
  input logic        trace_valid,
  input logic [2:0]  hcmd,
  input logic [3:0]  trace_cmd,
  input logic [31:0] haddr, trace_addr,
  input logic [15:0] hwdata, hrdata,
  input logic [127:0] rdline,
  input logic [2:0]  ba,
  input logic [13:0] addr,
  input logic [15:0] dq,
  input logic [1:0]  dqs,
  input logic        dq_oe, dqs_oe     // output enables (DUT internals)
);
  `COV_CLOCKING(clk, !rst_n)
  localparam int NB = 8, NLINES = 8 * 512 * 8;
  localparam int T_RCD = 6, T_RP = 6, T_RC = 40, T_RAS = 16, T_RRD = 3, T_WR = 8,
                 T_WTR = 8, T_RFC = 40, T_RFC_PB = 20, T_REFI = 150, CL0 = 11, CWL0 = 8;
  localparam int REF_LAT = 2 * (T_RAS + T_RP + T_RCD + 20 + 8 + T_WR) + 16;
  localparam int BUSY_MAX = REF_LAT + T_RFC + 2 * (T_RAS + T_RP + T_RCD + 20 + 8 + T_WR) + 16;

  function automatic int bank_of(input logic [31:0] a); return int'(a[9:7]); endfunction
  function automatic int row_of(input logic [31:0] a); return int'(a[18:10]); endfunction
  function automatic int line_of(input logic [31:0] a); return int'(a[6:4]); endfunction
  function automatic int idx_of(input logic [31:0] a); return int'({a[9:7], a[18:10], a[6:4]}); endfunction
  function automatic logic in_range(input logic [31:0] a); return a[31:19] == 0; endfunction

  logic        q_cs_n, q_act_n, q_ras_n, q_cas_n, q_we_n, q_hready, q_hdone, q_irq, q_tv,
               q_dq_oe, q_dqs_oe;
  logic [2:0]  q_ba;
  logic [1:0]  q_dqs;
  logic [13:0] q_addr;
  logic [15:0] q_dq, q_hrdata;
  logic [3:0]  q_tc;
  logic        q_fsp, q_wck_t, q_wck_c;
  logic [31:0] q_ta;
  always @(negedge clk) begin
    q_cs_n <= cs_n; q_act_n <= act_n; q_ras_n <= ras_n; q_cas_n <= cas_n; q_we_n <= we_n;
    q_ba <= ba; q_addr <= addr; q_dq <= dq; q_dqs <= dqs;
    q_hready <= hready; q_hdone <= hdone; q_hrdata <= hrdata; q_irq <= irq;
    q_dq_oe <= dq_oe; q_dqs_oe <= dqs_oe;
    q_fsp <= fsp; q_wck_t <= wck_t; q_wck_c <= wck_c;
    q_tv <= trace_valid; q_tc <= trace_cmd; q_ta <= trace_addr;
  end
  wire [2:0] pin_bank = q_ba;

  logic [7:0] mr_o [8];                // the inactive FSP register set
  logic       fsp_m, p_wck;
  longint     wck_s, wck_e;            // WCK run window
  logic v_fsp, v_wck, e_fspw, e_fsp1_cl, e_mrw_fsp1, e_hpb_open;
`define LITE_PBREF
`define LITE_MRW(i, d) d[7:0]
`define LITE_NO_DLL
`define LITE_RESET \
      for (int i = 0; i < 8; i++) mr_o[i] = 0; \
      mr_o[0] = 8'(CL0 - 5); mr_o[1] = 8'(CWL0 - 5); \
      fsp_m = 0; p_wck = 1; wck_s = 0; wck_e = -1; \
      {v_fsp, v_wck, e_fspw, e_fsp1_cl, e_mrw_fsp1, e_hpb_open} = '0;
`define LITE_HCMD67 \
            3'd6: begin \
              op_v = 1; op_k = 3'd6; op_a = haddr; op_b = int'(haddr[9:7]); \
              s_act = 0; s_pre = 0; s_rw = 0; s_data = 0; s_ref = 0; \
              e_hpb_open = open_m[op_b]; \
            end \
            3'd7: begin \
              if (hwdata[0] !== fsp_m) begin \
                for (int i = 0; i < 8; i++) {mr_m[i], mr_o[i]} = {mr_o[i], mr_m[i]}; \
                fsp_m = hwdata[0]; e_fspw = 1; \
              end \
              imm_at = n + 1; imm_mrr = 0; \
            end
`define LITE_EXTRA \
      e_fspw = 0; e_hpb_open = 0; \
      v_fsp = q_fsp !== fsp_m; \
      v_wck = q_wck_c !== !q_wck_t || \
              ((n >= wck_s && n <= wck_e) ? q_wck_t === p_wck : q_wck_t !== 1'b1); \
      p_wck = q_wck_t; \
      if (pc == C_WR) begin wck_s = n + 1; wck_e = n + `LITE_CWL_OF + 7; end \
      e_fsp1_cl = pc == C_RD && fsp_m && `LITE_CL_OF != CL0; \
      e_mrw_fsp1 = hvalid && q_hready && !filling && hcmd == 3'd3 && fsp_m;

`define LITE_ACT_HI_ZERO
  `include "lite_chk.svh"

  // clock and clock-enable pins
  `SVA_INV(a_ck_differential, ck_c == !ck_t)
  `SVA_INV(a_cke_high, cke)
  `SVA_INV(a_fsp_pin, !v_fsp)
  `SVA_INV(a_wck_runs_through_write_path, !v_wck)
  `FC(fsp_switch, e_fspw)
  `FC(read_with_fsp1_cl, e_fsp1_cl)
  `FC(mode_register_write_fsp1, e_mrw_fsp1)
  `FC(host_bank_refresh, e_href_pb)
  `FC(host_bank_refresh_open_bank, e_hpb_open)
endmodule

bind LPDDR5X_Lite_top LPDDR5X_Lite_sva u_sva (.*);
