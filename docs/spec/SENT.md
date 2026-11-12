<!-- SPDX-License-Identifier: Apache-2.0 -->
# SENT: design specification

A SAE J2716 SENT transmitter (sensor side) and receiver (ECU side) with the short and enhanced
slow serial channel. Not implemented: SPC (short PWM code) triggers, tick-time variants beyond
the configurable tick, the fast-channel message formats (they only interpret data). Core
`SENT_top` (`rtl/SENT_top.sv`), testbench `tb/SENT_tb.sv`, checker `tb/cov/SENT_sva.sv`.

Conventions on this page: every flop is clocked on the rising edge of `clk` and reset
asynchronously by `rst_n` low. A pulse starts with a falling edge, stays low, then high; the time
between two falling edges (the period) carries the symbol. A nibble of value v is 12 + v ticks.

## 1. Interface

| Port | Dir | Width | Meaning | Active | Clock | Reset |
|---|---|---|---|---|---|---|
| `clk` | input | 1 | clock | rising edge | - | - |
| `rst_n` | input | 1 | asynchronous reset | low | async | - |
| `cfg_crc_legacy` | input | 1 | CRC without the appended zero nibble (pre-2010 form) | high | static | - |
| `tx_en` | input | 1 | transmit frames back to back | high | `clk` | - |
| `cfg_tx_tick_clks` | input | 12 | transmit tick in clocks (values below 4 act as 4) | - | static | - |
| `cfg_tx_low_ticks` | input | 4 | low part of each pulse in ticks, clamped to 4..11 | - | static | - |
| `cfg_tx_nibbles` | input | 3 | data nibbles 1..6 (0 acts as 1, 7 as 6) | - | static | - |
| `cfg_tx_pause_mode` | input | 2 | 0 no pause, 1 fixed pause, 2/3 constant frame length | - | static | - |
| `cfg_tx_pause` | input | 11 | pause ticks (mode 1) or frame ticks (mode 2/3) | - | static | - |
| `tx_status` | input | 4 | status nibble, taken at `tx_frame_start` | - | `clk` | - |
| `tx_data` | input | 24 | data nibbles, nibble i in bits 4i+3:4i, taken at `tx_frame_start` | - | `clk` | - |
| `tx_frame_start` | output | 1 | one-clock pulse: a sync pulse starts (its falling edge) | high | `clk` | 0 |
| `sent_out` | output | 1 | SENT line driven | - | `clk` | 1 |
| `ser_tx_start` | input | 1 | start a serial message (ignored while busy) | high | `clk` | - |
| `ser_tx_enh` | input | 1 | enhanced (18-frame) message | - | `clk` | - |
| `ser_tx_cfg` | input | 1 | enhanced configuration bit C | - | `clk` | - |
| `ser_tx_id` | input | 8 | message ID (short: bits 3:0) | - | `clk` | - |
| `ser_tx_data` | input | 16 | message data (short: bits 7:0; enhanced C=0: 11:0) | - | `clk` | - |
| `ser_tx_busy` | output | 1 | a serial message is being sent | high | `clk` | 0 |
| `ser_tx_done` | output | 1 | one-clock pulse: the last frame of the message started | high | `clk` | 0 |
| `sent_in` | input | 1 | SENT line received; two-flop synchronised | - | async | - |
| `cfg_rx_tick_clks` | input | 12 | nominal receive tick in clocks (4..4095) | - | static | - |
| `cfg_rx_nibbles` | input | 3 | data nibbles expected 1..6 (0 acts as 1, 7 as 6) | - | static | - |
| `cfg_rx_pause` | input | 1 | a pause pulse follows the CRC nibble | high | static | - |
| `cfg_rx_cal_check` | input | 1 | drop frames whose calibration pulse drifts more than 1/64 | high | static | - |
| `cfg_rx_filt` | input | 4 | glitch filter: a level must stay `cfg_rx_filt` + 1 clocks | - | static | - |
| `rx_valid` | output | 1 | one-clock pulse: a good frame | high | `clk` | 0 |
| `rx_status` | output | 4 | its status nibble; holds | - | `clk` | 0 |
| `rx_data` | output | 24 | its data nibbles (unused nibbles 0); holds | - | `clk` | 0 |
| `rx_cal_clks` | output | 19 | its calibration pulse in clocks; holds | - | `clk` | 0 |
| `rx_err_nibble` | output | 1 | one-clock pulse: a period that is no nibble | high | `clk` | 0 |
| `rx_err_low` | output | 1 | one-clock pulse: a low part shorter than 3.5 ticks | high | `clk` | 0 |
| `rx_err_crc` | output | 1 | one-clock pulse: CRC mismatch | high | `clk` | 0 |
| `rx_err_pause` | output | 1 | one-clock pulse: a pause outside 12..768 ticks | high | `clk` | 0 |
| `rx_err_sync` | output | 1 | one-clock pulse: no calibration pulse where one was due | high | `clk` | 0 |
| `rx_err_cal` | output | 1 | one-clock pulse: calibration drift over 1/64 | high | `clk` | 0 |
| `ser_rx_valid` | output | 1 | one-clock pulse: a serial message | high | `clk` | 0 |
| `ser_rx_enh` | output | 1 | it was enhanced; holds | - | `clk` | 0 |
| `ser_rx_cfg` | output | 1 | its configuration bit; holds | - | `clk` | 0 |
| `ser_rx_id` | output | 8 | its ID; holds | - | `clk` | 0 |
| `ser_rx_data` | output | 16 | its data; holds | - | `clk` | 0 |
| `ser_rx_err_crc` | output | 1 | one-clock pulse: serial message CRC error | high | `clk` | 0 |

