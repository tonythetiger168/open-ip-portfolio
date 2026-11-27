# HBM3E memory controller: sideband-ECC controller (256 page entries {channel haddr[10:8], pc/bank haddr[15:11]}, row = haddr[31:18], storage = 256 columns per channel, each word with 5 SEC check bits carried on ecc); the TB flips bits of stored codewords in its DRAM model and the reads must still return the written data; line commands (RDL / WRL: BL8 with dqs and per-beat ECC) and an MR file (CL / CWL)

Protocol IP `HBM3E`, version 3.0. Apache-2.0.

| Item | Value |
|---|---|
| Core | `HBM3E_top` (`rtl/HBM3E_top.sv`) |
| Register interface | APB4 slave `HBM3E_apb`, 32-bit data, 12-bit byte address, zero wait states |
| Clock, reset | PCLK (rising edge), PRESETN (active low, asynchronous) |
| ID register | 0x6D0C0300 (code 0x6D0C, version 3.0) |
| Registers | 13 words, 0x000 to 0x030 |
| Interrupts | 3 sources into one level-high `irq` |
| Data streams | CMD (to the core) |
| Protocol pins | 16 pass-through |

## Overview

HBM3E -- INDEPENDENT design IP #18/20. Architecture thesis: sideband SEC ECC. Every word is stored in the DRAM as a 21-bit SEC codeword (16 data + 5 Hamming check bits over positions 1..21, checks at 1,2,4,8,16): a write drives the data on dq and its 5 check bits on the channel's ecc pins; a read takes data and check bits back from dq / ecc and decodes + corrects a single-bit error (syndrome = XOR of set-bit positions; syndrome!=0 flips that position back). Read data is always corrected before hrdata; the stored word is not scrubbed. SEC only: a double-bit error is not detected and may be miscorrected. The core holds no data: the DRAM drives the read word CL clocks after the RD command. 256 page entries ({ch haddr[10:8], pc/bank haddr[15:11]}), per-entry refresh rotating over all 256. Contract identical to DDR_top (hrdata carries corrected data; the TB flips bits stored in its DRAM device through a backdoor and its scoreboard therefore proves the correction). On top of the word commands (as DDR4_top): * line commands: hcmd 5 RDL / 6 WRL move one 128-bit line (the 8 columns {haddr[7:3], k}) in one BL8 burst (addr[12] = 1 on the RD / WR), every beat a SEC codeword: 16 data bits on the channel's dq and its 5 check bits on ecc. A WRL takes its 8 data beats on hwdata in the 8 hvalid clocks after the command and drives them CWL clocks after the WR, dqs toggling every beat; an RDL takes the DRAM's 8 beats from CL clocks after the RD, corrects each and passes it to hrdata in its clock, pulses hdone with the last and holds the corrected line on rdline * mode-register file MR0..MR7 (hcmd 7: haddr[3] = 0 MRW of hwdata[7:0], 1 MRR into hrdata[7:0] with an hdone pulse): CL = 5 + MR0[3:0], CWL = 5 + MR1[3:0] (reset to the CL / CWL parameters); MR0 bit 7 is a self-clearing DLL reset. Controller-side: the DRAM's own mode registers are set to match outside this model * command pins: cs_n (high = deselect), act_n (ACT: low, with ras_n / cas_n / we_n = 0), ba = page entry {channel, pc/bank}

ck_t, ck_c, cke, cs_n, act_n, ba, addr, ras_n, cas_n, we_n, dq, ecc and dqs are the DRAM pins and trace_valid, trace_cmd and trace_addr the command trace (one clock before each command on the pins); they pass through unchanged.
Address map and behaviour of the core: sideband-ECC controller (256 page entries {channel haddr[10:8], pc/bank haddr[15:11]}, row = haddr[31:18], storage = 256 columns per channel, each word with 5 SEC check bits carried on ecc); the TB flips bits of stored codewords in its DRAM model and the reads must still return the written data.
A line is the 8 columns {haddr[7:3], k}. CL = 5 + MR0[3:0], CWL = 5 + MR1[3:0]; each line beat carries its own 5 SEC check bits on ecc and is corrected on the way in.
The core's own verification (pin-level checker, 100% coverage) is tb/cov/HBM3E_sva.sv with tb/HBM3E_tb.sv; this wrapper test drives the core only through the registers.

