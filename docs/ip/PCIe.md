# PCIe-style data link layer: TLP framing with sequence numbers and LCRC, Ack/Nak DLLPs with CRC-16, replay buffer, replay and Ack latency timers, flow control for Posted / Non-Posted / Completion header and data credits (InitFC1/InitFC2/UpdateFC), ASPM L1 entry and exit, on a PIPE-like symbol interface

Protocol IP `PCIe`, version 3.0. Apache-2.0.

| Item | Value |
|---|---|
| Core | `PCIe_top` (`rtl/PCIe_top.sv`) |
| Register interface | APB4 slave `PCIe_apb`, 32-bit data, 12-bit byte address, zero wait states |
| Clock, reset | PCLK (rising edge), PRESETN (active low, asynchronous) |
| ID register | 0x50430300 (code 0x5043, version 3.0) |
| Registers | 9 words, 0x000 to 0x020 |
| Interrupts | 14 sources into one level-high `irq` |
| Data streams | TX (to the core), RX (from the core) |
| Protocol pins | 4 pass-through |

## Overview

PCIe_top v3.0: PCI Express-style data link layer, one lane (TLP framing with sequence numbers and LCRC, Ack/Nak with a replay buffer, replay timer and Ack latency timer, DLLPs with CRC-16, flow control for the Posted, Non-Posted and Completion credit types with header and data credits, ASPM L1 entry and exit)

- Line: a PIPE-style symbol interface, one symbol per clk (8b/10b and
scrambling belong to the PHY). tx_k / rx_k mark K symbols: STP (FB),
SDP (5C), END (FD), EDB (FE). Between packets the transmitter sends
data 00 (logical idle) for at least one symbol.
- TLP: STP, {0000, seq[11:8]}, seq[7:0], 1..MAXLEN bytes, LCRC, END.
LCRC = CRC-32 (04C11DB7, initial value all ones, bit 7 of each byte
first) of the two sequence bytes and the TLP bytes, sent inverted,
bits 31:24 first. A TLP ended by EDB whose LCRC is not inverted is
nullified and dropped silently.
- Credit type of a TLP, from its first byte {Fmt[2:0], Type[4:0]}:
Completion when Type is 0101x; Posted when Type is 10xxx (messages)
or 00000 with Fmt[1] set (memory write); Non-Posted otherwise. It
takes one header credit and, when Fmt[1] (with data) is set, one
data credit per 16 bytes of the TLP, rounded up (header included:
the TLP is not parsed further).
- DLLP: SDP, 4 bytes, CRC-16 (100B, initial value all ones, bit 7 first,
sent inverted, bits 15:8 first), END. Byte 0 is the type: Ack 00 and
Nak 10 (bytes 2..3 = {0000, seq}); InitFC1 40 / 50 / 60, InitFC2
C0 / D0 / E0, UpdateFC 80 / 90 / A0 for P / NP / Cpl (bytes 1..3 =
{00, HdrFC[7:0], 00, DataFC[11:0]}); PM_Active_State_Request_L1 23,
PM_Request_Ack 24 (bytes 1..3 zero). Any other type is unknown.
- Flow control initialization: with link_up the layer sends InitFC1 for
P, NP and Cpl (HP / DP, HNP / DNP, HC / DC credits) every FC_GAP
clocks until it has received an InitFC1 or InitFC2 of every type,
then InitFC2 until it receives an InitFC2, an UpdateFC or a good TLP
(dl_up). An advertised value of 0 is infinite. Dropping link_up
resets the whole layer (buffers emptied, sequence numbers back to 0).
- Transmit: a TLP is written into the replay buffer through tlp_* (up
to TXN unacknowledged; a TLP longer than MAXLEN is cut), gets the next
sequence number and is sent when the receiver has header and data
credit of its type, oldest first (credit check as in PCIe: limit -
(consumed + needed) mod 2^n below 2^(n-1)). It stays in the buffer
until acknowledged. A Nak, or REPLAY_TO clocks without progress,
replays from the oldest unacknowledged TLP; the fourth replay without
progress pulses retrain. UpdateFC sets the limits of finite credits.
- Receive: a good TLP with the expected sequence number goes into the
receive buffer and is handed out through rx_*; its Ack is sent ACK_LAT
clocks after the first TLP not yet acknowledged (or at once for a
duplicate). A duplicate is dropped and acknowledged (ev_tlp_dup); a
sequence number ahead, a bad LCRC or a framing error makes a Nak
(once until a good TLP arrives; ev_tlp_seq / ev_tlp_bad). A TLP over
the credits advertised for its type is dropped, not acknowledged
(ev_overflow). Credits are returned (UpdateFC of that type) as each
TLP is read out; UpdateFC of every type is also repeated every UPD_GAP
clocks while in L0.
- ASPM L1 (pm_state 0 L0, 1 requesting, 2 L1): with pm_req, the link
up and nothing unacknowledged, written or owed, the layer stops
taking TLPs and sends PM_Active_State_Request_L1 every FC_GAP clocks
(credits read out are still returned);
PM_Request_Ack -> L1 when nothing is owed (no Ack, Nak or UpdateFC
waiting; otherwise the ack is ignored and the request repeated);
pm_req low or a TLP written -> L0. A request received with aspm_ok
and the same conditions (no TLP written, nothing owed) is answered by
PM_Request_Ack and enters L1; otherwise it is ignored. In L1 nothing
is sent but PM_Request_Ack; a TLP written, a TLP read out or any
packet received other than a PM DLLP returns to L0.
Packets go out between packets in the order Nak, Ack, PM_Request_Ack,
InitFC, PM request, UpdateFC (P, NP, Cpl), TLP.
Not implemented: the physical layer (LTSSM, ordered sets, electrical
idle, 8b/10b, scrambling, skip), 128b/130b, flit mode, more than one
lane, virtual channels other than VC0, credit scale factors, the
PM_Active_State_Nak message, PCI-PM L1 / L2 DLLPs, surprise-down and
data link feature exchange. Field layouts follow PCIe as we read it;
they have not been checked against a compliant device.

