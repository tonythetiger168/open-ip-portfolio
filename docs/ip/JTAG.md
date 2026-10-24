# IEEE 1149.1 JTAG TAP controller: 16-state TAP, 4-bit IR, IDCODE (0x1CAF0001), BYPASS and an 8-bit USER data register

Protocol IP `JTAG`, version 2.0. Apache-2.0.

| Item | Value |
|---|---|
| Core | `JTAG_top` (`rtl/JTAG_top.sv`) |
| Register interface | APB4 slave `JTAG_apb`, 32-bit data, 12-bit byte address, zero wait states |
| Clock, reset | PCLK (rising edge), PRESETN (active low, asynchronous) |
| ID register | 0x4A540200 (code 0x4A54, version 2.0) |
| Registers | 5 words, 0x000 to 0x010 |
| Interrupts | 1 sources into one level-high `irq` |
| Protocol pins | 5 pass-through |

## Overview

JTAG TAP controller, IEEE 1149.1 16-state FSM in TCK domain; IDCODE / BYPASS / USER data registers. irq (clk domain): one-cycle pulse after each USER register update. Style follows classic OpenCores jtag/openjtag TAP cores.

tck, tms, tdi, trst_n and tdo are the JTAG port; they pass through unchanged. The TAP runs on tck; only the USER update event crosses into PCLK. TCK must be at most PCLK / 4 for no update to be missed.
Instructions: 0001 IDCODE (selected in Test-Logic-Reset), 0010 USER, others BYPASS. IR capture is 0101.
The update event is a toggle in the tck domain that PCLK compares with its own copy. PRESETN clears only the PCLK copy, so after an odd number of USER updates a PRESETN reset (without trst_n) reports one USER_UPDATE when it ends.

## Files

| File | Content |
|---|---|
| `rtl/JTAG_top.sv` | protocol core |
| `rtl/JTAG_apb.sv` | APB4 register wrapper (generated) |
| `tb/JTAG_tb.sv` | core testbench |
| `tb/JTAG_apb_tb.sv`, `tb/apb/JTAG_apb_func.svh` | wrapper testbench (generated part + IP-specific part) |
| `tb/cov/JTAG_sva.sv`, `tb/cov/JTAG_apb_sva.sv` | coverage checkers (core, wrapper) |
| `scripts/apb/specs/JTAG.json` | register spec the wrapper, TB, checker and this page are generated from |

```
make -f Makefile.JTAG sim syn            # core test + synthesis (Icarus, Yosys)
make -f Makefile.JTAG apb                # wrapper test + synthesis
bash scripts/cov/run_cov.sh JTAG          # core coverage (Verilator)
bash scripts/cov/run_cov.sh JTAG_apb      # wrapper coverage
```

## Parameters

`JTAG_apb` has the core's parameters and passes them to `JTAG_top` unchanged.

| Parameter | Type | Default |
|---|---|---|
| `IDCODE` | logic [31:0] | `32'h1CAF_0001` |

## Wrapper pins

Pins of `JTAG_apb`. Widths of the pass-through pins are at the default parameters.

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
| `tck` | input | 1 | protocol pin, core port `tck` |
| `tms` | input | 1 | protocol pin, core port `tms` |
| `tdi` | input | 1 | protocol pin, core port `tdi` |
| `trst_n` | input | 1 | protocol pin, core port `trst_n` |
| `tdo` | output | 1 | protocol pin, core port `tdo` |

## Core ports

| Port | Dir | Width | In the APB wrapper |
|---|---|---|---|
| `clk` | input | 1 | PCLK |
| `rst_n` | input | 1 | PRESETN |
| `tck` | input | 1 | pin (pass-through) |
| `tms` | input | 1 | pin (pass-through) |
| `tdi` | input | 1 | pin (pass-through) |
| `trst_n` | input | 1 | pin (pass-through) |
| `tdo` | output | 1 | pin (pass-through) |
| `irq` | output | 1 | IRQ_STATUS.USER_UPDATE |

## APB wrapper

`JTAG_apb` is an APB4 slave (AMBA APB protocol v2.0): zero wait states, 32-bit data, 12-bit byte address, PSTRB byte lanes on every writable register, PSLVERR on an unmapped or misaligned address (reads then return 0, writes are dropped). Writes to read-only registers are ignored without an error. The core runs on PCLK and PRESETN. `irq` is level-high: `|(IRQ_STATUS & IRQ_ENABLE)`.

Pass-through pins: `tck`, `tms`, `tdi`, `trst_n`, `tdo`.

### Register map

| Offset | Name | Access | Reset | Description |
|---|---|---|---|---|
| 0x000 | ID | RO | 0x4A540200 | IP identification: code, major and minor version |
| 0x004 | IRQ_STATUS | W1C | 0x00000000 | Sticky interrupt bits, write 1 to clear |
| 0x008 | IRQ_ENABLE | RW | 0x00000000 | Interrupt enables; irq = \|(IRQ_STATUS & IRQ_ENABLE) |
| 0x00C | FLAGS | RO | 0x00000000 | Stream holding-register state |
| 0x010 | SCRATCH | RW | 0x00000000 | Scratch register, no effect on the core |

Unlisted bits read 0 and ignore writes. Reset "core": the register reads the core's outputs directly, so after reset it shows the core's own reset state. WO (pulse) registers read 0. Offsets from 0x014 up to 0xFFC are unmapped (PSLVERR).

### Fields

| Register | Bits | Field | Access | Reset | Description |
|---|---|---|---|---|---|
| ID | 31:16 | CODE | RO | 0x4A54 | IP code |
| ID | 15:8 | MAJOR | RO | 0x02 | major version |
| ID | 7:0 | MINOR | RO | 0x00 | minor version |
| IRQ_STATUS | 0 | one bit per interrupt | W1C | 0x0 | see Interrupts |
| IRQ_ENABLE | 0 | one bit per interrupt | RW | 0x0 | 1 enables the IRQ_STATUS bit onto `irq` |
| SCRATCH | 31:0 | SCRATCH | RW | 0x00000000 | free for software |

### Interrupts (IRQ_STATUS, IRQ_ENABLE)

A bit is set while its source is active, stays set until written with 1, and a set in the same clock as the clear wins.

| Bit | Name | Set when |
|---|---|---|
| 0 | USER_UPDATE | the debugger wrote the USER register (Update-DR with IR = USER), seen three PCLK edges later through the TCK-to-PCLK synchroniser |

## Programming sequence

1. Release PRESETN. Read ID (0x000) and check it is 0x4A540200.
2. Write 0x1 to IRQ_STATUS (0x004) to clear any stale bits.
3. Write IRQ_ENABLE (0x008) with the interrupts to use (bit order as in the Interrupts table; 0x1 enables all).
4. On `irq`: read IRQ_STATUS, handle every bit that is set and enabled, then write those bits back to IRQ_STATUS to clear them. A source that is still active sets its bit again.

## Verification

Five-metric coverage with Verilator 5.052 (`scripts/cov/run_cov.sh`); see [COVERAGE_CLOSURE.md](../COVERAGE_CLOSURE.md) for the flow. Line and toggle count only the named RTL file.

| Scope | Test | Line | Toggle | FSM | SVA | Functional |
|---|---|---|---|---|---|---|
| core `rtl/JTAG_top.sv` | pass | 86/86 | 150/150 | 48/48 | 6/6 | 83/83 |
| wrapper `rtl/JTAG_apb.sv` | pass | 19/19 | 402/402 | n/a | 7/7 | 23/23 |
