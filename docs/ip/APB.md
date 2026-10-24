# AMBA APB completer: a 256-word memory with a wait-state region and a PSLVERR region

Protocol IP `APB`, version 2.0. Apache-2.0.

| Item | Value |
|---|---|
| Core | `APB_top` (`rtl/APB_top.sv`) |
| Register interface | APB4 slave `APB_apb`, 32-bit data, 12-bit byte address, zero wait states |
| Clock, reset | PCLK (rising edge), PRESETN (active low, asynchronous) |
| ID register | 0x41500200 (code 0x4150, version 2.0) |
| Registers | 5 words, 0x000 to 0x010 |
| Interrupts | 1 sources into one level-high `irq` |
| Protocol pins | 8 pass-through |

## Overview

APB3 slave -- real two-phase IDLE/SETUP/ACCESS protocol, pready wait states (slow region), pslverr on reserved region, 256x32 register file Address map (byte addresses): 0x000-0x3FF : fast region, zero wait state   (256 x 32 register file) 0x400-0x7FF : slow region, one wait state    (same register file) 0x800+      : reserved  -> pslverr at completion + irq event

psel, penable, paddr, pwrite, pwdata, prdata, pready and pslverr are the completer pins of the IP's own APB port (the subject of the IP, separate from the register port); they pass through unchanged. The registers report the completer's error events.
Address map seen on the IP's port (paddr[11:10]): 00 memory, no wait state; 01 the same memory with one wait state; 1x reserved, PSLVERR (writes ignored, reads 0). paddr[9:2] selects the word; other bits are ignored.

## Files

| File | Content |
|---|---|
| `rtl/APB_top.sv` | protocol core |
| `rtl/APB_apb.sv` | APB4 register wrapper (generated) |
| `tb/APB_tb.sv` | core testbench |
| `tb/APB_apb_tb.sv`, `tb/apb/APB_apb_func.svh` | wrapper testbench (generated part + IP-specific part) |
| `tb/cov/APB_sva.sv`, `tb/cov/APB_apb_sva.sv` | coverage checkers (core, wrapper) |
| `scripts/apb/specs/APB.json` | register spec the wrapper, TB, checker and this page are generated from |

```
make -f Makefile.APB sim syn            # core test + synthesis (Icarus, Yosys)
make -f Makefile.APB apb                # wrapper test + synthesis
bash scripts/cov/run_cov.sh APB          # core coverage (Verilator)
bash scripts/cov/run_cov.sh APB_apb      # wrapper coverage
```

## Parameters

`APB_apb` has the core's parameters and passes them to `APB_top` unchanged.

| Parameter | Type | Default |
|---|---|---|
| `DW` | int | `32` |
| `AW` | int | `32` |
| `DEPTH` | int | `256` |

## Wrapper pins

Pins of `APB_apb`. Widths of the pass-through pins are at the default parameters.

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
| `psel` | input | 1 | protocol pin, core port `psel` |
| `penable` | input | 1 | protocol pin, core port `penable` |
| `paddr` | input | 32 | protocol pin, core port `paddr` |
| `pwrite` | input | 1 | protocol pin, core port `pwrite` |
| `pwdata` | input | 32 | protocol pin, core port `pwdata` |
| `prdata` | output | 32 | protocol pin, core port `prdata` |
| `pready` | output | 1 | protocol pin, core port `pready` |
| `pslverr` | output | 1 | protocol pin, core port `pslverr` |

## Core ports

| Port | Dir | Width | In the APB wrapper |
|---|---|---|---|
| `clk` | input | 1 | PCLK |
| `rst_n` | input | 1 | PRESETN |
| `psel` | input | 1 | pin (pass-through) |
| `penable` | input | 1 | pin (pass-through) |
| `paddr` | input | 32 | pin (pass-through) |
| `pwrite` | input | 1 | pin (pass-through) |
| `pwdata` | input | 32 | pin (pass-through) |
| `prdata` | output | 32 | pin (pass-through) |
| `pready` | output | 1 | pin (pass-through) |
| `pslverr` | output | 1 | pin (pass-through) |
| `irq` | output | 1 | IRQ_STATUS.ERR |

## APB wrapper

`APB_apb` is an APB4 slave (AMBA APB protocol v2.0): zero wait states, 32-bit data, 12-bit byte address, PSTRB byte lanes on every writable register, PSLVERR on an unmapped or misaligned address (reads then return 0, writes are dropped). Writes to read-only registers are ignored without an error. The core runs on PCLK and PRESETN. `irq` is level-high: `|(IRQ_STATUS & IRQ_ENABLE)`.

Pass-through pins: `psel`, `penable`, `paddr`, `pwrite`, `pwdata`, `prdata`, `pready`, `pslverr`.

### Register map

| Offset | Name | Access | Reset | Description |
|---|---|---|---|---|
| 0x000 | ID | RO | 0x41500200 | IP identification: code, major and minor version |
| 0x004 | IRQ_STATUS | W1C | 0x00000000 | Sticky interrupt bits, write 1 to clear |
| 0x008 | IRQ_ENABLE | RW | 0x00000000 | Interrupt enables; irq = \|(IRQ_STATUS & IRQ_ENABLE) |
| 0x00C | FLAGS | RO | 0x00000000 | Stream holding-register state |
| 0x010 | SCRATCH | RW | 0x00000000 | Scratch register, no effect on the core |

Unlisted bits read 0 and ignore writes. Reset "core": the register reads the core's outputs directly, so after reset it shows the core's own reset state. WO (pulse) registers read 0. Offsets from 0x014 up to 0xFFC are unmapped (PSLVERR).

### Fields

| Register | Bits | Field | Access | Reset | Description |
|---|---|---|---|---|---|
| ID | 31:16 | CODE | RO | 0x4150 | IP code |
| ID | 15:8 | MAJOR | RO | 0x02 | major version |
| ID | 7:0 | MINOR | RO | 0x00 | minor version |
| IRQ_STATUS | 0 | one bit per interrupt | W1C | 0x0 | see Interrupts |
| IRQ_ENABLE | 0 | one bit per interrupt | RW | 0x0 | 1 enables the IRQ_STATUS bit onto `irq` |
| SCRATCH | 31:0 | SCRATCH | RW | 0x00000000 | free for software |

### Interrupts (IRQ_STATUS, IRQ_ENABLE)

A bit is set while its source is active, stays set until written with 1, and a set in the same clock as the clear wins.

| Bit | Name | Set when |
|---|---|---|
| 0 | ERR | a transfer to the reserved region (paddr[11] set) completed with PSLVERR |

## Programming sequence

1. Release PRESETN. Read ID (0x000) and check it is 0x41500200.
2. Write 0x1 to IRQ_STATUS (0x004) to clear any stale bits.
3. Write IRQ_ENABLE (0x008) with the interrupts to use (bit order as in the Interrupts table; 0x1 enables all).
4. On `irq`: read IRQ_STATUS, handle every bit that is set and enabled, then write those bits back to IRQ_STATUS to clear them. A source that is still active sets its bit again.

## Verification

Five-metric coverage with Verilator 5.052 (`scripts/cov/run_cov.sh`); see [COVERAGE_CLOSURE.md](../COVERAGE_CLOSURE.md) for the flow. Line and toggle count only the named RTL file.

| Scope | Test | Line | Toggle | FSM | SVA | Functional |
|---|---|---|---|---|---|---|
| core `rtl/APB_top.sv` | pass | 21/21 | 288/288 | 6/6 | 14/14 | 45/45 |
| wrapper `rtl/APB_apb.sv` | pass | 19/19 | 594/594 | n/a | 7/7 | 23/23 |
