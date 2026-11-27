<!-- SPDX-License-Identifier: Apache-2.0 -->
# Memory controller optimization, 2026-11

Before: commit `e4c600a` (`docs/perf/*.json` at that commit). After: this pass, measured the same way with `bash scripts/perf/run_perf.sh <P>` (FORCE_STA=1). Clocks are cycle-exact from simulation; Fmax is pre-layout SKY130 and moves a few percent with any RTL change (ABC mapping), so compare clocks first.

## What changed (public, contract-preserving)

- **Writes complete on the pins.** A WR used to hold the core until the whole CL wait and burst had passed. It now completes once the WR command is issued; the following commands wait only for the real DRAM limits, which are now modeled: write recovery before PRE (tWR, counted from the end of the write burst), write-to-read turnaround (tWTR) and burst spacing (tCCD). The shared checker `tb/cov/mem_chk.svh` gained assertions for all three.
- **Exact timer spacing on the miss paths.** The ACT, PRE and REF timers were each one or two clocks longer than the DRAM limit, and the closed-bank and conflict paths had idle hop states. Commands now issue on the first legal clock.
- **Per-entry refresh no longer blocks the host.** In the cores that refresh one bank entry at a time (HBM family, LPDDR4 to LPDDR7), only the refreshed entry waits tRFC; the host is served from the other entries meanwhile. The checker tracks tRFC per entry.
- **Read cut-through in the line controllers (`*_Lite`).** The 128-bit line goes to the host beat by beat as it arrives, with `hdone` on the last beat, instead of after the whole line was buffered.

Not in this pass (private, licensed tier): a command queue, several reads in flight, and reordering. Those change the one-command host contract.

## Latency (clocks, unloaded)

| IP | Read closed bank | Read row conflict | Write page hit | Write closed bank | Write row conflict |
|---|---|---|---|---|---|
| DDR | 16 → 12 | 7 → 7 | 8 → 3 | 17 → 8 | 8 → 3 |
| DDR4 | 35 → 31 | 49 → 45 | 18 → 2 | 36 → 16 | 50 → 30 |
| DDR5 | 41 → 38 | 55 → 52 | 25 → 3 | 42 → 17 | 56 → 31 |
| DDR6 | 46 → 44 | 64 → 60 | 83 → 85 | 65 → 69 | 83 → 85 |
| DDR7 | 54 → 50 | 72 → 68 | 1 → 1 | 35 → 5 | 57 → 23 |
| GDDR5 | 32 → 28 | 45 → 41 | 16 → 3 | 33 → 16 | 46 → 29 |
| GDDR6 | 36 → 32 | 50 → 46 | 19 → 3 | 37 → 17 | 51 → 31 |
| GDDR7 | 39 → 35 | 54 → 50 | 21 → 3 | 40 → 18 | 55 → 33 |
| HBM | 20 → 16 | 27 → 23 | 10 → 3 | 21 → 10 | 28 → 17 |
| HBM2 | 27 → 23 | 16 → 16 | 17 → 3 | 28 → 10 | 17 → 3 |
| HBM3 | 25 → 21 | 34 → 30 | 13 → 3 | 26 → 12 | 35 → 21 |
| HBM3E | 28 → 24 | 38 → 34 | 15 → 3 | 29 → 13 | 39 → 23 |
| HBM4 | 30 → 27 | 41 → 38 | 17 → 3 | 31 → 14 | 42 → 25 |
| HBM5 | 34 → 30 | 46 → 42 | 19 → 3 | 35 → 15 | 47 → 27 |
| LPDDR | 12 → 8 | 5 → 5 | 6 → 3 | 13 → 6 | 6 → 3 |
| LPDDR4 | 36 → 32 | 50 → 46 | 18 → 3 | 37 → 18 | 51 → 32 |
| LPDDR5 | 37 → 33 | 51 → 47 | 20 → 3 | 38 → 17 | 52 → 31 |
| LPDDR5X | 42 → 38 | 56 → 52 | 25 → 3 | 43 → 17 | 57 → 31 |
| LPDDR6 | 43 → 40 | 57 → 54 | 27 → 3 | 44 → 17 | 58 → 31 |
| LPDDR7 | 49 → 45 | 64 → 60 | 31 → 3 | 67 → 55 | 82 → 70 |
| DDR4_Lite | 37 → 28 | 46 → 37 | 28 → 28 | 34 → 34 | 43 → 43 |
| HBM3E_Lite | 37 → 28 | 46 → 37 | 28 → 28 | 34 → 34 | 43 → 43 |
| LPDDR5X_Lite | 37 → 28 | 46 → 37 | 28 → 28 | 34 → 34 | 43 → 43 |
| GDDR7_Lite | 37 → 28 | 46 → 37 | 28 → 28 | 34 → 34 | 43 → 43 |

