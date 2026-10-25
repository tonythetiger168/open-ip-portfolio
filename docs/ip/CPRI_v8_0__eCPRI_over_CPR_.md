# CPRI v8.0 REC link-layer slice: 8b/10b both ways, hyperframe sync (HUNT, ALIGN, SYNC) on the peer's K28.5, L1 inband rate and version negotiation, vendor byte, uplink IQ buffered for the CPU

Protocol IP `CPRI_v8_0__eCPRI_over_CPR_`, version 2.0. Apache-2.0.

| Item | Value |
|---|---|
| Core | `CPRI_v8_0__eCPRI_over_CPR__top` (`rtl/CPRI_v8_0__eCPRI_over_CPR__top.sv`) |
| Register interface | APB4 slave `CPRI_v8_0__eCPRI_over_CPR__apb`, 32-bit data, 12-bit byte address, zero wait states |
| Clock, reset | PCLK (rising edge), PRESETN (active low, asynchronous) |
| ID register | 0x43500200 (code 0x4350, version 2.0) |
| Registers | 19 words, 0x000 to 0x048 |
| Interrupts | 1 sources into one level-high `irq` |
| Core register port | CORE (14 words) |
| Protocol pins | 2 pass-through |

## Overview

CPRI v8.0 (eCPRI over CPR) -- CPRI master (REC) link-layer slice

- full 8b/10b encode/decode: all D0.0..D31.7 (with the D.x.A7 alternate)
+ K28.x, running disparity on both directions; a received symbol that
is not a code group or has the wrong disparity is a code violation
(symbol = {a,b,c,d,e,i,f,g,h,j}, 'a' transmitted first, 1 symbol/clk)
- basic frame = 1 control word + 15 IQ words (16 bytes)
- hyperframe = 64 basic frames (simplified from 256 -- educational slice)
- sync FSM: master sends K28.5+0x50+0x50 at hyperframe start, peer RE
replies with K28.5; HUNT -> ALIGN (2 well-placed commas) -> SYNC,
rx phase locks onto the peer hyperframe
- control word slots: #0 sync (K28.5), #1 L1 inband (16-hyperframe slow
stream carrying rate / pointer-p / protocol-version negotiation),
#4 vendor byte
- IQ data: peer 16-bit I/Q interleaved byte stream packed into 32x32
buffer as {I[15:0],Q[15:0]} words, cpu port pop; words arriving with
the buffer full are dropped and counted (saturating at 255)
- 8x8 rate config registers (cpu port)
- loss of sync: 4 consecutive hyperframes without peer K28.5 at the
expected position -> resync (HUNT) + irq

rx_sym and tx_sym are the line pins, one 10-bit 8b/10b symbol per PCLK; they pass through unchanged. The transmitter runs from reset: K28.5 and the sync bytes at each hyperframe start, the L1 inband stream, the vendor byte and a fixed IQ pattern.
A hyperframe here is 64 basic frames of 16 bytes (the standard has 256). Two commas one hyperframe apart give SYNC; four hyperframes in a row without the peer's comma give loss of sync.
Core registers take whole words: a write with PSTRB != 4'hF gets PSLVERR and is dropped. Only bits [7:0] of CFG0..CFG7 are stored.

## Files

| File | Content |
|---|---|
| `rtl/CPRI_v8_0__eCPRI_over_CPR__top.sv` | protocol core |
| `rtl/CPRI_v8_0__eCPRI_over_CPR__apb.sv` | APB4 register wrapper (generated) |
| `tb/CPRI_v8_0__eCPRI_over_CPR__tb.sv` | core testbench |
| `tb/CPRI_v8_0__eCPRI_over_CPR__apb_tb.sv`, `tb/apb/CPRI_v8_0__eCPRI_over_CPR__apb_func.svh` | wrapper testbench (generated part + IP-specific part) |
| `tb/cov/CPRI_v8_0__eCPRI_over_CPR__sva.sv`, `tb/cov/CPRI_v8_0__eCPRI_over_CPR__apb_sva.sv` | coverage checkers (core, wrapper) |
| `scripts/apb/specs/CPRI_v8_0__eCPRI_over_CPR_.json` | register spec the wrapper, TB, checker and this page are generated from |

