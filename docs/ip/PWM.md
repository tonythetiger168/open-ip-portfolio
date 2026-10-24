# PWM generator: programmable period and duty, output and its complement

Protocol IP `PWM`, version 2.0. Apache-2.0.

| Item | Value |
|---|---|
| Core | `PWM_top` (`rtl/PWM_top.sv`) |
| Register interface | APB4 slave `PWM_apb`, 32-bit data, 12-bit byte address, zero wait states |
| Clock, reset | PCLK (rising edge), PRESETN (active low, asynchronous) |
| ID register | 0x50570200 (code 0x5057, version 2.0) |
| Registers | 7 words, 0x000 to 0x018 |
| Interrupts | 1 sources into one level-high `irq` |
| Core register port | CORE (2 words) |
| Protocol pins | 2 pass-through |

## Overview

PWM generator: period/duty registers, active-high output + complement

Features:

- `DW`-bit (default 32) period and duty registers, written through the core register port.
- Counter runs 0 .. PERIOD-1 and wraps; PERIOD = 0 stops it and holds the outputs low (`pwm_out` = 0, `pwm_n_out` = 1).
- `pwm_out` is high while counter < DUTY; DUTY >= PERIOD gives 100 % duty, DUTY = 0 gives 0 %.
- `pwm_n_out` is always the complement of `pwm_out` (no dead time).
- Interrupt PERIOD_END once per period, in the last count (counter = PERIOD-1).

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

## Parameters

`PWM_apb` has the core's parameters and passes them to `PWM_top` unchanged.

| Parameter | Type | Default |
|---|---|---|
| `DW` | int | `32` |

## Wrapper pins

Pins of `PWM_apb`. Widths of the pass-through pins are at the default parameters.

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
| `pwm_out` | output | 1 | protocol pin, core port `pwm_out` |
| `pwm_n_out` | output | 1 | protocol pin, core port `pwm_n_out` |

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
| 0x014 | PERIOD | WO (core) | core | Period in clocks (0 stops the output, held low) |
| 0x018 | DUTY | WO (core) | core | Clocks per period the output is high |

Unlisted bits read 0 and ignore writes. Reset "core": the register reads the core's outputs directly, so after reset it shows the core's own reset state. WO (pulse) registers read 0. Offsets from 0x01C up to 0xFFC are unmapped (PSLVERR).

### Fields

| Register | Bits | Field | Access | Reset | Description |
|---|---|---|---|---|---|
| ID | 31:16 | CODE | RO | 0x5057 | IP code |
| ID | 15:8 | MAJOR | RO | 0x02 | major version |
| ID | 7:0 | MINOR | RO | 0x00 | minor version |
| IRQ_STATUS | 0 | one bit per interrupt | W1C | 0x0 | see Interrupts |
| IRQ_ENABLE | 0 | one bit per interrupt | RW | 0x0 | 1 enables the IRQ_STATUS bit onto `irq` |
| SCRATCH | 31:0 | SCRATCH | RW | 0x00000000 | free for software |
| PERIOD | 31:0 | core register | WO (core) | core | written at core register 0 |
| DUTY | 31:0 | core register | WO (core) | core | written at core register 1 |

### Interrupts (IRQ_STATUS, IRQ_ENABLE)

A bit is set while its source is active, stays set until written with 1, and a set in the same clock as the clear wins.

| Bit | Name | Set when |
|---|---|---|
| 0 | PERIOD_END | the last clock of a period |

### Core register port

The CORE words reach the core's own register port. A write to one pulses `wen` for one clock with `waddr` (the core register) and `wdata` (PWDATA's low bits); it must cover the whole word (PSTRB = 4'hF): a partial write is dropped with PSLVERR. 

## Programming sequence

1. Release PRESETN. Read ID (0x000) and check it is 0x50570200.
2. Write 0x1 to IRQ_STATUS (0x004) to clear any stale bits.
3. Write IRQ_ENABLE (0x008) with the interrupts to use (bit order as in the Interrupts table; 0x1 enables all).
4. Access the core's registers through the CORE words (0x014 onward), one word per core register; write whole words (PSTRB = 0xF), a partial write is dropped with PSLVERR.
5. On `irq`: read IRQ_STATUS, handle every bit that is set and enabled, then write those bits back to IRQ_STATUS to clear them. A source that is still active sets its bit again.

## Verification

Five-metric coverage with Verilator 5.052 (`scripts/cov/run_cov.sh`); see [COVERAGE_CLOSURE.md](../COVERAGE_CLOSURE.md) for the flow. Line and toggle count only the named RTL file.

| Scope | Test | Line | Toggle | FSM | SVA | Functional |
|---|---|---|---|---|---|---|
| core `rtl/PWM_top.sv` | pass | 11/11 | 276/276 (+20 excl.) | n/a | 5/5 | 14/14 |
| wrapper `rtl/PWM_apb.sv` | FAIL | 19/19 | 466/466 | n/a | 9/9 | 28/28 |
