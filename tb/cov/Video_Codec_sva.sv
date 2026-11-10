// SPDX-License-Identifier: Apache-2.0
// Video_Codec (DPCM line codec on soc_ss_axi_engine): concurrent SVA against
// an independent model of the predictor (128 at the start of a job and of
// each line, else the previous reconstructed sample), the encode / decode
// arithmetic modulo 256, ZEROS (saturating) and CHECKSUM, fed by the
// configuration pins and the engine's read stream, + functional coverage.
// The engine is closed by its own run.
`include "cov_macros.svh"
module Video_Codec_sva (
  input logic        clk, rst_n, start, busy, done, err, err_irq, mode,
  input logic [15:0] xfer_len, line_words, zeros,
  input logic [31:0] checksum,
  input logic        rs_valid, rs_ready, ws_valid, ws_ready,
  input logic [31:0] rs_data, ws_data
);
  `COV_CLOCKING(clk, !rst_n)
  `include "soc_ss_job_cov.svh"

  logic        m_mode;
  logic [7:0]  m_pred;
  logic [15:0] m_x;
  logic [18:0] m_z;                  // unsaturated zero count
  logic [31:0] m_sum, m_out, m_rec;
  logic [2:0]  m_nz;
  always_comb begin
    logic [7:0] p, i, o;
    p = (m_x == 0) ? 8'd128 : m_pred;
    m_nz = 0;
    for (int b = 0; b < 4; b++) begin
      i = rs_data[8*b +: 8];
      o = m_mode ? i + p : i - p;
      m_out[8*b +: 8] = o;
      m_rec[8*b +: 8] = m_mode ? o : i;
      if ((m_mode ? i : o) == 0) m_nz = m_nz + 1;
      p = m_rec[8*b +: 8];
    end
  end
  wire m_hs = rs_valid && rs_ready;
  wire m_eol = line_words != 0 && 32'(m_x) + 1 >= 32'(line_words);
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin m_mode <= 0; m_pred <= 128; m_x <= 0; m_z <= 0; m_sum <= 0; end
    else if (go) begin m_mode <= mode; m_pred <= 128; m_x <= 0; m_z <= 0; m_sum <= 0; end
    else if (m_hs) begin
      m_pred <= m_rec[31:24];
      m_z    <= m_z + 19'(m_nz);
      m_sum  <= m_sum + m_rec;
      m_x    <= m_eol ? 16'd0 : m_x + 1;
    end
  end

  `SVA_RST(a_reset_idle, !rst_n, zeros == 0 && checksum == 0 && !err_irq)
  `SVA_IMP(a_ws_data, ws_valid, ws_data == m_out)
  `SVA_INV(a_stream, ws_valid == rs_valid && rs_ready == ws_ready)
  `SVA_INV(a_zeros, zeros == (m_z > 19'hFFFF ? 16'hFFFF : m_z[15:0]))
  `SVA_INV(a_checksum, checksum == m_sum)

  covergroup cg_vcodec @(posedge clk);
    option.per_instance = 1;
    cp_mode: coverpoint mode iff (rst_n && go);
    cp_lines: coverpoint (line_words == 0 ? 2'd0 : line_words == 1 ? 2'd1 : line_words < 16 ? 2'd2 : 2'd3) iff (rst_n && go)
      { bins whole_frame = {0}; bins one_word = {1}; bins short_ = {2}; bins long_ = {3}; }
    x_mode_lines: cross cp_mode, cp_lines;
    cp_len: coverpoint lcls(xfer_len) iff (rst_n && go)
      { bins zero = {0}; bins one = {1}; bins short_ = {2}; bins sixteen = {3}; bins mid = {4}; }
    x_mode_len: cross cp_mode, cp_len;
  endgroup
  cg_vcodec u_cg_vcodec = new;
  covergroup cg_vcodec_data @(posedge clk);
    option.per_instance = 1;
    cp_line_start: coverpoint (m_x == 0) iff (rst_n && m_hs);
    cp_nz: coverpoint m_nz iff (rst_n && m_hs) { bins n[] = {[0:4]}; }
    x_mode_nz: cross m_mode, cp_nz;
    cp_in: coverpoint dcls(rs_data) iff (rst_n && m_hs)
      { bins zero = {0}; bins ones = {1}; bins alt = {2}; bins other = {3}; }
  endgroup
  cg_vcodec_data u_cg_vcodec_data = new;

  `FC(zeros_saturate, m_hs && m_z <= 19'hFFFF && m_z + 19'(m_nz) > 19'hFFFF)
  `FC(line_wrap, m_hs && m_eol && line_words > 1)
endmodule

bind Video_Codec_top Video_Codec_sva u_sva (.*);
