<!-- SPDX-License-Identifier: Apache-2.0 -->
# Timer_WDT: design specification

System timer and watchdog of the phone SoC. A prescaler makes a tick every `prescale` + 1
clocks; `count` is a free-running 32-bit tick counter. The timer raises a one-clock event every
`period` + 1 ticks and can write `count` at that event as a 32-bit timestamp record into a ring
buffer in memory over an AXI4 manager port. The watchdog counts ticks down from `wdt_load`; a
missed kick first barks (interrupt), and a second miss bites (`wdt_reset`). Core
`Timer_WDT_top` (`rtl/Timer_WDT_top.sv`, uses `rtl/soc_ss_axi_engine.sv`), testbench
`tb/Timer_WDT_tb.sv` (with the AXI memory model `tb/soc_ss_axi_mem.svh`); no core checker.

Conventions on this page: every flop is clocked on the rising edge of `clk` and reset
asynchronously by `rst_n` low. Configuration inputs are levels driven from the APB wrapper's
registers; outputs marked "comb." are combinational from flops and inputs in the same clock.

## 1. Interface

| Port | Dir | Width | Meaning | Active | Clock | Reset |
|---|---|---|---|---|---|---|
| `clk` | input | 1 | core clock | rising edge | - | - |
| `rst_n` | input | 1 | asynchronous reset of every flop | low | async assert | - |
| `prescale` | input | 16 | tick every `prescale` + 1 clocks (0 = every clock) | - | clk | - |
| `tmr_en` | input | 1 | timer enable; 0 holds the timer count at 0 | high | clk | - |
| `period` | input | 32 | timer event every `period` + 1 ticks | - | clk | - |
| `ts_en` | input | 1 | write a timestamp record at each timer event | high | clk | - |
| `ts_base` | input | 32 | byte address of the record ring (word aligned; bits 1:0 ignored) | - | clk | - |
| `ts_words` | input | 16 | ring size in 32-bit words; 0 = no records | - | clk | - |
| `wdt_en` | input | 1 | watchdog enable; 0 holds the watchdog loaded and clears bark/bite | high | clk | - |
| `wdt_load` | input | 32 | watchdog reload value, in ticks | - | clk | - |
| `kick` | input | 1 | reload the watchdog (a one-clock pulse from CMD.kick); also clears bark/bite state | high | clk | - |
| `count` | output | 32 | free-running tick counter, wraps at 2^32 | - | clk | 0 |
| `ts_wp` | output | 16 | records written (completed AXI writes), wraps at 2^16 | - | clk | 0 |
| `ts_missed` | output | 16 | timer events with records enabled that found the writer busy; saturates at 0xFFFF | - | clk | 0 |
| `wdt_count` | output | 32 | watchdog down-counter | - | clk | 0 |
| `wdt_reset` | output | 1 | bite: reset request to the power manager; a level, held until `kick` or `wdt_en` = 0 | high | clk | 0 |
| `tmr_irq` | output | 1 | timer event, one clock (comb.: `tmr_en && tick && tcnt >= period`) | high | comb. | 0 |
| `bark` | output | 1 | watchdog first timeout, one clock (comb.: `wdt_en && tick && wdt_count == 0 && !barked && !kick`) | high | comb. | 0 |
| `ts_err` | output | 1 | one-clock pulse when a record write completed with an AXI error response | high | clk | 0 |
| `m_awid` | output | 4 | AXI write ID = `AXI_ID` | - | clk | `AXI_ID` |
| `m_awaddr` | output | 32 | record address `ts_base + 4 * slot` | - | clk | 0 |
| `m_awlen` | output | 8 | 0 (single beat) | - | clk | - |
| `m_awsize` | output | 3 | 2 (4 bytes) | - | clk | 2 |
| `m_awburst` | output | 2 | 1 (INCR) | - | clk | 1 |
| `m_awprot` | output | 3 | 0 | - | clk | 0 |
| `m_awvalid` | output | 1 | AW valid | high | clk | 0 |
| `m_awready` | input | 1 | AW ready | high | clk | - |
| `m_wdata` | output | 32 | the record (value of `count` at the event) | - | clk | - |
| `m_wstrb` | output | 4 | 0xF | - | clk | 0xF |
| `m_wlast` | output | 1 | 1 with the (only) W beat | high | clk | 0 |
| `m_wvalid` | output | 1 | W valid | high | clk | 0 |
| `m_wready` | input | 1 | W ready | high | clk | - |
| `m_bid` | input | 4 | B ID (ignored) | - | clk | - |
| `m_bresp` | input | 2 | B response; anything but OKAY (0) is an error | - | clk | - |
| `m_bvalid` | input | 1 | B valid | high | clk | - |
| `m_bready` | output | 1 | B ready (high while waiting for the response) | high | clk | 0 |
| `m_arid` | output | 4 | `AXI_ID`; the read channel is never used | - | - | `AXI_ID` |
| `m_araddr` | output | 32 | unused read channel, constant | - | - | 0 |
| `m_arlen` | output | 8 | unused read channel | - | - | - |
| `m_arsize` | output | 3 | unused read channel, 2 | - | - | 2 |
| `m_arburst` | output | 2 | unused read channel, 1 | - | - | 1 |
| `m_arprot` | output | 3 | unused read channel, 0 | - | - | 0 |
| `m_arvalid` | output | 1 | always 0 | - | - | 0 |
| `m_arready` | input | 1 | ignored | - | - | - |
| `m_rid` | input | 4 | ignored | - | - | - |
| `m_rdata` | input | 32 | ignored | - | - | - |
| `m_rresp` | input | 2 | ignored | - | - | - |
| `m_rlast` | input | 1 | ignored | - | - | - |
| `m_rvalid` | input | 1 | ignored | - | - | - |
| `m_rready` | output | 1 | always 0 | - | - | 0 |

