# GDDR5 memory controller: graphics controller with a tWTR fence (banks = haddr[11:9], row = haddr[31:18], storage = 256 columns): a RD waits tWTR after the end of a write burst to its bank

Protocol IP `GDDR5`, version 2.0. Apache-2.0.

| Item | Value |
|---|---|
| Core | `GDDR5_top` (`rtl/GDDR5_top.sv`) |
| Register interface | APB4 slave `GDDR5_apb`, 32-bit data, 12-bit byte address, zero wait states |
| Clock, reset | PCLK (rising edge), PRESETN (active low, asynchronous) |
| ID register | 0x6D060200 (code 0x6D06, version 2.0) |
| Registers | 9 words, 0x000 to 0x020 |
| Interrupts | 3 sources into one level-high `irq` |
| Data streams | CMD (to the core) |
| Protocol pins | 12 pass-through |

## Overview

GDDR5 -- INDEPENDENT design IP #12/20. Architecture thesis: graphics memory with a hard write-to-read turnaround. A tWTR down-counter loads at the end of every WR burst and blocks any RD to the same bank until it drains; 8 banks ({ch,haddr[11:9]}) feed a high-CL pipeline (CL=13). All-bank refresh. The WTR fence is the structure the DDR designs omit. Contract identical to DDR_top.

ck_t, ck_c, cke, addr, ras_n, cas_n, we_n, dq and dqs are the DRAM pins and trace_valid, trace_cmd and trace_addr the command trace (one clock before each command on the pins); they pass through unchanged.
Address map and behaviour of the core: graphics controller with a tWTR fence (banks = haddr[11:9], row = haddr[31:18], storage = 256 columns): a RD waits tWTR after the end of a write burst to its bank.
The core's own verification (pin-level checker, 100% coverage) is tb/cov/GDDR5_sva.sv with tb/GDDR5_tb.sv; this wrapper test drives the core only through the registers.

## Files

| File | Content |
|---|---|
| `rtl/GDDR5_top.sv` | protocol core |
| `rtl/GDDR5_apb.sv` | APB4 register wrapper (generated) |
| `tb/GDDR5_tb.sv` | core testbench |
| `tb/GDDR5_apb_tb.sv`, `tb/apb/GDDR5_apb_func.svh` | wrapper testbench (generated part + IP-specific part) |
| `tb/cov/GDDR5_sva.sv`, `tb/cov/GDDR5_apb_sva.sv` | coverage checkers (core, wrapper) |
| `scripts/apb/specs/GDDR5.json` | register spec the wrapper, TB, checker and this page are generated from |

```
make -f Makefile.GDDR5 sim syn            # core test + synthesis (Icarus, Yosys)
make -f Makefile.GDDR5 apb                # wrapper test + synthesis
bash scripts/cov/run_cov.sh GDDR5          # core coverage (Verilator)
bash scripts/cov/run_cov.sh GDDR5_apb      # wrapper coverage
```

## Parameters

`GDDR5_apb` has the core's parameters and passes them to `GDDR5_top` unchanged.

| Parameter | Type | Default |
|---|---|---|
| `NCH` | int | `1` |

## Wrapper pins

Pins of `GDDR5_apb`. Widths of the pass-through pins are at the default parameters.

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
| `ras_n` | output | 1 | protocol pin, core port `ras_n` |
| `cas_n` | output | 1 | protocol pin, core port `cas_n` |
| `we_n` | output | 1 | protocol pin, core port `we_n` |
| `dq` | inout | 16 | protocol pin, core port `dq` |
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
| `hdone` | output | 1 | IRQ_STATUS.RD_DONE |
| `ck_t` | output | 1 | pin (pass-through) |
| `ck_c` | output | 1 | pin (pass-through) |
| `addr` | output | 17 | pin (pass-through) |
| `ras_n` | output | 1 | pin (pass-through) |
| `cas_n` | output | 1 | pin (pass-through) |
| `we_n` | output | 1 | pin (pass-through) |
| `dq` | inout | 16 | pin (pass-through) |
| `dqs` | inout | 2 | pin (pass-through) |
| `cke` | output | 1 | pin (pass-through) |
| `trace_valid` | output | 1 | pin (pass-through) |
| `trace_cmd` | output | 3 | pin (pass-through) |
| `trace_addr` | output | 32 | pin (pass-through) |

## APB wrapper

`GDDR5_apb` is an APB4 slave (AMBA APB protocol v2.0): zero wait states, 32-bit data, 12-bit byte address, PSTRB byte lanes on every writable register, PSLVERR on an unmapped or misaligned address (reads then return 0, writes are dropped). Writes to read-only registers are ignored without an error. The core runs on PCLK and PRESETN. `irq` is level-high: `|(IRQ_STATUS & IRQ_ENABLE)`.

