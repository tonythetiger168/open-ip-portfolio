// SPDX-License-Identifier: Apache-2.0
// Timer_WDT (system timer and watchdog, timestamp records written by
// soc_ss_axi_engine): concurrent SVA against an independent model of the
// prescaler, COUNT, the periodic timer (auto-reload, PERIOD lowered below
// the count), the record ring (slot wrap, TS_WORDS lowered, missed events,
// saturating TS_MISSED) and the watchdog (kick, bark, bite), fed by the input
// pins, + functional coverage. The engine is closed by its own run.
`include "cov_macros.svh"
module Timer_WDT_sva (
  input logic        clk, rst_n, tmr_en, ts_en, wdt_en, kick,
  input logic [15:0] prescale, ts_words, ts_wp, ts_missed,
  input logic [31:0] period, ts_base, wdt_load, count, wdt_count,
  input logic        wdt_reset, tmr_irq, bark, ts_err,
  input logic        e_busy, e_done, e_err, ws_valid, ws_ready, rs_ready,
  input logic [31:0] ws_data
);
  `COV_CLOCKING(clk, !rst_n)
  logic [15:0] m_pre, m_slot, m_wp, m_miss;
  logic [31:0] m_cnt, m_tc, m_wdt, m_rec;
  logic        m_barked, m_bite;
  wire         m_tick = m_pre >= prescale;
  wire         m_tev  = tmr_en && m_tick && m_tc >= period;
  wire         m_bark = wdt_en && m_tick && m_wdt == 0 && !m_barked && !kick;
  wire         m_want = m_tev && ts_en && ts_words != 0;
  wire         m_go   = m_want && !e_busy && !e_done;
  wire  [15:0] m_ws   = m_slot >= ts_words ? 16'd0 : m_slot;
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      m_pre <= 0; m_cnt <= 0; m_tc <= 0; m_rec <= 0; m_slot <= 0; m_wp <= 0; m_miss <= 0;
      m_wdt <= 0; m_barked <= 0; m_bite <= 0;
    end else begin
      m_pre <= m_tick ? 16'd0 : m_pre + 1;
      if (m_tick) m_cnt <= m_cnt + 1;
      if (!tmr_en) m_tc <= 0;
      else if (m_tick) m_tc <= m_tc >= period ? 32'd0 : m_tc + 1;
      if (m_go) m_rec <= m_cnt;
      if (m_want && !m_go && m_miss != 16'hFFFF) m_miss <= m_miss + 1;
      if (e_done) begin
        m_wp <= m_wp + 1;
        m_slot <= (32'(m_ws) + 1 >= 32'(ts_words)) ? 16'd0 : m_ws + 1;
      end
      if (!wdt_en || kick) begin m_wdt <= wdt_load; m_barked <= 0; m_bite <= 0; end
      else if (m_tick) begin
        if (m_wdt == 0) begin m_wdt <= wdt_load; if (m_barked) m_bite <= 1; m_barked <= 1; end
        else m_wdt <= m_wdt - 1;
      end
    end
  end

  `SVA_RST(a_reset_idle, !rst_n, count == 0 && ts_wp == 0 && ts_missed == 0 && wdt_count == 0 && !wdt_reset && !ws_valid)
  `SVA_INV(a_count, count == m_cnt)
  `SVA_INV(a_timer, tmr_irq == m_tev)
  `SVA_INV(a_watchdog, wdt_count == m_wdt && bark == m_bark && wdt_reset == m_bite)
  `SVA_INV(a_ring, ts_wp == m_wp && ts_missed == m_miss)
  `SVA_INV(a_engine_start, u_eng.start == m_go)
  `SVA_IMP(a_engine_job, m_go, u_eng.dst == ts_base + {14'd0, m_ws, 2'b00} && u_eng.len == 16'd1
                               && !u_eng.rd_en && u_eng.wr_en)
  `SVA_INV(a_record, ws_valid == e_busy && (!ws_valid || ws_data == m_rec))
  `SVA_INV(a_ts_err, ts_err == (e_done && e_err))
  `SVA_INV(a_no_read_stream, !rs_ready)

  covergroup cg_tmr @(posedge clk);
    option.per_instance = 1;
    cp_pre: coverpoint (prescale == 0 ? 2'd0 : prescale == 16'hFFFF ? 2'd2 : 2'd1) iff (rst_n && m_tick)
      { bins every_clock = {0}; bins divided = {1}; bins max = {2}; }
    cp_period: coverpoint (period == 0 ? 2'd0 : period < 32 ? 2'd1 : 2'd2) iff (rst_n && m_tev)
      { bins every_tick = {0}; bins short_ = {1}; bins long_ = {2}; }
    cp_lowered: coverpoint (m_tc > period) iff (rst_n && m_tev);
    cp_rec: coverpoint {m_go, m_want} iff (rst_n && m_tev && ts_en) { bins off = {2'b00}; bins missed = {2'b01}; bins written = {2'b11}; }
    cp_slot: coverpoint (m_ws == 0 ? 2'd0 : 32'(m_ws) + 1 == 32'(ts_words) ? 2'd1 : 2'd2) iff (rst_n && m_go)
      { bins first = {0}; bins last = {1}; bins middle = {2}; }
    cp_shrunk: coverpoint (m_slot >= ts_words) iff (rst_n && m_go);
    cp_end: coverpoint e_err iff (rst_n && e_done);
  endgroup
  cg_tmr u_cg_tmr = new;
  covergroup cg_wdt @(posedge clk);
    option.per_instance = 1;
    cp_expire: coverpoint {m_barked, kick} iff (rst_n && wdt_en && m_tick && m_wdt == 0)
      { bins bark = {2'b00}; bins bite = {2'b10}; bins kick_at_zero = {2'b01, 2'b11}; }
    cp_kick: coverpoint {m_barked, m_bite} iff (rst_n && wdt_en && kick)
      { bins early = {2'b00}; bins after_bark = {2'b10}; bins after_bite = {2'b11}; }
    cp_load: coverpoint (wdt_load == 0) iff (rst_n && wdt_en && kick);
    cp_disable_in_bite: coverpoint m_bite iff (rst_n && !wdt_en);
  endgroup
  cg_wdt u_cg_wdt = new;

  `FC(missed_saturate, m_want && !m_go && m_miss == 16'hFFFE)
  `FC(ts_wp_wrap, e_done && m_wp == 16'hFFFF)
  `FC(record_stall, ws_valid && !ws_ready)
  `FC(ts_words_zero, m_tev && ts_en && ts_words == 0)
  `FC(timer_and_bark_together, m_tev && m_bark)
  `FC_RST(reset_mid_record, rst_n && e_busy ##1 !rst_n)
endmodule

bind Timer_WDT_top Timer_WDT_sva u_sva (.*);
