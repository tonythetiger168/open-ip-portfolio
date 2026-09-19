// SPDX-License-Identifier: Apache-2.0
// ============================================================================
// MIPI C-PHY trio (3-wire, 3-level) symbol-transmitter with loopback decoder
// Implementation scope:
//   * Trio wires a/b/c, each carrying one of three levels {low,mid,high},
//     simplified to a 2-bit per wire encoding (00=low, 01=mid, 10=high).
//     One symbol per clk cycle (real C-PHY maps ~2.28 bits/symbol at wire
//     rate; the clocked simplification is documented).
//   * Legal wire states: the five permutations of {low,mid,high} used as
//     data states S0..S4 (every symbol has three mutually distinct wire
//     levels). The sixth physical permutation X is reserved as the
//     collision marker described below. Idle/stop = all wires mid, which
//     never collides with a data symbol.
//   * 16-bit -> 7 symbol mapping (custom table, per task allowance; the TB
//     uses the identical table):
//       digits   : d_i = (v / 5**i) mod 5, i = 0..6 (5**7 = 78125 > 65535)
//       rotation : k_i = (d_i + i) mod 5         (position-dependent)
//       symbol_i : S[k_i], except when S[k_i] would equal the previous
//                  transmitted symbol -- then the reserved marker X is sent
//                  and the receiver recovers k_i = index(previous symbol).
//     This guarantees adjacent symbols always differ on the trio (a hard
//     C-PHY requirement) while keeping the mapping bijective. Note: with
//     only 5 legal states a change-constrained 16->7 mapping is
//     information-theoretically impossible (5*4^6 < 2^16); real C-PHY
//     therefore uses 6 states. Here the 6th state appears only as the
//     collision marker, documented simplification.
//   * Packet format: idle (mid,mid,mid) -> 7-symbol sync word
//     {S1,S3,S0,S2,S4,S1,X} (simplified; real C-PHY uses the "4444443"
//     sync sequence) -> 7 symbols per 16-bit payload word -> stop.
//   * RX decodes the same trio (TB loopback): sync match, symbol-to-digit
//     de-rotation, word reassembly. Protocol violations (illegal wire
//     state, adjacent identical symbols, bad sync, mid-word stop) raise
//     sticky irq.
// IP design implementation v1.0 -- Apache-2.0
// ============================================================================
module C_PHY_top #(
  parameter int DW = 32,        // retained framework parameter (data width)
  parameter int AW = 32         // retained framework parameter (address width)
)(
  input  logic        clk,
  input  logic        rst_n,
  output logic        irq,        // sticky protocol-error flag (RX decoder)
  input  logic        irq_clear,

  // ---- host TX word stream ----
  input  logic [15:0] tx_data,    // 16-bit payload word
  input  logic        tx_valid,
  output logic        tx_ready,
  input  logic        tx_last,    // marks the final word of the packet
  output logic        tx_done,    // pulse: packet finished, trio back to idle

  // ---- trio TX pads ----
  output logic [1:0]  t_a,
  output logic [1:0]  t_b,
  output logic [1:0]  t_c,

  // ---- same-trio RX inputs (loopback in TB) ----
  input  logic [1:0]  r_a,
  input  logic [1:0]  r_b,
  input  logic [1:0]  r_c,

  // ---- RX decode outputs ----
  output logic        rx_active,  // packet decode in progress
  output logic [15:0] rx_data,
  output logic        rx_valid,
  output logic        rx_done     // pulse: clean stop observed
);

  // ------------------------------------------------------------------
  // line levels and wire states
  // ------------------------------------------------------------------
  localparam logic [1:0] LVL_L = 2'b00;
  localparam logic [1:0] LVL_M = 2'b01;
  localparam logic [1:0] LVL_H = 2'b10;

  // wire states as {a,b,c}
  localparam logic [5:0] ST_S0 = {LVL_L, LVL_M, LVL_H}; // (L,M,H)
  localparam logic [5:0] ST_S1 = {LVL_L, LVL_H, LVL_M}; // (L,H,M)
  localparam logic [5:0] ST_S2 = {LVL_M, LVL_L, LVL_H}; // (M,L,H)
  localparam logic [5:0] ST_S3 = {LVL_M, LVL_H, LVL_L}; // (M,H,L)
  localparam logic [5:0] ST_S4 = {LVL_H, LVL_L, LVL_M}; // (H,L,M)
  localparam logic [5:0] ST_X  = {LVL_H, LVL_M, LVL_L}; // (H,M,L) marker
  localparam logic [5:0] ST_MID = {LVL_M, LVL_M, LVL_M}; // idle/stop

  // sync word: S1 S3 S0 S2 S4 S1 X  (adjacent symbols all differ)
  function automatic logic [5:0] sync_sym(input int i);
    case (i)
      0: sync_sym = ST_S1;
      1: sync_sym = ST_S3;
      2: sync_sym = ST_S0;
      3: sync_sym = ST_S2;
      4: sync_sym = ST_S4;
      5: sync_sym = ST_S1;
      default: sync_sym = ST_X;
    endcase
  endfunction

  // data state table S0..S4
  function automatic logic [5:0] state_abc(input logic [2:0] k);
    case (k)
      3'd0: state_abc = ST_S0;
      3'd1: state_abc = ST_S1;
      3'd2: state_abc = ST_S2;
      3'd3: state_abc = ST_S3;
      default: state_abc = ST_S4;
    endcase
  endfunction

  // inverse table: wire state -> index 0..4, 5 = X marker, 6 = illegal,
  // 7 = all-mid (idle/stop, not a data symbol)
  function automatic logic [2:0] idx_of(input logic [5:0] s);
    case (s)
      ST_S0:  idx_of = 3'd0;
      ST_S1:  idx_of = 3'd1;
      ST_S2:  idx_of = 3'd2;
      ST_S3:  idx_of = 3'd3;
      ST_S4:  idx_of = 3'd4;
      ST_X:   idx_of = 3'd5;
      ST_MID: idx_of = 3'd7;
      default: idx_of = 3'd6;
    endcase
  endfunction

  // 5**i for i = 0..6
  function automatic logic [15:0] pow5(input logic [2:0] i);
    case (i)
      3'd0: pow5 = 16'd1;
      3'd1: pow5 = 16'd5;
      3'd2: pow5 = 16'd25;
      3'd3: pow5 = 16'd125;
      3'd4: pow5 = 16'd625;
      3'd5: pow5 = 16'd3125;
      default: pow5 = 16'd15625;
    endcase
  endfunction

  // ------------------------------------------------------------------
  // TX FSM
  // ------------------------------------------------------------------
  typedef enum logic [1:0] {T_IDLE, T_SYNC, T_DATA, T_STOP} tstate_t;
  tstate_t    tstate;
  logic [2:0] spos;               // sync position 0..6
  logic [2:0] sym_cnt;            // symbol position inside word 0..6
  logic [15:0] r_val;             // residual value (divided by 5 per symbol)
  logic [5:0] prev_sym;           // previously transmitted wire state
  logic       cur_last;
  logic       buf_valid;
  logic [15:0] buf_data;
  logic       buf_last;

  assign tx_ready = ~buf_valid;

  // current data symbol (combinational): digit, rotation, collision rule
  wire [15:0] tx_d16  = r_val % 16'd5;
  wire [2:0]  tx_d    = tx_d16[2:0];
  wire [3:0]  tx_sum  = {1'b0, tx_d} + {1'b0, sym_cnt};
  wire [2:0]  tx_k    = (tx_sum >= 4'd10) ? tx_sum[2:0] - 3'd2  // -10 mod 8 ok
                      : (tx_sum >= 4'd5)  ? tx_sum[2:0] - 3'd5
                                          : tx_sum[2:0];
  wire [5:0]  tx_cand = state_abc(tx_k);
  wire [5:0]  tx_sym  = (tx_cand == prev_sym) ? ST_X : tx_cand;

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      tstate    <= T_IDLE;
      spos      <= 3'd0;
      sym_cnt   <= 3'd0;
      r_val     <= 16'd0;
      prev_sym  <= ST_MID;
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
        T_IDLE: begin
          if (buf_valid) begin
            tstate <= T_SYNC;
            spos   <= 3'd0;
          end
        end
        T_SYNC: begin
          prev_sym <= sync_sym(spos);
          if (spos == 3'd6) begin
            tstate  <= T_DATA;
            sym_cnt <= 3'd0;
            // first payload word was waiting in the buffer
            r_val     <= buf_data;
            cur_last  <= buf_last;
            buf_valid <= 1'b0;
          end else begin
            spos <= spos + 3'd1;
          end
        end
        T_DATA: begin
          prev_sym <= tx_sym;
          r_val    <= r_val / 16'd5;
          if (sym_cnt == 3'd6) begin
            sym_cnt <= 3'd0;
            if (cur_last) begin
              tstate  <= T_STOP;      // final word done -> stop
              tx_done <= 1'b1;
            end else if (buf_valid) begin
              r_val     <= buf_data;  // next word, symbols continue
              cur_last  <= buf_last;
              buf_valid <= 1'b0;
            end else begin
              tstate  <= T_STOP;      // host underrun -> clean stop
              tx_done <= 1'b1;
            end
          end else begin
            sym_cnt <= sym_cnt + 3'd1;
          end
        end
        T_STOP: begin
          tstate   <= T_IDLE;
          prev_sym <= ST_MID;
        end
        default: tstate <= T_IDLE;
      endcase
    end
  end

  // TX trio drivers
  always_comb begin
    {t_a, t_b, t_c} = ST_MID;
    case (tstate)
      T_SYNC: {t_a, t_b, t_c} = sync_sym(spos);
      T_DATA: {t_a, t_b, t_c} = tx_sym;
      default: ;
    endcase
  end

  // ------------------------------------------------------------------
  // RX decoder (same-trio loopback)
  // ------------------------------------------------------------------
  typedef enum logic [1:0] {R_IDLE, R_SYNC, R_DATA, R_ERR} rstate_t;
  rstate_t    rstate;
  logic [2:0] r_spos;
  logic [2:0] r_sym_cnt;
  logic [5:0] r_prev;
  logic [31:0] r_acc;
  logic       err_sticky;

  wire [5:0] rw     = {r_a, r_b, r_c};
  wire [2:0] r_idx  = idx_of(rw);
  wire [2:0] pidx   = idx_of(r_prev);

  // recovered rotation index: X means "candidate equaled previous symbol"
  wire [2:0] r_k    = (r_idx == 3'd5) ? pidx : r_idx;
  // de-rotation: d = (k - sym_cnt) mod 5
  wire [2:0] r_m    = (r_sym_cnt >= 3'd5) ? r_sym_cnt - 3'd5 : r_sym_cnt;
  wire [3:0] r_dtmp = {1'b0, r_k} + 4'd5 - {1'b0, r_m};
  wire [2:0] r_dig  = (r_dtmp >= 4'd5) ? r_dtmp[2:0] - 3'd5 : r_dtmp[2:0];
  wire [31:0] r_word = (r_sym_cnt == 3'd0) ? ({16'd0, r_dig} * pow5(3'd0))
                                           : (r_acc + {29'd0, r_dig} * pow5(r_sym_cnt));

  assign irq       = err_sticky;
  assign rx_active = (rstate == R_SYNC) | (rstate == R_DATA);

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      rstate     <= R_IDLE;
      r_spos     <= 3'd0;
      r_sym_cnt  <= 3'd0;
      r_prev     <= ST_MID;
      r_acc      <= 32'd0;
      err_sticky <= 1'b0;
      rx_data    <= 16'd0;
      rx_valid   <= 1'b0;
      rx_done    <= 1'b0;
    end else begin
      rx_valid <= 1'b0;
      rx_done  <= 1'b0;
      if (irq_clear) err_sticky <= 1'b0;

      case (rstate)
        R_IDLE: begin
          if (rw != ST_MID) begin
            if (rw == sync_sym(0)) begin
              rstate <= R_SYNC;
              r_spos <= 3'd1;
              r_prev <= rw;
            end else begin
              err_sticky <= 1'b1;      // packet not starting with sync
              rstate     <= R_ERR;
            end
          end
        end
        R_SYNC: begin
          if (rw == sync_sym(r_spos)) begin
            r_prev <= rw;
            if (r_spos == 3'd6) begin
              rstate    <= R_DATA;
              r_sym_cnt <= 3'd0;
            end else begin
              r_spos <= r_spos + 3'd1;
            end
          end else begin
            err_sticky <= 1'b1;        // sync word mismatch
            rstate     <= R_ERR;
          end
        end
        R_DATA: begin
          if (r_idx == 3'd7) begin     // all-mid: stop
            if (r_sym_cnt == 3'd0) begin
              rstate  <= R_IDLE;       // clean word-boundary stop
              rx_done <= 1'b1;
            end else begin
              err_sticky <= 1'b1;      // mid-word stop
              rstate     <= R_ERR;
            end
          end else if (r_idx == 3'd6) begin
            err_sticky <= 1'b1;        // illegal wire state (wires not distinct)
            rstate     <= R_ERR;
          end else if (rw == r_prev) begin
            err_sticky <= 1'b1;        // adjacent identical symbols
            rstate     <= R_ERR;
          end else begin
            r_acc  <= r_word;
            r_prev <= rw;
            if (r_sym_cnt == 3'd6) begin
              r_sym_cnt <= 3'd0;
              rx_data   <= r_word[15:0];
              rx_valid  <= 1'b1;
            end else begin
              r_sym_cnt <= r_sym_cnt + 3'd1;
            end
          end
        end
        R_ERR: if (r_idx == 3'd7) rstate <= R_IDLE;  // resync on idle
        default: rstate <= R_IDLE;
      endcase
    end
  end

endmodule
