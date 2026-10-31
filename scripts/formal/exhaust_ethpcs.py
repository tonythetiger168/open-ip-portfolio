#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
"""Exhaustive checks of the Ethernet PCS core's data functions and gearboxes.

1. The functions are cut out of rtl/Ethernet_PCS_top.sv as they are and
   compared (Verilator) with the bit-serial versions in the core checker
   tb/cov/Ethernet_PCS_sva.sv, written separately from clause 119:
     xcode(g)     for each of the 256 sync header combinations of the four
                  blocks, the payload is moved bit by bit, so the zero
                  payload and every one-hot payload (256) cover every input
     rxcode(x)    for each header bit / flag combination (32) and each first
                  block type nibble (16), the zero and every one-hot value
                  of the other bits
     scr(h, x)    linear in {h, x}: the zero and every one-hot input (315),
                  scrambling and descrambling
     btf_hi(n)    all 16 nibbles
2. The two gearboxes: every reachable state {fill, beat of the pair} under
   the core's rules (transmit: a beat leaves when fill >= 640, 40 for beat
   16, a block of 257 enters when the fill after it stays below 1024;
   receive: a block leaves when fill >= 257, a beat enters when the fill
   after it stays below 1024), any choice each clock: the fill registers
   (10 bits) never overflow, and transmit fill bit 6 is never set (the
   coverage exclusion of tfill[6]).
  python3 scripts/formal/exhaust_ethpcs.py
"""
import os, re, subprocess, sys
root = os.path.join(os.path.dirname(os.path.abspath(__file__)), '..', '..')
os.chdir(root)
rtl = open('rtl/Ethernet_PCS_top.sv').read()
chk = open('tb/cov/Ethernet_PCS_sva.sv').read()


def cut(src, pat, end='endfunction'):
    m = re.search(pat, src)
    if not m:
        sys.exit(f'not found: {pat}')
    return src[m.start():src.index(end, m.start()) + len(end)] + '\n'


parts = [cut(rtl, r'  function automatic logic \[314:0\] scr\('),
         cut(rtl, r'  function automatic logic \[256:0\] xcode\('),
         cut(rtl, r'  function automatic logic \[4:0\] btf_hi\('),
         cut(rtl, r'  function automatic logic \[264:0\] rxcode\('),
         cut(chk, r'  function automatic logic \[256:0\] xcode_m\('),
         cut(chk, r'  function automatic logic \[256:0\] scr_m\('),
         cut(chk, r'  function automatic int btf_m\('),
         cut(chk, r'  function automatic logic \[263:0\] rxcode_m\(')]