Pass-through pins: `ck_t`, `ck_c`, `addr`, `ras_n`, `cas_n`, `we_n`, `dq`, `dqs`, `cke`, `trace_valid`, `trace_cmd`, `trace_addr`.

### Register map

| Offset | Name | Access | Reset | Description |
|---|---|---|---|---|
| 0x000 | ID | RO | 0x6D060200 | IP identification: code, major and minor version |
| 0x004 | IRQ_STATUS | W1C | 0x00000000 | Sticky interrupt bits, write 1 to clear |
| 0x008 | IRQ_ENABLE | RW | 0x00000000 | Interrupt enables; irq = \|(IRQ_STATUS & IRQ_ENABLE) |
| 0x00C | FLAGS | RO | 0x00000000 | Stream holding-register state |
| 0x010 | SCRATCH | RW | 0x00000000 | Scratch register, no effect on the core |
| 0x014 | CMD0 | RW | 0x00000000 | Host command; writing CMD2 sends it (the core takes it when it is idle and no refresh is due) |
| 0x018 | CMD1 | RW | 0x00000000 | Host command; writing CMD2 sends it (the core takes it when it is idle and no refresh is due) |
| 0x01C | CMD2 | RW | 0x00000000 | Host command; writing CMD2 sends it (the core takes it when it is idle and no refresh is due) |
| 0x020 | RDATA | RO | core | Read data |

Unlisted bits read 0 and ignore writes. Reset "core": the register reads the core's outputs directly, so after reset it shows the core's own reset state. WO (pulse) registers read 0. Offsets from 0x024 up to 0xFFC are unmapped (PSLVERR).

### Fields

| Register | Bits | Field | Access | Reset | Description |
|---|---|---|---|---|---|
| ID | 31:16 | CODE | RO | 0x6D06 | IP code |
| ID | 15:8 | MAJOR | RO | 0x02 | major version |
| ID | 7:0 | MINOR | RO | 0x00 | minor version |
| IRQ_STATUS | 2:0 | one bit per interrupt | W1C | 0x0 | see Interrupts |
| IRQ_ENABLE | 2:0 | one bit per interrupt | RW | 0x0 | 1 enables the IRQ_STATUS bit onto `irq` |
| FLAGS | 0 | one bit per stream flag | RO | 0x0 | see FLAGS |
| SCRATCH | 31:0 | SCRATCH | RW | 0x00000000 | free for software |
| CMD0 | 2:0 | `hcmd` | RW | 0x0 | 1 ACT, 2 RD, 3 WR, 4 PRE; other codes are no-ops |
| CMD1 | 31:0 | `haddr` | RW | 0x0 | host address (bank, row and column fields below) |
| CMD2 | 15:0 | `hwdata` | RW | 0x0 | word to write (WR) |
| RDATA | 15:0 | `hrdata` | RO | core | word of the last RD, valid once RD_DONE is set |

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

## Programming sequence

1. Release PRESETN. Read ID (0x000) and check it is 0x6D060200.
2. Write 0x7 to IRQ_STATUS (0x004) to clear any stale bits.
3. Write IRQ_ENABLE (0x008) with the interrupts to use (bit order as in the Interrupts table; 0x7 enables all).
4. To send on CMD: wait until FLAGS.CMD_FULL (bit 0) is 0, or for IRQ CMD_DONE, then write CMD0 (0x014) then CMD1 (0x018) then CMD2 (0x01C). The last write commits the beat. CMD_OVF means a write came while the register was full and was dropped.
5. Read RDATA (0x020) for the core's live `hrdata`; it needs no clearing.
6. On `irq`: read IRQ_STATUS, handle every bit that is set and enabled, then write those bits back to IRQ_STATUS to clear them. A source that is still active sets its bit again.

## Verification

Five-metric coverage with Verilator 5.052 (`scripts/cov/run_cov.sh`); see [COVERAGE_CLOSURE.md](../COVERAGE_CLOSURE.md) for the flow. Line and toggle count only the named RTL file.

| Scope | Test | Line | Toggle | FSM | SVA | Functional |
|---|---|---|---|---|---|---|
| core `rtl/GDDR5_top.sv` | pass | 104/104 (+4 excl.) | 1364/1364 (+322 excl.) | 24/24 | 25/25 | 67/67 |
| wrapper `rtl/GDDR5_apb.sv` | pass | 33/33 | 810/810 (+12 excl.) | n/a | 11/11 | 42/42 |
