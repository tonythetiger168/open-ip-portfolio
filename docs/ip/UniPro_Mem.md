# MIPI UniPro-Mem: UniPro data link layer (ESC_DL / COF framing, CRC-16, NAC retransmission, TC1 over TC0 priority) carrying a memory-mapped transaction layer (writes / reads of a 64 x 32-bit memory with a read timeout) and PACP attribute get / set

Protocol IP `UniPro_Mem`, version 2.0. Apache-2.0.

| Item | Value |
|---|---|
| Core | `UniPro_Mem_top` (`rtl/UniPro_Mem_top.sv`) |
| Register interface | APB4 slave `UniPro_Mem_apb`, 32-bit data, 12-bit byte address, zero wait states |
| Clock, reset | PCLK (rising edge), PRESETN (active low, asynchronous) |
| ID register | 0x554D0200 (code 0x554D, version 2.0) |
| Registers | 5 words, 0x000 to 0x010 |
| Interrupts | 1 sources into one level-high `irq` |
| Protocol pins | 5 pass-through |

## Overview

MIPI UniPro-Mem -- UniPro 1.x data-link layer (educational slice) with a memory-mapped transaction-layer service. * 8-bit symbol serial link, ESC_DL escape (8'h9D) + COF (8'hC0) framing; a data byte equal to ESC or COF is sent as ESC, byte ^ 8'h20 * L2 frame: hdr{tc,cport[3:0]}{seq[3:0]}{len[7:0]} payload(<=16B) CRC16(0x1021) (the sequence number of received frames is not checked) * CPort1 memory transactions: write/read of a 64x32 memory; a queued read response that cannot start transmission within 100 clk is replaced by an error frame (read timeout) * PACP-style attribute get/set (16x8 regs) on CPort 0xF * Outgoing data frames carry seq numbers; NAC triggers retransmit (<=3, then irq). QoS: TC1 strict priority over TC0. irq: CRC error / out-of-bounds / NAC retransmit exhausted / response dropped because its traffic-class queue slot is still occupied (TX back-pressure). * Responses are queued as records (kind + fields) and serialized into bytes by the TX engine.

rx_sym / rx_valid (symbols in), tx_sym / tx_valid / tx_ready (symbols out with back-pressure) pass through unchanged.
Memory and attributes are reached over the UniPro link only; the registers report its errors.

## Files

| File | Content |
|---|---|
| `rtl/UniPro_Mem_top.sv` | protocol core |
| `rtl/UniPro_Mem_apb.sv` | APB4 register wrapper (generated) |
| `tb/UniPro_Mem_tb.sv` | core testbench |
| `tb/UniPro_Mem_apb_tb.sv`, `tb/apb/UniPro_Mem_apb_func.svh` | wrapper testbench (generated part + IP-specific part) |
| `tb/cov/UniPro_Mem_sva.sv`, `tb/cov/UniPro_Mem_apb_sva.sv` | coverage checkers (core, wrapper) |
| `scripts/apb/specs/UniPro_Mem.json` | register spec the wrapper, TB, checker and this page are generated from |

