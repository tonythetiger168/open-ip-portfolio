// SPDX-License-Identifier: Apache-2.0
// ML_DSA_top testbench: runs the vectors in tb/ML_DSA_vec.hex (made by
// scripts/mldsa/gen_vec.py from the FIPS 204 model, which passes the NIST
// ACVP vectors, plus NIST ACVP cases): KeyGen, Sign (deterministic and
// hedged, with M' or an external mu; the attempt count of the rejection
// loop is checked) and Verify (valid signatures and ones with a modified
// c~, z, hint encoding or message) for the three parameter sets; reserved
// op / pset / mlen, start while busy, host back-pressure, reset mid-run.
`timescale 1ns/1ps
module ML_DSA_tb;
  logic clk = 0, rst_n = 0;
  always #5 clk = ~clk;
  int errors = 0;
  task automatic fail(input string s);
    errors++;
    $display("ERROR: %s @%0t", s, $time);
  endtask

  logic        start = 0;
  logic [1:0]  op = 0, pset = 0;
  logic        ext_mu = 0;
  logic [14:0] mlen = 0;
  logic        busy, done, err, fail_o;
  logic [15:0] tries;
  logic        hp_load = 0;
  logic [12:0] hp_addr = 0;
  logic        hw_valid = 0;
  logic [31:0] hw_data = 0;
  logic        hw_ready;
  logic        hr_en = 0;
  logic        hr_valid;
  logic [31:0] hr_data;
  logic        hr_ready = 0;
  ML_DSA_top dut (.fail(fail_o), .*);

  logic [31:0] vec [0:400000];
  int vp = 0;
  task automatic cyc(input int n);
    repeat (n) @(posedge clk);
  endtask

  task automatic set_ptr(input logic [12:0] a);
    @(negedge clk); hp_load = 1; hp_addr = a;
    @(negedge clk); hp_load = 0;
  endtask

  // load n words from vec[vp..] at word address a, with random gaps
  task automatic load(input logic [12:0] a, input int n);
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
  task automatic check(input logic [12:0] a, input int n, input logic [1:0] pad, input string what);
    int bad;
    logic [31:0] msk;
    bad = 0;
    set_ptr(a);
    hr_en = 1;
    for (int i = 0; i < n; i++) begin
      @(negedge clk);
      hr_ready = $urandom_range(0, 3) != 0;
      while (!(hr_ready && hr_valid)) begin @(negedge clk); hr_ready = 1; end
      msk = i == n - 1 ? 32'hFFFF_FFFF >> (8 * pad) : 32'hFFFF_FFFF;
      if ((hr_data & msk) !== vec[vp + i]) begin
        if (bad < 3) fail($sformatf("%s word %0d: got %h want %h", what, i, hr_data, vec[vp + i]));
        bad++;
      end
      @(posedge clk);
    end
    @(negedge clk); hr_en = 0; hr_ready = 0;
    vp += n;
  endtask

  int cycles;
  task automatic run(input logic [1:0] o, input logic [1:0] p, input logic e, input logic [14:0] ml, output int n);
    @(negedge clk); start = 1; op = o; pset = p; ext_mu = e; mlen = ml;
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
    while (!done && n < 20000000) begin @(negedge clk); n++; end
    if (!done) fail("timeout");
    @(negedge clk);
    if (busy) fail("busy after done");
  endtask

  function automatic string opn(input logic [1:0] o);
    opn = o == 2'd0 ? "KeyGen" : o == 2'd1 ? "Sign" : "Verify";
  endfunction
  function automatic string note(input logic [1:0] o);
    note = "";
    if (o == 2'd1) note = $sformatf(", %0d attempts", tries);
    if (o == 2'd2) note = fail_o ? ", rejected" : ", valid";
  endfunction
  int ncase = 0;
  logic [12:0] ha [0:63];
  logic [31:0] hd [0:63];
  initial begin
    // the vectors, from the repository root, sim/ or the coverage build directory
    if ($fopen("tb/ML_DSA_vec.hex", "r") != 0) $readmemh("tb/ML_DSA_vec.hex", vec);
    else if ($fopen("../tb/ML_DSA_vec.hex", "r") != 0) $readmemh("../tb/ML_DSA_vec.hex", vec);
    else $readmemh("../../../../tb/ML_DSA_vec.hex", vec);
    cyc(3); rst_n = 1; cyc(2);
    // reserved op, pset, message length
    @(negedge clk); start = 1; op = 2'd3; pset = 2'd0;
    @(negedge clk); start = 0;
    if (!err || busy) fail("reserved op not refused");
    @(negedge clk); start = 1; op = 2'd0; pset = 2'd3;
    @(negedge clk); start = 0;
    if (!err || busy) fail("reserved pset not refused");
    @(negedge clk); start = 1; op = 2'd1; pset = 2'd0; mlen = 15'd16385;
    @(negedge clk); start = 0;
    if (!err || busy) fail("message length over 16384 not refused");
    // host port: words at random addresses, read back in random order
    for (int i = 0; i < 64; i++) begin
      ha[i] = 13'($urandom); hd[i] = $urandom;
      for (int j = 0; j < i; j++) if (ha[j] == ha[i]) ha[i] = ha[i] ^ 13'h1000;
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
      logic [31:0] h, h2;
      int nseg;
      h = vec[vp]; h2 = vec[vp + 1]; vp += 2;
      if (h[31:24] !== 8'hA5) begin fail($sformatf("bad vector header %h at %0d", h, vp - 2)); $finish; end
      nseg = h[7:0];
      cycles = 0;
      for (int s = 0; s <= nseg; s++) begin : b_seg
        logic [31:0] g;
        g = s < nseg ? vec[vp] : 32'h8000_0000;
        if (g[31] && cycles == 0) begin
          run(h[17:16], h[9:8], h[23], h2[14:0], cycles);
          if (fail_o !== h2[31])
            fail($sformatf("case %0d %s: fail %b want %b", ncase, opn(h[17:16]), fail_o, h2[31]));
          if (h[17:16] == 2'd1 && tries !== {1'b0, h2[30:16]})
            fail($sformatf("case %0d Sign: %0d attempts, want %0d", ncase, tries, h2[30:16]));
        end
        if (s < nseg) begin
          vp++;
          if (g[31]) check(g[28:16], g[15:0], g[30:29], $sformatf("case %0d %s", ncase, opn(h[17:16])));
          else load(g[28:16], g[15:0]);
        end
      end
      $display("case %0d: %s ML-DSA-%0d%s %0d clocks%s", ncase, opn(h[17:16]), h[9:8] == 0 ? 44 : h[9:8] == 1 ? 65 : 87,
               h[23] ? " (external mu)" : "", cycles, note(h[17:16]));
      ncase++;
    end
    // reset in the middle of an operation
    @(negedge clk); start = 1; op = 2'd1; pset = 2'd1; ext_mu = 1;
    @(negedge clk); start = 0;
    cyc(5000);
    rst_n = 0; cyc(2);
    if (busy || done || err) fail("not idle in reset");
    rst_n = 1; cyc(2);
    if (!hw_ready) fail("host port closed after reset");
    cyc(5);
    if (errors == 0) $display("TEST PASSED: ML_DSA (%0d cases)", ncase);
    else $display("TEST FAILED: ML_DSA (%0d errors)", errors);
    $finish;
  end
endmodule
