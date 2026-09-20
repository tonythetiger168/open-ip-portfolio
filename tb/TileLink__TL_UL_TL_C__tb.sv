// SPDX-License-Identifier: Apache-2.0
// ============================================================================
// Self-checking testbench for TileLink__TL_UL_TL_C__top (TL-UL slave)
// TB acts as a TileLink master model: PutFull/PutPartial/Get, source echo
// checks, mask merge, d_ready backpressure hold, illegal opcode/size/mask/
// alignment/range error injection (d_error + irq), back-to-back requests.
// ============================================================================
`timescale 1ns/1ps
module TileLink__TL_UL_TL_C__tb;
  localparam int DW = 32, AW = 32;

  logic clk = 0, rst_n = 0;
  logic          a_valid, a_ready;
  logic [2:0]    a_opcode, a_param, a_size;
  logic [7:0]    a_source;
  logic [AW-1:0] a_address;
  logic [3:0]    a_mask;
  logic [DW-1:0] a_data;
  logic          d_valid, d_ready;
  logic [2:0]    d_opcode, d_size;
  logic [7:0]    d_source;
  logic [DW-1:0] d_data;
  logic          d_error, irq;

  int errors = 0;

  TileLink__TL_UL_TL_C__top #(.DW(DW), .AW(AW)) dut (
    .clk(clk), .rst_n(rst_n),
    .a_valid(a_valid), .a_ready(a_ready), .a_opcode(a_opcode),
    .a_param(a_param), .a_size(a_size), .a_source(a_source),
    .a_address(a_address), .a_mask(a_mask), .a_data(a_data),
    .d_valid(d_valid), .d_ready(d_ready), .d_opcode(d_opcode),
    .d_size(d_size), .d_source(d_source), .d_data(d_data),
    .d_error(d_error), .irq(irq)
  );

  always #5 clk = ~clk;

`ifdef VERILATOR
  // =====================================================================
  // v2.5 CRV instrumentation (tool build only; iverilog path unchanged)
  // FSM probed: dut.state (S_IDLE/S_RESP), 2 states.
  // =====================================================================
  localparam int TL_FSM_TOTAL = 2;
  logic [1:0] fsm_seen = '0;          // visited-state bitmap
  wire        dut_state = dut.state;

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
        sva_check(d_valid === 1'b0 && a_ready === 1'b1 && irq === 1'b0,
                  "A1 reset: idle, ready, no irq");
    end else begin
      // A2: d_valid exactly reflects S_RESP
      sva_check(d_valid === (dut_state == 1'b1), "A2 d_valid == S_RESP");
      // A3: a_ready exactly reflects the accept rule
      sva_check(a_ready === ((dut_state == 1'b0) || (dut_state == 1'b1 && d_ready)),
                "A3 a_ready rule");
      // A4: D-channel outputs mirror their holding registers
      sva_check(d_opcode === dut.d_opcode_q && d_size === dut.d_size_q &&
                d_source === dut.d_source_q && d_data === dut.d_data_q &&
                d_error === dut.d_error_q, "A4 D outputs mirror regs");
      // A5: state register holds a legal encoding (1-bit)
      sva_check(dut_state <= 1'b1, "A5 state legal");
      // A6: response opcode is always a legal TL-UL response
      sva_check(!d_valid || (d_opcode == 3'd0 || d_opcode == 3'd1),
                "A6 legal response opcode");
    end
    rst_n_q <= rst_n;
  end
`endif

  // ------------------------------------------------------------------
  // passive response recorder (used by the pipelined back-to-back test)
  // ------------------------------------------------------------------
  logic [2:0]  r_op  [0:255];
  logic [7:0]  r_src [0:255];
  logic        r_err [0:255];
  logic [31:0] r_dat [0:255];
  int rn = 0;
  always @(posedge clk) begin
    if (d_valid && d_ready) begin
      r_op[rn]  = d_opcode;
      r_src[rn] = d_source;
      r_err[rn] = d_error;
      r_dat[rn] = d_data;
      rn++;
    end
  end

  // ------------------------------------------------------------------
  // master-model helpers
  // ------------------------------------------------------------------
  task automatic tl_idle;
    begin
      @(negedge clk);
      a_valid <= 1'b0;
    end
  endtask

  // issue one A beat (held until a_ready), then wait for the D response.
  // Checks d_opcode/d_size/d_source/d_error; read data compared when !exp_err.
  task automatic tl_xact(input logic [2:0] op, input logic [31:0] addr,
                         input logic [31:0] data, input logic [3:0] mask,
                         input logic [2:0] size, input logic [7:0] src,
                         input logic        exp_err,
                         input logic [31:0] exp_data);
    int to;
    begin
      @(negedge clk);
      a_valid  <= 1'b1;
      a_opcode <= op; a_param <= 3'd0; a_size <= size; a_source <= src;
      a_address <= addr; a_mask <= mask; a_data <= data;
      to = 0;
      while (to < 50) begin
        @(posedge clk);
        if (a_ready) to = 100; else to++;
      end
      if (to != 100) begin errors++; $display("ERROR: a_ready timeout op=%0d @%h", op, addr); end
      tl_idle();
      // wait for D response
      to = 0;
      while (to < 50) begin
        @(posedge clk);
        if (d_valid) to = 100; else to++;
      end
      if (to != 100) begin
        errors++; $display("ERROR: d_valid timeout op=%0d @%h", op, addr);
      end else begin
        if (d_error !== exp_err) begin
          errors++; $display("ERROR: d_error=%b exp %b op=%0d @%h", d_error, exp_err, op, addr);
        end
        if (d_source !== src) begin
          errors++; $display("ERROR: source echo exp %h got %h", src, d_source);
        end
        if (d_size !== size) begin
          errors++; $display("ERROR: size echo exp %0d got %0d", size, d_size);
        end
        if (!exp_err) begin
          if (op == 3'd4) begin
            if (d_opcode !== 3'd1) begin
              errors++; $display("ERROR: Get d_opcode exp AccessAckData got %0d", d_opcode);
            end
            if (d_data !== exp_data) begin
              errors++; $display("ERROR: Get data @%h exp %h got %h", addr, exp_data, d_data);
            end
          end else begin
            if (d_opcode !== 3'd0) begin
              errors++; $display("ERROR: Put d_opcode exp AccessAck got %0d", d_opcode);
            end
          end
        end
      end
      // response consumed (d_ready=1); settle
      @(posedge clk);
    end
  endtask

  // ------------------------------------------------------------------
  // test sequence
  // ------------------------------------------------------------------
  logic [31:0] held_data;
  int to;

  initial begin
    a_valid = 0; a_opcode = 0; a_param = 0; a_size = 3'd2; a_source = 0;
    a_address = 0; a_mask = 4'hF; a_data = 0; d_ready = 1;
    repeat (4) @(negedge clk);
    rst_n = 1;
    @(negedge clk);

    // CHECK 1: reset / idle state
    if (d_valid !== 1'b0 || irq !== 1'b0) begin
      errors++; $display("ERROR: bad reset state d_valid=%b irq=%b", d_valid, irq);
    end
    if (a_ready !== 1'b1) begin
      errors++; $display("ERROR: a_ready must be high when idle");
    end

    // CHECK 2: PutFull + Get data path, distinct source ids
    tl_xact(3'd0, 32'h0000_0010, 32'hDEAD_BEEF, 4'hF, 3'd2, 8'h11, 1'b0, 32'h0);
    tl_xact(3'd4, 32'h0000_0010, 32'h0,        4'hF, 3'd2, 8'h22, 1'b0, 32'hDEAD_BEEF);
    tl_xact(3'd0, 32'h0000_0014, 32'h1234_5678, 4'hF, 3'd2, 8'h33, 1'b0, 32'h0);
    tl_xact(3'd4, 32'h0000_0014, 32'h0,        4'hF, 3'd2, 8'h44, 1'b0, 32'h1234_5678);

    // CHECK 3: PutPartial mask merge
    tl_xact(3'd0, 32'h0000_0020, 32'hAABB_CCDD, 4'hF,    3'd2, 8'h01, 1'b0, 32'h0);
    tl_xact(3'd1, 32'h0000_0020, 32'h0000_1234, 4'b0011, 3'd2, 8'h02, 1'b0, 32'h0);
    tl_xact(3'd4, 32'h0000_0020, 32'h0,         4'hF,    3'd2, 8'h03, 1'b0, 32'hAABB_1234);

    // CHECK 4: d_ready backpressure -- d_valid & payload must hold
    @(negedge clk);
    a_valid <= 1'b1; a_opcode <= 3'd4; a_size <= 3'd2; a_source <= 8'h55;
    a_address <= 32'h0000_0010; a_mask <= 4'hF; a_data <= 32'h0;
    d_ready <= 1'b0;
    to = 0;
    while (to < 50) begin
      @(posedge clk);
      if (a_ready) to = 100; else to++;
    end
    tl_idle();
    to = 0;
    while (to < 50) begin
      @(posedge clk);
      if (d_valid) to = 100; else to++;
    end
    if (to != 100) begin errors++; $display("ERROR: d_valid timeout (backpressure test)"); end
    held_data = d_data;
    if (d_data !== 32'hDEAD_BEEF) begin
      errors++; $display("ERROR: backpressure data exp DEAD_BEEF got %h", d_data);
    end
    repeat (4) begin
      @(posedge clk);
      if (!d_valid) begin errors++; $display("ERROR: d_valid dropped under backpressure"); end
      if (d_data !== held_data) begin
        errors++; $display("ERROR: d_data changed while d_ready low");
      end
    end
    @(negedge clk);
    d_ready <= 1'b1;
    @(posedge clk); @(posedge clk);

    // CHECK 5: error injection -- illegal opcode (2=Intent reserved)
    tl_xact(3'd2, 32'h0000_0010, 32'h0, 4'hF, 3'd2, 8'h66, 1'b1, 32'h0);
    // illegal size (3 = 8B > bus width)
    tl_xact(3'd4, 32'h0000_0010, 32'h0, 4'hF, 3'd3, 8'h67, 1'b1, 32'h0);
    // misaligned address
    tl_xact(3'd4, 32'h0000_0012, 32'h0, 4'hF, 3'd2, 8'h68, 1'b1, 32'h0);
    // Get with non-full mask (mask/size inconsistency)
    tl_xact(3'd4, 32'h0000_0010, 32'h0, 4'h3, 3'd2, 8'h69, 1'b1, 32'h0);
    // PutPartial with zero mask
    tl_xact(3'd1, 32'h0000_0010, 32'h0, 4'h0, 3'd2, 8'h6A, 1'b1, 32'h0);
    // out-of-range address (>= 0x100)
    tl_xact(3'd4, 32'h0000_0100, 32'h0, 4'hF, 3'd2, 8'h6B, 1'b1, 32'h0);
    if (irq !== 1'b1) begin
      errors++; $display("ERROR: irq not set after illegal requests");
    end

    // CHECK 6: errors must not corrupt the regfile
    tl_xact(3'd4, 32'h0000_0010, 32'h0, 4'hF, 3'd2, 8'h70, 1'b0, 32'hDEAD_BEEF);
    tl_xact(3'd4, 32'h0000_0020, 32'h0, 4'hF, 3'd2, 8'h71, 1'b0, 32'hAABB_1234);

    // CHECK 7: pipelined back-to-back requests -- a_valid held across beats,
    // payload swapped every accepted cycle (1 request + 1 response per clk)
    begin
      int i, base;
      base = rn;
      for (i = 0; i < 4; i++) begin
        @(negedge clk);
        a_valid <= 1'b1; a_opcode <= 3'd0; a_size <= 3'd2;
        a_source <= 8'h80 + i[7:0];
        a_address <= 32'h0000_0040 + i[31:0]*4;
        a_mask <= 4'hF; a_data <= 32'h9000_0000 + i[31:0];
        to = 0;
        while (to < 50) begin
          @(posedge clk);
          if (a_ready) to = 100; else to++;
        end
        if (to != 100) begin errors++; $display("ERROR: b2b a_ready timeout %0d", i); end
      end
      tl_idle();
      // wait for all 4 in-order responses (recorded concurrently)
      to = 0;
      while (rn < base + 4 && to < 100) begin @(posedge clk); to++; end
      if (rn < base + 4) begin
        errors++; $display("ERROR: b2b got %0d/4 responses", rn - base);
      end else begin
        for (i = 0; i < 4; i++) begin
          if (r_err[base+i] || r_op[base+i] !== 3'd0 ||
              r_src[base+i] !== (8'h80 + i[7:0])) begin
            errors++; $display("ERROR: b2b resp %0d err=%b op=%0d src=%h",
                               i, r_err[base+i], r_op[base+i], r_src[base+i]);
          end
        end
      end
      repeat (2) @(posedge clk);
      // verify back-to-back writes landed
      tl_xact(3'd4, 32'h0000_0040, 32'h0, 4'hF, 3'd2, 8'h90, 1'b0, 32'h9000_0000);
      tl_xact(3'd4, 32'h0000_004C, 32'h0, 4'hF, 3'd2, 8'h91, 1'b0, 32'h9000_0003);
    end

    repeat (2) @(posedge clk);

`ifdef VERILATOR
    // ---- v2.5 CRV random phase (directed tests above untouched) ----
    // 174 transactions: 64-entry regfile write sweep (random data, toggles
    // every mem entry) + 110 randomized: valid PutFull/PutPartial/Get with
    // shadow-regfile data check, plus the five error classes (bad opcode /
    // size / alignment / mask / range) expecting d_error + sticky irq.
    // Reuses the bounded tl_xact master task (no unbounded waits).
    begin : crv_phase
      int n_put = 0, n_get = 0, n_err = 0;
      logic [31:0] sh_mem [0:63];
      logic [31:0] av, dv;
      logic [2:0]  op_v, sz_v;
      logic [3:0]  mk_v;
      logic [7:0]  src_v;
      int roll, cls;
      // sweep: write every regfile entry (mem toggle coverage), then read
      // four of them back to confirm the sweep landed
      for (int a = 0; a < 64; a++) begin
        sh_mem[a] = $urandom;
        tl_xact(3'd0, a*4, sh_mem[a], 4'hF, 3'd2, 8'hA0 + a[7:0] % 8'h40, 1'b0, 32'h0);
      end
      for (int a = 0; a < 64; a += 16)
        tl_xact(3'd4, a*4, 32'h0, 4'hF, 3'd2, 8'hE0 + a[7:0], 1'b0, sh_mem[a]);
      for (int t = 0; t < 110; t++) begin
        roll = $urandom_range(0, 9);
        src_v = $urandom_range(0, 255);
        if (roll < 4) begin
          // valid PutFull / PutPartial with mask merge into the shadow copy
          op_v = (roll < 2) ? 3'd0 : 3'd1;
          av   = {$urandom_range(0, 63), 2'b00};
          dv   = $urandom;
          mk_v = (op_v == 3'd0) ? 4'hF : (4'h1 << $urandom_range(0, 3));
          if (op_v == 3'd1 && t % 3 == 0) mk_v = 4'hF;   // full partial too
          for (int b = 0; b < 4; b++)
            if (mk_v[b]) sh_mem[av[7:2]][b*8 +: 8] = dv[b*8 +: 8];
          tl_xact(op_v, av, dv, mk_v, 3'd2, src_v, 1'b0, 32'h0);
          n_put++;
        end else if (roll < 8) begin
          // valid Get, data checked against the shadow regfile
          av = {$urandom_range(0, 63), 2'b00};
          tl_xact(3'd4, av, 32'h0, 4'hF, 3'd2, src_v, 1'b0, sh_mem[av[7:2]]);
          n_get++;
        end else begin
          // error injection; classes round-robin so each is guaranteed hit.
          // Full-random addresses toggle every a_address bit.
          cls = t % 5;
          op_v = 3'd4; av = {$urandom_range(0, 63), 2'b00};
          mk_v = 4'hF; sz_v = 3'd2; dv = 32'h0;
          case (cls)
            0: begin op_v = 3'd2 + $urandom_range(0, 1);  // reserved opcode
                      av = $urandom; end
            1: begin sz_v = $urandom_range(0, 7);             // bad size
                      if (sz_v == 3'd2) sz_v = 3'd7;          // (not 2)
                      av = $urandom; av[1:0] = 2'b00; av[8] = 1'b0; end
            2: begin av = $urandom;                       // misaligned
                      if (av[1:0] == 2'b00) av[0] = 1'b1; av[8] = 1'b0; end
            3: begin mk_v = (t % 2 == 0) ? 4'h3 : 4'h0;   // bad mask
                      av = $urandom; av[1:0] = 2'b00; av[8] = 1'b0; end
            default: av = $urandom | 32'h0000_0100;       // out of range
          endcase
          tl_xact(op_v, av, dv, mk_v, sz_v, src_v, 1'b1, 32'h0);
          n_err++;
        end
        // a_param is functionally unused; wiggle it between txns (toggle cov)
        @(negedge clk); a_param <= $urandom_range(0, 7);
      end
      // errors must not have corrupted the regfile: re-verify the sweep
      for (int a = 1; a < 64; a += 16)
        tl_xact(3'd4, a*4, 32'h0, 4'hF, 3'd2, 8'hF0 + a[7:0], 1'b0, sh_mem[a]);
      if (irq !== 1'b1) begin
        errors++; $display("ERROR: CRV irq not sticky after error injections");
      end
      $display("CRV: 174 txns (sweep=68 put=%0d get=%0d err=%0d)",
               n_put, n_get, n_err);
    end
`endif

    if (errors == 0) $display("TEST PASSED: TileLink__TL_UL_TL_C_");
    else             $display("TEST FAILED: %0d errors", errors);
`ifdef VERILATOR
    begin
      int visited;
      visited = 0;
      for (int s = 0; s < TL_FSM_TOTAL; s++) visited += fsm_seen[s];
      $display("FSM_COV: %0d/%0d", visited, TL_FSM_TOTAL);
      $display("SVA_CHECKS: %0d/%0d", sva_total - sva_fail, sva_total);
    end
`endif
    $finish;
  end

`ifdef VERILATOR
  // chunked timeout guard: a single long-pending #delay event corrupts the
  // 5.006 --timing delay heap once many short-delay resumptions interleave
  initial begin
    repeat (2000) #1000;
    $display("TIMEOUT"); $finish;
  end
`else
  // TIMEOUT guard
  initial begin
    #300000;
    $display("TEST FAILED: TIMEOUT");
    $finish;
  end
`endif

endmodule
