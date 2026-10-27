// SPDX-License-Identifier: Apache-2.0
/*verilator coverage_off*/
// USB-PD sink: a cycle-level model fed only by the CC wire predicts every
// output on every clock. Receiver: BMC toggle decode, K-code hunt with the
// 5-clock comma lock, then the frame collected as a bit list and checked
// at EOP (CRC-32 residue over header, objects and CRC). Transmitter: the
// frame built as a bit list at start and BMC-shifted out, then the gap.
// Policy: capabilities -> Request (PDO choice) -> GoodCRC (MessageID,
// timeout, retries) -> Accept / Reject -> PS_RDY, HardReset, irq level.
`include "cov_macros.svh"
module USB_PD_sva #(
  parameter int GCRC_TO = 200,
  parameter int N_RETRY = 2
)(
  input logic clk, rst_n, cc_rxd, cc_txd, cc_tx_en, vbus_ok, irq
);
  `COV_CLOCKING(clk, !rst_n)

  localparam logic [4:0] K_SYNC1 = 5'b11000, K_SYNC2 = 5'b10001, K_EOP = 5'b01101;
  localparam int WCAPS = 0, WGCRC = 1, WACC = 2, WPSRDY = 3, CONTRACT = 4;

  function automatic logic [31:0] crc_b(input logic [31:0] c, input logic b);
    return (c >> 1) ^ ((c[0] ^ b) ? 32'hEDB8_8320 : 32'h0);
  endfunction

  // receiver
  logic        prev, hunt, sop_s, rst_s;
  logic [3:0]  w4;
  int          skip, nb, need;
  logic        fb [0:127];
  logic [15:0] h;
  logic [9:0]  o0;
  logic [19:0] o1;
  logic [2:0]  r_id;
  logic [1:0]  r_nobj;
  logic [4:0]  r_mt;
  logic        p_done, p_err, p_hrst;
  // transmitter
  logic        t_busy, t_gap, m_en, m_line, st_gc, st_req;
  logic        tbits [0:127];
  int          t_n, t_k, t_g;
  // policy
  int          pe, tmr, retry;
  logic        pend_gc, pend_req, m_vbus, m_irq, r9v;
  logic [2:0]  gc_id, k_id;
  logic [9:0]  rcur;
  // coverage events
  logic v_9v, v_5v_one, v_5v_other, v_reneg, v_reject, v_wrong_id, v_retry, v_giveup,
        v_crc, v_eop, v_nobj, v_hrst, v_hrst_contract, v_hrst_gcrc, v_wrap, v_src_gc,
        v_other, v_ack_retry;
  // per-step copies for the covergroup (set at posedge, sampled at negedge)
  logic        c_dn, c_tv, c_tg, c_av;
  int          c_k, c_pe, c_ar;
  logic [2:0]  c_id, c_tid;
  logic [9:0]  c_rc;

  always @(posedge clk or negedge rst_n) begin
    logic        b, o_done, o_err, o_hrst, o_busy, o_stgc, o_streq, gcrc, caps, ctrl;
    logic [4:0]  win;
    logic [31:0] c, rdo;
    logic [15:0] th;
    int          o_pe, o_tmr, n;
    logic        o_pgc, o_preq, o_r9v;
    logic [2:0]  o_gcid, o_kid;
    logic [9:0]  o_rcur;
    if (!rst_n) begin
      prev = 0; hunt = 1; sop_s = 0; rst_s = 0; w4 = 0; skip = 0; nb = 0; need = 0;
      h = 0; o0 = 0; o1 = 0; r_id = 0; r_nobj = 0; r_mt = 0;
      {p_done, p_err, p_hrst} = '0;
      t_busy = 0; t_gap = 0; m_en = 0; m_line = 1; st_gc = 0; st_req = 0;
      t_n = 0; t_k = 0; t_g = 0;
      pe = WCAPS; tmr = 0; retry = 0; pend_gc = 0; pend_req = 0; m_vbus = 0; m_irq = 0;
      r9v = 0; gc_id = 0; k_id = 0; rcur = 0;
      {v_9v, v_5v_one, v_5v_other, v_reneg, v_reject, v_wrong_id, v_retry, v_giveup,
       v_crc, v_eop, v_nobj, v_hrst, v_hrst_contract, v_hrst_gcrc, v_wrap, v_src_gc,
       v_other, v_ack_retry} = '0;
      {c_dn, c_tv, c_tg, c_av} = '0; c_k = 0; c_pe = 0; c_ar = 0; c_id = 0; c_tid = 0; c_rc = 0;
    end else begin
      {v_9v, v_5v_one, v_5v_other, v_reneg, v_reject, v_wrong_id, v_retry, v_giveup,
       v_crc, v_eop, v_nobj, v_hrst, v_hrst_contract, v_hrst_gcrc, v_wrap, v_src_gc,
       v_other, v_ack_retry} = '0;
      o_done = p_done; o_err = p_err; o_hrst = p_hrst; o_busy = t_busy || t_gap;
      o_stgc = st_gc; o_streq = st_req; o_pe = pe; o_tmr = tmr;
      o_pgc = pend_gc; o_preq = pend_req; o_gcid = gc_id; o_kid = k_id; o_r9v = r9v;
      o_rcur = rcur;
      {p_done, p_err, p_hrst} = '0;

      // ---------------- policy ----------------
      ctrl = (r_nobj == 0);
      gcrc = o_done && ctrl && r_mt == 5'h01;
      caps = o_done && !ctrl && r_mt == 5'h01;
      {c_tv, c_av} = '0;
      c_dn = o_done && !o_hrst; c_pe = o_pe; c_id = r_id;
      c_k = !ctrl ? (r_mt != 5'h01 ? 7 : (r_nobj == 1 ? 5 : 6)) :
            (r_mt == 5'h01 ? 0 : (r_mt == 5'h03 ? 1 : (r_mt == 5'h04 ? 2 : (r_mt == 5'h06 ? 3 : 4))));
      if (o_hrst) begin
        v_hrst = 1;
        if (o_pe == CONTRACT) v_hrst_contract = 1;
        if (o_pe == WGCRC) v_hrst_gcrc = 1;
        pe = WCAPS; m_vbus = 0; pend_gc = 0; pend_req = 0; k_id = 0; m_irq = 0;
      end else begin
        if (o_stgc) pend_gc = 0;
        if (o_streq) pend_req = 0;
        if (o_err) m_irq = 1; else if (o_done) m_irq = 0;
        if (o_done && !gcrc) begin pend_gc = 1; gc_id = r_id; end
        if (gcrc && o_pe != WGCRC) v_src_gc = 1;
        if (o_done && !ctrl && r_mt != 5'h01) v_other = 1;
        if (caps && (o_pe == WCAPS || o_pe == CONTRACT)) begin
          r9v = (r_nobj == 2) && o1[19:10] == 10'd180;
          rcur = r9v ? o1[9:0] : o0;
          if (r9v) v_9v = 1; else if (r_nobj == 1) v_5v_one = 1; else v_5v_other = 1;
          if (o_pe == CONTRACT) v_reneg = 1;
          pend_req = 1; m_vbus = 0; tmr = 0; retry = 0; pe = WGCRC;
        end
        case (o_pe)
          WGCRC: begin
            if (pend_req || o_busy) tmr = 0; else tmr++;
            if (gcrc) begin
              if (r_id == k_id) begin
                if (k_id == 7) v_wrap = 1;
                if (retry != 0) v_ack_retry = 1;
                c_av = 1; c_ar = retry;
                k_id++; pe = WACC;
              end else begin m_irq = 1; v_wrong_id = 1; end
            end else if (o_tmr == GCRC_TO) begin
              tmr = 0;
              if (retry == N_RETRY) begin m_irq = 1; pe = WCAPS; v_giveup = 1; end
              else begin retry++; pend_req = 1; v_retry = 1; end
            end
          end
          WACC: begin
            if (o_done && ctrl && r_mt == 5'h03) pe = WPSRDY;
            if (o_done && ctrl && r_mt == 5'h04) begin pe = WCAPS; v_reject = 1; end
          end
          WPSRDY:
            if (o_done && ctrl && r_mt == 5'h06) begin m_vbus = 1; pe = CONTRACT; end
          default: ;
        endcase
      end

      // ---------------- receiver ----------------
      b = cc_rxd ^ prev;
      prev = cc_rxd;
      if (o_busy) begin
        hunt = 1; w4 = 0; skip = 0; sop_s = 0; rst_s = 0;
      end else if (hunt) begin
        win = {w4, b};
        w4 = win[3:0];
        if (skip != 0) skip--;
        else begin
          if (win == 5'b11000) begin
            sop_s = 1; rst_s = 0; skip = 4;
          end else if (win == 5'b10001 && sop_s) begin
            sop_s = 0; rst_s = 0; hunt = 0; nb = 0; need = 16; w4 = 0;
          end else if (win == 5'b00111) begin
            sop_s = 0; rst_s = 1; skip = 4;
          end else if (win == 5'b11001 && rst_s) begin
            sop_s = 0; rst_s = 0; p_hrst = 1; skip = 4;
          end else begin
            sop_s = 0; rst_s = 0;
          end
        end
      end else begin
        fb[nb] = b; nb++;
        if (nb == 16) begin
          for (int i = 0; i < 16; i++) h[i] = fb[i];
          if (h[14:12] > 2) begin p_err = 1; hunt = 1; w4 = 0; v_nobj = 1; end
          else begin
            r_nobj = h[13:12]; r_id = h[11:9]; r_mt = h[4:0];
            need = 16 + 32 * h[13:12] + 32 + 5;
          end
        end else if (nb == need) begin
          for (int i = 0; i < 10; i++) if (r_nobj >= 1) o0[i] = fb[16 + i];
          for (int i = 0; i < 20; i++) if (r_nobj == 2) o1[i] = fb[48 + i];
          c = 32'hFFFF_FFFF;
          for (int i = 0; i < need - 5; i++) c = crc_b(c, fb[i]);
          for (int i = 0; i < 5; i++) win[4 - i] = fb[need - 5 + i];
          if (win == 5'b01101 && c == 32'hDEBB_20E3) p_done = 1;
          else begin
            p_err = 1;
            if (win != 5'b01101) v_eop = 1; else v_crc = 1;
          end
          hunt = 1; w4 = 0;
        end
      end

      // ---------------- transmitter ----------------
      st_gc = 0; st_req = 0;
      if (t_gap) begin
        m_en = 0;
        if (t_g == 2) t_gap = 0; else t_g++;
      end else if (t_busy) begin
        m_line = m_line ^ tbits[t_k];
        t_k++;
        if (t_k == t_n) begin t_busy = 0; t_gap = 1; t_g = 0; end
      end else if (o_pgc || o_preq) begin
        th = o_pgc ? {1'b0, 3'd0, o_gcid, 1'b0, 2'b10, 1'b0, 5'h01}
                   : {1'b0, 3'd1, o_kid, 1'b0, 2'b10, 1'b0, 5'h02};
        rdo = {1'b0, o_r9v ? 3'd2 : 3'd1, 8'h00, o_rcur, o_rcur};
        n = 0;
        for (int i = 0; i < 16; i++) begin tbits[n] = i[0]; n++; end
        for (int s = 0; s < 4; s++)
          for (int i = 4; i >= 0; i--) begin
            tbits[n] = (s == 3) ? K_SYNC2[i] : K_SYNC1[i]; n++;
          end
        c = 32'hFFFF_FFFF;
        for (int i = 0; i < 16; i++) begin tbits[n] = th[i]; c = crc_b(c, th[i]); n++; end
        if (!o_pgc)
          for (int i = 0; i < 32; i++) begin tbits[n] = rdo[i]; c = crc_b(c, rdo[i]); n++; end
        c = ~c;
        for (int i = 0; i < 32; i++) begin tbits[n] = c[i]; n++; end
        for (int i = 4; i >= 0; i--) begin tbits[n] = K_EOP[i]; n++; end
        t_n = n; t_k = 0; t_busy = 1; m_en = 1; m_line = 1;
        st_gc = o_pgc; st_req = !o_pgc;
        c_tv = 1; c_tg = o_pgc; c_tid = o_pgc ? o_gcid : o_kid; c_rc = o_rcur;
      end
    end
  end

  // ---------------- assertions ----------------
  `SVA_RST(a_reset_outputs, !rst_n, !cc_tx_en && cc_txd && !vbus_ok && !irq)
  `SVA_INV(a_cc_tx_en, cc_tx_en == m_en)
  `SVA_IMP(a_cc_txd, cc_tx_en, cc_txd == m_line)
  `SVA_INV(a_vbus_ok, vbus_ok == m_vbus)
  `SVA_INV(a_irq, irq == m_irq)

  // ---------------- functional coverage ----------------
  // received message kind, x the policy state where it matters, its
  // MessageID; GoodCRC / Request sent x MessageID; requested current
  // class; Request acknowledged first time or after a retry
  covergroup cg_pd @(negedge clk);
    option.per_instance = 1;
    cp_rx: coverpoint c_k iff (rst_n && c_dn)
      { bins goodcrc = {0}; bins accept = {1}; bins reject = {2}; bins ps_rdy = {3}; bins other_ctrl = {4};
        bins caps_1pdo = {5}; bins caps_2pdo = {6}; bins other_data = {7}; }
    cp_rx_pe: coverpoint c_k * 8 + c_pe iff (rst_n && c_dn && c_k inside {[0:3], 5, 6})
      { bins gc_in_wait_gcrc = {0 * 8 + WGCRC}; bins gc_in_contract = {0 * 8 + CONTRACT};
        bins accept_in_wait_acc = {1 * 8 + WACC}; bins accept_in_contract = {1 * 8 + CONTRACT};
        bins reject_in_wait_acc = {2 * 8 + WACC}; bins psrdy_in_wait_psrdy = {3 * 8 + WPSRDY};
        bins psrdy_in_wait_caps = {3 * 8 + WCAPS};
        bins caps_in_wait_caps = {5 * 8 + WCAPS, 6 * 8 + WCAPS}; bins caps_in_contract = {5 * 8 + CONTRACT, 6 * 8 + CONTRACT}; }
    cp_rx_id: coverpoint c_id iff (rst_n && c_dn);
    cp_tx: coverpoint {c_tg, c_tid} iff (rst_n && c_tv) { bins req[] = {[0:7]}; bins goodcrc[] = {[8:15]}; }
    cp_cur: coverpoint c_rc iff (rst_n && c_tv && !c_tg)
      { bins zero = {0}; bins max = {10'h3FF}; bins alt = {10'h155, 10'h2AA}; bins other = {[1:10'h154], [10'h156:10'h2A9], [10'h2AB:10'h3FE]}; }
    cp_ack: coverpoint c_ar iff (rst_n && c_av) { bins first_try = {0}; bins after_retry = {[1:N_RETRY]}; }
  endgroup
  cg_pd u_cg_pd = new;

  `FC(request_9v, v_9v)
  `FC(request_5v_single_pdo, v_5v_one)
  `FC(request_5v_second_pdo_not_9v, v_5v_other)
  `FC(renegotiate_from_contract, v_reneg)
  `FC(reject, v_reject)
  `FC(goodcrc_wrong_id, v_wrong_id)
  `FC(request_retry, v_retry)
  `FC(request_give_up, v_giveup)
  `FC(retry_acknowledged, v_ack_retry)
  `FC(message_id_wraps, v_wrap)
  `FC(bad_crc, v_crc)
  `FC(bad_eop, v_eop)
  `FC(too_many_objects, v_nobj)
  `FC(hard_reset, v_hrst)
  `FC(hard_reset_in_contract, v_hrst_contract)
  `FC(hard_reset_waiting_goodcrc, v_hrst_gcrc)
  `FC(source_goodcrc_ignored, v_src_gc)
  `FC(other_data_message, v_other)
  `FC(contract_up, $rose(vbus_ok))
  `FC_RST(reset_during_negotiation, rst_n && pe != WCAPS && pe != CONTRACT ##1 !rst_n)
endmodule

bind USB_PD_top USB_PD_sva #(.GCRC_TO(GCRC_TO), .N_RETRY(N_RETRY)) u_sva (.*);
