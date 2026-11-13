// SPDX-License-Identifier: Apache-2.0
// GPU (2D blitter on soc_ss_axi_engine): concurrent SVA against an
// independent model of the datapath (copy, fill, blend with a clamped alpha,
// invert of the colour channels) and of the PIXELS count, fed by the
// configuration pins and the engine's read stream, + functional coverage of
// the mode / length / alpha / data space. The engine is closed by its own run.
`include "cov_macros.svh"
module GPU_sva (
  input logic        clk, rst_n, start, busy, done, err, err_irq,
  input logic [15:0] xfer_len, pixels,
  input logic [1:0]  mode,
  input logic [8:0]  alpha,
  input logic [31:0] color,
  input logic        rs_valid, rs_ready, ws_valid, ws_ready,
  input logic [31:0] rs_data, ws_data
);
  `COV_CLOCKING(clk, !rst_n)
  `include "soc_ss_job_cov.svh"

  logic [1:0]  m_mode;
  logic [15:0] m_pix;
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin m_mode <= 0; m_pix <= 0; end
    else if (go) begin m_mode <= mode; m_pix <= 0; end
    else if (ws_valid && ws_ready) m_pix <= m_pix + 1;
  end
  function automatic logic [31:0] f(input logic [1:0] md, input logic [31:0] x);
    int a;
    a = alpha > 256 ? 256 : int'(alpha);
    case (md)
      2'd1: f = color;
      2'd2: for (int c = 0; c < 4; c++)
              f[8*c +: 8] = 8'((int'(x[8*c +: 8]) * a + int'(color[8*c +: 8]) * (256 - a)) >> 8);
      2'd3: f = {x[31:24], ~x[23:0]};
      default: f = x;
    endcase
  endfunction

  `SVA_RST(a_reset_idle, !rst_n, pixels == 0 && !busy && !done && !err_irq)
  `SVA_IMP(a_ws_data, ws_valid, ws_data == f(m_mode, rs_data))
  `SVA_INV(a_ws_valid, ws_valid == (m_mode == 2'd1 ? busy : rs_valid))
  `SVA_INV(a_rs_ready, rs_ready == ws_ready)
  `SVA_INV(a_pixels, pixels == m_pix)

  function automatic logic [2:0] acls(input logic [8:0] a);
    acls = a == 0 ? 3'd0 : a < 128 ? 3'd1 : a == 128 ? 3'd2 : a < 256 ? 3'd3 : a == 256 ? 3'd4 : 3'd5;
  endfunction
  covergroup cg_gpu @(posedge clk);
    option.per_instance = 1;
    cp_mode: coverpoint mode iff (rst_n && go);
    cp_len: coverpoint lcls(xfer_len) iff (rst_n && go)
      { bins zero = {0}; bins one = {1}; bins short_ = {2}; bins sixteen = {3}; bins mid = {4}; }
    x_mode_len: cross cp_mode, cp_len;
    cp_alpha: coverpoint acls(alpha) iff (rst_n && go && mode == 2'd2)
      { bins zero = {0}; bins low = {1}; bins half = {2}; bins high = {3}; bins full = {4}; bins clamped = {5}; }
    cp_color: coverpoint dcls(color) iff (rst_n && go && mode[0] != mode[1])
      { bins zero = {0}; bins ones = {1}; bins alt = {2}; bins other = {3}; }
  endgroup
  cg_gpu u_cg_gpu = new;
  covergroup cg_gpu_data @(posedge clk);
    option.per_instance = 1;
    cp_mode: coverpoint m_mode iff (rst_n && ws_valid && ws_ready);
    cp_in: coverpoint dcls(rs_data) iff (rst_n && ws_valid && ws_ready && m_mode != 2'd1)
      { bins zero = {0}; bins ones = {1}; bins alt = {2}; bins other = {3}; }
    cp_out: coverpoint dcls(ws_data) iff (rst_n && ws_valid && ws_ready)
      { bins zero = {0}; bins ones = {1}; bins alt = {2}; bins other = {3}; }
    cp_mode_in: coverpoint {m_mode, dcls(rs_data)} iff (rst_n && ws_valid && ws_ready && m_mode != 2'd1)
      { bins copy[] = {[0:3]}; bins blend[] = {[8:11]}; bins invert[] = {[12:15]}; }
  endgroup
  cg_gpu_data u_cg_gpu_data = new;

  `FC(fill_stall, m_mode == 2'd1 && busy && ws_valid && !ws_ready)
endmodule

bind GPU_top GPU_sva u_sva (.*);
