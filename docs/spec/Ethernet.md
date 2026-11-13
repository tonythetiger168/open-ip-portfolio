<!-- SPDX-License-Identifier: Apache-2.0 -->
# Ethernet: design specification

An IEEE 802.3 full-duplex MAC with a GMII-style byte interface, address filtering and PAUSE
flow control (receive side). Not implemented: half duplex (CSMA/CD), sending PAUSE frames,
priority flow control, multicast hash filtering, statistics counters, jumbo frames. Core
`Ethernet_top` (`rtl/Ethernet_top.sv`), testbench `tb/Ethernet_tb.sv` (two MACs cross-connected,
line monitors and reference receivers), checker `tb/cov/Ethernet_sva.sv`.

Conventions on this page: every flop is clocked on the rising edge of `clk` and reset
asynchronously by `rst_n` low. Inputs are sampled at the rising edge. A byte time is `cfg_div` + 1
clocks; a "byte edge" is the edge at the end of a byte time (`ls` = 1). All line and host
decisions happen at byte edges.

## 1. Interface

| Port | Dir | Width | Meaning | Active | Clock | Reset |
|---|---|---|---|---|---|---|
| `clk` | input | 1 | clock | rising edge | - | - |
| `rst_n` | input | 1 | asynchronous reset | low | async | - |
| `cfg_div` | input | 5 | byte time - 1, in clocks (both ends must use the same) | - | static | - |
| `cfg_mac` | input | 48 | station address (first DA byte in bits 47:40) | - | static | - |
| `cfg_promisc` | input | 1 | accept every DA | high | static | - |
| `cfg_pause_en` | input | 1 | obey received PAUSE frames | high | `clk` | - |
| `tx_valid` | input | 1 | a frame byte (or the start of a frame) is offered | high | `clk` | - |
| `tx_ready` | output | 1 | one clock per byte time while sending frame bytes: the byte is taken; combinational | high | comb | 0 |
| `tx_data` | input | 8 | frame byte, DA first | - | `clk` | - |
| `tx_last` | input | 1 | last frame byte (before padding and FCS) | high | `clk` | - |
| `tx_done` | output | 1 | one-clock pulse with the last FCS byte | high | `clk` | 0 |
| `tx_underrun` | output | 1 | one-clock pulse: no byte in time, the frame was ended with `gtx_er` | high | `clk` | 0 |
| `tx_paused` | output | 1 | a received PAUSE is holding the transmitter; combinational | high | comb | 0 |
| `gtxd` | output | 8 | GMII transmit data | - | `clk` | 0 |
| `gtx_en` | output | 1 | GMII transmit enable | high | `clk` | 0 |
| `gtx_er` | output | 1 | GMII transmit error | high | `clk` | 0 |
| `grxd` | input | 8 | GMII receive data (sampled once per byte time) | - | `clk` | - |
| `grx_dv` | input | 1 | GMII receive data valid | high | `clk` | - |
| `grx_er` | input | 1 | GMII receive error | high | `clk` | - |
| `rx_valid` | output | 1 | one-clock pulse: a received byte on `rx_data` | high | `clk` | 0 |
| `rx_data` | output | 8 | received frame byte (no FCS); holds | - | `clk` | 0 |
| `rx_last` | output | 1 | with `rx_valid`: last byte of the frame | high | `clk` | 0 |
| `rx_stat` | output | 4 | {pause, phy_err, len_err, crc_err}, valid with `rx_last`; holds | - | `clk` | 0 |
| `rx_frag` | output | 1 | one-clock pulse: a fragment or bad preamble | high | `clk` | 0 |

### Internal signals used by the verification

The TB reads these by name in each MAC instance (`g_mac[i].u`); the FSM coverage collector binds
`ts` and `rs`.

| Signal | Width | Meaning |
|---|---|---|
| `dc` | 5 | byte time counter, 0..`cfg_div` |
| `ls` | 1 | `dc` = `cfg_div`: this clock ends a byte time |
| `ts` | 3 | transmitter: 0 IDLE, 1 PREAMBLE, 2 DATA, 3 PAD, 4 FCS, 5 GAP |
| `rs` | 3 | receiver: 0 IDLE, 1 PREAMBLE, 2 DATA, 3 DROP, 4 / 5 flushing the last two bytes |
| `pause` | 22 | byte times of PAUSE left |

