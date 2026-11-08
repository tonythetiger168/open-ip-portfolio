# SPI controller (master): modes 0..3, 8-bit frames MSB first, programmable SCLK, two chip selects

Protocol IP `SPI_Host`, version 1.0. Apache-2.0.

| Item | Value |
|---|---|
| Core | `SPI_Host_top` (`rtl/SPI_Host_top.sv`) |
| Register interface | APB4 slave `SPI_Host_apb`, 32-bit data, 12-bit byte address, zero wait states |
| Clock, reset | PCLK (rising edge), PRESETN (active low, asynchronous) |
| ID register | 0x5C520100 (code 0x5C52, version 1.0) |
| Registers | 11 words, 0x000 to 0x028 |
| Interrupts | 1 sources into one level-high `irq` |
| Protocol pins | 4 pass-through |

## Overview

SPI_Host: SPI controller (master), modes 0..3, 8-bit frames, MSB first The controller role that the SPI_top target does not cover (sensor, display panel, PMIC and NOR-flash control).

- start (ignored while busy) sends TX_DATA and receives RX_DATA in one
8-bit frame; DONE pulses when it ends.
- CPOL: SCLK idle level. CPHA 0: data changes on the trailing edge and is
sampled on the leading edge (the first bit is presented before the
first edge); CPHA 1: changes on the leading edge, sampled on the
trailing edge.
- Half an SCLK period is DIV + 1 clocks. Targets that sample on their own
clock (as SPI_top does) need at least 3.
- Chip select: csn[i] = !CS[i] (software keeps it asserted across frames
of one transaction); NCS selects.

Features:

- The controller role that the SPI_top target does not cover: sensor, panel, PMIC and flash control.
- CMD.start sends TX_DATA and receives RX_DATA in one frame; DONE when it ends.
- CPOL is the SCLK idle level; CPHA 0 samples on the leading edge, CPHA 1 on the trailing edge.
- Half an SCLK period is DIV + 1 clocks; CS[i] drives csn[i] low, held by software across the frames of a transaction.

sclk, mosi, miso and csn are the SPI pins; they pass through unchanged.

## Files

| File | Content |
|---|---|
| `rtl/SPI_Host_top.sv` | protocol core |
| `rtl/SPI_Host_apb.sv` | APB4 register wrapper (generated) |
| `tb/SPI_Host_tb.sv` | core testbench |
| `tb/SPI_Host_apb_tb.sv`, `tb/apb/SPI_Host_apb_func.svh` | wrapper testbench (generated part + IP-specific part) |
| `tb/cov/SPI_Host_sva.sv`, `tb/cov/SPI_Host_apb_sva.sv` | coverage checkers (core, wrapper) |
| `scripts/apb/specs/SPI_Host.json` | register spec the wrapper, TB, checker and this page are generated from |

