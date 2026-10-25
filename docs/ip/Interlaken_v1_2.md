# Interlaken-style lane: 64b/67b framing, scrambling, metaframe (sync, scrambler state, skip, diagnostic with CRC-32), bursts with CRC-24, in-band flow control

Protocol IP `Interlaken_v1_2`, version 2.0. Apache-2.0.

## Overview

Interlaken_v1_2_top v2.0: Interlaken-style lane, one lane (64b/67b framing, scrambling, metaframe, bursts with CRC-24, in-band flow control)

- Line: one bit per clk. A word is 67 bits sent bit 66 first: bit 66 the
inversion flag, bits 65:64 the framing (01 data, 10 control; 00 and 11
are invalid), bits 63:0 the payload (inverted when bit 66 is set).
- Disparity: the transmitter keeps the running disparity of every bit
sent and inverts a word's payload when the word would push it further
from zero.
- Scrambling: the payload is added to the sequence of the generator
x^58 + x^39 + 1 (64 steps a word, bit 63 first), except in the sync
and scrambler state words, where the generator also holds still.
- Metaframe: MF words: sync word (78F678F678F678F6), scrambler state
word (001010 and the generator state), skip word (1E1E1E1E1E1E1E1E),
MF - 4 protocol words, diagnostic word (011001, 24 zero bits, lane
status, link status, CRC-32C). The framing words are control words;
the CRC covers bits 65:0 of every word of the metaframe before
scrambling, with the state field and its own field as zeros
(polynomial 1EDC6F41, initial value all ones, bit 65 first, sent
inverted). Lane status = this end's sync_lock; link status = also the
peer's lane status.
- Protocol words: data words and burst / idle control words. Control
word: [63] 1, [62] burst (1) or idle (0), [61] SOP, [60] EOP of the
burst it closes, [59:57] valid bytes of that last word (0 = 8), [56]
0, [55:40] flow control, [39:32] channel, [31:24] 0, [23:0] CRC-24.
Every control word closes the burst before it; a burst control word
opens the next. The CRC-24 (polynomial 328B63, initial value all
ones, bit 63 first) covers the data words since the previous control
word and this one with its CRC field as zeros.
- Transmit: one word per 67 clocks. A burst carries up to BMAX data
words of one packet; it ends at the packet's end, at BMAX or when no
word is offered. tx_valid must stay high until tx_ready; a burst
control word takes tx_sop and tx_chan of the word offered, tx_ready
takes the word itself in the next protocol word. tx_fc goes out in
every control word.
- Receive, word lock: the receiver slides one bit at a time until the
framing bits are valid, locks (word_lock) after 64 valid in a row,
pulses err_word for each invalid one while locked and unlocks at the
16th invalid one within a window of 64 words.
- Receive, metaframe lock: with word_lock, a sync word starts the count;
four sync words MF words apart give sync_lock. While locked, err_sync
pulses for a missing sync word and the 4th in a row drops the lock;
err_scr pulses for a scrambler state word that does not match the
descrambler (loaded from these words while testing) and the 3rd in a
row drops the lock; err_crc32 pulses for a diagnostic word whose CRC
does not match, otherwise peer_status takes its status bits.
- Receive, protocol: with sync_lock, each data word is held until the
next protocol word tells whether it ends the packet; it then goes out
on rx_data with rx_sop / rx_eop / rx_bytes / rx_chan, rx_err set when
the CRC-24 of its burst failed (a word held when sync_lock drops goes
out with rx_eop and rx_err). err_crc24 pulses for every control word
whose CRC-24 fails; rx_fc takes the flow control of every one that
passes. err_proto pulses for a data word outside a burst, an EOP with
no data word to end, a SOP inside a packet, a burst without SOP
outside a packet, and a framing layer word in a protocol position.
Not implemented: lane striping (multiple lanes), the calendar and its
reset bit, BurstShort / BurstMin rules, skip words elsewhere than third,
the multiple-use field, retransmit, dual calendar. Field layouts follow
Interlaken 1.2 as we read it; they have not been checked against a
compliant device.

tx_p and rx_p are the serial lane pins (one bit per PCLK); they pass through unchanged.
The core parameters MF (metaframe length, 64), BMAX (data words per burst, 8) and SEED (scrambler start) keep their defaults.

## Files

| File | Content |
|---|---|
| `rtl/Interlaken_v1_2_top.sv` | protocol core |
| `rtl/Interlaken_v1_2_apb.sv` | APB4 register wrapper (generated) |
| `tb/Interlaken_v1_2_tb.sv` | core testbench |
| `tb/Interlaken_v1_2_apb_tb.sv`, `tb/apb/Interlaken_v1_2_apb_func.svh` | wrapper testbench (generated part + IP-specific part) |
| `tb/cov/Interlaken_v1_2_sva.sv`, `tb/cov/Interlaken_v1_2_apb_sva.sv` | coverage checkers (core, wrapper) |
| `scripts/apb/specs/Interlaken_v1_2.json` | register spec the wrapper, TB, checker and this page are generated from |

