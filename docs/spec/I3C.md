<!-- SPDX-License-Identifier: Apache-2.0 -->
# I3C: design specification

Minimal I3C target in I2C-compatible (open-drain, SDR) form: START / repeated START / STOP, a
7-bit static address with R/W bit, a 9th-bit ACK after the address and after every written byte,
and reads of a single host-supplied byte repeated for as long as the controller ACKs. After a
write the core requests an in-band-interrupt-style service by pulling `int_n` low until the next
START. There is no CCC, dynamic address assignment, HDR mode, parity or real in-band IBI
arbitration. SCL and SDA are oversampled by `clk`. Core `I3C_top` (`rtl/I3C_top.sv`), testbench
`tb/I3C_tb.sv`, checker `tb/cov/I3C_sva.sv`.

Conventions on this page: every flop is clocked on the rising edge of `clk` and reset
asynchronously by `rst_n` low. A *rise* / *fall* is an SCL edge as detected by the core (§3.1);
a *bit* is the SDA value taken at a rise. The controller is the bus master (the TB).

## 1. Interface

| Port | Dir | Width | Meaning | Active | Clock | Reset |
|---|---|---|---|---|---|---|
| `clk` | input | 1 | core clock; every SCL level and every SDA setup / hold around SCL must last at least 2 `clk` periods | rising edge | - | - |
| `rst_n` | input | 1 | asynchronous reset of the target engine | low | async assert | - |
| `sda` | inout | 1 | SDA, open drain: the core only drives 0 (`ack_low` = 1), else high-Z; needs a pull-up | - | sampled by 2 flops; driven from a flop | released |
| `scl` | input | 1 | SCL from the controller | - | async (2 flops) | - |
| `tx_byte` | input | 8 | byte returned for reads; read at the SCL falls that present its bits (§3.5), so hold it stable during a read | - | `clk` | - |
| `rx_byte` | output | 8 | last byte written to this target | - | `clk` | 0x00 |
| `rx_valid` | output | 1 | one-`clk` pulse when a written byte is complete; `rx_byte` changes only in that cycle | high | `clk` | 0 |
| `int_n` | output | 1 | service request: low from the STOP that ends a write until the next START on the bus | low | `clk` | 1 |
| `busy` | output | 1 | a transfer to this target is in progress: `state` is not IDLE and not IGNORE | high | comb. from `state` | 0 |
| `irq` | output | 1 | equal to `rx_valid` | high | `clk` | 0 |

### Internal signals used by the verification

The TB and the checker read these by name; a re-implementation must have them.

| Signal | Width | Meaning |
|---|---|---|
| `state` | 3 | target state, encoded IDLE = 0, ADDR = 1, ACK = 2, RX = 3, TX = 4, TXACK = 5, IGNORE = 6 (7 is illegal) |
| `bit_cnt` | 3 | bit index within the current byte (0 = first) |
| `byte_w` | 8 | `{shift[6:0], sda_s}`: the byte including the bit being taken at this rise |
| `rw` | 1 | R/W bit of the last matching address (1 = read) |
| `ack_low` | 1 | 1 while the core pulls SDA low (ACK or a 0 data bit) |
| `txack_done` | 1 | in TXACK: the controller's ACK has been sampled and the next byte starts at the next fall |
| `scl_rise` | 1 | detected SCL rising edge (§3.1) |
| `scl_fall` | 1 | detected SCL falling edge |
| `start_det` | 1 | detected START or repeated START |
| `stop_det` | 1 | detected STOP |
| `sda_s` | 1 | first SDA synchronizer stage, the bit value at a rise |

## 2. Registers

<!-- AUTO:registers -->
Generated from [`docs/ip/I3C.md`](../ip/I3C.md) (source: `scripts/apb/specs/I3C.json`); do not edit by hand.

`I3C_apb` is an APB4 slave (AMBA APB protocol v2.0): zero wait states, 32-bit data, 12-bit byte address, PSTRB byte lanes on every writable register, PSLVERR on an unmapped or misaligned address (reads then return 0, writes are dropped). Writes to read-only registers are ignored without an error. The core runs on PCLK and PRESETN. `irq` is level-high: `|(IRQ_STATUS & IRQ_ENABLE)`.

Pass-through pins: `sda`, `scl`.

### Register map

