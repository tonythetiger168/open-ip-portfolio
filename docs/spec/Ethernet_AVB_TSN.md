<!-- SPDX-License-Identifier: Apache-2.0 -->
# Ethernet_AVB_TSN: design specification

TSN egress transmission selection for one port with 4 traffic classes: IEEE 802.1Qbv time-aware
gates with a gate control list, 802.1Qav credit-based shapers, strict priority, a PTP time counter
and egress timestamps. The core chooses which queue's head frame the MAC sends; it does not move
frame data. Not implemented: frame preemption (802.1Qbu), per-stream filtering, gate list
switching at a configuration change time, hold / release, PTP message handling, more than 4
classes. Core `Ethernet_AVB_TSN_top` (`rtl/Ethernet_AVB_TSN_top.sv`), testbench
`tb/Ethernet_AVB_TSN_tb.sv` (queue, time and schedule models), checker
`tb/cov/Ethernet_AVB_TSN_sva.sv`.

Conventions on this page: every flop is clocked on the rising edge of `clk` and reset
asynchronously by `rst_n` low. Inputs are sampled at the rising edge; registered outputs show a
decision of clock n in clock n+1. A frame of L bytes occupies the line for L + 20 clocks
(preamble and SFD 8, gap 12).

## 1. Interface

| Port | Dir | Width | Meaning | Active | Clock | Reset |
|---|---|---|---|---|---|---|
| `clk` | input | 1 | clock; one line byte per clock | rising edge | - | - |
| `rst_n` | input | 1 | asynchronous reset | low | async | - |
| `cfg_inc_ns` | input | 8 | time increment per clock, integer ns | - | `clk` | - |
| `cfg_inc_frac` | input | 16 | time increment per clock, fraction (1/65536 ns) | - | `clk` | - |
| `time_set` | input | 1 | load `time_set_ns` (fraction 0) | high | `clk` | - |
| `time_set_ns` | input | 64 | time to load | - | `clk` | - |
| `time_adj` | input | 1 | add `time_adj_ns` this clock | high | `clk` | - |
| `time_adj_ns` | input | 32 | signed adjustment, ns | - | `clk` | - |
| `time_ns` | output | 64 | PTP time, ns | - | `clk` | 0 |
| `gcl_en` | input | 1 | run the gate schedule | high | `clk` | - |
| `gcl_base` | input | 64 | schedule start time, ns | - | `clk` | - |
| `gcl_cycle` | input | 24 | cycle time, ns (at least `cfg_inc_ns`) | - | `clk` | - |
| `gcl_last` | input | 3 | index of the last gate list entry | - | `clk` | - |
| `gcl_we` | input | 1 | write gate list entry `gcl_waddr` (while `gcl_en` = 0) | high | `clk` | - |
| `gcl_waddr` | input | 3 | entry to write | - | `clk` | - |
| `gcl_wgates` | input | 4 | entry gate states, bit c = class c open | - | `clk` | - |
| `gcl_wivl` | input | 24 | entry interval, ns (at least `cfg_inc_ns`) | - | `clk` | - |
| `cbs_en` | input | 4 | credit-based shaper enable per class | high | `clk` | - |
| `cbs_idle` | input | 36 | idle slope per class c in bits 9c+8:9c, 0..256 (/256 of the line rate) | - | `clk` | - |
| `q_valid` | input | 4 | class c has a frame at its queue head | high | `clk` | - |
| `q_len` | input | 44 | head frame length of class c in bits 11c+10:11c, bytes | - | `clk` | - |
| `q_pop` | output | 4 | one-clock pulse: the head frame of that class was taken | high | `clk` | 0 |
| `tx_start` | output | 1 | one-clock pulse: a frame was selected | high | `clk` | 0 |
| `tx_tc` | output | 2 | class of the frame selected; holds | - | `clk` | 0 |
| `tx_len` | output | 11 | length of the frame selected; holds | - | `clk` | 0 |
| `tx_ts` | output | 64 | egress timestamp: `time_ns` in the selection clock; holds | - | `clk` | 0 |
| `tx_busy` | output | 1 | the line is occupied (L + 20 clocks per frame) | high | `clk` | 0 |
| `gcl_running` | output | 1 | the gate schedule runs | high | `clk` | 0 |
| `gcl_entry` | output | 3 | current gate list entry | - | `clk` | 0 |
| `gate_state` | output | 4 | gate states now (all open without a running schedule); combinational | - | comb | 4'hF |
| `cycle_start` | output | 1 | one-clock pulse at each schedule cycle start | high | `clk` | 0 |
| `cbs_credit` | output | 80 | class c credit in bits 20c+19:20c, signed, 1/256 byte | - | `clk` | 0 |