Read page hit latency is unchanged in the word controllers: a read still waits CL plus the burst. It drops from 31 to 22 clocks in the line controllers (cut-through).

## Throughput (clocks per host command)

| IP | Seq read | Seq write | Seq read/write mix | Random read | Random write | Random mix | Refresh busy (idle) |
|---|---|---|---|---|---|---|---|
| DDR | 8.26 → 8.24 | 8.26 → 4.16 | 8.32 → 9.79 | 8.29 → 8.26 | 8.34 → 4.17 | 8.29 → 8.51 | 3.17% → 3.04% |
| DDR4 | 18.57 → 18.55 | 18.57 → 4.1 | 18.57 → 21.14 | 50.93 → 46.9 | 51.01 → 37.86 | 51.01 → 43.85 | 2.85% → 2.79% |
| DDR5 | 25.65 → 25.63 | 25.78 → 8.28 | 25.65 → 31.38 | 56.75 → 53.73 | 56.8 → 38.29 | 56.86 → 49.02 | 2.65% → 2.61% |
| DDR6 | 66.93 → 61.68 | 67.07 → 84.32 | 66.93 → 73.07 | 66.91 → 50.15 | 67.05 → 72.9 | 67.05 → 58.01 | 2.99% → 2.95% |
| DDR7 | 34.14 → 34.11 | 36.24 → 8.35 | 35.35 → 41.44 | 74.25 → 70.14 | 75.59 → 49.54 | 75.13 → 64.1 | 3.33% → 3.29% |
| GDDR5 | 16.52 → 16.49 | 16.59 → 3.14 | 19.64 → 14.99 | 46.11 → 42.05 | 46.15 → 31.21 | 46.15 → 38.2 | 3.0% → 2.9% |
| GDDR6 | 19.86 → 19.82 | 19.86 → 3.18 | 19.95 → 17.23 | 51.56 → 47.44 | 51.61 → 34.14 | 51.6 → 42.75 | 4.05% → 3.95% |
| GDDR7 | 22.01 → 21.97 | 22.1 → 3.2 | 22.01 → 19.37 | 55.65 → 51.55 | 55.71 → 36.45 | 55.65 → 46.17 | 4.33% → 4.23% |
| HBM | 10.55 → 10.07 | 10.58 → 3.01 | 10.58 → 9.56 | 29.51 → 24.11 | 29.6 → 17.93 | 29.6 → 21.95 | 5.83% → 0.58% |
| HBM2 | 18.06 → 17.03 | 18.1 → 3.01 | 18.08 → 14.52 | 18.44 → 17.3 | 18.3 → 3.16 | 18.32 → 14.33 | 6.47% → 0.58% |
| HBM3 | 14.0 → 13.02 | 14.0 → 4.0 | 14.0 → 14.52 | 37.47 → 30.86 | 37.73 → 21.16 | 37.72 → 27.66 | 7.88% → 0.71% |
| HBM3E | 16.37 → 15.03 | 16.37 → 4.0 | 16.44 → 17.03 | 42.37 → 34.91 | 42.58 → 23.13 | 42.6 → 30.94 | 9.23% → 0.77% |
| HBM4 | 18.81 → 17.03 | 18.88 → 4.0 | 18.88 → 19.53 | 46.14 → 38.8 | 46.51 → 25.27 | 46.58 → 34.31 | 10.58% → 0.83% |
| HBM5 | 24.57 → 19.34 | 24.53 → 4.08 | 24.55 → 21.82 | 58.51 → 42.79 | 59.12 → 27.51 | 59.28 → 38.22 | 28.72% → 7.18% |
| LPDDR | 6.15 → 6.14 | 6.15 → 4.1 | 6.15 → 7.19 | 6.17 → 6.15 | 6.16 → 4.15 | 6.16 → 6.36 | 2.49% → 2.38% |
| LPDDR4 | 19.71 → 18.21 | 19.75 → 8.17 | 19.75 → 21.26 | 55.73 → 47.77 | 55.78 → 36.25 | 55.78 → 43.71 | 9.49% → 1.03% |
| LPDDR5 | 22.03 → 20.22 | 22.07 → 8.0 | 22.05 → 22.7 | 57.1 → 48.51 | 57.14 → 33.36 | 57.2 → 43.39 | 10.13% → 1.03% |
| LPDDR5X | 27.61 → 25.39 | 27.61 → 8.09 | 27.59 → 26.37 | 62.72 → 54.03 | 62.77 → 35.99 | 62.77 → 47.46 | 10.02% → 1.03% |
| LPDDR6 | 29.94 → 27.25 | 29.96 → 8.1 | 29.96 → 27.72 | 64.06 → 55.36 | 64.17 → 33.4 | 64.17 → 48.1 | 10.77% → 1.03% |
| LPDDR7 | 34.61 → 31.52 | 34.7 → 8.1 | 34.7 → 31.01 | 74.83 → 51.01 | 74.77 → 57.82 | 74.85 → 53.1 | 10.51% → 0.19% |
| DDR4_Lite | 31.43 → 22.31 | 28.41 → 28.41 | 30.49 → 25.9 | 46.05 → 37.11 | 43.16 → 43.15 | 45.37 → 39.46 | 1.15% → 1.15% |
| HBM3E_Lite | 31.37 → 22.38 | 28.37 → 28.37 | 30.27 → 25.82 | 46.28 → 37.39 | 43.36 → 43.34 | 45.43 → 39.51 | 2.05% → 2.05% |
| LPDDR5X_Lite | 31.15 → 22.15 | 28.15 → 28.14 | 30.12 → 25.66 | 46.11 → 37.15 | 43.18 → 43.18 | 45.28 → 39.33 | 0.82% → 0.82% |
| GDDR7_Lite | 31.43 → 22.31 | 28.41 → 28.41 | 30.49 → 25.9 | 45.62 → 36.76 | 42.78 → 42.76 | 44.79 → 38.94 | 1.15% → 1.15% |

