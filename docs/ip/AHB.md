# AMBA 3 AHB-Lite subordinate: a 256-word memory with a wait-state region and a two-cycle ERROR region

Protocol IP `AHB`, version 2.0. Apache-2.0.

## Overview

AHB-Lite slave -- address/data phase pipelined, BUSY/IDLE, wait states, two-cycle ERROR response, 256x32 register file Address map (byte addresses): 0x000-0x3FF : fast region, zero wait state   (256 x 32 register file) 0x400-0x7FF : slow region, one wait state    (same register file) 0x800+      : reserved  -> two-cycle ERROR response + irq event


hsel, htrans, haddr, hwrite, hsize, hwdata, hrdata, hready, hreadyout and hresp are the AHB-Lite subordinate pins; they pass through unchanged. The registers report the subordinate's error events.
Address map seen on AHB (HADDR[11:10]): 00 memory, zero wait states; 01 the same memory with one wait state; 1x reserved, ERROR. HADDR[9:2] selects the word; other bits are ignored.

## Files

| File | Content |
|---|---|
| `rtl/AHB_top.sv` | protocol core |
| `rtl/AHB_apb.sv` | APB4 register wrapper (generated) |
| `tb/AHB_tb.sv` | core testbench |
| `tb/AHB_apb_tb.sv`, `tb/apb/AHB_apb_func.svh` | wrapper testbench (generated part + IP-specific part) |
| `tb/cov/AHB_sva.sv`, `tb/cov/AHB_apb_sva.sv` | coverage checkers (core, wrapper) |
| `scripts/apb/specs/AHB.json` | register spec the wrapper, TB, checker and this page are generated from |

```
make -f Makefile.AHB sim syn            # core test + synthesis (Icarus, Yosys)
make -f Makefile.AHB apb                # wrapper test + synthesis
bash scripts/cov/run_cov.sh AHB          # core coverage (Verilator)
bash scripts/cov/run_cov.sh AHB_apb      # wrapper coverage
```

## Core ports

| Port | Dir | Width | In the APB wrapper |
|---|---|---|---|
| `clk` | input | 1 | PCLK |
| `rst_n` | input | 1 | PRESETN |
| `hsel` | input | 1 | pin (pass-through) |
| `htrans` | input | 2 | pin (pass-through) |
| `haddr` | input | 32 | pin (pass-through) |
| `hwrite` | input | 1 | pin (pass-through) |
| `hsize` | input | 3 | pin (pass-through) |
| `hwdata` | input | 32 | pin (pass-through) |
| `hrdata` | output | 32 | pin (pass-through) |
| `hready` | input | 1 | pin (pass-through) |
| `hreadyout` | output | 1 | pin (pass-through) |
| `hresp` | output | 1 | pin (pass-through) |
| `irq` | output | 1 | IRQ_STATUS.ERR |

## APB wrapper

`AHB_apb` is an APB4 slave (AMBA APB protocol v2.0): zero wait states, 32-bit data, 12-bit byte address, PSTRB byte lanes on every writable register, PSLVERR on an unmapped or misaligned address (reads then return 0, writes are dropped). Writes to read-only registers are ignored without an error. The core runs on PCLK and PRESETN. `irq` is level-high: `|(IRQ_STATUS & IRQ_ENABLE)`.

Pass-through pins: `hsel`, `htrans`, `haddr`, `hwrite`, `hsize`, `hwdata`, `hrdata`, `hready`, `hreadyout`, `hresp`.

### Register map

| Offset | Name | Access | Reset | Description |
|---|---|---|---|---|
| 0x000 | ID | RO | 0x41480200 | IP identification: code, major and minor version |
| 0x004 | IRQ_STATUS | W1C | 0x00000000 | Sticky interrupt bits, write 1 to clear |
| 0x008 | IRQ_ENABLE | RW | 0x00000000 | Interrupt enables; irq = \|(IRQ_STATUS & IRQ_ENABLE) |
| 0x00C | FLAGS | RO | 0x00000000 | Stream holding-register state |
| 0x010 | SCRATCH | RW | 0x00000000 | Scratch register, no effect on the core |

### Fields

| Register | Bits | Field | Description |
|---|---|---|---|
| ID | 31:16 | CODE | 0x4148 |
| ID | 15:8 | MAJOR | 2 |
| ID | 7:0 | MINOR | 0 |

### Interrupts (IRQ_STATUS, IRQ_ENABLE)

A bit is set while its source is active, stays set until written with 1, and a set in the same clock as the clear wins.

| Bit | Name | Set when |
|---|---|---|
| 0 | ERR | a transfer to the reserved region (HADDR[11] set) got the two-cycle ERROR response |

## Verification

Five-metric coverage with Verilator 5.052 (`scripts/cov/run_cov.sh`); see [COVERAGE_CLOSURE.md](../COVERAGE_CLOSURE.md) for the flow. Line and toggle count only the named RTL file.

| Scope | Test | Line | Toggle | FSM | SVA | Functional |
|---|---|---|---|---|---|---|
| core `rtl/AHB_top.sv` | pass | 28/28 (+2 excl.) | 298/298 | 6/6 | 12/12 | 23/23 |
| wrapper `rtl/AHB_apb.sv` | pass | 19/19 | 604/604 | n/a | 7/7 | 23/23 |
