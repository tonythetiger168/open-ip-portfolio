<!-- SPDX-License-Identifier: Apache-2.0 -->
# CAN: design specification

A classical CAN 2.0A/B protocol controller (ISO 11898-1): base and extended data and remote frames,
bit stuffing, CRC-15, bitwise arbitration, ACK, the five error types with active / passive error
frames, fault confinement (TEC, REC, error passive, bus-off and recovery), configurable bit timing
with hard and re-synchronisation, a one-frame transmit buffer and an acceptance filter. Not
implemented: overload frames, the +8 counter rules for dominant bits after error flags, CAN FD.
Core `CAN_top` (`rtl/CAN_top.sv`), testbench `tb/CAN_tb.sv` (two controllers on a wired-AND bus
with slightly different clocks, a bus BFM with fault injection and an independent bus monitor),
checker `tb/cov/CAN_sva.sv`.

Conventions on this page: every flop is clocked on the rising edge of `clk` and reset
asynchronously by `rst_n` low. 0 is dominant, 1 recessive. A *sample* is the clock where the bit
timing reaches the sample point; frame logic runs at samples, and the event pulses are high in the
clock after that sample.

## 1. Interface

| Port | Dir | Width | Meaning | Active | Clock | Reset |
|---|---|---|---|---|---|---|
| `clk` | input | 1 | clock | rising edge | - | - |
| `rst_n` | input | 1 | asynchronous reset | low | async | - |
| `rxd` | input | 1 | bus receive (0 dominant); synchronised by two flops | - | async | - |
| `txd` | output | 1 | bus transmit (0 dominant); registered | - | `clk` | 1 |
| `cfg_brp` | input | 6 | baud rate prescaler: tq = `cfg_brp`+1 clocks | - | `clk` | - |
| `cfg_tseg1` | input | 4 | TSEG1 = `cfg_tseg1`+1 tq (propagation + phase 1) | - | `clk` | - |
| `cfg_tseg2` | input | 3 | TSEG2 = `cfg_tseg2`+1 tq (phase 2) | - | `clk` | - |
| `cfg_sjw` | input | 2 | resynchronisation jump width = `cfg_sjw`+1 tq | - | `clk` | - |
| `acc_code` | input | 29 | acceptance code | - | `clk` | - |
| `acc_mask` | input | 29 | acceptance mask: 1 = the ID bit must equal `acc_code` | - | `clk` | - |
| `tx_valid` | input | 1 | a frame is offered to the transmit buffer | high | `clk` | - |
| `tx_ready` | output | 1 | the transmit buffer is empty | high | `clk` | 1 |
| `tx_id` | input | 29 | ID: base frames use bits 10:0, extended frames 28:0 | - | `clk` | - |
| `tx_ide` | input | 1 | 1 extended frame | - | `clk` | - |
| `tx_rtr` | input | 1 | 1 remote frame | - | `clk` | - |
| `tx_dlc` | input | 4 | data length code 0..15 (above 8 sends 8 bytes) | - | `clk` | - |
| `tx_data` | input | 64 | data; byte i at bits 8i+7:8i, byte 0 sent first, MSB first | - | `clk` | - |
| `tx_abort` | input | 1 | drop the buffered frame when it is not being transmitted | high | `clk` | - |
| `tx_done` | output | 1 | one-clock pulse: the own frame was sent successfully | high | `clk` | 0 |
| `tx_aborted` | output | 1 | one-clock pulse: the buffered frame was dropped by `tx_abort` | high | `clk` | 0 |
| `rx_valid` | output | 1 | one-clock pulse: an accepted frame is on `rx_*` | high | `clk` | 0 |
| `rx_id` | output | 29 | received ID (base: bits 10:0, others 0) | - | `clk` | 0 |
| `rx_ide` | output | 1 | received IDE | - | `clk` | 0 |
| `rx_rtr` | output | 1 | received remote flag | - | `clk` | 0 |
| `rx_dlc` | output | 4 | received DLC as sent (0..15) | - | `clk` | 0 |
| `rx_data` | output | 64 | received data, layout as `tx_data`; bytes not received are 0 | - | `clk` | 0 |
| `arb_lost` | output | 1 | one-clock pulse: arbitration lost | high | `clk` | 0 |
| `err_bit` | output | 1 | one-clock pulse: bit error | high | `clk` | 0 |
| `err_stuff` | output | 1 | one-clock pulse: stuff error | high | `clk` | 0 |
| `err_crc` | output | 1 | one-clock pulse: CRC error | high | `clk` | 0 |
| `err_form` | output | 1 | one-clock pulse: form error | high | `clk` | 0 |
| `err_ack` | output | 1 | one-clock pulse: ACK error | high | `clk` | 0 |
| `tec` | output | 9 | transmit error counter | - | `clk` | 0 |
| `rec` | output | 8 | receive error counter | - | `clk` | 0 |
| `err_passive` | output | 1 | error passive: not bus-off and (`tec` > 127 or `rec` > 127); combinational | high | comb | 0 |
| `bus_off` | output | 1 | bus-off state; combinational from the state | high | comb | 0 |

