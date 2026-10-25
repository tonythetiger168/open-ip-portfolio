// SPDX-License-Identifier: Apache-2.0
// MIPI C-PHY trio: an independent trio decoder works on level tuples
// (rotation = rotating the {A,B,C} tuple, polarity = swapping high and
// low). One copy decodes the DUT's own TX pads and checks burst structure
// (idle, +x entry, sync 3444443, a transition every UI, exactly one
// post-amble), the words against the host handshakes in order, the
// burst end rule, tx_ready and tx_done. A second copy decodes r_a/b/c and
// predicts every RX output and the sticky irq.
`include "cov_macros.svh"

module C_PHY_sva_dec (
  input  logic       clk, rst_n,
  input  logic [5:0] w,
  output int         ph, cnt,
  output logic       ui, mid, e_enter, e_badentry, e_err, e_word, e_post, e_done, e_extra4,
  output logic [2:0] sym,
  output logic [16:0] word
);
  localparam logic [1:0] L = 2'b00, M = 2'b01, H = 2'b10;
  localparam int IDLE = 0, SYNC = 1, DATA = 2, POST = 3, ERR = 4;
  localparam logic [5:0] PX = {H, L, M}, MID = {M, M, M};

  function automatic logic [5:0] swp(input logic [5:0] t);   // swap H and L
    for (int i = 0; i < 3; i++)
      swp[2*i +: 2] = t[2*i +: 2] == H ? L : t[2*i +: 2] == L ? H : t[2*i +: 2];
  endfunction
  function automatic logic [5:0] rot_r(input logic [5:0] t);  // (A,B,C) -> (C,A,B)
    return {t[1:0], t[5:2]};
  endfunction
  function automatic logic [5:0] rot_l(input logic [5:0] t);  // (A,B,C) -> (B,C,A)
    return {t[3:0], t[5:4]};
  endfunction
  function automatic bit perm(input logic [5:0] t);
    return t[5:4] != t[3:2] && t[3:2] != t[1:0] && t[5:4] != t[1:0] &&
           t[5:4] != 2'b11 && t[3:2] != 2'b11 && t[1:0] != 2'b11;
  endfunction

  logic [5:0]  prev;
  logic [16:0] acc;
  int p5;
  always_comb begin
    mid  = w == MID;
    ui = perm(w) && w != prev;
    if (w == swp(prev))               sym = 3'd4;
    else if (w == rot_r(prev))        sym = 3'd2;
    else if (w == swp(rot_r(prev)))   sym = 3'd3;
    else if (w == rot_l(prev))        sym = 3'd0;
    else                              sym = 3'd1;
    p5 = 1;
    for (int i = 0; i < 7; i++) if (i < cnt) p5 *= 5;
    word = 17'(cnt == 0 ? 0 : int'(acc)) + 17'(int'(sym) * p5);
    e_enter = ph == IDLE && w == PX;
    e_badentry = ph == IDLE && !mid && w != PX;
    e_word = ph == DATA && ui && cnt == 6 && word < 65536;
    e_post = ph == DATA && ui && cnt == 6 && word == 78124;
    e_done = ph == POST && mid;
    e_extra4 = ph == POST && ui && sym == 3'd4;
    e_err = e_badentry ||
            (ph == SYNC && (!ui || sym != ((cnt == 0 || cnt == 6) ? 3'd3 : 3'd4))) ||
            (ph == DATA && (!ui || (cnt == 6 && word >= 65536 && word != 78124))) ||
            (ph == POST && !mid && !(ui && sym == 3'd4));
  end

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin ph <= IDLE; cnt <= 0; prev <= MID; acc <= 0; end
    else begin
      prev <= w;
      if (e_err) ph <= ERR;
      else case (ph)
        IDLE: begin cnt <= 0; if (e_enter) ph <= SYNC; end
        SYNC: begin cnt <= cnt + 1; if (cnt == 6) begin ph <= DATA; cnt <= 0; end end
        DATA: begin
          acc <= word; cnt <= cnt == 6 ? 0 : cnt + 1;
          if (e_post) ph <= POST;
        end
        POST: if (mid) ph <= IDLE;
        ERR:  if (mid) ph <= IDLE;
        default: ;
      endcase
    end
  end
endmodule

module C_PHY_sva (
  input logic        clk, rst_n, irq, irq_clear, tx_valid, tx_ready, tx_last, tx_done,
  input logic        rx_active, rx_valid, rx_done,
  input logic [15:0] tx_data, rx_data,
  input logic [1:0]  t_a, t_b, t_c, r_a, r_b, r_c
);
  `COV_CLOCKING(clk, !rst_n)
  localparam int IDLE = 0, SYNC = 1, DATA = 2, POST = 3, ERR = 4;

  // ---------------- TX side ----------------
  int t_ph, t_cnt;
  logic t_tran, t_mid, t_enter, t_badentry, t_err, t_word, t_post, t_done, t_extra4;
  logic [2:0] t_sym;
  logic [16:0] t_wv;
  C_PHY_sva_dec u_tdec (.clk, .rst_n, .w({t_a, t_b, t_c}), .ph(t_ph), .cnt(t_cnt), .ui(t_tran),
    .mid(t_mid), .e_enter(t_enter), .e_badentry(t_badentry), .e_err(t_err), .e_word(t_word),
    .e_post(t_post), .e_done(t_done), .e_extra4(t_extra4), .sym(t_sym), .word(t_wv));

  logic [16:0] q [0:255];             // accepted {last, data}
  int          qh, qt;
  logic        m_buf, rdy_q, was_mid, exp_post;
  wire  [16:0] cur = q[qh[7:0]];
  // the buffered word is taken when the last sync symbol, or the last
  // symbol of a non-final word with the buffer full, goes on the wire
  wire consume = (t_ph == SYNC && t_cnt == 6) || (t_ph == DATA && t_cnt == 6 && !rdy_q && !cur[16]);
  wire exp_ready = !(m_buf && !consume);
  // continue after a word: buffer was full and the word was not the last
  wire cont = !rdy_q && !cur[16];
  logic f_underrun, f_b2b, f_multi;

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin qh <= 0; qt <= 0; m_buf <= 0; rdy_q <= 1; was_mid <= 1; exp_post <= 0; {f_underrun, f_b2b, f_multi} <= '0; end
    else begin
      {f_underrun, f_b2b, f_multi} <= '0;
      rdy_q <= tx_ready;
      was_mid <= t_mid;
      if (consume) m_buf <= 0;
      if (t_ph == SYNC && t_cnt == 6) exp_post <= 0;   // first group is data
      if (tx_valid && tx_ready) begin q[qt[7:0]] <= {tx_last, tx_data}; qt <= qt + 1; m_buf <= 1; end
      if (t_word) begin
        qh <= qh + 1;
        f_underrun <= !cont && !cur[16];
        f_multi <= cont;
        exp_post <= !cont;
      end
      f_b2b <= t_done && m_buf;
    end
  end

  `SVA_RST(a_reset_idle, !rst_n, t_mid && tx_ready && !tx_done && !irq && !rx_active && !rx_valid && !rx_done)
  `SVA_INV(a_tx_no_protocol_error, !t_err)
  `SVA_INV(a_tx_single_postamble, !t_extra4)
  `SVA_IMP(a_tx_word_matches_host, t_word, qh != qt && t_wv[15:0] == cur[15:0])
  `SVA_IMP(a_tx_burst_end_rule, t_ph == DATA && t_cnt == 6 && t_tran, t_post == exp_post)
  `SVA_INV(a_tx_ready, tx_ready == exp_ready)
  `SVA_INV(a_tx_done, tx_done == (t_mid && !was_mid))
  `SVA_IMP(a_tx_enters_only_with_data, t_enter, qh != qt)

  // ---------------- RX side ----------------
  int r_ph, r_cnt;
  logic r_tran, r_mid, r_enter, r_badentry, r_err, r_word, r_post, r_done, r_extra4;
  logic [2:0] r_sym;
  logic [16:0] r_wv;
  C_PHY_sva_dec u_rdec (.clk, .rst_n, .w({r_a, r_b, r_c}), .ph(r_ph), .cnt(r_cnt), .ui(r_tran),
    .mid(r_mid), .e_enter(r_enter), .e_badentry(r_badentry), .e_err(r_err), .e_word(r_word),
    .e_post(r_post), .e_done(r_done), .e_extra4(r_extra4), .sym(r_sym), .word(r_wv));

  logic        m_irq, m_valid, m_done;
  logic [15:0] m_data;
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin m_irq <= 0; m_valid <= 0; m_done <= 0; m_data <= 0; end
    else begin
      if (irq_clear) m_irq <= 0;
      if (r_err) m_irq <= 1;
      m_valid <= r_word;
      if (r_word) m_data <= r_wv[15:0];
      m_done <= r_done;
    end
  end

  `SVA_INV(a_rx_irq, irq == m_irq)
  `SVA_INV(a_rx_valid, rx_valid == m_valid)
  `SVA_INV(a_rx_data, rx_data == m_data)
  `SVA_INV(a_rx_done, rx_done == m_done)
  `SVA_INV(a_rx_active, rx_active == (r_ph == SYNC || r_ph == DATA || r_ph == POST))

  // ---------------- coverage ----------------
  `FC(tx_word_continues, f_multi)
  `FC(tx_underrun_ends_burst, f_underrun)
  `FC(tx_new_word_waiting_at_done, f_b2b)
  `FC(rx_sym_flip, r_ph == DATA && r_tran && r_sym == 3'd4)
  `FC(rx_sym_cw_same, r_ph == DATA && r_tran && r_sym == 3'd2)
  `FC(rx_sym_cw_inv, r_ph == DATA && r_tran && r_sym == 3'd3)
  `FC(rx_sym_ccw_same, r_ph == DATA && r_tran && r_sym == 3'd0)
  `FC(rx_sym_ccw_inv, r_ph == DATA && r_tran && r_sym == 3'd1)
  `FC(rx_word_ffff, r_word && r_wv == 17'hFFFF)
  `FC(rx_word_0000, r_word && r_wv == 17'h0)
  `FC(rx_post_then_idle, r_done)
  `FC(rx_long_postamble, r_extra4)
  `FC(err_bad_entry, r_badentry)
  `FC(err_sync_symbol, r_ph == SYNC && r_tran && r_err)
  `FC(err_no_transition, r_ph == DATA && !r_mid && !r_tran)
  `FC(err_stop_mid_word, r_ph == DATA && r_mid && r_cnt != 0)
  `FC(err_stop_without_post, r_ph == DATA && r_mid && r_cnt == 0)
  `FC(err_word_overflow, r_ph == DATA && r_tran && r_cnt == 6 && r_err)
  `FC(err_after_post, r_ph == POST && r_err)
  `FC(err_while_sticky, r_err && irq)
  `FC(irq_clear_same_cycle_error, irq_clear && r_err)
  `FC_RST(reset_mid_burst, rst_n && !t_mid ##1 !rst_n)
endmodule

bind C_PHY_top C_PHY_sva u_sva (.*);
