# LPDDR5X memory controller: DVFS mobile controller (bank = {haddr[8] channel, haddr[10:9]}, row = haddr[31:18], storage = 256 columns per channel), per-bank refresh, FSP-OP mailbox (WR to column 0xF1: FSP0 CL 22 / FSP1 CL 14); commands leave as framed beats on the 7-bit CA bus

Protocol IP `LPDDR5X`, version 2.0. Apache-2.0.

## Overview

LPDDR5X -- INDEPENDENT design IP #9/20. Architecture thesis: DVFS-era mobile controller. Two frequency-set-point latency files (FSP0: CL=22 / FSP1: CL=14); a write to the "FSP-OP" mailbox column (0xF1) switches the active file for all subsequent transactions (mid-flight bursts keep their latched latency). The mailbox write is a controller register write: no DRAM traffic, array and page state untouched. 8 banks, per-bank refresh rotation; commands reach the pins as framed beats on the 7-bit CA bus. Distinct from LPDDR4 (single frequency word) and LPDDR5 (ranks, no FSP). Self-contained; contract identical.


ck_t, ck_c, cke, ca, cs_n, dq and dqs are the DRAM pins and trace_valid, trace_cmd and trace_addr the command trace (one clock before each command on the pins); they pass through unchanged.
Address map and behaviour of the core: DVFS mobile controller (bank = {haddr[8] channel, haddr[10:9]}, row = haddr[31:18], storage = 256 columns per channel), per-bank refresh, FSP-OP mailbox (WR to column 0xF1: FSP0 CL 22 / FSP1 CL 14); commands leave as framed beats on the 7-bit CA bus.
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

```
make -f Makefile.LPDDR5X sim syn            # core test + synthesis (Icarus, Yosys)
make -f Makefile.LPDDR5X apb                # wrapper test + synthesis
bash scripts/cov/run_cov.sh LPDDR5X          # core coverage (Verilator)
bash scripts/cov/run_cov.sh LPDDR5X_apb      # wrapper coverage
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
| `hdone` | output | 1 | IRQ_STATUS.RD_DONE |
| `ck_t` | output | 1 | pin (pass-through) |
| `ck_c` | output | 1 | pin (pass-through) |
| `ca` | output | 7 | pin (pass-through) |
| `cs_n` | output | 1 | pin (pass-through) |
| `dq` | inout | 32 | pin (pass-through) |
| `dqs` | inout | 2 | pin (pass-through) |
| `cke` | output | 1 | pin (pass-through) |
| `trace_valid` | output | 1 | pin (pass-through) |
| `trace_cmd` | output | 3 | pin (pass-through) |
| `trace_addr` | output | 32 | pin (pass-through) |

## APB wrapper

`LPDDR5X_apb` is an APB4 slave (AMBA APB protocol v2.0): zero wait states, 32-bit data, 12-bit byte address, PSTRB byte lanes on every writable register, PSLVERR on an unmapped or misaligned address (reads then return 0, writes are dropped). Writes to read-only registers are ignored without an error. The core runs on PCLK and PRESETN. `irq` is level-high: `|(IRQ_STATUS & IRQ_ENABLE)`.

Pass-through pins: `ck_t`, `ck_c`, `ca`, `cs_n`, `dq`, `dqs`, `cke`, `trace_valid`, `trace_cmd`, `trace_addr`.

### Register map

| Offset | Name | Access | Reset | Description |
|---|---|---|---|---|
| 0x000 | ID | RO | 0x6D120200 | IP identification: code, major and minor version |
| 0x004 | IRQ_STATUS | W1C | 0x00000000 | Sticky interrupt bits, write 1 to clear |
| 0x008 | IRQ_ENABLE | RW | 0x00000000 | Interrupt enables; irq = \|(IRQ_STATUS & IRQ_ENABLE) |
| 0x00C | FLAGS | RO | 0x00000000 | Stream holding-register state |
| 0x010 | SCRATCH | RW | 0x00000000 | Scratch register, no effect on the core |
| 0x014 | CMD0 | RW | 0x00000000 | Host command; writing CMD2 sends it (the core takes it when it is idle and no refresh is due) |
| 0x018 | CMD1 | RW | 0x00000000 | Host command; writing CMD2 sends it (the core takes it when it is idle and no refresh is due) |
| 0x01C | CMD2 | RW | 0x00000000 | Host command; writing CMD2 sends it (the core takes it when it is idle and no refresh is due) |
| 0x020 | RDATA | RO | 0x00000000 | Read data |

### Fields

| Register | Bits | Field | Description |
|---|---|---|---|
| ID | 31:16 | CODE | 0x6D12 |
| ID | 15:8 | MAJOR | 2 |
| ID | 7:0 | MINOR | 0 |
| CMD0 | 2:0 | `hcmd` | 1 ACT, 2 RD, 3 WR, 4 PRE; other codes are no-ops |
| CMD1 | 31:0 | `haddr` | host address (bank, row and column fields below) |
| CMD2 | 15:0 | `hwdata` | word to write (WR) |
| RDATA | 15:0 | `hrdata` | word of the last RD, valid once RD_DONE is set |

### Interrupts (IRQ_STATUS, IRQ_ENABLE)

A bit is set while its source is active, stays set until written with 1, and a set in the same clock as the clear wins.

| Bit | Name | Set when |
|---|---|---|
| 0 | RD_DONE | a RD finished; RDATA holds its word |
| 1 | CMD_DONE | CMD beat accepted by the core |
| 2 | CMD_OVF | write to CMD while full (dropped) |

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
| core `rtl/LPDDR5X_top.sv` | pass | 117/117 (+4 excl.) | 1330/1330 (+200 excl.) | 24/24 | 26/26 | 27/27 |
| wrapper `rtl/LPDDR5X_apb.sv` | pass | 33/33 | 818/818 (+6 excl.) | n/a | 11/11 | 42/42 |
