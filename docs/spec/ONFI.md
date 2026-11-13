<!-- SPDX-License-Identifier: Apache-2.0 -->
# ONFI: design specification

An ONFI NAND flash host controller for one target on the asynchronous (SDR) data interface. Not
implemented: the NV-DDR interfaces and timing modes, more than one target or LUN, cache and
multi-plane operations, Change Read Column, Read Parameter Page, Read Status Enhanced, ECC, write
protect; opcodes follow ONFI 4.2 but were not checked against a device. Core `ONFI_top`
(`rtl/ONFI_top.sv`), testbench `tb/ONFI_tb.sv` (a NAND target model and a host model), checker
`tb/cov/ONFI_sva.sv`.

Conventions on this page: every flop is clocked on the rising edge of `clk` and reset
asynchronously by `rst_n` low.

## 1. Interface

| Port | Dir | Width | Meaning | Active | Clock | Reset |
|---|---|---|---|---|---|---|
| `clk` | input | 1 | clock | rising edge | - | - |
| `rst_n` | input | 1 | asynchronous reset | low | async | - |
| `cmd_valid` | input | 1 | a command is offered | high | `clk` | - |
| `cmd_ready` | output | 1 | idle, a command is taken; combinational from flops | high | `clk` | 1 |
| `cmd_op` | input | 3 | 0 Reset, 1 Read ID, 2 Read Status, 3 Read Page, 4 Program Page, 5 Erase Block, 6 Get Features, 7 Set Features | - | `clk` | - |
| `cmd_row` | input | 24 | row address | - | `clk` | - |
| `cmd_col` | input | 16 | column address (Read ID / features: address in bits 7:0) | - | `clk` | - |
| `cmd_len` | input | LW | bytes for Read ID, Read Page, Program Page | - | `clk` | - |
| `wr_valid` | input | 1 | a write byte is offered | high | `clk` | - |
| `wr_ready` | output | 1 | the byte is taken; combinational from flops | high | `clk` | 0 |
| `wr_data` | input | 8 | write byte | - | `clk` | - |
| `rd_valid` | output | 1 | a read byte is held | high | `clk` | 0 |
| `rd_ready` | input | 1 | the host takes it | high | `clk` | - |
| `rd_data` | output | 8 | read byte | - | `clk` | 0 |
| `done` | output | 1 | one-clock pulse: the command is over | high | `clk` | 0 |
| `status` | output | 8 | last status byte read; holds | - | `clk` | 0 |
| `ev_fail` | output | 1 | pulse with `done`: Program / Erase status FAIL (bit 0) | high | `clk` | 0 |
| `ev_timeout` | output | 1 | pulse with `done`: R/B# stayed low `TBUSY` clocks | high | `clk` | 0 |
| `ce_n` | output | 1 | chip enable | low | `clk` | 1 |
| `cle` | output | 1 | command latch enable | high | `clk` | 0 |
| `ale` | output | 1 | address latch enable | high | `clk` | 0 |
| `we_n` | output | 1 | write enable (target latches on the rise) | low | `clk` | 1 |
| `re_n` | output | 1 | read enable | low | `clk` | 1 |
| `dq_o` | output | 8 | DQ driven | - | `clk` | 0 |
| `dq_oe` | output | 1 | the controller drives DQ | high | `clk` | 0 |
| `dq_i` | input | 8 | DQ from the target | - | `clk` | - |
| `rb_n` | input | 1 | ready / busy; two-flop synchronised | low | async | - |

### Internal signals used by the verification

The FSM coverage collector binds `st`.

| Signal | Width | Meaning |
|---|---|---|
| `st` | 3 | 0 IDLE, 1 STEP (next micro-operation), 2 WE# cycle, 3 RE# cycle, 4 WAIT, 5 BUSY |

## 2. Registers

<!-- AUTO:registers -->
Generated from [`docs/ip/ONFI.md`](../ip/ONFI.md) (source: `scripts/apb/specs/ONFI.json`); do not edit by hand.

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
| 0x024 | STATUS | RO | core | Target status |

Unlisted bits read 0 and ignore writes. Reset "core": the register reads the core's outputs directly, so after reset it shows the core's own reset state. WO (pulse) registers read 0. Offsets from 0x028 up to 0xFFC are unmapped (PSLVERR).

