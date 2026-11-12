<!-- SPDX-License-Identifier: Apache-2.0 -->
# MIPI_SLIMbus: design specification

A SLIMbus-style TDM bus interface that is either the framer or a device, with one transmit and
one receive data channel using a pushed protocol. Not implemented: the message protocol (control
space, arbitration, enumeration, reconfiguration), clock gears and other transport protocols,
more than one channel per direction; the frame layout is simplified and this design's own. Core
`MIPI_SLIMbus_top` (`rtl/MIPI_SLIMbus_top.sv`), testbench `tb/MIPI_SLIMbus_tb.sv` (a framer and two
devices on one bus with a keeper), checker `tb/cov/MIPI_SLIMbus_sva.sv`.

Conventions on this page: every flop is clocked on the rising edge of `clk` and reset
asynchronously by `rst_n` low. CLK edges are acted on one clock after they are seen (devices see
CLK through two flops first). A cell is one bit per CLK period; a slot is 4 cells, MSB first; a
frame is 192 slots; a superframe is 8 frames.

## 1. Interface

| Port | Dir | Width | Meaning | Active | Clock | Reset |
|---|---|---|---|---|---|---|
| `clk` | input | 1 | clock | rising edge | - | - |
| `rst_n` | input | 1 | asynchronous reset | low | async | - |
| `cfg_framer` | input | 1 | 1: this endpoint is the framer (drives CLK, frame sync, FI) | high | static | - |
| `cfg_div` | input | 4 | framer: CLK half period - 1, in clocks (3 or more) | - | static | - |
| `cfg_fi` | input | 8 | framer: 8 bits of framing information sent each superframe | - | static | - |
| `sf_set` | input | 1 | framer: load the superframe count | high | `clk` | - |
| `sf_set_val` | input | 16 | count sent in the next superframe | - | `clk` | - |
| `cfg_tx_slot` | input | 8 | transmit segment first slot | - | static | - |
| `cfg_tx_len` | input | 3 | transmit bytes per frame 1..4, 0 = off | - | static | - |
| `cfg_rx_slot` | input | 8 | receive segment first slot | - | static | - |
| `cfg_rx_len` | input | 3 | receive bytes per frame 1..4, 0 = off | - | static | - |
| `cfg_err` | output | 1 | a channel with a length is configured outside the legal slots; combinational | high | comb | 0 |
| `slim_clk_o` | output | 1 | CLK driven (framer) | - | `clk` | 0 |
| `slim_clk_oe` | output | 1 | = `cfg_framer` | high | comb | - |
| `slim_clk_i` | input | 1 | CLK on the bus (devices; two-flop synchronised) | - | async | - |
| `slim_dat_o` | output | 1 | DATA driven (NRZI line level) | - | `clk` | 0 |
| `slim_dat_oe` | output | 1 | this endpoint drives DATA | high | `clk` | 0 |
| `slim_dat_i` | input | 1 | DATA on the bus | - | `clk` | - |
| `tx_valid` | input | 1 | a transmit sample is available | high | `clk` | - |
| `tx_ready` | output | 1 | one-clock pulse: the sample on `tx_data` was taken for this frame | high | `clk` | 0 |
| `tx_data` | input | 32 | transmit sample (the low `cfg_tx_len` bytes) | - | `clk` | - |
| `tx_underrun` | output | 1 | one-clock pulse: no sample at the segment start (present = 0 sent) | high | `clk` | 0 |
| `rx_valid` | output | 1 | one-clock pulse: a received sample | high | `clk` | 0 |
| `rx_data` | output | 32 | received sample (the low `cfg_rx_len` bytes); holds | - | `clk` | 0 |
| `rx_err` | output | 1 | one-clock pulse: a TAG with reserved bits set | high | `clk` | 0 |
| `locked` | output | 1 | frame sync lock (always 1 in the framer) | high | `clk` | 0 |
| `sf_locked` | output | 1 | superframe lock (always 1 in the framer) | high | `clk` | 0 |
| `lost_sync` | output | 1 | one-clock pulse: frame lock lost | high | `clk` | 0 |
| `fi_valid` | output | 1 | one-clock pulse: a complete FI received | high | `clk` | 0 |
| `fi_info` | output | 8 | FI information byte; holds | - | `clk` | 0 |
| `sf_count` | output | 16 | FI superframe count; holds | - | `clk` | 0 |

### Internal signals used by the verification

The TB reads these by name in the framer instance (`g_ep[0].u`) to time scenarios; the FSM
coverage collector binds `ls`.

| Signal | Width | Meaning |
|---|---|---|
| `cpos` | 10 | cell position in the frame, 0..767 (reset 767) |
| `cnext` | 10 | next cell position (`cpos` + 1, wrapping); combinational |
| `fno` | 3 | frame number in the superframe (reset 7) |
| `rise` | 1 | a CLK rising edge was seen (one-clock pulse) |
| `ls` | 2 | frame lock: 0 HUNT, 1 CHECK, 2 LOCK |

