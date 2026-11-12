<!-- SPDX-License-Identifier: Apache-2.0 -->
# CCIX_Cache_Coherent_Interconnect: design specification

A CCIX link layer over PCIe: protocol-layer messages are packed into PCIe vendor-defined message
TLPs and taken out of received ones, with message credits for Requests and Snoops. The core sits
on a PCIe transaction layer's TLP streams. Not implemented: the CCIX transaction layer and agents
(home / request / slave agents, coherence), the optimized TLP format, CCIX TLP prefixes, the PCIe
link itself (DLLPs, PCIe flow control), port and link IDs beyond the PCIe ID, packing rules other
than in-order gathering, ESM and port discovery. Field positions and encodings are this design's
own. Core `CCIX_Cache_Coherent_Interconnect_top` (`rtl/CCIX_Cache_Coherent_Interconnect_top.sv`),
testbench `tb/CCIX_Cache_Coherent_Interconnect_tb.sv` (a TB peer link layer on the TLP streams),
checker `tb/cov/CCIX_Cache_Coherent_Interconnect_sva.sv` (a cycle-exact model of every output).

Conventions on this page: every flop is clocked on the rising edge of `clk` and reset
asynchronously by `rst_n` low. Inputs are sampled at the rising edge; registered outputs show a
decision of clock n in clock n+1. Events are one-clock pulses.

## 1. Interface

| Port | Dir | Width | Meaning | Active | Clock | Reset |
|---|---|---|---|---|---|---|
| `clk` | input | 1 | clock | rising edge | - | - |
| `rst_n` | input | 1 | asynchronous reset | low | async | - |
| `rid` | input | 16 | this end's PCIe ID (Requester ID of TLPs sent; target ID checked on TLPs received) | - | static | - |
| `tgt_rid` | input | 16 | the peer's PCIe ID (target of TLPs sent) | - | static | - |
| `tx_valid` | input | 1 | a message word is offered by the protocol layer | high | `clk` | - |
| `tx_ready` | output | 1 | the word is taken (§3.2); combinational | high | comb | 1 |
| `tx_data` | input | 32 | message word: a header (§3.1) then MsgLen - 1 body words | - | `clk` | - |
| `rx_valid` | output | 1 | a received message word is waiting; combinational | high | comb | 0 |
| `rx_ready` | input | 1 | the protocol layer takes it | high | `clk` | - |
| `rx_data` | output | 32 | received message word (header as received, credit fields included); combinational | - | comb | - |
| `rx_last` | output | 1 | last word of its message; combinational | high | comb | - |
| `tlp_tx_valid` | output | 1 | a TLP word to the transaction layer (whole TLP back to back, §3.3); combinational from the state | high | comb | 0 |
| `tlp_tx_ready` | input | 1 | the transaction layer takes the word | high | `clk` | - |
| `tlp_tx_data` | output | 32 | TLP word; combinational | - | comb | - |
| `tlp_tx_last` | output | 1 | last word of the TLP; combinational | high | comb | - |
| `tlp_rx_valid` | input | 1 | a TLP word from the transaction layer (no back-pressure) | high | `clk` | - |
| `tlp_rx_data` | input | 32 | TLP word | - | `clk` | - |
| `tlp_rx_last` | input | 1 | last word of the TLP | high | `clk` | - |
| `tx_crd_req` | output | 5 | Request credits held (granted by the peer, not used) | - | `clk` | 0 |
| `tx_crd_snp` | output | 5 | Snoop credits held | - | `clk` | 0 |
| `ev_err` | output | 1 | one-clock pulse in the clock after a malformed TLP / message / header was dropped or a credit count would pass 31 | high | `clk` | 0 |
| `ev_nocrd` | output | 1 | pulse after a received Request or Snoop was skipped for lack of a credit | high | `clk` | 0 |
| `ev_ovf` | output | 1 | pulse after a received Response was skipped for lack of room | high | `clk` | 0 |

### Internal signals used by the verification

The TB reads this by name to time a scenario; a re-implementation must have it.

