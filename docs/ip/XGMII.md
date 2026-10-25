# XGMII MAC-side interface: TX bytes packed into 32-bit columns through a FIFO into the tx_clk domain, an RX capture ring of the data lanes sampled from rx_clk

Protocol IP `XGMII`, version 2.0. Apache-2.0.

## Overview

XGMII MAC datapath: 32-bit SDR TX + RX with term/error column (txc/rxc) TX: host bytes packed into 32-bit columns -> async FIFO -> txd/txc on tx_clk; a partial last column (end of frame) pads with idle lanes RX: rxd/rxc on rx_clk -> byte ring; data lanes (rxc=0) are compacted Loopback-compatible. OpenCores ethernet/xgmii style.


txd, txc, tx_clk, rxd, rxc and rx_clk are the XGMII pins; they pass through unchanged. An empty TX FIFO sends idle columns (0x07070707, txc 0xF). rx_clk is sampled on clk (each phase at least two clocks); on each rising edge the data lanes (rxc clear) are stored in lane order, control lanes skipped. tx_clk is its own clock domain.

## Files

| File | Content |
|---|---|
| `rtl/XGMII_top.sv` | protocol core |
| `rtl/XGMII_apb.sv` | APB4 register wrapper (generated) |
| `tb/XGMII_tb.sv` | core testbench |
| `tb/XGMII_apb_tb.sv`, `tb/apb/XGMII_apb_func.svh` | wrapper testbench (generated part + IP-specific part) |
| `tb/cov/XGMII_sva.sv`, `tb/cov/XGMII_apb_sva.sv` | coverage checkers (core, wrapper) |
| `scripts/apb/specs/XGMII.json` | register spec the wrapper, TB, checker and this page are generated from |

```
make -f Makefile.XGMII sim syn            # core test + synthesis (Icarus, Yosys)
make -f Makefile.XGMII apb                # wrapper test + synthesis
bash scripts/cov/run_cov.sh XGMII          # core coverage (Verilator)
bash scripts/cov/run_cov.sh XGMII_apb      # wrapper coverage
```

## Core ports

| Port | Dir | Width | In the APB wrapper |
|---|---|---|---|
| `clk` | input | 1 | PCLK |
| `rst_n` | input | 1 | PRESETN |
| `tx_clk` | input | 1 | pin (pass-through) |
| `txd` | output | 32 | pin (pass-through) |
| `txc` | output | 4 | pin (pass-through) |
| `rx_clk` | input | 1 | pin (pass-through) |
| `rxd` | input | 32 | pin (pass-through) |
| `rxc` | input | 4 | pin (pass-through) |
| `wen` | input | 1 | write to a CORE word |
| `waddr` | input | 4 | CORE word index |
| `wdata` | input | 8 | CORE write data |
| `ren` | input | 1 | read of a CORE word |
| `raddr` | input | 4 | CORE word index |
| `rdata` | output | 8 | CORE read data |
| `count` | output | 5 | STATUS[4:0] |
| `irq` | output | 1 | IRQ_STATUS.READ |

## APB wrapper

`XGMII_apb` is an APB4 slave (AMBA APB protocol v2.0): zero wait states, 32-bit data, 12-bit byte address, PSTRB byte lanes on every writable register, PSLVERR on an unmapped or misaligned address (reads then return 0, writes are dropped). Writes to read-only registers are ignored without an error. The core runs on PCLK and PRESETN. `irq` is level-high: `|(IRQ_STATUS & IRQ_ENABLE)`.

Pass-through pins: `tx_clk`, `txd`, `txc`, `rx_clk`, `rxd`, `rxc`.

### Register map

