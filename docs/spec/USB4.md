<!-- SPDX-License-Identifier: Apache-2.0 -->
# USB4: design specification

A USB4-style transport layer adapter for one link, as an educational slice: transport layer
packets with HEC-protected headers, HEC delineation (as in ATM cell delineation), two tunnelled
paths with HopID routing, and credit-based flow control per path. Not implemented: the logical
layer (lane bonding, 64b/66b, RS-FEC, LTSSM), control packets and the configuration space, link
management packets other than the credit grant, more than two paths, shared buffering and the
protocol adapters. Field layouts follow the USB4 transport layer as read by the author and are not
checked against a compliant router. Core `USB4_top` (`rtl/USB4_top.sv`), testbench `tb/USB4_tb.sv`
(two adapters cross-connected, then adapter A against a byte-level link partner), checker
`tb/cov/USB4_sva.sv`.

Conventions on this page: every flop is clocked on the rising edge of `clk` and reset
asynchronously by `rst_n` low. Multi-byte fields go on the line most significant byte first.

## 1. Interface

| Port | Dir | Width | Meaning | Active | Clock | Reset |
|---|---|---|---|---|---|---|
| `clk` | input | 1 | clock; one line byte per clock each way | rising edge | - | - |
| `rst_n` | input | 1 | asynchronous reset | low | async | - |
| `link_up` | input | 1 | the logical layer below is up; low resets the link state (section 3.6) | high | `clk` | - |
| `tx_sym` | output | 8 | transmit byte stream, most significant byte of each field first; 0 while the link is down | - | `clk` | 0x00 |
| `rx_sym` | input | 8 | receive byte stream, any alignment | - | `clk` | - |
| `path_en` | input | 2 | path enables | high | `clk` | - |
| `hop_tx0` | input | 11 | path 0 egress HopID (put in its data packets; matched by received credit grants) | - | `clk` | - |
| `hop_tx1` | input | 11 | path 1 egress HopID | - | `clk` | - |
| `hop_rx0` | input | 11 | path 0 ingress HopID (accepted data packets; put in its credit grants) | - | `clk` | - |
| `hop_rx1` | input | 11 | path 1 ingress HopID | - | `clk` | - |
| `tx_valid` | input | 1 | a packet byte is offered | high | `clk` | - |
| `tx_ready` | output | 1 | `tx_path`'s transmit buffer is free; combinational | high | comb | 1 |
| `tx_data` | input | 8 | packet byte | - | `clk` | - |
| `tx_last` | input | 1 | last byte of the packet | high | `clk` | - |
| `tx_path` | input | 1 | path of the offered byte | - | `clk` | - |
| `rx_valid` | output | 1 | a received packet is waiting; combinational from the order queue | high | comb | 0 |
| `rx_ready` | input | 1 | the consumer takes `rx_data` this clock | high | `clk` | - |
| `rx_data` | output | 8 | byte of the packet at the head of the order queue; combinational | - | comb | - |
| `rx_last` | output | 1 | `rx_data` is the packet's last byte; combinational | high | comb | - |
| `rx_path` | output | 1 | path of the head packet; combinational | - | comb | - |
| `sync` | output | 1 | receive delineation is in SYNC (`dst` == SYNC) | high | `clk` | 0 |
| `path_up` | output | 2 | a valid credit grant arrived for the path since link up | high | `clk` | 00 |
| `ev_hec_fix` | output | 1 | one-clock pulse: header single-bit error corrected in SYNC | high | `clk` | 0 |
| `ev_hec_bad` | output | 1 | one-clock pulse: uncorrectable header in SYNC (back to HUNT) | high | `clk` | 0 |
| `ev_proto` | output | 1 | one-clock pulse: bad HopID 0 packet or rejected credit grant | high | `clk` | 0 |
| `ev_hop` | output | 1 | one-clock pulse: data packet for no enabled path | high | `clk` | 0 |
| `ev_len` | output | 1 | one-clock pulse: data packet length 0 or over `MAXL` | high | `clk` | 0 |
| `ev_overflow` | output | 1 | one-clock pulse: data packet for a path whose buffers are all full | high | `clk` | 0 |

### Internal signals used by the verification

The TB reads `tst`, `tkind`, `tcnt` and `occ` of adapter A (`u_a`) to time a link drop inside a
packet and for its debug print; fsm_cov binds `tst`, `dst` and `rst`. Keep these names and
encodings.

