// SPDX-License-Identifier: Apache-2.0
// CAN XL controller: concurrent SVA against an independent pin-level
// reference model, plus functional coverage.
//  * Bit timing from the cfg pins at the nominal or data rate (hard sync,
//    resync with SJW), own synchroniser; the model predicts txd, tx_fast
//    and rx_fast on every clock.
//  * Frame model works on whole bit sequences instead of a field FSM: when
//    a node starts its frame, the model builds the whole stuffed SOF..FCP
//    (XL) or SOF..CRC (CC) sequence from the header and its own copy of the
//    TX buffer (dynamic stuffing, SBC, PCRC, FCRC, fixed stuffing) and
//    compares the bus with it; a receiver collects de-stuffed bits (stuff
//    rule from a 5-bit raw window or a fixed-stuff counter) and checks the
//    SBC / PCRC, the fixed fields, the FCRC and the FCP from that array.
//  * Error frames, TEC/REC rules (incl. the two TEC exceptions), passive
//    flags, suspend, bus-off recovery, protocol exceptions, abort, refused
//    frames, acceptance filtering, and the received bytes on hb_rdata.
// The TX buffer must not change while its frame is on the bus.
`include "cov_macros.svh"
module CAN_XL_sva #(
  parameter int MAX_BYTES = 64,
  parameter int FS        = 10,
  localparam int BW = $clog2(MAX_BYTES),
  localparam int WW = BW - 2
) (
  input logic          clk, rst_n, rxd, txd, tx_fast, rx_fast,
  input logic [5:0]    cfg_brp,
  input logic [3:0]    cfg_tseg1,
  input logic [2:0]    cfg_tseg2,
  input logic [1:0]    cfg_sjw,
  input logic [5:0]    cfg_dbrp,
  input logic [3:0]    cfg_dtseg1,
  input logic [2:0]    cfg_dtseg2,
  input logic [1:0]    cfg_dsjw,
  input logic [28:0]   acc_code, acc_mask,
  input logic          hb_wen,
  input logic [WW-1:0] hb_waddr,
  input logic [31:0]   hb_wdata,
  input logic [WW-1:0] hb_raddr,
  input logic [31:0]   hb_rdata,
  input logic          tx_valid, tx_ready, tx_xl,
  input logic [28:0]   tx_id,
  input logic          tx_ide, tx_rtr,
  input logic [10:0]   tx_dlc,
  input logic [7:0]    tx_sdt,
  input logic          tx_sec,
  input logic [7:0]    tx_vcid,
  input logic [31:0]   tx_af,
  input logic          tx_abort, tx_done, tx_aborted, tx_rejected,
  input logic          rx_valid, rx_xl,
  input logic [28:0]   rx_id,
  input logic          rx_ide, rx_rtr,
  input logic [10:0]   rx_dlc,
  input logic [7:0]    rx_sdt,
  input logic          rx_sec,
  input logic [7:0]    rx_vcid,
  input logic [31:0]   rx_af,
  input logic          rx_trunc,
  input logic          arb_lost, err_bit, err_stuff, err_crc, err_form, err_ack, pexc,
  input logic [8:0]    tec,
  input logic [7:0]    rec,
  input logic          err_passive, bus_off
);
  `COV_CLOCKING(clk, !rst_n)
  localparam int S_IDLE = 0, S_SUSP = 1, S_FRAME = 2, S_FLAG = 3, S_WAIT = 4, S_DELIM = 5,
                 S_IFS = 6, S_OFF = 7, S_PEXC = 8;
  localparam int DN  = 8 * MAX_BYTES + 136;     // de-stuffed bits of the longest own frame
  localparam int RN  = DN + DN / FS + 16;       // with its stuff bits
  localparam int RXN = 8 * 2048 + 136;          // longest XL frame on the bus
  localparam int UNK = 1 << 30;                 // length not known yet

  // ---------------- synchroniser + bit timing ----------------
  logic q1, q2, q3;
  always_ff @(posedge clk or negedge rst_n)
    if (!rst_n) begin q1 <= 1; q2 <= 1; q3 <= 1; end
    else begin q1 <= rxd; q2 <= q1; q3 <= q2; end

  int   st, pre, tq;
  bit   rsd, lsmp, d, mdph;           // resynced this bit, last sample, model txd, data rate
  int   T1, NT, SJ, BP, PN;
  bit   edge_f, hard, rs, rs_late, rs_end, rs_skip, tick, smp, bst;
  always_comb begin
    T1 = int'(mdph ? cfg_dtseg1 : cfg_tseg1) + 1;
    NT = 1 + T1 + int'(mdph ? cfg_dtseg2 : cfg_tseg2) + 1;
    SJ = int'(mdph ? cfg_dsjw : cfg_sjw) + 1;
    BP = int'(mdph ? cfg_dbrp : cfg_brp) + 1;     // clocks per tq
    PN = tq * BP + pre + 1;                       // next clock's position in the bit, in clocks
    tick   = pre == BP - 1;
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

  // ---------------- CRCs ----------------
  function automatic logic [14:0] c15(input logic [14:0] c, input logic b);
    return {c[13:0], 1'b0} ^ ((b ^ c[14]) ? 15'h4599 : 15'h0);
  endfunction
  function automatic logic [12:0] c13(input logic [12:0] c, input logic b);
    return {c[11:0], 1'b0} ^ ((b ^ c[12]) ? 13'h19E7 : 13'h0);
  endfunction
  function automatic logic [31:0] c32(input logic [31:0] c, input logic b);
    return {c[30:0], 1'b0} ^ ((b ^ c[31]) ? 32'hF4ACFB13 : 32'h0);
  endfunction
  function automatic int cc_bytes(input logic rtr, input logic [3:0] dlc);
    return rtr ? 0 : (dlc > 8 ? 8 : int'(dlc));
  endfunction
  function automatic int q_bytes(input logic xl, input logic rtr, input logic [10:0] dlc);
    return xl ? int'(dlc) + 1 : cc_bytes(rtr, dlc[3:0]);
  endfunction

  // ---------------- transmit buffer and its bit sequence ----------------
  logic [7:0]  mtb [0:MAX_BYTES-1];
  always_ff @(posedge clk)
    if (hb_wen) for (int i = 0; i < 4; i++) mtb[4 * int'(hb_waddr) + i] <= hb_wdata[8 * i +: 8];

  bit          pend, abreq, bx, bide, brtr, bsec;
  logic [28:0] bid;
  logic [10:0] bdlc;
  logic [7:0]  bsdt, bvcid;
  logic [31:0] baf;
  wire         q_fit     = q_bytes(tx_xl, tx_rtr, tx_dlc) <= MAX_BYTES;
  wire         accept_tx = tx_valid && !pend && q_fit;
  wire         refuse_tx = tx_valid && !pend && !q_fit;

  logic        os  [0:DN-1];          // own frame, de-stuffed
  logic        txs [0:RN-1];          // own frame, stuffed
  int          txlen, arbl;
  task automatic build_tx();
    int L, xe, nb, k, run, fc;
    logic last;
    logic [12:0] p;
    logic [31:0] f;
    logic [14:0] c;
    logic [1:0]  g;
    os[0] = 0;
    if (bx) begin
      for (int i = 0; i < 11; i++) os[1 + i] = bid[10 - i];
      os[12] = 0; os[13] = 0; os[14] = 1; os[15] = 1; os[16] = 0;
      os[17] = 1; os[18] = 1; os[19] = 1; os[20] = 0;
      for (int i = 0; i < 8; i++) os[21 + i] = bsdt[7 - i];
      os[29] = bsec;
      for (int i = 0; i < 11; i++) os[30 + i] = bdlc[10 - i];
      // dynamic stuff bits ahead of indices 1..17: their count and the PCRC
      p = 0; k = 0; run = 0; last = 0;
      for (int i = 0; i <= 17; i++) begin
        if (i > 0 && run == 5) begin p = c13(p, ~last); last = ~last; run = 1; k++; end
        p = c13(p, os[i]);
        if (i == 0 || os[i] != last) run = 1; else run++;
        last = os[i];
      end
      g = 2'(k) ^ (2'(k) >> 1);
      os[41] = g[1]; os[42] = g[0]; os[43] = ^g;
      for (int i = 18; i <= 43; i++) p = c13(p, os[i]);
      for (int i = 0; i < 13; i++) os[44 + i] = p[12 - i];
      for (int i = 0; i < 8; i++) os[57 + i] = bvcid[7 - i];
      for (int i = 0; i < 32; i++) os[65 + i] = baf[31 - i];
      nb = int'(bdlc) + 1;
      for (int i = 0; i < 8 * nb; i++) os[97 + i] = mtb[i / 8][7 - i % 8];
      xe = 97 + 8 * nb;
      f = 0;
      for (int i = 0; i < xe; i++) f = c32(f, os[i]);
      for (int i = 0; i < 32; i++) os[xe + i] = f[31 - i];
      os[xe + 32] = 1; os[xe + 33] = 1; os[xe + 34] = 0; os[xe + 35] = 0;
      L = xe + 36;
      k = 0; run = 0; last = 0; fc = 0;
      for (int i = 0; i < L; i++) begin
        if (i >= 1 && i <= 17 && run == 5) begin
          txs[k] = ~last; k++; last = ~last; run = 1;
        end else if (i >= 21 && i <= xe + 31 && fc == FS) begin
          txs[k] = ~last; k++; last = ~last; run = 1; fc = 0;
        end
        txs[k] = os[i]; k++;
        if (i == 0 || os[i] != last) run = 1; else run++;
        last = os[i];
        if (i >= 20 && i <= xe + 31) fc++;
      end
      arbl = 12;
    end else begin
      if (bide) begin
        for (int i = 0; i < 11; i++) os[1 + i] = bid[28 - i];
        os[12] = 1; os[13] = 1;
        for (int i = 0; i < 18; i++) os[14 + i] = bid[17 - i];
        os[32] = brtr; os[33] = 0; os[34] = 0;
        for (int i = 0; i < 4; i++) os[35 + i] = bdlc[3 - i];
        k = 39; arbl = 32;
      end else begin
        for (int i = 0; i < 11; i++) os[1 + i] = bid[10 - i];
        os[12] = brtr; os[13] = 0; os[14] = 0;
        for (int i = 0; i < 4; i++) os[15 + i] = bdlc[3 - i];
        k = 19; arbl = 12;
      end
      nb = cc_bytes(brtr, bdlc[3:0]);
      for (int i = 0; i < 8 * nb; i++) os[k + i] = mtb[i / 8][7 - i % 8];
      xe = k + 8 * nb;
      c = 0;
      for (int i = 0; i < xe; i++) c = c15(c, os[i]);
      for (int i = 0; i < 15; i++) os[xe + i] = c[14 - i];
      L = xe + 15;
      k = 0; run = 0; last = 0;
      for (int i = 0; i <= L; i++) begin
        if (i >= 1 && run == 5) begin txs[k] = ~last; k++; last = ~last; run = 1; end
        if (i < L) begin
          txs[k] = os[i]; k++;
          if (i == 0 || os[i] != last) run = 1; else run++;
          last = os[i];
        end
      end
    end
    txlen = k;
  endtask

  // ---------------- frame model ----------------
  bit          tx_now, bdone, crcbad, flagp, fdf, xl, xdk;
  int          n, nd, tail, cnt, rr, oc, mtec, mrec, bend, xc, fc, dsc, np;
  logic [4:0]  win;                   // last five raw bits, newest in [0]
  logic        ds [0:RXN-1];          // received frame, de-stuffed
  logic        ph [0:63];             // raw bits up to index 43 without fixed stuff bits (PCRC)
  logic [7:0]  mrb [0:MAX_BYTES-1];   // bytes of the last delivered frame
  int          mrn;                   // ... how many
  bit          m_txdone, m_txab, m_txrej, m_rxv, m_arb, m_eb, m_es, m_ec, m_ef, m_ea, m_px;
  logic [92:0] m_rxh;                 // {xl, id, ide, rtr, dlc, sdt, sec, vcid, af, trunc}
  bit          v_join, v_join_idle, v_susp_sof, v_ack_given, v_noteca, v_notecs, v_stuff_after_crc,
               v_eof7_dom_rx, v_err_in_delim, v_arb_at[0:3], v_filtered, v_rec_sat,
               v_rec_to_120, v_off_enter, v_off_exit, v_abort_idle, v_abort_after_lost,
               v_abort_after_err, v_passive_flag, v_px_fd, v_px_r1, v_px_end, v_xl_form,
               v_fcp_form, v_sbc_bad, v_pcrc_bad, v_fcrc_bad, v_fix_stuff_err,
               v_dp_err, v_fix_last, v_dyn_before_fdf;
  int          v_dsc;                 // dynamic stuff count of an XL header (at the SBC), else -1
  wire         m_passive = st != S_OFF && (mtec > 127 || mrec > 127);

  function automatic logic [92:0] rx_hdr();
    logic [28:0] id;
    logic [10:0] dl;
    logic [7:0]  sdt, vcid;
    logic [31:0] af;
    logic        ide, rtr;
    id = 0; dl = 0; sdt = 0; vcid = 0; af = 0; ide = 0; rtr = 0;
    if (xl) begin
      for (int i = 0; i < 11; i++) id[10 - i] = ds[1 + i];
      for (int i = 0; i < 8; i++) sdt[7 - i] = ds[21 + i];
      for (int i = 0; i < 11; i++) dl[10 - i] = ds[30 + i];
      for (int i = 0; i < 8; i++) vcid[7 - i] = ds[57 + i];
      for (int i = 0; i < 32; i++) af[31 - i] = ds[65 + i];
      return {1'b1, id, 1'b0, 1'b0, dl, sdt, ds[29], vcid, af, int'(dl) + 1 > MAX_BYTES};
    end
    ide = ds[13];
    if (ide) begin
      for (int i = 0; i < 11; i++) id[28 - i] = ds[1 + i];
      for (int i = 0; i < 18; i++) id[17 - i] = ds[14 + i];
      rtr = ds[32];
      for (int i = 0; i < 4; i++) dl[3 - i] = ds[35 + i];
    end else begin
      for (int i = 0; i < 11; i++) id[10 - i] = ds[1 + i];
      rtr = ds[12];
      for (int i = 0; i < 4; i++) dl[3 - i] = ds[15 + i];
    end
    return {1'b0, id, ide, rtr, dl, sdt, 1'b0, vcid, af, 1'b0};
  endfunction

  always_ff @(posedge clk or negedge rst_n) begin
    logic b, eb, es, ef, ea, ec, notec, isdyn, isfix;
    logic [12:0] p;
    logic [31:0] f;
    logic [14:0] c;
    logic [1:0]  g;
    logic [92:0] h;
    logic [10:0] dl;
    int t, nb, d0;
    bit bad;
    if (!rst_n) begin
      st <= S_IDLE; d <= 1; mdph <= 0; lsmp <= 1; pend <= 0; abreq <= 0;
      bx <= 0; bid <= 0; bide <= 0; brtr <= 0; bdlc <= 0; bsdt <= 0; bsec <= 0; bvcid <= 0; baf <= 0;
      tx_now <= 0; bdone <= 0; crcbad <= 0; flagp <= 0; fdf <= 0; xl <= 0; xdk <= 0;
      n <= 0; nd <= 0; tail <= 0; cnt <= 0; rr <= 0; oc <= 0; mtec <= 0; mrec <= 0; bend <= UNK;
      xc <= 0; fc <= 0; dsc <= 0; np <= 0; win <= 0; mrn <= 0;
      m_txdone <= 0; m_txab <= 0; m_txrej <= 0; m_rxv <= 0; m_arb <= 0; m_px <= 0;
      m_eb <= 0; m_es <= 0; m_ec <= 0; m_ef <= 0; m_ea <= 0; m_rxh <= 0;
    end else begin
      m_txdone <= 0; m_txab <= 0; m_txrej <= 0; m_rxv <= 0; m_arb <= 0; m_px <= 0;
      m_eb <= 0; m_es <= 0; m_ec <= 0; m_ef <= 0; m_ea <= 0;
      v_join = 0; v_join_idle = 0; v_susp_sof = 0; v_ack_given = 0; v_noteca = 0; v_notecs = 0;
      v_stuff_after_crc = 0; v_eof7_dom_rx = 0; v_err_in_delim = 0; v_filtered = 0;
      v_rec_sat = 0; v_rec_to_120 = 0; v_off_enter = 0; v_off_exit = 0; v_abort_idle = 0;
      v_abort_after_lost = 0; v_abort_after_err = 0; v_passive_flag = 0;
      v_px_fd = 0; v_px_r1 = 0; v_px_end = 0; v_xl_form = 0; v_fcp_form = 0; v_sbc_bad = 0;
      v_pcrc_bad = 0; v_fcrc_bad = 0; v_fix_stuff_err = 0; v_dp_err = 0;
      v_fix_last = 0; v_dyn_before_fdf = 0; v_dsc = -1;
      for (int i = 0; i < 4; i++) v_arb_at[i] = 0;
      eb = 0; es = 0; ef = 0; ea = 0; ec = 0; notec = 0;
      b = q2;

      if (tx_valid && !pend) begin
        if (q_fit) begin
          pend <= 1;
          bx <= tx_xl; bid <= tx_id; bide <= tx_ide && !tx_xl; brtr <= tx_rtr && !tx_xl;
          bdlc <= tx_dlc; bsdt <= tx_sdt; bsec <= tx_sec; bvcid <= tx_vcid; baf <= tx_af;
        end else m_txrej <= 1;
      end
      if (tx_abort && pend) abreq <= 1;
      if (abreq && pend && !tx_now) begin
        pend <= 0; abreq <= 0; m_txab <= 1;
        v_abort_idle = st == S_IDLE;
        v_abort_after_lost = st == S_FRAME;
        v_abort_after_err = st == S_IFS || st == S_SUSP;
      end

      if (bst) begin
        d <= 1;
        mdph <= st == S_FRAME && xl && nd >= 18 && nd < bend;
        if (st == S_IDLE && pend && !abreq) begin d <= 0; tx_now <= 1; end
        if (st == S_FRAME && tx_now && n < txlen) d <= txs[n];
        if (st == S_FRAME && !tx_now && bdone && tail == 1 && !crcbad) begin d <= 0; v_ack_given = 1; end
        if (st == S_FLAG) d <= flagp;
      end

      if (smp) begin
        lsmp <= b;
        if (st == S_IDLE || st == S_SUSP || st == S_IFS) begin
          if (!b) begin
            st <= S_FRAME; n <= 1; nd <= 1; ds[0] <= 0; ph[0] <= 0; np <= 1; win <= 5'b00000;
            tail <= 0; bdone <= 0; crcbad <= 0; bend <= UNK; fdf <= 0; xl <= 0; xdk <= 0;
            fc <= 0; dsc <= 0;
            if (st == S_IFS) begin
              tx_now <= cnt == 2 && pend && !abreq && !(tx_now && m_passive);
              v_join = cnt == 2 && pend && !abreq && !(tx_now && m_passive);
              if (v_join) build_tx();
            end
            if (st == S_SUSP) begin tx_now <= 0; v_susp_sof = 1; end
            if (st == S_IDLE) begin
              tx_now <= tx_now || (pend && !abreq);
              v_join_idle = !tx_now && pend && !abreq;
              if (tx_now || (pend && !abreq)) build_tx();
            end
          end else if (st == S_IFS) begin
            if (cnt == 2) begin cnt <= 0; tx_now <= 0; st <= (tx_now && m_passive) ? S_SUSP : S_IDLE; end
            else cnt <= cnt + 1;
          end else if (st == S_SUSP) begin
            if (cnt == 7) begin cnt <= 0; st <= S_IDLE; end
            else cnt <= cnt + 1;
          end
        end else if (st == S_FRAME) begin
          // a dynamic stuff bit (up to index 17 in XL frames, after the CRC
          // in CC frames) or a fixed one (XL, DL1 to the last FCRC bit)
          isdyn = tail == 0 && n >= 5 && (win == 5'b11111 || win == 5'b00000) && (!xl || nd <= 17);
          isfix = xl && nd >= 21 && (!xdk || nd <= xc + 31) && fc == FS;
          if (isdyn || isfix) begin
            if (b == win[0]) begin
              es = 1;
              notec = isdyn && tx_now && n < txlen && txs[n] && nd <= arbl;
              v_fix_stuff_err = isfix;
            end
            if (isdyn) begin
              dsc <= dsc + 1;
              if (nd <= 43) begin ph[np] <= b; np <= np + 1; end
              v_dyn_before_fdf = nd == 14;          // the last place one can be
            end
            if (isfix) begin fc <= 0; v_fix_last = xdk && nd == xc + 31; end
            v_stuff_after_crc = bdone;
            win <= {win[3:0], b}; n <= n + 1;
          end else if (!bdone) begin
            ds[nd] <= b;
            win <= {win[3:0], b}; n <= n + 1; nd <= nd + 1;
            if (nd <= 43) begin ph[np] <= b; np <= np + 1; end
            if (xl && nd >= 20 && (!xdk || nd <= xc + 31)) fc <= fc + 1;
            if (tx_now && n < txlen && b != txs[n]) begin
              if (txs[n] && nd >= 1 && nd <= arbl) begin
                tx_now <= 0; m_arb <= 1;
                v_arb_at[nd <= 11 ? 0 : nd == 12 ? 1 : nd == 13 ? 2 : 3] = 1;
              end else eb = 1;
            end
            // format: FDF / XLF of base frames, r1 of extended frames
            if (nd == 14 && !ds[13]) fdf <= b;
            if (nd == 15 && !ds[13] && fdf) begin
              if (b) xl <= 1;
              else begin st <= S_PEXC; m_px <= 1; tx_now <= 0; rr <= 0; v_px_fd = 1; end
            end
            if (nd == 33 && ds[13] && b) begin st <= S_PEXC; m_px <= 1; tx_now <= 0; rr <= 0; v_px_r1 = 1; end
            if (xl) begin
              if (((nd == 16 || nd == 20) && b) || (nd >= 17 && nd <= 19 && !b)) begin ef = 1; v_xl_form = 1; end
              if (nd == 40) begin
                for (int i = 0; i < 10; i++) dl[10 - i] = ds[30 + i];
                dl[0] = b;
                xdk <= 1; xc <= 97 + 8 * (int'(dl) + 1); bend <= 97 + 8 * (int'(dl) + 1) + 36;
              end
              if (nd == 41) v_dsc = dsc % 4;
              if (nd == 56) begin
                p = 0;
                for (int i = 0; i < 64; i++) if (i < np) p = c13(p, ph[i]);
                bad = 0;
                for (int i = 0; i < 13; i++) if ((i == 12 ? b : ds[44 + i]) != p[12 - i]) bad = 1;
                g = 2'(dsc) ^ (2'(dsc) >> 1);
                v_pcrc_bad = bad;
                v_sbc_bad = !bad && {ds[41], ds[42], ds[43]} != {g, ^g};
                if (bad || {ds[41], ds[42], ds[43]} != {g, ^g}) ec = 1;
              end
              if (xdk && nd == xc + 31) begin
                f = 0;
                for (int i = 0; i < RXN; i++) if (i < xc) f = c32(f, ds[i]);
                bad = 0;
                for (int i = 0; i < 32; i++) if ((i == 31 ? b : ds[xc + i]) != f[31 - i]) bad = 1;
                crcbad <= bad;
              end
              if (xdk && nd >= xc + 32 && b != (nd < xc + 34)) begin ef = 1; v_fcp_form = 1; end
            end else begin
              // CC: CRC end once the last DLC bit is in
              if (nd == 18 && !ds[13] && !fdf) bend <= 19 + 8 * cc_bytes(ds[12], {ds[15], ds[16], ds[17], b}) + 15;
              if (nd == 38 && ds[13]) bend <= 39 + 8 * cc_bytes(ds[32], {ds[35], ds[36], ds[37], b}) + 15;
              if (nd + 1 == bend) begin
                c = 0;
                for (int i = 0; i < 128; i++) if (i < bend - 15) c = c15(c, ds[i]);
                bad = 0;
                for (int i = 0; i < 15; i++) if ((i == 14 ? b : ds[bend - 15 + i]) != c[14 - i]) bad = 1;
                crcbad <= bad;
              end
            end
            if (nd + 1 == bend) bdone <= 1;
          end else begin
            t = tail + 1;
            tail <= t;
            n <= n + 1;
            if (t == 1 && !b) ef = 1;
            if (t == 2 && tx_now && b) ea = 1;
            if (t == 3) begin
              if (!b) ef = 1;
              else if (crcbad) begin ec = 1; v_fcrc_bad = xl; end
            end
            if (t >= 4 && t <= 9 && !b) ef = 1;
            if (t == 10 && tx_now && !b) ef = 1;
            if (t == 10 && !tx_now && !b) v_eof7_dom_rx = 1;
            if (t == 9 && b && !tx_now) begin
              if (mrec > 127) begin mrec <= 120; v_rec_to_120 = 1; end
              else if (mrec > 0) mrec <= mrec - 1;
              h = rx_hdr();
              if (((h[91:63] ^ acc_code) & acc_mask) == 0) begin
                m_rxv <= 1; m_rxh <= h;
                nb = xl ? int'(h[60:50]) + 1 : cc_bytes(h[61], h[53:50]);
                d0 = xl ? 97 : ds[13] ? 39 : 19;
                mrn <= nb > MAX_BYTES ? MAX_BYTES : nb;
                for (int j = 0; j < MAX_BYTES; j++)
                  if (j < nb) for (int i = 0; i < 8; i++) mrb[j][7 - i] = ds[d0 + 8 * j + i];
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
        end else if (st == S_PEXC) begin                 // 11 recessive bits
          if (!b) rr <= 0;
          else if (rr == 10) begin rr <= 0; st <= S_IDLE; v_px_end = 1; end
          else rr <= rr + 1;
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
          v_dp_err = mdph;
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

  // received bytes on the host port (only the delivered frame's length)
  function automatic bit rdata_ok();
    for (int i = 0; i < 4; i++)
      if (4 * int'(hb_raddr) + i < mrn && hb_rdata[8 * i +: 8] != mrb[4 * int'(hb_raddr) + i]) return 0;
    return 1;
  endfunction

  // ---------------- assertions ----------------
  `SVA_RST(a_reset_values, !rst_n, txd && tx_ready && !tx_done && !rx_valid && tec == 0 && rec == 0
                                   && !bus_off && !err_passive && !arb_lost && !tx_fast && !rx_fast && !pexc)
  `SVA_INV(a_txd_model, txd == d)
  `SVA_INV(a_rate_model, tx_fast == (mdph && tx_now) && rx_fast == (mdph && !tx_now))
  `SVA_INV(a_tx_ready_model, tx_ready == !pend)
  `SVA_INV(a_tx_done_model, tx_done == m_txdone && tx_aborted == m_txab && tx_rejected == m_txrej)
  `SVA_INV(a_rx_valid_model, rx_valid == m_rxv)
  `SVA_IMP(a_rx_frame_model, rx_valid, {rx_xl, rx_id, rx_ide, rx_rtr, rx_dlc, rx_sdt, rx_sec, rx_vcid, rx_af,
                                        rx_trunc} == m_rxh)
  `SVA_INV(a_rx_bytes_model, rdata_ok())
  `SVA_INV(a_arb_lost_model, arb_lost == m_arb)
  `SVA_INV(a_error_pulses_model, {err_bit, err_stuff, err_crc, err_form, err_ack} == {m_eb, m_es, m_ec, m_ef, m_ea})
  `SVA_INV(a_pexc_model, pexc == m_px)
  `SVA_INV(a_counters_model, int'(tec) == mtec && int'(rec) == mrec)
  `SVA_INV(a_state_model, bus_off == (st == S_OFF) && err_passive == m_passive)
  `SVA_IMP(a_bus_off_recessive, bus_off && $past(bus_off), txd)

  // ---------------- functional coverage ----------------
  // length class of a frame: 0 one byte, 1 2..8, 2 9..64, 3 more, 4 the
  // whole buffer, 5 longer than the buffer
  function automatic int lcls(input int nb);
    return nb > MAX_BYTES ? 5 : nb == MAX_BYTES ? 4 : nb == 1 ? 0 : nb <= 8 ? 1 : nb <= 64 ? 2 : 3;
  endfunction
  function automatic int vcls(input logic [31:0] v, input logic [31:0] max);
    return v == 0 ? 0 : v == max ? 1 : 2;
  endfunction
  int c_rl, c_tl, c_rk, c_tk, c_sdt, c_vcid, c_af, c_sec, c_rid;
  always @(posedge clk) begin
    c_rl  = rst_n && rx_valid && rx_xl ? lcls(int'(rx_dlc) + 1) : -1;
    c_tl  = rst_n && accept_tx && tx_xl ? lcls(int'(tx_dlc) + 1) : -1;
    c_rk  = rst_n && rx_valid ? (rx_xl ? 4 : {rx_ide, rx_rtr}) : -1;
    c_tk  = rst_n && accept_tx ? (tx_xl ? 4 : {tx_ide, tx_rtr}) : -1;
    c_sdt = rst_n && rx_valid && rx_xl ? vcls(32'(rx_sdt), 32'hFF) : -1;
    c_vcid = rst_n && rx_valid && rx_xl ? vcls(32'(rx_vcid), 32'hFF) : -1;
    c_af  = rst_n && rx_valid && rx_xl ? vcls(rx_af, 32'hFFFF_FFFF) : -1;
    c_sec = rst_n && rx_valid && rx_xl ? int'(rx_sec) : -1;
    c_rid = rst_n && rx_valid ? vcls(32'(rx_id), rx_ide ? 32'h1FFF_FFFF : 32'h7FF) : -1;
  end
  covergroup cg_can_xl @(negedge clk);
    option.per_instance = 1;
    cp_rx_len: coverpoint c_rl iff (c_rl >= 0)
      { bins one = {0}; bins few = {1}; bins mid = {2}; bins big = {3}; bins full = {4}; }
    cp_tx_len: coverpoint c_tl iff (c_tl >= 0)
      { bins one = {0}; bins few = {1}; bins mid = {2}; bins big = {3}; bins full = {4}; }
    cp_rx_kind: coverpoint c_rk iff (c_rk >= 0)
      { bins std = {0}; bins std_rtr = {1}; bins ext = {2}; bins ext_rtr = {3}; bins xl = {4}; }
    cp_tx_kind: coverpoint c_tk iff (c_tk >= 0)
      { bins std = {0}; bins std_rtr = {1}; bins ext = {2}; bins ext_rtr = {3}; bins xl = {4}; }
    cp_sdt: coverpoint c_sdt iff (c_sdt >= 0) { bins zero = {0}; bins max_ = {1}; bins other = {2}; }
    cp_vcid: coverpoint c_vcid iff (c_vcid >= 0) { bins zero = {0}; bins max_ = {1}; bins other = {2}; }
    cp_af: coverpoint c_af iff (c_af >= 0) { bins zero = {0}; bins max_ = {1}; bins other = {2}; }
    cp_sec: coverpoint c_sec iff (c_sec >= 0) { bins off = {0}; bins on = {1}; }
    cp_rid: coverpoint c_rid iff (c_rid >= 0) { bins zero = {0}; bins max_ = {1}; bins other = {2}; }
    x_rid: cross cp_rx_kind, cp_rid;
    cp_dsc: coverpoint v_dsc iff (rst_n && v_dsc >= 0) { bins n0 = {0}; bins n1 = {1}; bins n2 = {2}; bins n3 = {3}; }
  endgroup
  cg_can_xl u_cg_can_xl = new;

  `FC(xl_frame_sent, tx_done && bx)
  `FC(cc_frame_sent, tx_done && !bx)
  `FC(xl_frame_received, rx_valid && rx_xl)
  `FC(xl_frame_truncated, rx_valid && rx_trunc)
  `FC(frame_refused, tx_rejected)
  `FC(frame_filtered_out, v_filtered)
  `FC(ack_given, v_ack_given)
  `FC(ack_given_xl, v_ack_given && xl)
  `FC(arb_lost_in_id, v_arb_at[0])
  `FC(arb_lost_at_rtr_or_srr, v_arb_at[1])
  `FC(arb_lost_at_ide, v_arb_at[2])
  `FC(arb_lost_in_ext_id_or_rtr, v_arb_at[3])
  `FC(arb_lost_by_xl, arb_lost && bx)
  `FC(join_at_third_ifs_bit, v_join)
  `FC(join_at_idle_sof, v_join_idle)
  `FC(sof_during_suspend, v_susp_sof)
  `FC(suspend_completed, st == S_SUSP && smp && q2 && cnt == 7)
  `FC(stuff_bit_after_crc, v_stuff_after_crc)
  `FC(stuff_bit_before_fdf, v_dyn_before_fdf)
  `FC(fixed_stuff_before_last_fcrc_bit, v_fix_last)
  `FC(tx_data_phase, tx_fast)
  `FC(rx_data_phase, rx_fast)
  `FC(error_bit_tx, err_bit)
  `FC(error_bit_data_phase, err_bit && v_dp_err)
  `FC(error_stuff_tx, err_stuff && tx_now)
  `FC(error_stuff_rx, err_stuff && !tx_now)
  `FC(error_stuff_fixed, v_fix_stuff_err)
  `FC(error_in_data_phase_rx, v_dp_err && !tx_now)
  `FC(error_crc_cc, err_crc && !xl)
  `FC(error_crc_sbc, v_sbc_bad)
  `FC(error_crc_pcrc, v_pcrc_bad)
  `FC(error_crc_fcrc, v_fcrc_bad)
  `FC(error_form_xl_fixed_bit, v_xl_form)
  `FC(error_form_fcp, v_fcp_form)
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
  `FC(protocol_exception_fd, v_px_fd)
  `FC(protocol_exception_r1, v_px_r1)
  `FC(protocol_exception_ended, v_px_end)
  `FC(abort_idle, v_abort_idle)
  `FC(abort_after_arbitration_loss, v_abort_after_lost)
  `FC(abort_after_error, v_abort_after_err)
  `FC(abort_too_late, tx_done && $past(abreq))
  `FC(hard_sync, hard)
  `FC(resync_late, rs_late && !mdph)
  `FC(resync_late_beyond_sjw, rs_late && PN > SJ * BP)
  `FC(resync_early_end_bit, rs_end)
  `FC(resync_early_beyond_sjw, rs_skip)
  `FC(resync_in_data_phase, rs && mdph)
  `FC(min_data_bit_time, smp && mdph && cfg_dbrp == 0 && NT * BP == 6)
  `FC_RST(reset_mid_frame, rst_n && st == S_FRAME ##1 !rst_n)
endmodule

bind CAN_XL_top CAN_XL_sva #(.MAX_BYTES(MAX_BYTES), .FS(FS)) u_sva (.*);
