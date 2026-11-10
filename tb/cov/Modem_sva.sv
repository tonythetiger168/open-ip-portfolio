// SPDX-License-Identifier: Apache-2.0
// Modem (scrambler / descrambler with CRC-32 on soc_ss_axi_engine):
// concurrent SVA against an independent model of the Galois LFSR key stream
// (SEED 0 replaced by 1, 32 steps per word), the bypass and the reflected
// CRC-32 over the input or the output words, fed by the configuration pins and
// the engine's read stream, + functional coverage. The engine is closed by
// its own run.
`include "cov_macros.svh"
module Modem_sva (
  input logic        clk, rst_n, start, busy, done, err, err_irq, crc_sel, bypass,
  input logic [15:0] xfer_len,
  input logic [31:0] seed, crc,
  input logic        rs_valid, rs_ready, ws_valid, ws_ready,
  input logic [31:0] rs_data, ws_data
);
  `COV_CLOCKING(clk, !rst_n)
  `include "soc_ss_job_cov.svh"

  logic [31:0] m_l, m_c;
  logic        m_sel, m_byp;
  // 32 steps of the scrambler LFSR: {next state, key word}
  function automatic logic [63:0] step32(input logic [31:0] s);
    logic [31:0] k;
    for (int i = 0; i < 32; i++) begin
      k[i] = s[0];
      s = s[0] ? ((s >> 1) ^ 32'h8020_0003) : (s >> 1);
    end
    step32 = {s, k};
  endfunction
  function automatic logic [31:0] crc_w(input logic [31:0] c, input logic [31:0] d);
    for (int b = 0; b < 4; b++) begin
      c = c ^ 32'(d[8*b +: 8]);
      for (int i = 0; i < 8; i++) c = c[0] ? ((c >> 1) ^ 32'hEDB8_8320) : (c >> 1);
    end
    crc_w = c;
  endfunction
  wire [63:0] m_st  = step32(m_l);
  wire [31:0] m_out = rs_data ^ (m_byp ? 32'd0 : m_st[31:0]);
  wire        m_hs  = rs_valid && rs_ready;
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin m_l <= 1; m_c <= '1; m_sel <= 0; m_byp <= 0; end
    else if (go) begin m_l <= seed == 0 ? 32'd1 : seed; m_c <= '1; m_sel <= crc_sel; m_byp <= bypass; end
    else if (m_hs) begin m_l <= m_st[63:32]; m_c <= crc_w(m_c, m_sel ? m_out : rs_data); end
  end

  `SVA_RST(a_reset_idle, !rst_n, crc == 32'h0 && !err_irq)
  `SVA_IMP(a_ws_data, ws_valid, ws_data == m_out)
  `SVA_INV(a_stream, ws_valid == rs_valid && rs_ready == ws_ready)
  `SVA_INV(a_crc, crc == ~m_c)

  covergroup cg_modem @(posedge clk);
    option.per_instance = 1;
    cp_seed: coverpoint (seed == 0 ? 2'd0 : seed == 1 ? 2'd1 : seed == '1 ? 2'd2 : 2'd3) iff (rst_n && go)
      { bins zero = {0}; bins one = {1}; bins ones = {2}; bins other = {3}; }
    cp_sel: coverpoint crc_sel iff (rst_n && go);
    cp_byp: coverpoint bypass iff (rst_n && go);
    x_sel_byp: cross cp_sel, cp_byp;
    cp_len: coverpoint lcls(xfer_len) iff (rst_n && go)
      { bins zero = {0}; bins one = {1}; bins short_ = {2}; bins sixteen = {3}; bins mid = {4}; }
    x_byp_len: cross cp_byp, cp_len;
  endgroup
  cg_modem u_cg_modem = new;
  covergroup cg_modem_data @(posedge clk);
    option.per_instance = 1;
    cp_in: coverpoint dcls(rs_data) iff (rst_n && m_hs)
      { bins zero = {0}; bins ones = {1}; bins alt = {2}; bins other = {3}; }
    cp_out: coverpoint dcls(m_out) iff (rst_n && m_hs && m_byp)
      { bins zero = {0}; bins ones = {1}; bins alt = {2}; bins other = {3}; }
  endgroup
  cg_modem_data u_cg_modem_data = new;
endmodule

bind Modem_top Modem_sva u_sva (.*);
