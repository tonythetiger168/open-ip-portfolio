#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# CI regression: run sim + syn for every Makefile.<PROTOCOL>, serially.
# Exits non-zero if any protocol fails. Prints a summary table at the end.
set -u
cd "$(dirname "$0")/.."

mkdir -p work
pass_sim=0; fail_sim=0; pass_syn=0; fail_syn=0
failed=""

for mk in Makefile.*; do
  [ "$mk" = "Makefile.common" ] && continue
  proto="${mk#Makefile.}"
  if make -f "$mk" sim >"work/ci_sim_${proto}.log" 2>&1 && grep -q "TEST PASSED" "work/ci_sim_${proto}.log"; then
    pass_sim=$((pass_sim+1))
  else
    fail_sim=$((fail_sim+1)); failed="$failed sim:$proto"
  fi
  if make -f "$mk" syn >"work/ci_syn_${proto}.log" 2>&1 && ! grep -q "ERROR" "work/ci_syn_${proto}.log"; then
    pass_syn=$((pass_syn+1))
  else
    fail_syn=$((fail_syn+1)); failed="$failed syn:$proto"
  fi
  rm -f simv simv_bitclks
done

echo "=================================================="
echo "SIM: $pass_sim passed, $fail_sim failed"
echo "SYN: $pass_syn passed, $fail_syn failed"
[ -n "$failed" ] && echo "FAILED:$failed"
echo "=================================================="
[ "$fail_sim" -eq 0 ] && [ "$fail_syn" -eq 0 ]
