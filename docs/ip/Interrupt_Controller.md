# Interrupt controller: 32 level sources, enables, software set, priority claim and an AXI4 event log

Protocol IP `Interrupt_Controller`, version 1.0. Apache-2.0.

| Item | Value |
|---|---|
| Core | `Interrupt_Controller_top` (`rtl/Interrupt_Controller_top.sv`) |
| Register interface | APB4 slave `Interrupt_Controller_apb`, 32-bit data, 12-bit byte address, zero wait states |
| Clock, reset | PCLK (rising edge), PRESETN (active low, asynchronous) |
| ID register | 0x5C0B0100 (code 0x5C0B, version 1.0) |
| Registers | 12 words, 0x000 to 0x02C |
| Interrupts | 2 sources into one level-high `irq` |
| Protocol pins | 33 pass-through |

## Overview

Interrupt_Controller: 32-source interrupt controller of the phone SoC with an in-memory event log (AXI4 manager, APB4 registers) Collects the level interrupts of the subsystems and peripherals (irq_src[31:0], active high) and drives one CPU interrupt:

- PENDING = (irq_src | SW_SET) & ENABLE; cpu_irq = |PENDING.
- CLAIM gives the highest-priority pending source, the lowest-numbered
one: {valid (bit 31), id (bits 4:0)}. A source is acknowledged at the
device (its level falls) or, for SW_SET bits, by clearing the bit.
- Event log: with LOG_EN set, each source that becomes pending is written
as one 32-bit record {timestamp[23:0], 3'b000, id[4:0]} into a ring of
LOG_WORDS words at LOG_BASE (record n at LOG_BASE + 4 * (n mod
LOG_WORDS)); the timestamp is a free-running clock counter taken when the
record is written. LOG_WP counts records written. Sources that become
pending again before their record is written are merged.
- Interrupt CPU follows cpu_irq; LOG_ERR is set when a record write got
an AXI error response. AXI ID = AXI_ID, single-beat writes.

Features:

- PENDING = (irq_src | SW_SET) & ENABLE; cpu_irq = |PENDING (a pin, also STATE.cpu_irq).
- CLAIM = {valid (bit 31), id (bits 4:0)} of the lowest-numbered pending source.
- LOG_EN 1: each source that becomes pending (rising edge of its PENDING bit) is written as {timestamp[23:0], 3'b000, id[4:0]} at LOG_BASE + 4 * (n mod LOG_WORDS), n = the record number; LOG_WP counts records. The lowest-numbered waiting source is written first; edges of a source still waiting are merged.
- timestamp: a free-running 24-bit clock counter, read in the clock the record write starts.

m_* is the AXI4 manager port (32-bit address and data, 4-bit ID, no user / QoS); it passes through unchanged. Bursts are INCR, AxSIZE = 2 (4 bytes), 1 to 16 beats, WSTRB = 4'hF, never across a 4 KB boundary; one read and one write burst are outstanding at a time. A read burst is issued only when its data has room, a write burst only when all its data is ready.
irq_src[31:0] (the interrupt inputs) and cpu_irq pass through.

## Files

| File | Content |
|---|---|
| `rtl/Interrupt_Controller_top.sv` | protocol core |
| `rtl/Interrupt_Controller_apb.sv` | APB4 register wrapper (generated) |
| `tb/Interrupt_Controller_tb.sv` | core testbench |
| `tb/Interrupt_Controller_apb_tb.sv`, `tb/apb/Interrupt_Controller_apb_func.svh` | wrapper testbench (generated part + IP-specific part) |
| `tb/cov/Interrupt_Controller_sva.sv`, `tb/cov/Interrupt_Controller_apb_sva.sv` | coverage checkers (core, wrapper) |
| `scripts/apb/specs/Interrupt_Controller.json` | register spec the wrapper, TB, checker and this page are generated from |

How to run the tests and the coverage flow: see [Running and verifying](#running-and-verifying).

## Parameters

`Interrupt_Controller_apb` has the core's parameters and passes them to `Interrupt_Controller_top` unchanged.

| Parameter | Type | Default |
|---|---|---|
| `AXI_ID` | logic [3:0] | `4'd10` |

## Wrapper pins

Pins of `Interrupt_Controller_apb`. Widths of the pass-through pins are at the default parameters.

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
| `irq_src` | input | 32 | protocol pin, core port `irq_src` |
| `cpu_irq` | output | 1 | protocol pin, core port `cpu_irq` (also read in a register) |
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
| `irq_src` | input | 32 | pin (pass-through) |
| `enable` | input | 32 | ENABLE[31:0] |
| `sw_set` | input | 32 | SW_SET[31:0] |
| `log_en` | input | 1 | LOG_CTRL[0:0] |
| `log_base` | input | 32 | LOG_BASE[31:0] |
| `log_words` | input | 16 | LOG_CTRL[16:1] |
| `pending` | output | 32 | PENDING[31:0] |
| `claim` | output | 32 | CLAIM[31:0] |
| `log_wp` | output | 16 | STATE[15:0] |
| `cpu_irq` | output | 1 | STATE[16:16], IRQ_STATUS.CPU |
| `log_err` | output | 1 | IRQ_STATUS.LOG_ERR |
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

`Interrupt_Controller_apb` is an APB4 slave (AMBA APB protocol v2.0): zero wait states, 32-bit data, 12-bit byte address, PSTRB byte lanes on every writable register, PSLVERR on an unmapped or misaligned address (reads then return 0, writes are dropped). Writes to read-only registers are ignored without an error. The core runs on PCLK and PRESETN. `irq` is level-high: `|(IRQ_STATUS & IRQ_ENABLE)`.

Pass-through pins: `irq_src`, `cpu_irq`, `m_awid`, `m_awaddr`, `m_awlen`, `m_awsize`, `m_awburst`, `m_awprot`, `m_awvalid`, `m_awready`, `m_wdata`, `m_wstrb`, `m_wlast`, `m_wvalid`, `m_wready`, `m_bid`, `m_bresp`, `m_bvalid`, `m_bready`, `m_arid`, `m_araddr`, `m_arlen`, `m_arsize`, `m_arburst`, `m_arprot`, `m_arvalid`, `m_arready`, `m_rid`, `m_rdata`, `m_rresp`, `m_rlast`, `m_rvalid`, `m_rready`.

### Register map

| Offset | Name | Access | Reset | Description |
|---|---|---|---|---|
| 0x000 | ID | RO | 0x5C0B0100 | IP identification: code, major and minor version |
| 0x004 | IRQ_STATUS | W1C | 0x00000000 | Sticky interrupt bits, write 1 to clear |
| 0x008 | IRQ_ENABLE | RW | 0x00000000 | Interrupt enables; irq = \|(IRQ_STATUS & IRQ_ENABLE) |
| 0x00C | FLAGS | RO | 0x00000000 | Stream holding-register state |
| 0x010 | SCRATCH | RW | 0x00000000 | Scratch register, no effect on the core |
| 0x014 | ENABLE | RW | 0x00000000 | Source enables |
| 0x018 | SW_SET | RW | 0x00000000 | Software interrupts |
| 0x01C | LOG_CTRL | RW | 0x00000000 | Event log |
| 0x020 | LOG_BASE | RW | 0x00000000 | Event log base |
| 0x024 | PENDING | RO | core | Pending sources |
| 0x028 | CLAIM | RO | core | Highest-priority pending source |
| 0x02C | STATE | RO | core | Output and log state |

Unlisted bits read 0 and ignore writes. Reset "core": the register reads the core's outputs directly, so after reset it shows the core's own reset state. WO (pulse) registers read 0. Offsets from 0x030 up to 0xFFC are unmapped (PSLVERR).

### Fields

| Register | Bits | Field | Access | Reset | Description |
|---|---|---|---|---|---|
| ID | 31:16 | CODE | RO | 0x5C0B | IP code |
| ID | 15:8 | MAJOR | RO | 0x01 | major version |
| ID | 7:0 | MINOR | RO | 0x00 | minor version |
| IRQ_STATUS | 1:0 | one bit per interrupt | W1C | 0x0 | see Interrupts |
| IRQ_ENABLE | 1:0 | one bit per interrupt | RW | 0x0 | 1 enables the IRQ_STATUS bit onto `irq` |
| SCRATCH | 31:0 | SCRATCH | RW | 0x00000000 | free for software |
| ENABLE | 31:0 | `enable` | RW | 0x0 | 1: source can be pending |
| SW_SET | 31:0 | `sw_set` | RW | 0x0 | ORed into irq_src |
| LOG_CTRL | 0 | `log_en` | RW | 0x0 | 1: log records |
| LOG_CTRL | 16:1 | `log_words` | RW | 0x0 | ring size in words (0: no log) |
| LOG_BASE | 31:0 | `log_base` | RW | 0x0 | byte address of record 0 |
| PENDING | 31:0 | `pending` | RO | core | (irq_src | SW_SET) & ENABLE |
| CLAIM | 31:0 | `claim` | RO | core | {valid, 26'b0, id} |
| STATE | 15:0 | `log_wp` | RO | core | records written |
| STATE | 16 | `cpu_irq` | RO | core | the CPU interrupt |

### Interrupts (IRQ_STATUS, IRQ_ENABLE)

A bit is set while its source is active, stays set until written with 1, and a set in the same clock as the clear wins.

| Bit | Name | Set when |
|---|---|---|
| 0 | CPU | cpu_irq was high (level: sets again while a source is pending) |
| 1 | LOG_ERR | a log write got an AXI error response |

## Programming sequence

1. Release PRESETN. Read ID (0x000) and check it is 0x5C0B0100.
2. Write 0x3 to IRQ_STATUS (0x004) to clear any stale bits.
3. Configure the core: write ENABLE (0x014), SW_SET (0x018), LOG_CTRL (0x01C), LOG_BASE (0x020). Reset values are in the register map; PSTRB selects the bytes written.
4. Write IRQ_ENABLE (0x008) with the interrupts to use (bit order as in the Interrupts table; 0x3 enables all).
5. Read PENDING (0x024) for the core's live `pending`; it needs no clearing.
6. Read CLAIM (0x028) for the core's live `claim`; it needs no clearing.
7. Read STATE (0x02C) for the core's live `log_wp`, `cpu_irq`; it needs no clearing.
8. On `irq`: read IRQ_STATUS, handle every bit that is set and enabled, then write those bits back to IRQ_STATUS to clear them. A source that is still active sets its bit again.

IP-specific use:

1. Write LOG_BASE and LOG_CTRL (optional), then ENABLE.
2. On cpu_irq read CLAIM, service source id at its device, repeat until CLAIM.valid = 0.

## Running and verifying

All commands run from the repository root. Icarus Verilog 12 and Yosys 0.33 are enough for steps 1 to 3; step 4 also needs Verilator 5.052 and pyslang (see [README, Setup](../../README.md#setup)).

| Step | Command | Pass when | Output |
|---|---|---|---|
| 1. Core test | `make -f Makefile.Interrupt_Controller sim` | a `TEST PASSED` line, no `ERROR` | console |
| 2. Core synthesis | `make -f Makefile.Interrupt_Controller syn` | Yosys ends without `ERROR`; `stat` prints the cell count | `work/Interrupt_Controller_top.json` |
| 3. APB wrapper test + synthesis | `make -f Makefile.Interrupt_Controller apb` | `TEST PASSED: Interrupt_Controller_apb`, then Yosys without `ERROR` | console, `work/Interrupt_Controller_apb.json` |
| 4. Coverage (core, wrapper) | `bash scripts/cov/run_cov.sh Interrupt_Controller`<br>`bash scripts/cov/run_cov.sh Interrupt_Controller_apb` | `RESULT: CLOSED` (all five metrics 100%) | `work/cov/Interrupt_Controller/score.json`, `work/cov/Interrupt_Controller_apb/score.json` |

Expected end of a step 4 run:

```
===== Interrupt_Controller =====
TEST: PASSED   SVA_FAILURES: 0
LINE ... TOGGLE ... FSM ... SVA ... FUNCTIONAL  (each n/n, 100.0%)
RESULT: CLOSED
```

**Core test** (`tb/Interrupt_Controller_tb.sv`): drives `Interrupt_Controller_top` through its own ports against a protocol peer or model and checks every result itself; any mismatch prints `ERROR`, and `TEST PASSED` is printed only when there were none.

**APB wrapper test** (`tb/Interrupt_Controller_apb_tb.sv`), in this order:

1. Reset values of every register, ID included.
2. Writes to read-only registers are ignored.
3. Each RW register: all ones, all zeros, then 16 random writes with every PSTRB byte-lane pattern, read back each time.
4. Unmapped and misaligned addresses, reads and writes: PSLVERR, read data 0, no side effect on other registers.
5. Back-to-back transfers with no idle cycle.
6. IP traffic through the registers only (`tb/apb/Interrupt_Controller_apb_func.svh`): the programming sequence above, every interrupt bit set, enabled and cleared (100% wrapper toggle coverage confirms each bit moved).
7. PRESETN asserted mid-run: `irq` and PRDATA go to 0, registers return to reset values.

**Checkers** (`tb/cov/Interrupt_Controller_sva.sv`, `tb/cov/Interrupt_Controller_apb_sva.sv`): SVA protocol and APB assertions plus covergroups, bound in by the coverage flow. An assertion failure prints `SVA_FAIL` and fails the run even when the test itself passed.

Whole portfolio: `bash scripts/ci_regression.sh` runs steps 1 to 3 for every IP (what CI runs), and `bash scripts/cov/run_all.sh 4` runs step 4 for every IP.

## Verification

Five-metric coverage with Verilator 5.052 (`scripts/cov/run_cov.sh`); see [COVERAGE_CLOSURE.md](../COVERAGE_CLOSURE.md) for the flow. Line and toggle count only the named RTL file.

| Scope | Test | Line | Toggle | FSM | SVA | Functional |
|---|---|---|---|---|---|---|
| core `rtl/Interrupt_Controller_top.sv` | not run | | | | | |
| wrapper `rtl/Interrupt_Controller_apb.sv` | pass | 34/34 | 1195/1484 | n/a | 12/12 | 41/41 |