| Signal | Width | Meaning |
|---|---|---|
| `tst` | 1 | transmitter: 0 IDLE (link just up), 1 in a packet |
| `tkind` | 2 | kind of the packet being sent: 0 Idle, 1 credit grant, 2 data |
| `tcnt` | $clog2(`MAXL`+5) | bytes of the current packet already on `tx_sym` (1 after the first) |
| `occ` | 2 x ($clog2(`RXB`)+1) | full receive buffers per path, `[0:1]` |
| `dst` | 2 | delineation: 0 HUNT, 1 PRESYNC, 2 SYNC |
| `rst` | 1 | receive parser: 0 header, 1 payload |

## 2. Registers

<!-- AUTO:registers -->
Generated from [`docs/ip/USB4.md`](../ip/USB4.md) (source: `scripts/apb/specs/USB4.json`); do not edit by hand.

`USB4_apb` is an APB4 slave (AMBA APB protocol v2.0): zero wait states, 32-bit data, 12-bit byte address, PSTRB byte lanes on every writable register, PSLVERR on an unmapped or misaligned address (reads then return 0, writes are dropped). Writes to read-only registers are ignored without an error. The core runs on PCLK and PRESETN. `irq` is level-high: `|(IRQ_STATUS & IRQ_ENABLE)`.

Pass-through pins: `tx_sym`, `rx_sym`.

### Register map

