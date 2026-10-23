# MIPI M-PHY lane: full 8b/10b (256 D-codes, 12 K-codes, running disparity), G1 / G2 bit rates, HIBERN8 with wake burst, and the receiver (comma alignment, decode, code and disparity checks)

Protocol IP `M_PHY`, version 2.0. Apache-2.0.

## Overview

MIPI M-PHY lane (8b/10b, PWM-gear rates, HIBERN8) with loopback decoder Implementation scope: * Full 8b/10b codec: all 256 D-codes and the 12 K-codes (K28.0..K28.7, K23.7, K27.7, K29.7, K30.7), standard 5b/6b and 3b/4b tables with the D.x.A7 and K28 comma rules and running-disparity (RD) tracking. The TX rejects other K-codes (dropped, irq). The RX decodes each word and re-encodes it with the current RD, so any code or disparity violation raises irq. * PWM gears simplified to NRZ bit-rate division (real M-PHY TYPE-I uses PWM pulse widths at LS gears; the gearing itself is kept): G1 = 1 bit per clk, G2 = 1 bit per 2 clk, selected by the gear input. Gear may only change while the lane is idle (documented host contract). * Line states on tx_dif_p/tx_dif_n: DIF-N (0,1) = idle / bit 0, DIF-P (1,0) = bit 1, DIF-Z (0,0) = high-Z during HIBERN8. * HIBERN8: hibern8_req enters the SAVE state (hibern8 power-down flag raised, lines DIF-Z); wake_req drives an 8-clk DIF-N wake burst and returns to normal idle. RX detects DIF-Z persistence as hibernation and re-hunts after wake. * Bursts: K28.5 comma (bit 'a' first) for RX alignment, then 8b/10b data words back-to-back; a 1-deep buffer keeps the stream seamless. RX hunts for the comma (clk-resolution shift register, gear-aware), then frames every 10 bits; an all-zero idle word ends the burst and returns the RX to hunt. The TX therefore keeps the line idle for at least 10 bit times between bursts (inter-burst STALL), so the RX always sees that idle word and re-acquires the comma of the next burst.


tx_dif_p / tx_dif_n (transmit line) and rx_dif_p / rx_dif_n (receive line) pass through unchanged: DIF-N (0,1) idle or bit 0, DIF-P (1,0) bit 1, DIF-Z (0,0) hibernated.
At G1 a byte takes 10 clocks: TX must be written, and RX read, at that rate (RX holds one byte; a byte arriving with RX full is dropped, RX_OVF).

## Files

| File | Content |
|---|---|
| `rtl/M_PHY_top.sv` | protocol core |
| `rtl/M_PHY_apb.sv` | APB4 register wrapper (generated) |
| `tb/M_PHY_tb.sv` | core testbench |
| `tb/M_PHY_apb_tb.sv`, `tb/apb/M_PHY_apb_func.svh` | wrapper testbench (generated part + IP-specific part) |
| `tb/cov/M_PHY_sva.sv`, `tb/cov/M_PHY_apb_sva.sv` | coverage checkers (core, wrapper) |
| `scripts/apb/specs/M_PHY.json` | register spec the wrapper, TB, checker and this page are generated from |

```
make -f Makefile.M_PHY sim syn            # core test + synthesis (Icarus, Yosys)
make -f Makefile.M_PHY apb                # wrapper test + synthesis
bash scripts/cov/run_cov.sh M_PHY          # core coverage (Verilator)
bash scripts/cov/run_cov.sh M_PHY_apb      # wrapper coverage
```

## Core ports

| Port | Dir | Width | In the APB wrapper |
|---|---|---|---|
| `clk` | input | 1 | PCLK |
| `rst_n` | input | 1 | PRESETN |
| `irq` | output | 1 | IRQ_STATUS.ERROR |
| `irq_clear` | input | 1 | CMD[2:2] |
| `gear` | input | 1 | CFG |
| `hibern8_req` | input | 1 | CMD[0:0] |
| `wake_req` | input | 1 | CMD[1:1] |
| `hibern8` | output | 1 | STATUS[0:0] |
| `tx_data` | input | 8 | TX[7:0] |
| `tx_k` | input | 1 | TX[8:8] |
| `tx_valid` | input | 1 | TX commit / FLAGS |
| `tx_ready` | output | 1 | TX handshake |
| `tx_dif_p` | output | 1 | pin (pass-through) |
| `tx_dif_n` | output | 1 | pin (pass-through) |
| `rx_dif_p` | input | 1 | pin (pass-through) |
| `rx_dif_n` | input | 1 | pin (pass-through) |
| `rx_locked` | output | 1 | STATUS[1:1] |
| `rx_hibern` | output | 1 | STATUS[2:2] |
| `rx_data` | output | 8 | RX[7:0] |
| `rx_k` | output | 1 | RX[8:8] |
| `rx_valid` | output | 1 | RX capture |

## APB wrapper

