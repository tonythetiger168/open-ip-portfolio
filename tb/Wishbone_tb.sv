// SPDX-License-Identifier: Apache-2.0
// ============================================================================
// Self-checking testbench for Wishbone_top (Wishbone B4 pipelined slave)
// TB acts as a Wishbone master model: classic + pipelined cycles, SEL merge,
// stall backpressure observance, reserved-region error injection.
// ============================================================================
`timescale 1ns/1ps
module Wishbone_tb;
  localparam int DW = 32, AW = 32;

  logic clk = 0, rst_n = 0;
  logic          cyc_i, stb_i, we_i;
  logic [AW-1:0] adr_i;
  logic [DW-1:0] dat_i;
  logic [3:0]    sel_i;
  logic [2:0]    cti_i;
  logic [DW-1:0] dat_o;
  logic          ack_o, stall_o, err_o, rty_o, irq;

  int errors = 0;

  Wishbone_top #(.DW(DW), .AW(AW)) dut (
    .clk(clk), .rst_n(rst_n),
    .cyc_i(cyc_i), .stb_i(stb_i), .we_i(we_i), .adr_i(adr_i),
    .dat_i(dat_i), .sel_i(sel_i), .cti_i(cti_i),
    .dat_o(dat_o), .ack_o(ack_o), .stall_o(stall_o),
    .err_o(err_o), .rty_o(rty_o), .irq(irq)
  );

  always #5 clk = ~clk;

`ifdef VERILATOR
  // =====================================================================
  // v2.5 CRV instrumentation (tool build only; iverilog path unchanged)
  // FSM probed: dut.state (S_IDLE/S_WAIT/S_RESP), 3 states.
  // =====================================================================
  localparam int WB_FSM_TOTAL = 3;
  logic [2:0] fsm_seen = '0;          // visited-state bitmap
  wire  [1:0] dut_state = dut.state;

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

  // FSM coverage: sample DUT state register on both edges (scheduler
  // failure mode #3 mitigation: dual-edge probe tolerates lost wakeups)
  always @(posedge clk or negedge clk) fsm_seen[dut_state] <= 1'b1;

  // output-invariant assertion suite (level/comb checks, negedge-sampled
  // so all NBA updates are settled; no history-dependent properties)
  logic rst_n_q = 1'b1;
  always @(negedge clk) begin
    if (!rst_n) begin
      // A1: outputs quiescent during reset (one cycle for regs to init)
      if (!rst_n_q)
        sva_check(ack_o === 1'b0 && err_o === 1'b0 && irq === 1'b0 &&
                  stall_o === 1'b0, "A1 reset: outputs quiescent");
    end else begin
      // A2: stall_o exactly reflects a full 2-deep queue
      sva_check(stall_o === (dut.q_count == 2'd2), "A2 stall == queue full");
      // A3: ack and err never assert together
      sva_check(!(ack_o && err_o), "A3 ack/err exclusive");
      // A4: rty_o is tied off (this slave never requests retry)
      sva_check(rty_o === 1'b0, "A4 rty tied off");
      // A5: service FSM holds a legal encoding (3 of 4 used)
      sva_check(dut_state <= 2'd2, "A5 state legal");
      // A6: dat_o always reflects the queue head read mux
      sva_check(dat_o === ((dut.q_ok[0] && !dut.q_we[0]) ?
                           dut.mem[dut.q_idx[0]] : 32'h0), "A6 dat_o mux");
    end
    rst_n_q <= rst_n;
  end
`endif

  // ------------------------------------------------------------------
  // in-order response scoreboard
  // ------------------------------------------------------------------
  logic [31:0] exp_data [0:511];
  bit          exp_err  [0:511];
  bit          exp_is_rd[0:511];
  int exp_wr = 0, exp_rd = 0;
  int stall_seen = 0;

  always @(posedge clk) begin
    if (stall_o) stall_seen++;
    if (ack_o || err_o) begin
      if (exp_rd >= exp_wr) begin
        errors++; $display("ERROR: unexpected response ack=%b err=%b @%0t", ack_o, err_o, $time);
      end else begin
        if (exp_err[exp_rd] && !err_o) begin
          errors++; $display("ERROR: expected err_o, got ack_o (resp %0d)", exp_rd);
        end
        if (!exp_err[exp_rd] && !ack_o) begin
          errors++; $display("ERROR: expected ack_o, got err_o (resp %0d)", exp_rd);
        end
        if (!exp_err[exp_rd] && exp_is_rd[exp_rd] && dat_o !== exp_data[exp_rd]) begin
          errors++; $display("ERROR: read data mismatch resp %0d exp %h got %h",
                             exp_rd, exp_data[exp_rd], dat_o);
        end
        exp_rd++;
      end
    end
  end

  // ------------------------------------------------------------------
  // master-model tasks (drive on negedge, hold while stall_o)
  // ------------------------------------------------------------------
  task automatic wb_idle;
    begin
      @(negedge clk);
      cyc_i <= 1'b0; stb_i <= 1'b0; we_i <= 1'b0; cti_i <= 3'b000;
    end
  endtask

  // issue one pipelined beat (does not wait for response)
  task automatic wb_issue(input logic [AW-1:0] a, input logic [DW-1:0] d,
                          input logic [3:0] s, input logic wr);
    int to;
    begin
      @(negedge clk);
      cyc_i <= 1'b1; stb_i <= 1'b1; we_i <= wr;
      adr_i <= a; dat_i <= d; sel_i <= s; cti_i <= 3'b010; // incrementing burst
      to = 0;
      // wait until the beat is accepted (stall_o low at a posedge)
      while (to < 50) begin
        @(posedge clk);
        if (!stall_o) to = 100;
        else to++;
      end
      if (to != 100) begin errors++; $display("ERROR: stall timeout @%h", a); end
    end
  endtask

  // classic single write, waits for its ack (scoreboard checks data path)
  task automatic wb_write(input logic [AW-1:0] a, input logic [DW-1:0] d,
                          input logic [3:0] s);
    int to;
    begin
      @(negedge clk);
      cyc_i <= 1'b1; stb_i <= 1'b1; we_i <= 1'b1;
      adr_i <= a; dat_i <= d; sel_i <= s; cti_i <= 3'b000;
      exp_err[exp_wr] = 1'b0; exp_is_rd[exp_wr] = 1'b0; exp_data[exp_wr] = 32'h0; exp_wr++;
      to = 0;
      while (to < 50) begin
        @(posedge clk);
        if (ack_o) to = 100;
        else to++;
      end
      if (to != 100) begin errors++; $display("ERROR: write ack timeout @%h", a); end
      wb_idle();
    end
  endtask

  // classic single read, data checked by scoreboard
  task automatic wb_read(input logic [AW-1:0] a, input logic [DW-1:0] exp);
    int to;
    begin
      @(negedge clk);
      cyc_i <= 1'b1; stb_i <= 1'b1; we_i <= 1'b0;
      adr_i <= a; dat_i <= '0; sel_i <= 4'hF; cti_i <= 3'b000;
      exp_err[exp_wr] = 1'b0; exp_is_rd[exp_wr] = 1'b1; exp_data[exp_wr] = exp; exp_wr++;
      to = 0;
      while (to < 50) begin
        @(posedge clk);
        if (ack_o) to = 100;
        else to++;
      end
      if (to != 100) begin errors++; $display("ERROR: read ack timeout @%h", a); end
      wb_idle();
    end
  endtask

  // error injection: reserved-region access must end with err_o, no ack_o
  task automatic wb_read_err(input logic [AW-1:0] a);
    int to;
    begin
      @(negedge clk);
      cyc_i <= 1'b1; stb_i <= 1'b1; we_i <= 1'b0;
      adr_i <= a; dat_i <= '0; sel_i <= 4'hF; cti_i <= 3'b000;
      exp_err[exp_wr] = 1'b1; exp_is_rd[exp_wr] = 1'b0; exp_data[exp_wr] = 32'h0; exp_wr++;
      to = 0;
      while (to < 50) begin
        @(posedge clk);
        if (err_o) to = 100;
        else if (ack_o) begin
          errors++; $display("ERROR: reserved access acked @%h", a); to = 100;
        end
        else to++;
      end
      if (to != 100) begin errors++; $display("ERROR: err timeout @%h", a); end
      wb_idle();
    end
  endtask

  // ------------------------------------------------------------------
  // test sequence
  // ------------------------------------------------------------------
  logic [31:0] pipe_w [0:3];
  int i;

  initial begin
    pipe_w[0] = 32'h1111_0001; pipe_w[1] = 32'h2222_0002;
    pipe_w[2] = 32'h3333_0003; pipe_w[3] = 32'h4444_0004;
    cyc_i = 0; stb_i = 0; we_i = 0; adr_i = 0; dat_i = 0; sel_i = 4'hF; cti_i = 3'b000;
    repeat (4) @(negedge clk);
    rst_n = 1;
    @(negedge clk);

    // CHECK 1: reset / idle state
    if (ack_o !== 1'b0 || err_o !== 1'b0 || stall_o !== 1'b0 || rty_o !== 1'b0) begin
      errors++; $display("ERROR: bad reset state ack=%b err=%b stall=%b rty=%b",
                         ack_o, err_o, stall_o, rty_o);
    end
    if (irq !== 1'b0) begin errors++; $display("ERROR: irq high after reset"); end

    // CHECK 2: classic write + read data path
    wb_write(32'h0000_0010, 32'hDEAD_BEEF, 4'hF);
    wb_read (32'h0000_0010, 32'hDEAD_BEEF);
    wb_write(32'h0000_0014, 32'h1234_5678, 4'hF);
    wb_read (32'h0000_0014, 32'h1234_5678);

    // CHECK 3: SEL partial-write merge
    wb_write(32'h0000_0020, 32'hAABB_CCDD, 4'hF);
    wb_write(32'h0000_0020, 32'h0000_1234, 4'b0011);
    wb_read (32'h0000_0020, 32'hAABB_1234);
    wb_write(32'h0000_0020, 32'h7700_0000, 4'b1000);
    wb_read (32'h0000_0020, 32'h77BB_1234);

    // CHECK 4: pipelined burst -- 4 writes back-to-back, then 4 reads,
    // in-order ack/data checked by scoreboard
    for (i = 0; i < 4; i++) begin
      exp_err[exp_wr] = 1'b0; exp_is_rd[exp_wr] = 1'b0; exp_data[exp_wr] = 32'h0; exp_wr++;
      wb_issue(32'h0000_0040 + i*4, pipe_w[i], 4'hF, 1'b1);
    end
    wb_idle();
    repeat (4) @(posedge clk);               // drain responses
    for (i = 0; i < 4; i++) begin
      exp_err[exp_wr] = 1'b0; exp_is_rd[exp_wr] = 1'b1; exp_data[exp_wr] = pipe_w[i]; exp_wr++;
      wb_issue(32'h0000_0040 + i*4, 32'h0, 4'hF, 1'b0);
    end
    wb_idle();
    repeat (6) @(posedge clk);

    // CHECK 5: slow window (0x200+) generates real stall_o backpressure;
    // 3 back-to-back writes must all complete correctly
    for (i = 0; i < 3; i++) begin
      exp_err[exp_wr] = 1'b0; exp_is_rd[exp_wr] = 1'b0; exp_data[exp_wr] = 32'h0; exp_wr++;
      wb_issue(32'h0000_0200 + i*4, 32'h5A00_0000 + i, 4'hF, 1'b1);
    end
    wb_idle();
    repeat (8) @(posedge clk);
    wb_read(32'h0000_0200, 32'h5A00_0000);
    wb_read(32'h0000_0204, 32'h5A00_0001);
    wb_read(32'h0000_0208, 32'h5A00_0002);
    if (stall_seen == 0) begin
      errors++; $display("ERROR: stall_o never asserted (backpressure not real)");
    end

    // CHECK 6: error injection -- reserved region 0x800+ -> err_o + irq
    wb_read_err(32'h0000_0800);
    wb_read_err(32'h0000_0FFC);
    repeat (2) @(posedge clk);
    if (irq !== 1'b1) begin errors++; $display("ERROR: irq not set after reserved access"); end

    // CHECK 7: normal access still works after error
    wb_write(32'h0000_0030, 32'hCAFE_F00D, 4'hF);
    wb_read (32'h0000_0030, 32'hCAFE_F00D);

    // scoreboard must be drained
    if (exp_rd != exp_wr) begin
      errors++; $display("ERROR: %0d expected responses never arrived", exp_wr - exp_rd);
    end
    if (rty_o !== 1'b0) begin errors++; $display("ERROR: rty_o must be tied 0"); end

    repeat (2) @(posedge clk);
`ifdef VERILATOR
    // ---- v2.5 CRV random phase (directed tests above untouched) ----
    // 256-word pipelined write sweep (mem toggle) + 120 randomized
    // transactions: classic reads/writes in fast/slow/hole windows with
    // random SEL merge, pipelined bursts of 2..4 outstanding beats,
    // hole-region reads (ack, data 0, writes dropped), reserved-region
    // accesses (err_o + sticky irq). All response data checked by the
    // in-order scoreboard; all register state by a shadow regfile.
    begin : crv_phase
      int n_cw = 0, n_cr = 0, n_pipe = 0, n_rsv = 0, n_drain = 0;
      logic [31:0] sh_mem [0:255];
      logic [31:0] ba, db;
      logic [3:0]  sel_v;
      int roll, nb, to_c;
      // sweep: 256 pipelined writes, random data and lanes
      for (int w = 0; w < 256; w++) begin
        db = $urandom; sel_v = 4'hF;
        sh_mem[w] = db;
        wb_issue(w*4, db, sel_v, 1'b1);
        exp_err[exp_wr] = 1'b0; exp_is_rd[exp_wr] = 1'b0; exp_data[exp_wr] = 32'h0; exp_wr++;
      end
      wb_idle();
      to_c = 0;
      while (exp_rd < exp_wr && to_c < 2000) begin @(posedge clk); to_c++; end
      for (int t = 0; t < 120; t++) begin
        roll = $urandom_range(0, 9);
        roll = $urandom_range(0, 9);
        db = $urandom;
        sel_v = (t % 3 == 0) ? 4'hF : (4'h1 << $urandom_range(0, 3));
        // address per window (fast / slow / hole); reserved only via the
        // dedicated rsv beat below (its err response expects exp_err=1)
        case ($urandom_range(0, 2))
          0: ba = {$urandom_range(0, 127), 2'b00};
          1: ba = 32'h200 + {$urandom_range(0, 127), 2'b00};
          default: ba = 32'h400 + {$urandom_range(0, 255), 2'b00};
        endcase
        if (roll < 3) begin
          // classic write (valid/slow/hole); shadow merge when in regfile
          if (ba < 32'h400)
            for (int b = 0; b < 4; b++)
              if (sel_v[b]) sh_mem[ba[9:2]][b*8 +: 8] = db[b*8 +: 8];
          wb_write(ba, db, sel_v);
          n_cw++;
        end else if (roll < 6) begin
          // classic read; hole reads return 0
          wb_read(ba, (ba < 32'h400) ? sh_mem[ba[9:2]] : 32'h0);
          n_cr++;
        end else if (roll < 8) begin
          // pipelined burst of 2..4 outstanding beats (mixed windows)
          nb = 2 + $urandom_range(0, 2);
          for (int j = 0; j < nb; j++) begin
            case ($urandom_range(0, 2))
              0: ba = {$urandom_range(0, 127), 2'b00};
              1: ba = 32'h200 + {$urandom_range(0, 127), 2'b00};
              default: ba = 32'h400 + {$urandom_range(0, 255), 2'b00};
            endcase
            db = $urandom; sel_v = 4'hF;
            if (j == nb-1 && t % 2 == 0) begin
              // last beat to the reserved region while the queue is
              // non-empty: lands q_rsv[1] (err_o response, sticky irq)
              ba = 32'h800 + $urandom;
              wb_issue(ba, 32'h0, sel_v, 1'b0);
              exp_err[exp_wr] = 1'b1; exp_is_rd[exp_wr] = 1'b1;
              exp_data[exp_wr] = 32'h0; exp_wr++;
            end else if ($urandom_range(0, 1)) begin
              if (ba < 32'h400) sh_mem[ba[9:2]] = db;
              wb_issue(ba, db, sel_v, 1'b1);
              exp_err[exp_wr] = 1'b0; exp_is_rd[exp_wr] = 1'b0;
              exp_data[exp_wr] = 32'h0; exp_wr++;
            end else begin
              wb_issue(ba, 32'h0, sel_v, 1'b0);
              exp_err[exp_wr] = 1'b0; exp_is_rd[exp_wr] = 1'b1;
              exp_data[exp_wr] = (ba < 32'h400) ? sh_mem[ba[9:2]] : 32'h0; exp_wr++;
            end
          end
          wb_idle();
          // drain before any classic beat follows: classic tasks correlate
          // ack_o with their own request and require an empty queue
          to_c = 0;
          while (exp_rd < exp_wr && to_c < 200) begin @(posedge clk); to_c++; end
          n_pipe++;
        end else begin
          // reserved region: err_o + sticky irq (custom beat, task can't)
          ba = 32'h800 + $urandom;
          @(negedge clk);
          cyc_i <= 1'b1; stb_i <= 1'b1; we_i <= (t % 2);
          adr_i <= ba; dat_i <= db; sel_i <= sel_v; cti_i <= 3'b000; // classic guard
          exp_err[exp_wr] = 1'b1; exp_is_rd[exp_wr] = !(t % 2);
          exp_data[exp_wr] = 32'h0; exp_wr++;
          to_c = 0;
          while (to_c < 50) begin
            @(posedge clk);
            if (err_o) to_c = 100; else to_c++;
          end
          if (to_c != 100) begin
            errors++; $display("ERROR: CRV err_o timeout @%h", ba);
          end
          wb_idle();
          // wiggle cti_i through reserved values in the idle gap (toggle)
          @(negedge clk); cti_i <= 3'b110;
          @(negedge clk); cti_i <= 3'b011;
          @(negedge clk); cti_i <= 3'b000;
          n_rsv++;
        end
      end
      // drain + sticky irq + spot readback of the shadow regfile
      to_c = 0;
      while (exp_rd < exp_wr && to_c < 2000) begin @(posedge clk); to_c++; end
      if (exp_rd != exp_wr) begin
        errors++; $display("ERROR: CRV %0d responses missing", exp_wr - exp_rd);
      end
      if (irq !== 1'b1) begin
        errors++; $display("ERROR: CRV irq not sticky after reserved accesses");
      end
      for (int w = 0; w < 256; w += 17) wb_read(w*4, sh_mem[w]);
      to_c = 0;
      while (exp_rd < exp_wr && to_c < 500) begin @(posedge clk); to_c++; end
      $display("CRV: 376 txns (sweep=256 classic_wr=%0d classic_rd=%0d pipe_burst=%0d rsv=%0d)",
               n_cw, n_cr, n_pipe, n_rsv);
    end
`endif

    if (errors == 0) $display("TEST PASSED: Wishbone");
    else             $display("TEST FAILED: %0d errors", errors);
`ifdef VERILATOR
    begin
      int visited;
      visited = 0;
      for (int s = 0; s < WB_FSM_TOTAL; s++) visited += fsm_seen[s];
      $display("FSM_COV: %0d/%0d", visited, WB_FSM_TOTAL);
      $display("SVA_CHECKS: %0d/%0d", sva_total - sva_fail, sva_total);
    end
`endif
    $finish;
  end

  // TIMEOUT guard
  initial begin
    #200000;
    $display("TEST FAILED: TIMEOUT");
    $finish;
  end

endmodule
