# SMBus 3.x target with the PMBus 1.3 command layer: PEC, clock stretching, STATUS_CML fault reporting, WRITE_PROTECT, SMBALERT# with the Alert Response Address, spike filter, SDA hold time, bus timeout

Protocol IP `SMBus`, version 1.0. Apache-2.0.

| Item | Value |
|---|---|
| Core | `SMBus_top` (`rtl/SMBus_top.sv`) |
| Register interface | APB4 slave `SMBus_apb`, 32-bit data, 12-bit byte address, zero wait states |
| Clock, reset | PCLK (rising edge), PRESETN (active low, asynchronous) |
| ID register | 0x53420100 (code 0x5342, version 1.0) |
| Registers | 9 words, 0x000 to 0x020 |
| Interrupts | 3 sources into one level-high `irq` |
| Protocol pins | 5 pass-through |

## Overview

SMBus 3.x target with the PMBus 1.3 command layer (a voltage-regulator style device): open-drain SCL / SDA, START / repeated START / STOP, Packet Error Checking, clock stretching, SMBALERT# with the Alert Response Address, bus timeout. * Bus: SCL and SDA are synchronised and spike-filtered (FILT clocks, tSP); SDA is changed HOLD clocks after SCL falls (tHD;DAT). After each ACKed address byte the target holds SCL low for STRETCH clocks. * Protocols: Send Byte, Write Byte / Word, Read Byte / Word and Block Read, each with an optional PEC byte (CRC-8, x^8 + x^2 + x + 1). A write takes effect at STOP, only if it carried the full data and at most one correct PEC; a read sends its data, then the PEC while the host keeps ACKing, then 0xFF. * Commands: OPERATION 01, ON_OFF_CONFIG 02, CLEAR_FAULTS 03, WRITE_PROTECT 10, CAPABILITY 19, VOUT_MODE 20, VOUT_COMMAND 21, STATUS_BYTE 78, STATUS_WORD 79, STATUS_CML 7E, READ_VOUT 8B, PMBUS_REVISION 98, MFR_ID 99 (block read). * STATUS_CML: [7] unsupported command (command byte NACKed, or a read of a write-only command), [6] invalid data (too many or too few data bytes, a write to a protected or read-only command, a bad WRITE_PROTECT value; the data byte is NACKed), [5] PEC failed (the PEC byte is NACKed), [1] other (bus timeout). Any fault, or a VOUT overvoltage reported on vout_ov, latches and pulls SMBALERT# low. * SMBALERT#: released when the host reads the Alert Response Address (0x0C) and this target wins the address arbitration, or by CLEAR_FAULTS; a new fault pulls it again. * WRITE_PROTECT: 0x80 only WRITE_PROTECT is writable, 0x40 also OPERATION, 0x20 also ON_OFF_CONFIG and VOUT_COMMAND (every writable command here), 0x00 all. CLEAR_FAULTS is always accepted. * Timeout: SCL low for TIMEOUT clocks in a transfer (tTIMEOUT) ends the transfer, releases both lines and sets STATUS_CML[1]. Arbitration: a target that sends a 1 and sees SDA low stops sending.

Features:

- SMBus 3.x target at address ADDR (default 0x5A): Send Byte, Write Byte / Word, Read Byte / Word and Block Read, each with an optional PEC byte (CRC-8).
- PMBus 1.3 commands OPERATION, ON_OFF_CONFIG, CLEAR_FAULTS, WRITE_PROTECT, CAPABILITY, VOUT_MODE, VOUT_COMMAND, STATUS_BYTE, STATUS_WORD, STATUS_CML, READ_VOUT, PMBUS_REVISION and MFR_ID.
- Fault reporting in STATUS_CML (unsupported command, invalid data, PEC failed, other communication fault) with the matching byte NACKed; a write only takes effect at STOP when it was complete and error-free.
- SMBALERT# with the Alert Response Address (0x0C): the target returns its address, releases SMBALERT# when it wins the arbitration, and pulls it again on a new fault.
- Bus timing: SCL / SDA spike filter of FILT clocks, SDA changed HOLD clocks after SCL falls, SCL stretched for STRETCH clocks after each address ACK, tTIMEOUT after TIMEOUT clocks of SCL low.

scl and sda are the bus inputs; scl_o, sda_o and smbalert_n are open-drain outputs (0 pulls the line low). They pass through unchanged.
Not implemented: the SMBus Address Resolution Protocol (fixed address), Host Notify, Quick Command, Block Write and the PMBus fault-response, limit and telemetry commands beyond READ_VOUT.

## Files

| File | Content |
|---|---|
| `rtl/SMBus_top.sv` | protocol core |
| `rtl/SMBus_apb.sv` | APB4 register wrapper (generated) |
| `tb/SMBus_tb.sv` | core testbench |
| `tb/SMBus_apb_tb.sv`, `tb/apb/SMBus_apb_func.svh` | wrapper testbench (generated part + IP-specific part) |
| `tb/cov/SMBus_sva.sv`, `tb/cov/SMBus_apb_sva.sv` | coverage checkers (core, wrapper) |
| `scripts/apb/specs/SMBus.json` | register spec the wrapper, TB, checker and this page are generated from |

