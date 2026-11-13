# I2C controller (master): START / repeated START, byte write with ACK check, byte read with ACK / NACK, STOP

Protocol IP `I2C_Host`, version 1.0. Apache-2.0.

| Item | Value |
|---|---|
| Core | `I2C_Host_top` (`rtl/I2C_Host_top.sv`) |
| Register interface | APB4 slave `I2C_Host_apb`, 32-bit data, 12-bit byte address, zero wait states |
| Clock, reset | PCLK (rising edge), PRESETN (active low, asynchronous) |
| ID register | 0x5C510100 (code 0x5C51, version 1.0) |
| Registers | 10 words, 0x000 to 0x024 |
| Interrupts | 1 sources into one level-high `irq` |
| Protocol pins | 2 pass-through |

## Overview

I2C_Host: I2C controller (master) for sensor / PMIC control The controller role the I2C_top target does not cover. Byte commands in the style of the OpenCores I2C master:

- A command (cmd_valid) is any of: STA (START, or a repeated START when
the bus is held), then WR (send TX_DATA, read the ACK bit into RX_ACK)
or RD (read a byte into RX_DATA, then send ACK, or NACK with NACK = 1),
then STO (STOP). DONE pulses when the command ends; BUSY is high during
it. A command while busy is ignored; STO alone with the bus free does
nothing on the wire; WR or RD with the bus free sends a START first.
- Timing: one quarter of the SCL period is PRESCALE + 1 clocks (at least
3, for targets that sample on their own clock). SCL is driven push-pull
(no clock stretching, single controller); SDA is open drain.
- BUS_HELD: SCL is low between a START and a STOP (the controller owns
the bus).

Features:

- The controller role that the I2C_top target does not cover: sensor, PMIC and EEPROM control.
- Byte commands: STA, then WR (send TX_DATA, ACK bit into RX_ACK) or RD (byte into RX_DATA, then ACK or NACK), then STO.
- One quarter of the SCL period is PRESCALE + 1 clocks (at least 3); SCL push-pull, SDA open drain, single controller, no clock stretching.

scl is driven push-pull and sda is open drain (it only pulls low; an external pull-up is required); both pass through unchanged.

## Files

| File | Content |
|---|---|
| `rtl/I2C_Host_top.sv` | protocol core |
| `rtl/I2C_Host_apb.sv` | APB4 register wrapper (generated) |
| `tb/I2C_Host_tb.sv` | core testbench |
| `tb/I2C_Host_apb_tb.sv`, `tb/apb/I2C_Host_apb_func.svh` | wrapper testbench (generated part + IP-specific part) |
| `tb/cov/I2C_Host_sva.sv`, `tb/cov/I2C_Host_apb_sva.sv` | coverage checkers (core, wrapper) |
| `scripts/apb/specs/I2C_Host.json` | register spec the wrapper, TB, checker and this page are generated from |

