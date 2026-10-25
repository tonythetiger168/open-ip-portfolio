# DFI 5.0 PHY-side model: DDR command decode with bank state, write path (tphy_wrlat) and read path (trddata_en, tphy_rdlat) timing checks, byte masks, init and low-power handshakes, over an 8-bank DRAM array

Protocol IP `DFI_5_0__MC_PHY_Interface_`, version 2.0. Apache-2.0.

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

```
make -f Makefile.DFI_5_0__MC_PHY_Interface_ sim syn            # core test + synthesis (Icarus, Yosys)
make -f Makefile.DFI_5_0__MC_PHY_Interface_ apb                # wrapper test + synthesis
bash scripts/cov/run_cov.sh DFI_5_0__MC_PHY_Interface_          # core coverage (Verilator)
bash scripts/cov/run_cov.sh DFI_5_0__MC_PHY_Interface__apb      # wrapper coverage
```

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
| 0x014 | STATUS | RO | 0x00000000 | Handshake state |

### Fields

| Register | Bits | Field | Description |
|---|---|---|---|
| ID | 31:16 | CODE | 0x4435 |
| ID | 15:8 | MAJOR | 2 |
| ID | 7:0 | MINOR | 0 |
| STATUS | 0 | `dfi_init_complete` | initialisation done (held while dfi_init_start stays high); same as the pin |
| STATUS | 1 | `dfi_lp_ctrl_ack` | low-power request acknowledged; same as the pin |

### Interrupts (IRQ_STATUS, IRQ_ENABLE)

A bit is set while its source is active, stays set until written with 1, and a set in the same clock as the clear wins.

| Bit | Name | Set when |
|---|---|---|
| 0 | ERR | a command before init, in low power or with cke low; ACT to an open bank; RD / WR to a closed bank; REF / MRS with a bank open; a missing or unexpected dfi_wrdata_en / dfi_rddata_en beat. Sticky in the core until PRESETN, so the bit is set again on every clock |

## Verification

Five-metric coverage with Verilator 5.052 (`scripts/cov/run_cov.sh`); see [COVERAGE_CLOSURE.md](../COVERAGE_CLOSURE.md) for the flow. Line and toggle count only the named RTL file.

| Scope | Test | Line | Toggle | FSM | SVA | Functional |
|---|---|---|---|---|---|---|
| core `rtl/DFI_5_0__MC_PHY_Interface__top.sv` | pass | 53/53 | 788/788 | 14/14 | 7/7 | 25/25 |
| wrapper `rtl/DFI_5_0__MC_PHY_Interface__apb.sv` | pass | 20/20 | 600/600 | n/a | 7/7 | 25/25 |
