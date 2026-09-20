// SPDX-License-Identifier: Apache-2.0
// Self-checking testbench for AXI_Stream_top -- SystemVerilog
`timescale 1ns/1ps
module AXI_Stream_tb;
  logic clk = 0, rst_n = 0;
  logic tvalid = 0, tready;
  logic [31:0] tdata = 0;
  logic tlast = 0;
  logic ren = 0;
  logic [3:0] raddr = 0;
  logic [31:0] rdata;
  logic [4:0] count;
  logic irq;
  logic irq_seen = 0;
  int errors = 0;

  AXI_Stream_top dut (
    .clk(clk), .rst_n(rst_n), .tvalid(tvalid), .tready(tready),
    .tdata(tdata), .tlast(tlast), .ren(ren), .raddr(raddr),
    .rdata(rdata), .count(count), .irq(irq));

  always #5 clk = ~clk;
  always @(posedge clk) if (irq) irq_seen <= 1'b1;

  task automatic send(input logic [31:0] d, input logic last);
    begin
      wait (tready === 1'b1);
      @(negedge clk);
      tdata <= d; tlast <= last; tvalid <= 1'b1;
      @(posedge clk); #1;
      if (tready !== 1'b1) begin
        errors++; $display("ERROR: AXIS tready dropped mid-beat");
      end
      @(negedge clk);
      tvalid <= 1'b0; tlast <= 1'b0;
    end
  endtask

`ifdef VERILATOR
  // =====================================================================
  // v2.5 CRV instrumentation (Verilator only; iverilog path unchanged)
  // Tool notes (Verilator 5.006): no native FSM/SVA coverage and
  // randomize() ignores constraint blocks -> procedural constraints
  // ($urandom_range + rejection sampling), TB probe, immediate
  // assertions. The timeout guard is chunked (see bottom of file).
  // Note: this DUT has no state-register FSM; the FIFO write pointer
  // (wr_ptr, values 0..DEPTH) is the sequential state variable and is
  // probed as the FSM state (17 states).
  // =====================================================================
  localparam int AXIS_FSM_TOTAL = 17;  // wr_ptr values 0..16 (DEPTH=16)
  logic [16:0] fsm_seen = '0;          // visited-state bitmap
  wire  [4:0]  dut_wrptr = dut.wr_ptr; // hierarchical probe

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

  // FSM coverage: sample DUT write pointer every clock
  always @(posedge clk) if (dut_wrptr <= 5'd16) fsm_seen[dut_wrptr] <= 1'b1;

  // output-invariant assertion suite (sampled coherently pre-NBA)
  logic [4:0] p_count = 0;
  logic       p_tready = 0;
  always @(posedge clk) begin
    if (!rst_n) begin
      // A1: FIFO empty during reset
      sva_check(count === 5'd0, "A1 reset: count zero");
    end else begin
      // A2: count never exceeds DEPTH
      sva_check(count <= 5'd16, "A2 count within depth");
      // A3: tready reflects FIFO-not-full exactly
      sva_check(tready === (count < 5'd16), "A3 tready == not full");
      // A4: irq only on an accepted tlast beat
      sva_check(!irq || (tvalid && tlast && tready), "A4 irq == push&tlast");
      // A5: count only increments by one per cycle
      sva_check((count === p_count) || (count === p_count + 5'd1),
                "A5 count steps by <=1");
      // A6: no count change unless tready was high last cycle (a push
      // can only land while the FIFO is not full)
      sva_check(p_tready || (count === p_count), "A6 count changes only via push");
    end
    p_count  <= count;
    p_tready <= tready;
  end
`endif

  logic [31:0] exp [0:4];
  initial begin
    exp[0] = 32'hDEAD_BEEF; exp[1] = 32'h1234_5678;
    exp[2] = 32'hA5A5_5A5A; exp[3] = 32'h0BAD_F00D;
    exp[4] = 32'hC001_D00D;
  end
  initial begin
    rst_n = 0; repeat(5) @(posedge clk);
    rst_n = 1; repeat(5) @(posedge clk);

    for (int i = 0; i < 5; i++) send(exp[i], i == 4);

    repeat(2) @(posedge clk);
    if (count !== 5'd5) begin
      errors++; $display("ERROR: AXIS count got=%0d exp=5", count);
    end
    if (!irq_seen) begin
      errors++; $display("ERROR: AXIS irq never fired");
    end
    for (int i = 0; i < 5; i++) begin
      @(negedge clk); ren <= 1'b1; raddr <= i[3:0];
      #1;
      if (rdata !== exp[i]) begin
        errors++; $display("ERROR: AXIS mem[%0d] got=%h exp=%h", i, rdata, exp[i]);
      end
      @(negedge clk); ren <= 1'b0;
    end

`ifdef VERILATOR
    // ---- v2.5 CRV random phase (directed test above untouched) -------
    // 12 rounds; each round re-resets the FIFO, pushes a random number
    // of random-data beats (random tlast injection), then reads back and
    // compares the captured contents. Rounds that fill the FIFO add
    // error injection: tvalid beats while tready is low must be dropped
    // (count and contents unchanged). Round 0 deterministically fills
    // the FIFO so all 17 wr_ptr states are visited.
    begin : crv_phase
      int n_beats = 0, n_full = 0;
      int target, sends, qlen;
      logic [31:0] q [0:15];
      logic [31:0] d;
      logic        l;
      for (int r = 0; r < 12; r++) begin
        // fresh FIFO
        @(negedge clk); rst_n = 1'b0;
        repeat (3) @(posedge clk);
        @(negedge clk); rst_n = 1'b1;
        repeat (2) @(posedge clk);
        qlen   = 0;
        target = (r == 0) ? 17 : 1 + $urandom_range(0, 16);
        sends  = (target > 16) ? 16 : target;
        for (int b = 0; b < sends; b++) begin
          d = $urandom;
          l = ($urandom_range(0, 7) == 0) || (b == sends - 1);
          if (b == 15 && sends == 16) begin
            // final beat fills the FIFO: tready legitimately drops right
            // after the accepting edge, so the send() post-check (which
            // expects tready to stay high) does not apply -- drive inline
            wait (tready === 1'b1);
            @(negedge clk);
            tdata <= d; tlast <= l; tvalid <= 1'b1;
            @(posedge clk);
            @(negedge clk);
            tvalid <= 1'b0; tlast <= 1'b0;
          end else begin
            send(d, l);
          end
          q[qlen] = d; qlen++;
          n_beats++;
        end
        @(posedge clk); #1;
        if (count !== 5'(qlen)) begin
          errors++; $display("ERROR: CRV count got=%0d exp=%0d", count, qlen);
        end
        // error injection: FIFO full -> beats must be dropped
        if (qlen == 16) begin
          n_full++;
          @(negedge clk);
          tdata <= $urandom; tlast <= 1'b1; tvalid <= 1'b1;
          repeat (2) begin
            @(posedge clk); #1;
            if (tready !== 1'b0) begin
              errors++; $display("ERROR: CRV tready high while full");
            end
            if (count !== 5'd16) begin
              errors++; $display("ERROR: CRV full FIFO accepted a beat");
            end
          end
          @(negedge clk); tvalid <= 1'b0; tlast <= 1'b0;
        end
        // read-back compare of the captured contents
        for (int i = 0; i < qlen; i++) begin
          @(negedge clk); ren <= 1'b1; raddr <= i[3:0];
          #1;
          if (rdata !== q[i]) begin
            errors++;
            $display("ERROR: CRV mem[%0d] got=%h exp=%h", i, rdata, q[i]);
          end
          @(negedge clk); ren <= 1'b0;
        end
      end
      $display("CRV: 12 rounds, %0d beats, %0d full-FIFO drop injections",
               n_beats, n_full);
    end
`endif
    if (errors == 0) $display("TEST PASSED: AXI-Stream");
    else             $display("TEST FAILED: %0d errors", errors);
`ifdef VERILATOR
    begin
      int visited;
      visited = 0;
      for (int s = 0; s < AXIS_FSM_TOTAL; s++) visited += fsm_seen[s];
      $display("FSM_COV: %0d/%0d", visited, AXIS_FSM_TOTAL);
      $display("SVA_CHECKS: %0d/%0d", sva_total - sva_fail, sva_total);
    end
`endif
    $finish;
  end

`ifdef VERILATOR
  // Chunked timeout: with Verilator 5.006 a single long-pending #delay
  // event corrupts the --timing delay heap once many short-delay
  // resumptions interleave with it (processes lose wakeups and the long
  // event fires early). 1-us chunks keep all heap entries short-lived
  // (verified with a minimal repro).
  initial begin
    repeat (1000) #1000;   // 1 ms in 1-us chunks
    $display("TIMEOUT"); $finish;
  end
`else
  initial begin
    #500_000; $display("TIMEOUT"); $finish;
  end
`endif
endmodule
