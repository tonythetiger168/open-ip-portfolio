#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
"""Performance report of a memory-controller core.

  perf_report.py <P>        work/perf/<P>/{sim.log,sta.txt} -> docs/perf/<P>.json
  perf_report.py --summary  docs/perf/*.json -> docs/MEMORY_PERFORMANCE.md

The JSON keeps the raw measurements (clocks) and the derived figures; the
Markdown of an IP page's Performance section comes from perf_section(), which
scripts/apb/gen_apb_tb.py calls when docs/perf/<P>.json exists.
"""
import json
import os
import re
import sys

ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", ".."))
PERF_DIR = os.path.join(ROOT, "docs", "perf")
HOST_PEAK_B = 2.0      # host port: one 16-bit word per clock, both families

PATTERNS = [
    ("seq_rd", "Sequential reads, one open row (page hits)"),
    ("seq_wr", "Sequential writes, one open row (page hits)"),
    ("seq_rw", "Alternating write / read, one open row"),
    ("ilv_rd", "Reads interleaved over every bank, rows open"),
    ("conf_rd", "Reads alternating two rows of one bank (row conflicts)"),
    ("rnd_rd", "Random reads (bank, row, column uniform)"),
    ("rnd_wr", "Random writes"),
    ("rnd_mix", "Random mix, 2 reads : 1 write"),
]
LATENCY = [
    ("rd_hit", "Read, page hit"),
    ("rd_closed", "Read, bank closed (ACT first)"),
    ("rd_conflict", "Read, row conflict (PRE + ACT first)"),
    ("wr_hit", "Write, page hit"),
    ("wr_closed", "Write, bank closed"),
    ("wr_conflict", "Write, row conflict"),
]


def timing_params(P):
    """The core's DRAM timing, in clocks, as written in the RTL."""
    src = open(os.path.join(ROOT, "rtl", f"{P}_top.sv")).read()
    t = {}
    for m in re.finditer(r"localparam\s+int\s+([^;]*);", src):
        for k, v in re.findall(r"(\w+)\s*=\s*(\d+)", m.group(1)):
            t[k.upper()] = int(v)
    for k, v in re.findall(r"parameter\s+integer\s+(\w+)\s*=\s*(\d+)", src):
        t[k.upper().replace("T_", "T")] = int(v)
    keep = ["CL", "CWL", "TRCD", "TRP", "TRAS", "TRC", "TRRD", "TWR", "TWTR", "TRFC", "TRFC_PB", "TREFI"]
    return {k: t[k] for k in keep if k in t}


def build(P):
    w = os.path.join(ROOT, "work", "perf", P)
    raw = {}
    for f in ("sim.log", "sta.txt"):
        for line in open(os.path.join(w, f)):
            m = re.match(r"PERF (\w+) ([\d.]+)$", line.strip())
            if m:
                v = m.group(2)
                raw[m.group(1)] = float(v) if "." in v else int(v)
    fmax = raw["sta_fmax_mhz"]
    wb = raw["word_bytes"]
    d = {
        "ip": P,
        "family": "line" if P.endswith("_Lite") else "word",
        "bytes_per_op": wb,
        "bank_entries": raw["nbu"],
        "timing_clk": timing_params(P),
        "impl": {
            "library": "sky130_fd_sc_hd tt_025C_1v80 (pre-layout)",
            "logic_path_ns": raw["sta_logic_ns"],
            "fmax_mhz": fmax,
            "area_um2": raw["sta_area_um2"],
            "cells": raw["sta_cells"],
            "flip_flops": raw["sta_ff"],
            "model_array_bits": raw["sta_mem_bits"],
        },
        "latency_clk": {k: [raw[f"lat_{k}_min"], raw[f"lat_{k}_max"]] for k, _ in LATENCY},
        "latency_rd_refresh_clk": raw["lat_rd_refresh"],
        "throughput": {},
        "refresh_idle": {
            "busy_pct": round(100.0 * raw["ref_busy_clk"] / raw["ref_idle_clk"], 2),
            "windows": raw["ref_windows"],
            "window_clk": raw["ref_longest"],
            "observed_clk": raw["ref_idle_clk"],
        },
    }
    for k, _ in PATTERNS:
        ops, clk = raw[f"tp_{k}_ops"], raw[f"tp_{k}_clk"]
        cpo = clk / ops
        bpc = wb / cpo
        d["throughput"][k] = {
            "ops": ops, "clk": clk,
            "clk_per_op": round(cpo, 2),
            "bytes_per_clk": round(bpc, 3),
            "host_util_pct": round(100.0 * bpc / HOST_PEAK_B, 1),
            "mbyte_s_at_fmax": round(bpc * fmax, 1),
        }
    return d


