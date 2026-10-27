// SPDX-License-Identifier: Apache-2.0
// UALink_top testbench: a TB originator on the four UPLI channels.
//  - the originator counts the request and data credits it is granted,
//    sends requests (reads and writes of 1..8 beats, FETCH_ADD, SWAP, CAS
//    with and without a match) and their data beats on their own schedule,
//    and grants read and write response credits at a variable rate
//  - a reference memory takes each request's effect in order; every
//    response is checked in order on its channel (tag, data, last, status)
//  - error requests (invalid command, misaligned, past the memory, atomic
//    with len != 0), a wrong od_last, a request and a data beat without a
//    credit, a response credit past 15; reset with traffic in flight
// The bound checker (tb/cov/UALink_sva.sv) checks every output on every
// clock against its own model.
`timescale 1ns/1ps
module UALink_tb;
  localparam int MW = 16, RQ = 4, DQ = 8;
  logic clk = 0, rst_n = 0;
  always #5 clk = ~clk;
  int errors = 0;
  task automatic fail(input string s);
    errors++;
    $display("ERROR: %s @%0t", s, $time);
  endtask
  task automatic wait_clk(input int n); repeat (n) @(negedge clk); endtask

  logic        req_valid = 0, od_valid = 0, od_last = 0, rd_crd = 0, wr_crd = 0;
  logic [2:0]  req_cmd = 0, req_len = 0;
  logic [7:0]  req_tag = 0, od_be = 0;
  logic [15:0] req_addr = 0;
  logic [63:0] od_data = 0;
  wire         req_crd, od_crd, rd_valid, rd_last, wr_valid, ev_err, ev_proto;
  wire  [7:0]  rd_tag, wr_tag;
  wire  [63:0] rd_data;
  wire  [1:0]  rd_status, wr_status;
  UALink_top #(.MW(MW), .RQ(RQ), .DQ(DQ)) dut (.*);

  // ---------------- reference ----------------
  logic [63:0] r_mem [0:MW-1];
  initial for (int i = 0; i < MW; i++) r_mem[i] = 0;
  logic [74:0] e_rd [$];                         // {tag, data, last, status}
  logic [9:0]  e_wr [$];                         // {tag, status}
  logic [72:0] oq [$];                           // data beats to send {data, be, last}
  int n_req = 0, n_rd = 0, n_wr = 0, n_err = 0, x_err = 0, n_proto = 0, x_proto = 0;
  int n_ok_rd = 0, n_ok_wr = 0, n_at = 0;

  // knobs
  int  p_req = 60, p_od = 70, p_rc = 70, p_wc = 70, p_err = 0;
  bit  req_on = 0, crd_on = 1;
  bit  nocrd_req = 0, nocrd_od = 0, bad_last = 0;
  int  fix_w = -1, fix_len = 0, fix_cmd = -1;    // a fixed request
  logic [63:0] fix_data = 0;

  // one request: its effect on the reference, its expected responses, its data
  task automatic make_req(output logic [2:0] cmd, output logic [15:0] addr, output logic [2:0] len, input logic [7:0] tag);
    int w, k, st, nb;
    bit bad, at;
    logic [63:0] d [0:7];
    logic [7:0]  be [0:7];
    logic [63:0] old;
    k = $urandom % 100;
    cmd = k < 35 ? 0 : k < 70 ? 1 : k < 80 ? 2 : k < 90 ? 3 : 4;
    w = $urandom % MW;
    len = $urandom % 8;
    if (cmd >= 2 || w + len >= MW) len = cmd >= 2 ? 0 : MW - 1 - w;
    addr = 16'(w * 8);
    if (fix_cmd >= 0) begin cmd = fix_cmd; w = fix_w; len = fix_len; addr = 16'(w * 8); end
    if ($urandom % 100 < p_err) begin
      case ($urandom % 5)
        0: cmd = 5 + $urandom % 3;
        1: addr[2:0] = 1 + $urandom % 7;
        2: if (cmd >= 2) len = 1 + $urandom % 7; else addr[2:0] = 1 + $urandom % 7;
        3: begin addr = $urandom; addr[2:0] = 0; if (addr[15:3] + (cmd >= 2 ? 0 : len) < MW) addr[15] = 1; end
        default: if (cmd <= 1) begin                   // runs past the last word
                   w = MW - 1 - $urandom % 4; len = 4 + $urandom % 4; addr = 16'(w * 8);
                 end else addr[15:14] = 2'b11;
      endcase
    end
    at = cmd >= 2 && cmd <= 4;
    bad = cmd > 4 || addr[2:0] != 0 || at && len != 0;
    w = addr[15:3];
    st = bad ? 2 : w + (at ? 0 : len) >= MW ? 1 : 0;
    nb = cmd == 1 ? len + 1 : cmd == 2 || cmd == 3 ? 1 : cmd == 4 ? 2 : 0;
    for (int i = 0; i < nb; i++) begin
      d[i] = {$urandom, $urandom};
      be[i] = $urandom % 3 == 0 ? 8'hFF : 8'($urandom);
      if (fix_cmd >= 0) begin d[i] = fix_data; be[i] = 8'hFF; end
    end
    if (cmd == 4 && st == 0 && $urandom % 2) d[0] = r_mem[w];        // CAS: a match
    for (int i = 0; i < nb; i++) oq.push_back({d[i], be[i], i == nb - 1});
    if (st != 0) x_err++;
    case (cmd)
      0: if (st != 0) e_rd.push_back({tag, 64'd0, 1'b1, 2'(st)});
         else for (int i = 0; i <= len; i++) e_rd.push_back({tag, r_mem[w + i], i == len, 2'd0});
      1: begin
        if (st == 0)
          for (int i = 0; i <= len; i++)
            for (int b = 0; b < 8; b++) if (be[i][b]) r_mem[w + i][8*b +: 8] = d[i][8*b +: 8];
        e_wr.push_back({tag, 2'(st)});
      end
      2, 3, 4: begin
        if (st != 0) e_rd.push_back({tag, 64'd0, 1'b1, 2'(st)});
        else begin
          old = r_mem[w];
          e_rd.push_back({tag, old, 1'b1, 2'd0});
          r_mem[w] = cmd == 2 ? old + d[0] : cmd == 3 ? d[0] : old == d[0] ? d[1] : old;
          n_at++;
        end
      end
      default: e_wr.push_back({tag, 2'(st)});
    endcase
  endtask

  // ---------------- originator ----------------
  int m_rq = 0, m_od = 0;                        // credits held
  int c_rd = 0, c_wr = 0;                        // response credits the completer holds
  int fix_n = 0;                                 // fixed requests still to send
  bit raw = 0;                                   // send raw_* as is
  logic [2:0] raw_cmd = 0, raw_len = 0;
  logic [7:0] raw_tag = 0;
  logic [15:0] raw_addr = 0;
  always @(negedge clk) begin : b_req
    logic [2:0]  c, l;
    logic [15:0] a;
    req_valid = 0;
    {req_cmd, req_tag, req_addr, req_len} = $urandom;
    if (rst_n && req_crd) m_rq++;
    if (rst_n && nocrd_req) begin
      nocrd_req = 0; req_valid = 1; x_proto++;
    end else if (rst_n && raw && m_rq > 0) begin
      raw = 0; req_valid = 1; req_cmd = raw_cmd; req_tag = raw_tag; req_addr = raw_addr; req_len = raw_len;
      m_rq--; n_req++;
    end else if (rst_n && m_rq > 0 && (req_on && $urandom % 100 < p_req || fix_n > 0)) begin
      if (fix_n > 0) fix_n--;
      req_tag = $urandom;
      make_req(c, a, l, req_tag);
      req_valid = 1; req_cmd = c; req_addr = a; req_len = l;
      m_rq--; n_req++;
    end
  end
  always @(negedge clk) begin : b_od
    logic [72:0] b;
    od_valid = 0;
    {od_data, od_be, od_last} = {$urandom, $urandom, $urandom};
    if (rst_n && od_crd) m_od++;
    if (rst_n && nocrd_od) begin
      nocrd_od = 0; od_valid = 1; x_proto++;
    end else if (rst_n && m_od > 0 && oq.size() != 0 && $urandom % 100 < p_od) begin
      b = oq.pop_front();
      od_valid = 1; {od_data, od_be, od_last} = b;
      if (bad_last) begin bad_last = 0; od_last = !od_last; x_proto++; end
      m_od--;
    end
  end
  bit over_rd = 0, over_wr = 0;
  always @(negedge clk) begin
    rd_crd = 0; wr_crd = 0;
    if (rst_n && (crd_on && c_rd < 15 && $urandom % 100 < p_rc || over_rd)) begin
      rd_crd = 1;
      if (over_rd) begin over_rd = 0; x_proto++; end else c_rd++;
    end
    if (rst_n && (crd_on && c_wr < 15 && $urandom % 100 < p_wc || over_wr)) begin
      wr_crd = 1;
      if (over_wr) begin over_wr = 0; x_proto++; end else c_wr++;
    end
  end

  // ---------------- responses ----------------
  always @(negedge clk) if (rst_n) begin : b_chk
    logic [74:0] e;
    logic [9:0]  f;
    if (ev_proto) n_proto++;
    if (ev_err) n_err++;
    if (rd_valid) begin
      c_rd--; n_rd++;
      if (e_rd.size() == 0) fail("read response with none expected");
      else begin
        e = e_rd.pop_front();
        if ({rd_tag, rd_data, rd_last, rd_status} !== e)
          fail($sformatf("RD tag %h data %h last %0d st %0d, expected tag %h data %h last %0d st %0d",
                         rd_tag, rd_data, rd_last, rd_status, e[74:67], e[66:3], e[2], e[1:0]));
        if (e[1:0] == 0) n_ok_rd++;
      end
    end
    if (wr_valid) begin
      c_wr--; n_wr++;
      if (e_wr.size() == 0) fail("write response with none expected");
      else begin
        f = e_wr.pop_front();
        if ({wr_tag, wr_status} !== f)
          fail($sformatf("WR tag %h st %0d, expected tag %h st %0d", wr_tag, wr_status, f[9:2], f[1:0]));
        if (f[1:0] == 0) n_ok_wr++;
      end
    end
  end

  task automatic drain(input string ph);
    int t;
    t = 0;
    while ((e_rd.size() != 0 || e_wr.size() != 0 || oq.size() != 0 || fix_n != 0) && t < 20000) begin @(negedge clk); t++; end
    if (t == 20000) fail($sformatf("%s: stuck (%0d reads, %0d writes, %0d beats left)", ph, e_rd.size(), e_wr.size(), oq.size()));
    wait_clk(5);
    if (n_proto != x_proto) fail($sformatf("%s: ev_proto %0d, expected %0d", ph, n_proto, x_proto));
    if (n_err != x_err) fail($sformatf("%s: ev_err %0d, expected %0d", ph, n_err, x_err));
    $display("%s: %0d requests, %0d read beats (%0d OK), %0d write responses (%0d OK), %0d atomics, %0d errors",
             ph, n_req, n_rd, n_ok_rd, n_wr, n_ok_wr, n_at, n_err);
  endtask
  // fixed requests: n of cmd at word w, len, data
  task automatic fixed(input int cmd, input int w, input int len, input logic [63:0] d, input int n);
    fix_cmd = cmd; fix_w = w; fix_len = len; fix_data = d; fix_n = n;
    while (fix_n != 0) @(negedge clk);
    fix_cmd = -1;
  endtask

  // a READ (or an invalid command) sent as is, that fails with status st
  task automatic raw_bad(input logic [2:0] c, input logic [15:0] a, input logic [2:0] l, input int st);
    while (raw) @(negedge clk);
    if (c == 0) e_rd.push_back({8'h3C, 64'd0, 1'b1, 2'(st)}); else e_wr.push_back({8'h3C, 2'(st)});
    x_err++;
    raw_cmd = c; raw_tag = 8'h3C; raw_addr = a; raw_len = l; raw = 1;
    while (raw) @(negedge clk);
  endtask
  task automatic raw_ur(input logic [15:0] a, input logic [2:0] l);
    raw_bad(0, a, l, 1);
  endtask

  initial begin
    wait_clk(3);
    rst_n = 1;
    // a request before any credit
    nocrd_req = 1;
    wait_clk(10);
    if (m_rq != RQ || m_od != DQ) fail($sformatf("%0d / %0d credits after reset", m_rq, m_od));
    // every memory bit both ways
    fixed(1, 0, 7, '1, 1); fixed(1, 8, 7, '1, 1);
    fixed(0, 0, 7, 0, 1); fixed(0, 8, 7, 0, 1);
    fixed(1, 0, 7, '0, 1); fixed(1, 8, 7, '0, 1);
    fixed(0, 0, 7, 0, 1); fixed(0, 8, 7, 0, 1);
    drain("fill");
    // random traffic
    req_on = 1;
    wait_clk(3000);
    req_on = 0;
    drain("random");
    // response credits scarce, data slow
    p_rc = 8; p_wc = 8; p_od = 30; req_on = 1;
    wait_clk(2000);
    req_on = 0;
    drain("slow");
    // everything fast
    p_rc = 100; p_wc = 100; p_od = 100; p_req = 100; req_on = 1;
    wait_clk(1500);
    req_on = 0;
    drain("fast");
    // error requests
    p_rc = 70; p_wc = 70; p_od = 70; p_req = 60; p_err = 40; req_on = 1;
    wait_clk(3000);
    req_on = 0; p_err = 0;
    drain("errors");
    // the top of the address space, and every request slot with high address bits
    raw_ur(16'hFFF8, 7);
    for (int i = 0; i < RQ; i++) raw_ur(16'h0080, 0);
    // misaligned or invalid and past the memory: BAD
    raw_bad(0, 16'h0081, 0, 2);
    raw_bad(0, 16'h0074, 3, 2);
    raw_bad(6, 16'h0400, 0, 2);
    drain("high addresses");
    // write response credits run out
    p_wc = 0; req_on = 1;
    while (c_wr != 0 || e_wr.size() == 0) @(negedge clk);
    wait_clk(20);
    p_wc = 5;
    wait_clk(1000);
    req_on = 0; p_wc = 70;
    drain("write credits scarce");
    // a wrong od_last: early, and missing
    bad_last = 1; fixed(1, 2, 3, 64'h1234_5678, 1);
    drain("early last");
    bad_last = 1; fixed(1, 3, 0, 64'h55, 1);
    drain("missing last");
    // a write's data ahead of it: the data slots fill, then a beat without a credit
    for (int i = 0; i < DQ; i++) begin
      oq.push_back({64'(64'h0101_0101_0101_0101 * (i + 1)), 8'hFF, i == DQ - 1});
      r_mem[4 + i] = 64'h0101_0101_0101_0101 * (i + 1);
    end
    while (m_od != 0 || oq.size() != 0) @(negedge clk);
    wait_clk(3);
    nocrd_od = 1;
    wait_clk(3);
    e_wr.push_back({8'hA7, 2'd0});
    raw_cmd = 1; raw_tag = 8'hA7; raw_addr = 16'(4 * 8); raw_len = 7; raw = 1;
    drain("data ahead");
    // response credits past 15
    req_on = 0; crd_on = 1; p_rc = 100; p_wc = 100;
    while (c_rd != 15 || c_wr != 15) @(negedge clk);
    crd_on = 0;
    over_rd = 1; wait_clk(3);
    over_wr = 1; wait_clk(3);
    crd_on = 1;
    drain("credits past 15");
    // reset with traffic in flight
    p_rc = 50; p_wc = 50; req_on = 1;
    while (!(rd_valid && e_rd.size() > 1 && oq.size() != 0)) @(negedge clk);
    rst_n = 0;
    req_on = 0;
    wait_clk(3);
    e_rd.delete(); e_wr.delete(); oq.delete();
    for (int i = 0; i < MW; i++) r_mem[i] = 0;
    m_rq = 0; m_od = 0; c_rd = 0; c_wr = 0;
    n_proto = 0; x_proto = 0; n_err = 0; x_err = 0;
    rst_n = 1;
    wait_clk(3);
    req_on = 1;
    wait_clk(1000);
    req_on = 0;
    drain("after reset");
    // alternating data patterns
    fixed(1, 0, 7, {32{2'b01}}, 1); fixed(1, 8, 7, {32{2'b10}}, 1);
    fixed(0, 0, 7, 0, 1); fixed(0, 8, 7, 0, 1);
    drain("patterns");
    if (errors == 0) $display("TEST PASSED: UALink (%0d requests, %0d read beats, %0d write responses)", n_req, n_rd, n_wr);
    else $display("TEST FAILED: UALink (%0d errors)", errors);
    $finish;
  end

  initial begin
    #10ms;
    $display("TEST FAILED: UALink (timeout)");
    $finish;
  end
endmodule
