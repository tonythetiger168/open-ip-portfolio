#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
"""Per-IP design specs in docs/spec/<IP>.md (issue #41).

A spec page is hand-written, except for the region between
  <!-- AUTO:registers -->  and  <!-- /AUTO:registers -->
which is copied from the generated register page docs/ip/<IP>.md.

Usage:
  python3 scripts/spec/gen_spec.py            refresh AUTO regions + index, then check
  python3 scripts/spec/gen_spec.py --check    check only; exit 1 if anything is stale or missing
  python3 scripts/spec/gen_spec.py --stub P   write a skeleton docs/spec/P.md to fill in

Checks on every spec page (so that a spec cannot silently fall behind its RTL / TB):
  * the six sections 1. Interface ... 6. TB check map are present, in order
  * every core port of rtl/<IP>_top.sv is named (`port`) in section 1
  * every core-internal signal the TB (dut.x) or the bound checker uses is named in
    section 1, since a re-implementation must provide it under that name
  * every overridable parameter is named in section 4
  * every assertion a_* in tb/cov/<IP>_sva.sv is named in section 6
  * every error message of tb/<IP>_tb.sv (fail("..."), $display("ERROR: ..."),
    sva_check(..., "...")) is quoted in section 6, up to its first format specifier
  * no TODO left
"""
import os, re, sys

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
sys.path.insert(0, os.path.join(ROOT, "scripts", "apb"))
from gen_apb import core_ports, param_names  # noqa: E402

SPEC = os.path.join(ROOT, "docs", "spec")
SECTIONS = ["## 1. Interface", "## 2. Registers", "## 3. Timing", "## 4. Parameters",
            "## 5. Errors and corner cases", "## 6. TB check map"]
BEGIN, END = "<!-- AUTO:registers -->", "<!-- /AUTO:registers -->"


def rd(p):
    return open(p, encoding="utf-8").read()


def reg_block(P):
    """The register part of docs/ip/<P>.md: '## APB wrapper' and '## Programming
    sequence', up to the next other '## ' heading; '## ' headings become '### '."""
    page = os.path.join(ROOT, "docs", "ip", P + ".md")
    if not os.path.exists(page):
        return "This IP has no register interface.\n"
    lines = rd(page).split("\n")
    out, on = [], False
    for ln in lines:
        if ln.startswith("## "):
            if ln.strip() == "## APB wrapper":
                on = True
                continue
            if on and ln.strip() != "## Programming sequence":
                break
        if on:
            out.append("#" + ln if ln.startswith("## ") else ln)
    body = "\n".join(out).strip("\n")
    return (f"Generated from [`docs/ip/{P}.md`](../ip/{P}.md) (source: "
            f"`scripts/apb/specs/{P}.json`); do not edit by hand.\n\n{body}\n")


def tb_messages(P):
    """Error-message prefixes of the core TB: text up to the first format specifier."""
    p = os.path.join(ROOT, "tb", P + "_tb.sv")
    if not os.path.exists(p):
        return []
    src = rd(p)
    msgs = []
    for m in re.finditer(r'\bfail\s*\(\s*(?:\$sformatf\s*\(\s*)?"([^"]*)"', src):
        msgs.append(m.group(1))
    for m in re.finditer(r'\$display\s*\(\s*(?:\$sformatf\s*\(\s*)?"\s*ERROR:\s*([^"]*)"', src):
        msgs.append(m.group(1))
    for m in re.finditer(r'\bsva_check\s*\((?:[^;]*?),\s*"([^"]*)"\s*\)\s*;', src, flags=re.S):
        msgs.append(m.group(1))
    out = []
    for s in msgs:
        s = s.split("%")[0]
        s = re.sub(r"(\s+got)?=$", "", s.rstrip())     # "x got=" -> "x", "rx_byte=" -> "rx_byte"
        s = re.sub(r"\s*\(\w*$", "", s)                 # "... (v=" -> "..."
        s = s.rstrip(" :,(@=-").strip()
        if len(s) >= 3 and s not in out:
            out.append(s)
    return out


