// SPDX-License-Identifier: Apache-2.0
// NVMe controller command engine: concurrent SVA against an independent
// reference model, plus functional coverage.
//  * The model plans each phase as a list of memory requests when the phase
//    begins (the seven SQ entry dwords, the data moves of a command, the four
//    completion dwords with their values) and hands them to the request
//    channel one per free clock. Read responses are counted as owed and
//    stored by phase. The command is checked from the seven dwords it got.
//  * m_req_valid and every request field, csts_rdy, sq_head, cq_tail and
//    the event pulses are compared on every clock.
`include "cov_macros.svh"
module NVMe_sva #(
  parameter int QD = 8, NBLK = 8, BLKDW = 4
)(
  input logic        clk, rst_n,
  input logic        cc_en, csts_rdy,
  input logic [15:0] sq_base, cq_base,
  input logic        sq_db_valid,
  input logic [15:0] sq_db,
  input logic        cq_db_valid,
  input logic [15:0] cq_db,
  input logic [$clog2(QD)-1:0] sq_head, cq_tail,
  input logic        m_req_valid, m_req_ready, m_req_we,
  input logic [15:0] m_req_addr,
  input logic [31:0] m_req_wdata,
  input logic        m_rsp_valid,
  input logic [31:0] m_rsp_data,
  input logic        ev_cqe, ev_err, ev_db
);
  `COV_CLOCKING(clk, !rst_n)
  localparam int ND = NBLK * BLKDW;
  // phases
  localparam int OFF = 0, IDLE = 1, FETCH = 2, DEC = 3, XFER = 4, CPL = 5, ABORT = 6;

  int          ph;
  int          sqh, sqt, cqh, cqt;
  bit          pt;                             // phase tag
  bit          pv, pwe;                        // the request on the channel
  logic [15:0] pa;
  logic [31:0] pd;
  bit          l_we [$];                       // planned requests
  logic [15:0] l_a [$];
  logic [31:0] l_d [$];
  int          owed, got;
  logic [31:0] fd [0:6];
  logic [31:0] ns [0:ND-1];
  logic [15:0] c_cid;
  logic [7:0]  c_sc;
  int          c_op, c_slba, c_n;
  logic [15:0] c_prp;
  bit          m_cqe, m_err, m_db;

  // coverage
  bit v_sc [0:6], v_ok [0:2], v_flush_all, v_slba_hi, v_slba_out, v_nlb_hi, v_nlb_over, v_ab [0:7], v_ab_held, v_ab_owed;
  bit v_cq_full, v_pt_wrap, v_sq_wrap, v_db_sq_bad, v_db_cq_bad, v_db_off, v_db_busy, v_batch, v_n_max, v_n_min;
  bit v_prp_hi, v_prp_lo_hi, v_rsp_while_iss, v_idle_off, v_fuse, v_psdt, v_ns0, v_ns_all_rw, v_rd_after_wr, v_req_held;

  function automatic logic [7:0] sc_code(input int i);
    case (i)
      1: return 8'h01;
      2: return 8'h02;
      3: return 8'h0B;
      4: return 8'h13;
      5: return 8'h80;
      6: return 8'h04;
      default: return 8'h00;
    endcase
  endfunction
  task automatic plan(input bit we, input logic [15:0] a, input logic [31:0] d);
    l_we.push_back(we); l_a.push_back(a); l_d.push_back(d);
  endtask
  task automatic plan_cpl();
    logic [15:0] a;
    a = cq_base + 16'(cqt * 4);
    plan(1, a, 32'd0);
    plan(1, a + 16'd1, 32'd0);
    plan(1, a + 16'd2, {16'd1, 16'(sqh)});
    plan(1, a + 16'd3, {c_sc != 0, 6'd0, c_sc, pt, c_cid});
    ph = CPL;
  endtask

  // per-step copies for the covergroup (set at posedge, sampled at negedge)
  bit k_dv, k_wv, k_rv, k_cv;
  int k_op, k_sc, k_slba, k_nb, k_sq, k_cq;
  logic [31:0] k_wd, k_rd;

  bit e_last_rd;                               // data of the last Write landed (for v_rd_after_wr)
  always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      ph = OFF; sqh = 0; sqt = 0; cqh = 0; cqt = 0; pt = 1;
      pv = 0; pwe = 0; pa = 0; pd = 0;
      l_we.delete(); l_a.delete(); l_d.delete();
      owed = 0; got = 0;
      for (int i = 0; i < ND; i++) ns[i] = 0;
      m_cqe = 0; m_err = 0; m_db = 0;
    end else begin : b_step
      int  o_ph, o_sqt, o_owed, sci;
      bit  o_pv, rdy, full, ld;
      o_ph = ph; o_sqt = sqt; o_owed = owed; o_pv = pv;
      rdy = ph != OFF && ph != ABORT;
      full = (cqt + 1) % QD == cqh;
      m_cqe = 0; m_err = 0; m_db = 0;
      {k_dv, k_wv, k_rv, k_cv} = '0;
      // ---- doorbells
      if (sq_db_valid) begin
        if (rdy && sq_db < QD) begin
          if (ph != IDLE) v_db_busy = 1;
          if ((sq_db - sqt + QD) % QD > 1) v_batch = 1;
          sqt = sq_db;
        end else begin
          m_db = 1;
          if (!rdy) v_db_off = 1; else v_db_sq_bad = 1;
        end
      end
      if (cq_db_valid) begin
        if (rdy && cq_db < QD) cqh = cq_db;
        else begin
          m_db = 1;
          if (!rdy) v_db_off = 1; else v_db_cq_bad = 1;
        end
      end
      // ---- the request channel
      if (pv && m_req_ready) pv = 0;
      if (o_pv && !m_req_ready) v_req_held = 1;
      ld = cc_en && (o_ph == FETCH || o_ph == XFER || o_ph == CPL && !full) && (!o_pv || m_req_ready) && l_we.size() != 0;
      if (o_ph == CPL && full && l_we.size() != 0) v_cq_full = 1;
      if (ld) begin
        pv = 1; pwe = l_we.pop_front(); pa = l_a.pop_front(); pd = l_d.pop_front();
        if (pwe && o_ph == XFER) begin k_rv = 1; k_rd = pd; end
        if (!pwe) owed++;
        if (o_owed != 0) v_rsp_while_iss = 1;
      end
      // ---- read responses
      if (m_rsp_valid && o_owed != 0) begin
        owed--;
        if (ph == FETCH) fd[got] = m_rsp_data;
        else if (ph == XFER) begin ns[c_slba * BLKDW + got] = m_rsp_data; k_wv = 1; k_wd = m_rsp_data; end
        got++;
      end
      // ---- the engine
      if (!cc_en && ph != OFF && ph != IDLE && ph != ABORT) begin
        if (pv && !m_req_ready) v_ab_held = 1;
        if (owed != 0) v_ab_owed = 1;
        v_ab[ph == XFER && c_op == 2 ? 7 : ph] = 1;
        ph = ABORT;
      end else
        case (ph)
          OFF: begin
            sqh = 0; sqt = 0; cqh = 0; cqt = 0; pt = 1;
            if (cc_en) ph = IDLE;
          end
          IDLE:
            if (!cc_en) begin ph = OFF; v_idle_off = 1; end
            else if (sqh != o_sqt) begin
              ph = FETCH; got = 0;
              for (int i = 0; i < 7; i++)
                plan(0, sq_base + 16'(sqh * 16) + 16'(i < 2 ? i : i < 4 ? i + 4 : i + 6), 32'd0);
            end
          FETCH:
            if (got == 7) begin
              ph = DEC;
              if (sqh == QD - 1) v_sq_wrap = 1;
              sqh = (sqh + 1) % QD;
            end
          DEC: begin
            logic [7:0]  op;
            logic [31:0] nsid, slo, shi;
            logic [15:0] nlb;
            op = fd[0][7:0]; nsid = fd[1]; slo = fd[4]; shi = fd[5]; nlb = fd[6][15:0];
            c_cid = fd[0][31:16]; c_prp = fd[2][17:2];
            if (op > 2) sci = 1;
            else if (fd[0][9:8] != 0 || fd[0][15:14] != 0) begin
              sci = 2;
              if (fd[0][9:8] != 0) v_fuse = 1;
              if (fd[0][15:14] != 0) v_psdt = 1;
            end else if (!(nsid == 1 || op == 0 && nsid == 32'hFFFFFFFF)) begin
              sci = 3;
              if (nsid == 0) v_ns0 = 1;
              if (nsid == 32'hFFFFFFFF) v_ns_all_rw = 1;
            end else if (op != 0 && fd[2][1:0] != 0) sci = 4;
            else if (op != 0 && !(shi == 0 && slo < NBLK && nlb < NBLK && slo + nlb < NBLK)) begin
              sci = 5;
              if (shi != 0) v_slba_hi = 1;
              else if (slo >= NBLK) v_slba_out = 1;
              else if (nlb >= NBLK) v_nlb_hi = 1;
              else v_nlb_over = 1;
            end else if (op != 0 && (fd[3] != 0 || fd[2][31:18] != 0)) begin
              sci = 6;
              if (fd[3] != 0) v_prp_hi = 1;
              if (fd[2][31:18] != 0) v_prp_lo_hi = 1;
            end else sci = 0;
            v_sc[sci] = 1;
            k_dv = 1; k_op = op > 2 ? 3 : op; k_sc = sci; k_slba = slo; k_nb = nlb + 1; k_sq = (sqh + QD - 1) % QD;
            c_sc = sc_code(sci);
            c_op = op;
            if (sci == 0) begin
              v_ok[op] = 1;
              if (op == 0 && nsid == 32'hFFFFFFFF) v_flush_all = 1;
            end
            if (sci != 0 || op == 0) plan_cpl();
            else begin
              c_slba = slo; c_n = (nlb + 1) * BLKDW; got = 0;
              if (c_n == ND) v_n_max = 1;
              if (c_n == BLKDW) v_n_min = 1;
              if (op == 2 && e_last_rd) v_rd_after_wr = 1;
              e_last_rd = op == 1;
              for (int i = 0; i < c_n; i++)
                plan(op == 2, c_prp + 16'(i), op == 2 ? ns[c_slba * BLKDW + i] : 32'd0);
              ph = XFER;
            end
          end
          XFER:
            if (c_op == 1 ? got == c_n : l_we.size() == 0 && !o_pv) plan_cpl();
          CPL:
            if (o_ph == CPL && l_we.size() == 0 && !o_pv) begin
              m_cqe = 1; m_err = c_sc != 0;
              k_cv = 1; k_cq = cqt;
              if (cqt == QD - 1) begin pt = !pt; v_pt_wrap = 1; end
              cqt = (cqt + 1) % QD;
              ph = IDLE;
            end
          default:
            if (!o_pv && o_owed == 0) begin
              ph = OFF;
              l_we.delete(); l_a.delete(); l_d.delete();
            end
        endcase
    end
  end

  // ---------------- assertions ----------------
  `SVA_INV(a_req, m_req_valid == pv && (!pv || m_req_we == pwe && m_req_addr == pa && (!pwe || m_req_wdata == pd)))
  `SVA_INV(a_rdy, csts_rdy == (ph != OFF && ph != ABORT))
  `SVA_INV(a_ptrs, sq_head == sqh && cq_tail == cqt)
  `SVA_INV(a_events, {ev_cqe, ev_err, ev_db} == {m_cqe, m_err, m_db})
  `SVA_RST(a_reset, !rst_n, !m_req_valid && !csts_rdy && sq_head == 0 && cq_tail == 0 && {ev_cqe, ev_err, ev_db} == 3'b0)

  // ---------------- functional coverage ----------------
  function automatic int dcls(input logic [31:0] v);
    return v == 32'd0 ? 0 : v == '1 ? 1 : (v == 32'h5555_5555 || v == 32'hAAAA_AAAA) ? 2 : 3;
  endfunction
  covergroup cg_nvme @(negedge clk);
    option.per_instance = 1;
    cp_cmd: coverpoint k_op * 8 + k_sc iff (rst_n && k_dv)
      { bins flush_ok = {0}; bins flush_field = {2}; bins flush_ns = {3};
        bins write_ok = {8}; bins write_field = {10}; bins write_ns = {11}; bins write_prp_off = {12};
        bins write_lba = {13}; bins write_prp_hi = {14};
        bins read_ok = {16}; bins read_field = {18}; bins read_ns = {19}; bins read_prp_off = {20};
        bins read_lba = {21}; bins read_prp_hi = {22}; bins bad_opcode = {25}; }
    cp_rw: coverpoint k_op iff (rst_n && k_dv && k_sc == 0 && k_op != 0) { bins write = {1}; bins read = {2}; }
    cp_slba: coverpoint k_slba iff (rst_n && k_dv && k_sc == 0 && k_op != 0) { bins b[] = {[0:NBLK-1]}; }
    cp_nb: coverpoint k_nb iff (rst_n && k_dv && k_sc == 0 && k_op != 0) { bins n[] = {[1:NBLK]}; }
    x_rw_slba: cross cp_rw, cp_slba;
    cp_sq: coverpoint k_sq iff (rst_n && k_dv) { bins s[] = {[0:QD-1]}; }
    cp_cq: coverpoint k_cq iff (rst_n && k_cv) { bins s[] = {[0:QD-1]}; }
    cp_wdata: coverpoint dcls(k_wd) iff (rst_n && k_wv)
      { bins zero = {0}; bins ones = {1}; bins alt = {2}; bins other = {3}; }
    cp_rdata: coverpoint dcls(k_rd) iff (rst_n && k_rv)
      { bins zero = {0}; bins ones = {1}; bins alt = {2}; bins other = {3}; }
  endgroup
  cg_nvme u_cg_nvme = new;

  `FC(sc_success, v_sc[0])
  `FC(sc_invalid_opcode, v_sc[1])
  `FC(sc_invalid_field, v_sc[2])
  `FC(sc_invalid_namespace, v_sc[3])
  `FC(sc_prp_offset, v_sc[4])
  `FC(sc_lba_range, v_sc[5])
  `FC(sc_data_transfer, v_sc[6])
  `FC(prp1_upper_dword, v_prp_hi)
  `FC(prp1_above_window, v_prp_lo_hi)
  `FC(flush_ok, v_ok[0])
  `FC(write_ok, v_ok[1])
  `FC(read_ok, v_ok[2])
  `FC(flush_all_namespaces, v_flush_all)
  `FC(rw_broadcast_nsid_rejected, v_ns_all_rw)
  `FC(nsid_zero, v_ns0)
  `FC(fused, v_fuse)
  `FC(sgl_psdt, v_psdt)
  `FC(slba_upper_dword, v_slba_hi)
  `FC(slba_beyond, v_slba_out)
  `FC(nlb_upper_bits, v_nlb_hi)
  `FC(slba_plus_nlb_beyond, v_nlb_over)
  `FC(whole_namespace, v_n_max)
  `FC(one_block, v_n_min)
  `FC(read_after_write, v_rd_after_wr)
  `FC(abort_fetch, v_ab[FETCH])
  `FC(abort_decode, v_ab[DEC])
  `FC(abort_write_data, v_ab[XFER])
  `FC(abort_read_data, v_ab[7])
  `FC(abort_completion, v_ab[CPL])
  `FC(abort_request_held, v_ab_held)
  `FC(abort_reads_owed, v_ab_owed)
  `FC(abort_drains, ph == ABORT && m_rsp_valid)
  `FC(disable_from_idle, v_idle_off)
  `FC(cq_full_stall, v_cq_full)
  `FC(phase_tag_wrap, v_pt_wrap)
  `FC(sq_head_wrap, v_sq_wrap)
  `FC(doorbell_sq_invalid, v_db_sq_bad)
  `FC(doorbell_cq_invalid, v_db_cq_bad)
  `FC(doorbell_not_ready, v_db_off)
  `FC(doorbell_while_busy, v_db_busy)
  `FC(doorbell_batch, v_batch)
  `FC(request_held, v_req_held)
  `FC(responses_while_issuing, v_rsp_while_iss)
  `FC(both_doorbells, sq_db_valid && cq_db_valid)
  `FC_RST(reset_in_transfer, rst_n && ph == XFER ##1 !rst_n)
endmodule

bind NVMe_top NVMe_sva #(.QD(QD), .NBLK(NBLK), .BLKDW(BLKDW)) u_sva (.*);
