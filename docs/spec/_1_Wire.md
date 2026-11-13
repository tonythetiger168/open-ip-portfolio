<!-- SPDX-License-Identifier: Apache-2.0 -->
# _1_Wire: design specification

1-Wire slave with a fixed, simplified transaction: after a bus reset the core answers with a
presence pulse, receives one byte in 8 write slots (LSB first) and reports it on `rx_byte`, then
sends `tx_byte` in the next 8 read slots, and repeats (byte in, byte out) until the next bus
reset. There is no ROM code, no command decoding, no search algorithm and no overdrive speed:
the received byte is simply handed to the host, which supplies the reply. Slot timing is counted
in `clk` cycles with `US` cycles per microsecond. Core `_1_Wire_top` (`rtl/_1_Wire_top.sv`),
testbench `tb/_1_Wire_tb.sv`, checker `tb/cov/_1_Wire_sva.sv`.

Conventions on this page: every flop is clocked on the rising edge of `clk` and reset
asynchronously by `rst_n` low. Times in "us" are multiples of `US` `clk` cycles; a *fall* is a
falling edge of DQ as seen through the synchronizer (§3.1).

## 1. Interface

| Port | Dir | Width | Meaning | Active | Clock | Reset |
|---|---|---|---|---|---|---|
| `clk` | input | 1 | core clock; `US` cycles of it make one microsecond of bus time | rising edge | - | - |
| `rst_n` | input | 1 | asynchronous reset of the slave engine | low | async assert | - |
| `dq` | inout | 1 | 1-Wire data line, open drain: the core only drives 0 (`drv_low` = 1), else high-Z; needs a pull-up | - | sampled by 2 flops; drive comb. from `state` | released |
| `tx_byte` | input | 8 | byte to send in the read slots that follow each received byte; latched when that byte completes | - | `clk` | - |
| `rx_byte` | output | 8 | last byte received in write slots | - | `clk` | 0x00 |
| `rx_valid` | output | 1 | one-`clk` pulse when the 8th write slot of a byte has been sampled; `rx_byte` changes only in that cycle | high | `clk` | 0 |
| `busy` | output | 1 | `state` != IDLE: 1 from the first low on the bus until a glitch returns to IDLE or `rst_n`; after a valid bus reset it stays 1 | high | comb. from `state` | 0 |
| `irq` | output | 1 | equal to `rx_valid` | high | `clk` | 0 |

### Internal signals used by the verification

The TB and the checker read these by name; a re-implementation must have them.

| Signal | Width | Meaning |
|---|---|---|
| `state` | 3 | encoded IDLE = 0, RESET_CNT = 1, RESET_REL = 2, PRESENCE = 3, WAIT_SLOT = 4, W_SAMPLE = 5, R_DRIVE = 6, TX_BYTE = 7 |
| `drv_low` | 1 | 1 while the core pulls DQ low: PRESENCE with the timer >= 15 us, or R_DRIVE with `tx_shift[0]` = 0 |
| `tx_shift` | 8 | read-data shifter, bit 0 is the bit of the current read slot |

## 2. Registers

<!-- AUTO:registers -->
Generated from [`docs/ip/_1_Wire.md`](../ip/_1_Wire.md) (source: `scripts/apb/specs/_1_Wire.json`); do not edit by hand.

`_1_Wire_apb` is an APB4 slave (AMBA APB protocol v2.0): zero wait states, 32-bit data, 12-bit byte address, PSTRB byte lanes on every writable register, PSLVERR on an unmapped or misaligned address (reads then return 0, writes are dropped). Writes to read-only registers are ignored without an error. The core runs on PCLK and PRESETN. `irq` is level-high: `|(IRQ_STATUS & IRQ_ENABLE)`.

Pass-through pins: `dq`.

### Register map

| Offset | Name | Access | Reset | Description |
|---|---|---|---|---|
| 0x000 | ID | RO | 0x31570200 | IP identification: code, major and minor version |
| 0x004 | IRQ_STATUS | W1C | 0x00000000 | Sticky interrupt bits, write 1 to clear |
| 0x008 | IRQ_ENABLE | RW | 0x00000000 | Interrupt enables; irq = \|(IRQ_STATUS & IRQ_ENABLE) |
| 0x00C | FLAGS | RO | 0x00000000 | Stream holding-register state |
| 0x010 | SCRATCH | RW | 0x00000000 | Scratch register, no effect on the core |
| 0x014 | TX | RW | 0x00000000 | Byte returned on the read slots after each byte received |
| 0x018 | RX | RO (pop) | 0x00000000 | Bytes written by the controller; reading RX frees it |
| 0x01C | STATUS | RO | core | Target state |

Unlisted bits read 0 and ignore writes. Reset "core": the register reads the core's outputs directly, so after reset it shows the core's own reset state. WO (pulse) registers read 0. Offsets from 0x020 up to 0xFFC are unmapped (PSLVERR).

### Fields

