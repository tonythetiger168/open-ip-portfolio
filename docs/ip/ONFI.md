# ONFI NAND flash host controller, one target on the asynchronous (SDR) interface: Reset, Read ID, Read Status, Read Page, Program Page, Erase Block, Get / Set Features, R/B# wait with timeout

Protocol IP `ONFI`, version 2.0. Apache-2.0.

## Overview

ONFI_top v2.0: ONFI NAND flash host controller for one target on the asynchronous (SDR) data interface

- Host side: a command (cmd_valid / cmd_ready; cmd_op, row address,
column address, length), a write byte stream (wr_*) for Program Page
and Set Features, a read byte stream (rd_*) for Read ID, Read Page and
Get Features. done pulses when a command is over; status holds the
last status byte read; ev_fail pulses with done when a Program or
Erase reports FAIL (status bit 0); ev_timeout pulses with done when
R/B# stayed low for TBUSY clocks (the command is abandoned).
- Commands (cmd_op): 0 Reset FFh; 1 Read ID 90h (address = col[7:0],
cmd_len bytes); 2 Read Status 70h (into status); 3 Read Page 00h, two
column and three row cycles, 30h, wait for ready, cmd_len bytes;
4 Program Page 80h, five address cycles, cmd_len bytes, 10h, wait for
ready, then Read Status; 5 Erase Block 60h, three row cycles, D0h,
wait for ready, then Read Status; 6 Get Features EEh (feature address
= col[7:0]), wait for ready, 4 bytes; 7 Set Features EFh, 4 bytes,
wait for ready.
- Pins: ce_n is low from the first cycle of a command to its end. A
command, address or data-in cycle sets CLE / ALE / DQ, holds WE# low
for TP clocks and high for TP clocks (the target latches on the rising
edge); a data-out cycle holds RE# low for TP clocks and takes DQ on
the clock RE# rises, then RE# high for TP clocks. dq_oe drives DQ for
write cycles only. Between phases the controller waits tWB (TWB clocks
after the last command cycle, before R/B# is looked at), tWHR (TWHR
clocks before the first data-out cycle after a command or address),
tADL (TADL clocks from the last address cycle to data in) and tRR (TRR
clocks from ready to data out). rb_n goes through a two-flop
synchronizer.
- The data streams can stall the bus: a data-in cycle starts when a
byte is offered, a data-out cycle when the read register is empty.
Not implemented: the NV-DDR interfaces and their timing modes, more
than one target or LUN, cache and multi-plane operations, Change Read
Column, Read Parameter Page, Read Status Enhanced, ECC, write protect.
Opcodes and cycle order follow ONFI 4.2 as we read them; they have not
been checked against a device.

ce_n, cle, ale, we_n, re_n, dq_o, dq_oe, dq_i and rb_n are the NAND pins; they pass through unchanged.
The core parameters TP (2), TWB (6), TWHR (8), TADL (10), TRR (3), TBUSY (2048) and LW (12) keep their defaults.

## Files

| File | Content |
|---|---|
| `rtl/ONFI_top.sv` | protocol core |
| `rtl/ONFI_apb.sv` | APB4 register wrapper (generated) |
| `tb/ONFI_tb.sv` | core testbench |
| `tb/ONFI_apb_tb.sv`, `tb/apb/ONFI_apb_func.svh` | wrapper testbench (generated part + IP-specific part) |
| `tb/cov/ONFI_sva.sv`, `tb/cov/ONFI_apb_sva.sv` | coverage checkers (core, wrapper) |
| `scripts/apb/specs/ONFI.json` | register spec the wrapper, TB, checker and this page are generated from |

```
make -f Makefile.ONFI sim syn            # core test + synthesis (Icarus, Yosys)
make -f Makefile.ONFI apb                # wrapper test + synthesis
bash scripts/cov/run_cov.sh ONFI          # core coverage (Verilator)
bash scripts/cov/run_cov.sh ONFI_apb      # wrapper coverage
```

## Core ports

| Port | Dir | Width | In the APB wrapper |
|---|---|---|---|
| `clk` | input | 1 | PCLK |
| `rst_n` | input | 1 | PRESETN |
| `cmd_valid` | input | 1 | CMD commit / FLAGS |
| `cmd_ready` | output | 1 | CMD handshake |
| `cmd_op` | input | 3 | CMD0[26:24] |
| `cmd_row` | input | 24 | CMD0[23:0] |
| `cmd_col` | input | 16 | CMD1[15:0] |
| `cmd_len` | input | 12 | CMD1[27:16] |
| `wr_valid` | input | 1 | WR commit / FLAGS |
| `wr_ready` | output | 1 | WR handshake |
| `wr_data` | input | 8 | WR[7:0] |
| `rd_valid` | output | 1 | RD capture |
| `rd_ready` | input | 1 | RD handshake |
| `rd_data` | output | 8 | RD[7:0] |
| `done` | output | 1 | IRQ_STATUS.DONE |
| `status` | output | 8 | STATUS[7:0] |
| `ev_fail` | output | 1 | IRQ_STATUS.FAIL |
| `ev_timeout` | output | 1 | IRQ_STATUS.TIMEOUT |
| `ce_n` | output | 1 | pin (pass-through) |
| `cle` | output | 1 | pin (pass-through) |
| `ale` | output | 1 | pin (pass-through) |
| `we_n` | output | 1 | pin (pass-through) |
| `re_n` | output | 1 | pin (pass-through) |
| `dq_o` | output | 8 | pin (pass-through) |
| `dq_oe` | output | 1 | pin (pass-through) |
| `dq_i` | input | 8 | pin (pass-through) |
| `rb_n` | input | 1 | pin (pass-through) |

