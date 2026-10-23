# AMBA CXS stream port: packets of 32-bit words in 4-word flits with START / END control, credit flow control, ACTIVEREQ / ACTIVEACK link activation and deactivation

Protocol IP `CXS_CCIX_Stream_Interface`, version 2.0. Apache-2.0.

## Overview

CXS_CCIX_Stream_Interface_top v2.0: AMBA CXS (credited eXtensible Stream) port, one transmit and one receive interface, carrying packets of 32-bit words in 4-word flits

- Flit: CXSDATA 128 bits (word 0 in bits 31:0) and CXSCNTL {START[1:0],
START0_PTR, START1_PTR, END[1:0], END0_PTR, END1_PTR,
END_ERROR[1:0]} (pointers are word indexes). At most two packets
start and two end in a flit; START[1] / END[1] only with START[0] /
END[0]. Words between a start and an end belong to that packet, a
packet open at the end of a flit goes on in the next one, other
words are not used.
- Link: each direction has ACTIVEREQ (transmitter) and ACTIVEACK
(receiver): STOP (0, 0), ACTIVATE (1, 0), RUN (1, 1), DEACTIVATE
(0, 1). The receiver grants credits (CRDGNT pulses) only in RUN, one
per free flit buffer; the transmitter sends a flit per credit and, in
DEACTIVATE, returns the credits it holds (CRDRTN pulses); the
receiver drops ACTIVEACK once no credit is out (credits the
transmitter still holds then are dropped). DEACTHINT asks the
transmitter to deactivate.
- Transmit: with tx_en set the port activates its transmit side. Words
written on tx_* (tx_last ends a packet, tx_err with it sets
END_ERROR) fill a flit; the flit is sent (in RUN, with a credit) when
it holds 4 words, or at a packet end when its second packet ended,
or no word is waiting. A packet may wait for words in the
middle of a flit. With tx_en clear or DEACTHINT seen, the side
deactivates at the next packet boundary with the flit sent.
- Receive: with rx_en set the port answers ACTIVEREQ and grants RXF
credits; clearing rx_en raises DEACTHINT. A flit is checked (START /
END order against the open packet, at least one word used); its used
words are handed out on rx_* with rx_last and rx_err (END_ERROR).
A flit without a credit is dropped with ev_crd; a bad flit is dropped
with ev_cntl, and a packet it leaves open is closed with one extra
word 0 marked rx_last and rx_err. A credit returned beyond those
granted, and a grant past 15 credits held, also set ev_crd.
Not implemented: other data widths and more packets per flit, the CXS
continuous-delivery / CXSLAST options, CXSPRCLTYPE, CXSDATACHECK,
credit return without DEACTIVATE as a flow-control tool, the CCIX
packet formats the stream carries. Field positions are ours; they have
not been checked against a CXS peer.

cxs_tx_* and cxs_rx_* are the CXS transmit and receive interfaces; they pass through unchanged.
The core parameter RXF (4) keeps its default.

## Files

| File | Content |
|---|---|
| `rtl/CXS_CCIX_Stream_Interface_top.sv` | protocol core |
| `rtl/CXS_CCIX_Stream_Interface_apb.sv` | APB4 register wrapper (generated) |
| `tb/CXS_CCIX_Stream_Interface_tb.sv` | core testbench |
| `tb/CXS_CCIX_Stream_Interface_apb_tb.sv`, `tb/apb/CXS_CCIX_Stream_Interface_apb_func.svh` | wrapper testbench (generated part + IP-specific part) |
| `tb/cov/CXS_CCIX_Stream_Interface_sva.sv`, `tb/cov/CXS_CCIX_Stream_Interface_apb_sva.sv` | coverage checkers (core, wrapper) |
| `scripts/apb/specs/CXS_CCIX_Stream_Interface.json` | register spec the wrapper, TB, checker and this page are generated from |

```
make -f Makefile.CXS_CCIX_Stream_Interface sim syn            # core test + synthesis (Icarus, Yosys)
make -f Makefile.CXS_CCIX_Stream_Interface apb                # wrapper test + synthesis
bash scripts/cov/run_cov.sh CXS_CCIX_Stream_Interface          # core coverage (Verilator)
bash scripts/cov/run_cov.sh CXS_CCIX_Stream_Interface_apb      # wrapper coverage
```

