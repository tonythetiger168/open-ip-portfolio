// SPDX-License-Identifier: Apache-2.0
// SGMII / 1000BASE-X PCS: concurrent SVA against a table-driven model of
// the receive path (aligner, 8b/10b decode from the clause 36 tables,
// synchronisation, ordered sets and packets, GMII receive), the clause 37
// auto-negotiation and the transmitted code-group stream (valid at the
// running disparity, ordered-set positions, /I1/ / /I2/, packet framing
// against the GMII input) + functional coverage.
`include "cov_macros.svh"
module SGMII_sva #(parameter int LT_X = 1250000, LT_SG = 200000) (
  input logic        clk, rst_n,
  input logic [7:0]  gtxd, grxd,
  input logic        gtx_en, gtx_er, grx_dv, grx_er,
  input logic [9:0]  tx_code, rx_code,
  input logic        mode_sgmii, an_en, an_restart,
  input logic [15:0] adv, lp_ability,
  input logic        sync_ok, an_done, link_up, full_duplex, irq_link, irq_an, irq_err,
  input logic [1:0]  speed
);
  `COV_CLOCKING(clk, !rst_n)

  // ---------------- 8b/10b tables ----------------
  function automatic logic [5:0] m6(input logic [4:0] x);
    case (x)
      0: return 6'b100111;  1: return 6'b011101;  2: return 6'b101101;  3: return 6'b110001;
      4: return 6'b110101;  5: return 6'b101001;  6: return 6'b011001;  7: return 6'b111000;
      8: return 6'b111001;  9: return 6'b100101; 10: return 6'b010101; 11: return 6'b110100;
      12: return 6'b001101; 13: return 6'b101100; 14: return 6'b011100; 15: return 6'b010111;
      16: return 6'b011011; 17: return 6'b100011; 18: return 6'b010011; 19: return 6'b110010;
      20: return 6'b001011; 21: return 6'b101010; 22: return 6'b011010; 23: return 6'b111010;
      24: return 6'b110011; 25: return 6'b100110; 26: return 6'b010110; 27: return 6'b110110;
      28: return 6'b001110; 29: return 6'b101110; 30: return 6'b011110; default: return 6'b101011;
    endcase
  endfunction
  function automatic int n1(input logic [9:0] v);
    int c;
    c = 0;
    for (int i = 0; i < 10; i++) c += int'(v[i]);
    return c;
  endfunction
  function automatic logic [10:0] r_enc(input logic [7:0] b, input logic k, input logic rd);
    logic [5:0] a;
    logic [3:0] f;
    logic r, alt;
    a = (k && b[4:0] == 5'd28) ? 6'b001111 : m6(b[4:0]);
    if (rd && (n1({4'b0, a}) != 3 || a == 6'b111000)) a = ~a;
    r = n1({4'b0, a}) == 3 ? rd : n1({4'b0, a}) > 3;
    alt = b[7:5] == 3'd7 && (k || (!r && (b[4:0] == 5'd17 || b[4:0] == 5'd18 || b[4:0] == 5'd20)) ||
                             (r && (b[4:0] == 5'd11 || b[4:0] == 5'd13 || b[4:0] == 5'd14)));
    case (b[7:5])
      3'd0: f = 4'b1011; 3'd1: f = 4'b1001; 3'd2: f = 4'b0101; 3'd3: f = 4'b1100;
      3'd4: f = 4'b1101; 3'd5: f = 4'b1010; 3'd6: f = 4'b0110; default: f = alt ? 4'b0111 : 4'b1110;
    endcase
    if (k && b[4:0] == 5'd28 && (b[7:5] == 3'd1 || b[7:5] == 3'd2 || b[7:5] == 3'd5 || b[7:5] == 3'd6)) f = ~f;
    if (r && (n1({6'b0, f}) != 2 || b[7:5] == 3'd3 || (k && b[4:0] == 5'd28))) f = ~f;
    r = n1({6'b0, f}) == 2 ? r : n1({6'b0, f}) > 2;
    return {a, f, r};
  endfunction
  // {valid, k, RD after, byte} for each code group at RD- / RD+
  logic [10:0] dt [0:2047];
  initial begin
    logic [10:0] e;
    for (int i = 0; i < 2048; i++) dt[i] = '0;
    for (int k = 0; k < 2; k++)
      for (int b = 0; b < 256; b++)
        if (k == 0 || b == 8'h1C || b == 8'h3C || b == 8'h5C || b == 8'h7C || b == 8'h9C || b == 8'hBC ||
            b == 8'hDC || b == 8'hFC || b == 8'hF7 || b == 8'hFB || b == 8'hFD || b == 8'hFE)
          for (int r = 0; r < 2; r++) begin
            e = r_enc(8'(b), 1'(k), 1'(r));
            dt[{1'(r), e[10:1]}] = {1'b1, 1'(k), e[0], 8'(b)};
          end
  end
  // RD after an invalid group: its last unbalanced sub-block
  function automatic logic inv_rd(input logic [9:0] c, input logic rd);
    if (n1({6'b0, c[3:0]}) != 2) return n1({6'b0, c[3:0]}) > 2;
    if (n1({4'b0, c[9:4]}) != 3) return n1({4'b0, c[9:4]}) > 3;
    return rd;
  endfunction
  localparam logic [7:0] K28_5 = 8'hBC, KS = 8'hFB, KT = 8'hFD, KR = 8'hF7, KV = 8'hFE,
                         D21_5 = 8'hB5, D2_2 = 8'h42, D5_6 = 8'hC5, D16_2 = 8'h50;
  localparam logic [15:0] ACK = 16'h4000;

  // ---------------- receive model ----------------
  logic [9:0]  q_prev, q_cg;
  logic [3:0]  q_off;
  logic        q_rd, q_even;
  int          q_sy, q_good;                // 0 loss, 1..2 comma detect / acquire, 3 CD3, 10..13 acquired 1..4
  int          q_rs;                        // 0 idle, 1 OS1, 2 cfg1, 3 cfg2, 4 packet, 5 end
  logic [7:0]  q_lo, m_rxd;
  logic        m_dv, m_er, m_ierr;
  logic        q_evc, q_evi;
  logic [15:0] q_val;
  wire  [19:0] q_win = {q_prev, rx_code};
  wire  [10:0] q_d = dt[{q_rd, q_cg}];
  wire         q_v = q_d[10], q_k = q_d[9];
  wire  [7:0]  q_b = q_d[7:0];
  wire         q_comma = q_cg[9:3] == 7'b0011111 || q_cg[9:3] == 7'b1100000;
  wire         q_bad = !q_v || (q_comma && !q_even);
  wire         q_sync = q_sy >= 10;
  // xmit from the AN model: 0 config, 1 idle, 2 data
  int          a_st;                        // 0 off, 1 restart, 2 ability, 3 ack, 4 complete ack, 5 idle, 6 OK
  wire  [1:0]  a_xmit = (a_st == 0 || a_st == 6) ? 2'd2 : a_st == 5 ? 2'd1 : 2'd0;
  logic [3:0]  fc_at;                       // first comma offset in the window (10: none)
  always_comb begin
    fc_at = 4'd10;
    for (int o = 9; o >= 0; o--)
      if (q_win[19-o -: 7] == 7'b0011111 || q_win[19-o -: 7] == 7'b1100000) fc_at = 4'(o);
  end

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      q_prev <= 0; q_cg <= 0; q_off <= 0; q_rd <= 0; q_even <= 0; q_sy <= 0; q_good <= 0; q_rs <= 0;
      q_lo <= 0; m_rxd <= 0; m_dv <= 0; m_er <= 0; m_ierr <= 0; q_evc <= 0; q_evi <= 0; q_val <= 0;
    end else begin
      q_prev <= rx_code;
      if (q_sy == 0 && fc_at != 4'd10) begin q_off <= fc_at; q_cg <= q_win[19 - fc_at -: 10]; end
      else q_cg <= q_win[19 - q_off -: 10];
      q_rd <= q_v ? q_d[8] : inv_rd(q_cg, q_rd);
      q_even <= !q_even;
      m_dv <= 0; m_er <= 0; m_rxd <= 0; m_ierr <= 0; q_evc <= 0; q_evi <= 0;
      // synchronisation (figure 36-9)
      if (q_sy == 0) begin if (q_comma) begin q_sy <= 1; q_even <= 0; end end
      else if (q_sy == 1 || q_sy == 3 || q_sy == 5) q_sy <= (q_v && !q_k) ? (q_sy == 5 ? 10 : q_sy + 1) : 0;
      else if (q_sy == 2 || q_sy == 4) begin
        if (q_bad) q_sy <= 0; else if (q_comma) q_sy <= q_sy + 1;
      end else if (q_sy == 10) begin if (q_bad) begin q_sy <= 11; q_good <= 0; end end
      else if (q_bad) begin q_good <= 0; q_sy <= q_sy == 13 ? 0 : q_sy + 1; end
      else if (q_good == 2) begin q_good <= 0; q_sy <= q_sy - 1; end
      else q_good <= q_good + 1;
      // ordered sets and packets
      if (q_sync) begin
        if (q_bad) m_ierr <= 1;
        case (q_rs)
          0, 5:
            if (q_comma && q_even) q_rs <= 1;
            else if (q_v && q_k && q_b == KS && q_even && a_xmit == 2) begin q_rs <= 4; m_dv <= 1; m_rxd <= 8'h55; end
            else if (q_rs == 5 && q_v && q_k && q_b == KR) ;
            else begin
              q_rs <= 0;
              if ((!q_v || q_k) && a_xmit == 2) begin m_er <= 1; m_rxd <= 8'h0E; m_ierr <= 1; end
            end
          1: begin
            q_rs <= (q_v && !q_k && (q_b == D21_5 || q_b == D2_2)) ? 2 : 0;
            if (q_v && !q_k && (q_b == D5_6 || q_b == D16_2)) q_evi <= 1;
          end
          2: begin q_lo <= q_b; q_rs <= (q_v && !q_k) ? 3 : 0; end
          3: begin q_rs <= 0; if (q_v && !q_k) begin q_evc <= 1; q_val <= {q_b, q_lo}; end end
          default:
            if (q_v && q_k && q_b == KT) q_rs <= 5;
            else if (q_comma) begin m_dv <= 1; m_er <= 1; m_ierr <= 1; q_rs <= q_even ? 1 : 0; end
            else begin
              m_dv <= 1; m_rxd <= q_b;
              if (!q_v || q_k) begin m_er <= 1; m_ierr <= 1; end
            end
        endcase
      end else q_rs <= 0;
    end
  end

  // ---------------- auto-negotiation model ----------------
  logic [15:0] a_last, a_lp;
  int          a_nab, a_nak, a_nid, a_lt;
  logic        a_sync_q, a_done_p;
  wire  [31:0] a_max = mode_sgmii ? LT_SG : LT_X;
  wire         a_abl = q_evc && a_nab == 2 && (q_val & ~ACK) == (a_last & ~ACK);
  wire         a_abl_h = q_evc && a_nab >= 2 && (q_val & ~ACK) == (a_last & ~ACK);
  wire         a_ack = q_evc && a_nak >= 2 && q_val == a_last && q_val[14];
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      a_st <= 0; a_last <= 0; a_lp <= 0; a_nab <= 0; a_nak <= 0; a_nid <= 0; a_lt <= 0; a_sync_q <= 0; a_done_p <= 0;
    end else begin
      a_sync_q <= q_sync; a_done_p <= 0;
      if (q_evc) begin
        a_last <= q_val; a_nid <= 0;
        a_nab <= (q_val & ~ACK) == (a_last & ~ACK) ? (a_nab < 3 ? a_nab + 1 : 3) : 1;
        a_nak <= (q_val == a_last && q_val[14]) ? (a_nak < 3 ? a_nak + 1 : 3) : int'(q_val[14]);
      end
      if (q_evi) begin a_nab <= 0; a_nak <= 0; if (a_nid < 3) a_nid <= a_nid + 1; end
      if (!q_sync) begin a_nab <= 0; a_nak <= 0; a_nid <= 0; end
      if (a_lt != 0) a_lt <= a_lt - 1;
      if (!an_en) a_st <= 0;
      else if (a_st == 0 || an_restart || (a_sync_q && !q_sync)) begin a_st <= 1; a_lt <= a_max; end
      else if (a_abl && q_val == 0 && (a_st == 3 || a_st == 4)) begin a_st <= 1; a_lt <= a_max; end
      else
        case (a_st)
          1: if (a_lt == 0) a_st <= 2;
          2: if (a_abl_h && q_val != 0) begin a_st <= 3; a_lp <= q_val; end
          3: if (a_ack) begin
               if ((q_val & ~ACK) == (a_lp & ~ACK)) begin a_st <= 4; a_lt <= a_max; a_lp <= q_val; end
               else begin a_st <= 1; a_lt <= a_max; end
             end
          4: if (a_lt == 0) begin a_st <= 5; a_lt <= a_max; a_nid <= 0; end
          5: if (a_abl) begin a_st <= 1; a_lt <= a_max; end
             else if (a_lt == 0 && a_nid == 3) begin a_st <= 6; a_done_p <= 1; end
          default: if (a_abl) begin a_st <= 1; a_lt <= a_max; end
        endcase
    end
  end
  wire m_link = q_sync && (!an_en || (a_st == 6 && (!mode_sgmii || a_lp[15])));
  logic m_link_q, m_irq_link;
  always_ff @(posedge clk or negedge rst_n)
    if (!rst_n) begin m_link_q <= 0; m_irq_link <= 0; end
    else begin m_link_q <= m_link; m_irq_link <= m_link != m_link_q; end

  // ---------------- transmit stream model ----------------
  logic        t_rd, t_even, t_pkt, t_seen_k;
  int          t_os, t_r;                   // position in a /C/ (1..3) or /I/ (1); /R/ count after /T/
  logic [7:0]  t_c1, t_lo;
  logic        t_en_q, t_er_q, t_tbad;
  logic [7:0]  t_d_q;
  wire  [10:0] t_d = dt[{t_rd, tx_code}];
  wire         t_v = t_d[10], t_k = t_d[9];
  wire  [7:0]  t_b = t_d[7:0];
  logic [15:0] t_cfg;
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      t_rd <= 0; t_even <= 0; t_pkt <= 0; t_seen_k <= 0; t_os <= 0; t_r <= 0; t_c1 <= 0; t_lo <= 0;
      t_en_q <= 0; t_er_q <= 0; t_d_q <= 0; t_cfg <= 0; t_tbad <= 0;
    end else begin
      // tx_code shows the group chosen in the previous clock
      t_en_q <= gtx_en; t_er_q <= gtx_er; t_d_q <= gtxd;
      t_rd <= t_v ? t_d[8] : t_rd;
      t_even <= !t_even;
      t_tbad <= 0;
      if (t_v && t_k && t_b == K28_5) begin t_seen_k <= 1; t_even <= 0; t_os <= 1; t_pkt <= 0; t_r <= 0; end
      else if (t_os == 1) begin t_c1 <= t_b; t_os <= (t_b == D21_5 || t_b == D2_2) ? 2 : 0; end
      else if (t_os == 2) begin t_lo <= t_b; t_os <= 3; end
      else if (t_os == 3) begin t_os <= 0; t_cfg <= {t_b, t_lo}; end
      else if (t_v && t_k && t_b == KS) t_pkt <= 1;
      else if (t_pkt && t_v && t_k && t_b == KT) begin t_pkt <= 0; t_r <= 1; end
      else if (t_r != 0 && t_v && t_k && t_b == KR) t_r <= t_r + 1;
    end
  end
  wire t_in = t_seen_k && rst_n;

  // ---------------- assertions ----------------
  `SVA_INV(a_tx_valid, !t_seen_k || t_v)
  `SVA_IMP(a_tx_comma_even, t_in && t_v && t_k && t_b == K28_5, t_even || !t_seen_k)
  `SVA_IMP(a_tx_sop_even, t_in && t_v && t_k && t_b == KS, t_even && t_en_q)
  `SVA_IMP(a_tx_idle, t_in && t_os == 1 && !(t_b == D21_5 || t_b == D2_2), t_v && !t_k && t_b == (t_rd ? D16_2 : D5_6))
  `SVA_IMP(a_tx_data, t_in && t_pkt && t_en_q, t_v && t_k == t_er_q && t_b == (t_er_q ? KV : t_d_q))
  `SVA_IMP(a_tx_eop, t_in && t_pkt && !t_en_q, t_v && t_k && t_b == KT)
  `SVA_IMP(a_tx_r, t_in && t_r == 1, t_v && t_k && t_b == KR)
  `SVA_IMP(a_tx_r2, t_in && t_r == 2 && !t_even, t_v && t_k && t_b == KR)
  `SVA_IMP(a_tx_cfg_alt, t_in && t_os == 1 && (t_b == D21_5 || t_b == D2_2) && t_c1 != 0, t_b != t_c1)
  `SVA_INV(a_rx_gmii, grx_dv == m_dv && grx_er == m_er && (!(m_dv || m_er) || m_er && m_dv || grxd == m_rxd))
  `SVA_INV(a_irq_err, irq_err == m_ierr)
  `SVA_INV(a_sync, sync_ok == q_sync)
  `SVA_INV(a_an, an_done == (a_st == 6) && irq_an == a_done_p && (a_st < 3 && a_st != 0 || lp_ability == a_lp))
  `SVA_INV(a_link, link_up == m_link && irq_link == m_irq_link)
  `SVA_INV(a_result, speed == (mode_sgmii ? lp_ability[11:10] : 2'b10) &&
                     full_duplex == (mode_sgmii ? lp_ability[12] : adv[5] && lp_ability[5]))
  `SVA_INV(a_no_x, !$isunknown({tx_code, grx_dv, grx_er, sync_ok, an_done, link_up, irq_link, irq_an, irq_err}))
  `SVA_RST(a_rst, 1'b1, !grx_dv && !grx_er && !sync_ok && !an_done && !link_up && !irq_link && !irq_an && !irq_err)

  // ---------------- functional coverage ----------------
  // classes computed at the clock edge, sampled half a clock later (-1: none)
  int k_off, k_an, k_rx, k_tx, k_sg, k_sy;
  always @(posedge clk) begin
    k_off = -1; k_an = -1; k_rx = -1; k_tx = -1; k_sg = -1; k_sy = -1;
    if (rst_n) begin
      if (q_sy == 0 && fc_at != 4'd10) k_off = int'(fc_at);
      // AN: a restart by its cause, or the state reached
      if (an_en && a_st != 0) begin
        if (an_restart) k_an = 0;
        else if (a_sync_q && !q_sync) k_an = 1;
        else if (a_abl && q_val == 0 && (a_st == 3 || a_st == 4)) k_an = 2;
        else if (a_st == 3 && a_ack && (q_val & ~ACK) != (a_lp & ~ACK)) k_an = 3;
        else if (a_st == 5 && a_abl) k_an = 4;
        else if (a_st == 6 && a_abl) k_an = 5;
        else if (a_st == 5 && a_lt == 0 && a_nid == 3) k_an = 6;
        else if (a_st == 2 && a_abl_h && !a_abl && q_val != 0) k_an = 7;   // matched before ability detect
        else if (a_st == 3 && a_ack && a_nak == 3) k_an = 8;               // acknowledged before acknowledge detect
      end
      if (q_sync)
        case (q_rs)
          4: k_rx = (q_v && q_k && q_b == KT) ? 0 : q_comma ? 1 : (q_v && q_k && q_b == KV) ? 2 : !q_v ? 3 : (q_v && q_k) ? 4 : -1;
          0, 5: k_rx = (q_v && q_k && q_b == KS && q_even && a_xmit == 2) ? (q_rs == 5 ? 5 : 6) :
                       ((!q_v || (q_k && !q_comma && !(q_rs == 5 && q_b == KR))) && a_xmit == 2) ? 7 :
                       (q_v && q_k && q_b == KS && a_xmit != 2) ? 8 : -1;
          default: ;
        endcase
      if (t_in && t_v && t_k && t_b == KT) k_tx = t_even ? 0 : 1;
      if (t_in && t_v && t_k && t_b == KV) k_tx = 2;
      if (t_in && t_os == 1 && t_v && !t_k) k_tx = t_b == D5_6 ? 3 : t_b == D16_2 ? 4 : t_b == D21_5 ? 5 : 6;
      if (an_done && mode_sgmii) k_sg = 4 * int'(lp_ability[15]) + int'(lp_ability[11:10]);
      if (q_sy >= 11 && q_good == 2 && !q_bad) k_sy = q_sy - 11;     // a step back up
      if (q_sy >= 10 && q_bad) k_sy = q_sy == 13 ? 4 : 3;
    end
  end
  covergroup cg_sgmii @(negedge clk);
    option.per_instance = 1;
    cp_offset: coverpoint k_off { bins off[] = {[0:9]}; }
    cp_an: coverpoint k_an
      { bins an_restart = {0}; bins sync_lost = {1}; bins partner_zero = {2}; bins abilities_changed = {3};
        bins cfg_in_idle = {4}; bins cfg_in_link = {5}; bins complete = {6};
        bins ability_held = {7}; bins ack_held = {8}; }
    cp_rx: coverpoint k_rx
      { bins eop = {0}; bins early_end = {1}; bins error_v = {2}; bins invalid = {3}; bins special = {4};
        bins sop_after_r = {5}; bins sop_idle = {6}; bins false_carrier = {7}; bins sop_not_data = {8}; }
    cp_tx: coverpoint k_tx
      { bins t_even = {0}; bins t_odd = {1}; bins v = {2}; bins i1 = {3}; bins i2 = {4}; bins c1 = {5}; bins c2 = {6}; }
    cp_sgmii: coverpoint k_sg { bins s10 = {4}; bins s100 = {5}; bins s1000 = {6}; bins no_link = {0}; }
    cp_sync: coverpoint k_sy { bins up_from_2 = {0}; bins up_from_3 = {1}; bins up_from_4 = {2}; bins bad = {3}; bins lost = {4}; }
  endgroup
  cg_sgmii u_cg_sgmii = new;

  `FC(an_disabled_link, !an_en && link_up)
  `FC(tx_packet_starts_odd, gtx_en && !t_en_q && !t_even && a_xmit == 2 && t_seen_k)
  `FC(rx_packet_both_ways, grx_dv && t_pkt)
  `FC(half_duplex_result, an_done && !mode_sgmii && !full_duplex)
  `FC_RST(reset_in_packet, rst_n && grx_dv ##1 !rst_n)
endmodule

bind SGMII_top SGMII_sva #(.LT_X(LT_X), .LT_SG(LT_SG)) u_sva (.*);