| Signal | Width | Meaning |
|---|---|---|
| `rs` | 3 | receive state: 0..3 TLP header words DW0..DW3, 4 message header, 5 message body (stored), 6 message body (skipped), 7 dropping the rest of a bad TLP |

## 2. Registers

<!-- AUTO:registers -->
Generated from [`docs/ip/CCIX_Cache_Coherent_Interconnect.md`](../ip/CCIX_Cache_Coherent_Interconnect.md) (source: `scripts/apb/specs/CCIX_Cache_Coherent_Interconnect.json`); do not edit by hand.

`CCIX_Cache_Coherent_Interconnect_apb` is an APB4 slave (AMBA APB protocol v2.0): zero wait states, 32-bit data, 12-bit byte address, PSTRB byte lanes on every writable register, PSLVERR on an unmapped or misaligned address (reads then return 0, writes are dropped). Writes to read-only registers are ignored without an error. The core runs on PCLK and PRESETN. `irq` is level-high: `|(IRQ_STATUS & IRQ_ENABLE)`.

Pass-through pins: `tlp_tx_valid`, `tlp_tx_ready`, `tlp_tx_data`, `tlp_tx_last`, `tlp_rx_valid`, `tlp_rx_data`, `tlp_rx_last`.

### Register map

| Offset | Name | Access | Reset | Description |
|---|---|---|---|---|
| 0x000 | ID | RO | 0x43430200 | IP identification: code, major and minor version |
| 0x004 | IRQ_STATUS | W1C | 0x00000000 | Sticky interrupt bits, write 1 to clear |
| 0x008 | IRQ_ENABLE | RW | 0x00000000 | Interrupt enables; irq = \|(IRQ_STATUS & IRQ_ENABLE) |
| 0x00C | FLAGS | RO | 0x00000000 | Stream holding-register state |
| 0x010 | SCRATCH | RW | 0x00000000 | Scratch register, no effect on the core |
| 0x014 | ID_CFG | RW | 0x00000000 | PCIe IDs |
| 0x018 | TX | RW | 0x00000000 | Message word to send: a header {MsgType, MsgLen, credit fields (replaced), 16 protocol bits}, then MsgLen - 1 body words. A Request or Snoop header is taken once a credit is held |
| 0x01C | RX0 | RO (pop) | 0x00000000 | Received message word; reading it pops it. A Request or Snoop's credit goes back to the peer once its last word is read |
| 0x020 | RX1 | RO (pop) | 0x00000000 | Received message word; reading it pops it. A Request or Snoop's credit goes back to the peer once its last word is read |
| 0x024 | STATUS | RO | core | Credits held for sending |

Unlisted bits read 0 and ignore writes. Reset "core": the register reads the core's outputs directly, so after reset it shows the core's own reset state. WO (pulse) registers read 0. Offsets from 0x028 up to 0xFFC are unmapped (PSLVERR).

### Fields

| Register | Bits | Field | Access | Reset | Description |
|---|---|---|---|---|---|
| ID | 31:16 | CODE | RO | 0x4343 | IP code |
| ID | 15:8 | MAJOR | RO | 0x02 | major version |
| ID | 7:0 | MINOR | RO | 0x00 | minor version |
| IRQ_STATUS | 5:0 | one bit per interrupt | W1C | 0x0 | see Interrupts |
| IRQ_ENABLE | 5:0 | one bit per interrupt | RW | 0x0 | 1 enables the IRQ_STATUS bit onto `irq` |
| FLAGS | 1:0 | one bit per stream flag | RO | 0x0 | see FLAGS |
| SCRATCH | 31:0 | SCRATCH | RW | 0x00000000 | free for software |
| ID_CFG | 15:0 | `rid` | RW | 0x0 | this end's PCIe ID: the Requester ID of TLPs sent, the target ID TLPs received must carry |
| ID_CFG | 31:16 | `tgt_rid` | RW | 0x0 | the peer's PCIe ID: the target ID of TLPs sent |
| TX | 31:0 | `tx_data` | RW | 0x0 | message word |
| RX0 | 31:0 | `rx_data` | RO (pop) | 0x0 | message word |
| RX1 | 0 | `rx_last` | RO (pop) | 0x0 | last word of the message |
| STATUS | 4:0 | `tx_crd_req` | RO | core | Request credits |
| STATUS | 9:5 | `tx_crd_snp` | RO | core | Snoop credits |

