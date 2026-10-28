#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
"""Write sim/filelist_<S>.f for every Makefile.<P> from the Makefile's own
sim recipe (core RTL, DEPS, testbench), so the filelists cannot drift from
what `make sim` compiles. Paths are relative to sim/:

  cd sim && iverilog -g2012 -c filelist_I2C.f -o simv

  python3 scripts/gen_filelists.py           # rewrite every filelist
  python3 scripts/gen_filelists.py --check   # exit 1 if any is out of date
"""
import os, re, sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))


def var(mk, name):
    m = re.search(rf"^{name}\s*:?=(.*)$", mk, re.M)
    return m.group(1).split() if m else []


def filelist(P):
    mk = open(os.path.join(ROOT, f"Makefile.{P}")).read()
    S = var(mk, "S")[0]
    lines = ["+incdir+../tb"] if "-I tb" in mk else []
    lines += [f"../{f}" for f in [f"rtl/{S}_top.sv", *var(mk, "DEPS"), f"tb/{S}_tb.sv"]]
    return S, "\n".join(lines) + "\n"


def main():
    check = "--check" in sys.argv[1:]
    stale = []
    for mk in sorted(os.listdir(ROOT)):
        if not mk.startswith("Makefile.") or mk == "Makefile.common":
            continue
        S, text = filelist(mk[len("Makefile."):])
        path = os.path.join(ROOT, "sim", f"filelist_{S}.f")
        old = open(path).read() if os.path.exists(path) else None
        if old != text:
            stale.append(path)
            if not check:
                open(path, "w").write(text)
    for p in stale:
        print(("STALE " if check else "wrote ") + os.path.relpath(p, ROOT))
    return 1 if check and stale else 0


if __name__ == "__main__":
    sys.exit(main())
