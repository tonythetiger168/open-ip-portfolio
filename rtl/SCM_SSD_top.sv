// SPDX-License-Identifier: Apache-2.0
// ============================================================================
// SCM_SSD_top v1.0: dual-mode SCM SSD controller slice. One device, two
// media regions and two host views:
//   - block mode: an NVMe 2.1-style I/O command engine with NQ submission /
//     completion queue pairs (round-robin arbitration), Write, Read and
//     Flush, and Flexible Data Placement (FDP) on the NAND namespace
//   - byte mode: a CXL.mem-style load / store port (tagged requests and
//     responses) straight onto the SCM region, the same cells namespace 1
//     reads and writes
// Modelled on an SCM-class (low-latency flash) plus TLC NAND drive behind
// PCIe 6.0 / CXL 3.x; the PCIe and CXL link layers are separate IPs
// (PCIe_top, CXL_top) and are not part of this core.
// ----------------------------------------------------------------------------
//  - Host memory master: as NVMe_top (32-bit request channel, valid /
//    ready; in-order read responses, no ready; dword addresses, a 256 KiB
//    window).
//  - Controller enable: while cc_en is low the controller is off
//    (csts_rdy low) and every queue pointer is zero. Raising cc_en makes it
//    ready. Dropping cc_en while a command runs aborts it as NVMe_top does
//    (no new request, the request on the channel and the reads owed are
//    waited for, then csts_rdy falls). The media keep their contents.
//  - Queues: NQ pairs, QD entries each; pair q (queue identifier q + 1)
//    has its SQ at sq_base[16q +: 16] (64-byte entries) and its CQ at
//    cq_base[16q +: 16] (16-byte entries). Doorbells carry the pair index
//    (sq_db_qid, cq_db_qid). A value of QD or more, or a write while not
//    ready, is ignored with ev_db.
//  - Arbitration: round robin over the pairs whose SQ is not empty,
//    starting after the pair served last; one command at a time.
//  - Commands: the engine reads dwords 0, 1, 6, 7, 10, 11, 12 and 13 of the
//    entry (CDW0, NSID, PRP1, CDW10 to CDW13), moves that SQ's head past it
//    and checks, in this order: opcode not Flush 00h, Write 01h or Read
//    02h: Invalid Opcode (01h); FUSE or PSDT not zero: Invalid Field (02h);
//    NSID not 1 or 2 (Flush also takes FFFFFFFFh): Invalid Namespace (0Bh);
//    Write only, CDW12 DTYPE (bits 23:20) not 0 or 2, DTYPE 2 on namespace
//    1, or DTYPE 2 with a placement handle (CDW13 DSPEC, bits 31:16) of
//    NRUH or more: Invalid Field (02h); Read and Write: PRP1 bits 1:0 not
//    zero: PRP Offset Invalid (13h); SLBA + NLB beyond the namespace: LBA
//    Out of Range (80h); PRP1 beyond the window: Data Transfer Error (04h).
//    All generic status (SCT 0); an error sets DNR.
//  - Namespaces: 1 = SCM region (NBS blocks), 2 = NAND region (NBN
//    blocks), BLKDW dwords per block. Media latency, in clocks: a Read waits
//    TSCM (namespace 1) or TRD (namespace 2) before its data moves; a
//    Write waits TSCM or TPROG after its data has moved, before the
//    completion. A NAND block never written reads as zero.
//  - FDP: NRUH reclaim unit handles, each with a reclaim unit of RUB
//    blocks. A Write to namespace 2 goes to the handle in DSPEC when DTYPE
//    is 2, else to handle 0. When it completes, its NLB + 1 blocks are
//    added to the handle's fill count; when that reaches RUB the unit is
//    full, a new one opens (the count keeps the remainder) and ev_ru pulses
//    with ev_ru_h = the handle. ru_fill shows each handle's count;
//    nand_blks and scm_blks count the blocks written to each region.
//  - Completion: 4 dwords at the CQ tail of the command's pair: DW0, DW1
//    zero, DW2 {SQ identifier q + 1, SQ head}, DW3 {DNR, 6'b0, status
//    code, phase tag, command identifier}. The engine waits while that CQ
//    is full. ev_cqe pulses with ev_cqe_qid = q (an MSI-X vector per pair);
//    ev_err with it when the status is not success.
//  - Byte port: b_req_valid / b_req_ready, b_req_we, b_req_tag, b_req_addr
//    (dword index into the SCM region), b_req_wdata. One request at a time:
//    TSCM clocks after it is taken the port answers with b_rsp_valid (one
//    clock, no ready), b_rsp_tag, b_rsp_data (the dword for a read, zero
//    for a write) and b_rsp_err when the address is beyond the region
//    (nothing is written). Byte-port stores and namespace 1 Writes hit the
//    same cells; if both write one dword in the same clock, the byte port's
//    value lands. The byte port works while the controller is disabled.
//  Not implemented: the admin queue (no Identify, Get Log Page or FDP
//  event log; the FDP configuration is fixed by parameters), PRP lists and
//  SGLs, metadata and protection information, the 512-byte minimum LBA
//  size, weighted round robin and urgent queues, wear levelling, garbage
//  collection, reclaim-unit erase, power-loss protection. Field encodings
//  follow NVMe 2.1 as we read them; they have not been checked against a
//  compliant host.
// ============================================================================
module SCM_SSD_top #(
  parameter int NQ    = 4,              // I/O queue pairs (power of 2, 2 .. 8)
  parameter int QD    = 8,              // entries per queue (power of 2, 4 .. 16)
  parameter int BLKDW = 4,              // block size, dwords (power of 2, at least 2)
  parameter int NBS   = 8,              // SCM namespace, blocks (power of 2, at least 2)
  parameter int NBN   = 16,             // NAND namespace, blocks (power of 2, at least NBS)
  parameter int NRUH  = 4,              // FDP reclaim unit handles (power of 2, 2 .. 16)
  parameter int RUB   = 4,              // blocks per reclaim unit (power of 2, at least 2)
  parameter int TSCM  = 2,              // SCM access latency, clocks (1 .. 255)
  parameter int TRD   = 12,             // NAND read latency, clocks (1 .. 255)
  parameter int TPROG = 24              // NAND program latency, clocks (1 .. 255)
)(
  input  logic        clk,
  input  logic        rst_n,
  // controller registers
  input  logic        cc_en,
  output logic        csts_rdy,
  input  logic [NQ*16-1:0] sq_base,     // dword address of each SQ
  input  logic [NQ*16-1:0] cq_base,     // dword address of each CQ
  input  logic        sq_db_valid,
  input  logic [$clog2(NQ)-1:0] sq_db_qid,
  input  logic [15:0] sq_db,
  input  logic        cq_db_valid,
  input  logic [$clog2(NQ)-1:0] cq_db_qid,
  input  logic [15:0] cq_db,
  output logic [NQ*$clog2(QD)-1:0] sq_head,
  output logic [NQ*$clog2(QD)-1:0] cq_tail,
  // host memory master
  output logic        m_req_valid,
  input  logic        m_req_ready,
  output logic        m_req_we,
  output logic [15:0] m_req_addr,
  output logic [31:0] m_req_wdata,
  input  logic        m_rsp_valid,
  input  logic [31:0] m_rsp_data,
  // byte-mode (CXL.mem-style) port onto the SCM region
  input  logic        b_req_valid,
  output logic        b_req_ready,
  input  logic        b_req_we,
  input  logic [7:0]  b_req_tag,
  input  logic [15:0] b_req_addr,
  input  logic [31:0] b_req_wdata,
  output logic        b_rsp_valid,
  output logic [7:0]  b_rsp_tag,
  output logic [31:0] b_rsp_data,
  output logic        b_rsp_err,
  // FDP and media statistics
  output logic [NRUH*$clog2(RUB)-1:0] ru_fill,
  output logic [31:0] nand_blks,
  output logic [31:0] scm_blks,
  // events
  output logic        ev_cqe,
  output logic [$clog2(NQ)-1:0] ev_cqe_qid,
  output logic        ev_err,
  output logic        ev_db,
  output logic        ev_ru,
  output logic [$clog2(NRUH)-1:0] ev_ru_h
);
  localparam int QW  = $clog2(QD);
  localparam int QIW = $clog2(NQ);
  localparam int BW  = $clog2(BLKDW);
  localparam int LBS = $clog2(NBS);
  localparam int LBN = $clog2(NBN);
  localparam int DS  = NBS * BLKDW;     // SCM dwords
  localparam int DN  = NBN * BLKDW;     // NAND dwords
  localparam int MSW = LBS + BW;        // SCM dword index
  localparam int MNW = LBN + BW;        // NAND dword index
  localparam int CW  = MNW + 1;         // transfer counts, up to DN (at least 8: the fetch)
  localparam int HW  = $clog2(NRUH);
  localparam int RW  = $clog2(RUB);

  typedef enum logic [3:0] {S_OFF, S_IDLE, S_FETCH, S_DEC, S_MEDIA, S_XFER, S_PROG, S_CPL, S_ABORT} st_t;
  st_t st;

  logic [31:0]    mem_s [0:DS-1];
  logic [31:0]    mem_n [0:DN-1];
  logic [QW-1:0]  sqh [NQ], sqt [NQ], cqh [NQ], cqt [NQ];
  logic           ph  [NQ];
  logic [RW-1:0]  fill [NRUH];
  logic [QIW-1:0] q, last_q;            // the pair being served, the one served last

  // ---------------- the command ----------------
  logic [15:0]    cid;
  logic [1:0]     op;                   // Flush 0, Write 1, Read 2
  logic           op_bad, fld_bad, ns1, ns2, ns_all, prp_bad, prp_in, slba_hi0;
  logic [15:0]    prp;
  logic [31:0]    slba32;
  logic [15:0]    nlb16;
  logic [3:0]     dtype;
  logic [15:0]    dspec;
  logic           nsn;                  // the command is on namespace 2
  logic [HW-1:0]  ruh;
  logic [2:0]     sts;                  // 0 ok, 1 opcode, 2 field, 3 namespace, 4 PRP offset, 5 LBA range, 6 transfer
  logic [CW-1:0]  rn, ri, rr;
  logic [7:0]     lat;                  // media latency counter

  wire  [LBN:0]   lba_end = {1'b0, slba32[LBN-1:0]} + {1'b0, nlb16[LBN-1:0]};
  wire            ns1_rng = slba32[31:LBS] == '0 && nlb16[15:LBS] == '0 && !lba_end[LBS];
  wire            ns2_rng = slba32[31:LBN] == '0 && nlb16[15:LBN] == '0 && !lba_end[LBN];
  wire            fdp_bad = op == 2'd1 && (!(dtype == 4'd0 || dtype == 4'd2) ||
                                           dtype == 4'd2 && (!ns2 || dspec >= 16'(NRUH)));

  wire            rdy     = st != S_OFF && st != S_ABORT;
  assign csts_rdy = rdy;
  wire            cq_full = cqt[q] + 1'b1 == cqh[q];
  wire            x_rd    = st == S_XFER && op == 2'd1;   // Write: the controller reads the host
  wire            iss     = cc_en && (st == S_FETCH || st == S_XFER || st == S_CPL && !cq_full);
  wire            ld      = iss && (!m_req_valid || m_req_ready) && ri != rn;
  wire            rsp     = m_rsp_valid && (st == S_FETCH || x_rd || st == S_ABORT);

  // the next pair to serve: round robin after last_q
  logic           any;
  logic [QIW-1:0] nxt;
  always @* begin
    any = 1'b0; nxt = last_q;
    for (int k = 1; k <= NQ; k++)
      if (!any && sqh[QIW'(last_q + QIW'(k))] != sqt[QIW'(last_q + QIW'(k))]) begin
        any = 1'b1; nxt = QIW'(last_q + QIW'(k));
      end
  end

  // media dword of transfer index i
  wire  [MSW-1:0] ms_i = {slba32[LBS-1:0], BW'(0)} + MSW'(ri);
  wire  [MNW-1:0] mn_i = {slba32[LBN-1:0], BW'(0)} + MNW'(ri);
  wire  [MSW-1:0] ms_r = {slba32[LBS-1:0], BW'(0)} + MSW'(rr);
  wire  [MNW-1:0] mn_r = {slba32[LBN-1:0], BW'(0)} + MNW'(rr);

  // address and data of request ri
  logic [15:0]    a_n;
  logic [31:0]    d_n;
  logic [15:0]    sqb, cqb;
  always @* begin
    sqb = sq_base[16*q +: 16];
    cqb = cq_base[16*q +: 16];
    a_n = prp + 16'(ri);
    d_n = nsn ? mem_n[mn_i] : mem_s[ms_i];
    if (st == S_FETCH)
      a_n = sqb + {(12-QW)'(0), sqh[q], 4'h0} +
            (ri < CW'(2) ? 16'(ri) : ri < CW'(4) ? 16'(ri) + 16'd4 : 16'(ri) + 16'd6);
    else if (st == S_CPL) begin
      a_n = cqb + {(14-QW)'(0), cqt[q], 2'b00} + 16'(ri);
      d_n = ri[1] ? (ri[0] ? {sts != 3'd0, 6'd0,
                              sts == 3'd1 ? 8'h01 : sts == 3'd2 ? 8'h02 : sts == 3'd3 ? 8'h0B : sts == 3'd4 ? 8'h13 :
                              sts == 3'd5 ? 8'h80 : sts == 3'd6 ? 8'h04 : 8'h00, ph[q], cid}
                           : {16'(q) + 16'd1, (16-QW)'(0), sqh[q]}) : 32'd0;
    end
  end

  always @* begin
    for (int i = 0; i < NQ; i++) begin
      sq_head[QW*i +: QW] = sqh[i];
      cq_tail[QW*i +: QW] = cqt[i];
    end
    for (int h = 0; h < NRUH; h++) ru_fill[RW*h +: RW] = fill[h];
  end

  // ---------------- byte port ----------------
  logic           b_busy, b_we;
  logic [7:0]     b_tag, b_cnt;
  logic [15:0]    b_addr;
  logic [31:0]    b_wd;
  assign b_req_ready = !b_busy;
  wire            b_in  = b_addr < 16'(DS);
  wire            b_fin = b_busy && b_cnt == 8'd1;

  // FDP fill on a NAND write's completion
  wire  [RW:0]    f_sum = {1'b0, fill[ruh]} + (RW+1)'(nlb16[RW-1:0]) + 1'b1;
  wire            f_wrap = f_sum[RW] || nlb16[LBN-1:0] >= LBN'(RUB);

  always_ff @(posedge clk or negedge rst_n)
    if (!rst_n) begin
      for (int i = 0; i < DS; i++) mem_s[i] <= '0;
      for (int i = 0; i < DN; i++) mem_n[i] <= '0;
      for (int i = 0; i < NQ; i++) begin sqh[i] <= '0; sqt[i] <= '0; cqh[i] <= '0; cqt[i] <= '0; ph[i] <= 1'b1; end
      for (int h = 0; h < NRUH; h++) fill[h] <= '0;
      st <= S_OFF; q <= '0; last_q <= QIW'(NQ - 1);
      cid <= '0; op <= '0; {op_bad, fld_bad, ns1, ns2, ns_all, prp_bad, prp_in, slba_hi0} <= '0;
      prp <= '0; slba32 <= '0; nlb16 <= '0; dtype <= '0; dspec <= '0; nsn <= 1'b0; ruh <= '0;
      sts <= '0; rn <= '0; ri <= '0; rr <= '0; lat <= '0;
      m_req_valid <= 1'b0; m_req_we <= 1'b0; m_req_addr <= '0; m_req_wdata <= '0;
      b_busy <= 1'b0; b_we <= 1'b0; b_tag <= '0; b_cnt <= '0; b_addr <= '0; b_wd <= '0;
      b_rsp_valid <= 1'b0; b_rsp_tag <= '0; b_rsp_data <= '0; b_rsp_err <= 1'b0;
      nand_blks <= '0; scm_blks <= '0;
      {ev_cqe, ev_err, ev_db, ev_ru} <= '0; ev_cqe_qid <= '0; ev_ru_h <= '0;
    end else begin
      {ev_cqe, ev_err, ev_db, ev_ru} <= '0;
      // ---- doorbells
      if (sq_db_valid) begin
        if (rdy && sq_db < 16'(QD)) sqt[sq_db_qid] <= sq_db[QW-1:0];
        else ev_db <= 1'b1;
      end
      if (cq_db_valid) begin
        if (rdy && cq_db < 16'(QD)) cqh[cq_db_qid] <= cq_db[QW-1:0];
        else ev_db <= 1'b1;
      end
      // ---- memory requests
      if (m_req_valid && m_req_ready) m_req_valid <= 1'b0;
      if (ld) begin
        m_req_valid <= 1'b1;
        m_req_we <= st == S_CPL || st == S_XFER && op == 2'd2;
        m_req_addr <= a_n;
        m_req_wdata <= d_n;
        ri <= ri + 1'b1;
      end
      if (rsp) begin
        rr <= rr + 1'b1;
        if (x_rd) begin
          if (nsn) mem_n[mn_r] <= m_rsp_data;
          else     mem_s[ms_r] <= m_rsp_data;
        end
        if (st == S_FETCH)
          case (rr[2:0])
            3'd0: begin
              cid <= m_rsp_data[31:16]; op <= m_rsp_data[1:0];
              op_bad <= m_rsp_data[7:0] > 8'd2;
              fld_bad <= m_rsp_data[9:8] != 2'b00 || m_rsp_data[15:14] != 2'b00;
            end
            3'd1: begin ns1 <= m_rsp_data == 32'd1; ns2 <= m_rsp_data == 32'd2; ns_all <= &m_rsp_data; end
            3'd2: begin prp <= m_rsp_data[17:2]; prp_bad <= m_rsp_data[1:0] != 2'b00; prp_in <= m_rsp_data[31:18] == '0; end
            3'd3: prp_in <= prp_in && m_rsp_data == 32'd0;
            3'd4: slba32 <= m_rsp_data;
            3'd5: slba_hi0 <= m_rsp_data == 32'd0;
            3'd6: begin nlb16 <= m_rsp_data[15:0]; dtype <= m_rsp_data[23:20]; end
            default: dspec <= m_rsp_data[31:16];
          endcase
      end
      // ---- the engine
      if (!cc_en && st != S_OFF && st != S_IDLE && st != S_ABORT) st <= S_ABORT;
      else
        case (st)
          S_OFF: begin
            for (int i = 0; i < NQ; i++) begin sqh[i] <= '0; sqt[i] <= '0; cqh[i] <= '0; cqt[i] <= '0; ph[i] <= 1'b1; end
            last_q <= QIW'(NQ - 1);
            if (cc_en) st <= S_IDLE;
          end
          S_IDLE:
            if (!cc_en) st <= S_OFF;
            else if (any) begin
              st <= S_FETCH; q <= nxt; last_q <= nxt; rn <= CW'(8); ri <= '0; rr <= '0;
            end
          S_FETCH:
            if (rsp && rr == CW'(7)) begin st <= S_DEC; sqh[q] <= sqh[q] + 1'b1; end
          S_DEC: begin
            ri <= '0; rr <= '0;
            nsn <= ns2;
            ruh <= dtype == 4'd2 ? dspec[HW-1:0] : '0;
            rn <= ns2 ? {{1'b0, nlb16[LBN-1:0]} + 1'b1, BW'(0)} : CW'({{1'b0, nlb16[LBS-1:0]} + 1'b1, BW'(0)});
            lat <= ns2 ? 8'(TRD) : 8'(TSCM);
            if (op_bad) sts <= 3'd1;
            else if (fld_bad) sts <= 3'd2;
            else if (!(ns1 || ns2) && !(op == 2'd0 && ns_all)) sts <= 3'd3;
            else if (fdp_bad) sts <= 3'd2;
            else if (op != 2'd0 && prp_bad) sts <= 3'd4;
            else if (op != 2'd0 && !(slba_hi0 && (ns2 ? ns2_rng : ns1_rng))) sts <= 3'd5;
            else if (op != 2'd0 && !prp_in) sts <= 3'd6;
            else sts <= 3'd0;
            if (op_bad || fld_bad || op == 2'd0 || !(ns1 || ns2) || fdp_bad || prp_bad ||
                !(slba_hi0 && (ns2 ? ns2_rng : ns1_rng)) || !prp_in) begin
              st <= S_CPL; rn <= CW'(4);
            end else st <= op == 2'd2 ? S_MEDIA : S_XFER;
          end
          S_MEDIA:                       // Read: media access time
            if (lat == 8'd1) st <= S_XFER;
            else lat <= lat - 1'b1;
          S_XFER:
            if (x_rd ? rsp && rr == rn - 1'b1 : ri == rn && !m_req_valid) begin
              ri <= '0; rr <= '0;
              if (op == 2'd1) begin st <= S_PROG; lat <= nsn ? 8'(TPROG) : 8'(TSCM); end
              else begin st <= S_CPL; rn <= CW'(4); end
            end
          S_PROG:                        // Write: program time, then account the blocks
            if (lat == 8'd1) begin
              st <= S_CPL; rn <= CW'(4);
              if (nsn) begin
                nand_blks <= nand_blks + 32'(nlb16[LBN-1:0]) + 1'b1;
                fill[ruh] <= f_sum[RW-1:0];
                if (f_wrap) begin ev_ru <= 1'b1; ev_ru_h <= ruh; end
              end else
                scm_blks <= scm_blks + 32'(nlb16[LBS-1:0]) + 1'b1;
            end else lat <= lat - 1'b1;
          S_CPL:
            if (ri == rn && !m_req_valid) begin
              st <= S_IDLE; cqt[q] <= cqt[q] + 1'b1;
              if (cqt[q] == QW'(QD - 1)) ph[q] <= !ph[q];
              ev_cqe <= 1'b1; ev_cqe_qid <= q; ev_err <= sts != 3'd0;
            end
          default:                       // S_ABORT
            if (!m_req_valid && (m_req_we || rr == ri)) st <= S_OFF;
        endcase
      // ---- byte port (after the engine: its store wins a same-clock conflict)
      b_rsp_valid <= 1'b0;
      if (!b_busy && b_req_valid) begin
        b_busy <= 1'b1; b_we <= b_req_we; b_tag <= b_req_tag; b_addr <= b_req_addr;
        b_wd <= b_req_wdata; b_cnt <= 8'(TSCM);
      end else if (b_busy) begin
        b_cnt <= b_cnt - 1'b1;
        if (b_fin) begin
          b_busy <= 1'b0;
          b_rsp_valid <= 1'b1; b_rsp_tag <= b_tag; b_rsp_err <= !b_in;
          b_rsp_data <= b_in && !b_we ? mem_s[b_addr[MSW-1:0]] : 32'd0;
          if (b_in && b_we) mem_s[b_addr[MSW-1:0]] <= b_wd;
        end
      end
    end
endmodule
