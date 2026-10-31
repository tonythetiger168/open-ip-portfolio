// SPDX-License-Identifier: Apache-2.0
// HDMI TMDS source: the checker deserialises the three data channels using
// the TMDS clock channel for word alignment, keeps its own 640x480 raster
// position from link start, and re-encodes every pixel with its own TMDS
// (DVI 1.0) encoder, CTL table, guard bands, TERC4 table and packet
// builder (InfoFrame bytes, checksum and BCH ECC computed here), then
// compares each 10-bit word exactly. hsync/vsync/de, hpd parking and irq
// are checked against the same raster.
`include "cov_macros.svh"
module HDMI_2_1_sva (
  input logic       clk, rst_n, hpd, tmds_clk, hsync, vsync, de, irq,
  input logic [2:0] tmds_d
);
  `COV_CLOCKING(clk, !rst_n)
  localparam int HACT = 640, HT = 800, VACT = 480, VT = 525;
  localparam int HS0 = 656, HS1 = 752, VS0 = 490, VS1 = 492;
  localparam int IX = HS0 - 20, AVI_Y = VACT + 1, SPD_Y = VS0;

  // ---------------- reference encoders ----------------
  function automatic int ones8(input logic [7:0] v);
    ones8 = 0;
    for (int i = 0; i < 8; i++) ones8 += int'(v[i]);
  endfunction
  // returns {new disparity (8-bit signed), code}
  function automatic logic [17:0] tmds(input logic [7:0] d, input int c);
    logic [8:0] m;
    logic [9:0] q;
    int n1, n0;
    bit xn;
    xn = ones8(d) > 4 || (ones8(d) == 4 && d[0] == 1'b0);
    m[0] = d[0];
    for (int i = 1; i < 8; i++) m[i] = xn ? !(m[i-1] ^ d[i]) : (m[i-1] ^ d[i]);
    m[8] = !xn;
    n1 = ones8(m[7:0]); n0 = 8 - n1;
    if (c == 0 || n1 == n0) begin
      q = {!m[8], m[8], m[8] ? m[7:0] : ~m[7:0]};
      c = m[8] ? c + n1 - n0 : c + n0 - n1;
    end else if ((c > 0 && n1 > n0) || (c < 0 && n0 > n1)) begin
      q = {1'b1, m[8], ~m[7:0]};
      c = c + 2 * int'(m[8]) + n0 - n1;
    end else begin
      q = {1'b0, m[8], m[7:0]};
      c = c - 2 * int'(!m[8]) + n1 - n0;
    end
    return {8'(c), q};
  endfunction
  function automatic logic [9:0] ctl(input logic [1:0] c);
    logic [9:0] t [0:3];
    t = '{10'b1101010100, 10'b0010101011, 10'b0101010100, 10'b1010101011};
    return t[c];
  endfunction
  function automatic logic [9:0] terc4(input logic [3:0] d);
    logic [9:0] t [0:15];
    t = '{10'b1010011100, 10'b1001100011, 10'b1011100100, 10'b1011100010,
          10'b0101110001, 10'b0100011110, 10'b0110001110, 10'b0100111100,
          10'b1011001100, 10'b0100111001, 10'b0110011100, 10'b1011000110,
          10'b1010001110, 10'b1001110001, 10'b0101100011, 10'b1011000011};
    return t[d];
  endfunction
  function automatic logic [7:0] bch(input logic [55:0] v, input int n);
    logic [7:0] e;
    e = 0;
    for (int i = 0; i < 56; i++) if (i < n) e = (e >> 1) ^ ((e[0] ^ v[i]) ? 8'h83 : 8'h00);
    return e;
  endfunction

  // InfoFrame packets: header {ECC, HB2..HB0}, subpackets {ECC, PB6..PB0}
  logic [31:0] P_HDR [0:1];
  logic [63:0] P_SP  [0:1][0:3];
  initial begin
    logic [7:0] hb [0:2], pb [0:27];
    for (int p = 0; p < 2; p++) begin
      for (int i = 0; i < 28; i++) pb[i] = 0;
      if (p == 0) begin
        hb = '{8'h82, 8'h02, 8'h0D};
        pb[1] = 8'h10; pb[2] = 8'h18; pb[4] = 8'h01;
      end else begin
        string v, n;
        hb = '{8'h83, 8'h01, 8'h19};
        v = "OpenIP"; n = "HDMI 2.1 TX Core";
        for (int i = 0; i < v.len(); i++) pb[1 + i] = v[i];
        for (int i = 0; i < n.len(); i++) pb[9 + i] = n[i];
      end
      pb[0] = hb[0] + hb[1] + hb[2];
      for (int i = 1; i < 28; i++) pb[0] += pb[i];
      pb[0] = -pb[0];
      P_HDR[p][23:0] = {hb[2], hb[1], hb[0]};
      P_HDR[p][31:24] = bch({32'h0, P_HDR[p][23:0]}, 24);
      for (int k = 0; k < 4; k++) begin
        for (int i = 0; i < 7; i++) P_SP[p][k][8*i +: 8] = pb[7*k + i];
        P_SP[p][k][63:56] = bch(P_SP[p][k][55:0], 56);
      end
    end
  end

  // ---------------- deserialiser + raster ----------------
  logic       hpd_q, run, dummy;
  int         k, x, y, cnt [0:2];
  logic [8:0] sr [0:2];
  logic       s_de, s_hs, s_vs;
  wire        word = run && k == 9;
  logic [9:0] got [0:2];
  always_comb for (int c = 0; c < 3; c++) got[c] = {tmds_d[c], sr[c]};

  // expected words for (x, y)
  wire e_de  = y < VACT && x < HACT;
  wire e_hs  = !(x >= HS0 && x < HS1);
  wire e_vs  = !(y >= VS0 && y < VS1);
  wire pre_l = y == VT - 1 || y < VACT - 1;
  wire isl_l = y == AVI_Y || y == SPD_Y;
  wire spd   = y == SPD_Y;
  wire [4:0] ii = 5'(x - IX - 10);
  logic [9:0] exp_w [0:2];
  logic [7:0] exp_c [0:2];
  int ph;                                     // period, for coverage
  always_comb begin
    logic [17:0] r;
    logic [7:0] pix [0:2];
    logic [3:0] n1, n2;
    pix = '{8'(x) ^ 8'(y), 8'(y), 8'(x)};
    for (int c = 0; c < 3; c++) exp_c[c] = 0;
    for (int c = 0; c < 3; c++) begin
      r = tmds(pix[c], cnt[c]);
      exp_w[c] = r[9:0];
      if (e_de) exp_c[c] = r[17:10];
    end
    for (int b = 0; b < 4; b++) begin
      n1[b] = P_SP[spd][b][2 * ii];
      n2[b] = P_SP[spd][b][2 * ii + 1];
    end
    ph = 0;
    if (e_de) ph = 1;
    else if (pre_l && x >= HT - 2) begin
      ph = 2; exp_w = '{10'b1011001100, 10'b0100110011, 10'b1011001100};
    end else if (pre_l && x >= HT - 10) begin
      ph = 3; exp_w = '{ctl({e_vs, e_hs}), ctl(2'b01), ctl(2'b00)};
    end else if (isl_l && x >= IX && x < IX + 8) begin
      ph = 4; exp_w = '{ctl({e_vs, e_hs}), ctl(2'b01), ctl(2'b01)};
    end else if (isl_l && x >= IX && (x < IX + 10 || (x >= IX + 42 && x < IX + 44))) begin
      ph = 5; exp_w = '{terc4({2'b11, e_vs, e_hs}), 10'b0100110011, 10'b0100110011};
    end else if (isl_l && x >= IX + 10 && x < IX + 42) begin
      ph = 6; exp_w = '{terc4({ii != 0, P_HDR[spd][ii], e_vs, e_hs}), terc4(n1), terc4(n2)};
    end else begin
      ph = 0; exp_w = '{ctl({e_vs, e_hs}), ctl(2'b00), ctl(2'b00)};
    end
  end

  logic ran;                                  // link has run since reset
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      hpd_q <= 0; run <= 0; dummy <= 1; k <= 0; x <= 0; y <= 0; ran <= 0;
      for (int c = 0; c < 3; c++) begin cnt[c] <= 0; sr[c] <= 0; end
      s_de <= 0; s_hs <= 1; s_vs <= 1;
    end else if (!hpd) begin
      run <= 0; dummy <= 1; k <= 0; x <= 0; y <= 0; hpd_q <= 0;
      for (int c = 0; c < 3; c++) cnt[c] <= 0;
    end else begin
      ran <= 1;
      hpd_q <= 1;
      // word alignment: the first bit after the link starts is bit 0
      if (!run && hpd_q) begin run <= 1; k <= 1; end
      else if (run) k <= (k == 9) ? 0 : k + 1;
      for (int c = 0; c < 3; c++) sr[c] <= {tmds_d[c], sr[c][8:1]};
      if (run && k == 0) begin s_de <= de; s_hs <= hsync; s_vs <= vsync; end
      if (word) begin
        dummy <= 0;
        if (!dummy) begin
          for (int c = 0; c < 3; c++) cnt[c] <= int'($signed(exp_c[c]));
          if (x == HT - 1) begin x <= 0; y <= (y == VT - 1) ? 0 : y + 1; end
          else x <= x + 1;
        end
      end
    end
  end
  wire chk = word && !dummy;

  `SVA_RST(a_reset_parked, !rst_n, tmds_d == 0 && !tmds_clk && !de && hsync && vsync && !irq)
  `SVA_IMP(a_word_ch0, chk, got[0] == exp_w[0])
  `SVA_IMP(a_word_ch1, chk, got[1] == exp_w[1])
  `SVA_IMP(a_word_ch2, chk, got[2] == exp_w[2])
  `SVA_IMP(a_raster_flags, chk, s_de == e_de && s_hs == e_hs && s_vs == e_vs)
  `SVA_IMP(a_clock_channel, run && hpd, tmds_clk == (k >= 5))
  `SVA_NXT(a_unplug_parks, !hpd, tmds_d == 0 && !tmds_clk && !de)
  `SVA_INV(a_irq, irq == (ran && !hpd))

  // TMDS video encoding per channel: transition-minimizing mode (XOR /
  // XNOR) x DC-balance branch (no running disparity or balanced word,
  // inverted, not inverted); every legal period-to-period transition.
  // The pixel pattern (x ^ y, y, x) and the AVI / SPD packets are fixed
  // by the core, not by the TB: channel 1 (y) reaches all six encoder
  // branches, while channels 0 and 2 did not take XOR-inverted or
  // XNOR-kept in the simulated frames (their data cannot be steered), so
  // only their reached branches are binned; the TERC4 nibbles are those
  // two constant packets, checked word by word by a_word_ch*.
  function automatic logic [2:0] tbr(input logic [7:0] d, input int c);
    logic [8:0] m;
    int n1, n0;
    bit xn;
    xn = ones8(d) > 4 || (ones8(d) == 4 && d[0] == 1'b0);
    m[0] = d[0];
    for (int i = 1; i < 8; i++) m[i] = xn ? !(m[i-1] ^ d[i]) : (m[i-1] ^ d[i]);
    n1 = ones8(m[7:0]); n0 = 8 - n1;
    tbr[2] = xn;
    tbr[1:0] = (c == 0 || n1 == n0) ? 2'd0 :
               ((c > 0 && n1 > n0) || (c < 0 && n0 > n1)) ? 2'd1 : 2'd2;
  endfunction
  logic [7:0] pixv [0:2];
  always_comb pixv = '{8'(x) ^ 8'(y), 8'(y), 8'(x)};
  wire [2:0] br0 = tbr(pixv[0], cnt[0]), br1 = tbr(pixv[1], cnt[1]), br2 = tbr(pixv[2], cnt[2]);
  int ph_prev;
  always_ff @(posedge clk or negedge rst_n)
    if (!rst_n) ph_prev <= -1;
    else if (!hpd) ph_prev <= -1;
    else if (chk) ph_prev <= ph;
  covergroup cg_link @(posedge clk);
    option.per_instance = 1;
    cp_br0: coverpoint br0 iff (rst_n && chk && ph == 1)
      { bins xor_bal = {3'b0_00}; bins xor_keep = {3'b0_10};
        bins xnor_bal = {3'b1_00}; bins xnor_inv = {3'b1_01}; }
    cp_br1: coverpoint br1 iff (rst_n && chk && ph == 1)
      { bins xor_bal = {3'b0_00}; bins xor_inv = {3'b0_01}; bins xor_keep = {3'b0_10};
        bins xnor_bal = {3'b1_00}; bins xnor_inv = {3'b1_01}; bins xnor_keep = {3'b1_10}; }
    cp_br2: coverpoint br2 iff (rst_n && chk && ph == 1)
      { bins xor_bal = {3'b0_00}; bins xor_keep = {3'b0_10};
        bins xnor_bal = {3'b1_00}; bins xnor_inv = {3'b1_01}; }
    cp_period: coverpoint {4'(ph_prev), 4'(ph)} iff (rst_n && chk && ph_prev >= 0 && ph_prev != ph)
      { bins ctrl_to_vpre = {8'h03}; bins vpre_to_vguard = {8'h32}; bins vguard_to_video = {8'h21};
        bins video_to_ctrl = {8'h10}; bins ctrl_to_ipre = {8'h04}; bins ipre_to_iguard = {8'h45};
        bins iguard_to_data = {8'h56}; bins data_to_iguard = {8'h65}; bins iguard_to_ctrl = {8'h50}; }
  endgroup
  cg_link u_cg_link = new;

  `FC(video_pixel, chk && ph == 1)
  `FC(video_preamble, chk && ph == 3)
  `FC(video_guard, chk && ph == 2)
  `FC(island_preamble, chk && ph == 4)
  `FC(island_guard, chk && ph == 5)
  `FC(avi_island_done, chk && ph == 6 && !spd && ii == 31)
  `FC(spd_island_done, chk && ph == 6 && spd && ii == 31)
  `FC(hsync_edge_in_island, chk && ph == 6 && x == HS0)
  `FC(ctrl_hs_vs_both_active, chk && ph == 0 && !e_hs && !e_vs)
  `FC(ctrl_vs_only, chk && ph == 0 && e_hs && !e_vs)
  `FC(disparity_positive, chk && ph == 1 && cnt[0] > 0)
  `FC(disparity_negative, chk && ph == 1 && cnt[0] < 0)
  `FC(frame_wrap, chk && x == HT - 1 && y == VT - 1)
  `FC(unplug_in_video, $fell(hpd) && $past(de))
  `FC(replug, $rose(hpd))
  `FC_RST(reset_while_unplugged, !hpd && rst_n ##1 !rst_n)
endmodule

bind HDMI_2_1_top HDMI_2_1_sva u_sva (.*);
