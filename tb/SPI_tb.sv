// SPDX-License-Identifier: Apache-2.0
// Self-checking testbench: TB acts as SPI master (mode 0) -- SystemVerilog
`timescale 1ns/1ps
module SPI_tb;
  logic clk = 0, rst_n = 0;
  logic sclk = 0, mosi = 0, csn = 1;
  logic miso;
  logic wen = 0, ren = 0;
  logic [3:0] waddr = 0, raddr = 0;
  logic [7:0] wdata = 0, rdata;
  int errors = 0;

  SPI_top dut (
    .clk(clk), .rst_n(rst_n), .sclk(sclk), .mosi(mosi), .miso(miso),
    .csn(csn), .wen(wen), .waddr(waddr), .wdata(wdata),
    .ren(ren), .raddr(raddr), .rdata(rdata), .irq());

  always #5 clk = ~clk;

`ifdef VERILATOR
  // =====================================================================
  // v2.5 CRV instrumentation (tool build only; iverilog path unchanged)
  // SPI_top is a shift-register datapath: NO FSM present, so FSM coverage
  // is N/A (documented in docs/coverage/W6_REST.md).
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
  logic csn_q = 1'b1, irq_q = 1'b0;
  always @(posedge clk) begin
    if (!rst_n) begin
      // A1: irq low during reset
      sva_check(dut.irq === 1'b0, "A1 reset: irq low");
    end else begin
      // A2: rdata has no X/Z once out of reset
      sva_check(!$isunknown(rdata), "A2 rdata never X/Z");
      // A3: raddr==1 always reads back the TX register
      sva_check((raddr != 4'd1) || (rdata === dut.tx_q), "A3 raddr1 reads tx_q");
      // A4: irq is a single-cycle pulse
      sva_check(!(dut.irq && irq_q), "A4 irq single-cycle pulse");
      // A5: bit counter cleared one cycle after csn deasserts
      sva_check(!csn_q || (dut.bit_cnt == 3'd0), "A5 bit_cnt clear under csn");
      // A6: MISO always reflects the current TX-register bit
      sva_check(miso === dut.tx_q[7 - dut.bit_cnt], "A6 miso bit select");
      // A7: illegal read addresses return zero
      sva_check((raddr <= 4'd1) || (rdata === 8'h00), "A7 illegal addr reads 0");
    end
    csn_q <= csn;
    irq_q <= dut.irq;
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

  task automatic spi_xfer(input logic [7:0] din, output logic [7:0] dout);
    begin
      csn = 1'b0;
      for (int i = 0; i < 8; i++) begin
        mosi = din[7-i];
        #40 sclk = 1'b1;
        #1 dout[7-i] = miso;
        #39 sclk = 1'b0;
      end
      csn = 1'b1;
      #80;
    end
  endtask

  logic [7:0] d1, d2, got;
  initial begin
    rst_n = 0; repeat(5) @(posedge clk);
    rst_n = 1; repeat(5) @(posedge clk);

    wr(4'd0, 8'h3C);
    spi_xfer(8'h00, d1);
    spi_xfer(8'hA7, d2);
    rd(4'd0, got);

    if (d1 !== 8'h3C) begin errors++; $display("ERROR: SPI MISO xfer1 got=%h exp=3C", d1); end
    if (d2 !== 8'h3C) begin errors++; $display("ERROR: SPI MISO xfer2 got=%h exp=3C", d2); end
    if (got !== 8'hA7) begin errors++; $display("ERROR: SPI MOSI got=%h exp=A7", got); end

`ifdef VERILATOR
    // ---- v2.5 CRV random phase (directed tests above untouched) ----
    // 110 randomized transactions: full-duplex random frames (MISO must
    // return the loaded tx_q, MOSI must land in rx_q), mid-frame CS abort
    // error injection (partial byte discarded, next frame clean), and
    // illegal-address write/read injection.
    begin : crv_phase
      int n_xfer = 0, n_abort = 0, n_ill = 0;
      logic [7:0] tv, dv, dout_c;
      logic [3:0] ra;
      int roll;
      for (int t = 0; t < 110; t++) begin
        roll = $urandom_range(0, 9);
        tv = $urandom_range(0, 255);
        dv = $urandom_range(0, 255);
        if (roll < 1) begin
          // error injection: write/read unimplemented addresses, ignored
          n_ill++;
          ra = $urandom_range(2, 15);
          wr(ra, dv);
          rd(ra, dout_c);
          if (dout_c !== 8'h00) begin
            errors++; $display("ERROR: CRV illegal addr %0d read=%h exp=00", ra, dout_c);
          end
          rd(4'd1, dout_c);   // tx_q must be untouched by the illegal write
          spi_xfer(8'h00, dv);
          if (dv !== dout_c) begin
            errors++; $display("ERROR: CRV illegal write clobbered tx_q");
          end
        end else if (roll < 3) begin
          // error injection: mid-frame CS abort, then a clean frame
          n_abort++;
          wr(4'd0, tv);
          csn = 1'b0;
          for (int i = 0; i < $urandom_range(1, 7); i++) begin
            mosi = dv[7-i];
            #40 sclk = 1'b1;
            #40 sclk = 1'b0;
          end
          csn = 1'b1;              // abort: partial byte discarded
          #160;
          spi_xfer(dv, dout_c);    // clean frame must still work
          if (dout_c !== tv) begin
            errors++; $display("ERROR: CRV post-abort MISO got=%h exp=%h", dout_c, tv);
          end
          rd(4'd0, got);
          if (got !== dv) begin
            errors++; $display("ERROR: CRV post-abort MOSI got=%h exp=%h", got, dv);
          end
        end else begin
          // normal random full-duplex frame
          n_xfer++;
          wr(4'd0, tv);
          spi_xfer(dv, dout_c);
          if (dout_c !== tv) begin
            errors++; $display("ERROR: CRV MISO got=%h exp=%h", dout_c, tv);
          end
          rd(4'd0, got);
          if (got !== dv) begin
            errors++; $display("ERROR: CRV MOSI got=%h exp=%h", got, dv);
          end
        end
      end
      $display("CRV: 110 txns (xfer=%0d abort=%0d illegal=%0d)", n_xfer, n_abort, n_ill);
    end
`endif

    if (errors == 0) $display("TEST PASSED: SPI");
    else             $display("TEST FAILED: %0d errors", errors);
`ifdef VERILATOR
    $display("FSM_COV: N/A (no FSM: shift-register datapath)");
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
    #500_000; $display("TIMEOUT"); $finish;
  end
`endif
endmodule
