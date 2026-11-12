<!-- SPDX-License-Identifier: Apache-2.0 -->
# Avalon_ST: design specification

Avalon-ST sink that captures beats into a 16-entry buffer: `av_valid`/`av_ready` handshake, the buffer fills
once and is not drained (it empties only on reset), any slot can be read back at any time, and a
beat with `av_eop` raises a one-clock interrupt. Core `Avalon_ST_top` (`rtl/Avalon_ST_top.sv`), testbench
`tb/Avalon_ST_tb.sv`, checker `tb/cov/Avalon_ST_sva.sv`.

Conventions on this page: every flop is clocked on the rising edge of `clk` and reset
asynchronously by `rst_n` low. A *push* is a clock in which `av_valid` = 1 and `av_ready` = 1; it takes
effect at the rising edge that ends that clock.

## 1. Interface

| Port | Dir | Width | Meaning | Active | Clock | Reset |
|---|---|---|---|---|---|---|
| `clk` | input | 1 | core clock | rising edge | - | - |
| `rst_n` | input | 1 | asynchronous reset of the write pointer (the buffer contents are not reset) | low | async assert | - |
| `av_valid` | input | 1 | source has a beat | high | clk | - |
| `av_ready` | output | 1 | buffer has room: `wr_ptr < DEPTH` (combinational from the pointer, independent of `av_valid`) | high | clk | 1 |
| `av_data` | input | `DW` | beat data, stored at a push | - | clk | - |
| `av_eop` | input | 1 | last beat of a packet; only drives `irq` | high | clk | - |
| `ren` | input | 1 | read strobe; unused (`rdata` is valid regardless of `ren`, reads have no side effect) | high | - | - |
| `raddr` | input | 4 | slot to read, 0..15 | - | comb. | - |
| `rdata` | output | `DW` | contents of slot `raddr`, combinational; a slot never written since power-up reads X (the buffer is not reset) | - | comb. | not reset |
| `count` | output | 5 | beats stored: equal to `wr_ptr`, 0..`DEPTH` | - | clk | 0 |
| `irq` | output | 1 | `av_valid && av_ready && av_eop` (combinational): high in the clock of a push of a last beat | high | comb. | 0 |

### Internal signals used by the verification

| Signal | Width | Meaning |
|---|---|---|
| `wr_ptr` | 5 | write pointer = number of beats stored (the TB reads it by name) |

## 2. Registers

Local read port of the core: `raddr` 0..15 reads buffer slot 0..15; `count` and `irq` are
separate outputs. The APB4 wrapper `Avalon_ST_apb` maps these onto the registers below.

<!-- AUTO:registers -->
Generated from [`docs/ip/Avalon_ST.md`](../ip/Avalon_ST.md) (source: `scripts/apb/specs/Avalon_ST.json`); do not edit by hand.

`Avalon_ST_apb` is an APB4 slave (AMBA APB protocol v2.0): zero wait states, 32-bit data, 12-bit byte address, PSTRB byte lanes on every writable register, PSLVERR on an unmapped or misaligned address (reads then return 0, writes are dropped). Writes to read-only registers are ignored without an error. The core runs on PCLK and PRESETN. `irq` is level-high: `|(IRQ_STATUS & IRQ_ENABLE)`.

Pass-through pins: `av_valid`, `av_ready`, `av_data`, `av_eop`.

### Register map

| Offset | Name | Access | Reset | Description |
|---|---|---|---|---|
| 0x000 | ID | RO | 0x41760200 | IP identification: code, major and minor version |
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
| ID | 31:16 | CODE | RO | 0x4176 | IP code |
| ID | 15:8 | MAJOR | RO | 0x02 | major version |
| ID | 7:0 | MINOR | RO | 0x00 | minor version |
| IRQ_STATUS | 0 | one bit per interrupt | W1C | 0x0 | see Interrupts |
| IRQ_ENABLE | 0 | one bit per interrupt | RW | 0x0 | 1 enables the IRQ_STATUS bit onto `irq` |
| SCRATCH | 31:0 | SCRATCH | RW | 0x00000000 | free for software |
| STATUS | 4:0 | `count` | RO | core | beats captured (16: full, av_ready low until reset) |
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
| 0 | LAST | a beat with av_eop was accepted |

### Core register port

The CORE words reach the core's own register port. A write to one pulses A read drives `raddr` (the core register) and pulses `ren` during the access phase and returns `rdata`.

### Programming sequence

1. Release PRESETN. Read ID (0x000) and check it is 0x41760200.
2. Write 0x1 to IRQ_STATUS (0x004) to clear any stale bits.
3. Write IRQ_ENABLE (0x008) with the interrupts to use (bit order as in the Interrupts table; 0x1 enables all).
4. Read STATUS (0x014) for the core's live `count`; it needs no clearing.
5. Access the core's registers through the CORE words (0x018 onward), one word per core register.
6. On `irq`: read IRQ_STATUS, handle every bit that is set and enabled, then write those bits back to IRQ_STATUS to clear them. A source that is still active sets its bit again.
<!-- /AUTO:registers -->

