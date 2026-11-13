<!-- SPDX-License-Identifier: Apache-2.0 -->
# ATB: design specification

CoreSight ATB (AMBA trace bus) sink, simplified: `atvalid`/`atready` beats with a 7-bit trace
ID are captured into a 16-entry buffer that fills once (it empties only on a flush or reset), a
flush request (`afvalid`) with an ID different from the current capture ID empties the buffer
and switches to that ID, and a beat with `atlast` raises a one-clock interrupt and records its
ID. Core `ATB_top` (`rtl/ATB_top.sv`), testbench `tb/ATB_tb.sv`, checker `tb/cov/ATB_sva.sv`.

Conventions on this page: every flop is clocked on the rising edge of `clk` and reset
asynchronously by `rst_n` low. A *push* is a clock with `atvalid` = `atready` = 1; a *flush* is a
clock with `afvalid` = 1 and `atid` ≠ `cur_id`. Both take effect at the edge that ends the
clock.

## 1. Interface

| Port | Dir | Width | Meaning | Active | Clock | Reset |
|---|---|---|---|---|---|---|
| `clk` | input | 1 | core clock | rising edge | - | - |
| `rst_n` | input | 1 | asynchronous reset of `wr_ptr`, `cur_id`, `last_id` (buffer contents are not reset) | low | async assert | - |
| `atvalid` | input | 1 | trace source has a beat | high | clk | - |
| `atready` | output | 1 | `wr_ptr < DEPTH && !flush` (combinational): room left and no flush this clock | high | comb. | 1 (with `afvalid` low) |
| `atdata` | input | `DW` | beat data | - | clk | - |
| `atid` | input | 7 | trace source ID of the beat; also the new capture ID in a flush | - | clk | - |
| `atlast` | input | 1 | last beat of a packet: drives `irq` and updates `last_id` | high | clk | - |
| `afvalid` | input | 1 | flush request; acts only when `atid` ≠ `cur_id` | high | clk | - |
| `afready` | output | 1 | always 1 (flush always accepted) | high | - | 1 |
| `ren` | input | 1 | read strobe; unused (reads have no side effect) | high | - | - |
| `raddr` | input | 4 | slot to read, 0..15 | - | comb. | - |
| `rdata` | output | `DW` | contents of slot `raddr`, combinational; not reset | - | comb. | not reset |
| `count` | output | 5 | beats stored = `wr_ptr`, 0..`DEPTH` | - | clk | 0 |
| `last_id` | output | 7 | `atid` of the last pushed beat that had `atlast` | - | clk | 0 |
| `irq` | output | 1 | `atvalid && atready && atlast` (combinational): high in the clock of a push of a last beat | high | comb. | 0 |

### Internal signals used by the verification

| Signal | Width | Meaning |
|---|---|---|
| `wr_ptr` | 5 | write pointer = beats stored (TB reads it by name) |
| `cur_id` | 7 | current capture ID, set by a flush, reset to 0; the TB computes `flush = afvalid && atid != cur_id` from it |

## 2. Registers

Local read port: `raddr` 0..15 reads buffer slot 0..15; `count`, `last_id` and `irq` are
outputs. The APB4 wrapper `ATB_apb` maps them onto the registers below.

<!-- AUTO:registers -->
Generated from [`docs/ip/ATB.md`](../ip/ATB.md) (source: `scripts/apb/specs/ATB.json`); do not edit by hand.

`ATB_apb` is an APB4 slave (AMBA APB protocol v2.0): zero wait states, 32-bit data, 12-bit byte address, PSTRB byte lanes on every writable register, PSLVERR on an unmapped or misaligned address (reads then return 0, writes are dropped). Writes to read-only registers are ignored without an error. The core runs on PCLK and PRESETN. `irq` is level-high: `|(IRQ_STATUS & IRQ_ENABLE)`.

Pass-through pins: `atvalid`, `atready`, `atdata`, `atid`, `atlast`, `afvalid`, `afready`.

### Register map

