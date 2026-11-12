<!-- SPDX-License-Identifier: Apache-2.0 -->
# SPMI: design specification

Simplified MIPI SPMI slave on the two-wire SCLK / SDATA bus. A frame is a Sequence Start
Condition (SSC) followed by an 8-bit header (slave address SA[3:0], command CMD[3:0]), an 8-bit
register address and, for a write, an 8-bit data byte, all MSB first. Only two commands exist:
CMD 0x0 register write (the core reports the byte and drives a 1-bit ACK) and CMD 0x1 register
read (the core shifts out `tx_byte`). There is no parity, no bus park and no arbitration. SCLK and
SDATA are oversampled by `clk`. Core `SPMI_top` (`rtl/SPMI_top.sv`), testbench `tb/SPMI_tb.sv`,
checker `tb/cov/SPMI_sva.sv`.

Conventions on this page: every flop is clocked on the rising edge of `clk` and reset
asynchronously by `rst_n` low. A *rise* / *fall* is an SCLK edge as detected by the core (§3.1);
a *bit* is the SDATA value taken at a rise.

## 1. Interface

| Port | Dir | Width | Meaning | Active | Clock | Reset |
|---|---|---|---|---|---|---|
| `clk` | input | 1 | core clock; every SCLK level must last at least 2 `clk` periods | rising edge | - | - |
| `rst_n` | input | 1 | asynchronous reset of the frame engine | low | async assert | - |
| `sdata` | inout | 1 | SDATA, open drain: the core only drives 0 (`sd_oe` = 1), else high-Z; needs a pull-up | - | sampled by 2 flops; driven from a flop | released |
| `sclk` | input | 1 | SCLK from the master | - | async (2 flops) | - |
| `rx_byte` | output | 8 | data byte of the last write frame addressed to this slave | - | `clk` | 0x00 |
| `rx_addr` | output | 8 | register address of the last frame to this slave that got past its address field (write, read or unknown command) | - | `clk` | 0x00 |
| `rx_valid` | output | 1 | one-`clk` pulse when a write's data byte is complete; `rx_byte` changes only in that cycle | high | `clk` | 0 |
| `tx_byte` | input | 8 | read data; latched at the end of a read's address field (§3.4) | - | `clk` | - |
| `busy` | output | 1 | a frame to this slave is in progress: `state` is not IDLE and not IGNORE | high | `clk` | 0 |
| `irq` | output | 1 | equal to `rx_valid` | high | `clk` | 0 |

### Internal signals used by the verification

The TB reads these by name; a re-implementation must have them.

| Signal | Width | Meaning |
|---|---|---|
| `state` | 3 | frame state, encoded IDLE = 0, HEAD = 1, ADDR = 2, DATA = 3, ACKP = 4, IGNORE = 5 (values 6 and 7 are illegal) |
| `sd_oe` | 1 | 1 while the core pulls SDATA low (ACK or a 0 data bit) |

## 2. Registers

<!-- AUTO:registers -->
Generated from [`docs/ip/SPMI.md`](../ip/SPMI.md) (source: `scripts/apb/specs/SPMI.json`); do not edit by hand.

`SPMI_apb` is an APB4 slave (AMBA APB protocol v2.0): zero wait states, 32-bit data, 12-bit byte address, PSTRB byte lanes on every writable register, PSLVERR on an unmapped or misaligned address (reads then return 0, writes are dropped). Writes to read-only registers are ignored without an error. The core runs on PCLK and PRESETN. `irq` is level-high: `|(IRQ_STATUS & IRQ_ENABLE)`.

Pass-through pins: `sdata`, `sclk`.

### Register map

| Offset | Name | Access | Reset | Description |
|---|---|---|---|---|
| 0x000 | ID | RO | 0x534D0200 | IP identification: code, major and minor version |
| 0x004 | IRQ_STATUS | W1C | 0x00000000 | Sticky interrupt bits, write 1 to clear |
| 0x008 | IRQ_ENABLE | RW | 0x00000000 | Interrupt enables; irq = \|(IRQ_STATUS & IRQ_ENABLE) |
| 0x00C | FLAGS | RO | 0x00000000 | Stream holding-register state |
| 0x010 | SCRATCH | RW | 0x00000000 | Scratch register, no effect on the core |
| 0x014 | TX | RW | 0x00000000 | Byte returned for a register read |
| 0x018 | RX | RO (pop) | 0x00000000 | Register writes received (data and register address); reading RX frees it |
| 0x01C | STATUS | RO | core | Target state |

Unlisted bits read 0 and ignore writes. Reset "core": the register reads the core's outputs directly, so after reset it shows the core's own reset state. WO (pulse) registers read 0. Offsets from 0x020 up to 0xFFC are unmapped (PSLVERR).

### Fields

