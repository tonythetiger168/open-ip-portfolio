// SPDX-License-Identifier: Apache-2.0
// ============================================================================
// MIPI CSI-2 receiver (camera side link, packet layer)
// Implementation scope:
//   * Serial HS input model: 1 bit/clk on rx_bit while rx_valid is high,
//     LSB-first per byte (D-PHY/lane deskew abstracted, see note in body)
//   * SoT hunt: 8'hB8 sync byte, then packet header DI/VC + WC/data[15:0]
//     + ECC byte (Hamming(30,24) subset, P7=P6=0):
//       - syndrome == 0            -> clean header
//       - syndrome in D0..D23 table-> single error corrected in place
//       - syndrome == 6'h01..6'h20 -> error inside ECC byte itself, data ok
//       - otherwise                -> uncorrectable, packet dropped + irq
//   * Short packets (DT 6'h00..6'h0F): FS=0x00 / FE=0x01 frame control,
//     LS=0x02 / LE=0x03 line control, 16-bit data field captured
//   * Long packets (DT >= 6'h10, e.g. RAW8=0x2B): WC[15:0] payload bytes
//     into a 1-line x 512-byte pixel buffer, then CRC-16/CCITT
//     (poly 0x1021, init 0xFFFF, LSB-first on the wire) checked; bad CRC
//     drops the line and raises irq
//   * Status: frame_cnt / line_cnt, last DT/VC/WC, error flags, line
//     buffer read-out port (lb_addr/lb_rdata + lb_len)
// IP design implementation v1.0 -- Apache-2.0
// ============================================================================
module CSI_2_top #(
  parameter int DW = 32,            // retained framework parameter (data width)
  parameter int AW = 32,            // retained framework parameter (address width)
  parameter int LINE_BYTES = 512    // pixel line buffer depth
)(
  input  logic        clk,
  input  logic        rst_n,
  // serial lane input (1 bit/clk, LSB first)
  input  logic        rx_bit,
  input  logic        rx_valid,
  // interrupt / status
  output logic        irq,           // protocol error, sticky until next good packet
  output logic        frame_active,
  output logic [15:0] frame_cnt,
  output logic [15:0] line_cnt,
  output logic [7:0]  last_dt,       // {VC[1:0], DT[5:0]} of last accepted header
  output logic [15:0] last_wc,       // WC (long) or data field (short)
  output logic [3:0]  err_flags,     // [0]crc [1]ecc_uncorr [2]abort [3]ecc_corrected
  output logic [15:0] lb_len,        // bytes committed in line buffer
  // line buffer read port
  input  logic [8:0]  lb_addr,
  output logic [7:0]  lb_rdata
);

  // ------------------------------------------------------------------
  // constants
  // ------------------------------------------------------------------
  localparam logic [7:0] SOT_SYNC = 8'hB8;   // CSI-2 SoT code on the wire
  localparam logic [5:0] DT_FS    = 6'h00;
  localparam logic [5:0] DT_FE    = 6'h01;
  localparam logic [5:0] DT_LS    = 6'h02;
  localparam logic [5:0] DT_LE    = 6'h03;

  typedef enum logic [2:0] {
    S_SYNC, S_HDR0, S_HDR1, S_HDR2, S_ECC, S_PAY, S_CRC0, S_CRC1
  } state_t;

  localparam logic [15:0] LB16 = 16'(LINE_BYTES);

  state_t       state;
  logic [7:0]   shreg;        // serial->parallel shift register
  logic [2:0]   bit_cnt;
  logic [23:0]  hdr;          // {WC/data[15:8], WC/data[7:0], DI}
  logic [15:0]  wc;           // corrected word count
  logic [15:0]  pay_cnt;
  logic [15:0]  crc;          // running CRC-16 over payload
  logic [7:0]   crc_lo;
  logic [5:0]   dt_c;         // corrected DT (registered at ECC phase)
  logic [5:0]   eb;           // ECC syndrome bit index (S_ECC decode)
  logic [23:0]  hc;           // corrected header (S_ECC decode)
  (* ram_style = "block" *) logic [7:0]   line_buf [0:LINE_BYTES-1];

  // ------------------------------------------------------------------
  // ECC (Hamming(30,24) subset per MIPI CSI-2/DSI, P7=P6=0)
  // parity equations derived from the spec syndrome association matrix
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

  // syndrome -> errored bit index (0..23 = data bit, 24..29 = ECC bit,
  // 63 = uncorrectable / not a single-bit error)
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

  // ------------------------------------------------------------------
  // CRC-16/CCITT (poly 0x1021), reflected I/O as used on the CSI-2 wire
  // ------------------------------------------------------------------
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
  // byte assembly + packet FSM
  // ------------------------------------------------------------------
  wire [7:0] rx_byte  = {rx_bit, shreg[7:1]};   // LSB first
  wire       byte_rdy = rx_valid && (bit_cnt == 3'd7);

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      state        <= S_SYNC;
      shreg        <= 8'h00;
      bit_cnt      <= 3'd0;
      hdr          <= 24'h0;
      eb           <= 6'h0;
      hc           <= 24'h0;
      wc           <= 16'h0;
      pay_cnt      <= 16'h0;
      crc          <= 16'hFFFF;
      crc_lo       <= 8'h00;
      dt_c         <= 6'h00;
      irq          <= 1'b0;
      frame_active <= 1'b0;
      frame_cnt    <= 16'h0;
      line_cnt     <= 16'h0;
      last_dt      <= 8'h00;
      last_wc      <= 16'h0;
      err_flags    <= 4'h0;
      lb_len       <= 16'h0;
    end else begin
      // ---- serial->parallel ----
      if (rx_valid) begin
        shreg <= rx_byte;
        if (byte_rdy) bit_cnt <= 3'd0;
        else          bit_cnt <= bit_cnt + 3'd1;
      end else begin
        bit_cnt <= 3'd0;
        // link went idle mid-packet: abort (LP-11 / EoT without full packet)
        if (state != S_SYNC) begin
          state          <= S_SYNC;
          err_flags[2]   <= 1'b1;
        end
      end

      if (byte_rdy) begin
        case (state)
          // ---- SoT sync hunt ----
          S_SYNC: begin
            if (rx_byte == SOT_SYNC) begin
              state <= S_HDR0;
              crc   <= 16'hFFFF;
            end
          end
          // ---- packet header ----
          S_HDR0: begin
            hdr[7:0] <= rx_byte;
            state    <= S_HDR1;
          end
          S_HDR1: begin
            hdr[15:8] <= rx_byte;
            state     <= S_HDR2;
          end
          S_HDR2: begin
            hdr[23:16] <= rx_byte;
            state      <= S_ECC;
          end
          // ---- ECC byte: correct or drop (decide on rx_byte this cycle) ----
          S_ECC: begin
            if ((rx_byte[5:0] ^ ecc24(hdr)) == 6'h00) begin
              // clean header
              irq       <= 1'b0;
              last_dt   <= hdr[7:0];
              last_wc   <= hdr[23:8];
              if (hdr[5:0] < 6'h10) begin
                // short packet
                state <= S_SYNC;
                case (hdr[5:0])
                  DT_FS: begin
                    frame_active <= 1'b1;
                    frame_cnt    <= frame_cnt + 16'd1;
                    line_cnt     <= 16'h0;
                  end
                  DT_FE: frame_active <= 1'b0;
                  DT_LE: line_cnt     <= line_cnt + 16'd1;
                  default: ;
                endcase
              end else begin
                // long packet
                dt_c    <= hdr[5:0];
                wc      <= hdr[23:8];
                pay_cnt <= 16'h0;
                state   <= (hdr[23:8] == 16'h0) ? S_CRC0 : S_PAY;
              end
            end else if (ecc_bit(rx_byte[5:0] ^ ecc24(hdr)) != 6'd63) begin
              // single-bit error: correct it (data bits) or accept (ECC bits)
              eb = ecc_bit(rx_byte[5:0] ^ ecc24(hdr));
              hc = (eb < 6'd24) ? (hdr ^ (24'h000001 << eb)) : hdr;
              irq          <= 1'b0;
              err_flags[3] <= 1'b1;               // corrected-error event
              last_dt      <= hc[7:0];
              last_wc      <= hc[23:8];
              if (hc[5:0] < 6'h10) begin
                state <= S_SYNC;
                case (hc[5:0])
                  DT_FS: begin
                    frame_active <= 1'b1;
                    frame_cnt    <= frame_cnt + 16'd1;
                    line_cnt     <= 16'h0;
                  end
                  DT_FE: frame_active <= 1'b0;
                  DT_LE: line_cnt     <= line_cnt + 16'd1;
                  default: ;
                endcase
              end else begin
                dt_c    <= hc[5:0];
                wc      <= hc[23:8];
                pay_cnt <= 16'h0;
                state   <= (hc[23:8] == 16'h0) ? S_CRC0 : S_PAY;
              end
            end else begin
              // uncorrectable: drop packet
              state        <= S_SYNC;
              irq          <= 1'b1;
              err_flags[1] <= 1'b1;
            end
          end
          // ---- long packet payload ----
          S_PAY: begin
            crc <= crc16_byte(crc, rx_byte);
            if (pay_cnt < LB16)
              line_buf[pay_cnt[8:0]] <= rx_byte;
            pay_cnt <= pay_cnt + 16'd1;
            if (pay_cnt == wc - 16'd1)
              state <= S_CRC0;
          end
          // ---- packet footer CRC-16 ----
          S_CRC0: begin
            crc_lo <= rx_byte;
            state  <= S_CRC1;
          end
          S_CRC1: begin
            state <= S_SYNC;
            if ({rx_byte, crc_lo} == crc) begin
              // good packet: commit the line
              irq       <= 1'b0;
              line_cnt  <= line_cnt + 16'd1;
              lb_len    <= (wc > LB16) ? LB16 : wc;
            end else begin
              irq          <= 1'b1;
              err_flags[0] <= 1'b1;
            end
          end
          default: state <= S_SYNC;
        endcase
      end
    end
  end

  // ------------------------------------------------------------------
  // line buffer read port (combinational, TB/host observes last line)
  // ------------------------------------------------------------------
  assign lb_rdata = line_buf[lb_addr];

endmodule
