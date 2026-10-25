// SPDX-License-Identifier: Apache-2.0
// ============================================================================
// HSI_top v2.0: MIPI HSI (High-Speed Synchronous Interface) link endpoint,
// frame mode, one transmitter and one receiver
// ----------------------------------------------------------------------------
//  - Signalling: DATA / FLAG (data-strobe): every bit changes exactly one
//    of the two lines; DATA carries the bit, FLAG toggles when the bit
//    equals the previous one. A bit lasts cfg_div + 1 clocks (cfg_div >= 3
//    on both ends).
//  - Frame: start bit 1, cfg_chbits channel bits (0..4, larger values
//    count as 4), 32 data bits, each field MSB first.
//  - Flow control (synchronised data flow): the transmitter starts a frame
//    only while the peer's READY is high (sampled through two flops). The
//    receiver drives READY while it is enabled, the peer's WAKE is high and
//    its 4-frame FIFO has room for one more frame besides the one arriving.
//  - WAKE: the transmitter raises WAKE while it has a frame to send, is
//    sending, or cfg_wake forces it.
//  - Break: tx_brk sends 33 + channel bits zeros (once the transmitter is
//    idle, without waiting for READY). The receiver counts zeros between
//    frames: that many is a break (rx_break); fewer before a start bit is
//    err_stray.
//  - Receive errors: a frame that ends with the FIFO full is dropped
//    (err_overflow); both lines changing in one clock is err_ds (taken as
//    one bit); no bit for 4 bit times inside a frame drops it (err_timeout).
//  Not implemented: stream mode, pipelined data flow, more than 16
//  channels, the configuration / "receiver ready" handshake variants of
//  HSI 1.01 beyond the above.
// ============================================================================
module HSI_top (
  input  logic        clk,
  input  logic        rst_n,
  // transmit lines
  output logic        tx_data,
  output logic        tx_flag,
  input  logic        tx_ready_in,    // the peer's READY
  output logic        tx_wake,
  // receive lines
  input  logic        rx_data,
  input  logic        rx_flag,
  output logic        rx_ready_out,
  input  logic        rx_wake,
  // configuration
  input  logic [7:0]  cfg_div,
  input  logic [2:0]  cfg_chbits,
  input  logic        cfg_rx_en,
  input  logic        cfg_wake,
  // transmit host
  input  logic        txq_valid,
  output logic        txq_ready,
  input  logic [3:0]  txq_ch,
  input  logic [31:0] txq_data,
  input  logic        tx_brk,
  output logic        tx_busy,        // sending, or a break is pending
  output logic        tx_done,
  // receive host
  output logic        rxq_valid,
  input  logic        rxq_ready,
  output logic [3:0]  rxq_ch,
  output logic [31:0] rxq_data,
  // events
  output logic        rx_break,
  output logic        err_overflow,
  output logic        err_stray,
  output logic        err_ds,
  output logic        err_timeout
);
  wire [2:0] chb = cfg_chbits > 3'd4 ? 3'd4 : cfg_chbits;
  // frame length in bits, start bit included (33 + chb; written out where
  // used, a constant-bit wire of its own would never toggle)

  // ---------------- transmitter ----------------
  typedef enum logic [1:0] {T_IDLE, T_SEND, T_BRK} tst_t;
  tst_t        ts;
  logic        hold;                     // a frame is waiting in txq_*
  logic [3:0]  h_ch;
  logic [31:0] h_d;
  logic [36:0] tsh;                      // bits to send, next in [36]
  logic [5:0]  tleft;                    // bits left
  logic [7:0]  tcnt;                     // clocks left in the bit
  logic        brk_req, rdy_s1, rdy_s2;

  wire [35:0] tfr = {h_ch, h_d} << (3'd4 - chb);   // channel bits left-aligned
  assign txq_ready = !hold;
  assign tx_busy = ts != T_IDLE || brk_req;
  assign tx_wake = hold || ts != T_IDLE || cfg_wake;

  always_ff @(posedge clk or negedge rst_n)
    if (!rst_n) begin
      ts <= T_IDLE; hold <= 1'b0; h_ch <= '0; h_d <= '0; tsh <= '0; tleft <= '0; tcnt <= '0;
      brk_req <= 1'b0; rdy_s1 <= 1'b0; rdy_s2 <= 1'b0; tx_data <= 1'b0; tx_flag <= 1'b0; tx_done <= 1'b0;
    end else begin
      rdy_s1 <= tx_ready_in; rdy_s2 <= rdy_s1;
      tx_done <= 1'b0;
      if (txq_valid && txq_ready) begin hold <= 1'b1; h_ch <= txq_ch; h_d <= txq_data; end
      if (tx_brk) brk_req <= 1'b1;
      case (ts)
        T_IDLE: begin
          tcnt <= 8'd0;
          if (brk_req) begin
            ts <= T_BRK; brk_req <= 1'b0; tsh <= '0; tleft <= 6'd33 + {3'd0, chb};
          end else if (hold && rdy_s2) begin
            // start bit, channel bits MSB first right after it, then data
            ts <= T_SEND; hold <= 1'b0; tleft <= 6'd33 + {3'd0, chb};
            tsh <= {1'b1, tfr};
          end
        end
        default: begin
          if (tcnt != 8'd0) tcnt <= tcnt - 8'd1;
          else if (tleft == 6'd0) begin
            ts <= T_IDLE;
            if (ts == T_SEND) tx_done <= 1'b1;
          end else begin
            // data-strobe: change DATA to the bit, or FLAG when it is equal
            if (tsh[36] != tx_data) tx_data <= tsh[36];
            else tx_flag <= !tx_flag;
            tsh <= {tsh[35:0], 1'b0}; tleft <= tleft - 6'd1; tcnt <= cfg_div;
          end
        end
      endcase
    end

  // ---------------- receiver ----------------
  typedef enum logic {R_IDLE, R_FRAME} rst_t;
  rst_t        rs;
  logic [1:0]  d_s, f_s;                 // synchronisers
  logic        d_q, f_q;
  logic [5:0]  rcnt;                     // bits of the frame still to come
  logic [34:0] rsh;
  logic [5:0]  zeros;
  logic [9:0]  rto;                      // clocks since the last bit
  // FIFO
  logic [35:0] fq [0:3];
  logic [1:0]  wp, rp;
  logic [2:0]  fn;

  wire        d_now = d_s[1], f_now = f_s[1];
  wire        bit_ev = (d_now != d_q) || (f_now != f_q);
  wire        pop = rxq_valid && rxq_ready;
  wire        last = rs == R_FRAME && bit_ev && rcnt == 6'd1;
  wire        push = last && (fn != 3'd4 || pop);
  assign rxq_valid = fn != 3'd0;
  assign rxq_ch = fq[rp][35:32];
  assign rxq_data = fq[rp][31:0];
  assign rx_ready_out = cfg_rx_en && rx_wake && (fn + {2'd0, rs == R_FRAME}) <= 3'd3;

  always_ff @(posedge clk or negedge rst_n)
    if (!rst_n) begin
      d_s <= '0; f_s <= '0; d_q <= 1'b0; f_q <= 1'b0; rs <= R_IDLE; rcnt <= '0; rsh <= '0; zeros <= '0;
      rto <= '0; wp <= '0; rp <= '0; fn <= '0;
      for (int i = 0; i < 4; i++) fq[i] <= '0;
      rx_break <= 1'b0; err_overflow <= 1'b0; err_stray <= 1'b0; err_ds <= 1'b0; err_timeout <= 1'b0;
    end else begin
      rx_break <= 1'b0; err_overflow <= 1'b0; err_stray <= 1'b0; err_ds <= 1'b0; err_timeout <= 1'b0;
      d_s <= {d_s[0], rx_data}; f_s <= {f_s[0], rx_flag};
      d_q <= d_now; f_q <= f_now;
      if (bit_ev && d_now != d_q && f_now != f_q) err_ds <= 1'b1;
      // the channel bits sit above the data (bits above them are 0)
      if (push) begin fq[wp] <= {rsh[34:0], d_now}; wp <= wp + 2'd1; end
      if (last && !push) err_overflow <= 1'b1;
      fn <= fn + {2'd0, push} - {2'd0, pop};
      if (pop) rp <= rp + 2'd1;
      rto <= bit_ev ? 10'd0 : (rto == 10'h3FF ? rto : rto + 10'd1);
      case (rs)
        R_IDLE: if (bit_ev) begin
          if (d_now) begin
            // start bit
            if (zeros != 6'd0 && zeros < 6'd33 + {3'd0, chb}) err_stray <= 1'b1;
            zeros <= '0; rs <= R_FRAME; rcnt <= 6'd32 + {3'd0, chb}; rsh <= '0;
          end else if (zeros != 6'h3F) begin
            zeros <= zeros + 6'd1;
            if (zeros + 6'd1 == 6'd33 + {3'd0, chb}) rx_break <= 1'b1;
          end
        end
        default: begin
          if (bit_ev) begin
            rsh <= {rsh[33:0], d_now}; rcnt <= rcnt - 6'd1;
            if (rcnt == 6'd1) rs <= R_IDLE;
          end else if (rto == {cfg_div, 2'b11}) begin
            rs <= R_IDLE; err_timeout <= 1'b1;
          end
        end
      endcase
    end
endmodule
