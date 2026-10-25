# eUSB2 repeater: eD+ / eD- retimed onto USB2 dp / dm, control packets (PID C3, NRZI, bit stuffing, CRC8) writing and reading an 8 x 8 register file with read responses sent on dp / dm, and squelch detection on long SE0

Protocol IP `eUSB2`, version 2.0. Apache-2.0.

| Item | Value |
|---|---|
| Core | `eUSB2_top` (`rtl/eUSB2_top.sv`) |
| Register interface | APB4 slave `eUSB2_apb`, 32-bit data, 12-bit byte address, zero wait states |
| Clock, reset | PCLK (rising edge), PRESETN (active low, asynchronous) |
| ID register | 0x65550200 (code 0x6555, version 2.0) |
| Registers | 6 words, 0x000 to 0x014 |
| Interrupts | 1 sources into one level-high `irq` |
| Protocol pins | 5 pass-through |

## Overview

eUSB2 protocol IP -- eUSB2 device/repeater (simplified) * eD+/eD- single-ended 1.2V signalling, simplified to lvcmos logic levels (J = 10, K = 01, SE0 = 00, SE1 = 11 illegal), 1 bit cell/clk * USB2 packet-layer retimer: the received eUSB2 NRZI bit stream is re-registered and driven onto the standard dp/dm output port * Control messages (control packets, PID 8'hC3): register write/read of an 8x8 register file (reg0 = squelch threshold, reg1 = term config, reg2..7 scratch); read responses are transmitted as a USB2-style frame on dp/dm * Squelch detection: SE0 longer than the programmed threshold forces the retimed outputs silent and resets the packet parser * NRZI decode + bit unstuffing on receive; NRZI encode + bit stuffing on transmit; CRC8 (poly 0x07, init 0xFF) protects control packets * irq (sticky until rst_n): SE1 on the line, bit-stuff error, a truncated or over-long control packet, or a CRC8 mismatch

edp / edm (eUSB2 line in, one bit cell per PCLK), dp / dm (retimed USB2 line out) and squelch pass through unchanged.
The 8 x 8 register file (squelch threshold, termination, scratch) is reached through control packets on the line only.

## Files

| File | Content |
|---|---|
| `rtl/eUSB2_top.sv` | protocol core |
| `rtl/eUSB2_apb.sv` | APB4 register wrapper (generated) |
| `tb/eUSB2_tb.sv` | core testbench |
| `tb/eUSB2_apb_tb.sv`, `tb/apb/eUSB2_apb_func.svh` | wrapper testbench (generated part + IP-specific part) |
| `tb/cov/eUSB2_sva.sv`, `tb/cov/eUSB2_apb_sva.sv` | coverage checkers (core, wrapper) |
| `scripts/apb/specs/eUSB2.json` | register spec the wrapper, TB, checker and this page are generated from |

How to run the tests and the coverage flow: see [Running and verifying](#running-and-verifying).

## Parameters

The core and the wrapper have no parameters.

## Wrapper pins

Pins of `eUSB2_apb`. Widths of the pass-through pins are at the default parameters.

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
| `edp` | input | 1 | protocol pin, core port `edp` |
| `edm` | input | 1 | protocol pin, core port `edm` |
| `dp` | output | 1 | protocol pin, core port `dp` |
| `dm` | output | 1 | protocol pin, core port `dm` |
| `squelch` | output | 1 | protocol pin, core port `squelch` (also read in a register) |

## Core ports

| Port | Dir | Width | In the APB wrapper |
|---|---|---|---|
| `clk` | input | 1 | PCLK |
| `rst_n` | input | 1 | PRESETN |
| `edp` | input | 1 | pin (pass-through) |
| `edm` | input | 1 | pin (pass-through) |
| `dp` | output | 1 | pin (pass-through) |
| `dm` | output | 1 | pin (pass-through) |
| `squelch` | output | 1 | STATUS |
| `irq` | output | 1 | IRQ_STATUS.ERR |

## APB wrapper

`eUSB2_apb` is an APB4 slave (AMBA APB protocol v2.0): zero wait states, 32-bit data, 12-bit byte address, PSTRB byte lanes on every writable register, PSLVERR on an unmapped or misaligned address (reads then return 0, writes are dropped). Writes to read-only registers are ignored without an error. The core runs on PCLK and PRESETN. `irq` is level-high: `|(IRQ_STATUS & IRQ_ENABLE)`.

Pass-through pins: `edp`, `edm`, `dp`, `dm`, `squelch`.

### Register map

| Offset | Name | Access | Reset | Description |
|---|---|---|---|---|
| 0x000 | ID | RO | 0x65550200 | IP identification: code, major and minor version |
| 0x004 | IRQ_STATUS | W1C | 0x00000000 | Sticky interrupt bits, write 1 to clear |
| 0x008 | IRQ_ENABLE | RW | 0x00000000 | Interrupt enables; irq = \|(IRQ_STATUS & IRQ_ENABLE) |
| 0x00C | FLAGS | RO | 0x00000000 | Stream holding-register state |
| 0x010 | SCRATCH | RW | 0x00000000 | Scratch register, no effect on the core |
| 0x014 | STATUS | RO | core | Line state |

Unlisted bits read 0 and ignore writes. Reset "core": the register reads the core's outputs directly, so after reset it shows the core's own reset state. WO (pulse) registers read 0. Offsets from 0x018 up to 0xFFC are unmapped (PSLVERR).

### Fields

| Register | Bits | Field | Access | Reset | Description |
|---|---|---|---|---|---|
| ID | 31:16 | CODE | RO | 0x6555 | IP code |
| ID | 15:8 | MAJOR | RO | 0x02 | major version |
| ID | 7:0 | MINOR | RO | 0x00 | minor version |
| IRQ_STATUS | 0 | one bit per interrupt | W1C | 0x0 | see Interrupts |
| IRQ_ENABLE | 0 | one bit per interrupt | RW | 0x0 | 1 enables the IRQ_STATUS bit onto `irq` |
| SCRATCH | 31:0 | SCRATCH | RW | 0x00000000 | free for software |
| STATUS | 0 | `squelch` | RO | core | signal loss: SE0 longer than the squelch threshold (cleared by J); same as the squelch pin |

### Interrupts (IRQ_STATUS, IRQ_ENABLE)

A bit is set while its source is active, stays set until written with 1, and a set in the same clock as the clear wins.

| Bit | Name | Set when |
|---|---|---|
| 0 | ERR | SE1 on the line, bit-stuff error, truncated or over-long control packet, or CRC8 mismatch. Sticky in the core until PRESETN, so the bit is set again on every clock |

## Programming sequence

1. Release PRESETN. Read ID (0x000) and check it is 0x65550200.
2. Write 0x1 to IRQ_STATUS (0x004) to clear any stale bits.
3. Write IRQ_ENABLE (0x008) with the interrupts to use (bit order as in the Interrupts table; 0x1 enables all).
4. Read STATUS (0x014) for the core's live `squelch`; it needs no clearing.
5. On `irq`: read IRQ_STATUS, handle every bit that is set and enabled, then write those bits back to IRQ_STATUS to clear them. A source that is still active sets its bit again.

## Running and verifying

All commands run from the repository root. Icarus Verilog 12 and Yosys 0.33 are enough for steps 1 to 3; step 4 also needs Verilator 5.052 and pyslang (see [README, Setup](../../README.md#setup)).

| Step | Command | Pass when | Output |
|---|---|---|---|
| 1. Core test | `make -f Makefile.eUSB2 sim` | a `TEST PASSED` line, no `ERROR` | console |
| 2. Core synthesis | `make -f Makefile.eUSB2 syn` | Yosys ends without `ERROR`; `stat` prints the cell count | `work/eUSB2_top.json` |
| 3. APB wrapper test + synthesis | `make -f Makefile.eUSB2 apb` | `TEST PASSED: eUSB2_apb`, then Yosys without `ERROR` | console, `work/eUSB2_apb.json` |
| 4. Coverage (core, wrapper) | `bash scripts/cov/run_cov.sh eUSB2`<br>`bash scripts/cov/run_cov.sh eUSB2_apb` | `RESULT: CLOSED` (all five metrics 100%) | `work/cov/eUSB2/score.json`, `work/cov/eUSB2_apb/score.json` |

Expected end of a step 4 run:

```
===== eUSB2 =====
TEST: PASSED   SVA_FAILURES: 0
LINE ... TOGGLE ... FSM ... SVA ... FUNCTIONAL  (each n/n, 100.0%)
RESULT: CLOSED
```

**Core test** (`tb/eUSB2_tb.sv`): drives `eUSB2_top` through its own ports against a protocol peer or model and checks every result itself; any mismatch prints `ERROR`, and `TEST PASSED` is printed only when there were none.

**APB wrapper test** (`tb/eUSB2_apb_tb.sv`), in this order:

1. Reset values of every register, ID included.
2. Writes to read-only registers are ignored.
3. Each RW register: all ones, all zeros, then 16 random writes with every PSTRB byte-lane pattern, read back each time.
4. Unmapped and misaligned addresses, reads and writes: PSLVERR, read data 0, no side effect on other registers.
5. Back-to-back transfers with no idle cycle.
6. IP traffic through the registers only (`tb/apb/eUSB2_apb_func.svh`): the programming sequence above, every interrupt bit set, enabled and cleared (100% wrapper toggle coverage confirms each bit moved).
7. PRESETN asserted mid-run: `irq` and PRDATA go to 0, registers return to reset values.

**Checkers** (`tb/cov/eUSB2_sva.sv`, `tb/cov/eUSB2_apb_sva.sv`): SVA protocol and APB assertions plus covergroups, bound in by the coverage flow. An assertion failure prints `SVA_FAIL` and fails the run even when the test itself passed.

Whole portfolio: `bash scripts/ci_regression.sh` runs steps 1 to 3 for every IP (what CI runs), and `bash scripts/cov/run_all.sh 4` runs step 4 for every IP.

## Verification

Five-metric coverage with Verilator 5.052 (`scripts/cov/run_cov.sh`); see [COVERAGE_CLOSURE.md](../COVERAGE_CLOSURE.md) for the flow. Line and toggle count only the named RTL file.

| Scope | Test | Line | Toggle | FSM | SVA | Functional |
|---|---|---|---|---|---|---|
| core `rtl/eUSB2_top.sv` | pass | 108/108 (+1 excl.) | 394/394 | 16/16 | 6/6 | 74/74 |
| wrapper `rtl/eUSB2_apb.sv` | pass | 20/20 | 406/406 | n/a | 7/7 | 25/25 |
