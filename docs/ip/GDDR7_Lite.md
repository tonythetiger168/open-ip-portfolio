# GDDR7_Lite: GDDR7-style line controller: 2 channels x 4 banks, PAM3 symbol bus (BL6 of 16 ternary lanes) or PAM2 (BL8), the line read back the same in either mode, DDR4_Lite timing and refresh

Protocol IP `GDDR7_Lite`, version 2.0. Apache-2.0.

| Item | Value |
|---|---|
| Core | `GDDR7_Lite_top` (`rtl/GDDR7_Lite_top.sv`) |
| Register interface | APB4 slave `GDDR7_Lite_apb`, 32-bit data, 12-bit byte address, zero wait states |
| Clock, reset | PCLK (rising edge), PRESETN (active low, asynchronous) |
| ID register | 0x6D220200 (code 0x6D22, version 2.0) |
| Registers | 14 words, 0x000 to 0x034 |
| Interrupts | 4 sources into one level-high `irq` |
| Data streams | CMD (to the core) |
| Protocol pins | 16 pass-through |

## Overview

GDDR7_Lite_top -- educational GDDR7-flavoured controller. Built on the DDR4_Lite micro-architecture with GDDR7 features: * dual independent channels (2 ch x 4 banks = 8 entries, each with its own open-row state and timers); the channel travels on addr[11] of ACT / RD / WR / PRE * PAM3 signaling mode (MR2[0]): the data interface is a symbol bus -- 16 physical pins x 2-bit ternary lanes. A PAM3 burst is BL6: 6 beats x 16 trits = 96 trits = 32 nibbles = 128 data bits (nibble v -> trits {t0, t1, t2} with v = 9*t0 + 3*t1 + t2; 16 of the 27 trit triples are used). PAM2 mode keeps BL8 on the low 16 lanes, the upper 16 Hi-Z. * the array holds raw data in both modes: a write is encoded onto the symbol bus and decoded on the DRAM side, a read is encoded by the DRAM side and decoded for the host, so a round trip in PAM3 proves both coders, and a line reads back the same after a mode switch * the burst length follows the mode latched with each command * timing-fenced scheduling as DDR4_Lite: tRCD, tRP, tRC, tRAS, tRRD, tWR, tWTR, tRFC, tREFI; data exactly CL / CWL clocks after RD / WR; all-bank refresh is PREA (when a bank is open) + REF + tRFC * MR file MR0..MR7 (MR0[3:0] CL, MR1[3:0] CWL, MR2[0] PAM3), sticky irq on rejected commands and refresh overrun Documented abstractions: PAM3 here is a digital symbol-level model (one 2-bit lane per pin), not analog levels; no equalization, no CK/WCK ratio, no per-channel CK/WCK; SDR dqs; array inside the model; one command engine for both channels (one transaction in flight). Front-end: hcmd 0 NOP | 1 READ line | 2 WRITE line | 3 MRW (haddr[2:0], hwdata[7:0]) | 4 MRR | 5 REFRESH (all banks, both channels). haddr: [9]=channel [8:7]=bank [18:10]=row [6:4]=line [3:0]=byte; [31:19] must be 0. Handshake and data beats as DDR4_Lite: a command is taken on hvalid && hready; a WRITE takes 8 beats on hvalid clocks; read data is on hrdata in the 8 clocks ending with hdone.

haddr: [9] channel, [8:7] bank, [18:10] row, [6:4] line; [31:19] must be 0. hcmd 0 NOP, 1 READ line, 2 WRITE line (then 8 data beats), 3 MRW (haddr[2:0], hwdata[7:0]; MR2[0] selects PAM3), 4 MRR, 5 REFRESH; 6 and 7 are rejected.
The DRAM pins (ck_t, ck_c, cke, cs_n, act_n, ras_n, cas_n, we_n, ba, addr, dq, dqs) and the command trace pass through unchanged.
The core's own verification (pin-level checker, 100% coverage) is tb/cov/GDDR7_Lite_sva.sv with tb/GDDR7_Lite_tb.sv; this wrapper test drives the core only through the registers.

## Files

| File | Content |
|---|---|
| `rtl/GDDR7_Lite_top.sv` | protocol core |
| `rtl/GDDR7_Lite_apb.sv` | APB4 register wrapper (generated) |
| `tb/GDDR7_Lite_tb.sv` | core testbench |
| `tb/GDDR7_Lite_apb_tb.sv`, `tb/apb/GDDR7_Lite_apb_func.svh` | wrapper testbench (generated part + IP-specific part) |
| `tb/cov/GDDR7_Lite_sva.sv`, `tb/cov/GDDR7_Lite_apb_sva.sv` | coverage checkers (core, wrapper) |
| `scripts/apb/specs/GDDR7_Lite.json` | register spec the wrapper, TB, checker and this page are generated from |

