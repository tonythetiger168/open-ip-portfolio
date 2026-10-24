# UCIe Die-to-Die Adapter Retry: flits with CRC-16 and sequence numbers, Ack / Nak from the far side, a replay buffer resent on a Nak or a replay timeout

Protocol IP `UCIe`, version 2.0. Apache-2.0.

| Item | Value |
|---|---|
| Core | `UCIe_top` (`rtl/UCIe_top.sv`) |
| Register interface | APB4 slave `UCIe_apb`, 32-bit data, 12-bit byte address, zero wait states |
| Clock, reset | PCLK (rising edge), PRESETN (active low, asynchronous) |
| ID register | 0x55430200 (code 0x5543, version 2.0) |
| Registers | 10 words, 0x000 to 0x024 |
| Interrupts | 6 sources into one level-high `irq` |
| Data streams | TX (to the core), RX (from the core) |
| Protocol pins | 4 pass-through |

## Overview

UCIe_top v2.0: the Retry function of a UCIe Die-to-Die Adapter: flits with a CRC and a sequence number, acknowledged (Ack) or negatively acknowledged (Nak) by the far side, kept in a replay buffer and resent from the first unacknowledged one on a Nak or a replay timeout

- Protocol side: tx_valid / tx_ready / tx_data (one 64-bit payload per
flit); rx_valid / rx_data, payloads delivered once each, in order.
- Link side: lt_valid / lt_flit out, lr_valid / lr_flit in. A flit is
{DATA, SEQ[3:0], ACK[3:0], NAK, payload[63:0], CRC[15:0]}; CRC-16
(polynomial 0x1021, seed 0xFFFF, MSB first) over the 74 bits before
it. NOP flits (DATA clear) carry only ACK / NAK.
- Every flit carries ACK: the last sequence number received in order.
It frees replay buffer entries up to it (an ACK that does not fall
within what is outstanding is ignored). NAK set: the far side lost a
flit; everything outstanding is resent.
- Transmit: a replay in progress first, then a new payload (tx_ready:
the RB-entry replay buffer has room and no replay is running), then a
NOP when an Ack or Nak is owed. A replay also starts when nothing has
been acknowledged for TO clocks while flits are outstanding.
- Receive: a flit with a bad CRC is dropped (ev_crc) and a Nak is owed;
a DATA flit with the expected SEQ is delivered and an Ack is owed; an
old SEQ (a replayed duplicate) is dropped and an Ack is owed; a SEQ
ahead is dropped and a Nak is owed. Only one Nak is sent until the
expected flit arrives.
- ev_replay: a replay starts (Nak or timeout). tx_pend: flits
outstanding.
Not implemented: the UCIe flit formats (68B, 256B standard and latency
optimized) and their real CRC, the Adapter's link state machine and
sideband messages, stack multiplexing, parameter exchange, the
physical layer. Widths, the field layout and the CRC are ours; they
have not been checked against another UCIe Adapter.

lt_valid / lt_flit and lr_valid / lr_flit are the flit interfaces to the link; they pass through unchanged.
The core parameters RB (8) and TO (32) keep their defaults.

## Files

| File | Content |
|---|---|
| `rtl/UCIe_top.sv` | protocol core |
| `rtl/UCIe_apb.sv` | APB4 register wrapper (generated) |
| `tb/UCIe_tb.sv` | core testbench |
| `tb/UCIe_apb_tb.sv`, `tb/apb/UCIe_apb_func.svh` | wrapper testbench (generated part + IP-specific part) |
| `tb/cov/UCIe_sva.sv`, `tb/cov/UCIe_apb_sva.sv` | coverage checkers (core, wrapper) |
| `scripts/apb/specs/UCIe.json` | register spec the wrapper, TB, checker and this page are generated from |

```
make -f Makefile.UCIe sim syn            # core test + synthesis (Icarus, Yosys)
make -f Makefile.UCIe apb                # wrapper test + synthesis
bash scripts/cov/run_cov.sh UCIe          # core coverage (Verilator)
bash scripts/cov/run_cov.sh UCIe_apb      # wrapper coverage
```

## Parameters

