// SPDX-License-Identifier: Apache-2.0
// Audio_DSP (stereo gain / downmix / mute on soc_ss_axi_engine): concurrent
// SVA against an independent model of the per-channel Q8.8 gain with
// saturation, the mono downmix, mute, PEAK and CLIPS (saturating), fed by the
// configuration pins and the engine's read stream, + functional coverage.
// The engine is closed by its own run.
`include "cov_macros.svh"
module Audio_DSP_sva (
  input logic        clk, rst_n, start, busy, done, err, err_irq, mix, mute,
  input logic [15:0] xfer_len, gain_l, gain_r, peak, clips,
  input logic        rs_valid, rs_ready, ws_valid, ws_ready,
  input logic [31:0] rs_data, ws_data
);
  `COV_CLOCKING(clk, !rst_n)
  `include "soc_ss_job_cov.svh"

  logic [31:0] m_out;
  logic [15:0] m_pk;
  logic [1:0]  m_ncl;
  logic [1:0]  m_cls [2];            // per channel: 0 in range, 1 clipped high, 2 clipped low
  always_comb begin
    int x [2];
    int m, p, yv;
    m = (int'(signed'(rs_data[15:0])) + int'(signed'(rs_data[31:16]))) >>> 1;
    x[0] = mix ? m : int'(signed'(rs_data[15:0]));
    x[1] = mix ? m : int'(signed'(rs_data[31:16]));
    m_pk = 0; m_ncl = 0;
    for (int c = 0; c < 2; c++) begin
      p = (x[c] * int'(signed'(c == 0 ? gain_l : gain_r))) >>> 8;
      m_cls[c] = 0;
      if (mute) yv = 0;
      else if (p > 32767)  begin yv = 32767;  m_cls[c] = 1; end
      else if (p < -32768) begin yv = -32768; m_cls[c] = 2; end
      else yv = p;
      if (m_cls[c] != 0) m_ncl = m_ncl + 1;
      m_out[16*c +: 16] = 16'(yv);
      if ((yv < 0 ? -yv : yv) > int'(m_pk)) m_pk = 16'(yv < 0 ? -yv : yv);
    end
  end
  wire m_hs = rs_valid && rs_ready;
  logic [15:0] m_peak;
  logic [18:0] m_clips;
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin m_peak <= 0; m_clips <= 0; end
    else if (go) begin m_peak <= 0; m_clips <= 0; end
    else if (m_hs) begin
      if (m_pk > m_peak) m_peak <= m_pk;
      m_clips <= m_clips + 19'(m_ncl);
    end
  end

  `SVA_RST(a_reset_idle, !rst_n, peak == 0 && clips == 0 && !err_irq)
  `SVA_IMP(a_ws_data, ws_valid, ws_data == m_out)
  `SVA_INV(a_stream, ws_valid == rs_valid && rs_ready == ws_ready)
  `SVA_INV(a_peak, peak == m_peak)
  `SVA_INV(a_clips, clips == (m_clips > 19'hFFFF ? 16'hFFFF : m_clips[15:0]))

  function automatic logic [2:0] gcls(input logic [15:0] g);
    gcls = g == 0 ? 3'd0 : g == 16'd256 ? 3'd1 : g[15] ? 3'd2 : g < 16'd256 ? 3'd3 : 3'd4;
  endfunction
  covergroup cg_audio @(posedge clk);
    option.per_instance = 1;
    cp_gl: coverpoint gcls(gain_l) iff (rst_n && go)
      { bins zero = {0}; bins unity = {1}; bins negative = {2}; bins cut = {3}; bins boost = {4}; }
    cp_gr: coverpoint gcls(gain_r) iff (rst_n && go)
      { bins zero = {0}; bins unity = {1}; bins negative = {2}; bins cut = {3}; bins boost = {4}; }
    cp_mix: coverpoint mix iff (rst_n && go);
    cp_mute: coverpoint mute iff (rst_n && go);
    x_mix_mute: cross cp_mix, cp_mute;
  endgroup
  cg_audio u_cg_audio = new;
  covergroup cg_audio_data @(posedge clk);
    option.per_instance = 1;
    cp_l: coverpoint m_cls[0] iff (rst_n && m_hs && !mute) { bins in_range = {0}; bins high = {1}; bins low = {2}; }
    cp_r: coverpoint m_cls[1] iff (rst_n && m_hs && !mute) { bins in_range = {0}; bins high = {1}; bins low = {2}; }
    x_lr: cross cp_l, cp_r;
    cp_in: coverpoint dcls(rs_data) iff (rst_n && m_hs)
      { bins zero = {0}; bins ones = {1}; bins alt = {2}; bins other = {3}; }
    cp_new_peak: coverpoint (m_pk > m_peak) iff (rst_n && m_hs);
  endgroup
  cg_audio_data u_cg_audio_data = new;

  `FC(clips_saturate, m_hs && m_clips <= 19'hFFFF && m_clips + 19'(m_ncl) > 19'hFFFF)
  `FC(full_scale_peak, m_hs && m_pk == 16'h8000)
endmodule

bind Audio_DSP_top Audio_DSP_sva u_sva (.*);
