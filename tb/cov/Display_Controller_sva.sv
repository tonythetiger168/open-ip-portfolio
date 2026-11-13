// SPDX-License-Identifier: Apache-2.0
// Display_Controller (frame scan-out on soc_ss_axi_engine, read only):
// concurrent SVA against an independent model of the panel stream (pixels in
// order, hsync at the end of each LINE_WORDS line and of the frame, vsync on
// the last pixel), FRAME_CRC and UNDERRUNS (saturating), fed by the
// configuration pins, the panel's ready and the engine's read stream, +
// functional coverage. The engine is closed by its own run.
`include "cov_macros.svh"
module Display_Controller_sva (
  input logic        clk, rst_n, start, busy, done, err, err_irq,
  input logic [15:0] xfer_len, line_words, underruns,
  input logic [31:0] frame_crc,
  input logic        pix_valid, pix_hsync, pix_vsync, pix_ready,
  input logic [31:0] pix_data,
  input logic        rs_valid, rs_ready, ws_valid, ws_ready,
  input logic [31:0] rs_data, ws_data
);
  `COV_CLOCKING(clk, !rst_n)
  `define SOC_SS_READ_ONLY
  `include "soc_ss_job_cov.svh"
  `undef SOC_SS_READ_ONLY

  logic [15:0] m_x, m_left, m_und;
  logic [31:0] m_crc;
  function automatic logic [31:0] crc_w(input logic [31:0] c, input logic [31:0] d);
    for (int b = 0; b < 4; b++) begin
      c = c ^ 32'(d[8*b +: 8]);
      for (int i = 0; i < 8; i++) c = c[0] ? ((c >> 1) ^ 32'hEDB8_8320) : (c >> 1);
    end
    crc_w = c;
  endfunction
  wire m_hs   = pix_valid && pix_ready;
  wire m_eol  = line_words == 0 || 32'(m_x) + 1 >= 32'(line_words);
  wire m_starve = busy && pix_ready && !pix_valid && m_left != 0;
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin m_x <= 0; m_left <= 0; m_und <= 0; m_crc <= '1; end
    else if (go) begin m_x <= 0; m_left <= xfer_len; m_und <= 0; m_crc <= '1; end
    else if (m_hs) begin
      m_crc <= crc_w(m_crc, pix_data); m_left <= m_left - 1;
      m_x <= m_eol ? 16'd0 : m_x + 1;
    end else if (m_starve && m_und != 16'hFFFF) m_und <= m_und + 1;
  end

  `SVA_RST(a_reset_idle, !rst_n, !pix_valid && !pix_hsync && !pix_vsync && underruns == 0 && frame_crc == 0)
  `SVA_INV(a_pix_stream, pix_valid == rs_valid && pix_data == rs_data && rs_ready == pix_ready)
  `SVA_INV(a_hsync, pix_hsync == (pix_valid && (m_eol || m_left == 1)))
  `SVA_INV(a_vsync, pix_vsync == (pix_valid && m_left == 1))
  `SVA_INV(a_crc, frame_crc == ~m_crc)
  `SVA_INV(a_underruns, underruns == m_und)
  `SVA_INV(a_no_write_stream, !ws_valid)
  `SVA_IMP(a_pixels_in_frame, pix_valid, m_left != 0)

  covergroup cg_disp @(posedge clk);
    option.per_instance = 1;
    cp_lines: coverpoint (line_words == 0 ? 2'd0 : line_words == 1 ? 2'd1 : line_words < 16 ? 2'd2 : 2'd3) iff (rst_n && go)
      { bins whole_frame = {0}; bins one_pixel = {1}; bins short_ = {2}; bins long_ = {3}; }
    cp_len: coverpoint lcls(xfer_len) iff (rst_n && go)
      { bins zero = {0}; bins one = {1}; bins short_ = {2}; bins sixteen = {3}; bins mid = {4}; }
    x_lines_len: cross cp_lines, cp_len;
  endgroup
  cg_disp u_cg_disp = new;
  covergroup cg_disp_pix @(posedge clk);
    option.per_instance = 1;
    cp_sync: coverpoint {pix_hsync, pix_vsync} iff (rst_n && m_hs) { bins none = {0}; bins h = {2}; bins hv = {3}; }
    cp_panel_stall: coverpoint pix_ready iff (rst_n && pix_valid);
    cp_px: coverpoint dcls(pix_data) iff (rst_n && m_hs)
      { bins zero = {0}; bins ones = {1}; bins alt = {2}; bins other = {3}; }
  endgroup
  cg_disp_pix u_cg_disp_pix = new;

  `FC(underrun, m_starve)
  `FC(underruns_saturate, m_starve && m_und == 16'hFFFE)
  `FC(hsync_then_line_start, m_hs && pix_hsync && !pix_vsync ##[1:$] m_hs && m_x == 0)
endmodule

bind Display_Controller_top Display_Controller_sva u_sva (.*);
