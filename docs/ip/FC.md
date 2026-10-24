# Fibre Channel FC-1 / FC-2 port: 8b/10b, ordered sets, class 3 frames, buffer-to-buffer credit

Protocol IP `FC`, version 2.0. Apache-2.0.

| Item | Value |
|---|---|
| Core | `FC_top` (`rtl/FC_top.sv`) |
| Register interface | APB4 slave `FC_apb`, 32-bit data, 12-bit byte address, zero wait states |
| Clock, reset | PCLK (rising edge), PRESETN (active low, asynchronous) |
| ID register | 0x46430200 (code 0x4643, version 2.0) |
| Registers | 9 words, 0x000 to 0x020 |
| Interrupts | 9 sources into one level-high `irq` |
| Data streams | TX (to the core), RX (from the core) |
| Protocol pins | 2 pass-through |

## Overview

FC_top v2.0: Fibre Channel FC-1 / FC-2 port (8b/10b, ordered sets, class 3 frames, buffer-to-buffer credit)

- Line: one bit per clk, symbol bit a first, 8b/10b coding (the IEEE
802.3 clause 36 tables) with running disparity, starting at RD-. The
transmitter sends transmission words (4 characters) all the time.
- Ordered sets: K28.5 then three data characters:
IDLE   D21.4 D21.5 D21.5      R_RDY  D21.4 D10.2 D10.2
SOFi3  D21.5 D22.2 D22.2      SOFn3  D21.5 D22.1 D22.1
EOFn   Dx    D21.6 D21.6      EOFt   Dx    D21.3 D21.3
EOFa   Dx    D21.7 D21.7      (Dx = D21.4 when the running disparity
before the EOF is negative, D21.5
when positive; the EOF ends at RD-)
- Transmit: a frame (24-byte header and payload, byte by byte) comes
from the tx_* stream; tx_sofi with the first byte picks SOFi3 over
SOFn3, tx_eoft with the last byte picks EOFt over EOFn. tx_ready is
high for one clock when a byte goes out. The port sends SOF, the
bytes, zero fill up to a word boundary and at least 24 bytes, the
CRC-32 word, EOF; tx_done pulses as the EOF goes out. Without a byte
in time it pulses tx_underrun, fills the word with zeros and ends the
frame with EOFa. At least six IDLE / R_RDY words separate frames.
- Buffer-to-buffer credit: a frame starts only while credit_used (frames
sent, less R_RDYs received) is below cfg_credit; cfg_credit = 0 turns
the check off (credit_used then saturates at 15). The port sends one
R_RDY for each frame it receives (up to 15 waiting), ahead of IDLEs.
- Receive: the receiver aligns on K28.5 at any bit offset; three ordered
sets later rx_sync goes high. A code violation, a disparity error or a
K character other than K28.5 in the first position pulses err_code
and drops alignment. Frame bytes go out on rx_* five bytes late,
without the CRC; the last one has rx_last and
rx_stat = {sofi, eoft, abort, len_err, crc_err}:
crc_err  the CRC does not check
len_err  fewer than 28 or more than 2140 bytes, CRC included
abort    the frame ended with EOFa, another ordered set or a loss of
alignment
A frame that ends with fewer than 5 bytes pulses rx_frag instead. Data
words or an EOF outside a frame pulse err_word.
Not implemented: link initialization (NOS / OLS / LR / LRR), classes
other than 3, other SOF / EOF delimiters and primitive signals, word
synchronization with loss-of-sync hysteresis (one error drops
alignment), ACK / end-to-end credit, header parsing. The CRC is sent
like an Ethernet FCS (complemented, least significant byte first).

tx_p and rx_p are the serial line pins (one bit per PCLK); they pass through unchanged.

## Files

| File | Content |
|---|---|
| `rtl/FC_top.sv` | protocol core |
| `rtl/FC_apb.sv` | APB4 register wrapper (generated) |
| `tb/FC_tb.sv` | core testbench |
| `tb/FC_apb_tb.sv`, `tb/apb/FC_apb_func.svh` | wrapper testbench (generated part + IP-specific part) |
| `tb/cov/FC_sva.sv`, `tb/cov/FC_apb_sva.sv` | coverage checkers (core, wrapper) |
| `scripts/apb/specs/FC.json` | register spec the wrapper, TB, checker and this page are generated from |

```
make -f Makefile.FC sim syn            # core test + synthesis (Icarus, Yosys)
make -f Makefile.FC apb                # wrapper test + synthesis
bash scripts/cov/run_cov.sh FC          # core coverage (Verilator)
bash scripts/cov/run_cov.sh FC_apb      # wrapper coverage
```

