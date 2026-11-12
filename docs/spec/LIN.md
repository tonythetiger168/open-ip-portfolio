<!-- SPDX-License-Identifier: Apache-2.0 -->
# LIN: design specification

A LIN 2.2A (ISO 17987) node that can send headers (commander) and publish or subscribe to
responses (responder), with optional auto-baud. Not implemented: sleep and wake-up, the bus idle
timeout, the transport layer and diagnostics, schedule tables (the host decides). Core `LIN_top`
(`rtl/LIN_top.sv`), testbench `tb/LIN_tb.sv` (a commander, an auto-baud responder on a different
clock, and a bus driver on one wired-AND bus), checker `tb/cov/LIN_sva.sv`.

Conventions on this page: every flop is clocked on the rising edge of `clk` and reset
asynchronously by `rst_n` low. `rxd` passes two flops before use; "a falling edge" is a 1 -> 0
change of the synchronised level. A byte is a start bit (0), 8 data bits LSB first and a stop bit
(1); bytes are sent back to back. "bt" is `bit_time`.

## 1. Interface

| Port | Dir | Width | Meaning | Active | Clock | Reset |
|---|---|---|---|---|---|---|
| `clk` | input | 1 | clock | rising edge | - | - |
| `rst_n` | input | 1 | asynchronous reset | low | async | - |
| `rxd` | input | 1 | bus level (0 dominant); two-flop synchronised | - | async | - |
| `txd` | output | 1 | transmit (0 dominant, 1 released) | - | `clk` | 1 |
| `cfg_bit` | input | 16 | nominal bit time in clocks (16 or more) | - | static | - |
| `cfg_autobaud` | input | 1 | measure the bit time from each sync byte | high | static | - |
| `hdr_valid` | input | 1 | request to send a header (commander) | high | `clk` | - |
| `hdr_ready` | output | 1 | a header can start; combinational from flops | high | `clk` | 1 |
| `hdr_id` | input | 6 | frame ID of the header | - | `clk` | - |
| `pid_valid` | output | 1 | one-clock pulse: a header was received (any node) | high | `clk` | 0 |
| `pid_id` | output | 6 | ID of that header; holds | - | `clk` | 0 |
| `rsp_ready` | output | 1 | the node waits for its response role; combinational from flops | high | `clk` | 0 |
| `rsp_valid` | input | 1 | role decided this clock | high | `clk` | - |
| `rsp_pub` | input | 1 | 1: publish, 0: subscribe | - | `clk` | - |
| `rsp_len` | input | 3 | data bytes - 1 | - | `clk` | - |
| `rsp_enh` | input | 1 | enhanced checksum (ignored for IDs 60..63) | - | `clk` | - |
| `rsp_data` | input | 64 | published data, byte 0 in bits 7:0 | - | `clk` | - |
| `tx_done` | output | 1 | one-clock pulse: a published response was sent | high | `clk` | 0 |
| `rx_valid` | output | 1 | one-clock pulse: a subscribed response was received with a good checksum | high | `clk` | 0 |
| `rx_id` | output | 6 | its ID; holds | - | `clk` | 0 |
| `rx_len` | output | 3 | its data bytes - 1; holds | - | `clk` | 0 |
| `rx_data` | output | 64 | its data, byte 0 in bits 7:0; holds | - | `clk` | 0 |
| `err_bit` | output | 1 | one-clock pulse: a sent bit read back wrong | high | `clk` | 0 |
| `err_sync` | output | 1 | one-clock pulse: bad sync byte or delimiter | high | `clk` | 0 |
| `err_parity` | output | 1 | one-clock pulse: protected ID parity error | high | `clk` | 0 |
| `err_frame` | output | 1 | one-clock pulse: stop bit dominant | high | `clk` | 0 |
| `err_chk` | output | 1 | one-clock pulse: checksum error | high | `clk` | 0 |
| `err_timeout` | output | 1 | one-clock pulse: subscribed response too late | high | `clk` | 0 |
| `bit_time` | output | 16 | bit time of the current frame, clocks | - | `clk` | 0 |

