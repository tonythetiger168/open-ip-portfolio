<!-- SPDX-License-Identifier: Apache-2.0 -->
# HSI: design specification

A MIPI HSI (High-Speed Synchronous Interface) link endpoint in frame mode: one transmitter and one
receiver with DATA / FLAG data-strobe signalling, READY / WAKE flow control, breaks, and receive
error detection. Not implemented: stream mode, pipelined data flow, more than 16 channels, the
HSI 1.01 configuration handshake variants. Core `HSI_top` (`rtl/HSI_top.sv`), testbench
`tb/HSI_tb.sv` (two endpoints cross-connected, plus a line BFM for illegal traffic), checker
`tb/cov/HSI_sva.sv`.

Conventions on this page: every flop is clocked on the rising edge of `clk` and reset
asynchronously by `rst_n` low. Inputs are sampled at the rising edge. CB = 33 + channel bits is
the frame length in bits (start bit included), with channel bits = min(`cfg_chbits`, 4).

## 1. Interface

| Port | Dir | Width | Meaning | Active | Clock | Reset |
|---|---|---|---|---|---|---|
| `clk` | input | 1 | clock | rising edge | - | - |
| `rst_n` | input | 1 | asynchronous reset | low | async | - |
| `tx_data` | output | 1 | transmit DATA line | - | `clk` | 0 |
| `tx_flag` | output | 1 | transmit FLAG line | - | `clk` | 0 |
| `tx_ready_in` | input | 1 | the peer receiver's READY (asynchronous, two-flop synchronised) | high | async | - |
| `tx_wake` | output | 1 | WAKE to the peer: a frame held, sending, or `cfg_wake`; combinational | high | comb | 0 |
| `rx_data` | input | 1 | receive DATA line (asynchronous, two-flop synchronised) | - | async | - |
| `rx_flag` | input | 1 | receive FLAG line (asynchronous, two-flop synchronised) | - | async | - |
| `rx_ready_out` | output | 1 | READY to the peer (§3.4); combinational | high | comb | 0 |
| `rx_wake` | input | 1 | the peer's WAKE | high | async | - |
| `cfg_div` | input | 8 | bit time - 1 in clocks (3 or more on both ends) | - | static | - |
| `cfg_chbits` | input | 3 | channel bits per frame, 0..4 (5..7 count as 4) | - | static | - |
| `cfg_rx_en` | input | 1 | receiver enabled (gates READY) | high | `clk` | - |
| `cfg_wake` | input | 1 | force WAKE high | high | `clk` | - |
| `txq_valid` | input | 1 | a frame to send is offered | high | `clk` | - |
| `txq_ready` | output | 1 | the one-frame hold register is empty; combinational | high | comb | 1 |
| `txq_ch` | input | 4 | channel (its low `cfg_chbits` bits are sent) | - | `clk` | - |
| `txq_data` | input | 32 | frame data | - | `clk` | - |
| `tx_brk` | input | 1 | send a break (one-clock request, remembered) | high | `clk` | - |
| `tx_busy` | output | 1 | sending a frame or break, or a break pending; combinational | high | comb | 0 |
| `tx_done` | output | 1 | one-clock pulse after the last bit time of a frame | high | `clk` | 0 |
| `rxq_valid` | output | 1 | a received frame is in the FIFO; combinational | high | comb | 0 |
| `rxq_ready` | input | 1 | the host takes the head frame | high | `clk` | - |
| `rxq_ch` | output | 4 | channel of the head frame (bits above `cfg_chbits` 0); combinational | - | comb | - |
| `rxq_data` | output | 32 | data of the head frame; combinational | - | comb | - |
| `rx_break` | output | 1 | one-clock pulse: a break was received | high | `clk` | 0 |
| `err_overflow` | output | 1 | pulse: a frame ended with the FIFO full and was dropped | high | `clk` | 0 |
| `err_stray` | output | 1 | pulse: a start bit after fewer zeros than a break | high | `clk` | 0 |
| `err_ds` | output | 1 | pulse: both lines changed in one clock | high | `clk` | 0 |
| `err_timeout` | output | 1 | pulse: a frame stopped (no bit for about 4 bit times) | high | `clk` | 0 |

### Internal signals used by the verification

The TB reads `fn` by name (of endpoint `g_ep[1].u`) to check the FIFO is full; the FSM coverage
collector (`tb/cov/HSI_fsm_cov.sv`) binds `ts` and `rs`.

