// SPDX-License-Identifier: Apache-2.0
// ============================================================================
// Self-checking testbench for D_PHY_top (MIPI D-PHY lane pair TX + RX decode)
// The TB plays the host (HS byte stream / escape requests) and loops the
// data-lane TX pads back into the same-lane RX decoder through an injection
// mux, so protocol errors can be driven directly onto the lane.
// Checks:
//   - reset state; HS bursts of 0..N bytes (with host stalls) looped back
//     byte for byte, wire-level SoT / sync / EoT on the first burst, clock
//     lane entry and HS clock
//   - escape LPDT (0..N bytes, last flag, host underrun), ULPS with release,
//     Trigger-Reset, unknown command -> irq
//   - requests while busy are served later (HS first), pending escape
//     command replaced
//   - every RX grammar violation injected on the lane -> irq, resync on
//     LP-11, irq_clear
//   - reset during HS and during escape
// Under Verilator the bound checker (tb/cov/D_PHY_sva.sv) predicts every
// output on every clock.
// ============================================================================
`timescale 1ns/1ps
module D_PHY_tb;

  logic clk = 0, rst_n = 0;
  always #5 clk = ~clk;

  logic       hs_req = 0, hs_tx_valid = 0, esc_req = 0, esc_release = 0;
  logic       lpdt_valid = 0, lpdt_last = 0, irq_clear = 0;
  logic [7:0] hs_tx_data = 0, esc_cmd = 0, lpdt_data = 0;
  wire        hs_tx_ready, hs_tx_done, lpdt_ready, esc_done, irq;
  wire        d_lp_p, d_lp_n, d_hs_p, d_hs_n, d_hs_en;
  wire        c_lp_p, c_lp_n, c_hs_p, c_hs_n, c_hs_en;

  // injection mux: TB can seize the lane feeding the RX decoder
  logic       inj = 0;
  logic [1:0] i_lp = 2'b11;
  logic       i_hs_p = 0, i_hs_n = 1, i_hs_en = 0;
  wire r_lp_p  = inj ? i_lp[1] : d_lp_p;
  wire r_lp_n  = inj ? i_lp[0] : d_lp_n;
  wire r_hs_p  = inj ? i_hs_p  : d_hs_p;
  wire r_hs_n  = inj ? i_hs_n  : d_hs_n;
  wire r_hs_en = inj ? i_hs_en : d_hs_en;

  wire       rx_hs_active, rx_data_valid, rx_esc_valid, rx_ulps;
  wire [7:0] rx_data, rx_esc_cmd;

  D_PHY_top dut (.*);

  int errors = 0;
  task automatic fail(input string s);
    errors++; $display("ERROR: %s @%0t", s, $time);
  endtask

  // ------------------------------------------------------------------
  // RX monitor
  // ------------------------------------------------------------------
  logic [7:0] rxq [$];
  logic [7:0] cmdq [$];
  int         n_hs_done = 0, n_esc_done = 0;
  always @(posedge clk) begin
    if (rx_data_valid) rxq.push_back(rx_data);
    if (rx_esc_valid)  cmdq.push_back(rx_esc_cmd);
    if (hs_tx_done)    n_hs_done++;
    if (esc_done)      n_esc_done++;
  end

  // compare received bytes with the module-level queue exp_q
  logic [7:0] exp_q [$];
  task automatic expect_rx(input string s);
    if (rxq.size() != exp_q.size())
      fail($sformatf("%s: %0d bytes received, %0d expected", s, rxq.size(), exp_q.size()));
    else
      foreach (exp_q[i])
        if (rxq[i] !== exp_q[i]) fail($sformatf("%s: byte %0d = %h exp %h", s, i, rxq[i], exp_q[i]));
    rxq.delete();
  endtask

  task automatic wait_cond_hs(input int n0, input string s);
    int t;
    t = 0;
    while (n_hs_done == n0 && t < 2000) begin @(negedge clk); t++; end
    if (n_hs_done == n0) fail({"no hs_tx_done: ", s});
  endtask

  task automatic wait_cond_esc(input int n0, input string s);
    int t;
    t = 0;
    while (n_esc_done == n0 && t < 2000) begin @(negedge clk); t++; end
    if (n_esc_done == n0) fail({"no esc_done: ", s});
  endtask

  // ------------------------------------------------------------------
  // host tasks
  // ------------------------------------------------------------------
  // HS burst of n bytes; stall > 0 inserts up to that many idle cycles
  // between offers (a long stall ends the burst early: bytes after that are
  // not sent)
  logic [7:0] sent [$];
  int         hs_pat = -1, lp_pat = -1;     // forced data byte (directed)
  task automatic hs_burst(input int n, input int stall = 0, input bit rnd = 1);
    int n0, k;
    n0 = n_hs_done; k = 0;
    sent.delete();
    @(negedge clk); hs_req = 1;
    @(negedge clk); hs_req = 0;
    while (k < n && n_hs_done == n0) begin
      hs_tx_valid = 1;
      hs_tx_data  = rnd ? (hs_pat >= 0 ? 8'(hs_pat) : 8'($urandom)) : ((k % 2) ? 8'hFF : 8'h00);
      @(posedge clk);
      if (hs_tx_ready) begin sent.push_back(hs_tx_data); k++; end
      @(negedge clk);
      if (stall > 0 && k < n && ($urandom % 2)) begin
        hs_tx_valid = 0;
        repeat ($urandom % (stall + 1)) @(negedge clk);
      end
    end
    hs_tx_valid = 0;
    wait_cond_hs(n0, "hs burst");
    repeat (2) @(negedge clk);
    exp_q = sent;
    expect_rx("hs loopback");
  endtask

  task automatic esc(input logic [7:0] cmd);
    @(negedge clk); esc_req = 1; esc_cmd = cmd;
    @(negedge clk); esc_req = 0; esc_cmd = 8'($urandom);
  endtask

  // LPDT with n bytes, last flag on the final byte unless underrun
  task automatic lpdt(input int n, input bit underrun = 0, input int stall = 0);
    int n0, k;
    n0 = n_esc_done; k = 0;
    sent.delete();
    esc(8'h87);
    while (k < n && n_esc_done == n0) begin
      lpdt_valid = 1;
      lpdt_data  = lp_pat >= 0 ? 8'(lp_pat) : 8'($urandom);
      lpdt_last  = (k == n - 1) && !underrun;
      @(posedge clk);
      if (lpdt_ready) begin sent.push_back(lpdt_data); k++; end
      @(negedge clk);
      if (stall > 0 && k < n) begin
        lpdt_valid = 0;
        repeat ($urandom % (stall + 1)) @(negedge clk);
      end
    end
    lpdt_valid = 0; lpdt_last = 0;
    wait_cond_esc(n0, "lpdt");
    repeat (2) @(negedge clk);
    exp_q = sent;
    expect_rx("lpdt loopback");
    if (cmdq.size() != 1 || cmdq[0] !== 8'h87) fail("lpdt command not decoded");
    cmdq.delete();
  endtask

  // ------------------------------------------------------------------
  // lane injection helpers (RX error grammar)
  // ------------------------------------------------------------------
  task automatic sym(input logic [1:0] lp, input int n = 1);
    repeat (n) begin @(negedge clk); i_lp = lp; i_hs_en = 0; end
  endtask
  // n_ < 0: proper differential level, else drive hs_n = n_
  task automatic hsbit(input logic b, input int n_ = -1);
    @(negedge clk); i_hs_en = 1; i_hs_p = b; i_hs_n = (n_ < 0) ? !b : n_[0];
  endtask
  task automatic hsbyte(input logic [7:0] v);
    for (int i = 0; i < 8; i++) hsbit(v[i]);
  endtask
  task automatic lpbyte(input logic [7:0] v);
    for (int i = 0; i < 8; i++) sym(v[i] ? 2'b10 : 2'b00);
  endtask
  task automatic esc_entry;
    sym(2'b10); sym(2'b00); sym(2'b01); sym(2'b00);
  endtask
  task automatic hs_entry;
    sym(2'b01); sym(2'b00); hsbit(0);
  endtask
  // finish an injected sequence: back to stop, check irq and clear it
  task automatic inj_end(input bit exp_irq, input string s);
    sym(2'b11, 2);
    if (irq !== exp_irq) fail($sformatf("%s: irq=%b exp %b", s, irq, exp_irq));
    @(negedge clk); irq_clear = 1;
    @(negedge clk); irq_clear = 0;
    if (irq) fail({"irq_clear: ", s});
    rxq.delete(); cmdq.delete();
  endtask

  // ------------------------------------------------------------------
  // test sequence
  // ------------------------------------------------------------------
  logic [7:0] sy;
  int         n0, n1;

  initial begin
    repeat (3) @(negedge clk);
    if ({d_lp_p, d_lp_n, c_lp_p, c_lp_n} !== 4'hF || d_hs_en || c_hs_en || irq)
      fail("reset state");
    rst_n = 1;
    repeat (3) @(negedge clk);

    // ---------------- first HS burst: wire-level checks
    fork
      hs_burst(2, 0, 0);
      begin
        @(posedge hs_req);
        @(negedge clk);
        if ({d_lp_p, d_lp_n} !== 2'b01 || {c_lp_p, c_lp_n} !== 2'b01) fail("SoT LP-01");
        @(negedge clk);
        if ({d_lp_p, d_lp_n} !== 2'b00 || {c_lp_p, c_lp_n} !== 2'b00) fail("SoT LP-00");
        @(negedge clk);
        if (!d_hs_en || d_hs_p || !c_hs_en) fail("SoT HS-0");
        for (int i = 0; i < 8; i++) begin
          @(negedge clk); sy[i] = d_hs_p;
          if (d_hs_n !== !d_hs_p) fail("HS differential");
        end
        if (sy !== 8'hB8) fail($sformatf("sync byte %h", sy));
        repeat (17) @(negedge clk);
        if (d_hs_p !== 1'b0) fail("EoT inverted bit");   // last payload bit was 1
        @(negedge clk);
        if (d_hs_p !== 1'b1) fail("EoT hold bit");
        @(negedge clk);
        if (d_hs_en || {d_lp_p, d_lp_n} !== 2'b11) fail("EoT stop");
      end
    join

    // ---------------- HS bursts: sizes, data patterns, host stalls
    hs_burst(0);
    hs_burst(1);
    hs_burst(3);
    for (int i = 0; i < 6; i++) hs_burst(1 + $urandom % 12);
    for (int i = 0; i < 4; i++) hs_burst(4, 0, 0);
    for (int i = 0; i < 6; i++) hs_burst(8, 9);       // stalls, some end early
    // back-to-back request while the lane is busy
    n0 = n_hs_done;
    @(negedge clk); hs_req = 1;
    @(negedge clk); hs_req = 0;
    repeat (3) @(negedge clk);
    hs_req = 1; @(negedge clk); hs_req = 0;            // queued
    repeat (40) @(negedge clk);
    if (n_hs_done != n0 + 2) fail("queued hs request not served");
    rxq.delete();

    // ---------------- escape: LPDT
    lpdt(0);
    lpdt(1);
    lpdt(3);
    for (int i = 0; i < 4; i++) lpdt(2 + $urandom % 5, 0, 3);
    lpdt(2, 1);                                        // no last flag: underrun
    lpdt(4, 1, 12);
    // ---------------- ULPS / trigger / unknown
    n0 = n_esc_done;
    esc(8'h78);
    @(negedge clk); esc_release = 1;                   // too early: ignored
    @(negedge clk); esc_release = 0;
    repeat (15) @(negedge clk);
    if (!rx_ulps) fail("ULPS not observed");
    repeat (20) @(negedge clk);
    if (!rx_ulps || n_esc_done != n0) fail("ULPS not held");
    @(negedge clk); esc_release = 1;
    @(negedge clk); esc_release = 0;
    wait_cond_esc(n0, "ulps exit");
    n0 = n_esc_done;
    esc(8'h46);
    wait_cond_esc(n0, "trigger");
    if (irq) fail("irq after trigger");
    if (cmdq.size() != 2 || cmdq[0] !== 8'h78 || cmdq[1] !== 8'h46) fail("ulps/trigger cmds");
    cmdq.delete();
    for (int i = 0; i < 6; i++) begin                  // unknown commands
      n0 = n_esc_done;
      esc((i == 0) ? 8'h00 : (i == 1) ? 8'hFF : 8'($urandom));
      wait_cond_esc(n0, "unknown command");
      repeat (3) @(negedge clk);
      if (!irq) fail("unknown command irq");
      @(negedge clk); irq_clear = 1;
      @(negedge clk); irq_clear = 0;
    end
    cmdq.delete();

    // ---------------- requests while busy
    n0 = n_esc_done; n1 = n_hs_done;
    @(negedge clk); hs_req = 1; esc_req = 1; esc_cmd = 8'h46;     // both at once
    @(negedge clk); hs_req = 0; esc_req = 0;
    repeat (5) @(negedge clk);
    esc_req = 1; esc_cmd = 8'h00;                                  // replaced below
    @(negedge clk); esc_cmd = 8'h87;
    @(negedge clk); esc_req = 0;
    repeat (80) @(negedge clk);
    if (n_hs_done != n1 + 1 || n_esc_done != n0 + 1) fail("pending requests");
    if (cmdq.size() != 1 || cmdq[0] !== 8'h87) fail("pending command replaced");
    n0 = n_esc_done;
    esc(8'h46);
    repeat (4) @(negedge clk);
    hs_req = 1; @(negedge clk); hs_req = 0;            // HS requested during escape
    esc(8'h78);                                        // and another escape
    repeat (60) @(negedge clk);
    esc_release = 1; @(negedge clk); esc_release = 0;
    repeat (20) @(negedge clk);
    if (irq) fail("irq after queued traffic");
    rxq.delete(); cmdq.delete();

    // ---------------- RX grammar violations (lane injected)
    @(negedge clk); inj = 1; i_lp = 2'b11; i_hs_en = 0;
    sym(2'b11, 2);
    // valid injected sequences first (no irq)
    hs_entry(); hsbyte(8'hB8); hsbyte(8'h5A); hsbyte(8'hA5); hsbit(1); hsbit(0); sym(2'b11);
    exp_q = '{8'h5A, 8'hA5}; expect_rx("injected hs");
    esc_entry(); lpbyte(8'h87); lpbyte(8'h3C); sym(2'b01); sym(2'b10); sym(2'b11);
    exp_q = '{8'h3C}; expect_rx("injected lpdt");
    inj_end(0, "valid injected");
    // stop state
    sym(2'b00); inj_end(1, "LP-00 from stop");
    // HS entry
    sym(2'b01); sym(2'b01); sym(2'b10); inj_end(1, "HS request");
    sym(2'b01); sym(2'b11); inj_end(1, "HS request stop");
    sym(2'b01); sym(2'b00); sym(2'b00); inj_end(1, "no HS-0");
    sym(2'b01); sym(2'b00); hsbit(1); inj_end(1, "HS-1 instead of HS-0");
    sym(2'b01); sym(2'b00); hsbit(0, 0); inj_end(1, "HS-0 bad differential");
    hs_entry(); hsbit(0); hsbit(0); sym(2'b11); inj_end(1, "HS dropped in sync");
    hs_entry(); hsbit(0); hsbit(1, 1); inj_end(1, "invalid level in sync");
    hs_entry(); hsbyte(8'hB9); inj_end(1, "bad sync");
    hs_entry(); hsbyte(8'h38); inj_end(1, "bad sync 2");
    hs_entry(); hsbyte(8'hB8); hsbit(1); hsbit(0, 0); inj_end(1, "invalid level in data");
    hs_entry(); hsbyte(8'hB8); hsbit(1); hsbit(1, 1); i_lp = 2'b11;
    @(negedge clk); @(negedge clk); i_hs_en = 1;                   // LP-11 with HS still on
    @(negedge clk); i_hs_en = 0; inj_end(1, "error waits for HS off");
    // escape entry / command
    sym(2'b10); sym(2'b01); inj_end(1, "escape entry 1");
    sym(2'b10); sym(2'b00); sym(2'b00); inj_end(1, "escape entry 2");
    sym(2'b10); sym(2'b00); sym(2'b01); sym(2'b01); inj_end(1, "escape entry 3");
    esc_entry(); sym(2'b10); sym(2'b01); inj_end(1, "LP-01 in command");
    esc_entry(); sym(2'b00); sym(2'b11); inj_end(1, "LP-11 in command");
    esc_entry(); lpbyte(8'h5A); inj_end(1, "unknown command");
    // LPDT / ULPS / trigger / exits
    esc_entry(); lpbyte(8'h87); sym(2'b10); sym(2'b01); inj_end(1, "LP-01 inside LPDT byte");
    esc_entry(); lpbyte(8'h87); sym(2'b11); inj_end(1, "LP-11 in LPDT");
    esc_entry(); lpbyte(8'h78); sym(2'b00, 3); sym(2'b01); inj_end(1, "ULPS level");
    esc_entry(); lpbyte(8'h78); sym(2'b11); inj_end(1, "ULPS stop");
    esc_entry(); lpbyte(8'h46); sym(2'b01); inj_end(1, "trigger level");
    esc_entry(); lpbyte(8'h46); sym(2'b11); inj_end(1, "trigger stop");
    esc_entry(); lpbyte(8'h87); sym(2'b01); sym(2'b00); inj_end(1, "LPDT exit");
    esc_entry(); lpbyte(8'h87); sym(2'b01); sym(2'b11); inj_end(1, "LPDT exit stop");
    esc_entry(); lpbyte(8'h46); sym(2'b10); sym(2'b00); inj_end(1, "escape exit");
    esc_entry(); lpbyte(8'h46); sym(2'b10); sym(2'b01); inj_end(1, "escape exit 01");
    // irq_clear in the same cycle as a new error: the error wins
    sym(2'b00);
    @(negedge clk); i_lp = 2'b11;
    sym(2'b00); irq_clear = 1; @(negedge clk); irq_clear = 0;
    if (!irq) fail("irq clear collision");
    inj_end(1, "clear collision");
    // toggle the rx data / command registers through all-ones / all-zeros
    for (int i = 0; i < 4; i++) begin
      hs_entry(); hsbyte(8'hB8); hsbyte((i % 2) ? 8'hFF : 8'h00); hsbit(0); sym(2'b11);
      esc_entry(); lpbyte(8'h87); lpbyte((i % 2) ? 8'h00 : 8'hFF); sym(2'b01); sym(2'b10);
      sym(2'b11);
    end
    inj_end(0, "rx patterns");
    inj = 0;
    repeat (3) @(negedge clk);

    // ---------------- reset during HS and during escape
    @(negedge clk); hs_req = 1;
    @(negedge clk); hs_req = 0; hs_tx_valid = 1;
    repeat (30) begin @(negedge clk); hs_tx_data = 8'($urandom); end
    rst_n = 0; hs_tx_valid = 0;
    repeat (2) @(negedge clk); rst_n = 1;
    repeat (3) @(negedge clk);
    rxq.delete();
    esc(8'h78);
    repeat (8) @(negedge clk);
    rst_n = 0;
    repeat (2) @(negedge clk); rst_n = 1;
    repeat (3) @(negedge clk);
    rxq.delete(); cmdq.delete();
    hs_burst(2);
    lpdt(2);
    // data patterns both ways
    for (int k = 0; k < 4; k++) begin
      hs_pat = k == 0 ? 8'h00 : k == 1 ? 8'hFF : k == 2 ? 8'h55 : 8'hAA; lp_pat = hs_pat;
      hs_burst(2);
      lpdt(2);
    end
    hs_pat = -1; lp_pat = -1;

    if (errors == 0) $display("TEST PASSED: D_PHY");
    else             $display("TEST FAILED: %0d errors", errors);
    $finish;
  end

  initial begin
    #5_000_000;
    $display("TEST FAILED: TIMEOUT"); $finish;
  end
endmodule
