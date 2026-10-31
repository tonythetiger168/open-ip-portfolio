# Avalon-MM agent: a 256-word memory with a wait-state window, read and write bursts of up to 16 beats with byte enables, pipelined read data

Protocol IP `Avalon_MM`, version 2.0. Apache-2.0.

| Item | Value |
|---|---|
| Core | `Avalon_MM_top` (`rtl/Avalon_MM_top.sv`) |
| Register interface | APB4 slave `Avalon_MM_apb`, 32-bit data, 12-bit byte address, zero wait states |
| Clock, reset | PCLK (rising edge), PRESETN (active low, asynchronous) |
| ID register | 0x414D0200 (code 0x414D, version 2.0) |
| Registers | 5 words, 0x000 to 0x010 |
| Interrupts | 1 sources into one level-high `irq` |
| Protocol pins | 9 pass-through |

## Overview

av_address, av_read, av_write, av_writedata, av_byteenable, av_burstcount, av_readdata, av_readdatavalid and av_waitrequest are the Avalon-MM agent pins; they pass through unchanged. The registers report the agent's error event.
Bytes 0x000 to 0x1FF answer without wait states; 0x200 to 0x3FF cost one wait state per command or write beat and one idle cycle before each read beat. Beats above 0x3FF are dropped (writes) or return 0 (reads). A burstcount of 0 is one beat, above 16 is clamped to 16. waitrequest stays high while read data is returned.

## Files

| File | Content |
|---|---|
| `rtl/Avalon_MM_top.sv` | protocol core |
| `rtl/Avalon_MM_apb.sv` | APB4 register wrapper (generated) |
| `tb/Avalon_MM_tb.sv` | core testbench |
| `tb/Avalon_MM_apb_tb.sv`, `tb/apb/Avalon_MM_apb_func.svh` | wrapper testbench (generated part + IP-specific part) |
| `tb/cov/Avalon_MM_sva.sv`, `tb/cov/Avalon_MM_apb_sva.sv` | coverage checkers (core, wrapper) |
| `scripts/apb/specs/Avalon_MM.json` | register spec the wrapper, TB, checker and this page are generated from |

