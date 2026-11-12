<!-- SPDX-License-Identifier: Apache-2.0 -->
# CXS_CCIX_Stream_Interface: design specification

One AMBA CXS (Credited eXtensible Stream) port: a transmit interface and a receive interface,
carrying packets of 32-bit words in 128-bit (4-word) flits, with the CXS link activation
handshake (ACTIVEREQ / ACTIVEACK / DEACTHINT) and credit flow control. Not implemented: other data
widths and more than two packets per flit, the continuous-delivery / CXSLAST options,
CXSPRCLTYPE, CXSDATACHECK, credit return outside DEACTIVATE, and the CCIX packet formats the
stream carries. Field positions in CXSCNTL are this design's own. Core
`CXS_CCIX_Stream_Interface_top` (`rtl/CXS_CCIX_Stream_Interface_top.sv`), testbench
`tb/CXS_CCIX_Stream_Interface_tb.sv` (two ports back to back, then a TB peer), checker
`tb/cov/CXS_CCIX_Stream_Interface_sva.sv` (a cycle-exact model of every output).

Conventions on this page: every flop is clocked on the rising edge of `clk` and reset
asynchronously by `rst_n` low. Inputs are sampled at the rising edge; registered outputs show a
decision of clock n in clock n+1. Valids, credit pulses and events are one-clock pulses.

## 1. Interface

| Port | Dir | Width | Meaning | Active | Clock | Reset |
|---|---|---|---|---|---|---|
| `clk` | input | 1 | clock | rising edge | - | - |
| `rst_n` | input | 1 | asynchronous reset of both sides | low | async | - |
| `tx_en` | input | 1 | activate the transmit side (level, §3.1) | high | `clk` | - |
| `rx_en` | input | 1 | accept the peer's activation; 0 in RUN raises DEACTHINT (§3.4) | high | `clk` | - |
| `tx_valid` | input | 1 | a packet word is offered | high | `clk` | - |
| `tx_ready` | output | 1 | the flit being filled takes a word: fewer than 4 words and not closed (§3.2); combinational | high | comb | 1 |
| `tx_data` | input | 32 | packet word | - | `clk` | - |
| `tx_last` | input | 1 | the word ends its packet | high | `clk` | - |
| `tx_err` | input | 1 | with `tx_last`: the packet ends with an error (END_ERROR) | high | `clk` | - |
| `rx_valid` | output | 1 | a received word is waiting (a flit buffer is not empty); combinational | high | comb | 0 |
| `rx_ready` | input | 1 | the user takes the word | high | `clk` | - |
| `rx_data` | output | 32 | received word (next used word of the head buffer); combinational | - | comb | - |
| `rx_last` | output | 1 | the word ends its packet | high | comb | - |
| `rx_err` | output | 1 | with `rx_last`: the packet ended with END_ERROR, or was cut by a bad flit (§3.6) | high | comb | - |
| `cxs_tx_valid` | output | 1 | CXSVALID: one flit (one clock) | high | `clk` | 0 |
| `cxs_tx_data` | output | 128 | CXSDATA: word 0 in bits 31:0 ... word 3 in bits 127:96; holds the last flit when `cxs_tx_valid` is 0 | - | `clk` | 0 |
| `cxs_tx_cntl` | output | 14 | CXSCNTL (§3.3); holds the last value when `cxs_tx_valid` is 0 | - | `clk` | 0 |
| `cxs_tx_crdgnt` | input | 1 | CXSCRDGNT from the peer receiver: one credit per clock it is 1 | high | `clk` | - |
| `cxs_tx_crdrtn` | output | 1 | CXSCRDRTN: one credit returned (in DEACTIVATE) | high | `clk` | 0 |
| `cxs_tx_activereq` | output | 1 | CXSACTIVEREQ: ACTIVATE or RUN; combinational from the link state | high | comb | 0 |
| `cxs_tx_activeack` | input | 1 | CXSACTIVEACK from the peer receiver | high | `clk` | - |
| `cxs_tx_deacthint` | input | 1 | CXSDEACTHINT from the peer receiver | high | `clk` | - |
| `cxs_rx_valid` | input | 1 | CXSVALID from the peer: one flit | high | `clk` | - |
| `cxs_rx_data` | input | 128 | CXSDATA from the peer | - | `clk` | - |
| `cxs_rx_cntl` | input | 14 | CXSCNTL from the peer (§3.3) | - | `clk` | - |
| `cxs_rx_crdgnt` | output | 1 | CXSCRDGNT: one credit granted | high | `clk` | 0 |
| `cxs_rx_crdrtn` | input | 1 | CXSCRDRTN from the peer: one credit returned | high | `clk` | - |
| `cxs_rx_activereq` | input | 1 | CXSACTIVEREQ from the peer transmitter | high | `clk` | - |
| `cxs_rx_activeack` | output | 1 | CXSACTIVEACK: receive side not in STOP; combinational | high | comb | 0 |
| `cxs_rx_deacthint` | output | 1 | CXSDEACTHINT: receive side in RUN and `rx_en` = 0; combinational | high | comb | 0 |
| `tx_link` | output | 2 | transmit state: 0 STOP, 1 ACTIVATE, 2 RUN, 3 DEACTIVATE | - | `clk` | 0 |
| `rx_link` | output | 2 | receive state: 0 STOP, 2 RUN, 3 DEACTIVATE (1 is never used) | - | `clk` | 0 |
| `tx_credits` | output | 4 | credits the transmit side holds (0..15) | - | `clk` | 0 |
| `ev_crd` | output | 1 | one-clock pulse in the clock after a credit error (§3.6) | high | `clk` | 0 |
| `ev_cntl` | output | 1 | one-clock pulse in the clock after a bad flit was dropped (§3.6) | high | `clk` | 0 |

