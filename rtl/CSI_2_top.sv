// SPDX-License-Identifier: Apache-2.0
// ============================================================================
// MIPI CSI-2 receiver (camera side link, packet layer)
// Implementation scope:
//   * Serial HS input model: 1 bit/clk on rx_bit while rx_valid is high,
//     LSB-first per byte. rx_valid high = one HS burst (SoT .. EoT).
//   * SoT: the 8'hB8 sync byte is hunted bit by bit from the start of a
//     burst (any number of leading HS-zero bits). After a packet, a further
//     sync byte on the same byte alignment starts another packet in the
//     same burst; anything else is EoT trailer and is ignored to burst end.
//   * Packet header DI/VC + WC/data[15:0] + ECC byte (CSI-2 Hamming code,
//     6 parity bits, SEC-DED):
//       - syndrome == 0             -> clean header
//       - syndrome of a data bit    -> single error corrected in place
//       - one-hot syndrome          -> error inside the ECC byte, data ok
//       - otherwise                 -> uncorrectable, packet dropped + irq
//   * Short packets (DT 6'h00..6'h0F): FS=0x00 opens a frame (frame_cnt++,
//     line_cnt and err_flags cleared), FE=0x01 closes it; the 16-bit data
//     field of every short packet is reported in last_wc.
//   * Long packets (DT >= 6'h10): WC payload bytes, then CRC-16/CCITT
//     (poly 0x1021, init 0xFFFF, LSB-first on the wire). The payload goes
//     into the back half of a ping-pong line buffer; a good CRC swaps the
//     halves and bumps line_cnt, so the read port always shows the last
//     good line. Bytes beyond LINE_BYTES are checked but not stored.
//   * irq: protocol error, held until the next good packet.
//     err_flags: [0] CRC  [1] ECC uncorrectable  [2] burst ended inside a
//     packet  [3] ECC corrected; they accumulate and clear at Frame Start.
// IP design implementation v1.1 -- Apache-2.0
// ============================================================================
module CSI_2_top #(
  parameter int LINE_BYTES = 512    // pixel line buffer depth (power of 2)
)(
  input  logic        clk,
  input  logic        rst_n,
  // serial lane input (1 bit/clk, LSB first)
  input  logic        rx_bit,
  input  logic        rx_valid,
  // interrupt / status
  output logic        irq,
  output logic        frame_active,
  output logic [15:0] frame_cnt,
  output logic [15:0] line_cnt,
  output logic [7:0]  last_dt,       // {VC[1:0], DT[5:0]} of last accepted header
  output logic [15:0] last_wc,       // WC (long) or data field (short)
  output logic [3:0]  err_flags,
  output logic [15:0] lb_len,        // bytes in the readable line
  // line buffer read port
  input  logic [$clog2(LINE_BYTES)-1:0] lb_addr,
  output logic [7:0]  lb_rdata
);
  localparam int LA = $clog2(LINE_BYTES);
  localparam logic [7:0]  SOT_SYNC = 8'hB8;
  localparam logic [5:0]  DT_FS = 6'h00;
  localparam logic [5:0]  DT_FE = 6'h01;
  localparam logic [15:0] LB16  = 16'(LINE_BYTES);

  typedef enum logic [3:0] {
    S_HUNT, S_HDR0, S_HDR1, S_HDR2, S_ECC, S_PAY, S_CRC0, S_CRC1, S_NEXT, S_EOT
  } state_t;
  state_t state;

  logic [6:0]  shreg;          // last 7 bits, newest at [6]
  logic [2:0]  bit_cnt;
  logic [23:0] hdr;            // {WC[15:8], WC[7:0], DI}
  logic [15:0] wc, pay_cnt, crc;
  logic [7:0]  crc_lo;
  logic        bank;           // half of line_buf that the read port shows
  logic [7:0]  line_buf [0:2*LINE_BYTES-1];

  // CSI-2 ECC parity equations (P7 = P6 = 0 on the wire)
  function automatic logic [5:0] ecc24(input logic [23:0] d);
    ecc24[0] = d[0]^d[1]^d[2]^d[4]^d[5]^d[7]^d[10]^d[11]^d[13]^d[16]^d[20]^d[21]^d[22]^d[23];
    ecc24[1] = d[0]^d[1]^d[3]^d[4]^d[6]^d[8]^d[10]^d[12]^d[14]^d[17]^d[20]^d[21]^d[22]^d[23];
    ecc24[2] = d[0]^d[2]^d[3]^d[5]^d[6]^d[9]^d[11]^d[12]^d[15]^d[18]^d[20]^d[21]^d[22];
    ecc24[3] = d[1]^d[2]^d[3]^d[7]^d[8]^d[9]^d[13]^d[14]^d[15]^d[19]^d[20]^d[21]^d[23];
    ecc24[4] = d[4]^d[5]^d[6]^d[7]^d[8]^d[9]^d[16]^d[17]^d[18]^d[19]^d[20]^d[22]^d[23];
    ecc24[5] = d[10]^d[11]^d[12]^d[13]^d[14]^d[15]^d[16]^d[17]^d[18]^d[19]^d[21]^d[22]^d[23];
  endfunction

  // syndrome -> one-hot mask of the data bit to flip (0 if none)
  function automatic logic [23:0] ecc_fix(input logic [5:0] syn);
    ecc_fix = '0;
    for (int i = 0; i < 24; i++)
      if (syn == ecc24(24'h1 << i)) ecc_fix = 24'h1 << i;
  endfunction

  function automatic logic [15:0] crc16_byte(input logic [15:0] c, input logic [7:0] d);
    logic [15:0] v;
    v = c ^ {8'h00, d};
    for (int k = 0; k < 8; k++) v = v[0] ? (v >> 1) ^ 16'h8408 : (v >> 1);
    crc16_byte = v;
  endfunction

  wire [7:0]  rx_byte  = {rx_bit, shreg};           // LSB first
  wire        byte_rdy = rx_valid && bit_cnt == 3'd7;
  wire [5:0]  syn      = rx_byte[5:0] ^ ecc24(hdr);
  wire [23:0] fix      = ecc_fix(syn);
  wire        ecc_bit  = syn != 6'h00 && (syn & (syn - 6'd1)) == 6'h00;   // one-hot
  wire        ecc_ok   = syn == 6'h00 || fix != '0 || ecc_bit;
  wire [23:0] hc       = hdr ^ fix;                  // corrected header
  wire        in_pkt   = state != S_HUNT && state != S_NEXT && state != S_EOT;

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      state <= S_HUNT; shreg <= '0; bit_cnt <= '0; hdr <= '0; wc <= '0;
      pay_cnt <= '0; crc <= 16'hFFFF; crc_lo <= '0; bank <= 1'b0;
      irq <= 1'b0; frame_active <= 1'b0; frame_cnt <= '0; line_cnt <= '0;
      last_dt <= '0; last_wc <= '0; err_flags <= '0; lb_len <= '0;
    end else if (!rx_valid) begin
      bit_cnt <= '0;
      state   <= S_HUNT;
      if (in_pkt) err_flags[2] <= 1'b1;               // burst ended in a packet
    end else begin
      shreg   <= rx_byte[7:1];
      bit_cnt <= bit_cnt + 3'd1;
      if (state == S_HUNT) begin                        // bit-wise sync hunt
        if (rx_byte == SOT_SYNC) begin state <= S_HDR0; bit_cnt <= '0; end
      end else if (byte_rdy) begin
        case (state)
          S_NEXT: state <= (rx_byte == SOT_SYNC) ? S_HDR0 : S_EOT;
          S_HDR0: begin hdr[7:0]   <= rx_byte; state <= S_HDR1; end
          S_HDR1: begin hdr[15:8]  <= rx_byte; state <= S_HDR2; end
          S_HDR2: begin hdr[23:16] <= rx_byte; state <= S_ECC;  end
          S_ECC: begin
            if (!ecc_ok) begin
              state <= S_NEXT; irq <= 1'b1; err_flags[1] <= 1'b1;
            end else begin
              last_dt <= hc[7:0];
              last_wc <= hc[23:8];
              if (hc[5:0] < 6'h10) begin                // short packet
                state <= S_NEXT;
                irq   <= 1'b0;
                if (hc[5:0] == DT_FS) begin
                  frame_active <= 1'b1; frame_cnt <= frame_cnt + 16'd1; line_cnt <= '0;
                  err_flags <= {syn != 6'h00, 3'b000};
                end else begin
                  if (hc[5:0] == DT_FE) frame_active <= 1'b0;
                  if (syn != 6'h00) err_flags[3] <= 1'b1;
                end
              end else begin                            // long packet
                if (syn != 6'h00) err_flags[3] <= 1'b1;
                wc <= hc[23:8]; pay_cnt <= '0; crc <= 16'hFFFF;
                state <= (hc[23:8] == 16'h0) ? S_CRC0 : S_PAY;
              end
            end
          end
          S_PAY: begin
            crc <= crc16_byte(crc, rx_byte);
            if (pay_cnt < LB16) line_buf[{~bank, pay_cnt[LA-1:0]}] <= rx_byte;
            pay_cnt <= pay_cnt + 16'd1;
            if (pay_cnt == wc - 16'd1) state <= S_CRC0;
          end
          S_CRC0: begin crc_lo <= rx_byte; state <= S_CRC1; end
          S_CRC1: begin
            state <= S_NEXT;
            if ({rx_byte, crc_lo} == crc) begin
              irq <= 1'b0; line_cnt <= line_cnt + 16'd1; bank <= ~bank;
              lb_len <= (wc > LB16) ? LB16 : wc;
            end else begin
              irq <= 1'b1; err_flags[0] <= 1'b1;
            end
          end
          default: ;                                    // S_EOT: ignore to burst end
        endcase
      end
    end
  end

  assign lb_rdata = line_buf[{bank, lb_addr}];

endmodule
