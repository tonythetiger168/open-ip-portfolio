// SPDX-License-Identifier: Apache-2.0
// Self-checking TB: master drives req flit with credits; checks rsp flit.
`timescale 1ns/1ps
module UCIe_tb;
  logic clk = 0, rst_n = 0;
  logic [43:0] txreqflit = '0;
  logic        txreqflitv = 0;
  logic        txreqlcrdv;
  logic [33:0] rxrspflit;
  logic        rxrspflitv;
  logic        rxrsplcrdv = 0;
  int errors = 0;

  UCIe_top dut (
    .clk(clk), .rst_n(rst_n),
    .txreqflit(txreqflit), .txreqflitv(txreqflitv), .txreqlcrdv(txreqlcrdv),
    .rxrspflit(rxrspflit), .rxrspflitv(rxrspflitv), .rxrsplcrdv(rxrsplcrdv),
    .busy(), .irq());

  always #5 clk = ~clk;

`ifdef VERILATOR
  // =====================================================================
  // v2.5 CRV instrumentation (tool build only; iverilog path unchanged)
  // FSM probed: dut.cstate (C_IDLE/C_LAT/C_SEND, 3 states).
  // =====================================================================
  localparam int UCIE_FSM_TOTAL = 3;  // C_IDLE..C_SEND
  logic [2:0] fsm_seen = '0;            // visited-state bitmap
  wire  [1:0] dut_state = dut.cstate;

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

  // FSM coverage: sample DUT state register every clock
  always @(posedge clk) fsm_seen[dut_state] <= 1'b1;



  // output-invariant assertion suite (sampled coherently pre-NBA)
  logic rst_n_q = 1'b1;
  always @(posedge clk) begin
    if (!rst_n) begin
      // A1: outputs quiescent during reset (one cycle for regs to init)
      if (!rst_n_q)
        sva_check(rxrspflitv === 1'b0 && dut.busy === 1'b0,
                  "A1 reset: outputs quiescent");
    end else begin
      // A2: response-valid exactly reflects C_SEND with a credit
      sva_check(rxrspflitv === ((dut_state == 2'd2) && (dut.tx_crd != 0)),
                "A2 flitv == C_SEND+credit");
      // A3: busy exactly reflects non-idle
      sva_check(dut.busy === (dut_state != 2'd0), "A3 busy == !C_IDLE");
      // A4: acceptance credit counter never exceeds the max
      sva_check(dut.rx_crd <= 4'd8, "A4 rx_crd within max");
      // A5: response credit counter never exceeds the max
      sva_check(dut.tx_crd <= 4'd8, "A5 tx_crd within max");
      // A6: irq mirrors response-valid
      sva_check(dut.irq === rxrspflitv, "A6 irq == flitv");
      // A7: valid response flits carry the OK opcode and set tag bit
      sva_check(!rxrspflitv ||
                (rxrspflit[33:29] === 5'b00001 && rxrspflit[0] === 1'b1),
                "A7 rsp flit opcode/tag");
    end
    rst_n_q <= rst_n;
  end
`endif

  // grant response credits periodically (master side)
`ifdef VERILATOR
  // constant grant in the coverage build: a second forever-coroutine with
  // thousands of suspends can lose wakeups under the 5.006 timing scheduler
  // (see docs/COVERAGE.md note 1), which would starve the response path
  initial begin
    rxrsplcrdv = 0;
    repeat(4) @(posedge clk);
    rxrsplcrdv = 1;
    @(posedge clk);          // one low->high->pulse for toggle coverage
    rxrsplcrdv = 0;
    @(posedge clk);
    rxrsplcrdv = 1;
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
      // wait for an acceptance credit from the slave
      @(posedge clk);
      while (!txreqlcrdv) @(posedge clk);
      txreqflit  <= {txn, addr};
      txreqflitv <= 1'b1;
      @(posedge clk);
      txreqflitv <= 1'b0;
      txreqflit  <= '0;
    end
  endtask

  task automatic expect_rsp(input logic [11:0] txn, input logic [15:0] data);
    logic [33:0] r;
    begin
      r = '0;
      wait (rxrspflitv === 1'b1);
      @(posedge clk); #1;
      r = rxrspflit;
      if (r[28:17] !== txn) begin
        errors++; $display("ERROR: UCIe rsp txn got=%h exp=%h", r[28:17], txn);
      end
      if (r[16:1] !== data) begin
        errors++; $display("ERROR: UCIe rsp data got=%h exp=%h", r[16:1], data);
      end
      if (r[33:29] !== 5'b00001) begin
        errors++; $display("ERROR: UCIe rsp opcode got=%b", r[33:29]);
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
    $display("DBG: directed done");
`endif

`ifdef VERILATOR
    // ---- v2.5 CRV random phase (directed tests above untouched) ----
    // 110 randomized flit transactions: random txnID/addr (normal),
    // boundary values (all-zero/all-one fields), and credit-protocol error
    // injection (flit offered while the DUT is busy must be ignored).
    // Fully inlined via macros (no timing-task coroutine chains): chained
    // task awaits hit the 5.006 timing-scheduler corruption after ~2k
    // suspensions; a single coroutine with plain awaits avoids it.
    begin : crv_phase
      int n_norm = 0, n_bnd = 0, n_inj = 0;
      logic [11:0] txn;
      logic [31:0] addr;
      logic [33:0] r_c;
      int roll;
      for (int t = 0; t < 110; t++) begin
        roll = $urandom_range(0, 9);
        txn  = $urandom_range(0, 4095);
        addr = $urandom;
        if (roll < 8) begin
          n_norm++;
          if (t % 11 == 0)      begin txn = 12'h000; addr = 32'h0;        end
          else if (t % 13 == 0) begin txn = 12'hFFF; addr = 32'hFFFF_FFFF; end
        end else begin
          n_bnd++;
          txn  = (t % 2 == 0) ? 12'h000 : 12'hFFF;
          addr = (t % 2 == 0) ? 32'hFFFF_FFFF : 32'h0000_0000;
        end
        // inlined send_req: fixed settle instead of credit polling (the
        // 8-deep acceptance credit can never be exhausted at ~1 flit / 9
        // clks with a 6-clk response loop), bounded by construction
        begin
          repeat (2) @(posedge clk);
          txreqflit  <= {txn, addr};
          txreqflitv <= 1'b1;
          @(posedge clk);
          txreqflitv <= 1'b0;
          txreqflit  <= '0;
        end
        if (roll >= 8) begin
          // error injection: junk flit while the DUT is busy (C_LAT)
          n_inj++;
          @(negedge clk);
          txreqflit  <= {12'h555, 32'h5555_5555};
          txreqflitv <= 1'b1;
          @(negedge clk);
          txreqflitv <= 1'b0;
          txreqflit  <= '0;
        end
        // inlined expect_rsp (bounded wait; junk flit must be ignored)
        begin
          int wt2;
          wt2 = 0;
          while (!rxrspflitv && wt2 < 2000) begin @(posedge clk); wt2++; end
          if (wt2 >= 2000) begin
            errors++;
            $display("ERROR: CRV rsp timeout t=%0d cstate=%0d tx_crd=%0d rx_crd=%0d lat=%0d lcrdv=%b",
                     t, dut.cstate, dut.tx_crd, dut.rx_crd, dut.lat_cnt, rxrsplcrdv);
          end
        end
        @(posedge clk); #1;
        r_c = rxrspflit;
        if (r_c[28:17] !== txn || r_c[16:1] !== addr[15:0] ||
            r_c[33:29] !== 5'b00001) begin
          errors++;
          $display("ERROR: CRV rsp got=%h exp txn=%h data=%h", r_c, txn, addr[15:0]);
        end
      end
      $display("CRV: 110 flits (normal=%0d boundary=%0d busy_inject=%0d)",
               n_norm, n_bnd, n_inj);
    end
`endif

    if (errors == 0) $display("TEST PASSED: UCIe");
    else             $display("TEST FAILED: %0d errors", errors);
`ifdef VERILATOR
    begin
      int visited;
      visited = 0;
      for (int s = 0; s < UCIE_FSM_TOTAL; s++) visited += fsm_seen[s];
      $display("FSM_COV: %0d/%0d", visited, UCIE_FSM_TOTAL);
      $display("SVA_CHECKS: %0d/%0d", sva_total - sva_fail, sva_total);
    end
`endif
    $finish;
  end

`ifdef VERILATOR
  // chunked timeout guard: a single long-pending #delay event corrupts the
  // 5.006 --timing delay heap once many short-delay resumptions interleave;
  // chunked delays keep all heap entries short-lived (see docs/COVERAGE.md)
  initial begin
    repeat (4000) #1000;   // 4 ms in 1-us chunks
    $display("TIMEOUT"); $finish;
  end
`else
  initial begin
    #500_000; $display("TIMEOUT"); $finish;
  end
`endif
endmodule
