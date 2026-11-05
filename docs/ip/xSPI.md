# xSPI (JESD251) 8D-8D-8D NOR flash target: octal DDR command / address / data with a DQS read strobe, JESD251 Profile 1.0 command set, page program, sector and chip erase, configurable read latency

Protocol IP `xSPI`, version 1.0. Apache-2.0.

| Item | Value |
|---|---|
| Core | `xSPI_top` (`rtl/xSPI_top.sv`) |
| Register interface | APB4 slave `xSPI_apb`, 32-bit data, 12-bit byte address, zero wait states |
| Clock, reset | PCLK (rising edge), PRESETN (active low, asynchronous) |
| ID register | 0x78530100 (code 0x7853, version 1.0) |
| Registers | 6 words, 0x000 to 0x014 |
| Interrupts | 3 sources into one level-high `irq` |
| Protocol pins | 7 pass-through |

## Overview

xSPI (JESD251) 8D-8D-8D memory target: an octal-DDR NOR flash device with a 2^MEM_AW byte array, the JESD251 Profile 1.0 command set and DQS read strobe. Grown from the QSPI slave (oversampled clock, edge-counted frames) to eight data lines and both clock edges. * Frame: CS# low, CK idles low. Every CK edge (rising and falling) carries one byte on DQ[7:0]: edge 0 the command, edge 1 its extension (the inverted command), edges 2..5 the address A[31:24]..A[7:0] for commands that take one, then DUMMY CK cycles (2 x DUMMY edges) for reads, then data, two bytes per CK cycle. * Reads: from the first dummy edge the target drives DQS low (preamble) and from the last one DQ; on each data edge it puts the next byte on DQ and toggles DQS, so the host captures byte 2k on a DQS rise and byte 2k + 1 on a DQS fall. A0 is ignored (8D transfers start on an even address); the array address wraps. * Commands: 06F9 WREN, 04FB WRDI, 05FA RDSR, 9F60 RDID, EE11 8D READ, 12ED PAGE PROGRAM, 21DE SECTOR ERASE, 609F CHIP ERASE, 817E WRCR (write configuration: dummy cycles), 857A RDCR, 6699 RESET ENABLE, 9966 RESET. Status register: [1] WEL, [0] WIP. * Program / erase need WEL, start at CS# high and run in the background (WIP = 1, one array byte per clock); WEL clears when they finish. Program is NOR-style: bits only go from 1 to 0 (new = old & data); the data wraps inside its PAGE-byte page. While WIP is set only RDSR is accepted. * Frame rules: commands without data must end after exactly their header (WREN / WRDI / CE / RSTEN / RST after 2 edges, SE after 6); PP and WRCR after a whole number of CK cycles with data; and no frame may end with CK high (an odd number of edges). A frame that breaks a rule, or any other error, is ignored to its end. irq_cmd pulses at the end of each accepted frame, irq_done when a program or erase finishes, irq_err on an error; err_code holds the last error: 1 bad extension, 2 unknown command, 3 busy, 4 WEL not set, 5 bad frame length / CS# with CK high, 6 dummy setting below 4, 7 RESET without RESET ENABLE. CK, CS# and DQ are sampled on clk: CK must stay high and low at least two clocks each, DQ be stable one clock before a CK edge and one after. The array is not cleared by reset (sim starts it at zero).

Features:

- xSPI 8D-8D-8D (JESD251 octal DDR): every CK edge carries a byte on DQ[7:0], the command is followed by its inverted extension, 4 address bytes, a configurable latency (DUMMY CK cycles) for reads, then data two bytes per CK cycle.
- Reads drive DQS low through the latency (preamble) and toggle it with each byte, so byte 2k is captured on a DQS rise and byte 2k + 1 on a DQS fall; A0 is ignored and the array address wraps.
- Commands (JESD251 Profile 1.0 set): 06F9 WREN, 04FB WRDI, 05FA RDSR, 9F60 RDID, EE11 8D READ, 12ED PAGE PROGRAM, 21DE SECTOR ERASE, 609F CHIP ERASE, 817E WRCR (dummy cycles), 857A RDCR, 6699 RESET ENABLE, 9966 RESET.
- NOR array of 2^MEM_AW bytes (default 512): program only clears bits (new = old & data) and wraps inside its 2^PAGE_AW-byte page; sector erase (2^SECT_AW bytes) and chip erase set bytes to FF. Program and erase need WEL and run in the background, one byte per clock, with WIP set; only RDSR is accepted meanwhile.
- Frame checks: wrong extension, unknown command, busy, WEL not set, a frame ending off its length or with CK high, a latency below 4 and RESET without RESET ENABLE reject the frame and set err_code.

ck, csn, dq_i, dq_o, dq_oe, dqs_o and dqs_oe are the xSPI pins (pad directions split: the pad ring merges dq_o / dq_i under dq_oe); they pass through unchanged. CK, CS# and DQ are sampled on PCLK: CK must stay high and low at least two clocks each, DQ be stable one clock before and one clock after each CK edge.
Not implemented: 1S-1S-1S power-up mode and the mode switch to 8D (the target is in 8D-8D-8D from reset), SFDP, data strobe on writes (DQS as write mask), INT#, deep power-down, suspend / resume, block protection and ECC. The array is not cleared by reset.

