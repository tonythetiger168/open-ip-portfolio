# GMII MAC-side interface: a TX byte FIFO into the tx_clk domain, an RX capture ring sampled from rx_clk

Protocol IP `GMII`, version 2.0. Apache-2.0.

| Item | Value |
|---|---|
| Core | `GMII_top` (`rtl/GMII_top.sv`) |
| Register interface | APB4 slave `GMII_apb`, 32-bit data, 12-bit byte address, zero wait states |
| Clock, reset | PCLK (rising edge), PRESETN (active low, asynchronous) |
| ID register | 0x474D0200 (code 0x474D, version 2.0) |
| Registers | 23 words, 0x000 to 0x058 |
| Interrupts | 1 sources into one level-high `irq` |
| Core register port | CORE (17 words) |
| Protocol pins | 8 pass-through |

## Overview

GMII MAC datapath: 8-bit SDR TX + RX with FIFOs TX: bytes from host FIFO -> txd/tx_en on tx_clk; RX: rxd/rx_dv -> FIFO Loopback-compatible. OpenCores ethernet/mac style.

txd, tx_en, tx_er, tx_clk, rxd, rx_dv, rx_er and rx_clk are the GMII pins; they pass through unchanged. rx_clk is sampled on clk (each phase at least two clocks); tx_clk is its own clock domain.

## Files

| File | Content |
|---|---|
| `rtl/GMII_top.sv` | protocol core |
| `rtl/GMII_apb.sv` | APB4 register wrapper (generated) |
| `tb/GMII_tb.sv` | core testbench |
| `tb/GMII_apb_tb.sv`, `tb/apb/GMII_apb_func.svh` | wrapper testbench (generated part + IP-specific part) |
| `tb/cov/GMII_sva.sv`, `tb/cov/GMII_apb_sva.sv` | coverage checkers (core, wrapper) |
| `scripts/apb/specs/GMII.json` | register spec the wrapper, TB, checker and this page are generated from |

```
make -f Makefile.GMII sim syn            # core test + synthesis (Icarus, Yosys)
make -f Makefile.GMII apb                # wrapper test + synthesis
bash scripts/cov/run_cov.sh GMII          # core coverage (Verilator)
bash scripts/cov/run_cov.sh GMII_apb      # wrapper coverage
```

## Parameters

`GMII_apb` has the core's parameters and passes them to `GMII_top` unchanged.

| Parameter | Type | Default |
|---|---|---|
| `DEPTH` | int | `16` |

## Wrapper pins

Pins of `GMII_apb`. Widths of the pass-through pins are at the default parameters.

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
| `tx_clk` | input | 1 | protocol pin, core port `tx_clk` |
| `txd` | output | 8 | protocol pin, core port `txd` |
| `tx_en` | output | 1 | protocol pin, core port `tx_en` |
| `tx_er` | output | 1 | protocol pin, core port `tx_er` |
| `rx_clk` | input | 1 | protocol pin, core port `rx_clk` |
| `rxd` | input | 8 | protocol pin, core port `rxd` |
| `rx_dv` | input | 1 | protocol pin, core port `rx_dv` |
| `rx_er` | input | 1 | protocol pin, core port `rx_er` |

## Core ports

| Port | Dir | Width | In the APB wrapper |
|---|---|---|---|
| `clk` | input | 1 | PCLK |
| `rst_n` | input | 1 | PRESETN |
| `tx_clk` | input | 1 | pin (pass-through) |
| `txd` | output | 8 | pin (pass-through) |
| `tx_en` | output | 1 | pin (pass-through) |
| `tx_er` | output | 1 | pin (pass-through) |
| `rx_clk` | input | 1 | pin (pass-through) |
| `rxd` | input | 8 | pin (pass-through) |
| `rx_dv` | input | 1 | pin (pass-through) |
| `rx_er` | input | 1 | pin (pass-through) |
| `wen` | input | 1 | write to a CORE word |
| `waddr` | input | 4 | CORE word index |
| `wdata` | input | 8 | CORE write data |
| `ren` | input | 1 | read of a CORE word |
| `raddr` | input | 4 | CORE word index |
| `rdata` | output | 8 | CORE read data |
| `count` | output | 5 | STATUS[4:0] |
| `irq` | output | 1 | IRQ_STATUS.READ |

## APB wrapper

`GMII_apb` is an APB4 slave (AMBA APB protocol v2.0): zero wait states, 32-bit data, 12-bit byte address, PSTRB byte lanes on every writable register, PSLVERR on an unmapped or misaligned address (reads then return 0, writes are dropped). Writes to read-only registers are ignored without an error. The core runs on PCLK and PRESETN. `irq` is level-high: `|(IRQ_STATUS & IRQ_ENABLE)`.

Pass-through pins: `tx_clk`, `txd`, `tx_en`, `tx_er`, `rx_clk`, `rxd`, `rx_dv`, `rx_er`.

### Register map

