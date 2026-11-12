<!-- SPDX-License-Identifier: Apache-2.0 -->
# AXI_Stream: design specification

AXI4-Stream sink that captures beats into a 16-entry buffer: `tvalid`/`tready` handshake, the buffer fills
once and is not drained (it empties only on reset), any slot can be read back at any time, and a
beat with `tlast` raises a one-clock interrupt. Core `AXI_Stream_top` (`rtl/AXI_Stream_top.sv`), testbench
`tb/AXI_Stream_tb.sv`, checker `tb/cov/AXI_Stream_sva.sv`.

Conventions on this page: every flop is clocked on the rising edge of `clk` and reset
asynchronously by `rst_n` low. A *push* is a clock in which `tvalid` = 1 and `tready` = 1; it takes
effect at the rising edge that ends that clock.

## 1. Interface

| Port | Dir | Width | Meaning | Active | Clock | Reset |
|---|---|---|---|---|---|---|
| `clk` | input | 1 | core clock | rising edge | - | - |
| `rst_n` | input | 1 | asynchronous reset of the write pointer (the buffer contents are not reset) | low | async assert | - |
| `tvalid` | input | 1 | source has a beat | high | clk | - |
| `tready` | output | 1 | buffer has room: `wr_ptr < DEPTH` (combinational from the pointer, independent of `tvalid`) | high | clk | 1 |
| `tdata` | input | `DW` | beat data, stored at a push | - | clk | - |
| `tlast` | input | 1 | last beat of a packet; only drives `irq` | high | clk | - |
| `ren` | input | 1 | read strobe; unused (`rdata` is valid regardless of `ren`, reads have no side effect) | high | - | - |
| `raddr` | input | 4 | slot to read, 0..15 | - | comb. | - |
| `rdata` | output | `DW` | contents of slot `raddr`, combinational; a slot never written since power-up reads X (the buffer is not reset) | - | comb. | not reset |
| `count` | output | 5 | beats stored: equal to `wr_ptr`, 0..`DEPTH` | - | clk | 0 |
| `irq` | output | 1 | `tvalid && tready && tlast` (combinational): high in the clock of a push of a last beat | high | comb. | 0 |

### Internal signals used by the verification

| Signal | Width | Meaning |
|---|---|---|
| `wr_ptr` | 5 | write pointer = number of beats stored (the TB reads it by name) |

## 2. Registers

Local read port of the core: `raddr` 0..15 reads buffer slot 0..15; `count` and `irq` are
separate outputs. The APB4 wrapper `AXI_Stream_apb` maps these onto the registers below.

<!-- AUTO:registers -->
Generated from [`docs/ip/AXI_Stream.md`](../ip/AXI_Stream.md) (source: `scripts/apb/specs/AXI_Stream.json`); do not edit by hand.

`AXI_Stream_apb` is an APB4 slave (AMBA APB protocol v2.0): zero wait states, 32-bit data, 12-bit byte address, PSTRB byte lanes on every writable register, PSLVERR on an unmapped or misaligned address (reads then return 0, writes are dropped). Writes to read-only registers are ignored without an error. The core runs on PCLK and PRESETN. `irq` is level-high: `|(IRQ_STATUS & IRQ_ENABLE)`.

Pass-through pins: `tvalid`, `tready`, `tdata`, `tlast`.

### Register map

| Offset | Name | Access | Reset | Description |
|---|---|---|---|---|
| 0x000 | ID | RO | 0x41530200 | IP identification: code, major and minor version |
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
| ID | 31:16 | CODE | RO | 0x4153 | IP code |
| ID | 15:8 | MAJOR | RO | 0x02 | major version |
| ID | 7:0 | MINOR | RO | 0x00 | minor version |
| IRQ_STATUS | 0 | one bit per interrupt | W1C | 0x0 | see Interrupts |
| IRQ_ENABLE | 0 | one bit per interrupt | RW | 0x0 | 1 enables the IRQ_STATUS bit onto `irq` |
| SCRATCH | 31:0 | SCRATCH | RW | 0x00000000 | free for software |
| STATUS | 4:0 | `count` | RO | core | beats captured (16: full, tready low until reset) |
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
| 0 | LAST | a beat with tlast was accepted |

### Core register port

The CORE words reach the core's own register port. A write to one pulses A read drives `raddr` (the core register) and pulses `ren` during the access phase and returns `rdata`.

### Programming sequence

