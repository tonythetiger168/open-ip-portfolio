// SPDX-License-Identifier: Apache-2.0
// ATB capture buffer: concurrent SVA against an independent fill/flush
// model (flush on afvalid with a new ATID, last_id on atlast) + functional
// coverage. The buffer is emptied only by a flush or reset.
`include "cov_macros.svh"
module ATB_sva #(parameter int DW = 32, DEPTH = 16) (
  input logic          clk, rst_n,
  input logic          atvalid, atready, atlast, afvalid, afready, ren, irq,
  input logic [DW-1:0] atdata, rdata,
  input logic [6:0]    atid, last_id,
  input logic [3:0]    raddr,
  input logic [4:0]    count
);
  `COV_CLOCKING(clk, !rst_n)
  logic [DW-1:0] shadow [0:DEPTH-1];
  logic [4:0]    m_cnt;
  logic [6:0]    m_id, m_last;
  wire flush = afvalid && atid != m_id;
  wire push  = atvalid && atready;
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin m_cnt <= 0; m_id <= 0; m_last <= 0; end
    else if (flush) begin m_cnt <= 0; m_id <= atid; end
    else if (push) begin
      shadow[m_cnt[3:0]] <= atdata;
      m_cnt <= m_cnt + 1;
      if (atlast) m_last <= atid;
    end
  end

  `SVA_RST(a_reset_empty, !rst_n, count == 0 && last_id == 0)
  `SVA_INV(a_flush_always_ready, afready)
  `SVA_IMP(a_ready_model, 1'b1, atready == (m_cnt < DEPTH && !flush))
  `SVA_IMP(a_count_model, 1'b1, count == m_cnt)
  `SVA_IMP(a_last_id_model, 1'b1, last_id == m_last)
  `SVA_IMP(a_irq_on_last, 1'b1, irq == (push && atlast))
  `SVA_IMP(a_read_model, ren && raddr < m_cnt, rdata == shadow[raddr])
  `SVA_NXT(a_flush_empties, flush, count == 0)

  covergroup cg_fill @(posedge clk);
    option.per_instance = 1;
    cp_level: coverpoint m_cnt iff (rst_n && push)
      { bins empty = {0}; bins partial = {[1:14]}; bins last_slot = {15}; }
    cp_last: coverpoint atlast iff (rst_n && push) { bins mid = {0}; bins last = {1}; }
    x_level_last: cross cp_level, cp_last;
    cp_flush_level: coverpoint m_cnt iff (rst_n && flush)
      { bins empty = {0}; bins partial = {[1:15]}; bins full = {16}; }
  endgroup
  cg_fill u_cg_fill = new;

  `FC(push_while_full, atvalid && !atready && m_cnt == DEPTH)
  `FC(beat_dropped_by_flush, atvalid && flush)
  `FC(flush_same_id_ignored, afvalid && atid == m_id)
  `FC(read_while_filling, ren && push)
  `FC_RST(reset_when_full, rst_n && m_cnt == DEPTH ##1 !rst_n)
endmodule

bind ATB_top ATB_sva #(.DW(DW), .DEPTH(DEPTH)) u_sva (.*);
