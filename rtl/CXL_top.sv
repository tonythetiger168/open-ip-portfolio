// SPDX-License-Identifier: Apache-2.0
// ============================================================================
// CXL_top v3.0: CXL Type 3 device (memory expander) with a 256-byte flit
// link layer, a CXL.io pass-through path and HDM-DB back-invalidation:
// CXL.mem M2S Req / RwD / BIRsp in, S2M NDR / DRS / BISnp out, device
// memory with a 2-bit meta state, poison, a range decoder and a snoop filter
// ----------------------------------------------------------------------------
//  - Link: rx_valid / rx_data (M2S, from the host; no back-pressure) and
//    tx_valid / tx_ready / tx_data (S2M), 8 bytes per beat, byte 0 in bits
//    7:0. A flit is 32 beats (256 bytes, beat 0 first):
//      bytes   0..1    flit header {SEQ[7:0], 6'b0, TYPE[1:0]}; TYPE NOP 0,
//                      CXL.io 1, CXL.cachemem 2 (3 reserved: the flit is
//                      dropped with ev_fmt, its credits too)
//      bytes   2..15   H slot: bytes 2..7 reserved, bytes 8..15 (beat 1)
//                      one header unit
//      bytes  16..239  G slots 1..14 (16 bytes each, beats 2..29), each two
//                      units of 8 bytes, or one data slot
//      bytes 240..241  CRD: credits returned {IO[3:0], CH2[3:0], CH1[3:0],
//                      CH0[3:0]} (M2S: credits for the device's NDR, DRS,
//                      BISnp and CXL.io flits; S2M: for its Req, RwD, BIRsp
//                      and CXL.io flits)
//      bytes 242..249  CRC-64 (polynomial 0x42F0E1EBA9EA3693, seed all
//                      ones, each beat bit 63 first, no final xor) of bytes
//                      0..241, CRC bit 7:0 in byte 242
//      bytes 250..255  FEC: sent as zero, not checked (the PHY's job)
//    SEQ counts the flits a side sends; a received SEQ other than the last
//    one plus 1 raises ev_seq (the flit is still taken, and the count
//    follows it). A flit with a bad CRC is dropped whole (ev_crc), a
//    partly received RwD message is abandoned and SEQ is taken as received.
//    There is no link-level retry.
//  - CXL.cachemem flits: units are 8 bytes, format code in bits 3:0. A
//    header unit carries one message or is empty (0); beat 0 bytes 2..7 are
//    reserved. Data: after a message with data, the next 4 G slots (8
//    units, line bytes 0..63 in order) carry its line; they may roll over
//    into the next CXL.cachemem flit, skipping the H slot, which stays a
//    header unit.
//      M2S Req   1: {16'b0, ADDR, TAG, 1'b0, SNP[2:0], MV, MF, OP, 4'd1}
//      M2S RwD   2: {16'b0, ADDR, TAG, POISON, SNP, MV, MF, OP, 4'd2}, in
//                   the first unit of a G slot; the second unit is the
//                   64-bit byte enable (MemWrPtl). Every RwD opcode but
//                   BIConflict (4) is followed by its 4 data slots. An RwD
//                   header in any other unit is ignored (ev_fmt).
//      M2S BIRsp 3: {44'b0, BITAG[11:0], OP, 4'd3}
//      S2M NDR   4: {32'b0, TAG, 4'b0, DEVLOAD, MV, 1'b0, OP[2:0], 4'd4}
//      S2M DRS   5: {32'b0, TAG, 3'b0, POISON, DEVLOAD, MV, 4'b0, 4'd5}
//      S2M BISnp 6: {16'b0, ADDR, 12'b0, BITAG, OP, 4'd6}
//    A received unit with code 4..15 is ignored (ev_fmt). A message that
//    finds no buffer backed by a credit the host holds (every buffer in use
//    or owed back as a credit: the host sent it without a credit) is
//    dropped (ev_ovf); the data units of a dropped RwD are skipped.
//    The device sends a CXL.cachemem flit when a message or a line's data
//    is waiting (with credit), a CXL.io flit when the CXL.io side offers one
//    (with credit; the two alternate), and a NOP flit when only credits are
//    owed. In a CXL.cachemem flit each header unit takes one message: the
//    response (NDR or DRS, in the order the core made them) and BISnp
//    alternate when both wait. A DRS message's data starts in the next G
//    slot; the unit after a DRS header in the same slot can take an NDR or
//    BISnp.
//    Credits: the device's buffers (RQD Req, WQD RwD, 1 BIRsp, IOD CXL.io
//    flits) are returned in every flit as they free, starting with all of
//    them after reset. Credits from the host are counted per channel (up to
//    255) and each message (each CXL.io flit) sent takes one.
//  - CXL.io: io_rx_* delivers the payload of each CXL.io flit received
//    (bytes 2..239) as 30 beats of 8 bytes, io_rx_last on the 30th, which
//    carries bytes 234..239 in its bits 47:0 (bits 63:48 zero); io_tx_*
//    takes 30 beats per flit the same way (bits 63:48 of the 30th are
//    ignored). The payload (the TLPs, their framing and flow control) is
//    not looked at: the CXL.io transaction layer is outside. A CXL.io flit
//    that finds no buffer backed by a credit is dropped (ev_ovf). A CXL.io flit being sent
//    waits for each beat of io_tx (tx_valid low meanwhile).
//  - Address: ADDR is a host line address (byte address bits 21:6). The HDM
//    decoder maps hdm_base .. hdm_base + LINES - 1 to the device's LINES
//    lines (DPA = address - hdm_base, modulo 2^16); any other address is out
//    of range (ev_range): a read returns zeros with poison, a write is
//    dropped, a completion is still sent.
//  - M2S Req opcodes: MemInv 0, MemRd 1, MemRdData 2, MemSpecRd 8,
//    MemInvNT 9, MemClnEvct 10. MemRdFwd 3, MemWrFwd 4 and the reserved
//    codes are dropped with ev_opcode, no response.
//    MemRd / MemRdData: S2M DRS with the line, its poison bit and meta
//    state. MemInv / MemInvNT / MemClnEvct: S2M NDR; for MemInv and
//    MemInvNT with MetaField Meta0-State the opcode follows MetaValue
//    (Cmp-S 1 for Shared, Cmp-E 2 for Any, Cmp 0 otherwise), else Cmp.
//    MemSpecRd: no response (a prefetch hint).
//  - M2S RwD opcodes: MemWr 1 (the whole line; the poison bit replaces the
//    line's), MemWrPtl 2 (bytes with their enable set; poison is or-ed in):
//    S2M NDR Cmp. BIConflict 4 (HDM-DB, bi_en): S2M NDR BIConflictAck 4.
//    Others (BIConflict without bi_en, reserved) are dropped (ev_opcode).
//  - Meta state (per line: Invalid 00, Any 10, Shared 11; reset Invalid):
//    MetaField Meta0-State (00) sets it to MetaValue for MemRd, MemInv,
//    MemInvNT, MemClnEvct, MemWr and MemWrPtl; No-Op (11) leaves it.
//    Responses carry the state before the request. A reserved MetaField
//    (01, 10) or SnpType (1xx) is taken as No-Op with ev_proto.
//  - HDM-DB (bi_en): the meta state of a line is the host's coherence
//    state, and the snoop filter holds at most SFE lines that are not
//    Invalid (sf_cnt counts them). A Req that would take a line from Invalid
//    to Any or Shared with the filter full waits at the head of the Req
//    FIFO while the device evicts a victim (the next line not Invalid,
//    round robin): S2M BISnpInv, then the BIRsp. An RwD that would do so
//    with the filter full leaves the line Invalid. bi_valid / bi_ready /
//    bi_op (BISnpCur 0, BISnpData 1, BISnpInv 2; 3 is taken as 2) /
//    bi_line (DPA) is the device's own back-invalidation request: for a
//    line already Invalid it completes at once, else a BISnp is sent and
//    the BIRsp waited for; bi_done pulses with bi_state, the line's new
//    meta state. One BISnp is outstanding at a time; BITAG steps through a
//    12-bit LFSR (x^12 + x^11 + x^10 + x^4 + 1) from 1.
//    BIRsp opcodes: BIRspI 0 (-> Invalid), BIRspS 1 (-> Shared), BIRspE 2
//    (-> Any); allowed: BISnpInv I; BISnpData I, S; BISnpCur I, S, E. An
//    illegal one is taken as BIRspI (ev_proto); a BIRsp with another BITAG
//    or none outstanding is dropped (ev_proto). A Req to the line of the
//    outstanding BISnp waits at the head of the FIFO; RwD messages do not
//    (the host's write-back). Without bi_en, bi_ready is low, nothing is
//    evicted and a BIRsp is dropped (ev_proto).
//  - Order: Req messages wait in a FIFO of RQD entries, complete RwD
//    messages in a ring of WQD. A BIRsp is served first; else the Req and
//    the RwD at the heads are served by round robin when both can go, one
//    per clock, when the response they need can be held (one NDR, one DRS).
//    DevLoad in each response grades the requests left waiting in the FIFO
//    once it is served: none Light (00), 1 Optimal (01), RQD - 1 or more
//    Severe (11), else Moderate (10). Device memory is zero after reset.
//  Not implemented: link-level retry, FEC, the 68-byte flit mode, ARB/MUX
//  link states (L1, ALMP), CXL.cache, HDM-D, the Blk BISnp variants,
//  several messages per data-free slot beyond two units, IDE, interleaving
//  and more than one HDM decoder, the extended meta field, traffic classes,
//  QoS telemetry beyond DevLoad, RAS logging. Field layouts and encodings
//  are ours, modelled on CXL 3.x as we read it; they have not been checked
//  against a compliant host.
// ============================================================================
module CXL_top #(
  parameter int LINES = 16,             // device memory, cache lines (power of 2, at most 256)
  parameter int RQD   = 4,              // Req FIFO entries (power of 2, 4 to 8)
  parameter int WQD   = 2,              // RwD buffers (power of 2, 2 to 8)
  parameter int SFE   = 4,              // snoop filter entries (1 to LINES)
  parameter int IOD   = 2               // CXL.io receive flit buffers (power of 2, 2 to 8)
)(
  input  logic        clk,
  input  logic        rst_n,
  input  logic [15:0] hdm_base,         // first host line address of the device
  input  logic        bi_en,            // HDM-DB: snoop filter and back-invalidation
  // link
  input  logic        rx_valid,
  input  logic [63:0] rx_data,
  output logic        tx_valid,
  input  logic        tx_ready,
  output logic [63:0] tx_data,
  // CXL.io pass-through
  output logic        io_rx_valid,
  input  logic        io_rx_ready,
  output logic [63:0] io_rx_data,
  output logic        io_rx_last,
  input  logic        io_tx_valid,
  output logic        io_tx_ready,
  input  logic [63:0] io_tx_data,
  // device back-invalidation request
  input  logic        bi_valid,
  output logic        bi_ready,
  input  logic [1:0]  bi_op,
  input  logic [$clog2(LINES)-1:0] bi_line,
  output logic        bi_done,
  output logic [1:0]  bi_state,
  output logic [$clog2(LINES):0] sf_cnt, // lines not Invalid
  // events
  output logic        ev_range,         // address outside the HDM range
  output logic        ev_opcode,        // unsupported opcode: dropped
  output logic        ev_proto,         // reserved MetaField or SnpType, a bad BIRsp
  output logic        ev_poison,        // a read of a poisoned line
  output logic        ev_crc,           // a flit with a bad CRC: dropped
  output logic        ev_seq,           // a flit out of sequence
  output logic        ev_fmt,           // a reserved flit type or unit code, a misplaced RwD
  output logic        ev_ovf            // a message or CXL.io flit without a free buffer: dropped
);
  localparam int DW = $clog2(LINES);
  localparam int QW = $clog2(RQD);
  localparam int WW = $clog2(WQD);
  localparam int IW = $clog2(IOD);
  localparam int IA = $clog2(IOD * 30);
  localparam int PQ = $clog2(RQD + 1);
  localparam int PW = $clog2(WQD + 1);
  localparam int PI = $clog2(IOD + 1);
  localparam logic [63:0] POLY = 64'h42F0E1EBA9EA3693;

  function automatic logic [63:0] crc64(input logic [63:0] c, input logic [63:0] d);
    logic [63:0] r;
    r = c;
    for (int i = 63; i >= 0; i--) r = {r[62:0], 1'b0} ^ ({64{r[63] ^ d[i]}} & POLY);
    crc64 = r;
  endfunction
  function automatic logic [63:0] crc16(input logic [63:0] c, input logic [15:0] d);
    logic [63:0] r;
    r = c;
    for (int i = 15; i >= 0; i--) r = {r[62:0], 1'b0} ^ ({64{r[63] ^ d[i]}} & POLY);
    crc16 = r;
  endfunction
  function automatic logic [7:0] sat(input logic [7:0] c, input logic [3:0] add, input logic use1);
    logic [8:0] s;
    s = {1'b0, c} + {5'b0, add};
    sat = s[8] ? 8'hFF - 8'(use1) : s[7:0] - 8'(use1);
  endfunction

  // ---------------- device memory ----------------
  logic [63:0]   mem [0:LINES*8-1];
  logic [1:0]    meta [0:LINES-1];
  logic          pois [0:LINES-1];

  // ---------------- link receive ----------------
  logic [63:0]   rb [0:31];                    // the flit being received
  logic [4:0]    rj;                           // next beat
  logic [63:0]   r_crc;
  logic [1:0]    r_type;
  logic [7:0]    r_seq, x_seq;
  logic [15:0]   r_crd;
  logic [47:0]   r_c0;                         // received CRC bits 47:0
  wire  [63:0]   r_fin = crc16(r_crc, r_crd);
  wire           r_end = rx_valid && rj == 5'd31;
  wire           r_good = r_fin == {rx_data[15:0], r_c0};
  // unpacker: one unit per clock, from the clock after the flit's last beat
  logic          u_act, u_io, u_be, u_bic, u_keep;
  logic [4:0]    uj;
  logic [3:0]    ro_cnt;                       // data units still owed to an RwD
  logic          ro_keep;                      // ... and they are kept
  wire  [63:0]   uw = rb[uj];
  wire           u_data = !u_io && uj >= 5'd2 && ro_cnt != 4'd0;

  // ---------------- Req FIFO ----------------
  logic [40:0]   rq [0:RQD-1];                 // {opcode, meta field, meta value, SnpType[2], tag, addr}
  logic [QW:0]   rqw, rqr;
  wire  [QW:0]   r_cnt = rqw - rqr;
  wire  [40:0]   r_h = rq[rqr[QW-1:0]];
  wire  [3:0]    r_op = r_h[40:37];
  wire           r_valid = rqw != rqr;
  // what the head needs: 1 NDR, 2 DRS, 0 nothing
  wire  [1:0]    r_need = r_op == 4'd1 || r_op == 4'd2 ? 2'd2 : r_op == 4'd0 || r_op == 4'd9 || r_op == 4'd10 ? 2'd1 : 2'd0;
  wire  [1:0]    r_mf = r_h[36:35] == 2'b01 || r_h[36:35] == 2'b10 || r_h[32] ? 2'b11 : r_h[36:35];
  wire  [15:0]   r_off = r_h[15:0] - hdm_base;
  wire           r_in = r_off < 16'(LINES);
  wire  [DW-1:0] r_dpa = DW'(r_off);
  // the head would take its line from Invalid to Any or Shared
  wire           r_alloc = r_in && r_mf == 2'b00 && r_h[34:33] != 2'b00 && meta[r_dpa] == 2'b00 &&
                           (r_op == 4'd0 || r_op == 4'd1 || r_op == 4'd9 || r_op == 4'd10);

  // ---------------- RwD ring ----------------
  logic [3:0]    wq_op [0:WQD-1];
  logic [5:0]    wq_hd [0:WQD-1];              // {meta field, meta value, SnpType[2], poison}
  logic [15:0]   wq_tag [0:WQD-1], wq_addr [0:WQD-1];
  logic [63:0]   wq_be [0:WQD-1];
  logic [63:0]   wq_d [0:WQD*8-1];
  logic [WW:0]   wqw, wqr;
  wire  [WW-1:0] wh = wqr[WW-1:0];
  wire           w_valid = wqw != wqr;
  wire  [3:0]    w_op = wq_op[wh];
  wire           w_ok = w_op == 4'd1 || w_op == 4'd2;
  wire           w_bic = w_op == 4'd4 && bi_en;

  // ---------------- BIRsp buffer ----------------
  logic          bir_v;
  logic [3:0]    bir_op;
  logic [11:0]   bir_tag;

  // ---------------- CXL.io receive buffers ----------------
  logic [63:0]   iom [0:IOD*30-1];
  logic [IW:0]   iwf, irf;                     // flits written, read
  logic [4:0]    irw;                          // beat of the flit being read
  wire  [IW-1:0] irx = irf[IW-1:0];
  wire  [IW-1:0] iwx = iwf[IW-1:0];
  assign io_rx_valid = iwf != irf;
  assign io_rx_data  = iom[IA'(32'(irx) * 30 + 32'(irw))];
  assign io_rx_last  = irw == 5'd29;
  wire           io_pop = io_rx_valid && io_rx_ready && io_rx_last;

  // ---------------- back-invalidation engine ----------------
  typedef enum logic [1:0] {BI_IDLE, BI_SEND, BI_WAIT} bi_t;
  bi_t           bi_st;
  logic [DW-1:0] bi_ln, vp;
  logic [1:0]    bi_sop;                       // BISnpCur 0, BISnpData 1, BISnpInv 2
  logic          bi_ext;
  logic [11:0]   bi_tag;                       // LFSR x^12 + x^11 + x^10 + x^4 + 1, from 1
  wire  [11:0]   bi_next = {bi_tag[10:0], bi_tag[11] ^ bi_tag[10] ^ bi_tag[9] ^ bi_tag[3]};
  wire           r_blk = bi_st != BI_IDLE && r_in && r_dpa == bi_ln;
  wire           r_full = bi_en && r_alloc && sf_cnt >= (DW+1)'(SFE);
  wire           evict = r_valid && r_full && bi_st == BI_IDLE;
  assign bi_ready = bi_en && bi_st == BI_IDLE && !evict;
  logic [DW-1:0] victim;
  always_comb begin
    victim = vp;
    for (int k = LINES - 1; k >= 0; k--)
      if (meta[DW'(vp + DW'(k))] != 2'b00) victim = DW'(vp + DW'(k));
  end

  // ---------------- responses (to the packer) ----------------
  logic          ndr_v, drs_v, drs_hs, d_first;  // d_first: the DRS was made before the NDR (read only
                                               // while the DRS header is still to send)
  logic [2:0]    ndr_op;
  logic [15:0]   ndr_tag, drs_tag;
  logic [1:0]    ndr_mv, ndr_dl, drs_mv, drs_dl;
  logic          drs_po;
  logic [63:0]   drb [0:7];
  logic [2:0]    d_wc;                         // data units of the DRS line sent

  // ---------------- link transmit ----------------
  logic          t_act, t_io, t_nop, t_lio, t_rr;
  logic [4:0]    t_j;                          // next beat
  logic [63:0]   t_crc;
  logic [7:0]    t_seq;
  logic [15:0]   t_c48;
  logic [15:0]   t_io16;
  logic [7:0]    c_ndr, c_drs, c_bis, c_io;    // credits from the host
  logic [PQ-1:0] p_req;                        // credits owed to the host
  logic [PW-1:0] p_rwd;
  logic          p_bir;
  logic [PI-1:0] p_io;
  // no RwD buffer backed by a credit the host holds: in use or owed
  wire           w_full = 32'((WW+1)'(wqw - wqr)) + 32'(p_rwd) >= WQD;
  // the CRD field: the credits owed
  function automatic logic [15:0] crd(input logic [PI-1:0] i, input logic b, input logic [PW-1:0] w,
                                      input logic [PQ-1:0] q);
    crd = {4'(i), 4'(b), 4'(w), 4'(q)};
  endfunction
  wire           adv = !tx_valid || tx_ready;
  wire           n_el = ndr_v && !(drs_v && !drs_hs && d_first) && c_ndr != 8'd0;
  wire           d_el = drs_v && !drs_hs && !(ndr_v && !d_first) && c_drs != 8'd0;
  wire           b_el = bi_st == BI_SEND && c_bis != 8'd0;
  wire           d_owe = drs_v && drs_hs;
  wire           cm_want = n_el || d_el || b_el || d_owe;
  wire           io_want = io_tx_valid && c_io != 8'd0;
  wire           crd_want = p_req != '0 || p_rwd != '0 || p_bir || p_io != '0;
  wire           t_start = !t_act && adv && (cm_want || io_want || crd_want);
  wire           s_io = io_want && (!cm_want || !t_lio);
  wire           s_nop = !cm_want && !io_want;
  // this clock's beat, when one is made
  wire           t_gen = t_start || t_act && adv && !(t_io && t_j <= 5'd29 && !io_tx_valid);
  wire  [4:0]    t_b = t_start ? 5'd0 : t_j;
  wire           t_cm = t_act && !t_io && !t_nop;
  wire           t_unit = t_gen && t_cm && t_b >= 5'd1 && t_b <= 5'd29;
  wire           t_dat = t_unit && t_b >= 5'd2 && d_owe && (d_wc != 3'd0 || !t_b[0]);
  wire           t_hdr = t_unit && !t_dat;
  wire           p_resp = t_hdr && (n_el || d_el) && (!b_el || !t_rr);
  wire           p_bis = t_hdr && b_el && !p_resp;
  wire           p_ndr = p_resp && n_el;
  wire           p_drs = p_resp && d_el;
  wire           t_last = t_dat && d_wc == 3'd7;
  assign io_tx_ready = t_gen && (t_start ? s_io : t_io && t_j <= 5'd29);
  wire  [63:0]   t_c30 = crc16(crc64(t_crc, tx_data), crd(p_io, p_bir, p_rwd, p_req));
  logic [63:0]   t_beat;
  always_comb begin
    if (t_start)
      t_beat = {s_io ? io_tx_data[47:0] : 48'd0, t_seq, 6'd0, s_io ? 2'd1 : s_nop ? 2'd0 : 2'd2};
    else if (t_b == 5'd30)
      t_beat = {t_c30[47:0], crd(p_io, p_bir, p_rwd, p_req)};
    else if (t_b == 5'd31)
      t_beat = {48'd0, t_c48};
    else if (t_io)
      t_beat = {io_tx_data[47:0], t_io16};
    else if (t_dat)
      t_beat = drb[d_wc];
    else if (p_ndr)
      t_beat = {32'd0, ndr_tag, 4'd0, ndr_dl, ndr_mv, 1'b0, ndr_op, 4'd4};
    else if (p_drs)
      t_beat = {32'd0, drs_tag, 3'd0, drs_po, drs_dl, drs_mv, 4'd0, 4'd5};
    else if (p_bis)
      t_beat = {16'd0, hdm_base + 16'(bi_ln), 12'd0, bi_tag, 2'b00, bi_sop, 4'd6};
    else
      t_beat = 64'd0;
  end
  wire           n_free = !ndr_v || p_ndr;
  wire           d_free = !drs_v || t_last;

  // ---------------- arbitration ----------------
  logic          arb;                          // 1: RwD first on a tie
  wire           c_req = r_valid && !r_blk && !r_full &&
                         (r_need == 2'd0 || r_need == 2'd1 && n_free || r_need == 2'd2 && d_free);
  wire           c_rwd = w_valid && (!(w_ok || w_bic) || n_free);
  wire           g_bir = bir_v;
  wire           g_rwd = !g_bir && c_rwd && (arb || !c_req);
  wire           g_req = !g_bir && c_req && !g_rwd;
  // DevLoad: the requests left waiting once this one is served
  wire  [QW:0]   r_left = r_cnt - (QW+1)'(g_req);
  wire  [1:0]    devload = r_left == '0 ? 2'b00 : r_left == (QW+1)'(1) ? 2'b01 :
                           r_left >= (QW+1)'(RQD - 1) ? 2'b11 : 2'b10;

  always_ff @(posedge clk or negedge rst_n)
    if (!rst_n) begin
      for (int i = 0; i < LINES * 8; i++) mem[i] <= '0;
      for (int i = 0; i < LINES; i++) begin meta[i] <= 2'b00; pois[i] <= 1'b0; end
      rj <= '0; r_crc <= '1; r_type <= '0; r_seq <= '0; x_seq <= '0; r_crd <= '0; r_c0 <= '0;
      u_act <= 1'b0; u_io <= 1'b0; u_be <= 1'b0; u_bic <= 1'b0; u_keep <= 1'b0; uj <= '0;
      ro_cnt <= '0; ro_keep <= 1'b0;
      rqw <= '0; rqr <= '0; wqw <= '0; wqr <= '0; arb <= 1'b0;
      bir_v <= 1'b0; bir_op <= '0; bir_tag <= '0;
      iwf <= '0; irf <= '0; irw <= '0;
      bi_st <= BI_IDLE; bi_ln <= '0; vp <= '0; bi_sop <= '0; bi_ext <= 1'b0; bi_tag <= 12'd1;
      bi_done <= 1'b0; bi_state <= '0; sf_cnt <= '0;
      ndr_v <= 1'b0; drs_v <= 1'b0; drs_hs <= 1'b0; d_first <= 1'b0; ndr_op <= '0; ndr_tag <= '0; drs_tag <= '0;
      ndr_mv <= '0; ndr_dl <= '0; drs_mv <= '0; drs_dl <= '0; drs_po <= 1'b0; d_wc <= '0;
      t_act <= 1'b0; t_io <= 1'b0; t_nop <= 1'b0; t_lio <= 1'b0; t_rr <= 1'b0; t_j <= '0; t_crc <= '1;
      t_seq <= '0; t_c48 <= '0; t_io16 <= '0; tx_valid <= 1'b0; tx_data <= '0;
      c_ndr <= '0; c_drs <= '0; c_bis <= '0; c_io <= '0;
      p_req <= PQ'(RQD); p_rwd <= PW'(WQD); p_bir <= 1'b1; p_io <= PI'(IOD);
      {ev_range, ev_opcode, ev_proto, ev_poison, ev_crc, ev_seq, ev_fmt, ev_ovf} <= '0;
    end else begin : b_main
      logic [15:0]   off;
      logic          in, mwe;
      logic [DW-1:0] dpa, mwa;
      logic [1:0]    mwv, mf;
      logic [3:0]    a_ndr, a_drs, a_bis, a_io;
      {ev_range, ev_opcode, ev_proto, ev_poison, ev_crc, ev_seq, ev_fmt, ev_ovf} <= '0;
      bi_done <= 1'b0;
      mwe = 1'b0; mwa = '0; mwv = '0;
      {a_ndr, a_drs, a_bis, a_io} = '0;

      // ================= link receive =================
      if (rx_valid) begin
        rb[rj] <= rx_data;
        rj <= rj + 5'd1;
        if (rj == 5'd0) begin r_type <= rx_data[1:0]; r_seq <= rx_data[15:8]; end
        if (rj <= 5'd29) r_crc <= crc64(r_crc, rx_data);
        if (rj == 5'd30) begin r_crd <= rx_data[15:0]; r_c0 <= rx_data[63:16]; end
        if (r_end) begin
          r_crc <= '1;
          if (!r_good) begin
            ev_crc <= 1'b1;
            x_seq <= x_seq + 8'd1;
            ro_cnt <= '0;
          end else if (r_type == 2'd3) begin
            ev_fmt <= 1'b1;
            x_seq <= r_seq + 8'd1;
            if (r_seq != x_seq) ev_seq <= 1'b1;
          end else begin
            x_seq <= r_seq + 8'd1;
            if (r_seq != x_seq) ev_seq <= 1'b1;
            {a_io, a_bis, a_drs, a_ndr} = r_crd;
            if (r_type == 2'd2) begin u_act <= 1'b1; u_io <= 1'b0; uj <= 5'd1; end
            if (r_type == 2'd1) begin
              if (32'((IW+1)'(iwf - irf)) + 32'(p_io) >= IOD) ev_ovf <= 1'b1;
              else begin u_act <= 1'b1; u_io <= 1'b1; uj <= 5'd0; end
            end
          end
        end
      end

      // ================= unpacker =================
      if (u_act) begin
        uj <= uj + 5'd1;
        if (u_io) begin
          iom[IA'(32'(iwx) * 30 + 32'(uj))] <= uj == 5'd29 ? {16'd0, uw[63:16]} : {rb[uj + 5'd1][15:0], uw[63:16]};
          if (uj == 5'd29) begin u_act <= 1'b0; iwf <= iwf + 1'b1; end
        end else begin
          if (uj == 5'd29) u_act <= 1'b0;
          if (u_data) begin
            if (ro_keep) wq_d[{wqw[WW-1:0], 3'(4'd8 - ro_cnt)}] <= uw;
            ro_cnt <= ro_cnt - 4'd1;
            if (ro_cnt == 4'd1 && ro_keep) wqw <= wqw + 1'b1;
          end else if (u_be) begin
            u_be <= 1'b0;
            if (u_keep) wq_be[wqw[WW-1:0]] <= uw;
            if (u_bic) begin
              if (u_keep) wqw <= wqw + 1'b1;
            end else begin
              ro_cnt <= 4'd8; ro_keep <= u_keep;
            end
          end else
            case (uw[3:0])
              4'd0: ;
              4'd1:
                if (32'(r_cnt) + 32'(p_req) >= RQD) ev_ovf <= 1'b1;
                else begin
                  rq[rqw[QW-1:0]] <= {uw[7:4], uw[9:8], uw[11:10], uw[14], uw[31:16], uw[47:32]};
                  rqw <= rqw + 1'b1;
                end
              4'd2:
                if (uj[0]) ev_fmt <= 1'b1;
                else begin
                  u_be <= 1'b1; u_bic <= uw[7:4] == 4'd4;
                  u_keep <= !w_full;
                  if (w_full) ev_ovf <= 1'b1;
                  else begin
                    wq_op[wqw[WW-1:0]] <= uw[7:4];
                    wq_hd[wqw[WW-1:0]] <= {uw[9:8], uw[11:10], uw[14], uw[15]};
                    wq_tag[wqw[WW-1:0]] <= uw[31:16]; wq_addr[wqw[WW-1:0]] <= uw[47:32];
                  end
                end
              4'd3:
                if (bir_v || p_bir) ev_ovf <= 1'b1;
                else begin bir_v <= 1'b1; bir_op <= uw[7:4]; bir_tag <= uw[19:8]; end
              default: ev_fmt <= 1'b1;
            endcase
        end
      end

      // ================= CXL.io receive buffers =================
      if (io_rx_valid && io_rx_ready) begin
        irw <= io_rx_last ? 5'd0 : irw + 5'd1;
        if (io_rx_last) irf <= irf + 1'b1;
      end

      // ================= link transmit =================
      if (adv && !t_gen) tx_valid <= 1'b0;
      if (t_gen) begin
        tx_valid <= 1'b1;
        tx_data <= t_beat;
        t_j <= t_b + 5'd1;
        if (t_start) begin
          t_act <= 1'b1; t_io <= s_io; t_nop <= s_nop; t_crc <= '1; t_seq <= t_seq + 8'd1;
          if (s_io) t_lio <= 1'b1;
          else if (!s_nop) t_lio <= 1'b0;
        end else if (t_b <= 5'd30) t_crc <= crc64(t_crc, tx_data);
        if (t_io || t_start && s_io) t_io16 <= io_tx_data[63:48];
        if (t_b == 5'd30) t_c48 <= t_c30[63:48];
        if (t_b == 5'd31) t_act <= 1'b0;
        if (t_dat) begin
          d_wc <= d_wc + 3'd1;
          if (t_last) begin drs_v <= 1'b0; drs_hs <= 1'b0; end
        end
        if (p_ndr) ndr_v <= 1'b0;
        if (p_drs) begin drs_hs <= 1'b1; d_first <= 1'b0; end
        if (p_resp) t_rr <= 1'b1;
        if (p_bis) begin t_rr <= 1'b0; bi_st <= BI_WAIT; end
      end
      // credits from the host, and those used
      c_ndr <= sat(c_ndr, a_ndr, p_ndr);
      c_drs <= sat(c_drs, a_drs, p_drs);
      c_bis <= sat(c_bis, a_bis, p_bis);
      c_io  <= sat(c_io, a_io, t_start && s_io);
      // credits owed to the host
      begin : b_owed
        logic sent;
        sent = t_gen && t_b == 5'd30;
        p_req <= (sent ? '0 : p_req) + PQ'(g_req);
        p_rwd <= (sent ? '0 : p_rwd) + PW'(g_rwd);
        p_bir <= (sent ? 1'b0 : p_bir) | g_bir;
        p_io  <= (sent ? '0 : p_io) + PI'(io_pop);
      end

      // ================= a BIRsp =================
      if (g_bir) begin : b_bir
        logic legal;
        bir_v <= 1'b0;
        legal = bir_op == 4'd0 || bir_op == 4'd1 && bi_sop != 2'd2 || bir_op == 4'd2 && bi_sop == 2'd0;
        if (bi_st == BI_WAIT && bir_tag == bi_tag) begin
          if (!legal) ev_proto <= 1'b1;
          mwe = 1'b1; mwa = bi_ln;
          mwv = !legal ? 2'b00 : bir_op == 4'd1 ? 2'b11 : bir_op == 4'd2 ? 2'b10 : 2'b00;
          bi_st <= BI_IDLE;
          if (bi_ext) begin bi_done <= 1'b1; bi_state <= mwv; end
        end else ev_proto <= 1'b1;
      end

      // ================= back-invalidation requests =================
      if (evict) begin
        bi_st <= BI_SEND; bi_ln <= victim; bi_sop <= 2'd2; bi_ext <= 1'b0; bi_tag <= bi_next;
        vp <= victim + DW'(1);
      end else if (bi_valid && bi_ready) begin
        if (meta[bi_line] == 2'b00) begin
          bi_done <= 1'b1; bi_state <= 2'b00;
        end else begin
          bi_st <= BI_SEND; bi_ln <= bi_line; bi_sop <= bi_op == 2'd3 ? 2'd2 : bi_op; bi_ext <= 1'b1;
          bi_tag <= bi_next;
        end
      end

      // ================= a Req =================
      if (g_req) begin : b_req
        logic [1:0] mv, old;
        rqr <= rqr + 1'b1;
        arb <= 1'b1;
        mf = r_mf; mv = r_h[34:33];
        in = r_in; dpa = r_dpa;
        old = in ? meta[dpa] : 2'b00;
        if (r_h[36:35] == 2'b01 || r_h[36:35] == 2'b10 || r_h[32]) ev_proto <= 1'b1;
        if (r_need != 2'd0 && !in) ev_range <= 1'b1;
        case (r_op)
          4'd1, 4'd2: begin
            // MemRd, MemRdData
            drs_v <= 1'b1; drs_hs <= 1'b0; d_wc <= '0; d_first <= 1'b0;
            drs_tag <= r_h[31:16]; drs_mv <= old; drs_dl <= devload;
            drs_po <= !in || pois[dpa];
            for (int b = 0; b < 8; b++) drb[b] <= in ? mem[{dpa, 3'(b)}] : 64'd0;
            if (in && pois[dpa]) ev_poison <= 1'b1;
            if (in && r_op == 4'd1 && mf == 2'b00) begin mwe = 1'b1; mwa = dpa; mwv = mv; end
          end
          4'd0, 4'd9, 4'd10: begin
            // MemInv, MemInvNT, MemClnEvct
            ndr_v <= 1'b1; ndr_tag <= r_h[31:16]; ndr_mv <= old; ndr_dl <= devload;
            ndr_op <= r_op != 4'd10 && mf == 2'b00 ? (mv == 2'b11 ? 3'd1 : mv == 2'b10 ? 3'd2 : 3'd0) : 3'd0;
            d_first <= drs_v;
            if (in && mf == 2'b00) begin mwe = 1'b1; mwa = dpa; mwv = mv; end
          end
          4'd8: ;                                  // MemSpecRd
          default: ev_opcode <= 1'b1;
        endcase
      end

      // ================= an RwD message =================
      if (g_rwd) begin : b_rwd
        logic [5:0] hd;
        wqr <= wqr + 1'b1;
        arb <= 1'b0;
        hd = wq_hd[wh];
        mf = hd[5:4];
        off = wq_addr[wh] - hdm_base;
        in = off < 16'(LINES);
        dpa = DW'(off);
        if (w_bic) begin
          // BIConflictAck
          ndr_v <= 1'b1; ndr_op <= 3'd4; ndr_tag <= wq_tag[wh]; ndr_mv <= 2'b00; ndr_dl <= devload;
          d_first <= drs_v;
        end else begin
          if (mf == 2'b01 || mf == 2'b10 || hd[1]) begin ev_proto <= 1'b1; mf = 2'b11; end
          if (!w_ok) ev_opcode <= 1'b1;
        end
        if (w_ok) begin
          ndr_v <= 1'b1; ndr_op <= 3'd0; ndr_tag <= wq_tag[wh]; ndr_mv <= in ? meta[dpa] : 2'b00;
          ndr_dl <= devload;
          d_first <= drs_v;
          if (!in) ev_range <= 1'b1;
          else begin
            for (int b = 0; b < 8; b++)
              for (int k = 0; k < 8; k++)
                if (w_op == 4'd1 || wq_be[wh][8 * b + k]) mem[{dpa, 3'(b)}][8 * k +: 8] <= wq_d[{wh, 3'(b)}][8 * k +: 8];
            pois[dpa] <= hd[0] || w_op == 4'd2 && pois[dpa];
            if (mf == 2'b00) begin
              mwe = 1'b1; mwa = dpa;
              mwv = bi_en && meta[dpa] == 2'b00 && sf_cnt >= (DW+1)'(SFE) ? 2'b00 : hd[3:2];
            end
          end
        end
      end

      // ================= meta state and snoop filter count =================
      if (mwe) begin
        meta[mwa] <= mwv;
        sf_cnt <= sf_cnt + (DW+1)'(mwv != 2'b00) - (DW+1)'(meta[mwa] != 2'b00);
      end
    end
`ifdef FORMAL
  `include "CXL_props.svh"
`endif
endmodule
