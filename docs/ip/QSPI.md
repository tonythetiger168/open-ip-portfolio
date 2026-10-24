# Quad SPI slave: standard mode (MOSI on io[0], MISO on io[1]) and quad mode (a nibble per SCLK on io[3:0], read or write)

Protocol IP `QSPI`, version 2.0. Apache-2.0.

| Item | Value |
|---|---|
| Core | `QSPI_top` (`rtl/QSPI_top.sv`) |
| Register interface | APB4 slave `QSPI_apb`, 32-bit data, 12-bit byte address, zero wait states |
| Clock, reset | PCLK (rising edge), PRESETN (active low, asynchronous) |
| ID register | 0x51530200 (code 0x5153, version 2.0) |
| Registers | 9 words, 0x000 to 0x020 |
| Interrupts | 1 sources into one level-high `irq` |
| Core register port | CORE (4 words) |
| Protocol pins | 3 pass-through |

## Overview

QSPI slave: standard (1-bit) and quad (4-bit) SPI mode 0, 8-bit frames OpenCores spi/quad-spi style: io[0]=MOSI/IO0, io[1]=MISO/IO1, io[3:2]=IO2/3

Features:

- QSPI slave, mode 0, MSB first, 8-bit frames, selectable with MODE: standard SPI (1 bit per clock) or quad (4 bits per clock).
- Standard mode: `io[0]` is MOSI and `io[1]` is MISO; `io[3:2]` are not driven.
- Quad mode: DIR selects the direction. DIR = 0 drives `io[3:0]` with the TX byte, high nibble first; DIR = 1 releases the pins and receives a byte as two nibbles.
- The first bit or nibble of a frame shows on the pins as soon as CSn falls, from the current TX value.
- CSn high resets the bit and nibble counters.
- Interrupt BYTE once per received byte.

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

## Parameters

The core and the wrapper have no parameters.

## Wrapper pins

Pins of `QSPI_apb`. Widths of the pass-through pins are at the default parameters.

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
| `csn` | input | 1 | protocol pin, core port `csn` |
| `io` | inout | 4 | protocol pin, core port `io` |

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
| 0x014 | TX | RW (core) | core | Byte shifted out (MISO in standard mode, io[3:0] in a quad read) |
| 0x018 | RX | RO (core) | core | Last byte shifted in |
| 0x01C | MODE | WO (core) | core | Bits 1:0: 0 standard, otherwise quad (write-only) |
| 0x020 | DIR | WO (core) | core | Bit 0, quad mode: 0 the slave drives io[3:0] (read), 1 it releases them (write) (write-only) |

Unlisted bits read 0 and ignore writes. Reset "core": the register reads the core's outputs directly, so after reset it shows the core's own reset state. WO (pulse) registers read 0. Offsets from 0x024 up to 0xFFC are unmapped (PSLVERR).

### Fields

| Register | Bits | Field | Access | Reset | Description |
|---|---|---|---|---|---|
| ID | 31:16 | CODE | RO | 0x5153 | IP code |
| ID | 15:8 | MAJOR | RO | 0x02 | major version |
| ID | 7:0 | MINOR | RO | 0x00 | minor version |
| IRQ_STATUS | 0 | one bit per interrupt | W1C | 0x0 | see Interrupts |
| IRQ_ENABLE | 0 | one bit per interrupt | RW | 0x0 | 1 enables the IRQ_STATUS bit onto `irq` |
| SCRATCH | 31:0 | SCRATCH | RW | 0x00000000 | free for software |
| TX | 7:0 | core register | RW (core) | core | written at core register 0 and read from core register 1 |
| RX | 7:0 | core register | RO (core) | core | read from core register 0 |
| MODE | 7:0 | core register | WO (core) | core | written at core register 2 |
| DIR | 7:0 | core register | WO (core) | core | written at core register 3 |

### Interrupts (IRQ_STATUS, IRQ_ENABLE)

A bit is set while its source is active, stays set until written with 1, and a set in the same clock as the clear wins.

| Bit | Name | Set when |
|---|---|---|
| 0 | BYTE | a byte was received (eight standard or two quad SCLK rising edges) |

### Core register port

The CORE words reach the core's own register port. A write to one pulses `wen` for one clock with `waddr` (the core register) and `wdata` (PWDATA's low bits); it must cover the whole word (PSTRB = 4'hF): a partial write is dropped with PSLVERR. A read drives `raddr` (the core register) and pulses `ren` during the access phase and returns `rdata`.

## Programming sequence

1. Release PRESETN. Read ID (0x000) and check it is 0x51530200.
2. Write 0x1 to IRQ_STATUS (0x004) to clear any stale bits.
3. Write IRQ_ENABLE (0x008) with the interrupts to use (bit order as in the Interrupts table; 0x1 enables all).
4. Access the core's registers through the CORE words (0x014 onward), one word per core register; write whole words (PSTRB = 0xF), a partial write is dropped with PSLVERR.
5. On `irq`: read IRQ_STATUS, handle every bit that is set and enabled, then write those bits back to IRQ_STATUS to clear them. A source that is still active sets its bit again.

## Verification

Five-metric coverage with Verilator 5.052 (`scripts/cov/run_cov.sh`); see [COVERAGE_CLOSURE.md](../COVERAGE_CLOSURE.md) for the flow. Line and toggle count only the named RTL file.

| Scope | Test | Line | Toggle | FSM | SVA | Functional |
|---|---|---|---|---|---|---|
| core `rtl/QSPI_top.sv` | pass | 46/46 | 156/156 | n/a | 6/6 | 60/60 |
| wrapper `rtl/QSPI_apb.sv` | pass | 21/21 | 448/448 | n/a | 11/11 | 32/32 |