## 2. Registers

<!-- AUTO:registers -->
Generated from [`docs/ip/Ethernet.md`](../ip/Ethernet.md) (source: `scripts/apb/specs/Ethernet.json`); do not edit by hand.

`Ethernet_apb` is an APB4 slave (AMBA APB protocol v2.0): zero wait states, 32-bit data, 12-bit byte address, PSTRB byte lanes on every writable register, PSLVERR on an unmapped or misaligned address (reads then return 0, writes are dropped). Writes to read-only registers are ignored without an error. The core runs on PCLK and PRESETN. `irq` is level-high: `|(IRQ_STATUS & IRQ_ENABLE)`.

Pass-through pins: `gtxd`, `gtx_en`, `gtx_er`, `grxd`, `grx_dv`, `grx_er`.

### Register map

| Offset | Name | Access | Reset | Description |
|---|---|---|---|---|
| 0x000 | ID | RO | 0x45540200 | IP identification: code, major and minor version |
| 0x004 | IRQ_STATUS | W1C | 0x00000000 | Sticky interrupt bits, write 1 to clear |
| 0x008 | IRQ_ENABLE | RW | 0x00000000 | Interrupt enables; irq = \|(IRQ_STATUS & IRQ_ENABLE) |
| 0x00C | FLAGS | RO | 0x00000000 | Stream holding-register state |
| 0x010 | SCRATCH | RW | 0x00000000 | Scratch register, no effect on the core |
| 0x014 | CFG | RW | 0x0000005F | Byte time and receive options |
| 0x018 | MAC0 | RW | 0x00000000 | Station address (MAC0 = bits 31:0, MAC1 = bits 47:32; the first byte on the wire is bits 47:40) |
| 0x01C | MAC1 | RW | 0x00000000 | Station address (MAC0 = bits 31:0, MAC1 = bits 47:32; the first byte on the wire is bits 47:40) |
| 0x020 | TX | RW | 0x00000000 | Transmit byte (DA first; the MAC adds preamble, padding and FCS); a frame starts once its first byte is in TX, and each next byte must arrive within a byte time |
| 0x024 | RX | RO (pop) | 0x00000000 | Received byte (FCS removed); read it within a byte time |
| 0x028 | STATUS | RO | core | Flow control |

Unlisted bits read 0 and ignore writes. Reset "core": the register reads the core's outputs directly, so after reset it shows the core's own reset state. WO (pulse) registers read 0. Offsets from 0x02C up to 0xFFC are unmapped (PSLVERR).

### Fields

| Register | Bits | Field | Access | Reset | Description |
|---|---|---|---|---|---|
| ID | 31:16 | CODE | RO | 0x4554 | IP code |
| ID | 15:8 | MAJOR | RO | 0x02 | major version |
| ID | 7:0 | MINOR | RO | 0x00 | minor version |
| IRQ_STATUS | 6:0 | one bit per interrupt | W1C | 0x0 | see Interrupts |
| IRQ_ENABLE | 6:0 | one bit per interrupt | RW | 0x0 | 1 enables the IRQ_STATUS bit onto `irq` |
| FLAGS | 1:0 | one bit per stream flag | RO | 0x0 | see FLAGS |
| SCRATCH | 31:0 | SCRATCH | RW | 0x00000000 | free for software |
| CFG | 4:0 | `cfg_div` | RW | 0x1F | byte time - 1 in PCLK (both ends of the link alike) |
| CFG | 5 | `cfg_promisc` | RW | 0x0 | accept every DA |
| CFG | 6 | `cfg_pause_en` | RW | 0x1 | obey received PAUSE frames |
| MAC0 | 31:0 | `cfg_mac[31:0]` | RW | 0x0 | station address |
| MAC1 | 15:0 | `cfg_mac[47:32]` | RW | 0x0 | station address |
| TX | 7:0 | `tx_data` | RW | 0x0 | byte |
| TX | 8 | `tx_last` | RW | 0x0 | last byte of the frame |
| RX | 7:0 | `rx_data` | RO (pop) | 0x0 | byte |
| RX | 8 | `rx_last` | RO (pop) | 0x0 | last byte of the frame |
| RX | 12:9 | `rx_stat` | RO (pop) | 0x0 | with rx_last: {pause, phy_err, len_err, crc_err} |
| STATUS | 0 | `tx_paused` | RO | core | a received PAUSE holds the transmitter |

