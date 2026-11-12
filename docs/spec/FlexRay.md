<!-- SPDX-License-Identifier: Apache-2.0 -->
# FlexRay: design specification

A FlexRay 3.0.1 communication controller for one channel and the static segment. Not implemented:
the dynamic segment, symbol window (CAS / MTS, WUS), wakeup, startup with several coldstart nodes,
rate correction, a second channel, the bus guardian. Core `FlexRay_top` (`rtl/FlexRay_top.sv`),
testbench `tb/FlexRay_tb.sv` (three nodes on clocks 0.1 % apart, and a bus driver), checker
`tb/cov/FlexRay_sva.sv`.

Conventions on this page: every flop is clocked on the rising edge of `clk` and reset
asynchronously by `rst_n` low. A bit is 8 samples of `cfg_spc` + 1 clocks; a macrotick is one
bit.

## 1. Interface

| Port | Dir | Width | Meaning | Active | Clock | Reset |
|---|---|---|---|---|---|---|
| `clk` | input | 1 | clock | rising edge | - | - |
| `rst_n` | input | 1 | asynchronous reset | low | async | - |
| `rxd` | input | 1 | received bus level (idle HIGH); two-flop synchronised | - | async | - |
| `txd` | output | 1 | transmit bit | - | `clk` | 1 |
| `tx_en` | output | 1 | sending | high | `clk` | 0 |
| `cfg_spc` | input | 4 | clocks per sample - 1 (a bit is 8 samples) | - | static | - |
| `cfg_tss` | input | 4 | TSS length in bits (3..15) | - | static | - |
| `cfg_slot` | input | 10 | static slot length in bits | - | static | - |
| `cfg_ap` | input | 6 | action point offset in bits | - | static | - |
| `cfg_nslots` | input | 6 | static slots per cycle (1..63) | - | static | - |
| `cfg_nit` | input | 10 | network idle time in bits | - | static | - |
| `cfg_plen` | input | 4 | payload length of own frames, 2-byte words | - | static | - |
| `cfg_my_slot` | input | 6 | own slot, 0 = none | - | static | - |
| `cfg_sync` | input | 1 | own frames are sync frames | high | static | - |
| `cfg_cold` | input | 1 | coldstart node / time master | high | static | - |
| `cfg_chan_b` | input | 1 | frame CRC init of channel B | high | static | - |
| `cfg_corr` | input | 8 | largest offset correction, clocks | - | static | - |
| `tx_valid` | input | 1 | a payload is offered | high | `clk` | - |
| `tx_ready` | output | 1 | the transmit buffer is empty; combinational from flops | high | `clk` | 1 |
| `tx_data` | input | 128 | payload, byte 0 in bits 7:0 | - | `clk` | - |
| `tx_done` | output | 1 | one-clock pulse: a frame with a queued payload was sent | high | `clk` | 0 |
| `rx_valid` | output | 1 | one-clock pulse: a frame was received | high | `clk` | 0 |
| `rx_id` | output | 6 | frame ID[5:0] (registered every clock from the last header) | - | `clk` | 0 |
| `rx_cycle` | output | 6 | cycle count of the frame | - | `clk` | 0 |
| `rx_len` | output | 7 | payload length, words | - | `clk` | 0 |
| `rx_null` | output | 1 | null frame (indicator 0) | high | `clk` | 1 |
| `rx_sync` | output | 1 | sync frame indicator | high | `clk` | 0 |
| `rx_startup` | output | 1 | startup frame indicator | high | `clk` | 0 |
| `rx_data` | output | 128 | first 16 payload bytes, byte 0 in bits 7:0 | - | `clk` | 0 |
| `synced` | output | 1 | the node follows the cluster schedule | high | `clk` | 0 |
| `cycle` | output | 6 | cycle count | - | `clk` | 0 |
| `slot` | output | 6 | current static slot, 0 = network idle time | - | `clk` | 0 |
| `cycle_start` | output | 1 | one-clock pulse: a cycle starts | high | `clk` | 0 |
| `err_coding` | output | 1 | one-clock pulse: a coding error (not on own frames) | high | `clk` | 0 |
| `err_hcrc` | output | 1 | one-clock pulse: header CRC error | high | `clk` | 0 |
| `err_fcrc` | output | 1 | one-clock pulse: frame CRC error | high | `clk` | 0 |
| `err_slot` | output | 1 | one-clock pulse: ID or cycle count not those of the slot | high | `clk` | 0 |
| `err_sync` | output | 1 | one-clock pulse: synchronisation lost | high | `clk` | 0 |

