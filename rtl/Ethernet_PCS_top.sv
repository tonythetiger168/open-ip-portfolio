// SPDX-License-Identifier: Apache-2.0
// ============================================================================
// Ethernet_PCS_top v1.0: 400GBASE-R PCS data path around the RS(544,514)
// FEC (IEEE 802.3 clause 119), transmit and receive, on two instances of
// Ethernet_RS_FEC_top (codewords A and B).
// ----------------------------------------------------------------------------
//  Bit order: bit 0 of every vector is the first bit sent. A 66-bit block
//  has its sync header in [1:0] (data 2'b10, control 2'b01: the first bit
//  sent is 0 for data) and its payload in [65:2]; a control block's block
//  type field is [9:2]. A group is four blocks, block j at [66j +: 66].
//
//  Transmit, one group per clock at most:
//   - 256B/257B transcoding (119.2.4.2 / 91.5.2.5): four data blocks give
//     header 1 and the four payloads; otherwise header 0, a flag per block
//     (1: data) and the payloads without the second nibble of the first
//     control block's type field. A group with an invalid sync header gives
//     all flags 1 (the receiver sees an invalid block).
//   - Scrambler 1 + x^39 + x^58, self-synchronizing, over all 257 bits.
//   - Alignment marker group (119.2.4.4.2) at the start of every AMP-th
//     pair of FEC messages (first after reset): the 16 lane markers of
//     Table 119-2, 10-bit interleaved, a 133-bit free-running PRBS9 pad
//     (x^9 + x^5 + 1) and the 3 status bits tx_am_sf: eight 257-bit blocks,
//     not scrambled. tx_in_ready is low for those 8 block times: the room
//     for the markers comes from the MAC side (idle deletion), not here.
//   - Pre-FEC distribution (119.2.4.5): 40 blocks (10280 bits) make two
//     514-symbol messages, the even 10-bit symbols to A, the odd to B.
//   - RS(544,514) encoding (Ethernet_RS_FEC_top, 32 symbols a beat).
//   - Symbol distribution (119.2.4.7): tx_out_data carries 64 symbols of
//     the interleaved pair a clock, symbol n at [10n +: 10], 17 beats a
//     pair (tx_out_first on the first); symbol n of a beat goes to PCS lane
//     n mod 16. Lane distribution to the PMA is outside the core.
//  Receive (input: the de-skewed, re-ordered lanes as the same 64-symbol
//  beats, rx_in_first on the first beat of a pair):
//   - the inverse distribution, RS decoding of A and B, the inverse pre-FEC
//     distribution into 257-bit blocks;
//   - marker lock: until a marker group (all 1920 marker bits) is found in
//     the first eight blocks of a pair nothing comes out; locked, the group
//     is expected every AMP pairs and removed (rx_am_sf takes its status
//     bits); a missing group of a correctable pair, or a group off its
//     period, pulses ev_am_err; three missing in a row drop the lock;
//   - descrambling and reverse transcoding into groups on rx_out_*. A
//     transcoded block with header 0 and all flags 1, or a first control
//     block type nibble that is not one of the 11 clause 82 types, gives
//     four blocks with sync header 2'b11 (ev_itb); so does every block of
//     a pair in which a codeword was uncorrectable (the FEC's d_out_bad,
//     which cfg_bypass_ind turns off).
//  Not implemented: 64B/66B encoding, idle deletion / insertion, the
//  per-lane alignment marker lock, deskew and lane reordering, BIP-free
//  lane error counters, the FEC_degraded_SER detector, the 200GBASE-R
//  (8-lane) variant, the test-pattern generators, EEE.
// ============================================================================
module Ethernet_PCS_top #(
  parameter int AMP = 4096              // pairs of FEC codewords per marker period (163840 blocks)
) (
  input  logic         clk,
  input  logic         rst_n,
  input  logic         cfg_bypass_corr,
  input  logic         cfg_bypass_ind,
  input  logic [2:0]   tx_am_sf,
  // transmit
  input  logic         tx_in_valid,
  input  logic [263:0] tx_in_data,
  output logic         tx_in_ready,
  output logic         tx_out_valid,
  output logic         tx_out_first,
  output logic [639:0] tx_out_data,
  input  logic         tx_out_ready,
  // receive
  input  logic         rx_in_valid,
  input  logic         rx_in_first,
  input  logic [639:0] rx_in_data,
  output logic         rx_in_ready,
  output logic         rx_out_valid,
  output logic [263:0] rx_out_data,
  input  logic         rx_out_ready,
  // status
  output logic         rx_am_lock,
  output logic [2:0]   rx_am_sf,
  output logic         ev_am_err,
  output logic         ev_itb,
  output logic         ev_corr_a,
  output logic         ev_corr_b,
  output logic         ev_uncorr_a,
  output logic         ev_uncorr_b,
  output logic         ev_resync,
  output logic [3:0]   st_nsym_a,
  output logic [3:0]   st_nsym_b
);
  localparam int PW = AMP > 1 ? $clog2(AMP) : 1;

  // ---- BEGIN GENERATED TABLES (scripts/ethpcs/gen_tables.py; do not edit by hand)
  // AMG: the alignment marker group without its pad and status bits
  localparam logic [1919:0] AMG = {
    384'h592196a0f12731e8ab0c5e6920d8baa90bd0ca0415443a309567546ee0c124a3bc3aedfdccc868ef54e6ada78cafb63e,
    384'h6397d12735e76c1025ee25665e6a6f0c958e3d84f07556da1746f2f41561faf3fbeeaf6a5ceb99873f119c5db5113cf3,
    384'h20271379994abc722589d50c6a1958c2e492a11a3ef6981d1d9b6bdb364d876fd8b6ed8b69dbb6ed9369d9f66d5b56d5,
    384'hb56d5b56d5b56d5b56d5b56d5b56d5b565d966519465d95655956519465d976559565994d090250982b0ba2aca0288bd,
    384'h2c8a126886210b626499264992649926499264992649926499264992a6a9aa6a9aa6a9aa6a9aa6a9aa6a9aa6a9aa6a9a};
  // ---- END GENERATED TABLES

  // ---------------- functions ----------------
  // scrambler 1 + x^39 + x^58: h holds the last 58 line bits, the newest in bit 57
  function automatic logic [314:0] scr(input logic [57:0] h, input logic [256:0] x, input logic de);
    logic [256:0] o;
    logic         b;
    for (int i = 0; i < 257; i++) begin
      b = x[i] ^ h[19] ^ h[0];
      o[i] = b;
      h = {de ? x[i] : b, h[57:1]};
    end
    scr = {h, o};
  endfunction
  function automatic logic [256:0] xcode(input logic [263:0] g);
    logic [255:0] p;
    logic [3:0]   m;
    logic         ok;
    for (int j = 0; j < 4; j++) begin
      p[64 * j +: 64] = g[66 * j + 2 +: 64];
      m[j] = g[66 * j + 1];
    end
    ok = 1'b1;
    for (int j = 0; j < 4; j++) ok = ok & (g[66 * j] ^ g[66 * j + 1]);
    if (!ok) m = 4'hF;
    if (ok && m == 4'hF) xcode = {p, 1'b1};
    else if (!ok || !m[0]) xcode = {p[255:8], p[3:0], m, 1'b0};
    else if (!m[1]) xcode = {p[255:72], p[67:0], m, 1'b0};
    else if (!m[2]) xcode = {p[255:136], p[131:0], m, 1'b0};
    else xcode = {p[255:200], p[195:0], m, 1'b0};
  endfunction
  // the high nibble of a clause 82 block type from its low (first sent) nibble; 0: none
  function automatic logic [4:0] btf_hi(input logic [3:0] n);
    case (n)
      4'hE: btf_hi = 5'h11;
      4'h8: btf_hi = 5'h17;
      4'hB: btf_hi = 5'h14;
      4'h7: btf_hi = 5'h18;
      4'h9: btf_hi = 5'h19;
      4'hA: btf_hi = 5'h1A;
      4'h4: btf_hi = 5'h1B;
      4'hC: btf_hi = 5'h1C;
      4'h2: btf_hi = 5'h1D;
      4'h1: btf_hi = 5'h1E;
      4'hF: btf_hi = 5'h1F;
      default: btf_hi = 5'h00;
    endcase
  endfunction
  // {invalid, group}
  function automatic logic [264:0] rxcode(input logic [256:0] x);
    logic [255:0] p;
    logic [3:0]   m, nib;
    logic [4:0]   hn;
    logic         bad;
    m = x[4:1];
    bad = 1'b0;
    if (x[0]) begin p = x[256:1]; m = 4'hF; end
    else if (m == 4'hF) begin p = {4'd0, x[256:5]}; bad = 1'b1; end
    else begin
      if (!m[0]) nib = x[8:5];
      else if (!m[1]) nib = x[72:69];
      else if (!m[2]) nib = x[136:133];
      else nib = x[200:197];
      hn = btf_hi(nib);
      bad = !hn[4];
      if (!m[0]) p = {x[256:9], hn[3:0], x[8:5]};
      else if (!m[1]) p = {x[256:73], hn[3:0], x[72:5]};
      else if (!m[2]) p = {x[256:137], hn[3:0], x[136:5]};
      else p = {x[256:201], hn[3:0], x[200:5]};
    end
    for (int j = 0; j < 4; j++)
      rxcode[66 * j +: 66] = {p[64 * j +: 64], bad ? 2'b11 : m[j] ? 2'b10 : 2'b01};
    rxcode[264] = bad;
  endfunction

  // ---------------- transmit ----------------
  logic [5:0]   tpb;                    // block of the pair being formed
  logic [PW-1:0] tpc;                   // pair in the marker period
  logic [57:0]  tsh;                    // scrambler history
  logic [8:0]   prbs;
  logic         tb_v;                   // a 257-bit block waits for the gearbox
  logic [256:0] tb_d;
  logic [1023:0] tacc;                  // gearbox: the pair stream, bit 0 next
  logic [9:0]   tfill;                  // at most 937 (a beat needs 640, a block adds 257)
  logic [4:0]   teb;                    // beat of the pair to the encoders
  wire          tam = tpc == '0 && tpb < 6'd8;
  wire          te_rdy;
  wire          tlast = teb == 5'd16;   // beat 16 takes the last 40 bits of the pair
  wire          temit = (tlast ? tfill >= 10'd40 : tfill >= 10'd640) && te_rdy;
  wire  [9:0]   tfill_e = temit ? tfill - (tlast ? 10'd40 : 10'd640) : tfill;
  wire          tapp = tb_v && tfill_e < 10'd767;      // keeps the fill below 1024
  wire          tload = !tb_v || tapp;
  assign tx_in_ready = tload && !tam;

  // the marker group's 133 pad bits, and the PRBS state after them
  logic [132:0] pad;
  logic [8:0]   prbs_n;
  always_comb begin
    prbs_n = prbs;
    for (int i = 0; i < 133; i++) begin
      pad[i] = prbs_n[8] ^ prbs_n[4];
      prbs_n = {prbs_n[7:0], prbs_n[8] ^ prbs_n[4]};
    end
  end
  wire [314:0] tscr = scr(tsh, xcode(tx_in_data), 1'b0);
  logic [256:0] tamb;
  always_comb begin
    case (tpb[2:0])
      3'd0: tamb = AMG[0 +: 257];
      3'd1: tamb = AMG[257 +: 257];
      3'd2: tamb = AMG[514 +: 257];
      3'd3: tamb = AMG[771 +: 257];
      3'd4: tamb = AMG[1028 +: 257];
      3'd5: tamb = AMG[1285 +: 257];
      3'd6: tamb = AMG[1542 +: 257];
      default: tamb = {tx_am_sf, pad, AMG[1799 +: 121]};
    endcase
  end

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      tpb <= '0; tpc <= '0; tsh <= '1; prbs <= '1; tb_v <= 1'b0; tb_d <= '0;
    end else if (tload) begin
      tb_v <= 1'b0;
      if (tam) begin
        tb_v <= 1'b1; tb_d <= tamb;
        if (tpb == 6'd7) prbs <= prbs_n;
      end else if (tx_in_valid) begin
        tb_v <= 1'b1; tb_d <= tscr[256:0]; tsh <= tscr[314:257];
      end
      if (tam || tx_in_valid) begin
        tpb <= tpb == 6'd39 ? '0 : tpb + 6'd1;
        if (tpb == 6'd39) tpc <= tpc == PW'(AMP - 1) ? '0 : tpc + 1'b1;
      end
    end
  end

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      tacc <= '0; tfill <= '0; teb <= '0;
    end else begin
      tacc <= (temit ? (tlast ? tacc >> 40 : tacc >> 640) : tacc)
            | (tapp ? {767'd0, tb_d} << tfill_e : '0);
      tfill <= tapp ? tfill_e + 10'd257 : tfill_e;
      if (temit) teb <= tlast ? '0 : teb + 5'd1;
    end
  end
  // the beat for A (even symbols of the stream) and B (odd); beat 16 carries two each
  logic [319:0] tea, teb_d;
  always_comb begin
    for (int k = 0; k < 32; k++) begin
      tea[10 * k +: 10] = (!tlast || k < 2) ? tacc[20 * k +: 10] : 10'd0;
      teb_d[10 * k +: 10] = (!tlast || k < 2) ? tacc[20 * k + 10 +: 10] : 10'd0;
    end
  end

  // ---------------- the two FEC instances ----------------
  wire          a_e_in_ready, a_e_out_valid, a_e_out_first, a_d_in_ready, a_d_out_valid, a_d_out_first, a_d_out_bad;
  wire          b_e_in_ready, b_e_out_valid, b_e_out_first, b_d_in_ready, b_d_out_valid, b_d_out_first, b_d_out_bad;
  wire  [319:0] a_e_out_data, a_d_out_data, b_e_out_data, b_d_out_data;
  wire          a_eres, b_eres, a_dres, b_dres;
  logic [319:0] rda, rdb;
  wire          rtake;
  assign te_rdy = a_e_in_ready;
  Ethernet_RS_FEC_top u_a (
    .clk, .rst_n, .cfg_bypass_corr, .cfg_bypass_ind,
    .e_in_valid(temit), .e_in_first(teb == '0), .e_in_data(tea), .e_in_ready(a_e_in_ready),
    .e_out_valid(a_e_out_valid), .e_out_first(a_e_out_first), .e_out_data(a_e_out_data), .e_out_ready(tx_out_ready),
    .d_in_valid(rx_in_valid), .d_in_first(rx_in_first), .d_in_data(rda), .d_in_ready(a_d_in_ready),
    .d_out_valid(a_d_out_valid), .d_out_first(a_d_out_first), .d_out_bad(a_d_out_bad), .d_out_data(a_d_out_data),
    .d_out_ready(rtake),
    .ev_corr(ev_corr_a), .ev_uncorr(ev_uncorr_a), .ev_eresync(a_eres), .ev_dresync(a_dres), .st_nsym(st_nsym_a));
  Ethernet_RS_FEC_top u_b (
    .clk, .rst_n, .cfg_bypass_corr, .cfg_bypass_ind,
    .e_in_valid(temit), .e_in_first(teb == '0), .e_in_data(teb_d), .e_in_ready(b_e_in_ready),
    .e_out_valid(b_e_out_valid), .e_out_first(b_e_out_first), .e_out_data(b_e_out_data), .e_out_ready(tx_out_ready),
    .d_in_valid(rx_in_valid), .d_in_first(rx_in_first), .d_in_data(rdb), .d_in_ready(b_d_in_ready),
    .d_out_valid(b_d_out_valid), .d_out_first(b_d_out_first), .d_out_bad(b_d_out_bad), .d_out_data(b_d_out_data),
    .d_out_ready(rtake),
    .ev_corr(ev_corr_b), .ev_uncorr(ev_uncorr_b), .ev_eresync(b_eres), .ev_dresync(b_dres), .st_nsym(st_nsym_b));
  // A and B run in lockstep: their handshakes are the same
  wire _unused = &{1'b0, b_e_in_ready, b_e_out_valid, b_e_out_first, b_d_in_ready, b_d_out_valid, b_d_out_first,
                   a_eres, b_eres, b_dres};
  assign ev_resync = a_dres;

  // symbol distribution: symbol 16k + 2j of a beat is codeword symbol 8k + j
  // of A (even k) or B (odd k), symbol 16k + 2j + 1 of the other
  always_comb begin
    for (int k = 0; k < 4; k++)
      for (int j = 0; j < 8; j++) begin
        tx_out_data[10 * (16 * k + 2 * j) +: 10]     = k % 2 == 0 ? a_e_out_data[10 * (8 * k + j) +: 10]
                                                                  : b_e_out_data[10 * (8 * k + j) +: 10];
        tx_out_data[10 * (16 * k + 2 * j + 1) +: 10] = k % 2 == 0 ? b_e_out_data[10 * (8 * k + j) +: 10]
                                                                  : a_e_out_data[10 * (8 * k + j) +: 10];
        rda[10 * (8 * k + j) +: 10] = k % 2 == 0 ? rx_in_data[10 * (16 * k + 2 * j) +: 10]
                                                 : rx_in_data[10 * (16 * k + 2 * j + 1) +: 10];
        rdb[10 * (8 * k + j) +: 10] = k % 2 == 0 ? rx_in_data[10 * (16 * k + 2 * j + 1) +: 10]
                                                 : rx_in_data[10 * (16 * k + 2 * j) +: 10];
      end
  end
  assign tx_out_valid = a_e_out_valid;
  assign tx_out_first = a_e_out_first;
  assign rx_in_ready = a_d_in_ready;

  // ---------------- receive ----------------
  logic [1023:0] racc;
  logic [9:0]   rfill;                  // at most 1023
  logic [4:0]   rb;                     // beat of the pair from the decoders
  logic [5:0]   rpb;                    // block of the pair to the output
  logic [PW-1:0] rpc;
  logic [1:0]   rbadq, rnq;             // bad flags of the pairs in the gearbox (entry 0: the oldest)
  logic [57:0]  rsh;
  // marker lock: hunting, locked, locked with one or two groups missing in a row
  typedef enum logic [1:0] {R_HUNT, R_LOCK, R_MISS1, R_MISS2} rlk_t;
  rlk_t         rlk;
  logic         amacc;
  wire          lock = rlk != R_HUNT;
  wire  [4:0]   rbc = a_d_out_first ? 5'd0 : rb;
  wire          rlast = rbc == 5'd16;
  wire          rblk = rfill >= 10'd257 && (!rx_out_valid || rx_out_ready);
  wire  [9:0]   rfill_e = rblk ? rfill - 10'd257 : rfill;
  assign rtake = rlast ? rfill_e < 10'd984 : rfill_e < 10'd384;   // keeps the fill below 1024
  wire          rbeat = a_d_out_valid && rtake;
  logic [639:0] rbits;
  always_comb
    for (int k = 0; k < 32; k++) begin
      rbits[20 * k +: 10] = a_d_out_data[10 * k +: 10];
      rbits[20 * k + 10 +: 10] = b_d_out_data[10 * k +: 10];
    end
  wire  [639:0] rbm = rlast ? {600'd0, rbits[39:0]} : rbits;
  wire  [256:0] rbk = racc[256:0];
  wire          rbad = rbadq[0];
  // marker group: the fixed bits of block rpb (block 7: its first 121 bits)
  logic         amm;
  always_comb
    case (rpb[2:0])
      3'd0: amm = rbk == AMG[0 +: 257];
      3'd1: amm = rbk == AMG[257 +: 257];
      3'd2: amm = rbk == AMG[514 +: 257];
      3'd3: amm = rbk == AMG[771 +: 257];
      3'd4: amm = rbk == AMG[1028 +: 257];
      3'd5: amm = rbk == AMG[1285 +: 257];
      3'd6: amm = rbk == AMG[1542 +: 257];
      default: amm = rbk[120:0] == AMG[1799 +: 121];
    endcase
  wire          rfound = amacc && amm;          // at block 7
  wire          ramslot = rpb < 6'd8 && (!lock || rpc == '0);
  wire [314:0]  rdsc = scr(rsh, rbk, 1'b1);
  wire [264:0]  rgrp = rxcode(rdsc[256:0]);
  wire          rend = rpb == 6'd39;

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      racc <= '0; rfill <= '0; rb <= '0; rbadq <= '0; rnq <= '0;
    end else begin
      racc <= (rblk ? racc >> 257 : racc) | (rbeat ? {384'd0, rbm} << rfill_e : '0);
      rfill <= rbeat ? rfill_e + (rlast ? 10'd40 : 10'd640) : rfill_e;
      if (rbeat) rb <= rlast ? '0 : rbc + 5'd1;
      // a pair's bad flag enters with its first beat and leaves with its last
      // block; at most two pairs are in the gearbox, and when one enters as
      // another leaves, the one leaving is the only one (a pair is longer
      // than the gearbox)
      case ({rbeat && rbc == '0, rblk && rend})
        2'b10: begin rbadq[rnq[0]] <= a_d_out_bad | b_d_out_bad; rnq <= rnq + 2'd1; end
        2'b01: begin rbadq <= {1'b0, rbadq[1]}; rnq <= rnq - 2'd1; end
        2'b11: rbadq[0] <= a_d_out_bad | b_d_out_bad;
        default: ;
      endcase
    end
  end

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      rpb <= '0; rpc <= '0; rsh <= '1; rlk <= R_HUNT; amacc <= 1'b0;
      rx_out_valid <= 1'b0; rx_out_data <= '0; rx_am_sf <= '0; ev_am_err <= 1'b0; ev_itb <= 1'b0;
    end else begin
      ev_am_err <= 1'b0; ev_itb <= 1'b0;
      if (rx_out_ready) rx_out_valid <= 1'b0;
      if (rblk) begin
        rpb <= rend ? '0 : rpb + 6'd1;
        amacc <= (rpb == '0 || amacc) && amm;
        if (rend) rpc <= rpc == PW'(AMP - 1) ? '0 : rpc + 1'b1;
        if (rpb == 6'd7) begin
          if (!lock) begin
            if (rfound) begin rlk <= R_LOCK; rpc <= '0; rx_am_sf <= rbk[256:254]; end
          end else if (rpc == '0) begin
            if (rfound) begin rlk <= R_LOCK; rx_am_sf <= rbk[256:254]; end
            else if (!rbad) begin
              ev_am_err <= 1'b1;
              case (rlk)
                R_LOCK: rlk <= R_MISS1;
                R_MISS1: rlk <= R_MISS2;
                default: rlk <= R_HUNT;
              endcase
            end
          end else if (rfound && !rbad) ev_am_err <= 1'b1;
        end
        if (!ramslot && (lock || rpb >= 6'd8)) rsh <= rdsc[314:257];
        if (!ramslot && lock) begin
          rx_out_valid <= 1'b1;
          for (int j = 0; j < 4; j++)
            rx_out_data[66 * j +: 66] <= {rgrp[66 * j + 2 +: 64], rbad ? 2'b11 : rgrp[66 * j +: 2]};
          ev_itb <= rgrp[264] && !rbad;
        end
      end
    end
  end
  assign rx_am_lock = lock;
endmodule
