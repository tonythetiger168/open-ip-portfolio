# GPIO bank: 8 bidirectional pins with per-pin output enable and input readback

Protocol IP `GPIO`, version 2.0. Apache-2.0.

| Item | Value |
|---|---|
| Core | `GPIO_top` (`rtl/GPIO_top.sv`) |
| Register interface | APB4 slave `GPIO_apb`, 32-bit data, 12-bit byte address, zero wait states |
| Clock, reset | PCLK (rising edge), PRESETN (active low, asynchronous) |
| ID register | 0x47500200 (code 0x4750, version 2.0) |
| Registers | 8 words, 0x000 to 0x01C |
| Interrupts | 1 sources into one level-high `irq` |
| Core register port | CORE (2 words) |
| Protocol pins | 1 pass-through |

## Overview

GPIO bank: 8-bit bidirectional, per-bit output-enable, input readback

Features:

- 8 bidirectional pins `gpio[7:0]`; each pin is driven from OUT only while its OE bit is 1, otherwise it is released (high impedance).
- Input readback: IN shows the pin levels registered one clock earlier.
- OUT reads back the value last written.
- Interrupt HIGH is set while any registered input pin is high (level source, so it sets again until the pins are low).

gpio is the pin bank; it passes through unchanged.

## Files

| File | Content |
|---|---|
| `rtl/GPIO_top.sv` | protocol core |
| `rtl/GPIO_apb.sv` | APB4 register wrapper (generated) |
| `tb/GPIO_tb.sv` | core testbench |
| `tb/GPIO_apb_tb.sv`, `tb/apb/GPIO_apb_func.svh` | wrapper testbench (generated part + IP-specific part) |
| `tb/cov/GPIO_sva.sv`, `tb/cov/GPIO_apb_sva.sv` | coverage checkers (core, wrapper) |
| `scripts/apb/specs/GPIO.json` | register spec the wrapper, TB, checker and this page are generated from |

```
make -f Makefile.GPIO sim syn            # core test + synthesis (Icarus, Yosys)
make -f Makefile.GPIO apb                # wrapper test + synthesis
bash scripts/cov/run_cov.sh GPIO          # core coverage (Verilator)
bash scripts/cov/run_cov.sh GPIO_apb      # wrapper coverage
```

## Parameters

The core and the wrapper have no parameters.

## Wrapper pins

Pins of `GPIO_apb`. Widths of the pass-through pins are at the default parameters.

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
| `gpio` | inout | 8 | protocol pin, core port `gpio` |

## Core ports

| Port | Dir | Width | In the APB wrapper |
|---|---|---|---|
| `clk` | input | 1 | PCLK |
| `rst_n` | input | 1 | PRESETN |
| `wen` | input | 1 | write to a CORE word |
| `waddr` | input | 4 | CORE word index |
| `wdata` | input | 8 | CORE write data |
| `ren` | input | 1 | read of a CORE word |
| `raddr` | input | 4 | CORE word index |
| `rdata` | output | 8 | CORE read data |
| `gpio` | inout | 8 | pin (pass-through) |
| `gpio_oe` | input | 8 | OE[7:0] |
| `irq` | output | 1 | IRQ_STATUS.HIGH |

## APB wrapper

`GPIO_apb` is an APB4 slave (AMBA APB protocol v2.0): zero wait states, 32-bit data, 12-bit byte address, PSTRB byte lanes on every writable register, PSLVERR on an unmapped or misaligned address (reads then return 0, writes are dropped). Writes to read-only registers are ignored without an error. The core runs on PCLK and PRESETN. `irq` is level-high: `|(IRQ_STATUS & IRQ_ENABLE)`.

Pass-through pins: `gpio`.

### Register map

