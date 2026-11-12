<!-- SPDX-License-Identifier: Apache-2.0 -->
# FC: design specification

A Fibre Channel FC-1 / FC-2 port: 8b/10b, ordered sets, class 3 frames and buffer-to-buffer
credit. Not implemented: link initialization (NOS / OLS / LR / LRR), classes other than 3, other
delimiters and primitive signals, loss-of-sync hysteresis (one error drops alignment), ACK /
end-to-end credit, header parsing. Core `FC_top` (`rtl/FC_top.sv`), testbench `tb/FC_tb.sv` (two
ports cross-connected, with an injector), checker `tb/cov/FC_sva.sv`.

Conventions on this page: every flop is clocked on the rising edge of `clk` and reset
asynchronously by `rst_n` low. 8b/10b uses the IEEE 802.3 clause 36 tables with running
disparity, starting at RD-. A transmission word is 4 characters.

## 1. Interface

| Port | Dir | Width | Meaning | Active | Clock | Reset |
|---|---|---|---|---|---|---|
| `clk` | input | 1 | clock; one line bit per clock | rising edge | - | - |
| `rst_n` | input | 1 | asynchronous reset | low | async | - |
| `tx_p` | output | 1 | serial line out, symbol bit a first | - | `clk` | 0 |
| `rx_p` | input | 1 | serial line in (one flop before use) | - | `clk` | - |
| `cfg_credit` | input | 4 | BB_credit of the far end (0 = no check) | - | static | - |
| `tx_valid` | input | 1 | a frame byte is offered | high | `clk` | - |
| `tx_ready` | output | 1 | the byte goes out this clock (one-clock pulse); combinational | high | comb | 0 |
| `tx_data` | input | 8 | frame byte (24-byte header and payload) | - | `clk` | - |
| `tx_last` | input | 1 | last byte of the frame | high | `clk` | - |
| `tx_sofi` | input | 1 | with the first byte: SOFi3 instead of SOFn3 | high | `clk` | - |
| `tx_eoft` | input | 1 | with the last byte: EOFt instead of EOFn | high | `clk` | - |
| `tx_done` | output | 1 | one-clock pulse: EOFn / EOFt is going out | high | `clk` | 0 |
| `tx_underrun` | output | 1 | one-clock pulse: no byte in time, the frame is aborted | high | `clk` | 0 |
| `credit_used` | output | 4 | frames sent less R_RDYs received (saturates 0..15) | - | `clk` | 0 |
| `rx_valid` | output | 1 | one-clock pulse: a received frame byte | high | `clk` | 0 |
| `rx_data` | output | 8 | received byte; holds | - | `clk` | 0 |
| `rx_last` | output | 1 | with `rx_valid`: last byte (CRC excluded); holds | high | `clk` | 0 |
| `rx_stat` | output | 5 | with `rx_last`: {sofi, eoft, abort, len_err, crc_err}; holds | - | `clk` | 0 |
| `rx_frag` | output | 1 | one-clock pulse: a frame of fewer than 5 bytes ended | high | `clk` | 0 |
| `rx_sync` | output | 1 | receive word alignment established | high | `clk` | 0 |
| `err_code` | output | 1 | one-clock pulse: code violation, disparity error or misplaced K | high | `clk` | 0 |
| `err_word` | output | 1 | one-clock pulse: data word or EOF outside a frame | high | `clk` | 0 |

### Internal signals used by the verification

The FSM coverage collector binds `ts`.

| Signal | Width | Meaning |
|---|---|---|
| `ts` | 3 | what the next transmit character is: 0 GAP (IDLE / R_RDY), 1 SOF, 2 DATA, 3 PAD, 4 CRC, 5 FILL (after an underrun), 6 EOF |

## 2. Registers

<!-- AUTO:registers -->
Generated from [`docs/ip/FC.md`](../ip/FC.md) (source: `scripts/apb/specs/FC.json`); do not edit by hand.

