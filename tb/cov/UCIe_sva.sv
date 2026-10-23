// SPDX-License-Identifier: Apache-2.0
// UCIe Adapter Retry: concurrent SVA against an independent reference
// model, plus functional coverage.
//  * The model keeps its own replay buffer, sequence numbers (as integers
//    modulo 16), replay timer, expected SEQ and owed Ack / Nak, and
//    predicts every flit sent (fields and CRC), delivery, tx_ready,
//    tx_pend and event.
//  Every output is compared on every clock.
`include "cov_macros.svh"
module UCIe_sva #(
  parameter int RB = 8, TO = 32
)(
  input logic        clk, rst_n,
  input logic        tx_valid,
  input logic [63:0] tx_data,
  input logic        tx_ready, rx_valid,
  input logic [63:0] rx_data,
  input logic        lt_valid,
  input logic [89:0] lt_flit,
  input logic        lr_valid,
  input logic [89:0] lr_flit,
  input logic [3:0]  tx_pend,
  input logic        ev_crc, ev_replay
);
  `COV_CLOCKING(clk, !rst_n)

  // CRC-16, polynomial 0x1021, seed 0xFFFF, MSB first, table-free
  function automatic logic [15:0] crc(input logic [73:0] d);
    logic [15:0] c;
    c = 16'hFFFF;
    for (int i = 73; i >= 0; i--) begin
      logic fb;
      fb = c[15] ^ d[i];
      c = c << 1;
      if (fb) c = c ^ 16'h1021;
    end
    return c;
  endfunction
  function automatic int m16(input int x); return ((x % 16) + 16) % 16; endfunction

  logic [63:0] buf_ [0:15];               // payloads by SEQ
  int          nxt, old, snd, t, ex;     // next new SEQ, oldest outstanding, next to send, timer, expected
  bit          ow_ack, ow_nak, nk;
  // expected outputs
  bit          o_lt, o_rx, o_crc, o_rep;
  logic [89:0] o_flit;
  logic [63:0] o_rxd;

  // coverage
  bit v_new, v_replay_send, v_nop_ack, v_nop_nak, v_nak_in_data, v_full, v_crc_bad, v_dup, v_ahead, v_ack_bad;
  bit v_nak_rx, v_timeout, v_nak_once, v_ack_partial, v_ack_with_replay, v_clamp, v_wrap, v_rep_and_new;

  function automatic int outstanding(); return m16(nxt - old); endfunction

  always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      for (int i = 0; i < 16; i++) buf_[i] = 0;
      nxt = 0; old = 0; snd = 0; t = 0; ex = 0; ow_ack = 0; ow_nak = 0; nk = 0;
      {o_lt, o_rx, o_crc, o_rep} = '0; o_flit = 0; o_rxd = 0;
    end else begin : b_step
      int old2, snd2, nxt2;
      bit ack2, nak2, rep_now;
      logic [73:0] f;
      {o_lt, o_rx, o_crc, o_rep} = '0;
      old2 = old; snd2 = snd; nxt2 = nxt; ack2 = ow_ack; nak2 = ow_nak; rep_now = snd != nxt;
      if (outstanding() == RB) v_full = 1;
      // ---- what goes out
      f = 'x;
      if (snd != nxt) begin
        f = {1'b1, 4'(snd), 4'(m16(ex - 1)), ow_nak, buf_[snd]};
        snd2 = m16(snd + 1); v_replay_send = 1;
      end else if (tx_valid && outstanding() != RB) begin
        buf_[nxt] = tx_data;
        f = {1'b1, 4'(nxt), 4'(m16(ex - 1)), ow_nak, tx_data};
        nxt2 = m16(nxt + 1); snd2 = m16(snd + 1); v_new = 1;
        if (nxt == 15) v_wrap = 1;
      end else if (ow_ack || ow_nak) begin
        f = {1'b0, 4'd0, 4'(m16(ex - 1)), ow_nak, 64'd0};
        if (ow_nak) v_nop_nak = 1; else v_nop_ack = 1;
      end
      if (ow_ack || ow_nak || snd != nxt || tx_valid && outstanding() != RB) begin
        if (ow_nak && f[73]) v_nak_in_data = 1;
        o_lt = 1; o_flit = {f, crc(f)}; ack2 = 0; nak2 = 0;
      end
      // ---- what comes in
      if (lr_valid) begin
        if (crc(lr_flit[89:16]) != lr_flit[15:0]) begin
          o_crc = 1; v_crc_bad = 1;
          if (!nk) begin nak2 = 1; nk = 1; end else v_nak_once = 1;
        end else begin : b_good
          int fr;
          fr = m16(int'(lr_flit[84:81]) + 1 - old);
          if (fr <= outstanding()) begin
            old2 = m16(old + fr);
            if (fr != 0 && fr != outstanding()) v_ack_partial = 1;
            if (fr != 0 && rep_now) v_ack_with_replay = 1;
          end else v_ack_bad = 1;
          if (lr_flit[80]) begin snd2 = old2; o_rep = 1; v_nak_rx = 1; end
          if (lr_flit[89]) begin
            if (int'(lr_flit[88:85]) == ex) begin
              o_rx = 1; o_rxd = lr_flit[79:16]; ex = m16(ex + 1); ack2 = 1; nk = 0;
            end else if (m16(ex - int'(lr_flit[88:85])) <= RB) begin ack2 = 1; v_dup = 1; end
            else begin
              v_ahead = 1;
              if (!nk) begin nak2 = 1; nk = 1; end else v_nak_once = 1;
            end
          end
        end
      end
      // ---- timeout
      if (old2 != old || nxt == old || snd != nxt) t = 0;
      else if (t == TO - 1) begin t = 0; snd2 = old2; o_rep = 1; v_timeout = 1; end
      else t++;
      if (m16(snd2 - old2) > m16(nxt2 - old2)) begin snd2 = old2; v_clamp = 1; end
      if (o_rep && o_lt && f[73] && !rep_now) v_rep_and_new = 1;
      old = old2; snd = snd2; nxt = nxt2; ow_ack = ack2; ow_nak = nak2;
    end
  end

  // ---------------- assertions ----------------
  `SVA_INV(a_tx, lt_valid == o_lt && (!o_lt || lt_flit == o_flit))
  `SVA_INV(a_rx, rx_valid == o_rx && (!o_rx || rx_data == o_rxd))
  `SVA_INV(a_status, tx_ready == (snd == nxt && outstanding() != RB) && int'(tx_pend) == outstanding())
  `SVA_INV(a_events, ev_crc == o_crc && ev_replay == o_rep)
  `SVA_RST(a_reset, !rst_n, !lt_valid && !rx_valid && tx_ready && tx_pend == 0 && !ev_crc && !ev_replay)

  // ---------------- functional coverage ----------------
  `FC(new_flit, v_new)
  `FC(replayed_flit, v_replay_send)
  `FC(nop_with_ack, v_nop_ack)
  `FC(nop_with_nak, v_nop_nak)
  `FC(nak_in_data_flit, v_nak_in_data)
  `FC(replay_buffer_full, v_full)
  `FC(sequence_wraps, v_wrap)
  `FC(bad_crc, v_crc_bad)
  `FC(duplicate_dropped, v_dup)
  `FC(seq_ahead_dropped, v_ahead)
  `FC(second_nak_held, v_nak_once)
  `FC(ack_outside_outstanding, v_ack_bad)
  `FC(ack_frees_some, v_ack_partial)
  `FC(ack_during_replay, v_ack_with_replay)
  `FC(replay_on_nak, v_nak_rx)
  `FC(replay_on_timeout, v_timeout)
  `FC(replay_skips_acked, v_clamp)
  `FC(replay_starts_as_new_flit_goes, v_rep_and_new)
  // a flit going out with flits outstanding as reset lands (taken on the
  // falling edge, before the asynchronous reset clears them)
  bit busy_n = 0;
  always @(negedge clk) busy_n <= lt_valid && tx_pend != 0;
  `FC_RST(reset_in_traffic, !rst_n && busy_n)
endmodule

bind UCIe_top UCIe_sva #(.RB(RB), .TO(TO)) u_sva (.*);