def sva_names(P):
    p = os.path.join(ROOT, "tb", "cov", P + "_sva.sv")
    if not os.path.exists(p):
        return []
    names = re.findall(r"`SVA_\w+\s*\(\s*(a_\w+)", rd(p))
    names += re.findall(r"^\s*(a_\w+)\s*:\s*assert\b", rd(p), flags=re.M)
    return list(dict.fromkeys(names))


def internal_names(P, ports):
    """Core-internal signal names the verification relies on: dut.<x> in the core TB and
    the checker's bind connections (.* binds the checker's port names). A re-implementation
    must provide them under these names, so the spec lists them."""
    names = []
    tb = os.path.join(ROOT, "tb", P + "_tb.sv")
    if os.path.exists(tb):
        names += re.findall(r"\bdut\.(\w+)", rd(tb))
    sva = os.path.join(ROOT, "tb", "cov", P + "_sva.sv")
    if os.path.exists(sva):
        src = re.sub(r"//[^\n]*|/\*.*?\*/", "", rd(sva), flags=re.S)
        m = re.search(r"\bbind\s+" + re.escape(P) + r"_top\s+\w+\s*(?:#\s*\((?:[^()]|\([^()]*\))*\)\s*)?"
                      r"\w+\s*\((.*?)\)\s*;", src, flags=re.S)
        h = re.search(r"\bmodule\s+" + re.escape(P) + r"_sva\b\s*(#\s*\(.*?\)\s*)?\((.*?)\)\s*;", src, flags=re.S)
        if m and m.group(1).strip() == ".*" and h:
            for seg in h.group(2).split(","):
                w = re.findall(r"[A-Za-z_]\w*", re.sub(r"\[[^\]]*\]", "", seg))
                if w and w[-1] not in ("logic", "wire", "input", "output", "bit"):
                    names.append(w[-1])
        elif m:
            for conn in re.findall(r"\.\w+\s*\(([^()]*)\)", m.group(1)):
                names += re.findall(r"[A-Za-z_]\w*", re.sub(r"\[[^\]]*\]", "", conn))
    return [n for n in dict.fromkeys(names) if n not in ports]


def section(txt, i):
    a = txt.find(SECTIONS[i])
    if a < 0:
        return ""
    b = txt.find(SECTIONS[i + 1]) if i + 1 < len(SECTIONS) else len(txt)
    return txt[a:b if b > a else len(txt)]


def check(P, txt):
    errs = []
    pos = [txt.find(s) for s in SECTIONS]
    for s, p in zip(SECTIONS, pos):
        if p < 0:
            errs.append(f"missing section '{s}'")
    if all(p >= 0 for p in pos) and pos != sorted(pos):
        errs.append("sections out of order")
    order, _w, _d, _decl, params, _h = core_ports(os.path.join(ROOT, "rtl", P + "_top.sv"), P + "_top")
    s1, s4, s6 = section(txt, 0), section(txt, 3), section(txt, 5)
    for port in order:
        if f"`{port}`" not in s1:
            errs.append(f"port `{port}` not described in section 1")
    for n in internal_names(P, order):
        if f"`{n}`" not in s1:
            errs.append(f"internal signal `{n}` (used by the TB or checker) not listed in section 1")
    for prm in param_names(params):
        if f"`{prm}`" not in s4:
            errs.append(f"parameter `{prm}` not described in section 4")
    for a in sva_names(P):
        if a not in s6:
            errs.append(f"assertion {a} not mapped in section 6")
    for m in tb_messages(P):
        if m not in s6:
            errs.append(f'TB message "{m}" not mapped in section 6')
    if "TODO" in txt:
        errs.append("TODO left")
    return errs


def refresh(P, txt):
    a, b = txt.find(BEGIN), txt.find(END)
    if a < 0 or b < a:
        return txt
    return txt[:a + len(BEGIN)] + "\n" + reg_block(P) + txt[b:]


