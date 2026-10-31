#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
"""Exhaustive check of the Ethernet RS-FEC core's arithmetic: the functions
and constant tables are cut out of rtl/Ethernet_RS_FEC_top.sv as they are,
wrapped in a test module and compared with their definitions (Verilator):
  gmul(a, b)        for every pair, against shift-and-add with x^10 = x^3 + 1
  ginv(a)           a * ginv(a) == 1 for every a != 0, ginv(0) == 0
  every M_* table   the datapath applies them as y = M x over GF(2), so
                    checking every unit vector x checks every input: each
                    column is compared with the definition, computed here
                    from alpha = x (the powers of alpha by repeated
                    multiplication), g(x) = prod (x - alpha^j) and x^e mod g
                    by long division
  python3 scripts/formal/exhaust_ethfec.py
"""
import os, re, subprocess, sys
root = os.path.join(os.path.dirname(os.path.abspath(__file__)), '..', '..')
os.chdir(root)
src = open('rtl/Ethernet_RS_FEC_top.sv').read()


def cut(pat, end):
    m = re.search(pat, src)
    if not m:
        sys.exit(f'not found: {pat}')
    return src[m.start():src.index(end, m.start()) + len(end)] + '\n'


MAPS = [  # name, inputs, outputs, reference (SV expression filling z from x)
    ('M_ENC', 620, 300, 'renc(x, 32)'), ('M_ENCL', 320, 300, 'renc(620\'(x), 2)'),
    ('M_SYN', 620, 300, 'rsyn(x)'),
    ('M_LAM', 160, 320, 'rev(x, 0, 16, 3)'), ('M_LE', 160, 320, 'rev(x, 0, 16, 1)'),
    ('M_LO', 160, 320, 'rev(x, 0, 16, 2)'), ('M_W', 150, 320, 'rev(160\'(x), 30, 15, 3)'),
    ('M_UPL', 160, 160, 'rsc(x, 0, 16, 32)'), ('M_UPW', 150, 150, 'rsc(160\'(x), 30, 15, 32)'),
    ('M_SCL', 160, 160, 'rsc(x, 0, 16, 480)'), ('M_SCW', 150, 150, 'rsc(160\'(x), 30, 15, 480)'),
    ('M_SQ1', 10, 10, 'rpw(x, 2)'), ('M_SQ2', 10, 10, 'rpw(x, 4)'), ('M_SQ4', 10, 10, 'rpw(x, 16)'),
]
parts = []
for n, _, _, _ in MAPS:
    parts.append(cut(r'  localparam logic \[\d+:0\] ' + n + r' = \{', '};'))
for f in ['gmul', 'lin10', 'ginv']:
    parts.append(cut(r'  function automatic logic \[9:0\] ' + f + r'\(', 'endfunction'))

checks = []
for n, ni, no, ref in MAPS:
    checks.append(f'''
    for (int j = 0; j < {ni}; j++) begin : c_{n}
      logic [{ni - 1}:0] x;
      logic [{no - 1}:0] y, z;
      x = '0; x[j] = 1'b1;
      for (int o = 0; o < {no}; o++) y[o] = ^(x & {n}[{ni}*o +: {ni}]);
      z = {no}'({ref});
      if (y != z) begin if (bad < 5) $display("{n} column %0d", j); bad++; end
    end
    $display("{n}: {ni} columns");''')

