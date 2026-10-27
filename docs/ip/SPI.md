# SPI slave (mode 0, MSB first): a byte shifted in on MOSI while the TX byte shifts out on MISO

Protocol IP `SPI`, version 2.0. Apache-2.0.

| Item | Value |
|---|---|
| Core | `SPI_top` (`rtl/SPI_top.sv`) |
| Register interface | APB4 slave `SPI_apb`, 32-bit data, 12-bit byte address, zero wait states |
| Clock, reset | PCLK (rising edge), PRESETN (active low, asynchronous) |
| ID register | 0x53500200 (code 0x5350, version 2.0) |
| Registers | 7 words, 0x000 to 0x018 |
| Interrupts | 1 sources into one level-high `irq` |
| Core register port | CORE (2 words) |
| Protocol pins | 4 pass-through |

## Overview

SPI slave, mode 0 (CPOL=0 CPHA=0), 8-bit frames, byte IRQ

Features:

- SPI slave, mode 0 (CPOL = 0, CPHA = 0), MSB first, 8-bit frames.
- MOSI is sampled on each SCLK rising edge while CSn is low; MISO shifts out the TX byte, starting with bit 7.
- CSn high resets the bit counter, so each frame starts on a byte boundary.
- RX reads the receive shift register, which holds a complete byte when IRQ BYTE is set; TX is the byte sent in the next frame and reads back.
- Interrupt BYTE once per received byte.

sclk, mosi, miso and csn are the SPI pins; they pass through unchanged. SCLK is sampled on clk: it must stay high and low at least two clocks each.

## Files

| File | Content |
|---|---|
| `rtl/SPI_top.sv` | protocol core |
| `rtl/SPI_apb.sv` | APB4 register wrapper (generated) |
| `tb/SPI_tb.sv` | core testbench |
| `tb/SPI_apb_tb.sv`, `tb/apb/SPI_apb_func.svh` | wrapper testbench (generated part + IP-specific part) |
| `tb/cov/SPI_sva.sv`, `tb/cov/SPI_apb_sva.sv` | coverage checkers (core, wrapper) |
| `scripts/apb/specs/SPI.json` | register spec the wrapper, TB, checker and this page are generated from |

