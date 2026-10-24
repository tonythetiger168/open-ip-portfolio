# ARM Q-Channel device-side controller: qreqn / qacceptn / qdeny / qactive handshake (RUN, REQUEST, STOPPED, EXIT, DENIED), activity from software events, illegal controller sequences flagged

Protocol IP `ARM_Q_Channel_Low_Power_Interface`, version 2.0. Apache-2.0.

| Item | Value |
|---|---|
| Core | `ARM_Q_Channel_Low_Power_Interface_top` (`rtl/ARM_Q_Channel_Low_Power_Interface_top.sv`) |
| Register interface | APB4 slave `ARM_Q_Channel_Low_Power_Interface_apb`, 32-bit data, 12-bit byte address, zero wait states |
| Clock, reset | PCLK (rising edge), PRESETN (active low, asynchronous) |
| ID register | 0x51430200 (code 0x5143, version 2.0) |
| Registers | 7 words, 0x000 to 0x018 |
| Interrupts | 2 sources into one level-high `irq` |
| Protocol pins | 4 pass-through |

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

## Parameters

`ARM_Q_Channel_Low_Power_Interface_apb` has the core's parameters and passes them to `ARM_Q_Channel_Low_Power_Interface_top` unchanged.

| Parameter | Type | Default |
|---|---|---|
| `DW` | int | `32` |
| `AW` | int | `32` |
| `ACT_CYCLES` | int | `16` |

## Wrapper pins

Pins of `ARM_Q_Channel_Low_Power_Interface_apb`. Widths of the pass-through pins are at the default parameters.

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
| `PSLVERR` | output | 1 | error: unmapped or misaligned address |
| `irq` | output | 1 | interrupt, level high: \|(IRQ_STATUS & IRQ_ENABLE) |
| `qreqn` | input | 1 | protocol pin, core port `qreqn` |
| `qacceptn` | output | 1 | protocol pin, core port `qacceptn` (also read in a register) |
| `qdeny` | output | 1 | protocol pin, core port `qdeny` (also read in a register) |
| `qactive` | output | 1 | protocol pin, core port `qactive` (also read in a register) |

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
| 0x018 | STATUS | RO | core | Q-Channel outputs, as driven on the pins |

Unlisted bits read 0 and ignore writes. Reset "core": the register reads the core's outputs directly, so after reset it shows the core's own reset state. WO (pulse) registers read 0. Offsets from 0x01C up to 0xFFC are unmapped (PSLVERR).

### Fields

| Register | Bits | Field | Access | Reset | Description |
|---|---|---|---|---|---|
| ID | 31:16 | CODE | RO | 0x5143 | IP code |
| ID | 15:8 | MAJOR | RO | 0x02 | major version |
| ID | 7:0 | MINOR | RO | 0x00 | minor version |
| IRQ_STATUS | 1:0 | one bit per interrupt | W1C | 0x0 | see Interrupts |
| IRQ_ENABLE | 1:0 | one bit per interrupt | RW | 0x0 | 1 enables the IRQ_STATUS bit onto `irq` |
| SCRATCH | 31:0 | SCRATCH | RW | 0x00000000 | free for software |
| EVENT | 0 | `dev_event` | WO (pulse) | 0x0 | write 1: an activity event; qactive stays high for ACT_CYCLES (16) clocks after the last one, and a request while it is high is denied |
| STATUS | 0 | `qacceptn` | RO | core | low: the device accepted the request and is stopped (STOPPED and EXIT) |
| STATUS | 1 | `qdeny` | RO | core | high: the request was denied (DENIED, until qreqn rises) |
| STATUS | 2 | `qactive` | RO | core | high: activity within the last ACT_CYCLES clocks |

### Interrupts (IRQ_STATUS, IRQ_ENABLE)

A bit is set while its source is active, stays set until written with 1, and a set in the same clock as the clear wins.

| Bit | Name | Set when |
|---|---|---|
| 0 | ILLEGAL | the controller broke the handshake: qreqn rose before the device answered a request, or fell during the exit |
| 1 | DENIED | a request was denied; set on every clock qdeny is high, so a clear only holds once qreqn has risen |

## Programming sequence

1. Release PRESETN. Read ID (0x000) and check it is 0x51430200.
2. Write 0x3 to IRQ_STATUS (0x004) to clear any stale bits.
3. Write IRQ_ENABLE (0x008) with the interrupts to use (bit order as in the Interrupts table; 0x3 enables all).
4. To issue a command, write 1 to `dev_event` (EVENT bit 0) at 0x014; the core sees a one-clock pulse, and the register reads 0.
5. Read STATUS (0x018) for the core's live `qacceptn`, `qdeny`, `qactive`; it needs no clearing.
6. On `irq`: read IRQ_STATUS, handle every bit that is set and enabled, then write those bits back to IRQ_STATUS to clear them. A source that is still active sets its bit again.

## Verification

Five-metric coverage with Verilator 5.052 (`scripts/cov/run_cov.sh`); see [COVERAGE_CLOSURE.md](../COVERAGE_CLOSURE.md) for the flow. Line and toggle count only the named RTL file.

| Scope | Test | Line | Toggle | FSM | SVA | Functional |
|---|---|---|---|---|---|---|
| core `rtl/ARM_Q_Channel_Low_Power_Interface_top.sv` | pass | 27/27 (+1 excl.) | 34/34 | 14/14 | 9/9 | 43/43 |
| wrapper `rtl/ARM_Q_Channel_Low_Power_Interface_apb.sv` | pass | 22/22 | 420/420 | n/a | 8/8 | 32/32 |