| Offset | Name | Access | Reset | Description |
|---|---|---|---|---|
| 0x000 | ID | RO | 0x47500200 | IP identification: code, major and minor version |
| 0x004 | IRQ_STATUS | W1C | 0x00000000 | Sticky interrupt bits, write 1 to clear |
| 0x008 | IRQ_ENABLE | RW | 0x00000000 | Interrupt enables; irq = \|(IRQ_STATUS & IRQ_ENABLE) |
| 0x00C | FLAGS | RO | 0x00000000 | Stream holding-register state |
| 0x010 | SCRATCH | RW | 0x00000000 | Scratch register, no effect on the core |
| 0x014 | OE | RW | 0x00000000 | Output enables |
| 0x018 | OUT | RW (core) | core | Output values (driven on pins whose OE bit is set) |
| 0x01C | IN | RO (core) | core | Pin levels, sampled one clock earlier |

Unlisted bits read 0 and ignore writes. Reset "core": the register reads the core's outputs directly, so after reset it shows the core's own reset state. WO (pulse) registers read 0. Offsets from 0x020 up to 0xFFC are unmapped (PSLVERR).

### Fields

| Register | Bits | Field | Access | Reset | Description |
|---|---|---|---|---|---|
| ID | 31:16 | CODE | RO | 0x4750 | IP code |
| ID | 15:8 | MAJOR | RO | 0x02 | major version |
| ID | 7:0 | MINOR | RO | 0x00 | minor version |
| IRQ_STATUS | 0 | one bit per interrupt | W1C | 0x0 | see Interrupts |
| IRQ_ENABLE | 0 | one bit per interrupt | RW | 0x0 | 1 enables the IRQ_STATUS bit onto `irq` |
| SCRATCH | 31:0 | SCRATCH | RW | 0x00000000 | free for software |
| OE | 7:0 | `gpio_oe` | RW | 0x0 | 1: pin driven from OUT; 0: pin is an input |
| OUT | 7:0 | core register | RW (core) | core | written at core register 0 and read from core register 1 |
| IN | 7:0 | core register | RO (core) | core | read from core register 0 |

### Interrupts (IRQ_STATUS, IRQ_ENABLE)

A bit is set while its source is active, stays set until written with 1, and a set in the same clock as the clear wins.

| Bit | Name | Set when |
|---|---|---|
| 0 | HIGH | a pin was sampled high |

### Core register port

The CORE words reach the core's own register port. A write to one pulses `wen` for one clock with `waddr` (the core register) and `wdata` (PWDATA's low bits); it must cover the whole word (PSTRB = 4'hF): a partial write is dropped with PSLVERR. A read drives `raddr` (the core register) and pulses `ren` during the access phase and returns `rdata`.

## Programming sequence

1. Release PRESETN. Read ID (0x000) and check it is 0x47500200.
2. Write 0x1 to IRQ_STATUS (0x004) to clear any stale bits.
3. Configure the core: write OE (0x014). Reset values are in the register map; PSTRB selects the bytes written.
4. Write IRQ_ENABLE (0x008) with the interrupts to use (bit order as in the Interrupts table; 0x1 enables all).
5. Access the core's registers through the CORE words (0x018 onward), one word per core register; write whole words (PSTRB = 0xF), a partial write is dropped with PSLVERR.
6. On `irq`: read IRQ_STATUS, handle every bit that is set and enabled, then write those bits back to IRQ_STATUS to clear them. A source that is still active sets its bit again.

## Verification

Five-metric coverage with Verilator 5.052 (`scripts/cov/run_cov.sh`); see [COVERAGE_CLOSURE.md](../COVERAGE_CLOSURE.md) for the flow. Line and toggle count only the named RTL file.

| Scope | Test | Line | Toggle | FSM | SVA | Functional |
|---|---|---|---|---|---|---|
| core `rtl/GPIO_top.sv` | pass | 11/11 | 122/122 | n/a | 4/4 | 12/12 |
| wrapper `rtl/GPIO_apb.sv` | pass | 24/24 | 482/482 | n/a | 12/12 | 30/30 |
