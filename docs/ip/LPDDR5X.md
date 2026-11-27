# LPDDR5X memory controller: DVFS mobile controller (bank = {haddr[8] channel, haddr[10:9]}, row = haddr[31:18], storage = 256 columns per channel), per-bank refresh, FSP-OP mailbox (WR to column 0xF1: FSP0 CL 22 / FSP1 CL 14); commands leave as framed beats on the 7-bit CA bus; line commands (RDL / WRL: BL8 with dqs, WCK through line writes) and one MR set per FSP

Protocol IP `LPDDR5X`, version 3.0. Apache-2.0.

| Item | Value |
|---|---|
| Core | `LPDDR5X_top` (`rtl/LPDDR5X_top.sv`) |
| Register interface | APB4 slave `LPDDR5X_apb`, 32-bit data, 12-bit byte address, zero wait states |
| Clock, reset | PCLK (rising edge), PRESETN (active low, asynchronous) |
| ID register | 0x6D120300 (code 0x6D12, version 3.0) |
| Registers | 13 words, 0x000 to 0x030 |
| Interrupts | 3 sources into one level-high `irq` |
| Data streams | CMD (to the core) |
| Protocol pins | 12 pass-through |

## Overview

LPDDR5X -- INDEPENDENT design IP #9/20. Architecture thesis: DVFS-era mobile controller. Two frequency-set-point latency files (FSP0: CL=22 / FSP1: CL=14); a write to the "FSP-OP" mailbox column (0xF1) switches the active file for all subsequent transactions (mid-flight bursts keep their latched latency). The mailbox write is a controller register write: no DRAM traffic, array and page state untouched. 8 banks, per-bank refresh rotation; commands reach the pins as framed beats on the 7-bit CA bus. Distinct from LPDDR4 (single frequency word) and LPDDR5 (ranks, no FSP). Self-contained; contract identical. The core holds no data: write words leave on dq, and the read word is taken from dq CL clocks after the RD command (the DRAM drives it). On top of the word commands: * line commands: hcmd 5 RDL / 6 WRL move one 128-bit line (8 columns {haddr[7:3], k}) in one BL8 burst (CA beat 0 bit 0 = 1 on the RD / WR frame; 0 for a word); a WRL takes its 8 data beats on hwdata in the 8 hvalid clocks after the command and drives them on dq CWL clocks after the WR with dqs toggling every beat; an RDL takes the 8 beats the DRAM drives from CL clocks after the RD, passes each to hrdata in its clock, pulses hdone with the last and holds the line on rdline * two mode-register sets, one per FSP (hcmd 7: haddr[3] = 0 MRW of hwdata[7:0] to MR haddr[2:0] of the active set, 1 MRR into hrdata[7:0] with an hdone pulse): CL = 10 + MR0[3:0], CWL = 5 + MR1[3:0] of the active set, used by every RD / WR. Reset: FSP0 CL 22, FSP1 CL 14, CWL 11 in both. MR0 bit 7 self-clears. The MR sets are controller-side: the DRAM's own mode registers are set to match outside this model. The FSP-OP mailbox (WR to column 0xF1) switches the set, and with it CL / CWL * WCK: wck_t / wck_c run (wck_t toggles every clock, starting low) from the clock after the WR of a line through its last data beat, and rest wck_t = 1 otherwise

ck_t, ck_c, cke, ca, cs_n, wck_t, wck_c, dq and dqs are the DRAM pins and trace_valid, trace_cmd and trace_addr the command trace (one clock before each command on the pins); they pass through unchanged.
Address map and behaviour of the core: DVFS mobile controller (bank = {haddr[8] channel, haddr[10:9]}, row = haddr[31:18], storage = 256 columns per channel), per-bank refresh, FSP-OP mailbox (WR to column 0xF1: FSP0 CL 22 / FSP1 CL 14); commands leave as framed beats on the 7-bit CA bus.
A line is the 8 columns {haddr[7:3], k}. MRW / MRR address the MR set of the active FSP (the FSP-OP mailbox switches it): CL = 10 + MR0[3:0], CWL = 5 + MR1[3:0]; reset FSP0 CL 22, FSP1 CL 14, CWL 11.
The core's own verification (pin-level checker, 100% coverage) is tb/cov/LPDDR5X_sva.sv with tb/LPDDR5X_tb.sv; this wrapper test drives the core only through the registers.

## Files

