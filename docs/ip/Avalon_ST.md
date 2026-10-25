# Avalon-ST sink: a 16-beat capture buffer, read back through the registers

Protocol IP `Avalon_ST`, version 2.0. Apache-2.0.

| Item | Value |
|---|---|
| Core | `Avalon_ST_top` (`rtl/Avalon_ST_top.sv`) |
| Register interface | APB4 slave `Avalon_ST_apb`, 32-bit data, 12-bit byte address, zero wait states |
| Clock, reset | PCLK (rising edge), PRESETN (active low, asynchronous) |
| ID register | 0x41760200 (code 0x4176, version 2.0) |
| Registers | 22 words, 0x000 to 0x054 |
| Interrupts | 1 sources into one level-high `irq` |
| Core register port | CORE (16 words) |
| Protocol pins | 4 pass-through |

## Overview

Avalon-ST sink with 16-deep FIFO capture (valid/ready/data/eop)

Features:

- Avalon-ST sink: `av_valid` / `av_ready` handshake, `DW`-bit (default 32) data, end-of-packet `av_eop`.
- Captures up to `DEPTH` (16) beats into a buffer, entries 0 to 15 in order; `av_ready` drops when it is full.
- STATUS.count reports how many beats are stored; buffer entries D0 to D15 are read at any time without side effects.
- Interrupt LAST on every accepted beat with `av_eop`.

av_valid, av_ready, av_data and av_eop are the Avalon-ST sink pins; they pass through unchanged. Beats fill entries 0 to 15 in order; the buffer is emptied only by reset.

## Files

| File | Content |
|---|---|
| `rtl/Avalon_ST_top.sv` | protocol core |
| `rtl/Avalon_ST_apb.sv` | APB4 register wrapper (generated) |
| `tb/Avalon_ST_tb.sv` | core testbench |
| `tb/Avalon_ST_apb_tb.sv`, `tb/apb/Avalon_ST_apb_func.svh` | wrapper testbench (generated part + IP-specific part) |
| `tb/cov/Avalon_ST_sva.sv`, `tb/cov/Avalon_ST_apb_sva.sv` | coverage checkers (core, wrapper) |
| `scripts/apb/specs/Avalon_ST.json` | register spec the wrapper, TB, checker and this page are generated from |

