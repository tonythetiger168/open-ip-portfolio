# OCP-IP 3.0 slave: a 256-word memory behind MCmd / SCmdAccept / SResp, posted WR, RD and non-posted WRNP with byte enables and thread IDs

Protocol IP `OCP`, version 2.0. Apache-2.0.

| Item | Value |
|---|---|
| Core | `OCP_top` (`rtl/OCP_top.sv`) |
| Register interface | APB4 slave `OCP_apb`, 32-bit data, 12-bit byte address, zero wait states |
| Clock, reset | PCLK (rising edge), PRESETN (active low, asynchronous) |
| ID register | 0x4F430200 (code 0x4F43, version 2.0) |
| Registers | 5 words, 0x000 to 0x010 |
| Interrupts | 1 sources into one level-high `irq` |
| Protocol pins | 9 pass-through |

## Overview

OCP protocol -- OCP-IP 3.0 slave (MCmd/MAddr/MData -> SCmdAccept/SData/SResp) Scope: basic data-handshake subset of OCP-IP:

- MCmd: IDLE=0 / WR=1 (posted write, no response) / RD=2 /
WRNP=5 (non-posted write, answered DVA or ERR)
- configurable command-accept latency (ACCEPT_DLY = 0 or 1)
- fixed 2-cycle DVA response latency for RD/WRNP, SData valid with DVA
- MByteEn partial-write merge, MThreadID echoed on SThreadID
- 256x32 register file (1 KiB, word aligned); accesses outside
0x000..0x3FC or misaligned -> SResp=ERR + irq pulse
- other MCmd encodings (RDEX/RDL/WRC/BCST) are not supported: accepted
and answered with SResp=ERR + irq pulse, no register-file effect

mcmd, maddr, mdata, mbyteen, mthreadid, scmdaccept, sdata, sresp and sthreadid are the OCP slave pins; they pass through unchanged. The registers report the slave's error events.
A command is accepted the clock after it is presented (ACCEPT_DLY 1, the default). RD and WRNP are answered DVA (or ERR) two clocks after acceptance with the thread ID echoed; SData carries the word as it was when the request was accepted. WR (posted write) is not answered. MCmd values other than WR, RD and WRNP are answered ERR and do nothing.

## Files

| File | Content |
|---|---|
| `rtl/OCP_top.sv` | protocol core |
| `rtl/OCP_apb.sv` | APB4 register wrapper (generated) |
| `tb/OCP_tb.sv` | core testbench |
| `tb/OCP_apb_tb.sv`, `tb/apb/OCP_apb_func.svh` | wrapper testbench (generated part + IP-specific part) |
| `tb/cov/OCP_sva.sv`, `tb/cov/OCP_apb_sva.sv` | coverage checkers (core, wrapper) |
| `scripts/apb/specs/OCP.json` | register spec the wrapper, TB, checker and this page are generated from |

