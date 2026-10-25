// SPDX-License-Identifier: Apache-2.0
// ============================================================================
// MIPI M-PHY lane (8b/10b, PWM-gear rates, HIBERN8) with loopback decoder
// Implementation scope:
//   * Full 8b/10b codec: all 256 D-codes and the 12 K-codes (K28.0..K28.7,
//     K23.7, K27.7, K29.7, K30.7), standard 5b/6b and 3b/4b tables with
//     the D.x.A7 and K28 comma rules and running-disparity (RD) tracking.
//     The TX rejects other K-codes (dropped, irq). The RX decodes each
//     word and re-encodes it with the current RD, so any code or disparity
//     violation raises irq.
//   * PWM gears simplified to NRZ bit-rate division (real M-PHY TYPE-I uses
//     PWM pulse widths at LS gears; the gearing itself is kept): G1 = 1 bit
//     per clk, G2 = 1 bit per 2 clk, selected by the gear input. Gear may
//     only change while the lane is idle (documented host contract).
//   * Line states on tx_dif_p/tx_dif_n: DIF-N (0,1) = idle / bit 0,
//     DIF-P (1,0) = bit 1, DIF-Z (0,0) = high-Z during HIBERN8.
//   * HIBERN8: hibern8_req enters the SAVE state (hibern8 power-down flag
//     raised, lines DIF-Z); wake_req drives an 8-clk DIF-N wake burst and
//     returns to normal idle. RX detects DIF-Z persistence as hibernation
//     and re-hunts after wake.
//   * Bursts: K28.5 comma (bit 'a' first) for RX alignment, then 8b/10b
//     data words back-to-back; a 1-deep buffer keeps the stream seamless.
//     RX hunts for the comma (clk-resolution shift register, gear-aware),
//     then frames every 10 bits; an all-zero idle word ends the burst and
//     returns the RX to hunt. The TX therefore keeps the line idle for at
//     least 10 bit times between bursts (inter-burst STALL), so the RX always
//     sees that idle word and re-acquires the comma of the next burst.
// IP design implementation v1.1 -- Apache-2.0
// ============================================================================
module M_PHY_top (
  input  logic       clk,
  input  logic       rst_n,
  output logic       irq,         // sticky protocol-error flag
  input  logic       irq_clear,

  input  logic       gear,        // 0 = G1 (1 bit/clk), 1 = G2 (1 bit/2 clk)

  // ---- HIBERN8 control ----
  input  logic       hibern8_req, // pulse: enter SAVE state (when idle)
  input  logic       wake_req,    // pulse: leave SAVE state
  output logic       hibern8,     // SAVE state power-down flag

  // ---- TX byte interface ----
  input  logic [7:0] tx_data,     // payload byte
  input  logic       tx_k,        // 1 = control code (K28.5 = 8'hBC is the comma)
  input  logic       tx_valid,
  output logic       tx_ready,

  // ---- serial line ----
  output logic       tx_dif_p,
  output logic       tx_dif_n,
  input  logic       rx_dif_p,    // loopback in TB
  input  logic       rx_dif_n,

  // ---- RX decode outputs ----
  output logic       rx_locked,   // comma acquired, framing 8b/10b words
  output logic       rx_hibern,   // line observed in DIF-Z (hibernated)
  output logic [7:0] rx_data,
  output logic       rx_k,
  output logic       rx_valid
);

  // ------------------------------------------------------------------
  // 8b/10b codec (IEEE 802.3 clause 36 tables), word bit 9 = 'a' (sent
  // first), layout abcdei fghj. rd = running disparity, 0 = RD-, 1 = RD+.
  // ------------------------------------------------------------------
  localparam logic [9:0] K28P_RDN = 10'b0011111010; // K28.5, RD- form
  localparam logic [9:0] K28P_RDP = 10'b1100000101; // K28.5, RD+ form

  // 5b/6b, RD- column
  function automatic logic [5:0] t6(input logic [4:0] x);
    case (x)
      5'd0:  t6 = 6'b100111;  5'd1:  t6 = 6'b011101;  5'd2:  t6 = 6'b101101;
      5'd3:  t6 = 6'b110001;  5'd4:  t6 = 6'b110101;  5'd5:  t6 = 6'b101001;
      5'd6:  t6 = 6'b011001;  5'd7:  t6 = 6'b111000;  5'd8:  t6 = 6'b111001;
      5'd9:  t6 = 6'b100101;  5'd10: t6 = 6'b010101;  5'd11: t6 = 6'b110100;
      5'd12: t6 = 6'b001101;  5'd13: t6 = 6'b101100;  5'd14: t6 = 6'b011100;
      5'd15: t6 = 6'b010111;  5'd16: t6 = 6'b011011;  5'd17: t6 = 6'b100011;
      5'd18: t6 = 6'b010011;  5'd19: t6 = 6'b110010;  5'd20: t6 = 6'b001011;
      5'd21: t6 = 6'b101010;  5'd22: t6 = 6'b011010;  5'd23: t6 = 6'b111010;
      5'd24: t6 = 6'b110011;  5'd25: t6 = 6'b100110;  5'd26: t6 = 6'b010110;
      5'd27: t6 = 6'b110110;  5'd28: t6 = 6'b001110;  5'd29: t6 = 6'b101110;
      5'd30: t6 = 6'b011110;  default: t6 = 6'b101011;
    endcase
  endfunction

  // 3b/4b, RD- column (y = 7 is the primary P7 form)
  function automatic logic [3:0] t4(input logic [2:0] y);
    case (y)
      3'd0: t4 = 4'b1011;  3'd1: t4 = 4'b1001;  3'd2: t4 = 4'b0101;
      3'd3: t4 = 4'b1100;  3'd4: t4 = 4'b1101;  3'd5: t4 = 4'b1010;
      3'd6: t4 = 4'b0110;  default: t4 = 4'b1110;
    endcase
  endfunction

  function automatic logic [2:0] ones4(input logic [3:0] v);
    ones4 = 3'(v[0]) + 3'(v[1]) + 3'(v[2]) + 3'(v[3]);
  endfunction
  function automatic logic [2:0] ones6(input logic [5:0] v);
    ones6 = 3'(v[0]) + 3'(v[1]) + 3'(v[2]) + 3'(v[3]) + 3'(v[4]) + 3'(v[5]);
  endfunction

  // K28.0..K28.7, K23.7, K27.7, K29.7, K30.7
  function automatic logic k_ok(input logic [7:0] d);
    k_ok = (d[4:0] == 5'd28) ||
           (d[7:5] == 3'd7 && (d[4:0] == 5'd23 || d[4:0] == 5'd27 ||
                               d[4:0] == 5'd29 || d[4:0] == 5'd30));
  endfunction

  // encode: {valid, rd_out, word[9:0]}
  function automatic logic [11:0] enc10(input logic [7:0] d, input logic k, input logic rd);
    logic [4:0] x;
    logic [2:0] y;
    logic [5:0] s6;
    logic [3:0] s4;
    logic       rd6, a7, k28;
    x   = d[4:0];
    y   = d[7:5];
    k28 = k && x == 5'd28;
    s6  = k28 ? 6'b001111 : t6(x);
    if (rd && (ones6(s6) != 3'd3 || (!k && x == 5'd7))) s6 = ~s6;
    rd6 = (ones6(s6) == 3'd3) ? rd : (ones6(s6) > 3'd3);
    a7  = y == 3'd7 && (k || (!rd6 && (x == 5'd17 || x == 5'd18 || x == 5'd20)) ||
                             (rd6 && (x == 5'd11 || x == 5'd13 || x == 5'd14)));
    s4  = a7 ? 4'b0111 : t4(y);
    if (k28 && (y == 3'd1 || y == 3'd2 || y == 3'd5 || y == 3'd6)) begin
      if (!rd6) s4 = ~s4;                  // keep the comma property
    end else if (rd6 && (ones4(s4) != 3'd2 || y == 3'd3)) s4 = ~s4;
    enc10 = {!k || k_ok(d), (ones4(s4) == 3'd2) ? rd6 : (ones4(s4) > 3'd2), s6, s4};
  endfunction

  function automatic logic [9:0] enc_w(input logic [7:0] d, input logic k, input logic rd);
    // verilator lint_off UNUSEDSIGNAL
    logic [11:0] e;                        // valid / rd bits not needed here
    // verilator lint_on UNUSEDSIGNAL
    e     = enc10(d, k, rd);
    enc_w = e[9:0];
  endfunction

  // candidate byte from the sub-blocks; the caller re-encodes it with the
  // current running disparity, so any code or disparity error mismatches
  function automatic logic [4:0] d6(input logic [5:0] s);
    d6 = 5'd0;
    for (int i = 0; i < 32; i++)
      if (s == t6(5'(i)) || (s == ~t6(5'(i)) && (ones6(s) != 3'd3 || i == 7))) d6 = 5'(i);
    if (s == 6'b001111 || s == 6'b110000) d6 = 5'd28;
  endfunction
  function automatic logic [2:0] d4(input logic [3:0] s);
    d4 = 3'd7;                             // P7 / A7 forms
    for (int i = 0; i < 7; i++)
      if (s == t4(3'(i)) || (s == ~t4(3'(i)) && (ones4(s) != 3'd2 || i == 3))) d4 = 3'(i);
  endfunction

  // duplicate each bit (G2 hunt pattern: every bit lasts 2 clk)
  function automatic logic [19:0] dup10(input logic [9:0] w);
    for (int i = 0; i < 10; i++)
      dup10[2*i +: 2] = {2{w[i]}};
  endfunction

  // ------------------------------------------------------------------
  // TX
  // ------------------------------------------------------------------
  typedef enum logic [1:0] {T_IDLE, T_SHIFT, T_SAVE, T_WAKE} tstate_t;
  tstate_t   tstate;
  logic [9:0] tx_word;
  logic [3:0] bit_cnt;
  logic       tx_tick;
  logic       tx_rd;
  logic [2:0] wake_cnt;
  logic       buf_valid;
  logic [7:0] buf_data;
  logic       buf_k;
  logic       err_tx;
  logic [4:0] gap_cnt;     // inter-burst idle still owed (clks)

  assign tx_ready = ~buf_valid & (tstate == T_IDLE || tstate == T_SHIFT);
  assign hibern8  = (tstate == T_SAVE);

  // candidate word from the buffer + its running-disparity update
  wire [11:0] enc      = enc10(buf_data, buf_k, tx_rd);
  wire [9:0]  ew       = enc[9:0];
  wire        enc_ok   = enc[11];
  wire        e_rd4    = enc[10];

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      tstate     <= T_IDLE;
      tx_word    <= 10'd0;
      bit_cnt    <= 4'd0;
      tx_tick    <= 1'b0;
      tx_rd      <= 1'b0;
      wake_cnt   <= 3'd0;
      buf_valid  <= 1'b0;
      buf_data   <= 8'd0;
      buf_k      <= 1'b0;
      err_tx     <= 1'b0;
      gap_cnt    <= 5'd0;
    end else begin
      if (irq_clear) err_tx <= 1'b0;

      if (tx_valid && tx_ready) begin
        buf_valid <= 1'b1;
        buf_data  <= tx_data;
        buf_k     <= tx_k;
      end

      case (tstate)
        T_IDLE: begin
          tx_tick <= 1'b0;
          if (gap_cnt != 5'd0) gap_cnt <= gap_cnt - 5'd1;
          if (hibern8_req && !buf_valid) begin
            tstate <= T_SAVE;
          end else if (buf_valid) begin
            if (enc_ok && gap_cnt == 5'd0) begin
              // one idle clk elapses before the first bit of the burst;
              // harmless: the RX hunt ignores leading idle bits
              tstate    <= T_SHIFT;
              tx_word   <= ew;
              bit_cnt   <= 4'd0;
              tx_tick   <= 1'b0;
              tx_rd     <= e_rd4;
              buf_valid <= 1'b0;
            end else if (!enc_ok) begin
              err_tx <= 1'b1;      // byte outside the 8b/10b subset
              buf_valid  <= 1'b0;
            end
          end
        end
        T_SHIFT: begin
          if (tx_tick == gear) begin
            tx_tick <= 1'b0;
            if (bit_cnt == 4'd9) begin
              // word finished: seamless wrap if another byte is buffered
              if (buf_valid && enc_ok) begin
                tx_word   <= ew;
                bit_cnt   <= 4'd0;
                tx_rd     <= e_rd4;
                buf_valid <= 1'b0;
              end else begin
                if (buf_valid && !enc_ok) begin
                  err_tx <= 1'b1;
                  buf_valid  <= 1'b0;
                end
                tstate  <= T_IDLE;
                bit_cnt <= 4'd0;
                gap_cnt <= gear ? 5'd20 : 5'd10;   // >= 10 idle bit times
              end
            end else begin
              tx_word <= {tx_word[8:0], 1'b0};
              bit_cnt <= bit_cnt + 4'd1;
            end
          end else begin
            tx_tick <= 1'b1;
          end
        end
        T_SAVE: begin
          if (wake_req) begin
            tstate   <= T_WAKE;
            wake_cnt <= 3'd0;
          end
        end
        T_WAKE: begin
          // 8-clk DIF-N wake burst (real M-PHY: DIF-N burst + PWM sync)
          if (wake_cnt == 3'd7) tstate <= T_IDLE;
          else                  wake_cnt <= wake_cnt + 3'd1;
        end
      endcase
    end
  end

  // line drivers: DIF-Z in SAVE, DIF-N idle/wake, data bit in SHIFT
  always_comb begin
    tx_dif_p = 1'b0;
    tx_dif_n = 1'b1;                       // DIF-N (idle / wake)
    case (tstate)
      T_SAVE:  {tx_dif_p, tx_dif_n} = 2'b00;   // DIF-Z (high-Z simplified)
      T_SHIFT: {tx_dif_p, tx_dif_n} = {tx_word[9], ~tx_word[9]};
      default: ;
    endcase
  end

  // ------------------------------------------------------------------
  // RX
  // ------------------------------------------------------------------
  typedef enum logic [1:0] {H_HUNT, H_LOCK, H_HIB} rstate_t;
  rstate_t   rstate;
  logic [18:0] hunt_sr;
  logic [8:0] wr;
  logic [3:0] rbit_cnt;
  logic       rx_tick;
  logic       rx_rd;
  logic       gear_q;
  logic [1:0] hib_cnt;
  logic       err_rx;

  assign rx_locked = (rstate == H_LOCK);
  assign rx_hibern = (rstate == H_HIB);
  assign irq       = err_tx | err_rx;

  // comma match (including the bit arriving this clk)
  wire [9:0]  h10 = {hunt_sr[8:0], rx_dif_p};
  wire [19:0] h20 = {hunt_sr[18:0], rx_dif_p};
  wire        m_n = gear ? (h20 == dup10(K28P_RDN)) : (h10 == K28P_RDN);
  wire        m_p = gear ? (h20 == dup10(K28P_RDP)) : (h10 == K28P_RDP);

  // completed frame + running-disparity check
  wire [9:0]  frame   = {wr[8:0], rx_dif_p};
  wire [4:0]  f_x     = d6(frame[9:4]);
  wire [2:0]  f_y     = d4((frame[9:4] == 6'b110000) ? ~frame[3:0] : frame[3:0]);
  wire        f_isd   = enc_w({f_y, f_x}, 1'b0, rx_rd) == frame;
  wire        f_isk   = k_ok({f_y, f_x}) && enc_w({f_y, f_x}, 1'b1, rx_rd) == frame;
  // running disparity carried on from the received word, valid or not
  wire [2:0]  f_n6    = ones6(frame[9:4]);
  wire [2:0]  f_n4    = ones4(frame[3:0]);
  wire        f_rd6   = (f_n6 == 3'd3) ? rx_rd : (f_n6 > 3'd3);
  wire        f_rd4   = (f_n4 == 3'd2) ? f_rd6 : (f_n4 > 3'd2);

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      rstate     <= H_HUNT;
      hunt_sr    <= 19'd0;
      wr         <= 9'd0;
      rbit_cnt   <= 4'd0;
      rx_tick    <= 1'b0;
      rx_rd      <= 1'b0;
      gear_q     <= 1'b0;
      hib_cnt    <= 2'd0;
      rx_data    <= 8'd0;
      rx_k       <= 1'b0;
      rx_valid   <= 1'b0;
      err_rx     <= 1'b0;
    end else begin
      rx_valid <= 1'b0;
      gear_q   <= gear;
      if (irq_clear) err_rx <= 1'b0;

      // DIF-Z persistence detector (hibernation)
      if (rx_dif_p == 1'b0 && rx_dif_n == 1'b0) begin
        if (hib_cnt != 2'd3) hib_cnt <= hib_cnt + 2'd1;
        if (hib_cnt >= 2'd2) rstate <= H_HIB;
      end else begin
        hib_cnt <= 2'd0;
      end

      case (rstate)
        H_HUNT: begin
          hunt_sr <= {hunt_sr[17:0], rx_dif_p};
          if (m_n || m_p) begin
            rstate   <= H_LOCK;
            rbit_cnt <= 4'd0;
            rx_tick  <= 1'b0;
            // after an RD- comma the running disparity is RD+, and vice versa
            rx_rd    <= m_n ? 1'b1 : 1'b0;
            // the comma itself is a decoded K28.5 word
            rx_data  <= 8'hBC;
            rx_k     <= 1'b1;
            rx_valid <= 1'b1;
          end
        end
        H_LOCK: begin
          if (gear != gear_q) begin
            rstate <= H_HUNT;          // gear switched: re-align
          end else if (gear == 1'b0 || rx_tick == 1'b1) begin
            rx_tick <= 1'b0;
            wr      <= frame[8:0];
            if (rbit_cnt == 4'd9) begin
              rbit_cnt <= 4'd0;
              if (frame == 10'd0) begin
                rstate <= H_HUNT;      // idle word: burst over, re-hunt
              end else if (!f_isd && !f_isk) begin
                err_rx <= 1'b1;    // code / disparity violation
                rx_rd      <= f_rd4;
              end else begin
                rx_data  <= {f_y, f_x};
                rx_k     <= f_isk;
                rx_valid <= 1'b1;
                rx_rd    <= f_rd4;
              end
            end else begin
              rbit_cnt <= rbit_cnt + 4'd1;
            end
          end else begin
            rx_tick <= 1'b1;
          end
        end
        H_HIB: begin
          if (rx_dif_p || rx_dif_n) begin
            rstate  <= H_HUNT;         // wake observed: re-align
            hunt_sr <= 19'd0;
          end
        end
        default: rstate <= H_HUNT;
      endcase
    end
  end

endmodule
