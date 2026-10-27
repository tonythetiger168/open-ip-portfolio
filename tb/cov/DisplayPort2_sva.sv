// SPDX-License-Identifier: Apache-2.0
/*verilator coverage_off*/
// DisplayPort source: a cycle-level model fed only by the pins (HPD and the
// AUX line from the sink) predicts every output on every clock. The AUX
// side expands each request into its chip list and plays it, then times
// the reply and decodes it pair by pair; the link-training model walks the
// op sequence with its retry budget; the main-link model builds every
// symbol of the active pattern and encodes it with the standard 8b/10b
// tables (not the DUT's encoder) before serialising it.
`include "cov_macros.svh"
module DisplayPort2_sva (
  input logic        clk, rst_n, lane_p, lane_valid, link_trained, train_fail,
  input logic        aux_tx_p, aux_tx_en, aux_rx_p, sink_present, edid_valid, irq,
  input logic [63:0] edid
);
  `COV_CLOCKING(clk, !rst_n)

  // link-training steps
  localparam int L_IDLE = 0, L_RATE = 1, L_LANE = 2, L_CRSET = 3, L_CRWAIT = 4, L_CRPOLL = 5,
                 L_TPSSET = 6, L_TPSWAIT = 7, L_TPSPOLL = 8, L_EDIDW = 9, L_EDIDR = 10,
                 L_OFF = 11, L_VIDEO = 12, L_FAIL = 13;
  // AUX model modes
  localparam int M_IDLE = 0, M_TX = 1, M_WAIT = 2, M_RX = 3, M_STOP0 = 4, M_STOP1 = 5;

  // ------------------------------------------------------- 8b/10b (tables)
  function automatic logic [11:0] t6(input logic [4:0] x);   // {RD-, RD+}
    case (x)
      5'd0:  t6 = {6'b100111, 6'b011000};  5'd1:  t6 = {6'b011101, 6'b100010};
      5'd2:  t6 = {6'b101101, 6'b010010};  5'd3:  t6 = {6'b110001, 6'b110001};
      5'd4:  t6 = {6'b110101, 6'b001010};  5'd5:  t6 = {6'b101001, 6'b101001};
      5'd6:  t6 = {6'b011001, 6'b011001};  5'd7:  t6 = {6'b111000, 6'b000111};
      5'd8:  t6 = {6'b111001, 6'b000110};  5'd9:  t6 = {6'b100101, 6'b100101};
      5'd10: t6 = {6'b010101, 6'b010101};  5'd11: t6 = {6'b110100, 6'b110100};
      5'd12: t6 = {6'b001101, 6'b001101};  5'd13: t6 = {6'b101100, 6'b101100};
      5'd14: t6 = {6'b011100, 6'b011100};  5'd15: t6 = {6'b010111, 6'b101000};
      5'd16: t6 = {6'b011011, 6'b100100};  5'd17: t6 = {6'b100011, 6'b100011};
      5'd18: t6 = {6'b010011, 6'b010011};  5'd19: t6 = {6'b110010, 6'b110010};
      5'd20: t6 = {6'b001011, 6'b001011};  5'd21: t6 = {6'b101010, 6'b101010};
      5'd22: t6 = {6'b011010, 6'b011010};  5'd23: t6 = {6'b111010, 6'b000101};
      5'd24: t6 = {6'b110011, 6'b001100};  5'd25: t6 = {6'b100110, 6'b100110};
      5'd26: t6 = {6'b010110, 6'b010110};  5'd27: t6 = {6'b110110, 6'b001001};
      5'd28: t6 = {6'b001110, 6'b001110};  5'd29: t6 = {6'b101110, 6'b010001};
      5'd30: t6 = {6'b011110, 6'b100001};  default: t6 = {6'b101011, 6'b010100};
    endcase
  endfunction
  function automatic logic [7:0] t4(input logic [2:0] y);
    case (y)
      3'd0: t4 = {4'b1011, 4'b0100};  3'd1: t4 = {4'b1001, 4'b1001};
      3'd2: t4 = {4'b0101, 4'b0101};  3'd3: t4 = {4'b1100, 4'b0011};
      3'd4: t4 = {4'b1101, 4'b0010};  3'd5: t4 = {4'b1010, 4'b1010};
      3'd6: t4 = {4'b0110, 4'b0110};  default: t4 = {4'b1110, 4'b0001};
    endcase
  endfunction
  function automatic logic [7:0] tk28(input logic [2:0] y);
    case (y)
      3'd0: tk28 = {4'b0100, 4'b1011};  3'd1: tk28 = {4'b1001, 4'b0110};
      3'd2: tk28 = {4'b0101, 4'b1010};  3'd3: tk28 = {4'b0011, 4'b1100};
      3'd4: tk28 = {4'b0010, 4'b1101};  3'd5: tk28 = {4'b1010, 4'b0101};
      3'd6: tk28 = {4'b0110, 4'b1001};  default: tk28 = {4'b1000, 4'b0111};
    endcase
  endfunction
  function automatic int ones(input logic [9:0] v);
    ones = 0;
    for (int i = 0; i < 10; i++) ones += v[i];
  endfunction
  function automatic logic [10:0] enc(input logic [7:0] d, input bit k, input bit rd);
    logic [5:0] c6;
    logic [3:0] c4;
    logic [11:0] p6;
    logic [7:0] p4;
    bit r1;
    if (k && d[4:0] == 5'd28) begin
      c6 = rd ? 6'b110000 : 6'b001111;
      p4 = tk28(d[7:5]);
      c4 = rd ? p4[3:0] : p4[7:4];
    end else begin
      p6 = t6(d[4:0]);
      c6 = rd ? p6[5:0] : p6[11:6];
      r1 = (ones({4'd0, c6}) == 3) ? rd : !rd;
      if (d[7:5] == 3'd7 && (k || (!r1 && (d[4:0] == 17 || d[4:0] == 18 || d[4:0] == 20)) ||
                             (r1 && (d[4:0] == 11 || d[4:0] == 13 || d[4:0] == 14))))
        c4 = r1 ? 4'b1000 : 4'b0111;
      else begin
        p4 = t4(d[7:5]);
        c4 = r1 ? p4[3:0] : p4[7:4];
      end
    end
    enc = {(ones({c6, c4}) == 5) ? rd : !rd, c6, c4};
  endfunction

  // ------------------------------------------------------- AUX requests
  // {byte0..byte4, number of bytes} of the op that step s waits for
  function automatic logic [42:0] req(input int s);
    case (s)
      L_RATE:   req = {8'h80, 8'h00, 8'h00, 8'h01, 8'h14, 3'd5};
      L_LANE:   req = {8'h80, 8'h00, 8'h01, 8'h01, 8'h01, 3'd5};
      L_CRSET:  req = {8'h80, 8'h00, 8'h02, 8'h01, 8'h21, 3'd5};
      L_TPSSET: req = {8'h80, 8'h00, 8'h02, 8'h01, 8'h22, 3'd5};
      L_OFF:    req = {8'h80, 8'h00, 8'h02, 8'h01, 8'h00, 3'd5};
      L_EDIDW:  req = {8'h00, 8'h50, 8'h00, 8'h00, 8'h00, 3'd4};
      L_EDIDR:  req = {8'h10, 8'h50, 8'h00, 8'h08, 8'h00, 3'd4};
      default:  req = {8'h90, 8'h00, 8'h03, 8'h01, 8'h00, 3'd4};   // status polls
    endcase
  endfunction
  function automatic int rlen(input int s);
    rlen = s == L_EDIDR ? 8 : (s == L_CRPOLL || s == L_TPSPOLL) ? 1 : 0;
  endfunction

  // ------------------------------------------------------- AUX model
  int          am, ai, an, wk, nb;
  logic        ch [0:114];             // request chips (SYNC, start, bytes, STOP0)
  logic        m_en, m_p, m_done, m_err, c0, half, nak;
  logic [7:0]  sb;
  logic [63:0] rdat;
  bit          ost;                    // op start (from the training model)
  int          ls;
  bit v_tmo, v_viol, v_sync1, v_start0, v_nak, v_stop0, v_stop1, v_hdrlo, v_last_wait,
      v_viol_data, v_drop_tx, v_drop_rx;

  always_ff @(posedge clk or negedge rst_n)
    if (!rst_n) begin
      am <= M_IDLE; ai <= 0; an <= 0; wk <= 0; nb <= 0;
      m_en <= 0; m_p <= 1; m_done <= 0; m_err <= 0; c0 <= 0; half <= 0; nak <= 0;
      sb <= 0; rdat <= 0;
    end else begin : aux
      logic [42:0] r;
      logic [7:0] by;
      int n;
      bit e;
      {v_tmo, v_viol, v_sync1, v_start0, v_nak, v_stop0, v_stop1, v_hdrlo, v_last_wait,
       v_viol_data, v_drop_tx, v_drop_rx} = '0;
      if (!sink_present) begin
        v_drop_tx = am == M_TX;
        v_drop_rx = am >= M_WAIT;
        am <= M_IDLE; m_en <= 0; m_p <= 1; m_done <= 0;
      end else begin
        m_done <= 0;
        e = 0;
        case (am)
          M_IDLE:
            if (ost) begin
              r = req(ls);
              n = 0;
              for (int i = 0; i < 16; i++) begin ch[n] = 0; ch[n+1] = 1; n += 2; end
              ch[n] = 1; ch[n+1] = 0; n += 2;
              for (int b = 0; b < int'(r[2:0]); b++) begin
                by = r[42 - 8*b -: 8];
                for (int i = 7; i >= 0; i--) begin ch[n] = by[i]; ch[n+1] = !by[i]; n += 2; end
              end
              ch[n] = 1; n++;
              an <= n; ai <= 1; m_en <= 1; m_p <= ch[0]; am <= M_TX;
            end
          M_TX:
            if (ai < an) begin m_p <= ch[ai]; ai <= ai + 1; end
            else begin m_en <= 0; wk <= 0; am <= M_WAIT; end
          M_WAIT:
            if (wk == 200) begin e = 1; v_tmo = 1; end
            else begin
              wk <= wk + 1;
              if (!aux_rx_p) begin am <= M_RX; half <= 1; c0 <= 0; nb <= 0; v_last_wait = wk == 199; end
            end
          M_RX:
            if (!half) begin c0 <= aux_rx_p; half <= 1; end
            else if (aux_rx_p == c0) begin e = 1; v_viol = 1; v_viol_data = nb >= 17; end
            else if (nb < 16 && c0) begin e = 1; v_sync1 = 1; end
            else if (nb == 16 && !c0) begin e = 1; v_start0 = 1; end
            else begin
              half <= 0;
              nb <= nb + 1;
              if (nb >= 17) begin
                by = {sb[6:0], c0};
                sb <= by;
                if ((nb - 17) % 8 == 7) begin
                  if (nb == 24) begin                        // reply header
                    nak <= by[7:4] != 0;
                    v_nak = by[7:4] != 0;
                    v_hdrlo = by[7:4] == 0 && by[3:0] != 0;
                    if (by[7:4] != 0 || rlen(ls) == 0) am <= M_STOP0;
                  end else begin
                    rdat[8*((nb - 17) / 8 - 1) +: 8] <= by;
                    if ((nb - 17) / 8 == rlen(ls)) am <= M_STOP0;
                  end
                end
              end
            end
          M_STOP0:
            if (aux_rx_p) am <= M_STOP1;
            else begin e = 1; v_stop0 = 1; end
          default: begin
            m_done <= 1; m_err <= !aux_rx_p || nak; am <= M_IDLE;
            v_stop1 = !aux_rx_p;
          end
        endcase
        if (e) begin m_done <= 1; m_err <= 1; am <= M_IDLE; end
      end
    end

  // ------------------------------------------------------- training model
  bit          act, tf, prst, edv;
  int          pt, rty;
  logic [63:0] ed;
  int          sc;                     // symbols since pattern start (sat. 32)
  bit v_poll_nd_cr, v_poll_nd_eq, v_retry3_ok, v_retry, v_drop_video, v_drop_fail, v_drop_wait;

  always_ff @(posedge clk or negedge rst_n)
    if (!rst_n) begin
      ls <= L_IDLE; act <= 0; tf <= 0; pt <= 0; prst <= 0; ost <= 0; rty <= 0; ed <= 0; edv <= 0;
    end else begin : lt
      {v_poll_nd_cr, v_poll_nd_eq, v_retry3_ok, v_retry, v_drop_video, v_drop_fail, v_drop_wait} = '0;
      if (!sink_present) begin
        v_drop_video = ls == L_VIDEO;
        v_drop_fail = ls == L_FAIL;
        v_drop_wait = ls == L_CRWAIT || ls == L_TPSWAIT;
        ls <= L_IDLE; act <= 0; tf <= 0; pt <= 0; prst <= 0; ost <= 0; edv <= 0;
      end else begin
        ost <= 0; prst <= 0;
        if (ls == L_IDLE) begin
          act <= 1; rty <= 0; ost <= 1; ls <= L_RATE;
        end else if (ls == L_CRWAIT || ls == L_TPSWAIT) begin
          if (sc >= 32 && !prst) begin ost <= 1; ls <= ls + 1; end
        end else if (ls == L_VIDEO) begin
        end else if (ls == L_FAIL) begin
          tf <= 1; pt <= 0;
        end else if (m_done) begin
          bit ok;
          ok = !m_err && (ls == L_CRPOLL ? rdat[0] : ls == L_TPSPOLL ? rdat[1] : 1'b1);
          v_poll_nd_cr = ls == L_CRPOLL && !m_err && !rdat[0];
          v_poll_nd_eq = ls == L_TPSPOLL && !m_err && !rdat[1];
          v_retry3_ok = ok && rty == 3;
          v_retry = !ok && rty < 3;
          if (ok) begin
            rty <= 0;
            case (ls)
              L_CRSET:  begin pt <= 1; prst <= 1; ls <= L_CRWAIT; end
              L_TPSSET: begin pt <= 2; prst <= 1; ls <= L_TPSWAIT; end
              L_OFF:    begin pt <= 3; prst <= 1; ls <= L_VIDEO; end
              L_CRPOLL: begin ost <= 1; ls <= L_TPSSET; end
              L_TPSPOLL: begin ost <= 1; ls <= L_EDIDW; end
              L_EDIDR:  begin ed <= rdat; edv <= 1; ost <= 1; ls <= L_OFF; end
              default:  begin ost <= 1; ls <= ls + 1; end   // RATE, LANE, EDIDW
            endcase
          end else if (rty == 3) ls <= L_FAIL;
          else begin
            rty <= rty + 1;
            if (ls == L_CRPOLL || ls == L_TPSPOLL) begin prst <= 1; ls <= ls - 1; end
            else ost <= 1;
          end
        end
      end
    end

  // ------------------------------------------------------- main-link model
  int          bc, tc, fp;
  logic [7:0]  fcnt;
  logic [8:0]  sh;
  logic        m_lp, m_lv, rdm;
  bit v_k28_rdp, v_tps;
  logic        c_sv;                   // a main-link symbol was picked (for the covergroup)
  logic [8:0]  c_s;

  function automatic logic [8:0] sym(input int p, input int t, input int v, input logic [7:0] f);
    // {k, data}
    if (p == 1) sym = {1'b0, 8'h4A};
    else if (p == 2) sym = t == 0 ? {1'b1, 8'hBC} : {1'b0, 8'h4A};
    else if (p == 3) begin
      if (v == 0)       sym = {1'b1, 8'hFB};
      else if (v <= 16) sym = {1'b0, 8'(f + v - 1)};
      else if (v == 17) sym = {1'b1, 8'hBC};
      else if (v == 18) sym = {1'b1, 8'hFD};
      else if (v <= 34)
        case (v - 19)
          0: sym = {1'b0, 8'h01};  1: sym = {1'b0, f};    4: sym = {1'b0, 8'h56};
          5: sym = {1'b0, 8'h34};  6: sym = {1'b0, 8'h12}; 8: sym = {1'b0, 8'h40};
          9: sym = {1'b0, 8'h01};  12: sym = {1'b0, 8'hF0};
          default: sym = {1'b0, 8'h00};
        endcase
      else if (v == 35) sym = {1'b1, 8'hFE};
      else if (v == 36) sym = {1'b1, 8'hF7};
      else              sym = {1'b0, 8'h00};
    end else sym = {1'b1, 8'hF7};
  endfunction

  always_ff @(posedge clk or negedge rst_n)
    if (!rst_n) begin
      bc <= 9; tc <= 0; fp <= 0; fcnt <= 0; sc <= 0; sh <= 0; m_lp <= 0; m_lv <= 0; rdm <= 0;
      c_sv <= 0; c_s <= 0;
    end else begin : ml
      int t, v;
      logic [8:0] s;
      logic [10:0] c;
      {v_k28_rdp, v_tps} = '0;
      if (act) begin
        m_lv <= 1;
        if (bc == 9) begin
          t = prst ? 0 : tc;
          v = prst ? 0 : fp;
          s = sym(pt, t, v, fcnt);
          c = enc(s[7:0], s[8], rdm);
          v_k28_rdp = s == {1'b1, 8'hBC} && rdm;
          v_tps = pt == 2 && t == 0;
          c_sv <= pt == 3; c_s <= s;
          bc <= 0; m_lp <= c[9]; sh <= c[8:0]; rdm <= c[10];
          tc <= (t + 1) % 4;
          fp <= v == 39 ? 0 : v + 1;
          if (pt == 3 && v == 39) fcnt <= fcnt + 1;
          sc <= prst ? 1 : sc < 32 ? sc + 1 : sc;
        end else begin
          c_sv <= 0;
          bc <= bc + 1; m_lp <= sh[8]; sh <= sh << 1;
          if (prst) begin tc <= 0; fp <= 0; sc <= 0; end
        end
      end else begin
        bc <= 9; m_lp <= 0; m_lv <= 0; sh <= 0; rdm <= 0; c_sv <= 0;
      end
    end

  // AUX transactions by training step, outcome and retry count; every video
  // data byte and control symbol through the encoder
  covergroup cg_dp @(negedge clk);
    option.per_instance = 1;
    cp_step: coverpoint ls iff (rst_n && m_done && sink_present)
      { bins rate = {L_RATE}; bins lane = {L_LANE}; bins crset = {L_CRSET}; bins crpoll = {L_CRPOLL};
        bins tpsset = {L_TPSSET}; bins tpspoll = {L_TPSPOLL}; bins edidw = {L_EDIDW}; bins edidr = {L_EDIDR};
        bins off = {L_OFF}; }
    cp_res: coverpoint {m_err, nak} iff (rst_n && m_done && sink_present)
      { bins ok = {2'b00}; bins nak = {2'b11}; bins error = {2'b10}; }
    cp_rty: coverpoint rty iff (rst_n && m_done && sink_present) { bins r[] = {[0:3]}; }
    cp_vbyte: coverpoint c_s[7:0] iff (rst_n && c_sv && !c_s[8]) { bins b[] = {[0:255]}; }
    cp_vk: coverpoint c_s[7:0] iff (rst_n && c_sv && c_s[8])
      { bins bs = {8'hBC}; bins be = {8'hFB}; bins se = {8'hFD}; bins ss = {8'hFE}; bins fs = {8'hF7}; }
  endgroup
  cg_dp u_cg_dp = new;

  `SVA_RST(a_reset_outputs, !rst_n, !lane_p && !lane_valid && !link_trained && !train_fail &&
           aux_tx_p && !aux_tx_en && edid == 0 && !edid_valid && !irq)
  `SVA_INV(a_aux_tx_en, aux_tx_en == m_en)
  `SVA_INV(a_aux_tx_p, aux_tx_p == m_p)
  `SVA_INV(a_lane_valid, lane_valid == m_lv)
  `SVA_INV(a_lane_p, lane_p == m_lp)
  `SVA_INV(a_link_trained, link_trained == (ls == L_VIDEO))
  `SVA_INV(a_train_fail, train_fail == tf)
  `SVA_INV(a_irq, irq == train_fail)
  `SVA_INV(a_edid_valid, edid_valid == edv)
  `SVA_INV(a_edid, edid == ed)
  `SVA_NXT(a_hpd_low_drops_link, !sink_present, !aux_tx_en && !link_trained && !train_fail && !edid_valid)

  `FC(reply_timeout, v_tmo)
  `FC(reply_manchester_violation_sync, v_viol && !v_viol_data)
  `FC(reply_manchester_violation_data, v_viol_data)
  `FC(reply_sync_bit_one, v_sync1)
  `FC(reply_start_bit_zero, v_start0)
  `FC(reply_not_ack, v_nak)
  `FC(reply_stop_chip0_low, v_stop0)
  `FC(reply_stop_chip1_low, v_stop1)
  `FC(reply_header_low_nibble_ignored, v_hdrlo)
  `FC(reply_starts_on_last_wait_cycle, v_last_wait)
  `FC(cr_poll_not_done, v_poll_nd_cr)
  `FC(eq_poll_not_done, v_poll_nd_eq)
  `FC(op_retried, v_retry)
  `FC(op_ok_after_three_retries, v_retry3_ok)
  `FC(edid_read, $rose(edv))
  `FC(link_trained, $rose(ls == L_VIDEO))
  `FC(training_failed, $rose(tf))
  `FC(hpd_low_during_request, v_drop_tx)
  `FC(hpd_low_during_reply, v_drop_rx)
  `FC(hpd_low_during_training_wait, v_drop_wait)
  `FC(hpd_low_during_video, v_drop_video)
  `FC(hpd_low_after_failure, v_drop_fail)
  `FC(k28_5_at_rd_plus, v_k28_rdp)
  `FC(tps1_marker, v_tps)
  `FC(frame_counter_wrap, $past(fcnt) == 8'hFF && fcnt == 8'h00)
  `FC_RST(reset_during_training, (ls != L_IDLE && ls != L_VIDEO) ##1 !rst_n)
  `FC_RST(reset_during_video, (ls == L_VIDEO) ##1 !rst_n)
endmodule

bind DisplayPort2_top DisplayPort2_sva u_sva (.*);
