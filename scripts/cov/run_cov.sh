#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# run_cov.sh <PROTOCOL> -- Verilator 5.052 five-metric coverage run:
# line, toggle, FSM (generated state/arc covers), SVA (bound concurrent
# assertions) and functional (covergroups + fc_* covers).
#   bash scripts/cov/run_cov.sh I2C
# Env: BUILD_DIR (default work/cov/<P>), SEED (default 1), VFLAGS (extra).
set -u
cd "$(dirname "$0")/../.."
P="${1:?usage: run_cov.sh <PROTOCOL>}"
TB="${P}_tb"
BUILD="${BUILD_DIR:-work/cov/$P}"
SEED="${SEED:-1}"
mkdir -p "$BUILD"
S=$(grep -E '^S\s*:?=' "Makefile.$P" | head -1 | sed 's/.*= *//')
DEPS=$(grep -E '^DEPS\s*:?=' "Makefile.$P" | head -1 | sed 's/.*= *//')
RTL="rtl/${S}_top.sv $DEPS"
[ -f "tb/$TB.sv" ] || { echo "NO_TB $P"; exit 2; }
python3 scripts/cov/gen_fsm_cov.py "$P" >/dev/null || { echo "FSM_GEN_FAIL $P"; exit 2; }
COV="tb/cov/${P}_fsm_cov.sv"
[ -f "tb/cov/${P}_sva.sv" ] && COV="$COV tb/cov/${P}_sva.sv"
sed "s/V@TOP@/Vtop/g; s/@TOP@/${TB}/g" scripts/verilator_cov/sim_main.cpp.tmpl > "$BUILD/sim_main.cpp"

verilator --cc --exe --build --timing --assert \
  --coverage-line --coverage-toggle --coverage-user \
  -j 4 -Wno-fatal -Wno-lint -Wno-style -Wno-UNOPTFLAT -Wno-COVERIGN \
  +incdir+tb/cov --top-module "$TB" --prefix Vtop ${VFLAGS:-} \
  $RTL "tb/$TB.sv" $COV "$BUILD/sim_main.cpp" \
  -o "${TB}_cov" --Mdir "$BUILD/obj" > "$BUILD/build.log" 2>&1 \
  || { echo "BUILD_FAIL $P (see $BUILD/build.log)"; grep -m5 '%Error' "$BUILD/build.log"; exit 1; }

( cd "$BUILD/obj" && rm -f coverage.dat && "./${TB}_cov" +verilator+seed+$SEED ) > "$BUILD/run.log" 2>&1 || true
[ -f "$BUILD/obj/coverage.dat" ] || { echo "NO_COVERAGE_DAT $P"; tail -5 "$BUILD/run.log"; exit 1; }
python3 scripts/cov/score.py "$BUILD/obj/coverage.dat" "$BUILD/run.log" "$P" $RTL --json "$BUILD/score.json"
