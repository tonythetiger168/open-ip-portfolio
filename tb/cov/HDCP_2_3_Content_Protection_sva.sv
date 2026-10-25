// SPDX-License-Identifier: Apache-2.0
/*verilator coverage_off*/
// HDCP 2.3 transmitter: a cycle-level model fed only by the pins (register
// window, message channels, pixel stream) predicts every output on every
// clock: the authentication FSM with its nonces (its own xorshift64 from
// the reset seed), the AES-128 derivations (own AES: ks, E_km, H', the CTR
// keystream), the locality / message timeouts, the error flags, the
// keystream exhaustion and the register read data.
`include "cov_macros.svh"
module HDCP_2_3_Content_Protection_sva #(
  parameter int MSG_TIMEOUT = 255
)(
  input logic         clk, rst_n, reg_we, txm_valid, txm_ready, rxm_valid, rxm_ready,
  input logic         pix_valid, pix_ready, enc_valid, enc_ready, irq,
  input logic [2:0]   reg_addr,
  input logic [7:0]   reg_wdata, reg_rdata,
  input logic [3:0]   txm_type, rxm_type,
  input logic [127:0] txm_data, rxm_data,
  input logic [31:0]  pix_data, enc_data
);
  `COV_CLOCKING(clk, !rst_n)

  // AES S-box as one packed constant (entry x at bits [8x+7:8x]); a
  // 256-arm case inside a function is rejected by Verilator 5.052 (IMPURE)
  localparam logic [2047:0] SBOX_V = {
    256'h16bb54b00f2d99416842e6bf0d89a18cdf2855cee9871e9b948ed9691198f8e1,
    256'h9e1dc186b95735610ef6034866b53e708a8bbd4b1f74dde8c6b4a61c2e2578ba,
    256'h08ae7a65eaf4566ca94ed58d6d37c8e779e4959162acd3c25c2406490a3a32e0,
    256'hdb0b5ede14b8ee4688902a22dc4f816073195d643d7ea7c41744975fec130ccd,
    256'hd2f3ff1021dab6bcf5389d928f40a351a89f3c507f02f94585334d43fbaaefd0,
    256'hcf584c4a39becb6a5bb1fc20ed00d153842fe329b3d63b52a05a6e1b1a2c8309,
    256'h75b227ebe28012079a059618c323c7041531d871f1e5a534ccf73f362693fdb7,
    256'hc072a49cafa2d4adf04759fa7dc982ca76abd7fe2b670130c56f6bf27b777c63
  };
  function automatic logic [7:0] sbox(input logic [7:0] x);
    return SBOX_V[8*x +: 8];
  endfunction

  function automatic logic [7:0] xtime(input logic [7:0] a);
    xtime = {a[6:0], 1'b0} ^ (a[7] ? 8'h1b : 8'h00);
  endfunction
  function automatic logic [7:0] mul2(input logic [7:0] a); mul2 = xtime(a); endfunction
  function automatic logic [7:0] mul3(input logic [7:0] a); mul3 = xtime(a) ^ a; endfunction

  function automatic logic [127:0] sub_bytes(input logic [127:0] s);
    for (int i = 0; i < 16; i++) sub_bytes[127-8*i -: 8] = sbox(s[127-8*i -: 8]);
  endfunction

  function automatic logic [127:0] shift_rows(input logic [127:0] s);
    logic [7:0] b [0:15];
    begin
      for (int i = 0; i < 16; i++) b[i] = s[127-8*i -: 8];
      shift_rows = {b[0], b[5], b[10], b[15], b[4], b[9], b[14], b[3],
                    b[8], b[13], b[2], b[7], b[12], b[1], b[6], b[11]};
    end
  endfunction

  function automatic logic [31:0] mix_col(input logic [31:0] c);
    logic [7:0] b0, b1, b2, b3;
    begin
      b0 = c[31:24]; b1 = c[23:16]; b2 = c[15:8]; b3 = c[7:0];
      mix_col = {mul2(b0) ^ mul3(b1) ^ b2 ^ b3,
                 b0 ^ mul2(b1) ^ mul3(b2) ^ b3,
                 b0 ^ b1 ^ mul2(b2) ^ mul3(b3),
                 mul3(b0) ^ b1 ^ b2 ^ mul2(b3)};
    end
  endfunction
  function automatic logic [127:0] mix_columns(input logic [127:0] s);
    mix_columns = {mix_col(s[127:96]), mix_col(s[95:64]),
                   mix_col(s[63:32]), mix_col(s[31:0])};
  endfunction

  function automatic logic [7:0] rcon(input logic [3:0] r);
    case (r)
      4'd1: rcon = 8'h01; 4'd2: rcon = 8'h02; 4'd3: rcon = 8'h04;
      4'd4: rcon = 8'h08; 4'd5: rcon = 8'h10; 4'd6: rcon = 8'h20;
      4'd7: rcon = 8'h40; 4'd8: rcon = 8'h80; 4'd9: rcon = 8'h1b;
      default: rcon = 8'h36;
    endcase
  endfunction

  function automatic logic [127:0] key_next(input logic [127:0] k,
                                            input logic [3:0] r);
    logic [31:0] w0, w1, w2, w3, t;
    begin
      w0 = k[127:96]; w1 = k[95:64]; w2 = k[63:32]; w3 = k[31:0];
      t  = {sbox(w3[23:16]), sbox(w3[15:8]), sbox(w3[7:0]), sbox(w3[31:24])}
           ^ {rcon(r), 24'h0};
      w0 = w0 ^ t;
      w1 = w1 ^ w0;
      w2 = w2 ^ w1;
      w3 = w3 ^ w2;
      key_next = {w0, w1, w2, w3};
    end
  endfunction

  function automatic logic [127:0] aes128_enc(input logic [127:0] key,
                                              input logic [127:0] pt);
    logic [127:0] rk, s;
    begin
      rk = key;
      s  = pt ^ rk;
      for (int r = 1; r <= 9; r++) begin
        rk = key_next(rk, r[3:0]);
        s  = mix_columns(shift_rows(sub_bytes(s))) ^ rk;
      end
      rk = key_next(rk, 4'd10);
      aes128_enc = shift_rows(sub_bytes(s)) ^ rk;
    end
  endfunction

  function automatic logic [63:0] xs(input logic [63:0] s);
    logic [63:0] x;
    x = s ^ (s >> 12);
    x = x ^ (x << 25);
    xs = x ^ (x >> 27);
  endfunction

  localparam int IDLE = 0, AKE_INIT = 1, AKE_CERT = 2, PAIR_TX = 3, PAIR_RX = 4, LC_TX = 5,
                 LC_WAIT = 6, SKE_TX = 7, RPT_WAIT = 8, AUTH = 9;
  function automatic logic [3:0] want(input int st);   // expected message in a wait state
    want = (st == AKE_CERT) ? 4'd3 : (st == PAIR_RX) ? 4'd7 : (st == LC_WAIT) ? 4'd10 : 4'd12;
  endfunction

  int           st, wc;
  logic [127:0] km, ks;
  logic [3:0]   idx;
  logic [63:0]  rng, rtx, lv;
  logic [31:0]  hrx;
  logic         rpt, fail, exh, m_ev;
  logic [15:0]  ctr;
  logic [5:0]   err;
  logic [31:0]  m_ed;
  // coverage events
  logic v_auth, v_auth_rpt, v_pair_bad, v_lc_bad, v_lc_to, v_bad_type, v_msg_to, v_exh,
        v_start_busy, v_restart, v_set_wins, v_backpressure, v_lc_last, v_msg_last;

  wire w8 = (st == AKE_CERT) || (st == PAIR_RX) || (st == LC_WAIT) || (st == RPT_WAIT);
  wire m_txv  = (st == AKE_INIT) || (st == PAIR_TX) || (st == LC_TX) || (st == SKE_TX);
  wire m_pixr = (st == AUTH) && !exh && (!m_ev || enc_ready);

  always @(posedge clk or negedge rst_n) begin
    int           o_st;
    logic [127:0] o_km, a;
    logic [63:0]  o_rng;
    logic         take, bad;
    if (!rst_n) begin
      st = IDLE; wc = 0; km = 0; ks = 0; idx = 0; rng = 64'h9E37_79B9_7F4A_7C15; rtx = 0; lv = 0;
      hrx = 0; rpt = 0; fail = 0; exh = 0; m_ev = 0; ctr = 0; err = 0; m_ed = 0;
      {v_auth, v_auth_rpt, v_pair_bad, v_lc_bad, v_lc_to, v_bad_type, v_msg_to, v_exh,
       v_start_busy, v_restart, v_set_wins, v_backpressure, v_lc_last, v_msg_last} = '0;
    end else begin
      {v_auth, v_auth_rpt, v_pair_bad, v_lc_bad, v_lc_to, v_bad_type, v_msg_to, v_exh,
       v_start_busy, v_restart, v_set_wins, v_backpressure, v_lc_last, v_msg_last} = '0;
      o_st = st; o_km = km; o_rng = rng;
      take = pix_valid && m_pixr;
      bad  = w8 && rxm_valid && rxm_type != want(o_st);
      rng  = xs(o_rng);
      // register writes
      if (reg_we) begin
        if (reg_addr == 3'd4) idx = reg_wdata[3:0];
        else if (reg_addr == 3'd5) km[8 * idx +: 8] = reg_wdata;
        else if (reg_addr == 3'd0) begin
          if (reg_wdata[2]) begin err = 0; fail = 0; end
          if (reg_wdata[0]) begin
            if (o_st == IDLE || o_st == AUTH) begin
              err = 0; fail = 0; exh = 0; st = AKE_INIT; rtx = xs(o_rng);
              if (o_st == AUTH) v_restart = 1;
            end else v_start_busy = 1;
          end
        end
      end
      // authentication
      if (bad) begin err[3] = 1; fail = 1; st = IDLE; v_bad_type = 1; end
      else case (o_st)
        AKE_INIT: if (txm_ready) begin st = AKE_CERT; wc = MSG_TIMEOUT; end
        AKE_CERT: if (rxm_valid) begin
                    rpt = rxm_data[0]; hrx = rxm_data[95:64];
                    ks = aes128_enc(o_km, {rtx, rtx}); st = PAIR_TX;
                    if (wc == 0) v_msg_last = 1;
                  end else if (wc == 0) begin err[4] = 1; fail = 1; st = IDLE; v_msg_to = 1; end
                  else wc--;
        PAIR_TX:  if (txm_ready) begin st = PAIR_RX; wc = MSG_TIMEOUT; end
        PAIR_RX:  if (rxm_valid) begin
                    a = aes128_enc(o_km, {hrx, hrx, hrx, hrx});
                    if (rxm_data[31:0] == a[31:0]) begin st = LC_TX; lv = xs(o_rng); end
                    else begin err[1] = 1; fail = 1; st = IDLE; v_pair_bad = 1; end
                  end else if (wc == 0) begin err[4] = 1; fail = 1; st = IDLE; v_msg_to = 1; end
                  else wc--;
        LC_TX:    if (txm_ready) begin st = LC_WAIT; wc = 20; end
        LC_WAIT:  if (rxm_valid) begin
                    if (wc == 0) v_lc_last = 1;
                    if (rxm_data[63:0] == (lv ^ ks[63:0])) st = SKE_TX;
                    else begin err[2] = 1; fail = 1; st = IDLE; v_lc_bad = 1; end
                  end else if (wc == 0) begin err[0] = 1; fail = 1; st = IDLE; v_lc_to = 1; end
                  else wc--;
        SKE_TX:   if (txm_ready) begin
                    st = rpt ? RPT_WAIT : AUTH; wc = MSG_TIMEOUT; ctr = 0;
                    if (!rpt) v_auth = 1;
                  end
        RPT_WAIT: if (rxm_valid) begin st = AUTH; v_auth_rpt = 1; end
                  else if (wc == 0) begin err[4] = 1; fail = 1; st = IDLE; v_msg_to = 1; end
                  else wc--;
        default: ;
      endcase
      if (reg_we && reg_addr == 3'd0 && reg_wdata[2] && err != 0) v_set_wins = 1;
      // pixel pipeline (old state)
      if (o_st == AUTH) begin
        if (take) begin
          a = aes128_enc(ks, {rtx, 48'h0, ctr});
          m_ed = pix_data ^ a[127:96]; m_ev = 1;
          if (ctr == 16'hFFFF) begin exh = 1; err[5] = 1; v_exh = 1; end
          ctr++;
        end else begin
          if (m_ev && !enc_ready) v_backpressure = 1;
          if (m_ev && enc_ready) m_ev = 0;
        end
      end else m_ev = 0;
    end
  end

  // expected combinational outputs
  logic [3:0]   m_type;
  logic [127:0] m_data;
  logic [7:0]   m_rd;
  always_comb begin
    m_type = (st == AKE_INIT) ? 4'd2 : (st == PAIR_TX) ? 4'd4 : (st == LC_TX) ? 4'd9 : 4'd11;
    m_data = (st == AKE_INIT) ? {64'h0, rtx} :
             (st == PAIR_TX)  ? aes128_enc({hrx, hrx, hrx, hrx}, km) :
             (st == LC_TX)    ? {64'h0, lv} : (ks ^ km);
    case (reg_addr)
      3'd0: m_rd = 8'h00;
      3'd1: m_rd = {2'b00, exh, rpt, fail, st == AUTH, st == AUTH, st != IDLE};
      3'd2: m_rd = 8'h23;
      3'd3: m_rd = {2'b00, err};
      3'd4: m_rd = {4'h0, idx};
      3'd5: m_rd = km[8 * idx +: 8];
      3'd6: m_rd = 8'(st);
      default: m_rd = ks[8 * idx +: 8];
    endcase
  end

  // ---------------- assertions ----------------
  `SVA_RST(a_reset_outputs, !rst_n, !txm_valid && !rxm_ready && !pix_ready && !enc_valid && !irq)
  `SVA_INV(a_txm_valid, txm_valid == m_txv)
  `SVA_IMP(a_txm_message, txm_valid, txm_type == m_type && txm_data == m_data)
  `SVA_INV(a_rxm_ready, rxm_ready == w8)
  `SVA_INV(a_pix_ready, pix_ready == m_pixr)
  `SVA_INV(a_enc_valid, enc_valid == m_ev)
  `SVA_IMP(a_enc_data, enc_valid, enc_data == m_ed)
  `SVA_INV(a_irq, irq == (err != 0))
  `SVA_INV(a_reg_rdata, reg_rdata == m_rd)
  `SVA_NXT(a_enc_held_under_backpressure, enc_valid && !enc_ready, enc_valid && $stable(enc_data))

  // ---------------- functional coverage ----------------
  `FC(authenticated, v_auth)
  `FC(authenticated_via_repeater, v_auth_rpt)
  `FC(pairing_ack_mismatch, v_pair_bad)
  `FC(locality_mismatch, v_lc_bad)
  `FC(locality_timeout, v_lc_to)
  `FC(locality_answer_last_clock, v_lc_last)
  `FC(unexpected_message, v_bad_type)
  `FC(message_timeout, v_msg_to)
  `FC(message_answer_last_clock, v_msg_last)
  `FC(keystream_exhausted, v_exh)
  `FC(start_ignored_while_busy, v_start_busy)
  `FC(session_restarted_from_auth, v_restart)
  `FC(error_wins_over_clear, v_set_wins)
  `FC(pixel_backpressure, v_backpressure)
  `FC(tx_message_waits_for_ready, txm_valid && !txm_ready)
  `FC_RST(reset_during_authentication, rst_n && st != IDLE && st != AUTH ##1 !rst_n)
endmodule

bind HDCP_2_3_Content_Protection_top HDCP_2_3_Content_Protection_sva #(.MSG_TIMEOUT(MSG_TIMEOUT)) u_sva (.*);