### Internal signals used by the verification

The TB reads `fst` to see that a frame was dropped; the FSM coverage collector binds `fst` and
`tst`.

| Signal | Width | Meaning |
|---|---|---|
| `fst` | 3 | frame state: 0 IDLE, 1 BREAK, 2 SYNC, 3 PID, 4 RSP (role undecided), 5 RX, 6 TX |
| `tst` | 2 | transmitter: 0 IDLE, 1 BREAK, 2 DELIMITER, 3 BYTES |

## 2. Registers

<!-- AUTO:registers -->
Generated from [`docs/ip/LIN.md`](../ip/LIN.md) (source: `scripts/apb/specs/LIN.json`); do not edit by hand.

`LIN_apb` is an APB4 slave (AMBA APB protocol v2.0): zero wait states, 32-bit data, 12-bit byte address, PSTRB byte lanes on every writable register, PSLVERR on an unmapped or misaligned address (reads then return 0, writes are dropped). Writes to read-only registers are ignored without an error. The core runs on PCLK and PRESETN. `irq` is level-high: `|(IRQ_STATUS & IRQ_ENABLE)`.

Pass-through pins: `rxd`, `txd`.

### Register map

| Offset | Name | Access | Reset | Description |
|---|---|---|---|---|
| 0x000 | ID | RO | 0x4C490200 | IP identification: code, major and minor version |
| 0x004 | IRQ_STATUS | W1C | 0x00000000 | Sticky interrupt bits, write 1 to clear |
| 0x008 | IRQ_ENABLE | RW | 0x00000000 | Interrupt enables; irq = \|(IRQ_STATUS & IRQ_ENABLE) |
| 0x00C | FLAGS | RO | 0x00000000 | Stream holding-register state |
| 0x010 | SCRATCH | RW | 0x00000000 | Scratch register, no effect on the core |
| 0x014 | CFG | RW | 0x00000A2C | Bit timing (static while the bus is in use) |
| 0x018 | HDR | RW | 0x00000000 | Commander: writing an ID sends a header (break, sync, protected ID) |
| 0x01C | PID | RO (pop) | 0x00000000 | Header seen on the bus (own headers included); reading frees it |
| 0x020 | RSP0 | RW | 0x00000000 | This node's role in the next response, taken once a header has been seen; writing RSP2 commits it. Not written before the response starts: the frame is ignored |
| 0x024 | RSP1 | RW | 0x00000000 | This node's role in the next response, taken once a header has been seen; writing RSP2 commits it. Not written before the response starts: the frame is ignored |
| 0x028 | RSP2 | RW | 0x00000000 | This node's role in the next response, taken once a header has been seen; writing RSP2 commits it. Not written before the response starts: the frame is ignored |
| 0x02C | RX0 | RO (pop) | 0x00000000 | Subscribed response received with a good checksum; reading RX2 frees it |
| 0x030 | RX1 | RO (pop) | 0x00000000 | Subscribed response received with a good checksum; reading RX2 frees it |
| 0x034 | RX2 | RO (pop) | 0x00000000 | Subscribed response received with a good checksum; reading RX2 frees it |
| 0x038 | STATUS | RO | core | Bit time in use |

Unlisted bits read 0 and ignore writes. Reset "core": the register reads the core's outputs directly, so after reset it shows the core's own reset state. WO (pulse) registers read 0. Offsets from 0x03C up to 0xFFC are unmapped (PSLVERR).

### Fields