### Internal signals used by the verification

The TB reads these core-internal signals by name to decide which timer events must be recorded;
a re-implementation must have them, with these names and meanings.

| Signal | Width | Meaning |
|---|---|---|
| `e_busy` | 1 | the record writer is busy: high from the clock after a record is started (`go`) until the clock in which `e_done` is high (§3.4) |
| `e_done` | 1 | one-clock pulse: the record write finished (the clock after the B handshake edge) |

Other internal state (names free): `pre` (16-bit prescaler), `tcnt` (32-bit timer count),
`barked`, `rec` (record value), `slot` (next ring slot).

## 2. Registers

The core has no registers of its own: the inputs above come from the APB4 wrapper
`Timer_WDT_apb` (CTRL holds the enables and PRESCALE, CMD.kick makes the `kick` pulse,
COUNT / TS_STATE / WDT_COUNT / WDT_STATE read the outputs, and the interrupt sources are
`tmr_irq`, `bark`, `ts_err`).

<!-- AUTO:registers -->
Generated from [`docs/ip/Timer_WDT.md`](../ip/Timer_WDT.md) (source: `scripts/apb/specs/Timer_WDT.json`); do not edit by hand.

`Timer_WDT_apb` is an APB4 slave (AMBA APB protocol v2.0): zero wait states, 32-bit data, 12-bit byte address, PSTRB byte lanes on every writable register, PSLVERR on an unmapped or misaligned address (reads then return 0, writes are dropped). Writes to read-only registers are ignored without an error. The core runs on PCLK and PRESETN. `irq` is level-high: `|(IRQ_STATUS & IRQ_ENABLE)`.

Pass-through pins: `wdt_reset`, `m_awid`, `m_awaddr`, `m_awlen`, `m_awsize`, `m_awburst`, `m_awprot`, `m_awvalid`, `m_awready`, `m_wdata`, `m_wstrb`, `m_wlast`, `m_wvalid`, `m_wready`, `m_bid`, `m_bresp`, `m_bvalid`, `m_bready`, `m_arid`, `m_araddr`, `m_arlen`, `m_arsize`, `m_arburst`, `m_arprot`, `m_arvalid`, `m_arready`, `m_rid`, `m_rdata`, `m_rresp`, `m_rlast`, `m_rvalid`, `m_rready`.

### Register map

