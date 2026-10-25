// SPDX-License-Identifier: Apache-2.0
// CXL.mem Type 3 device: concurrent SVA against an independent reference
// model, plus functional coverage.
//  * The model keeps device memory as bytes, the Req FIFO as queues of
//    fields and the RwD message as queues of beats. Each clock it decides,
//    from its own state, which waiting message is served (round robin on a
//    tie, only when the response channel it needs is free), applies it and
//    builds the response; a DRS message is held as 8 beats.
//  * req_ready, rwd_ready, every NDR and DRS field, every data beat,
//    DevLoad and the event pulses are compared on every clock.
`include "cov_macros.svh"
module CXL_sva #(
  parameter int LINES = 16, RQD = 4
)(
  input logic        clk, rst_n,
  input logic [15:0] hdm_base,
  input logic        req_valid, req_ready,
  input logic [3:0]  req_opcode,
  input logic [1:0]  req_meta_field, req_meta_value,
  input logic [2:0]  req_snp_type,
  input logic [15:0] req_tag, req_addr,
  input logic        rwd_valid, rwd_ready,
  input logic [3:0]  rwd_opcode,
  input logic [1:0]  rwd_meta_field, rwd_meta_value,
  input logic [2:0]  rwd_snp_type,
  input logic [15:0] rwd_tag, rwd_addr,
  input logic        rwd_poison,
  input logic [63:0] rwd_data,
  input logic [7:0]  rwd_be,
  input logic        ndr_valid, ndr_ready,
  input logic [1:0]  ndr_opcode,
  input logic [15:0] ndr_tag,
  input logic [1:0]  ndr_meta_value, ndr_devload,
  input logic        drs_valid, drs_ready,
  input logic [15:0] drs_tag,
  input logic [1:0]  drs_meta_value, drs_devload,
  input logic        drs_poison,
  input logic [63:0] drs_data,
  input logic        drs_last,
  input logic        ev_range, ev_opcode, ev_proto, ev_poison
);
  `COV_CLOCKING(clk, !rst_n)

  // ---------------- model ----------------
  logic [7:0]  mb [0:LINES*64-1];
  logic [1:0]  mmeta [0:LINES-1];
  bit          mpo [0:LINES-1];
  logic [3:0]  q_op [$];
  logic [1:0]  q_mf [$], q_mv [$];
  logic [2:0]  q_snp [$];
  logic [15:0] q_tag [$], q_addr [$];
  logic [63:0] w_d [$];
  logic [7:0]  w_b [$];
  logic [3:0]  h_op;
  logic [1:0]  h_mf, h_mv;
  logic [2:0]  h_snp;
  logic [15:0] h_tag, h_addr;
  bit          h_po;
  bit          req_last;                       // the last one served was a Req
  bit          m_nv, m_dv;
  logic [1:0]  m_nop, m_nmv, m_ndl, m_dmv, m_ddl;
  logic [15:0] m_ntag, m_dtag;
  bit          m_dpo;
  logic [63:0] m_dl [0:7];
  int          m_dc;
  bit          m_rng, m_opc, m_pro, m_poi;

  // what a Req opcode needs: 0 nothing, 1 NDR, 2 DRS
  function automatic int need(input logic [3:0] op);
    case (op)
      4'd1, 4'd2: return 2;
      4'd0, 4'd9, 4'd10: return 1;
      default: return 0;
    endcase
  endfunction
  function automatic logic [1:0] load(input int n);
    if (n == 0) return 2'b00;
    if (n == 1) return 2'b01;
    if (n < RQD - 1) return 2'b10;
    return 2'b11;
  endfunction

  // coverage
  bit v_op [0:15], v_wop [0:15], v_cmp [0:2], v_rng_rd, v_rng_wr, v_rng_inv, v_poi_rd, v_po_set, v_po_clr, v_po_keep;
  bit v_be0, v_be_part, v_res_mf, v_res_snp, v_dl_n [0:3], v_dl_d [0:3], v_tie_q, v_tie_w, v_q_wait_n, v_q_wait_d;
  bit v_w_wait, v_bad_w_busy, v_drs_b2b, v_ndr_b2b, v_wrap, v_spec_out, v_meta_set [0:3], v_rddata_meta, v_ptl_po;

  always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      for (int i = 0; i < LINES * 64; i++) mb[i] = 8'h00;
      for (int l = 0; l < LINES; l++) begin mmeta[l] = 2'b00; mpo[l] = 0; end
      q_op.delete(); q_mf.delete(); q_mv.delete(); q_snp.delete(); q_tag.delete(); q_addr.delete();
      w_d.delete(); w_b.delete();
      req_last = 0; m_nv = 0; m_dv = 0; m_dc = 0;
      {m_rng, m_opc, m_pro, m_poi} = '0;
    end else begin : b_step
      int          nq, k;
      bit          o_nv, o_dv, nfree, dfree, full, cq, cw, sq, sw, wok, in;
      logic [1:0]  dl, mf, mv, old;
      logic [15:0] off;
      int          ln;
      nq = q_op.size(); full = w_d.size() == 8; o_nv = m_nv; o_dv = m_dv;
      nfree = !o_nv || ndr_ready;
      dfree = !o_dv || drs_ready && m_dc == 7;
      wok = h_op == 4'd1 || h_op == 4'd2;
      k = nq != 0 ? need(q_op[0]) : 0;
      cq = nq != 0 && (k == 0 || k == 1 && nfree || k == 2 && dfree);
      cw = full && (!wok || nfree);
      sw = cw && (req_last || !cq);
      sq = cq && !sw;
      dl = load(nq - int'(sq));
      {m_rng, m_opc, m_pro, m_poi} = '0;
      if (cq && cw) begin if (sq) v_tie_q = 1; else v_tie_w = 1; end
      if (nq != 0 && k == 1 && !nfree) v_q_wait_n = 1;
      if (nq != 0 && k == 2 && !dfree) v_q_wait_d = 1;
      if (full && wok && !nfree) v_w_wait = 1;
      if (full && !wok && o_nv && !ndr_ready && sw) v_bad_w_busy = 1;
      // response handshakes
      if (o_nv && ndr_ready) m_nv = 0;
      if (o_dv && drs_ready) begin
        if (m_dc == 7) m_dv = 0;
        m_dc = (m_dc + 1) % 8;
      end
      // a Req served
      if (sq) begin
        logic [3:0] op;
        op = q_op.pop_front(); mf = q_mf.pop_front(); mv = q_mv.pop_front();
        req_last = 1;
        off = q_addr[0] - hdm_base;
        in = off < LINES;
        ln = int'(off);
        if (in && q_addr[0] < hdm_base) v_wrap = 1;
        old = in ? mmeta[ln] : 2'b00;
        if (mf == 2'b01 || mf == 2'b10 || q_snp[0][2]) begin
          m_pro = 1; mf = 2'b11;
          if (q_snp[0][2]) v_res_snp = 1; else v_res_mf = 1;
        end
        v_op[op] = 1;
        if (need(op) != 0 && !in) begin
          m_rng = 1;
          if (need(op) == 2) v_rng_rd = 1; else v_rng_inv = 1;
        end
        if (op == 4'd8 && !in) v_spec_out = 1;
        if (need(op) == 2) begin
          if (o_dv) v_drs_b2b = 1;
          m_dv = 1; m_dc = 0; m_dtag = q_tag[0]; m_dmv = old; m_ddl = dl; m_dpo = !in || mpo[ln];
          v_dl_d[dl] = 1;
          for (int b = 0; b < 8; b++)
            for (int j = 0; j < 8; j++) m_dl[b][8 * j +: 8] = in ? mb[ln * 64 + 8 * b + j] : 8'h00;
          if (in && mpo[ln]) begin m_poi = 1; v_poi_rd = 1; end
          if (in && op == 4'd1 && mf == 2'b00) begin mmeta[ln] = mv; v_meta_set[mv] = 1; end
          if (op == 4'd2 && mf == 2'b00) v_rddata_meta = 1;
        end else if (need(op) == 1) begin
          if (o_nv) v_ndr_b2b = 1;
          m_nv = 1; m_ntag = q_tag[0]; m_nmv = old; m_ndl = dl;
          m_nop = 2'd0;
          if (op != 4'd10 && mf == 2'b00) m_nop = mv == 2'b11 ? 2'd1 : mv == 2'b10 ? 2'd2 : 2'd0;
          v_cmp[m_nop] = 1;
          v_dl_n[dl] = 1;
          if (in && mf == 2'b00) begin mmeta[ln] = mv; v_meta_set[mv] = 1; end
        end else if (op != 4'd8) m_opc = 1;
        void'(q_snp.pop_front()); void'(q_tag.pop_front()); void'(q_addr.pop_front());
      end
      // an RwD message served
      if (sw) begin
        req_last = 0;
        mf = h_mf;
        off = h_addr - hdm_base;
        in = off < LINES;
        ln = int'(off);
        if (mf == 2'b01 || mf == 2'b10 || h_snp[2]) begin
          m_pro = 1; mf = 2'b11;
          if (h_snp[2]) v_res_snp = 1; else v_res_mf = 1;
        end
        v_wop[h_op] = 1;
        if (!wok) m_opc = 1;
        else begin
          if (o_nv) v_ndr_b2b = 1;
          m_nv = 1; m_nop = 2'd0; m_ntag = h_tag; m_nmv = in ? mmeta[ln] : 2'b00; m_ndl = dl;
          v_dl_n[dl] = 1;
          if (!in) begin m_rng = 1; v_rng_wr = 1; end
          else begin
            for (int b = 0; b < 8; b++) begin
              if (h_op == 4'd2 && w_b[b] == 8'h00) v_be0 = 1;
              if (h_op == 4'd2 && w_b[b] != 8'h00 && w_b[b] != 8'hFF) v_be_part = 1;
              for (int j = 0; j < 8; j++)
                if (h_op == 4'd1 || w_b[b][j]) mb[ln * 64 + 8 * b + j] = w_d[b][8 * j +: 8];
            end
            if (h_op == 4'd1) begin
              if (h_po) v_po_set = 1; else if (mpo[ln]) v_po_clr = 1;
              mpo[ln] = h_po;
            end else begin
              if (mpo[ln] && !h_po) v_po_keep = 1;
              if (h_po) v_ptl_po = 1;
              mpo[ln] = mpo[ln] || h_po;
            end
            if (mf == 2'b00) begin mmeta[ln] = h_mv; v_meta_set[h_mv] = 1; end
          end
        end
        w_d.delete(); w_b.delete();
      end
      // messages in
      if (req_valid && nq < RQD) begin
        q_op.push_back(req_opcode); q_mf.push_back(req_meta_field); q_mv.push_back(req_meta_value);
        q_snp.push_back(req_snp_type); q_tag.push_back(req_tag); q_addr.push_back(req_addr);
      end
      if (rwd_valid && !full) begin
        if (w_d.size() == 0) begin
          h_op = rwd_opcode; h_mf = rwd_meta_field; h_mv = rwd_meta_value; h_snp = rwd_snp_type;
          h_tag = rwd_tag; h_addr = rwd_addr; h_po = rwd_poison;
        end
        w_d.push_back(rwd_data); w_b.push_back(rwd_be);
      end
    end
  end

  // ---------------- assertions ----------------
  `SVA_INV(a_req_ready, req_ready == (q_op.size() < RQD))
  `SVA_INV(a_rwd_ready, rwd_ready == (w_d.size() < 8))
  `SVA_INV(a_ndr, ndr_valid == m_nv && (!m_nv || ndr_opcode == m_nop && ndr_tag == m_ntag &&
                                        ndr_meta_value == m_nmv && ndr_devload == m_ndl))
  `SVA_INV(a_drs, drs_valid == m_dv && (!m_dv || drs_tag == m_dtag && drs_meta_value == m_dmv &&
                                        drs_devload == m_ddl && drs_poison == m_dpo && drs_data == m_dl[m_dc] &&
                                        drs_last == (m_dc == 7)))
  `SVA_INV(a_events, {ev_range, ev_opcode, ev_proto, ev_poison} == {m_rng, m_opc, m_pro, m_poi})
  `SVA_RST(a_reset, 1'b1, !ndr_valid && !drs_valid && req_ready && rwd_ready &&
                          {ev_range, ev_opcode, ev_proto, ev_poison} == 4'b0000)

  // ---------------- functional coverage ----------------
  `FC(req_meminv, v_op[0])
  `FC(req_memrd, v_op[1])
  `FC(req_memrddata, v_op[2])
  `FC(req_memrdfwd_dropped, v_op[3])
  `FC(req_memwrfwd_dropped, v_op[4])
  `FC(req_memspecrd, v_op[8])
  `FC(req_meminvnt, v_op[9])
  `FC(req_memclnevct, v_op[10])
  `FC(req_reserved_dropped, v_op[15])
  `FC(rwd_memwr, v_wop[1])
  `FC(rwd_memwrptl, v_wop[2])
  `FC(rwd_biconflict_dropped, v_wop[4])
  `FC(rwd_reserved_dropped, v_wop[15])
  `FC(ndr_cmp, v_cmp[0])
  `FC(ndr_cmp_s, v_cmp[1])
  `FC(ndr_cmp_e, v_cmp[2])
  `FC(meta_set_invalid, v_meta_set[0])
  `FC(meta_set_reserved, v_meta_set[1])
  `FC(meta_set_any, v_meta_set[2])
  `FC(meta_set_shared, v_meta_set[3])
  `FC(memrddata_meta0_ignored, v_rddata_meta)
  `FC(range_read, v_rng_rd)
  `FC(range_write, v_rng_wr)
  `FC(range_inv, v_rng_inv)
  `FC(range_specrd, v_spec_out)
  `FC(range_wraps, v_wrap)
  `FC(poison_read, v_poi_rd)
  `FC(poison_set_full, v_po_set)
  `FC(poison_clear_full, v_po_clr)
  `FC(poison_kept_partial, v_po_keep)
  `FC(poison_set_partial, v_ptl_po)
  `FC(partial_no_bytes, v_be0)
  `FC(partial_some_bytes, v_be_part)
  `FC(reserved_meta_field, v_res_mf)
  `FC(reserved_snp_type, v_res_snp)
  `FC(devload_light_ndr, v_dl_n[0])
  `FC(devload_optimal_ndr, v_dl_n[1])
  `FC(devload_moderate_ndr, v_dl_n[2])
  `FC(devload_severe_ndr, v_dl_n[3])
  `FC(devload_light_drs, v_dl_d[0])
  `FC(devload_optimal_drs, v_dl_d[1])
  `FC(devload_moderate_drs, v_dl_d[2])
  `FC(devload_severe_drs, v_dl_d[3])
  `FC(tie_req_served, v_tie_q)
  `FC(tie_rwd_served, v_tie_w)
  `FC(req_waits_for_ndr, v_q_wait_n)
  `FC(req_waits_for_drs, v_q_wait_d)
  `FC(rwd_waits_for_ndr, v_w_wait)
  `FC(rwd_dropped_while_ndr_busy, v_bad_w_busy)
  `FC(drs_back_to_back, v_drs_b2b)
  `FC(ndr_back_to_back, v_ndr_b2b)
  `FC(req_fifo_full, req_valid && !req_ready)
  `FC(rwd_held, rwd_valid && !rwd_ready)
  `FC(drs_stalled, drs_valid && !drs_ready)
  `FC(ndr_stalled, ndr_valid && !ndr_ready)
  `FC_RST(reset_in_drs, rst_n && drs_valid && !drs_last ##1 !rst_n)
endmodule

bind CXL_top CXL_sva #(.LINES(LINES), .RQD(RQD)) u_sva (.*);
