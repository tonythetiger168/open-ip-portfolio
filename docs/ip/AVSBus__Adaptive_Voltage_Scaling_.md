# AVSBus voltage-control slave at address 0x55: START, address, command, 16-bit data, CRC4 and ACK over sclk / sdat, SET and GET of a 12-bit DAC code ramped at 10 codes per clock

Protocol IP `AVSBus__Adaptive_Voltage_Scaling_`, version 2.0. Apache-2.0.

| Item | Value |
|---|---|
| Core | `AVSBus__Adaptive_Voltage_Scaling__top` (`rtl/AVSBus__Adaptive_Voltage_Scaling__top.sv`) |
| Register interface | APB4 slave `AVSBus__Adaptive_Voltage_Scaling__apb`, 32-bit data, 12-bit byte address, zero wait states |
| Clock, reset | PCLK (rising edge), PRESETN (active low, asynchronous) |
| ID register | 0x41560200 (code 0x4156, version 2.0) |
| Registers | 6 words, 0x000 to 0x014 |
| Interrupts | 1 sources into one level-high `irq` |
| Protocol pins | 4 pass-through |

## Overview

AVSBus (Adaptive Voltage Scaling, PMBus-style) -- synthesizable slave Scope: serial sclk/sdat (open-drain) frame interface: START + addr[6:0] + cmd[7:0] + data[15:0] + CRC4 + ACK/NACK slot, GET reads back {4'h0, vdac} + CRC4; set/get voltage commands with an internal 12-bit DAC code register and a voltage ramp FSM (10 mV/clk, 1 code = 1 mV). NACK on illegal address / bad CRC / unknown command / a SET code that does not fit the 12-bit DAC (data[15:12] != 0). A frame abandoned by the master (no sclk rise for TIMEOUT clk cycles) is dropped, so the next START is decoded from bit 0.

sclk and sdat (open drain: the slave only pulls it low, for the ACK and the GET readback) are the bus pins; they pass through unchanged. Both are sampled on PCLK, so each sclk phase must last at least three PCLK clocks. vdac and busy drive the regulator and are also readable in STATUS.
The voltage is set and read only over AVSBus (SET 0x01, GET 0x02); the APB side observes it. A frame with no sclk rise for TIMEOUT (1024) clocks is dropped. A frame to another address is not acknowledged and raises no interrupt.

## Files

| File | Content |
|---|---|
| `rtl/AVSBus__Adaptive_Voltage_Scaling__top.sv` | protocol core |
| `rtl/AVSBus__Adaptive_Voltage_Scaling__apb.sv` | APB4 register wrapper (generated) |
| `tb/AVSBus__Adaptive_Voltage_Scaling__tb.sv` | core testbench |
| `tb/AVSBus__Adaptive_Voltage_Scaling__apb_tb.sv`, `tb/apb/AVSBus__Adaptive_Voltage_Scaling__apb_func.svh` | wrapper testbench (generated part + IP-specific part) |
| `tb/cov/AVSBus__Adaptive_Voltage_Scaling__sva.sv`, `tb/cov/AVSBus__Adaptive_Voltage_Scaling__apb_sva.sv` | coverage checkers (core, wrapper) |
| `scripts/apb/specs/AVSBus__Adaptive_Voltage_Scaling_.json` | register spec the wrapper, TB, checker and this page are generated from |

How to run the tests and the coverage flow: see [Running and verifying](#running-and-verifying).

## Parameters

`AVSBus__Adaptive_Voltage_Scaling__apb` has the core's parameters and passes them to `AVSBus__Adaptive_Voltage_Scaling__top` unchanged.

| Parameter | Type | Default |
|---|---|---|
| `DW` | int | `32` |
| `AW` | int | `32` |
| `TIMEOUT` | int | `1024` |

## Wrapper pins

Pins of `AVSBus__Adaptive_Voltage_Scaling__apb`. Widths of the pass-through pins are at the default parameters.

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
| `sdat` | inout | 1 | protocol pin, core port `sdat` |
| `vdac` | output | 12 | protocol pin, core port `vdac` (also read in a register) |
| `busy` | output | 1 | protocol pin, core port `busy` (also read in a register) |

## Core ports

| Port | Dir | Width | In the APB wrapper |
|---|---|---|---|
| `clk` | input | 1 | PCLK |
| `rst_n` | input | 1 | PRESETN |
| `sclk` | input | 1 | pin (pass-through) |
| `sdat` | inout | 1 | pin (pass-through) |
| `vdac` | output | 12 | STATUS[11:0] |
| `busy` | output | 1 | STATUS[12:12] |
| `irq` | output | 1 | IRQ_STATUS.ERROR |

## APB wrapper

`AVSBus__Adaptive_Voltage_Scaling__apb` is an APB4 slave (AMBA APB protocol v2.0): zero wait states, 32-bit data, 12-bit byte address, PSTRB byte lanes on every writable register, PSLVERR on an unmapped or misaligned address (reads then return 0, writes are dropped). Writes to read-only registers are ignored without an error. The core runs on PCLK and PRESETN. `irq` is level-high: `|(IRQ_STATUS & IRQ_ENABLE)`.

Pass-through pins: `sclk`, `sdat`, `vdac`, `busy`.

### Register map

| Offset | Name | Access | Reset | Description |
|---|---|---|---|---|
| 0x000 | ID | RO | 0x41560200 | IP identification: code, major and minor version |
| 0x004 | IRQ_STATUS | W1C | 0x00000000 | Sticky interrupt bits, write 1 to clear |
| 0x008 | IRQ_ENABLE | RW | 0x00000000 | Interrupt enables; irq = \|(IRQ_STATUS & IRQ_ENABLE) |
| 0x00C | FLAGS | RO | 0x00000000 | Stream holding-register state |
| 0x010 | SCRATCH | RW | 0x00000000 | Scratch register, no effect on the core |
| 0x014 | STATUS | RO | core | Voltage state, as driven on the pins |

Unlisted bits read 0 and ignore writes. Reset "core": the register reads the core's outputs directly, so after reset it shows the core's own reset state. WO (pulse) registers read 0. Offsets from 0x018 up to 0xFFC are unmapped (PSLVERR).

### Fields

| Register | Bits | Field | Access | Reset | Description |
|---|---|---|---|---|---|
| ID | 31:16 | CODE | RO | 0x4156 | IP code |
| ID | 15:8 | MAJOR | RO | 0x02 | major version |
| ID | 7:0 | MINOR | RO | 0x00 | minor version |
| IRQ_STATUS | 0 | one bit per interrupt | W1C | 0x0 | see Interrupts |
| IRQ_ENABLE | 0 | one bit per interrupt | RW | 0x0 | 1 enables the IRQ_STATUS bit onto `irq` |
| SCRATCH | 31:0 | SCRATCH | RW | 0x00000000 | free for software |
| STATUS | 11:0 | `vdac` | RO | core | current DAC code (1 code = 1 mV), moving 10 codes per clock toward the last target SET |
| STATUS | 12 | `busy` | RO | core | high while vdac has not reached the target |

### Interrupts (IRQ_STATUS, IRQ_ENABLE)

A bit is set while its source is active, stays set until written with 1, and a set in the same clock as the clear wins.

| Bit | Name | Set when |
|---|---|---|
| 0 | ERROR | a frame to our address was NACKed for a bad CRC or a bad command (unknown command, or a SET code above 0xFFF) |

## Programming sequence

1. Release PRESETN. Read ID (0x000) and check it is 0x41560200.
2. Write 0x1 to IRQ_STATUS (0x004) to clear any stale bits.
3. Write IRQ_ENABLE (0x008) with the interrupts to use (bit order as in the Interrupts table; 0x1 enables all).
4. Read STATUS (0x014) for the core's live `vdac`, `busy`; it needs no clearing.
5. On `irq`: read IRQ_STATUS, handle every bit that is set and enabled, then write those bits back to IRQ_STATUS to clear them. A source that is still active sets its bit again.

## Running and verifying

All commands run from the repository root. Icarus Verilog 12 and Yosys 0.33 are enough for steps 1 to 3; step 4 also needs Verilator 5.052 and pyslang (see [README, Setup](../../README.md#setup)).

| Step | Command | Pass when | Output |
|---|---|---|---|
| 1. Core test | `make -f Makefile.AVSBus__Adaptive_Voltage_Scaling_ sim` | a `TEST PASSED` line, no `ERROR` | console |
| 2. Core synthesis | `make -f Makefile.AVSBus__Adaptive_Voltage_Scaling_ syn` | Yosys ends without `ERROR`; `stat` prints the cell count | `work/AVSBus__Adaptive_Voltage_Scaling__top.json` |
| 3. APB wrapper test + synthesis | `make -f Makefile.AVSBus__Adaptive_Voltage_Scaling_ apb` | `TEST PASSED: AVSBus__Adaptive_Voltage_Scaling__apb`, then Yosys without `ERROR` | console, `work/AVSBus__Adaptive_Voltage_Scaling__apb.json` |
| 4. Coverage (core, wrapper) | `bash scripts/cov/run_cov.sh AVSBus__Adaptive_Voltage_Scaling_`<br>`bash scripts/cov/run_cov.sh AVSBus__Adaptive_Voltage_Scaling__apb` | `RESULT: CLOSED` (all five metrics 100%) | `work/cov/AVSBus__Adaptive_Voltage_Scaling_/score.json`, `work/cov/AVSBus__Adaptive_Voltage_Scaling__apb/score.json` |

Expected end of a step 4 run:

```
===== AVSBus__Adaptive_Voltage_Scaling_ =====
TEST: PASSED   SVA_FAILURES: 0
LINE ... TOGGLE ... FSM ... SVA ... FUNCTIONAL  (each n/n, 100.0%)
RESULT: CLOSED
```

**Core test** (`tb/AVSBus__Adaptive_Voltage_Scaling__tb.sv`): drives `AVSBus__Adaptive_Voltage_Scaling__top` through its own ports against a protocol peer or model and checks every result itself; any mismatch prints `ERROR`, and `TEST PASSED` is printed only when there were none.

**APB wrapper test** (`tb/AVSBus__Adaptive_Voltage_Scaling__apb_tb.sv`), in this order:

1. Reset values of every register, ID included.
2. Writes to read-only registers are ignored.
3. Each RW register: all ones, all zeros, then 16 random writes with every PSTRB byte-lane pattern, read back each time.
4. Unmapped and misaligned addresses, reads and writes: PSLVERR, read data 0, no side effect on other registers.
5. Back-to-back transfers with no idle cycle.
6. IP traffic through the registers only (`tb/apb/AVSBus__Adaptive_Voltage_Scaling__apb_func.svh`): the programming sequence above, every interrupt bit set, enabled and cleared (100% wrapper toggle coverage confirms each bit moved).
7. PRESETN asserted mid-run: `irq` and PRDATA go to 0, registers return to reset values.

**Checkers** (`tb/cov/AVSBus__Adaptive_Voltage_Scaling__sva.sv`, `tb/cov/AVSBus__Adaptive_Voltage_Scaling__apb_sva.sv`): SVA protocol and APB assertions plus covergroups, bound in by the coverage flow. An assertion failure prints `SVA_FAIL` and fails the run even when the test itself passed.

Whole portfolio: `bash scripts/ci_regression.sh` runs steps 1 to 3 for every IP (what CI runs), and `bash scripts/cov/run_all.sh 4` runs step 4 for every IP.

## Verification

Five-metric coverage with Verilator 5.052 (`scripts/cov/run_cov.sh`); see [COVERAGE_CLOSURE.md](../COVERAGE_CLOSURE.md) for the flow. Line and toggle count only the named RTL file.

| Scope | Test | Line | Toggle | FSM | SVA | Functional |
|---|---|---|---|---|---|---|
| core `rtl/AVSBus__Adaptive_Voltage_Scaling__top.sv` | pass | 51/51 (+1 excl.) | 352/352 | 12/12 | 5/5 | 35/35 |
| wrapper `rtl/AVSBus__Adaptive_Voltage_Scaling__apb.sv` | pass | 20/20 | 450/450 | n/a | 7/7 | 25/25 |
