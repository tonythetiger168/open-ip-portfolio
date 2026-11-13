# USB3_2: design specification

USB 3.2-style SuperSpeed link layer for one lane. It covers header packets with sequence numbers, CRC-16 and a CRC-5 link control word; data packet payloads with CRC-32; link commands; header buffer credits; retry; and recovery.

Not included: the LTSSM, LFPS, 8b/10b and 128b/132b, scrambling, SKP / TS ordered sets, power-management link commands, the 3-of-4 framing tolerance, multiple lanes, and hub / delayed / deferred bits. Field layouts follow the USB 3.2 link layer as read by the author and have not been checked against a compliant device.

Core `USB3_2_top` (`rtl/USB3_2_top.sv`), testbench `tb/USB3_2_tb.sv`, checker `tb/cov/USB3_2_sva.sv`.

## 1. Interface

| Port | Dir | Width | Meaning | Active | Clock | Reset |
|---|---|---|---|---|---|---|
| `clk` | input | 1 | clock; one symbol per clock | rising edge | - | - |
| `rst_n` | input | 1 | asynchronous reset | low | async | - |
| `link_up` | input | 1 | U0 from the LTSSM; low stops the layer (buffers and sequence numbers are kept) | high | `clk` | - |
| `recovery` | output | 1 | one-clock pulse: enter Recovery (the LTSSM is expected to drop and raise `link_up`) | high | `clk` | 0 |
| `tx_sym` | output | 8 | transmit symbol (data 00 = logical idle) | - | `clk` | 0x00 |
| `tx_k` | output | 1 | `tx_sym` is a K symbol | high | `clk` | 0 |
| `rx_sym` | input | 8 | receive symbol | - | `clk` | - |
| `rx_k` | input | 1 | `rx_sym` is a K symbol | high | `clk` | - |
| `tx_valid` | input | 1 | packet byte in (12 header bytes, then a DP payload) | high | `clk` | - |
| `tx_ready` | output | 1 | a free replay slot that is not being sent; combinational | high | comb | 1 |
| `tx_data` | input | 8 | packet byte | - | `clk` | - |
| `tx_last` | input | 1 | last byte of the packet | high | `clk` | - |
| `rx_valid` | output | 1 | a received packet is buffered; combinational | high | comb | 0 |
| `rx_ready` | input | 1 | host takes `rx_data` | high | `clk` | - |
| `rx_data` | output | 8 | received packet byte (header, then payload) | - | comb | - |
| `rx_last` | output | 1 | last byte of the packet | high | comb | - |
| `rx_err` | output | 1 | the packet's payload failed (only its 12 header bytes are delivered) | high | comb | - |
| `ll_up` | output | 1 | advertisement done (link layer up) | high | comb | 0 |
| `ev_hp_bad` | output | 1 | one-clock pulse: header packet failed (CRC-16 / CRC-5 / framing): LBAD sent | high | `clk` | 0 |
| `ev_seq` | output | 1 | one-clock pulse: header packet with an unexpected sequence number | high | `clk` | 0 |
| `ev_lc_bad` | output | 1 | one-clock pulse: link command with both copies bad | high | `clk` | 0 |
| `ev_dpp_bad` | output | 1 | one-clock pulse: payload failed | high | `clk` | 0 |
| `ev_frame` | output | 1 | one-clock pulse: framing error | high | `clk` | 0 |
| `ev_proto` | output | 1 | one-clock pulse: link command out of order, with nothing to cover, or unknown | high | `clk` | 0 |
| `ev_overflow` | output | 1 | one-clock pulse: header packet without a free buffer (dropped, not acknowledged) | high | `clk` | 0 |
| `ev_lbad` | output | 1 | one-clock pulse: LBAD received: retry | high | `clk` | 0 |
| `ev_timeout` | output | 1 | one-clock pulse: PENDING_HP_TIMER or CREDIT_HP_TIMER expired | high | `clk` | 0 |

### Internal signals used by the verification

The checker uses ports only. The FSM coverage binds these state registers.

| Signal | Width | Meaning |
|---|---|---|
| `ll` | 2 | link-layer state (FSM coverage): 0 DOWN, 1 ADV (advertising), 2 UP, 3 REC (recovery requested) |
| `tst` | 2 | transmit state (FSM coverage): 0 IDLE, 1 LC, 2 HP, 3 DPP |
| `rst` | 3 | receive state (FSM coverage): 0 IDLE, 1 OS (framing set), 2 HP, 3 DPP, 4 DE (payload end), 5 LC |

## 2. Registers

<!-- AUTO:registers -->
Generated from [`docs/ip/USB3_2.md`](../ip/USB3_2.md) (source: `scripts/apb/specs/USB3_2.json`); do not edit by hand.

