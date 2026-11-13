// SPDX-License-Identifier: Apache-2.0
// Crypto_DMA (AES_GCM_top between a read and a write soc_ss_axi_engine):
// concurrent SVA against a model of the job written from the header, fed by
// the job pins, the engine streams and the core's block handshakes, +
// functional coverage. Checked: the read job (SRC, 4 words per AAD and text
// block) and the write job (DST, 4 words per text block), the input blocks
// (4 read words, byte-swapped into a big-endian block, AAD blocks first with
// the AAD flag, the last AAD block and the last text block carrying their
// byte counts, the empty closing block of an AAD-only job), the output words
// (each output block as 4 byte-swapped words in order; zeros after a core
// error), the end of the job (both transfers and the core done), ERR,
// GCM_ERR / ERR_CODE and the ERR interrupt. The engines and the core are
// closed by their own runs.
`include "cov_macros.svh"
module Crypto_DMA_sva (
  input logic         clk, rst_n, start, busy, done, err, err_irq, gcm_err, decrypt, key256, tag_ok,
  input logic [2:0]   err_code,
  input logic [15:0]  aad_len, txt_len,
  input logic [31:0]  src_addr, dst_addr,
  input logic         rs_valid, rs_ready, ws_valid, ws_ready,
  input logic [31:0]  rs_data, ws_data,
  input logic         in_valid, in_ready, in_aad, in_last,
  input logic [127:0] in_data, out_data,
  input logic [4:0]   in_bytes,
  input logic         out_valid, out_ready,
  input logic         c_done, c_err,
  input logic [2:0]   c_code,
  input logic         r_done, r_err, w_done, w_err, r_busy, w_busy
);
  `COV_CLOCKING(clk, !rst_n)
  wire [15:0] xfer_len = txt_len;   // job length class of the shared part: text bytes
