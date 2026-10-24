# USB 3.2-style link layer: header packets with CRC-16 and link control word, data packet payloads with CRC-32, link commands (LGOOD, LCRD, LRTY, LBAD), header sequence numbers, retry buffer, credits and the pending/credit timers, on an 8b/10b-like symbol interface

Protocol IP `USB3_2`, version 2.0. Apache-2.0.

| Item | Value |
|---|---|
| Core | `USB3_2_top` (`rtl/USB3_2_top.sv`) |
| Register interface | APB4 slave `USB3_2_apb`, 32-bit data, 12-bit byte address, zero wait states |
| Clock, reset | PCLK (rising edge), PRESETN (active low, asynchronous) |
| ID register | 0x55330200 (code 0x5533, version 2.0) |
| Registers | 9 words, 0x000 to 0x020 |
| Interrupts | 13 sources into one level-high `irq` |
| Data streams | TX (to the core), RX (from the core) |
| Protocol pins | 4 pass-through |

## Overview

USB3_2_top v2.0: USB 3.2-style SuperSpeed link layer, one lane (header packets with sequence numbers, CRC-16 and a CRC-5 link control word, data packet payloads with CRC-32, link commands, header buffer credits, retry and recovery)

- Line: a PIPE-style symbol interface, one symbol per clk (8b/10b,
scrambling and the LTSSM belong to the PHY). tx_k / rx_k mark K
symbols: SHP (FB), SDP (5C), END (FD), EDB (7C), SLC (DC), EPF (F7).
Between packets the transmitter sends data 00 (logical idle).
Multi-byte fields are sent most significant byte first.
- Header packet (HP): SHP SHP SHP EPF, 12 header bytes, CRC-16 of them
(100B, initial value all ones, bit 7 of each byte first, sent
inverted), link control word. Link control word = {CRC-5, 8'h00,
seq[2:0]}; CRC-5 (x^5+x^2+1, initial value all ones, bit 10 first,
inverted) covers bits 10:0.
- Data packet: a header packet whose type (header byte 0, bits 4:0) is
01000 (DP) is followed at once by its payload (DPP): SDP SDP SDP EPF,
0..MAXD bytes, CRC-32 of them (04C11DB7, initial value all ones, bit 7
first, sent inverted), END END END EPF. EDB EDB EDB EPF in place of
the END set aborts the payload.
- Link command (LC): SLC SLC SLC EPF, then the link command word twice.
Link command word = {CRC-5, info[10:0]}; info: LGOOD_n 000_0000_0nnn,
LCRD_x 000_1000_00xx, LRTY 001_0000_0000, LBAD 001_1000_0000. The
first copy with a good CRC-5 is used; both bad: ev_lc_bad.
- Link: link_up is U0 from the LTSSM. On link_up the layer advertises:
it sends LGOOD_n for the last header packet it received (Header
Sequence Number Advertisement), then LCRD_A, LCRD_B, ... for each free
receive buffer (credit letters restart at A on both sides). ll_up
comes once the partner's LGOOD advertisement arrives: header packets
it acknowledges are released, the rest are sent again. Dropping
link_up keeps every buffer and sequence number. The layer pulses
recovery (the LTSSM is expected to drop link_up and raise it again)
and stops sending on: no advertisement or LGOOD for PEND_TO clocks
(PENDING_HP_TIMER), no credit for CRED_TO clocks while a header
packet waits for one (CREDIT_HP_TIMER), an LGOOD, LCRD or LBAD out of
order or with nothing to cover, a header packet with an unexpected
sequence number, or the third LBAD in a row.
- Transmit: packets are written into the replay buffer through tx_*
(up to TXN unacknowledged): 12 header bytes (fewer are padded with
zeros), then for a DP the payload (cut after MAXD bytes; the bytes
after the header of any other packet are dropped). A header packet
goes out when the link is up and the partner has a free buffer
(LCRD credit; a packet sent again in a retry does not take a new
one). It stays in the replay buffer until the LGOOD with its sequence
number arrives. An LBAD sends LRTY, then every unacknowledged packet
from the oldest.
- Receive: a good header packet with the expected sequence number is
stored in one of RXN buffers and acknowledged with LGOOD_n; one with a
bad CRC-16 / CRC-5 or a framing error sends LBAD, after which header
packets are ignored until LRTY arrives (ev_hp_bad). A DP's payload is
stored with it; a payload with a bad CRC-32, too long, aborted, cut
by a framing error or missing (another packet first) marks the packet
with rx_err (ev_dpp_bad; payloads are not retried by the link layer).
Packets are handed out through rx_* (header bytes, then payload); a
buffer is returned to the partner with LCRD_x once read out. A header
packet without a free buffer is dropped and not acknowledged
(ev_overflow). Link commands go out between packets, before header
packets.
Not implemented: the LTSSM, LFPS, ordered sets other than the packet
framing (SKP, TS1/TS2), 8b/10b and 128b/132b, power management link
commands (LGO_Ux, LAU, LXU, LPMA, LUP, LDN), the 3-of-4 symbol framing
tolerance, more than one lane, hub depth / delayed / deferred bits.
Field layouts follow the USB 3.2 link layer as we read it; they have
not been checked against a compliant device.

tx_sym / tx_k and rx_sym / rx_k are the symbol interface (one 8-bit symbol per clock, K flag for SHP FB, SDP 5C, END FD, EDB 7C, SLC DC, EPF F7); they pass through unchanged.
The core parameters MAXD (32), TXN (4 retry buffers), RXN (4 receive buffers), PEND_TO (400) and CRED_TO (2000) keep their defaults.

