// SPDX-License-Identifier: Apache-2.0
// Self-checking testbench: GMII loopback -- SystemVerilog
`timescale 1ns/1ps
module GMII_tb;
  logic clk = 0, rst_n = 0;
  logic tx_clk = 0, rx_clk;
  logic [7:0] txd, rxd;
  logic tx_en, rx_dv;
  logic wen = 0, ren = 0;
  logic [3:0] waddr = 0, raddr = 0;
  logic [7:0] wdata = 0, rdata;
  logic [4:0] count;
  int errors = 0;

`ifdef VERILATOR
  logic rx_er_drv = 1'b0;          // CRV error-injection knob (iverilog: tied 0)
`endif
  GMII_top dut (
    .clk(clk), .rst_n(rst_n), .tx_clk(tx_clk), .txd(txd), .tx_en(tx_en),
    .tx_er(), .rx_clk(rx_clk), .rxd(rxd), .rx_dv(rx_dv),
`ifdef VERILATOR
    .rx_er(rx_er_drv),
`else
    .rx_er(1'b0),
`endif
    .wen(wen), .waddr(waddr), .wdata(wdata),
    .ren(ren), .raddr(raddr), .rdata(rdata), .count(count), .irq());

  always #5 clk = ~clk;
  always #40 tx_clk = ~tx_clk;
  assign rx_clk = tx_clk;
  assign rxd    = txd;
  assign rx_dv  = tx_en;

`ifdef VERILATOR
  // =====================================================================
  // v2.5 CRV instrumentation (Verilator only; iverilog path unchanged)
  // Tool notes (Verilator 5.006): no native FSM/SVA coverage and
  // randomize() ignores constraint blocks -> $urandom_range + rejection
  // sampling, hierarchical FSM probe, counted immediate assertions.
  // =====================================================================
  localparam int GMII_FSM_TOTAL = 2;  // TX serializer: 0=idle, 1=active (txen_q)
  logic [1:0] fsm_seen = '0;
  wire        dut_txen = dut.txen_q;  // hierarchical FSM probe

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
      // A2: tx_er is hard-tied low by the MAC
      sva_check(dut.tx_er === 1'b0, "A2 tx_er tied low");
      // A3: rx count steps by at most 1 per clk (mod-32 wrap allowed)
      sva_check(((count - count_q) & 5'h1F) <= 5'd1, "A3 count steps <=1");
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
    for (int i = 0; i < 8; i++) exp[i] = 8'h80 + i * 8'h7;
    rst_n = 0; repeat(5) @(posedge clk);
    rst_n = 1; repeat(5) @(posedge clk);

    for (int i = 0; i < 8; i++) wr(exp[i]);
    wait (count == 5'd8);
    repeat(10) @(posedge clk);
    for (int i = 0; i < 8; i++) begin
      rd(i[3:0], got);
      if (got !== exp[i]) begin
        errors++; $display("ERROR: GMII rxq[%0d] got=%h exp=%h", i, got, exp[i]);
      end
    end

`ifdef VERILATOR
    // ---- v2.5 CRV random phase (directed tests above untouched) ----
    // 120 randomized loopback bursts: random length 1..8 (txq depth cap),
    // random data with forced 00/FF corners, random read order, plus
    // rx_er error-signal injection (DUT must be unaffected: it has no
    // rx_er handling). Scoreboard: byte-stream model vs rxq read-back.
    begin : crv_phase
      logic [7:0] model [0:255];   // expected stream, index = global byte idx
      int exp_cnt = 0;             // total bytes expected in rxq so far
      int n_burst = 0, n_full = 0, n_errinj = 0, n_wa = 0;
      int nb, base, ridx;
      logic [7:0] b;
      logic [7:0] rback;
      exp_cnt = count;             // directed phase already received 8 bytes
      for (int t = 0; t < 120; t++) begin
        nb = 1 + $urandom_range(0, 7);
        if ($urandom_range(0, 9) == 0) nb = 8;        // boundary: full txq
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
        // error injection 2: assert rx_er during reception (~20% of bursts)
        if ($urandom_range(0, 9) < 2) begin
          n_errinj++;
          rx_er_drv = 1'b1;
        end
        // wait for the whole burst to land in rxq (count is mod-32)
        wait (count == (exp_cnt % 32));
        repeat(4) @(posedge clk);
        rx_er_drv = 1'b0;
        // read back in random order; burst bytes sit at rxq[(base+i)%16]
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
      end
      $display("CRV: %0d bursts (%0d full-depth, %0d rx_er-injected), %0d bytes",
               n_burst, n_full, n_errinj, exp_cnt);
    end
`endif

    if (errors == 0) $display("TEST PASSED: GMII");
    else             $display("TEST FAILED: %0d errors", errors);
`ifdef VERILATOR
    begin
      int visited;
      visited = 0;
      for (int s = 0; s < GMII_FSM_TOTAL; s++) visited += fsm_seen[s];
      $display("FSM_COV: %0d/%0d", visited, GMII_FSM_TOTAL);
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
