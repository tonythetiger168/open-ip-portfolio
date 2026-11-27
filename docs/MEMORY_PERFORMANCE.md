# Memory controller performance

Measured figures of every DDR / LPDDR / GDDR / HBM controller core, from `bash scripts/perf/run_perf.sh <P>` (simulation at the core's ports, then a pre-layout SKY130 synthesis for Fmax and area). Each IP page has the full Performance section; the raw data is in `docs/perf/<P>.json`.

The 20 controllers move one 16-bit word per host command (DDR4, GDDR7, HBM3E and LPDDR5X also take 128-bit line commands, not measured here) with one command in flight, so throughput is latency-bound. Latency in clocks; MB/s at the estimated Fmax (SKY130 HD, typical corner, pre-layout, DRAM model array excluded).

The 2026-11 optimization pass (writes complete on the pins, exact timer spacing, no idle clocks on the miss paths) is compared with the previous figures in [perf/OPTIMIZATION_2026-11.md](perf/OPTIMIZATION_2026-11.md).

| IP | Fmax MHz | Area mm2 | RD hit | RD closed | RD conflict | Seq RD MB/s | Random RD MB/s | Random mix MB/s | Refresh busy |
|---|---|---|---|---|---|---|---|---|---|
| [DDR](ip/DDR.md) | 354 | 0.030 | 7 | 12 | 7 | 86 | 86 | 83 | 3.04% |
| [DDR4](ip/DDR4.md) | 274 | 0.030 | 17 | 31 | 45 | 30 | 12 | 12 | 2.79% |
| [DDR5](ip/DDR5.md) | 295 | 0.071 | 24 | 38 | 52 | 23 | 11 | 12 | 2.61% |
| [DDR6](ip/DDR6.md) | 289 | 0.067 | 60 | 44 | 60 | 9 | 12 | 10 | 2.95% |
| [DDR7](ip/DDR7.md) | 256 | 0.083 | 32 | 50 | 68 | 15 | 7 | 8 | 3.29% |
| [GDDR5](ip/GDDR5.md) | 306 | 0.047 | 15 | 28 | 41 | 37 | 15 | 16 | 2.90% |
| [GDDR6](ip/GDDR6.md) | 258 | 0.067 | 18 | 32 | 46 | 26 | 11 | 12 | 3.95% |
| [GDDR7](ip/GDDR7.md) | 275 | 0.056 | 20 | 35 | 50 | 25 | 11 | 12 | 4.23% |
| [HBM](ip/HBM.md) | 294 | 0.238 | 9 | 16 | 23 | 58 | 24 | 27 | 0.58% |
| [HBM2](ip/HBM2.md) | 261 | 0.317 | 16 | 23 | 16 | 31 | 30 | 36 | 0.58% |
| [HBM3](ip/HBM3.md) | 226 | 0.455 | 12 | 21 | 30 | 35 | 15 | 16 | 0.71% |
| [HBM3E](ip/HBM3E.md) | 160 | 0.608 | 14 | 24 | 34 | 21 | 9 | 10 | 0.77% |
| [HBM4](ip/HBM4.md) | 240 | 0.663 | 16 | 27 | 38 | 28 | 12 | 14 | 0.83% |
| [HBM5](ip/HBM5.md) | 233 | 0.634 | 18 | 30 | 42 | 24 | 11 | 12 | 7.18% |
| [LPDDR](ip/LPDDR.md) | 363 | 0.030 | 5 | 8 | 5 | 118 | 118 | 114 | 2.38% |
| [LPDDR4](ip/LPDDR4.md) | 302 | 0.070 | 17 | 32 | 46 | 33 | 13 | 14 | 1.03% |
| [LPDDR5](ip/LPDDR5.md) | 302 | 0.133 | 19 | 33 | 47 | 30 | 12 | 14 | 1.03% |
| [LPDDR5X](ip/LPDDR5X.md) | 278 | 0.044 | 24 | 38 | 52 | 22 | 10 | 12 | 1.03% |
| [LPDDR6](ip/LPDDR6.md) | 292 | 0.090 | 26 | 40 | 54 | 21 | 10 | 12 | 1.03% |
| [LPDDR7](ip/LPDDR7.md) | 330 | 0.071 | 30 | 45 | 60 | 21 | 13 | 12 | 0.19% |

How the figures are measured, and what they leave out, is in each IP page's Performance section.
