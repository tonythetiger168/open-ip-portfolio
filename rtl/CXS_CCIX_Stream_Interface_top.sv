// SPDX-License-Identifier: Apache-2.0
// ============================================================================
// CXS_CCIX_Stream_Interface_top v2.0: AMBA CXS (credited eXtensible Stream)
// port, one transmit and one receive interface, carrying packets of
// 32-bit words in 4-word flits
// ----------------------------------------------------------------------------
//  - Flit: CXSDATA 128 bits (word 0 in bits 31:0) and CXSCNTL {START[1:0],
//    START0_PTR, START1_PTR, END[1:0], END0_PTR, END1_PTR,
//    END_ERROR[1:0]} (pointers are word indexes). At most two packets
//    start and two end in a flit; START[1] / END[1] only with START[0] /
//    END[0]. Words between a start and an end belong to that packet, a
//    packet open at the end of a flit goes on in the next one, other
//    words are not used.
//  - Link: each direction has ACTIVEREQ (transmitter) and ACTIVEACK
//    (receiver): STOP (0, 0), ACTIVATE (1, 0), RUN (1, 1), DEACTIVATE
//    (0, 1). The receiver grants credits (CRDGNT pulses) only in RUN, one
//    per free flit buffer; the transmitter sends a flit per credit and, in
//    DEACTIVATE, returns the credits it holds (CRDRTN pulses); the
//    receiver drops ACTIVEACK once no credit is out (credits the
//    transmitter still holds then are dropped). DEACTHINT asks the
//    transmitter to deactivate.
//  - Transmit: with tx_en set the port activates its transmit side. Words
//    written on tx_* (tx_last ends a packet, tx_err with it sets
//    END_ERROR) fill a flit; the flit is sent (in RUN, with a credit) when
//    it holds 4 words, or at a packet end when its second packet ended,
//    or no word is waiting. A packet may wait for words in the
//    middle of a flit. With tx_en clear or DEACTHINT seen, the side
//    deactivates at the next packet boundary with the flit sent.
//  - Receive: with rx_en set the port answers ACTIVEREQ and grants RXF
//    credits; clearing rx_en raises DEACTHINT. A flit is checked (START /
//    END order against the open packet, at least one word used); its used
//    words are handed out on rx_* with rx_last and rx_err (END_ERROR).
//    A flit without a credit is dropped with ev_crd; a bad flit is dropped
//    with ev_cntl, and a packet it leaves open is closed with one extra
//    word 0 marked rx_last and rx_err. A credit returned beyond those
//    granted, and a grant past 15 credits held, also set ev_crd.
//  Not implemented: other data widths and more packets per flit, the CXS
//  continuous-delivery / CXSLAST options, CXSPRCLTYPE, CXSDATACHECK,
//  credit return without DEACTIVATE as a flow-control tool, the CCIX
//  packet formats the stream carries. Field positions are ours; they have
//  not been checked against a CXS peer.
// ============================================================================
module CXS_CCIX_Stream_Interface_top #(
  parameter int RXF = 4                 // receive flit buffers (credits granted), 2..15
)(
  input  logic         clk,
  input  logic         rst_n,
  input  logic         tx_en,           // activate the transmit side
  input  logic         rx_en,           // accept the peer's activation
  // packets to send
  input  logic         tx_valid,
  output logic         tx_ready,
  input  logic [31:0]  tx_data,
  input  logic         tx_last,
  input  logic         tx_err,
  // packets received
  output logic         rx_valid,
  input  logic         rx_ready,
  output logic [31:0]  rx_data,
  output logic         rx_last,
  output logic         rx_err,
  // CXS transmit interface
  output logic         cxs_tx_valid,
  output logic [127:0] cxs_tx_data,
  output logic [13:0]  cxs_tx_cntl,
  input  logic         cxs_tx_crdgnt,
  output logic         cxs_tx_crdrtn,
  output logic         cxs_tx_activereq,
  input  logic         cxs_tx_activeack,
  input  logic         cxs_tx_deacthint,
  // CXS receive interface
  input  logic         cxs_rx_valid,
  input  logic [127:0] cxs_rx_data,
  input  logic [13:0]  cxs_rx_cntl,
  output logic         cxs_rx_crdgnt,
  input  logic         cxs_rx_crdrtn,
  input  logic         cxs_rx_activereq,
  output logic         cxs_rx_activeack,
  output logic         cxs_rx_deacthint,
  // status and events
  output logic [1:0]   tx_link,         // 0 STOP, 1 ACTIVATE, 2 RUN, 3 DEACTIVATE
  output logic [1:0]   rx_link,         // 0 STOP, 2 RUN, 3 DEACTIVATE
  output logic [3:0]   tx_credits,      // credits held
  output logic         ev_crd,          // credit error: flit without a credit, return or grant too many
  output logic         ev_cntl          // flit with bad START / END, or no word used: dropped
);
  localparam int FW = $clog2(RXF);
  localparam int GW = $clog2(RXF + 1);

  // ---------------- transmit ----------------
  typedef enum logic [1:0] {T_STOP, T_ACT, T_RUN, T_DEACT} t_t;
  t_t          ts;
  logic [31:0] fd [0:3];                // flit being filled
  logic [2:0]  fw;                      // its words
  logic [1:0]  ns, ne;                  // packets started / ended in it
  logic [1:0]  sp0, sp1, ep0, ep1;
  logic [1:0]  ee;
  logic        t_ip;                    // a packet open
  logic [3:0]  cr;                      // credits held

  // a flit whose second packet ended takes no more packets (two started
  // and none open means two ended)
  wire t_closed = fw != 3'd0 && !t_ip && ne == 2'd2;
  wire t_full = fw == 3'd4 || t_closed || fw != 3'd0 && !t_ip && !tx_valid;
  wire t_send = t_full && ts == T_RUN && cr != 4'd0;
  assign tx_ready = fw != 3'd4 && !t_closed;

  assign cxs_tx_activereq = ts == T_ACT || ts == T_RUN;
  assign tx_link = ts;
  assign tx_credits = cr;

  // ---------------- receive ----------------
  typedef enum logic [1:0] {R_STOP, R_RUN = 2'd2, R_DEACT = 2'd3} r_t;
  r_t            rs;
  logic [127:0]  bd [0:RXF-1];          // flit buffers
  logic [3:0]    bv [0:RXF-1], bl [0:RXF-1], be [0:RXF-1];   // word used, last, error
  logic [FW:0]   bw, br;                // write, read
  logic [2:0]    bdone;                 // words 0..2 of the head buffer handed out (word 3 is its last)
  logic [GW-1:0] g;                     // credits out
  logic          r_ip;                  // a packet open

  // the flit on cxs_rx_*: which words it uses, where packets end, whether
  // its START / END agree with the open packet
  logic [3:0] u_v, u_l, u_e;
  logic       u_bad, u_ip;
  always_comb begin : b_unpack
    logic [1:0] si, ei, nst, nen;
    logic       ip;
    nst = cxs_rx_cntl[13] ? 2'd2 : {1'b0, cxs_rx_cntl[12]};
    nen = cxs_rx_cntl[7] ? 2'd2 : {1'b0, cxs_rx_cntl[6]};
    u_bad = cxs_rx_cntl[13:12] == 2'b10 || cxs_rx_cntl[7:6] == 2'b10;
    ip = r_ip; si = 2'd0; ei = 2'd0;
    u_v = '0; u_l = '0; u_e = '0;
    for (int w = 0; w < 4; w++) begin
      if (si != nst && (si == 2'd0 ? cxs_rx_cntl[11:10] : cxs_rx_cntl[9:8]) == 2'(w)) begin
        if (ip) u_bad = 1'b1;
        ip = 1'b1; si = si + 1'b1;
      end
      if (ei != nen && (ei == 2'd0 ? cxs_rx_cntl[5:4] : cxs_rx_cntl[3:2]) == 2'(w)) begin
        if (!ip) u_bad = 1'b1;
        u_l[w] = 1'b1; u_e[w] = cxs_rx_cntl[ei == 2'd0 ? 0 : 1];
        u_v[w] = 1'b1;
        ip = 1'b0; ei = ei + 1'b1;
      end else if (ip) u_v[w] = 1'b1;
    end
    if (si != nst || ei != nen || u_v == '0) u_bad = 1'b1;
    u_ip = ip;
  end

  wire [2:0] h_left = bv[br[FW-1:0]][2:0] & ~bdone;   // words 0..2 still to hand out
  wire [1:0] h_i = h_left[0] ? 2'd0 : h_left[1] ? 2'd1 : h_left[2] ? 2'd2 : 2'd3;
  wire [FW:0] b_used = bw - br;
  assign rx_valid = bw != br;
  assign rx_data = bd[br[FW-1:0]][32 * h_i +: 32];
  assign rx_last = bl[br[FW-1:0]][h_i];
  assign rx_err = be[br[FW-1:0]][h_i];
  assign cxs_rx_activeack = rs != R_STOP;
  assign cxs_rx_deacthint = rs == R_RUN && !rx_en;
  assign rx_link = rs;

  always_ff @(posedge clk or negedge rst_n)
    if (!rst_n) begin
      ts <= T_STOP; fw <= '0; ns <= '0; ne <= '0; sp0 <= '0; sp1 <= '0; ep0 <= '0; ep1 <= '0; ee <= '0;
      t_ip <= 1'b0; cr <= '0;
      for (int i = 0; i < 4; i++) fd[i] <= '0;
      cxs_tx_valid <= 1'b0; cxs_tx_data <= '0; cxs_tx_cntl <= '0; cxs_tx_crdrtn <= 1'b0;
      rs <= R_STOP; bw <= '0; br <= '0; bdone <= '0; g <= '0; r_ip <= 1'b0; cxs_rx_crdgnt <= 1'b0;
      for (int i = 0; i < RXF; i++) begin bd[i] <= '0; bv[i] <= '0; bl[i] <= '0; be[i] <= '0; end
      ev_crd <= 1'b0; ev_cntl <= 1'b0;
    end else begin : b_main
      logic [3:0]  c;
      logic [GW:0] gg;
      logic [FW:0] used;
      c = cr; gg = (GW + 1)'(g); used = b_used;
      ev_crd <= 1'b0; ev_cntl <= 1'b0;
      cxs_tx_valid <= 1'b0; cxs_tx_crdrtn <= 1'b0; cxs_rx_crdgnt <= 1'b0;

      // ---- transmit: credits in
      if (cxs_tx_crdgnt) begin
        if (c == 4'd15) ev_crd <= 1'b1;
        else c = c + 1'b1;
      end
      // ---- transmit: a word into the flit
      if (tx_valid && tx_ready) begin
        fd[fw[1:0]] <= tx_data;
        fw <= fw + 1'b1;
        if (!t_ip) begin
          if (ns == 2'd0) sp0 <= fw[1:0]; else sp1 <= fw[1:0];
          ns <= ns + 1'b1;
        end
        if (tx_last) begin
          if (ne == 2'd0) begin ep0 <= fw[1:0]; ee[0] <= tx_err; end
          else begin ep1 <= fw[1:0]; ee[1] <= tx_err; end
          ne <= ne + 1'b1;
        end
        t_ip <= !tx_last;
      end
      // ---- transmit: the flit out
      if (t_send) begin
        c = c - 1'b1;
        cxs_tx_valid <= 1'b1;
        cxs_tx_data <= {fd[3], fd[2], fd[1], fd[0]};
        cxs_tx_cntl <= {ns == 2'd2, ns != 2'd0, sp0, sp1, ne == 2'd2, ne != 2'd0, ep0, ep1, ee};
        fw <= '0; ns <= '0; ne <= '0; sp0 <= '0; sp1 <= '0; ep0 <= '0; ep1 <= '0; ee <= '0;
      end
      // ---- transmit: link
      case (ts)
        T_STOP:  if (tx_en && !cxs_tx_activeack) ts <= T_ACT;
        T_ACT:   if (cxs_tx_activeack) ts <= T_RUN;
        T_RUN:   if ((!tx_en || cxs_tx_deacthint) && !t_ip && fw == 3'd0) ts <= T_DEACT;
        default: begin                                    // T_DEACT: credits back
          if (c != 4'd0) begin
            c = c - 1'b1;
            cxs_tx_crdrtn <= 1'b1;
          end
          if (!cxs_tx_activeack) begin
            ts <= T_STOP;
            c = '0;
          end
        end
      endcase

      // ---- receive: a credit back
      if (cxs_rx_crdrtn) begin
        if (gg == '0) ev_crd <= 1'b1;
        else gg = gg - 1'b1;
      end
      // ---- receive: a flit
      if (cxs_rx_valid) begin
        if (gg == '0) ev_crd <= 1'b1;
        else begin
          gg = gg - 1'b1;
          if (u_bad) begin
            ev_cntl <= 1'b1;
            if (r_ip) begin                               // close the open packet
              bd[bw[FW-1:0]] <= '0;
              bv[bw[FW-1:0]] <= 4'b0001; bl[bw[FW-1:0]] <= 4'b0001; be[bw[FW-1:0]] <= 4'b0001;
              bw <= bw + 1'b1; used = used + 1'b1;
              r_ip <= 1'b0;
            end
          end else begin
            bd[bw[FW-1:0]] <= cxs_rx_data;
            bv[bw[FW-1:0]] <= u_v; bl[bw[FW-1:0]] <= u_l; be[bw[FW-1:0]] <= u_e;
            bw <= bw + 1'b1; used = used + 1'b1;
            r_ip <= u_ip;
          end
        end
      end
      // ---- receive: a word out
      if (rx_valid && rx_ready) begin
        if (({1'b0, bdone} | (4'd1 << h_i)) == bv[br[FW-1:0]]) begin
          br <= br + 1'b1; bdone <= '0; used = used - 1'b1;
        end else bdone <= bdone | 3'(4'd1 << h_i);
      end
      // ---- receive: link and credits out
      case (rs)
        R_STOP: if (cxs_rx_activereq && rx_en) rs <= R_RUN;
        R_RUN: begin
          if (32'(used) + 32'(gg) < RXF) begin
            cxs_rx_crdgnt <= 1'b1;
            gg = gg + 1'b1;
          end
          if (!cxs_rx_activereq) rs <= R_DEACT;
        end
        default: if (gg == '0) rs <= R_STOP;              // R_DEACT
      endcase

      cr <= c; g <= GW'(gg);
    end
endmodule
