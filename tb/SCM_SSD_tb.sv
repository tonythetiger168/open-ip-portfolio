// SPDX-License-Identifier: Apache-2.0
// SCM_SSD_top testbench: a host model with its own memory and NQ queue
// pairs, plus a byte-port (CXL.mem-style) master on the SCM region.
//  - The host builds submission queue entries on every pair (Write, Read,
//    Flush on both namespaces, FDP-directed Writes on namespace 2, and
//    malformed commands), rings SQ doorbells singly or in batches, and
//    rings CQ doorbells after a random delay (so CQs fill up). The memory
//    slave takes requests with random back-pressure and answers reads in
//    order after a random latency.
//  - Commands run one at a time in the controller, so the completions'
//    order (ev_cqe, ev_cqe_qid) is the execution order. The reference
//    namespaces and FDP fill counts are updated in that order; each
//    completion is checked for CID, status, DNR, SQ head, SQ identifier and
//    phase, and a Read's buffer against the reference.
//  - The controller may write only to Read buffers in flight and to CQs.
//  - Round robin: with every SQ loaded while the memory slave stalls, the
//    pairs are served in turn.
//  - Media latency: a Read / Write takes at least its media time.
//  - Byte port: random loads and stores (and out-of-range addresses) run
//    on the upper half of the SCM region while block traffic uses the lower
//    half; a directed phase checks that both views see the same cells.
//  - Doorbell errors, enable / disable.
`timescale 1ns/1ps
module SCM_SSD_tb;
  localparam int NQ = 4, QD = 8, BLKDW = 4, NBS = 8, NBN = 16, NRUH = 4, RUB = 4;
  localparam int TSCM = 2, TRD = 12, TPROG = 24;
  localparam int QW = $clog2(QD), QIW = $clog2(NQ), HW = $clog2(NRUH), RW = $clog2(RUB);
  localparam int DS = NBS * BLKDW, DN = NBN * BLKDW;
  logic clk = 0, rst_n = 0;
  always #5 clk = ~clk;
  int errors = 0;
  task automatic fail(input string s);
    errors++;
    $display("ERROR: %s @%0t", s, $time);
  endtask

  logic              cc_en = 0, sq_db_valid = 0, cq_db_valid = 0, m_req_ready = 0, m_rsp_valid = 0;
  logic [NQ*16-1:0]  sq_base = 0, cq_base = 0;
  logic [QIW-1:0]    sq_db_qid = 0, cq_db_qid = 0;
  logic [15:0]       sq_db = 0, cq_db = 0;
  logic [31:0]       m_rsp_data = 0;
  wire               csts_rdy, m_req_valid, m_req_we, ev_cqe, ev_err, ev_db, ev_ru;
  wire [NQ*QW-1:0]   sq_head, cq_tail;
  wire [15:0]        m_req_addr;
  wire [31:0]        m_req_wdata;
  logic              b_req_valid = 0, b_req_we = 0;
  logic [7:0]        b_req_tag = 0;
  logic [15:0]       b_req_addr = 0;
  logic [31:0]       b_req_wdata = 0;
  wire               b_req_ready, b_rsp_valid, b_rsp_err;
  wire [7:0]         b_rsp_tag;
  wire [31:0]        b_rsp_data;
  wire [NRUH*RW-1:0] ru_fill;
  wire [31:0]        nand_blks, scm_blks;
  wire [QIW-1:0]     ev_cqe_qid;
  wire [HW-1:0]      ev_ru_h;

  SCM_SSD_top #(.NQ(NQ), .QD(QD), .BLKDW(BLKDW), .NBS(NBS), .NBN(NBN), .NRUH(NRUH), .RUB(RUB),
                .TSCM(TSCM), .TRD(TRD), .TPROG(TPROG)) dut (.*);

  // ---------------- host memory and slave ----------------
  logic [31:0] hm [0:65535];
  bit          hwr [0:65535];                  // the controller may write here
  logic [31:0] rs_d [$];
  int          rs_t [$];
  int          cyc = 0, p_rdy = 80, lat = 4, p_rsp = 90;
  bit          hold_rdy = 0;
  always @(posedge clk) begin
    cyc++;
    if (!rst_n) begin
      rs_d.delete(); rs_t.delete();
    end else begin
      if (m_rsp_valid) begin void'(rs_d.pop_front()); void'(rs_t.pop_front()); end
      if (m_req_valid && m_req_ready) begin
        if (m_req_we) begin
          if (!hwr[m_req_addr]) fail($sformatf("write to %h, not a Read buffer or a CQ", m_req_addr));
          hm[m_req_addr] = m_req_wdata;
        end else begin
          rs_d.push_back(hm[m_req_addr]);
          rs_t.push_back(cyc + 1 + $urandom % lat);
        end
      end
    end
  end
  always @(negedge clk) begin
    m_req_ready = !hold_rdy && $urandom % 100 < p_rdy;
    m_rsp_valid = rs_d.size() != 0 && rs_t[0] <= cyc && $urandom % 100 < p_rsp;
    m_rsp_data = m_rsp_valid ? rs_d[0] : $urandom;
  end

  // ---------------- layout ----------------
  // pair q: SQ at 0x1000*q + 0x0100 (8 x 16 dwords), CQ at 0x1000*q + 0x0800
  // (8 x 4 dwords), data buffers at 0x8000 + 0x400*q + 0x40*slot (QD slots)
  function automatic int sqa(input int q); return 'h1000 * q + 'h0100; endfunction
  function automatic int cqa(input int q); return 'h1000 * q + 'h0800; endfunction
  function automatic int bfa(input int q, input int s); return 'h8000 + 'h400 * q + 'h40 * s; endfunction

  // ---------------- reference ----------------
  logic [31:0] ns_s [0:DS-1];
  logic [31:0] ns_n [0:DN-1];
  int          r_fill [NRUH];
  int          r_nand = 0, r_scm = 0;
  // commands submitted and not completed, all pairs, in submission order
  int          i_q [$], i_cid [$], i_op [$], i_ns [$], i_slba [$], i_nlb [$], i_ruh [$], i_slot [$], i_sqhd [$], i_sc [$], i_t [$];
  int          n_infl [NQ];
  int          rung_h [NQ];
  int          sq_t [NQ], sq_known [NQ], cq_h [NQ], unrung [NQ], pend [NQ];
  bit          cq_ph [NQ];
  int          slot_n [NQ];
  int          ord [$];                        // completion order (pair)
  int          x_cqe = 0, x_err = 0, x_db = 0, x_ru = 0, n_cqe = 0, n_err = 0, n_db = 0, n_ru = 0;
  int          sc_seen [0:255];
  int          q_seen [NQ];
  int          ru_q [$];
  int          t_cqe = 0;
  always @(posedge clk) if (rst_n) begin
    if (ev_cqe) begin n_cqe++; t_cqe = $time / 10; ord.push_back(ev_cqe_qid); end
    if (ev_err) n_err++;
    if (ev_db) n_db++;
    if (ev_ru) begin n_ru++; ru_q.push_back(ev_ru_h); end
  end

  // ---------------- doorbells ----------------
  bit sq_lock = 0, cq_lock = 0;
  task automatic ring_sq(input int q, input int v);
    while (sq_lock) @(negedge clk);
    sq_lock = 1;
    sq_db_valid = 1; sq_db_qid = q; sq_db = 16'(v);
    @(negedge clk);
    sq_db_valid = 0; sq_db = $urandom % 3 == 0 ? 16'hFFFF : 16'h0000; sq_db_qid = $urandom;
    sq_lock = 0;
  endtask
  task automatic ring_cq(input int q, input int v);
    while (cq_lock) @(negedge clk);
    cq_lock = 1;
    cq_db_valid = 1; cq_db_qid = q; cq_db = 16'(v);
    @(negedge clk);
    cq_db_valid = 0; cq_db = $urandom % 3 == 0 ? 16'hFFFF : 16'h0000; cq_db_qid = $urandom;
    if (v < QD) rung_h[q] = v;
    cq_lock = 0;
  endtask

  // ---------------- consumer: completions in execution order ----------------
  bit c_on = 0;
  int c_hold = 0;
  int min_lat_bad = 0;
  initial forever begin
    @(negedge clk);
    if (c_on && ord.size() != 0) begin : b_cons
      int q, a;
      logic [31:0] d2, d3;
      int c_cid, c_op, c_ns, c_slba, c_nlb, c_ruh, c_slot, c_sqhd, c_sc, c_t_sub, j;
      bit c_ok;
      c_ok = 0;
      q = ord.pop_front();
      a = cqa(q) + cq_h[q] * 4;
      d3 = hm[a + 3];
      if (n_infl[q] == 0) fail($sformatf("completion on pair %0d with none expected", q));
      else if (d3[16] != cq_ph[q]) fail($sformatf("pair %0d CQE phase %0d, expected %0d", q, d3[16], cq_ph[q]));
      else begin
        j = 0;
        while (i_q[j] != q) j++;
        c_cid = i_cid[j]; c_op = i_op[j]; c_ns = i_ns[j]; c_slba = i_slba[j]; c_nlb = i_nlb[j];
        c_ruh = i_ruh[j]; c_slot = i_slot[j]; c_sqhd = i_sqhd[j]; c_sc = i_sc[j]; c_t_sub = i_t[j];
        i_q.delete(j); i_cid.delete(j); i_op.delete(j); i_ns.delete(j); i_slba.delete(j); i_nlb.delete(j);
        i_ruh.delete(j); i_slot.delete(j); i_sqhd.delete(j); i_sc.delete(j); i_t.delete(j);
        n_infl[q]--;
        c_ok = 1;
        d2 = hm[a + 2];
        q_seen[q]++;
        if (hm[a] != 0 || hm[a + 1] != 0) fail("CQE DW0/DW1 not zero");
        if (d2 != {16'(q + 1), 16'(c_sqhd)}) fail($sformatf("pair %0d CQE DW2 %h, expected SQID %0d SQHD %0d", q, d2, q + 1, c_sqhd));
        if (d3[15:0] != c_cid) fail($sformatf("pair %0d CQE CID %h, expected %h", q, d3[15:0], c_cid));
        if (d3[24:17] != c_sc || d3[30:25] != 6'd0 || d3[31] != (c_sc != 0))
          fail($sformatf("pair %0d CID %h status %h, expected SC %h", q, d3[15:0], d3[31:17], c_sc));
        sc_seen[c_sc]++;
        x_cqe++;
        if (c_sc != 0) x_err++;
        if (c_sc == 0 && c_op != 0) begin
          int n, b;
          n = (c_nlb + 1) * BLKDW;
          b = bfa(q, c_slot);
          if (c_op == 2) begin
            for (int i = 0; i < n; i++) begin
              logic [31:0] x;
              x = c_ns == 2 ? ns_n[c_slba * BLKDW + i] : ns_s[c_slba * BLKDW + i];
              if (hm[b + i] !== x) fail($sformatf("Read CID %h ns %0d dword %0d: %h, expected %h", c_cid, c_ns, i, hm[b + i], x));
            end
            for (int i = 0; i < n; i++) hwr[b + i] = 0;
          end else begin
            for (int i = 0; i < n; i++)
              if (c_ns == 2) ns_n[c_slba * BLKDW + i] = hm[b + i];
              else ns_s[c_slba * BLKDW + i] = hm[b + i];
            if (c_ns == 2) begin
              int s;
              r_nand += c_nlb + 1;
              s = r_fill[c_ruh] + c_nlb + 1;
              if (s >= RUB) begin
                x_ru++;
                if (ru_q.size() == 0) fail($sformatf("no ev_ru for handle %0d", c_ruh));
                else begin
                  int h;
                  h = ru_q.pop_front();
                  if (h != c_ruh) fail($sformatf("ev_ru handle %0d, expected %0d", h, c_ruh));
                end
              end
              r_fill[c_ruh] = s % RUB;
            end else r_scm += c_nlb + 1;
          end
          // a Read waits its media time, a Write its program time
          if (cyc - c_t_sub < (c_op == 2 ? (c_ns == 2 ? TRD : TSCM) : (c_ns == 2 ? TPROG : TSCM))) min_lat_bad++;
        end
        for (int h = 0; h < NRUH; h++)
          if (ru_fill[RW*h +: RW] != RW'(r_fill[h])) fail($sformatf("ru_fill[%0d] %0d, expected %0d", h, ru_fill[RW*h +: RW], r_fill[h]));
        if (nand_blks != r_nand || scm_blks != r_scm)
          fail($sformatf("block counts nand %0d/%0d scm %0d/%0d", nand_blks, r_nand, scm_blks, r_scm));
      end
      if (c_ok) sq_known[q] = c_sqhd;
      cq_h[q] = (cq_h[q] + 1) % QD;
      if (cq_h[q] == rung_h[q]) fail($sformatf("pair %0d: completion posted into a full CQ", q));
      if (cq_h[q] == 0) cq_ph[q] = !cq_ph[q];
      unrung[q]++;
    end
  end
  // CQ doorbells, after a random delay
  initial forever begin
    @(negedge clk);
    if (c_on)
      for (int q = 0; q < NQ; q++)
        if (unrung[q] != 0 && (c_hold == 0 || $urandom % c_hold == 0)) begin
          int v;
          v = cq_h[q];
          unrung[q] = 0;
          ring_cq(q, v);
        end
  end

  // ---------------- producer ----------------
  // ns1 traffic stays in the lower half of the SCM region (the byte port
  // owns the upper half) unless lo_only is cleared
  bit lo_only = 1;
  function automatic logic [7:0] status(input int op, input int fuse, input logic [31:0] nsid, input int dtype,
                                        input int dspec, input logic [31:0] prp, input logic [31:0] phi,
                                        input logic [31:0] slo, input logic [31:0] shi, input logic [15:0] nlb);
    int nb;
    if (op > 2) return 8'h01;
    if (fuse != 0) return 8'h02;
    if (!(nsid == 1 || nsid == 2 || op == 0 && nsid == 32'hFFFFFFFF)) return 8'h0B;
    if (op == 1 && (!(dtype == 0 || dtype == 2) || dtype == 2 && (nsid != 2 || dspec >= NRUH))) return 8'h02;
    if (op != 0 && prp[1:0] != 0) return 8'h13;
    nb = nsid == 2 ? NBN : NBS;
    if (op != 0 && !(shi == 0 && slo < nb && nlb < nb && slo + nlb < nb)) return 8'h80;
    if (op != 0 && (phi != 0 || prp[31:18] != 0)) return 8'h04;
    return 8'h00;
  endfunction

  int n_cmd = 0, n_fdp = 0;
  bit stop = 0;
  // kind: 0 valid, 1 any (errors too)
  task automatic submit(input int q, input int kind, input int batch, input int f_op = -1, input int f_ns = -1,
                         input int f_dspec = -1);
    logic [31:0] e [0:15];
    int          op, fuse, dtype, dspec, ns, r, nb, half;
    logic [31:0] nsid, prp, phi, slo, shi, c12, c13;
    int          c_cid, c_op, c_ns, c_slba, c_nlb, c_ruh, c_slot, c_sqhd, c_sc;
    while ((sq_t[q] + 1) % QD == sq_known[q] && !stop) @(negedge clk);
    for (int i = 0; i < 16; i++) e[i] = $urandom;
    r = $urandom % 100;
    op = f_op >= 0 ? f_op : r < 45 ? 1 : r < 88 ? 2 : 0;
    ns = f_ns >= 0 ? f_ns : 1 + $urandom % 2;
    nsid = op == 0 && $urandom % 4 == 0 ? 32'hFFFFFFFF : ns;
    fuse = 0;
    nb = ns == 2 ? NBN : NBS;
    half = ns == 1 && lo_only ? NBS / 2 : nb;
    slo = $urandom % half;
    shi = 0;
    c12 = $urandom & 32'hFF0F_FFFF;              // DTYPE 0
    c12[15:0] = $urandom % (half - slo);
    c13 = $urandom;
    dtype = 0; dspec = 0;
    if (op == 1 && ns == 2 && $urandom % 3 != 0) begin
      dtype = 2; dspec = $urandom % NRUH; n_fdp++;
    end
    if (f_dspec >= 0) begin dtype = 2; dspec = f_dspec; end
    prp = {14'd0, 16'(bfa(q, slot_n[q])), 2'b00};
    phi = 0;
    if (kind == 1 && $urandom % 3 == 0) begin
      int r2;
      r = $urandom % 100;
      r2 = $urandom % 4;
      if (r < 8) op = 3 + $urandom % 253;
      else if (r < 14) fuse = 1 + $urandom % 3;
      else if (r < 24) nsid = r2 == 0 ? 32'd0 : r2 == 1 ? 32'd3 : r2 == 2 ? $urandom | 32'h100 : 32'hFFFFFFFF;
      else if (r < 34) begin dtype = r2 == 0 ? 1 : r2 == 1 ? 3 + $urandom % 13 : 2; dspec = r2 == 3 ? NRUH + $urandom % 100 : $urandom % NRUH; if (r2 == 3) begin op = 1; nsid = 2; end end
      else if (r < 44) begin dtype = 2; dspec = $urandom % NRUH; nsid = 1; end      // FDP on the SCM namespace
      else if (r < 54) prp[1:0] = 1 + $urandom % 3;
      else if (r < 66) slo = r2 < 2 ? nb + $urandom % 4 : $urandom;
      else if (r < 72) shi = 32'd1 << ($urandom % 32);
      else if (r < 82) c12[15:0] = r2 < 2 ? nb - slo + $urandom % 3 : 16'($urandom);
      else if (r < 88) phi = 32'd1 << ($urandom % 32);
      else if (r < 94) prp[31:18] = 14'd1 << ($urandom % 14);
    end
    c12[23:20] = dtype;
    c13[31:16] = dtype == 2 ? dspec : $urandom;   // DSPEC is ignored without DTYPE 2
    c_sc = status(op, fuse, nsid, dtype, dspec, prp, phi, slo, shi, c12[15:0]);
    c_cid = e[0][31:16]; c_op = op; c_ns = nsid; c_slba = slo; c_nlb = c12[15:0];
    c_ruh = dtype == 2 ? dspec : 0; c_slot = slot_n[q];
    c_sqhd = (sq_t[q] + 1) % QD;
    if (c_sc == 0 && op != 0) begin
      int b;
      b = bfa(q, slot_n[q]);
      for (int i = 0; i < (c_nlb + 1) * BLKDW; i++) begin
        hm[b + i] = $urandom;
        hwr[b + i] = op == 2;
      end
    end
    slot_n[q] = (slot_n[q] + 1) % QD;
    e[0] = {e[0][31:16], 2'b00, e[0][13:10], 2'(fuse), 8'(op)};
    e[1] = nsid; e[6] = prp; e[7] = phi; e[10] = slo; e[11] = shi; e[12] = c12; e[13] = c13;
    for (int i = 0; i < 16; i++) hm[sqa(q) + sq_t[q] * 16 + i] = e[i];
    i_q.push_back(q); i_cid.push_back(c_cid); i_op.push_back(c_op); i_ns.push_back(c_ns);
    i_slba.push_back(c_slba); i_nlb.push_back(c_nlb); i_ruh.push_back(c_ruh); i_slot.push_back(c_slot);
    i_sqhd.push_back(c_sqhd); i_sc.push_back(c_sc); i_t.push_back(-1);
    n_infl[q]++;
    sq_t[q] = (sq_t[q] + 1) % QD;
    n_cmd++;
    pend[q]++;
    if (pend[q] >= batch && !stop) begin
      for (int i = 0; i < i_q.size(); i++) if (i_q[i] == q && i_t[i] < 0) i_t[i] = cyc;
      pend[q] = 0;
      ring_sq(q, sq_t[q]);
    end
  endtask
  task automatic flush_sq(input int q);
    if (pend[q] != 0) begin
      for (int i = 0; i < i_q.size(); i++) if (i_q[i] == q && i_t[i] < 0) i_t[i] = cyc;
      pend[q] = 0;
      ring_sq(q, sq_t[q]);
    end
  endtask

  task automatic wait_clk(input int n);
    repeat (n) @(negedge clk);
  endtask
  function automatic int outstanding();
    int s = 0;
    for (int q = 0; q < NQ; q++) s += unrung[q];
    s += i_q.size();
    return s + ord.size();
  endfunction
  task automatic drain(input string ph);
    int t;
    for (int q = 0; q < NQ; q++) flush_sq(q);
    t = 0;
    while (outstanding() != 0 && t < 40000) begin @(negedge clk); t++; end
    if (outstanding() != 0) fail($sformatf("%s: %0d completions missing", ph, outstanding()));
    wait_clk(4);
    if (n_cqe != x_cqe || n_err != x_err || n_db != x_db || n_ru != x_ru)
      fail($sformatf("%s: events cqe %0d/%0d err %0d/%0d db %0d/%0d ru %0d/%0d",
                     ph, n_cqe, x_cqe, n_err, x_err, n_db, x_db, n_ru, x_ru));
  endtask

  task automatic enable();
    for (int i = 0; i < 65536; i++) hwr[i] = 0;
    for (int q = 0; q < NQ; q++) begin
      sq_base[16*q +: 16] = sqa(q);
      cq_base[16*q +: 16] = cqa(q);
      for (int i = 0; i < QD * 4; i++) begin hm[cqa(q) + i] = 0; hwr[cqa(q) + i] = 1; end
      sq_t[q] = 0; sq_known[q] = 0; cq_h[q] = 0; rung_h[q] = 0; cq_ph[q] = 1; unrung[q] = 0; pend[q] = 0;
      n_infl[q] = 0;
    end
    ord.delete();
    i_q.delete(); i_cid.delete(); i_op.delete(); i_ns.delete(); i_slba.delete(); i_nlb.delete();
    i_ruh.delete(); i_slot.delete(); i_sqhd.delete(); i_sc.delete(); i_t.delete();
    wait_clk(2);
    cc_en = 1;
    while (!csts_rdy) @(negedge clk);
    c_on = 1;
  endtask
  task automatic disable_ctl(input string ph);
    c_on = 0;
    cc_en = 0;
    wait_clk(3);
    if (csts_rdy) fail({ph, ": csts_rdy still high with cc_en low"});
    if (sq_head != '0 || cq_tail != '0) fail({ph, ": queue pointers not zero while off"});
  endtask

  // ---------------- byte port master ----------------
  logic [7:0] b_tag_n = 0;
  int         n_bld = 0, n_bst = 0, n_berr = 0;
  task automatic bport(input bit we, input int addr, input logic [31:0] d, output logic [31:0] rd, output bit err);
    int t0, t;
    b_req_valid = 1; b_req_we = we; b_req_addr = addr; b_req_wdata = d; b_req_tag = b_tag_n;
    @(posedge clk);
    while (!b_req_ready) @(posedge clk);
    t0 = $time / 10;                           // the clock that takes the request
    @(negedge clk);
    b_req_valid = 0; b_req_we = $urandom; b_req_addr = $urandom; b_req_wdata = $urandom;
    t = 0;
    while (!b_rsp_valid && t < 100) begin @(posedge clk); #1; t++; end
    if (!b_rsp_valid) fail("byte port: no response");
    if (($time - 1) / 10 - t0 != TSCM)
      fail($sformatf("byte port answered %0d clocks after the request, SCM latency is %0d", ($time - 1) / 10 - t0, TSCM));
    if (b_rsp_tag != b_tag_n) fail($sformatf("byte port tag %h, expected %h", b_rsp_tag, b_tag_n));
    rd = b_rsp_data; err = b_rsp_err;
    b_tag_n++;
    @(posedge clk); #1;
    if (b_rsp_valid) fail("byte port response longer than one clock");
    @(negedge clk);
  endtask
  // checked access against the SCM reference
  task automatic bcheck(input bit we, input int addr);
    logic [31:0] d, rd;
    bit          err;
    d = $urandom;
    bport(we, addr, d, rd, err);
    if (err != (addr >= DS)) fail($sformatf("byte port addr %0d err %0d", addr, err));
    if (addr >= DS) n_berr++;
    else if (we) begin
      ns_s[addr] = d; n_bst++;
      if (rd != 0) fail("byte port store answered with data");
    end else begin
      n_bld++;
      if (rd != ns_s[addr]) fail($sformatf("byte load SCM[%0d] %h, expected %h", addr, rd, ns_s[addr]));
    end
  endtask
  bit b_run = 0;
  initial forever begin
    @(negedge clk);
    if (b_run) begin
      int a;
      a = $urandom % 10 == 0 ? DS + $urandom % 1000 : DS / 2 + $urandom % (DS / 2);
      bcheck($urandom % 2, a);
      wait_clk($urandom % 4);
    end
  end

  // ---------------- test ----------------
  initial begin : main
    for (int i = 0; i < DS; i++) ns_s[i] = 0;
    for (int i = 0; i < DN; i++) ns_n[i] = 0;
    for (int h = 0; h < NRUH; h++) r_fill[h] = 0;
    for (int q = 0; q < NQ; q++) begin slot_n[q] = 0; q_seen[q] = 0; end
    for (int i = 0; i < 65536; i++) hm[i] = $urandom;
    repeat (3) @(negedge clk);
    rst_n = 1;
    wait_clk(2);
    if (csts_rdy) fail("ready while disabled");
    // doorbells while off are ignored
    ring_sq(1, 1); x_db++;
    ring_cq(2, 0); x_db++;
    wait_clk(2);

    // ---- 1: valid traffic on every pair
    enable();
    fork
      for (int k = 0; k < 40; k++) submit(0, 0, 1 + $urandom % 3);
      for (int k = 0; k < 40; k++) submit(1, 0, 1 + $urandom % 3);
      for (int k = 0; k < 40; k++) submit(2, 0, 1 + $urandom % 3);
      for (int k = 0; k < 40; k++) submit(3, 0, 1 + $urandom % 3);
    join
    drain("valid traffic");

    // ---- 2: errors, CQ back-pressure, byte port in parallel
    c_hold = 12; b_run = 1;
    fork
      for (int k = 0; k < 60; k++) submit(0, 1, 1 + $urandom % 4);
      for (int k = 0; k < 60; k++) submit(1, 1, 1 + $urandom % 4);
      for (int k = 0; k < 60; k++) submit(2, 1, 1 + $urandom % 4);
      for (int k = 0; k < 60; k++) submit(3, 1, 1 + $urandom % 4);
    join
    drain("errors and byte port");
    b_run = 0; c_hold = 0;
    wait_clk(20);

    // ---- 2b: CQs left full for a long time
    c_hold = 300;
    fork
      for (int k = 0; k < 20; k++) submit(0, 0, 2);
      for (int k = 0; k < 20; k++) submit(2, 0, 1);
    join
    drain("full CQs");
    c_hold = 0;

    // ---- 3: invalid doorbell values
    ring_sq(0, QD); x_db++;
    ring_cq(3, QD + 5); x_db++;
    ring_sq(2, 16'hFFFF); x_db++;
    wait_clk(4);
    drain("doorbells");

    // ---- 4: round robin: load every SQ while the slave stalls
    begin
      int first, seen [$];
      hold_rdy = 1;
      wait_clk(4);
      c_on = 0;
      for (int q = 0; q < NQ; q++) for (int k = 0; k < 3; k++) submit(q, 0, 3, 0, 1);  // Flush
      wait_clk(4);
      hold_rdy = 0;
      wait_clk(10);
      while (n_cqe < x_cqe + 3 * NQ) @(negedge clk);
      for (int i = 0; i < 3 * NQ; i++) seen.push_back(ord[i]);
      first = seen[0];
      for (int i = 1; i < 3 * NQ; i++)
        if (seen[i] != (seen[i - 1] + 1) % NQ) fail($sformatf("round robin: pair %0d after %0d", seen[i], seen[i - 1]));
      c_on = 1;
      drain("round robin");
    end

    // ---- 5: FDP: Writes on the NAND namespace from every pair, across reclaim units
    for (int k = 0; k < 8 * NRUH; k++) submit(k % NQ, 0, 1, 1, 2);
    for (int k = 0; k < 4; k++) submit(k % NQ, 0, 1, 1, 2, k == 0 ? NRUH : k == 1 ? 16'hFFFF : NRUH + $urandom % 500);
    for (int k = 0; k < 4; k++) submit(k % NQ, 0, 1, 1, 1, k);                  // FDP on the SCM namespace
    drain("FDP");

    // ---- 6: dual mode: block writes seen by the byte port and back
    lo_only = 0;
    for (int k = 0; k < 6; k++) begin
      submit(k % NQ, 0, 1, 1, 1);               // Write on the SCM namespace
      drain("dual mode write");
      for (int i = 0; i < 16; i++) bcheck(0, $urandom % DS);
      for (int i = 0; i < 8; i++) bcheck(1, $urandom % DS);
      submit(k % NQ, 0, 1, 2, 1);               // Read it back as blocks
      drain("dual mode read");
    end
    for (int i = 0; i < 8; i++) bcheck(0, DS + $urandom % 100);   // out of range

    // ---- 6b: media latency: with a slave that never stalls, a one-block
    // command's doorbell-to-completion time differs between the namespaces
    // by exactly the media time difference
    begin
      int t1 [4];
      p_rdy = 100; p_rsp = 100; lat = 1;
      for (int k = 0; k < 4; k++) begin : b_lat
        int t0, n0;
        drain("latency setup");
        submit(1, 0, 99, k < 2 ? 2 : 1, 1 + k % 2);
        while (i_slba[i_slba.size() - 1] != 0 || i_nlb[i_nlb.size() - 1] != 0) begin
          // directed: block 0, one block (re-pick until the random draw is that)
          i_q.delete(i_q.size() - 1); i_cid.delete(i_cid.size() - 1); i_op.delete(i_op.size() - 1);
          i_ns.delete(i_ns.size() - 1); i_slba.delete(i_slba.size() - 1); i_nlb.delete(i_nlb.size() - 1);
          i_ruh.delete(i_ruh.size() - 1); i_slot.delete(i_slot.size() - 1); i_sqhd.delete(i_sqhd.size() - 1);
          i_sc.delete(i_sc.size() - 1); i_t.delete(i_t.size() - 1);
          n_infl[1]--; pend[1]--; n_cmd--;
          sq_t[1] = (sq_t[1] + QD - 1) % QD;
          submit(1, 0, 99, k < 2 ? 2 : 1, 1 + k % 2);
        end
        n0 = n_cqe;
        @(negedge clk);
        t0 = $time / 10;
        flush_sq(1);
        while (n_cqe == n0) @(negedge clk);
        t1[k] = t_cqe - t0;
      end
      drain("latency");
      if (t1[1] - t1[0] != TRD - TSCM)
        fail($sformatf("Read: NAND %0d clocks, SCM %0d, expected a difference of %0d", t1[1], t1[0], TRD - TSCM));
      if (t1[3] - t1[2] != TPROG - TSCM)
        fail($sformatf("Write: NAND %0d clocks, SCM %0d, expected a difference of %0d", t1[3], t1[2], TPROG - TSCM));
      p_rdy = 80; p_rsp = 90; lat = 4;
    end

    // ---- 7: disable and re-enable, then a last mixed burst
    disable_ctl("disable");
    ring_sq(0, 1); x_db++;
    wait_clk(2);
    enable();
    c_hold = 6;
    for (int k = 0; k < 40; k++) submit($urandom % NQ, 1, 2);
    drain("after re-enable");
    disable_ctl("end");

    // ---- summary
    if (min_lat_bad != 0) fail($sformatf("%0d commands completed faster than their media time", min_lat_bad));
    for (int q = 0; q < NQ; q++) if (q_seen[q] == 0) fail($sformatf("pair %0d never served", q));
    if (sc_seen[8'h00] == 0 || sc_seen[8'h01] == 0 || sc_seen[8'h02] == 0 || sc_seen[8'h0B] == 0 ||
        sc_seen[8'h13] == 0 || sc_seen[8'h80] == 0 || sc_seen[8'h04] == 0)
      fail("not every status code was produced");
    if (x_ru == 0 || n_fdp == 0) fail("no FDP reclaim unit filled");
    if (n_bld == 0 || n_bst == 0 || n_berr == 0) fail("byte port loads, stores or errors not exercised");
    $display("SCM_SSD: %0d commands, %0d completions (%0d errors), %0d FDP writes, %0d RU fills, nand %0d scm %0d blocks, byte port %0d loads %0d stores %0d errors",
             n_cmd, x_cqe, x_err, n_fdp, x_ru, r_nand, r_scm, n_bld, n_bst, n_berr);
    if (errors == 0) $display("TEST PASSED: SCM_SSD");
    else $display("TEST FAILED: %0d errors", errors);
    $finish;
  end

  initial begin
    #20ms;
    $display("TIMEOUT");
    $display("TEST FAILED: %0d errors", errors + 1);
    $finish;
  end
endmodule
