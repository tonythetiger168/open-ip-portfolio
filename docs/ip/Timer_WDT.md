# System timer and watchdog: periodic timer with AXI4 timestamp records, bark interrupt and bite reset request

Protocol IP `Timer_WDT`, version 1.0. Apache-2.0.

| Item | Value |
|---|---|
| Core | `Timer_WDT_top` (`rtl/Timer_WDT_top.sv`) |
| Register interface | APB4 slave `Timer_WDT_apb`, 32-bit data, 12-bit byte address, zero wait states |
| Clock, reset | PCLK (rising edge), PRESETN (active low, asynchronous) |
| ID register | 0x5C0C0100 (code 0x5C0C, version 1.0) |
| Registers | 15 words, 0x000 to 0x038 |
| Interrupts | 3 sources into one level-high `irq` |
| Protocol pins | 32 pass-through |

## Overview

Timer_WDT: system timer and watchdog of the phone SoC, with timestamp records in memory (AXI4 manager, APB4 registers) A prescaler makes one tick every PRESCALE + 1 clocks; COUNT is a free- running 32-bit tick counter.

- Timer: with TMR_EN set, the TIMER interrupt fires every PERIOD + 1
ticks (periodic, auto-reload; lowering PERIOD below the current count
ends the current period at the next tick). With TS_EN also set, each timer event
writes COUNT at that tick as one 32-bit record into a ring of TS_WORDS
words at TS_BASE (record n at TS_BASE + 4 * (n mod TS_WORDS)); TS_WP
counts records written. An event while the previous record is still
being written is not recorded (TS_MISSED counts it).
- Watchdog: with WDT_EN set, a down-counter loaded with WDT_LOAD counts
ticks; CMD.kick reloads it. When it reaches 0 the BARK interrupt fires and
it reloads; if it reaches 0 again without a kick, wdt_reset goes high
(the BITE: a reset request to the power manager) and stays high until a
kick or WDT_EN = 0.
- TS_ERR is set when a record write got an AXI error response.
- AXI ID = AXI_ID, single-beat writes.

Features:

