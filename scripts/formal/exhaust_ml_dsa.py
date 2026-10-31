#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
"""Exhaustive check of the ML-DSA core's arithmetic: the functions and
tables are cut out of rtl/ML_DSA_top.sv as they are, wrapped in a test
module, and compared with their definitions for every input they can get
(Verilator):
  fold1, fold2, fold3           the reduction mod q = 2^23 - 2^13 + 1 of a product
                                of two values below q (below 2^46). Each fold maps
                                x = h 2^23 + l to h (2^13 - 1) + l: it keeps x mod q
                                for every h (h 2^23 = h (2^13 - 1) mod q is checked
                                for every h), and the bound for the next fold is
                                checked at l = 2^23 - 1 for every h; fold3 (with its
                                final subtraction) is checked for every input below
                                2^27.
  addq, subq                    for every a < q against b in {0, 1, q - 2, q - 1}
                                and 64 random b, and every b against the same a
                                (each is piecewise linear in either argument)
  absq                          for every x < q
  dquo, drem, dhi               Decompose (FIPS 204 Algorithm 36) for every r < q,
                                gamma2 = (q - 1) / 88 and (q - 1) / 32
  uhint                         UseHint (Algorithm 40) for every r < q, h in {0, 1},
                                both gamma2
  p2h, p2l                      Power2Round (Algorithm 35) for every r < q
  hb_ok, hb_val                 CoeffFromHalfByte (Algorithm 15), eta 2 and 4
  zeta(i)                       1753^BitRev8(i) mod q
  KRC                           the 24 round constants from the LFSR of FIPS 202
  python3 scripts/formal/exhaust_ml_dsa.py
"""
import os, re, subprocess, sys
root = os.path.join(os.path.dirname(os.path.abspath(__file__)), '..', '..')
os.chdir(root)
src = open('rtl/ML_DSA_top.sv').read()


def cut(pat, end):
    m = re.search(pat, src)
    if not m:
        sys.exit(f'not found: {pat}')
    return src[m.start():src.index(end, m.start()) + len(end)] + '\n'


parts = [cut(r"  localparam logic \[22:0\] Q = ", ';')]
for f in ['addq', 'subq', 'fold1', 'fold2', 'fold3', 'absq', 'dquo', 'drem', 'dhi', 'uhint', 'p2h', 'p2l',
          'hb_ok', 'hb_val', 'zeta']:
    parts.append(cut(r'  function automatic logic( \[\d+:0\])? ' + f + r'\(', 'endfunction'))
