# AMBA AXI4 subordinate: a 256-word memory, INCR and FIXED bursts of up to 16 beats with byte strobes, independent read and write paths, SLVERR and DECERR responses

Protocol IP `AXI4`, version 2.0. Apache-2.0.

## Overview

AXI4 protocol -- real AXI4 slave IP: 5 independent channel handshakes, INCR/FIXED bursts (len 1..16), byte strobes, true valid/ready backpressure, SLVERR on out-of-range / misaligned / WRAP, DECERR on unsupported ID/size/ burst/len. 256x32 register file as the slave memory target. Simplifications: single outstanding transaction per direction, ID==0 only, awsize <= log2(DW/8), WRAP treated as error.


The AW, W, B, AR and R channel pins (awid ... rready) are the AXI4 subordinate pins; they pass through unchanged. The registers report the subordinate's error event.
One transaction at a time per direction. DECERR: an ID other than 0, a size above 4 bytes, the reserved burst type or a length above 16 beats. SLVERR: a burst starting outside bytes 0x000 to 0x3FF or misaligned, a WRAP burst, an INCR burst running past 0x3FF (from that beat on), a WLAST early or missing. Writes are dropped from the first error on.

## Files

| File | Content |
|---|---|
| `rtl/AXI4_top.sv` | protocol core |
| `rtl/AXI4_apb.sv` | APB4 register wrapper (generated) |
| `tb/AXI4_tb.sv` | core testbench |
| `tb/AXI4_apb_tb.sv`, `tb/apb/AXI4_apb_func.svh` | wrapper testbench (generated part + IP-specific part) |
| `tb/cov/AXI4_sva.sv`, `tb/cov/AXI4_apb_sva.sv` | coverage checkers (core, wrapper) |
| `scripts/apb/specs/AXI4.json` | register spec the wrapper, TB, checker and this page are generated from |

```
make -f Makefile.AXI4 sim syn            # core test + synthesis (Icarus, Yosys)
make -f Makefile.AXI4 apb                # wrapper test + synthesis
bash scripts/cov/run_cov.sh AXI4          # core coverage (Verilator)
bash scripts/cov/run_cov.sh AXI4_apb      # wrapper coverage
```

## Core ports

| Port | Dir | Width | In the APB wrapper |
|---|---|---|---|
| `clk` | input | 1 | PCLK |
| `rst_n` | input | 1 | PRESETN |
| `awid` | input | 4 | pin (pass-through) |
| `awaddr` | input | 32 | pin (pass-through) |
| `awlen` | input | 8 | pin (pass-through) |
| `awsize` | input | 3 | pin (pass-through) |
| `awburst` | input | 2 | pin (pass-through) |
| `awvalid` | input | 1 | pin (pass-through) |
| `awready` | output | 1 | pin (pass-through) |
| `wdata` | input | 32 | pin (pass-through) |
| `wstrb` | input | 4 | pin (pass-through) |
| `wlast` | input | 1 | pin (pass-through) |
| `wvalid` | input | 1 | pin (pass-through) |
| `wready` | output | 1 | pin (pass-through) |
| `bid` | output | 4 | pin (pass-through) |
| `bresp` | output | 2 | pin (pass-through) |
| `bvalid` | output | 1 | pin (pass-through) |
| `bready` | input | 1 | pin (pass-through) |
| `arid` | input | 4 | pin (pass-through) |
| `araddr` | input | 32 | pin (pass-through) |
| `arlen` | input | 8 | pin (pass-through) |
| `arsize` | input | 3 | pin (pass-through) |
| `arburst` | input | 2 | pin (pass-through) |
| `arvalid` | input | 1 | pin (pass-through) |
| `arready` | output | 1 | pin (pass-through) |
| `rid` | output | 4 | pin (pass-through) |
| `rdata` | output | 32 | pin (pass-through) |
| `rresp` | output | 2 | pin (pass-through) |
| `rlast` | output | 1 | pin (pass-through) |
| `rvalid` | output | 1 | pin (pass-through) |
| `rready` | input | 1 | pin (pass-through) |
| `irq` | output | 1 | IRQ_STATUS.ERR |

## APB wrapper

`AXI4_apb` is an APB4 slave (AMBA APB protocol v2.0): zero wait states, 32-bit data, 12-bit byte address, PSTRB byte lanes on every writable register, PSLVERR on an unmapped or misaligned address (reads then return 0, writes are dropped). Writes to read-only registers are ignored without an error. The core runs on PCLK and PRESETN. `irq` is level-high: `|(IRQ_STATUS & IRQ_ENABLE)`.

Pass-through pins: `awid`, `awaddr`, `awlen`, `awsize`, `awburst`, `awvalid`, `awready`, `wdata`, `wstrb`, `wlast`, `wvalid`, `wready`, `bid`, `bresp`, `bvalid`, `bready`, `arid`, `araddr`, `arlen`, `arsize`, `arburst`, `arvalid`, `arready`, `rid`, `rdata`, `rresp`, `rlast`, `rvalid`, `rready`.

### Register map

| Offset | Name | Access | Reset | Description |
|---|---|---|---|---|
| 0x000 | ID | RO | 0x41340200 | IP identification: code, major and minor version |
| 0x004 | IRQ_STATUS | W1C | 0x00000000 | Sticky interrupt bits, write 1 to clear |
| 0x008 | IRQ_ENABLE | RW | 0x00000000 | Interrupt enables; irq = \|(IRQ_STATUS & IRQ_ENABLE) |
| 0x00C | FLAGS | RO | 0x00000000 | Stream holding-register state |
| 0x010 | SCRATCH | RW | 0x00000000 | Scratch register, no effect on the core |

### Fields

| Register | Bits | Field | Description |
|---|---|---|---|
| ID | 31:16 | CODE | 0x4134 |
| ID | 15:8 | MAJOR | 2 |
| ID | 7:0 | MINOR | 0 |

### Interrupts (IRQ_STATUS, IRQ_ENABLE)

A bit is set while its source is active, stays set until written with 1, and a set in the same clock as the clear wins.

| Bit | Name | Set when |
|---|---|---|
| 0 | ERR | a transfer got SLVERR or DECERR, or a write burst's WLAST came early or not at all; the core holds this until reset, so the bit cannot be cleared before then |

## Verification

Five-metric coverage with Verilator 5.052 (`scripts/cov/run_cov.sh`); see [COVERAGE_CLOSURE.md](../COVERAGE_CLOSURE.md) for the flow. Line and toggle count only the named RTL file.

| Scope | Test | Line | Toggle | FSM | SVA | Functional |
|---|---|---|---|---|---|---|
| core `rtl/AXI4_top.sv` | pass | 59/59 (+1 excl.) | 690/690 | 10/10 | 16/16 | 64/64 |
| wrapper `rtl/AXI4_apb.sv` | pass | 19/19 | 772/772 | n/a | 7/7 | 23/23 |
