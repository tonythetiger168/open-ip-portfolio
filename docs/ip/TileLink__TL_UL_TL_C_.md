# TileLink TL-UL agent: a 64-word memory on the A and D channels, PutFullData, PutPartialData and Get with source echo, a request accepted in the clock its response leaves

Protocol IP `TileLink__TL_UL_TL_C_`, version 2.0. Apache-2.0.

| Item | Value |
|---|---|
| Core | `TileLink__TL_UL_TL_C__top` (`rtl/TileLink__TL_UL_TL_C__top.sv`) |
| Register interface | APB4 slave `TileLink__TL_UL_TL_C__apb`, 32-bit data, 12-bit byte address, zero wait states |
| Clock, reset | PCLK (rising edge), PRESETN (active low, asynchronous) |
| ID register | 0x544C0200 (code 0x544C, version 2.0) |
| Registers | 5 words, 0x000 to 0x010 |
| Interrupts | 1 sources into one level-high `irq` |
| Protocol pins | 16 pass-through |

## Overview

The A channel (a_valid ... a_data) and D channel (d_valid ... d_error) pins are the TL-UL agent pins; they pass through unchanged. The registers report the agent's error event.
One response is held at a time; a new request is accepted in the clock the held response is taken. TL-C (B, C and E channels) is not implemented. d_opcode bits 2:1 are always 0 (waived).

## Files

| File | Content |
|---|---|
| `rtl/TileLink__TL_UL_TL_C__top.sv` | protocol core |
| `rtl/TileLink__TL_UL_TL_C__apb.sv` | APB4 register wrapper (generated) |
| `tb/TileLink__TL_UL_TL_C__tb.sv` | core testbench |
| `tb/TileLink__TL_UL_TL_C__apb_tb.sv`, `tb/apb/TileLink__TL_UL_TL_C__apb_func.svh` | wrapper testbench (generated part + IP-specific part) |
| `tb/cov/TileLink__TL_UL_TL_C__sva.sv`, `tb/cov/TileLink__TL_UL_TL_C__apb_sva.sv` | coverage checkers (core, wrapper) |
| `scripts/apb/specs/TileLink__TL_UL_TL_C_.json` | register spec the wrapper, TB, checker and this page are generated from |

```
make -f Makefile.TileLink__TL_UL_TL_C_ sim syn            # core test + synthesis (Icarus, Yosys)
make -f Makefile.TileLink__TL_UL_TL_C_ apb                # wrapper test + synthesis
bash scripts/cov/run_cov.sh TileLink__TL_UL_TL_C_          # core coverage (Verilator)
bash scripts/cov/run_cov.sh TileLink__TL_UL_TL_C__apb      # wrapper coverage
```

## Parameters

`TileLink__TL_UL_TL_C__apb` has the core's parameters and passes them to `TileLink__TL_UL_TL_C__top` unchanged.

| Parameter | Type | Default |
|---|---|---|
| `DW` | int | `32` |
| `AW` | int | `32` |
| `DEPTH` | int | `64` |

## Wrapper pins

Pins of `TileLink__TL_UL_TL_C__apb`. Widths of the pass-through pins are at the default parameters.

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
| `a_valid` | input | 1 | protocol pin, core port `a_valid` |
| `a_ready` | output | 1 | protocol pin, core port `a_ready` |
| `a_opcode` | input | 3 | protocol pin, core port `a_opcode` |
| `a_param` | input | 3 | protocol pin, core port `a_param` |
| `a_size` | input | 3 | protocol pin, core port `a_size` |
| `a_source` | input | 8 | protocol pin, core port `a_source` |
| `a_address` | input | 32 | protocol pin, core port `a_address` |
| `a_mask` | input | 4 | protocol pin, core port `a_mask` |
| `a_data` | input | 32 | protocol pin, core port `a_data` |
| `d_valid` | output | 1 | protocol pin, core port `d_valid` |
| `d_ready` | input | 1 | protocol pin, core port `d_ready` |
| `d_opcode` | output | 3 | protocol pin, core port `d_opcode` |
| `d_size` | output | 3 | protocol pin, core port `d_size` |
| `d_source` | output | 8 | protocol pin, core port `d_source` |
| `d_data` | output | 32 | protocol pin, core port `d_data` |
| `d_error` | output | 1 | protocol pin, core port `d_error` |

## Core ports