### Fields

| Register | Bits | Field | Access | Reset | Description |
|---|---|---|---|---|---|
| ID | 31:16 | CODE | RO | 0x4F4E | IP code |
| ID | 15:8 | MAJOR | RO | 0x02 | major version |
| ID | 7:0 | MINOR | RO | 0x00 | minor version |
| IRQ_STATUS | 7:0 | one bit per interrupt | W1C | 0x0 | see Interrupts |
| IRQ_ENABLE | 7:0 | one bit per interrupt | RW | 0x0 | 1 enables the IRQ_STATUS bit onto `irq` |
| FLAGS | 2:0 | one bit per stream flag | RO | 0x0 | see FLAGS |
| SCRATCH | 31:0 | SCRATCH | RW | 0x00000000 | free for software |
| CMD0 | 23:0 | `cmd_row` | RW | 0x0 | row address (three cycles, low byte first) |
| CMD0 | 26:24 | `cmd_op` | RW | 0x0 | 0 Reset, 1 Read ID, 2 Read Status, 3 Read Page, 4 Program Page, 5 Erase Block, 6 Get Features, 7 Set Features |
| CMD1 | 15:0 | `cmd_col` | RW | 0x0 | column address (two cycles); bits 7:0 are the Read ID and feature address |
| CMD1 | 27:16 | `cmd_len` | RW | 0x0 | bytes to read or program (Read ID, Read Page, Program Page) |
| WR | 7:0 | `wr_data` | RW | 0x0 | byte |
| RD | 7:0 | `rd_data` | RO (pop) | 0x0 | byte |
| STATUS | 7:0 | `status` | RO | core | the last status byte read (Read Status, and after Program and Erase): bit 6 RDY, bit 0 FAIL |

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

### Programming sequence

1. Release PRESETN. Read ID (0x000) and check it is 0x4F4E0200.
2. Write 0xFF to IRQ_STATUS (0x004) to clear any stale bits.
3. Write IRQ_ENABLE (0x008) with the interrupts to use (bit order as in the Interrupts table; 0xFF enables all).
4. To send on CMD: wait until FLAGS.CMD_FULL (bit 0) is 0, or for IRQ CMD_DONE, then write CMD0 (0x014) then CMD1 (0x018). The last write commits the beat. CMD_OVF means a write came while the register was full and was dropped.
5. To send on WR: wait until FLAGS.WR_FULL (bit 1) is 0, or for IRQ WR_DONE, then write WR (0x01C). The last write commits the beat. WR_OVF means a write came while the register was full and was dropped.
6. To receive on RD: wait for IRQ RD_AVAIL or FLAGS.RD_AVAIL (bit 2), then read RD (0x020). Reading the last word frees the register for the next beat; write 1 to IRQ_STATUS.RD_AVAIL (bit 7) to clear it.
7. Read STATUS (0x024) for the core's live `status`; it needs no clearing.
8. On `irq`: read IRQ_STATUS, handle every bit that is set and enabled, then write those bits back to IRQ_STATUS to clear them. A source that is still active sets its bit again.
<!-- /AUTO:registers -->

## 3. Timing

### 3.1 Command sequences

A command is taken in IDLE (`cmd_valid` with `cmd_ready`); `ce_n` goes low until it ends. The
sequence of each command (A = address cycles: col[7:0], col[15:8], row[7:0], row[15:8],
row[23:16]):

| `cmd_op` | Sequence |
|---|---|
| 0 Reset | FFh, tWB, busy |
| 1 Read ID | 90h, address col[7:0], tWHR, `cmd_len` bytes out |
| 2 Read Status | 70h, tWHR, status byte |
| 3 Read Page | 00h, 5 A, 30h, tWB, busy, tRR, `cmd_len` bytes out |
| 4 Program Page | 80h, 5 A, tADL, `cmd_len` bytes in, 10h, tWB, busy, 70h, tWHR, status byte |
| 5 Erase Block | 60h, 3 A (row bytes), D0h, tWB, busy, 70h, tWHR, status byte |
| 6 Get Features | EEh, address col[7:0], tWB, busy, tRR, 4 bytes out |
| 7 Set Features | EFh, address col[7:0], tADL, 4 bytes in, tWB, busy |

At the end `done` pulses, `ce_n` goes high, and for Program / Erase `ev_fail` = status bit 0.

