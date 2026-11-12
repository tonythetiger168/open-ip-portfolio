<!-- SPDX-License-Identifier: Apache-2.0 -->
# C_PHY: design specification

A MIPI C-PHY style trio (3 wires, 3 levels) high-speed transmitter with a decoder for the same
trio. Not implemented: the MIPI 16-bit to 7-symbol mapping table (a base-5 mapper is used), LP
mode signalling and escape mode, wire-rate clocking and clock recovery (one symbol per clock),
calibration preamble, multiple trios. Core `C_PHY_top` (`rtl/C_PHY_top.sv`), testbench
`tb/C_PHY_tb.sv` (TX looped back into RX through an error-injection mux), checker
`tb/cov/C_PHY_sva.sv`.

Conventions on this page: every flop is clocked on the rising edge of `clk` and reset
asynchronously by `rst_n` low. Wire states {A, B, C}: +x = (H, L, M), -x = (L, H, M),
+y = (M, H, L), -y = (M, L, H), +z = (L, M, H), -z = (H, M, L); idle = (M, M, M).

## 1. Interface

| Port | Dir | Width | Meaning | Active | Clock | Reset |
|---|---|---|---|---|---|---|
| `clk` | input | 1 | clock; one symbol per clock | rising edge | - | - |
| `rst_n` | input | 1 | asynchronous reset | low | async | - |
| `irq` | output | 1 | sticky receive protocol error | high | `clk` | 0 |
| `irq_clear` | input | 1 | clear `irq` (an error in the same clock wins) | high | `clk` | - |
| `tx_data` | input | 16 | host word | - | `clk` | - |
| `tx_valid` | input | 1 | a word is offered | high | `clk` | - |
| `tx_ready` | output | 1 | the one-word buffer is empty; combinational from flops | high | `clk` | 1 |
| `tx_last` | input | 1 | last word of the burst | high | `clk` | - |
| `tx_done` | output | 1 | one-clock pulse: the burst ended, trio back to idle | high | `clk` | 0 |
| `t_a` | output | 2 | wire A level: 00 low, 01 mid, 10 high | - | `clk` | 01 |
| `t_b` | output | 2 | wire B level | - | `clk` | 01 |
| `t_c` | output | 2 | wire C level | - | `clk` | 01 |
| `r_a` | input | 2 | received wire A (sampled directly) | - | `clk` | - |
| `r_b` | input | 2 | received wire B | - | `clk` | - |
| `r_c` | input | 2 | received wire C | - | `clk` | - |
| `rx_active` | output | 1 | a burst is being decoded; combinational from flops | high | `clk` | 0 |
| `rx_data` | output | 16 | decoded word; holds | - | `clk` | 0 |
| `rx_valid` | output | 1 | one-clock pulse: a decoded word | high | `clk` | 0 |
| `rx_done` | output | 1 | one-clock pulse: post-amble and clean stop seen | high | `clk` | 0 |

### Internal signals used by the verification

The TB reads `buf_valid` and `tstate`; the FSM coverage collector binds `tstate` and `rstate`.

| Signal | Width | Meaning |
|---|---|---|
| `buf_valid` | 1 | the one-word transmit buffer is full (`tx_ready` = !`buf_valid`) |
| `tstate` | 3 | transmitter: 0 IDLE, 1 SYNC, 2 DATA, 3 POST-AMBLE, 4 END |
| `rstate` | 3 | decoder: 0 IDLE, 1 SYNC, 2 DATA, 3 POST-AMBLE, 4 ERROR (waits for idle) |

## 2. Registers

<!-- AUTO:registers -->
Generated from [`docs/ip/C_PHY.md`](../ip/C_PHY.md) (source: `scripts/apb/specs/C_PHY.json`); do not edit by hand.

`C_PHY_apb` is an APB4 slave (AMBA APB protocol v2.0): zero wait states, 32-bit data, 12-bit byte address, PSTRB byte lanes on every writable register, PSLVERR on an unmapped or misaligned address (reads then return 0, writes are dropped). Writes to read-only registers are ignored without an error. The core runs on PCLK and PRESETN. `irq` is level-high: `|(IRQ_STATUS & IRQ_ENABLE)`.

Pass-through pins: `t_a`, `t_b`, `t_c`, `r_a`, `r_b`, `r_c`.

### Register map

