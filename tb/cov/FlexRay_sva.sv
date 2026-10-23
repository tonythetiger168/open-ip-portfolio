// SPDX-License-Identifier: Apache-2.0
// FlexRay controller: concurrent SVA against an independent pin-level
// reference model, plus functional coverage.
//  * Sampling: own synchroniser and sample prescaler; the vote is a
//    population count of the last five samples; the strobe is sample 5
//    counted from the last resynchronising edge.
//  * Decoding by position: after the FSS, bit p of the frame is BSS1, BSS2
//    or data bit by p % 10, and FES follows the last CRC byte; bytes are
//    collected in an array and parsed when the FES ends.
//  * Time base as one position in the cycle (clocks); slot and NIT are
//    derived from it; integration and offset correction set it from the
//    time of the first BSS edge.
//  * Transmitter: the whole frame (TSS..FES) is built as a bit array at the
//    action point; bit j is driven for clocks start+1+j*B .. start+(j+1)*B.
// Every output is compared on every clock.
`include "cov_macros.svh"
module FlexRay_sva (
  input logic         clk, rst_n, rxd, txd, tx_en,
  input logic [3:0]   cfg_spc, cfg_tss,
  input logic [9:0]   cfg_slot,
  input logic [5:0]   cfg_ap, cfg_nslots,
  input logic [9:0]   cfg_nit,
  input logic [3:0]   cfg_plen,
  input logic [5:0]   cfg_my_slot,
  input logic         cfg_sync, cfg_cold, cfg_chan_b,
  input logic [7:0]   cfg_corr,
  input logic         tx_valid, tx_ready,
  input logic [127:0] tx_data,
  input logic         tx_done, rx_valid,
  input logic [5:0]   rx_id,
  input logic [5:0]   rx_cycle,
  input logic [6:0]   rx_len,
  input logic         rx_null, rx_sync, rx_startup,
  input logic [127:0] rx_data,
  input logic         synced,
  input logic [5:0]   cycle, slot,
  input logic         cycle_start, err_coding, err_hcrc, err_fcrc, err_slot, err_sync
);
  `COV_CLOCKING(clk, !rst_n)
  localparam int W_IDLE = 0, IDLE = 1, TSS = 2, FRAME = 3;

  function automatic logic [10:0] h_crc(input logic [19:0] d);
    logic [10:0] c;
    c = 11'h01A;
    for (int i = 19; i >= 0; i--) begin
      if (d[i] != c[10]) c = {c[9:0], 1'b0} ^ 11'h385;
      else c = {c[9:0], 1'b0};
    end
    return c;
  endfunction
  function automatic logic [23:0] f_crc(input logic [23:0] c, input logic [7:0] b);
    for (int i = 7; i >= 0; i--) begin
      if (b[i] != c[23]) c = {c[22:0], 1'b0} ^ 24'h5D6DCB;
      else c = {c[22:0], 1'b0};
    end
    return c;
  endfunction

  // ---------------- model state ----------------
  logic        q1, q2;
  longint      now;
  int          pre, ns;                 // prescaler, samples since resync
  bit          win [0:3];               // last four samples, [0] newest
  bit          vq;
  int          d_st, idle_n, tss_n, pos, nb;   // decoder; pos = bits after the FSS
  bit          own_f, nb_known;
  int          slot_f, cyc_f;
  logic [7:0]  fb [0:263];              // received bytes
  logic [7:0]  cur;
  longint      t_edge;
  // time base
  bit          m_sync, m_got, m_ever;  // m_ever: slot/cycle valid since reset
  longint      tpos;                    // clocks into the cycle
  int          m_cyc;
  // transmitter
  bit          tbusy, tfull;
  logic [127:0] tbuf;
  longint      t0;
  int          tn;
  bit          tbits [0:399];
  bit          tnfi;
  bit          m_txd, m_en;
  // registered outputs
  bit          m_txdone, m_rxv, m_cs;
  bit [4:0]    m_err;                   // {coding, hcrc, fcrc, slot, sync}
  logic [10:0] m_id;
  logic [5:0]  m_rcyc;
  logic [6:0]  m_len;
  bit          m_null, m_sy, m_st;
  logic [127:0] m_dat;
  // coverage events
  bit v_integrate, v_rephase, v_corr_fail, v_sync_lost, v_glitch, v_tss_long, v_tss_short_ok;
  bit v_e_bss1, v_e_bss2, v_e_fes1, v_e_fes2, v_null_tx, v_data_tx, v_ignored_unsynced;
  bit v_rx_in_nit, v_own;

  int B, SPC1, SLOTC, NITC, CYCC;
  always_comb begin
    SPC1  = int'(cfg_spc) + 1;
    B     = 8 * SPC1;
    SLOTC = int'(cfg_slot) * B;
    NITC  = int'(cfg_nit) * B;
    CYCC  = int'(cfg_nslots) * SLOTC + NITC;
  end
  // slot of a cycle position (0 = NIT) and the start of that segment
  function automatic int slot_at(input longint p);
    if (SLOTC == 0) slot_at = p < longint'(cfg_nslots) ? int'(p) + 1 : 0;
    else slot_at = p < longint'(cfg_nslots) * SLOTC ? int'(p / SLOTC) + 1 : 0;
  endfunction
  function automatic longint seg_start(input int s);
    seg_start = s == 0 ? longint'(cfg_nslots) * longint'(SLOTC > 0 ? SLOTC : 1)
                       : longint'(s - 1) * longint'(SLOTC > 0 ? SLOTC : 1);
  endfunction
  wire [5:0] m_slot = m_ever ? 6'(slot_at(tpos)) : 6'd0;

  always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      q1 = 1; q2 = 1; now = 0; pre = 0; ns = 0; vq = 1;
      for (int i = 0; i < 4; i++) win[i] = 1;
      d_st = W_IDLE; idle_n = 0; tss_n = 0; pos = 0; nb = 0; own_f = 0; nb_known = 0;
      slot_f = 0; cyc_f = 0; t_edge = 0; cur = 0;
      m_sync = 0; m_got = 0; m_ever = 0; tpos = 0; m_cyc = 0;
      tbusy = 0; tfull = 0; tbuf = 0; t0 = 0; tn = 0; tnfi = 0; m_txd = 1; m_en = 0;
      m_txdone = 0; m_rxv = 0; m_cs = 0; m_err = 0; m_id = 0; m_rcyc = 0; m_len = 0;
      m_null = 0; m_sy = 0; m_st = 0; m_dat = 0;
    end else begin
      bit     tk, vn, fl, stb, rs, en_now, sync0, full0;
      int     ones, slot_now, cyc0;
      longint sc_now, seg_len;
      {v_integrate, v_rephase, v_corr_fail, v_sync_lost, v_glitch, v_tss_long, v_tss_short_ok} = '0;
      {v_e_bss1, v_e_bss2, v_e_fes1, v_e_fes2, v_null_tx, v_data_tx, v_ignored_unsynced} = '0;
      {v_rx_in_nit, v_own} = '0;
      m_txdone = 0; m_rxv = 0; m_cs = 0; m_err = 0;
      en_now = m_en; sync0 = m_sync; cyc0 = m_cyc; full0 = tfull;
      slot_now = m_ever ? slot_at(tpos) : 0;
      sc_now = tpos - seg_start(slot_now);

      // ---- time base
      if (cfg_cold && !m_sync) begin
        m_sync = 1; m_ever = 1; tpos = 0; m_cyc = 0; m_cs = 1;
      end else if (m_sync) begin
        seg_len = slot_now == 0 ? NITC : SLOTC;
        if (sc_now + 1 >= seg_len) begin
          if (slot_now == 0) begin
            tpos = 0; m_cyc = (m_cyc + 1) % 64; m_cs = 1;
            if (!cfg_cold && !m_got) begin m_sync = 0; m_err[0] = 1; v_sync_lost = 1; end
            m_got = 0;
          end else if (slot_now >= int'(cfg_nslots)) tpos = seg_start(0);
          else tpos = seg_start(slot_now + 1);
        end else tpos++;
      end

      // ---- sampling and voting
      tk = pre == int'(cfg_spc);
      pre = tk ? 0 : pre + 1;
      ones = int'(q2) + int'(win[0]) + int'(win[1]) + int'(win[2]) + int'(win[3]);
      vn = ones >= 3;
      fl = tk && vq && !vn;
      rs = d_st == IDLE || (d_st == FRAME && pos % 10 == 1 && !(nb_known && pos == 10 * nb + 1));
      stb = 0;
      if (tk) begin
        ns = (fl && rs) ? 1 : ns + 1;
        stb = ns % 8 == 4;
        win[3] = win[2]; win[2] = win[1]; win[1] = win[0]; win[0] = q2;
        vq = vn;
      end

      // ---- decoder
      if (tk) begin
        if (d_st == W_IDLE) begin
          if (stb) begin
            if (!vn) idle_n = 0;
            else if (idle_n == 10) begin idle_n = 0; d_st = IDLE; end
            else idle_n++;
          end
        end else if (d_st == IDLE) begin
          if (fl) begin
            d_st = TSS; tss_n = 0; own_f = en_now; slot_f = slot_now; cyc_f = cyc0; v_own = en_now;
          end
        end else if (d_st == TSS) begin
          if (stb) begin
            if (vn) begin
              if (tss_n == 0) begin d_st = IDLE; v_glitch = 1; end
              else begin d_st = FRAME; pos = 0; nb_known = 0; v_tss_short_ok = tss_n == int'(cfg_tss) + 1; end
            end else if (tss_n == int'(cfg_tss) + 1) begin
              d_st = W_IDLE; m_err[4] = !own_f; v_tss_long = 1;
            end else tss_n++;
          end
        end else begin                                        // FRAME
          if (fl && pos == 1) t_edge = now;
          if (stb) begin
            int k;
            k = pos % 10;
            if (nb_known && pos == 10 * nb) begin             // FES1
              if (vn) begin d_st = W_IDLE; m_err[4] = !own_f; v_e_fes1 = 1; end
              else pos++;
            end else if (nb_known && pos == 10 * nb + 1) begin   // FES2
              d_st = W_IDLE;
              if (!vn) begin m_err[4] = !own_f; v_e_fes2 = 1; end
              else if (!own_f) begin
                logic [39:0] h;
                logic [23:0] c;
                int          plen_b;
                h = {fb[0], fb[1], fb[2], fb[3], fb[4]};
                plen_b = 2 * int'(h[23:17]);
                c = cfg_chan_b ? 24'hABCDEF : 24'hFEDCBA;
                for (int i = 0; i < 5 + plen_b; i++) c = f_crc(c, fb[i]);
                if (h_crc({h[36:24], h[23:17]}) != h[16:6]) m_err[3] = 1;
                else if (c != {fb[5 + plen_b], fb[6 + plen_b], fb[7 + plen_b]}) m_err[2] = 1;
                else begin
                  logic [127:0] dd;
                  longint       sc_new, diff;
                  bit           ok;
                  dd = 0;
                  for (int i = 0; i < 16; i++) if (i < plen_b) dd[8*i +: 8] = fb[5 + i];
                  sc_new = longint'(int'(cfg_ap) * B) + longint'((int'(cfg_tss) + 2) * B)
                           + 3 + 2 * SPC1 + int'(cfg_spc) / 2
                           + (now - t_edge - 1 > 131071 ? 131071 : now - t_edge - 1) + 1;   // saturating count
                  ok = 0;
                  if (sync0) begin
                    if (int'(h[34:24]) != slot_f || int'(h[5:0]) != cyc_f) m_err[1] = 1;
                    else begin
                      ok = 1;
                      v_rx_in_nit = slot_now == 0;
                      if (h[36] && !cfg_cold) begin
                        m_got = 1;
                        diff = sc_new - (sc_now + 1);
                        if (diff < 0) diff = -diff;
                        if (diff > longint'(cfg_corr)) begin
                          m_sync = 0; m_err[0] = 1; v_corr_fail = 1;
                        end else begin
                          tpos = seg_start(slot_now) + sc_new % 131072; v_rephase = 1;
                        end
                      end
                    end
                  end else if (h[36] && h[34:24] != 0 && int'(h[34:24]) <= int'(cfg_nslots)) begin
                    ok = 1; v_integrate = 1;
                    m_sync = 1; m_ever = 1; m_got = 1; m_cyc = int'(h[5:0]);
                    tpos = seg_start(int'(h[34:24])) + sc_new % 131072;
                  end else v_ignored_unsynced = 1;
                  if (ok) begin
                    m_rxv = 1; m_id = h[34:24]; m_rcyc = h[5:0]; m_len = h[23:17];
                    m_null = !h[37]; m_sy = h[36]; m_st = h[35]; m_dat = dd;
                  end
                end
              end
            end else if (k == 0) begin                        // BSS1
              if (!vn) begin d_st = W_IDLE; m_err[4] = !own_f; v_e_bss1 = 1; end
              else pos++;
            end else if (k == 1) begin                        // BSS2
              if (vn) begin d_st = W_IDLE; m_err[4] = !own_f; v_e_bss2 = 1; end
              else pos++;
            end else begin                                    // data bit
              cur = {cur[6:0], vn};
              if (k == 9) begin
                fb[pos / 10] = cur;
                if (pos / 10 == 4) begin nb = 8 + 2 * int'(fb[2][7:1]); nb_known = 1; end
              end
              pos++;
            end
          end
        end
      end

      // ---- transmit buffer and transmitter
      if (!tbusy) begin
        if (sync0 && slot_now != 0 && slot_now == int'(cfg_my_slot)
            && sc_now == longint'(int'(cfg_ap) * B)) begin
          logic [39:0] h;
          logic [23:0] c;
          logic [7:0]  by;
          int          pb;
          pb = 2 * int'(cfg_plen);
          tnfi = full0;
          h = {2'b00, full0, cfg_sync, cfg_sync & cfg_cold, 5'd0, cfg_my_slot, 3'd0, cfg_plen,
               h_crc({cfg_sync, cfg_sync & cfg_cold, 5'd0, cfg_my_slot, 3'd0, cfg_plen}), 6'(cyc0)};
          c = cfg_chan_b ? 24'hABCDEF : 24'hFEDCBA;
          tn = 0;
          for (int i = 0; i < int'(cfg_tss); i++) begin tbits[tn] = 0; tn++; end
          tbits[tn] = 1; tn++;
          for (int i = 0; i < 8 + pb; i++) begin
            if (i < 5) by = h[39 - 8 * i -: 8];
            else if (i < 5 + pb) by = (i - 5 < 16 && full0) ? tbuf[8 * (i - 5) +: 8] : 8'h00;
            else by = c[23 - 8 * (i - 5 - pb) -: 8];
            if (i < 5 + pb) c = f_crc(c, by);
            tbits[tn] = 1; tbits[tn + 1] = 0; tn += 2;
            for (int j = 7; j >= 0; j--) begin tbits[tn] = by[j]; tn++; end
          end
          tbits[tn] = 0; tbits[tn + 1] = 1; tn += 2;
          v_null_tx = !full0; v_data_tx = full0;
          tbusy = 1; t0 = now; m_txd = 0; m_en = 1;
          if (full0) tfull = 0;
        end
      end else begin
        longint o;
        o = now - t0;                                         // clocks since the start
        if (o == longint'(tn) * B) begin
          tbusy = 0; m_en = 0;
          if (tnfi) m_txdone = 1;
        end else m_txd = tbits[int'(o / B)];
      end
      if (tx_valid && !full0) begin tfull = 1; tbuf = tx_data; end

      q2 = q1; q1 = rxd;
      now++;
    end
  end

  // ---------------- assertions ----------------
  `SVA_RST(a_reset_values, !rst_n, txd && !tx_en && tx_ready && !tx_done && !rx_valid && !synced
                                   && slot == 0 && cycle == 0 && !cycle_start
                                   && {err_coding, err_hcrc, err_fcrc, err_slot, err_sync} == 0)
  `SVA_INV(a_txd_model, txd == m_txd && tx_en == m_en)
  `SVA_INV(a_tx_ready_model, tx_ready == !tfull)
  `SVA_INV(a_tx_done_model, tx_done == m_txdone)
  `SVA_INV(a_time_base_model, synced == m_sync && int'(cycle) == m_cyc && slot == m_slot
                              && cycle_start == m_cs)
  `SVA_INV(a_rx_valid_model, rx_valid == m_rxv)
  `SVA_IMP(a_rx_frame_model, rx_valid, rx_id == m_id && rx_cycle == m_rcyc && rx_len == m_len
                                       && rx_null == m_null && rx_sync == m_sy && rx_startup == m_st
                                       && rx_data == m_dat)
  `SVA_INV(a_errors_model, {err_coding, err_hcrc, err_fcrc, err_slot, err_sync} == m_err)

  // ---------------- functional coverage ----------------
  logic       rx_q, rx_nul_q;
  logic [6:0] rx_len_q;
  always_ff @(posedge clk) begin rx_q <= rst_n && rx_valid; rx_nul_q <= rx_null; rx_len_q <= rx_len; end
  covergroup cg_fr @(posedge clk);
    option.per_instance = 1;
    cp_rx_len: coverpoint rx_len_q iff (rst_n && rx_q && !rx_nul_q) {
      bins zero = {0}; bins short_[] = {[1:8]}; bins mid_ = {[9:62]}; bins b63 = {63}; bins b64 = {64};
      bins long_ = {[65:127]};
    }
    cp_slot: coverpoint slot iff (rst_n && synced) { bins nit = {0}; bins first = {1}; bins low[] = {[2:6]};
                                                    bins high = {[7:63]}; }
  endgroup
  cg_fr u_cg_fr = new;

  `FC(integration, v_integrate)
  `FC(offset_correction, v_rephase)
  `FC(correction_beyond_limit, v_corr_fail)
  `FC(sync_lost_no_sync_frame, v_sync_lost)
  `FC(frame_ignored_unsynced, v_ignored_unsynced)
  `FC(glitch_ignored, v_glitch)
  `FC(tss_too_long, v_tss_long)
  `FC(tss_one_bit_longer, v_tss_short_ok)
  `FC(bss1_error, v_e_bss1)
  `FC(bss2_error, v_e_bss2)
  `FC(fes1_error, v_e_fes1)
  `FC(fes2_error, v_e_fes2)
  `FC(header_crc_error, err_hcrc)
  `FC(frame_crc_error, err_fcrc)
  `FC(slot_error, err_slot)
  `FC(null_frame_sent, v_null_tx)
  `FC(data_frame_sent, v_data_tx)
  `FC(null_frame_received, rx_valid && rx_null)
  `FC(sync_frame_received, rx_valid && rx_sync)
  `FC(startup_frame_received, rx_valid && rx_startup)
  `FC(frame_ends_in_nit, v_rx_in_nit)
  `FC(own_frame_seen, v_own)
  `FC(cycle_wrap, cycle_start && cycle == 0 && synced && $past(synced))
  `FC(channel_b, rx_valid && cfg_chan_b)
  `FC(tx_ready_during_frame, tx_en && tx_valid && tx_ready)
  `FC_RST(reset_mid_frame, rst_n && tx_en ##1 !rst_n)
endmodule

bind FlexRay_top FlexRay_sva u_sva (.*);