| File | Content |
|---|---|
| `rtl/LPDDR5X_top.sv` | protocol core |
| `rtl/LPDDR5X_apb.sv` | APB4 register wrapper (generated) |
| `tb/LPDDR5X_tb.sv` | core testbench |
| `tb/LPDDR5X_apb_tb.sv`, `tb/apb/LPDDR5X_apb_func.svh` | wrapper testbench (generated part + IP-specific part) |
| `tb/cov/LPDDR5X_sva.sv`, `tb/cov/LPDDR5X_apb_sva.sv` | coverage checkers (core, wrapper) |
| `scripts/apb/specs/LPDDR5X.json` | register spec the wrapper, TB, checker and this page are generated from |

How to run the tests and the coverage flow: see [Running and verifying](#running-and-verifying).

## Parameters

`LPDDR5X_apb` has the core's parameters and passes them to `LPDDR5X_top` unchanged.

| Parameter | Type | Default |
|---|---|---|
| `NCH` | int | `2` |

## Wrapper pins

Pins of `LPDDR5X_apb`. Widths of the pass-through pins are at the default parameters.

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
| `ck_t` | output | 1 | protocol pin, core port `ck_t` |
| `ck_c` | output | 1 | protocol pin, core port `ck_c` |
| `ca` | output | 7 | protocol pin, core port `ca` |
| `cs_n` | output | 1 | protocol pin, core port `cs_n` |
| `wck_t` | output | 1 | protocol pin, core port `wck_t` |
| `wck_c` | output | 1 | protocol pin, core port `wck_c` |
| `dq` | inout | 32 | protocol pin, core port `dq` |
| `dqs` | inout | 2 | protocol pin, core port `dqs` |
| `cke` | output | 1 | protocol pin, core port `cke` |
| `trace_valid` | output | 1 | protocol pin, core port `trace_valid` |
| `trace_cmd` | output | 3 | protocol pin, core port `trace_cmd` |
| `trace_addr` | output | 32 | protocol pin, core port `trace_addr` |

## Core ports

| Port | Dir | Width | In the APB wrapper |
|---|---|---|---|
| `clk` | input | 1 | PCLK |
| `rst_n` | input | 1 | PRESETN |
| `hvalid` | input | 1 | CMD commit / FLAGS |
| `hready` | output | 1 | CMD handshake |
| `hcmd` | input | 3 | CMD0[2:0] |
| `haddr` | input | 32 | CMD1[31:0] |
| `hwdata` | input | 16 | CMD2[15:0] |
| `hrdata` | output | 16 | RDATA[15:0] |
| `rdline` | output | 128 | RLINE0[31:0], RLINE1[31:0], RLINE2[31:0], RLINE3[31:0] |
| `hdone` | output | 1 | IRQ_STATUS.DONE |
| `ck_t` | output | 1 | pin (pass-through) |
| `ck_c` | output | 1 | pin (pass-through) |
| `ca` | output | 7 | pin (pass-through) |
| `cs_n` | output | 1 | pin (pass-through) |
| `wck_t` | output | 1 | pin (pass-through) |
| `wck_c` | output | 1 | pin (pass-through) |
| `dq` | inout | 32 | pin (pass-through) |
| `dqs` | inout | 2 | pin (pass-through) |
| `cke` | output | 1 | pin (pass-through) |
| `trace_valid` | output | 1 | pin (pass-through) |
| `trace_cmd` | output | 3 | pin (pass-through) |
| `trace_addr` | output | 32 | pin (pass-through) |

## APB wrapper

`LPDDR5X_apb` is an APB4 slave (AMBA APB protocol v2.0): zero wait states, 32-bit data, 12-bit byte address, PSTRB byte lanes on every writable register, PSLVERR on an unmapped or misaligned address (reads then return 0, writes are dropped). Writes to read-only registers are ignored without an error. The core runs on PCLK and PRESETN. `irq` is level-high: `|(IRQ_STATUS & IRQ_ENABLE)`.

Pass-through pins: `ck_t`, `ck_c`, `ca`, `cs_n`, `wck_t`, `wck_c`, `dq`, `dqs`, `cke`, `trace_valid`, `trace_cmd`, `trace_addr`.

### Register map

| Offset | Name | Access | Reset | Description |
|---|---|---|---|---|
| 0x000 | ID | RO | 0x6D120300 | IP identification: code, major and minor version |
| 0x004 | IRQ_STATUS | W1C | 0x00000000 | Sticky interrupt bits, write 1 to clear |
| 0x008 | IRQ_ENABLE | RW | 0x00000000 | Interrupt enables; irq = \|(IRQ_STATUS & IRQ_ENABLE) |
| 0x00C | FLAGS | RO | 0x00000000 | Stream holding-register state |
| 0x010 | SCRATCH | RW | 0x00000000 | Scratch register, no effect on the core |
| 0x014 | CMD0 | RW | 0x00000000 | Host command beat; writing CMD2 sends it: a command (the core takes it when it is idle and no refresh is due), or one of the 8 data beats that follow a WRL |
| 0x018 | CMD1 | RW | 0x00000000 | Host command beat; writing CMD2 sends it: a command (the core takes it when it is idle and no refresh is due), or one of the 8 data beats that follow a WRL |
| 0x01C | CMD2 | RW | 0x00000000 | Host command beat; writing CMD2 sends it: a command (the core takes it when it is idle and no refresh is due), or one of the 8 data beats that follow a WRL |
| 0x020 | RDATA | RO | core | Read data |
| 0x024 | RLINE0 | RO | core | Line of the last RDL (RLINE0 = bits 31:0) |
| 0x028 | RLINE1 | RO | core | Line of the last RDL (RLINE0 = bits 31:0) |
| 0x02C | RLINE2 | RO | core | Line of the last RDL (RLINE0 = bits 31:0) |
| 0x030 | RLINE3 | RO | core | Line of the last RDL (RLINE0 = bits 31:0) |

Unlisted bits read 0 and ignore writes. Reset "core": the register reads the core's outputs directly, so after reset it shows the core's own reset state. WO (pulse) registers read 0. Offsets from 0x034 up to 0xFFC are unmapped (PSLVERR).

### Fields

| Register | Bits | Field | Access | Reset | Description |
|---|---|---|---|---|---|
| ID | 31:16 | CODE | RO | 0x6D12 | IP code |
| ID | 15:8 | MAJOR | RO | 0x03 | major version |
| ID | 7:0 | MINOR | RO | 0x00 | minor version |
| IRQ_STATUS | 2:0 | one bit per interrupt | W1C | 0x0 | see Interrupts |
| IRQ_ENABLE | 2:0 | one bit per interrupt | RW | 0x0 | 1 enables the IRQ_STATUS bit onto `irq` |
| FLAGS | 0 | one bit per stream flag | RO | 0x0 | see FLAGS |
| SCRATCH | 31:0 | SCRATCH | RW | 0x00000000 | free for software |
| CMD0 | 2:0 | `hcmd` | RW | 0x0 | 1 ACT, 2 RD, 3 WR, 4 PRE, 5 RDL, 6 WRL (then 8 data beats), 7 MR access; 0 is a no-op; ignored on a data beat |
| CMD1 | 31:0 | `haddr` | RW | 0x0 | host address (bank, row and column fields below); MR access: [3] 1 MRR / 0 MRW, [2:0] MR index |
| CMD2 | 15:0 | `hwdata` | RW | 0x0 | word to write (WR), MRW value (bits 7:0), or a WRL data beat (beat 0 = column {haddr[7:3], 0}) |
| RDATA | 15:0 | `hrdata` | RO | core | word of the last RD (or word 7 of an RDL, {8'h0, MR} of an MRR), valid once DONE is set |
| RLINE0 | 31:0 | `rdline[31:0]` | RO | core | the 8 words of the last RDL (word k = column {haddr[7:3], k} in bits 16k+15:16k), held until the next RDL |
| RLINE1 | 31:0 | `rdline[63:32]` | RO | core | the 8 words of the last RDL (word k = column {haddr[7:3], k} in bits 16k+15:16k), held until the next RDL |
| RLINE2 | 31:0 | `rdline[95:64]` | RO | core | the 8 words of the last RDL (word k = column {haddr[7:3], k} in bits 16k+15:16k), held until the next RDL |
| RLINE3 | 31:0 | `rdline[127:96]` | RO | core | the 8 words of the last RDL (word k = column {haddr[7:3], k} in bits 16k+15:16k), held until the next RDL |

### Interrupts (IRQ_STATUS, IRQ_ENABLE)

A bit is set while its source is active, stays set until written with 1, and a set in the same clock as the clear wins.

| Bit | Name | Set when |
|---|---|---|
| 0 | DONE | a RD, RDL or MRR finished; RDATA (and RLINE for an RDL) holds its data |
| 1 | CMD_DONE | CMD beat accepted by the core |
| 2 | CMD_OVF | write to CMD while full (dropped) |

### FLAGS

| Bit | Name | Meaning |
|---|---|---|
| 0 | CMD_FULL | CMD holds a beat the core has not taken |

### Streams

* **CMD** feeds `hcmd`, `haddr`, `hwdata`/`hvalid`. Writing CMD2 commits the beat: FLAGS.CMD_FULL is set and `hvalid` stays high until the core's `hready`; then CMD_DONE is set. A write while full is dropped and sets CMD_OVF.

## Programming sequence

1. Release PRESETN. Read ID (0x000) and check it is 0x6D120300.
2. Write 0x7 to IRQ_STATUS (0x004) to clear any stale bits.
3. Write IRQ_ENABLE (0x008) with the interrupts to use (bit order as in the Interrupts table; 0x7 enables all).
4. To send on CMD: wait until FLAGS.CMD_FULL (bit 0) is 0, or for IRQ CMD_DONE, then write CMD0 (0x014) then CMD1 (0x018) then CMD2 (0x01C). The last write commits the beat. CMD_OVF means a write came while the register was full and was dropped.
5. Read RDATA (0x020) for the core's live `hrdata`; it needs no clearing.
6. Read RLINE0 (0x024), RLINE1 (0x028), RLINE2 (0x02C), RLINE3 (0x030) for the core's live `rdline[31:0]`, `rdline[63:32]`, `rdline[95:64]`, `rdline[127:96]`; it needs no clearing.
7. On `irq`: read IRQ_STATUS, handle every bit that is set and enabled, then write those bits back to IRQ_STATUS to clear them. A source that is still active sets its bit again.

## Running and verifying

All commands run from the repository root. Icarus Verilog 12 and Yosys 0.33 are enough for steps 1 to 3; step 4 also needs Verilator 5.052 and pyslang (see [README, Setup](../../README.md#setup)).

| Step | Command | Pass when | Output |
|---|---|---|---|
| 1. Core test | `make -f Makefile.LPDDR5X sim` | a `TEST PASSED` line, no `ERROR` | console |
| 2. Core synthesis | `make -f Makefile.LPDDR5X syn` | Yosys ends without `ERROR`; `stat` prints the cell count | `work/LPDDR5X_top.json` |
| 3. APB wrapper test + synthesis | `make -f Makefile.LPDDR5X apb` | `TEST PASSED: LPDDR5X_apb`, then Yosys without `ERROR` | console, `work/LPDDR5X_apb.json` |
| 4. Coverage (core, wrapper) | `bash scripts/cov/run_cov.sh LPDDR5X`<br>`bash scripts/cov/run_cov.sh LPDDR5X_apb` | `RESULT: CLOSED` (all five metrics 100%) | `work/cov/LPDDR5X/score.json`, `work/cov/LPDDR5X_apb/score.json` |

Expected end of a step 4 run:

```
===== LPDDR5X =====
TEST: PASSED   SVA_FAILURES: 0
LINE ... TOGGLE ... FSM ... SVA ... FUNCTIONAL  (each n/n, 100.0%)
RESULT: CLOSED
```

**Core test** (`tb/LPDDR5X_tb.sv`): drives `LPDDR5X_top` through its own ports against a protocol peer or model and checks every result itself; any mismatch prints `ERROR`, and `TEST PASSED` is printed only when there were none.

**APB wrapper test** (`tb/LPDDR5X_apb_tb.sv`), in this order:

1. Reset values of every register, ID included.
2. Writes to read-only registers are ignored.
3. Each RW register: all ones, all zeros, then 16 random writes with every PSTRB byte-lane pattern, read back each time.
4. Unmapped and misaligned addresses, reads and writes: PSLVERR, read data 0, no side effect on other registers.
5. Back-to-back transfers with no idle cycle.
6. IP traffic through the registers only (`tb/apb/LPDDR5X_apb_func.svh`): the programming sequence above, every interrupt bit set, enabled and cleared, stream FULL/AVAIL/OVF cases (100% wrapper toggle coverage confirms each bit moved).
7. PRESETN asserted mid-run: `irq` and PRDATA go to 0, registers return to reset values.

**Checkers** (`tb/cov/LPDDR5X_sva.sv`, `tb/cov/LPDDR5X_apb_sva.sv`): SVA protocol and APB assertions plus covergroups, bound in by the coverage flow. An assertion failure prints `SVA_FAIL` and fails the run even when the test itself passed.

Whole portfolio: `bash scripts/ci_regression.sh` runs steps 1 to 3 for every IP (what CI runs), and `bash scripts/cov/run_all.sh 4` runs step 4 for every IP.

## Verification

Five-metric coverage with Verilator 5.052 (`scripts/cov/run_cov.sh`); see [COVERAGE_CLOSURE.md](../COVERAGE_CLOSURE.md) for the flow. Line and toggle count only the named RTL file.

| Scope | Test | Line | Toggle | FSM | SVA | Functional |
|---|---|---|---|---|---|---|
| core `rtl/LPDDR5X_top.sv` | pass | 160/160 (+3 excl.) | 2234/2234 (+144 excl.) | 36/36 | 37/37 | 88/88 |
| wrapper `rtl/LPDDR5X_apb.sv` | pass | 37/37 | 1086/1086 (+2 excl.) | n/a | 11/11 | 50/50 |

## Performance

Measured, not estimated: `bash scripts/perf/run_perf.sh LPDDR5X` runs the core's own testbench with `+define+MEM_PERF` (`tb/perf/mem_perf.svh`), which drives the host port as fast as `hready` allows and times every command at the core's ports, then synthesizes the core on the open SkyWater SKY130 library (`scripts/perf/sta_sky130.sh`). Raw data: [`docs/perf/LPDDR5X.json`](../perf/LPDDR5X.json). One host operation moves one 16-bit word (2 bytes); the host port peaks at 2 bytes per clock. Clock-based figures hold at any frequency; ns and MB/s are at the estimated Fmax below. Family comparison: [MEMORY_PERFORMANCE.md](../MEMORY_PERFORMANCE.md).

### Implementation (pre-layout estimate)

| Item | Value |
|---|---|
| Library | SKY130 `sky130_fd_sc_hd`, typical corner (tt, 25 C, 1.80 V) |
| Longest logic path | 3.10 ns |
| Estimated Fmax | 278 MHz (logic path + 0.50 ns flip-flop clock-to-Q and setup) |
| Area | 0.044 mm2 (44129 um2), 4195 cells, 895 flip-flops |
| Not counted | the in-model DRAM array, 0 bits (0 bytes): a real controller has the DRAM off chip |

No wire load, placement, clock skew or on-chip variation: these rank the designs and give the order of magnitude; they are not a timing sign-off.

### DRAM timing used (clocks)

| CWL | TBURST | TRCD | TRP | TRAS | TRC | TWR | TWTR | TRFC | TREFI |
|---|---|---|---|---|---|---|---|---|---|
| 11 | 8 | 14 | 14 | 34 | 46 | 14 | 8 | 140 | 1560 |

### Latency, unloaded

From the first clock the host presents the command to the clock `hrdata` is valid (read) or the core can take the next command (write). Min and max over 8 samples in different banks, away from refresh, with the bank's timers (tRAS, tRC) already run out. A write is complete once its WR command is on the pins; write recovery (tWR), the write-to-read turnaround (tWTR) and the burst spacing (tCCD = TBURST) are enforced on the commands that follow it.

| Command | Clocks | ns at Fmax |
|---|---|---|
| Read, page hit | 24 | 86 |
| Read, bank closed (ACT first) | 38 | 137 |
| Read, row conflict (PRE + ACT first) | 52 | 187 |
| Write, page hit | 3 | 11 |
| Write, bank closed | 17 | 61 |
| Write, row conflict | 31 | 112 |
| Read, page hit, requested as a refresh falls due (worst case seen) | 192 | 691 |

### Sustained throughput

2048 back-to-back commands per pattern, refreshes included. Host utilization = bytes per clock over the port's 2-byte peak.

| Pattern | Clocks / op | Bytes / clock | Host utilization | MB/s at Fmax |
|---|---|---|---|---|
| Sequential reads, one open row (page hits) | 25.39 | 0.079 | 3.9% | 22 |
| Sequential writes, one open row (page hits) | 8.09 | 0.247 | 12.4% | 69 |
| Alternating write / read, one open row | 26.37 | 0.076 | 3.8% | 21 |
| Reads interleaved over every bank, rows open | 27.49 | 0.073 | 3.6% | 20 |
| Reads alternating two rows of one bank (row conflicts) | 53.67 | 0.037 | 1.9% | 10 |
| Random reads (bank, row, column uniform) | 54.03 | 0.037 | 1.9% | 10 |
| Random writes | 35.99 | 0.056 | 2.8% | 15 |
| Random mix, 2 reads : 1 write | 47.46 | 0.042 | 2.1% | 12 |

### Refresh cost

With no host traffic for 12480 clocks, `hready` is low (the core cannot take a command) 1.03% of the time, in 8 windows of at most 16 clocks (58 ns).

### Limits of these figures

* One command in flight: the core finishes a command before it takes the next, so throughput is set by the per-command latency, not by the DRAM data bus. A production controller queues and reorders many commands and keeps the data bus busy.
* The host port is 16 bits wide; the figures are bytes through that port, not DRAM pin bandwidth. The core's line commands (RDL / WRL) are not measured here.
* Timing parameters are in controller clocks as listed above, not tied to a JEDEC speed bin.
