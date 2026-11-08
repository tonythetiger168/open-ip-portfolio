#!/bin/sh
# SPDX-License-Identifier: Apache-2.0
# setup_tools.sh -- idempotent EDA toolchain restore
# Run after every environment reset. Safe to run multiple times.
# Usage: sh setup_tools.sh
# Installs yosys from apt and Icarus Verilog 13.0 (what CI uses) from source
# into /usr/local: distro iverilog 12 accepts some illegal code, such as a net
# used above its declaration (issue #25). IVERILOG_VERSION overrides the tag.
set -e

IVERILOG_VERSION="${IVERILOG_VERSION:-v13_0}"
want_major=$(echo "$IVERILOG_VERSION" | sed 's/^v//; s/_.*//')

iv_major() {
  iverilog -V 2>/dev/null | head -1 | sed -n 's/^Icarus Verilog version \([0-9]*\)\..*/\1/p'
}

echo "== checking EDA tools =="
need_apt=0
command -v yosys >/dev/null 2>&1 || need_apt=1
need_iv=0
[ "$(iv_major)" = "$want_major" ] || need_iv=1

if [ "$need_apt" = "0" ] && [ "$need_iv" = "0" ]; then
  echo "iverilog: $(iverilog -V 2>/dev/null | head -1)"
  echo "yosys:    $(yosys -V 2>/dev/null)"
  echo "== all tools present =="
  exit 0
fi

# 1. ensure a reachable apt mirror (msh.team mirror is unreachable)
if grep -rq "mirrors.msh.team" /etc/apt/sources.list /etc/apt/sources.list.d/ 2>/dev/null; then
  echo "-- switching apt mirror to deb.debian.org"
  sed -i 's|http://mirrors.msh.team/debian-security|http://deb.debian.org/debian-security|; s|http://mirrors.msh.team/debian|http://deb.debian.org/debian|' \
    /etc/apt/sources.list /etc/apt/sources.list.d/*.sources /etc/apt/sources.list.d/*.list 2>/dev/null || true
fi

# 2. refresh package index (tolerate partial failure)
apt-get update 2>&1 | tail -1 || true

# 3. yosys from apt
if [ "$need_apt" = "1" ]; then
  echo "== installing yosys via apt =="
  DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends yosys 2>&1 | tail -2
fi

# 4. iverilog from source (about 3 minutes on 4 cores)
if [ "$need_iv" = "1" ]; then
  echo "== building iverilog $IVERILOG_VERSION from source =="
  DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
    git autoconf gperf flex bison g++ make libfl-dev zlib1g-dev 2>&1 | tail -2
  src=$(mktemp -d)
  git clone -q -b "$IVERILOG_VERSION" --depth 1 https://github.com/steveicarus/iverilog.git "$src"
  (cd "$src" && sh autoconf.sh >/dev/null && ./configure --prefix=/usr/local >/dev/null &&
   make -j"$(nproc)" >/dev/null && make install >/dev/null)
  rm -rf "$src"
  hash -r 2>/dev/null || true
fi

echo "== verify =="
iverilog -V | head -1
yosys -V
[ "$(iv_major)" = "$want_major" ] || { echo "iverilog $want_major not first in PATH (check /usr/local/bin)"; exit 1; }
echo "== done =="
