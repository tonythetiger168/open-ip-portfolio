// SPDX-License-Identifier: Apache-2.0
// ============================================================================
// UART 8N1 transceiver with 16x oversampled RX
// IP design implementation v2.0 -- Apache-2.0
// ----------------------------------------------------------------------------
//  - Baud tick: tick16 every CLK_FREQ/BAUD/16 clocks (free-running).
//  - TX: tx_valid/tx_ready handshake; start bit, 8 data bits LSB first,
//    one stop bit, 16 ticks per bit. tx_ready is high only while idle.
//  - RX: 2-flop synchroniser, falling-edge start detection, start bit
//    re-checked at its middle (a shorter low pulse is a glitch and is
//    ignored), data and stop bits sampled at their middles. A frame whose
//    stop bit samples 0 is a framing error: it is dropped and pulses irq.
//    Hunting for the next start bit begins at the middle of the stop bit.
//  - irq: one-clock pulse per received byte (with rx_valid) or framing error.
// ============================================================================
module UART_top #(
  parameter int CLK_FREQ = 50_000_000,
  parameter int BAUD     = 115_200
)(
  input  logic       clk,
  input  logic       rst_n,
  input  logic       rxd,
  output logic       txd,
  input  logic [7:0] tx_data,
  input  logic       tx_valid,
  output logic       tx_ready,
  output logic [7:0] rx_data,
  output logic       rx_valid,
  output logic       irq
);
  localparam int DIV16 = (CLK_FREQ / BAUD) / 16;
  localparam int DW    = $clog2(DIV16 > 1 ? DIV16 : 2);

  // ---------------- 16x baud tick ----------------
  logic [DW-1:0] div_cnt;
  logic          tick16;
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      div_cnt <= '0;
      tick16  <= 1'b0;
    end else if (div_cnt == DW'(DIV16 - 1)) begin
      div_cnt <= '0;
      tick16  <= 1'b1;
    end else begin
      div_cnt <= div_cnt + 1'b1;
      tick16  <= 1'b0;
    end
  end

  // ---------------- TX: 8N1 ----------------
  typedef enum logic [1:0] {TX_IDLE, TX_START, TX_DATA, TX_STOP} tx_t;
  tx_t        tstate;
  logic [3:0] tsub;
  logic [2:0] tbit;
  logic [7:0] tshift;

  assign tx_ready = (tstate == TX_IDLE);

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      tstate <= TX_IDLE; txd <= 1'b1;
      tsub <= '0; tbit <= '0; tshift <= '0;
    end else case (tstate)
      TX_IDLE: if (tx_valid) begin
        tshift <= tx_data; tstate <= TX_START;
        txd <= 1'b0; tsub <= '0;
      end
      TX_START: if (tick16) begin
        tsub <= tsub + 1'b1;
        if (tsub == 4'd15) begin
          tbit   <= '0;
          txd    <= tshift[0];
          tshift <= {1'b0, tshift[7:1]};
          tstate <= TX_DATA;
        end
      end
      TX_DATA: if (tick16) begin
        tsub <= tsub + 1'b1;
        if (tsub == 4'd15) begin
          tbit   <= tbit + 1'b1;
          txd    <= tbit == 3'd7 ? 1'b1 : tshift[0];
          tshift <= {1'b0, tshift[7:1]};
          if (tbit == 3'd7) tstate <= TX_STOP;
        end
      end
      default: if (tick16) begin       // TX_STOP
        tsub <= tsub + 1'b1;
        if (tsub == 4'd15) tstate <= TX_IDLE;
      end
    endcase
  end

  // ---------------- RX: 8N1, 16x oversample ----------------
  logic rxd_s, rxd_d;
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin rxd_s <= 1'b1; rxd_d <= 1'b1; end
    else begin rxd_s <= rxd; rxd_d <= rxd_s; end
  end
  wire start_det = rxd_d & ~rxd_s;

  typedef enum logic [1:0] {RX_IDLE, RX_START, RX_DATA, RX_STOP} rx_t;
  rx_t        rstate;
  logic [3:0] rsub;
  logic [2:0] rbit;
  logic [7:0] rshift;
  logic       frame_err;

  assign irq = rx_valid | frame_err;

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      rstate <= RX_IDLE; rsub <= '0; rbit <= '0;
      rshift <= '0; rx_data <= '0; rx_valid <= 1'b0; frame_err <= 1'b0;
    end else begin
      rx_valid  <= 1'b0;
      frame_err <= 1'b0;
      case (rstate)
        RX_IDLE: if (start_det) begin
          rstate <= RX_START; rsub <= '0;
        end
        RX_START: if (tick16) begin       // middle of the start bit
          rsub <= rsub + 1'b1;
          if (rsub == 4'd7) begin
            rsub   <= '0;
            rbit   <= '0;
            rstate <= rxd_s ? RX_IDLE : RX_DATA;
          end
        end
        RX_DATA: if (tick16) begin
          rsub <= rsub + 1'b1;
          if (rsub == 4'd15) begin
            rshift <= {rxd_s, rshift[7:1]};
            rbit   <= rbit + 1'b1;
            if (rbit == 3'd7) rstate <= RX_STOP;
          end
        end
        default: if (tick16) begin        // RX_STOP: sample the stop bit middle
          rsub <= rsub + 1'b1;
          if (rsub == 4'd15) begin
            rstate <= RX_IDLE;
            if (rxd_s) begin
              rx_data  <= rshift;
              rx_valid <= 1'b1;
            end else frame_err <= 1'b1;
          end
        end
      endcase
    end
  end

endmodule