## Files

| File | Content |
|---|---|
| `rtl/USB3_2_top.sv` | protocol core |
| `rtl/USB3_2_apb.sv` | APB4 register wrapper (generated) |
| `tb/USB3_2_tb.sv` | core testbench |
| `tb/USB3_2_apb_tb.sv`, `tb/apb/USB3_2_apb_func.svh` | wrapper testbench (generated part + IP-specific part) |
| `tb/cov/USB3_2_sva.sv`, `tb/cov/USB3_2_apb_sva.sv` | coverage checkers (core, wrapper) |
| `scripts/apb/specs/USB3_2.json` | register spec the wrapper, TB, checker and this page are generated from |

```
make -f Makefile.USB3_2 sim syn            # core test + synthesis (Icarus, Yosys)
make -f Makefile.USB3_2 apb                # wrapper test + synthesis
bash scripts/cov/run_cov.sh USB3_2          # core coverage (Verilator)
bash scripts/cov/run_cov.sh USB3_2_apb      # wrapper coverage
```

## Parameters

`USB3_2_apb` has the core's parameters and passes them to `USB3_2_top` unchanged.

| Parameter | Type | Default |
|---|---|---|
| `MAXD` | int | `32` |
| `TXN` | int | `4` |
| `RXN` | int | `4` |
| `PEND_TO` | int | `400` |
| `CRED_TO` | int | `2000` |

## Wrapper pins

Pins of `USB3_2_apb`. Widths of the pass-through pins are at the default parameters.

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
| `tx_sym` | output | 8 | protocol pin, core port `tx_sym` |
| `tx_k` | output | 1 | protocol pin, core port `tx_k` |
| `rx_sym` | input | 8 | protocol pin, core port `rx_sym` |
| `rx_k` | input | 1 | protocol pin, core port `rx_k` |

## Core ports

| Port | Dir | Width | In the APB wrapper |
|---|---|---|---|
| `clk` | input | 1 | PCLK |
| `rst_n` | input | 1 | PRESETN |
| `link_up` | input | 1 | CTRL |
| `recovery` | output | 1 | IRQ_STATUS.RECOVERY |
| `tx_sym` | output | 8 | pin (pass-through) |
| `tx_k` | output | 1 | pin (pass-through) |
| `rx_sym` | input | 8 | pin (pass-through) |
| `rx_k` | input | 1 | pin (pass-through) |
| `tx_valid` | input | 1 | TX commit / FLAGS |
| `tx_ready` | output | 1 | TX handshake |
| `tx_data` | input | 8 | TX[7:0] |
| `tx_last` | input | 1 | TX[8:8] |
| `rx_valid` | output | 1 | RX capture |
| `rx_ready` | input | 1 | RX handshake |
| `rx_data` | output | 8 | RX[7:0] |
| `rx_last` | output | 1 | RX[8:8] |
| `rx_err` | output | 1 | RX[9:9] |
| `ll_up` | output | 1 | STATUS |
| `ev_hp_bad` | output | 1 | IRQ_STATUS.ERR_HP |
| `ev_seq` | output | 1 | IRQ_STATUS.ERR_SEQ |
| `ev_lc_bad` | output | 1 | IRQ_STATUS.ERR_LC |
| `ev_dpp_bad` | output | 1 | IRQ_STATUS.ERR_DPP |
| `ev_frame` | output | 1 | IRQ_STATUS.ERR_FRAME |
| `ev_proto` | output | 1 | IRQ_STATUS.ERR_PROTO |
| `ev_overflow` | output | 1 | IRQ_STATUS.ERR_OVERFLOW |
| `ev_lbad` | output | 1 | IRQ_STATUS.LBAD |
| `ev_timeout` | output | 1 | IRQ_STATUS.TIMEOUT |

## APB wrapper

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

## Programming sequence

1. Release PRESETN. Read ID (0x000) and check it is 0x55330200.
2. Write 0x1FFF to IRQ_STATUS (0x004) to clear any stale bits.
3. Configure the core: write CTRL (0x014). Reset values are in the register map; PSTRB selects the bytes written.
4. Write IRQ_ENABLE (0x008) with the interrupts to use (bit order as in the Interrupts table; 0x1FFF enables all).
5. To send on TX: wait until FLAGS.TX_FULL (bit 0) is 0, or for IRQ TX_DONE, then write TX (0x018). The last write commits the beat. TX_OVF means a write came while the register was full and was dropped.
6. To receive on RX: wait for IRQ RX_AVAIL or FLAGS.RX_AVAIL (bit 1), then read RX (0x01C). Reading the last word frees the register for the next beat; write 1 to IRQ_STATUS.RX_AVAIL (bit 12) to clear it.
7. Read STATUS (0x020) for the core's live `ll_up`; it needs no clearing.
8. On `irq`: read IRQ_STATUS, handle every bit that is set and enabled, then write those bits back to IRQ_STATUS to clear them. A source that is still active sets its bit again.

## Verification

Five-metric coverage with Verilator 5.052 (`scripts/cov/run_cov.sh`); see [COVERAGE_CLOSURE.md](../COVERAGE_CLOSURE.md) for the flow. Line and toggle count only the named RTL file.

| Scope | Test | Line | Toggle | FSM | SVA | Functional |
|---|---|---|---|---|---|---|
| core `rtl/USB3_2_top.sv` | pass | 173/173 | 954/954 | 31/31 | 7/7 | 48/48 |
| wrapper `rtl/USB3_2_apb.sv` | pass | 34/34 | 624/624 | n/a | 12/12 | 87/87 |
