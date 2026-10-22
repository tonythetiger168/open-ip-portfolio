// SPDX-License-Identifier: Apache-2.0
// AXI_Stream capture buffer: concurrent SVA against an independent fill model
// (16-word store, ready == not full, random-access read port) + functional
// coverage. The buffer is emptied only by reset (documented scope).
`include "cov_macros.svh"
module AXI_Stream_sva #(parameter int DW = 32, DEPTH = 16) (
  input logic          clk, rst_n,
  input logic          tvalid, tready, tlast, ren, irq,
  input logic [DW-1:0] tdata, rdata,
  input logic [3:0]    raddr,
  input logic [4:0]    count
);
  `COV_CLOCKING(clk, !rst_n)
  wire push = tvalid && tready;
  logic [DW-1:0] shadow [0:DEPTH-1];
  logic [4:0]    m_cnt;
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) m_cnt <= 0;
    else if (push) begin
      shadow[m_cnt[3:0]] <= tdata;
      m_cnt <= m_cnt + 1;
    end
  end

  `SVA_RST(a_reset_empty, !rst_n, count == 0 && tready)
  `SVA_IMP(a_ready_not_full, 1'b1, tready == (m_cnt < DEPTH))
  `SVA_IMP(a_count_model, 1'b1, count == m_cnt)
  `SVA_IMP(a_irq_on_last, 1'b1, irq == (push && tlast))
  `SVA_IMP(a_read_model, ren && raddr < m_cnt, rdata == shadow[raddr])
  `SVA_NXT(a_full_holds, m_cnt == DEPTH, count == DEPTH && !tready)

  covergroup cg_fill @(posedge clk);
    option.per_instance = 1;
    cp_level: coverpoint m_cnt iff (rst_n && push)
      { bins empty = {0}; bins partial = {[1:14]}; bins last_slot = {15}; }
    cp_last: coverpoint tlast iff (rst_n && push) { bins mid = {0}; bins last = {1}; }
    x_level_last: cross cp_level, cp_last;
  endgroup
  cg_fill u_cg_fill = new;

  `FC(push_while_full, tvalid && !tready)
  `FC(read_while_filling, ren && push)
  `FC(idle_cycle_partial, !tvalid && m_cnt != 0 && m_cnt != DEPTH)
  `FC_RST(reset_when_full, rst_n && m_cnt == DEPTH ##1 !rst_n)
  `FC_RST(reset_when_partial, rst_n && m_cnt != 0 && m_cnt != DEPTH ##1 !rst_n)
endmodule

bind AXI_Stream_top AXI_Stream_sva #(.DW(DW), .DEPTH(DEPTH)) u_sva (.*);