def ns(clk, fmax):
    return f"{clk * 1000.0 / fmax:.0f}"


def kib(bits):
    return f"{bits // 8} bytes" if bits < 8192 else f"{bits / 8192:g} KiB"


def rng(a):
    return f"{a[0]}" if a[0] == a[1] else f"{a[0]}-{a[1]}"


def perf_section(P, notes=()):
    """Markdown of the Performance section, or [] when not characterized.
    notes: IP-specific reading of the figures (spec JSON "perf_notes")."""
    f = os.path.join(PERF_DIR, f"{P}.json")
    if not os.path.exists(f):
        return []
    d = json.load(open(f))
    im = d["impl"]
    fmax = im["fmax_mhz"]
    line = d["family"] == "line"
    unit = "128-bit line (16 bytes)" if line else "16-bit word (2 bytes)"
    L = ["## Performance", ""]
    L.append(
        f"Measured, not estimated: `bash scripts/perf/run_perf.sh {P}` runs the core's own testbench "
        f"with `+define+MEM_PERF` ({'`tb/perf/lite_perf.svh`' if line else '`tb/perf/mem_perf.svh`'}), "
        "which drives the host port as fast as `hready` allows and times every command at the "
        "core's ports, then synthesizes the core on the open SkyWater SKY130 library "
        f"(`scripts/perf/sta_sky130.sh`). Raw data: [`docs/perf/{P}.json`](../perf/{P}.json). "
        f"One host operation moves one {unit}; the host port peaks at 2 bytes per clock. "
        "Clock-based figures hold at any frequency; ns and MB/s are at the estimated Fmax below. "
        "Family comparison: [MEMORY_PERFORMANCE.md](../MEMORY_PERFORMANCE.md).")
    L.append("")
    L.append("### Implementation (pre-layout estimate)")
    L.append("")
    L.append("| Item | Value |")
    L.append("|---|---|")
    L.append(f"| Library | SKY130 `sky130_fd_sc_hd`, typical corner (tt, 25 C, 1.80 V) |")
    L.append(f"| Longest logic path | {im['logic_path_ns']:.2f} ns |")
    L.append(f"| Estimated Fmax | {fmax:.0f} MHz (logic path + 0.50 ns flip-flop clock-to-Q and setup) |")
    L.append(f"| Area | {im['area_um2'] / 1e6:.3f} mm2 ({im['area_um2']:.0f} um2), {im['cells']} cells, {im['flip_flops']} flip-flops |")
    L.append(f"| Not counted | the in-model DRAM array, {im['model_array_bits']} bits ({kib(im['model_array_bits'])}): a real controller has the DRAM off chip |")
    L.append("")
    L.append("No wire load, placement, clock skew or on-chip variation: these rank the designs and give the "
             "order of magnitude; they are not a timing sign-off.")
    L.append("")
    tc = d["timing_clk"]
    if tc:
        L.append("### DRAM timing used (clocks)")
        L.append("")
        L.append("| " + " | ".join(tc.keys()) + " |")
        L.append("|" + "---|" * len(tc))
        L.append("| " + " | ".join(str(v) for v in tc.values()) + " |")
        L.append("")
    L.append("### Latency, unloaded")
    L.append("")
    if line:
        L.append("From the first clock the host presents the command to `hdone` (the last of the 8 read "
                 "beats, or the write's completion); the first read beat is 7 clocks earlier. "
                 "Min and max over 8 samples in different banks, away from refresh, with the bank's "
                 "timers (tRAS, tRC, tWR) already run out.")
    else:
        L.append("From the first clock the host presents the command to the clock `hrdata` is valid (read) "
                 "or the core can take the next command (write). Min and max over 8 samples in different "
                 "banks, away from refresh, with the bank's timers (tRAS, tRC) already run out.")
    L.append("")
    L.append("| Command | Clocks | ns at Fmax |")
    L.append("|---|---|---|")
    for k, label in LATENCY:
        a = d["latency_clk"][k]
        L.append(f"| {label} | {rng(a)} | {ns(a[0], fmax)}" + ("" if a[0] == a[1] else f"-{ns(a[1], fmax)}") + " |")
    r = d["latency_rd_refresh_clk"]
    L.append(f"| Read, page hit, requested as a refresh falls due (worst case seen) | {r} | {ns(r, fmax)} |")
    L.append("")
    L.append("### Sustained throughput")
    L.append("")
    n = d["throughput"]["seq_rd"]["ops"]
    L.append(f"{n} back-to-back commands per pattern, refreshes included. Host utilization = bytes per clock "
             "over the port's 2-byte peak.")
    L.append("")
    L.append("| Pattern | Clocks / op | Bytes / clock | Host utilization | MB/s at Fmax |")
    L.append("|---|---|---|---|---|")
    for k, label in PATTERNS:
        t = d["throughput"][k]
        L.append(f"| {label} | {t['clk_per_op']:.2f} | {t['bytes_per_clk']:.3f} | {t['host_util_pct']:.1f}% | {t['mbyte_s_at_fmax']:.0f} |")
    L.append("")
    ri = d["refresh_idle"]
    L.append("### Refresh cost")
    L.append("")
    what = "the command engine is busy refreshing" if line else "`hready` is low (the core cannot take a command)"
    L.append(f"With no host traffic for {ri['observed_clk']} clocks, {what} {ri['busy_pct']:.2f}% of the "
             f"time, in {ri['windows']} windows of at most {ri['window_clk']} clocks "
             f"({ns(ri['window_clk'], fmax)} ns).")
    L.append("")
    if notes:
        L.append("### Reading the figures for this IP")
        L.append("")
        for n in notes:
            L.append(f"* {n}")
        L.append("")
    L.append("### Limits of these figures")
    L.append("")
    L.append("* One command in flight: the core finishes a command before it takes the next, so throughput "
             "is set by the per-command latency, not by the DRAM data bus. A production controller queues "
             "and reorders many commands and keeps the data bus busy.")
    L.append("* The host port is 16 bits wide" + (", and a line moves as 8 beats" if line else "")
             + "; the figures are bytes through that port, not DRAM pin bandwidth.")
    L.append("* Timing parameters are in controller clocks as listed above, not tied to a JEDEC speed bin.")
    L.append("")
    return L


