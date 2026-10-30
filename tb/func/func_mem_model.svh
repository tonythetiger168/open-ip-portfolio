// SPDX-License-Identifier: Apache-2.0
// Shared body of the pin-level functional tests for the DDR4 / LPDDR4
// controllers (func_ddr4_tb, func_lpddr4_tb). Ported from the
// open-vip-portfolio func_*_tb tests, which targeted the old MEMCH /
// MEMCORE cores, and rewritten for the independent designs.
//
// <P>_tb checks the host side and tb/cov/<P>_sva.sv replays the RTL's own
// state; this test instead plays the DRAM device. The including TB decodes
// its pins into commands and calls the dev_* tasks below, which check the
// device rules from the pins alone (bank state, tRCD / tRP / tRAS / tRC /
// tRFC, refresh interval, CAS latency, DQ ownership) and keep their own
// array from the data seen on DQ. Reads are checked twice: against that
// array and against a host-side reference of every write.
//
// The including TB provides, before the include:
//   localparams NCH, NBK (banks), TRP, TRAS, TRC, TRFC, TREFI, REF_SLACK
//   functions cl_now() / trcd_now()   current CL / tRCD in clocks
//   function bank_of(a)              bank a host address lands on
//   function cell_of(a)              storage index ({channel, column})
//   function is_mrw(c, a)            host command is a controller-side MRW
//   task mrw(d)                      apply an MRW to the TB's timing view
//   logic hvalid/hcmd/haddr/hwdata, hready, hdone, hrdata, clk, rst_n
// and calls dev_tick() once per clock (at the negedge, after decoding).

  int errors = 0, checks = 0, cyc = 0;
  task automatic fail(input string m);
    errors++;
    $display("ERROR: %s (cycle %0d, t=%0t)", m, cyc, $time);
  endtask
  task automatic chk(input bit ok, input string m);
    checks++;
    if (!ok) fail(m);
  endtask

  // ---------------------------- device view ----------------------------
  localparam int NEVER = -1000000;
  bit          b_open [NBK];
  logic [13:0] b_row  [NBK];
  int          t_act  [NBK], t_pre [NBK], t_ref [NBK];
  int          t_ref_any = 0, n_ref = 0, n_act = 0, n_pre = 0, n_rd = 0, n_wr = 0;
  int          max_ref_gap = 0;
  logic [15:0] dmem [0:NCH*256-1];    // array as written through DQ
  // smallest gap seen per rule, to show the controller does not over-wait
  int          g_rcd = 1 << 30, g_rp = 1 << 30, g_ras = 1 << 30, g_rc = 1 << 30;

  // reads in flight: issue cycle, expected word, CL at issue
  int          rq_t [$];
  logic [15:0] rq_d [$];
  int          rq_cl [$];

  task automatic dev_reset();
    for (int b = 0; b < NBK; b++) begin
      b_open[b] = 0; b_row[b] = 0; t_act[b] = NEVER; t_pre[b] = NEVER; t_ref[b] = NEVER;
    end
    t_ref_any = cyc; rq_t.delete(); rq_d.delete(); rq_cl.delete();
  endtask

  task automatic dev_act(input int b, input logic [13:0] row);
    n_act++;
    chk(!b_open[b], $sformatf("ACT to bank %0d, which is already open", b));
    chk(cyc - t_pre[b] >= TRP, $sformatf("tRP: ACT bank %0d %0d clocks after PRE", b, cyc - t_pre[b]));
    chk(cyc - t_act[b] >= TRC, $sformatf("tRC: ACT bank %0d %0d clocks after ACT", b, cyc - t_act[b]));
    chk(cyc - t_ref[b] >= TRFC, $sformatf("tRFC: ACT bank %0d %0d clocks after REF", b, cyc - t_ref[b]));
    if (t_pre[b] != NEVER && cyc - t_pre[b] < g_rp) g_rp = cyc - t_pre[b];
    if (t_act[b] != NEVER && cyc - t_act[b] < g_rc) g_rc = cyc - t_act[b];
    b_open[b] = 1; b_row[b] = row; t_act[b] = cyc;
  endtask

  task automatic dev_cas(input bit wr, input int b, input logic [13:0] row, input int ci,
                         input logic [15:0] d);
    chk(b_open[b], $sformatf("%s to closed bank %0d", wr ? "WR" : "RD", b));
    chk(b_row[b] == row, $sformatf("%s to bank %0d row %h, open row is %h", wr ? "WR" : "RD", b, row, b_row[b]));
    chk(cyc - t_act[b] >= trcd_now(), $sformatf("tRCD: %s %0d clocks after ACT", wr ? "WR" : "RD", cyc - t_act[b]));
    if (cyc - t_act[b] < g_rcd) g_rcd = cyc - t_act[b];
    if (wr) begin n_wr++; dmem[ci] = d; end
    else begin
      n_rd++;
      rq_t.push_back(cyc); rq_d.push_back(dmem[ci]); rq_cl.push_back(cl_now());
    end
  endtask

  task automatic dev_pre(input int b);
    n_pre++;
    chk(b_open[b], $sformatf("PRE to closed bank %0d", b));
    chk(cyc - t_act[b] >= TRAS, $sformatf("tRAS: PRE bank %0d %0d clocks after ACT", b, cyc - t_act[b]));
    if (cyc - t_act[b] < g_ras) g_ras = cyc - t_act[b];
    b_open[b] = 0; t_pre[b] = cyc;
  endtask

  task automatic dev_prea();
    n_pre++;
    for (int b = 0; b < NBK; b++) begin
      if (b_open[b]) begin
        chk(cyc - t_act[b] >= TRAS, $sformatf("tRAS: PREA %0d clocks after ACT bank %0d", cyc - t_act[b], b));
        if (cyc - t_act[b] < g_ras) g_ras = cyc - t_act[b];
      end
      b_open[b] = 0; t_pre[b] = cyc;
    end
  endtask

  // b < 0: all-bank refresh
  task automatic dev_ref(input int b);
    n_ref++;
    for (int i = 0; i < NBK; i++)
      if (b < 0 || i == b) begin
        chk(!b_open[i], $sformatf("REF with bank %0d open", i));
        chk(cyc - t_pre[i] >= TRP, $sformatf("tRP: REF %0d clocks after PRE of bank %0d", cyc - t_pre[i], i));
        t_ref[i] = cyc;
      end
    if (cyc - t_ref_any > max_ref_gap) max_ref_gap = cyc - t_ref_any;
    chk(cyc - t_ref_any <= TREFI + REF_SLACK, $sformatf("refresh interval %0d clocks", cyc - t_ref_any));
    t_ref_any = cyc;
  endtask

  // ----------------------------- host view -----------------------------
  logic [15:0] href [0:NCH*256-1];    // every host write, in order
  logic [15:0] hq [$];                // expected words of accepted reads
  int n_hrd = 0, n_hwr = 0, n_hact = 0, n_hpre = 0, n_mrw = 0, n_done = 0;
  logic [15:0] last_wdata;            // data of the write in flight
  initial for (int i = 0; i < NCH*256; i++) begin href[i] = 0; dmem[i] = 0; end

  always @(posedge clk) if (rst_n && hvalid && hready) begin
    case (hcmd)
      3'd1: n_hact++;
      3'd2: begin n_hrd++; hq.push_back(href[cell_of(haddr)]); end
      3'd3: if (is_mrw(hcmd, haddr)) begin n_mrw++; mrw(hwdata); end
            else begin n_hwr++; href[cell_of(haddr)] = hwdata; last_wdata = hwdata; end
      3'd4: n_hpre++;
      default: ;
    endcase
  end

  // hdone: exactly CL after the RD command; hrdata holds the word next clock
  logic        done_q = 0;
  logic [15:0] exp_dev, exp_host;
  task automatic dev_tick();
    if (done_q) begin
      chk(hrdata == exp_dev, $sformatf("read data %h, the device array holds %h", hrdata, exp_dev));
      chk(hrdata == exp_host, $sformatf("read data %h, the host wrote %h", hrdata, exp_host));
    end
    done_q = 0;
    if (hdone) begin
      n_done++;
      if (rq_t.size() == 0 || hq.size() == 0) fail("hdone without a read in flight");
      else begin
        chk(cyc - rq_t[0] == rq_cl[0], $sformatf("hdone %0d clocks after RD, CL is %0d", cyc - rq_t[0], rq_cl[0]));
        exp_dev = rq_d.pop_front(); exp_host = hq.pop_front();
        void'(rq_t.pop_front()); void'(rq_cl.pop_front());
        done_q = 1;
      end
    end
    cyc++;
  endtask

  // ---------------------------- stimulus ----------------------------
  task automatic host(input logic [2:0] c, input logic [31:0] a, input logic [15:0] d);
    @(negedge clk);
    while (!hready) @(negedge clk);
    hvalid = 1; hcmd = c; haddr = a; hwdata = d;
    @(negedge clk);
    hvalid = 0; hcmd = 3'($urandom);    // a code without hvalid is ignored
  endtask

  task automatic drain();
    // wait for the controller to finish the last command and any refresh
    repeat (TRFC + 200) @(negedge clk);
    while (!hready) @(negedge clk);
  endtask

  // random traffic over a few rows per bank (hits, misses, conflicts) and
  // a column set that is revisited often
  function automatic logic [31:0] rnd_addr();
    logic [31:0] a;
    a = $urandom;
    case ($urandom_range(3))
      0: a[31:18] = 14'h0000; 1: a[31:18] = 14'h3FFF;
      2: a[31:18] = 14'h2A5C; default: a[31:18] = 14'h1234;
    endcase
    if ($urandom_range(3) != 0) a[7:0] = 8'($urandom_range(15)) ^ 8'hF5;
    return a;
  endfunction
  task automatic traffic(input int n);
    for (int i = 0; i < n; i++) begin
      int r;
      r = $urandom_range(99);
      host(r < 15 ? 3'd1 : r < 50 ? 3'd2 : r < 88 ? 3'd3 : r < 96 ? 3'd4 : 3'd0,
           rnd_addr(), 16'($urandom));
    end
  endtask

  task automatic report(input string name);
    drain();
    chk(hq.size() == 0 && rq_t.size() == 0, "every read completed");
    chk(n_done == n_hrd && n_rd == n_hrd, $sformatf("reads: host %0d, RD %0d, hdone %0d", n_hrd, n_rd, n_done));
    chk(n_wr == n_hwr, $sformatf("writes: host %0d, WR %0d", n_hwr, n_wr));
    chk(n_ref > 3, $sformatf("only %0d refreshes", n_ref));
    // the controller meets each rule without padding it by more than a few clocks
    // (back-to-back ACTs of one bank also need tRAS + tRP)
    chk(g_rcd <= trcd_now() + 3 && g_rp <= TRP + 3 && g_ras <= TRAS + 3 &&
        g_rc <= ((TRC > TRAS + TRP) ? TRC : TRAS + TRP) + 3,
        $sformatf("min gaps tRCD %0d tRP %0d tRAS %0d tRC %0d", g_rcd, g_rp, g_ras, g_rc));
    $display("%s: %0d checks, ACT %0d RD %0d WR %0d PRE %0d REF %0d MRW %0d, max refresh gap %0d",
             name, checks, n_act, n_rd, n_wr, n_pre, n_ref, n_mrw, max_ref_gap);
    $display("  min gaps: tRCD %0d tRP %0d tRAS %0d tRC %0d", g_rcd, g_rp, g_ras, g_rc);
    if (errors == 0) $display("TEST PASSED: %s", name);
    else             $display("TEST FAILED: %0d errors", errors);
    $finish;
  endtask