| Offset | Name | Access | Reset | Description |
|---|---|---|---|---|
| 0x000 | ID | RO | 0x43700200 | IP identification: code, major and minor version |
| 0x004 | IRQ_STATUS | W1C | 0x00000000 | Sticky interrupt bits, write 1 to clear |
| 0x008 | IRQ_ENABLE | RW | 0x00000000 | Interrupt enables; irq = \|(IRQ_STATUS & IRQ_ENABLE) |
| 0x00C | FLAGS | RO | 0x00000000 | Stream holding-register state |
| 0x010 | SCRATCH | RW | 0x00000000 | Scratch register, no effect on the core |
| 0x014 | TX | RW | 0x00000000 | Word to send; writing TX commits it. A burst starts with the first word and continues while words keep coming; it ends after a word with last set or when the next word is late |
| 0x018 | RX | RO (pop) | 0x00000000 | Word decoded from the receive trio (one every seven clocks in a burst); reading RX frees it |
| 0x01C | CMD | WO (pulse) | 0x00000000 | Commands |
| 0x020 | STATUS | RO | core | Receiver state |

Unlisted bits read 0 and ignore writes. Reset "core": the register reads the core's outputs directly, so after reset it shows the core's own reset state. WO (pulse) registers read 0. Offsets from 0x024 up to 0xFFC are unmapped (PSLVERR).

### Fields

| Register | Bits | Field | Access | Reset | Description |
|---|---|---|---|---|---|
| ID | 31:16 | CODE | RO | 0x4370 | IP code |
| ID | 15:8 | MAJOR | RO | 0x02 | major version |
| ID | 7:0 | MINOR | RO | 0x00 | minor version |
| IRQ_STATUS | 6:0 | one bit per interrupt | W1C | 0x0 | see Interrupts |
| IRQ_ENABLE | 6:0 | one bit per interrupt | RW | 0x0 | 1 enables the IRQ_STATUS bit onto `irq` |
| FLAGS | 1:0 | one bit per stream flag | RO | 0x0 | see FLAGS |
| SCRATCH | 31:0 | SCRATCH | RW | 0x00000000 | free for software |
| TX | 15:0 | `tx_data` | RW | 0x0 | 16-bit payload word |
| TX | 16 | `tx_last` | RW | 0x0 | last word of the burst |
| RX | 15:0 | `rx_data` | RO (pop) | 0x0 | Word decoded from the receive trio (one every seven clocks in a burst); reading RX frees it |
| CMD | 0 | `irq_clear` | WO (pulse) | 0x0 | write 1: clear the receiver's sticky error (ERROR stops being set) |
| STATUS | 0 | `rx_active` | RO | core | a burst is being decoded |

### Interrupts (IRQ_STATUS, IRQ_ENABLE)

A bit is set while its source is active, stays set until written with 1, and a set in the same clock as the clear wins.

| Bit | Name | Set when |
|---|---|---|
| 0 | TX_SENT | a burst finished and the trio is back to idle |
| 1 | RX_DONE | a received burst ended with the post-amble and a clean stop |
| 2 | ERROR | the receiver saw a protocol error (entry not on +x, wrong sync, invalid wire state, missing transition, a symbol group above 65535, a stop inside a word or without post-amble, junk after it); sticky in the core, so the bit is set again on every clock until CMD.irq_clear |
| 3 | TX_DONE | TX beat accepted by the core |
| 4 | TX_OVF | write to TX while full (dropped) |
| 5 | RX_AVAIL | RX captured a beat |
| 6 | RX_OVF | beat dropped, RX was full |

### FLAGS

| Bit | Name | Meaning |
|---|---|---|
| 0 | TX_FULL | TX holds a beat the core has not taken |
| 1 | RX_AVAIL | RX holds an unread beat |

### Streams

* **TX** feeds `tx_data`, `tx_last`/`tx_valid`. Writing TX commits the beat: FLAGS.TX_FULL is set and `tx_valid` stays high until the core's `tx_ready`; then TX_DONE is set. A write while full is dropped and sets TX_OVF.
* **RX** captures `rx_data` when `rx_valid` is high and the register is empty (or is being read in the same clock), and sets FLAGS/IRQ RX_AVAIL. Reading RX pops it. A beat that arrives while the register is full is dropped and sets RX_OVF.

### Programming sequence

1. Release PRESETN. Read ID (0x000) and check it is 0x43700200.
2. Write 0x7F to IRQ_STATUS (0x004) to clear any stale bits.
3. Write IRQ_ENABLE (0x008) with the interrupts to use (bit order as in the Interrupts table; 0x7F enables all).
4. To send on TX: wait until FLAGS.TX_FULL (bit 0) is 0, or for IRQ TX_DONE, then write TX (0x014). The last write commits the beat. TX_OVF means a write came while the register was full and was dropped.
5. To receive on RX: wait for IRQ RX_AVAIL or FLAGS.RX_AVAIL (bit 1), then read RX (0x018). Reading the last word frees the register for the next beat; write 1 to IRQ_STATUS.RX_AVAIL (bit 5) to clear it. Read each beat before the next arrives, or it is dropped and RX_OVF is set.
6. To issue a command, write 1 to `irq_clear` (CMD bit 0) at 0x01C; the core sees a one-clock pulse, and the register reads 0.
7. Read STATUS (0x020) for the core's live `rx_active`; it needs no clearing.
8. On `irq`: read IRQ_STATUS, handle every bit that is set and enabled, then write those bits back to IRQ_STATUS to clear them. A source that is still active sets its bit again.
<!-- /AUTO:registers -->

