// SPDX-License-Identifier: Apache-2.0
// ============================================================================
// ARM_Serial_Wire_Debug_top v2.0: Serial Wire Debug port (SW-DP, ADIv5 DPv1
// register set, SWD only) with a request port towards the access ports
// ----------------------------------------------------------------------------
//  - Pins: SWCLK and SWDIO are synchronised into clk (two flops each); the
//    target samples SWDIO at each rising SWCLK edge and changes its own
//    SWDIO output 3 clk after that edge. SWCLK high and low times must be
//    at least 4 clk. The host drives SWDIO between rising edges and leaves
//    the line released (pull-up, reads 1) in turnaround cycles. Read data
//    is taken when the target starts driving the ACK.
//  - Line reset: 50 or more consecutive 1 samples (target not driving),
//    then at least 2 idle (0) samples. After a line reset the first packet
//    must read DPIDR; any other packet, a request parity error or a wrong
//    stop / park bit is a protocol error: no reply, the port locks out
//    until the next line reset. The port also starts locked out.
//  - Packet: request {start 1, APnDP, RnW, A[2], A[3], parity (even over
//    the 4 bits), stop 0, park 1}, turnaround (DLCR.TURNROUND + 1 cycles),
//    ACK from the target (3 bits, first bit first: OK 1,0,0; WAIT 0,1,0;
//    FAULT 0,0,1), then for a read: 32 data bits (bit 0 first) + even
//    parity from the target and a turnaround; for a write: a turnaround and
//    32 data bits + parity from the host. WAIT / FAULT end the packet after
//    the ACK and a turnaround unless CTRL/STAT.ORUNDETECT is set: then the
//    data phase follows anyway (read data 0, write data ignored) and
//    STICKYORUN is set.
//  - DP registers (A[3:2]): read 0 DPIDR, 1 CTRL/STAT (SELECT.DPBANKSEL 0)
//    or DLCR (bank 1; other banks read 0), 2 RESEND, 3 RDBUFF; write 0
//    ABORT, 1 CTRL/STAT / DLCR, 2 SELECT, 3 ignored.
//      CTRL/STAT: [0] ORUNDETECT, [1] STICKYORUN, [5] STICKYERR,
//        [6] READOK, [7] WDATAERR, [28] CDBGPWRUPREQ, [29] CDBGPWRUPACK,
//        [30] CSYSPWRUPREQ, [31] CSYSPWRUPACK. Sticky bits are cleared
//        only through ABORT.
//      ABORT: [0] DAPABORT (drops the AP access in progress), [2]
//        STKERRCLR, [3] WDERRCLR, [4] ORUNERRCLR.
//      DLCR: [9:8] TURNROUND. SELECT: [31:24] APSEL, [7:4] APBANKSEL,
//        [3:0] DPBANKSEL. RESEND: the data of the last AP or RDBUFF read.
//  - AP accesses: ap_req pulses for one clock with the request {ap_write,
//    ap_sel = APSEL, ap_addr (word address) = {APBANKSEL, A[3:2]},
//    ap_wdata}; ap_busy stays high until ap_done (ap_err: STICKYERR) or
//    DAPABORT (ap_abort pulse). AP reads are posted: the read returns RDBUFF (the
//    previous AP read result) and starts a new AP read whose result goes
//    to RDBUFF. While an AP access is in progress, AP accesses and RDBUFF
//    reads get WAIT; with STICKYERR, STICKYORUN or WDATAERR set, AP
//    accesses get FAULT (checked first). A write with a data parity error
//    sets WDATAERR and is dropped.
//  Not implemented: JTAG-DP and dormant state (the JTAG-to-SWD sequence
//  is harmless: it contains line resets), multi-drop (TARGETSEL), DPv2
//  registers, pushed compare / verify (STICKYCMP reads 0), transaction
//  counter, debug reset request.
// ============================================================================
module ARM_Serial_Wire_Debug_top #(
  parameter logic [31:0] DPIDR = 32'h0010_1001       // part 0x01, DPv1, RAO
)(
  input  logic        clk,
  input  logic        rst_n,
  input  logic        swclk,
  input  logic        swdio_in,
  output logic        swdio_out,
  output logic        swdio_oe,
  // power-up handshake
  output logic        cdbgpwrupreq,
  input  logic        cdbgpwrupack,
  output logic        csyspwrupreq,
  input  logic        csyspwrupack,
  // access port requests
  output logic        ap_req,          // pulse: new request (fields held until done)
  output logic        ap_busy,         // request in progress
  output logic        ap_write,
  output logic [7:0]  ap_sel,
  output logic [5:0]  ap_addr,         // word address {APBANKSEL, A[3:2]}
  output logic [31:0] ap_wdata,
  input  logic        ap_done,
  input  logic [31:0] ap_rdata,
  input  logic        ap_err,
  output logic        ap_abort,
  // status
  output logic        lockout,         // waiting for a line reset
  output logic        line_reset,      // pulse: line reset seen
  output logic        proto_err,       // pulse: protocol error
  output logic        ack_wait,        // pulse: WAIT sent
  output logic        ack_fault        // pulse: FAULT sent
);
  // ---------------- pins ----------------
  logic ck_m, ck_s, ck_q, io_m, io_s;
  wire  rise = ck_s && !ck_q;
  always_ff @(posedge clk or negedge rst_n)
    if (!rst_n) begin ck_m <= 1'b0; ck_s <= 1'b0; ck_q <= 1'b0; io_m <= 1'b1; io_s <= 1'b1; end
    else begin ck_m <= swclk; ck_s <= ck_m; ck_q <= ck_s; io_m <= swdio_in; io_s <= io_m; end

  // ---------------- state ----------------
  typedef enum logic [3:0] {S_LOCK, S_RST, S_IDLE, S_REQ, S_TRN, S_ACK, S_RD, S_WTRN, S_WR, S_HTRN} st_t;
  st_t         st;
  logic [5:0]  ones;                   // consecutive 1 samples (saturates at 50)
  logic        idle2;                  // one idle sample after the line reset
  logic        need_id;                // first packet after a line reset
  logic [5:0]  req;                    // request bits, newest in bit 5
  logic [2:0]  k3;                     // request bits / ACK bits / turnaround count
  logic [5:0]  k;                      // data bit
  logic [2:0]  ack;                    // {FAULT, WAIT, OK}
  logic [32:0] sh;                     // data shift register (with parity)
  logic        apndp, rnw;
  logic [1:0]  a;
  logic        orun_ph;                // data phase after WAIT / FAULT

  // registers
  logic        orundetect, stickyorun, stickyerr, readok, wdataerr;
  logic [1:0]  turnround;
  logic [7:0]  apsel;
  logic [3:0]  apbank, dpbank;
  logic [31:0] rdbuf, last_rd;
  logic        busy;

  // CTRL/STAT = {c_hi, 20'h0, c_lo[4:2], 3'b000, c_lo[1:0]}
  wire [3:0]  c_hi = {csyspwrupack, csyspwrupreq, cdbgpwrupack, cdbgpwrupreq};
  wire [4:0]  c_lo = {wdataerr, readok, stickyerr, stickyorun, orundetect};
  wire        sticky = stickyerr || stickyorun || wdataerr;
  // at the park sample req = {stop, parity, A[3], A[2], RnW, APnDP}
  wire        r_ap = req[0], r_rnw = req[1];
  wire [1:0]  r_a  = req[3:2];
  wire        r_ok = (req[0] ^ req[1] ^ req[2] ^ req[3]) == req[4] && !req[5] && io_s;

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      st <= S_LOCK; ones <= '0; idle2 <= 1'b0; need_id <= 1'b0; req <= '0; k3 <= '0; k <= '0;
      ack <= '0; sh <= '0; apndp <= 1'b0; rnw <= 1'b0; a <= '0; orun_ph <= 1'b0;
      orundetect <= 1'b0; stickyorun <= 1'b0; stickyerr <= 1'b0; readok <= 1'b0; wdataerr <= 1'b0;
      turnround <= '0; apsel <= '0; apbank <= '0; dpbank <= '0; rdbuf <= '0; last_rd <= '0; busy <= 1'b0;
      cdbgpwrupreq <= 1'b0; csyspwrupreq <= 1'b0;
      swdio_out <= 1'b0; swdio_oe <= 1'b0;
      ap_req <= 1'b0; ap_write <= 1'b0; ap_sel <= '0; ap_addr <= '0; ap_wdata <= '0; ap_abort <= 1'b0;
      line_reset <= 1'b0; proto_err <= 1'b0; ack_wait <= 1'b0; ack_fault <= 1'b0;
    end else begin
      line_reset <= 1'b0; proto_err <= 1'b0; ack_wait <= 1'b0; ack_fault <= 1'b0; ap_abort <= 1'b0;
      ap_req <= 1'b0;

      // ---------------- access port
      if (busy && ap_done) begin
        busy <= 1'b0;
        if (ap_err) stickyerr <= 1'b1;
        if (!ap_write) begin rdbuf <= ap_rdata; readok <= !ap_err; end
      end

      if (rise) begin
        // ---------------- line reset (counted while the host drives)
        if (swdio_oe || !io_s) ones <= '0;
        else if (ones != 6'd50) ones <= ones + 6'd1;
        if (!swdio_oe && io_s && ones == 6'd49) begin
          st <= S_RST; line_reset <= 1'b1; swdio_oe <= 1'b0;
        end else begin
          case (st)
            S_LOCK: ;
            S_RST: if (!io_s) begin
              idle2 <= !idle2;
              if (idle2) begin st <= S_IDLE; need_id <= 1'b1; end
            end else idle2 <= 1'b0;
            S_IDLE: if (io_s) begin st <= S_REQ; k3 <= '0; end
            S_REQ: begin
              req <= {io_s, req[5:1]};
              k3  <= k3 + 3'd1;
              if (k3 == 3'd6) begin                         // park sample
                apndp <= r_ap; rnw <= r_rnw; a <= r_a;
                if (!r_ok || (need_id && (r_ap || !r_rnw || r_a != 2'd0))) begin
                  st <= S_LOCK; proto_err <= 1'b1;
                end else begin
                  st <= S_TRN; k3 <= {1'b0, turnround} + 3'd1; need_id <= 1'b0; orun_ph <= 1'b0;
                  if (r_ap && sticky) ack <= 3'b100;
                  else if ((r_ap || (r_rnw && r_a == 2'd3)) && busy) ack <= 3'b010;
                  else ack <= 3'b001;
                end
              end
            end
            S_TRN: if (k3 == 3'd1) begin                   // last turnaround cycle
              st <= S_ACK; k3 <= 3'd1; swdio_oe <= 1'b1; swdio_out <= ack[0];
              if (ack[1]) ack_wait <= 1'b1;
              if (ack[2]) ack_fault <= 1'b1;
              if (!ack[0]) begin
                if (orundetect) begin stickyorun <= 1'b1; orun_ph <= 1'b1; end
                sh <= '0;
              end else if (rnw) begin
                // read data; AP reads are posted
                if (apndp || a == 2'd3) begin sh <= {^rdbuf, rdbuf}; last_rd <= rdbuf; end
                else if (a == 2'd0) sh <= {^DPIDR, DPIDR};
                else if (a == 2'd1) begin
                  if (dpbank == 4'd0) sh <= {^{c_hi, c_lo}, c_hi, 20'h0, c_lo[4:2], 3'b000, c_lo[1:0]};
                  else if (dpbank == 4'd1) sh <= {^turnround, 22'h0, turnround, 8'h00};
                  else sh <= '0;
                end
                else sh <= {^last_rd, last_rd};
                if (apndp) begin
                  busy <= 1'b1; ap_req <= 1'b1; ap_write <= 1'b0; ap_sel <= apsel;
                  ap_addr <= {apbank, a};
                end
              end
            end else k3 <= k3 - 3'd1;
            S_ACK: begin
              k3 <= k3 + 3'd1;
              if (k3 != 3'd3) swdio_out <= ack[k3[1:0]];
              else if (rnw && (ack[0] || orun_ph)) begin
                st <= S_RD; k <= '0; swdio_out <= sh[0]; sh <= {1'b0, sh[32:1]};
              end else begin
                st <= S_WTRN; swdio_oe <= 1'b0; k3 <= {1'b0, turnround} + 3'd1;
              end
            end
            S_RD: begin
              k <= k + 6'd1;
              if (k == 6'd32) begin
                st <= S_HTRN; swdio_oe <= 1'b0; k3 <= {1'b0, turnround} + 3'd1;
              end else begin swdio_out <= sh[0]; sh <= {1'b0, sh[32:1]}; end
            end
            S_WTRN: begin
              k3 <= k3 - 3'd1;
              if (k3 == 3'd1) begin
                if (!rnw && (ack[0] || orun_ph)) begin st <= S_WR; k <= '0; end
                else st <= S_IDLE;
              end
            end
            S_WR: begin
              sh <= {io_s, sh[32:1]};
              k  <= k + 6'd1;
              if (k == 6'd32) begin
                st <= S_IDLE;
                if (ack[0]) begin
                  if (^{io_s, sh[32:1]}) wdataerr <= 1'b1;
                  else if (apndp) begin
                    busy <= 1'b1; ap_req <= 1'b1; ap_write <= 1'b1; ap_sel <= apsel;
                    ap_addr <= {apbank, a}; ap_wdata <= sh[32:1];
                  end else case (a)
                    2'd0: begin
                      if (sh[1] && busy) begin busy <= 1'b0; ap_abort <= 1'b1; end
                      if (sh[3]) stickyerr <= 1'b0;
                      if (sh[4]) wdataerr <= 1'b0;
                      if (sh[5]) stickyorun <= 1'b0;
                    end
                    2'd1:
                      if (dpbank == 4'd0) begin
                        orundetect <= sh[1]; cdbgpwrupreq <= sh[29]; csyspwrupreq <= sh[31];
                      end else if (dpbank == 4'd1) turnround <= sh[10:9];
                    2'd2: begin apsel <= sh[32:25]; apbank <= sh[8:5]; dpbank <= sh[4:1]; end
                    default: ;
                  endcase
                end
              end
            end
            default: begin                                 // S_HTRN
              k3 <= k3 - 3'd1;
              if (k3 == 3'd1) st <= S_IDLE;
            end
          endcase
        end
      end
    end
  end
  assign lockout = st == S_LOCK;
  assign ap_busy = busy;
endmodule
