// SPDX-License-Identifier: Apache-2.0
// ============================================================================
// Self-checking testbench for SD_top -- SystemVerilog
// SD card model (CMD/DAT responder, 4-bit bus) + R7 voltage-mismatch, CRC16,
// CRC7 and mute (command timeout) injection scenarios. DUT is the host.
// Bus convention (race-free): the host drives/samples on the sd_clk rising
// edge (its internal tick); this card model drives/samples on the falling
// edge of sd_clk, so every transferred bit is stable for half a cycle
// before it is sampled. CMD/DAT lines are tri1 (pull-up modelled).
// ============================================================================
`timescale 1ns/1ps
module SD_tb;

  // ------------------------- clocks / resets / bus -------------------------
  logic clk = 1'b0, rst_n = 1'b0;
  logic sd_clk;
  tri1  cmd;                       // CMD line with pull-up
  tri1 [3:0] dat;                  // DAT lines with pull-ups
  logic irq;
  int   errors = 0;

  SD_top dut (
    .clk(clk), .rst_n(rst_n), .sd_clk(sd_clk),
    .cmd(cmd), .dat(dat), .irq(irq)
  );

  always #5 clk = ~clk;            // 100 MHz system clock; sd_clk = clk/4

  // DUT state encodings (mirror rtl/SD_top.sv for hierarchical checks)
  localparam logic [3:0] H_CMD0 = 4'd0, H_IDLE = 4'd6;

  // card identity
  localparam logic [127:0] CID_VAL = 128'h0123_4567_89AB_CDEF_FEDC_BA98_7654_3211;
  localparam logic [15:0]  RCA_VAL = 16'h0001;
  localparam logic [31:0]  R1_ST   = 32'h0000_0900; // ready_for_data | tran
  localparam logic [31:0]  R1_APP  = R1_ST | 32'h20; // + APP_CMD bit

  // ------------------------- card-model knobs (main process only) ---------
  logic busy_ready = 1'b0;  // OCR busy bit: 0 = card still busy
  logic mute       = 1'b0;  // 1 = never respond (command timeout test)
  logic inj_crc16  = 1'b0;  // 1 = corrupt CRC16 of next read data block
  logic inj_crc7   = 1'b0;  // 1 = corrupt CRC7 of next R1 response
  logic bad_volt   = 1'b0;  // 1 = R7 with wrong voltage/pattern (auto-clears)

  // ------------------------- card drive signals ---------------------------
  logic       c_cmd_oe = 1'b0, c_cmd_out = 1'b1;
  logic [3:0] c_dat_oe = 4'b0000, c_dat_out = 4'hF;
  assign cmd = c_cmd_oe ? c_cmd_out : 1'bz;
  // per-bit drive: oe=1 drives c_dat_out, oe=0 leaves the line pulled up
  assign dat[0] = c_dat_oe[0] ? c_dat_out[0] : 1'bz;
  assign dat[1] = c_dat_oe[1] ? c_dat_out[1] : 1'bz;
  assign dat[2] = c_dat_oe[2] ? c_dat_out[2] : 1'bz;
  assign dat[3] = c_dat_oe[3] ? c_dat_out[3] : 1'bz;

  logic [255:0] card_blk [0:3];               // card storage: 4 x 32-byte blocks
  int cmd_log [0:255];                        // received command index log
  int cmd_log_n        = 0;
  int cmd8_cnt         = 0;
  int cmd41_cnt        = 0;
  int cmd55_cnt        = 0;
  int cmd13_cnt        = 0;
  int cmd8_arg_ok      = 0;                   // CMD8 arg was 0x1AA
  int cmd41_arg_ok     = 0;                   // ACMD41 arg HCS+voltage window
  int card_cmdcrc_errs = 0;
  int card_datcrc_errs = 0;
  int irq_cnt          = 0;
  int irq_before       = 0;
  int twait            = 0;
  int sdclk_cnt        = 0;

  always @(posedge irq) irq_cnt = irq_cnt + 1;
  always @(posedge sd_clk) sdclk_cnt = sdclk_cnt + 1;

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

  function automatic logic [15:0] crc16_step(input logic [15:0] c_in,
                                             input logic        b);
    logic fb;
    fb = b ^ c_in[15];
    crc16_step = {c_in[14:0], 1'b0} ^ (fb ? 16'h1021 : 16'h0000);
  endfunction

  // CRC16 of one DAT lane over a 256-bit block: nibble j occupies
  // blk[255-4j -: 4] with blk[255-4j] on DAT[3]; lane i bit j = blk[252-4j+i]
  function automatic logic [15:0] crc16_lane(input logic [255:0] d,
                                             input int          lane);
    logic [15:0] c;
    c = 16'h0000;
    for (int j = 0; j < 64; j++) c = crc16_step(c, d[252 - 4*j + lane]);
    crc16_lane = c;
  endfunction

  // expected payload of round r (must match DUT pat_word)
  function automatic logic [255:0] exp_blk_tb(input logic [7:0] r);
    for (int i = 0; i < 8; i++)
      exp_blk_tb[255 - i*32 -: 32] =
        32'hA500_3C00 ^ {24'h0, r} ^ ({24'h0, i[7:0]} * 32'h0001_0101);
  endfunction

  // ------------------------- card model FSM (negedge sd_clk) --------------
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
  logic [1:0]   post_act = 2'd0;   // 0 none / 1 receive write data / 2 send read
  logic [8:0]   drx_cnt  = 9'd0;
  logic [8:0]   drx_to   = 9'd0;   // write-data start timeout (host may abort)
  logic [15:0]  drx_crc0 = 16'h0, drx_crc1 = 16'h0,
                drx_crc2 = 16'h0, drx_crc3 = 16'h0;
  logic [15:0]  drx_crx0 = 16'h0, drx_crx1 = 16'h0,
                drx_crx2 = 16'h0, drx_crx3 = 16'h0;
  logic [255:0] dtx_sh   = 256'h0;
  logic [15:0]  dtx_crc0 = 16'h0, dtx_crc1 = 16'h0,
                dtx_crc2 = 16'h0, dtx_crc3 = 16'h0;
  logic [8:0]   dtx_cnt  = 9'd0;
  logic [3:0]   busy_cnt = 4'd0;

  logic [47:0]  f;        // assembled command frame (scratch)
  logic [39:0]  rbody;    // response body for CRC7 (scratch)
  logic [6:0]   rcrc;
  logic [31:0]  rarg;     // response argument (scratch)

  // build a 48-bit response frame placed at the top of the 136-bit shifter
  `define CARD_RSP48(IDXF, ARGF, CRCF) \
    crsp <= {{1'b0, 1'b0, IDXF, ARGF, CRCF, 1'b1}, 88'h0}

  always @(negedge sd_clk) begin
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
          end else begin
            cmd_log[cmd_log_n] = f[45:40];
            cmd_log_n = cmd_log_n + 1;
            if (mute) begin
              cstate <= C_IDLE;                        // muted: no response
            end else begin
              case (f[45:40])
                6'd0: begin                            // CMD0 GO_IDLE: no rsp
                  cstate <= C_IDLE;
                end
                6'd8: begin                            // CMD8: R7 echo
                  cmd8_cnt = cmd8_cnt + 1;
                  if (f[39:8] == 32'h0000_01AA) cmd8_arg_ok = 1;
                  rarg = bad_volt ? {20'h0, 4'h0, 8'h55} : {20'h0, f[19:8]};
                  rbody = {1'b0, 6'd8, rarg};
                  `CARD_RSP48(6'd8, rarg, crc7_40(rbody));
                  crsp_len <= 8'd48;
                  cgap     <= 4'd3;
                  post_act <= 2'd0;
                  cstate   <= C_GAP;
                  bad_volt <= 1'b0;                    // one-shot injection
                end
                6'd55: begin                           // CMD55: R1 (APP_CMD)
                  cmd55_cnt = cmd55_cnt + 1;
                  rbody = {1'b0, 6'd55, R1_APP};
                  rcrc  = crc7_40(rbody);
                  if (inj_crc7) rcrc = rcrc ^ 7'h55;
                  `CARD_RSP48(6'd55, R1_APP, rcrc);
                  crsp_len <= 8'd48;
                  cgap     <= 4'd3;
                  post_act <= 2'd0;
                  cstate   <= C_GAP;
                end
                6'd41: begin                           // ACMD41: R3 (OCR)
                  cmd41_cnt = cmd41_cnt + 1;
                  if (f[39:8] == 32'h40FF_8000) cmd41_arg_ok = 1;
                  `CARD_RSP48(6'b111111,
                              (busy_ready ? 32'hC0FF_8000 : 32'h00FF_8000),
                              7'h7F);
                  crsp_len   <= 8'd48;
                  cgap       <= 4'd3;
                  post_act   <= 2'd0;
                  cstate     <= C_GAP;
                  busy_ready <= 1'b1;                  // ready after 1st poll
                end
                6'd2: begin                            // CMD2: R2 (CID)
                  crsp     <= {1'b0, 1'b0, 6'b111111, CID_VAL[127:1], 1'b1};
                  crsp_len <= 8'd136;
                  cgap     <= 4'd3;
                  post_act <= 2'd0;
                  cstate   <= C_GAP;
                end
                6'd3: begin                            // CMD3: R6 (RCA)
                  rbody = {1'b0, 6'd3, RCA_VAL, 16'h0900};
                  `CARD_RSP48(6'd3, {RCA_VAL, 16'h0900}, crc7_40(rbody));
                  crsp_len <= 8'd48;
                  cgap     <= 4'd3;
                  post_act <= 2'd0;
                  cstate   <= C_GAP;
                end
                6'd7, 6'd13, 6'd24, 6'd17: begin       // R1 responses
                  rbody = {1'b0, f[45:40], R1_ST};
                  rcrc  = crc7_40(rbody);
                  if (inj_crc7) rcrc = rcrc ^ 7'h55;
                  `CARD_RSP48(f[45:40], R1_ST, rcrc);
                  crsp_len <= 8'd48;
                  cgap     <= 4'd3;
                  cstate   <= C_GAP;
                  if (f[45:40] == 6'd13) cmd13_cnt = cmd13_cnt + 1;
                  if (f[45:40] == 6'd24) begin         // CMD24: then RX data
                    cblk     <= f[9:8];
                    post_act <= 2'd1;
                  end else if (f[45:40] == 6'd17) begin // CMD17: then TX data
                    cblk     <= f[9:8];
                    post_act <= 2'd2;
                  end else begin
                    post_act <= 2'd0;
                  end
                end
                default: cstate <= C_IDLE;             // unknown: no response
              endcase
            end
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

      // -------------------- receive write data block on dat[3:0] ----------
      C_DRX: begin
        if (drx_cnt == 9'd0) begin
          if (dat === 4'b0000) begin
            drx_cnt  <= 9'd1;                          // start bits
            drx_to   <= 9'd0;
            drx_crc0 <= 16'h0;
            drx_crc1 <= 16'h0;
            drx_crc2 <= 16'h0;
            drx_crc3 <= 16'h0;
            drx_crx0 <= 16'h0;
            drx_crx1 <= 16'h0;
            drx_crx2 <= 16'h0;
            drx_crx3 <= 16'h0;
          end else if (drx_to >= 9'd300) begin         // host aborted write
            cstate <= C_IDLE;
            drx_to <= 9'd0;
          end else begin
            drx_to <= drx_to + 9'd1;
          end
        end else if (drx_cnt <= 9'd64) begin           // 64 nibbles
          card_blk[cblk] <= {card_blk[cblk][251:0], dat};
          drx_crc0 <= crc16_step(drx_crc0, dat[0]);
          drx_crc1 <= crc16_step(drx_crc1, dat[1]);
          drx_crc2 <= crc16_step(drx_crc2, dat[2]);
          drx_crc3 <= crc16_step(drx_crc3, dat[3]);
          drx_cnt  <= drx_cnt + 9'd1;
        end else if (drx_cnt <= 9'd80) begin           // 16 CRC16 bits/line
          drx_crx0 <= {drx_crx0[14:0], dat[0]};
          drx_crx1 <= {drx_crx1[14:0], dat[1]};
          drx_crx2 <= {drx_crx2[14:0], dat[2]};
          drx_crx3 <= {drx_crx3[14:0], dat[3]};
          drx_cnt  <= drx_cnt + 9'd1;
        end else begin                                 // end bits (drx_cnt==81)
          if (dat !== 4'hF || drx_crx0 !== drx_crc0 ||
              drx_crx1 !== drx_crc1 || drx_crx2 !== drx_crc2 ||
              drx_crx3 !== drx_crc3)
            card_datcrc_errs = card_datcrc_errs + 1;
          cstate    <= C_BUSY;                         // busy on DAT0
          busy_cnt  <= 4'd0;
          c_dat_oe  <= 4'b0001;
          c_dat_out <= 4'h0;
          drx_cnt   <= 9'd0;
        end
      end

      // -------------------- busy signalling on DAT0 after write -----------
      C_BUSY: begin
        busy_cnt <= busy_cnt + 4'd1;
        if (busy_cnt < 4'd8) begin
          c_dat_oe  <= 4'b0001;
          c_dat_out <= 4'h0;
        end else if (busy_cnt < 4'd11) begin
          c_dat_oe  <= 4'b0001;
          c_dat_out <= 4'h1;                           // busy released
        end else begin
          c_dat_oe <= 4'b0000;
          cstate   <= C_IDLE;
        end
      end

      // -------------------- prepare read data block -----------------------
      C_DTXGAP: begin
        if (cgap <= 4'd1) begin
          dtx_sh   <= card_blk[cblk];
          dtx_crc0 <= crc16_lane(card_blk[cblk], 0) ^
                      (inj_crc16 ? 16'hFFFF : 16'h0000);
          dtx_crc1 <= crc16_lane(card_blk[cblk], 1) ^
                      (inj_crc16 ? 16'hFFFF : 16'h0000);
          dtx_crc2 <= crc16_lane(card_blk[cblk], 2) ^
                      (inj_crc16 ? 16'hFFFF : 16'h0000);
          dtx_crc3 <= crc16_lane(card_blk[cblk], 3) ^
                      (inj_crc16 ? 16'hFFFF : 16'h0000);
          dtx_cnt  <= 9'd82;                           // start+64+16+1
          cstate   <= C_DTX;
        end else begin
          cgap <= cgap - 4'd1;
        end
      end

      // -------------------- send read data block on dat[3:0] --------------
      C_DTX: begin
        if (dtx_cnt > 9'd0) begin
          c_dat_oe <= 4'b1111;
          if (dtx_cnt == 9'd82) begin
            c_dat_out <= 4'b0000;                      // start bits
          end else if (dtx_cnt >= 9'd18) begin         // 64 data nibbles
            c_dat_out <= dtx_sh[255:252];
            dtx_sh    <= {dtx_sh[251:0], 4'h0};
          end else if (dtx_cnt >= 9'd2) begin          // 16 CRC16 bits/line
            c_dat_out <= {dtx_crc3[15], dtx_crc2[15],
                          dtx_crc1[15], dtx_crc0[15]};
            dtx_crc0  <= {dtx_crc0[14:0], 1'b0};
            dtx_crc1  <= {dtx_crc1[14:0], 1'b0};
            dtx_crc2  <= {dtx_crc2[14:0], 1'b0};
            dtx_crc3  <= {dtx_crc3[14:0], 1'b0};
          end else begin                               // dtx_cnt==1: end bits
            c_dat_out <= 4'hF;
          end
          dtx_cnt <= dtx_cnt - 9'd1;
        end else begin
          c_dat_oe <= 4'b0000;
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
        @(posedge sd_clk); twait = twait + 1; \
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
    rst_n = 1'b0;
    repeat (6) @(posedge clk);
    rst_n = 1'b1;
    repeat (3) @(posedge sd_clk);
    if (dut.state !== H_CMD0) begin
      $display("ERROR: post-reset state=%0d, expected H_CMD0(0)", dut.state);
      errors = errors + 1;
    end
    if (irq !== 1'b0 || dut.init_done !== 1'b0 || dut.err_crc7 !== 1'b0 ||
        dut.err_crc16 !== 1'b0 || dut.err_timeout !== 1'b0 ||
        dut.err_r7 !== 1'b0 || dut.match_cnt !== 8'd0) begin
      $display("ERROR: post-reset flags not clean");
      errors = errors + 1;
    end
    if (sdclk_cnt < 2) begin
      $display("ERROR: sd_clk not toggling (cnt=%0d)", sdclk_cnt);
      errors = errors + 1;
    end

    // (b) CMD8 voltage-mismatch injection: card answers R7 with wrong
    //     voltage/pattern; host must flag err_r7 + irq and restart init
    bad_volt  = 1'b1;
    irq_before = irq_cnt;
    `WAIT_FLAG(dut.err_r7 === 1'b1, "host R7 voltage-mismatch detect")
    if (dut.err_r7 === 1'b1) begin
      if (irq_cnt <= irq_before) begin
        $display("ERROR: no irq pulse on R7 voltage mismatch");
        errors = errors + 1;
      end
      if (cmd8_cnt < 1 || cmd8_arg_ok != 1) begin
        $display("ERROR: CMD8 not seen or arg!=0x1AA (cnt=%0d ok=%0d)",
                 cmd8_cnt, cmd8_arg_ok);
        errors = errors + 1;
      end
    end

    // (c) host retries: full init CMD0->CMD8->ACMD41(poll)->CMD2->CMD3->CMD7
    `WAIT_FLAG(dut.init_done === 1'b1, "init_done (CMD0..CMD7)")
    if (dut.init_done === 1'b1) begin
      if (cmd8_cnt < 2) begin
        $display("ERROR: CMD8 not retried after voltage mismatch (cnt=%0d)",
                 cmd8_cnt);
        errors = errors + 1;
      end
      if (dut.cid !== CID_VAL) begin
        $display("ERROR: CID got=%h exp=%h", dut.cid, CID_VAL);
        errors = errors + 1;
      end
      if (dut.rca !== RCA_VAL) begin
        $display("ERROR: RCA got=%h exp=%h", dut.rca, RCA_VAL);
        errors = errors + 1;
      end
      if (cmd41_cnt < 2 || cmd55_cnt < 2) begin
        $display("ERROR: ACMD41 polling missing (CMD55=%0d CMD41=%0d)",
                 cmd55_cnt, cmd41_cnt);
        errors = errors + 1;
      end
      if (cmd41_arg_ok != 1) begin
        $display("ERROR: ACMD41 arg wrong (HCS/OCR window)");
        errors = errors + 1;
      end
      // per-command init sequence: 0,8, 0,8, 55,41, 55,41, 2,3,7
      if (cmd_log_n < 11 ||
          cmd_log[0] != 0 || cmd_log[1] != 8 ||
          cmd_log[2] != 0 || cmd_log[3] != 8 ||
          cmd_log[4] != 55 || cmd_log[5] != 41 ||
          cmd_log[6] != 55 || cmd_log[7] != 41 ||
          cmd_log[8] != 2 || cmd_log[9] != 3 || cmd_log[10] != 7) begin
        $display("ERROR: init command sequence mismatch");
        errors = errors + 1;
      end
      if (irq_cnt != 1) begin                 // only the injected R7 error
        $display("ERROR: unexpected irq during clean init (irq_cnt=%0d)",
                 irq_cnt);
        errors = errors + 1;
      end
    end

    // (d) round 0: CMD24 write 32 bytes (4-bit) + CMD17 read-back + CMD13
    `WAIT_FLAG(dut.match_cnt >= 8'd1, "round0 write/read match")
    if (card_blk[0] !== exp_blk_tb(8'd0)) begin
      $display("ERROR: card block0 got=%h exp=%h", card_blk[0], exp_blk_tb(8'd0));
      errors = errors + 1;
    end
    if (cmd13_cnt < 1) begin
      $display("ERROR: CMD13 SEND_STATUS not issued after round0");
      errors = errors + 1;
    end
    if (dut.card_status !== R1_ST) begin
      $display("ERROR: card_status got=%h exp=%h", dut.card_status, R1_ST);
      errors = errors + 1;
    end
    if (cmd_log_n < 14 || cmd_log[11] != 24 || cmd_log[12] != 17 ||
        cmd_log[13] != 13) begin
      $display("ERROR: round0 command sequence mismatch (exp 24,17,13)");
      errors = errors + 1;
    end
    if (dut.err_crc16 !== 1'b0 || dut.err_timeout !== 1'b0 ||
        dut.err_crc7 !== 1'b0 || dut.err_cmp !== 1'b0) begin
      $display("ERROR: unexpected error flag after clean round0");
      errors = errors + 1;
    end
    // card-side sanity on clean traffic: host CRC7/CRC16 always valid
    if (card_cmdcrc_errs != 0) begin
      $display("ERROR: card saw %0d host commands with bad CRC7",
               card_cmdcrc_errs);
      errors = errors + 1;
    end
    if (card_datcrc_errs != 0) begin
      $display("ERROR: card saw %0d write blocks with bad CRC16",
               card_datcrc_errs);
      errors = errors + 1;
    end

    // (e) error injection: card sends bad CRC16 on the round-1 read block
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

    // (f) error injection: card sends R1 with bad CRC7
    irq_before = irq_cnt;
    inj_crc7   = 1'b1;
    `WAIT_FLAG(dut.err_crc7 === 1'b1, "host CRC7 error detect")
    inj_crc7   = 1'b0;
    if (irq_cnt <= irq_before) begin
      $display("ERROR: no irq pulse on bad CRC7 response");
      errors = errors + 1;
    end
    `WAIT_FLAG(dut.match_cnt >= 8'd3, "round2 match after CRC7 error")

    // (g) command timeout: card stops responding entirely
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

    if (errors == 0) $display("TEST PASSED: SD");
    else             $display("TEST FAILED: %0d errors", errors);
    $finish;
  end

  // ------------------------- optional debug trace -------------------------
`ifdef SD_DEBUG
  logic [3:0] prev_state  = 4'hf;
  logic [2:0] prev_dphase = 3'h7;
  logic [2:0] prev_cstate = 3'h7;
  always @(posedge sd_clk) begin
    if (dut.state != prev_state || dut.dphase != prev_dphase ||
        cstate != prev_cstate || irq) begin
      $display("t=%0t state=%0d ph=%0d dph=%0d bc=%0d wc=%0d card=%0d dtxc=%0d drxc=%0d mc=%0d rnd=%0d err=%b%b%b%b%b irqc=%0d",
               $time, dut.state, dut.phase, dut.dphase, dut.bit_cnt,
               dut.wait_cnt, cstate, dtx_cnt, drx_cnt, dut.match_cnt,
               dut.round, dut.err_crc7, dut.err_crc16, dut.err_timeout,
               dut.err_cmp, dut.err_r7, irq_cnt);
      prev_state  = dut.state;
      prev_dphase = dut.dphase;
      prev_cstate = cstate;
    end
  end
`endif

  // ------------------------- timeout guard --------------------------------
  initial begin
    #20_000_000;
    $display("TIMEOUT");
    $finish;
  end

endmodule