How to run the tests and the coverage flow: see [Running and verifying](#running-and-verifying).

## Parameters

`OCP_apb` has the core's parameters and passes them to `OCP_top` unchanged.

| Parameter | Type | Default |
|---|---|---|
| `DW` | int | `32` |
| `AW` | int | `32` |
| `DEPTH` | int | `256` |
| `ACCEPT_DLY` | int | `1` |

## Wrapper pins

Pins of `OCP_apb`. Widths of the pass-through pins are at the default parameters.

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
| `mcmd` | input | 3 | protocol pin, core port `mcmd` |
| `maddr` | input | 32 | protocol pin, core port `maddr` |
| `mdata` | input | 32 | protocol pin, core port `mdata` |
| `mbyteen` | input | 4 | protocol pin, core port `mbyteen` |
| `mthreadid` | input | 2 | protocol pin, core port `mthreadid` |
| `scmdaccept` | output | 1 | protocol pin, core port `scmdaccept` |
| `sdata` | output | 32 | protocol pin, core port `sdata` |
| `sresp` | output | 2 | protocol pin, core port `sresp` |
| `sthreadid` | output | 2 | protocol pin, core port `sthreadid` |

## Core ports

| Port | Dir | Width | In the APB wrapper |
|---|---|---|---|
| `clk` | input | 1 | PCLK |
| `rst_n` | input | 1 | PRESETN |
| `mcmd` | input | 3 | pin (pass-through) |
| `maddr` | input | 32 | pin (pass-through) |
| `mdata` | input | 32 | pin (pass-through) |
| `mbyteen` | input | 4 | pin (pass-through) |
| `mthreadid` | input | 2 | pin (pass-through) |
| `scmdaccept` | output | 1 | pin (pass-through) |
| `sdata` | output | 32 | pin (pass-through) |
| `sresp` | output | 2 | pin (pass-through) |
| `sthreadid` | output | 2 | pin (pass-through) |
| `irq` | output | 1 | IRQ_STATUS.ERR |

## APB wrapper

`OCP_apb` is an APB4 slave (AMBA APB protocol v2.0): zero wait states, 32-bit data, 12-bit byte address, PSTRB byte lanes on every writable register, PSLVERR on an unmapped or misaligned address (reads then return 0, writes are dropped). Writes to read-only registers are ignored without an error. The core runs on PCLK and PRESETN. `irq` is level-high: `|(IRQ_STATUS & IRQ_ENABLE)`.

Pass-through pins: `mcmd`, `maddr`, `mdata`, `mbyteen`, `mthreadid`, `scmdaccept`, `sdata`, `sresp`, `sthreadid`.

### Register map

| Offset | Name | Access | Reset | Description |
|---|---|---|---|---|
| 0x000 | ID | RO | 0x4F430200 | IP identification: code, major and minor version |
| 0x004 | IRQ_STATUS | W1C | 0x00000000 | Sticky interrupt bits, write 1 to clear |
| 0x008 | IRQ_ENABLE | RW | 0x00000000 | Interrupt enables; irq = \|(IRQ_STATUS & IRQ_ENABLE) |
| 0x00C | FLAGS | RO | 0x00000000 | Stream holding-register state |
| 0x010 | SCRATCH | RW | 0x00000000 | Scratch register, no effect on the core |

Unlisted bits read 0 and ignore writes. Reset "core": the register reads the core's outputs directly, so after reset it shows the core's own reset state. WO (pulse) registers read 0. Offsets from 0x014 up to 0xFFC are unmapped (PSLVERR).

### Fields

| Register | Bits | Field | Access | Reset | Description |
|---|---|---|---|---|---|
| ID | 31:16 | CODE | RO | 0x4F43 | IP code |
| ID | 15:8 | MAJOR | RO | 0x02 | major version |
| ID | 7:0 | MINOR | RO | 0x00 | minor version |
| IRQ_STATUS | 0 | one bit per interrupt | W1C | 0x0 | see Interrupts |
| IRQ_ENABLE | 0 | one bit per interrupt | RW | 0x0 | 1 enables the IRQ_STATUS bit onto `irq` |
| SCRATCH | 31:0 | SCRATCH | RW | 0x00000000 | free for software |

### Interrupts (IRQ_STATUS, IRQ_ENABLE)

A bit is set while its source is active, stays set until written with 1, and a set in the same clock as the clear wins.

| Bit | Name | Set when |
|---|---|---|
| 0 | ERR | a request was answered ERR (an address outside 0x000 to 0x3FC or misaligned, or an unsupported MCmd), or a posted write went to such an address |

## Programming sequence

1. Release PRESETN. Read ID (0x000) and check it is 0x4F430200.
2. Write 0x1 to IRQ_STATUS (0x004) to clear any stale bits.
3. Write IRQ_ENABLE (0x008) with the interrupts to use (bit order as in the Interrupts table; 0x1 enables all).
4. On `irq`: read IRQ_STATUS, handle every bit that is set and enabled, then write those bits back to IRQ_STATUS to clear them. A source that is still active sets its bit again.

## Running and verifying

All commands run from the repository root. Icarus Verilog 12 and Yosys 0.33 are enough for steps 1 to 3; step 4 also needs Verilator 5.052 and pyslang (see [README, Setup](../../README.md#setup)).

| Step | Command | Pass when | Output |
|---|---|---|---|
| 1. Core test | `make -f Makefile.OCP sim` | a `TEST PASSED` line, no `ERROR` | console |
| 2. Core synthesis | `make -f Makefile.OCP syn` | Yosys ends without `ERROR`; `stat` prints the cell count | `work/OCP_top.json` |
| 3. APB wrapper test + synthesis | `make -f Makefile.OCP apb` | `TEST PASSED: OCP_apb`, then Yosys without `ERROR` | console, `work/OCP_apb.json` |
| 4. Coverage (core, wrapper) | `bash scripts/cov/run_cov.sh OCP`<br>`bash scripts/cov/run_cov.sh OCP_apb` | `RESULT: CLOSED` (all five metrics 100%) | `work/cov/OCP/score.json`, `work/cov/OCP_apb/score.json` |

Expected end of a step 4 run:

```
===== OCP =====
TEST: PASSED   SVA_FAILURES: 0
LINE ... TOGGLE ... FSM ... SVA ... FUNCTIONAL  (each n/n, 100.0%)
RESULT: CLOSED
```

**Core test** (`tb/OCP_tb.sv`): drives `OCP_top` through its own ports against a protocol peer or model and checks every result itself; any mismatch prints `ERROR`, and `TEST PASSED` is printed only when there were none.

**APB wrapper test** (`tb/OCP_apb_tb.sv`), in this order:

1. Reset values of every register, ID included.
2. Writes to read-only registers are ignored.
3. Each RW register: all ones, all zeros, then 16 random writes with every PSTRB byte-lane pattern, read back each time.
4. Unmapped and misaligned addresses, reads and writes: PSLVERR, read data 0, no side effect on other registers.
5. Back-to-back transfers with no idle cycle.
6. IP traffic through the registers only (`tb/apb/OCP_apb_func.svh`): the programming sequence above, every interrupt bit set, enabled and cleared (100% wrapper toggle coverage confirms each bit moved).
7. PRESETN asserted mid-run: `irq` and PRDATA go to 0, registers return to reset values.

**Checkers** (`tb/cov/OCP_sva.sv`, `tb/cov/OCP_apb_sva.sv`): SVA protocol and APB assertions plus covergroups, bound in by the coverage flow. An assertion failure prints `SVA_FAIL` and fails the run even when the test itself passed.

Whole portfolio: `bash scripts/ci_regression.sh` runs steps 1 to 3 for every IP (what CI runs), and `bash scripts/cov/run_all.sh 4` runs step 4 for every IP.

## Verification

Five-metric coverage with Verilator 5.052 (`scripts/cov/run_cov.sh`); see [COVERAGE_CLOSURE.md](../COVERAGE_CLOSURE.md) for the flow. Line and toggle count only the named RTL file.

| Scope | Test | Line | Toggle | FSM | SVA | Functional |
|---|---|---|---|---|---|---|
| core `rtl/OCP_top.sv` | pass | 31/31 | 308/308 | 11/11 | 11/11 | 77/77 |
| wrapper `rtl/OCP_apb.sv` | pass | 19/19 | 612/612 | n/a | 7/7 | 23/23 |