| Offset | Name | Access | Reset | Description |
|---|---|---|---|---|
| 0x000 | ID | RO | 0x49330200 | IP identification: code, major and minor version |
| 0x004 | IRQ_STATUS | W1C | 0x00000000 | Sticky interrupt bits, write 1 to clear |
| 0x008 | IRQ_ENABLE | RW | 0x00000000 | Interrupt enables; irq = \|(IRQ_STATUS & IRQ_ENABLE) |
| 0x00C | FLAGS | RO | 0x00000000 | Stream holding-register state |
| 0x010 | SCRATCH | RW | 0x00000000 | Scratch register, no effect on the core |
| 0x014 | TX | RW | 0x00000000 | Byte returned to the controller on reads |
| 0x018 | RX | RO (pop) | 0x00000000 | Bytes written by the controller (acknowledged); reading RX frees it |
| 0x01C | STATUS | RO | core | Target state |

Unlisted bits read 0 and ignore writes. Reset "core": the register reads the core's outputs directly, so after reset it shows the core's own reset state. WO (pulse) registers read 0. Offsets from 0x020 up to 0xFFC are unmapped (PSLVERR).

### Fields

| Register | Bits | Field | Access | Reset | Description |
|---|---|---|---|---|---|
| ID | 31:16 | CODE | RO | 0x4933 | IP code |
| ID | 15:8 | MAJOR | RO | 0x02 | major version |
| ID | 7:0 | MINOR | RO | 0x00 | minor version |
| IRQ_STATUS | 2:0 | one bit per interrupt | W1C | 0x0 | see Interrupts |
| IRQ_ENABLE | 2:0 | one bit per interrupt | RW | 0x0 | 1 enables the IRQ_STATUS bit onto `irq` |
| FLAGS | 0 | one bit per stream flag | RO | 0x0 | see FLAGS |
| SCRATCH | 31:0 | SCRATCH | RW | 0x00000000 | free for software |
| TX | 7:0 | `tx_byte` | RW | 0x0 | sent MSB first for every byte of a read, until the controller NACKs; read bit by bit as the byte goes out (the MSB at the SCL fall ending the address or the previous ACK), so change it only between a byte's last bit and the ACK clock that follows |
| RX | 7:0 | `rx_byte` | RO (pop) | 0x0 | Bytes written by the controller (acknowledged); reading RX frees it |
| STATUS | 0 | `busy` | RO | core | addressed: between our address and the STOP or the NACK |
| STATUS | 1 | `int_n` | RO | core | IBI request, active low: set by the STOP that ends a write, released by the next START |

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

1. Release PRESETN. Read ID (0x000) and check it is 0x49330200.
2. Write 0x7 to IRQ_STATUS (0x004) to clear any stale bits.
3. Configure the core: write TX (0x014). Reset values are in the register map; PSTRB selects the bytes written.
4. Write IRQ_ENABLE (0x008) with the interrupts to use (bit order as in the Interrupts table; 0x7 enables all).
5. To receive on RX: wait for IRQ RX_AVAIL or FLAGS.RX_AVAIL (bit 0), then read RX (0x018). Reading the last word frees the register for the next beat; write 1 to IRQ_STATUS.RX_AVAIL (bit 1) to clear it. Read each beat before the next arrives, or it is dropped and RX_OVF is set.
6. Read STATUS (0x01C) for the core's live `busy`, `int_n`; it needs no clearing.
7. On `irq`: read IRQ_STATUS, handle every bit that is set and enabled, then write those bits back to IRQ_STATUS to clear them. A source that is still active sets its bit again.
<!-- /AUTO:registers -->

## 3. Timing

### 3.1 Sampling and bus conditions

At every `clk` edge: `scl_s <= scl`, `scl_d <= scl_s`, `sda_s <= sda`, `sda_d <= sda_s` (all
reset to 1). A rise is a `clk` edge where `scl_s && !scl_d`, a fall one where `!scl_s && scl_d`.
START (and repeated START) is `!sda_s && sda_d && scl_s` (SDA falls while SCL is high), STOP is
`sda_s && !sda_d && scl_s` (SDA rises while SCL is high). The bit taken at a rise is `sda_s`
from the same `clk` edge as `scl_s`, so the controller must hold SDA at least one `clk` past its
SCL rise. The TB uses a 10 ns `clk` and SCL with 600 ns high, 600 ns low.

START and STOP take priority over everything else and act in every state:

- START: `state` <= ADDR, `bit_cnt` <= 0, SDA released, `txack_done` <= 0, `int_n` <= 1.
- STOP: `state` <= IDLE, SDA released, `txack_done` <= 0; if the core was in RX (a write's data
  phase, after the address ACK) or `rx_valid` is 1 at that edge, `int_n` <= 0.

