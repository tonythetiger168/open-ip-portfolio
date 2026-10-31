// SPDX-License-Identifier: Apache-2.0
// HSI endpoint: concurrent SVA against an independent reference model,
// plus functional coverage.
//  * Transmitter: a frame is latched when it starts and sent by bit index
//    (start, channel bits, data); each bit drives DATA or toggles FLAG and
//    is held cfg_div + 1 clocks. Breaks send flen zeros. READY is used two
//    clocks late.
//  * Receiver: own synchronisers and bit events, a bit accumulator, the
//    zero run between frames, the timeout deadline and a frame queue.
// Every output is compared on every clock.
`include "cov_macros.svh"
module HSI_sva (
  input logic        clk, rst_n,
  input logic        tx_data, tx_flag, tx_ready_in, tx_wake,
  input logic        rx_data, rx_flag, rx_ready_out, rx_wake,
  input logic [7:0]  cfg_div,
  input logic [2:0]  cfg_chbits,
  input logic        cfg_rx_en, cfg_wake,
  input logic        txq_valid, txq_ready,
  input logic [3:0]  txq_ch,
  input logic [31:0] txq_data,
  input logic        tx_brk, tx_busy, tx_done,
  input logic        rxq_valid, rxq_ready,
  input logic [3:0]  rxq_ch,
  input logic [31:0] rxq_data,
  input logic        rx_break, err_overflow, err_stray, err_ds, err_timeout
);
  `COV_CLOCKING(clk, !rst_n)

  function automatic int nch(input logic [2:0] c);
    return c > 4 ? 4 : int'(c);
  endfunction
  // bit p of a frame (0 = start bit)
  function automatic bit fbit(input int p, input int cb, input logic [3:0] ch, input logic [31:0] d);
    if (p == 0) return 1'b1;
    if (p <= cb) return ch[cb - p];
    return d[31 - (p - 1 - cb)];
  endfunction

  // ---------------- model state ----------------
  int          t_mode;                   // 0 idle, 1 frame, 2 break
  bit          t_hold, t_breq, t_r1, t_r2, t_d, t_f, t_done;
  logic [3:0]  t_hch, t_fch;
  logic [31:0] t_hd, t_fd;
  int          t_cb, t_pos, t_len, t_wait;
  bit [1:0]    r_ds, r_fs;
  bit          r_dq, r_fq, r_in;
  int          r_need, r_zero, r_since;
  logic [35:0] r_acc;
  logic [35:0] q [$];
  bit          m_brk, m_ovf, m_stray, m_ds, m_tmo;
  // coverage
  bit          v_full_pp, v_wait_rdy, v_brk_busy, v_brk_and_frame, v_tmo_ch, v_zero_sat, v_ds_frame;
  bit          v_sent [0:5], v_rcvd [0:4];
  bit          v_div_min, v_div_max, v_same, v_diff;

  wire [5:0] w_flen = 6'(33 + nch(cfg_chbits));

  always @(posedge clk or negedge rst_n)
    if (!rst_n) begin
      t_mode = 0; {t_hold, t_breq, t_r1, t_r2, t_d, t_f, t_done} = '0;
      t_hch = 0; t_fch = 0; t_hd = 0; t_fd = 0; t_cb = 0; t_pos = 0; t_len = 0; t_wait = 0;
      r_ds = 0; r_fs = 0; r_dq = 0; r_fq = 0; r_in = 0; r_need = 0; r_zero = 0; r_since = 0; r_acc = 0;
      q.delete();
      {m_brk, m_ovf, m_stray, m_ds, m_tmo} = '0;
    end else begin : b_step
      bit acc, rn, dn, fn, ev, pop, lastb;
      // ---------------- transmitter ----------------
      acc = txq_valid && !t_hold;
      rn = t_r2;
      t_r2 = t_r1; t_r1 = tx_ready_in;
      t_done = 0;
      if (t_mode == 0) begin
        if (t_breq) begin
          t_mode = 2; t_breq = 0; t_pos = 0; t_len = int'(w_flen); t_wait = 0;
          if (t_hold) v_brk_and_frame = 1;
        end else if (t_hold && rn) begin
          t_mode = 1; t_hold = 0; t_pos = 0; t_cb = nch(cfg_chbits); t_len = 33 + t_cb; t_wait = 0;
          t_fch = t_hch; t_fd = t_hd;
        end else if (t_hold) v_wait_rdy = 1;
      end else if (t_wait > 0) t_wait--;
      else if (t_pos == t_len) begin
        if (t_mode == 1) begin t_done = 1; v_sent[t_cb] = 1; if (cfg_chbits > 4) v_sent[5] = 1; end
        t_mode = 0;
      end else begin : b_bit
        bit b;
        b = t_mode == 2 ? 1'b0 : fbit(t_pos, t_cb, t_fch, t_fd);
        if (b != t_d) begin t_d = b; v_diff = 1; end
        else begin t_f = !t_f; v_same = 1; end
        t_pos++; t_wait = int'(cfg_div);
        if (cfg_div == 3) v_div_min = 1;
        if (cfg_div == 255) v_div_max = 1;
      end
      if (acc) begin t_hold = 1; t_hch = txq_ch; t_hd = txq_data; end
      if (tx_brk) begin
        if (t_mode != 0) v_brk_busy = 1;
        t_breq = 1;
      end

      // ---------------- receiver ----------------
      dn = r_ds[1]; fn = r_fs[1];
      ev = dn != r_dq || fn != r_fq;
      pop = q.size() != 0 && rxq_ready;
      lastb = r_in && ev && r_need == 1;
      {m_brk, m_ovf, m_stray, m_ds, m_tmo} = '0;
      if (dn != r_dq && fn != r_fq) begin m_ds = 1; if (r_in) v_ds_frame = 1; end
      if (pop) begin
        if (q.size() == 4 && lastb) v_full_pp = 1;
        void'(q.pop_front());
      end
      if (lastb) begin
        if (q.size() < 4) q.push_back({r_acc[34:0], dn});
        else m_ovf = 1;
        v_rcvd[nch(cfg_chbits)] = 1;
      end
      if (!r_in) begin
        if (ev) begin
          if (dn) begin
            if (r_zero != 0 && r_zero < int'(w_flen)) m_stray = 1;
            r_zero = 0; r_in = 1; r_need = int'(w_flen) - 1; r_acc = 0;
          end else if (r_zero < 63) begin
            r_zero++;
            if (r_zero == int'(w_flen)) m_brk = 1;
          end else v_zero_sat = 1;
        end
      end else if (ev) begin
        r_acc = {r_acc[34:0], dn}; r_need--;
        if (r_need == 0) r_in = 0;
      end else if (r_since == 4 * int'(cfg_div) + 3) begin
        r_in = 0; m_tmo = 1;
        if (r_need > 32) v_tmo_ch = 1;
      end
      r_since = ev ? 0 : (r_since == 1023 ? 1023 : r_since + 1);
      r_dq = dn; r_fq = fn;
      r_ds = {r_ds[0], rx_data}; r_fs = {r_fs[0], rx_flag};
    end

  wire       m_busy = t_mode != 0 || t_breq;
  wire       m_ready = cfg_rx_en && rx_wake && (q.size() + int'(r_in)) <= 3;
  wire [35:0] m_head = q.size() != 0 ? q[0] : '0;

  // ---------------- assertions ----------------
  `SVA_INV(a_tx_lines, tx_data == t_d && tx_flag == t_f)
  `SVA_INV(a_txq_ready, txq_ready == !t_hold)
  `SVA_INV(a_tx_busy, tx_busy == m_busy)
  `SVA_INV(a_tx_wake, tx_wake == (t_hold || t_mode != 0 || cfg_wake))
  `SVA_INV(a_tx_done, tx_done == t_done)
  `SVA_INV(a_rx_ready, rx_ready_out == m_ready)
  `SVA_INV(a_rxq_valid, rxq_valid == (q.size() != 0))
  `SVA_IMP(a_rxq_frame, q.size() != 0, {rxq_ch, rxq_data} == m_head)
  `SVA_INV(a_rx_break, rx_break == m_brk)
  `SVA_INV(a_overflow, err_overflow == m_ovf)
  `SVA_INV(a_stray, err_stray == m_stray)
  `SVA_INV(a_ds, err_ds == m_ds)
  `SVA_INV(a_timeout, err_timeout == m_tmo)
  `SVA_IMP(a_one_line, $changed(tx_data), $stable(tx_flag))
  `SVA_RST(a_rst_lines, 1'b1, !tx_data && !tx_flag && txq_ready && !tx_busy && !rxq_valid)

  function automatic int dcls(input logic [31:0] v);
    return v == 32'd0 ? 0 : v == '1 ? 1 : (v == 32'h5555_5555 || v == 32'hAAAA_AAAA) ? 2 : 3;
  endfunction
  // frames taken and handed out: channel (4 channel bits) and data class
  covergroup cg_hsi @(negedge clk);
    option.per_instance = 1;
    cp_tch: coverpoint txq_ch iff (rst_n && txq_valid && txq_ready && cfg_chbits == 4) { bins c[] = {[0:15]}; }
    cp_tdata: coverpoint dcls(txq_data) iff (rst_n && txq_valid && txq_ready)
      { bins zero = {0}; bins ones = {1}; bins alt = {2}; bins other = {3}; }
    cp_rch: coverpoint rxq_ch iff (rst_n && rxq_valid && rxq_ready && cfg_chbits == 4) { bins c[] = {[0:15]}; }
    cp_rdata: coverpoint dcls(rxq_data) iff (rst_n && rxq_valid && rxq_ready)
      { bins zero = {0}; bins ones = {1}; bins alt = {2}; bins other = {3}; }
  endgroup
  cg_hsi u_cg_hsi = new;

  // ---------------- functional coverage ----------------
  `FC(sent_chbits_0, v_sent[0])
  `FC(sent_chbits_1, v_sent[1])
  `FC(sent_chbits_2, v_sent[2])
  `FC(sent_chbits_3, v_sent[3])
  `FC(sent_chbits_4, v_sent[4])
  `FC(sent_chbits_over_4, v_sent[5])
  `FC(rcvd_chbits_0, v_rcvd[0])
  `FC(rcvd_chbits_1, v_rcvd[1])
  `FC(rcvd_chbits_2, v_rcvd[2])
  `FC(rcvd_chbits_3, v_rcvd[3])
  `FC(rcvd_chbits_4, v_rcvd[4])
  `FC(bit_time_min, v_div_min)
  `FC(bit_time_max, v_div_max)
  `FC(bit_on_data, v_diff)
  `FC(bit_on_flag, v_same)
  `FC(wait_for_ready, v_wait_rdy)
  `FC(fifo_full, q.size() == 4)
  `FC(full_push_with_pop, v_full_pp)
  `FC(ready_low_wake, !rx_wake && cfg_rx_en && q.size() == 0)
  `FC(ready_low_disabled, rx_wake && !cfg_rx_en)
  `FC(wake_forced, cfg_wake && !t_hold && t_mode == 0)
  `FC(break_sent, t_mode == 2 && t_pos == t_len && t_wait == 0)
  `FC(break_while_busy, v_brk_busy)
  `FC(break_before_frame, v_brk_and_frame)
  `FC(break_received, m_brk)
  `FC(overflow, m_ovf)
  `FC(stray_zeros, m_stray)
  `FC(ds_error, m_ds)
  `FC(ds_error_in_frame, v_ds_frame)
  `FC(timeout, m_tmo)
  `FC(timeout_in_channel_bits, v_tmo_ch)
  `FC(zero_run_saturates, v_zero_sat)
  `FC_RST(reset_in_frame, rst_n && t_mode == 1 ##1 !rst_n)
endmodule

bind HSI_top HSI_sva u_sva (.*);
