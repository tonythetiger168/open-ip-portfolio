#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
"""Reads the counterexample VCD of a failed `yosys sat -prove-asserts` run
and prints, for each clock, the assertions (file:line) that fail there with
their enable high, plus the named signals given on the command line.
  python3 scripts/formal/fail_report.py work/formal/PCIe/cex.vcd rqw rqr"""
import re, sys

lines = open(sys.argv[1]).read().split('\n')
show = set(sys.argv[2:])
ids = {}
for l in lines:
    m = re.match(r'\$var \w+ \d+ (\S+) (\S+)', l)
    if m:
        ids.setdefault(m.group(1), []).append(m.group(2))
# a CHECK's enable is the EN with the closest id at or below its own (one
# EN per always block)
chk = re.compile(r'_formal_(.+?\.svh?)_(\d+)_(\d+)_CHECK')
en = re.compile(r'_formal_.+?\.svh?_\d+_(\d+)_EN')
t, vals = None, {}


def report(t):
    ens = sorted((int(m.group(1)), v) for k, v in vals.items() if (m := en.search(k)))
    bad = set()
    for k, v in vals.items():
        m = chk.search(k)
        if m and v == '0':
            e = [ev for i, ev in ens if i <= int(m.group(3))]
            if e and e[-1] == '1':
                bad.add(m.group(1) + ':' + m.group(2))
    sig = {k.lstrip('\\'): v for k, v in vals.items() if k.lstrip('\\') in show}
    if bad or sig:
        print(f"step {t}: failing {sorted(bad)} {sig}")


for l in lines + ['#end']:
    if l.startswith('#'):
        if t is not None:
            report(t)
        t = l[1:]
    elif l[:1] in ('0', '1') and l[1:] in ids:
        for n in ids[l[1:]]:
            vals[n] = l[0]
    elif l.startswith('b'):
        v, i = l.split()
        for n in ids.get(i, []):
            vals[n] = v[1:]
