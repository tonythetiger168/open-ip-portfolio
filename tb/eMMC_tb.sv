// SPDX-License-Identifier: Apache-2.0
// ============================================================================
// Self-checking testbench for eMMC_top -- SystemVerilog
// eMMC card model (CMD/DAT responder) + CRC16/CRC7 error injection + mute
// (command timeout) scenario. DUT is the host; this TB is the card.
// Bus convention (both sides, race-free): drivers update on posedge emmc_clk
// via nonblocking assignments, receivers sample on posedge emmc_clk, so every
// transferred bit is seen exactly one cycle after it is driven.
// ============================================================================
`timescale 1ns/1ps
module eMMC_tb;

  // ------------------------- clocks / resets / bus -------------------------
  logic clk = 1'b0, rst_n = 1'b0;
  logic emmc_clk = 1'b0;
  logic emmc_rst_n = 1'b0;
  tri   cmd;
  tri [7:0] dat;
  logic irq;
  int   errors = 0;

  eMMC_top dut (
    .clk(clk), .rst_n(rst_n), .emmc_clk(emmc_clk),
    .cmd(cmd), .dat(dat), .emmc_rst_n(emmc_rst_n), .irq(irq)
  );

  always #5  clk      = ~clk;        // 100 MHz system clock (DUT-reserved)
  always #7  emmc_clk = ~emmc_clk;   // ~71 MHz bus clock: all DUT logic

  // DUT state encodings (mirror rtl/eMMC_top.sv for hierarchical checks)
  localparam logic [3:0] H_CMD0 = 4'd0, H_IDLE = 4'd4;

  // card identity
  localparam logic [127:0] CID_VAL = 128'h0123_4567_89AB_CDEF_FEDC_BA98_7654_3211;
  localparam logic [31:0]  R1_ST   = 32'h0000_0900; // card status in R1

  // ------------------------- card-model knobs (main process only) ---------
  logic busy_ready = 1'b0;  // OCR busy bit: 0 = card still busy
  logic mute       = 1'b0;  // 1 = never respond (command timeout test)
  logic inj_crc16  = 1'b0;  // 1 = corrupt CRC16 of next read data block
  logic inj_crc7   = 1'b0;  // 1 = corrupt CRC7 of next R1 response

  // ------------------------- card drive signals ---------------------------
  logic c_cmd_oe = 1'b0, c_cmd_out = 1'b1;
  logic c_dat_oe = 1'b0, c_dat_out = 1'b1;
  assign cmd     = c_cmd_oe ? c_cmd_out : 1'bz;
  assign dat[0]  = c_dat_oe ? c_dat_out : 1'bz;
  assign dat[7:1] = 7'bzzzzzzz;               // 1-bit mode

  logic [255:0] card_blk [0:3];               // card storage: 4 x 32-byte blocks
  int cmd1_cnt         = 0;
  int card_cmdcrc_errs = 0;
  int card_datcrc_errs = 0;
  int irq_cnt          = 0;
  int irq_before       = 0;
  int twait            = 0;

  always @(posedge irq) irq_cnt = irq_cnt + 1;

  // ------------------------- TB CRC helpers -------------------------------
  function automatic logic [6:0] crc7_40(input logic [39:0] d);
    logic [6:0] c;
    logic       fb;
    c = 7'h00;
    for (int i = 39; i >= 0; i--) begin
      fb = d[i] ^ c[6];
      c  = {c[5:0], 1'b0};
      if (fb) c = c ^ 7'h09;
    end
    crc7_40 = c;
  endfunction

  function automatic logic [15:0] crc16_blk(input logic [255:0] d);
    logic [15:0] c;
    logic        fb;
    c = 16'h0000;
    for (int i = 255; i >= 0; i--) begin
      fb = d[i] ^ c[15];
      c  = {c[14:0], 1'b0};
      if (fb) c = c ^ 16'h1021;
    end
    crc16_blk = c;
  endfunction

  // expected payload of round r (must match DUT pat_word)
  function automatic logic [255:0] exp_blk_tb(input logic [7:0] r);
    for (int i = 0; i < 8; i++)
      exp_blk_tb[255 - i*32 -: 32] =
        32'hA500_3C00 ^ {24'h0, r} ^ ({24'h0, i[7:0]} * 32'h0001_0101);
  endfunction

  // ------------------------- card model FSM -------------------------------
  localparam logic [2:0] C_IDLE   = 3'd0,
                         C_CMDRX  = 3'd1,
                         C_GAP    = 3'd2,
                         C_RSPTX  = 3'd3,
                         C_DRX    = 3'd4,
                         C_BUSY   = 3'd5,
                         C_DTXGAP = 3'd6,
                         C_DTX    = 3'd7;

  logic [2:0]   cstate   = C_IDLE;
  logic [47:0]  cframe   = 48'h0;
  logic [8:0]   ccnt     = 9'd0;
  logic [135:0] crsp     = 136'h0;
  logic [7:0]   crsp_len = 8'd0;
  logic [3:0]   cgap     = 4'd0;
  logic [1:0]   cblk     = 2'd0;
  logic [1:0]   post_act = 2'd0;   // 0 none / 1 receive write data / 2 send read data
  logic [8:0]   drx_cnt  = 9'd0;
  logic [8:0]   drx_to   = 9'd0;   // write-data start timeout (host may abort)
  logic [15:0]  drx_crc  = 16'h0;
  logic [255:0] dtx_sh   = 256'h0;
  logic [15:0]  dtx_crc  = 16'h0;
  logic [8:0]   dtx_cnt  = 9'd0;
  logic [3:0]   busy_cnt = 4'd0;

  logic [47:0]  f;        // assembled command frame (scratch)
  logic [39:0]  r1body;   // R1 body for CRC7 (scratch)
  logic [6:0]   r1crc;

  always @(posedge emmc_clk) begin
    case (cstate)
      // -------------------- wait for command start bit --------------------
      C_IDLE: begin
        if (cmd === 1'b0) begin
          cframe <= {47'h0, 1'b0};
          ccnt   <= 9'd1;
          cstate <= C_CMDRX;
        end
      end

      // -------------------- shift in remaining 47 bits --------------------
      C_CMDRX: begin
        cframe <= {cframe[46:0], cmd};
        if (ccnt == 9'd47) begin
          ccnt <= 9'd0;
          f = {cframe[46:0], cmd};
          if (crc7_40(f[46:8]) !== f[7:1]) begin
            card_cmdcrc_errs = card_cmdcrc_errs + 1;   // bad host CRC: ignore
            cstate <= C_IDLE;
          end else if (mute) begin
            cstate <= C_IDLE;                          // muted: no response
          end else begin
            case (f[45:40])
              6'd0: begin                              // CMD0 GO_IDLE: no rsp
                cstate <= C_IDLE;
              end
              6'd1: begin                              // CMD1: R3 (OCR)
                crsp     <= {{1'b0, 1'b0, 6'b111111,
                              (busy_ready ? 32'hC0FF_8080 : 32'h40FF_8080),
                              7'h7F, 1'b1}, 88'h0};
                crsp_len <= 8'd48;
                cgap     <= 4'd3;
                post_act <= 2'd0;
                cstate   <= C_GAP;
                cmd1_cnt = cmd1_cnt + 1;
                busy_ready <= 1'b1;                    // ready after 1st poll
              end
              6'd2: begin                              // CMD2: R2 (CID)
                crsp     <= {1'b0, 1'b0, 6'b111111, CID_VAL[127:1], 1'b1};
                crsp_len <= 8'd136;
                cgap     <= 4'd3;
                post_act <= 2'd0;
                cstate   <= C_GAP;
              end
              6'd3, 6'd24, 6'd17: begin                // R1 responses
                r1body = {1'b0, f[45:40], R1_ST};
                r1crc  = crc7_40(r1body);
                if (inj_crc7) r1crc = r1crc ^ 7'h55;
                crsp     <= {{1'b0, r1body, r1crc, 1'b1}, 88'h0};
                crsp_len <= 8'd48;
                cgap     <= 4'd3;
                cstate   <= C_GAP;
                if (f[45:40] == 6'd24) begin           // CMD24: then RX data
                  cblk     <= f[9:8];
                  post_act <= 2'd1;
                end else if (f[45:40] == 6'd17) begin  // CMD17: then TX data
                  cblk     <= f[9:8];
                  post_act <= 2'd2;
                end else begin
                  post_act <= 2'd0;
                end
              end
              default: cstate <= C_IDLE;               // unknown: no response
            endcase
          end
        end else begin
          ccnt <= ccnt + 9'd1;
        end
      end

      // -------------------- inter-frame gap before response ---------------
      C_GAP: begin
        if (cgap <= 4'd1) begin
          c_cmd_oe <= 1'b1;                            // drives idle '1' first
          ccnt     <= {1'b0, crsp_len};
          cstate   <= C_RSPTX;
        end else begin
          cgap <= cgap - 4'd1;
        end
      end

      // -------------------- shift response out, MSB first -----------------
      C_RSPTX: begin
        if (ccnt > 9'd0) begin
          c_cmd_out <= crsp[135];
          crsp      <= {crsp[134:0], 1'b1};
          ccnt      <= ccnt - 9'd1;
        end else begin
          c_cmd_oe <= 1'b0;
          case (post_act)
            2'd1: begin cstate <= C_DRX;    drx_cnt <= 9'd0; post_act <= 2'd0; end
            2'd2: begin cstate <= C_DTXGAP; cgap    <= 4'd3; post_act <= 2'd0; end
            default: cstate <= C_IDLE;
          endcase
        end
      end

      // -------------------- receive write data block on dat[0] ------------
      C_DRX: begin
        if (drx_cnt == 9'd0) begin
          if (dat[0] === 1'b0) begin
            drx_cnt <= 9'd1;                           // start bit
            drx_to  <= 9'd0;
          end else if (drx_to >= 9'd150) begin         // host aborted write
            cstate <= C_IDLE;
            drx_to <= 9'd0;
          end else begin
            drx_to <= drx_to + 9'd1;
          end
        end else if (drx_cnt <= 9'd256) begin          // 256 data bits
          card_blk[cblk] <= {card_blk[cblk][254:0], dat[0]};
          drx_cnt <= drx_cnt + 9'd1;
        end else if (drx_cnt <= 9'd272) begin          // 16 CRC16 bits
          drx_crc <= {drx_crc[14:0], dat[0]};
          drx_cnt <= drx_cnt + 9'd1;
        end else begin                                 // end bit (drx_cnt==273)
          if (dat[0] !== 1'b1 ||
              drx_crc !== crc16_blk(card_blk[cblk]))
            card_datcrc_errs = card_datcrc_errs + 1;
          cstate   <= C_BUSY;                          // busy on dat[0]
          busy_cnt <= 4'd0;
          c_dat_oe <= 1'b1;
          c_dat_out <= 1'b0;
          drx_cnt  <= 9'd0;
        end
      end

      // -------------------- busy signalling after write -------------------
      C_BUSY: begin
        busy_cnt <= busy_cnt + 4'd1;
        if (busy_cnt < 4'd8) begin
          c_dat_oe  <= 1'b1;
          c_dat_out <= 1'b0;
        end else if (busy_cnt < 4'd11) begin
          c_dat_oe  <= 1'b1;
          c_dat_out <= 1'b1;                           // busy released
        end else begin
          c_dat_oe <= 1'b0;
          cstate   <= C_IDLE;
        end
      end

      // -------------------- prepare read data block -----------------------
      C_DTXGAP: begin
        if (cgap <= 4'd1) begin
          dtx_sh  <= card_blk[cblk];
          dtx_crc <= crc16_blk(card_blk[cblk]) ^
                     (inj_crc16 ? 16'hFFFF : 16'h0000);
          dtx_cnt <= 9'd274;                           // start+256+16+end
          cstate  <= C_DTX;
        end else begin
          cgap <= cgap - 4'd1;
        end
      end

      // -------------------- send read data block on dat[0] ----------------
      C_DTX: begin
        if (dtx_cnt > 9'd0) begin
          if (dtx_cnt == 9'd274) begin
            c_dat_oe  <= 1'b1;
            c_dat_out <= 1'b0;                         // start bit
          end else if (dtx_cnt >= 9'd18) begin         // 256 data bits
            c_dat_out <= dtx_sh[255];
            dtx_sh    <= {dtx_sh[254:0], 1'b0};
          end else if (dtx_cnt >= 9'd2) begin          // 16 CRC16 bits
            c_dat_out <= dtx_crc[15];
            dtx_crc   <= {dtx_crc[14:0], 1'b0};
          end else begin                               // dtx_cnt==1: end bit
            c_dat_out <= 1'b1;
          end
          dtx_cnt <= dtx_cnt - 9'd1;
        end else begin
          c_dat_oe <= 1'b0;
          cstate   <= C_IDLE;
        end
      end

      default: cstate <= C_IDLE;
    endcase
  end

  // ------------------------- wait helper ----------------------------------
  `define WAIT_FLAG(cond, what) \
    begin \
      twait = 0; \
      while (!(cond) && twait < 60000) begin \
        @(posedge emmc_clk); twait = twait + 1; \
      end \
      if (twait >= 60000) begin \
        $display("ERROR: timeout waiting for %s", what); \
        errors = errors + 1; \
      end \
    end

  // ------------------------- main stimulus --------------------------------
  initial begin
    for (int i = 0; i < 4; i++) card_blk[i] = 256'h0;

    // (a) reset and initial-state check
    rst_n = 1'b0; emmc_rst_n = 1'b0;
    repeat (6) @(posedge emmc_clk);
    rst_n = 1'b1; emmc_rst_n = 1'b1;
    repeat (2) @(posedge emmc_clk);
    if (dut.state !== H_CMD0) begin
      $display("ERROR: post-reset state=%0d, expected H_CMD0(0)", dut.state);
      errors = errors + 1;
    end
    if (irq !== 1'b0 || dut.init_done !== 1'b0 || dut.err_crc7 !== 1'b0 ||
        dut.err_crc16 !== 1'b0 || dut.err_timeout !== 1'b0 ||
        dut.match_cnt !== 8'd0) begin
      $display("ERROR: post-reset flags not clean");
      errors = errors + 1;
    end

    // (b) full init sequence: CMD0 -> CMD1(poll) -> CMD2 -> CMD3
    `WAIT_FLAG(dut.init_done === 1'b1, "init_done (CMD0..CMD3)")
    if (dut.init_done === 1'b1) begin
      if (dut.cid !== CID_VAL) begin
        $display("ERROR: CID got=%h exp=%h", dut.cid, CID_VAL);
        errors = errors + 1;
      end
      if (cmd1_cnt < 2) begin
        $display("ERROR: CMD1 issued %0d times, expected polling >=2", cmd1_cnt);
        errors = errors + 1;
      end
      if (irq_cnt != 0) begin
        $display("ERROR: irq during clean init");
        errors = errors + 1;
      end
    end

    // (c) round 0: CMD24 write 32 bytes + CMD17 read-back compare
    `WAIT_FLAG(dut.match_cnt >= 8'd1, "round0 write/read match")
    if (card_blk[0] !== exp_blk_tb(8'd0)) begin
      $display("ERROR: card block0 got=%h exp=%h", card_blk[0], exp_blk_tb(8'd0));
      errors = errors + 1;
    end
    if (dut.err_crc16 !== 1'b0 || dut.err_timeout !== 1'b0 ||
        dut.err_crc7 !== 1'b0 || dut.err_cmp !== 1'b0) begin
      $display("ERROR: unexpected error flag after clean round0");
      errors = errors + 1;
    end
    // card-side sanity on clean traffic: host CRC7/CRC16 always valid
    if (card_cmdcrc_errs != 0) begin
      $display("ERROR: card saw %0d host commands with bad CRC7", card_cmdcrc_errs);
      errors = errors + 1;
    end
    if (card_datcrc_errs != 0) begin
      $display("ERROR: card saw %0d write blocks with bad CRC16", card_datcrc_errs);
      errors = errors + 1;
    end

    // (d) error injection: card sends bad CRC16 on the round-1 read block
    irq_before = irq_cnt;
    inj_crc16  = 1'b1;
    `WAIT_FLAG(dut.err_crc16 === 1'b1, "host CRC16 error detect")
    inj_crc16  = 1'b0;
    if (irq_cnt <= irq_before) begin
      $display("ERROR: no irq pulse on bad CRC16 block");
      errors = errors + 1;
    end
    if (dut.match_cnt != 1) begin
      $display("ERROR: corrupt block accepted (match_cnt=%0d)", dut.match_cnt);
      errors = errors + 1;
    end
    // host must recover and complete the retried round
    `WAIT_FLAG(dut.match_cnt >= 8'd2, "round1 retry match")
    if (card_blk[1] !== exp_blk_tb(8'd1)) begin
      $display("ERROR: card block1 got=%h exp=%h", card_blk[1], exp_blk_tb(8'd1));
      errors = errors + 1;
    end

    // (e) error injection: card sends R1 with bad CRC7
    irq_before = irq_cnt;
    inj_crc7   = 1'b1;
    `WAIT_FLAG(dut.err_crc7 === 1'b1, "host CRC7 error detect")
    inj_crc7   = 1'b0;
    if (irq_cnt <= irq_before) begin
      $display("ERROR: no irq pulse on bad CRC7 response");
      errors = errors + 1;
    end
    `WAIT_FLAG(dut.match_cnt >= 8'd3, "round2 match after CRC7 error")

    // (f) command timeout: card stops responding entirely
    irq_before = irq_cnt;
    mute       = 1'b1;
    `WAIT_FLAG(dut.err_timeout === 1'b1 && irq_cnt > irq_before,
               "host command timeout detect")
    if (irq_cnt <= irq_before) begin
      $display("ERROR: no irq pulse on command timeout");
      errors = errors + 1;
    end
    // host must fall back to IDLE between retries (not stuck in wait)
    `WAIT_FLAG(dut.state === H_IDLE, "host returns to IDLE after timeout")
    mute = 1'b0;
    // link recovers: further back-to-back transactions complete
    `WAIT_FLAG(dut.match_cnt >= 8'd4, "recovery transaction after mute")
    if (dut.err_cmp !== 1'b0) begin
      $display("ERROR: read-back compare mismatch flag set");
      errors = errors + 1;
    end

    if (errors == 0) $display("TEST PASSED: eMMC");
    else             $display("TEST FAILED: %0d errors", errors);
    $finish;
  end

  // ------------------------- optional debug trace -------------------------
`ifdef EMMC_DEBUG
  logic [3:0] prev_state  = 4'hf;
  logic [2:0] prev_dphase = 3'h7;
  logic [2:0] prev_cstate = 3'h7;
  always @(posedge emmc_clk) begin
    if (dut.state != prev_state || dut.dphase != prev_dphase ||
        cstate != prev_cstate || irq) begin
      $display("t=%0t state=%0d ph=%0d dph=%0d bc=%0d wc=%0d card=%0d dtxc=%0d drxc=%0d mc=%0d rnd=%0d err=%b%b%b%b irqc=%0d",
               $time, dut.state, dut.phase, dut.dphase, dut.bit_cnt,
               dut.wait_cnt, cstate, dtx_cnt, drx_cnt, dut.match_cnt,
               dut.round, dut.err_crc7, dut.err_crc16, dut.err_timeout,
               dut.err_cmp, irq_cnt);
      prev_state  = dut.state;
      prev_dphase = dut.dphase;
      prev_cstate = cstate;
    end
  end
`endif

  // ------------------------- timeout guard --------------------------------
  initial begin
    #2_000_000;
    $display("TIMEOUT");
    $finish;
  end

endmodule
