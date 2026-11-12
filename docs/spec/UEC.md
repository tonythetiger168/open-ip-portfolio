<!-- SPDX-License-Identifier: Apache-2.0 -->
# UEC: design specification

An Ultra Ethernet Transport style packet delivery sublayer (PDS) for one packet delivery context
in reliable unordered delivery (RUD): PSNs, a retransmit window, cumulative and selective ACKs,
NACKs for no receive buffer, a retransmit timer. Not implemented: PDC establishment and teardown
(the PSNs and `enable` are pins), the ROD / RUDI / UUD modes, the semantic sublayer, congestion
control and packet spraying, ACK coalescing timers and ACK-CC, the security sublayer, multiple
PDCs; frame layouts are this design's own. Core `UEC_top` (`rtl/UEC_top.sv`), testbench
`tb/UEC_tb.sv` (two ends over a lossy network model, then one end against a frame BFM), checker
`tb/cov/UEC_sva.sv`.

Conventions on this page: every flop is clocked on the rising edge of `clk` and reset
asynchronously by `rst_n` low. Byte streams transfer when valid and ready are both 1. Multi-byte
fields go most significant byte first; PSN arithmetic is modulo 2^16.

## 1. Interface

| Port | Dir | Width | Meaning | Active | Clock | Reset |
|---|---|---|---|---|---|---|
| `clk` | input | 1 | clock | rising edge | - | - |
| `rst_n` | input | 1 | asynchronous reset | low | async | - |
| `enable` | input | 1 | the PDC is open; low loads the start PSNs and drops everything | high | `clk` | - |
| `start_psn_tx` | input | 16 | first PSN sent (loaded while `enable` is low) | - | `clk` | - |
| `start_psn_rx` | input | 16 | first PSN expected (loaded while `enable` is low) | - | `clk` | - |
| `tx_valid` | input | 1 | host write byte offered | high | `clk` | - |
| `tx_ready` | output | 1 | byte taken; combinational | high | comb | 0 |
| `tx_data` | input | 8 | host write byte | - | `clk` | - |
| `tx_last` | input | 1 | last byte of a packet | high | `clk` | - |
| `rx_valid` | output | 1 | a received packet byte is available; combinational from flops | high | `clk` | 0 |
| `rx_ready` | input | 1 | the host takes it | high | `clk` | - |
| `rx_data` | output | 8 | received byte | - | `clk` | - |
| `rx_last` | output | 1 | last byte of the packet | high | `clk` | - |
| `net_tx_valid` | output | 1 | a frame byte is offered to the network | high | `clk` | 0 |
| `net_tx_ready` | input | 1 | the network takes it | high | `clk` | - |
| `net_tx_data` | output | 8 | frame byte; combinational from flops | - | `clk` | - |
| `net_tx_last` | output | 1 | last byte of the frame | high | `clk` | - |
| `net_rx_valid` | input | 1 | a frame byte arrives (no back-pressure) | high | `clk` | - |
| `net_rx_data` | input | 8 | frame byte | - | `clk` | - |
| `net_rx_last` | input | 1 | last byte of the frame | high | `clk` | - |
| `outstanding` | output | $clog2(`W`) + 1 | packets written and not yet acknowledged; combinational from flops | - | `clk` | 0 |
| `ev_rto` | output | 1 | one-clock pulse: retransmit timer expired | high | `clk` | 0 |
| `ev_nack` | output | 1 | one-clock pulse: a NACK marked a packet for retransmission | high | `clk` | 0 |
| `ev_dup` | output | 1 | one-clock pulse: a duplicate DATA packet was dropped | high | `clk` | 0 |
| `ev_nobuf` | output | 1 | one-clock pulse: a DATA packet found no receive buffer | high | `clk` | 0 |
| `ev_proto` | output | 1 | one-clock pulse: a bad frame was dropped | high | `clk` | 0 |

## 2. Registers

<!-- AUTO:registers -->
Generated from [`docs/ip/UEC.md`](../ip/UEC.md) (source: `scripts/apb/specs/UEC.json`); do not edit by hand.

