# AXI4-Stream sink: a 16-beat capture buffer, read back through the registers

Protocol IP `AXI_Stream`, version 2.0. Apache-2.0.

## Overview

AXI-Stream sink monitor with 16-deep FIFO capture OpenCores avalon/peripheral style: tready backpressure, IRQ on tlast.


tvalid, tready, tdata and tlast are the AXI4-Stream slave pins; they pass through unchanged. Beats fill entries 0 to 15 in order; the buffer is emptied only by reset.

## Files

| File | Content |
|---|---|
| `rtl/AXI_Stream_top.sv` | protocol core |
| `rtl/AXI_Stream_apb.sv` | APB4 register wrapper (generated) |
| `tb/AXI_Stream_tb.sv` | core testbench |
| `tb/AXI_Stream_apb_tb.sv`, `tb/apb/AXI_Stream_apb_func.svh` | wrapper testbench (generated part + IP-specific part) |
| `tb/cov/AXI_Stream_sva.sv`, `tb/cov/AXI_Stream_apb_sva.sv` | coverage checkers (core, wrapper) |
| `scripts/apb/specs/AXI_Stream.json` | register spec the wrapper, TB, checker and this page are generated from |

```
make -f Makefile.AXI_Stream sim syn            # core test + synthesis (Icarus, Yosys)
make -f Makefile.AXI_Stream apb                # wrapper test + synthesis
bash scripts/cov/run_cov.sh AXI_Stream          # core coverage (Verilator)
bash scripts/cov/run_cov.sh AXI_Stream_apb      # wrapper coverage
```

## Core ports

| Port | Dir | Width | In the APB wrapper |
|---|---|---|---|
| `clk` | input | 1 | PCLK |
| `rst_n` | input | 1 | PRESETN |
| `tvalid` | input | 1 | pin (pass-through) |
| `tready` | output | 1 | pin (pass-through) |
| `tdata` | input | 32 | pin (pass-through) |
| `tlast` | input | 1 | pin (pass-through) |
| `ren` | input | 1 | read of a CORE word |
| `raddr` | input | 4 | CORE word index |
| `rdata` | output | 32 | CORE read data |
| `count` | output | 5 | STATUS[4:0] |
| `irq` | output | 1 | IRQ_STATUS.LAST |

## APB wrapper

`AXI_Stream_apb` is an APB4 slave (AMBA APB protocol v2.0): zero wait states, 32-bit data, 12-bit byte address, PSTRB byte lanes on every writable register, PSLVERR on an unmapped or misaligned address (reads then return 0, writes are dropped). Writes to read-only registers are ignored without an error. The core runs on PCLK and PRESETN. `irq` is level-high: `|(IRQ_STATUS & IRQ_ENABLE)`.

Pass-through pins: `tvalid`, `tready`, `tdata`, `tlast`.

### Register map

| Offset | Name | Access | Reset | Description |
|---|---|---|---|---|
| 0x000 | ID | RO | 0x41530200 | IP identification: code, major and minor version |
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
| ID | 31:16 | CODE | 0x4153 |
| ID | 15:8 | MAJOR | 2 |
| ID | 7:0 | MINOR | 0 |
| STATUS | 4:0 | `count` | beats captured (16: full, tready low until reset) |
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
| 0 | LAST | a beat with tlast was accepted |

### Core register port

The CORE words reach the core's own register port. A write to one pulses A read drives `raddr` (the core register) and pulses `ren` during the access phase and returns `rdata`.

## Verification

Five-metric coverage with Verilator 5.052 (`scripts/cov/run_cov.sh`); see [COVERAGE_CLOSURE.md](../COVERAGE_CLOSURE.md) for the flow. Line and toggle count only the named RTL file.

| Scope | Test | Line | Toggle | FSM | SVA | Functional |
|---|---|---|---|---|---|---|
| core `rtl/AXI_Stream_top.sv` | pass | 5/5 | 172/172 | n/a | 6/6 | 16/16 |
| wrapper `rtl/AXI_Stream_apb.sv` | pass | 36/36 | 572/572 | n/a | 9/9 | 57/57 |
