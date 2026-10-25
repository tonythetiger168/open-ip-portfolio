// SPDX-License-Identifier: Apache-2.0
// ============================================================================
// LIN_top v2.0: LIN 2.2A node (ISO 17987), commander and responder roles
// ----------------------------------------------------------------------------
//  - Bus: rxd/txd, 0 = dominant, txd open-drain style (1 = released).
//    Bytes are UART frames: start bit, 8 data bits LSB first, stop bit.
//  - Header: break (13 dominant bits, then a 1-bit delimiter), sync byte
//    0x55, protected identifier (6-bit ID + parity P0 = ID0^ID1^ID2^ID4,
//    P1 = ~(ID1^ID3^ID4^ID5)). A node with hdr_valid/hdr_ready sends one
//    (commander; ready when idle or when no role was taken in the current
//    frame); every node, the sender included, parses headers off the bus.
//  - Break detection: rxd dominant for 11 nominal bit times (cfg_bit
//    clocks per bit). Any break restarts the frame, whatever the state.
//  - Sync: the delimiter may last up to 14 nominal bits; the four intervals
//    between the five falling edges of 0x55 must each last 1.5..2.5 nominal
//    bits; with cfg_autobaud the bit time for the
//    rest of the frame is their sum / 8 (responders without a crystal),
//    otherwise cfg_bit (the measurement saturates at 65535). Bit 7 and
//    the stop bit of the sync byte are checked.
//  - Response: after pid_valid the host picks this node's role through
//    rsp_valid (rsp_ready high while undecided): publish rsp_len+1 data
//    bytes of rsp_data (byte 0 in bits 7:0, sent first) or subscribe to
//    rsp_len+1 bytes; a published response starts at the end of the PID
//    stop bit at the earliest. Checksum: inverted 8-bit sum with
//    end-around carry over the data (classic), plus the protected ID when
//    rsp_enh (enhanced);
//    IDs 60..63 always use classic. Undecided at the first response start
//    bit, or 126 bit times after the header (the timeout of the longest
//    response): the frame is ignored.
//  - Errors (one-clock pulses): err_bit (sent bit read back wrong; the node
//    stops sending), err_sync, err_parity, err_frame (stop bit dominant),
//    err_chk, err_timeout (subscribed response not complete within
//    1.4 x 10 x (bytes + 1) bit times after the header).
//  Not implemented: sleep and wake-up, bus-idle timeout, transport layer.
// ============================================================================
module LIN_top (
  input  logic        clk,
  input  logic        rst_n,
  input  logic        rxd,
  output logic        txd,
  input  logic [15:0] cfg_bit,       // nominal bit time in clocks (>= 16)
  input  logic        cfg_autobaud,
  // commander: send a header
  input  logic        hdr_valid,
  output logic        hdr_ready,
  input  logic [5:0]  hdr_id,
  // headers seen on the bus
  output logic        pid_valid,
  output logic [5:0]  pid_id,
  // this node's role in the response
  output logic        rsp_ready,
  input  logic        rsp_valid,
  input  logic        rsp_pub,
  input  logic [2:0]  rsp_len,       // data bytes - 1
  input  logic        rsp_enh,
  input  logic [63:0] rsp_data,
  output logic        tx_done,
  output logic        rx_valid,
  output logic [5:0]  rx_id,
  output logic [2:0]  rx_len,
  output logic [63:0] rx_data,
  output logic        err_bit,
  output logic        err_sync,
  output logic        err_parity,
  output logic        err_frame,
  output logic        err_chk,
  output logic        err_timeout,
  output logic [15:0] bit_time       // bit time of the current frame
);
  // ---------------- input synchroniser ----------------
  logic rx_m, rx_s, rx_d;
  always_ff @(posedge clk or negedge rst_n)
    if (!rst_n) begin rx_m <= 1'b1; rx_s <= 1'b1; rx_d <= 1'b1; end
    else begin rx_m <= rxd; rx_s <= rx_m; rx_d <= rx_s; end
  wire fall = rx_d && !rx_s;

  function automatic logic [7:0] pid_of(input logic [5:0] id);
    pid_of = {~(id[1] ^ id[3] ^ id[4] ^ id[5]), id[0] ^ id[1] ^ id[2] ^ id[4], id};
  endfunction
  function automatic logic [7:0] csum_add(input logic [7:0] s, input logic [7:0] b);
    logic [8:0] t;
    t = {1'b0, s} + {1'b0, b};
    csum_add = t[7:0] + {7'd0, t[8]};
  endfunction

  // ---------------- break detector ----------------
  wire  [19:0] brk_thr = {cfg_bit, 3'b000} + {3'b000, cfg_bit, 1'b0} + {4'h0, cfg_bit};  // 11 bits
  logic [19:0] dom_cnt;
  wire         brk = !rx_s && dom_cnt == brk_thr - 20'd1;
  always_ff @(posedge clk or negedge rst_n)
    if (!rst_n) dom_cnt <= '0;
    else if (rx_s) dom_cnt <= '0;
    else if (dom_cnt != brk_thr) dom_cnt <= dom_cnt + 20'd1;

  // ---------------- frame state ----------------
  typedef enum logic [2:0] {F_IDLE, F_BREAK, F_SYNC, F_PID, F_RSP, F_RX, F_TX} fst_t;
  fst_t        fst;
  logic [15:0] bt;                   // bit time of this frame
  logic [2:0]  s_edges;              // sync: falling edges seen
  logic [19:0] s_sum;                // sync: clocks from the first edge
  logic [19:0] s_int;                // sync: clocks since the delimiter / last edge
  wire  [16:0] lim_lo = {1'b0, cfg_bit} + {2'b0, cfg_bit[15:1]};              // 1.5 bits
  wire  [17:0] lim_hi = {1'b0, cfg_bit, 1'b0} + {3'b0, cfg_bit[15:1]};        // 2.5 bits
  wire  [18:0] lim_dl7 = {cfg_bit, 3'h0} - {3'h0, cfg_bit};                    // 7 bits (x2: 14)
  wire  [16:0] s_avg  = 17'((s_sum + 20'd5) >> 3);   // clocks over 8 bits (+1), +4 to round
  wire  [15:0] meas   = s_avg[16] ? 16'hFFFF : s_avg[15:0];   // saturates
  logic [7:0]  pid;
  logic [2:0]  r_len;
  logic [63:0] r_data;               // published or received data
  logic [3:0]  r_idx;                // response byte index (r_len + 1: checksum)
  logic [7:0]  r_sum;                // running checksum of the received bytes
  logic [15:0] t_cnt;                // response timer: clocks in the bit
  logic [6:0]  t_bits;               //                 bits since the header
  wire  [5:0]  t_lim2 = 6'd7 * {2'd0, 4'(r_len) + 4'd2};   // half the limit in bits
  wire         classic = pid[5:2] == 4'hF;

  // byte receiver
  logic        r_busy;
  logic [3:0]  r_k;                  // 0 start, 1..8 data, 9 stop
  logic [15:0] r_cnt;                // clocks to the next sample
  logic [7:0]  r_sh;
  logic        rx_start;             // start a byte at this falling edge
  wire         r_smp  = r_busy && r_cnt == 16'd0;
  wire  [7:0]  r_byte = r_sh;        // complete at the stop-bit sample

  // transmitter
  typedef enum logic [1:0] {T_IDLE, T_BRK, T_DEL, T_BYTES} tst_t;
  tst_t        tst;
  logic [15:0] t_bc;                 // clocks in the current bit
  logic [3:0]  t_k;                  // bit in the byte / break bit count
  logic [3:0]  t_i;                  // byte index
  logic [3:0]  t_n;                  // bytes to send - 1
  logic        t_hdr;                // sending a header
  logic [7:0]  t_sum;                // checksum of the response bytes sent
  logic        drv;
  wire  [15:0] t_bt  = t_hdr ? cfg_bit : bt;
  wire         t_end = t_bc == t_bt - 16'd1;        // last clock of the bit
  wire         t_chk = t_bc == {1'b0, t_bt[15:1]};  // read back at mid-bit
  logic [5:0]  hdr_id_q;
  logic [7:0]  t_byte;
  always_comb begin
    if (t_hdr)            t_byte = t_i == 4'd0 ? 8'h55 : pid_of(hdr_id_q);
    else if (t_i <= {1'b0, r_len}) t_byte = r_data[{t_i[2:0], 3'b000} +: 8];
    else                  t_byte = ~t_sum;
  end
  logic        tx_pend;              // publish decided, waiting for the transmitter
  logic        sp_ok;                // half a bit since the PID stop-bit sample: stop bit over

  assign txd       = drv;
  assign hdr_ready = (fst == F_IDLE || fst == F_RSP) && tst == T_IDLE;   // not while in a response
  assign rsp_ready = fst == F_RSP;
  assign bit_time  = bt;

  always_comb begin
    rx_start = 1'b0;
    if (!r_busy && fall)
      case (fst)
        F_PID: rx_start = 1'b1;
        F_RX:  rx_start = 1'b1;
        F_RSP: rx_start = rsp_valid && !rsp_pub;
        default: ;
      endcase
  end

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      fst <= F_IDLE; bt <= '0; s_edges <= '0; s_sum <= '0; s_int <= '0; pid <= '0;
      r_len <= '0; r_data <= '0; r_idx <= '0; r_sum <= '0;
      t_cnt <= '0; t_bits <= '0;
      r_busy <= 1'b0; r_k <= '0; r_cnt <= '0; r_sh <= '0;
      tst <= T_IDLE; t_bc <= '0; t_k <= '0; t_i <= '0; t_n <= '0; t_hdr <= 1'b0; t_sum <= '0;
      drv <= 1'b1; hdr_id_q <= '0; tx_pend <= 1'b0; sp_ok <= 1'b0;
      pid_valid <= 1'b0; pid_id <= '0; tx_done <= 1'b0;
      rx_valid <= 1'b0; rx_id <= '0; rx_len <= '0; rx_data <= '0;
      err_bit <= 1'b0; err_sync <= 1'b0; err_parity <= 1'b0; err_frame <= 1'b0;
      err_chk <= 1'b0; err_timeout <= 1'b0;
    end else begin
      pid_valid <= 1'b0; tx_done <= 1'b0; rx_valid <= 1'b0;
      err_bit <= 1'b0; err_sync <= 1'b0; err_parity <= 1'b0; err_frame <= 1'b0;
      err_chk <= 1'b0; err_timeout <= 1'b0;

      // ---------------- byte receiver
      if (rx_start) begin
        r_busy <= 1'b1; r_k <= '0; r_cnt <= {1'b0, bt[15:1]} - 16'd1;
      end else if (r_busy) begin
        if (r_cnt != 16'd0) r_cnt <= r_cnt - 16'd1;
        else begin
          r_cnt <= bt - 16'd1;
          r_k   <= r_k + 4'd1;
          if (r_k >= 4'd1 && r_k <= 4'd8) r_sh <= {rx_s, r_sh[7:1]};
          if ((r_k == 4'd0 && rx_s) || r_k == 4'd9) r_busy <= 1'b0;  // glitch / done
        end
      end

      // ---------------- response timer
      if (fst == F_RSP || fst == F_RX || fst == F_TX) begin
        if (t_cnt == bt - 16'd1) begin t_cnt <= '0; t_bits <= t_bits + 7'd1; end
        else t_cnt <= t_cnt + 16'd1;
        if (t_cnt == {1'b0, bt[15:1]}) sp_ok <= 1'b1;
      end

      // ---------------- frame
      case (fst)
        F_IDLE: ;
        F_BREAK: if (rx_s) begin
          fst <= F_SYNC; s_edges <= '0; s_sum <= '0; s_int <= '0;
        end
        F_SYNC: begin
          s_int <= s_int + 20'd1;
          if (s_edges != 3'd0) s_sum <= s_sum + 20'd1;
          if (r_busy) begin                              // bit 7 and stop of 0x55
            if (r_smp && r_k == 4'd8 && rx_s) begin err_sync <= 1'b1; fst <= F_IDLE; end
            if (r_smp && r_k == 4'd9) begin
              if (!rx_s) begin err_sync <= 1'b1; fst <= F_IDLE; end
              else fst <= F_PID;
            end
          end else if (fall) begin
            s_edges <= s_edges + 3'd1;
            s_int   <= '0;
            if (s_edges != 3'd0 && s_int < {3'b0, lim_lo}) begin err_sync <= 1'b1; fst <= F_IDLE; end
            else if (s_edges == 3'd4) begin                // 5th edge: bit 7 starts
              bt     <= cfg_autobaud ? meas : cfg_bit;
              r_busy <= 1'b1; r_k <= 4'd8;
              r_cnt  <= (cfg_autobaud ? {1'b0, meas[15:1]} : {1'b0, cfg_bit[15:1]}) - 16'd1;
            end
          end else if (s_edges != 3'd0 ? s_int == {2'b0, lim_hi} : s_int == {lim_dl7, 1'b0}) begin
            err_sync <= 1'b1; fst <= F_IDLE;                 // edge missing, or delimiter too long
          end
        end
        F_PID: if (r_smp && r_k == 4'd9) begin
          if (!rx_s) begin err_frame <= 1'b1; fst <= F_IDLE; end
          else if (r_byte != pid_of(r_byte[5:0])) begin err_parity <= 1'b1; fst <= F_IDLE; end
          else begin
            pid <= r_byte; pid_valid <= 1'b1; pid_id <= r_byte[5:0];
            fst <= F_RSP; t_cnt <= '0; t_bits <= '0; sp_ok <= 1'b0;
          end
        end
        F_RSP: begin
          if (rsp_valid) begin
            r_len <= rsp_len; r_idx <= '0;
            r_data <= rsp_pub ? rsp_data : 64'h0;
            r_sum <= (rsp_enh && !classic) ? pid : 8'h00;
            fst <= rsp_pub ? F_TX : F_RX;
            tx_pend <= rsp_pub;
          end else if (fall || t_bits == 7'd126) fst <= F_IDLE;   // undecided: ignore the frame
        end
        F_RX: begin
          if (r_smp && r_k == 4'd9) begin
            if (!rx_s) begin err_frame <= 1'b1; fst <= F_IDLE; end
            else if (r_idx == {1'b0, r_len} + 4'd1) begin  // checksum byte
              if (r_byte == ~r_sum) begin
                rx_valid <= 1'b1; rx_id <= pid[5:0]; rx_len <= r_len; rx_data <= r_data;
              end else err_chk <= 1'b1;
              fst <= F_IDLE;
            end else begin
              r_data[{r_idx[2:0], 3'b000} +: 8] <= r_byte;
              r_sum <= csum_add(r_sum, r_byte);
              r_idx <= r_idx + 4'd1;
            end
          end else if (t_bits == {t_lim2, 1'b0}) begin
            err_timeout <= 1'b1; fst <= F_IDLE;
          end
        end
        default: if (!tx_pend && tst == T_IDLE) fst <= F_IDLE;   // F_TX: sent, or stopped by a bit error
      endcase
      if (brk) begin                                      // any break restarts the frame
        fst <= F_BREAK; r_busy <= 1'b0; tx_pend <= 1'b0;
      end

      // ---------------- transmitter
      case (tst)
        T_IDLE: begin
          drv <= 1'b1;
          if (hdr_valid && hdr_ready) begin
            tst <= T_BRK; t_hdr <= 1'b1; t_bc <= '0; t_k <= '0; t_i <= '0; t_n <= 4'd1;
            hdr_id_q <= hdr_id; drv <= 1'b0;
          end else if (tx_pend && sp_ok) begin             // after the PID stop bit (and our header)
            tst <= T_BYTES; t_hdr <= 1'b0; t_bc <= '0; t_k <= '0; t_i <= '0;
            t_n <= {1'b0, r_len} + 4'd1; t_sum <= r_sum; tx_pend <= 1'b0;
            drv <= 1'b0;
          end
        end
        T_BRK: begin
          t_bc <= t_end ? 16'd0 : t_bc + 16'd1;
          if (t_chk && rx_s) begin err_bit <= 1'b1; tst <= T_IDLE; drv <= 1'b1; end
          else if (t_end) begin
            t_k <= t_k + 4'd1;
            if (t_k == 4'd12) begin tst <= T_DEL; drv <= 1'b1; end
          end
        end
        T_DEL: begin
          t_bc <= t_end ? 16'd0 : t_bc + 16'd1;
          if (t_chk && !rx_s) begin err_bit <= 1'b1; tst <= T_IDLE; drv <= 1'b1; end
          else if (t_end) begin tst <= T_BYTES; t_k <= '0; drv <= 1'b0; end
        end
        default: begin                                    // T_BYTES
          t_bc <= t_end ? 16'd0 : t_bc + 16'd1;
          if (t_chk && rx_s != drv) begin err_bit <= 1'b1; tst <= T_IDLE; drv <= 1'b1; end
          else if (t_end) begin
            if (t_k == 4'd9) begin
              if (!t_hdr && t_i <= {1'b0, r_len}) t_sum <= csum_add(t_sum, t_byte);
              if (t_i == t_n) begin
                tst <= T_IDLE; drv <= 1'b1;
                if (!t_hdr) tx_done <= 1'b1;
              end else begin t_i <= t_i + 4'd1; t_k <= '0; drv <= 1'b0; end
            end else begin
              t_k <= t_k + 4'd1;
              drv <= t_k == 4'd8 ? 1'b1 : t_byte[t_k[2:0]];
            end
          end
        end
      endcase
    end
  end
endmodule