How to run the tests and the coverage flow: see [Running and verifying](#running-and-verifying).

## Parameters

The core and the wrapper have no parameters.

## Wrapper pins

Pins of `I2C_Host_apb`. Widths of the pass-through pins are at the default parameters.

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
| `scl` | output | 1 | protocol pin, core port `scl` |
| `sda` | inout | 1 | protocol pin, core port `sda` |

## Core ports

| Port | Dir | Width | In the APB wrapper |
|---|---|---|---|
| `clk` | input | 1 | PCLK |
| `rst_n` | input | 1 | PRESETN |
| `scl` | output | 1 | pin (pass-through) |
| `sda` | inout | 1 | pin (pass-through) |
| `prescale` | input | 16 | PRESCALE[15:0] |
| `cmd_valid` | input | 1 | CMD[0:0] |
| `cmd_sta` | input | 1 | CMD[1:1] |
| `cmd_wr` | input | 1 | CMD[2:2] |
| `cmd_rd` | input | 1 | CMD[3:3] |
| `cmd_sto` | input | 1 | CMD[4:4] |
| `cmd_nack` | input | 1 | CMD[5:5] |
| `tx_data` | input | 8 | TX_DATA[7:0] |
| `rx_data` | output | 8 | RX[7:0] |
| `rx_ack` | output | 1 | RX[8:8] |
| `busy` | output | 1 | STATUS[0:0] |
| `bus_held` | output | 1 | STATUS[1:1] |
| `done` | output | 1 | IRQ_STATUS.DONE |

## APB wrapper

`I2C_Host_apb` is an APB4 slave (AMBA APB protocol v2.0): zero wait states, 32-bit data, 12-bit byte address, PSTRB byte lanes on every writable register, PSLVERR on an unmapped or misaligned address (reads then return 0, writes are dropped). Writes to read-only registers are ignored without an error. The core runs on PCLK and PRESETN. `irq` is level-high: `|(IRQ_STATUS & IRQ_ENABLE)`.

Pass-through pins: `scl`, `sda`.

### Register map

| Offset | Name | Access | Reset | Description |
|---|---|---|---|---|
| 0x000 | ID | RO | 0x5C510100 | IP identification: code, major and minor version |
| 0x004 | IRQ_STATUS | W1C | 0x00000000 | Sticky interrupt bits, write 1 to clear |
| 0x008 | IRQ_ENABLE | RW | 0x00000000 | Interrupt enables; irq = \|(IRQ_STATUS & IRQ_ENABLE) |
| 0x00C | FLAGS | RO | 0x00000000 | Stream holding-register state |
| 0x010 | SCRATCH | RW | 0x00000000 | Scratch register, no effect on the core |
| 0x014 | PRESCALE | RW | 0x00000063 | SCL timing |
| 0x018 | TX_DATA | RW | 0x00000000 | Byte sent by the next WR command |
| 0x01C | CMD | WO (pulse) | 0x00000000 | Command (write 1s; one command per write) |
| 0x020 | RX | RO | core | Result of the last command |
| 0x024 | STATUS | RO | core | State |

Unlisted bits read 0 and ignore writes. Reset "core": the register reads the core's outputs directly, so after reset it shows the core's own reset state. WO (pulse) registers read 0. Offsets from 0x028 up to 0xFFC are unmapped (PSLVERR).

### Fields

| Register | Bits | Field | Access | Reset | Description |
|---|---|---|---|---|---|
| ID | 31:16 | CODE | RO | 0x5C51 | IP code |
| ID | 15:8 | MAJOR | RO | 0x01 | major version |
| ID | 7:0 | MINOR | RO | 0x00 | minor version |
| IRQ_STATUS | 0 | one bit per interrupt | W1C | 0x0 | see Interrupts |
| IRQ_ENABLE | 0 | one bit per interrupt | RW | 0x0 | 1 enables the IRQ_STATUS bit onto `irq` |
| SCRATCH | 31:0 | SCRATCH | RW | 0x00000000 | free for software |
| PRESCALE | 15:0 | `prescale` | RW | 0x63 | quarter SCL period - 1, in clocks (reset 0x63: 100 kHz at 40 MHz) |
| TX_DATA | 7:0 | `tx_data` | RW | 0x0 | MSB first |
| CMD | 0 | `cmd_valid` | WO (pulse) | 0x0 | issue the command made of the other bits |
| CMD | 1 | `cmd_sta` | WO (pulse) | 0x0 | START (repeated START when the bus is held) |
| CMD | 2 | `cmd_wr` | WO (pulse) | 0x0 | write TX_DATA |
| CMD | 3 | `cmd_rd` | WO (pulse) | 0x0 | read a byte (ignored with WR) |
| CMD | 4 | `cmd_sto` | WO (pulse) | 0x0 | STOP at the end |
| CMD | 5 | `cmd_nack` | WO (pulse) | 0x0 | RD: answer NACK instead of ACK |
| RX | 7:0 | `rx_data` | RO | core | byte read by the last RD |
| RX | 8 | `rx_ack` | RO | core | ACK bit after the last WR: 0 ACK, 1 NACK |
| STATUS | 0 | `busy` | RO | core | a command is running |
| STATUS | 1 | `bus_held` | RO | core | between a START and a STOP |

### Interrupts (IRQ_STATUS, IRQ_ENABLE)

A bit is set while its source is active, stays set until written with 1, and a set in the same clock as the clear wins.

| Bit | Name | Set when |
|---|---|---|
| 0 | DONE | a command ended |

## Programming sequence

1. Release PRESETN. Read ID (0x000) and check it is 0x5C510100.
2. Write 0x1 to IRQ_STATUS (0x004) to clear any stale bits.
3. Configure the core: write PRESCALE (0x014), TX_DATA (0x018). Reset values are in the register map; PSTRB selects the bytes written.
4. Write IRQ_ENABLE (0x008) with the interrupts to use (bit order as in the Interrupts table; 0x1 enables all).
5. To issue a command, write 1 to `cmd_valid` (CMD bit 0), `cmd_sta` (CMD bit 1), `cmd_wr` (CMD bit 2), `cmd_rd` (CMD bit 3), `cmd_sto` (CMD bit 4), `cmd_nack` (CMD bit 5) at 0x01C; the core sees a one-clock pulse, and the register reads 0.
6. Read RX (0x020) for the core's live `rx_data`, `rx_ack`; it needs no clearing.
7. Read STATUS (0x024) for the core's live `busy`, `bus_held`; it needs no clearing.
8. On `irq`: read IRQ_STATUS, handle every bit that is set and enabled, then write those bits back to IRQ_STATUS to clear them. A source that is still active sets its bit again.

IP-specific use:

1. Write PRESCALE.
2. Write TX_DATA = {address, R/W}, then CMD = valid | sta | wr; wait for DONE, check RX.rx_ack.
3. For each data byte: TX_DATA and CMD = valid | wr (| sto on the last), or CMD = valid | rd (| nack | sto on the last) and read RX.rx_data.

## Running and verifying

All commands run from the repository root. Icarus Verilog 12 and Yosys 0.33 are enough for steps 1 to 3; step 4 also needs Verilator 5.052 and pyslang (see [README, Setup](../../README.md#setup)).

| Step | Command | Pass when | Output |
|---|---|---|---|
| 1. Core test | `make -f Makefile.I2C_Host sim` | a `TEST PASSED` line, no `ERROR` | console |
| 2. Core synthesis | `make -f Makefile.I2C_Host syn` | Yosys ends without `ERROR`; `stat` prints the cell count | `work/I2C_Host_top.json` |
| 3. APB wrapper test + synthesis | `make -f Makefile.I2C_Host apb` | `TEST PASSED: I2C_Host_apb`, then Yosys without `ERROR` | console, `work/I2C_Host_apb.json` |
| 4. Coverage (core, wrapper) | `bash scripts/cov/run_cov.sh I2C_Host`<br>`bash scripts/cov/run_cov.sh I2C_Host_apb` | `RESULT: CLOSED` (all five metrics 100%) | `work/cov/I2C_Host/score.json`, `work/cov/I2C_Host_apb/score.json` |

Expected end of a step 4 run:

```
===== I2C_Host =====
TEST: PASSED   SVA_FAILURES: 0
LINE ... TOGGLE ... FSM ... SVA ... FUNCTIONAL  (each n/n, 100.0%)
RESULT: CLOSED
```

**Core test** (`tb/I2C_Host_tb.sv`): drives `I2C_Host_top` through its own ports against a protocol peer or model and checks every result itself; any mismatch prints `ERROR`, and `TEST PASSED` is printed only when there were none.

**APB wrapper test** (`tb/I2C_Host_apb_tb.sv`), in this order:

1. Reset values of every register, ID included.
2. Writes to read-only registers are ignored.
3. Each RW register: all ones, all zeros, then 16 random writes with every PSTRB byte-lane pattern, read back each time.
4. Unmapped and misaligned addresses, reads and writes: PSLVERR, read data 0, no side effect on other registers.
5. Back-to-back transfers with no idle cycle.
6. IP traffic through the registers only (`tb/apb/I2C_Host_apb_func.svh`): the programming sequence above, every interrupt bit set, enabled and cleared (100% wrapper toggle coverage confirms each bit moved).
7. PRESETN asserted mid-run: `irq` and PRDATA go to 0, registers return to reset values.

**Checkers** (`tb/cov/I2C_Host_sva.sv`, `tb/cov/I2C_Host_apb_sva.sv`): SVA protocol and APB assertions plus covergroups, bound in by the coverage flow. An assertion failure prints `SVA_FAIL` and fails the run even when the test itself passed.

Whole portfolio: `bash scripts/ci_regression.sh` runs steps 1 to 3 for every IP (what CI runs), and `bash scripts/cov/run_all.sh 4` runs step 4 for every IP.

## Verification

Five-metric coverage with Verilator 5.052 (`scripts/cov/run_cov.sh`); see [COVERAGE_CLOSURE.md](../COVERAGE_CLOSURE.md) for the flow. Line and toggle count only the named RTL file.

| Scope | Test | Line | Toggle | FSM | SVA | Functional |
|---|---|---|---|---|---|---|
| core `rtl/I2C_Host_top.sv` | not run | | | | | |
| wrapper `rtl/I2C_Host_apb.sv` | pass | 29/29 | 548/548 | n/a | 15/15 | 39/39 |
