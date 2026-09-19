// SPDX-License-Identifier: Apache-2.0
// ============================================================================
// SD protocol Open IP -- SD memory card host: CMD0/CMD8/ACMD41/CMD2/CMD3/CMD7
// init sequence, CMD24/CMD17 single-block read/write in 4-bit DAT mode,
// CMD13 status poll, R1/R2/R3/R6/R7 response parsing, CRC7/CRC16 checking
// IP design implementation v1.0 -- Apache-2.0
// ----------------------------------------------------------------------------
// Documented simplifications (educational slice of the SD physical layer):
//  - Block length is 32 bytes (256 bits) instead of the SD-native 512 bytes.
//  - 4-bit bus mode from the start (bus-width switch via ACMD6 is skipped;
//    the host is born in 4-bit mode, documented deviation).
//  - sd_clk is generated from clk by an even divider (parameter SD_CLK_DIV);
//    all host logic runs in the clk domain and advances one bus bit per
//    sd_clk period (internal "tick" aligned with the sd_clk rising edge).
//  - CMD7's R1b busy on DAT0 is simplified to plain R1 (no busy wait).
//  - Response/data-start timeout is 64 sd_clk cycles.
//  - The host autonomously repeats demo rounds: CMD24 write of an internal
//    pattern block, CMD17 read-back compare, CMD13 status poll. Round n
//    uses block address n[1:0]. Status is observable via internal state
//    (TB hierarchical reference) and irq pulses.
// ============================================================================
module SD_top #(
  parameter int DW = 32,          // data width (reserved, fixed 32-byte blocks)
  parameter int AW = 32,          // address width (reserved, block addr in arg)
  parameter int SD_CLK_DIV = 4    // clk cycles per sd_clk period (even, >= 2)
)(
  input  logic       clk,
  input  logic       rst_n,
  output logic       sd_clk,
  inout  logic       cmd,
  inout  logic [3:0] dat,
  output logic       irq
);

  // ------------------------- constants -------------------------
  localparam int BLK_BITS   = 256;             // 32-byte simplified block
  localparam int NIBBLES    = 64;              // 256 bits / 4-bit bus
  localparam logic [8:0] NIB_CNT = 9'd64;      // nibble count, sized
  localparam logic [6:0] TO_MAX  = 7'd63;      // timeout limit (64 sd_clk)
  localparam logic [31:0] IF_COND  = 32'h0000_01AA; // CMD8: 2.7-3.6V + 0xAA
  localparam logic [31:0] OCR_ARG  = 32'h40FF_8000; // ACMD41: HCS + 3.3V window
  localparam int DIV = SD_CLK_DIV;

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
    H_CMD0  = 4'd0,    // GO_IDLE (no response)
    H_CMD8  = 4'd1,    // SEND_IF_COND (R7, 0x1AA check)
    H_ACMD  = 4'd2,    // CMD55 (R1) then CMD41 (R3) -- ACMD41 OCR polling
    H_CMD2  = 4'd3,    // ALL_SEND_CID (R2, 136-bit)
    H_CMD3  = 4'd4,    // SEND_RCA (R6)
    H_CMD7  = 4'd5,    // SELECT_CARD (R1)
    H_IDLE  = 4'd6,    // between demo rounds
    H_WCMD  = 4'd7,    // CMD24 single-block write (R1)
    H_WDAT  = 4'd8,    // write data block on dat[3:0]
    H_RCMD  = 4'd9,    // CMD17 single-block read (R1)
    H_RDAT  = 4'd10,   // read data block on dat[3:0]
    H_CMD13 = 4'd11    // SEND_STATUS (R1) after each round
  } hstate_t;

  localparam logic [1:0] PH_TX  = 2'd0,
                         PH_GAP = 2'd1,
                         PH_RSP = 2'd2;

  localparam logic [2:0] DP_START  = 3'd0,   // write: start bits / read: wait
                         DP_DATA   = 3'd1,   // 64 nibbles
                         DP_CRC    = 3'd2,   // 16 CRC16 bits per line
                         DP_END    = 3'd3,   // end bits
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
  logic         dat_oe_r;
  logic [3:0]   dat_out_r;
  logic [255:0] dat_sh;         // TX shift / RX assemble buffer
  logic [15:0]  crc0, crc1, crc2, crc3;   // per-DAT-line CRC16 (running)
  logic [15:0]  crx0, crx1, crx2, crx3;   // per-DAT-line CRC16 (received)
  logic         busy_rel;       // write busy release observed
  logic [7:0]   round;
  logic [7:0]   match_cnt;      // successful read-back compares
  logic [127:0] cid;
  logic [15:0]  rca;
  logic [31:0]  card_status;    // last R1/R6 status field
  logic         init_done;
  logic         err_crc7, err_crc16, err_timeout, err_cmp, err_r7;

  // ------------------------- sd_clk divider -------------------------
  // sd_clk = clk / SD_CLK_DIV; "tick" is the clk edge where sd_clk rises,
  // so every host bus action is aligned to the sd_clk rising edge.
  localparam int DIV_W = (DIV <= 2) ? 1 : $clog2(DIV);
  logic [DIV_W-1:0] div_cnt;
  wire tick = (div_cnt == DIV_W'(DIV-1));

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      div_cnt <= '0;
      sd_clk  <= 1'b0;
    end else if (div_cnt == DIV_W'(DIV-1)) begin
      div_cnt <= '0;
      sd_clk  <= 1'b1;
    end else begin
      div_cnt <= div_cnt + DIV_W'(1);
      if (div_cnt == DIV_W'(DIV/2-1)) sd_clk <= 1'b0;
    end
  end

  // ------------------------- bus drivers -------------------------
  assign cmd = cmd_oe_r ? cmd_out_r : 1'bz;
  assign dat = dat_oe_r ? dat_out_r : 4'bzzzz;

  // expected payload for the current round (write source / read reference)
  logic [255:0] exp_blk;
  always_comb begin
    for (int i = 0; i < 8; i++)          // constant bound
      exp_blk[255 - i*32 -: 32] = pat_word(round, i[7:0]);
  end

  // next response-shift value and response field checks (combinational)
  logic [135:0] rsp_nxt;
  always_comb rsp_nxt = {rsp_sh[134:0], cmd};
  logic r1_ok;                   // valid end bit + CRC7 (R1/R6/R7 framing)
  always_comb r1_ok = (rsp_nxt[0] == 1'b1) &&
                      (crc7_40(rsp_nxt[46:8]) == rsp_nxt[7:1]);
  // R7: cmd index 8, voltage range accepted (4'h1) and pattern echo 8'hAA
  logic r7_ok;
  always_comb r7_ok = r1_ok && (rsp_nxt[45:40] == 6'd8) &&
                      (rsp_nxt[19:16] == 4'h1) && (rsp_nxt[15:8] == 8'hAA);
  // R6: cmd index 3, RCA in arg[31:16]
  logic r6_ok;
  always_comb r6_ok = r1_ok && (rsp_nxt[45:40] == 6'd3);

  // ------------------------- macros (kept local) -------------------------
  // issue a 48-bit command frame and arm the response engine
  `define SD_ISSUE(ST, IDX, ARG, RLEN) \
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

  // raise error: sticky flag + 1-tick irq pulse; init errors restart init,
  // data-phase errors return to H_IDLE which restarts the current round
  `define SD_RAISE(ERRF) \
    begin \
      ERRF <= 1'b1; \
      irq  <= 1'b1; \
      if (init_done) begin \
        state    <= H_IDLE; \
        wait_cnt <= 7'd0; \
      end else begin \
        `SD_ISSUE(H_CMD0, 6'd0, 32'h0000_0000, 8'd0) \
      end \
    end

  // ------------------------- main FSM -------------------------
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      state       <= H_CMD0;
      phase       <= PH_TX;
      dphase      <= DP_START;
      bit_cnt     <= 9'd48;
      wait_cnt    <= 7'd0;
      cmd_sh      <= cmd_frame(6'd0, 32'h0000_0000);
      rsp_sh      <= '0;
      rsp_len     <= 8'd0;
      cur_cmd     <= 6'd0;
      cmd_oe_r    <= 1'b1;          // first act after reset: send CMD0
      cmd_out_r   <= 1'b1;
      dat_oe_r    <= 1'b0;
      dat_out_r   <= 4'hF;
      dat_sh      <= '0;
      busy_rel    <= 1'b0;
      crc0        <= 16'h0000;
      crc1        <= 16'h0000;
      crc2        <= 16'h0000;
      crc3        <= 16'h0000;
      crx0        <= 16'h0000;
      crx1        <= 16'h0000;
      crx2        <= 16'h0000;
      crx3        <= 16'h0000;
      round       <= 8'd0;
      match_cnt   <= 8'd0;
      cid         <= 128'h0;
      rca         <= 16'h0;
      card_status <= 32'h0;
      init_done   <= 1'b0;
      err_crc7    <= 1'b0;
      err_crc16   <= 1'b0;
      err_timeout <= 1'b0;
      err_cmp     <= 1'b0;
      err_r7      <= 1'b0;
      irq         <= 1'b0;
    end else if (tick) begin
      irq <= 1'b0;                 // default: single-tick pulse

      case (state)
        // ------------------------------------------------------------------
        // command states: shared TX/GAP/RSP engine, per-command completion
        // ------------------------------------------------------------------
        H_CMD0, H_CMD8, H_ACMD, H_CMD2, H_CMD3, H_CMD7,
        H_WCMD, H_RCMD, H_CMD13: begin
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
                  `SD_ISSUE(H_CMD8, 6'd8, IF_COND, 8'd48)
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
                  `SD_RAISE(err_timeout)
                end else begin
                  wait_cnt <= wait_cnt + 7'd1;
                end
              end else begin                       // shift remaining bits
                rsp_sh <= rsp_nxt;
                if (bit_cnt == {1'b0, rsp_len} - 9'd1) begin
                  bit_cnt <= 9'd0;
                  case (cur_cmd)
                    6'd8: begin                    // R7: voltage + pattern
                      if (r7_ok)
                        `SD_ISSUE(H_ACMD, 6'd55, 32'h0000_0000, 8'd48)
                      else
                        `SD_RAISE(err_r7)          // bad IF_COND: restart
                    end
                    6'd55: begin                   // R1 (APP_CMD) -> CMD41
                      if (r1_ok) begin
                        card_status <= rsp_nxt[39:8];
                        `SD_ISSUE(H_ACMD, 6'd41, OCR_ARG, 8'd48)
                      end else `SD_RAISE(err_crc7)
                    end
                    6'd41: begin                   // R3: OCR, no CRC check
                      if (rsp_nxt[39])             // busy bit = ready
                        `SD_ISSUE(H_CMD2, 6'd2, 32'h0000_0000, 8'd136)
                      else                         // still busy: poll again
                        `SD_ISSUE(H_ACMD, 6'd55, 32'h0000_0000, 8'd48)
                    end
                    6'd2: begin                    // R2: capture 128-bit CID
                      cid <= {rsp_nxt[127:1], 1'b1};
                      `SD_ISSUE(H_CMD3, 6'd3, 32'h0000_0000, 8'd48)
                    end
                    6'd3: begin                    // R6: capture RCA -> CMD7
                      if (r6_ok) begin
                        rca         <= rsp_nxt[39:24];
                        card_status <= {16'h0, rsp_nxt[23:8]};
                        `SD_ISSUE(H_CMD7, 6'd7, {rsp_nxt[39:24], 16'h0}, 8'd48)
                      end else `SD_RAISE(err_crc7)
                    end
                    6'd7: begin                    // R1 after SELECT_CARD
                      if (r1_ok) begin
                        card_status <= rsp_nxt[39:8];
                        init_done   <= 1'b1;
                        state       <= H_IDLE;
                        wait_cnt    <= 7'd0;
                      end else `SD_RAISE(err_crc7)
                    end
                    6'd24: begin                   // R1 after CMD24
                      if (r1_ok) begin
                        card_status <= rsp_nxt[39:8];
                        state       <= H_WDAT;
                        dphase      <= DP_START;
                        dat_oe_r    <= 1'b1;       // drives idle '1's first
                        dat_out_r   <= 4'hF;
                        crc0        <= 16'h0000;
                        crc1        <= 16'h0000;
                        crc2        <= 16'h0000;
                        crc3        <= 16'h0000;
                        bit_cnt     <= NIB_CNT;
                        dat_sh      <= exp_blk;
                      end else `SD_RAISE(err_crc7)
                    end
                    6'd17: begin                   // R1 after CMD17
                      if (r1_ok) begin
                        card_status <= rsp_nxt[39:8];
                        state    <= H_RDAT;
                        dphase   <= DP_START;
                        crc0     <= 16'h0000;
                        crc1     <= 16'h0000;
                        crc2     <= 16'h0000;
                        crc3     <= 16'h0000;
                        crx0     <= 16'h0000;
                        crx1     <= 16'h0000;
                        crx2     <= 16'h0000;
                        crx3     <= 16'h0000;
                        wait_cnt <= 7'd0;
                      end else `SD_RAISE(err_crc7)
                    end
                    6'd13: begin                   // R1: status, round done
                      if (r1_ok) begin
                        card_status <= rsp_nxt[39:8];
                        match_cnt   <= match_cnt + 8'd1;
                        round       <= round + 8'd1;
                        state       <= H_IDLE;
                        wait_cnt    <= 7'd0;
                      end else `SD_RAISE(err_crc7)
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
            `SD_ISSUE(H_WCMD, 6'd24, {30'h0, round[1:0]}, 8'd48)
        end

        // ------------------------------------------------------------------
        // write data block: start(0000) + 64 nibbles + 4xCRC16 + end(1111)
        // nibble bit i travels on DAT[i]; each line carries its own CRC16
        // ------------------------------------------------------------------
        H_WDAT: begin
          case (dphase)
            DP_START: begin        // one idle cycle was driven, now start bits
              dat_out_r <= 4'b0000;
              dphase    <= DP_DATA;
            end
            DP_DATA: begin
              dat_out_r <= dat_sh[255:252];
              dat_sh    <= {dat_sh[251:0], 4'h0};
              crc0      <= crc16_step(crc0, dat_sh[252]);
              crc1      <= crc16_step(crc1, dat_sh[253]);
              crc2      <= crc16_step(crc2, dat_sh[254]);
              crc3      <= crc16_step(crc3, dat_sh[255]);
              if (bit_cnt == 9'd1) begin
                bit_cnt <= 9'd16;
                dphase  <= DP_CRC;
              end else begin
                bit_cnt <= bit_cnt - 9'd1;
              end
            end
            DP_CRC: begin
              dat_out_r <= {crc3[15], crc2[15], crc1[15], crc0[15]};
              crc0      <= {crc0[14:0], 1'b0};
              crc1      <= {crc1[14:0], 1'b0};
              crc2      <= {crc2[14:0], 1'b0};
              crc3      <= {crc3[14:0], 1'b0};
              if (bit_cnt == 9'd1) begin
                dphase <= DP_END;
              end else begin
                bit_cnt <= bit_cnt - 9'd1;
              end
            end
            DP_END: begin
              dat_out_r <= 4'hF;       // end bits on all lines
              dphase    <= DP_BUSY;
              wait_cnt  <= 7'd0;
              busy_rel  <= 1'b0;
            end
            DP_BUSY: begin
              dat_oe_r <= 1'b0;        // release DAT; card drives busy on DAT0
              if (!busy_rel) begin
                // skip first tick: DAT0 may still show our own end bit
                if (wait_cnt != 7'd0 && dat[0] == 1'b1) begin
                  busy_rel <= 1'b1;    // busy released; allow card to re-arm
                  wait_cnt <= 7'd0;
                end else if (wait_cnt == TO_MAX) begin
                  `SD_RAISE(err_timeout)
                end else begin
                  wait_cnt <= wait_cnt + 7'd1;
                end
              end else begin           // inter-transaction gap after busy
                wait_cnt <= wait_cnt + 7'd1;
                if (wait_cnt == 7'd5)
                  `SD_ISSUE(H_RCMD, 6'd17, {30'h0, round[1:0]}, 8'd48)
              end
            end
            default: dphase <= DP_START;
          endcase
        end

        // ------------------------------------------------------------------
        // read data block: wait start(0000), 64 nibbles + 4xCRC16 check,
        // end(1111); mismatch on any line CRC16 discards the block
        // ------------------------------------------------------------------
        H_RDAT: begin
          case (dphase)
            DP_START: begin        // wait for data start bits
              if (dat == 4'b0000) begin
                dphase  <= DP_DATA;
                bit_cnt <= NIB_CNT;
              end else if (wait_cnt == TO_MAX) begin
                `SD_RAISE(err_timeout)
              end else begin
                wait_cnt <= wait_cnt + 7'd1;
              end
            end
            DP_DATA: begin
              dat_sh <= {dat_sh[251:0], dat};
              crc0   <= crc16_step(crc0, dat[0]);
              crc1   <= crc16_step(crc1, dat[1]);
              crc2   <= crc16_step(crc2, dat[2]);
              crc3   <= crc16_step(crc3, dat[3]);
              if (bit_cnt == 9'd1) begin
                bit_cnt <= 9'd16;
                dphase  <= DP_CRC;
              end else begin
                bit_cnt <= bit_cnt - 9'd1;
              end
            end
            DP_CRC: begin
              crx0 <= {crx0[14:0], dat[0]};
              crx1 <= {crx1[14:0], dat[1]};
              crx2 <= {crx2[14:0], dat[2]};
              crx3 <= {crx3[14:0], dat[3]};
              if (bit_cnt == 9'd1) begin
                dphase <= DP_END;
              end else begin
                bit_cnt <= bit_cnt - 9'd1;
              end
            end
            DP_END: begin
              if (dat == 4'hF && crx0 == crc0 && crx1 == crc1 &&
                  crx2 == crc2 && crx3 == crc3) begin
                if (dat_sh == exp_blk) begin     // read-back compare OK
                  `SD_ISSUE(H_CMD13, 6'd13, {rca, 16'h0}, 8'd48)
                end else begin
                  `SD_RAISE(err_cmp)
                end
              end else begin
                `SD_RAISE(err_crc16)             // bad CRC16/end: discard
              end
            end
            default: dphase <= DP_START;
          endcase
        end

        default: begin
          state <= H_CMD0;
        end
      endcase
    end
  end

  `undef SD_ISSUE
  `undef SD_RAISE

endmodule
