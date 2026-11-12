# USB3: design specification

Simplified USB 3 SuperSpeed device link and protocol layer. The link is symbol-parallel (one 8-bit symbol per clock on a differential pair, `_n` = complement). It covers LFPS link training and warm reset, data packet header / payload and transaction packet framing with CRC5 / CRC32, and sequence-number retransmission. The function unit is a 64-word bulk buffer (4 blocks of 16 dwords). Core `USB3_top` (`rtl/USB3_top.sv`), testbench `tb/USB3_tb.sv`, checker `tb/cov/USB3_sva.sv`.

## 1. Interface

| Port | Dir | Width | Meaning | Active | Clock | Reset |
|---|---|---|---|---|---|---|
| `clk` | input | 1 | clock; one symbol per clock | rising edge | - | - |
| `rst_n` | input | 1 | asynchronous reset | low | async | - |
| `rx_p` | input | 8 | received symbol | - | `clk` | - |
| `rx_n` | input | 8 | complement of `rx_p`; a symbol is valid only when `rx_n` == ~`rx_p` | - | `clk` | - |
| `tx_p` | output | 8 | transmitted symbol (registered) | - | `clk` | 0x00 |
| `tx_n` | output | 8 | = ~`tx_p` | - | comb | 0xFF |
| `link_up` | output | 1 | U0 reached | high | `clk` | 0 |
| `irq` | output | 1 | sticky protocol-error flag (cleared only by `rst_n`) | high | `clk` | 0 |

### Internal signals used by the verification

| Signal | Width | Meaning |
|---|---|---|
| `await_ack` | 1 | an IN data packet was sent and the host ACK is awaited (ACK watchdog running) |
| `in_active` | 1 | a bulk IN transfer is in progress |

## 2. Registers

<!-- AUTO:registers -->
Generated from [`docs/ip/USB3.md`](../ip/USB3.md) (source: `scripts/apb/specs/USB3.json`); do not edit by hand.

`USB3_apb` is an APB4 slave (AMBA APB protocol v2.0): zero wait states, 32-bit data, 12-bit byte address, PSTRB byte lanes on every writable register, PSLVERR on an unmapped or misaligned address (reads then return 0, writes are dropped). Writes to read-only registers are ignored without an error. The core runs on PCLK and PRESETN. `irq` is level-high: `|(IRQ_STATUS & IRQ_ENABLE)`.

Pass-through pins: `rx_p`, `rx_n`, `tx_p`, `tx_n`, `link_up`.

### Register map

| Offset | Name | Access | Reset | Description |
|---|---|---|---|---|
| 0x000 | ID | RO | 0x55530200 | IP identification: code, major and minor version |
| 0x004 | IRQ_STATUS | W1C | 0x00000000 | Sticky interrupt bits, write 1 to clear |
| 0x008 | IRQ_ENABLE | RW | 0x00000000 | Interrupt enables; irq = \|(IRQ_STATUS & IRQ_ENABLE) |
| 0x00C | FLAGS | RO | 0x00000000 | Stream holding-register state |
| 0x010 | SCRATCH | RW | 0x00000000 | Scratch register, no effect on the core |
| 0x014 | STATUS | RO | core | Link state |

Unlisted bits read 0 and ignore writes. Reset "core": the register reads the core's outputs directly, so after reset it shows the core's own reset state. WO (pulse) registers read 0. Offsets from 0x018 up to 0xFFC are unmapped (PSLVERR).

### Fields

| Register | Bits | Field | Access | Reset | Description |
|---|---|---|---|---|---|
| ID | 31:16 | CODE | RO | 0x5553 | IP code |
| ID | 15:8 | MAJOR | RO | 0x02 | major version |
| ID | 7:0 | MINOR | RO | 0x00 | minor version |
| IRQ_STATUS | 0 | one bit per interrupt | W1C | 0x0 | see Interrupts |
| IRQ_ENABLE | 0 | one bit per interrupt | RW | 0x0 | 1 enables the IRQ_STATUS bit onto `irq` |
| SCRATCH | 31:0 | SCRATCH | RW | 0x00000000 | free for software |
| STATUS | 0 | `link_up` | RO | core | U0 reached (cleared by a warm reset); same as the link_up pin |

