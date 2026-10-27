# SD memory card host: CMD0 / CMD8 / ACMD41 / CMD2 / CMD3 / CMD7 initialisation, then repeated CMD24 write, CMD17 read-back compare and CMD13 status rounds in 4-bit mode, with R1 / R2 / R3 / R6 / R7 checks, CRC7 and CRC16

Protocol IP `SD`, version 2.0. Apache-2.0.

| Item | Value |
|---|---|
| Core | `SD_top` (`rtl/SD_top.sv`) |
| Register interface | APB4 slave `SD_apb`, 32-bit data, 12-bit byte address, zero wait states |
| Clock, reset | PCLK (rising edge), PRESETN (active low, asynchronous) |
| ID register | 0x53440200 (code 0x5344, version 2.0) |
| Registers | 5 words, 0x000 to 0x010 |
| Interrupts | 1 sources into one level-high `irq` |
| Protocol pins | 3 pass-through |

## Overview

SD protocol Open IP -- SD memory card host: CMD0/CMD8/ACMD41/CMD2/CMD3/CMD7 init sequence, CMD24/CMD17 single-block read/write in 4-bit DAT mode, CMD13 status poll, R1/R2/R3/R6/R7 response checking, CRC7/CRC16 Documented simplifications (educational slice of the SD physical layer):

- Block length is 32 bytes (256 bits) instead of the SD-native 512 bytes.
- 4-bit bus mode from the start (bus-width switch via ACMD6 is skipped;
the host is born in 4-bit mode, documented deviation).
- sd_clk is generated from clk by an even divider (parameter SD_CLK_DIV);
all host logic runs in the clk domain and advances one bus bit per
sd_clk period (internal "tick" aligned with the sd_clk rising edge).
- CMD7's R1b busy on DAT0 is simplified to plain R1 (no busy wait).
- Response / data-start / CRC-status / busy timeout is 64 sd_clk cycles.
- The host autonomously repeats demo rounds: CMD24 write of an internal
pattern block, CMD17 read-back compare, CMD13 status poll. Round n
uses block n[1:0]: the argument is the block number for a high
capacity card (OCR CCS = 1) and its byte address (n[1:0] * 32)
otherwise. Status is observable via internal state (TB hierarchical
reference) and irq pulses.
- Response checks: R1 (CMD55/7/24/17/13) start + transmission bits,
command index, CRC7, end bit and the card-status error bits
(ERR_MASK); R6 (CMD3) the same with its 16 status bits; R7 (CMD8)
framing plus the echoed voltage (1) and check pattern (0xAA); R3
framing (start, transmission, reserved 111111 fields, end bit); R2
framing (start, transmission, 111111) and the CID's own CRC7 with
CID[0] = 1. A failed check raises irq: framing / CRC -> err_crc7,
status bits -> err_status, R7 contents -> err_r7.
- Write: after the end bits the card returns the CRC status token on
DAT0 (0, 3 status bits, 1); 010 = accepted, anything else ->
err_crc16. The host then waits for the card to release DAT0 busy.
- Errors during init restart it with CMD0; errors in a round return to
the idle gap, which restarts the round.

