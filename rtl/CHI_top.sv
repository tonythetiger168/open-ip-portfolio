// SPDX-License-Identifier: Apache-2.0
// ============================================================================
// CHI_top v2.0: AMBA CHI subordinate node (SN-F) for a small memory:
// ReadNoSnp, WriteNoSnpPtl and WriteNoSnpFull over CHI link-layer channels
// with L-Credit flow control
// ----------------------------------------------------------------------------
//  - Channels: RXREQ and RXDAT in, TXRSP and TXDAT out. A flit is a one
//    clock pulse of its flitv; a sender needs one L-Credit per flit, and
//    a credit is one clock pulse of the receiver's lcrdv. This node grants
//    RQ request credits (one per free request slot) and NDC data credits
//    (data is written as it arrives), and counts the credits it is given
//    for TXRSP and TXDAT (at most 15 each). A flit that arrives without a
//    credit is dropped with ev_proto.
//  - Flits (fields from CHI Issue B, narrowed): REQ {SrcID[6:0],
//    TxnID[7:0], Opcode[5:0], Order, Size[2:0], Addr[15:0]}; RXDAT
//    {TxnID[7:0], Opcode[3:0], DataID[1:0], BE[15:0], Data[127:0]}; RSP
//    {TgtID[6:0], TxnID[7:0], Opcode[3:0], RespErr[1:0], DBID[7:0]};
//    TXDAT {TgtID[6:0], TxnID[7:0], RespErr[1:0], DataID[1:0],
//    Data[127:0]}, always CompData with Resp UC (the opcode and Resp
//    fields are left out of the port).
//  - Memory: LINES 64-byte lines at byte addresses 0 .. LINES * 64 - 1,
//    16 bytes per data beat (DataID = address bits 5:4). Size 0..4 moves
//    the beat holding the address, 5 two beats, 6 the line.
//  - Requests are served in order. ReadNoSnp: ReadReceipt (RSP 8h) first
//    when Order is set, then CompData beats. WriteNoSnpPtl: DBIDResp (6h),
//    then Comp (4h) once its data beats are in; WriteNoSnpFull (Size 6
//    only): CompDBIDResp (5h). DBID = {write buffer, TxnID[6:0]}; NDB = 2
//    writes can wait for data. NonCopyBackWrData (3h) beats are written
//    with their byte enables; a beat with another opcode, a DBID not
//    waiting, or a DataID not expected (or already in) is dropped with
//    ev_proto.
//  - Errors: an address beyond the memory gets RespErr DERR (10)
//    (read data zero, write data dropped); another opcode, Size 7, or
//    WriteNoSnpFull with Size other than 6 gets Comp (or, for ReadNoSnp
//    with Size 7, one CompData beat of zeros) with RespErr NDERR (11).
//    ev_err pulses once per such request, with its first response.
//  - TXRSP: a Comp for completed write data goes before the request
//    being served. Memory is zero after reset.
//  Not implemented: snoops and the home node's coherence (the node is
//  only a memory target), the other request opcodes (atomics, CMOs,
//  exclusive, ReadOnce and friends), retry and protocol credits
//  (RetryAck, PCrdGrant), DMT / DWT, CompAck, link activation and
//  deactivation (TXLINKACTIVE*), the SACTIVE signals, QoS, poison,
//  data check, MPAM, full-width addresses and node IDs. Encodings follow
//  CHI Issue B as we read them; they have not been checked against a
//  compliant home node.
// ============================================================================
module CHI_top #(
  parameter int LINES = 16,             // memory, 64-byte lines (power of 2, at most 1024)
  parameter int RQ    = 4,              // request slots (power of 2, at least 2)
  parameter int NDC   = 2               // RXDAT credits granted (at most 7)
)(
  input  logic         clk,
  input  logic         rst_n,
  // RXREQ
  input  logic         rxreqflitv,
  input  logic [40:0]  rxreqflit,
  output logic         rxreqlcrdv,
  // RXDAT
  input  logic         rxdatflitv,
  input  logic [157:0] rxdatflit,
  output logic         rxdatlcrdv,
  // TXRSP
  output logic         txrspflitv,
  output logic [28:0]  txrspflit,
  input  logic         txrsplcrdv,
  // TXDAT
  output logic         txdatflitv,
  output logic [146:0] txdatflit,
  input  logic         txdatlcrdv,
  // events
  output logic         ev_err,          // an error response (DERR or NDERR)
  output logic         ev_proto         // a flit dropped: no credit, or data not expected
);
  localparam int QW = $clog2(RQ);
  localparam int LW = $clog2(LINES);
  localparam int CW = $clog2(NDC + 1);
  localparam logic [5:0] RD_NOSNP = 6'h04, WR_PTL = 6'h1C, WR_FULL = 6'h1D;

  // ---------------- memory ----------------
  logic [127:0]  mem [0:LINES*4-1];

  // ---------------- request slots ----------------
  logic [40:0]   rq [0:RQ-1];
  logic [QW:0]   rqw, rqr;
  logic [QW:0]   rq_g;                  // credits held by the requester
  wire  [QW:0]   rq_n = rqw - rqr;
  /* verilator lint_off UNUSEDSIGNAL */
  wire  [40:0]   h = rq[rqr[QW-1:0]];      // byte address bits 3:0 are not needed
  /* verilator lint_on UNUSEDSIGNAL */
  wire           h_v = rq_n != '0;
  wire  [5:0]    h_op = h[25:20];
  wire  [2:0]    h_size = h[18:16];
  wire  [15:4]   h_addr = h[15:4];
  wire           h_in = h_addr[15:6] < 10'(LINES);
  wire           h_rd = h_op == RD_NOSNP;
  wire           h_wr = h_op == WR_PTL && h_size != 3'd7 || h_op == WR_FULL && h_size == 3'd6;
  // the beats a Size touches: first DataID and count - 1
  wire  [1:0]    h_d0 = h_size == 3'd6 ? 2'd0 : h_size == 3'd5 ? {h_addr[5], 1'b0} : h_addr[5:4];
  wire  [1:0]    h_dn = h_size == 3'd6 ? 2'd3 : h_size == 3'd5 ? 2'd1 : 2'd0;

  // ---------------- write buffers ----------------
  logic [1:0]    w_v;
  logic [1:0]    w_ptl, w_err;
  logic [6:0]    w_tgt [0:1];
  logic [7:0]    w_txn [0:1];
  logic [LW-1:0] w_line [0:1];
  logic [3:0]    w_need [0:1], w_got [0:1];
  logic [1:0]    w_comp;                // Comp owed
  logic [CW-1:0] d_g;                   // data credits held by the requester

  // ---------------- transmit ----------------
  logic [3:0]    c_rsp, c_dat;
  logic          rcpt;                  // ReadReceipt sent for the head
  logic [1:0]    beat;                  // CompData beats sent for the head
  // TXRSP: a Comp owed, else the head's response
  wire           comp_go = w_comp != 2'b00 && c_rsp != 4'd0;
  wire           ci = !w_comp[0];       // which Comp
  wire           h_rsp = h_v && (h_rd ? h[19] && !rcpt : !h_wr || w_v != 2'b11);
  wire           rsp_go = !comp_go && h_rsp && c_rsp != 4'd0;
  wire           dat_go = h_v && h_rd && !(h[19] && !rcpt) && c_dat != 4'd0;
  wire           wi = w_v[0];           // the free write buffer for the head

  // the RXDAT flit
  wire  [7:0]    x_txn = rxdatflit[157:150];
  wire  [3:0]    x_op = rxdatflit[149:146];
  wire  [1:0]    x_id = rxdatflit[145:144];
  wire  [15:0]   x_be = rxdatflit[143:128];
  wire           x_s = x_txn[7];
  // (a buffer not waiting has every beat it needs in, or needs none)
  wire           x_ok = x_op == 4'h3 && x_txn[6:0] == w_txn[x_s][6:0] && w_need[x_s][x_id] && !w_got[x_s][x_id];

  always_ff @(posedge clk or negedge rst_n)
    if (!rst_n) begin
      for (int i = 0; i < LINES * 4; i++) mem[i] <= '0;
      rqw <= '0; rqr <= '0; rq_g <= '0; d_g <= '0; rxreqlcrdv <= 1'b0; rxdatlcrdv <= 1'b0;
      w_v <= '0; w_ptl <= '0; w_err <= '0; w_comp <= '0;
      for (int i = 0; i < 2; i++) begin w_tgt[i] <= '0; w_txn[i] <= '0; w_line[i] <= '0; w_need[i] <= '0; w_got[i] <= '0; end
      c_rsp <= '0; c_dat <= '0; rcpt <= 1'b0; beat <= '0;
      txrspflitv <= 1'b0; txrspflit <= '0; txdatflitv <= 1'b0; txdatflit <= '0;
      ev_err <= 1'b0; ev_proto <= 1'b0;
    end else begin : b_main
      logic [QW:0]   g;
      bit            push;
      logic [CW-1:0] dg;
      logic [3:0]    cr, cd;
      g = rq_g; dg = d_g; cr = c_rsp; cd = c_dat; push = 1'b0;
      ev_err <= 1'b0; ev_proto <= 1'b0;
      txrspflitv <= 1'b0; txdatflitv <= 1'b0;
      // ---- credits in
      if (txrsplcrdv) cr = cr + 1'b1;
      if (txdatlcrdv) cd = cd + 1'b1;
      // ---- RXREQ
      if (rxreqflitv) begin
        if (g == '0) ev_proto <= 1'b1;
        else begin
          g = g - 1'b1; push = 1'b1;
          rq[rqw[QW-1:0]] <= rxreqflit;
          rqw <= rqw + 1'b1;
        end
      end
      // ---- RXDAT
      if (rxdatflitv) begin
        // a beat without a credit can only come on the first clock out of
        // reset, when no write waits: !x_ok covers it
        if (!x_ok) ev_proto <= 1'b1;
        else begin
          w_got[x_s][x_id] <= 1'b1;
          if (!w_err[x_s])
            for (int b = 0; b < 16; b++)
              if (x_be[b]) mem[{w_line[x_s], x_id}][8 * b +: 8] <= rxdatflit[8 * b +: 8];
          if ((w_got[x_s] | (4'd1 << x_id)) == w_need[x_s]) begin
            if (w_ptl[x_s]) w_comp[x_s] <= 1'b1;
            else w_v[x_s] <= 1'b0;
          end
        end
        if (dg != '0) dg = dg - 1'b1;
      end
      // ---- TXRSP: a Comp owed
      if (comp_go) begin
        cr = cr - 1'b1;
        txrspflitv <= 1'b1;
        txrspflit <= {w_tgt[ci], w_txn[ci], 4'h4, w_err[ci] ? 2'b10 : 2'b00, 8'h00};
        w_comp[ci] <= 1'b0; w_v[ci] <= 1'b0;
      end
      // ---- the head request
      if (rsp_go) begin
        cr = cr - 1'b1;
        txrspflitv <= 1'b1;
        if (h_rd) begin
          txrspflit <= {h[40:26], 4'h8, 2'b00, 8'h00};
          rcpt <= 1'b1;
        end else if (h_wr) begin
          txrspflit <= {h[40:26], h_op == WR_FULL ? 4'h5 : 4'h6, h_in ? 2'b00 : 2'b10, wi, h[32:26]};
          w_v[wi] <= 1'b1; w_ptl[wi] <= h_op == WR_PTL; w_err[wi] <= !h_in;
          w_tgt[wi] <= h[40:34]; w_txn[wi] <= h[33:26];
          w_line[wi] <= h_addr[LW+5:6];
          w_need[wi] <= h_dn == 2'd3 ? 4'hF : h_dn == 2'd1 ? 4'd3 << h_d0 : 4'd1 << h_d0;
          w_got[wi] <= '0;
          if (!h_in) ev_err <= 1'b1;
          rqr <= rqr + 1'b1;
        end else begin
          txrspflit <= {h[40:26], 4'h4, 2'b11, 8'h00};
          ev_err <= 1'b1;
          rqr <= rqr + 1'b1;
        end
      end
      if (dat_go) begin
        cd = cd - 1'b1;
        txdatflitv <= 1'b1;
        txdatflit <= {h[40:26], h_size == 3'd7 ? 2'b11 : h_in ? 2'b00 : 2'b10, h_d0 + beat,
                      h_in && h_size != 3'd7 ? mem[{h_addr[LW+5:6], h_d0 + beat}] : 128'd0};
        if (beat == 2'd0 && (!h_in || h_size == 3'd7)) ev_err <= 1'b1;
        if (beat == h_dn) begin               // Size 7: h_dn is 0
          beat <= '0; rcpt <= 1'b0;
          rqr <= rqr + 1'b1;
        end else beat <= beat + 1'b1;
      end
      // ---- credits out: one per clock per channel while slots are free
      rxreqlcrdv <= 1'b0; rxdatlcrdv <= 1'b0;
      if (32'(g) + 32'(rq_n) + 32'(push) < RQ) begin
        rxreqlcrdv <= 1'b1;
        g = g + 1'b1;
      end
      if (dg != CW'(NDC)) begin
        rxdatlcrdv <= 1'b1;
        dg = dg + 1'b1;
      end
      rq_g <= g; d_g <= dg; c_rsp <= cr; c_dat <= cd;
    end
endmodule
