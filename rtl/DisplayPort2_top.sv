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
//  pattern / lane status), I2C-over-AUX read of the first 8 EDID bytes,
//  HPD unplug / replug.
// IP design implementation v2.0 -- Apache-2.0
// ----------------------------------------------------------------------------
// Documented simplifications (educational slice of the DP physical layer):
//  - 1 lane, serialisation 1 bit/clk; the 10-bit 8b/10b code is transmitted
//    'a' first (DP-native bit order), 10 clk per symbol, gap-free. The
//    running disparity restarts at RD- whenever the lane comes up.
//  - AUX Manchester-II at 2 clk chips per bit (IEEE 802.3 convention:
//    logical 1 = chips (1,0), logical 0 = chips (0,1)). Idle line = 1.
//    SYNC = 16 zero bits + one start bit (1). STOP = chips (1,1).
//    AUX CRC nibble is replaced by the STOP chip pair (documented).
//  - AUX reply: header byte {reply[3:0], 4'hx}; reply 0 = ACK, any other
//    code (NACK, DEFER, I2C NACK/DEFER) is a failed attempt and carries no
//    data: the STOP follows the header. An ACK carries exactly the
//    requested number of bytes. The reply must start within 200 clk of the
//    request STOP; a Manchester violation, a bad SYNC / start bit or a
//    missing STOP fails the attempt.
//  - DPCD window model: addr0 = LINK_RATE(0x14), addr1 = LANE_COUNT(1),
//    addr2 = TRAINING_PATTERN_SET (0x21=CR, 0x22=TPS1, 0x00=off),
//    addr3 = LANE0_STATUS (bit0 CR_DONE, bit1 EQ_DONE) -- lives in the sink.
//  - I2C-over-AUX: addr = {4'h0, i2c_dev[7:0], offset[7:0]}; write with
//    len=0 sets the EDID offset; read returns len bytes from EDID ROM.
//  - Link training: send >= 32 CR symbols then poll LANE0_STATUS; a poll
//    that is not done (or fails) re-polls after another 32 symbols, up to 3
//    retries per phase. Every AUX op is retried 3 times. Then train_fail +
//    irq, sticky until reset or HPD low; fill (K23.7) keeps the lane up.
//  - HPD (sink_present) is taken as already debounced: low drops the lane,
//    aborts any AUX transfer and clears edid_valid / train_fail; high
//    starts a new training.
//  - Video line (40 symbols, documented simplification):
//    BS(K27.7), 16 pixel D-symbols (pixel[i] = frame_cnt+i), BE(K28.5),
//    SS(K29.7), 16 MSA bytes (4 dwords LSB-first: {8'h00,8'h00,fc,8'h01},
//    32'h0012_3456 (Mvid), 32'h140 (Htotal), 32'h0F0 (Vtotal)), SE(K30.7),
//    FS(K23.7) + 3 x D00.0 fill. K23.7 fill is sent whenever the link is
//    up but no video/training pattern is active.
// ============================================================================
module DisplayPort2_top (
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

  localparam logic [7:0] DPCD_LINK_RATE = 8'h14;
  localparam logic [7:0] DPCD_LANE_CNT  = 8'h01;
  localparam logic [7:0] DPCD_TP_CR     = 8'h21; // TRAINING_PATTERN_SET: CR
  localparam logic [7:0] DPCD_TP_TPS1   = 8'h22; // TRAINING_PATTERN_SET: TPS1
  localparam logic [7:0] DPCD_TP_OFF    = 8'h00;
  localparam logic [7:0] EDID_I2C_ADDR  = 8'h50;

  localparam logic [7:0] RX_TIMEOUT = 8'd200;  // AUX reply start timeout (clk)
  localparam logic [1:0] RETRY_MAX  = 2'd3;

  // ------------------------- link-training controller states -------------------------
  typedef enum logic [3:0] {
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
      ones6 = {2'b00, s6[0]} + {2'b00, s6[1]} + {2'b00, s6[2]} +
              {2'b00, s6[3]} + {2'b00, s6[4]} + {2'b00, s6[5]};
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
        // K28.1/.2/.5/.6 after 110000 (RD+ in) take the complemented 4b
        // form, e.g. K28.5 RD+ = 110000 0101
        if (k && d5 == 5'd28 && rd && (d3 == 3'd1 || d3 == 3'd2 || d3 == 3'd5 || d3 == 3'd6))
          s4 = ~s4;
      end
      ones4 = {1'b0, s4[0]} + {1'b0, s4[1]} + {1'b0, s4[2]} + {1'b0, s4[3]};
      if (ones4 == 2) rd2 = rd1;
      else            rd2 = (ones4 > 2);
      enc_8b10b = {rd2, s6, s4};   // code[9]='a' ... code[0]='j'
    end
  endfunction

  // ------------------------- pattern / symbol generator -------------------------
  typedef enum logic [1:0] {PAT_FILL, PAT_CR, PAT_TPS1, PAT_VIDEO} pat_t;
  pat_t pat;

  logic [1:0]  tps_cnt;        // position within the 4-symbol TPS1 sequence
  logic [5:0]  frame_pos;      // 0..39 position within the video line
  logic [7:0]  frame_cnt;      // increments per video line
  logic [5:0]  sym_cnt;        // symbols since pattern start, saturates at 32
  logic        pat_rst;        // pulse: the new pattern starts at position 0

  // positions of the symbol loaded now (a pattern restart counts as 0)
  wire  [1:0]  tps_pos = pat_rst ? 2'd0 : tps_cnt;
  wire  [5:0]  vid_pos = pat_rst ? 6'd0 : frame_pos;

  logic [7:0]  sym_d;
  logic        sym_k;
  logic [10:0] sym_enc;        // {rd_out, code[9:0]}
  logic        rd;             // running disparity (0 = -1)

  // MSA packet, 4 dwords LSB first: VB-ID {00,00,fc,01}, Mvid, Htotal, Vtotal
  function automatic logic [7:0] msa_byte(input logic [3:0] i, input logic [7:0] fc);
    case (i)
      4'd0:    msa_byte = 8'h01;
      4'd1:    msa_byte = fc;
      4'd4:    msa_byte = 8'h56;
      4'd5:    msa_byte = 8'h34;
      4'd6:    msa_byte = 8'h12;
      4'd8:    msa_byte = 8'h40;
      4'd9:    msa_byte = 8'h01;
      4'd12:   msa_byte = 8'hF0;
      default: msa_byte = 8'h00;
    endcase
  endfunction

  always_comb begin
    sym_d = K23_7;
    sym_k = 1'b1;
    case (pat)
      PAT_CR: begin
        sym_d = D10_2; sym_k = 1'b0;
      end
      PAT_TPS1: begin
        if (tps_pos == 2'd0) begin
          sym_d = K28_5; sym_k = 1'b1;   // TPS1 marker
        end else begin
          sym_d = D10_2; sym_k = 1'b0;
        end
      end
      PAT_VIDEO: begin
        if (vid_pos == 6'd0) begin
          sym_d = K27_7; sym_k = 1'b1;   // BS
        end else if (vid_pos <= 6'd16) begin
          sym_d = frame_cnt + {2'b00, vid_pos} - 8'd1;           // pixel[i]
          sym_k = 1'b0;
        end else if (vid_pos == 6'd17) begin
          sym_d = K28_5; sym_k = 1'b1;   // BE
        end else if (vid_pos == 6'd18) begin
          sym_d = K29_7; sym_k = 1'b1;   // SS
        end else if (vid_pos <= 6'd34) begin
          sym_d = msa_byte(4'(vid_pos - 6'd19), frame_cnt);       // MSA bytes
          sym_k = 1'b0;
        end else if (vid_pos == 6'd35) begin
          sym_d = K30_7; sym_k = 1'b1;   // SE
        end else if (vid_pos == 6'd36) begin
          sym_d = K23_7; sym_k = 1'b1;   // FS
        end else begin
          sym_d = D00_0; sym_k = 1'b0;   // fill
        end
      end
      default: ;                         // PAT_FILL: K23.7
    endcase
    sym_enc = enc_8b10b(sym_d, sym_k, rd);
  end

  // ------------------------- serializer (1 bit/clk, 'a' first) -------------------------
  logic [8:0] shreg;           // code bits b..j still to send
  logic [3:0] bit_cnt;
  logic       lane_active;

  assign link_trained = (lt_state == LT_VIDEO);
  assign irq          = train_fail;

  // lane_valid is aligned with the first serialised bit (the first active
  // clk loads a symbol)
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      shreg      <= '0;
      bit_cnt    <= 4'd9;
      lane_p     <= 1'b0;
      lane_valid <= 1'b0;
      rd         <= 1'b0;
      tps_cnt    <= 2'd0;
      frame_pos  <= 6'd0;
      frame_cnt  <= 8'd0;
      sym_cnt    <= 6'd0;
    end else if (lane_active) begin
      lane_valid <= 1'b1;
      if (bit_cnt == 4'd9) begin           // symbol boundary: load the next code
        bit_cnt   <= 4'd0;
        lane_p    <= sym_enc[9];           // 'a' first
        shreg     <= sym_enc[8:0];
        rd        <= sym_enc[10];
        tps_cnt   <= tps_pos + 2'd1;
        frame_pos <= vid_pos == 6'd39 ? 6'd0 : vid_pos + 6'd1;
        if (pat == PAT_VIDEO && vid_pos == 6'd39) frame_cnt <= frame_cnt + 8'd1;
        if (pat_rst) sym_cnt <= 6'd1;
        else if (!sym_cnt[5]) sym_cnt <= sym_cnt + 6'd1;
      end else begin
        bit_cnt <= bit_cnt + 4'd1;
        lane_p  <= shreg[8];
        shreg   <= {shreg[7:0], 1'b0};
        if (pat_rst) begin
          tps_cnt   <= 2'd0;
          frame_pos <= 6'd0;
          sym_cnt   <= 6'd0;
        end
      end
    end else begin
      bit_cnt    <= 4'd9;
      lane_p     <= 1'b0;
      lane_valid <= 1'b0;
      shreg      <= '0;
      rd         <= 1'b0;
    end
  end

  // ------------------------- AUX request content -------------------------
  // Each AUX op belongs to the link-training state that waits for it, so
  // the request bytes are a function of lt_state:
  //  {cmd, addr[19:16]}, addr[15:8], addr[7:0], {4'h0, len}, [write byte]
  function automatic logic [7:0] req_byte(input lt_state_t s, input logic [2:0] i);
    logic       i2c, rd_op;
    logic [1:0] da;            // DPCD address
    logic [7:0] wd;            // write data
    i2c   = s == LT_EDID_W || s == LT_EDID_R;
    rd_op = s == LT_CR_POLL || s == LT_TPS_POLL || s == LT_EDID_R;
    case (s)
      LT_CFG_RATE:  begin da = 2'd0; wd = DPCD_LINK_RATE; end
      LT_CFG_LANE:  begin da = 2'd1; wd = DPCD_LANE_CNT;  end
      LT_CR_SET:    begin da = 2'd2; wd = DPCD_TP_CR;     end
      LT_TPS_SET:   begin da = 2'd2; wd = DPCD_TP_TPS1;   end
      LT_TRAIN_OFF: begin da = 2'd2; wd = DPCD_TP_OFF;    end
      default:      begin da = 2'd3; wd = 8'h00;          end  // polls, EDID
    endcase
    case (i)
      3'd0:    req_byte = {!i2c, 2'b00, rd_op, 4'h0};          // cmd, addr[19:16]
      3'd1:    req_byte = i2c ? EDID_I2C_ADDR : 8'h00;
      3'd2:    req_byte = i2c ? 8'h00 : {6'd0, da};
      3'd3:    req_byte = s == LT_EDID_R ? 8'd8 : {7'd0, !i2c};
      default: req_byte = wd;
    endcase
  endfunction

  function automatic logic req_bit(input lt_state_t s, input logic [2:0] i,
                                   input logic [2:0] b);
    logic [7:0] v;
    v = req_byte(s, i);
    req_bit = v[3'd7 - b];
  endfunction

  // native writes carry one data byte (5 request bytes), the rest 4
  function automatic logic req_has_data(input lt_state_t s);
    req_has_data = !(s == LT_CR_POLL || s == LT_TPS_POLL ||
                     s == LT_EDID_W || s == LT_EDID_R);
  endfunction

  // data bytes expected in an ACK reply
  function automatic logic [3:0] rep_len(input lt_state_t s);
    rep_len = s == LT_EDID_R ? 4'd8 :
              (s == LT_CR_POLL || s == LT_TPS_POLL) ? 4'd1 : 4'd0;
  endfunction

  // ------------------------- AUX engine (Manchester-II) -------------------------
  // request: SYNC(16x0) + start(1) + request bytes + STOP
  // reply:   SYNC(16x0) + start(1) + {reply[3:0],4'hx} + [read data] + STOP
  typedef enum logic [3:0] {
    A_IDLE, A_SYNC0, A_SYNC1, A_START0, A_START1, A_C0, A_C1,
    A_STOP0, A_STOP1, A_RX_W0, A_RX_C0, A_RX_C1, A_RX_STOP0, A_RX_STOP1
  } aux_state_t;
  aux_state_t aux_state;

  logic        op_start;      // from the link-training FSM
  logic        op_done;       // 1-clk pulse
  logic        op_err;        // timeout / NACK / framing error (with op_done)
  logic [63:0] op_rdata;      // reply byte i at [8*i +: 8]

  logic [4:0]  a_sync_cnt;    // TX: 0..15 SYNC bits; RX: 0..15 SYNC, 16 start, 17 data
  logic [3:0]  a_byte_idx;
  logic [2:0]  a_bit_idx;
  logic [6:0]  a_rx_byte;     // bits received so far of the current byte
  logic        a_cur_bit;     // chip0 of the current pair
  logic        a_nak;         // reply code was not ACK
  logic [7:0]  a_timeout;

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      aux_state  <= A_IDLE;
      aux_tx_p   <= 1'b1;
      aux_tx_en  <= 1'b0;
      op_done    <= 1'b0;
      op_err     <= 1'b0;
      op_rdata   <= '0;
      a_sync_cnt <= '0;
      a_byte_idx <= '0;
      a_bit_idx  <= '0;
      a_rx_byte  <= '0;
      a_cur_bit  <= 1'b0;
      a_nak      <= 1'b0;
      a_timeout  <= '0;
    end else if (!sink_present) begin    // unplug aborts the transfer
      aux_state  <= A_IDLE;
      aux_tx_p   <= 1'b1;
      aux_tx_en  <= 1'b0;
      op_done    <= 1'b0;
      a_sync_cnt <= '0;
      a_bit_idx  <= '0;
    end else begin
      op_done <= 1'b0;
      case (aux_state)
        A_IDLE:
          if (op_start) begin
            aux_tx_en  <= 1'b1;
            aux_tx_p   <= 1'b0;          // SYNC chip0 of bit0
            a_byte_idx <= '0;
            aux_state  <= A_SYNC1;
          end
        // --- TX SYNC: 16 zero bits -> chips (0,1) ---
        A_SYNC1: begin
          aux_tx_p <= 1'b1;
          if (a_sync_cnt == 5'd15) begin
            a_sync_cnt <= '0;
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
        // --- request bytes, MSB first, chip0 = bit, chip1 = ~bit ---
        A_C0: begin
          aux_tx_p  <= req_bit(lt_state, a_byte_idx[2:0], a_bit_idx);
          aux_state <= A_C1;
        end
        A_C1: begin
          aux_tx_p  <= !req_bit(lt_state, a_byte_idx[2:0], a_bit_idx);
          a_bit_idx <= a_bit_idx + 3'd1;
          aux_state <= A_C0;
          if (a_bit_idx == 3'd7) begin
            a_byte_idx <= a_byte_idx + 4'd1;
            if (a_byte_idx[2:0] == (req_has_data(lt_state) ? 3'd4 : 3'd3))
              aux_state <= A_STOP0;
          end
        end
        // --- STOP chips (1,1), then release the pair ---
        A_STOP0: begin
          aux_tx_p  <= 1'b1;
          aux_state <= A_STOP1;
        end
        A_STOP1: begin
          aux_tx_en  <= 1'b0;
          a_timeout  <= '0;
          a_byte_idx <= '0;
          aux_state  <= A_RX_W0;
        end
        // --- RX: wait for the 1->0 transition = chip0 of the first SYNC pair ---
        A_RX_W0:
          if (a_timeout == RX_TIMEOUT) begin
            op_err    <= 1'b1;
            op_done   <= 1'b1;
            aux_state <= A_IDLE;
          end else begin
            a_timeout <= a_timeout + 8'd1;
            if (!aux_rx_p) begin
              a_cur_bit <= 1'b0;
              aux_state <= A_RX_C1;
            end
          end
        // --- RX pairs: chip0 in A_RX_C0, chip1 in A_RX_C1 ---
        A_RX_C0: begin
          a_cur_bit <= aux_rx_p;         // bit = chip0 (802.3)
          aux_state <= A_RX_C1;
        end
        A_RX_C1:
          if (aux_rx_p == a_cur_bit ||                       // Manchester violation
              (a_sync_cnt < 5'd16 && a_cur_bit) ||           // SYNC bit must be 0
              (a_sync_cnt == 5'd16 && !a_cur_bit)) begin     // start bit must be 1
            op_err     <= 1'b1;
            op_done    <= 1'b1;
            a_sync_cnt <= '0;
            a_bit_idx  <= '0;
            aux_state  <= A_IDLE;
          end else begin
            aux_state <= A_RX_C0;
            if (a_sync_cnt != 5'd17) a_sync_cnt <= a_sync_cnt + 5'd1;
            else begin                   // data bit, MSB first
              a_rx_byte <= {a_rx_byte[5:0], a_cur_bit};
              a_bit_idx <= a_bit_idx + 3'd1;
              if (a_bit_idx == 3'd7) begin
                a_byte_idx <= a_byte_idx + 4'd1;
                if (a_byte_idx == 4'd0) begin                // reply header
                  a_nak <= a_rx_byte[6:3] != 4'h0;
                  if (a_rx_byte[6:3] != 4'h0 || rep_len(lt_state) == 4'd0)
                    aux_state <= A_RX_STOP0;
                end else begin
                  op_rdata[8*(a_byte_idx-4'd1) +: 8] <= {a_rx_byte, a_cur_bit};
                  if (a_byte_idx == rep_len(lt_state)) aux_state <= A_RX_STOP0;
                end
              end
            end
          end
        A_RX_STOP0: begin
          a_sync_cnt <= '0;
          if (aux_rx_p) aux_state <= A_RX_STOP1;
          else begin
            op_err    <= 1'b1;
            op_done   <= 1'b1;
            aux_state <= A_IDLE;
          end
        end
        default: begin                   // A_RX_STOP1
          op_err    <= !aux_rx_p || a_nak;
          op_done   <= 1'b1;
          aux_state <= A_IDLE;
        end
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
      retry_cnt   <= 2'd0;
      edid        <= '0;
      edid_valid  <= 1'b0;
    end else if (!sink_present) begin    // HPD low: sink unplugged
      lt_state    <= LT_IDLE;
      lane_active <= 1'b0;
      train_fail  <= 1'b0;
      pat         <= PAT_FILL;
      pat_rst     <= 1'b0;
      op_start    <= 1'b0;
      edid_valid  <= 1'b0;
    end else begin
      op_start <= 1'b0;
      pat_rst  <= 1'b0;
      case (lt_state)
        LT_IDLE: begin
          lane_active <= 1'b1;
          retry_cnt   <= 2'd0;
          op_start    <= 1'b1;
          lt_state    <= LT_CFG_RATE;
        end
        LT_CFG_RATE:
          if (op_done) begin
            if (!op_err) begin
              retry_cnt <= 2'd0;
              op_start  <= 1'b1;
              lt_state  <= LT_CFG_LANE;
            end else if (retry_cnt == RETRY_MAX) lt_state <= LT_FAIL;
            else begin
              retry_cnt <= retry_cnt + 2'd1;
              op_start  <= 1'b1;         // retry the same op
            end
          end
        LT_CFG_LANE:
          if (op_done) begin
            if (!op_err) begin
              retry_cnt <= 2'd0;
              op_start  <= 1'b1;
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
          if (sym_cnt[5] && !pat_rst) begin
            op_start <= 1'b1;
            lt_state <= LT_CR_POLL;
          end
        LT_CR_POLL:
          if (op_done) begin
            if (!op_err && op_rdata[0]) begin   // CR_DONE
              retry_cnt <= 2'd0;
              op_start  <= 1'b1;
              lt_state  <= LT_TPS_SET;
            end else if (retry_cnt == RETRY_MAX) lt_state <= LT_FAIL;
            else begin
              retry_cnt <= retry_cnt + 2'd1;
              pat_rst   <= 1'b1;         // another 32 CR symbols, then poll again
              lt_state  <= LT_CR_WAIT;
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
          if (sym_cnt[5] && !pat_rst) begin
            op_start <= 1'b1;
            lt_state <= LT_TPS_POLL;
          end
        LT_TPS_POLL:
          if (op_done) begin
            if (!op_err && op_rdata[1]) begin   // EQ_DONE
              retry_cnt <= 2'd0;
              op_start  <= 1'b1;
              lt_state  <= LT_EDID_W;
            end else if (retry_cnt == RETRY_MAX) lt_state <= LT_FAIL;
            else begin
              retry_cnt <= retry_cnt + 2'd1;
              pat_rst   <= 1'b1;
              lt_state  <= LT_TPS_WAIT;
            end
          end
        LT_EDID_W:
          if (op_done) begin
            if (!op_err) begin
              retry_cnt <= 2'd0;
              op_start  <= 1'b1;
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
        LT_VIDEO: ;                      // free-running video stream
        default: begin                   // LT_FAIL
          train_fail <= 1'b1;
          pat        <= PAT_FILL;
        end
      endcase
    end
  end

endmodule