`FC_apb` is an APB4 slave (AMBA APB protocol v2.0): zero wait states, 32-bit data, 12-bit byte address, PSTRB byte lanes on every writable register, PSLVERR on an unmapped or misaligned address (reads then return 0, writes are dropped). Writes to read-only registers are ignored without an error. The core runs on PCLK and PRESETN. `irq` is level-high: `|(IRQ_STATUS & IRQ_ENABLE)`.

Pass-through pins: `tx_p`, `rx_p`.

### Register map

| Offset | Name | Access | Reset | Description |
|---|---|---|---|---|
| 0x000 | ID | RO | 0x46430200 | IP identification: code, major and minor version |
| 0x004 | IRQ_STATUS | W1C | 0x00000000 | Sticky interrupt bits, write 1 to clear |
| 0x008 | IRQ_ENABLE | RW | 0x00000000 | Interrupt enables; irq = \|(IRQ_STATUS & IRQ_ENABLE) |
| 0x00C | FLAGS | RO | 0x00000000 | Stream holding-register state |
| 0x010 | SCRATCH | RW | 0x00000000 | Scratch register, no effect on the core |
| 0x014 | CFG | RW | 0x00000000 | Flow control |
| 0x018 | TX | RW | 0x00000000 | Transmit byte (header first; the port adds SOF, fill, CRC and EOF); a frame starts once its first byte is in TX, and each next byte must arrive within a character time (10 PCLK) |
| 0x01C | RX | RO (pop) | 0x00000000 | Received byte (CRC removed); read it within a character time (10 PCLK) |
| 0x020 | STATUS | RO | core | Link and credit |

Unlisted bits read 0 and ignore writes. Reset "core": the register reads the core's outputs directly, so after reset it shows the core's own reset state. WO (pulse) registers read 0. Offsets from 0x024 up to 0xFFC are unmapped (PSLVERR).

### Fields

| Register | Bits | Field | Access | Reset | Description |
|---|---|---|---|---|---|
| ID | 31:16 | CODE | RO | 0x4643 | IP code |
| ID | 15:8 | MAJOR | RO | 0x02 | major version |
| ID | 7:0 | MINOR | RO | 0x00 | minor version |
| IRQ_STATUS | 8:0 | one bit per interrupt | W1C | 0x0 | see Interrupts |
| IRQ_ENABLE | 8:0 | one bit per interrupt | RW | 0x0 | 1 enables the IRQ_STATUS bit onto `irq` |
| FLAGS | 1:0 | one bit per stream flag | RO | 0x0 | see FLAGS |
| SCRATCH | 31:0 | SCRATCH | RW | 0x00000000 | free for software |
| CFG | 3:0 | `cfg_credit` | RW | 0x0 | BB_credit of the far end: frames that may be outstanding (0 = no check) |
| TX | 7:0 | `tx_data` | RW | 0x0 | byte |
| TX | 8 | `tx_last` | RW | 0x0 | last byte of the frame |
| TX | 9 | `tx_sofi` | RW | 0x0 | with the first byte: SOFi3 (else SOFn3) |
| TX | 10 | `tx_eoft` | RW | 0x0 | with the last byte: EOFt (else EOFn) |
| RX | 7:0 | `rx_data` | RO (pop) | 0x0 | byte |
| RX | 8 | `rx_last` | RO (pop) | 0x0 | last byte of the frame |
| RX | 13:9 | `rx_stat` | RO (pop) | 0x0 | with rx_last: {sofi, eoft, abort, len_err, crc_err} |
| STATUS | 0 | `rx_sync` | RO | core | the receiver is word-aligned and has seen three ordered sets |
| STATUS | 4:1 | `credit_used` | RO | core | frames sent and not yet answered by R_RDY |

### Interrupts (IRQ_STATUS, IRQ_ENABLE)