How to run the tests and the coverage flow: see [Running and verifying](#running-and-verifying).

## Parameters

The core and the wrapper have no parameters.

## Wrapper pins

Pins of `UniPro_Mem_apb`. Widths of the pass-through pins are at the default parameters.

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
| `rx_sym` | input | 8 | protocol pin, core port `rx_sym` |
| `rx_valid` | input | 1 | protocol pin, core port `rx_valid` |
| `tx_sym` | output | 8 | protocol pin, core port `tx_sym` |
| `tx_valid` | output | 1 | protocol pin, core port `tx_valid` |
| `tx_ready` | input | 1 | protocol pin, core port `tx_ready` |

## Core ports

| Port | Dir | Width | In the APB wrapper |
|---|---|---|---|
| `clk` | input | 1 | PCLK |
| `rst_n` | input | 1 | PRESETN |
| `rx_sym` | input | 8 | pin (pass-through) |
| `rx_valid` | input | 1 | pin (pass-through) |
| `tx_sym` | output | 8 | pin (pass-through) |
| `tx_valid` | output | 1 | pin (pass-through) |
| `tx_ready` | input | 1 | pin (pass-through) |
| `irq` | output | 1 | IRQ_STATUS.ERR |

## APB wrapper

`UniPro_Mem_apb` is an APB4 slave (AMBA APB protocol v2.0): zero wait states, 32-bit data, 12-bit byte address, PSTRB byte lanes on every writable register, PSLVERR on an unmapped or misaligned address (reads then return 0, writes are dropped). Writes to read-only registers are ignored without an error. The core runs on PCLK and PRESETN. `irq` is level-high: `|(IRQ_STATUS & IRQ_ENABLE)`.

Pass-through pins: `rx_sym`, `rx_valid`, `tx_sym`, `tx_valid`, `tx_ready`.

### Register map

| Offset | Name | Access | Reset | Description |
|---|---|---|---|---|
| 0x000 | ID | RO | 0x554D0200 | IP identification: code, major and minor version |
| 0x004 | IRQ_STATUS | W1C | 0x00000000 | Sticky interrupt bits, write 1 to clear |
| 0x008 | IRQ_ENABLE | RW | 0x00000000 | Interrupt enables; irq = \|(IRQ_STATUS & IRQ_ENABLE) |
| 0x00C | FLAGS | RO | 0x00000000 | Stream holding-register state |
| 0x010 | SCRATCH | RW | 0x00000000 | Scratch register, no effect on the core |

Unlisted bits read 0 and ignore writes. Reset "core": the register reads the core's outputs directly, so after reset it shows the core's own reset state. WO (pulse) registers read 0. Offsets from 0x014 up to 0xFFC are unmapped (PSLVERR).

### Fields

| Register | Bits | Field | Access | Reset | Description |
|---|---|---|---|---|---|
| ID | 31:16 | CODE | RO | 0x554D | IP code |
| ID | 15:8 | MAJOR | RO | 0x02 | major version |
| ID | 7:0 | MINOR | RO | 0x00 | minor version |
| IRQ_STATUS | 0 | one bit per interrupt | W1C | 0x0 | see Interrupts |
| IRQ_ENABLE | 0 | one bit per interrupt | RW | 0x0 | 1 enables the IRQ_STATUS bit onto `irq` |
| SCRATCH | 31:0 | SCRATCH | RW | 0x00000000 | free for software |

### Interrupts (IRQ_STATUS, IRQ_ENABLE)

A bit is set while its source is active, stays set until written with 1, and a set in the same clock as the clear wins.

| Bit | Name | Set when |
|---|---|---|
| 0 | ERR | received CRC error, out-of-bounds or invalid-length memory request, NAC retransmit budget exhausted, or a response dropped because its traffic-class slot was still occupied |

## Programming sequence

1. Release PRESETN. Read ID (0x000) and check it is 0x554D0200.
2. Write 0x1 to IRQ_STATUS (0x004) to clear any stale bits.
3. Write IRQ_ENABLE (0x008) with the interrupts to use (bit order as in the Interrupts table; 0x1 enables all).
4. On `irq`: read IRQ_STATUS, handle every bit that is set and enabled, then write those bits back to IRQ_STATUS to clear them. A source that is still active sets its bit again.

## Running and verifying

All commands run from the repository root. Icarus Verilog 12 and Yosys 0.33 are enough for steps 1 to 3; step 4 also needs Verilator 5.052 and pyslang (see [README, Setup](../../README.md#setup)).

| Step | Command | Pass when | Output |
|---|---|---|---|
| 1. Core test | `make -f Makefile.UniPro_Mem sim` | a `TEST PASSED` line, no `ERROR` | console |
| 2. Core synthesis | `make -f Makefile.UniPro_Mem syn` | Yosys ends without `ERROR`; `stat` prints the cell count | `work/UniPro_Mem_top.json` |
| 3. APB wrapper test + synthesis | `make -f Makefile.UniPro_Mem apb` | `TEST PASSED: UniPro_Mem_apb`, then Yosys without `ERROR` | console, `work/UniPro_Mem_apb.json` |
| 4. Coverage (core, wrapper) | `bash scripts/cov/run_cov.sh UniPro_Mem`<br>`bash scripts/cov/run_cov.sh UniPro_Mem_apb` | `RESULT: CLOSED` (all five metrics 100%) | `work/cov/UniPro_Mem/score.json`, `work/cov/UniPro_Mem_apb/score.json` |

Expected end of a step 4 run:

```
===== UniPro_Mem =====
TEST: PASSED   SVA_FAILURES: 0
LINE ... TOGGLE ... FSM ... SVA ... FUNCTIONAL  (each n/n, 100.0%)
RESULT: CLOSED
```

**Core test** (`tb/UniPro_Mem_tb.sv`): drives `UniPro_Mem_top` through its own ports against a protocol peer or model and checks every result itself; any mismatch prints `ERROR`, and `TEST PASSED` is printed only when there were none.

**APB wrapper test** (`tb/UniPro_Mem_apb_tb.sv`), in this order:

1. Reset values of every register, ID included.
2. Writes to read-only registers are ignored.
3. Each RW register: all ones, all zeros, then 16 random writes with every PSTRB byte-lane pattern, read back each time.
4. Unmapped and misaligned addresses, reads and writes: PSLVERR, read data 0, no side effect on other registers.
5. Back-to-back transfers with no idle cycle.
6. IP traffic through the registers only (`tb/apb/UniPro_Mem_apb_func.svh`): the programming sequence above, every interrupt bit set, enabled and cleared (100% wrapper toggle coverage confirms each bit moved).
7. PRESETN asserted mid-run: `irq` and PRDATA go to 0, registers return to reset values.

**Checkers** (`tb/cov/UniPro_Mem_sva.sv`, `tb/cov/UniPro_Mem_apb_sva.sv`): SVA protocol and APB assertions plus covergroups, bound in by the coverage flow. An assertion failure prints `SVA_FAIL` and fails the run even when the test itself passed.

Whole portfolio: `bash scripts/ci_regression.sh` runs steps 1 to 3 for every IP (what CI runs), and `bash scripts/cov/run_all.sh 4` runs step 4 for every IP.

## Verification

Five-metric coverage with Verilator 5.052 (`scripts/cov/run_cov.sh`); see [COVERAGE_CLOSURE.md](../COVERAGE_CLOSURE.md) for the flow. Line and toggle count only the named RTL file.

| Scope | Test | Line | Toggle | FSM | SVA | Functional |
|---|---|---|---|---|---|---|
| core `rtl/UniPro_Mem_top.sv` | pass | 142/142 | 2116/2116 | 14/14 | 5/5 | 106/106 |
| wrapper `rtl/UniPro_Mem_apb.sv` | pass | 19/19 | 430/430 | n/a | 7/7 | 23/23 |