test = r'''
  int bad = 0, n = 0;
  initial begin
    // xcode: 256 sync header combinations x (zero + 256 one-hot payloads)
    for (int hs = 0; hs < 256; hs++)
      for (int b = -1; b < 256; b++) begin
        logic [263:0] g;
        int kind;
        g = '0;
        for (int j = 0; j < 4; j++) g[66 * j +: 2] = 2'(hs >> (2 * j));
        if (b >= 0) g[66 * (b / 64) + 2 + b % 64] = 1'b1;
        if (xcode(g) != xcode_m(g, kind)) begin if (bad < 5) $display("xcode %0d %0d", hs, b); bad++; end
        n++;
      end
    $display("xcode: %0d inputs", n);
    // rxcode: 32 x 16 classes x (zero + one-hot of the other bits)
    n = 0;
    for (int hf = 0; hf < 32; hf++)
      for (int nb = 0; nb < 16; nb++)
        for (int b = -1; b < 257; b++) begin
          logic [256:0] x;
          logic [263:0] gm;
          logic [264:0] gr;
          int c, kind;
          x = '0;
          x[4:0] = 5'(hf);
          c = 0;
          while (c < 3 && x[1 + c]) c++;
          if (!x[0] && x[4:1] != 4'hF) x[5 + 64 * c +: 4] = 4'(nb);
          if (b >= 0 && b > 4 && !(!x[0] && x[4:1] != 4'hF && b >= 5 + 64 * c && b < 9 + 64 * c)) x[b] = 1'b1;
          gr = rxcode(x);
          gm = rxcode_m(x, kind);
          if (gr[263:0] != gm || gr[264] != (kind >= 5)) begin
            if (bad < 5) $display("rxcode %0d %0d %0d", hf, nb, b); bad++;
          end
          n++;
        end
    $display("rxcode: %0d inputs", n);
    // scrambler: linear in {h, x}
    n = 0;
    for (int de = 0; de < 2; de++)
      for (int b = -1; b < 315; b++) begin
        logic [57:0] h, hm;
        logic [256:0] x, om;
        logic [314:0] r;
        {h, x} = '0;
        if (b >= 0) {h, x} = 315'(1) << b;
        hm = h;
        r = scr(h, x, de[0]);
        om = scr_m(x, de[0], hm);
        if (r != {hm, om}) begin if (bad < 5) $display("scr %0d %0d", de, b); bad++; end
        n++;
      end
    $display("scr: %0d inputs", n);
    for (int i = 0; i < 16; i++) begin
      logic [4:0] h;
      int t;
      h = btf_hi(4'(i));
      t = btf_m(4'(i));
      if (t < 0 ? h != 5'd0 : h != {1'b1, 4'(t >> 4)}) begin $display("btf_hi %0d", i); bad++; end
    end
    $display("btf_hi: 16 inputs");
    if (bad == 0) $display("FUNCTIONS PASS");
    else $display("FUNCTIONS FAIL: %0d", bad);
    $finish;
  end
'''
out = 'work/formal/exhaust_ethpcs'
os.makedirs(out, exist_ok=True)
with open(f'{out}/t.sv', 'w') as f:
    f.write('module t;\n' + ''.join(parts) + test + 'endmodule\n')
subprocess.run(['verilator', '--binary', '-j', '4', '-Wno-fatal', '-Wno-lint', '-Wno-style', '--top-module', 't',
                '--Mdir', f'{out}/obj', f'{out}/t.sv'], check=True, stdout=subprocess.DEVNULL)
r = subprocess.run([f'{out}/obj/Vt'], capture_output=True, text=True)
print(r.stdout.strip())
ok = 'FUNCTIONS PASS' in r.stdout


def reach(step):
    seen, todo = set(), [(0, 0)]
    while todo:
        s = todo.pop()
        if s in seen:
            continue
        seen.add(s)
        todo += step(*s)
    return seen


def tx_step(f, e):
    nxt = []
    need = 40 if e == 16 else 640
    for emit in (False, True):
        if emit and f < need:
            continue
        fe, ne = (f - need, (e + 1) % 17) if emit else (f, e)
        nxt.append((fe, ne))
        if fe < 767:
            nxt.append((fe + 257, ne))
    return nxt


def rx_step(f, e):
    nxt = []
    need = 40 if e == 16 else 640
    for blk in (False, True):
        if blk and f < 257:
            continue
        fe = f - 257 if blk else f
        nxt.append((fe, e))
        if fe < 1024 - need:
            nxt.append((fe + need, (e + 1) % 17))
    return nxt


tx, rx = reach(tx_step), reach(rx_step)
txf, rxf = {f for f, _ in tx}, {f for f, _ in rx}
gb = max(txf) < 1024 and max(rxf) < 1024 and all(not (f >> 6) & 1 for f in txf)
print(f"gearboxes: transmit {len(tx)} states, fill 0..{max(txf)} (bit 6 never set: "
      f"{all(not (f >> 6) & 1 for f in txf)}); receive {len(rx)} states, fill 0..{max(rxf)}")
print("EXHAUSTIVE PASS" if ok and gb else "EXHAUSTIVE FAIL")
sys.exit(0 if ok and gb else 1)
