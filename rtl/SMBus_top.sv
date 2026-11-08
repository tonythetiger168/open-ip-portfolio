// SPDX-License-Identifier: Apache-2.0
// ============================================================================
// SMBus 3.x target with the PMBus 1.3 command layer (a voltage-regulator
// style device): open-drain SCL / SDA, START / repeated START / STOP,
// Packet Error Checking, clock stretching, SMBALERT# with the Alert
// Response Address, bus timeout.
//   * Bus: SCL and SDA are synchronised and spike-filtered (FILT clocks,
//     tSP); SDA is changed HOLD clocks after SCL falls (tHD;DAT). After
//     each ACKed address byte the target holds SCL low for STRETCH clocks.
//   * Protocols: Send Byte, Write Byte / Word, Read Byte / Word and Block
//     Read, each with an optional PEC byte (CRC-8, x^8 + x^2 + x + 1).
//     A write takes effect at STOP, only if it carried the full data and
//     at most one correct PEC; a read sends its data, then the PEC while
//     the host keeps ACKing, then 0xFF.
//   * Commands: OPERATION 01, ON_OFF_CONFIG 02, CLEAR_FAULTS 03,
//     WRITE_PROTECT 10, CAPABILITY 19, VOUT_MODE 20, VOUT_COMMAND 21,
//     STATUS_BYTE 78, STATUS_WORD 79, STATUS_CML 7E, READ_VOUT 8B,
//     PMBUS_REVISION 98, MFR_ID 99 (block read).
//   * STATUS_CML: [7] unsupported command (command byte NACKed, or a read
//     of a write-only command), [6] invalid data (too many or too few data
//     bytes, a write to a protected or read-only command, a bad
//     WRITE_PROTECT value; the data byte is NACKed), [5] PEC failed (the
//     PEC byte is NACKed), [1] other (bus timeout). Any fault, or a VOUT
//     overvoltage reported on vout_ov, latches and pulls SMBALERT# low.
//   * SMBALERT#: released when the host reads the Alert Response Address
//     (0x0C) and this target wins the address arbitration, or by
//     CLEAR_FAULTS; a new fault pulls it again.
//   * WRITE_PROTECT: 0x80 only WRITE_PROTECT is writable, 0x40 also
//     OPERATION, 0x20 also ON_OFF_CONFIG and VOUT_COMMAND (every
//     writable command here), 0x00 all.
//     CLEAR_FAULTS is always accepted.
//   * Timeout: SCL low for TIMEOUT clocks in a transfer (tTIMEOUT) ends the
//     transfer, releases both lines and sets STATUS_CML[1].
// Arbitration: a target that sends a 1 and sees SDA low stops sending.
// ============================================================================
module SMBus_top #(
  parameter logic [6:0] ADDR    = 7'h5A,
  parameter int         FILT    = 3,        // spike filter, clocks (>= 1)
  parameter int         HOLD    = 4,        // SDA hold after SCL falls, clocks (>= 1)
  parameter int         STRETCH = 8,        // SCL stretch after an address ACK, clocks
  parameter int         TIMEOUT = 2500000   // tTIMEOUT, clocks (25 ms at 100 MHz)
)(
  input  logic        clk,
  input  logic        rst_n,
  // SMBus (open drain: an output at 0 pulls the line low)
  input  logic        scl,
  input  logic        sda,
  output logic        scl_o,
  output logic        sda_o,
  output logic        smbalert_n,
  // power stage
  output logic [7:0]  operation,
  output logic [7:0]  on_off_config,
  output logic [15:0] vout_command,
  input  logic [15:0] read_vout,
  input  logic        vout_ov,          // VOUT overvoltage fault event
  // events (one-clock pulses)
  output logic        irq_cml,          // a STATUS_CML bit was set
  output logic        irq_upd,          // OPERATION / ON_OFF_CONFIG / VOUT_COMMAND written
  output logic        irq_to            // bus timeout
);
  localparam logic [7:0] ARA = {7'h0C, 1'b1};
  localparam int TW = $clog2(TIMEOUT + 1);
  localparam int SW = $clog2(STRETCH + 2);

  // ---------------- input sync and spike filter ----------------
  logic [1:0] scl_y, sda_y;
  logic       scl_f, sda_f, scl_p, sda_p;
  logic [$clog2(FILT+1)-1:0] scl_c, sda_c;
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      scl_y <= 2'b11; sda_y <= 2'b11; scl_f <= 1'b1; sda_f <= 1'b1; scl_c <= '0; sda_c <= '0;
      scl_p <= 1'b1; sda_p <= 1'b1;
    end else begin
      scl_y <= {scl_y[0], scl}; sda_y <= {sda_y[0], sda};
      // the filtered line follows the input once it has held for FILT clocks
      if (scl_y[1] == scl_f) scl_c <= '0;
      else if (scl_c == ($clog2(FILT+1))'(FILT - 1)) begin scl_f <= scl_y[1]; scl_c <= '0; end
      else scl_c <= scl_c + 1'b1;
      if (sda_y[1] == sda_f) sda_c <= '0;
      else if (sda_c == ($clog2(FILT+1))'(FILT - 1)) begin sda_f <= sda_y[1]; sda_c <= '0; end
      else sda_c <= sda_c + 1'b1;
      scl_p <= scl_f; sda_p <= sda_f;
    end
  end
  wire start = scl_f && scl_p && sda_p && !sda_f;
  wire stop  = scl_f && scl_p && !sda_p && sda_f;
  wire rise  = scl_f && !scl_p;
  wire fall  = !scl_f && scl_p;
  // SDA moves HOLD clocks after SCL falls
  localparam int HW = $clog2(HOLD + 1);
  logic [HW-1:0] hcnt;
  always_ff @(posedge clk or negedge rst_n)
    if (!rst_n)              hcnt <= '0;
    else if (start || stop)  hcnt <= '0;
    else if (fall)           hcnt <= HW'(HOLD);
    else if (hcnt != 0)      hcnt <= hcnt - 1'b1;
  wire fall_h = (hcnt == HW'(1));

  // ---------------- command table ----------------
  // bytes a write carries (4'hF: not writable) / a read returns (4'hF: not readable)
  function automatic logic [3:0] f_wlen(input logic [7:0] c);
    case (c)
      8'h01, 8'h02, 8'h10: f_wlen = 4'd1;
      8'h03:               f_wlen = 4'd0;
      8'h21:               f_wlen = 4'd2;
      default:             f_wlen = 4'hF;
    endcase
  endfunction
  function automatic logic [3:0] f_rlen(input logic [7:0] c);
    case (c)
      8'h01, 8'h02, 8'h10, 8'h19, 8'h20, 8'h78, 8'h7E, 8'h98: f_rlen = 4'd1;
      8'h21, 8'h79, 8'h8B: f_rlen = 4'd2;
      8'h99:               f_rlen = 4'd5;          // count + "OIPF"
      default:             f_rlen = 4'hF;
    endcase
  endfunction
  function automatic logic [7:0] f_crc8(input logic [7:0] c, input logic [7:0] b);
    logic [7:0] x;
    x = c ^ b;
    for (int k = 0; k < 8; k++) x = x[7] ? ((x << 1) ^ 8'h07) : (x << 1);
    f_crc8 = x;
  endfunction

  // ---------------- registers ----------------
  logic        wp80, wp40, wp20;          // WRITE_PROTECT (one of 80h / 40h / 20h, or 00h)
  logic [3:0]  cml;                       // STATUS_CML bits 7, 6, 5 and 1
  logic        ov_l, alert_ack;
  // write protection of a command at the current WRITE_PROTECT level
  // (state passed as arguments: a function in a continuous assignment
  // is only re-evaluated when its arguments change)
  function automatic logic f_prot(input logic [7:0] c, input logic p80, input logic p40);
    f_prot = (p80 && (c != 8'h10) && (c != 8'h03)) ||
             (p40 && (c != 8'h10) && (c != 8'h03) && (c != 8'h01));
  endfunction

  // ---------------- transfer state ----------------
  logic        active, rep, drop, tx, mack, pre, ara;
  logic [3:0]  bitn, nb, ntx;
  logic [2:0]  nw;
  logic [7:0]  sh, crc, cmd, txb, w0, w1;
  logic [15:0] snap;                      // word sampled when a read starts
  logic [SW-1:0] stretch;
  logic [TW-1:0] tcnt;

  // byte i (0-based) of the read of command c
  function automatic logic [7:0] f_rbyte(input logic [7:0] c, input logic [3:0] i, input logic [15:0] sn);
    if (c == 8'h99)
      case (i)
        4'd0: f_rbyte = 8'd4;
        4'd1: f_rbyte = "O"; 4'd2: f_rbyte = "I"; 4'd3: f_rbyte = "P";
        default: f_rbyte = "F";
      endcase
    else f_rbyte = (i == 4'd0) ? sn[7:0] : sn[15:8];
  endfunction
  // STATUS_BYTE: OFF, VOUT_OV, CML
  function automatic logic [15:0] f_snap(input logic [7:0] c);
    case (c)
      8'h01: f_snap = {8'h00, operation};
      8'h02: f_snap = {8'h00, on_off_config};
      8'h10: f_snap = {8'h00, wp80, wp40, wp20, 5'b00000};
      8'h19: f_snap = 16'h00B0;           // PEC, 400 kHz, SMBALERT#
      8'h20: f_snap = 16'h0017;           // linear VOUT, exponent -9
      8'h21: f_snap = vout_command;
      8'h78: f_snap = {9'h000, !operation[7], ov_l, 3'b000, cml != 4'h0, 1'b0};
      8'h79: f_snap = {ov_l, 8'h00, !operation[7], ov_l, 3'b000, cml != 4'h0, 1'b0};
      8'h7E: f_snap = {8'h00, cml[3:1], 3'b000, cml[0], 1'b0};
      8'h8B: f_snap = read_vout;
      default: f_snap = 16'h0033;         // PMBUS_REVISION 1.3 / 1.3
    endcase
  endfunction

  wire [3:0] wl = f_wlen(cmd), rl = f_rlen(cmd);
  // a complete write: the full data, with or without its PEC
  wire wr_ok    = active && !rep && !drop && nb >= 4'd2 && wl != 4'hF &&
                  ({1'b0, nw} == wl || {1'b0, nw} == wl + 4'd1);
  wire wr_short = active && !rep && !drop && nb >= 4'd2 && wl != 4'hF && {1'b0, nw} < wl;

  // ---------------- events, in priority order ----------------
  wire ev_to    = active && tcnt == TW'(TIMEOUT);
  wire ev_start = !ev_to && start;
  wire ev_stop  = !ev_to && !start && stop;
  wire ev_rise  = !ev_to && !start && !stop && active && rise;
  wire ev_fall  = !ev_to && !start && !stop && active && fall_h && !pre;
  wire ev_rx    = ev_fall && bitn == 4'd7 && !tx;        // a byte received: ACK it or not
  wire ev_ackend= ev_fall && bitn == 4'd8;               // the ACK bit ends

  // decision on a received byte
  wire wp_bad = !(sh == 8'h80 || sh == 8'h40 || sh == 8'h20 || sh == 8'h00);
  logic r_ack, r_c7, r_c6, r_c5;
  always_comb begin
    r_ack = 1'b0; r_c7 = 1'b0; r_c6 = 1'b0; r_c5 = 1'b0;
    if (drop) ;
    else if (nb == 4'd0)                                   // address (or ARA)
      r_ack = (sh == ARA) ? !smbalert_n : (sh == {ADDR, 1'b0});
    else if (!rep && nb == 4'd1) begin                     // command
      r_ack = (f_wlen(sh) != 4'hF) || (f_rlen(sh) != 4'hF);
      r_c7  = !r_ack;
    end else if (!rep) begin                               // data / PEC
      if (wl == 4'hF || {1'b0, nw} > wl || (nw == 3'd0 && (f_prot(cmd, wp80, wp40) || (cmd == 8'h10 && wp_bad))))
        r_c6 = 1'b1;
      else if ({1'b0, nw} < wl) r_ack = 1'b1;
      else if (sh == crc)       r_ack = 1'b1;
      else                      r_c5 = 1'b1;
    end else begin                                         // address after repeated START
      r_ack = (sh[7:1] == ADDR) && sh[0] && nb == 4'd2 && rl != 4'hF;
      r_c7  = (sh[7:1] == ADDR) && sh[0] && nb == 4'd2 && rl == 4'hF;
    end
  end
  wire [3:0] cml_set = {ev_rx && r_c7, (ev_rx && r_c6) || (ev_stop && wr_short), ev_rx && r_c5, ev_to};
  // next byte to send when the host ACKs: data, then the PEC, then 0xFF
  wire [7:0] nxt = (ara ? (ntx == 4'd1) : (ntx == rl)) ? crc
                 : (ara || ntx > rl) ? 8'hFF : f_rbyte(cmd, ntx, snap);
  wire [7:0] b0  = f_rbyte(cmd, 4'd0, snap);

  assign smbalert_n = !(((cml != 4'h0) || ov_l) && !alert_ack);

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      scl_o <= 1'b1; sda_o <= 1'b1;
      active <= 1'b0; rep <= 1'b0; drop <= 1'b0; tx <= 1'b0; mack <= 1'b0; pre <= 1'b0; ara <= 1'b0;
      bitn <= '0; nb <= '0; nw <= '0; ntx <= '0;
      sh <= '0; crc <= '0; cmd <= '0; txb <= '0; w0 <= '0; w1 <= '0; snap <= '0;
      stretch <= '0; tcnt <= '0;
      operation <= 8'h80; on_off_config <= 8'h1E; vout_command <= 16'h0000;
      wp80 <= 1'b0; wp40 <= 1'b0; wp20 <= 1'b0;
      cml <= 4'h0; ov_l <= 1'b0; alert_ack <= 1'b0;
      irq_cml <= 1'b0; irq_upd <= 1'b0; irq_to <= 1'b0;
    end else begin
      irq_upd <= 1'b0;
      irq_to  <= ev_to;
      irq_cml <= (cml_set != 4'h0);
      if (vout_ov && !ov_l) begin ov_l <= 1'b1; alert_ack <= 1'b0; end
      if (stretch != 0) begin
        stretch <= stretch - 1'b1;
        if (stretch == SW'(1)) scl_o <= 1'b1;
      end
      // tTIMEOUT: SCL low too long inside a transfer
      if (!active || scl_f || ev_to) tcnt <= '0;
      else tcnt <= tcnt + 1'b1;

      if (ev_to) begin
        active <= 1'b0; tx <= 1'b0; sda_o <= 1'b1; scl_o <= 1'b1; stretch <= '0;
      end
      if (ev_start) begin
        if (!active) begin
          rep <= 1'b0; drop <= 1'b0; nb <= '0; nw <= '0; crc <= '0;
        end else
          rep <= 1'b1;
        active <= 1'b1; tx <= 1'b0; ara <= 1'b0; bitn <= '0; sda_o <= 1'b1; pre <= 1'b1;
      end
      if (ev_stop) begin
        if (wr_ok)
          case (cmd)
            8'h01: begin operation <= w0; irq_upd <= 1'b1; end
            8'h02: begin on_off_config <= w0; irq_upd <= 1'b1; end
            8'h03: begin cml <= 4'h0; ov_l <= vout_ov; alert_ack <= 1'b0; end
            8'h10: begin wp80 <= w0[7]; wp40 <= w0[6]; wp20 <= w0[5]; end
            default: begin vout_command <= {w1, w0}; irq_upd <= 1'b1; end   // 8'h21
          endcase
        active <= 1'b0; tx <= 1'b0; sda_o <= 1'b1;
      end
      if (ev_rise) begin
        if (bitn < 4'd8) begin
          if (!tx) sh <= {sh[6:0], sda_f};
          else if (sda_o && !sda_f) begin      // lost arbitration: stop sending
            tx <= 1'b0; drop <= 1'b1; sda_o <= 1'b1;
          end
        end else if (tx)
          mack <= !sda_f;
      end
      if (active && fall_h && pre && !ev_to && !start && !stop) pre <= 1'b0;
      if (ev_fall && bitn == 4'd7 && tx) begin              // last bit of a sent byte
        bitn <= 4'd8;
        sda_o <= 1'b1;                                     // release for the host's ACK
        if (ara && ntx == 4'd1) alert_ack <= 1'b1;         // address sent in full
      end
      if (ev_rx) begin
        bitn <= 4'd8;
        if (!r_ack) drop <= 1'b1;
        if (nb == 4'd0) begin
          crc <= f_crc8(8'h00, sh);
          ara <= (sh == ARA) && r_ack;
        end else if (!rep && nb == 4'd1) begin
          if (!drop) begin cmd <= sh; crc <= f_crc8(crc, sh); end
        end else if (!rep && !drop) begin
          if (r_ack && {1'b0, nw} < wl) begin
            crc <= f_crc8(crc, sh);
            if (nw == 3'd0) w0 <= sh; else w1 <= sh;
          end
          nw <= nw + 1'b1;
        end else if (r_ack) begin
          crc <= f_crc8(crc, sh); snap <= f_snap(cmd);
        end
        if (nb != 4'hF) nb <= nb + 1'b1;
        sda_o <= !r_ack;
      end
      if (ev_ackend) begin
        bitn <= '0;
        if (!tx) begin
          sda_o <= 1'b1;
          if (STRETCH != 0 && !sda_o && (nb == 4'd1 || (rep && nb == 4'd3))) begin
            scl_o <= 1'b0; stretch <= SW'(STRETCH);       // stretch after an address ACK
          end
          if (ara && nb == 4'd1) begin                     // ARA: send our address
            tx <= 1'b1; ntx <= 4'd1; txb <= {ADDR, 1'b0}; sda_o <= ADDR[6];
            crc <= f_crc8(crc, {ADDR, 1'b0});
          end else if (rep && nb == 4'd3 && !drop) begin   // start sending read data
            tx <= 1'b1; ntx <= 4'd1;
            txb <= b0; sda_o <= b0[7];
            crc <= f_crc8(crc, b0);
          end
        end else if (mack) begin                           // the host wants another byte
          if (!ara && ntx < rl) crc <= f_crc8(crc, nxt);
          if (ntx != 4'hF) ntx <= ntx + 1'b1;
          txb <= nxt; sda_o <= nxt[7];
        end else begin
          tx <= 1'b0; drop <= 1'b1; sda_o <= 1'b1;        // host NACK: done until STOP
        end
      end
      if (ev_fall && bitn < 4'd7) begin
        bitn <= bitn + 1'b1;
        if (tx) sda_o <= txb[3'd6 - bitn[2:0]];
      end
      if (cml_set != 4'h0) begin cml <= cml | cml_set; alert_ack <= 1'b0; end
    end
  end
endmodule