`USB3_2_apb` is an APB4 slave (AMBA APB protocol v2.0): zero wait states, 32-bit data, 12-bit byte address, PSTRB byte lanes on every writable register, PSLVERR on an unmapped or misaligned address (reads then return 0, writes are dropped). Writes to read-only registers are ignored without an error. The core runs on PCLK and PRESETN. `irq` is level-high: `|(IRQ_STATUS & IRQ_ENABLE)`.

Pass-through pins: `tx_sym`, `tx_k`, `rx_sym`, `rx_k`.

### Register map

| Offset | Name | Access | Reset | Description |
|---|---|---|---|---|
| 0x000 | ID | RO | 0x55330200 | IP identification: code, major and minor version |
| 0x004 | IRQ_STATUS | W1C | 0x00000000 | Sticky interrupt bits, write 1 to clear |
| 0x008 | IRQ_ENABLE | RW | 0x00000000 | Interrupt enables; irq = \|(IRQ_STATUS & IRQ_ENABLE) |
| 0x00C | FLAGS | RO | 0x00000000 | Stream holding-register state |
| 0x010 | SCRATCH | RW | 0x00000000 | Scratch register, no effect on the core |
| 0x014 | CTRL | RW | 0x00000000 | Link control |
| 0x018 | TX | RW | 0x00000000 | Packet byte to send; one write per byte, LAST on the final byte. Bytes 0-11 are the header (byte 0 bits 4:0 = 01000 makes it a data packet, whose bytes 12 on are its payload); a packet is cut after 12 + MAXD = 44 bytes. The core takes bytes while one of its TXN = 4 retry buffers is free, link up or not |
| 0x01C | RX | RO (pop) | 0x00000000 | Received packet byte (head of the core's receive buffers); reading it pops it. Headers are delivered as 12 bytes, a data packet's payload after its header; a data packet whose payload failed is delivered as its header with ERR set. A credit is returned as each packet is read |
| 0x020 | STATUS | RO | core | Link state |

Unlisted bits read 0 and ignore writes. Reset "core": the register reads the core's outputs directly, so after reset it shows the core's own reset state. WO (pulse) registers read 0. Offsets from 0x024 up to 0xFFC are unmapped (PSLVERR).

### Fields

| Register | Bits | Field | Access | Reset | Description |
|---|---|---|---|---|---|
| ID | 31:16 | CODE | RO | 0x5533 | IP code |
| ID | 15:8 | MAJOR | RO | 0x02 | major version |
| ID | 7:0 | MINOR | RO | 0x00 | minor version |
| IRQ_STATUS | 12:0 | one bit per interrupt | W1C | 0x0 | see Interrupts |
| IRQ_ENABLE | 12:0 | one bit per interrupt | RW | 0x0 | 1 enables the IRQ_STATUS bit onto `irq` |
| FLAGS | 1:0 | one bit per stream flag | RO | 0x0 | see FLAGS |
| SCRATCH | 31:0 | SCRATCH | RW | 0x00000000 | free for software |
| CTRL | 0 | `link_up` | RW | 0x0 | physical link up (U0): starts the advertisement; clearing it drops the link (receive state and credits reset; unacknowledged packets are kept and sent again) |
| TX | 7:0 | `tx_data` | RW | 0x0 | byte |
| TX | 8 | `tx_last` | RW | 0x0 | last byte of the packet |
| RX | 7:0 | `rx_data` | RO (pop) | 0x0 | byte |
| RX | 8 | `rx_last` | RO (pop) | 0x0 | last byte of the packet |
| RX | 9 | `rx_err` | RO (pop) | 0x0 | the packet's payload failed (bad CRC-32, aborted with EDB, framing, too long): only its header is delivered |
| STATUS | 0 | `ll_up` | RO | core | link layer up (advertisement received) |

### Interrupts (IRQ_STATUS, IRQ_ENABLE)

A bit is set while its source is active, stays set until written with 1, and a set in the same clock as the clear wins.

| Bit | Name | Set when |
|---|---|---|
| 0 | RECOVERY | the link needs recovery (sequence error, protocol error, a third LBAD in a row, or a timer expired): the core stops until CTRL.LINK_UP is cleared and set again |
| 1 | ERR_HP | a header packet failed (CRC-16, link control word CRC-5, or a K symbol inside): an LBAD is sent and headers are ignored until LRTY |
| 2 | ERR_SEQ | a header packet with the wrong sequence number |
| 3 | ERR_LC | a link command with both copies failing their CRC-5 |
| 4 | ERR_DPP | a data packet payload failed (CRC-32, EDB, framing, too long) |
| 5 | ERR_FRAME | a framing error (K symbol out of place, broken ordered set) |
| 6 | ERR_PROTO | a link command out of place: an LGOOD out of order, an LCRD with the wrong letter or too many, an LBAD with nothing sent |
| 7 | ERR_OVERFLOW | a good header packet with no free receive buffer: dropped, not acknowledged |
| 8 | LBAD | an LBAD was received: unacknowledged packets are sent again |
| 9 | TIMEOUT | PENDING_HP_TIMER or CREDIT_HP_TIMER expired |
| 10 | TX_DONE | TX beat accepted by the core |
| 11 | TX_OVF | write to TX while full (dropped) |
| 12 | RX_AVAIL | RX captured a beat |

### FLAGS

| Bit | Name | Meaning |
|---|---|---|
| 0 | TX_FULL | TX holds a beat the core has not taken |
| 1 | RX_AVAIL | RX holds an unread beat |

### Streams

* **TX** feeds `tx_data`, `tx_last`/`tx_valid`. Writing TX commits the beat: FLAGS.TX_FULL is set and `tx_valid` stays high until the core's `tx_ready`; then TX_DONE is set. A write while full is dropped and sets TX_OVF.
* **RX** takes `rx_data`, `rx_last`, `rx_err` from the core with `rx_valid` / `rx_ready`: `rx_ready` is high while the register is empty (or is being read in the same clock), and a captured beat sets FLAGS/IRQ RX_AVAIL. Reading RX pops it. Nothing is dropped: the core holds its data until the register is free.

### Programming sequence

1. Release PRESETN. Read ID (0x000) and check it is 0x55330200.
2. Write 0x1FFF to IRQ_STATUS (0x004) to clear any stale bits.
3. Configure the core: write CTRL (0x014). Reset values are in the register map; PSTRB selects the bytes written.
4. Write IRQ_ENABLE (0x008) with the interrupts to use (bit order as in the Interrupts table; 0x1FFF enables all).
5. To send on TX: wait until FLAGS.TX_FULL (bit 0) is 0, or for IRQ TX_DONE, then write TX (0x018). The last write commits the beat. TX_OVF means a write came while the register was full and was dropped.
6. To receive on RX: wait for IRQ RX_AVAIL or FLAGS.RX_AVAIL (bit 1), then read RX (0x01C). Reading the last word frees the register for the next beat; write 1 to IRQ_STATUS.RX_AVAIL (bit 12) to clear it.
7. Read STATUS (0x020) for the core's live `ll_up`; it needs no clearing.
8. On `irq`: read IRQ_STATUS, handle every bit that is set and enabled, then write those bits back to IRQ_STATUS to clear them. A source that is still active sets its bit again.
<!-- /AUTO:registers -->

## 3. Timing

One symbol per clock. Multi-byte fields are sent most significant byte first. K symbols: SHP FB, SDP 5C, END FD, EDB 7C, SLC DC, EPF F7.

### 3.1 Packet formats

| Packet | Format |
|---|---|
| Header packet (HP) | SHP SHP SHP EPF, 12 header bytes, CRC-16 of them, link control word |
| Data packet payload (DPP) | SDP SDP SDP EPF, 0..MAXD bytes, CRC-32, END END END EPF (EDB EDB EDB EPF aborts it) |
| Link command (LC) | SLC SLC SLC EPF, then the link command word twice |

- **Link control word** (in an HP): {CRC-5, 8'h00, seq[2:0]}.
- **CRC-16:** polynomial 100B, initial value all ones, bit 7 first, sent inverted.
- **CRC-5:** x^5 + x^2 + 1, initial value all ones, bit 10 first, inverted; it covers bits 10:0.
- **Data packet:** a header packet with type (header byte 0 bits 4:0) 01000 (DP) is followed at once by its DPP.
- **CRC-32:** polynomial 04C11DB7, initial value all ones, bit 7 first, sent inverted.
- **Link command word:** {CRC-5, info[10:0]}.

  | Command | info |
  |---|---|
  | LGOOD_n | 000_0000_0nnn |
  | LCRD_x | 000_1000_00xx |
  | LRTY | 001_0000_0000 |
  | LBAD | 001_1000_0000 |

  The first copy with a good CRC-5 is used. If both copies are bad, `ev_lc_bad` pulses.

Between packets the transmitter sends data 00. Link commands go out before header packets, in the order: the advertisement LGOOD, LRTY, LBAD, a pending LGOOD, LCRD.

### 3.2 Link up and advertisement

1. **DOWN to ADV:** when `link_up` rises, the layer sends LGOOD_n for the last header packet it received (n = expected - 1). It then sends LCRD_A, LCRD_B, ... for each free receive buffer. The credit letters restart at A on both sides.
2. **ADV to UP:** the partner's LGOOD advertisement moves the layer to UP (`ll_up` = 1).
   - Header packets that advertisement acknowledges are released.
   - The rest are sent again.

`link_up` low returns to DOWN and stops transmitting. Every buffer and sequence number is kept. A payload being received at that moment is stored as failed (`rx_err`).

### 3.3 Transmit

- **Writing:** packets are written through `tx_*`, up to TXN unacknowledged.
  - 12 header bytes; fewer are padded with zeros.
  - For a DP, the payload follows, cut after MAXD bytes. Bytes after the header of any other packet are dropped.
- **Sending:** a header packet goes out in UP when a credit is available. A packet re-sent in a retry does not take a new credit.
- **Release:** the packet stays in the replay buffer until the LGOOD with its sequence number arrives.
- **LBAD:** `ev_lbad`, then LRTY is sent, then every unacknowledged packet from the oldest. A third LBAD in a row requests recovery.

### 3.4 Receive

- **Good header packet:** one with the expected sequence number is stored in one of RXN buffers and acknowledged with LGOOD_n.
- **Failed header packet:** a bad CRC-16 / CRC-5 or a framing error sends LBAD (`ev_hp_bad`). Header packets are then ignored until LRTY arrives.
- **DP payload:** stored with its header. The payload fails, and the packet is delivered as 12 header bytes with `rx_err` = 1 (`ev_dpp_bad`), when it:
  - has a bad CRC-32;
  - is longer than MAXD;
  - is aborted;
  - is cut by a framing error;
  - is missing (another packet came first).

  Payloads are not retried by the link layer.
- **Delivery:** packets are handed out through `rx_*`. When the last byte is read the buffer is free, and LCRD_x is sent for it.
- **No free buffer:** a header packet arriving with no free buffer is dropped and not acknowledged (`ev_overflow`).

### 3.5 Recovery

The layer pulses `recovery` once, moves to REC and stops sending, until `link_up` drops. Causes:
- no advertisement or LGOOD for PEND_TO clocks (PENDING_HP_TIMER, `ev_timeout`);
- no credit for CRED_TO clocks while a header packet waits for one (CREDIT_HP_TIMER, `ev_timeout`);
- an LGOOD, LCRD or LBAD out of order or with nothing to cover (`ev_proto`);
- a header packet with an unexpected sequence number (`ev_seq`);
- the third LBAD in a row.

### 3.6 Reset

`tx_sym` = 00, `tx_k` = 0, state DOWN, `ll_up` = 0, no packet buffered, sequence numbers 0, no event.

## 4. Parameters

| Parameter | Default | Legal range | Effect |
|---|---|---|---|
| `MAXD` | 32 | >= 1 | payload bytes in a data packet |
| `TXN` | 4 | power of 2, <= 4 | unacknowledged header packets (replay buffer) |
| `RXN` | 4 | power of 2, <= 4 | receive header buffers (credits advertised) |
| `PEND_TO` | 400 | >= 1 | PENDING_HP_TIMER, clocks |
| `CRED_TO` | 2000 | >= 1 | CREDIT_HP_TIMER, clocks |

## 5. Errors and corner cases

- Sequence numbers are 3 bits; with at most 4 outstanding packets, "ahead" and "behind" are unambiguous.
- A failed payload does not cause a retry. The header is delivered with `rx_err` and the payload is lost.
- Dropping `link_up` keeps all buffers, so a recovered link resends what was not acknowledged.
- A link command with one bad copy is still used (the good copy).

## 6. TB check map

| Check (TB message or assertion) | What it requires | Spec |
|---|---|---|
| "end" | every packet written at one end is delivered once, in order, at the other (header, payload, `rx_err` only for payload faults); link up at the end | §3.3, §3.4 |
| "A sent no link command" | the expected link command is sent | §3.2 |
| "not drained" | everything is delivered despite channel errors | §3.3 |
| "A did not ask for recovery" | a timeout or protocol fault pulses `recovery` | §3.5 |
| a_tx_sym | `{tx_k, tx_sym}` equals the reference model every clock | §3 |
| a_tx_ready | `tx_ready` as the model | §3.3 |
| a_ll_up | `ll_up` = state UP | §3.2 |
| a_rx_valid | `rx_valid` as the model | §3.4 |
| a_rx_byte | `rx_data` / `rx_last` / `rx_err` as the model | §3.4 |
| a_events | `recovery` and every event pulse as the model | §3.5, §5 |
| a_reset | reset values | §3.6 |
