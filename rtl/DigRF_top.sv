// SPDX-License-Identifier: Apache-2.0
// ============================================================================
// DigRF_top v2.0: DigRF v4-style baseband / RF IC serial link endpoint
// (one TX lane, one RX lane, 8b/10b, framed logical channels)
// ----------------------------------------------------------------------------
//  - Line: one bit per clk, symbol bit a first. A stopped lane is held at
//    0. 8b/10b coding (IEEE 802.3 clause 36 tables) with running
//    disparity; the transmitter starts every burst at RD-.
//  - Burst: max(cfg_sync, 1) x K28.5 (sync, the receiver aligns on the
//    first comma), frames, K28.5 fillers while the transmitter has nothing
//    to send, K29.7 (end of burst) once cfg_hold fillers came in a row; then
//    the lane stops. A frame waiting while the lane stops starts a new
//    burst.
//  - Frame: K28.1 (start of frame), header {LCT[2:0], F[4:0]}, payload:
//      LCT 0 DATA      F = {chan[1:0], size[2:0]}, 8 << size bytes (size 0..5)
//      LCT 1 CTRL_WR   F = tag, payload {addr, data}
//      LCT 2 CTRL_RD   F = tag, payload {addr}
//      LCT 3 CTRL_RSP  F = tag of the read, payload {data}
//      LCT 4 INT       F = vector, no payload
//    Transmit priority: read response, interrupt, control request, data.
//    A DATA frame takes dtx_size (sizes 6 and 7 are sent as 5) and
//    dtx_chan when it starts, i.e. while dtx_valid offers its first byte.
//  - Control master: ctl_valid / ctl_ready take a write or a read; a read
//    is outstanding until the response with its tag arrives (rsp_valid) or
//    cfg_timeout x 16 clocks pass (rsp_timeout); tags count up per request.
//  - Register slave: a received CTRL_WR pulses reg_we with reg_addr /
//    reg_wdata; a received CTRL_RD pulses reg_re with reg_addr and samples
//    reg_rdata in the next clock, then answers with CTRL_RSP.
//  - Data: dtx_* offers one frame at a time (size and channel with the
//    first byte); each payload byte is taken with dtx_ready; a missing byte
//    is sent as 0 and pulses tx_underrun. Received payload bytes come out
//    on drx_* as they arrive (no back-pressure); drx_abort ends a data
//    frame that broke off.
//  - Receiver: hunts for K28.5 at any bit offset, then decodes every
//    symbol. A code violation or disparity error (err_code) or K29.7 drops
//    the alignment; a bad header, a size code above 5, an unexpected
//    control symbol in a frame or a data byte between frames pulse
//    err_frame. A frame that breaks off is dropped (data frames: drx_abort).
//  Simplifications against DigRF v4: no M-PHY (no PWM / HS gears, no
//  PREPARE / DIF-P / line state handshake, no clock recovery: the receiver
//  runs on the transmitter's bit clock at any phase), one lane each way,
//  no CRC, no flow-control or retransmission, the header layout above.
// ============================================================================
module DigRF_top (
  input  logic       clk,
  input  logic       rst_n,
  // lanes
  output logic       tx_p,
  input  logic       rx_p,
  // configuration
  input  logic [3:0] cfg_sync,       // sync symbols per burst (0 = 1)
  input  logic [7:0] cfg_hold,       // fillers before the lane stops
  input  logic [7:0] cfg_timeout,    // read timeout, x 16 clocks
  // control master
  input  logic       ctl_valid,
  output logic       ctl_ready,
  input  logic       ctl_rd,
  input  logic [7:0] ctl_addr,
  input  logic [7:0] ctl_wdata,
  output logic       rsp_valid,
  output logic [7:0] rsp_data,
  output logic       rsp_timeout,
  // register slave
  output logic       reg_we,
  output logic       reg_re,
  output logic [7:0] reg_addr,
  output logic [7:0] reg_wdata,
  input  logic [7:0] reg_rdata,
  // interrupts
  input  logic       int_valid,
  output logic       int_ready,
  input  logic [4:0] int_vec,
  output logic       int_rx,
  output logic [4:0] int_rx_vec,
  // data
  input  logic       dtx_valid,
  output logic       dtx_ready,
  input  logic [7:0] dtx_data,
  input  logic [2:0] dtx_size,
  input  logic [1:0] dtx_chan,
  output logic       drx_valid,
  output logic [7:0] drx_data,
  output logic       drx_sof,
  output logic       drx_eof,
  output logic [1:0] drx_chan,
  output logic       drx_abort,
  // status
  output logic       tx_on,
  output logic       rx_locked,
  output logic       err_code,
  output logic       err_frame,
  output logic       tx_underrun
);
  // ---------------- 8b/10b ----------------
  // symbols {a,b,c,d,e,i,f,g,h,j}, a in bit 9; tables give the RD- forms
  function logic [5:0] t6(input logic [4:0] x);
    case (x)
      5'd0:  t6 = 6'b100111; 5'd1:  t6 = 6'b011101; 5'd2:  t6 = 6'b101101; 5'd3:  t6 = 6'b110001;
      5'd4:  t6 = 6'b110101; 5'd5:  t6 = 6'b101001; 5'd6:  t6 = 6'b011001; 5'd7:  t6 = 6'b111000;
      5'd8:  t6 = 6'b111001; 5'd9:  t6 = 6'b100101; 5'd10: t6 = 6'b010101; 5'd11: t6 = 6'b110100;
      5'd12: t6 = 6'b001101; 5'd13: t6 = 6'b101100; 5'd14: t6 = 6'b011100; 5'd15: t6 = 6'b010111;
      5'd16: t6 = 6'b011011; 5'd17: t6 = 6'b100011; 5'd18: t6 = 6'b010011; 5'd19: t6 = 6'b110010;
      5'd20: t6 = 6'b001011; 5'd21: t6 = 6'b101010; 5'd22: t6 = 6'b011010; 5'd23: t6 = 6'b111010;
      5'd24: t6 = 6'b110011; 5'd25: t6 = 6'b100110; 5'd26: t6 = 6'b010110; 5'd27: t6 = 6'b110110;
      5'd28: t6 = 6'b001110; 5'd29: t6 = 6'b101110; 5'd30: t6 = 6'b011110; default: t6 = 6'b101011;
    endcase
  endfunction
  function logic [3:0] t4(input logic [2:0] y, input logic k28);
    case (y)
      3'd0: t4 = 4'b1011;
      3'd1: t4 = k28 ? 4'b0110 : 4'b1001;
      3'd2: t4 = k28 ? 4'b1010 : 4'b0101;
      3'd3: t4 = 4'b1100;
      3'd4: t4 = 4'b1101;
      3'd5: t4 = k28 ? 4'b0101 : 4'b1010;
      3'd6: t4 = k28 ? 4'b1001 : 4'b0110;
      default: t4 = 4'b1110;
    endcase
  endfunction
  function logic unbal6(input logic [5:0] s);
    unbal6 = {2'd0, s[0]} + {2'd0, s[1]} + {2'd0, s[2]} + {2'd0, s[3]} + {2'd0, s[4]} + {2'd0, s[5]} != 3'd3;
  endfunction
  function logic unbal4(input logic [3:0] s);
    unbal4 = {2'd0, s[0]} + {2'd0, s[1]} + {2'd0, s[2]} + {2'd0, s[3]} != 3'd2;
  endfunction
  // {symbol, RD after}; rd = 1: RD+
  function logic [10:0] enc(input logic [7:0] d, input logic k, input logic rd);
    logic [5:0] s6;
    logic [3:0] s4;
    logic       r, k28;
    k28 = k && d[4:0] == 5'd28;
    s6 = k28 ? 6'b001111 : t6(d[4:0]);
    r = rd;
    if (r && (unbal6(s6) || s6 == 6'b111000)) s6 = ~s6;
    if (unbal6(s6)) r = !r;
    if (d[7:5] == 3'd7 && (k || (!r && (d[4:0] == 5'd17 || d[4:0] == 5'd18 || d[4:0] == 5'd20))
                            || (r && (d[4:0] == 5'd11 || d[4:0] == 5'd13 || d[4:0] == 5'd14))))
      s4 = 4'b0111;
    else s4 = t4(d[7:5], k28);
    if (r && (unbal4(s4) || d[7:5] == 3'd3 || k28)) s4 = ~s4;
    if (unbal4(s4)) r = !r;
    enc = {s6, s4, r};
  endfunction
  // 6b -> {valid, x}; both forms
  function logic [5:0] d6(input logic [5:0] s);
    logic [5:0] m;
    d6 = 6'd0;
    for (int x = 0; x < 32; x++) begin : b_d6
      m = t6(5'(x));
      if (s == m || (s == ~m && (unbal6(m) || x == 7))) d6 = {1'b1, 5'(x)};
    end
  endfunction
  // 4b -> y (7 when nothing else matches); K28: the 6b form fixes the
  // column (kinv: 001111 was sent, the RD+ column follows)
  function logic [2:0] d4(input logic [3:0] s, input logic k28, input logic kinv);
    logic [3:0] m;
    d4 = 3'd7;
    for (int y = 0; y < 7; y++) begin : b_d4
      m = t4(3'(y), k28);
      if (k28 ? s == (kinv ? ~m : m) : (s == m || (s == ~m && (unbal4(m) || y == 3)))) d4 = 3'(y);
    end
  endfunction

  localparam logic [8:0] K28_1 = {1'b1, 8'h3C}, K28_5 = {1'b1, 8'hBC}, K29_7 = {1'b1, 8'hFD};
  localparam logic [2:0] L_DATA = 3'd0, L_WR = 3'd1, L_RD = 3'd2, L_RSP = 3'd3, L_INT = 3'd4;

  // ---------------- transmitter ----------------
  typedef enum logic [2:0] {T_OFF, T_SYNC, T_GAP, T_HDR, T_PAY, T_EOB} tst_t;
  tst_t        ts;
  logic [9:0]  tsh;                     // symbol being sent, bit 9 next
  logic [3:0]  tbit;                    // bits left in the symbol - 1
  logic        trd;
  logic [3:0]  tn;                      // sync symbols left
  logic [7:0]  tidle;                   // fillers in a row
  logic [8:0]  tcnt;                    // payload bytes left
  logic [2:0]  tlct;
  logic [7:0]  thdr;
  logic [15:0] tpay;                    // control payload, next byte in [15:8]
  // pending sources
  logic        rsp_pend, int_pend, ctl_pend, ctl_isrd, rd_out;
  logic [4:0]  rsp_tag, int_v, ctl_tag, out_tag;
  logic [7:0]  rsp_d, ctl_a, ctl_d;
  logic        rsp_cap;                 // sample reg_rdata
  logic [11:0] tmo;

  wire sym_end = tbit == 4'd0;
  wire any_src = rsp_pend || int_pend || ctl_pend || dtx_valid;
  assign tx_p = ts != T_OFF && tsh[9];
  assign tx_on = ts != T_OFF;
  assign ctl_ready = !ctl_pend && !rd_out;
  assign int_ready = !int_pend;

  // next symbol {k, byte}
  logic [8:0] nsym;
  tst_t       nts;
  logic       take_rsp, take_int, take_ctl, take_dat, take_byte;
  always_comb begin
    nsym = K28_5; nts = ts;
    take_rsp = 1'b0; take_int = 1'b0; take_ctl = 1'b0; take_dat = 1'b0; take_byte = 1'b0;
    case (ts)
      T_OFF: begin nts = T_SYNC; if (cfg_sync <= 4'd1) nts = T_GAP; end
      T_SYNC: if (tn == 4'd1) nts = T_GAP;
      T_GAP: begin
        if (any_src) begin : b_sof
          nsym = K28_1; nts = T_HDR;
          if (rsp_pend) take_rsp = 1'b1;
          else if (int_pend) take_int = 1'b1;
          else if (ctl_pend) take_ctl = 1'b1;
          else take_dat = 1'b1;
        end else if (tidle >= cfg_hold) begin nsym = K29_7; nts = T_EOB; end
      end
      T_HDR: begin nsym = {1'b0, thdr}; nts = T_PAY; if (tcnt == 9'd0) nts = T_GAP; end
      T_EOB: nts = T_OFF;
      default: begin                     // T_PAY
        if (tcnt == 9'd1) nts = T_GAP;
        if (tlct != L_DATA) nsym = {1'b0, tpay[15:8]};
        else begin take_byte = dtx_valid; nsym = {1'b0, dtx_valid ? dtx_data : 8'h00}; end
      end
    endcase
  end
  wire [2:0]  dsz = dtx_size > 3'd5 ? 3'd5 : dtx_size;
  wire        t_go = ts == T_OFF ? any_src : sym_end && ts != T_EOB;
  wire [10:0] tenc = enc(nsym[7:0], nsym[8], ts == T_OFF ? 1'b0 : trd);
  assign dtx_ready = t_go && take_byte;

  always_ff @(posedge clk or negedge rst_n)
    if (!rst_n) begin
      ts <= T_OFF; tsh <= '0; tbit <= '0; trd <= 1'b0; tn <= '0; tidle <= '0; tcnt <= '0;
      tlct <= '0; thdr <= '0; tpay <= '0; tx_underrun <= 1'b0;
    end else begin
      tx_underrun <= 1'b0;
      if (!t_go) begin
        if (ts == T_EOB && sym_end) ts <= T_OFF;
        else if (ts != T_OFF) begin tbit <= tbit - 4'd1; tsh <= {tsh[8:0], 1'b0}; end
      end else begin
        ts <= nts; tsh <= tenc[10:1]; trd <= tenc[0]; tbit <= 4'd9;
        if (ts == T_OFF) tn <= cfg_sync - 4'd1;
        else if (ts == T_SYNC) tn <= tn - 4'd1;
        tidle <= (ts == T_GAP && !any_src) ? tidle + 8'd1 : 8'd0;
        if (take_rsp) begin tlct <= L_RSP; thdr <= {L_RSP, rsp_tag}; tcnt <= 9'd1; tpay <= {rsp_d, 8'h00}; end
        if (take_int) begin tlct <= L_INT; thdr <= {L_INT, int_v}; tcnt <= 9'd0; end
        if (take_ctl) begin
          tlct <= ctl_isrd ? L_RD : L_WR; thdr <= {ctl_isrd ? L_RD : L_WR, ctl_tag};
          tcnt <= ctl_isrd ? 9'd1 : 9'd2; tpay <= {ctl_a, ctl_d};
        end
        if (take_dat) begin
          tlct <= L_DATA; thdr <= {L_DATA, dtx_chan, dsz};
          tcnt <= 9'd8 << dsz;
        end
        if (ts == T_PAY) begin
          tcnt <= tcnt - 9'd1; tpay <= {tpay[7:0], 8'h00};
          if (tlct == L_DATA && !dtx_valid) tx_underrun <= 1'b1;
        end
      end
    end

  // ---------------- pending sources, read timeout ----------------
  always_ff @(posedge clk or negedge rst_n)
    if (!rst_n) begin
      rsp_pend <= 1'b0; int_pend <= 1'b0; ctl_pend <= 1'b0; ctl_isrd <= 1'b0; rd_out <= 1'b0;
      int_v <= '0; ctl_tag <= '0; out_tag <= '0; rsp_d <= '0; ctl_a <= '0; ctl_d <= '0;
      tmo <= '0; rsp_timeout <= 1'b0;
    end else begin
      rsp_timeout <= 1'b0;
      if (t_go && take_rsp) rsp_pend <= 1'b0;
      if (rsp_cap) begin rsp_pend <= 1'b1; rsp_d <= reg_rdata; end
      if (t_go && take_int) int_pend <= 1'b0;
      if (int_valid && int_ready) begin int_pend <= 1'b1; int_v <= int_vec; end
      if (ctl_valid && ctl_ready) begin
        ctl_pend <= 1'b1; ctl_isrd <= ctl_rd; ctl_a <= ctl_addr; ctl_d <= ctl_wdata;
      end
      if (t_go && take_ctl) begin
        ctl_pend <= 1'b0; ctl_tag <= ctl_tag + 5'd1;
        if (ctl_isrd) begin rd_out <= 1'b1; out_tag <= ctl_tag; tmo <= {cfg_timeout, 4'h0}; end
      end
      if (rd_out && !(t_go && take_ctl)) begin
        if (rsp_valid) rd_out <= 1'b0;
        else if (tmo == 12'd0) begin rd_out <= 1'b0; rsp_timeout <= 1'b1; end
        else tmo <= tmo - 12'd1;
      end
    end

  // ---------------- receiver ----------------
  typedef enum logic [1:0] {R_IDLE, R_HDR, R_PAY} rst_t;
  rst_t        rs;
  logic        rx_q;
  logic [9:0]  rsh;
  logic [3:0]  rph;                     // bit position; a symbol is complete at 0
  logic        rrd;
  logic [2:0]  rlct;
  logic [4:0]  rf;
  logic [8:0]  rcnt;
  logic [7:0]  rbuf;                    // first control payload byte
  logic        rfirst;

  wire        comma = rsh == 10'b0011111010 || rsh == 10'b1100000101;
  wire        sym_rdy = rx_locked && rph == 4'd0;
  // decode
  wire [5:0]  dx = d6(rsh[9:4]);
  wire        k28 = rsh[9:4] == 6'b001111 || rsh[9:4] == 6'b110000;
  wire [2:0]  dy = d4(rsh[3:0], k28, rsh[9:4] == 6'b001111);
  wire        kx = k28 || ((dx[4:0] == 5'd23 || dx[4:0] == 5'd27 || dx[4:0] == 5'd29 || dx[4:0] == 5'd30)
                           && (rsh[3:0] == 4'b0111 || rsh[3:0] == 4'b1000));
  wire [7:0]  db = {dy, k28 ? 5'd28 : dx[4:0]};
  wire [10:0] e_same = enc(db, kx, rrd);
  wire        c_ok   = (dx[5] || k28) && e_same[10:1] == rsh;
  wire [8:0]  rsym = {kx, db};

  always_ff @(posedge clk or negedge rst_n)
    if (!rst_n) begin
      rx_q <= 1'b0; rsh <= '0; rph <= '0; rrd <= 1'b0; rx_locked <= 1'b0; rs <= R_IDLE;
      rlct <= '0; rf <= '0; rcnt <= '0; rbuf <= '0; rfirst <= 1'b0;
      err_code <= 1'b0; err_frame <= 1'b0; reg_we <= 1'b0; reg_re <= 1'b0; reg_addr <= '0;
      reg_wdata <= '0; rsp_cap <= 1'b0; rsp_tag <= '0; rsp_valid <= 1'b0; rsp_data <= '0;
      int_rx <= 1'b0; int_rx_vec <= '0;
      drx_valid <= 1'b0; drx_data <= '0; drx_sof <= 1'b0; drx_eof <= 1'b0; drx_chan <= '0; drx_abort <= 1'b0;
    end else begin
      err_code <= 1'b0; err_frame <= 1'b0; reg_we <= 1'b0; reg_re <= 1'b0; rsp_cap <= reg_re;
      rsp_valid <= 1'b0; int_rx <= 1'b0; drx_valid <= 1'b0; drx_abort <= 1'b0;
      rx_q <= rx_p; rsh <= {rsh[8:0], rx_q};
      rph <= rph == 4'd9 ? 4'd0 : rph + 4'd1;
      if (!rx_locked) begin
        if (comma) begin rx_locked <= 1'b1; rph <= 4'd1; rrd <= !rsh[9]; rs <= R_IDLE; end
      end else if (sym_rdy) begin
        if (!c_ok) begin
          err_code <= 1'b1; rx_locked <= 1'b0;
          if (rs == R_PAY && rlct == L_DATA) drx_abort <= 1'b1;
        end else begin
          rrd <= e_same[0];
          if (rsym[8]) begin
            // control symbol: K28.5 filler, K28.1 start of frame, K29.7 end
            // of burst; anything else, or one inside a frame, is an error
            if (rs != R_IDLE || (rsym != K28_5 && rsym != K28_1 && rsym != K29_7)) err_frame <= 1'b1;
            if (rs == R_PAY && rlct == L_DATA) drx_abort <= 1'b1;
            rs <= rsym == K28_1 ? R_HDR : R_IDLE;
            if (rsym == K29_7) rx_locked <= 1'b0;
          end else case (rs)
            R_IDLE: err_frame <= 1'b1;
            R_HDR: begin
              rlct <= rsym[7:5]; rf <= rsym[4:0]; rfirst <= 1'b1; rs <= R_PAY;
              case (rsym[7:5])
                L_DATA: begin
                  rcnt <= 9'd8 << rsym[2:0];
                  if (rsym[2:0] > 3'd5) begin err_frame <= 1'b1; rs <= R_IDLE; end
                end
                L_WR: rcnt <= 9'd2;
                L_RD, L_RSP: rcnt <= 9'd1;
                L_INT: begin int_rx <= 1'b1; int_rx_vec <= rsym[4:0]; rs <= R_IDLE; end
                default: begin err_frame <= 1'b1; rs <= R_IDLE; end
              endcase
            end
            default: begin                // R_PAY
              rcnt <= rcnt - 9'd1; rfirst <= 1'b0; rbuf <= rsym[7:0];
              if (rcnt == 9'd1) rs <= R_IDLE;
              case (rlct)
                L_DATA: begin
                  drx_valid <= 1'b1; drx_data <= rsym[7:0]; drx_sof <= rfirst; drx_eof <= rcnt == 9'd1;
                  drx_chan <= rf[4:3];
                end
                L_WR: if (rcnt == 9'd1) begin reg_we <= 1'b1; reg_addr <= rbuf; reg_wdata <= rsym[7:0]; end
                L_RD: begin reg_re <= 1'b1; reg_addr <= rsym[7:0]; rsp_tag <= rf; end
                default: begin            // L_RSP
                  if (rd_out && rf == out_tag) begin rsp_valid <= 1'b1; rsp_data <= rsym[7:0]; end
                  else err_frame <= 1'b1;
                end
              endcase
            end
          endcase
        end
      end
    end
endmodule