| Register | Bits | Field | Access | Reset | Description |
|---|---|---|---|---|---|
| ID | 31:16 | CODE | RO | 0x4C49 | IP code |
| ID | 15:8 | MAJOR | RO | 0x02 | major version |
| ID | 7:0 | MINOR | RO | 0x00 | minor version |
| IRQ_STATUS | 14:0 | one bit per interrupt | W1C | 0x0 | see Interrupts |
| IRQ_ENABLE | 14:0 | one bit per interrupt | RW | 0x0 | 1 enables the IRQ_STATUS bit onto `irq` |
| FLAGS | 3:0 | one bit per stream flag | RO | 0x0 | see FLAGS |
| SCRATCH | 31:0 | SCRATCH | RW | 0x00000000 | free for software |
| CFG | 15:0 | `cfg_bit` | RW | 0xA2C | nominal bit time in clocks, at least 16 (2604: 19200 bit/s at 50 MHz) |
| CFG | 16 | `cfg_autobaud` | RW | 0x0 | 1 = measure the bit time of each frame on its sync byte (responder without a crystal) |
| HDR | 5:0 | `hdr_id` | RW | 0x0 | frame identifier 0..63 |
| PID | 5:0 | `pid_id` | RO (pop) | 0x0 | frame identifier |
| RSP0 | 31:0 | `rsp_data[31:0]` | RW | 0x0 | data to publish, byte 0 in bits 7:0 (sent first) |
| RSP1 | 31:0 | `rsp_data[63:32]` | RW | 0x0 | data to publish, byte 0 in bits 7:0 (sent first) |
| RSP2 | 2:0 | `rsp_len` | RW | 0x0 | data bytes - 1 |
| RSP2 | 3 | `rsp_pub` | RW | 0x0 | 1 = publish rsp_data, 0 = subscribe |
| RSP2 | 4 | `rsp_enh` | RW | 0x0 | 1 = enhanced checksum (IDs 60..63 always classic) |
| RX0 | 31:0 | `rx_data[31:0]` | RO (pop) | 0x0 | data bytes, byte 0 in bits 7:0, unused bytes 0 |
| RX1 | 31:0 | `rx_data[63:32]` | RO (pop) | 0x0 | data bytes, byte 0 in bits 7:0, unused bytes 0 |
| RX2 | 5:0 | `rx_id` | RO (pop) | 0x0 | frame identifier |
| RX2 | 8:6 | `rx_len` | RO (pop) | 0x0 | data bytes - 1 |
| STATUS | 15:0 | `bit_time` | RO | core | bit time of the current frame in clocks (measured with auto-baud) |

### Interrupts (IRQ_STATUS, IRQ_ENABLE)

A bit is set while its source is active, stays set until written with 1, and a set in the same clock as the clear wins.

| Bit | Name | Set when |
|---|---|---|
| 0 | SENT | a published response was sent completely |
| 1 | ERR_BIT | a sent bit read back wrong; the node stopped sending |
| 2 | ERR_SYNC | break delimiter too long, or sync byte wrong or off-rate |
| 3 | ERR_PARITY | protected ID parity error |
| 4 | ERR_FRAME | dominant stop bit in the PID or the response |
| 5 | ERR_CHK | response checksum error |
| 6 | ERR_TIMEOUT | subscribed response incomplete after 1.4 x its nominal length |
| 7 | HDR_DONE | HDR beat accepted by the core |
| 8 | HDR_OVF | write to HDR while full (dropped) |
| 9 | PID_AVAIL | PID captured a beat |
| 10 | PID_OVF | beat dropped, PID was full |
| 11 | RSP_DONE | RSP beat accepted by the core |
| 12 | RSP_OVF | write to RSP while full (dropped) |
| 13 | RX_AVAIL | RX captured a beat |
| 14 | RX_OVF | beat dropped, RX was full |

### FLAGS

| Bit | Name | Meaning |
|---|---|---|
| 0 | HDR_FULL | HDR holds a beat the core has not taken |
| 1 | PID_AVAIL | PID holds an unread beat |
| 2 | RSP_FULL | RSP holds a beat the core has not taken |
| 3 | RX_AVAIL | RX holds an unread beat |

### Streams