## 2. Registers

<!-- AUTO:registers -->
Generated from [`docs/ip/MIPI_SLIMbus.md`](../ip/MIPI_SLIMbus.md) (source: `scripts/apb/specs/MIPI_SLIMbus.json`); do not edit by hand.

`MIPI_SLIMbus_apb` is an APB4 slave (AMBA APB protocol v2.0): zero wait states, 32-bit data, 12-bit byte address, PSTRB byte lanes on every writable register, PSLVERR on an unmapped or misaligned address (reads then return 0, writes are dropped). Writes to read-only registers are ignored without an error. The core runs on PCLK and PRESETN. `irq` is level-high: `|(IRQ_STATUS & IRQ_ENABLE)`.

Pass-through pins: `slim_clk_o`, `slim_clk_oe`, `slim_clk_i`, `slim_dat_o`, `slim_dat_oe`, `slim_dat_i`.

### Register map

| Offset | Name | Access | Reset | Description |
|---|---|---|---|---|
| 0x000 | ID | RO | 0x534C0200 | IP identification: code, major and minor version |
| 0x004 | IRQ_STATUS | W1C | 0x00000000 | Sticky interrupt bits, write 1 to clear |
| 0x008 | IRQ_ENABLE | RW | 0x00000000 | Interrupt enables; irq = \|(IRQ_STATUS & IRQ_ENABLE) |
| 0x00C | FLAGS | RO | 0x00000000 | Stream holding-register state |
| 0x010 | SCRATCH | RW | 0x00000000 | Scratch register, no effect on the core |
| 0x014 | CFG | RW | 0x00000006 | Role and framing |
| 0x018 | CHAN | RW | 0x00000801 | Data channel segments (TAG slot + 2 slots per byte, inside slots 1..95 or 97..191) |
| 0x01C | SFSET | RW | 0x00000000 | Framer: writing SFSET loads the superframe count sent in the next superframe |
| 0x020 | TX | RW | 0x00000000 | Transmit sample (the low CHAN.cfg_tx_len bytes); writing TX commits it for the next segment |
| 0x024 | RX | RO (pop) | 0x00000000 | Received sample; reading RX frees it |
| 0x028 | STATUS | RO | core | Lock and framing information |

Unlisted bits read 0 and ignore writes. Reset "core": the register reads the core's outputs directly, so after reset it shows the core's own reset state. WO (pulse) registers read 0. Offsets from 0x02C up to 0xFFC are unmapped (PSLVERR).

### Fields

| Register | Bits | Field | Access | Reset | Description |
|---|---|---|---|---|---|
| ID | 31:16 | CODE | RO | 0x534C | IP code |
| ID | 15:8 | MAJOR | RO | 0x02 | major version |
| ID | 7:0 | MINOR | RO | 0x00 | minor version |
| IRQ_STATUS | 7:0 | one bit per interrupt | W1C | 0x0 | see Interrupts |
| IRQ_ENABLE | 7:0 | one bit per interrupt | RW | 0x0 | 1 enables the IRQ_STATUS bit onto `irq` |
| FLAGS | 1:0 | one bit per stream flag | RO | 0x0 | see FLAGS |
| SCRATCH | 31:0 | SCRATCH | RW | 0x00000000 | free for software |
| CFG | 0 | `cfg_framer` | RW | 0x0 | 1 = framer (drives CLK, frame sync and FI) |
| CFG | 4:1 | `cfg_div` | RW | 0x3 | framer: CLK half period - 1 (PCLK); 3 or more |
| CFG | 12:5 | `cfg_fi` | RW | 0x0 | framer: FI information byte |
| CHAN | 7:0 | `cfg_tx_slot` | RW | 0x1 | transmit segment first slot |
| CHAN | 10:8 | `cfg_tx_len` | RW | 0x0 | transmit bytes per frame (1..4, 0 = off) |
| CHAN | 18:11 | `cfg_rx_slot` | RW | 0x1 | receive segment first slot |
| CHAN | 21:19 | `cfg_rx_len` | RW | 0x0 | receive bytes per frame (1..4, 0 = off) |
| SFSET | 15:0 | `sf_set_val` | RW | 0x0 | superframe count |
| TX | 31:0 | `tx_data` | RW | 0x0 | sample |
| RX | 31:0 | `rx_data` | RO (pop) | 0x0 | sample (the low CHAN.cfg_rx_len bytes) |
| STATUS | 0 | `locked` | RO | core | frame sync locked |
| STATUS | 1 | `sf_locked` | RO | core | superframe found; the data channels run |
| STATUS | 2 | `cfg_err` | RO | core | a channel segment is invalid (that channel is off) |
| STATUS | 10:3 | `fi_info` | RO | core | FI information byte of the last superframe |
| STATUS | 26:11 | `sf_count` | RO | core | superframe count of the last superframe |

