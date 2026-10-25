// SPDX-License-Identifier: Apache-2.0
// ============================================================================
// CCIX_Cache_Coherent_Interconnect_top v2.0: CCIX link layer over PCIe:
// protocol-layer messages packed into PCIe vendor-defined message TLPs,
// with message credits for requests and snoops
// ----------------------------------------------------------------------------
//  - Messages (32-bit words): a header word {MsgType[3:0], MsgLen[3:0],
//    CrdReq[3:0], CrdSnp[3:0], 16 bits for the protocol layer (target and
//    source IDs, opcode)}, then MsgLen - 1 body words, opaque here.
//    MsgType 1 Request, 2 Snoop, 3 Response; MsgLen 1..8. MsgType 0 is the
//    link layer's own Misc message (MsgLen 1) that only returns credits.
//  - Transmit: the protocol layer writes messages on tx_*. A Request
//    needs a Request credit, a Snoop a Snoop credit (credits the peer
//    returns; tx_crd_req / tx_crd_snp count them), a Response none; a
//    message waits on tx_ready until its credit is there. Messages are
//    gathered into a TLP payload of at most MAXP words: the TLP is sent
//    once the next message is not ready, does not fit, or has no credit.
//    Every header leaves with CrdReq / CrdSnp set to the credits this end
//    returns (the protocol layer's values are replaced); with credits to
//    return and no message for CRT clocks, a Misc message carries them.
//    A header with a bad MsgType or MsgLen is dropped alone, with ev_err.
//  - TLP (PCIe Message with data, routed by ID, Vendor_Defined Type 1):
//    DW0 {Fmt 011, Type 10010, 0, Length[9:0]}, DW1 {rid, Tag, 7Fh},
//    DW2 {tgt_rid, Vendor ID 1E2Ch}, DW3 0, then Length payload words.
//    Tag counts the TLPs sent.
//  - Receive: tlp_rx_* takes a TLP word per clock (no back-pressure). A
//    TLP with another Fmt / Type / message code / vendor, a target other
//    than rid, DW3 not 0, a Length of 0 or above MAXP, or a last word not
//    where Length puts it is dropped from the bad word on, with ev_err;
//    so is a message with a bad MsgType or MsgLen or running past the
//    payload (the messages before it stay). Messages are written to an
//    RXD-word buffer and handed out on rx_* (rx_last on a message's last
//    word) once complete. A Request or Snoop needs a credit this end
//    granted (NREQ and NSNP of them, one per message buffered): without
//    one it is skipped with ev_nocrd. A Response is taken if the buffer
//    has room for it besides 8 words per Request and Snoop credit not yet
//    used; else it is skipped with ev_ovf. The credit of a Request or
//    Snoop goes back once the protocol layer has read the message. The
//    credits a well-formed header carries are added once the message is
//    in; if either count would pass 31, neither is added (ev_err).
//  Not implemented: the CCIX transaction layer and agents (home, request,
//  slave agents, coherence), the optimized TLP format, CCIX TLP prefixes
//  and the PCIe link itself (DLLPs, flow-control credits: this core sits
//  on a transaction layer's TLP streams), port and link IDs beyond the
//  PCIe ID, message packing rules other than in-order gathering, and
//  CCIX ESM / ports discovery. Field positions and encodings are ours;
//  they have not been checked against a CCIX peer.
// ============================================================================
module CCIX_Cache_Coherent_Interconnect_top #(
  parameter int MAXP = 16,              // TLP payload words (8..1023)
  parameter int NREQ = 2,               // Request credits granted (1..15)
  parameter int NSNP = 2,               // Snoop credits granted (1..15)
  parameter int RXD  = 64,              // receive buffer words (power of 2, more than 8 * (NREQ + NSNP))
  parameter int CRT  = 16               // idle clocks before a Misc returns credits
)(
  input  logic        clk,
  input  logic        rst_n,
  input  logic [15:0] rid,              // this end's PCIe ID
  input  logic [15:0] tgt_rid,          // the peer's PCIe ID
  // messages to send
  input  logic        tx_valid,
  output logic        tx_ready,
  input  logic [31:0] tx_data,
  // messages received
  output logic        rx_valid,
  input  logic        rx_ready,
  output logic [31:0] rx_data,
  output logic        rx_last,
  // TLPs to the transaction layer
  output logic        tlp_tx_valid,
  input  logic        tlp_tx_ready,
  output logic [31:0] tlp_tx_data,
  output logic        tlp_tx_last,
  // TLPs from the transaction layer
  input  logic        tlp_rx_valid,
  input  logic [31:0] tlp_rx_data,
  input  logic        tlp_rx_last,
  // status and events
  output logic [4:0]  tx_crd_req,       // Request credits held
  output logic [4:0]  tx_crd_snp,       // Snoop credits held
  output logic        ev_err,           // a malformed TLP or message dropped, a credit count overflowing
  output logic        ev_nocrd,         // a Request or Snoop without a credit skipped
  output logic        ev_ovf            // a Response without room skipped
);
  localparam int PW = $clog2(MAXP + 1);
  localparam int AW = $clog2(MAXP);
  localparam int RW = $clog2(RXD);
  localparam int IW = $clog2(CRT + 1);
  localparam int QW = $clog2(NREQ + 1);
  localparam int SW = $clog2(NSNP + 1);
  localparam int XW = $clog2(MAXP + 5);

  // ---------------- transmit ----------------
  typedef enum logic [1:0] {T_IDLE, T_BODY, T_GATH, T_TLP} t_t;
  t_t            ts;
  logic [31:0]   tb [0:MAXP-1];         // payload being gathered
  logic [PW-1:0] tn;                    // payload words
  logic [2:0]    tbody;                 // body words still to come
  logic [XW-1:0] tp;                    // TLP word being sent: 0..3 header, then payload
  logic [7:0]    tag;
  logic [IW-1:0] idle;
  logic [QW-1:0] p_req;                 // credits to return
  logic [SW-1:0] p_snp;
  logic [4:0]    c_req, c_snp;          // credits held

  wire  [3:0]    h_ty = tx_data[31:28];
  wire  [3:0]    h_ln = tx_data[27:24];
  wire           h_bad = h_ty == 4'd0 || h_ty > 4'd3 || h_ln == 4'd0 || h_ln > 4'd8;
  wire           h_crd = h_ty == 4'd1 ? c_req != '0 : h_ty == 4'd2 ? c_snp != '0 : 1'b1;
  wire           h_fit = 32'(tn) + 32'(h_ln) <= MAXP;
  wire           misc_go = (p_req != '0 || p_snp != '0) && 32'(idle) == CRT;

  always_comb
    case (ts)
      T_IDLE:  tx_ready = !misc_go && (h_bad || h_crd);
      T_BODY:  tx_ready = 1'b1;
      T_GATH:  tx_ready = h_bad || h_crd && h_fit;
      default: tx_ready = 1'b0;
    endcase

  assign tlp_tx_valid = ts == T_TLP;
  assign tlp_tx_last = 32'(tp) == 32'(tn) + 3;
  always_comb
    case (32'(tp))
      0:       tlp_tx_data = {8'b011_10010, 14'd0, 10'(tn)};
      1:       tlp_tx_data = {rid, tag, 8'h7F};
      2:       tlp_tx_data = {tgt_rid, 16'h1E2C};
      3:       tlp_tx_data = 32'd0;
      default: tlp_tx_data = tb[AW'(tp - 4)];
    endcase

  // ---------------- receive ----------------
  typedef enum logic [2:0] {R_H0, R_H1, R_H2, R_H3, R_MH, R_MB, R_SKIP, R_DROP} r_t;
  r_t            rs;
  logic [33:0]   fq [0:RXD-1];          // {MsgType at a message's last word, else 0; word}
  logic [RW:0]   wp, tw, rp;            // committed write, tentative write, read
  logic [PW-1:0] rem;                   // payload words left in the TLP
  logic [2:0]    cnt;                   // body words left in the message
  logic [1:0]    m_cl;                  // the message's class
  logic [3:0]    m_cq, m_cs;            // credits its header carries
  logic [QW-1:0] o_req;                 // credits granted, not used yet
  logic [SW-1:0] o_snp;

  wire  [3:0]    r_ty = tlp_rx_data[31:28];
  wire  [3:0]    r_ln = tlp_rx_data[27:24];
  wire           r_end = tlp_rx_last != (rem == PW'(1));   // last word not where Length puts it
  wire  [RW:0]   r_used = wp - rp;
  wire           r_room = 32'(RXD) - 32'(r_used) >= 32'(r_ln) + 8 * (32'(o_req) + 32'(o_snp) + 32'(p_req) + 32'(p_snp));
  // a well-formed message not taken: no credit, or no room
  wire           r_skip = r_ty == 4'd1 && o_req == '0 || r_ty == 4'd2 && o_snp == '0 || r_ty == 4'd3 && !r_room;

  assign rx_valid = rp != wp;
  assign rx_data = fq[rp[RW-1:0]][31:0];
  assign rx_last = fq[rp[RW-1:0]][33:32] != 2'd0;
  assign tx_crd_req = c_req;
  assign tx_crd_snp = c_snp;

  always_ff @(posedge clk or negedge rst_n)
    if (!rst_n) begin
      ts <= T_IDLE; tn <= '0; tbody <= '0; tp <= '0; tag <= '0; idle <= '0;
      for (int i = 0; i < MAXP; i++) tb[i] <= '0;
      p_req <= QW'(NREQ); p_snp <= SW'(NSNP); c_req <= '0; c_snp <= '0;
      rs <= R_H0; wp <= '0; tw <= '0; rp <= '0; rem <= '0; cnt <= '0; m_cl <= '0;
      m_cq <= '0; m_cs <= '0; o_req <= '0; o_snp <= '0;
      for (int i = 0; i < RXD; i++) fq[i] <= '0;
      ev_err <= 1'b0; ev_nocrd <= 1'b0; ev_ovf <= 1'b0;
    end else begin : b_main
      logic [QW-1:0] pq, oq;
      logic [SW-1:0] ps, os;
      logic [4:0]    cq, cs;
      bit            cmt;               // the message received is complete
      bit            tlp_bad;
      pq = p_req; ps = p_snp; cq = c_req; cs = c_snp; oq = o_req; os = o_snp;
      cmt = 1'b0; tlp_bad = 1'b0;
      ev_err <= 1'b0; ev_nocrd <= 1'b0; ev_ovf <= 1'b0;

      // ---- receive
      if (tlp_rx_valid)
        case (rs)
          R_H0: begin
            rem <= PW'(tlp_rx_data[9:0]);
            if (tlp_rx_data[31:24] != 8'b011_10010 || tlp_rx_data[9:0] == '0 || 32'(tlp_rx_data[9:0]) > MAXP ||
                tlp_rx_last) tlp_bad = 1'b1;
            else rs <= R_H1;
          end
          R_H1:
            if (tlp_rx_data[7:0] != 8'h7F || tlp_rx_last) tlp_bad = 1'b1;
            else rs <= R_H2;
          R_H2:
            if (tlp_rx_data != {rid, 16'h1E2C} || tlp_rx_last) tlp_bad = 1'b1;
            else rs <= R_H3;
          R_H3:
            if (tlp_rx_data != '0 || tlp_rx_last) tlp_bad = 1'b1;
            else rs <= R_MH;
          R_MH: begin
            rem <= rem - 1'b1;
            m_cq <= tlp_rx_data[23:20]; m_cs <= tlp_rx_data[19:16];
            m_cl <= r_ty[1:0];
            cnt <= 3'(r_ln - 1'b1);
            if (r_ty > 4'd3 || r_ln == '0 || r_ln > 4'd8 || 32'(r_ln) > 32'(rem) || r_ty == '0 && r_ln != 4'd1 ||
                r_end) tlp_bad = 1'b1;
            else begin
              if (r_skip && r_ty == 4'd3) ev_ovf <= 1'b1;
              else if (r_skip) ev_nocrd <= 1'b1;
              else if (r_ty != '0) begin
                fq[tw[RW-1:0]] <= {r_ln == 4'd1 ? r_ty[1:0] : 2'd0, tlp_rx_data};
                tw <= tw + 1'b1;
              end
              if (r_ln == 4'd1) cmt = 1'b1;
              else rs <= r_skip ? R_SKIP : R_MB;
            end
          end
          R_MB: begin
            rem <= rem - 1'b1;
            cnt <= cnt - 1'b1;
            if (r_end) tlp_bad = 1'b1;
            else begin
              fq[tw[RW-1:0]] <= {cnt == 3'd1 ? m_cl : 2'd0, tlp_rx_data};
              tw <= tw + 1'b1;
              if (cnt == 3'd1) cmt = 1'b1;
            end
          end
          R_SKIP: begin
            rem <= rem - 1'b1;
            cnt <= cnt - 1'b1;
            if (r_end) tlp_bad = 1'b1;
            else if (cnt == 3'd1) cmt = 1'b1;
          end
          default:                                        // R_DROP
            if (tlp_rx_last) rs <= R_H0;
        endcase
      if (cmt) begin
        // a header just in (MsgLen 1) has its fields on the bus
        logic [3:0] aq, as;
        logic [1:0] cl;
        bit         kp;
        if (rs == R_MH) begin
          aq = tlp_rx_data[23:20]; as = tlp_rx_data[19:16]; cl = r_ty[1:0]; kp = !r_skip;
        end else begin
          aq = m_cq; as = m_cs; cl = m_cl; kp = rs == R_MB;
        end
        if (6'(cq) + 6'(aq) > 6'd31 || 6'(cs) + 6'(as) > 6'd31) ev_err <= 1'b1;
        else begin cq = cq + 5'(aq); cs = cs + 5'(as); end
        if (kp && cl != 2'd0) begin
          wp <= tw + 1'b1;
          if (cl == 2'd1) oq = oq - 1'b1;
          if (cl == 2'd2) os = os - 1'b1;
        end
        rs <= tlp_rx_last ? R_H0 : R_MH;
      end
      if (tlp_bad) begin
        ev_err <= 1'b1;
        tw <= wp;
        rs <= tlp_rx_last ? R_H0 : R_DROP;
      end

      // ---- the protocol layer reads
      if (rx_valid && rx_ready) begin
        rp <= rp + 1'b1;
        if (fq[rp[RW-1:0]][33:32] == 2'd1) pq = pq + 1'b1;
        if (fq[rp[RW-1:0]][33:32] == 2'd2) ps = ps + 1'b1;
      end

      // ---- transmit
      case (ts)
        T_IDLE:
          if (misc_go) begin
            tb[0] <= {8'h01, 4'(p_req), 4'(p_snp), 16'h0000};
            oq = oq + p_req; os = os + p_snp;
            pq = pq - p_req; ps = ps - p_snp;
            tn <= PW'(1); tp <= '0; ts <= T_TLP;
          end else if (tx_valid && tx_ready) begin
            if (h_bad) ev_err <= 1'b1;
            else begin
              tb[0] <= {tx_data[31:24], 4'(p_req), 4'(p_snp), tx_data[15:0]};
              oq = oq + p_req; os = os + p_snp;
              pq = pq - p_req; ps = ps - p_snp;
              if (h_ty == 4'd1) cq = cq - 1'b1;
              if (h_ty == 4'd2) cs = cs - 1'b1;
              tn <= PW'(1); tbody <= 3'(h_ln - 1'b1);
              ts <= h_ln == 4'd1 ? T_GATH : T_BODY;
            end
          end
        T_BODY:
          if (tx_valid) begin
            tb[AW'(tn)] <= tx_data;
            tn <= tn + 1'b1;
            tbody <= tbody - 1'b1;
            if (tbody == 3'd1) ts <= T_GATH;
          end
        T_GATH:
          if (tx_valid && tx_ready) begin
            if (h_bad) ev_err <= 1'b1;
            else begin
              tb[AW'(tn)] <= {tx_data[31:24], 4'(p_req), 4'(p_snp), tx_data[15:0]};
              oq = oq + p_req; os = os + p_snp;
              pq = pq - p_req; ps = ps - p_snp;
              if (h_ty == 4'd1) cq = cq - 1'b1;
              if (h_ty == 4'd2) cs = cs - 1'b1;
              tn <= tn + 1'b1; tbody <= 3'(h_ln - 1'b1);
              if (h_ln != 4'd1) ts <= T_BODY;
            end
          end else begin
            tp <= '0; ts <= T_TLP;
          end
        default:                                          // T_TLP
          if (tlp_tx_ready) begin
            tp <= tp + 1'b1;
            if (tlp_tx_last) begin
              ts <= T_IDLE; tn <= '0; tag <= tag + 1'b1;
            end
          end
      endcase
      // credits to return wait CRT clocks for a message to carry them
      if (ts != T_IDLE || pq == '0 && ps == '0) idle <= '0;
      else if (32'(idle) != CRT) idle <= idle + 1'b1;

      p_req <= pq; p_snp <= ps; c_req <= cq; c_snp <= cs; o_req <= oq; o_snp <= os;
    end
endmodule
