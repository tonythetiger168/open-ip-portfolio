#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# run_cov.sh <PROTOCOL> -- Verilator 5.052 five-metric coverage run:
# line, toggle, FSM (generated state/arc covers), SVA (bound concurrent
# assertions) and functional (covergroups + fc_* covers).
#   bash scripts/cov/run_cov.sh I2C
#   bash scripts/cov/run_cov.sh I2C_apb   # APB wrapper: scores rtl/I2C_apb.sv only
# Env: BUILD_DIR (default work/cov/<P>), SEED (default 1), VFLAGS (extra).
# Per-IP options: scripts/cov/flags/<P>.txt (core and wrapper runs).
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
# MK: the IP's Makefile, or scripts/cov/units/<P>.mk for a shared block that
# is closed on its own (no release package, no APB wrapper), e.g. the AXI
# engine of the SoC subsystem IPs
MK="Makefile.$BASE"
[ -f "$MK" ] || MK="scripts/cov/units/$BASE.mk"
[ -f "$MK" ] || { echo "NO_MAKEFILE $P"; exit 2; }
mkvar() { grep -E "^$1\s*:?=" "$MK" | head -1 | sed 's/^[^=]*= *//; s/ *#.*//'; }
S=$(mkvar S)
DEPS=$(mkvar DEPS)
# TBDEPS: testbench-side RTL (e.g. the far-end device of the bus), compiled
# but never scored; .svh entries are included by the TB itself
TBDEPS=""
for f in $(mkvar TBDEPS); do case "$f" in *.sv) TBDEPS="$TBDEPS $f" ;; esac; done
TOPF="rtl/${S}_top.sv"
[ -f "$TOPF" ] || TOPF="rtl/${S}.sv"
RTL="$TOPF $DEPS"
# COVLIB: DEPS files that are IPs of their own (closed by their own run):
# compiled, not scored
COVLIB=$(mkvar COVLIB)
SCORED="$TOPF"
for f in $DEPS; do case " $COVLIB " in *" $f "*) ;; *) SCORED="$SCORED $f" ;; esac; done
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
# per-IP Verilator options (e.g. --coverage-max-width for flits wider than
# the default 256 bits, which Verilator leaves out of toggle coverage)
XFLAGS=$(grep -v '^#' "scripts/cov/flags/$BASE.txt" 2>/dev/null | tr '\n' ' ')
sed "s/V@TOP@/Vtop/g; s/@TOP@/${TB}/g" scripts/verilator_cov/sim_main.cpp.tmpl > "$BUILD/sim_main.cpp"

verilator --cc --exe --build --timing --assert \
  --coverage-line --coverage-toggle --coverage-user \
  -j 4 -Wno-fatal -Wno-lint -Wno-style -Wno-UNOPTFLAT -Wno-COVERIGN \
  +incdir+tb/cov +incdir+tb --top-module "$TB" --prefix Vtop ${XFLAGS} ${VFLAGS:-} \
  $RTL "tb/$TB.sv" $TBDEPS $COV "$BUILD/sim_main.cpp" \
  -o "${TB}_cov" --Mdir "$BUILD/obj" > "$BUILD/build.log" 2>&1 \
  || { echo "BUILD_FAIL $P (see $BUILD/build.log)"; grep -m5 '%Error' "$BUILD/build.log"; exit 1; }

# +cov_long turns on the long runs of a testbench (counters driven past 2^15
# and to saturation, ...) that only coverage needs; the iverilog regression
# and the mutation flow (COV_QUICK=1) leave them out.
LONG="+cov_long"; [ "${COV_QUICK:-0}" = 1 ] && LONG=""
( cd "$BUILD/obj" && rm -f coverage.dat && "./${TB}_cov" +verilator+seed+$SEED $LONG ) > "$BUILD/run.log" 2>&1 || true
[ -f "$BUILD/obj/coverage.dat" ] || { echo "NO_COVERAGE_DAT $P"; tail -5 "$BUILD/run.log"; exit 1; }
python3 scripts/cov/score.py "$BUILD/obj/coverage.dat" "$BUILD/run.log" "$P" $SCORED --json "$BUILD/score.json"
