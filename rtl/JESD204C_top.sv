// SPDX-License-Identifier: Apache-2.0
// ============================================================================
// JESD204C_top v2.0: JESD204C-style 64b/66b link layer, one lane
// (scrambling, sync header stream with CRC-12 and command channel,
// multiblock and extended multiblock alignment)
// ----------------------------------------------------------------------------
//  - Line: one bit per clk. A block is a 2-bit sync header (first bit the
//    inverse of the second; the second is the sync header stream bit, so
//    00 and 11 are invalid) and 64 payload bits, payload bit 0 first.
//  - Scrambling: the payload goes through the self-synchronous scrambler
//    1 + x^39 + x^58 (headers are not scrambled).
//  - Multiblock: 32 blocks. Its 32 sync header stream bits, block 0 first:
//      C11 C10 C9 1  C8 C7 C6 1  C5 C4 C3 1  C2 C1 C0 1
//      M6  M5  M4 1  M3 M2 M1 1  M0 EoEMB 1  0  0  0  0  1
//    C = CRC-12 (x^12 + x^11 + x^3 + x^2 + x + 1, initial value 0, payload
//    bit 0 first) of the previous multiblock's 2048 payload bits before
//    scrambling; M = command channel; EoEMB = last multiblock of an
//    extended multiblock of cfg_e + 1 multiblocks; 00001 marks the end of
//    the multiblock and occurs nowhere else.
//  - Transmit: one block per 66 clocks. tx_ready is high for one clock
//    when a block's payload is taken from tx_data; without tx_valid the
//    block carries zeros and tx_underrun pulses. tx_mb_start pulses as a
//    multiblock starts; tx_cmd is sampled then.
//  - Receive, sync header alignment: the receiver slides one bit at a time
//    until a header is valid, locks (sh_lock) after 64 valid headers in a
//    row, pulses err_sh for each invalid header while locked and unlocks
//    at the 16th invalid header within a window of 64 headers.
//  - Receive, multiblock alignment: with sh_lock, a 00001 marks the
//    multiblock end; the next EoEMB = 1 multiblock gives emb_lock, and
//    from the next block on every block goes out on rx_data with
//    rx_mb_start / rx_emb_start. A missing or misplaced 00001 or an EoEMB
//    where cfg_e does not expect one pulses err_emb and drops the lock
//    (back to hunting, or to waiting for an EoEMB). With emb_lock each
//    multiblock end pulses rx_mb_valid with rx_cmd and rx_crc_err (its
//    CRC field against the previous multiblock; emb_lock comes at a
//    multiblock end, so that one was always received whole).
//  Not implemented: multiple lanes, the transport layer (M / N / S / F
//  mapping), SYSREF / LEMC alignment and deterministic latency, the CRC-3
//  and FEC sync header modes, pilot bit checks, the 64b/80b mode. The
//  sync header layout follows JESD204C's CRC-12 mode as we read it; it
//  has not been checked against a compliant device.
// ============================================================================
module JESD204C_top (
  input  logic        clk,
  input  logic        rst_n,
  // line
  output logic        tx_p,
  input  logic        rx_p,
  // configuration
  input  logic [3:0]  cfg_e,          // multiblocks per extended multiblock - 1
  // transmit
  input  logic        tx_valid,
  output logic        tx_ready,
  input  logic [63:0] tx_data,
  input  logic [6:0]  tx_cmd,
  output logic        tx_mb_start,
  output logic        tx_underrun,
  // receive
  output logic        rx_valid,
  output logic [63:0] rx_data,
  output logic        rx_mb_start,
  output logic        rx_emb_start,
  output logic        rx_mb_valid,
  output logic [6:0]  rx_cmd,
  output logic        rx_crc_err,
  // status
  output logic        sh_lock,
  output logic        emb_lock,
  output logic        err_sh,
  output logic        err_emb
);
  function automatic logic [11:0] crc_step(input logic [11:0] c, input logic b);
    crc_step = {c[10:0], 1'b0} ^ ((c[11] ^ b) ? 12'h80F : 12'h000);
  endfunction
  // sync header stream bit j of a multiblock
  function automatic logic sh_bit(input logic [4:0] j, input logic [11:0] c, input logic [6:0] m, input logic eo);
    case (j)
      5'd0: sh_bit = c[11]; 5'd1: sh_bit = c[10]; 5'd2: sh_bit = c[9];
      5'd4: sh_bit = c[8];  5'd5: sh_bit = c[7];  5'd6: sh_bit = c[6];
      5'd8: sh_bit = c[5];  5'd9: sh_bit = c[4];  5'd10: sh_bit = c[3];
      5'd12: sh_bit = c[2]; 5'd13: sh_bit = c[1]; 5'd14: sh_bit = c[0];
      5'd16: sh_bit = m[6]; 5'd17: sh_bit = m[5]; 5'd18: sh_bit = m[4];
      5'd20: sh_bit = m[3]; 5'd21: sh_bit = m[2]; 5'd22: sh_bit = m[1];
      5'd24: sh_bit = m[0]; 5'd25: sh_bit = eo;
      5'd27, 5'd28, 5'd29, 5'd30: sh_bit = 1'b0;
      default: sh_bit = 1'b1;
    endcase
  endfunction

  // ---------------- transmitter ----------------
  logic [6:0]  tc;                      // bit in the block, 0..65
  logic [4:0]  tj;                      // block in the multiblock
  logic [3:0]  te;                      // multiblock in the extended multiblock
  logic [63:0] tpay;
  logic [57:0] tscr;                    // scrambled bits sent, [0] newest
  logic [11:0] tcrc, tcrc_s;            // running CRC, CRC to send
  logic [6:0]  tcmd;

  wire tsb = sh_bit(tj, tcrc_s, tcmd, te >= cfg_e);
  wire tbit = tpay[6'(tc - 7'd2)];
  wire tsc = tbit ^ tscr[38] ^ tscr[57];
  assign tx_ready = tc == 7'd0 && tx_valid;

  always_ff @(posedge clk or negedge rst_n)
    if (!rst_n) begin
      tc <= '0; tj <= '0; te <= '0; tpay <= '0; tscr <= '0; tcrc <= '0; tcrc_s <= '0; tcmd <= '0;
      tx_p <= 1'b0; tx_mb_start <= 1'b0; tx_underrun <= 1'b0;
    end else begin
      tx_mb_start <= 1'b0; tx_underrun <= 1'b0;
      tc <= tc == 7'd65 ? 7'd0 : tc + 7'd1;
      if (tc == 7'd0) begin
        tx_p <= !tsb;
        tpay <= tx_valid ? tx_data : 64'd0;
        tx_underrun <= !tx_valid;
        if (tj == 5'd0) begin tcmd <= tx_cmd; tx_mb_start <= 1'b1; end
      end else if (tc == 7'd1) tx_p <= tsb;
      else begin
        tx_p <= tsc; tscr <= {tscr[56:0], tsc}; tcrc <= crc_step(tcrc, tbit);
        if (tc == 7'd65) begin
          tj <= tj + 5'd1;
          if (tj == 5'd31) begin
            tcrc_s <= crc_step(tcrc, tbit); tcrc <= '0;
            te <= te >= cfg_e ? 4'd0 : te + 4'd1;
          end
        end
      end
    end

  // ---------------- receiver ----------------
  typedef enum logic [1:0] {SH_HUNT, SH_TEST, SH_LOCK} sh_t;
  typedef enum logic [1:0] {E_INIT, E_MB, E_LOCK} es_t;
  sh_t         ss;
  es_t         es;
  logic        rx_q, h0;
  logic [6:0]  rc;
  logic [5:0]  vcnt, wcnt;              // valid headers while testing; headers in the window
  logic [3:0]  icnt;                    // invalid headers in the window
  logic [57:0] rscr;
  logic [62:0] rpay;                    // payload bits so far, newest in [62]
  logic [11:0] rcrc, rcrc_p;
  logic [31:0] rsh;                     // sync header stream bits, [0] newest
  logic [4:0]  rj;
  logic [3:0]  re;

  assign sh_lock = ss == SH_LOCK;
  assign emb_lock = es == E_LOCK;
  wire        hv = h0 != rx_q;
  wire        rd = rx_q ^ rscr[38] ^ rscr[57];
  wire [63:0] blk = {rd, rpay};
  wire [11:0] rcrc_n = crc_step(rcrc, rd);
  wire        eomb = rsh[4:0] == 5'b00001;
  wire [11:0] c_rx = {rsh[31:29], rsh[27:25], rsh[23:21], rsh[19:17]};
  wire [6:0]  m_rx = {rsh[15:13], rsh[11:9], rsh[7]};
  wire        eo_rx = rsh[6];

  always_ff @(posedge clk or negedge rst_n)
    if (!rst_n) begin
      ss <= SH_HUNT; es <= E_INIT; rx_q <= 1'b0; h0 <= 1'b0; rc <= '0; vcnt <= '0; wcnt <= '0;
      icnt <= '0; rscr <= '0; rpay <= '0; rcrc <= '0; rcrc_p <= '0; rsh <= '0; rj <= '0; re <= '0;
      rx_valid <= 1'b0; rx_data <= '0; rx_mb_start <= 1'b0; rx_emb_start <= 1'b0; rx_mb_valid <= 1'b0;
      rx_cmd <= '0; rx_crc_err <= 1'b0; err_sh <= 1'b0; err_emb <= 1'b0;
    end else begin
      rx_valid <= 1'b0; rx_mb_valid <= 1'b0; err_sh <= 1'b0; err_emb <= 1'b0;
      rx_q <= rx_p;
      if (rc == 7'd0) begin h0 <= rx_q; rc <= 7'd1; end
      else if (rc == 7'd1) begin
        rc <= 7'd2;
        rsh <= {rsh[30:0], rx_q};
        unique case (ss)
          // an invalid header has rx_q == h0: sliding by one bit keeps h0
          SH_HUNT: if (hv) begin ss <= SH_TEST; vcnt <= 6'd1; end
                   else rc <= 7'd1;
          SH_TEST: if (!hv) begin ss <= SH_HUNT; rc <= 7'd1; end
                   else begin
                     vcnt <= vcnt + 6'd1;
                     if (vcnt == 6'd63) begin ss <= SH_LOCK; wcnt <= '0; icnt <= '0; end
                   end
          SH_LOCK: begin
            wcnt <= wcnt + 6'd1;
            icnt <= wcnt == 6'd63 ? 4'd0 : icnt + {3'd0, !hv};
            if (!hv) err_sh <= 1'b1;
            if (!hv && icnt == 4'd15) ss <= SH_HUNT;
          end
        endcase
      end else begin
        rc <= rc == 7'd65 ? 7'd0 : rc + 7'd1;
        rscr <= {rscr[56:0], rx_q};
        rpay <= blk[63:1];
        rcrc <= rcrc_n;
        if (rc == 7'd65) begin
          // a whole block
          if (es == E_LOCK) begin
            rx_valid <= 1'b1; rx_data <= blk; rx_mb_start <= rj == 5'd0; rx_emb_start <= rj == 5'd0 && re == 4'd0;
          end
          rj <= rj + 5'd1;
          if (!sh_lock) es <= E_INIT;
          else unique case (es)
            E_INIT: if (eomb) begin es <= E_MB; rj <= '0; rcrc <= '0; end
            E_MB, E_LOCK: begin
              if (rj == 5'd31) begin
                if (!eomb) begin err_emb <= 1'b1; es <= E_INIT; end
                else begin
                  rcrc <= '0; rcrc_p <= rcrc_n;
                  if (es == E_LOCK) begin
                    rx_mb_valid <= 1'b1; rx_cmd <= m_rx; rx_crc_err <= c_rx != rcrc_p;
                    if (eo_rx != (re == cfg_e)) begin err_emb <= 1'b1; es <= E_MB; end
                    re <= eo_rx ? 4'd0 : re + 4'd1;
                  end else if (eo_rx) begin es <= E_LOCK; re <= '0; end
                end
              end else if (eomb) begin
                err_emb <= 1'b1; es <= E_MB; rj <= '0; rcrc <= '0;
              end
            end
          endcase
        end
      end
    end
endmodule