How to run the tests and the coverage flow: see [Running and verifying](#running-and-verifying).

## Parameters

`SPI_Host_apb` has the core's parameters and passes them to `SPI_Host_top` unchanged.

| Parameter | Type | Default |
|---|---|---|
| `NCS` | int | `2` |

## Wrapper pins

Pins of `SPI_Host_apb`. Widths of the pass-through pins are at the default parameters.

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
| `sclk` | output | 1 | protocol pin, core port `sclk` |
| `mosi` | output | 1 | protocol pin, core port `mosi` |
| `miso` | input | 1 | protocol pin, core port `miso` |
| `csn` | output | 2 | protocol pin, core port `csn` |

## Core ports

| Port | Dir | Width | In the APB wrapper |
|---|---|---|---|
| `clk` | input | 1 | PCLK |
| `rst_n` | input | 1 | PRESETN |
| `sclk` | output | 1 | pin (pass-through) |
| `mosi` | output | 1 | pin (pass-through) |
| `miso` | input | 1 | pin (pass-through) |
| `csn` | output | 2 | pin (pass-through) |
| `div` | input | 16 | DIV[15:0] |
| `cpol` | input | 1 | CFG[0:0] |
| `cpha` | input | 1 | CFG[1:1] |
| `cs` | input | 2 | CFG[3:2] |
| `tx_data` | input | 8 | TX_DATA[7:0] |
| `start` | input | 1 | CMD |
| `rx_data` | output | 8 | RX_DATA[7:0] |
| `busy` | output | 1 | STATUS |
| `done` | output | 1 | IRQ_STATUS.DONE |

## APB wrapper

`SPI_Host_apb` is an APB4 slave (AMBA APB protocol v2.0): zero wait states, 32-bit data, 12-bit byte address, PSTRB byte lanes on every writable register, PSLVERR on an unmapped or misaligned address (reads then return 0, writes are dropped). Writes to read-only registers are ignored without an error. The core runs on PCLK and PRESETN. `irq` is level-high: `|(IRQ_STATUS & IRQ_ENABLE)`.

Pass-through pins: `sclk`, `mosi`, `miso`, `csn`.

### Register map

| Offset | Name | Access | Reset | Description |
|---|---|---|---|---|
| 0x000 | ID | RO | 0x5C520100 | IP identification: code, major and minor version |
| 0x004 | IRQ_STATUS | W1C | 0x00000000 | Sticky interrupt bits, write 1 to clear |
| 0x008 | IRQ_ENABLE | RW | 0x00000000 | Interrupt enables; irq = \|(IRQ_STATUS & IRQ_ENABLE) |
| 0x00C | FLAGS | RO | 0x00000000 | Stream holding-register state |
| 0x010 | SCRATCH | RW | 0x00000000 | Scratch register, no effect on the core |
| 0x014 | CFG | RW | 0x00000000 | Mode and chip selects |
| 0x018 | DIV | RW | 0x00000009 | SCLK timing |
| 0x01C | TX_DATA | RW | 0x00000000 | Byte sent by the next frame |
| 0x020 | CMD | WO (pulse) | 0x00000000 | Commands (write 1) |
| 0x024 | RX_DATA | RO | core | Byte received by the last frame |
| 0x028 | STATUS | RO | core | State |

Unlisted bits read 0 and ignore writes. Reset "core": the register reads the core's outputs directly, so after reset it shows the core's own reset state. WO (pulse) registers read 0. Offsets from 0x02C up to 0xFFC are unmapped (PSLVERR).

### Fields

| Register | Bits | Field | Access | Reset | Description |
|---|---|---|---|---|---|
| ID | 31:16 | CODE | RO | 0x5C52 | IP code |
| ID | 15:8 | MAJOR | RO | 0x01 | major version |
| ID | 7:0 | MINOR | RO | 0x00 | minor version |
| IRQ_STATUS | 0 | one bit per interrupt | W1C | 0x0 | see Interrupts |
| IRQ_ENABLE | 0 | one bit per interrupt | RW | 0x0 | 1 enables the IRQ_STATUS bit onto `irq` |
| SCRATCH | 31:0 | SCRATCH | RW | 0x00000000 | free for software |
| CFG | 0 | `cpol` | RW | 0x0 | SCLK idle level |
| CFG | 1 | `cpha` | RW | 0x0 | 0 sample on the leading edge, 1 on the trailing edge |
| CFG | 3:2 | `cs` | RW | 0x0 | csn[i] = !cs[i] |
| DIV | 15:0 | `div` | RW | 0x9 | half SCLK period - 1, in clocks |
| TX_DATA | 7:0 | `tx_data` | RW | 0x0 | MSB first |
| CMD | 0 | `start` | WO (pulse) | 0x0 | send one frame; ignored while busy |
| RX_DATA | 7:0 | `rx_data` | RO | core | MSB first |
| STATUS | 0 | `busy` | RO | core | a frame is running |

### Interrupts (IRQ_STATUS, IRQ_ENABLE)

A bit is set while its source is active, stays set until written with 1, and a set in the same clock as the clear wins.

| Bit | Name | Set when |
|---|---|---|
| 0 | DONE | a frame ended |

## Programming sequence

1. Release PRESETN. Read ID (0x000) and check it is 0x5C520100.
2. Write 0x1 to IRQ_STATUS (0x004) to clear any stale bits.
3. Configure the core: write CFG (0x014), DIV (0x018), TX_DATA (0x01C). Reset values are in the register map; PSTRB selects the bytes written.
4. Write IRQ_ENABLE (0x008) with the interrupts to use (bit order as in the Interrupts table; 0x1 enables all).
5. To issue a command, write 1 to `start` (CMD bit 0) at 0x020; the core sees a one-clock pulse, and the register reads 0.
6. Read RX_DATA (0x024) for the core's live `rx_data`; it needs no clearing.
7. Read STATUS (0x028) for the core's live `busy`; it needs no clearing.
8. On `irq`: read IRQ_STATUS, handle every bit that is set and enabled, then write those bits back to IRQ_STATUS to clear them. A source that is still active sets its bit again.

IP-specific use:

1. Write DIV and CFG (mode, then CS to select the target).
2. For each byte: TX_DATA, CMD.start, wait for DONE, read RX_DATA.
3. Write CFG.cs = 0 to end the transaction.

## Running and verifying

All commands run from the repository root. Icarus Verilog 12 and Yosys 0.33 are enough for steps 1 to 3; step 4 also needs Verilator 5.052 and pyslang (see [README, Setup](../../README.md#setup)).

| Step | Command | Pass when | Output |
|---|---|---|---|
| 1. Core test | `make -f Makefile.SPI_Host sim` | a `TEST PASSED` line, no `ERROR` | console |
| 2. Core synthesis | `make -f Makefile.SPI_Host syn` | Yosys ends without `ERROR`; `stat` prints the cell count | `work/SPI_Host_top.json` |
| 3. APB wrapper test + synthesis | `make -f Makefile.SPI_Host apb` | `TEST PASSED: SPI_Host_apb`, then Yosys without `ERROR` | console, `work/SPI_Host_apb.json` |
| 4. Coverage (core, wrapper) | `bash scripts/cov/run_cov.sh SPI_Host`<br>`bash scripts/cov/run_cov.sh SPI_Host_apb` | `RESULT: CLOSED` (all five metrics 100%) | `work/cov/SPI_Host/score.json`, `work/cov/SPI_Host_apb/score.json` |

Expected end of a step 4 run:

```
===== SPI_Host =====
TEST: PASSED   SVA_FAILURES: 0
LINE ... TOGGLE ... FSM ... SVA ... FUNCTIONAL  (each n/n, 100.0%)
RESULT: CLOSED
```

**Core test** (`tb/SPI_Host_tb.sv`): drives `SPI_Host_top` through its own ports against a protocol peer or model and checks every result itself; any mismatch prints `ERROR`, and `TEST PASSED` is printed only when there were none.

**APB wrapper test** (`tb/SPI_Host_apb_tb.sv`), in this order:

1. Reset values of every register, ID included.
2. Writes to read-only registers are ignored.
3. Each RW register: all ones, all zeros, then 16 random writes with every PSTRB byte-lane pattern, read back each time.
4. Unmapped and misaligned addresses, reads and writes: PSLVERR, read data 0, no side effect on other registers.
5. Back-to-back transfers with no idle cycle.
6. IP traffic through the registers only (`tb/apb/SPI_Host_apb_func.svh`): the programming sequence above, every interrupt bit set, enabled and cleared (100% wrapper toggle coverage confirms each bit moved).
7. PRESETN asserted mid-run: `irq` and PRDATA go to 0, registers return to reset values.

**Checkers** (`tb/cov/SPI_Host_sva.sv`, `tb/cov/SPI_Host_apb_sva.sv`): SVA protocol and APB assertions plus covergroups, bound in by the coverage flow. An assertion failure prints `SVA_FAIL` and fails the run even when the test itself passed.

Whole portfolio: `bash scripts/ci_regression.sh` runs steps 1 to 3 for every IP (what CI runs), and `bash scripts/cov/run_all.sh 4` runs step 4 for every IP.

## Verification

Five-metric coverage with Verilator 5.052 (`scripts/cov/run_cov.sh`); see [COVERAGE_CLOSURE.md](../COVERAGE_CLOSURE.md) for the flow. Line and toggle count only the named RTL file.

| Scope | Test | Line | Toggle | FSM | SVA | Functional |
|---|---|---|---|---|---|---|
| core `rtl/SPI_Host_top.sv` | not run | | | | | |
| wrapper `rtl/SPI_Host_apb.sv` | pass | 32/32 | 548/548 | n/a | 13/13 | 36/36 |
