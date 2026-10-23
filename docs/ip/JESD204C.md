# JESD204C-style 64b/66b link layer: scrambling, sync header stream (CRC-12, command channel), multiblock and extended multiblock alignment

Protocol IP `JESD204C`, version 2.0. Apache-2.0.

## Overview

JESD204C_top v2.0: JESD204C-style 64b/66b link layer, one lane (scrambling, sync header stream with CRC-12 and command channel, multiblock and extended multiblock alignment)

- Line: one bit per clk. A block is a 2-bit sync header (first bit the
inverse of the second; the second is the sync header stream bit, so
00 and 11 are invalid) and 64 payload bits, payload bit 0 first.
- Scrambling: the payload goes through the self-synchronous scrambler
1 + x^39 + x^58 (headers are not scrambled).
- Multiblock: 32 blocks. Its 32 sync header stream bits, block 0 first:
C11 C10 C9 1  C8 C7 C6 1  C5 C4 C3 1  C2 C1 C0 1
M6  M5  M4 1  M3 M2 M1 1  M0 EoEMB 1  0  0  0  0  1
C = CRC-12 (x^12 + x^11 + x^3 + x^2 + x + 1, initial value 0, payload
bit 0 first) of the previous multiblock's 2048 payload bits before
scrambling; M = command channel; EoEMB = last multiblock of an
extended multiblock of cfg_e + 1 multiblocks; 00001 marks the end of
the multiblock and occurs nowhere else.
- Transmit: one block per 66 clocks. tx_ready is high for one clock
when a block's payload is taken from tx_data; without tx_valid the
block carries zeros and tx_underrun pulses. tx_mb_start pulses as a
multiblock starts; tx_cmd is sampled then.
- Receive, sync header alignment: the receiver slides one bit at a time
until a header is valid, locks (sh_lock) after 64 valid headers in a
row, pulses err_sh for each invalid header while locked and unlocks
at the 16th invalid header within a window of 64 headers.
- Receive, multiblock alignment: with sh_lock, a 00001 marks the
multiblock end; the next EoEMB = 1 multiblock gives emb_lock, and
from the next block on every block goes out on rx_data with
rx_mb_start / rx_emb_start. A missing or misplaced 00001 or an EoEMB
where cfg_e does not expect one pulses err_emb and drops the lock
(back to hunting, or to waiting for an EoEMB). With emb_lock each
multiblock end pulses rx_mb_valid with rx_cmd and rx_crc_err (its
CRC field against the previous multiblock; emb_lock comes at a
multiblock end, so that one was always received whole).
Not implemented: multiple lanes, the transport layer (M / N / S / F
mapping), SYSREF / LEMC alignment and deterministic latency, the CRC-3
and FEC sync header modes, pilot bit checks, the 64b/80b mode. The
sync header layout follows JESD204C's CRC-12 mode as we read it; it
has not been checked against a compliant device.

tx_p and rx_p are the serial lane pins (one bit per PCLK); they pass through unchanged.

## Files

| File | Content |
|---|---|
| `rtl/JESD204C_top.sv` | protocol core |
| `rtl/JESD204C_apb.sv` | APB4 register wrapper (generated) |
| `tb/JESD204C_tb.sv` | core testbench |
| `tb/JESD204C_apb_tb.sv`, `tb/apb/JESD204C_apb_func.svh` | wrapper testbench (generated part + IP-specific part) |
| `tb/cov/JESD204C_sva.sv`, `tb/cov/JESD204C_apb_sva.sv` | coverage checkers (core, wrapper) |
| `scripts/apb/specs/JESD204C.json` | register spec the wrapper, TB, checker and this page are generated from |

```
make -f Makefile.JESD204C sim syn            # core test + synthesis (Icarus, Yosys)
make -f Makefile.JESD204C apb                # wrapper test + synthesis
bash scripts/cov/run_cov.sh JESD204C          # core coverage (Verilator)
bash scripts/cov/run_cov.sh JESD204C_apb      # wrapper coverage
```

## Core ports