## Files

| File | Content |
|---|---|
| `rtl/xSPI_top.sv` | protocol core |
| `rtl/xSPI_apb.sv` | APB4 register wrapper (generated) |
| `tb/xSPI_tb.sv` | core testbench |
| `tb/xSPI_apb_tb.sv`, `tb/apb/xSPI_apb_func.svh` | wrapper testbench (generated part + IP-specific part) |
| `tb/cov/xSPI_sva.sv`, `tb/cov/xSPI_apb_sva.sv` | coverage checkers (core, wrapper) |
| `scripts/apb/specs/xSPI.json` | register spec the wrapper, TB, checker and this page are generated from |

How to run the tests and the coverage flow: see [Running and verifying](#running-and-verifying).

## Parameters

`xSPI_apb` has the core's parameters and passes them to `xSPI_top` unchanged.

| Parameter | Type | Default |
|---|---|---|
| `MEM_AW` | int | `9` |
| `PAGE_AW` | int | `5` |
| `SECT_AW` | int | `7` |
| `DUMMY` | logic [4:0] | `5'd8` |

## Wrapper pins

Pins of `xSPI_apb`. Widths of the pass-through pins are at the default parameters.

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
| `ck` | input | 1 | protocol pin, core port `ck` |
| `csn` | input | 1 | protocol pin, core port `csn` |
| `dq_i` | input | 8 | protocol pin, core port `dq_i` |
| `dq_o` | output | 8 | protocol pin, core port `dq_o` |
| `dq_oe` | output | 1 | protocol pin, core port `dq_oe` |
| `dqs_o` | output | 1 | protocol pin, core port `dqs_o` |
| `dqs_oe` | output | 1 | protocol pin, core port `dqs_oe` |

## Core ports

| Port | Dir | Width | In the APB wrapper |
|---|---|---|---|
| `clk` | input | 1 | PCLK |
| `rst_n` | input | 1 | PRESETN |
| `ck` | input | 1 | pin (pass-through) |
| `csn` | input | 1 | pin (pass-through) |
| `dq_i` | input | 8 | pin (pass-through) |
| `dq_o` | output | 8 | pin (pass-through) |
| `dq_oe` | output | 1 | pin (pass-through) |
| `dqs_o` | output | 1 | pin (pass-through) |
| `dqs_oe` | output | 1 | pin (pass-through) |
| `sr` | output | 2 | STATUS[1:0] |
| `dummy` | output | 5 | STATUS[6:2] |
| `err_code` | output | 3 | STATUS[9:7] |
| `irq_cmd` | output | 1 | IRQ_STATUS.CMD |
| `irq_done` | output | 1 | IRQ_STATUS.DONE |
| `irq_err` | output | 1 | IRQ_STATUS.ERR |

## APB wrapper

`xSPI_apb` is an APB4 slave (AMBA APB protocol v2.0): zero wait states, 32-bit data, 12-bit byte address, PSTRB byte lanes on every writable register, PSLVERR on an unmapped or misaligned address (reads then return 0, writes are dropped). Writes to read-only registers are ignored without an error. The core runs on PCLK and PRESETN. `irq` is level-high: `|(IRQ_STATUS & IRQ_ENABLE)`.

Pass-through pins: `ck`, `csn`, `dq_i`, `dq_o`, `dq_oe`, `dqs_o`, `dqs_oe`.

### Register map

| Offset | Name | Access | Reset | Description |
|---|---|---|---|---|
| 0x000 | ID | RO | 0x78530100 | IP identification: code, major and minor version |
| 0x004 | IRQ_STATUS | W1C | 0x00000000 | Sticky interrupt bits, write 1 to clear |
| 0x008 | IRQ_ENABLE | RW | 0x00000000 | Interrupt enables; irq = \|(IRQ_STATUS & IRQ_ENABLE) |
| 0x00C | FLAGS | RO | 0x00000000 | Stream holding-register state |
| 0x010 | SCRATCH | RW | 0x00000000 | Scratch register, no effect on the core |
| 0x014 | STATUS | RO | core | Device state as the host sees it |

Unlisted bits read 0 and ignore writes. Reset "core": the register reads the core's outputs directly, so after reset it shows the core's own reset state. WO (pulse) registers read 0. Offsets from 0x018 up to 0xFFC are unmapped (PSLVERR).

### Fields

| Register | Bits | Field | Access | Reset | Description |
|---|---|---|---|---|---|
| ID | 31:16 | CODE | RO | 0x7853 | IP code |
| ID | 15:8 | MAJOR | RO | 0x01 | major version |
| ID | 7:0 | MINOR | RO | 0x00 | minor version |
| IRQ_STATUS | 2:0 | one bit per interrupt | W1C | 0x0 | see Interrupts |
| IRQ_ENABLE | 2:0 | one bit per interrupt | RW | 0x0 | 1 enables the IRQ_STATUS bit onto `irq` |
| SCRATCH | 31:0 | SCRATCH | RW | 0x00000000 | free for software |
| STATUS | 1:0 | `sr` | RO | core | status register bits: [1] WEL (write enable latch), [0] WIP (program / erase in progress) |
| STATUS | 6:2 | `dummy` | RO | core | read latency in CK cycles (WRCR, 4..31; 8 after reset or RESET) |
| STATUS | 9:7 | `err_code` | RO | core | last error: 1 bad extension, 2 unknown command, 3 busy, 4 WEL not set, 5 bad frame length or CS# with CK high, 6 dummy setting below 4, 7 RESET without RESET ENABLE |

### Interrupts (IRQ_STATUS, IRQ_ENABLE)

A bit is set while its source is active, stays set until written with 1, and a set in the same clock as the clear wins.

| Bit | Name | Set when |
|---|---|---|
| 0 | CMD | a frame ended and its command was accepted |
| 1 | DONE | a page program, sector erase or chip erase finished (WIP and WEL cleared) |
| 2 | ERR | a frame was rejected; the cause is in STATUS.err_code |

## Programming sequence

1. Release PRESETN. Read ID (0x000) and check it is 0x78530100.
2. Write 0x7 to IRQ_STATUS (0x004) to clear any stale bits.
3. Write IRQ_ENABLE (0x008) with the interrupts to use (bit order as in the Interrupts table; 0x7 enables all).
4. Read STATUS (0x014) for the core's live `sr`, `dummy`, `err_code`; it needs no clearing.
5. On `irq`: read IRQ_STATUS, handle every bit that is set and enabled, then write those bits back to IRQ_STATUS to clear them. A source that is still active sets its bit again.

## Running and verifying

All commands run from the repository root. Icarus Verilog 12 and Yosys 0.33 are enough for steps 1 to 3; step 4 also needs Verilator 5.052 and pyslang (see [README, Setup](../../README.md#setup)).

| Step | Command | Pass when | Output |
|---|---|---|---|
| 1. Core test | `make -f Makefile.xSPI sim` | a `TEST PASSED` line, no `ERROR` | console |
| 2. Core synthesis | `make -f Makefile.xSPI syn` | Yosys ends without `ERROR`; `stat` prints the cell count | `work/xSPI_top.json` |
| 3. APB wrapper test + synthesis | `make -f Makefile.xSPI apb` | `TEST PASSED: xSPI_apb`, then Yosys without `ERROR` | console, `work/xSPI_apb.json` |
| 4. Coverage (core, wrapper) | `bash scripts/cov/run_cov.sh xSPI`<br>`bash scripts/cov/run_cov.sh xSPI_apb` | `RESULT: CLOSED` (all five metrics 100%) | `work/cov/xSPI/score.json`, `work/cov/xSPI_apb/score.json` |

Expected end of a step 4 run:

```
===== xSPI =====
TEST: PASSED   SVA_FAILURES: 0
LINE ... TOGGLE ... FSM ... SVA ... FUNCTIONAL  (each n/n, 100.0%)
RESULT: CLOSED
```

**Core test** (`tb/xSPI_tb.sv`): drives `xSPI_top` through its own ports against a protocol peer or model and checks every result itself; any mismatch prints `ERROR`, and `TEST PASSED` is printed only when there were none.

**APB wrapper test** (`tb/xSPI_apb_tb.sv`), in this order:

1. Reset values of every register, ID included.
2. Writes to read-only registers are ignored.
3. Each RW register: all ones, all zeros, then 16 random writes with every PSTRB byte-lane pattern, read back each time.
4. Unmapped and misaligned addresses, reads and writes: PSLVERR, read data 0, no side effect on other registers.
5. Back-to-back transfers with no idle cycle.
6. IP traffic through the registers only (`tb/apb/xSPI_apb_func.svh`): the programming sequence above, every interrupt bit set, enabled and cleared (100% wrapper toggle coverage confirms each bit moved).
7. PRESETN asserted mid-run: `irq` and PRDATA go to 0, registers return to reset values.

**Checkers** (`tb/cov/xSPI_sva.sv`, `tb/cov/xSPI_apb_sva.sv`): SVA protocol and APB assertions plus covergroups, bound in by the coverage flow. An assertion failure prints `SVA_FAIL` and fails the run even when the test itself passed.

Whole portfolio: `bash scripts/ci_regression.sh` runs steps 1 to 3 for every IP (what CI runs), and `bash scripts/cov/run_all.sh 4` runs step 4 for every IP.

## Verification

Five-metric coverage with Verilator 5.052 (`scripts/cov/run_cov.sh`); see [COVERAGE_CLOSURE.md](../COVERAGE_CLOSURE.md) for the flow. Line and toggle count only the named RTL file.

| Scope | Test | Line | Toggle | FSM | SVA | Functional |
|---|---|---|---|---|---|---|
| core `rtl/xSPI_top.sv` | not run | | | | | |
| wrapper `rtl/xSPI_apb.sv` | not run | | | | | |
