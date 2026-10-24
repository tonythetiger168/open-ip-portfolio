# CCIX link layer over PCIe: protocol messages (Request, Snoop, Response) packed into PCIe vendor-defined message TLPs, Request and Snoop credits, credit return by piggyback or Misc message

Protocol IP `CCIX_Cache_Coherent_Interconnect`, version 2.0. Apache-2.0.

| Item | Value |
|---|---|
| Core | `CCIX_Cache_Coherent_Interconnect_top` (`rtl/CCIX_Cache_Coherent_Interconnect_top.sv`) |
| Register interface | APB4 slave `CCIX_Cache_Coherent_Interconnect_apb`, 32-bit data, 12-bit byte address, zero wait states |
| Clock, reset | PCLK (rising edge), PRESETN (active low, asynchronous) |
| ID register | 0x43430200 (code 0x4343, version 2.0) |
| Registers | 10 words, 0x000 to 0x024 |
| Interrupts | 6 sources into one level-high `irq` |
| Data streams | TX (to the core), RX (from the core) |
| Protocol pins | 7 pass-through |

## Overview

CCIX_Cache_Coherent_Interconnect_top v2.0: CCIX link layer over PCIe: protocol-layer messages packed into PCIe vendor-defined message TLPs, with message credits for requests and snoops

