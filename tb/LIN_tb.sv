// SPDX-License-Identifier: Apache-2.0
// Self-checking testbench: LIN loopback (rxd = txd) -- SystemVerilog
`timescale 1ns/1ps
module LIN_tb;
  logic clk = 0, rst_n = 0;
  logic rxd, txd;
  logic wen = 0, ren = 0;
  logic [3:0] waddr = 0, raddr = 0;
  logic [7:0] wdata = 0, rdata;
  int errors = 0;
  // loopback control: default 1 keeps the directed/iverilog path identical;
  // the CRV phase breaks the loop for bit-flip error injection
  logic loop_en = 1'b1;

  LIN_top #(.BAUD_DIV(20)) dut (
    .clk(clk), .rst_n(rst_n), .rxd(rxd), .txd(txd),
    .wen(wen), .waddr(waddr), .wdata(wdata),
    .ren(ren), .raddr(raddr), .rdata(rdata), .irq());

  always #5 clk = ~clk;
  assign rxd = loop_en ? txd : ~txd;         // loopback (breakable: bit-flip injection)

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

  logic [7:0] idl, hdr, b0, b1, b2, b3, st;
  task automatic check_frame(input logic [10:0] id, input logic [3:0] dlc,
                             input logic [7:0] d0, input logic [7:0] d1,
                             input logic [7:0] d2, input logic [7:0] d3);
    begin
      wr(4'd0, id[7:0]);
      wr(4'd1, {id[10:8], 1'b0, dlc});
      wr(4'd2, d0); wr(4'd3, d1); wr(4'd4, d2); wr(4'd5, d3);
      wr(4'd10, 8'h01);
`ifdef VERILATOR
      // bounded poll: an unbounded wait() can lose its wakeup under the
      // 5.006 timing scheduler (docs/coverage/W6_REST.md mode #2)
      begin int wtd; wtd = 0;
        while (dut.rx_valid !== 1'b1 && wtd < 200000) begin @(posedge clk); wtd++; end
        if (wtd >= 200000) begin errors++; $display("ERROR: LIN rx_valid timeout"); end
      end
`else
      wait (dut.rx_valid === 1'b1);
`endif
      @(posedge clk); #1;
      rd(4'd0, idl); rd(4'd1, hdr);
      rd(4'd2, b0); rd(4'd3, b1); rd(4'd4, b2); rd(4'd5, b3);
      rd(4'd10, st);
      if ({hdr[7:5], idl} !== id) begin
        errors++; $display("ERROR: LIN id got=%h_%h exp=%h", hdr[7:5], idl, id);
      end
      if (hdr[3:0] !== dlc) begin errors++; $display("ERROR: LIN dlc got=%0d exp=%0d", hdr[3:0], dlc); end
      if (dlc >= 1 && b0 !== d0) begin errors++; $display("ERROR: LIN b0 got=%h exp=%h", b0, d0); end
      if (dlc >= 2 && b1 !== d1) begin errors++; $display("ERROR: LIN b1 got=%h exp=%h", b1, d1); end
      if (dlc >= 3 && b2 !== d2) begin errors++; $display("ERROR: LIN b2 got=%h exp=%h", b2, d2); end
      if (dlc >= 4 && b3 !== d3) begin errors++; $display("ERROR: LIN b3 got=%h exp=%h", b3, d3); end
      if (st[5] !== 1'b0) begin errors++; $display("ERROR: LIN rx_err set (st=%h)", st); end
      repeat (50) @(posedge clk);          // inter-frame gap
    end
  endtask

`ifdef VERILATOR
  // =====================================================================
  // v2.5 CRV instrumentation (tool build only; iverilog path unchanged)
  // FSMs probed: dut.tstate (TX_IDLE..TX_EOF) + dut.rstate
  // (RX_IDLE..RX_EOF), 16 states total.
  // =====================================================================
  localparam int LIN_FSM_TOTAL = 16;  // 8 TX + 8 RX states
  logic [7:0] fsm_seen_t = '0;        // visited TX-state bitmap
  logic [7:0] fsm_seen_r = '0;        // visited RX-state bitmap
  wire  [3:0] dut_tstate = dut.tstate;
  wire  [3:0] dut_rstate = dut.rstate;

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

  // FSM coverage: sample DUT state registers on both edges (scheduler
  // failure mode #3 mitigation: dual-edge probe tolerates lost wakeups)
  always @(posedge clk or negedge clk) begin
    fsm_seen_t[dut_tstate[2:0]] <= 1'b1;
    fsm_seen_r[dut_rstate[2:0]] <= 1'b1;
  end

  // output-invariant assertion suite (level/comb checks, negedge-sampled
  // so all NBA updates are settled; no history-dependent properties)
  logic rst_n_q = 1'b1;
  always @(negedge clk) begin
    if (!rst_n) begin
      // A1: outputs quiescent during reset (one cycle for regs to init)
      if (!rst_n_q)
        sva_check(txd === 1'b1 && dut.irq === 1'b0,
                  "A1 reset: bus recessive, irq low");
    end else begin
      // A2: txd is exactly can_out overridden by the ACK drive
      sva_check(txd === (dut.can_out & ~dut.ack_drive), "A2 txd == can_out & ~ack");
      // A3: irq mirrors the rx_valid pulse
      sva_check(dut.irq === dut.rx_valid, "A3 irq == rx_valid");
      // A4: TX FSM never takes an encoding above TX_EOF
      sva_check(dut_tstate <= 4'd7, "A4 tstate legal encoding");
      // A5: RX FSM never takes an encoding above RX_EOF
      sva_check(dut_rstate <= 4'd7, "A5 rstate legal encoding");
      // A6: TX stuff-run counter bounded by the 5-bit stuff rule
      sva_check(dut.run_cnt <= 4'd5, "A6 run_cnt <= 5");
      // A7: RX de-stuff run counter bounded by the 5-bit stuff rule
      sva_check(dut.rx_run <= 4'd5, "A7 rx_run <= 5");
      // A8: tx_busy exactly reflects non-idle of the TX FSM
      sva_check(dut.tx_busy === (dut_tstate != 4'd0), "A8 tx_busy == !TX_IDLE");
    end
    rst_n_q <= rst_n;
  end
`endif

  initial begin
    rst_n = 0; repeat(10) @(posedge clk);
    rst_n = 1; repeat(20) @(posedge clk);

    check_frame(11'h1AB, 4'd4, 8'h55, 8'hAA, 8'h0F, 8'hF0);  // stuffing-heavy
    check_frame(11'h055, 4'd0, 8'h00, 8'h00, 8'h00, 8'h00);  // dataless
    check_frame(11'h7FF, 4'd2, 8'hFF, 8'hFF, 8'h00, 8'h00);  // worst-case stuff

`ifdef VERILATOR
    // ---- v2.5 CRV random phase (directed tests above untouched) ----
    // 120 frames through the register interface, LIN loopback:
    //   100 good: random 11-bit id, dlc 0..8 (every 7th: misuse dlc 9..15,
    //   both ends wrap dlc[2:0] consistently), random data, all-zero/all-one
    //   stuffing-boundary content, illegal-address reads (expect 8'h00);
    //   10 bit-flip injections (loop broken for one 40-clk bit cell in the
    //   data phase): rx_err must set, rx_valid must not fire;
    //   10 more good frames to prove recovery after sticky rx_err.
    // Fully inlined (no timing-task coroutine chains); all waits bounded.
    begin : crv_phase
      int n_good = 0, n_misuse = 0, n_inj = 0, n_rec = 0;
      int wt;
      logic [10:0] id_v;
      logic [3:0]  dlc_v;
      logic [7:0]  dat [0:7];
      logic [7:0]  rb_v, hdr_v, idl_v, st_v, ill_v;
      int          ndata;
      for (int t = 0; t < 120; t++) begin
        id_v  = $urandom_range(0, 11'h7FF);
        if (t < 100 || t >= 110) begin
          dlc_v = (t % 7 == 3) ? $urandom_range(9, 15) : $urandom_range(0, 8);
        end else begin
          dlc_v = 4'd8;                            // injection frames: full data
        end
        for (int i = 0; i < 8; i++) dat[i] = $urandom_range(0, 255);
        if (t % 13 == 0) for (int i = 0; i < 8; i++) dat[i] = 8'h00;
        if (t % 17 == 0) for (int i = 0; i < 8; i++) dat[i] = 8'hFF;
        // ---- program TX registers (negedge drives, same as wr task) ----
        @(negedge clk); wen <= 1; waddr <= 4'd0; wdata <= id_v[7:0];
        @(negedge clk); wen <= 0;
        @(negedge clk); wen <= 1; waddr <= 4'd1; wdata <= {id_v[10:8], 1'b0, dlc_v};
        @(negedge clk); wen <= 0;
        for (int i = 0; i < 8; i++) begin
          @(negedge clk); wen <= 1; waddr <= 4'd2 + i[3:0]; wdata <= dat[i];
          @(negedge clk); wen <= 0;
        end
        @(negedge clk); wen <= 1; waddr <= 4'd10; wdata <= 8'h01;
        @(negedge clk); wen <= 0;
        if (t >= 100 && t < 110) begin
          // ---- bit-flip injection in the data phase (~bit 60 of frame) ----
          repeat (2400) @(posedge clk);
          @(negedge clk); loop_en = 1'b0;   // rxd = ~txd: live inversion
          repeat (40) @(posedge clk);       // covers >= 1 RX sample point
          @(negedge clk); loop_en = 1'b1;
          // frame completes with a CRC error: no rx_valid; wait for TX done
          wt = 0;
          while (dut.tx_busy !== 1'b0 && wt < 200000) begin @(posedge clk); wt++; end
          repeat (200) @(posedge clk);             // RX drains through EOF
          if (dut.rx_valid === 1'b1) begin
            errors++; $display("ERROR: CRV rx_valid after bit-flip t=%0d", t);
          end
          @(negedge clk); ren <= 1; raddr <= 4'd10;
          #1 st_v = rdata;
          @(negedge clk); ren <= 0;
          if (st_v[5] !== 1'b1) begin
            errors++; $display("ERROR: CRV rx_err not set after bit-flip t=%0d st=%h", t, st_v);
          end
          n_inj++;
        end else begin
          // ---- wait for looped-back frame (bounded) ----
          wt = 0;
          while (dut.rx_valid !== 1'b1 && wt < 200000) begin @(posedge clk); wt++; end
          if (wt >= 200000) begin
            errors++;
            $display("ERROR: CRV rx_valid timeout t=%0d tstate=%0d rstate=%0d",
                     t, dut_tstate, dut_rstate);
          end
          @(posedge clk); #1;
          // ---- read back ID/DLC/data/status + one illegal address ----
          @(negedge clk); ren <= 1; raddr <= 4'd0;
          #1 idl_v = rdata;
          @(negedge clk); raddr <= 4'd1;
          #1 hdr_v = rdata;
          @(negedge clk); ren <= 0;
          ndata = dlc_v[2:0] == 3'd0 ? (dlc_v == 4'd8 ? 8 : 0) : dlc_v[2:0];
          for (int i = 0; i < 8; i++) begin
            @(negedge clk); ren <= 1; raddr <= 4'd2 + i[3:0];
            #1 rb_v = rdata;
            @(negedge clk); ren <= 0;
            if (i < ndata && rb_v !== dat[i]) begin
              errors++;
              $display("ERROR: CRV data t=%0d i=%0d got=%h exp=%h", t, i, rb_v, dat[i]);
            end
          end
          @(negedge clk); ren <= 1; raddr <= 4'd10;
          #1 st_v = rdata;
          @(negedge clk); raddr <= 4'd11 + (t % 5);
          #1 ill_v = rdata;
          @(negedge clk); ren <= 0;
          if ({hdr_v[7:5], idl_v} !== id_v) begin
            errors++; $display("ERROR: CRV id t=%0d got=%h_%h exp=%h", t, hdr_v[7:5], idl_v, id_v);
          end
          if (hdr_v[3:0] !== dlc_v) begin
            errors++; $display("ERROR: CRV dlc t=%0d got=%0d exp=%0d", t, hdr_v[3:0], dlc_v);
          end
          if (st_v[5] !== 1'b0) begin
            errors++; $display("ERROR: CRV rx_err set on good frame t=%0d st=%h", t, st_v);
          end
          if (ill_v !== 8'h00) begin
            errors++; $display("ERROR: CRV illegal raddr read t=%0d got=%h exp=00", t, ill_v);
          end
          if (dlc_v > 4'd8) n_misuse++; else n_good++;
          if (t >= 110) n_rec++;
          repeat (50) @(posedge clk);              // inter-frame gap
        end
      end
      $display("CRV: 120 frames (good=%0d misuse_dlc=%0d bitflip=%0d recovery=%0d)",
               n_good - n_rec, n_misuse, n_inj, n_rec);
    end
`endif

    if (errors == 0) $display("TEST PASSED: LIN");
    else             $display("TEST FAILED: %0d errors", errors);
`ifdef VERILATOR
    begin
      int visited;
      visited = 0;
      for (int s = 0; s < 8; s++) visited += fsm_seen_t[s] + fsm_seen_r[s];
      $display("FSM_COV: %0d/%0d", visited, LIN_FSM_TOTAL);
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
    repeat (40000) #1000;   // 40 ms in 1-us chunks
    $display("TIMEOUT"); $finish;
  end
`else
  initial begin
    #8_000_000; $display("TIMEOUT"); $finish;
  end
`endif
endmodule