### Internal signals used by the verification

fsm_cov binds the protocol state; keep its name and encoding.

| Signal | Width | Meaning |
|---|---|---|
| `mode` | 3 | 0 IDLE, 1 SUSPEND, 2 FRAME, 3 EFLAG (error flag), 4 EWAIT (wait for recessive), 5 EDELIM (error delimiter), 6 INTERM (intermission), 7 BUSOFF |

## 2. Registers

<!-- AUTO:registers -->
Generated from [`docs/ip/CAN.md`](../ip/CAN.md) (source: `scripts/apb/specs/CAN.json`); do not edit by hand.

`CAN_apb` is an APB4 slave (AMBA APB protocol v2.0): zero wait states, 32-bit data, 12-bit byte address, PSTRB byte lanes on every writable register, PSLVERR on an unmapped or misaligned address (reads then return 0, writes are dropped). Writes to read-only registers are ignored without an error. The core runs on PCLK and PRESETN. `irq` is level-high: `|(IRQ_STATUS & IRQ_ENABLE)`.

Pass-through pins: `rxd`, `txd`.

### Register map

| Offset | Name | Access | Reset | Description |
|---|---|---|---|---|
| 0x000 | ID | RO | 0x43410200 | IP identification: code, major and minor version |
| 0x004 | IRQ_STATUS | W1C | 0x00000000 | Sticky interrupt bits, write 1 to clear |
| 0x008 | IRQ_ENABLE | RW | 0x00000000 | Interrupt enables; irq = \|(IRQ_STATUS & IRQ_ENABLE) |
| 0x00C | FLAGS | RO | 0x00000000 | Stream holding-register state |
| 0x010 | SCRATCH | RW | 0x00000000 | Scratch register, no effect on the core |
| 0x014 | BTR | RW | 0x00002941 | Bit timing (static while the bus is in use) |
| 0x018 | ACC_CODE | RW | 0x00000000 | Acceptance code |
| 0x01C | ACC_MASK | RW | 0x00000000 | Acceptance mask |
| 0x020 | TX0 | RW | 0x00000000 | Frame to transmit; writing TX3 (DLC) queues it |
| 0x024 | TX1 | RW | 0x00000000 | Frame to transmit; writing TX3 (DLC) queues it |
| 0x028 | TX2 | RW | 0x00000000 | Frame to transmit; writing TX3 (DLC) queues it |
| 0x02C | TX3 | RW | 0x00000000 | Frame to transmit; writing TX3 (DLC) queues it |
| 0x030 | CMD | WO (pulse) | 0x00000000 | Commands |
| 0x034 | RX0 | RO (pop) | 0x00000000 | Received frame; reading RX3 frees it |
| 0x038 | RX1 | RO (pop) | 0x00000000 | Received frame; reading RX3 frees it |
| 0x03C | RX2 | RO (pop) | 0x00000000 | Received frame; reading RX3 frees it |
| 0x040 | RX3 | RO (pop) | 0x00000000 | Received frame; reading RX3 frees it |
| 0x044 | STATUS | RO | core | Fault confinement |

Unlisted bits read 0 and ignore writes. Reset "core": the register reads the core's outputs directly, so after reset it shows the core's own reset state. WO (pulse) registers read 0. Offsets from 0x048 up to 0xFFC are unmapped (PSLVERR).