## Core ports

| Port | Dir | Width | In the APB wrapper |
|---|---|---|---|
| `clk` | input | 1 | PCLK |
| `rst_n` | input | 1 | PRESETN |
| `tx_en` | input | 1 | CTRL[0:0] |
| `rx_en` | input | 1 | CTRL[1:1] |
| `tx_valid` | input | 1 | TX commit / FLAGS |
| `tx_ready` | output | 1 | TX handshake |
| `tx_data` | input | 32 | TX0[31:0] |
| `tx_last` | input | 1 | TX1[0:0] |
| `tx_err` | input | 1 | TX1[1:1] |
| `rx_valid` | output | 1 | RX capture |
| `rx_ready` | input | 1 | RX handshake |
| `rx_data` | output | 32 | RX0[31:0] |
| `rx_last` | output | 1 | RX1[0:0] |
| `rx_err` | output | 1 | RX1[1:1] |
| `cxs_tx_valid` | output | 1 | pin (pass-through) |
| `cxs_tx_data` | output | 128 | pin (pass-through) |
| `cxs_tx_cntl` | output | 14 | pin (pass-through) |
| `cxs_tx_crdgnt` | input | 1 | pin (pass-through) |
| `cxs_tx_crdrtn` | output | 1 | pin (pass-through) |
| `cxs_tx_activereq` | output | 1 | pin (pass-through) |
| `cxs_tx_activeack` | input | 1 | pin (pass-through) |
| `cxs_tx_deacthint` | input | 1 | pin (pass-through) |
| `cxs_rx_valid` | input | 1 | pin (pass-through) |
| `cxs_rx_data` | input | 128 | pin (pass-through) |
| `cxs_rx_cntl` | input | 14 | pin (pass-through) |
| `cxs_rx_crdgnt` | output | 1 | pin (pass-through) |
| `cxs_rx_crdrtn` | input | 1 | pin (pass-through) |
| `cxs_rx_activereq` | input | 1 | pin (pass-through) |
| `cxs_rx_activeack` | output | 1 | pin (pass-through) |
| `cxs_rx_deacthint` | output | 1 | pin (pass-through) |
| `tx_link` | output | 2 | STATUS[1:0] |
| `rx_link` | output | 2 | STATUS[3:2] |
| `tx_credits` | output | 4 | STATUS[7:4] |
| `ev_crd` | output | 1 | IRQ_STATUS.CRD |
| `ev_cntl` | output | 1 | IRQ_STATUS.CNTL |

## APB wrapper

`CXS_CCIX_Stream_Interface_apb` is an APB4 slave (AMBA APB protocol v2.0): zero wait states, 32-bit data, 12-bit byte address, PSTRB byte lanes on every writable register, PSLVERR on an unmapped or misaligned address (reads then return 0, writes are dropped). Writes to read-only registers are ignored without an error. The core runs on PCLK and PRESETN. `irq` is level-high: `|(IRQ_STATUS & IRQ_ENABLE)`.

Pass-through pins: `cxs_tx_valid`, `cxs_tx_data`, `cxs_tx_cntl`, `cxs_tx_crdgnt`, `cxs_tx_crdrtn`, `cxs_tx_activereq`, `cxs_tx_activeack`, `cxs_tx_deacthint`, `cxs_rx_valid`, `cxs_rx_data`, `cxs_rx_cntl`, `cxs_rx_crdgnt`, `cxs_rx_crdrtn`, `cxs_rx_activereq`, `cxs_rx_activeack`, `cxs_rx_deacthint`.

### Register map