## Fmax and area (pre-layout)

| IP | Fmax MHz | Area um2 |
|---|---|---|
| DDR | 342 → 354 (+4%) | 29454 → 29553 |
| DDR4 | 302 → 340 (+13%) | 36282 → 34882 |
| DDR5 | 280 → 295 (+5%) | 69477 → 70543 |
| DDR6 | 259 → 289 (+12%) | 67057 → 66737 |
| DDR7 | 231 → 256 (+11%) | 82522 → 82940 |
| GDDR5 | 325 → 306 (-6%) | 47423 → 46508 |
| GDDR6 | 311 → 258 (-17%) | 67834 → 67218 |
| GDDR7 | 282 → 276 (-2%) | 73374 → 71635 |
| HBM | 306 → 294 (-4%) | 221157 → 238334 |
| HBM2 | 241 → 261 (+8%) | 314118 → 316759 |
| HBM3 | 231 → 226 (-2%) | 457305 → 454676 |
| HBM3E | 154 → 156 (+1%) | 789836 → 787346 |
| HBM4 | 241 → 240 (-0%) | 667541 → 663105 |
| HBM5 | 223 → 233 (+4%) | 633676 → 633844 |
| LPDDR | 308 → 363 (+18%) | 29816 → 29952 |
| LPDDR4 | 324 → 302 (-7%) | 69885 → 70142 |
| LPDDR5 | 286 → 302 (+6%) | 128337 → 132591 |
| LPDDR5X | 313 → 303 (-3%) | 68264 → 69852 |
| LPDDR6 | 298 → 292 (-2%) | 89513 → 90160 |
| LPDDR7 | 290 → 330 (+14%) | 70483 → 70707 |
| DDR4_Lite | 412 → 404 (-2%) | 36206 → 35665 |
| HBM3E_Lite | 259 → 282 (+9%) | 73058 → 72362 |
| LPDDR5X_Lite | 367 → 393 (+7%) | 45555 → 44974 |
| GDDR7_Lite | 337 → 338 (+0%) | 54821 → 55194 |

## Trade-offs, stated plainly

- **Alternating read/write got slower in half of the word controllers.** The old cores waited out the whole write, so tWTR never showed. Now a read right after a write waits tWTR, which a real DRAM requires. `seq_rw` is up to 22% more clocks per command (DDR5), while GDDR5/6/7, HBM, HBM2, HBM5 and LPDDR5X/6/7 got faster on it; the write-heavy and random patterns gain far more.
- **DDR6 writes got slower.** DDR6 is closed-page by design (every access auto-precharges), so with tWR now modeled each write waits for write recovery before its precharge. DDR6 reads got faster (random read 66.9 → 50.2 clocks).
- **Line-controller writes are unchanged.** A `*_Lite` write still sends the whole line before it completes.
- **Fmax moved between -17% and +18%.** GDDR6 dropped the most (311 → 258 MHz). The new tWTR gate is on the command-issue path of every word controller, but how much of each change is real and how much is ABC mapping noise was not separated. These are pre-layout numbers, not sign-off.