### 3.2 Bus cycles

* Command / address / data-in: CLE (command) or ALE (address) set, DQ driven, `we_n` low for
  `TP` clocks then high for `TP` clocks, then CLE / ALE drop. There is at least one more clock
  before the next cycle.
* Data-out / status: DQ released, `re_n` low for `TP` clocks; DQ is taken in the clock `re_n`
  rises, then `re_n` high for `TP` clocks.
* Waits: tWB = `TWB`, tWHR = `TWHR`, tADL = `TADL`, tRR = `TRR` clocks at least (one more clock
  to step on).
* Busy: wait for the synchronised `rb_n` = 1. After `TBUSY` clocks low, the command is abandoned:
  `done` and `ev_timeout` pulse, `ce_n` high.

### 3.3 Data streams

A data-in cycle starts only when a byte is offered: `wr_ready` = 1 while the sequence is at the
data-in step with bytes left; the byte is taken with `wr_valid`. A data-out cycle starts only when
the read register is empty (`rd_valid` = 0); the byte stays in `rd_data` with `rd_valid` until
`rd_ready`. So either stream can stall the bus.

### 3.4 Reset

While `rst_n` is low: idle, `ce_n` / `we_n` / `re_n` high, CLE / ALE 0, DQ released, outputs 0.

## 4. Parameters

| Parameter | Default | Meaning |
|---|---|---|
| `TP` | 2 | WE# / RE# low and high time, clocks |
| `TWB` | 6 | tWB, clocks |
| `TWHR` | 8 | tWHR, clocks |
| `TADL` | 10 | tADL, clocks |
| `TRR` | 3 | tRR, clocks |
| `TBUSY` | 2048 | R/B# timeout, clocks (power of 2, above the waits) |
| `LW` | 12 | width of `cmd_len` |

## 5. Errors and corner cases

| Case | Behaviour |
|---|---|
| R/B# low for `TBUSY` clocks | command abandoned, `ev_timeout` |
| Program / Erase status FAIL | `ev_fail` with `done` |
| `cmd_len` = 0 | no data bytes moved |
| host stalls a stream | the bus waits between cycles |

## 6. TB check map

Messages are printed by `tb/ONFI_tb.sv` as `ERROR: <message>`. Assertions `a_*` are in the bound
checker `tb/cov/ONFI_sva.sv`. The target model decodes every cycle and checks the pin rules; the
host model keeps a reference array and checks every byte, status and event.

| Check (TB message or assertion) | What it requires | Spec |
|---|---|---|
| "CLE and ALE together" | never both | §3.2 |
| "WE# and RE# low together" | never both | §3.2 |
| "WE# / RE# low with CE# high" | CE# low around cycles | §3.1 |
| "WE# low with DQ not driven" | DQ driven on writes | §3.2 |
| "RE# low with DQ driven" | DQ released on reads | §3.2 |
| "WE# high too short" | `TP` | §3.2 |
| "WE# low too short" | `TP` | §3.2 |
| "RE# high too short" | `TP` | §3.2 |
| "RE# low too short" | `TP` | §3.2 |
| "tWHR" | tWHR | §3.2 |
| "tRR" | tRR | §3.2 |
| "RE# while busy" | no reads while busy | §3.2 |
| "cycle while busy" | no cycles while busy | §3.2 |
| "30h after" | Read Page sequence | §3.1 |
| "10h out of place" | Program sequence | §3.1 |
| "D0h out of place" | Erase sequence | §3.1 |
| "unknown command" | opcodes | §3.1 |
| "too many address cycles" | address counts | §3.1 |
| "address cycle out of place" | address order | §3.1 |
| "tADL" | tADL | §3.2 |
| "data-in cycle out of place" | data-in step | §3.1 |
| "write bytes left over" | exactly the bytes asked | §3.3 |
| "status after two Read Status" | status | §3.1 |
| "target errors" | no target-side errors | §3 |
| "RE# with nothing to read" | reads only in data steps | §3.1 |
| a_pins | pins as the model | §3.2 |
| a_host | host handshakes as the model | §3.3 |
| a_read | read bytes as the model | §3.3 |
| a_done | `done` / events as the model | §3.1, §3.2 |
| a_reset | reset values | §3.4 |