## APB wrapper

`ONFI_apb` is an APB4 slave (AMBA APB protocol v2.0): zero wait states, 32-bit data, 12-bit byte address, PSTRB byte lanes on every writable register, PSLVERR on an unmapped or misaligned address (reads then return 0, writes are dropped). Writes to read-only registers are ignored without an error. The core runs on PCLK and PRESETN. `irq` is level-high: `|(IRQ_STATUS & IRQ_ENABLE)`.

Pass-through pins: `ce_n`, `cle`, `ale`, `we_n`, `re_n`, `dq_o`, `dq_oe`, `dq_i`, `rb_n`.

### Register map

| Offset | Name | Access | Reset | Description |
|---|---|---|---|---|
| 0x000 | ID | RO | 0x4F4E0200 | IP identification: code, major and minor version |
| 0x004 | IRQ_STATUS | W1C | 0x00000000 | Sticky interrupt bits, write 1 to clear |
| 0x008 | IRQ_ENABLE | RW | 0x00000000 | Interrupt enables; irq = \|(IRQ_STATUS & IRQ_ENABLE) |
| 0x00C | FLAGS | RO | 0x00000000 | Stream holding-register state |
| 0x010 | SCRATCH | RW | 0x00000000 | Scratch register, no effect on the core |
| 0x014 | CMD0 | RW | 0x00000000 | Command; writing CMD1 sends it (the core takes it when the previous command is over) |
| 0x018 | CMD1 | RW | 0x00000000 | Command; writing CMD1 sends it (the core takes it when the previous command is over) |
| 0x01C | WR | RW | 0x00000000 | Byte to program (Program Page) or feature parameter (Set Features, 4 bytes); the core takes it as the data-in cycle starts |
| 0x020 | RD | RO (pop) | 0x00000000 | Byte read (Read ID, Read Page, Get Features); reading it pops it. The core holds off the next data-out cycle while RD is full |
| 0x024 | STATUS | RO | 0x00000000 | Target status |

### Fields

| Register | Bits | Field | Description |
|---|---|---|---|
| ID | 31:16 | CODE | 0x4F4E |
| ID | 15:8 | MAJOR | 2 |
| ID | 7:0 | MINOR | 0 |
| CMD0 | 23:0 | `cmd_row` | row address (three cycles, low byte first) |
| CMD0 | 26:24 | `cmd_op` | 0 Reset, 1 Read ID, 2 Read Status, 3 Read Page, 4 Program Page, 5 Erase Block, 6 Get Features, 7 Set Features |
| CMD1 | 15:0 | `cmd_col` | column address (two cycles); bits 7:0 are the Read ID and feature address |
| CMD1 | 27:16 | `cmd_len` | bytes to read or program (Read ID, Read Page, Program Page) |
| WR | 7:0 | `wr_data` | byte |
| RD | 7:0 | `rd_data` | byte |
| STATUS | 7:0 | `status` | the last status byte read (Read Status, and after Program and Erase): bit 6 RDY, bit 0 FAIL |

### Interrupts (IRQ_STATUS, IRQ_ENABLE)

A bit is set while its source is active, stays set until written with 1, and a set in the same clock as the clear wins.

| Bit | Name | Set when |
|---|---|---|
| 0 | DONE | a command is over |
| 1 | FAIL | a Program or Erase reported FAIL |
| 2 | TIMEOUT | R/B# stayed low for TBUSY = 2048 clocks: the command was abandoned |
| 3 | CMD_DONE | CMD beat accepted by the core |
| 4 | CMD_OVF | write to CMD while full (dropped) |
| 5 | WR_DONE | WR beat accepted by the core |
| 6 | WR_OVF | write to WR while full (dropped) |
| 7 | RD_AVAIL | RD captured a beat |

### FLAGS

| Bit | Name | Meaning |
|---|---|---|
| 0 | CMD_FULL | CMD holds a beat the core has not taken |
| 1 | WR_FULL | WR holds a beat the core has not taken |
| 2 | RD_AVAIL | RD holds an unread beat |

### Streams

* **CMD** feeds `cmd_row`, `cmd_op`, `cmd_col`, `cmd_len`/`cmd_valid`. Writing CMD1 commits the beat: FLAGS.CMD_FULL is set and `cmd_valid` stays high until the core's `cmd_ready`; then CMD_DONE is set. A write while full is dropped and sets CMD_OVF.
* **WR** feeds `wr_data`/`wr_valid`. Writing WR commits the beat: FLAGS.WR_FULL is set and `wr_valid` stays high until the core's `wr_ready`; then WR_DONE is set. A write while full is dropped and sets WR_OVF.
* **RD** takes `rd_data` from the core with `rd_valid` / `rd_ready`: `rd_ready` is high while the register is empty (or is being read in the same clock), and a captured beat sets FLAGS/IRQ RD_AVAIL. Reading RD pops it. Nothing is dropped: the core holds its data until the register is free.

## Verification

Five-metric coverage with Verilator 5.052 (`scripts/cov/run_cov.sh`); see [COVERAGE_CLOSURE.md](../COVERAGE_CLOSURE.md) for the flow. Line and toggle count only the named RTL file.

| Scope | Test | Line | Toggle | FSM | SVA | Functional |
|---|---|---|---|---|---|---|
| core `rtl/ONFI_top.sv` | pass | 119/119 | 458/458 | 17/17 | 5/5 | 25/25 |
| wrapper `rtl/ONFI_apb.sv` | pass | 40/40 | 818/818 | n/a | 15/15 | 72/72 |
