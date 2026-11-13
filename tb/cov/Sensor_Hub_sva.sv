// SPDX-License-Identifier: Apache-2.0
// Sensor_Hub (sample decimator and batching writer on soc_ss_axi_engine,
// write only): concurrent SVA against an independent model of the sample
// intake (only while the batch needs words), the 2^AVG_LOG2 averaging, the
// packing of two averages per word, DROPS (saturating) when the write FIFO
// is full, the once-per-job WAKE and LAST_AVG, fed by the configuration pins
// and the sensor stream, + functional coverage. The engine is closed by its
// own run.
`include "cov_macros.svh"
module Sensor_Hub_sva (
  input logic        clk, rst_n, start, busy, done, err, err_irq, wake_en, wake,
  input logic [15:0] xfer_len, threshold, last_avg, drops,
  input logic [2:0]  avg_log2,
  input logic        sns_valid,
  input logic [15:0] sns_data,
  input logic        rs_valid, rs_ready, ws_valid, ws_ready,
  input logic [31:0] rs_data, ws_data
);
  `COV_CLOCKING(clk, !rst_n)
  `define SOC_SS_WRITE_ONLY
  `include "soc_ss_job_cov.svh"
  `undef SOC_SS_WRITE_ONLY

  int          m_acc, m_cnt;
  logic [2:0]  m_k;
  logic [15:0] m_lo, m_last, m_drops, m_nw, m_len;
  logic        m_half, m_woke;
  wire         m_take = busy && sns_valid && m_nw != m_len;
  wire         m_full = m_take && m_cnt == (1 << m_k) - 1;    // a group completes
  wire  [15:0] m_avg  = 16'((m_acc + int'(sns_data)) >> m_k);
  wire         m_wake = m_full && wake_en && !m_woke && m_avg > threshold;
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      m_acc <= 0; m_cnt <= 0; m_k <= 0; m_lo <= 0; m_last <= 0; m_drops <= 0;
      m_nw <= 0; m_len <= 0; m_half <= 0; m_woke <= 0;
    end else if (go) begin
      m_acc <= 0; m_cnt <= 0; m_k <= avg_log2; m_lo <= 0; m_drops <= 0;
      m_nw <= 0; m_len <= xfer_len; m_half <= 0; m_woke <= 0;
    end else if (m_take) begin
      if (m_full) begin
        m_acc <= 0; m_cnt <= 0; m_last <= m_avg; m_half <= !m_half;
        if (!m_half) m_lo <= m_avg;
        else if (ws_ready) m_nw <= m_nw + 1;
        else if (m_drops != 16'hFFFF) m_drops <= m_drops + 1;
        if (m_wake) m_woke <= 1;
      end else begin
        m_acc <= m_acc + int'(sns_data); m_cnt <= m_cnt + 1;
      end
    end
  end

  `SVA_RST(a_reset_idle, !rst_n, !wake && last_avg == 0 && drops == 0 && !err_irq)
  `SVA_INV(a_ws_valid, ws_valid == (m_full && m_half))
  `SVA_IMP(a_ws_data, ws_valid, ws_data == {m_avg, m_lo})
  `SVA_INV(a_wake, wake == m_wake)
  `SVA_INV(a_last_avg, last_avg == m_last)
  `SVA_INV(a_drops, drops == m_drops)
  `SVA_INV(a_no_read_stream, !rs_ready)

  covergroup cg_shub @(posedge clk);
    option.per_instance = 1;
    cp_k: coverpoint avg_log2 iff (rst_n && go);
    cp_wake_en: coverpoint wake_en iff (rst_n && go);
    cp_thr: coverpoint (threshold == 0 ? 2'd0 : threshold == 16'hFFFF ? 2'd1 : 2'd2) iff (rst_n && go)
      { bins zero = {0}; bins max = {1}; bins other = {2}; }
    cp_len: coverpoint lcls(xfer_len) iff (rst_n && go)
      { bins zero = {0}; bins one = {1}; bins short_ = {2}; bins sixteen = {3}; bins mid = {4}; }
  endgroup
  cg_shub u_cg_shub = new;
  covergroup cg_shub_avg @(posedge clk);
    option.per_instance = 1;
    cp_k: coverpoint m_k iff (rst_n && m_full);
    cp_half: coverpoint m_half iff (rst_n && m_full);
    cp_drop: coverpoint ws_ready iff (rst_n && m_full && m_half);
    cp_avg: coverpoint (m_avg == 0 ? 2'd0 : m_avg == 16'hFFFF ? 2'd1 : 2'd2) iff (rst_n && m_full)
      { bins zero = {0}; bins max = {1}; bins other = {2}; }
    cp_above: coverpoint (m_avg > threshold) iff (rst_n && m_full && wake_en);
    cp_ignored: coverpoint m_nw == m_len iff (rst_n && busy && sns_valid);
  endgroup
  cg_shub_avg u_cg_shub_avg = new;

  `FC(wake_once, m_wake ##[1:$] m_full && wake_en && m_woke && m_avg > threshold)
  `FC(drops_saturate, m_full && m_half && !ws_ready && m_drops == 16'hFFFE)
  `FC(drop_at_ceiling, m_full && m_half && !ws_ready && m_drops == 16'hFFFF)
endmodule

bind Sensor_Hub_top Sensor_Hub_sva u_sva (.*);