| Offset | Name | Access | Reset | Description |
|---|---|---|---|---|
| 0x000 | ID | RO | 0x43580200 | IP identification: code, major and minor version |
| 0x004 | IRQ_STATUS | W1C | 0x00000000 | Sticky interrupt bits, write 1 to clear |
| 0x008 | IRQ_ENABLE | RW | 0x00000000 | Interrupt enables; irq = \|(IRQ_STATUS & IRQ_ENABLE) |
| 0x00C | FLAGS | RO | 0x00000000 | Stream holding-register state |
| 0x010 | SCRATCH | RW | 0x00000000 | Scratch register, no effect on the core |
| 0x014 | CTRL | RW | 0x00000000 | Link control |
| 0x018 | TX0 | RW | 0x00000000 | Packet word to send; writing TX1 sends it (the core takes it when the flit being filled has room) |
| 0x01C | TX1 | RW | 0x00000000 | Packet word to send; writing TX1 sends it (the core takes it when the flit being filled has room) |
| 0x020 | RX0 | RO (pop) | 0x00000000 | Received packet word; reading RX1 pops it. While RX is not read the flit buffers fill and no credit is granted |
| 0x024 | RX1 | RO (pop) | 0x00000000 | Received packet word; reading RX1 pops it. While RX is not read the flit buffers fill and no credit is granted |
| 0x028 | STATUS | RO | 0x00000000 | Link state |

### Fields

| Register | Bits | Field | Description |
|---|---|---|---|
| ID | 31:16 | CODE | 0x4358 |
| ID | 15:8 | MAJOR | 2 |
| ID | 7:0 | MINOR | 0 |
| CTRL | 0 | `tx_en` | activate the transmit side (cleared: deactivate at the next packet boundary) |
| CTRL | 1 | `rx_en` | accept the peer's activation (cleared: DEACTHINT) |
| TX0 | 31:0 | `tx_data` | word |
| TX1 | 0 | `tx_last` | last word of the packet |
| TX1 | 1 | `tx_err` | with tx_last: the packet ends with END_ERROR |
| RX0 | 31:0 | `rx_data` | word |
| RX1 | 0 | `rx_last` | last word of the packet |
| RX1 | 1 | `rx_err` | with rx_last: END_ERROR, or a packet cut by a bad flit |
| STATUS | 1:0 | `tx_link` | transmit side: 0 STOP, 1 ACTIVATE, 2 RUN, 3 DEACTIVATE |
| STATUS | 3:2 | `rx_link` | receive side: 0 STOP, 2 RUN, 3 DEACTIVATE |
| STATUS | 7:4 | `tx_credits` | credits held |

### Interrupts (IRQ_STATUS, IRQ_ENABLE)

A bit is set while its source is active, stays set until written with 1, and a set in the same clock as the clear wins.

| Bit | Name | Set when |
|---|---|---|
| 0 | CRD | a flit without a credit, a credit returned beyond those granted, or a grant past 15 credits |
| 1 | CNTL | a flit with bad START / END or no word used was dropped |
| 2 | TX_DONE | TX beat accepted by the core |
| 3 | TX_OVF | write to TX while full (dropped) |
| 4 | RX_AVAIL | RX captured a beat |

### FLAGS

| Bit | Name | Meaning |
|---|---|---|
| 0 | TX_FULL | TX holds a beat the core has not taken |
| 1 | RX_AVAIL | RX holds an unread beat |

### Streams

* **TX** feeds `tx_data`, `tx_last`, `tx_err`/`tx_valid`. Writing TX1 commits the beat: FLAGS.TX_FULL is set and `tx_valid` stays high until the core's `tx_ready`; then TX_DONE is set. A write while full is dropped and sets TX_OVF.
* **RX** takes `rx_data`, `rx_last`, `rx_err` from the core with `rx_valid` / `rx_ready`: `rx_ready` is high while the register is empty (or is being read in the same clock), and a captured beat sets FLAGS/IRQ RX_AVAIL. Reading RX1 pops it. Nothing is dropped: the core holds its data until the register is free.

## Verification

Five-metric coverage with Verilator 5.052 (`scripts/cov/run_cov.sh`); see [COVERAGE_CLOSURE.md](../COVERAGE_CLOSURE.md) for the flow. Line and toggle count only the named RTL file.

| Scope | Test | Line | Toggle | FSM | SVA | Functional |
|---|---|---|---|---|---|---|
| core `rtl/CXS_CCIX_Stream_Interface_top.sv` | pass | 81/81 | 1244/1244 | 14/14 | 4/4 | 25/25 |
| wrapper `rtl/CXS_CCIX_Stream_Interface_apb.sv` | pass | 38/38 | 1334/1334 | n/a | 14/14 | 59/59 |
