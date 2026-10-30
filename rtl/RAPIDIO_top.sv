// SPDX-License-Identifier: Apache-2.0
// ============================================================================
// RAPIDIO_top v1.0: RapidIO logical / transport layer endpoint (target for
// NREAD / NWRITE / NWRITE_R / SWRITE / MAINTENANCE / DOORBELL, initiator for
// DOORBELL) over a packet byte stream with LP-Serial CRC-16
// ----------------------------------------------------------------------------
//  - Packet stream: rx_valid / rx_data / rx_last carry one octet per clock,
//    the first octet of the packet first; tx_valid / tx_data / tx_last give
//    the packets this endpoint sends (no back pressure). Packet layout:
//    {ackID[4:0], rsvd[2:0]}, {prio[1:0], tt[1:0], ftype[3:0]}, transport
//    (tt 0: dest, src as 8-bit IDs; tt 1: 16-bit IDs), the logical header,
//    payload, CRC-16. CRC-16 is x^16 + x^12 + x^5 + 1 (0x1021), seed 0xFFFF,
//    MSB first, with the first 6 bits of the packet taken as 0. A packet
//    longer than 80 octets carries an early CRC after octet 80 (over octets
//    0..79); the final CRC covers everything before it, early CRC included.
//    Packets are padded with 2 zero octets to a multiple of 4 octets.
//    Sent packets use ackID 0 (the physical layer assigns ackIDs).
//  - Received packets are buffered (up to 511 octets) and executed after
//    their CRCs check. While a packet executes or a packet is sent, new
//    packets are dropped (busy = 1; reported with why 6 the clock after
//    their last octet).
//  - Requests (dest ID = this endpoint's base device ID of the packet's tt):
//    NREAD (ftype 2, ttype 4), NWRITE / NWRITE_R (ftype 5, ttype 4 / 5),
//    SWRITE (ftype 6) on a 1 KB memory at addresses 0x000..0x3FF; rdsize /
//    wrsize with wdptr as in the RapidIO size table (sub-double-word lanes,
//    8 .. 256 octets); a write may carry fewer double-words than its size.
//    NREAD returns whole double-words. MAINTENANCE (ftype 8, hop count 0)
//    read / write of one 32-bit word (size 0b1000): 0x00 device identity CAR,
//    0x04 device information CAR, 0x08 assembly identity CAR, 0x0C assembly
//    information CAR, 0x10 processing element features CAR (inputs), 0x60
//    base device ID CSR ([23:16] 8-bit, [15:0] 16-bit ID), 0x68 host base
//    device ID lock CSR (set when 0xFFFF, cleared by writing the holder),
//    0x6C component tag CSR; other offsets read 0 and ignore writes.
//    DOORBELL (ftype 10) is reported on db_*. Responses (ftype 13, or 8 for
//    maintenance) go to the request's source ID with priority + 1 (at most
//    3) and status DONE (0) or ERROR (7): ERROR for an address outside the
//    memory, xamsbs != 0, a size that is reserved for the transaction, or an
//    unsupported ttype of ftype 2 / 5 / 8. NWRITE / SWRITE send no response.
//  - Doorbells out: ob_start sends a DOORBELL (ob_tt, ob_dest, ob_tid,
//    ob_info) when idle; the RESPONSE with that TID ends it: ob_done with
//    ob_status. ob_busy holds in between.
//  - Every received packet ends with rx_rep and rx_why: 0 executed,
//    1 CRC error, 2 not for this endpoint (dest ID, hop count), 3 malformed
//    (length, tt, structure), 4 unsupported ftype / ttype, 5 request error
//    (answered with ERROR), 6 dropped (busy), 7 unexpected response.
//  - Host port: host_rd gives host_rdata the clock after; a host write to
//    the octet the endpoint writes in the same clock is dropped.
//  - Not implemented: the physical layer (control symbols, ackID tracking,
//    retry), message passing, atomics, flow control, request timeouts,
//    34 / 50 / 66-bit addressing.
// ============================================================================
`timescale 1ns/1ps
module RAPIDIO_top (
  input  logic        clk,
  input  logic        rst_n,
  input  logic        rx_valid,
  input  logic [7:0]  rx_data,
  input  logic        rx_last,
  output logic        tx_valid,
  output logic [7:0]  tx_data,
  output logic        tx_last,
  input  logic [31:0] cfg_dev_id_car,
  input  logic [31:0] cfg_dev_info_car,
  input  logic [31:0] cfg_asm_id_car,
  input  logic [31:0] cfg_asm_info_car,
  input  logic [31:0] cfg_pe_feat_car,
  input  logic [23:0] cfg_base_id,         // {8-bit ID, 16-bit ID}
  input  logic        id_load,             // base device ID CSR <= cfg_base_id
  output logic [23:0] base_id,             // base device ID CSR [23:0]
  input  logic        host_rd,
  input  logic        host_wr,
  input  logic [9:0]  host_addr,
  input  logic [7:0]  host_wdata,
  output logic [7:0]  host_rdata,
  input  logic        ob_start,
  input  logic        ob_tt,
  input  logic [15:0] ob_dest,
  input  logic [7:0]  ob_tid,
  input  logic [15:0] ob_info,
  output logic        ob_busy,
  output logic        ob_done,
  output logic [3:0]  ob_status,
  output logic        db_valid,
  output logic [15:0] db_src,
  output logic [7:0]  db_tid,
  output logic [15:0] db_info,
  output logic        rx_rep,
  output logic [2:0]  rx_why,
  output logic [3:0]  rx_ftype,
  output logic        busy
);
  // ---------------- CRC-16 ----------------
  function automatic logic [15:0] crc8(input logic [15:0] c, input logic [7:0] d);
    logic [15:0] x;
    x = c;
    for (int i = 7; i >= 0; i--) x = {x[14:0], 1'b0} ^ ((x[15] ^ d[i]) ? 16'h1021 : 16'h0000);
    crc8 = x;
  endfunction
  // size table: {ok, octets (9 bits), first lane (3 bits)} for rdsize / wrsize, wdptr
  function automatic logic [12:0] sz(input logic [3:0] s, input logic w, input logic wr);
    logic [8:0] n;
    logic [2:0] l;
    logic       ok;
    ok = 1'b1; n = 9'd0; l = 3'd0;
    case (s)
      4'd0, 4'd1, 4'd2, 4'd3: begin n = 9'd1; l = {w, s[1:0]}; end
      4'd4: begin n = 9'd2; l = {w, 2'd0}; end
      4'd5: begin n = 9'd3; l = w ? 3'd5 : 3'd0; end
      4'd6: begin n = 9'd2; l = {w, 2'd2}; end
      4'd7: begin n = 9'd5; l = w ? 3'd3 : 3'd0; end
      4'd8: begin n = 9'd4; l = {w, 2'd0}; end
      4'd9: begin n = 9'd6; l = w ? 3'd2 : 3'd0; end
      4'd10: begin n = 9'd7; l = w ? 3'd1 : 3'd0; end
      4'd11: n = w ? 9'd16 : 9'd8;
      4'd12: n = w ? 9'd64 : 9'd32;
      4'd13: begin n = w ? 9'd128 : 9'd96; ok = w || !wr; end
      4'd14: begin n = w ? 9'd192 : 9'd160; ok = !wr; end
      default: begin n = w ? 9'd256 : 9'd224; ok = w || !wr; end
    endcase
    sz = {ok, n, l};
  endfunction

  // ---------------- memory ----------------
  logic [7:0] mem [0:1023];
  logic       e_we;
  logic [9:0] e_wa, e_ra;
  logic [7:0] e_wd;
  wire  [7:0] e_rd = mem[e_ra];
  wire        h_we = host_wr && !(e_we && e_wa == host_addr);
  always_ff @(posedge clk) begin
    if (e_we) mem[e_wa] <= e_wd;
    if (h_we) mem[host_addr] <= host_wdata;
  end
  always_ff @(posedge clk or negedge rst_n)
    if (!rst_n) host_rdata <= '0;
    else if (host_rd) host_rdata <= mem[host_addr];

  // ---------------- receive buffer ----------------
  logic [7:0]  rb [0:511];
  logic [7:0]  hd [0:15];                  // the first 16 octets
  logic [8:0]  ri;                         // octets received, held at 511 (a longer packet is malformed)
  logic [15:0] rc, rc1, rc2;               // CRC after all / all but 1 / all but 2 octets
  logic        z82;                        // CRC residue 0 after octet 82
  logic [7:0]  lb0, lb1;                   // last two octets
  logic [8:0]  b_ra;                       // buffer read address
  wire  [7:0]  b_rd = rb[b_ra];

  typedef enum logic [2:0] {E_IDLE, E_RX, E_CHK, E_WR, E_TX} es_t;
  es_t         es;
  logic        rx_skip;                    // dropping the rest of a packet that came while busy
  logic        drop_rep;                   // report the dropped packet next clock (E_CHK may report now)
  wire         take = rx_valid && !rx_skip && (es == E_IDLE || es == E_RX);
  always_ff @(posedge clk) if (take) rb[es == E_IDLE ? 9'd0 : ri] <= rx_data;

  // ---------------- decode (from hd, at E_CHK) ----------------
  wire  [3:0]  ftype = hd[1][3:0];
  wire  [1:0]  tt    = hd[1][5:4];
  wire  [1:0]  prio  = hd[1][7:6];
  wire  [15:0] dst   = tt[0] ? {hd[2], hd[3]} : {8'd0, hd[2]};
  wire  [15:0] srcid = tt[0] ? {hd[4], hd[5]} : {8'd0, hd[3]};
  wire  [3:0]  o     = tt[0] ? 4'd6 : 4'd4;          // logical header
  wire  [7:0]  l0 = hd[o], l1 = hd[o + 4'd1], l2 = hd[o + 4'd2], l3 = hd[o + 4'd3],
               l4 = hd[o + 4'd4], l5 = hd[o + 4'd5];
  wire  [3:0]  ttype = l0[7:4];
  wire  [3:0]  size  = l0[3:0];
  // logical header length
  logic [3:0]  lh;
  always_comb
    case (ftype)
      4'd2, 4'd5, 4'd8: lh = 4'd6;
      4'd6, 4'd10:      lh = 4'd4;
      default:          lh = 4'd2;
    endcase
  wire  [8:0]  hl = {5'd0, o} + {5'd0, lh};
  // content length for pad p = 0 / 2: total less the CRCs (early CRC when content > 80)
  wire  [8:0]  t0 = ri, t2 = ri - 9'd2;
  wire  [8:0]  c0 = t0 > 9'd84 ? t0 - 9'd4 : t0 - 9'd2;
  wire  [8:0]  c2 = t2 > 9'd84 ? t2 - 9'd4 : t2 - 9'd2;
  wire         len_ok0 = t0 >= 9'd4 && t0 != 9'd84;
  wire         len_ok2 = t2 >= 9'd4 && t2 != 9'd84;
  // structure: payload length for this ftype / ttype
  function automatic logic st_ok(input logic [3:0] ft, input logic [3:0] tty, input logic [8:0] c,
                                 input logic [8:0] h);
    logic [8:0] pl;
    pl = c - h;
    if (c < h) st_ok = 1'b0;
    else case (ft)
      4'd2, 4'd10: st_ok = pl == 9'd0;
      4'd5, 4'd6:  st_ok = pl != 9'd0 && pl[2:0] == 3'd0 && pl <= 9'd256;
      4'd8:        st_ok = (tty == 4'd1 || tty == 4'd2) ? pl == 9'd8 : pl == 9'd0;
      4'd13:       st_ok = tty == 4'd8 ? (pl != 9'd0 && pl[2:0] == 3'd0 && pl <= 9'd256) : pl == 9'd0;
      default:     st_ok = 1'b1;
    endcase
  endfunction
  wire         crc0 = rc == 16'd0 && (c0 <= 9'd80 || z82);
  wire         crc2 = rc2 == 16'd0 && lb0 == 8'd0 && lb1 == 8'd0 && (c2 <= 9'd80 || z82);
  wire         s0 = len_ok0 && st_ok(ftype, ttype, c0, hl);
  wire         s2 = len_ok2 && st_ok(ftype, ttype, c2, hl);
  wire         use0 = crc0 && s0;
  wire  [8:0]  cl = use0 ? c0 : c2;                    // content length
  wire  [8:0]  pl = cl - hl;                           // payload octets
  wire         crc_any = crc0 || crc2;
  wire         str_ok = (crc0 && s0) || (crc2 && s2);
  wire  [15:0] my_id = tt[0] ? base_id[15:0] : {8'd0, base_id[23:16]};
  // memory requests
  wire  [31:0] dw    = {l2, l3, l4, l5};                // 29-bit double-word address, wdptr, xamsbs
  wire  [31:0] sw_a  = {l0, l1, l2, l3};                // SWRITE: no ttype / size, [2] reserved
  wire  [12:0] szr   = sz(size, dw[2], ftype != 4'd2);
  wire  [8:0]  sz_n  = szr[11:3];
  wire  [2:0]  sz_l  = szr[2:0];
  wire         sub   = size <= 4'd10;
  wire  [31:0] a_dw  = {dw[31:3], 3'd0};
  // octets the request touches: reads whole double-words; writes the lanes or the payload
  wire  [31:0] a_beg = (ftype == 4'd2) ? a_dw : (ftype == 4'd6) ? {sw_a[31:3], 3'd0} :
                       (sub ? a_dw + {29'd0, sz_l} : a_dw);
  wire  [8:0]  a_n   = (ftype == 4'd2) ? (sub ? 9'd8 : sz_n) : (ftype == 4'd6 || !sub) ? pl : sz_n;
  wire         a_in  = (ftype == 4'd6 ? sw_a[1:0] == 2'd0 : dw[1:0] == 2'd0) &&
                       {1'b0, a_beg} + {24'd0, a_n} <= 33'd1024;
  wire         mreq  = (ftype == 4'd2 && ttype == 4'd4) || (ftype == 4'd5 && (ttype == 4'd4 || ttype == 4'd5)) ||
                       ftype == 4'd6;
  wire         m_err = !a_in || (ftype != 4'd6 && !szr[12]) || (ftype == 4'd5 && !sub && pl > sz_n) ||
                       (ftype == 4'd5 && sub && pl != 9'd8);
  // maintenance
  wire  [23:0] mo    = {l3, l4, l5[7:3], 3'd0} | {21'd0, l5[2], 2'd0};   // byte offset {offset, wdptr, 00}
  wire         mt_ok = (ttype == 4'd0 || ttype == 4'd1) && size == 4'd8;

  // ---------------- CSRs ----------------
  logic [15:0] lock;
  logic [31:0] tag;
  logic [31:0] csr_v;                  // the CSR at the maintenance offset
  always_comb
    case (mo)
      24'h00: csr_v = cfg_dev_id_car;
      24'h04: csr_v = cfg_dev_info_car;
      24'h08: csr_v = cfg_asm_id_car;
      24'h0C: csr_v = cfg_asm_info_car;
      24'h10: csr_v = cfg_pe_feat_car;
      24'h60: csr_v = {8'd0, base_id};
      24'h68: csr_v = {16'd0, lock};
      24'h6C: csr_v = tag;
      default: csr_v = 32'd0;
    endcase

  // ---------------- engine ----------------
  // transmit: header octets th[], payload from memory (tp_mem) or the 8-octet tpw
  logic [7:0]  th [0:11];
  logic [3:0]  th_n;
  logic [8:0]  tp_n;                       // payload octets
  logic        tp_mem;
  logic [9:0]  tp_a;
  logic [63:0] tpw;
  logic [8:0]  tk;                         // content octets sent
  logic [8:0]  tn;                         // octets sent
  logic [1:0]  tph;                        // 0 content, 1 early CRC, 2 final CRC, 3 pad
  logic        tsec;                       // second octet of a CRC / pad
  logic [15:0] tc;
  // write: payload octets from the buffer
  logic [8:0]  w_src, w_n, w_i;
  logic [9:0]  w_dst;
  logic        w_resp;                     // a response follows the write
  logic        w_early;                    // the packet has an early CRC
  logic        ob_tt_q;                    // our doorbell: tt, destination, TID
  logic [15:0] ob_dest_q;
  logic [7:0]  ob_tid_q;

  wire  [8:0]  tcl = {5'd0, th_n} + tp_n;               // content length to send
  wire  [7:0]  t_cont = tk < {5'd0, th_n} ? th[tk[3:0]] :
                        tp_mem ? e_rd : tpw[8 * (9'd7 - (tk - {5'd0, th_n})) +: 8];
  always_comb begin
    e_ra = tp_a + 10'(tk - {5'd0, th_n});
    b_ra = w_src + w_i;
    if (w_early && b_ra >= 9'd80) b_ra = b_ra + 9'd2;          // skip the early CRC
    e_we = es == E_WR; e_wa = w_dst + 10'(w_i); e_wd = b_rd;
  end
  // the octet on tx this clock
  always_comb begin
    tx_valid = es == E_TX;
    tx_data = 8'd0; tx_last = 1'b0;
    if (es == E_TX)
      case (tph)
        2'd0: tx_data = t_cont;
        2'd1, 2'd2: tx_data = tsec ? tc[7:0] : tc[15:8];
        default: tx_data = 8'd0;
      endcase
    tx_last = es == E_TX && tsec && ((tph == 2'd2 && tn[1:0] == 2'd3) || tph == 2'd3);
  end
  assign busy = es != E_IDLE && es != E_RX;

  // response header: ftype 13 (or 8), to the request's source
  task automatic resp(input logic [3:0] ft, input logic [3:0] tty, input logic [3:0] stat);
    th[0] <= 8'd0;
    th[1] <= {prio == 2'd3 ? 2'd3 : prio + 2'd1, tt, ft};
    if (tt[0]) begin
      th[2] <= srcid[15:8]; th[3] <= srcid[7:0]; th[4] <= my_id[15:8]; th[5] <= my_id[7:0];
    end else begin
      th[2] <= srcid[7:0]; th[3] <= my_id[7:0];
    end
    th[o] <= {tty, stat}; th[o + 4'd1] <= l1;
    th[o + 4'd2] <= 8'hFF; th[o + 4'd3] <= 8'd0; th[o + 4'd4] <= 8'd0; th[o + 4'd5] <= 8'd0;
    th_n <= o + (ft == 4'd8 ? 4'd6 : 4'd2);
    tp_n <= '0; tp_mem <= 1'b0;
  endtask
  task automatic rep(input logic [2:0] w);
    rx_rep <= 1'b1; rx_why <= w; rx_ftype <= ftype;
  endtask

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      es <= E_IDLE; ri <= '0; rc <= '1; rc1 <= '1; rc2 <= '1; z82 <= 1'b0; lb0 <= '0; lb1 <= '0;
      for (int i = 0; i < 16; i++) hd[i] <= '0;
      for (int i = 0; i < 12; i++) th[i] <= '0;
      th_n <= '0; tp_n <= '0; tp_mem <= 1'b0; tp_a <= '0; tpw <= '0; tk <= '0; tn <= '0; tph <= '0; tsec <= 1'b0;
      tc <= '1; w_src <= '0; w_n <= '0; w_i <= '0; w_dst <= '0; w_resp <= 1'b0; w_early <= 1'b0; rx_skip <= 1'b0; drop_rep <= 1'b0;
      ob_tt_q <= 1'b0; ob_dest_q <= '0; ob_tid_q <= '0;
      base_id <= '0; lock <= 16'hFFFF; tag <= '0;
      ob_busy <= 1'b0; ob_done <= 1'b0; ob_status <= '0;
      db_valid <= 1'b0; db_src <= '0; db_tid <= '0; db_info <= '0;
      rx_rep <= 1'b0; rx_why <= '0; rx_ftype <= '0;
    end else begin
      rx_rep <= 1'b0; db_valid <= 1'b0; ob_done <= 1'b0;
      if (id_load) base_id <= cfg_base_id;
      // a packet arriving while busy is dropped (to its last octet); it is
      // reported a clock later, when E_CHK (entered only after an accepted
      // last octet) cannot report in the same clock
      drop_rep <= rx_valid && (busy || rx_skip) && rx_last;
      if (rx_valid && (busy || rx_skip)) rx_skip <= !rx_last;
      if (drop_rep) begin rx_rep <= 1'b1; rx_why <= 3'd6; rx_ftype <= 4'd0; end
      case (es)
        E_IDLE, E_RX: begin
          if (rx_valid && rx_skip) ;
          else if (es == E_IDLE && ob_start && !ob_busy && !rx_valid) begin
            // our doorbell
            th[0] <= 8'd0; th[1] <= {2'd0, 1'b0, ob_tt, 4'd10};
            if (ob_tt) begin
              th[2] <= ob_dest[15:8]; th[3] <= ob_dest[7:0]; th[4] <= base_id[15:8]; th[5] <= base_id[7:0];
              th[6] <= 8'd0; th[7] <= ob_tid; th[8] <= ob_info[15:8]; th[9] <= ob_info[7:0]; th_n <= 4'd10;
            end else begin
              th[2] <= ob_dest[7:0]; th[3] <= base_id[23:16];
              th[4] <= 8'd0; th[5] <= ob_tid; th[6] <= ob_info[15:8]; th[7] <= ob_info[7:0]; th_n <= 4'd8;
            end
            tp_n <= '0; tp_mem <= 1'b0; ob_busy <= 1'b1;
            ob_tt_q <= ob_tt; ob_dest_q <= ob_tt ? ob_dest : {8'd0, ob_dest[7:0]}; ob_tid_q <= ob_tid;
            tk <= '0; tn <= '0; tph <= '0; tsec <= 1'b0; tc <= '1; es <= E_TX;
          end else if (rx_valid) begin
            logic [8:0]  n;
            logic [15:0] c;
            n = es == E_IDLE ? 9'd0 : ri;
            c = crc8(es == E_IDLE ? 16'hFFFF : rc, n == 9'd0 ? {6'd0, rx_data[1:0]} : rx_data);
            if (n < 9'd16) hd[n[3:0]] <= rx_data;
            rc2 <= es == E_IDLE ? 16'hFFFF : rc1; rc1 <= es == E_IDLE ? 16'hFFFF : rc; rc <= c;
            if (n == 9'd81) z82 <= c == 16'd0;
            if (es == E_IDLE) z82 <= 1'b0;
            lb1 <= lb0; lb0 <= rx_data;
            if (n != 9'd511) ri <= n + 9'd1;
            es <= rx_last ? E_CHK : E_RX;
          end
        end
        E_CHK: begin
          es <= E_IDLE; tk <= '0; tn <= '0; tph <= '0; tsec <= 1'b0; tc <= '1;
          if (ri[1:0] != 2'd0 || tt[1]) rep(3'd3);             // ri 511: more than 511 octets
          else if (!crc_any) rep(3'd1);
          else if (!str_ok) rep(3'd3);
          else if (ftype == 4'd13) begin
            if (dst != my_id) rep(3'd2);
            else if (ob_busy && ttype == 4'd0 && tt[0] == ob_tt_q && l1 == ob_tid_q && srcid == ob_dest_q) begin
              rep(3'd0); ob_busy <= 1'b0; ob_done <= 1'b1; ob_status <= l0[3:0];
            end else rep(3'd7);
          end else if (dst != my_id || (ftype == 4'd8 && l2 != 8'd0)) rep(3'd2);
          else if (ftype == 4'd10) begin
            rep(3'd0);
            db_valid <= 1'b1; db_src <= srcid; db_tid <= l1; db_info <= {l2, l3};
            resp(4'd13, 4'd0, 4'd0); es <= E_TX;
          end else if (ftype == 4'd8) begin
            if (ttype == 4'd2 || ttype == 4'd3) rep(3'd7);
            else if (!mt_ok) begin rep(ttype >= 4'd4 ? 3'd4 : 3'd5); resp(4'd8, ttype == 4'd1 ? 4'd3 : 4'd2, 4'd7); es <= E_TX; end
            else if (ttype == 4'd0) begin
              rep(3'd0); resp(4'd8, 4'd2, 4'd0);
              tp_n <= 9'd8; tpw <= mo[2] ? {32'd0, csr_v} : {csr_v, 32'd0};
              es <= E_TX;
            end else begin
              // write: the word in the lane wdptr selects
              logic [31:0] v;
              v = mo[2] ? {rb[hl + 9'd4], rb[hl + 9'd5], rb[hl + 9'd6], rb[hl + 9'd7]}
                        : {rb[hl], rb[hl + 9'd1], rb[hl + 9'd2], rb[hl + 9'd3]};
              if (mo == 24'h60) base_id <= v[23:0];
              if (mo == 24'h68) begin
                if (lock == 16'hFFFF) lock <= v[15:0];
                else if (lock == v[15:0]) lock <= 16'hFFFF;
              end
              if (mo == 24'h6C) tag <= v;
              rep(3'd0); resp(4'd8, 4'd3, 4'd0); es <= E_TX;
            end
          end else if (!mreq) begin
            rep(3'd4);
            if (ftype == 4'd2 || ftype == 4'd5) begin resp(4'd13, 4'd0, 4'd7); es <= E_TX; end
          end else if (m_err) begin
            rep(3'd5);
            if (ftype == 4'd2 || (ftype == 4'd5 && ttype == 4'd5)) begin resp(4'd13, 4'd0, 4'd7); es <= E_TX; end
          end else if (ftype == 4'd2) begin
            rep(3'd0); resp(4'd13, 4'd8, 4'd0);
            tp_n <= a_n; tp_mem <= 1'b1; tp_a <= a_beg[9:0];
            es <= E_TX;
          end else begin
            // NWRITE / NWRITE_R / SWRITE: copy the payload (or its lanes)
            rep(3'd0);
            w_src <= hl + ((ftype == 4'd5 && sub) ? {6'd0, sz_l} : 9'd0);
            w_n <= a_n; w_i <= '0; w_dst <= a_beg[9:0]; w_early <= cl > 9'd80;
            w_resp <= ftype == 4'd5 && ttype == 4'd5;
            resp(4'd13, 4'd0, 4'd0);                                // sent only when w_resp
            es <= E_WR;
          end
        end
        E_WR: begin
          w_i <= w_i + 9'd1;
          if (w_i + 9'd1 == w_n) es <= w_resp ? E_TX : E_IDLE;
        end
        E_TX: begin
          tn <= tn + 9'd1;
          tsec <= !tsec;
          case (tph)
            2'd0: begin
              tc <= crc8(tc, tk == 9'd0 ? {6'd0, t_cont[1:0]} : t_cont);
              tk <= tk + 9'd1;
              tsec <= 1'b0;
              if (tk + 9'd1 == tcl) tph <= 2'd2;
              else if (tk + 9'd1 == 9'd80) tph <= 2'd1;
            end
            2'd1: if (tsec) begin                                  // the early CRC continues the CRC
              tc <= crc8(crc8(tc, tc[15:8]), tc[7:0]);
              tph <= 2'd0;
            end
            2'd2: if (tsec) begin
              if (tn[1:0] == 2'd3) es <= E_IDLE;
              else tph <= 2'd3;
            end
            default: if (tsec) es <= E_IDLE;
          endcase
        end
        default: es <= E_IDLE;
      endcase
    end
  end
endmodule