## 2. Registers

<!-- AUTO:registers -->
Generated from [`docs/ip/Ethernet_AVB_TSN.md`](../ip/Ethernet_AVB_TSN.md) (source: `scripts/apb/specs/Ethernet_AVB_TSN.json`); do not edit by hand.

`Ethernet_AVB_TSN_apb` is an APB4 slave (AMBA APB protocol v2.0): zero wait states, 32-bit data, 12-bit byte address, PSTRB byte lanes on every writable register, PSLVERR on an unmapped or misaligned address (reads then return 0, writes are dropped). Writes to read-only registers are ignored without an error. The core runs on PCLK and PRESETN. `irq` is level-high: `|(IRQ_STATUS & IRQ_ENABLE)`.

Pass-through pins: `q_valid`, `q_len`, `q_pop`, `tx_tc`, `tx_len`, `tx_ts`.

### Register map

| Offset | Name | Access | Reset | Description |
|---|---|---|---|---|
| 0x000 | ID | RO | 0x54530200 | IP identification: code, major and minor version |
| 0x004 | IRQ_STATUS | W1C | 0x00000000 | Sticky interrupt bits, write 1 to clear |
| 0x008 | IRQ_ENABLE | RW | 0x00000000 | Interrupt enables; irq = \|(IRQ_STATUS & IRQ_ENABLE) |
| 0x00C | FLAGS | RO | 0x00000000 | Stream holding-register state |
| 0x010 | SCRATCH | RW | 0x00000000 | Scratch register, no effect on the core |
| 0x014 | CFG0 | RW | 0x00000008 | Time increment, schedule and shaper enables |
| 0x018 | CFG1 | RW | 0x000F4240 | Time increment, schedule and shaper enables |
| 0x01C | GCL_BASE0 | RW | 0x00000000 | Schedule start time, ns: the list starts in the first clock with time >= GCL_BASE |
| 0x020 | GCL_BASE1 | RW | 0x00000000 | Schedule start time, ns: the list starts in the first clock with time >= GCL_BASE |
| 0x024 | CBS_IDLE0 | RW | 0x00000000 | Shaper idle slopes, class c in bits 9c+8:9c, in 1/256 of the line rate (0..256) |
| 0x028 | CBS_IDLE1 | RW | 0x00000000 | Shaper idle slopes, class c in bits 9c+8:9c, in 1/256 of the line rate (0..256) |
| 0x02C | GCL_WR | RW | 0x00000000 | Writes one gate control list entry; writing GCL_WR commits it. Write entries while CFG.gcl_en = 0 |
| 0x030 | TIME_SET0 | RW | 0x00000000 | Loads the time (fraction 0); writing TIME_SET1 commits it |
| 0x034 | TIME_SET1 | RW | 0x00000000 | Loads the time (fraction 0); writing TIME_SET1 commits it |
| 0x038 | TIME_ADJ | RW | 0x00000000 | Adds a signed offset to the time once; writing TIME_ADJ commits it |
| 0x03C | TIME0 | RO | core | Current time, ns. TIME0 and TIME1 are read separately: read TIME1, TIME0, TIME1 again and retry if TIME1 changed |
| 0x040 | TIME1 | RO | core | Current time, ns. TIME0 and TIME1 are read separately: read TIME1, TIME0, TIME1 again and retry if TIME1 changed |
| 0x044 | STATUS | RO | core | Schedule and line state |
| 0x048 | CREDIT0 | RO | core | Shaper credits, class c in bits 20c+19:20c, signed, 1/256 byte |
| 0x04C | CREDIT1 | RO | core | Shaper credits, class c in bits 20c+19:20c, signed, 1/256 byte |
| 0x050 | CREDIT2 | RO | core | Shaper credits, class c in bits 20c+19:20c, signed, 1/256 byte |

