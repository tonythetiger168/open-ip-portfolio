# DFI 5.0 PHY-side model: DDR command decode with bank state, write path (tphy_wrlat) and read path (trddata_en, tphy_rdlat) timing checks, byte masks, init and low-power handshakes, over an 8-bank DRAM array

Protocol IP `DFI_5_0__MC_PHY_Interface_`, version 2.0. Apache-2.0.

| Item | Value |
|---|---|
| Core | `DFI_5_0__MC_PHY_Interface__top` (`rtl/DFI_5_0__MC_PHY_Interface__top.sv`) |
| Register interface | APB4 slave `DFI_5_0__MC_PHY_Interface__apb`, 32-bit data, 12-bit byte address, zero wait states |
| Clock, reset | PCLK (rising edge), PRESETN (active low, asynchronous) |
| ID register | 0x44350200 (code 0x4435, version 2.0) |
| Registers | 6 words, 0x000 to 0x014 |
| Interrupts | 1 sources into one level-high `irq` |
| Protocol pins | 18 pass-through |

## Overview

DFI 5.0 (MC-PHY Interface) protocol IP -- PHY-side DFI model Implementation scope (documented simplified subset of DFI 5.0):

- Single 1:1 frequency ratio slice: dfi_clk == clk (no 1:2/1:4 phase
alignment, documented simplification).
- Command channel sampled from the MC: dfi_address/dfi_bank/
dfi_ras_n/dfi_cas_n/dfi_we_n/dfi_cs_n/dfi_cke/dfi_odt.
DDR-style command decode {ras_n,cas_n,we_n} while cs_n=0:
ACT=3'b011  RD=3'b101  WR=3'b100  PRE=3'b010  REF=3'b001
NOP=3'b111  MRS=3'b000 (accepted, no mode-register side effects)
- Bank state: ACT opens a bank (row = dfi_address; the array keeps
row[1:0]), PRE closes it (dfi_address[10] = 1: all banks), RD / WR
take the column from dfi_address[2:0] of an open bank. ACT to an
open bank, RD / WR to a closed bank, REF / MRS with a bank open are
ignored and raise irq.
- Write path (tphy_wrlat): the MC must assert dfi_wrdata_en, with
dfi_wrdata / dfi_wrdata_mask (1 = byte masked off), exactly
T_PHY_WRLAT cycles after each WR command.
- Read path (trddata_en, tphy_rdlat): the MC must assert dfi_rddata_en
exactly T_RDDATA_EN cycles after each RD command; the array is read
on that beat and T_PHY_RDLAT cycles later the PHY returns one
dfi_rddata_valid beat (dfi_rddata is 0 when not valid). A write beat
and a read beat of the same word on the same cycle read the old data.
A missing or unexpected dfi_wrdata_en / dfi_rddata_en raises irq;
the beat is dropped (no write, no read data).
- Initialisation: a rising dfi_init_start runs a 32-cycle init
sequence, then dfi_init_complete is held while dfi_init_start stays
asserted (DFI handshake); the initialised state persists after
release, a new dfi_init_start revokes it and closes all banks.
- Low power: dfi_lp_ctrl request is acknowledged with dfi_lp_ctrl_ack
after a 2-cycle handshake and released 2 cycles after the request
drops. Any command other than NOP / DES before initialisation, in
low power or with dfi_cke low is ignored and raises irq.
- Backing store: 8 banks x 4 rows x 8 columns x 32-bit DRAM array.
- irq is sticky until reset. dfi_odt is sampled (termination) but has
no data-path side effect.

Every DFI signal passes through unchanged; dfi_clk is PCLK (1:1 ratio). The MC drives commands and data beats on the pins; the registers report the handshake state and protocol errors.
Timing: T_PHY_WRLAT 4, T_RDDATA_EN 3, T_PHY_RDLAT 5, init 32 cycles.

## Files