How to run the tests and the coverage flow: see [Running and verifying](#running-and-verifying).

## Parameters

`Avalon_MM_apb` has the core's parameters and passes them to `Avalon_MM_top` unchanged.

| Parameter | Type | Default |
|---|---|---|
| `DW` | int | `32` |
| `AW` | int | `32` |
| `DEPTH` | int | `256` |

## Wrapper pins

Pins of `Avalon_MM_apb`. Widths of the pass-through pins are at the default parameters.

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
| `av_address` | input | 32 | protocol pin, core port `av_address` |
| `av_read` | input | 1 | protocol pin, core port `av_read` |
| `av_write` | input | 1 | protocol pin, core port `av_write` |
| `av_writedata` | input | 32 | protocol pin, core port `av_writedata` |
| `av_byteenable` | input | 4 | protocol pin, core port `av_byteenable` |
| `av_burstcount` | input | 8 | protocol pin, core port `av_burstcount` |
| `av_readdata` | output | 32 | protocol pin, core port `av_readdata` |
| `av_readdatavalid` | output | 1 | protocol pin, core port `av_readdatavalid` |
| `av_waitrequest` | output | 1 | protocol pin, core port `av_waitrequest` |

## Core ports

| Port | Dir | Width | In the APB wrapper |
|---|---|---|---|
| `clk` | input | 1 | PCLK |
| `rst_n` | input | 1 | PRESETN |
| `av_address` | input | 32 | pin (pass-through) |
| `av_read` | input | 1 | pin (pass-through) |
| `av_write` | input | 1 | pin (pass-through) |
| `av_writedata` | input | 32 | pin (pass-through) |
| `av_byteenable` | input | 4 | pin (pass-through) |
| `av_burstcount` | input | 8 | pin (pass-through) |
| `av_readdata` | output | 32 | pin (pass-through) |
| `av_readdatavalid` | output | 1 | pin (pass-through) |
| `av_waitrequest` | output | 1 | pin (pass-through) |
| `irq` | output | 1 | IRQ_STATUS.ERR |

## APB wrapper

`Avalon_MM_apb` is an APB4 slave (AMBA APB protocol v2.0): zero wait states, 32-bit data, 12-bit byte address, PSTRB byte lanes on every writable register, PSLVERR on an unmapped or misaligned address (reads then return 0, writes are dropped). Writes to read-only registers are ignored without an error. The core runs on PCLK and PRESETN. `irq` is level-high: `|(IRQ_STATUS & IRQ_ENABLE)`.

Pass-through pins: `av_address`, `av_read`, `av_write`, `av_writedata`, `av_byteenable`, `av_burstcount`, `av_readdata`, `av_readdatavalid`, `av_waitrequest`.

### Register map

| Offset | Name | Access | Reset | Description |
|---|---|---|---|---|
| 0x000 | ID | RO | 0x414D0200 | IP identification: code, major and minor version |
| 0x004 | IRQ_STATUS | W1C | 0x00000000 | Sticky interrupt bits, write 1 to clear |
| 0x008 | IRQ_ENABLE | RW | 0x00000000 | Interrupt enables; irq = \|(IRQ_STATUS & IRQ_ENABLE) |
| 0x00C | FLAGS | RO | 0x00000000 | Stream holding-register state |
| 0x010 | SCRATCH | RW | 0x00000000 | Scratch register, no effect on the core |

Unlisted bits read 0 and ignore writes. Reset "core": the register reads the core's outputs directly, so after reset it shows the core's own reset state. WO (pulse) registers read 0. Offsets from 0x014 up to 0xFFC are unmapped (PSLVERR).

### Fields

| Register | Bits | Field | Access | Reset | Description |
|---|---|---|---|---|---|
| ID | 31:16 | CODE | RO | 0x414D | IP code |
| ID | 15:8 | MAJOR | RO | 0x02 | major version |
| ID | 7:0 | MINOR | RO | 0x00 | minor version |
| IRQ_STATUS | 0 | one bit per interrupt | W1C | 0x0 | see Interrupts |
| IRQ_ENABLE | 0 | one bit per interrupt | RW | 0x0 | 1 enables the IRQ_STATUS bit onto `irq` |
| SCRATCH | 31:0 | SCRATCH | RW | 0x00000000 | free for software |

### Interrupts (IRQ_STATUS, IRQ_ENABLE)

A bit is set while its source is active, stays set until written with 1, and a set in the same clock as the clear wins.

| Bit | Name | Set when |
|---|---|---|
| 0 | ERR | an access outside the memory, a burstcount above 16, or read and write asserted together; the core holds this until reset, so the bit cannot be cleared before then |

## Programming sequence

1. Release PRESETN. Read ID (0x000) and check it is 0x414D0200.
2. Write 0x1 to IRQ_STATUS (0x004) to clear any stale bits.
3. Write IRQ_ENABLE (0x008) with the interrupts to use (bit order as in the Interrupts table; 0x1 enables all).
4. On `irq`: read IRQ_STATUS, handle every bit that is set and enabled, then write those bits back to IRQ_STATUS to clear them. A source that is still active sets its bit again.

## Running and verifying

All commands run from the repository root. Icarus Verilog 12 and Yosys 0.33 are enough for steps 1 to 3; step 4 also needs Verilator 5.052 and pyslang (see [README, Setup](../../README.md#setup)).

| Step | Command | Pass when | Output |
|---|---|---|---|
| 1. Core test | `make -f Makefile.Avalon_MM sim` | a `TEST PASSED` line, no `ERROR` | console |
| 2. Core synthesis | `make -f Makefile.Avalon_MM syn` | Yosys ends without `ERROR`; `stat` prints the cell count | `work/Avalon_MM_top.json` |
| 3. APB wrapper test + synthesis | `make -f Makefile.Avalon_MM apb` | `TEST PASSED: Avalon_MM_apb`, then Yosys without `ERROR` | console, `work/Avalon_MM_apb.json` |
| 4. Coverage (core, wrapper) | `bash scripts/cov/run_cov.sh Avalon_MM`<br>`bash scripts/cov/run_cov.sh Avalon_MM_apb` | `RESULT: CLOSED` (all five metrics 100%) | `work/cov/Avalon_MM/score.json`, `work/cov/Avalon_MM_apb/score.json` |

Expected end of a step 4 run:

```
===== Avalon_MM =====
TEST: PASSED   SVA_FAILURES: 0
LINE ... TOGGLE ... FSM ... SVA ... FUNCTIONAL  (each n/n, 100.0%)
RESULT: CLOSED
```

**Core test** (`tb/Avalon_MM_tb.sv`): drives `Avalon_MM_top` through its own ports against a protocol peer or model and checks every result itself; any mismatch prints `ERROR`, and `TEST PASSED` is printed only when there were none.

**APB wrapper test** (`tb/Avalon_MM_apb_tb.sv`), in this order:

1. Reset values of every register, ID included.
2. Writes to read-only registers are ignored.
3. Each RW register: all ones, all zeros, then 16 random writes with every PSTRB byte-lane pattern, read back each time.
4. Unmapped and misaligned addresses, reads and writes: PSLVERR, read data 0, no side effect on other registers.
5. Back-to-back transfers with no idle cycle.
6. IP traffic through the registers only (`tb/apb/Avalon_MM_apb_func.svh`): the programming sequence above, every interrupt bit set, enabled and cleared (100% wrapper toggle coverage confirms each bit moved).
7. PRESETN asserted mid-run: `irq` and PRDATA go to 0, registers return to reset values.

**Checkers** (`tb/cov/Avalon_MM_sva.sv`, `tb/cov/Avalon_MM_apb_sva.sv`): SVA protocol and APB assertions plus covergroups, bound in by the coverage flow. An assertion failure prints `SVA_FAIL` and fails the run even when the test itself passed.

Whole portfolio: `bash scripts/ci_regression.sh` runs steps 1 to 3 for every IP (what CI runs), and `bash scripts/cov/run_all.sh 4` runs step 4 for every IP.

## Verification

Five-metric coverage with Verilator 5.052 (`scripts/cov/run_cov.sh`); see [COVERAGE_CLOSURE.md](../COVERAGE_CLOSURE.md) for the flow. Line and toggle count only the named RTL file.

| Scope | Test | Line | Toggle | FSM | SVA | Functional |
|---|---|---|---|---|---|---|
| core `rtl/Avalon_MM_top.sv` | pass | 51/51 (+1 excl.) | 338/338 | 7/7 | 15/15 | 59/59 |
| wrapper `rtl/Avalon_MM_apb.sv` | pass | 19/19 | 616/616 | n/a | 7/7 | 23/23 |