### Internal signals used by the verification

The TB reads these in the node instances (`u_a`, `u_b`, `u_c`) to time faults; the FSM coverage
collector binds `dst` and `tst`.

| Signal | Width | Meaning |
|---|---|---|
| `sc` | 17 | clocks into the current slot / network idle time |
| `corr` | 18 | offset correction the current frame would apply, clocks; combinational |
| `dst` | 3 | decoder: 0 wait for idle, 1 IDLE, 2 TSS, 3 BSS high, 4 BSS low, 5 DATA, 6 FES low, 7 FES high |
| `slot_s` | 6 | slot when the frame started |
| `strobe` | 1 | bit strobe (sample 5); combinational |
| `tst` | 3 | encoder: 0 IDLE, 1 TSS, 2 FSS, 3 BSS high, 4 BSS low, 5 DATA, 6 FES low, 7 FES high |

## 2. Registers

<!-- AUTO:registers -->
Generated from [`docs/ip/FlexRay.md`](../ip/FlexRay.md) (source: `scripts/apb/specs/FlexRay.json`); do not edit by hand.

`FlexRay_apb` is an APB4 slave (AMBA APB protocol v2.0): zero wait states, 32-bit data, 12-bit byte address, PSTRB byte lanes on every writable register, PSLVERR on an unmapped or misaligned address (reads then return 0, writes are dropped). Writes to read-only registers are ignored without an error. The core runs on PCLK and PRESETN. `irq` is level-high: `|(IRQ_STATUS & IRQ_ENABLE)`.

Pass-through pins: `rxd`, `txd`, `tx_en`.

### Register map

| Offset | Name | Access | Reset | Description |
|---|---|---|---|---|
| 0x000 | ID | RO | 0x46520200 | IP identification: code, major and minor version |
| 0x004 | IRQ_STATUS | W1C | 0x00000000 | Sticky interrupt bits, write 1 to clear |
| 0x008 | IRQ_ENABLE | RW | 0x00000000 | Interrupt enables; irq = \|(IRQ_STATUS & IRQ_ENABLE) |
| 0x00C | FLAGS | RO | 0x00000000 | Stream holding-register state |
| 0x010 | SCRATCH | RW | 0x00000000 | Scratch register, no effect on the core |
| 0x014 | CFG0 | RW | 0x08307850 | Cluster and node configuration (static while the cluster runs) |
| 0x018 | CFG1 | RW | 0x2000001E | Cluster and node configuration (static while the cluster runs) |
| 0x01C | TX0 | RW | 0x00000000 | Payload for the next own frame; writing TX3 commits it. With nothing queued the node sends a null frame |
| 0x020 | TX1 | RW | 0x00000000 | Payload for the next own frame; writing TX3 commits it. With nothing queued the node sends a null frame |
| 0x024 | TX2 | RW | 0x00000000 | Payload for the next own frame; writing TX3 commits it. With nothing queued the node sends a null frame |
| 0x028 | TX3 | RW | 0x00000000 | Payload for the next own frame; writing TX3 commits it. With nothing queued the node sends a null frame |
| 0x02C | RX0 | RO (pop) | 0x00000000 | Valid frame received in its slot (null frames included); reading RX4 frees it |
| 0x030 | RX1 | RO (pop) | 0x00000000 | Valid frame received in its slot (null frames included); reading RX4 frees it |
| 0x034 | RX2 | RO (pop) | 0x00000000 | Valid frame received in its slot (null frames included); reading RX4 frees it |
| 0x038 | RX3 | RO (pop) | 0x00000000 | Valid frame received in its slot (null frames included); reading RX4 frees it |
| 0x03C | RX4 | RO (pop) | 0x00000000 | Valid frame received in its slot (null frames included); reading RX4 frees it |
| 0x040 | STATUS | RO | core | Synchronisation state and position in the cycle |

Unlisted bits read 0 and ignore writes. Reset "core": the register reads the core's outputs directly, so after reset it shows the core's own reset state. WO (pulse) registers read 0. Offsets from 0x044 up to 0xFFC are unmapped (PSLVERR).

