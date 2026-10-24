# AMBA ACE cached interface: AXI4 channels into a 64-line write-back cache model, with the AC / CR / CD snoop channels answering ReadShared, ReadClean, CleanInvalid and MakeInvalid

Protocol IP `ACE`, version 2.0. Apache-2.0.

| Item | Value |
|---|---|
| Core | `ACE_top` (`rtl/ACE_top.sv`) |
| Register interface | APB4 slave `ACE_apb`, 32-bit data, 12-bit byte address, zero wait states |
| Clock, reset | PCLK (rising edge), PRESETN (active low, asynchronous) |
| ID register | 0x41430200 (code 0x4143, version 2.0) |
| Registers | 5 words, 0x000 to 0x010 |
| Interrupts | 1 sources into one level-high `irq` |
| Protocol pins | 42 pass-through |

## Overview

ACE (AXI Coherency Extension) -- synthesizable ACE cached-master/slave model Scope: AXI4 main channels (AW/W/B/AR/R, INCR burst) + ACE snoop channels (AC/CR/CD) with an internal 64-line cache model (valid/dirty/tag/data). Dirty-hit snoops return data on CD; MakeInvalid/CleanInvalid invalidate.

The AW, W, B, AR and R channel pins with their ACE fields, and the AC, CR and CD snoop channel pins, pass through unchanged. The registers report the error event.
The cache is 64 direct-mapped one-word lines (index address[7:2], tag address[31:8]). A write fills its line (valid, dirty) with byte strobes; a read returns the line on a tag hit, 0 otherwise. A snoop is accepted only while no write is in progress, and a write address only while no snoop is: ReadShared / ReadClean on a hit return the line on CD (IsShared, PassDirty and WasUnique when it was dirty) and leave it clean; CleanInvalid on a hit invalidates it and returns the data when it was dirty; MakeInvalid invalidates the index; other snoops get an empty response. The CR Error bit is never set (waived), nor bit 0 of BRESP / RRESP.

## Files

| File | Content |
|---|---|
| `rtl/ACE_top.sv` | protocol core |
| `rtl/ACE_apb.sv` | APB4 register wrapper (generated) |
| `tb/ACE_tb.sv` | core testbench |
| `tb/ACE_apb_tb.sv`, `tb/apb/ACE_apb_func.svh` | wrapper testbench (generated part + IP-specific part) |
| `tb/cov/ACE_sva.sv`, `tb/cov/ACE_apb_sva.sv` | coverage checkers (core, wrapper) |
| `scripts/apb/specs/ACE.json` | register spec the wrapper, TB, checker and this page are generated from |

```
make -f Makefile.ACE sim syn            # core test + synthesis (Icarus, Yosys)
make -f Makefile.ACE apb                # wrapper test + synthesis
bash scripts/cov/run_cov.sh ACE          # core coverage (Verilator)
bash scripts/cov/run_cov.sh ACE_apb      # wrapper coverage
```

## Parameters

`ACE_apb` has the core's parameters and passes them to `ACE_top` unchanged.

| Parameter | Type | Default |
|---|---|---|
| `DW` | int | `32` |
| `AW` | int | `32` |

## Wrapper pins

Pins of `ACE_apb`. Widths of the pass-through pins are at the default parameters.

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
| `awvalid` | input | 1 | protocol pin, core port `awvalid` |
| `awready` | output | 1 | protocol pin, core port `awready` |
| `awaddr` | input | 32 | protocol pin, core port `awaddr` |
| `awlen` | input | 8 | protocol pin, core port `awlen` |
| `awsize` | input | 3 | protocol pin, core port `awsize` |
| `awburst` | input | 2 | protocol pin, core port `awburst` |
| `awsnoop` | input | 3 | protocol pin, core port `awsnoop` |
| `awdomain` | input | 2 | protocol pin, core port `awdomain` |
| `awbar` | input | 2 | protocol pin, core port `awbar` |
| `wvalid` | input | 1 | protocol pin, core port `wvalid` |
| `wready` | output | 1 | protocol pin, core port `wready` |
| `wdata` | input | 32 | protocol pin, core port `wdata` |
| `wstrb` | input | 4 | protocol pin, core port `wstrb` |
| `wlast` | input | 1 | protocol pin, core port `wlast` |
| `bvalid` | output | 1 | protocol pin, core port `bvalid` |
| `bready` | input | 1 | protocol pin, core port `bready` |
| `bresp` | output | 2 | protocol pin, core port `bresp` |
| `arvalid` | input | 1 | protocol pin, core port `arvalid` |
| `arready` | output | 1 | protocol pin, core port `arready` |
| `araddr` | input | 32 | protocol pin, core port `araddr` |
| `arlen` | input | 8 | protocol pin, core port `arlen` |
| `arsize` | input | 3 | protocol pin, core port `arsize` |
| `arburst` | input | 2 | protocol pin, core port `arburst` |
| `arsnoop` | input | 4 | protocol pin, core port `arsnoop` |
| `ardomain` | input | 2 | protocol pin, core port `ardomain` |
| `arbar` | input | 2 | protocol pin, core port `arbar` |
| `rvalid` | output | 1 | protocol pin, core port `rvalid` |
| `rready` | input | 1 | protocol pin, core port `rready` |
| `rdata` | output | 32 | protocol pin, core port `rdata` |
| `rresp` | output | 2 | protocol pin, core port `rresp` |
| `rlast` | output | 1 | protocol pin, core port `rlast` |
| `acvalid` | input | 1 | protocol pin, core port `acvalid` |
| `acready` | output | 1 | protocol pin, core port `acready` |
| `acaddr` | input | 32 | protocol pin, core port `acaddr` |
| `acsnoop` | input | 4 | protocol pin, core port `acsnoop` |
| `crvalid` | output | 1 | protocol pin, core port `crvalid` |
| `crready` | input | 1 | protocol pin, core port `crready` |
| `crresp` | output | 5 | protocol pin, core port `crresp` |
| `cdvalid` | output | 1 | protocol pin, core port `cdvalid` |
| `cdready` | input | 1 | protocol pin, core port `cdready` |
| `cddata` | output | 32 | protocol pin, core port `cddata` |
| `cdlast` | output | 1 | protocol pin, core port `cdlast` |

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
| `acvalid` | input | 1 | pin (pass-through) |
| `acready` | output | 1 | pin (pass-through) |
| `acaddr` | input | 32 | pin (pass-through) |
| `acsnoop` | input | 4 | pin (pass-through) |
| `crvalid` | output | 1 | pin (pass-through) |
| `crready` | input | 1 | pin (pass-through) |
| `crresp` | output | 5 | pin (pass-through) |
| `cdvalid` | output | 1 | pin (pass-through) |
| `cdready` | input | 1 | pin (pass-through) |
| `cddata` | output | 32 | pin (pass-through) |
| `cdlast` | output | 1 | pin (pass-through) |
| `irq` | output | 1 | IRQ_STATUS.ERR |