## 3. Timing

### 3.1 Symbols

Every symbol 0..4 is a transition from the current wire state, so consecutive states always
differ. Symbol 4 (Flip): same pair, opposite polarity. Symbols 0..3 = {0, Rotation, Polarity}:
Rotation 1 moves x -> y -> z -> x, 0 moves x -> z -> y -> x; Polarity 1 flips the polarity.

A 16-bit word v is 7 symbols, symbol i = (v / 5^i) mod 5, i = 0 first. The post-amble 4444444
decodes to 78124, which no word gives.

### 3.2 Transmitter

A word is taken into a one-word buffer when `tx_valid` and `tx_ready`. A burst, one wire state per
clock:

1. In IDLE with a buffered word: +x.
2. Sync word 3444443 (7 states).
3. Words: after the sync the buffered word is taken (the buffer frees) and sent as 7 symbols. At
   the end of each word, if it was not `tx_last` and another word is buffered, that one follows;
   otherwise (last word, or host underrun) the burst ends.
4. Post-amble 4444444.
5. Idle (M, M, M), with `tx_done` high in that clock.

### 3.3 Decoder

The received wires are decoded each clock (no synchroniser). In IDLE a non-idle state must be +x
(start of a burst); then each clock must be a transition (a valid state different from the
previous one) carrying the sync symbols, then 7-symbol groups. A group equal to 78124 starts the
post-amble; a group above 65535 is an error; otherwise `rx_valid` pulses one clock later with the
word. In the post-amble further 4s are allowed, and idle ends the burst with `rx_done` one clock
later.

Errors set `irq` (sticky until `irq_clear`) and the decoder waits for idle: entry not on +x, a
wrong sync symbol, an invalid wire state, no transition, a group above 65535 that is not the
post-amble, idle inside a word or before the post-amble, anything but 4 after the post-amble.
`rx_active` is high from the clock after +x until the burst ends or fails.

### 3.4 Reset

While `rst_n` is low: both sides idle, wires mid, buffer empty, outputs 0.

## 4. Parameters

None.

## 5. Errors and corner cases

| Case | Behaviour |
|---|---|
| host underrun mid-burst | burst ends with the post-amble; later words start a new burst |
| post-amble longer than 7 symbols | accepted |
| error and `irq_clear` in the same clock | `irq` stays set |
| reset mid-burst | wires idle at once |

## 6. TB check map

Messages are printed by `tb/C_PHY_tb.sv` as `ERROR: <message>`. Assertions `a_*` are in the bound
checker `tb/cov/C_PHY_sva.sv`, which also checks the wire states with its own tuple-based encoder.
The TB loops TX into RX and injects every decoder error kind.

| Check (TB message or assertion) | What it requires | Spec |
|---|---|---|
| "one burst expected" | one burst per packet | §3.2 |
| "loopback word count" | all words arrive | §3.2, §3.3 |
| "loopback word" | word values | §3.1 |
| "irq on a clean burst" | no false errors | §3.3 |
| "rx_done / tx_done once per burst" | one done each | §3.2, §3.3 |
| "reset state" | reset values | §3.4 |
| "underrun words" | words split at an underrun | §3.2 |
| "irq after underrun" | an underrun burst is clean | §3.2 |
| "back-to-back bursts" | bursts back to back | §3.2 |
| "long post-amble word" | long post-amble accepted | §3.3 |
| "error in the irq_clear cycle wins" | set wins over clear | §3.3 |
| "reset mid-burst" | reset | §3.4 |
| a_reset_idle | reset values | §3.4 |
| a_tx_no_protocol_error | transmitted bursts are legal | §3.1, §3.2 |
| a_tx_single_postamble | one post-amble per burst | §3.2 |
| a_tx_word_matches_host | sent words as written | §3.2 |
| a_tx_burst_end_rule | burst ends at last word or underrun | §3.2 |
| a_tx_ready | `tx_ready` as the model | §3.2 |
| a_tx_done | `tx_done` as the model | §3.2 |
| a_tx_enters_only_with_data | a burst needs a word | §3.2 |
| a_rx_irq | `irq` as the model | §3.3 |
| a_rx_valid | `rx_valid` as the model | §3.3 |
| a_rx_data | `rx_data` as the model | §3.3 |
| a_rx_done | `rx_done` as the model | §3.3 |
| a_rx_active | `rx_active` as the model | §3.3 |
