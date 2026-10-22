// SPDX-License-Identifier: Apache-2.0
// ============================================================================
// USB3 protocol IP -- SuperSpeed link + protocol layer (simplified)
//   * Symbol-parallel serial link: 1 symbol/clk, 8-bit symbol, on the
//     tx_p/tx_n and rx_p/rx_n differential pairs (_n carries the complement)
//   * Symbol decode: a received symbol is valid only when rx_n == ~rx_p; an
//     invalid symbol inside a packet aborts it (irq), and is never counted
//     as LFPS or taken as a packet start.
//   * LFPS out-of-band handshake: RXDET (32 clk) -> Polling.LFPS: the device
//     sends 16-symbol LFPS bursts + 16 idle; U0 (link_up) once it has sent
//     two bursts and received two bursts of >= 8 symbols. LFPS burst =
//     repeated 8'hAA symbols, idle = 8'h00.
//   * Warm reset: in U0, 32 consecutive LFPS symbols between packets drop
//     the link back to RXDET and clear the sequence numbers and any
//     transfer in progress (buffer contents, block flags and irq are kept).
//   * Ordered-set framing:
//       DPH : SOF(8'hBC) + {route,type} + {seq,blk} + CRC5
//       DPP : START(8'h5A) + fixed 16-dword payload + CRC32 + END(8'h3C)
//       TP  : SOF(8'h4B) + {route,type} + {seq,retry,blk,in_req} + CRC5 + END
//       Transaction packet types: ACK(4'hA) / NRDY(4'h5) / LBAD(4'hB)
//   * Sequence-number retransmission management: bad DPP CRC32 -> LBAD ->
//     host resends; duplicate seq -> ACK with retry flag; out-of-order seq
//     -> NRDY; device IN data retransmitted on LBAD / ACK timeout.
//   * Function unit: bulk OUT writes / bulk IN reads a 64x32 buffer
//     (4 blocks x 16 dwords, one DPP carries exactly one block).
// IP design implementation v1.1 -- Apache-2.0
// ============================================================================
module USB3_top (
  input  logic       clk,
  input  logic       rst_n,
  input  logic [7:0] rx_p,      // received symbol (differential +)
  input  logic [7:0] rx_n,      // received symbol (differential -, = ~rx_p)
  output logic [7:0] tx_p,      // transmitted symbol (differential +)
  output logic [7:0] tx_n,      // transmitted symbol (differential -)
  output logic       link_up,   // link trained, U0 reached
  output logic       irq        // sticky protocol-error indication
);

  // ------------------------------------------------------------------
  // symbol / packet constants
  // ------------------------------------------------------------------
  localparam logic [7:0] SYM_IDLE = 8'h00;  // electrical idle
  localparam logic [7:0] SYM_LFPS = 8'hAA;  // LFPS burst symbol
  localparam logic [7:0] SYM_DPH  = 8'hBC;  // data packet header start
  localparam logic [7:0] SYM_TP   = 8'h4B;  // transaction packet start
  localparam logic [7:0] SYM_DPP  = 8'h5A;  // data packet payload start
  localparam logic [7:0] SYM_END  = 8'h3C;  // packet end framing

  localparam logic [3:0] TYPE_DATA = 4'h1;  // DPH type: data (DPP follows)
  localparam logic [3:0] TP_ACK    = 4'hA;
  localparam logic [3:0] TP_NRDY   = 4'h5;
  localparam logic [3:0] TP_LBAD   = 4'hB;

  // ------------------------------------------------------------------
  // CRC functions
  // ------------------------------------------------------------------
  // CRC5, poly x^5+x^2+1 (reflected), init all-ones, over 16 bits {s2,s1},
  // transmitted bit0 (s1[0]) first; final value complemented.
  function automatic logic [4:0] crc5_16(input logic [15:0] d);
    logic [4:0] c;
    logic       fb;
    begin
      c = 5'h1F;
      for (int i = 0; i < 16; i++) begin
        fb = d[i] ^ c[0];
        c  = {fb, c[4], c[3] ^ fb, c[2], c[1]};
      end
      crc5_16 = ~c;
    end
  endfunction

  // CRC32, poly 0x04C11DB7 reflected (0xEDB88320), one byte per call,
  // LSB-first; caller seeds with all-ones and complements the result.
  function automatic logic [31:0] crc32_b(input logic [31:0] c_in,
                                          input logic [7:0]  d);
    logic [31:0] c;
    logic        fb;
    begin
      c = c_in;
      for (int i = 0; i < 8; i++) begin
        fb = d[i] ^ c[0];
        c  = c >> 1;
        if (fb) c = c ^ 32'hEDB8_8320;
      end
      crc32_b = c;
    end
  endfunction

  // ------------------------------------------------------------------
  // link layer: RXDET -> POLL (LFPS handshake) -> U0
  // ------------------------------------------------------------------
  typedef enum logic [1:0] {LK_RXDET, LK_POLL, LK_U0} link_state_t;
  link_state_t link_state;

  wire        rx_ok   = (rx_n == ~rx_p);           // valid differential symbol
  wire        rx_lfps = rx_ok && (rx_p == SYM_LFPS);

  logic [4:0] det_cnt;        // RXDET dwell timer
  logic [3:0] rx_burst_len;   // length of current received LFPS burst (sat. 8)
  logic [1:0] rx_bursts;      // completed received Polling.LFPS bursts (sat. 2)
  logic [1:0] tx_bursts;      // transmitted Polling.LFPS bursts (sat. 2)
  logic [4:0] warm_cnt;       // consecutive LFPS symbols seen in U0
  logic       warm;           // warm-reset pulse (link back to RXDET)
  logic       rx_idle;        // packet receiver between packets

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      link_state   <= LK_RXDET;
      det_cnt      <= 5'd0;
      rx_burst_len <= 4'd0;
      rx_bursts    <= 2'd0;
      warm_cnt     <= 5'd0;
      warm         <= 1'b0;
      link_up      <= 1'b0;
    end else begin
      warm <= 1'b0;
      case (link_state)
        LK_RXDET: begin
          det_cnt <= det_cnt + 5'd1;
          if (det_cnt == 5'd31) begin
            link_state   <= LK_POLL;
            rx_burst_len <= 4'd0;
            rx_bursts    <= 2'd0;
          end
        end
        LK_POLL: begin
          // received Polling.LFPS burst/idle counting
          if (rx_lfps) begin
            if (rx_burst_len != 4'd8)
              rx_burst_len <= rx_burst_len + 4'd1;
          end else begin
            if ((rx_burst_len == 4'd8) && (rx_bursts != 2'd2))
              rx_bursts <= rx_bursts + 2'd1;
            rx_burst_len <= 4'd0;
          end
          // link up once both directions sent >= 2 Polling.LFPS bursts
          if ((rx_bursts == 2'd2) && (tx_bursts == 2'd2)) begin
            link_state <= LK_U0;
            link_up    <= 1'b1;
            warm_cnt   <= 5'd0;
          end
        end
        default: begin // LK_U0: watch for a warm reset between packets
          if (rx_lfps && rx_idle) begin
            warm_cnt <= warm_cnt + 5'd1;
            if (warm_cnt == 5'd31) begin
              link_state <= LK_RXDET;
              link_up    <= 1'b0;
              warm       <= 1'b1;
            end
          end else
            warm_cnt <= 5'd0;
        end
      endcase
    end
  end

  // ------------------------------------------------------------------
  // storage
  // ------------------------------------------------------------------
  logic [31:0] bulk_mem [0:63];  // bulk buffer, 4 blocks x 16 dwords
  logic [31:0] rx_buf   [0:15];  // staging buffer (committed on good CRC32)
  logic [3:0]  valid_blk;        // block-written flags

  // ------------------------------------------------------------------
  // RX path (host -> device)
  // ------------------------------------------------------------------
  typedef enum logic [3:0] {
    RX_IDLE, RX_DH1, RX_DH2, RX_DH3, RX_PS, RX_PAY,
    RX_RC0, RX_RC1, RX_RC2, RX_RC3, RX_END,
    RX_TP1, RX_TP2, RX_TP3, RX_TP4
  } rx_state_t;
  rx_state_t rx_state;
  assign rx_idle = (rx_state == RX_IDLE);

  logic [7:0]  dph_s1_q, dph_s2_q;      // captured DPH fields
  logic [2:0]  dph_seq_q;
  logic [1:0]  dph_blk_q;
  logic [7:0]  tp_s1_q,  tp_s2_q;       // captured TP fields
  logic [6:0]  rx_pay_cnt;              // payload byte counter 0..63
  logic [23:0] pay_shift;               // dword assembly, LSB-first
  logic [31:0] rx_crc;                  // running payload CRC32
  logic [23:0] crc_shift;               // received CRC32 assembly
  logic [31:0] crc_rcvd;                // received CRC32 value
  logic [2:0]  rx_exp;                  // expected OUT sequence number

  // device -> host IN transfer bookkeeping (owned here, TX only reads)
  logic        in_pend;                 // IN request waiting to be sent
  logic [1:0]  in_blk;                  // block to send
  logic        in_active;               // IN transfer in progress
  logic        await_ack;               // IN DPP sent, waiting for host ACK
  logic [7:0]  ack_timer;               // ACK timeout counter
  logic        resend_req;              // retransmit current IN DPP
  logic [1:0]  retry_cnt;               // retransmission attempts
  logic [2:0]  tx_seq;                  // device-originated data seq number

  // response TP request (owned here, consumed by TX via rsp_taken)
  logic        rsp_pend;
  logic [3:0]  rsp_type;
  logic [2:0]  rsp_seq;
  logic        rsp_retry;
  logic [1:0]  rsp_blk;

  // pulses from TX block
  logic        rsp_taken, in_taken, resend_taken, in_sent;

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      rx_state   <= RX_IDLE;
      dph_s1_q   <= 8'd0;
      dph_s2_q   <= 8'd0;
      dph_seq_q  <= 3'd0;
      dph_blk_q  <= 2'd0;
      tp_s1_q    <= 8'd0;
      tp_s2_q    <= 8'd0;
      rx_pay_cnt <= 7'd0;
      pay_shift  <= 24'd0;
      rx_crc     <= 32'd0;
      crc_shift  <= 24'd0;
      crc_rcvd   <= 32'd0;
      rx_exp     <= 3'd0;
      valid_blk  <= 4'd0;
      in_pend    <= 1'b0;
      in_blk     <= 2'd0;
      in_active  <= 1'b0;
      await_ack  <= 1'b0;
      ack_timer  <= 8'd0;
      resend_req <= 1'b0;
      retry_cnt  <= 2'd0;
      tx_seq     <= 3'd0;
      rsp_pend   <= 1'b0;
      rsp_type   <= TP_ACK;
      rsp_seq    <= 3'd0;
      rsp_retry  <= 1'b0;
      rsp_blk    <= 2'd0;
      irq        <= 1'b0;
    end else begin
      // ---- housekeeping: consume TX pulses, ACK watchdog ------------
      if (rsp_taken)
        rsp_pend <= 1'b0;
      if (in_taken) begin
        in_pend   <= 1'b0;
        in_active <= 1'b1;
        retry_cnt <= 2'd0;
      end
      if (resend_taken) begin
        resend_req <= 1'b0;
        if (retry_cnt == 2'd3) begin
          in_active <= 1'b0;   // give up after 4 attempts
          irq       <= 1'b1;
        end else begin
          retry_cnt <= retry_cnt + 2'd1;
        end
      end
      // v2.5.1 fix: never (re-)arm the ACK watchdog outside an active IN
      // transfer (invariant: watchdog only runs while in_active)
      if (in_sent && in_active) begin
        await_ack <= 1'b1;
        ack_timer <= 8'd0;
      end else if (await_ack) begin
        ack_timer <= ack_timer + 8'd1;
        if (ack_timer == 8'd255) begin  // ACK timeout -> retransmit
          await_ack  <= 1'b0;
          resend_req <= 1'b1;
        end
      end

      // ---- packet receiver FSM --------------------------------------
      if (!rx_idle && !rx_ok) begin
        rx_state <= RX_IDLE;           // symbol decode error inside a packet
        irq      <= 1'b1;
      end else
      case (rx_state)
        RX_IDLE: begin
          if (link_state == LK_U0 && rx_ok) begin
            if (rx_p == SYM_DPH)
              rx_state <= RX_DH1;
            else if (rx_p == SYM_TP)
              rx_state <= RX_TP1;
          end
        end

        // ---- DPH: SOF s1 s2 CRC5 ----
        RX_DH1: begin
          dph_s1_q <= rx_p;
          rx_state <= RX_DH2;
        end
        RX_DH2: begin
          dph_s2_q  <= rx_p;
          dph_seq_q <= rx_p[7:5];
          dph_blk_q <= rx_p[4:3];
          rx_state  <= RX_DH3;
        end
        RX_DH3: begin
          if (rx_p == {3'b000, crc5_16({dph_s2_q, dph_s1_q})}) begin
            if (dph_s1_q[3:0] == TYPE_DATA)
              rx_state <= RX_PS;
            else
              rx_state <= RX_IDLE;   // unsupported header type: drop
          end else begin
            rx_state <= RX_IDLE;     // bad header CRC5: silently drop + irq
            irq      <= 1'b1;
          end
        end

        // ---- DPP: START payload[64] CRC32[4] END ----
        RX_PS: begin
          if (rx_p == SYM_DPP) begin
            rx_state   <= RX_PAY;
            rx_pay_cnt <= 7'd0;
            rx_crc     <= 32'hFFFF_FFFF;
          end else begin
            rx_state <= RX_IDLE;     // missing DPP start
            irq      <= 1'b1;
          end
        end
        RX_PAY: begin
          rx_crc    <= crc32_b(rx_crc, rx_p);
          pay_shift <= {rx_p, pay_shift[23:8]};
          if (rx_pay_cnt[1:0] == 2'b11)
            rx_buf[rx_pay_cnt[5:2]] <= {rx_p, pay_shift};
          rx_pay_cnt <= rx_pay_cnt + 7'd1;
          if (rx_pay_cnt == 7'd63)
            rx_state <= RX_RC0;
        end
        RX_RC0: begin
          crc_shift <= {rx_p, crc_shift[23:8]};
          rx_state  <= RX_RC1;
        end
        RX_RC1: begin
          crc_shift <= {rx_p, crc_shift[23:8]};
          rx_state  <= RX_RC2;
        end
        RX_RC2: begin
          crc_shift <= {rx_p, crc_shift[23:8]};
          rx_state  <= RX_RC3;
        end
        RX_RC3: begin
          crc_rcvd <= {rx_p, crc_shift};
          rx_state <= RX_END;
        end
        RX_END: begin
          rx_state <= RX_IDLE;
          if (rx_p != SYM_END) begin
            irq <= 1'b1;             // framing error
          end else if (crc_rcvd != ~rx_crc) begin
            // bad payload CRC32 -> LBAD, host will retransmit
            rsp_pend  <= 1'b1;
            rsp_type  <= TP_LBAD;
            rsp_seq   <= dph_seq_q;
            rsp_retry <= 1'b0;
            rsp_blk   <= dph_blk_q;
            irq       <= 1'b1;
          end else if (dph_seq_q == rx_exp) begin
            // in-order data: commit staging buffer to bulk buffer
            for (int k = 0; k < 16; k++)
              bulk_mem[{dph_blk_q, k[3:0]}] <= rx_buf[k];
            valid_blk[dph_blk_q] <= 1'b1;
            rx_exp    <= rx_exp + 3'd1;
            rsp_pend  <= 1'b1;
            rsp_type  <= TP_ACK;
            rsp_seq   <= dph_seq_q;
            rsp_retry <= 1'b0;
            rsp_blk   <= dph_blk_q;
          end else if (dph_seq_q == (rx_exp - 3'd1)) begin
            // duplicate (host retry): ACK with retry flag, no rewrite
            rsp_pend  <= 1'b1;
            rsp_type  <= TP_ACK;
            rsp_seq   <= dph_seq_q;
            rsp_retry <= 1'b1;
            rsp_blk   <= dph_blk_q;
          end else begin
            // out-of-order sequence: not ready, drop data
            rsp_pend  <= 1'b1;
            rsp_type  <= TP_NRDY;
            rsp_seq   <= dph_seq_q;
            rsp_retry <= 1'b0;
            rsp_blk   <= dph_blk_q;
            irq       <= 1'b1;
          end
        end

        // ---- TP from host: SOF_TP s1 s2 CRC5 END ----
        RX_TP1: begin
          tp_s1_q  <= rx_p;
          rx_state <= RX_TP2;
        end
        RX_TP2: begin
          tp_s2_q  <= rx_p;
          rx_state <= RX_TP3;
        end
        RX_TP3: begin
          if (rx_p == {3'b000, crc5_16({tp_s2_q, tp_s1_q})})
            rx_state <= RX_TP4;
          else begin
            rx_state <= RX_IDLE;
            irq      <= 1'b1;
          end
        end
        default: begin                 // RX_TP4
          rx_state <= RX_IDLE;
          if (rx_p != SYM_END) begin
            irq <= 1'b1;
          end else if (tp_s1_q[3:0] == TP_ACK) begin
            if (tp_s2_q[1]) begin
              // ACK with in_req: host requests a bulk IN transfer
              if (valid_blk[tp_s2_q[3:2]] && !in_active && !in_pend) begin
                in_pend <= 1'b1;
                in_blk  <= tp_s2_q[3:2];
              end else begin
                // block never written (or device busy): NRDY
                rsp_pend  <= 1'b1;
                rsp_type  <= TP_NRDY;
                rsp_seq   <= tp_s2_q[7:5];
                rsp_retry <= 1'b0;
                rsp_blk   <= tp_s2_q[3:2];
              end
            end else if (await_ack && (tp_s2_q[7:5] == tx_seq)) begin
              // host ACK completes the current device IN transfer
              await_ack <= 1'b0;
              in_active <= 1'b0;
              tx_seq    <= tx_seq + 3'd1;
            end
          end else if (tp_s1_q[3:0] == TP_LBAD) begin
            // host reports bad IN DPP: retransmit
            if (await_ack) begin
              await_ack  <= 1'b0;
              resend_req <= 1'b1;
            end
          end
          // host NRDY: leave await_ack set; ACK watchdog retransmits
        end

      endcase

      // ---- warm reset: abandon sequence state and transfers ---------
      if (warm) begin
        rx_exp     <= 3'd0;
        tx_seq     <= 3'd0;
        in_pend    <= 1'b0;
        in_active  <= 1'b0;
        await_ack  <= 1'b0;
        resend_req <= 1'b0;
        rsp_pend   <= 1'b0;
      end
    end
  end

  // ------------------------------------------------------------------
  // TX path (device -> host)
  // ------------------------------------------------------------------
  typedef enum logic [4:0] {
    TX_LFPS, TX_IDLE,
    TX_TP0, TX_TP1, TX_TP2, TX_TP3, TX_TP4,
    TX_DH0, TX_DH1, TX_DH2, TX_DH3,
    TX_PS, TX_PAY, TX_C0, TX_C1, TX_C2, TX_C3, TX_END
  } tx_state_t;
  tx_state_t tx_state;

  logic [4:0]  lfps_cnt;     // LFPS burst/idle pattern position
  logic [3:0]  tp_type_q;    // latched response-TP fields
  logic [2:0]  tp_seq_q;
  logic        tp_retry_q;
  logic [1:0]  tp_blk_q;
  logic [6:0]  tx_pay_cnt;   // IN payload byte counter 0..63
  logic [31:0] tx_crc;       // running IN payload CRC32

  // IN payload byte select (LSB-first)
  logic [31:0] tx_word;
  logic [7:0]  tx_byte;
  always_comb begin
    tx_word = bulk_mem[{in_blk, tx_pay_cnt[5:2]}];
    case (tx_pay_cnt[1:0])
      2'd0:    tx_byte = tx_word[7:0];
      2'd1:    tx_byte = tx_word[15:8];
      2'd2:    tx_byte = tx_word[23:16];
      default: tx_byte = tx_word[31:24];
    endcase
  end

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      tx_state     <= TX_LFPS;
      tx_p         <= SYM_IDLE;
      lfps_cnt     <= 5'd0;
      tx_bursts    <= 2'd0;
      tp_type_q    <= TP_ACK;
      tp_seq_q     <= 3'd0;
      tp_retry_q   <= 1'b0;
      tp_blk_q     <= 2'd0;
      tx_pay_cnt   <= 7'd0;
      tx_crc       <= 32'd0;
      rsp_taken    <= 1'b0;
      in_taken     <= 1'b0;
      resend_taken <= 1'b0;
      in_sent      <= 1'b0;
    end else begin
      rsp_taken    <= 1'b0;
      in_taken     <= 1'b0;
      resend_taken <= 1'b0;
      in_sent      <= 1'b0;
      if (warm) begin                  // warm reset: back to link training
        tx_state  <= TX_LFPS;
        tx_p      <= SYM_IDLE;
        lfps_cnt  <= 5'd0;
        tx_bursts <= 2'd0;
      end else
      case (tx_state)
        // ---- Polling.LFPS generation: 16 burst + 16 idle, repeating ----
        TX_LFPS: begin
          tx_p <= SYM_IDLE;
          if (link_up)
            tx_state <= TX_IDLE;
          else if (link_state == LK_POLL) begin
            if (!lfps_cnt[4])
              tx_p <= SYM_LFPS;
            lfps_cnt <= lfps_cnt + 5'd1;
            if (lfps_cnt == 5'd15 && tx_bursts != 2'd2)
              tx_bursts <= tx_bursts + 2'd1;
          end
        end

        // ---- priority: response TP > new IN data > IN retransmission ----
        TX_IDLE: begin
          tx_p <= SYM_IDLE;
          if (rsp_pend) begin
            tp_type_q  <= rsp_type;
            tp_seq_q   <= rsp_seq;
            tp_retry_q <= rsp_retry;
            tp_blk_q   <= rsp_blk;
            rsp_taken  <= 1'b1;
            tx_state   <= TX_TP0;
          end else if (in_pend || resend_req) begin
            in_taken     <= in_pend;
            resend_taken <= ~in_pend;
            // v2.5.1 fix: the 4th consecutive failed attempt gives up
            // (housekeeping clears in_active/raises irq on this same
            // resend_taken pulse) -- do not launch a 5th DPP
            if (resend_req && !in_pend && retry_cnt == 2'd3)
              tx_state <= TX_IDLE;
            else
              tx_state <= TX_DH0;
          end
        end

        // ---- transaction packet: SOF_TP s1 s2 CRC5 END ----
        TX_TP0: begin
          tx_p     <= SYM_TP;
          tx_state <= TX_TP1;
        end
        TX_TP1: begin
          tx_p     <= {4'h0, tp_type_q};
          tx_state <= TX_TP2;
        end
        TX_TP2: begin
          tx_p     <= {tp_seq_q, tp_retry_q, tp_blk_q, 1'b0, 1'b0};
          tx_state <= TX_TP3;
        end
        TX_TP3: begin
          tx_p     <= {3'b000, crc5_16({tp_seq_q, tp_retry_q, tp_blk_q, 1'b0, 1'b0,
                                        4'h0, tp_type_q})};
          tx_state <= TX_TP4;
        end
        TX_TP4: begin
          tx_p     <= SYM_END;
          tx_state <= TX_IDLE;
        end

        // ---- IN data packet: DPH + DPP ----
        TX_DH0: begin
          tx_p     <= SYM_DPH;
          tx_state <= TX_DH1;
        end
        TX_DH1: begin
          tx_p     <= {4'h0, TYPE_DATA};
          tx_state <= TX_DH2;
        end
        TX_DH2: begin
          tx_p     <= {tx_seq, in_blk, 3'b000};
          tx_state <= TX_DH3;
        end
        TX_DH3: begin
          tx_p     <= {3'b000, crc5_16({tx_seq, in_blk, 3'b000, 4'h0, TYPE_DATA})};
          tx_state <= TX_PS;
        end
        TX_PS: begin
          tx_p       <= SYM_DPP;
          tx_crc     <= 32'hFFFF_FFFF;
          tx_pay_cnt <= 7'd0;
          tx_state   <= TX_PAY;
        end
        TX_PAY: begin
          tx_p       <= tx_byte;
          tx_crc     <= crc32_b(tx_crc, tx_byte);
          tx_pay_cnt <= tx_pay_cnt + 7'd1;
          if (tx_pay_cnt == 7'd63)
            tx_state <= TX_C0;
        end
        TX_C0: begin
          tx_p     <= ~(tx_crc[7:0]);         // ~CRC32 byte 0 (LSB first)
          tx_state <= TX_C1;
        end
        TX_C1: begin
          tx_p     <= ~(tx_crc[15:8]);
          tx_state <= TX_C2;
        end
        TX_C2: begin
          tx_p     <= ~(tx_crc[23:16]);
          tx_state <= TX_C3;
        end
        TX_C3: begin
          tx_p     <= ~(tx_crc[31:24]);
          tx_state <= TX_END;
        end
        default: begin                 // TX_END
          tx_p     <= SYM_END;
          in_sent  <= 1'b1;
          tx_state <= TX_IDLE;
        end
      endcase
    end
  end

  // differential complement
  assign tx_n = ~tx_p;

endmodule