### Fields

| Register | Bits | Field | Access | Reset | Description |
|---|---|---|---|---|---|
| ID | 31:16 | CODE | RO | 0x4341 | IP code |
| ID | 15:8 | MAJOR | RO | 0x02 | major version |
| ID | 7:0 | MINOR | RO | 0x00 | minor version |
| IRQ_STATUS | 13:0 | one bit per interrupt | W1C | 0x0 | see Interrupts |
| IRQ_ENABLE | 13:0 | one bit per interrupt | RW | 0x0 | 1 enables the IRQ_STATUS bit onto `irq` |
| FLAGS | 1:0 | one bit per stream flag | RO | 0x0 | see FLAGS |
| SCRATCH | 31:0 | SCRATCH | RW | 0x00000000 | free for software |
| BTR | 5:0 | `cfg_brp` | RW | 0x1 | time quantum = BRP+1 clocks |
| BTR | 9:6 | `cfg_tseg1` | RW | 0x5 | TSEG1 = TSEG1+1 tq (propagation + phase 1) |
| BTR | 12:10 | `cfg_tseg2` | RW | 0x2 | TSEG2 = TSEG2+1 tq (phase 2) |
| BTR | 14:13 | `cfg_sjw` | RW | 0x1 | resynchronisation jump width = SJW+1 tq (at most TSEG2+1) |
| ACC_CODE | 28:0 | `acc_code` | RW | 0x0 | ID to match (base IDs in bits 10:0) |
| ACC_MASK | 28:0 | `acc_mask` | RW | 0x0 | 1 = the ID bit must equal ACC_CODE; 0 accepts every frame |
| TX0 | 31:0 | `tx_data[31:0]` | RW | 0x0 | data bytes, byte 0 in bits 7:0 (sent first) |
| TX1 | 31:0 | `tx_data[63:32]` | RW | 0x0 | data bytes, byte 0 in bits 7:0 (sent first) |
| TX2 | 28:0 | `tx_id` | RW | 0x0 | identifier (base frames: bits 10:0) |
| TX2 | 29 | `tx_ide` | RW | 0x0 | 1 = extended frame |
| TX2 | 30 | `tx_rtr` | RW | 0x0 | 1 = remote frame |
| TX3 | 3:0 | `tx_dlc` | RW | 0x0 | data length code |
| CMD | 0 | `tx_abort` | WO (pulse) | 0x0 | 1 = drop the queued frame when it is not being sent (IRQ ABORTED) |
| RX0 | 31:0 | `rx_data[31:0]` | RO (pop) | 0x0 | data bytes, byte 0 in bits 7:0 |
| RX1 | 31:0 | `rx_data[63:32]` | RO (pop) | 0x0 | data bytes, byte 0 in bits 7:0 |
| RX2 | 28:0 | `rx_id` | RO (pop) | 0x0 | identifier |
| RX2 | 29 | `rx_ide` | RO (pop) | 0x0 | extended frame |
| RX2 | 30 | `rx_rtr` | RO (pop) | 0x0 | remote frame |
| RX3 | 3:0 | `rx_dlc` | RO (pop) | 0x0 | data length code |
| STATUS | 8:0 | `tec` | RO | core | transmit error counter |
| STATUS | 16:9 | `rec` | RO | core | receive error counter |
| STATUS | 17 | `err_passive` | RO | core | error passive |
| STATUS | 18 | `bus_off` | RO | core | bus-off |

### Interrupts (IRQ_STATUS, IRQ_ENABLE)

A bit is set while its source is active, stays set until written with 1, and a set in the same clock as the clear wins.

| Bit | Name | Set when |
|---|---|---|
| 0 | SENT | a queued frame was sent |
| 1 | ABORTED | a queued frame was dropped by CMD.tx_abort |
| 2 | ARB_LOST | arbitration lost (the frame is retried) |
| 3 | ERR_BIT | bit error |
| 4 | ERR_STUFF | stuff error |
| 5 | ERR_CRC | CRC error |
| 6 | ERR_FORM | form error |
| 7 | ERR_ACK | acknowledgement error |
| 8 | ERR_PASSIVE | node is error passive (level) |
| 9 | BUS_OFF | node is bus-off (level) |
| 10 | TX_DONE | TX beat accepted by the core |
| 11 | TX_OVF | write to TX while full (dropped) |
| 12 | RX_AVAIL | RX captured a beat |
| 13 | RX_OVF | beat dropped, RX was full |

