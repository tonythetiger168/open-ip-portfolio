// SPDX-License-Identifier: Apache-2.0
/*verilator coverage_off*/
// WTB token-bus station: a cycle-level model fed only by the pins predicts
// every output on every clock. The receiver is modelled at frame level
// (16-bit delimiter window, byte array, CRC over the collected bytes), the
// transmitter as a byte array shifted out MSB first, plus the station FSM
// (idle timer, claim window, hold window / frame limit), both FIFOs and the
// RX word delivery.
`include "cov_macros.svh"
module WTB_sva #(
  parameter int IDLE_TO   = 300,
  parameter int CLAIM_WIN = 150,
  parameter int HOLD_WIN  = 400,
  parameter int MAX_FR    = 4
)(
  input logic        clk, rst_n, rx_bit, tx_bit, tx_en, cpu_we, cpu_re, token_held, irq,
  input logic [7:0]  my_addr,
  input logic [1:0]  cpu_addr,
  input logic [31:0] cpu_wdata, cpu_rdata,
  input logic [3:0]  fifo_count, rx_count
);
  `COV_CLOCKING(clk, !rst_n)

  localparam int HW = $clog2(HOLD_WIN + 1);
  localparam int LISTEN = 0, HOLD = 1, CLAIM_TX = 2, CLAIM_WAIT = 3, PASS = 4;

  function automatic logic [15:0] crc16(input logic [15:0] c, input logic [7:0] d);
    c = c ^ {d, 8'h00};
    for (int i = 0; i < 8; i++) c = c[15] ? ((c << 1) ^ 16'h1021) : (c << 1);
    return c;
  endfunction

  // configuration and FIFOs
  logic [7:0]  ns, da;
  logic        claim;
  int          hw;
  logic [31:0] txf [8], rxf [8], sw [4];
  int          t_wr, t_rd, t_cnt, r_wr, r_rd, r_cnt, dl, dl_i;
  // receiver
  logic        hunting, crc_good;
  logic [15:0] win;
  logic [7:0]  cur, fb [24];
  int          bc, nb;
  logic [7:0]  f_fc, f_da, f_sa, f_len;
  // transmitter
  logic        t_busy, t_done, m_tx_en, m_tx_bit;
  logic [7:0]  tb_ [14];
  int          t_n, t_i;
  // station
  int          st, idle, hold, frs, ccnt;
  logic        s_start, s_pop;
  logic [1:0]  s_fc;
  logic [7:0]  s_da;
  logic [31:0] s_w;
  // pulses
  logic        p_bad, p_cfg, p_ovf, p_tok, p_done;
  // coverage events
  logic v_pass_empty, v_max_fr, v_window, v_window0, v_txpp, v_d16, v_d0, v_bcast, v_notme,
        v_rxpp, v_crc, v_ed, v_long, v_own, v_tok_other, v_claim, v_claim_to, v_claim_low,
        v_claim_high, v_claim_tok, v_claim_other;

  always @(posedge clk or negedge rst_n) begin
    logic        o_done, o_tstart, o_pop, o_tbusy, o_tdone, push, pop, push_ok, rpush, rpop,
                 rpush_ok, deliver, tok_me;
    logic [1:0]  o_fc;
    logic [7:0]  o_da;
    logic [31:0] o_w;
    int          o_tcnt, o_rcnt, o_dl, o_dl_i, o_idle, o_hold, o_ccnt, o_hw, len;
    logic [15:0] c;
    if (!rst_n) begin
      ns = 8'h02; da = 8'hFF; claim = 0; hw = HOLD_WIN;
      t_wr = 0; t_rd = 0; t_cnt = 0; r_wr = 0; r_rd = 0; r_cnt = 0; dl = 0; dl_i = 0;
      for (int i = 0; i < 4; i++) sw[i] = 0;
      hunting = 1; win = 16'hFFFF; crc_good = 0; bc = 0; nb = 0;
      f_fc = 0; f_da = 0; f_sa = 0; f_len = 0;
      t_busy = 0; t_done = 0; m_tx_en = 0; m_tx_bit = 1; t_n = 0; t_i = 0;
      st = LISTEN; idle = 0; hold = 0; frs = 0; ccnt = 0;
      s_start = 0; s_pop = 0; s_fc = 0; s_da = 0; s_w = 0;
      {p_bad, p_cfg, p_ovf, p_tok, p_done} = '0;
      {v_pass_empty, v_max_fr, v_window, v_window0, v_txpp, v_d16, v_d0, v_bcast, v_notme,
       v_rxpp, v_crc, v_ed, v_long, v_own, v_tok_other, v_claim, v_claim_to, v_claim_low,
       v_claim_high, v_claim_tok, v_claim_other} = '0;
    end else begin
      {v_pass_empty, v_max_fr, v_window, v_window0, v_txpp, v_d16, v_d0, v_bcast, v_notme,
       v_rxpp, v_crc, v_ed, v_long, v_own, v_tok_other, v_claim, v_claim_to, v_claim_low,
       v_claim_high, v_claim_tok, v_claim_other} = '0;
      o_done = p_done; o_tstart = s_start; o_pop = s_pop; o_fc = s_fc; o_da = s_da; o_w = s_w;
      o_tbusy = t_busy; o_tdone = t_done; o_tcnt = t_cnt; o_rcnt = r_cnt; o_dl = dl;
      o_dl_i = dl_i; o_idle = idle; o_hold = hold; o_ccnt = ccnt; o_hw = hw;
      {p_bad, p_cfg, p_ovf, p_tok, p_done} = '0;
      s_start = 0; s_pop = 0;

      // ---------------- station ----------------
      tok_me = o_done && f_fc == 8'h01 && f_da == my_addr;
      if (o_done && f_fc == 8'h01 && f_da != my_addr) v_tok_other = 1;
      if (!rx_bit) idle = 0; else if (idle != IDLE_TO) idle++;
      case (st)
        LISTEN:
          if (tok_me) begin st = HOLD; hold = 0; frs = 0; p_tok = 1; end
          else if (claim && o_idle == IDLE_TO) begin
            s_start = 1; s_fc = 2'd0; s_da = 8'hFF; s_w = 0; st = CLAIM_TX; v_claim = 1;
          end
        HOLD: begin
          if (hold < o_hw) hold++;
          if (!o_tbusy && !o_tstart) begin
            if (frs != MAX_FR && o_hold < o_hw && o_tcnt != 0) begin
              s_start = 1; s_fc = 2'd2; s_da = da; s_w = txf[t_rd]; s_pop = 1; frs++;
            end else begin
              s_start = 1; s_fc = 2'd1; s_da = ns; s_w = 0; st = PASS;
              if (o_tcnt == 0) v_pass_empty = 1;
              else if (frs == MAX_FR) v_max_fr = 1;
              else begin v_window = 1; if (o_hw == 0) v_window0 = 1; end
            end
          end
        end
        PASS:     if (o_tdone) st = LISTEN;
        CLAIM_TX: if (o_tdone) begin st = CLAIM_WAIT; ccnt = 0; end
        default: begin
          ccnt++;
          if (tok_me) begin st = HOLD; hold = 0; frs = 0; p_tok = 1; v_claim_tok = 1; end
          else if (!o_done && o_ccnt == CLAIM_WIN) begin
            st = HOLD; hold = 0; frs = 0; p_tok = 1; v_claim_to = 1;
          end else if (o_done) begin
            if (f_fc == 8'h00 && f_sa > my_addr) v_claim_high = 1;
            else begin
              st = LISTEN;
              if (f_fc == 8'h00) v_claim_low = 1; else v_claim_other = 1;
            end
          end
        end
      endcase

      // ---------------- configuration + TX FIFO ----------------
      push = cpu_we && cpu_addr == 2'd0;
      pop = o_pop && o_tcnt != 0;
      push_ok = push && (o_tcnt != 8 || pop);
      p_cfg = push && !push_ok;
      if (push && pop && o_tcnt == 8) v_txpp = 1;
      if (cpu_we && cpu_addr == 2'd1) ns = cpu_wdata[7:0];
      if (cpu_we && cpu_addr == 2'd2) da = cpu_wdata[7:0];
      if (cpu_we && cpu_addr == 2'd3) begin claim = cpu_wdata[0]; hw = cpu_wdata[8 +: HW]; end
      if (push_ok) begin txf[t_wr] = cpu_wdata; t_wr = (t_wr + 1) % 8; end
      if (pop) t_rd = (t_rd + 1) % 8;
      t_cnt = o_tcnt + push_ok - pop;

      // ---------------- RX delivery + RX FIFO ----------------
      deliver = o_done && f_fc == 8'h02 && (f_da == my_addr || f_da == 8'hFF);
      if (o_done && f_fc == 8'h02 && !deliver) v_notme = 1;
      if (deliver && f_len == 16) v_d16 = 1;
      if (deliver && f_len == 0) v_d0 = 1;
      if (deliver && f_da == 8'hFF) v_bcast = 1;
      rpush = o_dl != 0;
      rpop = cpu_re && o_rcnt != 0;
      rpush_ok = rpush && (o_rcnt != 8 || rpop);
      p_ovf = rpush && !rpush_ok;
      if (rpush && rpop && o_rcnt == 8) v_rxpp = 1;
      if (deliver) begin dl = (f_len + 3) / 4; dl_i = 0; end
      else if (rpush) begin dl--; dl_i++; end
      if (rpush_ok) begin rxf[r_wr] = sw[o_dl_i]; r_wr = (r_wr + 1) % 8; end
      if (rpop) r_rd = (r_rd + 1) % 8;
      r_cnt = o_rcnt + rpush_ok - rpop;

      // ---------------- receiver ----------------
      if (hunting) begin
        win = {win[14:0], rx_bit};
        if (win == 16'h55D5) begin
          hunting = 0; bc = 0; nb = 0;
          for (int i = 0; i < 4; i++) sw[i] = 0;
        end
      end else begin
        cur = {cur[6:0], rx_bit};
        if (++bc == 8) begin
          bc = 0; fb[nb] = cur; nb++;
          len = fb[3];
          if (nb == 4 && len > 16) begin
            p_bad = 1; v_long = 1; hunting = 1; win = 16'hFFFF;
          end else if (nb >= 5 && nb <= 4 + len) begin
            sw[(nb - 5) / 4][8 * (3 - (nb - 5) % 4) +: 8] = cur;
          end else if (nb == 6 + len) begin
            c = 16'hFFFF;
            for (int i = 0; i < 4 + len; i++) c = crc16(c, fb[i]);
            crc_good = (c == {fb[4 + len], fb[5 + len]});
            if (!crc_good) begin p_bad = 1; v_crc = 1; end
          end else if (nb == 7 + len) begin
            f_fc = fb[0]; f_da = fb[1]; f_sa = fb[2]; f_len = fb[3];
            if (cur != 8'hD4) begin p_bad = 1; v_ed = 1; end
            else if (crc_good && f_sa == my_addr) v_own = 1;
            p_done = cur == 8'hD4 && crc_good && f_sa != my_addr;
            hunting = 1; win = 16'hFFFF;
          end
        end
      end

      // ---------------- transmitter ----------------
      t_done = 0;
      if (!t_busy) begin
        m_tx_en = 0; m_tx_bit = 1;
        if (o_tstart) begin
          len = (o_fc == 2'd2) ? 4 : 0;
          tb_[0] = 8'h55; tb_[1] = 8'h55; tb_[2] = 8'hD5;
          tb_[3] = {6'd0, o_fc}; tb_[4] = o_da; tb_[5] = my_addr; tb_[6] = 8'(len);
          for (int i = 0; i < len; i++) tb_[7 + i] = o_w[8 * (3 - i) +: 8];
          c = 16'hFFFF;
          for (int i = 3; i < 7 + len; i++) c = crc16(c, tb_[i]);
          tb_[7 + len] = c[15:8]; tb_[8 + len] = c[7:0]; tb_[9 + len] = 8'hD4;
          t_n = 8 * (10 + len); t_i = 0; t_busy = 1;
          m_tx_en = 1; m_tx_bit = tb_[0][7];
        end
      end else begin
        t_i++;
        m_tx_bit = tb_[t_i / 8][7 - t_i % 8];
        if (t_i == t_n - 1) begin t_busy = 0; t_done = 1; end
      end
    end
  end

  // ---------------- assertions ----------------
  `SVA_RST(a_reset_outputs, !rst_n, !tx_en && tx_bit && !irq && !token_held &&
                                    fifo_count == 0 && rx_count == 0)
  `SVA_INV(a_tx_en, tx_en == m_tx_en)
  `SVA_INV(a_tx_bit, tx_bit == m_tx_bit)
  `SVA_INV(a_fifo_count, fifo_count == 4'(t_cnt))
  `SVA_INV(a_rx_count, rx_count == 4'(r_cnt))
  `SVA_IMP(a_cpu_rdata, rx_count != 0, cpu_rdata == rxf[r_rd])
  `SVA_INV(a_token_held, token_held == (st == HOLD || st == PASS))
  `SVA_INV(a_irq, irq == (p_bad || p_cfg || p_ovf || p_tok))

  // ---------------- functional coverage ----------------
  `FC(token_passed_with_empty_fifo, v_pass_empty)
  `FC(hold_ended_by_frame_limit, v_max_fr)
  `FC(hold_ended_by_window, v_window)
  `FC(hold_window_zero, v_window0)
  `FC(tx_fifo_overflow, p_cfg)
  `FC(tx_push_and_pop_while_full, v_txpp)
  `FC(rx_deliver_16_bytes, v_d16)
  `FC(rx_deliver_empty_payload, v_d0)
  `FC(rx_deliver_broadcast, v_bcast)
  `FC(rx_data_for_other_station, v_notme)
  `FC(rx_fifo_overflow, p_ovf)
  `FC(rx_push_and_pop_while_full, v_rxpp)
  `FC(rx_bad_crc, v_crc)
  `FC(rx_bad_ed, v_ed)
  `FC(rx_overlong, v_long)
  `FC(own_frame_ignored, v_own)
  `FC(token_for_other_station, v_tok_other)
  `FC(claim_sent, v_claim)
  `FC(claim_window_expired, v_claim_to)
  `FC(claim_lower_address_wins, v_claim_low)
  `FC(claim_higher_address_ignored, v_claim_high)
  `FC(claim_token_received, v_claim_tok)
  `FC(claim_ended_by_traffic, v_claim_other)
  `FC_RST(reset_while_holding_token, rst_n && token_held ##1 !rst_n)
endmodule

bind WTB_top WTB_sva #(.IDLE_TO(IDLE_TO), .CLAIM_WIN(CLAIM_WIN), .HOLD_WIN(HOLD_WIN),
                       .MAX_FR(MAX_FR)) u_sva (.*);