### Internal signals used by the verification

The TB waits on `tst` to see the transmitter idle; the FSM coverage collector binds `tst` and
`rst`.

| Signal | Width | Meaning |
|---|---|---|
| `tst` | 3 | transmitter: 0 IDLE, 1 SYNC, 2 STATUS, 3 DATA, 4 CRC, 5 PAUSE |
| `rst` | 3 | receiver: 0 HUNT, 1 STATUS, 2 DATA, 3 CRC, 4 PAUSE, 5 SYNC (next calibration pulse due) |

## 2. Registers

<!-- AUTO:registers -->
Generated from [`docs/ip/SENT.md`](../ip/SENT.md) (source: `scripts/apb/specs/SENT.json`); do not edit by hand.

`SENT_apb` is an APB4 slave (AMBA APB protocol v2.0): zero wait states, 32-bit data, 12-bit byte address, PSTRB byte lanes on every writable register, PSLVERR on an unmapped or misaligned address (reads then return 0, writes are dropped). Writes to read-only registers are ignored without an error. The core runs on PCLK and PRESETN. `irq` is level-high: `|(IRQ_STATUS & IRQ_ENABLE)`.

Pass-through pins: `sent_out`, `sent_in`.

### Register map

| Offset | Name | Access | Reset | Description |
|---|---|---|---|---|
| 0x000 | ID | RO | 0x4A320100 | IP identification: code, major and minor version |
| 0x004 | IRQ_STATUS | W1C | 0x00000000 | Sticky interrupt bits, write 1 to clear |
| 0x008 | IRQ_ENABLE | RW | 0x00000000 | Interrupt enables; irq = \|(IRQ_STATUS & IRQ_ENABLE) |
| 0x00C | FLAGS | RO | 0x00000000 | Stream holding-register state |
| 0x010 | SCRATCH | RW | 0x00000000 | Scratch register, no effect on the core |
| 0x014 | CTRL | RW | 0x00000000 | Control |
| 0x018 | TX_CFG | RW | 0x00065096 | Transmitter timing and format |
| 0x01C | TX_PAUSE | RW | 0x00000000 | Pause length or constant frame length |
| 0x020 | TX_FRAME | RW | 0x00000000 | Next frame's content, taken when a frame starts (IRQ TX_FRAME) |
| 0x024 | SER_TX | RW | 0x00000000 | Serial message to send |
| 0x028 | CMD | WO (pulse) | 0x00000000 | Commands |
| 0x02C | RX_CFG | RW | 0x00016096 | Receiver |
| 0x030 | STATUS | RO | core | Status |
| 0x034 | RX0 | RO (pop) | 0x00000000 | Received frame; reading RX1 frees it |
| 0x038 | RX1 | RO (pop) | 0x00000000 | Received frame; reading RX1 frees it |
| 0x03C | SER_RX | RO (pop) | 0x00000000 | Received serial message; reading SER_RX frees it |