### Interrupts (IRQ_STATUS, IRQ_ENABLE)

A bit is set while its source is active, stays set until written with 1, and a set in the same clock as the clear wins.

| Bit | Name | Set when |
|---|---|---|
| 0 | FI | a complete FI was received (STATUS.fi_info / sf_count updated) |
| 1 | LOST_SYNC | frame sync lost (two misses, or no superframe within 16 frames) |
| 2 | TX_UNDERRUN | a transmit segment found no sample (sent as not present) |
| 3 | RX_ERR | a receive segment TAG had reserved bits set |
| 4 | TX_DONE | TX beat accepted by the core |
| 5 | TX_OVF | write to TX while full (dropped) |
| 6 | RX_AVAIL | RX captured a beat |
| 7 | RX_OVF | beat dropped, RX was full |

### FLAGS

| Bit | Name | Meaning |
|---|---|---|
| 0 | TX_FULL | TX holds a beat the core has not taken |
| 1 | RX_AVAIL | RX holds an unread beat |

### Streams

* **SFSET** feeds `sf_set_val`; writing SFSET pulses `sf_set` for one clock.
* **TX** feeds `tx_data`/`tx_valid`. Writing TX commits the beat: FLAGS.TX_FULL is set and `tx_valid` stays high until the core's `tx_ready`; then TX_DONE is set. A write while full is dropped and sets TX_OVF.
* **RX** captures `rx_data` when `rx_valid` is high and the register is empty (or is being read in the same clock), and sets FLAGS/IRQ RX_AVAIL. Reading RX pops it. A beat that arrives while the register is full is dropped and sets RX_OVF.

### Programming sequence

1. Release PRESETN. Read ID (0x000) and check it is 0x534C0200.
2. Write 0xFF to IRQ_STATUS (0x004) to clear any stale bits.
3. Configure the core: write CFG (0x014), CHAN (0x018). Reset values are in the register map; PSTRB selects the bytes written.
4. Write IRQ_ENABLE (0x008) with the interrupts to use (bit order as in the Interrupts table; 0xFF enables all).
5. To send on SFSET: write SFSET (0x01C). The last write pulses `sf_set` for one clock; there is no back-pressure.
6. To send on TX: wait until FLAGS.TX_FULL (bit 0) is 0, or for IRQ TX_DONE, then write TX (0x020). The last write commits the beat. TX_OVF means a write came while the register was full and was dropped.
7. To receive on RX: wait for IRQ RX_AVAIL or FLAGS.RX_AVAIL (bit 1), then read RX (0x024). Reading the last word frees the register for the next beat; write 1 to IRQ_STATUS.RX_AVAIL (bit 6) to clear it. Read each beat before the next arrives, or it is dropped and RX_OVF is set.
8. Read STATUS (0x028) for the core's live `locked`, `sf_locked`, `cfg_err`, `fi_info`, `sf_count`; it needs no clearing.
9. On `irq`: read IRQ_STATUS, handle every bit that is set and enabled, then write those bits back to IRQ_STATUS to clear them. A source that is still active sets its bit again.
<!-- /AUTO:registers -->

## 3. Timing

### 3.1 Bus and coding

The framer toggles `slim_clk_o` every `cfg_div` + 1 clocks. At each CLK rise every endpoint moves
to the next cell; a driver puts the cell's level on DATA; at the CLK fall everyone samples DATA and
drivers release it (a bus keeper holds the level). DATA is NRZI: the bit is 1 if the sampled level
differs from the previous cell's level. Each endpoint drives the level = last sampled level XOR
bit.

### 3.2 Framer

`locked` and `sf_locked` are forced to 1. Slot 0 carries the frame sync 1011; slot 96 carries four
FI bits per frame (bits 4f .. 4f + 3 in frame f). The 32 FI bits of a superframe are {8'h96,
`cfg_fi`, count}, latched as the superframe starts; the count then + 1. `sf_set` loads the count
sent in the next superframe.

### 3.3 Device lock

* HUNT: the last four decoded bits 1011 -> CHECK, aligned so this is cell 3 of slot 0.
* CHECK: at each frame's slot 0 end, 1011 again: twice in a row -> LOCK (`locked`); otherwise HUNT.
* LOCK: at each slot 0 end: two missing frame syncs in a row, or 16 frames without the superframe
  lock, -> HUNT with `locked` = `sf_locked` = 0 and `lost_sync` pulsing.