```
make -f Makefile.Interlaken_v1_2 sim syn            # core test + synthesis (Icarus, Yosys)
make -f Makefile.Interlaken_v1_2 apb                # wrapper test + synthesis
bash scripts/cov/run_cov.sh Interlaken_v1_2          # core coverage (Verilator)
bash scripts/cov/run_cov.sh Interlaken_v1_2_apb      # wrapper coverage
```

## Core ports

| Port | Dir | Width | In the APB wrapper |
|---|---|---|---|
| `clk` | input | 1 | PCLK |
| `rst_n` | input | 1 | PRESETN |
| `tx_p` | output | 1 | pin (pass-through) |
| `rx_p` | input | 1 | pin (pass-through) |
| `tx_valid` | input | 1 | TX commit / FLAGS |
| `tx_ready` | output | 1 | TX handshake |
| `tx_data` | input | 64 | TX0[31:0], TX1[31:0] |
| `tx_sop` | input | 1 | TX2[0:0] |
| `tx_eop` | input | 1 | TX2[1:1] |
| `tx_bytes` | input | 3 | TX2[4:2] |
| `tx_chan` | input | 8 | TX2[12:5] |
| `tx_fc` | input | 16 | FC[15:0] |
| `rx_valid` | output | 1 | RX capture |
| `rx_data` | output | 64 | RX0[31:0], RX1[31:0] |
| `rx_sop` | output | 1 | RX2[0:0] |
| `rx_eop` | output | 1 | RX2[1:1] |
| `rx_bytes` | output | 3 | RX2[4:2] |
| `rx_chan` | output | 8 | RX2[12:5] |
| `rx_err` | output | 1 | RX2[13:13] |
| `rx_fc` | output | 16 | RX_FC[15:0] |
| `word_lock` | output | 1 | STATUS[0:0] |
| `sync_lock` | output | 1 | STATUS[1:1] |
| `peer_status` | output | 2 | STATUS[3:2] |
| `err_word` | output | 1 | IRQ_STATUS.ERR_WORD |
| `err_sync` | output | 1 | IRQ_STATUS.ERR_SYNC |
| `err_scr` | output | 1 | IRQ_STATUS.ERR_SCR |
| `err_crc32` | output | 1 | IRQ_STATUS.ERR_CRC32 |
| `err_crc24` | output | 1 | IRQ_STATUS.ERR_CRC24 |
| `err_proto` | output | 1 | IRQ_STATUS.ERR_PROTO |

## APB wrapper

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
| 0x030 | RX_FC | RO | 0x00000000 | Flow control received |
| 0x034 | STATUS | RO | 0x00000000 | Receive alignment and peer status |

### Fields

| Register | Bits | Field | Description |
|---|---|---|---|
| ID | 31:16 | CODE | 0x494C |
| ID | 15:8 | MAJOR | 2 |
| ID | 7:0 | MINOR | 0 |
| FC | 15:0 | `tx_fc` | flow control bits |
| TX0 | 31:0 | `tx_data[31:0]` | payload |
| TX1 | 31:0 | `tx_data[63:32]` | payload |
| TX2 | 0 | `tx_sop` | first word of a packet |
| TX2 | 1 | `tx_eop` | last word of a packet |
| TX2 | 4:2 | `tx_bytes` | with EOP: valid bytes of the word (0 = 8) |
| TX2 | 12:5 | `tx_chan` | channel (taken at the burst start) |
| RX0 | 31:0 | `rx_data[31:0]` | payload |
| RX1 | 31:0 | `rx_data[63:32]` | payload |
| RX2 | 0 | `rx_sop` | first word of a packet |
| RX2 | 1 | `rx_eop` | last word of a packet |
| RX2 | 4:2 | `rx_bytes` | with EOP: valid bytes (0 = 8) |
| RX2 | 12:5 | `rx_chan` | channel of its burst |
| RX2 | 13 | `rx_err` | its burst failed the CRC-24 (or the lane lost sync) |
| RX_FC | 15:0 | `rx_fc` | from the last control word that passed its CRC-24 |
| STATUS | 0 | `word_lock` | word (framing bit) lock |
| STATUS | 1 | `sync_lock` | metaframe lock (words are delivered) |
| STATUS | 3:2 | `peer_status` | {lane, link} status from the peer's last good diagnostic word |

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

## Verification

Five-metric coverage with Verilator 5.052 (`scripts/cov/run_cov.sh`); see [COVERAGE_CLOSURE.md](../COVERAGE_CLOSURE.md) for the flow. Line and toggle count only the named RTL file.

| Scope | Test | Line | Toggle | FSM | SVA | Functional |
|---|---|---|---|---|---|---|
| core `rtl/Interlaken_v1_2_top.sv` | pass | 120/120 | 2926/2926 | 14/14 | 9/9 | 38/38 |
| wrapper `rtl/Interlaken_v1_2_apb.sv` | pass | 43/43 | 1216/1216 | n/a | 15/15 | 85/85 |
