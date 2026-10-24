# Ultra Ethernet Transport-style packet delivery sublayer, one PDC in reliable unordered delivery: PSNs, a retransmit window, cumulative and selective ACKs, NACKs for no receive buffer, a retransmit timer

Protocol IP `UEC`, version 2.0. Apache-2.0.

| Item | Value |
|---|---|
| Core | `UEC_top` (`rtl/UEC_top.sv`) |
| Register interface | APB4 slave `UEC_apb`, 32-bit data, 12-bit byte address, zero wait states |
| Clock, reset | PCLK (rising edge), PRESETN (active low, asynchronous) |
| ID register | 0x55450200 (code 0x5545, version 2.0) |
| Registers | 10 words, 0x000 to 0x024 |
| Interrupts | 8 sources into one level-high `irq` |
| Data streams | TX (to the core), RX (from the core) |
| Protocol pins | 7 pass-through |

## Overview

UEC_top v2.0: Ultra Ethernet Transport-style packet delivery sublayer (PDS), one packet delivery context (PDC) in reliable unordered delivery (RUD) mode: PSNs, a retransmit window, cumulative + selective ACKs, NACKs for no receive buffer, a retransmit timer

- Network side: frames of bytes with valid / last (an Ethernet MAC
client: the MAC, IP / UDP headers and the FCS belong below, and a
frame with a bad FCS never arrives). net_tx_* has back-pressure
(net_tx_ready); net_rx_* has none. Fields go most significant byte
first. Frames:
DATA  {8'h10, PSN[15:0], LEN[7:0], payload[LEN]}   LEN 1..MAXP
ACK   {8'h20, CACK[15:0], SACK[7:0]}  CACK: every PSN up to it was
received; SACK bit j: PSN CACK + 2 + j was received (j < W-1)
NACK  {8'h30, PSN[15:0]}   PSN was dropped: no receive buffer
Any other type byte, a length that does not match the frame or a DATA
LEN of 0 or over MAXP: the frame is dropped (ev_proto).
- Host side: packets of 1..MAXP bytes written through tx_* (tx_last on
the final byte; a write of more than MAXP bytes is cut into packets),
received packets read through rx_* in arrival order (unordered with
respect to PSN: RUD hands a packet over as soon as it arrives once).
- Sender: a packet gets the next PSN (from start_psn_tx) and a slot in
the retransmit buffer of W packets; at most W are outstanding. It is
sent once, kept until an ACK covers it (CACK or SACK), sent again on
a NACK for it, and every sent, unacknowledged packet is sent again
when the retransmit timer (RTO clocks without progress) expires
(ev_rto). An ACK whose CACK is behind is ignored (late), one past the
packets sent is dropped (ev_proto); a NACK for a PSN no longer
outstanding is ignored, one for a PSN not sent is dropped (ev_proto).
- Receiver: expects PSNs from start_psn_rx; tracks the cumulative PSN
and which of the next W - 1 arrived. A new packet goes to one of RXB
receive buffers; with none free at its first byte it is dropped and
NACKed (ev_nobuf). A packet received before (or behind the window) is
dropped (ev_dup). Every DATA frame in or behind the window (new, a
duplicate or NACKed) makes an ACK due; one ACK with the state at the
time it is sent covers all that are due.
A PSN past the window (no sender can send it) is dropped (ev_proto).
- Transmit order: NACK, ACK, retransmissions (lowest PSN first), new
packets. enable low closes the PDC (it must be low for a clock after
reset, to load the start PSNs): everything (buffers, both PSN
spaces, a frame in progress: it is cut, and the MAC must drop it) is
dropped and starts again from the
start PSNs when it rises.
Not implemented: PDC establishment and teardown (the PSNs and enable are
pins here), the other delivery modes (ROD, RUDI, UUD), the semantic
sublayer, congestion control (NSCC / RCCC) and packet spraying,
ACK coalescing timers and ACK-CC, the security sublayer, multiple PDCs.
Frame layouts are our own; they follow the shape of UET PDS headers but
not their encodings.

net_tx_* and net_rx_* are the network (MAC client) frames; they pass through unchanged.
The core parameters MAXP (16), W (4), RXB (2) and RTO (256 clocks) keep their defaults.

## Files

| File | Content |
|---|---|
| `rtl/UEC_top.sv` | protocol core |
| `rtl/UEC_apb.sv` | APB4 register wrapper (generated) |
| `tb/UEC_tb.sv` | core testbench |
| `tb/UEC_apb_tb.sv`, `tb/apb/UEC_apb_func.svh` | wrapper testbench (generated part + IP-specific part) |
| `tb/cov/UEC_sva.sv`, `tb/cov/UEC_apb_sva.sv` | coverage checkers (core, wrapper) |
| `scripts/apb/specs/UEC.json` | register spec the wrapper, TB, checker and this page are generated from |

```
make -f Makefile.UEC sim syn            # core test + synthesis (Icarus, Yosys)
make -f Makefile.UEC apb                # wrapper test + synthesis
bash scripts/cov/run_cov.sh UEC          # core coverage (Verilator)
bash scripts/cov/run_cov.sh UEC_apb      # wrapper coverage
```

## Parameters

`UEC_apb` has the core's parameters and passes them to `UEC_top` unchanged.

| Parameter | Type | Default |
|---|---|---|
| `MAXP` | int | `16` |
| `W` | int | `4` |
| `RXB` | int | `2` |
| `RTO` | int | `256` |

## Wrapper pins

Pins of `UEC_apb`. Widths of the pass-through pins are at the default parameters.

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
| `net_tx_valid` | output | 1 | protocol pin, core port `net_tx_valid` |
| `net_tx_ready` | input | 1 | protocol pin, core port `net_tx_ready` |
| `net_tx_data` | output | 8 | protocol pin, core port `net_tx_data` |
| `net_tx_last` | output | 1 | protocol pin, core port `net_tx_last` |
| `net_rx_valid` | input | 1 | protocol pin, core port `net_rx_valid` |
| `net_rx_data` | input | 8 | protocol pin, core port `net_rx_data` |
| `net_rx_last` | input | 1 | protocol pin, core port `net_rx_last` |

## Core ports

| Port | Dir | Width | In the APB wrapper |
|---|---|---|---|
| `clk` | input | 1 | PCLK |
| `rst_n` | input | 1 | PRESETN |
| `enable` | input | 1 | CTRL |
| `start_psn_tx` | input | 16 | PSN[15:0] |
| `start_psn_rx` | input | 16 | PSN[31:16] |
| `tx_valid` | input | 1 | TX commit / FLAGS |
| `tx_ready` | output | 1 | TX handshake |
| `tx_data` | input | 8 | TX[7:0] |
| `tx_last` | input | 1 | TX[8:8] |
| `rx_valid` | output | 1 | RX capture |
| `rx_ready` | input | 1 | RX handshake |
| `rx_data` | output | 8 | RX[7:0] |
| `rx_last` | output | 1 | RX[8:8] |
| `net_tx_valid` | output | 1 | pin (pass-through) |
| `net_tx_ready` | input | 1 | pin (pass-through) |
| `net_tx_data` | output | 8 | pin (pass-through) |
| `net_tx_last` | output | 1 | pin (pass-through) |
| `net_rx_valid` | input | 1 | pin (pass-through) |
| `net_rx_data` | input | 8 | pin (pass-through) |
| `net_rx_last` | input | 1 | pin (pass-through) |
| `outstanding` | output | 3 | STATUS[2:0] |
| `ev_rto` | output | 1 | IRQ_STATUS.RTO |
| `ev_nack` | output | 1 | IRQ_STATUS.NACK |
| `ev_dup` | output | 1 | IRQ_STATUS.DUP |
| `ev_nobuf` | output | 1 | IRQ_STATUS.NOBUF |
| `ev_proto` | output | 1 | IRQ_STATUS.ERR_PROTO |

## APB wrapper

`UEC_apb` is an APB4 slave (AMBA APB protocol v2.0): zero wait states, 32-bit data, 12-bit byte address, PSTRB byte lanes on every writable register, PSLVERR on an unmapped or misaligned address (reads then return 0, writes are dropped). Writes to read-only registers are ignored without an error. The core runs on PCLK and PRESETN. `irq` is level-high: `|(IRQ_STATUS & IRQ_ENABLE)`.

Pass-through pins: `net_tx_valid`, `net_tx_ready`, `net_tx_data`, `net_tx_last`, `net_rx_valid`, `net_rx_data`, `net_rx_last`.

### Register map

| Offset | Name | Access | Reset | Description |
|---|---|---|---|---|
| 0x000 | ID | RO | 0x55450200 | IP identification: code, major and minor version |
| 0x004 | IRQ_STATUS | W1C | 0x00000000 | Sticky interrupt bits, write 1 to clear |
| 0x008 | IRQ_ENABLE | RW | 0x00000000 | Interrupt enables; irq = \|(IRQ_STATUS & IRQ_ENABLE) |
| 0x00C | FLAGS | RO | 0x00000000 | Stream holding-register state |
| 0x010 | SCRATCH | RW | 0x00000000 | Scratch register, no effect on the core |
| 0x014 | CTRL | RW | 0x00000000 | PDC control |
| 0x018 | PSN | RW | 0x00000000 | Start PSNs (taken while CTRL.enable is 0) |
| 0x01C | TX | RW | 0x00000000 | Packet byte to send; one write per byte, LAST on the final byte (a packet is cut after MAXP = 16 bytes). Bytes are taken while the retransmit window (W = 4 packets) has room |
| 0x020 | RX | RO (pop) | 0x00000000 | Received packet byte (packets in arrival order); reading it pops it. While RX is not read the core's RXB = 2 receive buffers fill and further packets are NACKed |
| 0x024 | STATUS | RO | core | Sender state |

Unlisted bits read 0 and ignore writes. Reset "core": the register reads the core's outputs directly, so after reset it shows the core's own reset state. WO (pulse) registers read 0. Offsets from 0x028 up to 0xFFC are unmapped (PSLVERR).

### Fields

| Register | Bits | Field | Access | Reset | Description |
|---|---|---|---|---|---|
| ID | 31:16 | CODE | RO | 0x5545 | IP code |
| ID | 15:8 | MAJOR | RO | 0x02 | major version |
| ID | 7:0 | MINOR | RO | 0x00 | minor version |
| IRQ_STATUS | 7:0 | one bit per interrupt | W1C | 0x0 | see Interrupts |
| IRQ_ENABLE | 7:0 | one bit per interrupt | RW | 0x0 | 1 enables the IRQ_STATUS bit onto `irq` |
| FLAGS | 1:0 | one bit per stream flag | RO | 0x0 | see FLAGS |
| SCRATCH | 31:0 | SCRATCH | RW | 0x00000000 | free for software |
| CTRL | 0 | `enable` | RW | 0x0 | the PDC is open; clearing it drops every packet, frame and buffer and loads the start PSNs |
| PSN | 15:0 | `start_psn_tx` | RW | 0x0 | the first PSN this end sends |
| PSN | 31:16 | `start_psn_rx` | RW | 0x0 | the first PSN this end expects |
| TX | 7:0 | `tx_data` | RW | 0x0 | byte |
| TX | 8 | `tx_last` | RW | 0x0 | last byte of the packet |
| RX | 7:0 | `rx_data` | RO (pop) | 0x0 | byte |
| RX | 8 | `rx_last` | RO (pop) | 0x0 | last byte of the packet |
| STATUS | 2:0 | `outstanding` | RO | core | packets written and not yet acknowledged (0..4) |

### Interrupts (IRQ_STATUS, IRQ_ENABLE)

A bit is set while its source is active, stays set until written with 1, and a set in the same clock as the clear wins.

| Bit | Name | Set when |
|---|---|---|
| 0 | RTO | the retransmit timer expired: every unacknowledged packet is sent again |
| 1 | NACK | a NACK arrived: that packet is sent again |
| 2 | DUP | a packet received before arrived again (dropped, ACKed) |
| 3 | NOBUF | a new packet found no receive buffer: dropped and NACKed |
| 4 | ERR_PROTO | a bad frame (type, length) or an ACK / NACK / PSN no peer could send: dropped |
| 5 | TX_DONE | TX beat accepted by the core |
| 6 | TX_OVF | write to TX while full (dropped) |
| 7 | RX_AVAIL | RX captured a beat |

### FLAGS

| Bit | Name | Meaning |
|---|---|---|
| 0 | TX_FULL | TX holds a beat the core has not taken |
| 1 | RX_AVAIL | RX holds an unread beat |

### Streams

* **TX** feeds `tx_data`, `tx_last`/`tx_valid`. Writing TX commits the beat: FLAGS.TX_FULL is set and `tx_valid` stays high until the core's `tx_ready`; then TX_DONE is set. A write while full is dropped and sets TX_OVF.
* **RX** takes `rx_data`, `rx_last` from the core with `rx_valid` / `rx_ready`: `rx_ready` is high while the register is empty (or is being read in the same clock), and a captured beat sets FLAGS/IRQ RX_AVAIL. Reading RX pops it. Nothing is dropped: the core holds its data until the register is free.

## Programming sequence

1. Release PRESETN. Read ID (0x000) and check it is 0x55450200.
2. Write 0xFF to IRQ_STATUS (0x004) to clear any stale bits.
3. Configure the core: write CTRL (0x014), PSN (0x018). Reset values are in the register map; PSTRB selects the bytes written.
4. Write IRQ_ENABLE (0x008) with the interrupts to use (bit order as in the Interrupts table; 0xFF enables all).
5. To send on TX: wait until FLAGS.TX_FULL (bit 0) is 0, or for IRQ TX_DONE, then write TX (0x01C). The last write commits the beat. TX_OVF means a write came while the register was full and was dropped.
6. To receive on RX: wait for IRQ RX_AVAIL or FLAGS.RX_AVAIL (bit 1), then read RX (0x020). Reading the last word frees the register for the next beat; write 1 to IRQ_STATUS.RX_AVAIL (bit 7) to clear it.
7. Read STATUS (0x024) for the core's live `outstanding`; it needs no clearing.
8. On `irq`: read IRQ_STATUS, handle every bit that is set and enabled, then write those bits back to IRQ_STATUS to clear them. A source that is still active sets its bit again.

## Verification

Five-metric coverage with Verilator 5.052 (`scripts/cov/run_cov.sh`); see [COVERAGE_CLOSURE.md](../COVERAGE_CLOSURE.md) for the flow. Line and toggle count only the named RTL file.

| Scope | Test | Line | Toggle | FSM | SVA | Functional |
|---|---|---|---|---|---|---|
| core `rtl/UEC_top.sv` | pass | 90/90 | 1132/1132 | n/a | 7/7 | 42/42 |
| wrapper `rtl/UEC_apb.sv` | pass | 37/37 | 720/720 | n/a | 14/14 | 69/69 |
