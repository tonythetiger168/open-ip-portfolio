#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# CI regression: run sim + syn (+ apb) for every Makefile.<PROTOCOL>.
# Protocols run in parallel (JOBS, default: CPU count), each in its own
# scratch copy of the tree, since every Makefile builds ./simv in the
# current directory. Logs land in work/ci_{sim,syn,apb}_<P>.log.
# Exits non-zero if any protocol fails. Prints a summary table at the end.
#   bash scripts/ci_regression.sh [JOBS] [PROTOCOL...]
set -u
cd "$(dirname "$0")/.."
ROOT=$(pwd)
JOBS="${1:-$(nproc)}"
[ $# -gt 0 ] && shift

mkdir -p work
SCR=$(mktemp -d)
trap 'rm -rf "$SCR"' EXIT

if [ $# -gt 0 ]; then protos="$*"
else protos=$(ls Makefile.* | sed 's/^Makefile\.//' | grep -vx common); fi

run_one() {
  proto=$1; d="$SCR/$proto"
  mkdir -p "$d"
  cp -r "$ROOT/rtl" "$ROOT/tb" "$ROOT/syn" "$ROOT/scripts" "$ROOT/Makefile.$proto" "$d/"
  cd "$d" || exit 1
  r=""
  if make -f "Makefile.$proto" sim >"$ROOT/work/ci_sim_${proto}.log" 2>&1 \
     && grep -q "TEST PASSED" "$ROOT/work/ci_sim_${proto}.log"; then r="$r sim:ok"; else r="$r sim:FAIL"; fi
  if make -f "Makefile.$proto" syn >"$ROOT/work/ci_syn_${proto}.log" 2>&1 \
     && ! grep -q "ERROR" "$ROOT/work/ci_syn_${proto}.log"; then r="$r syn:ok"; else r="$r syn:FAIL"; fi
  if grep -q '^apb:' "Makefile.$proto"; then   # APB register wrapper: sim + syn
    if make -f "Makefile.$proto" apb >"$ROOT/work/ci_apb_${proto}.log" 2>&1 \
       && grep -q "TEST PASSED" "$ROOT/work/ci_apb_${proto}.log" \
       && ! grep -q "ERROR" "$ROOT/work/ci_apb_${proto}.log"; then r="$r apb:ok"; else r="$r apb:FAIL"; fi
  fi
  cd "$ROOT"; rm -rf "$d"
  echo "$proto$r"
}
export -f run_one
export ROOT SCR

printf '%s\n' $protos | xargs -P "$JOBS" -I{} bash -c 'run_one {}' | sort > work/ci_results.txt

cnt() { grep -c " $1:$2" work/ci_results.txt; }
failed=$(awk '{for (i = 2; i <= NF; i++) if ($i ~ /FAIL/) { split($i, a, ":"); printf " %s:%s", a[1], $1 }}' work/ci_results.txt)
echo "=================================================="
echo "SIM: $(cnt sim ok) passed, $(cnt sim FAIL) failed"
echo "SYN: $(cnt syn ok) passed, $(cnt syn FAIL) failed"
echo "APB: $(cnt apb ok) passed, $(cnt apb FAIL) failed"
[ -n "$failed" ] && echo "FAILED:$failed"
echo "=================================================="
[ -z "$failed" ] && [ "$(wc -l < work/ci_results.txt)" -eq "$(printf '%s\n' $protos | wc -l)" ]
