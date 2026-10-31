# SPMI-style target: sequence start, a header of slave address 5 and command, a register address, then a register write (acknowledged) or read

Protocol IP `SPMI`, version 2.0. Apache-2.0.

| Item | Value |
|---|---|
| Core | `SPMI_top` (`rtl/SPMI_top.sv`) |
| Register interface | APB4 slave `SPMI_apb`, 32-bit data, 12-bit byte address, zero wait states |
| Clock, reset | PCLK (rising edge), PRESETN (active low, asynchronous) |
| ID register | 0x534D0200 (code 0x534D, version 2.0) |
| Registers | 8 words, 0x000 to 0x01C |
| Interrupts | 3 sources into one level-high `irq` |
| Data streams | RX (from the core) |
| Protocol pins | 2 pass-through |

## Overview

MIPI SPMI slave: SSC + SA[3:0] + CMD[3:0] + AD[7:0] + DATA[7:0] Simplified command set: CMD 0x0 = register write, 0x1 = register read. Two-wire open-drain style, OpenCores spmi/pmic bus pattern.

sdata (open drain: the target only pulls it low for the ACK and read data) and sclk are the bus pins; they pass through unchanged. Each SCLK phase must last at least three PCLK clocks.
Frame: SSC (SDATA falling while SCLK is high), header {SA[3:0], CMD[3:0]} then the register address, MSB first, sampled on SCLK rising. CMD 0: a data byte follows and the target ACKs it by holding SDATA low for the next bit; CMD 1: the target sends TX on the next 8 bits, each driven from an SCLK fall. Other commands and slave addresses are ignored. This is a simplified SPMI framing: no parity bits, bus park or arbitration.

## Files

| File | Content |
|---|---|
| `rtl/SPMI_top.sv` | protocol core |
| `rtl/SPMI_apb.sv` | APB4 register wrapper (generated) |
| `tb/SPMI_tb.sv` | core testbench |
| `tb/SPMI_apb_tb.sv`, `tb/apb/SPMI_apb_func.svh` | wrapper testbench (generated part + IP-specific part) |
| `tb/cov/SPMI_sva.sv`, `tb/cov/SPMI_apb_sva.sv` | coverage checkers (core, wrapper) |
| `scripts/apb/specs/SPMI.json` | register spec the wrapper, TB, checker and this page are generated from |