### 3.2 Address

In ADDR, 8 bits are shifted in at rises. At the 8th: if bits [7:1] equal `I3C_ADDR[6:0]`,
`rw` <= bit 0 and `state` <= ACK; otherwise `state` <= IGNORE, where SDA is never driven,
`busy` is 0 and only START or STOP is acted on.

### 3.3 ACK slot

On entering ACK (after the address or after a written byte), the next fall sets `ack_low` <= 1:
SDA is held low for the whole 9th bit, which the controller samples at the following rise. At
the next fall:

- write (`rw` = 0): SDA released, `state` <= RX;
- read (`rw` = 1): `ack_low` <= !`tx_byte[7]` (the read MSB goes on the line at the same fall
  that ends the ACK) and `state` <= TX.

### 3.4 Write data

In RX, 8 bits are shifted in at rises. At the 8th, `rx_byte` <= the byte, `rx_valid` (and `irq`)
is 1 for that `clk`, and `state` <= ACK, so every byte is ACKed (§3.3). The write ends with STOP,
which requests service on `int_n` (§3.1), or with a repeated START.

### 3.5 Read data

In TX, at the *k*-th fall (k = 1..7) `ack_low` <= !`tx_byte[7 - k]`: bits 6 down to 0 follow the
MSB placed in §3.3, one per fall, each sampled by the controller at the next rise. At the 8th
fall SDA is released and `state` <= TXACK. `tx_byte` is read live at each of these falls.

In TXACK the controller's 9th bit is taken at the next rise:

- SDA high (NACK): `state` <= IDLE (the controller then sends STOP or START).
- SDA low (ACK): `txack_done` <= 1, and at the next fall the MSB of `tx_byte` is driven again,
  `bit_cnt` <= 0, `state` <= TX: another byte (the current `tx_byte`) is sent.

### 3.6 Reset

`rst_n` low: IDLE, SDA released at once, `rx_valid` = 0, `busy` = 0, `int_n` = 1, `rx_byte` = 0,
synchronizers to 1. A transfer in progress is dropped; the next one starts with a START.

## 4. Parameters

| Parameter | Default | Legal range | Effect |
|---|---|---|---|
| `I3C_ADDR` | 7'h2A | 0 to 127 | static 7-bit target address; only bits [6:0] are compared |

## 5. Errors and corner cases

| Case | Behaviour |
|---|---|
| address does not match | IGNORE until the next START or STOP: no ACK, SDA never driven, `busy` = 0 |
| controller NACKs a read byte | IDLE at that rise, SDA released before the STOP |
| controller ACKs a read byte | the same `tx_byte` is sent again |
| repeated START during a write or read | new address phase at once; `int_n` is not lowered (only a STOP after a write lowers it) |
| STOP right after the address ACK of a write (no data) | still counts as a write: `int_n` goes low |
| any START, also to another target | clears `int_n` |
| reset in the middle of a byte | SDA released at once, `busy` = 0, `int_n` = 1 |
| `tx_byte` changes during a read | the bits already sent are unaffected; later bits come from the new value |

## 6. TB check map

Messages are printed by `tb/I3C_tb.sv` as `ERROR: <message>` (A1..A8 as `SVA_FAIL:`); "CRV"
messages and A1..A8 are built only for Verilator. Assertions a_* are in `tb/cov/I3C_sva.sv`.
The TB's "ACK" is SDA = 0 at the 9th rise.

