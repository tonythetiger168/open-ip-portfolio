# PCIe: design specification

PCI Express-style data link layer for one lane. It covers TLP framing with sequence numbers and LCRC, Ack / Nak with a replay buffer, the replay timer and Ack latency timer, DLLPs with CRC-16, and flow control for the Posted, Non-Posted and Completion credit types (header and data credits). It also covers ASPM L1 entry and exit. The physical layer is not included: LTSSM, ordered sets, 8b/10b, 128b/130b, scrambling, skip and electrical idle. Also not included: flit mode, more than one lane, virtual channels other than VC0, credit scale factors, PM_Active_State_Nak, PCI-PM DLLPs and data link feature exchange. Field layouts follow PCIe as read by the author and have not been checked against a compliant device. Core `PCIe_top` (`rtl/PCIe_top.sv`), testbench `tb/PCIe_tb.sv`, checker `tb/cov/PCIe_sva.sv`.

## 1. Interface

| Port | Dir | Width | Meaning | Active | Clock | Reset |
|---|---|---|---|---|---|---|
| `clk` | input | 1 | clock; one line symbol per clock | rising edge | - | - |
| `rst_n` | input | 1 | asynchronous reset | low | async | - |
| `link_up` | input | 1 | PHY link up; low resets the whole layer synchronously (§3.6) | high | `clk` | - |
| `tx_sym` | output | 8 | transmit symbol (data 00 = logical idle) | - | `clk` | 0x00 |
| `tx_k` | output | 1 | `tx_sym` is a K symbol: STP FB, SDP 5C, END FD | high | `clk` | 0 |
| `rx_sym` | input | 8 | receive symbol | - | `clk` | - |
| `rx_k` | input | 1 | `rx_sym` is a K symbol (STP, SDP, END, EDB FE) | high | `clk` | - |
| `tlp_valid` | input | 1 | TLP byte to write into the replay buffer | high | `clk` | - |
| `tlp_ready` | output | 1 | `dl_up` && L0 && a free replay slot that is not being sent; combinational | high | comb | 0 |
| `tlp_data` | input | 8 | TLP byte (the first byte is {Fmt, Type}) | - | `clk` | - |
| `tlp_last` | input | 1 | last TLP byte (a TLP is cut after MAXLEN bytes) | high | `clk` | - |
| `rx_valid` | output | 1 | a received TLP is in the receive buffer; combinational | high | comb | 0 |
| `rx_ready` | input | 1 | host takes `rx_data` | high | `clk` | - |
| `rx_data` | output | 8 | received TLP byte, combinational from the buffer | - | comb | - |
| `rx_last` | output | 1 | last byte of the TLP | high | comb | - |
| `pm_req` | input | 1 | request ASPM L1 | high | `clk` | - |
| `aspm_ok` | input | 1 | accept the partner's L1 request | high | `clk` | - |
| `pm_state` | output | 2 | 0 L0, 1 requesting L1, 2 L1 | - | `clk` | 0 |
| `dl_up` | output | 1 | data link active (`dls` = 3) | high | comb | 0 |
| `retrain` | output | 1 | one-clock pulse: the fourth replay without progress | high | `clk` | 0 |
| `ev_tlp_bad` | output | 1 | one-clock pulse: a received TLP with a bad LCRC, EDB or framing error (Nak) | high | `clk` | 0 |
| `ev_tlp_seq` | output | 1 | one-clock pulse: a received sequence number ahead (Nak) | high | `clk` | 0 |
| `ev_tlp_dup` | output | 1 | one-clock pulse: a duplicate TLP dropped (acknowledged at once) | high | `clk` | 0 |
| `ev_tlp_null` | output | 1 | one-clock pulse: a nullified TLP dropped | high | `clk` | 0 |
| `ev_overflow` | output | 1 | one-clock pulse: a TLP over its advertised credits dropped (not acknowledged) | high | `clk` | 0 |
| `ev_dllp_bad` | output | 1 | one-clock pulse: DLLP CRC-16 error | high | `clk` | 0 |
| `ev_dllp_proto` | output | 1 | one-clock pulse: Ack / Nak out of range or with reserved bits set, unknown DLLP type | high | `clk` | 0 |
| `ev_frame` | output | 1 | one-clock pulse: framing error (bad end symbol or length, stray K symbol) | high | `clk` | 0 |
| `ev_nak` | output | 1 | one-clock pulse: a Nak received | high | `clk` | 0 |
| `ev_replay` | output | 1 | one-clock pulse: the replay timer expired | high | `clk` | 0 |

