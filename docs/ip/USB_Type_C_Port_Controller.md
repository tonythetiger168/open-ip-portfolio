# USB Type-C port controller (DRP): CC1 / CC2 attach detection with a 100-clock debounce and orientation, 10-clock detach, source / sink role, VBUS enable, CC fault detection, and an 8 x 8-bit register file

Protocol IP `USB_Type_C_Port_Controller`, version 2.0. Apache-2.0.

| Item | Value |
|---|---|
| Core | `USB_Type_C_Port_Controller_top` (`rtl/USB_Type_C_Port_Controller_top.sv`) |
| Register interface | APB4 slave `USB_Type_C_Port_Controller_apb`, 32-bit data, 12-bit byte address, zero wait states |
| Clock, reset | PCLK (rising edge), PRESETN (active low, asynchronous) |
| ID register | 0x54430200 (code 0x5443, version 2.0) |
| Registers | 13 words, 0x000 to 0x030 |
| Interrupts | 1 sources into one level-high `irq` |
| Core register port | CORE (8 words) |
| Protocol pins | 5 pass-through |

## Overview

USB Type-C Port Controller (TCPC) -- DRP port controller Implementation scope: * cc1/cc2 3-level analog-line inputs, encoded as 2-bit enum: CC_OPEN = 2'b00 (nothing connected / line open) CC_RD   = 2'b01 (sink pull-down Rd present) CC_RA   = 2'b10 (powered-cable / audio accessory Ra present) 2'b11   = abnormal level (fault injection, raises irq) * Attach-detect FSM: UNATTACHED -> ATTACHWAIT (100 clk debounce) -> ATTACHED; orientation resolved from which CC pin saw Rd (cc1 -> orientation=0, cc2 -> orientation=1). Ra-only or Rd on both pins is not a sink attach and is ignored. The debounce restarts if Rd moves to the other pin or an abnormal level appears. * Detach detect: active CC pin back to OPEN for 10 consecutive clks. * vbus_en: asserted in ATTACHED when configured role is source (DFP); stays low for sink role. * 8 x 8-bit register port (I2C-style register file over a simplified parallel command interface: reg_addr/reg_wdata/reg_rdata/reg_rd/reg_wr): 0 CC_STATUS  RO  {attached, orientation, fsm[1:0], cc2[1:0], cc1[1:0]} 1 ROLE_CTRL  RW  bit0: 1 = source/DFP (default), 0 = sink/UFP 2 FAULT_STAT RW1C bit0: abnormal CC level seen (sticky) 3 INT_STAT   RW1C bit0 attach, bit1 detach, bit2 fault (sticky) 4 DEBOUNCE   RO  attach debounce value (8'd100) 5 ORIENT     RO  bit0 = orientation 6 VBUS_STAT  RO  bit0 = vbus_en 7 DEVICE_ID  RO  8'hC7 * irq: asserted while an abnormal CC level is present or while any sticky INT_STAT bit is set (cleared via RW1C write).

cc1 / cc2 (2-bit CC line levels: 0 open, 1 Rd, 2 Ra, 3 abnormal), attached, orientation and vbus_en pass through unchanged.
The core's 8-bit register file is mapped one register per word (bits 7:0); a write with PSTRB != 4'hF is dropped with PSLVERR.

## Files

| File | Content |
|---|---|
| `rtl/USB_Type_C_Port_Controller_top.sv` | protocol core |
| `rtl/USB_Type_C_Port_Controller_apb.sv` | APB4 register wrapper (generated) |
| `tb/USB_Type_C_Port_Controller_tb.sv` | core testbench |
| `tb/USB_Type_C_Port_Controller_apb_tb.sv`, `tb/apb/USB_Type_C_Port_Controller_apb_func.svh` | wrapper testbench (generated part + IP-specific part) |
| `tb/cov/USB_Type_C_Port_Controller_sva.sv`, `tb/cov/USB_Type_C_Port_Controller_apb_sva.sv` | coverage checkers (core, wrapper) |
| `scripts/apb/specs/USB_Type_C_Port_Controller.json` | register spec the wrapper, TB, checker and this page are generated from |

How to run the tests and the coverage flow: see [Running and verifying](#running-and-verifying).

## Parameters

`USB_Type_C_Port_Controller_apb` has the core's parameters and passes them to `USB_Type_C_Port_Controller_top` unchanged.

| Parameter | Type | Default |
|---|---|---|
| `DW` | int | `32` |
| `AW` | int | `32` |

## Wrapper pins

Pins of `USB_Type_C_Port_Controller_apb`. Widths of the pass-through pins are at the default parameters.

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
| `PSLVERR` | output | 1 | error: unmapped or misaligned address, or partial write to a core register word |
| `irq` | output | 1 | interrupt, level high: \|(IRQ_STATUS & IRQ_ENABLE) |
| `cc1` | input | 2 | protocol pin, core port `cc1` |
| `cc2` | input | 2 | protocol pin, core port `cc2` |
| `attached` | output | 1 | protocol pin, core port `attached` |
| `orientation` | output | 1 | protocol pin, core port `orientation` |
| `vbus_en` | output | 1 | protocol pin, core port `vbus_en` |

## Core ports

| Port | Dir | Width | In the APB wrapper |
|---|---|---|---|
| `clk` | input | 1 | PCLK |
| `rst_n` | input | 1 | PRESETN |
| `cc1` | input | 2 | pin (pass-through) |
| `cc2` | input | 2 | pin (pass-through) |
| `attached` | output | 1 | pin (pass-through) |
| `orientation` | output | 1 | pin (pass-through) |
| `vbus_en` | output | 1 | pin (pass-through) |
| `reg_addr` | input | 3 | CORE word index |
| `reg_wdata` | input | 8 | CORE write data |
| `reg_rdata` | output | 8 | CORE read data |
| `reg_rd` | input | 1 | read of a CORE word |
| `reg_wr` | input | 1 | write to a CORE word |
| `irq` | output | 1 | IRQ_STATUS.EVENT |

## APB wrapper

`USB_Type_C_Port_Controller_apb` is an APB4 slave (AMBA APB protocol v2.0): zero wait states, 32-bit data, 12-bit byte address, PSTRB byte lanes on every writable register, PSLVERR on an unmapped or misaligned address (reads then return 0, writes are dropped). Writes to read-only registers are ignored without an error. The core runs on PCLK and PRESETN. `irq` is level-high: `|(IRQ_STATUS & IRQ_ENABLE)`.

Pass-through pins: `cc1`, `cc2`, `attached`, `orientation`, `vbus_en`.

### Register map

| Offset | Name | Access | Reset | Description |
|---|---|---|---|---|
| 0x000 | ID | RO | 0x54430200 | IP identification: code, major and minor version |
| 0x004 | IRQ_STATUS | W1C | 0x00000000 | Sticky interrupt bits, write 1 to clear |
| 0x008 | IRQ_ENABLE | RW | 0x00000000 | Interrupt enables; irq = \|(IRQ_STATUS & IRQ_ENABLE) |
| 0x00C | FLAGS | RO | 0x00000000 | Stream holding-register state |
| 0x010 | SCRATCH | RW | 0x00000000 | Scratch register, no effect on the core |
| 0x014 | CC_STATUS | RO (core) | core | {attached, orientation, fsm[1:0], cc2[1:0], cc1[1:0]} (fsm: 0 unattached, 1 attach wait, 2 attached) |
| 0x018 | ROLE_CTRL | RW (core) | core | bit 0: 1 = source / DFP (reset), 0 = sink / UFP; vbus_en needs the source role |
| 0x01C | FAULT_STAT | RW (core) | core | bit 0: abnormal CC level seen (sticky, write 1 to clear; a fault in the same clock wins) |
| 0x020 | INT_STAT | RW (core) | core | bit 0 attach, bit 1 detach, bit 2 fault (sticky, write 1 to clear; a new event in the same clock wins) |
| 0x024 | DEBOUNCE | RO (core) | core | attach debounce in clocks (100) |
| 0x028 | ORIENT | RO (core) | core | bit 0: orientation (1 = CC2 is the wired CC) |
| 0x02C | VBUS_STAT | RO (core) | core | bit 0: vbus_en |
| 0x030 | DEVICE_ID | RO (core) | core | device ID 0xC7 |

Unlisted bits read 0 and ignore writes. Reset "core": the register reads the core's outputs directly, so after reset it shows the core's own reset state. WO (pulse) registers read 0. Offsets from 0x034 up to 0xFFC are unmapped (PSLVERR).

### Fields

| Register | Bits | Field | Access | Reset | Description |
|---|---|---|---|---|---|
| ID | 31:16 | CODE | RO | 0x5443 | IP code |
| ID | 15:8 | MAJOR | RO | 0x02 | major version |
| ID | 7:0 | MINOR | RO | 0x00 | minor version |
| IRQ_STATUS | 0 | one bit per interrupt | W1C | 0x0 | see Interrupts |
| IRQ_ENABLE | 0 | one bit per interrupt | RW | 0x0 | 1 enables the IRQ_STATUS bit onto `irq` |
| SCRATCH | 31:0 | SCRATCH | RW | 0x00000000 | free for software |
| CC_STATUS | 7:0 | core register | RO (core) | core | read from core register 0 |
| ROLE_CTRL | 7:0 | core register | RW (core) | core | written at core register 1 and read from core register 1 |
| FAULT_STAT | 7:0 | core register | RW (core) | core | written at core register 2 and read from core register 2 |
| INT_STAT | 7:0 | core register | RW (core) | core | written at core register 3 and read from core register 3 |
| DEBOUNCE | 7:0 | core register | RO (core) | core | read from core register 4 |
| ORIENT | 7:0 | core register | RO (core) | core | read from core register 5 |
| VBUS_STAT | 7:0 | core register | RO (core) | core | read from core register 6 |
| DEVICE_ID | 7:0 | core register | RO (core) | core | read from core register 7 |

### Interrupts (IRQ_STATUS, IRQ_ENABLE)

A bit is set while its source is active, stays set until written with 1, and a set in the same clock as the clear wins.

| Bit | Name | Set when |
|---|---|---|
| 0 | EVENT | an abnormal CC level is present or an INT_STAT bit is set; held while either lasts, so the bit is set again on every clock until INT_STAT is cleared and the fault is gone |

### Core register port

The CORE words reach the core's own register port. A write to one pulses `reg_wr` for one clock with `reg_addr` (the core register) and `reg_wdata` (PWDATA's low bits); it must cover the whole word (PSTRB = 4'hF): a partial write is dropped with PSLVERR. A read drives `reg_addr` (the core register) and pulses `reg_rd` during the access phase and returns `reg_rdata`.

## Programming sequence

1. Release PRESETN. Read ID (0x000) and check it is 0x54430200.
2. Write 0x1 to IRQ_STATUS (0x004) to clear any stale bits.
3. Write IRQ_ENABLE (0x008) with the interrupts to use (bit order as in the Interrupts table; 0x1 enables all).
4. Access the core's registers through the CORE words (0x014 onward), one word per core register; write whole words (PSTRB = 0xF), a partial write is dropped with PSLVERR.
5. On `irq`: read IRQ_STATUS, handle every bit that is set and enabled, then write those bits back to IRQ_STATUS to clear them. A source that is still active sets its bit again.

## Running and verifying

All commands run from the repository root. Icarus Verilog 12 and Yosys 0.33 are enough for steps 1 to 3; step 4 also needs Verilator 5.052 and pyslang (see [README, Setup](../../README.md#setup)).

| Step | Command | Pass when | Output |
|---|---|---|---|
| 1. Core test | `make -f Makefile.USB_Type_C_Port_Controller sim` | a `TEST PASSED` line, no `ERROR` | console |
| 2. Core synthesis | `make -f Makefile.USB_Type_C_Port_Controller syn` | Yosys ends without `ERROR`; `stat` prints the cell count | `work/USB_Type_C_Port_Controller_top.json` |
| 3. APB wrapper test + synthesis | `make -f Makefile.USB_Type_C_Port_Controller apb` | `TEST PASSED: USB_Type_C_Port_Controller_apb`, then Yosys without `ERROR` | console, `work/USB_Type_C_Port_Controller_apb.json` |
| 4. Coverage (core, wrapper) | `bash scripts/cov/run_cov.sh USB_Type_C_Port_Controller`<br>`bash scripts/cov/run_cov.sh USB_Type_C_Port_Controller_apb` | `RESULT: CLOSED` (all five metrics 100%) | `work/cov/USB_Type_C_Port_Controller/score.json`, `work/cov/USB_Type_C_Port_Controller_apb/score.json` |

Expected end of a step 4 run:

```
===== USB_Type_C_Port_Controller =====
TEST: PASSED   SVA_FAILURES: 0
LINE ... TOGGLE ... FSM ... SVA ... FUNCTIONAL  (each n/n, 100.0%)
RESULT: CLOSED
```

**Core test** (`tb/USB_Type_C_Port_Controller_tb.sv`): drives `USB_Type_C_Port_Controller_top` through its own ports against a protocol peer or model and checks every result itself; any mismatch prints `ERROR`, and `TEST PASSED` is printed only when there were none.

**APB wrapper test** (`tb/USB_Type_C_Port_Controller_apb_tb.sv`), in this order:

1. Reset values of every register, ID included.
2. Writes to read-only registers are ignored.
3. Each RW register: all ones, all zeros, then 16 random writes with every PSTRB byte-lane pattern, read back each time.
4. Unmapped and misaligned addresses, reads and writes: PSLVERR, read data 0, no side effect on other registers.
5. Back-to-back transfers with no idle cycle.
6. IP traffic through the registers only (`tb/apb/USB_Type_C_Port_Controller_apb_func.svh`): the programming sequence above, every interrupt bit set, enabled and cleared (100% wrapper toggle coverage confirms each bit moved).
7. PRESETN asserted mid-run: `irq` and PRDATA go to 0, registers return to reset values.

**Checkers** (`tb/cov/USB_Type_C_Port_Controller_sva.sv`, `tb/cov/USB_Type_C_Port_Controller_apb_sva.sv`): SVA protocol and APB assertions plus covergroups, bound in by the coverage flow. An assertion failure prints `SVA_FAIL` and fails the run even when the test itself passed.

Whole portfolio: `bash scripts/ci_regression.sh` runs steps 1 to 3 for every IP (what CI runs), and `bash scripts/cov/run_all.sh 4` runs step 4 for every IP.

## Verification

Five-metric coverage with Verilator 5.052 (`scripts/cov/run_cov.sh`); see [COVERAGE_CLOSURE.md](../COVERAGE_CLOSURE.md) for the flow. Line and toggle count only the named RTL file.

| Scope | Test | Line | Toggle | FSM | SVA | Functional |
|---|---|---|---|---|---|---|
| core `rtl/USB_Type_C_Port_Controller_top.sv` | pass | 29/29 (+1 excl.) | 132/132 | 7/7 | 5/5 | 81/81 |
| wrapper `rtl/USB_Type_C_Port_Controller_apb.sv` | pass | 27/27 | 458/458 | n/a | 11/11 | 40/40 |