* **HDR** feeds `hdr_id`/`hdr_valid`. Writing HDR commits the beat: FLAGS.HDR_FULL is set and `hdr_valid` stays high until the core's `hdr_ready`; then HDR_DONE is set. A write while full is dropped and sets HDR_OVF.
* **PID** captures `pid_id` when `pid_valid` is high and the register is empty (or is being read in the same clock), and sets FLAGS/IRQ PID_AVAIL. Reading PID pops it. A beat that arrives while the register is full is dropped and sets PID_OVF.
* **RSP** feeds `rsp_data`, `rsp_len`, `rsp_pub`, `rsp_enh`/`rsp_valid`. Writing RSP2 commits the beat: FLAGS.RSP_FULL is set and `rsp_valid` stays high until the core's `rsp_ready`; then RSP_DONE is set. A write while full is dropped and sets RSP_OVF.
* **RX** captures `rx_data`, `rx_id`, `rx_len` when `rx_valid` is high and the register is empty (or is being read in the same clock), and sets FLAGS/IRQ RX_AVAIL. Reading RX2 pops it. A beat that arrives while the register is full is dropped and sets RX_OVF.

### Programming sequence

1. Release PRESETN. Read ID (0x000) and check it is 0x4C490200.
2. Write 0x7FFF to IRQ_STATUS (0x004) to clear any stale bits.
3. Configure the core: write CFG (0x014). Reset values are in the register map; PSTRB selects the bytes written.
4. Write IRQ_ENABLE (0x008) with the interrupts to use (bit order as in the Interrupts table; 0x7FFF enables all).
5. To send on HDR: wait until FLAGS.HDR_FULL (bit 0) is 0, or for IRQ HDR_DONE, then write HDR (0x018). The last write commits the beat. HDR_OVF means a write came while the register was full and was dropped.
6. To receive on PID: wait for IRQ PID_AVAIL or FLAGS.PID_AVAIL (bit 1), then read PID (0x01C). Reading the last word frees the register for the next beat; write 1 to IRQ_STATUS.PID_AVAIL (bit 9) to clear it. Read each beat before the next arrives, or it is dropped and PID_OVF is set.
7. To send on RSP: wait until FLAGS.RSP_FULL (bit 2) is 0, or for IRQ RSP_DONE, then write RSP0 (0x020) then RSP1 (0x024) then RSP2 (0x028). The last write commits the beat. RSP_OVF means a write came while the register was full and was dropped.
8. To receive on RX: wait for IRQ RX_AVAIL or FLAGS.RX_AVAIL (bit 3), then read RX0 (0x02C) then RX1 (0x030) then RX2 (0x034). Reading the last word frees the register for the next beat; write 1 to IRQ_STATUS.RX_AVAIL (bit 13) to clear it. Read each beat before the next arrives, or it is dropped and RX_OVF is set.
9. Read STATUS (0x038) for the core's live `bit_time`; it needs no clearing.
10. On `irq`: read IRQ_STATUS, handle every bit that is set and enabled, then write those bits back to IRQ_STATUS to clear them. A source that is still active sets its bit again.
<!-- /AUTO:registers -->

## 3. Timing

### 3.1 Header reception (every node)

* Break: the bus dominant for 11 x `cfg_bit` clocks. Any break, in any state, restarts the frame
  (state BREAK; a running byte reception and a pending response are dropped).
* BREAK -> SYNC at the first recessive level.
* SYNC: the delimiter may last up to 14 x `cfg_bit` clocks before the first falling edge. The
  next four falling edges must each come 1.5 .. 2.5 nominal bits after the previous one. At the
  fifth edge bt = (clocks from the first to the fifth edge + 5) / 8 with `cfg_autobaud`
  (saturating at 65535), else `cfg_bit`; then bit 7 must be 0 and the stop bit 1, sampled at
  mid-bit. Any failure: `err_sync`, back to IDLE.
* PID: one byte, each bit sampled bt/2 after the start falling edge and then every bt (a start bit
  that is recessive at its sample is a glitch and is ignored). Stop dominant: `err_frame`. Parity
  P0 = ID0^ID1^ID2^ID4, P1 = ~(ID1^ID3^ID4^ID5) wrong: `err_parity`. Otherwise `pid_valid` pulses with
  `pid_id`, the response timer starts and the state becomes RSP.

