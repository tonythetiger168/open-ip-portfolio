# PWM generator: programmable period and duty, output and its complement

Protocol IP `PWM`, version 2.0. Apache-2.0.

## Overview

PWM generator: period/duty registers, active-high output + complement


pwm_out and pwm_n_out are the outputs; they pass through unchanged. PERIOD and DUTY are write-only (the core has no readback): they read 0.

## Files

| File | Content |
|---|---|
| `rtl/PWM_top.sv` | protocol core |
| `rtl/PWM_apb.sv` | APB4 register wrapper (generated) |
| `tb/PWM_tb.sv` | core testbench |
| `tb/PWM_apb_tb.sv`, `tb/apb/PWM_apb_func.svh` | wrapper testbench (generated part + IP-specific part) |
| `tb/cov/PWM_sva.sv`, `tb/cov/PWM_apb_sva.sv` | coverage checkers (core, wrapper) |
| `scripts/apb/specs/PWM.json` | register spec the wrapper, TB, checker and this page are generated from |

```
make -f Makefile.PWM sim syn            # core test + synthesis (Icarus, Yosys)
make -f Makefile.PWM apb                # wrapper test + synthesis
bash scripts/cov/run_cov.sh PWM          # core coverage (Verilator)
bash scripts/cov/run_cov.sh PWM_apb      # wrapper coverage
```

## Core ports

| Port | Dir | Width | In the APB wrapper |
|---|---|---|---|
| `clk` | input | 1 | PCLK |
| `rst_n` | input | 1 | PRESETN |
| `wen` | input | 1 | write to a CORE word |
| `waddr` | input | 4 | CORE word index |
| `wdata` | input | 32 | CORE write data |
| `pwm_out` | output | 1 | pin (pass-through) |
| `pwm_n_out` | output | 1 | pin (pass-through) |
| `irq` | output | 1 | IRQ_STATUS.PERIOD_END |

## APB wrapper

`PWM_apb` is an APB4 slave (AMBA APB protocol v2.0): zero wait states, 32-bit data, 12-bit byte address, PSTRB byte lanes on every writable register, PSLVERR on an unmapped or misaligned address (reads then return 0, writes are dropped). Writes to read-only registers are ignored without an error. The core runs on PCLK and PRESETN. `irq` is level-high: `|(IRQ_STATUS & IRQ_ENABLE)`.

Pass-through pins: `pwm_out`, `pwm_n_out`.

### Register map

| Offset | Name | Access | Reset | Description |
|---|---|---|---|---|
| 0x000 | ID | RO | 0x50570200 | IP identification: code, major and minor version |
| 0x004 | IRQ_STATUS | W1C | 0x00000000 | Sticky interrupt bits, write 1 to clear |
| 0x008 | IRQ_ENABLE | RW | 0x00000000 | Interrupt enables; irq = \|(IRQ_STATUS & IRQ_ENABLE) |
| 0x00C | FLAGS | RO | 0x00000000 | Stream holding-register state |
| 0x010 | SCRATCH | RW | 0x00000000 | Scratch register, no effect on the core |
| 0x014 | PERIOD | WO (core) | 0x00000000 | Period in clocks (0 stops the output, held low) |
| 0x018 | DUTY | WO (core) | 0x00000000 | Clocks per period the output is high |

### Fields

| Register | Bits | Field | Description |
|---|---|---|---|
| ID | 31:16 | CODE | 0x5057 |
| ID | 15:8 | MAJOR | 2 |
| ID | 7:0 | MINOR | 0 |
| PERIOD | 31:0 | core register | written at core register 0 |
| DUTY | 31:0 | core register | written at core register 1 |

### Interrupts (IRQ_STATUS, IRQ_ENABLE)

A bit is set while its source is active, stays set until written with 1, and a set in the same clock as the clear wins.

| Bit | Name | Set when |
|---|---|---|
| 0 | PERIOD_END | the last clock of a period |

### Core register port

The CORE words reach the core's own register port. A write to one pulses `wen` for one clock with `waddr` (the core register) and `wdata` (PWDATA's low bits); it must cover the whole word (PSTRB = 4'hF): a partial write is dropped with PSLVERR. 

## Verification

Five-metric coverage with Verilator 5.052 (`scripts/cov/run_cov.sh`); see [COVERAGE_CLOSURE.md](../COVERAGE_CLOSURE.md) for the flow. Line and toggle count only the named RTL file.

| Scope | Test | Line | Toggle | FSM | SVA | Functional |
|---|---|---|---|---|---|---|
| core `rtl/PWM_top.sv` | pass | 11/11 | 276/276 (+20 excl.) | n/a | 5/5 | 14/14 |
| wrapper `rtl/PWM_apb.sv` | FAIL | 19/19 | 466/466 | n/a | 9/9 | 28/28 |
