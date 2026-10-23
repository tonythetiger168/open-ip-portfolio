# PCIe-style data link layer: TLP framing with sequence numbers and LCRC, Ack/Nak DLLPs with CRC-16, replay buffer and timer, flow-control init (InitFC1/InitFC2) and header credits, on a PIPE-like symbol interface

Protocol IP `PCIe`, version 2.0. Apache-2.0.

## Overview

PCIe_top v2.0: PCI Express-style data link layer, one lane (TLP framing with sequence numbers and LCRC, Ack/Nak with a replay buffer and replay timer, DLLPs with CRC-16, flow control initialization and header credits)

- Line: a PIPE-style symbol interface, one symbol per clk (8b/10b and
scrambling belong to the PHY). tx_k / rx_k mark K symbols: STP (FB),
SDP (5C), END (FD), EDB (FE). Between packets the transmitter sends
data 00 (logical idle) for at least one symbol.
- TLP: STP, {0000, seq[11:8]}, seq[7:0], 1..MAXLEN bytes, LCRC, END.
LCRC = CRC-32 (04C11DB7, initial value all ones, bit 7 of each byte
first) of the two sequence bytes and the TLP bytes, sent inverted,
bits 31:24 first. A TLP ended by EDB whose LCRC is not inverted is
nullified and dropped silently.
- DLLP: SDP, 4 bytes, CRC-16 (100B, initial value all ones, bit 7 first,
sent inverted, bits 15:8 first), END. Byte 0 is the type: Ack 00 and
Nak 10 (bytes 2..3 = {0000, seq}), InitFC1-P 40, InitFC2-P C0,
UpdateFC-P 80 (bytes 1..2 = {00, HdrFC[7:0], 00, DataFC[11:8]},
byte 3 = DataFC[7:0]). Only header credits are used; DataFC is sent
as 0 (infinite) and ignored on receipt.
- Link: dl_up comes once flow control is initialized: with link_up the
layer sends InitFC1 every FC_GAP clocks until it receives an InitFC1
or InitFC2, then InitFC2 until it receives an InitFC2, an UpdateFC or
a good TLP. Dropping link_up resets the whole layer (both buffers are
emptied, sequence numbers restart at 0).
- Transmit: a TLP is written into the replay buffer through tlp_* (up
to TXN unacknowledged; a TLP longer than MAXLEN is cut), gets the next
sequence number and is sent when the link is up and the receiver has
header credit (none needed when its InitFC advertised 0). It stays in
the replay buffer until an Ack or Nak covers it. A Nak, or the replay
timer (REPLAY_TO clocks with unacknowledged TLPs and no progress),
sends again every unacknowledged TLP from the oldest; the 4th replay
without progress pulses retrain. An Ack / Nak for a sequence number
not sent pulses ev_dllp_proto.
- Receive: a good TLP with the expected sequence number is acknowledged
and handed out through rx_* once its LCRC is checked; one already
received is dropped and acknowledged again (ev_tlp_dup); one ahead of
it, a bad LCRC or a framing error makes a Nak (once until a good TLP
arrives; ev_tlp_seq / ev_tlp_bad). The receive buffer holds RXN TLPs;
RXN header credits are advertised and one is returned (UpdateFC) as
each TLP is read out; UpdateFC is also repeated every UPD_GAP clocks.
A TLP without room is dropped and not acknowledged (ev_overflow).
Acks and Naks are sent between packets, before anything else.
Not implemented: the physical layer (LTSSM, ordered sets, 8b/10b,
scrambling, skip), 128b/130b, flits, more than one lane, non-posted and
completion credits, data credits, virtual channels, power management
DLLPs, the AckNak latency timer (Acks go out as soon as possible),
surprise-down and data link feature exchange. Field layouts follow
PCIe as we read it; they have not been checked against a compliant
device.

tx_sym / tx_k and rx_sym / rx_k are the symbol interface (one 8-bit symbol per PCLK, K flag for STP FB, SDP 5C, END FD, EDB FE); they pass through unchanged.
The core parameters MAXLEN (32), TXN (4 replay slots), RXN (4 receive TLPs), REPLAY_TO (600), FC_GAP (32) and UPD_GAP (1024) keep their defaults.

## Files

| File | Content |
|---|---|
| `rtl/PCIe_top.sv` | protocol core |
| `rtl/PCIe_apb.sv` | APB4 register wrapper (generated) |
| `tb/PCIe_tb.sv` | core testbench |
| `tb/PCIe_apb_tb.sv`, `tb/apb/PCIe_apb_func.svh` | wrapper testbench (generated part + IP-specific part) |
| `tb/cov/PCIe_sva.sv`, `tb/cov/PCIe_apb_sva.sv` | coverage checkers (core, wrapper) |
| `scripts/apb/specs/PCIe.json` | register spec the wrapper, TB, checker and this page are generated from |

```
make -f Makefile.PCIe sim syn            # core test + synthesis (Icarus, Yosys)
make -f Makefile.PCIe apb                # wrapper test + synthesis
bash scripts/cov/run_cov.sh PCIe          # core coverage (Verilator)
bash scripts/cov/run_cov.sh PCIe_apb      # wrapper coverage
```

## Core ports

