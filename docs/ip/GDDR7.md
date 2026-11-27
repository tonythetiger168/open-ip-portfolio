# GDDR7 memory controller: PAM3 graphics controller (banks = {haddr[8], haddr[10:9]}, row = haddr[31:18], storage = 256 columns per channel); the DRAM returns read data on dq as PAM3 symbols over two beats and the controller decodes them, with line commands (RDL / WRL: BL8 NRZ or BL6 PAM3), an MR file (CL / CWL / PAM3) and cs_n / act_n / ba pins

Protocol IP `GDDR7`, version 3.0. Apache-2.0.

| Item | Value |
|---|---|
| Core | `GDDR7_top` (`rtl/GDDR7_top.sv`) |
| Register interface | APB4 slave `GDDR7_apb`, 32-bit data, 12-bit byte address, zero wait states |
| Clock, reset | PCLK (rising edge), PRESETN (active low, asynchronous) |
| ID register | 0x6D080300 (code 0x6D08, version 3.0) |
| Registers | 13 words, 0x000 to 0x030 |
| Interrupts | 3 sources into one level-high `irq` |
| Data streams | CMD (to the core) |
| Protocol pins | 17 pass-through |

## Overview

GDDR7 -- INDEPENDENT design IP #14/20. Architecture thesis: PAM3 signaling. Read data returns from the DRAM on the channel's dq lanes as 12 ternary symbols, 3 per nibble (v = 9*t0 + 3*t1 + t2, so 16 of the 27 symbol triples are legal), over two beats: the clock before hdone carries nibbles 0-1, the hdone clock nibbles 2-3; the controller captures both beats and decodes them into hrdata. A symbol is a 2-bit level code on a pin pair (00 / 01 / 10 = levels 0 / 1 / 2; 11 never appears), on dq[11:0]; dq[15:12] stay Hi-Z. Writes stay NRZ on dq[ch*16 +: 16]. 4 banks per channel ({ch,haddr[10:9]}), all-bank refresh, CL=18. Word commands as DDR_top. The core holds no data: write words leave on dq, read words come back from the DRAM. On top of the word commands (as DDR4_top): * line commands: hcmd 5 RDL / 6 WRL move one 128-bit line (the 8 columns {haddr[7:3], k}) in one burst (addr[12] = 1 on the RD / WR). PAM2 (MR2[0] = 0): BL8 of 16-bit NRZ beats on the channel's dq. PAM3 (MR2[0] = 1): BL6, each of the channel's 16 dq pins carrying one ternary symbol per beat as the level code {dqx[p], dq[p]} (00 / 01 / 10): the line's 32 nibbles as 96 trits (nibble k = trits 3k..3k+2, v = 9*t0 + 3*t1 + t2), beat b = trits 16b..16b+15. A WRL takes its 8 data beats on hwdata in the 8 hvalid clocks after the command and drives the burst CWL clocks after the WR, dqs toggling every beat; an RDL takes the DRAM's burst from CL clocks after the RD: PAM2 passes each beat to hrdata in its clock and pulses hdone with the last, PAM3 decodes the line with the last beat (hrdata = word 7, hdone then); rdline holds the line * mode-register file MR0..MR7 (hcmd 7: haddr[3] = 0 MRW of hwdata[7:0], 1 MRR into hrdata[7:0] with an hdone pulse): CL = 5 + MR0[3:0], CWL = 5 + MR1[3:0], MR2[0] = PAM3 (reset 1: word reads in PAM3 as above; MR2[0] = 0 sends a read word NRZ in the second beat), pin pam3; MR0 bit 7 is a self-clearing DLL reset. Controller-side: the DRAM's own mode registers are set to match outside this model * command pins: cs_n (high = deselect), act_n (ACT: low, with ras_n / cas_n / we_n = 0), ba = bank entry {channel, bank}

