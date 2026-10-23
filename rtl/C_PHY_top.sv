// SPDX-License-Identifier: Apache-2.0
// ============================================================================
// MIPI C-PHY trio (3-wire, 3-level) HS transmitter with same-trio decoder
// Implementation scope:
//   * Trio wires A/B/C each drive one of three levels {low, mid, high},
//     encoded 2 bits per wire (00 = low, 01 = mid, 10 = high). One symbol
//     per clk (the wire-rate clocking is abstracted).
//   * The six C-PHY wire states, as {A, B, C}:
//       +x = (H,L,M)  -x = (L,H,M)  +y = (M,H,L)  -y = (M,L,H)
//       +z = (L,M,H)  -z = (H,M,L)
//     Idle (LP stop) is shown as all wires mid.
//   * Every symbol is a state transition, 3 bits {Flip, Rotation,
//     Polarity}, so consecutive states always differ and the receiver
//     recovers timing from every unit interval:
//       Flip = 1      (symbol 4): same wire pair, opposite polarity
//       Flip = 0, Rotation = 1  : x -> y -> z -> x (clockwise)
//       Flip = 0, Rotation = 0  : x -> z -> y -> x (counter-clockwise)
//                 Polarity = 1  : opposite polarity, 0: same polarity
//     Symbols 5..7 do not exist.
//   * Burst: the TX enters HS on +x, sends the sync word 3444443, then 7
//     symbols per 16-bit word, then the post-amble 4444444, and returns to
//     idle. The 16-bit -> 7-symbol mapper here is base 5, least
//     significant digit first (symbol i = (v / 5^i) mod 5); it is
//     bijective but it is not the mapping table of the MIPI specification.
//     The post-amble decodes to 78124, which no 16-bit word can produce,
//     so the receiver tells it apart from data.
//   * RX decodes the trio: burst entry on +x, sync check, transition to
//     symbol, words, post-amble, then a clean return to idle (rx_done).
//     Sticky irq on: a burst not entering on +x, a wrong sync symbol, an
//     invalid wire state, a missing transition, a 7-symbol group above
//     65535 that is not the post-amble, a stop inside a word or without a
//     post-amble, or anything but 4 after the post-amble. After an error
//     the receiver waits for idle.
// IP design implementation v1.1 -- Apache-2.0
// ============================================================================
module C_PHY_top (
  input  logic        clk,
  input  logic        rst_n,
  output logic        irq,        // sticky protocol-error flag (RX decoder)
  input  logic        irq_clear,

  // ---- host TX word stream ----
  input  logic [15:0] tx_data,    // 16-bit payload word
  input  logic        tx_valid,
  output logic        tx_ready,
  input  logic        tx_last,    // marks the final word of the packet
  output logic        tx_done,    // pulse: burst finished, trio back to idle

  // ---- trio TX pads ----
  output logic [1:0]  t_a,
  output logic [1:0]  t_b,
  output logic [1:0]  t_c,

  // ---- same-trio RX inputs (loopback in TB) ----
  input  logic [1:0]  r_a,
  input  logic [1:0]  r_b,
  input  logic [1:0]  r_c,

  // ---- RX decode outputs ----
  output logic        rx_active,  // burst decode in progress
  output logic [15:0] rx_data,
  output logic        rx_valid,
  output logic        rx_done     // pulse: post-amble and clean stop seen
);

  // ------------------------------------------------------------------
  // wire states: index {pair[1:0], polarity}; pair 0 = x, 1 = y, 2 = z
  // ------------------------------------------------------------------
  localparam logic [1:0] L = 2'b00, M = 2'b01, H = 2'b10;
  localparam logic [2:0] S_PX = 3'd0, S_MID = 3'd6, S_BAD = 3'd7;

  function automatic logic [5:0] wires(input logic [2:0] s);
    case (s)
      3'd0: wires = {H, L, M};   // +x
      3'd1: wires = {L, H, M};   // -x
      3'd2: wires = {M, H, L};   // +y
      3'd3: wires = {M, L, H};   // -y
      3'd4: wires = {L, M, H};   // +z
      3'd5: wires = {H, M, L};   // -z
      default: wires = {M, M, M};
    endcase
  endfunction

  function automatic logic [2:0] state_of(input logic [5:0] w);
    case (w)
      {H, L, M}: state_of = 3'd0;
      {L, H, M}: state_of = 3'd1;
      {M, H, L}: state_of = 3'd2;
      {M, L, H}: state_of = 3'd3;
      {L, M, H}: state_of = 3'd4;
      {H, M, L}: state_of = 3'd5;
      {M, M, M}: state_of = S_MID;
      default:   state_of = S_BAD;
    endcase
  endfunction

  function automatic logic [1:0] pair_cw(input logic [1:0] p);
    pair_cw = (p == 2'd2) ? 2'd0 : p + 2'd1;
  endfunction

  // next wire state for symbol s (0..4)
  function automatic logic [2:0] next_state(input logic [2:0] st, input logic [2:0] s);
    if (s[2]) next_state = {st[2:1], ~st[0]};
    else      next_state = {s[1] ? pair_cw(st[2:1]) : pair_cw(pair_cw(st[2:1])), st[0] ^ s[0]};
  endfunction

  // symbol carried by the transition prev -> cur (cur != prev, both valid)
  function automatic logic [2:0] symbol_of(input logic [2:0] prev, input logic [2:0] cur);
    if (cur[2:1] == prev[2:1]) symbol_of = 3'd4;
    else symbol_of = {1'b0, cur[2:1] == pair_cw(prev[2:1]), cur[0] ^ prev[0]};
  endfunction

  // sync word 3444443
  function automatic logic [2:0] sync_sym(input logic [2:0] i);
    sync_sym = (i == 3'd0 || i == 3'd6) ? 3'd3 : 3'd4;
  endfunction

  // 5**i for i = 0..6
  function automatic logic [16:0] pow5(input logic [2:0] i);
    case (i)
      3'd0: pow5 = 17'd1;
      3'd1: pow5 = 17'd5;
      3'd2: pow5 = 17'd25;
      3'd3: pow5 = 17'd125;
      3'd4: pow5 = 17'd625;
      3'd5: pow5 = 17'd3125;
      default: pow5 = 17'd15625;
    endcase
  endfunction

  localparam logic [16:0] POST_VAL = 17'd78124;   // 4444444

  // ------------------------------------------------------------------
  // TX
  // ------------------------------------------------------------------
  typedef enum logic [2:0] {T_IDLE, T_SYNC, T_DATA, T_POST, T_END} tstate_t;
  tstate_t     tstate;
  logic [2:0]  tcnt;              // symbol position 0..6
  logic [15:0] r_val;             // residual value (divided by 5 per symbol)
  logic [2:0]  tx_st;             // state on the wires (S_MID = idle)
  logic        cur_last;
  logic        buf_valid;
  logic [15:0] buf_data;
  logic        buf_last;

  assign tx_ready = ~buf_valid;
  assign {t_a, t_b, t_c} = wires(tx_st);

  wire [2:0]  tx_dig = 3'(r_val % 16'd5);

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      tstate    <= T_IDLE;
      tcnt      <= 3'd0;
      r_val     <= 16'd0;
      tx_st     <= S_MID;
      cur_last  <= 1'b0;
      buf_valid <= 1'b0;
      buf_data  <= 16'd0;
      buf_last  <= 1'b0;
      tx_done   <= 1'b0;
    end else begin
      tx_done <= 1'b0;

      if (tx_valid && tx_ready) begin
        buf_valid <= 1'b1;
        buf_data  <= tx_data;
        buf_last  <= tx_last;
      end

      case (tstate)
        T_IDLE: if (buf_valid) begin          // HS entry on +x
          tstate <= T_SYNC;
          tcnt   <= 3'd0;
          tx_st  <= S_PX;
        end
        T_SYNC: begin
          tx_st <= next_state(tx_st, sync_sym(tcnt));
          tcnt  <= tcnt + 3'd1;
          if (tcnt == 3'd6) begin
            tstate    <= T_DATA;
            tcnt      <= 3'd0;
            r_val     <= buf_data;            // first word is waiting
            cur_last  <= buf_last;
            buf_valid <= 1'b0;
          end
        end
        T_DATA: begin
          tx_st <= next_state(tx_st, tx_dig);
          r_val <= r_val / 16'd5;
          tcnt  <= tcnt + 3'd1;
          if (tcnt == 3'd6) begin
            tcnt <= 3'd0;
            if (!cur_last && buf_valid) begin
              r_val     <= buf_data;          // next word, symbols continue
              cur_last  <= buf_last;
              buf_valid <= 1'b0;
            end else tstate <= T_POST;        // last word or host underrun
          end
        end
        T_POST: begin
          tx_st <= next_state(tx_st, 3'd4);
          tcnt  <= tcnt + 3'd1;
          if (tcnt == 3'd6) tstate <= T_END;
        end
        T_END: begin                          // back to idle
          tx_st   <= S_MID;
          tx_done <= 1'b1;
          tstate  <= T_IDLE;
        end
        default: tstate <= T_IDLE;
      endcase
    end
  end

  // ------------------------------------------------------------------
  // RX decoder
  // ------------------------------------------------------------------
  typedef enum logic [2:0] {R_IDLE, R_SYNC, R_DATA, R_POST, R_ERR} rstate_t;
  rstate_t     rstate;
  logic [2:0]  rcnt;
  logic [2:0]  r_prev;
  logic [16:0] r_acc;
  logic        err_sticky;

  wire  [2:0]  r_st   = state_of({r_a, r_b, r_c});
  wire         r_tran = (r_st < S_MID) && (r_st != r_prev);   // valid UI
  wire  [2:0]  r_sym  = symbol_of(r_prev, r_st);
  wire  [16:0] r_word = ((rcnt == 3'd0) ? 17'd0 : r_acc) + 17'(r_sym) * pow5(rcnt);

  assign irq       = err_sticky;
  assign rx_active = (rstate == R_SYNC) || (rstate == R_DATA) || (rstate == R_POST);

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      rstate     <= R_IDLE;
      rcnt       <= 3'd0;
      r_prev     <= S_MID;
      r_acc      <= 17'd0;
      err_sticky <= 1'b0;
      rx_data    <= 16'd0;
      rx_valid   <= 1'b0;
      rx_done    <= 1'b0;
    end else begin
      rx_valid <= 1'b0;
      rx_done  <= 1'b0;
      if (irq_clear) err_sticky <= 1'b0;
      r_prev <= r_st;

      case (rstate)
        R_IDLE: begin
          rcnt <= 3'd0;
          if (r_st != S_MID) begin
            if (r_st == S_PX) rstate <= R_SYNC;
            else begin err_sticky <= 1'b1; rstate <= R_ERR; end
          end
        end
        R_SYNC: begin
          if (!r_tran || r_sym != sync_sym(rcnt)) begin
            err_sticky <= 1'b1; rstate <= R_ERR;
          end else begin
            rcnt <= rcnt + 3'd1;
            if (rcnt == 3'd6) begin rstate <= R_DATA; rcnt <= 3'd0; end
          end
        end
        R_DATA: begin
          if (!r_tran) begin                     // stop, bad state, no change
            err_sticky <= 1'b1; rstate <= R_ERR;
          end else begin
            r_acc <= r_word;
            rcnt  <= rcnt + 3'd1;
            if (rcnt == 3'd6) begin
              rcnt <= 3'd0;
              if (r_word == POST_VAL) rstate <= R_POST;
              else if (r_word[16]) begin err_sticky <= 1'b1; rstate <= R_ERR; end
              else begin rx_data <= r_word[15:0]; rx_valid <= 1'b1; end
            end
          end
        end
        R_POST: begin                            // extra 4s, then idle
          if (r_st == S_MID) begin rx_done <= 1'b1; rstate <= R_IDLE; end
          else if (!r_tran || r_sym != 3'd4) begin err_sticky <= 1'b1; rstate <= R_ERR; end
        end
        R_ERR: if (r_st == S_MID) rstate <= R_IDLE;
        default: rstate <= R_IDLE;
      endcase
    end
  end

endmodule
