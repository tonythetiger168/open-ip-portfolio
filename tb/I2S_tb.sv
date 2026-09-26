// SPDX-License-Identifier: Apache-2.0
// Self-checking testbench for I2S_top: loopback SDIN=SDOUT -- SystemVerilog
`timescale 1ns/1ps
module I2S_tb;
  logic clk = 0, rst_n = 0;
  logic bclk = 0, lrck = 0;
  logic sdin, sdout;
  logic wen = 0, ren = 0;
  logic [3:0] waddr = 0, raddr = 0;
  logic [15:0] wdata = 0, rdata;
  int errors = 0;

  I2S_top dut (
    .clk(clk), .rst_n(rst_n), .bclk(bclk), .lrck(lrck),
    .sdin(sdin), .sdout(sdout),
    .wen(wen), .waddr(waddr), .wdata(wdata),
    .ren(ren), .raddr(raddr), .rdata(rdata), .irq());

  always #5 clk = ~clk;
  assign sdin = sdout;   // loopback

`ifdef VERILATOR
  // =====================================================================
  // v2.5 CRV instrumentation (Verilator only; iverilog path unchanged)
  // Tool notes (Verilator 5.006): no native FSM/SVA coverage and
  // randomize() ignores constraint blocks -> $urandom_range + rejection
  // sampling, hierarchical FSM probe, counted immediate assertions.
  // =====================================================================
  localparam int I2S_FSM_TOTAL = 2;  // channel phase: 0=left, 1=right (lrck_s)
  logic [1:0] fsm_seen = '0;
  wire        dut_lr = dut.lrck_s;   // hierarchical FSM probe

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

  // FSM coverage: sample channel phase every clock
  always @(posedge clk) fsm_seen[dut_lr] <= 1'b1;

  // output-invariant assertion suite (sampled coherently pre-NBA)
  int rst_cyc = 0;   // first reset posedge is sampled pre-NBA (regs still X)
  logic [4:0] bc_q = '0;
  always @(posedge clk) begin
    if (!rst_n) begin
      // A1: sample registers cleared in reset
      if (rst_cyc > 0)
        sva_check((dut.tx_left === 16'h0) && (dut.rx_left === 16'h0) &&
                  (dut.bit_cnt === 5'd0), "A1 reset: regs cleared");
      rst_cyc++;
    end else begin
      // A2: bit counter bounded by the 16-bit word length
      sva_check(dut.bit_cnt < 5'd16, "A2 bit_cnt < 16");
      // A3: irq is exactly the (synchronized) LRCK transition
      sva_check(dut.irq === (dut.lrck_s ^ dut.lrck_d), "A3 irq is lrck_change");
      // A4: sdout is the MSB of the TX shift register
      sva_check(sdout === dut.tx_shift[15], "A4 sdout is tx_shift MSB");
      // A5: read mux: 0->rx_left, 1->rx_right, others->0
      sva_check(rdata === ((raddr == 4'd0) ? dut.rx_left :
                           (raddr == 4'd1) ? dut.rx_right : 16'h0),
                "A5 rdata mux");
      // A6: bit_cnt steps by one, or wraps/clears on a word/LRCK boundary
      sva_check(((dut.bit_cnt - bc_q) <= 5'd1) || (dut.bit_cnt === 5'd0),
                "A6 bit_cnt step");
    end
    bc_q <= dut.bit_cnt;
  end
`endif

  task automatic wr(input logic [3:0] a, input logic [15:0] d);
    begin
      @(negedge clk); wen <= 1'b1; waddr <= a; wdata <= d;
      @(negedge clk); wen <= 1'b0;
    end
  endtask

  task automatic rd(input logic [3:0] a, output logic [15:0] d);
    begin
      @(negedge clk); ren <= 1'b1; raddr <= a;
      #1 d = rdata;
      @(negedge clk); ren <= 1'b0;
    end
  endtask

  task automatic channel(input logic lr);
    begin
      if (lrck == lr) lrck = ~lr;   // force a transition so frame-sync fires
      #600;
      lrck = lr;
      #600;
      for (int i = 0; i < 16; i++) begin
        bclk = 1; #300; bclk = 0; #300;
      end
    end
  endtask

  logic [15:0] gotL, gotR;
  initial begin
    rst_n = 0; repeat(10) @(posedge clk);
    rst_n = 1; repeat(10) @(posedge clk);

    wr(4'd0, 16'h1234);   // tx_left
    wr(4'd1, 16'hABCD);   // tx_right

    channel(1'b0);        // left frame:  shifts tx_left out, loops back in
    channel(1'b1);        // right frame: shifts tx_right out

    rd(4'd0, gotL);
    rd(4'd1, gotR);
    if (gotL !== 16'h1234) begin errors++; $display("ERROR: I2S left got=%h exp=1234", gotL); end
    if (gotR !== 16'hABCD) begin errors++; $display("ERROR: I2S right got=%h exp=ABCD", gotR); end

    // second pass: change data, verify again
    wr(4'd0, 16'h55AA);
    channel(1'b0);
    rd(4'd0, gotL);
    if (gotL !== 16'h55AA) begin errors++; $display("ERROR: I2S left2 got=%h exp=55AA", gotL); end

`ifdef VERILATOR
    // ---- v2.5 CRV random phase (directed tests above untouched) ----
    // 120 randomized loopback frames: random L/R sample data with
    // 0000/FFFF corners, random channel order. Error classes:
    // wrong-address writes (waddr>=2, must be ignored) and reads of
    // undefined raddr>=2 (must return 0).
    begin : crv_phase
      logic [15:0] dl, dr, rb;
      int n_frm = 0, n_wa = 0, n_ur = 0;
      for (int t = 0; t < 120; t++) begin
        dl = $urandom_range(0, 65535);
        dr = $urandom_range(0, 65535);
        if ($urandom_range(0, 11) == 0) dl = 16'h0000;
        if ($urandom_range(0, 11) == 0) dl = 16'hFFFF;
        if ($urandom_range(0, 11) == 0) dr = 16'h0000;
        if ($urandom_range(0, 11) == 0) dr = 16'hFFFF;
        wr(4'd0, dl);
        wr(4'd1, dr);
        // error injection 1: wrong-address write must be ignored
        if ($urandom_range(0, 9) < 3) begin
          n_wa++;
          wr($urandom_range(2, 15), $urandom_range(0, 65535));
        end
        // random channel order (both channels always exercised)
        if ($urandom_range(0, 1)) begin
          channel(1'b0); channel(1'b1);
        end else begin
          channel(1'b1); channel(1'b0);
        end
        rd(4'd0, rb);
        if (rb !== dl) begin
          errors++; $display("ERROR: CRV %0d left got=%h exp=%h", t, rb, dl);
        end
        rd(4'd1, rb);
        if (rb !== dr) begin
          errors++; $display("ERROR: CRV %0d right got=%h exp=%h", t, rb, dr);
        end
        // error injection 2: undefined read address must return 0
        if ($urandom_range(0, 9) < 3) begin
          n_ur++;
          rd($urandom_range(2, 15), rb);
          if (rb !== 16'h0000) begin
            errors++; $display("ERROR: CRV %0d undef-raddr got=%h exp=0", t, rb);
          end
        end
        n_frm++;
      end
      $display("CRV: %0d frame pairs (%0d wrong-addr wr, %0d undef-addr rd)",
               n_frm, n_wa, n_ur);
    end
`endif

    if (errors == 0) $display("TEST PASSED: I2S");
    else             $display("TEST FAILED: %0d errors", errors);
`ifdef VERILATOR
    begin
      int visited;
      visited = 0;
      for (int s = 0; s < I2S_FSM_TOTAL; s++) visited += fsm_seen[s];
      $display("FSM_COV: %0d/%0d", visited, I2S_FSM_TOTAL);
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
    #1_000_000; $display("TIMEOUT"); $finish;
  end
`endif
endmodule
