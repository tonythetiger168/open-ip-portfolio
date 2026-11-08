// SPDX-License-Identifier: Apache-2.0
// ============================================================================
// eMMC protocol Open IP -- eMMC host: hardware reset (RST_n), CMD0/CMD1/
// CMD2/CMD3/CMD7 init sequence, CMD24/CMD17 single-block read/write in
// 1-bit DAT mode, CRC7/CRC16 checking -- Apache-2.0
// Open IP design implementation v3.0
// ----------------------------------------------------------------------------
// Bus timing:
//  - The host drives the device: emmc_clk (CLK) is generated from clk by an
//    even divider, ID_CLK_DIV during identification (CMD0 .. CMD3, which
//    JESD84 limits to 400 kHz: the default 128 meets that for clk up to
//    51.2 MHz) and CLK_DIV from CMD7 on. CMD / DAT0 are sampled on the CLK
//    rising edge and change on the falling edge.
//  - emmc_rst_n is the device's RST_n, an output: after rst_n it is held
//    low RST_LOW clk cycles (tRSTW), then high RST_WAIT clk cycles (tRSCA)
//    before the host gives the 74 CLK cycles of the power-up sequence and
//    sends CMD0.
//  - The response start bit is looked for from N_CR = 2 up to 64 clocks;
//    the CRC status token within 64 clocks. Read access (data start bit)
//    and write busy have their own limits, RD_TIMEOUT and BUSY_TIMEOUT
//    CLK cycles (defaults 100 ms and 250 ms at 26 MHz).
//  - CMD3 assigns RCA 1; CMD7 then selects the device (stand-by to
//    transfer state) before any CMD24 / CMD17. CMD7's R1b busy on DAT0 is
//    waited out in the idle gap (BUSY_TIMEOUT).
// Documented simplifications (SPEC section 2.5):
//  - Block length is 32 bytes (256 bits) instead of the eMMC-native 512 bytes.
//  - 1-bit bus mode only: host drives/samples dat[0]; dat[7:1] stay high-Z.
//  - The host autonomously repeats demo rounds: CMD24 write of an internal
//    pattern block, then CMD17 read of the same block with read-back compare.
//    Round n uses block address n[1:0]. Status is observable via internal
//    state (TB hierarchical reference) and irq pulses.
//  - Response checks: R1 (CMD3/24/17) start + transmission bits, command
//    index, CRC7, end bit and the card-status error bits (ERR_MASK); R3
//    framing (start, transmission, reserved 111111 fields, end bit); R2
//    framing (start, transmission, 111111) and the CID's own CRC7 with
//    CID[0] = 1. A failed check raises irq: framing / CRC -> err_crc7,
//    status bits -> err_status.
//  - Write: after the end bit the card returns the CRC status token
//    (0, 3 status bits, 1); 010 = accepted, anything else -> err_crc16.
//    The host then waits for the card to release DAT0 busy.
// ============================================================================
module eMMC_top #(
  parameter int CLK_DIV      = 2,        // clk cycles per CLK period (even, >= 2)
  parameter int ID_CLK_DIV   = 128,      // the same during identification
  parameter int RST_LOW      = 64,       // clk cycles RST_n is held low
  parameter int RST_WAIT     = 16384,    // clk cycles from RST_n high to the 74 clocks
  parameter int RD_TIMEOUT   = 2600000,  // read access limit (CLK cycles)
  parameter int BUSY_TIMEOUT = 6500000   // write / R1b busy limit (CLK cycles)
)(
  input  logic       clk,
  input  logic       rst_n,
  output logic       emmc_clk,
  inout  logic       cmd,
  inout  logic [7:0] dat,
  output logic       emmc_rst_n,
  output logic       irq
);

  // ------------------------- constants -------------------------
  localparam logic [8:0] BLK_CNT = 9'd256;     // block bit count, sized
  localparam logic [5:0] TO_MAX  = 6'd63;      // response / token limit (64 clocks)
  localparam logic [31:0] OCR_ARG = 32'h40FF_8080; // CMD1 OCR (3.3V range)
  localparam logic [31:0] RCA_ARG = 32'h0001_0000; // CMD3: RCA = 1
  // R1 card-status error bits: OUT_OF_RANGE, ADDRESS_MISALIGN, BLOCK_LEN,
  // ERASE_SEQ, ERASE_PARAM, WP_VIOLATION, LOCK_UNLOCK_FAILED, COM_CRC,
  // ILLEGAL_COMMAND, CARD_ECC, CC_ERROR, ERROR, CID/CSD_OVERWRITE,
  // WP_ERASE_SKIP, SWITCH_ERROR
  localparam logic [31:0] ERR_MASK = 32'hFDF9_8080;

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
    body = {2'b01, idx, arg};                  // start, transmission bit
    cmd_frame = {body, crc7_40(body), 1'b1};
  endfunction

  // Demo payload pattern: word i of round r (MSB of block shifted out first)
  function automatic logic [31:0] pat_word(input logic [7:0] r,
                                           input logic [7:0] i);
    pat_word = 32'hA500_3C00 ^ {24'h0, r} ^ ({24'h0, i} * 32'h0001_0101);
  endfunction

  // ------------------------- state types -------------------------
  // host activity; which command is in flight is held separately in cur
  typedef enum logic [2:0] {
    H_CTX  = 3'd0,   // shift a 48-bit command frame out on CMD
    H_GAP  = 3'd1,   // CMD released: gap before the response (or next command)
    H_RSP  = 3'd2,   // hunt for the response start bit, then shift it in
    H_IDLE = 3'd3,   // between demo rounds
    H_WDAT = 3'd4,   // write data block on dat[0], CRC status, busy
    H_RDAT = 3'd5,   // read data block on dat[0]
    H_PWR  = 3'd6    // RST_n pulse, tRSCA wait, 74 clocks before CMD0
  } hstate_t;

  // command in flight
  localparam logic [2:0] C0 = 3'd0, C1 = 3'd1, C2 = 3'd2, C3 = 3'd3, C24 = 3'd4, C17 = 3'd5,
                         C7 = 3'd6;
  function automatic logic [5:0] cmd_idx(input logic [2:0] c);
    case (c)
      C1:      cmd_idx = 6'd1;
      C2:      cmd_idx = 6'd2;
      C3:      cmd_idx = 6'd3;
      C7:      cmd_idx = 6'd7;
      C24:     cmd_idx = 6'd24;
      C17:     cmd_idx = 6'd17;
      default: cmd_idx = 6'd0;
    endcase
  endfunction

  localparam logic [2:0] DP_START  = 3'd0,   // write: start bit / read: wait start
                         DP_DATA   = 3'd1,   // 256 data bits
                         DP_CRC    = 3'd2,   // 16 CRC bits
                         DP_END    = 3'd3,   // end bit
                         DP_TOK    = 3'd4,   // write: CRC status token
                         DP_BUSY   = 3'd5;   // write: wait busy release

  // ------------------------- registers -------------------------
  hstate_t      state;
  logic [2:0]   cur;            // command in flight (C0..C17)
  logic [2:0]   dphase;         // data sub-phase
  logic [8:0]   bit_cnt;
  logic [5:0]   wait_cnt;
  logic [47:0]  cmd_sh;
  logic [134:0] rsp_sh;
  logic         cmd_oe_r, cmd_out_r;
  logic         dat0_oe_r, dat0_out_r;
  logic [255:0] dat_sh;         // TX shift / RX assemble buffer
  logic [15:0]  crc16, crc_rx;
  logic         busy_rel;       // write busy release observed
  logic [7:0]   round;
  logic [7:0]   match_cnt;      // successful read-back compares
  logic [127:0] cid;
  logic         init_done;
  logic         err_crc7, err_crc16, err_timeout, err_cmp, err_status;
  logic [2:0]   tok;            // CRC status token bits received so far
  logic         fast;           // RCA assigned: transfer clock rate
  logic [1:0]   pwr;            // H_PWR step: 0 RST_n low, 1 tRSCA, 2 74 clocks
  // long timers: power-up steps (clk cycles), read access and busy (CLK)
  localparam int LT_MAX = (RST_WAIT > RD_TIMEOUT) ?
                          ((RST_WAIT > BUSY_TIMEOUT) ? RST_WAIT : BUSY_TIMEOUT) :
                          ((RD_TIMEOUT > BUSY_TIMEOUT) ? RD_TIMEOUT : BUSY_TIMEOUT);
  localparam int LTW = $clog2(LT_MAX + 1);
  logic [LTW-1:0] lt_cnt;

  // ------------------------- CLK divider -------------------------
  // CLK = clk / ID_CLK_DIV until the RCA is assigned, clk / CLK_DIV after;
  // "tick" is the clk edge where CLK rises (the host samples CMD / DAT0 and
  // steps its FSM), "ftick" the one where it falls. The rate changes only
  // at a tick, so every CLK period is whole.
  localparam int MDIV  = (CLK_DIV > ID_CLK_DIV) ? CLK_DIV : ID_CLK_DIV;
  localparam int DIV_W = (MDIV <= 2) ? 1 : $clog2(MDIV);
  logic [DIV_W-1:0] div_cnt;
  // (compared per rate, so no constant-bit divider net is left for toggle coverage)
  wire tick  = fast ? div_cnt == DIV_W'(CLK_DIV-1)   : div_cnt == DIV_W'(ID_CLK_DIV-1);
  wire ftick = fast ? div_cnt == DIV_W'(CLK_DIV/2-1) : div_cnt == DIV_W'(ID_CLK_DIV/2-1);

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      div_cnt  <= '0;
      emmc_clk <= 1'b0;
    end else if (tick) begin
      div_cnt  <= '0;
      emmc_clk <= 1'b1;
    end else begin
      div_cnt <= div_cnt + DIV_W'(1);
      if (ftick) emmc_clk <= 1'b0;
    end
  end

  // ------------------------- bus drivers -------------------------
  // the FSM sets the next CMD / DAT0 value at a tick; the pins take it at
  // the following falling edge, half a period before the device samples it
  logic cmd_oe_p, cmd_out_p, dat0_oe_p, dat0_out_p;
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      cmd_oe_p <= 1'b0; cmd_out_p <= 1'b1; dat0_oe_p <= 1'b0; dat0_out_p <= 1'b1;
    end else if (ftick) begin
      cmd_oe_p  <= cmd_oe_r;  cmd_out_p  <= cmd_out_r;
      dat0_oe_p <= dat0_oe_r; dat0_out_p <= dat0_out_r;
    end
  end
  assign cmd      = cmd_oe_p  ? cmd_out_p  : 1'bz;
  assign dat[0]   = dat0_oe_p ? dat0_out_p : 1'bz;
  assign dat[7:1] = 7'bzzzzzzz;           // 1-bit mode: upper lines high-Z

  // expected payload of a round (write source / read reference)
  function automatic logic [255:0] exp_blk(input logic [7:0] r);
    for (int i = 0; i < 8; i++)          // constant bound
      exp_blk[255 - i*32 -: 32] = pat_word(r, i[7:0]);
  endfunction

  // next response-shift value and response checks (combinational)
  logic [135:0] rsp_nxt;
  always_comb rsp_nxt = {rsp_sh[134:0], cmd};

  // the CID and the sticky error flags are status registers read
  // hierarchically (no register port)
  wire          _unused = &{1'b0, cid, err_crc7, err_crc16, err_timeout,
                            err_cmp, err_status, rsp_nxt[135]};
  // R1: frame / CRC check (r1_ok) and card-status error bits (r1_err)
  logic r1_ok, r1_err, r2_ok, r3_ok;
  always_comb begin
    r1_ok  = (rsp_nxt[46] == 1'b0) && (rsp_nxt[45:40] == cmd_idx(cur)) &&
             (rsp_nxt[0] == 1'b1) && (crc7_40(rsp_nxt[47:8]) == rsp_nxt[7:1]);
    r1_err = (rsp_nxt[39:8] & ERR_MASK) != 32'h0;
    r3_ok  = (rsp_nxt[46] == 1'b0) && (rsp_nxt[45:40] == 6'h3F) &&
             (rsp_nxt[7:0] == 8'hFF);
    r2_ok  = (rsp_nxt[134] == 1'b0) && (rsp_nxt[133:128] == 6'h3F) &&
             (cid_crc(rsp_nxt[127:8]) == rsp_nxt[7:1]) && rsp_nxt[0];
  end
  // last response bit index: R2 is 136 bits, the others 48
  wire last_rsp_bit = (cur == C2) ? (bit_cnt == 9'd135) : (bit_cnt == 9'd47);

  // ------------------------- macros (kept local) -------------------------
  // issue a 48-bit command frame
  `define EMMC_ISSUE(C, ARG) \
    begin \
      state    <= H_CTX; \
      cur      <= C; \
      cmd_sh   <= cmd_frame(cmd_idx(C), ARG); \
      bit_cnt  <= 9'd48; \
      cmd_oe_r <= 1'b1; \
      wait_cnt <= 6'd0; \
    end

  // raise error: sticky flag + 1-cycle irq pulse. During init the host
  // restarts with CMD0; data-phase errors return to H_IDLE, which restarts
  // the current round
  `define EMMC_FAIL_INIT(ERRF) \
    begin ERRF <= 1'b1; irq <= 1'b1; fast <= 1'b0; `EMMC_ISSUE(C0, 32'h0000_0000) end
  `define EMMC_FAIL_DATA(ERRF) \
    begin ERRF <= 1'b1; irq <= 1'b1; state <= H_IDLE; wait_cnt <= 6'd0; lt_cnt <= '0; end

  // ------------------------- main FSM -------------------------
  // RST_n (device hardware reset), driven by the power-up sequence
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n)                                  emmc_rst_n <= 1'b0;
    else if (state == H_PWR && pwr == 2'd0 &&
             lt_cnt == LTW'(RST_LOW - 1))        emmc_rst_n <= 1'b1;
  end

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      state      <= H_PWR;
      pwr        <= 2'd0;
      lt_cnt     <= '0;
      fast       <= 1'b0;
      cur        <= C0;
      dphase     <= DP_START;
      bit_cnt    <= 9'd48;
      wait_cnt   <= 6'd0;
      cmd_sh     <= cmd_frame(6'd0, 32'h0000_0000);
      rsp_sh     <= '0;
      cmd_oe_r   <= 1'b0;          // CMD released until the power-up is done
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
      err_status <= 1'b0;
      tok        <= 3'h0;
      irq        <= 1'b0;
    end else begin
      irq <= 1'b0;                   // default: single-clock pulse
      if (state == H_PWR && pwr != 2'd2) begin
        // RST_n low for RST_LOW clk cycles, then RST_WAIT clk cycles (tRSCA)
        if (pwr == 2'd0 && lt_cnt == LTW'(RST_LOW - 1) ||
            pwr == 2'd1 && lt_cnt == LTW'(RST_WAIT - 1)) begin
          pwr    <= pwr + 2'd1;
          lt_cnt <= '0;
        end else lt_cnt <= lt_cnt + LTW'(1);
      end else if (tick) begin
        case (state)
          // ------------------------------------------------------------------
          // power-up: 74 CLK cycles with CMD high, then CMD0
          // ------------------------------------------------------------------
          H_PWR: begin
            lt_cnt <= lt_cnt + LTW'(1);
            if (lt_cnt == LTW'(73)) `EMMC_ISSUE(C0, 32'h0000_0000)
          end

          // ------------------------------------------------------------------
          // command frame out, MSB first
          // ------------------------------------------------------------------
          H_CTX: begin
            cmd_out_r <= cmd_sh[47];
            cmd_sh    <= {cmd_sh[46:0], 1'b0};
            if (bit_cnt == 9'd1) begin
              state    <= H_GAP;
              wait_cnt <= 6'd0;
            end else begin
              bit_cnt <= bit_cnt - 9'd1;
            end
          end

          // release CMD; CMD0 has no response: CMD1 follows after 8 bits.
          // Otherwise hunt for the start bit from the next clock on, so a
          // response at N_CR = 2 is seen
          H_GAP: begin
            cmd_oe_r <= 1'b0;
            wait_cnt <= wait_cnt + 6'd1;
            if (cur == C0) begin
              if (wait_cnt == 6'd7) `EMMC_ISSUE(C1, OCR_ARG)
            end else begin
              state    <= H_RSP;
              wait_cnt <= 6'd0;
              bit_cnt  <= 9'd0;
            end
          end

          // ------------------------------------------------------------------
          // response: hunt the start bit (64-bit timeout), shift, judge
          // ------------------------------------------------------------------
          H_RSP: begin
            if (bit_cnt == 9'd0) begin
              if (cmd == 1'b0) begin
                rsp_sh  <= '0;              // the start bit
                bit_cnt <= 9'd1;
              end else if (wait_cnt == TO_MAX) begin
                if (init_done) `EMMC_FAIL_DATA(err_timeout)
                else           `EMMC_FAIL_INIT(err_timeout)
              end else begin
                wait_cnt <= wait_cnt + 6'd1;
              end
            end else begin
              rsp_sh  <= rsp_nxt[134:0];
              bit_cnt <= bit_cnt + 9'd1;
              if (last_rsp_bit) begin
                case (cur)
                  C1:                       // R3: OCR, no CRC
                    if (!r3_ok)          `EMMC_FAIL_INIT(err_crc7)
                    else if (rsp_nxt[39]) `EMMC_ISSUE(C2, 32'h0000_0000)  // ready
                    else                 `EMMC_ISSUE(C1, OCR_ARG)          // busy: poll
                  C2:                       // R2: CID[127:1] + end bit
                    if (!r2_ok) `EMMC_FAIL_INIT(err_crc7)
                    else begin
                      cid <= rsp_nxt[127:0];
                      `EMMC_ISSUE(C3, RCA_ARG)
                    end
                  C3:                       // R1 after SET_RCA: select it
                    if (!r1_ok)      `EMMC_FAIL_INIT(err_crc7)
                    else if (r1_err) `EMMC_FAIL_INIT(err_status)
                    else begin
                      fast <= 1'b1;         // identification done: full rate
                      `EMMC_ISSUE(C7, RCA_ARG)
                    end
                  C7:                       // R1b after SELECT_CARD
                    if (!r1_ok)      `EMMC_FAIL_INIT(err_crc7)
                    else if (r1_err) `EMMC_FAIL_INIT(err_status)
                    else begin
                      init_done <= 1'b1;
                      state     <= H_IDLE;
                      wait_cnt  <= 6'd0;
                      lt_cnt    <= '0;
                    end
                  C24:                      // R1 after CMD24: send the block
                    if (!r1_ok)      `EMMC_FAIL_DATA(err_crc7)
                    else if (r1_err) `EMMC_FAIL_DATA(err_status)
                    else begin
                      state     <= H_WDAT;
                      dphase    <= DP_START;
                      dat0_oe_r <= 1'b1;   // drives idle '1' first
                      crc16     <= 16'h0000;
                      bit_cnt   <= BLK_CNT;
                      dat_sh    <= exp_blk(round);
                    end
                  default:                  // C17: R1 after CMD17
                    if (!r1_ok)      `EMMC_FAIL_DATA(err_crc7)
                    else if (r1_err) `EMMC_FAIL_DATA(err_status)
                    else begin
                      state    <= H_RDAT;
                      dphase   <= DP_START;
                      crc16    <= 16'h0000;
                      crc_rx   <= 16'h0000;
                      lt_cnt   <= '0;
                    end
                endcase
              end
            end
          end

          // ------------------------------------------------------------------
          // idle gap between demo rounds (DAT0 high for 8 clocks: an R1b busy
          // is waited out, up to BUSY_TIMEOUT), then CMD24 for this round
          // ------------------------------------------------------------------
          H_IDLE: begin
            if (dat[0] == 1'b0) begin
              wait_cnt <= 6'd0;
              if (lt_cnt == LTW'(BUSY_TIMEOUT - 1)) begin
                err_timeout <= 1'b1; irq <= 1'b1; lt_cnt <= '0;
              end else lt_cnt <= lt_cnt + LTW'(1);
            end else begin
              lt_cnt   <= '0;
              wait_cnt <= wait_cnt + 6'd1;
              if (wait_cnt == 6'd7) `EMMC_ISSUE(C24, {30'h0, round[1:0]})
            end
          end

          // ------------------------------------------------------------------
          // write data block on dat[0]: start(0) + 256b + CRC16 + end(1),
          // then the card's CRC status token and busy
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
                if (bit_cnt == 9'd1) dphase <= DP_END;
                else                 bit_cnt <= bit_cnt - 9'd1;
              end
              DP_END: begin
                dat0_out_r <= 1'b1;    // end bit
                dphase     <= DP_TOK;
                wait_cnt   <= 6'd0;
                lt_cnt     <= '0;
                bit_cnt    <= 9'd0;
                busy_rel   <= 1'b0;
              end
              DP_TOK: begin            // CRC status token: 0, s2 s1 s0, 1
                dat0_oe_r <= 1'b0;     // release DAT0 to the card
                if (bit_cnt == 9'd0) begin
                  if (dat[0] == 1'b0) bit_cnt <= 9'd1;
                  else if (wait_cnt == TO_MAX) `EMMC_FAIL_DATA(err_timeout)
                  else wait_cnt <= wait_cnt + 6'd1;
                end else begin
                  tok     <= {tok[1:0], dat[0]};
                  bit_cnt <= bit_cnt + 9'd1;
                  if (bit_cnt == 9'd4) begin
                    if ({tok, dat[0]} == 4'b0101) begin
                      dphase   <= DP_BUSY;     // accepted: wait for busy release
                      wait_cnt <= 6'd0;
                    end else `EMMC_FAIL_DATA(err_crc16)
                  end
                end
              end
              default: begin           // DP_BUSY
                if (!busy_rel) begin
                  // busy (DAT0 low) follows the token; wait for the release
                  if (dat[0] == 1'b1) begin
                    busy_rel <= 1'b1;
                    wait_cnt <= 6'd0;
                  end else if (lt_cnt == LTW'(BUSY_TIMEOUT - 1)) `EMMC_FAIL_DATA(err_timeout)
                  else lt_cnt <= lt_cnt + LTW'(1);
                end else begin         // inter-transaction gap after busy
                  wait_cnt <= wait_cnt + 6'd1;
                  if (wait_cnt == 6'd5) `EMMC_ISSUE(C17, {30'h0, round[1:0]})
                end
              end
            endcase
          end

          // ------------------------------------------------------------------
          // read data block on dat[0]: wait start, 256b + CRC16 check + end(1)
          // ------------------------------------------------------------------
          default: begin             // H_RDAT
            case (dphase)
              DP_START: begin        // wait for data start bit
                if (dat[0] == 1'b0) begin
                  dphase  <= DP_DATA;
                  bit_cnt <= BLK_CNT;
                end else if (lt_cnt == LTW'(RD_TIMEOUT - 1)) `EMMC_FAIL_DATA(err_timeout)
                else lt_cnt <= lt_cnt + LTW'(1);
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
                if (bit_cnt == 9'd1) dphase <= DP_END;
                else                 bit_cnt <= bit_cnt - 9'd1;
              end
              default: begin         // DP_END
                if (dat[0] == 1'b1 && crc_rx == crc16) begin
                  if (dat_sh == exp_blk(round)) begin
                    match_cnt <= match_cnt + 8'd1;   // read-back compare OK
                    round     <= round + 8'd1;
                    state     <= H_IDLE;
                    wait_cnt  <= 6'd0;
                  end else `EMMC_FAIL_DATA(err_cmp)
                end else `EMMC_FAIL_DATA(err_crc16)  // bad CRC16/end: discard
              end
            endcase
          end
        endcase
      end
    end
  end

  `undef EMMC_ISSUE
  `undef EMMC_FAIL_INIT
  `undef EMMC_FAIL_DATA

endmodule