- Tick: one every PRESCALE + 1 clocks; COUNT counts ticks.
- Timer (TMR_EN): TIMER fires every PERIOD + 1 ticks (the event is the tick at which the timer count is >= PERIOD, so lowering PERIOD ends the current period at the next tick). With TS_EN and TS_WORDS != 0 each timer event writes COUNT (the value in the event's clock) at TS_BASE + 4 * (n mod TS_WORDS); if TS_WORDS is lowered below the slot of the next record, that record goes to slot 0 and the ring restarts there; TS_WP counts records, TS_MISSED events that came while a record was being written.
- Watchdog (WDT_EN): WDT_COUNT loads WDT_LOAD, counts down one per tick; CMD.kick reloads. At 0: BARK fires and it reloads; at 0 again without a kick wdt_reset goes high until a kick or WDT_EN = 0.

m_* is the AXI4 manager port (32-bit address and data, 4-bit ID, no user / QoS); it passes through unchanged. Bursts are INCR, AxSIZE = 2 (4 bytes), 1 to 16 beats, WSTRB = 4'hF, never across a 4 KB boundary; one read and one write burst are outstanding at a time. A read burst is issued only when its data has room, a write burst only when all its data is ready.
wdt_reset (the reset request) drives a pin and reads in WDT_STATE.

## Files

| File | Content |
|---|---|
| `rtl/Timer_WDT_top.sv` | protocol core |
| `rtl/Timer_WDT_apb.sv` | APB4 register wrapper (generated) |
| `tb/Timer_WDT_tb.sv` | core testbench |
| `tb/Timer_WDT_apb_tb.sv`, `tb/apb/Timer_WDT_apb_func.svh` | wrapper testbench (generated part + IP-specific part) |
| `tb/cov/Timer_WDT_sva.sv`, `tb/cov/Timer_WDT_apb_sva.sv` | coverage checkers (core, wrapper) |
| `scripts/apb/specs/Timer_WDT.json` | register spec the wrapper, TB, checker and this page are generated from |

How to run the tests and the coverage flow: see [Running and verifying](#running-and-verifying).

## Parameters

`Timer_WDT_apb` has the core's parameters and passes them to `Timer_WDT_top` unchanged.

| Parameter | Type | Default |
|---|---|---|
| `AXI_ID` | logic [3:0] | `4'd11` |

## Wrapper pins

Pins of `Timer_WDT_apb`. Widths of the pass-through pins are at the default parameters.

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
| `wdt_reset` | output | 1 | protocol pin, core port `wdt_reset` (also read in a register) |
| `m_awid` | output | 4 | protocol pin, core port `m_awid` |
| `m_awaddr` | output | 32 | protocol pin, core port `m_awaddr` |
| `m_awlen` | output | 8 | protocol pin, core port `m_awlen` |
| `m_awsize` | output | 3 | protocol pin, core port `m_awsize` |
| `m_awburst` | output | 2 | protocol pin, core port `m_awburst` |
| `m_awprot` | output | 3 | protocol pin, core port `m_awprot` |
| `m_awvalid` | output | 1 | protocol pin, core port `m_awvalid` |
| `m_awready` | input | 1 | protocol pin, core port `m_awready` |
| `m_wdata` | output | 32 | protocol pin, core port `m_wdata` |
| `m_wstrb` | output | 4 | protocol pin, core port `m_wstrb` |
| `m_wlast` | output | 1 | protocol pin, core port `m_wlast` |
| `m_wvalid` | output | 1 | protocol pin, core port `m_wvalid` |
| `m_wready` | input | 1 | protocol pin, core port `m_wready` |
| `m_bid` | input | 4 | protocol pin, core port `m_bid` |
| `m_bresp` | input | 2 | protocol pin, core port `m_bresp` |
| `m_bvalid` | input | 1 | protocol pin, core port `m_bvalid` |
| `m_bready` | output | 1 | protocol pin, core port `m_bready` |
| `m_arid` | output | 4 | protocol pin, core port `m_arid` |
| `m_araddr` | output | 32 | protocol pin, core port `m_araddr` |
| `m_arlen` | output | 8 | protocol pin, core port `m_arlen` |
| `m_arsize` | output | 3 | protocol pin, core port `m_arsize` |
| `m_arburst` | output | 2 | protocol pin, core port `m_arburst` |
| `m_arprot` | output | 3 | protocol pin, core port `m_arprot` |
| `m_arvalid` | output | 1 | protocol pin, core port `m_arvalid` |
| `m_arready` | input | 1 | protocol pin, core port `m_arready` |
| `m_rid` | input | 4 | protocol pin, core port `m_rid` |
| `m_rdata` | input | 32 | protocol pin, core port `m_rdata` |
| `m_rresp` | input | 2 | protocol pin, core port `m_rresp` |
| `m_rlast` | input | 1 | protocol pin, core port `m_rlast` |
| `m_rvalid` | input | 1 | protocol pin, core port `m_rvalid` |
| `m_rready` | output | 1 | protocol pin, core port `m_rready` |

## Core ports

| Port | Dir | Width | In the APB wrapper |
|---|---|---|---|
| `clk` | input | 1 | PCLK |
| `rst_n` | input | 1 | PRESETN |
| `prescale` | input | 16 | CTRL[15:0] |
| `tmr_en` | input | 1 | CTRL[16:16] |
| `period` | input | 32 | PERIOD[31:0] |
| `ts_en` | input | 1 | CTRL[17:17] |
| `ts_base` | input | 32 | TS_BASE[31:0] |
| `ts_words` | input | 16 | TS_WORDS[15:0] |
| `wdt_en` | input | 1 | CTRL[18:18] |
| `wdt_load` | input | 32 | WDT_LOAD[31:0] |
| `kick` | input | 1 | CMD |
| `count` | output | 32 | COUNT[31:0] |
| `ts_wp` | output | 16 | TS_STATE[15:0] |
| `ts_missed` | output | 16 | TS_STATE[31:16] |
| `wdt_count` | output | 32 | WDT_COUNT[31:0] |
| `wdt_reset` | output | 1 | WDT_STATE |
| `tmr_irq` | output | 1 | IRQ_STATUS.TIMER |
| `bark` | output | 1 | IRQ_STATUS.BARK |
| `ts_err` | output | 1 | IRQ_STATUS.TS_ERR |
| `m_awid` | output | 4 | pin (pass-through) |
| `m_awaddr` | output | 32 | pin (pass-through) |
| `m_awlen` | output | 8 | pin (pass-through) |
| `m_awsize` | output | 3 | pin (pass-through) |
| `m_awburst` | output | 2 | pin (pass-through) |
| `m_awprot` | output | 3 | pin (pass-through) |
| `m_awvalid` | output | 1 | pin (pass-through) |
| `m_awready` | input | 1 | pin (pass-through) |
| `m_wdata` | output | 32 | pin (pass-through) |
| `m_wstrb` | output | 4 | pin (pass-through) |
| `m_wlast` | output | 1 | pin (pass-through) |
| `m_wvalid` | output | 1 | pin (pass-through) |
| `m_wready` | input | 1 | pin (pass-through) |
| `m_bid` | input | 4 | pin (pass-through) |
| `m_bresp` | input | 2 | pin (pass-through) |
| `m_bvalid` | input | 1 | pin (pass-through) |
| `m_bready` | output | 1 | pin (pass-through) |
| `m_arid` | output | 4 | pin (pass-through) |
| `m_araddr` | output | 32 | pin (pass-through) |
| `m_arlen` | output | 8 | pin (pass-through) |
| `m_arsize` | output | 3 | pin (pass-through) |
| `m_arburst` | output | 2 | pin (pass-through) |
| `m_arprot` | output | 3 | pin (pass-through) |
| `m_arvalid` | output | 1 | pin (pass-through) |
| `m_arready` | input | 1 | pin (pass-through) |
| `m_rid` | input | 4 | pin (pass-through) |
| `m_rdata` | input | 32 | pin (pass-through) |
| `m_rresp` | input | 2 | pin (pass-through) |
| `m_rlast` | input | 1 | pin (pass-through) |
| `m_rvalid` | input | 1 | pin (pass-through) |
| `m_rready` | output | 1 | pin (pass-through) |

## APB wrapper

`Timer_WDT_apb` is an APB4 slave (AMBA APB protocol v2.0): zero wait states, 32-bit data, 12-bit byte address, PSTRB byte lanes on every writable register, PSLVERR on an unmapped or misaligned address (reads then return 0, writes are dropped). Writes to read-only registers are ignored without an error. The core runs on PCLK and PRESETN. `irq` is level-high: `|(IRQ_STATUS & IRQ_ENABLE)`.

Pass-through pins: `wdt_reset`, `m_awid`, `m_awaddr`, `m_awlen`, `m_awsize`, `m_awburst`, `m_awprot`, `m_awvalid`, `m_awready`, `m_wdata`, `m_wstrb`, `m_wlast`, `m_wvalid`, `m_wready`, `m_bid`, `m_bresp`, `m_bvalid`, `m_bready`, `m_arid`, `m_araddr`, `m_arlen`, `m_arsize`, `m_arburst`, `m_arprot`, `m_arvalid`, `m_arready`, `m_rid`, `m_rdata`, `m_rresp`, `m_rlast`, `m_rvalid`, `m_rready`.

### Register map

| Offset | Name | Access | Reset | Description |
|---|---|---|---|---|
| 0x000 | ID | RO | 0x5C0C0100 | IP identification: code, major and minor version |
| 0x004 | IRQ_STATUS | W1C | 0x00000000 | Sticky interrupt bits, write 1 to clear |
| 0x008 | IRQ_ENABLE | RW | 0x00000000 | Interrupt enables; irq = \|(IRQ_STATUS & IRQ_ENABLE) |
| 0x00C | FLAGS | RO | 0x00000000 | Stream holding-register state |
| 0x010 | SCRATCH | RW | 0x00000000 | Scratch register, no effect on the core |
| 0x014 | CTRL | RW | 0x00000000 | Enables and prescaler |
| 0x018 | PERIOD | RW | 0x00000000 | Timer period |
| 0x01C | TS_BASE | RW | 0x00000000 | Timestamp ring base |
| 0x020 | TS_WORDS | RW | 0x00000000 | Timestamp ring size |
| 0x024 | WDT_LOAD | RW | 0x00000000 | Watchdog timeout |
| 0x028 | CMD | WO (pulse) | 0x00000000 | Commands (write 1) |
| 0x02C | COUNT | RO | core | Tick counter |
| 0x030 | TS_STATE | RO | core | Record counters |
| 0x034 | WDT_COUNT | RO | core | Watchdog counter |
| 0x038 | WDT_STATE | RO | core | Watchdog output |

Unlisted bits read 0 and ignore writes. Reset "core": the register reads the core's outputs directly, so after reset it shows the core's own reset state. WO (pulse) registers read 0. Offsets from 0x03C up to 0xFFC are unmapped (PSLVERR).

### Fields

| Register | Bits | Field | Access | Reset | Description |
|---|---|---|---|---|---|
| ID | 31:16 | CODE | RO | 0x5C0C | IP code |
| ID | 15:8 | MAJOR | RO | 0x01 | major version |
| ID | 7:0 | MINOR | RO | 0x00 | minor version |
| IRQ_STATUS | 2:0 | one bit per interrupt | W1C | 0x0 | see Interrupts |
| IRQ_ENABLE | 2:0 | one bit per interrupt | RW | 0x0 | 1 enables the IRQ_STATUS bit onto `irq` |
| SCRATCH | 31:0 | SCRATCH | RW | 0x00000000 | free for software |
| CTRL | 15:0 | `prescale` | RW | 0x0 | clocks per tick - 1 |
| CTRL | 16 | `tmr_en` | RW | 0x0 | timer on |
| CTRL | 17 | `ts_en` | RW | 0x0 | timestamp records on |
| CTRL | 18 | `wdt_en` | RW | 0x0 | watchdog on |
| PERIOD | 31:0 | `period` | RW | 0x0 | ticks per event - 1 |
| TS_BASE | 31:0 | `ts_base` | RW | 0x0 | byte address of record 0 |
| TS_WORDS | 15:0 | `ts_words` | RW | 0x0 | words (0: no records) |
| WDT_LOAD | 31:0 | `wdt_load` | RW | 0x0 | ticks |
| CMD | 0 | `kick` | WO (pulse) | 0x0 | reload the watchdog |
| COUNT | 31:0 | `count` | RO | core | ticks since reset |
| TS_STATE | 15:0 | `ts_wp` | RO | core | records written |
| TS_STATE | 31:16 | `ts_missed` | RO | core | events not recorded |
| WDT_COUNT | 31:0 | `wdt_count` | RO | core | ticks left |
| WDT_STATE | 0 | `wdt_reset` | RO | core | bite: reset request |

### Interrupts (IRQ_STATUS, IRQ_ENABLE)

A bit is set while its source is active, stays set until written with 1, and a set in the same clock as the clear wins.

| Bit | Name | Set when |
|---|---|---|
| 0 | TIMER | timer event |
| 1 | BARK | watchdog expired once |
| 2 | TS_ERR | a record write got an AXI error response |

## Programming sequence

1. Release PRESETN. Read ID (0x000) and check it is 0x5C0C0100.
2. Write 0x7 to IRQ_STATUS (0x004) to clear any stale bits.
3. Configure the core: write CTRL (0x014), PERIOD (0x018), TS_BASE (0x01C), TS_WORDS (0x020), WDT_LOAD (0x024). Reset values are in the register map; PSTRB selects the bytes written.
4. Write IRQ_ENABLE (0x008) with the interrupts to use (bit order as in the Interrupts table; 0x7 enables all).
5. To issue a command, write 1 to `kick` (CMD bit 0) at 0x028; the core sees a one-clock pulse, and the register reads 0.
6. Read COUNT (0x02C) for the core's live `count`; it needs no clearing.
7. Read TS_STATE (0x030) for the core's live `ts_wp`, `ts_missed`; it needs no clearing.
8. Read WDT_COUNT (0x034) for the core's live `wdt_count`; it needs no clearing.
9. Read WDT_STATE (0x038) for the core's live `wdt_reset`; it needs no clearing.
10. On `irq`: read IRQ_STATUS, handle every bit that is set and enabled, then write those bits back to IRQ_STATUS to clear them. A source that is still active sets its bit again.

IP-specific use:

1. Write CTRL.prescale, PERIOD, TS_BASE, TS_WORDS, then CTRL with tmr_en / ts_en.
2. Watchdog: write WDT_LOAD, set CTRL.wdt_en, write CMD.kick periodically.

## Running and verifying

All commands run from the repository root. Icarus Verilog 12 and Yosys 0.33 are enough for steps 1 to 3; step 4 also needs Verilator 5.052 and pyslang (see [README, Setup](../../README.md#setup)).

| Step | Command | Pass when | Output |
|---|---|---|---|
| 1. Core test | `make -f Makefile.Timer_WDT sim` | a `TEST PASSED` line, no `ERROR` | console |
| 2. Core synthesis | `make -f Makefile.Timer_WDT syn` | Yosys ends without `ERROR`; `stat` prints the cell count | `work/Timer_WDT_top.json` |
| 3. APB wrapper test + synthesis | `make -f Makefile.Timer_WDT apb` | `TEST PASSED: Timer_WDT_apb`, then Yosys without `ERROR` | console, `work/Timer_WDT_apb.json` |
| 4. Coverage (core, wrapper) | `bash scripts/cov/run_cov.sh Timer_WDT`<br>`bash scripts/cov/run_cov.sh Timer_WDT_apb` | `RESULT: CLOSED` (all five metrics 100%) | `work/cov/Timer_WDT/score.json`, `work/cov/Timer_WDT_apb/score.json` |

Expected end of a step 4 run:

```
===== Timer_WDT =====
TEST: PASSED   SVA_FAILURES: 0
LINE ... TOGGLE ... FSM ... SVA ... FUNCTIONAL  (each n/n, 100.0%)
RESULT: CLOSED
```

**Core test** (`tb/Timer_WDT_tb.sv`): drives `Timer_WDT_top` through its own ports against a protocol peer or model and checks every result itself; any mismatch prints `ERROR`, and `TEST PASSED` is printed only when there were none.

**APB wrapper test** (`tb/Timer_WDT_apb_tb.sv`), in this order:

1. Reset values of every register, ID included.
2. Writes to read-only registers are ignored.
3. Each RW register: all ones, all zeros, then 16 random writes with every PSTRB byte-lane pattern, read back each time.
4. Unmapped and misaligned addresses, reads and writes: PSLVERR, read data 0, no side effect on other registers.
5. Back-to-back transfers with no idle cycle.
6. IP traffic through the registers only (`tb/apb/Timer_WDT_apb_func.svh`): the programming sequence above, every interrupt bit set, enabled and cleared (100% wrapper toggle coverage confirms each bit moved).
7. PRESETN asserted mid-run: `irq` and PRDATA go to 0, registers return to reset values.

**Checkers** (`tb/cov/Timer_WDT_sva.sv`, `tb/cov/Timer_WDT_apb_sva.sv`): SVA protocol and APB assertions plus covergroups, bound in by the coverage flow. An assertion failure prints `SVA_FAIL` and fails the run even when the test itself passed.

Whole portfolio: `bash scripts/ci_regression.sh` runs steps 1 to 3 for every IP (what CI runs), and `bash scripts/cov/run_all.sh 4` runs step 4 for every IP.

## Verification

Five-metric coverage with Verilator 5.052 (`scripts/cov/run_cov.sh`); see [COVERAGE_CLOSURE.md](../COVERAGE_CLOSURE.md) for the flow. Line and toggle count only the named RTL file.

| Scope | Test | Line | Toggle | FSM | SVA | Functional |
|---|---|---|---|---|---|---|
| core `rtl/Timer_WDT_top.sv` | not run | | | | | |
| wrapper `rtl/Timer_WDT_apb.sv` | pass | 40/40 | 1544/1544 (+268 excl.) | n/a | 16/16 | 52/52 |