| Register | Bits | Field | Access | Reset | Description |
|---|---|---|---|---|---|
| ID | 31:16 | CODE | RO | 0x3157 | IP code |
| ID | 15:8 | MAJOR | RO | 0x02 | major version |
| ID | 7:0 | MINOR | RO | 0x00 | minor version |
| IRQ_STATUS | 2:0 | one bit per interrupt | W1C | 0x0 | see Interrupts |
| IRQ_ENABLE | 2:0 | one bit per interrupt | RW | 0x0 | 1 enables the IRQ_STATUS bit onto `irq` |
| FLAGS | 0 | one bit per stream flag | RO | 0x0 | see FLAGS |
| SCRATCH | 31:0 | SCRATCH | RW | 0x00000000 | free for software |
| TX | 7:0 | `tx_byte` | RW | 0x0 | taken when a byte's last write slot is sampled, then sent LSB first on the next 8 read slots |
| RX | 7:0 | `rx_byte` | RO (pop) | 0x0 | Bytes written by the controller; reading RX frees it |
| STATUS | 0 | `busy` | RO | core | between a reset pulse and the bus going idle (not cleared by the transfer ending: only the core's reset returns it to idle) |

### Interrupts (IRQ_STATUS, IRQ_ENABLE)

A bit is set while its source is active, stays set until written with 1, and a set in the same clock as the clear wins.

| Bit | Name | Set when |
|---|---|---|
| 0 | BYTE | a byte was received (the same clock RX captures it) |
| 1 | RX_AVAIL | RX captured a beat |
| 2 | RX_OVF | beat dropped, RX was full |

### FLAGS

| Bit | Name | Meaning |
|---|---|---|
| 0 | RX_AVAIL | RX holds an unread beat |

### Streams

* **RX** captures `rx_byte` when `rx_valid` is high and the register is empty (or is being read in the same clock), and sets FLAGS/IRQ RX_AVAIL. Reading RX pops it. A beat that arrives while the register is full is dropped and sets RX_OVF.

### Programming sequence

1. Release PRESETN. Read ID (0x000) and check it is 0x31570200.
2. Write 0x7 to IRQ_STATUS (0x004) to clear any stale bits.
3. Configure the core: write TX (0x014). Reset values are in the register map; PSTRB selects the bytes written.
4. Write IRQ_ENABLE (0x008) with the interrupts to use (bit order as in the Interrupts table; 0x7 enables all).
5. To receive on RX: wait for IRQ RX_AVAIL or FLAGS.RX_AVAIL (bit 0), then read RX (0x018). Reading the last word frees the register for the next beat; write 1 to IRQ_STATUS.RX_AVAIL (bit 1) to clear it. Read each beat before the next arrives, or it is dropped and RX_OVF is set.
6. Read STATUS (0x01C) for the core's live `busy`; it needs no clearing.
7. On `irq`: read IRQ_STATUS, handle every bit that is set and enabled, then write those bits back to IRQ_STATUS to clear them. A source that is still active sets its bit again.
<!-- /AUTO:registers -->

## 3. Timing

### 3.1 Sampling and bus reset detection

At every `clk` edge `dq_s <= dq`, `dq_d <= dq_s` (both reset to 1). A fall is `dq_d && !dq_s`.
A free-running counter `low_cnt` counts consecutive cycles with `dq_s` = 0 (cleared when DQ is
high, saturating just past the threshold). Bus reset is recognised when `low_cnt` > 480 us. The
master's reset pulse must therefore be longer than 480 us + 1 cycle; the TB uses 600 us.

From IDLE, the first low moves to RESET_CNT, which counts the same 480 us; if DQ goes high
earlier the pulse was a glitch and the engine returns to IDLE (no presence pulse). In WAIT_SLOT,
W_SAMPLE, TX_BYTE and R_DRIVE a recognised bus reset abandons the transaction at once (bit count
cleared). Either way the engine waits in RESET_REL for DQ to go high.

### 3.2 Presence pulse

When DQ is high in RESET_REL the engine enters PRESENCE with a timer at 0. DQ is driven low while
the timer is between 15 us and 135 us (tPDH = 15 us, tPDL = 120 us); then the engine goes to
WAIT_SLOT with a bit count of 0. A master sampling at 70 us after its rising edge (as the TB does)
sees the presence.

### 3.3 Write slots (byte from the master)

In WAIT_SLOT, a fall starts a slot (W_SAMPLE, timer 0). When the timer reaches 30 us, `dq_s` is
the bit: 0 if the master still holds the line (write 0, held 60 us or more), 1 if it released it
(write 1, low for 1 to 15 us). Bits are assembled LSB first. After the 8th bit, `rx_byte` <= the
byte, `rx_valid` (and `irq`) pulses for one `clk`, `tx_shift` <= `tx_byte` and the engine goes to
TX_BYTE; otherwise it returns to WAIT_SLOT. Slots must be at least 30 us + recovery apart; the TB
uses 80 us slots.

### 3.4 Read slots (byte to the master)

In TX_BYTE, a fall starts a read slot (R_DRIVE, timer 0). If `tx_shift[0]` = 0 the core drives
DQ low from about 3 `clk` after the master's fall (2 synchronizer stages plus the state update)
until the timer passes 40 us; for a 1 it leaves the line released. The master samples at about
15 us. After the slot the shifter moves to the next bit (LSB first) and the engine returns to
TX_BYTE; after the 8th slot it returns to WAIT_SLOT for the next byte from the master.

So every byte the master writes is followed by exactly 8 read slots. A master that writes another
byte instead would see its write-1 slots pulled low by any 0 bits of `tx_byte`.

### 3.5 Reset

`rst_n` low: IDLE, DQ released at once, `rx_valid` = 0, `busy` = 0, `rx_byte` = 0, synchronizers
to 1, `low_cnt` = 0.

## 4. Parameters

| Parameter | Default | Legal range | Effect |
|---|---|---|---|
| `US` | 10 | >= 2 | `clk` cycles per microsecond of bus time: the core clock frequency in MHz (the TB runs at 100 MHz with `US` = 10, i.e. 10x faster than real 1-Wire timing). All slot times scale with it; the timer width is sized from 480 x `US` |

## 5. Errors and corner cases

| Case | Behaviour |
|---|---|
| low pulse shorter than 480 us from IDLE | glitch: back to IDLE, no presence, `busy` returns to 0 |
| bus reset in the middle of a write byte | transaction abandoned, presence pulse after the release. The reset's falling edge is first taken as a write-0 slot; if that was the 8th bit a byte with bit 7 = 0 is reported before the reset is recognised |
| bus reset in the middle of a read byte | the current read slot may hold DQ low for up to 40 us more, then the reset is recognised and answered with presence |
| bus reset after a complete read byte | recognised from WAIT_SLOT: presence, next byte received normally |
| master writes instead of reading after a byte | write slots are treated as read slots (§3.4) |
| `tx_byte` changes during the read slots | ignored; the value latched at the end of the received byte is sent |
| `busy` after a transaction | stays 1 (the engine never returns to IDLE except through a glitch or `rst_n`) |

## 6. TB check map

Messages are printed by `tb/_1_Wire_tb.sv` as `ERROR: <message>` (A1..A6 as `SVA_FAIL:`); "CRV"
messages and A1..A6 are built only for Verilator. Assertions a_* are in `tb/cov/_1_Wire_sva.sv`.
The TB is the bus master with the standard slot shapes (600 us reset, presence sampled at 70 us,
80 us slots, write 0 held 62 us, read sampled at 15 us).

| Check (TB message or assertion) | What it requires | Spec |
|---|---|---|
| "1-Wire no presence pulse" | presence after the first bus reset | §3.1, §3.2 |
| "1-Wire rx_valid never pulsed" | command 0xCC written: `rx_valid` pulses | §3.3 |
| "1-Wire rx" | `rx_byte` = 0xCC | §3.3 |
| "1-Wire read" | the next 8 read slots return `tx_byte` = 0x5A LSB first | §3.4 |
| "1-Wire no presence after post-read reset" | bus reset after a complete read byte is recognised | §3.1 |
| "1-Wire rx_valid never pulsed after post-read reset" | the next byte is received | §3.3 |
| "1-Wire post-reset rx" | ... as 0x33 | §3.3 |
| "1-Wire no presence after mid-read reset" | bus reset after 3 read slots is recognised | §3.1, §5 |
| "1-Wire after mid-read reset rx" | the next byte (0x0F) is received | §3.3 |
| "CRV presence after glitch t" | 100 us glitch from IDLE: no presence | §3.1 |
| "CRV busy after glitch t" | ... and `busy` = 0 | §3.1 |
| "CRV no presence t" | random transactions: presence | §3.2 |
| "CRV no rx_valid t" | random command byte pulses `rx_valid` | §3.3 |
| "CRV cmd t" | ... with the right value | §3.3 |
| "CRV read t" | random `tx_byte` read back | §3.4 |
| "1-Wire ROM command rx" | Match ROM 0x55 and Search ROM 0xF0 bytes are received as data | §3.3 |
| "A1 reset: line released, outputs quiescent" | in reset DQ released, `busy` and `rx_valid` 0 | §3.5 |
| "A2 busy == !ST_IDLE" | `busy` definition | §1 |
| "A3 irq == rx_valid" | `irq` = `rx_valid` | §1 |
| "A4 state legal" | `state` <= 7 | §1 |
| "A5 slave drive only in presence/read-0" | DQ low without the master only in PRESENCE or a read-0 slot | §3.2, §3.4 |
| "A6 rx_valid implies busy" | `rx_valid` only during a transaction | §3.3 |
| a_reset_released | in reset DQ released, `busy` and `rx_valid` 0 | §3.5 |
| a_drive_model | `drv_low` equals an independent slot-timing model | §3.2, §3.4 |
| a_rx_valid_model | `rx_valid` equals the model | §3.3 |
| a_rx_byte_model | at `rx_valid`, `rx_byte` equals the model | §3.3 |
| a_busy_model | `busy` equals the model's non-idle phases | §1, §3.1 |
| a_irq_is_rx_valid | `irq` = `rx_valid` | §1 |