Superframe: in LOCK, slot 96 bits shift in; at its last cell, without `sf_locked`, the last 8 FI
bits = 0x96 give `sf_locked` (that is frame 1). With `sf_locked`: in frame 7, `fi_valid` pulses with
`fi_info` and `sf_count`; in frames 0 and 1 the sync nibbles 9 / 6 are checked, and a mismatch drops
only `sf_locked`.

### 3.4 Channels

A segment is a TAG slot {present, 000} and `len` byte pairs of slots: slots `slot` .. `slot` + 2 x
`len`. It is legal when 1 <= `len` <= 4 and it lies within slots 1..95 or 97..191; otherwise the
channel is off and `cfg_err` = 1 (when `len` != 0). Channels run only with `sf_locked`.

* Transmit: at the CLK rise that starts the segment, with `tx_valid` the sample is taken
  (`tx_ready` pulses) and sent as present = 1 and the low `len` bytes MSB first; without it
  present = 0 and zeros are sent (`tx_underrun`).
* Receive: at the last cell of the segment, a TAG with reserved bits set pulses `rx_err`; else with
  present = 1 `rx_valid` pulses with the `len` bytes in `rx_data` (upper bytes 0).

### 3.5 Reset

While `rst_n` is low: HUNT, cell position 767, frame 7, no drive, all pulses 0, count 0.

## 4. Parameters

None.

## 5. Errors and corner cases

| Case | Behaviour |
|---|---|
| segment touching slot 0 / 96 / past 191, or length 5..7 | channel off, `cfg_err` |
| no sample at the segment start | present = 0, `tx_underrun` |
| TAG with reserved bits | `rx_err`, no sample |
| one missed frame sync | lock kept |
| two missed frame syncs in a row | `lost_sync`, relock from HUNT |
| bad FI sync nibble | only `sf_locked` dropped |
| framer reset | devices lose lock and relock |

## 6. TB check map

Messages are printed by `tb/MIPI_SLIMbus_tb.sv` as `ERROR: <message>`. Assertions `a_*` are in the
bound checker `tb/cov/MIPI_SLIMbus_sva.sv`. A framer and two devices share one bus; the TB decodes
the frame sync and FI from the line, checks that every transmitted sample arrives in order at
every receiver of its segment, and runs every segment length, edge segments, loopback, underruns,
bad configurations, reserved TAG bits, corrupted frame syncs and FI, count loading and wrap, a
slower CLK, and device and framer resets.

| Check (TB message or assertion) | What it requires | Spec |
|---|---|---|
| "frame sync" | 1011 at every frame start | §3.2 |
| "FI count" | count loaded by `sf_set`, then + 1 per superframe | §3.2 |
| "DATA driven by" | one driver at a time | §3.1, §3.4 |
| "no lock" | devices lock | §3.3 |
| "no underruns" | underruns happen without samples | §3.4 |
| "slot 0 accepted" | segment at slot 0 is illegal | §3.4 |
| "slot 96 accepted" | segment at slot 96 is illegal | §3.4 |
| "segment across slot 96 accepted" | must end before 96 | §3.4 |
| "segment across slot 192 accepted" | must end by 191 | §3.4 |
| "length 5 accepted" | length at most 4 | §3.4 |
| "rx segment across slot 192 accepted" | same for receive | §3.4 |
| "a channel with a bad segment ran" | an illegal channel is off | §3.4 |
| "rx_err" | reserved TAG bits flagged once | §3.4 |
| "one missed frame sync lost the lock" | one miss tolerated | §3.3 |
| "two missed frame syncs kept the lock" | two misses lose lock | §3.3 |
| "bad FI did not drop only the superframe lock" | FI error drops `sf_locked` only | §3.3 |
| "devices kept the lock after a framer reset" | devices relock after a framer reset | §3.3 |
| a_cfg_err | `cfg_err` as the checker's model | §3.4 |
| a_clk_oe | `slim_clk_oe` = `cfg_framer` | §3.1 |
| a_clk | framer CLK as the model | §3.1 |
| a_dat_oe | `slim_dat_oe` as the model | §3.1, §3.4 |
| a_dat | driven DATA as the model | §3.1, §3.2, §3.4 |
| a_tx_ready | `tx_ready` as the model | §3.4 |
| a_underrun | `tx_underrun` as the model | §3.4 |
| a_rx_valid | `rx_valid` as the model | §3.4 |
| a_rx_data | `rx_data` as the model | §3.4 |
| a_rx_err | `rx_err` as the model | §3.4 |
| a_locked | `locked` as the model | §3.3 |
| a_sf_locked | `sf_locked` as the model | §3.3 |
| a_lost | `lost_sync` as the model | §3.3 |
| a_fi_valid | `fi_valid` as the model | §3.3 |
| a_fi | `fi_info` / `sf_count` as the model | §3.3 |
| a_reset | in reset: no drive, not locked, no pulses | §3.5 |
