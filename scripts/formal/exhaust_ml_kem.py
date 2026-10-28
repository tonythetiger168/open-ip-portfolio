#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
"""Exhaustive check of the ML-KEM core's arithmetic: the functions and
tables are cut out of rtl/ML_KEM_top.sv as they are, wrapped in a test
module, and compared with their definitions for every input they can get
(Verilator):
  mred(x) == x mod q            for every x < 2^25 (products are < 2^24)
  addq, subq                    for every a, b < q
  compress_d, decompress_d      for every input, d in {1, 4, 5, 10, 11}
  pop3                          for every input
  zeta(i), gamma(i)             17^BitRev7(i), 17^(2 BitRev7(i) + 1) mod q
  KRC                           the 24 round constants from the LFSR of FIPS 202
  python3 scripts/formal/exhaust_ml_kem.py
"""
import os, re, subprocess, sys
root = os.path.join(os.path.dirname(os.path.abspath(__file__)), '..', '..')
os.chdir(root)
src = open('rtl/ML_KEM_top.sv').read()


def cut(pat, end):
    m = re.search(pat, src)
    if not m:
        sys.exit(f'not found: {pat}')
    return src[m.start():src.index(end, m.start()) + len(end)] + '\n'


parts = [cut(r"  localparam logic \[11:0\] Q = ", ';')]
for f in ['mred', 'addq', 'subq', 'compress', 'decompress', 'pop3', 'zeta', 'gamma']:
    parts.append(cut(r'  function automatic logic \[\d+:0\] ' + f + r'\(', 'endfunction'))
parts.append(cut(r'  localparam logic \[64\*24-1:0\] KRC', '};'))
test = r'''
  function automatic int brv7(input int i);
    brv7 = 0;
    for (int b = 0; b < 7; b++) if (i & (1 << b)) brv7 |= 1 << (6 - b);
  endfunction
  function automatic int pw17(input int e);
    pw17 = 1;
    for (int n = 0; n < e; n++) pw17 = pw17 * 17 % 3329;
  endfunction
  int bad = 0;
  int ds [0:4] = '{1, 4, 5, 10, 11};
  initial begin
    for (int x = 0; x < (1 << 25); x++)
      if (int'(mred(25'(x))) != x % 3329) begin if (bad < 5) $display("mred %0d", x); bad++; end
    $display("mred: 2^25 inputs");
    for (int a = 0; a < 3329; a++)
      for (int b = 0; b < 3329; b++) begin
        if (int'(addq(12'(a), 12'(b))) != (a + b) % 3329) begin if (bad < 5) $display("addq %0d %0d", a, b); bad++; end
        if (int'(subq(12'(a), 12'(b))) != (a - b + 3329) % 3329) begin if (bad < 5) $display("subq %0d %0d", a, b); bad++; end
      end
    $display("addq, subq: q^2 inputs each");
    foreach (ds[k]) begin
      int d;
      d = ds[k];
      for (int x = 0; x < 3329; x++)
        if (int'(compress(12'(x), 4'(d))) != ((x << (d + 1)) + 3329) / 6658 % (1 << d)) begin
          if (bad < 5) $display("compress %0d %0d", x, d); bad++;
        end
      for (int y = 0; y < (1 << d); y++)
        if (int'(decompress(12'(y), 4'(d))) != (3329 * y * 2 + (1 << d)) >> (d + 1)) begin
          if (bad < 5) $display("decompress %0d %0d", y, d); bad++;
        end
    end
    $display("compress, decompress: d = 1, 4, 5, 10, 11");
    for (int b = 0; b < 16; b++)
      if (int'(pop3(3'(b), b[3])) != (b & 1) + (b >> 1 & 1) + (b[3] ? b >> 2 & 1 : 0)) begin $display("pop3 %0d", b); bad++; end
    for (int i = 0; i < 128; i++) begin
      if (int'(zeta(7'(i))) != pw17(brv7(i))) begin $display("zeta %0d", i); bad++; end
      if (int'(gamma(7'(i))) != pw17(2 * brv7(i) + 1)) begin $display("gamma %0d", i); bad++; end
    end
    $display("zeta, gamma: 128 entries each");
    begin
      logic [7:0] r;
      logic [63:0] rc;
      r = 8'h01;
      for (int t = 0; t < 24; t++) begin
        rc = '0;
        for (int j = 0; j < 7; j++) begin
          rc[(1 << j) - 1] = r[0];
          for (int n = 0; n < 1; n++) r = {r[6:0], 1'b0} ^ (r[7] ? 8'h71 : 8'h00);
        end
        if (KRC[64 * t +: 64] != rc) begin $display("KRC %0d", t); bad++; end
      end
    end
    $display("KRC: 24 round constants");
    if (bad == 0) $display("EXHAUSTIVE PASS: ML_KEM arithmetic");
    else $display("EXHAUSTIVE FAIL: %0d mismatches", bad);
    $finish;
  end
'''
w = 'work/formal/ML_KEM'
os.makedirs(w, exist_ok=True)
open(f'{w}/arith.sv', 'w').write('module arith;\n' + ''.join(parts) + test + 'endmodule\n')
subprocess.run(['verilator', '--binary', '-O3', '-Wno-fatal', '-Wno-lint', '-Wno-style', '--top-module', 'arith',
                '--Mdir', f'{w}/obj', f'{w}/arith.sv'], check=True, stdout=subprocess.DEVNULL)
out = subprocess.run([f'{w}/obj/Varith'], capture_output=True, text=True).stdout
print(out, end='')
sys.exit(0 if 'EXHAUSTIVE PASS' in out else 1)
