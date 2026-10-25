# MIPI RFFE slave (USID 5): register 0 write, register write / read, extended write / read with auto-increment over a 32 x 8 register file, broadcast writes, parity checks

Protocol IP `MIPI_RFFE`, version 2.0. Apache-2.0.

| Item | Value |
|---|---|
| Core | `MIPI_RFFE_top` (`rtl/MIPI_RFFE_top.sv`) |
| Register interface | APB4 slave `MIPI_RFFE_apb`, 32-bit data, 12-bit byte address, zero wait states |
| Clock, reset | PCLK (rising edge), PRESETN (active low, asynchronous) |
| ID register | 0x52660200 (code 0x5266, version 2.0) |
| Registers | 5 words, 0x000 to 0x010 |
| Interrupts | 1 sources into one level-high `irq` |
| Protocol pins | 2 pass-through |

## Overview

MIPI RFFE protocol IP -- RFFE slave controller Implementation scope (subset of MIPI RFFE v2.x, clk oversamples the bus):

- SSC: SDATA rises then falls while SCLK stays low. It is recognised in
any state the slave is not driving, so a new SSC aborts a sequence.
- Master drives SDATA on SCLK rising edges; the slave samples on SCLK
falling edges, and drives read data on rising edges.
- Command frame, 13 bits: SA[3:0] | C[7:0] | P, odd parity per frame.
1DDDDDDD : register 0 write (reg0 <= {0, D[6:0]})
010AAAAA : register write   -> data frame D[7:0]|P, then bus park
011AAAAA : register read    -> bus park, slave drives D[7:0]|P,
slave parks the bus (drives 0 for
the high phase) and releases
0000BBBB : extended write   -> address frame A[7:0]|P, BC+1 data
0010BBBB : extended read    -> address frame, bus park, BC+1 frames
driven by the slave, bus park
- SA = USID addresses this slave; SA = 0 (broadcast) is accepted for
writes only. Other SAs are another slave's traffic and are ignored.
- 32 x 8 register file. Extended accesses auto-increment; addresses
32..255 read as 0 and ignore writes.
- Command/address/data parity errors and unsupported commands abort the
sequence and raise irq, which holds until the next SSC.

sclk (in) and sdata (bidirectional, needs a weak keeper to 0) are the RFFE bus; they pass through unchanged. PCLK oversamples the bus: SCLK phases must last at least four PCLK clocks.
The register file is reached over the RFFE bus only; the registers report its protocol errors.

## Files

| File | Content |
|---|---|
| `rtl/MIPI_RFFE_top.sv` | protocol core |
| `rtl/MIPI_RFFE_apb.sv` | APB4 register wrapper (generated) |
| `tb/MIPI_RFFE_tb.sv` | core testbench |
| `tb/MIPI_RFFE_apb_tb.sv`, `tb/apb/MIPI_RFFE_apb_func.svh` | wrapper testbench (generated part + IP-specific part) |
| `tb/cov/MIPI_RFFE_sva.sv`, `tb/cov/MIPI_RFFE_apb_sva.sv` | coverage checkers (core, wrapper) |
| `scripts/apb/specs/MIPI_RFFE.json` | register spec the wrapper, TB, checker and this page are generated from |