Unlisted bits read 0 and ignore writes. Reset "core": the register reads the core's outputs directly, so after reset it shows the core's own reset state. WO (pulse) registers read 0. Offsets from 0x054 up to 0xFFC are unmapped (PSLVERR).

### Fields

| Register | Bits | Field | Access | Reset | Description |
|---|---|---|---|---|---|
| ID | 31:16 | CODE | RO | 0x5453 | IP code |
| ID | 15:8 | MAJOR | RO | 0x02 | major version |
| ID | 7:0 | MINOR | RO | 0x00 | minor version |
| IRQ_STATUS | 1:0 | one bit per interrupt | W1C | 0x0 | see Interrupts |
| IRQ_ENABLE | 1:0 | one bit per interrupt | RW | 0x0 | 1 enables the IRQ_STATUS bit onto `irq` |
| SCRATCH | 31:0 | SCRATCH | RW | 0x00000000 | free for software |
| CFG0 | 7:0 | `cfg_inc_ns` | RW | 0x8 | time increment per clock, whole ns (8: 125 MHz) |
| CFG0 | 23:8 | `cfg_inc_frac` | RW | 0x0 | time increment per clock, 1/65536 ns |
| CFG0 | 24 | `gcl_en` | RW | 0x0 | 1 = run the gate control list from GCL_BASE; 0 = all gates open |
| CFG0 | 27:25 | `gcl_last` | RW | 0x0 | last gate control list entry (0..7) |
| CFG0 | 31:28 | `cbs_en` | RW | 0x0 | credit-based shaper enable per class |
| CFG1 | 23:0 | `gcl_cycle` | RW | 0xF4240 | cycle time, ns |
| GCL_BASE0 | 31:0 | `gcl_base[31:0]` | RW | 0x0 | base time, ns |
| GCL_BASE1 | 31:0 | `gcl_base[63:32]` | RW | 0x0 | base time, ns |
| CBS_IDLE0 | 31:0 | `cbs_idle[31:0]` | RW | 0x0 | idle slopes of classes 0..3 |
| CBS_IDLE1 | 3:0 | `cbs_idle[35:32]` | RW | 0x0 | idle slopes of classes 0..3 |
| GCL_WR | 23:0 | `gcl_wivl` | RW | 0x0 | interval, ns (at least CFG.cfg_inc_ns) |
| GCL_WR | 27:24 | `gcl_wgates` | RW | 0x0 | gate states, bit c = class c open |
| GCL_WR | 30:28 | `gcl_waddr` | RW | 0x0 | entry |
| TIME_SET0 | 31:0 | `time_set_ns[31:0]` | RW | 0x0 | new time, ns |
| TIME_SET1 | 31:0 | `time_set_ns[63:32]` | RW | 0x0 | new time, ns |
| TIME_ADJ | 31:0 | `time_adj_ns` | RW | 0x0 | signed offset, ns |
| TIME0 | 31:0 | `time_ns[31:0]` | RO | core | time, ns |
| TIME1 | 31:0 | `time_ns[63:32]` | RO | core | time, ns |
| STATUS | 0 | `gcl_running` | RO | core | 1 = the gate control list runs |
| STATUS | 3:1 | `gcl_entry` | RO | core | current entry |
| STATUS | 7:4 | `gate_state` | RO | core | gate state per class (all open while the list does not run) |
| STATUS | 8 | `tx_busy` | RO | core | a frame occupies the line |
| CREDIT0 | 31:0 | `cbs_credit[31:0]` | RO | core | credits of classes 0..3 |
| CREDIT1 | 31:0 | `cbs_credit[63:32]` | RO | core | credits of classes 0..3 |
| CREDIT2 | 15:0 | `cbs_credit[79:64]` | RO | core | credits of classes 0..3 |

### Interrupts (IRQ_STATUS, IRQ_ENABLE)

A bit is set while its source is active, stays set until written with 1, and a set in the same clock as the clear wins.