## Files

| File | Content |
|---|---|
| `rtl/HBM3E_top.sv` | protocol core |
| `rtl/HBM3E_apb.sv` | APB4 register wrapper (generated) |
| `tb/HBM3E_tb.sv` | core testbench |
| `tb/HBM3E_apb_tb.sv`, `tb/apb/HBM3E_apb_func.svh` | wrapper testbench (generated part + IP-specific part) |
| `tb/cov/HBM3E_sva.sv`, `tb/cov/HBM3E_apb_sva.sv` | coverage checkers (core, wrapper) |
| `scripts/apb/specs/HBM3E.json` | register spec the wrapper, TB, checker and this page are generated from |

How to run the tests and the coverage flow: see [Running and verifying](#running-and-verifying).

## Parameters

`HBM3E_apb` has the core's parameters and passes them to `HBM3E_top` unchanged.

| Parameter | Type | Default |
|---|---|---|
| `NCH` | int | `8` |

## Wrapper pins

Pins of `HBM3E_apb`. Widths of the pass-through pins are at the default parameters.

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
| `addr` | output | 17 | protocol pin, core port `addr` |
| `cs_n` | output | 1 | protocol pin, core port `cs_n` |
| `act_n` | output | 1 | protocol pin, core port `act_n` |
| `ba` | output | 8 | protocol pin, core port `ba` |
| `ras_n` | output | 1 | protocol pin, core port `ras_n` |
| `cas_n` | output | 1 | protocol pin, core port `cas_n` |
| `we_n` | output | 1 | protocol pin, core port `we_n` |
| `dq` | inout | 128 | protocol pin, core port `dq` |
| `ecc` | inout | 40 | protocol pin, core port `ecc` |
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
| `addr` | output | 17 | pin (pass-through) |
| `cs_n` | output | 1 | pin (pass-through) |
| `act_n` | output | 1 | pin (pass-through) |
| `ba` | output | 8 | pin (pass-through) |
| `ras_n` | output | 1 | pin (pass-through) |
| `cas_n` | output | 1 | pin (pass-through) |
| `we_n` | output | 1 | pin (pass-through) |
| `dq` | inout | 128 | pin (pass-through) |
| `ecc` | inout | 40 | pin (pass-through) |
| `dqs` | inout | 2 | pin (pass-through) |
| `cke` | output | 1 | pin (pass-through) |
| `trace_valid` | output | 1 | pin (pass-through) |
| `trace_cmd` | output | 3 | pin (pass-through) |
| `trace_addr` | output | 32 | pin (pass-through) |

## APB wrapper

`HBM3E_apb` is an APB4 slave (AMBA APB protocol v2.0): zero wait states, 32-bit data, 12-bit byte address, PSTRB byte lanes on every writable register, PSLVERR on an unmapped or misaligned address (reads then return 0, writes are dropped). Writes to read-only registers are ignored without an error. The core runs on PCLK and PRESETN. `irq` is level-high: `|(IRQ_STATUS & IRQ_ENABLE)`.

Pass-through pins: `ck_t`, `ck_c`, `addr`, `cs_n`, `act_n`, `ba`, `ras_n`, `cas_n`, `we_n`, `dq`, `ecc`, `dqs`, `cke`, `trace_valid`, `trace_cmd`, `trace_addr`.

### Register map

| Offset | Name | Access | Reset | Description |
|---|---|---|---|---|
| 0x000 | ID | RO | 0x6D0C0300 | IP identification: code, major and minor version |
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
| ID | 31:16 | CODE | RO | 0x6D0C | IP code |
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

1. Release PRESETN. Read ID (0x000) and check it is 0x6D0C0300.
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
| 1. Core test | `make -f Makefile.HBM3E sim` | a `TEST PASSED` line, no `ERROR` | console |
| 2. Core synthesis | `make -f Makefile.HBM3E syn` | Yosys ends without `ERROR`; `stat` prints the cell count | `work/HBM3E_top.json` |
| 3. APB wrapper test + synthesis | `make -f Makefile.HBM3E apb` | `TEST PASSED: HBM3E_apb`, then Yosys without `ERROR` | console, `work/HBM3E_apb.json` |
| 4. Coverage (core, wrapper) | `bash scripts/cov/run_cov.sh HBM3E`<br>`bash scripts/cov/run_cov.sh HBM3E_apb` | `RESULT: CLOSED` (all five metrics 100%) | `work/cov/HBM3E/score.json`, `work/cov/HBM3E_apb/score.json` |

Expected end of a step 4 run:

```
===== HBM3E =====
TEST: PASSED   SVA_FAILURES: 0
LINE ... TOGGLE ... FSM ... SVA ... FUNCTIONAL  (each n/n, 100.0%)
RESULT: CLOSED
```

**Core test** (`tb/HBM3E_tb.sv`): drives `HBM3E_top` through its own ports against a protocol peer or model and checks every result itself; any mismatch prints `ERROR`, and `TEST PASSED` is printed only when there were none.

**APB wrapper test** (`tb/HBM3E_apb_tb.sv`), in this order:

1. Reset values of every register, ID included.
2. Writes to read-only registers are ignored.
3. Each RW register: all ones, all zeros, then 16 random writes with every PSTRB byte-lane pattern, read back each time.
4. Unmapped and misaligned addresses, reads and writes: PSLVERR, read data 0, no side effect on other registers.
5. Back-to-back transfers with no idle cycle.
6. IP traffic through the registers only (`tb/apb/HBM3E_apb_func.svh`): the programming sequence above, every interrupt bit set, enabled and cleared, stream FULL/AVAIL/OVF cases (100% wrapper toggle coverage confirms each bit moved).
7. PRESETN asserted mid-run: `irq` and PRDATA go to 0, registers return to reset values.

**Checkers** (`tb/cov/HBM3E_sva.sv`, `tb/cov/HBM3E_apb_sva.sv`): SVA protocol and APB assertions plus covergroups, bound in by the coverage flow. An assertion failure prints `SVA_FAIL` and fails the run even when the test itself passed.

Whole portfolio: `bash scripts/ci_regression.sh` runs steps 1 to 3 for every IP (what CI runs), and `bash scripts/cov/run_all.sh 4` runs step 4 for every IP.

## Verification

Five-metric coverage with Verilator 5.052 (`scripts/cov/run_cov.sh`); see [COVERAGE_CLOSURE.md](../COVERAGE_CLOSURE.md) for the flow. Line and toggle count only the named RTL file.

| Scope | Test | Line | Toggle | FSM | SVA | Functional |
|---|---|---|---|---|---|---|
| core `rtl/HBM3E_top.sv` | pass | 159/159 (+3 excl.) | 3476/3476 (+34 excl.) | 36/36 | 35/35 | 81/81 |
| wrapper `rtl/HBM3E_apb.sv` | pass | 37/37 | 1398/1398 (+8 excl.) | n/a | 11/11 | 50/50 |

## Performance

Measured, not estimated: `bash scripts/perf/run_perf.sh HBM3E` runs the core's own testbench with `+define+MEM_PERF` (`tb/perf/mem_perf.svh`), which drives the host port as fast as `hready` allows and times every command at the core's ports, then synthesizes the core on the open SkyWater SKY130 library (`scripts/perf/sta_sky130.sh`). Raw data: [`docs/perf/HBM3E.json`](../perf/HBM3E.json). One host operation moves one 16-bit word (2 bytes); the host port peaks at 2 bytes per clock. Clock-based figures hold at any frequency; ns and MB/s are at the estimated Fmax below. Family comparison: [MEMORY_PERFORMANCE.md](../MEMORY_PERFORMANCE.md).

### Implementation (pre-layout estimate)

| Item | Value |
|---|---|
| Library | SKY130 `sky130_fd_sc_hd`, typical corner (tt, 25 C, 1.80 V) |
| Longest logic path | 5.73 ns |
| Estimated Fmax | 160 MHz (logic path + 0.50 ns flip-flop clock-to-Q and setup) |
| Area | 0.608 mm2 (607581 um2), 69851 cells, 11245 flip-flops |
| Not counted | the in-model DRAM array, 0 bits (0 bytes): a real controller has the DRAM off chip |

No wire load, placement, clock skew or on-chip variation: these rank the designs and give the order of magnitude; they are not a timing sign-off.

### DRAM timing used (clocks)

| CL | CWL | TBURST | TRCD | TRP | TRAS | TRC | TWR | TWTR | TRFC | TREFI |
|---|---|---|---|---|---|---|---|---|---|---|
| 12 | 10 | 4 | 10 | 10 | 22 | 34 | 10 | 5 | 130 | 1560 |

### Latency, unloaded

From the first clock the host presents the command to the clock `hrdata` is valid (read) or the core can take the next command (write). Min and max over 8 samples in different banks, away from refresh, with the bank's timers (tRAS, tRC) already run out. A write is complete once its WR command is on the pins; write recovery (tWR), the write-to-read turnaround (tWTR) and the burst spacing (tCCD = TBURST) are enforced on the commands that follow it.

| Command | Clocks | ns at Fmax |
|---|---|---|
| Read, page hit | 14 | 88 |
| Read, bank closed (ACT first) | 24 | 150 |
| Read, row conflict (PRE + ACT first) | 34 | 212 |
| Write, page hit | 3 | 19 |
| Write, bank closed | 13 | 81 |
| Write, row conflict | 23 | 144 |
| Read, page hit, requested as a refresh falls due (worst case seen) | 26 | 162 |

### Sustained throughput

2048 back-to-back commands per pattern, refreshes included. Host utilization = bytes per clock over the port's 2-byte peak.

| Pattern | Clocks / op | Bytes / clock | Host utilization | MB/s at Fmax |
|---|---|---|---|---|
| Sequential reads, one open row (page hits) | 15.03 | 0.133 | 6.7% | 21 |
| Sequential writes, one open row (page hits) | 4.00 | 0.499 | 25.0% | 80 |
| Alternating write / read, one open row | 17.03 | 0.117 | 5.9% | 19 |
| Reads interleaved over every bank, rows open | 15.22 | 0.131 | 6.6% | 21 |
| Reads alternating two rows of one bank (row conflicts) | 35.26 | 0.057 | 2.8% | 9 |
| Random reads (bank, row, column uniform) | 34.91 | 0.057 | 2.9% | 9 |
| Random writes | 23.13 | 0.086 | 4.3% | 14 |
| Random mix, 2 reads : 1 write | 30.94 | 0.065 | 3.2% | 10 |

### Refresh cost

With no host traffic for 12480 clocks, `hready` is low (the core cannot take a command) 0.77% of the time, in 8 windows of at most 12 clocks (75 ns).

### Limits of these figures

* One command in flight: the core finishes a command before it takes the next, so throughput is set by the per-command latency, not by the DRAM data bus. A production controller queues and reorders many commands and keeps the data bus busy.
* The host port is 16 bits wide; the figures are bytes through that port, not DRAM pin bandwidth. The core's line commands (RDL / WRL) are not measured here.
* Timing parameters are in controller clocks as listed above, not tied to a JEDEC speed bin.