### Fields

| Register | Bits | Field | Access | Reset | Description |
|---|---|---|---|---|---|
| ID | 31:16 | CODE | RO | 0x4652 | IP code |
| ID | 15:8 | MAJOR | RO | 0x02 | major version |
| ID | 7:0 | MINOR | RO | 0x00 | minor version |
| IRQ_STATUS | 10:0 | one bit per interrupt | W1C | 0x0 | see Interrupts |
| IRQ_ENABLE | 10:0 | one bit per interrupt | RW | 0x0 | 1 enables the IRQ_STATUS bit onto `irq` |
| FLAGS | 1:0 | one bit per stream flag | RO | 0x0 | see FLAGS |
| SCRATCH | 31:0 | SCRATCH | RW | 0x00000000 | free for software |
| CFG0 | 3:0 | `cfg_spc` | RW | 0x0 | clocks per sample - 1; a bit is 8 samples (0: 8 clocks per bit, 10 Mbit/s at 80 MHz) |
| CFG0 | 7:4 | `cfg_tss` | RW | 0x5 | transmission start sequence length in bits (3..15) |
| CFG0 | 17:8 | `cfg_slot` | RW | 0x78 | static slot length in bits |
| CFG0 | 23:18 | `cfg_ap` | RW | 0xC | action point offset in bits |
| CFG0 | 29:24 | `cfg_nslots` | RW | 0x8 | static slots per cycle (1..63) |
| CFG1 | 9:0 | `cfg_nit` | RW | 0x1E | network idle time in bits |
| CFG1 | 13:10 | `cfg_plen` | RW | 0x0 | payload length of own frames in 2-byte words |
| CFG1 | 19:14 | `cfg_my_slot` | RW | 0x0 | own static slot, 0 = listen only |
| CFG1 | 20 | `cfg_sync` | RW | 0x0 | own frames are sync frames |
| CFG1 | 21 | `cfg_cold` | RW | 0x0 | coldstart node: runs its own schedule and is the time master |
| CFG1 | 22 | `cfg_chan_b` | RW | 0x0 | frame CRC initial value of channel B |
| CFG1 | 30:23 | `cfg_corr` | RW | 0x40 | largest accepted offset correction in clocks |
| TX0 | 31:0 | `tx_data[31:0]` | RW | 0x0 | payload bytes, byte 0 in bits 7:0 (sent first); bytes beyond 2 x CFG.cfg_plen are not sent |
| TX1 | 31:0 | `tx_data[63:32]` | RW | 0x0 | payload bytes, byte 0 in bits 7:0 (sent first); bytes beyond 2 x CFG.cfg_plen are not sent |
| TX2 | 31:0 | `tx_data[95:64]` | RW | 0x0 | payload bytes, byte 0 in bits 7:0 (sent first); bytes beyond 2 x CFG.cfg_plen are not sent |
| TX3 | 31:0 | `tx_data[127:96]` | RW | 0x0 | payload bytes, byte 0 in bits 7:0 (sent first); bytes beyond 2 x CFG.cfg_plen are not sent |
| RX0 | 31:0 | `rx_data[31:0]` | RO (pop) | 0x0 | first 16 payload bytes, byte 0 in bits 7:0 |
| RX1 | 31:0 | `rx_data[63:32]` | RO (pop) | 0x0 | first 16 payload bytes, byte 0 in bits 7:0 |
| RX2 | 31:0 | `rx_data[95:64]` | RO (pop) | 0x0 | first 16 payload bytes, byte 0 in bits 7:0 |
| RX3 | 31:0 | `rx_data[127:96]` | RO (pop) | 0x0 | first 16 payload bytes, byte 0 in bits 7:0 |
| RX4 | 5:0 | `rx_id` | RO (pop) | 0x0 | frame ID (= slot) |
| RX4 | 11:6 | `rx_cycle` | RO (pop) | 0x0 | cycle count |
| RX4 | 18:12 | `rx_len` | RO (pop) | 0x0 | payload length in words |
| RX4 | 19 | `rx_null` | RO (pop) | 0x0 | 1 = null frame |
| RX4 | 20 | `rx_sync` | RO (pop) | 0x0 | sync frame indicator |
| RX4 | 21 | `rx_startup` | RO (pop) | 0x0 | startup frame indicator |
| STATUS | 0 | `synced` | RO | core | 1 = synchronised to the cluster |
| STATUS | 6:1 | `cycle` | RO | core | cycle count |
| STATUS | 12:7 | `slot` | RO | core | current static slot, 0 = network idle time |

