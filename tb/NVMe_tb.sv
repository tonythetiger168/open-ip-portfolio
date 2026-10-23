// SPDX-License-Identifier: Apache-2.0
// NVMe_top testbench: a host model with its own memory. The host builds
// submission queue entries (Write, Read, Flush and malformed commands with
// random fields), rings the SQ tail doorbell singly or in batches, and a
// consumer process polls the completion queue by phase tag, checks each
// entry and rings the CQ head doorbell after a random delay (so the CQ
// fills up). The memory slave takes requests with random back-pressure and
// answers reads in order after a random latency.
//  - a reference namespace is updated as commands are submitted (they run
//    in order), so every Read's data is known at submission; each
//    completion is checked for CID, status, DNR, SQ head, SQ identifier and
//    phase; data of a Read is checked in the host buffer
//  - the controller may write only to Read buffers in flight and to the CQ
//  - event pulses are counted against the completions and doorbells
//  - the controller is disabled with commands in flight (in each engine
//    state) and re-enabled with new queue bases, invalid doorbells are
//    written, and a reset lands with traffic in flight
// The bound checker (tb/cov/NVMe_sva.sv) checks every output on every clock
// against its own model.
`timescale 1ns/1ps
module NVMe_tb;
  localparam int QD = 8, NBLK = 8, BLKDW = 4, ND = NBLK * BLKDW;
  logic clk = 0, rst_n = 0;
  always #5 clk = ~clk;
  int errors = 0;
  task automatic fail(input string s);
    errors++;
    $display("ERROR: %s @%0t", s, $time);
  endtask

  logic        cc_en = 0, sq_db_valid = 0, cq_db_valid = 0, m_req_ready = 0, m_rsp_valid = 0;
  logic [15:0] sq_base = 0, cq_base = 0, sq_db = 0, cq_db = 0;
  logic [31:0] m_rsp_data = 0;
  wire         csts_rdy, m_req_valid, m_req_we, ev_cqe, ev_err, ev_db;
  wire  [2:0]  sq_head, cq_tail;
  wire  [15:0] m_req_addr;
  wire  [31:0] m_req_wdata;

  NVMe_top #(.QD(QD), .NBLK(NBLK), .BLKDW(BLKDW)) dut (.*);

  // ---------------- host memory and slave ----------------
  logic [31:0] hm [0:65535];
  bit          hbusy [0:65535];                // allocated (queues, buffers)
  bit          hwr [0:65535];                  // the controller may write here
  logic [31:0] rs_d [$];
  int          rs_t [$];
  int          cyc = 0, p_rdy = 80, lat = 4, p_rsp = 90;
  bit          hold_rdy = 0;                   // the slave takes no request
  int          n_wr = 0, n_rd = 0;
  always @(posedge clk) begin
    cyc++;
    if (!rst_n) begin
      rs_d.delete(); rs_t.delete();
    end else begin
      if (m_rsp_valid) begin void'(rs_d.pop_front()); void'(rs_t.pop_front()); end
      if (m_req_valid && m_req_ready) begin
        if (m_req_we) begin
          if (!hwr[m_req_addr]) fail($sformatf("write to %h, not a Read buffer or the CQ", m_req_addr));
          hm[m_req_addr] = m_req_wdata;
          n_wr++;
        end else begin
          rs_d.push_back(hm[m_req_addr]);
          rs_t.push_back(cyc + 1 + $urandom % lat);
          n_rd++;
        end
      end
    end
  end
  always @(negedge clk) begin
    m_req_ready = !hold_rdy && $urandom % 100 < p_rdy;
    m_rsp_valid = rs_d.size() != 0 && rs_t[0] <= cyc && $urandom % 100 < p_rsp;
    m_rsp_data = m_rsp_valid ? rs_d[0] : $urandom;
  end

  // ---------------- reference ----------------
  logic [31:0] nm [0:ND-1];
  // expected completions, in order
  logic [15:0] e_cid [$];
  logic [7:0]  e_sc [$];
  int          e_sqhd [$], e_buf [$], e_n [$];
  bit          e_rd [$];
  logic [31:0] e_rdat [$];
  int          x_cqe = 0, x_err = 0, x_db = 0, n_cqe = 0, n_err = 0, n_db = 0;
  int          sc_seen [0:255];
  always @(posedge clk) if (rst_n) begin
    if (ev_cqe) n_cqe++;
    if (ev_err) n_err++;
    if (ev_db) n_db++;
  end

  int          sq_tail = 0, known_sqh = 0, c_head = 0, unrung = 0;
  bit          c_phase = 1, c_on = 0;
  int          c_hold = 0;                     // CQ doorbell delay, clocks

  task automatic mark(input int a, input int n, input bit busy, input bit wr);
    for (int i = 0; i < n; i++) begin hbusy[(a + i) % 65536] = busy; hwr[(a + i) % 65536] = wr; end
  endtask
  // a free region of n dwords
  function automatic int alloc(input int n);
    int a;
    bit ok;
    for (int t = 0; t < 1000; t++) begin
      a = $urandom % (65536 - n);
      ok = 1;
      for (int i = 0; i < n; i++) if (hbusy[a + i]) ok = 0;
      if (ok) return a;
    end
    $display("ERROR: no free host memory");
    return 0;
  endfunction

  // ---------------- consumer ----------------
  initial forever begin
    @(negedge clk);
    if (c_on) begin : b_cons
      int a;
      logic [31:0] d2, d3;
      a = (cq_base + c_head * 4) % 65536;
      d3 = hm[(a + 3) % 65536];
      if (d3[16] == c_phase) begin
        d2 = hm[(a + 2) % 65536];
        if (e_cid.size() == 0) fail("completion with none expected");
        else begin
          if (hm[a] != 0 || hm[(a + 1) % 65536] != 0) fail("CQE DW0/DW1 not zero");
          if (d2 != {16'd1, 16'(e_sqhd[0])}) fail($sformatf("CQE DW2 %h, expected SQHD %0d", d2, e_sqhd[0]));
          if (d3[15:0] != e_cid[0]) fail($sformatf("CQE CID %h, expected %h", d3[15:0], e_cid[0]));
          if (d3[24:17] != e_sc[0] || d3[27:25] != 3'd0 || d3[30:28] != 3'd0 || d3[31] != (e_sc[0] != 0))
            fail($sformatf("CQE CID %h status %h, expected SC %h", d3[15:0], d3[31:17], e_sc[0]));
          sc_seen[e_sc[0]]++;
          if (e_rd[0])
            for (int i = 0; i < e_n[0]; i++) begin
              logic [31:0] x;
              x = e_rdat.pop_front();
              if (hm[(e_buf[0] + i) % 65536] !== x)
                fail($sformatf("Read CID %h dword %0d: %h, expected %h", e_cid[0], i, hm[(e_buf[0] + i) % 65536], x));
            end
          if (e_buf[0] >= 0) mark(e_buf[0], e_n[0], 0, 0);
          x_cqe++;
          if (e_sc[0] != 0) x_err++;
          known_sqh = e_sqhd[0];
          void'(e_cid.pop_front()); void'(e_sc.pop_front()); void'(e_sqhd.pop_front());
          void'(e_buf.pop_front()); void'(e_n.pop_front()); void'(e_rd.pop_front());
        end
        c_head = (c_head + 1) % QD;
        if (c_head == 0) c_phase = !c_phase;
        unrung++;
      end
      if (unrung != 0 && (c_hold == 0 || $urandom % c_hold == 0)) begin
        cq_db_valid = 1; cq_db = 16'(c_head);
        @(negedge clk);
        cq_db_valid = 0; cq_db = $urandom % 3 == 0 ? 16'hFFFF : 16'h0000;
        unrung = 0;
      end
    end
  end

  // ---------------- producer ----------------
  int pending = 0;                             // submitted, doorbell not rung
  task automatic ring_sq();
    sq_db_valid = 1; sq_db = 16'(sq_tail);
    @(negedge clk);
    sq_db_valid = 0; sq_db = $urandom % 3 == 0 ? 16'hFFFF : 16'h0000;
    pending = 0;
  endtask

  function automatic logic [7:0] status(input logic [7:0] op, input logic [1:0] fuse, input logic [1:0] psdt,
                                        input logic [31:0] nsid, input logic [31:0] prp, input logic [31:0] phi,
                                        input logic [31:0] slo, input logic [31:0] shi, input logic [15:0] nlb);
    if (op > 8'd2) return 8'h01;
    if (fuse != 0 || psdt != 0) return 8'h02;
    if (!(nsid == 1 || op == 0 && nsid == 32'hFFFFFFFF)) return 8'h0B;
    if (op != 0 && prp[1:0] != 0) return 8'h13;
    if (op != 0 && !(shi == 0 && slo < NBLK && nlb < NBLK && slo + nlb < NBLK)) return 8'h80;
    if (op != 0 && (phi != 0 || prp[31:18] != 0)) return 8'h04;
    return 8'h00;
  endfunction

  // kind: 0 valid Write / Read / Flush, 1 any (errors too), 2 Write of a pattern, 3 Read, 4 Flush
  int          f_slba = -1, f_nlb = -1, n_cmd = 0;
  logic [32:0] f_nsid = '1;                    // bit 32 set: not forced
  int          f_op = -1, f_fuse = -1, f_prpw = -1;
  logic [31:0] f_pat = 0;
  task automatic submit(input int kind, input int batch);
    logic [31:0] e [0:15];
    logic [7:0]  op, sc;
    logic [1:0]  fuse, psdt;
    logic [31:0] nsid, prp, phi, slo, shi, c12;
    int          r, n, b;
    while ((sq_tail + 1) % QD == known_sqh && !stop) @(negedge clk);
    for (int i = 0; i < 16; i++) e[i] = $urandom;
    r = $urandom % 100;
    op = kind == 2 ? 8'd1 : kind == 3 ? 8'd2 : kind == 4 ? 8'd0 : r < 45 ? 8'd1 : r < 85 ? 8'd2 : 8'd0;
    fuse = 0; psdt = 0;
    nsid = f_nsid[32] ? (op == 0 && $urandom % 3 == 0 ? 32'hFFFFFFFF : 32'd1) : f_nsid[31:0];
    slo = f_slba >= 0 ? f_slba : $urandom % NBLK;
    shi = 0;
    c12 = $urandom;
    c12[15:0] = f_nlb >= 0 ? f_nlb : $urandom % (NBLK - slo);
    prp = {14'd0, 16'($urandom), 2'b00};
    phi = 0;
    // errors, sometimes two at once
    for (int k = 0; k < (kind == 1 ? ($urandom % 4 == 0 ? 2 : 1) : 0); k++) begin
      int r2;
      r = $urandom % 100;
      r2 = $urandom % 6;
      if (r < 8) op = 8'd3 + 8'($urandom % 253);
      else if (r < 14) begin fuse = $urandom; psdt = $urandom; end
      else if (r < 22)
        nsid = r2 == 0 ? 32'd0 : r2 == 1 ? 32'hFFFFFFFF : r2 == 2 ? $urandom : r2 == 3 ? {16'(1 + $urandom % 65535), 16'h0001} :
               r2 == 4 ? 32'h0000FFFF : 32'd1 << (1 + $urandom % 31);
      else if (r < 30) prp[1:0] = 1 + $urandom % 3;
      else if (r < 36) slo = r2 < 2 ? NBLK + $urandom % 4 : r2 < 4 ? $urandom : 32'd1 << (3 + $urandom % 29);
      else if (r < 40) shi = r2 < 2 ? 32'h80000000 : r2 < 4 ? 32'd1 << ($urandom % 32) : $urandom;
      else if (r < 46)
        c12[15:0] = r2 < 2 ? NBLK - slo + $urandom % 3 : r2 < 4 ? 16'($urandom) : 16'(1 << (3 + $urandom % 13)) + 16'($urandom % 4);
      else if (r < 50) phi = 32'd1 << ($urandom % 32);
      else if (r < 54) prp[31:18] = 14'd1 << ($urandom % 14);
      else if (r < 56) begin prp[31:18] = $urandom; phi = $urandom; end
    end
    if (f_op >= 0) op = f_op;
    if (f_fuse >= 0) fuse = f_fuse;
    if (f_prpw >= 0) prp[f_prpw] = 1'b1;
    sc = status(op, fuse, psdt, nsid, prp, phi, slo, shi, c12[15:0]);
    n = 0; b = -1;
    if (sc == 0 && op != 0) begin
      n = (c12[15:0] + 1) * BLKDW;
      b = alloc(n);
      prp[17:2] = b;
      mark(b, n, 1, op == 2);
      for (int i = 0; i < n; i++)
        if (op == 1) begin
          hm[b + i] = kind == 2 ? f_pat : $urandom;
          nm[slo * BLKDW + i] = hm[b + i];
        end else begin
          hm[b + i] = $urandom;
          e_rdat.push_back(nm[slo * BLKDW + i]);
        end
    end
    e[0] = {e[0][31:16], psdt, e[0][13:10], fuse, op};
    e[1] = nsid; e[6] = prp; e[7] = phi; e[10] = slo; e[11] = shi; e[12] = c12;
    for (int i = 0; i < 16; i++) hm[(sq_base + sq_tail * 16 + i) % 65536] = e[i];
    e_cid.push_back(e[0][31:16]); e_sc.push_back(sc); e_sqhd.push_back((sq_tail + 1) % QD);
    e_buf.push_back(b); e_n.push_back(n); e_rd.push_back(sc == 0 && op == 2);
    sq_tail = (sq_tail + 1) % QD;
    n_cmd++;
    pending++;
    if (pending >= batch && !stop) ring_sq();
  endtask

  task automatic wait_clk(input int n);
    repeat (n) @(negedge clk);
  endtask
  // run the commands submitted out
  task automatic drain(input string ph);
    int t;
    if (pending != 0) ring_sq();
    t = 0;
    while ((e_cid.size() != 0 || unrung != 0) && t < 20000) begin @(negedge clk); t++; end
    if (e_cid.size() != 0) fail($sformatf("%s: %0d completions missing", ph, e_cid.size()));
    wait_clk(4);
    if (n_cqe != x_cqe || n_err != x_err || n_db != x_db)
      fail($sformatf("%s: events cqe %0d/%0d err %0d/%0d db %0d/%0d", ph, n_cqe, x_cqe, n_err, x_err, n_db, x_db));
  endtask

  // bring the controller up with new queues (it must be off)
  task automatic enable(input logic [15:0] sb, input logic [15:0] cb);
    for (int i = 0; i < 65536; i++) begin hbusy[i] = 0; hwr[i] = 0; end
    sq_base = sb; cq_base = cb;
    mark(sb, QD * 16, 1, 0);
    mark(cb, QD * 4, 1, 1);
    for (int i = 0; i < QD * 4; i++) hm[(cb + i) % 65536] = 0;
    sq_tail = 0; known_sqh = 0; c_head = 0; c_phase = 1; unrung = 0; pending = 0;
    e_cid.delete(); e_sc.delete(); e_sqhd.delete(); e_buf.delete(); e_n.delete(); e_rd.delete(); e_rdat.delete();
    wait_clk(2);
    cc_en = 1;
    while (!csts_rdy) @(negedge clk);
    c_on = 1;
  endtask
  task automatic disable_ctl();
    c_on = 0;
    cc_en = 0;
    while (csts_rdy) @(negedge clk);
    // whatever was in flight is gone; the namespace may hold part of a Write
    for (int i = 0; i < ND; i++) nm[i] = dut.mem[i];
    wait_clk(3);
    n_cqe = 0; n_err = 0; n_db = 0; x_cqe = 0; x_err = 0; x_db = 0;
  endtask
  function automatic logic [15:0] rnd_base(input int n);
    return 16'($urandom % (65536 - n));
  endfunction

  task automatic traffic(input int n, input int kind, input int maxb);
    for (int i = 0; i < n && !stop; i++) begin
      submit(kind, 1 + $urandom % maxb);
      if ($urandom % 4 == 0) wait_clk($urandom % 30);
    end
  endtask

  // a background producer (Icarus cannot fork inside a task)
  int bg_n = 0, bg_kind = 0;
  bit bg_busy = 0, stop = 0;
  initial forever begin
    @(negedge clk);
    if (bg_n != 0) begin
      bg_busy = 1;
      traffic(bg_n, bg_kind, 3);
      bg_n = 0;
      bg_busy = 0;
    end
  end
  task automatic bg_stop();
    stop = 1;
    while (bg_busy) @(negedge clk);
    bg_n = 0;
    stop = 0;
  endtask

  // disable while the engine is in state s (anywhere after a while when
  // s < 0); out: 1 with memory reads owed, 2 with all of a whole-namespace
  // Write requested and at least two of its reads owed, 3 with a request
  // held on the channel
  task automatic abort_in(input int s, input int out, input int kind);
    int t;
    bg_kind = kind; bg_n = 12;
    t = 0;
    if (s < 0) wait_clk(20 + $urandom % 60);
    else
      while (!(int'(dut.st) == s && (out == 0 || out == 1 && dut.ri != dut.rr || out == 2 && dut.ri == ND && dut.rr < ND - 2 ||
                                     out == 3 && dut.ri < 2)) && t < 5000) begin @(negedge clk); t++; end
    if (out == 3) begin
      // a write held on the channel
      hold_rdy = 1;
      while (!m_req_valid) @(negedge clk);
    end
    if (t == 5000) fail($sformatf("abort: state %0d never reached", s));
    c_on = 0;
    cc_en = 0;
    wait_clk(5);
    hold_rdy = 0;
    bg_stop();
    disable_ctl();
  endtask
  task automatic enable_rnd();
    logic [15:0] sb, cb;
    cb = rnd_base(QD * 4);
    sb = rnd_base(QD * 16);
    while (cb < sb + QD * 16 && cb + QD * 4 > sb) sb = rnd_base(QD * 16);
    enable(sb, cb);
  endtask

  int q_seed;
  initial begin
    for (int i = 0; i < 65536; i++) begin hm[i] = $urandom; hbusy[i] = 0; hwr[i] = 0; end
    for (int i = 0; i < ND; i++) nm[i] = 0;
    for (int i = 0; i < 256; i++) sc_seen[i] = 0;
    wait_clk(3);
    rst_n = 1;
    wait_clk(3);
    // a doorbell while off
    sq_db_valid = 1; sq_db = 16'd1; x_db++;
    @(negedge clk);
    sq_db_valid = 0; cq_db_valid = 1; cq_db = 16'd0; x_db++;
    @(negedge clk);
    cq_db_valid = 0;
    wait_clk(2);
    if (n_db != x_db) fail("doorbell while off not flagged");
    n_db = 0; x_db = 0;

    // ---- clean, one command at a time
    enable(16'h0100, 16'h0800);
    traffic(30, 0, 1);
    drain("single");
    // ---- patterns over the whole namespace
    f_slba = 0; f_nlb = NBLK - 1;
    f_pat = 32'hFFFFFFFF; submit(2, 1);
    submit(3, 1);
    f_pat = 32'h00000000; submit(2, 1);
    f_pat = 32'hFFFFFFFF; submit(2, 1);
    f_pat = 32'h00000000; submit(2, 1);
    submit(3, 1);
    f_slba = -1; f_nlb = -1;
    drain("pattern");
    // single bits beyond the checked fields
    f_nsid = 33'h0_0000_FFFF; submit(4, 1);
    f_nsid = 33'h0_FFFF_0001; submit(4, 1);
    f_nsid = '1;
    f_slba = 0; f_nlb = 16'h8000; submit(3, 1);
    f_nlb = 16'h4001; submit(2, 1);
    f_nlb = 0; f_slba = 32'h0001_0000; submit(3, 1);   // SLBA with only bit 16 set
    f_slba = -1; f_nlb = -1;
    f_op = 8'h55; f_fuse = 1; submit(0, 1);        // two errors: the opcode wins
    f_op = -1; f_fuse = -1;
    f_prpw = 18; submit(2, 1);                     // PRP1 just above the window
    f_prpw = 31; submit(3, 1);
    f_prpw = -1;
    drain("bits");
    // ---- batches, errors, slow host, CQ held full
    p_rdy = 40; lat = 12; c_hold = 40;
    traffic(80, 1, 6);
    drain("errors");
    p_rdy = 100; lat = 1; p_rsp = 100; c_hold = 0;
    traffic(60, 0, 8);
    drain("fast");
    // ---- CQ full: the consumer stops ringing for a while
    c_hold = 400;
    traffic(40, 1, 4);
    drain("cq full");
    c_hold = 10; p_rdy = 70; lat = 6; p_rsp = 70;
    // ---- invalid doorbells while ready
    c_on = 0;
    wait_clk(5);
    sq_db_valid = 1; sq_db = 16'(QD) + 16'($urandom % (65536 - QD)); x_db++;
    @(negedge clk);
    sq_db = 16'hFFFF; x_db++;
    @(negedge clk);
    sq_db = 16'(QD); x_db++;
    @(negedge clk);
    sq_db_valid = 0; cq_db_valid = 1; cq_db = 16'hAAAA; x_db++;
    @(negedge clk);
    cq_db = 16'h5555; x_db++;
    @(negedge clk);
    cq_db = 16'(QD); x_db++;
    @(negedge clk);
    cq_db_valid = 0;
    c_on = 1;
    traffic(10, 0, 2);
    drain("bad doorbell");
    // ---- the controller disabled in each engine state, re-enabled elsewhere
    disable_ctl();
    enable(16'hFF00 - QD * 16, 16'h0003);
    traffic(20, 1, 3);
    drain("moved queues");
    for (int s = 0; s < 9; s++) begin
      case (s)
        0: abort_in(2, 1, 0);            // fetching, reads owed
        1: abort_in(3, 0, 0);            // decoding
        2: abort_in(4, 1, 2);            // a Write moving data, reads owed
        3: abort_in(4, 0, 3);            // a Read moving data
        4: abort_in(5, 0, 0);            // posting a completion
        5: abort_in(2, 0, 0);
        6: begin
          f_slba = 0; f_nlb = NBLK - 1; p_rsp = 20; p_rdy = 100;
          abort_in(4, 2, 2);
          f_slba = -1; f_nlb = -1; p_rsp = 70; p_rdy = 70;
        end
        7: abort_in(5, 3, 0);
        default: abort_in(-1, 0, 1);
      endcase
      enable_rnd();
      traffic(15, 1, 4);
      drain($sformatf("after abort %0d", s));
    end
    // a disable straight from idle
    disable_ctl();
    enable(16'h1234, 16'h4321);
    traffic(40, 1, 5);
    drain("random");
    // ---- a reset with traffic in flight
    bg_kind = 0; bg_n = 30;
    wait_clk(50 + $urandom % 100);
    // two clocks into a data move
    while (dut.st != 4) @(negedge clk);
    @(negedge clk);
    while (dut.st != 4) @(negedge clk);
    c_on = 0;
    rst_n = 0;
    bg_stop();
    cc_en = 0;
    wait_clk(3);
    for (int i = 0; i < ND; i++) nm[i] = 0;
    n_cqe = 0; n_err = 0; n_db = 0; x_cqe = 0; x_err = 0; x_db = 0;
    rst_n = 1;
    wait_clk(2);
    enable(16'h2000, 16'h3000);
    traffic(30, 1, 4);
    drain("after reset");

    for (int i = 0; i < 256; i++)
      if (i == 0 || i == 1 || i == 2 || i == 4 || i == 'h0B || i == 'h13 || i == 'h80)
        if (sc_seen[i] == 0) fail($sformatf("status %h never seen", i));
    if (errors == 0) $display("TEST PASSED: NVMe (%0d commands, %0d reads, %0d writes)", n_cmd, n_rd, n_wr);
    else $display("TEST FAILED: NVMe (%0d errors)", errors);
    $finish;
  end

  initial begin
    #20ms;
    $display("TEST FAILED: NVMe (timeout, %0d completions outstanding)", e_cid.size());
    $finish;
  end
endmodule
