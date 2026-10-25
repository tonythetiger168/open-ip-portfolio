// SPDX-License-Identifier: Apache-2.0
// ============================================================================
// UALink_top v2.0: a UALink completer on the UPLI (UALink Protocol Level
// Interface): reads, writes and atomics to a local memory over the four
// UPLI channels, each credited
// ----------------------------------------------------------------------------
//  - Request channel (req_*): cmd 0 READ, 1 WRITE, 2 FETCH_ADD, 3 SWAP,
//    4 CAS (5..7 invalid), an 8-bit tag, a byte address and len (beats - 1,
//    beats of 8 bytes; atomics are one 64-bit beat, len 0). The completer
//    grants RQ request credits (req_crd pulses, one per free slot).
//  - Originator data channel (od_*): the data of WRITE (len + 1 beats with
//    byte enables), FETCH_ADD / SWAP (one beat: the operand) and CAS (two
//    beats: compare, then swap value), in request order; od_last marks
//    each request's last beat. DQ data credits (od_crd).
//  - Read response channel (rd_*): READ data (len + 1 beats, rd_last on
//    the last) and the old value of an atomic (one beat), with a status;
//    the originator grants a credit per beat (rd_crd).
//  - Write response channel (wr_*): WRITE and invalid commands, one
//    response with a status; credited by the originator (wr_crd).
//  - Status: 0 OK; 1 UR, the access runs past the MW-word memory; 2 BAD,
//    an invalid command, an address not 8-byte aligned or an atomic with
//    len != 0. A failed access has no effect; a failed read answers one
//    beat (data 0). Its data beats are still taken.
//  - Requests are executed in order, one at a time: a clock to take the
//    request, a clock per data beat, a clock per response beat (waiting
//    for a credit). An atomic updates memory as its response goes out.
//  - ev_err: a response with a non-OK status. ev_proto: a request or data
//    beat without a credit (dropped), an od_last that does not match the
//    beat count (the beat count wins), a response credit past 15
//    (ignored).
//  Not implemented: the UPLI virtual channels and their ordering rules,
//  multiple outstanding requests and out-of-order completion, the full
//  request field set (address width, size and byte-granular reads,
//  metadata, the atomic set beyond these three, poison), the UALink
//  transaction, data link and physical layers below UPLI. Field widths
//  and encodings are ours; they have not been checked against a UALink
//  originator.
// ============================================================================
module UALink_top #(
  parameter int MW = 16,                // memory words of 64 bits, power of 2
  parameter int RQ = 4,                 // request slots (credits), power of 2
  parameter int DQ = 8                  // data beat slots (credits), power of 2
)(
  input  logic        clk,
  input  logic        rst_n,
  // request channel
  input  logic        req_valid,
  input  logic [2:0]  req_cmd,
  input  logic [7:0]  req_tag,
  input  logic [15:0] req_addr,
  input  logic [2:0]  req_len,
  output logic        req_crd,
  // originator data channel
  input  logic        od_valid,
  input  logic [63:0] od_data,
  input  logic [7:0]  od_be,
  input  logic        od_last,
  output logic        od_crd,
  // read response channel
  output logic        rd_valid,
  output logic [7:0]  rd_tag,
  output logic [63:0] rd_data,
  output logic        rd_last,
  output logic [1:0]  rd_status,
  input  logic        rd_crd,
  // write response channel
  output logic        wr_valid,
  output logic [7:0]  wr_tag,
  output logic [1:0]  wr_status,
  input  logic        wr_crd,
  // events
  output logic        ev_err,
  output logic        ev_proto
);
  localparam int QW = $clog2(RQ);
  localparam int DW = $clog2(DQ);
  localparam int MA = $clog2(MW);
  localparam logic [2:0] C_RD = 3'd0, C_WR = 3'd1, C_ADD = 3'd2, C_SWP = 3'd3, C_CAS = 3'd4;

  logic [63:0] mem [0:MW-1];

  // ---------------- request and data slots ----------------
  logic [29:0]   rq [0:RQ-1];           // {cmd, tag, addr, len}
  logic [QW:0]   rqw, rqr, rg;
  wire  [QW:0]   rq_n = rqw - rqr;
  wire  [29:0]   rh = rq[rqr[QW-1:0]];
  logic [72:0]   dq [0:DQ-1];           // {data, be, last}
  logic [DW:0]   dqw, dqr, dg;
  wire  [DW:0]   dq_n = dqw - dqr;
  wire  [72:0]   dh = dq[dqr[DW-1:0]];
  wire  [63:0]   dh_data = dh[72:9];
  wire  [7:0]    dh_be = dh[8:1];
  wire           dh_last = dh[0];

  // ---------------- the request being executed ----------------
  typedef enum logic [1:0] {E_IDLE, E_DATA, E_RD, E_RSP} e_t;
  e_t            es;
  logic [2:0]    x_cmd;
  logic [7:0]    x_tag;
  logic [MA-1:0] x_w;                   // word
  logic [2:0]    x_len;
  logic [1:0]    x_st;                  // status
  logic [3:0]    x_nb;                  // data beats left
  logic [2:0]    x_i;                   // beat
  logic [63:0]   x_op0, x_op1;          // atomic operands
  logic [3:0]    rc, wc;                // response credits held

  // decode of the head request
  wire [2:0]  h_cmd = rh[29:27];
  wire [15:0] h_addr = rh[18:3];
  wire [2:0]  h_len = rh[2:0];
  wire        h_at = h_cmd == C_ADD || h_cmd == C_SWP || h_cmd == C_CAS;
  wire        h_bad = h_cmd > C_CAS || h_addr[2:0] != 3'd0 || h_at && h_len != 3'd0;
  wire [13:0] h_end = 14'(h_addr[15:3]) + 14'(h_len);        // an atomic with len != 0 is BAD anyway
  wire [1:0]  h_st = h_bad ? 2'd2 : h_end >= 14'(MW) ? 2'd1 : 2'd0;
  wire [3:0]  h_nb = h_cmd == C_WR ? 4'(h_len) + 4'd1 : h_cmd == C_ADD || h_cmd == C_SWP ? 4'd1 :
                     h_cmd == C_CAS ? 4'd2 : 4'd0;

  // the atomic's new value
  wire [63:0] a_old = mem[x_w];
  wire [63:0] a_new = x_cmd == C_ADD ? a_old + x_op0 : x_cmd == C_SWP ? x_op0 : a_old == x_op0 ? x_op1 : a_old;

  always_ff @(posedge clk or negedge rst_n)
    if (!rst_n) begin
      for (int i = 0; i < MW; i++) mem[i] <= '0;
      for (int i = 0; i < RQ; i++) rq[i] <= '0;
      for (int i = 0; i < DQ; i++) dq[i] <= '0;
      rqw <= '0; rqr <= '0; rg <= '0; dqw <= '0; dqr <= '0; dg <= '0;
      req_crd <= 1'b0; od_crd <= 1'b0;
      es <= E_IDLE; x_cmd <= '0; x_tag <= '0; x_w <= '0; x_len <= '0; x_st <= '0; x_nb <= '0; x_i <= '0;
      x_op0 <= '0; x_op1 <= '0; rc <= '0; wc <= '0;
      rd_valid <= 1'b0; rd_tag <= '0; rd_data <= '0; rd_last <= 1'b0; rd_status <= '0;
      wr_valid <= 1'b0; wr_tag <= '0; wr_status <= '0;
      ev_err <= 1'b0; ev_proto <= 1'b0;
    end else begin : b_main
      logic [QW:0] rgg;
      logic [DW:0] dgg;
      logic [3:0]  rcc, wcc;
      bit          rpop, dpop, rpush, dpush;
      rgg = rg; dgg = dg; rcc = rc; wcc = wc;
      rpop = 1'b0; dpop = 1'b0; rpush = 1'b0; dpush = 1'b0;
      req_crd <= 1'b0; od_crd <= 1'b0; rd_valid <= 1'b0; wr_valid <= 1'b0; ev_err <= 1'b0; ev_proto <= 1'b0;

      // ---- the engine, on the slots and credits as they stand
      case (es)
        E_IDLE: if (rq_n != '0) begin
          rpop = 1'b1;
          x_cmd <= h_cmd; x_tag <= rh[26:19]; x_w <= h_addr[MA+2:3]; x_len <= h_len; x_st <= h_st;
          x_nb <= h_nb; x_i <= '0;
          es <= h_nb != 4'd0 ? E_DATA : h_cmd == C_RD ? E_RD : E_RSP;
        end
        E_DATA: if (dq_n != '0) begin
          dpop = 1'b1;
          if (dh_last != (x_nb == 4'd1)) ev_proto <= 1'b1;
          if (x_cmd == C_WR && x_st == 2'd0)
            for (int b = 0; b < 8; b++)
              if (dh_be[b]) mem[x_w + MA'(x_i)][8*b +: 8] <= dh_data[8*b +: 8];
          if (x_i == 3'd0) x_op0 <= dh_data; else x_op1 <= dh_data;
          x_i <= x_i + 1'b1; x_nb <= x_nb - 1'b1;
          if (x_nb == 4'd1) es <= E_RSP;
        end
        E_RD: if (rcc != '0) begin
          rcc = rcc - 1'b1;
          rd_valid <= 1'b1; rd_tag <= x_tag; rd_status <= x_st;
          rd_data <= x_st == 2'd0 ? mem[x_w + MA'(x_i)] : '0;
          rd_last <= x_st != 2'd0 || x_i == x_len;
          ev_err <= x_st != 2'd0;
          x_i <= x_i + 1'b1;
          if (x_st != 2'd0 || x_i == x_len) es <= E_IDLE;
        end
        default:                                         // E_RSP
          if (x_cmd == C_WR || x_cmd > C_CAS) begin
            if (wcc != '0) begin
              wcc = wcc - 1'b1;
              wr_valid <= 1'b1; wr_tag <= x_tag; wr_status <= x_st; ev_err <= x_st != 2'd0;
              es <= E_IDLE;
            end
          end else if (rcc != '0) begin                  // an atomic
            rcc = rcc - 1'b1;
            rd_valid <= 1'b1; rd_tag <= x_tag; rd_status <= x_st; rd_last <= 1'b1;
            rd_data <= x_st == 2'd0 ? a_old : '0;
            ev_err <= x_st != 2'd0;
            if (x_st == 2'd0) mem[x_w] <= a_new;
            es <= E_IDLE;
          end
      endcase

      // ---- request and data channels
      if (req_valid) begin
        if (rgg == '0) ev_proto <= 1'b1;
        else begin
          rgg = rgg - 1'b1; rpush = 1'b1;
          rq[rqw[QW-1:0]] <= {req_cmd, req_tag, req_addr, req_len};
        end
      end
      if (od_valid) begin
        if (dgg == '0) ev_proto <= 1'b1;
        else begin
          dgg = dgg - 1'b1; dpush = 1'b1;
          dq[dqw[DW-1:0]] <= {od_data, od_be, od_last};
        end
      end
      rqw <= rqw + (QW + 1)'(rpush); rqr <= rqr + (QW + 1)'(rpop);
      dqw <= dqw + (DW + 1)'(dpush); dqr <= dqr + (DW + 1)'(dpop);

      // ---- response credits from the originator
      if (rd_crd) begin
        if (rcc == 4'd15) ev_proto <= 1'b1;
        else rcc = rcc + 1'b1;
      end
      if (wr_crd) begin
        if (wcc == 4'd15) ev_proto <= 1'b1;
        else wcc = wcc + 1'b1;
      end

      // ---- credits for free slots
      if (32'(rgg) + 32'(rq_n) + 32'(rpush) - 32'(rpop) < RQ) begin req_crd <= 1'b1; rgg = rgg + 1'b1; end
      if (32'(dgg) + 32'(dq_n) + 32'(dpush) - 32'(dpop) < DQ) begin od_crd <= 1'b1; dgg = dgg + 1'b1; end
      rg <= rgg; dg <= dgg; rc <= rcc; wc <= wcc;
    end
endmodule
