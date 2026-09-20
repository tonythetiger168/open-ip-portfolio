// SPDX-License-Identifier: Apache-2.0
// Self-checking loopback testbench for UART_top -- SystemVerilog
`timescale 1ns/1ps
module ARM_Serial_Wire_Debug_tb;
  localparam int N = 8;
  logic clk = 0, rst_n = 0;
  logic rxd, txd;
  logic [7:0] tx_data;
  logic tx_valid, tx_ready;
  logic [7:0] rx_data;
  logic rx_valid;
  logic [7:0] sent [0:N-1];
  int errors = 0;

  ARM_Serial_Wire_Debug_top #(.CLK_FREQ(50_000_000), .BAUD(1_000_000)) dut (
    .clk(clk), .rst_n(rst_n), .rxd(rxd), .txd(txd),
    .tx_data(tx_data), .tx_valid(tx_valid), .tx_ready(tx_ready),
    .rx_data(rx_data), .rx_valid(rx_valid), .irq());

  always #5 clk = ~clk;
  assign rxd = txd;    // loopback

`ifdef VERILATOR
  // =====================================================================
  // v2.5 CRV instrumentation (Verilator only; iverilog path unchanged)
  // Tool notes (Verilator 5.006): no native FSM/SVA coverage and
  // randomize() ignores constraint blocks -> procedural constraints
  // ($urandom_range + rejection sampling), TB FSM probe, immediate
  // assertions.
  // =====================================================================
  localparam int SWD_FSM_TOTAL = 8;   // TX 4 states + RX 4 states
  logic [7:0] fsm_seen = '0;          // visited-state bitmap
  wire [1:0] dut_tstate = dut.tstate; // hierarchical FSM probes
  wire [1:0] dut_rstate = dut.rstate;
  wire       dut_irq    = dut.irq;    // unconnected port, probed in DUT scope

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

  // FSM coverage: sample both DUT state registers every clock
  always @(posedge clk) begin
    fsm_seen[dut_tstate]     <= 1'b1;
    fsm_seen[4 + dut_rstate] <= 1'b1;
  end

  // output-invariant assertion suite (sampled coherently pre-NBA).
  // p_rstn is rst_n delayed by one clock: at the deasserting edge the
  // pre-NBA sample still sees reset values, so the reset check must be
  // keyed on the previous cycle's rst_n.
  logic p_rstn  = 1;
  logic p_rxv   = 0;
  logic rst_obs = 0;   // set once reset has been observed (skips the t=0
                       // sample: on the very first posedge this block can
                       // run before the DUT's initial reset settle)
  always @(posedge clk) begin
    if (!rst_n) rst_obs <= 1'b1;
    if (rst_obs) begin
    if (!p_rstn) begin
      // A1: outputs quiescent during reset
      sva_check(txd === 1'b1 && rx_valid === 1'b0 && dut_irq === 1'b0,
                "A1 reset: outputs quiescent");
    end else begin
      // A2: irq is a pure copy of rx_valid
      sva_check(dut_irq === rx_valid, "A2 irq equals rx_valid");
      // A3: rx_valid is a single-cycle pulse (no back-to-back)
      sva_check(!(rx_valid && p_rxv), "A3 rx_valid single-cycle pulse");
      // A4: TX line is idle-high whenever the TX FSM is in IDLE
      sva_check((dut_tstate != 2'd0) || (txd === 1'b1), "A4 txd idle-high");
    end
    end
    p_rstn <= rst_n;
    p_rxv  <= rx_valid;
  end
`endif

  initial begin
    tx_valid = 0; tx_data = 0;
    rst_n = 0; repeat(10) @(posedge clk);
    rst_n = 1; repeat(20) @(posedge clk);
    for (int i = 0; i < N; i++) begin
      sent[i] = 8'hA5 ^ (i * 8'h11);
      wait (tx_ready === 1'b1);        // ensure TX is idle before requesting
      @(negedge clk);
      tx_data  <= sent[i];
      tx_valid <= 1'b1;
      wait (tx_ready === 1'b0);        // now this edge means real acceptance
      @(negedge clk);
      tx_valid <= 1'b0;
      wait (rx_valid === 1'b1);
      @(posedge clk); #1;
      if (rx_data !== sent[i]) begin
        errors++;
        $display("ERROR: ARM Serial Wire Debug byte %0d got=%h exp=%h", i, rx_data, sent[i]);
      end
      repeat (40) @(posedge clk);   // inter-frame idle: RX back to IDLE
    end
`ifdef VERILATOR
    // ---- v2.5 CRV random phase (directed tests above untouched) ------
    // 120 randomized loopback bytes: corner-mixed data (00/FF/55/AA +
    // uniform random) and randomized inter-frame idle gaps; every byte
    // self-checked against the loopback echo.
    begin : crv_phase
      int n_tx = 0;
      logic [7:0] b;
      for (int t = 0; t < 120; t++) begin
        case ($urandom_range(0, 9))
          0:       b = 8'h00;
          1:       b = 8'hFF;
          2:       b = 8'h55;
          3:       b = 8'hAA;
          default: b = 8'($urandom_range(0, 255));
        endcase
        wait (tx_ready === 1'b1);    // TX idle before requesting
        @(negedge clk);
        tx_data  <= b;
        tx_valid <= 1'b1;
        wait (tx_ready === 1'b0);    // real acceptance
        @(negedge clk);
        tx_valid <= 1'b0;
        wait (rx_valid === 1'b1);
        @(posedge clk); #1;
        if (rx_data !== b) begin
          errors++;
          $display("ERROR: CRV byte %0d got=%h exp=%h", t, rx_data, b);
        end
        n_tx++;
        repeat ($urandom_range(0, 40)) @(posedge clk);  // random gap
      end
      $display("CRV: %0d random loopback bytes", n_tx);
    end
`endif
    if (errors == 0) $display("TEST PASSED: ARM Serial Wire Debug");
    else             $display("TEST FAILED: %0d errors", errors);
`ifdef VERILATOR
    begin
      int visited;
      visited = 0;
      for (int s = 0; s < SWD_FSM_TOTAL; s++) visited += fsm_seen[s];
      $display("FSM_COV: %0d/%0d", visited, SWD_FSM_TOTAL);
      $display("SVA_CHECKS: %0d/%0d", sva_total - sva_fail, sva_total);
    end
`endif
    $finish;
  end

  // timeout guard
`ifdef VERILATOR
  // Chunked timeout: with Verilator 5.006 a single long-pending #delay
  // event corrupts the --timing delay heap once many short-delay
  // resumptions interleave with it (processes lose wakeups and the long
  // event fires early). 1-us chunks keep all heap entries short-lived
  // (verified with a minimal repro).
  initial begin
    repeat (5000) #1000;   // 5 ms in 1-us chunks
    $display("TIMEOUT");
    $finish;
  end
`else
  initial begin
    #5_000_000; $display("TIMEOUT"); $finish;
  end
`endif
endmodule