A bit is set while its source is active, stays set until written with 1, and a set in the same clock as the clear wins.

| Bit | Name | Set when |
|---|---|---|
| 0 | TX_SENT | a frame was sent (EOF out) |
| 1 | TX_UNDERRUN | a transmit byte was late: the frame was ended with EOFa |
| 2 | RX_FRAG | a frame of fewer than 5 bytes was received and dropped |
| 3 | ERR_CODE | a code violation, disparity error or misplaced K character (alignment lost) |
| 4 | ERR_WORD | a data word or an EOF outside a frame |
| 5 | TX_DONE | TX beat accepted by the core |
| 6 | TX_OVF | write to TX while full (dropped) |
| 7 | RX_AVAIL | RX captured a beat |
| 8 | RX_OVF | beat dropped, RX was full |

### FLAGS

| Bit | Name | Meaning |
|---|---|---|
| 0 | TX_FULL | TX holds a beat the core has not taken |
| 1 | RX_AVAIL | RX holds an unread beat |

### Streams

* **TX** feeds `tx_data`, `tx_last`, `tx_sofi`, `tx_eoft`/`tx_valid`. Writing TX commits the beat: FLAGS.TX_FULL is set and `tx_valid` stays high until the core's `tx_ready`; then TX_DONE is set. A write while full is dropped and sets TX_OVF.
* **RX** captures `rx_data`, `rx_last`, `rx_stat` when `rx_valid` is high and the register is empty (or is being read in the same clock), and sets FLAGS/IRQ RX_AVAIL. Reading RX pops it. A beat that arrives while the register is full is dropped and sets RX_OVF.

### Programming sequence

1. Release PRESETN. Read ID (0x000) and check it is 0x46430200.
2. Write 0x1FF to IRQ_STATUS (0x004) to clear any stale bits.
3. Configure the core: write CFG (0x014). Reset values are in the register map; PSTRB selects the bytes written.
4. Write IRQ_ENABLE (0x008) with the interrupts to use (bit order as in the Interrupts table; 0x1FF enables all).
5. To send on TX: wait until FLAGS.TX_FULL (bit 0) is 0, or for IRQ TX_DONE, then write TX (0x018). The last write commits the beat. TX_OVF means a write came while the register was full and was dropped.
6. To receive on RX: wait for IRQ RX_AVAIL or FLAGS.RX_AVAIL (bit 1), then read RX (0x01C). Reading the last word frees the register for the next beat; write 1 to IRQ_STATUS.RX_AVAIL (bit 7) to clear it. Read each beat before the next arrives, or it is dropped and RX_OVF is set.
7. Read STATUS (0x020) for the core's live `rx_sync`, `credit_used`; it needs no clearing.
8. On `irq`: read IRQ_STATUS, handle every bit that is set and enabled, then write those bits back to IRQ_STATUS to clear them. A source that is still active sets its bit again.
<!-- /AUTO:registers -->

## 3. Timing

### 3.1 Ordered sets

K28.5 then three data characters:

| Set | Characters 1..3 |
|---|---|
| IDLE | D21.4 D21.5 D21.5 |
| R_RDY | D21.4 D10.2 D10.2 |
| SOFi3 / SOFn3 | D21.5 D22.2 D22.2 / D21.5 D22.1 D22.1 |
| EOFn / EOFt / EOFa | Dx D21.6 D21.6 / Dx D21.3 D21.3 / Dx D21.7 D21.7 |

Dx = D21.4 when the running disparity before the EOF is negative, D21.5 when positive.

### 3.2 Transmitter

The port always sends words. A frame starts at a word boundary when a byte is offered, at least
six IDLE / R_RDY words have passed since the last EOF, and credit allows it (§3.3). It sends SOF
(by `tx_sofi`), the bytes (`tx_ready` pulses as each goes out), zero fill to a word boundary and
to at least 24 bytes, the CRC-32 (complemented, least significant byte first, over bytes and
fill), then EOF (`tx_done` pulses as it starts). If no byte is offered when one is due,
`tx_underrun` pulses, the word is filled with zeros and the frame ends with EOFa (no `tx_done`).
Between frames the port sends R_RDY for each owed one, else IDLE.