| Offset | Name | Access | Reset | Description |
|---|---|---|---|---|
| 0x000 | ID | RO | 0x55340200 | IP identification: code, major and minor version |
| 0x004 | IRQ_STATUS | W1C | 0x00000000 | Sticky interrupt bits, write 1 to clear |
| 0x008 | IRQ_ENABLE | RW | 0x00000000 | Interrupt enables; irq = \|(IRQ_STATUS & IRQ_ENABLE) |
| 0x00C | FLAGS | RO | 0x00000000 | Stream holding-register state |
| 0x010 | SCRATCH | RW | 0x00000000 | Scratch register, no effect on the core |
| 0x014 | CTRL | RW | 0x00000000 | Link and path control |
| 0x018 | HOP0 | RW | 0x00000000 | Path 0 HopIDs (change them only while the path is disabled) |
| 0x01C | HOP1 | RW | 0x00000000 | Path 1 HopIDs (change them only while the path is disabled) |
| 0x020 | TX | RW | 0x00000000 | Packet byte to send on a path; one write per byte, LAST on the final byte (a packet is cut after MAXL = 32 bytes). Each path has one packet buffer: bytes are taken while the PATH's buffer is free, and the buffer frees once the packet went out (the partner must have granted credit). The two paths' bytes may be interleaved |
| 0x024 | RX | RO (pop) | 0x00000000 | Received packet byte (head of the core's receive buffers, packets in arrival order); reading it pops it. A credit grant is sent once a packet is read out |
| 0x028 | STATUS | RO | core | Link state |

Unlisted bits read 0 and ignore writes. Reset "core": the register reads the core's outputs directly, so after reset it shows the core's own reset state. WO (pulse) registers read 0. Offsets from 0x02C up to 0xFFC are unmapped (PSLVERR).

### Fields

| Register | Bits | Field | Access | Reset | Description |
|---|---|---|---|---|---|
| ID | 31:16 | CODE | RO | 0x5534 | IP code |
| ID | 15:8 | MAJOR | RO | 0x02 | major version |
| ID | 7:0 | MINOR | RO | 0x00 | minor version |
| IRQ_STATUS | 8:0 | one bit per interrupt | W1C | 0x0 | see Interrupts |
| IRQ_ENABLE | 8:0 | one bit per interrupt | RW | 0x0 | 1 enables the IRQ_STATUS bit onto `irq` |
| FLAGS | 1:0 | one bit per stream flag | RO | 0x0 | see FLAGS |
| SCRATCH | 31:0 | SCRATCH | RW | 0x00000000 | free for software |
| CTRL | 0 | `link_up` | RW | 0x0 | the logical layer is up: Idle packets, then credit grants; clearing it returns delineation to HUNT and restarts credit counts (a packet cut by it is sent again) |
| CTRL | 2:1 | `path_en` | RW | 0x0 | paths enabled (bit p: path p sends, accepts its ingress HopID and grants credit) |
| HOP0 | 10:0 | `hop_tx0` | RW | 0x0 | egress HopID: put in path 0's packets, and matched against credit grants |
| HOP0 | 21:11 | `hop_rx0` | RW | 0x0 | ingress HopID: packets with it go to path 0 |
| HOP1 | 10:0 | `hop_tx1` | RW | 0x0 | egress HopID of path 1 |
| HOP1 | 21:11 | `hop_rx1` | RW | 0x0 | ingress HopID of path 1 |
| TX | 7:0 | `tx_data` | RW | 0x0 | byte |
| TX | 8 | `tx_last` | RW | 0x0 | last byte of the packet |
| TX | 9 | `tx_path` | RW | 0x0 | path |
| RX | 7:0 | `rx_data` | RO (pop) | 0x0 | byte |
| RX | 8 | `rx_last` | RO (pop) | 0x0 | last byte of the packet |
| RX | 9 | `rx_path` | RO (pop) | 0x0 | the path it came in on |
| STATUS | 0 | `sync` | RO | core | receive delineation in SYNC |
| STATUS | 2:1 | `path_up` | RO | core | bit p: a credit grant arrived for path p |

### Interrupts (IRQ_STATUS, IRQ_ENABLE)

A bit is set while its source is active, stays set until written with 1, and a set in the same clock as the clear wins.

| Bit | Name | Set when |
|---|---|---|
| 0 | HEC_FIX | a header with a single-bit error was corrected |
| 1 | ERR_HEC | a header HEC error in SYNC that could not be corrected: delineation back to HUNT |
| 2 | ERR_PROTO | a HopID 0 packet with an unknown PDF or length, or a credit grant with reserved bits set, for no enabled path or over RXB credits ahead |
| 3 | ERR_HOP | a packet for a HopID of no enabled path: skipped |
| 4 | ERR_LEN | a data packet with length 0 or over MAXL: skipped |
| 5 | ERR_OVERFLOW | a data packet for a path whose RXB buffers are full: dropped |
| 6 | TX_DONE | TX beat accepted by the core |
| 7 | TX_OVF | write to TX while full (dropped) |
| 8 | RX_AVAIL | RX captured a beat |

### FLAGS

| Bit | Name | Meaning |
|---|---|---|
| 0 | TX_FULL | TX holds a beat the core has not taken |
| 1 | RX_AVAIL | RX holds an unread beat |

### Streams

* **TX** feeds `tx_data`, `tx_last`, `tx_path`/`tx_valid`. Writing TX commits the beat: FLAGS.TX_FULL is set and `tx_valid` stays high until the core's `tx_ready`; then TX_DONE is set. A write while full is dropped and sets TX_OVF.
* **RX** takes `rx_data`, `rx_last`, `rx_path` from the core with `rx_valid` / `rx_ready`: `rx_ready` is high while the register is empty (or is being read in the same clock), and a captured beat sets FLAGS/IRQ RX_AVAIL. Reading RX pops it. Nothing is dropped: the core holds its data until the register is free.

### Programming sequence

1. Release PRESETN. Read ID (0x000) and check it is 0x55340200.
2. Write 0x1FF to IRQ_STATUS (0x004) to clear any stale bits.
3. Configure the core: write CTRL (0x014), HOP0 (0x018), HOP1 (0x01C). Reset values are in the register map; PSTRB selects the bytes written.
4. Write IRQ_ENABLE (0x008) with the interrupts to use (bit order as in the Interrupts table; 0x1FF enables all).
5. To send on TX: wait until FLAGS.TX_FULL (bit 0) is 0, or for IRQ TX_DONE, then write TX (0x020). The last write commits the beat. TX_OVF means a write came while the register was full and was dropped.
6. To receive on RX: wait for IRQ RX_AVAIL or FLAGS.RX_AVAIL (bit 1), then read RX (0x024). Reading the last word frees the register for the next beat; write 1 to IRQ_STATUS.RX_AVAIL (bit 8) to clear it.
7. Read STATUS (0x028) for the core's live `sync`, `path_up`; it needs no clearing.
8. On `irq`: read IRQ_STATUS, handle every bit that is set and enabled, then write those bits back to IRQ_STATUS to clear them. A source that is still active sets its bit again.
<!-- /AUTO:registers -->

## 3. Timing

### 3.1 Packets

Transport layer packet: a 4-byte header, then Length payload bytes padded with zeros to a multiple
of 4. Header = {PDF[3:0], SuppID, HopID[10:0], Length[7:0], HEC[7:0]}. HEC = CRC-8
(x^8 + x^2 + x + 1, not reflected, initial value 0, bit 31 first) over header bits 31:8, XOR 0x55.
SuppID is sent 0 and ignored.

| Packet | HopID | PDF | Length | Payload |
|---|---|---|---|---|
| Idle | 0 | 0 | 0 | none |
| Credit grant | 0 | 1 | 4 | {5'b0, HopID[10:0], 8'h00, count[7:0]}: the sender's cumulative credit count for its receive path with that (ingress) HopID |
| Data | egress HopID of the path | 0 (ignored on receive) | 1..`MAXL` | packet bytes, then pad |

### 3.2 Transmit

While `link_up` is low, `tx_sym` = 0x00 and the transmitter is idle. Once it is high, packets go
back to back with no gaps: a new packet starts in the clock after the previous one's last byte (or
in the first clock with the link up), and `tx_sym` carries header byte 0 from that clock's edge,
then one byte per clock. The choice made at each start:

1. the first 2 x `DELTA` packets after the link comes up are Idle;
2. otherwise a credit grant, if one is pending for an enabled path and this end's receiver is in
   SYNC (path 0 first);
3. otherwise a data packet, if a path can send (below); the paths alternate on a tie (the
   other path is preferred after each data packet);
4. otherwise Idle.

A path can send when its buffer holds a packet, `path_en` is set, its packet is not the one on the
line now, and the granted count differs from the packets sent since link up. The packet count goes
up when its packet starts. The buffer is freed only when the packet's last byte went out with the
link still up (at the start of the next packet).

Writing: `tx_ready` = the buffer of `tx_path` is empty (combinational). Each byte with `tx_valid`
&& `tx_ready` is stored; the packet closes on `tx_last` or at `MAXL` bytes (a longer write is cut
into packets), and the buffer is then full. Bytes of the two paths may be interleaved.

### 3.3 Credits

A credit is one receive buffer. Each receive path keeps a cumulative count, `RXB` at reset; one is
added each time one of its buffers is read out. When the link is down the count restarts at the
number of free buffers.

Grants pending per path: both at reset and while the link is down, on each buffer read out, and
both every `REFRESH` clocks while in SYNC (the refresh timer is zero on the first SYNC clock, so
entering SYNC requests both at once). A grant clears its path's pending bit when it starts; the
count it carries is taken at that moment.

On receive (in SYNC), a credit grant is checked at its last payload byte: it is accepted for the
first enabled path (path 0 first) whose egress HopID is non-zero and equals the grant's HopID,
when bits 31:27 and 15:8 are zero and count - sent (8-bit) <= `RXB`. Accepting sets the path's
limit to count and `path_up`. Otherwise `ev_proto`. Limits, counts sent and `path_up` restart at
0 while the link is down.

### 3.4 Delineation

`rx_sym` is taken every clock while `link_up`. The window is the last 4 bytes received, the newest
last:

| State | Header check | Good | Bad |
|---|---|---|---|
| HUNT | every clock, on the window | PRESYNC with count 1, skip its padded payload | stay |
| PRESYNC | at each expected header | count + 1; the `DELTA`-th good header in a row: SYNC; payload skipped | HUNT |
| SYNC | at each expected header | handle the packet | a single-bit error (any of the 32 bits) is corrected and handled, `ev_hec_fix`; anything else: HUNT and `ev_hec_bad` |

In HUNT and PRESYNC no packet is delivered and no event other than those above is raised.

### 3.5 Receive

In SYNC, a good (or corrected) header is classified; its payload (Length padded to 4, up to 256
bytes) is always skipped by its length:

| Header | Result |
|---|---|
| HopID 0, PDF 0, Length 0 | Idle, nothing |
| HopID 0, PDF 1, Length 4 | credit grant (3.3) |
| HopID 0, anything else | `ev_proto` |
| HopID = `hop_rx0` with `path_en[0]`, else = `hop_rx1` with `path_en[1]` | data for that path: Length 0 or over `MAXL`: `ev_len`; all `RXB` buffers full: `ev_overflow`; else stored |
| any other HopID | `ev_hop` |

A stored packet (its bytes and pad) is queued at its last line byte, in arrival order across both
paths. The head of the queue is shown combinationally: `rx_valid` while the queue is not empty,
`rx_path`, `rx_data` (byte at the read index) and `rx_last`. Each clock with `rx_valid` &&
`rx_ready` moves to the next byte; at `rx_last` the packet is removed and its buffer freed (credit
count + 1, grant pending).

### 3.6 Link down

`link_up` low, on the next edge: the transmitter goes idle with `tx_sym` = 0, the lead-in Idle count
and the credit state (limits, sent counts, `path_up`) clear and grants are pending for both paths;
the receiver returns to HUNT and drops a partly received packet. Packets already stored stay and
can still be read; a transmit packet that was on the line stays in its buffer and is sent again
after the link is back (the partner drops the part it got).

