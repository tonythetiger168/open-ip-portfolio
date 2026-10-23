# HBM3E memory controller: on-die-ECC controller (256 page entries {channel haddr[10:8], pc/bank haddr[15:11]}, row = haddr[31:18], storage = 256 SEC codewords per channel); bits of stored codewords are flipped through a backdoor and the reads must still return the written data

Protocol IP `HBM3E`, version 2.0. Apache-2.0.

## Overview

HBM3E -- INDEPENDENT design IP #18/20. Architecture thesis: on-die ECC. The array stores 21-bit SEC codewords (16 data + 5 Hamming check bits over positions 1..21, checks at 1,2,4,8,16); writes encode, reads decode+correct a single-bit error (syndrome = XOR of set-bit positions; syndrome!=0 flips that position back). Read data is always corrected before hrdata; the stored word is not scrubbed. SEC only: a double-bit error is not detected and may be miscorrected. 256 page entries ({ch haddr[10:8], pc/bank haddr[15:11]}), per-entry refresh rotating over all 256. Contract identical to DDR_top (hrdata carries corrected data; the TB flips stored bits through a backdoor and its scoreboard therefore proves the correction).


ck_t, ck_c, cke, addr, ras_n, cas_n, we_n, dq and dqs are the DRAM pins and trace_valid, trace_cmd and trace_addr the command trace (one clock before each command on the pins); they pass through unchanged.
Address map and behaviour of the core: on-die-ECC controller (256 page entries {channel haddr[10:8], pc/bank haddr[15:11]}, row = haddr[31:18], storage = 256 SEC codewords per channel); bits of stored codewords are flipped through a backdoor and the reads must still return the written data.
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

```
make -f Makefile.HBM3E sim syn            # core test + synthesis (Icarus, Yosys)
make -f Makefile.HBM3E apb                # wrapper test + synthesis
bash scripts/cov/run_cov.sh HBM3E          # core coverage (Verilator)
bash scripts/cov/run_cov.sh HBM3E_apb      # wrapper coverage
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
| `addr` | output | 17 | pin (pass-through) |
| `ras_n` | output | 1 | pin (pass-through) |
| `cas_n` | output | 1 | pin (pass-through) |
| `we_n` | output | 1 | pin (pass-through) |
| `dq` | inout | 128 | pin (pass-through) |
| `dqs` | inout | 2 | pin (pass-through) |
| `cke` | output | 1 | pin (pass-through) |
| `trace_valid` | output | 1 | pin (pass-through) |
| `trace_cmd` | output | 3 | pin (pass-through) |
| `trace_addr` | output | 32 | pin (pass-through) |

## APB wrapper

`HBM3E_apb` is an APB4 slave (AMBA APB protocol v2.0): zero wait states, 32-bit data, 12-bit byte address, PSTRB byte lanes on every writable register, PSLVERR on an unmapped or misaligned address (reads then return 0, writes are dropped). Writes to read-only registers are ignored without an error. The core runs on PCLK and PRESETN. `irq` is level-high: `|(IRQ_STATUS & IRQ_ENABLE)`.

Pass-through pins: `ck_t`, `ck_c`, `addr`, `ras_n`, `cas_n`, `we_n`, `dq`, `dqs`, `cke`, `trace_valid`, `trace_cmd`, `trace_addr`.

### Register map

| Offset | Name | Access | Reset | Description |
|---|---|---|---|---|
| 0x000 | ID | RO | 0x6D0C0200 | IP identification: code, major and minor version |
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
| ID | 31:16 | CODE | 0x6D0C |
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
| core `rtl/HBM3E_top.sv` | pass | 115/115 (+4 excl.) | 2402/2402 (+20 excl.) | 24/24 | 24/24 | 23/23 |
| wrapper `rtl/HBM3E_apb.sv` | pass | 33/33 | 1034/1034 (+12 excl.) | n/a | 11/11 | 42/42 |
