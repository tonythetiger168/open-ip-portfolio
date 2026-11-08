#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
"""strict_elab.py [P ...] -- strict IEEE 1800 elaboration of every IP's RTL.

Icarus Verilog accepts some code that the standard forbids, for example a
net used above its declaration (issue #25). This script elaborates each IP's
core, its DEPS and its APB wrapper together with slang (pyslang, the same
front end the coverage flow uses) and fails on any error, so CI catches what
iverilog lets through. The file set comes from Makefile.<P> (S and DEPS).

  python3 scripts/lint/strict_elab.py          # all IPs, exit 1 on any error
  python3 scripts/lint/strict_elab.py DDR4_Lite
"""
import glob
import os
import re
import sys

from pyslang import ast, syntax


def files_of(mk):
    txt = open(mk).read()
    s = re.search(r"^S\s*:=\s*(\S+)", txt, re.M).group(1)
    m = re.search(r"^DEPS\s*:=(.*)$", txt, re.M)
    deps = m.group(1).split() if m else []
    fs = [f"rtl/{s}_top.sv"] + deps
    if os.path.exists(f"rtl/{s}_apb.sv"):
        fs.append(f"rtl/{s}_apb.sv")
    return s, fs


def main():
    want = set(sys.argv[1:])
    bad = 0
    n = 0
    for mk in sorted(glob.glob("Makefile.*")):
        s, fs = files_of(mk)
        if want and s not in want:
            continue
        n += 1
        c = ast.Compilation()
        for f in fs:
            c.addSyntaxTree(syntax.SyntaxTree.fromFile(f))
        errs = [d for d in c.getAllDiagnostics() if d.isError()]
        if errs:
            bad += 1
            sm = c.sourceManager
            for d in errs:
                loc = d.location
                print(f"STRICT_ELAB_ERROR {s}: {sm.getFileName(loc)}:"
                      f"{sm.getLineNumber(loc)}: {d.code}")
    print(f"strict elaboration: {n - bad}/{n} IPs clean")
    return 1 if bad else 0


if __name__ == "__main__":
    sys.exit(main())