| Offset | Name | Access | Reset | Description |
|---|---|---|---|---|
| 0x000 | ID | RO | 0x41540200 | IP identification: code, major and minor version |
| 0x004 | IRQ_STATUS | W1C | 0x00000000 | Sticky interrupt bits, write 1 to clear |
| 0x008 | IRQ_ENABLE | RW | 0x00000000 | Interrupt enables; irq = \|(IRQ_STATUS & IRQ_ENABLE) |
| 0x00C | FLAGS | RO | 0x00000000 | Stream holding-register state |
| 0x010 | SCRATCH | RW | 0x00000000 | Scratch register, no effect on the core |
| 0x014 | STATUS | RO | core | Capture buffer state |
| 0x018 | D0 | RO (core) | core | Capture buffer entry 0 |
| 0x01C | D1 | RO (core) | core | Capture buffer entry 1 |
| 0x020 | D2 | RO (core) | core | Capture buffer entry 2 |
| 0x024 | D3 | RO (core) | core | Capture buffer entry 3 |
| 0x028 | D4 | RO (core) | core | Capture buffer entry 4 |
| 0x02C | D5 | RO (core) | core | Capture buffer entry 5 |
| 0x030 | D6 | RO (core) | core | Capture buffer entry 6 |
| 0x034 | D7 | RO (core) | core | Capture buffer entry 7 |
| 0x038 | D8 | RO (core) | core | Capture buffer entry 8 |
| 0x03C | D9 | RO (core) | core | Capture buffer entry 9 |
| 0x040 | D10 | RO (core) | core | Capture buffer entry 10 |
| 0x044 | D11 | RO (core) | core | Capture buffer entry 11 |
| 0x048 | D12 | RO (core) | core | Capture buffer entry 12 |
| 0x04C | D13 | RO (core) | core | Capture buffer entry 13 |
| 0x050 | D14 | RO (core) | core | Capture buffer entry 14 |
| 0x054 | D15 | RO (core) | core | Capture buffer entry 15 |

Unlisted bits read 0 and ignore writes. Reset "core": the register reads the core's outputs directly, so after reset it shows the core's own reset state. WO (pulse) registers read 0. Offsets from 0x058 up to 0xFFC are unmapped (PSLVERR).

### Fields

| Register | Bits | Field | Access | Reset | Description |
|---|---|---|---|---|---|
| ID | 31:16 | CODE | RO | 0x4154 | IP code |
| ID | 15:8 | MAJOR | RO | 0x02 | major version |
| ID | 7:0 | MINOR | RO | 0x00 | minor version |
| IRQ_STATUS | 0 | one bit per interrupt | W1C | 0x0 | see Interrupts |
| IRQ_ENABLE | 0 | one bit per interrupt | RW | 0x0 | 1 enables the IRQ_STATUS bit onto `irq` |
| SCRATCH | 31:0 | SCRATCH | RW | 0x00000000 | free for software |
| STATUS | 4:0 | `count` | RO | core | beats captured since the last flush (16: full, atready low) |
| STATUS | 11:5 | `last_id` | RO | core | ATID of the last beat accepted with atlast |
| D0 | 31:0 | core register | RO (core) | core | read from core register 0 |
| D1 | 31:0 | core register | RO (core) | core | read from core register 1 |
| D2 | 31:0 | core register | RO (core) | core | read from core register 2 |
| D3 | 31:0 | core register | RO (core) | core | read from core register 3 |
| D4 | 31:0 | core register | RO (core) | core | read from core register 4 |
| D5 | 31:0 | core register | RO (core) | core | read from core register 5 |
| D6 | 31:0 | core register | RO (core) | core | read from core register 6 |
| D7 | 31:0 | core register | RO (core) | core | read from core register 7 |
| D8 | 31:0 | core register | RO (core) | core | read from core register 8 |
| D9 | 31:0 | core register | RO (core) | core | read from core register 9 |
| D10 | 31:0 | core register | RO (core) | core | read from core register 10 |
| D11 | 31:0 | core register | RO (core) | core | read from core register 11 |
| D12 | 31:0 | core register | RO (core) | core | read from core register 12 |
| D13 | 31:0 | core register | RO (core) | core | read from core register 13 |
| D14 | 31:0 | core register | RO (core) | core | read from core register 14 |
| D15 | 31:0 | core register | RO (core) | core | read from core register 15 |

### Interrupts (IRQ_STATUS, IRQ_ENABLE)

A bit is set while its source is active, stays set until written with 1, and a set in the same clock as the clear wins.

| Bit | Name | Set when |
|---|---|---|
| 0 | LAST | a beat with atlast was accepted |

### Core register port

The CORE words reach the core's own register port. A write to one pulses A read drives `raddr` (the core register) and pulses `ren` during the access phase and returns `rdata`.

### Programming sequence

1. Release PRESETN. Read ID (0x000) and check it is 0x41540200.
2. Write 0x1 to IRQ_STATUS (0x004) to clear any stale bits.
3. Write IRQ_ENABLE (0x008) with the interrupts to use (bit order as in the Interrupts table; 0x1 enables all).
4. Read STATUS (0x014) for the core's live `count`, `last_id`; it needs no clearing.
5. Access the core's registers through the CORE words (0x018 onward), one word per core register.
6. On `irq`: read IRQ_STATUS, handle every bit that is set and enabled, then write those bits back to IRQ_STATUS to clear them. A source that is still active sets its bit again.
<!-- /AUTO:registers -->

## 3. Timing

