// SPDX-License-Identifier: Apache-2.0
// ============================================================================
// SDIO protocol Open IP -- SDIO card/slave (CMD52/CMD53, R5, CRC7/CRC16)
// -- Apache-2.0
// Open IP design implementation v2.4
// ============================================================================
//
// Scope: card-side minimal SDIO subset.
//  * CMD line quasi-bidirectional: host drives while sending a command (card
//    Hi-Z), card drives during the R5 response. Sampled on sd_clk rising edge.
//  * Frame format: start(0) + tx(1=host/0=card) + cmdidx[6] + arg[32] +
//    CRC7[7] + end(1), 48 bits, MSB first.
//  * CMD52 IO_RW_DIRECT: arg[31]=r/w, arg[30:28]=func, arg[27]=raw,
//    arg[26]=stuff, arg[25:9]=addr[17], arg[8]=stuff, arg[7:0]=data.
//    Reads/writes the internal function-1 register file (128 x 8-bit) and
//    answers R5 (cmdidx=52, flags + read/write data + CRC7).
//  * CMD53 IO_RW_EXTENDED: arg[31]=r/w, arg[30:28]=func, arg[27]=block mode,
//    arg[26]=opcode (1=incrementing address), arg[25:9]=addr[17],
//    arg[8:0]=count. Byte mode only, 1..32 bytes (count==0 -> 32).
//    write: host shifts block on DAT0 (start + n*8 data bits + CRC16 + end),
//           card verifies CRC16 and commits the block only on match;
//    read : card drives block on DAT[3:0] (start 0000 + 2*n nibbles +
//           per-line CRC16 + end 1111).
//  * CRC7  poly 7'h09 (x^7+x^3+1), MSB-first, over frame bits [47:8].
//  * CRC16 poly 16'h1021 (CCITT), MSB-first, one instance per DAT line.
//  * Bad CRC7 / illegal command / bad CRC16 / missing end bit -> no response,
//    irq pulse of one sd_clk, transfer discarded.
// Note: `clk` is the reserved system clock; the whole card datapath runs on
//       the sd_clk line clock (documented simplification; clk kept so the
//       port contract stays intact).
module SDIO_top #(
  parameter int DW = 32,       // data width (kept for interface contract)
  parameter int AW = 32,       // address width (kept for interface contract)
  parameter int BIT_CLKS = 1   // sd_clk cycles per serial bit (bit-rate divider)
)(
  input  logic       clk,
  input  logic       rst_n,
  input  logic       sd_clk,
  inout  logic       cmd,
  inout  logic [3:0] dat,
  output logic       irq
);
  // ---------------- CRC helpers ----------------
  // CRC7, poly 7'h09 (x^7+x^3+1), MSB-first, init 0 (SD command CRC)
  function automatic logic [6:0] crc7_bit(input logic [6:0] c, input logic d);
    logic fb;
    begin
      fb       = c[6] ^ d;
      crc7_bit = {c[5:3], c[2] ^ fb, c[1:0], fb};
    end
  endfunction

  // CRC7 over a 40-bit message (bits 39..0 consumed MSB first)
  function automatic logic [6:0] crc7_40(input logic [39:0] m);
    logic [6:0] c;
    begin
      c = 7'h00;
      for (int i = 39; i >= 0; i--) c = crc7_bit(c, m[i]);
      crc7_40 = c;
    end
  endfunction

  // CRC16-CCITT, poly 16'h1021, MSB-first, init 0 (SD data line CRC)
  function automatic logic [15:0] crc16_bit(input logic [15:0] c, input logic d);
    logic fb;
    begin
      fb        = c[15] ^ d;
      crc16_bit = {c[14:12], c[11] ^ fb, c[10:5], c[4] ^ fb, c[3:0], fb};
    end
  endfunction

  // 7-bit address wrap (register file is 128 entries deep)
  function automatic logic [6:0] wrap_addr(input logic [6:0] a, input logic [6:0] off);
    wrap_addr = a + off;  // wraps modulo 128 naturally in 7-bit arithmetic
  endfunction

  // ---------------- FSM ----------------
  typedef enum logic [3:0] {
    S_IDLE,      // waiting for a command start bit on CMD
    S_CMD,       // shifting in the 48-bit command frame
    S_RSP_DLY,   // turnaround gap before driving the R5 response
    S_RSP,       // driving the 48-bit R5 response
    S_DWR_WAIT,  // CMD53 write: waiting for the data block start bit on DAT0
    S_DWR_DATA,  // CMD53 write: receiving n*8 data bits on DAT0
    S_DWR_CRC,   // CMD53 write: receiving the 16-bit CRC16 on DAT0
    S_DWR_END,   // CMD53 write: end bit + CRC16 check + commit
    S_DRD_START, // CMD53 read: drive start pattern 4'b0000
    S_DRD_DATA,  // CMD53 read: drive 2*n data nibbles on DAT[3:0]
    S_DRD_CRC,   // CMD53 read: drive 16 CRC16 clocks, one per DAT line
    S_DRD_END    // CMD53 read: drive end pattern 4'b1111
  } state_t;

  state_t      state;
  logic [6:0]  bit_cnt;     // generic bit/clock counter
  logic [1:0]  gap_cnt;     // response turnaround gap counter
  logic [47:0] shift;       // incoming command shift register (MSB first)
  logic [47:0] rsp;         // outgoing R5 response shift register (MSB first)

  // function-1 register file (128x8) and CMD53 write staging buffer
  (* ram_style = "block" *) logic [7:0]  reg1   [0:127];
  logic [7:0]  wr_buf [0:31];

  logic [5:0]  cmd_idx;     // decoded command index (52 or 53)
  logic        cmd_is_wr;   // decoded R/W flag
  logic [6:0]  n_bytes;     // CMD53 byte count, 1..32
  logic [6:0]  base_addr;   // register file base address
  logic        arg_incr;    // CMD53 opcode bit: 1 = incrementing address

  // CMD53 write path
  logic [6:0]  wr_byte_cnt;
  logic [2:0]  wr_bit_cnt;
  logic [7:0]  wr_shift;
  logic [15:0] crc16_wr;    // running CRC16 over received data bits
  logic [15:0] crc16_rcv;   // CRC16 shifted in from the host
  logic [6:0]  dwr_timeout; // start-bit timeout guard

  // CMD53 read path
  logic [6:0]  rd_byte_cnt;
  logic        rd_phase;    // 0 = high nibble, 1 = low nibble
  logic [15:0] crc16_rd [0:3]; // per-DAT-line CRC16

  // line drivers (quasi-bidirectional)
  logic        cmd_oe, cmd_out;
  logic        dat_oe;
  logic [3:0]  dat_out;

  assign cmd = cmd_oe ? cmd_out : 1'bz;
  assign dat = dat_oe ? dat_out : 4'bzzzz;

  // current read byte for the CMD53 read path (combinational regfile read)
  logic [7:0] rd_byte;
  assign rd_byte = reg1[wrap_addr(base_addr, arg_incr ? rd_byte_cnt : 7'd0)];

  // ---------------- command decode (valid when the 48th bit is sampled) ----
  logic [47:0] frame;
  logic        frame_ok, is52, is53;
  logic [8:0]  cnt53;
  logic [39:0] rsp_pre;
  logic [7:0]  rsp_data;

  // arg bit k of the command argument is frame bit k+8
  assign frame    = {shift[46:0], cmd};
  assign frame_ok = (frame[47] == 1'b0) && (frame[46] == 1'b1) &&
                    (frame[0]  == 1'b1) && (crc7_40(frame[47:8]) == frame[7:1]);
  assign is52     = frame_ok && (frame[45:40] == 6'd52) && (frame[38:36] == 3'd1);
  assign cnt53    = frame[16:8];                       // CMD53 byte count
  assign is53     = frame_ok && (frame[45:40] == 6'd53) && (frame[38:36] == 3'd1) &&
                    (frame[35] == 1'b0) &&             // byte mode only
                    (cnt53 <= 9'd32);
  // R5 response: start, tx=0(card), cmdidx, flags=0, stuff=0, data, CRC7, end
  assign rsp_data = is52 ? (frame[39] ? frame[15:8]          // CMD52 write echo
                                      : reg1[frame[23:17]])  // CMD52 read data
                         : 8'h00;                           // CMD53: no data
  assign rsp_pre  = {1'b0, 1'b0, frame[45:40], 8'h00, 16'h0000, rsp_data};

  // ---------------- sequential FSM (single sd_clk domain) ----------------
  // Bit-rate divider: the bit-level FSM advances only on bit_tick.
  // BIT_CLKS=1 keeps the legacy 1-bit-per-sd_clk behavior (bit_tick constant 1).
  localparam int BCW = (BIT_CLKS <= 1) ? 1 : $clog2(BIT_CLKS);
  logic [BCW-1:0] bd_cnt;
  wire bit_tick = (BIT_CLKS <= 1) || (bd_cnt == BIT_CLKS-1);
  always_ff @(posedge sd_clk or negedge rst_n) begin
    if (!rst_n)          bd_cnt <= '0;
    else if (bit_tick)   bd_cnt <= '0;
    else                 bd_cnt <= bd_cnt + 1'b1;
  end

  always_ff @(posedge sd_clk or negedge rst_n) begin
    if (!rst_n) begin
      state       <= S_IDLE;
      bit_cnt     <= '0;
      gap_cnt     <= '0;
      shift       <= '0;
      rsp         <= '0;
      cmd_idx     <= '0;
      cmd_is_wr   <= 1'b0;
      n_bytes     <= '0;
      base_addr   <= '0;
      arg_incr    <= 1'b0;
      wr_byte_cnt <= '0;
      wr_bit_cnt  <= '0;
      wr_shift    <= '0;
      crc16_wr    <= '0;
      crc16_rcv   <= '0;
      dwr_timeout <= '0;
      rd_byte_cnt <= '0;
      rd_phase    <= 1'b0;
      cmd_oe      <= 1'b0;
      cmd_out     <= 1'b1;
      dat_oe      <= 1'b0;
      dat_out     <= 4'b1111;
      irq         <= 1'b0;
      for (int i = 0; i < 128; i++) reg1[i]   <= 8'h00;
      for (int i = 0; i < 32;  i++) wr_buf[i] <= 8'h00;
      for (int l = 0; l < 4;   l++) crc16_rd[l] <= 16'h0000;
    end else begin
      if (bit_tick) begin
      irq <= 1'b0;  // default: irq is a one-sd_clk pulse
      case (state)
        // ---------------- idle: wait for command start bit ----------------
        S_IDLE: begin
          cmd_oe <= 1'b0;
          dat_oe <= 1'b0;
          if (cmd == 1'b0) begin
            shift   <= {47'd0, 1'b0};   // start bit captured
            bit_cnt <= 7'd1;
            state   <= S_CMD;
          end
        end

        // ---------------- receive the 48-bit command frame ----------------
        S_CMD: begin
          shift   <= {shift[46:0], cmd};
          bit_cnt <= bit_cnt + 7'd1;
          if (bit_cnt == 7'd47) begin
            // frame complete: decode combinationally from `frame`
            if (is52 || is53) begin
              cmd_idx   <= frame[45:40];
              cmd_is_wr <= frame[39];
              rsp       <= {rsp_pre, crc7_40(rsp_pre), 1'b1};
              gap_cnt   <= '0;
              state     <= S_RSP_DLY;
              if (is52) begin
                if (frame[39]) reg1[frame[23:17]] <= frame[15:8]; // write
              end else begin
                n_bytes     <= (cnt53 == 9'd0) ? 7'd32 : cnt53[6:0];
                base_addr   <= frame[23:17];
                arg_incr    <= frame[34];
                wr_byte_cnt <= '0;
                wr_bit_cnt  <= '0;
                wr_shift    <= '0;
                crc16_wr    <= '0;
                crc16_rcv   <= '0;
                dwr_timeout <= '0;
              end
            end else begin
              // bad CRC7 / bad frame / illegal command: no response
              irq   <= 1'b1;
              state <= S_IDLE;
            end
          end
        end

        // ---------------- turnaround gap, then drive R5 -------------------
        S_RSP_DLY: begin
          gap_cnt <= gap_cnt + 2'd1;
          if (gap_cnt == 2'd2) begin
            bit_cnt <= '0;
            state   <= S_RSP;
          end
        end

        S_RSP: begin
          cmd_oe  <= 1'b1;
          cmd_out <= rsp[47];
          rsp     <= {rsp[46:0], 1'b1};
          bit_cnt <= bit_cnt + 7'd1;
          if (bit_cnt == 7'd47) begin
            cmd_oe <= 1'b0;
            if (cmd_idx == 6'd53) begin
              state <= cmd_is_wr ? S_DWR_WAIT : S_DRD_START;
            end else begin
              state <= S_IDLE;
            end
          end
        end

        // ---------------- CMD53 write (host -> card, DAT0) ----------------
        S_DWR_WAIT: begin
          dwr_timeout <= dwr_timeout + 7'd1;
          if (dat[0] == 1'b0) begin
            state <= S_DWR_DATA;   // start bit seen
          end else if (dwr_timeout == 7'd64) begin
            irq   <= 1'b1;         // host never sent the block
            state <= S_IDLE;
          end
        end

        S_DWR_DATA: begin
          wr_shift  <= {wr_shift[6:0], dat[0]};
          crc16_wr  <= crc16_bit(crc16_wr, dat[0]);
          wr_bit_cnt <= wr_bit_cnt + 3'd1;
          if (wr_bit_cnt == 3'd7) begin
            wr_buf[wr_byte_cnt[4:0]] <= {wr_shift[6:0], dat[0]};
            wr_byte_cnt <= wr_byte_cnt + 7'd1;
            if (wr_byte_cnt == n_bytes - 7'd1) begin
              bit_cnt <= '0;
              state   <= S_DWR_CRC;
            end
          end
        end

        S_DWR_CRC: begin
          crc16_rcv <= {crc16_rcv[14:0], dat[0]};
          bit_cnt   <= bit_cnt + 7'd1;
          if (bit_cnt == 7'd15) state <= S_DWR_END;
        end

        S_DWR_END: begin
          if (dat[0] == 1'b1 && crc16_rcv == crc16_wr) begin
            // CRC16 matches: commit the staged block to the register file
            for (int i = 0; i < 32; i++) begin
              if (i[6:0] < n_bytes)
                reg1[wrap_addr(base_addr, arg_incr ? i[6:0] : 7'd0)] <= wr_buf[i[4:0]];
            end
          end else begin
            irq <= 1'b1;             // bad CRC16 or missing end bit: discard
          end
          state <= S_IDLE;
        end

        // ---------------- CMD53 read (card -> host, DAT[3:0]) -------------
        S_DRD_START: begin
          dat_oe      <= 1'b1;
          dat_out     <= 4'b0000;    // start bit on every line
          rd_byte_cnt <= '0;
          rd_phase    <= 1'b0;
          for (int l = 0; l < 4; l++) crc16_rd[l] <= 16'h0000;
          state       <= S_DRD_DATA;
        end

        S_DRD_DATA: begin
          dat_oe <= 1'b1;
          if (!rd_phase) begin
            dat_out      <= {rd_byte[7], rd_byte[6], rd_byte[5], rd_byte[4]};
            crc16_rd[3]  <= crc16_bit(crc16_rd[3], rd_byte[7]);
            crc16_rd[2]  <= crc16_bit(crc16_rd[2], rd_byte[6]);
            crc16_rd[1]  <= crc16_bit(crc16_rd[1], rd_byte[5]);
            crc16_rd[0]  <= crc16_bit(crc16_rd[0], rd_byte[4]);
            rd_phase     <= 1'b1;
          end else begin
            dat_out      <= {rd_byte[3], rd_byte[2], rd_byte[1], rd_byte[0]};
            crc16_rd[3]  <= crc16_bit(crc16_rd[3], rd_byte[3]);
            crc16_rd[2]  <= crc16_bit(crc16_rd[2], rd_byte[2]);
            crc16_rd[1]  <= crc16_bit(crc16_rd[1], rd_byte[1]);
            crc16_rd[0]  <= crc16_bit(crc16_rd[0], rd_byte[0]);
            rd_phase     <= 1'b0;
            if (rd_byte_cnt == n_bytes - 7'd1) begin
              bit_cnt <= '0;
              state   <= S_DRD_CRC;
            end else begin
              rd_byte_cnt <= rd_byte_cnt + 7'd1;
            end
          end
        end

        S_DRD_CRC: begin
          dat_oe  <= 1'b1;
          dat_out <= {crc16_rd[3][15], crc16_rd[2][15],
                      crc16_rd[1][15], crc16_rd[0][15]};
          for (int l = 0; l < 4; l++)
            crc16_rd[l] <= {crc16_rd[l][14:0], 1'b0};
          bit_cnt <= bit_cnt + 7'd1;
          if (bit_cnt == 7'd15) state <= S_DRD_END;
        end

        S_DRD_END: begin
          dat_oe  <= 1'b1;
          dat_out <= 4'b1111;        // end bit on every line
          state   <= S_IDLE;         // S_IDLE releases the lines next clock
        end

        default: state <= S_IDLE;
      endcase
      end // bit_tick
    end
  end

endmodule
