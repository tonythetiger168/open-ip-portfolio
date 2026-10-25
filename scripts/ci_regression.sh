#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# CI regression: run sim + syn (and apb, where the Makefile has it) for every
# Makefile.<PROTOCOL>. Protocols run in parallel (JOBS, default: CPU count),
# each in its own directory under work/ci/ that links the repository's
# files, so each run has a private ./simv and work/. Exits non-zero if any
# protocol fails. Prints a summary table at the end.
#   bash scripts/ci_regression.sh [JOBS]
set -u
cd "$(dirname "$0")/.."
ROOT=$(pwd)
JOBS="${1:-$(nproc)}"

rm -rf work/ci; mkdir -p work/ci

one() {   # one <PROTOCOL>: writes work/ci_{sim,syn,apb}_<P>.log and work/ci/<P>.res
  proto=$1; mk=Makefile.$proto; d=$ROOT/work/ci/$proto
  mkdir -p "$d/work"
  for f in "$ROOT"/*; do
    b=$(basename "$f")
    case "$b" in work|simv*|*.vcd) ;; *) ln -s "$f" "$d/$b" ;; esac   # not build outputs
  done
  cd "$d"
  r=""
  if make -f "$mk" sim >"$ROOT/work/ci_sim_${proto}.log" 2>&1 && grep -q "TEST PASSED" "$ROOT/work/ci_sim_${proto}.log"; then
    r="$r sim:ok"; else r="$r sim:FAIL"; fi
  if make -f "$mk" syn >"$ROOT/work/ci_syn_${proto}.log" 2>&1 && ! grep -q "ERROR" "$ROOT/work/ci_syn_${proto}.log"; then
    r="$r syn:ok"; else r="$r syn:FAIL"; fi
  if grep -q '^apb:' "$mk"; then   # APB register wrapper: sim + syn
    if make -f "$mk" apb >"$ROOT/work/ci_apb_${proto}.log" 2>&1 && grep -q "TEST PASSED" "$ROOT/work/ci_apb_${proto}.log" \
       && ! grep -q "ERROR" "$ROOT/work/ci_apb_${proto}.log"; then
      r="$r apb:ok"; else r="$r apb:FAIL"; fi
  fi
  echo "$r" > "$ROOT/work/ci/$proto.res"
  cd "$ROOT"; rm -rf "$d"
}
export -f one; export ROOT

ls Makefile.* | sed 's/^Makefile\.//' | grep -vx common | xargs -P "$JOBS" -I{} bash -c 'one {}'

pass_sim=0; fail_sim=0; pass_syn=0; fail_syn=0; pass_apb=0; fail_apb=0
failed=""
for res in work/ci/*.res; do
  proto=$(basename "$res" .res)
  for t in $(cat "$res"); do
    k=${t%%:*}; v=${t#*:}
    if [ "$v" = ok ]; then eval "pass_$k=\$((pass_$k+1))"
    else eval "fail_$k=\$((fail_$k+1))"; failed="$failed $k:$proto"; fi
  done
done
n_mk=$(ls Makefile.* | grep -vc 'Makefile\.common$')
n_res=$(ls work/ci/*.res 2>/dev/null | wc -l)
[ "$n_res" -eq "$n_mk" ] || { failed="$failed missing:$((n_mk - n_res))"; fail_sim=$((fail_sim + n_mk - n_res)); }

echo "=================================================="
echo "SIM: $pass_sim passed, $fail_sim failed"
echo "SYN: $pass_syn passed, $fail_syn failed"
echo "APB: $pass_apb passed, $fail_apb failed"
[ -n "$failed" ] && echo "FAILED:$failed"
echo "=================================================="
[ "$fail_sim" -eq 0 ] && [ "$fail_syn" -eq 0 ] && [ "$fail_apb" -eq 0 ]
