# IEEE 1149.1 JTAG TAP controller: 16-state TAP, 4-bit IR, IDCODE (0x1CAF0001), BYPASS and an 8-bit USER data register

Protocol IP `JTAG`, version 2.0. Apache-2.0.

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

### Fields

| Register | Bits | Field | Description |
|---|---|---|---|
| ID | 31:16 | CODE | 0x4A54 |
| ID | 15:8 | MAJOR | 2 |
| ID | 7:0 | MINOR | 0 |

### Interrupts (IRQ_STATUS, IRQ_ENABLE)

A bit is set while its source is active, stays set until written with 1, and a set in the same clock as the clear wins.

| Bit | Name | Set when |
|---|---|---|
| 0 | USER_UPDATE | the debugger wrote the USER register (Update-DR with IR = USER), seen three PCLK edges later through the TCK-to-PCLK synchroniser |

## Verification

Five-metric coverage with Verilator 5.052 (`scripts/cov/run_cov.sh`); see [COVERAGE_CLOSURE.md](../COVERAGE_CLOSURE.md) for the flow. Line and toggle count only the named RTL file.

| Scope | Test | Line | Toggle | FSM | SVA | Functional |
|---|---|---|---|---|---|---|
| core `rtl/JTAG_top.sv` | pass | 86/86 | 150/150 | 48/48 | 6/6 | 10/10 |
| wrapper `rtl/JTAG_apb.sv` | pass | 19/19 | 402/402 | n/a | 7/7 | 23/23 |
