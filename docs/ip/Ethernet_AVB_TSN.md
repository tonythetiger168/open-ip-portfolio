# TSN egress transmission selection (802.1Qbv gates, 802.1Qav shapers, strict priority, PTP time)

Protocol IP `Ethernet_AVB_TSN`, version 2.0. Apache-2.0.

| Item | Value |
|---|---|
| Core | `Ethernet_AVB_TSN_top` (`rtl/Ethernet_AVB_TSN_top.sv`) |
| Register interface | APB4 slave `Ethernet_AVB_TSN_apb`, 32-bit data, 12-bit byte address, zero wait states |
| Clock, reset | PCLK (rising edge), PRESETN (active low, asynchronous) |
| ID register | 0x54530200 (code 0x5453, version 2.0) |
| Registers | 21 words, 0x000 to 0x050 |
| Interrupts | 2 sources into one level-high `irq` |
| Data streams | GCL_WR (to the core), TIME_SET (to the core), TIME_ADJ (to the core) |
| Protocol pins | 6 pass-through |

## Overview

Ethernet_AVB_TSN_top v2.0: TSN egress transmission selection for one port with 4 traffic classes: IEEE 802.1Qbv time-aware gates, 802.1Qav credit-based shapers, strict priority, a PTP time counter and egress timestamps

- Line: one byte per clk. A frame of L bytes occupies the line for
L + 20 clocks (preamble + SFD 8, inter-frame gap 12). The MAC is told
which frame to send (tx_start, tx_tc, tx_len, tx_ts); the queues show
their head frame (q_valid[c], q_len[c]) and get q_pop[c] when it is
taken.
- Time: {time_ns, 16-bit fraction} advances by {cfg_inc_ns,
cfg_inc_frac} every clk; time_set loads time_set_ns (fraction 0);
time_adj adds the signed time_adj_ns. tx_ts = time_ns in the clock
the frame is selected.
- Gate control list (802.1Qbv): entries 0..gcl_last of {gates[3:0],
interval ns}, written through gcl_we / gcl_waddr (write while
gcl_en = 0). With gcl_en the schedule starts in the first clock with
time_ns >= gcl_base and then runs in elapsed time (cfg_inc_ns per
clk; time_set / time_adj do not move it): entry k lasts its interval,
the last entry lasts until the cycle ends, a cycle lasts gcl_cycle ns
(entries beyond it are cut). Gate changes and cycle starts happen in
the first clock at or after their time; the remainder is carried.
Without gcl_en, and before the schedule starts, every gate is open.
Intervals and the cycle must be at least cfg_inc_ns.
- Guard band: while the schedule runs, a frame of class c starts only
if gate c stays open for its whole line time (L + 20) * cfg_inc_ns,
counted from now to the next close of gate c or the end of the cycle,
whichever is first (a frame never crosses a cycle boundary).
- Credit-based shaper (802.1Qav), per class with cbs_en[c]: credit
(20-bit signed, saturating, units 1/256 byte) changes every clock by
cbs_idle[c] - 256 while class c transmits; by cbs_idle[c] while a
frame waits and the gate is open; it is held while a frame waits
behind a closed gate; with no frame queued, a positive credit drops
to 0 and a negative one rises by cbs_idle[c] up to 0. A class is
eligible only with credit >= 0. Without cbs_en[c] the credit is 0.
- Selection: when the line is free, the highest class with a frame
that passes its gate, guard band and shaper starts.
Not implemented: frame preemption (802.1Qbu), per-stream filtering,
gate-list switching at a config change time, hold/release, PTP message
handling (timestamps only), more than 4 classes.

