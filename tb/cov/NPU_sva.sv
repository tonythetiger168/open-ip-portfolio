// SPDX-License-Identifier: Apache-2.0
// NPU (4-tap int8 convolution engine on soc_ss_axi_engine): concurrent SVA
// against an independent model of the filter (sample history across words,
// zero padding at the start of a job, bias, ReLU, arithmetic shift,
// saturation) and of the SATURATIONS count, fed by the configuration pins and
// the engine's read stream, + functional coverage. The engine is closed by
// its own run.
`include "cov_macros.svh"
module NPU_sva (
  input logic        clk, rst_n, start, busy, done, err, err_irq, relu,
  input logic [15:0] xfer_len, saturations, bias,
  input logic [7:0]  w0, w1, w2, w3,
  input logic [3:0]  shift,
  input logic        rs_valid, rs_ready, ws_valid, ws_ready,
  input logic [31:0] rs_data, ws_data
);
  `COV_CLOCKING(clk, !rst_n)
  `include "soc_ss_job_cov.svh"

  logic signed [7:0] m_h [3];        // x[n-1], x[n-2], x[n-3] before this word
  logic [18:0] m_sat;                // unsaturated count (up to 4 x 65535)
  // per-byte result and its class: 0 in range, 1 clipped high, 2 clipped low
  function automatic logic [9:0] y(input int b);
    logic signed [7:0] x [7];
    int acc, sh;
    x[0] = m_h[2]; x[1] = m_h[1]; x[2] = m_h[0];
    for (int k = 0; k < 4; k++) x[3 + k] = rs_data[8*k +: 8];
    acc = int'(signed'(bias)) + int'(signed'(w0)) * int'(x[3 + b]) + int'(signed'(w1)) * int'(x[2 + b])
        + int'(signed'(w2)) * int'(x[1 + b]) + int'(signed'(w3)) * int'(x[b]);
    if (relu && acc < 0) acc = 0;
    sh = acc >>> shift;
    y = sh > 127 ? {2'd1, 8'h7F} : sh < -128 ? {2'd2, 8'h80} : {2'd0, 8'(sh)};
  endfunction
  logic [31:0] m_y;
  logic [2:0]  m_ns;
  logic [1:0]  m_cls [4];
  always_comb begin
    m_ns = 0;
    for (int b = 0; b < 4; b++) begin
      logic [9:0] r;
      r = y(b);
      m_y[8*b +: 8] = r[7:0];
      m_cls[b] = r[9:8];
      if (r[9:8] != 0) m_ns = m_ns + 1;
    end
  end
  wire m_hs = rs_valid && rs_ready;
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin m_h <= '{0, 0, 0}; m_sat <= 0; end
    else if (go) begin m_h <= '{0, 0, 0}; m_sat <= 0; end
    else if (m_hs) begin
      m_h[0] <= rs_data[31:24]; m_h[1] <= rs_data[23:16]; m_h[2] <= rs_data[15:8];
      m_sat <= m_sat + 19'(m_ns);
    end
  end

  `SVA_RST(a_reset_idle, !rst_n, saturations == 0 && !err_irq)
  `SVA_IMP(a_ws_data, ws_valid, ws_data == m_y)
  `SVA_INV(a_stream, ws_valid == rs_valid && rs_ready == ws_ready)
  `SVA_INV(a_saturations, saturations == (m_sat > 19'hFFFF ? 16'hFFFF : m_sat[15:0]))

  covergroup cg_npu @(posedge clk);
    option.per_instance = 1;
    cp_relu: coverpoint relu iff (rst_n && go);
    cp_shift: coverpoint shift iff (rst_n && go) { bins zero = {0}; bins mid[] = {[1:14]}; bins max = {15}; }
    cp_bias_sign: coverpoint bias[15] iff (rst_n && go);
    cp_w0: coverpoint w0[7] iff (rst_n && go);
    cp_w3: coverpoint w3[7] iff (rst_n && go);
    x_relu_shift: cross cp_relu, cp_bias_sign;
  endgroup
  cg_npu u_cg_npu = new;
  covergroup cg_npu_out @(posedge clk);
    option.per_instance = 1;
    cp_b0: coverpoint m_cls[0] iff (rst_n && m_hs) { bins in_range = {0}; bins high = {1}; bins low = {2}; }
    cp_b3: coverpoint m_cls[3] iff (rst_n && m_hs) { bins in_range = {0}; bins high = {1}; bins low = {2}; }
    cp_nsat: coverpoint m_ns iff (rst_n && m_hs) { bins n[] = {[0:4]}; }
    cp_relu_clamp: coverpoint relu iff (rst_n && m_hs && m_y == 0);
    cp_in: coverpoint dcls(rs_data) iff (rst_n && m_hs)
      { bins zero = {0}; bins ones = {1}; bins alt = {2}; bins other = {3}; }
  endgroup
  cg_npu_out u_cg_npu_out = new;

  `FC(saturations_saturate, m_hs && m_sat <= 19'hFFFF && m_sat + 19'(m_ns) > 19'hFFFF)
  `FC(history_crosses_word, m_hs ##1 m_hs)
endmodule

bind NPU_top NPU_sva u_sva (.*);
