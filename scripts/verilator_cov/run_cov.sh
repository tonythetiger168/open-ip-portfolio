#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# run_cov.sh <PROTOCOL> — build + run one protocol TB under Verilator with
# coverage, then print the 4-metric summary (line/toggle from coverage.dat,
# FSM_COV and SVA_CHECKS parsed from the TB's own output).
# Usage:  bash scripts/verilator_cov/run_cov.sh I2C
# Env:    BUILD_DIR (default $HOME/vcov/<PROTO>), extra VFLAGS via VFLAGS.
set -u
cd "$(dirname "$0")/../.."
P="${1:?usage: run_cov.sh <PROTOCOL>}"
TOP_TB="${P}_tb"
BUILD="${BUILD_DIR:-$HOME/vcov/$P}"
mkdir -p "$BUILD"

# collect RTL sources from the protocol Makefile (S + DEPS)
S_LINE=$(grep -E '^S\s*:?=' "Makefile.$P" | head -1 | sed 's/.*= *//')
DEPS=$(grep -E '^DEPS\s*:?=' "Makefile.$P" | head -1 | sed 's/.*= *//')
SRCS="rtl/${S_LINE}_top.sv $DEPS tb/${TOP_TB}.sv"
[ -f "tb/${TOP_TB}.sv" ] || { echo "NO_TB $P"; exit 2; }

sed "s/@TOP@/${TOP_TB}/g" scripts/verilator_cov/sim_main.cpp.tmpl > "$BUILD/sim_main.cpp"

verilator --cc --exe --build --timing --coverage -j 4 \
  -Wno-WIDTH -Wno-fatal -Wno-UNOPTFLAT --top-module "$TOP_TB" \
  $SRCS "$BUILD/sim_main.cpp" -o "${TOP_TB}_cov" --Mdir "$BUILD/obj" \
  > "$BUILD/build.log" 2>&1 || { echo "BUILD_FAIL $P (see $BUILD/build.log)"; exit 1; }

( cd "$BUILD/obj" && "./${TOP_TB}_cov" ) > "$BUILD/run.log" 2>&1 || true

echo "===== $P ====="
grep -E 'TEST (PASSED|FAILED)' "$BUILD/run.log" | tail -1
grep -E 'FSM_COV:|SVA_CHECKS:' "$BUILD/run.log" | tail -2
if [ -f "$BUILD/obj/coverage.dat" ]; then
  python3 scripts/verilator_cov/parse_cov.py "$BUILD/obj/coverage.dat" "rtl/${S_LINE}_top.sv"
else
  echo "NO_COVERAGE_DAT"
fi
