#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
"""Score one protocol's Verilator run on the five coverage metrics.

  LINE        v_line + v_branch points in the DUT RTL files
  TOGGLE      v_toggle points in the DUT RTL files
  FSM         fsm_st__* / fsm_arc__* cover properties (tb/cov/<P>_fsm_cov.sv)
  SVA         assertions: exercised (<name>__ante cover hit) and never failed
  FUNCTIONAL  covergroup bins (v_covergroup) + fc_* cover properties

Points are merged per module (Verilator's page field carries the module
name): a point is hit if any instance of that module hits it. Designs with
one DUT instance are unaffected; a TB that instantiates a module twice with
different parameters (e.g. both accept latencies) covers the union.

Exclusions: scripts/cov/exclude/<P>.txt, one per line
  <METRIC> <regex on point id> # <justification>   (justification mandatory;
  the regex is everything up to " # ")
LINE point ids end in " | <source line text>", so an exclusion can name the
code it waives instead of a line number. A point is excluded only if it is a
hole AND matches; excluded points stay in
the total, are counted as closed and listed separately (reported as
"raw x/y, +N excluded"). Unused exclusion lines are reported as stale.

Usage: score.py <coverage.dat> <run.log> <PROTOCOL> <rtl files...> [--json out]
Exit status 0 only if the test passed, no SVA failed and every metric is 100%.
"""
import glob, json, re, sys

def canon_factory(files):
    """Map a Verilator page module (possibly a parameter variant such as
    OCP_top__AB0 or X__pi3) back to the declared module name."""
    mods = set()
    for f in files:
        try:
            mods |= set(re.findall(r"^\s*module\s+(\w+)", open(f).read(), re.M))
        except OSError:
            pass
    by_len = sorted(mods, key=len, reverse=True)
    cache = {}
    def canon(name):
        if name not in cache:
            cache[name] = next((m for m in by_len
                                if name == m or name.startswith(m + "__")), name)
        return cache[name]
    return canon

def parse_dat(path):
    pts = []
    for ln in open(path, encoding="latin1"):
        if not ln.startswith("C '"):
            continue
        body, cnt = ln.rstrip("\n").rsplit("' ", 1)
        d = {}
        for x in body[3:].split("\x01"):
            if "\x02" in x:
                k, v = x.split("\x02", 1)
                d[k] = v
        for k in ("o", "h"):
            if k in d:   # Verilator mangles "__" in identifiers to "___05F"
                d[k] = d[k].replace("___05F", "__")
        d["count"] = int(cnt)
        pts.append(d)
    return pts

def main():
    a = sys.argv[1:]
    jout = None
    if "--json" in a:
        i = a.index("--json"); jout = a[i + 1]; del a[i:i + 2]
    dat, log, proto, rtl = a[0], a[1], a[2], a[3:]
    rtl = set(rtl)
    pts = parse_dat(dat)
    src = {}
    for f in rtl:
        try:
            src[f] = open(f).read().split("\n")
        except OSError:
            src[f] = []
    logtxt = open(log, errors="replace").read()
    canon = canon_factory(list(rtl) + glob.glob(f"tb/cov/{proto}_*.sv"))

    m = {k: {} for k in ("LINE", "TOGGLE", "FSM", "SVA", "FUNCTIONAL")}
    ante = {}
    for p in pts:
        page = p.get("page", "")
        kind, _, mod = page.partition("/")
        mod = canon(mod)
        f = p.get("f", "")
        if kind in ("v_line", "v_branch") and f in rtl:
            ln_no = int(p.get("l", 0))
            text = src[f][ln_no - 1].strip() if 0 < ln_no <= len(src[f]) else ""
            key = f"{f}:{ln_no}:{p.get('o','')}:{mod} | {text}"
            m["LINE"][key] = m["LINE"].get(key, 0) + p["count"]
        elif kind == "v_toggle" and f in rtl:
            key = f"{mod}.{p.get('o','')}"
            m["TOGGLE"][key] = m["TOGGLE"].get(key, 0) + p["count"]
        elif kind == "v_user":
            name = p.get("o", "")
            if name.startswith("fsm_"):
                k = f"{mod}.{name}"; m["FSM"][k] = m["FSM"].get(k, 0) + p["count"]
            elif name.endswith("__ante"):
                k = f"{mod}.{name[:-6]}"; ante[k] = ante.get(k, 0) + p["count"]
            elif name.startswith("fc_"):
                k = f"{mod}.{name}"; m["FUNCTIONAL"][k] = m["FUNCTIONAL"].get(k, 0) + p["count"]
        elif kind == "v_covergroup":
            key = f"{mod}:{p.get('h','')}"   # h = cg.cp.bin (already per type)
            m["FUNCTIONAL"][key] = m["FUNCTIONAL"].get(key, 0) + p["count"]
    fails = set(re.findall(r"SVA_FAIL: (\S+)", logtxt))
    for k, c in ante.items():
        short = k.rsplit(".", 1)[1]
        m["SVA"][k] = 0 if short in fails else c

    excl = []
    try:
        for ln in open(f"scripts/cov/exclude/{proto}.txt"):
            ln = ln.strip()
            if not ln or ln.startswith("#"):
                continue
            met, rest = ln.split(None, 1)
            rx, why = rest.split(" # ", 1) if " # " in rest else (rest, "")
            if not why.strip():
                sys.exit(f"exclusion without justification: {ln}")
            excl.append([met, re.compile(rx.strip()), why.strip(), 0])
    except FileNotFoundError:
        pass

    passed = bool(re.search(r"TEST PASSED", logtxt)) and not re.search(r"TEST FAILED", logtxt)
    ok = passed and not fails
    res = {"protocol": proto, "test_passed": passed, "sva_failures": sorted(fails),
           "metrics": {}}
    print(f"===== {proto} =====")
    print(f"TEST: {'PASSED' if passed else 'FAILED'}   SVA_FAILURES: {len(fails)}"
          + (f" {sorted(fails)}" if fails else ""))
    for met, d in m.items():
        tot = len(d)
        hit = sum(1 for c in d.values() if c > 0)
        holes = [k for k, c in d.items() if c == 0]
        ex = []
        for h in holes:
            for e in excl:
                if e[0] == met and e[1].search(h):
                    ex.append((h, e[2])); e[3] += 1
                    break
        exk = {h for h, _ in ex}
        open_h = [h for h in holes if h not in exk]
        closed = tot - len(open_h)
        pct = 100.0 * closed / tot if tot else 100.0
        if tot and open_h:
            ok = False
        tag = "N/A (no points)" if tot == 0 else f"{closed}/{tot} ({pct:.1f}%)"
        extra = f"  [raw {hit}/{tot}, +{len(ex)} excluded]" if ex else ""
        print(f"{met:<11} {tag}{extra}")
        for h in open_h[:40]:
            print(f"    HOLE {h}")
        if len(open_h) > 40:
            print(f"    ... {len(open_h)-40} more holes")
        res["metrics"][met] = {"total": tot, "hit": hit, "excluded": len(ex),
                               "closed": closed, "holes": open_h,
                               "excluded_points": ex}
    for e in excl:
        if e[3] == 0:
            print(f"STALE EXCLUSION: {e[0]} {e[1].pattern}")
    res["closed"] = ok
    print("RESULT:", "CLOSED" if ok else "OPEN")
    if jout:
        json.dump(res, open(jout, "w"), indent=1)
    sys.exit(0 if ok else 1)

if __name__ == "__main__":
    main()