Unlisted bits read 0 and ignore writes. Reset "core": the register reads the core's outputs directly, so after reset it shows the core's own reset state. WO (pulse) registers read 0. Offsets from 0x040 up to 0xFFC are unmapped (PSLVERR).

### Fields

| Register | Bits | Field | Access | Reset | Description |
|---|---|---|---|---|---|
| ID | 31:16 | CODE | RO | 0x4A32 | IP code |
| ID | 15:8 | MAJOR | RO | 0x01 | major version |
| ID | 7:0 | MINOR | RO | 0x00 | minor version |
| IRQ_STATUS | 12:0 | one bit per interrupt | W1C | 0x0 | see Interrupts |
| IRQ_ENABLE | 12:0 | one bit per interrupt | RW | 0x0 | 1 enables the IRQ_STATUS bit onto `irq` |
| FLAGS | 1:0 | one bit per stream flag | RO | 0x0 | see FLAGS |
| SCRATCH | 31:0 | SCRATCH | RW | 0x00000000 | free for software |
| CTRL | 0 | `tx_en` | RW | 0x0 | 1 = send frames back to back |
| CTRL | 1 | `cfg_crc_legacy` | RW | 0x0 | 1 = the pre-2010 CRC (no appended zero nibble), both directions |
| CTRL | 2 | `cfg_rx_pause` | RW | 0x0 | 1 = a pause pulse must follow the CRC nibble |
| CTRL | 3 | `cfg_rx_cal_check` | RW | 0x0 | 1 = drop a frame whose calibration pulse is more than 1/64 off the one before |
| TX_CFG | 11:0 | `cfg_tx_tick_clks` | RW | 0x96 | PCLK cycles per tick, 4..4095 (150: 3 us at 50 MHz) |
| TX_CFG | 15:12 | `cfg_tx_low_ticks` | RW | 0x5 | low part of every pulse in ticks, 4..11 (clamped) |
| TX_CFG | 18:16 | `cfg_tx_nibbles` | RW | 0x6 | data nibbles, 1..6 (0 = 1, 7 = 6) |
| TX_CFG | 20:19 | `cfg_tx_pause_mode` | RW | 0x0 | 0 no pause, 1 a fixed pause of TX_PAUSE ticks, 2 / 3 constant frames of TX_PAUSE ticks |
| TX_PAUSE | 10:0 | `cfg_tx_pause` | RW | 0x0 | ticks (the pause itself is clamped to 12..768) |
| TX_FRAME | 3:0 | `tx_status` | RW | 0x0 | status and communication nibble (bits 3:2 are the serial channel's while SER_TX runs) |
| TX_FRAME | 27:4 | `tx_data` | RW | 0x0 | data nibbles, nibble i in bits 4i+3:4i, nibble 0 sent first |
| SER_TX | 7:0 | `ser_tx_id` | RW | 0x0 | message ID (short: 4 bits, enhanced: 8 bits or 4 with ser_tx_cfg) |
| SER_TX | 23:8 | `ser_tx_data` | RW | 0x0 | data (short: 8 bits, enhanced: 12 bits or 16 with ser_tx_cfg) |
| SER_TX | 24 | `ser_tx_enh` | RW | 0x0 | 1 = enhanced message (18 frames), 0 = short (16 frames) |
| SER_TX | 25 | `ser_tx_cfg` | RW | 0x0 | enhanced configuration bit C: 1 = 4-bit ID, 16-bit data |
| CMD | 0 | `ser_tx_start` | WO (pulse) | 0x0 | 1 = send SER_TX from the next frame on (ignored while one is sent) |
| RX_CFG | 11:0 | `cfg_rx_tick_clks` | RW | 0x96 | nominal PCLK cycles per tick; calibration pulses within +-25 % are accepted |
| RX_CFG | 14:12 | `cfg_rx_nibbles` | RW | 0x6 | data nibbles, 1..6 (0 = 1, 7 = 6) |
| RX_CFG | 18:15 | `cfg_rx_filt` | RW | 0x2 | glitch filter: the line must be stable for this many PCLK cycles |
| STATUS | 0 | `ser_tx_busy` | RO | core | a serial message is being sent |
| RX0 | 3:0 | `rx_status` | RO (pop) | 0x0 | status and communication nibble |
| RX0 | 27:4 | `rx_data` | RO (pop) | 0x0 | data nibbles (nibble i in bits 4i+3:4i; past RX_CFG nibbles read 0) |
| RX1 | 18:0 | `rx_cal_clks` | RO (pop) | 0x0 | calibration pulse of the frame in PCLK cycles (56 ticks) |
| SER_RX | 0 | `ser_rx_enh` | RO (pop) | 0x0 | 1 = enhanced message |
| SER_RX | 1 | `ser_rx_cfg` | RO (pop) | 0x0 | enhanced configuration bit C |
| SER_RX | 9:2 | `ser_rx_id` | RO (pop) | 0x0 | message ID |
| SER_RX | 25:10 | `ser_rx_data` | RO (pop) | 0x0 | message data |

### Interrupts (IRQ_STATUS, IRQ_ENABLE)

A bit is set while its source is active, stays set until written with 1, and a set in the same clock as the clear wins.

| Bit | Name | Set when |
|---|---|---|
| 0 | TX_FRAME | a frame started (TX_FRAME was taken) |
| 1 | SER_TX_DONE | the serial message went out with its last frame |
| 2 | ERR_NIBBLE | a period that is no nibble, or a calibration pulse inside a frame |
| 3 | ERR_LOW | a low part shorter than 3.5 ticks |
| 4 | ERR_CRC | wrong CRC nibble |
| 5 | ERR_PAUSE | a pause outside 12..768 ticks |
| 6 | ERR_SYNC | no calibration pulse where one was due |
| 7 | ERR_CAL | a calibration pulse more than 1/64 off the previous one (the frame is dropped) |
| 8 | SER_CRC | a serial message with a wrong CRC |
| 9 | RX_AVAIL | RX captured a beat |
| 10 | RX_OVF | beat dropped, RX was full |
| 11 | SER_RX_AVAIL | SER_RX captured a beat |
| 12 | SER_RX_OVF | beat dropped, SER_RX was full |

### FLAGS

| Bit | Name | Meaning |
|---|---|---|
| 0 | RX_AVAIL | RX holds an unread beat |
| 1 | SER_RX_AVAIL | SER_RX holds an unread beat |

### Streams

* **RX** captures `rx_status`, `rx_data`, `rx_cal_clks` when `rx_valid` is high and the register is empty (or is being read in the same clock), and sets FLAGS/IRQ RX_AVAIL. Reading RX1 pops it. A beat that arrives while the register is full is dropped and sets RX_OVF.
* **SER_RX** captures `ser_rx_enh`, `ser_rx_cfg`, `ser_rx_id`, `ser_rx_data` when `ser_rx_valid` is high and the register is empty (or is being read in the same clock), and sets FLAGS/IRQ SER_RX_AVAIL. Reading SER_RX pops it. A beat that arrives while the register is full is dropped and sets SER_RX_OVF.

### Programming sequence

1. Release PRESETN. Read ID (0x000) and check it is 0x4A320100.
2. Write 0x1FFF to IRQ_STATUS (0x004) to clear any stale bits.
3. Configure the core: write CTRL (0x014), TX_CFG (0x018), TX_PAUSE (0x01C), TX_FRAME (0x020), SER_TX (0x024), RX_CFG (0x02C). Reset values are in the register map; PSTRB selects the bytes written.
4. Write IRQ_ENABLE (0x008) with the interrupts to use (bit order as in the Interrupts table; 0x1FFF enables all).
5. To issue a command, write 1 to `ser_tx_start` (CMD bit 0) at 0x028; the core sees a one-clock pulse, and the register reads 0.
6. Read STATUS (0x030) for the core's live `ser_tx_busy`; it needs no clearing.
7. To receive on RX: wait for IRQ RX_AVAIL or FLAGS.RX_AVAIL (bit 0), then read RX0 (0x034) then RX1 (0x038). Reading the last word frees the register for the next beat; write 1 to IRQ_STATUS.RX_AVAIL (bit 9) to clear it. Read each beat before the next arrives, or it is dropped and RX_OVF is set.
8. To receive on SER_RX: wait for IRQ SER_RX_AVAIL or FLAGS.SER_RX_AVAIL (bit 1), then read SER_RX (0x03C). Reading the last word frees the register for the next beat; write 1 to IRQ_STATUS.SER_RX_AVAIL (bit 11) to clear it. Read each beat before the next arrives, or it is dropped and SER_RX_OVF is set.
9. On `irq`: read IRQ_STATUS, handle every bit that is set and enabled, then write those bits back to IRQ_STATUS to clear them. A source that is still active sets its bit again.

IP-specific use:

1. Transmit: TX_CFG, TX_PAUSE, TX_FRAME, then CTRL.tx_en; on IRQ TX_FRAME write the next TX_FRAME. Serial: write SER_TX, CMD.ser_tx_start, wait for IRQ SER_TX_DONE.
2. Receive: RX_CFG and CTRL, IRQ_ENABLE; on IRQ RX_AVAIL read RX0, RX1; on SER_RX_AVAIL read SER_RX; error bits as they come.
<!-- /AUTO:registers -->

## 3. Timing

### 3.1 Frame and CRCs

A frame: a 56-tick calibration pulse, the status nibble, N data nibbles (nibble 0 first), the CRC
nibble and an optional pause pulse (12..768 ticks).

* Fast CRC: x^4 + x^3 + x^2 + 1, seed 0101, over the data nibbles MSB first (not the status),
  then a zero nibble unless `cfg_crc_legacy`.
* Short serial message (16 frames): status bit 3 = 1 then 15 zeros; bit 2 = ID[3:0], data[7:0],
  CRC-4 of {ID, data} (as the fast CRC).
* Enhanced serial message (18 frames): bit 3 = 111111, 0, C, a3..a0, 0, b3..b0, 0; bit 2 = CRC-6
  (x^6 + x^4 + x^3 + 1, seed 010101, over bit 2 then bit 3 of frames 7..18, then six zeros) followed
  by 12 data bits. C = 0: ID = {a, b}, data = 12 bits; C = 1: ID = a, data = {b, 12 bits}.

### 3.2 Transmitter

A tick is `cfg_tx_tick_clks` clocks; each pulse is low for `cfg_tx_low_ticks` ticks. When idle
with `tx_en`, and at the end of each frame, a new frame starts: `tx_frame_start` pulses as
`sent_out` falls, and status, data and the nibble count are taken. Without `tx_en` at that point
the line stays high (idle). Pause: mode 0 none; mode 1 `cfg_tx_pause` ticks clamped to 12..768;
mode 2/3 `cfg_tx_pause` minus the frame's ticks so far, at least 12, at most 768.

`ser_tx_start` while not busy loads a message and sets `ser_tx_busy`. From the next frame start,
each frame's status bits 3:2 come from the message (overriding `tx_status`); at the start of the
last frame `ser_tx_busy` clears and `ser_tx_done` pulses.

### 3.3 Receiver input

`sent_in` passes two flops, then a filter: the filtered level follows only after the new level has
been seen for `cfg_rx_filt` + 1 clocks. A filtered falling edge ends a period P (in clocks).

### 3.4 Receiver decoding

* A period within 0.75..1.25 x 56 x `cfg_rx_tick_clks` clocks, in any state but PAUSE, is a
  calibration pulse: it starts a frame and gives the tick for it (cal = P). If a frame was being
  received, `rx_err_nibble` pulses for it.
* With `cfg_rx_cal_check`, a calibration pulse right after a frame (state SYNC) that differs from
  the previous one by more than cal_prev / 64 pulses `rx_err_cal` and that frame gives no
  `rx_valid` (it is still received).
* In SYNC any other period: `rx_err_sync`, HUNT.
* Other periods are divided: ticks = round(56 x P / cal). A nibble must be 12..27 ticks
  (`rx_err_nibble`) with a low part of at least cal / 16 (3.5 ticks; `rx_err_low`); either error
  goes to HUNT. Errors decided by the division come 13 clocks after the edge's errors would
  (2 for a period of 1024 ticks or more).
* After the CRC nibble: CRC correct (and no drift drop) gives `rx_valid` with status, data
  (nibbles beyond `cfg_rx_nibbles` read 0) and `rx_cal_clks`; else `rx_err_crc`. Then PAUSE (with
  `cfg_rx_pause`) or SYNC. A pause outside 12..768 ticks or with a short low part: `rx_err_pause`,
  HUNT.
* At most one error pulses per clock, never with `rx_valid`.

### 3.5 Serial decoder

Each good frame shifts status bits 3 and 2 into an 18-frame history; any bad frame clears it.
After each good frame: with 18 frames and the enhanced bit 3 pattern, the CRC-6 is checked; else
with 16 frames whose bit 3 is 1 then 15 zeros, the CRC-4 is checked. Either way `ser_rx_valid`
(with the decoded fields) or `ser_rx_err_crc` pulses and the history is cleared.

### 3.6 Reset

While `rst_n` is low: both sides idle (`sent_out` = 1, receiver HUNT), all outputs 0.

## 4. Parameters

None.

## 5. Errors and corner cases

| Case | Behaviour |
|---|---|
| calibration pulse during a frame | `rx_err_nibble`, new frame starts |
| nibble outside 12..27 ticks / low part short | `rx_err_nibble` / `rx_err_low`, HUNT |
| CRC wrong | `rx_err_crc` |
| pause wrong (with `cfg_rx_pause`) | `rx_err_pause`, HUNT |
| missing calibration pulse after a frame | `rx_err_sync`, HUNT |
| calibration drift over 1/64 (with `cfg_rx_cal_check`) | `rx_err_cal`, frame dropped |
| glitch shorter than `cfg_rx_filt` + 1 clocks | ignored |
| long idle line | period counter saturates (22 bits) |
| `ser_tx_start` while busy | ignored |

## 6. TB check map

Messages are printed by `tb/SENT_tb.sv` as `ERROR: <message>`. Assertions `a_*` are in the bound
checker `tb/cov/SENT_sva.sv`, which has a transmitter model and a pulse-level reference receiver
with a schedule of expected outputs. The TB measures every transmitted pulse, runs a sensor BFM
and loopback into the receiver with every error kind, tick drift and glitches.

| Check (TB message or assertion) | What it requires | Spec |
|---|---|---|
| "ser_tx_done missing" | message completes | §3.2 |
| "ser_tx_done without a message" | no stray done | §3.2 |
| "ser_tx_done outside a frame start" | done at the last frame start | §3.2 |
| "transmitter pulse not expected" | pulses only while a frame is due | §3.2 |
| "pulse of" | each pulse length as the frame | §3.1, §3.2 |
| "low part of" | low part as configured | §3.2 |
| "serial transmitter busy" | busy until the message is sent | §3.2 |
| "ser_tx_busy not set" | busy after start | §3.2 |
| "reset values" | reset values | §3.6 |
| a_tx_line | `sent_out` as the model | §3.2 |
| a_tx_frame_start | `tx_frame_start` as the model | §3.2 |
| a_ser_tx_busy | `ser_tx_busy` as the model | §3.2 |
| a_ser_tx_done | `ser_tx_done` as the model | §3.2 |
| a_tx_frame_starts_low | the line is low at a frame start | §3.2 |
| a_rx_valid | `rx_valid` and errors at the scheduled clock | §3.4 |
| a_rx_errors | each error kind as the model | §3.4 |
| a_rx_frame_data | status / data / calibration with `rx_valid` | §3.4 |
| a_ser_rx_valid | serial message results as the model | §3.5 |
| a_ser_rx_data | serial message fields | §3.5 |
| a_rx_schedule | no expected output missed | §3.4 |
| a_rx_one_error | one error at a time, never with `rx_valid` | §3.4 |
