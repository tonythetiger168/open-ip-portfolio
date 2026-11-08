#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# Performance characterization of a memory-controller core:
#   1. the IP's own TB built with +define+MEM_PERF runs tb/perf/mem_perf.svh
#      (numbered DDR / LPDDR / GDDR / HBM cores) or tb/perf/lite_perf.svh
#      (*_Lite line controllers): latency, sustained throughput per traffic
#      pattern and refresh cost, measured in clocks on the core's ports;
#   2. scripts/perf/sta_sky130.sh: pre-layout Fmax and area on SKY130 HD;
#   3. scripts/perf/perf_report.py combines both into docs/perf/<P>.json,
#      which scripts/apb/gen_apb.py renders as the Performance section of
#      docs/ip/<P>.md.
#   bash scripts/perf/run_perf.sh DDR4 [DDR5 ...]
# Then: python3 scripts/apb/gen_apb.py <P> (page) and
#       python3 scripts/perf/perf_report.py --summary (docs/MEMORY_PERFORMANCE.md)
set -euo pipefail
cd "$(dirname "$0")/../.."
for P in "$@"; do
  W=work/perf/$P
  mkdir -p "$W"
  iverilog -g2012 -DMEM_PERF -I tb -o "$W/simv" "rtl/${P}_top.sv" "tb/${P}_tb.sv"
  vvp -n "$W/simv" > "$W/sim.log"
  grep -q '^PERF_DONE' "$W/sim.log" || { echo "$P: performance run did not finish"; tail -5 "$W/sim.log"; exit 1; }
  # the synthesis result is reused while it is newer than the RTL
  [ "$W/sta.txt" -nt "rtl/${P}_top.sv" ] && [ -z "${FORCE_STA:-}" ] || bash scripts/perf/sta_sky130.sh "$P" > /dev/null
  python3 scripts/perf/perf_report.py "$P"
done