### 3.2 Response role

In RSP, `rsp_ready` = 1. With `rsp_valid` the node publishes (`rsp_pub`) or subscribes to
`rsp_len` + 1 bytes. The checksum starts from the protected ID when `rsp_enh` and the ID is not
60..63, else from 0. If no role is taken by the first falling edge of the response or within 126
bit times of the header, the frame is ignored (IDLE). A subscriber decided in the clock of the first
start edge still receives the byte.

### 3.3 Subscribe

Bytes are received as in §3.1. Each data byte is added to the checksum (8-bit sum with end-around
carry). After `rsp_len` + 1 bytes the next byte is the checksum: if it equals the inverted sum,
`rx_valid` pulses with `rx_id`, `rx_len`, `rx_data`; else `err_chk`. A dominant stop bit gives
`err_frame`. If the response is not complete 14 x (`rsp_len` + 2) bit times after the header,
`err_timeout`. All of these end the frame.

### 3.4 Transmitter

`hdr_ready` = 1 when the frame state is IDLE or RSP and the transmitter is idle. With `hdr_valid`
the node sends, with bit time `cfg_bit`: 13 dominant bits, a 1-bit recessive delimiter, 0x55 and
the protected ID of `hdr_id`.

A published response starts once the PID stop bit is over (half a bit time after its sample) and
the transmitter is idle: the data bytes then the inverted checksum, with bit time bt. `tx_done`
pulses at the end of the checksum's stop bit.

Every bit is read back at its middle: a mismatch pulses `err_bit`, releases `txd` and stops the
transmitter (the frame then ends).

### 3.5 Reset

While `rst_n` is low: all states idle, `txd` = 1, outputs and `bit_time` 0.

## 4. Parameters

None.

## 5. Errors and corner cases

| Case | Behaviour |
|---|---|
| break in any state | frame restarts |
| delimiter longer than 14 bits, sync edge interval outside 1.5..2.5 bits, sync bit 7 / stop wrong | `err_sync` |
| PID stop dominant / parity | `err_frame` / `err_parity` |
| response checksum wrong | `err_chk` |
| response stop dominant | `err_frame` |
| response too slow | `err_timeout` |
| read-back mismatch while sending | `err_bit`, sending stops |
| role undecided | frame ignored, no error |
| auto-baud measurement over 65535 | `bit_time` = 65535 |

## 6. TB check map

Messages are printed by `tb/LIN_tb.sv` as `ERROR: <message>`. Assertions `a_*` are in the bound
checker `tb/cov/LIN_sva.sv`, a cycle model of the node. The TB counts, per node, headers,
received frames (ID, length, data), sent responses and every error kind, over all 64 IDs both
ways, ignored and late decisions, timeouts, every error injection, glitches and off-rate headers.

| Check (TB message or assertion) | What it requires | Spec |
|---|---|---|
| "nodes not idle" | every frame ends | §3 |
| "undecided frame not dropped" | an undecided frame is ignored | §3.2 |
| "M bit time" | auto-baud saturation | §3.1 |
| a_reset_values | reset values | §3.5 |
| a_txd_model | `txd` as the model | §3.4 |
| a_hdr_ready_model | `hdr_ready` as the model | §3.4 |
| a_rsp_ready_model | `rsp_ready` in RSP only | §3.2 |
| a_pid_model | `pid_valid` as the model | §3.1 |
| a_pid_id_model | `pid_id` with `pid_valid` | §3.1 |
| a_tx_done_model | `tx_done` as the model | §3.4 |
| a_rx_valid_model | `rx_valid` as the model | §3.3 |
| a_rx_frame_model | `rx_id` / `rx_len` / `rx_data` with `rx_valid` | §3.3 |
| a_errors_model | every error pulse as the model | §3.1, §3.3, §3.4 |
| a_bit_time_model | `bit_time` as the model | §3.1 |