| Port | Dir | Width | In the APB wrapper |
|---|---|---|---|
| `clk` | input | 1 | PCLK |
| `rst_n` | input | 1 | PRESETN |
| `a_valid` | input | 1 | pin (pass-through) |
| `a_ready` | output | 1 | pin (pass-through) |
| `a_opcode` | input | 3 | pin (pass-through) |
| `a_param` | input | 3 | pin (pass-through) |
| `a_size` | input | 3 | pin (pass-through) |
| `a_source` | input | 8 | pin (pass-through) |
| `a_address` | input | 32 | pin (pass-through) |
| `a_mask` | input | 4 | pin (pass-through) |
| `a_data` | input | 32 | pin (pass-through) |
| `d_valid` | output | 1 | pin (pass-through) |
| `d_ready` | input | 1 | pin (pass-through) |
| `d_opcode` | output | 3 | pin (pass-through) |
| `d_size` | output | 3 | pin (pass-through) |
| `d_source` | output | 8 | pin (pass-through) |
| `d_data` | output | 32 | pin (pass-through) |
| `d_error` | output | 1 | pin (pass-through) |
| `irq` | output | 1 | IRQ_STATUS.ERR |

## APB wrapper

`TileLink__TL_UL_TL_C__apb` is an APB4 slave (AMBA APB protocol v2.0): zero wait states, 32-bit data, 12-bit byte address, PSTRB byte lanes on every writable register, PSLVERR on an unmapped or misaligned address (reads then return 0, writes are dropped). Writes to read-only registers are ignored without an error. The core runs on PCLK and PRESETN. `irq` is level-high: `|(IRQ_STATUS & IRQ_ENABLE)`.

Pass-through pins: `a_valid`, `a_ready`, `a_opcode`, `a_param`, `a_size`, `a_source`, `a_address`, `a_mask`, `a_data`, `d_valid`, `d_ready`, `d_opcode`, `d_size`, `d_source`, `d_data`, `d_error`.

### Register map

| Offset | Name | Access | Reset | Description |
|---|---|---|---|---|
| 0x000 | ID | RO | 0x544C0200 | IP identification: code, major and minor version |
| 0x004 | IRQ_STATUS | W1C | 0x00000000 | Sticky interrupt bits, write 1 to clear |
| 0x008 | IRQ_ENABLE | RW | 0x00000000 | Interrupt enables; irq = \|(IRQ_STATUS & IRQ_ENABLE) |
| 0x00C | FLAGS | RO | 0x00000000 | Stream holding-register state |
| 0x010 | SCRATCH | RW | 0x00000000 | Scratch register, no effect on the core |

Unlisted bits read 0 and ignore writes. Reset "core": the register reads the core's outputs directly, so after reset it shows the core's own reset state. WO (pulse) registers read 0. Offsets from 0x014 up to 0xFFC are unmapped (PSLVERR).

### Fields

| Register | Bits | Field | Access | Reset | Description |
|---|---|---|---|---|---|
| ID | 31:16 | CODE | RO | 0x544C | IP code |
| ID | 15:8 | MAJOR | RO | 0x02 | major version |
| ID | 7:0 | MINOR | RO | 0x00 | minor version |
| IRQ_STATUS | 0 | one bit per interrupt | W1C | 0x0 | see Interrupts |
| IRQ_ENABLE | 0 | one bit per interrupt | RW | 0x0 | 1 enables the IRQ_STATUS bit onto `irq` |
| SCRATCH | 31:0 | SCRATCH | RW | 0x00000000 | free for software |

### Interrupts (IRQ_STATUS, IRQ_ENABLE)

A bit is set while its source is active, stays set until written with 1, and a set in the same clock as the clear wins.

| Bit | Name | Set when |
|---|---|---|
| 0 | ERR | a request was answered with d_error: an opcode other than PutFullData / PutPartialData / Get, a size other than 4 bytes, a misaligned or out-of-range address (0x100 and up), a mask not matching the opcode, or a non-zero param; the core holds this until reset, so the bit cannot be cleared before then |

## Programming sequence

1. Release PRESETN. Read ID (0x000) and check it is 0x544C0200.
2. Write 0x1 to IRQ_STATUS (0x004) to clear any stale bits.
3. Write IRQ_ENABLE (0x008) with the interrupts to use (bit order as in the Interrupts table; 0x1 enables all).
4. On `irq`: read IRQ_STATUS, handle every bit that is set and enabled, then write those bits back to IRQ_STATUS to clear them. A source that is still active sets its bit again.

## Verification

Five-metric coverage with Verilator 5.052 (`scripts/cov/run_cov.sh`); see [COVERAGE_CLOSURE.md](../COVERAGE_CLOSURE.md) for the flow. Line and toggle count only the named RTL file.

| Scope | Test | Line | Toggle | FSM | SVA | Functional |
|---|---|---|---|---|---|---|
| core `rtl/TileLink__TL_UL_TL_C__top.sv` | pass | 22/22 | 386/386 (+4 excl.) | 4/4 | 7/7 | 68/68 |
| wrapper `rtl/TileLink__TL_UL_TL_C__apb.sv` | pass | 19/19 | 664/664 (+4 excl.) | n/a | 7/7 | 23/23 |