How to run the tests and the coverage flow: see [Running and verifying](#running-and-verifying).

## Parameters

The core and the wrapper have no parameters.

## Wrapper pins

Pins of `CPRI_v8_0__eCPRI_over_CPR__apb`. Widths of the pass-through pins are at the default parameters.

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
| `rx_sym` | input | 10 | protocol pin, core port `rx_sym` |
| `tx_sym` | output | 10 | protocol pin, core port `tx_sym` |

## Core ports

| Port | Dir | Width | In the APB wrapper |
|---|---|---|---|
| `clk` | input | 1 | PCLK |
| `rst_n` | input | 1 | PRESETN |
| `rx_sym` | input | 10 | pin (pass-through) |
| `tx_sym` | output | 10 | pin (pass-through) |
| `cpu_we` | input | 1 | write to a CORE word |
| `cpu_re` | input | 1 | read of a CORE word |
| `cpu_addr` | input | 4 | CORE word index |
| `cpu_wdata` | input | 32 | CORE write data |
| `cpu_rdata` | output | 32 | CORE read data |
| `irq` | output | 1 | IRQ_STATUS.LINK_EVENT |

## APB wrapper

`CPRI_v8_0__eCPRI_over_CPR__apb` is an APB4 slave (AMBA APB protocol v2.0): zero wait states, 32-bit data, 12-bit byte address, PSTRB byte lanes on every writable register, PSLVERR on an unmapped or misaligned address (reads then return 0, writes are dropped). Writes to read-only registers are ignored without an error. The core runs on PCLK and PRESETN. `irq` is level-high: `|(IRQ_STATUS & IRQ_ENABLE)`.

Pass-through pins: `rx_sym`, `tx_sym`.

### Register map

| Offset | Name | Access | Reset | Description |
|---|---|---|---|---|
| 0x000 | ID | RO | 0x43500200 | IP identification: code, major and minor version |
| 0x004 | IRQ_STATUS | W1C | 0x00000000 | Sticky interrupt bits, write 1 to clear |
| 0x008 | IRQ_ENABLE | RW | 0x00000000 | Interrupt enables; irq = \|(IRQ_STATUS & IRQ_ENABLE) |
| 0x00C | FLAGS | RO | 0x00000000 | Stream holding-register state |
| 0x010 | SCRATCH | RW | 0x00000000 | Scratch register, no effect on the core |
| 0x014 | CFG0 | RW (core) | core | {pointer p[7:4], line rate[3:0]} sent in the L1 inband stream; the rate is negotiated against the peer's (reset 0x2A) |
| 0x018 | CFG1 | RW (core) | core | bits [3:0]: local protocol version, sent in the L1 inband stream and negotiated (reset 0x04) |
| 0x01C | CFG2 | RW (core) | core | vendor byte, sent in control word #4 of each hyperframe (reset 0xC9) |
| 0x020 | CFG3 | RW (core) | core | spare configuration byte, no effect on the link (reset 0) |
| 0x024 | CFG4 | RW (core) | core | spare configuration byte, no effect on the link (reset 0) |
| 0x028 | CFG5 | RW (core) | core | spare configuration byte, no effect on the link (reset 0) |
| 0x02C | CFG6 | RW (core) | core | spare configuration byte, no effect on the link (reset 0) |
| 0x030 | CFG7 | RW (core) | core | spare configuration byte, no effect on the link (reset 0) |
| 0x034 | LINK | RO (core) | core | [1:0] sync state (0 HUNT, 1 ALIGN, 2 SYNC), [2] L1 inband negotiation received, [4:3] hyperframes missed in a row, [11:6] IQ words buffered, [15:12] peer protocol version, [23:16] IQ words dropped with the buffer full (saturates at 255) |
| 0x038 | NEG | RO (core) | core | [3:0] negotiated protocol version, [7:4] negotiated line rate (the smaller of ours and the peer's) |
| 0x03C | IQ | RO (core) | core | oldest buffered IQ word {I[15:0], Q[15:0]}; reading it pops the word when one is buffered |
| 0x040 | IQ_COUNT | RO (core) | core | IQ words buffered (0..32) |
| 0x044 | VENDOR | RO (core) | core | vendor byte received from the peer |
| 0x048 | EVENTS | RW (core) | core | [0] loss of sync, [1] code violation; sticky, write 1 to clear (a violation in the same clock wins) |

Unlisted bits read 0 and ignore writes. Reset "core": the register reads the core's outputs directly, so after reset it shows the core's own reset state. WO (pulse) registers read 0. Offsets from 0x04C up to 0xFFC are unmapped (PSLVERR).

### Fields

| Register | Bits | Field | Access | Reset | Description |
|---|---|---|---|---|---|
| ID | 31:16 | CODE | RO | 0x4350 | IP code |
| ID | 15:8 | MAJOR | RO | 0x02 | major version |
| ID | 7:0 | MINOR | RO | 0x00 | minor version |
| IRQ_STATUS | 0 | one bit per interrupt | W1C | 0x0 | see Interrupts |
| IRQ_ENABLE | 0 | one bit per interrupt | RW | 0x0 | 1 enables the IRQ_STATUS bit onto `irq` |
| SCRATCH | 31:0 | SCRATCH | RW | 0x00000000 | free for software |
| CFG0 | 31:0 | core register | RW (core) | core | written at core register 0 and read from core register 0 |
| CFG1 | 31:0 | core register | RW (core) | core | written at core register 1 and read from core register 1 |
| CFG2 | 31:0 | core register | RW (core) | core | written at core register 2 and read from core register 2 |
| CFG3 | 31:0 | core register | RW (core) | core | written at core register 3 and read from core register 3 |
| CFG4 | 31:0 | core register | RW (core) | core | written at core register 4 and read from core register 4 |
| CFG5 | 31:0 | core register | RW (core) | core | written at core register 5 and read from core register 5 |
| CFG6 | 31:0 | core register | RW (core) | core | written at core register 6 and read from core register 6 |
| CFG7 | 31:0 | core register | RW (core) | core | written at core register 7 and read from core register 7 |
| LINK | 31:0 | core register | RO (core) | core | read from core register 8 |
| NEG | 31:0 | core register | RO (core) | core | read from core register 9 |
| IQ | 31:0 | core register | RO (core) | core | read from core register 10 |
| IQ_COUNT | 31:0 | core register | RO (core) | core | read from core register 11 |
| VENDOR | 31:0 | core register | RO (core) | core | read from core register 12 |
| EVENTS | 31:0 | core register | RW (core) | core | written at core register 13 and read from core register 13 |

### Interrupts (IRQ_STATUS, IRQ_ENABLE)

A bit is set while its source is active, stays set until written with 1, and a set in the same clock as the clear wins.

| Bit | Name | Set when |
|---|---|---|
| 0 | LINK_EVENT | EVENTS has a bit set (loss of sync or a code violation); set on every clock until EVENTS is cleared, so clear EVENTS first |

### Core register port

The CORE words reach the core's own register port. A write to one pulses `cpu_we` for one clock with `cpu_addr` (the core register) and `cpu_wdata` (PWDATA's low bits); it must cover the whole word (PSTRB = 4'hF): a partial write is dropped with PSLVERR. A read drives `cpu_addr` (the core register) and pulses `cpu_re` during the access phase and returns `cpu_rdata`.

## Programming sequence

1. Release PRESETN. Read ID (0x000) and check it is 0x43500200.
2. Write 0x1 to IRQ_STATUS (0x004) to clear any stale bits.
3. Write IRQ_ENABLE (0x008) with the interrupts to use (bit order as in the Interrupts table; 0x1 enables all).
4. Access the core's registers through the CORE words (0x014 onward), one word per core register; write whole words (PSTRB = 0xF), a partial write is dropped with PSLVERR.
5. On `irq`: read IRQ_STATUS, handle every bit that is set and enabled, then write those bits back to IRQ_STATUS to clear them. A source that is still active sets its bit again.

## Running and verifying

All commands run from the repository root. Icarus Verilog 12 and Yosys 0.33 are enough for steps 1 to 3; step 4 also needs Verilator 5.052 and pyslang (see [README, Setup](../../README.md#setup)).

| Step | Command | Pass when | Output |
|---|---|---|---|
| 1. Core test | `make -f Makefile.CPRI_v8_0__eCPRI_over_CPR_ sim` | a `TEST PASSED` line, no `ERROR` | console |
| 2. Core synthesis | `make -f Makefile.CPRI_v8_0__eCPRI_over_CPR_ syn` | Yosys ends without `ERROR`; `stat` prints the cell count | `work/CPRI_v8_0__eCPRI_over_CPR__top.json` |
| 3. APB wrapper test + synthesis | `make -f Makefile.CPRI_v8_0__eCPRI_over_CPR_ apb` | `TEST PASSED: CPRI_v8_0__eCPRI_over_CPR__apb`, then Yosys without `ERROR` | console, `work/CPRI_v8_0__eCPRI_over_CPR__apb.json` |
| 4. Coverage (core, wrapper) | `bash scripts/cov/run_cov.sh CPRI_v8_0__eCPRI_over_CPR_`<br>`bash scripts/cov/run_cov.sh CPRI_v8_0__eCPRI_over_CPR__apb` | `RESULT: CLOSED` (all five metrics 100%) | `work/cov/CPRI_v8_0__eCPRI_over_CPR_/score.json`, `work/cov/CPRI_v8_0__eCPRI_over_CPR__apb/score.json` |

Expected end of a step 4 run:

```
===== CPRI_v8_0__eCPRI_over_CPR_ =====
TEST: PASSED   SVA_FAILURES: 0
LINE ... TOGGLE ... FSM ... SVA ... FUNCTIONAL  (each n/n, 100.0%)
RESULT: CLOSED
```

**Core test** (`tb/CPRI_v8_0__eCPRI_over_CPR__tb.sv`): drives `CPRI_v8_0__eCPRI_over_CPR__top` through its own ports against a protocol peer or model and checks every result itself; any mismatch prints `ERROR`, and `TEST PASSED` is printed only when there were none.

**APB wrapper test** (`tb/CPRI_v8_0__eCPRI_over_CPR__apb_tb.sv`), in this order:

1. Reset values of every register, ID included.
2. Writes to read-only registers are ignored.
3. Each RW register: all ones, all zeros, then 16 random writes with every PSTRB byte-lane pattern, read back each time.
4. Unmapped and misaligned addresses, reads and writes: PSLVERR, read data 0, no side effect on other registers.
5. Back-to-back transfers with no idle cycle.
6. IP traffic through the registers only (`tb/apb/CPRI_v8_0__eCPRI_over_CPR__apb_func.svh`): the programming sequence above, every interrupt bit set, enabled and cleared (100% wrapper toggle coverage confirms each bit moved).
7. PRESETN asserted mid-run: `irq` and PRDATA go to 0, registers return to reset values.

**Checkers** (`tb/cov/CPRI_v8_0__eCPRI_over_CPR__sva.sv`, `tb/cov/CPRI_v8_0__eCPRI_over_CPR__apb_sva.sv`): SVA protocol and APB assertions plus covergroups, bound in by the coverage flow. An assertion failure prints `SVA_FAIL` and fails the run even when the test itself passed.

Whole portfolio: `bash scripts/ci_regression.sh` runs steps 1 to 3 for every IP (what CI runs), and `bash scripts/cov/run_all.sh 4` runs step 4 for every IP.

## Verification

Five-metric coverage with Verilator 5.052 (`scripts/cov/run_cov.sh`); see [COVERAGE_CLOSURE.md](../COVERAGE_CLOSURE.md) for the flow. Line and toggle count only the named RTL file.

| Scope | Test | Line | Toggle | FSM | SVA | Functional |
|---|---|---|---|---|---|---|
| core `rtl/CPRI_v8_0__eCPRI_over_CPR__top.sv` | pass | 244/244 | 634/634 | 7/7 | 6/6 | 299/299 |
| wrapper `rtl/CPRI_v8_0__eCPRI_over_CPR__apb.sv` | pass | 33/33 | 592/592 | n/a | 11/11 | 52/52 |
