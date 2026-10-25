# HBM3 memory controller: pseudo-channel controller (128 page entries {channel haddr[10:8], pc haddr[14:11]}, row = haddr[31:18], storage = 256 columns per channel); per-entry refresh over all 128

Protocol IP `HBM3`, version 2.0. Apache-2.0.

| Item | Value |
|---|---|
| Core | `HBM3_top` (`rtl/HBM3_top.sv`) |
| Register interface | APB4 slave `HBM3_apb`, 32-bit data, 12-bit byte address, zero wait states |
| Clock, reset | PCLK (rising edge), PRESETN (active low, asynchronous) |
| ID register | 0x6D0B0200 (code 0x6D0B, version 2.0) |
| Registers | 9 words, 0x000 to 0x020 |
| Interrupts | 3 sources into one level-high `irq` |
| Data streams | CMD (to the core) |
| Protocol pins | 12 pass-through |

## Overview

HBM3 -- INDEPENDENT design IP #17/20. Architecture thesis: 16 pseudo-channels per channel: page entry = {ch haddr[10:8], pc haddr[14:11]} (128 entries), served by one shared engine (a single global ACT path for the whole pc space) with per-entry refresh rotating over all 128. The state arrays are indexed directly by the entry field. HBM3-class timings (CL=10). Contract identical.

ck_t, ck_c, cke, addr, ras_n, cas_n, we_n, dq and dqs are the DRAM pins and trace_valid, trace_cmd and trace_addr the command trace (one clock before each command on the pins); they pass through unchanged.
Address map and behaviour of the core: pseudo-channel controller (128 page entries {channel haddr[10:8], pc haddr[14:11]}, row = haddr[31:18], storage = 256 columns per channel); per-entry refresh over all 128.
The core's own verification (pin-level checker, 100% coverage) is tb/cov/HBM3_sva.sv with tb/HBM3_tb.sv; this wrapper test drives the core only through the registers.

## Files

| File | Content |
|---|---|
| `rtl/HBM3_top.sv` | protocol core |
| `rtl/HBM3_apb.sv` | APB4 register wrapper (generated) |
| `tb/HBM3_tb.sv` | core testbench |
| `tb/HBM3_apb_tb.sv`, `tb/apb/HBM3_apb_func.svh` | wrapper testbench (generated part + IP-specific part) |
| `tb/cov/HBM3_sva.sv`, `tb/cov/HBM3_apb_sva.sv` | coverage checkers (core, wrapper) |
| `scripts/apb/specs/HBM3.json` | register spec the wrapper, TB, checker and this page are generated from |