## 2. Registers

<!-- AUTO:registers -->
Generated from [`docs/ip/CXS_CCIX_Stream_Interface.md`](../ip/CXS_CCIX_Stream_Interface.md) (source: `scripts/apb/specs/CXS_CCIX_Stream_Interface.json`); do not edit by hand.

`CXS_CCIX_Stream_Interface_apb` is an APB4 slave (AMBA APB protocol v2.0): zero wait states, 32-bit data, 12-bit byte address, PSTRB byte lanes on every writable register, PSLVERR on an unmapped or misaligned address (reads then return 0, writes are dropped). Writes to read-only registers are ignored without an error. The core runs on PCLK and PRESETN. `irq` is level-high: `|(IRQ_STATUS & IRQ_ENABLE)`.

Pass-through pins: `cxs_tx_valid`, `cxs_tx_data`, `cxs_tx_cntl`, `cxs_tx_crdgnt`, `cxs_tx_crdrtn`, `cxs_tx_activereq`, `cxs_tx_activeack`, `cxs_tx_deacthint`, `cxs_rx_valid`, `cxs_rx_data`, `cxs_rx_cntl`, `cxs_rx_crdgnt`, `cxs_rx_crdrtn`, `cxs_rx_activereq`, `cxs_rx_activeack`, `cxs_rx_deacthint`.

### Register map

