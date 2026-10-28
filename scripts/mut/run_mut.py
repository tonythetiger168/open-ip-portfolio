#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
"""Mutation testing of the core testbenches (Icarus Verilog).

For each IP, picks up to N mutation sites in rtl/<S>_top.sv (relational,
logical and constant-bit operators, deterministic sample), applies one
mutant at a time in a private copy of the tree and runs
`make -f Makefile.<P> sim`. A mutant is KILLED when the testbench does not
print TEST PASSED (or hangs past the timeout), SURVIVED when it still passes,
and INVALID when it does not compile (not counted). The score is
killed / (killed + survived).

This scores the self-checking testbench alone. The Verilator coverage
checkers (tb/cov/<P>_sva.sv) kill more, so this is a lower bound.

  python3 scripts/mut/run_mut.py I2C UART          # selected IPs
  python3 scripts/mut/run_mut.py --all -n 12 -j 4  # every IP
  python3 scripts/mut/run_mut.py --all --min 0.8   # exit 1 below 80%

Results: work/mut/<P>.json and a table on stdout (survivors listed with
their line, so each one is either a TB gap to close or an equivalent mutant).
"""
import argparse, json, os, random, re, shutil, subprocess, sys, tempfile, time
from concurrent.futures import ThreadPoolExecutor

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))

# (pattern, replacement); each match position is one candidate site
OPS = [
    (r"==", "!="), (r"!=", "=="),
    (r"&&", "||"), (r"\|\|", "&&"),
    (r"1'b1", "1'b0"), (r"1'b0", "1'b1"),
    (r"(?<![<>=!-])>(?![>=])", ">="), (r">=", ">"),
    (r"\+ *1\b(?!')", "+ 2"), (r"- *1\b(?!')", "- 2"),
]


def code_part(line):
    return line.split("//", 1)[0]


def sites(src):
    out = []
    in_block = False
    for ln, line in enumerate(src.splitlines()):
        code = code_part(line)
        if "/*" in code:
            in_block = True
        if in_block:
            if "*/" in code:
                in_block = False
            continue
        s = code.strip()
        # skip declarations, parameters, preprocessor and assertion text
        if not s or s.startswith(("`", "localparam", "parameter", "input", "output",
                                  "inout", "module", "endmodule", "assert", "$")):
            continue
        for pat, rep in OPS:
            for m in re.finditer(pat, code):
                out.append((ln, m.start(), m.end(), rep))
    return out


def mutate(src, site):
    ln, a, b, rep = site
    lines = src.splitlines(keepends=True)
    lines[ln] = lines[ln][:a] + rep + lines[ln][b:]
    return "".join(lines)


def tree(tmp, rtl_rel, text):
    """A private copy of the repository: symlinks, except for real rtl/, tb/,
    tb/cov/ and work/ directories, so the mutant and every generated file
    (simv, tb/cov/<P>_fsm_cov.sv, work/cov/) stay inside tmp."""
    real = {"rtl", "tb", os.path.join("tb", "cov"), "work"}
    for d, subdirs, files in os.walk(ROOT):
        rel = os.path.relpath(d, ROOT)
        if rel != "." and rel not in real:
            continue
        os.makedirs(os.path.join(tmp, rel), exist_ok=True)
        for f in subdirs + files:
            r = os.path.normpath(os.path.join(rel, f))
            if r in real or r == ".git" or (rel == "." and (f.startswith("simv") or f.endswith(".vcd"))):
                continue
            if rel == "work" or r.endswith("_fsm_cov.sv"):
                continue   # build outputs: regenerated inside tmp
            os.symlink(os.path.join(ROOT, r), os.path.join(tmp, r))
        subdirs[:] = [x for x in subdirs if os.path.normpath(os.path.join(rel, x)) in real]
    os.makedirs(os.path.join(tmp, "work"), exist_ok=True)
    if text is not None:
        dst = os.path.join(tmp, rtl_rel)
        os.unlink(dst)
        open(dst, "w").write(text)


