#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# run_all.sh [JOBS] -- five-metric coverage regression over every IP that
# has a checker (tb/cov/<P>_sva.sv, and <P>_apb for each APB wrapper); prints one RESULT line per IP and
# exits 1 unless all of them are CLOSED. Each build directory is removed after
# scoring (coverage.dat is kept in work/cov/<P>/) so a full run fits on disk.
#   bash scripts/cov/run_all.sh 4
set -u
cd "$(dirname "$0")/../.."
JOBS="${1:-4}"
mkdir -p work/cov
ls tb/cov/*_sva.sv | sed 's#tb/cov/##; s#_sva\.sv$##' |
  xargs -P "$JOBS" -I{} sh -c 'r=$(bash scripts/cov/run_cov.sh {} 2>&1 | grep -E "^(RESULT|BUILD_FAIL|NO_|OLD_)" | head -1); echo "{} ${r:-NO_RESULT}"; mv -f work/cov/{}/obj/coverage.dat work/cov/{}/ 2>/dev/null; rm -rf work/cov/{}/obj' |
  sort | tee work/cov/run_all.txt
n=$(wc -l < work/cov/run_all.txt)
c=$(grep -c "RESULT: CLOSED" work/cov/run_all.txt)
echo "CLOSED $c/$n"
[ "$c" -eq "$n" ]
