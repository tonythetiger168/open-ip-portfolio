// SPDX-License-Identifier: Apache-2.0
// ============================================================================
// MIPI DSI host transmitter (packet layer, command + video mode, BTA)
// Implementation scope:
//   * Serial HS output model: 1 bit/clk on tx_bit while tx_valid is high,
//     LSB-first per byte; SoT sync byte 8'hB8 per packet (lane/LP states
//     abstracted: tx_oe marks host bus ownership, idle level = 1)
//   * Packet layer: header DI+WC/data[15:0]+ECC (Hamming(30,24) subset,
//     P7=P6=0, single-error correction on receive); long packets append
//     CRC-16/CCITT (reflected poly 0x8408, init 0xFFFF), low byte first
//   * Command ops (cmd_op):
//       0 OP_SPKT   raw short packet        (DT=cmd_dt, data=cmd_len)
//       1 OP_DCS_S0 DCS short write 0 param (DT=0x05, data={00,cmd_dcs})
//       2 OP_DCS_S1 DCS short write 1 param (DT=0x15, data={ram[0],cmd_dcs})
//       3 OP_DCS_L  DCS long write          (DT=0x39, WC=cmd_len, payload RAM)
//       4 OP_VLINE  video-mode line: HSS(0x21), HSE(0x31), HBP blanking
//                   (0x19, WC=cmd_len2, zero payload), HACT RGB888 (0x3E,
//                   WC=cmd_len, payload RAM)
//       5 OP_DCS_RD DCS read (DT=0x06, data={00,cmd_dcs}) + bus turn-around
//       6, 7        invalid: rejected with irq
//     A command whose RAM payload is longer than the 32-byte RAM, or whose
//     HACT WC is not a whole number of RGB888 pixels (3 bytes), is rejected
//     with irq and nothing is sent.
//   * BTA: after the read-request packet the host sends the BTA trigger byte
//     (8'h84, escape-command abstraction), releases the lane (tx_oe=0) and
//     receives a peripheral short-packet response with ECC checking
//     (single-error corrected; bta_data = {data1, data0, DI}). An
//     Acknowledge-and-Error-Report response (DT 0x02) with any error bit set
//     completes the read and raises irq. A timeout (BTA_TO clocks without a
//     SoT), a bad SoT byte or an uncorrectable header raise irq.
//   * irq is a one-clock pulse.
//   * 32-byte payload RAM written via pl_we/pl_addr.
// IP design implementation v1.1 -- Apache-2.0
// ============================================================================
module DSI_top #(
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
  localparam int         PLEN     = 32;      // payload RAM depth (bytes)
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
  localparam logic [7:0] DT_ACKERR = 8'h02;  // acknowledge and error report

  localparam logic [2:0] OP_SPKT   = 3'd0;
  localparam logic [2:0] OP_DCS_S0 = 3'd1;
  localparam logic [2:0] OP_DCS_S1 = 3'd2;
  localparam logic [2:0] OP_DCS_L  = 3'd3;
  localparam logic [2:0] OP_VLINE  = 3'd4;
  localparam logic [2:0] OP_DCS_RD = 3'd5;

  localparam int TOW = $clog2(BTA_TO + 1);

  typedef enum logic [3:0] {
    T_IDLE, T_SOT, T_H0, T_H1, T_H2, T_HE, T_PAY, T_C0, T_C1,
    T_GAP, T_BTA, B_WAIT, B_RBIT
  } state_t;

  // BTA receive sub-state
  typedef enum logic [2:0] {RB_SOT, RB_H0, RB_H1, RB_H2, RB_HE} rb_t;

  state_t state;
  rb_t    rbst;

  // current command: op, raw DT, data field / WC of the first (or HACT)
  // packet, HBP WC; the packet sequence is derived from the op
  logic [2:0]  c_op;
  logic [5:0]  c_dt;
  logic [15:0] c_len, c_len2;
  logic [1:0]  seq_i;          // current packet index

  // TX datapath
  logic [7:0]  tx_shreg;
  logic [2:0]  bit_cnt;
  logic [15:0] pay_cnt;
  logic [15:0] crc;
  logic        gap;

  // BTA receive datapath
  logic [6:0]     b_shift;                // latest 7 received bits
  logic [2:0]     b_cnt;
  logic [TOW-1:0] to_cnt;
  logic [23:0]    rb_hdr;

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
  // packet sequence of a command: VLINE = HSS, HSE, HBP, HACT; others one
  // packet
  // ------------------------------------------------------------------
  function automatic logic [5:0] pk_dt(input logic [2:0] op, input logic [1:0] i,
                                       input logic [5:0] dt);
    case (op)
      OP_SPKT:   pk_dt = dt;
      OP_DCS_S0: pk_dt = DT_DCS_S0[5:0];
      OP_DCS_S1: pk_dt = DT_DCS_S1[5:0];
      OP_DCS_L:  pk_dt = DT_DCS_L[5:0];
      OP_VLINE:  pk_dt = (i == 2'd0) ? DT_HSS[5:0] : (i == 2'd1) ? DT_HSE[5:0] :
                         (i == 2'd2) ? DT_HBP[5:0] : DT_HACT[5:0];
      default:   pk_dt = DT_DCS_RD[5:0];
    endcase
  endfunction
  // data field (short) / WC (long)
  function automatic logic [15:0] pk_len(input logic [2:0] op, input logic [1:0] i,
                                         input logic [15:0] l, input logic [15:0] l2);
    if (op != OP_VLINE)   pk_len = l;
    else if (i == 2'd2)   pk_len = l2;
    else if (i == 2'd3)   pk_len = l;
    else                  pk_len = 16'h0;
  endfunction
  function automatic logic pk_long(input logic [2:0] op, input logic [1:0] i);
    pk_long = (op == OP_DCS_L) || (op == OP_VLINE && i >= 2'd2);
  endfunction
  // payload of zeros (HBP blanking) instead of the payload RAM
  function automatic logic pk_zero(input logic [2:0] op, input logic [1:0] i);
    pk_zero = (op == OP_VLINE) && (i == 2'd2);
  endfunction
  function automatic logic [1:0] seq_last(input logic [2:0] op);
    seq_last = (op == OP_VLINE) ? 2'd3 : 2'd0;
  endfunction

  // command check: RAM payload must fit, HACT must be whole RGB888 pixels
  function automatic logic cmd_ok(input logic [2:0] op, input logic [15:0] l);
    case (op)
      OP_SPKT, OP_DCS_S0, OP_DCS_S1, OP_DCS_RD: cmd_ok = 1'b1;
      OP_DCS_L:  cmd_ok = (l <= 16'(PLEN));
      OP_VLINE:  cmd_ok = (l <= 16'(PLEN)) && (l % 16'd3 == 16'd0);
      default:   cmd_ok = 1'b0;
    endcase
  endfunction

  // ------------------------------------------------------------------
  // combinational helpers
  // ------------------------------------------------------------------
  wire [5:0]  cur_dt   = pk_dt(c_op, seq_i, c_dt);   // DI with VC 0
  wire [15:0] cur_len  = pk_len(c_op, seq_i, c_len, c_len2);
  wire        cur_zero = pk_zero(c_op, seq_i);
  wire        last_bit = (bit_cnt == 3'd7);
  wire        last_pay = (pay_cnt == cur_len - 16'd1);
  // payload byte currently being transmitted / next one
  wire [7:0]  pay_byte = cur_zero ? 8'h00 : pl_ram[pay_cnt[4:0]];
  wire [7:0]  pay_next = cur_zero ? 8'h00 : pl_ram[pay_cnt[4:0] + 5'd1];
  wire [15:0] ncrc     = crc16_byte(crc, pay_byte);
  // BTA receive: assembled byte and ECC syndrome on it
  wire [7:0]  rb_byte  = {rx_bit, b_shift};
  wire [5:0]  rb_syn   = rb_byte[5:0] ^ ecc24(rb_hdr);
  wire [5:0]  rb_eb    = ecc_bit(rb_syn);
  // corrected response header (single data-bit error)
  wire [23:0] rb_fix   = (rb_eb < 6'd24) ? rb_hdr ^ (24'h1 << rb_eb) : rb_hdr;
  wire        tx_state = (state != T_IDLE) && (state != T_GAP) &&
                         (state != B_WAIT) && (state != B_RBIT);

  // ------------------------------------------------------------------
  // sequential
  // ------------------------------------------------------------------
  always_ff @(posedge clk) begin
    if (pl_we) pl_ram[pl_addr] <= pl_wdata;
  end

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
      gap      <= 1'b0;
      c_op     <= OP_SPKT;
      c_dt     <= 6'h0;
      c_len    <= 16'h0;
      c_len2   <= 16'h0;
      seq_i    <= 2'd0;
      b_shift  <= 7'h00;
      b_cnt    <= 3'd0;
      to_cnt   <= '0;
      rb_hdr   <= 24'h0;
      cmd_busy <= 1'b0;
      bta_done <= 1'b0;
      bta_data <= 24'h0;
      pkt_cnt  <= 16'h0;
      irq      <= 1'b0;
    end else begin
      bta_done <= 1'b0;   // pulses
      irq      <= 1'b0;

      // common bit-serial output of the packet / trigger states; tx_shreg
      // holds the state's byte, preloaded before entry
      if (tx_state) begin
        tx_valid <= 1'b1;
        tx_bit   <= tx_shreg[0];
        if (last_bit) bit_cnt <= 3'd0;
        else begin
          bit_cnt  <= bit_cnt + 3'd1;
          tx_shreg <= {1'b1, tx_shreg[7:1]};
        end
      end

      case (state)
        // ----------------------------------------------------------
        T_IDLE: begin
          tx_valid <= 1'b0;
          tx_oe    <= 1'b1;
          tx_bit   <= 1'b1;
          if (cmd_valid) begin
            if (!cmd_ok(cmd_op, cmd_len)) begin
              irq <= 1'b1;                       // rejected command
            end else begin
              cmd_busy <= 1'b1;
              c_op     <= cmd_op;
              c_dt     <= cmd_dt;
              c_len    <= (cmd_op == OP_DCS_S0 || cmd_op == OP_DCS_RD) ? {8'h00, cmd_dcs} :
                          (cmd_op == OP_DCS_S1) ? {pl_ram[0], cmd_dcs} : cmd_len;
              c_len2   <= cmd_len2;
              seq_i    <= 2'd0;
              state    <= T_SOT;
              bit_cnt  <= 3'd0;
              tx_shreg <= SOT_SYNC;
            end
          end
        end

        // ------------------------- packet TX ------------------------
        T_SOT: if (last_bit) begin
          state    <= T_H0;
          tx_shreg <= {2'b00, cur_dt};
        end
        T_H0: if (last_bit) begin
          state    <= T_H1;
          tx_shreg <= cur_len[7:0];
        end
        T_H1: if (last_bit) begin
          state    <= T_H2;
          tx_shreg <= cur_len[15:8];
        end
        T_H2: if (last_bit) begin
          state    <= T_HE;
          tx_shreg <= {2'b00, ecc24({cur_len, 2'b00, cur_dt})};
        end
        T_HE: if (last_bit) begin
          pay_cnt <= 16'h0;
          crc     <= 16'hFFFF;
          if (pk_long(c_op, seq_i)) begin
            if (cur_len == 16'h0) begin
              state    <= T_C0;
              tx_shreg <= 8'hFF;   // CRC-16 of an empty payload
            end else begin
              state    <= T_PAY;
              tx_shreg <= cur_zero ? 8'h00 : pl_ram[0];
            end
          end else begin
            state   <= T_GAP;
            gap     <= 1'b1;
            pkt_cnt <= pkt_cnt + 16'd1;
          end
        end
        T_PAY: if (last_bit) begin
          crc <= ncrc;
          if (last_pay) begin
            state    <= T_C0;
            tx_shreg <= ncrc[7:0];
          end else begin
            pay_cnt  <= pay_cnt + 16'd1;
            tx_shreg <= pay_next;
          end
        end
        T_C0: if (last_bit) begin
          state    <= T_C1;
          tx_shreg <= crc[15:8];
        end
        T_C1: if (last_bit) begin
          state   <= T_GAP;
          gap     <= 1'b1;
          pkt_cnt <= pkt_cnt + 16'd1;
        end
        T_BTA: if (last_bit) begin  // trigger bit7 goes out this next
          state  <= B_WAIT;         // cycle; B_WAIT releases the lane
          to_cnt <= '0;
        end

        // ------------------- inter-packet gap / next ----------------
        T_GAP: begin
          tx_valid <= 1'b0;
          tx_bit   <= 1'b1;
          gap      <= 1'b0;
          if (gap) begin
            // one extra idle clock between packets
          end else if (seq_i != seq_last(c_op)) begin
            seq_i    <= seq_i + 2'd1;
            state    <= T_SOT;
            bit_cnt  <= 3'd0;
            tx_shreg <= SOT_SYNC;
          end else if (c_op == OP_DCS_RD) begin
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
            b_shift <= 7'h00;                  // SoT bit 0 (= 0) taken
            b_cnt   <= 3'd1;
            state   <= B_RBIT;
            rbst    <= RB_SOT;
          end else if (to_cnt == TOW'(BTA_TO)) begin
            irq      <= 1'b1;                    // peripheral did not answer
            state    <= T_IDLE;
            tx_oe    <= 1'b1;
            cmd_busy <= 1'b0;
          end else begin
            to_cnt <= to_cnt + 1'b1;
          end
        end

        B_RBIT: begin
          b_shift <= rb_byte[7:1];
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
                if (rb_eb != 6'd63 || rb_syn == 6'h00) begin
                  bta_data <= rb_fix;            // clean or corrected
                  bta_done <= 1'b1;
                  if (rb_fix[7:0] == DT_ACKERR && rb_fix[23:8] != 16'h0)
                    irq <= 1'b1;                 // peripheral reported errors
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