| Offset | Name | Access | Reset | Description |
|---|---|---|---|---|
| 0x000 | ID | RO | 0x43530200 | IP identification: code, major and minor version |
| 0x004 | IRQ_STATUS | W1C | 0x00000000 | Sticky interrupt bits, write 1 to clear |
| 0x008 | IRQ_ENABLE | RW | 0x00000000 | Interrupt enables; irq = \|(IRQ_STATUS & IRQ_ENABLE) |
| 0x00C | FLAGS | RO | 0x00000000 | Stream holding-register state |
| 0x010 | SCRATCH | RW | 0x00000000 | Scratch register, no effect on the core |
| 0x014 | CTRL | RW | 0x00000000 | Link control |
| 0x018 | TX0 | RW | 0x00000000 | Packet word to send; writing TX1 sends it (the core takes it when the flit being filled has room) |
| 0x01C | TX1 | RW | 0x00000000 | Packet word to send; writing TX1 sends it (the core takes it when the flit being filled has room) |
| 0x020 | RX0 | RO (pop) | 0x00000000 | Received packet word; reading RX1 pops it. While RX is not read the flit buffers fill and no credit is granted |
| 0x024 | RX1 | RO (pop) | 0x00000000 | Received packet word; reading RX1 pops it. While RX is not read the flit buffers fill and no credit is granted |
| 0x028 | STATUS | RO | core | Link state |

Unlisted bits read 0 and ignore writes. Reset "core": the register reads the core's outputs directly, so after reset it shows the core's own reset state. WO (pulse) registers read 0. Offsets from 0x02C up to 0xFFC are unmapped (PSLVERR).

### Fields

| Register | Bits | Field | Access | Reset | Description |
|---|---|---|---|---|---|
| ID | 31:16 | CODE | RO | 0x4353 | IP code |
| ID | 15:8 | MAJOR | RO | 0x02 | major version |
| ID | 7:0 | MINOR | RO | 0x00 | minor version |
| IRQ_STATUS | 4:0 | one bit per interrupt | W1C | 0x0 | see Interrupts |
| IRQ_ENABLE | 4:0 | one bit per interrupt | RW | 0x0 | 1 enables the IRQ_STATUS bit onto `irq` |
| FLAGS | 1:0 | one bit per stream flag | RO | 0x0 | see FLAGS |
| SCRATCH | 31:0 | SCRATCH | RW | 0x00000000 | free for software |
| CTRL | 0 | `tx_en` | RW | 0x0 | activate the transmit side (cleared: deactivate at the next packet boundary) |
| CTRL | 1 | `rx_en` | RW | 0x0 | accept the peer's activation (cleared: DEACTHINT) |
| TX0 | 31:0 | `tx_data` | RW | 0x0 | word |
| TX1 | 0 | `tx_last` | RW | 0x0 | last word of the packet |
| TX1 | 1 | `tx_err` | RW | 0x0 | with tx_last: the packet ends with END_ERROR |
| RX0 | 31:0 | `rx_data` | RO (pop) | 0x0 | word |
| RX1 | 0 | `rx_last` | RO (pop) | 0x0 | last word of the packet |
| RX1 | 1 | `rx_err` | RO (pop) | 0x0 | with rx_last: END_ERROR, or a packet cut by a bad flit |
| STATUS | 1:0 | `tx_link` | RO | core | transmit side: 0 STOP, 1 ACTIVATE, 2 RUN, 3 DEACTIVATE |
| STATUS | 3:2 | `rx_link` | RO | core | receive side: 0 STOP, 2 RUN, 3 DEACTIVATE |
| STATUS | 7:4 | `tx_credits` | RO | core | credits held |

### Interrupts (IRQ_STATUS, IRQ_ENABLE)

A bit is set while its source is active, stays set until written with 1, and a set in the same clock as the clear wins.

| Bit | Name | Set when |
|---|---|---|
| 0 | CRD | a flit without a credit, a credit returned beyond those granted, or a grant past 15 credits |
| 1 | CNTL | a flit with bad START / END or no word used was dropped |
| 2 | TX_DONE | TX beat accepted by the core |
| 3 | TX_OVF | write to TX while full (dropped) |
| 4 | RX_AVAIL | RX captured a beat |

### FLAGS

| Bit | Name | Meaning |
|---|---|---|
| 0 | TX_FULL | TX holds a beat the core has not taken |
| 1 | RX_AVAIL | RX holds an unread beat |

### Streams

