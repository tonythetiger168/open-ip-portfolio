<!-- SPDX-License-Identifier: Apache-2.0 -->
# I2C: design specification

I2C target (slave) with a fixed 7-bit address: START / repeated START / STOP detection,
address match with ACK, byte writes from the controller (each ACKed and delivered as an
`rx_valid` pulse) and byte reads (the core returns `tx_byte` until the controller NACKs).
Open-drain SDA: the core only pulls it low. No clock stretching, no general call, no 10-bit
addressing. SCL and SDA are oversampled by `clk`. Core `I2C_top` (`rtl/I2C_top.sv`),
testbench `tb/I2C_tb.sv`, checker `tb/cov/I2C_sva.sv`.

Conventions on this page: every flop is clocked on the rising edge of `clk` and reset
asynchronously by `rst_n` low. "Edge" means a rising edge of `clk`.

## 1. Interface

| Port | Dir | Width | Meaning | Active | Clock | Reset |
|---|---|---|---|---|---|---|
| `clk` | input | 1 | core clock; samples SCL and SDA | rising edge | - | - |
| `rst_n` | input | 1 | asynchronous reset of every flop | low | async assert | - |
| `sda` | inout | 1 | I2C data, open drain: the core drives 0 when `ack_low` = 1, else high-Z (needs an external pull-up) | low = driven | sampled by clk (2-flop sync) | released (Z) |
| `scl` | input | 1 | I2C clock from the controller | - | async (2-flop sync) | - |
| `tx_byte` | input | 8 | byte returned on a read; read live, one bit at each SCL fall (§3.5), not latched | - | clk | - |
| `rx_byte` | output | 8 | last data byte written by the controller; changes only together with `rx_valid` | - | clk | 0x00 |
| `rx_valid` | output | 1 | one-clock pulse: a data byte was received into `rx_byte` (address bytes do not pulse) | high | clk | 0 |
| `busy` | output | 1 | `state` is neither IDLE nor IGNORE: a transaction (or an address phase) is in progress | high | clk | 0 |
| `irq` | output | 1 | equal to `rx_valid` | high | clk | 0 |

### Internal signals used by the verification

The TB and the bound checker read these core-internal signals by name; a re-implementation
must have them, with these names and meanings.

| Signal | Width | Meaning |
|---|---|---|
| `state` | 3 | FSM state, encoded IDLE = 0, ADDR = 1, ACK = 2, RX = 3, TX = 4, TXACK = 5, IGNORE = 6 (the TB checks this encoding) |
| `ack_low` | 1 | 1 = core pulls SDA low (`sda = ack_low ? 0 : 'z`) |
| `scl_rise`, `scl_fall`, `start_det`, `stop_det` | 1 each | bus events of §3.1 |
| `sda_s` | 1 | synchronised SDA (§3.1) |
| `bit_cnt` | 3 | bit counter within the current byte |
| `addr_byte` | 8 | `{shift[6:0], sda_s}`: the byte including the bit being sampled |
| `rw` | 1 | R/W bit of the matched address (1 = read) |
| `txack_done` | 1 | the controller's ACK/NACK bit after a read byte has been sampled (§3.5) |

## 2. Registers

The core has no registers of its own. The generated APB4 wrapper `I2C_apb` maps `tx_byte`
(TX), `rx_byte` / `rx_valid` (RX, a holding register) and `busy` (STATUS) onto the registers
below.

<!-- AUTO:registers -->
Generated from [`docs/ip/I2C.md`](../ip/I2C.md) (source: `scripts/apb/specs/I2C.json`); do not edit by hand.

`I2C_apb` is an APB4 slave (AMBA APB protocol v2.0): zero wait states, 32-bit data, 12-bit byte address, PSTRB byte lanes on every writable register, PSLVERR on an unmapped or misaligned address (reads then return 0, writes are dropped). Writes to read-only registers are ignored without an error. The core runs on PCLK and PRESETN. `irq` is level-high: `|(IRQ_STATUS & IRQ_ENABLE)`.

Pass-through pins: `sda`, `scl`.

### Register map