| Offset | Name | Access | Reset | Description |
|---|---|---|---|---|
| 0x000 | ID | RO | 0x5C0C0100 | IP identification: code, major and minor version |
| 0x004 | IRQ_STATUS | W1C | 0x00000000 | Sticky interrupt bits, write 1 to clear |
| 0x008 | IRQ_ENABLE | RW | 0x00000000 | Interrupt enables; irq = \|(IRQ_STATUS & IRQ_ENABLE) |
| 0x00C | FLAGS | RO | 0x00000000 | Stream holding-register state |
| 0x010 | SCRATCH | RW | 0x00000000 | Scratch register, no effect on the core |
| 0x014 | CTRL | RW | 0x00000000 | Enables and prescaler |
| 0x018 | PERIOD | RW | 0x00000000 | Timer period |
| 0x01C | TS_BASE | RW | 0x00000000 | Timestamp ring base |
| 0x020 | TS_WORDS | RW | 0x00000000 | Timestamp ring size |
| 0x024 | WDT_LOAD | RW | 0x00000000 | Watchdog timeout |
| 0x028 | CMD | WO (pulse) | 0x00000000 | Commands (write 1) |
| 0x02C | COUNT | RO | core | Tick counter |
| 0x030 | TS_STATE | RO | core | Record counters |
| 0x034 | WDT_COUNT | RO | core | Watchdog counter |
| 0x038 | WDT_STATE | RO | core | Watchdog output |

Unlisted bits read 0 and ignore writes. Reset "core": the register reads the core's outputs directly, so after reset it shows the core's own reset state. WO (pulse) registers read 0. Offsets from 0x03C up to 0xFFC are unmapped (PSLVERR).

### Fields

| Register | Bits | Field | Access | Reset | Description |
|---|---|---|---|---|---|
| ID | 31:16 | CODE | RO | 0x5C0C | IP code |
| ID | 15:8 | MAJOR | RO | 0x01 | major version |
| ID | 7:0 | MINOR | RO | 0x00 | minor version |
| IRQ_STATUS | 2:0 | one bit per interrupt | W1C | 0x0 | see Interrupts |
| IRQ_ENABLE | 2:0 | one bit per interrupt | RW | 0x0 | 1 enables the IRQ_STATUS bit onto `irq` |
| SCRATCH | 31:0 | SCRATCH | RW | 0x00000000 | free for software |
| CTRL | 15:0 | `prescale` | RW | 0x0 | clocks per tick - 1 |
| CTRL | 16 | `tmr_en` | RW | 0x0 | timer on |
| CTRL | 17 | `ts_en` | RW | 0x0 | timestamp records on |
| CTRL | 18 | `wdt_en` | RW | 0x0 | watchdog on |
| PERIOD | 31:0 | `period` | RW | 0x0 | ticks per event - 1 |
| TS_BASE | 31:0 | `ts_base` | RW | 0x0 | byte address of record 0 |
| TS_WORDS | 15:0 | `ts_words` | RW | 0x0 | words (0: no records) |
| WDT_LOAD | 31:0 | `wdt_load` | RW | 0x0 | ticks |
| CMD | 0 | `kick` | WO (pulse) | 0x0 | reload the watchdog |
| COUNT | 31:0 | `count` | RO | core | ticks since reset |
| TS_STATE | 15:0 | `ts_wp` | RO | core | records written |
| TS_STATE | 31:16 | `ts_missed` | RO | core | events not recorded |
| WDT_COUNT | 31:0 | `wdt_count` | RO | core | ticks left |
| WDT_STATE | 0 | `wdt_reset` | RO | core | bite: reset request |

### Interrupts (IRQ_STATUS, IRQ_ENABLE)

A bit is set while its source is active, stays set until written with 1, and a set in the same clock as the clear wins.

| Bit | Name | Set when |
|---|---|---|
| 0 | TIMER | timer event |
| 1 | BARK | watchdog expired once |
| 2 | TS_ERR | a record write got an AXI error response |

### Programming sequence

1. Release PRESETN. Read ID (0x000) and check it is 0x5C0C0100.
2. Write 0x7 to IRQ_STATUS (0x004) to clear any stale bits.
3. Configure the core: write CTRL (0x014), PERIOD (0x018), TS_BASE (0x01C), TS_WORDS (0x020), WDT_LOAD (0x024). Reset values are in the register map; PSTRB selects the bytes written.
4. Write IRQ_ENABLE (0x008) with the interrupts to use (bit order as in the Interrupts table; 0x7 enables all).
5. To issue a command, write 1 to `kick` (CMD bit 0) at 0x028; the core sees a one-clock pulse, and the register reads 0.
6. Read COUNT (0x02C) for the core's live `count`; it needs no clearing.
7. Read TS_STATE (0x030) for the core's live `ts_wp`, `ts_missed`; it needs no clearing.
8. Read WDT_COUNT (0x034) for the core's live `wdt_count`; it needs no clearing.
9. Read WDT_STATE (0x038) for the core's live `wdt_reset`; it needs no clearing.
10. On `irq`: read IRQ_STATUS, handle every bit that is set and enabled, then write those bits back to IRQ_STATUS to clear them. A source that is still active sets its bit again.