parts.append(cut(r'  localparam logic \[64\*24-1:0\] KRC', '};'))
test = r'''
  localparam longint QL = 8380417;
  function automatic int brv8(input int i);
    brv8 = 0;
    for (int b = 0; b < 8; b++) if (i & (1 << b)) brv8 |= 1 << (7 - b);
  endfunction
  int bad = 0;
  longint bs [0:67];
  initial begin
    // folds
    for (longint h = 0; h < (64'd1 << 23); h++) begin
      longint c, mx;
      c = longint'(fold1(46'(h << 23)));
      if (c % QL != (h << 23) % QL) begin if (bad < 5) $display("fold1 %0d", h); bad++; end
      mx = longint'(fold1(46'((h << 23) | 64'h7FFFFF)));
      if (mx != c + 64'h7FFFFF || mx >= (64'd1 << 36)) begin if (bad < 5) $display("fold1 bound %0d", h); bad++; end
    end
    for (longint h = 0; h < (64'd1 << 13); h++) begin
      longint c, mx;
      c = longint'(fold2(36'(h << 23)));
      if (c % QL != (h << 23) % QL) begin if (bad < 5) $display("fold2 %0d", h); bad++; end
      mx = longint'(fold2(36'((h << 23) | 64'h7FFFFF)));
      if (mx != c + 64'h7FFFFF || mx >= (64'd1 << 27)) begin if (bad < 5) $display("fold2 bound %0d", h); bad++; end
    end
    for (longint z = 0; z < (64'd1 << 27); z++)
      if (longint'(fold3(27'(z))) != z % QL) begin if (bad < 5) $display("fold3 %0d", z); bad++; end
    $display("fold1: 2^23 high parts, fold2: 2^13, fold3: 2^27 inputs");
    // addq, subq
    bs[0] = 0; bs[1] = 1; bs[2] = QL - 2; bs[3] = QL - 1;
    for (int i = 4; i < 68; i++) bs[i] = longint'($urandom) % QL;
    for (longint a = 0; a < QL; a++)
      foreach (bs[i]) begin
        longint b;
        b = bs[i];
        if (longint'(addq(23'(a), 23'(b))) != (a + b) % QL || longint'(addq(23'(b), 23'(a))) != (a + b) % QL ||
            longint'(subq(23'(a), 23'(b))) != (a - b + QL) % QL || longint'(subq(23'(b), 23'(a))) != (b - a + QL) % QL)
          begin if (bad < 5) $display("addq/subq %0d %0d", a, b); bad++; end
      end
    $display("addq, subq: every a against 68 b, both orders");
    // absq, Decompose, UseHint, Power2Round
    for (longint r = 0; r < QL; r++) begin
      longint ab, r0, t1;
      ab = r > (QL - 1) / 2 ? QL - r : r;
      if (longint'(absq(23'(r))) != ab) begin if (bad < 5) $display("absq %0d", r); bad++; end
      for (int g = 0; g < 2; g++) begin
        longint g2, m, er0, er1, q1, gr0, gr1;
        g2 = g ? (QL - 1) / 32 : (QL - 1) / 88;
        m = (QL - 1) / (2 * g2);
        er0 = r % (2 * g2);
        if (er0 > g2) er0 -= 2 * g2;
        if (r - er0 == QL - 1) begin er1 = 0; er0 = er0 - 1; end
        else er1 = (r - er0) / (2 * g2);
        q1 = longint'(dquo(23'(r), g[0]));
        gr1 = longint'(dhi(6'(q1), g[0]));
        gr0 = longint'(signed'(drem(23'(r), 6'(q1), g[0])));
        if (gr1 != er1 || gr0 != er0) begin if (bad < 5) $display("decompose %0d g%0d", r, g); bad++; end
        for (int h = 0; h < 2; h++) begin
          longint eu;
          eu = h == 0 ? er1 : er0 > 0 ? (er1 + 1) % m : (er1 - 1 + m) % m;
          if (longint'(uhint(h[0], 6'(gr1), drem(23'(r), 6'(q1), g[0]), g[0])) != eu) begin
            if (bad < 5) $display("usehint %0d g%0d h%0d", r, g, h); bad++;
          end
        end
      end
      r0 = r % 8192;
      if (r0 > 4096) r0 -= 8192;
      t1 = (r - r0) / 8192;
      if (longint'(p2h(23'(r))) != t1 || longint'(p2l(23'(r), p2h(23'(r)))) != 4096 - r0) begin
        if (bad < 5) $display("power2round %0d", r); bad++;
      end
    end
    $display("absq, Decompose, UseHint, Power2Round: every r < q");
    for (int b = 0; b < 16; b++)
      for (int e = 0; e < 2; e++) begin
        bit ok;
        int v;
        ok = e ? b < 9 : b < 15;
        v = e ? 4 - b : 2 - b % 5;
        if (hb_ok(4'(b), e[0]) != ok || ok && longint'(hb_val(4'(b), e[0])) != (v + QL) % QL) begin
          $display("half byte %0d eta%0d", b, e ? 4 : 2); bad++;
        end
      end
    for (int i = 0; i < 256; i++) begin
      longint p;
      p = 1;
      for (int n = 0; n < brv8(i); n++) p = p * 1753 % QL;
      if (longint'(zeta(8'(i))) != p) begin $display("zeta %0d", i); bad++; end
    end
    $display("CoeffFromHalfByte: 16 x 2, zeta: 256 entries");
    begin
      logic [7:0] r;
      logic [63:0] rc;
      r = 8'h01;
      for (int t = 0; t < 24; t++) begin
        rc = '0;
        for (int j = 0; j < 7; j++) begin
          rc[(1 << j) - 1] = r[0];
          r = {r[6:0], 1'b0} ^ (r[7] ? 8'h71 : 8'h00);
        end
        if (KRC[64 * t +: 64] != rc) begin $display("KRC %0d", t); bad++; end
      end
    end
    $display("KRC: 24 round constants");
    if (bad == 0) $display("EXHAUSTIVE PASS: ML_DSA arithmetic");
    else $display("EXHAUSTIVE FAIL: %0d mismatches", bad);
    $finish;
  end
'''
w = 'work/formal/ML_DSA'
os.makedirs(w, exist_ok=True)
open(f'{w}/arith.sv', 'w').write('module arith;\n' + ''.join(parts) + test + 'endmodule\n')
subprocess.run(['verilator', '--binary', '-O3', '-Wno-fatal', '-Wno-lint', '-Wno-style', '--top-module', 'arith',
                '--Mdir', f'{w}/obj', f'{w}/arith.sv'], check=True, stdout=subprocess.DEVNULL)
out = subprocess.run([f'{w}/obj/Varith'], capture_output=True, text=True).stdout
print(out, end='')
sys.exit(0 if 'EXHAUSTIVE PASS' in out else 1)
