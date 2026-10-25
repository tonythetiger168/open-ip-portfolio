// SPDX-License-Identifier: Apache-2.0
// ============================================================================
// UCIe_top v2.0: the Retry function of a UCIe Die-to-Die Adapter: flits
// with a CRC and a sequence number, acknowledged (Ack) or negatively
// acknowledged (Nak) by the far side, kept in a replay buffer and resent
// from the first unacknowledged one on a Nak or a replay timeout
// ----------------------------------------------------------------------------
//  - Protocol side: tx_valid / tx_ready / tx_data (one 64-bit payload per
//    flit); rx_valid / rx_data, payloads delivered once each, in order.
//  - Link side: lt_valid / lt_flit out, lr_valid / lr_flit in. A flit is
//    {DATA, SEQ[3:0], ACK[3:0], NAK, payload[63:0], CRC[15:0]}; CRC-16
//    (polynomial 0x1021, seed 0xFFFF, MSB first) over the 74 bits before
//    it. NOP flits (DATA clear) carry only ACK / NAK.
//  - Every flit carries ACK: the last sequence number received in order.
//    It frees replay buffer entries up to it (an ACK that does not fall
//    within what is outstanding is ignored). NAK set: the far side lost a
//    flit; everything outstanding is resent.
//  - Transmit: a replay in progress first, then a new payload (tx_ready:
//    the RB-entry replay buffer has room and no replay is running), then a
//    NOP when an Ack or Nak is owed. A replay also starts when nothing has
//    been acknowledged for TO clocks while flits are outstanding.
//  - Receive: a flit with a bad CRC is dropped (ev_crc) and a Nak is owed;
//    a DATA flit with the expected SEQ is delivered and an Ack is owed; an
//    old SEQ (a replayed duplicate) is dropped and an Ack is owed; a SEQ
//    ahead is dropped and a Nak is owed. Only one Nak is sent until the
//    expected flit arrives.
//  - ev_replay: a replay starts (Nak or timeout). tx_pend: flits
//    outstanding.
//  Not implemented: the UCIe flit formats (68B, 256B standard and latency
//  optimized) and their real CRC, the Adapter's link state machine and
//  sideband messages, stack multiplexing, parameter exchange, the
//  physical layer. Widths, the field layout and the CRC are ours; they
//  have not been checked against another UCIe Adapter.
// ============================================================================
module UCIe_top #(
  parameter int RB = 8,                 // replay buffer entries, power of 2, at most 8
  parameter int TO = 32                 // replay timeout, clocks
)(
  input  logic        clk,
  input  logic        rst_n,
  // protocol side
  input  logic        tx_valid,
  input  logic [63:0] tx_data,
  output logic        tx_ready,
  output logic        rx_valid,
  output logic [63:0] rx_data,
  // link side
  output logic        lt_valid,
  output logic [89:0] lt_flit,
  input  logic        lr_valid,
  input  logic [89:0] lr_flit,
  // status and events
  output logic [3:0]  tx_pend,
  output logic        ev_crc,
  output logic        ev_replay
);
  localparam int BW = $clog2(RB);

  function automatic logic [15:0] crc16(input logic [73:0] d);
    logic [15:0] c;
    c = 16'hFFFF;
    for (int i = 73; i >= 0; i--)
      c = {c[14:0], 1'b0} ^ ((c[15] ^ d[i]) ? 16'h1021 : 16'h0000);
    crc16 = c;
  endfunction

  // ---------------- transmit ----------------
  logic [63:0] rb [0:RB-1];
  logic [3:0]  ws, as, rp;               // next new, oldest outstanding, next to send
  logic [$clog2(TO)-1:0] tmr;
  wire  [3:0]  outst = ws - as;
  wire         replaying = rp != ws;
  assign tx_ready = outst != 4'(RB) && !replaying;
  assign tx_pend = outst;

  // ---------------- receive ----------------
  logic [3:0]  exp;                      // next SEQ expected
  logic        ack_owed, nak_owed, nak_sent;
  wire         r_ok = crc16(lr_flit[89:16]) == lr_flit[15:0];
  wire         r_data = lr_flit[89];
  wire  [3:0]  r_seq = lr_flit[88:85];
  wire  [3:0]  r_ack = lr_flit[84:81];
  wire         r_nak = lr_flit[80];
  wire  [3:0]  r_n = r_ack + 4'd1 - as; // flits this ACK frees
  wire  [3:0]  r_behind = exp - r_seq;

  always_ff @(posedge clk or negedge rst_n)
    if (!rst_n) begin
      for (int i = 0; i < RB; i++) rb[i] <= '0;
      ws <= '0; as <= '0; rp <= '0; tmr <= '0;
      exp <= '0; ack_owed <= 1'b0; nak_owed <= 1'b0; nak_sent <= 1'b0;
      lt_valid <= 1'b0; lt_flit <= '0; rx_valid <= 1'b0; rx_data <= '0;
      ev_crc <= 1'b0; ev_replay <= 1'b0;
    end else begin : b_main
      logic [3:0]  as_n, rp_n, ws_n;
      logic        snd, sdat, ack_n, nak_n;
      logic [3:0]  sseq;
      logic [63:0] spl;
      as_n = as; rp_n = rp; ws_n = ws; ack_n = ack_owed; nak_n = nak_owed;
      snd = 1'b0; sdat = 1'b0; sseq = '0; spl = '0;
      lt_valid <= 1'b0; rx_valid <= 1'b0; ev_crc <= 1'b0; ev_replay <= 1'b0;

      // ---- transmit, on the state as it stands
      if (replaying) begin
        snd = 1'b1; sdat = 1'b1; sseq = rp; spl = rb[rp[BW-1:0]]; rp_n = rp + 1'b1;
      end else if (tx_valid && tx_ready) begin
        snd = 1'b1; sdat = 1'b1; sseq = ws; spl = tx_data;
        rb[ws[BW-1:0]] <= tx_data; ws_n = ws + 1'b1; rp_n = rp + 1'b1;
      end else if (ack_owed || nak_owed) snd = 1'b1;
      if (snd) begin
        lt_valid <= 1'b1;
        lt_flit <= {sdat, sseq, exp - 4'd1, nak_owed, spl, crc16({sdat, sseq, exp - 4'd1, nak_owed, spl})};
        ack_n = 1'b0; nak_n = 1'b0;
      end

      // ---- receive
      if (lr_valid) begin
        if (!r_ok) begin
          ev_crc <= 1'b1;
          if (!nak_sent) begin nak_n = 1'b1; nak_sent <= 1'b1; end
        end else begin
          // the far side's ACK / NAK
          if (r_n <= outst) as_n = as + r_n;
          if (r_nak) begin rp_n = as_n; ev_replay <= 1'b1; end
          // its payload
          if (r_data) begin
            if (r_seq == exp) begin
              rx_valid <= 1'b1; rx_data <= lr_flit[79:16];
              exp <= exp + 1'b1; ack_n = 1'b1; nak_sent <= 1'b0;
            end else if (r_behind <= 4'(RB)) ack_n = 1'b1;                // an old SEQ (behind 0 is the expected one)
            else if (!nak_sent) begin nak_n = 1'b1; nak_sent <= 1'b1; end
          end
        end
      end

      // ---- replay timeout: nothing acknowledged for TO clocks
      if (as_n != as || ws == as || replaying) tmr <= '0;
      else if (32'(tmr) == TO - 1) begin
        tmr <= '0; rp_n = as_n; ev_replay <= 1'b1;
      end else tmr <= tmr + 1'b1;

      // a replay never resends what is acknowledged
      if (4'(rp_n - as_n) > 4'(ws_n - as_n)) rp_n = as_n;
      as <= as_n; rp <= rp_n; ws <= ws_n; ack_owed <= ack_n; nak_owed <= nak_n;
    end
endmodule