ck_t, ck_c, cke, cs_n, act_n, ba, addr, ras_n, cas_n, we_n, dq, dqx and dqs are the DRAM pins, pam3 the line signaling mode (MR2[0]), and trace_valid, trace_cmd and trace_addr the command trace (one clock before each ACT / RD / WR on the pins); they pass through unchanged.
Address map and behaviour of the core: PAM3 graphics controller (banks = {haddr[8], haddr[10:9]}, row = haddr[31:18], storage = 256 columns per channel); the DRAM returns read data on dq as PAM3 symbols over two beats and the controller decodes them.
A line is the 8 columns {haddr[7:3], k}. CL = 5 + MR0[3:0], CWL = 5 + MR1[3:0], MR2[0] = PAM3 (reset 1).
The core's own verification (pin-level checker, 100% coverage) is tb/cov/GDDR7_sva.sv with tb/GDDR7_tb.sv; this wrapper test drives the core only through the registers.

## Files

| File | Content |
|---|---|
| `rtl/GDDR7_top.sv` | protocol core |
| `rtl/GDDR7_apb.sv` | APB4 register wrapper (generated) |
| `tb/GDDR7_tb.sv` | core testbench |
| `tb/GDDR7_apb_tb.sv`, `tb/apb/GDDR7_apb_func.svh` | wrapper testbench (generated part + IP-specific part) |
| `tb/cov/GDDR7_sva.sv`, `tb/cov/GDDR7_apb_sva.sv` | coverage checkers (core, wrapper) |
| `scripts/apb/specs/GDDR7.json` | register spec the wrapper, TB, checker and this page are generated from |