### Interrupts (IRQ_STATUS, IRQ_ENABLE)

A bit is set while its source is active, stays set until written with 1, and a set in the same clock as the clear wins.

| Bit | Name | Set when |
|---|---|---|
| 0 | ERR | bad DPP CRC32, bad DPH / TP CRC5, bad END, missing DPP, symbol decode error inside a packet, or an IN transfer given up after four attempts. Sticky in the core until PRESETN, so the bit is set again on every clock |

### Programming sequence

1. Release PRESETN. Read ID (0x000) and check it is 0x55530200.
2. Write 0x1 to IRQ_STATUS (0x004) to clear any stale bits.
3. Write IRQ_ENABLE (0x008) with the interrupts to use (bit order as in the Interrupts table; 0x1 enables all).
4. Read STATUS (0x014) for the core's live `link_up`; it needs no clearing.
5. On `irq`: read IRQ_STATUS, handle every bit that is set and enabled, then write those bits back to IRQ_STATUS to clear them. A source that is still active sets its bit again.
<!-- /AUTO:registers -->

## 3. Timing

### 3.1 Link training

- **Symbols:** idle 0x00, LFPS 0xAA, DPH start 0xBC, TP start 0x4B, DPP start 0x5A, END 0x3C. A received symbol with `rx_n` != ~`rx_p` is invalid. It is never counted as LFPS and never starts a packet.
- **RXDET:** lasts 32 clocks, sending idle.
- **POLL:** the transmitter repeats 16 LFPS symbols then 16 idle symbols. The receiver counts bursts of at least 8 valid LFPS symbols, each ended by a non-LFPS symbol.
- **U0:** once the device has sent 2 bursts and received 2, `link_up` = 1. The transmitter then sends idle between packets.

Only idle and LFPS symbols are sent before U0.

### 3.2 Warm reset

In U0, 32 consecutive valid LFPS symbols while the receiver is between packets drop the link:
- `link_up` = 0 and the link returns to RXDET (then POLL);
- the sequence numbers are cleared, along with any pending response or IN transfer.

The bulk buffer, the block-written flags and `irq` are kept. 0xAA bytes inside a packet do not count.

### 3.3 Packet formats

| Packet | Format |
|---|---|
| DPH | 0xBC, s1 = {0000, type}, s2 = {seq[2:0], blk[1:0], 000}, CRC5 |
| DPP | 0x5A, 64 payload bytes (16 dwords, each LSB first), CRC32 (4 bytes, LSB first, complemented), 0x3C |
| TP | 0x4B, s1 = {0000, type}, s2 = {seq[2:0], retry, blk[1:0], in_req, 0}, CRC5, 0x3C |

- **CRC5:** polynomial x^5 + x^2 + 1 in reflected form, initial value all ones, over {s2, s1} starting with s1 bit 0, complemented, sent as {000, crc}.
- **CRC32:** polynomial 0x04C11DB7 reflected, initial value all ones, LSB first, complemented.
- **DPH types:** DATA = 1.
- **TP types:** ACK 0xA, NRDY 0x5, LBAD 0xB.

### 3.4 OUT (host to device)

The host sends a DPH of type DATA followed by a DPP. Each byte is checked as it arrives. On the DPP END the device acts:

| Condition | TP sent | Other effect |
|---|---|---|
| CRC32 bad | LBAD | `irq`; the host must resend |
| seq = expected | ACK (retry 0) | the 16 dwords are written to block `blk`, the block is marked written, expected + 1 |
| seq = expected - 1 (a duplicate) | ACK with retry = 1 | nothing written |
| other seq | NRDY | `irq`, data dropped |

The TP echoes seq and blk.

Dropped without a TP, with `irq`:
- a DPH with a bad CRC5;
- a missing DPP start;
- a missing END;
- an invalid symbol inside a packet.

