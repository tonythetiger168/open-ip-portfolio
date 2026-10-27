#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# run_cov.sh <PROTOCOL> -- Verilator 5.052 five-metric coverage run:
# line, toggle, FSM (generated state/arc covers), SVA (bound concurrent
# assertions) and functional (covergroups + fc_* covers).
#   bash scripts/cov/run_cov.sh I2C
#   bash scripts/cov/run_cov.sh I2C_apb   # APB wrapper: scores rtl/I2C_apb.sv only
# Env: BUILD_DIR (default work/cov/<P>), SEED (default 1), VFLAGS (extra).
set -u
cd "$(dirname "$0")/../.."
P="${1:?usage: run_cov.sh <PROTOCOL>}"
TB="${P}_tb"
BUILD="${BUILD_DIR:-work/cov/$P}"
SEED="${SEED:-1}"
# Older Verilators parse covergroups but drop them (COVERIGN, silenced below),
# which would score functional coverage on the fc_* covers alone.
VV=$(verilator --version 2>/dev/null | awk '{print $2}')
[ -n "$VV" ] || { echo "NO_VERILATOR: install Verilator 5.052 (see README, Setup)"; exit 2; }
if [ "$(printf '%s\n5.052\n' "$VV" | sort -V | head -1)" != "5.052" ]; then
  echo "OLD_VERILATOR $VV: this flow needs Verilator >= 5.052 (see README, Setup)"; exit 2
fi
python3 -c "import pyslang" 2>/dev/null || { echo "NO_PYSLANG: pip install pyslang==12.0.0 (see README, Setup)"; exit 2; }
mkdir -p "$BUILD"
case "$P" in
  *_apb) BASE="${P%_apb}" ;;
  *)     BASE="$P" ;;
esac
S=$(grep -E '^S\s*:?=' "Makefile.$BASE" | head -1 | sed 's/.*= *//')
DEPS=$(grep -E '^DEPS\s*:?=' "Makefile.$BASE" | head -1 | sed 's/.*= *//')
RTL="rtl/${S}_top.sv $DEPS"
SCORED="$RTL"
[ -f "tb/$TB.sv" ] || { echo "NO_TB $P"; exit 2; }
if [ "$BASE" != "$P" ]; then
  # APB wrapper: the core is compiled but only the wrapper is scored, and only
  # the wrapper's checker is bound (the core has its own run)
  RTL="$RTL rtl/${S}_apb.sv"
  SCORED="rtl/${S}_apb.sv"
  COV="tb/cov/${P}_sva.sv"
else
  python3 scripts/cov/gen_fsm_cov.py "$P" >/dev/null || { echo "FSM_GEN_FAIL $P"; exit 2; }
  COV="tb/cov/${P}_fsm_cov.sv"
  [ -f "tb/cov/${P}_sva.sv" ] && COV="$COV tb/cov/${P}_sva.sv"
fi
sed "s/V@TOP@/Vtop/g; s/@TOP@/${TB}/g" scripts/verilator_cov/sim_main.cpp.tmpl > "$BUILD/sim_main.cpp"

verilator --cc --exe --build --timing --assert \
  --coverage-line --coverage-toggle --coverage-user \
  -j 4 -Wno-fatal -Wno-lint -Wno-style -Wno-UNOPTFLAT -Wno-COVERIGN \
  +incdir+tb/cov +incdir+tb --top-module "$TB" --prefix Vtop ${VFLAGS:-} \
  $RTL "tb/$TB.sv" $COV "$BUILD/sim_main.cpp" \
  -o "${TB}_cov" --Mdir "$BUILD/obj" > "$BUILD/build.log" 2>&1 \
  || { echo "BUILD_FAIL $P (see $BUILD/build.log)"; grep -m5 '%Error' "$BUILD/build.log"; exit 1; }

( cd "$BUILD/obj" && rm -f coverage.dat && "./${TB}_cov" +verilator+seed+$SEED ) > "$BUILD/run.log" 2>&1 || true
[ -f "$BUILD/obj/coverage.dat" ] || { echo "NO_COVERAGE_DAT $P"; tail -5 "$BUILD/run.log"; exit 1; }
python3 scripts/cov/score.py "$BUILD/obj/coverage.dat" "$BUILD/run.log" "$P" $SCORED --json "$BUILD/score.json"
