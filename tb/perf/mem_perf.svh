// SPDX-License-Identifier: Apache-2.0
// Performance run of a memory-controller core (DDR / LPDDR / GDDR / HBM
// numbered IPs). Included by mem_tb_common.svh in place of its test body
// when MEM_PERF is defined, so it reuses the IP TB's declarations (NBU, ROWW,
// REFI, mk, `REFCNT) and the shared host tasks (cmd, act, pre, quiesce, idle,
// near_refresh).
//
// Everything is measured on the core's own ports, in clocks, by monitors
// that sample at the rising edge (the same edge the core samples on):
//   * request edge: the first edge at which the host has the command
//   * accept edge: hvalid && hready
//   * read data edge: hdone (hrdata holds the word from this edge on)
//   * free edge: the next edge at which a command could be accepted
// The host drives a new command as soon as hready allows (no host bubbles),
// so the throughput figures are the core's own limit.
//
// Output: one "PERF <key> <value>" line per figure, parsed by
// scripts/perf/perf_report.py.

  int unsigned cyc = 0;            // rising edges since time 0
  int unsigned acc_cyc, done_cyc;  // edge of the last accept / hdone
  int unsigned n_acc = 0, n_done = 0;
  always @(posedge clk) begin
    cyc = cyc + 1;
    if (hvalid === 1'b1 && hready === 1'b1) begin acc_cyc = cyc; n_acc++; end
    if (hdone === 1'b1) begin done_cyc = cyc; n_done++; end
  end

  function automatic logic [13:0] prow(input int k);
    prow = 14'(k * 37 + 5);
    if (ROWW < 14) prow = prow & ((14'd1 << ROWW) - 1);
  endfunction

  // wait until the next refresh is at least a margin away, so that the
  // command about to be timed cannot meet it
  // (margin: the set-up command, PIDLE clocks and the timed command)
  localparam int PIDLE = (REFI / 4 < 72) ? REFI / 4 : 72;   // > every core's tRC
  localparam int PMARGIN = (REFI - 8 < 600) ? REFI - 8 : 600;
  task automatic away_from_refresh;
    quiesce();
    while (`REFCNT < PMARGIN) @(negedge clk);
  endtask

  // ---- one RD: request edge (the first edge the host has it) -> data edge
  task automatic lat_rd(input logic [31:0] a, output int lat);
    int unsigned d0, r;
    d0 = n_done; r = cyc + 1;
    cmd(3'd2, a, 0);
    while (n_done == d0) @(negedge clk);
    lat = done_cyc - r;
  endtask
  // ---- one WR: request edge -> edge the next command can be accepted
  task automatic lat_wr(input logic [31:0] a, output int lat);
    int unsigned r;
    r = cyc + 1;
    cmd(3'd3, a, $urandom);
    quiesce();
    lat = cyc + 1 - r;
  endtask

  // ---- unloaded latency: 8 samples away from refresh, each after the bank's
  // timers have run out; report min / max.
  // kind 0 page hit, 1 bank closed (PRE first), 2 row conflict
  task automatic lat_case(input string name, input bit is_wr, input int kind);
    int lat, mn, mx, b;
    logic [31:0] a;
    mn = 1 << 30; mx = 0;
    for (int s = 0; s < 8; s++) begin
      b = s % NBU;
      away_from_refresh();
      case (kind)
        0: act(mk(b, prow(s), 0));
        1: pre(mk(b, prow(s), 0));
        default: act(mk(b, prow(s + 1), 0));
      endcase
      quiesce(); idle(PIDLE);            // every bank timer (tRAS, tRC) has run out
      a = mk(b, prow(s), 8'(16 + s));
      if (is_wr) lat_wr(a, lat); else lat_rd(a, lat);
      if (lat < mn) mn = lat;
      if (lat > mx) mx = lat;
    end
    $display("PERF lat_%s_min %0d", name, mn);
    $display("PERF lat_%s_max %0d", name, mx);
  endtask

  // ---- RD page hit that meets a refresh falling due: the worst case a
  // single read sees
  task automatic lat_refresh;
    int lat, mx;
    mx = 0;
    for (int s = 0; s < 4; s++) begin
      away_from_refresh();
      act(mk(0, prow(s), 0)); quiesce();
      near_refresh(1); @(negedge clk);       // the refresh is due now
      lat_rd(mk(0, prow(s), 8'(32 + s)), lat);
      if (lat > mx) mx = lat;
    end
    $display("PERF lat_rd_refresh %0d", mx);
  endtask

  // ---- sustained traffic: N commands back to back.
  //   pattern 0 sequential page hits (one bank, one row, rising columns)
  //           1 bank interleave (every bank entry in turn, its row open)
  //           2 row conflict (one bank, two rows alternating)
  //           3 uniform random bank / row / column
  //   mix: 0 all RD, 1 all WR, 2 RD/WR alternating, 3 random 2 RD : 1 WR
  task automatic stream(input string name, input int pattern, input int mix, input int n);
    logic [31:0] a;
    bit w;
    int unsigned c0, nrd, d0;
    quiesce(); idle(4);
    // open the rows the pattern uses (untimed)
    if (pattern == 0 || pattern == 2) act(mk(0, prow(0), 0));
    if (pattern == 1) for (int b = 0; b < NBU; b++) act(mk(b, prow(b), 0));
    quiesce(); idle(4);
    nrd = 0; d0 = n_done;
    for (int i = 0; i < n; i++) begin
      case (pattern)
        0: a = mk(0, prow(0), 8'(i));
        1: a = mk(i % NBU, prow(i % NBU), 8'(i / NBU));
        2: a = mk(0, prow(i % 2), 8'(i));
        default: a = mk($urandom_range(0, NBU - 1), rrow(), 8'($urandom));
      endcase
      case (mix)
        0: w = 0;
        1: w = 1;
        2: w = i[0];
        default: w = ($urandom_range(0, 2) == 0);
      endcase
      cmd(w ? 3'd3 : 3'd2, a, $urandom);
      if (i == 0) c0 = acc_cyc;
      if (!w) nrd++;
    end
    while (n_done - d0 < nrd) @(negedge clk);
    quiesce();
    $display("PERF tp_%s_ops %0d", name, n);
    $display("PERF tp_%s_clk %0d", name, cyc + 1 - c0);
  endtask

  // ---- refresh cost with no host traffic: share of clocks the core cannot
  // take a command, number of blocking windows and the longest one
  task automatic refresh_idle;
    int unsigned busy, win, longest, run, total;
    bit prev;
    quiesce();
    busy = 0; win = 0; longest = 0; run = 0; prev = 1;
    total = 8 * REFI;
    for (int i = 0; i < total; i++) begin
      @(posedge clk);
      if (hready !== 1'b1) begin
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
    rst_n = 0; idle(5); rst_n = 1; idle(5);
    $display("PERF nbu %0d", NBU);
    $display("PERF refi %0d", REFI);
    $display("PERF word_bytes 2");
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
