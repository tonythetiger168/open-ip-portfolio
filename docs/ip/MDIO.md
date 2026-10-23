# MDIO PHY management target (IEEE 802.3 Clause 22) at PHY address 0x0C: 32 registers written and read over MDC / MDIO, register 0 preset to 0x1140

Protocol IP `MDIO`, version 2.0. Apache-2.0.

## Overview

MDIO slave (IEEE 802.3 Clause 22 PHY management) ST(01) + OP(2) + PHYAD(5) + REGAD(5) + TA(2) + DATA(16), MSB first. Open-drain MDIO. A frame starts on ST (0 then 1) only after at least one idle/preamble 1 (preamble suppression down to one bit is accepted), so the tail of one frame can never be mistaken for the start of the next. Reads: the PHY drives the second turnaround bit low, then DATA[15:0].


mdio (open drain: the target pulls it low for the turnaround and read data) and mdc are the management pins; they pass through unchanged. The PHY registers are reached only over MDIO; the APB registers report frame completion. MDC is sampled on PCLK, so each MDC phase must last at least three PCLK clocks.
A frame starts at ST (0 then 1) after at least one idle 1 (preamble suppression is accepted). Writes to another PHY address are ignored and reads of another address are not answered.

## Files

| File | Content |
|---|---|
| `rtl/MDIO_top.sv` | protocol core |
| `rtl/MDIO_apb.sv` | APB4 register wrapper (generated) |
| `tb/MDIO_tb.sv` | core testbench |
| `tb/MDIO_apb_tb.sv`, `tb/apb/MDIO_apb_func.svh` | wrapper testbench (generated part + IP-specific part) |
| `tb/cov/MDIO_sva.sv`, `tb/cov/MDIO_apb_sva.sv` | coverage checkers (core, wrapper) |
| `scripts/apb/specs/MDIO.json` | register spec the wrapper, TB, checker and this page are generated from |

```
make -f Makefile.MDIO sim syn            # core test + synthesis (Icarus, Yosys)
make -f Makefile.MDIO apb                # wrapper test + synthesis
bash scripts/cov/run_cov.sh MDIO          # core coverage (Verilator)
bash scripts/cov/run_cov.sh MDIO_apb      # wrapper coverage
```

## Core ports

| Port | Dir | Width | In the APB wrapper |
|---|---|---|---|
| `clk` | input | 1 | PCLK |
| `rst_n` | input | 1 | PRESETN |
| `mdio` | inout | 1 | pin (pass-through) |
| `mdc` | input | 1 | pin (pass-through) |
| `irq` | output | 1 | IRQ_STATUS.FRAME |

## APB wrapper

`MDIO_apb` is an APB4 slave (AMBA APB protocol v2.0): zero wait states, 32-bit data, 12-bit byte address, PSTRB byte lanes on every writable register, PSLVERR on an unmapped or misaligned address (reads then return 0, writes are dropped). Writes to read-only registers are ignored without an error. The core runs on PCLK and PRESETN. `irq` is level-high: `|(IRQ_STATUS & IRQ_ENABLE)`.

Pass-through pins: `mdio`, `mdc`.

### Register map

| Offset | Name | Access | Reset | Description |
|---|---|---|---|---|
| 0x000 | ID | RO | 0x4D440200 | IP identification: code, major and minor version |
| 0x004 | IRQ_STATUS | W1C | 0x00000000 | Sticky interrupt bits, write 1 to clear |
| 0x008 | IRQ_ENABLE | RW | 0x00000000 | Interrupt enables; irq = \|(IRQ_STATUS & IRQ_ENABLE) |
| 0x00C | FLAGS | RO | 0x00000000 | Stream holding-register state |
| 0x010 | SCRATCH | RW | 0x00000000 | Scratch register, no effect on the core |

### Fields

| Register | Bits | Field | Description |
|---|---|---|---|
| ID | 31:16 | CODE | 0x4D44 |
| ID | 15:8 | MAJOR | 2 |
| ID | 7:0 | MINOR | 0 |

### Interrupts (IRQ_STATUS, IRQ_ENABLE)

A bit is set while its source is active, stays set until written with 1, and a set in the same clock as the clear wins.

| Bit | Name | Set when |
|---|---|---|
| 0 | FRAME | a management frame (to any PHY address) has been fully received |

## Verification

Five-metric coverage with Verilator 5.052 (`scripts/cov/run_cov.sh`); see [COVERAGE_CLOSURE.md](../COVERAGE_CLOSURE.md) for the flow. Line and toggle count only the named RTL file.

| Scope | Test | Line | Toggle | FSM | SVA | Functional |
|---|---|---|---|---|---|---|
| core `rtl/MDIO_top.sv` | pass | 25/25 | 140/140 | n/a | 5/5 | 15/15 |
| wrapper `rtl/MDIO_apb.sv` | pass | 19/19 | 396/396 | n/a | 7/7 | 23/23 |
