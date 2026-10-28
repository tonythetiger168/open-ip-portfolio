#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
"""Rebuild the standalone per-protocol packages releases/open_ip_<P>.zip.

  python3 scripts/package_releases.py            # every Makefile.<P>
  python3 scripts/package_releases.py SAS UART   # selected IPs
  python3 scripts/package_releases.py --check    # also unzip each package in a
                                                 # temp dir and run make sim syn apb

A package holds what `make -f Makefile.<P> sim|syn|apb` reads, at the same
relative paths, plus the IP page and the license:
  Makefile (copy of Makefile.<P>), rtl/<P>_top.sv, rtl/<P>_apb.sv, the DEPS
  files, tb/<P>_tb.sv, tb/<P>_apb_tb.sv and every file they `include,
  syn/<P>_*, sim/filelist_<P>.f, docs/ip/<P>.md, LICENSE, and tb/<P>_vec.hex
  (test vectors) where there is one.
The coverage flow (Verilator, tb/cov/, scripts/cov/) is not packaged; run it
from the repository.
"""
import os, re, shutil, subprocess, sys, tempfile, zipfile

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
INC = re.compile(r'^\s*`include\s+"([^"]+)"', re.M)


def includes(path, seen):
    """path and everything it `includes, resolved against its own dir and tb/."""
    if path in seen or not os.path.exists(os.path.join(ROOT, path)):
        return
    seen.add(path)
    for inc in INC.findall(open(os.path.join(ROOT, path)).read()):
        for base in (os.path.dirname(path), "tb"):
            cand = os.path.normpath(os.path.join(base, inc))
            if os.path.exists(os.path.join(ROOT, cand)):
                includes(cand, seen)
                break


def files_of(P):
    mk = open(os.path.join(ROOT, f"Makefile.{P}")).read()
    S = re.search(r"^S\s*:?=\s*(\S+)", mk, re.M).group(1)
    deps = re.search(r"^DEPS\s*:?=(.*)$", mk, re.M).group(1).split()
    out = set()
    for f in [f"rtl/{S}_top.sv", f"rtl/{S}_apb.sv", *deps]:
        includes(f, out)
    # every TB the Makefile names (tb/<S>_tb.sv, tb/<S>_apb_tb.sv, extra targets)
    for tb in re.findall(r"tb/\$\(S\)(\w*)\.sv", mk):
        includes(f"tb/{S}{tb}.sv", out)
    for d, pat in (("syn", rf"{re.escape(S)}(_apb)?(_yosys\.ys|_dc\.tcl|\.sdc)$"),
                   ("sim", rf"filelist_{re.escape(S)}\.f$")):
        out |= {f"{d}/{f}" for f in os.listdir(os.path.join(ROOT, d)) if re.match(pat, f)}
    for f in (f"docs/ip/{S}.md", "LICENSE", f"tb/{S}_vec.hex"):    # test vectors read by the TBs
        if os.path.exists(os.path.join(ROOT, f)):
            out.add(f)
    return S, mk, sorted(out)


def package(P):
    S, mk, files = files_of(P)
    top = f"open_ip_{P}"
    zpath = os.path.join(ROOT, "releases", f"{top}.zip")
    with zipfile.ZipFile(zpath, "w", zipfile.ZIP_DEFLATED) as z:
        z.writestr(f"{top}/Makefile", mk)
        for f in files:
            z.write(os.path.join(ROOT, f), f"{top}/{f}")
    return zpath, len(files) + 1


def check(P, zpath):
    with tempfile.TemporaryDirectory() as d:
        zipfile.ZipFile(zpath).extractall(d)
        cwd = os.path.join(d, f"open_ip_{P}")
        mk = open(os.path.join(cwd, "Makefile")).read()
        bad = []
        for t in ("sim", "syn", "apb"):
            if not re.search(rf"^{t}:", mk, re.M):
                continue
            r = subprocess.run(["make", t], cwd=cwd, capture_output=True, text=True)
            log = r.stdout + r.stderr
            ok = r.returncode == 0 and "ERROR" not in log and \
                 (t == "syn" or "TEST PASSED" in log)
            if not ok:
                bad.append(t)
        return bad


def main():
    args = sys.argv[1:]
    do_check = "--check" in args
    args = [a for a in args if a != "--check"]
    if not args:
        args = sorted(f[len("Makefile."):] for f in os.listdir(ROOT) if f.startswith("Makefile."))
    os.makedirs(os.path.join(ROOT, "releases"), exist_ok=True)
    fails = 0
    for P in args:
        zpath, n = package(P)
        msg = f"{P}: {n} files"
        if do_check:
            bad = check(P, zpath)
            msg += "  OK" if not bad else f"  FAIL {' '.join(bad)}"
            fails += bool(bad)
        print(msg, flush=True)
    sys.exit(1 if fails else 0)


if __name__ == "__main__":
    main()