| Signal | Width | Meaning |
|---|---|---|
| `fn` | 3 | frames in the receive FIFO, 0..4 |
| `ts` | 2 | transmitter: 0 IDLE, 1 SEND, 2 BREAK |
| `rs` | 1 | receiver: 0 IDLE, 1 FRAME |

## 2. Registers

<!-- AUTO:registers -->
Generated from [`docs/ip/HSI.md`](../ip/HSI.md) (source: `scripts/apb/specs/HSI.json`); do not edit by hand.

`HSI_apb` is an APB4 slave (AMBA APB protocol v2.0): zero wait states, 32-bit data, 12-bit byte address, PSTRB byte lanes on every writable register, PSLVERR on an unmapped or misaligned address (reads then return 0, writes are dropped). Writes to read-only registers are ignored without an error. The core runs on PCLK and PRESETN. `irq` is level-high: `|(IRQ_STATUS & IRQ_ENABLE)`.

Pass-through pins: `tx_data`, `tx_flag`, `tx_ready_in`, `tx_wake`, `rx_data`, `rx_flag`, `rx_ready_out`, `rx_wake`.

### Register map

| Offset | Name | Access | Reset | Description |
|---|---|---|---|---|
| 0x000 | ID | RO | 0x48530200 | IP identification: code, major and minor version |
| 0x004 | IRQ_STATUS | W1C | 0x00000000 | Sticky interrupt bits, write 1 to clear |
| 0x008 | IRQ_ENABLE | RW | 0x00000000 | Interrupt enables; irq = \|(IRQ_STATUS & IRQ_ENABLE) |
| 0x00C | FLAGS | RO | 0x00000000 | Stream holding-register state |
| 0x010 | SCRATCH | RW | 0x00000000 | Scratch register, no effect on the core |
| 0x014 | CFG | RW | 0x00000C07 | Link configuration |
| 0x018 | TX0 | RW | 0x00000000 | Frame to send; writing TX_DATA commits it. The core sends it once the peer's READY is high |
| 0x01C | TX1 | RW | 0x00000000 | Frame to send; writing TX_DATA commits it. The core sends it once the peer's READY is high |
| 0x020 | RX0 | RO (pop) | 0x00000000 | Received frame (head of the core's 4-frame FIFO); reading RX_DATA pops it |
| 0x024 | RX1 | RO (pop) | 0x00000000 | Received frame (head of the core's 4-frame FIFO); reading RX_DATA pops it |
| 0x028 | CMD | WO (pulse) | 0x00000000 | Commands |
| 0x02C | STATUS | RO | core | Transmitter state |

Unlisted bits read 0 and ignore writes. Reset "core": the register reads the core's outputs directly, so after reset it shows the core's own reset state. WO (pulse) registers read 0. Offsets from 0x030 up to 0xFFC are unmapped (PSLVERR).

### Fields

| Register | Bits | Field | Access | Reset | Description |
|---|---|---|---|---|---|
| ID | 31:16 | CODE | RO | 0x4853 | IP code |
| ID | 15:8 | MAJOR | RO | 0x02 | major version |
| ID | 7:0 | MINOR | RO | 0x00 | minor version |
| IRQ_STATUS | 8:0 | one bit per interrupt | W1C | 0x0 | see Interrupts |
| IRQ_ENABLE | 8:0 | one bit per interrupt | RW | 0x0 | 1 enables the IRQ_STATUS bit onto `irq` |
| FLAGS | 1:0 | one bit per stream flag | RO | 0x0 | see FLAGS |
| SCRATCH | 31:0 | SCRATCH | RW | 0x00000000 | free for software |
| CFG | 7:0 | `cfg_div` | RW | 0x7 | bit time - 1 in PCLK (3 or more on both ends) |
| CFG | 10:8 | `cfg_chbits` | RW | 0x4 | channel bits per frame (0..4; larger values count as 4) |
| CFG | 11 | `cfg_rx_en` | RW | 0x1 | receiver enabled (drives READY) |
| CFG | 12 | `cfg_wake` | RW | 0x0 | hold WAKE high while idle |
| TX0 | 3:0 | `txq_ch` | RW | 0x0 | channel |
| TX1 | 31:0 | `txq_data` | RW | 0x0 | frame data |
| RX0 | 3:0 | `rxq_ch` | RO (pop) | 0x0 | channel (upper bits 0 when fewer channel bits are used) |
| RX1 | 31:0 | `rxq_data` | RO (pop) | 0x0 | frame data |
| CMD | 0 | `tx_brk` | WO (pulse) | 0x0 | send a break (once the transmitter is idle; does not wait for READY) |
| STATUS | 0 | `tx_busy` | RO | core | a frame or break is being sent, or a break is pending |

### Interrupts (IRQ_STATUS, IRQ_ENABLE)

A bit is set while its source is active, stays set until written with 1, and a set in the same clock as the clear wins.

| Bit | Name | Set when |
|---|---|---|
| 0 | TX_SENT | a frame was sent (TX_DONE is set earlier, when the core takes the frame) |
| 1 | RX_BREAK | a break was received |
| 2 | ERR_OVERFLOW | a frame arrived with the receive FIFO full and was dropped |
| 3 | ERR_STRAY | a start bit followed fewer zeros than a break |
| 4 | ERR_DS | DATA and FLAG changed in the same clock |
| 5 | ERR_TIMEOUT | no bit for 4 bit times inside a frame (frame dropped) |
| 6 | TX_DONE | TX beat accepted by the core |
| 7 | TX_OVF | write to TX while full (dropped) |
| 8 | RX_AVAIL | RX captured a beat |

### FLAGS

| Bit | Name | Meaning |
|---|---|---|
| 0 | TX_FULL | TX holds a beat the core has not taken |
| 1 | RX_AVAIL | RX holds an unread beat |

### Streams

* **TX** feeds `txq_ch`, `txq_data`/`txq_valid`. Writing TX1 commits the beat: FLAGS.TX_FULL is set and `txq_valid` stays high until the core's `txq_ready`; then TX_DONE is set. A write while full is dropped and sets TX_OVF.
* **RX** takes `rxq_ch`, `rxq_data` from the core with `rxq_valid` / `rxq_ready`: `rxq_ready` is high while the register is empty (or is being read in the same clock), and a captured beat sets FLAGS/IRQ RX_AVAIL. Reading RX1 pops it. Nothing is dropped: the core holds its data until the register is free.

### Programming sequence

1. Release PRESETN. Read ID (0x000) and check it is 0x48530200.
2. Write 0x1FF to IRQ_STATUS (0x004) to clear any stale bits.
3. Configure the core: write CFG (0x014). Reset values are in the register map; PSTRB selects the bytes written.
4. Write IRQ_ENABLE (0x008) with the interrupts to use (bit order as in the Interrupts table; 0x1FF enables all).
5. To send on TX: wait until FLAGS.TX_FULL (bit 0) is 0, or for IRQ TX_DONE, then write TX0 (0x018) then TX1 (0x01C). The last write commits the beat. TX_OVF means a write came while the register was full and was dropped.
6. To receive on RX: wait for IRQ RX_AVAIL or FLAGS.RX_AVAIL (bit 1), then read RX0 (0x020) then RX1 (0x024). Reading the last word frees the register for the next beat; write 1 to IRQ_STATUS.RX_AVAIL (bit 8) to clear it.
7. To issue a command, write 1 to `tx_brk` (CMD bit 0) at 0x028; the core sees a one-clock pulse, and the register reads 0.
8. Read STATUS (0x02C) for the core's live `tx_busy`; it needs no clearing.
9. On `irq`: read IRQ_STATUS, handle every bit that is set and enabled, then write those bits back to IRQ_STATUS to clear them. A source that is still active sets its bit again.
<!-- /AUTO:registers -->

## 3. Timing

### 3.1 Line coding

Each bit changes exactly one line: DATA is set to the bit if it differs from the current DATA,
otherwise FLAG toggles. A bit lasts `cfg_div` + 1 clocks. A frame is: start bit 1, the channel
bits (the low channel-bits bits of `txq_ch`, MSB first), then 32 data bits MSB first. A break is
CB zero bits.

### 3.2 Transmitter

`txq_ready` = the hold register is empty; a frame offered with `txq_valid` is held at that edge.
`tx_brk` sets a pending break. In IDLE, at an edge:

* a pending break wins: BREAK (no READY needed);
* else a held frame with the synchronised READY (`tx_ready_in` through two flops) = 1: SEND, the
  hold register empties.

In SEND / BREAK the first bit is put on the lines at the next edge, then each bit `cfg_div` + 1
clocks after the previous; after the last bit time the transmitter returns to IDLE and, for a
frame, `tx_done` pulses. `tx_wake` = hold full or not IDLE or `cfg_wake`. `tx_busy` = not IDLE or
a break pending.

### 3.3 Receiver

`rx_data` / `rx_flag` pass two synchronising flops; a bit is seen in a clock where either
synchronised line differs from its value in the previous clock (the bit value is DATA). Both
changing in one clock pulses `err_ds` and counts as one bit.

* IDLE: a 1 bit is a start bit: if 1..CB - 1 zero bits came since the last start bit, `err_stray`;
  the zero count is cleared and FRAME begins for CB - 1 more bits. A 0 bit counts a zero
  (saturating at 63); when the count reaches CB, `rx_break` pulses (once per run of zeros).
* FRAME: each bit shifts in; at the last bit the frame {channel bits right-aligned, data} is
  pushed into the 4-entry FIFO if it has room (a pop in the same clock makes room), else dropped
  with `err_overflow`. If no bit is seen for 4 x `cfg_div` + 3 clocks the frame is dropped with
  `err_timeout` and the receiver returns to IDLE.

`rxq_valid` = FIFO not empty; `rxq_ch` / `rxq_data` show the head; `rxq_ready` pops it.

### 3.4 Flow control

`rx_ready_out` = `cfg_rx_en` and `rx_wake` and (frames in the FIFO + 1 if a frame is arriving)
<= 3, so a frame that starts while READY is high always has room. The transmitter samples the
peer's READY only when starting a frame.

### 3.5 Reset

While `rst_n` is low: both lines 0, IDLE, hold and FIFO empty, all events 0.

## 4. Parameters

None.

## 5. Errors and corner cases

| Case | Behaviour |
|---|---|
| frame while READY was low (non-compliant peer) | stored if there is room, else `err_overflow` |
| zeros shorter than a break before a start bit | `err_stray`, the frame is received |
| both lines change in one clock | `err_ds`, taken as one bit |
| frame stops | `err_timeout`, dropped |
| break requested while sending | sent after the current frame, before a held frame |
| `cfg_chbits` 5..7 | 4 channel bits |
| two breaks back to back | one `rx_break` (the zero count goes on) |
| reset mid-frame | lines 0, everything cleared |

## 6. TB check map

Messages are printed by `tb/HSI_tb.sv` as `ERROR: <message>`. Assertions `a_*` are in the bound
checker `tb/cov/HSI_sva.sv`. Two endpoints are cross-connected with random traffic and receive
back-pressure; every frame is checked in order at the other side, and both transmit pairs are
line-checked. A BFM sends frames while READY is low, stray zeros, double-line changes, stopped
frames and breaks of exact and short length. Every `cfg_chbits` value, several bit times, a slow
receiver, the receiver disabled, WAKE forced and a reset mid-frame are run.

| Check (TB message or assertion) | What it requires | Spec |
|---|---|---|
| "side" | per side: frames in order, no unexpected receive error, one line per change, bits at least `cfg_div` + 1 clocks apart | §3.1..§3.3 |
| "link did not go quiet" | every frame delivered | §3.2, §3.4 |
| "FIFO not full with a frame held back" | READY low with 3 frames + 1 arriving; the transmitter holds the next | §3.4 |
| "frame did not wait for READY" | a held frame waits for READY with WAKE high | §3.2 |
| "breaks seen" | one `rx_break` per break | §3.3 |
| "events: overflow" | BFM error cases give the expected event counts | §3.3 |
| a_tx_lines | `tx_data` / `tx_flag` exactly as the checker's model | §3.1, §3.2 |
| a_txq_ready | `txq_ready` = hold empty | §3.2 |
| a_tx_busy | `tx_busy` as the model | §3.2 |
| a_tx_wake | `tx_wake` = hold or not IDLE or `cfg_wake` | §3.2 |
| a_tx_done | `tx_done` as the model | §3.2 |
| a_rx_ready | `rx_ready_out` as the model | §3.4 |
| a_rxq_valid | `rxq_valid` = FIFO not empty | §3.3 |
| a_rxq_frame | head frame as the model | §3.3 |
| a_rx_break | `rx_break` as the model | §3.3 |
| a_overflow | `err_overflow` as the model | §3.3 |
| a_stray | `err_stray` as the model | §3.3 |
| a_ds | `err_ds` as the model | §3.3 |
| a_timeout | `err_timeout` as the model | §3.3 |
| a_one_line | DATA and FLAG never change together | §3.1 |
| a_rst_lines | in reset: lines 0, `txq_ready` 1, not busy, FIFO empty | §3.5 |
