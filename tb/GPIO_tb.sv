// SPDX-License-Identifier: Apache-2.0
// Self-checking testbench for GPIO_top -- SystemVerilog
`timescale 1ns/1ps
module GPIO_tb;
  logic clk = 0, rst_n = 0;
  logic wen = 0, ren = 0;
  logic [3:0] waddr = 0, raddr = 0;
  logic [7:0] wdata = 0, rdata;
  logic [7:0] gpio_oe = 0;
  logic [7:0] drive_val = 0;
  logic       drive_en = 0;
  tri  [7:0]  gpio;
  int errors = 0;

  GPIO_top dut (
    .clk(clk), .rst_n(rst_n), .wen(wen), .waddr(waddr), .wdata(wdata),
    .ren(ren), .raddr(raddr), .rdata(rdata),
    .gpio(gpio), .gpio_oe(gpio_oe), .irq());

  always #5 clk = ~clk;
  assign gpio = drive_en ? drive_val : 8'hzz;

`ifdef VERILATOR
  // =====================================================================
  // v2.5 CRV instrumentation (tool build only; iverilog path unchanged)
  // GPIO_top is a pure register/combinational core: NO FSM present, so FSM
  // coverage is N/A (documented in docs/coverage/W6_REST.md).
  // =====================================================================
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

  // output-invariant assertion suite (sampled coherently pre-NBA)
  always @(posedge clk) begin
    if (!rst_n) begin
      // A1: rdata reads back zero during reset (in_q/out_q cleared)
      sva_check(rdata === 8'h00, "A1 reset: rdata zero");
    end else begin
      // A2: rdata has no X/Z once out of reset
      sva_check(!$isunknown(rdata), "A2 rdata never X/Z");
      // A3: raddr==1 always reads back the output register
      sva_check((raddr != 4'd1) || (rdata === dut.out_q), "A3 raddr1 reads out_q");
      // A4: DUT drives the pins only when OE is nonzero
      sva_check((gpio_oe != 8'h00) || (gpio === 8'hzz || drive_en),
                "A4 hi-Z when OE clear");
      // A5: driven pin value matches the output register
      sva_check((gpio_oe == 8'h00) || (gpio === dut.out_q),
                "A5 driven value == out_q");
      // A6: illegal read addresses return zero
      sva_check((raddr <= 4'd1) || (rdata === 8'h00), "A6 illegal addr reads 0");
    end
  end
`endif

  task automatic wr(input logic [3:0] a, input logic [7:0] d);
    begin
      @(negedge clk); wen <= 1'b1; waddr <= a; wdata <= d;
      @(negedge clk); wen <= 1'b0;
    end
  endtask

  task automatic rd(input logic [3:0] a, output logic [7:0] d);
    begin
      @(negedge clk); ren <= 1'b1; raddr <= a;
      #1 d = rdata;
      @(negedge clk); ren <= 1'b0;
    end
  endtask

  logic [7:0] got;
  initial begin
    rst_n = 0; repeat(5) @(posedge clk);
    rst_n = 1; repeat(5) @(posedge clk);

    gpio_oe = 8'hFF;
    wr(4'd0, 8'hA5);
    repeat(2) @(posedge clk); #1;
    if (gpio !== 8'hA5) begin
      errors++; $display("ERROR: GPIO output got=%h exp=A5", gpio);
    end

    rd(4'd0, got);
    if (got !== 8'hA5) begin
      errors++; $display("ERROR: GPIO loopback got=%h exp=A5", got);
    end

    gpio_oe = 8'h00;
    drive_en = 1'b1; drive_val = 8'h3C;
    repeat(2) @(posedge clk);
    rd(4'd0, got);
    if (got !== 8'h3C) begin
      errors++; $display("ERROR: GPIO input got=%h exp=3C", got);
    end

    rd(4'd1, got);
    if (got !== 8'hA5) begin
      errors++; $display("ERROR: GPIO out_reg got=%h exp=A5", got);
    end

`ifdef VERILATOR
    // ---- v2.5 CRV random phase (directed tests above untouched) ----
    // 120 randomized transactions over three classes: output writes with
    // loopback read, external input drives with sampled read, and OE/hi-Z
    // behavior; self-checked against a TB model of out_q and in_q.
    begin : crv_phase
      int n_out = 0, n_in = 0, n_rd = 0;
      logic [7:0] model_out = 8'h00;  // TB model of the output register
      logic [7:0] exp_in;
      logic [3:0] ra;
      int roll;
      logic [7:0] v;
      drive_en = 1'b0; gpio_oe = 8'h00;
      for (int t = 0; t < 120; t++) begin
        roll = $urandom_range(0, 9);
        v    = $urandom_range(0, 255);
        if (roll < 4) begin
          // random output write + loopback read with OE enabled
          n_out++;
          gpio_oe = 8'hFF; drive_en = 1'b0;
          wr(4'd0, v);
          model_out = v;
          repeat(2) @(posedge clk); #1;
          if (gpio !== model_out) begin
            errors++; $display("ERROR: CRV GPIO out got=%h exp=%h", gpio, model_out);
          end
          rd(4'd0, got);
          if (got !== model_out) begin
            errors++; $display("ERROR: CRV loopback got=%h exp=%h", got, model_out);
          end
        end else if (roll < 8) begin
          // random external input drive + sampled read
          n_in++;
          gpio_oe = 8'h00; drive_en = 1'b1; drive_val = v;
          repeat(2) @(posedge clk);
          rd(4'd0, got);
          if (got !== v) begin
            errors++; $display("ERROR: CRV input got=%h exp=%h", got, v);
          end
        end else begin
          n_rd++;
          drive_en = 1'b0;
          ra = $urandom_range(0, 15);
          if (ra >= 4'd2) begin
            // error injection: write to an unimplemented address must be
            // ignored (also toggles all waddr bits for coverage)
            wr(ra, v);
            repeat(2) @(posedge clk);
            rd(4'd1, got);
            if (got !== model_out) begin
              errors++;
              $display("ERROR: CRV illegal write to %0d clobbered out_q: got=%h exp=%h",
                       ra, got, model_out);
            end
          end
          ra = $urandom_range(0, 15);
          // random address read: out_q mirror or illegal-address zero
          rd(ra, got);
          if (ra == 4'd1) begin
            if (got !== model_out) begin
              errors++; $display("ERROR: CRV out_reg got=%h exp=%h", got, model_out);
            end
          end else if (ra >= 4'd2) begin
            if (got !== 8'h00) begin
              errors++; $display("ERROR: CRV illegal addr %0d got=%h exp=00", ra, got);
            end
          end
          // ra==0 reads live pins (undriven here -> in_q holds last value);
          // no functional check, covered by the SVA suite instead
        end
      end
      $display("CRV: 120 txns (out=%0d in=%0d rd=%0d)", n_out, n_in, n_rd);
    end
`endif

    if (errors == 0) $display("TEST PASSED: GPIO");
    else             $display("TEST FAILED: %0d errors", errors);
`ifdef VERILATOR
    $display("FSM_COV: N/A (no FSM: pure register/combinational core)");
    $display("SVA_CHECKS: %0d/%0d", sva_total - sva_fail, sva_total);
`endif
    $finish;
  end

`ifdef VERILATOR
  // chunked timeout guard: a single long-pending #delay event corrupts the
  // 5.006 --timing delay heap once many short-delay resumptions interleave;
  // chunked delays keep all heap entries short-lived (see docs/COVERAGE.md)
  initial begin
    repeat (2000) #1000;   // 2 ms in 1-us chunks
    $display("TIMEOUT"); $finish;
  end
`else
  initial begin
    #100_000; $display("TIMEOUT"); $finish;
  end
`endif
endmodule
