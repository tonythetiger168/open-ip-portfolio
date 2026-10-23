# MIPI C-PHY trio (three wires, three levels): HS bursts with the 3444443 sync, 16-bit words as seven transition symbols, post-amble; the same trio decoded on the receive side

Protocol IP `C_PHY`, version 2.0. Apache-2.0.

## Overview

MIPI C-PHY trio (3-wire, 3-level) HS transmitter with same-trio decoder Implementation scope: * Trio wires A/B/C each drive one of three levels {low, mid, high}, encoded 2 bits per wire (00 = low, 01 = mid, 10 = high). One symbol per clk (the wire-rate clocking is abstracted). * The six C-PHY wire states, as {A, B, C}: +x = (H,L,M)  -x = (L,H,M)  +y = (M,H,L)  -y = (M,L,H) +z = (L,M,H)  -z = (H,M,L) Idle (LP stop) is shown as all wires mid. * Every symbol is a state transition, 3 bits {Flip, Rotation, Polarity}, so consecutive states always differ and the receiver recovers timing from every unit interval: Flip = 1      (symbol 4): same wire pair, opposite polarity Flip = 0, Rotation = 1  : x -> y -> z -> x (clockwise) Flip = 0, Rotation = 0  : x -> z -> y -> x (counter-clockwise) Polarity = 1  : opposite polarity, 0: same polarity Symbols 5..7 do not exist. * Burst: the TX enters HS on +x, sends the sync word 3444443, then 7 symbols per 16-bit word, then the post-amble 4444444, and returns to idle. The 16-bit -> 7-symbol mapper here is base 5, least significant digit first (symbol i = (v / 5^i) mod 5); it is bijective but it is not the mapping table of the MIPI specification. The post-amble decodes to 78124, which no 16-bit word can produce, so the receiver tells it apart from data. * RX decodes the trio: burst entry on +x, sync check, transition to symbol, words, post-amble, then a clean return to idle (rx_done). Sticky irq on: a burst not entering on +x, a wrong sync symbol, an invalid wire state, a missing transition, a 7-symbol group above 65535 that is not the post-amble, a stop inside a word or without a post-amble, or anything but 4 after the post-amble. After an error the receiver waits for idle.


t_a, t_b and t_c are the transmit trio and r_a, r_b and r_c the receive trio, 2 bits per wire (00 low, 01 mid, 10 high), one symbol per PCLK; they pass through unchanged.
A word takes seven clocks on the wires, so a burst of several words needs TX written and RX read at that rate: RX has one holding register and a word arriving while it is full is dropped (RX_OVF). The 16-bit to 7-symbol mapping is base 5, least significant digit first; it is not the MIPI mapping table.

## Files

| File | Content |
|---|---|
| `rtl/C_PHY_top.sv` | protocol core |
| `rtl/C_PHY_apb.sv` | APB4 register wrapper (generated) |
| `tb/C_PHY_tb.sv` | core testbench |
| `tb/C_PHY_apb_tb.sv`, `tb/apb/C_PHY_apb_func.svh` | wrapper testbench (generated part + IP-specific part) |
| `tb/cov/C_PHY_sva.sv`, `tb/cov/C_PHY_apb_sva.sv` | coverage checkers (core, wrapper) |
| `scripts/apb/specs/C_PHY.json` | register spec the wrapper, TB, checker and this page are generated from |

```
make -f Makefile.C_PHY sim syn            # core test + synthesis (Icarus, Yosys)
make -f Makefile.C_PHY apb                # wrapper test + synthesis
bash scripts/cov/run_cov.sh C_PHY          # core coverage (Verilator)
bash scripts/cov/run_cov.sh C_PHY_apb      # wrapper coverage
```

## Core ports

| Port | Dir | Width | In the APB wrapper |
|---|---|---|---|
| `clk` | input | 1 | PCLK |
| `rst_n` | input | 1 | PRESETN |
| `irq` | output | 1 | IRQ_STATUS.ERROR |
| `irq_clear` | input | 1 | CMD |
| `tx_data` | input | 16 | TX[15:0] |
| `tx_valid` | input | 1 | TX commit / FLAGS |
| `tx_ready` | output | 1 | TX handshake |
| `tx_last` | input | 1 | TX[16:16] |
| `tx_done` | output | 1 | IRQ_STATUS.TX_SENT |
| `t_a` | output | 2 | pin (pass-through) |
| `t_b` | output | 2 | pin (pass-through) |
| `t_c` | output | 2 | pin (pass-through) |
| `r_a` | input | 2 | pin (pass-through) |
| `r_b` | input | 2 | pin (pass-through) |
| `r_c` | input | 2 | pin (pass-through) |
| `rx_active` | output | 1 | STATUS |
| `rx_data` | output | 16 | RX[15:0] |
| `rx_valid` | output | 1 | RX capture |
| `rx_done` | output | 1 | IRQ_STATUS.RX_DONE |