`M_PHY_apb` is an APB4 slave (AMBA APB protocol v2.0): zero wait states, 32-bit data, 12-bit byte address, PSTRB byte lanes on every writable register, PSLVERR on an unmapped or misaligned address (reads then return 0, writes are dropped). Writes to read-only registers are ignored without an error. The core runs on PCLK and PRESETN. `irq` is level-high: `|(IRQ_STATUS & IRQ_ENABLE)`.

Pass-through pins: `tx_dif_p`, `tx_dif_n`, `rx_dif_p`, `rx_dif_n`.

### Register map

| Offset | Name | Access | Reset | Description |
|---|---|---|---|---|
| 0x000 | ID | RO | 0x4D500200 | IP identification: code, major and minor version |
| 0x004 | IRQ_STATUS | W1C | 0x00000000 | Sticky interrupt bits, write 1 to clear |
| 0x008 | IRQ_ENABLE | RW | 0x00000000 | Interrupt enables; irq = \|(IRQ_STATUS & IRQ_ENABLE) |
| 0x00C | FLAGS | RO | 0x00000000 | Stream holding-register state |
| 0x010 | SCRATCH | RW | 0x00000000 | Scratch register, no effect on the core |
| 0x014 | CMD | WO (pulse) | 0x00000000 | Commands |
| 0x018 | CFG | RW | 0x00000000 | Gear |
| 0x01C | TX | RW | 0x00000000 | Byte to send; start each burst with the comma K28.5 (0xBC with K). A byte every 10 bit times keeps the burst going; a gap ends it |
| 0x020 | RX | RO (pop) | 0x00000000 | Byte decoded by the receiver (the comma included); reading RX frees it |
| 0x024 | STATUS | RO | 0x00000000 | Lane state |

### Fields

| Register | Bits | Field | Description |
|---|---|---|---|
| ID | 31:16 | CODE | 0x4D50 |
| ID | 15:8 | MAJOR | 2 |
| ID | 7:0 | MINOR | 0 |
| CMD | 0 | `hibern8_req` | write 1: enter HIBERN8 (SAVE state, lines DIF-Z) once the lane is idle; a buffered byte goes first |
| CMD | 1 | `wake_req` | write 1: leave HIBERN8 (8-clock DIF-N wake burst) |
| CMD | 2 | `irq_clear` | write 1: clear the sticky receive / transmit error (an error in the same clock wins) |
| CFG | 0 | `gear` | 0: G1 (1 bit per clock), 1: G2 (1 bit per 2 clocks); change only while the lane is idle (a change while locked makes the receiver re-hunt) |
| TX | 7:0 | `tx_data` | byte |
| TX | 8 | `tx_k` | 1: control code (K28.0-7, K23.7, K27.7, K29.7, K30.7; other K-codes are dropped with ERROR) |
| RX | 7:0 | `rx_data` | byte |
| RX | 8 | `rx_k` | control code |
| STATUS | 0 | `hibern8` | the transmitter is in HIBERN8 |
| STATUS | 1 | `rx_locked` | the receiver found the comma and frames 10-bit words |
| STATUS | 2 | `rx_hibern` | the receive line is in DIF-Z (hibernated) |

### Interrupts (IRQ_STATUS, IRQ_ENABLE)

A bit is set while its source is active, stays set until written with 1, and a set in the same clock as the clear wins.

| Bit | Name | Set when |
|---|---|---|
| 0 | ERROR | an unsupported K-code was dropped, or the receiver saw an invalid code or a disparity error; sticky in the core, so the bit is set again on every clock until CMD.irq_clear |
| 1 | TX_DONE | TX beat accepted by the core |
| 2 | TX_OVF | write to TX while full (dropped) |
| 3 | RX_AVAIL | RX captured a beat |
| 4 | RX_OVF | beat dropped, RX was full |

### FLAGS

| Bit | Name | Meaning |
|---|---|---|
| 0 | TX_FULL | TX holds a beat the core has not taken |
| 1 | RX_AVAIL | RX holds an unread beat |

### Streams

* **TX** feeds `tx_data`, `tx_k`/`tx_valid`. Writing TX commits the beat: FLAGS.TX_FULL is set and `tx_valid` stays high until the core's `tx_ready`; then TX_DONE is set. A write while full is dropped and sets TX_OVF.
* **RX** captures `rx_data`, `rx_k` when `rx_valid` is high and the register is empty (or is being read in the same clock), and sets FLAGS/IRQ RX_AVAIL. Reading RX pops it. A beat that arrives while the register is full is dropped and sets RX_OVF.

## Verification

Five-metric coverage with Verilator 5.052 (`scripts/cov/run_cov.sh`); see [COVERAGE_CLOSURE.md](../COVERAGE_CLOSURE.md) for the flow. Line and toggle count only the named RTL file.

| Scope | Test | Line | Toggle | FSM | SVA | Functional |
|---|---|---|---|---|---|---|
| core `rtl/M_PHY_top.sv` | pass | 120/120 (+1 excl.) | 392/392 | 16/16 | 8/8 | 286/286 |
| wrapper `rtl/M_PHY_apb.sv` | pass | 36/36 | 542/542 | n/a | 14/14 | 60/60 |
