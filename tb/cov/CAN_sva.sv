// SPDX-License-Identifier: Apache-2.0
// CAN 2.0A/B controller: concurrent SVA against an independent pin-level
// reference model, plus functional coverage.
//  * Bit timing from the cfg pins (hard sync, resync with SJW), own
//    synchroniser; the model predicts txd on every clock.
//  * Frame model works on whole bit sequences instead of a field FSM: a
//    transmitter compares the bus with a stuffed SOF..CRC sequence built at
//    tx accept; a receiver collects de-stuffed bits in an array (stuff rule
//    from a 5-bit raw window) and parses them when the CRC ends / at EOF.
//  * Error frames, TEC/REC rules (incl. the two TEC exceptions), passive
//    flags, suspend, bus-off recovery, abort and acceptance filtering.
// Every output is compared on every clock.
`include "cov_macros.svh"
module CAN_sva (
  input logic        clk, rst_n, rxd, txd,
  input logic [5:0]  cfg_brp,
  input logic [3:0]  cfg_tseg1,
  input logic [2:0]  cfg_tseg2,
  input logic [1:0]  cfg_sjw,
  input logic [28:0] acc_code, acc_mask,
  input logic        tx_valid, tx_ready,
  input logic [28:0] tx_id,
  input logic        tx_ide, tx_rtr,
  input logic [3:0]  tx_dlc,
  input logic [63:0] tx_data,
  input logic        tx_abort, tx_done, tx_aborted, rx_valid,
  input logic [28:0] rx_id,
  input logic        rx_ide, rx_rtr,
  input logic [3:0]  rx_dlc,
  input logic [63:0] rx_data,
  input logic        arb_lost, err_bit, err_stuff, err_crc, err_form, err_ack,
  input logic [8:0]  tec,
  input logic [7:0]  rec,
  input logic        err_passive, bus_off
);
  `COV_CLOCKING(clk, !rst_n)
  localparam int S_IDLE = 0, S_SUSP = 1, S_FRAME = 2, S_FLAG = 3, S_WAIT = 4, S_DELIM = 5,
                 S_IFS = 6, S_OFF = 7;

  // ---------------- synchroniser + bit timing ----------------
  logic q1, q2, q3;
  always_ff @(posedge clk or negedge rst_n)
    if (!rst_n) begin q1 <= 1; q2 <= 1; q3 <= 1; end
    else begin q1 <= rxd; q2 <= q1; q3 <= q2; end

  int   st, pre, tq;
  bit   rsd, lsmp, d;                 // resynced this bit, last sample, model txd
  int   T1, NT, SJ, BP, PN;
  bit   edge_f, hard, rs, rs_late, rs_end, rs_skip, tick, smp, bst;
  always_comb begin
    T1 = int'(cfg_tseg1) + 1;
    NT = 1 + T1 + int'(cfg_tseg2) + 1;
    SJ = int'(cfg_sjw) + 1;
    BP = int'(cfg_brp) + 1;               // clocks per tq
    PN = tq * BP + pre + 1;               // next clock's position in the bit, in clocks
    tick   = pre == int'(cfg_brp);
    edge_f = q3 && !q2;
    hard   = edge_f && (st == S_IDLE || st == S_SUSP || st == S_IFS);
    rs     = edge_f && !hard && st != S_OFF && !rsd && lsmp && d && tq != 0;
    // phase error e = PN (late) or NT*BP - PN (early); correction min(e, SJW)
    rs_late = rs && tq <= T1;
    rs_end  = rs && tq > T1 && NT * BP - PN <= SJ * BP;
    rs_skip = rs && tq > T1 && NT * BP - PN > SJ * BP;
    smp = tick && tq == T1 && !hard && !rs;
    bst = (tick && tq == NT - 1 && !hard && !rs) || rs_end;
  end
  always_ff @(posedge clk or negedge rst_n)
    if (!rst_n) begin pre <= 0; tq <= 0; rsd <= 0; end
    else begin
      if (hard || rs_end || (rs_late && PN <= SJ * BP)) begin pre <= 0; tq <= 0; end
      else if (rs_late) begin pre <= (PN - SJ * BP) % BP; tq <= (PN - SJ * BP) / BP; end
      else if (rs_skip) begin pre <= (PN + SJ * BP) % BP; tq <= (PN + SJ * BP) / BP; end
      else if (tick) begin pre <= 0; tq <= (tq + 1) % NT; end
      else pre <= pre + 1;
      if (smp) rsd <= 0; else if (rs) rsd <= 1;
    end

  // ---------------- transmit buffer and its bit sequence ----------------
  bit          pend, abreq;
  logic [98:0] buf_f;                 // {id, ide, rtr, dlc, data}
  logic        txs [0:159];           // stuffed SOF..CRC to send
  int          txp [0:159];           // de-stuffed index of each bit, -1 = stuff bit
  int          txlen, arbl;
  wire         accept_tx = tx_valid && !pend;

  function automatic logic [14:0] crc_step(input logic [14:0] c, input logic b);
    return (c << 1) ^ (((b ^ c[14]) == 1'b1) ? 15'h4599 : 15'h0);
  endfunction
  function automatic int nbytes(input logic rtr, input logic [3:0] dlc);
    return rtr ? 0 : (dlc > 8 ? 8 : int'(dlc));
  endfunction

  always_ff @(posedge clk) if (rst_n && accept_tx) begin
    logic       s [0:127];
    logic [14:0] c;
    int n, k, run, nb;
    logic last;
    n = 0;
    s[n] = 0; n++;
    if (tx_ide) begin
      for (int i = 28; i >= 18; i--) begin s[n] = tx_id[i]; n++; end
      s[n] = 1; n++; s[n] = 1; n++;
      for (int i = 17; i >= 0; i--) begin s[n] = tx_id[i]; n++; end
      s[n] = tx_rtr; n++; s[n] = 0; n++; s[n] = 0; n++;
      arbl <= 32;
    end else begin
      for (int i = 10; i >= 0; i--) begin s[n] = tx_id[i]; n++; end
      s[n] = tx_rtr; n++; s[n] = 0; n++; s[n] = 0; n++;
      arbl <= 12;
    end
    for (int i = 3; i >= 0; i--) begin s[n] = tx_dlc[i]; n++; end
    nb = nbytes(tx_rtr, tx_dlc);
    for (int i = 0; i < 64; i++) if (i < 8 * nb) begin s[n] = tx_data[8 * (i / 8) + 7 - i % 8]; n++; end
    c = 0;
    for (int i = 0; i < 128; i++) if (i < n) c = crc_step(c, s[i]);
    for (int i = 14; i >= 0; i--) begin s[n] = c[i]; n++; end
    k = 0; run = 0; last = 1'b1;
    for (int i = 0; i < 128; i++) if (i < n) begin
      txs[k] <= s[i]; txp[k] <= i; k++;
      if (i > 0 && s[i] == last) run++; else run = 1;
      last = s[i];
      if (run == 5) begin txs[k] <= ~last; txp[k] <= -1; k++; last = ~last; run = 1; end
    end
    txlen <= k;
  end

  // ---------------- frame model ----------------
  bit          tx_now, crcdone, crcbad, flagp;
  int          n, nd, tail, cnt, rr, oc, mtec, mrec, crc_end;
  logic [4:0]  win;                   // last five raw bits, newest in [0]
  logic        ds [0:127];
  bit          m_txdone, m_txab, m_rxv, m_arb, m_eb, m_es, m_ec, m_ef, m_ea;
  logic [98:0] m_rxf;
  bit          v_join, v_join_idle, v_susp_sof, v_ack_given, v_noteca, v_notecs, v_stuff_after_crc,
               v_eof7_dom_rx, v_err_in_delim, v_arb_at[0:3], v_filtered, v_rec_sat,
               v_rec_to_120, v_off_enter, v_off_exit, v_abort_idle, v_abort_after_lost,
               v_abort_after_err, v_passive_flag;
  wire         m_passive = st != S_OFF && (mtec > 127 || mrec > 127);

  function automatic logic [98:0] parse(input int nbits);
    logic [98:0] g;
    int st0, nb;
    g = 0;
    if (ds[13]) begin
      for (int i = 0; i < 11; i++) g[98 - i] = ds[1 + i];
      for (int i = 0; i < 18; i++) g[87 - i] = ds[14 + i];
      g[69] = 1; g[68] = ds[32];
      for (int i = 0; i < 4; i++) g[67 - i] = ds[35 + i];
      st0 = 39;
    end else begin
      for (int i = 0; i < 11; i++) g[80 - i] = ds[1 + i];
      g[68] = ds[12];
      for (int i = 0; i < 4; i++) g[67 - i] = ds[15 + i];
      st0 = 19;
    end
    nb = nbytes(g[68], g[67:64]);
    for (int i = 0; i < 64; i++) if (i < 8 * nb) g[8 * (i / 8) + 7 - i % 8] = ds[st0 + i];
    return g;
  endfunction

  always_ff @(posedge clk or negedge rst_n) begin
    logic b, eb, es, ef, ea, ec, notec, isstuff;
    logic [14:0] c;
    int t;
    if (!rst_n) begin
      st <= S_IDLE; d <= 1; lsmp <= 1; pend <= 0; abreq <= 0; buf_f <= 0;
      tx_now <= 0; crcdone <= 0; crcbad <= 0; flagp <= 0;
      n <= 0; nd <= 0; tail <= 0; cnt <= 0; rr <= 0; oc <= 0; mtec <= 0; mrec <= 0; crc_end <= 999;
      win <= 0;
      m_txdone <= 0; m_txab <= 0; m_rxv <= 0; m_arb <= 0;
      m_eb <= 0; m_es <= 0; m_ec <= 0; m_ef <= 0; m_ea <= 0; m_rxf <= 0;
    end else begin
      m_txdone <= 0; m_txab <= 0; m_rxv <= 0; m_arb <= 0;
      m_eb <= 0; m_es <= 0; m_ec <= 0; m_ef <= 0; m_ea <= 0;
      v_join = 0; v_join_idle = 0; v_susp_sof = 0; v_ack_given = 0; v_noteca = 0; v_notecs = 0;
      v_stuff_after_crc = 0; v_eof7_dom_rx = 0; v_err_in_delim = 0; v_filtered = 0;
      v_rec_sat = 0; v_rec_to_120 = 0; v_off_enter = 0; v_off_exit = 0; v_abort_idle = 0;
      v_abort_after_lost = 0; v_abort_after_err = 0; v_passive_flag = 0;
      for (int i = 0; i < 4; i++) v_arb_at[i] = 0;
      eb = 0; es = 0; ef = 0; ea = 0; ec = 0; notec = 0;
      b = q2;

      if (accept_tx) begin pend <= 1; buf_f <= {tx_id, tx_ide, tx_rtr, tx_dlc, tx_data}; end
      if (tx_abort && pend) abreq <= 1;
      if (abreq && pend && !tx_now) begin
        pend <= 0; abreq <= 0; m_txab <= 1;
        v_abort_idle = st == S_IDLE;
        v_abort_after_lost = st == S_FRAME;
        v_abort_after_err = st == S_IFS || st == S_SUSP;
      end

      if (bst) begin
        d <= 1;
        if (st == S_IDLE && pend && !abreq) begin d <= 0; tx_now <= 1; end
        if (st == S_FRAME && tx_now && n < txlen) d <= txs[n];
        if (st == S_FRAME && !tx_now && crcdone && tail == 1 && !crcbad) begin d <= 0; v_ack_given = 1; end
        if (st == S_FLAG) d <= flagp;
      end

      if (smp) begin
        lsmp <= b;
        if (st == S_IDLE || st == S_SUSP || st == S_IFS) begin
          if (!b) begin
            st <= S_FRAME; n <= 1; nd <= 1; ds[0] <= 0; win <= 5'b00000; tail <= 0;
            crcdone <= 0; crcbad <= 0; crc_end <= 999;
            if (st == S_IFS) begin
              tx_now <= cnt == 2 && pend && !abreq && !(tx_now && m_passive);
              v_join = cnt == 2 && pend && !abreq && !(tx_now && m_passive);
            end
            if (st == S_SUSP) begin tx_now <= 0; v_susp_sof = 1; end
            if (st == S_IDLE) begin
              tx_now <= tx_now || (pend && !abreq);
              v_join_idle = !tx_now && pend && !abreq;
            end
          end else if (st == S_IFS) begin
            if (cnt == 2) begin cnt <= 0; tx_now <= 0; st <= (tx_now && m_passive) ? S_SUSP : S_IDLE; end
            else cnt <= cnt + 1;
          end else if (st == S_SUSP) begin
            if (cnt == 7) begin cnt <= 0; st <= S_IDLE; end
            else cnt <= cnt + 1;
          end
        end else if (st == S_FRAME) begin
          // first raw bit after SOF: the window holds SOF only
          isstuff = tail == 0 && n >= 5 && (win == 5'b11111 || win == 5'b00000);
          if (isstuff) begin
            if (b == win[0]) begin
              es = 1;
              notec = tx_now && n < txlen && txs[n] && nd <= arbl;
            end
            v_stuff_after_crc = crcdone;
            win <= {win[3:0], b}; n <= n + 1;
          end else if (!crcdone) begin
            ds[nd] <= b;
            win <= {win[3:0], b}; n <= n + 1; nd <= nd + 1;
            if (tx_now && b != txs[n]) begin
              if (txs[n] && txp[n] >= 1 && txp[n] <= arbl) begin
                tx_now <= 0; m_arb <= 1;
                v_arb_at[txp[n] <= 11 ? 0 : txp[n] == 12 ? 1 : txp[n] == 13 ? 2 : 3] = 1;
              end else eb = 1;
            end
            // CRC end once the last DLC bit is in
            if (nd == 18 && !ds[13]) crc_end <= 19 + 8 * nbytes(ds[12], {ds[15], ds[16], ds[17], b}) + 15;
            if (nd == 38 && ds[13])  crc_end <= 39 + 8 * nbytes(ds[32], {ds[35], ds[36], ds[37], b}) + 15;
            if (nd + 1 == crc_end) begin
              crcdone <= 1;
              c = 0;
              for (int i = 0; i < 128; i++) if (i < crc_end - 15) c = crc_step(c, ds[i]);
              crcbad <= 0;
              for (int i = 0; i < 15; i++)
                if ((i == 14 ? b : ds[crc_end - 15 + i]) != c[14 - i]) crcbad <= 1;
            end
          end else begin
            t = tail + 1;
            tail <= t;
            n <= n + 1;
            if (t == 1 && !b) ef = 1;
            if (t == 2 && tx_now && b) ea = 1;
            if (t == 3) begin if (!b) ef = 1; else if (crcbad && !tx_now) ec = 1; end
            if (t >= 4 && t <= 9 && !b) ef = 1;
            if (t == 10 && tx_now && !b) ef = 1;
            if (t == 10 && !tx_now && !b) v_eof7_dom_rx = 1;
            if (t == 9 && b && !tx_now) begin
              if (mrec > 127) begin mrec <= 120; v_rec_to_120 = 1; end
              else if (mrec > 0) mrec <= mrec - 1;
              if (((parse(nd) >> 70 ^ {70'h0, acc_code}) & {70'h0, acc_mask}) == 0) begin
                m_rxv <= 1; m_rxf <= parse(nd);
              end else v_filtered = 1;
            end
            if (t == 10 && !(tx_now && !b)) begin
              st <= S_IFS; cnt <= 0;
              if (tx_now) begin
                pend <= 0; abreq <= 0; m_txdone <= 1;
                if (mtec > 0) mtec <= mtec - 1;
              end
            end
          end
        end else if (st == S_FLAG) begin
          if (cnt == 5) begin cnt <= 0; st <= S_WAIT; end else cnt <= cnt + 1;
        end else if (st == S_WAIT) begin
          if (b) begin cnt <= 1; st <= S_DELIM; end
        end else if (st == S_DELIM) begin
          if (!b) begin ef = 1; v_err_in_delim = 1; end
          else if (cnt == 7) begin cnt <= 0; st <= S_IFS; end
          else cnt <= cnt + 1;
        end else begin                                   // bus-off
          if (!b) rr <= 0;
          else if (rr == 10) begin
            rr <= 0;
            if (oc == 127) begin oc <= 0; mtec <= 0; mrec <= 0; st <= S_IDLE; v_off_exit = 1; end
            else oc <= oc + 1;
          end else rr <= rr + 1;
        end

        if (eb || es || ef || ea || ec) begin
          m_eb <= eb; m_es <= es; m_ef <= ef; m_ea <= ea; m_ec <= ec;
          cnt <= 0; flagp <= m_passive; st <= S_FLAG;
          v_passive_flag = m_passive;
          if (tx_now) begin
            v_notecs = notec;
            v_noteca = ea && m_passive;
            if (!notec && !(ea && m_passive)) begin
              mtec <= mtec + 8;
              if (mtec + 8 > 255) begin st <= S_OFF; tx_now <= 0; rr <= 0; oc <= 0; v_off_enter = 1; end
            end
          end else if (mrec < 255) mrec <= mrec + 1;
          else v_rec_sat = 1;
        end
      end
    end
  end

  // ---------------- assertions ----------------
  `SVA_RST(a_reset_values, !rst_n, txd && tx_ready && !tx_done && !rx_valid && tec == 0 && rec == 0
                                   && !bus_off && !err_passive && !arb_lost)
  `SVA_INV(a_txd_model, txd == d)
  `SVA_INV(a_tx_ready_model, tx_ready == !pend)
  `SVA_INV(a_tx_done_model, tx_done == m_txdone && tx_aborted == m_txab)
  `SVA_INV(a_rx_valid_model, rx_valid == m_rxv)
  `SVA_IMP(a_rx_frame_model, rx_valid, {rx_id, rx_ide, rx_rtr, rx_dlc, rx_data} == m_rxf)
  `SVA_INV(a_arb_lost_model, arb_lost == m_arb)
  `SVA_INV(a_error_pulses_model, {err_bit, err_stuff, err_crc, err_form, err_ack} == {m_eb, m_es, m_ec, m_ef, m_ea})
  `SVA_INV(a_counters_model, int'(tec) == mtec && int'(rec) == mrec)
  `SVA_INV(a_state_model, bus_off == (st == S_OFF) && err_passive == m_passive)
  `SVA_IMP(a_bus_off_recessive, bus_off && $past(bus_off), txd)

  // ---------------- functional coverage ----------------
  // accepted frames registered once: the inputs change between clock edges
  logic       acc_q;
  logic [3:0] acc_dlc;
  logic [1:0] acc_kind;
  always_ff @(posedge clk) begin
    acc_q <= rst_n && accept_tx; acc_dlc <= tx_dlc; acc_kind <= {tx_ide, tx_rtr};
  end
  covergroup cg_can @(posedge clk);
    option.per_instance = 1;
    cp_rx_dlc: coverpoint rx_dlc iff (rst_n && rx_valid);
    cp_tx_dlc: coverpoint acc_dlc iff (rst_n && acc_q);
    cp_rx_kind: coverpoint {rx_ide, rx_rtr} iff (rst_n && rx_valid);
    cp_tx_kind: coverpoint acc_kind iff (rst_n && acc_q);
  endgroup
  cg_can u_cg_can = new;

  `FC(frame_sent, tx_done)
  `FC(frame_received, rx_valid)
  `FC(frame_filtered_out, v_filtered)
  `FC(ack_given, v_ack_given)
  `FC(arb_lost_in_id, v_arb_at[0])
  `FC(arb_lost_at_rtr_or_srr, v_arb_at[1])
  `FC(arb_lost_at_ide, v_arb_at[2])
  `FC(arb_lost_in_ext_id_or_rtr, v_arb_at[3])
  `FC(join_at_third_ifs_bit, v_join)
  `FC(join_at_idle_sof, v_join_idle)
  `FC(sof_during_suspend, v_susp_sof)
  `FC(suspend_completed, st == S_SUSP && smp && q2 && cnt == 7)
  `FC(stuff_bit_after_crc, v_stuff_after_crc)
  `FC(error_bit_tx, err_bit)
  `FC(error_stuff_tx, err_stuff && tx_now)
  `FC(error_stuff_rx, err_stuff && !tx_now)
  `FC(error_crc, err_crc)
  `FC(error_form_rx, err_form && !tx_now)
  `FC(error_form_tx, err_form && tx_now)
  `FC(error_ack, err_ack)
  `FC(error_in_error_delimiter, v_err_in_delim)
  `FC(eof7_dominant_at_receiver, v_eof7_dom_rx)
  `FC(no_tec_passive_ack_error, v_noteca)
  `FC(no_tec_arbitration_stuff_error, v_notecs)
  `FC(passive_error_flag, v_passive_flag)
  `FC(rec_saturated, v_rec_sat)
  `FC(rec_back_to_120, v_rec_to_120)
  `FC(bus_off_entered, v_off_enter)
  `FC(bus_off_recovered, v_off_exit)
  `FC(abort_idle, v_abort_idle)
  `FC(abort_after_arbitration_loss, v_abort_after_lost)
  `FC(abort_after_error, v_abort_after_err)
  `FC(abort_too_late, tx_done && $past(abreq))
  `FC(hard_sync, hard)
  `FC(resync_late, rs_late)
  `FC(resync_late_beyond_sjw, rs_late && PN > SJ * BP)
  `FC(resync_early_end_bit, rs_end)
  `FC(resync_early_beyond_sjw, rs_skip)
  `FC(tx_ext_frame, tx_done && buf_f[69])
  `FC(rx_remote_ext, rx_valid && rx_ide && rx_rtr)
  `FC(rx_dlc_over_8, rx_valid && rx_dlc > 8)
  `FC(min_bit_time, smp && cfg_brp == 0)
  `FC(max_bit_time, smp && cfg_brp == 63 && cfg_tseg1 == 15 && cfg_tseg2 == 7)
  `FC_RST(reset_mid_frame, rst_n && st == S_FRAME ##1 !rst_n)
endmodule

bind CAN_top CAN_sva u_sva (.*);
