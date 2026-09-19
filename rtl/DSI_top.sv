// SPDX-License-Identifier: Apache-2.0
// ============================================================================
// MIPI DSI host transmitter (packet layer, command + video mode, BTA)
// Implementation scope:
//   * Serial HS output model: 1 bit/clk on tx_bit while tx_valid is high,
//     LSB-first per byte; SoT sync byte 8'hB8 per packet (lane/LP states
//     abstracted: tx_oe marks host bus ownership, idle level = 1)
//   * Packet layer identical to CSI-2: header DI+WC/data[15:0]+ECC
//     (Hamming(30,24) subset, P7=P6=0, single-error correction on receive),
//     long packets append CRC-16/CCITT (poly 0x1021, init 0xFFFF)
//   * Command ops (cmd_op):
//       0 OP_SPKT   raw short packet        (DT=cmd_dt, data=cmd_len)
//       1 OP_DCS_S0 DCS short write 0 param (DT=0x05, e.g. set_display_on 0x29)
//       2 OP_DCS_S1 DCS short write 1 param (DT=0x15, e.g. set_pixel_format 0x3A)
//       3 OP_DCS_L  DCS long write          (DT=0x39, WC=cmd_len, e.g.
//                                            column/page address 0x2A/0x2B)
//       4 OP_VLINE  video-mode line: HSS(0x21)/HSE(0x31)/HBP blanking
//                   (0x19, WC=cmd_len2)/HACT RGB888 (0x3E, WC=cmd_len)
//       5 OP_DCS_RD DCS read (DT=0x06) + bus turn-around
//   * BTA: after the read-request packet the host sends the BTA trigger byte
//     (8'h84, escape-command abstraction), releases the lane (tx_oe=0) and
//     receives a peripheral short-packet response with ECC checking
//     (single-error corrected); timeout or uncorrectable ECC raises irq
//   * 32-byte payload RAM written via pl_we/pl_addr before long commands
//     (long-packet WC must be <= PLEN)
// IP design implementation v1.0 -- Apache-2.0
// ============================================================================
module DSI_top #(
  parameter int DW = 32,          // retained framework parameter (data width)
  parameter int AW = 32,          // retained framework parameter (address width)
  parameter int PLEN = 32,        // payload RAM depth (bytes)
  parameter int BTA_TO = 512      // BTA response timeout (clk)
)(
  input  logic        clk,
  input  logic        rst_n,
  output logic        irq,
  // serial lane
  output logic        tx_bit,
  output logic        tx_valid,
  output logic        tx_oe,      // 1 = host owns the lane
  input  logic        rx_bit,     // peripheral drives when tx_oe = 0
  // command interface
  input  logic        cmd_valid,
  input  logic [2:0]  cmd_op,
  input  logic [5:0]  cmd_dt,
  input  logic [7:0]  cmd_dcs,
  input  logic [15:0] cmd_len,
  input  logic [15:0] cmd_len2,
  output logic        cmd_busy,
  // payload RAM write port
  input  logic        pl_we,
  input  logic [4:0]  pl_addr,
  input  logic [7:0]  pl_wdata,
  // BTA response
  output logic        bta_done,
  output logic [23:0] bta_data,
  // status
  output logic [15:0] pkt_cnt
);

  // ------------------------------------------------------------------
  // constants
  // ------------------------------------------------------------------
  localparam logic [7:0] SOT_SYNC = 8'hB8;
  localparam logic [7:0] BTA_TRIG = 8'h84;   // BTA trigger (escape cmd model)
  localparam logic [7:0] DT_DCS_S0 = 8'h05;
  localparam logic [7:0] DT_DCS_S1 = 8'h15;
  localparam logic [7:0] DT_DCS_L  = 8'h39;
  localparam logic [7:0] DT_DCS_RD = 8'h06;
  localparam logic [7:0] DT_HSS    = 8'h21;
  localparam logic [7:0] DT_HSE    = 8'h31;
  localparam logic [7:0] DT_HBP    = 8'h19;
  localparam logic [7:0] DT_HACT   = 8'h3E;  // RGB888 pixel stream

  localparam logic [2:0] OP_SPKT   = 3'd0;
  localparam logic [2:0] OP_DCS_S0 = 3'd1;
  localparam logic [2:0] OP_DCS_S1 = 3'd2;
  localparam logic [2:0] OP_DCS_L  = 3'd3;
  localparam logic [2:0] OP_VLINE  = 3'd4;
  localparam logic [2:0] OP_DCS_RD = 3'd5;

  localparam logic [15:0] BTA_TO16 = 16'(BTA_TO);

  typedef enum logic [3:0] {
    T_IDLE, T_SOT, T_H0, T_H1, T_H2, T_HE, T_PAY, T_C0, T_C1,
    T_GAP, T_BTA, B_WAIT, B_RBIT
  } state_t;

  // BTA receive sub-state
  typedef enum logic [2:0] {RB_SOT, RB_H0, RB_H1, RB_H2, RB_HE} rb_t;

  state_t state;
  rb_t    rbst;

  // packet sequence descriptors (max 4 packets per command)
  logic [7:0]  p_dt   [0:3];
  logic [15:0] p_len  [0:3];   // payload bytes (long) / data field (short)
  logic        p_long [0:3];
  logic        p_zero [0:3];   // payload = zeros (blanking) vs payload RAM
  logic [1:0]  seq_n;          // number of packets - 1
  logic [1:0]  seq_i;          // current packet index
  logic        seq_bta;        // command ends with bus turn-around

  // TX datapath
  logic [7:0]  tx_shreg;
  logic [2:0]  bit_cnt;
  logic [15:0] pay_cnt;
  logic [15:0] crc;
  logic [1:0]  gap_cnt;

  // BTA receive datapath
  logic [7:0]  b_shift;
  logic [2:0]  b_cnt;
  logic [15:0] to_cnt;
  logic [23:0] rb_hdr;

  // payload RAM
  logic [7:0]  pl_ram [0:PLEN-1];

  // ------------------------------------------------------------------
  // ECC + CRC (same code as the CSI-2 receiver, MIPI spec equations)
  // ------------------------------------------------------------------
  function automatic logic [5:0] ecc24(input logic [23:0] d);
    begin
      ecc24[0] = d[0]^d[1]^d[2]^d[4]^d[5]^d[7]^d[10]^d[11]^d[13]^d[16]^d[20]^d[21]^d[22]^d[23];
      ecc24[1] = d[0]^d[1]^d[3]^d[4]^d[6]^d[8]^d[10]^d[12]^d[14]^d[17]^d[20]^d[21]^d[22]^d[23];
      ecc24[2] = d[0]^d[2]^d[3]^d[5]^d[6]^d[9]^d[11]^d[12]^d[15]^d[18]^d[20]^d[21]^d[22];
      ecc24[3] = d[1]^d[2]^d[3]^d[7]^d[8]^d[9]^d[13]^d[14]^d[15]^d[19]^d[20]^d[21]^d[23];
      ecc24[4] = d[4]^d[5]^d[6]^d[7]^d[8]^d[9]^d[16]^d[17]^d[18]^d[19]^d[20]^d[22]^d[23];
      ecc24[5] = d[10]^d[11]^d[12]^d[13]^d[14]^d[15]^d[16]^d[17]^d[18]^d[19]^d[21]^d[22]^d[23];
    end
  endfunction

  function automatic logic [5:0] ecc_bit(input logic [5:0] syn);
    begin
      case (syn)
        6'h07: ecc_bit = 6'd0;   6'h0B: ecc_bit = 6'd1;
        6'h0D: ecc_bit = 6'd2;   6'h0E: ecc_bit = 6'd3;
        6'h13: ecc_bit = 6'd4;   6'h15: ecc_bit = 6'd5;
        6'h16: ecc_bit = 6'd6;   6'h19: ecc_bit = 6'd7;
        6'h1A: ecc_bit = 6'd8;   6'h1C: ecc_bit = 6'd9;
        6'h23: ecc_bit = 6'd10;  6'h25: ecc_bit = 6'd11;
        6'h26: ecc_bit = 6'd12;  6'h29: ecc_bit = 6'd13;
        6'h2A: ecc_bit = 6'd14;  6'h2C: ecc_bit = 6'd15;
        6'h31: ecc_bit = 6'd16;  6'h32: ecc_bit = 6'd17;
        6'h34: ecc_bit = 6'd18;  6'h38: ecc_bit = 6'd19;
        6'h1F: ecc_bit = 6'd20;  6'h2F: ecc_bit = 6'd21;
        6'h37: ecc_bit = 6'd22;  6'h3B: ecc_bit = 6'd23;
        6'h01: ecc_bit = 6'd24;  6'h02: ecc_bit = 6'd25;
        6'h04: ecc_bit = 6'd26;  6'h08: ecc_bit = 6'd27;
        6'h10: ecc_bit = 6'd28;  6'h20: ecc_bit = 6'd29;
        default: ecc_bit = 6'd63;
      endcase
    end
  endfunction

  function automatic logic [15:0] crc16_byte(input logic [15:0] c,
                                             input logic [7:0]  d);
    logic [15:0] v;
    begin
      v = c ^ {8'h00, d};
      v = v[0] ? {1'b0, v[15:1]} ^ 16'h8408 : {1'b0, v[15:1]};
      v = v[0] ? {1'b0, v[15:1]} ^ 16'h8408 : {1'b0, v[15:1]};
      v = v[0] ? {1'b0, v[15:1]} ^ 16'h8408 : {1'b0, v[15:1]};
      v = v[0] ? {1'b0, v[15:1]} ^ 16'h8408 : {1'b0, v[15:1]};
      v = v[0] ? {1'b0, v[15:1]} ^ 16'h8408 : {1'b0, v[15:1]};
      v = v[0] ? {1'b0, v[15:1]} ^ 16'h8408 : {1'b0, v[15:1]};
      v = v[0] ? {1'b0, v[15:1]} ^ 16'h8408 : {1'b0, v[15:1]};
      v = v[0] ? {1'b0, v[15:1]} ^ 16'h8408 : {1'b0, v[15:1]};
      crc16_byte = v;
    end
  endfunction

  // ------------------------------------------------------------------
  // combinational helpers
  // ------------------------------------------------------------------
  wire       last_bit = (bit_cnt == 3'd7);
  wire       last_pay = (pay_cnt == p_len[seq_i] - 16'd1);
  // payload byte currently being transmitted / next one
  wire [7:0] pay_byte  = p_zero[seq_i] ? 8'h00 : pl_ram[pay_cnt[4:0]];
  wire [7:0] pay_next  = p_zero[seq_i] ? 8'h00 : pl_ram[pay_cnt[4:0] + 5'd1];
  wire [15:0] ncrc     = crc16_byte(crc, pay_byte);
  // BTA receive: assembled byte and ECC syndrome on it
  wire [7:0] rb_byte = {rx_bit, b_shift[7:1]};
  wire [5:0] rb_syn  = rb_byte[5:0] ^ ecc24(rb_hdr);
  wire [5:0] rb_eb   = ecc_bit(rb_syn);

  // ------------------------------------------------------------------
  // sequential
  // ------------------------------------------------------------------
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      state    <= T_IDLE;
      rbst     <= RB_SOT;
      tx_bit   <= 1'b1;
      tx_valid <= 1'b0;
      tx_oe    <= 1'b1;
      tx_shreg <= 8'hFF;
      bit_cnt  <= 3'd0;
      pay_cnt  <= 16'h0;
      crc      <= 16'hFFFF;
      gap_cnt  <= 2'd0;
      seq_n    <= 2'd0;
      seq_i    <= 2'd0;
      seq_bta  <= 1'b0;
      b_shift  <= 8'h00;
      b_cnt    <= 3'd0;
      to_cnt   <= 16'h0;
      rb_hdr   <= 24'h0;
      cmd_busy <= 1'b0;
      bta_done <= 1'b0;
      bta_data <= 24'h0;
      pkt_cnt  <= 16'h0;
      irq      <= 1'b0;
      for (int i = 0; i < 4; i++) begin
        p_dt[i]   <= 8'h00;
        p_len[i]  <= 16'h0;
        p_long[i] <= 1'b0;
        p_zero[i] <= 1'b0;
      end
    end else begin
      bta_done <= 1'b0;   // pulse

      // payload RAM write port
      if (pl_we)
        pl_ram[pl_addr] <= pl_wdata;

      case (state)
        // ----------------------------------------------------------
        T_IDLE: begin
          tx_valid <= 1'b0;
          tx_oe    <= 1'b1;
          tx_bit   <= 1'b1;
          if (cmd_valid && !cmd_busy) begin
            cmd_busy <= 1'b1;
            seq_i    <= 2'd0;
            seq_bta  <= (cmd_op == OP_DCS_RD);
            pay_cnt  <= 16'h0;
            crc      <= 16'hFFFF;
            // decode command into packet descriptors
            case (cmd_op)
              OP_SPKT: begin
                seq_n     <= 2'd0;
                p_dt[0]   <= {2'b00, cmd_dt};
                p_len[0]  <= cmd_len;
                p_long[0] <= 1'b0;
                p_zero[0] <= 1'b0;
              end
              OP_DCS_S0: begin
                seq_n     <= 2'd0;
                p_dt[0]   <= DT_DCS_S0;
                p_len[0]  <= {8'h00, cmd_dcs};
                p_long[0] <= 1'b0;
                p_zero[0] <= 1'b0;
              end
              OP_DCS_S1: begin
                seq_n     <= 2'd0;
                p_dt[0]   <= DT_DCS_S1;
                p_len[0]  <= {pl_ram[0], cmd_dcs};
                p_long[0] <= 1'b0;
                p_zero[0] <= 1'b0;
              end
              OP_DCS_L: begin
                seq_n     <= 2'd0;
                p_dt[0]   <= DT_DCS_L;
                p_len[0]  <= cmd_len;
                p_long[0] <= 1'b1;
                p_zero[0] <= 1'b0;
              end
              OP_VLINE: begin
                seq_n     <= 2'd3;
                p_dt[0]   <= DT_HSS;
                p_len[0]  <= 16'h0;
                p_long[0] <= 1'b0;
                p_zero[0] <= 1'b0;
                p_dt[1]   <= DT_HSE;
                p_len[1]  <= 16'h0;
                p_long[1] <= 1'b0;
                p_zero[1] <= 1'b0;
                p_dt[2]   <= DT_HBP;
                p_len[2]  <= cmd_len2;
                p_long[2] <= 1'b1;
                p_zero[2] <= 1'b1;
                p_dt[3]   <= DT_HACT;
                p_len[3]  <= cmd_len;
                p_long[3] <= 1'b1;
                p_zero[3] <= 1'b0;
              end
              default: begin  // OP_DCS_RD
                seq_n     <= 2'd0;
                p_dt[0]   <= DT_DCS_RD;
                p_len[0]  <= {8'h00, cmd_dcs};
                p_long[0] <= 1'b0;
                p_zero[0] <= 1'b0;
              end
            endcase
            state    <= T_SOT;
            bit_cnt  <= 3'd0;
            tx_shreg <= SOT_SYNC;
          end
        end

        // ------------------------- packet TX ------------------------
        // tx_shreg is preloaded with the state's byte before/at entry,
        // so tx_bit <= tx_shreg[0] always emits the aligned bit.
        T_SOT, T_H0, T_H1, T_H2, T_HE, T_PAY, T_C0, T_C1, T_BTA: begin
          tx_valid <= 1'b1;
          tx_bit   <= tx_shreg[0];
          if (state == T_PAY && last_bit)
            crc <= ncrc;
          if (last_bit) begin
            bit_cnt <= 3'd0;
            case (state)
              T_SOT: begin
                state    <= T_H0;
                tx_shreg <= p_dt[seq_i];
              end
              T_H0: begin
                state    <= T_H1;
                tx_shreg <= p_len[seq_i][7:0];
              end
              T_H1: begin
                state    <= T_H2;
                tx_shreg <= p_len[seq_i][15:8];
              end
              T_H2: begin
                state    <= T_HE;
                tx_shreg <= {2'b00, ecc24({p_len[seq_i], p_dt[seq_i]})};
              end
              T_HE: begin
                pay_cnt <= 16'h0;
                crc     <= 16'hFFFF;
                if (p_long[seq_i]) begin
                  if (p_len[seq_i] == 16'h0) begin
                    state    <= T_C0;
                    tx_shreg <= 8'hFF;   // CRC-16 of empty payload
                  end else begin
                    state    <= T_PAY;
                    tx_shreg <= p_zero[seq_i] ? 8'h00 : pl_ram[0];
                  end
                end else begin
                  state   <= T_GAP;
                  gap_cnt <= 2'd1;
                  pkt_cnt <= pkt_cnt + 16'd1;
                end
              end
              T_PAY: begin
                if (last_pay) begin
                  state    <= T_C0;
                  tx_shreg <= ncrc[7:0];
                end else begin
                  pay_cnt  <= pay_cnt + 16'd1;
                  tx_shreg <= pay_next;
                end
              end
              T_C0: begin
                state    <= T_C1;
                tx_shreg <= crc[15:8];
              end
              T_C1: begin
                state   <= T_GAP;
                gap_cnt <= 2'd1;
                pkt_cnt <= pkt_cnt + 16'd1;
              end
              default: begin  // T_BTA: trigger bit7 goes out this next
                state  <= B_WAIT;    // cycle; B_WAIT releases the lane
                to_cnt <= 16'h0;
                rbst   <= RB_SOT;
              end
            endcase
          end else begin
            bit_cnt  <= bit_cnt + 3'd1;
            tx_shreg <= {1'b1, tx_shreg[7:1]};
          end
        end

        // ------------------- inter-packet gap / next ----------------
        T_GAP: begin
          tx_valid <= 1'b0;
          tx_bit   <= 1'b1;
          if (gap_cnt != 2'd0) begin
            gap_cnt <= gap_cnt - 2'd1;
          end else if (seq_i != seq_n) begin
            seq_i    <= seq_i + 2'd1;
            state    <= T_SOT;
            bit_cnt  <= 3'd0;
            tx_shreg <= SOT_SYNC;
          end else if (seq_bta) begin
            state    <= T_BTA;
            bit_cnt  <= 3'd0;
            tx_shreg <= BTA_TRIG;
          end else begin
            state    <= T_IDLE;
            cmd_busy <= 1'b0;
          end
        end

        // --------------------------- BTA ----------------------------
        B_WAIT: begin
          // lane released (one cycle after the trigger's last bit);
          // wait for peripheral SoT (rx idle level = 1)
          tx_valid <= 1'b0;
          tx_oe    <= 1'b0;
          if (rx_bit == 1'b0) begin
            b_shift <= {7'h00, rx_bit};
            b_cnt   <= 3'd1;
            state   <= B_RBIT;
            rbst    <= RB_SOT;
          end else if (to_cnt == BTA_TO16) begin
            // peripheral did not answer
            irq      <= 1'b1;
            state    <= T_IDLE;
            tx_oe    <= 1'b1;
            cmd_busy <= 1'b0;
          end else begin
            to_cnt <= to_cnt + 16'd1;
          end
        end

        B_RBIT: begin
          b_shift <= rb_byte;
          if (b_cnt == 3'd7) begin
            b_cnt <= 3'd0;
            case (rbst)
              RB_SOT: begin
                if (rb_byte != SOT_SYNC) begin
                  irq      <= 1'b1;              // framing error
                  state    <= T_IDLE;
                  tx_oe    <= 1'b1;
                  cmd_busy <= 1'b0;
                end else begin
                  rbst <= RB_H0;
                end
              end
              RB_H0: begin
                rb_hdr[7:0] <= rb_byte;
                rbst        <= RB_H1;
              end
              RB_H1: begin
                rb_hdr[15:8] <= rb_byte;
                rbst         <= RB_H2;
              end
              RB_H2: begin
                rb_hdr[23:16] <= rb_byte;
                rbst          <= RB_HE;
              end
              default: begin  // RB_HE: ECC byte of the response header
                state    <= T_IDLE;
                tx_oe    <= 1'b1;
                cmd_busy <= 1'b0;
                if (rb_syn == 6'h00) begin
                  bta_data <= rb_hdr;
                  bta_done <= 1'b1;
                  irq      <= 1'b0;
                end else if (rb_eb != 6'd63) begin
                  // correctable single-bit error in the response header
                  if (rb_eb < 6'd24)
                    bta_data <= rb_hdr ^ (24'h1 << rb_eb);
                  else
                    bta_data <= rb_hdr;
                  bta_done <= 1'b1;
                  irq      <= 1'b0;
                end else begin
                  irq <= 1'b1;                   // uncorrectable response
                end
              end
            endcase
          end else begin
            b_cnt <= b_cnt + 3'd1;
          end
        end

        default: state <= T_IDLE;
      endcase
    end
  end

endmodule
