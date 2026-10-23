# AMBA ATB trace sink: a 16-beat capture buffer flushed when the trace ID changes, read back through the registers

Protocol IP `ATB`, version 2.0. Apache-2.0.

## Overview

CoreSight ATB slave: atvalid/atready handshake, 32-bit data + 7-bit ID Sink with 16-deep FIFO capture; fifo flush on atid change or AFREADY. OpenCreensight/atb funnel style.


atvalid, atready, atdata, atid, atlast, afvalid and afready are the ATB slave pins; they pass through unchanged. afvalid with an ATID other than the current one flushes the buffer (count back to 0) and makes that ID current; afready is always 1. Beats fill entries 0 to 15 in order.

## Files

| File | Content |
|---|---|
| `rtl/ATB_top.sv` | protocol core |
| `rtl/ATB_apb.sv` | APB4 register wrapper (generated) |
| `tb/ATB_tb.sv` | core testbench |
| `tb/ATB_apb_tb.sv`, `tb/apb/ATB_apb_func.svh` | wrapper testbench (generated part + IP-specific part) |
| `tb/cov/ATB_sva.sv`, `tb/cov/ATB_apb_sva.sv` | coverage checkers (core, wrapper) |
| `scripts/apb/specs/ATB.json` | register spec the wrapper, TB, checker and this page are generated from |

```
make -f Makefile.ATB sim syn            # core test + synthesis (Icarus, Yosys)
make -f Makefile.ATB apb                # wrapper test + synthesis
bash scripts/cov/run_cov.sh ATB          # core coverage (Verilator)
bash scripts/cov/run_cov.sh ATB_apb      # wrapper coverage
```

## Core ports

| Port | Dir | Width | In the APB wrapper |
|---|---|---|---|
| `clk` | input | 1 | PCLK |
| `rst_n` | input | 1 | PRESETN |
| `atvalid` | input | 1 | pin (pass-through) |
| `atready` | output | 1 | pin (pass-through) |
| `atdata` | input | 32 | pin (pass-through) |
| `atid` | input | 7 | pin (pass-through) |
| `atlast` | input | 1 | pin (pass-through) |
| `afvalid` | input | 1 | pin (pass-through) |
| `afready` | output | 1 | pin (pass-through) |
| `ren` | input | 1 | read of a CORE word |
| `raddr` | input | 4 | CORE word index |
| `rdata` | output | 32 | CORE read data |
| `count` | output | 5 | STATUS[4:0] |
| `last_id` | output | 7 | STATUS[11:5] |
| `irq` | output | 1 | IRQ_STATUS.LAST |

## APB wrapper

`ATB_apb` is an APB4 slave (AMBA APB protocol v2.0): zero wait states, 32-bit data, 12-bit byte address, PSTRB byte lanes on every writable register, PSLVERR on an unmapped or misaligned address (reads then return 0, writes are dropped). Writes to read-only registers are ignored without an error. The core runs on PCLK and PRESETN. `irq` is level-high: `|(IRQ_STATUS & IRQ_ENABLE)`.

Pass-through pins: `atvalid`, `atready`, `atdata`, `atid`, `atlast`, `afvalid`, `afready`.

### Register map

