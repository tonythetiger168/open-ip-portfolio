// SPDX-License-Identifier: Apache-2.0
// UALink UPLI completer: concurrent SVA against an independent reference
// model, plus functional coverage.
//  * The model keeps its own memory, request and data queues, the credits
//    out on both input channels and held on both response channels, and
//    steps the request being executed (take, data beats, response beats)
//    clock by clock, predicting every response, credit and event.
//  Every output is compared on every clock.
`include "cov_macros.svh"
module UALink_sva #(
  parameter int MW = 16, RQ = 4, DQ = 8
)(
  input logic        clk, rst_n,
  input logic        req_valid,
  input logic [2:0]  req_cmd,
  input logic [7:0]  req_tag,
  input logic [15:0] req_addr,
  input logic [2:0]  req_len,
  input logic        req_crd,
  input logic        od_valid,
  input logic [63:0] od_data,
  input logic [7:0]  od_be,
  input logic        od_last, od_crd,
  input logic        rd_valid,
  input logic [7:0]  rd_tag,
  input logic [63:0] rd_data,
  input logic        rd_last,
  input logic [1:0]  rd_status,
  input logic        rd_crd,
  input logic        wr_valid,
  input logic [7:0]  wr_tag,
  input logic [1:0]  wr_status,
  input logic        wr_crd, ev_err, ev_proto
);
  `COV_CLOCKING(clk, !rst_n)
  localparam int IDLE = 0, DATA = 1, READ = 2, RESP = 3;

  logic [63:0] m [0:MW-1];
  logic [29:0] q [$];                     // {cmd, tag, addr, len}
  logic [72:0] d [$];                     // {data, be, last}
  int          gq, gd, hr, hw;            // credits out (request, data), held (read, write responses)
  // the request being executed
  int          st, cmd, w, len, stat, left, beat;
  logic [7:0]  tag;
  logic [63:0] op [0:1];
  // expected outputs
  bit          o_rd, o_rl, o_wr, o_err, o_proto, o_qc, o_dc;
  logic [7:0]  o_rt, o_wt;
  logic [63:0] o_rdat;
  int          o_rs, o_ws;

  // coverage
  bit v_rd [0:7], v_wr [0:7], v_add, v_swp, v_cas_hit, v_cas_miss, v_bad_cmd, v_bad_align, v_bad_atlen, v_ur_rd, v_ur_wr;
  bit v_ur_at, v_be_part, v_rd_wait, v_wr_wait, v_at_wait, v_data_wait, v_last_early, v_last_missing, v_nocrd_req;
  bit v_nocrd_od, v_over_rd, v_over_wr, v_q_full, v_d_full, v_data_ahead, v_add_carry;

  always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      for (int i = 0; i < MW; i++) m[i] = 0;
      q.delete(); d.delete();
      gq = 0; gd = 0; hr = 0; hw = 0;
      st = IDLE; cmd = 0; w = 0; len = 0; stat = 0; left = 0; beat = 0; tag = 0; op[0] = 0; op[1] = 0;
      {o_rd, o_rl, o_wr, o_err, o_proto, o_qc, o_dc} = '0;
      o_rt = 0; o_wt = 0; o_rdat = 0; o_rs = 0; o_ws = 0;
    end else begin : b_step
      int nq0, nd0;
      bit qpop, dpop;
      {o_rd, o_wr, o_err, o_proto, o_qc, o_dc} = '0;
      nq0 = q.size(); nd0 = d.size(); qpop = 0; dpop = 0;
      if (nq0 == RQ) v_q_full = 1;
      if (nd0 == DQ) v_d_full = 1;
      // ---- execution
      case (st)
        IDLE: if (nq0 != 0) begin : b_take
          logic [29:0] r;
          bit at, bad;
          r = q.pop_front(); qpop = 1;
          cmd = r[29:27]; tag = r[26:19]; len = r[2:0]; beat = 0;
          at = cmd >= 2 && cmd <= 4;
          bad = cmd > 4 || r[5:3] != 0 || at && len != 0;
          stat = bad ? 2 : int'(r[18:6]) + (at ? 0 : len) >= MW ? 1 : 0;
          w = int'(r[18:6]) % MW;
          if (cmd > 4) v_bad_cmd = 1;
          else if (r[5:3] != 0) v_bad_align = 1;
          else if (at && len != 0) v_bad_atlen = 1;
          else if (stat == 1) begin if (cmd == 0) v_ur_rd = 1; else if (cmd == 1) v_ur_wr = 1; else v_ur_at = 1; end
          left = cmd == 1 ? len + 1 : cmd == 2 || cmd == 3 ? 1 : cmd == 4 ? 2 : 0;
          if (left != 0 && nd0 >= left) v_data_ahead = 1;
          st = left != 0 ? DATA : cmd == 0 ? READ : RESP;
        end
        DATA: if (nd0 != 0) begin : b_beat
          logic [72:0] b;
          b = d.pop_front(); dpop = 1;
          if (b[0] != (left == 1)) begin
            o_proto = 1;
            if (b[0]) v_last_early = 1; else v_last_missing = 1;
          end
          if (cmd == 1 && stat == 0) begin
            for (int k = 0; k < 8; k++) if (b[1 + k]) m[w + beat][8*k +: 8] = b[9 + 8*k +: 8];
            if (b[8:1] != 8'hFF && b[8:1] != 8'h00) v_be_part = 1;
          end
          if (beat < 2) op[beat] = b[72:9];
          beat++; left--;
          if (left == 0) st = RESP;
        end else v_data_wait = 1;
        READ: if (hr != 0) begin
          hr--;
          o_rd = 1; o_rt = tag; o_rs = stat; o_err = stat != 0;
          o_rdat = stat == 0 ? m[w + beat] : 0;
          o_rl = stat != 0 || beat == len;
          if (stat == 0 && beat == len) v_rd[len] = 1;
          beat++;
          if (o_rl) st = IDLE;
        end else v_rd_wait = 1;
        default:
          if (cmd == 1 || cmd > 4) begin
            if (hw != 0) begin
              hw--;
              o_wr = 1; o_wt = tag; o_ws = stat; o_err = stat != 0;
              if (cmd == 1 && stat == 0) v_wr[len] = 1;
              st = IDLE;
            end else v_wr_wait = 1;
          end else if (hr != 0) begin : b_atomic
            logic [63:0] old;
            hr--;
            old = m[w];
            o_rd = 1; o_rt = tag; o_rs = stat; o_rl = 1; o_err = stat != 0;
            o_rdat = stat == 0 ? old : 0;
            if (stat == 0) begin
              case (cmd)
                2: begin m[w] = old + op[0]; v_add = 1; if ({1'b0, old} + {1'b0, op[0]} > 65'h0_FFFF_FFFF_FFFF_FFFF) v_add_carry = 1; end
                3: begin m[w] = op[0]; v_swp = 1; end
                default: if (old == op[0]) begin m[w] = op[1]; v_cas_hit = 1; end else v_cas_miss = 1;
              endcase
            end
            st = IDLE;
          end else v_at_wait = 1;
      endcase
      // ---- inputs
      if (req_valid) begin
        if (gq == 0) begin o_proto = 1; v_nocrd_req = 1; end
        else begin gq--; q.push_back({req_cmd, req_tag, req_addr, req_len}); end
      end
      if (od_valid) begin
        if (gd == 0) begin o_proto = 1; v_nocrd_od = 1; end
        else begin gd--; d.push_back({od_data, od_be, od_last}); end
      end
      if (rd_crd) begin if (hr == 15) begin o_proto = 1; v_over_rd = 1; end else hr++; end
      if (wr_crd) begin if (hw == 15) begin o_proto = 1; v_over_wr = 1; end else hw++; end
      // ---- credits for free slots
      if (gq + q.size() < RQ) begin o_qc = 1; gq++; end
      if (gd + d.size() < DQ) begin o_dc = 1; gd++; end
    end
  end

  // ---------------- assertions ----------------
  `SVA_INV(a_rd, rd_valid == o_rd && (!o_rd || rd_tag == o_rt && rd_data == o_rdat && rd_last == o_rl && int'(rd_status) == o_rs))
  `SVA_INV(a_wr, wr_valid == o_wr && (!o_wr || wr_tag == o_wt && int'(wr_status) == o_ws))
  `SVA_INV(a_credits, req_crd == o_qc && od_crd == o_dc)
  `SVA_INV(a_events, ev_err == o_err && ev_proto == o_proto)
  `SVA_RST(a_reset, !rst_n, !req_crd && !od_crd && !rd_valid && !wr_valid && !ev_err && !ev_proto)

  // ---------------- functional coverage ----------------
  `FC(read_1_beats, v_rd[0])
  `FC(read_2_beats, v_rd[1])
  `FC(read_3_beats, v_rd[2])
  `FC(read_4_beats, v_rd[3])
  `FC(read_5_beats, v_rd[4])
  `FC(read_6_beats, v_rd[5])
  `FC(read_7_beats, v_rd[6])
  `FC(read_8_beats, v_rd[7])
  `FC(write_1_beats, v_wr[0])
  `FC(write_2_beats, v_wr[1])
  `FC(write_3_beats, v_wr[2])
  `FC(write_4_beats, v_wr[3])
  `FC(write_5_beats, v_wr[4])
  `FC(write_6_beats, v_wr[5])
  `FC(write_7_beats, v_wr[6])
  `FC(write_8_beats, v_wr[7])
  `FC(fetch_add, v_add)
  `FC(fetch_add_carry_out, v_add_carry)
  `FC(swap, v_swp)
  `FC(cas_match, v_cas_hit)
  `FC(cas_no_match, v_cas_miss)
  `FC(bad_command, v_bad_cmd)
  `FC(bad_alignment, v_bad_align)
  `FC(bad_atomic_length, v_bad_atlen)
  `FC(read_past_memory, v_ur_rd)
  `FC(write_past_memory, v_ur_wr)
  `FC(atomic_past_memory, v_ur_at)
  `FC(write_partial_bytes, v_be_part)
  `FC(read_waits_for_credit, v_rd_wait)
  `FC(write_response_waits_for_credit, v_wr_wait)
  `FC(atomic_waits_for_credit, v_at_wait)
  `FC(waits_for_data, v_data_wait)
  `FC(data_ahead_of_request, v_data_ahead)
  `FC(last_early, v_last_early)
  `FC(last_missing, v_last_missing)
  `FC(request_without_credit, v_nocrd_req)
  `FC(data_without_credit, v_nocrd_od)
  `FC(read_credit_past_15, v_over_rd)
  `FC(write_credit_past_15, v_over_wr)
  `FC(request_slots_full, v_q_full)
  `FC(data_slots_full, v_d_full)
  // a response going out with requests queued as reset lands (taken on the
  // falling edge, before the asynchronous reset clears them)
  bit busy_n = 0;
  always @(negedge clk) busy_n <= rd_valid && q.size() != 0;
  `FC_RST(reset_in_traffic, !rst_n && busy_n)
endmodule

bind UALink_top UALink_sva #(.MW(MW), .RQ(RQ), .DQ(DQ)) u_sva (.*);
