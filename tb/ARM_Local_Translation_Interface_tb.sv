// SPDX-License-Identifier: Apache-2.0
// Self-checking TB: master drives req flit with credits; checks rsp flit.
`timescale 1ns/1ps
module ARM_Local_Translation_Interface_tb;
  logic clk = 0, rst_n = 0;
  logic [43:0] txreqflit = '0;
  logic        txreqflitv = 0;
  logic        txreqlcrdv;
  logic [33:0] rxrspflit;
  logic        rxrspflitv;
  logic        rxrsplcrdv = 0;
  int errors = 0;

`ifdef VERILATOR
  // =====================================================================
  // v2.5 CRV instrumentation (Verilator only; iverilog path unchanged)
  // Tool notes (Verilator 5.006): no native FSM/SVA coverage and
  // randomize() ignores constraint blocks -> procedural constraints
  // ($urandom_range + rejection sampling), TB FSM probe, immediate
  // assertions. The timeout guard is chunked (see bottom of file).
  // This TB family also hits the 5.006 slow-scheduler mode (coroutine
  // wakeups resume ~10 us late; minimal repro: DUT-less clk +
  // repeat(30) @(posedge clk) -> 295 us), hence: level/sticky waits in
  // the driver tasks, negedge-sampled history-free assertions, dual-
  // edge FSM sampling, oversized chunked timeout.
  // =====================================================================
  localparam int FLIT_FSM_TOTAL = 3;  // C_IDLE / C_LAT / C_SEND (rtl enum)
  logic [2:0] fsm_seen = '0;          // visited-state bitmap
  wire  [1:0] dut_cstate = dut.cstate;  // hierarchical probes
  wire  [3:0] dut_rx_crd = dut.rx_crd;
  wire  [3:0] dut_tx_crd = dut.tx_crd;
  wire  [3:0] dut_crd_tim = dut.crd_timer;
  wire        dut_busy   = dut.busy;    // unconnected at the TB port map
  wire        dut_irq    = dut.irq;

  int sva_total = 0, sva_fail = 0;
  // counted immediate assertion: every evaluation is one check
  task automatic sva_check(input bit cond, input string name);
    begin
      sva_total++;
      if (!cond) begin
        sva_fail++;
        errors++;
        $display("SVA_FAIL: %s @%0t", name, $time);
      end
    end
  endtask

  // FSM coverage: sample DUT state register on both clock edges
  // (5.006 slow-scheduler mode can drop single-edge wakeups)
  always @(clk) fsm_seen[dut_cstate] <= 1'b1;

  // sticky response capture: rxrspflitv is a single-cycle pulse that a
  // delayed coroutine resume would miss; a static always block samples
  // it reliably and holds the flit until the stimulus consumes it
  logic        rsp_seen = 1'b0;
  logic [33:0] rsp_cap  = '0;
  always @(posedge clk) if (rxrspflitv) begin
    rsp_seen <= 1'b1;
    rsp_cap  <= rxrspflit;
  end

  // output-invariant assertion suite. Sampled at negedge and kept
  // history-free (level/combinational checks only): in this TB family
  // the 5.006 timing scheduler resumes coroutine wakeups ~10 us late,
  // so prev-cycle sampled checks produce stale-NBA false failures.
  always @(negedge clk) begin
    if (!rst_n) begin
      // A1: outputs quiescent during reset
      sva_check(rxrspflitv === 1'b0 && dut_busy === 1'b0 && dut_irq === 1'b0,
                "A1 reset: outputs quiescent");
    end else begin
      // A2: a response flit is only emitted while a request is in flight
      sva_check(!rxrspflitv || dut_busy, "A2 rsp implies busy");
      // A3: response opcode is the fixed OK encoding
      sva_check(!rxrspflitv || (rxrspflit[33:29] === 5'b00001),
                "A3 rsp opcode OK");
      // A4: response valid-tag bit is set
      sva_check(!rxrspflitv || (rxrspflit[0] === 1'b1), "A4 rsp tag set");
      // A5: FSM holds a legal enum encoding
      sva_check(dut_cstate <= 2'd2, "A5 cstate encoding legal");
      // A6: credit counters never exceed CRD_MAX
      sva_check((dut_rx_crd <= 4'd8) && (dut_tx_crd <= 4'd8),
                "A6 credits within max");
      // A7: acceptance-credit grant combinationally reflects the
      // credit timer (history-free check)
      sva_check(txreqlcrdv === (dut_crd_tim == 4'd0),
                "A7 lcrdv == (crd_timer==0)");
    end
  end
`endif

  ARM_Local_Translation_Interface_top dut (
    .clk(clk), .rst_n(rst_n),
    .txreqflit(txreqflit), .txreqflitv(txreqflitv), .txreqlcrdv(txreqlcrdv),
    .rxrspflit(rxrspflit), .rxrspflitv(rxrspflitv), .rxrsplcrdv(rxrsplcrdv),
    .busy(), .irq());

  always #5 clk = ~clk;

  // grant response credits periodically (master side)
`ifdef VERILATOR
  // always-block credit grant: with Verilator 5.006 --timing, concurrent
  // forever-loop coroutines can lose event wakeups (W6 failure mode);
  // a plain clocked always block is a static process and schedules
  // cleanly. iverilog keeps the original coroutine driver.
  logic [2:0] crd_div = 0;
  always @(posedge clk) begin
    crd_div    <= crd_div + 3'd1;
    rxrsplcrdv <= (crd_div == 3'd3);
  end
`else
  initial begin
    rxrsplcrdv = 0;
    repeat(4) @(posedge clk);
    forever begin
      repeat(8) @(posedge clk);
      rxrsplcrdv <= 1;
      @(posedge clk);
      rxrsplcrdv <= 0;
    end
  end
`endif

  task automatic send_req(input logic [11:0] txn, input logic [31:0] addr);
    begin
`ifdef VERILATOR
      // level-based acceptance wait (no pulse sampling): issue the flit
      // when the slave is idle with acceptance credit available, driven
      // at negedge so it is stable for the capturing posedge. Immune to
      // the 5.006 slow-scheduler resume delay (coroutine wakeups land
      // ~10 us late; level waits cannot miss, pulse waits can).
      while (!((dut_cstate == 2'd0) && (dut_rx_crd != 4'd0)))
        @(negedge clk);
      txreqflit  <= {txn, addr};
      txreqflitv <= 1'b1;
      @(negedge clk);
      txreqflitv <= 1'b0;
      txreqflit  <= '0;
`else
      // wait for an acceptance credit from the slave
      @(posedge clk);
      while (!txreqlcrdv) @(posedge clk);
      txreqflit  <= {txn, addr};
      txreqflitv <= 1'b1;
      @(posedge clk);
      txreqflitv <= 1'b0;
      txreqflit  <= '0;
`endif
    end
  endtask

  task automatic expect_rsp(input logic [11:0] txn, input logic [15:0] data);
    logic [33:0] r;
    begin
      r = '0;
`ifdef VERILATOR
      // consume the sticky-captured response (see rsp_seen/rsp_cap above)
      while (!rsp_seen) @(negedge clk);
      rsp_seen = 1'b0;
      r = rsp_cap;
`else
      wait (rxrspflitv === 1'b1);
      @(posedge clk); #1;
      r = rxrspflit;
`endif
      if (r[28:17] !== txn) begin
        errors++; $display("ERROR: ARM Local Translation Interface rsp txn got=%h exp=%h", r[28:17], txn);
      end
      if (r[16:1] !== data) begin
        errors++; $display("ERROR: ARM Local Translation Interface rsp data got=%h exp=%h", r[16:1], data);
      end
      if (r[33:29] !== 5'b00001) begin
        errors++; $display("ERROR: ARM Local Translation Interface rsp opcode got=%b", r[33:29]);
      end
    end
  endtask

  initial begin
    rst_n = 0; repeat(10) @(posedge clk);
    rst_n = 1; repeat(20) @(posedge clk);

    send_req(12'hA5A, 32'hDEAD_BEEF);
    expect_rsp(12'hA5A, 16'hBEEF);
    repeat(10) @(posedge clk);
    send_req(12'h123, 32'hCAFE_0001);
    expect_rsp(12'h123, 16'h0001);

`ifdef VERILATOR
    // ---- v2.5 CRV random phase (directed tests above untouched) ------
    // 120 randomized request flits: random txnID and address payload,
    // random inter-request gaps; every response is self-checked against
    // the expected echo (opcode / txnID / low data half). Boundary flits
    // (all-zero / all-one txnID+addr) are forced first. The DUT has no
    // error-response path; injection coverage is provided by boundary
    // encodings and credit-stress (requests issued immediately when an
    // acceptance credit is available, gaps randomized down to zero).
    begin : crv_phase
      logic [11:0] c_txn;
      logic [31:0] c_addr;
      int n_req = 0;
      for (int t = 0; t < 120; t++) begin
        if (t == 0) begin
          c_txn = 12'h000; c_addr = 32'h0000_0000;   // boundary: all zero
        end else if (t == 1) begin
          c_txn = 12'hFFF; c_addr = 32'hFFFF_FFFF;   // boundary: all ones
        end else begin
          c_txn  = 12'($urandom_range(0, 4095));
          c_addr = $urandom;
        end
        send_req(c_txn, c_addr);
        expect_rsp(c_txn, c_addr[15:0]);
        n_req++;
        if (n_req % 20 == 0)
          $display("CRV progress: %0d/120 @%0t", n_req, $time);
        repeat ($urandom_range(0, 3)) @(posedge clk);  // random gap
      end
      $display("CRV: %0d random flits (2 boundary + uniform mix)", n_req);
      $display("CRV probe: tx_crd=%0d rx_crd=%0d", dut_tx_crd, dut_rx_crd);
    end
`endif
    if (errors == 0) $display("TEST PASSED: ARM Local Translation Interface");
    else             $display("TEST FAILED: %0d errors", errors);
`ifdef VERILATOR
    begin
      int visited;
      visited = 0;
      for (int s = 0; s < FLIT_FSM_TOTAL; s++) visited += fsm_seen[s];
      $display("FSM_COV: %0d/%0d", visited, FLIT_FSM_TOTAL);
      $display("SVA_CHECKS: %0d/%0d", sva_total - sva_fail, sva_total);
    end
`endif
    $finish;
  end

`ifdef VERILATOR
  // Chunked timeout: with Verilator 5.006 a single long-pending #delay
  // event corrupts the --timing delay heap once many short-delay
  // resumptions interleave with it. Additionally, in this TB family
  // coroutine wakeups resume ~10 us late (5.006 slow-scheduler mode),
  // so the chunk count is oversized to guarantee the stimulus coroutine
  // always finishes first (functional results are unaffected; only sim
  // time stretches, wall-clock stays in seconds).
  initial begin
    repeat (60000) #1000;   // 60 ms in 1-us chunks (see note)
    $display("TIMEOUT"); $finish;
  end
`else
  initial begin
    #500_000; $display("TIMEOUT"); $finish;
  end
`endif
endmodule
