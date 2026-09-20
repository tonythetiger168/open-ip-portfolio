// SPDX-License-Identifier: Apache-2.0
// Self-checking testbench for ATB_top -- SystemVerilog
`timescale 1ns/1ps
module ATB_tb;
  logic clk = 0, rst_n = 0;
  logic atvalid = 0, atready;
  logic [31:0] atdata = 0;
  logic [6:0] atid = 0;
  logic atlast = 0;
  logic afvalid = 0, afready;
  logic ren = 0;
  logic [3:0] raddr = 0;
  logic [31:0] rdata;
  logic [4:0] count;
  logic [6:0] last_id;
  logic irq;
  logic irq_seen = 0;
  int errors = 0;

  ATB_top dut (
    .clk(clk), .rst_n(rst_n), .atvalid(atvalid), .atready(atready),
    .atdata(atdata), .atid(atid), .atlast(atlast),
    .afvalid(afvalid), .afready(afready),
    .ren(ren), .raddr(raddr), .rdata(rdata), .count(count),
    .last_id(last_id), .irq(irq));

  always #5 clk = ~clk;
  always @(posedge clk) if (irq) irq_seen <= 1'b1;

  task automatic send(input logic [31:0] d, input logic [6:0] id, input logic last);
    begin
      wait (atready === 1'b1);
      @(negedge clk);
      atdata <= d; atid <= id; atlast <= last; atvalid <= 1'b1;
      @(posedge clk); #1;
      @(negedge clk);
      atvalid <= 1'b0; atlast <= 1'b0;
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
  localparam int ATB_FSM_TOTAL = 17;  // wr_ptr values 0..16 (DEPTH=16)
  logic [16:0] fsm_seen = '0;         // visited-state bitmap
  wire  [4:0]  dut_wrptr = dut.wr_ptr;  // hierarchical probe

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
  logic       p_atready = 0;
  always @(posedge clk) begin
    if (!rst_n) begin
      // A1: FIFO empty during reset
      sva_check(count === 5'd0, "A1 reset: count zero");
    end else begin
      // A2: count never exceeds DEPTH
      sva_check(count <= 5'd16, "A2 count within depth");
      // A3: atready reflects FIFO-not-full exactly
      sva_check(atready === (count < 5'd16), "A3 atready == not full");
      // A4: irq only on an accepted atlast beat
      sva_check(!irq || (atvalid && atready && atlast),
                "A4 irq == push&atlast");
      // A5: count steps by +1 (push) or clears to 0 (flush/reset)
      sva_check((count === p_count) || (count === p_count + 5'd1) ||
                (count === 5'd0), "A5 count +1 or flush-to-0");
      // A6: flush engine always ready
      sva_check(afready === 1'b1, "A6 afready constant high");
      // A7: while full, only a flush changes the count
      sva_check(p_atready || (count === p_count) || (count === 5'd0),
                "A7 full: only flush changes count");
    end
    p_count   <= count;
    p_atready <= atready;
  end
`endif

  logic [31:0] exp [0:3];
  initial begin
    exp[0] = 32'hDEAD_BEEF; exp[1] = 32'h1234_5678;
    exp[2] = 32'hCAFE_F00D; exp[3] = 32'h0BAD_C0DE;
    rst_n = 0; repeat(5) @(posedge clk);
    rst_n = 1; repeat(5) @(posedge clk);

    // first trace burst, id=0x12
    for (int i = 0; i < 4; i++) send(exp[i], 7'h12, i == 3);
    repeat(2) @(posedge clk);
    if (count !== 5'd4) begin errors++; $display("ERROR: ATB count=%0d exp=4", count); end
    if (!irq_seen) begin errors++; $display("ERROR: ATB irq never fired"); end
    if (last_id !== 7'h12) begin errors++; $display("ERROR: ATB last_id=%h", last_id); end
    for (int i = 0; i < 4; i++) begin
      @(negedge clk); ren <= 1'b1; raddr <= i[3:0];
      #1;
      if (rdata !== exp[i]) begin errors++; $display("ERROR: ATB mem[%0d] got=%h exp=%h", i, rdata, exp[i]); end
      @(negedge clk); ren <= 1'b0;
    end

    // flush with new id -> FIFO empties
    @(negedge clk); afvalid <= 1'b1; atid <= 7'h34;
    @(posedge clk); #1;
    @(negedge clk); afvalid <= 1'b0;
    repeat(2) @(posedge clk);
    if (count !== 5'd0) begin errors++; $display("ERROR: ATB flush count=%0d exp=0", count); end

`ifdef VERILATOR
    // ---- v2.5 CRV random phase (directed test above untouched) -------
    // 12 rounds; each round re-resets, pushes a random number of
    // random-data beats with random atlast, then either reads back and
    // compares the captured contents or issues an AFVALID flush with a
    // new ID (FIFO must empty). Round 0 deterministically fills the FIFO
    // (all 17 wr_ptr states) and adds full-FIFO drop injection.
    begin : crv_phase
      int n_beats = 0, n_flush = 0, n_full = 0;
      int target, sends, qlen;
      logic [31:0] q [0:15];
      logic [31:0] d;
      logic [6:0]  cid, nid;
      logic        l, l_seen;
      for (int r = 0; r < 12; r++) begin
        // fresh FIFO + fresh capture ID
        @(negedge clk); rst_n = 1'b0;
        repeat (3) @(posedge clk);
        @(negedge clk); rst_n = 1'b1;
        repeat (2) @(posedge clk);
        qlen = 0; l_seen = 0;
        cid = $urandom_range(0, 127);
        target = (r == 0) ? 17 : 1 + $urandom_range(0, 16);
        sends  = (target > 16) ? 16 : target;
        for (int b = 0; b < sends; b++) begin
          d = $urandom;
          l = ($urandom_range(0, 7) == 0) || (b == sends - 1);
          send(d, cid, l);
          q[qlen] = d; qlen++;
          n_beats++;
          if (l) l_seen = 1;
        end
        @(posedge clk); #1;
        if (count !== 5'(qlen)) begin
          errors++; $display("ERROR: CRV count got=%0d exp=%0d", count, qlen);
        end
        if (l_seen && (last_id !== cid)) begin
          errors++; $display("ERROR: CRV last_id got=%h exp=%h", last_id, cid);
        end
        // error injection: FIFO full -> beats must be dropped
        if (qlen == 16) begin
          n_full++;
          @(negedge clk);
          atdata <= $urandom; atid <= cid; atlast <= 1'b1; atvalid <= 1'b1;
          repeat (2) begin
            @(posedge clk); #1;
            if (atready !== 1'b0) begin
              errors++; $display("ERROR: CRV atready high while full");
            end
            if (count !== 5'd16) begin
              errors++; $display("ERROR: CRV full FIFO accepted a beat");
            end
          end
          @(negedge clk); atvalid <= 1'b0; atlast <= 1'b0;
        end
        if ($urandom_range(0, 1)) begin
          // flush with a new ID: FIFO must empty. The DUT capture ID
          // (cur_id) is 0 after this round's reset, so the flush ID must
          // be nonzero to trigger id_change (rejection sampling).
          n_flush++;
          nid = $urandom_range(1, 127);
          @(negedge clk); afvalid <= 1'b1; atid <= nid;
          @(posedge clk); #1;
          @(negedge clk); afvalid <= 1'b0;
          repeat (2) @(posedge clk);
          if (count !== 5'd0) begin
            errors++; $display("ERROR: CRV flush count=%0d exp=0", count);
          end
        end else begin
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
      end
      $display("CRV: 12 rounds, %0d beats, %0d flushes, %0d full drops",
               n_beats, n_flush, n_full);
    end
`endif
    if (errors == 0) $display("TEST PASSED: ATB");
    else             $display("TEST FAILED: %0d errors", errors);
`ifdef VERILATOR
    begin
      int visited;
      visited = 0;
      for (int s = 0; s < ATB_FSM_TOTAL; s++) visited += fsm_seen[s];
      $display("FSM_COV: %0d/%0d", visited, ATB_FSM_TOTAL);
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