### Interrupts (IRQ_STATUS, IRQ_ENABLE)

A bit is set while its source is active, stays set until written with 1, and a set in the same clock as the clear wins.

| Bit | Name | Set when |
|---|---|---|
| 0 | TX_SENT | a frame was sent (FCS out) |
| 1 | TX_UNDERRUN | a transmit byte was late: the frame was ended with gtx_er |
| 2 | RX_FRAG | a fragment or a bad preamble was received and dropped |
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
* **RX** captures `rx_data`, `rx_last`, `rx_stat` when `rx_valid` is high and the register is empty (or is being read in the same clock), and sets FLAGS/IRQ RX_AVAIL. Reading RX pops it. A beat that arrives while the register is full is dropped and sets RX_OVF.

### Programming sequence

1. Release PRESETN. Read ID (0x000) and check it is 0x45540200.
2. Write 0x7F to IRQ_STATUS (0x004) to clear any stale bits.
3. Configure the core: write CFG (0x014), MAC0 (0x018), MAC1 (0x01C). Reset values are in the register map; PSTRB selects the bytes written.
4. Write IRQ_ENABLE (0x008) with the interrupts to use (bit order as in the Interrupts table; 0x7F enables all).
5. To send on TX: wait until FLAGS.TX_FULL (bit 0) is 0, or for IRQ TX_DONE, then write TX (0x020). The last write commits the beat. TX_OVF means a write came while the register was full and was dropped.
6. To receive on RX: wait for IRQ RX_AVAIL or FLAGS.RX_AVAIL (bit 1), then read RX (0x024). Reading the last word frees the register for the next beat; write 1 to IRQ_STATUS.RX_AVAIL (bit 5) to clear it. Read each beat before the next arrives, or it is dropped and RX_OVF is set.
7. Read STATUS (0x028) for the core's live `tx_paused`; it needs no clearing.
8. On `irq`: read IRQ_STATUS, handle every bit that is set and enabled, then write those bits back to IRQ_STATUS to clear them. A source that is still active sets its bit again.
<!-- /AUTO:registers -->

## 3. Timing

### 3.1 Byte time

`dc` counts 0 .. `cfg_div` and restarts; the last clock of each byte time is a byte edge. The
GMII outputs change only at byte edges and the GMII inputs are sampled only at byte edges.

### 3.2 Transmit

At a byte edge in IDLE with `tx_valid` and no PAUSE running: `gtx_en` = 1 and the frame starts:
7 bytes 0x55 then the SFD 0xD5. Then, in DATA, `tx_ready` = 1 in the clock of each byte edge:

* with `tx_valid`: the byte goes on `gtxd` and into the CRC; with `tx_last` the frame data ends:
  if fewer than 60 bytes were sent, zero bytes pad it to 60;
* without `tx_valid`: underrun: one byte 0x00 with `gtx_er` = 1, `tx_underrun` pulses, and the
  frame ends (no FCS).

Then the FCS: the complement of the CRC-32 (reflected polynomial 0xEDB88320, init 0xFFFFFFFF) over
DA .. padding, least significant byte first; `tx_done` pulses with the 4th FCS byte. Then 12 byte
times with `gtx_en` = `gtx_er` = 0 and `gtxd` 0 before the next frame can start.

### 3.3 Receive

At each byte edge:

* IDLE / PREAMBLE: `grx_dv` = 1 with 0xD5 starts the frame (any number of 0x55 before it, also
  none); 0x55 continues the preamble; any other byte pulses `rx_frag` and the rest of the burst is
  dropped. `grx_dv` falling during the preamble pulses `rx_frag`.
* DATA: each byte with `grx_dv` enters the CRC and a six-byte delay line; `grx_er` marks the frame.
  The sixth byte completes the DA: the frame is accepted if `cfg_promisc`, DA = `cfg_mac`, DA =
  broadcast, or DA = 01-80-C2-00-00-01. From the seventh byte on, an accepted frame outputs the
  byte six earlier (`rx_valid` one clock).
