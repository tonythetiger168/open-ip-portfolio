<!-- SPDX-License-Identifier: Apache-2.0 -->
# Interlaken_v1_2: design specification

One Interlaken-style lane, both directions: 64b/67b framing with running-disparity inversion,
the x^58 + x^39 + 1 scrambler, metaframes (sync, scrambler state, skip and diagnostic words with
CRC-32C), bursts with CRC-24 and in-band flow control, and the receive word lock and metaframe
lock. Not implemented: lane striping, the calendar, BurstShort / BurstMin, skip words other than
third, retransmit. Field layouts follow Interlaken 1.2 as read by the author and are not checked
against a compliant device. Core `Interlaken_v1_2_top` (`rtl/Interlaken_v1_2_top.sv`), testbench
`tb/Interlaken_v1_2_tb.sv` (two ends cross-connected through a channel that delays, slides and
flips bits), checker `tb/cov/Interlaken_v1_2_sva.sv`.

Conventions on this page: every flop is clocked on the rising edge of `clk` and reset
asynchronously by `rst_n` low. Bit numbers of a 67-bit word: 66 inversion flag, 65:64 framing,
63:0 payload. "Control word" means framing 10, "data word" framing 01.

## 1. Interface

| Port | Dir | Width | Meaning | Active | Clock | Reset |
|---|---|---|---|---|---|---|
| `clk` | input | 1 | clock; one line bit per clock, a 67-bit word every 67 clocks | rising edge | - | - |
| `rst_n` | input | 1 | asynchronous reset | low | async | - |
| `tx_p` | output | 1 | serial line out, bit 66 of each word first (section 3.1) | - | `clk` | 0 |
| `rx_p` | input | 1 | serial line in, any bit alignment | - | `clk` | - |
| `tx_valid` | input | 1 | a data word is offered; hold until `tx_ready` | high | `clk` | - |
| `tx_ready` | output | 1 | the offered word is taken in this clock; combinational (section 3.3) | high | comb | 0 |
| `tx_data` | input | 64 | data word | - | `clk` | - |
| `tx_sop` | input | 1 | the offered word starts a packet | high | `clk` | - |
| `tx_eop` | input | 1 | the offered word ends a packet | high | `clk` | - |
| `tx_bytes` | input | 3 | valid bytes in an EOP word, 0 = 8 | - | `clk` | - |
| `tx_chan` | input | 8 | channel of the packet, taken by the burst control word | - | `clk` | - |
| `tx_fc` | input | 16 | flow-control field sent in every control word | - | `clk` | - |
| `rx_valid` | output | 1 | one-clock strobe: a received data word on `rx_*` | high | `clk` | 0 |
| `rx_data` | output | 64 | received data word | - | `clk` | 0 |
| `rx_sop` | output | 1 | the word starts a packet | high | `clk` | 0 |
| `rx_eop` | output | 1 | the word ends a packet (or the lock was lost while it was held) | high | `clk` | 0 |
| `rx_bytes` | output | 3 | valid bytes of an EOP word, 0 = 8; 0 otherwise | - | `clk` | 0 |
| `rx_chan` | output | 8 | channel of the burst that carried the word | - | `clk` | 0 |
| `rx_err` | output | 1 | the word closed a burst whose CRC-24 failed, or was flushed by a lock loss | high | `clk` | 0 |
| `rx_fc` | output | 16 | flow control of the last control word whose CRC-24 passed | - | `clk` | 0 |
| `word_lock` | output | 1 | word alignment found (`ws` == LOCK) | high | `clk` | 0 |
| `sync_lock` | output | 1 | metaframe lock (`ms` == LOCK) | high | `clk` | 0 |
| `peer_status` | output | 2 | {lane, link} status from the peer's last good diagnostic word | - | `clk` | 0 |
| `err_word` | output | 1 | one-clock pulse: invalid framing bits while word-locked | high | `clk` | 0 |
| `err_sync` | output | 1 | one-clock pulse: missing sync word while sync-locked | high | `clk` | 0 |
| `err_scr` | output | 1 | one-clock pulse: scrambler state word mismatch while sync-locked | high | `clk` | 0 |
| `err_crc32` | output | 1 | one-clock pulse: diagnostic word CRC-32C mismatch | high | `clk` | 0 |
| `err_crc24` | output | 1 | one-clock pulse: control word CRC-24 mismatch | high | `clk` | 0 |
| `err_proto` | output | 1 | one-clock pulse: protocol violation (section 5) | high | `clk` | 0 |