How to run the tests and the coverage flow: see [Running and verifying](#running-and-verifying).

## Parameters

`MIPI_RFFE_apb` has the core's parameters and passes them to `MIPI_RFFE_top` unchanged.

| Parameter | Type | Default |
|---|---|---|
| `USID` | logic [3:0] | `4'h5` |

## Wrapper pins

Pins of `MIPI_RFFE_apb`. Widths of the pass-through pins are at the default parameters.

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
| `sclk` | input | 1 | protocol pin, core port `sclk` |
| `sdata` | inout | 1 | protocol pin, core port `sdata` |

## Core ports

| Port | Dir | Width | In the APB wrapper |
|---|---|---|---|
| `clk` | input | 1 | PCLK |
| `rst_n` | input | 1 | PRESETN |
| `sclk` | input | 1 | pin (pass-through) |
| `sdata` | inout | 1 | pin (pass-through) |
| `irq` | output | 1 | IRQ_STATUS.PROTO |

## APB wrapper

`MIPI_RFFE_apb` is an APB4 slave (AMBA APB protocol v2.0): zero wait states, 32-bit data, 12-bit byte address, PSTRB byte lanes on every writable register, PSLVERR on an unmapped or misaligned address (reads then return 0, writes are dropped). Writes to read-only registers are ignored without an error. The core runs on PCLK and PRESETN. `irq` is level-high: `|(IRQ_STATUS & IRQ_ENABLE)`.

Pass-through pins: `sclk`, `sdata`.

### Register map

| Offset | Name | Access | Reset | Description |
|---|---|---|---|---|
| 0x000 | ID | RO | 0x52660200 | IP identification: code, major and minor version |
| 0x004 | IRQ_STATUS | W1C | 0x00000000 | Sticky interrupt bits, write 1 to clear |
| 0x008 | IRQ_ENABLE | RW | 0x00000000 | Interrupt enables; irq = \|(IRQ_STATUS & IRQ_ENABLE) |
| 0x00C | FLAGS | RO | 0x00000000 | Stream holding-register state |
| 0x010 | SCRATCH | RW | 0x00000000 | Scratch register, no effect on the core |

Unlisted bits read 0 and ignore writes. Reset "core": the register reads the core's outputs directly, so after reset it shows the core's own reset state. WO (pulse) registers read 0. Offsets from 0x014 up to 0xFFC are unmapped (PSLVERR).

### Fields

| Register | Bits | Field | Access | Reset | Description |
|---|---|---|---|---|---|
| ID | 31:16 | CODE | RO | 0x5266 | IP code |
| ID | 15:8 | MAJOR | RO | 0x02 | major version |
| ID | 7:0 | MINOR | RO | 0x00 | minor version |
| IRQ_STATUS | 0 | one bit per interrupt | W1C | 0x0 | see Interrupts |
| IRQ_ENABLE | 0 | one bit per interrupt | RW | 0x0 | 1 enables the IRQ_STATUS bit onto `irq` |
| SCRATCH | 31:0 | SCRATCH | RW | 0x00000000 | free for software |

### Interrupts (IRQ_STATUS, IRQ_ENABLE)

A bit is set while its source is active, stays set until written with 1, and a set in the same clock as the clear wins.

| Bit | Name | Set when |
|---|---|---|
| 0 | PROTO | a sequence was aborted: command, address or data parity error, or an unsupported command. Held in the core until the next SSC, so the bit is set again on every clock until then |

## Programming sequence

1. Release PRESETN. Read ID (0x000) and check it is 0x52660200.
2. Write 0x1 to IRQ_STATUS (0x004) to clear any stale bits.
3. Write IRQ_ENABLE (0x008) with the interrupts to use (bit order as in the Interrupts table; 0x1 enables all).
4. On `irq`: read IRQ_STATUS, handle every bit that is set and enabled, then write those bits back to IRQ_STATUS to clear them. A source that is still active sets its bit again.

## Running and verifying

All commands run from the repository root. Icarus Verilog 12 and Yosys 0.33 are enough for steps 1 to 3; step 4 also needs Verilator 5.052 and pyslang (see [README, Setup](../../README.md#setup)).

| Step | Command | Pass when | Output |
|---|---|---|---|
| 1. Core test | `make -f Makefile.MIPI_RFFE sim` | a `TEST PASSED` line, no `ERROR` | console |
| 2. Core synthesis | `make -f Makefile.MIPI_RFFE syn` | Yosys ends without `ERROR`; `stat` prints the cell count | `work/MIPI_RFFE_top.json` |
| 3. APB wrapper test + synthesis | `make -f Makefile.MIPI_RFFE apb` | `TEST PASSED: MIPI_RFFE_apb`, then Yosys without `ERROR` | console, `work/MIPI_RFFE_apb.json` |
| 4. Coverage (core, wrapper) | `bash scripts/cov/run_cov.sh MIPI_RFFE`<br>`bash scripts/cov/run_cov.sh MIPI_RFFE_apb` | `RESULT: CLOSED` (all five metrics 100%) | `work/cov/MIPI_RFFE/score.json`, `work/cov/MIPI_RFFE_apb/score.json` |

Expected end of a step 4 run:

```
===== MIPI_RFFE =====
TEST: PASSED   SVA_FAILURES: 0
LINE ... TOGGLE ... FSM ... SVA ... FUNCTIONAL  (each n/n, 100.0%)
RESULT: CLOSED
```

**Core test** (`tb/MIPI_RFFE_tb.sv`): drives `MIPI_RFFE_top` through its own ports against a protocol peer or model and checks every result itself; any mismatch prints `ERROR`, and `TEST PASSED` is printed only when there were none.

**APB wrapper test** (`tb/MIPI_RFFE_apb_tb.sv`), in this order:

1. Reset values of every register, ID included.
2. Writes to read-only registers are ignored.
3. Each RW register: all ones, all zeros, then 16 random writes with every PSTRB byte-lane pattern, read back each time.
4. Unmapped and misaligned addresses, reads and writes: PSLVERR, read data 0, no side effect on other registers.
5. Back-to-back transfers with no idle cycle.
6. IP traffic through the registers only (`tb/apb/MIPI_RFFE_apb_func.svh`): the programming sequence above, every interrupt bit set, enabled and cleared (100% wrapper toggle coverage confirms each bit moved).
7. PRESETN asserted mid-run: `irq` and PRDATA go to 0, registers return to reset values.

**Checkers** (`tb/cov/MIPI_RFFE_sva.sv`, `tb/cov/MIPI_RFFE_apb_sva.sv`): SVA protocol and APB assertions plus covergroups, bound in by the coverage flow. An assertion failure prints `SVA_FAIL` and fails the run even when the test itself passed.

Whole portfolio: `bash scripts/ci_regression.sh` runs steps 1 to 3 for every IP (what CI runs), and `bash scripts/cov/run_all.sh 4` runs step 4 for every IP.

## Verification

Five-metric coverage with Verilator 5.052 (`scripts/cov/run_cov.sh`); see [COVERAGE_CLOSURE.md](../COVERAGE_CLOSURE.md) for the flow. Line and toggle count only the named RTL file.

| Scope | Test | Line | Toggle | FSM | SVA | Functional |
|---|---|---|---|---|---|---|
| core `rtl/MIPI_RFFE_top.sv` | pass | 69/69 (+1 excl.) | 732/732 | 19/19 | 7/7 | 91/91 |
| wrapper `rtl/MIPI_RFFE_apb.sv` | pass | 19/19 | 396/396 | n/a | 7/7 | 23/23 |
