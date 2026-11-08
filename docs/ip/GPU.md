# GPU 2D engine: copy, fill, alpha blend and invert of RGBA8888 surfaces over AXI4

Protocol IP `GPU`, version 1.0. Apache-2.0.

| Item | Value |
|---|---|
| Core | `GPU_top` (`rtl/GPU_top.sv`) |
| Register interface | APB4 slave `GPU_apb`, 32-bit data, 12-bit byte address, zero wait states |
| Clock, reset | PCLK (rising edge), PRESETN (active low, asynchronous) |
| ID register | 0x5C010100 (code 0x5C01, version 1.0) |
| Registers | 14 words, 0x000 to 0x034 |
| Interrupts | 2 sources into one level-high `irq` |
| Protocol pins | 31 pass-through |

## Overview

GPU: 2D graphics engine of the phone SoC (AXI4 manager, APB4 registers) A blitter on RGBA8888 surfaces (one pixel per 32-bit word): each job processes LEN pixels from SRC to DST.

- MODE 0 COPY: dst = src.
- MODE 1 FILL: dst = COLOR (no reads), a solid rectangle or a clear.
- MODE 2 BLEND: each 8-bit channel c of a pixel becomes
(src.c * ALPHA + COLOR.c * (256 - ALPHA)) >> 8, ALPHA = 0..256 (256: src).
- MODE 3 INVERT: dst = ~src on the colour channels, alpha (bits 31:24) kept.
- DONE interrupt when a job ends, ERR as well on an AXI error response.
- PIXELS counts the pixels written by the last job, CYCLES its length.
- AXI ID = AXI_ID; bursts of up to 16 beats, never across 4 KB.

Features:

- One RGBA8888 pixel per 32-bit word; channel c is bits 8c+7:8c.
- MODE 0 COPY: dst = src.
- MODE 1 FILL: dst = COLOR, write-only.
- MODE 2 BLEND: per channel, dst.c = (src.c * A + COLOR.c * (256 - A)) >> 8 with A = min(ALPHA, 256).
- MODE 3 INVERT: dst = {src[31:24], ~src[23:0]}.
- PIXELS counts the pixels written by the last job.

m_* is the AXI4 manager port (32-bit address and data, 4-bit ID, no user / QoS); it passes through unchanged. Bursts are INCR, AxSIZE = 2 (4 bytes), 1 to 16 beats, WSTRB = 4'hF, never across a 4 KB boundary; one read and one write burst are outstanding at a time. A read burst is issued only when its data has room, a write burst only when all its data is ready.

## Files

| File | Content |
|---|---|
| `rtl/GPU_top.sv` | protocol core |
| `rtl/GPU_apb.sv` | APB4 register wrapper (generated) |
| `tb/GPU_tb.sv` | core testbench |
| `tb/GPU_apb_tb.sv`, `tb/apb/GPU_apb_func.svh` | wrapper testbench (generated part + IP-specific part) |
| `tb/cov/GPU_sva.sv`, `tb/cov/GPU_apb_sva.sv` | coverage checkers (core, wrapper) |
| `scripts/apb/specs/GPU.json` | register spec the wrapper, TB, checker and this page are generated from |

