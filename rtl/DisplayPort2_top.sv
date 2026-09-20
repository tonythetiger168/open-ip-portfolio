// SPDX-License-Identifier: Apache-2.0
// ============================================================================
// DisplayPort2 protocol Open IP -- DisplayPort source (TX) educational slice:
//  main link 1 lane with ANSI 8b/10b encoding (full D-code table + K28.5 /
//  K23.7 / K27.7 / K29.7 / K30.7 control codes, running-disparity tracking),
//  link-training FSM (D10.2 clock-recovery pattern -> TPS1 = K28.5 + D10.2
//  sequence with simplified TRAINING_PATTERN_SET semantics -> trained),
//  video streaming (BS/BE blanking marks + pixel data + SS/SE framed MSA
//  packet: VB-ID / Mvid[23:0] simplified to 4 dwords), AUX channel with
//  Manchester-II coding (1 bit = 2 clk chips), SYNC 16'h0000 preamble +
//  start bit, commands {native AUX write/read, I2C-over-AUX write/read},
//  addr[20] + len[8] + data + simplified stop (CRC replaced by stop chips),
//  DPCD register window access (16 x 8: link rate / lane count / training
//  pattern / lane status), I2C-over-AUX read of the first 8 EDID bytes.
// IP design implementation v1.0 -- Apache-2.0
// ----------------------------------------------------------------------------
// Documented simplifications (educational slice of the DP physical layer):
//  - 1 lane, serialisation 1 bit/clk; the 10-bit 8b/10b code is transmitted
//    'a' first (DP-native bit order), 10 clk per symbol, gap-free.
//  - AUX Manchester-II at 2 clk chips per bit (IEEE 802.3 convention:
//    logical 1 = chips (1,0), logical 0 = chips (0,1)). Idle line = 1.
//    SYNC = 16 zero bits + one start bit (1). STOP = chips (1,1).
//    AUX CRC nibble is replaced by the STOP chip pair (documented).
//  - DPCD window model: addr0 = LINK_RATE(0x14), addr1 = LANE_COUNT(1),
//    addr2 = TRAINING_PATTERN_SET (0x21=CR, 0x22=TPS1, 0x00=off),
//    addr3 = LANE0_STATUS (bit0 CR_DONE, bit1 EQ_DONE) -- lives in the sink.
//  - I2C-over-AUX: addr = {4'h0, i2c_dev[7:0], offset[7:0]}; write with
//    len=0 sets the EDID offset; read returns len bytes from EDID ROM.
//  - Link training: send >=32 CR symbols then poll LANE0_STATUS; up to 3
//    retries per phase; AUX timeout / NACK / Manchester violation retried
//    3 times, then train_fail + irq (sticky until reset).
//  - Video line (40 symbols, documented simplification):
//    BS(K27.7), 16 pixel D-symbols (pixel[i] = frame_cnt+i), BE(K28.5),
//    SS(K29.7), 16 MSA bytes (4 dwords LSB-first: {8'h00,8'h00,fc,8'h01},
//    32'h0012_3456 (Mvid), 32'h140 (Htotal), 32'h0F0 (Vtotal)), SE(K30.7),
//    FS(K23.7) + 3 x D00.0 fill. K23.7 fill is sent whenever the link is
//    up but no video/training pattern is active.
// ============================================================================
module DisplayPort2_top #(
  parameter int DW   = 32,      // data width (reserved, datapath fixed)
  parameter int AW   = 32       // address width (reserved)
)(
  input  logic        clk,
  input  logic        rst_n,
  // main link (serial, 1 bit/clk, 8b/10b encoded)
  output logic        lane_p,        // serial data out
  output logic        lane_valid,    // link up / transmitting
  output logic        link_trained,  // training complete, streaming video
  output logic        train_fail,    // training failed after all retries
  // AUX channel (Manchester-II, half duplex)
  output logic        aux_tx_p,      // Manchester chip out
  output logic        aux_tx_en,     // source is driving the AUX pair
  input  logic        aux_rx_p,      // Manchester chip in (from sink)
  input  logic        sink_present,  // HPD
  // EDID result (first 8 bytes, read via I2C-over-AUX)
  output logic [63:0] edid,
  output logic        edid_valid,
  output logic        irq
);

  // ------------------------- constants -------------------------
  localparam logic [7:0] D10_2  = 8'h4A;   // clock recovery pattern
  localparam logic [7:0] D00_0  = 8'h00;
  localparam logic [7:0] K28_5  = 8'hBC;   // comma / BE / TPS1 marker
  localparam logic [7:0] K23_7  = 8'hF7;   // fill start
  localparam logic [7:0] K27_7  = 8'hFB;   // blanking start (BS)
  localparam logic [7:0] K29_7  = 8'hFD;   // secondary start (SS)
  localparam logic [7:0] K30_7  = 8'hFE;   // secondary end (SE)

  localparam logic [3:0] AUX_CMD_I2C_WR = 4'h0;  // I2C-over-AUX write
  localparam logic [3:0] AUX_CMD_I2C_RD = 4'h1;  // I2C-over-AUX read
  localparam logic [3:0] AUX_CMD_WR     = 4'h8;  // native AUX write
  localparam logic [3:0] AUX_CMD_RD     = 4'h9;  // native AUX read
  localparam logic [3:0] AUX_REP_ACK    = 4'h0;

  localparam logic [7:0] DPCD_LINK_RATE = 8'h14;
  localparam logic [7:0] DPCD_LANE_CNT  = 8'h01;
  localparam logic [7:0] DPCD_TP_CR     = 8'h21; // TRAINING_PATTERN_SET: CR
  localparam logic [7:0] DPCD_TP_TPS1   = 8'h22; // TRAINING_PATTERN_SET: TPS1
  localparam logic [7:0] DPCD_TP_OFF    = 8'h00;

  localparam logic [8:0] RX_TIMEOUT = 9'd200;  // AUX reply timeout (clk)
  localparam logic [7:0] SYM_TRAIN  = 8'd32;   // symbols per training phase
  localparam logic [1:0] RETRY_MAX  = 2'd3;

  // MSA packet, 4 dwords, byte idx0 = dword0[7:0] sent first
  localparam logic [31:0] MSA_DW1 = 32'h0012_3456; // Mvid[23:0]
  localparam logic [31:0] MSA_DW2 = 32'h0000_0140; // Htotal (demo)
  localparam logic [31:0] MSA_DW3 = 32'h0000_00F0; // Vtotal (demo)

  // ------------------------- link-training controller states -------------------------
  typedef enum logic [4:0] {
    LT_IDLE, LT_CFG_RATE, LT_CFG_LANE, LT_CR_SET, LT_CR_WAIT, LT_CR_POLL,
    LT_TPS_SET, LT_TPS_WAIT, LT_TPS_POLL, LT_EDID_W, LT_EDID_R,
    LT_TRAIN_OFF, LT_VIDEO, LT_FAIL
  } lt_state_t;
  lt_state_t lt_state;

  // ------------------------- 8b/10b encoder -------------------------
  // ANSI X3.230-1994 tables; 6-bit literals written 'a'=MSB...'i'=LSB,
  // 4-bit literals 'f'=MSB...'j'=LSB.  Return {rd_out, code} with
  // code[9]='a' (transmitted first) ... code[0]='j'.
  // rd encoding: 0 = negative (-1), 1 = positive (+1).
  function automatic logic [10:0] enc_8b10b(input logic [7:0] d,
                                            input logic       k,
                                            input logic       rd);
    logic [4:0] d5;
    logic [2:0] d3;
    logic [5:0] s6;
    logic [3:0] s4;
    logic       rd1, rd2;
    logic [2:0] ones6;
    logic [1:0] ones4;
    logic       use_a7;
    begin
      d5 = d[4:0];
      d3 = d[7:5];
      // ---- 5b/6b ----
      if (k && d5 == 5'd28) begin
        s6 = 6'b001111;                                    // K28.x
        if (rd) s6 = ~s6;
      end else begin
        case (d5)                                          // RD- column
          5'd0 : s6 = 6'b100111;  5'd1 : s6 = 6'b011101;
          5'd2 : s6 = 6'b101101;  5'd3 : s6 = 6'b110001;
          5'd4 : s6 = 6'b110101;  5'd5 : s6 = 6'b101001;
          5'd6 : s6 = 6'b011001;  5'd7 : s6 = 6'b111000;
          5'd8 : s6 = 6'b111001;  5'd9 : s6 = 6'b100101;
          5'd10: s6 = 6'b010101;  5'd11: s6 = 6'b110100;
          5'd12: s6 = 6'b001101;  5'd13: s6 = 6'b101100;
          5'd14: s6 = 6'b011100;  5'd15: s6 = 6'b010111;
          5'd16: s6 = 6'b011011;  5'd17: s6 = 6'b100011;
          5'd18: s6 = 6'b010011;  5'd19: s6 = 6'b110010;
          5'd20: s6 = 6'b001011;  5'd21: s6 = 6'b101010;
          5'd22: s6 = 6'b011010;  5'd23: s6 = 6'b111010;
          5'd24: s6 = 6'b110011;  5'd25: s6 = 6'b100110;
          5'd26: s6 = 6'b010110;  5'd27: s6 = 6'b110110;
          5'd28: s6 = 6'b001110;  5'd29: s6 = 6'b101110;
          5'd30: s6 = 6'b011110;  default: s6 = 6'b101011;
        endcase
        // entries whose RD+ form is the bitwise complement
        if (rd && (d5 == 5'd0  || d5 == 5'd1  || d5 == 5'd2  || d5 == 5'd4  ||
                   d5 == 5'd7  || d5 == 5'd8  || d5 == 5'd15 || d5 == 5'd16 ||
                   d5 == 5'd23 || d5 == 5'd24 || d5 == 5'd27 || d5 == 5'd29 ||
                   d5 == 5'd30 || d5 == 5'd31))
          s6 = ~s6;
      end
      ones6 = s6[0] + s6[1] + s6[2] + s6[3] + s6[4] + s6[5];
      if (ones6 == 3) rd1 = rd;
      else            rd1 = (ones6 > 3);
      // ---- 3b/4b ----
      // A7 (alternate 0111/1000) for K.x.7, and for D.x.7 when P7 would
      // create a run of 5 (s6[0]='i', s6[1]='e')
      use_a7 = (d3 == 3'd7) &&
               (k || (!rd1 && s6[0] && s6[1]) || (rd1 && !s6[0] && !s6[1]));
      if (use_a7) begin
        s4 = rd1 ? 4'b1000 : 4'b0111;
      end else begin
        case (d3)                                          // RD- column
          3'd0: s4 = 4'b1011;  3'd1: s4 = 4'b1001;
          3'd2: s4 = 4'b0101;  3'd3: s4 = 4'b1100;
          3'd4: s4 = 4'b1101;  3'd5: s4 = 4'b1010;
          3'd6: s4 = 4'b0110;  default: s4 = 4'b1110;
        endcase
        if (rd1 && (d3 == 3'd0 || d3 == 3'd3 || d3 == 3'd4 || d3 == 3'd7))
          s4 = ~s4;
      end
      ones4 = s4[0] + s4[1] + s4[2] + s4[3];
      if (ones4 == 2) rd2 = rd1;
      else            rd2 = (ones4 > 2);
      enc_8b10b = {rd2, s6, s4};   // code[9]='a' ... code[0]='j'
    end
  endfunction

  // ------------------------- pattern / symbol generator -------------------------
  typedef enum logic [2:0] {PAT_FILL, PAT_CR, PAT_TPS1, PAT_VIDEO} pat_t;
  pat_t pat;

  logic [4:0]  tps_cnt;        // position within TPS1 burst
  logic [5:0]  frame_pos;      // 0..39 position within video line
  logic [7:0]  frame_cnt;      // increments per video line
  logic [7:0]  sym_cnt;        // symbols sent since pattern start (sat.)
  logic        pat_rst;        // pulse: restart pattern counters

  logic [7:0]  sym_d;
  logic        sym_k;
  logic [10:0] sym_enc;        // {rd_out, code[9:0]}
  logic        rd;             // running disparity (0 = -1)

  logic [127:0] msa;
  always_comb begin
    msa[31:0]    = {16'h0000, frame_cnt, 8'h01}; // VB-ID dword
    msa[63:32]   = MSA_DW1;
    msa[95:64]   = MSA_DW2;
    msa[127:96]  = MSA_DW3;
  end

  always_comb begin
    sym_d = K23_7;
    sym_k = 1'b1;
    case (pat)
      PAT_CR: begin
        sym_d = D10_2;
        sym_k = 1'b0;
      end
      PAT_TPS1: begin
        if (tps_cnt[1:0] == 2'd0) begin
          sym_d = K28_5; sym_k = 1'b1;   // TPS1 marker
        end else begin
          sym_d = D10_2; sym_k = 1'b0;
        end
      end
      PAT_VIDEO: begin
        if (frame_pos == 6'd0) begin
          sym_d = K27_7; sym_k = 1'b1;   // BS
        end else if (frame_pos <= 6'd16) begin
          sym_d = frame_cnt + ({3'b000, frame_pos[4:0]} - 8'd1); // pixel[i]
          sym_k = 1'b0;
        end else if (frame_pos == 6'd17) begin
          sym_d = K28_5; sym_k = 1'b1;   // BE
        end else if (frame_pos == 6'd18) begin
          sym_d = K29_7; sym_k = 1'b1;   // SS
        end else if (frame_pos <= 6'd34) begin
          sym_d = msa[8*(frame_pos-6'd19) +: 8];                 // MSA bytes
          sym_k = 1'b0;
        end else if (frame_pos == 6'd35) begin
          sym_d = K30_7; sym_k = 1'b1;   // SE
        end else if (frame_pos == 6'd36) begin
          sym_d = K23_7; sym_k = 1'b1;   // FS
        end else begin
          sym_d = D00_0; sym_k = 1'b0;   // fill
        end
      end
      default: begin
        sym_d = K23_7; sym_k = 1'b1;     // fill
      end
    endcase
    sym_enc = enc_8b10b(sym_d, sym_k, rd);
  end

  // ------------------------- serializer (1 bit/clk, 'a' first) -------------------------
  logic [9:0] shreg;
  logic [3:0] bit_cnt;
  logic       lane_active;
  logic       lane_valid_r;

  // lane_valid is aligned with the first serialised bit (one clk after
  // lane_active rises the first symbol is loaded)
  assign lane_valid   = lane_valid_r;
  assign link_trained = (lt_state == LT_VIDEO);
  assign irq          = train_fail;

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      shreg        <= 10'h000;
      bit_cnt      <= 4'd9;  // first active clk loads a symbol immediately
      lane_p       <= 1'b0;
      lane_valid_r <= 1'b0;
      rd           <= 1'b0;
      tps_cnt      <= 5'd0;
      frame_pos    <= 6'd0;
      frame_cnt    <= 8'd0;
      sym_cnt      <= 8'd0;
    end else if (lane_active) begin
      lane_valid_r <= 1'b1;
      if (pat_rst) begin
        sym_cnt   <= 8'd0;
        tps_cnt   <= 5'd0;
        frame_pos <= 6'd0;
      end
      if (bit_cnt == 4'd9) begin
        bit_cnt <= 4'd0;
        lane_p  <= sym_enc[9];            // 'a' first
        shreg   <= {sym_enc[8:0], 1'b0};
        rd      <= sym_enc[10];
        if (!pat_rst && sym_cnt != 8'hFF) sym_cnt <= sym_cnt + 8'd1;
        if (!pat_rst && pat == PAT_TPS1) tps_cnt <= tps_cnt + 5'd1;
        if (pat == PAT_VIDEO) begin
          if (frame_pos == 6'd39) begin
            frame_pos <= 6'd0;
            frame_cnt <= frame_cnt + 8'd1;
          end else if (!pat_rst) begin
            frame_pos <= frame_pos + 6'd1;
          end
        end
      end else begin
        bit_cnt <= bit_cnt + 4'd1;
        lane_p  <= shreg[9];
        shreg   <= {shreg[8:0], 1'b0};
      end
    end else begin
      bit_cnt      <= 4'd9;
      lane_p       <= 1'b0;
      lane_valid_r <= 1'b0;
      shreg        <= 10'h000;
    end
  end

  // ------------------------- AUX engine (Manchester-II) -------------------------
  // request: SYNC(16x0) + start(1) + {cmd,addr[19:16]} + addr[15:8] +
  //          addr[7:0] + {4'h0,len} + [write data len bytes] + STOP
  // reply:   SYNC(16x0) + start(1) + {reply[3:0],4'h0} + [read data] + STOP
  typedef enum logic [3:0] {
    A_IDLE, A_SYNC0, A_SYNC1, A_START0, A_START1, A_C0, A_C1,
    A_STOP0, A_STOP1, A_RX_W0, A_RX_C0, A_RX_C1, A_RX_STOP0, A_RX_STOP1
  } aux_state_t;
  aux_state_t aux_state;

  // operation interface (driven by link-training FSM)
  logic        op_start;
  logic [3:0]  op_cmd;
  logic [19:0] op_addr;
  logic [3:0]  op_len;        // number of data bytes (0..8)
  logic [63:0] op_wdata;      // byte i at [8*i +: 8], first byte = LSB
  logic        op_done;       // 1-clk pulse
  logic        op_err;        // timeout / NACK / Manchester violation
  logic [63:0] op_rdata;      // byte i at [8*i +: 8], first byte = LSB

  logic [4:0]  a_sync_cnt;    // 0..17 (16 sync + start)
  logic [3:0]  a_byte_idx;
  logic [4:0]  a_byte_total;
  logic [3:0]  a_exp_len;     // expected reply data bytes (reads only)
  logic [2:0]  a_bit_idx;
  logic [7:0]  a_tx_byte;
  logic [7:0]  a_rx_byte;
  logic        a_cur_bit;     // chip0 of the current pair
  logic [3:0]  a_rx_reply;
  logic [8:0]  a_timeout;

  // TX byte selector
  always_comb begin
    case (a_byte_idx)
      4'd0: a_tx_byte = {op_cmd, op_addr[19:16]};
      4'd1: a_tx_byte = op_addr[15:8];
      4'd2: a_tx_byte = op_addr[7:0];
      4'd3: a_tx_byte = {4'h0, op_len};
      default: a_tx_byte = op_wdata[8*(a_byte_idx-4) +: 8];
    endcase
  end

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      aux_state    <= A_IDLE;
      aux_tx_p     <= 1'b1;
      aux_tx_en    <= 1'b0;
      op_done      <= 1'b0;
      op_err       <= 1'b0;
      op_rdata     <= 64'h0;
      a_sync_cnt   <= 5'd0;
      a_byte_idx   <= 4'd0;
      a_byte_total <= 5'd0;
      a_exp_len    <= 4'd0;
      a_bit_idx    <= 3'd0;
      a_rx_byte    <= 8'h00;
      a_cur_bit    <= 1'b0;
      a_rx_reply   <= 4'h0;
      a_timeout    <= 9'd0;
    end else begin
      op_done <= 1'b0;
      case (aux_state)
        A_IDLE: begin
          aux_tx_en <= 1'b0;
          aux_tx_p  <= 1'b1;
          if (op_start) begin
            aux_tx_en    <= 1'b1;
            aux_tx_p     <= 1'b0;         // SYNC chip0 of bit0
            a_sync_cnt   <= 5'd0;
            a_byte_total <= 5'd4 +
              ((op_cmd == AUX_CMD_WR || op_cmd == AUX_CMD_I2C_WR)
               ? {1'b0, op_len} : 5'd0);
            a_exp_len    <=
              ((op_cmd == AUX_CMD_RD || op_cmd == AUX_CMD_I2C_RD)
               ? op_len : 4'd0);
            a_byte_idx   <= 4'd0;
            a_bit_idx    <= 3'd0;
            a_timeout    <= 9'd0;
            aux_state    <= A_SYNC1;
          end
        end
        // --- TX SYNC: 16 zero bits -> chips (0,1) ---
        A_SYNC1: begin
          aux_tx_p <= 1'b1;
          if (a_sync_cnt == 5'd15) begin
            a_sync_cnt <= 5'd0;
            aux_state  <= A_START0;
          end else begin
            a_sync_cnt <= a_sync_cnt + 5'd1;
            aux_state  <= A_SYNC0;
          end
        end
        A_SYNC0: begin
          aux_tx_p  <= 1'b0;
          aux_state <= A_SYNC1;
        end
        // --- start bit = 1 -> chips (1,0) ---
        A_START0: begin
          aux_tx_p  <= 1'b1;
          aux_state <= A_START1;
        end
        A_START1: begin
          aux_tx_p  <= 1'b0;
          aux_state <= A_C0;
        end
        // --- data bytes, MSB first, chip0 = bit, chip1 = ~bit ---
        A_C0: begin
          aux_tx_p  <= a_tx_byte[3'd7 - a_bit_idx];
          aux_state <= A_C1;
        end
        A_C1: begin
          aux_tx_p <= ~a_tx_byte[3'd7 - a_bit_idx];
          if (a_bit_idx == 3'd7) begin
            a_bit_idx <= 3'd0;
            if ({1'b0, a_byte_idx} == a_byte_total - 5'd1) begin
              aux_state <= A_STOP0;
            end else begin
              a_byte_idx <= a_byte_idx + 4'd1;
              aux_state  <= A_C0;
            end
          end else begin
            a_bit_idx <= a_bit_idx + 3'd1;
            aux_state <= A_C0;
          end
        end
        // --- STOP chips (1,1), then release the pair ---
        A_STOP0: begin
          aux_tx_p  <= 1'b1;
          aux_state <= A_STOP1;
        end
        A_STOP1: begin
          aux_tx_p   <= 1'b1;
          aux_tx_en  <= 1'b0;
          a_timeout  <= 9'd0;
          a_sync_cnt <= 5'd0;
          a_bit_idx  <= 3'd0;
          a_byte_idx <= 4'd0;
          aux_state  <= A_RX_W0;
        end
        // --- RX: wait for the 1->0 transition = chip0 of first SYNC pair ---
        A_RX_W0: begin
          a_timeout <= a_timeout + 9'd1;
          if (a_timeout == RX_TIMEOUT) begin
            op_err    <= 1'b1;
            op_done   <= 1'b1;
            aux_state <= A_IDLE;
          end else if (!aux_rx_p) begin
            a_cur_bit <= 1'b0;
            aux_state <= A_RX_C1;
          end
        end
        // --- RX pairs: chip0 in A_RX_C0, chip1 in A_RX_C1 ---
        A_RX_C0: begin
          a_timeout <= a_timeout + 9'd1;
          if (a_timeout == RX_TIMEOUT) begin
            op_err    <= 1'b1;
            op_done   <= 1'b1;
            aux_state <= A_IDLE;
          end else begin
            a_cur_bit <= aux_rx_p;      // bit = chip0 (802.3)
            aux_state <= A_RX_C1;
          end
        end
        A_RX_C1: begin
          if (aux_rx_p == a_cur_bit) begin
            op_err    <= 1'b1;          // Manchester violation (0,0)/(1,1)
            op_done   <= 1'b1;
            aux_state <= A_IDLE;
          end else if (a_sync_cnt < 5'd16) begin
            if (!a_cur_bit) begin       // SYNC bit = 0
              a_sync_cnt <= a_sync_cnt + 5'd1;
              aux_state  <= A_RX_C0;
            end else begin
              op_err    <= 1'b1;
              op_done   <= 1'b1;
              aux_state <= A_IDLE;
            end
          end else if (a_sync_cnt == 5'd16) begin
            if (a_cur_bit) begin        // start bit = 1
              a_sync_cnt <= a_sync_cnt + 5'd1;
              a_bit_idx  <= 3'd0;
              a_byte_idx <= 4'd0;
              aux_state  <= A_RX_C0;
            end else begin
              op_err    <= 1'b1;
              op_done   <= 1'b1;
              aux_state <= A_IDLE;
            end
          end else begin
            // data bit, MSB first
            a_rx_byte <= {a_rx_byte[6:0], a_cur_bit};
            if (a_bit_idx == 3'd7) begin
              a_bit_idx <= 3'd0;
              if (a_byte_idx == 4'd0)
                a_rx_reply <= a_rx_byte[6:3]; // {b7,b6,b5,b4}
              else
                op_rdata[8*(a_byte_idx-1) +: 8] <= {a_rx_byte[6:0], a_cur_bit};
              if (a_byte_idx == a_exp_len) begin
                aux_state <= A_RX_STOP0;
              end else begin
                a_byte_idx <= a_byte_idx + 4'd1;
                aux_state  <= A_RX_C0;
              end
            end else begin
              a_bit_idx <= a_bit_idx + 3'd1;
              aux_state <= A_RX_C0;
            end
          end
        end
        A_RX_STOP0: begin
          if (aux_rx_p) aux_state <= A_RX_STOP1;
          else begin
            op_err    <= 1'b1;
            op_done   <= 1'b1;
            aux_state <= A_IDLE;
          end
        end
        A_RX_STOP1: begin
          op_err    <= !aux_rx_p || (a_rx_reply != AUX_REP_ACK);
          op_done   <= 1'b1;
          aux_state <= A_IDLE;
        end
        default: aux_state <= A_IDLE;
      endcase
    end
  end

  // ------------------------- link-training controller -------------------------
  logic [1:0] retry_cnt;

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      lt_state    <= LT_IDLE;
      lane_active <= 1'b0;
      train_fail  <= 1'b0;
      pat         <= PAT_FILL;
      pat_rst     <= 1'b0;
      op_start    <= 1'b0;
      op_cmd      <= 4'h0;
      op_addr     <= 20'h0;
      op_len      <= 4'h0;
      op_wdata    <= 64'h0;
      retry_cnt   <= 2'd0;
      edid        <= 64'h0;
      edid_valid  <= 1'b0;
    end else begin
      op_start <= 1'b0;
      pat_rst  <= 1'b0;
      case (lt_state)
        LT_IDLE: begin
          if (sink_present) begin
            lane_active <= 1'b1;
            retry_cnt   <= 2'd0;
            op_start    <= 1'b1;
            op_cmd      <= AUX_CMD_WR;
            op_addr     <= 20'h0;
            op_len      <= 4'd1;
            op_wdata    <= {56'h0, DPCD_LINK_RATE};
            lt_state    <= LT_CFG_RATE;
          end
        end
        LT_CFG_RATE:
          if (op_done) begin
            if (!op_err) begin
              retry_cnt <= 2'd0;
              op_start  <= 1'b1;
              op_cmd    <= AUX_CMD_WR;
              op_addr   <= 20'h1;
              op_len    <= 4'd1;
              op_wdata  <= {56'h0, DPCD_LANE_CNT};
              lt_state  <= LT_CFG_LANE;
            end else if (retry_cnt == RETRY_MAX) lt_state <= LT_FAIL;
            else begin
              retry_cnt <= retry_cnt + 2'd1;
              op_start  <= 1'b1;         // retry same op
            end
          end
        LT_CFG_LANE:
          if (op_done) begin
            if (!op_err) begin
              retry_cnt <= 2'd0;
              op_start  <= 1'b1;
              op_cmd    <= AUX_CMD_WR;
              op_addr   <= 20'h2;
              op_len    <= 4'd1;
              op_wdata  <= {56'h0, DPCD_TP_CR};
              lt_state  <= LT_CR_SET;
            end else if (retry_cnt == RETRY_MAX) lt_state <= LT_FAIL;
            else begin
              retry_cnt <= retry_cnt + 2'd1;
              op_start  <= 1'b1;
            end
          end
        LT_CR_SET:
          if (op_done) begin
            if (!op_err) begin
              pat       <= PAT_CR;
              pat_rst   <= 1'b1;
              retry_cnt <= 2'd0;
              lt_state  <= LT_CR_WAIT;
            end else if (retry_cnt == RETRY_MAX) lt_state <= LT_FAIL;
            else begin
              retry_cnt <= retry_cnt + 2'd1;
              op_start  <= 1'b1;
            end
          end
        LT_CR_WAIT:
          if (sym_cnt >= SYM_TRAIN) begin
            retry_cnt <= retry_cnt;      // hold
            op_start  <= 1'b1;
            op_cmd    <= AUX_CMD_RD;
            op_addr   <= 20'h3;
            op_len    <= 4'd1;
            op_wdata  <= 64'h0;
            lt_state  <= LT_CR_POLL;
          end
        LT_CR_POLL:
          if (op_done) begin
            if (!op_err && op_rdata[0]) begin   // CR_DONE
              retry_cnt <= 2'd0;
              op_start  <= 1'b1;
              op_cmd    <= AUX_CMD_WR;
              op_addr   <= 20'h2;
              op_len    <= 4'd1;
              op_wdata  <= {56'h0, DPCD_TP_TPS1};
              lt_state  <= LT_TPS_SET;
            end else if (retry_cnt == RETRY_MAX) lt_state <= LT_FAIL;
            else begin
              retry_cnt <= retry_cnt + 2'd1;
              lt_state  <= LT_CR_WAIT;   // keep CR pattern, poll again
            end
          end
        LT_TPS_SET:
          if (op_done) begin
            if (!op_err) begin
              pat       <= PAT_TPS1;
              pat_rst   <= 1'b1;
              retry_cnt <= 2'd0;
              lt_state  <= LT_TPS_WAIT;
            end else if (retry_cnt == RETRY_MAX) lt_state <= LT_FAIL;
            else begin
              retry_cnt <= retry_cnt + 2'd1;
              op_start  <= 1'b1;
            end
          end
        LT_TPS_WAIT:
          if (sym_cnt >= SYM_TRAIN) begin
            op_start  <= 1'b1;
            op_cmd    <= AUX_CMD_RD;
            op_addr   <= 20'h3;
            op_len    <= 4'd1;
            op_wdata  <= 64'h0;
            lt_state  <= LT_TPS_POLL;
          end
        LT_TPS_POLL:
          if (op_done) begin
            if (!op_err && op_rdata[1]) begin   // EQ_DONE
              retry_cnt <= 2'd0;
              op_start  <= 1'b1;
              op_cmd    <= AUX_CMD_I2C_WR;
              op_addr   <= {4'h0, 8'h50, 8'h00};
              op_len    <= 4'd0;
              op_wdata  <= 64'h0;
              lt_state  <= LT_EDID_W;
            end else if (retry_cnt == RETRY_MAX) lt_state <= LT_FAIL;
            else begin
              retry_cnt <= retry_cnt + 2'd1;
              lt_state  <= LT_TPS_WAIT;
            end
          end
        LT_EDID_W:
          if (op_done) begin
            if (!op_err) begin
              retry_cnt <= 2'd0;
              op_start  <= 1'b1;
              op_cmd    <= AUX_CMD_I2C_RD;
              op_addr   <= {4'h0, 8'h50, 8'h00};
              op_len    <= 4'd8;
              op_wdata  <= 64'h0;
              lt_state  <= LT_EDID_R;
            end else if (retry_cnt == RETRY_MAX) lt_state <= LT_FAIL;
            else begin
              retry_cnt <= retry_cnt + 2'd1;
              op_start  <= 1'b1;
            end
          end
        LT_EDID_R:
          if (op_done) begin
            if (!op_err) begin
              edid       <= op_rdata;
              edid_valid <= 1'b1;
              retry_cnt  <= 2'd0;
              op_start   <= 1'b1;
              op_cmd     <= AUX_CMD_WR;
              op_addr    <= 20'h2;
              op_len     <= 4'd1;
              op_wdata   <= {56'h0, DPCD_TP_OFF};
              lt_state   <= LT_TRAIN_OFF;
            end else if (retry_cnt == RETRY_MAX) lt_state <= LT_FAIL;
            else begin
              retry_cnt <= retry_cnt + 2'd1;
              op_start  <= 1'b1;
            end
          end
        LT_TRAIN_OFF:
          if (op_done) begin
            if (!op_err) begin
              pat      <= PAT_VIDEO;
              pat_rst  <= 1'b1;
              lt_state <= LT_VIDEO;
            end else if (retry_cnt == RETRY_MAX) lt_state <= LT_FAIL;
            else begin
              retry_cnt <= retry_cnt + 2'd1;
              op_start  <= 1'b1;
            end
          end
        LT_VIDEO: begin
          pat <= PAT_VIDEO;              // free-running video stream
        end
        LT_FAIL: begin
          train_fail <= 1'b1;
          pat        <= PAT_FILL;
        end
        default: lt_state <= LT_IDLE;
      endcase
    end
  end

endmodule