### Internal signals used by the verification

The TB reads these from the B end (`u_b`) to aim bit flips at chosen words and bits; fsm_cov
binds `ws` and `ms`. A re-implementation must keep these names and meanings.

| Signal | Width | Meaning |
|---|---|---|
| `ws` | 2 | word-lock FSM: 0 HUNT, 1 TEST, 2 LOCK |
| `ms` | 2 | metaframe FSM: 0 HUNT, 1 TEST, 2 LOCK |
| `rc` | 7 | receive bit counter in the word: 0 inversion bit, 1..2 framing, 3..66 payload; the word completes at 66 |
| `wcnt` | 6 | word index in the 64-word error window while word-locked |
| `rpos` | $clog2(`MF`) | position of the word being received in the metaframe (0 sync, 1 state, 2 skip, `MF`-1 diagnostic) |
| `rf1`, `rf0` | 1 each | framing bits 65 and 64 of the word being received |
| `r_inpkt` | 1 | the receiver is inside a packet |
| `rh_v` | 1 | a received data word is held, waiting for the next protocol word |

## 2. Registers

<!-- AUTO:registers -->
Generated from [`docs/ip/Interlaken_v1_2.md`](../ip/Interlaken_v1_2.md) (source: `scripts/apb/specs/Interlaken_v1_2.json`); do not edit by hand.

`Interlaken_v1_2_apb` is an APB4 slave (AMBA APB protocol v2.0): zero wait states, 32-bit data, 12-bit byte address, PSTRB byte lanes on every writable register, PSLVERR on an unmapped or misaligned address (reads then return 0, writes are dropped). Writes to read-only registers are ignored without an error. The core runs on PCLK and PRESETN. `irq` is level-high: `|(IRQ_STATUS & IRQ_ENABLE)`.

Pass-through pins: `tx_p`, `rx_p`.

### Register map

| Offset | Name | Access | Reset | Description |
|---|---|---|---|---|
| 0x000 | ID | RO | 0x494C0200 | IP identification: code, major and minor version |
| 0x004 | IRQ_STATUS | W1C | 0x00000000 | Sticky interrupt bits, write 1 to clear |
| 0x008 | IRQ_ENABLE | RW | 0x00000000 | Interrupt enables; irq = \|(IRQ_STATUS & IRQ_ENABLE) |
| 0x00C | FLAGS | RO | 0x00000000 | Stream holding-register state |
| 0x010 | SCRATCH | RW | 0x00000000 | Scratch register, no effect on the core |
| 0x014 | FC | RW | 0x00000000 | In-band flow control sent in every control word |
| 0x018 | TX0 | RW | 0x00000000 | Transmit word (TX0 = bits 31:0, TX1 = bits 63:32, TX2 = flags and channel; writing TX2 commits it); a burst control word takes SOP and channel of the word waiting, the word itself goes out next; one word per 67 PCLK |
| 0x01C | TX1 | RW | 0x00000000 | Transmit word (TX0 = bits 31:0, TX1 = bits 63:32, TX2 = flags and channel; writing TX2 commits it); a burst control word takes SOP and channel of the word waiting, the word itself goes out next; one word per 67 PCLK |
| 0x020 | TX2 | RW | 0x00000000 | Transmit word (TX0 = bits 31:0, TX1 = bits 63:32, TX2 = flags and channel; writing TX2 commits it); a burst control word takes SOP and channel of the word waiting, the word itself goes out next; one word per 67 PCLK |
| 0x024 | RX0 | RO (pop) | 0x00000000 | Received word (RX0 = bits 31:0, RX1 = bits 63:32, RX2 = flags; reading RX2 frees it); each data word arrives once the next protocol word shows whether it ends the packet |
| 0x028 | RX1 | RO (pop) | 0x00000000 | Received word (RX0 = bits 31:0, RX1 = bits 63:32, RX2 = flags; reading RX2 frees it); each data word arrives once the next protocol word shows whether it ends the packet |
| 0x02C | RX2 | RO (pop) | 0x00000000 | Received word (RX0 = bits 31:0, RX1 = bits 63:32, RX2 = flags; reading RX2 frees it); each data word arrives once the next protocol word shows whether it ends the packet |
| 0x030 | RX_FC | RO | core | Flow control received |
| 0x034 | STATUS | RO | core | Receive alignment and peer status |