A DPH of another type is dropped silently.

### 3.5 IN (device to host)

1. **Request:** a host TP of type ACK with in_req = 1 asks for block blk.
   - If the block has been written and no IN is in progress, the device sends a DPH (type DATA, its own seq, blk) and a DPP with the block.
   - Otherwise it answers NRDY.
2. **Wait for ACK:** after the END, the device waits for a host ACK TP (in_req = 0) with seq = its seq.
   - That ACK completes the transfer, and the device seq + 1.
   - LBAD, or 256 clocks without an ACK, resends the packet.
   - A host NRDY is ignored, so the watchdog resends.
3. **Give up:** after the fourth failed attempt the device gives up (`irq`).

### 3.6 Transmit priority and irq

Between packets the transmitter picks, in order: a response TP, a new IN packet, an IN retransmission.

`irq` is sticky from any error until `rst_n`:
- a framing error;
- a CRC5 error;
- a CRC32 error;
- an out-of-order sequence;
- an invalid symbol in a packet;
- IN retries exhausted.

### 3.7 Reset

`tx_p` = 0x00 (idle), `link_up` = 0, `irq` = 0, the link in RXDET, sequence numbers 0, and no block written.

## 4. Parameters

None.

## 5. Errors and corner cases

- A duplicate OUT packet (host retry after a lost ACK) is ACKed with the retry flag and not rewritten.
- An IN request for a block never written gets NRDY.
- Only one IN transfer can be outstanding; a second request gets NRDY.
- A warm reset abandons an IN transfer; no data is sent for it afterwards.
- The bulk buffer is not cleared by warm reset; a later IN of a written block returns its old data.

## 6. TB check map

| Check (TB message or assertion) | What it requires | Spec |
|---|---|---|
| "timeout waiting for transaction packet" | the device answers each OUT data packet with a TP | §3.4 |
| "TP CRC5" | TP CRC5 correct | §3.3 |
| "TP END" | TP ends with END | §3.3 |
| "TP reserved bits" | TP reserved bits zero | §3.3 |
| "timeout waiting for IN DPH" | the device sends IN data after an IN request | §3.5 |
| "IN DPH type" | IN DPH type DATA | §3.3 |
| "IN DPH seq/blk" | IN DPH sequence number and block | §3.5 |
| "IN DPH CRC5" | IN DPH CRC5 | §3.3 |
| "IN DPP start" | DPP START symbol | §3.3 |
| "IN blk" | IN payload equals the block written | §3.5 |
| "IN CRC32" | IN DPP CRC32 | §3.3 |
| "IN END" | IN DPP ends with END | §3.3 |
| "link training" | U0 is reached | §3.1 |
| "reset state" | reset values | §3.7 |
| "warm reset: link still up" | 32 LFPS symbols drop the link | §3.2 |
| "link up on short bursts" | bursts shorter than 8 symbols do not count | §3.1 |
| "20 LFPS symbols dropped the link" | fewer than 32 LFPS symbols keep the link | §3.2 |
| "AA payload dropped the link" | 0xAA bytes inside a packet are not LFPS | §3.2 |
| "IN DPH before warm reset" | no IN data after a warm reset abandoned the transfer | §3.2 |
| "U0 before the device sent two bursts" | U0 needs two transmitted bursts | §3.1 |
| "reset in U0" | `rst_n` in U0 retrains | §3.7 |
| a_reset_outputs | in reset: idle symbol, no `link_up`, no irq | §3.7 |
| a_tx | `tx_p` equals the reference model every clock | §3 |
| a_tx_n | `tx_n` = ~`tx_p` | §1 |
| a_link_up | `link_up` as the model | §3.1, §3.2 |
| a_irq | `irq` as the model | §3.6 |
| a_training_symbols | before U0 only idle and LFPS symbols are sent | §3.1 |
| a_watchdog_in_transfer | `await_ack` only within an IN transfer | §3.5 |
| a_irq_sticky | `irq` stays set | §3.6 |