test = r'''
  int ex [0:2045];
  int lg [0:1023];
  logic [9:0] gpol [0:30];                   // g(x), lowest degree first
  logic [9:0] pmod [0:61][0:29];             // x^e mod g
  int bad = 0;
  function automatic logic [9:0] ref_mul(input logic [9:0] a, input logic [9:0] b);
    logic [19:0] p;
    p = '0;
    for (int i = 0; i < 10; i++) if (b[i]) p = p ^ (20'(a) << i);
    for (int i = 19; i >= 10; i--) if (p[i]) p = p ^ (20'h409 << (i - 10));
    ref_mul = p[9:0];
  endfunction
  function automatic logic [9:0] al(input int e);
    al = 10'(ex[e % 1023]);
  endfunction
  function automatic logic [299:0] renc(input logic [619:0] x, input int n);
    logic [299:0] z;
    z = '0;
    for (int i = 0; i < 30; i++)
      for (int j = 0; j < 30; j++) z[10*j +: 10] ^= ref_mul(x[10*i +: 10], pmod[i + n][j]);
    for (int k = 0; k < n; k++)
      for (int j = 0; j < 30; j++) z[10*j +: 10] ^= ref_mul(x[300 + 10*k +: 10], pmod[n - 1 - k + 30][j]);
    renc = z;
  endfunction
  function automatic logic [299:0] rsyn(input logic [619:0] x);
    logic [299:0] z;
    for (int j = 0; j < 30; j++) begin
      z[10*j +: 10] = ref_mul(x[10*j +: 10], al(32 * j));
      for (int k = 0; k < 32; k++) z[10*j +: 10] ^= ref_mul(x[300 + 10*k +: 10], al(j * (31 - k)));
    end
    rsyn = z;
  endfunction
  // sel: 1 even terms, 2 odd terms, 3 all
  function automatic logic [319:0] rev(input logic [159:0] x, input int off, input int n, input int sel);
    logic [319:0] z;
    z = '0;
    for (int k = 0; k < 32; k++)
      for (int i = 0; i < n; i++)
        if (sel[i % 2]) z[10*k +: 10] ^= ref_mul(x[10*i +: 10], al((i + off) * k));
    rev = z;
  endfunction
  function automatic logic [159:0] rsc(input logic [159:0] x, input int off, input int n, input int e);
    logic [159:0] z;
    z = '0;
    for (int i = 0; i < n; i++) z[10*i +: 10] = ref_mul(x[10*i +: 10], al(e * (i + off)));
    rsc = z;
  endfunction
  function automatic logic [9:0] rpw(input logic [9:0] x, input int e);
    logic [9:0] z;
    z = 10'd1;
    for (int i = 0; i < e; i++) z = ref_mul(z, x);
    rpw = z;
  endfunction
  initial begin
    logic [9:0] x, top;
    logic [9:0] r [0:29];
    x = 10'd1;
    for (int i = 0; i < 1023; i++) begin
      ex[i] = int'(x); ex[i + 1023] = int'(x); lg[x] = i;
      x = ref_mul(x, 10'd2);
    end
    for (int i = 0; i <= 30; i++) gpol[i] = '0;
    gpol[0] = 10'd1;
    for (int j = 0; j < 30; j++)
      for (int i = j + 1; i >= 0; i--) gpol[i] = (i > 0 ? gpol[i - 1] : 10'd0) ^ ref_mul(gpol[i], al(j));
    for (int e = 0; e < 62; e++) begin       // x^e mod g by long division
      for (int j = 0; j < 30; j++) r[j] = '0;
      r[0] = 10'd1;
      for (int s = 0; s < e; s++) begin
        top = r[29];
        for (int j = 29; j > 0; j--) r[j] = r[j - 1] ^ ref_mul(top, gpol[j]);
        r[0] = ref_mul(top, gpol[0]);
      end
      for (int j = 0; j < 30; j++) pmod[e][j] = r[j];
    end
    for (int a = 0; a < 1024; a++)
      for (int b = 0; b < 1024; b++)
        if (gmul(10'(a), 10'(b)) != ref_mul(10'(a), 10'(b))) begin
          if (bad < 5) $display("gmul %0d %0d", a, b); bad++;
        end
    $display("gmul: 2^20 pairs");
    if (ginv(10'd0) != 10'd0) begin $display("ginv 0"); bad++; end
    for (int a = 1; a < 1024; a++)
      if (ref_mul(10'(a), ginv(10'(a))) != 10'd1) begin if (bad < 5) $display("ginv %0d", a); bad++; end
    $display("ginv: 1024 inputs");
''' + ''.join(checks) + r'''
    if (bad == 0) $display("EXHAUSTIVE PASS");
    else $display("EXHAUSTIVE FAIL: %0d", bad);
    $finish;
  end
'''
out = 'work/formal/exhaust_ethfec'
os.makedirs(out, exist_ok=True)
with open(f'{out}/t.sv', 'w') as f:
    f.write('module t;\n' + ''.join(parts) + test + 'endmodule\n')
subprocess.run(['verilator', '--binary', '-j', '4', '-Wno-fatal', '-Wno-lint', '-Wno-style', '--top-module', 't',
                '--Mdir', f'{out}/obj', f'{out}/t.sv'], check=True, stdout=subprocess.DEVNULL)
r = subprocess.run([f'{out}/obj/Vt'], capture_output=True, text=True)
print(r.stdout.strip())
sys.exit(0 if 'EXHAUSTIVE PASS' in r.stdout else 1)
