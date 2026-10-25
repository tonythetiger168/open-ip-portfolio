// SPDX-License-Identifier: Apache-2.0
// ============================================================================
// NVMe_top v2.0: NVMe controller command engine for one I/O submission /
// completion queue pair and one small namespace, with a host memory master
// ----------------------------------------------------------------------------
//  - Host memory: a 32-bit request channel (valid / ready; m_req_we, a
//    dword address, write data) and an in-order read response (m_rsp_valid,
//    no ready). Writes have no response. All addresses here are dword
//    addresses (byte address bits 17:2).
//  - Controller enable: while cc_en is low the controller is off
//    (csts_rdy low) and its queue pointers are zero. Raising cc_en makes it
//    ready. Dropping cc_en while a command runs aborts it: no new memory
//    request is made, a request already on the channel stays until it is
//    taken, the read responses still owed are waited for, then csts_rdy
//    falls. sq_base, cq_base and the namespace keep their values.
//  - Queues: QD entries each, at sq_base (64-byte entries) and cq_base
//    (16-byte entries). The host writes the SQ tail doorbell (sq_db_valid,
//    sq_db) and the CQ head doorbell (cq_db_valid, cq_db). A doorbell
//    value of QD or more, or a doorbell written while the controller is not
//    ready, is ignored with ev_db (NVMe's invalid doorbell write).
//  - Commands are taken one at a time, in order. The engine reads dwords
//    0, 1, 6, 7, 10, 11 and 12 of the entry (CDW0, NSID, PRP1, CDW10 to
//    CDW12), moves the SQ head past it and checks it, in this order:
//    opcode not Flush 00h, Write 01h or Read 02h: Invalid Opcode (01h);
//    FUSE or PSDT not zero: Invalid Field (02h); NSID not 1 (Flush also
//    takes FFFFFFFFh): Invalid Namespace (0Bh); Read and Write only: PRP1
//    bits 1:0 not zero: PRP Offset Invalid (13h); SLBA + NLB beyond the
//    namespace: LBA Out of Range (80h); PRP1 beyond the 256 KiB host
//    window (bits 63:18 not zero): Data Transfer Error (04h). All are
//    generic status (SCT 0); an error sets DNR.
//  - Write moves (NLB + 1) * BLKDW dwords from host memory at PRP1 into
//    the namespace at SLBA, Read the other way; Flush moves nothing. The
//    buffer is contiguous (PRP2 and page boundaries are not used); its
//    dword addresses wrap within the window.
//  - Completion: 4 dwords at the CQ tail: DW0 and DW1 zero, DW2 the SQ head
//    and SQ identifier 1, DW3 the command identifier, phase tag (1 on the
//    first pass, inverted on each wrap), status code and DNR. The engine
//    waits while the CQ is full (tail + 1 = head). ev_cqe pulses as the
//    entry is posted (an MSI); ev_err with it when the status is not
//    success.
//  Not implemented: the PCIe function and its register file (the
//  controller registers are ports here), the admin queue and its commands,
//  more than one I/O queue, PRP lists and SGLs, fused commands, metadata,
//  protection information, the 512-byte minimum LBA size (blocks are
//  BLKDW dwords), arbitration bursts, interrupt coalescing, shutdown
//  notification. Field encodings follow NVMe 1.4 as we read them; they have
//  not been checked against a compliant host.
// ============================================================================
module NVMe_top #(
  parameter int QD    = 8,              // entries per queue (power of 2, 4 .. 16)
  parameter int NBLK  = 8,              // namespace size, blocks (power of 2, at least 2)
  parameter int BLKDW = 4               // block size, dwords (power of 2, at least 2)
)(
  input  logic        clk,
  input  logic        rst_n,
  // controller registers
  input  logic        cc_en,
  output logic        csts_rdy,
  input  logic [15:0] sq_base,          // dword address of the submission queue
  input  logic [15:0] cq_base,          // dword address of the completion queue
  input  logic        sq_db_valid,      // SQ tail doorbell write
  input  logic [15:0] sq_db,
  input  logic        cq_db_valid,      // CQ head doorbell write
  input  logic [15:0] cq_db,
  output logic [$clog2(QD)-1:0] sq_head,
  output logic [$clog2(QD)-1:0] cq_tail,
  // host memory master
  output logic        m_req_valid,
  input  logic        m_req_ready,
  output logic        m_req_we,
  output logic [15:0] m_req_addr,
  output logic [31:0] m_req_wdata,
  input  logic        m_rsp_valid,
  input  logic [31:0] m_rsp_data,
  // events
  output logic        ev_cqe,           // a completion entry was posted
  output logic        ev_err,           // ... with a status other than success
  output logic        ev_db             // an invalid doorbell write, ignored
);
  localparam int QW  = $clog2(QD);
  localparam int LBW = $clog2(NBLK);
  localparam int BW  = $clog2(BLKDW);
  localparam int MW  = LBW + BW;        // namespace dword index
  localparam int CW  = MW + 1;          // transfer counts, up to NBLK * BLKDW

  typedef enum logic [2:0] {S_OFF, S_IDLE, S_FETCH, S_DEC, S_XFER, S_CPL, S_ABORT} st_t;
  st_t st;

  logic [31:0]   mem [0:NBLK*BLKDW-1];
  logic [QW-1:0] sq_tail, cq_head;
  logic          phase;

  // ---------------- the command ----------------
  logic [15:0]   cid;
  logic [1:0]    op;                    // Flush 0, Write 1, Read 2
  logic          op_bad, fld_bad, ns_one, ns_all, prp_bad, prp_in, slba_in, slba_hi0, nlb_hi0;
  logic [15:0]   prp;
  logic [LBW-1:0] slba, nlb;
  logic [2:0]    sts;                   // 0 success, 1 opcode, 2 field, 3 namespace, 4 PRP offset, 5 LBA range, 6 transfer
  logic [CW-1:0] rn, ri, rr;            // dwords to move, requested, received
  wire  [LBW:0]  lba_end = {1'b0, slba} + {1'b0, nlb};

  wire           rdy = st != S_OFF && st != S_ABORT;
  assign csts_rdy = rdy;
  wire           cq_full = cq_tail + 1'b1 == cq_head;
  wire           x_rd = st == S_XFER && op == 2'd1;   // Write command: host reads
  wire           iss = cc_en && (st == S_FETCH || st == S_XFER || st == S_CPL && !cq_full);
  wire           ld = iss && (!m_req_valid || m_req_ready) && ri != rn;
  wire           rsp = m_rsp_valid && (st == S_FETCH || x_rd || st == S_ABORT);

  // address and data of request ri
  logic [15:0]   a_n;
  logic [31:0]   d_n;
  always @* begin
    a_n = prp + 16'(ri);
    d_n = mem[{slba, BW'(0)} + MW'(ri)];
    if (st == S_FETCH)
      a_n = sq_base + {(12-QW)'(0), sq_head, 4'h0} + (ri < CW'(2) ? 16'(ri) : ri < CW'(4) ? 16'(ri) + 16'd4 : 16'(ri) + 16'd6);
    else if (st == S_CPL) begin
      a_n = cq_base + {(14-QW)'(0), cq_tail, 2'b00} + 16'(ri);
      d_n = ri[1] ? (ri[0] ? {sts != 3'd0, 6'd0,
                              sts == 3'd1 ? 8'h01 : sts == 3'd2 ? 8'h02 : sts == 3'd3 ? 8'h0B : sts == 3'd4 ? 8'h13 :
                              sts == 3'd5 ? 8'h80 : sts == 3'd6 ? 8'h04 : 8'h00, phase, cid}
                           : {16'd1, (16-QW)'(0), sq_head}) : 32'd0;
    end
  end

  always_ff @(posedge clk or negedge rst_n)
    if (!rst_n) begin
      for (int i = 0; i < NBLK * BLKDW; i++) mem[i] <= '0;
      st <= S_OFF; sq_head <= '0; sq_tail <= '0; cq_head <= '0; cq_tail <= '0; phase <= 1'b1;
      cid <= '0; op <= '0; {op_bad, fld_bad, ns_one, ns_all, prp_bad, prp_in, slba_in, slba_hi0, nlb_hi0} <= '0;
      prp <= '0; slba <= '0; nlb <= '0; sts <= '0; rn <= '0; ri <= '0; rr <= '0;
      m_req_valid <= 1'b0; m_req_we <= 1'b0; m_req_addr <= '0; m_req_wdata <= '0;
      {ev_cqe, ev_err, ev_db} <= '0;
    end else begin
      {ev_cqe, ev_err, ev_db} <= '0;
      // ---- doorbells
      if (sq_db_valid) begin
        if (rdy && sq_db < 16'(QD)) sq_tail <= sq_db[QW-1:0];
        else ev_db <= 1'b1;
      end
      if (cq_db_valid) begin
        if (rdy && cq_db < 16'(QD)) cq_head <= cq_db[QW-1:0];
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
        if (x_rd) mem[{slba, BW'(0)} + MW'(rr)] <= m_rsp_data;
        if (st == S_FETCH)
          case (rr[2:0])
            3'd0: begin
              cid <= m_rsp_data[31:16]; op <= m_rsp_data[1:0];
              op_bad <= m_rsp_data[7:0] > 8'd2;
              fld_bad <= m_rsp_data[9:8] != 2'b00 || m_rsp_data[15:14] != 2'b00;
            end
            3'd1: begin ns_one <= m_rsp_data == 32'd1; ns_all <= &m_rsp_data; end
            3'd2: begin prp <= m_rsp_data[17:2]; prp_bad <= m_rsp_data[1:0] != 2'b00; prp_in <= m_rsp_data[31:18] == '0; end
            3'd3: prp_in <= prp_in && m_rsp_data == 32'd0;
            3'd4: begin slba <= m_rsp_data[LBW-1:0]; slba_in <= m_rsp_data[31:LBW] == '0; end
            3'd5: slba_hi0 <= m_rsp_data == 32'd0;
            default: begin nlb <= m_rsp_data[LBW-1:0]; nlb_hi0 <= m_rsp_data[15:LBW] == '0; end
          endcase
      end
      // ---- the engine
      if (!cc_en && st != S_OFF && st != S_IDLE && st != S_ABORT) st <= S_ABORT;
      else
        case (st)
          S_OFF: begin
            sq_head <= '0; sq_tail <= '0; cq_head <= '0; cq_tail <= '0; phase <= 1'b1;
            if (cc_en) st <= S_IDLE;
          end
          S_IDLE:
            if (!cc_en) st <= S_OFF;
            else if (sq_head != sq_tail) begin
              st <= S_FETCH; rn <= CW'(7); ri <= '0; rr <= '0;
            end
          S_FETCH:
            if (rsp && rr == CW'(6)) begin st <= S_DEC; sq_head <= sq_head + 1'b1; end
          S_DEC: begin
            ri <= '0; rr <= '0;
            rn <= {{1'b0, nlb} + 1'b1, BW'(0)};
            if (op_bad) sts <= 3'd1;
            else if (fld_bad) sts <= 3'd2;
            else if (!ns_one && !(op == 2'd0 && ns_all)) sts <= 3'd3;
            else if (op != 2'd0 && prp_bad) sts <= 3'd4;
            else if (op != 2'd0 && !(slba_in && slba_hi0 && nlb_hi0 && !lba_end[LBW])) sts <= 3'd5;
            else if (op != 2'd0 && !prp_in) sts <= 3'd6;
            else sts <= 3'd0;
            if (op_bad || fld_bad || op == 2'd0 || !ns_one || prp_bad || !slba_in || !slba_hi0 || !nlb_hi0 || lba_end[LBW] || !prp_in) begin
              st <= S_CPL; rn <= CW'(4);
            end else st <= S_XFER;
          end
          S_XFER:
            if (x_rd ? rsp && rr == rn - 1'b1 : ri == rn && !m_req_valid) begin
              st <= S_CPL; rn <= CW'(4); ri <= '0; rr <= '0;
            end
          S_CPL:
            if (ri == rn && !m_req_valid) begin
              st <= S_IDLE; cq_tail <= cq_tail + 1'b1;
              if (cq_tail == QW'(QD - 1)) phase <= !phase;
              ev_cqe <= 1'b1; ev_err <= sts != 3'd0;
            end
          default:                       // S_ABORT: wait for the request on the channel and the reads owed
            if (!m_req_valid && (m_req_we || rr == ri)) st <= S_OFF;
        endcase
    end
endmodule