## 3. Timing

- **Ready**: `av_ready = (wr_ptr < DEPTH)`. It is 1 from reset until the DEPTH-th push and 0 after it,
  until the next reset. It does not depend on `av_valid` (no combinational path from valid to ready).
- **Push**: at the rising edge that ends a clock with `av_valid` = `av_ready` = 1, `av_data` is written to
  slot `wr_ptr` and `wr_ptr` increments. Back-to-back pushes are accepted every clock. A beat
  offered while `av_ready` = 0 is not taken and does not change anything.
- **Count**: `count = wr_ptr`, so it increases by one at each push edge, never decreases, and
  stops at DEPTH.
- **Interrupt**: `irq` is high exactly in the clock of a push whose `av_eop` = 1 (combinational,
  so it is visible before the edge and falls after it). A last beat offered while full gives no
  `irq`.
- **Read**: `rdata = mem[raddr]`, combinational; a slot reads the beat written into it as soon as
  the push edge has passed. Reading does not remove anything.
- **Reset**: `wr_ptr` = 0 at once, so `count` = 0, `av_ready` = 1, `irq` = 0 (while `av_valid` is low). The
  stored data is kept and still readable; the next pushes overwrite slots from 0.

## 4. Parameters

| Parameter | Default | Legal range | Effect |
|---|---|---|---|
| `DW` | 32 | ≥ 1 | width of `av_data` and `rdata` |
| `DEPTH` | 16 | 1 .. 16 (`raddr` and the slot index are 4 bits, `count` 5 bits) | number of slots; `av_ready` falls after DEPTH pushes |

## 5. Errors and corner cases

| Case | Behaviour |
|---|---|
| buffer full | `av_ready` = 0; further beats are refused (not dropped silently: the source must wait), `count` stays DEPTH |
| last beat refused while full | no `irq` |
| read of a slot not yet written | returns the old contents (X after power-up) |
| `av_eop` on every beat | one `irq` pulse per push |
| reset | empties the pointer, keeps the data |

## 6. TB check map

Messages are printed by `tb/Avalon_ST_tb.sv` as `ERROR: <message>`; messages starting "CRV" and the
immediate checks A1.. are built only for Verilator. Assertions a_* are in `tb/cov/Avalon_ST_sva.sv`.

| Check (TB message or assertion) | What it requires | Spec |
|---|---|---|
| "Avalon-ST count" | after 4 beats `count` = 4 | §3 Count |
| "Avalon-ST irq never fired" | the beat with `av_eop` raised `irq` | §3 Interrupt |
| "Avalon-ST mem[" | slots 0..3 read back the 4 beats in order | §3 Read |
| "fill-16 count" | 16 back-to-back pushes: `count` = 16, slot 0 = first beat | §3 Push, Read |
| "data class slot" | all-zero, all-one and alternating beats read back after a reset | §3 Read, Reset |
| "CRV ready timeout t" | `av_ready` comes back after reset | §3 Ready, Reset |
| "CRV irq t" | `irq` in the push clock equals (last beat && ready) | §3 Interrupt |
| "CRV count t" | `count` = beats pushed since reset | §3 Count |
| "CRV irq never fired t" | each packet's last beat raised `irq` | §3 Interrupt |
| "CRV ready high when full t" | after 16 pushes `av_ready` = 0 | §3 Ready |
| "CRV count changed by overflow t" | beats offered while full do not change `count` | §5 |
| "CRV mem[" | every pushed beat reads back from its slot | §3 Read |
| "A1 reset: count 0, ready, no irq" | in reset `count` = 0, `av_ready` = 1, `irq` = 0 | §3 Reset |
| "A2 ready == !full" | `av_ready` = (`wr_ptr` < 16) | §3 Ready |
| "A3 count == wr_ptr" | `count` = `wr_ptr` | §1, §3 Count |
| "A4 irq == eop write" | `irq` = `av_valid` && `av_ready` && `av_eop` | §3 Interrupt |
| "A5 wr_ptr <= DEPTH" | `wr_ptr` never exceeds 16 | §3 Count |
| a_reset_empty | in reset: `count` = 0, `av_ready` = 1 | §3 Reset |
| a_ready_not_full | `av_ready` = (count < DEPTH) | §3 Ready |
| a_count_model | `count` equals the model's push count | §3 Count |
| a_irq_on_last | `irq` = push && `av_eop` | §3 Interrupt |
| a_read_model | a read of a written slot returns the model's beat | §3 Read |
| a_full_holds | once full, `count` stays DEPTH and `av_ready` stays 0 | §3 Ready, §5 |