How to run the tests and the coverage flow: see [Running and verifying](#running-and-verifying).

## Parameters

`GPU_apb` has the core's parameters and passes them to `GPU_top` unchanged.

| Parameter | Type | Default |
|---|---|---|
| `AXI_ID` | logic [3:0] | `4'd1` |

## Wrapper pins

Pins of `GPU_apb`. Widths of the pass-through pins are at the default parameters.

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
| `src_addr` | input | 32 | SRC_ADDR[31:0] |
| `dst_addr` | input | 32 | DST_ADDR[31:0] |
| `xfer_len` | input | 16 | LEN[15:0] |
| `mode` | input | 2 | CTRL[1:0] |
| `alpha` | input | 9 | CTRL[10:2] |
| `color` | input | 32 | COLOR[31:0] |
| `start` | input | 1 | CMD |
| `busy` | output | 1 | STATUS[0:0] |
| `err` | output | 1 | STATUS[1:1] |
| `pixels` | output | 16 | PIXELS[15:0] |
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

`GPU_apb` is an APB4 slave (AMBA APB protocol v2.0): zero wait states, 32-bit data, 12-bit byte address, PSTRB byte lanes on every writable register, PSLVERR on an unmapped or misaligned address (reads then return 0, writes are dropped). Writes to read-only registers are ignored without an error. The core runs on PCLK and PRESETN. `irq` is level-high: `|(IRQ_STATUS & IRQ_ENABLE)`.

Pass-through pins: `m_awid`, `m_awaddr`, `m_awlen`, `m_awsize`, `m_awburst`, `m_awprot`, `m_awvalid`, `m_awready`, `m_wdata`, `m_wstrb`, `m_wlast`, `m_wvalid`, `m_wready`, `m_bid`, `m_bresp`, `m_bvalid`, `m_bready`, `m_arid`, `m_araddr`, `m_arlen`, `m_arsize`, `m_arburst`, `m_arprot`, `m_arvalid`, `m_arready`, `m_rid`, `m_rdata`, `m_rresp`, `m_rlast`, `m_rvalid`, `m_rready`.

### Register map

| Offset | Name | Access | Reset | Description |
|---|---|---|---|---|
| 0x000 | ID | RO | 0x5C010100 | IP identification: code, major and minor version |
| 0x004 | IRQ_STATUS | W1C | 0x00000000 | Sticky interrupt bits, write 1 to clear |
| 0x008 | IRQ_ENABLE | RW | 0x00000000 | Interrupt enables; irq = \|(IRQ_STATUS & IRQ_ENABLE) |
| 0x00C | FLAGS | RO | 0x00000000 | Stream holding-register state |
| 0x010 | SCRATCH | RW | 0x00000000 | Scratch register, no effect on the core |
| 0x014 | SRC_ADDR | RW | 0x00000000 | Source address (byte address, word aligned) |
| 0x018 | DST_ADDR | RW | 0x00000000 | Destination address (byte address, word aligned) |
| 0x01C | LEN | RW | 0x00000000 | Job length |
| 0x020 | CTRL | RW | 0x00000000 | Job options |
| 0x024 | COLOR | RW | 0x00000000 | Fill / blend colour |
| 0x028 | CMD | WO (pulse) | 0x00000000 | Commands (write 1) |
| 0x02C | STATUS | RO | core | Job state |
| 0x030 | PIXELS | RO | core | Pixels written |
| 0x034 | CYCLES | RO | core | Job length in clocks |

Unlisted bits read 0 and ignore writes. Reset "core": the register reads the core's outputs directly, so after reset it shows the core's own reset state. WO (pulse) registers read 0. Offsets from 0x038 up to 0xFFC are unmapped (PSLVERR).

### Fields

| Register | Bits | Field | Access | Reset | Description |
|---|---|---|---|---|---|
| ID | 31:16 | CODE | RO | 0x5C01 | IP code |
| ID | 15:8 | MAJOR | RO | 0x01 | major version |
| ID | 7:0 | MINOR | RO | 0x00 | minor version |
| IRQ_STATUS | 1:0 | one bit per interrupt | W1C | 0x0 | see Interrupts |
| IRQ_ENABLE | 1:0 | one bit per interrupt | RW | 0x0 | 1 enables the IRQ_STATUS bit onto `irq` |
| SCRATCH | 31:0 | SCRATCH | RW | 0x00000000 | free for software |
| SRC_ADDR | 31:0 | `src_addr` | RW | 0x0 | first word read by the job |
| DST_ADDR | 31:0 | `dst_addr` | RW | 0x0 | first word written by the job |
| LEN | 15:0 | `xfer_len` | RW | 0x0 | 32-bit words (0: the job ends at once) |
| CTRL | 1:0 | `mode` | RW | 0x0 | 0 COPY, 1 FILL, 2 BLEND, 3 INVERT |
| CTRL | 10:2 | `alpha` | RW | 0x0 | BLEND weight of src, 0..256 |
| COLOR | 31:0 | `color` | RW | 0x0 | RGBA8888 |
| CMD | 0 | `start` | WO (pulse) | 0x0 | start a job with the current registers; ignored while busy |
| STATUS | 0 | `busy` | RO | core | a job is running |
| STATUS | 1 | `err` | RO | core | the current / last job saw an AXI error response (cleared by start) |
| PIXELS | 15:0 | `pixels` | RO | core | pixels written by the current / last job |
| CYCLES | 31:0 | `cycles` | RO | core | clocks from start to DONE of the current / last job |

### Interrupts (IRQ_STATUS, IRQ_ENABLE)

A bit is set while its source is active, stays set until written with 1, and a set in the same clock as the clear wins.

| Bit | Name | Set when |
|---|---|---|
| 0 | DONE | a job ended |
| 1 | ERR | a job ended that saw an AXI error response |

## Programming sequence

1. Release PRESETN. Read ID (0x000) and check it is 0x5C010100.
2. Write 0x3 to IRQ_STATUS (0x004) to clear any stale bits.
3. Configure the core: write SRC_ADDR (0x014), DST_ADDR (0x018), LEN (0x01C), CTRL (0x020), COLOR (0x024). Reset values are in the register map; PSTRB selects the bytes written.
4. Write IRQ_ENABLE (0x008) with the interrupts to use (bit order as in the Interrupts table; 0x3 enables all).
5. To issue a command, write 1 to `start` (CMD bit 0) at 0x028; the core sees a one-clock pulse, and the register reads 0.
6. Read STATUS (0x02C) for the core's live `busy`, `err`; it needs no clearing.
7. Read PIXELS (0x030) for the core's live `pixels`; it needs no clearing.
8. Read CYCLES (0x034) for the core's live `cycles`; it needs no clearing.
9. On `irq`: read IRQ_STATUS, handle every bit that is set and enabled, then write those bits back to IRQ_STATUS to clear them. A source that is still active sets its bit again.

IP-specific use:

1. Write SRC_ADDR, DST_ADDR (word aligned) and LEN (32-bit words).
2. Write CTRL with the job's options and IRQ_ENABLE with DONE (and ERR).
3. Write CMD.start = 1 (ignored while STATUS.busy is 1).
4. Wait for irq (or poll STATUS.busy = 0), read the result registers, write 1s to IRQ_STATUS to clear it.

## Running and verifying

All commands run from the repository root. Icarus Verilog 12 and Yosys 0.33 are enough for steps 1 to 3; step 4 also needs Verilator 5.052 and pyslang (see [README, Setup](../../README.md#setup)).

| Step | Command | Pass when | Output |
|---|---|---|---|
| 1. Core test | `make -f Makefile.GPU sim` | a `TEST PASSED` line, no `ERROR` | console |
| 2. Core synthesis | `make -f Makefile.GPU syn` | Yosys ends without `ERROR`; `stat` prints the cell count | `work/GPU_top.json` |
| 3. APB wrapper test + synthesis | `make -f Makefile.GPU apb` | `TEST PASSED: GPU_apb`, then Yosys without `ERROR` | console, `work/GPU_apb.json` |
| 4. Coverage (core, wrapper) | `bash scripts/cov/run_cov.sh GPU`<br>`bash scripts/cov/run_cov.sh GPU_apb` | `RESULT: CLOSED` (all five metrics 100%) | `work/cov/GPU/score.json`, `work/cov/GPU_apb/score.json` |

Expected end of a step 4 run:

```
===== GPU =====
TEST: PASSED   SVA_FAILURES: 0
LINE ... TOGGLE ... FSM ... SVA ... FUNCTIONAL  (each n/n, 100.0%)
RESULT: CLOSED
```

**Core test** (`tb/GPU_tb.sv`): drives `GPU_top` through its own ports against a protocol peer or model and checks every result itself; any mismatch prints `ERROR`, and `TEST PASSED` is printed only when there were none.

**APB wrapper test** (`tb/GPU_apb_tb.sv`), in this order:

1. Reset values of every register, ID included.
2. Writes to read-only registers are ignored.
3. Each RW register: all ones, all zeros, then 16 random writes with every PSTRB byte-lane pattern, read back each time.
4. Unmapped and misaligned addresses, reads and writes: PSLVERR, read data 0, no side effect on other registers.
5. Back-to-back transfers with no idle cycle.
6. IP traffic through the registers only (`tb/apb/GPU_apb_func.svh`): the programming sequence above, every interrupt bit set, enabled and cleared (100% wrapper toggle coverage confirms each bit moved).
7. PRESETN asserted mid-run: `irq` and PRDATA go to 0, registers return to reset values.

**Checkers** (`tb/cov/GPU_sva.sv`, `tb/cov/GPU_apb_sva.sv`): SVA protocol and APB assertions plus covergroups, bound in by the coverage flow. An assertion failure prints `SVA_FAIL` and fails the run even when the test itself passed.

Whole portfolio: `bash scripts/ci_regression.sh` runs steps 1 to 3 for every IP (what CI runs), and `bash scripts/cov/run_all.sh 4` runs step 4 for every IP.

## Verification

Five-metric coverage with Verilator 5.052 (`scripts/cov/run_cov.sh`); see [COVERAGE_CLOSURE.md](../COVERAGE_CLOSURE.md) for the flow. Line and toggle count only the named RTL file.

| Scope | Test | Line | Toggle | FSM | SVA | Functional |
|---|---|---|---|---|---|---|
| core `rtl/GPU_top.sv` | not run | | | | | |
| wrapper `rtl/GPU_apb.sv` | pass | 39/39 | 1346/1406 (+54 excl.) | n/a | 14/14 | 46/46 |