| Offset | Name | Access | Reset | Description |
|---|---|---|---|---|
| 0x000 | ID | RO | 0x49430200 | IP identification: code, major and minor version |
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
| ID | 31:16 | CODE | RO | 0x4943 | IP code |
| ID | 15:8 | MAJOR | RO | 0x02 | major version |
| ID | 7:0 | MINOR | RO | 0x00 | minor version |
| IRQ_STATUS | 2:0 | one bit per interrupt | W1C | 0x0 | see Interrupts |
| IRQ_ENABLE | 2:0 | one bit per interrupt | RW | 0x0 | 1 enables the IRQ_STATUS bit onto `irq` |
| FLAGS | 0 | one bit per stream flag | RO | 0x0 | see FLAGS |
| SCRATCH | 31:0 | SCRATCH | RW | 0x00000000 | free for software |
| TX | 7:0 | `tx_byte` | RW | 0x0 | sent MSB first for every byte of a read, until the controller NACKs; read bit by bit as the byte goes out (the MSB at the SCL fall ending the address or the previous ACK), so change it only between a byte's last bit and the ACK clock that follows |
| RX | 7:0 | `rx_byte` | RO (pop) | 0x0 | Bytes written by the controller (acknowledged); reading RX frees it |
| STATUS | 0 | `busy` | RO | core | addressed: between our address and the STOP or the NACK |

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

1. Release PRESETN. Read ID (0x000) and check it is 0x49430200.
2. Write 0x7 to IRQ_STATUS (0x004) to clear any stale bits.
3. Configure the core: write TX (0x014). Reset values are in the register map; PSTRB selects the bytes written.
4. Write IRQ_ENABLE (0x008) with the interrupts to use (bit order as in the Interrupts table; 0x7 enables all).
5. To receive on RX: wait for IRQ RX_AVAIL or FLAGS.RX_AVAIL (bit 0), then read RX (0x018). Reading the last word frees the register for the next beat; write 1 to IRQ_STATUS.RX_AVAIL (bit 1) to clear it. Read each beat before the next arrives, or it is dropped and RX_OVF is set.
6. Read STATUS (0x01C) for the core's live `busy`; it needs no clearing.
7. On `irq`: read IRQ_STATUS, handle every bit that is set and enabled, then write those bits back to IRQ_STATUS to clear them. A source that is still active sets its bit again.
<!-- /AUTO:registers -->

## 3. Timing

### 3.1 Sampling and bus events

At every edge: `scl_s <= scl`, `scl_d <= scl_s`, `sda_s <= sda`, `sda_d <= sda_s` (all reset to
1). From these, combinationally:

| Event | Condition |
|---|---|
| SCL rise | `scl_s && !scl_d` |
| SCL fall | `!scl_s && scl_d` |
| START (also repeated START) | `!sda_s && sda_d && scl_s` (SDA fell while SCL high) |
| STOP | `sda_s && !sda_d && scl_s` (SDA rose while SCL high) |

The state machine acts on an event at the edge after the event became visible, i.e. at the
second edge after the pin changed; a change of `sda` driven by the core appears right after
that edge. Requirements on the controller (all met by the TB, which uses 10 ns `clk` and SCL
phases of 300 ns or more): each SCL high and low phase at least 3 clocks; SDA set up at least
1 clock before SCL rises; SDA changed only after SCL low has been sampled (hold ≥ 1 clock),
otherwise the change is taken as a START or STOP.

START and STOP win over everything else in any state, including IGNORE and the middle of a
byte:

- START: `state <= ADDR`, `bit_cnt <= 0`, `ack_low <= 0` (SDA released), `txack_done <= 0`.
- STOP: `state <= IDLE`, `ack_low <= 0`, `txack_done <= 0`.

### 3.2 Address phase (state ADDR)

At each SCL rise, the bit `sda_s` is shifted in MSB first; `addr_byte = {shift[6:0], sda_s}`.
At the 8th rise:

- `addr_byte[7:1] == I2C_ADDR`: `rw <= addr_byte[0]` (1 = read), `state <= ACK`;
- otherwise `state <= IGNORE`: SDA stays released (the controller sees NACK) and the core waits
  for the next START or STOP; `busy` goes low.

### 3.3 ACK bit (state ACK)

Used after a matching address and after every received data byte.