`UCIe_apb` has the core's parameters and passes them to `UCIe_top` unchanged.

| Parameter | Type | Default |
|---|---|---|
| `RB` | int | `8` |
| `TO` | int | `32` |

## Wrapper pins

Pins of `UCIe_apb`. Widths of the pass-through pins are at the default parameters.

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
| `lt_valid` | output | 1 | protocol pin, core port `lt_valid` |
| `lt_flit` | output | 90 | protocol pin, core port `lt_flit` |
| `lr_valid` | input | 1 | protocol pin, core port `lr_valid` |
| `lr_flit` | input | 90 | protocol pin, core port `lr_flit` |

## Core ports

| Port | Dir | Width | In the APB wrapper |
|---|---|---|---|
| `clk` | input | 1 | PCLK |
| `rst_n` | input | 1 | PRESETN |
| `tx_valid` | input | 1 | TX commit / FLAGS |
| `tx_data` | input | 64 | TX0[31:0], TX1[31:0] |
| `tx_ready` | output | 1 | TX handshake |
| `rx_valid` | output | 1 | RX capture |
| `rx_data` | output | 64 | RX0[31:0], RX1[31:0] |
| `lt_valid` | output | 1 | pin (pass-through) |
| `lt_flit` | output | 90 | pin (pass-through) |
| `lr_valid` | input | 1 | pin (pass-through) |
| `lr_flit` | input | 90 | pin (pass-through) |
| `tx_pend` | output | 4 | STATUS[3:0] |
| `ev_crc` | output | 1 | IRQ_STATUS.CRC |
| `ev_replay` | output | 1 | IRQ_STATUS.REPLAY |

## APB wrapper

`UCIe_apb` is an APB4 slave (AMBA APB protocol v2.0): zero wait states, 32-bit data, 12-bit byte address, PSTRB byte lanes on every writable register, PSLVERR on an unmapped or misaligned address (reads then return 0, writes are dropped). Writes to read-only registers are ignored without an error. The core runs on PCLK and PRESETN. `irq` is level-high: `|(IRQ_STATUS & IRQ_ENABLE)`.

Pass-through pins: `lt_valid`, `lt_flit`, `lr_valid`, `lr_flit`.

### Register map

| Offset | Name | Access | Reset | Description |
|---|---|---|---|---|
| 0x000 | ID | RO | 0x55430200 | IP identification: code, major and minor version |
| 0x004 | IRQ_STATUS | W1C | 0x00000000 | Sticky interrupt bits, write 1 to clear |
| 0x008 | IRQ_ENABLE | RW | 0x00000000 | Interrupt enables; irq = \|(IRQ_STATUS & IRQ_ENABLE) |
| 0x00C | FLAGS | RO | 0x00000000 | Stream holding-register state |
| 0x010 | SCRATCH | RW | 0x00000000 | Scratch register, no effect on the core |
| 0x014 | TX0 | RW | 0x00000000 | Payload to send; writing TX1 sends it (the Adapter takes it when the replay buffer has room and no replay is running) |
| 0x018 | TX1 | RW | 0x00000000 | Payload to send; writing TX1 sends it (the Adapter takes it when the replay buffer has room and no replay is running) |
| 0x01C | RX0 | RO (pop) | 0x00000000 | Payload received; reading RX1 pops it. A payload arriving while RX is full is lost (RX_OVF) |
| 0x020 | RX1 | RO (pop) | 0x00000000 | Payload received; reading RX1 pops it. A payload arriving while RX is full is lost (RX_OVF) |
| 0x024 | STATUS | RO | core | Retry state |

Unlisted bits read 0 and ignore writes. Reset "core": the register reads the core's outputs directly, so after reset it shows the core's own reset state. WO (pulse) registers read 0. Offsets from 0x028 up to 0xFFC are unmapped (PSLVERR).

### Fields

