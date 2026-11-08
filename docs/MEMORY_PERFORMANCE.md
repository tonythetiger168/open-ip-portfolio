# Memory controller performance

Measured figures of every DDR / LPDDR / GDDR / HBM controller core, from `bash scripts/perf/run_perf.sh <P>` (simulation at the core's ports, then a pre-layout SKY130 synthesis for Fmax and area). Each IP page has the full Performance section; the raw data is in `docs/perf/<P>.json`.

Word controllers (the 20 numbered IPs) move one 16-bit word per host command; line controllers (`*_Lite`) move one 128-bit line (8 beats). Both have one command in flight, so throughput is latency-bound. Latency in clocks; MB/s at the estimated Fmax (SKY130 HD, typical corner, pre-layout, DRAM model array excluded).

| IP | Fmax MHz | Area mm2 | RD hit | RD closed | RD conflict | Seq RD MB/s | Random RD MB/s | Random mix MB/s | Refresh busy |
|---|---|---|---|---|---|---|---|---|---|
| [DDR](ip/DDR.md) | 342 | 0.029 | 7 | 16 | 7 | 83 | 82 | 83 | 3.17% |
| [DDR4](ip/DDR4.md) | 302 | 0.036 | 17 | 35 | 49 | 32 | 12 | 12 | 2.85% |
| [DDR4_Lite](ip/DDR4_Lite.md) | 412 | 0.036 | 31 | 37 | 46 | 210 | 143 | 145 | 1.15% |
| [DDR5](ip/DDR5.md) | 280 | 0.069 | 24 | 41 | 55 | 22 | 10 | 10 | 2.65% |
| [DDR6](ip/DDR6.md) | 259 | 0.067 | 64 | 46 | 64 | 8 | 8 | 8 | 2.99% |
| [DDR7](ip/DDR7.md) | 231 | 0.083 | 32 | 54 | 72 | 14 | 6 | 6 | 3.33% |
| [GDDR5](ip/GDDR5.md) | 325 | 0.047 | 15 | 32 | 45 | 39 | 14 | 14 | 3.00% |
| [GDDR6](ip/GDDR6.md) | 311 | 0.068 | 18 | 36 | 50 | 31 | 12 | 12 | 4.05% |
| [GDDR7](ip/GDDR7.md) | 282 | 0.073 | 20 | 39 | 54 | 26 | 10 | 10 | 4.33% |
| [GDDR7_Lite](ip/GDDR7_Lite.md) | 337 | 0.055 | 31 | 37 | 46 | 172 | 118 | 120 | 1.15% |
| [HBM](ip/HBM.md) | 306 | 0.221 | 9 | 20 | 27 | 58 | 21 | 21 | 5.83% |
| [HBM2](ip/HBM2.md) | 241 | 0.314 | 16 | 27 | 16 | 27 | 26 | 26 | 6.47% |
| [HBM3](ip/HBM3.md) | 231 | 0.457 | 12 | 25 | 34 | 33 | 12 | 12 | 7.88% |
| [HBM3E](ip/HBM3E.md) | 154 | 0.790 | 14 | 28 | 38 | 19 | 7 | 7 | 9.23% |
| [HBM3E_Lite](ip/HBM3E_Lite.md) | 259 | 0.073 | 31 | 37 | 46 | 132 | 90 | 91 | 2.05% |
| [HBM4](ip/HBM4.md) | 241 | 0.668 | 16 | 30 | 41 | 26 | 10 | 10 | 10.58% |
| [HBM5](ip/HBM5.md) | 223 | 0.634 | 18 | 34 | 46 | 18 | 8 | 8 | 28.72% |
| [LPDDR](ip/LPDDR.md) | 308 | 0.030 | 5 | 12 | 5 | 100 | 100 | 100 | 2.49% |
| [LPDDR4](ip/LPDDR4.md) | 324 | 0.070 | 17 | 36 | 50 | 33 | 12 | 12 | 9.49% |
| [LPDDR5](ip/LPDDR5.md) | 286 | 0.128 | 19 | 37 | 51 | 26 | 10 | 10 | 10.13% |
| [LPDDR5X](ip/LPDDR5X.md) | 313 | 0.068 | 24 | 42 | 56 | 23 | 10 | 10 | 10.02% |
| [LPDDR5X_Lite](ip/LPDDR5X_Lite.md) | 367 | 0.046 | 31 | 37 | 46 | 188 | 127 | 130 | 0.82% |
| [LPDDR6](ip/LPDDR6.md) | 298 | 0.090 | 26 | 43 | 57 | 20 | 9 | 9 | 10.77% |
| [LPDDR7](ip/LPDDR7.md) | 290 | 0.070 | 30 | 49 | 64 | 17 | 8 | 8 | 10.51% |

How the figures are measured, and what they leave out, is in each IP page's Performance section.