1. Release PRESETN. Read ID (0x000) and check it is 0x41530200.
2. Write 0x1 to IRQ_STATUS (0x004) to clear any stale bits.
3. Write IRQ_ENABLE (0x008) with the interrupts to use (bit order as in the Interrupts table; 0x1 enables all).
4. Read STATUS (0x014) for the core's live `count`; it needs no clearing.
5. Access the core's registers through the CORE words (0x018 onward), one word per core register.
6. On `irq`: read IRQ_STATUS, handle every bit that is set and enabled, then write those bits back to IRQ_STATUS to clear them. A source that is still active sets its bit again.
<!-- /AUTO:registers -->

## 3. Timing

- **Ready**: `tready = (wr_ptr < DEPTH)`. It is 1 from reset until the DEPTH-th push and 0 after it,
  until the next reset. It does not depend on `tvalid` (no combinational path from valid to ready).
- **Push**: at the rising edge that ends a clock with `tvalid` = `tready` = 1, `tdata` is written to
  slot `wr_ptr` and `wr_ptr` increments. Back-to-back pushes are accepted every clock. A beat
  offered while `tready` = 0 is not taken and does not change anything.
- **Count**: `count = wr_ptr`, so it increases by one at each push edge, never decreases, and
  stops at DEPTH.
- **Interrupt**: `irq` is high exactly in the clock of a push whose `tlast` = 1 (combinational,
  so it is visible before the edge and falls after it). A last beat offered while full gives no
  `irq`.
- **Read**: `rdata = mem[raddr]`, combinational; a slot reads the beat written into it as soon as
  the push edge has passed. Reading does not remove anything.
- **Reset**: `wr_ptr` = 0 at once, so `count` = 0, `tready` = 1, `irq` = 0 (while `tvalid` is low). The
  stored data is kept and still readable; the next pushes overwrite slots from 0.

## 4. Parameters

| Parameter | Default | Legal range | Effect |
|---|---|---|---|
| `DW` | 32 | ≥ 1 | width of `tdata` and `rdata` |
| `DEPTH` | 16 | 1 .. 16 (`raddr` and the slot index are 4 bits, `count` 5 bits) | number of slots; `tready` falls after DEPTH pushes |

## 5. Errors and corner cases

| Case | Behaviour |
|---|---|
| buffer full | `tready` = 0; further beats are refused (not dropped silently: the source must wait), `count` stays DEPTH |
| last beat refused while full | no `irq` |
| read of a slot not yet written | returns the old contents (X after power-up) |
| `tlast` on every beat | one `irq` pulse per push |
| reset | empties the pointer, keeps the data |

## 6. TB check map

Messages are printed by `tb/AXI_Stream_tb.sv` as `ERROR: <message>`; messages starting "CRV" and the
immediate checks A1.. are built only for Verilator. Assertions a_* are in `tb/cov/AXI_Stream_sva.sv`.

| Check (TB message or assertion) | What it requires | Spec |
|---|---|---|
| "AXIS tready dropped mid-beat" | with room left, `tready` is still 1 right after a push | §3 Ready |
| "AXIS count" | after 5 beats `count` = 5 | §3 Count |
| "AXIS irq never fired" | the beat with `tlast` raised `irq` | §3 Interrupt |
| "AXIS mem[" | slots 0..4 read back the 5 beats in order | §3 Read |
| "fill-16 count" | 16 back-to-back pushes: `count` = 16, slot 0 = first beat | §3 Push, Read |
| "data class slot" | all-zero, all-one and alternating beats read back after a reset | §3 Read, Reset |
| "CRV count" | `count` = beats pushed since reset | §3 Count |
| "CRV tready high while full" | after 16 pushes `tready` = 0 | §3 Ready |
| "CRV full FIFO accepted a beat" | a beat offered while full does not change `count` | §5 |
| "CRV mem[" | every pushed beat reads back from its slot | §3 Read |
| "A1 reset: count zero" | `count` = 0 in reset | §3 Reset |
| "A2 count within depth" | `count` ≤ 16 | §3 Count |
| "A3 tready == not full" | `tready` = (`count` < 16) | §3 Ready |
| "A4 irq == push&tlast" | `irq` only in a push clock with `tlast` | §3 Interrupt |
| "A5 count steps by <=1" | `count` changes by 0 or +1 per clock | §3 Count |
| "A6 count changes only via push" | `count` changes only after a clock with `tready` = 1 | §3 Push |
| a_reset_empty | in reset: `count` = 0, `tready` = 1 | §3 Reset |
| a_ready_not_full | `tready` = (count < DEPTH) | §3 Ready |
| a_count_model | `count` equals the model's push count | §3 Count |
| a_irq_on_last | `irq` = push && `tlast` | §3 Interrupt |
| a_read_model | a read of a written slot returns the model's beat | §3 Read |
| a_full_holds | once full, `count` stays DEPTH and `tready` stays 0 | §3 Ready, §5 |