## APB wrapper

`C_PHY_apb` is an APB4 slave (AMBA APB protocol v2.0): zero wait states, 32-bit data, 12-bit byte address, PSTRB byte lanes on every writable register, PSLVERR on an unmapped or misaligned address (reads then return 0, writes are dropped). Writes to read-only registers are ignored without an error. The core runs on PCLK and PRESETN. `irq` is level-high: `|(IRQ_STATUS & IRQ_ENABLE)`.

Pass-through pins: `t_a`, `t_b`, `t_c`, `r_a`, `r_b`, `r_c`.

### Register map

| Offset | Name | Access | Reset | Description |
|---|---|---|---|---|
| 0x000 | ID | RO | 0x43700200 | IP identification: code, major and minor version |
| 0x004 | IRQ_STATUS | W1C | 0x00000000 | Sticky interrupt bits, write 1 to clear |
| 0x008 | IRQ_ENABLE | RW | 0x00000000 | Interrupt enables; irq = \|(IRQ_STATUS & IRQ_ENABLE) |
| 0x00C | FLAGS | RO | 0x00000000 | Stream holding-register state |
| 0x010 | SCRATCH | RW | 0x00000000 | Scratch register, no effect on the core |
| 0x014 | TX | RW | 0x00000000 | Word to send; writing TX commits it. A burst starts with the first word and continues while words keep coming; it ends after a word with last set or when the next word is late |
| 0x018 | RX | RO (pop) | 0x00000000 | Word decoded from the receive trio (one every seven clocks in a burst); reading RX frees it |
| 0x01C | CMD | WO (pulse) | 0x00000000 | Commands |
| 0x020 | STATUS | RO | 0x00000000 | Receiver state |

### Fields

| Register | Bits | Field | Description |
|---|---|---|---|
| ID | 31:16 | CODE | 0x4370 |
| ID | 15:8 | MAJOR | 2 |
| ID | 7:0 | MINOR | 0 |
| TX | 15:0 | `tx_data` | 16-bit payload word |
| TX | 16 | `tx_last` | last word of the burst |
| RX | 15:0 | `rx_data` | Word decoded from the receive trio (one every seven clocks in a burst); reading RX frees it |
| CMD | 0 | `irq_clear` | write 1: clear the receiver's sticky error (ERROR stops being set) |
| STATUS | 0 | `rx_active` | a burst is being decoded |

### Interrupts (IRQ_STATUS, IRQ_ENABLE)

A bit is set while its source is active, stays set until written with 1, and a set in the same clock as the clear wins.

| Bit | Name | Set when |
|---|---|---|
| 0 | TX_SENT | a burst finished and the trio is back to idle |
| 1 | RX_DONE | a received burst ended with the post-amble and a clean stop |
| 2 | ERROR | the receiver saw a protocol error (entry not on +x, wrong sync, invalid wire state, missing transition, a symbol group above 65535, a stop inside a word or without post-amble, junk after it); sticky in the core, so the bit is set again on every clock until CMD.irq_clear |
| 3 | TX_DONE | TX beat accepted by the core |
| 4 | TX_OVF | write to TX while full (dropped) |
| 5 | RX_AVAIL | RX captured a beat |
| 6 | RX_OVF | beat dropped, RX was full |

### FLAGS

| Bit | Name | Meaning |
|---|---|---|
| 0 | TX_FULL | TX holds a beat the core has not taken |
| 1 | RX_AVAIL | RX holds an unread beat |

### Streams

* **TX** feeds `tx_data`, `tx_last`/`tx_valid`. Writing TX commits the beat: FLAGS.TX_FULL is set and `tx_valid` stays high until the core's `tx_ready`; then TX_DONE is set. A write while full is dropped and sets TX_OVF.
* **RX** captures `rx_data` when `rx_valid` is high and the register is empty (or is being read in the same clock), and sets FLAGS/IRQ RX_AVAIL. Reading RX pops it. A beat that arrives while the register is full is dropped and sets RX_OVF.

## Verification

Five-metric coverage with Verilator 5.052 (`scripts/cov/run_cov.sh`); see [COVERAGE_CLOSURE.md](../COVERAGE_CLOSURE.md) for the flow. Line and toggle count only the named RTL file.

| Scope | Test | Line | Toggle | FSM | SVA | Functional |
|---|---|---|---|---|---|---|
| core `rtl/C_PHY_top.sv` | pass | 89/89 (+2 excl.) | 306/306 | 24/24 | 13/13 | 22/22 |
| wrapper `rtl/C_PHY_apb.sv` | pass | 33/33 | 616/616 | n/a | 11/11 | 64/64 |