* **TX** feeds `tx_data`, `tx_last`, `tx_err`/`tx_valid`. Writing TX1 commits the beat: FLAGS.TX_FULL is set and `tx_valid` stays high until the core's `tx_ready`; then TX_DONE is set. A write while full is dropped and sets TX_OVF.
* **RX** takes `rx_data`, `rx_last`, `rx_err` from the core with `rx_valid` / `rx_ready`: `rx_ready` is high while the register is empty (or is being read in the same clock), and a captured beat sets FLAGS/IRQ RX_AVAIL. Reading RX1 pops it. Nothing is dropped: the core holds its data until the register is free.

### Programming sequence

1. Release PRESETN. Read ID (0x000) and check it is 0x43530200.
2. Write 0x1F to IRQ_STATUS (0x004) to clear any stale bits.
3. Configure the core: write CTRL (0x014). Reset values are in the register map; PSTRB selects the bytes written.
4. Write IRQ_ENABLE (0x008) with the interrupts to use (bit order as in the Interrupts table; 0x1F enables all).
5. To send on TX: wait until FLAGS.TX_FULL (bit 0) is 0, or for IRQ TX_DONE, then write TX0 (0x018) then TX1 (0x01C). The last write commits the beat. TX_OVF means a write came while the register was full and was dropped.
6. To receive on RX: wait for IRQ RX_AVAIL or FLAGS.RX_AVAIL (bit 1), then read RX0 (0x020) then RX1 (0x024). Reading the last word frees the register for the next beat; write 1 to IRQ_STATUS.RX_AVAIL (bit 4) to clear it.
7. Read STATUS (0x028) for the core's live `tx_link`, `rx_link`, `tx_credits`; it needs no clearing.
8. On `irq`: read IRQ_STATUS, handle every bit that is set and enabled, then write those bits back to IRQ_STATUS to clear them. A source that is still active sets its bit again.
<!-- /AUTO:registers -->

## 3. Timing

### 3.1 Transmit link and credits

| State (`tx_link`) | `cxs_tx_activereq` | Moves on |
|---|---|---|
| STOP (0) | 0 | `tx_en` = 1 and `cxs_tx_activeack` = 0 -> ACTIVATE (with ACTIVEACK still 1 it waits) |
| ACTIVATE (1) | 1 | `cxs_tx_activeack` = 1 -> RUN |
| RUN (2) | 1 | (`tx_en` = 0 or `cxs_tx_deacthint` = 1) and no packet open and the flit empty -> DEACTIVATE; ACTIVEACK falling alone does not leave RUN |
| DEACTIVATE (3) | 0 | `cxs_tx_activeack` = 0 -> STOP, credits held set to 0 |

Credits (`tx_credits`) are updated in this order within a clock: a `cxs_tx_crdgnt` adds one
(at 15 it is not counted and `ev_crd` pulses); a flit sent takes one; in DEACTIVATE, if any are
left, one is returned (`cxs_tx_crdrtn` pulses in the next clock); finally, in DEACTIVATE with
ACTIVEACK 0, the count becomes 0. So the clock that goes DEACTIVATE -> STOP may still return one
credit. Grants are counted in every state (a peer grants only in RUN).

### 3.2 Filling a flit

Words are taken at an edge with `tx_valid` and `tx_ready`, in any link state (they wait in the
flit until RUN). Word k of the flit goes in `cxs_tx_data[32k+31:32k]`. A word taken with no packet
open starts a packet (its index is START0_PTR, or START1_PTR for the second); a word with
`tx_last` ends one (END0_PTR / END1_PTR, END_ERROR bit 0 / 1 = `tx_err`). A packet may span
flits.

