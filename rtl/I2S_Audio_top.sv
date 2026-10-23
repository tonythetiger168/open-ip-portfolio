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
//  - Standard edge use in both modes: the frame position (and with it
//    sd_out and wclk) advances on the bclk falling edge, sd_in is sampled
//    on the bclk rising edge. In master mode bclk_out is low for the first
//    half of each bit, so sd_out/wclk_out are stable around every rise.
//  - Parallel sample interface carries both channels per frame
//    (tx_l/tx_r with valid/ready; rx_l/rx_r with rx_valid frame strobe).
//    Samples are LSB-aligned on the parallel side and left-justified into
//    the 32-bit wire slot internally.
//  - Slave mode: bclk_in/wclk_in must be synchronous to clk (TB drives them
//    from clk), wclk_in changing on bclk_in falling edges; the frame
//    position re-synchronizes to every wclk edge and a frame-sync error
//    (irq pulse) is flagged when the bclk/wclk phase is broken (e.g. a
//    dropped bclk pulse).
//  - tx_valid/tx_ready: tx_ready is a one-cycle pulse on the cycle that
//    loads the next frame; a sample pair transfers when both are high.
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

  // unused (padding) MSBs in the 32-bit slot, in bytes: 16-bit -> 2, 24 -> 1
  wire [1:0] shb = (cfg_depth == 2'd0) ? 2'd2 :
                   (cfg_depth == 2'd1) ? 2'd1 : 2'd0;

  // ------------------------- clock / frame counters ------------
  logic [DCW-1:0] div_cnt;        // mclk divider (master)
  logic           bclk_reg;
  logic [5:0]     frame_pos;      // 0..63: bit position in the stereo frame
  logic           synced;         // slave: wclk phase established
  logic           bclk_d;         // slave bclk_in delayed 1 clk (edge detect)
  logic [4:0]     cfg_q;          // previous config (change detect)

  // rise: sample sd_in; fall: advance the frame position (launch sd_out)
  wire m_rise = (div_cnt == DCW'(HALF-1));
  wire m_fall = (div_cnt == DCW'(MCLK_DIV-1));
  wire s_rise =  bclk_in & ~bclk_d;
  wire s_fall = ~bclk_in &  bclk_d;
  wire rise   = cfg_master ? m_rise : s_rise;
  wire fall   = cfg_master ? m_fall : s_fall;

  wire cfg_chg = ({cfg_master, cfg_fmt, cfg_depth} != cfg_q);

  // slave: after this fall the frame position must agree with wclk_in
  wire [5:0] fp_inc    = frame_pos + 6'd1;
  wire       wclk_mism = !cfg_master && (fp_inc[5] != wclk_in);

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
  wire [4:0]  fp_p  = frame_pos[4:0];         // position inside the slot
  wire [31:0] cur_w = fp_c ? tx_word_r : tx_word_l;
  wire        rj_on = (fp_p >= {shb, 3'b000});          // RJ: data part of the slot
  wire [4:0]  rj_ix = 5'd31 + {shb, 3'b000} - fp_p;     // RJ: word bit at this position
  wire [4:0]  i2_ix = 5'd0 - fp_p;            // I2S: 32 - fp_p (fp_p >= 1)

  // serial output bit for the current frame position
  always_comb begin
    case (cfg_fmt)
      FMT_LJ:  sd_out = cur_w[5'd31 - fp_p];
      FMT_RJ:  sd_out = rj_on ? cur_w[rj_ix] : 1'b0;
      default: sd_out = (fp_p == 5'd0)          // I2S: MSB delayed 1 bclk
                        ? (fp_c ? tx_word_l[0] : tx_prev_r_lsb)
                        : cur_w[i2_ix];
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
      rx_valid     <= 1'b0;
      irq          <= 1'b0;
    end else begin
      bclk_d <= bclk_in;

      // -------- master bclk generation: low, then high, per bit --------
      if (cfg_master) begin
        if (m_fall) div_cnt <= '0;
        else        div_cnt <= div_cnt + 1'b1;
        if (m_rise)      bclk_reg <= 1'b1;
        else if (m_fall) bclk_reg <= 1'b0;
      end else
        bclk_reg  <= 1'b0;

      // -------- slave frame-sync tracking / error detect --------
      irq <= 1'b0;                              // default: pulse
      if (!cfg_master && fall && wclk_mism) begin
        if (synced) irq <= 1'b1;                // phase broken mid-operation
        synced <= 1'b1;
      end
      if (!cfg_master && fall && frame_pos == 6'd63) synced <= 1'b1;

      // -------- RX: capture the wire bit on the rising edge --------
      if (rise) begin
        case (cfg_fmt)
          FMT_LJ:
            if (fp_c) rx_cap_r[5'd31 - fp_p] <= sd_in;
            else      rx_cap_l[5'd31 - fp_p] <= sd_in;
          FMT_RJ:
            if (rj_on) begin
              if (fp_c) rx_cap_r[rj_ix] <= sd_in;
              else      rx_cap_l[rj_ix] <= sd_in;
            end
          default:                              // I2S: 1-bclk delay
            if (fp_p == 5'd0) begin             // previous channel's LSB
              if (fp_c) rx_cap_l[0] <= sd_in;
              else      rx_cap_r[0] <= sd_in;
            end else begin
              if (fp_c) rx_cap_r[i2_ix] <= sd_in;
              else      rx_cap_l[i2_ix] <= sd_in;
            end
        endcase
      end

      // -------- per-bit advance on the falling edge --------
      rx_valid <= 1'b0;
      if (fall) begin
        // frame position: slave re-aligns to wclk when out of phase
        if (wclk_mism)
          frame_pos <= {wclk_in, 5'd0};
        else
          frame_pos <= fp_inc;

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

        // ---- RX: frame complete -> parallel samples + strobe ----
        // The last bit of a frame is sampled during position 63 (LJ/RJ) or,
        // for I2S, during position 0 of the next frame (right LSB); the
        // words are latched on the falling edge that ends that position.
        if (frame_pos == ((cfg_fmt == FMT_I2S) ? 6'd0 : 6'd63)) begin
          rx_l     <= rx_cap_l >> {shb, 3'b000};          // back to LSB-aligned
          rx_r     <= rx_cap_r >> {shb, 3'b000};
          rx_valid <= 1'b1;
        end
      end
    end
  end

  // ------------------------- outputs ---------------------------
  assign bclk_out  = bclk_reg;
  assign wclk_out  = cfg_master ? frame_pos[5] : 1'b0;  // 0 = left channel
  assign tx_ready  = fall && (frame_pos == 6'd63) && !cfg_chg;  // load cycle

endmodule
