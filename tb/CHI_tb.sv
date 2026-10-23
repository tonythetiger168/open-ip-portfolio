// SPDX-License-Identifier: Apache-2.0
// CHI_top testbench: a home node model drives RXREQ and RXDAT under the
// node's L-Credits and hands out TXRSP / TXDAT credits at random rates.
//  - requests: ReadNoSnp (with and without Order), WriteNoSnpPtl,
//    WriteNoSnpFull, every Size, other opcodes, addresses in and beyond the
//    memory, random SrcIDs and unique TxnIDs; write data beats go out after
//    the DBID arrives, in random DataID order, interleaved between writes,
//    with random byte enables
//  - a reference memory (the host keeps one transaction per line in
//    flight) predicts every CompData beat; every response must match an
//    outstanding transaction, in the order the node must send them
//  - error flits: requests and data without a credit, data with a wrong
//    opcode, an unknown DBID, a DataID not expected or sent twice;
//    ev_err and ev_proto pulses are counted against them
//  - the node is starved of TX credits (its request slots fill), given the
//    full 15, and reset with traffic in flight
// The bound checker (tb/cov/CHI_sva.sv) checks every output on every clock
// against its own model.
`timescale 1ns/1ps
module CHI_tb;
  localparam int LINES = 16, RQ = 4, NDC = 2;
  logic clk = 0, rst_n = 0;
  always #5 clk = ~clk;
  int errors = 0;
  task automatic fail(input string s);
    errors++;
    $display("ERROR: %s @%0t", s, $time);
  endtask

  logic         rxreqflitv = 0, rxdatflitv = 0, txrsplcrdv = 0, txdatlcrdv = 0;
  logic [40:0]  rxreqflit = 0;
  logic [157:0] rxdatflit = 0;
  wire          rxreqlcrdv, rxdatlcrdv, txrspflitv, txdatflitv, ev_err, ev_proto;
  wire  [28:0]  txrspflit;
  wire  [146:0] txdatflit;

  CHI_top #(.LINES(LINES), .RQ(RQ), .NDC(NDC)) dut (.*);

  // ---------------- reference ----------------
  logic [7:0]   rm [0:LINES*64-1];
  int           busy [0:LINES-1];
  // outstanding transactions, by TxnID
  bit           t_v [0:255];
  int           t_kind [0:255];               // 1 read, 2 WriteNoSnpPtl, 3 WriteNoSnpFull, 4 unsupported
  logic [6:0]   t_src [0:255];
  bit           t_ord [0:255], t_rcpt [0:255], t_in [0:255], t_dbid [0:255];
  int           t_size [0:255], t_ln [0:255], t_nb [0:255], t_d0 [0:255], t_beat [0:255];
  logic [127:0] t_data [0:255][0:3];
  logic [7:0]   t_dbv [0:255];                // the DBID given
  int           n_out = 0;
  int           x_err = 0, x_proto = 0, n_err = 0, n_proto = 0, n_rsp = 0, n_dat = 0, n_txn = 0;
  // credits
  int           h_rq = 0, h_dc = 0;           // RXREQ / RXDAT credits the host holds
  int           g_rsp = 0, g_dat = 0;         // TX credits the node holds
  int           p_rsp = 50, p_dat = 50, max_g = 15;
  bit           cr_on = 1;

  function automatic logic [127:0] ref_beat(input int ln, input int id);
    logic [127:0] d;
    for (int b = 0; b < 16; b++) d[8 * b +: 8] = rm[ln * 64 + id * 16 + b];
    return d;
  endfunction

  // ---------------- write data sender ----------------
  // beats waiting: DBID, DataID, BE, data, opcode
  logic [7:0]   q_dbid [$];
  logic [1:0]   q_id [$];
  logic [15:0]  q_be [$];
  logic [127:0] q_d [$];
  logic [3:0]   q_op [$];
  int           p_dsend = 60;
  bit           force_nocrd = 0, no_ilv = 0;
  always @(negedge clk) begin
    rxdatflitv = 0;
    rxdatflit = {$urandom, $urandom, $urandom, $urandom, $urandom};
    if (rst_n && q_dbid.size() != 0 && h_dc > 0 && $urandom % 100 < p_dsend) begin : b_send
      int k;
      k = $urandom % 2 == 0 && q_dbid.size() > 1 && !no_ilv ? 1 : 0;   // interleave
      rxdatflitv = 1;
      rxdatflit = {q_dbid[k], q_op[k], q_id[k], q_be[k], q_d[k]};
      h_dc--;
      q_dbid.delete(k); q_id.delete(k); q_be.delete(k); q_d.delete(k); q_op.delete(k);
    end else if (force_nocrd && rst_n) begin
      rxdatflitv = 1;
      force_nocrd = 0;
    end
  end
  // TX credits to the node
  always @(negedge clk) begin
    txrsplcrdv = rst_n && cr_on && g_rsp < max_g && $urandom % 100 < p_rsp;
    txdatlcrdv = rst_n && cr_on && g_dat < max_g && $urandom % 100 < p_dat;
    if (txrsplcrdv) g_rsp++;
    if (txdatlcrdv) g_dat++;
  end

  // ---------------- monitor ----------------
  always @(posedge clk) if (rst_n) begin
    if (rxreqlcrdv) h_rq++;
    if (rxdatlcrdv) h_dc++;
    if (ev_err) n_err++;
    if (ev_proto) n_proto++;
    if (txrspflitv) begin : b_rsp
      logic [7:0] txn;
      logic [3:0] op;
      logic [1:0] err;
      txn = txrspflit[21:14]; op = txrspflit[13:10]; err = txrspflit[9:8];
      g_rsp--;
      n_rsp++;
      if (!t_v[txn]) fail($sformatf("RSP for TxnID %h, not outstanding", txn));
      else begin
        if (txrspflit[28:22] != t_src[txn]) fail($sformatf("RSP TgtID %h, expected %h", txrspflit[28:22], t_src[txn]));
        case (t_kind[txn])
          1: begin
            if (op != 4'h8 || !t_ord[txn] || t_rcpt[txn] || err != 0 || txrspflit[7:0] != 0)
              fail($sformatf("TxnID %h: RSP %h for a read", txn, txrspflit));
            t_rcpt[txn] = 1;
          end
          2: begin
            if (!t_dbid[txn]) begin
              if (op != 4'h6 || err != (t_in[txn] ? 2'b00 : 2'b10) || txrspflit[6:0] != txn[6:0])
                fail($sformatf("TxnID %h: RSP %h, expected DBIDResp", txn, txrspflit));
              t_dbid[txn] = 1;
              queue_data(txn, txrspflit[7:0]);
            end else begin
              if (op != 4'h4 || err != (t_in[txn] ? 2'b00 : 2'b10) || txrspflit[7:0] != 0)
                fail($sformatf("TxnID %h: RSP %h, expected Comp", txn, txrspflit));
              for (int i = 0; i < q_dbid.size(); i++)
                if (q_dbid[i] == t_dbv[txn] && q_op[i] == 4'h3) fail($sformatf("TxnID %h: Comp before its data", txn));
              done_txn(txn);
            end
          end
          3: begin
            if (op != 4'h5 || err != (t_in[txn] ? 2'b00 : 2'b10) || txrspflit[6:0] != txn[6:0])
              fail($sformatf("TxnID %h: RSP %h, expected CompDBIDResp", txn, txrspflit));
            t_dbid[txn] = 1;
            queue_data(txn, txrspflit[7:0]);
          end
          default: begin
            if (op != 4'h4 || err != 2'b11 || txrspflit[7:0] != 0)
              fail($sformatf("TxnID %h: RSP %h, expected Comp NDERR", txn, txrspflit));
            done_txn(txn);
          end
        endcase
      end
    end
    if (txdatflitv) begin : b_dat
      logic [7:0] txn;
      txn = txdatflit[139:132];
      g_dat--;
      n_dat++;
      if (!t_v[txn] || t_kind[txn] != 1) fail($sformatf("DAT for TxnID %h, not a read outstanding", txn));
      else begin
        if (txdatflit[146:140] != t_src[txn]) fail("DAT TgtID");
        if (t_ord[txn] && !t_rcpt[txn]) fail($sformatf("TxnID %h: CompData before ReadReceipt", txn));
        if (txdatflit[131:130] != (t_size[txn] == 7 ? 2'b11 : t_in[txn] ? 2'b00 : 2'b10)) fail($sformatf("TxnID %h: DAT RespErr", txn));
        if (txdatflit[129:128] != 2'(t_d0[txn] + t_beat[txn])) fail($sformatf("TxnID %h: DataID %0d", txn, txdatflit[129:128]));
        if (txdatflit[127:0] != t_data[txn][t_beat[txn]])
          fail($sformatf("TxnID %h beat %0d: %h, expected %h", txn, t_beat[txn], txdatflit[127:0], t_data[txn][t_beat[txn]]));
        t_beat[txn]++;
        if (t_beat[txn] == t_nb[txn]) done_txn(txn);
      end
    end
  end
  task automatic done_txn(input logic [7:0] txn);
    t_v[txn] = 0;
    if (t_ln[txn] >= 0) busy[t_ln[txn]]--;
    n_out--;
  endtask
  // the beats of a write, once its DBID is known
  task automatic queue_data(input logic [7:0] txn, input logic [7:0] dbid);
    int ids [0:3];
    int n;
    n = t_nb[txn];
    t_dbv[txn] = dbid;
    for (int i = 0; i < n; i++) ids[i] = t_d0[txn] + i;
    for (int i = n - 1; i > 0; i--) begin : b_sh
      int j, x;
      j = $urandom % (i + 1);
      x = ids[i]; ids[i] = ids[j]; ids[j] = x;
    end
    for (int i = 0; i < n; i++) begin : b_beat
      logic [15:0]  be;
      logic [127:0] d;
      d = {$urandom, $urandom, $urandom, $urandom};
      be = t_kind[txn] == 3 ? 16'hFFFF : $urandom % 4 == 0 ? 16'hFFFF : $urandom % 8 == 0 ? 16'h0000 : 16'($urandom);
      if (t_in[txn])
        for (int b = 0; b < 16; b++) if (be[b]) rm[t_ln[txn] * 64 + ids[i] * 16 + b] = d[8 * b +: 8];
      q_dbid.push_back(dbid); q_id.push_back(2'(ids[i])); q_be.push_back(be); q_d.push_back(d); q_op.push_back(4'h3);
      t_beat[txn]++;
    end
    if (t_kind[txn] == 3) done_after_data[txn] = 1;
  endtask
  // a WriteNoSnpFull ends when its last beat has gone out
  bit done_after_data [0:255];
  always @(negedge clk) begin
    for (int t = 0; t < 256; t++)
      if (done_after_data[t] && t_v[t]) begin : b_chk
        bit left;
        left = 0;
        for (int i = 0; i < q_dbid.size(); i++) if (q_dbid[i] == t_dbv[t] && q_op[i] == 4'h3) left = 1;
        if (!left) begin done_after_data[t] = 0; done_txn(t); end
      end
  end

  // ---------------- requests ----------------
  int p_out = 10, gap = 4;
  bit stop = 0;
  task automatic wait_clk(input int n);
    repeat (n) @(negedge clk);
  endtask
  function automatic logic [7:0] new_txn();
    logic [7:0] t;
    t = $urandom;
    while (t_v[t] || done_after_data[t]) t = $urandom;
    return t;
  endfunction
  // kind: 1 ReadNoSnp, 2 WriteNoSnpPtl, 3 WriteNoSnpFull, 4 another opcode
  task automatic send_req(input int kind, input int size, input bit ord, input int f_ln);
    logic [7:0]  txn;
    logic [6:0]  src;
    logic [5:0]  op;
    logic [15:0] a;
    int          ln, nb, d0;
    bit          in, wr_ok;
    txn = new_txn(); src = $urandom;
    // an address: a free line, or beyond the memory
    if (f_ln >= 0) ln = f_ln;
    else if (f_ln == -2) ln = -1;                 // the line just past the memory
    else if ($urandom % 100 < p_out) ln = -1;
    else begin
      ln = $urandom % LINES;
      while (busy[ln] != 0 && !stop) begin @(negedge clk); ln = $urandom % LINES; end
    end
    in = ln >= 0;
    a = in ? 16'(ln * 64 + $urandom % 64) :
        f_ln == -2 ? 16'(LINES * 64 + $urandom % 64) : 16'(LINES * 64 + $urandom % (65536 - LINES * 64));
    op = kind == 1 ? 6'h04 : kind == 2 ? 6'h1C : kind == 3 ? 6'h1D : 6'h00;
    if (kind == 4) begin
      op = $urandom;
      while (op == 6'h04 || op == 6'h1C || op == 6'h1D) op = $urandom;
    end
    wr_ok = kind == 2 && size != 7 || kind == 3 && size == 6;
    nb = size == 6 ? 4 : size == 5 ? 2 : 1;
    d0 = size == 6 ? 0 : size == 5 ? {a[5], 1'b0} : a[5:4];
    t_v[txn] = 1; t_src[txn] = src; t_ord[txn] = ord; t_rcpt[txn] = 0; t_in[txn] = in; t_dbid[txn] = 0;
    t_size[txn] = size; t_ln[txn] = in ? ln : -1; t_beat[txn] = 0;
    t_kind[txn] = kind == 1 ? 1 : wr_ok ? kind : 4;
    t_nb[txn] = kind == 1 ? (size == 7 ? 1 : nb) : wr_ok ? nb : 0;
    t_d0[txn] = d0;
    if (kind == 1) for (int i = 0; i < t_nb[txn]; i++) t_data[txn][i] = in && size != 7 ? ref_beat(ln, d0 + i) : 128'd0;
    if (t_kind[txn] == 4 || !in || kind == 1 && size == 7) x_err++;
    if (in) busy[ln]++;
    n_out++;
    n_txn++;
    while (h_rq == 0 && !stop) @(negedge clk);
    if (!stop) begin
      h_rq--;
      rxreqflitv = 1; rxreqflit = {src, txn, op, ord, 3'(size), a};
      @(negedge clk);
      rxreqflitv = 0; rxreqflit = {$urandom, $urandom};
    end
  endtask
  task automatic rnd_req();
    int r;
    r = $urandom % 100;
    if (r < 40) send_req(1, $urandom % 100 < 5 ? 7 : $urandom % 7, $urandom % 3 == 0, -1);
    else if (r < 70) send_req(2, $urandom % 100 < 5 ? 7 : $urandom % 7, 0, -1);
    else if (r < 92) send_req(3, $urandom % 100 < 8 ? $urandom % 6 : 6, 0, -1);
    else send_req(4, $urandom % 8, 0, -1);
  endtask
  task automatic traffic(input int n);
    for (int i = 0; i < n && !stop; i++) begin
      rnd_req();
      if (gap > 0) wait_clk($urandom % gap);
    end
  endtask
  // a background requester (Icarus cannot fork inside a task)
  int bg_n = 0;
  bit bg_busy = 0;
  initial forever begin
    @(negedge clk);
    if (bg_n != 0) begin
      bg_busy = 1;
      traffic(bg_n);
      bg_n = 0;
      bg_busy = 0;
    end
  end
  task automatic drain(input string ph);
    int t;
    t = 0;
    while ((n_out != 0 || q_dbid.size() != 0) && t < 20000) begin @(negedge clk); t++; end
    if (n_out != 0) fail($sformatf("%s: %0d transactions outstanding", ph, n_out));
    wait_clk(5);
    if (n_err != x_err || n_proto != x_proto)
      fail($sformatf("%s: events err %0d/%0d proto %0d/%0d", ph, n_err, x_err, n_proto, x_proto));
  endtask

  // a data beat for a DBID no write waits on (kind 1: with a random opcode)
  task automatic bad_data(input int kind);
    logic [7:0] dbid;
    dbid = $urandom;
    // no write may be waiting with this DBID (a write may be waiting on the other buffer)
    while (dut.w_v[dbid[7]]) dbid = $urandom;
    while (h_dc == 0) @(negedge clk);
    q_dbid.push_back(dbid); q_id.push_back(2'($urandom)); q_be.push_back(16'($urandom));
    q_d.push_back({$urandom, $urandom, $urandom, $urandom}); q_op.push_back(kind == 0 ? 4'h3 : 4'($urandom));
    x_proto++;
    while (q_dbid.size() != 0) @(negedge clk);
  endtask

  initial begin
    for (int i = 0; i < LINES * 64; i++) rm[i] = 0;
    for (int l = 0; l < LINES; l++) busy[l] = 0;
    for (int t = 0; t < 256; t++) begin t_v[t] = 0; done_after_data[t] = 0; end
    wait_clk(3);
    // a data flit on the first clock out of reset, before any credit
    @(posedge clk);
    #1 rst_n = 1; force_nocrd = 1; x_proto++;
    wait_clk(5);
    drain("no credit");
    // ---- whole lines, then reads of every size
    for (int l = 0; l < LINES; l++) send_req(3, 6, 0, l);
    drain("fill");
    for (int s = 0; s < 8; s++) for (int o = 0; o < 2; o++) send_req(1, s, o, s);
    drain("sizes");
    for (int s = 0; s < 8; s++) send_req(2, s, 0, 8 + s);
    for (int s = 0; s < 8; s++) send_req(1, 6, 0, 8 + s);
    drain("partial");
    // ---- random traffic
    traffic(150);
    drain("random");
    // ---- slow credits, slow data, then fast
    p_rsp = 5; p_dat = 5; p_dsend = 10;
    traffic(60);
    drain("slow");
    p_rsp = 100; p_dat = 100; p_dsend = 100; gap = 0;
    traffic(100);
    drain("fast");
    gap = 4; p_rsp = 50; p_dat = 50; p_dsend = 60;
    // ---- starved: no TX credits until the request slots fill; a request
    // without a credit; then the full 15 credits
    cr_on = 0;
    p_out = 0;
    begin : b_starve
      int t;
      t = 0;
      while (!(h_rq == 0 && dut.rqw - dut.rqr == RQ) && t < 3000) begin
        if (h_rq > 0) send_req(1, 6, 1, -1);
        else @(negedge clk);
        t++;
      end
      if (t == 3000) fail("the request slots never filled");
    end
    // stuck: no credit with the requester, none being granted
    while (!(h_rq == 0 && dut.rqw - dut.rqr == RQ && dut.rq_g == 0 && !rxreqlcrdv)) @(negedge clk);
    rxreqflitv = 1; rxreqflit = {$urandom, $urandom}; x_proto++;
    @(negedge clk);
    rxreqflitv = 0;
    wait_clk(5);
    max_g = 15; p_rsp = 100; p_dat = 100; cr_on = 1;
    wait_clk(40);
    drain("starved");
    p_out = 10; p_rsp = 50; p_dat = 50;
    // ---- bad data beats
    for (int k = 0; k < 3; k++) begin
      bad_data(k % 2);
      drain($sformatf("bad data %0d", k));
    end
    // a DataID twice and a DataID not expected: hold a two-beat Ptl write's
    // data, send its first beat, the same beat again, the second, then a
    // third DataID
    p_dsend = 0; no_ilv = 1;
    send_req(2, 5, 0, 3);
    while (q_dbid.size() != 2) @(negedge clk);
    q_dbid.insert(1, q_dbid[0]); q_id.insert(1, q_id[0]); q_be.insert(1, q_be[0]); q_d.insert(1, q_d[0]); q_op.insert(1, 4'h3);
    q_dbid.push_back(q_dbid[0]); q_id.push_back(2'(q_id[0] + 2'd2)); q_be.push_back(16'hFFFF); q_d.push_back(128'd0); q_op.push_back(4'h3);
    x_proto += 2;
    p_dsend = 100;
    wait_clk(30);
    drain("bad DataID");
    // a beat with another opcode and a beat with the TxnID bits of the DBID
    // wrong, each otherwise what a held write waits for
    p_dsend = 0;
    send_req(2, 4, 0, 5);
    while (q_dbid.size() != 1) @(negedge clk);
    q_dbid.push_front(q_dbid[0] ^ 8'h01); q_id.push_front(q_id[0]); q_be.push_front(q_be[0]); q_d.push_front(q_d[0]); q_op.push_front(4'h3);
    q_dbid.push_front(q_dbid[1]); q_id.push_front(q_id[1]); q_be.push_front(q_be[1]); q_d.push_front(q_d[1]); q_op.push_front(4'h5);
    x_proto += 2;
    p_dsend = 100;
    wait_clk(30);
    drain("bad opcode, TxnID");
    no_ilv = 0;
    // two Comps owed at once (TXRSP credits held back while both writes'
    // data comes in): slot 0's goes first
    p_dsend = 0;
    send_req(2, 4, 0, 6);
    send_req(2, 4, 0, 7);
    while (q_dbid.size() != 2) @(negedge clk);
    p_rsp = 0;
    while (dut.c_rsp != 0) begin
      if (h_rq > 0) send_req(1, 0, 1, 9);
      else @(negedge clk);
    end
    p_dsend = 100;
    begin : b_two
      int t;
      t = 0;
      while (dut.w_comp != 2'b11 && t < 200) begin @(negedge clk); t++; end
      if (t == 200) fail("two Comps never owed at once");
    end
    p_rsp = 50;
    drain("two Comps");
    // the line just past the memory: DERR
    send_req(3, 6, 0, -2);
    send_req(1, 6, 0, -2);
    send_req(2, 4, 0, -2);
    send_req(1, 6, 0, 0);
    drain("past the memory");
    // ---- reset with traffic in flight
    bg_n = 300;
    wait_clk(150);
    // in the middle of a CompData burst
    begin : b_mid
      int t, p_beat;
      t = 0; p_beat = 0;
      // two clocks into it
      while (!(dut.beat != 0 && p_beat != 0) && t < 20000) begin p_beat = dut.beat; @(negedge clk); t++; end
    end
    stop = 1;
    rst_n = 0;
    while (bg_busy) @(negedge clk);
    wait_clk(3);
    for (int i = 0; i < LINES * 64; i++) rm[i] = 0;
    for (int l = 0; l < LINES; l++) busy[l] = 0;
    for (int t = 0; t < 256; t++) begin t_v[t] = 0; done_after_data[t] = 0; end
    q_dbid.delete(); q_id.delete(); q_be.delete(); q_d.delete(); q_op.delete();
    n_out = 0; h_rq = 0; h_dc = 0; g_rsp = 0; g_dat = 0;
    x_err = 0; x_proto = 0; n_err = 0; n_proto = 0;
    rxreqflitv = 0;
    stop = 0;
    rst_n = 1;
    traffic(60);
    drain("after reset");

    if (errors == 0) $display("TEST PASSED: CHI (%0d transactions, %0d RSP, %0d DAT flits)", n_txn, n_rsp, n_dat);
    else $display("TEST FAILED: CHI (%0d errors)", errors);
    $finish;
  end

  initial begin
    #20ms;
    $display("TEST FAILED: CHI (timeout, %0d outstanding)", n_out);
    $finish;
  end
endmodule