sd_clk (PCLK / 4), cmd and dat[3:0] (bidirectional, need pull-ups) are the SD bus; they pass through unchanged. The host initialises the card and runs its write / read-back rounds on its own after reset.
Blocks are 32 bytes (the slice's simplification of 512).

## Files

| File | Content |
|---|---|
| `rtl/SD_top.sv` | protocol core |
| `rtl/SD_apb.sv` | APB4 register wrapper (generated) |
| `tb/SD_tb.sv` | core testbench |
| `tb/SD_apb_tb.sv`, `tb/apb/SD_apb_func.svh` | wrapper testbench (generated part + IP-specific part) |
| `tb/cov/SD_sva.sv`, `tb/cov/SD_apb_sva.sv` | coverage checkers (core, wrapper) |
| `scripts/apb/specs/SD.json` | register spec the wrapper, TB, checker and this page are generated from |

How to run the tests and the coverage flow: see [Running and verifying](#running-and-verifying).

## Parameters

`SD_apb` has the core's parameters and passes them to `SD_top` unchanged.

| Parameter | Type | Default |
|---|---|---|
| `SD_CLK_DIV` | int | `4` |

## Wrapper pins

Pins of `SD_apb`. Widths of the pass-through pins are at the default parameters.

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
| `sd_clk` | output | 1 | protocol pin, core port `sd_clk` |
| `cmd` | inout | 1 | protocol pin, core port `cmd` |
| `dat` | inout | 4 | protocol pin, core port `dat` |

## Core ports

| Port | Dir | Width | In the APB wrapper |
|---|---|---|---|
| `clk` | input | 1 | PCLK |
| `rst_n` | input | 1 | PRESETN |
| `sd_clk` | output | 1 | pin (pass-through) |
| `cmd` | inout | 1 | pin (pass-through) |
| `dat` | inout | 4 | pin (pass-through) |
| `irq` | output | 1 | IRQ_STATUS.ERR |

## APB wrapper

`SD_apb` is an APB4 slave (AMBA APB protocol v2.0): zero wait states, 32-bit data, 12-bit byte address, PSTRB byte lanes on every writable register, PSLVERR on an unmapped or misaligned address (reads then return 0, writes are dropped). Writes to read-only registers are ignored without an error. The core runs on PCLK and PRESETN. `irq` is level-high: `|(IRQ_STATUS & IRQ_ENABLE)`.

Pass-through pins: `sd_clk`, `cmd`, `dat`.

### Register map

| Offset | Name | Access | Reset | Description |
|---|---|---|---|---|
| 0x000 | ID | RO | 0x53440200 | IP identification: code, major and minor version |
| 0x004 | IRQ_STATUS | W1C | 0x00000000 | Sticky interrupt bits, write 1 to clear |
| 0x008 | IRQ_ENABLE | RW | 0x00000000 | Interrupt enables; irq = \|(IRQ_STATUS & IRQ_ENABLE) |
| 0x00C | FLAGS | RO | 0x00000000 | Stream holding-register state |
| 0x010 | SCRATCH | RW | 0x00000000 | Scratch register, no effect on the core |

Unlisted bits read 0 and ignore writes. Reset "core": the register reads the core's outputs directly, so after reset it shows the core's own reset state. WO (pulse) registers read 0. Offsets from 0x014 up to 0xFFC are unmapped (PSLVERR).

### Fields

| Register | Bits | Field | Access | Reset | Description |
|---|---|---|---|---|---|
| ID | 31:16 | CODE | RO | 0x5344 | IP code |
| ID | 15:8 | MAJOR | RO | 0x02 | major version |
| ID | 7:0 | MINOR | RO | 0x00 | minor version |
| IRQ_STATUS | 0 | one bit per interrupt | W1C | 0x0 | see Interrupts |
| IRQ_ENABLE | 0 | one bit per interrupt | RW | 0x0 | 1 enables the IRQ_STATUS bit onto `irq` |
| SCRATCH | 31:0 | SCRATCH | RW | 0x00000000 | free for software |

### Interrupts (IRQ_STATUS, IRQ_ENABLE)

A bit is set while its source is active, stays set until written with 1, and a set in the same clock as the clear wins.

| Bit | Name | Set when |
|---|---|---|
| 0 | ERR | a response, CRC status, read block or busy phase failed (framing, CRC7, index, card-status error bits, R7 contents, negative CRC status, CRC16, end bit, read compare, timeout); the host retries |

## Programming sequence

1. Release PRESETN. Read ID (0x000) and check it is 0x53440200.
2. Write 0x1 to IRQ_STATUS (0x004) to clear any stale bits.
3. Write IRQ_ENABLE (0x008) with the interrupts to use (bit order as in the Interrupts table; 0x1 enables all).
4. On `irq`: read IRQ_STATUS, handle every bit that is set and enabled, then write those bits back to IRQ_STATUS to clear them. A source that is still active sets its bit again.

## Running and verifying

All commands run from the repository root. Icarus Verilog 12 and Yosys 0.33 are enough for steps 1 to 3; step 4 also needs Verilator 5.052 and pyslang (see [README, Setup](../../README.md#setup)).

| Step | Command | Pass when | Output |
|---|---|---|---|
| 1. Core test | `make -f Makefile.SD sim` | a `TEST PASSED` line, no `ERROR` | console |
| 2. Core synthesis | `make -f Makefile.SD syn` | Yosys ends without `ERROR`; `stat` prints the cell count | `work/SD_top.json` |
| 3. APB wrapper test + synthesis | `make -f Makefile.SD apb` | `TEST PASSED: SD_apb`, then Yosys without `ERROR` | console, `work/SD_apb.json` |
| 4. Coverage (core, wrapper) | `bash scripts/cov/run_cov.sh SD`<br>`bash scripts/cov/run_cov.sh SD_apb` | `RESULT: CLOSED` (all five metrics 100%) | `work/cov/SD/score.json`, `work/cov/SD_apb/score.json` |

Expected end of a step 4 run:

```
===== SD =====
TEST: PASSED   SVA_FAILURES: 0
LINE ... TOGGLE ... FSM ... SVA ... FUNCTIONAL  (each n/n, 100.0%)
RESULT: CLOSED
```

**Core test** (`tb/SD_tb.sv`): drives `SD_top` through its own ports against a protocol peer or model and checks every result itself; any mismatch prints `ERROR`, and `TEST PASSED` is printed only when there were none.

**APB wrapper test** (`tb/SD_apb_tb.sv`), in this order:

1. Reset values of every register, ID included.
2. Writes to read-only registers are ignored.
3. Each RW register: all ones, all zeros, then 16 random writes with every PSTRB byte-lane pattern, read back each time.
4. Unmapped and misaligned addresses, reads and writes: PSLVERR, read data 0, no side effect on other registers.
5. Back-to-back transfers with no idle cycle.
6. IP traffic through the registers only (`tb/apb/SD_apb_func.svh`): the programming sequence above, every interrupt bit set, enabled and cleared (100% wrapper toggle coverage confirms each bit moved).
7. PRESETN asserted mid-run: `irq` and PRDATA go to 0, registers return to reset values.

**Checkers** (`tb/cov/SD_sva.sv`, `tb/cov/SD_apb_sva.sv`): SVA protocol and APB assertions plus covergroups, bound in by the coverage flow. An assertion failure prints `SVA_FAIL` and fails the run even when the test itself passed.

Whole portfolio: `bash scripts/ci_regression.sh` runs steps 1 to 3 for every IP (what CI runs), and `bash scripts/cov/run_all.sh 4` runs step 4 for every IP.

## Verification

Five-metric coverage with Verilator 5.052 (`scripts/cov/run_cov.sh`); see [COVERAGE_CLOSURE.md](../COVERAGE_CLOSURE.md) for the flow. Line and toggle count only the named RTL file.

| Scope | Test | Line | Toggle | FSM | SVA | Functional |
|---|---|---|---|---|---|---|
| core `rtl/SD_top.sv` | pass | 137/137 | 1850/1850 | 18/18 | 7/7 | 71/71 |
| wrapper `rtl/SD_apb.sv` | pass | 19/19 | 404/404 | n/a | 7/7 | 23/23 |