### Interrupts (IRQ_STATUS, IRQ_ENABLE)

A bit is set while its source is active, stays set until written with 1, and a set in the same clock as the clear wins.

| Bit | Name | Set when |
|---|---|---|
| 0 | CYCLE | a new communication cycle started |
| 1 | SENT | a frame carrying the queued TX payload was sent |
| 2 | ERR_CODING | coding error (TSS, BSS or FES) |
| 3 | ERR_HCRC | header CRC error |
| 4 | ERR_FCRC | frame CRC error |
| 5 | ERR_SLOT | frame ID or cycle count does not match the slot |
| 6 | ERR_SYNC | synchronisation lost: offset correction beyond CFG.cfg_corr, or a cycle without a sync frame |
| 7 | TX_DONE | TX beat accepted by the core |
| 8 | TX_OVF | write to TX while full (dropped) |
| 9 | RX_AVAIL | RX captured a beat |
| 10 | RX_OVF | beat dropped, RX was full |

### FLAGS

| Bit | Name | Meaning |
|---|---|---|
| 0 | TX_FULL | TX holds a beat the core has not taken |
| 1 | RX_AVAIL | RX holds an unread beat |

### Streams

* **TX** feeds `tx_data`/`tx_valid`. Writing TX3 commits the beat: FLAGS.TX_FULL is set and `tx_valid` stays high until the core's `tx_ready`; then TX_DONE is set. A write while full is dropped and sets TX_OVF.
* **RX** captures `rx_data`, `rx_id`, `rx_cycle`, `rx_len`, `rx_null`, `rx_sync`, `rx_startup` when `rx_valid` is high and the register is empty (or is being read in the same clock), and sets FLAGS/IRQ RX_AVAIL. Reading RX4 pops it. A beat that arrives while the register is full is dropped and sets RX_OVF.

### Programming sequence

1. Release PRESETN. Read ID (0x000) and check it is 0x46520200.
2. Write 0x7FF to IRQ_STATUS (0x004) to clear any stale bits.
3. Configure the core: write CFG0 (0x014), CFG1 (0x018). Reset values are in the register map; PSTRB selects the bytes written.
4. Write IRQ_ENABLE (0x008) with the interrupts to use (bit order as in the Interrupts table; 0x7FF enables all).
5. To send on TX: wait until FLAGS.TX_FULL (bit 0) is 0, or for IRQ TX_DONE, then write TX0 (0x01C) then TX1 (0x020) then TX2 (0x024) then TX3 (0x028). The last write commits the beat. TX_OVF means a write came while the register was full and was dropped.
6. To receive on RX: wait for IRQ RX_AVAIL or FLAGS.RX_AVAIL (bit 1), then read RX0 (0x02C) then RX1 (0x030) then RX2 (0x034) then RX3 (0x038) then RX4 (0x03C). Reading the last word frees the register for the next beat; write 1 to IRQ_STATUS.RX_AVAIL (bit 9) to clear it. Read each beat before the next arrives, or it is dropped and RX_OVF is set.
7. Read STATUS (0x040) for the core's live `synced`, `cycle`, `slot`; it needs no clearing.
8. On `irq`: read IRQ_STATUS, handle every bit that is set and enabled, then write those bits back to IRQ_STATUS to clear them. A source that is still active sets its bit again.
<!-- /AUTO:registers -->

## 3. Timing

### 3.1 Coding

A frame on the line: TSS (`cfg_tss` LOW bits), FSS (HIGH), each byte as BSS (HIGH, LOW) plus 8
bits MSB first, then FES (LOW, HIGH). The transmitter holds `tx_en` = 1 for the whole frame.

Decoding: `rxd` passes two flops and is sampled every `cfg_spc` + 1 clocks; the voted value is a
majority over the last 5 samples; the bit is taken at sample 5. A falling edge of the voted value
in IDLE (start of TSS) or in the low half of a BSS re-aligns the sample counter. Channel idle: 11
HIGH bits. A TSS of 1 .. `cfg_tss` + 1 LOW bits is accepted (a LOW pulse shorter than a bit is
ignored). A bit that is not as the coding requires pulses `err_coding` (not for own frames) and
the decoder waits for idle.

