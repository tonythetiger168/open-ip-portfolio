# Quad-SPI NOR flash controller with execute-in-place: AXI4 read window (quad 0x6B / single 0x0B, stream kept open across bursts) and a register command port

Protocol IP `QSPI_XIP`, version 1.0. Apache-2.0.

| Item | Value |
|---|---|
| Core | `QSPI_XIP_top` (`rtl/QSPI_XIP_top.sv`) |
| Register interface | APB4 slave `QSPI_XIP_apb`, 32-bit data, 12-bit byte address, zero wait states |
| Clock, reset | PCLK (rising edge), PRESETN (active low, asynchronous) |
| ID register | 0x5C530100 (code 0x5C53, version 1.0) |
| Registers | 14 words, 0x000 to 0x034 |
| Interrupts | 1 sources into one level-high `irq` |
| Protocol pins | 32 pass-through |

## Overview

QSPI_XIP: quad-SPI NOR flash controller with execute-in-place (AXI4 subordinate read window, APB4 registers for flash commands) The flash-host role that the QSPI_top target does not cover (boot flash).

- XIP: an AXI4 read of the window reads the flash at addr[23:0] with
QUAD (0x6B, quad output fast read: command and address on IO0, 8 dummy
clocks, data on IO3..0) or, with QUAD = 0, 0x0B (fast read, single).
Bytes are little-endian in a word (flash byte A in bits 8 * A[1:0] + 7 :
8 * A[1:0]). INCR, FIXED and WRAP bursts of any length, AxSIZE 0..2: each
beat returns the word holding its address. The read stays open after a
burst: a burst that starts at the next word of the stream continues it
without a new command; any other address closes chip select and starts
a new read. SCLK stops while R is held off, so RREADY low never loses
data. AXI writes get SLVERR.
- Command port (PC_*): one flash command in single-bit mode: the command
byte, optionally a 24-bit address, PC_NWR (0..4) data bytes from
PC_WDATA (byte 0 first), PC_NRD (0..4) bytes into PC_RDATA (byte 0 in
bits 7:0). Used for 0x05 read status, 0x06 write enable, 0x02 page
program, 0x20 sector erase, 0x9F ID and so on. A command closes the XIP
stream; it waits for an XIP burst in progress, and XIP waits for it.
- SPI mode 0. Half an SCLK period is DIV + 1 clocks. IO2 / IO3 (WP#,
HOLD#) are driven high outside the quad data phase.
- Counters: XIP_CMDS (read commands issued), XIP_BEATS.

Features:

- The flash-host role that the QSPI_top target does not cover: boot and code flash of the SoC.
- XIP: AXI4 reads of the window (INCR / FIXED / WRAP, any length, AxSIZE 0..2) read the flash at addr[23:0], bytes little-endian in a word.
- QUAD = 1 uses 0x6B (quad output fast read), QUAD = 0 uses 0x0B (fast read); 8 dummy clocks either way.
- The read stays open after a burst: a burst starting at the next word continues it without a new command (XIP_CMDS counts commands, XIP_BEATS beats).
- SCLK stops while RREADY is low, so a stalled reader never loses data. AXI writes get SLVERR.
- Command port: one single-bit flash command with an optional 24-bit address, 0..4 bytes out of PC_WDATA and 0..4 bytes into PC_RDATA (byte 0 in bits 7:0).
- SPI mode 0; half an SCLK period is DIV + 1 clocks.

The AXI4 subordinate port (s_*) and the flash pins (sclk, csn, io[3:0]) pass through the wrapper unchanged.
A command closes the open XIP stream and waits for an XIP burst in progress; XIP waits for the command. IO2 / IO3 (WP#, HOLD#) are driven high outside the quad data phase.

## Files

| File | Content |
|---|---|
| `rtl/QSPI_XIP_top.sv` | protocol core |
| `rtl/QSPI_XIP_apb.sv` | APB4 register wrapper (generated) |
| `tb/QSPI_XIP_tb.sv` | core testbench |
| `tb/QSPI_XIP_apb_tb.sv`, `tb/apb/QSPI_XIP_apb_func.svh` | wrapper testbench (generated part + IP-specific part) |
| `tb/cov/QSPI_XIP_sva.sv`, `tb/cov/QSPI_XIP_apb_sva.sv` | coverage checkers (core, wrapper) |
| `scripts/apb/specs/QSPI_XIP.json` | register spec the wrapper, TB, checker and this page are generated from |

How to run the tests and the coverage flow: see [Running and verifying](#running-and-verifying).

## Parameters

The core and the wrapper have no parameters.

## Wrapper pins

Pins of `QSPI_XIP_apb`. Widths of the pass-through pins are at the default parameters.

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
| `sclk` | output | 1 | protocol pin, core port `sclk` |
| `csn` | output | 1 | protocol pin, core port `csn` |
| `io` | inout | 4 | protocol pin, core port `io` |
| `s_awid` | input | 4 | protocol pin, core port `s_awid` |
| `s_awaddr` | input | 32 | protocol pin, core port `s_awaddr` |
| `s_awlen` | input | 8 | protocol pin, core port `s_awlen` |
| `s_awsize` | input | 3 | protocol pin, core port `s_awsize` |
| `s_awburst` | input | 2 | protocol pin, core port `s_awburst` |
| `s_awvalid` | input | 1 | protocol pin, core port `s_awvalid` |
| `s_awready` | output | 1 | protocol pin, core port `s_awready` |
| `s_wdata` | input | 32 | protocol pin, core port `s_wdata` |
| `s_wstrb` | input | 4 | protocol pin, core port `s_wstrb` |
| `s_wlast` | input | 1 | protocol pin, core port `s_wlast` |
| `s_wvalid` | input | 1 | protocol pin, core port `s_wvalid` |
| `s_wready` | output | 1 | protocol pin, core port `s_wready` |
| `s_bid` | output | 4 | protocol pin, core port `s_bid` |
| `s_bresp` | output | 2 | protocol pin, core port `s_bresp` |
| `s_bvalid` | output | 1 | protocol pin, core port `s_bvalid` |
| `s_bready` | input | 1 | protocol pin, core port `s_bready` |
| `s_arid` | input | 4 | protocol pin, core port `s_arid` |
| `s_araddr` | input | 32 | protocol pin, core port `s_araddr` |
| `s_arlen` | input | 8 | protocol pin, core port `s_arlen` |
| `s_arsize` | input | 3 | protocol pin, core port `s_arsize` |
| `s_arburst` | input | 2 | protocol pin, core port `s_arburst` |
| `s_arvalid` | input | 1 | protocol pin, core port `s_arvalid` |
| `s_arready` | output | 1 | protocol pin, core port `s_arready` |
| `s_rid` | output | 4 | protocol pin, core port `s_rid` |
| `s_rdata` | output | 32 | protocol pin, core port `s_rdata` |
| `s_rresp` | output | 2 | protocol pin, core port `s_rresp` |
| `s_rlast` | output | 1 | protocol pin, core port `s_rlast` |
| `s_rvalid` | output | 1 | protocol pin, core port `s_rvalid` |
| `s_rready` | input | 1 | protocol pin, core port `s_rready` |

## Core ports

| Port | Dir | Width | In the APB wrapper |
|---|---|---|---|
| `clk` | input | 1 | PCLK |
| `rst_n` | input | 1 | PRESETN |
| `sclk` | output | 1 | pin (pass-through) |
| `csn` | output | 1 | pin (pass-through) |
| `io` | inout | 4 | pin (pass-through) |
| `div` | input | 8 | CFG[7:0] |
| `quad` | input | 1 | CFG[8:8] |
| `pc_cmd` | input | 8 | PC_CTRL[7:0] |
| `pc_has_addr` | input | 1 | PC_CTRL[8:8] |
| `pc_addr` | input | 24 | PC_ADDR[23:0] |
| `pc_nwr` | input | 3 | PC_CTRL[11:9] |
| `pc_nrd` | input | 3 | PC_CTRL[14:12] |
| `pc_wdata` | input | 32 | PC_WDATA[31:0] |
| `pc_start` | input | 1 | CMD |
| `pc_rdata` | output | 32 | PC_RDATA[31:0] |
| `pc_busy` | output | 1 | STATUS |
| `pc_done` | output | 1 | IRQ_STATUS.PC_DONE |
| `xip_cmds` | output | 16 | XIP_CMDS[15:0] |
| `xip_beats` | output | 16 | XIP_BEATS[15:0] |
| `s_awid` | input | 4 | pin (pass-through) |
| `s_awaddr` | input | 32 | pin (pass-through) |
| `s_awlen` | input | 8 | pin (pass-through) |
| `s_awsize` | input | 3 | pin (pass-through) |
| `s_awburst` | input | 2 | pin (pass-through) |
| `s_awvalid` | input | 1 | pin (pass-through) |
| `s_awready` | output | 1 | pin (pass-through) |
| `s_wdata` | input | 32 | pin (pass-through) |
| `s_wstrb` | input | 4 | pin (pass-through) |
| `s_wlast` | input | 1 | pin (pass-through) |
| `s_wvalid` | input | 1 | pin (pass-through) |
| `s_wready` | output | 1 | pin (pass-through) |
| `s_bid` | output | 4 | pin (pass-through) |
| `s_bresp` | output | 2 | pin (pass-through) |
| `s_bvalid` | output | 1 | pin (pass-through) |
| `s_bready` | input | 1 | pin (pass-through) |
| `s_arid` | input | 4 | pin (pass-through) |
| `s_araddr` | input | 32 | pin (pass-through) |
| `s_arlen` | input | 8 | pin (pass-through) |
| `s_arsize` | input | 3 | pin (pass-through) |
| `s_arburst` | input | 2 | pin (pass-through) |
| `s_arvalid` | input | 1 | pin (pass-through) |
| `s_arready` | output | 1 | pin (pass-through) |
| `s_rid` | output | 4 | pin (pass-through) |
| `s_rdata` | output | 32 | pin (pass-through) |
| `s_rresp` | output | 2 | pin (pass-through) |
| `s_rlast` | output | 1 | pin (pass-through) |
| `s_rvalid` | output | 1 | pin (pass-through) |
| `s_rready` | input | 1 | pin (pass-through) |

## APB wrapper

`QSPI_XIP_apb` is an APB4 slave (AMBA APB protocol v2.0): zero wait states, 32-bit data, 12-bit byte address, PSTRB byte lanes on every writable register, PSLVERR on an unmapped or misaligned address (reads then return 0, writes are dropped). Writes to read-only registers are ignored without an error. The core runs on PCLK and PRESETN. `irq` is level-high: `|(IRQ_STATUS & IRQ_ENABLE)`.

Pass-through pins: `sclk`, `csn`, `io`, `s_awid`, `s_awaddr`, `s_awlen`, `s_awsize`, `s_awburst`, `s_awvalid`, `s_awready`, `s_wdata`, `s_wstrb`, `s_wlast`, `s_wvalid`, `s_wready`, `s_bid`, `s_bresp`, `s_bvalid`, `s_bready`, `s_arid`, `s_araddr`, `s_arlen`, `s_arsize`, `s_arburst`, `s_arvalid`, `s_arready`, `s_rid`, `s_rdata`, `s_rresp`, `s_rlast`, `s_rvalid`, `s_rready`.

### Register map

| Offset | Name | Access | Reset | Description |
|---|---|---|---|---|
| 0x000 | ID | RO | 0x5C530100 | IP identification: code, major and minor version |
| 0x004 | IRQ_STATUS | W1C | 0x00000000 | Sticky interrupt bits, write 1 to clear |
| 0x008 | IRQ_ENABLE | RW | 0x00000000 | Interrupt enables; irq = \|(IRQ_STATUS & IRQ_ENABLE) |
| 0x00C | FLAGS | RO | 0x00000000 | Stream holding-register state |
| 0x010 | SCRATCH | RW | 0x00000000 | Scratch register, no effect on the core |
| 0x014 | CFG | RW | 0x00000101 | XIP read mode and SCLK timing |
| 0x018 | PC_CTRL | RW | 0x00000000 | Command port: the next command |
| 0x01C | PC_ADDR | RW | 0x00000000 | Command port: 24-bit flash address |
| 0x020 | PC_WDATA | RW | 0x00000000 | Command port: bytes to send, byte 0 (bits 7:0) first |
| 0x024 | CMD | WO (pulse) | 0x00000000 | Commands (write 1) |
| 0x028 | PC_RDATA | RO | core | Command port: bytes read by the last command, byte 0 in bits 7:0 |
| 0x02C | STATUS | RO | core | State |
| 0x030 | XIP_CMDS | RO | core | XIP read commands issued |
| 0x034 | XIP_BEATS | RO | core | XIP read beats returned |

Unlisted bits read 0 and ignore writes. Reset "core": the register reads the core's outputs directly, so after reset it shows the core's own reset state. WO (pulse) registers read 0. Offsets from 0x038 up to 0xFFC are unmapped (PSLVERR).

### Fields

| Register | Bits | Field | Access | Reset | Description |
|---|---|---|---|---|---|
| ID | 31:16 | CODE | RO | 0x5C53 | IP code |
| ID | 15:8 | MAJOR | RO | 0x01 | major version |
| ID | 7:0 | MINOR | RO | 0x00 | minor version |
| IRQ_STATUS | 0 | one bit per interrupt | W1C | 0x0 | see Interrupts |
| IRQ_ENABLE | 0 | one bit per interrupt | RW | 0x0 | 1 enables the IRQ_STATUS bit onto `irq` |
| SCRATCH | 31:0 | SCRATCH | RW | 0x00000000 | free for software |
| CFG | 7:0 | `div` | RW | 0x1 | half SCLK period - 1, in clocks |
| CFG | 8 | `quad` | RW | 0x1 | 1: XIP reads with 0x6B, 0: with 0x0B |
| PC_CTRL | 7:0 | `pc_cmd` | RW | 0x0 | command byte |
| PC_CTRL | 8 | `pc_has_addr` | RW | 0x0 | send PC_ADDR after the command |
| PC_CTRL | 11:9 | `pc_nwr` | RW | 0x0 | bytes sent from PC_WDATA (0..4) |
| PC_CTRL | 14:12 | `pc_nrd` | RW | 0x0 | bytes read into PC_RDATA (0..4) |
| PC_ADDR | 23:0 | `pc_addr` | RW | 0x0 | sent MSB first |
| PC_WDATA | 31:0 | `pc_wdata` | RW | 0x0 | data bytes |
| CMD | 0 | `pc_start` | WO (pulse) | 0x0 | run the command in PC_CTRL; ignored while busy |
| PC_RDATA | 31:0 | `pc_rdata` | RO | core | data bytes |
| STATUS | 0 | `pc_busy` | RO | core | a command is pending or running |
| XIP_CMDS | 15:0 | `xip_cmds` | RO | core | wraps at 0xFFFF |
| XIP_BEATS | 15:0 | `xip_beats` | RO | core | wraps at 0xFFFF |

### Interrupts (IRQ_STATUS, IRQ_ENABLE)

A bit is set while its source is active, stays set until written with 1, and a set in the same clock as the clear wins.

| Bit | Name | Set when |
|---|---|---|
| 0 | PC_DONE | a command-port command ended |

## Programming sequence

1. Release PRESETN. Read ID (0x000) and check it is 0x5C530100.
2. Write 0x1 to IRQ_STATUS (0x004) to clear any stale bits.
3. Configure the core: write CFG (0x014), PC_CTRL (0x018), PC_ADDR (0x01C), PC_WDATA (0x020). Reset values are in the register map; PSTRB selects the bytes written.
4. Write IRQ_ENABLE (0x008) with the interrupts to use (bit order as in the Interrupts table; 0x1 enables all).
5. To issue a command, write 1 to `pc_start` (CMD bit 0) at 0x024; the core sees a one-clock pulse, and the register reads 0.
6. Read PC_RDATA (0x028) for the core's live `pc_rdata`; it needs no clearing.
7. Read STATUS (0x02C) for the core's live `pc_busy`; it needs no clearing.
8. Read XIP_CMDS (0x030) for the core's live `xip_cmds`; it needs no clearing.
9. Read XIP_BEATS (0x034) for the core's live `xip_beats`; it needs no clearing.
10. On `irq`: read IRQ_STATUS, handle every bit that is set and enabled, then write those bits back to IRQ_STATUS to clear them. A source that is still active sets its bit again.

IP-specific use:

1. Write CFG (DIV, QUAD for the flash part); XIP reads work from then on.
2. Flash command: PC_ADDR and PC_WDATA if used, PC_CTRL, CMD.pc_start, wait for PC_DONE, read PC_RDATA.
3. Program: 0x06 write enable, then 0x02 with the address and up to 4 bytes, then poll 0x05 status until WIP is 0. Erase: 0x06, then 0x20 with the address.

## Running and verifying

All commands run from the repository root. Icarus Verilog 12 and Yosys 0.33 are enough for steps 1 to 3; step 4 also needs Verilator 5.052 and pyslang (see [README, Setup](../../README.md#setup)).

| Step | Command | Pass when | Output |
|---|---|---|---|
| 1. Core test | `make -f Makefile.QSPI_XIP sim` | a `TEST PASSED` line, no `ERROR` | console |
| 2. Core synthesis | `make -f Makefile.QSPI_XIP syn` | Yosys ends without `ERROR`; `stat` prints the cell count | `work/QSPI_XIP_top.json` |
| 3. APB wrapper test + synthesis | `make -f Makefile.QSPI_XIP apb` | `TEST PASSED: QSPI_XIP_apb`, then Yosys without `ERROR` | console, `work/QSPI_XIP_apb.json` |
| 4. Coverage (core, wrapper) | `bash scripts/cov/run_cov.sh QSPI_XIP`<br>`bash scripts/cov/run_cov.sh QSPI_XIP_apb` | `RESULT: CLOSED` (all five metrics 100%) | `work/cov/QSPI_XIP/score.json`, `work/cov/QSPI_XIP_apb/score.json` |

Expected end of a step 4 run:

```
===== QSPI_XIP =====
TEST: PASSED   SVA_FAILURES: 0
LINE ... TOGGLE ... FSM ... SVA ... FUNCTIONAL  (each n/n, 100.0%)
RESULT: CLOSED
```

**Core test** (`tb/QSPI_XIP_tb.sv`): drives `QSPI_XIP_top` through its own ports against a protocol peer or model and checks every result itself; any mismatch prints `ERROR`, and `TEST PASSED` is printed only when there were none.

**APB wrapper test** (`tb/QSPI_XIP_apb_tb.sv`), in this order:

1. Reset values of every register, ID included.
2. Writes to read-only registers are ignored.
3. Each RW register: all ones, all zeros, then 16 random writes with every PSTRB byte-lane pattern, read back each time.
4. Unmapped and misaligned addresses, reads and writes: PSLVERR, read data 0, no side effect on other registers.
5. Back-to-back transfers with no idle cycle.
6. IP traffic through the registers only (`tb/apb/QSPI_XIP_apb_func.svh`): the programming sequence above, every interrupt bit set, enabled and cleared (100% wrapper toggle coverage confirms each bit moved).
7. PRESETN asserted mid-run: `irq` and PRDATA go to 0, registers return to reset values.

**Checkers** (`tb/cov/QSPI_XIP_sva.sv`, `tb/cov/QSPI_XIP_apb_sva.sv`): SVA protocol and APB assertions plus covergroups, bound in by the coverage flow. An assertion failure prints `SVA_FAIL` and fails the run even when the test itself passed.

Whole portfolio: `bash scripts/ci_regression.sh` runs steps 1 to 3 for every IP (what CI runs), and `bash scripts/cov/run_all.sh 4` runs step 4 for every IP.

## Verification

Five-metric coverage with Verilator 5.052 (`scripts/cov/run_cov.sh`); see [COVERAGE_CLOSURE.md](../COVERAGE_CLOSURE.md) for the flow. Line and toggle count only the named RTL file.

| Scope | Test | Line | Toggle | FSM | SVA | Functional |
|---|---|---|---|---|---|---|
| core `rtl/QSPI_XIP_top.sv` | not run | | | | | |
| wrapper `rtl/QSPI_XIP_apb.sv` | not run | | | | | |
