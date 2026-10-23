# AMBA AXI3 subordinate: a 256-word memory, INCR and FIXED bursts of up to 16 beats with byte strobes and WID, independent read and write paths, SLVERR and DECERR responses

Protocol IP `AXI`, version 2.0. Apache-2.0.

## Overview

AXI (AXI3-style) protocol -- real AXI3 slave IP: 5 channel handshakes, INCR/FIXED bursts (len 1..16, len field [3:0]), write data channel carries WID (write interleaving NOT supported: WID must match the accepted AWID, beats are processed strictly in order), byte strobes, true valid/ready backpressure, SLVERR on out-of-range / misaligned / WRAP / WID mismatch, DECERR on unsupported size/burst encoding. 256x32 register file target. Simplifications: single outstanding transaction per direction, no write interleaving, awsize <= log2(DW/8), WRAP treated as error.


The AW, W, B, AR and R channel pins (awid ... rready, with wid) are the AXI3 subordinate pins; they pass through unchanged. The registers report the subordinate's error event.
One transaction at a time per direction, any ID, no write interleaving. DECERR: a size above 4 bytes or the reserved burst type. SLVERR: a burst starting outside bytes 0x000 to 0x3FF or misaligned, a WRAP burst, an INCR burst running past 0x3FF (from that beat on), a WID other than the AWID, a WLAST early or missing. Writes are dropped from the first error on.

## Files

| File | Content |
|---|---|
| `rtl/AXI_top.sv` | protocol core |
| `rtl/AXI_apb.sv` | APB4 register wrapper (generated) |
| `tb/AXI_tb.sv` | core testbench |
| `tb/AXI_apb_tb.sv`, `tb/apb/AXI_apb_func.svh` | wrapper testbench (generated part + IP-specific part) |
| `tb/cov/AXI_sva.sv`, `tb/cov/AXI_apb_sva.sv` | coverage checkers (core, wrapper) |
| `scripts/apb/specs/AXI.json` | register spec the wrapper, TB, checker and this page are generated from |

```
make -f Makefile.AXI sim syn            # core test + synthesis (Icarus, Yosys)
make -f Makefile.AXI apb                # wrapper test + synthesis
bash scripts/cov/run_cov.sh AXI          # core coverage (Verilator)
bash scripts/cov/run_cov.sh AXI_apb      # wrapper coverage
```

## Core ports

| Port | Dir | Width | In the APB wrapper |
|---|---|---|---|
| `clk` | input | 1 | PCLK |
| `rst_n` | input | 1 | PRESETN |
| `awid` | input | 4 | pin (pass-through) |
| `awaddr` | input | 32 | pin (pass-through) |
| `awlen` | input | 4 | pin (pass-through) |
| `awsize` | input | 3 | pin (pass-through) |
| `awburst` | input | 2 | pin (pass-through) |
| `awvalid` | input | 1 | pin (pass-through) |
| `awready` | output | 1 | pin (pass-through) |
| `wid` | input | 4 | pin (pass-through) |
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
| `arlen` | input | 4 | pin (pass-through) |
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

`AXI_apb` is an APB4 slave (AMBA APB protocol v2.0): zero wait states, 32-bit data, 12-bit byte address, PSTRB byte lanes on every writable register, PSLVERR on an unmapped or misaligned address (reads then return 0, writes are dropped). Writes to read-only registers are ignored without an error. The core runs on PCLK and PRESETN. `irq` is level-high: `|(IRQ_STATUS & IRQ_ENABLE)`.

Pass-through pins: `awid`, `awaddr`, `awlen`, `awsize`, `awburst`, `awvalid`, `awready`, `wid`, `wdata`, `wstrb`, `wlast`, `wvalid`, `wready`, `bid`, `bresp`, `bvalid`, `bready`, `arid`, `araddr`, `arlen`, `arsize`, `arburst`, `arvalid`, `arready`, `rid`, `rdata`, `rresp`, `rlast`, `rvalid`, `rready`.

### Register map

| Offset | Name | Access | Reset | Description |
|---|---|---|---|---|
| 0x000 | ID | RO | 0x41330200 | IP identification: code, major and minor version |
| 0x004 | IRQ_STATUS | W1C | 0x00000000 | Sticky interrupt bits, write 1 to clear |
| 0x008 | IRQ_ENABLE | RW | 0x00000000 | Interrupt enables; irq = \|(IRQ_STATUS & IRQ_ENABLE) |
| 0x00C | FLAGS | RO | 0x00000000 | Stream holding-register state |
| 0x010 | SCRATCH | RW | 0x00000000 | Scratch register, no effect on the core |

### Fields

| Register | Bits | Field | Description |
|---|---|---|---|
| ID | 31:16 | CODE | 0x4133 |
| ID | 15:8 | MAJOR | 2 |
| ID | 7:0 | MINOR | 0 |

### Interrupts (IRQ_STATUS, IRQ_ENABLE)

A bit is set while its source is active, stays set until written with 1, and a set in the same clock as the clear wins.

| Bit | Name | Set when |
|---|---|---|
| 0 | ERR | a transfer got SLVERR or DECERR, or a write burst's WLAST came early or not at all, or a WID did not match the AWID; the core holds this until reset, so the bit cannot be cleared before then |

## Verification

Five-metric coverage with Verilator 5.052 (`scripts/cov/run_cov.sh`); see [COVERAGE_CLOSURE.md](../COVERAGE_CLOSURE.md) for the flow. Line and toggle count only the named RTL file.

| Scope | Test | Line | Toggle | FSM | SVA | Functional |
|---|---|---|---|---|---|---|
| core `rtl/AXI_top.sv` | pass | 60/60 (+1 excl.) | 650/650 | 10/10 | 16/16 | 63/63 |
| wrapper `rtl/AXI_apb.sv` | pass | 19/19 | 764/764 | n/a | 7/7 | 23/23 |