## Parameters

The core and the wrapper have no parameters.

## Wrapper pins

Pins of `FC_apb`. Widths of the pass-through pins are at the default parameters.

| Pin | Dir | Width | Description |
|---|---|---|---|
| `PCLK` | input | 1 | APB clock; also the core clock |
| `PRESETN` | input | 1 | APB reset, active low; also the core reset |
| `PSEL` | input | 1 | slave select |
| `PENABLE` | input | 1 | access phase |
| `PWRITE` | input | 1 | 1 = write, 0 = read |
| `PADDR` | input | 12 | byte address; bits [1:0] must be 0 |
| `PWDATA` | input | 32 | write data |
| `PSTRB` | input | 4 | write byte strobes |
| `PRDATA` | output | 32 | read data |
| `PREADY` | output | 1 | always high in the access phase (no wait states) |
| `PSLVERR` | output | 1 | error: unmapped or misaligned address |
| `irq` | output | 1 | interrupt, level high: \|(IRQ_STATUS & IRQ_ENABLE) |
| `tx_p` | output | 1 | protocol pin, core port `tx_p` |
| `rx_p` | input | 1 | protocol pin, core port `rx_p` |

## Core ports

| Port | Dir | Width | In the APB wrapper |
|---|---|---|---|
| `clk` | input | 1 | PCLK |
| `rst_n` | input | 1 | PRESETN |
| `tx_p` | output | 1 | pin (pass-through) |
| `rx_p` | input | 1 | pin (pass-through) |
| `cfg_credit` | input | 4 | CFG[3:0] |
| `tx_valid` | input | 1 | TX commit / FLAGS |
| `tx_ready` | output | 1 | TX handshake |
| `tx_data` | input | 8 | TX[7:0] |
| `tx_last` | input | 1 | TX[8:8] |
| `tx_sofi` | input | 1 | TX[9:9] |
| `tx_eoft` | input | 1 | TX[10:10] |
| `tx_done` | output | 1 | IRQ_STATUS.TX_SENT |
| `tx_underrun` | output | 1 | IRQ_STATUS.TX_UNDERRUN |
| `credit_used` | output | 4 | STATUS[4:1] |
| `rx_valid` | output | 1 | RX capture |
| `rx_data` | output | 8 | RX[7:0] |
| `rx_last` | output | 1 | RX[8:8] |
| `rx_stat` | output | 5 | RX[13:9] |
| `rx_frag` | output | 1 | IRQ_STATUS.RX_FRAG |
| `rx_sync` | output | 1 | STATUS[0:0] |
| `err_code` | output | 1 | IRQ_STATUS.ERR_CODE |
| `err_word` | output | 1 | IRQ_STATUS.ERR_WORD |

## APB wrapper

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

## Programming sequence

1. Release PRESETN. Read ID (0x000) and check it is 0x46430200.
2. Write 0x1FF to IRQ_STATUS (0x004) to clear any stale bits.
3. Configure the core: write CFG (0x014). Reset values are in the register map; PSTRB selects the bytes written.
4. Write IRQ_ENABLE (0x008) with the interrupts to use (bit order as in the Interrupts table; 0x1FF enables all).
5. To send on TX: wait until FLAGS.TX_FULL (bit 0) is 0, or for IRQ TX_DONE, then write TX (0x018). The last write commits the beat. TX_OVF means a write came while the register was full and was dropped.
6. To receive on RX: wait for IRQ RX_AVAIL or FLAGS.RX_AVAIL (bit 1), then read RX (0x01C). Reading the last word frees the register for the next beat; write 1 to IRQ_STATUS.RX_AVAIL (bit 7) to clear it. Read each beat before the next arrives, or it is dropped and RX_OVF is set.
7. Read STATUS (0x020) for the core's live `rx_sync`, `credit_used`; it needs no clearing.
8. On `irq`: read IRQ_STATUS, handle every bit that is set and enabled, then write those bits back to IRQ_STATUS to clear them. A source that is still active sets its bit again.

## Verification

Five-metric coverage with Verilator 5.052 (`scripts/cov/run_cov.sh`); see [COVERAGE_CLOSURE.md](../COVERAGE_CLOSURE.md) for the flow. Line and toggle count only the named RTL file.

| Scope | Test | Line | Toggle | FSM | SVA | Functional |
|---|---|---|---|---|---|---|
| core `rtl/FC_top.sv` | pass | 160/160 | 720/720 | 17/17 | 10/10 | 565/565 |
| wrapper `rtl/FC_apb.sv` | pass | 34/34 | 600/600 | n/a | 13/13 | 71/71 |
