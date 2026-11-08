# TV picture quality: HDR tone mapping (EETF) and MEMC frame blending, frames in memory over AXI4

Protocol IP `PQ_MEMC`, version 1.0. Apache-2.0.

| Item | Value |
|---|---|
| Core | `PQ_MEMC_top` (`rtl/PQ_MEMC_top.sv`) |
| Register interface | APB4 slave `PQ_MEMC_apb`, 32-bit data, 12-bit byte address, zero wait states |
| Clock, reset | PCLK (rising edge), PRESETN (active low, asynchronous) |
| ID register | 0x7C080100 (code 0x7C08, version 1.0) |
| Registers | 21 words, 0x000 to 0x050 |
| Interrupts | 2 sources into one level-high `irq` |
| Protocol pins | 31 pass-through |

## Overview

PQ_MEMC: picture-quality engine of the TV SoC: HDR tone mapping and MEMC frame blending over AXI4 (AXI4 manager, APB4 registers) Processing stages (rtl/pq/pq_stages.sv): pq_meta_decode (HDR10 / Dolby Vision metadata -> tone parameters), pq_eetf (2-segment tone curve + trim gain / offset, clamped) and pq_blend (out = prev * (256 - a) + cur * a >> 8). With PQ_EXT defined the private pq-pipeline-sv stages l0 / l1 / l2d are used instead (fetched at build time, rtl/pq/README.md). This wrapper adds the frame DMA, back-pressure and registers.

