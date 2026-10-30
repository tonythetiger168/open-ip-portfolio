# DDR4_Lite: DDR4-style line controller: 4 banks with open-row tracking, ACT / RD / WR / PRE / PREA / REF on DDR4 pins, tRCD / tRP / tRC / tRAS / tRRD / tWR / tWTR / tRFC / tREFI, BL8 x16 line bursts, MR file with CL / CWL, all-bank refresh

Protocol IP `DDR4_Lite`, version 2.0. Apache-2.0.

| Item | Value |
|---|---|
| Core | `DDR4_Lite_top` (`rtl/DDR4_Lite_top.sv`) |
| Register interface | APB4 slave `DDR4_Lite_apb`, 32-bit data, 12-bit byte address, zero wait states |
| Clock, reset | PCLK (rising edge), PRESETN (active low, asynchronous) |
| ID register | 0x6D210200 (code 0x6D21, version 2.0) |
| Registers | 13 words, 0x000 to 0x030 |
| Interrupts | 4 sources into one level-high `irq` |
| Data streams | CMD (to the core) |
| Protocol pins | 15 pass-through |

## Overview

DDR4_Lite_top -- educational DDR4-style controller with a real micro-architecture (the base of the *_Lite memory controllers). What makes this a *real* DDR controller model (vs the 144-line single-bank MEMCORE educational slice): * 4 independent banks with per-bank open-row tracking (open-page policy) * JEDEC-style command set on the PHY pins: ACT / RD / WR / PRE (single & all-bank) / REF, DDR4 ACT_n encoding (RAS_n / CAS_n / WE_n carry row bits A16..A14 = 0 during ACT; RD / WR drive A12 = BC_n = 1 so an on-the-fly MR0 setting still bursts BL8) * timing-fenced scheduling: tRCD, tRP, tRC, tRAS, tRRD, tWR (WR burst end -> PRE), tWTR (WR burst end -> RD), tRFC, average-refresh interval tREFI (all in clk cycles); read data starts exactly CL clocks after the RD command, write data CWL clocks after the WR * BL8 x16 data path: front-end collects 8 AHB beats into a 128-bit line, one DRAM burst per transaction, dq/dqs pin-level bursts * refresh controller: tREFI countdown -> pending refresh, all-bank PRE + REF + tRFC, refresh-overrun sticky error * mode-register file MR0..MR7 (8-bit, JEDEC-style addressing; MR0 CL field and MR1 CWL field are functional and reset to the CL / CWL parameters; MRW/MRR front-end commands; MR0 bit 7 is a self-clearing DLL reset and always reads 0) * protocol-error sticky irq (bad command, out-of-range address, refresh overrun; overrun needs a tREFI shorter than one engine operation, so it is a misconfiguration alarm) Documented simplifications (an educational slice, not a production IP): * SDR-style dqs (one rising edge per beat; no true DDR strobes) * no DLL / read & write leveling / ZQ / DBI / ECC / bank groups / 2T command / gear-down / CA parity * refresh is served only when the command engine is idle * memory array lives inside the model (controller + DRAM array combined) * one command engine: a single transaction is in flight at a time * the MR file is controller-side only: MRW changes the controller's CL / CWL at once and issues no MRS on the pins, so the device's mode registers must be set to match (MR0 / MR2 for CL / CWL) by initialization outside this model Front-end (AHB-like, framework style): hcmd: 0 = NOP | 1 = READ line | 2 = WRITE line | 3 = MRW (haddr[2:0]=MR index, hwdata[7:0]=value) | 4 = MRR (hrdata[7:0]=value) | 5 = REFRESH haddr byte address: [8:7]=bank  [17:9]=row  [6:4]=line  [3:0]=byte-in-line (line = one BL8 x16 burst = 8 front-end beats).  haddr[31:18] must be 0. A command is taken when hvalid && hready. A WRITE then takes its 8 data beats on hwdata, one per clock with hvalid high (hready stays high). hready is low from a READ / WRITE / REFRESH until its hdone; MRW, MRR, NOP and rejected commands pulse hdone in the next clock. Read data is on hrdata in the 8 clocks that end with the hdone clock.

haddr: [8:7] bank, [17:9] row, [6:4] line; [31:18] must be 0. hcmd 0 NOP, 1 READ line, 2 WRITE line (then 8 data beats), 3 MRW (haddr[2:0], hwdata[7:0]; MR0 bit 7 is a self-clearing DLL reset), 4 MRR, 5 REFRESH; 6 and 7 are rejected.
The DRAM pins (ck_t, ck_c, cke, cs_n, act_n, ras_n, cas_n, we_n, ba, addr, dq, dqs) and the command trace pass through unchanged.
The core's own verification (pin-level checker, 100% coverage) is tb/cov/DDR4_Lite_sva.sv with tb/DDR4_Lite_tb.sv; this wrapper test drives the core only through the registers.