| Port | Dir | Width | In the APB wrapper |
|---|---|---|---|
| `clk` | input | 1 | PCLK |
| `rst_n` | input | 1 | PRESETN |
| `tx_p` | output | 1 | pin (pass-through) |
| `rx_p` | input | 1 | pin (pass-through) |
| `cfg_e` | input | 4 | CFG[3:0] |
| `tx_valid` | input | 1 | TX commit / FLAGS |
| `tx_ready` | output | 1 | TX handshake |
| `tx_data` | input | 64 | TX0[31:0], TX1[31:0] |
| `tx_cmd` | input | 7 | CMD[6:0] |
| `tx_mb_start` | output | 1 | IRQ_STATUS.TX_MB |
| `tx_underrun` | output | 1 | IRQ_STATUS.TX_UNDERRUN |
| `rx_valid` | output | 1 | RX capture |
| `rx_data` | output | 64 | RX0[31:0], RX1[31:0] |
| `rx_mb_start` | output | 1 | RX2[0:0] |
| `rx_emb_start` | output | 1 | RX2[1:1] |
| `rx_mb_valid` | output | 1 | MB capture |
| `rx_cmd` | output | 7 | MB[6:0] |
| `rx_crc_err` | output | 1 | MB[7:7] |
| `sh_lock` | output | 1 | STATUS[0:0] |
| `emb_lock` | output | 1 | STATUS[1:1] |
| `err_sh` | output | 1 | IRQ_STATUS.ERR_SH |
| `err_emb` | output | 1 | IRQ_STATUS.ERR_EMB |

## APB wrapper

`JESD204C_apb` is an APB4 slave (AMBA APB protocol v2.0): zero wait states, 32-bit data, 12-bit byte address, PSTRB byte lanes on every writable register, PSLVERR on an unmapped or misaligned address (reads then return 0, writes are dropped). Writes to read-only registers are ignored without an error. The core runs on PCLK and PRESETN. `irq` is level-high: `|(IRQ_STATUS & IRQ_ENABLE)`.

Pass-through pins: `tx_p`, `rx_p`.

### Register map

| Offset | Name | Access | Reset | Description |
|---|---|---|---|---|
| 0x000 | ID | RO | 0x4A430200 | IP identification: code, major and minor version |
| 0x004 | IRQ_STATUS | W1C | 0x00000000 | Sticky interrupt bits, write 1 to clear |
| 0x008 | IRQ_ENABLE | RW | 0x00000000 | Interrupt enables; irq = \|(IRQ_STATUS & IRQ_ENABLE) |
| 0x00C | FLAGS | RO | 0x00000000 | Stream holding-register state |
| 0x010 | SCRATCH | RW | 0x00000000 | Scratch register, no effect on the core |
| 0x014 | CFG | RW | 0x00000000 | Extended multiblock length (both ends alike) |
| 0x018 | CMD | RW | 0x00000000 | Command channel |
| 0x01C | TX0 | RW | 0x00000000 | Transmit block payload (TX0 = bits 31:0, TX1 = bits 63:32; writing TX1 commits it); one block goes out every 66 PCLK, a block without data is sent as zeros (TX_UNDERRUN) |
| 0x020 | TX1 | RW | 0x00000000 | Transmit block payload (TX0 = bits 31:0, TX1 = bits 63:32; writing TX1 commits it); one block goes out every 66 PCLK, a block without data is sent as zeros (TX_UNDERRUN) |
| 0x024 | RX0 | RO (pop) | 0x00000000 | Received block (RX0 = bits 31:0, RX1 = bits 63:32, RX2 = start flags; reading RX2 frees it); one arrives every 66 PCLK while emb_lock |
| 0x028 | RX1 | RO (pop) | 0x00000000 | Received block (RX0 = bits 31:0, RX1 = bits 63:32, RX2 = start flags; reading RX2 frees it); one arrives every 66 PCLK while emb_lock |
| 0x02C | RX2 | RO (pop) | 0x00000000 | Received block (RX0 = bits 31:0, RX1 = bits 63:32, RX2 = start flags; reading RX2 frees it); one arrives every 66 PCLK while emb_lock |
| 0x030 | MB | RO (pop) | 0x00000000 | Multiblock received (with emb_lock); reading MB frees it |
| 0x034 | STATUS | RO | 0x00000000 | Receive alignment |

