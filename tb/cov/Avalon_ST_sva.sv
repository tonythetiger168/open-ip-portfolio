// SPDX-License-Identifier: Apache-2.0
// Avalon_ST capture buffer: concurrent SVA against an independent fill model
// (16-word store, ready == not full, random-access read port) + functional
// coverage. The buffer is emptied only by reset (documented scope).
`include "cov_macros.svh"
module Avalon_ST_sva #(parameter int DW = 32, DEPTH = 16) (
  input logic          clk, rst_n,
  input logic          av_valid, av_ready, av_eop, ren, irq,
  input logic [DW-1:0] av_data, rdata,
  input logic [3:0]    raddr,
  input logic [4:0]    count
);
  `COV_CLOCKING(clk, !rst_n)
  wire push = av_valid && av_ready;
  logic [DW-1:0] shadow [0:DEPTH-1];
  logic [4:0]    m_cnt;
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) m_cnt <= 0;
    else if (push) begin
      shadow[m_cnt[3:0]] <= av_data;
      m_cnt <= m_cnt + 1;
    end
  end

  `SVA_RST(a_reset_empty, !rst_n, count == 0 && av_ready)
  `SVA_IMP(a_ready_not_full, 1'b1, av_ready == (m_cnt < DEPTH))
  `SVA_IMP(a_count_model, 1'b1, count == m_cnt)
  `SVA_IMP(a_irq_on_last, 1'b1, irq == (push && av_eop))
  `SVA_IMP(a_read_model, ren && raddr < m_cnt, rdata == shadow[raddr])
  `SVA_NXT(a_full_holds, m_cnt == DEPTH, count == DEPTH && !av_ready)

  covergroup cg_fill @(posedge clk);
    option.per_instance = 1;
    cp_level: coverpoint m_cnt iff (rst_n && push)
      { bins empty = {0}; bins partial = {[1:14]}; bins last_slot = {15}; }
    cp_last: coverpoint av_eop iff (rst_n && push) { bins mid = {0}; bins last = {1}; }
    x_level_last: cross cp_level, cp_last;
  endgroup
  cg_fill u_cg_fill = new;

  `FC(push_while_full, av_valid && !av_ready)
  `FC(read_while_filling, ren && push)
  `FC(idle_cycle_partial, !av_valid && m_cnt != 0 && m_cnt != DEPTH)
  `FC_RST(reset_when_full, rst_n && m_cnt == DEPTH ##1 !rst_n)
  `FC_RST(reset_when_partial, rst_n && m_cnt != 0 && m_cnt != DEPTH ##1 !rst_n)
endmodule

bind Avalon_ST_top Avalon_ST_sva #(.DW(DW), .DEPTH(DEPTH)) u_sva (.*);