### Internal signals used by the verification

The FSM coverage binds these state registers. The checker uses ports only.

| Signal | Width | Meaning |
|---|---|---|
| `dls` | 2 | data link state (FSM coverage): 0 INACTIVE, 1 FC1, 2 FC2, 3 ACTIVE |
| `tst` | 2 | transmit packet state (FSM coverage): 0 IDLE, 1 DLLP, 2 TLP |
| `rst` | 2 | receive packet state (FSM coverage): 0 IDLE, 1 TLP, 2 DLLP |

## 2. Registers

<!-- AUTO:registers -->
Generated from [`docs/ip/PCIe.md`](../ip/PCIe.md) (source: `scripts/apb/specs/PCIe.json`); do not edit by hand.

`PCIe_apb` is an APB4 slave (AMBA APB protocol v2.0): zero wait states, 32-bit data, 12-bit byte address, PSTRB byte lanes on every writable register, PSLVERR on an unmapped or misaligned address (reads then return 0, writes are dropped). Writes to read-only registers are ignored without an error. The core runs on PCLK and PRESETN. `irq` is level-high: `|(IRQ_STATUS & IRQ_ENABLE)`.

Pass-through pins: `tx_sym`, `tx_k`, `rx_sym`, `rx_k`.

### Register map

| Offset | Name | Access | Reset | Description |
|---|---|---|---|---|
| 0x000 | ID | RO | 0x50430300 | IP identification: code, major and minor version |
| 0x004 | IRQ_STATUS | W1C | 0x00000000 | Sticky interrupt bits, write 1 to clear |
| 0x008 | IRQ_ENABLE | RW | 0x00000000 | Interrupt enables; irq = \|(IRQ_STATUS & IRQ_ENABLE) |
| 0x00C | FLAGS | RO | 0x00000000 | Stream holding-register state |
| 0x010 | SCRATCH | RW | 0x00000000 | Scratch register, no effect on the core |
| 0x014 | CTRL | RW | 0x00000004 | Link control |
| 0x018 | TX | RW | 0x00000000 | TLP byte to send; one write per byte, LAST on the final byte (a TLP is cut after MAXLEN = 32 bytes). The first byte is the TLP header's {Fmt, Type}: it selects the credit type (Posted, Non-Posted, Completion) and whether data credits are used. The core takes bytes in L0 while the link is up and a replay-buffer slot is free |
| 0x01C | RX | RO (pop) | 0x00000000 | Received TLP byte (head of the core's receive buffer); reading it pops it. TLPs are delivered once their LCRC and sequence number check out; header and data credits of the TLP's type are returned (UpdateFC) as its last byte is read |
| 0x020 | STATUS | RO | core | Link state |

Unlisted bits read 0 and ignore writes. Reset "core": the register reads the core's outputs directly, so after reset it shows the core's own reset state. WO (pulse) registers read 0. Offsets from 0x024 up to 0xFFC are unmapped (PSLVERR).

### Fields

| Register | Bits | Field | Access | Reset | Description |
|---|---|---|---|---|---|
| ID | 31:16 | CODE | RO | 0x5043 | IP code |
| ID | 15:8 | MAJOR | RO | 0x03 | major version |
| ID | 7:0 | MINOR | RO | 0x00 | minor version |
| IRQ_STATUS | 13:0 | one bit per interrupt | W1C | 0x0 | see Interrupts |
| IRQ_ENABLE | 13:0 | one bit per interrupt | RW | 0x0 | 1 enables the IRQ_STATUS bit onto `irq` |
| FLAGS | 1:0 | one bit per stream flag | RO | 0x0 | see FLAGS |
| SCRATCH | 31:0 | SCRATCH | RW | 0x00000000 | free for software |
| CTRL | 0 | `link_up` | RW | 0x0 | physical link up: starts flow-control init; clearing it drops the link (buffers and sequence numbers reset) |
| CTRL | 1 | `pm_req` | RW | 0x0 | ASPM: ask for L1 whenever the link is idle (PM_Active_State_Request_L1); a TX write wakes the link |
| CTRL | 2 | `aspm_ok` | RW | 0x1 | ASPM: accept L1 requests from the far side when idle |
| TX | 7:0 | `tlp_data` | RW | 0x0 | byte |
| TX | 8 | `tlp_last` | RW | 0x0 | last byte of the TLP |
| RX | 7:0 | `rx_data` | RO (pop) | 0x0 | byte |
| RX | 8 | `rx_last` | RO (pop) | 0x0 | last byte of the TLP |
| STATUS | 0 | `dl_up` | RO | core | data link up (flow-control init done) |
| STATUS | 2:1 | `pm_state` | RO | core | ASPM state: 0 L0, 1 requesting L1, 2 L1 |

### Interrupts (IRQ_STATUS, IRQ_ENABLE)

A bit is set while its source is active, stays set until written with 1, and a set in the same clock as the clear wins.

| Bit | Name | Set when |
|---|---|---|
| 0 | RETRAIN | the fourth replay without progress: the physical layer should retrain |
| 1 | ERR_TLP | a TLP failed (bad LCRC, bad EDB, framing, sequence number ahead): a Nak is sent |
| 2 | ERR_SEQ | a TLP with a sequence number ahead of the expected one |
| 3 | TLP_DUP | a duplicate TLP (already received): dropped and acknowledged |
| 4 | TLP_NULL | a nullified TLP (EDB with inverted LCRC): dropped silently |
| 5 | ERR_OVERFLOW | a good TLP over the header or data credits advertised for its type: dropped, not acknowledged |
| 6 | ERR_DLLP | a DLLP failed its CRC-16 |
| 7 | ERR_PROTO | a DLLP of unknown type, or an Ack/Nak with reserved bits or a sequence number never sent |
| 8 | ERR_FRAME | a framing error (K symbol out of place, DLLP of the wrong length) |
| 9 | NAK | a Nak was received |
| 10 | REPLAY | the replay timer expired |
| 11 | TX_DONE | TX beat accepted by the core |
| 12 | TX_OVF | write to TX while full (dropped) |
| 13 | RX_AVAIL | RX captured a beat |

### FLAGS

| Bit | Name | Meaning |
|---|---|---|
| 0 | TX_FULL | TX holds a beat the core has not taken |
| 1 | RX_AVAIL | RX holds an unread beat |

### Streams

* **TX** feeds `tlp_data`, `tlp_last`/`tlp_valid`. Writing TX commits the beat: FLAGS.TX_FULL is set and `tlp_valid` stays high until the core's `tlp_ready`; then TX_DONE is set. A write while full is dropped and sets TX_OVF.
* **RX** takes `rx_data`, `rx_last` from the core with `rx_valid` / `rx_ready`: `rx_ready` is high while the register is empty (or is being read in the same clock), and a captured beat sets FLAGS/IRQ RX_AVAIL. Reading RX pops it. Nothing is dropped: the core holds its data until the register is free.

### Programming sequence

1. Release PRESETN. Read ID (0x000) and check it is 0x50430300.
2. Write 0x3FFF to IRQ_STATUS (0x004) to clear any stale bits.
3. Configure the core: write CTRL (0x014). Reset values are in the register map; PSTRB selects the bytes written.
4. Write IRQ_ENABLE (0x008) with the interrupts to use (bit order as in the Interrupts table; 0x3FFF enables all).
5. To send on TX: wait until FLAGS.TX_FULL (bit 0) is 0, or for IRQ TX_DONE, then write TX (0x018). The last write commits the beat. TX_OVF means a write came while the register was full and was dropped.
6. To receive on RX: wait for IRQ RX_AVAIL or FLAGS.RX_AVAIL (bit 1), then read RX (0x01C). Reading the last word frees the register for the next beat; write 1 to IRQ_STATUS.RX_AVAIL (bit 13) to clear it.
7. Read STATUS (0x020) for the core's live `dl_up`, `pm_state`; it needs no clearing.
8. On `irq`: read IRQ_STATUS, handle every bit that is set and enabled, then write those bits back to IRQ_STATUS to clear them. A source that is still active sets its bit again.

IP-specific use:

1. Write CTRL with link_up set (aspm_ok as wanted); poll STATUS until dl_up reads 1.
2. Send: write TX once per byte, LAST on the final byte. Receive: on RX_AVAIL read RX until a byte with LAST.
3. Set pm_req to let the link enter L1 when idle (STATUS pm_state reads 2); a TX write wakes it.
4. On RETRAIN, retrain the physical layer (clear and set link_up).
<!-- /AUTO:registers -->

## 3. Timing

All outputs except `tlp_ready`, `rx_valid`, `rx_data`, `rx_last` and `dl_up` are registered. One symbol is sent and received per clock.

### 3.1 Packets and link start-up

- **TLP:** STP, `{0000, seq[11:8]}`, `seq[7:0]`, 1..MAXLEN TLP bytes, LCRC (4 bytes), END.
  - LCRC = CRC-32 (polynomial 04C11DB7, initial value all ones, bit 7 of each byte first) over the two sequence bytes and the TLP bytes. It is sent inverted, bits 31:24 first.
- **DLLP:** SDP, 4 bytes, CRC-16, END.
  - CRC-16 uses polynomial 100B, initial value all ones, bit 7 first. It is sent inverted, bits 15:8 first.
  - Byte 0 is the type:

    | Type | Code | Bytes 1..3 |
    |---|---|---|
    | Ack | 00 | `{00, 0000, seq}` |
    | Nak | 10 | `{00, 0000, seq}` |
    | InitFC1 P / NP / Cpl | 40 / 50 / 60 | `{00, HdrFC[7:0], 00, DataFC[11:0]}` |
    | InitFC2 P / NP / Cpl | C0 / D0 / E0 | as InitFC1 |
    | UpdateFC P / NP / Cpl | 80 / 90 / A0 | as InitFC1 |
    | PM_Active_State_Request_L1 | 23 | zero |
    | PM_Request_Ack | 24 | zero |

  - The Ack / Nak sequence number is the last good TLP received (next expected - 1).
- **Idle and gaps:** between packets the line carries data 00 (`tx_k` = 0) for at least one symbol, because the transmitter returns to IDLE for a clock after END.
- **Credit type of a TLP**, from its first byte {Fmt[2:0], Type[4:0]}:
  - Completion: Type 0101x.
  - Posted: Type 10xxx, or Type 00000 with Fmt[1].
  - Non-Posted: everything else.

  A TLP uses one header credit. If Fmt[1] is set it also uses ceil(bytes / 16) data credits, counting the whole TLP.
- **Flow-control initialization** (`dls`):
  - `link_up` moves the layer from INACTIVE to FC1.
  - FC1 sends InitFC1 for P, NP and Cpl every FC_GAP clocks, advertising HP / DP, HNP / DNP and HC / DC; 0 means infinite. When an InitFC1 or InitFC2 of every type has been received, the layer moves to FC2 and records the partner's limits (0 = infinite).
  - FC2 sends InitFC2 the same way. An InitFC2, an UpdateFC or a good TLP moves it to ACTIVE (`dl_up` = 1).

### 3.2 Transmit order

When the transmitter is between packets it picks, in this order: Nak, Ack, PM_Request_Ack, InitFC (the lowest owed type), PM request, UpdateFC (P, NP, Cpl), TLP. The packet starts on the next clock edge, and one symbol follows per clock.

- An Ack is sent ACK_LAT clocks after the first unacknowledged good TLP, or at once after a duplicate.
- A Nak is sent once per error, until a good TLP arrives.
- UpdateFC of a type is owed when a TLP of that type is read out, and every UPD_GAP clocks for all types while ACTIVE and in L0.
- A new TLP is sent only with enough credit of its type: limit - (consumed + needed) mod 2^n below 2^(n-1), or an infinite limit. A replayed TLP needs no credit check.

### 3.3 Transmit buffer and replay

- **Writing:** TLP bytes are written with `tlp_valid && tlp_ready`. `tlp_ready` needs `dl_up`, L0 and fewer than TXN unacknowledged TLPs, and the slot being written must not be the one on the line. Each TLP gets the next sequence number (from 0) and stays in the buffer until acknowledged.
- **Ack or Nak:** an Ack or Nak with a sequence number between the last acknowledged TLP and the last sent one frees the TLPs up to it. A Nak then replays from the oldest unacknowledged TLP, unless that Nak acknowledged everything sent.
- **Replay timer:** after REPLAY_TO clocks with sent, unacknowledged TLPs and no progress, the layer replays (`ev_replay`). Progress means a new Ack sequence.
- **Retrain:** the fourth replay without progress pulses `retrain`.

### 3.4 Receive

- **Checks at the end symbol:** a TLP is judged at its END or EDB, in this order:
  1. Length or framing (at least 7 symbols, at most MAXLEN TLP bytes, END or EDB): failing gives `ev_frame` plus `ev_tlp_bad`.
  2. EDB with a non-inverted LCRC: nullified, dropped silently (`ev_tlp_null`).
  3. EDB otherwise, or a bad LCRC: `ev_tlp_bad` and a Nak.
  4. A sequence number ahead: `ev_tlp_seq` and a Nak.
  5. A duplicate: `ev_tlp_dup` and an immediate Ack.
  6. No room within the advertised credits of its type: `ev_overflow`, dropped and not acknowledged.
  7. Otherwise the TLP is good. It is stored, the Ack is scheduled and the next sequence number is expected.
- **Reading out:** `rx_valid` is high while a whole good TLP is in the buffer. `rx_data` / `rx_last` show its bytes, and each `rx_ready` takes one. The last byte frees the TLP's credits and makes an UpdateFC of its type owed.
- **DLLPs:** a DLLP must be exactly 4 + 2 bytes then END, otherwise `ev_frame`; a CRC error gives `ev_dllp_bad`. An Ack / Nak out of range or with reserved bits set, or an unknown type, gives `ev_dllp_proto`. UpdateFC sets the finite limits.

### 3.5 ASPM L1 (`pm_state`)

| Step | Condition | Action |
|---|---|---|
| L0 to 1 | `pm_req`, `dl_up`, nothing unacknowledged, being written or owed (Ack / Nak), and no `tlp_valid` | stop taking TLPs and send PM_Active_State_Request_L1 every FC_GAP clocks |
| 1 to L1 | PM_Request_Ack received with `pm_req`, nothing owed (including UpdateFC) and no `tlp_valid` | enter L1 |
| 1, ack ignored | PM_Request_Ack received but something is owed | the request repeats |
| 1 to L0 | `pm_req` low or `tlp_valid` | back to L0 |
| Partner request accepted | `aspm_ok` and the same quiet conditions | answer PM_Request_Ack and enter L1 |
| Partner request refused | otherwise | ignore it |
| Request received in L1 | | answer PM_Request_Ack again |
| L1 to L0 | `tlp_valid`, a TLP read out, or any received packet other than a PM DLLP | back to L0 |

In L1 only PM_Request_Ack is sent. Credits read out during state 1 are still returned.

### 3.6 Reset and link down

Reset, and every clock with `link_up` = 0, return the layer to its initial state:

- `dls` INACTIVE, L0, and the line idle (00).
- Both buffers empty and sequence numbers 0.
- Credits back to the advertised values and partner limits 0.
- No packet owed.

A reset also clears every event output. `dl_up` = `tlp_ready` = `rx_valid` = 0.

## 4. Parameters

| Parameter | Default | Legal range | Effect |
|---|---|---|---|
| `MAXLEN` | 32 | >= 1 | most bytes in a TLP; longer written TLPs are cut, longer received TLPs are framing errors |
| `TXN` | 4 | power of 2, at least 2 | unacknowledged TLPs in the replay buffer |
| `RXN` | 4 | power of 2, at least HP + HNP + HC | TLPs in the receive buffer (RXN * MAXLEN bytes must hold DP + DNP + DC credits of 16 bytes) |
| `REPLAY_TO` | 600 | >= 1 | replay timer, clocks |
| `ACK_LAT` | 16 | >= 1 | Ack latency, clocks |
| `FC_GAP` | 32 | >= 1 | InitFC and PM request repeat interval, clocks |
| `UPD_GAP` | 1024 | >= FC_GAP | UpdateFC repeat interval, clocks |
| `HP` | 2 | 0..255 (0 = infinite) | Posted header credits advertised |
| `HNP` | 1 | 0..255 | Non-Posted header credits advertised |
| `HC` | 1 | 0..255 | Completion header credits advertised |
| `DP` | 4 | 0..4095 (0 = infinite) | Posted data credits (16 bytes each) |
| `DNP` | 2 | 0..4095 | Non-Posted data credits |
| `DC` | 2 | 0..4095 | Completion data credits |

## 5. Errors and corner cases

- A TLP written with more than MAXLEN bytes is cut after MAXLEN. The rest of its bytes start a new TLP.
- The sequence-number checks of §3.4 work modulo 4096, using the "ahead" relation of PCIe.
- An Ack / Nak received before `dl_up` is ignored.
- A K symbol other than STP / SDP between packets, a data byte at the 7th DLLP position, and a short TLP each pulse `ev_frame`.
- Only one Nak is sent until a good TLP arrives (`nak_s`). Later bad TLPs only pulse their events.
- An overflowing TLP is not acknowledged. The partner replays it once the credits it needs have been returned.
- A received TLP that does not fit the byte buffer is still judged by its credits. RXN and MAXLEN must be large enough for the advertised credits (§4).
- Dropping `link_up` loses every buffered TLP, in both directions.

## 6. TB check map

| Check (TB message or assertion) | What it requires | Spec |
|---|---|---|
| "end" | each received byte (and `rx_last`) at either end equals the next byte written at the other end; link up and `pm_state` at the end of a test | §3.3, §3.4 |
| "A sent no DLLP" | the core sends the expected DLLP type | §3.2 |
| "InitFC1" | InitFC1 advertises HP / DP, HNP / DNP, HC / DC | §3.1 |
| "not drained" | every written TLP is delivered once, in order, despite channel errors (replay) | §3.3 |
| "refused L1 request" | with `aspm_ok` low the partner's request is ignored and the requester stays in state 1 | §3.5 |
| "L1 left on a request" | L1 is kept when a PM request is received in L1 | §3.5 |
| "L1 entered with an Ack owed" | no L1 while an Ack, Nak or UpdateFC is owed | §3.5 |
| "L1 entered with aspm_ok low" | no L1 on a request with `aspm_ok` low | §3.5 |
| a_tx_sym | `{tx_k, tx_sym}` equals the reference model's symbol on every clock (packet choice, order, CRCs) | §3.2 |
| a_tlp_ready | `tlp_ready` as the model | §3.3 |
| a_dl_up | `dl_up` as the model's link state | §3.1 |
| a_pm_state | `pm_state` as the model | §3.5 |
| a_rx_valid | `rx_valid` as the model | §3.4 |
| a_rx_byte | `rx_data` / `rx_last` as the model while valid | §3.4 |
| a_events | every event pulse and `retrain` as the model | §5 |
| a_reset | reset values | §3.6 |