| File | Content |
|---|---|
| `rtl/DFI_5_0__MC_PHY_Interface__top.sv` | protocol core |
| `rtl/DFI_5_0__MC_PHY_Interface__apb.sv` | APB4 register wrapper (generated) |
| `tb/DFI_5_0__MC_PHY_Interface__tb.sv` | core testbench |
| `tb/DFI_5_0__MC_PHY_Interface__apb_tb.sv`, `tb/apb/DFI_5_0__MC_PHY_Interface__apb_func.svh` | wrapper testbench (generated part + IP-specific part) |
| `tb/cov/DFI_5_0__MC_PHY_Interface__sva.sv`, `tb/cov/DFI_5_0__MC_PHY_Interface__apb_sva.sv` | coverage checkers (core, wrapper) |
| `scripts/apb/specs/DFI_5_0__MC_PHY_Interface_.json` | register spec the wrapper, TB, checker and this page are generated from |

How to run the tests and the coverage flow: see [Running and verifying](#running-and-verifying).

## Parameters

`DFI_5_0__MC_PHY_Interface__apb` has the core's parameters and passes them to `DFI_5_0__MC_PHY_Interface__top` unchanged.

| Parameter | Type | Default |
|---|---|---|
| `T_PHY_WRLAT` | int | `4` |
| `T_RDDATA_EN` | int | `3` |
| `T_PHY_RDLAT` | int | `5` |
| `INIT_CYCLES` | int | `32` |

## Wrapper pins

Pins of `DFI_5_0__MC_PHY_Interface__apb`. Widths of the pass-through pins are at the default parameters.

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
| `dfi_address` | input | 17 | protocol pin, core port `dfi_address` |
| `dfi_bank` | input | 3 | protocol pin, core port `dfi_bank` |
| `dfi_ras_n` | input | 1 | protocol pin, core port `dfi_ras_n` |
| `dfi_cas_n` | input | 1 | protocol pin, core port `dfi_cas_n` |
| `dfi_we_n` | input | 1 | protocol pin, core port `dfi_we_n` |
| `dfi_cs_n` | input | 1 | protocol pin, core port `dfi_cs_n` |
| `dfi_cke` | input | 1 | protocol pin, core port `dfi_cke` |
| `dfi_odt` | input | 1 | protocol pin, core port `dfi_odt` |
| `dfi_wrdata_en` | input | 1 | protocol pin, core port `dfi_wrdata_en` |
| `dfi_wrdata` | input | 32 | protocol pin, core port `dfi_wrdata` |
| `dfi_wrdata_mask` | input | 4 | protocol pin, core port `dfi_wrdata_mask` |
| `dfi_rddata_en` | input | 1 | protocol pin, core port `dfi_rddata_en` |
| `dfi_rddata_valid` | output | 1 | protocol pin, core port `dfi_rddata_valid` |
| `dfi_rddata` | output | 32 | protocol pin, core port `dfi_rddata` |
| `dfi_init_start` | input | 1 | protocol pin, core port `dfi_init_start` |
| `dfi_init_complete` | output | 1 | protocol pin, core port `dfi_init_complete` (also read in a register) |
| `dfi_lp_ctrl` | input | 1 | protocol pin, core port `dfi_lp_ctrl` |
| `dfi_lp_ctrl_ack` | output | 1 | protocol pin, core port `dfi_lp_ctrl_ack` (also read in a register) |

## Core ports

| Port | Dir | Width | In the APB wrapper |
|---|---|---|---|
| `clk` | input | 1 | PCLK |
| `rst_n` | input | 1 | PRESETN |
| `dfi_address` | input | 17 | pin (pass-through) |
| `dfi_bank` | input | 3 | pin (pass-through) |
| `dfi_ras_n` | input | 1 | pin (pass-through) |
| `dfi_cas_n` | input | 1 | pin (pass-through) |
| `dfi_we_n` | input | 1 | pin (pass-through) |
| `dfi_cs_n` | input | 1 | pin (pass-through) |
| `dfi_cke` | input | 1 | pin (pass-through) |
| `dfi_odt` | input | 1 | pin (pass-through) |
| `dfi_wrdata_en` | input | 1 | pin (pass-through) |
| `dfi_wrdata` | input | 32 | pin (pass-through) |
| `dfi_wrdata_mask` | input | 4 | pin (pass-through) |
| `dfi_rddata_en` | input | 1 | pin (pass-through) |
| `dfi_rddata_valid` | output | 1 | pin (pass-through) |
| `dfi_rddata` | output | 32 | pin (pass-through) |
| `dfi_init_start` | input | 1 | pin (pass-through) |
| `dfi_init_complete` | output | 1 | STATUS[0:0] |
| `dfi_lp_ctrl` | input | 1 | pin (pass-through) |
| `dfi_lp_ctrl_ack` | output | 1 | STATUS[1:1] |
| `irq` | output | 1 | IRQ_STATUS.ERR |

## APB wrapper

`DFI_5_0__MC_PHY_Interface__apb` is an APB4 slave (AMBA APB protocol v2.0): zero wait states, 32-bit data, 12-bit byte address, PSTRB byte lanes on every writable register, PSLVERR on an unmapped or misaligned address (reads then return 0, writes are dropped). Writes to read-only registers are ignored without an error. The core runs on PCLK and PRESETN. `irq` is level-high: `|(IRQ_STATUS & IRQ_ENABLE)`.

Pass-through pins: `dfi_address`, `dfi_bank`, `dfi_ras_n`, `dfi_cas_n`, `dfi_we_n`, `dfi_cs_n`, `dfi_cke`, `dfi_odt`, `dfi_wrdata_en`, `dfi_wrdata`, `dfi_wrdata_mask`, `dfi_rddata_en`, `dfi_rddata_valid`, `dfi_rddata`, `dfi_init_start`, `dfi_init_complete`, `dfi_lp_ctrl`, `dfi_lp_ctrl_ack`.

### Register map

| Offset | Name | Access | Reset | Description |
|---|---|---|---|---|
| 0x000 | ID | RO | 0x44350200 | IP identification: code, major and minor version |
| 0x004 | IRQ_STATUS | W1C | 0x00000000 | Sticky interrupt bits, write 1 to clear |
| 0x008 | IRQ_ENABLE | RW | 0x00000000 | Interrupt enables; irq = \|(IRQ_STATUS & IRQ_ENABLE) |
| 0x00C | FLAGS | RO | 0x00000000 | Stream holding-register state |
| 0x010 | SCRATCH | RW | 0x00000000 | Scratch register, no effect on the core |
| 0x014 | STATUS | RO | core | Handshake state |

Unlisted bits read 0 and ignore writes. Reset "core": the register reads the core's outputs directly, so after reset it shows the core's own reset state. WO (pulse) registers read 0. Offsets from 0x018 up to 0xFFC are unmapped (PSLVERR).

### Fields

| Register | Bits | Field | Access | Reset | Description |
|---|---|---|---|---|---|
| ID | 31:16 | CODE | RO | 0x4435 | IP code |
| ID | 15:8 | MAJOR | RO | 0x02 | major version |
| ID | 7:0 | MINOR | RO | 0x00 | minor version |
| IRQ_STATUS | 0 | one bit per interrupt | W1C | 0x0 | see Interrupts |
| IRQ_ENABLE | 0 | one bit per interrupt | RW | 0x0 | 1 enables the IRQ_STATUS bit onto `irq` |
| SCRATCH | 31:0 | SCRATCH | RW | 0x00000000 | free for software |
| STATUS | 0 | `dfi_init_complete` | RO | core | initialisation done (held while dfi_init_start stays high); same as the pin |
| STATUS | 1 | `dfi_lp_ctrl_ack` | RO | core | low-power request acknowledged; same as the pin |

### Interrupts (IRQ_STATUS, IRQ_ENABLE)

A bit is set while its source is active, stays set until written with 1, and a set in the same clock as the clear wins.

| Bit | Name | Set when |
|---|---|---|
| 0 | ERR | a command before init, in low power or with cke low; ACT to an open bank; RD / WR to a closed bank; REF / MRS with a bank open; a missing or unexpected dfi_wrdata_en / dfi_rddata_en beat. Sticky in the core until PRESETN, so the bit is set again on every clock |

## Programming sequence

1. Release PRESETN. Read ID (0x000) and check it is 0x44350200.
2. Write 0x1 to IRQ_STATUS (0x004) to clear any stale bits.
3. Write IRQ_ENABLE (0x008) with the interrupts to use (bit order as in the Interrupts table; 0x1 enables all).
4. Read STATUS (0x014) for the core's live `dfi_init_complete`, `dfi_lp_ctrl_ack`; it needs no clearing.
5. On `irq`: read IRQ_STATUS, handle every bit that is set and enabled, then write those bits back to IRQ_STATUS to clear them. A source that is still active sets its bit again.

## Running and verifying

All commands run from the repository root. Icarus Verilog 12 and Yosys 0.33 are enough for steps 1 to 3; step 4 also needs Verilator 5.052 and pyslang (see [README, Setup](../../README.md#setup)).

| Step | Command | Pass when | Output |
|---|---|---|---|
| 1. Core test | `make -f Makefile.DFI_5_0__MC_PHY_Interface_ sim` | a `TEST PASSED` line, no `ERROR` | console |
| 2. Core synthesis | `make -f Makefile.DFI_5_0__MC_PHY_Interface_ syn` | Yosys ends without `ERROR`; `stat` prints the cell count | `work/DFI_5_0__MC_PHY_Interface__top.json` |
| 3. APB wrapper test + synthesis | `make -f Makefile.DFI_5_0__MC_PHY_Interface_ apb` | `TEST PASSED: DFI_5_0__MC_PHY_Interface__apb`, then Yosys without `ERROR` | console, `work/DFI_5_0__MC_PHY_Interface__apb.json` |
| 4. Coverage (core, wrapper) | `bash scripts/cov/run_cov.sh DFI_5_0__MC_PHY_Interface_`<br>`bash scripts/cov/run_cov.sh DFI_5_0__MC_PHY_Interface__apb` | `RESULT: CLOSED` (all five metrics 100%) | `work/cov/DFI_5_0__MC_PHY_Interface_/score.json`, `work/cov/DFI_5_0__MC_PHY_Interface__apb/score.json` |

Expected end of a step 4 run:

```
===== DFI_5_0__MC_PHY_Interface_ =====
TEST: PASSED   SVA_FAILURES: 0
LINE ... TOGGLE ... FSM ... SVA ... FUNCTIONAL  (each n/n, 100.0%)
RESULT: CLOSED
```

**Core test** (`tb/DFI_5_0__MC_PHY_Interface__tb.sv`): drives `DFI_5_0__MC_PHY_Interface__top` through its own ports against a protocol peer or model and checks every result itself; any mismatch prints `ERROR`, and `TEST PASSED` is printed only when there were none.

**APB wrapper test** (`tb/DFI_5_0__MC_PHY_Interface__apb_tb.sv`), in this order:

1. Reset values of every register, ID included.
2. Writes to read-only registers are ignored.
3. Each RW register: all ones, all zeros, then 16 random writes with every PSTRB byte-lane pattern, read back each time.
4. Unmapped and misaligned addresses, reads and writes: PSLVERR, read data 0, no side effect on other registers.
5. Back-to-back transfers with no idle cycle.
6. IP traffic through the registers only (`tb/apb/DFI_5_0__MC_PHY_Interface__apb_func.svh`): the programming sequence above, every interrupt bit set, enabled and cleared (100% wrapper toggle coverage confirms each bit moved).
7. PRESETN asserted mid-run: `irq` and PRDATA go to 0, registers return to reset values.

**Checkers** (`tb/cov/DFI_5_0__MC_PHY_Interface__sva.sv`, `tb/cov/DFI_5_0__MC_PHY_Interface__apb_sva.sv`): SVA protocol and APB assertions plus covergroups, bound in by the coverage flow. An assertion failure prints `SVA_FAIL` and fails the run even when the test itself passed.

Whole portfolio: `bash scripts/ci_regression.sh` runs steps 1 to 3 for every IP (what CI runs), and `bash scripts/cov/run_all.sh 4` runs step 4 for every IP.

## Verification

Five-metric coverage with Verilator 5.052 (`scripts/cov/run_cov.sh`); see [COVERAGE_CLOSURE.md](../COVERAGE_CLOSURE.md) for the flow. Line and toggle count only the named RTL file.

| Scope | Test | Line | Toggle | FSM | SVA | Functional |
|---|---|---|---|---|---|---|
| core `rtl/DFI_5_0__MC_PHY_Interface__top.sv` | pass | 53/53 | 788/788 | 14/14 | 7/7 | 120/120 |
| wrapper `rtl/DFI_5_0__MC_PHY_Interface__apb.sv` | pass | 20/20 | 600/600 | n/a | 7/7 | 25/25 |
