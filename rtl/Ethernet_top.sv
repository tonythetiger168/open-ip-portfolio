// SPDX-License-Identifier: Apache-2.0
// ============================================================================
// Ethernet_top v2.0: IEEE 802.3 MAC (one port, GMII-style byte interface)
// with address filtering and PAUSE flow control
// ----------------------------------------------------------------------------
//  - Line: one byte per byte time of cfg_div + 1 clocks (gtxd / gtx_en /
//    gtx_er change once per byte time; grxd / grx_dv / grx_er are sampled
//    once per byte time, so the far end must use the same byte time).
//  - Transmit: a frame (DA .. payload) comes from the tx_* stream, one
//    byte per byte time (tx_ready is high for one clock at the byte time,
//    tx_last marks the last byte). The MAC sends 7 preamble bytes 0x55 and
//    the SFD 0xD5, the frame, zero padding up to 60 bytes, the FCS (CRC-32,
//    least significant byte first) and at least 12 idle byte times. Without
//    a byte in time it sends one byte with gtx_er, ends the frame and
//    pulses tx_underrun. tx_done pulses after the FCS. No new frame starts
//    while a PAUSE is running (tx_paused).
//  - Receive: any number of 0x55 then 0xD5 starts a frame (another byte
//    drops it). A frame is accepted when its DA is cfg_mac, broadcast, the
//    PAUSE address 01-80-C2-00-00-01, or anything with cfg_promisc. Bytes go
//    out on rx_* six byte times late, without the FCS; the last one has
//    rx_last and rx_stat = {pause, phy_err, len_err, crc_err}:
//      crc_err  the FCS does not check
//      len_err  shorter than 64 bytes, or longer than 1518 (1522 with a
//               VLAN tag, type 0x8100), FCS included
//      phy_err  grx_er during the frame
//      pause    a MAC control PAUSE frame (type 0x8808, opcode 0x0001)
//    A frame that ends before its sixth byte, or a bad preamble, pulses
//    rx_frag; a frame that fails the filter is dropped silently.
//  - PAUSE: an error-free PAUSE frame with cfg_pause_en holds the
//    transmitter for quanta x 64 byte times (512 bit times each).
//  Not implemented: half duplex (CSMA/CD), sending PAUSE frames, PFC,
//  multicast hash filtering, statistics counters, jumbo frames.
// ============================================================================
module Ethernet_top (
  input  logic        clk,
  input  logic        rst_n,
  // configuration
  input  logic [4:0]  cfg_div,
  input  logic [47:0] cfg_mac,
  input  logic        cfg_promisc,
  input  logic        cfg_pause_en,
  // transmit host
  input  logic        tx_valid,
  output logic        tx_ready,
  input  logic [7:0]  tx_data,
  input  logic        tx_last,
  output logic        tx_done,
  output logic        tx_underrun,
  output logic        tx_paused,
  // GMII
  output logic [7:0]  gtxd,
  output logic        gtx_en,
  output logic        gtx_er,
  input  logic [7:0]  grxd,
  input  logic        grx_dv,
  input  logic        grx_er,
  // receive host
  output logic        rx_valid,
  output logic [7:0]  rx_data,
  output logic        rx_last,
  output logic [3:0]  rx_stat,
  output logic        rx_frag
);
  localparam logic [47:0] PAUSE_DA = 48'h0180C2000001;
  localparam logic [31:0] RESIDUE = 32'hDEBB20E3;

  function automatic logic [31:0] crc8(input logic [31:0] c, input logic [7:0] d);
    logic [31:0] r;
    r = c;
    for (int i = 0; i < 8; i++) r = (r[0] ^ d[i]) ? (r >> 1) ^ 32'hEDB88320 : r >> 1;
    crc8 = r;
  endfunction

  // byte time
  logic [4:0] dc;
  wire        ls = dc == cfg_div;

  // ---------------- transmit ----------------
  typedef enum logic [2:0] {T_IDLE, T_PRE, T_DATA, T_PAD, T_FCS, T_IFG} tst_t;
  tst_t        ts;
  logic [3:0]  tk;                       // preamble / FCS / gap byte count
  logic [5:0]  tn;                       // frame bytes sent, up to 60
  logic [31:0] tcrc;
  logic [21:0] pause;
  assign tx_ready = ts == T_DATA && ls;
  assign tx_paused = pause != 22'd0;

  // ---------------- receive ----------------
  typedef enum logic [2:0] {R_IDLE, R_PRE, R_DATA, R_DROP, R_FL1, R_FL2} rst_t;
  rst_t        rs;
  logic [10:0] rn;                       // bytes received (saturates)
  logic [31:0] rcrc;
  logic [7:0]  p0, p1, p2, p3, p4, p5;   // six byte delay, p5 oldest
  logic [39:0] da;                       // DA bytes so far
  logic [15:0] rtype, ropc, rq;
  logic        acc, perr;

  always_ff @(posedge clk or negedge rst_n)
    if (!rst_n) begin
      dc <= '0; ts <= T_IDLE; tk <= '0; tn <= '0; tcrc <= '0; pause <= '0;
      gtxd <= '0; gtx_en <= 1'b0; gtx_er <= 1'b0; tx_done <= 1'b0; tx_underrun <= 1'b0;
      rs <= R_IDLE; rn <= '0; rcrc <= '0; {p0, p1, p2, p3, p4, p5} <= '0; da <= '0;
      rtype <= '0; ropc <= '0; rq <= '0; acc <= 1'b0; perr <= 1'b0;
      rx_valid <= 1'b0; rx_data <= '0; rx_last <= 1'b0; rx_stat <= '0; rx_frag <= 1'b0;
    end else begin
      tx_done <= 1'b0; tx_underrun <= 1'b0; rx_valid <= 1'b0; rx_frag <= 1'b0;
      dc <= ls ? 5'd0 : dc + 5'd1;
      if (ls) begin
        if (pause != 22'd0) pause <= pause - 22'd1;
        // ---- transmit
        unique case (ts)
          T_IDLE: if (tx_valid && pause == 22'd0) begin
            ts <= T_PRE; tk <= 4'd1; gtx_en <= 1'b1; gtxd <= 8'h55;
          end
          T_PRE: begin
            tk <= tk + 4'd1;
            gtxd <= tk == 4'd7 ? 8'hD5 : 8'h55;
            if (tk == 4'd7) begin ts <= T_DATA; tn <= '0; tcrc <= '1; end
          end
          T_DATA: if (tx_valid) begin
            gtxd <= tx_data; tcrc <= crc8(tcrc, tx_data);
            if (tn != 6'd60) tn <= tn + 6'd1;
            if (tx_last) begin ts <= tn >= 6'd59 ? T_FCS : T_PAD; tk <= '0; end
          end else begin
            gtxd <= 8'h00; gtx_er <= 1'b1; tx_underrun <= 1'b1; ts <= T_IFG; tk <= '0;
          end
          T_PAD: begin
            gtxd <= 8'h00; tcrc <= crc8(tcrc, 8'h00); tn <= tn + 6'd1;
            if (tn == 6'd59) ts <= T_FCS;
          end
          T_FCS: begin
            gtxd <= ~tcrc[8 * tk[1:0] +: 8];
            tk <= tk + 4'd1;
            if (tk == 4'd3) begin ts <= T_IFG; tk <= '0; tx_done <= 1'b1; end
          end
          T_IFG: begin
            gtx_en <= 1'b0; gtx_er <= 1'b0; gtxd <= 8'h00;
            tk <= tk + 4'd1;
            if (tk == 4'd11) ts <= T_IDLE;
          end
        endcase

        // ---- receive
        unique case (rs)
          R_IDLE, R_PRE: if (!grx_dv) begin
            if (rs == R_PRE) rx_frag <= 1'b1;
            rs <= R_IDLE;
          end else if (grxd == 8'hD5) begin
            rs <= R_DATA; rn <= '0; rcrc <= '1; perr <= 1'b0; acc <= 1'b0;
          end else if (grxd == 8'h55) rs <= R_PRE;
          else begin rs <= R_DROP; rx_frag <= 1'b1; end
          R_DATA: if (grx_dv) begin : b_byte
            logic [47:0] d2;
            rcrc <= crc8(rcrc, grxd);
            if (rn != 11'h7FF) rn <= rn + 11'd1;
            if (grx_er) perr <= 1'b1;
            {p5, p4, p3, p2, p1, p0} <= {p4, p3, p2, p1, p0, grxd};
            d2 = {da, grxd};
            if (rn < 11'd6) da <= d2[39:0];
            if (rn == 11'd5)
              acc <= cfg_promisc || d2 == cfg_mac || d2 == 48'hFFFF_FFFF_FFFF || d2 == PAUSE_DA;
            if (rn == 11'd12 || rn == 11'd13) rtype <= {rtype[7:0], grxd};
            if (rn == 11'd14 || rn == 11'd15) ropc <= {ropc[7:0], grxd};
            if (rn == 11'd16 || rn == 11'd17) rq <= {rq[7:0], grxd};
            if (rn >= 11'd6 && acc) begin rx_valid <= 1'b1; rx_data <= p5; rx_last <= 1'b0; end
          end else if (rn < 11'd6) begin rs <= R_IDLE; rx_frag <= 1'b1; end
          else rs <= acc ? R_FL1 : R_IDLE;
          R_DROP: if (!grx_dv) rs <= R_IDLE;
          R_FL1: begin
            rx_valid <= 1'b1; rx_data <= p5; rx_last <= 1'b0; rs <= R_FL2;
          end
          R_FL2: begin : b_end
            logic crc_e, len_e, pz;
            crc_e = rcrc != RESIDUE;
            len_e = rn < 11'd64 || rn > (rtype == 16'h8100 ? 11'd1522 : 11'd1518);
            pz = rtype == 16'h8808 && ropc == 16'h0001 && rn >= 11'd18;
            rx_valid <= 1'b1; rx_data <= p4; rx_last <= 1'b1;
            rx_stat <= {pz, perr, len_e, crc_e};
            if (pz && cfg_pause_en && !crc_e && !len_e && !perr) pause <= {rq, 6'd0};
            rs <= R_IDLE;
          end
        endcase
      end
    end
endmodule
