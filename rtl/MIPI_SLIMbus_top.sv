// SPDX-License-Identifier: Apache-2.0
// ============================================================================
// MIPI_SLIMbus_top v2.0: SLIMbus-style TDM bus interface (framer or device)
// with one transmit and one receive data channel
// ----------------------------------------------------------------------------
//  - Two-wire multi-drop bus: CLK from the framer, DATA NRZI coded (a 1
//    toggles the line, a 0 keeps it). A cell (one bit) per CLK period:
//    drivers change DATA after CLK rises, everyone samples as CLK falls.
//    A driver releases DATA once a cell is sampled (its CLK falling edge);
//    a bus keeper holds the level until the next driver.
//  - Frame: 192 slots of 4 cells, MSB first. Slot 0 carries the frame sync
//    1011, slot 96 four bits of the framing information (FI). Eight frames
//    make a superframe whose 32 FI bits are {8'h96 superframe sync,
//    cfg_fi, 16-bit superframe count}; sf_set loads the count sent in the
//    next superframe.
//  - Framer (cfg_framer = 1): drives CLK (a half period is cfg_div + 1
//    clocks), the frame sync and the FI. Device: samples CLK through two
//    flops (cfg_div >= 3 on the framer), hunts for the frame sync, locks
//    after seeing it in three frames in a row and loses lock after two
//    misses in a row, or after 16 frames without finding the superframe
//    (lost_sync); finds the superframe from the FI sync (sf_locked) and
//    reports every complete FI (fi_valid, fi_info, sf_count). The data
//    channels run only while sf_locked; an underrun sends zeros.
//  - Data channels (pushed protocol, once per frame): a
//    segment of 1 + 2 * len slots from slot cfg_*_slot: a TAG slot
//    {present, 000} and len bytes (1..4, MSB first). The transmitter takes
//    tx_data (the low len bytes) at the segment start when tx_valid, else
//    sends present = 0 and pulses tx_underrun. The receiver delivers
//    rx_data (the low len bytes) after a present segment; a TAG with
//    reserved bits set is rx_err. A segment must lie inside slots 1..95 or
//    97..191; otherwise the channel is off and cfg_err is high.
//  Not implemented: the message protocol (control space, arbitration,
//  enumeration, reconfiguration), clock gears and other transport
//  protocols, more than one channel per direction.
// ============================================================================
module MIPI_SLIMbus_top (
  input  logic        clk,
  input  logic        rst_n,
  // configuration
  input  logic        cfg_framer,
  input  logic [3:0]  cfg_div,
  input  logic [7:0]  cfg_fi,
  input  logic        sf_set,           // framer: load the superframe count
  input  logic [15:0] sf_set_val,
  input  logic [7:0]  cfg_tx_slot,
  input  logic [2:0]  cfg_tx_len,       // bytes, 0 = channel off
  input  logic [7:0]  cfg_rx_slot,
  input  logic [2:0]  cfg_rx_len,
  output logic        cfg_err,
  // bus
  output logic        slim_clk_o,
  output logic        slim_clk_oe,
  input  logic        slim_clk_i,
  output logic        slim_dat_o,
  output logic        slim_dat_oe,
  input  logic        slim_dat_i,
  // transmit channel
  input  logic        tx_valid,
  output logic        tx_ready,
  input  logic [31:0] tx_data,
  output logic        tx_underrun,
  // receive channel
  output logic        rx_valid,
  output logic [31:0] rx_data,
  output logic        rx_err,
  // status
  output logic        locked,
  output logic        sf_locked,
  output logic        lost_sync,
  output logic        fi_valid,
  output logic [7:0]  fi_info,
  output logic [15:0] sf_count
);
  // ---------------- channel configuration ----------------
  function automatic logic seg_ok(input logic [7:0] st, input logic [2:0] len);
    logic [8:0] e;
    e = {1'b0, st} + 9'd1 + {5'd0, len, 1'b0};             // first slot after the segment
    seg_ok = len != 3'd0 && len <= 3'd4 && st != 8'd0 && st != 8'd96 &&
             (st < 8'd96 ? e <= 9'd96 : e <= 9'd192);
  endfunction
  wire tx_on = seg_ok(cfg_tx_slot, cfg_tx_len);
  wire rx_on = seg_ok(cfg_rx_slot, cfg_rx_len);
  assign cfg_err = (cfg_tx_len != 3'd0 && !tx_on) || (cfg_rx_len != 3'd0 && !rx_on);

  // ---------------- CLK ----------------
  logic [3:0]  dcnt;
  logic [1:0]  cs;                           // CLK synchroniser (device)
  logic        cq;
  wire         c_now = cfg_framer ? slim_clk_o : cs[1];
  logic        rise, fall;                   // CLK edges, one clock late
  assign slim_clk_oe = cfg_framer;

  // ---------------- frame position ----------------
  typedef enum logic [1:0] {L_HUNT, L_CHECK, L_LOCK} lst_t;
  lst_t        ls;
  logic [9:0]  cpos;                         // cell on the bus (0..767)
  logic [2:0]  fno;                          // frame in the superframe
  logic        miss;                         // one frame sync missed
  logic        chk;                          // frame sync seen twice
  logic [3:0]  sfw;                          // frames locked without the superframe
  logic [2:0]  sh3;                          // last three received bits
  logic        lvl;                          // last sampled DATA level
  logic [22:0] fi_sh;                        // FI bits after the sync byte
  logic [15:0] sfc;                          // framer superframe count
  logic [23:0] fi_tx;                        // FI after the sync byte

  wire [7:0]  slot = cpos[9:2];
  wire [1:0]  ccell = cpos[1:0];
  wire [9:0]  cnext = cpos == 10'd767 ? 10'd0 : cpos + 10'd1;
  wire [7:0]  nslot = cnext[9:2];
  wire [1:0]  ncell = cnext[1:0];
  // FI bit i (0 = first of the superframe): the sync byte 96, then fi_tx
  function automatic logic fi_bit(input logic [4:0] i);
    logic [7:0] sync;
    sync = 8'h96;
    fi_bit = i < 5'd8 ? sync[3'd7 - i[2:0]] : fi_tx[5'd23 - (i - 5'd8)];
  endfunction

  // ---------------- channels ----------------
  logic [34:0] tsh;                          // TAG + bytes after the cell on the bus
  logic [30:0] rsh;
  logic [3:0]  rtag;
  wire  [7:0]  tx_end = cfg_tx_slot + 8'd1 + {4'd0, cfg_tx_len, 1'b0};
  wire  [7:0]  rx_end = cfg_rx_slot + 8'd1 + {4'd0, cfg_rx_len, 1'b0};

  always_ff @(posedge clk or negedge rst_n)
    if (!rst_n) begin
      dcnt <= '0; cs <= '0; cq <= 1'b0; rise <= 1'b0; fall <= 1'b0; slim_clk_o <= 1'b0;
      ls <= L_HUNT; cpos <= 10'd767; fno <= 3'd7; miss <= 1'b0; chk <= 1'b0; sfw <= '0; sh3 <= '0; lvl <= 1'b0; fi_sh <= '0;
      sfc <= '0; fi_tx <= '0; locked <= 1'b0; sf_locked <= 1'b0; lost_sync <= 1'b0; fi_valid <= 1'b0;
      fi_info <= '0; sf_count <= '0; slim_dat_o <= 1'b0; slim_dat_oe <= 1'b0;
      tsh <= '0; rsh <= '0; rtag <= '0;
      tx_ready <= 1'b0; tx_underrun <= 1'b0; rx_valid <= 1'b0; rx_data <= '0; rx_err <= 1'b0;
    end else begin
      lost_sync <= 1'b0; fi_valid <= 1'b0; tx_ready <= 1'b0; tx_underrun <= 1'b0;
      rx_valid <= 1'b0; rx_err <= 1'b0;
      // CLK: framer divider, device synchroniser; edges as seen here
      cs <= {cs[0], slim_clk_i};
      if (cfg_framer) begin
        if (dcnt != 4'd0) dcnt <= dcnt - 4'd1;
        else begin dcnt <= cfg_div; slim_clk_o <= !slim_clk_o; end
      end else dcnt <= '0;
      cq <= c_now;
      rise <= c_now && !cq;
      fall <= !c_now && cq;
      if (cfg_framer) begin ls <= L_LOCK; locked <= 1'b1; sf_locked <= 1'b1; end

      // ---- CLK rising: next cell, drive DATA
      if (rise) begin
        cpos <= cnext;
        if (cnext == 10'd0) begin
          fno <= fno + 3'd1;
          if (fno == 3'd7) begin
            fi_tx <= {cfg_fi, sfc};
            if (cfg_framer) sfc <= sfc + 16'd1;
          end
        end
      end
      if (sf_set) sfc <= sf_set_val;
      if (rise) begin
        // NRZI: a cell's level is the previous cell's (sampled) level, toggled for a 1
        slim_dat_oe <= 1'b0;
        if (cfg_framer && nslot == 8'd0) begin
          slim_dat_oe <= 1'b1;
          slim_dat_o <= lvl ^ (ncell != 2'd1);                          // 1011
        end else if (cfg_framer && nslot == 8'd96) begin
          slim_dat_oe <= 1'b1;
          slim_dat_o <= lvl ^ fi_bit({fno, ncell});
        end else if (sf_locked && tx_on && nslot >= cfg_tx_slot && nslot < tx_end) begin : b_tx
          logic [35:0] t;
          t = {tsh, 1'b0};
          if (nslot == cfg_tx_slot && ncell == 2'd0) begin
            t = {tx_valid, 3'b000, tx_valid ? tx_data << (6'd32 - {cfg_tx_len, 3'b000}) : 32'd0};
            if (tx_valid) tx_ready <= 1'b1; else tx_underrun <= 1'b1;
          end
          slim_dat_o <= lvl ^ t[35];
          slim_dat_oe <= 1'b1;
          tsh <= t[34:0];
        end
      end

      // ---- CLK falling: sample DATA
      if (fall) begin : b_rx
        logic b;
        b = slim_dat_i ^ lvl;
        lvl <= slim_dat_i;
        slim_dat_oe <= 1'b0;                     // the bus keeper holds the cell
        sh3 <= {sh3[1:0], b};
        // frame sync
        case (ls)
          L_HUNT: if ({sh3, b} == 4'b1011) begin ls <= L_CHECK; cpos <= 10'd3; chk <= 1'b0; end
          L_CHECK: if (cpos == 10'd3) begin
            if ({sh3, b} != 4'b1011) ls <= L_HUNT;
            else if (!chk) chk <= 1'b1;
            else begin ls <= L_LOCK; locked <= 1'b1; miss <= 1'b0; sfw <= '0; end
          end
          default: if (cpos == 10'd3 && !cfg_framer) begin
            sfw <= sf_locked ? 4'd0 : sfw + 4'd1;
            if ((!sf_locked && sfw == 4'd15) || ({sh3, b} != 4'b1011 && miss)) begin
              ls <= L_HUNT; locked <= 1'b0; sf_locked <= 1'b0; lost_sync <= 1'b1; miss <= 1'b0;
            end else miss <= {sh3, b} != 4'b1011;
          end
        endcase
        // framing information
        if (ls == L_LOCK && slot == 8'd96) begin
          fi_sh <= {fi_sh[21:0], b};
          if (ccell == 2'd3) begin
            if (!sf_locked && !cfg_framer) begin
              if ({fi_sh[6:0], b} == 8'h96) begin sf_locked <= 1'b1; fno <= 3'd1; end
            end else if (fno == 3'd7) begin
              fi_valid <= 1'b1; fi_info <= fi_sh[22:15]; sf_count <= {fi_sh[14:0], b};
            end else if ((fno == 3'd0 && {fi_sh[2:0], b} != 4'h9) || (fno == 3'd1 && {fi_sh[2:0], b} != 4'h6))
              sf_locked <= 1'b0;
          end
        end
        // receive channel
        if (sf_locked && rx_on && slot >= cfg_rx_slot && slot < rx_end) begin
          if (slot == cfg_rx_slot) rtag <= {rtag[2:0], b};
          else rsh <= {rsh[29:0], b};
          if (slot == rx_end - 8'd1 && ccell == 2'd3) begin
            if (rtag[2:0] != 3'd0) rx_err <= 1'b1;
            else if (rtag[3]) begin
              rx_valid <= 1'b1;
              rx_data <= {rsh[30:0], b} & ~(32'hFFFF_FFFF << {cfg_rx_len, 3'b000});
            end
          end
        end
      end
    end
endmodule