| Check (TB message or assertion) | What it requires | Spec |
|---|---|---|
| "I3C int_n not idle-high" | `int_n` = 1 after reset | §3.6 |
| "I3C no ACK addr W" | address 0x2A + W is ACKed | §3.2, §3.3 |
| "I3C no ACK data" | written byte is ACKed | §3.4 |
| "I3C rx" | `rx_byte` = 0x5A after the write | §3.4 |
| "I3C IBI (int_n) not asserted after write" | `int_n` low after the write's STOP | §3.1 |
| "I3C IBI not cleared by START" | the next START raises `int_n` | §3.1 |
| "I3C no ACK addr R" | address 0x2A + R is ACKed | §3.2, §3.3 |
| "I3C read" | read returns `tx_byte` = 0x73 (MSB 0: the MSB is driven at the ACK-ending fall) | §3.3, §3.5 |
| "I3C no ACK addr R (2nd read)" | a second read after a NACKed read is ACKed | §3.5 |
| "I3C 2nd read" | ... and returns the new `tx_byte` | §3.5 |
| "I3C slave still active after NACK+STOP" | after NACK and STOP `busy` = 0 and SDA released | §3.5 |
| "I3C Sr no ACK on data" | write data ACKed before a repeated START | §3.4 |
| "I3C Sr no ACK addr R" | the address after a repeated START is ACKed | §3.1, §3.2 |
| "I3C Sr read" | read after a repeated START returns `tx_byte` | §3.5 |
| "I3C Sr rx_byte" | the byte written before the repeated START is kept | §3.4 |
| "I3C mid-txn reset: busy" | reset in a data byte: `busy` = 0, `int_n` = 1, SDA released | §3.6 |
| "CRV no ACK on addr W" | random writes: address ACKed | §3.2 |
| "CRV no ACK on data" | random writes: data ACKed | §3.4 |
| "CRV write no rx_valid" | random writes pulse `rx_valid` | §3.4 |
| "CRV rx_byte" | random writes: data byte | §3.4 |
| "CRV IBI not asserted after write" | `int_n` low after each write | §3.1 |
| "CRV IBI not cleared by START" | each START raises `int_n` | §3.1 |
| "CRV no ACK on addr R" | random reads: address ACKed | §3.2 |
| "CRV read" | random reads: first byte | §3.5 |
| "CRV read b1" | multi-byte reads: second byte (repeat of `tx_byte`) | §3.5 |
| "CRV read b2" | multi-byte reads: third byte | §3.5 |
| "CRV wrong addr" | another address is not ACKed | §3.2, §5 |
| "CRV busy stuck after wrong-addr stop" | `busy` = 0 after that STOP | §3.2 |
| "A1 reset: outputs quiescent" | in reset `busy`, `rx_valid`, SDA drive 0 and `int_n` = 1 | §3.6 |
| "A2 state encoding legal" | `state` <= 6 | §1 |
| "A3 busy mirrors state" | `busy` = state not IDLE and not IGNORE | §1 |
| "A4 SDA drive only in ack/tx states" | SDA driven only in ACK, TX, TXACK | §3.3, §3.5 |
| "A5 rx_valid single-cycle pulse" | `rx_valid` never two `clk` in a row | §3.4 |
| "A6 rx_byte stable" | `rx_byte` changes only with `rx_valid` | §3.4 |
| "A7 rx_valid implies busy" | `rx_valid` only during a transfer | §3.4 |
| "A8 IBI pending only in IDLE" | `int_n` low only while `state` is IDLE | §3.1 |
| a_reset_quiet | in reset: IDLE, outputs quiet, `int_n` = 1 | §3.6 |
| a_state_legal | `state` <= IGNORE | §1 |
| a_irq_is_rx_valid | `irq` = `rx_valid` | §1 |
| a_busy_def | `busy` definition | §1 |
| a_sda_drive_states | `ack_low` only in ACK, TX, TXACK | §3.3, §3.5 |
| a_rx_valid_pulse | `rx_valid` is one `clk` | §3.4 |
| a_rx_byte_only_on_valid | `rx_byte` changes only with `rx_valid` | §3.4 |
| a_rx_valid_in_txn | `rx_valid` only together with the move to ACK | §3.4 |
| a_start_to_addr | START: ADDR, `bit_cnt` 0, SDA released | §3.1 |
| a_stop_to_idle | STOP: IDLE, SDA released | §3.1 |
| a_addr_match | matching address: ACK, `rw` = bit 0 | §3.2 |
| a_addr_mismatch | other address: IGNORE | §3.2 |
| a_rx_byte_done | 8th write bit: `rx_valid`, `rx_byte`, ACK | §3.4 |
| a_ignore_holds | IGNORE until START / STOP | §3.2 |
| a_master_nack_ends | NACK in TXACK: IDLE | §3.5 |
| a_master_ack_continues | ACK in TXACK: TX with the MSB driven | §3.5 |
| a_tx_bit_presented | each TX fall drives the next `tx_byte` bit | §3.5 |
| a_ibi_cleared_by_start | START raises `int_n` | §3.1 |
| a_ibi_set_after_write | STOP in RX (or with `rx_valid`) lowers `int_n` | §3.1 |
| a_ibi_only_after_stop | `int_n` falls only after a STOP | §3.1 |
| a_ibi_release_only_on_start | `int_n` rises only after a START | §3.1 |
| a_txack_fresh | the ACK sampler is re-armed at the end of every read byte | §3.5 |