## Files

| File | Content |
|---|---|
| `rtl/DDR4_Lite_top.sv` | protocol core |
| `rtl/DDR4_Lite_apb.sv` | APB4 register wrapper (generated) |
| `tb/DDR4_Lite_tb.sv` | core testbench |
| `tb/DDR4_Lite_apb_tb.sv`, `tb/apb/DDR4_Lite_apb_func.svh` | wrapper testbench (generated part + IP-specific part) |
| `tb/cov/DDR4_Lite_sva.sv`, `tb/cov/DDR4_Lite_apb_sva.sv` | coverage checkers (core, wrapper) |
| `scripts/apb/specs/DDR4_Lite.json` | register spec the wrapper, TB, checker and this page are generated from |

How to run the tests and the coverage flow: see [Running and verifying](#running-and-verifying).

## Parameters

`DDR4_Lite_apb` has the core's parameters and passes them to `DDR4_Lite_top` unchanged.

| Parameter | Type | Default |
|---|---|---|
| `T_RCD` | integer | `6` |
| `T_RP` | integer | `6` |
| `T_RC` | integer | `24` |
| `T_RAS` | integer | `16` |
| `T_RRD` | integer | `3` |
| `T_WR` | integer | `8` |
| `T_WTR` | integer | `4` |
| `T_RFC` | integer | `40` |
| `T_REFI` | integer | `3900` |
| `CL` | integer | `11` |
| `CWL` | integer | `8` |

## Wrapper pins

Pins of `DDR4_Lite_apb`. Widths of the pass-through pins are at the default parameters.

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
| `cke` | output | 1 | protocol pin, core port `cke` |
| `cs_n` | output | 1 | protocol pin, core port `cs_n` |
| `act_n` | output | 1 | protocol pin, core port `act_n` |
| `ras_n` | output | 1 | protocol pin, core port `ras_n` |
| `cas_n` | output | 1 | protocol pin, core port `cas_n` |
| `we_n` | output | 1 | protocol pin, core port `we_n` |
| `ba` | output | 2 | protocol pin, core port `ba` |
| `addr` | output | 14 | protocol pin, core port `addr` |
| `dq` | inout | 16 | protocol pin, core port `dq` |
| `dqs` | inout | 2 | protocol pin, core port `dqs` |
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
| `irq` | output | 1 | IRQ_STATUS.ERR |
| `ck_t` | output | 1 | pin (pass-through) |
| `ck_c` | output | 1 | pin (pass-through) |
| `cke` | output | 1 | pin (pass-through) |
| `cs_n` | output | 1 | pin (pass-through) |
| `act_n` | output | 1 | pin (pass-through) |
| `ras_n` | output | 1 | pin (pass-through) |
| `cas_n` | output | 1 | pin (pass-through) |
| `we_n` | output | 1 | pin (pass-through) |
| `ba` | output | 2 | pin (pass-through) |
| `addr` | output | 14 | pin (pass-through) |
| `dq` | inout | 16 | pin (pass-through) |
| `dqs` | inout | 2 | pin (pass-through) |
| `trace_valid` | output | 1 | pin (pass-through) |
| `trace_cmd` | output | 3 | pin (pass-through) |
| `trace_addr` | output | 32 | pin (pass-through) |

## APB wrapper

`DDR4_Lite_apb` is an APB4 slave (AMBA APB protocol v2.0): zero wait states, 32-bit data, 12-bit byte address, PSTRB byte lanes on every writable register, PSLVERR on an unmapped or misaligned address (reads then return 0, writes are dropped). Writes to read-only registers are ignored without an error. The core runs on PCLK and PRESETN. `irq` is level-high: `|(IRQ_STATUS & IRQ_ENABLE)`.

Pass-through pins: `ck_t`, `ck_c`, `cke`, `cs_n`, `act_n`, `ras_n`, `cas_n`, `we_n`, `ba`, `addr`, `dq`, `dqs`, `trace_valid`, `trace_cmd`, `trace_addr`.

### Register map

| Offset | Name | Access | Reset | Description |
|---|---|---|---|---|
| 0x000 | ID | RO | 0x6D210200 | IP identification: code, major and minor version |
| 0x004 | IRQ_STATUS | W1C | 0x00000000 | Sticky interrupt bits, write 1 to clear |
| 0x008 | IRQ_ENABLE | RW | 0x00000000 | Interrupt enables; irq = \|(IRQ_STATUS & IRQ_ENABLE) |
| 0x00C | FLAGS | RO | 0x00000000 | Stream holding-register state |
| 0x010 | SCRATCH | RW | 0x00000000 | Scratch register, no effect on the core |
| 0x014 | CMD0 | RW | 0x00000000 | Host command beat; writing CMD2 sends it: a command, or one of the 8 data beats that follow a WRITE |
| 0x018 | CMD1 | RW | 0x00000000 | Host command beat; writing CMD2 sends it: a command, or one of the 8 data beats that follow a WRITE |
| 0x01C | CMD2 | RW | 0x00000000 | Host command beat; writing CMD2 sends it: a command, or one of the 8 data beats that follow a WRITE |
| 0x020 | RDATA | RO | core | MRR result |
| 0x024 | RLINE0 | RO | core | Line of the last READ (RLINE0 = bits 31:0) |
| 0x028 | RLINE1 | RO | core | Line of the last READ (RLINE0 = bits 31:0) |
| 0x02C | RLINE2 | RO | core | Line of the last READ (RLINE0 = bits 31:0) |
| 0x030 | RLINE3 | RO | core | Line of the last READ (RLINE0 = bits 31:0) |

Unlisted bits read 0 and ignore writes. Reset "core": the register reads the core's outputs directly, so after reset it shows the core's own reset state. WO (pulse) registers read 0. Offsets from 0x034 up to 0xFFC are unmapped (PSLVERR).

### Fields

| Register | Bits | Field | Access | Reset | Description |
|---|---|---|---|---|---|
| ID | 31:16 | CODE | RO | 0x6D21 | IP code |
| ID | 15:8 | MAJOR | RO | 0x02 | major version |
| ID | 7:0 | MINOR | RO | 0x00 | minor version |
| IRQ_STATUS | 3:0 | one bit per interrupt | W1C | 0x0 | see Interrupts |
| IRQ_ENABLE | 3:0 | one bit per interrupt | RW | 0x0 | 1 enables the IRQ_STATUS bit onto `irq` |
| FLAGS | 0 | one bit per stream flag | RO | 0x0 | see FLAGS |
| SCRATCH | 31:0 | SCRATCH | RW | 0x00000000 | free for software |
| CMD0 | 2:0 | `hcmd` | RW | 0x0 | command (see the notes); ignored on a data beat |
| CMD1 | 31:0 | `haddr` | RW | 0x0 | host address (see the notes); ignored on a data beat |
| CMD2 | 15:0 | `hwdata` | RW | 0x0 | MRW value (bits 7:0), or the data beat of a WRITE (beat 0 = line bits 15:0) |
| RDATA | 15:0 | `hrdata` | RO | core | {8'h0, MR value} after an MRR (also carries read beats while a READ drains) |
| RLINE0 | 31:0 | `rdline[31:0]` | RO | core | the 128-bit line of the last READ, held until the next READ completes |
| RLINE1 | 31:0 | `rdline[63:32]` | RO | core | the 128-bit line of the last READ, held until the next READ completes |
| RLINE2 | 31:0 | `rdline[95:64]` | RO | core | the 128-bit line of the last READ, held until the next READ completes |
| RLINE3 | 31:0 | `rdline[127:96]` | RO | core | the 128-bit line of the last READ, held until the next READ completes |

### Interrupts (IRQ_STATUS, IRQ_ENABLE)

A bit is set while its source is active, stays set until written with 1, and a set in the same clock as the clear wins.

| Bit | Name | Set when |
|---|---|---|
| 0 | DONE | a command finished (READ: RLINE holds the line; MRR: RDATA holds the value) |
| 1 | ERR | a command was rejected (out-of-range address, illegal code) or a refresh overran; the core holds this until reset, so the bit cannot be cleared before then |
| 2 | CMD_DONE | CMD beat accepted by the core |
| 3 | CMD_OVF | write to CMD while full (dropped) |

### FLAGS

| Bit | Name | Meaning |
|---|---|---|
| 0 | CMD_FULL | CMD holds a beat the core has not taken |

### Streams

* **CMD** feeds `hcmd`, `haddr`, `hwdata`/`hvalid`. Writing CMD2 commits the beat: FLAGS.CMD_FULL is set and `hvalid` stays high until the core's `hready`; then CMD_DONE is set. A write while full is dropped and sets CMD_OVF.

## Programming sequence

1. Release PRESETN. Read ID (0x000) and check it is 0x6D210200.
2. Write 0xF to IRQ_STATUS (0x004) to clear any stale bits.
3. Write IRQ_ENABLE (0x008) with the interrupts to use (bit order as in the Interrupts table; 0xF enables all).
4. To send on CMD: wait until FLAGS.CMD_FULL (bit 0) is 0, or for IRQ CMD_DONE, then write CMD0 (0x014) then CMD1 (0x018) then CMD2 (0x01C). The last write commits the beat. CMD_OVF means a write came while the register was full and was dropped.
5. Read RDATA (0x020) for the core's live `hrdata`; it needs no clearing.
6. Read RLINE0 (0x024), RLINE1 (0x028), RLINE2 (0x02C), RLINE3 (0x030) for the core's live `rdline[31:0]`, `rdline[63:32]`, `rdline[95:64]`, `rdline[127:96]`; it needs no clearing.
7. On `irq`: read IRQ_STATUS, handle every bit that is set and enabled, then write those bits back to IRQ_STATUS to clear them. A source that is still active sets its bit again.

## Running and verifying

All commands run from the repository root. Icarus Verilog 12 and Yosys 0.33 are enough for steps 1 to 3; step 4 also needs Verilator 5.052 and pyslang (see [README, Setup](../../README.md#setup)).

| Step | Command | Pass when | Output |
|---|---|---|---|
| 1. Core test | `make -f Makefile.DDR4_Lite sim` | a `TEST PASSED` line, no `ERROR` | console |
| 2. Core synthesis | `make -f Makefile.DDR4_Lite syn` | Yosys ends without `ERROR`; `stat` prints the cell count | `work/DDR4_Lite_top.json` |
| 3. APB wrapper test + synthesis | `make -f Makefile.DDR4_Lite apb` | `TEST PASSED: DDR4_Lite_apb`, then Yosys without `ERROR` | console, `work/DDR4_Lite_apb.json` |
| 4. Coverage (core, wrapper) | `bash scripts/cov/run_cov.sh DDR4_Lite`<br>`bash scripts/cov/run_cov.sh DDR4_Lite_apb` | `RESULT: CLOSED` (all five metrics 100%) | `work/cov/DDR4_Lite/score.json`, `work/cov/DDR4_Lite_apb/score.json` |

Expected end of a step 4 run:

```
===== DDR4_Lite =====
TEST: PASSED   SVA_FAILURES: 0
LINE ... TOGGLE ... FSM ... SVA ... FUNCTIONAL  (each n/n, 100.0%)
RESULT: CLOSED
```

**Core test** (`tb/DDR4_Lite_tb.sv`): drives `DDR4_Lite_top` through its own ports against a protocol peer or model and checks every result itself; any mismatch prints `ERROR`, and `TEST PASSED` is printed only when there were none.

**APB wrapper test** (`tb/DDR4_Lite_apb_tb.sv`), in this order:

1. Reset values of every register, ID included.
2. Writes to read-only registers are ignored.
3. Each RW register: all ones, all zeros, then 16 random writes with every PSTRB byte-lane pattern, read back each time.
4. Unmapped and misaligned addresses, reads and writes: PSLVERR, read data 0, no side effect on other registers.
5. Back-to-back transfers with no idle cycle.
6. IP traffic through the registers only (`tb/apb/DDR4_Lite_apb_func.svh`): the programming sequence above, every interrupt bit set, enabled and cleared, stream FULL/AVAIL/OVF cases (100% wrapper toggle coverage confirms each bit moved).
7. PRESETN asserted mid-run: `irq` and PRDATA go to 0, registers return to reset values.

**Checkers** (`tb/cov/DDR4_Lite_sva.sv`, `tb/cov/DDR4_Lite_apb_sva.sv`): SVA protocol and APB assertions plus covergroups, bound in by the coverage flow. An assertion failure prints `SVA_FAIL` and fails the run even when the test itself passed.

Whole portfolio: `bash scripts/ci_regression.sh` runs steps 1 to 3 for every IP (what CI runs), and `bash scripts/cov/run_all.sh 4` runs step 4 for every IP.

## Verification

Five-metric coverage with Verilator 5.052 (`scripts/cov/run_cov.sh`); see [COVERAGE_CLOSURE.md](../COVERAGE_CLOSURE.md) for the flow. Line and toggle count only the named RTL file.

| Scope | Test | Line | Toggle | FSM | SVA | Functional |
|---|---|---|---|---|---|---|
| core `rtl/DDR4_Lite_top.sv` | pass | 161/161 (+3 excl.) | 2330/2330 (+58 excl.) | 43/43 | 31/31 | 98/98 |
| wrapper `rtl/DDR4_Lite_apb.sv` | pass | 37/37 | 1084/1084 (+54 excl.) | n/a | 11/11 | 54/54 |
