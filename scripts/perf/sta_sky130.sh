#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# Pre-layout timing and area estimate of an IP core on the open SkyWater
# SKY130 high-density library (sky130_fd_sc_hd, typical corner tt_025C_1v80).
# yosys synthesizes and flattens rtl/<P>_top.sv and takes out the in-model
# DRAM array, which is not controller logic (its size is reported
# separately): an array yosys keeps as a memory stays a RAM macro, and an
# array it has turned into flip-flops (cores that write it from an
# asynchronous-reset process: the words are wires mem[0], mem[1], ...) loses
# those flip-flops, their outputs becoming inputs of the netlist. The read
# multiplexer stays in. Then yosys maps flip-flops with dfflibmap and the
# logic with ABC (delay-driven mapping, buffering and gate sizing), and ABC's
# stime reports the longest combinational path between flip-flops / ports.
#   Fmax estimate = 1 / (logic path + flip-flop clock-to-Q + setup)
# with clock-to-Q + setup taken as 0.50 ns (sky130_fd_sc_hd__dfrtp_1, typical).
# No wires, placement, clock skew or on-chip variation: this ranks designs and
# gives an order of magnitude, it is not a sign-off number.
#   bash scripts/perf/sta_sky130.sh DDR4   -> work/perf/DDR4/sta.txt
# The liberty file (12 MB) is downloaded once into work/pdk/.
set -euo pipefail
P=$1
cd "$(dirname "$0")/../.."
W=work/perf/$P
mkdir -p "$W" work/pdk
LIB=work/pdk/sky130_fd_sc_hd__tt_025C_1v80.lib
URL=https://raw.githubusercontent.com/The-OpenROAD-Project/OpenROAD-flow-scripts/master/flow/platforms/sky130hd/lib/sky130_fd_sc_hd__tt_025C_1v80.lib
[ -s "$LIB" ] || curl -sSfL -o "$LIB" "$URL"
TARGET_PS=${TARGET_PS:-1000}
yosys -q -l "$W/sta.log" -p "read_verilog -sv -DSYNTHESIS rtl/${P}_top.sv; \
  synth -flatten -noshare -top ${P}_top -run :fine; memory_nordff; opt -fast -full; \
  tee -q -o $W/arr.txt stat w:mem[[]*; select -set arr w:mem[[]* %ci1 t:*dff* %i; \
  delete @arr; expose -input w:mem[[]*; opt_clean; \
  techmap; opt -fast; tee -q -o $W/mem.txt dump t:\$mem_v2; \
  dfflibmap -liberty $LIB; \
  abc -liberty $LIB -D $TARGET_PS -script +strash;ifraig;scorr;dc2;dretime;strash;&get,-n;&dch,-f;&nf,{D};&put;buffer;upsize,{D};dnsize,{D};stime,-p; \
  opt_clean; tee -q -o $W/stat.txt stat -liberty $LIB" > /dev/null 2>&1
python3 - "$P" "$W" <<'PY'
import re, sys
p, w = sys.argv[1], sys.argv[2]
log = open(f'{w}/sta.log').read()
d = [float(x) for x in re.findall(r'Delay =\s*([\d.]+) ps', log)]
delay = d[-1] / 1000.0
st = open(f'{w}/stat.txt').read()
area = float(re.search(r'Chip area for module .*?: ([\d.]+)', st).group(1))
ff = sum(int(n) for c, n in re.findall(r'sky130_fd_sc_hd__(df\w+|edf\w+|sdf\w+)\s+(\d+)', st))
cells = int(re.search(r'Number of cells:\s+(\d+)', st).group(1))
mst = open(f'{w}/mem.txt').read()
mbits = 0
for cell in mst.split('cell ')[1:]:
    sz = re.search(r'parameter \\SIZE (\d+)', cell)
    wd = re.search(r'parameter \\WIDTH (\d+)', cell)
    if sz and wd:
        mbits += int(sz.group(1)) * int(wd.group(1))
m = re.search(r'Number of wire bits:\s+(\d+)', open(f'{w}/arr.txt').read())
mbits += int(m.group(1)) if m else 0
fmax = 1000.0 / (delay + 0.50)
out = (f"PERF sta_logic_ns {delay:.2f}\nPERF sta_fmax_mhz {fmax:.0f}\nPERF sta_area_um2 {area:.0f}\n"
       f"PERF sta_cells {cells}\nPERF sta_ff {ff}\nPERF sta_mem_bits {mbits}\n")
open(f'{w}/sta.txt', 'w').write(out)
print(out, end='')
PY