`UEC_apb` is an APB4 slave (AMBA APB protocol v2.0): zero wait states, 32-bit data, 12-bit byte address, PSTRB byte lanes on every writable register, PSLVERR on an unmapped or misaligned address (reads then return 0, writes are dropped). Writes to read-only registers are ignored without an error. The core runs on PCLK and PRESETN. `irq` is level-high: `|(IRQ_STATUS & IRQ_ENABLE)`.

Pass-through pins: `net_tx_valid`, `net_tx_ready`, `net_tx_data`, `net_tx_last`, `net_rx_valid`, `net_rx_data`, `net_rx_last`.

### Register map

| Offset | Name | Access | Reset | Description |
|---|---|---|---|---|
| 0x000 | ID | RO | 0x55450200 | IP identification: code, major and minor version |
| 0x004 | IRQ_STATUS | W1C | 0x00000000 | Sticky interrupt bits, write 1 to clear |
| 0x008 | IRQ_ENABLE | RW | 0x00000000 | Interrupt enables; irq = \|(IRQ_STATUS & IRQ_ENABLE) |
| 0x00C | FLAGS | RO | 0x00000000 | Stream holding-register state |
| 0x010 | SCRATCH | RW | 0x00000000 | Scratch register, no effect on the core |
| 0x014 | CTRL | RW | 0x00000000 | PDC control |
| 0x018 | PSN | RW | 0x00000000 | Start PSNs (taken while CTRL.enable is 0) |
| 0x01C | TX | RW | 0x00000000 | Packet byte to send; one write per byte, LAST on the final byte (a packet is cut after MAXP = 16 bytes). Bytes are taken while the retransmit window (W = 4 packets) has room |
| 0x020 | RX | RO (pop) | 0x00000000 | Received packet byte (packets in arrival order); reading it pops it. While RX is not read the core's RXB = 2 receive buffers fill and further packets are NACKed |
| 0x024 | STATUS | RO | core | Sender state |

Unlisted bits read 0 and ignore writes. Reset "core": the register reads the core's outputs directly, so after reset it shows the core's own reset state. WO (pulse) registers read 0. Offsets from 0x028 up to 0xFFC are unmapped (PSLVERR).

### Fields

| Register | Bits | Field | Access | Reset | Description |
|---|---|---|---|---|---|
| ID | 31:16 | CODE | RO | 0x5545 | IP code |
| ID | 15:8 | MAJOR | RO | 0x02 | major version |
| ID | 7:0 | MINOR | RO | 0x00 | minor version |
| IRQ_STATUS | 7:0 | one bit per interrupt | W1C | 0x0 | see Interrupts |
| IRQ_ENABLE | 7:0 | one bit per interrupt | RW | 0x0 | 1 enables the IRQ_STATUS bit onto `irq` |
| FLAGS | 1:0 | one bit per stream flag | RO | 0x0 | see FLAGS |
| SCRATCH | 31:0 | SCRATCH | RW | 0x00000000 | free for software |
| CTRL | 0 | `enable` | RW | 0x0 | the PDC is open; clearing it drops every packet, frame and buffer and loads the start PSNs |
| PSN | 15:0 | `start_psn_tx` | RW | 0x0 | the first PSN this end sends |
| PSN | 31:16 | `start_psn_rx` | RW | 0x0 | the first PSN this end expects |
| TX | 7:0 | `tx_data` | RW | 0x0 | byte |
| TX | 8 | `tx_last` | RW | 0x0 | last byte of the packet |
| RX | 7:0 | `rx_data` | RO (pop) | 0x0 | byte |
| RX | 8 | `rx_last` | RO (pop) | 0x0 | last byte of the packet |
| STATUS | 2:0 | `outstanding` | RO | core | packets written and not yet acknowledged (0..4) |

### Interrupts (IRQ_STATUS, IRQ_ENABLE)

A bit is set while its source is active, stays set until written with 1, and a set in the same clock as the clear wins.