### 3.2 Frame

Header (5 bytes): reserved, payload preamble, null frame indicator (0 = null), sync, startup,
frame ID[10:0], payload length[6:0] (words), header CRC[10:0], cycle count[5:0]; then the payload
and a 24-bit frame CRC. Header CRC: x^11 + x^9 + x^8 + x^7 + x^2 + 1, init 0x01A, over sync,
startup, ID and length. Frame CRC: 0x5D6DCB, init 0xFEDCBA (channel A) or 0xABCDEF
(`cfg_chan_b`), over header and payload.

### 3.3 Schedule

A cycle is `cfg_nslots` static slots of `cfg_slot` bits, then `cfg_nit` bits of network idle
time (`slot` = 0); `cycle` counts 0..63 and `cycle_start` pulses as slot 1 begins. A synchronised
node with `cfg_my_slot` sends one frame in its slot, starting `cfg_ap` bits into it: the buffered
payload (indicator 1, `tx_done` at its end) or, with none, a null frame with zero payload; the
payload is `cfg_plen` words (bytes past 16 are 0), sync = `cfg_sync`, startup = `cfg_sync` and
`cfg_cold`.

### 3.4 Synchronisation

A coldstart node starts its schedule right after reset and is the time master. Another node
integrates on the first valid sync frame with ID 1..`cfg_nslots`: it takes slot = ID and the
cycle count, and sets its slot timer from the time of the frame's first BSS edge (the time the
edge would have at the sender's action point, plus the receive path). Every later sync frame
re-phases it the same way; a correction over `cfg_corr` clocks, or a cycle without a sync frame,
drops synchronisation with `err_sync`. Before integration only sync frames are used.

### 3.5 Reception

At the FES, for frames not sent by this node: header CRC wrong -> `err_hcrc`; frame CRC wrong ->
`err_fcrc`; synchronised and the ID or cycle count is not that of the slot -> `err_slot`;
otherwise `rx_valid` with the header fields and the first 16 payload bytes.

### 3.6 Reset

While `rst_n` is low: not synchronised, decoder waiting for idle, `txd` = 1, `tx_en` = 0, outputs 0.

## 4. Parameters

None.

## 5. Errors and corner cases

| Case | Behaviour |
|---|---|
| coding error | `err_coding`, wait for idle |
| header / frame CRC error | `err_hcrc` / `err_fcrc` |
| frame in the wrong slot or cycle | `err_slot` |
| correction over `cfg_corr`, or a cycle without a sync frame | `err_sync`, re-integrate |
| no payload queued | null frame sent |
| LOW glitch shorter than a bit | ignored |

## 6. TB check map

Messages are printed by `tb/FlexRay_tb.sv` as `ERROR: <message>`. Assertions `a_*` are in the bound
checker `tb/cov/FlexRay_sva.sv`, a cycle model of the node. Three nodes on slightly different
clocks run three cluster configurations; every received frame is checked against what its sender
queued, and errors are counted exactly per node.

| Check (TB message or assertion) | What it requires | Spec |
|---|---|---|
| "no re-integration after a late sync frame" | re-integration after a lost sync | §3.4 |
| "correction limit test: B corrects" | correction applied | §3.4 |
| "no re-integration after the correction limit test" | recovery | §3.4 |
| "integration on a frame that is not a valid sync frame" | integration rules | §3.4 |
| "no integration on the BFM sync frame" | integration | §3.4 |
| "no integration after the master restarted" | integration | §3.4 |
| "B did not integrate after its reset" | integration after reset | §3.4, §3.6 |
| a_reset_values | reset values | §3.6 |
| a_txd_model | `txd` / `tx_en` as the model | §3.1, §3.3 |
| a_tx_ready_model | `tx_ready` | §3.3 |
| a_tx_done_model | `tx_done` | §3.3 |
| a_time_base_model | slot / cycle / sync state | §3.3, §3.4 |
| a_rx_valid_model | `rx_valid` | §3.5 |
| a_rx_frame_model | received fields | §3.5 |
| a_errors_model | error pulses | §3.1, §3.4, §3.5 |
