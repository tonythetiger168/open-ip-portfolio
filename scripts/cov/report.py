#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
"""Markdown results table from the last run of every IP (work/cov/<P>/score.json).

  python3 scripts/cov/report.py            # cores, then APB wrappers
Prints the core table, the APB wrapper table and the totals of each, in the
format of docs/COVERAGE_CLOSURE.md.
"""
import glob, json, os

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
MET = ("LINE", "TOGGLE", "FSM", "SVA", "FUNCTIONAL")


def cell(m):
    if m["total"] == 0:
        return "n/a"
    s = f'{m["hit"]}/{m["total"]}'
    return s + (f' (+{m["excluded"]} excl.)' if m["excluded"] else "")


def table(names, title):
    out = [f"| {title} | Line | Toggle | FSM | SVA | Functional | Test + assertions |",
           "|---|---|---|---|---|---|---|"]
    tot = {k: [0, 0, 0] for k in MET}
    closed = 0
    for p in names:
        f = os.path.join(ROOT, "work", "cov", p, "score.json")
        if not os.path.exists(f):
            out.append(f"| {p} | not run | | | | | |")
            continue
        d = json.load(open(f))
        ms = d["metrics"]
        for k in MET:
            tot[k][0] += ms[k]["hit"]; tot[k][1] += ms[k]["total"]; tot[k][2] += ms[k]["excluded"]
        ok = d["test_passed"] and not d["sva_failures"]
        closed += bool(d["closed"])
        out.append(f"| {p} | " + " | ".join(cell(ms[k]) for k in MET) + f" | {'pass' if ok else 'FAIL'} |")
    t = ", ".join(f"{k.lower()} {v[0]}/{v[1]}" + (f" (+{v[2]} excluded)" if v[2] else "") for k, v in tot.items())
    return "\n".join(out), closed, len(names), t


cores = sorted(os.path.basename(f)[:-7] for f in glob.glob(os.path.join(ROOT, "tb", "cov", "*_sva.sv"))
               if not f.endswith("_apb_sva.sv"))
apbs = sorted(os.path.basename(f)[:-7] for f in glob.glob(os.path.join(ROOT, "tb", "cov", "*_apb_sva.sv")))
for names, title in ((cores, "IP"), (apbs, "APB wrapper")):
    tab, c, n, t = table(names, title)
    print(f"{c}/{n} closed.\n\n{tab}\n\nTotals: {t}.\n")
