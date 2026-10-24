# USB 2.0 full-speed packet engine in echo mode: NRZI, bit stuffing, SYNC / PID / CRC16 checks on receive, the last good frame sent back after a turnaround

Protocol IP `USB2_0`, version 2.0. Apache-2.0.

| Item | Value |
|---|---|
| Core | `USB2_0_top` (`rtl/USB2_0_top.sv`) |
| Register interface | APB4 slave `USB2_0_apb`, 32-bit data, 12-bit byte address, zero wait states |
| Clock, reset | PCLK (rising edge), PRESETN (active low, asynchronous) |
| ID register | 0x55320200 (code 0x5532, version 2.0) |
| Registers | 6 words, 0x000 to 0x014 |
| Interrupts | 1 sources into one level-high `irq` |
| Protocol pins | 2 pass-through |

## Overview

USB 2.0 full-speed packet engine, echo mode (pin-shared, half duplex) RX: 2-flop line sync, DPLL bit recovery (re-centred on every transition), NRZI decode, SYNC hunt, bit de-stuffing (a 0 after six 1s; a 1 there is a stuff error), PID check, CRC16 residual check (0xB001), EOP (SE0 then J). A frame is PID + 0..MAXB payload bytes + CRC16. TX: echoes the last good frame after a 3-bit turnaround: SYNC, PID, payload, inverted CRC16 (x^16+x^15+x^2+1, init 0xFFFF, LSB first), NRZI with bit stuffing from SYNC on, EOP = 2 bits SE0 + 1 bit J, then release (the bus pull-ups hold J). Any receive error (SYNC, stuffing, PID, overflow, alignment, CRC) sets the sticky rx_err output (cleared by reset), drops the frame and waits for an idle bus (8 bits of J).

dp and dm are the full-speed bus pins (tri-state: the engine drives them only while echoing); they pass through unchanged. A bit is 2 x BAUD_DIV = 40 PCLK clocks.
A frame is SYNC, PID, 0 to 8 payload bytes and CRC16; it is echoed after a three-bit turnaround. A frame in error is dropped and the engine waits for 8 bits of idle J.

## Files

| File | Content |
|---|---|
| `rtl/USB2_0_top.sv` | protocol core |
| `rtl/USB2_0_apb.sv` | APB4 register wrapper (generated) |
| `tb/USB2_0_tb.sv` | core testbench |
| `tb/USB2_0_apb_tb.sv`, `tb/apb/USB2_0_apb_func.svh` | wrapper testbench (generated part + IP-specific part) |
| `tb/cov/USB2_0_sva.sv`, `tb/cov/USB2_0_apb_sva.sv` | coverage checkers (core, wrapper) |
| `scripts/apb/specs/USB2_0.json` | register spec the wrapper, TB, checker and this page are generated from |

```
make -f Makefile.USB2_0 sim syn            # core test + synthesis (Icarus, Yosys)
make -f Makefile.USB2_0 apb                # wrapper test + synthesis
bash scripts/cov/run_cov.sh USB2_0          # core coverage (Verilator)
bash scripts/cov/run_cov.sh USB2_0_apb      # wrapper coverage
```

## Parameters

`USB2_0_apb` has the core's parameters and passes them to `USB2_0_top` unchanged.

| Parameter | Type | Default |
|---|---|---|
| `BAUD_DIV` | int | `20` |
| `MAXB` | int | `8` |

## Wrapper pins

Pins of `USB2_0_apb`. Widths of the pass-through pins are at the default parameters.

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
| `dp` | inout | 1 | protocol pin, core port `dp` |
| `dm` | inout | 1 | protocol pin, core port `dm` |

## Core ports

| Port | Dir | Width | In the APB wrapper |
|---|---|---|---|
| `clk` | input | 1 | PCLK |
| `rst_n` | input | 1 | PRESETN |
| `dp` | inout | 1 | pin (pass-through) |
| `dm` | inout | 1 | pin (pass-through) |
| `busy` | output | 1 | STATUS[0:0] |
| `rx_err` | output | 1 | STATUS[1:1] |
| `irq` | output | 1 | IRQ_STATUS.ECHO |

