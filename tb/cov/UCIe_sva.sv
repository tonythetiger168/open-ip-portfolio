// SPDX-License-Identifier: Apache-2.0
// UCIe Die-to-Die Adapter: concurrent SVA against an independent reference
// model, plus functional coverage.
//  * The model keeps its own link state (an int), negotiated capabilities,
//    owed sideband messages (an array in send order), handshake timer,
//    and for Retry its own replay buffer indexed by SEQ (integers modulo
//    64), replay timer, retrain counter, expected SEQ and owed Ack / Nak.
//    It predicts every flit and sideband message sent (fields and CRC),
//    every delivery, tx_ready, tx_pend, state, cap and every event.
//  Every output is compared on every clock.
`include "cov_macros.svh"
module UCIe_sva #(
  parameter int RB = 8, TO = 64, NR = 4, HT = 512
)(
  input logic         clk, rst_n,
  input logic         link_en, cfg_retry, cfg_stack1, cfg_l1_ok, pm_req,
  input logic         tx_valid, tx_stack,
  input logic [511:0] tx_data,
  input logic         tx_ready, rx_valid, rx_stack,
  input logic [511:0] rx_data,
  input logic         phy_up, lp_retrain, lt_valid,
  input logic [543:0] lt_flit,
  input logic         lr_valid,
  input logic [543:0] lr_flit,
  input logic         sb_tx_valid,
  input logic [15:0]  sb_tx_msg,
  input logic         sb_rx_valid,
  input logic [15:0]  sb_rx_msg,
  input logic [2:0]   state,
  input logic [1:0]   cap,
  input logic [$clog2(RB):0] tx_pend,
  input logic         ev_crc, ev_replay, ev_retrain, ev_pmnak, ev_proto, ev_lerr
);
  `COV_CLOCKING(clk, !rst_n)

  localparam int RESET = 0, PARAM = 1, ACTREQ = 2, ACTIVE = 3, L1 = 4, RETRAIN = 5, LINKERR = 6;
  // owed sideband messages, in send order
  localparam int O_ADV = 0, O_FIN = 1, O_RSP = 2, O_REQ = 3, O_L1RSP = 4, O_PMNAK = 5, O_L1REQ = 6;
  function automatic logic [7:0] code_of(input int i);
    case (i)
      O_ADV: return 8'h01;  O_FIN: return 8'h02;  O_RSP: return 8'h04;  O_REQ: return 8'h03;
      O_L1RSP: return 8'h06; O_PMNAK: return 8'h07; default: return 8'h05;
    endcase
  endfunction

  // CRC-16, polynomial 0x1021, seed 0xFFFF, MSB first
  function automatic logic [15:0] crc(input logic [527:0] d);
    logic [15:0] c;
    c = 16'hFFFF;
    for (int i = 527; i >= 0; i--) begin
      logic fb;
      fb = c[15] ^ d[i];
      c = c << 1;
      if (fb) c = c ^ 16'h1021;
    end
    return c;
  endfunction
  function automatic int m64(input int x); return ((x % 64) + 64) % 64; endfunction

  // ---------------- model state ----------------
  int          st, ht;
  logic [1:0]  own, neg, f_adv, f_fin;
  bit          g_adv, g_fin, f_sent, rq_got, rs_got, l1w, armed;
  bit          owe [0:6];
  logic [512:0] buf_ [0:63];             // {stack, payload} by SEQ
  int          nxt, old, snd, ex, t, nr;
  bit          ow_ack, ow_nak, nk;
  // expected registered outputs
  bit          o_lt, o_rx, o_rs, o_sb, o_ret;
  bit          o_crc, o_rep, o_pmn, o_pro, o_ler;
  logic [543:0] o_flit;
  logic [511:0] o_rxd;
  logic [15:0] o_sbm;

  function automatic int outstanding(); return m64(nxt - old); endfunction
  function automatic bit m_ready();
    return st == ACTIVE && !l1w && (!neg[0] || outstanding() != RB && snd == nxt);
  endfunction

  // ---------------- coverage flags ----------------
  bit v_adv_reset, v_fin_again, v_fin_mismatch, v_req_param, v_req_retrain, v_req_actreq, v_req_active, v_req_l1;
  bit v_l1_accept, v_l1_refuse_cfg, v_l1_refuse_busy, v_l1_refuse_flit, v_l1_rsp, v_l1_rsp_in_l1, v_pmnak_rx, v_l1_req_sent;
  bit v_wake_tx, v_phy_param, v_phy_actreq, v_phy_active, v_phy_l1, v_ht_param, v_ht_actreq;
  bit v_restart_actreq, v_restart_active, v_restart_l1, v_restart_retrain, v_dis_linkerr;
  bit v_sb_multi, v_sb_unknown, v_sb_proto, v_flit_proto_state, v_rty_mismatch, v_stack_drop_tx, v_stack_drop_rx;
  bit v_noretry_data, v_noretry_crc, v_noretry_nop, v_rx_actreq;
  bit v_new, v_replay_send, v_nop_ack, v_nop_nak, v_nak_in_data, v_full, v_wrap, v_crc_bad, v_dup, v_ahead;
  bit v_ack_bad, v_ack_partial, v_ack_with_replay, v_nak_rx, v_nak_once, v_timeout, v_clamp, v_rep_and_new;
  bit v_retrain_req, v_replay_after_retrain, v_stack1_tx, v_stack1_rx;

  // per-step copies for the covergroups (set at posedge, sampled at negedge)
  int          c_from, c_to, c_tk, c_out, c_seq, c_rk, c_ack, c_tdc, c_rdc, c_sbc, c_sbs;
  bit          c_tv, c_tnak, c_tstk, c_rv, c_rnak, c_rstk, c_dv, c_sbv;
  function automatic int dcls(input logic [511:0] v);
    return v == '0 ? 0 : (v == '1 ? 1 : (v == {256{2'b01}} || v == {256{2'b10}} ? 2 : 3));
  endfunction

  always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      st = RESET; ht = 0; own = 0; neg = 0; f_adv = 0; f_fin = 0;
      {g_adv, g_fin, f_sent, rq_got, rs_got, l1w, armed} = '0;
      for (int i = 0; i < 7; i++) owe[i] = 0;
      for (int i = 0; i < 64; i++) buf_[i] = 0;
      nxt = 0; old = 0; snd = 0; ex = 0; t = 0; nr = 0; ow_ack = 0; ow_nak = 0; nk = 0;
      {o_lt, o_rx, o_rs, o_sb, o_ret, o_crc, o_rep, o_pmn, o_pro, o_ler} = '0;
      o_flit = 0; o_rxd = 0; o_sbm = 0;
      c_from = 0; c_to = 0; c_tk = 0; c_out = 0; c_seq = 0; c_rk = 0; c_ack = 0; c_tdc = -1; c_rdc = -1;
      c_sbc = 0; c_sbs = 0; {c_tv, c_tnak, c_tstk, c_rv, c_rnak, c_rstk, c_dv, c_sbv} = '0;
    end else begin : b_step
      int s, nst, old2, snd2, nxt2, ex2;
      bit ack2, nak2, nk2, progress, replay, err, restart, sent, rep_now;
      bit g_adv2, g_fin2, f_sent2, rq2, rs2, l1w2, arm2;
      bit owe2 [0:6];
      logic [15:0] h;
      logic [511:0] p;
      s = st; nst = st;
      old2 = old; snd2 = snd; nxt2 = nxt; ex2 = ex; ack2 = ow_ack; nak2 = ow_nak; nk2 = nk;
      g_adv2 = g_adv; g_fin2 = g_fin; f_sent2 = f_sent; rq2 = rq_got; rs2 = rs_got; l1w2 = l1w;
      arm2 = armed || !pm_req;
      for (int i = 0; i < 7; i++) owe2[i] = owe[i];
      progress = 0; replay = 0; err = 0; restart = 0; sent = 0; rep_now = snd != nxt;
      {o_lt, o_rx, o_sb, o_ret, o_crc, o_rep, o_pmn, o_pro} = '0;
      {c_tv, c_rv, c_dv, c_sbv} = '0; c_tnak = ow_nak; c_ack = -1; c_out = outstanding(); c_tdc = -1; c_rdc = -1;
      if (neg[0] && outstanding() == RB) v_full = 1;

      // ---- sideband out: the first owed message
      begin : b_sbo
        int k, n;
        k = -1; n = 0;
        for (int i = 6; i >= 0; i--) if (owe[i]) begin k = i; n++; end
        if (k >= 0) begin
          o_sb = 1; owe2[k] = 0;
          o_sbm = {code_of(k), 6'd0, k == O_ADV ? own : (k == O_FIN ? neg : 2'b00)};
          if (n > 1) v_sb_multi = 1;
        end
      end

      // ---- sideband in
      c_sbv = sb_rx_valid; c_sbs = s;
      c_sbc = sb_rx_msg[15:8] >= 8'h01 && sb_rx_msg[15:8] <= 8'h07 ? int'(sb_rx_msg[15:8]) : 0;
      if (sb_rx_valid) begin
        case (sb_rx_msg[15:8])
          8'h01: begin                                  // AdvCap
            if (s == LINKERR) o_pro = 1;
            else begin
              f_adv = sb_rx_msg[1:0]; g_adv2 = 1;
              if (s == RESET) v_adv_reset = 1;
              else if (s == PARAM) begin if (f_sent) begin f_sent2 = 0; v_fin_again = 1; end end
              else begin
                nst = RESET; restart = 1;
                if (s == ACTREQ) v_restart_actreq = 1;
                if (s == ACTIVE) v_restart_active = 1;
                if (s == L1) v_restart_l1 = 1;
                if (s == RETRAIN) v_restart_retrain = 1;
              end
            end
          end
          8'h02:                                         // FinCap
            if (s == PARAM) begin f_fin = sb_rx_msg[1:0]; g_fin2 = 1; end
            else o_pro = 1;
          8'h03:                                         // Req.Active
            if (s == PARAM || s == RETRAIN) begin
              rq2 = 1;
              if (s == PARAM) v_req_param = 1; else v_req_retrain = 1;
            end else if (s == ACTREQ) begin rq2 = 1; owe2[O_RSP] = 1; v_req_actreq = 1; end
            else if (s == ACTIVE || s == L1) begin
              nst = ACTREQ; rq2 = 1; rs2 = 0; owe2[O_RSP] = 1; owe2[O_REQ] = 1; l1w2 = 0;
              if (s == ACTIVE) v_req_active = 1; else v_req_l1 = 1;
            end else o_pro = 1;
          8'h04:                                         // Rsp.Active
            if (s == ACTREQ) rs2 = 1;
            else o_pro = 1;
          8'h05:                                         // Req.L1
            if (s == ACTIVE) begin
              if (cfg_l1_ok && outstanding() == 0 && !ow_ack && !ow_nak && !tx_valid && !lr_valid) begin
                owe2[O_L1RSP] = 1; nst = L1; l1w2 = 0; v_l1_accept = 1;
              end else begin
                owe2[O_PMNAK] = 1;
                if (!cfg_l1_ok) v_l1_refuse_cfg = 1;
                else if (lr_valid && outstanding() == 0 && !ow_ack && !ow_nak && !tx_valid) v_l1_refuse_flit = 1;
                else v_l1_refuse_busy = 1;
              end
            end else o_pro = 1;
          8'h06:                                         // Rsp.L1
            if (s == ACTIVE && l1w) begin nst = L1; l1w2 = 0; v_l1_rsp = 1; end
            else if (s == L1) v_l1_rsp_in_l1 = 1;
            else o_pro = 1;
          8'h07:                                         // Rsp.PMNAK
            if (s == ACTIVE && l1w) begin l1w2 = 0; o_pmn = 1; v_pmnak_rx = 1; end
            else o_pro = 1;
          default: begin o_pro = 1; v_sb_unknown = 1; end
        endcase
        if (o_pro && sb_rx_msg[15:8] >= 8'h01 && sb_rx_msg[15:8] <= 8'h07) v_sb_proto = 1;
      end

      // ---- main band out
      h = 0; p = 0;
      if (s == ACTIVE) begin
        bit ok;
        ok = m_ready();
        if (neg[0]) begin
          if (snd != nxt) begin
            sent = 1; h = {1'b1, buf_[snd][512], 2'b00, 6'(snd), 6'd0}; p = buf_[snd][511:0];
            snd2 = m64(snd + 1); v_replay_send = 1; c_tk = 1;
          end else if (tx_valid && ok) begin
            if (tx_stack && !neg[1]) begin o_pro = 1; v_stack_drop_tx = 1; end
            else begin
              buf_[nxt] = {tx_stack, tx_data};
              sent = 1; h = {1'b1, tx_stack, 2'b00, 6'(nxt), 6'd0}; p = tx_data;
              c_seq = nxt; c_tdc = dcls(tx_data); c_tk = 0; v_new = 1;
              if (tx_stack) v_stack1_tx = 1;
              if (nxt == 63) v_wrap = 1;
              nxt2 = m64(nxt + 1); snd2 = m64(snd + 1);
            end
          end else if (ow_ack || ow_nak) begin
            sent = 1; c_tk = 2;
            if (ow_nak) v_nop_nak = 1; else v_nop_ack = 1;
          end
          if (sent) begin
            h[13] = ow_nak; h[12] = 1; h[5:0] = 6'(m64(ex - 1));
            if (ow_nak && h[15]) v_nak_in_data = 1;
            ack2 = 0; nak2 = 0;
          end
        end else if (tx_valid && ok) begin
          if (tx_stack && !neg[1]) begin o_pro = 1; v_stack_drop_tx = 1; end
          else begin sent = 1; h = {1'b1, tx_stack, 14'd0}; p = tx_data; c_tk = 3; c_tdc = dcls(tx_data); v_noretry_data = 1; end
        end
        if (sent) begin
          o_lt = 1; o_flit = {h, p, crc({h, p})}; c_tv = 1; c_tstk = h[14];
        end
      end

      // ---- main band in
      if (lr_valid) begin
        c_rv = 1; c_rnak = lr_flit[541]; c_rstk = lr_flit[542]; c_rk = 0;
        if (s != ACTREQ && s != ACTIVE) begin o_pro = 1; v_flit_proto_state = 1; c_rk = 7; end
        else begin
          if (s == ACTREQ) v_rx_actreq = 1;
          if (crc(lr_flit[543:16]) != lr_flit[15:0]) begin
            o_crc = 1; c_rk = 0;
            if (!neg[0]) begin err = 1; v_noretry_crc = 1; end
            else begin
              v_crc_bad = 1;
              if (!nk) begin nak2 = 1; nk2 = 1; end else v_nak_once = 1;
            end
          end else if (lr_flit[540] != neg[0]) begin o_pro = 1; v_rty_mismatch = 1; c_rk = 6; end
          else if (neg[0]) begin
            int fr, sq;
            fr = m64(int'(lr_flit[533:528]) + 1 - old);
            sq = int'(lr_flit[539:534]);
            c_ack = fr > outstanding() ? 3 : (fr == 0 ? 0 : (fr == outstanding() ? 2 : 1));
            if (fr <= outstanding()) begin
              old2 = m64(old + fr);
              if (fr != 0) progress = 1;
              if (fr != 0 && fr != outstanding()) v_ack_partial = 1;
              if (fr != 0 && rep_now) v_ack_with_replay = 1;
            end else v_ack_bad = 1;
            if (lr_flit[541]) begin snd2 = old2; replay = 1; v_nak_rx = 1; end
            if (!lr_flit[543]) c_rk = 4;
            else if (sq == ex) begin
              ex2 = m64(ex + 1); ack2 = 1; nk2 = 0; c_rk = 1;
              if (lr_flit[542] && !neg[1]) begin o_pro = 1; v_stack_drop_rx = 1; c_rk = 5; end
              else begin
                o_rx = 1; o_rs = lr_flit[542]; o_rxd = lr_flit[527:16]; c_dv = 1; c_rdc = dcls(lr_flit[527:16]);
                if (lr_flit[542]) v_stack1_rx = 1;
              end
            end else if (m64(ex - sq) <= RB) begin ack2 = 1; v_dup = 1; c_rk = 2; end
            else begin
              v_ahead = 1; c_rk = 3;
              if (!nk) begin nak2 = 1; nk2 = 1; end else v_nak_once = 1;
            end
          end else if (!lr_flit[543]) begin o_pro = 1; v_noretry_nop = 1; c_rk = 4; end
          else if (lr_flit[542] && !neg[1]) begin o_pro = 1; v_stack_drop_rx = 1; c_rk = 5; end
          else begin
            o_rx = 1; o_rs = lr_flit[542]; o_rxd = lr_flit[527:16]; c_dv = 1; c_rk = 1; c_rdc = dcls(lr_flit[527:16]);
          end
        end
      end

      // ---- replay timer, retrain request
      if (s != ACTIVE || !neg[0] || progress || nxt == old || snd != nxt) t = 0;
      else if (t == TO - 1) begin t = 0; replay = 1; snd2 = old2; v_timeout = 1; end
      else t++;
      if (replay) o_rep = 1;
      if (progress) nr = 0;
      else if (replay) begin
        if (nr == NR - 1) begin nr = 0; o_ret = 1; v_retrain_req = 1; end
        else nr++;
      end
      if (m64(snd2 - old2) > m64(nxt2 - old2)) begin snd2 = old2; v_clamp = 1; end
      if (replay && sent && h[15] && !rep_now) v_rep_and_new = 1;

      // ---- link state
      case (s)
        RESET:
          if (link_en && phy_up) begin nst = PARAM; own = {cfg_stack1, cfg_retry}; owe2[O_ADV] = 1; end
        PARAM: begin
          if (g_adv2 && !f_sent) begin neg = own & f_adv; owe2[O_FIN] = 1; f_sent2 = 1; end
          if (f_sent && g_fin2) begin
            if (f_fin == neg) begin nst = ACTREQ; owe2[O_REQ] = 1; owe2[O_RSP] = rq2; rs2 = 0; end
            else begin err = 1; v_fin_mismatch = 1; end
          end
        end
        ACTREQ:
          if (rq2 && rs2) begin
            nst = ACTIVE; rq2 = 0; rs2 = 0; snd2 = old2;
            if (m64(nxt2 - old2) != 0) v_replay_after_retrain = 1;
          end
        ACTIVE:
          if (nst == ACTIVE && !l1w2 && pm_req && armed && outstanding() == 0 && !ow_ack && !ow_nak && !tx_valid) begin
            owe2[O_L1REQ] = 1; l1w2 = 1; arm2 = 0; v_l1_req_sent = 1;
          end
        L1:
          if (nst == L1 && tx_valid) begin nst = ACTREQ; owe2[O_REQ] = 1; rs2 = 0; v_wake_tx = 1; end
        RETRAIN:
          if (phy_up) begin nst = ACTREQ; owe2[O_REQ] = 1; owe2[O_RSP] = rq2; rs2 = 0; end
        default: ;
      endcase
      if (nst == L1 && s != L1) arm2 = 0;
      if (nst == s && (s == PARAM || s == ACTREQ)) begin
        if (ht == HT - 1) begin
          err = 1;
          if (s == PARAM) v_ht_param = 1; else v_ht_actreq = 1;
        end else ht++;
      end else ht = 0;
      if (!phy_up) begin
        if (s == PARAM) begin nst = RESET; v_phy_param = 1; end
        else if (s == ACTREQ || s == ACTIVE || s == L1) begin
          nst = RETRAIN; rq2 = 0; rs2 = 0; l1w2 = 0; t = 0; nr = 0; err = 0;
          for (int i = 0; i < 7; i++) owe2[i] = 0;
          if (s == ACTREQ) v_phy_actreq = 1;
          if (s == ACTIVE) v_phy_active = 1;
          if (s == L1) v_phy_l1 = 1;
        end
      end
      o_ler = 0;
      if (err && nst != RESET) begin
        nst = LINKERR; o_ler = 1; l1w2 = 0;
        for (int i = 0; i < 7; i++) owe2[i] = 0;
      end
      if (!link_en && s != RESET || nst == RESET && s != RESET) begin
        if (s == LINKERR) v_dis_linkerr = 1;
        nst = RESET; neg = 0; o_ler = 0;
        {g_adv2, g_fin2, f_sent2, rq2, rs2, l1w2} = '0;
        for (int i = 0; i < 7; i++) owe2[i] = 0;
        old2 = 0; snd2 = 0; nxt2 = 0; ex2 = 0; ack2 = 0; nak2 = 0; nk2 = 0; t = 0; nr = 0; ht = 0;
        if (restart && link_en) g_adv2 = 1;
      end

      c_from = s; c_to = nst;
      st = nst;
      g_adv = g_adv2; g_fin = g_fin2; f_sent = f_sent2; rq_got = rq2; rs_got = rs2; l1w = l1w2; armed = arm2;
      for (int i = 0; i < 7; i++) owe[i] = owe2[i];
      old = old2; snd = snd2; nxt = nxt2; ex = ex2; ow_ack = ack2; ow_nak = nak2; nk = nk2;
    end
  end

  // ---------------- assertions ----------------
  `SVA_INV(a_flit, lt_valid == o_lt && (!o_lt || lt_flit == o_flit))
  `SVA_INV(a_rx, rx_valid == o_rx && (!o_rx || rx_data == o_rxd && rx_stack == o_rs))
  `SVA_INV(a_sb, sb_tx_valid == o_sb && (!o_sb || sb_tx_msg == o_sbm))
  `SVA_INV(a_state, int'(state) == st && cap == neg)
  `SVA_INV(a_status, tx_ready == m_ready() && int'(tx_pend) == outstanding())
  `SVA_INV(a_retrain, lp_retrain == o_ret && ev_retrain == o_ret)
  `SVA_INV(a_events, ev_crc == o_crc && ev_replay == o_rep && ev_pmnak == o_pmn && ev_proto == o_pro && ev_lerr == o_ler)
  `SVA_RST(a_reset, !rst_n, !lt_valid && !rx_valid && !sb_tx_valid && !tx_ready && tx_pend == 0 && state == 3'd0
                    && cap == 2'b00 && !lp_retrain && !ev_crc && !ev_replay && !ev_retrain && !ev_pmnak && !ev_proto && !ev_lerr)

  // ---------------- functional coverage ----------------
  // (Verilator samples covergroups of the first instance only: the TB
  // drives every scenario through Adapter A)
  // link state arcs; sideband messages received x state class
  covergroup cg_lsm @(negedge clk);
    option.per_instance = 1;
    cp_arc: coverpoint c_from * 8 + c_to iff (rst_n && c_from != c_to)
      { bins reset_param = {RESET * 8 + PARAM};
        bins param_actreq = {PARAM * 8 + ACTREQ}; bins param_reset = {PARAM * 8 + RESET};
        bins param_linkerr = {PARAM * 8 + LINKERR};
        bins actreq_active = {ACTREQ * 8 + ACTIVE}; bins actreq_retrain = {ACTREQ * 8 + RETRAIN};
        bins actreq_linkerr = {ACTREQ * 8 + LINKERR}; bins actreq_reset = {ACTREQ * 8 + RESET};
        bins active_l1 = {ACTIVE * 8 + L1}; bins active_actreq = {ACTIVE * 8 + ACTREQ};
        bins active_retrain = {ACTIVE * 8 + RETRAIN}; bins active_linkerr = {ACTIVE * 8 + LINKERR};
        bins active_reset = {ACTIVE * 8 + RESET};
        bins l1_actreq = {L1 * 8 + ACTREQ}; bins l1_retrain = {L1 * 8 + RETRAIN}; bins l1_reset = {L1 * 8 + RESET};
        bins retrain_actreq = {RETRAIN * 8 + ACTREQ}; bins retrain_reset = {RETRAIN * 8 + RESET};
        bins linkerr_reset = {LINKERR * 8 + RESET}; }
    cp_sb: coverpoint c_sbc iff (rst_n && c_sbv)
      { bins adv = {1}; bins fin = {2}; bins req = {3}; bins rsp = {4}; bins l1req = {5}; bins l1rsp = {6};
        bins pmnak = {7}; bins unknown = {0}; }
    cp_sbs: coverpoint c_sbs iff (rst_n && c_sbv)
      { bins reset = {RESET}; bins param = {PARAM}; bins actreq = {ACTREQ}; bins active = {ACTIVE};
        bins l1 = {L1}; bins retrain = {RETRAIN}; bins linkerr = {LINKERR}; }
  endgroup
  cg_lsm u_cg_lsm = new;

  // flit sent (new / replayed / NOP / no Retry) x Nak, x stack; replay
  // buffer depth and SEQ of new flits; payload classes both ways; what a
  // received flit is x its Nak bit and stack; how much its ACK frees
  covergroup cg_flit @(negedge clk);
    option.per_instance = 1;
    cp_kind: coverpoint c_tk iff (rst_n && c_tv)
      { bins new_ = {0}; bins replay = {1}; bins nop = {2}; bins no_retry = {3}; }
    cp_kind_r: coverpoint c_tk iff (rst_n && c_tv && c_tk != 3) { bins new_ = {0}; bins replay = {1}; bins nop = {2}; }
    cp_nak: coverpoint c_tnak iff (rst_n && c_tv && c_tk != 3);
    x_kind_nak: cross cp_kind_r, cp_nak;
    cp_kind_d: coverpoint c_tk iff (rst_n && c_tv && c_tk != 2) { bins new_ = {0}; bins replay = {1}; bins no_retry = {3}; }
    cp_tstk: coverpoint c_tstk iff (rst_n && c_tv && c_tk != 2);
    x_kind_stk: cross cp_kind_d, cp_tstk;
    cp_depth: coverpoint c_out iff (rst_n && c_tv && c_tk == 0) { bins d[] = {[0:RB-1]}; }
    cp_seq: coverpoint c_seq iff (rst_n && c_tv && c_tk == 0) { bins s[] = {[0:63]}; }
    cp_tdata: coverpoint c_tdc iff (rst_n && c_tdc >= 0)
      { bins zero = {0}; bins ones = {1}; bins alt = {2}; bins other = {3}; }
    cp_rdata: coverpoint c_rdc iff (rst_n && c_rdc >= 0)
      { bins zero = {0}; bins ones = {1}; bins alt = {2}; bins other = {3}; }
    cp_recv: coverpoint c_rk iff (rst_n && c_rv)
      { bins bad_crc = {0}; bins in_order = {1}; bins dup = {2}; bins ahead = {3}; bins nop = {4};
        bins stack_drop = {5}; bins rty_mismatch = {6}; bins wrong_state = {7}; }
    cp_recv_r: coverpoint c_rk iff (rst_n && c_rv && c_rk >= 1 && c_rk <= 4 && c_ack >= 0)
      { bins in_order = {1}; bins dup = {2}; bins ahead = {3}; bins nop = {4}; }
    cp_rnak: coverpoint c_rnak iff (rst_n && c_rv && c_rk >= 1 && c_rk <= 4 && c_ack >= 0);
    x_recv_nak: cross cp_recv_r, cp_rnak;
    cp_rstk: coverpoint c_rstk iff (rst_n && c_dv);
    cp_ack: coverpoint c_ack iff (rst_n && c_ack >= 0)
      { bins none = {0}; bins some = {1}; bins all = {2}; bins outside = {3}; }
  endgroup
  cg_flit u_cg_flit = new;

  // link state machine and sideband
  `FC(adv_kept_in_reset, v_adv_reset)
  `FC(fin_cap_again, v_fin_again)
  `FC(fin_cap_mismatch, v_fin_mismatch)
  `FC(req_active_in_param, v_req_param)
  `FC(req_active_in_retrain, v_req_retrain)
  `FC(req_active_in_actreq, v_req_actreq)
  `FC(req_active_in_active, v_req_active)
  `FC(req_active_in_l1, v_req_l1)
  `FC(l1_request_sent, v_l1_req_sent)
  `FC(l1_accepted, v_l1_accept)
  `FC(l1_refused_by_cfg, v_l1_refuse_cfg)
  `FC(l1_refused_busy, v_l1_refuse_busy)
  `FC(l1_refused_flit_arriving, v_l1_refuse_flit)
  `FC(l1_response, v_l1_rsp)
  `FC(l1_response_in_l1, v_l1_rsp_in_l1)
  `FC(pmnak_received, v_pmnak_rx)
  `FC(l1_exit_by_tx, v_wake_tx)
  `FC(phy_lost_in_param, v_phy_param)
  `FC(phy_lost_in_actreq, v_phy_actreq)
  `FC(phy_lost_in_active, v_phy_active)
  `FC(phy_lost_in_l1, v_phy_l1)
  `FC(handshake_timeout_param, v_ht_param)
  `FC(handshake_timeout_actreq, v_ht_actreq)
  `FC(restart_in_actreq, v_restart_actreq)
  `FC(restart_in_active, v_restart_active)
  `FC(restart_in_l1, v_restart_l1)
  `FC(restart_in_retrain, v_restart_retrain)
  `FC(disable_in_linkerr, v_dis_linkerr)
  `FC(sideband_messages_queued, v_sb_multi)
  `FC(sideband_unknown_code, v_sb_unknown)
  `FC(sideband_out_of_state, v_sb_proto)
  // main band
  `FC(flit_in_wrong_state, v_flit_proto_state)
  `FC(flit_in_actreq, v_rx_actreq)
  `FC(rty_mismatch, v_rty_mismatch)
  `FC(stack1_dropped_tx, v_stack_drop_tx)
  `FC(stack1_dropped_rx, v_stack_drop_rx)
  `FC(stack1_sent, v_stack1_tx)
  `FC(stack1_delivered, v_stack1_rx)
  `FC(no_retry_data, v_noretry_data)
  `FC(no_retry_bad_crc, v_noretry_crc)
  `FC(no_retry_nop, v_noretry_nop)
  // Retry
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
  `FC(retrain_requested, v_retrain_req)
  `FC(replay_after_retrain, v_replay_after_retrain)
  // a flit going out with flits outstanding as reset lands (taken on the
  // falling edge, before the asynchronous reset clears them)
  bit busy_n = 0;
  always @(negedge clk) busy_n <= lt_valid && tx_pend != 0;
  `FC_RST(reset_in_traffic, !rst_n && busy_n)
endmodule

bind UCIe_top UCIe_sva #(.RB(RB), .TO(TO), .NR(NR), .HT(HT)) u_sva (.*);