| Offset | Name | Access | Reset | Description |
|---|---|---|---|---|
| 0x000 | ID | RO | 0x58470200 | IP identification: code, major and minor version |
| 0x004 | IRQ_STATUS | W1C | 0x00000000 | Sticky interrupt bits, write 1 to clear |
| 0x008 | IRQ_ENABLE | RW | 0x00000000 | Interrupt enables; irq = \|(IRQ_STATUS & IRQ_ENABLE) |
| 0x00C | FLAGS | RO | 0x00000000 | Stream holding-register state |
| 0x010 | SCRATCH | RW | 0x00000000 | Scratch register, no effect on the core |
| 0x014 | STATUS | RO | 0x00000000 | RX capture count |
| 0x018 | TX | WO (core) | 0x00000000 | Byte to send, packed lane 0 first; the fourth byte pushes the column (dropped while the 4-column FIFO is full) (write-only) |
| 0x01C | EOF | WO (core) | 0x00000000 | End of frame: pushes a partly filled column, idle (0x07, txc set) in the unused lanes; nothing when no byte is held or while the FIFO is full (write-only, data ignored) |
| 0x020 | RX0 | RO (core) | 0x00000000 | RX capture ring entry 0 |
| 0x024 | RX1 | RO (core) | 0x00000000 | RX capture ring entry 1 |
| 0x028 | RX2 | RO (core) | 0x00000000 | RX capture ring entry 2 |
| 0x02C | RX3 | RO (core) | 0x00000000 | RX capture ring entry 3 |
| 0x030 | RX4 | RO (core) | 0x00000000 | RX capture ring entry 4 |
| 0x034 | RX5 | RO (core) | 0x00000000 | RX capture ring entry 5 |
| 0x038 | RX6 | RO (core) | 0x00000000 | RX capture ring entry 6 |
| 0x03C | RX7 | RO (core) | 0x00000000 | RX capture ring entry 7 |
| 0x040 | RX8 | RO (core) | 0x00000000 | RX capture ring entry 8 |
| 0x044 | RX9 | RO (core) | 0x00000000 | RX capture ring entry 9 |
| 0x048 | RX10 | RO (core) | 0x00000000 | RX capture ring entry 10 |
| 0x04C | RX11 | RO (core) | 0x00000000 | RX capture ring entry 11 |
| 0x050 | RX12 | RO (core) | 0x00000000 | RX capture ring entry 12 |
| 0x054 | RX13 | RO (core) | 0x00000000 | RX capture ring entry 13 |
| 0x058 | RX14 | RO (core) | 0x00000000 | RX capture ring entry 14 |
| 0x05C | RX15 | RO (core) | 0x00000000 | RX capture ring entry 15 |

### Fields

| Register | Bits | Field | Description |
|---|---|---|---|
| ID | 31:16 | CODE | 0x5847 |
| ID | 15:8 | MAJOR | 2 |
| ID | 7:0 | MINOR | 0 |
| STATUS | 4:0 | `count` | data lanes captured (wraps at 32); entry count mod 16 is written next |
| TX | 7:0 | core register | written at core register 0 |
| EOF | 7:0 | core register | written at core register 1 |
| RX0 | 7:0 | core register | read from core register 0 |
| RX1 | 7:0 | core register | read from core register 1 |
| RX2 | 7:0 | core register | read from core register 2 |
| RX3 | 7:0 | core register | read from core register 3 |
| RX4 | 7:0 | core register | read from core register 4 |
| RX5 | 7:0 | core register | read from core register 5 |
| RX6 | 7:0 | core register | read from core register 6 |
| RX7 | 7:0 | core register | read from core register 7 |
| RX8 | 7:0 | core register | read from core register 8 |
| RX9 | 7:0 | core register | read from core register 9 |
| RX10 | 7:0 | core register | read from core register 10 |
| RX11 | 7:0 | core register | read from core register 11 |
| RX12 | 7:0 | core register | read from core register 12 |
| RX13 | 7:0 | core register | read from core register 13 |
| RX14 | 7:0 | core register | read from core register 14 |
| RX15 | 7:0 | core register | read from core register 15 |

### Interrupts (IRQ_STATUS, IRQ_ENABLE)

A bit is set while its source is active, stays set until written with 1, and a set in the same clock as the clear wins.

| Bit | Name | Set when |
|---|---|---|
| 0 | READ | a ring entry was read after at least one byte was captured |

### Core register port

The CORE words reach the core's own register port. A write to one pulses `wen` for one clock with `waddr` (the core register) and `wdata` (PWDATA's low bits); it must cover the whole word (PSTRB = 4'hF): a partial write is dropped with PSLVERR. A read drives `raddr` (the core register) and pulses `ren` during the access phase and returns `rdata`.

## Verification

Five-metric coverage with Verilator 5.052 (`scripts/cov/run_cov.sh`); see [COVERAGE_CLOSURE.md](../COVERAGE_CLOSURE.md) for the flow. Line and toggle count only the named RTL file.

| Scope | Test | Line | Toggle | FSM | SVA | Functional |
|---|---|---|---|---|---|---|
| core `rtl/XGMII_top.sv` | pass | 33/33 | 1054/1054 | n/a | 7/7 | 12/12 |
| wrapper `rtl/XGMII_apb.sv` | pass | 36/36 | 624/624 | n/a | 11/11 | 62/62 |
