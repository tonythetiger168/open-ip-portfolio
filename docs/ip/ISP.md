# Camera ISP: black level and digital gain on raw frames from a test pattern or sensor stream, written over AXI4

Protocol IP `ISP`, version 1.0. Apache-2.0.

| Item | Value |
|---|---|
| Core | `ISP_top` (`rtl/ISP_top.sv`) |
| Register interface | APB4 slave `ISP_apb`, 32-bit data, 12-bit byte address, zero wait states |
| Clock, reset | PCLK (rising edge), PRESETN (active low, asynchronous) |
| ID register | 0x5C030100 (code 0x5C03, version 1.0) |
| Registers | 13 words, 0x000 to 0x030 |
| Interrupts | 2 sources into one level-high `irq` |
| Protocol pins | 34 pass-through |

## Overview

ISP: camera image signal processor of the phone SoC (AXI4 manager, APB4 registers) Takes LEN words of 8-bit raw pixels (four per word, byte 0 first) from the sensor and writes the processed frame to DST with streaming writes: out = min(255, (max(0, p - BLACK) * GAIN) >> 4), GAIN unsigned Q4.4 (16 = 1.0). STAT_SUM is the sum of the output pixels of the last frame (an auto-exposure statistic).

- SRC_SEL 0: the built-in test pattern generator: pixel b of word x of
line y is (4x + b + y) ^ SEED, with LINE_WORDS words per line.
- SRC_SEL 1: the external sensor stream sns_valid / sns_data / sns_ready
(for example from a CSI-2 receiver), one word of four pixels per beat.
- DONE interrupt when a frame is written, ERR as well on an AXI error
response. CYCLES is the length of the last frame in clocks.
- AXI ID = AXI_ID; bursts of up to 16 beats, never across 4 KB.

Features:

- Four 8-bit pixels per word, byte 0 first; the job writes LEN words at DST.
- out = min(255, (max(0, p - BLACK) * GAIN) >> 4); GAIN is unsigned Q4.4 (16 = 1.0).
- SRC_SEL 0: test pattern, pixel b of word x of line y = ((4x + b + y) mod 256) ^ SEED, LINE_WORDS words per line (x restarts at 0 when x + 1 >= LINE_WORDS).
- SRC_SEL 1: the sensor stream sns_valid / sns_data / sns_ready, one word per beat (sns_ready is high only while a job can take a word).
- STAT_SUM is the sum of all output pixels of the last frame.

m_* is the AXI4 manager port (32-bit address and data, 4-bit ID, no user / QoS); it passes through unchanged. Bursts are INCR, AxSIZE = 2 (4 bytes), 1 to 16 beats, WSTRB = 4'hF, never across a 4 KB boundary; one read and one write burst are outstanding at a time. A read burst is issued only when its data has room, a write burst only when all its data is ready.
sns_valid / sns_data / sns_ready (the sensor stream) pass through unchanged.

## Files

| File | Content |
|---|---|
| `rtl/ISP_top.sv` | protocol core |
| `rtl/ISP_apb.sv` | APB4 register wrapper (generated) |
| `tb/ISP_tb.sv` | core testbench |
| `tb/ISP_apb_tb.sv`, `tb/apb/ISP_apb_func.svh` | wrapper testbench (generated part + IP-specific part) |
| `tb/cov/ISP_sva.sv`, `tb/cov/ISP_apb_sva.sv` | coverage checkers (core, wrapper) |
| `scripts/apb/specs/ISP.json` | register spec the wrapper, TB, checker and this page are generated from |