* `grx_dv` low ends the frame: fewer than 6 bytes is a fragment (`rx_frag`); a rejected frame is
  dropped silently; an accepted one outputs the two delayed bytes still owed at the next two byte
  edges, the second with `rx_last` and `rx_stat`. The last four bytes (the FCS) are not output.

`rx_stat` = {pause, phy_err, len_err, crc_err}:

| Bit | Set when |
|---|---|
| crc_err | the CRC over the whole frame, FCS included, is not the residue 0xDEBB20E3 |
| len_err | fewer than 64 bytes, or more than 1518 (1522 when the type at bytes 12..13 is 0x8100), FCS included |
| phy_err | `grx_er` at any byte of the frame |
| pause | type 0x8808, opcode 0x0001 at bytes 14..15, at least 18 bytes |

### 3.4 PAUSE

A received frame with the pause bit and no CRC / length / PHY error, with `cfg_pause_en`, loads
the pause counter with quanta (bytes 16..17) x 64 byte times at its last byte. The counter falls
by one at each byte edge; while it is not 0 `tx_paused` = 1 and no new frame starts (a frame
already started is finished).

### 3.5 Reset

While `rst_n` is low: both sides IDLE, every output 0, no PAUSE.

## 4. Parameters

None.

## 5. Errors and corner cases

| Case | Behaviour |
|---|---|
| host late with a byte | underrun byte with `gtx_er`, frame ended, `tx_underrun` |
| frame shorter than 60 bytes | zero padding |
| bad preamble byte | `rx_frag`, rest dropped |
| frame shorter than 6 bytes | `rx_frag` |
| DA not accepted | dropped, no event |
| FCS error, length error, `grx_er` | frame delivered with the `rx_stat` bit |
| VLAN-tagged frame | 1522 bytes allowed |
| PAUSE with an error, or `cfg_pause_en` 0 | delivered with the pause bit, transmitter not held |
| PAUSE with quanta 0 | ends a running PAUSE |
| reset mid-frame | lines idle, everything cleared |

## 6. TB check map

Messages are printed by `tb/Ethernet_tb.sv` as `ERROR: <message>`. Assertions `a_*` are in the
bound checker `tb/cov/Ethernet_sva.sv`. Two MACs A and B are cross-connected (the TB can take over
A's receive lines). A line monitor per MAC checks every frame sent (preamble, data, padding, FCS,
underrun byte, gap); a reference receiver per MAC predicts every received byte, `rx_last`,
`rx_stat` and `rx_frag`. B sends PAUSE frames to A; byte times of 1, 2, 4 and 32 clocks, every
frame size up to past the VLAN maximum, promiscuous mode and resets are run.

| Check (TB message or assertion) | What it requires | Spec |
|---|---|---|
| "MAC" | per MAC: gap >= 12, preamble and SFD, data, padding, FCS bytes, `gtx_er` only at an underrun, frame length, received bytes and fragments as predicted | §3.2, §3.3 |
| "traffic did not drain: fh" | every frame sent and received | §3.2, §3.3 |
| "PAUSE seen / not seen" | the PAUSE frame is recognised | §3.3, §3.4 |
| "A started a frame" | no new frame for quanta x 64 byte times | §3.4 |
| "A held its frame for a PAUSE it should ignore" | no hold with `cfg_pause_en` 0 or a bad FCS | §3.4 |
| a_tx_ready | `tx_ready` in DATA at byte edges | §3.2 |
| a_gtx | `gtx_en` / `gtx_er` / `gtxd` exactly as the checker's model | §3.2 |
| a_tx_events | `tx_done` / `tx_underrun` as the model | §3.2 |
| a_paused | `tx_paused` as the model | §3.4 |
| a_rx_valid | `rx_valid` / `rx_frag` as the model | §3.3 |
| a_rx | `rx_data` / `rx_last` as the model | §3.3 |
| a_rx_stat | `rx_stat` at the last byte as the model | §3.3 |
| a_reset | in reset: lines idle, no host strobes | §3.5 |