### FLAGS

| Bit | Name | Meaning |
|---|---|---|
| 0 | TX_FULL | TX holds a beat the core has not taken |
| 1 | RX_AVAIL | RX holds an unread beat |

### Streams

* **TX** feeds `tx_data`, `tx_id`, `tx_ide`, `tx_rtr`, `tx_dlc`/`tx_valid`. Writing TX3 commits the beat: FLAGS.TX_FULL is set and `tx_valid` stays high until the core's `tx_ready`; then TX_DONE is set. A write while full is dropped and sets TX_OVF.
* **RX** captures `rx_data`, `rx_id`, `rx_ide`, `rx_rtr`, `rx_dlc` when `rx_valid` is high and the register is empty (or is being read in the same clock), and sets FLAGS/IRQ RX_AVAIL. Reading RX3 pops it. A beat that arrives while the register is full is dropped and sets RX_OVF.

### Programming sequence

1. Release PRESETN. Read ID (0x000) and check it is 0x43410200.
2. Write 0x3FFF to IRQ_STATUS (0x004) to clear any stale bits.
3. Configure the core: write BTR (0x014), ACC_CODE (0x018), ACC_MASK (0x01C). Reset values are in the register map; PSTRB selects the bytes written.
4. Write IRQ_ENABLE (0x008) with the interrupts to use (bit order as in the Interrupts table; 0x3FFF enables all).
5. To send on TX: wait until FLAGS.TX_FULL (bit 0) is 0, or for IRQ TX_DONE, then write TX0 (0x020) then TX1 (0x024) then TX2 (0x028) then TX3 (0x02C). The last write commits the beat. TX_OVF means a write came while the register was full and was dropped.
6. To issue a command, write 1 to `tx_abort` (CMD bit 0) at 0x030; the core sees a one-clock pulse, and the register reads 0.
7. To receive on RX: wait for IRQ RX_AVAIL or FLAGS.RX_AVAIL (bit 1), then read RX0 (0x034) then RX1 (0x038) then RX2 (0x03C) then RX3 (0x040). Reading the last word frees the register for the next beat; write 1 to IRQ_STATUS.RX_AVAIL (bit 12) to clear it. Read each beat before the next arrives, or it is dropped and RX_OVF is set.
8. Read STATUS (0x044) for the core's live `tec`, `rec`, `err_passive`, `bus_off`; it needs no clearing.
9. On `irq`: read IRQ_STATUS, handle every bit that is set and enabled, then write those bits back to IRQ_STATUS to clear them. A source that is still active sets its bit again.
<!-- /AUTO:registers -->

## 3. Timing

### 3.1 Bit timing

`rxd` passes two synchronising flops; the sampled bus value is the second flop, and a falling edge
is seen when the second flop goes 0 while a third copy is 1. A time quantum is `cfg_brp`+1 clocks.
A bit is SYNC (1 tq) + TSEG1 (`cfg_tseg1`+1 tq) + TSEG2 (`cfg_tseg2`+1 tq); the bus is sampled at
the end of TSEG1. The node changes `txd` at the start of each bit (start of SYNC).

- Hard synchronisation: a falling edge in IDLE, SUSPEND or INTERM restarts the bit (tq counter
  and prescaler to 0).
- Resynchronisation: a falling edge in any other state except BUSOFF, when the last sampled bit
  was recessive, this node drives recessive, the edge is not in SYNC, and no resynchronisation
  happened since the last sample. Edge in TSEG1 (late): the bit is lengthened by min(phase error,
  SJW) tq. Edge in TSEG2 (early): if the phase error is at most SJW the bit ends at the edge,
  otherwise it is shortened by SJW tq.

### 3.2 Frame layout

Bit positions are de-stuffed indices from SOF = 0:

| Field | Base frame | Extended frame |
|---|---|---|
| SOF | 0 | 0 |
| ID | 1..11 (ID[10:0]) | 1..11 (ID[28:18]) |
| bit 12 | RTR | SRR (sent 1) |
| IDE | 13 (0) | 13 (1) |
| ID[17:0] | - | 14..31 |
| RTR | - | 32 |
| reserved (sent 0) | 14 (r0) | 33, 34 (r1, r0) |
| DLC | 15..18 | 35..38 |
| data | from 19 | from 39 |

Data: min(DLC, 8) bytes, none for a remote frame; byte 0 first, each byte MSB first. CRC: 15 bits
after the data. Then CRC delimiter (1), ACK slot, ACK delimiter (1), EOF (7 recessive bits).

CRC-15: polynomial 0x4599, initial value 0, over SOF through the last data bit (de-stuffed),
sent MSB first. Stuffing: from SOF through the last CRC bit, after five equal bits a bit of the
opposite value is inserted (including one after the last CRC bit when needed).

### 3.3 Transmit buffer

`tx_ready` = buffer empty. A clock with `tx_valid` && `tx_ready` loads the frame. `tx_abort` while
a frame is buffered requests a drop: the frame is dropped (`tx_aborted`, buffer empty) as soon as
the node is not transmitting it, that is at once when idle or after the current attempt ends
(arbitration lost or end of intermission after an error); a frame that completes first gives
`tx_done` instead. While a drop is requested no new transmission starts.

### 3.4 Transmission and arbitration

In IDLE, at a bit start with a buffered frame, the node drives SOF. A node with a buffered frame
that samples another node's SOF in IDLE (it hard-synchronised to it) transmits along from ID
bit 1. During the frame it drives its own bits, inserting stuff bits.

Arbitration field: positions 1..12 for a base frame, 1..32 for an extended frame (of the own
frame). Sending recessive and sampling dominant there: `arb_lost`, the node continues as a
receiver and the frame stays buffered for the next bus idle. Any other difference between the
driven and sampled bit up to the last CRC bit is a bit error.

Success: the 7th EOF bit sampled recessive. Then `tx_done` pulses, the buffer is freed and `tec`
drops by 1 (if not 0). The node goes to intermission.

### 3.5 Intermission, suspend and idle

Intermission is 3 bits. A dominant bit sampled in intermission, suspend or idle is a SOF: the node
receives the frame from position 1. At the 3rd intermission bit, a node with a buffered frame
(not being dropped, and not an error-passive node that just transmitted) transmits from ID bit 1.
After 3 recessive intermission bits: an error-passive node that just transmitted enters SUSPEND
for 8 recessive bits (a SOF during suspend makes it a receiver), every other node enters IDLE.

### 3.6 Reception

Every node that is not transmitting checks the frame; at the bit start of the ACK slot it drives
dominant when the received CRC matched (whether or not its filter accepts the ID). At the 6th EOF
bit sampled recessive the frame is valid for a receiver: `rec` drops by 1 (to 120 when it was above
127), and when ((ID ^ `acc_code`) & `acc_mask`) == 0 the frame is delivered: `rx_valid` pulses with
the ID (base IDs in bits 10:0), IDE, RTR, raw DLC and data. A dominant 7th EOF bit is not an error
for a receiver. Own frames are never delivered.

### 3.7 Errors and error frames

Detected at samples:

| Error | Condition |
|---|---|
| bit | transmitter: sampled bit != driven bit at a non-stuff position up to the last CRC bit, except recessive driven / dominant seen inside arbitration (that is a lost arbitration) |
| stuff | a stuff bit position samples the same value as the previous five bits |
| CRC | the received CRC differs; reported at the ACK delimiter (when it is recessive) |
| form | dominant CRC delimiter, ACK delimiter, EOF bits 1..6 (all nodes) or EOF bit 7 (transmitter); dominant bit in an error delimiter |
| ACK | transmitter samples the ACK slot recessive |

On an error: the matching pulse, then an error flag of 6 bits from the next bit start: dominant
when error active, recessive when error passive (state taken at the error). Then the node waits
for a recessive sample, which counts as the first of 8 recessive delimiter bits; a dominant
delimiter bit is a form error (new error frame). Then intermission. The frame is retried by a
transmitter after the intermission.