How to run the tests and the coverage flow: see [Running and verifying](#running-and-verifying).

## Parameters

`ISP_apb` has the core's parameters and passes them to `ISP_top` unchanged.

| Parameter | Type | Default |
|---|---|---|
| `AXI_ID` | logic [3:0] | `4'd3` |

## Wrapper pins

Pins of `ISP_apb`. Widths of the pass-through pins are at the default parameters.

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
| `sns_valid` | input | 1 | protocol pin, core port `sns_valid` |
| `sns_data` | input | 32 | protocol pin, core port `sns_data` |
| `sns_ready` | output | 1 | protocol pin, core port `sns_ready` |
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
| `dst_addr` | input | 32 | DST_ADDR[31:0] |
| `xfer_len` | input | 16 | LEN[15:0] |
| `line_words` | input | 16 | LINE[15:0] |
| `src_sel` | input | 1 | CTRL[0:0] |
| `seed` | input | 8 | CTRL[8:1] |
| `black` | input | 8 | CTRL[16:9] |
| `gain` | input | 8 | CTRL[24:17] |
| `start` | input | 1 | CMD |
| `busy` | output | 1 | STATUS[0:0] |
| `err` | output | 1 | STATUS[1:1] |
| `stat_sum` | output | 32 | STAT_SUM[31:0] |
| `cycles` | output | 32 | CYCLES[31:0] |
| `done` | output | 1 | IRQ_STATUS.DONE |
| `err_irq` | output | 1 | IRQ_STATUS.ERR |
| `sns_valid` | input | 1 | pin (pass-through) |
| `sns_data` | input | 32 | pin (pass-through) |
| `sns_ready` | output | 1 | pin (pass-through) |
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

`ISP_apb` is an APB4 slave (AMBA APB protocol v2.0): zero wait states, 32-bit data, 12-bit byte address, PSTRB byte lanes on every writable register, PSLVERR on an unmapped or misaligned address (reads then return 0, writes are dropped). Writes to read-only registers are ignored without an error. The core runs on PCLK and PRESETN. `irq` is level-high: `|(IRQ_STATUS & IRQ_ENABLE)`.

Pass-through pins: `sns_valid`, `sns_data`, `sns_ready`, `m_awid`, `m_awaddr`, `m_awlen`, `m_awsize`, `m_awburst`, `m_awprot`, `m_awvalid`, `m_awready`, `m_wdata`, `m_wstrb`, `m_wlast`, `m_wvalid`, `m_wready`, `m_bid`, `m_bresp`, `m_bvalid`, `m_bready`, `m_arid`, `m_araddr`, `m_arlen`, `m_arsize`, `m_arburst`, `m_arprot`, `m_arvalid`, `m_arready`, `m_rid`, `m_rdata`, `m_rresp`, `m_rlast`, `m_rvalid`, `m_rready`.

### Register map

| Offset | Name | Access | Reset | Description |
|---|---|---|---|---|
| 0x000 | ID | RO | 0x5C030100 | IP identification: code, major and minor version |
| 0x004 | IRQ_STATUS | W1C | 0x00000000 | Sticky interrupt bits, write 1 to clear |
| 0x008 | IRQ_ENABLE | RW | 0x00000000 | Interrupt enables; irq = \|(IRQ_STATUS & IRQ_ENABLE) |
| 0x00C | FLAGS | RO | 0x00000000 | Stream holding-register state |
| 0x010 | SCRATCH | RW | 0x00000000 | Scratch register, no effect on the core |
| 0x014 | DST_ADDR | RW | 0x00000000 | Destination address (byte address, word aligned) |
| 0x018 | LEN | RW | 0x00000000 | Job length |
| 0x01C | CTRL | RW | 0x00200000 | Source and processing |
| 0x020 | LINE | RW | 0x00000000 | Frame geometry |
| 0x024 | CMD | WO (pulse) | 0x00000000 | Commands (write 1) |
| 0x028 | STATUS | RO | core | Job state |
| 0x02C | STAT_SUM | RO | core | Exposure statistic |
| 0x030 | CYCLES | RO | core | Job length in clocks |

Unlisted bits read 0 and ignore writes. Reset "core": the register reads the core's outputs directly, so after reset it shows the core's own reset state. WO (pulse) registers read 0. Offsets from 0x034 up to 0xFFC are unmapped (PSLVERR).

### Fields

| Register | Bits | Field | Access | Reset | Description |
|---|---|---|---|---|---|
| ID | 31:16 | CODE | RO | 0x5C03 | IP code |
| ID | 15:8 | MAJOR | RO | 0x01 | major version |
| ID | 7:0 | MINOR | RO | 0x00 | minor version |
| IRQ_STATUS | 1:0 | one bit per interrupt | W1C | 0x0 | see Interrupts |
| IRQ_ENABLE | 1:0 | one bit per interrupt | RW | 0x0 | 1 enables the IRQ_STATUS bit onto `irq` |
| SCRATCH | 31:0 | SCRATCH | RW | 0x00000000 | free for software |
| DST_ADDR | 31:0 | `dst_addr` | RW | 0x0 | first word written by the job |
| LEN | 15:0 | `xfer_len` | RW | 0x0 | 32-bit words (0: the job ends at once) |
| CTRL | 0 | `src_sel` | RW | 0x0 | 0 test pattern, 1 sensor stream |
| CTRL | 8:1 | `seed` | RW | 0x0 | test pattern seed |
| CTRL | 16:9 | `black` | RW | 0x0 | black level |
| CTRL | 24:17 | `gain` | RW | 0x10 | gain, Q4.4 |
| LINE | 15:0 | `line_words` | RW | 0x0 | words per line (test pattern) |
| CMD | 0 | `start` | WO (pulse) | 0x0 | start a job with the current registers; ignored while busy |
| STATUS | 0 | `busy` | RO | core | a job is running |
| STATUS | 1 | `err` | RO | core | the current / last job saw an AXI error response (cleared by start) |
| STAT_SUM | 31:0 | `stat_sum` | RO | core | sum of the output pixels |
| CYCLES | 31:0 | `cycles` | RO | core | clocks from start to DONE of the current / last job |

### Interrupts (IRQ_STATUS, IRQ_ENABLE)

A bit is set while its source is active, stays set until written with 1, and a set in the same clock as the clear wins.

| Bit | Name | Set when |
|---|---|---|
| 0 | DONE | a job ended |
| 1 | ERR | a job ended that saw an AXI error response |

## Programming sequence

1. Release PRESETN. Read ID (0x000) and check it is 0x5C030100.
2. Write 0x3 to IRQ_STATUS (0x004) to clear any stale bits.
3. Configure the core: write DST_ADDR (0x014), LEN (0x018), CTRL (0x01C), LINE (0x020). Reset values are in the register map; PSTRB selects the bytes written.
4. Write IRQ_ENABLE (0x008) with the interrupts to use (bit order as in the Interrupts table; 0x3 enables all).
5. To issue a command, write 1 to `start` (CMD bit 0) at 0x024; the core sees a one-clock pulse, and the register reads 0.
6. Read STATUS (0x028) for the core's live `busy`, `err`; it needs no clearing.
7. Read STAT_SUM (0x02C) for the core's live `stat_sum`; it needs no clearing.
8. Read CYCLES (0x030) for the core's live `cycles`; it needs no clearing.
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
| 1. Core test | `make -f Makefile.ISP sim` | a `TEST PASSED` line, no `ERROR` | console |
| 2. Core synthesis | `make -f Makefile.ISP syn` | Yosys ends without `ERROR`; `stat` prints the cell count | `work/ISP_top.json` |
| 3. APB wrapper test + synthesis | `make -f Makefile.ISP apb` | `TEST PASSED: ISP_apb`, then Yosys without `ERROR` | console, `work/ISP_apb.json` |
| 4. Coverage (core, wrapper) | `bash scripts/cov/run_cov.sh ISP`<br>`bash scripts/cov/run_cov.sh ISP_apb` | `RESULT: CLOSED` (all five metrics 100%) | `work/cov/ISP/score.json`, `work/cov/ISP_apb/score.json` |

Expected end of a step 4 run:

```
===== ISP =====
TEST: PASSED   SVA_FAILURES: 0
LINE ... TOGGLE ... FSM ... SVA ... FUNCTIONAL  (each n/n, 100.0%)
RESULT: CLOSED
```

**Core test** (`tb/ISP_tb.sv`): drives `ISP_top` through its own ports against a protocol peer or model and checks every result itself; any mismatch prints `ERROR`, and `TEST PASSED` is printed only when there were none.

**APB wrapper test** (`tb/ISP_apb_tb.sv`), in this order:

1. Reset values of every register, ID included.
2. Writes to read-only registers are ignored.
3. Each RW register: all ones, all zeros, then 16 random writes with every PSTRB byte-lane pattern, read back each time.
4. Unmapped and misaligned addresses, reads and writes: PSLVERR, read data 0, no side effect on other registers.
5. Back-to-back transfers with no idle cycle.
6. IP traffic through the registers only (`tb/apb/ISP_apb_func.svh`): the programming sequence above, every interrupt bit set, enabled and cleared (100% wrapper toggle coverage confirms each bit moved).
7. PRESETN asserted mid-run: `irq` and PRDATA go to 0, registers return to reset values.

**Checkers** (`tb/cov/ISP_sva.sv`, `tb/cov/ISP_apb_sva.sv`): SVA protocol and APB assertions plus covergroups, bound in by the coverage flow. An assertion failure prints `SVA_FAIL` and fails the run even when the test itself passed.

Whole portfolio: `bash scripts/ci_regression.sh` runs steps 1 to 3 for every IP (what CI runs), and `bash scripts/cov/run_all.sh 4` runs step 4 for every IP.

## Verification

Five-metric coverage with Verilator 5.052 (`scripts/cov/run_cov.sh`); see [COVERAGE_CLOSURE.md](../COVERAGE_CLOSURE.md) for the flow. Line and toggle count only the named RTL file.

| Scope | Test | Line | Toggle | FSM | SVA | Functional |
|---|---|---|---|---|---|---|
| core `rtl/ISP_top.sv` | not run | | | | | |
| wrapper `rtl/ISP_apb.sv` | pass | 36/36 | 1169/1368 (+66 excl.) | n/a | 15/15 | 44/44 |
