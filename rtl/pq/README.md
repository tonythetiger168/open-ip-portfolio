# rtl/pq: picture-quality stages of PQ_MEMC

`pq_stages.sv` holds the three processing stages `PQ_MEMC_top` uses, written
for this repository:

| Module | Function |
|---|---|
| `pq_meta_decode` | 128-bit HDR10 / Dolby Vision metadata to tone parameters (knee 0.75, slope = min(1, display peak / content peak), trim gain / offset) |
| `pq_eetf` | 2-segment tone curve above the knee, then trim gain (Q2.14) and offset, clamped to full scale; 4 clocks |
| `pq_blend` | MEMC frame blend `(prev * (256 - a) + cur * a) >> 8`; 1 clock |

They match the interface and timing of the l0 / l1 / l2d stages of Tony's
pq-pipeline-sv, which is a private repository. Its code is not copied
here. To simulate PQ_MEMC with those stages instead:

```
bash scripts/ext/fetch_pq.sh          # needs read access; fills the git-ignored ext/pq/
make -f Makefile.PQ_MEMC sim_ext      # same TB, compiled with -DPQ_EXT
```

One difference shows in that build: pq-pipeline-sv's l1 stage keeps only 16
bits of `y * trim_gain >> 14`, so a trim gain above 1.0 wraps bright pixels
instead of clamping them. The TB skips its trim-gain-above-1.0 case under
`PQ_EXT`.