- Pixels: one 32-bit word, {2'b00, R[9:0], G[9:0], B[9:0]}; a 10-bit code c
enters the pipeline as the Q0.16 value {c, c[9:4]} and leaves as bits
15:6 of the result.
- Frame job (START, ignored while busy): for each line k < V_ACTIVE, if
MEMC_EN the previous-frame line PREV_ADDR + k * STRIDE is read into a line
buffer, then the current line CUR_ADDR + k * STRIDE is read, processed
and written to DST_ADDR + k * STRIDE (H_ACTIVE words each). MEMC_EN 0:
prev = cur (tone mapping only). Both frames go through the tone curve
(two l1 instances) before the blend.
- MV_FRAC a (0..255) is the weight of the current frame (frame-rate
conversion phase from the NPU's motion estimation; one value per job).
- Tone mapping: META_LOAD loads the 128-bit metadata {META3..META0} with
DISPLAY_PEAK into l0 (TONE_SLOPE / CONTENT_MAX show the result). TONE_EN
0 (or no metadata loaded yet): neutral EETF (no compression, trim 1.0).
- H_ACTIVE above MAXW (the line buffer) or 0 ends the job at once with
CFG_ERR. DONE pulses at the end of the job, ERR as well on an AXI error
response. LINES and CYCLES report the last job. 8K60 (7680 x 4320) needs
MAXW = 7680 and about 8 GB/s read + 4 GB/s write with MEMC on.

Features:

- Processing stages in rtl/pq/pq_stages.sv: metadata decode, 2-segment tone curve with trim gain / offset (clamped), MEMC blend; interface-compatible with the private pq-pipeline-sv l0 / l1 / l2d stages, which a build-time fetch can substitute (rtl/pq/README.md).
- Pixel word {2'b00, R[9:0], G[9:0], B[9:0]}.
- CMD.start runs a frame: per line k, with MEMC_EN the previous-frame line PREV_ADDR + k * STRIDE is read into a line buffer, then CUR_ADDR + k * STRIDE is read, processed and written to DST_ADDR + k * STRIDE.
- out = prev * (256 - MV_FRAC) + cur * MV_FRAC >> 8 after both pass the tone curve; MEMC_EN 0: tone mapping only.
- CMD.meta_load loads the 128-bit metadata META3..META0 with DISPLAY_PEAK (SDR / HDR10 / Dolby Vision); TONE_EN 0 or no metadata: neutral curve.
- H_ACTIVE 0 or above the line buffer (MAXW) ends the job at once with STATUS.cfg_err.

m_* is the AXI4 manager port (32-bit address and data, 4-bit ID, no user / QoS); it passes through unchanged. Bursts are INCR, AxSIZE = 2 (4 bytes), 1 to 16 beats, WSTRB = 4'hF, never across a 4 KB boundary; one read and one write burst are outstanding at a time.
The core testbench prints one `LAT <master> dram R|W <cycles>` line per AXI burst (tb/tv_lat_mon.svh), the regression suite's latency format.

## Files

| File | Content |
|---|---|
| `rtl/PQ_MEMC_top.sv` | protocol core |
| `rtl/PQ_MEMC_apb.sv` | APB4 register wrapper (generated) |
| `tb/PQ_MEMC_tb.sv` | core testbench |
| `tb/PQ_MEMC_apb_tb.sv`, `tb/apb/PQ_MEMC_apb_func.svh` | wrapper testbench (generated part + IP-specific part) |
| `tb/cov/PQ_MEMC_sva.sv`, `tb/cov/PQ_MEMC_apb_sva.sv` | coverage checkers (core, wrapper) |
| `scripts/apb/specs/PQ_MEMC.json` | register spec the wrapper, TB, checker and this page are generated from |

How to run the tests and the coverage flow: see [Running and verifying](#running-and-verifying).

## Parameters

`PQ_MEMC_apb` has the core's parameters and passes them to `PQ_MEMC_top` unchanged.

| Parameter | Type | Default |
|---|---|---|
| `AXI_ID` | logic [3:0] | `4'd8` |
| `MAXW` | int | `64` |

## Wrapper pins

Pins of `PQ_MEMC_apb`. Widths of the pass-through pins are at the default parameters.

| Pin | Dir | Width | Description |
|---|---|---|---|
| `PCLK` | input | 1 | APB clock; also the core clock |
| `PRESETN` | input | 1 | APB reset, active low; also the core reset |
| `PSEL` | input | 1 | slave select |
| `PENABLE` | input | 1 | access phase |
| `PWRITE` | input | 1 | 1 = write, 0 = read |
| `PADDR` | input | 12 | byte address; bits [1:0] must be 0 |
| `PWDATA` | input | 32 | write data |
| `PSTRB` | input | 4 | write byte strobes |
| `PRDATA` | output | 32 | read data |
| `PREADY` | output | 1 | always high in the access phase (no wait states) |
| `PSLVERR` | output | 1 | error: unmapped or misaligned address |
| `irq` | output | 1 | interrupt, level high: \|(IRQ_STATUS & IRQ_ENABLE) |
| `m_awid` | output | 4 | protocol pin, core port `m_awid` |
| `m_awaddr` | output | 32 | protocol pin, core port `m_awaddr` |
| `m_awlen` | output | 8 | protocol pin, core port `m_awlen` |
| `m_awsize` | output | 3 | protocol pin, core port `m_awsize` |
| `m_awburst` | output | 2 | protocol pin, core port `m_awburst` |
| `m_awprot` | output | 3 | protocol pin, core port `m_awprot` |
| `m_awvalid` | output | 1 | protocol pin, core port `m_awvalid` |
| `m_awready` | input | 1 | protocol pin, core port `m_awready` |
| `m_wdata` | output | 32 | protocol pin, core port `m_wdata` |
| `m_wstrb` | output | 4 | protocol pin, core port `m_wstrb` |
| `m_wlast` | output | 1 | protocol pin, core port `m_wlast` |
| `m_wvalid` | output | 1 | protocol pin, core port `m_wvalid` |
| `m_wready` | input | 1 | protocol pin, core port `m_wready` |
| `m_bid` | input | 4 | protocol pin, core port `m_bid` |
| `m_bresp` | input | 2 | protocol pin, core port `m_bresp` |
| `m_bvalid` | input | 1 | protocol pin, core port `m_bvalid` |
| `m_bready` | output | 1 | protocol pin, core port `m_bready` |
| `m_arid` | output | 4 | protocol pin, core port `m_arid` |
| `m_araddr` | output | 32 | protocol pin, core port `m_araddr` |
| `m_arlen` | output | 8 | protocol pin, core port `m_arlen` |
| `m_arsize` | output | 3 | protocol pin, core port `m_arsize` |
| `m_arburst` | output | 2 | protocol pin, core port `m_arburst` |
| `m_arprot` | output | 3 | protocol pin, core port `m_arprot` |
| `m_arvalid` | output | 1 | protocol pin, core port `m_arvalid` |
| `m_arready` | input | 1 | protocol pin, core port `m_arready` |
| `m_rid` | input | 4 | protocol pin, core port `m_rid` |
| `m_rdata` | input | 32 | protocol pin, core port `m_rdata` |
| `m_rresp` | input | 2 | protocol pin, core port `m_rresp` |
| `m_rlast` | input | 1 | protocol pin, core port `m_rlast` |
| `m_rvalid` | input | 1 | protocol pin, core port `m_rvalid` |
| `m_rready` | output | 1 | protocol pin, core port `m_rready` |

## Core ports

| Port | Dir | Width | In the APB wrapper |
|---|---|---|---|
| `clk` | input | 1 | PCLK |
| `rst_n` | input | 1 | PRESETN |
| `cur_addr` | input | 32 | CUR_ADDR[31:0] |
| `prev_addr` | input | 32 | PREV_ADDR[31:0] |
| `dst_addr` | input | 32 | DST_ADDR[31:0] |
| `stride` | input | 16 | GEOM[15:0] |
| `h_active` | input | 16 | GEOM[31:16] |
| `v_active` | input | 16 | V_ACTIVE[15:0] |
| `memc_en` | input | 1 | CTRL[0:0] |
| `mv_frac` | input | 8 | CTRL[8:1] |
| `tone_en` | input | 1 | CTRL[9:9] |
| `meta0` | input | 32 | META0[31:0] |
| `meta1` | input | 32 | META1[31:0] |
| `meta2` | input | 32 | META2[31:0] |
| `meta3` | input | 32 | META3[31:0] |
| `display_peak` | input | 16 | DISPLAY_PEAK[15:0] |
| `meta_load` | input | 1 | CMD[0:0] |
| `start` | input | 1 | CMD[1:1] |
| `busy` | output | 1 | STATUS[0:0] |
| `err` | output | 1 | STATUS[1:1] |
| `cfg_err` | output | 1 | STATUS[2:2] |
| `params_ok` | output | 1 | STATUS[3:3] |
| `tone_slope` | output | 16 | TONE[15:0] |
| `content_max` | output | 16 | TONE[31:16] |
| `lines` | output | 16 | LINES[15:0] |
| `cycles` | output | 32 | CYCLES[31:0] |
| `done` | output | 1 | IRQ_STATUS.DONE |
| `err_irq` | output | 1 | IRQ_STATUS.ERR |
| `m_awid` | output | 4 | pin (pass-through) |
| `m_awaddr` | output | 32 | pin (pass-through) |
| `m_awlen` | output | 8 | pin (pass-through) |
| `m_awsize` | output | 3 | pin (pass-through) |
| `m_awburst` | output | 2 | pin (pass-through) |
| `m_awprot` | output | 3 | pin (pass-through) |
| `m_awvalid` | output | 1 | pin (pass-through) |
| `m_awready` | input | 1 | pin (pass-through) |
| `m_wdata` | output | 32 | pin (pass-through) |
| `m_wstrb` | output | 4 | pin (pass-through) |
| `m_wlast` | output | 1 | pin (pass-through) |
| `m_wvalid` | output | 1 | pin (pass-through) |
| `m_wready` | input | 1 | pin (pass-through) |
| `m_bid` | input | 4 | pin (pass-through) |
| `m_bresp` | input | 2 | pin (pass-through) |
| `m_bvalid` | input | 1 | pin (pass-through) |
| `m_bready` | output | 1 | pin (pass-through) |
| `m_arid` | output | 4 | pin (pass-through) |
| `m_araddr` | output | 32 | pin (pass-through) |
| `m_arlen` | output | 8 | pin (pass-through) |
| `m_arsize` | output | 3 | pin (pass-through) |
| `m_arburst` | output | 2 | pin (pass-through) |
| `m_arprot` | output | 3 | pin (pass-through) |
| `m_arvalid` | output | 1 | pin (pass-through) |
| `m_arready` | input | 1 | pin (pass-through) |
| `m_rid` | input | 4 | pin (pass-through) |
| `m_rdata` | input | 32 | pin (pass-through) |
| `m_rresp` | input | 2 | pin (pass-through) |
| `m_rlast` | input | 1 | pin (pass-through) |
| `m_rvalid` | input | 1 | pin (pass-through) |
| `m_rready` | output | 1 | pin (pass-through) |

## APB wrapper

`PQ_MEMC_apb` is an APB4 slave (AMBA APB protocol v2.0): zero wait states, 32-bit data, 12-bit byte address, PSTRB byte lanes on every writable register, PSLVERR on an unmapped or misaligned address (reads then return 0, writes are dropped). Writes to read-only registers are ignored without an error. The core runs on PCLK and PRESETN. `irq` is level-high: `|(IRQ_STATUS & IRQ_ENABLE)`.

Pass-through pins: `m_awid`, `m_awaddr`, `m_awlen`, `m_awsize`, `m_awburst`, `m_awprot`, `m_awvalid`, `m_awready`, `m_wdata`, `m_wstrb`, `m_wlast`, `m_wvalid`, `m_wready`, `m_bid`, `m_bresp`, `m_bvalid`, `m_bready`, `m_arid`, `m_araddr`, `m_arlen`, `m_arsize`, `m_arburst`, `m_arprot`, `m_arvalid`, `m_arready`, `m_rid`, `m_rdata`, `m_rresp`, `m_rlast`, `m_rvalid`, `m_rready`.

### Register map

| Offset | Name | Access | Reset | Description |
|---|---|---|---|---|
| 0x000 | ID | RO | 0x7C080100 | IP identification: code, major and minor version |
| 0x004 | IRQ_STATUS | W1C | 0x00000000 | Sticky interrupt bits, write 1 to clear |
| 0x008 | IRQ_ENABLE | RW | 0x00000000 | Interrupt enables; irq = \|(IRQ_STATUS & IRQ_ENABLE) |
| 0x00C | FLAGS | RO | 0x00000000 | Stream holding-register state |
| 0x010 | SCRATCH | RW | 0x00000000 | Scratch register, no effect on the core |
| 0x014 | CUR_ADDR | RW | 0x00000000 | Current frame |
| 0x018 | PREV_ADDR | RW | 0x00000000 | Previous frame |
| 0x01C | DST_ADDR | RW | 0x00000000 | Output frame |
| 0x020 | GEOM | RW | 0x00000000 | Line pitch and width |
| 0x024 | V_ACTIVE | RW | 0x00000000 | Lines |
| 0x028 | CTRL | RW | 0x00000000 | Options |
| 0x02C | META0 | RW | 0x00000000 | Metadata 31:0 |
| 0x030 | META1 | RW | 0x00000000 | Metadata 63:32 |
| 0x034 | META2 | RW | 0x00000000 | Metadata 95:64 |
| 0x038 | META3 | RW | 0x00000000 | Metadata 127:96 |
| 0x03C | DISPLAY_PEAK | RW | 0x00000000 | Panel peak |
| 0x040 | CMD | WO (pulse) | 0x00000000 | Commands (write 1) |
| 0x044 | STATUS | RO | core | State |
| 0x048 | TONE | RO | core | Tone parameters |
| 0x04C | LINES | RO | core | Lines written |
| 0x050 | CYCLES | RO | core | Frame length in clocks |

Unlisted bits read 0 and ignore writes. Reset "core": the register reads the core's outputs directly, so after reset it shows the core's own reset state. WO (pulse) registers read 0. Offsets from 0x054 up to 0xFFC are unmapped (PSLVERR).

### Fields

| Register | Bits | Field | Access | Reset | Description |
|---|---|---|---|---|---|
| ID | 31:16 | CODE | RO | 0x7C08 | IP code |
| ID | 15:8 | MAJOR | RO | 0x01 | major version |
| ID | 7:0 | MINOR | RO | 0x00 | minor version |
| IRQ_STATUS | 1:0 | one bit per interrupt | W1C | 0x0 | see Interrupts |
| IRQ_ENABLE | 1:0 | one bit per interrupt | RW | 0x0 | 1 enables the IRQ_STATUS bit onto `irq` |
| SCRATCH | 31:0 | SCRATCH | RW | 0x00000000 | free for software |
| CUR_ADDR | 31:0 | `cur_addr` | RW | 0x0 | line 0, word aligned |
| PREV_ADDR | 31:0 | `prev_addr` | RW | 0x0 | line 0, word aligned |
| DST_ADDR | 31:0 | `dst_addr` | RW | 0x0 | line 0, word aligned |
| GEOM | 15:0 | `stride` | RW | 0x0 | line pitch in bytes |
| GEOM | 31:16 | `h_active` | RW | 0x0 | pixels per line |
| V_ACTIVE | 15:0 | `v_active` | RW | 0x0 | lines per frame |
| CTRL | 0 | `memc_en` | RW | 0x0 | blend with the previous frame |
| CTRL | 8:1 | `mv_frac` | RW | 0x0 | weight of the current frame, 0..255 |
| CTRL | 9 | `tone_en` | RW | 0x0 | apply the loaded tone curve |
| META0 | 31:0 | `meta0` | RW | 0x0 | format[15:0], content max nits[31:16] |
| META1 | 31:0 | `meta1` | RW | 0x0 | content min, mastering peak |
| META2 | 31:0 | `meta2` | RW | 0x0 | mastering fall, trim gain (Q2.14) |
| META3 | 31:0 | `meta3` | RW | 0x0 | trim offset (Q0.16) |
| DISPLAY_PEAK | 15:0 | `display_peak` | RW | 0x0 | nits |
| CMD | 0 | `meta_load` | WO (pulse) | 0x0 | load META0..3 and DISPLAY_PEAK |
| CMD | 1 | `start` | WO (pulse) | 0x0 | process one frame; ignored while busy |
| STATUS | 0 | `busy` | RO | core | a frame is being processed |
| STATUS | 1 | `err` | RO | core | AXI error response |
| STATUS | 2 | `cfg_err` | RO | core | H_ACTIVE 0 or above MAXW |
| STATUS | 3 | `params_ok` | RO | core | tone parameters loaded |
| TONE | 15:0 | `tone_slope` | RO | core | Q0.16 slope above the knee |
| TONE | 31:16 | `content_max` | RO | core | content peak nits |
| LINES | 15:0 | `lines` | RO | core | lines written by the current / last frame |
| CYCLES | 31:0 | `cycles` | RO | core | clocks from start to DONE |

### Interrupts (IRQ_STATUS, IRQ_ENABLE)

A bit is set while its source is active, stays set until written with 1, and a set in the same clock as the clear wins.

| Bit | Name | Set when |
|---|---|---|
| 0 | DONE | a job ended |
| 1 | ERR | a job ended that saw an AXI error response |

## Programming sequence

1. Release PRESETN. Read ID (0x000) and check it is 0x7C080100.
2. Write 0x3 to IRQ_STATUS (0x004) to clear any stale bits.
3. Configure the core: write CUR_ADDR (0x014), PREV_ADDR (0x018), DST_ADDR (0x01C), GEOM (0x020), V_ACTIVE (0x024), CTRL (0x028), META0 (0x02C), META1 (0x030), META2 (0x034), META3 (0x038), DISPLAY_PEAK (0x03C). Reset values are in the register map; PSTRB selects the bytes written.
4. Write IRQ_ENABLE (0x008) with the interrupts to use (bit order as in the Interrupts table; 0x3 enables all).
5. To issue a command, write 1 to `meta_load` (CMD bit 0), `start` (CMD bit 1) at 0x040; the core sees a one-clock pulse, and the register reads 0.
6. Read STATUS (0x044) for the core's live `busy`, `err`, `cfg_err`, `params_ok`; it needs no clearing.
7. Read TONE (0x048) for the core's live `tone_slope`, `content_max`; it needs no clearing.
8. Read LINES (0x04C) for the core's live `lines`; it needs no clearing.
9. Read CYCLES (0x050) for the core's live `cycles`; it needs no clearing.
10. On `irq`: read IRQ_STATUS, handle every bit that is set and enabled, then write those bits back to IRQ_STATUS to clear them. A source that is still active sets its bit again.

IP-specific use:

1. Write META0..3 and DISPLAY_PEAK, CMD.meta_load = 1; wait for STATUS.params_ok.
2. Write CUR_ADDR, PREV_ADDR, DST_ADDR, GEOM, V_ACTIVE, CTRL and IRQ_ENABLE.
3. Write CMD.start = 1 (ignored while STATUS.busy is 1).
4. Wait for irq (or poll STATUS.busy = 0), read the result registers, write 1s to IRQ_STATUS to clear it.

## Running and verifying

All commands run from the repository root. Icarus Verilog 12 and Yosys 0.33 are enough for steps 1 to 3; step 4 also needs Verilator 5.052 and pyslang (see [README, Setup](../../README.md#setup)).

| Step | Command | Pass when | Output |
|---|---|---|---|
| 1. Core test | `make -f Makefile.PQ_MEMC sim` | a `TEST PASSED` line, no `ERROR` | console |
| 2. Core synthesis | `make -f Makefile.PQ_MEMC syn` | Yosys ends without `ERROR`; `stat` prints the cell count | `work/PQ_MEMC_top.json` |
| 3. APB wrapper test + synthesis | `make -f Makefile.PQ_MEMC apb` | `TEST PASSED: PQ_MEMC_apb`, then Yosys without `ERROR` | console, `work/PQ_MEMC_apb.json` |
| 4. Coverage (core, wrapper) | `bash scripts/cov/run_cov.sh PQ_MEMC`<br>`bash scripts/cov/run_cov.sh PQ_MEMC_apb` | `RESULT: CLOSED` (all five metrics 100%) | `work/cov/PQ_MEMC/score.json`, `work/cov/PQ_MEMC_apb/score.json` |

Expected end of a step 4 run:

```
===== PQ_MEMC =====
TEST: PASSED   SVA_FAILURES: 0
LINE ... TOGGLE ... FSM ... SVA ... FUNCTIONAL  (each n/n, 100.0%)
RESULT: CLOSED
```

**Core test** (`tb/PQ_MEMC_tb.sv`): drives `PQ_MEMC_top` through its own ports against a protocol peer or model and checks every result itself; any mismatch prints `ERROR`, and `TEST PASSED` is printed only when there were none.

**APB wrapper test** (`tb/PQ_MEMC_apb_tb.sv`), in this order:

1. Reset values of every register, ID included.
2. Writes to read-only registers are ignored.
3. Each RW register: all ones, all zeros, then 16 random writes with every PSTRB byte-lane pattern, read back each time.
4. Unmapped and misaligned addresses, reads and writes: PSLVERR, read data 0, no side effect on other registers.
5. Back-to-back transfers with no idle cycle.
6. IP traffic through the registers only (`tb/apb/PQ_MEMC_apb_func.svh`): the programming sequence above, every interrupt bit set, enabled and cleared (100% wrapper toggle coverage confirms each bit moved).
7. PRESETN asserted mid-run: `irq` and PRDATA go to 0, registers return to reset values.

**Checkers** (`tb/cov/PQ_MEMC_sva.sv`, `tb/cov/PQ_MEMC_apb_sva.sv`): SVA protocol and APB assertions plus covergroups, bound in by the coverage flow. An assertion failure prints `SVA_FAIL` and fails the run even when the test itself passed.

Whole portfolio: `bash scripts/ci_regression.sh` runs steps 1 to 3 for every IP (what CI runs), and `bash scripts/cov/run_all.sh 4` runs step 4 for every IP.

## Verification

Five-metric coverage with Verilator 5.052 (`scripts/cov/run_cov.sh`); see [COVERAGE_CLOSURE.md](../COVERAGE_CLOSURE.md) for the flow. Line and toggle count only the named RTL file.

| Scope | Test | Line | Toggle | FSM | SVA | Functional |
|---|---|---|---|---|---|---|
| core `rtl/PQ_MEMC_top.sv` | not run | | | | | |
| wrapper `rtl/PQ_MEMC_apb.sv` | not run | | | | | |