```
make -f Makefile.GDDR7_Lite sim syn            # core test + synthesis (Icarus, Yosys)
make -f Makefile.GDDR7_Lite apb                # wrapper test + synthesis
bash scripts/cov/run_cov.sh GDDR7_Lite          # core coverage (Verilator)
bash scripts/cov/run_cov.sh GDDR7_Lite_apb      # wrapper coverage
```

## Parameters

`GDDR7_Lite_apb` has the core's parameters and passes them to `GDDR7_Lite_top` unchanged.

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

Pins of `GDDR7_Lite_apb`. Widths of the pass-through pins are at the default parameters.

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
| `pam3` | output | 1 | protocol pin, core port `pam3` (also read in a register) |
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
| `dq` | inout | 32 | protocol pin, core port `dq` |
| `dqs` | inout | 2 | protocol pin, core port `dqs` |
| `trace_valid` | output | 1 | protocol pin, core port `trace_valid` |
| `trace_cmd` | output | 4 | protocol pin, core port `trace_cmd` |
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
| `pam3` | output | 1 | STATUS |
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
| `dq` | inout | 32 | pin (pass-through) |
| `dqs` | inout | 2 | pin (pass-through) |
| `trace_valid` | output | 1 | pin (pass-through) |
| `trace_cmd` | output | 4 | pin (pass-through) |
| `trace_addr` | output | 32 | pin (pass-through) |

## APB wrapper

`GDDR7_Lite_apb` is an APB4 slave (AMBA APB protocol v2.0): zero wait states, 32-bit data, 12-bit byte address, PSTRB byte lanes on every writable register, PSLVERR on an unmapped or misaligned address (reads then return 0, writes are dropped). Writes to read-only registers are ignored without an error. The core runs on PCLK and PRESETN. `irq` is level-high: `|(IRQ_STATUS & IRQ_ENABLE)`.

Pass-through pins: `pam3`, `ck_t`, `ck_c`, `cke`, `cs_n`, `act_n`, `ras_n`, `cas_n`, `we_n`, `ba`, `addr`, `dq`, `dqs`, `trace_valid`, `trace_cmd`, `trace_addr`.

### Register map

| Offset | Name | Access | Reset | Description |
|---|---|---|---|---|
| 0x000 | ID | RO | 0x6D220200 | IP identification: code, major and minor version |
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
| 0x034 | STATUS | RO | core | Core state |

Unlisted bits read 0 and ignore writes. Reset "core": the register reads the core's outputs directly, so after reset it shows the core's own reset state. WO (pulse) registers read 0. Offsets from 0x038 up to 0xFFC are unmapped (PSLVERR).

### Fields

| Register | Bits | Field | Access | Reset | Description |
|---|---|---|---|---|---|
| ID | 31:16 | CODE | RO | 0x6D22 | IP code |
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
| STATUS | 0 | `pam3` | RO | core | signaling mode: MR2[0], 1 = PAM3 (BL6 on the 16 symbol lanes); same as the pam3 pin |

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

1. Release PRESETN. Read ID (0x000) and check it is 0x6D220200.
2. Write 0xF to IRQ_STATUS (0x004) to clear any stale bits.
3. Write IRQ_ENABLE (0x008) with the interrupts to use (bit order as in the Interrupts table; 0xF enables all).
4. To send on CMD: wait until FLAGS.CMD_FULL (bit 0) is 0, or for IRQ CMD_DONE, then write CMD0 (0x014) then CMD1 (0x018) then CMD2 (0x01C). The last write commits the beat. CMD_OVF means a write came while the register was full and was dropped.
5. Read RDATA (0x020) for the core's live `hrdata`; it needs no clearing.
6. Read RLINE0 (0x024), RLINE1 (0x028), RLINE2 (0x02C), RLINE3 (0x030) for the core's live `rdline[31:0]`, `rdline[63:32]`, `rdline[95:64]`, `rdline[127:96]`; it needs no clearing.
7. Read STATUS (0x034) for the core's live `pam3`; it needs no clearing.
8. On `irq`: read IRQ_STATUS, handle every bit that is set and enabled, then write those bits back to IRQ_STATUS to clear them. A source that is still active sets its bit again.

## Verification

Five-metric coverage with Verilator 5.052 (`scripts/cov/run_cov.sh`); see [COVERAGE_CLOSURE.md](../COVERAGE_CLOSURE.md) for the flow. Line and toggle count only the named RTL file.

| Scope | Test | Line | Toggle | FSM | SVA | Functional |
|---|---|---|---|---|---|---|
| core `rtl/GDDR7_Lite_top.sv` | pass | 191/191 (+3 excl.) | 3596/3596 (+66 excl.) | 43/43 | 32/32 | 113/113 |
| wrapper `rtl/GDDR7_Lite_apb.sv` | pass | 38/38 | 1124/1124 (+54 excl.) | n/a | 11/11 | 56/56 |
