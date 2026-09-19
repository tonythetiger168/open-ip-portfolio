// SPDX-License-Identifier: Apache-2.0
// ============================================================================
// I2S Audio protocol Open IP -- I2S transceiver (TX + RX, master/slave)
// Three serial formats (I2S standard / left-justified / right-justified) x
// three sample depths (16/24/32 bit) inside a 32-bclk channel slot; TX and
// RX operate simultaneously (full-duplex, TB loopback).
// IP design implementation v1.0 -- Apache-2.0
// ----------------------------------------------------------------------------
// Documented simplifications:
//  - clk is the master clock (mclk). In master mode bclk = clk / MCLK_DIV
//    (default 4 -> 256x fs for 32-bit stereo) and wclk(lrck) = bclk / 64.
//  - All serial logic advances one wire bit per bclk rising tick; the bclk
//    falling edge is not used (educational single-edge model).
//  - Parallel sample interface carries both channels per frame
//    (tx_l/tx_r with valid/ready; rx_l/rx_r with rx_valid frame strobe).
//    Samples are LSB-aligned on the parallel side and left-justified into
//    the 32-bit wire slot internally.
//  - Slave mode: bclk_in/wclk_in must be synchronous to clk (TB drives them
//    from clk); the receiver re-synchronizes its frame position to every
//    wclk edge and flags a frame-sync error (irq pulse) when the bclk/wclk
//    phase is broken (e.g. a dropped bclk pulse).
//  - TX underrun (no fresh sample at frame start) transmits zeros.
//  - cfg_fmt/cfg_depth/cfg_master are configuration-register style inputs;
//    changing them re-synchronizes the frame counters.
// ============================================================================
module I2S_Audio_top #(
  parameter int DW = 32,          // sample interface width (fixed 32)
  parameter int AW = 32,          // address width (reserved, framework contract)
  parameter int MCLK_DIV = 4      // clk cycles per bclk period (even, >= 2)
)(
  input  logic        clk,        // mclk
  input  logic        rst_n,

  // configuration (register-style)
  input  logic        cfg_master, // 1: bclk/wclk generated, 0: slave
  input  logic [1:0]  cfg_fmt,    // 0: I2S, 1: left-justified, 2: right-justified
  input  logic [1:0]  cfg_depth,  // 0: 16-bit, 1: 24-bit, 2/3: 32-bit

  // serial clocks
  output logic        bclk_out,   // master mode bit clock
  output logic        wclk_out,   // master mode word clock (0 = left)
  input  logic        bclk_in,    // slave mode bit clock
  input  logic        wclk_in,    // slave mode word clock

  // parallel TX sample interface (valid/ready, both channels per frame)
  input  logic [DW-1:0] tx_l,
  input  logic [DW-1:0] tx_r,
  input  logic        tx_valid,
  output logic        tx_ready,

  // parallel RX sample interface (frame strobe)
  output logic [DW-1:0] rx_l,
  output logic [DW-1:0] rx_r,
  output logic        rx_valid,

  // serial data
  output logic        sd_out,     // TX serial data
  input  logic        sd_in,      // RX serial data

  output logic        irq         // frame-sync error (slave mode)
);

  // ------------------------- constants -------------------------
  localparam logic [1:0] FMT_I2S = 2'd0, FMT_LJ = 2'd1, FMT_RJ = 2'd2;
  localparam int HALF = MCLK_DIV / 2;
  localparam int DCW  = (MCLK_DIV <= 2) ? 1 : $clog2(MCLK_DIV);

  // depth in bits and right-shift to recover LSB-aligned sample
  wire [4:0] shv = (cfg_depth == 2'd0) ? 5'd16 :
                   (cfg_depth == 2'd1) ? 5'd8  : 5'd0;

  // ------------------------- clock / frame counters ------------
  logic [DCW-1:0] div_cnt;        // mclk divider (master)
  logic           bclk_reg;
  logic [5:0]     frame_pos;      // 0..63: bit position in the stereo frame
  logic           synced;         // slave: wclk phase established
  logic           bclk_d;         // slave bclk_in delayed 1 clk (edge detect)
  logic           wclk_d;         // slave wclk_in delayed 1 clk (phase ref)
  logic [4:0]     cfg_q;          // previous config (change detect)

  // master: bclk rising tick; slave: rising edge of bclk_in (clk-synchronous)
  wire m_tick = (div_cnt == DCW'(HALF-1));
  wire s_tick = bclk_in & ~bclk_d;
  wire tick   = cfg_master ? m_tick : s_tick;

  wire cfg_chg = ({cfg_master, cfg_fmt, cfg_depth} != cfg_q);

  // slave: wclk phase mismatch at this tick (wclk_d matches the wire bit
  // being captured: the transmitter placed it while wclk was still wclk_d)
  wire wclk_mism = !cfg_master && (frame_pos[5] != wclk_d);

  // ------------------------- TX datapath -----------------------
  logic [31:0] tx_word_l, tx_word_r;  // left-justified slot content
  logic        tx_prev_r_lsb;         // previous frame right LSB (I2S fmt)

  function automatic logic [31:0] ljust(input logic [31:0] s,
                                        input logic [1:0]  d);
    begin
      case (d)
        2'd0:    ljust = {s[15:0], 16'h0000};
        2'd1:    ljust = {s[23:0], 8'h00};
        default: ljust = s;
      endcase
    end
  endfunction

  wire        fp_c  = frame_pos[5];           // 0: left slot, 1: right slot
  wire [5:0]  fp_p  = {1'b0, frame_pos[4:0]}; // position inside the slot
  wire [31:0] cur_w = fp_c ? tx_word_r : tx_word_l;

  // serial output bit for the current frame position
  always_comb begin
    case (cfg_fmt)
      FMT_LJ:  sd_out = cur_w[6'd31 - fp_p];
      FMT_RJ:  sd_out = (fp_p >= {1'b0, shv})
                        ? cur_w[6'd31 + {1'b0, shv} - fp_p] : 1'b0;
      default: sd_out = (fp_p == 6'd0)          // I2S: MSB delayed 1 bclk
                        ? (fp_c ? tx_word_l[0] : tx_prev_r_lsb)
                        : cur_w[6'd32 - fp_p];
    endcase
  end

  // ------------------------- RX datapath -----------------------
  logic [31:0] rx_cap_l, rx_cap_r;

  // ------------------------- sequential ------------------------
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      div_cnt      <= '0;
      bclk_reg     <= 1'b0;
      frame_pos    <= 6'd0;
      synced       <= 1'b0;
      bclk_d       <= 1'b0;
      wclk_d       <= 1'b0;
      cfg_q        <= 5'h0;
      tx_word_l    <= 32'h0;
      tx_word_r    <= 32'h0;
      tx_prev_r_lsb<= 1'b0;
      rx_cap_l     <= 32'h0;
      rx_cap_r     <= 32'h0;
      rx_l         <= '0;
      rx_r         <= '0;
      rx_valid     <= 1'b0;
      irq          <= 1'b0;
    end else if (cfg_chg) begin
      // configuration changed: resynchronize everything
      cfg_q        <= {cfg_master, cfg_fmt, cfg_depth};
      div_cnt      <= '0;
      bclk_reg     <= 1'b0;
      frame_pos    <= 6'd0;
      synced       <= 1'b0;
      bclk_d       <= bclk_in;
      wclk_d       <= wclk_in;
      rx_valid     <= 1'b0;
      irq          <= 1'b0;
    end else begin
      bclk_d <= bclk_in;
      wclk_d <= wclk_in;

      // -------- master bclk generation --------
      if (cfg_master) begin
        if (div_cnt == DCW'(MCLK_DIV-1)) div_cnt <= '0;
        else                             div_cnt <= div_cnt + 1'b1;
        if (m_tick)                             bclk_reg <= 1'b1;
        else if (div_cnt == DCW'(MCLK_DIV-1))   bclk_reg <= 1'b0;
      end else
        bclk_reg  <= 1'b0;

      // -------- slave frame-sync tracking / error detect --------
      irq <= 1'b0;                              // default: pulse
      if (!cfg_master && tick && wclk_mism) begin
        if (synced) irq <= 1'b1;                // phase broken mid-operation
        synced <= 1'b1;
      end
      if (!cfg_master && tick && frame_pos == 6'd63) synced <= 1'b1;

      // -------- per-bclk-tick processing --------
      if (tick) begin
        // frame position: slave re-aligns to wclk when out of phase
        if (!cfg_master && wclk_mism)
          frame_pos <= {wclk_d, 5'd0};
        else
          frame_pos <= frame_pos + 6'd1;

        // ---- TX: load next frame's samples at end of frame ----
        if (frame_pos == 6'd63) begin
          tx_prev_r_lsb <= tx_word_r[0];
          if (tx_valid) begin
            tx_word_l <= ljust(tx_l, cfg_depth);
            tx_word_r <= ljust(tx_r, cfg_depth);
          end else begin                       // underrun: send zeros
            tx_word_l <= 32'h0;
            tx_word_r <= 32'h0;
          end
        end

        // ---- RX: capture the wire bit into the channel word ----
        case (cfg_fmt)
          FMT_LJ:
            if (fp_c) rx_cap_r[6'd31 - fp_p] <= sd_in;
            else      rx_cap_l[6'd31 - fp_p] <= sd_in;
          FMT_RJ:
            if (fp_p >= {1'b0, shv}) begin
              if (fp_c) rx_cap_r[6'd31 + {1'b0, shv} - fp_p] <= sd_in;
              else      rx_cap_l[6'd31 + {1'b0, shv} - fp_p] <= sd_in;
            end
          default:                              // I2S: 1-bclk delay
            if (fp_p == 6'd0) begin             // previous channel's LSB
              if (fp_c) rx_cap_l[0] <= sd_in;
              else      rx_cap_r[0] <= sd_in;
            end else begin
              if (fp_c) rx_cap_r[6'd32 - fp_p] <= sd_in;
              else      rx_cap_l[6'd32 - fp_p] <= sd_in;
            end
        endcase

        // ---- RX: frame complete -> parallel samples + strobe ----
        // Latch point is format dependent: for LJ/RJ the next frame's first
        // bit is captured at frame_pos==0, so the finished words are latched
        // there; for I2S the right channel's LSB arrives at frame_pos==0, so
        // the words are latched one bclk later (frame_pos==1).
        if (frame_pos == ((cfg_fmt == FMT_I2S) ? 6'd1 : 6'd0)) begin
          rx_l     <= rx_cap_l >> shv;          // back to LSB-aligned
          rx_r     <= rx_cap_r >> shv;
          rx_valid <= 1'b1;
        end else
          rx_valid <= 1'b0;
      end else
        rx_valid <= 1'b0;
    end
  end

  // ------------------------- outputs ---------------------------
  assign bclk_out  = bclk_reg;
  assign wclk_out  = cfg_master ? frame_pos[5] : 1'b0;  // 0 = left channel
  assign tx_ready  = (frame_pos == 6'd63);              // load window

endmodule