### Fields

| Register | Bits | Field | Description |
|---|---|---|---|
| ID | 31:16 | CODE | 0x4A43 |
| ID | 15:8 | MAJOR | 2 |
| ID | 7:0 | MINOR | 0 |
| CFG | 3:0 | `cfg_e` | multiblocks per extended multiblock - 1 |
| CMD | 6:0 | `tx_cmd` | command sent in each multiblock (sampled as the multiblock starts: IRQ TX_MB) |
| TX0 | 31:0 | `tx_data[31:0]` | payload |
| TX1 | 31:0 | `tx_data[63:32]` | payload |
| RX0 | 31:0 | `rx_data[31:0]` | payload |
| RX1 | 31:0 | `rx_data[63:32]` | payload |
| RX2 | 0 | `rx_mb_start` | first block of a multiblock |
| RX2 | 1 | `rx_emb_start` | first block of an extended multiblock |
| MB | 6:0 | `rx_cmd` | its command |
| MB | 7 | `rx_crc_err` | its CRC field did not match the previous multiblock |
| STATUS | 0 | `sh_lock` | sync header lock |
| STATUS | 1 | `emb_lock` | extended multiblock lock (blocks are delivered) |

### Interrupts (IRQ_STATUS, IRQ_ENABLE)

A bit is set while its source is active, stays set until written with 1, and a set in the same clock as the clear wins.

| Bit | Name | Set when |
|---|---|---|
| 0 | TX_MB | a transmit multiblock started (CMD sampled) |
| 1 | TX_UNDERRUN | a block went out as zeros: TX was empty |
| 2 | ERR_SH | an invalid sync header while locked |
| 3 | ERR_EMB | a multiblock or extended multiblock alignment error |
| 4 | TX_DONE | TX beat accepted by the core |
| 5 | TX_OVF | write to TX while full (dropped) |
| 6 | RX_AVAIL | RX captured a beat |
| 7 | RX_OVF | beat dropped, RX was full |
| 8 | MB_AVAIL | MB captured a beat |
| 9 | MB_OVF | beat dropped, MB was full |

### FLAGS

| Bit | Name | Meaning |
|---|---|---|
| 0 | TX_FULL | TX holds a beat the core has not taken |
| 1 | RX_AVAIL | RX holds an unread beat |
| 2 | MB_AVAIL | MB holds an unread beat |

### Streams

* **TX** feeds `tx_data`/`tx_valid`. Writing TX1 commits the beat: FLAGS.TX_FULL is set and `tx_valid` stays high until the core's `tx_ready`; then TX_DONE is set. A write while full is dropped and sets TX_OVF.
* **RX** captures `rx_data`, `rx_mb_start`, `rx_emb_start` when `rx_valid` is high and the register is empty (or is being read in the same clock), and sets FLAGS/IRQ RX_AVAIL. Reading RX2 pops it. A beat that arrives while the register is full is dropped and sets RX_OVF.
* **MB** captures `rx_cmd`, `rx_crc_err` when `rx_mb_valid` is high and the register is empty (or is being read in the same clock), and sets FLAGS/IRQ MB_AVAIL. Reading MB pops it. A beat that arrives while the register is full is dropped and sets MB_OVF.

## Verification

Five-metric coverage with Verilator 5.052 (`scripts/cov/run_cov.sh`); see [COVERAGE_CLOSURE.md](../COVERAGE_CLOSURE.md) for the flow. Line and toggle count only the named RTL file.

| Scope | Test | Line | Toggle | FSM | SVA | Functional |
|---|---|---|---|---|---|---|
| core `rtl/JESD204C_top.sv` | pass | 74/74 | 1298/1298 | 18/18 | 9/9 | 21/21 |
| wrapper `rtl/JESD204C_apb.sv` | pass | 46/46 | 1094/1094 | n/a | 12/12 | 90/90 |
