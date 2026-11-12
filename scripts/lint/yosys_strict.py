#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
"""yosys_strict.py [-j N] [-t SECONDS] [P ...] -- strict Yosys gate for every IP.

`make -f Makefile.<P> syn` runs a light flow (proc / opt / techmap) and CI
only greps its log for "ERROR", so latches, multiply driven nets, undriven
nets that are read and combinational loops pass silently. This script takes
the same file set and top module from every syn/*_yosys.ys (core and APB
wrapper) and runs, per script:

  1. hierarchy -check; proc
  2. no inferred latches          (select -assert-none on $dlatch/$sr cells)
  3. check -assert                (multiple drivers, used-but-undriven
                                   signals, combinational loops)
  4. full `synth` down to gates with ABC (memories are left as $mem cells
     where the light flow keeps `memory -nomap`), then check -assert again
     and a non-empty netlist

Any failure, a Yosys error or a timeout fails the IP; the exit status is 1 if
any IP fails. Logs go to work/yosys_strict/<script>.log.

  python3 scripts/lint/yosys_strict.py              # all scripts, nproc jobs
  python3 scripts/lint/yosys_strict.py UART GbE_DMA # cores + wrappers of these
"""
import argparse
import glob
import os
import re
import subprocess
import sys
import tempfile
import threading
import time
from concurrent.futures import ThreadPoolExecutor

ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", ".."))
LOGDIR = os.path.join(ROOT, "work", "yosys_strict")

LATCH_CELLS = "t:$dlatch t:$adlatch t:$dlatchsr t:$sr"

# Scripts that need 2.5-4 GB each (wide GF datapaths, three SHA3 + ML-DSA):
# at most one of them runs at a time so a 16 GB runner does not hit the OOM
# killer (yosys-abc exit 137).
HEAVY = {"Ethernet_RS_FEC", "SPDM"}
HEAVY_SLOT = threading.Semaphore(1)


def parse(ys):
    """(read_verilog line with absolute paths, top, keeps memories?) of a .ys."""
    txt = open(ys).read()
    reads = [ln for ln in txt.splitlines() if ln.startswith("read_verilog")]
    top = re.search(r"hierarchy\s+-check\s+-top\s+(\S+)", txt).group(1)
    nomap = "memory -nomap" in txt
    rtl = os.path.join(ROOT, "rtl") + "/"
    reads = [ln.replace("../rtl/", rtl) for ln in reads]
    return reads, top, nomap


def script(reads, top, nomap):
    s = list(reads)
    s += [
        f"hierarchy -check -top {top}",
        "proc",
        "opt_clean",
        f"select -assert-none {LATCH_CELLS}",
        "check -assert",
    ]
    if nomap:   # same memory handling as the light flow: keep $mem cells
        s += [
            f"synth -top {top} -run begin:fine",
            "opt -fast -full",
            "techmap",
            "opt -fast",
            "abc -fast",
            "opt -fast",
        ]
    else:
        s += [f"synth -top {top}"]
    s += [
        "check -assert",
        f"select -assert-none {LATCH_CELLS}",
        "select -assert-min 1 t:*",
        "stat",
    ]
    return "\n".join(s) + "\n"


def run(ys, timeout):
    if ip_of(ys) in HEAVY:
        with HEAVY_SLOT:
            return run1(ys, timeout)
    return run1(ys, timeout)


def ip_of(ys):
    return re.sub(r"(_apb)?_yosys\.ys$", "", os.path.basename(ys))


def run1(ys, timeout):
    name = os.path.basename(ys)[:-3]
    log = os.path.join(LOGDIR, name + ".log")
    reads, top, nomap = parse(ys)
    t0 = time.time()
    with tempfile.TemporaryDirectory() as d:
        sf = os.path.join(d, "strict.ys")
        open(sf, "w").write(script(reads, top, nomap))
        p = subprocess.Popen(["yosys", "-q", "-l", log, sf], cwd=d,
                             stdout=subprocess.DEVNULL,
                             stderr=subprocess.DEVNULL)
        rc, peak = wait(p, timeout)
    dt = time.time() - t0
    why = ""
    if rc != 0:
        why = "timeout" if rc == "timeout" else first_error(log)
    return name, rc == 0, dt, peak, why


def wait(p, timeout):
    """(exit code or "timeout", peak RSS in MB) of a child process."""
    t_end = time.time() + timeout
    while True:
        pid, status, ru = os.wait4(p.pid, os.WNOHANG)
        if pid:
            return os.waitstatus_to_exitcode(status), ru.ru_maxrss // 1024
        if time.time() > t_end:
            p.kill()
            _, _, ru = os.wait4(p.pid, 0)
            return "timeout", ru.ru_maxrss // 1024
        time.sleep(0.5)


def first_error(log):
    try:
        lines = open(log, errors="replace").read().splitlines()
    except OSError:
        return "no log"
    for ln in lines:
        if ln.startswith("ERROR"):
            return ln.strip()
    return "yosys failed"


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("-j", type=int, default=os.cpu_count() or 1)
    ap.add_argument("-t", type=int, default=3600, help="timeout per script (s)")
    ap.add_argument("ips", nargs="*")
    a = ap.parse_args()
    os.makedirs(LOGDIR, exist_ok=True)
    yss = sorted(glob.glob(os.path.join(ROOT, "syn", "*_yosys.ys")))
    if a.ips:
        want = set(a.ips)
        yss = [y for y in yss if ip_of(y) in want]
    bad = []
    with ThreadPoolExecutor(a.j) as ex:
        for name, ok, dt, peak, why in ex.map(lambda y: run(y, a.t), yss):
            print(f"{'PASS' if ok else 'FAIL'} {name} {dt:.0f}s {peak}MB {why}",
                  flush=True)
            if not ok:
                bad.append(name)
    n = len(yss)
    print(f"yosys strict: {n - len(bad)}/{n} scripts clean")
    for b in bad:
        print(f"YOSYS_STRICT_FAIL {b} (log: work/yosys_strict/{b}.log)")
    return 1 if bad or n == 0 else 0


if __name__ == "__main__":
    sys.exit(main())
