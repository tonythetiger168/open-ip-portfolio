# AMBA AXI4-Lite subordinate: a 256-word memory with byte strobes, independent read and write paths, SLVERR outside the memory

Protocol IP `AXI4_Lite`, version 2.0. Apache-2.0.

| Item | Value |
|---|---|
| Core | `AXI4_Lite_top` (`rtl/AXI4_Lite_top.sv`) |
| Register interface | APB4 slave `AXI4_Lite_apb`, 32-bit data, 12-bit byte address, zero wait states |
| Clock, reset | PCLK (rising edge), PRESETN (active low, asynchronous) |
| ID register | 0x414C0200 (code 0x414C, version 2.0) |
| Registers | 5 words, 0x000 to 0x010 |
| Interrupts | 1 sources into one level-high `irq` |
| Protocol pins | 17 pass-through |

## Overview

AXI4-Lite protocol -- real AXI4-Lite slave IP: 5 channel handshakes, single-beat transfers only (no awlen/wlast), byte strobes, true valid/ready backpressure, SLVERR on out-of-range / misaligned access. 256x32 register file as the slave memory target.

awaddr, awvalid, awready, wdata, wstrb, wvalid, wready, bresp, bvalid, bready, araddr, arvalid, arready, rdata, rresp, rvalid and rready are the AXI4-Lite subordinate pins; they pass through unchanged. The registers report the subordinate's error event.
The memory is bytes 0x000 to 0x3FF; an address above it or not word aligned gets SLVERR (a write is dropped, a read returns 0). Only OKAY and SLVERR are returned, so bresp[0] and rresp[0] are constant 0 (waived).

## Files

| File | Content |
|---|---|
| `rtl/AXI4_Lite_top.sv` | protocol core |
| `rtl/AXI4_Lite_apb.sv` | APB4 register wrapper (generated) |
| `tb/AXI4_Lite_tb.sv` | core testbench |
| `tb/AXI4_Lite_apb_tb.sv`, `tb/apb/AXI4_Lite_apb_func.svh` | wrapper testbench (generated part + IP-specific part) |
| `tb/cov/AXI4_Lite_sva.sv`, `tb/cov/AXI4_Lite_apb_sva.sv` | coverage checkers (core, wrapper) |
| `scripts/apb/specs/AXI4_Lite.json` | register spec the wrapper, TB, checker and this page are generated from |

```
make -f Makefile.AXI4_Lite sim syn            # core test + synthesis (Icarus, Yosys)
make -f Makefile.AXI4_Lite apb                # wrapper test + synthesis
bash scripts/cov/run_cov.sh AXI4_Lite          # core coverage (Verilator)
bash scripts/cov/run_cov.sh AXI4_Lite_apb      # wrapper coverage
```

## Parameters

`AXI4_Lite_apb` has the core's parameters and passes them to `AXI4_Lite_top` unchanged.

| Parameter | Type | Default |
|---|---|---|
| `DW` | int | `32` |
| `AW` | int | `32` |

## Wrapper pins

Pins of `AXI4_Lite_apb`. Widths of the pass-through pins are at the default parameters.

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
| `awaddr` | input | 32 | protocol pin, core port `awaddr` |
| `awvalid` | input | 1 | protocol pin, core port `awvalid` |
| `awready` | output | 1 | protocol pin, core port `awready` |
| `wdata` | input | 32 | protocol pin, core port `wdata` |
| `wstrb` | input | 4 | protocol pin, core port `wstrb` |
| `wvalid` | input | 1 | protocol pin, core port `wvalid` |
| `wready` | output | 1 | protocol pin, core port `wready` |
| `bresp` | output | 2 | protocol pin, core port `bresp` |
| `bvalid` | output | 1 | protocol pin, core port `bvalid` |
| `bready` | input | 1 | protocol pin, core port `bready` |
| `araddr` | input | 32 | protocol pin, core port `araddr` |
| `arvalid` | input | 1 | protocol pin, core port `arvalid` |
| `arready` | output | 1 | protocol pin, core port `arready` |
| `rdata` | output | 32 | protocol pin, core port `rdata` |
| `rresp` | output | 2 | protocol pin, core port `rresp` |
| `rvalid` | output | 1 | protocol pin, core port `rvalid` |
| `rready` | input | 1 | protocol pin, core port `rready` |

## Core ports

