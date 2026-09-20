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
    if (errors == 0) $display("TEST PASSED: Crypto___Security_Engine");
    else             $display("TEST FAILED: %0d errors", errors);
    $finish;
  end

  // TIMEOUT guard
  initial begin
    #2000000;
    $display("TEST FAILED: TIMEOUT");
    $finish;
  end

endmodule