### Interrupts (IRQ_STATUS, IRQ_ENABLE)

A bit is set while its source is active, stays set until written with 1, and a set in the same clock as the clear wins.

| Bit | Name | Set when |
|---|---|---|
| 0 | ERR | a malformed TLP or message was dropped, a bad header was written to TX, or a credit grant would pass 31 |
| 1 | NOCRD | a Request or Snoop came without a credit and was skipped |
| 2 | OVF | a Response found no room in the receive buffer and was skipped |
| 3 | TX_DONE | TX beat accepted by the core |
| 4 | TX_OVF | write to TX while full (dropped) |
| 5 | RX_AVAIL | RX captured a beat |

### FLAGS

| Bit | Name | Meaning |
|---|---|---|
| 0 | TX_FULL | TX holds a beat the core has not taken |
| 1 | RX_AVAIL | RX holds an unread beat |

### Streams

* **TX** feeds `tx_data`/`tx_valid`. Writing TX commits the beat: FLAGS.TX_FULL is set and `tx_valid` stays high until the core's `tx_ready`; then TX_DONE is set. A write while full is dropped and sets TX_OVF.
* **RX** takes `rx_data`, `rx_last` from the core with `rx_valid` / `rx_ready`: `rx_ready` is high while the register is empty (or is being read in the same clock), and a captured beat sets FLAGS/IRQ RX_AVAIL. Reading RX1 pops it. Nothing is dropped: the core holds its data until the register is free.

### Programming sequence

1. Release PRESETN. Read ID (0x000) and check it is 0x43430200.
2. Write 0x3F to IRQ_STATUS (0x004) to clear any stale bits.
3. Configure the core: write ID_CFG (0x014). Reset values are in the register map; PSTRB selects the bytes written.
4. Write IRQ_ENABLE (0x008) with the interrupts to use (bit order as in the Interrupts table; 0x3F enables all).
5. To send on TX: wait until FLAGS.TX_FULL (bit 0) is 0, or for IRQ TX_DONE, then write TX (0x018). The last write commits the beat. TX_OVF means a write came while the register was full and was dropped.
6. To receive on RX: wait for IRQ RX_AVAIL or FLAGS.RX_AVAIL (bit 1), then read RX0 (0x01C) then RX1 (0x020). Reading the last word frees the register for the next beat; write 1 to IRQ_STATUS.RX_AVAIL (bit 5) to clear it.
7. Read STATUS (0x024) for the core's live `tx_crd_req`, `tx_crd_snp`; it needs no clearing.
8. On `irq`: read IRQ_STATUS, handle every bit that is set and enabled, then write those bits back to IRQ_STATUS to clear them. A source that is still active sets its bit again.
<!-- /AUTO:registers -->

## 3. Timing

### 3.1 Messages

A message is 1..8 32-bit words. Header word:

| Bits | Field | Meaning |
|---|---|---|
| 31:28 | MsgType | 0 Misc (link layer only, MsgLen 1, returns credits), 1 Request, 2 Snoop, 3 Response; 4..15 illegal |
| 27:24 | MsgLen | words including the header, 1..8 |
| 23:20 | CrdReq | Request credits returned to the receiver of this message |
| 19:16 | CrdSnp | Snoop credits returned |
| 15:0 | - | protocol-layer fields (target / source IDs, opcode), opaque |

Body words are opaque.

### 3.2 Transmit: gathering messages

States IDLE, BODY (body words of a message), GATHER (a message complete, more may join), TLP
(sending).

| State | `tx_ready` | At an edge |
|---|---|---|
| IDLE | not Misc-due and (header bad or its credit held) | Misc due: build a Misc TLP. Else a header taken starts the payload |
| BODY | 1 | each `tx_valid` word is appended; after the last body word -> GATHER |
| GATHER | header bad, or (credit held and `tn` + MsgLen <= `MAXP`) | a header taken is appended; with no word taken this clock -> TLP |
| TLP | 0 | see §3.3 |

