# Quad SPI slave: standard mode (MOSI on io[0], MISO on io[1]) and quad mode (a nibble per SCLK on io[3:0], read or write)

Protocol IP `QSPI`, version 2.0. Apache-2.0.

## Overview

QSPI slave: standard (1-bit) and quad (4-bit) SPI mode 0, 8-bit frames OpenCores spi/quad-spi style: io[0]=MOSI/IO0, io[1]=MISO/IO1, io[3:2]=IO2/3


sclk, csn and io are the QSPI pins; they pass through unchanged. SCLK is sampled on clk: it must stay high and low at least two clocks each.

## Files

| File | Content |
|---|---|
| `rtl/QSPI_top.sv` | protocol core |
| `rtl/QSPI_apb.sv` | APB4 register wrapper (generated) |
| `tb/QSPI_tb.sv` | core testbench |
| `tb/QSPI_apb_tb.sv`, `tb/apb/QSPI_apb_func.svh` | wrapper testbench (generated part + IP-specific part) |
| `tb/cov/QSPI_sva.sv`, `tb/cov/QSPI_apb_sva.sv` | coverage checkers (core, wrapper) |
| `scripts/apb/specs/QSPI.json` | register spec the wrapper, TB, checker and this page are generated from |

```
make -f Makefile.QSPI sim syn            # core test + synthesis (Icarus, Yosys)
make -f Makefile.QSPI apb                # wrapper test + synthesis
bash scripts/cov/run_cov.sh QSPI          # core coverage (Verilator)
bash scripts/cov/run_cov.sh QSPI_apb      # wrapper coverage
```

## Core ports

| Port | Dir | Width | In the APB wrapper |
|---|---|---|---|
| `clk` | input | 1 | PCLK |
| `rst_n` | input | 1 | PRESETN |
| `sclk` | input | 1 | pin (pass-through) |
| `csn` | input | 1 | pin (pass-through) |
| `io` | inout | 4 | pin (pass-through) |
| `wen` | input | 1 | write to a CORE word |
| `waddr` | input | 4 | CORE word index |
| `wdata` | input | 8 | CORE write data |
| `ren` | input | 1 | read of a CORE word |
| `raddr` | input | 4 | CORE word index |
| `rdata` | output | 8 | CORE read data |
| `irq` | output | 1 | IRQ_STATUS.BYTE |

## APB wrapper

`QSPI_apb` is an APB4 slave (AMBA APB protocol v2.0): zero wait states, 32-bit data, 12-bit byte address, PSTRB byte lanes on every writable register, PSLVERR on an unmapped or misaligned address (reads then return 0, writes are dropped). Writes to read-only registers are ignored without an error. The core runs on PCLK and PRESETN. `irq` is level-high: `|(IRQ_STATUS & IRQ_ENABLE)`.

Pass-through pins: `sclk`, `csn`, `io`.

### Register map

| Offset | Name | Access | Reset | Description |
|---|---|---|---|---|
| 0x000 | ID | RO | 0x51530200 | IP identification: code, major and minor version |
| 0x004 | IRQ_STATUS | W1C | 0x00000000 | Sticky interrupt bits, write 1 to clear |
| 0x008 | IRQ_ENABLE | RW | 0x00000000 | Interrupt enables; irq = \|(IRQ_STATUS & IRQ_ENABLE) |
| 0x00C | FLAGS | RO | 0x00000000 | Stream holding-register state |
| 0x010 | SCRATCH | RW | 0x00000000 | Scratch register, no effect on the core |
| 0x014 | TX | RW (core) | 0x00000000 | Byte shifted out (MISO in standard mode, io[3:0] in a quad read) |
| 0x018 | RX | RO (core) | 0x00000000 | Last byte shifted in |
| 0x01C | MODE | WO (core) | 0x00000000 | Bits 1:0: 0 standard, otherwise quad (write-only) |
| 0x020 | DIR | WO (core) | 0x00000000 | Bit 0, quad mode: 0 the slave drives io[3:0] (read), 1 it releases them (write) (write-only) |

### Fields

| Register | Bits | Field | Description |
|---|---|---|---|
| ID | 31:16 | CODE | 0x5153 |
| ID | 15:8 | MAJOR | 2 |
| ID | 7:0 | MINOR | 0 |
| TX | 7:0 | core register | written at core register 0 and read from core register 1 |
| RX | 7:0 | core register | read from core register 0 |
| MODE | 7:0 | core register | written at core register 2 |
| DIR | 7:0 | core register | written at core register 3 |

### Interrupts (IRQ_STATUS, IRQ_ENABLE)

A bit is set while its source is active, stays set until written with 1, and a set in the same clock as the clear wins.

| Bit | Name | Set when |
|---|---|---|
| 0 | BYTE | a byte was received (eight standard or two quad SCLK rising edges) |

### Core register port

The CORE words reach the core's own register port. A write to one pulses `wen` for one clock with `waddr` (the core register) and `wdata` (PWDATA's low bits); it must cover the whole word (PSTRB = 4'hF): a partial write is dropped with PSLVERR. A read drives `raddr` (the core register) and pulses `ren` during the access phase and returns `rdata`.

## Verification

Five-metric coverage with Verilator 5.052 (`scripts/cov/run_cov.sh`); see [COVERAGE_CLOSURE.md](../COVERAGE_CLOSURE.md) for the flow. Line and toggle count only the named RTL file.

| Scope | Test | Line | Toggle | FSM | SVA | Functional |
|---|---|---|---|---|---|---|
| core `rtl/QSPI_top.sv` | pass | 46/46 | 156/156 | n/a | 6/6 | 27/27 |
| wrapper `rtl/QSPI_apb.sv` | not run | | | | | |
