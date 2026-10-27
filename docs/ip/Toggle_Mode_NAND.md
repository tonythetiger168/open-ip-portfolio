# Toggle-mode NAND flash target: SDR command / address cycles, DDR data in (dqs) and out (re_n echoed on dqs), Read ID, page read / program, block erase, Read Status, reset, a protected block, and protocol-error detection

Protocol IP `Toggle_Mode_NAND`, version 2.0. Apache-2.0.

| Item | Value |
|---|---|
| Core | `Toggle_Mode_NAND_top` (`rtl/Toggle_Mode_NAND_top.sv`) |
| Register interface | APB4 slave `Toggle_Mode_NAND_apb`, 32-bit data, 12-bit byte address, zero wait states |
| Clock, reset | PCLK (rising edge), PRESETN (active low, asynchronous) |
| ID register | 0x544E0200 (code 0x544E, version 2.0) |
| Registers | 6 words, 0x000 to 0x014 |
| Interrupts | 1 sources into one level-high `irq` |
| Protocol pins | 8 pass-through |

## Overview

Toggle Mode NAND protocol IP -- NAND flash target Implementation scope (subset of toggle-mode / ONFI NV-DDR style NAND; clk oversamples the bus):

- Commands and addresses are SDR: latched on the rising edge of we_n
while ce_n = 0, with cle = 1 (command) or ale = 1 (address).
- Data is DDR on dq[7:0]:
input : the host drives dqs; every dqs edge (rising and falling)
latches one byte during page-program data input.
output: the host toggles re_n; the target drives dq and echoes
re_n on dqs. The first byte follows the first re_n falling
edge and every further re_n edge presents the next byte;
cle or ale high releases dq / dqs at once.
- Command set:
90h + 1 addr            : Read ID, 5-byte ID
00h + 5 addr + 30h      : Page Read (col[5:0] = byte, row[3:0] = page)
80h + 5 addr + data + 10h: Page Program (1 -> 0 only)
60h + 3 addr + D0h      : Block Erase (4 pages per block)
70h                     : Read Status, accepted at any time, also
while busy: {WP_n=1, RDY, ARDY, 0000, FAIL}
00h (no address)        : after a page read, return from status to
the page data (restarts at the column)
(FAIL reports the last program / erase;
a page read clears it)
FFh                     : Reset, accepted at any time; aborts the
operation in flight, clears irq and FAIL
- Array: 16 pages x 64 bytes; block = 4 pages. Block 3 (pages 12..15)
is protected: program / erase leave it untouched and set FAIL.
- rb_n busy time (clk cycles): read T_R, program T_PROG, erase T_ERASE,
reset T_RST.
- irq (sticky until FFh or rst_n): unknown command, a command out of
sequence, an address cycle outside an address phase, or any command
but 70h / FFh while busy. The offending command is ignored.

ce_n, cle, ale, we_n, re_n (in), dq[7:0] and dqs (bidirectional tri-state) and rb_n (out) are the NAND bus; they pass through unchanged. PCLK oversamples the bus: each strobe phase must last at least two PCLK clocks.
The 16 x 64-byte array is reached over the NAND bus only; the registers report the ready / busy state and protocol errors.

## Files

| File | Content |
|---|---|
| `rtl/Toggle_Mode_NAND_top.sv` | protocol core |
| `rtl/Toggle_Mode_NAND_apb.sv` | APB4 register wrapper (generated) |
| `tb/Toggle_Mode_NAND_tb.sv` | core testbench |
| `tb/Toggle_Mode_NAND_apb_tb.sv`, `tb/apb/Toggle_Mode_NAND_apb_func.svh` | wrapper testbench (generated part + IP-specific part) |
| `tb/cov/Toggle_Mode_NAND_sva.sv`, `tb/cov/Toggle_Mode_NAND_apb_sva.sv` | coverage checkers (core, wrapper) |
| `scripts/apb/specs/Toggle_Mode_NAND.json` | register spec the wrapper, TB, checker and this page are generated from |

