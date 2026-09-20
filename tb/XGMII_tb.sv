// SPDX-License-Identifier: Apache-2.0
// Self-checking testbench: XGMII loopback -- SystemVerilog
`timescale 1ns/1ps
module XGMII_tb;
  logic clk = 0, rst_n = 0;
  logic tx_clk = 0, rx_clk;
  logic [31:0] txd, rxd;
  logic [3:0] txc, rxc;
  logic wen = 0, ren = 0;
  logic [3:0] waddr = 0, raddr = 0;
  logic [7:0] wdata = 0, rdata;
  logic [4:0] count;
  int errors = 0;

  XGMII_top dut (
    .clk(clk), .rst_n(rst_n), .tx_clk(tx_clk), .txd(txd), .txc(txc),
    .rx_clk(rx_clk), .rxd(rxd), .rxc(rxc),
    .wen(wen), .waddr(waddr), .wdata(wdata),
    .ren(ren), .raddr(raddr), .rdata(rdata), .count(count), .irq());

  always #5 clk = ~clk;
  always #40 tx_clk = ~tx_clk;
  assign rx_clk = tx_clk;
  assign rxd    = txd;
`ifdef VERILATOR
  logic       rxc_ovr = 1'b0;          // CRV error-injection knob (control col)
  assign rxc = rxc_ovr ? 4'hF : txc;
`else
  assign rxc    = txc;
`endif

`ifdef VERILATOR
  // =====================================================================
  // v2.5 CRV instrumentation (Verilator only; iverilog path unchanged)
  // Tool notes (Verilator 5.006): no native FSM/SVA coverage and
  // randomize() ignores constraint blocks -> $urandom_range + rejection
  // sampling, hierarchical FSM probe, counted immediate assertions.
  // =====================================================================
  localparam int XGMII_FSM_TOTAL = 2;  // TX serializer: 0=idle, 1=active (txen_q)
  logic [1:0] fsm_seen = '0;
  wire        dut_txen = dut.txen_q;   // hierarchical FSM probe

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

  // FSM coverage: sample TX serializer state every clock
  always @(posedge clk) fsm_seen[dut_txen] <= 1'b1;

  // output-invariant assertion suite (sampled coherently pre-NBA)
  logic [4:0] count_q = '0;
  int rst_cyc = 0;   // first reset posedge is sampled pre-NBA (regs still X)
  always @(posedge clk) begin
    if (!rst_n) begin
      // A1: rx byte count cleared in reset
      if (rst_cyc > 0) sva_check(count === 5'd0, "A1 reset: count cleared");
      rst_cyc++;
    end else begin
      // A2: data beat (txc==0) exactly when the TX serializer is active
      sva_check((txc === 4'h0) == (dut_txen === 1'b1), "A2 txc matches txen");
      // A3: rx count steps by at most 4 per clk (one word, mod-32 wrap)
      sva_check(((count - count_q) & 5'h1F) <= 5'd4, "A3 count steps <=4");
      // A4: irq only while reading a non-empty rx queue
      sva_check(!dut.irq || (ren && (count != 5'd0)), "A4 irq implies ren & data");
      // A5: read port is a structural rxq mux
      sva_check(rdata === dut.rxq[raddr[3:0]], "A5 rdata is rxq[raddr]");
      // A6: count is the raw rx write pointer
      sva_check(count === dut.rx_wr, "A6 count is rx_wr");
    end
    count_q <= count;
  end
`endif

  task automatic wr(input logic [7:0] d);
    begin
      @(negedge clk); wen <= 1'b1; waddr <= 4'd0; wdata <= d;
      @(negedge clk); wen <= 1'b0;
    end
  endtask
