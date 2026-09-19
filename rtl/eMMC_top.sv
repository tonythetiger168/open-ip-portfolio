// SPDX-License-Identifier: Apache-2.0
// ============================================================================
// eMMC protocol Open IP -- eMMC host: CMD0/CMD1/CMD2/CMD3 init sequence,
// CMD24/CMD17 single-block read/write in 1-bit DAT mode, CRC7/CRC16 checking
// -- Apache-2.0
// Open IP design implementation v2.4
// ----------------------------------------------------------------------------
// Documented simplifications (SPEC section 2.5):
//  - Block length is 32 bytes (256 bits) instead of the eMMC-native 512 bytes.
//  - 1-bit bus mode only: host drives/samples dat[0]; dat[7:1] stay high-Z.
//  - All host logic runs in the emmc_clk (bus clock) domain; clk is the
//    system clock and is reserved/unused internally (single-clock design).
//  - rst_n and emmc_rst_n are combined into one asynchronous reset (srst_n).
//  - Response wait timeout is 64 emmc_clk cycles (SPEC: N <= 64).
//  - The host autonomously repeats demo rounds: CMD24 write of an internal
//    pattern block, then CMD17 read of the same block with read-back compare.
//    Round n uses block address n[1:0]. Status is observable via internal
//    state (TB hierarchical reference) and irq pulses.
// ============================================================================
module eMMC_top #(
  parameter int DW = 32,       // data width (reserved, fixed internal 32-byte blocks)
  parameter int AW = 32,       // address width (reserved, block address in cmd arg)
  parameter int BIT_CLKS = 1   // emmc_clk cycles per serial bit (bit-rate divider)
)(
  input  logic       clk,
  input  logic       rst_n,
  input  logic       emmc_clk,
  inout  logic       cmd,
  inout  logic [7:0] dat,
  input  logic       emmc_rst_n,
  output logic       irq
);

  // ------------------------- constants -------------------------
  localparam int BLK_BITS   = 256;             // 32-byte simplified block
  localparam logic [8:0] BLK_CNT = 9'd256;     // block bit count, sized
  localparam logic [6:0] TO_MAX  = 7'd63;      // timeout limit (64 emmc_clk)
  localparam logic [31:0] OCR_ARG = 32'h40FF_8080; // CMD1 OCR (3.3V range)
  localparam logic [31:0] RCA_ARG = 32'h0001_0000; // CMD3: RCA = 1

  // ------------------------- CRC helpers -------------------------
  // CRC7: poly x^7 + x^3 + 1 (7'h09), MSB-first, init 0 -- over 40 bits
  function automatic logic [6:0] crc7_40(input logic [39:0] d);
    logic [6:0] c;
    logic       fb;
    c = 7'h00;
    for (int i = 39; i >= 0; i--) begin        // constant bounds
      fb = d[i] ^ c[6];
      c  = {c[5:0], 1'b0};
      if (fb) c = c ^ 7'h09;
    end
    crc7_40 = c;               // yosys-compatible (no return statement)
  endfunction

  // CRC16: poly 16'h1021 (CCITT), MSB-first, init 0 -- one serial step
  function automatic logic [15:0] crc16_step(input logic [15:0] c_in,
                                             input logic        b);
    logic fb;
    fb = b ^ c_in[15];
    crc16_step = {c_in[14:0], 1'b0} ^ (fb ? 16'h1021 : 16'h0000);
  endfunction

  // 48-bit command frame: start(0) tx(1) cmdidx[6] arg[32] crc7[7] end(1)
  function automatic logic [47:0] cmd_frame(input logic [5:0]  idx,
                                            input logic [31:0] arg);
    logic [39:0] body;
    body = {1'b1, idx, arg};
    cmd_frame = {1'b0, body, crc7_40(body), 1'b1};
  endfunction

  // Demo payload pattern: word i of round r (MSB of block shifted out first)
  function automatic logic [31:0] pat_word(input logic [7:0] r,
                                           input logic [7:0] i);
    pat_word = 32'hA500_3C00 ^ {24'h0, r} ^ ({24'h0, i} * 32'h0001_0101);
  endfunction

  // ------------------------- state types -------------------------
  typedef enum logic [3:0] {
    H_CMD0 = 4'd0,   // GO_IDLE (no response)
    H_CMD1 = 4'd1,   // SEND_OP_COND, poll OCR busy bit (R3)
    H_CMD2 = 4'd2,   // ALL_SEND_CID (R2, 136-bit)
    H_CMD3 = 4'd3,   // SET_RCA (R1)
    H_IDLE = 4'd4,   // between demo rounds
    H_WCMD = 4'd5,   // CMD24 single-block write (R1)
    H_WDAT = 4'd6,   // write data block on dat[0]
    H_RCMD = 4'd7,   // CMD17 single-block read (R1)
    H_RDAT = 4'd8    // read data block on dat[0]
  } hstate_t;

  localparam logic [1:0] PH_TX  = 2'd0,
                         PH_GAP = 2'd1,
                         PH_RSP = 2'd2;

  localparam logic [2:0] DP_START  = 3'd0,   // write: start bit / read: wait start
                         DP_DATA   = 3'd1,   // 256 data bits
                         DP_CRC    = 3'd2,   // 16 CRC bits
                         DP_END    = 3'd3,   // end bit
                         DP_BUSY   = 3'd4;   // write: wait busy release

  // ------------------------- registers -------------------------
  hstate_t      state;
  logic [1:0]   phase;          // command engine sub-phase
  logic [2:0]   dphase;         // data sub-phase
  logic [8:0]   bit_cnt;
  logic [6:0]   wait_cnt;
  logic [47:0]  cmd_sh;
  logic [135:0] rsp_sh;
  logic [7:0]   rsp_len;        // 0 (CMD0) / 48 / 136
  logic [5:0]   cur_cmd;
  logic         cmd_oe_r, cmd_out_r;
  logic         dat0_oe_r, dat0_out_r;
  logic [255:0] dat_sh;         // TX shift / RX assemble buffer
  logic [15:0]  crc16, crc_rx;
  logic         busy_rel;       // write busy release observed
  logic [7:0]   round;
  logic [7:0]   match_cnt;      // successful read-back compares
  logic [127:0] cid;
  logic         init_done;
  logic         err_crc7, err_crc16, err_timeout, err_cmp;

  // ------------------------- bus drivers -------------------------
  assign cmd     = cmd_oe_r  ? cmd_out_r  : 1'bz;
  assign dat[0]  = dat0_oe_r ? dat0_out_r : 1'bz;
  assign dat[7:1] = 7'bzzzzzzz;           // 1-bit mode: upper lines high-Z

  // expected payload for the current round (write source / read reference)
  logic [255:0] exp_blk;
  always_comb begin
    for (int i = 0; i < 8; i++)          // constant bound
      exp_blk[255 - i*32 -: 32] = pat_word(round, i[7:0]);
  end

  // next response-shift value and R1 field checks (combinational)
  logic [135:0] rsp_nxt;
  always_comb rsp_nxt = {rsp_sh[134:0], cmd};
  logic r1_ok;
  always_comb r1_ok = (rsp_nxt[0] == 1'b1) &&
                      (crc7_40(rsp_nxt[46:8]) == rsp_nxt[7:1]);

  // ------------------------- macros (kept local) -------------------------
  // issue a 48-bit command frame and arm the response engine
  `define EMMC_ISSUE(ST, IDX, ARG, RLEN) \
    begin \
      state    <= ST; \
      phase    <= PH_TX; \
      cmd_sh   <= cmd_frame(IDX, ARG); \
      bit_cnt  <= 9'd48; \
      cmd_oe_r <= 1'b1; \
      cur_cmd  <= IDX; \
      rsp_len  <= RLEN; \
      wait_cnt <= 7'd0; \
    end

  // raise error: sticky flag + 1-cycle irq pulse; init errors restart init,
  // data-phase errors return to H_IDLE which restarts the current round
  `define EMMC_RAISE(ERRF) \
    begin \
      ERRF <= 1'b1; \
      irq  <= 1'b1; \
      if (init_done) begin \
        state    <= H_IDLE; \
        wait_cnt <= 7'd0; \
      end else begin \
        `EMMC_ISSUE(H_CMD0, 6'd0, 32'h0000_0000, 8'd0) \
      end \
    end

  // ------------------------- main FSM -------------------------
  wire srst_n = rst_n & emmc_rst_n;

  // Bit-rate divider: the bit-paced FSM advances only on bit_tick.
  // BIT_CLKS=1 keeps the legacy 1-bit-per-emmc_clk behavior (bit_tick constant 1).
  localparam int BCW = (BIT_CLKS <= 1) ? 1 : $clog2(BIT_CLKS);
  logic [BCW-1:0] bd_cnt;
  wire bit_tick = (BIT_CLKS <= 1) || (bd_cnt == BIT_CLKS-1);
  always_ff @(posedge emmc_clk or negedge srst_n) begin
    if (!srst_n)         bd_cnt <= '0;
    else if (bit_tick)   bd_cnt <= '0;
    else                 bd_cnt <= bd_cnt + 1'b1;
  end

  always_ff @(posedge emmc_clk or negedge srst_n) begin
    if (!srst_n) begin
      state      <= H_CMD0;
      phase      <= PH_TX;
      dphase     <= DP_START;
      bit_cnt    <= 9'd48;
      wait_cnt   <= 7'd0;
      cmd_sh     <= cmd_frame(6'd0, 32'h0000_0000);
      rsp_sh     <= '0;
      rsp_len    <= 8'd0;
      cur_cmd    <= 6'd0;
      cmd_oe_r   <= 1'b1;          // first act after reset: send CMD0
      cmd_out_r  <= 1'b1;
      dat0_oe_r  <= 1'b0;
      dat0_out_r <= 1'b1;
      dat_sh     <= '0;
      busy_rel   <= 1'b0;
      crc16      <= 16'h0000;
      crc_rx     <= 16'h0000;
      round      <= 8'd0;
      match_cnt  <= 8'd0;
      cid        <= 128'h0;
      init_done  <= 1'b0;
      err_crc7   <= 1'b0;
      err_crc16  <= 1'b0;
      err_timeout<= 1'b0;
      err_cmp    <= 1'b0;
      irq        <= 1'b0;
    end else begin
      if (bit_tick) begin
      irq <= 1'b0;                 // default: single-cycle pulse

      case (state)
        // ------------------------------------------------------------------
        // command states: shared TX/GAP/RSP engine, per-command completion
        // ------------------------------------------------------------------
        H_CMD0, H_CMD1, H_CMD2, H_CMD3, H_WCMD, H_RCMD: begin
          case (phase)
            PH_TX: begin           // shift out 48 command bits, MSB first
              cmd_out_r <= cmd_sh[47];
              cmd_sh    <= {cmd_sh[46:0], 1'b1};
              if (bit_cnt == 9'd1) begin
                bit_cnt  <= 9'd0;
                phase    <= PH_GAP;
                wait_cnt <= 7'd0;
              end else begin
                bit_cnt <= bit_cnt - 9'd1;
              end
            end
            PH_GAP: begin          // release CMD line, inter-frame gap
              cmd_oe_r  <= 1'b0;
              wait_cnt  <= wait_cnt + 7'd1;
              if (rsp_len == 8'd0) begin          // CMD0: no response
                if (wait_cnt == 7'd7)
                  `EMMC_ISSUE(H_CMD1, 6'd1, OCR_ARG, 8'd48)
              end else if (wait_cnt == 7'd3) begin
                phase    <= PH_RSP;
                wait_cnt <= 7'd0;
                bit_cnt  <= 9'd0;
              end
            end
            PH_RSP: begin
              if (bit_cnt == 9'd0) begin          // hunt for start bit
                if (cmd == 1'b0) begin
                  rsp_sh   <= {135'h0, 1'b0};
                  bit_cnt  <= 9'd1;
                  wait_cnt <= 7'd0;
                end else if (wait_cnt == TO_MAX) begin
                  `EMMC_RAISE(err_timeout)
                end else begin
                  wait_cnt <= wait_cnt + 7'd1;
                end
              end else begin                       // shift remaining bits
                rsp_sh <= rsp_nxt;
                if (bit_cnt == {1'b0, rsp_len} - 9'd1) begin
                  bit_cnt <= 9'd0;
                  case (cur_cmd)
                    6'd1: begin                    // R3: OCR, no CRC check
                      if (rsp_nxt[39])             // busy bit = ready
                        `EMMC_ISSUE(H_CMD2, 6'd2, 32'h0000_0000, 8'd136)
                      else                         // still busy: poll again
                        `EMMC_ISSUE(H_CMD1, 6'd1, OCR_ARG, 8'd48)
                    end
                    6'd2: begin                    // R2: capture 128-bit CID
                      cid <= {rsp_nxt[127:1], 1'b1};
                      `EMMC_ISSUE(H_CMD3, 6'd3, RCA_ARG, 8'd48)
                    end
                    6'd3: begin                    // R1 after SET_RCA
                      if (r1_ok) begin
                        init_done <= 1'b1;
                        state     <= H_IDLE;
                        wait_cnt  <= 7'd0;
                      end else `EMMC_RAISE(err_crc7)
                    end
                    6'd24: begin                   // R1 after CMD24
                      if (r1_ok) begin
                        state      <= H_WDAT;
                        dphase     <= DP_START;
                        dat0_oe_r  <= 1'b1;        // drives idle '1' first
                        crc16      <= 16'h0000;
                        bit_cnt    <= BLK_CNT;
                        dat_sh     <= exp_blk;
                      end else `EMMC_RAISE(err_crc7)
                    end
                    6'd17: begin                   // R1 after CMD17
                      if (r1_ok) begin
                        state    <= H_RDAT;
                        dphase   <= DP_START;
                        crc16    <= 16'h0000;
                        crc_rx   <= 16'h0000;
                        wait_cnt <= 7'd0;
                      end else `EMMC_RAISE(err_crc7)
                    end
                    default: begin
                      state    <= H_IDLE;
                      wait_cnt <= 7'd0;
                    end
                  endcase
                end else begin
                  bit_cnt <= bit_cnt + 9'd1;
                end
              end
            end
            default: phase <= PH_TX;
          endcase
        end

        // ------------------------------------------------------------------
        // idle gap between demo rounds, then issue CMD24 for this round
        // ------------------------------------------------------------------
        H_IDLE: begin
          wait_cnt <= wait_cnt + 7'd1;
          if (wait_cnt == 7'd7)
            `EMMC_ISSUE(H_WCMD, 6'd24, {30'h0, round[1:0]}, 8'd48)
        end

        // ------------------------------------------------------------------
        // write data block on dat[0]: start(0) + 256b + CRC16 + end(1) + busy
        // ------------------------------------------------------------------
        H_WDAT: begin
          case (dphase)
            DP_START: begin        // one idle '1' cycle, then data start bit
              dat0_out_r <= 1'b0;
              dphase     <= DP_DATA;
            end
            DP_DATA: begin
              dat0_out_r <= dat_sh[255];
              dat_sh     <= {dat_sh[254:0], 1'b0};
              crc16      <= crc16_step(crc16, dat_sh[255]);
              if (bit_cnt == 9'd1) begin
                bit_cnt <= 9'd16;
                dphase  <= DP_CRC;
              end else begin
                bit_cnt <= bit_cnt - 9'd1;
              end
            end
            DP_CRC: begin
              dat0_out_r <= crc16[15];
              crc16      <= {crc16[14:0], 1'b0};
              if (bit_cnt == 9'd1) begin
                dphase <= DP_END;
              end else begin
                bit_cnt <= bit_cnt - 9'd1;
              end
            end
            DP_END: begin
              dat0_out_r <= 1'b1;    // end bit
              dphase     <= DP_BUSY;
              wait_cnt   <= 7'd0;
              busy_rel   <= 1'b0;
            end
            DP_BUSY: begin
              dat0_oe_r <= 1'b0;     // release DAT0; card drives busy
              if (!busy_rel) begin
                // skip first cycle: DAT0 may still show our own end bit
                if (wait_cnt != 7'd0 && dat[0] == 1'b1) begin
                  busy_rel <= 1'b1;  // busy released; allow card to re-arm
                  wait_cnt <= 7'd0;
                end else if (wait_cnt == TO_MAX) begin
                  `EMMC_RAISE(err_timeout)
                end else begin
                  wait_cnt <= wait_cnt + 7'd1;
                end
              end else begin         // inter-transaction gap after busy
                wait_cnt <= wait_cnt + 7'd1;
                if (wait_cnt == 7'd5)
                  `EMMC_ISSUE(H_RCMD, 6'd17, {30'h0, round[1:0]}, 8'd48)
              end
            end
            default: dphase <= DP_START;
          endcase
        end

        // ------------------------------------------------------------------
        // read data block on dat[0]: wait start, 256b + CRC16 check + end(1)
        // ------------------------------------------------------------------
        H_RDAT: begin
          case (dphase)
            DP_START: begin        // wait for data start bit
              if (dat[0] == 1'b0) begin
                dphase  <= DP_DATA;
                bit_cnt <= BLK_CNT;
              end else if (wait_cnt == TO_MAX) begin
                `EMMC_RAISE(err_timeout)
              end else begin
                wait_cnt <= wait_cnt + 7'd1;
              end
            end
            DP_DATA: begin
              dat_sh <= {dat_sh[254:0], dat[0]};
              crc16  <= crc16_step(crc16, dat[0]);
              if (bit_cnt == 9'd1) begin
                bit_cnt <= 9'd16;
                dphase  <= DP_CRC;
              end else begin
                bit_cnt <= bit_cnt - 9'd1;
              end
            end
            DP_CRC: begin
              crc_rx <= {crc_rx[14:0], dat[0]};
              if (bit_cnt == 9'd1) begin
                dphase <= DP_END;
              end else begin
                bit_cnt <= bit_cnt - 9'd1;
              end
            end
            DP_END: begin
              if (dat[0] == 1'b1 && crc_rx == crc16) begin
                if (dat_sh == exp_blk) begin
                  match_cnt <= match_cnt + 8'd1;   // read-back compare OK
                  round     <= round + 8'd1;
                  state     <= H_IDLE;
                  wait_cnt  <= 7'd0;
                end else begin
                  `EMMC_RAISE(err_cmp)
                end
              end else begin
                `EMMC_RAISE(err_crc16)             // bad CRC16/end: discard
              end
            end
            default: dphase <= DP_START;
          endcase
        end

        default: begin
          state <= H_CMD0;
        end
      endcase
      end // bit_tick
    end
  end

  `undef EMMC_ISSUE
  `undef EMMC_RAISE

endmodule
