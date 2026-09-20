#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
"""Parse Verilator coverage.dat -> line/toggle hit ratios for the DUT only.
Usage: parse_cov.py <coverage.dat> <dut_source_basename.sv>
Prints:  LINE: hit/total (pct)   TOGGLE: hit/total (pct)"""
import subprocess, sys, re

def main():
    dat, dut = sys.argv[1], sys.argv[2]
    out = subprocess.run(["verilator_coverage", "--write-info", "/dev/stdout", dat],
                         capture_output=True, text=True)
    if out.returncode != 0:
        # fallback: verilator_coverage writes cov.info in cwd
        subprocess.run(["verilator_coverage", "--write-info", "cov.info", dat], check=True)
        text = open("cov.info").read()
    else:
        text = out.stdout
    line_tot = line_hit = 0
    cur_sf = None
    # LCOV: DA:<line>,<hits> is line coverage. Toggle data appears as DA on
    # synthetic lines in newer formats; if absent we parse the .dat directly.
    for ln in text.splitlines():
        if ln.startswith("SF:"):
            cur_sf = ln[3:].strip()
        elif ln.startswith("DA:") and cur_sf and cur_sf.endswith(dut.split("/")[-1]):
            line_tot += 1
            try:
                if int(ln.split(",")[1]) > 0:
                    line_hit += 1
            except (IndexError, ValueError):
                pass
    print(f"LINE: {line_hit}/{line_tot} ({(100*line_hit/line_tot if line_tot else 0):.1f}%)")
    # toggle: count points directly from coverage.dat pages
    raw = subprocess.run(["strings", dat], capture_output=True, text=True).stdout
    tp = re.findall(r"v_toggle/", raw)
    # toggle hit counts need verilator_coverage annotate; approximate via dat
    # page entries: each toggle point line ends with a count; count >0 as hit.
    t_tot = t_hit = 0
    in_tog = False
    dut_base = dut.split("/")[-1].replace(".sv", "")
    for ln2 in raw.splitlines():
        m_page = re.match(r"v_(\w+)/", ln2)
        if m_page:
            # stay in the toggle page only; any other page (line/branch/...)
            # ends it (previously v_branch entries bled into the toggle count)
            in_tog = (m_page.group(1) == "toggle") and (dut_base in ln2)
            continue
        if in_tog:
            m = re.search(r"'\s*(\d+)$", ln2)
            if m:
                t_tot += 1
                if int(m.group(1)) > 0:
                    t_hit += 1
    if t_tot:
        print(f"TOGGLE: {t_hit}/{t_tot} ({100*t_hit/t_tot:.1f}%)")
    else:
        print("TOGGLE: n/a")

if __name__ == "__main__":
    main()