1. At the next SCL fall (end of the 8th bit): `ack_low <= 1`, SDA pulled low for the 9th bit.
2. At the following SCL fall (end of the 9th bit):
   - write (`rw` = 0): `ack_low <= 0`, `state <= RX`;
   - read (`rw` = 1): `ack_low <= !tx_byte[7]` (first data bit, MSB, presented at once), `state <= TX`, `bit_cnt` = 0.

### 3.4 Write data (state RX)

At each SCL rise a bit is shifted in, MSB first. At the 8th rise: `rx_byte <= addr_byte`,
`rx_valid <= 1` for one clock (so `irq` pulses), `state <= ACK` (every data byte is ACKed).
Any number of bytes may follow; a STOP or START ends the write. A STOP in the middle of a
byte drops the partial byte (no `rx_valid`).

### 3.5 Read data (states TX, TXACK)

The bit on SDA is `!ack_low` (1 = released, pulled up by the bus). Bit 7 of `tx_byte` was
presented at the SCL fall that ended the ACK (or master ACK, below). In TX, at each SCL fall
with `bit_cnt` = k:

- k < 7: `ack_low <= !tx_byte[6 - k]` (next bit), `bit_cnt <= k + 1`;
- k = 7 (end of bit 0): `ack_low <= 0` (release for the controller's ACK), `bit_cnt <= 0`,
  `state <= TXACK`.

In TXACK, at the next SCL rise the core samples `sda_s` and sets `txack_done <= 1`:

- `sda_s` = 1 (NACK): `state <= IDLE` (read finished; `busy` falls);
- `sda_s` = 0 (ACK): at the following SCL fall, `txack_done <= 0`, `ack_low <= !tx_byte[7]`,
  `state <= TX`: the next byte (again `tx_byte`, as it is at that time) is sent.

`tx_byte` is read at each SCL fall; if it changes in the middle of a byte the remaining bits come
from the new value.

### 3.6 Reset

`rst_n` low: `state` = IDLE, `ack_low` = 0 (SDA released), `rx_byte` = 0, `rx_valid` = 0,
`busy` = 0, `irq` = 0, synchroniser flops = 1. A transaction in progress is abandoned; after
release the core waits for a START.

## 4. Parameters

| Parameter | Default | Legal range | Effect |
|---|---|---|---|
| `I2C_ADDR` | 7'h50 | 0x00 .. 0x7F (bits [6:0] are used) | 7-bit target address compared with the first 7 bits after START |

## 5. Errors and corner cases

| Case | Behaviour |
|---|---|
| address does not match | no ACK (SDA released), IGNORE until START/STOP, `busy` low, no `rx_valid` |
| repeated START (no STOP) | new address phase at once, from any state (§3.1) |
| STOP in the middle of a write byte | partial byte dropped, IDLE |
| controller NACKs a read byte | read ends, IDLE |
| controller ACKs a read byte | `tx_byte` sent again (§3.5) |
| reset in the middle of a transaction | §3.6; the bus needs a STOP or START to resynchronise |
| SDA changing while SCL high outside a START/STOP | taken as START or STOP (I2C rule) |

## 6. TB check map

Messages are printed by `tb/I2C_tb.sv` as `ERROR: <message>`; messages starting "CRV" and the
immediate checks A1..A7 are built only for Verilator. Assertions a_* are in `tb/cov/I2C_sva.sv`.
The TB is the controller, with a pulled-up SDA (`tri1`) and `I2C_ADDR` = 0x50.

| Check (TB message or assertion) | What it requires | Spec |
|---|---|---|
| "I2C no ACK on addr W" | address 0x50 + W is ACKed | §3.2, §3.3 |
| "I2C no ACK on data" | a written data byte is ACKed | §3.4 |
| "I2C rx_valid never pulsed" | a written byte pulses `rx_valid` | §3.4 |
| "I2C rx_byte" | `rx_byte` holds the written byte (0x5A) | §3.4 |
| "I2C no ACK on addr R" | address 0x50 + R is ACKed | §3.3 |
| "I2C read" | a read returns `tx_byte` (C3, and 73, 00, 7F with MSB 0) | §3.3, §3.5 |
| "I2C read2 no ACK on addr R" | read address ACKed | §3.3 |
| "I2C read2 byte1" | first byte of a read = `tx_byte` | §3.5 |
| "I2C read2 byte2" | after a controller ACK, the next byte = `tx_byte` again | §3.5 |
| "I2C read3 no ACK on addr R" | read address ACKed | §3.3 |
| "I2C read3 byte1" | 3-byte read, byte 1 | §3.5 |
| "I2C read3 byte2" | 3-byte read, byte 2 | §3.5 |
| "I2C read3 byte3" | 3-byte read, byte 3 | §3.5 |
| "I2C Sr no ACK on addr W" | write address ACKed before a repeated START | §3.2 |
| "I2C Sr no ACK on data" | data ACKed before a repeated START | §3.4 |
| "I2C Sr no ACK on addr R" | read address ACKed after a repeated START (no STOP) | §3.1 |
| "I2C Sr read" | the read after a repeated START returns `tx_byte` (0x96) | §3.5 |
| "I2C Sr rx_byte" | the byte written before the repeated START (0x3C) is kept | §3.4 |
| "I2C mid-txn reset: busy" | 4 clocks into a reset mid-byte, `busy` = 0 and SDA released | §3.6 |
| "I2C post-reset no ACK" | after reset and a STOP, a new write is ACKed | §3.6 |
| "I2C post-reset rx_byte" | and its data byte (0x81) is received | §3.6 |
| "I2C wrong addr ACKed" | address 0x51 is not ACKed | §3.2, §5 |
| "CRV no ACK on addr W" | random writes: address ACKed | §3.2 |
| "CRV no ACK on data" | random writes: data ACKed | §3.4 |
| "CRV rx_byte" | random writes: `rx_byte` = the byte written | §3.4 |
| "CRV no ACK on addr R" | random reads: address ACKed | §3.3 |
| "CRV read" | random reads: data = `tx_byte` | §3.5 |
| "CRV wrong addr" | random other addresses are not ACKed | §3.2 |
| "CRV busy stuck after wrong-addr stop" | after a wrong address and a STOP, `busy` = 0 | §3.1, §3.2 |
| "A1 reset: outputs quiescent" | in reset `busy` = 0, `rx_valid` = 0, SDA released | §3.6 |
| "A2 state encoding legal" | state is one of the 7 states | §3 |
| "A3 busy low in IDLE" | IDLE → `busy` = 0 | §1 |
| "A4 SDA drive only in ack/tx states" | SDA pulled low only in ACK, TX, TXACK | §3.3, §3.5 |
| "A5 rx_valid single-cycle pulse" | `rx_valid` never two clocks in a row | §3.4 |
| "A6 rx_byte stable" | `rx_byte` changes only with `rx_valid` | §1, §3.4 |
| "A7 rx_valid implies busy" | `rx_valid` only during a transaction | §3.4 |
| a_reset_quiet | in reset: not busy, no `rx_valid`, SDA released, IDLE | §3.6 |
| a_state_legal | legal state encoding | §3 |
| a_irq_is_rx_valid | `irq` = `rx_valid` | §1 |
| a_busy_def | `busy` = state not IDLE / IGNORE | §1 |
| a_sda_drive_states | `ack_low` only in ACK, TX, TXACK | §3.3, §3.5 |
| a_rx_valid_pulse | `rx_valid` is followed by a clock without it | §3.4 |
| a_rx_byte_only_on_valid | `rx_byte` changes only when `rx_valid` | §3.4 |
| a_rx_valid_in_txn | `rx_valid` only when the state has moved to ACK | §3.4 |
| a_start_to_addr | after START: ADDR, `bit_cnt` 0, SDA released | §3.1 |
| a_stop_to_idle | after STOP: IDLE, SDA released | §3.1 |
| a_addr_match | matching address at the 8th rise: ACK state, `rw` = R/W bit | §3.2 |
| a_addr_mismatch | other address: IGNORE, SDA released | §3.2 |
| a_rx_byte_done | 8th data rise: `rx_valid`, `rx_byte` = assembled byte, ACK state | §3.4 |
| a_ignore_holds | IGNORE stays until START/STOP, SDA released | §3.2, §5 |
| a_master_nack_ends | NACK sampled in TXACK: IDLE | §3.5 |
| a_master_ack_continues | ACK then SCL fall: TX, `bit_cnt` 0, SDA = `tx_byte[7]` | §3.5 |
| a_tx_bit_presented | each SCL fall in TX presents the next bit of `tx_byte` | §3.5 |
