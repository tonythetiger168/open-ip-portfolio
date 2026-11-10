// SPDX-License-Identifier: Apache-2.0
// I2S_DMA (I2S_top fed and drained by soc_ss_axi_engine): concurrent SVA
// against a model of the frame-level DMA rules written from the header, fed
// by the job pins, the engine streams and the frame edges (the left-to-right
// and frame-start changes and the BCLK rises seen through the core's own
// synchronizers: to_right, to_left, bclk_rise), + functional coverage.
// TX: a word is taken at each left-to-right change while the job has words
// left (else TX_UNDERRUN counts the frame), its left half written to the
// core then and its right half at the next frame start. RX: frames that
// start after the first frame start of the job are captured one BCLK rise
// after their end (the core's RX_LEFT / RX_RIGHT then), offered to the
// engine, replaced by the next one if not taken (RX_OVERRUN). FRAMES counts
// the words taken (TX) or loaded (RX only). The engine and the core are
// closed by their own runs.
`include "cov_macros.svh"
module I2S_DMA_sva (
  input logic        clk, rst_n, start, busy, done, err, err_irq, tx_en, rx_en,
  input logic [15:0] xfer_len, frames, tx_underrun, rx_overrun,
  input logic        rs_valid, rs_ready, ws_valid, ws_ready,
  input logic [31:0] rs_data, rx_word,
  input logic        wen,
  input logic [3:0]  waddr,
  input logic [15:0] wdata,
  input logic        to_left, to_right, bclk_rise
);
  `COV_CLOCKING(clk, !rst_n)
`define SOC_SS_GO (start && !busy && (tx_en || rx_en))
  `include "soc_ss_job_cov.svh"

  logic        t_on, t_have, t_mode;
  logic [15:0] t_r, t_cnt, t_under, m_frames;
  logic        r_on, r_armed, r_wait, r_full;
  logic [2:0]  r_pipe;
  logic [15:0] r_l, r_cnt, r_over;
  logic [31:0] r_word;
  wire         t_take = t_on && to_right && rs_valid;
  wire         r_load = r_pipe[2] && r_on;

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      t_on <= 0; t_have <= 0; t_mode <= 0; t_r <= 0; t_cnt <= 0; t_under <= 0; m_frames <= 0;
      r_on <= 0; r_armed <= 0; r_wait <= 0; r_full <= 0; r_pipe <= 0; r_l <= 0; r_cnt <= 0; r_over <= 0; r_word <= 0;
    end else if (go) begin
      t_on <= tx_en && xfer_len != 0; t_have <= 0; t_mode <= tx_en; t_cnt <= 0; t_under <= 0; m_frames <= 0;
      r_on <= rx_en && xfer_len != 0; r_armed <= 0; r_wait <= 0; r_full <= 0; r_pipe <= 0; r_cnt <= 0; r_over <= 0;
    end else begin
      // TX
      if (t_take) begin
        t_r <= rs_data[31:16]; t_have <= 1; t_cnt <= t_cnt + 1; m_frames <= m_frames + 1;
        if (t_cnt + 1 == xfer_len) t_on <= 0;
      end else if (t_on && to_right) t_under <= t_under + 1;
      if (to_left && t_have) t_have <= 0;
      // RX
      if (r_on && to_left) begin if (r_armed) r_wait <= 1; r_armed <= 1; end
      r_pipe <= {r_pipe[1:0], r_wait && bclk_rise};
      if (r_wait && bclk_rise) r_wait <= 0;
      if (r_pipe[1]) r_l <= u_i2s.rx_left;
      if (r_load) begin
        r_word <= {u_i2s.rx_right, r_l}; r_full <= 1;
        if (r_full && !ws_ready) r_over <= r_over + 1;
        else begin r_cnt <= r_cnt + 1; if (!t_mode) m_frames <= m_frames + 1; end
      end else if (r_full && ws_ready) r_full <= 0;
      if (r_on && r_cnt == xfer_len) r_on <= 0;
    end
  end

  `SVA_RST(a_reset_idle, !rst_n, !busy && frames == 0 && tx_underrun == 0 && rx_overrun == 0 && !ws_valid && !wen)
  `SVA_INV(a_engine_start, u_eng.start == go && (!go || (u_eng.rd_en == tx_en && u_eng.wr_en == rx_en
                                                              && u_eng.len == xfer_len)))
  `SVA_INV(a_tx_take, rs_ready == t_take)
  `SVA_INV(a_core_write, wen == (t_take || (to_left && t_have))
                      && (!t_take || (waddr == 4'd0 && wdata == rs_data[15:0]))
                      && (t_take || !wen || (waddr == 4'd1 && wdata == t_r)))
  `SVA_INV(a_counters, frames == m_frames && tx_underrun == t_under && rx_overrun == r_over)
  `SVA_INV(a_rx_word, ws_valid == r_full && (!ws_valid || rx_word == r_word))
  `SVA_INV(a_done, done == u_eng.done)

  covergroup cg_i2s_dma @(posedge clk);
    option.per_instance = 1;
    cp_mode: coverpoint {tx_en, rx_en} iff (rst_n && go) { bins tx = {2'b10}; bins rx = {2'b01}; bins both = {2'b11}; }
    cp_tx_frame: coverpoint rs_valid iff (rst_n && t_on && to_right) { bins underrun = {0}; bins taken = {1}; }
    cp_rx_load: coverpoint {r_full, ws_ready} iff (rst_n && r_load)
      { bins empty = {2'b00, 2'b01}; bins taken_now = {2'b11}; bins overrun = {2'b10}; }
    cp_tx_last: coverpoint (t_cnt + 1 == xfer_len) iff (rst_n && t_take);
  endgroup
  cg_i2s_dma u_cg_i2s_dma = new;

  `FC(start_ignored_no_mode, start && !busy && !tx_en && !rx_en)
  `FC(rx_frame_skipped_at_start, r_on && !r_armed && to_left)
  `FC(tx_right_after_last_word, !t_on && t_have && to_left)
  // (a TX take and an RX load never fall on the same clock: the take is at
  // the mid-frame LRCK change, the load one BCLK rise after the frame start)
endmodule

bind I2S_DMA_top I2S_DMA_sva u_sva (.*);