| Bit | Name | Set when |
|---|---|---|
| 0 | RTO | the retransmit timer expired: every unacknowledged packet is sent again |
| 1 | NACK | a NACK arrived: that packet is sent again |
| 2 | DUP | a packet received before arrived again (dropped, ACKed) |
| 3 | NOBUF | a new packet found no receive buffer: dropped and NACKed |
| 4 | ERR_PROTO | a bad frame (type, length) or an ACK / NACK / PSN no peer could send: dropped |
| 5 | TX_DONE | TX beat accepted by the core |
| 6 | TX_OVF | write to TX while full (dropped) |
| 7 | RX_AVAIL | RX captured a beat |

### FLAGS

| Bit | Name | Meaning |
|---|---|---|
| 0 | TX_FULL | TX holds a beat the core has not taken |
| 1 | RX_AVAIL | RX holds an unread beat |

### Streams

* **TX** feeds `tx_data`, `tx_last`/`tx_valid`. Writing TX commits the beat: FLAGS.TX_FULL is set and `tx_valid` stays high until the core's `tx_ready`; then TX_DONE is set. A write while full is dropped and sets TX_OVF.
* **RX** takes `rx_data`, `rx_last` from the core with `rx_valid` / `rx_ready`: `rx_ready` is high while the register is empty (or is being read in the same clock), and a captured beat sets FLAGS/IRQ RX_AVAIL. Reading RX pops it. Nothing is dropped: the core holds its data until the register is free.

### Programming sequence

1. Release PRESETN. Read ID (0x000) and check it is 0x55450200.
2. Write 0xFF to IRQ_STATUS (0x004) to clear any stale bits.
3. Configure the core: write CTRL (0x014), PSN (0x018). Reset values are in the register map; PSTRB selects the bytes written.
4. Write IRQ_ENABLE (0x008) with the interrupts to use (bit order as in the Interrupts table; 0xFF enables all).
5. To send on TX: wait until FLAGS.TX_FULL (bit 0) is 0, or for IRQ TX_DONE, then write TX (0x01C). The last write commits the beat. TX_OVF means a write came while the register was full and was dropped.
6. To receive on RX: wait for IRQ RX_AVAIL or FLAGS.RX_AVAIL (bit 1), then read RX (0x020). Reading the last word frees the register for the next beat; write 1 to IRQ_STATUS.RX_AVAIL (bit 7) to clear it.
7. Read STATUS (0x024) for the core's live `outstanding`; it needs no clearing.
8. On `irq`: read IRQ_STATUS, handle every bit that is set and enabled, then write those bits back to IRQ_STATUS to clear them. A source that is still active sets its bit again.
<!-- /AUTO:registers -->

## 3. Timing

### 3.1 Frames

| Frame | Bytes |
|---|---|
| DATA | 0x10, PSN[15:8], PSN[7:0], LEN, LEN payload bytes (LEN 1..`MAXP`) |
| ACK | 0x20, CACK[15:8], CACK[7:0], SACK |
| NACK | 0x30, PSN[15:8], PSN[7:0] |

CACK: every PSN up to it was received. SACK bit j: PSN CACK + 2 + j was received (j < `W` - 1).
Any other type, a frame whose length does not match its type, or a DATA LEN of 0 or over `MAXP`
is dropped with `ev_proto`. A frame is decided at its last byte.

### 3.2 Sender

Host bytes go into a slot of a `W`-packet retransmit buffer; a packet ends at `tx_last` or after
`MAXP` bytes and gets the next PSN (from `start_psn_tx`). `tx_ready` = `enable` and fewer than
`W` packets outstanding and the slot being written is not the one on the network right now.

* A packet is sent once, then kept until an ACK covers it by CACK or SACK.
* ACK: CACK behind the window is ignored; CACK past the packets sent is `ev_proto`; otherwise the
  covered packets are freed. The window base moves past freed packets, one per clock.
* NACK for an outstanding, unacknowledged PSN marks it for retransmission (`ev_nack`); for a
  PSN behind the window it is ignored; for a PSN not yet sent it is `ev_proto`.
