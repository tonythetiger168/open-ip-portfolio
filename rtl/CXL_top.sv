// SPDX-License-Identifier: Apache-2.0
// ============================================================================
// CXL_top v2.0: CXL.mem Type 3 device (memory expander) transaction layer:
// M2S Req and RwD in, S2M NDR and DRS out, host-managed device memory
// (HDM-H) with a 2-bit meta state, poison and a range decoder
// ----------------------------------------------------------------------------
//  - Channels: valid / ready, one message per handshake. A cache line is
//    64 bytes, carried in 8 beats of 64 bits (beat 0 = bytes 7:0). An RwD
//    message is 8 beats; its header fields are taken from beat 0. A DRS
//    message is 8 beats, drs_last on the eighth, with its fields steady.
//  - Address: req_addr / rwd_addr are host line addresses (byte address
//    bits 21:6). The HDM decoder maps hdm_base .. hdm_base + LINES - 1 to
//    the device's LINES lines (DPA = address - hdm_base, modulo 2^16); any other
//    address is out of range (ev_range): a read returns zeros with
//    drs_poison, a write is dropped, a completion is still sent.
//  - M2S Req opcodes: MemInv 0, MemRd 1, MemRdData 2, MemSpecRd 8,
//    MemInvNT 9, MemClnEvct 10. MemRdFwd 3, MemWrFwd 4 (HDM-DB only) and
//    the reserved codes are dropped with ev_opcode, no response.
//    MemRd / MemRdData: S2M DRS MemData with the line, its poison bit and
//    meta state. MemInv / MemInvNT / MemClnEvct: S2M NDR; for MemInv and
//    MemInvNT with MetaField Meta0-State the opcode follows MetaValue
//    (Cmp-S for Shared, Cmp-E for Any, Cmp otherwise), else Cmp.
//    MemSpecRd: no response (a prefetch hint).
//  - M2S RwD opcodes: MemWr 1 (the whole line; the poison bit replaces the
//    line's), MemWrPtl 2 (bytes with rwd_be set; poison is or-ed in);
//    S2M NDR Cmp. Others (BIConflict, reserved) are dropped (ev_opcode).
//  - Meta state (per line: Invalid 00, Any 10, Shared 11; reset Invalid):
//    MetaField Meta0-State (00) sets it to MetaValue for MemRd, MemInv,
//    MemInvNT, MemClnEvct, MemWr and MemWrPtl; No-Op (11) leaves it.
//    Responses carry the state before the request. A reserved MetaField
//    (01, 10) or SnpType (1xx) is taken as No-Op with ev_proto.
//  - Order: requests wait in a FIFO of RQD entries; a complete RwD line
//    waits in one write buffer. The two are served by round robin when
//    both wait, one per clock, when the response channel they need can
//    take a message. DevLoad in each response grades the requests left
//    waiting in the FIFO once it is served: none Light (00), 1 Optimal (01),
//    RQD - 1 or more Severe (11), else Moderate (10). Device memory is zero
//    after reset.
//  Not implemented: the flit / link layers and ARB/MUX, CXL.io and
//  CXL.cache, HDM-D / HDM-DB (back-invalidate, snoop filters, forwards),
//  interleaving and more than one HDM decoder, the extended meta field,
//  traffic classes, QoS telemetry beyond DevLoad, RAS logging. Field
//  encodings follow CXL 2.0 as we read them; they have not been checked
//  against a compliant host.
// ============================================================================
module CXL_top #(
  parameter int LINES = 16,             // device memory, cache lines (power of 2, at most 256)
  parameter int RQD   = 4               // Req FIFO entries (power of 2, at least 4)
)(
  input  logic        clk,
  input  logic        rst_n,
  input  logic [15:0] hdm_base,         // first host line address of the device
  // M2S Req
  input  logic        req_valid,
  output logic        req_ready,
  input  logic [3:0]  req_opcode,
  input  logic [1:0]  req_meta_field,
  input  logic [1:0]  req_meta_value,
  input  logic [2:0]  req_snp_type,
  input  logic [15:0] req_tag,
  input  logic [15:0] req_addr,
  // M2S RwD
  input  logic        rwd_valid,
  output logic        rwd_ready,
  input  logic [3:0]  rwd_opcode,
  input  logic [1:0]  rwd_meta_field,
  input  logic [1:0]  rwd_meta_value,
  input  logic [2:0]  rwd_snp_type,
  input  logic [15:0] rwd_tag,
  input  logic [15:0] rwd_addr,
  input  logic        rwd_poison,
  input  logic [63:0] rwd_data,
  input  logic [7:0]  rwd_be,
  // S2M NDR
  output logic        ndr_valid,
  input  logic        ndr_ready,
  output logic [1:0]  ndr_opcode,       // Cmp 0, Cmp-S 1, Cmp-E 2
  output logic [15:0] ndr_tag,
  output logic [1:0]  ndr_meta_value,
  output logic [1:0]  ndr_devload,
  // S2M DRS (MemData)
  output logic        drs_valid,
  input  logic        drs_ready,
  output logic [15:0] drs_tag,
  output logic [1:0]  drs_meta_value,
  output logic [1:0]  drs_devload,
  output logic        drs_poison,
  output logic [63:0] drs_data,
  output logic        drs_last,
  // events
  output logic        ev_range,         // address outside the HDM range
  output logic        ev_opcode,        // unsupported opcode: dropped
  output logic        ev_proto,         // reserved MetaField or SnpType
  output logic        ev_poison         // a read of a poisoned line
);
  localparam int DW = $clog2(LINES);
  localparam int QW = $clog2(RQD);

  // ---------------- device memory ----------------
  logic [63:0]   mem [0:LINES*8-1];
  logic [1:0]    meta [0:LINES-1];
  logic          pois [0:LINES-1];

  // ---------------- Req FIFO ----------------
  logic [42:0]   rq [0:RQD-1];                 // {opcode, meta field, meta value, snp type, tag, addr}
  logic [QW:0]   rqw, rqr;
  wire  [QW:0]   r_cnt = rqw - rqr;
  assign req_ready = r_cnt != (QW+1)'(RQD);
  wire  [42:0]   r_h = rq[rqr[QW-1:0]];
  wire  [3:0]    r_op = r_h[42:39];
  wire           r_valid = rqw != rqr;
  // what the head needs: 1 NDR, 2 DRS, 0 nothing
  wire  [1:0]    r_need = r_op == 4'd1 || r_op == 4'd2 ? 2'd2 : r_op == 4'd0 || r_op == 4'd9 || r_op == 4'd10 ? 2'd1 : 2'd0;

  // ---------------- RwD write buffer ----------------
  logic [63:0]   wd [0:7];
  logic [7:0]    wbe [0:7];
  logic [11:0]   wh;                           // {opcode, meta field, meta value, snp type, poison}
  logic [15:0]   w_tag, w_addr;
  logic [2:0]    w_cnt;
  logic          w_full;
  assign rwd_ready = !w_full;
  wire  [3:0]    w_op = wh[11:8];
  wire           w_ok = w_op == 4'd1 || w_op == 4'd2;

  // ---------------- responses ----------------
  logic [63:0]   drb [0:7];
  logic [2:0]    d_cnt;
  wire           n_free = !ndr_valid || ndr_ready;
  wire           d_free = !drs_valid || drs_ready && drs_last;
  assign drs_data = drb[d_cnt];
  assign drs_last = d_cnt == 3'd7;

  // ---------------- arbitration ----------------
  logic          arb;                          // 1: RwD first on a tie
  wire           c_req = r_valid && (r_need == 2'd0 || r_need == 2'd1 && n_free || r_need == 2'd2 && d_free);
  wire           c_rwd = w_full && (!w_ok || n_free);
  wire           g_rwd = c_rwd && (arb || !c_req);
  wire           g_req = c_req && !g_rwd;
  // DevLoad: the requests left waiting once this one is served
  wire  [QW:0]   r_left = r_cnt - (QW+1)'(g_req);
  wire  [1:0]    devload = r_left == '0 ? 2'b00 : r_left == (QW+1)'(1) ? 2'b01 :
                           r_left >= (QW+1)'(RQD - 1) ? 2'b11 : 2'b10;

  always_ff @(posedge clk or negedge rst_n)
    if (!rst_n) begin
      for (int i = 0; i < LINES * 8; i++) mem[i] <= '0;
      for (int i = 0; i < LINES; i++) begin meta[i] <= 2'b00; pois[i] <= 1'b0; end
      rqw <= '0; rqr <= '0; wh <= '0; w_tag <= '0; w_addr <= '0; w_cnt <= '0; w_full <= 1'b0; arb <= 1'b0;
      d_cnt <= '0; ndr_valid <= 1'b0; ndr_opcode <= '0; ndr_tag <= '0; ndr_meta_value <= '0; ndr_devload <= '0;
      drs_valid <= 1'b0; drs_tag <= '0; drs_meta_value <= '0; drs_devload <= '0; drs_poison <= 1'b0;
      {ev_range, ev_opcode, ev_proto, ev_poison} <= '0;
    end else begin : b_main
      logic [15:0] off;
      logic        in;
      logic [DW-1:0] dpa;
      {ev_range, ev_opcode, ev_proto, ev_poison} <= '0;
      // ---- in
      if (req_valid && req_ready) begin
        rq[rqw[QW-1:0]] <= {req_opcode, req_meta_field, req_meta_value, req_snp_type, req_tag, req_addr};
        rqw <= rqw + 1'b1;
      end
      if (rwd_valid && rwd_ready) begin
        wd[w_cnt] <= rwd_data; wbe[w_cnt] <= rwd_be;
        if (w_cnt == 3'd0) begin
          wh <= {rwd_opcode, rwd_meta_field, rwd_meta_value, rwd_snp_type, rwd_poison};
          w_tag <= rwd_tag; w_addr <= rwd_addr;
        end
        w_cnt <= w_cnt + 3'd1;
        if (w_cnt == 3'd7) w_full <= 1'b1;
      end
      // ---- out
      if (ndr_valid && ndr_ready) ndr_valid <= 1'b0;
      if (drs_valid && drs_ready) begin
        d_cnt <= d_cnt + 3'd1;
        if (drs_last) drs_valid <= 1'b0;
      end
      // ---- a Req
      if (g_req) begin : b_req
        logic [1:0] mf, mv, old;
        logic [2:0] snp;
        rqr <= rqr + 1'b1;
        arb <= 1'b1;
        mf = r_h[38:37]; mv = r_h[36:35]; snp = r_h[34:32];
        off = r_h[15:0] - hdm_base;
        in = off < 16'(LINES);
        dpa = DW'(off);
        old = in ? meta[dpa] : 2'b00;
        if (mf == 2'b01 || mf == 2'b10 || snp[2]) begin ev_proto <= 1'b1; mf = 2'b11; end
        if (r_need != 2'd0 && !in) ev_range <= 1'b1;
        case (r_op)
          4'd1, 4'd2: begin
            // MemRd, MemRdData
            drs_valid <= 1'b1; d_cnt <= '0;
            drs_tag <= r_h[31:16]; drs_meta_value <= old; drs_devload <= devload;
            drs_poison <= !in || pois[dpa];
            for (int b = 0; b < 8; b++) drb[b] <= in ? mem[{dpa, 3'(b)}] : 64'd0;
            if (in && pois[dpa]) ev_poison <= 1'b1;
            if (in && r_op == 4'd1 && mf == 2'b00) meta[dpa] <= mv;
          end
          4'd0, 4'd9, 4'd10: begin
            // MemInv, MemInvNT, MemClnEvct
            ndr_valid <= 1'b1; ndr_tag <= r_h[31:16]; ndr_meta_value <= old; ndr_devload <= devload;
            ndr_opcode <= r_op != 4'd10 && mf == 2'b00 ? (mv == 2'b11 ? 2'd1 : mv == 2'b10 ? 2'd2 : 2'd0) : 2'd0;
            if (in && mf == 2'b00) meta[dpa] <= mv;
          end
          4'd8: ;                                  // MemSpecRd
          default: ev_opcode <= 1'b1;
        endcase
      end
      // ---- an RwD line
      if (g_rwd) begin : b_rwd
        logic [1:0] mf;
        w_full <= 1'b0;
        arb <= 1'b0;
        mf = wh[7:6];
        off = w_addr - hdm_base;
        in = off < 16'(LINES);
        dpa = DW'(off);
        if (mf == 2'b01 || mf == 2'b10 || wh[3]) begin ev_proto <= 1'b1; mf = 2'b11; end
        if (!w_ok) ev_opcode <= 1'b1;
        else begin
          ndr_valid <= 1'b1; ndr_opcode <= 2'd0; ndr_tag <= w_tag; ndr_meta_value <= in ? meta[dpa] : 2'b00;
          ndr_devload <= devload;
          if (!in) ev_range <= 1'b1;
          else begin
            for (int b = 0; b < 8; b++)
              for (int k = 0; k < 8; k++)
                if (w_op == 4'd1 || wbe[b][k]) mem[{dpa, 3'(b)}][8 * k +: 8] <= wd[b][8 * k +: 8];
            pois[dpa] <= wh[0] || w_op == 4'd2 && pois[dpa];
            if (mf == 2'b00) meta[dpa] <= wh[5:4];
          end
        end
      end
    end
endmodule
