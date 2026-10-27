#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# Build PDF specifications from docs/ip/*.md (pandoc + headless Chromium).
#   bash scripts/doc/build_pdf.sh [OUT_DIR] [IP ...]
# OUT_DIR defaults to work/pdf; with no IP names every page is built, plus
# IP_specifications_all.pdf (every page in one file, the index first).
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/../.." && pwd)
OUT=$(mkdir -p "${1:-$ROOT/work/pdf}" && cd "${1:-$ROOT/work/pdf}" && pwd)
shift || true
CSS="$ROOT/scripts/doc/spec.css"
HTML="$OUT/.html"
mkdir -p "$HTML"
cd "$ROOT/docs/ip"
if [ $# -gt 0 ]; then ips=("$@"); else ips=(README $(ls *.md | sed 's/\.md$//' | grep -v '^README$')); fi
args=()
for p in "${ips[@]}"; do
  t=$(head -1 "$p.md" | sed 's/^# //')
  pandoc "$p.md" -f gfm -t html5 --standalone --embed-resources --css "$CSS" \
    --metadata pagetitle="$t" -o "$HTML/$p.html"
  args+=("$HTML/$p.html" "$OUT/$p.pdf")
done
node "$ROOT/scripts/doc/md2pdf.js" "${args[@]}"
if [ $# -eq 0 ]; then
  # one combined book: the pages one after the other, each starting a new page
  { for p in "${ips[@]}"; do cat "$p.md"; printf '\n\n<div style="break-after: page"></div>\n\n'; done; } |
    pandoc -f gfm -t html5 --standalone --embed-resources --css "$CSS" \
      --metadata pagetitle="IP specifications" -o "$HTML/all.html"
  node "$ROOT/scripts/doc/md2pdf.js" "$HTML/all.html" "$OUT/IP_specifications_all.pdf"
  mv "$OUT/README.pdf" "$OUT/00_index.pdf"
fi
rm -rf "$HTML"
echo "PDFs in $OUT"
