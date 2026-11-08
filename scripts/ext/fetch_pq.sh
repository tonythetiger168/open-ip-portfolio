#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# Fetch the pq-pipeline-sv stages (a private repository) at a pinned commit
# into ext/pq/ (git-ignored) for `make -f Makefile.PQ_MEMC sim_ext`. Needs
# read access to the repository with your own GitHub credentials; nothing
# from it is ever committed here. Without access, PQ_MEMC uses the open
# stages in rtl/pq/pq_stages.sv (the default build and CI).
set -euo pipefail
cd "$(dirname "$0")/../.."
REPO=${PQ_REPO:-https://github.com/tonythetiger168/pq-pipeline-sv.git}
COMMIT=508427e629b52f907a6ceae1a83da686ffa8bbcb
rm -rf ext/pq ext/.pq_src
git clone -q "$REPO" ext/.pq_src
git -C ext/.pq_src checkout -q "$COMMIT"
mkdir -p ext/pq
for f in pq_pkg l0_metadata_unit l1_tone_map_eetf l2d_memc_blend; do cp "ext/.pq_src/rtl/$f.sv" ext/pq/; done
rm -rf ext/.pq_src
echo "ext/pq: pq-pipeline-sv @ ${COMMIT:0:12}"