def all_ips():
    return sorted(f[:-7] for f in os.listdir(os.path.join(ROOT, "rtl")) if f.endswith("_top.sv"))


def index(done):
    ips = all_ips()
    rows = "\n".join(f"| [{P}]({P}.md) |" for P in done)
    return f"""<!-- SPDX-License-Identifier: Apache-2.0 -->
# IP design specs

Generated by `scripts/spec/gen_spec.py`; do not edit by hand.

One page per IP, written so that the IP can be re-implemented from the page and the
module header alone and pass the IP's own testbench (issue #41). Each page has six
sections: 1. Interface (every port: direction, width, meaning, polarity, clock domain,
reset value), 2. Registers (generated from the APB register page), 3. Timing (cycle by
cycle), 4. Parameters, 5. Errors and corner cases, 6. TB check map (every check of the
core TB and every assertion of its checker, with the spec section that defines it).

`python3 scripts/spec/gen_spec.py --check` (run in CI) fails when a port, parameter,
assertion or TB message is not covered.

Progress: {len(done)} of {len(ips)} IPs.

| IP |
|---|
{rows}
"""


def stub(P):
    order, width, dirn, _decl, params, header = core_ports(os.path.join(ROOT, "rtl", P + "_top.sv"), P + "_top")
    ports = "\n".join(f"| `{p}` | {dirn[p]} | {width[p]} | TODO | TODO | TODO | TODO |" for p in order)
    prms = "\n".join(f"| `{n}` | TODO | TODO | TODO |" for n in param_names(params))
    chk = "\n".join([f'| "{m}" | TODO | §3 |' for m in tb_messages(P)] +
                    [f"| {a} | TODO | §3 |" for a in sva_names(P)])
    return f"""<!-- SPDX-License-Identifier: Apache-2.0 -->
# {P}: design specification

TODO overview. Core `{P}_top` (`rtl/{P}_top.sv`), testbench `tb/{P}_tb.sv`, checker `tb/cov/{P}_sva.sv`.

## 1. Interface

| Port | Dir | Width | Meaning | Active | Clock | Reset |
|---|---|---|---|---|---|---|
{ports}

## 2. Registers

{BEGIN}
{END}

## 3. Timing

TODO

## 4. Parameters

| Parameter | Default | Legal range | Effect |
|---|---|---|---|
{prms}

## 5. Errors and corner cases

TODO

## 6. TB check map

| Check (TB message or assertion) | What it requires | Spec |
|---|---|---|
{chk}
"""


def main():
    a = sys.argv[1:]
    if a[:1] == ["--stub"]:
        for P in a[1:]:
            p = os.path.join(SPEC, P + ".md")
            assert not os.path.exists(p), p + " exists"
            os.makedirs(SPEC, exist_ok=True)
            open(p, "w", encoding="utf-8").write(refresh(P, stub(P)))
            print("wrote", os.path.relpath(p, ROOT))
        return 0
    only_check = a == ["--check"]
    done = sorted(f[:-3] for f in os.listdir(SPEC) if f.endswith(".md") and f != "README.md")
    bad = 0
    for P in done:
        p = os.path.join(SPEC, P + ".md")
        txt = rd(p)
        new = refresh(P, txt)
        if new != txt:
            if only_check:
                print(f"{P}: AUTO:registers region is stale (run scripts/spec/gen_spec.py)")
                bad += 1
            else:
                open(p, "w", encoding="utf-8").write(new)
        for e in check(P, new):
            print(f"{P}: {e}")
            bad += 1
    idx = os.path.join(SPEC, "README.md")
    want = index(done)
    if not os.path.exists(idx) or rd(idx) != want:
        if only_check:
            print("docs/spec/README.md is stale (run scripts/spec/gen_spec.py)")
            bad += 1
        else:
            open(idx, "w", encoding="utf-8").write(want)
    print(f"specs: {len(done)} of {len(all_ips())} IPs, {bad} problem(s)")
    return 1 if bad else 0


if __name__ == "__main__":
    sys.exit(main())