- Messages (32-bit words): a header word {MsgType[3:0], MsgLen[3:0],
CrdReq[3:0], CrdSnp[3:0], 16 bits for the protocol layer (target and
source IDs, opcode)}, then MsgLen - 1 body words, opaque here.
MsgType 1 Request, 2 Snoop, 3 Response; MsgLen 1..8. MsgType 0 is the
link layer's own Misc message (MsgLen 1) that only returns credits.
- Transmit: the protocol layer writes messages on tx_*. A Request
needs a Request credit, a Snoop a Snoop credit (credits the peer
returns; tx_crd_req / tx_crd_snp count them), a Response none; a
message waits on tx_ready until its credit is there. Messages are
gathered into a TLP payload of at most MAXP words: the TLP is sent
once the next message is not ready, does not fit, or has no credit.
Every header leaves with CrdReq / CrdSnp set to the credits this end
returns (the protocol layer's values are replaced); with credits to
return and no message for CRT clocks, a Misc message carries them.
A header with a bad MsgType or MsgLen is dropped alone, with ev_err.
- TLP (PCIe Message with data, routed by ID, Vendor_Defined Type 1):
DW0 {Fmt 011, Type 10010, 0, Length[9:0]}, DW1 {rid, Tag, 7Fh},
DW2 {tgt_rid, Vendor ID 1E2Ch}, DW3 0, then Length payload words.
Tag counts the TLPs sent.
- Receive: tlp_rx_* takes a TLP word per clock (no back-pressure). A
TLP with another Fmt / Type / message code / vendor, a target other
than rid, DW3 not 0, a Length of 0 or above MAXP, or a last word not
where Length puts it is dropped from the bad word on, with ev_err;
so is a message with a bad MsgType or MsgLen or running past the
payload (the messages before it stay). Messages are written to an
RXD-word buffer and handed out on rx_* (rx_last on a message's last
word) once complete. A Request or Snoop needs a credit this end
granted (NREQ and NSNP of them, one per message buffered): without
one it is skipped with ev_nocrd. A Response is taken if the buffer
has room for it besides 8 words per Request and Snoop credit not yet
used; else it is skipped with ev_ovf. The credit of a Request or
Snoop goes back once the protocol layer has read the message. The
credits a well-formed header carries are added once the message is
in; if either count would pass 31, neither is added (ev_err).
Not implemented: the CCIX transaction layer and agents (home, request,
slave agents, coherence), the optimized TLP format, CCIX TLP prefixes
and the PCIe link itself (DLLPs, flow-control credits: this core sits
on a transaction layer's TLP streams), port and link IDs beyond the
PCIe ID, message packing rules other than in-order gathering, and
CCIX ESM / ports discovery. Field positions and encodings are ours;
they have not been checked against a CCIX peer.

tlp_tx_* and tlp_rx_* are the TLP streams to and from the PCIe transaction layer; they pass through unchanged.
The core parameters MAXP (16), NREQ (2), NSNP (2), RXD (64) and CRT (16) keep their defaults.

## Files

| File | Content |
|---|---|
| `rtl/CCIX_Cache_Coherent_Interconnect_top.sv` | protocol core |
| `rtl/CCIX_Cache_Coherent_Interconnect_apb.sv` | APB4 register wrapper (generated) |
| `tb/CCIX_Cache_Coherent_Interconnect_tb.sv` | core testbench |
| `tb/CCIX_Cache_Coherent_Interconnect_apb_tb.sv`, `tb/apb/CCIX_Cache_Coherent_Interconnect_apb_func.svh` | wrapper testbench (generated part + IP-specific part) |
| `tb/cov/CCIX_Cache_Coherent_Interconnect_sva.sv`, `tb/cov/CCIX_Cache_Coherent_Interconnect_apb_sva.sv` | coverage checkers (core, wrapper) |
| `scripts/apb/specs/CCIX_Cache_Coherent_Interconnect.json` | register spec the wrapper, TB, checker and this page are generated from |

```
make -f Makefile.CCIX_Cache_Coherent_Interconnect sim syn            # core test + synthesis (Icarus, Yosys)
make -f Makefile.CCIX_Cache_Coherent_Interconnect apb                # wrapper test + synthesis
bash scripts/cov/run_cov.sh CCIX_Cache_Coherent_Interconnect          # core coverage (Verilator)
bash scripts/cov/run_cov.sh CCIX_Cache_Coherent_Interconnect_apb      # wrapper coverage
```

## Parameters

`CCIX_Cache_Coherent_Interconnect_apb` has the core's parameters and passes them to `CCIX_Cache_Coherent_Interconnect_top` unchanged.

| Parameter | Type | Default |
|---|---|---|
| `MAXP` | int | `16` |
| `NREQ` | int | `2` |
| `NSNP` | int | `2` |
| `RXD` | int | `64` |
| `CRT` | int | `16` |

## Wrapper pins

Pins of `CCIX_Cache_Coherent_Interconnect_apb`. Widths of the pass-through pins are at the default parameters.

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
| `tlp_tx_valid` | output | 1 | protocol pin, core port `tlp_tx_valid` |
| `tlp_tx_ready` | input | 1 | protocol pin, core port `tlp_tx_ready` |
| `tlp_tx_data` | output | 32 | protocol pin, core port `tlp_tx_data` |
| `tlp_tx_last` | output | 1 | protocol pin, core port `tlp_tx_last` |
| `tlp_rx_valid` | input | 1 | protocol pin, core port `tlp_rx_valid` |
| `tlp_rx_data` | input | 32 | protocol pin, core port `tlp_rx_data` |
| `tlp_rx_last` | input | 1 | protocol pin, core port `tlp_rx_last` |

## Core ports

| Port | Dir | Width | In the APB wrapper |
|---|---|---|---|
| `clk` | input | 1 | PCLK |
| `rst_n` | input | 1 | PRESETN |
| `rid` | input | 16 | ID_CFG[15:0] |
| `tgt_rid` | input | 16 | ID_CFG[31:16] |
| `tx_valid` | input | 1 | TX commit / FLAGS |
| `tx_ready` | output | 1 | TX handshake |
| `tx_data` | input | 32 | TX[31:0] |
| `rx_valid` | output | 1 | RX capture |
| `rx_ready` | input | 1 | RX handshake |
| `rx_data` | output | 32 | RX0[31:0] |
| `rx_last` | output | 1 | RX1 |
| `tlp_tx_valid` | output | 1 | pin (pass-through) |
| `tlp_tx_ready` | input | 1 | pin (pass-through) |
| `tlp_tx_data` | output | 32 | pin (pass-through) |
| `tlp_tx_last` | output | 1 | pin (pass-through) |
| `tlp_rx_valid` | input | 1 | pin (pass-through) |
| `tlp_rx_data` | input | 32 | pin (pass-through) |
| `tlp_rx_last` | input | 1 | pin (pass-through) |
| `tx_crd_req` | output | 5 | STATUS[4:0] |
| `tx_crd_snp` | output | 5 | STATUS[9:5] |
| `ev_err` | output | 1 | IRQ_STATUS.ERR |
| `ev_nocrd` | output | 1 | IRQ_STATUS.NOCRD |
| `ev_ovf` | output | 1 | IRQ_STATUS.OVF |

## APB wrapper

`CCIX_Cache_Coherent_Interconnect_apb` is an APB4 slave (AMBA APB protocol v2.0): zero wait states, 32-bit data, 12-bit byte address, PSTRB byte lanes on every writable register, PSLVERR on an unmapped or misaligned address (reads then return 0, writes are dropped). Writes to read-only registers are ignored without an error. The core runs on PCLK and PRESETN. `irq` is level-high: `|(IRQ_STATUS & IRQ_ENABLE)`.

Pass-through pins: `tlp_tx_valid`, `tlp_tx_ready`, `tlp_tx_data`, `tlp_tx_last`, `tlp_rx_valid`, `tlp_rx_data`, `tlp_rx_last`.

### Register map

| Offset | Name | Access | Reset | Description |
|---|---|---|---|---|
| 0x000 | ID | RO | 0x43430200 | IP identification: code, major and minor version |
| 0x004 | IRQ_STATUS | W1C | 0x00000000 | Sticky interrupt bits, write 1 to clear |
| 0x008 | IRQ_ENABLE | RW | 0x00000000 | Interrupt enables; irq = \|(IRQ_STATUS & IRQ_ENABLE) |
| 0x00C | FLAGS | RO | 0x00000000 | Stream holding-register state |
| 0x010 | SCRATCH | RW | 0x00000000 | Scratch register, no effect on the core |
| 0x014 | ID_CFG | RW | 0x00000000 | PCIe IDs |
| 0x018 | TX | RW | 0x00000000 | Message word to send: a header {MsgType, MsgLen, credit fields (replaced), 16 protocol bits}, then MsgLen - 1 body words. A Request or Snoop header is taken once a credit is held |
| 0x01C | RX0 | RO (pop) | 0x00000000 | Received message word; reading it pops it. A Request or Snoop's credit goes back to the peer once its last word is read |
| 0x020 | RX1 | RO (pop) | 0x00000000 | Received message word; reading it pops it. A Request or Snoop's credit goes back to the peer once its last word is read |
| 0x024 | STATUS | RO | core | Credits held for sending |

Unlisted bits read 0 and ignore writes. Reset "core": the register reads the core's outputs directly, so after reset it shows the core's own reset state. WO (pulse) registers read 0. Offsets from 0x028 up to 0xFFC are unmapped (PSLVERR).

### Fields

| Register | Bits | Field | Access | Reset | Description |
|---|---|---|---|---|---|
| ID | 31:16 | CODE | RO | 0x4343 | IP code |
| ID | 15:8 | MAJOR | RO | 0x02 | major version |
| ID | 7:0 | MINOR | RO | 0x00 | minor version |
| IRQ_STATUS | 5:0 | one bit per interrupt | W1C | 0x0 | see Interrupts |
| IRQ_ENABLE | 5:0 | one bit per interrupt | RW | 0x0 | 1 enables the IRQ_STATUS bit onto `irq` |
| FLAGS | 1:0 | one bit per stream flag | RO | 0x0 | see FLAGS |
| SCRATCH | 31:0 | SCRATCH | RW | 0x00000000 | free for software |
| ID_CFG | 15:0 | `rid` | RW | 0x0 | this end's PCIe ID: the Requester ID of TLPs sent, the target ID TLPs received must carry |
| ID_CFG | 31:16 | `tgt_rid` | RW | 0x0 | the peer's PCIe ID: the target ID of TLPs sent |
| TX | 31:0 | `tx_data` | RW | 0x0 | message word |
| RX0 | 31:0 | `rx_data` | RO (pop) | 0x0 | message word |
| RX1 | 0 | `rx_last` | RO (pop) | 0x0 | last word of the message |
| STATUS | 4:0 | `tx_crd_req` | RO | core | Request credits |
| STATUS | 9:5 | `tx_crd_snp` | RO | core | Snoop credits |

### Interrupts (IRQ_STATUS, IRQ_ENABLE)

A bit is set while its source is active, stays set until written with 1, and a set in the same clock as the clear wins.

| Bit | Name | Set when |
|---|---|---|
| 0 | ERR | a malformed TLP or message was dropped, a bad header was written to TX, or a credit grant would pass 31 |
| 1 | NOCRD | a Request or Snoop came without a credit and was skipped |
| 2 | OVF | a Response found no room in the receive buffer and was skipped |
| 3 | TX_DONE | TX beat accepted by the core |
| 4 | TX_OVF | write to TX while full (dropped) |
| 5 | RX_AVAIL | RX captured a beat |

### FLAGS

| Bit | Name | Meaning |
|---|---|---|
| 0 | TX_FULL | TX holds a beat the core has not taken |
| 1 | RX_AVAIL | RX holds an unread beat |

### Streams

* **TX** feeds `tx_data`/`tx_valid`. Writing TX commits the beat: FLAGS.TX_FULL is set and `tx_valid` stays high until the core's `tx_ready`; then TX_DONE is set. A write while full is dropped and sets TX_OVF.
* **RX** takes `rx_data`, `rx_last` from the core with `rx_valid` / `rx_ready`: `rx_ready` is high while the register is empty (or is being read in the same clock), and a captured beat sets FLAGS/IRQ RX_AVAIL. Reading RX1 pops it. Nothing is dropped: the core holds its data until the register is free.

## Programming sequence

1. Release PRESETN. Read ID (0x000) and check it is 0x43430200.
2. Write 0x3F to IRQ_STATUS (0x004) to clear any stale bits.
3. Configure the core: write ID_CFG (0x014). Reset values are in the register map; PSTRB selects the bytes written.
4. Write IRQ_ENABLE (0x008) with the interrupts to use (bit order as in the Interrupts table; 0x3F enables all).
5. To send on TX: wait until FLAGS.TX_FULL (bit 0) is 0, or for IRQ TX_DONE, then write TX (0x018). The last write commits the beat. TX_OVF means a write came while the register was full and was dropped.
6. To receive on RX: wait for IRQ RX_AVAIL or FLAGS.RX_AVAIL (bit 1), then read RX0 (0x01C) then RX1 (0x020). Reading the last word frees the register for the next beat; write 1 to IRQ_STATUS.RX_AVAIL (bit 5) to clear it.
7. Read STATUS (0x024) for the core's live `tx_crd_req`, `tx_crd_snp`; it needs no clearing.
8. On `irq`: read IRQ_STATUS, handle every bit that is set and enabled, then write those bits back to IRQ_STATUS to clear them. A source that is still active sets its bit again.

## Verification

Five-metric coverage with Verilator 5.052 (`scripts/cov/run_cov.sh`); see [COVERAGE_CLOSURE.md](../COVERAGE_CLOSURE.md) for the flow. Line and toggle count only the named RTL file.

| Scope | Test | Line | Toggle | FSM | SVA | Functional |
|---|---|---|---|---|---|---|
| core `rtl/CCIX_Cache_Coherent_Interconnect_top.sv` | pass | 115/115 | 606/606 | 29/29 | 5/5 | 46/46 |
| wrapper `rtl/CCIX_Cache_Coherent_Interconnect_apb.sv` | pass | 35/35 | 998/998 | n/a | 12/12 | 61/61 |
