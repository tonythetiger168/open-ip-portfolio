# GPIO bank: 8 bidirectional pins with per-pin output enable and input readback

Protocol IP `GPIO`, version 2.0. Apache-2.0.

## Overview

GPIO bank: 8-bit bidirectional, per-bit output-enable, input readback


gpio is the pin bank; it passes through unchanged.

## Files

| File | Content |
|---|---|
| `rtl/GPIO_top.sv` | protocol core |
| `rtl/GPIO_apb.sv` | APB4 register wrapper (generated) |
| `tb/GPIO_tb.sv` | core testbench |
| `tb/GPIO_apb_tb.sv`, `tb/apb/GPIO_apb_func.svh` | wrapper testbench (generated part + IP-specific part) |
| `tb/cov/GPIO_sva.sv`, `tb/cov/GPIO_apb_sva.sv` | coverage checkers (core, wrapper) |
| `scripts/apb/specs/GPIO.json` | register spec the wrapper, TB, checker and this page are generated from |

```
make -f Makefile.GPIO sim syn            # core test + synthesis (Icarus, Yosys)
make -f Makefile.GPIO apb                # wrapper test + synthesis
bash scripts/cov/run_cov.sh GPIO          # core coverage (Verilator)
bash scripts/cov/run_cov.sh GPIO_apb      # wrapper coverage
```

## Core ports

| Port | Dir | Width | In the APB wrapper |
|---|---|---|---|
| `clk` | input | 1 | PCLK |
| `rst_n` | input | 1 | PRESETN |
| `wen` | input | 1 | write to a CORE word |
| `waddr` | input | 4 | CORE word index |
| `wdata` | input | 8 | CORE write data |
| `ren` | input | 1 | read of a CORE word |
| `raddr` | input | 4 | CORE word index |
| `rdata` | output | 8 | CORE read data |
| `gpio` | inout | 8 | pin (pass-through) |
| `gpio_oe` | input | 8 | OE[7:0] |
| `irq` | output | 1 | IRQ_STATUS.HIGH |

## APB wrapper

`GPIO_apb` is an APB4 slave (AMBA APB protocol v2.0): zero wait states, 32-bit data, 12-bit byte address, PSTRB byte lanes on every writable register, PSLVERR on an unmapped or misaligned address (reads then return 0, writes are dropped). Writes to read-only registers are ignored without an error. The core runs on PCLK and PRESETN. `irq` is level-high: `|(IRQ_STATUS & IRQ_ENABLE)`.

Pass-through pins: `gpio`.

### Register map

| Offset | Name | Access | Reset | Description |
|---|---|---|---|---|
| 0x000 | ID | RO | 0x47500200 | IP identification: code, major and minor version |
| 0x004 | IRQ_STATUS | W1C | 0x00000000 | Sticky interrupt bits, write 1 to clear |
| 0x008 | IRQ_ENABLE | RW | 0x00000000 | Interrupt enables; irq = \|(IRQ_STATUS & IRQ_ENABLE) |
| 0x00C | FLAGS | RO | 0x00000000 | Stream holding-register state |
| 0x010 | SCRATCH | RW | 0x00000000 | Scratch register, no effect on the core |
| 0x014 | OE | RW | 0x00000000 | Output enables |
| 0x018 | OUT | RW (core) | 0x00000000 | Output values (driven on pins whose OE bit is set) |
| 0x01C | IN | RO (core) | 0x00000000 | Pin levels, sampled one clock earlier |

### Fields

| Register | Bits | Field | Description |
|---|---|---|---|
| ID | 31:16 | CODE | 0x4750 |
| ID | 15:8 | MAJOR | 2 |
| ID | 7:0 | MINOR | 0 |
| OE | 7:0 | `gpio_oe` | 1: pin driven from OUT; 0: pin is an input |
| OUT | 7:0 | core register | written at core register 0 and read from core register 1 |
| IN | 7:0 | core register | read from core register 0 |

### Interrupts (IRQ_STATUS, IRQ_ENABLE)

A bit is set while its source is active, stays set until written with 1, and a set in the same clock as the clear wins.

| Bit | Name | Set when |
|---|---|---|
| 0 | HIGH | a pin was sampled high |

### Core register port

The CORE words reach the core's own register port. A write to one pulses `wen` for one clock with `waddr` (the core register) and `wdata` (PWDATA's low bits); it must cover the whole word (PSTRB = 4'hF): a partial write is dropped with PSLVERR. A read drives `raddr` (the core register) and pulses `ren` during the access phase and returns `rdata`.

## Verification

Five-metric coverage with Verilator 5.052 (`scripts/cov/run_cov.sh`); see [COVERAGE_CLOSURE.md](../COVERAGE_CLOSURE.md) for the flow. Line and toggle count only the named RTL file.

| Scope | Test | Line | Toggle | FSM | SVA | Functional |
|---|---|---|---|---|---|---|
| core `rtl/GPIO_top.sv` | pass | 11/11 | 122/122 | n/a | 4/4 | 12/12 |
| wrapper `rtl/GPIO_apb.sv` | pass | 24/24 | 482/482 | n/a | 12/12 | 30/30 |
