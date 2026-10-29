#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# Technology-independent area and logic-depth report of an IP core: yosys
# synthesizes and flattens rtl/<P>_top.sv, maps it with ABC to 2-input gates
# (AND, NAND, OR, NOR, XOR, XNOR, MUX, NOT) and flip-flops, counts the cells,
# converts them to NAND2 gate equivalents (GE), and reports the longest
# register-to-register path in gate levels (yosys ltp). No foundry library
# is used: the GE weights are the usual textbook ones and the depth is in
# gates, not picoseconds; they rank designs and spot deep paths, they are not
# a timing sign-off.
#   bash scripts/syn/ppa_report.sh PCIe     -> work/ppa/PCIe.txt
set -euo pipefail
P=$1
cd "$(dirname "$0")/../.."
W=work/ppa
mkdir -p "$W"
# IPs whose synthesis script keeps memories as RAM macros (memory -nomap) are
# reported the same way: logic and flip-flops around the RAMs, plus the RAM bits.
# Registered read ports are split back into an asynchronous port and flip-flops
# (memory_nordff), so a path ends at the RAM's read register instead of running
# through the RAM from its write data; resources are not shared (-noshare), as a
# timing-driven tool would not share a multiplier between two pipeline stages.
if grep -q 'memory -nomap' "syn/${P}_yosys.ys" 2>/dev/null; then
  FLOW="synth -flatten -noshare -top ${P}_top -run :fine; memory_nordff; opt -fast -full; techmap; opt -fast; abc -fast -g AND,NAND,OR,NOR,XOR,XNOR,MUX"
else
  FLOW="synth -flatten -top ${P}_top; abc -g AND,NAND,OR,NOR,XOR,XNOR,MUX"
fi
# Sub-blocks that are IPs of their own (Makefile COVLIB, e.g. the RS-FEC cores
# inside Ethernet_PCS) are read as black boxes: the report is the IP's own
# logic, and the sub-blocks have their own reports.
LIBS=""
for f in $(grep -E '^COVLIB\s*:?=' "Makefile.$P" 2>/dev/null | head -1 | sed 's/.*= *//'); do
  LIBS="$LIBS read_verilog -sv -lib $f;"
done
yosys -q -l "$W/$P.log" -p "$LIBS read_verilog -sv rtl/${P}_top.sv; $FLOW; \
  opt_clean; tee -q -o $W/$P.stat stat; tee -q -o $W/$P.ltp ltp -noff" \
  > /dev/null 2>&1
python3 - "$P" "$W" <<'PY'
import re, sys
p, w = sys.argv[1], sys.argv[2]
cells = {m.group(1): int(m.group(2)) for m in re.finditer(r'^\s+\$_(\w+)_\s+(\d+)', open(f'{w}/{p}.stat').read(), re.M)}
ge_w = {'NOT': 0.67, 'NAND': 1.0, 'NOR': 1.0, 'AND': 1.33, 'OR': 1.33, 'XOR': 2.33, 'XNOR': 2.33,
        'MUX': 2.33, 'ANDNOT': 1.33, 'ORNOT': 1.33}
ff = sum(n for c, n in cells.items() if c.startswith(('DFF', 'SDFF', 'DLATCH', 'ALDFF')))
comb = {c: n for c, n in cells.items() if not c.startswith(('DFF', 'SDFF', 'DLATCH', 'ALDFF'))}
ge = sum(ge_w.get(c, 1.33) * n for c, n in comb.items()) + 5.33 * ff
m = re.search(r'length=(\d+)', open(f'{w}/{p}.ltp').read())
depth = int(m.group(1)) - 1 if m else -1      # gates between two flip-flops
out = (f"{p}: flip-flops {ff}, logic gates {sum(comb.values())}, "
       f"area {ge / 1000:.1f} kGE (NAND2 equivalents), deepest path {depth} gate levels")
print(out)
open(f'{w}/{p}.txt', 'w').write(out + '\n' + ''.join(f'  {c}: {n}\n' for c, n in sorted(cells.items())))
PY
