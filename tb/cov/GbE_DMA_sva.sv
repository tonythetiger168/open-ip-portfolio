// SPDX-License-Identifier: Apache-2.0
// GbE_DMA (Ethernet_top MAC with TX / RX descriptor rings moved by one
// soc_ss_axi_engine): concurrent SVA against a model of the ring and frame
// rules written from the header, + functional coverage. The model follows
// the scheduler step that is running (st) and checks each engine job it
// starts against the descriptor it belongs to, keeps its own copy of the TX
// frame words and of every RX frame's bytes, and from them checks:
//  - descriptor fetches (2 words at BASE + 8 * HEAD), TX buffer reads
//    (word 0, ceil(len / 4) words), RX buffer writes (word 0, ceil(min(len,
//    size) / 4) words), status write-backs (1 word at descriptor + 4);
//  - every TX byte handed to the MAC (store and forward: the whole frame is
//    in the FIFO first; byte order; TX_LAST on the last byte) and the TX
//    status {done, underrun, bad_len, len} (bad_len: 0 or > TXF_BYTES);
//  - every word written to an RX buffer (the frame's bytes in address order,
//    zero padded) and the RX status {done, trunc, stat, len};
//  - the RX drop rules (RX_EN off or 4 frames waiting at the first byte, or
//    the FIFO full), RX_DROP / DROP interrupt;
//  - TX_HEAD / RX_HEAD (wrap at NUM), TX_FRAMES / RX_FRAMES, the TX / RX
//    interrupts, ERR (sticky until CLR_ERR) and its interrupt.
// The engine and the MAC are closed by their own runs.
`include "cov_macros.svh"
module GbE_DMA_sva #(parameter int TXF_BYTES = 2048, parameter int RXF_BYTES = 4096) (
  input logic        clk, rst_n, tx_en, rx_en, clr_err, err,
  input logic [31:0] tx_base, rx_base,
  input logic [15:0] tx_num, tx_tail, tx_head, rx_num, rx_tail, rx_head, tx_frames, rx_frames, rx_drop,
  input logic        tx_irq, rx_irq, drop_irq, err_irq,
  input logic        e_start, e_rd, e_wr, e_done, e_err,
  input logic [31:0] e_src, e_dst,
  input logic [15:0] e_len,
  input logic        rs_valid, rs_ready, ws_valid, ws_ready,
  input logic [31:0] rs_data, ws_data,
  input logic        tx_valid, tx_ready, tx_last, tx_done, tx_underrun,
  input logic [7:0]  tx_data, rx_data,
  input logic        rx_valid, rx_last,
  input logic [3:0]  rx_stat,
  input logic [3:0]  st,
  input logic        txs_pend, tx_busy
);
  `COV_CLOCKING(clk, !rst_n)
  localparam logic [3:0] S_IDLE = 0, S_TXD = 1, S_TXB = 2, S_TXS = 3, S_RXD = 4, S_RXB = 5, S_RXDRAIN = 6, S_RXS = 7;
  localparam int RW = RXF_BYTES / 4;
  function automatic logic [15:0] wds(input logic [15:0] b); wds = 16'((32'(b) + 3) / 4); endfunction

  // ---------------------------------------------------------------- RX side
  // bytes of the frame arriving, accepted frames waiting ({stat, len} and
  // bytes), FIFO words in use
  logic [7:0]  f_bytes [$];
  logic [7:0]  w_bytes [$];          // bytes of the waiting frames, in order
  logic [19:0] w_info [$];
  logic        f_in, f_bad;
  int          fifo_w;              // RX FIFO words held (waiting frames + the one arriving)
  int          f_w;                 // words of the arriving frame pushed so far
  logic [15:0] m_drop;
  wire  [2:0]  n_wait = 3'(w_info.size());
  wire         f_word = rx_valid && (f_bytes.size() % 4 == 3 || rx_last);   // a word completes
  logic        f_drop_now;
  // what the IDLE step serves: a TX status first, then an RX frame, then TX
  wire rx_rdy = rx_en && w_info.size() != 0 && r_head != rx_tail;
  wire tx_rdy = tx_en && !tx_busy && t_head != tx_tail;
  always_comb begin
    f_drop_now = 0;
    if (rx_valid && rx_last)
      f_drop_now = (f_in ? f_bad : (!rx_en || n_wait == 4)) || (f_word && !(f_in ? f_bad : 0) && fifo_w >= RW);
  end
  // ---------------------------------------------------------------- TX side
  logic [31:0] t_words [$];
  logic [15:0] t_len, t_bi, t_head, r_head, t_frames, r_frames;
  logic [31:0] d_w0, d_w1;
  logic        t_ur, t_bad, m_err;
  logic [1:0]  d_n;
  logic [15:0] r_take, r_left;      // RX: words to write, written
  int          r_drain;             // RX: FIFO words of the frame left after the copy
  wire  [15:0] w_len  = w_info.size() ? w_info[0][15:0] : 16'd0;
  wire  [3:0]  w_stat = w_info.size() ? w_info[0][19:16] : 4'd0;

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      f_bytes.delete(); w_bytes.delete(); w_info.delete(); f_in <= 0; f_bad <= 0; fifo_w <= 0; f_w <= 0; m_drop <= 0;
      t_words.delete(); t_len <= 0; t_bi <= 0; t_head <= 0; r_head <= 0; t_frames <= 0; r_frames <= 0;
      d_w0 <= 0; d_w1 <= 0; t_ur <= 0; t_bad <= 0; m_err <= 0; d_n <= 0;
      r_take <= 0; r_left <= 0; r_drain <= 0;
    end else begin
      int dfw;
      dfw = 0;
      // RX frames from the MAC
      if (rx_valid) begin
        logic bad;
        bad = f_in ? f_bad : (!rx_en || n_wait == 4);
        if (f_word && !bad && fifo_w >= RW) bad = 1;
        if (rx_last) begin
          if (bad) begin m_drop <= m_drop + 1; dfw -= f_w; end
          else begin
            foreach (f_bytes[i]) w_bytes.push_back(f_bytes[i]);
            w_bytes.push_back(rx_data);
            w_info.push_back({rx_stat, 16'(f_bytes.size() + 1)});
            dfw += f_word ? 1 : 0;
          end
          f_bytes.delete(); f_in <= 0; f_bad <= 0; f_w <= 0;
        end else begin
          f_bytes.push_back(rx_data); f_in <= 1; f_bad <= bad;
          if (f_word && !bad) begin dfw += 1; f_w <= f_w + 1; end
        end
      end
      // ERR
      if (clr_err) m_err <= 0;
      if (e_done && e_err) m_err <= 1;
      // descriptor words
      if ((st == S_TXD || st == S_RXD) && rs_valid) begin if (d_n == 0) d_w0 <= rs_data; else d_w1 <= rs_data; d_n <= d_n + 1; end
      if ((st == S_TXD || st == S_RXD) && e_start) d_n <= 0;
      // TX frame words, bytes to the MAC
      if (st == S_TXB && rs_valid) t_words.push_back(rs_data);
      if (st == S_TXD && e_done && !e_start) begin
        t_len <= d_w1[15:0]; t_bad <= d_w1[15:0] == 0 || d_w1[15:0] > 16'(TXF_BYTES); t_bi <= 0; t_words.delete();
      end
      if (st == S_TXB && e_done && !e_start) t_ur <= 0;
      if (tx_underrun) t_ur <= 1;
      if (tx_valid && tx_ready) begin
        t_bi <= t_bi + 1;
        if (t_bi[1:0] == 3 || tx_last) void'(t_words.pop_front());
      end
      if (st == S_TXS && e_done && !e_start) begin
        t_head <= (t_head + 1 == tx_num) ? 16'd0 : t_head + 1;
        if (!t_bad) t_frames <= t_frames + 1;
      end
      // RX copy
      if (st == S_RXD && e_done && !e_start) begin
        r_take <= wds(w_len > d_w1[15:0] ? d_w1[15:0] : w_len); r_left <= 0;
        r_drain <= int'(wds(w_len)) - int'(wds(w_len > d_w1[15:0] ? d_w1[15:0] : w_len));
      end
      if (st == S_RXB && ws_valid && ws_ready) begin r_left <= r_left + 1; dfw -= 1; end
      if (st == S_RXDRAIN && r_drain != 0) begin r_drain <= r_drain - 1; dfw -= 1; end
      if (st == S_RXS && e_done && !e_start) begin
        r_head <= (r_head + 1 == rx_num) ? 16'd0 : r_head + 1; r_frames <= r_frames + 1;
        repeat (int'(w_len)) void'(w_bytes.pop_front());
        void'(w_info.pop_front());
      end
      fifo_w <= fifo_w + dfw;
    end
  end

  function automatic logic [31:0] rx_word(input int k);   // word k of the waiting frame, zero padded
    logic [31:0] w;
    w = 0;
    for (int b = 0; b < 4; b++) if (4 * k + b < int'(w_len)) w[8 * b +: 8] = w_bytes[4 * k + b];
    return w;
  endfunction
  function automatic logic [7:0] tx_byte;
    return t_words.size() ? t_words[0][8 * t_bi[1:0] +: 8] : 8'hxx;
  endfunction

  `SVA_RST(a_reset_idle, !rst_n, tx_head == 0 && rx_head == 0 && tx_frames == 0 && rx_frames == 0 && rx_drop == 0
                                 && !err && !tx_valid && !e_start)
  `SVA_INV(a_heads, tx_head == t_head && rx_head == r_head)
  `SVA_INV(a_counters, tx_frames == t_frames && rx_frames == r_frames && rx_drop == m_drop)
  `SVA_INV(a_err, err == m_err)
  `SVA_NXT(a_err_irq, e_done && e_err, err_irq)
  `SVA_INV(a_irqs, tx_irq == $past(st == S_TXS && e_done && !e_start) && rx_irq == $past(st == S_RXS && e_done && !e_start)
                   && drop_irq == $past(rx_valid && rx_last && f_drop_now))
  // the scheduler: a TX status first, then an RX frame, then a TX frame
  `SVA_IMP(a_sched, st == S_IDLE, ##1 (txs_pend ? st == S_TXS : rx_rdy ? st == S_RXD : tx_rdy ? st == S_TXD : st == S_IDLE))
  // engine jobs (started the clock after the step is entered)
  `SVA_IMP(a_job_rx_desc, st == S_RXD && e_start, e_src == rx_base + {13'd0, r_head, 3'b000} && e_len == 2 && e_rd && !e_wr
                                                  && w_info.size() != 0)
  `SVA_IMP(a_job_tx_desc, st == S_TXD && e_start, e_src == tx_base + {13'd0, t_head, 3'b000} && e_len == 2 && e_rd && !e_wr)
  `SVA_IMP(a_job_tx_status, st == S_TXS && e_start, e_dst == tx_base + {13'd0, t_head, 3'b100} && e_len == 1 && !e_rd && e_wr)
  `SVA_IMP(a_job_tx_buf, st == S_TXB && e_start, e_src == d_w0 && e_len == wds(t_len) && e_rd && !e_wr && !t_bad)
  `SVA_IMP(a_job_rx_buf, st == S_RXB && e_start, e_dst == d_w0 && e_len == r_take && !e_rd && e_wr && r_take != 0)
  `SVA_IMP(a_job_rx_status, st == S_RXS && e_start, e_dst == rx_base + {13'd0, r_head, 3'b100} && e_len == 1 && !e_rd && e_wr)
  `SVA_INV(a_job_only_on_entry, e_start -> $past(st) != st)
  // TX: store and forward, bytes in order, status
  `SVA_IMP(a_tx_store_fwd, tx_valid, st != S_TXB && t_words.size() == int'(wds(t_len)) - int'(t_bi / 4))
  `SVA_IMP(a_tx_byte, tx_valid, tx_data == tx_byte() && tx_last == (t_bi + 1 == t_len))
  `SVA_IMP(a_tx_status, st == S_TXS && ws_valid,
           ws_data == {1'b1, 1'b0, t_ur && !t_bad, t_bad, 12'd0, t_len})
  // RX: buffer words, status
  `SVA_IMP(a_rx_word, st == S_RXB && ws_valid, ws_data == rx_word(int'(r_left)) && r_left < r_take)
  `SVA_IMP(a_rx_status, st == S_RXS && ws_valid,
           ws_data == {1'b1, w_len > d_w1[15:0], 10'd0, w_stat, w_len})

  covergroup cg_gbe @(posedge clk);
    option.per_instance = 1;
    cp_tx_len: coverpoint (t_len == 0 ? 3'd0 : t_len < 64 ? 3'd1 : t_len < 1519 ? 3'd2 : t_len <= TXF_BYTES ? 3'd3 : 3'd4)
                 iff (rst_n && st == S_TXS && e_done && !e_start)
      { bins zero = {0}; bins short_ = {1}; bins normal = {2}; bins jumbo = {3}; bins too_long = {4}; }
    cp_tx_rem: coverpoint t_len[1:0] iff (rst_n && st == S_TXB && e_done && !e_start);
    cp_tx_ur: coverpoint t_ur iff (rst_n && st == S_TXS && e_done && !e_start && !t_bad);
    cp_rx_fit: coverpoint {w_len > d_w1[15:0], d_w1[15:0] == 0} iff (rst_n && st == S_RXD && e_done && !e_start)
      { bins fits = {2'b00}; bins trunc = {2'b10}; bins no_room = {2'b11}; }
    cp_rx_rem: coverpoint w_len[1:0] iff (rst_n && st == S_RXD && e_done && !e_start);
    cp_rx_stat: coverpoint w_stat iff (rst_n && st == S_RXS && e_done && !e_start)
      { bins good = {0}; bins crc = {1}; bins len_err = {2}; bins phy = {4}; bins pause = {8}; }
    cp_waiting: coverpoint n_wait iff (rst_n && rx_valid && !f_in) { bins n[] = {[0:4]}; }
  endgroup
  cg_gbe u_cg_gbe = new;

  `FC(tx_ring_wrap, st == S_TXS && e_done && !e_start && t_head + 1 == tx_num)
  `FC(rx_ring_wrap, st == S_RXS && e_done && !e_start && r_head + 1 == rx_num)
  `FC(rx_waits_for_descriptor, rx_en && w_info.size() != 0 && r_head == rx_tail && st == S_IDLE)
  `FC(rx_before_tx, st == S_IDLE && !txs_pend && rx_rdy && tx_rdy)
  `FC(tx_status_before_rx, st == S_IDLE && txs_pend && rx_rdy)
  `FC(drop_rx_off, rx_valid && !f_in && !rx_en)
  `FC(drop_four_waiting, rx_valid && !f_in && rx_en && n_wait == 4)
  `FC(drop_fifo_full, rx_valid && f_word && !(f_in && f_bad) && !(!f_in && (!rx_en || n_wait == 4)) && fifo_w >= RW)
  `FC(rx_while_tx_sending, tx_valid && rx_valid)
  `FC(err_cleared, err && clr_err)
  `FC(tx_stall, tx_valid && !tx_ready)
  `FC(rx_buf_stall, st == S_RXB && ws_valid && !ws_ready)
  `FC_RST(reset_mid_tx, rst_n && tx_valid ##1 !rst_n)
  `FC_RST(reset_mid_rx_frame, rst_n && f_in ##1 !rst_n)
endmodule

bind GbE_DMA_top GbE_DMA_sva #(.TXF_BYTES(TXF_BYTES), .RXF_BYTES(RXF_BYTES)) u_sva (.*);