How to run the tests and the coverage flow: see [Running and verifying](#running-and-verifying).

## Parameters

`Toggle_Mode_NAND_apb` has the core's parameters and passes them to `Toggle_Mode_NAND_top` unchanged.

| Parameter | Type | Default |
|---|---|---|
| `T_R` | int | `25` |
| `T_PROG` | int | `200` |
| `T_ERASE` | int | `1000` |
| `T_RST` | int | `5` |

## Wrapper pins

Pins of `Toggle_Mode_NAND_apb`. Widths of the pass-through pins are at the default parameters.

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
| `ce_n` | input | 1 | protocol pin, core port `ce_n` |
| `cle` | input | 1 | protocol pin, core port `cle` |
| `ale` | input | 1 | protocol pin, core port `ale` |
| `we_n` | input | 1 | protocol pin, core port `we_n` |
| `re_n` | input | 1 | protocol pin, core port `re_n` |
| `dq` | inout | 8 | protocol pin, core port `dq` |
| `dqs` | inout | 1 | protocol pin, core port `dqs` |
| `rb_n` | output | 1 | protocol pin, core port `rb_n` (also read in a register) |

## Core ports

| Port | Dir | Width | In the APB wrapper |
|---|---|---|---|
| `clk` | input | 1 | PCLK |
| `rst_n` | input | 1 | PRESETN |
| `ce_n` | input | 1 | pin (pass-through) |
| `cle` | input | 1 | pin (pass-through) |
| `ale` | input | 1 | pin (pass-through) |
| `we_n` | input | 1 | pin (pass-through) |
| `re_n` | input | 1 | pin (pass-through) |
| `dq` | inout | 8 | pin (pass-through) |
| `dqs` | inout | 1 | pin (pass-through) |
| `rb_n` | output | 1 | STATUS |
| `irq` | output | 1 | IRQ_STATUS.PROTO |

## APB wrapper

`Toggle_Mode_NAND_apb` is an APB4 slave (AMBA APB protocol v2.0): zero wait states, 32-bit data, 12-bit byte address, PSTRB byte lanes on every writable register, PSLVERR on an unmapped or misaligned address (reads then return 0, writes are dropped). Writes to read-only registers are ignored without an error. The core runs on PCLK and PRESETN. `irq` is level-high: `|(IRQ_STATUS & IRQ_ENABLE)`.

Pass-through pins: `ce_n`, `cle`, `ale`, `we_n`, `re_n`, `dq`, `dqs`, `rb_n`.

### Register map

| Offset | Name | Access | Reset | Description |
|---|---|---|---|---|
| 0x000 | ID | RO | 0x544E0200 | IP identification: code, major and minor version |
| 0x004 | IRQ_STATUS | W1C | 0x00000000 | Sticky interrupt bits, write 1 to clear |
| 0x008 | IRQ_ENABLE | RW | 0x00000000 | Interrupt enables; irq = \|(IRQ_STATUS & IRQ_ENABLE) |
| 0x00C | FLAGS | RO | 0x00000000 | Stream holding-register state |
| 0x010 | SCRATCH | RW | 0x00000000 | Scratch register, no effect on the core |
| 0x014 | STATUS | RO | core | Target state |

Unlisted bits read 0 and ignore writes. Reset "core": the register reads the core's outputs directly, so after reset it shows the core's own reset state. WO (pulse) registers read 0. Offsets from 0x018 up to 0xFFC are unmapped (PSLVERR).

### Fields

| Register | Bits | Field | Access | Reset | Description |
|---|---|---|---|---|---|
| ID | 31:16 | CODE | RO | 0x544E | IP code |
| ID | 15:8 | MAJOR | RO | 0x02 | major version |
| ID | 7:0 | MINOR | RO | 0x00 | minor version |
| IRQ_STATUS | 0 | one bit per interrupt | W1C | 0x0 | see Interrupts |
| IRQ_ENABLE | 0 | one bit per interrupt | RW | 0x0 | 1 enables the IRQ_STATUS bit onto `irq` |
| SCRATCH | 31:0 | SCRATCH | RW | 0x00000000 | free for software |
| STATUS | 0 | `rb_n` | RO | core | ready (1) / busy (0); same as the rb_n pin |

### Interrupts (IRQ_STATUS, IRQ_ENABLE)

A bit is set while its source is active, stays set until written with 1, and a set in the same clock as the clear wins.

| Bit | Name | Set when |
|---|---|---|
| 0 | PROTO | unknown command, command out of sequence, address cycle outside an address phase, or a command other than 70h / FFh while busy. Held in the core until FFh, so the bit is set again on every clock until then |

## Programming sequence

1. Release PRESETN. Read ID (0x000) and check it is 0x544E0200.
2. Write 0x1 to IRQ_STATUS (0x004) to clear any stale bits.
3. Write IRQ_ENABLE (0x008) with the interrupts to use (bit order as in the Interrupts table; 0x1 enables all).
4. Read STATUS (0x014) for the core's live `rb_n`; it needs no clearing.
5. On `irq`: read IRQ_STATUS, handle every bit that is set and enabled, then write those bits back to IRQ_STATUS to clear them. A source that is still active sets its bit again.

## Running and verifying

All commands run from the repository root. Icarus Verilog 12 and Yosys 0.33 are enough for steps 1 to 3; step 4 also needs Verilator 5.052 and pyslang (see [README, Setup](../../README.md#setup)).

| Step | Command | Pass when | Output |
|---|---|---|---|
| 1. Core test | `make -f Makefile.Toggle_Mode_NAND sim` | a `TEST PASSED` line, no `ERROR` | console |
| 2. Core synthesis | `make -f Makefile.Toggle_Mode_NAND syn` | Yosys ends without `ERROR`; `stat` prints the cell count | `work/Toggle_Mode_NAND_top.json` |
| 3. APB wrapper test + synthesis | `make -f Makefile.Toggle_Mode_NAND apb` | `TEST PASSED: Toggle_Mode_NAND_apb`, then Yosys without `ERROR` | console, `work/Toggle_Mode_NAND_apb.json` |
| 4. Coverage (core, wrapper) | `bash scripts/cov/run_cov.sh Toggle_Mode_NAND`<br>`bash scripts/cov/run_cov.sh Toggle_Mode_NAND_apb` | `RESULT: CLOSED` (all five metrics 100%) | `work/cov/Toggle_Mode_NAND/score.json`, `work/cov/Toggle_Mode_NAND_apb/score.json` |

Expected end of a step 4 run:

```
===== Toggle_Mode_NAND =====
TEST: PASSED   SVA_FAILURES: 0
LINE ... TOGGLE ... FSM ... SVA ... FUNCTIONAL  (each n/n, 100.0%)
RESULT: CLOSED
```

**Core test** (`tb/Toggle_Mode_NAND_tb.sv`): drives `Toggle_Mode_NAND_top` through its own ports against a protocol peer or model and checks every result itself; any mismatch prints `ERROR`, and `TEST PASSED` is printed only when there were none.

**APB wrapper test** (`tb/Toggle_Mode_NAND_apb_tb.sv`), in this order:

1. Reset values of every register, ID included.
2. Writes to read-only registers are ignored.
3. Each RW register: all ones, all zeros, then 16 random writes with every PSTRB byte-lane pattern, read back each time.
4. Unmapped and misaligned addresses, reads and writes: PSLVERR, read data 0, no side effect on other registers.
5. Back-to-back transfers with no idle cycle.
6. IP traffic through the registers only (`tb/apb/Toggle_Mode_NAND_apb_func.svh`): the programming sequence above, every interrupt bit set, enabled and cleared (100% wrapper toggle coverage confirms each bit moved).
7. PRESETN asserted mid-run: `irq` and PRDATA go to 0, registers return to reset values.

**Checkers** (`tb/cov/Toggle_Mode_NAND_sva.sv`, `tb/cov/Toggle_Mode_NAND_apb_sva.sv`): SVA protocol and APB assertions plus covergroups, bound in by the coverage flow. An assertion failure prints `SVA_FAIL` and fails the run even when the test itself passed.

Whole portfolio: `bash scripts/ci_regression.sh` runs steps 1 to 3 for every IP (what CI runs), and `bash scripts/cov/run_all.sh 4` runs step 4 for every IP.

## Verification

Five-metric coverage with Verilator 5.052 (`scripts/cov/run_cov.sh`); see [COVERAGE_CLOSURE.md](../COVERAGE_CLOSURE.md) for the flow. Line and toggle count only the named RTL file.

| Scope | Test | Line | Toggle | FSM | SVA | Functional |
|---|---|---|---|---|---|---|
| core `rtl/Toggle_Mode_NAND_top.sv` | pass | 98/98 | 246/246 | 31/31 | 7/7 | 75/75 |
| wrapper `rtl/Toggle_Mode_NAND_apb.sv` | pass | 20/20 | 426/426 | n/a | 7/7 | 25/25 |