| Register | Bits | Field | Access | Reset | Description |
|---|---|---|---|---|---|
| ID | 31:16 | CODE | RO | 0x534D | IP code |
| ID | 15:8 | MAJOR | RO | 0x02 | major version |
| ID | 7:0 | MINOR | RO | 0x00 | minor version |
| IRQ_STATUS | 2:0 | one bit per interrupt | W1C | 0x0 | see Interrupts |
| IRQ_ENABLE | 2:0 | one bit per interrupt | RW | 0x0 | 1 enables the IRQ_STATUS bit onto `irq` |
| FLAGS | 0 | one bit per stream flag | RO | 0x0 | see FLAGS |
| SCRATCH | 31:0 | SCRATCH | RW | 0x00000000 | free for software |
| TX | 7:0 | `tx_byte` | RW | 0x0 | taken when the register address of a read is complete, sent MSB first |
| RX | 7:0 | `rx_byte` | RO (pop) | 0x0 | data written |
| RX | 15:8 | `rx_addr` | RO (pop) | 0x0 | register address |
| STATUS | 0 | `busy` | RO | core | in a command addressed to us |

### Interrupts (IRQ_STATUS, IRQ_ENABLE)

A bit is set while its source is active, stays set until written with 1, and a set in the same clock as the clear wins.

| Bit | Name | Set when |
|---|---|---|
| 0 | WRITE | a register write was received (the same clock RX captures it) |
| 1 | RX_AVAIL | RX captured a beat |
| 2 | RX_OVF | beat dropped, RX was full |

### FLAGS

| Bit | Name | Meaning |
|---|---|---|
| 0 | RX_AVAIL | RX holds an unread beat |

### Streams

* **RX** captures `rx_byte`, `rx_addr` when `rx_valid` is high and the register is empty (or is being read in the same clock), and sets FLAGS/IRQ RX_AVAIL. Reading RX pops it. A beat that arrives while the register is full is dropped and sets RX_OVF.

### Programming sequence

1. Release PRESETN. Read ID (0x000) and check it is 0x534D0200.
2. Write 0x7 to IRQ_STATUS (0x004) to clear any stale bits.
3. Configure the core: write TX (0x014). Reset values are in the register map; PSTRB selects the bytes written.
4. Write IRQ_ENABLE (0x008) with the interrupts to use (bit order as in the Interrupts table; 0x7 enables all).
5. To receive on RX: wait for IRQ RX_AVAIL or FLAGS.RX_AVAIL (bit 0), then read RX (0x018). Reading the last word frees the register for the next beat; write 1 to IRQ_STATUS.RX_AVAIL (bit 1) to clear it. Read each beat before the next arrives, or it is dropped and RX_OVF is set.
6. Read STATUS (0x01C) for the core's live `busy`; it needs no clearing.
7. On `irq`: read IRQ_STATUS, handle every bit that is set and enabled, then write those bits back to IRQ_STATUS to clear them. A source that is still active sets its bit again.
<!-- /AUTO:registers -->

## 3. Timing

### 3.1 Sampling

At every `clk` edge: `sclk_s <= sclk`, `sclk_d <= sclk_s`, `sdata_s <= sdata`,
`sdata_d <= sdata_s` (reset values 0, 0, 1, 1). A rise is a `clk` edge where
`sclk_s && !sclk_d`, a fall one where `!sclk_s && sclk_d`. The bit taken at a rise is `sdata_s`,
sampled at the same `clk` edge as `sclk_s`, so the master must hold SDATA at least one `clk`
past its SCLK rise and should change SDATA only while SCLK is low. The TB uses a 10 ns `clk`
and a 1.2 us bit (SCLK 600 ns high).

### 3.2 Sequence start and header

An SSC is detected at a `clk` edge where `!sdata_s && sdata_d && sclk_s`: SDATA falls while
SCLK is high. In any state an SSC moves the engine to HEAD with a bit count of 0 and releases
SDATA (`sd_oe` <= 0), so a new SSC in the middle of a frame abandons it and starts a new one.

In HEAD, 8 bits are shifted in at rises. At the 8th: if bits [7:4] (SA) equal `SPMI_ADDR`,
CMD = bits [3:0] is kept and the engine goes to ADDR; otherwise it goes to IGNORE, where `busy`
is 0 and everything but the next SSC is ignored.

### 3.3 Address field and write

In ADDR, 8 bits are shifted in. At the 8th rise: `rx_addr` <= the address, `tx_byte` is latched
for a read, and the engine goes to DATA for CMD 0, ACKP for CMD 1, and IGNORE for any other
command (`rx_addr` has already been updated in that case).

In DATA (write), 8 bits are shifted in. At the 8th rise `rx_byte` <= the byte and `rx_valid` (and
`irq`) is 1 for that one `clk`; the engine goes to ACKP. At the next fall `sd_oe` <= 1 (ACK = 0)
and the engine goes to IDLE; at the fall after that `sd_oe` <= 0. So the ACK is held for one full
bit, fall to fall, and the master reads it as 0 at the rise in between. `busy` is 1 from the SSC
until the fall that starts the ACK.

### 3.4 Read

In ACKP for CMD 1, the byte latched at the end of the address field is shifted out MSB first,
one bit per fall: at the *k*-th fall (k = 1..8) after the address field, `sd_oe` <= !bit(8 - k),
so a 0 pulls SDATA low and a 1 leaves it released. The master samples each bit at the rise after
the fall that put it on the line. At the 8th fall the engine goes to IDLE, and the fall after
that releases SDATA. Changing `tx_byte` during the read has no effect. There is no ACK bit for a
read.