## APB wrapper

`ACE_apb` is an APB4 slave (AMBA APB protocol v2.0): zero wait states, 32-bit data, 12-bit byte address, PSTRB byte lanes on every writable register, PSLVERR on an unmapped or misaligned address (reads then return 0, writes are dropped). Writes to read-only registers are ignored without an error. The core runs on PCLK and PRESETN. `irq` is level-high: `|(IRQ_STATUS & IRQ_ENABLE)`.

Pass-through pins: `awvalid`, `awready`, `awaddr`, `awlen`, `awsize`, `awburst`, `awsnoop`, `awdomain`, `awbar`, `wvalid`, `wready`, `wdata`, `wstrb`, `wlast`, `bvalid`, `bready`, `bresp`, `arvalid`, `arready`, `araddr`, `arlen`, `arsize`, `arburst`, `arsnoop`, `ardomain`, `arbar`, `rvalid`, `rready`, `rdata`, `rresp`, `rlast`, `acvalid`, `acready`, `acaddr`, `acsnoop`, `crvalid`, `crready`, `crresp`, `cdvalid`, `cdready`, `cddata`, `cdlast`.

### Register map

| Offset | Name | Access | Reset | Description |
|---|---|---|---|---|
| 0x000 | ID | RO | 0x41430200 | IP identification: code, major and minor version |
| 0x004 | IRQ_STATUS | W1C | 0x00000000 | Sticky interrupt bits, write 1 to clear |
| 0x008 | IRQ_ENABLE | RW | 0x00000000 | Interrupt enables; irq = \|(IRQ_STATUS & IRQ_ENABLE) |
| 0x00C | FLAGS | RO | 0x00000000 | Stream holding-register state |
| 0x010 | SCRATCH | RW | 0x00000000 | Scratch register, no effect on the core |

Unlisted bits read 0 and ignore writes. Reset "core": the register reads the core's outputs directly, so after reset it shows the core's own reset state. WO (pulse) registers read 0. Offsets from 0x014 up to 0xFFC are unmapped (PSLVERR).

### Fields

| Register | Bits | Field | Access | Reset | Description |
|---|---|---|---|---|---|
| ID | 31:16 | CODE | RO | 0x4143 | IP code |
| ID | 15:8 | MAJOR | RO | 0x02 | major version |
| ID | 7:0 | MINOR | RO | 0x00 | minor version |
| IRQ_STATUS | 0 | one bit per interrupt | W1C | 0x0 | see Interrupts |
| IRQ_ENABLE | 0 | one bit per interrupt | RW | 0x0 | 1 enables the IRQ_STATUS bit onto `irq` |
| SCRATCH | 31:0 | SCRATCH | RW | 0x00000000 | free for software |

### Interrupts (IRQ_STATUS, IRQ_ENABLE)

A bit is set while its source is active, stays set until written with 1, and a set in the same clock as the clear wins.

| Bit | Name | Set when |
|---|---|---|
| 0 | ERR | a read or write burst ended with SLVERR: a burst type other than INCR, a size above 4 bytes, or a start at or above 64 KB |

## Programming sequence

1. Release PRESETN. Read ID (0x000) and check it is 0x41430200.
2. Write 0x1 to IRQ_STATUS (0x004) to clear any stale bits.
3. Write IRQ_ENABLE (0x008) with the interrupts to use (bit order as in the Interrupts table; 0x1 enables all).
4. On `irq`: read IRQ_STATUS, handle every bit that is set and enabled, then write those bits back to IRQ_STATUS to clear them. A source that is still active sets its bit again.

## Verification

Five-metric coverage with Verilator 5.052 (`scripts/cov/run_cov.sh`); see [COVERAGE_CLOSURE.md](../COVERAGE_CLOSURE.md) for the flow. Line and toggle count only the named RTL file.

| Scope | Test | Line | Toggle | FSM | SVA | Functional |
|---|---|---|---|---|---|---|
| core `rtl/ACE_top.sv` | pass | 61/61 (+2 excl.) | 1128/1128 (+6 excl.) | 17/17 | 16/16 | 78/78 |
| wrapper `rtl/ACE_apb.sv` | pass | 19/19 | 930/930 (+6 excl.) | n/a | 7/7 | 23/23 |
