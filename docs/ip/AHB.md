# AMBA 3 AHB-Lite subordinate: a 256-word memory with a wait-state region and a two-cycle ERROR region

Protocol IP `AHB`, version 2.0. Apache-2.0.

| Item | Value |
|---|---|
| Core | `AHB_top` (`rtl/AHB_top.sv`) |
| Register interface | APB4 slave `AHB_apb`, 32-bit data, 12-bit byte address, zero wait states |
| Clock, reset | PCLK (rising edge), PRESETN (active low, asynchronous) |
| ID register | 0x41480200 (code 0x4148, version 2.0) |
| Registers | 5 words, 0x000 to 0x010 |
| Interrupts | 1 sources into one level-high `irq` |
| Protocol pins | 10 pass-through |

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

## Parameters

`AHB_apb` has the core's parameters and passes them to `AHB_top` unchanged.

| Parameter | Type | Default |
|---|---|---|
| `DW` | int | `32` |
| `AW` | int | `32` |
| `DEPTH` | int | `256` |

## Wrapper pins

Pins of `AHB_apb`. Widths of the pass-through pins are at the default parameters.

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
| `hsel` | input | 1 | protocol pin, core port `hsel` |
| `htrans` | input | 2 | protocol pin, core port `htrans` |
| `haddr` | input | 32 | protocol pin, core port `haddr` |
| `hwrite` | input | 1 | protocol pin, core port `hwrite` |
| `hsize` | input | 3 | protocol pin, core port `hsize` |
| `hwdata` | input | 32 | protocol pin, core port `hwdata` |
| `hrdata` | output | 32 | protocol pin, core port `hrdata` |
| `hready` | input | 1 | protocol pin, core port `hready` |
| `hreadyout` | output | 1 | protocol pin, core port `hreadyout` |
| `hresp` | output | 1 | protocol pin, core port `hresp` |

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

Unlisted bits read 0 and ignore writes. Reset "core": the register reads the core's outputs directly, so after reset it shows the core's own reset state. WO (pulse) registers read 0. Offsets from 0x014 up to 0xFFC are unmapped (PSLVERR).

### Fields

| Register | Bits | Field | Access | Reset | Description |
|---|---|---|---|---|---|
| ID | 31:16 | CODE | RO | 0x4148 | IP code |
| ID | 15:8 | MAJOR | RO | 0x02 | major version |
| ID | 7:0 | MINOR | RO | 0x00 | minor version |
| IRQ_STATUS | 0 | one bit per interrupt | W1C | 0x0 | see Interrupts |
| IRQ_ENABLE | 0 | one bit per interrupt | RW | 0x0 | 1 enables the IRQ_STATUS bit onto `irq` |
| SCRATCH | 31:0 | SCRATCH | RW | 0x00000000 | free for software |

### Interrupts (IRQ_STATUS, IRQ_ENABLE)

A bit is set while its source is active, stays set until written with 1, and a set in the same clock as the clear wins.

| Bit | Name | Set when |
|---|---|---|
| 0 | ERR | a transfer to the reserved region (HADDR[11] set) got the two-cycle ERROR response |

## Programming sequence

1. Release PRESETN. Read ID (0x000) and check it is 0x41480200.
2. Write 0x1 to IRQ_STATUS (0x004) to clear any stale bits.
3. Write IRQ_ENABLE (0x008) with the interrupts to use (bit order as in the Interrupts table; 0x1 enables all).
4. On `irq`: read IRQ_STATUS, handle every bit that is set and enabled, then write those bits back to IRQ_STATUS to clear them. A source that is still active sets its bit again.

## Verification

Five-metric coverage with Verilator 5.052 (`scripts/cov/run_cov.sh`); see [COVERAGE_CLOSURE.md](../COVERAGE_CLOSURE.md) for the flow. Line and toggle count only the named RTL file.

| Scope | Test | Line | Toggle | FSM | SVA | Functional |
|---|---|---|---|---|---|---|
| core `rtl/AHB_top.sv` | pass | 28/28 (+2 excl.) | 298/298 | 6/6 | 12/12 | 51/51 |
| wrapper `rtl/AHB_apb.sv` | pass | 19/19 | 604/604 | n/a | 7/7 | 23/23 |
