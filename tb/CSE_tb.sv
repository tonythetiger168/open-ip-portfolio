// SPDX-License-Identifier: Apache-2.0
// ============================================================================
// CSE_top testbench -- drives the AES-128 command port and checks:
//   * reset state
//   * FIPS-197 App.B, NIST AESAVS all-zero KAT, SP800-38A F.1.1 and an
//     all-ones vector: encrypt matches the known ciphertext, decrypt
//     returns the plaintext
//   * random keys / blocks: decrypt(encrypt(x)) == x, latency 21 cycles
//   * key write and start while busy -> irq, command ignored, result and
//     key unchanged; start in the cycle done is seen; key write and start
//     in the same idle cycle (the start uses the old key)
//   * reset while busy
// ============================================================================
`timescale 1ns/1ps
module CSE_tb;
  logic         clk = 1'b0, rst_n = 1'b0;
  logic         key_we = 1'b0;
  logic [1:0]   key_widx = 2'b0;
  logic [31:0]  key = 32'h0;
  logic         start = 1'b0, enc_dec = 1'b1;
  logic [127:0] din = 128'h0;
  wire          busy, done, irq;
  wire  [127:0] dout;
  int errors = 0;
  logic irq_seen = 0;

  CSE_top dut (
    .clk(clk), .rst_n(rst_n),
    .key_we(key_we), .key_widx(key_widx), .key(key),
    .start(start), .enc_dec(enc_dec), .din(din),
    .busy(busy), .done(done), .dout(dout), .irq(irq)
  );

  always #5 clk = ~clk;
  always @(posedge clk) if (irq) irq_seen <= 1;

  task automatic check(input bit cond, input string msg);
    if (!cond) begin errors++; $display("ERROR: %s (time %0t)", msg, $time); end
  endtask

  task automatic load_key(input logic [127:0] k);
    begin
      for (int i = 0; i < 4; i++) begin
        @(negedge clk); key_we = 1'b1; key_widx = 2'(i); key = k[127 - 32*i -: 32];
      end
      @(negedge clk); key_we = 1'b0;
    end
  endtask

  // one operation; returns the result, checks the latency
  task automatic run_op(input logic enc, input logic [127:0] data, output logic [127:0] res);
    int t;
    begin
      @(negedge clk); start = 1'b1; enc_dec = enc; din = data;
      @(negedge clk); start = 1'b0; din = ~data;
      t = 1;
      while (done !== 1'b1 && t < 200) begin @(negedge clk); t++; end
      check(t == 22, $sformatf("latency %0d", t));   // start edge + 21 busy cycles
      res = dout;
    end
  endtask

  task automatic kat(input logic [127:0] k, input logic [127:0] p, input logic [127:0] c, input string tag);
    logic [127:0] r;
    begin
      load_key(k);
      run_op(1, p, r); check(r === c, {tag, " encrypt"});
      run_op(0, c, r); check(r === p, {tag, " decrypt"});
    end
  endtask

  initial begin
    logic [127:0] r, k, p, c;
    repeat (3) @(negedge clk);
    check(!busy && !done && !irq && dout === 128'h0, "reset state");
    rst_n = 1;
    repeat (2) @(negedge clk);

    kat(128'h000102030405060708090a0b0c0d0e0f, 128'h00112233445566778899aabbccddeeff,
        128'h69c4e0d86a7b0430d8cdb78070b4c55a, "FIPS-197 C.1");
    kat(128'h0, 128'h0, 128'h66e94bd4ef8a2c3b884cfa59ca342b2e, "AESAVS zero");
    kat(128'h2b7e151628aed2a6abf7158809cf4f3c, 128'h6bc1bee22e409f96e93d7e117393172a,
        128'h3ad77bb40d7a3660a89ecaf32466ef97, "SP800-38A F.1.1");
    kat(128'hffffffffffffffffffffffffffffffff, 128'hffffffffffffffffffffffffffffffff,
        128'hbcbf217cb280cf30b2517052193ab979, "all ones");

    // random round trips
    for (int t = 0; t < 40; t++) begin
      k = {$urandom, $urandom, $urandom, $urandom};
      p = {$urandom, $urandom, $urandom, $urandom};
      load_key(k);
      run_op(1, p, c);
      run_op(0, c, r);
      check(r === p, "random round trip");
    end

    // violations while busy: ignored, irq
    load_key(128'h000102030405060708090a0b0c0d0e0f);
    irq_seen = 0;
    @(negedge clk); start = 1; enc_dec = 1; din = 128'h00112233445566778899aabbccddeeff;
    @(negedge clk); start = 0;
    repeat (3) @(negedge clk);
    key_we = 1; key_widx = 2; key = 32'hDEADBEEF; @(negedge clk); key_we = 0;
    repeat (3) @(negedge clk);
    start = 1; enc_dec = 0; din = '1; @(negedge clk); start = 0;
    while (!done) @(negedge clk);
    check(dout === 128'h69c4e0d86a7b0430d8cdb78070b4c55a && irq_seen, "violations ignored with irq");
    // start right in the done cycle, with a key write in the same idle cycle:
    // the start uses the key as it was before the write
    key_we = 1; key_widx = 0; key = 32'hFFFFFFFF; start = 1; enc_dec = 0; din = 128'h69c4e0d86a7b0430d8cdb78070b4c55a;
    @(negedge clk); key_we = 0; start = 0;
    while (!done) @(negedge clk);
    check(dout === 128'h00112233445566778899aabbccddeeff, "start with key write: old key used");
    run_op(1, 128'h00112233445566778899aabbccddeeff, c);
    run_op(0, c, r);
    check(c !== 128'h69c4e0d86a7b0430d8cdb78070b4c55a && r === 128'h00112233445566778899aabbccddeeff,
          "the next operation uses the new key word");

    // reset while busy
    @(negedge clk); start = 1; enc_dec = 1; @(negedge clk); start = 0;
    repeat (8) @(negedge clk);
    rst_n = 0; @(negedge clk);
    check(!busy && !done && dout === 128'h0, "reset while busy");
    rst_n = 1; repeat (2) @(negedge clk);
    kat(128'h000102030405060708090a0b0c0d0e0f, 128'h00112233445566778899aabbccddeeff,
        128'h69c4e0d86a7b0430d8cdb78070b4c55a, "after reset");

    // decrypt of all-zero and all-ones blocks (inverse round trip:
    // encrypting the result gives the block back), consecutive decrypts
    // and consecutive encrypts
    begin : dir_classes
      logic [127:0] r0, r1, e;
      load_key(128'h2b7e151628aed2a6abf7158809cf4f3c);
      run_op(0, 128'h0, r0);
      run_op(0, '1, r1);
      run_op(1, r0, e); check(e === 128'h0, "decrypt(0) inverse round trip");
      run_op(1, r1, e); check(e === '1, "decrypt(1s) inverse round trip");
    end

    if (errors == 0) $display("TEST PASSED: CSE");
    else             $display("TEST FAILED: %0d errors", errors);
    $finish;
  end

  initial begin
    repeat (200) #1000;
    $display("TEST FAILED: TIMEOUT"); $finish;
  end
endmodule
