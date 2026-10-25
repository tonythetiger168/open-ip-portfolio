// SPDX-License-Identifier: Apache-2.0
// ============================================================================
// Interlaken_v1_2_top v2.0: Interlaken-style lane, one lane (64b/67b
// framing, scrambling, metaframe, bursts with CRC-24, in-band flow control)
// ----------------------------------------------------------------------------
//  - Line: one bit per clk. A word is 67 bits sent bit 66 first: bit 66 the
//    inversion flag, bits 65:64 the framing (01 data, 10 control; 00 and 11
//    are invalid), bits 63:0 the payload (inverted when bit 66 is set).
//  - Disparity: the transmitter keeps the running disparity of every bit
//    sent and inverts a word's payload when the word would push it further
//    from zero.
//  - Scrambling: the payload is added to the sequence of the generator
//    x^58 + x^39 + 1 (64 steps a word, bit 63 first), except in the sync
//    and scrambler state words, where the generator also holds still.
//  - Metaframe: MF words: sync word (78F678F678F678F6), scrambler state
//    word (001010 and the generator state), skip word (1E1E1E1E1E1E1E1E),
//    MF - 4 protocol words, diagnostic word (011001, 24 zero bits, lane
//    status, link status, CRC-32C). The framing words are control words;
//    the CRC covers bits 65:0 of every word of the metaframe before
//    scrambling, with the state field and its own field as zeros
//    (polynomial 1EDC6F41, initial value all ones, bit 65 first, sent
//    inverted). Lane status = this end's sync_lock; link status = also the
//    peer's lane status.
//  - Protocol words: data words and burst / idle control words. Control
//    word: [63] 1, [62] burst (1) or idle (0), [61] SOP, [60] EOP of the
//    burst it closes, [59:57] valid bytes of that last word (0 = 8), [56]
//    0, [55:40] flow control, [39:32] channel, [31:24] 0, [23:0] CRC-24.
//    Every control word closes the burst before it; a burst control word
//    opens the next. The CRC-24 (polynomial 328B63, initial value all
//    ones, bit 63 first) covers the data words since the previous control
//    word and this one with its CRC field as zeros.
//  - Transmit: one word per 67 clocks. A burst carries up to BMAX data
//    words of one packet; it ends at the packet's end, at BMAX or when no
//    word is offered. tx_valid must stay high until tx_ready; a burst
//    control word takes tx_sop and tx_chan of the word offered, tx_ready
//    takes the word itself in the next protocol word. tx_fc goes out in
//    every control word.
//  - Receive, word lock: the receiver slides one bit at a time until the
//    framing bits are valid, locks (word_lock) after 64 valid in a row,
//    pulses err_word for each invalid one while locked and unlocks at the
//    16th invalid one within a window of 64 words.
//  - Receive, metaframe lock: with word_lock, a sync word starts the count;
//    four sync words MF words apart give sync_lock. While locked, err_sync
//    pulses for a missing sync word and the 4th in a row drops the lock;
//    err_scr pulses for a scrambler state word that does not match the
//    descrambler (loaded from these words while testing) and the 3rd in a
//    row drops the lock; err_crc32 pulses for a diagnostic word whose CRC
//    does not match, otherwise peer_status takes its status bits.
//  - Receive, protocol: with sync_lock, each data word is held until the
//    next protocol word tells whether it ends the packet; it then goes out
//    on rx_data with rx_sop / rx_eop / rx_bytes / rx_chan, rx_err set when
//    the CRC-24 of its burst failed (a word held when sync_lock drops goes
//    out with rx_eop and rx_err). err_crc24 pulses for every control word
//    whose CRC-24 fails; rx_fc takes the flow control of every one that
//    passes. err_proto pulses for a data word outside a burst, an EOP with
//    no data word to end, a SOP inside a packet, a burst without SOP
//    outside a packet, and a framing layer word in a protocol position.
//  Not implemented: lane striping (multiple lanes), the calendar and its
//  reset bit, BurstShort / BurstMin rules, skip words elsewhere than third,
//  the multiple-use field, retransmit, dual calendar. Field layouts follow
//  Interlaken 1.2 as we read it; they have not been checked against a
//  compliant device.
// ============================================================================
module Interlaken_v1_2_top #(
  parameter int          MF   = 64,     // metaframe length in words (>= 5)
  parameter int          BMAX = 8,      // data words per burst
  parameter logic [57:0] SEED = 58'h2F0_1234_5678_9ABC
)(
  input  logic        clk,
  input  logic        rst_n,
  // line
  output logic        tx_p,
  input  logic        rx_p,
  // transmit
  input  logic        tx_valid,
  output logic        tx_ready,
  input  logic [63:0] tx_data,
  input  logic        tx_sop,
  input  logic        tx_eop,
  input  logic [2:0]  tx_bytes,       // valid bytes in an EOP word, 0 = 8
  input  logic [7:0]  tx_chan,
  input  logic [15:0] tx_fc,
  // receive
  output logic        rx_valid,
  output logic [63:0] rx_data,
  output logic        rx_sop,
  output logic        rx_eop,
  output logic [2:0]  rx_bytes,
  output logic [7:0]  rx_chan,
  output logic        rx_err,
  output logic [15:0] rx_fc,
  // status
  output logic        word_lock,
  output logic        sync_lock,
  output logic [1:0]  peer_status,    // {lane, link} from the peer's diagnostic word
  output logic        err_word,
  output logic        err_sync,
  output logic        err_scr,
  output logic        err_crc32,
  output logic        err_crc24,
  output logic        err_proto
);
  localparam int          PW       = $clog2(MF);
  localparam int          BW       = $clog2(BMAX + 1);
  localparam logic [63:0] SYNC     = 64'h78F6_78F6_78F6_78F6;
  localparam logic [63:0] SKIP     = 64'h1E1E_1E1E_1E1E_1E1E;
  localparam logic [5:0]  SCR_TAG  = 6'b001010;
  localparam logic [5:0]  DIAG_TAG = 6'b011001;
  localparam logic [PW-1:0] LAST   = PW'(MF - 1);

  // generator: the 64-bit sequence of a word ([63] first) and the next state
  function automatic logic [121:0] scr64(input logic [57:0] s);
    logic        k;
    logic [57:0] g;
    g = s;
    for (int i = 63; i >= 0; i--) begin
      k = g[57] ^ g[38];
      g = {g[56:0], k};
      scr64[58 + i] = k;
    end
    scr64[57:0] = g;
  endfunction
  function automatic logic [31:0] crc32_66(input logic [31:0] c, input logic [65:0] d);
    crc32_66 = c;
    for (int i = 65; i >= 0; i--)
      crc32_66 = {crc32_66[30:0], 1'b0} ^ ((crc32_66[31] ^ d[i]) ? 32'h1EDC_6F41 : 32'h0);
  endfunction
  function automatic logic [23:0] crc24_64(input logic [23:0] c, input logic [63:0] d);
    crc24_64 = c;
    for (int i = 63; i >= 0; i--)
      crc24_64 = {crc24_64[22:0], 1'b0} ^ ((crc24_64[23] ^ d[i]) ? 24'h32_8B63 : 24'h0);
  endfunction
  function automatic logic [6:0] ones64(input logic [63:0] d);
    ones64 = '0;
    for (int i = 0; i < 64; i++) ones64 = ones64 + 7'(d[i]);
  endfunction

  // ---------------- transmitter ----------------
  logic [6:0]        tc;                // bit in the word, 0..66
  logic [PW-1:0]     tw;                // word in the metaframe
  logic [65:0]       tsh;               // bits still to send, [65] next
  logic [57:0]       tscr;
  logic signed [7:0] trd;               // running disparity
  logic [31:0]       tcrc32;
  logic [23:0]       tcrc24;
  logic              t_inb, t_eop;      // in a burst; its last data word ended the packet
  logic [2:0]        t_eb;              // valid bytes of that word
  logic [BW-1:0]     t_bc;              // data words in the burst

  wire         t_prot = tw > PW'(2) && tw != LAST;
  wire         t_dat = t_prot && t_inb && !t_eop && t_bc != BW'(BMAX) && tx_valid;
  assign       tx_ready = tc == 7'd0 && t_dat;
  // control word with CRC field c
  function automatic logic [63:0] cw(input logic [23:0] c, input logic v, sop, eop, input logic [2:0] eb,
                                     input logic [15:0] fc, input logic [7:0] ch);
    cw = {1'b1, v, v && sop, eop, eb, 1'b0, fc, v ? ch : 8'd0, 8'd0, c};
  endfunction
  // diagnostic word, CRC field as zeros
  function automatic logic [63:0] diag0(input logic lane, link);
    diag0 = {DIAG_TAG, 24'd0, lane, link, 32'd0};
  endfunction
  // the next running disparity and whether to invert: the word's
  // disparity with bit 66 = 0 is 2 * ones - 65; inverted it is the negative
  function automatic logic [8:0] disp(input logic signed [7:0] rd, input logic [63:0] p);
    logic [7:0] d;
    logic       inv;
    d = 8'({ones64(p), 1'b0}) - 8'd65;
    inv = rd != 8'sd0 && rd[7] == d[7];
    disp = {inv, rd + (inv ? -d : d)};
  endfunction
  wire [23:0]  t_c24 = crc24_64(tcrc24, cw(24'd0, tx_valid, tx_sop, t_eop, t_eb, tx_fc, tx_chan));
  wire [1:0]   t_fr = t_dat ? 2'b01 : 2'b10;
  wire [65:0]  t_cin = tw == PW'(1) ? {2'b10, SCR_TAG, 58'd0} :
                       {t_fr, tw == PW'(0) ? SYNC : tw == PW'(2) ? SKIP :
                              tw == LAST ? diag0(sync_lock, sync_lock && peer_status[1]) :
                              t_dat ? tx_data : cw(t_c24, tx_valid, tx_sop, t_eop, t_eb, tx_fc, tx_chan)};
  wire [31:0]  t_c32 = crc32_66(tw == PW'(0) ? 32'hFFFF_FFFF : tcrc32, t_cin);
  wire [63:0]  t_pay = tw == PW'(0) ? SYNC : tw == PW'(1) ? {SCR_TAG, tscr} : tw == PW'(2) ? SKIP :
                       tw == LAST ? {DIAG_TAG, 24'd0, sync_lock, sync_lock && peer_status[1], ~t_c32} : t_cin[63:0];
  wire [121:0] t_g = scr64(tscr);
  wire         t_scr = tw > PW'(1);
  wire [63:0]  t_ps = t_scr ? t_pay ^ t_g[121:58] : t_pay;
  wire [8:0]   t_dz = disp(trd, t_ps);
  wire         t_inv = t_dz[8];

  always_ff @(posedge clk or negedge rst_n)
    if (!rst_n) begin
      tc <= '0; tw <= '0; tsh <= '0; tscr <= SEED; trd <= '0; tcrc32 <= '0; tcrc24 <= '1;
      t_inb <= 1'b0; t_eop <= 1'b0; t_eb <= '0; t_bc <= '0; tx_p <= 1'b0;
    end else begin
      tc <= tc == 7'd66 ? 7'd0 : tc + 7'd1;
      if (tc == 7'd0) begin
        tx_p <= t_inv;
        tsh <= {t_fr, t_inv ? ~t_ps : t_ps};
        trd <= t_dz[7:0];
        tw <= tw == LAST ? '0 : tw + 1'b1;
        tcrc32 <= t_c32;
        if (t_scr) tscr <= t_g[57:0];
        if (t_dat) begin
          t_bc <= t_bc + 1'b1; t_eop <= tx_eop; t_eb <= tx_eop ? tx_bytes : 3'd0;
          tcrc24 <= crc24_64(tcrc24, tx_data);
        end else if (t_prot) begin
          t_inb <= tx_valid; t_bc <= '0; t_eop <= 1'b0; t_eb <= '0; tcrc24 <= '1;
        end
      end else begin
        tx_p <= tsh[65];
        tsh <= {tsh[64:0], 1'b0};
      end
    end

  // ---------------- receiver ----------------
  typedef enum logic [1:0] {W_HUNT, W_TEST, W_LOCK} ws_t;
  typedef enum logic [1:0] {M_HUNT, M_TEST, M_LOCK} ms_t;
  ws_t           ws;
  ms_t           ms;
  logic          rx_q, rinv, rf1, rf0;
  logic [6:0]    rc;
  logic [5:0]    vcnt, wcnt;            // valid words while testing; words in the window
  logic [3:0]    icnt;                  // invalid words in the window
  logic [62:0]   rsh;                   // payload bits so far, [0] newest
  logic [PW-1:0] rpos;                  // word in the metaframe
  logic [1:0]    rsc, rmiss, rscm;      // sync words seen; sync words missed; state words wrong
  logic [57:0]   rlfsr;
  logic [31:0]   rcrc32;
  logic [23:0]   rcrc24;
  logic          r_inb, r_inpkt, r_sopn;  // in a burst; in a packet; next data word starts it
  logic [7:0]    r_chan;
  logic          rh_v, rh_sop;          // held word
  logic [63:0]   rh_data;
  logic [7:0]    rh_chan;

  assign word_lock = ws == W_LOCK;
  assign sync_lock = ms == M_LOCK;
  wire         hv = rf1 != rx_q;        // at rc 2
  wire [63:0]  dw = {rsh, rx_q ^ rinv}; // at rc 66
  wire [1:0]   rfr = {rf1, rf0};
  wire [121:0] r_g = scr64(rlfsr);
  wire [63:0]  dd = dw ^ r_g[121:58];
  wire         is_sync = rfr == 2'b10 && dw == SYNC;
  wire         scr_bad = rfr != 2'b10 || dw != {SCR_TAG, rlfsr};
  wire [65:0]  r_cin = rpos == PW'(0) ? {rfr, dw} : rpos == PW'(1) ? {rfr, dw[63:58], 58'd0} :
                       rpos == LAST ? {rfr, dd[63:32], 32'd0} : {rfr, dd};
  wire [31:0]  r_c32 = crc32_66(rpos == PW'(0) ? 32'hFFFF_FFFF : rcrc32, r_cin);
  wire         r_c24ok = crc24_64(rcrc24, {dd[63:24], 24'd0}) == dd[23:0];
  wire         r_open = r_inpkt && !dd[60];   // a packet still open after a control word
  wire         m_lost = ms == M_LOCK && (ws != W_LOCK || rpos == PW'(0) && !is_sync && rmiss == 2'd3 ||
                                         rpos == PW'(1) && scr_bad && rscm == 2'd2);
  wire         r_prot = ms == M_LOCK && ws == W_LOCK && rpos > PW'(2) && rpos != LAST;

  always_ff @(posedge clk or negedge rst_n)
    if (!rst_n) begin
      ws <= W_HUNT; ms <= M_HUNT; rx_q <= 1'b0; rinv <= 1'b0; rf1 <= 1'b0; rf0 <= 1'b0; rc <= '0;
      vcnt <= '0; wcnt <= '0; icnt <= '0; rsh <= '0; rpos <= '0; rsc <= '0; rmiss <= '0; rscm <= '0;
      rlfsr <= '0; rcrc32 <= '0; rcrc24 <= '1; r_inb <= 1'b0; r_inpkt <= 1'b0; r_sopn <= 1'b0;
      r_chan <= '0; rh_v <= 1'b0; rh_sop <= 1'b0; rh_data <= '0; rh_chan <= '0;
      rx_valid <= 1'b0; rx_data <= '0; rx_sop <= 1'b0; rx_eop <= 1'b0; rx_bytes <= '0; rx_chan <= '0;
      rx_err <= 1'b0; rx_fc <= '0; peer_status <= '0;
      err_word <= 1'b0; err_sync <= 1'b0; err_scr <= 1'b0; err_crc32 <= 1'b0; err_crc24 <= 1'b0; err_proto <= 1'b0;
    end else begin
      rx_valid <= 1'b0; err_word <= 1'b0; err_sync <= 1'b0; err_scr <= 1'b0;
      err_crc32 <= 1'b0; err_crc24 <= 1'b0; err_proto <= 1'b0;
      rx_q <= rx_p;
      if (rc == 7'd0) begin rinv <= rx_q; rc <= 7'd1; end
      else if (rc == 7'd1) begin rf1 <= rx_q; rc <= 7'd2; end
      else if (rc == 7'd2) begin
        rf0 <= rx_q; rc <= 7'd3;
        unique case (ws)
          // an invalid word: slide by one bit
          W_HUNT: if (hv) begin ws <= W_TEST; vcnt <= 6'd1; end
                  else begin rinv <= rf1; rf1 <= rx_q; rc <= 7'd2; end
          W_TEST: if (!hv) begin ws <= W_HUNT; rinv <= rf1; rf1 <= rx_q; rc <= 7'd2; end
                  else begin
                    vcnt <= vcnt + 6'd1;
                    if (vcnt == 6'd63) begin ws <= W_LOCK; wcnt <= '0; icnt <= '0; end
                  end
          W_LOCK: begin
            wcnt <= wcnt + 6'd1;
            icnt <= wcnt == 6'd63 ? 4'd0 : icnt + {3'd0, !hv};
            if (!hv) err_word <= 1'b1;
            if (!hv && icnt == 4'd15) ws <= W_HUNT;
          end
        endcase
      end else begin
        rsh <= {rsh[61:0], rx_q ^ rinv};
        rc <= rc == 7'd66 ? 7'd0 : rc + 7'd1;
        if (rc == 7'd66) begin
          // a whole word
          if (ws != W_LOCK || ms == M_HUNT) begin
            rpos <= '0;
            if (ws == W_LOCK && is_sync) begin ms <= M_TEST; rsc <= 2'd1; rpos <= PW'(1); rcrc32 <= r_c32; end
            else ms <= M_HUNT;
          end else begin
            rpos <= rpos == LAST ? '0 : rpos + 1'b1;
            rcrc32 <= r_c32;
            if (rpos > PW'(1)) rlfsr <= r_g[57:0];
            if (rpos == PW'(0)) begin
              if (ms == M_TEST) begin
                if (!is_sync) begin ms <= M_HUNT; rpos <= '0; end
                else begin
                  rsc <= rsc + 2'd1;
                  if (rsc == 2'd3) begin ms <= M_LOCK; rmiss <= '0; rscm <= '0; end
                end
              end else if (!is_sync) begin err_sync <= 1'b1; rmiss <= rmiss + 2'd1; end
              else rmiss <= '0;
            end
            if (rpos == PW'(1)) begin
              if (ms == M_LOCK) begin
                if (scr_bad) begin err_scr <= 1'b1; rscm <= rscm + 2'd1; end
                else rscm <= '0;
              end else rlfsr <= dw[57:0];
            end
            if (rpos == LAST && ms == M_LOCK) begin
              if (dd[31:0] != ~r_c32) err_crc32 <= 1'b1;
              else peer_status <= dd[33:32];
            end
          end
          if (m_lost) begin
            ms <= M_HUNT; rpos <= '0;
            r_inb <= 1'b0; r_inpkt <= 1'b0; rh_v <= 1'b0; rcrc24 <= '1;
            if (rh_v) begin
              rx_valid <= 1'b1; rx_data <= rh_data; rx_sop <= rh_sop; rx_eop <= 1'b1; rx_bytes <= '0;
              rx_chan <= rh_chan; rx_err <= 1'b1;
            end
          end
          if (r_prot) begin
            if (rfr == 2'b01) begin
              rcrc24 <= crc24_64(rcrc24, dd);
              if (!r_inb) err_proto <= 1'b1;
              else begin
                if (rh_v) begin
                  rx_valid <= 1'b1; rx_data <= rh_data; rx_sop <= rh_sop; rx_eop <= 1'b0; rx_bytes <= '0;
                  rx_chan <= rh_chan; rx_err <= 1'b0;
                end
                rh_v <= 1'b1; rh_data <= dd; rh_sop <= r_sopn; rh_chan <= r_chan; r_sopn <= 1'b0;
              end
            end else if (rfr == 2'b10) begin
              if (!dd[63]) err_proto <= 1'b1;
              else begin
                rcrc24 <= '1;
                if (!r_c24ok) err_crc24 <= 1'b1;
                else rx_fc <= dd[55:40];
                if (rh_v) begin
                  rx_valid <= 1'b1; rx_data <= rh_data; rx_sop <= rh_sop; rx_eop <= dd[60];
                  rx_bytes <= dd[60] ? dd[59:57] : 3'd0; rx_chan <= rh_chan; rx_err <= !r_c24ok;
                  rh_v <= 1'b0;
                end else if (dd[60]) err_proto <= 1'b1;
                if (dd[62]) begin
                  if (dd[61] == r_open) err_proto <= 1'b1;
                  r_inb <= 1'b1; r_inpkt <= 1'b1; r_sopn <= dd[61]; r_chan <= dd[39:32];
                end else begin
                  r_inb <= 1'b0; r_inpkt <= r_open;
                end
              end
            end
          end
        end
      end
    end
endmodule
