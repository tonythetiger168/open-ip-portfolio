#!/bin/sh
# SPDX-License-Identifier: Apache-2.0
# setup_tools.sh -- idempotent EDA toolchain restore
# Run after every environment reset. Safe to run multiple times.
# Usage: sh setup_tools.sh
set -e

echo "== checking EDA tools =="
need_apt=0
command -v iverilog >/dev/null 2>&1 || need_apt=1
command -v yosys   >/dev/null 2>&1 || need_apt=1

if [ "$need_apt" = "0" ]; then
  echo "iverilog: $(iverilog -V 2>/dev/null | head -1)"
  echo "yosys:    $(yosys -V 2>/dev/null)"
  echo "== all tools present =="
  exit 0
fi

echo "== tools missing, restoring via apt =="

# 1. ensure a reachable apt mirror (msh.team mirror is unreachable)
if grep -rq "mirrors.msh.team" /etc/apt/sources.list /etc/apt/sources.list.d/ 2>/dev/null; then
  echo "-- switching apt mirror to deb.debian.org"
  sed -i 's|http://mirrors.msh.team/debian-security|http://deb.debian.org/debian-security|; s|http://mirrors.msh.team/debian|http://deb.debian.org/debian|' \
    /etc/apt/sources.list /etc/apt/sources.list.d/*.sources /etc/apt/sources.list.d/*.list 2>/dev/null || true
fi

# 2. refresh package index (tolerate partial failure)
apt-get update 2>&1 | tail -1 || true

# 3. install
DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends iverilog yosys 2>&1 | tail -2

echo "== verify =="
iverilog -V | head -1
yosys -V
echo "== done =="
