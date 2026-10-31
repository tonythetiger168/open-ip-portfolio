# MIPI M-PHY lane: full 8b/10b (256 D-codes, 12 K-codes, running disparity), G1 / G2 bit rates, HIBERN8 with wake burst, and the receiver (comma alignment, decode, code and disparity checks)

Protocol IP `M_PHY`, version 2.0. Apache-2.0.

| Item | Value |
|---|---|
| Core | `M_PHY_top` (`rtl/M_PHY_top.sv`) |
| Register interface | APB4 slave `M_PHY_apb`, 32-bit data, 12-bit byte address, zero wait states |
| Clock, reset | PCLK (rising edge), PRESETN (active low, asynchronous) |
| ID register | 0x4D500200 (code 0x4D50, version 2.0) |
| Registers | 10 words, 0x000 to 0x024 |
| Interrupts | 5 sources into one level-high `irq` |
| Data streams | TX (to the core), RX (from the core) |
| Protocol pins | 4 pass-through |

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

How to run the tests and the coverage flow: see [Running and verifying](#running-and-verifying).

## Parameters

The core and the wrapper have no parameters.

## Wrapper pins

Pins of `M_PHY_apb`. Widths of the pass-through pins are at the default parameters.

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
| `tx_dif_p` | output | 1 | protocol pin, core port `tx_dif_p` |
| `tx_dif_n` | output | 1 | protocol pin, core port `tx_dif_n` |
| `rx_dif_p` | input | 1 | protocol pin, core port `rx_dif_p` |
| `rx_dif_n` | input | 1 | protocol pin, core port `rx_dif_n` |

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
| 0x024 | STATUS | RO | core | Lane state |

Unlisted bits read 0 and ignore writes. Reset "core": the register reads the core's outputs directly, so after reset it shows the core's own reset state. WO (pulse) registers read 0. Offsets from 0x028 up to 0xFFC are unmapped (PSLVERR).

### Fields

| Register | Bits | Field | Access | Reset | Description |
|---|---|---|---|---|---|
| ID | 31:16 | CODE | RO | 0x4D50 | IP code |
| ID | 15:8 | MAJOR | RO | 0x02 | major version |
| ID | 7:0 | MINOR | RO | 0x00 | minor version |
| IRQ_STATUS | 4:0 | one bit per interrupt | W1C | 0x0 | see Interrupts |
| IRQ_ENABLE | 4:0 | one bit per interrupt | RW | 0x0 | 1 enables the IRQ_STATUS bit onto `irq` |
| FLAGS | 1:0 | one bit per stream flag | RO | 0x0 | see FLAGS |
| SCRATCH | 31:0 | SCRATCH | RW | 0x00000000 | free for software |
| CMD | 0 | `hibern8_req` | WO (pulse) | 0x0 | write 1: enter HIBERN8 (SAVE state, lines DIF-Z) once the lane is idle; a buffered byte goes first |
| CMD | 1 | `wake_req` | WO (pulse) | 0x0 | write 1: leave HIBERN8 (8-clock DIF-N wake burst) |
| CMD | 2 | `irq_clear` | WO (pulse) | 0x0 | write 1: clear the sticky receive / transmit error (an error in the same clock wins) |
| CFG | 0 | `gear` | RW | 0x0 | 0: G1 (1 bit per clock), 1: G2 (1 bit per 2 clocks); change only while the lane is idle (a change while locked makes the receiver re-hunt) |
| TX | 7:0 | `tx_data` | RW | 0x0 | byte |
| TX | 8 | `tx_k` | RW | 0x0 | 1: control code (K28.0-7, K23.7, K27.7, K29.7, K30.7; other K-codes are dropped with ERROR) |
| RX | 7:0 | `rx_data` | RO (pop) | 0x0 | byte |
| RX | 8 | `rx_k` | RO (pop) | 0x0 | control code |
| STATUS | 0 | `hibern8` | RO | core | the transmitter is in HIBERN8 |
| STATUS | 1 | `rx_locked` | RO | core | the receiver found the comma and frames 10-bit words |
| STATUS | 2 | `rx_hibern` | RO | core | the receive line is in DIF-Z (hibernated) |

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

## Programming sequence

1. Release PRESETN. Read ID (0x000) and check it is 0x4D500200.
2. Write 0x1F to IRQ_STATUS (0x004) to clear any stale bits.
3. Configure the core: write CFG (0x018). Reset values are in the register map; PSTRB selects the bytes written.
4. Write IRQ_ENABLE (0x008) with the interrupts to use (bit order as in the Interrupts table; 0x1F enables all).
5. To issue a command, write 1 to `hibern8_req` (CMD bit 0), `wake_req` (CMD bit 1), `irq_clear` (CMD bit 2) at 0x014; the core sees a one-clock pulse, and the register reads 0.
6. To send on TX: wait until FLAGS.TX_FULL (bit 0) is 0, or for IRQ TX_DONE, then write TX (0x01C). The last write commits the beat. TX_OVF means a write came while the register was full and was dropped.
7. To receive on RX: wait for IRQ RX_AVAIL or FLAGS.RX_AVAIL (bit 1), then read RX (0x020). Reading the last word frees the register for the next beat; write 1 to IRQ_STATUS.RX_AVAIL (bit 3) to clear it. Read each beat before the next arrives, or it is dropped and RX_OVF is set.
8. Read STATUS (0x024) for the core's live `hibern8`, `rx_locked`, `rx_hibern`; it needs no clearing.
9. On `irq`: read IRQ_STATUS, handle every bit that is set and enabled, then write those bits back to IRQ_STATUS to clear them. A source that is still active sets its bit again.

## Running and verifying

All commands run from the repository root. Icarus Verilog 12 and Yosys 0.33 are enough for steps 1 to 3; step 4 also needs Verilator 5.052 and pyslang (see [README, Setup](../../README.md#setup)).

| Step | Command | Pass when | Output |
|---|---|---|---|
| 1. Core test | `make -f Makefile.M_PHY sim` | a `TEST PASSED` line, no `ERROR` | console |
| 2. Core synthesis | `make -f Makefile.M_PHY syn` | Yosys ends without `ERROR`; `stat` prints the cell count | `work/M_PHY_top.json` |
| 3. APB wrapper test + synthesis | `make -f Makefile.M_PHY apb` | `TEST PASSED: M_PHY_apb`, then Yosys without `ERROR` | console, `work/M_PHY_apb.json` |
| 4. Coverage (core, wrapper) | `bash scripts/cov/run_cov.sh M_PHY`<br>`bash scripts/cov/run_cov.sh M_PHY_apb` | `RESULT: CLOSED` (all five metrics 100%) | `work/cov/M_PHY/score.json`, `work/cov/M_PHY_apb/score.json` |

Expected end of a step 4 run:

```
===== M_PHY =====
TEST: PASSED   SVA_FAILURES: 0
LINE ... TOGGLE ... FSM ... SVA ... FUNCTIONAL  (each n/n, 100.0%)
RESULT: CLOSED
```

**Core test** (`tb/M_PHY_tb.sv`): drives `M_PHY_top` through its own ports against a protocol peer or model and checks every result itself; any mismatch prints `ERROR`, and `TEST PASSED` is printed only when there were none.

**APB wrapper test** (`tb/M_PHY_apb_tb.sv`), in this order:

1. Reset values of every register, ID included.
2. Writes to read-only registers are ignored.
3. Each RW register: all ones, all zeros, then 16 random writes with every PSTRB byte-lane pattern, read back each time.
4. Unmapped and misaligned addresses, reads and writes: PSLVERR, read data 0, no side effect on other registers.
5. Back-to-back transfers with no idle cycle.
6. IP traffic through the registers only (`tb/apb/M_PHY_apb_func.svh`): the programming sequence above, every interrupt bit set, enabled and cleared, stream FULL/AVAIL/OVF cases (100% wrapper toggle coverage confirms each bit moved).
7. PRESETN asserted mid-run: `irq` and PRDATA go to 0, registers return to reset values.

**Checkers** (`tb/cov/M_PHY_sva.sv`, `tb/cov/M_PHY_apb_sva.sv`): SVA protocol and APB assertions plus covergroups, bound in by the coverage flow. An assertion failure prints `SVA_FAIL` and fails the run even when the test itself passed.

Whole portfolio: `bash scripts/ci_regression.sh` runs steps 1 to 3 for every IP (what CI runs), and `bash scripts/cov/run_all.sh 4` runs step 4 for every IP.

## Verification

Five-metric coverage with Verilator 5.052 (`scripts/cov/run_cov.sh`); see [COVERAGE_CLOSURE.md](../COVERAGE_CLOSURE.md) for the flow. Line and toggle count only the named RTL file.

| Scope | Test | Line | Toggle | FSM | SVA | Functional |
|---|---|---|---|---|---|---|
| core `rtl/M_PHY_top.sv` | pass | 120/120 (+1 excl.) | 392/392 | 16/16 | 8/8 | 286/286 |
| wrapper `rtl/M_PHY_apb.sv` | pass | 36/36 | 542/542 | n/a | 14/14 | 60/60 |