How to run the tests and the coverage flow: see [Running and verifying](#running-and-verifying).

## Parameters

The core and the wrapper have no parameters.

## Wrapper pins

Pins of `SPI_apb`. Widths of the pass-through pins are at the default parameters.

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
| `sclk` | input | 1 | protocol pin, core port `sclk` |
| `mosi` | input | 1 | protocol pin, core port `mosi` |
| `miso` | output | 1 | protocol pin, core port `miso` |
| `csn` | input | 1 | protocol pin, core port `csn` |

## Core ports

| Port | Dir | Width | In the APB wrapper |
|---|---|---|---|
| `clk` | input | 1 | PCLK |
| `rst_n` | input | 1 | PRESETN |
| `sclk` | input | 1 | pin (pass-through) |
| `mosi` | input | 1 | pin (pass-through) |
| `miso` | output | 1 | pin (pass-through) |
| `csn` | input | 1 | pin (pass-through) |
| `wen` | input | 1 | write to a CORE word |
| `waddr` | input | 4 | CORE word index |
| `wdata` | input | 8 | CORE write data |
| `ren` | input | 1 | read of a CORE word |
| `raddr` | input | 4 | CORE word index |
| `rdata` | output | 8 | CORE read data |
| `irq` | output | 1 | IRQ_STATUS.BYTE |

## APB wrapper

`SPI_apb` is an APB4 slave (AMBA APB protocol v2.0): zero wait states, 32-bit data, 12-bit byte address, PSTRB byte lanes on every writable register, PSLVERR on an unmapped or misaligned address (reads then return 0, writes are dropped). Writes to read-only registers are ignored without an error. The core runs on PCLK and PRESETN. `irq` is level-high: `|(IRQ_STATUS & IRQ_ENABLE)`.

Pass-through pins: `sclk`, `mosi`, `miso`, `csn`.

### Register map

| Offset | Name | Access | Reset | Description |
|---|---|---|---|---|
| 0x000 | ID | RO | 0x53500200 | IP identification: code, major and minor version |
| 0x004 | IRQ_STATUS | W1C | 0x00000000 | Sticky interrupt bits, write 1 to clear |
| 0x008 | IRQ_ENABLE | RW | 0x00000000 | Interrupt enables; irq = \|(IRQ_STATUS & IRQ_ENABLE) |
| 0x00C | FLAGS | RO | 0x00000000 | Stream holding-register state |
| 0x010 | SCRATCH | RW | 0x00000000 | Scratch register, no effect on the core |
| 0x014 | TX | RW (core) | core | Byte shifted out on MISO in the next transfer |
| 0x018 | RX | RO (core) | core | Last byte shifted in on MOSI |

Unlisted bits read 0 and ignore writes. Reset "core": the register reads the core's outputs directly, so after reset it shows the core's own reset state. WO (pulse) registers read 0. Offsets from 0x01C up to 0xFFC are unmapped (PSLVERR).

### Fields

| Register | Bits | Field | Access | Reset | Description |
|---|---|---|---|---|---|
| ID | 31:16 | CODE | RO | 0x5350 | IP code |
| ID | 15:8 | MAJOR | RO | 0x02 | major version |
| ID | 7:0 | MINOR | RO | 0x00 | minor version |
| IRQ_STATUS | 0 | one bit per interrupt | W1C | 0x0 | see Interrupts |
| IRQ_ENABLE | 0 | one bit per interrupt | RW | 0x0 | 1 enables the IRQ_STATUS bit onto `irq` |
| SCRATCH | 31:0 | SCRATCH | RW | 0x00000000 | free for software |
| TX | 7:0 | core register | RW (core) | core | written at core register 0 and read from core register 1 |
| RX | 7:0 | core register | RO (core) | core | read from core register 0 |

### Interrupts (IRQ_STATUS, IRQ_ENABLE)

A bit is set while its source is active, stays set until written with 1, and a set in the same clock as the clear wins.

| Bit | Name | Set when |
|---|---|---|
| 0 | BYTE | a byte was received (eighth SCLK rising edge) |

### Core register port

The CORE words reach the core's own register port. A write to one pulses `wen` for one clock with `waddr` (the core register) and `wdata` (PWDATA's low bits); it must cover the whole word (PSTRB = 4'hF): a partial write is dropped with PSLVERR. A read drives `raddr` (the core register) and pulses `ren` during the access phase and returns `rdata`.

## Programming sequence

1. Release PRESETN. Read ID (0x000) and check it is 0x53500200.
2. Write 0x1 to IRQ_STATUS (0x004) to clear any stale bits.
3. Write IRQ_ENABLE (0x008) with the interrupts to use (bit order as in the Interrupts table; 0x1 enables all).
4. Access the core's registers through the CORE words (0x014 onward), one word per core register; write whole words (PSTRB = 0xF), a partial write is dropped with PSLVERR.
5. On `irq`: read IRQ_STATUS, handle every bit that is set and enabled, then write those bits back to IRQ_STATUS to clear them. A source that is still active sets its bit again.

## Running and verifying

All commands run from the repository root. Icarus Verilog 12 and Yosys 0.33 are enough for steps 1 to 3; step 4 also needs Verilator 5.052 and pyslang (see [README, Setup](../../README.md#setup)).

| Step | Command | Pass when | Output |
|---|---|---|---|
| 1. Core test | `make -f Makefile.SPI sim` | a `TEST PASSED` line, no `ERROR` | console |
| 2. Core synthesis | `make -f Makefile.SPI syn` | Yosys ends without `ERROR`; `stat` prints the cell count | `work/SPI_top.json` |
| 3. APB wrapper test + synthesis | `make -f Makefile.SPI apb` | `TEST PASSED: SPI_apb`, then Yosys without `ERROR` | console, `work/SPI_apb.json` |
| 4. Coverage (core, wrapper) | `bash scripts/cov/run_cov.sh SPI`<br>`bash scripts/cov/run_cov.sh SPI_apb` | `RESULT: CLOSED` (all five metrics 100%) | `work/cov/SPI/score.json`, `work/cov/SPI_apb/score.json` |

Expected end of a step 4 run:

```
===== SPI =====
TEST: PASSED   SVA_FAILURES: 0
LINE ... TOGGLE ... FSM ... SVA ... FUNCTIONAL  (each n/n, 100.0%)
RESULT: CLOSED
```

**Core test** (`tb/SPI_tb.sv`): drives `SPI_top` through its own ports against a protocol peer or model and checks every result itself; any mismatch prints `ERROR`, and `TEST PASSED` is printed only when there were none.

**APB wrapper test** (`tb/SPI_apb_tb.sv`), in this order:

1. Reset values of every register, ID included.
2. Writes to read-only registers are ignored.
3. Each RW register: all ones, all zeros, then 16 random writes with every PSTRB byte-lane pattern, read back each time.
4. Unmapped and misaligned addresses, reads and writes: PSLVERR, read data 0, no side effect on other registers.
5. Back-to-back transfers with no idle cycle.
6. IP traffic through the registers only (`tb/apb/SPI_apb_func.svh`): the programming sequence above, every interrupt bit set, enabled and cleared (100% wrapper toggle coverage confirms each bit moved).
7. PRESETN asserted mid-run: `irq` and PRDATA go to 0, registers return to reset values.

**Checkers** (`tb/cov/SPI_sva.sv`, `tb/cov/SPI_apb_sva.sv`): SVA protocol and APB assertions plus covergroups, bound in by the coverage flow. An assertion failure prints `SVA_FAIL` and fails the run even when the test itself passed.

Whole portfolio: `bash scripts/ci_regression.sh` runs steps 1 to 3 for every IP (what CI runs), and `bash scripts/cov/run_all.sh 4` runs step 4 for every IP.

## Verification

Five-metric coverage with Verilator 5.052 (`scripts/cov/run_cov.sh`); see [COVERAGE_CLOSURE.md](../COVERAGE_CLOSURE.md) for the flow. Line and toggle count only the named RTL file.

| Scope | Test | Line | Toggle | FSM | SVA | Functional |
|---|---|---|---|---|---|---|
| core `rtl/SPI_top.sv` | pass | 15/15 | 108/108 | n/a | 5/5 | 46/46 |
| wrapper `rtl/SPI_apb.sv` | pass | 21/21 | 440/440 | n/a | 11/11 | 28/28 |