Features:

- TLP framing: STP, 12-bit sequence number, 1..MAXLEN bytes, LCRC (CRC-32), END / EDB; nullified TLPs.
- Ack / Nak DLLPs with CRC-16; Acks coalesced by an Ack latency timer (ACK_LAT), duplicates acknowledged at once.
- Replay buffer of TXN TLPs, replay on Nak or the replay timer; retrain request after the fourth replay without progress.
- Flow control per credit type (Posted, Non-Posted, Completion) with header and data credits: InitFC1 / InitFC2 handshake, UpdateFC as TLPs are read out and every UPD_GAP clocks, infinite credits, the PCIe modulo credit check.
- Receive overflow detection per type (header and data) and a byte-room guard.
- ASPM L1: PM_Active_State_Request_L1 / PM_Request_Ack in both directions, crossed requests, exit on a write, a received packet, a read, or anything owed.
- Error events for bad LCRC, sequence numbers ahead, duplicates, framing, DLLP CRC and protocol errors.

tx_sym / tx_k and rx_sym / rx_k are the symbol interface (one 8-bit symbol per PCLK, K flag for STP FB, SDP 5C, END FD, EDB FE); they pass through unchanged.
The core parameters MAXLEN (32), TXN (4 replay slots), RXN (4 receive TLPs), REPLAY_TO (600), ACK_LAT (16), FC_GAP (32), UPD_GAP (1024) and the credits advertised (HP 2, HNP 1, HC 1 headers; DP 4, DNP 2, DC 2 data) keep their defaults.
Field layouts follow PCIe as we read it; they have not been checked against a compliant device. Not implemented: the physical layer (LTSSM, ordered sets, 8b/10b, scrambling), 128b/130b and flit mode, more than one lane, virtual channels other than VC0, credit scale factors, PM_Active_State_Nak, PCI-PM L1 / L2.

## Files

| File | Content |
|---|---|
| `rtl/PCIe_top.sv` | protocol core |
| `rtl/PCIe_apb.sv` | APB4 register wrapper (generated) |
| `tb/PCIe_tb.sv` | core testbench |
| `tb/PCIe_apb_tb.sv`, `tb/apb/PCIe_apb_func.svh` | wrapper testbench (generated part + IP-specific part) |
| `tb/cov/PCIe_sva.sv`, `tb/cov/PCIe_apb_sva.sv` | coverage checkers (core, wrapper) |
| `scripts/apb/specs/PCIe.json` | register spec the wrapper, TB, checker and this page are generated from |