| Register | Bits | Field | Access | Reset | Description |
|---|---|---|---|---|---|
| ID | 31:16 | CODE | RO | 0x5543 | IP code |
| ID | 15:8 | MAJOR | RO | 0x02 | major version |
| ID | 7:0 | MINOR | RO | 0x00 | minor version |
| IRQ_STATUS | 5:0 | one bit per interrupt | W1C | 0x0 | see Interrupts |
| IRQ_ENABLE | 5:0 | one bit per interrupt | RW | 0x0 | 1 enables the IRQ_STATUS bit onto `irq` |
| FLAGS | 1:0 | one bit per stream flag | RO | 0x0 | see FLAGS |
| SCRATCH | 31:0 | SCRATCH | RW | 0x00000000 | free for software |
| TX0 | 31:0 | `tx_data[31:0]` | RW | 0x0 | payload |
| TX1 | 31:0 | `tx_data[63:32]` | RW | 0x0 | payload |
| RX0 | 31:0 | `rx_data[31:0]` | RO (pop) | 0x0 | payload |
| RX1 | 31:0 | `rx_data[63:32]` | RO (pop) | 0x0 | payload |
| STATUS | 3:0 | `tx_pend` | RO | core | flits sent and not yet acknowledged |

### Interrupts (IRQ_STATUS, IRQ_ENABLE)

A bit is set while its source is active, stays set until written with 1, and a set in the same clock as the clear wins.

| Bit | Name | Set when |
|---|---|---|
| 0 | CRC | a flit with a bad CRC was received and dropped |
| 1 | REPLAY | a replay started: a Nak from the far side, or the replay timeout |
| 2 | TX_DONE | TX beat accepted by the core |
| 3 | TX_OVF | write to TX while full (dropped) |
| 4 | RX_AVAIL | RX captured a beat |
| 5 | RX_OVF | beat dropped, RX was full |

### FLAGS

| Bit | Name | Meaning |
|---|---|---|
| 0 | TX_FULL | TX holds a beat the core has not taken |
| 1 | RX_AVAIL | RX holds an unread beat |

### Streams

* **TX** feeds `tx_data`/`tx_valid`. Writing TX1 commits the beat: FLAGS.TX_FULL is set and `tx_valid` stays high until the core's `tx_ready`; then TX_DONE is set. A write while full is dropped and sets TX_OVF.
* **RX** captures `rx_data` when `rx_valid` is high and the register is empty (or is being read in the same clock), and sets FLAGS/IRQ RX_AVAIL. Reading RX1 pops it. A beat that arrives while the register is full is dropped and sets RX_OVF.

## Programming sequence

1. Release PRESETN. Read ID (0x000) and check it is 0x55430200.
2. Write 0x3F to IRQ_STATUS (0x004) to clear any stale bits.
3. Write IRQ_ENABLE (0x008) with the interrupts to use (bit order as in the Interrupts table; 0x3F enables all).
4. To send on TX: wait until FLAGS.TX_FULL (bit 0) is 0, or for IRQ TX_DONE, then write TX0 (0x014) then TX1 (0x018). The last write commits the beat. TX_OVF means a write came while the register was full and was dropped.
5. To receive on RX: wait for IRQ RX_AVAIL or FLAGS.RX_AVAIL (bit 1), then read RX0 (0x01C) then RX1 (0x020). Reading the last word frees the register for the next beat; write 1 to IRQ_STATUS.RX_AVAIL (bit 4) to clear it. Read each beat before the next arrives, or it is dropped and RX_OVF is set.
6. Read STATUS (0x024) for the core's live `tx_pend`; it needs no clearing.
7. On `irq`: read IRQ_STATUS, handle every bit that is set and enabled, then write those bits back to IRQ_STATUS to clear them. A source that is still active sets its bit again.

## Verification

Five-metric coverage with Verilator 5.052 (`scripts/cov/run_cov.sh`); see [COVERAGE_CLOSURE.md](../COVERAGE_CLOSURE.md) for the flow. Line and toggle count only the named RTL file.

| Scope | Test | Line | Toggle | FSM | SVA | Functional |
|---|---|---|---|---|---|---|
| core `rtl/UCIe_top.sv` | pass | 33/33 | 738/738 | n/a | 5/5 | 19/19 |
| wrapper `rtl/UCIe_apb.sv` | pass | 35/35 | 1332/1332 | n/a | 10/10 | 61/61 |