def run_one(flow, P, rtl_rel, text, timeout):
    tmp = tempfile.mkdtemp(prefix=f"mut_{P}_")
    try:
        tree(tmp, rtl_rel, text)
        if flow == "sim":
            cmd = ["make", "-s", "-f", os.path.join(tmp, f"Makefile.{P}"), "sim"]
        else:
            cmd = ["bash", os.path.join(tmp, "scripts", "cov", "run_cov.sh"), P]
        try:
            r = subprocess.run(cmd, cwd=tmp, timeout=timeout, capture_output=True, text=True)
        except subprocess.TimeoutExpired:
            return "KILLED"   # hang: the TB's watchdog or our timeout
        if flow == "sim":
            if not os.path.exists(os.path.join(tmp, "simv")):
                return "INVALID"  # did not compile (the tree is fresh, so no stale simv)
            return "SURVIVED" if "TEST PASSED" in r.stdout + r.stderr else "KILLED"
        # cov: the testbench plus the bound checker (reference model + SVA)
        out = r.stdout + r.stderr
        if "BUILD_FAIL" in out or "FSM_GEN_FAIL" in out:
            return "INVALID"
        score = os.path.join(tmp, "work", "cov", P, "score.json")
        if not os.path.exists(score):
            return "KILLED"   # crashed before writing coverage
        sj = json.load(open(score))
        return "SURVIVED" if sj["test_passed"] and not sj["sva_failures"] else "KILLED"
    finally:
        shutil.rmtree(tmp, ignore_errors=True)


def one(flow, P, n, seed):
    mk = open(os.path.join(ROOT, f"Makefile.{P}")).read()
    S = re.search(r"^S\s*:?=\s*(\S+)", mk, re.M).group(1)
    rtl_rel = f"rtl/{S}_top.sv"
    src = open(os.path.join(ROOT, rtl_rel)).read()
    t0 = time.time()
    if run_one(flow, P, rtl_rel, None, 3600) != "SURVIVED":
        return {"ip": P, "error": f"baseline ({flow}) does not pass"}
    base = time.time() - t0
    timeout = max(60, 3 * base)
    cand = sites(src)
    random.Random(f"{seed}:{P}").shuffle(cand)
    res = []
    for site in cand:
        if len(res) >= n:
            break
        st = run_one(flow, P, rtl_rel, mutate(src, site), timeout)
        if st == "INVALID":
            continue
        ln, a, b, rep = site
        line = src.splitlines()[ln]
        res.append({"line": ln + 1, "from": line[a:b], "to": rep, "status": st,
                    "code": line.strip()})
    k = sum(r["status"] == "KILLED" for r in res)
    return {"ip": P, "flow": flow, "sites": len(cand), "mutants": len(res), "killed": k,
            "score": (k / len(res)) if res else None, "results": res}


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("ips", nargs="*")
    ap.add_argument("--all", action="store_true")
    ap.add_argument("-n", type=int, default=12, help="mutants per IP (default 12)")
    ap.add_argument("-j", type=int, default=os.cpu_count(), help="IPs in parallel")
    ap.add_argument("--seed", default="1")
    ap.add_argument("--flow", choices=("sim", "cov"), default="sim",
                    help="sim: Icarus testbench only; cov: Verilator run_cov.sh (testbench + checker)")
    ap.add_argument("--shard", default="1/1", help="K/N: every N-th IP starting at the K-th")
    ap.add_argument("--min", type=float, default=None, help="fail below this score")
    a = ap.parse_args()
    ips = a.ips or []
    if a.all:
        ips = sorted(f[len("Makefile."):] for f in os.listdir(ROOT)
                     if f.startswith("Makefile.") and f != "Makefile.common")
    if not ips:
        ap.error("name IPs or pass --all")
    k, n = (int(x) for x in a.shard.split("/"))
    ips = ips[k - 1::n]
    os.makedirs(os.path.join(ROOT, "work", "mut"), exist_ok=True)
    tot_k = tot_m = 0
    bad = []
    with ThreadPoolExecutor(a.j) as ex:
        for r in ex.map(lambda P: one(a.flow, P, a.n, a.seed), ips):
            json.dump(r, open(os.path.join(ROOT, "work", "mut", f"{r['ip']}.json"), "w"), indent=1)
            if "error" in r:
                print(f"{r['ip']:40s} ERROR {r['error']}")
                bad.append(r["ip"])
                continue
            tot_k += r["killed"]; tot_m += r["mutants"]
            sc = "n/a" if r["score"] is None else f"{100 * r['score']:.0f}%"
            print(f"{r['ip']:40s} {r['killed']:3d}/{r['mutants']:<3d} {sc}", flush=True)
            for m in r["results"]:
                if m["status"] == "SURVIVED":
                    print(f"    survived line {m['line']}: {m['from']} -> {m['to']}   {m['code'][:80]}")
            if a.min is not None and r["score"] is not None and r["score"] < a.min:
                bad.append(r["ip"])
    if tot_m:
        print(f"TOTAL {tot_k}/{tot_m} killed ({100 * tot_k / tot_m:.1f}%), {len(ips)} IPs, flow {a.flow}")
    return 1 if bad else 0


if __name__ == "__main__":
    sys.exit(main())