### 3.3 Credit

`credit_used` + 1 at each SOF sent, - 1 at each R_RDY received while in sync (not below 0); a
frame starts only while `credit_used` < `cfg_credit` (`cfg_credit` = 0: no check, `credit_used`
saturates at 15). One R_RDY is owed for each frame received (up to 15).

### 3.4 Receiver

`rx_p` passes one flop. The receiver aligns on a K28.5 at any bit offset; after three good
ordered sets `rx_sync` = 1. A code violation, a disparity error, or a K character other than
K28.5 in a word's first position pulses `err_code` and drops alignment (and `rx_sync`, and a frame
in progress).

In sync, SOFi3 / SOFn3 starts a frame. Its data characters are delayed five bytes and delivered
with `rx_valid`, so the last 4 (the CRC) are not delivered. The frame ends at the next ordered set
or a bad character: the last byte has `rx_last` and `rx_stat`:

* crc_err: the CRC residue is wrong;
* len_err: fewer than 28 or more than 2140 bytes, CRC included;
* abort: ended by EOFa, another ordered set, or a bad character;
* eoft: ended by EOFt; sofi: started by SOFi3.

A frame of fewer than 5 bytes pulses `rx_frag` instead. Data words or an EOF outside a frame
pulse `err_word`.

### 3.5 Reset

While `rst_n` is low: not aligned, transmitter in GAP at RD-, counters 0, outputs 0.

## 4. Parameters

None.

## 5. Errors and corner cases

| Case | Behaviour |
|---|---|
| host underrun | EOFa, `tx_underrun` |
| frame under 24 bytes | zero fill to 24 |
| code / disparity error | `err_code`, realign, frame aborted |
| frame without EOF (another ordered set) | abort |
| short / long frame | `len_err` |
| bad CRC | `crc_err` |
| R_RDY not owed | `credit_used` stays at 0 |
| R_RDY before sync | ignored |

## 6. TB check map

Messages are printed by `tb/FC_tb.sv` as `ERROR: <message>`. Assertions `a_*` are in the bound
checker `tb/cov/FC_sva.sv`. Two ports are cross-connected; an injector can take over A's receive
line, and frames of every kind are checked against expected-delivery queues.

| Check (TB message or assertion) | What it requires | Spec |
|---|---|---|
| "port" | delivered frames as sent | §3.2, §3.4 |
| "A not in sync on the injector" | alignment | §3.4 |
| "port A" | A's deliveries | §3.4 |
| "port B" | B's deliveries | §3.4 |
| "no sync after reset" | sync | §3.4 |
| "B delivered nothing after a line error" | recovery after an error | §3.4 |
| "A went past its credit" | credit limit | §3.3 |
| "an R_RDY before sync returned credit" | R_RDY needs sync | §3.3 |
| "credit_used" | credit count | §3.3 |
| "credit_used did not saturate" | saturation | §3.3 |
| "no phase lined up the credit events" | coverage: SOF and R_RDY in one clock | §3.3 |
| a_tx_bit | each line bit as the model | §3.1, §3.2 |
| a_tx_ready | `tx_ready` | §3.2 |
| a_tx_events | `tx_done` / `tx_underrun` | §3.2 |
| a_credit | `credit_used` | §3.3 |
| a_sync | `rx_sync` | §3.4 |
| a_errors | `err_code` / `err_word` | §3.4 |
| a_rx_valid | `rx_valid` / `rx_frag` | §3.4 |
| a_rx_data | `rx_data` / `rx_last` | §3.4 |
| a_rx_stat | `rx_stat` | §3.4 |
| a_reset | reset | §3.5 |