How to run the tests and the coverage flow: see [Running and verifying](#running-and-verifying).

## Parameters

`GDDR7_apb` has the core's parameters and passes them to `GDDR7_top` unchanged.

| Parameter | Type | Default |
|---|---|---|
| `NCH` | int | `2` |

## Wrapper pins

Pins of `GDDR7_apb`. Widths of the pass-through pins are at the default parameters.

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
| `pam3` | output | 1 | protocol pin, core port `pam3` |
| `ck_t` | output | 1 | protocol pin, core port `ck_t` |
| `ck_c` | output | 1 | protocol pin, core port `ck_c` |
| `addr` | output | 17 | protocol pin, core port `addr` |
| `cs_n` | output | 1 | protocol pin, core port `cs_n` |
| `act_n` | output | 1 | protocol pin, core port `act_n` |
| `ba` | output | 3 | protocol pin, core port `ba` |
| `ras_n` | output | 1 | protocol pin, core port `ras_n` |
| `cas_n` | output | 1 | protocol pin, core port `cas_n` |
| `we_n` | output | 1 | protocol pin, core port `we_n` |
| `dq` | inout | 32 | protocol pin, core port `dq` |
| `dqx` | inout | 32 | protocol pin, core port `dqx` |
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
| `pam3` | output | 1 | pin (pass-through) |
| `ck_t` | output | 1 | pin (pass-through) |
| `ck_c` | output | 1 | pin (pass-through) |
| `addr` | output | 17 | pin (pass-through) |
| `cs_n` | output | 1 | pin (pass-through) |
| `act_n` | output | 1 | pin (pass-through) |
| `ba` | output | 3 | pin (pass-through) |
| `ras_n` | output | 1 | pin (pass-through) |
| `cas_n` | output | 1 | pin (pass-through) |
| `we_n` | output | 1 | pin (pass-through) |
| `dq` | inout | 32 | pin (pass-through) |
| `dqx` | inout | 32 | pin (pass-through) |
| `dqs` | inout | 2 | pin (pass-through) |
| `cke` | output | 1 | pin (pass-through) |
| `trace_valid` | output | 1 | pin (pass-through) |
| `trace_cmd` | output | 3 | pin (pass-through) |
| `trace_addr` | output | 32 | pin (pass-through) |

## APB wrapper

`GDDR7_apb` is an APB4 slave (AMBA APB protocol v2.0): zero wait states, 32-bit data, 12-bit byte address, PSTRB byte lanes on every writable register, PSLVERR on an unmapped or misaligned address (reads then return 0, writes are dropped). Writes to read-only registers are ignored without an error. The core runs on PCLK and PRESETN. `irq` is level-high: `|(IRQ_STATUS & IRQ_ENABLE)`.

Pass-through pins: `pam3`, `ck_t`, `ck_c`, `addr`, `cs_n`, `act_n`, `ba`, `ras_n`, `cas_n`, `we_n`, `dq`, `dqx`, `dqs`, `cke`, `trace_valid`, `trace_cmd`, `trace_addr`.

### Register map

| Offset | Name | Access | Reset | Description |
|---|---|---|---|---|
| 0x000 | ID | RO | 0x6D080300 | IP identification: code, major and minor version |
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
| ID | 31:16 | CODE | RO | 0x6D08 | IP code |
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

1. Release PRESETN. Read ID (0x000) and check it is 0x6D080300.
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
| 1. Core test | `make -f Makefile.GDDR7 sim` | a `TEST PASSED` line, no `ERROR` | console |
| 2. Core synthesis | `make -f Makefile.GDDR7 syn` | Yosys ends without `ERROR`; `stat` prints the cell count | `work/GDDR7_top.json` |
| 3. APB wrapper test + synthesis | `make -f Makefile.GDDR7 apb` | `TEST PASSED: GDDR7_apb`, then Yosys without `ERROR` | console, `work/GDDR7_apb.json` |
| 4. Coverage (core, wrapper) | `bash scripts/cov/run_cov.sh GDDR7`<br>`bash scripts/cov/run_cov.sh GDDR7_apb` | `RESULT: CLOSED` (all five metrics 100%) | `work/cov/GDDR7/score.json`, `work/cov/GDDR7_apb/score.json` |

Expected end of a step 4 run:

```
===== GDDR7 =====
TEST: PASSED   SVA_FAILURES: 0
LINE ... TOGGLE ... FSM ... SVA ... FUNCTIONAL  (each n/n, 100.0%)
RESULT: CLOSED
```

**Core test** (`tb/GDDR7_tb.sv`): drives `GDDR7_top` through its own ports against a protocol peer or model and checks every result itself; any mismatch prints `ERROR`, and `TEST PASSED` is printed only when there were none.

**APB wrapper test** (`tb/GDDR7_apb_tb.sv`), in this order:

1. Reset values of every register, ID included.
2. Writes to read-only registers are ignored.
3. Each RW register: all ones, all zeros, then 16 random writes with every PSTRB byte-lane pattern, read back each time.
4. Unmapped and misaligned addresses, reads and writes: PSLVERR, read data 0, no side effect on other registers.
5. Back-to-back transfers with no idle cycle.
6. IP traffic through the registers only (`tb/apb/GDDR7_apb_func.svh`): the programming sequence above, every interrupt bit set, enabled and cleared, stream FULL/AVAIL/OVF cases (100% wrapper toggle coverage confirms each bit moved).
7. PRESETN asserted mid-run: `irq` and PRDATA go to 0, registers return to reset values.

**Checkers** (`tb/cov/GDDR7_sva.sv`, `tb/cov/GDDR7_apb_sva.sv`): SVA protocol and APB assertions plus covergroups, bound in by the coverage flow. An assertion failure prints `SVA_FAIL` and fails the run even when the test itself passed.

Whole portfolio: `bash scripts/ci_regression.sh` runs steps 1 to 3 for every IP (what CI runs), and `bash scripts/cov/run_all.sh 4` runs step 4 for every IP.

## Verification

Five-metric coverage with Verilator 5.052 (`scripts/cov/run_cov.sh`); see [COVERAGE_CLOSURE.md](../COVERAGE_CLOSURE.md) for the flow. Line and toggle count only the named RTL file.

| Scope | Test | Line | Toggle | FSM | SVA | Functional |
|---|---|---|---|---|---|---|
| core `rtl/GDDR7_top.sv` | pass | 168/168 (+3 excl.) | 3440/3440 (+236 excl.) | 37/37 | 38/38 | 98/98 |
| wrapper `rtl/GDDR7_apb.sv` | pass | 33/33 | 842/842 (+12 excl.) | n/a | 11/11 | 42/42 |

## Performance

Measured, not estimated: `bash scripts/perf/run_perf.sh GDDR7` runs the core's own testbench with `+define+MEM_PERF` (`tb/perf/mem_perf.svh`), which drives the host port as fast as `hready` allows and times every command at the core's ports, then synthesizes the core on the open SkyWater SKY130 library (`scripts/perf/sta_sky130.sh`). Raw data: [`docs/perf/GDDR7.json`](../perf/GDDR7.json). One host operation moves one 16-bit word (2 bytes); the host port peaks at 2 bytes per clock. Clock-based figures hold at any frequency; ns and MB/s are at the estimated Fmax below. Family comparison: [MEMORY_PERFORMANCE.md](../MEMORY_PERFORMANCE.md).

### Implementation (pre-layout estimate)

| Item | Value |
|---|---|
| Library | SKY130 `sky130_fd_sc_hd`, typical corner (tt, 25 C, 1.80 V) |
| Longest logic path | 3.12 ns |
| Estimated Fmax | 276 MHz (logic path + 0.50 ns flip-flop clock-to-Q and setup) |
| Area | 0.072 mm2 (71635 um2), 9655 cells, 457 flip-flops |
| Not counted | the in-model DRAM array, 8192 bits (1 KiB): a real controller has the DRAM off chip |

No wire load, placement, clock skew or on-chip variation: these rank the designs and give the order of magnitude; they are not a timing sign-off.

### DRAM timing used (clocks)

| CL | CWL | TBURST | TRCD | TRP | TRAS | TRC | TWR | TWTR | TRFC | TREFI |
|---|---|---|---|---|---|---|---|---|---|---|
| 18 | 7 | 2 | 15 | 15 | 32 | 46 | 15 | 7 | 150 | 3900 |

### Latency, unloaded

From the first clock the host presents the command to the clock `hrdata` is valid (read) or the core can take the next command (write). Min and max over 8 samples in different banks, away from refresh, with the bank's timers (tRAS, tRC) already run out. A write is complete once its WR command is on the pins; write recovery (tWR), the write-to-read turnaround (tWTR) and the burst spacing (tCCD = TBURST) are enforced on the commands that follow it.

| Command | Clocks | ns at Fmax |
|---|---|---|
| Read, page hit | 20 | 72 |
| Read, bank closed (ACT first) | 35 | 127 |
| Read, row conflict (PRE + ACT first) | 50 | 181 |
| Write, page hit | 3 | 11 |
| Write, bank closed | 18 | 65 |
| Write, row conflict | 33 | 120 |
| Read, page hit, requested as a refresh falls due (worst case seen) | 200 | 725 |

### Sustained throughput

2048 back-to-back commands per pattern, refreshes included. Host utilization = bytes per clock over the port's 2-byte peak.

| Pattern | Clocks / op | Bytes / clock | Host utilization | MB/s at Fmax |
|---|---|---|---|---|
| Sequential reads, one open row (page hits) | 21.97 | 0.091 | 4.6% | 25 |
| Sequential writes, one open row (page hits) | 3.20 | 0.626 | 31.3% | 173 |
| Alternating write / read, one open row | 19.37 | 0.103 | 5.2% | 28 |
| Reads interleaved over every bank, rows open | 22.67 | 0.088 | 4.4% | 24 |
| Reads alternating two rows of one bank (row conflicts) | 52.96 | 0.038 | 1.9% | 10 |
| Random reads (bank, row, column uniform) | 51.55 | 0.039 | 1.9% | 11 |
| Random writes | 36.45 | 0.055 | 2.7% | 15 |
| Random mix, 2 reads : 1 write | 46.17 | 0.043 | 2.2% | 12 |

### Refresh cost

With no host traffic for 31200 clocks, `hready` is low (the core cannot take a command) 4.23% of the time, in 8 windows of at most 165 clocks (598 ns).

### Limits of these figures

* One command in flight: the core finishes a command before it takes the next, so throughput is set by the per-command latency, not by the DRAM data bus. A production controller queues and reorders many commands and keeps the data bus busy.
* The host port is 16 bits wide; the figures are bytes through that port, not DRAM pin bandwidth.
* Timing parameters are in controller clocks as listed above, not tied to a JEDEC speed bin.