IP-specific use:

1. Write CTRL.prescale, PERIOD, TS_BASE, TS_WORDS, then CTRL with tmr_en / ts_en.
2. Watchdog: write WDT_LOAD, set CTRL.wdt_en, write CMD.kick periodically.
<!-- /AUTO:registers -->

## 3. Timing

### 3.1 Prescaler and COUNT

`tick = (pre >= prescale)` (combinational). At every edge `pre <= tick ? 0 : pre + 1`, and if
`tick`, `count <= count + 1`. After reset `pre` = 0, so with `prescale` = P the tick is high in
the clock where `pre` = P, i.e. every P + 1 clocks (every clock for P = 0). Lowering `prescale`
below the current `pre` gives a tick in the next clock.

### 3.2 Timer

- `tmr_en` = 0: `tcnt <= 0` at every edge, no events.
- `tmr_en` = 1, at each tick edge: `tcnt <= (tcnt >= period) ? 0 : tcnt + 1`.
- `tmr_irq` is high in the tick clock where `tcnt >= period`. From `tcnt` = 0 this is every
  `period` + 1 ticks (every tick for `period` = 0). Lowering `period` below `tcnt` makes the
  next tick an event and restarts the period.

### 3.3 Records: start, slot, miss

`go = tmr_irq && ts_en && ts_words != 0 && !e_busy && !e_done`. At a `go` edge:

