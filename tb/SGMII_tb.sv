// SPDX-License-Identifier: Apache-2.0
// Self-checking testbench for SGMII_top (1000BASE-X / SGMII PCS).
// The TB is both the MAC (GMII) and the link partner (ten-bit side). The
// partner has its own 8b/10b coder (from the clause 36 tables, decoded by
// searching every code group), its own clause 37 auto-negotiation, and a
// line between the two that can shift the code-group boundary by any
// number of bits. It checks every code group the PCS sends (valid, right
// disparity, /C/ alternation and config words, /I/ ending at RD-, /S/ on
// an even position, /T/ /R/ (/R/) alignment) and every packet both ways;
// GMII receive packets, errors and false carriers are compared with what
// the partner sent.
`timescale 1ns/1ps
module SGMII_tb;
  localparam int LT_X = 300, LT_SG = 211;   // every timer bit differs
  logic clk = 0, rst_n = 0;
  logic [7:0]  gtxd = 0;
  logic        gtx_en = 0, gtx_er = 0;
  wire  [7:0]  grxd;
  wire         grx_dv, grx_er;
  wire  [9:0]  tx_code;
  logic [9:0]  rx_code;
  logic        mode_sgmii = 0, an_en = 1, an_restart = 0;
  logic [15:0] adv = 16'h01A0;
  wire         sync_ok, an_done, link_up, full_duplex, irq_link, irq_an, irq_err;
  wire  [15:0] lp_ability;
  wire  [1:0]  speed;
  int errors = 0;

  SGMII_top #(.LT_X(LT_X), .LT_SG(LT_SG)) dut (.*);
  always #4 clk = ~clk;

  task automatic fail(input string m);
    errors++;
    if (errors < 30) $display("ERROR: %s @%0t", m, $time);
  endtask
  task automatic clocks(input int n); repeat (n) @(posedge clk); endtask

  // ------------------------------ reference 8b/10b ------------------------------
  // abcdei for D.x at RD-, fghj for D/K.x.y at RD- (clause 36 tables 36-1a..e)
  function automatic logic [5:0] m6(input int x);
    logic [5:0] t [0:31];
    t[0] = 6'b100111; t[1] = 6'b011101; t[2] = 6'b101101; t[3] = 6'b110001; t[4] = 6'b110101;
    t[5] = 6'b101001; t[6] = 6'b011001; t[7] = 6'b111000; t[8] = 6'b111001; t[9] = 6'b100101;
    t[10] = 6'b010101; t[11] = 6'b110100; t[12] = 6'b001101; t[13] = 6'b101100; t[14] = 6'b011100;
    t[15] = 6'b010111; t[16] = 6'b011011; t[17] = 6'b100011; t[18] = 6'b010011; t[19] = 6'b110010;
    t[20] = 6'b001011; t[21] = 6'b101010; t[22] = 6'b011010; t[23] = 6'b111010; t[24] = 6'b110011;
    t[25] = 6'b100110; t[26] = 6'b010110; t[27] = 6'b110110; t[28] = 6'b001110; t[29] = 6'b101110;
    t[30] = 6'b011110; t[31] = 6'b101011;
    return t[x];
  endfunction
  function automatic int ones(input logic [9:0] v, input int n);
    int c;
    c = 0;
    for (int i = 0; i < n; i++) c += v[i];
    return c;
  endfunction
  // {code, RD after}; rd 1 = RD+
  function automatic logic [10:0] r_enc(input logic [7:0] b, input bit k, input bit rd);
    logic [5:0] a;
    logic [3:0] f;
    int x, y;
    bit r, alt;
    x = b[4:0]; y = b[7:5];
    a = (k && x == 28) ? 6'b001111 : m6(x);
    if (rd && (ones(a, 6) != 3 || a == 6'b111000)) a = ~a;
    r = ones(a, 6) == 3 ? rd : ones(a, 6) > 3;
    alt = y == 7 && (k || (!r && (x == 17 || x == 18 || x == 20)) || (r && (x == 11 || x == 13 || x == 14)));
    case (y)
      0: f = 4'b1011; 1: f = 4'b1001; 2: f = 4'b0101; 3: f = 4'b1100;
      4: f = 4'b1101; 5: f = 4'b1010; 6: f = 4'b0110; default: f = alt ? 4'b0111 : 4'b1110;
    endcase
    if (k && x == 28 && (y == 1 || y == 2 || y == 5 || y == 6)) f = ~f;   // K28.y: the other balanced form
    if (r && (ones(f, 4) != 2 || y == 3 || (k && x == 28))) f = ~f;
    r = ones(f, 4) == 2 ? r : ones(f, 4) > 2;
    return {a, f, r};
  endfunction
  // decode tables: {valid, k, byte} per RD
  logic [9:0] dt0 [0:1023], dt1 [0:1023];
  function automatic bit is_k(input logic [7:0] b);
    return b == 8'h1C || b == 8'h3C || b == 8'h5C || b == 8'h7C || b == 8'h9C || b == 8'hBC || b == 8'hDC ||
           b == 8'hFC || b == 8'hF7 || b == 8'hFB || b == 8'hFD || b == 8'hFE;
  endfunction
  initial begin
    logic [10:0] e;
    for (int i = 0; i < 1024; i++) begin dt0[i] = 0; dt1[i] = 0; end
    for (int k = 0; k < 2; k++)
      for (int b = 0; b < 256; b++)
        if (!k || is_k(b)) begin
          e = r_enc(b, k, 0); dt0[e[10:1]] = {1'b1, 1'(k), 8'(b)};
          e = r_enc(b, k, 1); dt1[e[10:1]] = {1'b1, 1'(k), 8'(b)};
        end
  end
  function automatic logic [9:0] r_dec(input logic [9:0] c, input bit rd);
    return rd ? dt1[c] : dt0[c];
  endfunction
  function automatic bit rd_after(input logic [9:0] c, input bit rd);
    logic [10:0] e;
    logic [9:0]  d;
    d = r_dec(c, rd);
    e = r_enc(d[7:0], d[8], rd);
    return e[0];
  endfunction

  localparam logic [7:0] K28_5 = 8'hBC, KS = 8'hFB, KT = 8'hFD, KR = 8'hF7, KV = 8'hFE,
                         D21_5 = 8'hB5, D2_2 = 8'h42, D5_6 = 8'hC5, D16_2 = 8'h50;
  localparam logic [15:0] ACK = 16'h4000;

  // ------------------------------ link partner: transmit ------------------------------
  int          lt_p;                     // partner link timer
  int          pa = 0;                   // partner AN: 0 restart, 1 ability, 2 ack, 3 complete ack, 4 idle, 5 link, 9 off
  int          pa_t = 0;
  logic [15:0] p_cfg = 16'h01A0;
  bit          prd = 0, peven = 1;       // partner TX running disparity / next position even
  int          pc = 0;                   // position in a /C/ or /I/
  logic [9:0]  pq [0:2047];              // queued packet groups {invalid, k, byte}
  int          pq_n = 0, pq_i = 0;
  bit          pkt_on = 0;
  int          inj = 0;                  // invalid code groups to send
  logic [9:0]  inj_code = 10'b1111111111;
  bit          rs_req = 0;               // restart AN at the next even position
  bit          p_hold = 0;               // hold the partner in ability (no acknowledge)
  bit          p_stay = 0;               // hold the partner in acknowledge
  int          bad_per = 0, bad_at = 0, bad_i = 0;   // group bad_at of every bad_per (from an even one) invalid
  int          c_bad = 0;                // /C/ high bytes to send as invalid groups
  int          odd_d = 0;                // /I/ second groups to send as D0.0
  logic [9:0]  pcode = 0, pprev = 0;
  int          off_k = 0;                // line delay in bits
  // expected GMII receive: bytes with {er, dv}; false carriers as their own entries
  logic [9:0]  rxe [0:65535];
  int          rxe_n = 0, rxe_i = 0;

  function automatic bit p_pkt();
    return pa > 3 && (pkt_on || (peven && pq_i < pq_n && pa == 5));
  endfunction
  // an invalid group leaves the running disparity of its last unbalanced sub-block
  function automatic bit inv_rd(input logic [9:0] c, input bit rd);
    if (ones(c, 4) != 2) return ones(c, 4) > 2;
    if (ones(c >> 4, 6) != 3) return ones(c >> 4, 6) > 3;
    return rd;
  endfunction
  function automatic logic [9:0] p_next();
    logic [15:0] c;
    if (pa <= 3) begin                   // /C/
      c = pa == 0 ? 16'h0000 : pa == 1 ? p_cfg : p_cfg | ACK;
      case (pc)
        0, 4: return {2'b01, K28_5};
        1: return {2'b00, D21_5};
        5: return {2'b00, D2_2};
        2, 6: return {2'b00, c[7:0]};
        default: return {2'b00, c[15:8]};
      endcase
    end
    if (p_pkt()) return pq[pq_i];
    if (peven) return {2'b01, K28_5};
    if (odd_d > 0) begin odd_d--; return {2'b00, 8'h00}; end
    return {2'b00, prd ? D16_2 : D5_6};
  endfunction
  // consecutive config words the partner sent with the same abilities / acknowledged
  int          p_abl_run = 0, p_ack_run = 0;
  logic [15:0] p_wlast = 0;
  bit          p_wbad = 0;
  always @(posedge clk) begin
    logic [15:0] cw;
    logic [9:0]  g;
    logic [10:0] e;
    logic [19:0] w;
    if (rs_req && peven) begin pa = 0; pa_t = lt_p; pc = 0; rs_req = 0; pkt_on = 0; pq_i = pq_n; p_abl_run = 0; p_ack_run = 0; end
    g = p_next();
    if (c_bad > 0 && pa <= 3 && (pc == 3 || pc == 7)) begin g[9] = 1; c_bad--; p_wbad = 1; end
    if (bad_per != 0) begin
      if (bad_i == bad_at) g[9] = 1;
      bad_i = (bad_i + 1) % bad_per;
    end
    if (p_pkt()) begin
      pkt_on = 1; pq_i++;
      if (pq_i == pq_n) begin
        pkt_on = 0;
        if (g[8:0] == {1'b1, KR} && peven) begin pq[pq_n++] = {2'b01, KR}; pkt_on = 1; end   // /T/ was odd
      end
    end else if (pa <= 3) begin
      pc = (pc + 1) % 8;
      if (pc == 0 || pc == 4) begin              // a /C/ sent: consecutive matching words
        cw = pa == 0 ? 16'h0 : pa == 1 ? p_cfg : p_cfg | ACK;
        if (p_wbad) begin p_abl_run = 0; p_ack_run = 0; end
        else begin
          p_abl_run = (cw & ~ACK) == (p_wlast & ~ACK) ? p_abl_run + 1 : 1;
          p_ack_run = (cw == p_wlast && cw[14]) ? p_ack_run + 1 : int'(cw[14]);
        end
        p_wlast = cw; p_wbad = 0;
      end
    end else begin p_abl_run = 0; p_ack_run = 0; end
    if (inj > 0 || g[9]) begin
      pcode = inj_code; prd = inv_rd(inj_code, prd);
      if (inj > 0) inj--;
    end else begin e = r_enc(g[7:0], g[8], prd); pcode = e[10:1]; prd = e[0]; end
    peven = !peven;
    w = {pprev, pcode};
    rx_code <= w[19 - off_k -: 10];
    pprev = pcode;
  end

  // queue a packet from the partner: n bytes after /S/ (b[0] is replaced by /S/),
  // error kinds per byte: 0 none, 1 /V/, 2 an invalid group, 3 a comma (early end),
// 4 another special code (/R/)
  logic [7:0] pk [0:2047];
  int         pk_err [0:2047];
  task automatic p_send(input int n);
    int st;
    while (pkt_on || pq_i < pq_n) @(posedge clk);
    pq_n = 0; pq_i = 0;
    pq[pq_n++] = {2'b01, KS};
    rxe[rxe_n++] = {8'h55, 2'b01};
    st = 1;
    for (int i = 1; i < n && st; i++)
      case (pk_err[i])
        1: begin pq[pq_n++] = {2'b01, KV}; rxe[rxe_n++] = {8'hxx, 2'b11}; end
        2: begin pq[pq_n++] = {2'b10, 8'h00}; rxe[rxe_n++] = {8'hxx, 2'b11}; end
        4: begin pq[pq_n++] = {2'b01, KR}; rxe[rxe_n++] = {8'hxx, 2'b11}; end
        3: begin pq[pq_n++] = {2'b01, K28_5}; rxe[rxe_n++] = {8'hxx, 2'b11}; st = 0; end   // early end
        default: begin pq[pq_n++] = {2'b00, pk[i]}; rxe[rxe_n++] = {pk[i], 2'b01}; end
      endcase
    if (st) begin pq[pq_n++] = {2'b01, KT}; pq[pq_n++] = {2'b01, KR}; end
    @(posedge clk);
  endtask
  // n invalid groups from an even position between packets: each one is a
  // false carrier while the PCS is in sync
  task automatic p_inject(input int n, input int n_fc);
    while (pkt_on || pq_i < pq_n) @(posedge clk);
    while (!peven) @(posedge clk);
    inj = n;
    for (int i = 0; i < n_fc; i++) rxe[rxe_n++] = {8'h0E, 2'b10};
    clocks(n + 1);
  endtask

  // ------------------------------ link partner: receive ------------------------------
  bit          mrd = 0, meven = 1, m_lock = 0;
  int          mos = 0;                  // position in an ordered set (0: none)
  logic [7:0]  mc1 = 0, mlo = 0;
  logic [15:0] m_last = 0, m_cfg_seen = 0;
  int          m_ncfg = 0, m_nack = 0, m_nidle = 0, m_ncfg0 = 0;
  bit          m_c1 = 0;                 // the last /C/ was /C1/
  int          m_cfgs = 0, m_idles = 0;
  // packets sent by the TB MAC and what the partner received
  logic [7:0]  tq [0:2047];
  bit          tq_er [0:2047];
  int          tq_n = 0;
  logic [7:0]  mp [0:2047];
  bit          mp_v [0:2047];
  int          mp_n = 0, n_tx_pkts = 0, n_tx_short = 0;
  bit          m_in = 0, m_r = 0, m_t_odd = 0;
  int          m_r_n = 0;

  task automatic m_pkt_done();
    int sh;
    // /S/ replaced byte 0, or byte 1 when the packet started on an odd position
    sh = tq_n - mp_n;
    if (sh != 1 && sh != 2) fail($sformatf("TX packet: %0d groups received for %0d bytes", mp_n, tq_n));
    else begin
      if (sh == 2) n_tx_short++;
      for (int i = 0; i < mp_n; i++)
        if (tq_er[i + sh] ? !mp_v[i] : (mp_v[i] || mp[i] !== tq[i + sh]))
          fail($sformatf("TX packet byte %0d: %h%s, expected %h%s", i + sh, mp[i], mp_v[i] ? "/V/" : "",
                         tq[i + sh], tq_er[i + sh] ? "/V/" : ""));
    end
    n_tx_pkts++;
  endtask

  always @(posedge clk) if (!rst_n) m_lock = 0; else begin
    logic [9:0] d;
    logic [7:0] b;
    bit k, r0;
    d = r_dec(tx_code, mrd);
    b = d[7:0]; k = d[8];
    r0 = mrd;
    if (!d[9]) begin
      if (m_lock) fail($sformatf("PCS sent an invalid code group %b (RD%s)", tx_code, mrd ? "+" : "-"));
      if (dt0[tx_code][9] || dt1[tx_code][9]) mrd = !mrd;   // lock on the right disparity
    end else mrd = rd_after(tx_code, mrd);
    if (d[9] && k && b == K28_5 && !m_lock) begin m_lock = 1; meven = 1; end
    if (m_lock && d[9]) begin
      if (k && b == K28_5) begin
        if (!meven) fail("comma on an odd position");
        if (m_in) fail("comma inside a TX packet");
        if (m_r && m_t_odd && m_r_n < 2) fail("/T/ on an odd position followed by one /R/");
        m_r = 0;
        mos = 1; meven = 1;
      end else if (mos == 1) begin
        mos = 0;
        if (b == D21_5 || b == D2_2) begin
          if ((b == D21_5) == m_c1 && m_cfgs > 0) fail("/C1/ and /C2/ do not alternate");
          m_c1 = b == D21_5; mos = 2;
        end else if (b == D5_6 || b == D16_2) begin
          if (mrd) fail("/I/ ends at RD+");
          if ((b == D16_2) != r0) fail("/I1/ / /I2/ chosen against the disparity");
          m_idles++; m_nidle++; m_ncfg = 0; m_nack = 0;
        end else fail($sformatf("ordered set K28.5 %h", b));
      end else if (mos == 2) begin mlo = b; mos = 3; end
      else if (mos == 3) begin
        mos = 0; m_cfgs++; m_nidle = 0;
        if ({b, mlo} == m_last) begin m_ncfg++; if ({b, mlo} & ACK) m_nack++; end
        else begin m_ncfg = 1; m_nack = ({b, mlo} & ACK) ? 1 : 0; end
        m_last = {b, mlo};
        m_ncfg0 = {b, mlo} == 0 ? m_ncfg0 + 1 : 0;
      end else if (k && b == KS) begin
        if (!meven) fail("/S/ on an odd position");
        m_in = 1; mp_n = 0;
      end else if (m_in) begin
        if (k && b == KT) begin m_in = 0; m_r = 1; m_r_n = 0; m_t_odd = !meven; m_pkt_done(); end
        else begin mp[mp_n] = b; mp_v[mp_n] = k && b == KV; mp_n++; if (k && b != KV) fail("special code in a TX packet"); end
      end else if (m_r && k && b == KR) m_r_n++;
      else fail($sformatf("stray code group %s%h", k ? "K" : "D", b));
    end
    meven = !meven;
  end

  // ------------------------------ partner auto-negotiation ------------------------------
  // the partner changes what it sends only between ordered sets
  always @(posedge clk) begin
    if (pa_t > 0) pa_t--;
    if (pa > 3 || pc == 0)
    case (pa)
      0: if (pa_t == 0) begin pa = 1; m_ncfg = 0; end
      1: if (m_ncfg >= 3 && m_last != 0 && !p_hold) pa = 2;
      2: if (m_nack >= 3 && !p_stay) begin pa = 3; pa_t = lt_p; end
      3: if (pa_t == 0) begin pa = 4; pa_t = lt_p; end
      4: if (pa_t == 0 && m_nidle >= 3) pa = 5;
      default: ;
    endcase
    if ((pa == 2 || pa == 3) && pc == 0 && m_ncfg0 >= 3 && !p_stay) begin pa = 0; pa_t = lt_p; end
  end
  // idle with group at of every per invalid (from an even group) for 60
  // clocks, starting out of sync: synchronisation never completes
  task automatic p_bad(input int per, input int at);
    @(negedge clk);
    while (!peven) @(negedge clk);
    bad_i = 0; bad_at = 1; bad_per = 2;  // out of sync first
    repeat (10) @(negedge clk);
    bad_i = 0; bad_at = at; bad_per = per;
    clocks(60);
    @(negedge clk); bad_per = 0;
    if (sync_ok) fail($sformatf("sync with group %0d of every %0d bad", at, per));
  endtask
  // restart AN on both sides
  task automatic an_rs(); @(negedge clk); an_restart = 1; @(negedge clk); an_restart = 0; p_restart(); endtask
  task automatic p_restart(); rs_req = 1; @(posedge clk); while (rs_req) @(posedge clk); endtask

  // ------------------------------ GMII receive checker ------------------------------
  int n_rx_pkts = 0, n_fc = 0, n_irq_err = 0, n_irq_link = 0, n_irq_an = 0, an_p = 0, an_q = 0;
  bit rx_check = 1;
  bit dv_q = 0;
  always @(posedge clk) if (rst_n) begin
    #1;
    if (grx_er && !irq_err) fail("grx_er without irq_err");
    an_q = int'(dut.an);
    if (an_q == 3 && an_p == 2 && p_abl_run < 3) fail($sformatf("ability detect after %0d matching words", p_abl_run));
    if (an_q == 4 && an_p == 3 && p_ack_run < 3) fail($sformatf("acknowledge detect after %0d words", p_ack_run));
    an_p = an_q;
    if (grx_dv || grx_er) begin
      if (rx_check) begin
        if (rxe_i >= rxe_n) fail($sformatf("GMII RX dv %b er %b %h, nothing expected", grx_dv, grx_er, grxd));
        else begin
          if ({grx_er, grx_dv} !== rxe[rxe_i][1:0] || (rxe[rxe_i][1:0] != 2'b11 && grxd !== rxe[rxe_i][9:2]))
            fail($sformatf("GMII RX %b%b %h, expected %b %h (entry %0d)", grx_er, grx_dv, grxd,
                           rxe[rxe_i][1:0], rxe[rxe_i][9:2], rxe_i));
          rxe_i++;
        end
      end
      if (!grx_dv) n_fc++;
    end
    if (dv_q && !grx_dv) n_rx_pkts++;
    dv_q = grx_dv;
    n_irq_err += irq_err; n_irq_link += irq_link; n_irq_an += irq_an;
  end

  // ------------------------------ MAC transmit ------------------------------
  task automatic mac_send(input int n, input int er_at = -1);
    @(negedge clk);
    tq_n = n;
    for (int i = 0; i < n; i++) begin
      tq[i] = i < 7 ? 8'h55 : i == 7 ? 8'hD5 : 8'($urandom);
      tq_er[i] = i == er_at;
    end
    for (int i = 0; i < n; i++) begin
      gtx_en = 1; gtxd = tq[i]; gtx_er = tq_er[i];
      @(negedge clk);
    end
    gtx_en = 0; gtx_er = $urandom; gtxd = $urandom;
    repeat (12) @(negedge clk);
    gtx_er = 0;
  endtask

  // ------------------------------ scenarios ------------------------------
  task automatic start(input int k, input bit sg, input bit aen, input logic [15:0] pcfg);
    rst_n = 0; mode_sgmii = sg; an_en = aen; p_cfg = pcfg; off_k = k;
    lt_p = sg ? LT_SG : LT_X;
    pa = aen ? 0 : 5; pa_t = lt_p; pc = 0; peven = 1; rs_req = 0;
    mrd = 0; m_lock = 0; m_cfgs = 0; m_c1 = 0; mos = 0; meven = 1; m_in = 0; m_r = 0; m_ncfg = 0; m_nack = 0; m_nidle = 0;
    rxe_n = 0; rxe_i = 0; pq_n = 0; pq_i = 0; pkt_on = 0;
    clocks(3); rst_n = 1;
    $display("-- start: offset %0d, %s, AN %s @%0t", k, sg ? "SGMII" : "1000BASE-X", aen ? "on" : "off", $time);
  endtask
  task automatic wait_link(input int lim = 6000);
    int t;
    t = 0;
    while (!link_up && t < lim) begin @(posedge clk); t++; end
    if (!link_up) fail($sformatf("no link (sync %b, AN state %0d, partner %0d)", sync_ok, dut.an, pa));
    clocks(4);
  endtask
  task automatic rx_pkt(input int n, input int e1 = 0, input int e1at = 0);
    for (int i = 0; i < n; i++) begin pk[i] = i < 7 ? 8'h55 : i == 7 ? 8'hD5 : 8'($urandom); pk_err[i] = 0; end
    if (e1 != 0) pk_err[e1at] = e1;
    p_send(n);
  endtask
  task automatic rx_drain();
    int t;
    t = 0;
    while ((pkt_on || pq_i < pq_n || rxe_i < rxe_n) && t < 20000) begin @(posedge clk); t++; end
    clocks(10);
    if (rxe_i != rxe_n) fail($sformatf("GMII RX: %0d of %0d expected entries seen", rxe_i, rxe_n));
  endtask

  initial begin
    int m0;
    // ---- sync at every bit offset, AN disabled ----
    for (int k = 0; k < 10; k++) begin
      start(k, 0, 0, 16'h0);
      wait_link(200);
      if (!sync_ok || an_done) fail("AN off: sync without AN");
      rx_pkt(70); rx_drain();
    end
    // ---- 1000BASE-X auto-negotiation ----
    start(3, 0, 1, 16'h01A0);
    if (link_up) fail("link up at reset");
    wait_link();
    if (lp_ability !== 16'h41A0 || !full_duplex || speed !== 2'b10) fail($sformatf("1000BASE-X result lp %h fd %b", lp_ability, full_duplex));
    rx_pkt(64); rx_pkt(200); rx_pkt(9); rx_drain();
    mac_send(64); mac_send(100, 40); mac_send(13); mac_send(66);
    // every ability bit set on both sides
    adv = 16'hFFFF;                      // the PCS sends ACK only in acknowledge
    start(2, 0, 1, 16'hBFFF);
    wait_link();
    if (lp_ability !== 16'hFFFF || !full_duplex) fail("all abilities");
    adv = 16'h01A0;
    // half duplex partner
    start(7, 0, 1, 16'h0040);
    wait_link();
    if (full_duplex || lp_ability !== 16'h4040) fail("half duplex partner");
    // ---- SGMII: speeds and link ----
    for (int s = 0; s < 3; s++) begin
      start(s * 3, 1, 1, 16'h8001 | (16'(s) << 10) | (s == 2 ? 16'h1000 : 16'h0));
      wait_link();
      if (speed !== 2'(s) || full_duplex !== (s == 2) || !link_up) fail($sformatf("SGMII speed %b fd %b", speed, full_duplex));
      mac_send(70);
    end
    // the PHY reports link down: AN completes, link_up stays low
    start(1, 1, 1, 16'h1001);
    clocks(3000);
    if (!an_done || link_up) fail("SGMII with the PHY's link bit clear");
    // ---- errors in received packets ----
    start(5, 0, 1, 16'h0020);
    wait_link();
    rx_pkt(40, 1, 20);                   // /V/
    rx_pkt(40, 3, 15);                   // comma: early end, odd and even position
    rx_pkt(40, 3, 14);
    rx_pkt(40, 4, 10);                   // /R/ inside a packet
    rx_pkt(30); rx_drain();
    // a bad code group in a packet, and outside one (false carrier)
    inj_code = 10'b0000011111;
    rx_pkt(30, 2, 12);
    p_inject(1, 1);
    rx_drain();
    // ---- loss of sync and recovery ----
    inj_code = 10'b1111111111;
    p_inject(3, 3); clocks(30);
    if (!sync_ok) fail("sync lost after three bad code groups");
    p_inject(4, 4); clocks(4);
    if (sync_ok || link_up) fail("sync kept after four bad code groups");
    // acquisition broken at each step: K x, K D x, K D K x, K D K D x, K D K D K x
    p_bad(2, 1); p_bad(4, 2); p_bad(4, 3); p_bad(6, 4); p_bad(6, 5);
    rx_drain();
    p_restart();
    wait_link();
    // ---- restarts: an_restart, the partner restarts ----
    @(negedge clk); an_restart = 1; @(negedge clk); an_restart = 0;
    clocks(2);
    if (an_done) fail("an_restart");
    p_restart();
    wait_link();
    p_restart();
    clocks(40);
    if (an_done) fail("partner restart not seen");
    wait_link();
    // the partner restarts while the PCS acknowledges or completes, and in idle detect
    for (int s = 3; s <= 5; s++) begin
      an_rs();
      if (s == 3) begin                  // two /C/ with a bad high byte: irq_err, no word
        m0 = n_irq_err; c_bad = 2;
        while (c_bad > 0) @(posedge clk);
        clocks(8);
        if (n_irq_err != m0 + 2) fail($sformatf("%0d irq_err for 2 bad config bytes", n_irq_err - m0));
      end
      if (s == 4) begin @(negedge clk); an_en = 0; clocks(3); an_en = 1; end
      while (int'(dut.an) < s) @(posedge clk);
      p_restart();
      wait_link();
    end
    $display("-- abilities change @%0t", $time);
    // the partner acknowledges other abilities than it first sent
    p_hold = 1;
    an_rs();
    while (int'(dut.an) != 3) @(posedge clk);
    while (pc != 0) @(posedge clk);
    p_cfg = p_cfg ^ 16'h0080; p_hold = 0;
    wait_link();
    if (lp_ability !== (p_cfg | ACK)) fail($sformatf("changed abilities: lp %h, partner %h", lp_ability, p_cfg));
    // the PCS restarts alone while the partner keeps acknowledging: the
    // acknowledges seen during restart count in acknowledge detect
    an_rs();
    while (pa != 2) @(posedge clk);
    p_stay = 1;
    while (int'(dut.an) != 4) @(posedge clk);
    @(negedge clk); an_restart = 1; @(negedge clk); an_restart = 0;
    while (int'(dut.an) != 4) @(posedge clk);
    p_stay = 0;
    wait_link();
    $display("-- packet in idle @%0t", $time);
    // a packet while the PCS still sends idle (not in data mode) is dropped
    an_rs();
    for (int t = 0; t < 20000 && !(int'(dut.an) == 5 && pa >= 4); t++) @(posedge clk);
    if (int'(dut.an) != 5) fail("idle detect not reached");
    pa = 5; rx_check = 0;
    rx_pkt(20);
    while (pkt_on || pq_i < pq_n) @(posedge clk);
    clocks(4); rxe_i = rxe_n; rx_check = 1;
    wait_link();
    // ---- random traffic both ways ----
    for (int t = 0; t < 40; t++) begin
      rx_pkt($urandom_range(9, 300), $urandom_range(3) == 0 ? 1 : 0, $urandom_range(1, 8));
      mac_send($urandom_range(9, 200), $urandom_range(3) == 0 ? $urandom_range(1, 8) : -1);
    end
    rx_drain();
    odd_d = 2; clocks(20);               // K28.5 D0.0: neither /C/ nor /I/
    // ---- reset with traffic ----
    rx_pkt(500); clocks(50); rst_n = 0; clocks(2);
    if (grx_dv || grx_er || sync_ok || an_done || link_up || irq_err || irq_an || irq_link)
      fail("outputs in reset");
    rst_n = 1;

    $display("SGMII: %0d RX packets, %0d TX packets (%0d started odd), %0d false carriers, %0d /C/, %0d /I/",
             n_rx_pkts, n_tx_pkts, n_tx_short, n_fc, m_cfgs, m_idles);
    if (errors == 0) $display("TEST PASSED: SGMII");
    else             $display("TEST FAILED: %0d errors", errors);
    $finish;
  end

  initial begin
    #20ms;
    $display("TIMEOUT"); $finish;
  end
endmodule