### 3.5 Reset

`rst_n` low: engine IDLE, `sd_oe` = 0 (SDATA released at once), `rx_valid` = 0, `busy` = 0,
`rx_byte` = `rx_addr` = 0. A frame in progress is dropped; the next frame starts with an SSC.

## 4. Parameters

| Parameter | Default | Legal range | Effect |
|---|---|---|---|
| `SPMI_ADDR` | 4'h5 | 4'h0 to 4'hF | slave address compared with SA[3:0]; frames to other addresses are ignored |

## 5. Errors and corner cases

| Case | Behaviour |
|---|---|
| frame to another SA | IGNORE after the header: no output changes, SDATA never driven, `busy` back to 0 |
| CMD other than 0x0 / 0x1 | IGNORE after the address field; `rx_addr` is updated, nothing else |
| SSC in the middle of a frame (header, address or data) | frame abandoned without a `rx_valid`, new frame starts |
| `tx_byte` changes during a read | ignored: the value latched at the end of the address field is sent |
| reset while driving read data | SDATA released at once, `busy` = 0; the following frames work |
| master changes SDATA while SCLK is high | seen as an SSC if it falls, ignored if it rises |

## 6. TB check map

Messages are printed by `tb/SPMI_tb.sv` as `ERROR: <message>` (A1..A7 as `SVA_FAIL:`); "CRV"
messages and A1..A7 are built only for Verilator. Assertions a_* are in `tb/cov/SPMI_sva.sv`.

| Check (TB message or assertion) | What it requires | Spec |
|---|---|---|
| "SPMI rx_valid never pulsed" | a write frame pulses `rx_valid` | §3.3 |
| "SPMI rx" | write 0x5A to address 0x03: `rx_byte` = 0x5A | §3.3 |
| "SPMI rx_addr" | ... and `rx_addr` = 0x03 | §3.3 |
| "SPMI read" | a read returns `tx_byte` (0xC2) MSB first | §3.4 |
| "SPMI bus wedge: post-read write ignored" | after a read ending in a 0 bit SDATA is released and the next write is received | §3.4 |
| "SPMI post-read rx" | that write's byte is correct | §3.3, §3.4 |
| "CRV write no ACK" | random writes: the ACK bit reads 0 | §3.3 |
| "CRV write no rx_valid" | random writes pulse `rx_valid` | §3.3 |
| "CRV rx_byte" | random writes: data byte | §3.3 |
| "CRV rx_addr" | random writes: register address | §3.3 |
| "CRV read" | random reads return `tx_byte` | §3.4 |
| "CRV wrong addr" | frames to another SA do not change the outputs | §3.2, §5 |
| "CRV busy stuck after wrong-addr frame" | `busy` is 0 after such a frame | §3.2 |
| "CRV illegal cmd" | commands 2..15 do not produce `rx_valid` | §3.3, §5 |
| "CRV busy stuck after illegal-cmd frame" | `busy` is 0 after such a frame | §3.3 |
| "SPMI write not ACKed" | directed write: ACK bit 0 | §3.3 |
| "SPMI read changed mid-byte" | `tx_byte` changed mid-read does not change the data sent | §3.4 |
| "SPMI restart by SSC failed rx" | an SSC after 6 header bits restarts; the new write is received | §3.2 |
| "SPMI not released in reset" | reset during read data: SDATA released, `busy` = 0 | §3.5 |
| "SPMI after reset rx" | writes to addresses 0x00, 0xFF, 0x05 after reset are received and ACKed | §3.3, §3.5 |
| "SPMI alt write rx" | write of 0x55 to 0x21 | §3.3 |
| "SPMI write after restart rx" | SSCs in the address and data fields restart; the next write is received | §3.2 |
| "A1 reset: outputs quiescent" | in reset `busy`, `rx_valid`, `sd_oe` = 0 | §3.5 |
| "A2 state encoding legal" | `state` <= 5 | §1 |
| "A3 busy mirrors state" | `busy` = state not IDLE and not IGNORE | §1 |
| "A4 rx_valid single-cycle pulse" | `rx_valid` never high two `clk` in a row | §3.3 |
| "A5 drive only in ACKP/IDLE-drain" | `sd_oe` only in ACKP or IDLE (the bit after the frame) | §3.3, §3.4 |
| "A6 rx_byte stable" | `rx_byte` changes only with `rx_valid` | §3.3 |
| "A7 rx_valid implies busy" | `rx_valid` only during a frame | §3.3 |
| a_reset_released | in reset SDATA released, `busy` and `rx_valid` 0 | §3.5 |
| a_drive_model | `sd_oe` equals an independent frame model (ACK and read bits) | §3.3, §3.4 |
| a_rx_valid_model | `rx_valid` equals the model | §3.3 |
| a_rx_data_model | at `rx_valid`, `rx_byte` and `rx_addr` equal the model | §3.3 |
| a_busy_model | `busy` equals the model's in-frame phases | §3.2 to §3.4 |
| a_irq_is_rx_valid | `irq` = `rx_valid` | §1 |