`define SOC_SS_ERR_IRQ (done && (err || gcm_err))
  `include "soc_ss_job_cov.svh"

  function automatic logic [31:0] bsw(input logic [31:0] w);
    bsw = {w[7:0], w[15:8], w[23:16], w[31:24]};
  endfunction
  wire [12:0] m_nab = 13'((32'(aad_len) + 15) / 16);
  wire [12:0] m_ntb = 13'((32'(txt_len) + 15) / 16);
  wire [13:0] m_nbl = 14'(m_nab) + 14'(m_ntb);

  logic         m_run, m_g, m_r, m_w, m_ax, m_gerr, m_drop, m_term;
  logic [2:0]   m_code;
  logic [127:0] m_ib, m_ob;
  logic [1:0]   m_iw, m_ow;
  logic         m_ifull, m_ofull;
  logic [13:0]  m_bi;
  wire          m_fin = m_run && m_g && m_r && m_w && !r_busy && !w_busy;
  wire          m_last_aad = 32'(m_bi) + 1 == 32'(m_nab);
  wire          i_hs = in_valid && in_ready;

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      m_run <= 0; m_g <= 0; m_r <= 0; m_w <= 0; m_ax <= 0; m_gerr <= 0; m_drop <= 0; m_term <= 0; m_code <= 0;
      m_ib <= 0; m_ob <= 0; m_iw <= 0; m_ow <= 0; m_ifull <= 0; m_ofull <= 0; m_bi <= 0;
    end else if (go) begin
      m_run <= 1; m_g <= 0; m_r <= m_nbl == 0; m_w <= m_ntb == 0; m_ax <= 0; m_gerr <= 0; m_drop <= 0;
      m_code <= 0; m_term <= m_nbl == 0; m_iw <= 0; m_ow <= 0; m_ifull <= 0; m_ofull <= 0; m_bi <= 0;
    end else if (m_run) begin
      if (rs_valid && rs_ready && !m_drop) begin
        m_ib <= {m_ib[95:0], bsw(rs_data)}; m_iw <= m_iw + 1;
        if (m_iw == 3) m_ifull <= 1;
      end
      if (i_hs) begin
        if (m_term) m_term <= 0;
        else begin m_ifull <= 0; m_bi <= m_bi + 1; if (m_ntb == 0 && m_last_aad) m_term <= 1; end
      end
      if (m_drop) m_ofull <= 0;
      else if (out_valid && out_ready) begin m_ob <= out_data; m_ofull <= 1; m_ow <= 0; end
      else if (ws_valid && ws_ready) begin m_ob <= {m_ob[95:0], 32'd0}; m_ow <= m_ow + 1; if (m_ow == 3) m_ofull <= 0; end
      if (c_done) m_g <= 1;
      if (c_err) begin m_g <= 1; m_gerr <= 1; m_code <= c_code; m_drop <= 1; end
      if (r_done) begin m_r <= 1; if (r_err) m_ax <= 1; end
      if (w_done) begin m_w <= 1; if (w_err) m_ax <= 1; end
      if (m_fin) m_run <= 0;
    end
  end

  `SVA_RST(a_reset_idle, !rst_n, !busy && !done && !err && !gcm_err && !in_valid && !ws_valid)
  `SVA_INV(a_busy, busy == m_run && done == m_fin && err == m_ax && gcm_err == m_gerr && err_code == m_code
                   && err_irq == (m_fin && (m_ax || m_gerr)))
  `SVA_INV(a_rd_job, u_rd.start == (go && m_nbl != 0) && (!u_rd.start || (u_rd.src == src_addr
                     && u_rd.len == {m_nbl, 2'b00} && u_rd.rd_en && !u_rd.wr_en)))
  `SVA_INV(a_wr_job, u_wr.start == (go && m_ntb != 0) && (!u_wr.start || (u_wr.dst == dst_addr
                     && u_wr.len == {1'b0, m_ntb, 2'b00} && !u_wr.rd_en && u_wr.wr_en)))
  `SVA_INV(a_rs_ready, rs_ready == (m_run && (m_drop || !m_ifull)))
  `SVA_INV(a_in_valid, in_valid == (!m_drop && m_run && (m_term || m_ifull)))
  `SVA_IMP(a_in_term, in_valid && m_term, in_data == 0 && in_bytes == 0 && in_last && !in_aad)
  `SVA_IMP(a_in_block, in_valid && !m_term, in_data == m_ib
           && in_aad == (m_bi < 14'(m_nab))
           && in_last == (m_bi >= 14'(m_nab) && m_bi + 1 == m_nbl)
           && in_bytes == ((m_bi < 14'(m_nab)) ? ((m_last_aad && aad_len[3:0] != 0) ? 5'(aad_len[3:0]) : 5'd16)
                                               : ((m_bi + 1 == m_nbl && txt_len[3:0] != 0) ? 5'(txt_len[3:0]) : 5'd16)))
  `SVA_INV(a_out_ready, out_ready == !m_ofull)
  `SVA_INV(a_out_words, ws_valid == (m_ofull || m_drop) && (!ws_valid || ws_data == (m_drop ? 32'd0 : bsw(m_ob[127:96]))))

  covergroup cg_crypto_dma @(posedge clk);
    option.per_instance = 1;
    cp_shape: coverpoint {aad_len != 0, txt_len != 0} iff (rst_n && go);
    cp_aad_rem: coverpoint aad_len[3:0] != 0 iff (rst_n && go && aad_len != 0);
    cp_txt_rem: coverpoint txt_len[3:0] != 0 iff (rst_n && go && txt_len != 0);
    cp_mode: coverpoint {decrypt, key256} iff (rst_n && go);
    cp_tag: coverpoint tag_ok iff (rst_n && m_fin && decrypt && !m_gerr);
    // the DMA always forms well-ordered blocks of at most 16 bytes and at most
    // 65535 + 65535 bytes (the core counts to 2^20): only the sideload-key
    // error (4) can reach the core from here
    cp_code: coverpoint m_code iff (rst_n && m_fin && m_gerr) { bins sideload = {4}; }
    cp_ax: coverpoint {r_err, w_err} iff (rst_n && (r_done || w_done)) { bins ok = {0}; bins rd = {2'b10}; bins wr = {2'b01}; }
  endgroup
  cg_crypto_dma u_cg_crypto_dma = new;

  `FC(in_block_stall, in_valid && !in_ready)
  `FC(out_block_wait, out_valid && !out_ready)
  `FC(drain_after_core_error, m_drop && rs_valid && rs_ready)
  `FC(pad_after_core_error, m_drop && ws_valid && ws_ready)
  `FC(read_ends_first, r_done && !m_w)
  `FC(write_ends_first, w_done && !m_r)
endmodule

bind Crypto_DMA_top Crypto_DMA_sva u_sva (.*);
