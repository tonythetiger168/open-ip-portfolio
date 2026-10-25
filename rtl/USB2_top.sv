// SPDX-License-Identifier: Apache-2.0
// ============================================================================
// USB 2.0 High-Speed capable device controller (EP0 control + EP1 interrupt IN)
// Implementation scope:
//   * Speed detection (scaled digital model of the chirp handshake): after a
//     bus reset (SE0 >= RST_BITS bit times) the device drives chirp K for
//     CHIRP_K clocks once the host releases SE0, then listens; three host
//     K-J chirp pairs (each chirp >= CHIRP_MIN clocks) within CHIRP_WAIT
//     clocks switch the device to hs_mode, otherwise it stays full speed.
//     hs_mode is cleared by the next bus reset. The packet layer keeps the
//     same NRZI line coding in both speeds (signalling levels not modelled).
//   * SOF tracking: frame_no holds the last frame number, uframe counts the
//     SOFs that repeat it (microframes 0..7 of a frame in high speed).
//   * PHY layer : NRZI decode/encode, bit stuffing (insert 0 after six 1s,
//                 also before EOP; remove stuffed 0 on receive), SE0(2 bit)
//                 + J(1 bit) EOP, dp/dm tri-state pads with output-enable
//   * Protocol  : SYNC field 8'h80 (KJKJKJKK), PID nibble-complement check,
//                 token frame addr[7]+endp[4]+CRC5(poly 0x05),
//                 data frame payload+CRC16(poly 0x8005), generated on the fly,
//                 handshakes ACK/NAK/STALL,
//                 DATA0/DATA1 toggle synchronization (retransmit on lost ACK,
//                 discard-but-ACK on duplicated data)
//   * EP0       : max packet 8 (full speed) / 64 (high speed);
//                 GET_DESCRIPTOR device (18 bytes, bMaxPacketSize0 follows the
//                 speed) and device_qualifier (10 bytes), truncated to
//                 wLength; SET_ADDRESS (after the status stage),
//                 SET_CONFIGURATION(0/1), GET_CONFIGURATION; vendor request
//                 0x40/0x01 presets the EP1 counter to {wIndex, wValue};
//                 anything else is answered with a protocol STALL
//   * EP1       : interrupt IN, 4-byte transfer counter (incremented on ACK),
//                 NAK while unconfigured
//   * irq       : sticky on a token / data packet with bad CRC or stuffing;
//                 cleared by the next good token addressed to the device
// Line rate is parameterized: BIT_CLKS clk cycles per USB bit time (>= 2).
// IP design implementation v1.1 -- Apache-2.0
// ============================================================================
module USB2_top #(
  parameter int BIT_CLKS   = 4,   // clk cycles per USB bit time
  parameter int CHIRP_K    = 64,  // device chirp K length (clk)
  parameter int CHIRP_MIN  = 16,  // minimum host chirp length (clk)
  parameter int CHIRP_WAIT = 512  // time allowed for the host chirps (clk)
)(
  input  logic        clk,
  input  logic        rst_n,
  inout  wire         dp,        // D+ tri-state pad (device drives when tx_oe/chirp)
  inout  wire         dm,        // D- tri-state pad
  output logic        irq,       // protocol error event (sticky until next good token)
  output logic        hs_mode,   // 1 after a successful chirp handshake
  output logic [10:0] frame_no,  // last SOF frame number
  output logic [2:0]  uframe     // SOFs seen with this frame number - 1
);

  // ------------------------------------------------------------------
  // constants
  // ------------------------------------------------------------------
  localparam logic [1:0] LN_SE0 = 2'b00;  // {dp,dm}
  localparam logic [1:0] LN_K   = 2'b01;
  localparam logic [1:0] LN_J   = 2'b10;

  localparam logic [3:0] PID_OUT   = 4'h1;
  localparam logic [3:0] PID_IN    = 4'h9;
  localparam logic [3:0] PID_SOF   = 4'h5;
  localparam logic [3:0] PID_SETUP = 4'hD;
  localparam logic [3:0] PID_DATA0 = 4'h3;
  localparam logic [3:0] PID_DATA1 = 4'hB;
  localparam logic [3:0] PID_ACK   = 4'h2;
  localparam logic [3:0] PID_NAK   = 4'hA;
  localparam logic [3:0] PID_STALL = 4'hE;

  localparam int BTW        = $clog2(BIT_CLKS);
  localparam int SAMPLE_PT  = BIT_CLKS/2 - 1;   // bit-center sample point
  localparam int TURNAROUND = 4*BIT_CLKS;       // RX EOP -> TX SOP gap
  localparam int TAW        = $clog2(TURNAROUND);
  localparam int EOPW       = $clog2(2*BIT_CLKS);
  localparam int ACK_TO     = 32*BIT_CLKS;      // handshake timeout (clk)
  localparam int ATW        = $clog2(ACK_TO + 1);
  localparam int RST_BITS   = 32;               // bus reset: SE0 >= 32 bit times
  localparam int RST_CLKS   = RST_BITS*BIT_CLKS;
  localparam int RSW        = $clog2(RST_CLKS + 1);
  // descriptor length: device 18, device_qualifier 10
  function automatic logic [4:0] dlen_max(input logic q);
    dlen_max = q ? 5'd10 : 5'd18;
  endfunction

  // ------------------------------------------------------------------
  // tri-state pads
  // ------------------------------------------------------------------
  logic tx_oe;
  logic tx_dp, tx_dm;
  logic ch_oe;                        // chirp K drive (dp=0, dm=1)
  wire  drv_oe = tx_oe | ch_oe;
  wire  dp_i = dp;
  wire  dm_i = dm;
  assign dp = drv_oe ? (tx_oe & tx_dp) : 1'bz;
  assign dm = drv_oe ? (ch_oe | tx_dm) : 1'bz;

  wire [1:0] line    = {dp_i, dm_i};
  wire       line_jk = dp_i ^ dm_i;   // J or K (differential valid)

  // ------------------------------------------------------------------
  // CRC helpers (LSB-first reflected LFSRs, USB conventions)
  // ------------------------------------------------------------------
  function automatic logic [4:0] crc5_bit(input logic [4:0] c, input logic b);
    if (c[0] ^ b) crc5_bit = (c >> 1) ^ 5'h14;   // reflected poly of x^5+x^2+1
    else          crc5_bit = (c >> 1);
  endfunction

  function automatic logic [15:0] crc16_byte(input logic [15:0] c, input logic [7:0] d);
    logic [15:0] r;
    r = c;
    for (int k = 0; k < 8; k++)
      r = (r[0] ^ d[k]) ? ((r >> 1) ^ 16'hA001) : (r >> 1);  // reflected 0x8005
    crc16_byte = r;
  endfunction

  // 18-byte device descriptor (q = 0) / 10-byte device_qualifier (q = 1);
  // bMaxPacketSize0 is 64 at high speed, 8 at full speed, and the other way
  // round in the qualifier (it describes the other speed)
  function automatic logic [7:0] desc_byte(input logic q, input logic hs, input logic [4:0] i);
    if (q)
      case (i)
        5'd0:    desc_byte = 8'h0A;  // bLength=10
        5'd1:    desc_byte = 8'h06;  // DEVICE_QUALIFIER
        5'd3:    desc_byte = 8'h02;  // bcdUSB 2.00
        5'd7:    desc_byte = hs ? 8'h08 : 8'h40;
        5'd8:    desc_byte = 8'h01;  // bNumConfigurations=1
        default: desc_byte = 8'h00;
      endcase
    else
    case (i)
      5'd0:    desc_byte = 8'h12;  // bLength=18
      5'd1:    desc_byte = 8'h01;  // bDescriptorType=DEVICE
      5'd2:    desc_byte = 8'h00;  // bcdUSB 2.00
      5'd3:    desc_byte = 8'h02;
      5'd7:    desc_byte = hs ? 8'h40 : 8'h08;  // bMaxPacketSize0
      5'd8:    desc_byte = 8'h09;  // idVendor 0x1209
      5'd9:    desc_byte = 8'h12;
      5'd10:   desc_byte = 8'h01;  // idProduct 0x0001
      5'd13:   desc_byte = 8'h01;  // bcdDevice 1.00
      5'd17:   desc_byte = 8'h01;  // bNumConfigurations=1
      default: desc_byte = 8'h00;  // class/subclass/protocol, strings
    endcase
  endfunction

  // ==================================================================
  // bus reset detect (SE0 held for RST_CLKS)
  // ==================================================================
  logic [RSW-1:0] se0_cnt;
  logic           bus_rst;
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      se0_cnt <= '0;
      bus_rst <= 1'b0;
    end else begin
      bus_rst <= 1'b0;
      if (line != LN_SE0 || drv_oe) se0_cnt <= '0;
      else if (se0_cnt != RSW'(RST_CLKS)) begin
        se0_cnt <= se0_cnt + 1'b1;
        bus_rst <= (se0_cnt == RSW'(RST_CLKS - 1));
      end
    end
  end

  // ==================================================================
  // speed detection: device chirp K after bus reset, host K-J chirps
  // ==================================================================
  localparam int CKW = $clog2(((CHIRP_K > CHIRP_WAIT) ? CHIRP_K : CHIRP_WAIT) + 1);
  localparam int CMW = $clog2(CHIRP_MIN);
  typedef enum logic [2:0] {CH_FS, CH_RST, CH_K, CH_LISTEN, CH_HS} ch_t;
  ch_t            ch;
  logic [CKW-1:0] ch_cnt;
  logic [CMW-1:0] ch_run;     // clocks the expected chirp level has lasted
  logic [2:0]     ch_n;       // host chirps counted
  logic           ch_exp_j;   // next host chirp expected: 0 = K, 1 = J

  assign ch_oe = (ch == CH_K);

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      ch       <= CH_FS;
      ch_cnt   <= '0;
      ch_run   <= '0;
      ch_n     <= 3'd0;
      ch_exp_j <= 1'b0;
      hs_mode  <= 1'b0;
    end else if (bus_rst) begin
      ch      <= CH_RST;
      hs_mode <= 1'b0;
    end else begin
      case (ch)
        CH_RST: if (line != LN_SE0) begin      // host released reset
          ch     <= CH_K;
          ch_cnt <= '0;
        end
        CH_K: begin                            // device chirp K
          ch_cnt <= ch_cnt + 1'b1;
          if (ch_cnt == CKW'(CHIRP_K - 1)) begin
            ch       <= CH_LISTEN;
            ch_cnt   <= '0;
            ch_run   <= '0;
            ch_n     <= 3'd0;
            ch_exp_j <= 1'b0;
          end
        end
        CH_LISTEN: begin                       // count host chirps K J K J K J
          ch_cnt <= ch_cnt + 1'b1;
          if (ch_cnt == CKW'(CHIRP_WAIT)) ch <= CH_FS;   // no HS host
          else if (line == (ch_exp_j ? LN_J : LN_K)) begin
            ch_run <= ch_run + 1'b1;
            if (ch_run == CMW'(CHIRP_MIN - 1)) begin
              ch_run   <= '0;
              ch_exp_j <= ~ch_exp_j;
              ch_n     <= ch_n + 3'd1;
              if (ch_n == 3'd5) begin
                ch      <= CH_HS;
                hs_mode <= 1'b1;
              end
            end
          end else ch_run <= '0;
        end
        default: ;                             // CH_FS / CH_HS until bus reset
      endcase
    end
  end

  // ==================================================================
  // RX path : bit timer + NRZI decode + unstuff + frame disassembly
  // ==================================================================
  logic [1:0]     line_d;
  logic [BTW-1:0] bt;
  wire            rx_edge = line_jk && (line_d[1] ^ line_d[0]) && (line != line_d);
  wire            rx_sample;

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      line_d <= LN_J;
      bt     <= '0;
    end else begin
      line_d <= line;
      if (rx_edge || bt == BTW'(BIT_CLKS-1)) bt <= '0;  // edge resync
      else                                   bt <= bt + 1'b1;
    end
  end

  typedef enum logic [2:0] {RS_IDLE, RS_SYNC, RS_PID, RS_TOKEN,
                            RS_DATA, RS_DUMP, RS_SE0} rs_t;
  rs_t          rs;
  logic         prev_lvl;
  logic [2:0]   ones;
  logic         stuff_err;
  logic [3:0]   bcnt;
  logic [14:0]  shifter;        // bits received so far, newest at [14]
  logic [4:0]   crc5_r;
  logic [15:0]  crc16_r;
  logic [7:0]   b_d1, b_d2;
  logic [4:0]   dlen;
  logic [7:0]   rx_buf [0:7];
  logic         field_token;    // RS_DUMP was entered with complete token
  logic         tok_crc_ok_r;
  // RX -> control interface
  logic         rx_done;
  logic [3:0]   rx_pid;
  logic         rx_tok_ok;
  logic         rx_data_ok;
  logic [10:0]  rx_tokfield;
  logic [4:0]   rx_plen;

  typedef enum logic [2:0] {TS_IDLE, TS_WAIT, TS_RUN, TS_EOP0, TS_EOPJ} ts_t;
  ts_t         ts;
  // never receive our own transmit or the chirp handshake
  wire rx_en    = (ts == TS_IDLE) && (ch == CH_FS || ch == CH_HS);
  assign rx_sample = (bt == BTW'(SAMPLE_PT)) && line_jk;
  wire nrzi    = (dp_i == prev_lvl);      // no transition -> logic 1
  wire [7:0] byte_v = {nrzi, shifter[14:8]};   // bit i of byte sits at shifter[7+i]

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      rs          <= RS_IDLE;
      prev_lvl    <= 1'b1;
      ones        <= 3'd0;
      stuff_err   <= 1'b0;
      bcnt        <= 4'd0;
      shifter     <= 15'd0;
      crc5_r      <= 5'h1F;
      crc16_r     <= 16'hFFFF;
      b_d1        <= 8'd0;
      b_d2        <= 8'd0;
      dlen        <= 5'd0;
      field_token <= 1'b0;
      tok_crc_ok_r<= 1'b0;
      rx_done     <= 1'b0;
      rx_pid      <= 4'd0;
      rx_tok_ok   <= 1'b0;
      rx_data_ok  <= 1'b0;
      rx_tokfield <= 11'd0;
      rx_plen     <= 5'd0;
      for (int i = 0; i < 8; i++) rx_buf[i] <= 8'd0;
    end else begin
      rx_done <= 1'b0;
      if (!rx_en) begin
        rs <= RS_IDLE;
      end else begin
        if (rx_sample && (rs != RS_IDLE) && (rs != RS_SE0) && (rs != RS_DUMP))
          prev_lvl <= dp_i;
        case (rs)
          // ------------------------------------------------ SOP detect
          RS_IDLE: begin
            if (rx_edge && (line == LN_K)) begin
              rs          <= RS_SYNC;
              prev_lvl    <= 1'b1;       // idle was J
              ones        <= 3'd0;
              stuff_err   <= 1'b0;
              bcnt        <= 4'd0;
              field_token <= 1'b0;
              rx_pid      <= 4'd0;
            end
          end
          // ------------------------------------------------ SYNC field
          RS_SYNC: begin
            if (line == LN_SE0) rs <= RS_SE0;
            else if (rx_sample) begin
              shifter <= {nrzi, shifter[14:1]};
              bcnt    <= {1'b0, bcnt[2:0] + 3'd1};
              if (bcnt[2:0] == 3'd7) begin
                if (byte_v == 8'h80) begin rs <= RS_PID; ones <= 3'd0; end
                else                     rs <= RS_DUMP;  // bad sync, drop
              end
            end
          end
          // ------------------------------------------------ PID byte
          RS_PID: begin
            if (line == LN_SE0) begin
              rx_done <= 1'b1;           // truncated packet, pid invalid
              rs      <= RS_SE0;
            end else if (rx_sample) begin
              if (ones == 3'd6) begin
                ones <= 3'd0;
                if (nrzi) stuff_err <= 1'b1;
              end else begin
                shifter <= {nrzi, shifter[14:1]};
                ones    <= nrzi ? ones + 3'd1 : 3'd0;
                bcnt    <= {1'b0, bcnt[2:0] + 3'd1};
                if (bcnt[2:0] == 3'd7) begin
                  if (byte_v[7:4] == ~byte_v[3:0]) begin
                    rx_pid <= byte_v[3:0];
                    case (byte_v[3:0])
                      PID_OUT, PID_IN, PID_SETUP, PID_SOF: begin
                        rs     <= RS_TOKEN;
                        crc5_r <= 5'h1F;
                      end
                      PID_DATA0, PID_DATA1: begin
                        rs      <= RS_DATA;
                        crc16_r <= 16'hFFFF;
                        dlen    <= 5'd0;
                      end
                      default: rs <= RS_DUMP;   // handshake: PID only + EOP
                    endcase
                  end else begin
                    rx_pid <= 4'd0;             // bad PID check nibble
                    rs     <= RS_DUMP;
                  end
                end
              end
            end
          end
          // ------------------------------------------------ token 16 bits
          RS_TOKEN: begin
            if (line == LN_SE0) begin
              rx_done   <= 1'b1;         // short token -> crc bad
              rx_tok_ok <= 1'b0;
              rs        <= RS_SE0;
            end else if (rx_sample) begin
              if (ones == 3'd6) begin
                ones <= 3'd0;
                if (nrzi) stuff_err <= 1'b1;
              end else begin
                shifter <= {nrzi, shifter[14:1]};
                ones    <= nrzi ? ones + 3'd1 : 3'd0;
                if (bcnt < 4'd11) crc5_r <= crc5_bit(crc5_r, nrzi);
                bcnt    <= bcnt + 4'd1;
                if (bcnt == 4'd15) begin
                  rx_tokfield  <= shifter[10:0];             // bit i at position i
                  tok_crc_ok_r <= ({nrzi, shifter[14:11]} == (crc5_r ^ 5'h1F));
                  field_token  <= 1'b1;
                  rs           <= RS_DUMP;     // wait for EOP
                end
              end
            end
          end
          // ------------------------------------------------ data payload+CRC
          RS_DATA: begin
            if (line == LN_SE0) begin
              rx_done    <= 1'b1;
              rx_data_ok <= !stuff_err && (dlen >= 5'd2) &&
                            (b_d2 == (crc16_r[7:0] ^ 8'hFF)) &&
                            (b_d1 == (crc16_r[15:8] ^ 8'hFF));
              rx_plen    <= (dlen >= 5'd2) ? dlen - 5'd2 : 5'd0;
              rs         <= RS_SE0;
            end else if (rx_sample) begin
              if (ones == 3'd6) begin
                ones <= 3'd0;
                if (nrzi) stuff_err <= 1'b1;
              end else begin
                shifter <= {nrzi, shifter[14:1]};
                ones    <= nrzi ? ones + 3'd1 : 3'd0;
                bcnt    <= {1'b0, bcnt[2:0] + 3'd1};
                if (bcnt[2:0] == 3'd7) begin
                  if (dlen >= 5'd2) crc16_r <= crc16_byte(crc16_r, b_d2);
                  b_d2 <= b_d1;
                  b_d1 <= byte_v;
                  if (dlen < 5'd8) rx_buf[dlen[2:0]] <= byte_v;
                  if (dlen != 5'd31) dlen <= dlen + 5'd1;
                end
              end
            end
          end
          // ------------------------------------------------ discard to EOP
          RS_DUMP: begin
            if (line == LN_SE0) begin
              rx_done   <= 1'b1;
              rx_tok_ok <= field_token && tok_crc_ok_r && !stuff_err;
              rs        <= RS_SE0;
            end
          end
          // ------------------------------------------------ EOP: SE0 then J
          default: begin                       // RS_SE0
            if (line == LN_J) rs <= RS_IDLE;
          end
        endcase
      end
    end
  end

  // ==================================================================
  // TX path : NRZI encode + bit stuffing + EOP; bytes generated on the fly
  //   byte index 0 = SYNC, 1 = PID, 2.. payload, then CRC16 (data packets)
  // ==================================================================
  localparam logic [2:0] TK_HS = 3'd0, TK_ZLP = 3'd1, TK_DESC = 3'd2, TK_CFG = 3'd3,
                         TK_CNT = 3'd4;
  logic [TAW-1:0]  wait_cnt;
  logic [BTW-1:0]  tbt;
  logic [2:0]      t_ones;
  logic            t_stuff;
  logic [4:0]      byte_ptr;
  logic [2:0]      bit_ptr;
  logic            t_lvl;
  logic [EOPW-1:0] eop_cnt;
  logic            eop_pend;   // final bit-time in flight, EOP at next boundary
  logic            tx_start;
  logic            tx_done;
  logic [15:0]     tx_crc;
  // packet descriptor (from the control FSM)
  logic [2:0]      tx_kind;
  logic [2:0]      tx_pid;     // PID bits {3,2,0}: bit 1 is set in every PID sent
  logic [4:0]      tx_n;       // payload bytes
  logic            d_q;        // descriptor: 0 device, 1 device_qualifier
  logic            cfg;        // configured (SET_CONFIGURATION 1)
  logic [4:0]      d_len, d_off;  // control IN data stage length / progress
  logic [31:0]     ep1_cnt;

  wire [4:0] last_ptr = (tx_kind == TK_HS) ? 5'd1 : tx_n + 5'd3;
  wire [4:0] pay_i    = byte_ptr - 5'd2;

  logic [7:0] t_byte;
  always_comb begin
    if (byte_ptr == 5'd0)      t_byte = 8'h80;
    else if (byte_ptr == 5'd1) t_byte = {~tx_pid[2:1], 1'b0, ~tx_pid[0],
                                          tx_pid[2:1], 1'b1, tx_pid[0]};
    else if (pay_i < tx_n)
      case (tx_kind)
        TK_DESC: t_byte = desc_byte(d_q, hs_mode, d_off + pay_i);   // d_off steady while sending
        TK_CFG:  t_byte = {7'd0, cfg};
        default: t_byte = ep1_cnt[8*pay_i[1:0] +: 8];
      endcase
    else if (pay_i == tx_n)    t_byte = ~tx_crc[7:0];
    else                       t_byte = ~tx_crc[15:8];
  end
  wire t_bit = t_byte[bit_ptr];

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      ts        <= TS_IDLE;
      wait_cnt  <= '0;
      tbt       <= '0;
      t_ones    <= 3'd0;
      t_stuff   <= 1'b0;
      byte_ptr  <= 5'd0;
      bit_ptr   <= 3'd0;
      t_lvl     <= 1'b1;
      eop_cnt   <= '0;
      eop_pend  <= 1'b0;
      tx_oe     <= 1'b0;
      tx_done   <= 1'b0;
      tx_crc    <= 16'hFFFF;
    end else begin
      tx_done <= 1'b0;
      case (ts)
        TS_IDLE: begin
          if (tx_start) begin
            ts       <= TS_WAIT;
            wait_cnt <= '0;
          end
        end
        TS_WAIT: begin                       // inter-packet turnaround gap
          if (wait_cnt == TAW'(TURNAROUND - 1)) begin
            ts       <= TS_RUN;
            tx_oe    <= 1'b1;
            t_lvl    <= 1'b0;                // first SYNC bit is 0 -> K
            tbt      <= '0;
            t_ones   <= 3'd0;
            t_stuff  <= 1'b0;
            byte_ptr <= 5'd0;
            bit_ptr  <= 3'd1;                // bit0 pre-applied above
            eop_pend <= 1'b0;
            tx_crc   <= 16'hFFFF;
          end else wait_cnt <= wait_cnt + 1'b1;
        end
        TS_RUN: begin
          if (tbt == BTW'(BIT_CLKS-1)) begin
            tbt <= '0;
            if (t_stuff) begin               // emit stuffed 0 (also before EOP)
              t_lvl   <= ~t_lvl;
              t_stuff <= 1'b0;
              t_ones  <= 3'd0;
            end else if (eop_pend) begin     // final bit-time complete -> EOP
              ts       <= TS_EOP0;
              eop_cnt  <= '0;
              eop_pend <= 1'b0;
            end else begin
              if (!t_bit) t_lvl <= ~t_lvl;   // NRZI: 0 toggles
              if (byte_ptr != 5'd0) begin    // stuffing after SYNC field
                if (t_bit) begin
                  if (t_ones == 3'd5) t_stuff <= 1'b1;
                  t_ones <= t_ones + 3'd1;
                end else t_ones <= 3'd0;
              end
              if (bit_ptr == 3'd7) begin
                if (byte_ptr >= 5'd2 && pay_i < tx_n) tx_crc <= crc16_byte(tx_crc, t_byte);
                if (byte_ptr == last_ptr) eop_pend <= 1'b1;   // last bit-time
                else                      byte_ptr <= byte_ptr + 5'd1;
              end
              bit_ptr <= bit_ptr + 3'd1;
            end
          end else tbt <= tbt + 1'b1;
        end
        TS_EOP0: begin                       // SE0 for 2 bit times
          eop_cnt <= eop_cnt + 1'b1;
          if (eop_cnt == EOPW'(2*BIT_CLKS - 1)) ts <= TS_EOPJ;
        end
        default: begin                       // TS_EOPJ: J for 1 bit time, release
          eop_cnt <= eop_cnt + 1'b1;
          if (eop_cnt == EOPW'(BIT_CLKS - 1)) begin
            ts      <= TS_IDLE;
            tx_oe   <= 1'b0;
            tx_done <= 1'b1;
          end
        end
      endcase
    end
  end

  always_comb begin
    case (ts)
      TS_EOP0:  begin tx_dp = 1'b0;  tx_dm = 1'b0;  end
      TS_EOPJ:  begin tx_dp = 1'b1;  tx_dm = 1'b0;  end
      default:  begin tx_dp = t_lvl; tx_dm = ~t_lvl; end
    endcase
  end

  // ==================================================================
  // protocol control FSM
  // ==================================================================
  typedef enum logic [1:0] {CS_IDLE, CS_TX, CS_WACK} cs_t;
  // EP0 control transfer in progress
  typedef enum logic [2:0] {RQ_NONE, RQ_DESC, RQ_CFGGET, RQ_ADDR, RQ_CFGSET,
                            RQ_CNTSET, RQ_STALL} rq_t;
  cs_t            cs;
  rq_t            rq;
  logic [6:0]     dev_addr, new_addr;
  logic           new_cfg;
  logic [31:0]    new_cnt;
  logic           expect_ack;
  logic           exp_data, exp_setup, pend_stall;
  logic           ep0in_tgl, ep1in_tgl, out_tgl;
  logic [ATW-1:0] ack_timer;

  wire        wrong_tgl = ((rx_pid == PID_DATA1) != (exp_setup ? 1'b0 : out_tgl));
  wire        tok_me    = rx_tok_ok && (rx_tokfield[6:0] == dev_addr);
  wire [3:0]  tok_ep    = rx_tokfield[10:7];
  wire [4:0]  d_left    = d_len - d_off;
  // max packet size 8 / 64: a high-speed data stage (<= 18 bytes) is one packet
  wire [4:0]  d_n       = (d_left > 5'd8 && !hs_mode) ? 5'd8 : d_left;
  // SETUP packet fields
  wire [7:0]  s_bm  = rx_buf[0];
  wire [7:0]  s_rq  = rx_buf[1];
  wire [15:0] s_val = {rx_buf[3], rx_buf[2]};
  wire [15:0] s_idx = {rx_buf[5], rx_buf[4]};
  wire [15:0] s_len = {rx_buf[7], rx_buf[6]};

  // decode a SETUP request
  function automatic rq_t setup_rq(input logic [7:0] bm, input logic [7:0] rq_,
                                   input logic [15:0] val, input logic [15:0] idx,
                                   input logic [15:0] len);
    if (bm == 8'h80 && rq_ == 8'h06 && (val == 16'h0100 || val == 16'h0600))
                                                              setup_rq = RQ_DESC;
    else if (bm == 8'h80 && rq_ == 8'h08 && val == 16'h0 && idx == 16'h0 && len == 16'd1)
                                                              setup_rq = RQ_CFGGET;
    else if (bm == 8'h00 && rq_ == 8'h05 && val < 16'd128 && idx == 16'h0 && len == 16'h0)
                                                              setup_rq = RQ_ADDR;
    else if (bm == 8'h00 && rq_ == 8'h09 && val < 16'd2 && idx == 16'h0 && len == 16'h0)
                                                              setup_rq = RQ_CFGSET;
    else if (bm == 8'h40 && rq_ == 8'h01 && len == 16'h0)     setup_rq = RQ_CNTSET;
    else                                                      setup_rq = RQ_STALL;
  endfunction

  // start a response packet (pid[1] is 1 for every PID the device sends)
  /* verilator lint_off UNUSEDSIGNAL */
  task automatic send(input logic [2:0] k, input logic [3:0] pid, input logic [4:0] n,
                      input logic ack);
    tx_kind    <= k;
    tx_pid     <= {pid[3:2], pid[0]};
    tx_n       <= n;
    tx_start   <= 1'b1;
    expect_ack <= ack;
    cs         <= CS_TX;
  endtask
  /* verilator lint_on UNUSEDSIGNAL */

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      cs         <= CS_IDLE;
      rq         <= RQ_NONE;
      dev_addr   <= 7'd0;
      new_addr   <= 7'd0;
      cfg        <= 1'b0;
      new_cfg    <= 1'b0;
      new_cnt    <= 32'd0;
      d_len      <= 5'd0;
      d_off      <= 5'd0;
      expect_ack <= 1'b0;
      exp_data   <= 1'b0;
      exp_setup  <= 1'b0;
      pend_stall <= 1'b0;
      ep0in_tgl  <= 1'b0;
      ep1in_tgl  <= 1'b0;
      out_tgl    <= 1'b0;
      ep1_cnt    <= 32'd0;
      ack_timer  <= '0;
      tx_start   <= 1'b0;
      tx_kind    <= TK_HS;
      tx_pid     <= 3'd0;
      tx_n       <= 5'd0;
      d_q        <= 1'b0;
      frame_no   <= 11'd0;
      uframe     <= 3'd0;
      irq        <= 1'b0;
    end else if (bus_rst) begin            // USB bus reset: default state
      cs         <= CS_IDLE;
      rq         <= RQ_NONE;
      dev_addr   <= 7'd0;
      cfg        <= 1'b0;
      exp_data   <= 1'b0;
      ep0in_tgl  <= 1'b0;
      ep1in_tgl  <= 1'b0;
      out_tgl    <= 1'b0;
      tx_start   <= 1'b0;
    end else begin
      tx_start <= 1'b0;
      case (cs)
        // -------------------------------------------------- packet dispatch
        CS_IDLE: if (rx_done) begin
          case (rx_pid)
            PID_IN: begin
              exp_data <= 1'b0;
              if (!rx_tok_ok) irq <= 1'b1;            // bad CRC5: no response
              else if (tok_me) begin
                irq <= 1'b0;
                if (tok_ep == 4'd0) begin
                  case (rq)
                    RQ_DESC:
                      send(TK_DESC, ep0in_tgl ? PID_DATA1 : PID_DATA0, d_n, 1'b1);
                    RQ_CFGGET:
                      send(TK_CFG, ep0in_tgl ? PID_DATA1 : PID_DATA0, d_n, 1'b1);
                    RQ_ADDR, RQ_CFGSET, RQ_CNTSET:            // status stage
                      send(TK_ZLP, ep0in_tgl ? PID_DATA1 : PID_DATA0, 5'd0, 1'b1);
                    default: send(TK_HS, PID_STALL, 5'd0, 1'b0);
                  endcase
                end else if (tok_ep == 4'd1) begin
                  if (cfg) send(TK_CNT, ep1in_tgl ? PID_DATA1 : PID_DATA0, 5'd4, 1'b1);
                  else     send(TK_HS, PID_NAK, 5'd0, 1'b0);
                end else   send(TK_HS, PID_STALL, 5'd0, 1'b0);  // no such endpoint
              end
            end
            PID_OUT, PID_SETUP: begin
              if (!rx_tok_ok) irq <= 1'b1;            // bad CRC5: no response
              else if (tok_me) begin
                irq        <= 1'b0;
                exp_data   <= 1'b1;
                exp_setup  <= (rx_pid == PID_SETUP);
                pend_stall <= (tok_ep != 4'd0) ||
                              (rx_pid == PID_OUT && rq == RQ_STALL);
              end
            end
            PID_DATA0, PID_DATA1: if (exp_data) begin
              exp_data <= 1'b0;
              if (!rx_data_ok) irq <= 1'b1;           // bad CRC16: no response
              else if (pend_stall) send(TK_HS, PID_STALL, 5'd0, 1'b0);
              else begin
                send(TK_HS, PID_ACK, 5'd0, 1'b0);     // ACK (even if duplicated)
                if (!wrong_tgl) begin                 // apply only in-sequence data
                  out_tgl <= exp_setup ? 1'b1 : ~out_tgl;
                  if (exp_setup) begin
                    ep0in_tgl <= 1'b1;                // data/status IN: DATA1 first
                    d_off     <= 5'd0;
                    new_addr  <= s_val[6:0];
                    new_cfg   <= s_val[0];
                    new_cnt   <= {s_idx, s_val};
                    d_q       <= (s_val[15:8] == 8'h06);   // device_qualifier
                    d_len     <= (s_len > {11'd0, dlen_max(s_val[15:8] == 8'h06)})
                                 ? dlen_max(s_val[15:8] == 8'h06) : s_len[4:0];
                    rq        <= (rx_plen != 5'd8) ? RQ_STALL :
                                 setup_rq(s_bm, s_rq, s_val, s_idx, s_len);
                    if (s_bm == 8'h80 && s_rq == 8'h08) d_len <= 5'd1;
                  end else if (rq == RQ_DESC || rq == RQ_CFGGET)
                    rq <= RQ_NONE;                    // OUT status stage done
                end
              end
            end
            PID_SOF: begin                            // frame / microframe tracking
              if (!rx_tok_ok) irq <= 1'b1;
              else if (rx_tokfield == frame_no) uframe <= uframe + 3'd1;
              else begin
                frame_no <= rx_tokfield;
                uframe   <= 3'd0;
              end
            end
            default: ;                                // handshakes: ignore
          endcase
        end
        // -------------------------------------------------- transmit in flight
        CS_TX: if (tx_done) begin
          cs        <= expect_ack ? CS_WACK : CS_IDLE;
          ack_timer <= ATW'(ACK_TO);
        end
        // -------------------------------------------------- await host handshake
        default: begin                                // CS_WACK
          if (rx_done) begin
            cs <= CS_IDLE;
            if (rx_pid == PID_ACK) begin              // advance toggle / state
              case (tx_kind)
                TK_CNT: begin
                  ep1in_tgl <= ~ep1in_tgl;
                  ep1_cnt   <= ep1_cnt + 32'd1;
                end
                TK_ZLP: begin
                  ep0in_tgl <= ~ep0in_tgl;
                  rq        <= RQ_NONE;
                  if (rq == RQ_ADDR)   dev_addr <= new_addr;
                  if (rq == RQ_CFGSET) cfg      <= new_cfg;
                  if (rq == RQ_CNTSET) ep1_cnt  <= new_cnt;
                end
                default: begin                        // control IN data
                  ep0in_tgl <= ~ep0in_tgl;
                  d_off     <= d_off + tx_n;
                end
              endcase
            end                                       // NAK/other: resend later
          end else if (ack_timer == '0) cs <= CS_IDLE;
          else ack_timer <= ack_timer - 1'b1;
        end
      endcase
    end
  end

endmodule
