# rtl/pq: PQ pipeline stages reused from pq-pipeline-sv

These four files are copies from
[tonythetiger168/pq-pipeline-sv](https://github.com/tonythetiger168/pq-pipeline-sv)
at commit `508427e629b52f907a6ceae1a83da686ffa8bbcb` (main, 2026-10-27):

| File | Source | Used for |
|---|---|---|
| `pq_pkg.sv` | `rtl/pq_pkg.sv` | shared constants (metadata layout, default knee) |
| `l0_metadata_unit.sv` | `rtl/l0_metadata_unit.sv` | HDR10 / Dolby Vision metadata to tone parameters |
| `l1_tone_map_eetf.sv` | `rtl/l1_tone_map_eetf.sv` | BT.2390-style 2-segment EETF + L2 trim |
| `l2d_memc_blend.sv` | `rtl/l2d_memc_blend.sv` | MEMC compensated blend `prev * (1 - a) + cur * a` |

`rtl/PQ_MEMC_top.sv` wraps them with an AXI4 manager (frame fetch and write
back) and back-pressure; see `docs/ip/PQ_MEMC.md`. The other pq-pipeline-sv
stages (3x3 denoise, 3D LUT, local dimming, calibration) need a whole-frame
geometry fixed in `pq_pkg` and are not wrapped here.

The copies differ from the source only so that Yosys 0.33 (the CI version)
reads them; the logic is unchanged:

- the module headers' `import pq_pkg::*;` is removed and the three package
  names `l0_metadata_unit.sv` uses are written `pq_pkg::P_META_W`,
  `pq_pkg::META_FMT_SDR` and `pq_pkg::P_KNEE_DEFAULT` (Yosys 0.33 has no
  import in a module header);
- `l0_metadata_unit.sv` sets `slope_wide = '0;` at the top of its
  `always_comb` (it was assigned in one branch only, which Yosys reports as a
  latch; the value is not used in the other branch).

Do not edit them otherwise: change pq-pipeline-sv and copy them again (update
the commit above and repeat the two edits). The source repository has no LICENSE file; the
copies are used here with the permission of its owner, who owns both
repositories.

Known issue found by `tb/PQ_MEMC_tb.sv` (reported, not fixed in the copy):
in `l1_tone_map_eetf.sv` stage 4, `tr[15:0]` drops the bits above 16 of
`y * trim_gain >> 14`, so a trim gain above 1.0 (16384) wraps bright pixels
around instead of clamping them to full scale. The testbench keeps the trim
gain at or below 1.0.