The flit is full when it holds 4 words, or it is closed (its second packet ended, so it takes no
more words), or it holds words, no packet is open and `tx_valid` is 0 this clock. `tx_ready` = not
4 words and not closed. A full flit is sent in a clock where the link is RUN and at least one
credit is held (after this clock's grant): `cxs_tx_valid` pulses in the next clock with the data
and CXSCNTL, and the flit is empty again. A word is never taken in the clock its flit is sent.

### 3.3 CXSCNTL

| Bits | Field | Value |
|---|---|---|
| 13:12 | START[1:0] | 00 no packet starts, 01 one, 11 two (10 is illegal) |
| 11:10 | START0_PTR | word index of the first start |
| 9:8 | START1_PTR | word index of the second start |
| 7:6 | END[1:0] | 00 / 01 / 11 as START |
| 5:4 | END0_PTR | word index of the first end |
| 3:2 | END1_PTR | word index of the second end |
| 1:0 | END_ERROR[1:0] | bit 0: the first ended packet has an error; bit 1: the second |

Unused pointers and error bits are sent as 0. A one-word packet has its start and end pointer
equal. Words between an end and the next start are not used; a packet open at the end of a flit
goes on in the next one.

### 3.4 Receive link and credits

| State (`rx_link`) | `cxs_rx_activeack` | Moves on |
|---|---|---|
| STOP (0) | 0 | `cxs_rx_activereq` = 1 and `rx_en` = 1 -> RUN |
| RUN (2) | 1 | `cxs_rx_activereq` = 0 -> DEACTIVATE |
| DEACTIVATE (3) | 1 | no credit out (after this clock's returns and flits) -> STOP |

`cxs_rx_deacthint` = RUN and `rx_en` = 0. Credits out are updated in a clock in this order: a
`cxs_rx_crdrtn` takes one (with none out: `ev_crd`); a flit takes one (with none out: dropped,
`ev_crd`); then in RUN (including the clock ACTIVEREQ falls) one credit is granted
(`cxs_rx_crdgnt` in the next clock) if buffers used plus credits out, both after this clock's
flit and word hand-out, are below `RXF`. At most one grant per clock.

### 3.5 Receiving a flit

A flit with a credit is checked by walking word 0 to 3 and, at each word, first a pending start
(if its pointer equals the word index) and then a pending end:

* a start while a packet is open, or an end with none open, is bad;
* START = 10 or END = 10 is bad; starts or ends that the walk never reaches (pointers not
  increasing) are bad;
* a flit that uses no word (no packet open across it and none starting) is bad.

A word is used if it lies inside a packet (from its start, or from word 0 if a packet was open,
through its end, or word 3). A good flit takes one buffer holding its 4 words, which are used,
and where packets end (with END_ERROR); the open-packet state becomes that after word 3.

Words are handed out from the head buffer in index order, skipping unused words: `rx_valid` = a
buffer is not empty, `rx_data` / `rx_last` / `rx_err` = the next used word. The buffer is freed
at the edge its last used word is taken. A word stored at an edge is visible on `rx_*` from the
next clock.

### 3.6 Errors and events

* Bad flit: dropped, `ev_cntl` in the next clock, its credit is used. If a packet was open, a
  buffer is filled with one word 0 marked `rx_last` = 1, `rx_err` = 1, closing that packet.
* Flit with no credit out, or a credit returned with none out: `ev_crd`.
* A grant arriving with 15 credits held: not counted, `ev_crd`.

Several errors in one clock give one pulse per event output.

### 3.7 Reset

While `rst_n` is low: both links STOP, no credits held or out, flit and buffers empty, no packet
open. All outputs 0 except `tx_ready` = 1.

## 4. Parameters

| Parameter | Default | Legal range | Effect |
|---|---|---|---|
| `RXF` | 4 | 2..15 | receive flit buffers, so the most credits granted |

## 5. Errors and corner cases

| Case | Behaviour |
|---|---|
| words written while the link is not in RUN | wait in the flit; sent after the next RUN |
| `tx_en` cleared with a packet open | RUN until the packet ends and its flit is sent, then DEACTIVATE |
| ACTIVEACK falls while the transmitter is in RUN | stays in RUN (peer error); credits kept |
| `tx_en` set while ACTIVEACK is still 1 in STOP | waits in STOP until it falls |
| more than 15 credits granted | extra grants dropped, `ev_crd` |
| `rx_en` cleared in RUN | DEACTHINT; the receive side stays in RUN until ACTIVEREQ falls |
| bad flit with a packet open | packet closed with an extra word 0, `rx_last` + `rx_err` |
| flit with no credit (also in STOP) | dropped, `ev_crd` |
| reset with traffic in flight | everything cleared |

## 6. TB check map

Messages are printed by `tb/CXS_CCIX_Stream_Interface_tb.sv` as `ERROR: <message>`. Assertions
`a_*` are in the bound checker `tb/cov/CXS_CCIX_Stream_Interface_sva.sv`, which computes every
output of each port in every clock. Part 1 joins two ports A and B back to back, sends random
packets of 1..12 words (some with `tx_err`) both ways under random back-pressure, and
activates / deactivates the link with `tx_en` and `rx_en` many times. Part 2 puts a TB peer on
one of A's interfaces: two packets per flit, every START / END error with and without a packet
open, a flit with no word used, a flit or a credit return without a credit, more than 15 grants,
DEACTHINT, ACTIVEACK falling in RUN, and a reset with traffic in flight.

| Check (TB message or assertion) | What it requires | Spec |
|---|---|---|
| "B: word" | every word B receives was sent by A, in order, with `rx_last` / `rx_err` | §3.2, §3.5 |
| "A: word" | the same from B to A | §3.2, §3.5 |
| "link" | the link reaches the expected transmit / receive states | §3.1, §3.4 |
| "A not in ACTIVATE with B's receive side off" | with `rx_en` 0 at the peer, the transmitter waits in ACTIVATE | §3.1, §3.4 |
| "credits held in STOP" | credits are 0 after DEACTIVATE -> STOP | §3.1 |
| "transmit side not waiting in ACTIVATE" | as above, during repeated activations | §3.1 |
| "A granted" | the receive side grants exactly `RXF` credits | §3.4 |
| "A's receive side not in DEACTIVATE" | ACTIVEREQ falling moves RUN -> DEACTIVATE | §3.4 |
| "ACTIVEACK held with no credit out" | DEACTIVATE -> STOP once every credit is back | §3.4 |
| "A holds" | 16 grants leave 15 credits held (`ev_crd`) | §3.1, §3.6 |
| "A left RUN on ACTIVEACK falling" | RUN is not left on ACTIVEACK alone | §3.1 |
| "A in" | with `tx_en` 0 and ACTIVEACK 0: STOP with 0 credits | §3.1 |
| "A returned" | DEACTHINT: all 15 credits returned in DEACTIVATE | §3.1 |
| "A not in STOP" | DEACTIVATE -> STOP when ACTIVEACK falls | §3.1 |
| "A left STOP with ACTIVEACK up" | STOP -> ACTIVATE waits for ACTIVEACK 0 | §3.1 |
| "A not activating again" | then ACTIVATE | §3.1 |
| "never sending and receiving at once" | both directions run at once (sets up the reset test) | §3.7 |
| a_tx | `tx_ready`, flit outputs, `cxs_tx_crdrtn`, ACTIVEREQ, `tx_link`, `tx_credits` exactly as the model | §3.1, §3.2, §3.3 |
| a_rx | `rx_*` from the model's word queue, `cxs_rx_crdgnt`, ACTIVEACK, DEACTHINT, `rx_link` exactly as the model | §3.4, §3.5 |
| a_events | `ev_crd` / `ev_cntl` exactly as the model | §3.6 |
| a_reset | in reset: no flit, no ACTIVEREQ / ACTIVEACK, no credit pulses, no `rx_valid`, 0 credits, no events | §3.7 |
