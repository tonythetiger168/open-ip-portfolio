// SPDX-License-Identifier: Apache-2.0
// ============================================================================
// SD protocol Open IP -- SD memory card host: CMD0/CMD8/ACMD41/CMD2/CMD3/CMD7
// init sequence, CMD24/CMD17 single-block read/write in 4-bit DAT mode,
// CMD13 status poll, R1/R2/R3/R6/R7 response checking, CRC7/CRC16
// IP design implementation v1.1 -- Apache-2.0
// ----------------------------------------------------------------------------
// Documented simplifications (educational slice of the SD physical layer):
//  - Block length is 32 bytes (256 bits) instead of the SD-native 512 bytes.
//  - 4-bit bus mode from the start (bus-width switch via ACMD6 is skipped;
//    the host is born in 4-bit mode, documented deviation).
//  - sd_clk is generated from clk by an even divider: ID_CLK_DIV during
//    card identification (CMD0 .. CMD3, which must run at 400 kHz or less:
//    the default 128 meets that for clk up to 51.2 MHz) and SD_CLK_DIV once
//    the card has published its RCA (from CMD7 on). All host logic runs in
//    the clk domain and advances one bus bit per sd_clk period (internal
//    "tick" on the sd_clk rising edge, where CMD / DAT are sampled); the
//    CMD / DAT drivers change on the sd_clk falling edge.
//  - The response start bit is looked for from the 2nd sd_clk after the
//    command end bit (N_CR = 2, the minimum) up to 64 clocks.
//  - CMD7's R1b busy on DAT0 is simplified to plain R1 (no busy wait).
//  - Response / data-start / CRC-status / busy timeout is 64 sd_clk cycles.
//  - The host autonomously repeats demo rounds: CMD24 write of an internal
//    pattern block, CMD17 read-back compare, CMD13 status poll. Round n
//    uses block n[1:0]: the argument is the block number for a high
//    capacity card (OCR CCS = 1) and its byte address (n[1:0] * 32)
//    otherwise. Status is observable via internal state (TB hierarchical
//    reference) and irq pulses.
//  - Response checks: R1 (CMD55/7/24/17/13) start + transmission bits,
//    command index, CRC7, end bit and the card-status error bits
//    (ERR_MASK); R6 (CMD3) the same with its 16 status bits; R7 (CMD8)
//    framing plus the echoed voltage (1) and check pattern (0xAA); R3
//    framing (start, transmission, reserved 111111 fields, end bit); R2
//    framing (start, transmission, 111111) and the CID's own CRC7 with
//    CID[0] = 1. A failed check raises irq: framing / CRC -> err_crc7,
//    status bits -> err_status, R7 contents -> err_r7.
//  - Write: after the end bits the card returns the CRC status token on
//    DAT0 (0, 3 status bits, 1); 010 = accepted, anything else ->
//    err_crc16. The host then waits for the card to release DAT0 busy.
//  - Errors during init restart it with CMD0; errors in a round return to
//    the idle gap, which restarts the round.
// ============================================================================
module SD_top #(
  parameter int SD_CLK_DIV = 4,   // clk cycles per sd_clk period (even, >= 2)
  parameter int ID_CLK_DIV = 128  // the same during identification (even, >= 2)
)(
  input  logic       clk,
  input  logic       rst_n,
  output logic       sd_clk,
  inout  logic       cmd,
  inout  logic [3:0] dat,
  output logic       irq
);

  // ------------------------- constants -------------------------
  localparam logic [6:0] NIB_CNT  = 7'd64;          // nibbles per block
  localparam logic [5:0] TO_MAX   = 6'd63;          // timeout limit (64 sd_clk)
  localparam logic [31:0] IF_COND = 32'h0000_01AA;  // CMD8: 2.7-3.6V + 0xAA
  localparam logic [31:0] OCR_ARG = 32'h40FF_8000;  // ACMD41: HCS + 3.3V window
  // R1 card-status error bits: OUT_OF_RANGE, ADDRESS_ERROR, BLOCK_LEN_ERROR,
  // ERASE_SEQ_ERROR, ERASE_PARAM, WP_VIOLATION, LOCK_UNLOCK_FAILED,
  // COM_CRC_ERROR, ILLEGAL_COMMAND, CARD_ECC_FAILED, CC_ERROR, ERROR,
  // CSD_OVERWRITE, WP_ERASE_SKIP, AKE_SEQ_ERROR
  localparam logic [31:0] ERR_MASK = 32'hFDF9_8008;
  // R6 status field {23, 22, 19, 12:0}: COM_CRC_ERROR, ILLEGAL_COMMAND,
  // ERROR, AKE_SEQ_ERROR
  localparam logic [15:0] R6_MASK  = 16'hE008;
  localparam int DIV  = SD_CLK_DIV;
  localparam int IDIV = ID_CLK_DIV;
  localparam int MDIV = (DIV > IDIV) ? DIV : IDIV;

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
    crc7_40 = c;
  endfunction

  // CRC7 of the CID register (CID[127:8], 120 bits) -- stored in CID[7:1]
  function automatic logic [6:0] cid_crc(input logic [119:0] d);
    logic [6:0] c;
    logic       fb;
    c = 7'h00;
    for (int i = 119; i >= 0; i--) begin
      fb = d[i] ^ c[6];
      c  = {c[5:0], 1'b0};
      if (fb) c = c ^ 7'h09;
    end
    cid_crc = c;
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
    body = {2'b01, idx, arg};
    cmd_frame = {body, crc7_40(body), 1'b1};
  endfunction

  // Demo payload pattern: word i of round r (MSB of block shifted out first)
  function automatic logic [31:0] pat_word(input logic [7:0] r,
                                           input logic [7:0] i);
    pat_word = 32'hA500_3C00 ^ {24'h0, r} ^ ({24'h0, i} * 32'h0001_0101);
  endfunction
  function automatic logic [255:0] exp_blk(input logic [7:0] r);
    for (int i = 0; i < 8; i++)          // constant bound
      exp_blk[255 - i*32 -: 32] = pat_word(r, i[7:0]);
  endfunction

  // ------------------------- state types -------------------------
  // host activity; which command is in flight is held separately in cur
  typedef enum logic [2:0] {
    H_CTX  = 3'd0,   // shift a 48-bit command frame out on CMD
    H_GAP  = 3'd1,   // CMD released: gap before the response (or next command)
    H_RSP  = 3'd2,   // hunt for the response start bit, then shift it in
    H_IDLE = 3'd3,   // between demo rounds
    H_WDAT = 3'd4,   // write data block on dat[3:0], CRC status, busy
    H_RDAT = 3'd5    // read data block on dat[3:0]
  } hstate_t;

  // command in flight
  localparam logic [3:0] C0 = 4'd0, C8 = 4'd1, C55 = 4'd2, C41 = 4'd3, C2 = 4'd4,
                         C3 = 4'd5, C7 = 4'd6, C24 = 4'd7, C17 = 4'd8, C13 = 4'd9;
  function automatic logic [5:0] cmd_idx(input logic [3:0] c);
    case (c)
      C8:      cmd_idx = 6'd8;
      C55:     cmd_idx = 6'd55;
      C41:     cmd_idx = 6'd41;
      C2:      cmd_idx = 6'd2;
      C3:      cmd_idx = 6'd3;
      C7:      cmd_idx = 6'd7;
      C24:     cmd_idx = 6'd24;
      C17:     cmd_idx = 6'd17;
      C13:     cmd_idx = 6'd13;
      default: cmd_idx = 6'd0;
    endcase
  endfunction

  localparam logic [2:0] DP_START  = 3'd0,   // write: start bits / read: wait start
                         DP_DATA   = 3'd1,   // 64 nibbles
                         DP_CRC    = 3'd2,   // 16 CRC16 bits per line
                         DP_END    = 3'd3,   // end bits
                         DP_TOK    = 3'd4,   // write: CRC status token
                         DP_BUSY   = 3'd5;   // write: wait busy release

  // ------------------------- registers -------------------------
  hstate_t      state;
  logic [3:0]   cur;            // command in flight
  logic [2:0]   dphase;         // data sub-phase
  logic [7:0]   bit_cnt;
  logic [5:0]   wait_cnt;
  logic [47:0]  cmd_sh;
  logic [134:0] rsp_sh;
  logic         cmd_oe_r, cmd_out_r;
  logic         dat_oe_r;
  logic [3:0]   dat_out_r;
  logic [255:0] dat_sh;         // TX shift / RX assemble buffer
  logic [15:0]  crc0, crc1, crc2, crc3;   // per-DAT-line CRC16 (running)
  logic [15:0]  crx0, crx1, crx2, crx3;   // per-DAT-line CRC16 (received)
  logic         busy_rel;       // write busy release observed
  logic [2:0]   tok;            // CRC status token bits received so far
  logic [7:0]   round;
  logic [7:0]   match_cnt;      // completed rounds (read-back compare OK)
  logic [127:0] cid;
  logic [15:0]  rca;
  logic         ccs;            // high capacity card (block addressing)
  logic         init_done;
  logic         fast;           // RCA published: data-transfer clock rate
  logic         err_crc7, err_crc16, err_timeout, err_cmp, err_r7, err_status;

  // ------------------------- sd_clk divider -------------------------
  // sd_clk = clk / ID_CLK_DIV until the RCA is published, clk / SD_CLK_DIV
  // after; "tick" is the clk edge where sd_clk rises (the host samples CMD /
  // DAT there and steps its FSM), "ftick" the one where it falls. The rate
  // changes only at a tick, so every sd_clk period is whole.
  localparam int DIV_W = (MDIV <= 2) ? 1 : $clog2(MDIV);
  logic [DIV_W-1:0] div_cnt;
  wire [DIV_W-1:0] div_top = fast ? DIV_W'(DIV-1)   : DIV_W'(IDIV-1);
  wire [DIV_W-1:0] div_mid = fast ? DIV_W'(DIV/2-1) : DIV_W'(IDIV/2-1);
  wire tick  = (div_cnt == div_top);
  wire ftick = (div_cnt == div_mid);

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      div_cnt <= '0;
      sd_clk  <= 1'b0;
    end else if (tick) begin
      div_cnt <= '0;
      sd_clk  <= 1'b1;
    end else begin
      div_cnt <= div_cnt + DIV_W'(1);
      if (ftick) sd_clk <= 1'b0;
    end
  end

  // ------------------------- bus drivers -------------------------
  // the FSM sets the next CMD / DAT value at a tick; the pins take it at the
  // following falling edge, half a period before the card samples it
  logic       cmd_oe_p, cmd_out_p, dat_oe_p;
  logic [3:0] dat_out_p;
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      cmd_oe_p <= 1'b0; cmd_out_p <= 1'b1; dat_oe_p <= 1'b0; dat_out_p <= 4'hF;
    end else if (ftick) begin
      cmd_oe_p <= cmd_oe_r; cmd_out_p <= cmd_out_r;
      dat_oe_p <= dat_oe_r; dat_out_p <= dat_out_r;
    end
  end
  assign cmd = cmd_oe_p ? cmd_out_p : 1'bz;
  assign dat = dat_oe_p ? dat_out_p : 4'bzzzz;

  // next response-shift value and response checks (combinational)
  logic [135:0] rsp_nxt;
  always_comb rsp_nxt = {rsp_sh, cmd};

  // the CID, RCA and the sticky error flags are status registers read
  // hierarchically (no register port)
  wire _unused = &{1'b0, cid, err_crc7, err_crc16, err_timeout, err_cmp, err_r7,
                   err_status, rsp_nxt[135]};
  logic r1_ok, r1_err, r6_err, r7_ok, r2_ok, r3_ok;
  always_comb begin
    r1_ok  = (rsp_nxt[46] == 1'b0) && (rsp_nxt[45:40] == cmd_idx(cur)) &&
             (rsp_nxt[0] == 1'b1) && (crc7_40(rsp_nxt[47:8]) == rsp_nxt[7:1]);
    r1_err = (rsp_nxt[39:8] & ERR_MASK) != 32'h0;
    r6_err = (rsp_nxt[23:8] & R6_MASK) != 16'h0;
    r7_ok  = (rsp_nxt[19:16] == 4'h1) && (rsp_nxt[15:8] == 8'hAA);
    r3_ok  = (rsp_nxt[46] == 1'b0) && (rsp_nxt[45:40] == 6'h3F) &&
             (rsp_nxt[7:0] == 8'hFF);
    r2_ok  = (rsp_nxt[134] == 1'b0) && (rsp_nxt[133:128] == 6'h3F) &&
             (cid_crc(rsp_nxt[127:8]) == rsp_nxt[7:1]) && rsp_nxt[0];
  end
  // last response bit index: R2 is 136 bits, the others 48
  wire last_rsp_bit = (cur == C2) ? (bit_cnt == 8'd135) : (bit_cnt == 8'd47);
  // block argument of round r: block number (high capacity) or byte address
  function automatic logic [31:0] blk_arg(input logic hc, input logic [1:0] r);
    blk_arg = hc ? {30'h0, r} : {25'h0, r, 5'h0};
  endfunction

  // ------------------------- macros (kept local) -------------------------
  // issue a 48-bit command frame
  `define SD_ISSUE(C, ARG) \
    begin \
      state    <= H_CTX; \
      cur      <= C; \
      cmd_sh   <= cmd_frame(cmd_idx(C), ARG); \
      bit_cnt  <= 8'd48; \
      cmd_oe_r <= 1'b1; \
      wait_cnt <= 6'd0; \
    end

  // raise error: sticky flag + 1-tick irq pulse. During init the host
  // restarts with CMD0; round errors return to H_IDLE, which restarts the
  // current round
  `define SD_FAIL_INIT(ERRF) \
    begin ERRF <= 1'b1; irq <= 1'b1; fast <= 1'b0; `SD_ISSUE(C0, 32'h0000_0000) end
  `define SD_FAIL_DATA(ERRF) \
    begin ERRF <= 1'b1; irq <= 1'b1; state <= H_IDLE; wait_cnt <= 6'd0; end

  // ------------------------- main FSM -------------------------
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      state       <= H_CTX;
      cur         <= C0;
      dphase      <= DP_START;
      bit_cnt     <= 8'd48;
      wait_cnt    <= 6'd0;
      cmd_sh      <= cmd_frame(6'd0, 32'h0000_0000);
      rsp_sh      <= '0;
      cmd_oe_r    <= 1'b1;          // first act after reset: send CMD0
      cmd_out_r   <= 1'b1;
      dat_oe_r    <= 1'b0;
      dat_out_r   <= 4'hF;
      dat_sh      <= '0;
      busy_rel    <= 1'b0;
      tok         <= 3'h0;
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
      ccs         <= 1'b0;
      init_done   <= 1'b0;
      fast        <= 1'b0;
      err_crc7    <= 1'b0;
      err_crc16   <= 1'b0;
      err_timeout <= 1'b0;
      err_cmp     <= 1'b0;
      err_r7      <= 1'b0;
      err_status  <= 1'b0;
      irq         <= 1'b0;
    end else if (tick) begin
      irq <= 1'b0;                 // default: single-tick pulse

      case (state)
        // ------------------------------------------------------------------
        // command frame out, MSB first
        // ------------------------------------------------------------------
        H_CTX: begin
          cmd_out_r <= cmd_sh[47];
          cmd_sh    <= {cmd_sh[46:0], 1'b0};
          if (bit_cnt == 8'd1) begin
            state    <= H_GAP;
            wait_cnt <= 6'd0;
          end else begin
            bit_cnt <= bit_cnt - 8'd1;
          end
        end

        // release CMD; CMD0 has no response: CMD8 follows after 8 bits.
        // Otherwise hunt for the start bit from the next clock on, so a
        // response at N_CR = 2 is seen
        H_GAP: begin
          cmd_oe_r <= 1'b0;
          wait_cnt <= wait_cnt + 6'd1;
          if (cur == C0) begin
            if (wait_cnt == 6'd7) `SD_ISSUE(C8, IF_COND)
          end else begin
            state    <= H_RSP;
            wait_cnt <= 6'd0;
            bit_cnt  <= 8'd0;
          end
        end

        // ------------------------------------------------------------------
        // response: hunt the start bit (64-bit timeout), shift, judge
        // ------------------------------------------------------------------
        H_RSP: begin
          if (bit_cnt == 8'd0) begin
            if (cmd == 1'b0) begin
              rsp_sh  <= '0;              // the start bit
              bit_cnt <= 8'd1;
            end else if (wait_cnt == TO_MAX) begin
              if (init_done) `SD_FAIL_DATA(err_timeout)
              else           `SD_FAIL_INIT(err_timeout)
            end else wait_cnt <= wait_cnt + 6'd1;
          end else begin
            rsp_sh  <= rsp_nxt[134:0];
            bit_cnt <= bit_cnt + 8'd1;
            if (last_rsp_bit) begin
              case (cur)
                C8:                       // R7: voltage + check pattern
                  if (!r1_ok)      `SD_FAIL_INIT(err_crc7)
                  else if (!r7_ok) `SD_FAIL_INIT(err_r7)
                  else             `SD_ISSUE(C55, 32'h0000_0000)
                C41:                      // R3: OCR, no CRC
                  if (!r3_ok)           `SD_FAIL_INIT(err_crc7)
                  else if (rsp_nxt[39]) begin            // power-up done
                    ccs <= rsp_nxt[38];
                    `SD_ISSUE(C2, 32'h0000_0000)
                  end else             `SD_ISSUE(C55, 32'h0000_0000) // busy: poll
                C2:                       // R2: CID[127:1] + end bit
                  if (!r2_ok) `SD_FAIL_INIT(err_crc7)
                  else begin
                    cid <= rsp_nxt[127:0];
                    `SD_ISSUE(C3, 32'h0000_0000)
                  end
                C3:                       // R6: published RCA + status
                  if (!r1_ok)      `SD_FAIL_INIT(err_crc7)
                  else if (r6_err) `SD_FAIL_INIT(err_status)
                  else begin
                    rca  <= rsp_nxt[39:24];
                    fast <= 1'b1;         // identification done: full rate
                    `SD_ISSUE(C7, {rsp_nxt[39:24], 16'h0})
                  end
                default:                  // R1: CMD55 / 7 / 24 / 17 / 13
                  if (!r1_ok || r1_err) begin
                    if (!r1_ok) err_crc7   <= 1'b1;
                    else        err_status <= 1'b1;
                    irq <= 1'b1;
                    if (init_done) begin
                      state    <= H_IDLE;
                      wait_cnt <= 6'd0;
                    end else begin
                      fast <= 1'b0;
                      `SD_ISSUE(C0, 32'h0000_0000)
                    end
                  end else case (cur)
                    C55: `SD_ISSUE(C41, OCR_ARG)
                    C7: begin
                      init_done <= 1'b1;
                      state     <= H_IDLE;
                      wait_cnt  <= 6'd0;
                    end
                    C24: begin            // send the block
                      state    <= H_WDAT;
                      dphase   <= DP_START;
                      dat_oe_r <= 1'b1;   // drives idle '1's first
                      dat_out_r <= 4'hF;
                      crc0     <= 16'h0000;
                      crc1     <= 16'h0000;
                      crc2     <= 16'h0000;
                      crc3     <= 16'h0000;
                      bit_cnt  <= {1'b0, NIB_CNT};
                      dat_sh   <= exp_blk(round);
                    end
                    C17: begin
                      state    <= H_RDAT;
                      dphase   <= DP_START;
                      crc0     <= 16'h0000;
                      crc1     <= 16'h0000;
                      crc2     <= 16'h0000;
                      crc3     <= 16'h0000;
                      wait_cnt <= 6'd0;
                    end
                    default: begin        // C13: status read, round done
                      match_cnt <= match_cnt + 8'd1;
                      round     <= round + 8'd1;
                      state     <= H_IDLE;
                      wait_cnt  <= 6'd0;
                    end
                  endcase
              endcase
            end
          end
        end

        // ------------------------------------------------------------------
        // idle gap between demo rounds, then issue CMD24 for this round
        // ------------------------------------------------------------------
        H_IDLE: begin
          wait_cnt <= wait_cnt + 6'd1;
          if (wait_cnt == 6'd7) `SD_ISSUE(C24, blk_arg(ccs, round[1:0]))
        end

        // ------------------------------------------------------------------
        // write data block: start(0000) + 64 nibbles + 4xCRC16 + end(1111)
        // nibble bit i travels on DAT[i]; each line carries its own CRC16;
        // then the CRC status token and busy on DAT0
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
              if (bit_cnt == 8'd1) begin
                bit_cnt <= 8'd16;
                dphase  <= DP_CRC;
              end else begin
                bit_cnt <= bit_cnt - 8'd1;
              end
            end
            DP_CRC: begin
              dat_out_r <= {crc3[15], crc2[15], crc1[15], crc0[15]};
              crc0      <= {crc0[14:0], 1'b0};
              crc1      <= {crc1[14:0], 1'b0};
              crc2      <= {crc2[14:0], 1'b0};
              crc3      <= {crc3[14:0], 1'b0};
              if (bit_cnt == 8'd1) dphase <= DP_END;
              else                 bit_cnt <= bit_cnt - 8'd1;
            end
            DP_END: begin
              dat_out_r <= 4'hF;       // end bits on all lines
              dphase    <= DP_TOK;
              wait_cnt  <= 6'd0;
              bit_cnt   <= 8'd0;
              busy_rel  <= 1'b0;
            end
            DP_TOK: begin            // CRC status token on DAT0: 0, s2 s1 s0, 1
              dat_oe_r <= 1'b0;      // release DAT to the card
              if (bit_cnt == 8'd0) begin
                if (dat[0] == 1'b0) bit_cnt <= 8'd1;
                else if (wait_cnt == TO_MAX) `SD_FAIL_DATA(err_timeout)
                else wait_cnt <= wait_cnt + 6'd1;
              end else begin
                tok     <= {tok[1:0], dat[0]};
                bit_cnt <= bit_cnt + 8'd1;
                if (bit_cnt == 8'd4) begin
                  if ({tok, dat[0]} == 4'b0101) begin
                    dphase   <= DP_BUSY;     // accepted: wait for busy release
                    wait_cnt <= 6'd0;
                  end else `SD_FAIL_DATA(err_crc16)
                end
              end
            end
            default: begin           // DP_BUSY
              if (!busy_rel) begin
                // busy (DAT0 low) follows the token; wait for the release
                if (dat[0] == 1'b1) begin
                  busy_rel <= 1'b1;
                  wait_cnt <= 6'd0;
                end else if (wait_cnt == TO_MAX) `SD_FAIL_DATA(err_timeout)
                else wait_cnt <= wait_cnt + 6'd1;
              end else begin         // inter-transaction gap after busy
                wait_cnt <= wait_cnt + 6'd1;
                if (wait_cnt == 6'd5) `SD_ISSUE(C17, blk_arg(ccs, round[1:0]))
              end
            end
          endcase
        end

        // ------------------------------------------------------------------
        // read data block: wait start(0000), 64 nibbles + 4xCRC16 check,
        // end(1111); mismatch on any line CRC16 discards the block
        // ------------------------------------------------------------------
        default: begin             // H_RDAT
          case (dphase)
            DP_START: begin        // wait for data start bits
              if (dat == 4'b0000) begin
                dphase  <= DP_DATA;
                bit_cnt <= {1'b0, NIB_CNT};
              end else if (wait_cnt == TO_MAX) `SD_FAIL_DATA(err_timeout)
              else wait_cnt <= wait_cnt + 6'd1;
            end
            DP_DATA: begin
              dat_sh <= {dat_sh[251:0], dat};
              crc0   <= crc16_step(crc0, dat[0]);
              crc1   <= crc16_step(crc1, dat[1]);
              crc2   <= crc16_step(crc2, dat[2]);
              crc3   <= crc16_step(crc3, dat[3]);
              if (bit_cnt == 8'd1) begin
                bit_cnt <= 8'd16;
                dphase  <= DP_CRC;
              end else begin
                bit_cnt <= bit_cnt - 8'd1;
              end
            end
            DP_CRC: begin
              crx0 <= {crx0[14:0], dat[0]};
              crx1 <= {crx1[14:0], dat[1]};
              crx2 <= {crx2[14:0], dat[2]};
              crx3 <= {crx3[14:0], dat[3]};
              if (bit_cnt == 8'd1) dphase <= DP_END;
              else                 bit_cnt <= bit_cnt - 8'd1;
            end
            default: begin         // DP_END
              if (dat == 4'hF && crx0 == crc0 && crx1 == crc1 &&
                  crx2 == crc2 && crx3 == crc3) begin
                if (dat_sh == exp_blk(round))    // read-back compare OK
                  `SD_ISSUE(C13, {rca, 16'h0})
                else `SD_FAIL_DATA(err_cmp)
              end else `SD_FAIL_DATA(err_crc16)       // bad CRC16/end: discard
            end
          endcase
        end
      endcase
    end
  end

  `undef SD_ISSUE
  `undef SD_FAIL_INIT
  `undef SD_FAIL_DATA

endmodule
