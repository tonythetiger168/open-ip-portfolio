# SPI slave (mode 0, MSB first): a byte shifted in on MOSI while the TX byte shifts out on MISO

Protocol IP `SPI`, version 2.0. Apache-2.0.

## Overview

SPI slave, mode 0 (CPOL=0 CPHA=0), 8-bit frames, byte IRQ


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

```
make -f Makefile.SPI sim syn            # core test + synthesis (Icarus, Yosys)
make -f Makefile.SPI apb                # wrapper test + synthesis
bash scripts/cov/run_cov.sh SPI          # core coverage (Verilator)
bash scripts/cov/run_cov.sh SPI_apb      # wrapper coverage
```

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
| 0x014 | TX | RW (core) | 0x00000000 | Byte shifted out on MISO in the next transfer |
| 0x018 | RX | RO (core) | 0x00000000 | Last byte shifted in on MOSI |

### Fields

| Register | Bits | Field | Description |
|---|---|---|---|
| ID | 31:16 | CODE | 0x5350 |
| ID | 15:8 | MAJOR | 2 |
| ID | 7:0 | MINOR | 0 |
| TX | 7:0 | core register | written at core register 0 and read from core register 1 |
| RX | 7:0 | core register | read from core register 0 |

### Interrupts (IRQ_STATUS, IRQ_ENABLE)

A bit is set while its source is active, stays set until written with 1, and a set in the same clock as the clear wins.

| Bit | Name | Set when |
|---|---|---|
| 0 | BYTE | a byte was received (eighth SCLK rising edge) |

### Core register port

The CORE words reach the core's own register port. A write to one pulses `wen` for one clock with `waddr` (the core register) and `wdata` (PWDATA's low bits); it must cover the whole word (PSTRB = 4'hF): a partial write is dropped with PSLVERR. A read drives `raddr` (the core register) and pulses `ren` during the access phase and returns `rdata`.

## Verification

Five-metric coverage with Verilator 5.052 (`scripts/cov/run_cov.sh`); see [COVERAGE_CLOSURE.md](../COVERAGE_CLOSURE.md) for the flow. Line and toggle count only the named RTL file.

| Scope | Test | Line | Toggle | FSM | SVA | Functional |
|---|---|---|---|---|---|---|
| core `rtl/SPI_top.sv` | pass | 15/15 | 108/108 | n/a | 5/5 | 15/15 |
| wrapper `rtl/SPI_apb.sv` | not run | | | | | |
