# 1-Wire target: reset / presence, write slots assembling a byte (LSB first), then read slots returning a byte

Protocol IP `_1_Wire`, version 2.0. Apache-2.0.

| Item | Value |
|---|---|
| Core | `_1_Wire_top` (`rtl/_1_Wire_top.sv`) |
| Register interface | APB4 slave `_1_Wire_apb`, 32-bit data, 12-bit byte address, zero wait states |
| Clock, reset | PCLK (rising edge), PRESETN (active low, asynchronous) |
| ID register | 0x31570200 (code 0x3157, version 2.0) |
| Registers | 8 words, 0x000 to 0x01C |
| Interrupts | 3 sources into one level-high `irq` |
| Data streams | RX (from the core) |
| Protocol pins | 1 pass-through |

## Overview

1-Wire slave: reset/presence detect, write slots (rx), read slots (tx) Timing in units of US (clk cycles per microsecond); LSB-first bytes. OpenCores onewire slave style.

dq (open drain: the target only pulls it low) is the 1-Wire pin; it passes through unchanged. Timing is in units of US = 10 PCLK clocks per microsecond (the core parameter): a reset is more than 480 us low, the presence pulse follows 15 us after release for 120 us, write slots are sampled 30 us after their falling edge, a 0 read slot is held low for 40 us.
After a byte is received the target sends TX on the next 8 read slots, then waits for the next byte. A reset pulse at any point restarts with a presence pulse. ROM commands (Read ROM, Match ROM, Search ROM) are not implemented: every byte is data.

## Files

| File | Content |
|---|---|
| `rtl/_1_Wire_top.sv` | protocol core |
| `rtl/_1_Wire_apb.sv` | APB4 register wrapper (generated) |
| `tb/_1_Wire_tb.sv` | core testbench |
| `tb/_1_Wire_apb_tb.sv`, `tb/apb/_1_Wire_apb_func.svh` | wrapper testbench (generated part + IP-specific part) |
| `tb/cov/_1_Wire_sva.sv`, `tb/cov/_1_Wire_apb_sva.sv` | coverage checkers (core, wrapper) |
| `scripts/apb/specs/_1_Wire.json` | register spec the wrapper, TB, checker and this page are generated from |

