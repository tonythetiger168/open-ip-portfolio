// SPDX-License-Identifier: Apache-2.0
// ============================================================================
// USB 2.0 full-speed packet engine, echo mode (pin-shared, half duplex)
// RX: 2-flop line sync, DPLL bit recovery (re-centred on every transition),
//     NRZI decode, SYNC hunt, bit de-stuffing (a 0 after six 1s; a 1 there
//     is a stuff error), PID check, CRC16 residual check (0xB001), EOP
//     (SE0 then J). A frame is PID + 0..MAXB payload bytes + CRC16.
// TX: echoes the last good frame after a 3-bit turnaround: SYNC, PID,
//     payload, inverted CRC16 (x^16+x^15+x^2+1, init 0xFFFF, LSB first),
//     NRZI with bit stuffing from SYNC on, EOP = 2 bits SE0 + 1 bit J, then
//     release (the bus pull-ups hold J).
// Any receive error (SYNC, stuffing, PID, overflow, alignment, CRC) sets the
// sticky rx_err, drops the frame and waits for an idle bus (8 bits of J).
// Apache-2.0
// ============================================================================
module USB2_0_top #(
  parameter int BAUD_DIV = 20,        // clk per half-bit (bit = 2*BAUD_DIV)
  parameter int MAXB     = 8          // max payload bytes
)(
  input  logic        clk,
  input  logic        rst_n,
  inout  tri          dp,
  inout  tri          dm,
  output logic        busy,
  output logic        irq
);
  localparam int BP  = 2 * BAUD_DIV;           // clk per bit
  localparam int CW  = $clog2(BP);
  localparam int NB  = MAXB + 3;               // PID + payload + CRC16
  localparam int BW  = $clog2(NB + 1);
  localparam int LW  = $clog2(MAXB + 1);
  localparam int YW  = (MAXB > 1) ? $clog2(MAXB) : 1;
  localparam int TA_BITS = 3;                  // EOP-to-SYNC turnaround

  function automatic logic [15:0] crc16_u(input logic [15:0] c, input logic b);
    crc16_u = (c >> 1) ^ (((c[0] ^ b)) ? 16'hA001 : 16'h0000);
  endfunction

  // ---------------- line sampling ----------------
  logic dp1, dm1, dp2, dm2, dp3, dm3;
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin dp1 <= 1'b1; dm1 <= 1'b0; dp2 <= 1'b1; dm2 <= 1'b0; dp3 <= 1'b1; dm3 <= 1'b0; end
    else begin dp1 <= dp; dm1 <= dm; dp2 <= dp1; dm2 <= dm1; dp3 <= dp2; dm3 <= dm2; end
  end
  wire line_j   =  dp2 & ~dm2;
  wire line_k   = ~dp2 &  dm2;
  wire line_se0 = ~dp2 & ~dm2;
  wire line_chg = (dp2 != dp3) || (dm2 != dm3);

  // ---------------- RX DPLL: sample mid-bit, re-centre on each edge -------
  logic [CW-1:0] rcnt;
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n)                       rcnt <= '0;
    else if (line_chg)                rcnt <= '0;
    else if (rcnt == CW'(BP - 1))     rcnt <= '0;
    else                              rcnt <= rcnt + 1'b1;
  end
  wire rsamp = !line_chg && (rcnt == CW'(BAUD_DIV - 1));   // never on an edge

  // ---------------- RX ----------------
  typedef enum logic [2:0] {R_IDLE, R_SYNC, R_PKT, R_EOP, R_WAIT} rx_t;
  rx_t           rstate;
  typedef enum logic [2:0] {T_IDLE, T_TA, T_PKT, T_EOP, T_EOPJ} tx_t;
  tx_t           tstate;

  logic          rprev_j;
  logic [2:0]    zcnt;                 // SYNC zeros seen (saturating)
  logic [2:0]    ones;                 // consecutive 1s (stuffing)
  logic [2:0]    rbit;
  logic [6:0]    rsh;
  logic [BW-1:0] nbyte;
  logic [15:0]   rcrc;
  logic [3:0]    rpid, rx_pid;
  logic [7:0]    rbuf [0:MAXB+1];      // payload + CRC16
  logic [LW-1:0] rx_len;
  logic [3:0]    icnt;                 // consecutive J samples (idle hunt)
  logic          rx_err, rx_done;
  wire           d    = (line_j == rprev_j);   // NRZI: no transition = 1
  wire  [7:0]    rbyte = {d, rsh};
  wire           rx_ok = rbit == 3'd0 && nbyte >= BW'(3) && rcrc == 16'hB001;

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      rstate <= R_IDLE; rprev_j <= 1'b1; zcnt <= '0; ones <= '0; rbit <= '0;
      rsh <= '0; nbyte <= '0; rcrc <= '1; rpid <= '0; rx_pid <= '0; rx_len <= '0;
      icnt <= '0; rx_err <= 1'b0; rx_done <= 1'b0;
    end else begin
      rx_done <= 1'b0;
      if (rsamp) begin
        case (rstate)
          R_IDLE: if (line_k && tstate == T_IDLE) begin   // SYNC bit 0
            rstate <= R_SYNC; rprev_j <= 1'b0; zcnt <= 3'd1;
          end
          R_SYNC: begin
            rprev_j <= line_j;
            if (line_se0) begin rstate <= R_WAIT; rx_err <= 1'b1; icnt <= '0; end
            else if (!d) zcnt <= (zcnt == 3'd7) ? zcnt : zcnt + 3'd1;
            else if (zcnt >= 3'd5) begin                  // SYNC's closing 1
              rstate <= R_PKT; ones <= 3'd1; rbit <= '0; nbyte <= '0; rcrc <= '1;
            end else begin rstate <= R_WAIT; rx_err <= 1'b1; icnt <= '0; end
          end
          R_PKT: begin
            rprev_j <= line_j;
            if (line_se0) rstate <= R_EOP;
            else if (ones == 3'd6) begin                  // stuffed bit
              if (d) begin rstate <= R_WAIT; rx_err <= 1'b1; icnt <= '0; end
              ones <= '0;
            end else begin
              ones <= d ? ones + 3'd1 : 3'd0;
              rsh  <= rbyte[7:1];
              rbit <= rbit + 3'd1;
              if (nbyte != '0) rcrc <= crc16_u(rcrc, d);
              if (rbit == 3'd7) begin
                nbyte <= nbyte + 1'b1;
                if (nbyte == '0) begin
                  rpid <= rbyte[3:0];
                  if (rbyte[7:4] != ~rbyte[3:0]) begin rstate <= R_WAIT; rx_err <= 1'b1; icnt <= '0; end
                end else if (nbyte == BW'(NB)) begin       // too long
                  rstate <= R_WAIT; rx_err <= 1'b1; icnt <= '0;
                end else rbuf[nbyte - 1'b1] <= rbyte;
              end
            end
          end
          R_EOP: begin                                    // SE0 ... then J
            if (line_j) begin
              rstate <= R_IDLE;
              if (rx_ok) begin
                rx_done <= 1'b1; rx_pid <= rpid; rx_len <= LW'(nbyte - BW'(3));
              end else rx_err <= 1'b1;
            end else if (line_k) begin rstate <= R_WAIT; rx_err <= 1'b1; icnt <= '0; end
          end
          R_WAIT: begin                                   // idle hunt
            icnt <= line_j ? icnt + 4'd1 : 4'd0;
            if (line_j && icnt == 4'd7) rstate <= R_IDLE;
          end
          default: rstate <= R_IDLE;                      // unused encodings
        endcase
      end
    end
  end

  // ---------------- TX ----------------
  logic [CW-1:0] tcnt;
  logic [1:0]    fld;                  // 0 SYNC, 1 PID, 2 DATA, 3 CRC
  logic [3:0]    tbi;                  // bit within field
  logic [YW-1:0] tby;                  // payload byte
  logic [2:0]    tones;
  logic          tlast;                // last CRC bit sent
  logic [15:0]   tcrc;
  logic [3:0]    tx_pid;
  logic [LW-1:0] tx_len;
  logic          oe_q, dp_q;           // dm is driven as ~dp except in SE0
  logic          se0_q;
  wire           tedge = (tcnt == CW'(BP - 1));
  wire  [7:0]    tpid  = {~tx_pid, tx_pid};
  wire  [7:0]    tdat  = rbuf[tby];
  wire           tbitv = (fld == 2'd0) ? (tbi == 4'd7) :
                         (fld == 2'd1) ? tpid[tbi[2:0]] :
                         (fld == 2'd2) ? tdat[tbi[2:0]] : ~tcrc[0];

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      tstate <= T_IDLE; tcnt <= '0; fld <= '0; tbi <= '0; tby <= '0; tones <= '0;
      tlast <= 1'b0; tcrc <= '1; tx_pid <= '0; tx_len <= '0;
      oe_q <= 1'b0; dp_q <= 1'b1; se0_q <= 1'b0;
    end else begin
      tcnt <= (tstate == T_IDLE || tedge) ? '0 : tcnt + 1'b1;
      case (tstate)
        T_IDLE: if (rx_done) begin
          tx_pid <= rx_pid; tx_len <= rx_len;
          tbi <= '0; tstate <= T_TA;
        end
        T_TA: if (tedge) begin
          if (tbi == 4'(TA_BITS - 1)) begin
            tstate <= T_PKT; fld <= '0; tbi <= 4'd1; tby <= '0; tones <= '0;
            tlast <= 1'b0; tcrc <= '1;
            oe_q <= 1'b1; dp_q <= 1'b0;                   // SYNC bit 0: K
          end else tbi <= tbi + 4'd1;
        end
        T_PKT: if (tedge) begin
          if (tones == 3'd6) begin                        // stuff a 0
            dp_q <= ~dp_q; tones <= '0;
          end else if (tlast) begin
            tstate <= T_EOP; se0_q <= 1'b1; tbi <= '0;
          end else begin
            if (!tbitv) dp_q <= ~dp_q;
            tones <= tbitv ? tones + 3'd1 : 3'd0;
            case (fld)
              2'd0: begin                                 // SYNC 0000_0001
                if (tbi == 4'd7) begin fld <= 2'd1; tbi <= '0; end
                else tbi <= tbi + 4'd1;
              end
              2'd1: begin
                if (tbi == 4'd7) begin
                  tbi <= '0; fld <= (tx_len == '0) ? 2'd3 : 2'd2;
                end else tbi <= tbi + 4'd1;
              end
              2'd2: begin
                tcrc <= crc16_u(tcrc, tbitv);
                if (tbi == 4'd7) begin
                  tbi <= '0;
                  if (LW'(tby) == tx_len - 1'b1) fld <= 2'd3;
                  else tby <= tby + 1'b1;
                end else tbi <= tbi + 4'd1;
              end
              default: begin                              // CRC, inverted
                tcrc <= tcrc >> 1;
                if (tbi == 4'd15) tlast <= 1'b1;
                else tbi <= tbi + 4'd1;
              end
            endcase
          end
        end
        T_EOP: if (tedge) begin                           // 2 bit times SE0
          if (tbi == 4'd1) begin tstate <= T_EOPJ; se0_q <= 1'b0; dp_q <= 1'b1; end
          else tbi <= tbi + 4'd1;
        end
        T_EOPJ: if (tedge) begin                          // 1 bit time J
          oe_q <= 1'b0; tstate <= T_IDLE;
        end
        default: tstate <= T_IDLE;                        // unused encodings
      endcase
    end
  end

  assign dp = oe_q ? (dp_q & ~se0_q) : 1'bz;
  assign dm = oe_q ? (~dp_q & ~se0_q) : 1'bz;

  assign busy = (rstate != R_IDLE) || (tstate != T_IDLE);
  assign irq  = rx_done;
  // rx_err is a debug status: this pinout has no register port to read it
  wire _unused = &{1'b0, rx_err};

endmodule
