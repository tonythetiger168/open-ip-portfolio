#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
"""Writes the constant table of rtl/Ethernet_PCS_top.sv (the block between
the GENERATED TABLES markers) from the reference model pcs_ref.py:

  AMG   am_mapped<1919:0>, the 16 alignment markers of Table 119-2,
        10-bit interleaved as 119.2.4.4.2 maps them (bit 0 sent first)

  python3 scripts/ethpcs/gen_tables.py          # rewrite the RTL block
  python3 scripts/ethpcs/gen_tables.py --check  # exit 1 if it is stale
"""
import os, sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from pcs_ref import AM_FIXED  # noqa: E402

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
RTL = os.path.join(ROOT, "rtl", "Ethernet_PCS_top.sv")
B, E = "  // ---- BEGIN GENERATED TABLES", "  // ---- END GENERATED TABLES"

h = f"{AM_FIXED:0480x}"
rows = [h[i:i + 96] for i in range(0, 480, 96)]
body = ["  // AMG: the alignment marker group without its pad and status bits",
        "  localparam logic [1919:0] AMG = {"]
body += [f"    384'h{r}" + ("," if i < len(rows) - 1 else "};") for i, r in enumerate(rows)]
s = open(RTL).read()
i = s.index(B)
i = s.index("\n", i) + 1
j = s.index(E)
new = s[:i] + "\n".join(body) + "\n" + s[j:]
if "--check" in sys.argv:
    sys.exit(0 if new == s else 1)
open(RTL, "w").write(new)
