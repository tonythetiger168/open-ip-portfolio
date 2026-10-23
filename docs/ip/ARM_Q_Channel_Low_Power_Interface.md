# ARM Q-Channel device-side controller: qreqn / qacceptn / qdeny / qactive handshake (RUN, REQUEST, STOPPED, EXIT, DENIED), activity from software events, illegal controller sequences flagged

Protocol IP `ARM_Q_Channel_Low_Power_Interface`, version 2.0. Apache-2.0.

## Overview

ARM Q-Channel Low Power Interface -- device-side controller Full qreqn/qacceptn/qdeny/qactive handshake FSM (Q_RUN, Q_REQUEST, Q_STOPPED, Q_EXIT, Q_DENIED), qactive driven by internal activity detection (dev_event counter), deny path, illegal-sequence detection -> irq


qreqn is the controller's request pin; it passes through unchanged and is sampled on PCLK. qacceptn, qdeny and qactive drive the Q-Channel pins and are also readable in STATUS.
A request (qreqn low) is decided in the clock after it is seen: accepted (qacceptn low) when the device is idle, denied (qdeny high) when qactive is high. Only software activity events (EVENT) make the device active.

## Files

| File | Content |
|---|---|
| `rtl/ARM_Q_Channel_Low_Power_Interface_top.sv` | protocol core |
| `rtl/ARM_Q_Channel_Low_Power_Interface_apb.sv` | APB4 register wrapper (generated) |
| `tb/ARM_Q_Channel_Low_Power_Interface_tb.sv` | core testbench |
| `tb/ARM_Q_Channel_Low_Power_Interface_apb_tb.sv`, `tb/apb/ARM_Q_Channel_Low_Power_Interface_apb_func.svh` | wrapper testbench (generated part + IP-specific part) |
| `tb/cov/ARM_Q_Channel_Low_Power_Interface_sva.sv`, `tb/cov/ARM_Q_Channel_Low_Power_Interface_apb_sva.sv` | coverage checkers (core, wrapper) |
| `scripts/apb/specs/ARM_Q_Channel_Low_Power_Interface.json` | register spec the wrapper, TB, checker and this page are generated from |

```
make -f Makefile.ARM_Q_Channel_Low_Power_Interface sim syn            # core test + synthesis (Icarus, Yosys)
make -f Makefile.ARM_Q_Channel_Low_Power_Interface apb                # wrapper test + synthesis
bash scripts/cov/run_cov.sh ARM_Q_Channel_Low_Power_Interface          # core coverage (Verilator)
bash scripts/cov/run_cov.sh ARM_Q_Channel_Low_Power_Interface_apb      # wrapper coverage
```

## Core ports

| Port | Dir | Width | In the APB wrapper |
|---|---|---|---|
| `clk` | input | 1 | PCLK |
| `rst_n` | input | 1 | PRESETN |
| `qreqn` | input | 1 | pin (pass-through) |
| `qacceptn` | output | 1 | STATUS[0:0] |
| `qdeny` | output | 1 | STATUS[1:1], IRQ_STATUS.DENIED |
| `qactive` | output | 1 | STATUS[2:2] |
| `dev_event` | input | 1 | EVENT |
| `irq` | output | 1 | IRQ_STATUS.ILLEGAL |

## APB wrapper

`ARM_Q_Channel_Low_Power_Interface_apb` is an APB4 slave (AMBA APB protocol v2.0): zero wait states, 32-bit data, 12-bit byte address, PSTRB byte lanes on every writable register, PSLVERR on an unmapped or misaligned address (reads then return 0, writes are dropped). Writes to read-only registers are ignored without an error. The core runs on PCLK and PRESETN. `irq` is level-high: `|(IRQ_STATUS & IRQ_ENABLE)`.

Pass-through pins: `qreqn`, `qacceptn`, `qdeny`, `qactive`.

### Register map

| Offset | Name | Access | Reset | Description |
|---|---|---|---|---|
| 0x000 | ID | RO | 0x51430200 | IP identification: code, major and minor version |
| 0x004 | IRQ_STATUS | W1C | 0x00000000 | Sticky interrupt bits, write 1 to clear |
| 0x008 | IRQ_ENABLE | RW | 0x00000000 | Interrupt enables; irq = \|(IRQ_STATUS & IRQ_ENABLE) |
| 0x00C | FLAGS | RO | 0x00000000 | Stream holding-register state |
| 0x010 | SCRATCH | RW | 0x00000000 | Scratch register, no effect on the core |
| 0x014 | EVENT | WO (pulse) | 0x00000000 | Device activity |
| 0x018 | STATUS | RO | 0x00000000 | Q-Channel outputs, as driven on the pins |

### Fields

| Register | Bits | Field | Description |
|---|---|---|---|
| ID | 31:16 | CODE | 0x5143 |
| ID | 15:8 | MAJOR | 2 |
| ID | 7:0 | MINOR | 0 |
| EVENT | 0 | `dev_event` | write 1: an activity event; qactive stays high for ACT_CYCLES (16) clocks after the last one, and a request while it is high is denied |
| STATUS | 0 | `qacceptn` | low: the device accepted the request and is stopped (STOPPED and EXIT) |
| STATUS | 1 | `qdeny` | high: the request was denied (DENIED, until qreqn rises) |
| STATUS | 2 | `qactive` | high: activity within the last ACT_CYCLES clocks |

### Interrupts (IRQ_STATUS, IRQ_ENABLE)

A bit is set while its source is active, stays set until written with 1, and a set in the same clock as the clear wins.

| Bit | Name | Set when |
|---|---|---|
| 0 | ILLEGAL | the controller broke the handshake: qreqn rose before the device answered a request, or fell during the exit |
| 1 | DENIED | a request was denied; set on every clock qdeny is high, so a clear only holds once qreqn has risen |

## Verification

Five-metric coverage with Verilator 5.052 (`scripts/cov/run_cov.sh`); see [COVERAGE_CLOSURE.md](../COVERAGE_CLOSURE.md) for the flow. Line and toggle count only the named RTL file.

| Scope | Test | Line | Toggle | FSM | SVA | Functional |
|---|---|---|---|---|---|---|
| core `rtl/ARM_Q_Channel_Low_Power_Interface_top.sv` | pass | 27/27 (+1 excl.) | 34/34 | 14/14 | 9/9 | 9/9 |
| wrapper `rtl/ARM_Q_Channel_Low_Power_Interface_apb.sv` | pass | 22/22 | 420/420 | n/a | 8/8 | 32/32 |
