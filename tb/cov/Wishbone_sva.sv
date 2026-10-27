// SPDX-License-Identifier: Apache-2.0
// Wishbone B4 pipelined slave: concurrent SVA against an independent
// 2-deep in-order request model (fast/slow/hole/reserved windows, classic
// re-accept guard, regfile shadow with SEL merge) + functional coverage.
`include "cov_macros.svh"
module Wishbone_sva #(parameter int DW = 32, AW = 32) (
  input logic          clk, rst_n,
  input logic          cyc_i, stb_i, we_i,
  input logic [AW-1:0] adr_i,
  input logic [DW-1:0] dat_i, dat_o,
  input logic [3:0]    sel_i,
  input logic [2:0]    cti_i,
  input logic          ack_o, stall_o, err_o, rty_o, irq
);
  `COV_CLOCKING(clk, !rst_n)
  wire a_ok  = adr_i < 32'h400;
  wire a_rsv = adr_i >= 32'h800;
  wire a_slow = a_ok && adr_i[9];

  // ---------------- independent reference model ----------------
  logic [DW-1:0] shadow [0:255];       // regfile is not reset
  initial for (int i = 0; i < 256; i++) shadow[i] = '0;
  logic          mq_we [2], mq_ok [2], mq_rsv [2], mq_slow [2];
  logic [7:0]    mq_idx [2];
  logic [3:0]    mq_sel [2];
  logic [DW-1:0] mq_dat [2];
  logic [1:0]    m_cnt, m_age;
  logic          m_blk;
  wire acc  = cyc_i && stb_i && m_cnt != 2 && !m_blk;
  wire resp = m_cnt != 0 && (mq_slow[0] ? m_age == 2 : m_age == 0);
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      m_cnt <= 0; m_age <= 0; m_blk <= 0;
      for (int i = 0; i < 2; i++) begin
        mq_we[i] <= 0; mq_ok[i] <= 0; mq_rsv[i] <= 0; mq_slow[i] <= 0;
        mq_idx[i] <= 0; mq_sel[i] <= 0; mq_dat[i] <= 0;
      end
    end else begin
      if (acc && cti_i == 3'b000) m_blk <= 1;
      else if (!stb_i || (resp && m_cnt == 1)) m_blk <= 0;
      if (resp && mq_ok[0] && mq_we[0])
        for (int b = 0; b < 4; b++)
          if (mq_sel[0][b]) shadow[mq_idx[0]][8*b +: 8] <= mq_dat[0][8*b +: 8];
      m_age <= resp ? 2'd0 : (m_cnt != 0) ? m_age + 1 : 2'd0;
      if (resp) begin
        mq_we[0] <= mq_we[1]; mq_ok[0] <= mq_ok[1]; mq_rsv[0] <= mq_rsv[1];
        mq_slow[0] <= mq_slow[1]; mq_idx[0] <= mq_idx[1]; mq_sel[0] <= mq_sel[1];
        mq_dat[0] <= mq_dat[1];
      end
      if (acc) begin
        automatic int slot = int'(m_cnt) - int'(resp);
        mq_we[slot] <= we_i; mq_ok[slot] <= a_ok; mq_rsv[slot] <= a_rsv;
        mq_slow[slot] <= a_slow; mq_idx[slot] <= adr_i[9:2]; mq_sel[slot] <= sel_i;
        mq_dat[slot] <= dat_i;
      end
      m_cnt <= m_cnt + 2'(acc) - 2'(resp);
    end
  end

  // ---------------- assertions ----------------
  `SVA_RST(a_reset_quiet, !rst_n, !ack_o && !err_o && !stall_o && !irq)
  `SVA_INV(a_rty_tied_off, !rty_o)
  `SVA_IMP(a_stall_when_full, 1'b1, stall_o == (m_cnt == 2))
  `SVA_IMP(a_resp_timing, 1'b1, (ack_o || err_o) == resp)
  `SVA_IMP(a_err_reserved, resp, err_o == mq_rsv[0] && ack_o == !mq_rsv[0])
  `SVA_IMP(a_read_data, ack_o && !mq_we[0], dat_o == (mq_ok[0] ? shadow[mq_idx[0]] : '0))
  `SVA_NXT(a_irq_sticky, irq, irq)
  `SVA_NXT(a_irq_on_err, err_o, irq)
  `SVA_IMP(a_irq_cause, $rose(irq), $past(err_o))

  // ---------------- functional coverage ----------------
  covergroup cg_req @(posedge clk);
    option.per_instance = 1;
    cp_region: coverpoint {a_rsv, a_ok, a_slow} iff (rst_n && acc)
      { bins fast = {3'b010}; bins slow = {3'b011}; bins hole = {3'b000}; bins rsv = {3'b100}; }
    cp_we: coverpoint we_i iff (rst_n && acc) { bins rd = {0}; bins wr = {1}; }
    cp_cti: coverpoint cti_i iff (rst_n && acc)
      { bins classic = {3'b000}; bins incr = {3'b010}; bins other = default; }
    cp_sel: coverpoint sel_i iff (rst_n && acc && we_i)
      { bins full = {4'hF}; bins none = {0}; bins partial = default; }
    cp_depth: coverpoint m_cnt iff (rst_n && acc) { bins empty = {0}; bins one = {1}; }
    x_region_we: cross cp_region, cp_we;
  endgroup
  cg_req u_cg_req = new;

  // at the response: window class x direction, byte lanes and data classes
  // of in-range accesses; at accept: cycle type x direction and the
  // direction of the request queued behind an outstanding one
  function automatic logic [1:0] dcls(input logic [DW-1:0] v);
    dcls = (v == '0) ? 2'd0 : (v == '1) ? 2'd1 :
           (v == {(DW/2){2'b01}} || v == {(DW/2){2'b10}}) ? 2'd2 : 2'd3;
  endfunction
  covergroup cg_resp @(posedge clk);
    option.per_instance = 1;
    cp_win: coverpoint {mq_rsv[0], mq_ok[0], mq_slow[0]} iff (rst_n && resp)
      { bins fast = {3'b010}; bins slow = {3'b011}; bins hole = {3'b000}; bins rsv = {3'b100}; }
    cp_we: coverpoint mq_we[0] iff (rst_n && resp) { bins rd = {0}; bins wr = {1}; }
    x_win_we: cross cp_win, cp_we;
    cp_lane: coverpoint mq_sel[0] iff (rst_n && resp && mq_ok[0] && mq_we[0])
      { bins b0 = {4'b0001}; bins b1 = {4'b0010}; bins b2 = {4'b0100}; bins b3 = {4'b1000};
        bins lo_half = {4'b0011}; bins hi_half = {4'b1100}; }
    cp_wdata: coverpoint dcls(mq_dat[0]) iff (rst_n && resp && mq_ok[0] && mq_we[0] && mq_sel[0] == 4'hF)
      { bins zero = {0}; bins ones = {1}; bins alt = {2}; bins other = {3}; }
    cp_rdata: coverpoint dcls(dat_o) iff (rst_n && resp && mq_ok[0] && !mq_we[0])
      { bins zero = {0}; bins ones = {1}; bins alt = {2}; bins other = {3}; }
  endgroup
  cg_resp u_cg_resp = new;
  covergroup cg_acc @(posedge clk);
    option.per_instance = 1;
    cp_cti: coverpoint cti_i iff (rst_n && acc) { bins classic = {3'b000}; bins incr = {3'b010}; }
    cp_we: coverpoint we_i iff (rst_n && acc) { bins rd = {0}; bins wr = {1}; }
    x_cti_we: cross cp_cti, cp_we;
    cp_queued: coverpoint {mq_we[0], we_i} iff (rst_n && acc && m_cnt == 1 && !resp)
      { bins rd_rd = {2'b00}; bins rd_wr = {2'b01}; bins wr_rd = {2'b10}; bins wr_wr = {2'b11}; }
  endgroup
  cg_acc u_cg_acc = new;

  `FC(stalled_strobe, cyc_i && stb_i && stall_o)
  `FC(accept_with_response, acc && resp)
  `FC(classic_block_held_stb, acc && cti_i == 3'b000 && $past(ack_o && stb_i && cti_i == 3'b000))
  `FC(classic_strobe_held, cyc_i && stb_i && m_blk && !resp)
  `FC(slow_behind_fast, acc && a_slow && m_cnt == 1 && !mq_slow[0])
  `FC(fast_behind_slow, acc && !a_slow && m_cnt == 1 && mq_slow[0])
  `FC_RST(reset_with_queue, rst_n && m_cnt == 2 ##1 !rst_n)
endmodule

bind Wishbone_top Wishbone_sva #(.DW(DW), .AW(AW)) u_sva (.*);