How to run the tests and the coverage flow: see [Running and verifying](#running-and-verifying).

## Parameters

`SPMI_apb` has the core's parameters and passes them to `SPMI_top` unchanged.

| Parameter | Type | Default |
|---|---|---|
| `SPMI_ADDR` | logic [3:0] | `4'h5` |

## Wrapper pins

Pins of `SPMI_apb`. Widths of the pass-through pins are at the default parameters.

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
| `sdata` | inout | 1 | protocol pin, core port `sdata` |
| `sclk` | input | 1 | protocol pin, core port `sclk` |

## Core ports

| Port | Dir | Width | In the APB wrapper |
|---|---|---|---|
| `clk` | input | 1 | PCLK |
| `rst_n` | input | 1 | PRESETN |
| `sdata` | inout | 1 | pin (pass-through) |
| `sclk` | input | 1 | pin (pass-through) |
| `rx_byte` | output | 8 | RX[7:0] |
| `rx_addr` | output | 8 | RX[15:8] |
| `rx_valid` | output | 1 | RX capture |
| `tx_byte` | input | 8 | TX[7:0] |
| `busy` | output | 1 | STATUS |
| `irq` | output | 1 | IRQ_STATUS.WRITE |

## APB wrapper

`SPMI_apb` is an APB4 slave (AMBA APB protocol v2.0): zero wait states, 32-bit data, 12-bit byte address, PSTRB byte lanes on every writable register, PSLVERR on an unmapped or misaligned address (reads then return 0, writes are dropped). Writes to read-only registers are ignored without an error. The core runs on PCLK and PRESETN. `irq` is level-high: `|(IRQ_STATUS & IRQ_ENABLE)`.

Pass-through pins: `sdata`, `sclk`.

### Register map

| Offset | Name | Access | Reset | Description |
|---|---|---|---|---|
| 0x000 | ID | RO | 0x534D0200 | IP identification: code, major and minor version |
| 0x004 | IRQ_STATUS | W1C | 0x00000000 | Sticky interrupt bits, write 1 to clear |
| 0x008 | IRQ_ENABLE | RW | 0x00000000 | Interrupt enables; irq = \|(IRQ_STATUS & IRQ_ENABLE) |
| 0x00C | FLAGS | RO | 0x00000000 | Stream holding-register state |
| 0x010 | SCRATCH | RW | 0x00000000 | Scratch register, no effect on the core |
| 0x014 | TX | RW | 0x00000000 | Byte returned for a register read |
| 0x018 | RX | RO (pop) | 0x00000000 | Register writes received (data and register address); reading RX frees it |
| 0x01C | STATUS | RO | core | Target state |

Unlisted bits read 0 and ignore writes. Reset "core": the register reads the core's outputs directly, so after reset it shows the core's own reset state. WO (pulse) registers read 0. Offsets from 0x020 up to 0xFFC are unmapped (PSLVERR).

### Fields

| Register | Bits | Field | Access | Reset | Description |
|---|---|---|---|---|---|
| ID | 31:16 | CODE | RO | 0x534D | IP code |
| ID | 15:8 | MAJOR | RO | 0x02 | major version |
| ID | 7:0 | MINOR | RO | 0x00 | minor version |
| IRQ_STATUS | 2:0 | one bit per interrupt | W1C | 0x0 | see Interrupts |
| IRQ_ENABLE | 2:0 | one bit per interrupt | RW | 0x0 | 1 enables the IRQ_STATUS bit onto `irq` |
| FLAGS | 0 | one bit per stream flag | RO | 0x0 | see FLAGS |
| SCRATCH | 31:0 | SCRATCH | RW | 0x00000000 | free for software |
| TX | 7:0 | `tx_byte` | RW | 0x0 | taken when the register address of a read is complete, sent MSB first |
| RX | 7:0 | `rx_byte` | RO (pop) | 0x0 | data written |
| RX | 15:8 | `rx_addr` | RO (pop) | 0x0 | register address |
| STATUS | 0 | `busy` | RO | core | in a command addressed to us |

### Interrupts (IRQ_STATUS, IRQ_ENABLE)

A bit is set while its source is active, stays set until written with 1, and a set in the same clock as the clear wins.

| Bit | Name | Set when |
|---|---|---|
| 0 | WRITE | a register write was received (the same clock RX captures it) |
| 1 | RX_AVAIL | RX captured a beat |
| 2 | RX_OVF | beat dropped, RX was full |

### FLAGS

| Bit | Name | Meaning |
|---|---|---|
| 0 | RX_AVAIL | RX holds an unread beat |

### Streams

* **RX** captures `rx_byte`, `rx_addr` when `rx_valid` is high and the register is empty (or is being read in the same clock), and sets FLAGS/IRQ RX_AVAIL. Reading RX pops it. A beat that arrives while the register is full is dropped and sets RX_OVF.

## Programming sequence

1. Release PRESETN. Read ID (0x000) and check it is 0x534D0200.
2. Write 0x7 to IRQ_STATUS (0x004) to clear any stale bits.
3. Configure the core: write TX (0x014). Reset values are in the register map; PSTRB selects the bytes written.
4. Write IRQ_ENABLE (0x008) with the interrupts to use (bit order as in the Interrupts table; 0x7 enables all).
5. To receive on RX: wait for IRQ RX_AVAIL or FLAGS.RX_AVAIL (bit 0), then read RX (0x018). Reading the last word frees the register for the next beat; write 1 to IRQ_STATUS.RX_AVAIL (bit 1) to clear it. Read each beat before the next arrives, or it is dropped and RX_OVF is set.
6. Read STATUS (0x01C) for the core's live `busy`; it needs no clearing.
7. On `irq`: read IRQ_STATUS, handle every bit that is set and enabled, then write those bits back to IRQ_STATUS to clear them. A source that is still active sets its bit again.

## Running and verifying

All commands run from the repository root. Icarus Verilog 12 and Yosys 0.33 are enough for steps 1 to 3; step 4 also needs Verilator 5.052 and pyslang (see [README, Setup](../../README.md#setup)).

| Step | Command | Pass when | Output |
|---|---|---|---|
| 1. Core test | `make -f Makefile.SPMI sim` | a `TEST PASSED` line, no `ERROR` | console |
| 2. Core synthesis | `make -f Makefile.SPMI syn` | Yosys ends without `ERROR`; `stat` prints the cell count | `work/SPMI_top.json` |
| 3. APB wrapper test + synthesis | `make -f Makefile.SPMI apb` | `TEST PASSED: SPMI_apb`, then Yosys without `ERROR` | console, `work/SPMI_apb.json` |
| 4. Coverage (core, wrapper) | `bash scripts/cov/run_cov.sh SPMI`<br>`bash scripts/cov/run_cov.sh SPMI_apb` | `RESULT: CLOSED` (all five metrics 100%) | `work/cov/SPMI/score.json`, `work/cov/SPMI_apb/score.json` |

Expected end of a step 4 run:

```
===== SPMI =====
TEST: PASSED   SVA_FAILURES: 0
LINE ... TOGGLE ... FSM ... SVA ... FUNCTIONAL  (each n/n, 100.0%)
RESULT: CLOSED
```

**Core test** (`tb/SPMI_tb.sv`): drives `SPMI_top` through its own ports against a protocol peer or model and checks every result itself; any mismatch prints `ERROR`, and `TEST PASSED` is printed only when there were none.

**APB wrapper test** (`tb/SPMI_apb_tb.sv`), in this order:

1. Reset values of every register, ID included.
2. Writes to read-only registers are ignored.
3. Each RW register: all ones, all zeros, then 16 random writes with every PSTRB byte-lane pattern, read back each time.
4. Unmapped and misaligned addresses, reads and writes: PSLVERR, read data 0, no side effect on other registers.
5. Back-to-back transfers with no idle cycle.
6. IP traffic through the registers only (`tb/apb/SPMI_apb_func.svh`): the programming sequence above, every interrupt bit set, enabled and cleared, stream FULL/AVAIL/OVF cases (100% wrapper toggle coverage confirms each bit moved).
7. PRESETN asserted mid-run: `irq` and PRDATA go to 0, registers return to reset values.

**Checkers** (`tb/cov/SPMI_sva.sv`, `tb/cov/SPMI_apb_sva.sv`): SVA protocol and APB assertions plus covergroups, bound in by the coverage flow. An assertion failure prints `SVA_FAIL` and fails the run even when the test itself passed.

Whole portfolio: `bash scripts/ci_regression.sh` runs steps 1 to 3 for every IP (what CI runs), and `bash scripts/cov/run_all.sh 4` runs step 4 for every IP.

## Verification

Five-metric coverage with Verilator 5.052 (`scripts/cov/run_cov.sh`); see [COVERAGE_CLOSURE.md](../COVERAGE_CLOSURE.md) for the flow. Line and toggle count only the named RTL file.

| Scope | Test | Line | Toggle | FSM | SVA | Functional |
|---|---|---|---|---|---|---|
| core `rtl/SPMI_top.sv` | pass | 44/44 | 162/162 | 12/12 | 6/6 | 62/62 |
| wrapper `rtl/SPMI_apb.sv` | pass | 28/28 | 518/518 | n/a | 8/8 | 42/42 |
