// SPDX-License-Identifier: Apache-2.0
// Self-checking loopback testbench for UART_top -- SystemVerilog
`timescale 1ns/1ps
module UART_tb;
  localparam int N = 8;
  logic clk = 0, rst_n = 0;
  logic rxd, txd;
  logic [7:0] tx_data;
  logic tx_valid, tx_ready;
  logic [7:0] rx_data;
  logic rx_valid;
  logic [7:0] sent [0:N-1];
  int errors = 0;
  // loopback control: default 1 keeps the directed/iverilog path identical;
  // the CRV phase breaks the loop for false-start error injection
  logic loop_en = 1'b1;
  logic inj_rxd = 1'b1;

`ifdef VERILATOR
  // slower baud for the coverage build: DIV16=31 walks div_cnt[4:0]
  localparam int TB_BAUD = 100_000;
`else
  localparam int TB_BAUD = 1_000_000;
`endif

  UART_top #(.CLK_FREQ(50_000_000), .BAUD(TB_BAUD)) dut (
    .clk(clk), .rst_n(rst_n), .rxd(rxd), .txd(txd),
    .tx_data(tx_data), .tx_valid(tx_valid), .tx_ready(tx_ready),
    .rx_data(rx_data), .rx_valid(rx_valid), .irq());

  always #5 clk = ~clk;
  assign rxd = loop_en ? txd : inj_rxd;    // loopback (breakable for injection)

`ifdef VERILATOR
  // =====================================================================
  // v2.5 CRV instrumentation (tool build only; iverilog path unchanged)
  // FSMs probed: dut.tstate (TX_IDLE..TX_STOP) + dut.rstate
  // (RX_IDLE..RX_STOP), 8 states total.
  // =====================================================================
  localparam int UART_FSM_TOTAL = 8;  // 4 TX + 4 RX states
  logic [3:0] fsm_seen_t = '0;        // visited TX-state bitmap
  logic [3:0] fsm_seen_r = '0;        // visited RX-state bitmap
  wire  [1:0] dut_tstate = dut.tstate;
  wire  [1:0] dut_rstate = dut.rstate;

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
    fsm_seen_t[dut_tstate] <= 1'b1;
    fsm_seen_r[dut_rstate] <= 1'b1;
  end

  // output-invariant assertion suite (sampled coherently pre-NBA)
  logic [7:0] rx_data_q = '0;
  logic       rx_valid_q = 0;
  logic [1:0] rstate_q = '0;   // one-cycle-delayed RX state
  logic       rst_n_q = 1'b1;  // skip the very first reset edge (regs not yet init)
  always @(posedge clk) begin
    if (!rst_n) begin
      // A1: outputs quiescent during reset (line idle-high)
      if (!rst_n_q)
        sva_check(txd === 1'b1 && rx_valid === 1'b0 && tx_ready === 1'b1,
                  "A1 reset: outputs quiescent");
    end else begin
      // A2: line idles high whenever the TX FSM is idle
      sva_check((dut_tstate != 2'd0) || (txd === 1'b1), "A2 txd high in TX_IDLE");
      // A3: rx_valid is a single-cycle pulse
      sva_check(!(rx_valid && rx_valid_q), "A3 rx_valid single-cycle pulse");
      // A4: rx_valid only in the RX_STOP state
      sva_check(!rx_valid || (dut_rstate == 2'd3), "A4 rx_valid in RX_STOP");
      // A5: tx_ready exactly reflects TX_IDLE
      sva_check(tx_ready === (dut_tstate == 2'd0), "A5 tx_ready == TX_IDLE");
      // A6: rx_data updates only out of RX_DATA (NBA visible one cycle later)
      sva_check((rx_data === rx_data_q) || (rstate_q == 2'd2),
                "A6 rx_data stable outside RX_DATA");
      // A7: txd low only while transmitting start/data bits
      sva_check(txd || (dut_tstate == 2'd1) || (dut_tstate == 2'd2),
                "A7 txd low only in start/data");
    end
    rx_data_q  <= rx_data;
    rx_valid_q <= rx_valid;
    rstate_q   <= dut_rstate;
    rst_n_q    <= rst_n;
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
        $display("ERROR: UART byte %0d got=%h exp=%h", i, rx_data, sent[i]);
      end
      repeat (40) @(posedge clk);   // inter-frame idle: RX back to IDLE
    end

`ifdef VERILATOR
    // ---- v2.5 CRV random phase (directed tests above untouched) ----
    // 120 randomized transactions: random loopback bytes (normal, includes
    // 0x00/0xFF boundary data and back-to-back frames) plus false-start
    // glitch injection (error class: RX must reject and stay silent).
    begin : crv_phase
      int n_lb = 0, n_glit = 0;
      logic [7:0] v;
      int roll, glen;
      for (int t = 0; t < 120; t++) begin
        roll = $urandom_range(0, 9);
        if (roll < 2) begin
          // error injection: break the loopback and apply a short low
          // glitch (shorter than half a bit) -> false start, RX must abort
          n_glit++;
          wait (tx_ready === 1'b1);
          repeat (300) @(posedge clk); // let any RX activity drain (> half stop)
          loop_en = 1'b0;
          inj_rxd = 1'b0;
          glen = $urandom_range(2, 12);   // << half-bit (248 clks)
          repeat (glen) @(posedge clk);
          inj_rxd = 1'b1;
          repeat (600) @(posedge clk);    // > 1 bit: any false rx would show
          if (rx_valid === 1'b1) begin
            errors++;
            $display("ERROR: CRV rx_valid after false-start glitch len=%0d", glen);
          end
          loop_en = 1'b1;
        end else begin
          // random loopback byte; ~25% back-to-back (no inter-frame idle)
          n_lb++;
          if (t % 17 == 0)      v = 8'h00;   // boundary: all zeros
          else if (t % 19 == 0) v = 8'hFF;   // boundary: all ones
          else                  v = $urandom_range(0, 255);
          wait (tx_ready === 1'b1);
          @(negedge clk);
          tx_data  <= v;
          tx_valid <= 1'b1;
          wait (tx_ready === 1'b0);
          @(negedge clk);
          tx_valid <= 1'b0;
          wait (rx_valid === 1'b1);
          @(posedge clk); #1;
          if (rx_data !== v) begin
            errors++;
            $display("ERROR: CRV UART byte %0d got=%h exp=%h", t, rx_data, v);
          end
          if ($urandom_range(0, 3) != 0) repeat (40) @(posedge clk);
        end
      end
      $display("CRV: 120 txns (loopback=%0d glitch_inject=%0d)", n_lb, n_glit);
    end
`endif

    if (errors == 0) $display("TEST PASSED: UART");
    else             $display("TEST FAILED: %0d errors", errors);
`ifdef VERILATOR
    begin
      int visited;
      visited = 0;
      for (int s = 0; s < 4; s++) visited += fsm_seen_t[s] + fsm_seen_r[s];
      $display("FSM_COV: %0d/%0d", visited, UART_FSM_TOTAL);
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
    repeat (30000) #1000;  // 30 ms in 1-us chunks
    $display("TIMEOUT"); $finish;
  end
`else
  initial begin
    #5_000_000; $display("TIMEOUT"); $finish;
  end
`endif
endmodule
