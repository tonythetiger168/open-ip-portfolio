// SPDX-License-Identifier: Apache-2.0
// ============================================================================
// USB4_top v2.0: USB4-style transport layer adapter, one link (transport
// layer packets with HEC-protected headers, HEC delineation, two tunneled
// paths with HopID routing, credit-based flow control per path)
// ----------------------------------------------------------------------------
//  - Line: one byte per clk each way, most significant byte of each field
//    first, while link_up (the logical layer: lane bonding, 64b/66b /
//    128b/132b, RS-FEC and the LTSSM belong below). Packets go back to back
//    with no gaps; with nothing to send the transmitter sends Idle packets.
//  - Transport layer packet (TLP): a 4-byte header, then Length payload
//    bytes padded with zeros to a multiple of 4. Header = {PDF[3:0],
//    SuppID, HopID[10:0], Length[7:0], HEC[7:0]}; HEC = CRC-8 (x^8+x^2+x+1,
//    initial value 0, bit 31 first) of header bits 31:8, XOR 55h. SuppID
//    is sent 0 and ignored.
//      Idle: HopID 0, PDF 0, Length 0.
//      Credit grant: HopID 0, PDF 1, Length 4; payload {5'b0, HopID[10:0],
//        8'h00, count[7:0]}: the receiver's cumulative credit count for its
//        path with that (ingress) HopID.
//      Data: HopID of a path, Length 1..MAXL (PDF sent 0, ignored).
//  - Delineation (HEC, as in ATM cell delineation): HUNT checks the HEC of
//    every 4-byte window; a good one moves to PRESYNC at that alignment,
//    where packets are followed by their length but not delivered; DELTA
//    good headers in a row reach SYNC, a bad one returns to HUNT. In SYNC a
//    header with a single-bit error is corrected (ev_hec_fix); any other
//    HEC error returns to HUNT (ev_hec_bad). The link going down returns to
//    HUNT. After link_up the transmitter sends 2 x DELTA Idle packets first.
//  - Paths: two, each enabled by path_en[p], with an egress HopID (hop_txN,
//    put in its data packets) and an ingress HopID (hop_rxN, accepted from
//    the partner). Packets are written through tx_* with tx_path, one
//    buffer of MAXL bytes per path (a longer write is cut into packets).
//    Received packets are handed out through rx_* with rx_path, in arrival
//    order, from RXB buffers per path.
//  - Credits: one credit is one receive buffer. While its receiver is in
//    SYNC an adapter sends each enabled path's credit grant at once after
//    link up, again when one of the path's buffers is read out, and every
//    REFRESH clocks; a lost grant is made good by the next (counts are
//    cumulative). A path sends (path_up) once a grant for its egress HopID
//    arrived and while count - sent != 0; a grant with count - sent over
//    RXB, for no enabled path or with reserved bits set is ignored
//    (ev_proto). Credit counts restart at link up; a packet is kept until
//    its last byte went out with the link up, so one cut by the link going
//    down is sent again (the receiver drops the part it got).
//  - Receive errors (the packet is skipped by its length): HopID 0 with any
//    other PDF / Length (ev_proto), a HopID of no enabled path (ev_hop),
//    Length 0 or over MAXL on a path (ev_len), a packet for a path whose
//    buffers are all full (ev_overflow).
//  Not implemented: the logical layer, lane bonding, control packets and
//  the router configuration space, link management packets other than the
//  credit grant, path setup over the configuration space (the HopIDs are
//  pins here), more than two paths, Path Credits Sync and shared buffering,
//  the protocol adapters (DisplayPort, PCIe, USB3 tunnels). Field layouts
//  follow the USB4 transport layer as we read it; they have not been
//  checked against a compliant router.
// ============================================================================
module USB4_top #(
  parameter int MAXL    = 32,       // payload bytes in a data packet (multiple of 4, at most 64)
  parameter int RXB     = 2,        // receive buffers per path (2 or 4)
  parameter int DELTA   = 4,        // good headers in a row from PRESYNC to SYNC (2..7)
  parameter int REFRESH = 128       // clocks between credit grant refreshes (power of 2)
)(
  input  logic        clk,
  input  logic        rst_n,
  input  logic        link_up,         // the logical layer is up
  output logic [7:0]  tx_sym,
  input  logic [7:0]  rx_sym,
  input  logic [1:0]  path_en,
  input  logic [10:0] hop_tx0,         // path 0 egress HopID
  input  logic [10:0] hop_tx1,
  input  logic [10:0] hop_rx0,         // path 0 ingress HopID
  input  logic [10:0] hop_rx1,
  input  logic        tx_valid,        // packet bytes in
  output logic        tx_ready,
  input  logic [7:0]  tx_data,
  input  logic        tx_last,
  input  logic        tx_path,
  output logic        rx_valid,        // packet bytes out
  input  logic        rx_ready,
  output logic [7:0]  rx_data,
  output logic        rx_last,
  output logic        rx_path,
  output logic        sync,            // receive delineation in SYNC
  output logic [1:0]  path_up,         // a grant arrived for the path
  output logic        ev_hec_fix,      // header single-bit error corrected
  output logic        ev_hec_bad,      // header HEC error in SYNC: back to HUNT
  output logic        ev_proto,        // bad HopID 0 packet or credit grant
  output logic        ev_hop,          // packet for no enabled path
  output logic        ev_len,          // data packet length 0 or over MAXL
  output logic        ev_overflow      // data packet with the path's buffers full
);
  localparam int LW = $clog2(MAXL + 1);
  localparam int FW = $clog2(MAXL);
  localparam int NW = $clog2(MAXL / 4 + 1);
  localparam int CW = $clog2(MAXL + 5);
  localparam int RW = $clog2(RXB);
  localparam int NS = 2 * RXB;               // receive buffers
  localparam int SW = RW + 1;                // buffer index
  localparam int OW = SW + 1;                // order queue pointers
  localparam int JW = $clog2(NS * MAXL);
  localparam int GW = $clog2(REFRESH);
  localparam int LEAD = 2 * DELTA;           // Idle packets after link up

  function automatic logic [7:0] crc8(input logic [23:0] d);
    crc8 = 8'h00;
    for (int i = 23; i >= 0; i--) crc8 = {crc8[6:0], 1'b0} ^ ((crc8[7] ^ d[i]) ? 8'h07 : 8'h00);
  endfunction
  // syndrome of a header: 0 when good
  function automatic logic [7:0] synd(input logic [31:0] h);
    synd = crc8(h[31:8]) ^ 8'h55 ^ h[7:0];
  endfunction
  // syndrome of a single-bit error at bit i
  function automatic logic [7:0] esyn(input int i);
    logic [31:0] e;
    e = 32'd1 << i;
    esyn = crc8(e[31:8]) ^ e[7:0];
  endfunction
  // a header with a single-bit error corrected; bit 32: one was found
  function automatic logic [32:0] fix1(input logic [31:0] h);
    logic [7:0] s;
    s = synd(h);
    fix1 = {1'b0, h};
    for (int i = 0; i < 32; i++) if (esyn(i) == s) fix1 = {1'b1, h ^ (32'd1 << i)};
  endfunction
  function automatic logic [31:0] hdr(input logic [3:0] pdf, input logic [10:0] hop, input logic [7:0] len);
    hdr = {pdf, 1'b0, hop, len, crc8({pdf, 1'b0, hop, len}) ^ 8'h55};
  endfunction
  // payload bytes on the line: Length rounded up to 4
  function automatic logic [8:0] pad4(input logic [7:0] l);
    pad4 = 9'({l[7:2], 2'b00}) + (l[1:0] != 2'd0 ? 9'd4 : 9'd0);
  endfunction
  // byte i of a header (k: 0 Idle, 1 credit grant, 2 data)
  function automatic logic [7:0] hbyte(input logic [1:0] k, input logic [10:0] hop, input logic [7:0] len,
                                       input logic [1:0] i);
    logic [31:0] w;
    w = k == 2'd1 ? hdr(4'h1, 11'd0, 8'd4) : k == 2'd2 ? hdr(4'h0, hop, len) : hdr(4'h0, 11'd0, 8'd0);
    hbyte = 8'(w >> {~i, 3'b000});
  endfunction
  // byte i of a credit grant's payload
  function automatic logic [7:0] gbyte(input logic [10:0] hop, input logic [7:0] cnt, input logic [1:0] i);
    logic [31:0] w;
    w = {5'd0, hop, 8'h00, cnt};
    gbyte = 8'(w >> {~i, 3'b000});
  endfunction
  function automatic logic [JW-1:0] ridx(input logic [SW-1:0] s, input logic [LW-1:0] o);
    ridx = JW'(s) * JW'(MAXL) + JW'(o);
  endfunction

  // ---------------- transmit ----------------
  typedef enum logic {T_IDLE, T_PKT} ts_t;
  ts_t           tst;
  logic [CW-1:0] tcnt;                       // bytes of the packet out
  logic [1:0]    tkind;                      // 0 Idle, 1 credit grant, 2 data
  logic          tp;                         // its path (data, credit grant)
  logic [NW-1:0] tn;                         // its payload words on the line
  logic [7:0]    tga;                        // a credit grant's count
  logic [7:0]    tb [0:2*MAXL-1];            // a packet buffer per path
  logic [LW-1:0] tl [0:1];
  logic [1:0]    tfull;
  logic [FW-1:0] widx [0:1];
  logic [3:0]    lead;
  logic          rr;                         // path served next on a tie
  logic [7:0]    sent [0:1], lim [0:1];
  logic [1:0]    up;
  // ---------------- receive ----------------
  typedef enum logic [1:0] {D_HUNT, D_PRE, D_SYNC} ds_t;
  ds_t           dst;
  logic [2:0]    dcnt;                       // good headers in PRESYNC
  typedef enum logic {R_HDR, R_PAY} rs_t;
  rs_t           rst;
  logic [23:0]   win;                        // the last 3 bytes, [7:0] newest
  logic [1:0]    rcnt;                       // header bytes in
  logic [8:0]    rleft;                      // payload bytes still to come
  logic [1:0]    rm;                         // payload: 0 skip, 1 data, 2 credit grant
  logic          rp;                         // data: its path
  logic [LW-1:0] rlen, rgi;                  // data: length, bytes in
  logic [7:0]    rf [0:NS*MAXL-1];
  logic [LW-1:0] rq_len [0:NS-1];
  logic [RW-1:0] wptr [0:1], rptr [0:1];
  logic [RW:0]   occ [0:1];
  logic          oq [0:NS-1];                // path of each packet, in arrival order
  logic [OW-1:0] oqw, oqr;
  logic [FW-1:0] rgot;
  logic [7:0]    adv [0:1];                  // credit counts granted
  logic [1:0]    gp;                         // grants to send
  logic [GW-1:0] gtm;

  assign sync = dst == D_SYNC;
  assign path_up = up;

  // the next packet to send
  wire [1:0]   t_rel = {tst == T_PKT && tkind == 2'd2 && tp, tst == T_PKT && tkind == 2'd2 && !tp};
  wire [1:0]   t_can = tfull & path_en & ~t_rel & {lim[1] != sent[1], lim[0] != sent[0]};
  wire         t_dp = t_can[rr] ? rr : !rr;        // the data path, if t_can[t_dp]
  wire [1:0]   t_gp = gp & path_en;
  wire         t_gq = !t_gp[0];                    // the grant's path, if t_gp != 0
  wire         t_new = tst == T_IDLE || tcnt == CW'(4) + CW'({tn, 2'b00});
  wire [1:0]   t_nk = lead != 4'(LEAD) ? 2'd0 : t_gp != 2'd0 && dst == D_SYNC ? 2'd1 : t_can[t_dp] ? 2'd2 : 2'd0;
  wire [7:0]   t_db = CW'(tcnt - CW'(4)) < CW'(tl[tp]) ? tb[{tp, FW'(tcnt - CW'(4))}] : 8'h00;
  assign tx_ready = !tfull[tx_path];

  // receive
  wire [31:0]  r_nw = {win, rx_sym};             // with the byte now
  wire [7:0]   r_s = synd(r_nw);
  wire [32:0]  r_fx = fix1(r_nw);
  wire [JW-1:0] r_rd = ridx({oq[oqr[SW-1:0]], rptr[oq[oqr[SW-1:0]]]}, LW'(rgot));
  assign rx_valid = oqw != oqr;
  assign rx_path = oq[oqr[SW-1:0]];
  assign rx_data = rf[r_rd];
  assign rx_last = rgot == FW'(rq_len[{rx_path, rptr[rx_path]}] - 1'b1);

  always_ff @(posedge clk or negedge rst_n)
    if (!rst_n) begin
      tst <= T_IDLE; tcnt <= '0; tkind <= '0; tp <= 1'b0; tn <= '0; tga <= '0; tfull <= '0;
      tl[0] <= '0; tl[1] <= '0; widx[0] <= '0; widx[1] <= '0; lead <= '0; rr <= 1'b0;
      sent[0] <= '0; sent[1] <= '0; lim[0] <= '0; lim[1] <= '0; up <= '0; tx_sym <= '0;
      dst <= D_HUNT; dcnt <= '0; rst <= R_HDR; win <= '0; rcnt <= '0; rleft <= '0; rm <= '0; rp <= 1'b0;
      rlen <= '0; rgi <= '0; wptr[0] <= '0; wptr[1] <= '0; rptr[0] <= '0; rptr[1] <= '0;
      occ[0] <= '0; occ[1] <= '0; oqw <= '0; oqr <= '0; rgot <= '0; adv[0] <= 8'(RXB); adv[1] <= 8'(RXB);
      gp <= 2'b11; gtm <= '0;
      {ev_hec_fix, ev_hec_bad, ev_proto, ev_hop, ev_len, ev_overflow} <= '0;
    end else begin : b_main
      logic [1:0] put, fr, gn;                     // a buffer filled / read out, per path; grants
      logic [31:0] h;
      logic       ok;
      put = '0; fr = '0;
      {ev_hec_fix, ev_hec_bad, ev_proto, ev_hop, ev_len, ev_overflow} <= '0;

      // ---------------- transmit ----------------
      if (!link_up) begin
        tst <= T_IDLE; tx_sym <= 8'h00; lead <= '0;
        sent[0] <= '0; sent[1] <= '0; lim[0] <= '0; lim[1] <= '0; up <= '0;
      end else if (t_new) begin
        // the last packet's final byte went out with the link up
        if (tst == T_PKT && tkind == 2'd2) tfull[tp] <= 1'b0;
        tst <= T_PKT; tcnt <= CW'(1); tkind <= t_nk;
        if (lead != 4'(LEAD)) lead <= lead + 4'd1;
        case (t_nk)
          2'd1: begin
            tp <= t_gq; tn <= NW'(1); tga <= adv[t_gq];
            tx_sym <= hbyte(2'd1, 11'd0, 8'd4, 2'd0);
          end
          2'd2: begin
            tp <= t_dp; tn <= NW'(pad4(8'(tl[t_dp])) >> 2);
            sent[t_dp] <= sent[t_dp] + 8'd1; rr <= !t_dp;
            tx_sym <= hbyte(2'd2, t_dp ? hop_tx1 : hop_tx0, 8'(tl[t_dp]), 2'd0);
          end
          default: begin
            tn <= '0;
            tx_sym <= hbyte(2'd0, 11'd0, 8'd0, 2'd0);
          end
        endcase
      end else begin
        tcnt <= tcnt + 1'b1;
        if (tcnt < CW'(4)) tx_sym <= hbyte(tkind, tp ? hop_tx1 : hop_tx0, 8'(tl[tp]), tcnt[1:0]);
        else if (tkind == 2'd1) tx_sym <= gbyte(tp ? hop_rx1 : hop_rx0, tga, tcnt[1:0]);
        else tx_sym <= t_db;
      end
      // writing packets into the buffers
      if (tx_valid && tx_ready) begin
        tb[{tx_path, widx[tx_path]}] <= tx_data;
        widx[tx_path] <= widx[tx_path] + 1'b1;
        if (tx_last || widx[tx_path] == FW'(MAXL - 1)) begin
          tl[tx_path] <= LW'(widx[tx_path]) + 1'b1; widx[tx_path] <= '0; tfull[tx_path] <= 1'b1;
        end
      end

      // ---------------- receive ----------------
      if (!link_up) begin
        dst <= D_HUNT; rst <= R_HDR; rcnt <= '0; win <= '0;
      end else begin
        win <= r_nw[23:0];
        if (dst == D_HUNT) begin
          if (r_s == 8'h00) begin
            dst <= D_PRE; dcnt <= 3'd1; rm <= 2'd0;
            rleft <= pad4(r_nw[15:8]); rst <= pad4(r_nw[15:8]) == 9'd0 ? R_HDR : R_PAY; rcnt <= '0;
          end
        end else if (rst == R_HDR) begin
          rcnt <= rcnt + 2'd1;
          if (rcnt == 2'd3) begin
            // a header: good, or corrected in SYNC
            ok = r_s == 8'h00 || dst == D_SYNC && r_fx[32];
            h = r_s == 8'h00 ? r_nw : r_fx[31:0];
            if (!ok) begin
              dst <= D_HUNT;
              if (dst == D_SYNC) ev_hec_bad <= 1'b1;
            end else begin
              rm <= 2'd0; rgi <= '0;
              rleft <= pad4(h[15:8]);
              if (pad4(h[15:8]) != 9'd0) rst <= R_PAY;
              if (dst == D_PRE) begin
                dcnt <= dcnt + 3'd1;
                if (dcnt == 3'(DELTA - 1)) dst <= D_SYNC;
              end else begin
                if (r_s != 8'h00) ev_hec_fix <= 1'b1;
                if (h[26:16] == 11'd0) begin
                  if (h[31:28] == 4'h1 && h[15:8] == 8'd4) rm <= 2'd2;
                  else if (!(h[31:28] == 4'h0 && h[15:8] == 8'd0)) ev_proto <= 1'b1;
                end else if (!(path_en[0] && h[26:16] == hop_rx0) && !(path_en[1] && h[26:16] == hop_rx1))
                  ev_hop <= 1'b1;
                else begin : b_data
                  logic q;
                  q = !(path_en[0] && h[26:16] == hop_rx0);
                  if (h[15:8] == 8'd0 || h[15:8] > 8'(MAXL)) ev_len <= 1'b1;
                  else if (occ[q] == (RW+1)'(RXB)) ev_overflow <= 1'b1;
                  else begin rm <= 2'd1; rp <= q; rlen <= LW'(h[15:8]); end
                end
              end
            end
          end
        end else begin
          // payload
          rleft <= rleft - 9'd1;
          // (padding goes into the buffer too, after the packet)
          if (rm == 2'd1) begin
            rf[ridx({rp, wptr[rp]}, rgi)] <= rx_sym;
            rgi <= rgi + 1'b1;
          end
          if (rleft == 9'd1) begin
            rst <= R_HDR; rcnt <= '0;
            if (rm == 2'd1) begin
              rq_len[{rp, wptr[rp]}] <= rlen; wptr[rp] <= wptr[rp] + 1'b1;
              oq[oqw[SW-1:0]] <= rp; oqw <= oqw + 1'b1; put[rp] = 1'b1;
            end else if (rm == 2'd2) begin : b_grant
              logic       m0, m1, q;
              logic [7:0] d;
              m0 = path_en[0] && r_nw[26:16] == hop_tx0 && hop_tx0 != 11'd0;
              m1 = path_en[1] && r_nw[26:16] == hop_tx1 && hop_tx1 != 11'd0;
              q = !m0;
              d = r_nw[7:0] - sent[q];
              if (r_nw[31:27] != 5'd0 || r_nw[15:8] != 8'h00 || !(m0 || m1) || d > 8'(RXB)) ev_proto <= 1'b1;
              else begin lim[q] <= r_nw[7:0]; up[q] <= 1'b1; end
            end
          end
        end
      end

      // reading packets out
      if (rx_valid && rx_ready) begin
        rgot <= rgot + 1'b1;
        if (rx_last) begin
          rgot <= '0; oqr <= oqr + 1'b1; rptr[rx_path] <= rptr[rx_path] + 1'b1; fr[rx_path] = 1'b1;
        end
      end
      for (int p = 0; p < 2; p++) begin
        occ[p] <= occ[p] + (RW+1)'(put[p]) - (RW+1)'(fr[p]);
        // credit counts: restart while the link is down
        if (!link_up) adv[p] <= 8'(RXB) - 8'(occ[p]) + 8'(fr[p]);
        else if (fr[p]) adv[p] <= adv[p] + 8'd1;
      end
      // grants to send: at link up, on each buffer read out, every REFRESH
      // clocks in SYNC
      gn = gp | fr;
      if (link_up && t_new && t_nk == 2'd1) gn[t_gq] = fr[t_gq];
      if (!link_up || dst == D_SYNC && gtm == '0) gn = 2'b11;
      gp <= gn;
      if (link_up && dst == D_SYNC) gtm <= gtm + 1'b1;
      else gtm <= '0;
    end
endmodule
