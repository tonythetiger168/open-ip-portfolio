// SPDX-License-Identifier: Apache-2.0
// ============================================================================
// Crypto___Security_Engine_top testbench -- checks the SHA-256 / HMAC engine:
//   1. reset state
//   2. NIST SHA-256 "abc"    -> ba7816bf...f20015ad
//   3. NIST SHA-256 ""       -> e3b0c442...52b855
//   4. NIST SHA-256 56-byte critical-length message (two padded blocks)
//      "abcdbcde...nopq"    -> 248d6a61...db06c1
//   5. HMAC-SHA-256 RFC 4231 Test Case 1 (key=0b*20, data="Hi There")
//                              -> b0344c61...e32cff7
//   6. busy violation injection (start / msg write while busy) -> irq
//   7. consecutive back-to-back operations
// ============================================================================
`timescale 1ns/1ps
module Crypto___Security_Engine_tb;

  logic         clk = 1'b0;
  logic         rst_n = 1'b0;
  logic         msg_we = 1'b0;
  logic [1:0]   msg_widx = 2'b0;
  logic [127:0] msg = 128'h0;
  logic         key_we = 1'b0;
  logic [1:0]   key_widx = 2'b0;
  logic [127:0] key = 128'h0;
  logic [6:0]   msg_len = 7'd0;
  logic         start = 1'b0;
  logic         mode = 1'b0;
  logic         busy;
  logic         done;
  logic [255:0] digest;
  logic         irq;

  integer errors = 0;

  Crypto___Security_Engine_top dut (
    .clk(clk), .rst_n(rst_n),
    .msg_we(msg_we), .msg_widx(msg_widx), .msg(msg),
    .key_we(key_we), .key_widx(key_widx), .key(key),
    .msg_len(msg_len), .start(start), .mode(mode),
    .busy(busy), .done(done), .digest(digest), .irq(irq)
  );

  always #5 clk = ~clk;

`ifdef VERILATOR
  // =====================================================================
  // v2.5 CRV instrumentation (tool build only; iverilog path unchanged)
  // FSM probed: dut.cs (S_IDLE/S_BLK/S_RND/S_FIN/S_DONE), 5 states.
  // =====================================================================
  localparam int CRY_FSM_TOTAL = 5;
  logic [4:0] fsm_seen = '0;          // visited-state bitmap
  wire  [2:0] dut_state = dut.cs;

  int sva_total = 0, sva_fail = 0;
  // counted immediate assertion: every evaluation is one check
  task automatic sva_check(input bit cond, input string name);
    begin
      sva_total++;
      if (!cond) begin
        sva_fail++;
        errors = errors + 1;
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
        sva_check(busy === 1'b0 && done === 1'b0 && irq === 1'b0,
                  "A1 reset: outputs quiescent");
    end else begin
      // A2: busy exactly reflects non-idle
      sva_check(busy === (dut_state != 3'd0), "A2 busy == !S_IDLE");
      // A3: done is a single-cycle pulse NBA-issued by S_DONE (state has
      // already returned to S_IDLE when the pulse is observed)
      sva_check(!done || (dut_state == 3'd0), "A3 done pulse observed in S_IDLE");
      // A4: state register holds a legal encoding (5 of 8 used)
      sva_check(dut_state <= 3'd4, "A4 state legal");
      // A5: round counter bounded by the 64-round schedule
      sva_check(dut.rcnt <= 6'd63, "A5 rcnt <= 63");
      // A6: block programme register holds a legal encoding
      sva_check(dut.blk_type <= 3'd5, "A6 blk_type legal");
    end
    rst_n_q <= rst_n;
  end
`endif

  // irq capture
  logic irq_seen = 1'b0;
  always @(posedge clk) if (irq) irq_seen = 1'b1;

  // ------------------------------------------------------------------
  // tasks
  // ------------------------------------------------------------------
  task automatic wait_clk(input integer n);
    integer t;
    begin for (t = 0; t < n; t = t + 1) @(posedge clk); end
  endtask

  task automatic load_msg(input logic [511:0] m);
    begin
      @(negedge clk); msg_we = 1'b1; msg_widx = 2'd0; msg = m[511:384];
      @(negedge clk); msg_widx = 2'd1; msg = m[383:256];
      @(negedge clk); msg_widx = 2'd2; msg = m[255:128];
      @(negedge clk); msg_widx = 2'd3; msg = m[127:0];
      @(negedge clk); msg_we = 1'b0;
    end
  endtask

  task automatic load_key(input logic [511:0] k);
    begin
      @(negedge clk); key_we = 1'b1; key_widx = 2'd0; key = k[511:384];
      @(negedge clk); key_widx = 2'd1; key = k[383:256];
      @(negedge clk); key_widx = 2'd2; key = k[255:128];
      @(negedge clk); key_widx = 2'd3; key = k[127:0];
      @(negedge clk); key_we = 1'b0;
    end
  endtask

  task automatic run_op(input logic hm, input logic [6:0] len);
    integer t;
    begin
      @(negedge clk); start = 1'b1; mode = hm; msg_len = len;
      @(negedge clk); start = 1'b0;
      t = 0;
      while ((done !== 1'b1) && (t < 2000)) begin @(posedge clk); t = t + 1; end
      if (done !== 1'b1) begin
        errors = errors + 1;
        $display("ERROR: timeout waiting for done");
      end
    end
  endtask

  task automatic check_digest(input logic [255:0] exp, input string tag);
    begin
      if (digest !== exp) begin
        errors = errors + 1;
        $display("ERROR: %s digest=%064h", tag, digest);
        $display("       %s expect=%064h", tag, exp);
      end else $display("ok: %s digest=%064h", tag, digest);
    end
  endtask

  // ------------------------------------------------------------------
  // standard vectors
  // ------------------------------------------------------------------
  // "abc"
  localparam logic [511:0] M_ABC =
    512'h61626300000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000;
  localparam logic [255:0] D_ABC =
    256'hba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad;
  // "" (empty)
  localparam logic [511:0] M_EMPTY = 512'h0;
  localparam logic [255:0] D_EMPTY =
    256'he3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855;
  // 56-byte critical-length message
  localparam logic [511:0] M_56 =
    512'h6162636462636465636465666465666765666768666768696768696a68696a6b696a6b6c6a6b6c6d6b6c6d6e6c6d6e6f6d6e6f706e6f70710000000000000000;
  localparam logic [255:0] D_56 =
    256'h248d6a61d20638b8e5c026930c3e6039a33ce45964ff2167f6ecedd419db06c1;
  // RFC 4231 TC1: key = 0x0b x 20, data = "Hi There"
  localparam logic [511:0] K_RFC =
    512'h0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0000000000000000000000000000000000000000000000000000000000000000000000000000000000000000;
  localparam logic [511:0] M_RFC =
    512'h48692054686572650000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000;
  localparam logic [255:0] D_RFC =
    256'hb0344c61d8db38535ca8afceaf0bf12b881dc200c9833da726e9376c2e32cff7;

  integer t;

  initial begin
    // ---- 1. reset state ----
    rst_n = 1'b0;
    wait_clk(10);
    rst_n = 1'b1;
    wait_clk(5);
    if (busy !== 1'b0) begin errors = errors + 1; $display("ERROR: busy after reset"); end
    if (done !== 1'b0) begin errors = errors + 1; $display("ERROR: done after reset"); end
    if (irq  !== 1'b0) begin errors = errors + 1; $display("ERROR: irq after reset"); end
    $display("check 1: reset state done");

    // ---- 2. SHA-256("abc") ----
    load_msg(M_ABC);
    run_op(1'b0, 7'd3);
    check_digest(D_ABC, "sha256(abc)");
    $display("check 2: sha256 abc done");

    // ---- 3. SHA-256("") ----
    load_msg(M_EMPTY);
    run_op(1'b0, 7'd0);
    check_digest(D_EMPTY, "sha256(empty)");
    $display("check 3: sha256 empty done");

    // ---- 4. SHA-256 56-byte critical length (two padded blocks) ----
    load_msg(M_56);
    run_op(1'b0, 7'd56);
    check_digest(D_56, "sha256(56B)");
    $display("check 4: sha256 56-byte done");

    // ---- 5. HMAC-SHA-256 RFC 4231 test case 1 ----
    load_key(K_RFC);
    load_msg(M_RFC);
    run_op(1'b1, 7'd8);
    check_digest(D_RFC, "hmac_rfc4231_tc1");
    $display("check 5: HMAC RFC4231 TC1 done");

    // ---- 6. busy violation injection ----
    load_msg(M_ABC);
    irq_seen = 1'b0;
    @(negedge clk); start = 1'b1; mode = 1'b0; msg_len = 7'd3;
    @(negedge clk); start = 1'b0;
    wait_clk(3);
    if (busy !== 1'b1) begin
      errors = errors + 1; $display("ERROR: busy not set during hashing");
    end
    @(negedge clk); start = 1'b1;                    // illegal start while busy
    @(negedge clk); start = 1'b0;
    @(negedge clk); msg_we = 1'b1; msg_widx = 2'd0; msg = 128'hdeadbeef; // illegal
    @(negedge clk); msg_we = 1'b0;
    wait_clk(2);
    if (!irq_seen) begin
      errors = errors + 1; $display("ERROR: no irq on busy violation");
    end
    t = 0;
    while ((done !== 1'b1) && (t < 2000)) begin @(posedge clk); t = t + 1; end
    if (done !== 1'b1) begin
      errors = errors + 1; $display("ERROR: timeout after busy violation");
    end
    check_digest(D_ABC, "busy_violation result intact");
    $display("check 6: busy violation injection done");

    // ---- 7. consecutive back-to-back operations (SHA then HMAC) ----
    load_msg(M_ABC);
    run_op(1'b0, 7'd3);
    check_digest(D_ABC, "b2b sha256(abc)");
    load_msg(M_RFC);
    run_op(1'b1, 7'd8);      // key still K_RFC from check 5
    check_digest(D_RFC, "b2b hmac_rfc4231_tc1");
    $display("check 7: back-to-back operations done");

    // ---- summary ----
    wait_clk(10);
`ifdef VERILATOR
    // ---- v2.5 CRV random phase (directed tests above untouched) ----
    // 110 randomized ops + 10 busy-violation injections. Self-checking
    // without a second SHA model: (a) every op is run twice back-to-back
    // and must be bit-identical (determinism), (b) HMAC(key,m) must differ
    // from SHA-256(m) for the same message (avalanche sanity), (c) known
    // NIST/RFC4231 vectors anchored by the directed phase, (d) all
    // busy/done/irq protocol invariants via the SVA suite. Message lengths
    // sweep the padding boundaries 0/1/55/56/63/64.
    begin : crv_phase
      int n_sha = 0, n_hmac = 0, n_vio = 0, n_b2b = 0;
      logic [511:0] m_v, k_v;
      logic [255:0] d1, d2;
      logic [6:0]   len_v;
      logic         hm_v;
      integer       tt;
      for (int t = 0; t < 110; t++) begin
        for (int i = 0; i < 16; i++) m_v[511-32*i -: 32] = $urandom;
        for (int i = 0; i < 16; i++) k_v[511-32*i -: 32] = $urandom;
        hm_v = (t % 2 == 1);
        case (t % 6)
          0: len_v = 7'd0;
          1: len_v = 7'd55;
          2: len_v = 7'd56;
          3: len_v = 7'd64;
          4: len_v = 7'd1;
          default: len_v = $urandom_range(2, 63);
        endcase
        load_msg(m_v);
        load_key(k_v);
        run_op(hm_v, len_v);
        d1 = digest;
        // immediate re-run of the identical op: must be bit-identical
        run_op(hm_v, len_v);
        d2 = digest;
        n_b2b = n_b2b + 1;
        if (d1 !== d2) begin
          errors = errors + 1;
          $display("ERROR: CRV non-deterministic t=%0d len=%0d hm=%0d", t, len_v, hm_v);
        end
        if (hm_v) begin
          n_hmac = n_hmac + 1;
          // HMAC(key,m) must differ from plain SHA-256(m)
          run_op(1'b0, len_v);
          if (digest === d1) begin
            errors = errors + 1;
            $display("ERROR: CRV HMAC == SHA t=%0d", t);
          end
        end else n_sha = n_sha + 1;
        if (busy !== 1'b0) begin
          errors = errors + 1;
          $display("ERROR: CRV busy stuck after done t=%0d", t);
        end
      end
      // busy-violation injections: msg/key writes + start while busy -> irq
      for (int t = 0; t < 10; t++) begin
        for (int i = 0; i < 16; i++) m_v[511-32*i -: 32] = $urandom;
        load_msg(m_v);
        load_key(k_v);
        irq_seen = 1'b0;
        @(negedge clk); start = 1'b1; mode = (t % 2); msg_len = 7'd64;
        @(negedge clk); start = 1'b0;
        // engine is now busy: violate
        @(negedge clk); msg_we = 1'b1; msg_widx = t[1:0]; msg = $urandom;
        @(negedge clk); msg_we = 1'b0;
        @(negedge clk); key_we = 1'b1; key_widx = t[1:0]; key = $urandom;
        @(negedge clk); key_we = 1'b0;
        @(negedge clk); start = 1'b1;
        @(negedge clk); start = 1'b0;
        tt = 0;
        while ((done !== 1'b1) && (tt < 2000)) begin @(posedge clk); tt = tt + 1; end
        if (done !== 1'b1) begin
          errors = errors + 1; $display("ERROR: CRV violation op timeout t=%0d", t);
        end
        if (!irq_seen) begin
          errors = errors + 1; $display("ERROR: CRV no irq on busy violation t=%0d", t);
        end
        n_vio = n_vio + 1;
      end
      $display("CRV: 110 ops x2 (sha=%0d hmac=%0d b2b=%0d) + %0d violations",
               n_sha, n_hmac, n_b2b, n_vio);
    end
`endif

    if (errors == 0) $display("TEST PASSED: Crypto___Security_Engine");
    else             $display("TEST FAILED: %0d errors", errors);
`ifdef VERILATOR
    begin
      int visited;
      visited = 0;
      for (int s = 0; s < CRY_FSM_TOTAL; s++) visited += fsm_seen[s];
      $display("FSM_COV: %0d/%0d", visited, CRY_FSM_TOTAL);
      $display("SVA_CHECKS: %0d/%0d", sva_total - sva_fail, sva_total);
    end
`endif
    $finish;
  end

`ifdef VERILATOR
  // chunked timeout guard
  initial begin
    repeat (8000) #1000;
    $display("TIMEOUT"); $finish;
  end
`else
  // TIMEOUT guard
  initial begin
    #2000000;
    $display("TEST FAILED: TIMEOUT");
    $finish;
  end
`endif

endmodule