| Bit | Name | Set when |
|---|---|---|
| 0 | CYCLE | a gate control list cycle started |
| 1 | TX | a frame was selected for transmission |

### Streams

* **GCL_WR** feeds `gcl_wivl`, `gcl_wgates`, `gcl_waddr`; writing GCL_WR pulses `gcl_we` for one clock.
* **TIME_SET** feeds `time_set_ns`; writing TIME_SET1 pulses `time_set` for one clock.
* **TIME_ADJ** feeds `time_adj_ns`; writing TIME_ADJ pulses `time_adj` for one clock.

### Programming sequence

1. Release PRESETN. Read ID (0x000) and check it is 0x54530200.
2. Write 0x3 to IRQ_STATUS (0x004) to clear any stale bits.
3. Configure the core: write CFG0 (0x014), CFG1 (0x018), GCL_BASE0 (0x01C), GCL_BASE1 (0x020), CBS_IDLE0 (0x024), CBS_IDLE1 (0x028). Reset values are in the register map; PSTRB selects the bytes written.
4. Write IRQ_ENABLE (0x008) with the interrupts to use (bit order as in the Interrupts table; 0x3 enables all).
5. To send on GCL_WR: write GCL_WR (0x02C). The last write pulses `gcl_we` for one clock; there is no back-pressure.
6. To send on TIME_SET: write TIME_SET0 (0x030) then TIME_SET1 (0x034). The last write pulses `time_set` for one clock; there is no back-pressure.
7. To send on TIME_ADJ: write TIME_ADJ (0x038). The last write pulses `time_adj` for one clock; there is no back-pressure.
8. Read TIME0 (0x03C), TIME1 (0x040) for the core's live `time_ns[31:0]`, `time_ns[63:32]`; it needs no clearing.
9. Read STATUS (0x044) for the core's live `gcl_running`, `gcl_entry`, `gate_state`, `tx_busy`; it needs no clearing.
10. Read CREDIT0 (0x048), CREDIT1 (0x04C), CREDIT2 (0x050) for the core's live `cbs_credit[31:0]`, `cbs_credit[63:32]`, `cbs_credit[79:64]`; it needs no clearing.
11. On `irq`: read IRQ_STATUS, handle every bit that is set and enabled, then write those bits back to IRQ_STATUS to clear them. A source that is still active sets its bit again.
<!-- /AUTO:registers -->

## 3. Timing

### 3.1 Time

Each clock: with `time_set`, `time_ns` = `time_set_ns` and the fraction = 0; otherwise the
fraction adds `cfg_inc_frac` (carry into ns) and `time_ns` adds `cfg_inc_ns` + carry +
(`time_adj` ? sign-extended `time_adj_ns` : 0). `time_ns` wraps at 2^64.

### 3.2 Gate schedule

Gate list entries 0..7 hold {gates, interval}; `gcl_we` writes one at the edge. Entries 0 ..
`gcl_last` are used.

* `gcl_en` = 0: not running, `gate_state` = 4'hF.
* Not running with `gcl_en`: at the first edge where `time_ns` >= `gcl_base` the schedule starts
  (`gcl_running`, entry 0, `cycle_start` pulse); before that all gates are open.
* Running, each clock the schedule advances by `cfg_inc_ns` of elapsed time (independent of
  `time_set` / `time_adj`): when the cycle's elapsed time reaches `gcl_cycle` a new cycle starts
  (entry 0, `cycle_start`, the excess carried); else when the entry's elapsed time reaches its
  interval the next entry starts (the excess carried), except the last entry, which lasts until
  the cycle ends. Entries that do not fit in the cycle are cut.
* `gate_state` = gates of the current entry.

### 3.3 Guard band

While running, the time to close of class c is the time from now until gate c closes in a later
entry of this cycle or the cycle ends, whichever is first. A frame of class c may start only if
that time is at least (L + 20) x `cfg_inc_ns`. A frame never crosses a cycle boundary, so one
longer than the cycle is never sent.

### 3.4 Credit-based shaper

Per class with `cbs_en[c]`, the 20-bit signed credit (1/256 byte, saturating at -524288 and
524287) changes every clock:

| Condition | Change |
|---|---|
| class c is on the line (`tx_busy` and `tx_tc` = c) | + idle - 256 |
| a frame waits and gate c is open | + idle |
| a frame waits behind a closed gate | held |
| no frame queued, credit > 0 | set to 0 |
| no frame queued, credit < 0 | + idle, at most up to 0 |

Without `cbs_en[c]` the credit is 0. A class is eligible only with credit >= 0.

### 3.5 Selection

Class c is eligible when `q_valid[c]`, gate c open, the guard band holds (while running) and the
shaper allows. In a clock where the line is free or in its last line clock, the highest eligible
class is selected: `tx_start`, `tx_tc`, `tx_len` = its `q_len`, `tx_ts` = `time_ns` and `q_pop[c]`
all pulse in the next clock, and `tx_busy` is high for L + 20 clocks. With nothing eligible `tx_busy` falls. So
back-to-back frames follow without a gap clock.

### 3.6 Reset

While `rst_n` is low: time 0, schedule stopped (gates all open), credits 0, line free, gate list
entries 0.

## 4. Parameters

None.

## 5. Errors and corner cases

| Case | Behaviour |
|---|---|
| base time in the past | the schedule starts at once |
| interval or cycle below `cfg_inc_ns` | not allowed |
| entries past the cycle | cut |
| frame longer than the remaining open time | waits for a later window |
| frame longer than the cycle | never sent |
| gate closed with a frame waiting | credit held |
| idle slope 0 / 256 | a class never regains credit / never loses it |
| `time_set` / `time_adj` while running | the schedule keeps its elapsed time |
| reset mid-frame | line free, everything cleared |

## 6. TB check map

Messages are printed by `tb/Ethernet_AVB_TSN_tb.sv` as `ERROR: <message>`. Assertions `a_*` are in
the bound checker `tb/cov/Ethernet_AVB_TSN_sva.sv`. Four length-only queues feed the core; every
selection is checked against the queue heads, the TB time model and line overlap; a TB schedule
model is compared with the gate state every clock, and every frame must fit its gate window.
Strict priority, shaper shares and credit limits, gate lists of 1..8 entries, short and long
cycles, base times in the future and past, guard bands, gates closed with frames waiting,
schedules switched off and on, time set across the 64-bit wrap, adjustments, fractional
increments and a reset mid-frame are run.

| Check (TB message or assertion) | What it requires | Spec |
|---|---|---|
| "time" | `time_ns` as the TB model | §3.1 |
| "gcl_running" | schedule start / stop | §3.2 |
| "gates" | gate state as the schedule model | §3.2 |
| "gates not all open without a schedule" | 4'hF when not running | §3.2 |
| "q_pop" | `q_pop` of the selected class only | §3.5 |
| "class" | head frame of a non-empty queue, its length, no lower class while a higher one waits eligible, no overrun of a closing gate / cycle end | §3.3, §3.5 |
| "frame started while the line is busy" | one frame at a time | §3.5 |
| "timestamp" | `tx_ts` = time in the selection clock | §3.5 |
| "queues not drained" | every frame is sent | §3.5 |
| "class 3 share" | shaper gives class 3 its share | §3.4 |
| "class 2 share" | shaper gives class 2 its share | §3.4 |
| "credit never saturated high" | positive saturation reached | §3.4 |
| "credit never saturated low" | negative saturation reached | §3.4 |
| "frame longer than the cycle was sent" | never sent | §3.3 |
| a_time | `time_ns` exactly as the checker's model | §3.1 |
| a_running | `gcl_running` as the model | §3.2 |
| a_cycle_start | `cycle_start` as the model | §3.2 |
| a_gate_state | `gate_state` as the model | §3.2 |
| a_entry | `gcl_entry` as the model while running | §3.2 |
| a_credit | `cbs_credit` as the model | §3.4 |
| a_start | `tx_start` as the model | §3.5 |
| a_busy | `tx_busy` as the model | §3.5 |
| a_pop | `q_pop` as the model | §3.5 |
| a_frame | `tx_tc` / `tx_len` / `tx_ts` as the model | §3.5 |
| a_rst | in reset: time 0, idle, gates open, credits 0 | §3.6 |