| Port | Dir | Width | In the APB wrapper |
|---|---|---|---|
| `clk` | input | 1 | PCLK |
| `rst_n` | input | 1 | PRESETN |
| `awaddr` | input | 32 | pin (pass-through) |
| `awvalid` | input | 1 | pin (pass-through) |
| `awready` | output | 1 | pin (pass-through) |
| `wdata` | input | 32 | pin (pass-through) |
| `wstrb` | input | 4 | pin (pass-through) |
| `wvalid` | input | 1 | pin (pass-through) |
| `wready` | output | 1 | pin (pass-through) |
| `bresp` | output | 2 | pin (pass-through) |
| `bvalid` | output | 1 | pin (pass-through) |
| `bready` | input | 1 | pin (pass-through) |
| `araddr` | input | 32 | pin (pass-through) |
| `arvalid` | input | 1 | pin (pass-through) |
| `arready` | output | 1 | pin (pass-through) |
| `rdata` | output | 32 | pin (pass-through) |
| `rresp` | output | 2 | pin (pass-through) |
| `rvalid` | output | 1 | pin (pass-through) |
| `rready` | input | 1 | pin (pass-through) |
| `irq` | output | 1 | IRQ_STATUS.ERR |

## APB wrapper

`AXI4_Lite_apb` is an APB4 slave (AMBA APB protocol v2.0): zero wait states, 32-bit data, 12-bit byte address, PSTRB byte lanes on every writable register, PSLVERR on an unmapped or misaligned address (reads then return 0, writes are dropped). Writes to read-only registers are ignored without an error. The core runs on PCLK and PRESETN. `irq` is level-high: `|(IRQ_STATUS & IRQ_ENABLE)`.

Pass-through pins: `awaddr`, `awvalid`, `awready`, `wdata`, `wstrb`, `wvalid`, `wready`, `bresp`, `bvalid`, `bready`, `araddr`, `arvalid`, `arready`, `rdata`, `rresp`, `rvalid`, `rready`.

### Register map

| Offset | Name | Access | Reset | Description |
|---|---|---|---|---|
| 0x000 | ID | RO | 0x414C0200 | IP identification: code, major and minor version |
| 0x004 | IRQ_STATUS | W1C | 0x00000000 | Sticky interrupt bits, write 1 to clear |
| 0x008 | IRQ_ENABLE | RW | 0x00000000 | Interrupt enables; irq = \|(IRQ_STATUS & IRQ_ENABLE) |
| 0x00C | FLAGS | RO | 0x00000000 | Stream holding-register state |
| 0x010 | SCRATCH | RW | 0x00000000 | Scratch register, no effect on the core |

Unlisted bits read 0 and ignore writes. Reset "core": the register reads the core's outputs directly, so after reset it shows the core's own reset state. WO (pulse) registers read 0. Offsets from 0x014 up to 0xFFC are unmapped (PSLVERR).

### Fields

| Register | Bits | Field | Access | Reset | Description |
|---|---|---|---|---|---|
| ID | 31:16 | CODE | RO | 0x414C | IP code |
| ID | 15:8 | MAJOR | RO | 0x02 | major version |
| ID | 7:0 | MINOR | RO | 0x00 | minor version |
| IRQ_STATUS | 0 | one bit per interrupt | W1C | 0x0 | see Interrupts |
| IRQ_ENABLE | 0 | one bit per interrupt | RW | 0x0 | 1 enables the IRQ_STATUS bit onto `irq` |
| SCRATCH | 31:0 | SCRATCH | RW | 0x00000000 | free for software |

### Interrupts (IRQ_STATUS, IRQ_ENABLE)

A bit is set while its source is active, stays set until written with 1, and a set in the same clock as the clear wins.

| Bit | Name | Set when |
|---|---|---|
| 0 | ERR | an access outside the memory or misaligned was accepted (SLVERR); the core holds this until reset, so the bit cannot be cleared before then |

## Programming sequence

1. Release PRESETN. Read ID (0x000) and check it is 0x414C0200.
2. Write 0x1 to IRQ_STATUS (0x004) to clear any stale bits.
3. Write IRQ_ENABLE (0x008) with the interrupts to use (bit order as in the Interrupts table; 0x1 enables all).
4. On `irq`: read IRQ_STATUS, handle every bit that is set and enabled, then write those bits back to IRQ_STATUS to clear them. A source that is still active sets its bit again.

## Verification

Five-metric coverage with Verilator 5.052 (`scripts/cov/run_cov.sh`); see [COVERAGE_CLOSURE.md](../COVERAGE_CLOSURE.md) for the flow. Line and toggle count only the named RTL file.

| Scope | Test | Line | Toggle | FSM | SVA | Functional |
|---|---|---|---|---|---|---|
| core `rtl/AXI4_Lite_top.sv` | pass | 39/39 (+1 excl.) | 510/510 (+4 excl.) | 10/10 | 13/13 | 18/18 |
| wrapper `rtl/AXI4_Lite_apb.sv` | pass | 19/19 | 684/684 (+4 excl.) | n/a | 7/7 | 23/23 |