| Port | Dir | Width | In the APB wrapper |
|---|---|---|---|
| `clk` | input | 1 | PCLK |
| `rst_n` | input | 1 | PRESETN |
| `link_up` | input | 1 | CTRL |
| `tx_sym` | output | 8 | pin (pass-through) |
| `tx_k` | output | 1 | pin (pass-through) |
| `rx_sym` | input | 8 | pin (pass-through) |
| `rx_k` | input | 1 | pin (pass-through) |
| `tlp_valid` | input | 1 | TX commit / FLAGS |
| `tlp_ready` | output | 1 | TX handshake |
| `tlp_data` | input | 8 | TX[7:0] |
| `tlp_last` | input | 1 | TX[8:8] |
| `rx_valid` | output | 1 | RX capture |
| `rx_ready` | input | 1 | RX handshake |
| `rx_data` | output | 8 | RX[7:0] |
| `rx_last` | output | 1 | RX[8:8] |
| `dl_up` | output | 1 | STATUS |
| `retrain` | output | 1 | IRQ_STATUS.RETRAIN |
| `ev_tlp_bad` | output | 1 | IRQ_STATUS.ERR_TLP |
| `ev_tlp_seq` | output | 1 | IRQ_STATUS.ERR_SEQ |
| `ev_tlp_dup` | output | 1 | IRQ_STATUS.TLP_DUP |
| `ev_tlp_null` | output | 1 | IRQ_STATUS.TLP_NULL |
| `ev_overflow` | output | 1 | IRQ_STATUS.ERR_OVERFLOW |
| `ev_dllp_bad` | output | 1 | IRQ_STATUS.ERR_DLLP |
| `ev_dllp_proto` | output | 1 | IRQ_STATUS.ERR_PROTO |
| `ev_frame` | output | 1 | IRQ_STATUS.ERR_FRAME |
| `ev_nak` | output | 1 | IRQ_STATUS.NAK |
| `ev_replay` | output | 1 | IRQ_STATUS.REPLAY |

## APB wrapper

`PCIe_apb` is an APB4 slave (AMBA APB protocol v2.0): zero wait states, 32-bit data, 12-bit byte address, PSTRB byte lanes on every writable register, PSLVERR on an unmapped or misaligned address (reads then return 0, writes are dropped). Writes to read-only registers are ignored without an error. The core runs on PCLK and PRESETN. `irq` is level-high: `|(IRQ_STATUS & IRQ_ENABLE)`.

Pass-through pins: `tx_sym`, `tx_k`, `rx_sym`, `rx_k`.

### Register map

| Offset | Name | Access | Reset | Description |
|---|---|---|---|---|
| 0x000 | ID | RO | 0x50430200 | IP identification: code, major and minor version |
| 0x004 | IRQ_STATUS | W1C | 0x00000000 | Sticky interrupt bits, write 1 to clear |
| 0x008 | IRQ_ENABLE | RW | 0x00000000 | Interrupt enables; irq = \|(IRQ_STATUS & IRQ_ENABLE) |
| 0x00C | FLAGS | RO | 0x00000000 | Stream holding-register state |
| 0x010 | SCRATCH | RW | 0x00000000 | Scratch register, no effect on the core |
| 0x014 | CTRL | RW | 0x00000000 | Link control |
| 0x018 | TX | RW | 0x00000000 | TLP byte to send; one write per byte, LAST on the final byte (a TLP is cut after MAXLEN = 32 bytes). The core takes bytes while the link is up and a replay-buffer slot is free |
| 0x01C | RX | RO (pop) | 0x00000000 | Received TLP byte (head of the core's receive buffer); reading it pops it. TLPs are delivered once their LCRC and sequence number check out; header credits are returned as they are read |
| 0x020 | STATUS | RO | 0x00000000 | Link state |

### Fields

| Register | Bits | Field | Description |
|---|---|---|---|
| ID | 31:16 | CODE | 0x5043 |
| ID | 15:8 | MAJOR | 2 |
| ID | 7:0 | MINOR | 0 |
| CTRL | 0 | `link_up` | physical link up: starts flow-control init; clearing it drops the link (buffers and sequence numbers reset) |
| TX | 7:0 | `tlp_data` | byte |
| TX | 8 | `tlp_last` | last byte of the TLP |
| RX | 7:0 | `rx_data` | byte |
| RX | 8 | `rx_last` | last byte of the TLP |
| STATUS | 0 | `dl_up` | data link up (flow-control init done) |

### Interrupts (IRQ_STATUS, IRQ_ENABLE)

A bit is set while its source is active, stays set until written with 1, and a set in the same clock as the clear wins.

| Bit | Name | Set when |
|---|---|---|
| 0 | RETRAIN | the fourth replay without progress: the physical layer should retrain |
| 1 | ERR_TLP | a TLP failed (bad LCRC, bad EDB, framing, sequence number ahead): a Nak is sent |
| 2 | ERR_SEQ | a TLP with a sequence number ahead of the expected one |
| 3 | TLP_DUP | a duplicate TLP (already received): dropped and acknowledged |
| 4 | TLP_NULL | a nullified TLP (EDB with inverted LCRC): dropped silently |
| 5 | ERR_OVERFLOW | a good TLP with the receive buffer full: dropped, not acknowledged |
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

## Verification

Five-metric coverage with Verilator 5.052 (`scripts/cov/run_cov.sh`); see [COVERAGE_CLOSURE.md](../COVERAGE_CLOSURE.md) for the flow. Line and toggle count only the named RTL file.

| Scope | Test | Line | Toggle | FSM | SVA | Functional |
|---|---|---|---|---|---|---|
| core `rtl/PCIe_top.sv` | pass | 133/133 | 1146/1146 | 22/22 | 7/7 | 41/41 |
| wrapper `rtl/PCIe_apb.sv` | pass | 34/34 | 628/628 | n/a | 12/12 | 91/91 |