q_valid / q_len / q_pop connect to the four class queues of the frame buffer (head frame length, pop when taken); tx_start, tx_tc, tx_len, tx_ts and tx_busy connect to the MAC. One byte per PCLK: a frame of L bytes occupies the line for L + 20 clocks.
The wrapper takes tx_start and tx_busy into IRQ_STATUS and STATUS; the MAC uses |q_pop as the frame start strobe (q_pop is one-hot in exactly that clock). tx_ts is the time in the clock the frame was selected (the egress timestamp before the MAC's fixed latency).

## Files

| File | Content |
|---|---|
| `rtl/Ethernet_AVB_TSN_top.sv` | protocol core |
| `rtl/Ethernet_AVB_TSN_apb.sv` | APB4 register wrapper (generated) |
| `tb/Ethernet_AVB_TSN_tb.sv` | core testbench |
| `tb/Ethernet_AVB_TSN_apb_tb.sv`, `tb/apb/Ethernet_AVB_TSN_apb_func.svh` | wrapper testbench (generated part + IP-specific part) |
| `tb/cov/Ethernet_AVB_TSN_sva.sv`, `tb/cov/Ethernet_AVB_TSN_apb_sva.sv` | coverage checkers (core, wrapper) |
| `scripts/apb/specs/Ethernet_AVB_TSN.json` | register spec the wrapper, TB, checker and this page are generated from |

How to run the tests and the coverage flow: see [Running and verifying](#running-and-verifying).

## Parameters

The core and the wrapper have no parameters.

## Wrapper pins

Pins of `Ethernet_AVB_TSN_apb`. Widths of the pass-through pins are at the default parameters.

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
| `q_valid` | input | 4 | protocol pin, core port `q_valid` |
| `q_len` | input | 44 | protocol pin, core port `q_len` |
| `q_pop` | output | 4 | protocol pin, core port `q_pop` |
| `tx_tc` | output | 2 | protocol pin, core port `tx_tc` |
| `tx_len` | output | 11 | protocol pin, core port `tx_len` |
| `tx_ts` | output | 64 | protocol pin, core port `tx_ts` |

## Core ports

| Port | Dir | Width | In the APB wrapper |
|---|---|---|---|
| `clk` | input | 1 | PCLK |
| `rst_n` | input | 1 | PRESETN |
| `cfg_inc_ns` | input | 8 | CFG0[7:0] |
| `cfg_inc_frac` | input | 16 | CFG0[23:8] |
| `time_set` | input | 1 | TIME_SET commit / FLAGS |
| `time_set_ns` | input | 64 | TIME_SET0[31:0], TIME_SET1[31:0] |
| `time_adj` | input | 1 | TIME_ADJ commit / FLAGS |
| `time_adj_ns` | input | 32 | TIME_ADJ[31:0] |
| `time_ns` | output | 64 | TIME0[31:0], TIME1[31:0] |
| `gcl_en` | input | 1 | CFG0[24:24] |
| `gcl_base` | input | 64 | GCL_BASE0[31:0], GCL_BASE1[31:0] |
| `gcl_cycle` | input | 24 | CFG1[23:0] |
| `gcl_last` | input | 3 | CFG0[27:25] |
| `gcl_we` | input | 1 | GCL_WR commit / FLAGS |
| `gcl_waddr` | input | 3 | GCL_WR[30:28] |
| `gcl_wgates` | input | 4 | GCL_WR[27:24] |
| `gcl_wivl` | input | 24 | GCL_WR[23:0] |
| `cbs_en` | input | 4 | CFG0[31:28] |
| `cbs_idle` | input | 36 | CBS_IDLE0[31:0], CBS_IDLE1[3:0] |
| `q_valid` | input | 4 | pin (pass-through) |
| `q_len` | input | 44 | pin (pass-through) |
| `q_pop` | output | 4 | pin (pass-through) |
| `tx_start` | output | 1 | IRQ_STATUS.TX |
| `tx_tc` | output | 2 | pin (pass-through) |
| `tx_len` | output | 11 | pin (pass-through) |
| `tx_ts` | output | 64 | pin (pass-through) |
| `tx_busy` | output | 1 | STATUS[8:8] |
| `gcl_running` | output | 1 | STATUS[0:0] |
| `gcl_entry` | output | 3 | STATUS[3:1] |
| `gate_state` | output | 4 | STATUS[7:4] |
| `cycle_start` | output | 1 | IRQ_STATUS.CYCLE |
| `cbs_credit` | output | 80 | CREDIT0[31:0], CREDIT1[31:0], CREDIT2[15:0] |

## APB wrapper

`Ethernet_AVB_TSN_apb` is an APB4 slave (AMBA APB protocol v2.0): zero wait states, 32-bit data, 12-bit byte address, PSTRB byte lanes on every writable register, PSLVERR on an unmapped or misaligned address (reads then return 0, writes are dropped). Writes to read-only registers are ignored without an error. The core runs on PCLK and PRESETN. `irq` is level-high: `|(IRQ_STATUS & IRQ_ENABLE)`.

Pass-through pins: `q_valid`, `q_len`, `q_pop`, `tx_tc`, `tx_len`, `tx_ts`.

### Register map

| Offset | Name | Access | Reset | Description |
|---|---|---|---|---|
| 0x000 | ID | RO | 0x54530200 | IP identification: code, major and minor version |
| 0x004 | IRQ_STATUS | W1C | 0x00000000 | Sticky interrupt bits, write 1 to clear |
| 0x008 | IRQ_ENABLE | RW | 0x00000000 | Interrupt enables; irq = \|(IRQ_STATUS & IRQ_ENABLE) |
| 0x00C | FLAGS | RO | 0x00000000 | Stream holding-register state |
| 0x010 | SCRATCH | RW | 0x00000000 | Scratch register, no effect on the core |
| 0x014 | CFG0 | RW | 0x00000008 | Time increment, schedule and shaper enables |
| 0x018 | CFG1 | RW | 0x000F4240 | Time increment, schedule and shaper enables |
| 0x01C | GCL_BASE0 | RW | 0x00000000 | Schedule start time, ns: the list starts in the first clock with time >= GCL_BASE |
| 0x020 | GCL_BASE1 | RW | 0x00000000 | Schedule start time, ns: the list starts in the first clock with time >= GCL_BASE |
| 0x024 | CBS_IDLE0 | RW | 0x00000000 | Shaper idle slopes, class c in bits 9c+8:9c, in 1/256 of the line rate (0..256) |
| 0x028 | CBS_IDLE1 | RW | 0x00000000 | Shaper idle slopes, class c in bits 9c+8:9c, in 1/256 of the line rate (0..256) |
| 0x02C | GCL_WR | RW | 0x00000000 | Writes one gate control list entry; writing GCL_WR commits it. Write entries while CFG.gcl_en = 0 |
| 0x030 | TIME_SET0 | RW | 0x00000000 | Loads the time (fraction 0); writing TIME_SET1 commits it |
| 0x034 | TIME_SET1 | RW | 0x00000000 | Loads the time (fraction 0); writing TIME_SET1 commits it |
| 0x038 | TIME_ADJ | RW | 0x00000000 | Adds a signed offset to the time once; writing TIME_ADJ commits it |
| 0x03C | TIME0 | RO | core | Current time, ns. TIME0 and TIME1 are read separately: read TIME1, TIME0, TIME1 again and retry if TIME1 changed |
| 0x040 | TIME1 | RO | core | Current time, ns. TIME0 and TIME1 are read separately: read TIME1, TIME0, TIME1 again and retry if TIME1 changed |
| 0x044 | STATUS | RO | core | Schedule and line state |
| 0x048 | CREDIT0 | RO | core | Shaper credits, class c in bits 20c+19:20c, signed, 1/256 byte |
| 0x04C | CREDIT1 | RO | core | Shaper credits, class c in bits 20c+19:20c, signed, 1/256 byte |
| 0x050 | CREDIT2 | RO | core | Shaper credits, class c in bits 20c+19:20c, signed, 1/256 byte |

Unlisted bits read 0 and ignore writes. Reset "core": the register reads the core's outputs directly, so after reset it shows the core's own reset state. WO (pulse) registers read 0. Offsets from 0x054 up to 0xFFC are unmapped (PSLVERR).

### Fields

| Register | Bits | Field | Access | Reset | Description |
|---|---|---|---|---|---|
| ID | 31:16 | CODE | RO | 0x5453 | IP code |
| ID | 15:8 | MAJOR | RO | 0x02 | major version |
| ID | 7:0 | MINOR | RO | 0x00 | minor version |
| IRQ_STATUS | 1:0 | one bit per interrupt | W1C | 0x0 | see Interrupts |
| IRQ_ENABLE | 1:0 | one bit per interrupt | RW | 0x0 | 1 enables the IRQ_STATUS bit onto `irq` |
| SCRATCH | 31:0 | SCRATCH | RW | 0x00000000 | free for software |
| CFG0 | 7:0 | `cfg_inc_ns` | RW | 0x8 | time increment per clock, whole ns (8: 125 MHz) |
| CFG0 | 23:8 | `cfg_inc_frac` | RW | 0x0 | time increment per clock, 1/65536 ns |
| CFG0 | 24 | `gcl_en` | RW | 0x0 | 1 = run the gate control list from GCL_BASE; 0 = all gates open |
| CFG0 | 27:25 | `gcl_last` | RW | 0x0 | last gate control list entry (0..7) |
| CFG0 | 31:28 | `cbs_en` | RW | 0x0 | credit-based shaper enable per class |
| CFG1 | 23:0 | `gcl_cycle` | RW | 0xF4240 | cycle time, ns |
| GCL_BASE0 | 31:0 | `gcl_base[31:0]` | RW | 0x0 | base time, ns |
| GCL_BASE1 | 31:0 | `gcl_base[63:32]` | RW | 0x0 | base time, ns |
| CBS_IDLE0 | 31:0 | `cbs_idle[31:0]` | RW | 0x0 | idle slopes of classes 0..3 |
| CBS_IDLE1 | 3:0 | `cbs_idle[35:32]` | RW | 0x0 | idle slopes of classes 0..3 |
| GCL_WR | 23:0 | `gcl_wivl` | RW | 0x0 | interval, ns (at least CFG.cfg_inc_ns) |
| GCL_WR | 27:24 | `gcl_wgates` | RW | 0x0 | gate states, bit c = class c open |
| GCL_WR | 30:28 | `gcl_waddr` | RW | 0x0 | entry |
| TIME_SET0 | 31:0 | `time_set_ns[31:0]` | RW | 0x0 | new time, ns |
| TIME_SET1 | 31:0 | `time_set_ns[63:32]` | RW | 0x0 | new time, ns |
| TIME_ADJ | 31:0 | `time_adj_ns` | RW | 0x0 | signed offset, ns |
| TIME0 | 31:0 | `time_ns[31:0]` | RO | core | time, ns |
| TIME1 | 31:0 | `time_ns[63:32]` | RO | core | time, ns |
| STATUS | 0 | `gcl_running` | RO | core | 1 = the gate control list runs |
| STATUS | 3:1 | `gcl_entry` | RO | core | current entry |
| STATUS | 7:4 | `gate_state` | RO | core | gate state per class (all open while the list does not run) |
| STATUS | 8 | `tx_busy` | RO | core | a frame occupies the line |
| CREDIT0 | 31:0 | `cbs_credit[31:0]` | RO | core | credits of classes 0..3 |
| CREDIT1 | 31:0 | `cbs_credit[63:32]` | RO | core | credits of classes 0..3 |
| CREDIT2 | 15:0 | `cbs_credit[79:64]` | RO | core | credits of classes 0..3 |

### Interrupts (IRQ_STATUS, IRQ_ENABLE)

A bit is set while its source is active, stays set until written with 1, and a set in the same clock as the clear wins.

| Bit | Name | Set when |
|---|---|---|
| 0 | CYCLE | a gate control list cycle started |
| 1 | TX | a frame was selected for transmission |

### Streams

* **GCL_WR** feeds `gcl_wivl`, `gcl_wgates`, `gcl_waddr`; writing GCL_WR pulses `gcl_we` for one clock.
* **TIME_SET** feeds `time_set_ns`; writing TIME_SET1 pulses `time_set` for one clock.
* **TIME_ADJ** feeds `time_adj_ns`; writing TIME_ADJ pulses `time_adj` for one clock.

## Programming sequence

1. Release PRESETN. Read ID (0x000) and check it is 0x54530200.
2. Write 0x3 to IRQ_STATUS (0x004) to clear any stale bits.
3. Configure the core: write CFG0 (0x014), CFG1 (0x018), GCL_BASE0 (0x01C), GCL_BASE1 (0x020), CBS_IDLE0 (0x024), CBS_IDLE1 (0x028). Reset values are in the register map; PSTRB selects the bytes written.
4. Write IRQ_ENABLE (0x008) with the interrupts to use (bit order as in the Interrupts table; 0x3 enables all).
5. To send on GCL_WR: write GCL_WR (0x02C). The last write pulses `gcl_we` for one clock; there is no back-pressure.
6. To send on TIME_SET: write TIME_SET0 (0x030) then TIME_SET1 (0x034). The last write pulses `time_set` for one clock; there is no back-pressure.
7. To send on TIME_ADJ: write TIME_ADJ (0x038). The last write pulses `time_adj` for one clock; there is no back-pressure.
8. Read TIME0 (0x03C), TIME1 (0x040) for the core's live `time_ns[31:0]`, `time_ns[63:32]`; it needs no clearing.
9. Read STATUS (0x044) for the core's live `gcl_running`, `gcl_entry`, `gate_state`, `tx_busy`; it needs no clearing.
10. Read CREDIT0 (0x048), CREDIT1 (0x04C), CREDIT2 (0x050) for the core's live `cbs_credit[31:0]`, `cbs_credit[63:32]`, `cbs_credit[79:64]`; it needs no clearing.
11. On `irq`: read IRQ_STATUS, handle every bit that is set and enabled, then write those bits back to IRQ_STATUS to clear them. A source that is still active sets its bit again.

## Running and verifying

All commands run from the repository root. Icarus Verilog 12 and Yosys 0.33 are enough for steps 1 to 3; step 4 also needs Verilator 5.052 and pyslang (see [README, Setup](../../README.md#setup)).

| Step | Command | Pass when | Output |
|---|---|---|---|
| 1. Core test | `make -f Makefile.Ethernet_AVB_TSN sim` | a `TEST PASSED` line, no `ERROR` | console |
| 2. Core synthesis | `make -f Makefile.Ethernet_AVB_TSN syn` | Yosys ends without `ERROR`; `stat` prints the cell count | `work/Ethernet_AVB_TSN_top.json` |
| 3. APB wrapper test + synthesis | `make -f Makefile.Ethernet_AVB_TSN apb` | `TEST PASSED: Ethernet_AVB_TSN_apb`, then Yosys without `ERROR` | console, `work/Ethernet_AVB_TSN_apb.json` |
| 4. Coverage (core, wrapper) | `bash scripts/cov/run_cov.sh Ethernet_AVB_TSN`<br>`bash scripts/cov/run_cov.sh Ethernet_AVB_TSN_apb` | `RESULT: CLOSED` (all five metrics 100%) | `work/cov/Ethernet_AVB_TSN/score.json`, `work/cov/Ethernet_AVB_TSN_apb/score.json` |

Expected end of a step 4 run:

```
===== Ethernet_AVB_TSN =====
TEST: PASSED   SVA_FAILURES: 0
LINE ... TOGGLE ... FSM ... SVA ... FUNCTIONAL  (each n/n, 100.0%)
RESULT: CLOSED
```

**Core test** (`tb/Ethernet_AVB_TSN_tb.sv`): drives `Ethernet_AVB_TSN_top` through its own ports against a protocol peer or model and checks every result itself; any mismatch prints `ERROR`, and `TEST PASSED` is printed only when there were none.

**APB wrapper test** (`tb/Ethernet_AVB_TSN_apb_tb.sv`), in this order:

1. Reset values of every register, ID included.
2. Writes to read-only registers are ignored.
3. Each RW register: all ones, all zeros, then 16 random writes with every PSTRB byte-lane pattern, read back each time.
4. Unmapped and misaligned addresses, reads and writes: PSLVERR, read data 0, no side effect on other registers.
5. Back-to-back transfers with no idle cycle.
6. IP traffic through the registers only (`tb/apb/Ethernet_AVB_TSN_apb_func.svh`): the programming sequence above, every interrupt bit set, enabled and cleared, stream FULL/AVAIL/OVF cases (100% wrapper toggle coverage confirms each bit moved).
7. PRESETN asserted mid-run: `irq` and PRDATA go to 0, registers return to reset values.

**Checkers** (`tb/cov/Ethernet_AVB_TSN_sva.sv`, `tb/cov/Ethernet_AVB_TSN_apb_sva.sv`): SVA protocol and APB assertions plus covergroups, bound in by the coverage flow. An assertion failure prints `SVA_FAIL` and fails the run even when the test itself passed.

Whole portfolio: `bash scripts/ci_regression.sh` runs steps 1 to 3 for every IP (what CI runs), and `bash scripts/cov/run_all.sh 4` runs step 4 for every IP.

## Verification

Five-metric coverage with Verilator 5.052 (`scripts/cov/run_cov.sh`); see [COVERAGE_CLOSURE.md](../COVERAGE_CLOSURE.md) for the flow. Line and toggle count only the named RTL file.

| Scope | Test | Line | Toggle | FSM | SVA | Functional |
|---|---|---|---|---|---|---|
| core `rtl/Ethernet_AVB_TSN_top.sv` | pass | 61/61 | 2336/2336 | n/a | 11/11 | 89/89 |
| wrapper `rtl/Ethernet_AVB_TSN_apb.sv` | pass | 55/55 | 2140/2140 | n/a | 26/26 | 62/62 |
