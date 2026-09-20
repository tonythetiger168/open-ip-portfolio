// SPDX-License-Identifier: Apache-2.0
// ============================================================================
// USB 2.0 High-Speed device controller (EP0 control read + EP1 interrupt IN)
// Implementation scope:
//   * HS upgrade: post-reset chirp handshake (host K detected by level
//     timing, device answers 3 K/J chirp pairs -> hs_mode), microframe
//     SOF tracking (frame number register + microframe counter, readable
//     on output ports)
//   * Packet layer identical to USB 1.1 FS device:
//   * PHY layer : NRZI decode/encode, bit stuffing (insert 0 after six 1s,
//                 remove stuffed 0 on receive), SE0(2 bit)+J(1 bit) EOP,
//                 dp/dm tri-state pads with output-enable
//   * Protocol  : SYNC field 8'h80 (KJKJKJKK), PID nibble-complement check,
//                 token frame addr[7]+endp[4]+CRC5(poly 0x05),
//                 data frame payload+CRC16(poly 0x8005),
//                 handshakes ACK/NAK/STALL,
//                 DATA0/DATA1 toggle synchronization (retransmit on lost ACK,
//                 discard-but-ACK on duplicated data)
//   * Function  : EP0 GET_DESCRIPTOR (fixed 8-byte device descriptor),
//                 EP1 interrupt IN (4-byte transfer counter),
//                 SETUP data stage written into 8x8 register file
// Line rate is parameterized: BIT_CLKS clk cycles per USB bit time.
// IP design implementation v1.0 -- Apache-2.0
// ============================================================================
module USB2_top #(
  parameter int DW = 32,        // retained framework parameter (data width)
  parameter int AW = 32,        // retained framework parameter (address width)
  parameter int BIT_CLKS = 4,   // clk cycles per USB bit time
  parameter int CHIRP_DET = 48, // host chirp-K detect threshold (clk)
  parameter int CHIRP_LEN = 32  // device chirp K/J duration (clk)
)(
  input  logic        clk,
  input  logic        rst_n,
  inout  wire         dp,        // D+ tri-state pad (device drives when tx_oe/chirp)
  inout  wire         dm,        // D- tri-state pad
  output logic        irq,       // protocol error event (sticky until next good token)
  output logic        hs_mode,   // 1 after HS chirp handshake completes
  output logic [10:0] frame_no,  // last SOF frame number
  output logic [2:0]  uframe     // microframe counter (SOF count mod 8)
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

  localparam logic [6:0] DEV_ADDR   = 7'd0;             // default address
  localparam int         SAMPLE_PT  = BIT_CLKS/2 - 1;   // bit-center sample point
  localparam int         TURNAROUND = 4*BIT_CLKS;       // RX EOP -> TX SOP gap
  localparam logic [7:0] ACK_TO     = 8'd200;           // handshake timeout (clk)

  // ------------------------------------------------------------------
  // tri-state pads (TX engine or chirp FSM may drive)
  // ------------------------------------------------------------------
  logic tx_oe;
  logic tx_dp, tx_dm;
  logic ch_oe;
  logic ch_dp, ch_dm;
  wire  drv_oe = tx_oe | ch_oe;
  wire  drv_dp = tx_oe ? tx_dp : ch_dp;
  wire  drv_dm = tx_oe ? tx_dm : ch_dm;
  wire  dp_i = dp;
  wire  dm_i = dm;
  assign dp = drv_oe ? drv_dp : 1'bz;
  assign dm = drv_oe ? drv_dm : 1'bz;

  wire [1:0] line    = {dp_i, dm_i};
  wire       line_jk = dp_i ^ dm_i;   // J or K (differential valid)

  // ==================================================================
  // HS chirp handshake: detect sustained host chirp K after reset,
  // answer with 3 K/J chirp pairs, then enter hs_mode
  // ==================================================================
  typedef enum logic [1:0] {CH_WAITK, CH_WAITJ, CH_DRIVE, CH_DONE} ch_t;
  ch_t        ch;
  logic [7:0] ch_cnt;
  logic [2:0] ch_idx;     // chirp index 0..5 (3 K/J pairs)
  logic       ch_lvl;     // current chirp level: 0=K, 1=J

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      ch      <= CH_WAITK;
      ch_cnt  <= 8'd0;
      ch_idx  <= 3'd0;
      ch_lvl  <= 1'b0;
      ch_oe   <= 1'b0;
      hs_mode <= 1'b0;
    end else begin
      case (ch)
        CH_WAITK: begin                        // time host chirp K
          if (line == LN_K) begin
            if (ch_cnt == CHIRP_DET-1) begin
              ch     <= CH_WAITJ;
              ch_cnt <= 8'd0;
            end else ch_cnt <= ch_cnt + 8'd1;
          end else ch_cnt <= 8'd0;
        end
        CH_WAITJ: begin                        // host released chirp K
          if (line == LN_J) begin
            ch     <= CH_DRIVE;
            ch_cnt <= 8'd0;
            ch_idx <= 3'd0;
            ch_lvl <= 1'b0;                    // first device chirp is K
            ch_oe  <= 1'b1;
          end
        end
        CH_DRIVE: begin                        // 3 K/J chirp pairs
          if (ch_cnt == CHIRP_LEN-1) begin
            ch_cnt <= 8'd0;
            if (ch_idx == 3'd5) begin
              ch      <= CH_DONE;
              ch_oe   <= 1'b0;
              hs_mode <= 1'b1;
            end else begin
              ch_idx <= ch_idx + 3'd1;
              ch_lvl <= ~ch_lvl;
            end
          end else ch_cnt <= ch_cnt + 8'd1;
        end
        CH_DONE: ;                             // hs_mode stays until reset
        default: ch <= CH_WAITK;
      endcase
    end
  end

  always_comb begin
    ch_dp = ch_lvl;      // chirp J: dp=1,dm=0 ; chirp K: dp=0,dm=1
    ch_dm = ~ch_lvl;
  end

  // ------------------------------------------------------------------
  // CRC helpers (LSB-first reflected LFSRs, USB conventions)
  // ------------------------------------------------------------------
  function automatic logic [4:0] crc5_bit(input logic [4:0] c, input logic b);
    logic fb;
    begin
      fb = c[0] ^ b;
      if (fb) crc5_bit = (c >> 1) ^ 5'h14;   // reflected poly of x^5+x^2+1
      else    crc5_bit = (c >> 1);
    end
  endfunction

  function automatic logic [15:0] crc16_byte(input logic [15:0] c, input logic [7:0] d);
    logic [15:0] r;
    begin
      r = c;
      for (int k = 0; k < 8; k++) begin
        if (r[0] ^ d[k]) r = (r >> 1) ^ 16'hA001;  // reflected poly of 0x8005
        else             r = (r >> 1);
      end
      crc16_byte = r;
    end
  endfunction

  // fixed 8-byte device descriptor prefix returned on EP0 IN
  function automatic logic [7:0] desc_byte(input logic [2:0] i);
    begin
      case (i)
        3'd0:    desc_byte = 8'h12;  // bLength=18
        3'd1:    desc_byte = 8'h01;  // bDescriptorType=DEVICE
        3'd2:    desc_byte = 8'h00;  // bcdUSB LSB (2.00)
        3'd3:    desc_byte = 8'h02;  // bcdUSB MSB
        3'd4:    desc_byte = 8'h00;  // bDeviceClass
        3'd5:    desc_byte = 8'h00;  // bDeviceSubClass
        3'd6:    desc_byte = 8'h00;  // bDeviceProtocol
        default: desc_byte = 8'h08;  // bMaxPacketSize0=8
      endcase
    end
  endfunction

  // ==================================================================
  // RX path : bit timer + NRZI decode + unstuff + frame disassembly
  // ==================================================================
  logic [1:0] line_d;
  logic [3:0] bt;
  wire        rx_edge = line_jk && (line_d[1] ^ line_d[0]) && (line != line_d);
  wire        rx_sample;

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      line_d <= LN_J;
      bt     <= 4'd0;
    end else begin
      line_d <= line;
      if (rx_edge)               bt <= 4'd0;            // edge resync
      else if (bt == BIT_CLKS-1) bt <= 4'd0;
      else                       bt <= bt + 4'd1;
    end
  end

  typedef enum logic [2:0] {RS_IDLE, RS_SYNC, RS_PID, RS_TOKEN,
                            RS_DATA, RS_DUMP, RS_SE0} rs_t;
  rs_t          rs;
  logic         prev_lvl;
  logic [2:0]   ones;
  logic         stuff_err;
  logic [4:0]   bcnt;
  logic [15:0]  shifter;
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

  wire rx_en    = (ts == TS_IDLE) && hs_mode;  // RX after HS handshake, never during own TX
  assign rx_sample = (bt == SAMPLE_PT[3:0]) && line_jk;
  wire nrzi    = (dp_i == prev_lvl);      // no transition -> logic 1
  wire [7:0] byte_v = {nrzi, shifter[15:9]};   // bit i of byte sits at shifter[8+i]

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      rs          <= RS_IDLE;
      prev_lvl    <= 1'b1;
      ones        <= 3'd0;
      stuff_err   <= 1'b0;
      bcnt        <= 5'd0;
      shifter     <= 16'd0;
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
              bcnt        <= 5'd0;
              crc5_r      <= 5'h1F;
              crc16_r     <= 16'hFFFF;
              dlen        <= 5'd0;
              field_token <= 1'b0;
              rx_pid      <= 4'd0;
            end
          end
          // ------------------------------------------------ SYNC field
          RS_SYNC: begin
            if (line == LN_SE0) rs <= RS_SE0;
            else if (rx_sample) begin
              shifter <= {nrzi, shifter[15:1]};
              if (bcnt[2:0] == 3'd7) begin
                bcnt <= 5'd0;
                if (byte_v == 8'h80) begin rs <= RS_PID; ones <= 3'd0; end
                else                     rs <= RS_DUMP;  // bad sync, drop
              end else bcnt <= bcnt + 5'd1;
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
                shifter <= {nrzi, shifter[15:1]};
                ones    <= nrzi ? ones + 3'd1 : 3'd0;
                if (bcnt[2:0] == 3'd7) begin
                  bcnt <= 5'd0;
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
                end else bcnt <= bcnt + 5'd1;
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
                shifter <= {nrzi, shifter[15:1]};
                ones    <= nrzi ? ones + 3'd1 : 3'd0;
                if (bcnt < 5'd11) crc5_r <= crc5_bit(crc5_r, nrzi);
                if (bcnt == 5'd15) begin
                  rx_tokfield  <= {nrzi, shifter[15:1]};    // bit i at position i
                  tok_crc_ok_r <= ({nrzi, shifter[15:12]} == (crc5_r ^ 5'h1F));
                  field_token  <= 1'b1;
                  rs           <= RS_DUMP;     // wait for EOP
                end else bcnt <= bcnt + 5'd1;
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
                shifter <= {nrzi, shifter[15:1]};
                ones    <= nrzi ? ones + 3'd1 : 3'd0;
                if (bcnt[2:0] == 3'd7) begin
                  bcnt <= 5'd0;
                  if (dlen >= 5'd2) crc16_r <= crc16_byte(crc16_r, b_d2);
                  b_d2 <= b_d1;
                  b_d1 <= byte_v;
                  if (dlen < 5'd8) rx_buf[dlen[2:0]] <= byte_v;
                  if (dlen != 5'd31) dlen <= dlen + 5'd1;
                end else bcnt <= bcnt + 5'd1;
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
          RS_SE0: begin
            if (line == LN_J) rs <= RS_IDLE;
          end
          default: rs <= RS_IDLE;
        endcase
      end
    end
  end

  // ==================================================================
  // TX path : NRZI encode + bit stuffing + EOP, byte stream from txb[]
  //   byte_ptr 0            -> SYNC 8'h80
  //   byte_ptr 1..total_cnt -> txb[byte_ptr-1]  (PID, payload, CRC16)
  // ==================================================================
  typedef enum logic [2:0] {TS_IDLE, TS_WAIT, TS_RUN, TS_EOP0, TS_EOPJ} ts_t;
  ts_t         ts;
  logic [4:0]  wait_cnt;
  logic [3:0]  tbt;
  logic [2:0]  t_ones;
  logic        t_stuff;
  logic [4:0]  byte_ptr;
  logic [2:0]  bit_ptr;
  logic [4:0]  total_cnt;
  logic        t_lvl;
  logic [4:0]  eop_cnt;
  logic        eop_pend;   // final bit-time in flight, EOP at next boundary
  logic        tx_start;
  logic        tx_done;
  logic [7:0]  txb [0:15];

  wire [7:0] t_byte = (byte_ptr == 5'd0) ? 8'h80 : txb[byte_ptr[3:0] - 4'd1];
  wire       t_bit  = t_byte[bit_ptr];

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      ts        <= TS_IDLE;
      wait_cnt  <= 5'd0;
      tbt       <= 4'd0;
      t_ones    <= 3'd0;
      t_stuff   <= 1'b0;
      byte_ptr  <= 5'd0;
      bit_ptr   <= 3'd0;
      total_cnt <= 5'd0;
      t_lvl     <= 1'b1;
      eop_cnt   <= 5'd0;
      eop_pend  <= 1'b0;
      tx_oe     <= 1'b0;
      tx_done   <= 1'b0;
    end else begin
      tx_done <= 1'b0;
      case (ts)
        TS_IDLE: begin
          if (tx_start) begin
            ts       <= TS_WAIT;
            wait_cnt <= 5'd0;
            tx_oe    <= 1'b0;
          end
        end
        TS_WAIT: begin                       // inter-packet turnaround gap
          if (wait_cnt == TURNAROUND[4:0] - 5'd1) begin
            ts       <= TS_RUN;
            tx_oe    <= 1'b1;
            t_lvl    <= 1'b0;                // first SYNC bit is 0 -> K
            tbt      <= 4'd0;
            t_ones   <= 3'd0;
            t_stuff  <= 1'b0;
            byte_ptr <= 5'd0;
            bit_ptr  <= 3'd1;                // bit0 pre-applied above
            eop_pend <= 1'b0;
          end else wait_cnt <= wait_cnt + 5'd1;
        end
        TS_RUN: begin
          if (tbt == BIT_CLKS-1) begin
            tbt <= 4'd0;
            if (eop_pend) begin              // final bit-time complete -> EOP
              ts       <= TS_EOP0;
              eop_cnt  <= 5'd0;
              eop_pend <= 1'b0;
            end else if (t_stuff) begin      // emit stuffed 0
              t_lvl   <= ~t_lvl;
              t_stuff <= 1'b0;
              t_ones  <= 3'd0;
            end else begin
              if (!t_bit) t_lvl <= ~t_lvl;   // NRZI: 0 toggles
              if (byte_ptr != 5'd0) begin    // stuffing after SYNC field
                if (t_bit) begin
                  if (t_ones == 3'd5) t_stuff <= 1'b1;
                  t_ones <= t_ones + 3'd1;
                end else t_ones <= 3'd0;
              end
              if ((byte_ptr == total_cnt) && (bit_ptr == 3'd7))
                eop_pend <= 1'b1;            // this bit-time is the last one
              else if (bit_ptr == 3'd7) begin
                bit_ptr  <= 3'd0;
                byte_ptr <= byte_ptr + 5'd1;
              end else bit_ptr <= bit_ptr + 3'd1;
            end
          end else tbt <= tbt + 4'd1;
        end
        TS_EOP0: begin                       // SE0 for 2 bit times
          if (eop_cnt == (2*BIT_CLKS) - 1) begin
            ts      <= TS_EOPJ;
            eop_cnt <= 5'd0;
          end else eop_cnt <= eop_cnt + 5'd1;
        end
        TS_EOPJ: begin                       // J for 1 bit time, then release
          if (eop_cnt == BIT_CLKS - 1) begin
            ts      <= TS_IDLE;
            tx_oe   <= 1'b0;
            tx_done <= 1'b1;
          end else eop_cnt <= eop_cnt + 5'd1;
        end
        default: ts <= TS_IDLE;
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
  cs_t         cs;
  logic        expect_ack;
  logic        cur_ep;                      // 0: EP0, 1: EP1 (for ACK bookkeeping)
  logic        exp_data, exp_setup, pend_stall;
  logic        ep0in_tgl, ep1in_tgl, out_tgl;
  logic [31:0] ep1_cnt;
  logic [7:0]  setup_q [0:7];
  logic [7:0]  ack_timer;

  wire wrong_tgl = ((rx_pid == PID_DATA1) != (exp_setup ? 1'b0 : out_tgl));

  function automatic logic [15:0] crc16_desc(input logic dummy);
    logic [15:0] c;
    begin
      c = 16'hFFFF;
      for (int i = 0; i < 8; i++) c = crc16_byte(c, desc_byte(i[2:0]));
      crc16_desc = c;
    end
  endfunction

  function automatic logic [15:0] crc16_cnt(input logic [31:0] v);
    logic [15:0] c;
    begin
      c = 16'hFFFF;
      for (int i = 0; i < 4; i++) c = crc16_byte(c, v[i*8 +: 8]);
      crc16_cnt = c;
    end
  endfunction

  wire [15:0] crc_d = crc16_desc(1'b0);
  wire [15:0] crc_c = crc16_cnt(ep1_cnt);

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      cs         <= CS_IDLE;
      expect_ack <= 1'b0;
      cur_ep     <= 1'b0;
      exp_data   <= 1'b0;
      exp_setup  <= 1'b0;
      pend_stall <= 1'b0;
      ep0in_tgl  <= 1'b0;
      ep1in_tgl  <= 1'b0;
      out_tgl    <= 1'b0;
      ep1_cnt    <= 32'd0;
      ack_timer  <= 8'd0;
      tx_start   <= 1'b0;
      irq        <= 1'b0;
      frame_no   <= 11'd0;
      uframe     <= 3'd0;
      for (int i = 0; i < 8; i++) setup_q[i] <= 8'd0;
    end else begin
      tx_start <= 1'b0;
      case (cs)
        // -------------------------------------------------- packet dispatch
        CS_IDLE: begin
          if (rx_done) begin
            case (rx_pid)
              PID_IN: begin
                exp_data <= 1'b0;
                if (!rx_tok_ok) irq <= 1'b1;          // bad CRC5: no response
                else if (rx_tokfield[6:0] == DEV_ADDR) begin
                  irq <= 1'b0;
                  if (rx_tokfield[10:7] == 4'd0) begin
                    txb[0] <= ep0in_tgl ? 8'h4B : 8'hC3;   // DATA1/DATA0
                    for (int i = 0; i < 8; i++) txb[i+1] <= desc_byte(i[2:0]);
                    txb[9]  <= ~crc_d[7:0];
                    txb[10] <= ~crc_d[15:8];
                    total_cnt <= 5'd11;
                    tx_start  <= 1'b1;
                    expect_ack<= 1'b1;
                    cur_ep    <= 1'b0;
                    cs        <= CS_TX;
                  end else if (rx_tokfield[10:7] == 4'd1) begin
                    txb[0] <= ep1in_tgl ? 8'h4B : 8'hC3;
                    txb[1] <= ep1_cnt[7:0];
                    txb[2] <= ep1_cnt[15:8];
                    txb[3] <= ep1_cnt[23:16];
                    txb[4] <= ep1_cnt[31:24];
                    txb[5] <= ~crc_c[7:0];
                    txb[6] <= ~crc_c[15:8];
                    total_cnt <= 5'd7;
                    tx_start  <= 1'b1;
                    expect_ack<= 1'b1;
                    cur_ep    <= 1'b1;
                    cs        <= CS_TX;
                  end else begin                        // illegal endpoint
                    txb[0]    <= 8'h1E;               // STALL
                    total_cnt <= 5'd1;
                    tx_start  <= 1'b1;
                    expect_ack<= 1'b0;
                    cs        <= CS_TX;
                  end
                end
              end
              PID_OUT, PID_SETUP: begin
                if (!rx_tok_ok) irq <= 1'b1;          // bad CRC5: no response
                else if (rx_tokfield[6:0] == DEV_ADDR) begin
                  irq        <= 1'b0;
                  exp_data   <= 1'b1;
                  exp_setup  <= (rx_pid == PID_SETUP);
                  pend_stall <= (rx_tokfield[10:7] > 4'd1);
                end
              end
              PID_DATA0, PID_DATA1: begin
                if (exp_data) begin
                  exp_data <= 1'b0;
                  if (!rx_data_ok) irq <= 1'b1;       // bad CRC16: no response
                  else if (pend_stall) begin
                    txb[0]    <= 8'h1E;               // STALL
                    total_cnt <= 5'd1;
                    tx_start  <= 1'b1;
                    expect_ack<= 1'b0;
                    cs        <= CS_TX;
                  end else begin
                    txb[0]    <= 8'hD2;               // ACK (even if duplicated)
                    total_cnt <= 5'd1;
                    tx_start  <= 1'b1;
                    expect_ack<= 1'b0;
                    cs        <= CS_TX;
                    if (!wrong_tgl) begin             // apply only in-sequence data
                      if (exp_setup) begin
                        if (rx_plen == 5'd8)
                          for (int i = 0; i < 8; i++) setup_q[i] <= rx_buf[i];
                        ep0in_tgl <= 1'b1;            // SETUP: next data is DATA1
                        out_tgl   <= 1'b1;
                      end else out_tgl <= ~out_tgl;
                    end
                  end
                end
              end
              PID_SOF: begin                          // microframe tracking
                if (!rx_tok_ok) irq <= 1'b1;          // bad CRC5: flag error
                else begin
                  frame_no <= rx_tokfield;            // 11-bit frame number
                  uframe   <= uframe + 3'd1;          // microframe count mod 8
                end
              end
              default: ;                              // handshakes: ignore
            endcase
          end
        end
        // -------------------------------------------------- transmit in flight
        CS_TX: begin
          if (tx_done) begin
            cs        <= expect_ack ? CS_WACK : CS_IDLE;
            ack_timer <= ACK_TO;
          end
        end
        // -------------------------------------------------- await host handshake
        CS_WACK: begin
          if (rx_done) begin
            cs <= CS_IDLE;
            if (rx_pid == PID_ACK) begin              // advance toggle / counter
              if (cur_ep == 1'b0) ep0in_tgl <= ~ep0in_tgl;
              else begin
                ep1in_tgl <= ~ep1in_tgl;
                ep1_cnt   <= ep1_cnt + 32'd1;
              end
            end                                       // NAK/timeout: keep toggle -> resend
          end else if (ack_timer == 8'd0) cs <= CS_IDLE;
          else ack_timer <= ack_timer - 8'd1;
        end
        default: cs <= CS_IDLE;
      endcase
    end
  end

endmodule