How to run the tests and the coverage flow: see [Running and verifying](#running-and-verifying).

## Parameters

`HBM3_apb` has the core's parameters and passes them to `HBM3_top` unchanged.

| Parameter | Type | Default |
|---|---|---|
| `NCH` | int | `8` |

## Wrapper pins

Pins of `HBM3_apb`. Widths of the pass-through pins are at the default parameters.

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
| `ck_t` | output | 1 | protocol pin, core port `ck_t` |
| `ck_c` | output | 1 | protocol pin, core port `ck_c` |
| `addr` | output | 17 | protocol pin, core port `addr` |
| `ras_n` | output | 1 | protocol pin, core port `ras_n` |
| `cas_n` | output | 1 | protocol pin, core port `cas_n` |
| `we_n` | output | 1 | protocol pin, core port `we_n` |
| `dq` | inout | 128 | protocol pin, core port `dq` |
| `dqs` | inout | 2 | protocol pin, core port `dqs` |
| `cke` | output | 1 | protocol pin, core port `cke` |
| `trace_valid` | output | 1 | protocol pin, core port `trace_valid` |
| `trace_cmd` | output | 3 | protocol pin, core port `trace_cmd` |
| `trace_addr` | output | 32 | protocol pin, core port `trace_addr` |

## Core ports

| Port | Dir | Width | In the APB wrapper |
|---|---|---|---|
| `clk` | input | 1 | PCLK |
| `rst_n` | input | 1 | PRESETN |
| `hvalid` | input | 1 | CMD commit / FLAGS |
| `hready` | output | 1 | CMD handshake |
| `hcmd` | input | 3 | CMD0[2:0] |
| `haddr` | input | 32 | CMD1[31:0] |
| `hwdata` | input | 16 | CMD2[15:0] |
| `hrdata` | output | 16 | RDATA[15:0] |
| `hdone` | output | 1 | IRQ_STATUS.RD_DONE |
| `ck_t` | output | 1 | pin (pass-through) |
| `ck_c` | output | 1 | pin (pass-through) |
| `addr` | output | 17 | pin (pass-through) |
| `ras_n` | output | 1 | pin (pass-through) |
| `cas_n` | output | 1 | pin (pass-through) |
| `we_n` | output | 1 | pin (pass-through) |
| `dq` | inout | 128 | pin (pass-through) |
| `dqs` | inout | 2 | pin (pass-through) |
| `cke` | output | 1 | pin (pass-through) |
| `trace_valid` | output | 1 | pin (pass-through) |
| `trace_cmd` | output | 3 | pin (pass-through) |
| `trace_addr` | output | 32 | pin (pass-through) |

## APB wrapper

`HBM3_apb` is an APB4 slave (AMBA APB protocol v2.0): zero wait states, 32-bit data, 12-bit byte address, PSTRB byte lanes on every writable register, PSLVERR on an unmapped or misaligned address (reads then return 0, writes are dropped). Writes to read-only registers are ignored without an error. The core runs on PCLK and PRESETN. `irq` is level-high: `|(IRQ_STATUS & IRQ_ENABLE)`.

Pass-through pins: `ck_t`, `ck_c`, `addr`, `ras_n`, `cas_n`, `we_n`, `dq`, `dqs`, `cke`, `trace_valid`, `trace_cmd`, `trace_addr`.

### Register map

| Offset | Name | Access | Reset | Description |
|---|---|---|---|---|
| 0x000 | ID | RO | 0x6D0B0200 | IP identification: code, major and minor version |
| 0x004 | IRQ_STATUS | W1C | 0x00000000 | Sticky interrupt bits, write 1 to clear |
| 0x008 | IRQ_ENABLE | RW | 0x00000000 | Interrupt enables; irq = \|(IRQ_STATUS & IRQ_ENABLE) |
| 0x00C | FLAGS | RO | 0x00000000 | Stream holding-register state |
| 0x010 | SCRATCH | RW | 0x00000000 | Scratch register, no effect on the core |
| 0x014 | CMD0 | RW | 0x00000000 | Host command; writing CMD2 sends it (the core takes it when it is idle and no refresh is due) |
| 0x018 | CMD1 | RW | 0x00000000 | Host command; writing CMD2 sends it (the core takes it when it is idle and no refresh is due) |
| 0x01C | CMD2 | RW | 0x00000000 | Host command; writing CMD2 sends it (the core takes it when it is idle and no refresh is due) |
| 0x020 | RDATA | RO | core | Read data |

Unlisted bits read 0 and ignore writes. Reset "core": the register reads the core's outputs directly, so after reset it shows the core's own reset state. WO (pulse) registers read 0. Offsets from 0x024 up to 0xFFC are unmapped (PSLVERR).

### Fields

| Register | Bits | Field | Access | Reset | Description |
|---|---|---|---|---|---|
| ID | 31:16 | CODE | RO | 0x6D0B | IP code |
| ID | 15:8 | MAJOR | RO | 0x02 | major version |
| ID | 7:0 | MINOR | RO | 0x00 | minor version |
| IRQ_STATUS | 2:0 | one bit per interrupt | W1C | 0x0 | see Interrupts |
| IRQ_ENABLE | 2:0 | one bit per interrupt | RW | 0x0 | 1 enables the IRQ_STATUS bit onto `irq` |
| FLAGS | 0 | one bit per stream flag | RO | 0x0 | see FLAGS |
| SCRATCH | 31:0 | SCRATCH | RW | 0x00000000 | free for software |
| CMD0 | 2:0 | `hcmd` | RW | 0x0 | 1 ACT, 2 RD, 3 WR, 4 PRE; other codes are no-ops |
| CMD1 | 31:0 | `haddr` | RW | 0x0 | host address (bank, row and column fields below) |
| CMD2 | 15:0 | `hwdata` | RW | 0x0 | word to write (WR) |
| RDATA | 15:0 | `hrdata` | RO | core | word of the last RD, valid once RD_DONE is set |

### Interrupts (IRQ_STATUS, IRQ_ENABLE)

A bit is set while its source is active, stays set until written with 1, and a set in the same clock as the clear wins.

| Bit | Name | Set when |
|---|---|---|
| 0 | RD_DONE | a RD finished; RDATA holds its word |
| 1 | CMD_DONE | CMD beat accepted by the core |
| 2 | CMD_OVF | write to CMD while full (dropped) |

### FLAGS

| Bit | Name | Meaning |
|---|---|---|
| 0 | CMD_FULL | CMD holds a beat the core has not taken |

### Streams

* **CMD** feeds `hcmd`, `haddr`, `hwdata`/`hvalid`. Writing CMD2 commits the beat: FLAGS.CMD_FULL is set and `hvalid` stays high until the core's `hready`; then CMD_DONE is set. A write while full is dropped and sets CMD_OVF.

## Programming sequence

1. Release PRESETN. Read ID (0x000) and check it is 0x6D0B0200.
2. Write 0x7 to IRQ_STATUS (0x004) to clear any stale bits.
3. Write IRQ_ENABLE (0x008) with the interrupts to use (bit order as in the Interrupts table; 0x7 enables all).
4. To send on CMD: wait until FLAGS.CMD_FULL (bit 0) is 0, or for IRQ CMD_DONE, then write CMD0 (0x014) then CMD1 (0x018) then CMD2 (0x01C). The last write commits the beat. CMD_OVF means a write came while the register was full and was dropped.
5. Read RDATA (0x020) for the core's live `hrdata`; it needs no clearing.
6. On `irq`: read IRQ_STATUS, handle every bit that is set and enabled, then write those bits back to IRQ_STATUS to clear them. A source that is still active sets its bit again.

## Running and verifying

All commands run from the repository root. Icarus Verilog 12 and Yosys 0.33 are enough for steps 1 to 3; step 4 also needs Verilator 5.052 and pyslang (see [README, Setup](../../README.md#setup)).

| Step | Command | Pass when | Output |
|---|---|---|---|
| 1. Core test | `make -f Makefile.HBM3 sim` | a `TEST PASSED` line, no `ERROR` | console |
| 2. Core synthesis | `make -f Makefile.HBM3 syn` | Yosys ends without `ERROR`; `stat` prints the cell count | `work/HBM3_top.json` |
| 3. APB wrapper test + synthesis | `make -f Makefile.HBM3 apb` | `TEST PASSED: HBM3_apb`, then Yosys without `ERROR` | console, `work/HBM3_apb.json` |
| 4. Coverage (core, wrapper) | `bash scripts/cov/run_cov.sh HBM3`<br>`bash scripts/cov/run_cov.sh HBM3_apb` | `RESULT: CLOSED` (all five metrics 100%) | `work/cov/HBM3/score.json`, `work/cov/HBM3_apb/score.json` |

Expected end of a step 4 run:

```
===== HBM3 =====
TEST: PASSED   SVA_FAILURES: 0
LINE ... TOGGLE ... FSM ... SVA ... FUNCTIONAL  (each n/n, 100.0%)
RESULT: CLOSED
```

**Core test** (`tb/HBM3_tb.sv`): drives `HBM3_top` through its own ports against a protocol peer or model and checks every result itself; any mismatch prints `ERROR`, and `TEST PASSED` is printed only when there were none.

**APB wrapper test** (`tb/HBM3_apb_tb.sv`), in this order:

1. Reset values of every register, ID included.
2. Writes to read-only registers are ignored.
3. Each RW register: all ones, all zeros, then 16 random writes with every PSTRB byte-lane pattern, read back each time.
4. Unmapped and misaligned addresses, reads and writes: PSLVERR, read data 0, no side effect on other registers.
5. Back-to-back transfers with no idle cycle.
6. IP traffic through the registers only (`tb/apb/HBM3_apb_func.svh`): the programming sequence above, every interrupt bit set, enabled and cleared, stream FULL/AVAIL/OVF cases (100% wrapper toggle coverage confirms each bit moved).
7. PRESETN asserted mid-run: `irq` and PRDATA go to 0, registers return to reset values.

**Checkers** (`tb/cov/HBM3_sva.sv`, `tb/cov/HBM3_apb_sva.sv`): SVA protocol and APB assertions plus covergroups, bound in by the coverage flow. An assertion failure prints `SVA_FAIL` and fails the run even when the test itself passed.

Whole portfolio: `bash scripts/ci_regression.sh` runs steps 1 to 3 for every IP (what CI runs), and `bash scripts/cov/run_all.sh 4` runs step 4 for every IP.

## Verification

Five-metric coverage with Verilator 5.052 (`scripts/cov/run_cov.sh`); see [COVERAGE_CLOSURE.md](../COVERAGE_CLOSURE.md) for the flow. Line and toggle count only the named RTL file.

| Scope | Test | Line | Toggle | FSM | SVA | Functional |
|---|---|---|---|---|---|---|
| core `rtl/HBM3_top.sv` | pass | 92/92 (+4 excl.) | 1586/1586 (+22 excl.) | 24/24 | 24/24 | 66/66 |
| wrapper `rtl/HBM3_apb.sv` | pass | 33/33 | 1034/1034 (+12 excl.) | n/a | 11/11 | 42/42 |
