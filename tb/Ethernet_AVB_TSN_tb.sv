// SPDX-License-Identifier: Apache-2.0
// ============================================================================
// Self-checking testbench for Ethernet_AVB_TSN_top v2.0
//  * Four frame queues (lengths only) feed the DUT; every selected frame is
//    checked against the head of its queue (order, length), its timestamp
//    against a TB time model, and the line against overlap.
//  * A TB model of the gate schedule (position in the cycle = elapsed
//    clocks x cfg_inc_ns, entry by prefix sums) is compared with the DUT's
//    gate state every clock; every frame must find its gate open, inside
//    one cycle, for its whole line time (guard band).
//  * Strict priority is checked without gates and shapers; the shapers by
//    the share of the line each class gets, and the credit limits.
//  * Scenarios: plain strict priority with every frame length class (0,
//    64, 1522, 2047), CBS at several idle slopes incl. 0 and 256 and
//    saturation both ways, gate lists with 1..8 entries, short and long
//    cycles (truncated lists, a last entry that lasts to the cycle end),
//    base time in the future and the past, guard band, gates closed with
//    frames waiting (credit held), schedule switched off and on, time set
//    across the 64-bit wrap, positive / negative adjustments, fractional
//    increments, reset in the middle of a frame.
// ============================================================================
`timescale 1ns/1ps
module Ethernet_AVB_TSN_tb;
  logic clk = 0, rst_n = 0;
  always #4 clk = ~clk;

  int errors = 0;
  function automatic void fail(input string m);
    errors++;
    if (errors < 30) $display("ERROR: %s @%0t", m, $time);
  endfunction

  logic [7:0]  inc_ns = 8;
  logic [15:0] inc_frac = 0;
  logic        time_set = 0, time_adj = 0;
  logic [63:0] time_set_ns = 0;
  logic [31:0] time_adj_ns = 0;
  wire  [63:0] time_ns;
  logic        gcl_en = 0;
  logic [63:0] gcl_base = 0;
  logic [23:0] gcl_cycle = 1000;
  logic [2:0]  gcl_last = 0;
  logic        gcl_we = 0;
  logic [2:0]  gcl_waddr = 0;
  logic [3:0]  gcl_wgates = 0;
  logic [23:0] gcl_wivl = 0;
  logic [3:0]  cbs_en = 0;
  logic [35:0] cbs_idle = 0;
  logic [3:0]  q_valid = 0;
  logic [43:0] q_len = 0;
  wire  [3:0]  q_pop;
  wire         tx_start, tx_busy, gcl_running, cycle_start;
  wire  [1:0]  tx_tc;
  wire  [10:0] tx_len;
  wire  [63:0] tx_ts;
  wire  [2:0]  gcl_entry;
  wire  [3:0]  gate_state;
  wire  [79:0] cbs_credit;

  Ethernet_AVB_TSN_top dut (.cfg_inc_ns(inc_ns), .cfg_inc_frac(inc_frac), .*);

  // ---------------- queues ----------------
  int qbuf [0:3][0:4095];
  int qh [0:3], qt [0:3];
  task automatic update_q;
    for (int c = 0; c < 4; c++) begin
      q_valid[c] = qh[c] != qt[c];
      q_len[11*c +: 11] = q_valid[c] ? 11'(qbuf[c][qh[c] % 4096]) : 11'(c * 517 + 3);
    end
  endtask
  task automatic enq(input int c, input int len);
    qbuf[c][qt[c] % 4096] = len; qt[c]++;
  endtask
  function automatic int qn(input int c); return qt[c] - qh[c]; endfunction

  // ---------------- TB models ----------------
  logic [63:0] m_time = 0;
  logic [15:0] m_frac = 0;
  // gate schedule (TB copy)
  logic [3:0]  s_gates [0:7];
  int          s_ivl [0:7];
  bit          m_run = 0;
  longint      rn = 0;                    // clocks since the schedule started
  function automatic logic [3:0] gate_at(input longint n);
    longint p, cum;
    p = (n * longint'(inc_ns_q)) % longint'(gcl_cycle);
    cum = 0;
    for (int k = 0; k < 8; k++) begin
      if (k == int'(gcl_last)) return s_gates[k];
      if (p < cum + s_ivl[k]) return s_gates[k];
      cum += s_ivl[k];
    end
    return s_gates[7];
  endfunction
  function automatic longint cyc_of(input longint n);
    return (n * longint'(inc_ns_q)) / longint'(gcl_cycle);
  endfunction

  // values the DUT saw at the posedge (inputs change at negedges)
  logic        time_set_q, time_adj_q, gcl_en_q;
  logic [63:0] time_set_ns_q, gcl_base_q, t_prev_sel;
  logic [31:0] time_adj_ns_q;
  logic [7:0]  inc_ns_q;
  logic [15:0] inc_frac_q, m_frac_prev;
  longint      rn_prev_sel;
  bit          run_prev_sel;
  // ---------------- monitor ----------------
  int     n_tx [0:3];
  longint bytes [0:3];
  longint line_free = 0;                   // first clock the line is free
  longint now = 0;                         // posedges since reset
  logic [3:0]  qv_prev;
  logic [63:0] t_prev;
  longint      rn_prev;
  bit          run_prev;
  bit     chk_prio = 0;
  int     sat_hi [0:3], sat_lo [0:3];
  always @(negedge clk) if (rst_n) begin
    // models advance with the posedge just passed
    t_prev = m_time; rn_prev = rn; run_prev = m_run;
    if (time_set_q) begin m_time = time_set_ns_q; m_frac = 0; end
    else begin
      {m_frac} = m_frac + inc_frac_q;
      m_time = m_time + 64'(inc_ns_q) + 64'(({1'b0, m_frac_prev} + {1'b0, inc_frac_q}) >> 16)
               + (time_adj_q ? {{32{time_adj_ns_q[31]}}, time_adj_ns_q} : 64'd0);
    end
    if (!gcl_en_q) m_run = 0;
    else if (!m_run) begin if (t_prev >= gcl_base_q) begin m_run = 1; rn = 0; end end
    else rn++;
    now++;
    if (time_ns !== m_time) fail($sformatf("time %h, expected %h", time_ns, m_time));
    if (gcl_running !== m_run) fail($sformatf("gcl_running %b, expected %b", gcl_running, m_run));
    if (m_run && gate_state !== gate_at(rn)) fail($sformatf("gates %b, expected %b (n %0d)", gate_state, gate_at(rn), rn));
    if (!m_run && gate_state !== 4'hF) fail("gates not all open without a schedule");
    for (int c = 0; c < 4; c++) begin
      if (cbs_credit[20*c +: 20] == 20'h7FFFF) sat_hi[c]++;
      if (cbs_credit[20*c +: 20] == 20'h80000) sat_lo[c]++;
    end
    if (tx_start) begin : b_mon
      int c, L;
      bit bad;
      logic [3:0] gx;
      c = int'(tx_tc); L = int'(tx_len);
      if (q_pop !== (4'b1 << c)) fail($sformatf("q_pop %b with class %0d", q_pop, c));
      if (qh[c] == qt[c]) fail($sformatf("class %0d started with an empty queue", c));
      else if (L != qbuf[c][qh[c] % 4096] % 2048) fail($sformatf("class %0d length %0d, expected %0d", c, L, qbuf[c][qh[c] % 4096]));
      if (now - 1 < line_free) fail("frame started while the line is busy");
      line_free = now - 1 + L + 20;
      if (tx_ts !== t_prev_sel) fail($sformatf("timestamp %h, expected %h", tx_ts, t_prev_sel));
      if (chk_prio) for (int h = c + 1; h < 4; h++)
        if (qv_prev[h]) fail($sformatf("class %0d started while class %0d was waiting", c, h));
      if (run_prev_sel) begin
        bad = 0;
        for (int i = 0; i < L + 20; i++) begin
          gx = gate_at(rn_prev_sel + i);
          if (!gx[c] || cyc_of(rn_prev_sel + i) != cyc_of(rn_prev_sel)) bad = 1;
        end
        if (bad) fail($sformatf("class %0d frame of %0d bytes runs into a closed gate / cycle end", c, L));
      end
      qh[c]++; n_tx[c]++; bytes[c] += L + 20;
      update_q();
    end
    qv_prev = q_valid;
  end
  always @(posedge clk) begin
    time_set_q = time_set; time_adj_q = time_adj; gcl_en_q = gcl_en; time_set_ns_q = time_set_ns;
    gcl_base_q = gcl_base; time_adj_ns_q = time_adj_ns; inc_ns_q = inc_ns; inc_frac_q = inc_frac;
    m_frac_prev = m_frac; t_prev_sel = m_time; rn_prev_sel = rn; run_prev_sel = m_run;
  end

  // ---------------- helpers ----------------
  task automatic cycles(input int n); repeat (n) @(negedge clk); endtask
  task automatic drain(input int limit);
    int g;
    g = 0;
    while ((qn(0) + qn(1) + qn(2) + qn(3) > 0 || tx_busy) && g < limit) begin @(negedge clk); g++; end
    if (g >= limit) fail($sformatf("queues not drained (%0d %0d %0d %0d)", qn(0), qn(1), qn(2), qn(3)));
  endtask
  task automatic gcl_write(input int k, input logic [3:0] g, input int ivl);
    @(negedge clk);
    gcl_we = 1; gcl_waddr = k; gcl_wgates = g; gcl_wivl = ivl;
    s_gates[k] = g; s_ivl[k] = ivl;
    @(negedge clk) gcl_we = 0;
  endtask
  task automatic set_idle(input int c, input int v); cbs_idle[9*c +: 9] = v; endtask
  function automatic int rlen();
    case ($urandom % 8)
      0: return 0;
      1: return 64;
      2: return 1522;
      3: return 2047;
      default: return $urandom_range(1600, 40);
    endcase
  endfunction
  task automatic stats_clear; $display("@%0t frames %0d %0d %0d %0d", $time, n_tx[0], n_tx[1], n_tx[2], n_tx[3]); for (int c = 0; c < 4; c++) begin n_tx[c] = 0; bytes[c] = 0; end endtask

  // ---------------- scenarios ----------------
  initial begin
    for (int c = 0; c < 4; c++) begin qh[c] = 0; qt[c] = 0; n_tx[c] = 0; bytes[c] = 0; sat_hi[c] = 0; sat_lo[c] = 0; end
    for (int k = 0; k < 8; k++) begin s_gates[k] = 0; s_ivl[k] = 0; end
    update_q();
    #20 rst_n = 1;
    cycles(3);

    // 1. strict priority, no gates, no shapers; all lengths
    chk_prio = 1;
    for (int i = 0; i < 120; i++) begin
      enq($urandom % 4, rlen());
      if (i % 3 == 0) update_q();
      cycles($urandom % 200);
    end
    update_q(); drain(2_000_000);
    for (int c = 0; c < 4; c++) for (int i = 0; i < 6; i++) enq(c, 2047 - 300 * i);
    update_q(); drain(2_000_000);
    chk_prio = 0;

    // 2. credit-based shapers: class 3 at 1/4, class 2 at 1/2, classes 0/1
    // saturate the line; shares measured over many frames
    cbs_en = 4'b1100; set_idle(3, 64); set_idle(2, 128); set_idle(1, 256); set_idle(0, 0);
    stats_clear();
    for (int i = 0; i < 1000; i++) for (int c = 0; c < 4; c++) enq(c, 200);
    update_q();
    cycles(200_000);
    begin : b_share
      longint tot;
      tot = bytes[0] + bytes[1] + bytes[2] + bytes[3];
      if (bytes[3] * 256 > tot * 64 * 105 / 100 || bytes[3] * 256 < tot * 64 * 90 / 100)
        fail($sformatf("class 3 share %0d / %0d, expected 1/4", bytes[3], tot));
      if (bytes[2] * 256 > tot * 128 * 105 / 100 || bytes[2] * 256 < tot * 128 * 90 / 100)
        fail($sformatf("class 2 share %0d / %0d, expected 1/2", bytes[2], tot));
    end
    for (int c = 0; c < 4; c++) begin qh[c] = qt[c]; end    // drop what is left
    update_q(); drain(10_000);
    cycles(5000);
    // positive saturation: class 2 (idle 256) waits behind class 3 frames
    cbs_en = 4'b0100; set_idle(2, 256);
    for (int i = 0; i < 4; i++) enq(3, 2047);
    enq(2, 100);
    update_q(); drain(100_000);
    if (sat_hi[2] == 0) fail("credit never saturated high");
    // negative saturation: idle slope 0 is never eligible again once negative;
    // slope 1 recovers slowly
    cbs_en = 4'b0010; set_idle(1, 1);
    enq(1, 2047); enq(1, 64);
    update_q(); drain(2_000_000);
    if (sat_lo[1] == 0) fail("credit never saturated low");
    cbs_en = 0;
    cycles(10);

    // 3. gate control lists
    gcl_test(3'd3, 24'd20_000, 8'd8, 0, 0);       // 4 entries
    gcl_test(3'd7, 24'd40_000, 8'd8, 1, 0);       // 8 entries, with shapers
    gcl_test(3'd0, 24'd9_000, 8'd8, 0, 0);        // 1 entry
    gcl_test(3'd2, 24'd5_000, 8'd16, 0, 0);       // list longer than the cycle
    gcl_test(3'd2, 24'd60_000, 8'd8, 0, 7000);    // last entry lasts to the end
    g_off = 0; gcl_test(3'd7, 24'd40_000, 8'd8, 0, 0);   // every gate mask once
    g_off = 8; gcl_test(3'd7, 24'd40_000, 8'd8, 0, 0);
    g_off = -1;
    // a long cycle at the largest increment: elapsed counters fill up
    gcl_test(3'd1, 24'hFF_FFF0, 8'd255, 0, 0);
    inc_ns = 8;

    // 4. time: set across the wrap, adjust both ways, fractions
    @(negedge clk) time_set = 1; time_set_ns = 64'hFFFF_FFFF_FFFF_FF00;
    @(negedge clk) time_set = 0; time_set_ns = $urandom;
    cycles(100);
    @(negedge clk) time_adj = 1; time_adj_ns = 32'h7FFF_FFFF;
    @(negedge clk) time_adj_ns = 32'h8000_0000;
    @(negedge clk) time_adj_ns = 32'hFFFF_FFF0;
    @(negedge clk) time_adj = 0; time_adj_ns = 0;
    for (int i = 0; i < 8; i++) begin
      inc_frac = $urandom; inc_ns = $urandom;
      cycles(50);
    end
    inc_frac = 16'hFFFF; inc_ns = 8'hFF; cycles(20);
    inc_frac = 0; inc_ns = 8;
    @(negedge clk) time_set = 1; time_set_ns = 64'h0123_4567_89AB_CDEF;
    @(negedge clk) time_set = 0; time_set_ns = 0;

    // 5. directed: configuration extremes (toggles), a list cut by the
    // cycle end, all gates closed, the widest elapsed counters, timestamps
    // with high time bits, a negative class-0 credit
    for (int k = 0; k < 8; k++) gcl_write(k, 4'hF, 24'hFF_FFFF);
    for (int k = 0; k < 8; k++) gcl_write(k, 4'h0, 24'h0);
    @(negedge clk) gcl_base = '1; gcl_cycle = '1; cbs_idle = '1;
    @(negedge clk) gcl_base = '0; gcl_cycle = '0; cbs_idle = '0;
    @(negedge clk) time_set = 1; time_set_ns = '1;
    @(negedge clk) time_set = 0; time_set_ns = '0;
    enq(1, 30); update_q(); drain(1000);
    @(negedge clk) time_set = 1; time_set_ns = 64'h0;
    @(negedge clk) time_set = 0;
    enq(1, 30); update_q(); drain(1000);
    gcl_last = 2; gcl_cycle = 5000; inc_ns = 8;
    gcl_write(0, 4'h0, 3000); gcl_write(1, 4'hF, 3000); gcl_write(2, 4'h5, 3000);
    gcl_base = 0; @(negedge clk) gcl_en = 1;
    cycles(3000);
    gcl_en = 0; cycles(2);
    gcl_last = 0; gcl_cycle = 24'hFF_FFFF; inc_ns = 254;
    gcl_write(0, 4'hF, 24'hFF_FFFF);
    @(negedge clk) gcl_en = 1;
    cycles(270_000);
    gcl_en = 0; inc_ns = 8; cycles(2);
    // an entry interval with bit 23 set
    gcl_last = 1; inc_ns = 254;
    gcl_write(0, 4'hF, 24'h80_0010); gcl_write(1, 4'h0, 24'h00_1000);
    @(negedge clk) gcl_en = 1;
    cycles(34_000);
    gcl_en = 0; inc_ns = 8; cycles(2);
    // exact guard-band fit: class 0 opens at the cycle start for exactly
    // its frame's line time
    gcl_last = 1; gcl_cycle = 2000;
    gcl_write(0, 4'h1, 960); gcl_write(1, 4'h0, 1040);
    @(negedge clk) gcl_en = 1;
    cycles(200);
    enq(0, 100); update_q(); drain(400);
    // a gate that closes only in an entry the cycle cuts off: the cycle end
    // limits the frame (5520 ns never fits in a 5000 ns cycle)
    gcl_en = 0; cycles(2);
    gcl_last = 2; gcl_cycle = 5000;
    gcl_write(0, 4'hF, 3000); gcl_write(1, 4'hF, 3000); gcl_write(2, 4'h0, 3000);
    @(negedge clk) gcl_en = 1;
    cycles(2);
    enq(2, 670); update_q();
    cycles(3000);
    if (qn(2) != 1) fail("frame longer than the cycle was sent");
    qh[2] = qt[2]; update_q();
    gcl_en = 0; cycles(2);
    // time_set clears the fraction
    @(negedge clk) inc_frac = 16'h8000;
    cycles(3);
    @(negedge clk) time_set = 1; time_set_ns = 64'd1000;
    @(negedge clk) time_set = 0; inc_frac = 0;
    cycles(3);
    cbs_en = 4'b0001; set_idle(0, 64);
    enq(0, 1500); enq(0, 64); update_q(); drain(100_000);
    cbs_en = 0; set_idle(0, 0);

    // 6. reset in the middle of a frame
    enq(0, 1000); update_q();
    @(posedge tx_busy); cycles(300);
    rst_n = 0; cycles(3);
    for (int c = 0; c < 4; c++) qh[c] = qt[c];
    update_q();
    m_time = 0; m_frac = 0; m_run = 0; rn = 0; line_free = 0; gcl_en = 0; qv_prev = 0;
    #1 rst_n = 1;
    cycles(20);
    enq(2, 77); update_q(); drain(10_000);

    $display("end at %0t, %0d clocks", $time, now);
    for (int c = 0; c < 4; c++) $display("class %0d: %0d frames, sat %0d/%0d", c, n_tx[c], sat_hi[c], sat_lo[c]);
    if (errors == 0) $display("TEST PASSED: Ethernet_AVB_TSN");
    else $display("TEST FAILED: Ethernet_AVB_TSN (%0d errors)", errors);
    $finish;
  end

  // one schedule: random gates and intervals, frames on all classes, base
  // time in the future, then in the past; switched off at the end
  int g_off = -1;                       // >= 0: entry k gets gate mask g_off + k
  task automatic gcl_test(input logic [2:0] last, input logic [23:0] cyc, input logic [7:0] inc,
                          input bit with_cbs, input int ivl_max);
    gcl_en = 0; cycles(2);
    gcl_last = last; gcl_cycle = cyc; inc_ns = inc;
    if (ivl_max == 0) ivl_max = 2 * int'(cyc) / (int'(last) + 1);
    for (int k = 0; k < 8; k++)
      gcl_write(k, g_off >= 0 ? 4'(g_off + k) : k == 0 ? 4'b1000 : k == 1 ? 4'b0111 : 4'($urandom),
                $urandom_range(ivl_max, int'(inc) * 2));
    if (with_cbs) begin cbs_en = 4'b1111; set_idle(3, 200); set_idle(2, 150); set_idle(1, 100); set_idle(0, 50); end
    // base in the future
    gcl_base = time_ns + 64'd5_000;
    @(negedge clk) gcl_en = 1;
    stats_clear();
    for (int r = 0; r < 2; r++) begin
      for (int i = 0; i < 60; i++) begin
        enq($urandom % 4, $urandom_range(int'(cyc) / int'(inc) / 3 + 20, 0) % 2048);
        if (i % 4 == 0) update_q();
        cycles($urandom % 300);
      end
      update_q();
      cycles(int'(cyc) / int'(inc) * 3);
      // base in the past: restart at once
      gcl_en = 0; cycles(1); gcl_base = 64'd0; @(negedge clk) gcl_en = 1;
    end
    // frames that never fit (longer than any gate): stay queued
    gcl_en = 0; cycles(1);
    for (int c = 0; c < 4; c++) begin qh[c] = qt[c]; end
    update_q();
    while (tx_busy) @(negedge clk);
    cbs_en = 0;
    cycles(5);
  endtask
  initial begin #400ms; $display("TEST FAILED: Ethernet_AVB_TSN (timeout)"); $finish; end
endmodule
