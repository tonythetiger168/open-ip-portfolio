// SPDX-License-Identifier: Apache-2.0
// SHA3_tb: self-checking testbench. Cases from scripts/sha3/gen_vec.py
// (digests and SHAKE streams from Python's hashlib) are streamed in with
// random gaps, random junk above in_bytes, both encodings of a message that
// fills its last word (a full last word, or a full word then an empty last
// word) and random output back-pressure. Then the error and abort cases:
// a short word without in_last and in_bytes > 8 (dropped with err), start
// in every state, the reserved modes and a reset in the middle of a hash.
`timescale 1ns/1ps
module SHA3_tb;
  logic        clk = 1'b0, rst_n = 1'b0;
  always #5 clk = ~clk;
  logic        start;
  logic [2:0]  mode;
  logic        in_valid, in_last, in_ready;
  logic [63:0] in_data;
  logic [3:0]  in_bytes;
  logic        out_valid, out_last, out_ready;
  logic [63:0] out_data;
  logic        busy, done, err;

  SHA3_top u_dut (.*);

  localparam int NV = 8192;
  logic [63:0] vec [0:NV-1];
  int errors = 0, ncase = 0, nerr = 0, ndone = 0;
  always @(negedge clk) begin           // pulses are counted half a clock after they rise
    if (err) nerr++;
    if (done) ndone++;
  end
  task automatic fail(input string m);
    $display("FAIL @%0t: %s", $time, m); errors++;
  endtask

  int gap_in, gap_out;                  // percent of clocks without valid / ready
  task automatic idle_bus;
    in_valid = 1'b0; in_last = 1'b0; in_bytes = 4'd8; in_data = $urandom; out_ready = 1'b0; start = 1'b0;
  endtask
  task automatic do_start(input logic [2:0] m);
    @(negedge clk); start = 1'b1; mode = m;
    @(negedge clk); start = 1'b0; mode = 3'($urandom);
  endtask
  // one message word; junk above nb
  task automatic put(input logic [63:0] w, input int nb, input bit last);
    logic [63:0] junk;
    junk = {$urandom, $urandom};
    @(negedge clk);
    while ($urandom_range(0, 99) < gap_in) begin in_valid = 1'b0; in_data = junk; @(negedge clk); end
    in_valid = 1'b1; in_last = last; in_bytes = 4'(nb);
    in_data = (nb >= 8) ? w : ((w & ((64'h1 << (8 * nb)) - 1)) | (junk & ~((64'h1 << (8 * nb)) - 1)));
    @(posedge clk);
    while (!in_ready) @(posedge clk);
    #1 in_valid = 1'b0; in_last = 1'b0;
  endtask
  // read one output word and compare
  task automatic get(input logic [63:0] exp, input bit last_exp, input string tag);
    @(negedge clk);
    while ($urandom_range(0, 99) < gap_out) begin out_ready = 1'b0; @(negedge clk); end
    out_ready = 1'b1;
    @(posedge clk);
    while (!out_valid) @(posedge clk);
    if (out_data !== exp) fail($sformatf("%s: out %h, expected %h", tag, out_data, exp));
    if (out_last !== last_exp) fail($sformatf("%s: out_last %b, expected %b", tag, out_last, last_exp));
    #1 out_ready = 1'b0;
  endtask

  // run the case at vec[p]; returns the index after it
  int p;
  task automatic run_case(input bit bad_word, input bit abort_xof);
    logic [2:0] m;
    int nb, ow, nw, d0;
    m  = vec[p][58:56];
    ow = int'(vec[p][55:40]);
    nb = int'(vec[p][31:0]);
    nw = (nb + 7) / 8;
    d0 = ndone;
    do_start(m);
    if (!busy) fail("busy low after start");
    for (int i = 0; i < nw; i++) begin
      bit last;
      int b;
      last = (i == nw - 1);
      b = last ? nb - 8 * i : 8;
      if (bad_word && i == nw / 2) begin
        int e0;
        e0 = nerr;
        if ($urandom_range(0, 1)) put({$urandom, $urandom}, $urandom_range(0, 7), 1'b0);   // short, not last
        else put({$urandom, $urandom}, $urandom_range(9, 15), 1'($urandom_range(0, 1)));  // more than 8 bytes
        @(negedge clk); #1;
        if (nerr != e0 + 1) fail("bad word: no err pulse");
      end
      if (last && b == 8 && $urandom_range(0, 1)) begin
        put(vec[p + 1 + i], 8, 1'b0);   // the other encoding: an empty last word
        put({$urandom, $urandom}, 0, 1'b1);
      end else put(vec[p + 1 + i], b, last);
    end
    if (nw == 0) put({$urandom, $urandom}, 0, 1'b1);
    for (int i = 0; i < ow; i++)
      get(vec[p + 1 + nw + i], (m < 3'd4) && (i == ow - 1), $sformatf("case %0d mode %0d len %0d word %0d", ncase, m, nb, i));
    if (m < 3'd4) begin
      @(negedge clk); #1;
      if (ndone != d0 + 1) fail("no done pulse after the digest");
      if (busy) fail("busy after the digest");
      if (u_dut.ks !== '0) fail("state not cleared after the digest");
    end else begin
      repeat ($urandom_range(0, 30)) @(negedge clk);
      if (abort_xof) begin
        do_start(3'd6 + 3'($urandom_range(0, 1)));
        if (busy || u_dut.ks !== '0) fail("reserved mode did not wipe the SHAKE state");
      end
    end
    p = p + 1 + nw + ow;
    ncase++;
  endtask

  initial begin
    // run from the repo root (make), sim/ or a coverage build directory
    if ($fopen("tb/SHA3_vec.hex", "r") != 0) $readmemh("tb/SHA3_vec.hex", vec);
    else if ($fopen("../tb/SHA3_vec.hex", "r") != 0) $readmemh("../tb/SHA3_vec.hex", vec);
    else $readmemh("../../../../tb/SHA3_vec.hex", vec);
    idle_bus(); mode = '0;
    repeat (3) @(negedge clk);
    if (busy || in_ready || out_valid || done || err) fail("outputs not at their reset values");
    rst_n = 1'b1;
    // ---- all vectors, three passes with different bus timing ----
    for (int pass = 0; pass < 3; pass++) begin
      gap_in  = (pass == 0) ? 0 : (pass == 1) ? 30 : 70;
      gap_out = (pass == 0) ? 0 : (pass == 1) ? 50 : 20;
      p = 0;
      while (vec[p][63:56] != 8'hFF) run_case(pass == 2 && ($urandom_range(0, 3) == 0), $urandom_range(0, 1));
    end
    $display("vectors: %0d cases", ncase);

    // ---- start in the middle of absorbing, permuting and squeezing ----
    gap_in = 0; gap_out = 0;
    for (int k = 0; k < 40; k++) begin
      int q;
      p = 0;
      q = $urandom_range(0, 40);
      while (q > 0 && vec[p][63:56] != 8'hFF) begin
        p = p + 1 + int'((vec[p][31:0] + 7) / 8) + int'(vec[p][55:40]);
        q--;
      end
      if (vec[p][63:56] == 8'hFF) p = 0;
      do_start(3'($urandom_range(0, 5)));
      repeat ($urandom_range(0, 25)) put({$urandom, $urandom}, 8, 1'b0);   // up to a full block or two
      if ($urandom_range(0, 1)) put({$urandom, $urandom}, $urandom_range(0, 8), 1'b1);
      repeat ($urandom_range(0, 30)) @(negedge clk);
      if ($urandom_range(0, 1)) begin
        @(negedge clk); out_ready = 1'b1; repeat ($urandom_range(0, 3)) @(negedge clk); out_ready = 1'b0;
      end
      run_case(1'b0, 1'b0);             // the new start abandons whatever was running
    end
    // ---- start while a full block is being permuted ----
    for (int k = 0; k < 4; k++) begin
      do_start(3'd3);                   // SHA3-512: 9 words a block
      repeat (9) put({$urandom, $urandom}, 8, 1'b0);
      repeat ($urandom_range(0, 20)) @(negedge clk);
      if (in_ready) fail("in_ready during the permutation");
      p = 0;
      run_case(1'b0, 1'b0);
    end
    // ---- reserved modes from idle ----
    for (int k = 0; k < 4; k++) begin
      int e0;
      e0 = nerr;
      do_start(3'd6 + 3'(k % 2));
      @(negedge clk); #1;
      if (nerr != e0 + 1 || busy) fail("reserved mode: no err or busy");
    end
    // ---- words while idle are not taken ----
    @(negedge clk); in_valid = 1'b1; in_last = 1'b1; in_bytes = 4'd8;
    repeat (3) begin @(posedge clk); if (in_ready) fail("in_ready while idle"); end
    #1 in_valid = 1'b0;
    // ---- reset in the middle of a hash, then a clean hash ----
    for (int k = 0; k < 6; k++) begin
      do_start(3'($urandom_range(0, 5)));
      repeat ($urandom_range(1, 25)) put({$urandom, $urandom}, 8, 1'b0);
      repeat ($urandom_range(0, 20)) @(negedge clk);
      rst_n = 1'b0; @(negedge clk);
      if (busy || out_valid || done || err || u_dut.ks !== '0) fail("reset did not clear the core");
      rst_n = 1'b1;
      p = 0;
      run_case(1'b0, 1'b0);
    end
    repeat (5) @(negedge clk);
    $display("%0d cases, %0d err pulses, %0d done pulses", ncase, nerr, ndone);
    if (errors == 0) $display("TEST PASSED");
    else $display("TEST FAILED: %0d errors", errors);
    $finish;
  end
  initial begin
    #50ms;
    $display("TEST FAILED: timeout");
    $finish;
  end
endmodule