### 3.8 Fault confinement

- Transmit error: `tec` += 8, except a stuff error on a stuff bit the node itself sent recessive in
  arbitration, and an ACK error while error passive. When `tec` would exceed 255 the node goes
  bus-off.
- Receive error: `rec` += 1, saturating at 255.
- Success: see 3.4 and 3.6.
- `err_passive` = not bus-off and (`tec` > 127 or `rec` > 127).
- Bus-off: `txd` stays recessive and nothing is transmitted or received. Recovery: 128 runs of 11
  consecutive recessive samples (a dominant sample restarts the current run); then `tec` = `rec` =
  0 and IDLE.

### 3.9 Reset

`txd` = 1, buffer empty (`tx_ready` = 1), all pulses 0, `rx_*` 0, `tec` = `rec` = 0, IDLE.

## 4. Parameters

None. Bit timing comes from the `cfg_*` inputs (keep them stable while the bus is active).

## 5. Errors and corner cases

- DLC 9..15 sends and receives 8 bytes; `rx_dlc` shows the raw code.
- A remote frame never carries data; its DLC is still sent.
- Base and extended frames with the same base ID: a base data frame wins at position 12 (RTR 0
  against SRR 1); a base remote frame wins at IDE.
- The ACK is given by every error-free receiver regardless of the filter.
- Overload frames are not generated; a dominant intermission bit is always a SOF.

## 6. TB check map

| Check (TB message or assertion) | What it requires | Spec |
|---|---|---|
| "bus never idle" | the bus goes recessive between test steps | §3.5 |
| "A sent" | each `tx_done` of A matches the frame the bus monitor decoded | §3.3, §3.4 |
| "B sent" | the same for B | §3.3, §3.4 |
| "A did not deliver" | every valid frame A did not send and its filter accepts is delivered | §3.6 |
| "A delivered a frame it should not" | no delivery of own, filtered-out or invalid frames | §3.6 |
| "B did not deliver" | as for A | §3.6 |
| "B delivered a frame it should not" | as for A | §3.6 |
| "transmit never completed" | a queued frame is sent | §3.4 |
| "reset values" | outputs after reset | §3.9 |
| "A TEC" | `tec` follows the fault confinement rules | §3.8 |
| "A REC" | `rec` follows the rules | §3.8 |
| "B TEC" | as for A | §3.8 |
| "B REC" | as for A | §3.8 |
| "BFM should have lost arbitration" | a lower ID wins arbitration (base vs extended, data vs remote) | §3.4 |
| "BFM frame at the 3rd intermission bit" | a dominant 3rd intermission bit is a SOF; a pending node joins from the ID | §3.5 |
| "BFM frame not acknowledged" | a receiver drives the ACK slot when its CRC matched | §3.6 |
| "A never became error passive" | `tec` above 127 makes the node error passive | §3.8 |
| "passive TEC" | `tec` value while passive | §3.8 |
| "TEC moved on passive ACK errors" | an error-passive transmitter's ACK error does not change `tec` | §3.8 |
| "A never went bus-off" | `tec` above 255 means bus-off | §3.8 |
| "bus-off with TEC below 256" | no bus-off before `tec` > 255 | §3.8 |
| "no bus-off recovery" | recovery after 128 x 11 recessive bits | §3.8 |
| "receivers not error passive" | `rec` above 127 makes receivers passive | §3.8 |
| a_reset_values | reset values | §3.9 |
| a_txd_model | `txd` equals the checker's bit-level transmit model | §3.2..§3.7 |
| a_tx_ready_model | `tx_ready` = buffer empty | §3.3 |
| a_tx_done_model | `tx_done` and `tx_aborted` | §3.3, §3.4 |
| a_rx_valid_model | `rx_valid` | §3.6 |
| a_rx_frame_model | `rx_*` fields with `rx_valid` | §3.6 |
| a_arb_lost_model | `arb_lost` | §3.4 |
| a_error_pulses_model | the five error pulses | §3.7 |
| a_counters_model | `tec`, `rec` | §3.8 |
| a_state_model | `bus_off`, `err_passive` | §3.8 |
| a_bus_off_recessive | `txd` = 1 while bus-off | §3.8 |
