# TileLink TL-UL agent: a 64-word memory on the A and D channels, PutFullData, PutPartialData and Get with source echo, a request accepted in the clock its response leaves

Protocol IP `TileLink__TL_UL_TL_C_`, version 2.0. Apache-2.0.

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

### Fields

| Register | Bits | Field | Description |
|---|---|---|---|
| ID | 31:16 | CODE | 0x544C |
| ID | 15:8 | MAJOR | 2 |
| ID | 7:0 | MINOR | 0 |

### Interrupts (IRQ_STATUS, IRQ_ENABLE)

A bit is set while its source is active, stays set until written with 1, and a set in the same clock as the clear wins.

| Bit | Name | Set when |
|---|---|---|
| 0 | ERR | a request was answered with d_error: an opcode other than PutFullData / PutPartialData / Get, a size other than 4 bytes, a misaligned or out-of-range address (0x100 and up), a mask not matching the opcode, or a non-zero param; the core holds this until reset, so the bit cannot be cleared before then |

## Verification

Five-metric coverage with Verilator 5.052 (`scripts/cov/run_cov.sh`); see [COVERAGE_CLOSURE.md](../COVERAGE_CLOSURE.md) for the flow. Line and toggle count only the named RTL file.

| Scope | Test | Line | Toggle | FSM | SVA | Functional |
|---|---|---|---|---|---|---|
| core `rtl/TileLink__TL_UL_TL_C__top.sv` | pass | 22/22 | 386/386 (+4 excl.) | 4/4 | 7/7 | 23/23 |
| wrapper `rtl/TileLink__TL_UL_TL_C__apb.sv` | pass | 19/19 | 664/664 (+4 excl.) | n/a | 7/7 | 23/23 |
