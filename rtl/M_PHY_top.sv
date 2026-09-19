// SPDX-License-Identifier: Apache-2.0
// ============================================================================
// MIPI M-PHY lane (8b/10b, PWM-gear rates, HIBERN8) with loopback decoder
// Implementation scope:
//   * 8b/10b codec, documented subset: D-codes D0.0..D7.0 (8'h00..8'h07)
//     plus control code K28.5 (8'hBC, comma). Encoding follows the standard
//     table with running-disparity (RD) tracking per 6b/4b sub-block; the
//     decoder accepts both RD forms, checks sub-block disparity alternation
//     and flags code / disparity violations on irq.
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
//     returns the RX to hunt.
// IP design implementation v1.0 -- Apache-2.0
// ============================================================================
module M_PHY_top #(
  parameter int DW = 32,        // retained framework parameter (data width)
  parameter int AW = 32         // retained framework parameter (address width)
)(
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
  input  logic [7:0] tx_data,     // payload byte (subset 8'h00..8'h07)
  input  logic       tx_k,        // 1 = control code (K28.5 = 8'hBC)
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
  // 8b/10b code table (subset), word bit 9 = 'a' (transmitted first)
  // ------------------------------------------------------------------
  localparam logic [9:0] K28P_RDN = 10'b0011111010; // K28.5, RD- form
  localparam logic [9:0] K28P_RDP = 10'b1100000101; // K28.5, RD+ form

  // encode: {valid, word[9:0]}, rd = current running disparity (0 = RD-)
  function automatic logic [10:0] enc10(input logic [7:0] d,
                                        input logic k, input logic rd);
    if (k) begin
      if (d == 8'hBC)
        enc10 = {1'b1, rd ? K28P_RDP : K28P_RDN};
      else
        enc10 = {1'b0, 10'd0};                 // unsupported K-code
    end else begin
      case (d)
        8'h00: enc10 = {1'b1, rd ? 10'b0110001011 : 10'b1001110100}; // D0.0
        8'h01: enc10 = {1'b1, rd ? 10'b1000101011 : 10'b0111010100}; // D1.0
        8'h02: enc10 = {1'b1, rd ? 10'b0100101011 : 10'b1011010100}; // D2.0
        8'h03: enc10 = {1'b1, rd ? 10'b1100010100 : 10'b1100011011}; // D3.0
        8'h04: enc10 = {1'b1, rd ? 10'b0010101011 : 10'b1101010100}; // D4.0
        8'h05: enc10 = {1'b1, rd ? 10'b1010010100 : 10'b1010011011}; // D5.0
        8'h06: enc10 = {1'b1, rd ? 10'b0110010100 : 10'b0110011011}; // D6.0
        8'h07: enc10 = {1'b1, rd ? 10'b0001110100 : 10'b1110001011}; // D7.0
        default: enc10 = {1'b0, 10'd0};        // outside implemented subset
      endcase
    end
  endfunction

  // decode: {valid, k, byte[7:0]}; both RD forms accepted
  function automatic logic [9:0] dec10(input logic [9:0] w);
    case (w)
      10'b1001110100, 10'b0110001011: dec10 = {1'b1, 1'b0, 8'h00};
      10'b0111010100, 10'b1000101011: dec10 = {1'b1, 1'b0, 8'h01};
      10'b1011010100, 10'b0100101011: dec10 = {1'b1, 1'b0, 8'h02};
      10'b1100011011, 10'b1100010100: dec10 = {1'b1, 1'b0, 8'h03};
      10'b1101010100, 10'b0010101011: dec10 = {1'b1, 1'b0, 8'h04};
      10'b1010011011, 10'b1010010100: dec10 = {1'b1, 1'b0, 8'h05};
      10'b0110011011, 10'b0110010100: dec10 = {1'b1, 1'b0, 8'h06};
      10'b1110001011, 10'b0001110100: dec10 = {1'b1, 1'b0, 8'h07};
      10'b0011111010, 10'b1100000101: dec10 = {1'b1, 1'b1, 8'hBC};
      default:                        dec10 = {1'b0, 1'b0, 8'd0};
    endcase
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
  logic [3:0] wake_cnt;
  logic       buf_valid;
  logic [7:0] buf_data;
  logic       buf_k;
  logic       err_tx;

  assign tx_ready = ~buf_valid & (tstate == T_IDLE || tstate == T_SHIFT);
  assign hibern8  = (tstate == T_SAVE);

  // candidate word from the buffer + its running-disparity update
  wire [10:0] enc      = enc10(buf_data, buf_k, tx_rd);
  wire [9:0]  ew       = enc[9:0];
  wire        enc_ok   = enc[10];
  wire [2:0]  e_ones6  = ew[9] + ew[8] + ew[7] + ew[6] + ew[5] + ew[4];
  wire [2:0]  e_ones4  = ew[3] + ew[2] + ew[1] + ew[0];
  wire        e_rd6    = (e_ones6 == 3'd3) ? tx_rd : (e_ones6 > 3'd3);
  wire        e_rd4    = (e_ones4 == 3'd2) ? e_rd6 : (e_ones4 > 3'd2);

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      tstate     <= T_IDLE;
      tx_word    <= 10'd0;
      bit_cnt    <= 4'd0;
      tx_tick    <= 1'b0;
      tx_rd      <= 1'b0;
      wake_cnt   <= 4'd0;
      buf_valid  <= 1'b0;
      buf_data   <= 8'd0;
      buf_k      <= 1'b0;
      err_tx     <= 1'b0;
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
          if (hibern8_req && !buf_valid) begin
            tstate <= T_SAVE;
          end else if (buf_valid) begin
            if (enc_ok) begin
              // one idle clk elapses before the first bit of the burst;
              // harmless: the RX hunt ignores leading idle bits
              tstate    <= T_SHIFT;
              tx_word   <= ew;
              bit_cnt   <= 4'd0;
              tx_tick   <= 1'b0;
              tx_rd     <= e_rd4;
              buf_valid <= 1'b0;
            end else begin
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
            wake_cnt <= 4'd0;
          end
        end
        T_WAKE: begin
          // 8-clk DIF-N wake burst (real M-PHY: DIF-N burst + PWM sync)
          if (wake_cnt == 4'd7) tstate <= T_IDLE;
          else                  wake_cnt <= wake_cnt + 4'd1;
        end
        default: tstate <= T_IDLE;
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
  logic [19:0] hunt_sr;
  logic [9:0] wr;
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
  wire [2:0]  f_ones6 = frame[9] + frame[8] + frame[7] + frame[6] + frame[5] + frame[4];
  wire [2:0]  f_ones4 = frame[3] + frame[2] + frame[1] + frame[0];
  wire        f_viol6 = (f_ones6 != 3'd3) && ((f_ones6 > 3'd3) != (rx_rd == 1'b0));
  wire        f_rd6   = (f_ones6 == 3'd3) ? rx_rd : (f_ones6 > 3'd3);
  wire        f_viol4 = (f_ones4 != 3'd2) && ((f_ones4 > 3'd2) != (f_rd6 == 1'b0));
  wire        f_rd4   = (f_ones4 == 3'd2) ? f_rd6 : (f_ones4 > 3'd2);
  wire [9:0]  f_dec   = dec10(frame);

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      rstate     <= H_HUNT;
      hunt_sr    <= 20'd0;
      wr         <= 10'd0;
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
          hunt_sr <= {hunt_sr[18:0], rx_dif_p};
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
            wr      <= frame;
            if (rbit_cnt == 4'd9) begin
              rbit_cnt <= 4'd0;
              if (frame == 10'd0) begin
                rstate <= H_HUNT;      // idle word: burst over, re-hunt
              end else if (!f_dec[9] || f_viol6 || f_viol4) begin
                err_rx <= 1'b1;    // code / disparity violation
                rx_rd      <= f_rd4;
              end else begin
                rx_data  <= f_dec[7:0];
                rx_k     <= f_dec[8];
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
            hunt_sr <= 20'd0;
          end
        end
        default: rstate <= H_HUNT;
      endcase
    end
  end

endmodule