How to run the tests and the coverage flow: see [Running and verifying](#running-and-verifying).

## Parameters

`Avalon_ST_apb` has the core's parameters and passes them to `Avalon_ST_top` unchanged.

| Parameter | Type | Default |
|---|---|---|
| `DW` | int | `32` |
| `DEPTH` | int | `16` |

## Wrapper pins

Pins of `Avalon_ST_apb`. Widths of the pass-through pins are at the default parameters.

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
| `PSLVERR` | output | 1 | error: unmapped or misaligned address, or partial write to a core register word |
| `irq` | output | 1 | interrupt, level high: \|(IRQ_STATUS & IRQ_ENABLE) |
| `av_valid` | input | 1 | protocol pin, core port `av_valid` |
| `av_ready` | output | 1 | protocol pin, core port `av_ready` |
| `av_data` | input | 32 | protocol pin, core port `av_data` |
| `av_eop` | input | 1 | protocol pin, core port `av_eop` |

## Core ports

| Port | Dir | Width | In the APB wrapper |
|---|---|---|---|
| `clk` | input | 1 | PCLK |
| `rst_n` | input | 1 | PRESETN |
| `av_valid` | input | 1 | pin (pass-through) |
| `av_ready` | output | 1 | pin (pass-through) |
| `av_data` | input | 32 | pin (pass-through) |
| `av_eop` | input | 1 | pin (pass-through) |
| `ren` | input | 1 | read of a CORE word |
| `raddr` | input | 4 | CORE word index |
| `rdata` | output | 32 | CORE read data |
| `count` | output | 5 | STATUS[4:0] |
| `irq` | output | 1 | IRQ_STATUS.LAST |

## APB wrapper

`Avalon_ST_apb` is an APB4 slave (AMBA APB protocol v2.0): zero wait states, 32-bit data, 12-bit byte address, PSTRB byte lanes on every writable register, PSLVERR on an unmapped or misaligned address (reads then return 0, writes are dropped). Writes to read-only registers are ignored without an error. The core runs on PCLK and PRESETN. `irq` is level-high: `|(IRQ_STATUS & IRQ_ENABLE)`.

Pass-through pins: `av_valid`, `av_ready`, `av_data`, `av_eop`.

### Register map

| Offset | Name | Access | Reset | Description |
|---|---|---|---|---|
| 0x000 | ID | RO | 0x41760200 | IP identification: code, major and minor version |
| 0x004 | IRQ_STATUS | W1C | 0x00000000 | Sticky interrupt bits, write 1 to clear |
| 0x008 | IRQ_ENABLE | RW | 0x00000000 | Interrupt enables; irq = \|(IRQ_STATUS & IRQ_ENABLE) |
| 0x00C | FLAGS | RO | 0x00000000 | Stream holding-register state |
| 0x010 | SCRATCH | RW | 0x00000000 | Scratch register, no effect on the core |
| 0x014 | STATUS | RO | core | Capture buffer state |
| 0x018 | D0 | RO (core) | core | Capture buffer entry 0 |
| 0x01C | D1 | RO (core) | core | Capture buffer entry 1 |
| 0x020 | D2 | RO (core) | core | Capture buffer entry 2 |
| 0x024 | D3 | RO (core) | core | Capture buffer entry 3 |
| 0x028 | D4 | RO (core) | core | Capture buffer entry 4 |
| 0x02C | D5 | RO (core) | core | Capture buffer entry 5 |
| 0x030 | D6 | RO (core) | core | Capture buffer entry 6 |
| 0x034 | D7 | RO (core) | core | Capture buffer entry 7 |
| 0x038 | D8 | RO (core) | core | Capture buffer entry 8 |
| 0x03C | D9 | RO (core) | core | Capture buffer entry 9 |
| 0x040 | D10 | RO (core) | core | Capture buffer entry 10 |
| 0x044 | D11 | RO (core) | core | Capture buffer entry 11 |
| 0x048 | D12 | RO (core) | core | Capture buffer entry 12 |
| 0x04C | D13 | RO (core) | core | Capture buffer entry 13 |
| 0x050 | D14 | RO (core) | core | Capture buffer entry 14 |
| 0x054 | D15 | RO (core) | core | Capture buffer entry 15 |

Unlisted bits read 0 and ignore writes. Reset "core": the register reads the core's outputs directly, so after reset it shows the core's own reset state. WO (pulse) registers read 0. Offsets from 0x058 up to 0xFFC are unmapped (PSLVERR).

### Fields

| Register | Bits | Field | Access | Reset | Description |
|---|---|---|---|---|---|
| ID | 31:16 | CODE | RO | 0x4176 | IP code |
| ID | 15:8 | MAJOR | RO | 0x02 | major version |
| ID | 7:0 | MINOR | RO | 0x00 | minor version |
| IRQ_STATUS | 0 | one bit per interrupt | W1C | 0x0 | see Interrupts |
| IRQ_ENABLE | 0 | one bit per interrupt | RW | 0x0 | 1 enables the IRQ_STATUS bit onto `irq` |
| SCRATCH | 31:0 | SCRATCH | RW | 0x00000000 | free for software |
| STATUS | 4:0 | `count` | RO | core | beats captured (16: full, av_ready low until reset) |
| D0 | 31:0 | core register | RO (core) | core | read from core register 0 |
| D1 | 31:0 | core register | RO (core) | core | read from core register 1 |
| D2 | 31:0 | core register | RO (core) | core | read from core register 2 |
| D3 | 31:0 | core register | RO (core) | core | read from core register 3 |
| D4 | 31:0 | core register | RO (core) | core | read from core register 4 |
| D5 | 31:0 | core register | RO (core) | core | read from core register 5 |
| D6 | 31:0 | core register | RO (core) | core | read from core register 6 |
| D7 | 31:0 | core register | RO (core) | core | read from core register 7 |
| D8 | 31:0 | core register | RO (core) | core | read from core register 8 |
| D9 | 31:0 | core register | RO (core) | core | read from core register 9 |
| D10 | 31:0 | core register | RO (core) | core | read from core register 10 |
| D11 | 31:0 | core register | RO (core) | core | read from core register 11 |
| D12 | 31:0 | core register | RO (core) | core | read from core register 12 |
| D13 | 31:0 | core register | RO (core) | core | read from core register 13 |
| D14 | 31:0 | core register | RO (core) | core | read from core register 14 |
| D15 | 31:0 | core register | RO (core) | core | read from core register 15 |

### Interrupts (IRQ_STATUS, IRQ_ENABLE)

A bit is set while its source is active, stays set until written with 1, and a set in the same clock as the clear wins.

| Bit | Name | Set when |
|---|---|---|
| 0 | LAST | a beat with av_eop was accepted |

### Core register port

The CORE words reach the core's own register port. A write to one pulses A read drives `raddr` (the core register) and pulses `ren` during the access phase and returns `rdata`.

## Programming sequence

1. Release PRESETN. Read ID (0x000) and check it is 0x41760200.
2. Write 0x1 to IRQ_STATUS (0x004) to clear any stale bits.
3. Write IRQ_ENABLE (0x008) with the interrupts to use (bit order as in the Interrupts table; 0x1 enables all).
4. Read STATUS (0x014) for the core's live `count`; it needs no clearing.
5. Access the core's registers through the CORE words (0x018 onward), one word per core register.
6. On `irq`: read IRQ_STATUS, handle every bit that is set and enabled, then write those bits back to IRQ_STATUS to clear them. A source that is still active sets its bit again.

## Running and verifying

All commands run from the repository root. Icarus Verilog 12 and Yosys 0.33 are enough for steps 1 to 3; step 4 also needs Verilator 5.052 and pyslang (see [README, Setup](../../README.md#setup)).

| Step | Command | Pass when | Output |
|---|---|---|---|
| 1. Core test | `make -f Makefile.Avalon_ST sim` | a `TEST PASSED` line, no `ERROR` | console |
| 2. Core synthesis | `make -f Makefile.Avalon_ST syn` | Yosys ends without `ERROR`; `stat` prints the cell count | `work/Avalon_ST_top.json` |
| 3. APB wrapper test + synthesis | `make -f Makefile.Avalon_ST apb` | `TEST PASSED: Avalon_ST_apb`, then Yosys without `ERROR` | console, `work/Avalon_ST_apb.json` |
| 4. Coverage (core, wrapper) | `bash scripts/cov/run_cov.sh Avalon_ST`<br>`bash scripts/cov/run_cov.sh Avalon_ST_apb` | `RESULT: CLOSED` (all five metrics 100%) | `work/cov/Avalon_ST/score.json`, `work/cov/Avalon_ST_apb/score.json` |

Expected end of a step 4 run:

```
===== Avalon_ST =====
TEST: PASSED   SVA_FAILURES: 0
LINE ... TOGGLE ... FSM ... SVA ... FUNCTIONAL  (each n/n, 100.0%)
RESULT: CLOSED
```

**Core test** (`tb/Avalon_ST_tb.sv`): drives `Avalon_ST_top` through its own ports against a protocol peer or model and checks every result itself; any mismatch prints `ERROR`, and `TEST PASSED` is printed only when there were none.

**APB wrapper test** (`tb/Avalon_ST_apb_tb.sv`), in this order:

1. Reset values of every register, ID included.
2. Writes to read-only registers are ignored.
3. Each RW register: all ones, all zeros, then 16 random writes with every PSTRB byte-lane pattern, read back each time.
4. Unmapped and misaligned addresses, reads and writes: PSLVERR, read data 0, no side effect on other registers.
5. Back-to-back transfers with no idle cycle.
6. IP traffic through the registers only (`tb/apb/Avalon_ST_apb_func.svh`): the programming sequence above, every interrupt bit set, enabled and cleared (100% wrapper toggle coverage confirms each bit moved).
7. PRESETN asserted mid-run: `irq` and PRDATA go to 0, registers return to reset values.

**Checkers** (`tb/cov/Avalon_ST_sva.sv`, `tb/cov/Avalon_ST_apb_sva.sv`): SVA protocol and APB assertions plus covergroups, bound in by the coverage flow. An assertion failure prints `SVA_FAIL` and fails the run even when the test itself passed.

Whole portfolio: `bash scripts/ci_regression.sh` runs steps 1 to 3 for every IP (what CI runs), and `bash scripts/cov/run_all.sh 4` runs step 4 for every IP.

## Verification

Five-metric coverage with Verilator 5.052 (`scripts/cov/run_cov.sh`); see [COVERAGE_CLOSURE.md](../COVERAGE_CLOSURE.md) for the flow. Line and toggle count only the named RTL file.

| Scope | Test | Line | Toggle | FSM | SVA | Functional |
|---|---|---|---|---|---|---|
| core `rtl/Avalon_ST_top.sv` | pass | 4/4 | 170/170 | n/a | 6/6 | 61/61 |
| wrapper `rtl/Avalon_ST_apb.sv` | pass | 36/36 | 572/572 | n/a | 9/9 | 57/57 |