How to run the tests and the coverage flow: see [Running and verifying](#running-and-verifying).

## Parameters

`PCIe_apb` has the core's parameters and passes them to `PCIe_top` unchanged.

| Parameter | Type | Default |
|---|---|---|
| `MAXLEN` | int | `32` |
| `TXN` | int | `4` |
| `RXN` | int | `4` |
| `REPLAY_TO` | int | `600` |
| `ACK_LAT` | int | `16` |
| `FC_GAP` | int | `32` |
| `UPD_GAP` | int | `1024` |
| `HP` | int | `2, HNP = 1, HC = 1` |
| `DP` | int | `4, DNP = 2, DC = 2` |

## Wrapper pins

Pins of `PCIe_apb`. Widths of the pass-through pins are at the default parameters.

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
| `link_up` | input | 1 | CTRL[0:0] |
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
| `pm_req` | input | 1 | CTRL[1:1] |
| `aspm_ok` | input | 1 | CTRL[2:2] |
| `pm_state` | output | 2 | STATUS[2:1] |
| `dl_up` | output | 1 | STATUS[0:0] |
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
| 0x000 | ID | RO | 0x50430300 | IP identification: code, major and minor version |
| 0x004 | IRQ_STATUS | W1C | 0x00000000 | Sticky interrupt bits, write 1 to clear |
| 0x008 | IRQ_ENABLE | RW | 0x00000000 | Interrupt enables; irq = \|(IRQ_STATUS & IRQ_ENABLE) |
| 0x00C | FLAGS | RO | 0x00000000 | Stream holding-register state |
| 0x010 | SCRATCH | RW | 0x00000000 | Scratch register, no effect on the core |
| 0x014 | CTRL | RW | 0x00000004 | Link control |
| 0x018 | TX | RW | 0x00000000 | TLP byte to send; one write per byte, LAST on the final byte (a TLP is cut after MAXLEN = 32 bytes). The first byte is the TLP header's {Fmt, Type}: it selects the credit type (Posted, Non-Posted, Completion) and whether data credits are used. The core takes bytes in L0 while the link is up and a replay-buffer slot is free |
| 0x01C | RX | RO (pop) | 0x00000000 | Received TLP byte (head of the core's receive buffer); reading it pops it. TLPs are delivered once their LCRC and sequence number check out; header and data credits of the TLP's type are returned (UpdateFC) as its last byte is read |
| 0x020 | STATUS | RO | core | Link state |

Unlisted bits read 0 and ignore writes. Reset "core": the register reads the core's outputs directly, so after reset it shows the core's own reset state. WO (pulse) registers read 0. Offsets from 0x024 up to 0xFFC are unmapped (PSLVERR).

### Fields

| Register | Bits | Field | Access | Reset | Description |
|---|---|---|---|---|---|
| ID | 31:16 | CODE | RO | 0x5043 | IP code |
| ID | 15:8 | MAJOR | RO | 0x03 | major version |
| ID | 7:0 | MINOR | RO | 0x00 | minor version |
| IRQ_STATUS | 13:0 | one bit per interrupt | W1C | 0x0 | see Interrupts |
| IRQ_ENABLE | 13:0 | one bit per interrupt | RW | 0x0 | 1 enables the IRQ_STATUS bit onto `irq` |
| FLAGS | 1:0 | one bit per stream flag | RO | 0x0 | see FLAGS |
| SCRATCH | 31:0 | SCRATCH | RW | 0x00000000 | free for software |
| CTRL | 0 | `link_up` | RW | 0x0 | physical link up: starts flow-control init; clearing it drops the link (buffers and sequence numbers reset) |
| CTRL | 1 | `pm_req` | RW | 0x0 | ASPM: ask for L1 whenever the link is idle (PM_Active_State_Request_L1); a TX write wakes the link |
| CTRL | 2 | `aspm_ok` | RW | 0x1 | ASPM: accept L1 requests from the far side when idle |
| TX | 7:0 | `tlp_data` | RW | 0x0 | byte |
| TX | 8 | `tlp_last` | RW | 0x0 | last byte of the TLP |
| RX | 7:0 | `rx_data` | RO (pop) | 0x0 | byte |
| RX | 8 | `rx_last` | RO (pop) | 0x0 | last byte of the TLP |
| STATUS | 0 | `dl_up` | RO | core | data link up (flow-control init done) |
| STATUS | 2:1 | `pm_state` | RO | core | ASPM state: 0 L0, 1 requesting L1, 2 L1 |

### Interrupts (IRQ_STATUS, IRQ_ENABLE)

A bit is set while its source is active, stays set until written with 1, and a set in the same clock as the clear wins.

| Bit | Name | Set when |
|---|---|---|
| 0 | RETRAIN | the fourth replay without progress: the physical layer should retrain |
| 1 | ERR_TLP | a TLP failed (bad LCRC, bad EDB, framing, sequence number ahead): a Nak is sent |
| 2 | ERR_SEQ | a TLP with a sequence number ahead of the expected one |
| 3 | TLP_DUP | a duplicate TLP (already received): dropped and acknowledged |
| 4 | TLP_NULL | a nullified TLP (EDB with inverted LCRC): dropped silently |
| 5 | ERR_OVERFLOW | a good TLP over the header or data credits advertised for its type: dropped, not acknowledged |
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

## Programming sequence

1. Release PRESETN. Read ID (0x000) and check it is 0x50430300.
2. Write 0x3FFF to IRQ_STATUS (0x004) to clear any stale bits.
3. Configure the core: write CTRL (0x014). Reset values are in the register map; PSTRB selects the bytes written.
4. Write IRQ_ENABLE (0x008) with the interrupts to use (bit order as in the Interrupts table; 0x3FFF enables all).
5. To send on TX: wait until FLAGS.TX_FULL (bit 0) is 0, or for IRQ TX_DONE, then write TX (0x018). The last write commits the beat. TX_OVF means a write came while the register was full and was dropped.
6. To receive on RX: wait for IRQ RX_AVAIL or FLAGS.RX_AVAIL (bit 1), then read RX (0x01C). Reading the last word frees the register for the next beat; write 1 to IRQ_STATUS.RX_AVAIL (bit 13) to clear it.
7. Read STATUS (0x020) for the core's live `dl_up`, `pm_state`; it needs no clearing.
8. On `irq`: read IRQ_STATUS, handle every bit that is set and enabled, then write those bits back to IRQ_STATUS to clear them. A source that is still active sets its bit again.

IP-specific use:

1. Write CTRL with link_up set (aspm_ok as wanted); poll STATUS until dl_up reads 1.
2. Send: write TX once per byte, LAST on the final byte. Receive: on RX_AVAIL read RX until a byte with LAST.
3. Set pm_req to let the link enter L1 when idle (STATUS pm_state reads 2); a TX write wakes it.
4. On RETRAIN, retrain the physical layer (clear and set link_up).

## Running and verifying

All commands run from the repository root. Icarus Verilog 12 and Yosys 0.33 are enough for steps 1 to 3; step 4 also needs Verilator 5.052 and pyslang (see [README, Setup](../../README.md#setup)).

| Step | Command | Pass when | Output |
|---|---|---|---|
| 1. Core test | `make -f Makefile.PCIe sim` | a `TEST PASSED` line, no `ERROR` | console |
| 2. Core synthesis | `make -f Makefile.PCIe syn` | Yosys ends without `ERROR`; `stat` prints the cell count | `work/PCIe_top.json` |
| 3. APB wrapper test + synthesis | `make -f Makefile.PCIe apb` | `TEST PASSED: PCIe_apb`, then Yosys without `ERROR` | console, `work/PCIe_apb.json` |
| 4. Coverage (core, wrapper) | `bash scripts/cov/run_cov.sh PCIe`<br>`bash scripts/cov/run_cov.sh PCIe_apb` | `RESULT: CLOSED` (all five metrics 100%) | `work/cov/PCIe/score.json`, `work/cov/PCIe_apb/score.json` |

Expected end of a step 4 run:

```
===== PCIe =====
TEST: PASSED   SVA_FAILURES: 0
LINE ... TOGGLE ... FSM ... SVA ... FUNCTIONAL  (each n/n, 100.0%)
RESULT: CLOSED
```

**Core test** (`tb/PCIe_tb.sv`): drives `PCIe_top` through its own ports against a protocol peer or model and checks every result itself; any mismatch prints `ERROR`, and `TEST PASSED` is printed only when there were none.

**APB wrapper test** (`tb/PCIe_apb_tb.sv`), in this order:

1. Reset values of every register, ID included.
2. Writes to read-only registers are ignored.
3. Each RW register: all ones, all zeros, then 16 random writes with every PSTRB byte-lane pattern, read back each time.
4. Unmapped and misaligned addresses, reads and writes: PSLVERR, read data 0, no side effect on other registers.
5. Back-to-back transfers with no idle cycle.
6. IP traffic through the registers only (`tb/apb/PCIe_apb_func.svh`): the programming sequence above, every interrupt bit set, enabled and cleared, stream FULL/AVAIL/OVF cases (100% wrapper toggle coverage confirms each bit moved).
7. PRESETN asserted mid-run: `irq` and PRDATA go to 0, registers return to reset values.

**Checkers** (`tb/cov/PCIe_sva.sv`, `tb/cov/PCIe_apb_sva.sv`): SVA protocol and APB assertions plus covergroups, bound in by the coverage flow. An assertion failure prints `SVA_FAIL` and fails the run even when the test itself passed.

Whole portfolio: `bash scripts/ci_regression.sh` runs steps 1 to 3 for every IP (what CI runs), and `bash scripts/cov/run_all.sh 4` runs step 4 for every IP.

## Verification

Five-metric coverage with Verilator 5.052 (`scripts/cov/run_cov.sh`); see [COVERAGE_CLOSURE.md](../COVERAGE_CLOSURE.md) for the flow. Line and toggle count only the named RTL file.

| Scope | Test | Line | Toggle | FSM | SVA | Functional |
|---|---|---|---|---|---|---|
| core `rtl/PCIe_top.sv` | pass | 192/192 | 1838/1838 (+4 excl.) | 22/22 | 8/8 | 128/128 |
| wrapper `rtl/PCIe_apb.sv` | pass | 34/34 | 640/640 | n/a | 14/14 | 91/91 |