Unlisted bits read 0 and ignore writes. Reset "core": the register reads the core's outputs directly, so after reset it shows the core's own reset state. WO (pulse) registers read 0. Offsets from 0x038 up to 0xFFC are unmapped (PSLVERR).

### Fields

| Register | Bits | Field | Access | Reset | Description |
|---|---|---|---|---|---|
| ID | 31:16 | CODE | RO | 0x494C | IP code |
| ID | 15:8 | MAJOR | RO | 0x02 | major version |
| ID | 7:0 | MINOR | RO | 0x00 | minor version |
| IRQ_STATUS | 9:0 | one bit per interrupt | W1C | 0x0 | see Interrupts |
| IRQ_ENABLE | 9:0 | one bit per interrupt | RW | 0x0 | 1 enables the IRQ_STATUS bit onto `irq` |
| FLAGS | 1:0 | one bit per stream flag | RO | 0x0 | see FLAGS |
| SCRATCH | 31:0 | SCRATCH | RW | 0x00000000 | free for software |
| FC | 15:0 | `tx_fc` | RW | 0x0 | flow control bits |
| TX0 | 31:0 | `tx_data[31:0]` | RW | 0x0 | payload |
| TX1 | 31:0 | `tx_data[63:32]` | RW | 0x0 | payload |
| TX2 | 0 | `tx_sop` | RW | 0x0 | first word of a packet |
| TX2 | 1 | `tx_eop` | RW | 0x0 | last word of a packet |
| TX2 | 4:2 | `tx_bytes` | RW | 0x0 | with EOP: valid bytes of the word (0 = 8) |
| TX2 | 12:5 | `tx_chan` | RW | 0x0 | channel (taken at the burst start) |
| RX0 | 31:0 | `rx_data[31:0]` | RO (pop) | 0x0 | payload |
| RX1 | 31:0 | `rx_data[63:32]` | RO (pop) | 0x0 | payload |
| RX2 | 0 | `rx_sop` | RO (pop) | 0x0 | first word of a packet |
| RX2 | 1 | `rx_eop` | RO (pop) | 0x0 | last word of a packet |
| RX2 | 4:2 | `rx_bytes` | RO (pop) | 0x0 | with EOP: valid bytes (0 = 8) |
| RX2 | 12:5 | `rx_chan` | RO (pop) | 0x0 | channel of its burst |
| RX2 | 13 | `rx_err` | RO (pop) | 0x0 | its burst failed the CRC-24 (or the lane lost sync) |
| RX_FC | 15:0 | `rx_fc` | RO | core | from the last control word that passed its CRC-24 |
| STATUS | 0 | `word_lock` | RO | core | word (framing bit) lock |
| STATUS | 1 | `sync_lock` | RO | core | metaframe lock (words are delivered) |
| STATUS | 3:2 | `peer_status` | RO | core | {lane, link} status from the peer's last good diagnostic word |

### Interrupts (IRQ_STATUS, IRQ_ENABLE)

A bit is set while its source is active, stays set until written with 1, and a set in the same clock as the clear wins.

| Bit | Name | Set when |
|---|---|---|
| 0 | ERR_WORD | invalid framing bits while word locked |
| 1 | ERR_SYNC | a sync word missing while sync locked |
| 2 | ERR_SCR | a scrambler state word that does not match |
| 3 | ERR_CRC32 | a diagnostic word whose CRC-32 does not match the metaframe |
| 4 | ERR_CRC24 | a control word whose CRC-24 fails |
| 5 | ERR_PROTO | a protocol error (data outside a burst, EOP without data, SOP inside a packet, burst without SOP outside one, framing word out of place) |
| 6 | TX_DONE | TX beat accepted by the core |
| 7 | TX_OVF | write to TX while full (dropped) |
| 8 | RX_AVAIL | RX captured a beat |
| 9 | RX_OVF | beat dropped, RX was full |

### FLAGS

| Bit | Name | Meaning |
|---|---|---|
| 0 | TX_FULL | TX holds a beat the core has not taken |
| 1 | RX_AVAIL | RX holds an unread beat |

### Streams

* **TX** feeds `tx_data`, `tx_sop`, `tx_eop`, `tx_bytes`, `tx_chan`/`tx_valid`. Writing TX2 commits the beat: FLAGS.TX_FULL is set and `tx_valid` stays high until the core's `tx_ready`; then TX_DONE is set. A write while full is dropped and sets TX_OVF.
* **RX** captures `rx_data`, `rx_sop`, `rx_eop`, `rx_bytes`, `rx_chan`, `rx_err` when `rx_valid` is high and the register is empty (or is being read in the same clock), and sets FLAGS/IRQ RX_AVAIL. Reading RX2 pops it. A beat that arrives while the register is full is dropped and sets RX_OVF.

