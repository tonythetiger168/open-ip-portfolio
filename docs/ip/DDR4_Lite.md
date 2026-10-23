# DDR4_Lite: DDR4-style line controller: 4 banks with open-row tracking, ACT / RD / WR / PRE / PREA / REF on DDR4 pins, tRCD / tRP / tRC / tRAS / tRRD / tWR / tWTR / tRFC / tREFI, BL8 x16 line bursts, MR file with CL / CWL, all-bank refresh

Protocol IP `DDR4_Lite`, version 2.0. Apache-2.0.

## Overview

DDR4_Lite_top -- educational DDR4-style controller with a real micro-architecture (the base of the *_Lite memory controllers). What makes this a *real* DDR controller model (vs the 144-line single-bank MEMCORE educational slice): * 4 independent banks with per-bank open-row tracking (open-page policy) * full JEDEC-style command set on the PHY pins: ACT / RD / WR / PRE (single & all-bank) / REF / MRS, DDR4 ACT_n encoding * timing-fenced scheduling: tRCD, tRP, tRC, tRAS, tRRD, tWR (WR burst end -> PRE), tWTR (WR burst end -> RD), tRFC, average-refresh interval tREFI (all in clk cycles); read data starts exactly CL clocks after the RD command, write data CWL clocks after the WR * BL8 x16 data path: front-end collects 8 AHB beats into a 128-bit line, one DRAM burst per transaction, dq/dqs pin-level bursts * refresh controller: tREFI countdown -> pending refresh, all-bank PRE + REF + tRFC, refresh-overrun sticky error * mode-register file MR0..MR7 (8-bit, JEDEC-style addressing; MR0 CL field and MR1 CWL field are functional and reset to the CL / CWL parameters; MRW/MRR front-end commands; MR0 bit 7 is a self-clearing DLL reset and always reads 0) * protocol-error sticky irq (bad command, out-of-range address, refresh overrun; overrun needs a tREFI shorter than one engine operation, so it is a misconfiguration alarm) Documented simplifications (an educational slice, not a production IP): * SDR-style dqs (one rising edge per beat; no true DDR strobes) * no DLL / read & write leveling / ZQ / DBI / ECC / bank groups / 2T command / gear-down / CA parity * refresh is served only when the command engine is idle * memory array lives inside the model (controller + DRAM array combined) * one command engine: a single transaction is in flight at a time Front-end (AHB-like, framework style): hcmd: 0 = NOP | 1 = READ line | 2 = WRITE line | 3 = MRW (haddr[2:0]=MR index, hwdata[7:0]=value) | 4 = MRR (hrdata[7:0]=value) | 5 = REFRESH haddr byte address: [8:7]=bank  [17:9]=row  [6:4]=line  [3:0]=byte-in-line (line = one BL8 x16 burst = 8 front-end beats).  haddr[31:18] must be 0. A command is taken when hvalid && hready. A WRITE then takes its 8 data beats on hwdata, one per clock with hvalid high (hready stays high). hready is low from a READ / WRITE / REFRESH until its hdone; MRW, MRR, NOP and rejected commands pulse hdone in the next clock. Read data is on hrdata in the 8 clocks that end with the hdone clock.


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

```
make -f Makefile.DDR4_Lite sim syn            # core test + synthesis (Icarus, Yosys)
make -f Makefile.DDR4_Lite apb                # wrapper test + synthesis
bash scripts/cov/run_cov.sh DDR4_Lite          # core coverage (Verilator)
bash scripts/cov/run_cov.sh DDR4_Lite_apb      # wrapper coverage
```

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
| 0x020 | RDATA | RO | 0x00000000 | MRR result |
| 0x024 | RLINE0 | RO | 0x00000000 | Line of the last READ (RLINE0 = bits 31:0) |
| 0x028 | RLINE1 | RO | 0x00000000 | Line of the last READ (RLINE0 = bits 31:0) |
| 0x02C | RLINE2 | RO | 0x00000000 | Line of the last READ (RLINE0 = bits 31:0) |
| 0x030 | RLINE3 | RO | 0x00000000 | Line of the last READ (RLINE0 = bits 31:0) |

### Fields

| Register | Bits | Field | Description |
|---|---|---|---|
| ID | 31:16 | CODE | 0x6D21 |
| ID | 15:8 | MAJOR | 2 |
| ID | 7:0 | MINOR | 0 |
| CMD0 | 2:0 | `hcmd` | command (see the notes); ignored on a data beat |
| CMD1 | 31:0 | `haddr` | host address (see the notes); ignored on a data beat |
| CMD2 | 15:0 | `hwdata` | MRW value (bits 7:0), or the data beat of a WRITE (beat 0 = line bits 15:0) |
| RDATA | 15:0 | `hrdata` | {8'h0, MR value} after an MRR (also carries read beats while a READ drains) |
| RLINE0 | 31:0 | `rdline[31:0]` | the 128-bit line of the last READ, held until the next READ completes |
| RLINE1 | 31:0 | `rdline[63:32]` | the 128-bit line of the last READ, held until the next READ completes |
| RLINE2 | 31:0 | `rdline[95:64]` | the 128-bit line of the last READ, held until the next READ completes |
| RLINE3 | 31:0 | `rdline[127:96]` | the 128-bit line of the last READ, held until the next READ completes |

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

## Verification

Five-metric coverage with Verilator 5.052 (`scripts/cov/run_cov.sh`); see [COVERAGE_CLOSURE.md](../COVERAGE_CLOSURE.md) for the flow. Line and toggle count only the named RTL file.

| Scope | Test | Line | Toggle | FSM | SVA | Functional |
|---|---|---|---|---|---|---|
| core `rtl/DDR4_Lite_top.sv` | pass | 161/161 (+3 excl.) | 2330/2330 (+58 excl.) | 43/43 | 31/31 | 26/26 |
| wrapper `rtl/DDR4_Lite_apb.sv` | pass | 37/37 | 1084/1084 (+54 excl.) | n/a | 11/11 | 54/54 |
