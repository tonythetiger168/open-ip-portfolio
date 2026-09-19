#!/usr/bin/env python3
"""Compare RTL DDR trace port output vs gem5 DRAMCtrl trace (command sequences).
RTL trace format (one per line):  <cmd:1=ACT,2=RD,3=WR> <hex addr>
gem5 trace:  parse lines containing 'activate' / 'rd' / 'wr' with 0xADDR.

Co-verification semantics: identical access sequences must produce identical
activate/rd/wr ADDRESS SETS (timing may differ: RTL is a simplified single-bank
model, gem5 models full bank-group timing)."""
import sys, re

def parse_rtl(path):
    cmds = []
    for line in open(path):
        m = re.match(r"\s*([123])\s+(0x[0-9a-fA-F]+|[0-9a-fA-F]+)", line)
        if m:
            cmds.append((int(m.group(1)), int(m.group(2), 0) & 0xFFFF))
    return cmds

def parse_gem5(path):
    cmds = []
    for line in open(path):
        act = re.search(r"(activate|rd|wr)\b.*(0x[0-9a-fA-F]+)", line)
        if act:
            c = {"activate": 1, "rd": 2, "wr": 3}[act.group(1)]
            cmds.append((c, int(act.group(2), 16) & 0xFFFF))
    return cmds

if len(sys.argv) != 3:
    print("usage: compare_trace.py rtl_trace.txt gem5_trace.txt"); sys.exit(1)
rtl, g5 = parse_rtl(sys.argv[1]), parse_gem5(sys.argv[2])
rtl_set, g5_set = sorted(set(rtl)), sorted(set(g5))
print(f"RTL: {len(rtl)} cmds, {len(rtl_set)} unique; gem5: {len(g5)} cmds, {len(g5_set)} unique")
missing = [c for c in rtl_set if c not in g5_set]
extra   = [c for c in g5_set if c not in rtl_set]
if not missing and not extra:
    print("CO-VERIFICATION PASS: identical activate/rd/wr address sets")
    sys.exit(0)
print(f"MISSING in gem5: {missing[:8]}")
print(f"EXTRA in gem5:   {extra[:8]}")
sys.exit(1)