How to run the tests and the coverage flow: see [Running and verifying](#running-and-verifying).

## Parameters

`SMBus_apb` has the core's parameters and passes them to `SMBus_top` unchanged.

| Parameter | Type | Default |
|---|---|---|
| `ADDR` | logic [6:0] | `7'h5A` |
| `FILT` | int | `3` |
| `HOLD` | int | `4` |
| `STRETCH` | int | `8` |
| `TIMEOUT` | int | `2500000` |

## Wrapper pins

Pins of `SMBus_apb`. Widths of the pass-through pins are at the default parameters.

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
| `scl` | input | 1 | protocol pin, core port `scl` |
| `sda` | input | 1 | protocol pin, core port `sda` |
| `scl_o` | output | 1 | protocol pin, core port `scl_o` |
| `sda_o` | output | 1 | protocol pin, core port `sda_o` |
| `smbalert_n` | output | 1 | protocol pin, core port `smbalert_n` |

## Core ports

| Port | Dir | Width | In the APB wrapper |
|---|---|---|---|
| `clk` | input | 1 | PCLK |
| `rst_n` | input | 1 | PRESETN |
| `scl` | input | 1 | pin (pass-through) |
| `sda` | input | 1 | pin (pass-through) |
| `scl_o` | output | 1 | pin (pass-through) |
| `sda_o` | output | 1 | pin (pass-through) |
| `smbalert_n` | output | 1 | pin (pass-through) |
| `operation` | output | 8 | CTRL[7:0] |
| `on_off_config` | output | 8 | CTRL[15:8] |
| `vout_command` | output | 16 | VOUT[15:0] |
| `read_vout` | input | 16 | TELEMETRY[15:0] |
| `vout_ov` | input | 1 | FAULT |
| `irq_cml` | output | 1 | IRQ_STATUS.CML |
| `irq_upd` | output | 1 | IRQ_STATUS.UPD |
| `irq_to` | output | 1 | IRQ_STATUS.TO |

## APB wrapper

`SMBus_apb` is an APB4 slave (AMBA APB protocol v2.0): zero wait states, 32-bit data, 12-bit byte address, PSTRB byte lanes on every writable register, PSLVERR on an unmapped or misaligned address (reads then return 0, writes are dropped). Writes to read-only registers are ignored without an error. The core runs on PCLK and PRESETN. `irq` is level-high: `|(IRQ_STATUS & IRQ_ENABLE)`.

Pass-through pins: `scl`, `sda`, `scl_o`, `sda_o`, `smbalert_n`.

### Register map

| Offset | Name | Access | Reset | Description |
|---|---|---|---|---|
| 0x000 | ID | RO | 0x53420100 | IP identification: code, major and minor version |
| 0x004 | IRQ_STATUS | W1C | 0x00000000 | Sticky interrupt bits, write 1 to clear |
| 0x008 | IRQ_ENABLE | RW | 0x00000000 | Interrupt enables; irq = \|(IRQ_STATUS & IRQ_ENABLE) |
| 0x00C | FLAGS | RO | 0x00000000 | Stream holding-register state |
| 0x010 | SCRATCH | RW | 0x00000000 | Scratch register, no effect on the core |
| 0x014 | VOUT | RO | core | Output-voltage set point commanded over PMBus |
| 0x018 | CTRL | RO | core | On / off control commanded over PMBus |
| 0x01C | TELEMETRY | RW | 0x00000000 | Measured output voltage, returned by READ_VOUT (8Bh) |
| 0x020 | FAULT | WO (pulse) | 0x00000000 | Power-stage faults |

Unlisted bits read 0 and ignore writes. Reset "core": the register reads the core's outputs directly, so after reset it shows the core's own reset state. WO (pulse) registers read 0. Offsets from 0x024 up to 0xFFC are unmapped (PSLVERR).

### Fields

| Register | Bits | Field | Access | Reset | Description |
|---|---|---|---|---|---|
| ID | 31:16 | CODE | RO | 0x5342 | IP code |
| ID | 15:8 | MAJOR | RO | 0x01 | major version |
| ID | 7:0 | MINOR | RO | 0x00 | minor version |
| IRQ_STATUS | 2:0 | one bit per interrupt | W1C | 0x0 | see Interrupts |
| IRQ_ENABLE | 2:0 | one bit per interrupt | RW | 0x0 | 1 enables the IRQ_STATUS bit onto `irq` |
| SCRATCH | 31:0 | SCRATCH | RW | 0x00000000 | free for software |
| VOUT | 15:0 | `vout_command` | RO | core | VOUT_COMMAND (21h), linear 16-bit mantissa, exponent from VOUT_MODE (-9) |
| CTRL | 7:0 | `operation` | RO | core | OPERATION (01h); bit 7 = on |
| CTRL | 15:8 | `on_off_config` | RO | core | ON_OFF_CONFIG (02h) |
| TELEMETRY | 15:0 | `read_vout` | RW | 0x0 | READ_VOUT value |
| FAULT | 0 | `vout_ov` | WO (pulse) | 0x0 | write 1: a VOUT overvoltage fault; latched into STATUS_BYTE / STATUS_WORD and SMBALERT# until CLEAR_FAULTS |

### Interrupts (IRQ_STATUS, IRQ_ENABLE)

A bit is set while its source is active, stays set until written with 1, and a set in the same clock as the clear wins.

| Bit | Name | Set when |
|---|---|---|
| 0 | CML | a STATUS_CML bit was set (unsupported command, invalid data, PEC failure, bus timeout) |
| 1 | UPD | the host wrote OPERATION, ON_OFF_CONFIG or VOUT_COMMAND |
| 2 | TO | SCL was held low for TIMEOUT clocks in a transfer; the target released the bus |

## Programming sequence

1. Release PRESETN. Read ID (0x000) and check it is 0x53420100.
2. Write 0x7 to IRQ_STATUS (0x004) to clear any stale bits.
3. Configure the core: write TELEMETRY (0x01C). Reset values are in the register map; PSTRB selects the bytes written.
4. Write IRQ_ENABLE (0x008) with the interrupts to use (bit order as in the Interrupts table; 0x7 enables all).
5. Read VOUT (0x014) for the core's live `vout_command`; it needs no clearing.
6. Read CTRL (0x018) for the core's live `operation`, `on_off_config`; it needs no clearing.
7. To issue a command, write 1 to `vout_ov` (FAULT bit 0) at 0x020; the core sees a one-clock pulse, and the register reads 0.
8. On `irq`: read IRQ_STATUS, handle every bit that is set and enabled, then write those bits back to IRQ_STATUS to clear them. A source that is still active sets its bit again.

## Running and verifying

All commands run from the repository root. Icarus Verilog 12 and Yosys 0.33 are enough for steps 1 to 3; step 4 also needs Verilator 5.052 and pyslang (see [README, Setup](../../README.md#setup)).

| Step | Command | Pass when | Output |
|---|---|---|---|
| 1. Core test | `make -f Makefile.SMBus sim` | a `TEST PASSED` line, no `ERROR` | console |
| 2. Core synthesis | `make -f Makefile.SMBus syn` | Yosys ends without `ERROR`; `stat` prints the cell count | `work/SMBus_top.json` |
| 3. APB wrapper test + synthesis | `make -f Makefile.SMBus apb` | `TEST PASSED: SMBus_apb`, then Yosys without `ERROR` | console, `work/SMBus_apb.json` |
| 4. Coverage (core, wrapper) | `bash scripts/cov/run_cov.sh SMBus`<br>`bash scripts/cov/run_cov.sh SMBus_apb` | `RESULT: CLOSED` (all five metrics 100%) | `work/cov/SMBus/score.json`, `work/cov/SMBus_apb/score.json` |

Expected end of a step 4 run:

```
===== SMBus =====
TEST: PASSED   SVA_FAILURES: 0
LINE ... TOGGLE ... FSM ... SVA ... FUNCTIONAL  (each n/n, 100.0%)
RESULT: CLOSED
```

**Core test** (`tb/SMBus_tb.sv`): drives `SMBus_top` through its own ports against a protocol peer or model and checks every result itself; any mismatch prints `ERROR`, and `TEST PASSED` is printed only when there were none.

**APB wrapper test** (`tb/SMBus_apb_tb.sv`), in this order:

1. Reset values of every register, ID included.
2. Writes to read-only registers are ignored.
3. Each RW register: all ones, all zeros, then 16 random writes with every PSTRB byte-lane pattern, read back each time.
4. Unmapped and misaligned addresses, reads and writes: PSLVERR, read data 0, no side effect on other registers.
5. Back-to-back transfers with no idle cycle.
6. IP traffic through the registers only (`tb/apb/SMBus_apb_func.svh`): the programming sequence above, every interrupt bit set, enabled and cleared (100% wrapper toggle coverage confirms each bit moved).
7. PRESETN asserted mid-run: `irq` and PRDATA go to 0, registers return to reset values.

**Checkers** (`tb/cov/SMBus_sva.sv`, `tb/cov/SMBus_apb_sva.sv`): SVA protocol and APB assertions plus covergroups, bound in by the coverage flow. An assertion failure prints `SVA_FAIL` and fails the run even when the test itself passed.

Whole portfolio: `bash scripts/ci_regression.sh` runs steps 1 to 3 for every IP (what CI runs), and `bash scripts/cov/run_all.sh 4` runs step 4 for every IP.

## Verification

Five-metric coverage with Verilator 5.052 (`scripts/cov/run_cov.sh`); see [COVERAGE_CLOSURE.md](../COVERAGE_CLOSURE.md) for the flow. Line and toggle count only the named RTL file.

| Scope | Test | Line | Toggle | FSM | SVA | Functional |
|---|---|---|---|---|---|---|
| core `rtl/SMBus_top.sv` | not run | | | | | |
| wrapper `rtl/SMBus_apb.sv` | not run | | | | | |