### 3.7 Reset

`tx_sym` = 0x00, transmitter idle, buffers empty (`tx_ready` = 1), receive queue empty
(`rx_valid` = 0), delineation HUNT (`sync` = 0), `path_up` = 00, credit counts `RXB`, both grants
pending, all events 0.

## 4. Parameters

| Parameter | Default | Legal range | Effect |
|---|---|---|---|
| `MAXL` | 32 | multiple of 4, at most 64 | data payload bytes per packet and per buffer |
| `RXB` | 2 | 2 or 4 | receive buffers (credits) per path |
| `DELTA` | 4 | 2..7 | good headers in a row to reach SYNC; the lead-in is 2 x `DELTA` Idle packets |
| `REFRESH` | 128 | power of 2 | clocks between credit grant refreshes in SYNC |

## 5. Errors and corner cases

| Event | Cause | Effect |
|---|---|---|
| `ev_hec_fix` | single-bit header error in SYNC | header corrected, packet handled |
| `ev_hec_bad` | uncorrectable header in SYNC | HUNT |
| `ev_proto` | HopID 0 packet that is neither Idle nor a grant; grant with reserved bits set, for no enabled path, or with count - sent over `RXB` | packet ignored |
| `ev_hop` | data HopID matches no enabled path | skipped |
| `ev_len` | data Length 0 or over `MAXL` | skipped |
| `ev_overflow` | data for a path with all buffers full | skipped |

Each event is a registered one-clock pulse, high in the clock after the header's last byte is on `rx_sym` (the grant
check: its last payload byte). Grants are cumulative, so a lost grant is made good by the next.
A path with egress HopID 0 never accepts a grant.

## 6. TB check map

| Check (TB message or assertion) | What it requires | Spec |
|---|---|---|
| "A path" | a packet A sends on a path carries exactly the bytes written to it, in order, with the last-byte mark | §3.2, §3.3 |
| "end" | per end: every packet written at the other end comes out of the routed path once, in order, whole; every header on the line has a good HEC; `sync` is reached | §3.1, §3.5 |
| "A: bad credit grant" | grant = HopID 0, PDF 1, Length 4, reserved bits 0 | §3.1 |
| "A: bad Idle" | Idle = HopID 0, PDF 0, Length 0 | §3.1 |
| "A: data on HopID" | data packets carry the path's egress HopID | §3.2 |
| "A: padding not zero" | pad bytes are 0 | §3.1 |
| "not drained" | all written packets reach the far end | §3.3 |
| "only" | header single-bit errors are corrected | §3.4 |
| "A in SYNC on random bytes" | random bytes do not reach SYNC | §3.4 |
| "A in SYNC early" | SYNC needs `DELTA` good headers in a row | §3.4 |
| "A not in SYNC" | `DELTA` good headers give SYNC | §3.4 |
| "A granted" | the first grants carry count `RXB` per path | §3.3 |
| "A lost SYNC on single-bit errors" | corrected headers keep SYNC | §3.4 |
| "A paths not up" | a valid grant sets `path_up` | §3.3 |
| "A sent" | A sends exactly as many packets as granted, round robin between paths | §3.2, §3.3 |
| "A did not use the new credit" | a larger cumulative count allows more packets | §3.3 |
| "A sent on a disabled path" | no data on a path with `path_en` low | §3.2 |
| "A did not send after the path was enabled" | enabling a path with credit resumes it | §3.2 |
| "path 0 did not take the grant" | a grant matching path 0's egress HopID updates path 0 | §3.3 |
| "A did not send the cut packet again" | a packet cut by the link going down is sent again | §3.6 |
| "A did not refresh its grants" | grants repeat every `REFRESH` clocks in SYNC | §3.3 |
| "A not in SYNC again" | after an uncorrectable header the receiver hunts and resyncs | §3.4 |
| a_tx_sym | every `tx_sym` byte equals the checker's transmit model | §3.1..§3.3, §3.6 |
| a_tx_ready | `tx_ready` = `tx_path`'s buffer empty | §3.2 |
| a_status | `sync` and `path_up` as the model | §3.3, §3.4 |
| a_rx_valid | `rx_valid` = order queue not empty | §3.5 |
| a_rx_byte | `rx_path`, `rx_data`, `rx_last` of the head packet | §3.5 |
| a_events | the six event pulses as the model | §5 |
| a_reset | reset values | §3.7 |