* Timer: with sent, unacknowledged packets and no progress (no packet freed, window not moved)
  for `RTO` clocks, `ev_rto` pulses and every sent unacknowledged packet is marked for
  retransmission.

### 3.3 Receiver

Expects PSNs from `start_psn_rx`, keeping the next missing PSN (base) and which of the next
`W` - 1 arrived. For a DATA frame with d = PSN - base:

* d < `W` and not yet received: new. If a receive buffer (of `RXB`) was free at the frame's first
  byte, the packet is stored, handed to the host in arrival order, and recorded (the base moves
  over the run of received PSNs); otherwise `ev_nobuf` and a NACK for it becomes due (one NACK at
  a time; while one is due, another packet without a buffer is not NACKed).
* Already received or behind the base: `ev_dup`.
* Beyond the window: `ev_proto`.

New, duplicate and NACKed DATA frames each make an ACK due. One ACK, with the state at the time it
starts, covers every ACK due until then: CACK = base - 1, SACK = received bits.

### 3.4 Transmit order

When the network transmitter is idle, it picks in order: a due NACK, a due ACK, the
lowest-PSN packet marked for retransmission, the next new packet. Bytes are offered with
`net_tx_valid` and held until `net_tx_ready`; the next frame starts one clock after the last byte
is taken.

### 3.5 Enable and reset

While `enable` is low: every buffer, both PSN spaces, pending ACK / NACK and a frame being sent
(cut short; the MAC must drop it) are cleared, and the start PSNs are loaded. While `rst_n` is
low everything is 0 (PSNs 0); `enable` must be low for a clock after reset.

## 4. Parameters

| Parameter | Default | Meaning |
|---|---|---|
| `MAXP` | 16 | payload bytes per packet (power of 2, at most 128) |
| `W` | 4 | retransmit window, packets (power of 2, 2..8) |
| `RXB` | 2 | receive buffers (power of 2) |
| `RTO` | 256 | retransmit timeout, clocks (power of 2) |

## 5. Errors and corner cases

| Case | Behaviour |
|---|---|
| unknown type, wrong length, LEN 0 or over `MAXP` | dropped, `ev_proto` |
| DATA past the receive window | dropped, `ev_proto` |
| duplicate DATA | dropped, `ev_dup`, ACK due |
| no receive buffer | dropped, `ev_nobuf`, NACK due |
| late ACK / NACK | ignored |
| ACK / NACK beyond the packets sent | `ev_proto` |
| host packet over `MAXP` bytes | cut into packets |
| PSN wrap | modulo 2^16 |

## 6. TB check map

Messages are printed by `tb/UEC_tb.sv` as `ERROR: <message>`. Assertions `a_*` are in the bound
checker `tb/cov/UEC_sva.sv`. Part 1 runs two ends over a network model that drops, duplicates,
reorders and delays frames, with scoreboards that every packet arrives once and whole; part 2 runs
end A against a BFM that sends any frame.

| Check (TB message or assertion) | What it requires | Spec |
|---|---|---|
| "end" | every packet delivered exactly once, whole | §3.2, §3.3 |
| "A: ACK length" | ACK frame format | §3.1 |
| "A: NACK length" | NACK frame format | §3.1 |
| "A: DATA length" | DATA frame format | §3.1 |
| "A: DATA PSN" | PSNs | §3.2 |
| "A: frame type" | frame types | §3.1 |
| "ACK" | CACK / SACK contents | §3.3 |
| "NACK" | NACK PSN | §3.3 |
| "ACK after the frame errors" | bad frames change nothing | §3.1 |
| "A: no retransmission after the timeout" | timer retransmission | §3.2 |
| a_tx_ready | `tx_ready` as the model | §3.2 |
| a_rx_valid | host receive handshake | §3.3 |
| a_rx_byte | received bytes | §3.3 |
| a_net_tx | network frames as the model | §3.4 |
| a_outstanding | `outstanding` as the model | §3.2 |
| a_events | event pulses as the model | §3.2, §3.3 |
| a_reset | reset / disable values | §3.5 |
