// SPDX-License-Identifier: Apache-2.0
// ============================================================================
// CSE_top testbench -- drives the AES-128 command port and checks:
//   1. reset state
//   2. FIPS-197 App.B vector enc+dec loopback:
//      key=000102..0f pt=00112233..ff -> ct=69c4e0d86a7b0430d8cdb78070b4c55a
//   3. NIST AESAVS all-zero KAT vector enc+dec loopback
//      key=0, pt=0 -> ct=66e94bd4ef8a2c3b884cfa59ca342b2e
//   4. NIST SP800-38A F.1.1 ECB vector enc+dec loopback
//      key=2b7e15..f3c pt=6bc1be..172a -> ct=3ad77bb40d7a3660a89ecaf32466ef97
//   5. busy violation injection (start / key write while busy) -> irq
//   6. consecutive back-to-back operations
// ============================================================================
`timescale 1ns/1ps
module CSE_tb;

  logic         clk = 1'b0;
  logic         rst_n = 1'b0;
  logic         key_we = 1'b0;
  logic [1:0]   key_widx = 2'b0;
  logic [31:0]  key = 32'h0;
  logic         start = 1'b0;
  logic         enc_dec = 1'b1;
  logic [127:0] din = 128'h0;
  logic         busy;
  logic         done;
  logic [127:0] dout;
  logic         irq;

  integer errors = 0;

  CSE_top dut (
    .clk(clk), .rst_n(rst_n),
    .key_we(key_we), .key_widx(key_widx), .key(key),
    .start(start), .enc_dec(enc_dec), .din(din),
    .busy(busy), .done(done), .dout(dout), .irq(irq)
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

  task automatic load_key(input logic [127:0] k);
    begin
      @(negedge clk); key_we = 1'b1; key_widx = 2'd0; key = k[127:96];
      @(negedge clk); key_widx = 2'd1; key = k[95:64];
      @(negedge clk); key_widx = 2'd2; key = k[63:32];
      @(negedge clk); key_widx = 2'd3; key = k[31:0];
      @(negedge clk); key_we = 1'b0;
    end
  endtask

  // run one AES operation, wait for done, return nothing (checks dout outside)
  task automatic run_op(input logic enc, input logic [127:0] data);
    integer t;
    begin
      @(negedge clk); start = 1'b1; enc_dec = enc; din = data;
      @(negedge clk); start = 1'b0;
      t = 0;
      while ((done !== 1'b1) && (t < 200)) begin @(posedge clk); t = t + 1; end
      if (done !== 1'b1) begin
        errors = errors + 1;
        $display("ERROR: timeout waiting for done");
      end
    end
  endtask

  task automatic check_dout(input logic [127:0] exp, input string tag);
    begin
      if (dout !== exp) begin
        errors = errors + 1;
        $display("ERROR: %s dout=%032h exp %032h", tag, dout, exp);
      end else $display("ok: %s dout=%032h", tag, dout);
    end
  endtask

  // ------------------------------------------------------------------
  // standard vectors
  // ------------------------------------------------------------------
  localparam logic [127:0] K1 = 128'h000102030405060708090a0b0c0d0e0f;
  localparam logic [127:0] P1 = 128'h00112233445566778899aabbccddeeff;
  localparam logic [127:0] C1 = 128'h69c4e0d86a7b0430d8cdb78070b4c55a;

  localparam logic [127:0] K2 = 128'h00000000000000000000000000000000;
  localparam logic [127:0] P2 = 128'h00000000000000000000000000000000;
  localparam logic [127:0] C2 = 128'h66e94bd4ef8a2c3b884cfa59ca342b2e;

  localparam logic [127:0] K3 = 128'h2b7e151628aed2a6abf7158809cf4f3c;
  localparam logic [127:0] P3 = 128'h6bc1bee22e409f96e93d7e117393172a;
  localparam logic [127:0] C3 = 128'h3ad77bb40d7a3660a89ecaf32466ef97;

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

    // ---- 2/3/4. standard vectors, encrypt then decrypt loopback ----
    // FIPS-197 Appendix B
    load_key(K1);
    run_op(1'b1, P1); check_dout(C1, "fips197_appB enc");
    run_op(1'b0, C1); check_dout(P1, "fips197_appB dec");
    // NIST AESAVS all-zero KAT
    load_key(K2);
    run_op(1'b1, P2); check_dout(C2, "aesavs_zero enc");
    run_op(1'b0, C2); check_dout(P2, "aesavs_zero dec");
    // NIST SP800-38A F.1.1
    load_key(K3);
    run_op(1'b1, P3); check_dout(C3, "sp800_38a enc");
    run_op(1'b0, C3); check_dout(P3, "sp800_38a dec");
    $display("check 2-4: standard vector enc/dec loopback done");

    // ---- 5. busy violation injection: start + key write while busy ----
    load_key(K1);
    irq_seen = 1'b0;
    @(negedge clk); start = 1'b1; enc_dec = 1'b1; din = P1;
    @(negedge clk); start = 1'b0;
    wait_clk(3);                                  // engine busy now
    if (busy !== 1'b1) begin
      errors = errors + 1; $display("ERROR: busy not set during operation");
    end
    @(negedge clk); start = 1'b1; din = P2;       // illegal: start while busy
    @(negedge clk); start = 1'b0;
    @(negedge clk); key_we = 1'b1; key_widx = 2'd0; key = 32'hdeadbeef; // illegal
    @(negedge clk); key_we = 1'b0;
    wait_clk(2);
    if (!irq_seen) begin
      errors = errors + 1; $display("ERROR: no irq on busy violation");
    end
    // operation must still complete with the original command/key
    t = 0;
    while ((done !== 1'b1) && (t < 200)) begin @(posedge clk); t = t + 1; end
    if (done !== 1'b1) begin
      errors = errors + 1; $display("ERROR: timeout after busy violation");
    end
    check_dout(C1, "busy_violation result intact");
    $display("check 5: busy violation injection done");

    // ---- 6. consecutive back-to-back operations (done -> start) ----
    load_key(K3);
    run_op(1'b1, P1);   // encrypt P1 with K3, then decrypt result back
    run_op(1'b0, dout); check_dout(P1, "b2b loopback1");
    run_op(1'b1, C2);   // encrypt C2 with K3, then decrypt result back
    run_op(1'b0, dout); check_dout(C2, "b2b loopback2");
    $display("check 6: back-to-back operations done");

    // ---- summary ----
    wait_clk(10);
    if (errors == 0) $display("TEST PASSED: CSE");
    else             $display("TEST FAILED: %0d errors", errors);
    $finish;
  end

  // TIMEOUT guard
  initial begin
    #1000000;
    $display("TEST FAILED: TIMEOUT");
    $finish;
  end

endmodule
