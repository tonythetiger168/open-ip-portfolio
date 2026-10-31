#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# Formal check of an IP core with yosys's SAT solver: every assertion in
# formal/<P>_props.svh (included by the core under `ifdef FORMAL) is proven
# for DEPTH clocks after reset by bounded model checking, with all inputs
# free after the first clock (reset itself may come back at any time).
# Then k-induction is tried for INDUCT steps; when it fails the bounded
# result stands and is reported as such. PARAMS (formal/<P>.cfg) shrinks
# the core so the solver can reach a useful depth; FILES (optional) lists
# further RTL files the core instantiates.
#   bash scripts/formal/run_formal.sh PCIe
# On a failure the counterexample is work/formal/<P>/cex.vcd, and
#   python3 scripts/formal/fail_report.py work/formal/<P>/cex.vcd <signals>
# lists the failing assertions (by line) step by step.
set -euo pipefail
P=$1
cd "$(dirname "$0")/../.."
# shellcheck disable=SC1090
source "formal/$P.cfg"
W=work/formal/$P
mkdir -p "$W"
CH=""
for kv in $PARAMS; do CH="$CH -set ${kv%%=*} ${kv#*=}"; done
READ="read_verilog -sv -formal -I formal rtl/${P}_top.sv ${FILES:-}; chparam $CH ${P}_top; prep -top ${P}_top; ${FILES:+flatten;} \
  memory_map; opt -fast; async2sync; dffunmap"
echo "===== $P formal ($PARAMS) ====="
rm -f "$W/cex.vcd"
T0=$(date +%s)
if yosys -q -l "$W/bmc.log" -p "$READ; sat -seq $DEPTH -prove-asserts -set-assumes -set-init-zero -verify \
     -show-all -dump_vcd $W/cex.vcd -timeout ${BMC_TIMEOUT:-3000}" > /dev/null 2>&1; then
  echo "BMC         PASS: $(( $(grep -c 'Import proof for assert' "$W/bmc.log") / DEPTH )) assertions, depth $DEPTH ($(( $(date +%s) - T0 )) s)"
else
  echo "BMC         FAIL (counterexample $W/cex.vcd)"
  python3 scripts/formal/fail_report.py "$W/cex.vcd" | grep -v 'failing \[\]' | head -5
  exit 1
fi
if [ "${INDUCT:-0}" -gt 0 ]; then
  if yosys -q -l "$W/induct.log" -p "$READ; sat -tempinduct -prove-asserts -set-assumes -maxsteps $INDUCT -verify \
       -timeout ${INDUCT_TIMEOUT:-3000}" > /dev/null 2>&1; then
    echo "INDUCTION   PASS (k <= $INDUCT): the assertions hold at any depth"
  else
    echo "INDUCTION   not proven within k = $INDUCT: the result is the bounded one above"
  fi
fi
