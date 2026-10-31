// SPDX-License-Identifier: Apache-2.0
// ML_KEM_top testbench: runs the vectors in tb/ML_KEM_vec.hex (made by
// scripts/mlkem/gen_vec.py from the FIPS 203 model, which passes the NIST
// ACVP vectors, plus NIST ACVP cases): KeyGen, Encaps and Decaps for the
// three parameter sets, Decaps of modified ciphertexts (implicit rejection,
// which must take exactly as many clocks as the valid Decaps with the same
// key), reserved op / pset codes, start while busy, host back-pressure.
`timescale 1ns/1ps
module ML_KEM_tb;
  logic clk = 0, rst_n = 0;
  always #5 clk = ~clk;
  int errors = 0;
  task automatic fail(input string s);
    errors++;
    $display("ERROR: %s @%0t", s, $time);
  endtask

  logic        start = 0;
  logic [1:0]  op = 0, pset = 0;
  logic        busy, done, err;
  logic        hp_load = 0;
  logic [10:0] hp_addr = 0;
  logic        hw_valid = 0;
  logic [31:0] hw_data = 0;
  logic        hw_ready;
  logic        hr_en = 0;
  logic        hr_valid;
  logic [31:0] hr_data;
  logic        hr_ready = 0;
  ML_KEM_top dut (.*);

  logic [31:0] vec [0:200000];
  int vp = 0;
  task automatic cyc(input int n);
    repeat (n) @(posedge clk);
  endtask

  task automatic set_ptr(input logic [10:0] a);
    @(negedge clk); hp_load = 1; hp_addr = a;
    @(negedge clk); hp_load = 0;
  endtask

  // load n words from vec[vp..] at word address a, with random gaps
  task automatic load(input logic [10:0] a, input int n);
    set_ptr(a);
    for (int i = 0; i < n; i++) begin
      if ($urandom_range(0, 7) == 0) cyc(1);
      @(negedge clk); hw_valid = 1; hw_data = vec[vp + i];
      while (!hw_ready) @(negedge clk);
    end
    @(negedge clk); hw_valid = 0;
    vp += n;
  endtask

  // read n words back, compare with vec[vp..], random hr_ready stalls
  task automatic check(input logic [10:0] a, input int n, input string what);
    int bad;
    bad = 0;
    set_ptr(a);
    hr_en = 1;
    for (int i = 0; i < n; i++) begin
      @(negedge clk);
      hr_ready = $urandom_range(0, 3) != 0;
      while (!(hr_ready && hr_valid)) begin @(negedge clk); hr_ready = 1; end
      if (hr_data !== vec[vp + i]) begin
        if (bad < 3) fail($sformatf("%s word %0d: got %h want %h", what, i, hr_data, vec[vp + i]));
        bad++;
      end
      @(posedge clk);
    end
    @(negedge clk); hr_en = 0; hr_ready = 0;
    vp += n;
  endtask

  int cycles, last_dec;
  task automatic run(input logic [1:0] o, input logic [1:0] p, output int n);
    @(negedge clk); start = 1; op = o; pset = p;
    @(negedge clk); start = 0;
    if (!busy) fail("not busy after start");
    n = 1;
    // a second start while busy is ignored, and so are host writes and reads
    @(negedge clk); start = 1; op = 2'd3; @(negedge clk); start = 0; n += 2;
    hw_valid = 1; hw_data = 32'hDEAD_BEEF; hr_en = 1; hr_ready = 1;
    @(negedge clk); n++;
    #1;
    if (hw_ready || hr_valid) fail("host port open while busy");
    hw_valid = 0; hr_en = 0; hr_ready = 0;
    while (!done && n < 2000000) begin @(negedge clk); n++; end
    if (!done) fail("timeout");
    @(negedge clk);
    if (busy) fail("busy after done");
  endtask

  function automatic string opn(input logic [1:0] o);
    opn = o == 2'd0 ? "KeyGen" : o == 2'd1 ? "Encaps" : "Decaps";
  endfunction
  int ncase = 0;
  logic [10:0] ha [0:63];
  logic [31:0] hd [0:63];
  initial begin
    // the vectors, from the repository root, sim/ or the coverage build directory
    if ($fopen("tb/ML_KEM_vec.hex", "r") != 0) $readmemh("tb/ML_KEM_vec.hex", vec);
    else if ($fopen("../tb/ML_KEM_vec.hex", "r") != 0) $readmemh("../tb/ML_KEM_vec.hex", vec);
    else $readmemh("../../../../tb/ML_KEM_vec.hex", vec);
    cyc(3); rst_n = 1; cyc(2);
    // reserved op and pset
    @(negedge clk); start = 1; op = 2'd3; pset = 2'd0;
    @(negedge clk); start = 0;
    if (!err || busy) fail("reserved op not refused");
    @(negedge clk); start = 1; op = 2'd0; pset = 2'd3;
    @(negedge clk); start = 0;
    if (!err || busy) fail("reserved pset not refused");
    // host port: words at random addresses, read back in random order
    for (int i = 0; i < 64; i++) begin
      ha[i] = 11'($urandom); hd[i] = $urandom;
      for (int j = 0; j < i; j++) if (ha[j] == ha[i]) ha[i] = ha[i] ^ 11'h400;
    end
    for (int i = 0; i < 64; i++) begin
      set_ptr(ha[i]);
      @(negedge clk); hw_valid = 1; hw_data = hd[i];
      @(negedge clk); hw_valid = 0;
    end
    for (int i = 63; i >= 0; i--) begin
      set_ptr(ha[i]);
      @(negedge clk); hr_en = 1; hr_ready = 1;
      #1;
      if (!hr_valid || hr_data !== hd[i]) fail($sformatf("host word %h: got %h want %h", ha[i], hr_data, hd[i]));
      @(negedge clk); hr_en = 0; hr_ready = 0;
    end
    while (vec[vp] !== 32'hFFFFFFFF && errors < 20) begin : b_case
      logic [31:0] h;
      int nseg, nld;
      h = vec[vp]; vp++;
      if (h[31:24] !== 8'hA5) begin fail($sformatf("bad vector header %h at %0d", h, vp - 1)); $finish; end
      nseg = h[7:0];
      for (int s = 0; s < nseg; s++) begin : b_seg
        logic [31:0] g;
        g = vec[vp]; vp++;
        if (g[31]) begin
          if (cycles == 0) run(h[17:16], h[9:8], cycles);
          check(g[26:16], g[15:0], $sformatf("case %0d %s", ncase, opn(h[17:16])));
        end else begin
          if (s == 0) cycles = 0;
          load(g[26:16], g[15:0]);
        end
      end
      if (h[23] && cycles != last_dec)
        fail($sformatf("case %0d: Decaps of a modified ciphertext took %0d clocks, valid took %0d", ncase, cycles, last_dec));
      if (h[17:16] == 2'd2) last_dec = cycles;
      $display("case %0d: %s ML-KEM-%0d %0d clocks", ncase, opn(h[17:16]), 512 + 256 * h[9:8], cycles);
      ncase++;
    end
    // reset in the middle of an operation
    @(negedge clk); start = 1; op = 2'd2; pset = 2'd1;
    @(negedge clk); start = 0;
    cyc(5000);
    rst_n = 0; cyc(2);
    if (busy || done || err) fail("not idle in reset");
    rst_n = 1; cyc(2);
    if (!hw_ready) fail("host port closed after reset");
    cyc(5);
    if (errors == 0) $display("TEST PASSED: ML_KEM (%0d cases)", ncase);
    else $display("TEST FAILED: ML_KEM (%0d errors)", errors);
    $finish;
  end
endmodule
