// SPDX-License-Identifier: Apache-2.0
// ISP (camera pipeline on soc_ss_axi_engine, write only): concurrent SVA
// against an independent model of the test pattern generator (column and
// line counters), the sensor stream handshake, black level, Q4.4 gain with
// clipping and STAT_SUM, fed by the configuration pins and the sensor stream,
// + functional coverage. The engine is closed by its own run.
`include "cov_macros.svh"
module ISP_sva (
  input logic        clk, rst_n, start, busy, done, err, err_irq, src_sel,
  input logic [15:0] xfer_len, line_words,
  input logic [7:0]  seed, black, gain,
  input logic [31:0] stat_sum,
  input logic        sns_valid, sns_ready,
  input logic [31:0] sns_data,
  input logic        rs_valid, rs_ready, ws_valid, ws_ready,
  input logic [31:0] rs_data, ws_data
);
  `COV_CLOCKING(clk, !rst_n)
  `define SOC_SS_WRITE_ONLY
  `include "soc_ss_job_cov.svh"
  `undef SOC_SS_WRITE_ONLY

  logic        m_sel;
  logic [15:0] m_x, m_y;
  logic [31:0] m_sum, m_raw, m_out;
  logic [9:0]  m_ps;
  logic [3:0]  m_clip, m_blk;        // per pixel: clipped at 255, at or below black
  always_comb begin
    m_ps = 0;
    for (int b = 0; b < 4; b++) begin
      int d, g;
      m_raw[8*b +: 8] = m_sel ? sns_data[8*b +: 8] : (8'(4 * int'(m_x) + b + int'(m_y[7:0])) ^ seed);
      d = int'(m_raw[8*b +: 8]) > int'(black) ? int'(m_raw[8*b +: 8]) - int'(black) : 0;
      g = (d * int'(gain)) >> 4;
      m_blk[b]  = d == 0;
      m_clip[b] = g > 255;
      m_out[8*b +: 8] = g > 255 ? 8'hFF : 8'(g);
      m_ps = m_ps + 10'(m_out[8*b +: 8]);
    end
  end
  wire m_hs = ws_valid && ws_ready;
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin m_sel <= 0; m_x <= 0; m_y <= 0; m_sum <= 0; end
    else if (go) begin m_sel <= src_sel; m_x <= 0; m_y <= 0; m_sum <= 0; end
    else if (m_hs) begin
      m_sum <= m_sum + 32'(m_ps);
      if (32'(m_x) + 1 >= 32'(line_words)) begin m_x <= 0; m_y <= m_y + 1; end
      else m_x <= m_x + 1;
    end
  end

  `SVA_RST(a_reset_idle, !rst_n, stat_sum == 0 && !sns_ready && !err_irq)
  `SVA_INV(a_ws_valid, ws_valid == (busy && (m_sel ? sns_valid : 1'b1)))
  `SVA_IMP(a_ws_data, ws_valid, ws_data == m_out)
  `SVA_INV(a_sns_ready, sns_ready == (busy && m_sel && ws_ready))
  `SVA_INV(a_no_read_stream, !rs_ready)
  `SVA_INV(a_stat_sum, stat_sum == m_sum)

  covergroup cg_isp @(posedge clk);
    option.per_instance = 1;
    cp_sel: coverpoint src_sel iff (rst_n && go);
    cp_lines: coverpoint (line_words == 0 ? 2'd0 : line_words == 1 ? 2'd1 : line_words < 16 ? 2'd2 : 2'd3) iff (rst_n && go)
      { bins zero = {0}; bins one_word = {1}; bins short_ = {2}; bins long_ = {3}; }
    x_sel_lines: cross cp_sel, cp_lines;
    cp_len: coverpoint lcls(xfer_len) iff (rst_n && go)
      { bins zero = {0}; bins one = {1}; bins short_ = {2}; bins sixteen = {3}; bins mid = {4}; }
    x_sel_len: cross cp_sel, cp_len;
    cp_black: coverpoint (black == 0) iff (rst_n && go);
    cp_gain: coverpoint (gain == 0 ? 2'd0 : gain < 16 ? 2'd1 : gain == 16 ? 2'd2 : 2'd3) iff (rst_n && go)
      { bins zero = {0}; bins cut = {1}; bins unity = {2}; bins boost = {3}; }
  endgroup
  cg_isp u_cg_isp = new;
  covergroup cg_isp_pix @(posedge clk);
    option.per_instance = 1;
    cp_clip: coverpoint m_clip iff (rst_n && m_hs) { bins none = {0}; bins some = {[1:14]}; bins all = {15}; }
    cp_blk: coverpoint m_blk iff (rst_n && m_hs) { bins none = {0}; bins some = {[1:14]}; bins all = {15}; }
    cp_sns_gap: coverpoint sns_valid iff (rst_n && busy && m_sel);
    cp_out: coverpoint dcls(m_out) iff (rst_n && m_hs)
      { bins zero = {0}; bins ones = {1}; bins other = {3}; }
  endgroup
  cg_isp_pix u_cg_isp_pix = new;

  `FC(line_wrap, m_hs && line_words > 1 && 32'(m_x) + 1 == 32'(line_words))
  `FC(sensor_stalled_by_axi, busy && m_sel && sns_valid && !ws_ready)
endmodule

bind ISP_top ISP_sva u_sva (.*);