### Programming sequence

1. Release PRESETN. Read ID (0x000) and check it is 0x494C0200.
2. Write 0x3FF to IRQ_STATUS (0x004) to clear any stale bits.
3. Configure the core: write FC (0x014). Reset values are in the register map; PSTRB selects the bytes written.
4. Write IRQ_ENABLE (0x008) with the interrupts to use (bit order as in the Interrupts table; 0x3FF enables all).
5. To send on TX: wait until FLAGS.TX_FULL (bit 0) is 0, or for IRQ TX_DONE, then write TX0 (0x018) then TX1 (0x01C) then TX2 (0x020). The last write commits the beat. TX_OVF means a write came while the register was full and was dropped.
6. To receive on RX: wait for IRQ RX_AVAIL or FLAGS.RX_AVAIL (bit 1), then read RX0 (0x024) then RX1 (0x028) then RX2 (0x02C). Reading the last word frees the register for the next beat; write 1 to IRQ_STATUS.RX_AVAIL (bit 8) to clear it. Read each beat before the next arrives, or it is dropped and RX_OVF is set.
7. Read RX_FC (0x030) for the core's live `rx_fc`; it needs no clearing.
8. Read STATUS (0x034) for the core's live `word_lock`, `sync_lock`, `peer_status`; it needs no clearing.
9. On `irq`: read IRQ_STATUS, handle every bit that is set and enabled, then write those bits back to IRQ_STATUS to clear them. A source that is still active sets its bit again.
<!-- /AUTO:registers -->

## 3. Timing

### 3.1 Line, word and disparity

The transmitter has a free-running bit counter `tc` = 0..66. On the clock where `tc` = 0 it builds
the next word and drives bit 66 (the inversion flag) on `tx_p`; on the following 66 clocks it
drives bits 65 down to 0. The first word after reset is the sync word.

Running disparity `rd` (signed, starts at 0): for a word with scrambled payload `p`,
`d` = 2 x ones(`p`) - 65. The payload is inverted (bit 66 = 1, bits 63:0 = ~`p`) when `rd` != 0
and `rd` and `d` have the same sign; then `rd` -= `d`, otherwise `rd` += `d`. The framing bits are
never inverted.

### 3.2 Metaframe

`MF` words, by position `tw`:

| Position | Word (before scrambling) | Framing |
|---|---|---|
| 0 | sync 0x78F678F678F678F6 | 10 |
| 1 | scrambler state {001010, generator state[57:0]} | 10 |
| 2 | skip 0x1E1E1E1E1E1E1E1E | 10 |
| 3 .. `MF`-2 | protocol words (section 3.3) | 01 or 10 |
| `MF`-1 | diagnostic {011001, 24'b0, lane, link, ~CRC-32C} | 10 |

Lane status = this end's `sync_lock`; link = `sync_lock` && `peer_status[1]`, both taken when the
word is built.

Scrambler: generator `g`[57:0], reset to `SEED`. For a scrambled word, 64 steps, payload bit 63
first: `k` = `g`[57] ^ `g`[38]; `g` = {`g`[56:0], `k`}; payload bit ^= `k`. Positions 2 .. `MF`-1
are scrambled and advance the generator; the sync and state words are sent in clear and the
generator holds still for them. The state word carries the state that will scramble the skip word
that follows.

CRC-32C: polynomial 0x1EDC6F41, not reflected, initial value 0xFFFFFFFF at the sync word, fed with
the 66 bits {framing, payload before scrambling} of every word of the metaframe, bit 65 first;
the state word's 58-bit state field and the diagnostic word's CRC field count as zeros. The CRC
field carries the complement of the result.

### 3.3 Transmit protocol words

In a protocol position, a data word is sent when the transmitter is in a burst, the burst's last
word did not end the packet, fewer than `BMAX` data words are in the burst and `tx_valid` is high.
Otherwise a control word is sent:

| Bits | Field |
|---|---|
| 63 | 1 |
| 62 | burst (= `tx_valid` now) or idle (0) |
| 61 | SOP: `tx_sop` of the offered word when burst, else 0 |
| 60 | EOP: the burst being closed ended its packet |
| 59:57 | valid bytes of that last word (`tx_bytes`, 0 = 8), 0 if not EOP |
| 56 | 0 |
| 55:40 | `tx_fc` |
| 39:32 | `tx_chan` when burst, else 0 |
| 31:24 | 0 |
| 23:0 | CRC-24 |

Every control word closes the burst before it; a burst control word opens the next, and the
offered word itself goes out in the next protocol position. CRC-24: polynomial 0x328B63, not
reflected, initial value 0xFFFFFF after each control word, fed with the 64-bit payloads (before
scrambling) of the burst's data words and then this control word with its CRC field zero, bit 63
first. Framing-layer words inside a burst do not interrupt it or the CRC.

`tx_ready` = (`tc` == 0) && (a data word is sent now); it is combinational from `tx_valid`. The
word, `tx_eop` and `tx_bytes` are taken in that clock. A burst ends at the packet's end, at `BMAX`
words, or when `tx_valid` is low in a protocol position. The user keeps `tx_valid` high until
`tx_ready`.

### 3.4 Receive word lock

`rx_p` is registered first. The receiver counts bits `rc` = 0..66: 0 takes the inversion bit,
1 and 2 the framing bits, 3..66 the payload bits (XORed with the inversion bit). At `rc` = 2 the
framing is checked (valid = 01 or 10):

| State | Valid | Invalid |
|---|---|---|
| HUNT | TEST, count 1 | slide by one bit (`rc` stays 2, window moves one bit) |
| TEST | count + 1; the 64th valid in a row: LOCK, window and count cleared | HUNT and slide |
| LOCK | - | pulse `err_word`; the 16th invalid word in the current 64-word window: HUNT |

The window counter `wcnt` runs 0..63 while locked; the invalid count clears at `wcnt` = 63. A
whole-word shift of the line leaves the framing valid, so `word_lock` holds.

### 3.5 Receive metaframe lock

At `rc` = 66 (the word is complete):

- not word-locked, or metaframe HUNT: a sync word (framing 10 and payload = sync) while
  word-locked starts TEST with count 1 at position 1; anything else stays in HUNT.
- TEST: each word at position 0 must be a sync word, else HUNT; the 4th sync word `MF` words
  apart gives LOCK. While testing, the state word loads the descrambler from its 58 state bits.
- LOCK, position 0: no sync word pulses `err_sync`; the 4th in a row drops the lock. Position 1:
  a state word whose framing is not 10 or whose payload is not {001010, descrambler state} pulses
  `err_scr`; the 3rd in a row drops the lock (the descrambler is not reloaded while locked).
  Position `MF`-1: a CRC-32C mismatch (computed as in 3.2 over the received words, descrambled
  where scrambled) pulses `err_crc32`; a match loads `peer_status` with bits 33:32.
- Losing `word_lock` while sync-locked drops the metaframe lock at that word's end.

On losing the lock: HUNT, position 0, burst and packet state cleared; a held data word goes out
with `rx_eop` = 1, `rx_err` = 1, `rx_bytes` = 0.

### 3.6 Receive protocol words

Only with `sync_lock` and `word_lock`, at positions 3 .. `MF`-2, at the end of the word:

- data word: added to the CRC-24. Outside a burst: `err_proto`, dropped. In a burst: the
  previously held word (if any) goes out with `rx_eop` = 0, `rx_err` = 0; this word is held with
  SOP = the burst's SOP if it is the burst's first word, and the burst's channel.
- control word with bit 63 = 0: `err_proto`, otherwise ignored.
- control word: CRC-24 checked; fail pulses `err_crc24`, pass loads `rx_fc` with bits 55:40. A held
  word goes out with `rx_eop` = bit 60, `rx_bytes` = bits 59:57 if EOP else 0, `rx_err` = CRC-24
  failed; with no held word, EOP set pulses `err_proto`. A burst control word opens a burst
  (SOP = bit 61, channel = bits 39:32); a SOP inside a packet or no SOP outside a packet pulses
  `err_proto` but the burst still opens. The packet stays open after an idle control word unless
  it carried EOP.
- framing 00 or 11: no protocol action (only `err_word`).

Only the word held at the control word carries `rx_err` for a failed burst CRC; earlier words of
the same burst already went out clean. Fields of a control word that fails CRC-24 (EOP, SOP,
channel) are still used.

### 3.7 Receive outputs

`rx_valid` and the error pulses are registered one-clock pulses, at the clock where `rc` = 66
(`err_word`: where `rc` = 2). `rx_fc` and `peer_status` hold their last value.

### 3.8 Reset

`tx_p` = 0, both lock FSMs in HUNT, all strobes and error pulses 0, `rx_fc` = 0, `peer_status` = 0,
generators at `SEED` (transmit) and 0 (receive), transmit disparity 0, CRC-24 all ones.

## 4. Parameters

| Parameter | Default | Legal range | Effect |
|---|---|---|---|
| `MF` | 64 | 5 and up | metaframe length in words |
| `BMAX` | 8 | 1 and up | maximum data words per burst |
| `SEED` | 58'h2F0_1234_5678_9ABC | any non-zero 58-bit value | transmit scrambler reset state (zero would never scramble); the receiver learns the peer's state from the state words |

## 5. Errors and corner cases

| Pulse | Cause | Effect |
|---|---|---|
| `err_word` | invalid framing (00 / 11) while word-locked | 16 in a 64-word window drop `word_lock` |
| `err_sync` | missing sync word while sync-locked | the 4th in a row drops `sync_lock` |
| `err_scr` | bad scrambler state word while sync-locked | the 3rd in a row drops `sync_lock` |
| `err_crc32` | diagnostic word CRC-32C mismatch | `peer_status` not updated |
| `err_crc24` | control word CRC-24 mismatch | the held word goes out with `rx_err`; `rx_fc` not updated |
| `err_proto` | data word outside a burst; EOP with no word to end; SOP inside a packet; burst without SOP outside a packet; control word with bit 63 = 0 in a protocol position | the data word is dropped; otherwise processing continues |

Payload bit errors in protocol, skip or diagnostic words only cause CRC errors; protocol errors
never drop a lock. A bit shift of the line drops both locks; a whole-word shift drops only the
metaframe lock.

## 6. TB check map

| Check (TB message or assertion) | What it requires | Spec |
|---|---|---|
| "end" | per end: every received word is the next one the other end sent (data, SOP, EOP, bytes, channel), no `rx_err` on a clean line, and `sync_lock` is reached in time | §3.6, §3.7 |
| "B kept the lock" | a bit or word shift of the line drops `sync_lock` | §3.5 |
| "peer status" | after both ends lock, `peer_status` = 11 | §3.2 |
| "flow control" | `tx_fc` arrives on the far `rx_fc` | §3.3, §3.7 |
| "no packets through" | packets cross both ways | §3.7 |
| "lock lost over payload errors" | payload bit errors cause CRC errors only | §5 |
| "lock lost over protocol errors" | protocol errors do not drop the lock | §5 |
| "word lock lost below the error threshold" | fewer than 16 invalid words in a 64-word window keep `word_lock` | §3.4 |
| "unlocked before the 16th framing error" | 15 invalid words keep `word_lock` | §3.4 |
| "still locked after 16 framing errors" | the 16th invalid word in the window unlocks | §3.4 |
| "lock lost after 3 sync words" | 3 missing sync words in a row keep `sync_lock` | §3.5 |
| "still locked after 4 sync words" | the 4th drops it | §3.5 |
| "lock lost after 2 scrambler state words" | 2 bad state words in a row keep `sync_lock` | §3.5 |
| "still locked after 3 scrambler state words" | the 3rd drops it | §3.5 |
| "word lock lost over a word shift" | a whole-word shift keeps `word_lock` (framing still valid) | §3.4 |
| "too few clean words through" | traffic resumes after relock | §3.7 |
| a_tx_bit | every `tx_p` bit equals the checker's line model (framing, scrambling, disparity, CRCs) | §3.1..§3.3 |
| a_tx_ready | `tx_ready` as section 3.3 | §3.3 |
| a_locks | `word_lock` / `sync_lock` follow the checker's lock FSMs | §3.4, §3.5 |
| a_errors | all six error pulses equal the model, clock for clock | §5 |
| a_rx_valid | `rx_valid` as the model | §3.7 |
| a_rx_word | `rx_data`, `rx_sop`, `rx_eop`, `rx_bytes`, `rx_chan`, `rx_err` with `rx_valid` | §3.7 |
| a_rx_fc | `rx_fc` and `peer_status` | §3.6, §3.7 |
| a_disparity | the transmit running disparity stays within ±65 | §3.1 |
| a_reset | reset values | §3.8 |