- **Flush**: `flush = afvalid && (atid != cur_id)`. In a flush clock `atready` = 0, so no beat
  is taken and no `irq` is raised; at the edge `wr_ptr <= 0` and `cur_id <= atid`. `last_id`
  and the buffer contents are unchanged. `afvalid` with `atid` = `cur_id` does nothing.
- **Ready**: `atready = (wr_ptr < DEPTH) && !flush`, no dependence on `atvalid`.
- **Push** (no flush): `atdata` is written to slot `wr_ptr`, `wr_ptr` increments; if `atlast`,
  `last_id <= atid`. Pushes can happen every clock; beats need not carry `cur_id` (the ID
  only matters for flushes and `last_id`).
- **Full**: after DEPTH pushes `atready` = 0 until a flush or reset; beats offered are not
  taken.
- **Count** = `wr_ptr`: +1 per push, back to 0 at a flush, otherwise constant.
- **Interrupt**: `irq` is high in the clock of a push with `atlast`.
- **Read**: `rdata = mem[raddr]`, combinational, no side effect.
- **Reset**: `wr_ptr` = 0, `cur_id` = 0, `last_id` = 0 at once; data is kept.

## 4. Parameters

| Parameter | Default | Legal range | Effect |
|---|---|---|---|
| `DW` | 32 | ≥ 1 | width of `atdata` and `rdata` |
| `DEPTH` | 16 | 1 .. 16 (slot index 4 bits, `count` 5 bits) | buffer slots |

## 5. Errors and corner cases

| Case | Behaviour |
|---|---|
| beat offered in a flush clock | not acknowledged (`atready` = 0), no `irq` |
| flush with the current ID | ignored, buffer kept |
| flush of an empty buffer | `count` stays 0, `cur_id` changes |
| buffer full | beats refused until a flush or reset |
| ID change on beats without `afvalid` | no flush; beats are stored with any ID |

## 6. TB check map

Messages are printed by `tb/ATB_tb.sv` as `ERROR: <message>`; messages starting "CRV" and the
immediate checks A1..A7 are built only for Verilator. Assertions a_* are in `tb/cov/ATB_sva.sv`.

| Check (TB message or assertion) | What it requires | Spec |
|---|---|---|
| "ATB count" | 4 beats with ID 0x12: `count` = 4 | §3 Push |
| "ATB irq never fired" | the last beat raised `irq` | §3 Interrupt |
| "ATB last_id" | `last_id` = 0x12 | §3 Push |
| "ATB mem[" | slots 0..3 read back in order | §3 Read |
| "ATB flush count" | a flush with a new ID empties the buffer; a flush of an empty buffer keeps `count` 0 and `last_id` | §3 Flush |
| "ATB same-ID flush emptied the buffer" | `afvalid` with the current ID does nothing | §3 Flush, §5 |
| "ATB beat acked in flush cycle" | in a flush clock `atready` = 0 and `irq` = 0 | §3 Flush, §5 |
| "ATB fill-16 count" | 16 back-to-back pushes: `count` 16, slot 0 = first beat | §3 Push, Full |
| "data class slot" | all-zero, all-one, alternating beats with IDs 0 / 0x7F read back | §3 Read |
| "CRV count" | `count` = beats pushed | §3 Count |
| "CRV last_id" | `last_id` = ID of the last `atlast` beat | §3 Push |
| "CRV atready high while full" | full → `atready` = 0 | §3 Full |
| "CRV full FIFO accepted a beat" | full → `count` unchanged | §3 Full |
| "CRV flush count" | a flush with a new nonzero ID empties the buffer | §3 Flush |
| "CRV mem[" | captured beats read back | §3 Read |
| "A1 reset: count zero" | `count` = 0 in reset | §3 Reset |
| "A2 count within depth" | `count` ≤ 16 | §3 Count |
| "A3 atready == not full and not flushing" | `atready` = (`count` < 16) && !(afvalid && `atid` ≠ `cur_id`) | §3 Ready, Flush |
| "A4 irq == push&atlast" | `irq` only on a push with `atlast` | §3 Interrupt |
| "A5 count +1 or flush-to-0" | `count` changes only by +1 or to 0 | §3 Count |
| "A6 afready constant high" | `afready` = 1 | §1 |
| "A7 full: only flush changes count" | while not ready, `count` changes only to 0 | §3 Full |
| a_reset_empty | in reset `count` = 0 and `last_id` = 0 | §3 Reset |
| a_flush_always_ready | `afready` always 1 | §1 |
| a_ready_model | `atready` = room && !flush | §3 Ready |
| a_count_model | `count` equals the model | §3 Count |
| a_last_id_model | `last_id` equals the model | §3 Push |
| a_irq_on_last | `irq` = push && `atlast` | §3 Interrupt |
| a_read_model | written slots read back | §3 Read |
| a_flush_empties | after a flush `count` = 0 | §3 Flush |