`ifdef VERILATOR
  // CRV-only: write to an arbitrary address (non-0 writes must be ignored)
  task automatic wr_a(input logic [3:0] a, input logic [7:0] d);
    begin
      @(negedge clk); wen <= 1'b1; waddr <= a; wdata <= d;
      @(negedge clk); wen <= 1'b0;
    end
  endtask
`endif
  task automatic rd(input logic [3:0] a, output logic [7:0] d);
    begin
      @(negedge clk); ren <= 1'b1; raddr <= a;
      #1 d = rdata;
      @(negedge clk); ren <= 1'b0;
    end
  endtask

  logic [7:0] got;
  logic [7:0] exp [0:7];
  initial begin
    for (int i = 0; i < 8; i++) exp[i] = 8'h5A + i * 8'h9;
    rst_n = 0; repeat(5) @(posedge clk);
    rst_n = 1; repeat(5) @(posedge clk);

    for (int i = 0; i < 8; i++) wr(exp[i]);
    wait (count == 5'd8);
    repeat(10) @(posedge clk);
    for (int i = 0; i < 8; i++) begin
      rd(i[3:0], got);
      if (got !== exp[i]) begin
        errors++; $display("ERROR: XGMII rxq[%0d] got=%h exp=%h", i, got, exp[i]);
      end
    end

`ifdef VERILATOR
    // ---- v2.5 CRV random phase (directed tests above untouched) ----
    // 120 randomized loopback bursts: 4 or 8 bytes (TX emits whole 32-bit
    // words only; txq is 8 deep), random data with 00/FF corners, random
    // read order, plus two error classes: wrong-address writes (must be
    // ignored) and a "poison word" whose rxc is forced to all-control
    // (the 4-byte word must be dropped, stream realigns afterwards).
    // Scoreboard: byte-stream model vs rxq read-back.
    begin : crv_phase
      logic [7:0] model [0:255];   // expected stream, index = global byte idx
      int exp_cnt;                 // total bytes expected in rxq so far
      int n_burst = 0, n_full = 0, n_wa = 0, n_drop = 0;
      int nb, base, ridx;
      logic [7:0] b;
      logic [7:0] rback;
      exp_cnt = count;             // directed phase already received 8 bytes
      for (int t = 0; t < 120; t++) begin
        nb = ($urandom_range(0, 9) == 0) ? 8 : 4;     // boundary: full txq
        if (nb == 8) n_full++;
        base = exp_cnt;
        for (int i = 0; i < nb; i++) begin
          b = $urandom_range(0, 255);
          if ($urandom_range(0, 15) == 0) b = 8'h00;  // corner data
          if ($urandom_range(0, 15) == 0) b = 8'hFF;
          wr(b);
          model[(base + i) % 256] = b;
        end
        exp_cnt = base + nb;
        // error injection 1: writes to non-data addresses must be ignored
        if ($urandom_range(0, 9) < 3) begin
          n_wa++;
          wr_a($urandom_range(1, 15), $urandom_range(0, 255));
        end
        // wait for the whole burst to land in rxq (count is mod-32)
        wait (count == (exp_cnt % 32));
        repeat(4) @(posedge clk);
        // no spurious/lost bytes (catches wrong-address enqueues)
        if (count !== (exp_cnt % 32)) begin
          errors++;
          $display("ERROR: CRV burst %0d count=%0d exp=%0d", t, count, exp_cnt % 32);
        end
        // read back in random order; received bytes sit at rxq[(base+i)%16]
        for (int i = 0; i < nb; i++) begin
          ridx = $urandom_range(0, nb - 1);
          rd(((base + ridx) % 16), rback);
          if (rback !== model[(base + ridx) % 256]) begin
            errors++;
            $display("ERROR: CRV burst %0d idx %0d got=%h exp=%h",
                     t, ridx, rback, model[(base + ridx) % 256]);
          end
        end
        n_burst++;
        // error injection 2 (~20%): standalone poison word, rxc forced to
        // all-control for its whole beat -> word must be dropped. Armed
        // while the link is idle, fixed window = race-free.
        if ($urandom_range(0, 9) < 2) begin
          n_drop++;
          for (int i = 0; i < 4; i++) wr($urandom_range(0, 255));
          rxc_ovr = 1'b1;          // armed before the word's beat
          #220 rxc_ovr = 1'b0;     // covers worst-case TX start + one beat
          repeat(6) @(posedge clk);
          if (count !== (exp_cnt % 32)) begin
            errors++;
            $display("ERROR: CRV burst %0d poison word received (count=%0d exp=%0d)",
                     t, count, exp_cnt % 32);
          end
        end
      end
      $display("CRV: %0d bursts (%0d full-depth, %0d wrong-addr, %0d word-drop), %0d bytes",
               n_burst, n_full, n_wa, n_drop, exp_cnt);
    end
`endif

    if (errors == 0) $display("TEST PASSED: XGMII");
    else             $display("TEST FAILED: %0d errors", errors);
`ifdef VERILATOR
    begin
      int visited;
      visited = 0;
      for (int s = 0; s < XGMII_FSM_TOTAL; s++) visited += fsm_seen[s];
      $display("FSM_COV: %0d/%0d", visited, XGMII_FSM_TOTAL);
      $display("SVA_CHECKS: %0d/%0d", sva_total - sva_fail, sva_total);
    end
`endif
    $finish;
  end

`ifdef VERILATOR
  // Random phase adds bus traffic: extend the guard. Chunked into 1-us
  // delays: with Verilator 5.006 a single long-pending #delay event
  // corrupts the --timing delay heap once many short-delay resumptions
  // interleave (processes lose wakeups, long event fires early).
  initial begin
    repeat (20000) #1000;   // 20 ms in 1-us chunks
    $display("TIMEOUT"); $finish;
  end
`else
  initial begin
    #2_000_000; $display("TIMEOUT"); $finish;
  end
`endif
endmodule
