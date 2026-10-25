# AMBA ACE-Lite subordinate: a 256-word memory behind AXI4 channels with the ACE-Lite snoop, domain and barrier fields, INCR bursts up to 256 beats with byte strobes, SLVERR

Protocol IP `ACE_Lite`, version 2.0. Apache-2.0.

## Overview

ACE-Lite (AXI Coherency Extension, I/O-coherent subset) -- synthesizable slave Scope: full AXI4 channels (AW/W/B/AR/R, INCR burst) + ACE-Lite fields ARSNOOP/ARDOMAIN/ARBAR/AWSNOOP/AWDOMAIN/AWBAR (accepted; barrier ordering guaranteed by strict in-order completion). No snoop channels. Internal 256x32 word memory; out-of-range access -> SLVERR + irq. Range is checked per beat: an INCR burst that crosses 1KB gets SLVERR on the beats past the end instead of wrapping to word 0.


The AW, W, B, AR and R channel pins, with AWSNOOP / AWDOMAIN / AWBAR and ARSNOOP / ARDOMAIN / ARBAR, are the ACE-Lite subordinate pins; they pass through unchanged. The registers report the subordinate's error event.
One transaction at a time per direction; no ID signals. The ACE-Lite fields are accepted and do not change the transfer: completion is in order. A burst ends at WLAST or after AWLEN + 1 beats, whichever comes first. Beats past 0x3FF get SLVERR and write nothing; a burst that starts in error writes nothing; reads in error return 0.

## Files

| File | Content |
|---|---|
| `rtl/ACE_Lite_top.sv` | protocol core |
| `rtl/ACE_Lite_apb.sv` | APB4 register wrapper (generated) |
| `tb/ACE_Lite_tb.sv` | core testbench |
| `tb/ACE_Lite_apb_tb.sv`, `tb/apb/ACE_Lite_apb_func.svh` | wrapper testbench (generated part + IP-specific part) |
| `tb/cov/ACE_Lite_sva.sv`, `tb/cov/ACE_Lite_apb_sva.sv` | coverage checkers (core, wrapper) |
| `scripts/apb/specs/ACE_Lite.json` | register spec the wrapper, TB, checker and this page are generated from |

```
make -f Makefile.ACE_Lite sim syn            # core test + synthesis (Icarus, Yosys)
make -f Makefile.ACE_Lite apb                # wrapper test + synthesis
bash scripts/cov/run_cov.sh ACE_Lite          # core coverage (Verilator)
bash scripts/cov/run_cov.sh ACE_Lite_apb      # wrapper coverage
```

## Core ports

| Port | Dir | Width | In the APB wrapper |
|---|---|---|---|
| `clk` | input | 1 | PCLK |
| `rst_n` | input | 1 | PRESETN |
| `awvalid` | input | 1 | pin (pass-through) |
| `awready` | output | 1 | pin (pass-through) |
| `awaddr` | input | 32 | pin (pass-through) |
| `awlen` | input | 8 | pin (pass-through) |
| `awsize` | input | 3 | pin (pass-through) |
| `awburst` | input | 2 | pin (pass-through) |
| `awsnoop` | input | 3 | pin (pass-through) |
| `awdomain` | input | 2 | pin (pass-through) |
| `awbar` | input | 2 | pin (pass-through) |
| `wvalid` | input | 1 | pin (pass-through) |
| `wready` | output | 1 | pin (pass-through) |
| `wdata` | input | 32 | pin (pass-through) |
| `wstrb` | input | 4 | pin (pass-through) |
| `wlast` | input | 1 | pin (pass-through) |
| `bvalid` | output | 1 | pin (pass-through) |
| `bready` | input | 1 | pin (pass-through) |
| `bresp` | output | 2 | pin (pass-through) |
| `arvalid` | input | 1 | pin (pass-through) |
| `arready` | output | 1 | pin (pass-through) |
| `araddr` | input | 32 | pin (pass-through) |
| `arlen` | input | 8 | pin (pass-through) |
| `arsize` | input | 3 | pin (pass-through) |
| `arburst` | input | 2 | pin (pass-through) |
| `arsnoop` | input | 4 | pin (pass-through) |
| `ardomain` | input | 2 | pin (pass-through) |
| `arbar` | input | 2 | pin (pass-through) |
| `rvalid` | output | 1 | pin (pass-through) |
| `rready` | input | 1 | pin (pass-through) |
| `rdata` | output | 32 | pin (pass-through) |
| `rresp` | output | 2 | pin (pass-through) |
| `rlast` | output | 1 | pin (pass-through) |
| `irq` | output | 1 | IRQ_STATUS.ERR |

## APB wrapper

`ACE_Lite_apb` is an APB4 slave (AMBA APB protocol v2.0): zero wait states, 32-bit data, 12-bit byte address, PSTRB byte lanes on every writable register, PSLVERR on an unmapped or misaligned address (reads then return 0, writes are dropped). Writes to read-only registers are ignored without an error. The core runs on PCLK and PRESETN. `irq` is level-high: `|(IRQ_STATUS & IRQ_ENABLE)`.

Pass-through pins: `awvalid`, `awready`, `awaddr`, `awlen`, `awsize`, `awburst`, `awsnoop`, `awdomain`, `awbar`, `wvalid`, `wready`, `wdata`, `wstrb`, `wlast`, `bvalid`, `bready`, `bresp`, `arvalid`, `arready`, `araddr`, `arlen`, `arsize`, `arburst`, `arsnoop`, `ardomain`, `arbar`, `rvalid`, `rready`, `rdata`, `rresp`, `rlast`.

### Register map

| Offset | Name | Access | Reset | Description |
|---|---|---|---|---|
| 0x000 | ID | RO | 0x41450200 | IP identification: code, major and minor version |
| 0x004 | IRQ_STATUS | W1C | 0x00000000 | Sticky interrupt bits, write 1 to clear |
| 0x008 | IRQ_ENABLE | RW | 0x00000000 | Interrupt enables; irq = \|(IRQ_STATUS & IRQ_ENABLE) |
| 0x00C | FLAGS | RO | 0x00000000 | Stream holding-register state |
| 0x010 | SCRATCH | RW | 0x00000000 | Scratch register, no effect on the core |

### Fields

| Register | Bits | Field | Description |
|---|---|---|---|
| ID | 31:16 | CODE | 0x4145 |
| ID | 15:8 | MAJOR | 2 |
| ID | 7:0 | MINOR | 0 |

### Interrupts (IRQ_STATUS, IRQ_ENABLE)

A bit is set while its source is active, stays set until written with 1, and a set in the same clock as the clear wins.

| Bit | Name | Set when |
|---|---|---|
| 0 | ERR | a burst ended with SLVERR: a burst type other than INCR, a size above 4 bytes, a start above 0x3FF, or beats running past 0x3FF |

## Verification

Five-metric coverage with Verilator 5.052 (`scripts/cov/run_cov.sh`); see [COVERAGE_CLOSURE.md](../COVERAGE_CLOSURE.md) for the flow. Line and toggle count only the named RTL file.

| Scope | Test | Line | Toggle | FSM | SVA | Functional |
|---|---|---|---|---|---|---|
| core `rtl/ACE_Lite_top.sv` | pass | 41/41 (+1 excl.) | 592/592 (+4 excl.) | 10/10 | 15/15 | 51/51 |
| wrapper `rtl/ACE_Lite_apb.sv` | pass | 19/19 | 770/770 (+4 excl.) | n/a | 7/7 | 23/23 |