## APB wrapper

`USB2_0_apb` is an APB4 slave (AMBA APB protocol v2.0): zero wait states, 32-bit data, 12-bit byte address, PSTRB byte lanes on every writable register, PSLVERR on an unmapped or misaligned address (reads then return 0, writes are dropped). Writes to read-only registers are ignored without an error. The core runs on PCLK and PRESETN. `irq` is level-high: `|(IRQ_STATUS & IRQ_ENABLE)`.

Pass-through pins: `dp`, `dm`.

### Register map

| Offset | Name | Access | Reset | Description |
|---|---|---|---|---|
| 0x000 | ID | RO | 0x55320200 | IP identification: code, major and minor version |
| 0x004 | IRQ_STATUS | W1C | 0x00000000 | Sticky interrupt bits, write 1 to clear |
| 0x008 | IRQ_ENABLE | RW | 0x00000000 | Interrupt enables; irq = \|(IRQ_STATUS & IRQ_ENABLE) |
| 0x00C | FLAGS | RO | 0x00000000 | Stream holding-register state |
| 0x010 | SCRATCH | RW | 0x00000000 | Scratch register, no effect on the core |
| 0x014 | STATUS | RO | core | Engine state |

Unlisted bits read 0 and ignore writes. Reset "core": the register reads the core's outputs directly, so after reset it shows the core's own reset state. WO (pulse) registers read 0. Offsets from 0x018 up to 0xFFC are unmapped (PSLVERR).

### Fields

| Register | Bits | Field | Access | Reset | Description |
|---|---|---|---|---|---|
| ID | 31:16 | CODE | RO | 0x5532 | IP code |
| ID | 15:8 | MAJOR | RO | 0x02 | major version |
| ID | 7:0 | MINOR | RO | 0x00 | minor version |
| IRQ_STATUS | 0 | one bit per interrupt | W1C | 0x0 | see Interrupts |
| IRQ_ENABLE | 0 | one bit per interrupt | RW | 0x0 | 1 enables the IRQ_STATUS bit onto `irq` |
| SCRATCH | 31:0 | SCRATCH | RW | 0x00000000 | free for software |
| STATUS | 0 | `busy` | RO | core | receiving or echoing a frame |
| STATUS | 1 | `rx_err` | RO | core | a frame was received in error (SYNC, stuffing, PID check, length, alignment, CRC or EOP); held until reset |

### Interrupts (IRQ_STATUS, IRQ_ENABLE)

A bit is set while its source is active, stays set until written with 1, and a set in the same clock as the clear wins.

| Bit | Name | Set when |
|---|---|---|
| 0 | ECHO | a good frame was received (its echo follows) |

## Programming sequence

1. Release PRESETN. Read ID (0x000) and check it is 0x55320200.
2. Write 0x1 to IRQ_STATUS (0x004) to clear any stale bits.
3. Write IRQ_ENABLE (0x008) with the interrupts to use (bit order as in the Interrupts table; 0x1 enables all).
4. Read STATUS (0x014) for the core's live `busy`, `rx_err`; it needs no clearing.
5. On `irq`: read IRQ_STATUS, handle every bit that is set and enabled, then write those bits back to IRQ_STATUS to clear them. A source that is still active sets its bit again.

## Verification

Five-metric coverage with Verilator 5.052 (`scripts/cov/run_cov.sh`); see [COVERAGE_CLOSURE.md](../COVERAGE_CLOSURE.md) for the flow. Line and toggle count only the named RTL file.

| Scope | Test | Line | Toggle | FSM | SVA | Functional |
|---|---|---|---|---|---|---|
| core `rtl/USB2_0_top.sv` | pass | 111/111 (+2 excl.) | 476/476 | 23/23 | 11/11 | 41/41 |
| wrapper `rtl/USB2_0_apb.sv` | pass | 20/20 | 402/402 | n/a | 7/7 | 25/25 |