* A header is bad if MsgType is 0 or above 3, or MsgLen is 0 or above 8. A bad header is taken
  alone, dropped, and `ev_err` pulses; its body words (if the writer sends them) are treated as
  headers.
* A Request needs a Request credit (`tx_crd_req` > 0) and uses it when taken; a Snoop a Snoop
  credit; a Response none. A header without its credit waits (in IDLE) or closes the TLP
  (in GATHER), as does one that does not fit in `MAXP` words or a clock without `tx_valid`.
* Every header taken leaves with CrdReq / CrdSnp replaced by the credits this end has to return
  (all of them, as counted at the start of the clock), which are then counted as granted again.
* Credits to return: `NREQ` / `NSNP` after reset, plus one each time the protocol layer reads
  the last word of a received Request / Snoop. A counter runs in IDLE while credits are waiting
  (cleared outside IDLE or with none waiting); when it reaches `CRT`, the Misc is due:
  `tx_ready` 0, and at that edge a one-message TLP with the header {0, 1, CrdReq, CrdSnp, 0} is
  built.
* Credits received (§3.5) count up `tx_crd_req` / `tx_crd_snp`; a Request taken counts down in
  the same clock.

### 3.3 Transmit: the TLP

In state TLP, `tlp_tx_valid` = 1 and the words go out one per clock with `tlp_tx_ready`:

| Word | Value |
|---|---|
| DW0 | {Fmt 011, Type 10010 (= 8'h72), 14'b0, Length = payload words} |
| DW1 | {`rid`, Tag, 8'h7F (Vendor_Defined Type 1)} |
| DW2 | {`tgt_rid`, Vendor ID 16'h1E2C} |
| DW3 | 0 |
| DW4.. | the gathered message words in order |

`tlp_tx_last` on the last payload word. After it is taken: IDLE, Tag + 1 (Tag counts TLPs sent
from 0 after reset, wrapping at 256).

### 3.4 Receive: TLP and message checks

One word per clock with `tlp_rx_valid`. The TLP is dropped from the bad word to its last word,
with `ev_err`, if:

* DW0 bits 31:24 are not 8'h72, Length is 0 or above `MAXP` (bits 23:10 are not checked);
* DW1 bits 7:0 are not 8'h7F (Requester ID and Tag are not checked);
* DW2 is not {`rid`, 16'h1E2C}; DW3 is not 0;
* `tlp_rx_last` comes on a header word, or on a payload word that is not word Length, or does
  not come on word Length;
* a message header has MsgType above 3, MsgLen 0 or above 8, MsgLen beyond the payload left, or
  is a Misc with MsgLen not 1.

Messages complete before the bad word are kept; the one in progress is discarded (its words are
written tentatively and committed only when its last word is in).

### 3.5 Receive: credits, room and hand-out

At a well-formed header:

* Request with no Request credit granted and unused (initially `NREQ`): the message is skipped,
  `ev_nocrd`. The same for a Snoop. A Request / Snoop kept uses one granted credit when complete.
* Response: kept only if the free words (committed buffer use, `RXD` minus words not yet read)
  are at least MsgLen + 8 x (Request + Snoop credits granted and unused + credits waiting to be
  returned); else skipped, `ev_ovf`.
* Misc: not stored.

When a message's last word arrives (kept, skipped or Misc), the CrdReq / CrdSnp of its header are
added to `tx_crd_req` / `tx_crd_snp`; if either sum would pass 31, neither is added and `ev_err`
pulses. A kept message is then visible on `rx_*` from the next clock: `rx_valid` while words are
stored, `rx_data` the oldest, `rx_last` on each message's last word. Reading the last word of a
Request / Snoop makes one credit to return (§3.2).

### 3.6 Reset

While `rst_n` is low: transmit IDLE, Tag 0, receive at DW0, buffer empty, held credits 0, credits
to return `NREQ` / `NSNP` (so a Misc returning them goes out `CRT` clocks after reset unless a
message carries them first), all outputs 0 except `tx_ready`.

## 4. Parameters

| Parameter | Default | Legal range | Effect |
|---|---|---|---|
| `MAXP` | 16 | 8..1023 | most payload words in a TLP sent or received |
| `NREQ` | 2 | 1..15 | Request credits this end grants |
| `NSNP` | 2 | 1..15 | Snoop credits this end grants |
| `RXD` | 64 | power of 2, more than 8 x (`NREQ` + `NSNP`) | receive buffer words |
| `CRT` | 16 | 1 or more | idle clocks before a Misc returns waiting credits |

## 5. Errors and corner cases

| Case | Behaviour |
|---|---|
| bad header written on `tx_*` | dropped alone, `ev_err` |
| Request / Snoop written without a credit | waits on `tx_ready` (or closes the TLP being gathered) |
| next message does not fit in `MAXP` | the TLP is sent, the message starts the next one |
| credits waiting with no traffic | Misc after `CRT` idle clocks |
| malformed TLP / message | dropped from the bad word on, `ev_err`; earlier messages kept |
| Request / Snoop received without a granted credit | skipped, `ev_nocrd`; its credit fields still count |
| Response with no room | skipped, `ev_ovf` |
| credit count would pass 31 | neither count added, `ev_err` |
| reset with traffic in flight | everything cleared; credits to return back to `NREQ` / `NSNP` |

## 6. TB check map

Messages are printed by `tb/CCIX_Cache_Coherent_Interconnect_tb.sv` as `ERROR: <message>`.
Assertions `a_*` are in the bound checker `tb/cov/CCIX_Cache_Coherent_Interconnect_sva.sv`, which
computes every output in every clock. A writer sends random Requests, Snoops and Responses of 1..8
words (and bad headers in one phase); a reader takes received messages with random back-pressure.
The TB peer parses every TLP sent, checks its messages in order, counts the credits returned, and
sends TLPs of random messages within its credits, Misc messages, and every TLP and message error,
messages without a credit, Responses with the buffer full and credit overflow; then a reset with
traffic in flight.

| Check (TB message or assertion) | What it requires | Spec |
|---|---|---|
| "message word" | every received word was sent by the peer | §3.4, §3.5 |
| "received" | received words and `rx_last` in order, as sent | §3.5 |
| "TLP DW0" | DW0 Fmt / Type, Length 1..`MAXP` | §3.3 |
| "TLP DW1" | DW1 = {`rid`, Tag counting TLPs, 7Fh} | §3.3 |
| "TLP DW2" | DW2 = {`tgt_rid`, 1E2Ch} | §3.3 |
| "TLP DW3" | DW3 = 0 | §3.3 |
| "Misc" | Misc header {0, 1, credits, 0} | §3.2 |
| "Misc with no credits" | a Misc only when credits wait | §3.2 |
| "message" | headers sent in order, as written apart from the credit fields | §3.2 |
| "body word" | body words sent in order | §3.2 |
| "TLP last" | `tlp_tx_last` on payload word Length | §3.3 |
| "message runs past the TLP" | a message never spans TLPs | §3.2 |
| "credits at start" | after reset, exactly `NREQ` / `NSNP` returned, in one Misc | §3.2, §3.6 |
| "tx credits after the BFM's grant" | credits received are counted | §3.5 |
| "no Response skipped with the buffer full" | the room rule skips Responses | §3.5 |
| "never receiving and sending at once" | traffic both ways (sets up the reset test) | §3.6 |
| "credits after reset" | credits returned again after a reset | §3.6 |
| "tx credits" | counts unchanged by a grant that would pass 31 | §3.5 |
| a_tx | `tx_ready`, `tlp_tx_valid`, TLP words and last exactly as the model | §3.2, §3.3 |
| a_rx | `rx_valid` / `rx_data` / `rx_last` from the model's queue | §3.4, §3.5 |
| a_credits | `tx_crd_req` / `tx_crd_snp` exactly as the model | §3.2, §3.5 |
| a_events | `ev_err` / `ev_nocrd` / `ev_ovf` exactly as the model | §3.4, §3.5 |
| a_reset | in reset: no TLP, no `rx_valid`, 0 credits, no events | §3.6 |