| Offset | Name | Access | Reset | Description |
|---|---|---|---|---|
| 0x000 | ID | RO | 0x41540200 | IP identification: code, major and minor version |
| 0x004 | IRQ_STATUS | W1C | 0x00000000 | Sticky interrupt bits, write 1 to clear |
| 0x008 | IRQ_ENABLE | RW | 0x00000000 | Interrupt enables; irq = \|(IRQ_STATUS & IRQ_ENABLE) |
| 0x00C | FLAGS | RO | 0x00000000 | Stream holding-register state |
| 0x010 | SCRATCH | RW | 0x00000000 | Scratch register, no effect on the core |
| 0x014 | STATUS | RO | 0x00000000 | Capture buffer state |
| 0x018 | D0 | RO (core) | 0x00000000 | Capture buffer entry 0 |
| 0x01C | D1 | RO (core) | 0x00000000 | Capture buffer entry 1 |
| 0x020 | D2 | RO (core) | 0x00000000 | Capture buffer entry 2 |
| 0x024 | D3 | RO (core) | 0x00000000 | Capture buffer entry 3 |
| 0x028 | D4 | RO (core) | 0x00000000 | Capture buffer entry 4 |
| 0x02C | D5 | RO (core) | 0x00000000 | Capture buffer entry 5 |
| 0x030 | D6 | RO (core) | 0x00000000 | Capture buffer entry 6 |
| 0x034 | D7 | RO (core) | 0x00000000 | Capture buffer entry 7 |
| 0x038 | D8 | RO (core) | 0x00000000 | Capture buffer entry 8 |
| 0x03C | D9 | RO (core) | 0x00000000 | Capture buffer entry 9 |
| 0x040 | D10 | RO (core) | 0x00000000 | Capture buffer entry 10 |
| 0x044 | D11 | RO (core) | 0x00000000 | Capture buffer entry 11 |
| 0x048 | D12 | RO (core) | 0x00000000 | Capture buffer entry 12 |
| 0x04C | D13 | RO (core) | 0x00000000 | Capture buffer entry 13 |
| 0x050 | D14 | RO (core) | 0x00000000 | Capture buffer entry 14 |
| 0x054 | D15 | RO (core) | 0x00000000 | Capture buffer entry 15 |

### Fields

| Register | Bits | Field | Description |
|---|---|---|---|
| ID | 31:16 | CODE | 0x4154 |
| ID | 15:8 | MAJOR | 2 |
| ID | 7:0 | MINOR | 0 |
| STATUS | 4:0 | `count` | beats captured since the last flush (16: full, atready low) |
| STATUS | 11:5 | `last_id` | ATID of the last beat accepted with atlast |
| D0 | 31:0 | core register | read from core register 0 |
| D1 | 31:0 | core register | read from core register 1 |
| D2 | 31:0 | core register | read from core register 2 |
| D3 | 31:0 | core register | read from core register 3 |
| D4 | 31:0 | core register | read from core register 4 |
| D5 | 31:0 | core register | read from core register 5 |
| D6 | 31:0 | core register | read from core register 6 |
| D7 | 31:0 | core register | read from core register 7 |
| D8 | 31:0 | core register | read from core register 8 |
| D9 | 31:0 | core register | read from core register 9 |
| D10 | 31:0 | core register | read from core register 10 |
| D11 | 31:0 | core register | read from core register 11 |
| D12 | 31:0 | core register | read from core register 12 |
| D13 | 31:0 | core register | read from core register 13 |
| D14 | 31:0 | core register | read from core register 14 |
| D15 | 31:0 | core register | read from core register 15 |

### Interrupts (IRQ_STATUS, IRQ_ENABLE)

A bit is set while its source is active, stays set until written with 1, and a set in the same clock as the clear wins.

| Bit | Name | Set when |
|---|---|---|
| 0 | LAST | a beat with atlast was accepted |

### Core register port

The CORE words reach the core's own register port. A write to one pulses A read drives `raddr` (the core register) and pulses `ren` during the access phase and returns `rdata`.

## Verification

Five-metric coverage with Verilator 5.052 (`scripts/cov/run_cov.sh`); see [COVERAGE_CLOSURE.md](../COVERAGE_CLOSURE.md) for the flow. Line and toggle count only the named RTL file.

| Scope | Test | Line | Toggle | FSM | SVA | Functional |
|---|---|---|---|---|---|---|
| core `rtl/ATB_top.sv` | pass | 8/8 | 218/218 (+1 excl.) | n/a | 8/8 | 19/19 |
| wrapper `rtl/ATB_apb.sv` | pass | 36/36 | 604/604 (+1 excl.) | n/a | 9/9 | 57/57 |
