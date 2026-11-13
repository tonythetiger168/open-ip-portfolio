// SPDX-License-Identifier: Apache-2.0
// Interrupt_Controller (32 sources, CPU interrupt, event log written by
// soc_ss_axi_engine): concurrent SVA against an independent model of
// PENDING / CLAIM / cpu_irq, the rising-edge record queue (lowest id first,
// merged re-arms, dropped while LOG_EN is 0), the free-running timestamp,
// the ring slot (wrap at LOG_WORDS, back to 0 when LOG_WORDS is lowered)
// and LOG_WP, fed by the input pins, + functional coverage. The engine is
// closed by its own run.
`include "cov_macros.svh"
module Interrupt_Controller_sva (
  input logic        clk, rst_n, log_en, cpu_irq, log_err,
  input logic [31:0] irq_src, enable, sw_set, log_base, pending, claim,
  input logic [15:0] log_words, log_wp,
  input logic        e_busy, e_done, e_err, ws_valid, ws_ready, rs_ready,
  input logic [31:0] ws_data
);
  `COV_CLOCKING(clk, !rst_n)
  wire [31:0] m_p = (irq_src | sw_set) & enable;
  logic [31:0] m_pq, m_tolog;
  logic [23:0] m_ts;
  logic [15:0] m_slot, m_wp;
  logic [4:0]  m_lid, m_lidq;
  logic        m_lv;
  always_comb begin
    m_lid = 0; m_lv = 0;
    for (int i = 31; i >= 0; i--) if (m_tolog[i]) begin m_lid = 5'(i); m_lv = 1; end
  end
  wire        m_go = log_en && m_lv && !e_busy && !e_done && log_words != 0;
  wire [15:0] m_ws = m_slot >= log_words ? 16'd0 : m_slot;
  wire [31:0] m_rise = m_p & ~m_pq;
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin m_pq <= 0; m_tolog <= 0; m_ts <= 0; m_slot <= 0; m_wp <= 0; m_lidq <= 0; end
    else begin
      m_ts <= m_ts + 1;
      m_pq <= m_p;
      m_tolog <= log_en ? ((m_tolog & ~(m_go ? 32'd1 << m_lid : 32'd0)) | m_rise) : 32'd0;
      if (m_go) m_lidq <= m_lid;
      if (e_done) begin
        m_wp <= m_wp + 1;
        m_slot <= (32'(m_ws) + 1 >= 32'(log_words)) ? 16'd0 : m_ws + 1;
      end
    end
  end
  function automatic logic [31:0] m_claim(input logic [31:0] p);
    m_claim = 0;
    for (int i = 31; i >= 0; i--) if (p[i]) m_claim = {1'b1, 26'd0, 5'(i)};
  endfunction

  `SVA_RST(a_reset_idle, !rst_n, log_wp == 0 && !log_err && !ws_valid)
  `SVA_INV(a_pending, pending == m_p && cpu_irq == (m_p != 0) && claim == m_claim(m_p))
  `SVA_INV(a_log_wp, log_wp == m_wp)
  `SVA_INV(a_engine_start, u_eng.start == m_go)
  `SVA_IMP(a_engine_job, m_go, u_eng.dst == log_base + {14'd0, m_ws, 2'b00} && u_eng.len == 16'd1
                               && !u_eng.rd_en && u_eng.wr_en)
  `SVA_INV(a_record, ws_valid == e_busy && (!ws_valid || ws_data == {m_ts, 3'b000, m_lidq}))
  `SVA_INV(a_log_err, log_err == (e_done && e_err))
  `SVA_INV(a_no_read_stream, !rs_ready)

  covergroup cg_intc @(posedge clk);
    option.per_instance = 1;
    cp_claim: coverpoint claim[4:0] iff (rst_n && claim[31]);
    cp_npend: coverpoint $countones(m_p) iff (rst_n) { bins none = {0}; bins one = {1}; bins few = {[2:31]}; bins all = {32}; }
    cp_sw: coverpoint (sw_set & enable) != 0 iff (rst_n && cpu_irq);
    cp_masked: coverpoint ((irq_src | sw_set) & ~enable) != 0 iff (rst_n);
  endgroup
  cg_intc u_cg_intc = new;
  covergroup cg_intc_log @(posedge clk);
    option.per_instance = 1;
    cp_id: coverpoint m_lid iff (rst_n && m_go);
    cp_queue: coverpoint $countones(m_tolog) iff (rst_n && m_go) { bins one = {1}; bins several = {[2:32]}; }
    cp_slot: coverpoint (m_ws == 0 ? 2'd0 : 32'(m_ws) + 1 == 32'(log_words) ? 2'd1 : 2'd2) iff (rst_n && m_go)
      { bins first = {0}; bins last = {1}; bins middle = {2}; }
    cp_shrunk: coverpoint (m_slot >= log_words) iff (rst_n && m_go);
    cp_end: coverpoint e_err iff (rst_n && e_done);
  endgroup
  cg_intc_log u_cg_intc_log = new;

  `FC(merge_while_waiting, m_tolog != 0 && (m_rise & m_tolog) != 0)
  `FC(drop_on_log_disable, !log_en && m_tolog != 0)
  `FC(rise_during_write, e_busy && m_rise != 0)
  `FC(log_words_zero_holds, log_en && m_lv && log_words == 0)
  `FC(record_stall, ws_valid && !ws_ready)
  `FC(timestamp_wrap, m_ts == 24'hFFFFFF)
  `FC(log_wp_wrap, e_done && m_wp == 16'hFFFF)
  `FC_RST(reset_mid_record, rst_n && e_busy ##1 !rst_n)
endmodule

bind Interrupt_Controller_top Interrupt_Controller_sva u_sva (.*);