| Offset | Name | Access | Reset | Description |
|---|---|---|---|---|
| 0x000 | ID | RO | 0x474D0200 | IP identification: code, major and minor version |
| 0x004 | IRQ_STATUS | W1C | 0x00000000 | Sticky interrupt bits, write 1 to clear |
| 0x008 | IRQ_ENABLE | RW | 0x00000000 | Interrupt enables; irq = \|(IRQ_STATUS & IRQ_ENABLE) |
| 0x00C | FLAGS | RO | 0x00000000 | Stream holding-register state |
| 0x010 | SCRATCH | RW | 0x00000000 | Scratch register, no effect on the core |
| 0x014 | STATUS | RO | core | RX capture count |
| 0x018 | TX | WO (core) | core | Byte to send (dropped while the 8-entry TX FIFO is full) (write-only) |
| 0x01C | RX0 | RO (core) | core | RX capture ring entry 0 |
| 0x020 | RX1 | RO (core) | core | RX capture ring entry 1 |
| 0x024 | RX2 | RO (core) | core | RX capture ring entry 2 |
| 0x028 | RX3 | RO (core) | core | RX capture ring entry 3 |
| 0x02C | RX4 | RO (core) | core | RX capture ring entry 4 |
| 0x030 | RX5 | RO (core) | core | RX capture ring entry 5 |
| 0x034 | RX6 | RO (core) | core | RX capture ring entry 6 |
| 0x038 | RX7 | RO (core) | core | RX capture ring entry 7 |
| 0x03C | RX8 | RO (core) | core | RX capture ring entry 8 |
| 0x040 | RX9 | RO (core) | core | RX capture ring entry 9 |
| 0x044 | RX10 | RO (core) | core | RX capture ring entry 10 |
| 0x048 | RX11 | RO (core) | core | RX capture ring entry 11 |
| 0x04C | RX12 | RO (core) | core | RX capture ring entry 12 |
| 0x050 | RX13 | RO (core) | core | RX capture ring entry 13 |
| 0x054 | RX14 | RO (core) | core | RX capture ring entry 14 |
| 0x058 | RX15 | RO (core) | core | RX capture ring entry 15 |

Unlisted bits read 0 and ignore writes. Reset "core": the register reads the core's outputs directly, so after reset it shows the core's own reset state. WO (pulse) registers read 0. Offsets from 0x05C up to 0xFFC are unmapped (PSLVERR).

### Fields

| Register | Bits | Field | Access | Reset | Description |
|---|---|---|---|---|---|
| ID | 31:16 | CODE | RO | 0x474D | IP code |
| ID | 15:8 | MAJOR | RO | 0x02 | major version |
| ID | 7:0 | MINOR | RO | 0x00 | minor version |
| IRQ_STATUS | 0 | one bit per interrupt | W1C | 0x0 | see Interrupts |
| IRQ_ENABLE | 0 | one bit per interrupt | RW | 0x0 | 1 enables the IRQ_STATUS bit onto `irq` |
| SCRATCH | 31:0 | SCRATCH | RW | 0x00000000 | free for software |
| STATUS | 4:0 | `count` | RO | core | bytes captured (wraps at 32); entry count mod 16 is written next |
| TX | 7:0 | core register | WO (core) | core | written at core register 0 |
| RX0 | 7:0 | core register | RO (core) | core | read from core register 0 |
| RX1 | 7:0 | core register | RO (core) | core | read from core register 1 |
| RX2 | 7:0 | core register | RO (core) | core | read from core register 2 |
| RX3 | 7:0 | core register | RO (core) | core | read from core register 3 |
| RX4 | 7:0 | core register | RO (core) | core | read from core register 4 |
| RX5 | 7:0 | core register | RO (core) | core | read from core register 5 |
| RX6 | 7:0 | core register | RO (core) | core | read from core register 6 |
| RX7 | 7:0 | core register | RO (core) | core | read from core register 7 |
| RX8 | 7:0 | core register | RO (core) | core | read from core register 8 |
| RX9 | 7:0 | core register | RO (core) | core | read from core register 9 |
| RX10 | 7:0 | core register | RO (core) | core | read from core register 10 |
| RX11 | 7:0 | core register | RO (core) | core | read from core register 11 |
| RX12 | 7:0 | core register | RO (core) | core | read from core register 12 |
| RX13 | 7:0 | core register | RO (core) | core | read from core register 13 |
| RX14 | 7:0 | core register | RO (core) | core | read from core register 14 |
| RX15 | 7:0 | core register | RO (core) | core | read from core register 15 |

### Interrupts (IRQ_STATUS, IRQ_ENABLE)

A bit is set while its source is active, stays set until written with 1, and a set in the same clock as the clear wins.

| Bit | Name | Set when |
|---|---|---|
| 0 | READ | a ring entry was read after at least one byte was captured |

### Core register port

The CORE words reach the core's own register port. A write to one pulses `wen` for one clock with `waddr` (the core register) and `wdata` (PWDATA's low bits); it must cover the whole word (PSTRB = 4'hF): a partial write is dropped with PSLVERR. A read drives `raddr` (the core register) and pulses `ren` during the access phase and returns `rdata`.

## Programming sequence

1. Release PRESETN. Read ID (0x000) and check it is 0x474D0200.
2. Write 0x1 to IRQ_STATUS (0x004) to clear any stale bits.
3. Write IRQ_ENABLE (0x008) with the interrupts to use (bit order as in the Interrupts table; 0x1 enables all).
4. Read STATUS (0x014) for the core's live `count`; it needs no clearing.
5. Access the core's registers through the CORE words (0x018 onward), one word per core register; write whole words (PSTRB = 0xF), a partial write is dropped with PSLVERR.
6. On `irq`: read IRQ_STATUS, handle every bit that is set and enabled, then write those bits back to IRQ_STATUS to clear them. A source that is still active sets its bit again.

## Verification

Five-metric coverage with Verilator 5.052 (`scripts/cov/run_cov.sh`); see [COVERAGE_CLOSURE.md](../COVERAGE_CLOSURE.md) for the flow. Line and toggle count only the named RTL file.

| Scope | Test | Line | Toggle | FSM | SVA | Functional |
|---|---|---|---|---|---|---|
| core `rtl/GMII_top.sv` | pass | 17/17 | 616/616 (+2 excl.) | n/a | 7/7 | 56/56 |
| wrapper `rtl/GMII_apb.sv` | pass | 36/36 | 518/518 (+2 excl.) | n/a | 11/11 | 60/60 |
