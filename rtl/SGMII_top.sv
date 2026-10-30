// SPDX-License-Identifier: Apache-2.0
// ============================================================================
// SGMII / 1000BASE-X PCS (IEEE 802.3 clause 36 and 37, Cisco SGMII MAC side)
// between a GMII MAC interface and a ten-bit SerDes interface, one code
// group per clock (125 MHz). Grown from the GMII datapath: the GMII side is
// the same byte-per-clock interface, now coded onto 8b/10b.
//   * Transmit (clause 36): the 8b/10b encoder with running disparity sends
//     /C/ ordered sets during auto-negotiation (K28.5 D21.5 or D2.2, then
//     the 16-bit config word, low byte first), /I/ between packets (K28.5
//     D5.6 when the running disparity is positive, else K28.5 D16.2), and
//     packets as /S/ (in place of the first preamble byte), data, /V/ for
//     gtx_er, then /T/ /R/, plus a second /R/ when /T/ fell on an odd
//     position, so the next /I/ starts on an even one. /I/ always ends at
//     RD-: /I1/ corrects a positive disparity, /I2/ keeps a negative one. A packet that
//     starts on an odd position loses one preamble byte.
//   * Receive: the code-group aligner finds a comma (bits a..g = 0011111 or
//     1100000) at any of the ten bit offsets while sync is lost, and keeps
//     that offset; the synchronisation state machine of figure 36-9 needs
//     three commas on even positions, each followed by a data group, and
//     drops sync after four bad code groups (three good ones in a row
//     undo one bad one). An invalid code group (not in the tables, or
//     against the running disparity) is bad, as is a comma on an odd
//     position.
//   * The receiver turns /S/ into a 0x55 preamble byte with grx_dv, passes
//     data, signals /V/ and bad code groups in a packet with grx_er, ends
//     the packet at /T/ (or, with grx_er, at a comma), and reports a stray
//     special or bad code group outside a packet as false carrier
//     (grx_er = 1, grxd = 0x0E, grx_dv = 0). Packets are only received
//     while auto-negotiation is done (or off).
//   * Auto-negotiation (clause 37): restart (config 0 for a link timer),
//     ability detect (three matching non-zero config words), acknowledge
//     detect (three matching with ACK, the same abilities), complete
//     acknowledge (a link timer), idle detect (a link timer and three /I/),
//     link OK. A restart comes from an_restart, enabling an_en, a loss of
//     sync, or three zero config words; three /C/ while the link is OK also
//     restart. In 1000BASE-X mode the PCS sends adv and resolves duplex as
//     adv[5] & lp[5] at 1000 Mb/s; in SGMII mode (MAC side) it sends 0x0001
//     (0x4001 with ACK), uses the shorter SGMII link timer and takes speed
//     lp[11:10], duplex lp[12] and the PHY's link lp[15] from the partner.
// link_up: sync and AN done (with the PHY's link bit in SGMII), or sync
// with an_en low. irq_link pulses when link_up changes, irq_an when AN
// completes, irq_err on a bad code group while in sync, a false carrier or
// an error in a packet.
// Not implemented: SGMII rate adaptation (at 10 / 100 Mb/s the MAC repeats
// each byte 100 / 10 times), carrier extension, EEE, the PHY side of SGMII
// and next pages.
// ============================================================================
module SGMII_top #(
  parameter int LT_X  = 1250000,       // 1000BASE-X link timer: 10 ms at 125 MHz
  parameter int LT_SG = 200000         // SGMII link timer: 1.6 ms
)(
  input  logic        clk,
  input  logic        rst_n,
  // GMII (MAC side)
  input  logic [7:0]  gtxd,
  input  logic        gtx_en,
  input  logic        gtx_er,
  output logic [7:0]  grxd,
  output logic        grx_dv,
  output logic        grx_er,
  // ten-bit interface: bit 9 is bit a, the first on the line
  output logic [9:0]  tx_code,
  input  logic [9:0]  rx_code,
  // control
  input  logic        mode_sgmii,
  input  logic        an_en,
  input  logic        an_restart,
  input  logic [15:0] adv,             // 1000BASE-X abilities ([5] FD, [6] HD, [8:7] pause, [13:12] RF)
  // status
  output logic        sync_ok,
  output logic        an_done,
  output logic        link_up,
  output logic [15:0] lp_ability,      // the partner's word ([14]: it acknowledged)
  output logic [1:0]  speed,           // 00 10, 01 100, 10 1000 Mb/s
  output logic        full_duplex,
  output logic        irq_link,
  output logic        irq_an,
  output logic        irq_err
);
  // ---------------- 8b/10b ----------------
  // symbols {a,b,c,d,e,i,f,g,h,j}, a in bit 9; tables give the RD- forms
  function logic [5:0] t6(input logic [4:0] x);
    case (x)
      5'd0:  t6 = 6'b100111; 5'd1:  t6 = 6'b011101; 5'd2:  t6 = 6'b101101; 5'd3:  t6 = 6'b110001;
      5'd4:  t6 = 6'b110101; 5'd5:  t6 = 6'b101001; 5'd6:  t6 = 6'b011001; 5'd7:  t6 = 6'b111000;
      5'd8:  t6 = 6'b111001; 5'd9:  t6 = 6'b100101; 5'd10: t6 = 6'b010101; 5'd11: t6 = 6'b110100;
      5'd12: t6 = 6'b001101; 5'd13: t6 = 6'b101100; 5'd14: t6 = 6'b011100; 5'd15: t6 = 6'b010111;
      5'd16: t6 = 6'b011011; 5'd17: t6 = 6'b100011; 5'd18: t6 = 6'b010011; 5'd19: t6 = 6'b110010;
      5'd20: t6 = 6'b001011; 5'd21: t6 = 6'b101010; 5'd22: t6 = 6'b011010; 5'd23: t6 = 6'b111010;
      5'd24: t6 = 6'b110011; 5'd25: t6 = 6'b100110; 5'd26: t6 = 6'b010110; 5'd27: t6 = 6'b110110;
      5'd28: t6 = 6'b001110; 5'd29: t6 = 6'b101110; 5'd30: t6 = 6'b011110; default: t6 = 6'b101011;
    endcase
  endfunction
  function logic [3:0] t4(input logic [2:0] y, input logic k28);
    case (y)
      3'd0: t4 = 4'b1011;
      3'd1: t4 = k28 ? 4'b0110 : 4'b1001;
      3'd2: t4 = k28 ? 4'b1010 : 4'b0101;
      3'd3: t4 = 4'b1100;
      3'd4: t4 = 4'b1101;
      3'd5: t4 = k28 ? 4'b0101 : 4'b1010;
      3'd6: t4 = k28 ? 4'b1001 : 4'b0110;
      default: t4 = 4'b1110;
    endcase
  endfunction
  function logic unbal6(input logic [5:0] s);
    unbal6 = {2'd0, s[0]} + {2'd0, s[1]} + {2'd0, s[2]} + {2'd0, s[3]} + {2'd0, s[4]} + {2'd0, s[5]} != 3'd3;
  endfunction
  function logic unbal4(input logic [3:0] s);
    unbal4 = {2'd0, s[0]} + {2'd0, s[1]} + {2'd0, s[2]} + {2'd0, s[3]} != 3'd2;
  endfunction
  // {symbol, RD after}; rd = 1: RD+
  function logic [10:0] enc(input logic [7:0] d, input logic k, input logic rd);
    logic [5:0] s6;
    logic [3:0] s4;
    logic       r, k28;
    k28 = k && d[4:0] == 5'd28;
    s6 = k28 ? 6'b001111 : t6(d[4:0]);
    r = rd;
    if (r && (unbal6(s6) || s6 == 6'b111000)) s6 = ~s6;
    if (unbal6(s6)) r = !r;
    if (d[7:5] == 3'd7 && (k || (!r && (d[4:0] == 5'd17 || d[4:0] == 5'd18 || d[4:0] == 5'd20))
                            || (r && (d[4:0] == 5'd11 || d[4:0] == 5'd13 || d[4:0] == 5'd14))))
      s4 = 4'b0111;
    else s4 = t4(d[7:5], k28);
    if (r && (unbal4(s4) || d[7:5] == 3'd3 || k28)) s4 = ~s4;
    if (unbal4(s4)) r = !r;
    enc = {s6, s4, r};
  endfunction
  // 6b -> {valid, x}; both forms
  function logic [5:0] d6(input logic [5:0] s);
    logic [5:0] m;
    d6 = 6'd0;
    for (int x = 0; x < 32; x++) begin : b_d6
      m = t6(5'(x));
      if (s == m || (s == ~m && (unbal6(m) || x == 7))) d6 = {1'b1, 5'(x)};
    end
  endfunction
  // 4b -> y (7 when nothing else matches); K28: the 6b form fixes the
  // column (kinv: 001111 was sent, the RD+ column follows)
  function logic [2:0] d4(input logic [3:0] s, input logic k28, input logic kinv);
    logic [3:0] m;
    d4 = 3'd7;
    for (int y = 0; y < 7; y++) begin : b_d4
      m = t4(3'(y), k28);
      if (k28 ? s == (kinv ? ~m : m) : (s == m || (s == ~m && (unbal4(m) || y == 3)))) d4 = 3'(y);
    end
  endfunction

  localparam logic [7:0] K28_5 = 8'hBC, K27_7 = 8'hFB, K29_7 = 8'hFD, K23_7 = 8'hF7, K30_7 = 8'hFE,
                         D21_5 = 8'hB5, D2_2 = 8'h42, D5_6 = 8'hC5, D16_2 = 8'h50;
  localparam logic [15:0] ACK = 16'h4000;

  // ---------------- auto-negotiation state (used by both directions) ----------------
  typedef enum logic [2:0] { A_DIS, A_RESTART, A_ABIL, A_ACKD, A_CACK, A_IDLED, A_OK } an_t;
  an_t an;
  wire [1:0] xmit = (an == A_DIS || an == A_OK) ? 2'd2 : (an == A_IDLED) ? 2'd1 : 2'd0;   // 0 CONFIG, 1 IDLE, 2 DATA
  wire [15:0] my_cfg = (an == A_RESTART) ? 16'h0000 :
                       ((mode_sgmii ? 16'h0001 : adv & ~ACK) | ((an == A_ACKD || an == A_CACK) ? ACK : 16'h0000));

  // ---------------- transmit ----------------
  typedef enum logic [1:0] { T_IDLE, T_PKT, T_R, T_R2 } tx_t;
  tx_t        ts;
  logic       trd, todd;                // running disparity (1: RD+); position of the next group
  logic [2:0] tc;                       // position in a /C/ (0..7) or /I/ (0..1) ordered set
  logic [1:0] txm;                      // xmit latched at ordered-set boundaries
  logic [15:0] tcfg;
  logic [7:0] tb;
  logic       tk;

  always_comb begin
    tk = 1'b0; tb = gtxd;
    if (ts == T_PKT) begin
      if (!gtx_en)      begin tk = 1'b1; tb = K29_7; end
      else if (gtx_er)  begin tk = 1'b1; tb = K30_7; end
    end else if (ts == T_R || ts == T_R2) begin tk = 1'b1; tb = K23_7; end
    else if (txm == 2'd0)
      case (tc)
        3'd0, 3'd4: begin tk = 1'b1; tb = K28_5; end
        3'd1:       tb = D21_5;
        3'd5:       tb = D2_2;
        3'd2, 3'd6: tb = tcfg[7:0];
        default:    tb = tcfg[15:8];
      endcase
    else if (!todd && txm == 2'd2 && gtx_en) begin tk = 1'b1; tb = K27_7; end
    else if (!todd) begin tk = 1'b1; tb = K28_5; end
    else tb = trd ? D16_2 : D5_6;       // /I2/ after a K28.5 that left RD+, else /I1/
  end
  wire [10:0] te = enc(tb, tk, trd);

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      ts <= T_IDLE; trd <= 1'b0; todd <= 1'b0; tc <= '0; txm <= 2'd1; tcfg <= '0; tx_code <= '0;
    end else begin
      tx_code <= te[10:1]; trd <= te[0]; todd <= !todd;
      case (ts)
        T_IDLE:
          if (txm == 2'd0) begin
            tc <= tc + 3'd1;
            if (tc == 3'd7) begin txm <= xmit; tcfg <= my_cfg; end
          end else if (todd) txm <= xmit;
          else if (txm == 2'd2 && gtx_en) ts <= T_PKT;
        T_PKT: if (!gtx_en) ts <= T_R;
        T_R:   if (!todd) ts <= T_R2; else ts <= T_IDLE;  // /T/ was on an odd position
        default: ts <= T_IDLE;
      endcase
      if (ts == T_IDLE && txm != 2'd0 && todd && xmit == 2'd0) begin tc <= '0; tcfg <= my_cfg; end
    end
  end

  // ---------------- receive: alignment ----------------
  logic [9:0] rprev, cg;
  logic [3:0] off;
  wire  [19:0] win = {rprev, rx_code};
  logic [9:0] comma_at;                 // a comma starts at bit offset o
  always_comb
    for (int o = 0; o < 10; o++)
      comma_at[o] = win[19-o -: 7] == 7'b0011111 || win[19-o -: 7] == 7'b1100000;
  logic [3:0] first_comma;
  always_comb begin
    first_comma = 4'd0;
    for (int o = 9; o >= 0; o--) if (comma_at[o]) first_comma = 4'(o);
  end

  // ---------------- receive: decode ----------------
  logic       rrd;                      // running disparity
  wire [5:0]  dx  = d6(cg[9:4]);
  wire        k28 = cg[9:4] == 6'b001111 || cg[9:4] == 6'b110000;
  wire [2:0]  dy  = d4(cg[3:0], k28, cg[9:4] == 6'b001111);
  wire        kx  = k28 || ((dx[4:0] == 5'd23 || dx[4:0] == 5'd27 || dx[4:0] == 5'd29 || dx[4:0] == 5'd30)
                            && (cg[3:0] == 4'b0111 || cg[3:0] == 4'b1000));
  wire [7:0]  db  = {dy, k28 ? 5'd28 : dx[4:0]};
  wire [10:0] e_same = enc(db, kx, rrd);
  wire        valid = (dx[5] || k28) && e_same[10:1] == cg;
  wire        comma = cg[9:3] == 7'b0011111 || cg[9:3] == 7'b1100000;
  // running disparity after this group, valid or not: the last unbalanced sub-block decides
  wire        ones6 = {2'd0, cg[9]} + {2'd0, cg[8]} + {2'd0, cg[7]} + {2'd0, cg[6]} + {2'd0, cg[5]} + {2'd0, cg[4]} > 3'd3;
  wire        ones4 = {2'd0, cg[3]} + {2'd0, cg[2]} + {2'd0, cg[1]} + {2'd0, cg[0]} > 3'd2;
  wire        rd6 = unbal6(cg[9:4]) ? ones6 : rrd;
  wire        rd_n = valid ? e_same[0] : unbal4(cg[3:0]) ? ones4 : rd6;

  // ---------------- receive: synchronisation (figure 36-9) ----------------
  typedef enum logic [3:0] { S_LOSS, S_CD1, S_AS1, S_CD2, S_AS2, S_CD3, S_SA1, S_SA2, S_SA3, S_SA4 } sy_t;
  sy_t        sy;
  logic       reven;                    // this group is on an even position
  logic [1:0] good;
  wire        cgbad = !valid || (comma && !reven);

  // ---------------- receive: ordered sets and packets ----------------
  typedef enum logic [2:0] { R_IDLE, R_OS1, R_CFG1, R_CFG2, R_PKT, R_END } rx_t;
  rx_t        rs;
  logic [7:0] cfg_lo;
  logic       ev_cfg, ev_idle;          // an ordered set was received
  logic [15:0] ev_val;

  // ---------------- auto-negotiation ----------------
  logic [15:0] last_cfg;
  logic [1:0]  n_abl, n_ack, n_idl;     // consecutive matches (saturate at 3)
  localparam int LTW = $clog2((LT_X > LT_SG ? LT_X : LT_SG) + 1);
  logic [LTW-1:0] lt;                   // link timer
  logic        sync_q, link_q;
  wire  [LTW-1:0] lt_max = mode_sgmii ? LTW'(LT_SG) : LTW'(LT_X);
  // a match on the third word (a new sequence of config words), and a match
  // on the third word or later: ability / acknowledge detect take the
  // latter, as the words may have started while the state before ran
  wire         abl_same  = ev_cfg && (ev_val & ~ACK) == (last_cfg & ~ACK);
  wire         abl_match = abl_same && n_abl == 2'd2;
  wire         abl_held  = abl_same && n_abl[1];
  wire         ack_held  = ev_cfg && n_ack[1] && ev_val == last_cfg && ev_val[14];
  wire         idl_match = n_idl == 2'd3;

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      rprev <= '0; cg <= '0; off <= '0; rrd <= 1'b0; sy <= S_LOSS; reven <= 1'b0; good <= '0;
      rs <= R_IDLE; cfg_lo <= '0; ev_cfg <= 1'b0; ev_idle <= 1'b0; ev_val <= '0;
      grxd <= '0; grx_dv <= 1'b0; grx_er <= 1'b0; irq_err <= 1'b0;
    end else begin
      rprev <= rx_code;
      cg <= win[19 - off -: 10];
      if (sy == S_LOSS && comma_at != 0) begin off <= first_comma; cg <= win[19 - first_comma -: 10]; end
      rrd <= rd_n;
      reven <= !reven;
      ev_cfg <= 1'b0; ev_idle <= 1'b0; irq_err <= 1'b0;
      grx_dv <= 1'b0; grx_er <= 1'b0; grxd <= '0;

      // synchronisation
      case (sy)
        S_LOSS: if (comma) begin sy <= S_CD1; reven <= 1'b0; end
        S_CD1: sy <= (valid && !kx) ? S_AS1 : S_LOSS;
        S_CD2: sy <= (valid && !kx) ? S_AS2 : S_LOSS;
        S_CD3: sy <= (valid && !kx) ? S_SA1 : S_LOSS;
        S_AS1: if (cgbad) sy <= S_LOSS; else if (comma) sy <= S_CD2;
        S_AS2: if (cgbad) sy <= S_LOSS; else if (comma) sy <= S_CD3;
        S_SA1: if (cgbad) begin sy <= S_SA2; good <= '0; end
        // SA2..SA4: one step down per bad group, one up per three good ones
        S_SA2: if (cgbad) begin sy <= S_SA3; good <= '0; end
               else if (good == 2'd2) begin sy <= S_SA1; good <= '0; end
               else good <= good + 2'd1;
        S_SA3: if (cgbad) begin sy <= S_SA4; good <= '0; end
               else if (good == 2'd2) begin sy <= S_SA2; good <= '0; end
               else good <= good + 2'd1;
        default:                                          // S_SA4
               if (cgbad) begin sy <= S_LOSS; good <= '0; end
               else if (good == 2'd2) begin sy <= S_SA3; good <= '0; end
               else good <= good + 2'd1;
      endcase

      // ordered sets and packets, while in sync
      if (sync_ok) begin
        if (cgbad) irq_err <= 1'b1;
        case (rs)
          R_IDLE, R_END:
            if (comma && reven) rs <= R_OS1;
            else if (valid && kx && db == K27_7 && reven && xmit == 2'd2) begin
              rs <= R_PKT; grx_dv <= 1'b1; grxd <= 8'h55;
            end else if (rs == R_END && valid && kx && db == K23_7) ;   // /R/ after /T/
            else if (!valid || kx) begin
              rs <= R_IDLE;
              if (xmit == 2'd2) begin grx_er <= 1'b1; grxd <= 8'h0E; irq_err <= 1'b1; end   // false carrier
            end else rs <= R_IDLE;
          R_OS1: begin
            if (valid && !kx && (db == D21_5 || db == D2_2)) rs <= R_CFG1;
            else begin
              rs <= R_IDLE;
              if (valid && !kx && (db == D5_6 || db == D16_2)) ev_idle <= 1'b1;
            end
          end
          R_CFG1: begin cfg_lo <= db; rs <= valid && !kx ? R_CFG2 : R_IDLE; end
          R_CFG2: begin
            rs <= R_IDLE;
            if (valid && !kx) begin ev_cfg <= 1'b1; ev_val <= {db, cfg_lo}; end
          end
          default:                                        // R_PKT
            if (valid && kx && db == K29_7) rs <= R_END;
            else if (comma) begin                         // early end
              grx_dv <= 1'b1; grx_er <= 1'b1; irq_err <= 1'b1; rs <= reven ? R_OS1 : R_IDLE;
            end else begin
              grx_dv <= 1'b1; grxd <= db;
              if (!valid || kx) begin grx_er <= 1'b1; irq_err <= 1'b1; end
            end
        endcase
      end else rs <= R_IDLE;
    end
  end
  assign sync_ok = sy == S_SA1 || sy == S_SA2 || sy == S_SA3 || sy == S_SA4;

  // ---------------- auto-negotiation (clause 37) ----------------
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      an <= A_DIS; last_cfg <= '0; n_abl <= '0; n_ack <= '0; n_idl <= '0; lt <= '0;
      lp_ability <= '0; sync_q <= 1'b0; link_q <= 1'b0; irq_link <= 1'b0; irq_an <= 1'b0;
    end else begin
      sync_q <= sync_ok; link_q <= link_up;
      irq_link <= link_up != link_q; irq_an <= 1'b0;
      // match counters
      if (ev_cfg) begin
        last_cfg <= ev_val; n_idl <= '0;
        n_abl <= (ev_val & ~ACK) == (last_cfg & ~ACK) ? (n_abl == 2'd3 ? 2'd3 : n_abl + 2'd1) : 2'd1;
        n_ack <= ev_val == last_cfg && ev_val[14] ? (n_ack == 2'd3 ? 2'd3 : n_ack + 2'd1) : {1'b0, ev_val[14]};
      end
      if (ev_idle) begin n_abl <= '0; n_ack <= '0; if (n_idl != 2'd3) n_idl <= n_idl + 2'd1; end
      if (!sync_ok) begin n_abl <= '0; n_ack <= '0; n_idl <= '0; end
      // link timer
      if (lt != 0) lt <= lt - 1'b1;

      if (!an_en) an <= A_DIS;
      else if (an == A_DIS || an_restart || (sync_q && !sync_ok)) begin
        an <= A_RESTART; lt <= lt_max;
      end else if (abl_match && ev_val == 16'h0000 && (an == A_ACKD || an == A_CACK)) begin
        an <= A_RESTART; lt <= lt_max;                                  // the partner restarted
      end else
        case (an)
          A_RESTART: if (lt == 0) an <= A_ABIL;
          A_ABIL:    if (abl_held && ev_val != 0) begin an <= A_ACKD; lp_ability <= ev_val; end
          A_ACKD:
            if (ack_held) begin
              an <= A_RESTART; lt <= lt_max;                            // abilities changed
              if ((ev_val & ~ACK) == (lp_ability & ~ACK)) begin an <= A_CACK; lp_ability <= ev_val; end
            end
          A_CACK:    if (lt == 0) begin an <= A_IDLED; lt <= lt_max; n_idl <= '0; end
          A_IDLED:
            if (abl_match) begin an <= A_RESTART; lt <= lt_max; end
            else if (lt == 0 && idl_match) begin an <= A_OK; irq_an <= 1'b1; end
          default:                                                      // A_OK
            if (abl_match) begin an <= A_RESTART; lt <= lt_max; end
        endcase
    end
  end
  assign an_done     = an == A_OK;
  assign link_up     = sync_ok && (!an_en || (an == A_OK && (!mode_sgmii || lp_ability[15])));
  assign speed       = mode_sgmii ? lp_ability[11:10] : 2'b10;
  assign full_duplex = mode_sgmii ? lp_ability[12] : adv[5] && lp_ability[5];
endmodule