How to run the tests and the coverage flow: see [Running and verifying](#running-and-verifying).

## Parameters

`_1_Wire_apb` has the core's parameters and passes them to `_1_Wire_top` unchanged.

| Parameter | Type | Default |
|---|---|---|
| `US` | int | `10` |

## Wrapper pins

Pins of `_1_Wire_apb`. Widths of the pass-through pins are at the default parameters.

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
| `dq` | inout | 1 | protocol pin, core port `dq` |

## Core ports

| Port | Dir | Width | In the APB wrapper |
|---|---|---|---|
| `clk` | input | 1 | PCLK |
| `rst_n` | input | 1 | PRESETN |
| `dq` | inout | 1 | pin (pass-through) |
| `tx_byte` | input | 8 | TX[7:0] |
| `rx_byte` | output | 8 | RX[7:0] |
| `rx_valid` | output | 1 | RX capture |
| `busy` | output | 1 | STATUS |
| `irq` | output | 1 | IRQ_STATUS.BYTE |

## APB wrapper

`_1_Wire_apb` is an APB4 slave (AMBA APB protocol v2.0): zero wait states, 32-bit data, 12-bit byte address, PSTRB byte lanes on every writable register, PSLVERR on an unmapped or misaligned address (reads then return 0, writes are dropped). Writes to read-only registers are ignored without an error. The core runs on PCLK and PRESETN. `irq` is level-high: `|(IRQ_STATUS & IRQ_ENABLE)`.

Pass-through pins: `dq`.

### Register map

| Offset | Name | Access | Reset | Description |
|---|---|---|---|---|
| 0x000 | ID | RO | 0x31570200 | IP identification: code, major and minor version |
| 0x004 | IRQ_STATUS | W1C | 0x00000000 | Sticky interrupt bits, write 1 to clear |
| 0x008 | IRQ_ENABLE | RW | 0x00000000 | Interrupt enables; irq = \|(IRQ_STATUS & IRQ_ENABLE) |
| 0x00C | FLAGS | RO | 0x00000000 | Stream holding-register state |
| 0x010 | SCRATCH | RW | 0x00000000 | Scratch register, no effect on the core |
| 0x014 | TX | RW | 0x00000000 | Byte returned on the read slots after each byte received |
| 0x018 | RX | RO (pop) | 0x00000000 | Bytes written by the controller; reading RX frees it |
| 0x01C | STATUS | RO | core | Target state |

Unlisted bits read 0 and ignore writes. Reset "core": the register reads the core's outputs directly, so after reset it shows the core's own reset state. WO (pulse) registers read 0. Offsets from 0x020 up to 0xFFC are unmapped (PSLVERR).

### Fields

| Register | Bits | Field | Access | Reset | Description |
|---|---|---|---|---|---|
| ID | 31:16 | CODE | RO | 0x3157 | IP code |
| ID | 15:8 | MAJOR | RO | 0x02 | major version |
| ID | 7:0 | MINOR | RO | 0x00 | minor version |
| IRQ_STATUS | 2:0 | one bit per interrupt | W1C | 0x0 | see Interrupts |
| IRQ_ENABLE | 2:0 | one bit per interrupt | RW | 0x0 | 1 enables the IRQ_STATUS bit onto `irq` |
| FLAGS | 0 | one bit per stream flag | RO | 0x0 | see FLAGS |
| SCRATCH | 31:0 | SCRATCH | RW | 0x00000000 | free for software |
| TX | 7:0 | `tx_byte` | RW | 0x0 | taken when a byte's last write slot is sampled, then sent LSB first on the next 8 read slots |
| RX | 7:0 | `rx_byte` | RO (pop) | 0x0 | Bytes written by the controller; reading RX frees it |
| STATUS | 0 | `busy` | RO | core | between a reset pulse and the bus going idle (not cleared by the transfer ending: only the core's reset returns it to idle) |

### Interrupts (IRQ_STATUS, IRQ_ENABLE)

A bit is set while its source is active, stays set until written with 1, and a set in the same clock as the clear wins.

| Bit | Name | Set when |
|---|---|---|
| 0 | BYTE | a byte was received (the same clock RX captures it) |
| 1 | RX_AVAIL | RX captured a beat |
| 2 | RX_OVF | beat dropped, RX was full |

### FLAGS

| Bit | Name | Meaning |
|---|---|---|
| 0 | RX_AVAIL | RX holds an unread beat |

### Streams

* **RX** captures `rx_byte` when `rx_valid` is high and the register is empty (or is being read in the same clock), and sets FLAGS/IRQ RX_AVAIL. Reading RX pops it. A beat that arrives while the register is full is dropped and sets RX_OVF.

## Programming sequence

1. Release PRESETN. Read ID (0x000) and check it is 0x31570200.
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
| 1. Core test | `make -f Makefile._1_Wire sim` | a `TEST PASSED` line, no `ERROR` | console |
| 2. Core synthesis | `make -f Makefile._1_Wire syn` | Yosys ends without `ERROR`; `stat` prints the cell count | `work/_1_Wire_top.json` |
| 3. APB wrapper test + synthesis | `make -f Makefile._1_Wire apb` | `TEST PASSED: _1_Wire_apb`, then Yosys without `ERROR` | console, `work/_1_Wire_apb.json` |
| 4. Coverage (core, wrapper) | `bash scripts/cov/run_cov.sh _1_Wire`<br>`bash scripts/cov/run_cov.sh _1_Wire_apb` | `RESULT: CLOSED` (all five metrics 100%) | `work/cov/_1_Wire/score.json`, `work/cov/_1_Wire_apb/score.json` |

Expected end of a step 4 run:

```
===== _1_Wire =====
TEST: PASSED   SVA_FAILURES: 0
LINE ... TOGGLE ... FSM ... SVA ... FUNCTIONAL  (each n/n, 100.0%)
RESULT: CLOSED
```

**Core test** (`tb/_1_Wire_tb.sv`): drives `_1_Wire_top` through its own ports against a protocol peer or model and checks every result itself; any mismatch prints `ERROR`, and `TEST PASSED` is printed only when there were none.

**APB wrapper test** (`tb/_1_Wire_apb_tb.sv`), in this order:

1. Reset values of every register, ID included.
2. Writes to read-only registers are ignored.
3. Each RW register: all ones, all zeros, then 16 random writes with every PSTRB byte-lane pattern, read back each time.
4. Unmapped and misaligned addresses, reads and writes: PSLVERR, read data 0, no side effect on other registers.
5. Back-to-back transfers with no idle cycle.
6. IP traffic through the registers only (`tb/apb/_1_Wire_apb_func.svh`): the programming sequence above, every interrupt bit set, enabled and cleared, stream FULL/AVAIL/OVF cases (100% wrapper toggle coverage confirms each bit moved).
7. PRESETN asserted mid-run: `irq` and PRDATA go to 0, registers return to reset values.

**Checkers** (`tb/cov/_1_Wire_sva.sv`, `tb/cov/_1_Wire_apb_sva.sv`): SVA protocol and APB assertions plus covergroups, bound in by the coverage flow. An assertion failure prints `SVA_FAIL` and fails the run even when the test itself passed.

Whole portfolio: `bash scripts/ci_regression.sh` runs steps 1 to 3 for every IP (what CI runs), and `bash scripts/cov/run_all.sh 4` runs step 4 for every IP.

## Verification

Five-metric coverage with Verilator 5.052 (`scripts/cov/run_cov.sh`); see [COVERAGE_CLOSURE.md](../COVERAGE_CLOSURE.md) for the flow. Line and toggle count only the named RTL file.

| Scope | Test | Line | Toggle | FSM | SVA | Functional |
|---|---|---|---|---|---|---|
| core `rtl/_1_Wire_top.sv` | pass | 42/42 | 150/150 | 20/20 | 6/6 | 73/73 |
| wrapper `rtl/_1_Wire_apb.sv` | pass | 28/28 | 484/484 | n/a | 8/8 | 42/42 |
