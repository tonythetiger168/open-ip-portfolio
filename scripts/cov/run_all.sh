#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# run_all.sh [JOBS] -- five-metric coverage regression over every IP that
# has a checker (tb/cov/<P>_sva.sv, and <P>_apb for each APB wrapper); prints one RESULT line per IP and
# exits 1 unless all of them are CLOSED. Each build directory is removed after
# scoring (coverage.dat and the score report are kept in work/cov/<P>/) so a
# full run fits on disk; the reports of the IPs that are not closed are printed.
#   bash scripts/cov/run_all.sh 4
# Env: SHARD=K/N runs only every N-th IP starting at the K-th (K = 1..N), so CI
# can split the regression across N jobs.
set -u
cd "$(dirname "$0")/../.."
JOBS="${1:-4}"
mkdir -p work/cov
SHARD="${SHARD:-1/1}"
ls tb/cov/*_sva.sv | sed 's#tb/cov/##; s#_sva\.sv$##' |
  awk -v k="${SHARD%/*}" -v n="${SHARD#*/}" '(NR - k) % n == 0' |
  xargs -P "$JOBS" -I{} sh -c 'mkdir -p work/cov/{}; bash scripts/cov/run_cov.sh {} > work/cov/{}/report.txt 2>&1; r=$(grep -E "^(RESULT|BUILD_FAIL|NO_|OLD_)" work/cov/{}/report.txt | head -1); echo "{} ${r:-NO_RESULT}"; mv -f work/cov/{}/obj/coverage.dat work/cov/{}/ 2>/dev/null; rm -rf work/cov/{}/obj' |
  sort | tee work/cov/run_all.txt
n=$(wc -l < work/cov/run_all.txt)
c=$(grep -c "RESULT: CLOSED" work/cov/run_all.txt)
echo "CLOSED $c/$n"
# the score report of every IP that is not closed, so the CI log shows the holes
grep -v "RESULT: CLOSED" work/cov/run_all.txt | while read -r p _; do
  echo "===== $p"
  grep -vE "^(%Warning|  *:|  *\||  *\^)" "work/cov/$p/report.txt" | tail -n 60
done
[ "$c" -eq "$n" ]