def summary():
    rows = []
    for f in sorted(os.listdir(PERF_DIR)):
        if f.endswith(".json"):
            rows.append(json.load(open(os.path.join(PERF_DIR, f))))
    L = ["# Memory controller performance", "",
         "Measured figures of every DDR / LPDDR / GDDR / HBM controller core, from "
         "`bash scripts/perf/run_perf.sh <P>` (simulation at the core's ports, then a pre-layout "
         "SKY130 synthesis for Fmax and area). Each IP page has the full Performance section; "
         "the raw data is in `docs/perf/<P>.json`.", "",
         "Word controllers (the 20 numbered IPs) move one 16-bit word per host command; line "
         "controllers (`*_Lite`) move one 128-bit line (8 beats). Both have one command in flight, "
         "so throughput is latency-bound. Latency in clocks; MB/s at the estimated Fmax "
         "(SKY130 HD, typical corner, pre-layout, DRAM model array excluded).", "",
         "| IP | Fmax MHz | Area mm2 | RD hit | RD closed | RD conflict | Seq RD MB/s | Random RD MB/s | Random mix MB/s | Refresh busy |",
         "|---|---|---|---|---|---|---|---|---|---|"]
    for d in rows:
        P = d["ip"]
        lat = d["latency_clk"]
        tp = d["throughput"]
        L.append(f"| [{P}](ip/{P}.md) | {d['impl']['fmax_mhz']:.0f} | {d['impl']['area_um2'] / 1e6:.3f} | "
                 f"{rng(lat['rd_hit'])} | {rng(lat['rd_closed'])} | {rng(lat['rd_conflict'])} | "
                 f"{tp['seq_rd']['mbyte_s_at_fmax']:.0f} | {tp['rnd_rd']['mbyte_s_at_fmax']:.0f} | "
                 f"{tp['rnd_mix']['mbyte_s_at_fmax']:.0f} | {d['refresh_idle']['busy_pct']:.2f}% |")
    L += ["", "How the figures are measured, and what they leave out, is in each IP page's "
          "Performance section.", ""]
    open(os.path.join(ROOT, "docs", "MEMORY_PERFORMANCE.md"), "w").write("\n".join(L))


if __name__ == "__main__":
    if sys.argv[1:] == ["--summary"]:
        summary()
    else:
        os.makedirs(PERF_DIR, exist_ok=True)
        for P in sys.argv[1:]:
            d = build(P)
            json.dump(d, open(os.path.join(PERF_DIR, f"{P}.json"), "w"), indent=1)
            open(os.path.join(PERF_DIR, f"{P}.json"), "a").write("\n")
            print(f"{P}: Fmax {d['impl']['fmax_mhz']} MHz, RD hit {d['latency_clk']['rd_hit']} clk, "
                  f"seq RD {d['throughput']['seq_rd']['mbyte_s_at_fmax']} MB/s")