- `rec <= count` (the value of `count` in the event clock, before that tick's increment);
- the writer starts a single-word write of `rec` to `ts_base + 4 * wslot`, where
  `wslot = (slot >= ts_words) ? 0 : slot` (the ring was shrunk below the next slot → slot 0).

An event with `ts_en` = 1 and `ts_words` ≠ 0 while `e_busy` or `e_done` is high is not recorded
and increments `ts_missed` (up to 0xFFFF).

At the edge where `e_done` is high: `ts_wp <= ts_wp + 1` and
`slot <= (wslot + 1 >= ts_words) ? 0 : wslot + 1`. With a constant `ts_words` = N, record
*n* (from 0) is at `ts_base + 4 * (n mod N)`.

### 3.4 Record write on AXI

One single-beat INCR write (AWLEN 0, AWSIZE 2, WSTRB 0xF, WLAST 1, ID `AXI_ID`); one record
outstanding at a time. With `go` at edge G:

| Edge | Event |
|---|---|
| G | `e_busy` <= 1; address and record captured |
| G+1 | the record word is taken into the writer's buffer |
| G+2 | `m_awvalid` <= 1 (AW is issued only when the data is already buffered) |
| AW handshake (`m_awvalid && m_awready`) | `m_awvalid` <= 0, `m_wvalid` <= 1 with `m_wdata` = record, `m_wlast` = 1 |
| W handshake | `m_wvalid` <= 0, `m_bready` <= 1 |
| B handshake (`m_bready && m_bvalid`) | `m_bready` <= 0; `m_bresp` ≠ OKAY marks an error |
| next edge | `e_busy` <= 0, `e_done` <= 1 for one clock; `ts_err` = `e_done && error` (same clock) |

`m_awvalid` and `m_wvalid` stay high until accepted (AXI rule); W is never valid before AW is
accepted. The read channel is idle (`m_arvalid` = 0, `m_rready` = 0).

### 3.5 Watchdog

At every edge, in priority order:

1. `wdt_en` = 0: `wdt_count <= wdt_load`, `barked <= 0`, `wdt_reset <= 0`.
2. `kick` = 1: same reload and clear.
3. tick: if `wdt_count` = 0: `wdt_count <= wdt_load`; if `barked` then `wdt_reset <= 1`;
   `barked <= 1`. Else `wdt_count <= wdt_count - 1`.

`bark` is high in the tick clock where `wdt_count` = 0, `barked` = 0, no `kick` and `wdt_en` = 1:
the first timeout. The second timeout without a kick sets `wdt_reset`, which stays high (the
counter keeps reloading and counting) until a `kick` or `wdt_en` = 0. With `wdt_load` = L a
timeout comes every L + 1 ticks. Enabling: `wdt_count` already holds `wdt_load` while
disabled, so the first timeout is L + 1 ticks after enabling (write WDT_LOAD before setting
WDT_EN).

### 3.6 Reset

All flops clear: `count` = 0, `ts_wp` = 0, `ts_missed` = 0, `wdt_count` = 0, `wdt_reset` = 0,
`e_busy` = `e_done` = 0, no AXI request open (`m_awvalid` = `m_wvalid` = `m_bready` = 0). A
record write in flight is abandoned (the AXI subordinate must also be reset).

## 4. Parameters

| Parameter | Default | Legal range | Effect |
|---|---|---|---|
| `AXI_ID` | 4'd11 | 0 .. 15 | AWID / ARID of every request |

## 5. Errors and corner cases

| Case | Behaviour |
|---|---|
| AXI write error (BRESP ≠ OKAY) | record counted in `ts_wp` anyway; `ts_err` pulses with `e_done` |
| timer event while a record is in flight | not recorded; `ts_missed` + 1 (§3.3) |
| `period` shorter than a record write | some events missed (the TB requires at least one with period 1, prescale 0) |
| `ts_words` lowered below the next slot | next record goes to slot 0; slots above the new size are not written |
| `ts_words` = 0 or `ts_en` = 0 | no records and no misses counted |
| kicks in time | no bark, no bite |
| two timeouts without a kick | bark at the first, `wdt_reset` at the second |
| `kick` in the same clock as a timeout | kick wins: reload, no bark |
| reset during a record write | §3.6 |

## 6. TB check map

Messages are printed by `tb/Timer_WDT_tb.sv` as `ERROR: <message>`. The TB runs a cycle-level
reference model of §3.1, §3.2 and §3.5 and compares it with the core on every clock. The AXI
memory model (`tb/soc_ss_axi_mem.svh`) also prints `ERROR: axi_mem: ...` for an AXI rule
violation (AxSIZE ≠ 2, burst not INCR, 4 KB crossing, WLAST misplaced, BID not echoed), and the
common end check fails on an AXI request still open or a burst longer than 16 beats.

| Check (TB message or assertion) | What it requires | Spec |
|---|---|---|
| "COUNT" | `count` equals the model every clock | §3.1 |
| "WDT_COUNT" | `wdt_count` equals the model every clock | §3.5 |
| "TIMER event" | `tmr_irq` equals the model's event every clock | §3.2 |
| "BARK event" | `bark` equals the model every clock | §3.5 |
| "wdt_reset" | `wdt_reset` equals the model's bite every clock | §3.5 |
| "TS_WP" | `ts_wp` = number of recorded events (events with the writer idle) | §3.3 |
| "TS_MISSED" | `ts_missed` = number of events with `e_busy` or `e_done` high | §3.3 |
| "record" | the last min(N, n) records in the ring equal `count` at their events, at `ts_base + 4 * (n mod N)` | §3.3, §3.4 |
| "no missed records with a 2-clock period" | with period 1 and prescale 0 some events are missed | §3.3, §5 |
| "too few timer events" | random settings produce at least 50 events | §3.2 |
| "no TS_ERR on a write error" | an error response pulses `ts_err` | §3.4, §5 |
| "bark although kicked in time" | regular kicks prevent any bark | §3.5 |
| "no bite after a second timeout" | second timeout sets `wdt_reset` | §3.5 |
| "bite not cleared by a kick" | `kick` clears `wdt_reset` | §3.5 |
| "bite not cleared by WDT_EN = 0" | disabling clears `wdt_reset` | §3.5 |
| "no bark after the kick" | after a kick the watchdog runs again and barks | §3.5 |
| "not idle in reset" | in reset: no AW / W valid, `count` = 0, `ts_wp` = 0 | §3.6 |
| "TS_WP before lowering TS_WORDS" | 5 records written before the ring is shrunk | §3.3 |
| "record not at slots 0, 1 after lowering TS_WORDS" | after shrinking 8 → 3 with next slot 5, records go to slots 0 and 1 | §3.3, §5 |
| "record at slot" | slots 5..7, outside the shrunk ring, are not written | §3.3, §5 |
