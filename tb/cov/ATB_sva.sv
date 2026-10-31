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

  // every slot written and read back, data classes in and out, packet
  // length (beats per atlast-terminated packet, reset by a flush)
  function automatic logic [1:0] dcls(input logic [DW-1:0] v);
    dcls = (v == '0) ? 2'd0 : (v == '1) ? 2'd1 :
           (v == {(DW/2){2'b01}} || v == {(DW/2){2'b10}}) ? 2'd2 : 2'd3;
  endfunction
  logic [4:0] m_pkt;
  always_ff @(posedge clk or negedge rst_n)
    if (!rst_n) m_pkt <= 0;
    else if (flush) m_pkt <= 0;
    else if (push) m_pkt <= atlast ? 5'd0 : (m_pkt == 5'd31 ? m_pkt : m_pkt + 1);
  covergroup cg_data @(posedge clk);
    option.per_instance = 1;
    cp_slot: coverpoint m_cnt[3:0] iff (rst_n && push) { bins s[] = {[0:DEPTH-1]}; }
    cp_rslot: coverpoint raddr iff (rst_n && ren && raddr < m_cnt) { bins s[] = {[0:DEPTH-1]}; }
    cp_wdata: coverpoint dcls(atdata) iff (rst_n && push)
      { bins zero = {0}; bins ones = {1}; bins alt = {2}; bins other = {3}; }
    cp_rdata: coverpoint dcls(rdata) iff (rst_n && ren && raddr < m_cnt)
      { bins zero = {0}; bins ones = {1}; bins alt = {2}; bins other = {3}; }
    cp_pktlen: coverpoint m_pkt iff (rst_n && push && atlast)
      { bins single = {0}; bins short_ = {[1:3]}; bins long_ = {[4:15]}; }
    cp_last2: coverpoint atlast iff (rst_n && push) { bins mid = {0}; bins last = {1}; }
    cp_id: coverpoint atid iff (rst_n && push)
      { bins zero = {0}; bins max = {7'h7F}; bins other = {[1:7'h7E]}; }
    x_id_last: cross cp_id, cp_last2;
  endgroup
  cg_data u_cg_data = new;

  `FC(push_while_full, atvalid && !atready && m_cnt == DEPTH)
  `FC(beat_dropped_by_flush, atvalid && flush)
  `FC(flush_same_id_ignored, afvalid && atid == m_id)
  `FC(read_while_filling, ren && push)
  `FC_RST(reset_when_full, rst_n && m_cnt == DEPTH ##1 !rst_n)
endmodule

bind ATB_top ATB_sva #(.DW(DW), .DEPTH(DEPTH)) u_sva (.*);
