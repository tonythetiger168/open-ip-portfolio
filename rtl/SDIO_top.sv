// SPDX-License-Identifier: Apache-2.0
// ============================================================================
// SDIO protocol Open IP -- SDIO card/slave (CMD52/CMD53, R5, CRC7/CRC16)
// -- Apache-2.0
// Open IP design implementation v2.5
// ============================================================================
//
// Scope: card-side SDIO subset, function 1 only, 4-bit bus.
//  * CMD line: host drives a command (card Hi-Z), the card drives R5.
//    Everything is sampled / driven on sd_clk rising edges.
//  * Frame: start(0) + tx(1 host / 0 card) + cmdidx[6] + arg[32] + CRC7[7]
//    + end(1), 48 bits, MSB first. CRC7 poly x^7+x^3+1.
//  * CMD52 IO_RW_DIRECT: arg[31] r/w, [30:28] function, [27] RAW,
//    [25:9] register address, [7:0] write data. The R5 data field is the
//    register value (after the write for a write; with RAW = 0 this is the
//    written value as well, the register file has no side effects).
//  * CMD53 IO_RW_EXTENDED: arg[31] r/w, [30:28] function, [27] block mode
//    (not supported: ILLEGAL_COMMAND), [26] OP code (1 = incrementing
//    address), [25:9] address, [8:0] byte count (0 = 512).
//  * Function 1 register file: 128 x 8 bit, addresses 0..127.
//  * R5: start, tx = 0, index, 16 stuff bits, flags[7:0], data[7:0], CRC7,
//    end. Flags: [7] COM_CRC_ERROR and [6] ILLEGAL_COMMAND report an error
//    of the previous command (that command got no response) and clear once
//    reported; [5:4] IO_CURRENT_STATE = 01 (CMD); [1] FUNCTION_NUMBER for a
//    function other than 1; [0] OUT_OF_RANGE for an address above 127, a
//    CMD53 count above 32 (the transfer buffer) or an incrementing
//    transfer that runs past address 127. A command with [1] or [0] set is
//    answered but not executed, and has no data phase.
//  * Data phase on DAT[3:0], 4-bit mode, both directions: start 0000,
//    2 nibbles per byte (high nibble first), one CRC16-CCITT per line
//    (16 clocks), end 1111.
//    write: after the end bits and 2 clocks the card drives the CRC status
//           token on DAT0: 0 + 010 (accepted) or 101 (CRC error) + 1. The
//           block is committed only when accepted.
//    read : the card sends the block 2 clocks after its R5.
//  * Bad CRC7, bad framing or an unsupported command index: no response,
//    flag for the next R5, irq pulse. Bad data CRC16 / end bits, or no
//    write block start within 64 clocks: irq pulse, block discarded.
// Note: `clk` is the reserved system clock; the card runs on sd_clk.
module SDIO_top #(
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
  function automatic logic [6:0] crc7_bit(input logic [6:0] c, input logic d);
    logic fb;
    fb       = c[6] ^ d;
    crc7_bit = {c[5:3], c[2] ^ fb, c[1:0], fb};
  endfunction

  function automatic logic [6:0] crc7_40(input logic [39:0] m);
    logic [6:0] c;
    c = 7'h00;
    for (int i = 39; i >= 0; i--) c = crc7_bit(c, m[i]);
    crc7_40 = c;
  endfunction

  function automatic logic [15:0] crc16_bit(input logic [15:0] c, input logic d);
    logic fb;
    fb        = c[15] ^ d;
    crc16_bit = {c[14:12], c[11] ^ fb, c[10:5], c[4] ^ fb, c[3:0], fb};
  endfunction

  // ---------------- FSM ----------------
  typedef enum logic [3:0] {
    S_IDLE,      // waiting for a command start bit on CMD
    S_CMD,       // shifting in the 48-bit command frame
    S_RSP_DLY,   // turnaround gap before driving the R5 response
    S_RSP,       // driving the 48-bit R5 response
    S_DWR_WAIT,  // CMD53 write: waiting for the block start (0000)
    S_DWR_DATA,  // CMD53 write: 2*n nibbles
    S_DWR_CRC,   // CMD53 write: 16 CRC16 clocks, one CRC per line
    S_DWR_END,   // CMD53 write: end bits + CRC16 check
    S_DWR_STAT,  // CMD53 write: gap + CRC status token on DAT0
    S_DRD_START, // CMD53 read: drive start pattern 4'b0000
    S_DRD_DATA,  // CMD53 read: drive 2*n data nibbles on DAT[3:0]
    S_DRD_CRC,   // CMD53 read: drive 16 CRC16 clocks, one per DAT line
    S_DRD_END    // CMD53 read: drive end pattern 4'b1111
  } state_t;

  state_t      state;
  logic [5:0]  bit_cnt;     // generic bit/clock counter
  logic [1:0]  gap_cnt;     // response turnaround gap counter
  logic [46:0] shift;       // incoming command shift register (MSB first)
  logic [47:0] rsp;         // outgoing R5 response shift register (MSB first)

  (* ram_style = "block" *) logic [7:0]  reg1   [0:127];
  logic [7:0]  wr_buf [0:31];

  logic        do_data;     // CMD53 accepted with a data phase
  logic        cmd_is_wr;
  logic [5:0]  n_bytes;     // CMD53 byte count, 1..32
  logic [6:0]  base_addr;
  logic        arg_incr;
  logic        f_crc, f_ill; // previous command error flags (R5 [7:6])

  logic [5:0]  byte_cnt;
  logic        nib;         // 0 = high nibble, 1 = low nibble
  logic [3:0]  hi_nib;
  logic [15:0] crc16_l [0:3]; // per-DAT-line CRC16 (write: computed, read: sent)
  logic [15:0] crc16_rx [0:3]; // write: CRC16 received per line
  logic [5:0]  dwr_timeout;
  logic        wr_ok;

  logic        cmd_oe, cmd_out;
  logic [3:0]  dat_oe;      // per line: the CRC status token uses DAT0 only
  logic [3:0]  dat_out;

  assign cmd = cmd_oe ? cmd_out : 1'bz;
  for (genvar l = 0; l < 4; l++) begin : g_dat
    assign dat[l] = dat_oe[l] ? dat_out[l] : 1'bz;
  end

  wire  [6:0] cur_addr = base_addr + (arg_incr ? {1'b0, byte_cnt} : 7'd0);
  wire  [7:0] rd_byte  = reg1[cur_addr];

  // ---------------- command decode (valid when the 48th bit is sampled) ----
  wire [47:0] frame    = {shift, cmd};
  wire        fr_ok    = (frame[47] == 1'b0) && (frame[46] == 1'b1) && (frame[0] == 1'b1);
  wire        crc_ok   = crc7_40(frame[47:8]) == frame[7:1];
  wire [5:0]  f_idx    = frame[45:40];
  wire        f_wr     = frame[39];
  wire [2:0]  f_fn     = frame[38:36];
  wire [16:0] f_addr   = frame[33:17];
  wire [8:0]  f_cnt    = frame[16:8];
  wire        is52     = f_idx == 6'd52;
  wire        is53     = f_idx == 6'd53 && !frame[35];   // byte mode only
  wire        e_fn     = f_fn != 3'd1;
  wire [7:0]  a_end    = {1'b0, f_addr[6:0]} + 8'(f_cnt[5:0]);
  wire        e_range  = f_addr[16:7] != 10'd0 ||
                         (is53 && (f_cnt == 9'd0 || f_cnt > 9'd32 ||
                                   (frame[34] && a_end > 8'd128)));
  wire        exec     = !e_fn && !e_range;
  wire [7:0]  r5_data  = (is52 && exec) ? (f_wr ? frame[15:8] : reg1[f_addr[6:0]]) : 8'h00;

  // R5 frame: start, tx = 0, index, stuff, flags, data, CRC7, end
  function automatic logic [47:0] r5(input logic [5:0] idx, input logic fc, input logic fi,
                                     input logic efn, input logic erg, input logic [7:0] d);
    logic [39:0] p;
    p  = {2'b00, idx, 16'h0000, fc, fi, 2'b01, 2'b00, efn, erg, d};
    r5 = {p, crc7_40(p), 1'b1};
  endfunction

  // write-block CRC16 check across the four lines
  logic crc_rx_ok;
  always_comb begin
    crc_rx_ok = 1'b1;
    for (int l = 0; l < 4; l++) if (crc16_rx[l] != crc16_l[l]) crc_rx_ok = 1'b0;
  end

  // ---------------- bit-rate divider ----------------
  localparam int BCW = (BIT_CLKS <= 1) ? 1 : $clog2(BIT_CLKS);
  logic [BCW-1:0] bd_cnt;
  wire bit_tick = (BIT_CLKS <= 1) || (bd_cnt == BCW'(BIT_CLKS-1));
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
      do_data     <= 1'b0;
      cmd_is_wr   <= 1'b0;
      n_bytes     <= '0;
      base_addr   <= '0;
      arg_incr    <= 1'b0;
      f_crc       <= 1'b0;
      f_ill       <= 1'b0;
      byte_cnt    <= '0;
      nib         <= 1'b0;
      hi_nib      <= '0;
      dwr_timeout <= '0;
      wr_ok       <= 1'b0;
      cmd_oe      <= 1'b0;
      cmd_out     <= 1'b1;
      dat_oe      <= 4'b0000;
      dat_out     <= 4'b1111;
      irq         <= 1'b0;
      for (int i = 0; i < 128; i++) reg1[i]   <= 8'h00;
      for (int i = 0; i < 32;  i++) wr_buf[i] <= 8'h00;
      for (int l = 0; l < 4;   l++) begin crc16_l[l] <= '0; crc16_rx[l] <= '0; end
    end else if (bit_tick) begin
      irq <= 1'b0;  // default: irq is a one-bit-time pulse
      case (state)
        // ---------------- idle: wait for command start bit ----------------
        S_IDLE: begin
          cmd_oe <= 1'b0;
          dat_oe <= 4'b0000;
          if (cmd == 1'b0) begin
            shift   <= '0;              // start bit captured
            bit_cnt <= 6'd1;
            state   <= S_CMD;
          end
        end

        // ---------------- receive the 48-bit command frame ----------------
        S_CMD: begin
          shift   <= frame[46:0];
          bit_cnt <= bit_cnt + 6'd1;
          if (bit_cnt == 6'd47) begin
            if (fr_ok && crc_ok && (is52 || is53)) begin
              rsp       <= r5(f_idx, f_crc, f_ill, e_fn, e_range, r5_data);
              f_crc     <= 1'b0;            // reported in this R5
              f_ill     <= 1'b0;
              gap_cnt   <= '0;
              state     <= S_RSP_DLY;
              cmd_is_wr <= f_wr;
              do_data   <= is53 && exec;
              n_bytes   <= f_cnt[5:0];
              base_addr <= f_addr[6:0];
              arg_incr  <= frame[34];
              if (is52 && exec && f_wr) reg1[f_addr[6:0]] <= frame[15:8];
            end else begin
              // bad CRC7 / framing / unsupported command: no response
              if (!fr_ok || !crc_ok) f_crc <= 1'b1;
              else                   f_ill <= 1'b1;
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
          bit_cnt <= bit_cnt + 6'd1;
          byte_cnt    <= '0;
          nib         <= 1'b0;
          dwr_timeout <= '0;
          gap_cnt     <= '0;
          for (int l = 0; l < 4; l++) crc16_l[l] <= '0;
          if (bit_cnt == 6'd47) begin
            if (!do_data)       state <= S_IDLE;
            else if (cmd_is_wr) state <= S_DWR_WAIT;
            else                state <= S_DRD_START;
          end
        end

        // ---------------- CMD53 write (host -> card) ----------------------
        S_DWR_WAIT: begin
          cmd_oe      <= 1'b0;
          dwr_timeout <= dwr_timeout + 6'd1;
          if (dat == 4'b0000) begin
            state <= S_DWR_DATA;        // start bits seen
          end else if (dwr_timeout == 6'd63) begin
            irq   <= 1'b1;              // host never sent the block
            state <= S_IDLE;
          end
        end

        S_DWR_DATA: begin
          for (int l = 0; l < 4; l++) crc16_l[l] <= crc16_bit(crc16_l[l], dat[l]);
          nib <= !nib;
          if (!nib) hi_nib <= dat;
          else begin
            wr_buf[byte_cnt[4:0]] <= {hi_nib, dat};
            byte_cnt <= byte_cnt + 6'd1;
            if (byte_cnt == n_bytes - 6'd1) begin
              bit_cnt <= '0;
              state   <= S_DWR_CRC;
            end
          end
        end

        S_DWR_CRC: begin
          for (int l = 0; l < 4; l++) crc16_rx[l] <= {crc16_rx[l][14:0], dat[l]};
          bit_cnt <= bit_cnt + 6'd1;
          if (bit_cnt == 6'd15) state <= S_DWR_END;
        end

        S_DWR_END: begin
          wr_ok   <= dat == 4'b1111 && crc_rx_ok;
          if (dat == 4'b1111 && crc_rx_ok) begin
            for (int i = 0; i < 32; i++)
              if (6'(i) < n_bytes)
                reg1[base_addr + (arg_incr ? 7'(i) : 7'd0)] <= wr_buf[i];
          end else irq <= 1'b1;         // bad CRC16 or end bits: discard
          bit_cnt <= '0;
          state   <= S_DWR_STAT;
        end

        // 2 clocks gap, then 0, status[2:0], 1 on DAT0, then release
        S_DWR_STAT: begin
          bit_cnt <= bit_cnt + 6'd1;
          case (bit_cnt)
            6'd0, 6'd1: ;
            6'd2: begin dat_oe <= 4'b0001; dat_out[0] <= 1'b0; end
            6'd3: dat_out[0] <= !wr_ok;
            6'd4: dat_out[0] <= wr_ok;
            6'd5: dat_out[0] <= !wr_ok;
            6'd6: dat_out[0] <= 1'b1;
            default: begin dat_oe <= 4'b0000; state <= S_IDLE; end
          endcase
        end

        // ---------------- CMD53 read (card -> host) -----------------------
        S_DRD_START: begin
          cmd_oe   <= 1'b0;
          gap_cnt  <= gap_cnt + 2'd1;
          if (gap_cnt == 2'd1) begin
            dat_oe  <= 4'b1111;
            dat_out <= 4'b0000;         // start bit on every line
            state   <= S_DRD_DATA;
          end
        end

        S_DRD_DATA: begin
          nib     <= !nib;
          dat_out <= nib ? rd_byte[3:0] : rd_byte[7:4];
          for (int l = 0; l < 4; l++)
            crc16_l[l] <= crc16_bit(crc16_l[l], nib ? rd_byte[l] : rd_byte[l + 4]);
          if (nib) begin
            byte_cnt <= byte_cnt + 6'd1;
            if (byte_cnt == n_bytes - 6'd1) begin
              bit_cnt <= '0;
              state   <= S_DRD_CRC;
            end
          end
        end

        S_DRD_CRC: begin
          for (int l = 0; l < 4; l++) begin
            dat_out[l] <= crc16_l[l][15];
            crc16_l[l] <= {crc16_l[l][14:0], 1'b0};
          end
          bit_cnt <= bit_cnt + 6'd1;
          if (bit_cnt == 6'd15) state <= S_DRD_END;
        end

        S_DRD_END: begin
          dat_out <= 4'b1111;           // end bit on every line
          state   <= S_IDLE;            // S_IDLE releases the lines next bit
        end

        default: state <= S_IDLE;
      endcase
    end
  end

  wire _unused = &{1'b0, clk};

endmodule
