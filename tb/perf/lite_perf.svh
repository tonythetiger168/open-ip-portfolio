// SPDX-License-Identifier: Apache-2.0
// Performance run of a *_Lite line controller (DDR4_Lite, GDDR7_Lite,
// HBM3E_Lite, LPDDR5X_Lite). Included by lite_tb_common.svh in place of its
// test body when MEM_PERF is defined; the IP TB then instantiates the core
// with its default (datasheet) timing parameters. Reuses the TB's NBANK and
// mk(bank, row, line) and the shared cmd task.
//
// Measured on the core's own ports, in clocks, sampled at the rising edge:
//   * request edge: first edge with the command on hvalid (timed cases)
//   * accept edge: hvalid && hready
//   * data edge: hdone (the last of the 8 read beats; the first is 7
//     clocks earlier)
//   * free edge: the next edge at which a command could be accepted
// One operation moves one 128-bit line (16 bytes). The host issues the next
// command as soon as hready allows, so throughput is the core's own limit.
// Output: "PERF <key> <value>" lines for scripts/perf/perf_report.py.

  int unsigned cyc = 0, acc_cyc, done_cyc, n_acc = 0, n_done = 0;
  int unsigned req_cyc;            // set by the timed tasks: first edge with the command
  always @(posedge clk) begin
    cyc = cyc + 1;
    if (hvalid === 1'b1 && hready === 1'b1) begin acc_cyc = cyc; n_acc++; end
    if (hdone === 1'b1) begin done_cyc = cyc; n_done++; end
  end

  function automatic int prow(input int k); prow = (k * 37 + 5) % 512; endfunction

  task automatic away_from_refresh;
    // margin: the set-up command, 128 idle clocks and the timed command
    while (dut.eng != 0 || dut.refi_cnt < 600) @(negedge clk);
  endtask
  task automatic p_wait_done(input int unsigned d0);
    while (n_done == d0) @(negedge clk);
  endtask
  // one line READ / WRITE issued back to back (no wait for hdone)
  task automatic p_rd(input logic [31:0] a); cmd(3'd1, a, $urandom); endtask
  task automatic p_wr(input logic [31:0] a);
    cmd(3'd2, a, $urandom);
    for (int i = 0; i < 8; i++) begin
      hvalid <= 1'b1; hwdata <= $urandom; hcmd <= 3'd0; @(negedge clk);
    end
    hvalid <= 1'b0;
  endtask
  task automatic p_open(input int b, input int row);   // ACT a row (untimed)
    int unsigned d0;
    d0 = n_done; p_rd(mk(b, row, 0)); p_wait_done(d0); @(negedge clk);
  endtask

  // kind 0 page hit, 1 bank closed (after an all-bank REFRESH), 2 row conflict
  task automatic lat_case(input string name, input bit is_wr, input int kind);
    int lat, mn, mx, b;
    int unsigned d0;
    mn = 1 << 30; mx = 0;
    for (int s = 0; s < 8; s++) begin
      b = s % NBANK;
      away_from_refresh();
      case (kind)
        0: p_open(b, prow(s));
        1: begin d0 = n_done; cmd(3'd5, 0, 0); p_wait_done(d0); @(negedge clk); end
        default: p_open(b, prow(s + 1));
      endcase
      idle(128);                         // every bank timer has run out
      d0 = n_done; req_cyc = cyc + 1;
      if (is_wr) p_wr(mk(b, prow(s), 3)); else p_rd(mk(b, prow(s), 3));
      p_wait_done(d0);
      lat = done_cyc - req_cyc;
      if (lat < mn) mn = lat;
      if (lat > mx) mx = lat;
      @(negedge clk);
    end
    $display("PERF lat_%s_min %0d", name, mn);
    $display("PERF lat_%s_max %0d", name, mx);
  endtask

  // a page-hit READ requested in the clock the auto refresh falls due
  task automatic lat_refresh;
    int lat, mx;
    int unsigned d0;
    mx = 0;
    for (int s = 0; s < 4; s++) begin
      away_from_refresh();
      p_open(0, prow(s));
      while (dut.refi_cnt != 1) @(negedge clk);
      @(negedge clk);
      d0 = n_done; req_cyc = cyc + 1; p_rd(mk(0, prow(s), 5)); p_wait_done(d0);
      lat = done_cyc - req_cyc;
      if (lat > mx) mx = lat;
      @(negedge clk);
    end
    $display("PERF lat_rd_refresh %0d", mx);
  endtask

  // pattern 0 sequential (one bank, one row), 1 bank interleave, 2 row
  // conflict, 3 random; mix 0 RD, 1 WR, 2 alternating, 3 random 2 RD : 1 WR
  task automatic stream(input string name, input int pattern, input int mix, input int n);
    logic [31:0] a;
    bit w;
    int unsigned c0, d0, nops;
    away_from_refresh();
    if (pattern == 0 || pattern == 2) p_open(0, prow(0));
    if (pattern == 1) for (int b = 0; b < NBANK; b++) p_open(b, prow(b));
    idle(4);
    d0 = n_done;
    for (int i = 0; i < n; i++) begin
      case (pattern)
        0: a = mk(0, prow(0), i % 8);
        1: a = mk(i % NBANK, prow(i % NBANK), (i / NBANK) % 8);
        2: a = mk(0, prow(i % 2), i % 8);
        default: a = mk($urandom_range(0, NBANK - 1), $urandom_range(0, 511), $urandom_range(0, 7));
      endcase
      case (mix)
        0: w = 0;
        1: w = 1;
        2: w = i[0];
        default: w = ($urandom_range(0, 2) == 0);
      endcase
      if (w) p_wr(a); else p_rd(a);
      if (i == 0) c0 = acc_cyc;
    end
    while (n_done - d0 < n) @(negedge clk);
    while (hready !== 1'b1) @(negedge clk);
    $display("PERF tp_%s_ops %0d", name, n);
    $display("PERF tp_%s_clk %0d", name, cyc + 1 - c0);
  endtask

  // refresh cost with no host traffic: the engine is busy only refreshing
  task automatic refresh_idle;
    int unsigned busy, win, longest, run, total;
    bit prev;
    while (dut.eng != 0) @(negedge clk);
    busy = 0; win = 0; longest = 0; run = 0; prev = 1;
    total = 8 * dut.T_REFI;
    for (int i = 0; i < total; i++) begin
      @(posedge clk);
      if (dut.eng != 0) begin
        busy++; run++;
        if (prev) win++;
        prev = 0;
      end else begin
        if (run > longest) longest = run;
        run = 0; prev = 1;
      end
      @(negedge clk);
    end
    if (run > longest) longest = run;
    $display("PERF ref_idle_clk %0d", total);
    $display("PERF ref_busy_clk %0d", busy);
    $display("PERF ref_windows %0d", win);
    $display("PERF ref_longest %0d", longest);
  endtask

  initial begin
    hvalid = 0; hcmd = 0; haddr = 0; hwdata = 0;
    repeat (3) @(negedge clk); rst_n = 1;
    idle(4);
    $display("PERF nbu %0d", NBANK);
    $display("PERF refi %0d", dut.T_REFI);
    $display("PERF word_bytes 16");
    lat_case("rd_hit", 0, 0);
    lat_case("rd_closed", 0, 1);
    lat_case("rd_conflict", 0, 2);
    lat_case("wr_hit", 1, 0);
    lat_case("wr_closed", 1, 1);
    lat_case("wr_conflict", 1, 2);
    lat_refresh();
    stream("seq_rd", 0, 0, 2048);
    stream("seq_wr", 0, 1, 2048);
    stream("seq_rw", 0, 2, 2048);
    stream("ilv_rd", 1, 0, 2048);
    stream("conf_rd", 2, 0, 2048);
    stream("rnd_rd", 3, 0, 2048);
    stream("rnd_wr", 3, 1, 2048);
    stream("rnd_mix", 3, 3, 2048);
    refresh_idle();
    $display("PERF reads_done %0d", n_done);
    $display("PERF_DONE");
    $finish;
  end
