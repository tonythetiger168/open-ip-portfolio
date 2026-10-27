// SPDX-License-Identifier: Apache-2.0
// CPRI master: a cycle-level model fed only by the pins (rx_sym, cpu port)
// predicts tx_sym, cpu_rdata and irq on every clock. It has its own 8b/10b
// tables: the transmit side encodes the expected hyperframe (K28.5, stuff
// bytes, L1 slow stream, vendor byte, IQ pattern) with running disparity,
// the receive side decodes through a table of every valid code group at
// both disparities (built at time 0 from the encoder), so a symbol that is
// not a code group or arrives at the wrong disparity is a code violation.
// On top sit the sync FSM (HUNT / ALIGN / SYNC, loss of sync), the L1
// slow-stream negotiation, the vendor byte and the 32-word IQ buffer.
`include "cov_macros.svh"
module CPRI_v8_0__eCPRI_over_CPR__sva (
  input logic        clk, rst_n, cpu_we, cpu_re, irq,
  input logic [9:0]  rx_sym, tx_sym,
  input logic [3:0]  cpu_addr,
  input logic [31:0] cpu_wdata, cpu_rdata
);
  `COV_CLOCKING(clk, !rst_n)

  // ---------------- 8b/10b reference ----------------
  function automatic logic [5:0] t6(input int y);
    logic [191:0] t;
    t = {6'b101011, 6'b011110, 6'b101110, 6'b001110, 6'b110110, 6'b010110, 6'b100110, 6'b110011,
         6'b111010, 6'b011010, 6'b101010, 6'b001011, 6'b110010, 6'b010011, 6'b100011, 6'b011011,
         6'b010111, 6'b011100, 6'b101100, 6'b001101, 6'b110100, 6'b010101, 6'b100101, 6'b111001,
         6'b111000, 6'b011001, 6'b101001, 6'b110101, 6'b110001, 6'b101101, 6'b011101, 6'b100111};
    t6 = t[6 * y +: 6];
  endfunction
  function automatic logic [3:0] t4(input int x);
    logic [31:0] t;
    t = {4'b1110, 4'b0110, 4'b1010, 4'b1101, 4'b1100, 4'b0101, 4'b1001, 4'b1011};
    t4 = t[4 * x +: 4];
  endfunction
  function automatic int pop(input logic [9:0] v);
    pop = 0;
    for (int i = 0; i < 10; i++) pop += v[i];
  endfunction
  function automatic logic [10:0] enc(input logic [7:0] d, input logic k, input logic rd);
    logic [5:0] c6;
    logic [3:0] c4;
    logic       r;
    int         y, x;
    y = d[4:0]; x = d[7:5];
    if (k) begin
      c6 = 6'b001111;
      c4 = (x == 3) ? 4'b0011 : (x == 0 || x == 4 || x == 7) ? ~t4(x) : t4(x);
      if (x == 7) c4 = 4'b1000;
      if (rd) begin c6 = ~c6; c4 = ~c4; end
      enc = {(pop({c6, c4}) == 5) ? rd : ~rd, c6, c4};
    end else begin
      c6 = t6(y);
      if (rd && (pop({4'h0, c6}) != 3 || c6 == 6'b111000)) c6 = ~c6;
      r = (pop({4'h0, c6}) == 3) ? rd : ~rd;
      if (x == 7 && ((!r && (y == 17 || y == 18 || y == 20)) ||
                     (r && (y == 11 || y == 13 || y == 14)))) c4 = r ? 4'b1000 : 4'b0111;
      else begin
        c4 = t4(x);
        if (r && (pop({6'h0, c4}) != 2 || x == 3)) c4 = ~c4;
      end
      if (pop({6'h0, c4}) != 2) r = ~r;
      enc = {r, c6, c4};
    end
  endfunction

  // decode table: [rd][symbol] -> {valid, k, data}
  logic [9:0] dtab [0:1][0:1023];
  initial begin
    logic [10:0] e;
    for (int r = 0; r < 2; r++) begin
      for (int s = 0; s < 1024; s++) dtab[r][s] = 10'h0;
      for (int d = 0; d < 256; d++) begin
        e = enc(8'(d), 1'b0, r[0]);
        dtab[r][e[9:0]] = {2'b10, 8'(d)};
      end
      for (int x = 0; x < 8; x++) begin
        e = enc({3'(x), 5'd28}, 1'b1, r[0]);
        dtab[r][e[9:0]] = {2'b11, 3'(x), 5'd28};
      end
    end
  end
  // disparity after a symbol (sub-block rule; also used for violations)
  function automatic logic rd_after(input logic [9:0] s, input logic rd);
    int n6, n4;
    logic r;
    n6 = pop({4'h0, s[9:4]}); n4 = pop({6'h0, s[3:0]});
    r = (n6 == 4) ? 1'b1 : (n6 == 2) ? 1'b0 : rd;
    rd_after = (n4 == 3) ? 1'b1 : (n4 == 1) ? 1'b0 : r;
  endfunction

  // ---------------- model state ----------------
  logic [7:0]  cfg [0:7];
  int          tp, thf;              // TX position, hyperframe index (0..15)
  logic        trd, rrd;
  logic [9:0]  m_tx;
  int          st, wc, miss, l1c;    // st: 0 HUNT, 1 ALIGN, 2 SYNC
  logic        al, l1d, los, cv;
  logic [7:0]  b1, b2, vend, ovf;
  logic [3:0]  pver, prate;
  logic [31:0] q [0:31];
  int          qh, qn, ib;
  logic [23:0] ish;
  // coverage events
  logic v_align, v_sync, v_stray, v_align_lost, v_los, v_miss3, v_badcg, v_baddisp, v_l1ok,
        v_l1bad, v_l1restart, v_push_pop, v_full_drop, v_ovf_sat, v_pop_empty, v_set_wins,
        v_kp;
  logic [7:0] v_disp;                // wrong-disparity rule hit (see below)
  // per-step copies for the covergroup (set at posedge, sampled at negedge)
  logic        c_dv, c_pv;
  logic [7:0]  c_db;
  int          c_qn;
  logic [31:0] c_pw;

  wire [9:0] dec = dtab[rrd][rx_sym];
  wire       rv  = dec[9];
  wire       rk  = dec[8];
  wire [7:0] rdd = dec[7:0];

  function automatic logic [7:0] tx_byte(input int p, input int h, output logic k);
    int bf, w;
    bf = p / 16; w = p % 16; k = 0;
    if (w == 0) begin
      if (bf == 0) begin k = 1; tx_byte = 8'hBC; end
      else if (bf == 1)
        tx_byte = (h == 0) ? 8'h5A : (h == 1) ? {4'h0, cfg[1][3:0]} : (h == 2) ? cfg[0] :
                  (h == 15) ? cfg[0] ^ {4'h0, cfg[1][3:0]} ^ 8'hA5 : 8'h00;
      else if (bf == 4) tx_byte = cfg[2];
      else tx_byte = 8'h00;
    end else if (bf == 0 && w <= 2) tx_byte = 8'h50;
    else tx_byte = {4'(bf), 4'(w)};
  endfunction

  always @(posedge clk or negedge rst_n) begin
    logic [7:0] b;
    logic       k, popq, iqp, push, comma, data;
    if (!rst_n) begin
      cfg[0] = 8'h2A; cfg[1] = 8'h04; cfg[2] = 8'hC9;
      for (int i = 3; i < 8; i++) cfg[i] = 8'h00;
      tp = 0; thf = 0; trd = 0; m_tx = {6'b100111, 4'b0100};
      rrd = 0; st = 0; wc = 0; miss = 0; l1c = 0; al = 0; l1d = 0; los = 0; cv = 0;
      b1 = 0; b2 = 0; vend = 0; ovf = 0; pver = 0; prate = 0;
      qh = 0; qn = 0; ib = 0; ish = 0;
      {v_align, v_sync, v_stray, v_align_lost, v_los, v_miss3, v_badcg, v_baddisp, v_l1ok,
       v_l1bad, v_l1restart, v_push_pop, v_full_drop, v_ovf_sat, v_pop_empty, v_set_wins, v_kp} = '0;
      v_disp = 8'h0;
      c_dv = 0; c_pv = 0;
    end else begin
      c_dv = 0; c_pv = 0;
      {v_align, v_sync, v_stray, v_align_lost, v_los, v_miss3, v_badcg, v_baddisp, v_l1ok,
       v_l1bad, v_l1restart, v_push_pop, v_full_drop, v_ovf_sat, v_pop_empty, v_set_wins, v_kp} = '0;
      // ---- transmitter ----
      b = tx_byte(tp, thf, k);
      if (k && trd) v_kp = 1;
      {trd, m_tx} = enc(b, k, trd);
      if (tp == 1023) begin tp = 0; thf = (thf + 1) % 16; end else tp++;

      // ---- cpu writes / irq clear, code violation ----
      if (cpu_we && cpu_addr < 8) cfg[cpu_addr[2:0]] = cpu_wdata[7:0];
      if (cpu_we && cpu_addr == 13) begin
        if (cpu_wdata[0]) los = 0;
        if (cpu_wdata[1]) begin cv = 0; if (!rv) v_set_wins = 1; end
      end
      v_disp = 8'h0;
      if (!rv) begin
        int n6, n4;
        logic rm;
        n6 = pop({4'h0, rx_sym[9:4]}); n4 = pop({6'h0, rx_sym[3:0]});
        rm = (n6 == 4) ? 1'b1 : (n6 == 2) ? 1'b0 : rrd;
        v_disp[0] = n6 == 4 && rrd;
        v_disp[1] = n6 == 2 && !rrd;
        v_disp[2] = rx_sym[9:4] == 6'b111000 && rrd;
        v_disp[3] = rx_sym[9:4] == 6'b000111 && !rrd;
        v_disp[4] = n4 == 3 && rm;
        v_disp[5] = n4 == 1 && !rm;
        v_disp[6] = rx_sym[3:0] == 4'b1100 && rm;
        v_disp[7] = rx_sym[3:0] == 4'b0011 && !rm;
        cv = 1;
        if (pop({4'h0, rx_sym[9:4]}) == 6 || pop({4'h0, rx_sym[9:4]}) == 0 ||
            dtab[!rrd][rx_sym][9] == 1'b0) v_badcg = 1;
        else v_baddisp = 1;
      end
      popq = cpu_re && cpu_addr == 10 && qn != 0;
      if (cpu_re && cpu_addr == 10 && qn == 0) v_pop_empty = 1;
      comma = rv && rk && rdd == 8'hBC;
      data  = rv && !rk;
      if (data && st == 2) begin c_dv = 1; c_db = rdd; end
      push  = 0;

      // ---- sync FSM + slow stream + IQ ----
      case (st)
        0: if (comma) begin st = 1; wc = 1; al = 0; miss = 0; v_align = 1; end
        1: begin
          if (comma) begin
            if (wc == 0) begin
              wc = 1;
              if (al) begin st = 2; al = 0; ib = 0; l1c = 0; v_sync = 1; end
              else al = 1;
            end else begin wc = 1; al = 0; v_stray = 1; end
          end else if (wc == 0) begin st = 0; al = 0; v_align_lost = 1; end
          else wc = (wc + 1) % 1024;
        end
        default: begin
          iqp = (wc % 16 != 0) && !(wc < 16 && wc % 16 <= 2);
          if (wc == 0) begin
            if (comma) begin if (miss == 3) v_miss3 = 1; miss = 0; end
            else if (miss == 3) begin
              st = 0; miss = 0; los = 1; ib = 0; l1c = 0; l1d = 0; v_los = 1;
            end else miss++;
          end
          if (wc == 16 && data) begin
            if (rdd == 8'h5A) begin if (l1c != 0) v_l1restart = 1; l1c = 1; end
            else if (l1c != 0) begin
              if (l1c == 1) b1 = rdd;
              if (l1c == 2) b2 = rdd;
              if (l1c == 15) begin
                l1c = 0;
                if (rdd == (b1 ^ b2 ^ 8'hA5)) begin
                  l1d = 1; pver = b1[3:0]; prate = b2[3:0]; v_l1ok = 1;
                end else v_l1bad = 1;
              end else l1c++;
            end
          end
          if (wc == 64 && data) vend = rdd;
          if (iqp && data && st == 2) begin
            if (ib == 3) begin
              if (qn < 32 || popq) begin
                q[(qh + qn) % 32] = {ish, rdd}; push = 1;
                c_pv = 1; c_qn = qn; c_pw = {ish, rdd};
                if (popq) v_push_pop = 1;
              end else begin
                v_full_drop = 1;
                if (ovf != 8'hFF) ovf++; else v_ovf_sat = 1;
              end
            end else ish[8 * (2 - ib) +: 8] = rdd;
            ib = (ib + 1) % 4;
          end
          wc = (wc + 1) % 1024;
        end
      endcase
      if (popq) begin qh = (qh + 1) % 32; qn--; end
      if (push) qn++;
      rrd = rd_after(rx_sym, rrd);
    end
  end

  function automatic int dcls(input logic [31:0] v);
    return v == 32'd0 ? 0 : v == '1 ? 1 : (v == 32'h5555_5555 || v == 32'hAAAA_AAAA) ? 2 : 3;
  endfunction
  // every received data byte through the decoder, IQ buffer depth and word
  // classes, every CPU register written
  covergroup cg_cpri @(negedge clk);
    option.per_instance = 1;
    cp_rbyte: coverpoint c_db iff (rst_n && c_dv) { bins b[] = {[0:255]}; }
    cp_depth: coverpoint c_qn iff (rst_n && c_pv) { bins empty = {0}; bins some = {[1:30]}; bins last = {31}; }
    cp_iq: coverpoint dcls(c_pw) iff (rst_n && c_pv)
      { bins zero = {0}; bins ones = {1}; bins alt = {2}; bins other = {3}; }
    cp_wr: coverpoint cpu_addr iff (rst_n && cpu_we) { bins cfg[] = {[0:7]}; bins clear = {13}; }
  endgroup
  cg_cpri u_cg_cpri = new;

  // expected cpu read data (combinational on the current address)
  logic [31:0] m_rd;
  logic [3:0]  nver, nrate;
  always_comb begin
    nver  = (cfg[1][3:0] < pver)  ? cfg[1][3:0] : pver;
    nrate = (cfg[0][3:0] < prate) ? cfg[0][3:0] : prate;
    case (cpu_addr)
      4'd8:    m_rd = {8'h0, ovf, pver, 6'(qn), 1'b0, 2'(miss), l1d, 2'(st)};
      4'd9:    m_rd = {24'h0, nrate, nver};
      4'd10:   m_rd = q[qh];
      4'd11:   m_rd = {26'h0, 6'(qn)};
      4'd12:   m_rd = {24'h0, vend};
      4'd13:   m_rd = {30'h0, cv, los};
      4'd14, 4'd15: m_rd = 32'h0;
      default: m_rd = {24'h0, cfg[cpu_addr[2:0]]};
    endcase
  end

  // ---------------- assertions ----------------
  `SVA_RST(a_reset_state, !rst_n, !irq && tx_sym == {6'b100111, 4'b0100})
  `SVA_INV(a_tx_sym, tx_sym == m_tx)
  `SVA_INV(a_irq, irq == (los || cv))
  `SVA_IMP(a_cpu_rdata, cpu_addr != 4'd10 || qn != 0, cpu_rdata == m_rd)
  `SVA_INV(a_tx_symbol_is_code_group, dtab[0][tx_sym][9] || dtab[1][tx_sym][9])
  `SVA_NXT(a_los_irq, v_los, irq)

  // ---------------- functional coverage ----------------
  `FC(comma_starts_align, v_align)
  `FC(sync_reached, v_sync)
  `FC(stray_comma_realigns, v_stray)
  `FC(align_lost, v_align_lost)
  `FC(loss_of_sync, v_los)
  `FC(three_missed_commas_tolerated, v_miss3)
  `FC(invalid_code_group, v_badcg)
  `FC(wrong_disparity, v_baddisp)
  `FC(l1_negotiated, v_l1ok)
  `FC(l1_bad_check_byte, v_l1bad)
  `FC(l1_sequence_restarted, v_l1restart)
  `FC(iq_push_and_pop, v_push_pop)
  `FC(iq_dropped_when_full, v_full_drop)
  `FC(overflow_count_saturated, v_ovf_sat)
  `FC(pop_when_empty, v_pop_empty)
  `FC(violation_wins_over_clear, v_set_wins)
  `FC(k28_5_at_rd_plus, v_kp)
  `FC(disp_6b_positive_at_rd_plus, v_disp[0])
  `FC(disp_6b_negative_at_rd_minus, v_disp[1])
  `FC(disp_6b_111000_at_rd_plus, v_disp[2])
  `FC(disp_6b_000111_at_rd_minus, v_disp[3])
  `FC(disp_4b_positive_at_rd_plus, v_disp[4])
  `FC(disp_4b_negative_at_rd_minus, v_disp[5])
  `FC(disp_4b_1100_at_rd_plus, v_disp[6])
  `FC(disp_4b_0011_at_rd_minus, v_disp[7])
  `FC(local_rate_lower, nrate == cfg[0][3:0] && cfg[0][3:0] < prate)
  `FC_RST(reset_in_sync, rst_n && st == 2 ##1 !rst_n)
endmodule

bind CPRI_v8_0__eCPRI_over_CPR__top CPRI_v8_0__eCPRI_over_CPR__sva u_sva (.*);
