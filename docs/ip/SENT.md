# SAE J2716 SENT (Single Edge Nibble Transmission) transmitter and receiver with the slow serial channel (short and enhanced messages)

Protocol IP `SENT`, version 1.0. Apache-2.0.

| Item | Value |
|---|---|
| Core | `SENT_top` (`rtl/SENT_top.sv`) |
| Register interface | APB4 slave `SENT_apb`, 32-bit data, 12-bit byte address, zero wait states |
| Clock, reset | PCLK (rising edge), PRESETN (active low, asynchronous) |
| ID register | 0x4A320100 (code 0x4A32, version 1.0) |
| Registers | 16 words, 0x000 to 0x03C |
| Interrupts | 13 sources into one level-high `irq` |
| Data streams | RX (from the core), SER_RX (from the core) |
| Protocol pins | 2 pass-through |

## Overview

SENT_top v1.0: SAE J2716 SENT (Single Edge Nibble Transmission) transmitter and receiver, with the slow serial channel

- Line coding: every pulse starts with a falling edge, stays low for at
least 4 ticks and high for the rest; the time between two falling
edges carries the symbol. A frame is a 56-tick calibration (sync)
pulse, the status & communication nibble, 1..6 data nibbles and the
CRC nibble (each nibble 12 + value ticks, 12..27), optionally followed
by a pause pulse (12..768 ticks).
- CRC: 4 bits, x^4 + x^3 + x^2 + 1, seed 0101, over the data nibbles
(not the status nibble); the recommended form appends a zero nibble,
cfg_crc_legacy = 1 leaves it out (pre-2010 sensors).
- Slow serial channel in bits 3:2 of the status nibble:
* short message: 16 frames, bit 3 = 1 0 0 .. 0, bit 2 = 4-bit ID,
8-bit data and a 4-bit CRC of ID and data (same CRC and form as
the fast channel);
* enhanced message: 18 frames, bit 3 = 1 1 1 1 1 1 0 C a3..a0 0
b3..b0 0, bit 2 = a 6-bit CRC (frames 1..6) then 12 data bits
(frames 7..18), all MSB first; C = 0: 8-bit ID {a, b} and 12-bit
data, C = 1: 4-bit ID a and 16-bit data {b, 12 bits}. The CRC
(x^6 + x^4 + x^3 + 1, seed 010101, a zero 6-bit word appended)
covers bit 2 then bit 3 of frames 7..18.
- Transmitter (sensor side): tick = cfg_tx_tick_clks clocks, low part
cfg_tx_low_ticks; frames back to back while tx_en. tx_status /
tx_data are taken at tx_frame_start (the sync pulse's falling edge);
data nibble i is tx_data[4i+3:4i]. Pause: cfg_tx_pause_mode 0 none,
1 a pause of cfg_tx_pause ticks, 2 a constant frame of cfg_tx_pause
ticks (the pause fills it up, at least 12 ticks). ser_tx_start sends
a serial message from the next frame on; it owns status bits 3:2 for
16 / 18 frames (ser_tx_busy, then ser_tx_done).
- Receiver (ECU side): sent_in is synchronised and glitch filtered
(stable for cfg_rx_filt clocks). Any period within +-25 % of 56
nominal ticks (cfg_rx_tick_clks) is a calibration pulse and sets the
tick; every other period is rounded to whole ticks of that pulse.
A frame with valid nibbles, low parts >= 4 ticks and the right CRC
gives rx_valid (data nibbles past cfg_rx_nibbles read 0); errors
pulse rx_err_* and the receiver hunts for the
next calibration pulse. cfg_rx_pause: a pause pulse must follow the
CRC nibble. cfg_rx_cal_check: a calibration pulse that differs from
the one before by more than 1/64 drops its frame (rx_err_cal). The
serial decoder checks the last 16 / 18 good frames after every frame
(ser_rx_valid / ser_rx_err_crc); a bad frame restarts it.
Limits: cfg_*_tick_clks 4..4095 clocks (a period counter of 22 bits
saturates, so longer idle times read as one long period).
Not implemented: SPC (short PWM code) master triggers, the J2716 APR
2016 tick-time variants beyond the configurable tick, and the fast
channel message formats (H.1..H.7) which are only data interpretations.

Features:

- Transmitter: programmable tick (4..4095 PCLK cycles), low time, 1..6 data nibbles, no pause, a fixed pause or constant-length frames
- Receiver: synchroniser and glitch filter, calibration pulse within +-25 % sets the tick, ticks rounded from the measured calibration pulse, optional 1/64 drift check
- CRC-4 (recommended and legacy) on the fast channel; short (4-bit CRC) and enhanced (6-bit CRC, 8-bit ID / 12-bit data or 4-bit ID / 16-bit data) serial messages both ways
- Errors reported one by one: nibble, low time, CRC, pause, missing sync, calibration drift, serial CRC

sent_out is the open-drain style output (1 = released); sent_in is the line as received (it may be sent_out for a loopback).
The receiver holds one frame and one serial message; a frame that arrives while RX is full is dropped and sets RX_OVF.
Not implemented: SPC (short PWM code) master triggers; the fast channel formats (H.1..H.7) are data interpretations left to software.

## Files

| File | Content |
|---|---|
| `rtl/SENT_top.sv` | protocol core |
| `rtl/SENT_apb.sv` | APB4 register wrapper (generated) |
| `tb/SENT_tb.sv` | core testbench |
| `tb/SENT_apb_tb.sv`, `tb/apb/SENT_apb_func.svh` | wrapper testbench (generated part + IP-specific part) |
| `tb/cov/SENT_sva.sv`, `tb/cov/SENT_apb_sva.sv` | coverage checkers (core, wrapper) |
| `scripts/apb/specs/SENT.json` | register spec the wrapper, TB, checker and this page are generated from |

How to run the tests and the coverage flow: see [Running and verifying](#running-and-verifying).

## Parameters

The core and the wrapper have no parameters.

## Wrapper pins

Pins of `SENT_apb`. Widths of the pass-through pins are at the default parameters.

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
| `sent_out` | output | 1 | protocol pin, core port `sent_out` |
| `sent_in` | input | 1 | protocol pin, core port `sent_in` |

## Core ports

| Port | Dir | Width | In the APB wrapper |
|---|---|---|---|
| `clk` | input | 1 | PCLK |
| `rst_n` | input | 1 | PRESETN |
| `cfg_crc_legacy` | input | 1 | CTRL[1:1] |
| `tx_en` | input | 1 | CTRL[0:0] |
| `cfg_tx_tick_clks` | input | 12 | TX_CFG[11:0] |
| `cfg_tx_low_ticks` | input | 4 | TX_CFG[15:12] |
| `cfg_tx_nibbles` | input | 3 | TX_CFG[18:16] |
| `cfg_tx_pause_mode` | input | 2 | TX_CFG[20:19] |
| `cfg_tx_pause` | input | 11 | TX_PAUSE[10:0] |
| `tx_status` | input | 4 | TX_FRAME[3:0] |
| `tx_data` | input | 24 | TX_FRAME[27:4] |
| `tx_frame_start` | output | 1 | IRQ_STATUS.TX_FRAME |
| `sent_out` | output | 1 | pin (pass-through) |
| `ser_tx_start` | input | 1 | CMD |
| `ser_tx_enh` | input | 1 | SER_TX[24:24] |
| `ser_tx_cfg` | input | 1 | SER_TX[25:25] |
| `ser_tx_id` | input | 8 | SER_TX[7:0] |
| `ser_tx_data` | input | 16 | SER_TX[23:8] |
| `ser_tx_busy` | output | 1 | STATUS |
| `ser_tx_done` | output | 1 | IRQ_STATUS.SER_TX_DONE |
| `sent_in` | input | 1 | pin (pass-through) |
| `cfg_rx_tick_clks` | input | 12 | RX_CFG[11:0] |
| `cfg_rx_nibbles` | input | 3 | RX_CFG[14:12] |
| `cfg_rx_pause` | input | 1 | CTRL[2:2] |
| `cfg_rx_cal_check` | input | 1 | CTRL[3:3] |
| `cfg_rx_filt` | input | 4 | RX_CFG[18:15] |
| `rx_valid` | output | 1 | RX capture |
| `rx_status` | output | 4 | RX0[3:0] |
| `rx_data` | output | 24 | RX0[27:4] |
| `rx_cal_clks` | output | 19 | RX1[18:0] |
| `rx_err_nibble` | output | 1 | IRQ_STATUS.ERR_NIBBLE |
| `rx_err_low` | output | 1 | IRQ_STATUS.ERR_LOW |
| `rx_err_crc` | output | 1 | IRQ_STATUS.ERR_CRC |
| `rx_err_pause` | output | 1 | IRQ_STATUS.ERR_PAUSE |
| `rx_err_sync` | output | 1 | IRQ_STATUS.ERR_SYNC |
| `rx_err_cal` | output | 1 | IRQ_STATUS.ERR_CAL |
| `ser_rx_valid` | output | 1 | SER_RX capture |
| `ser_rx_enh` | output | 1 | SER_RX[0:0] |
| `ser_rx_cfg` | output | 1 | SER_RX[1:1] |
| `ser_rx_id` | output | 8 | SER_RX[9:2] |
| `ser_rx_data` | output | 16 | SER_RX[25:10] |
| `ser_rx_err_crc` | output | 1 | IRQ_STATUS.SER_CRC |

## APB wrapper

`SENT_apb` is an APB4 slave (AMBA APB protocol v2.0): zero wait states, 32-bit data, 12-bit byte address, PSTRB byte lanes on every writable register, PSLVERR on an unmapped or misaligned address (reads then return 0, writes are dropped). Writes to read-only registers are ignored without an error. The core runs on PCLK and PRESETN. `irq` is level-high: `|(IRQ_STATUS & IRQ_ENABLE)`.

Pass-through pins: `sent_out`, `sent_in`.

### Register map

| Offset | Name | Access | Reset | Description |
|---|---|---|---|---|
| 0x000 | ID | RO | 0x4A320100 | IP identification: code, major and minor version |
| 0x004 | IRQ_STATUS | W1C | 0x00000000 | Sticky interrupt bits, write 1 to clear |
| 0x008 | IRQ_ENABLE | RW | 0x00000000 | Interrupt enables; irq = \|(IRQ_STATUS & IRQ_ENABLE) |
| 0x00C | FLAGS | RO | 0x00000000 | Stream holding-register state |
| 0x010 | SCRATCH | RW | 0x00000000 | Scratch register, no effect on the core |
| 0x014 | CTRL | RW | 0x00000000 | Control |
| 0x018 | TX_CFG | RW | 0x00065096 | Transmitter timing and format |
| 0x01C | TX_PAUSE | RW | 0x00000000 | Pause length or constant frame length |
| 0x020 | TX_FRAME | RW | 0x00000000 | Next frame's content, taken when a frame starts (IRQ TX_FRAME) |
| 0x024 | SER_TX | RW | 0x00000000 | Serial message to send |
| 0x028 | CMD | WO (pulse) | 0x00000000 | Commands |
| 0x02C | RX_CFG | RW | 0x00016096 | Receiver |
| 0x030 | STATUS | RO | core | Status |
| 0x034 | RX0 | RO (pop) | 0x00000000 | Received frame; reading RX1 frees it |
| 0x038 | RX1 | RO (pop) | 0x00000000 | Received frame; reading RX1 frees it |
| 0x03C | SER_RX | RO (pop) | 0x00000000 | Received serial message; reading SER_RX frees it |

Unlisted bits read 0 and ignore writes. Reset "core": the register reads the core's outputs directly, so after reset it shows the core's own reset state. WO (pulse) registers read 0. Offsets from 0x040 up to 0xFFC are unmapped (PSLVERR).

### Fields

| Register | Bits | Field | Access | Reset | Description |
|---|---|---|---|---|---|
| ID | 31:16 | CODE | RO | 0x4A32 | IP code |
| ID | 15:8 | MAJOR | RO | 0x01 | major version |
| ID | 7:0 | MINOR | RO | 0x00 | minor version |
| IRQ_STATUS | 12:0 | one bit per interrupt | W1C | 0x0 | see Interrupts |
| IRQ_ENABLE | 12:0 | one bit per interrupt | RW | 0x0 | 1 enables the IRQ_STATUS bit onto `irq` |
| FLAGS | 1:0 | one bit per stream flag | RO | 0x0 | see FLAGS |
| SCRATCH | 31:0 | SCRATCH | RW | 0x00000000 | free for software |
| CTRL | 0 | `tx_en` | RW | 0x0 | 1 = send frames back to back |
| CTRL | 1 | `cfg_crc_legacy` | RW | 0x0 | 1 = the pre-2010 CRC (no appended zero nibble), both directions |
| CTRL | 2 | `cfg_rx_pause` | RW | 0x0 | 1 = a pause pulse must follow the CRC nibble |
| CTRL | 3 | `cfg_rx_cal_check` | RW | 0x0 | 1 = drop a frame whose calibration pulse is more than 1/64 off the one before |
| TX_CFG | 11:0 | `cfg_tx_tick_clks` | RW | 0x96 | PCLK cycles per tick, 4..4095 (150: 3 us at 50 MHz) |
| TX_CFG | 15:12 | `cfg_tx_low_ticks` | RW | 0x5 | low part of every pulse in ticks, 4..11 (clamped) |
| TX_CFG | 18:16 | `cfg_tx_nibbles` | RW | 0x6 | data nibbles, 1..6 (0 = 1, 7 = 6) |
| TX_CFG | 20:19 | `cfg_tx_pause_mode` | RW | 0x0 | 0 no pause, 1 a fixed pause of TX_PAUSE ticks, 2 / 3 constant frames of TX_PAUSE ticks |
| TX_PAUSE | 10:0 | `cfg_tx_pause` | RW | 0x0 | ticks (the pause itself is clamped to 12..768) |
| TX_FRAME | 3:0 | `tx_status` | RW | 0x0 | status and communication nibble (bits 3:2 are the serial channel's while SER_TX runs) |
| TX_FRAME | 27:4 | `tx_data` | RW | 0x0 | data nibbles, nibble i in bits 4i+3:4i, nibble 0 sent first |
| SER_TX | 7:0 | `ser_tx_id` | RW | 0x0 | message ID (short: 4 bits, enhanced: 8 bits or 4 with ser_tx_cfg) |
| SER_TX | 23:8 | `ser_tx_data` | RW | 0x0 | data (short: 8 bits, enhanced: 12 bits or 16 with ser_tx_cfg) |
| SER_TX | 24 | `ser_tx_enh` | RW | 0x0 | 1 = enhanced message (18 frames), 0 = short (16 frames) |
| SER_TX | 25 | `ser_tx_cfg` | RW | 0x0 | enhanced configuration bit C: 1 = 4-bit ID, 16-bit data |
| CMD | 0 | `ser_tx_start` | WO (pulse) | 0x0 | 1 = send SER_TX from the next frame on (ignored while one is sent) |
| RX_CFG | 11:0 | `cfg_rx_tick_clks` | RW | 0x96 | nominal PCLK cycles per tick; calibration pulses within +-25 % are accepted |
| RX_CFG | 14:12 | `cfg_rx_nibbles` | RW | 0x6 | data nibbles, 1..6 (0 = 1, 7 = 6) |
| RX_CFG | 18:15 | `cfg_rx_filt` | RW | 0x2 | glitch filter: the line must be stable for this many PCLK cycles |
| STATUS | 0 | `ser_tx_busy` | RO | core | a serial message is being sent |
| RX0 | 3:0 | `rx_status` | RO (pop) | 0x0 | status and communication nibble |
| RX0 | 27:4 | `rx_data` | RO (pop) | 0x0 | data nibbles (nibble i in bits 4i+3:4i; past RX_CFG nibbles read 0) |
| RX1 | 18:0 | `rx_cal_clks` | RO (pop) | 0x0 | calibration pulse of the frame in PCLK cycles (56 ticks) |
| SER_RX | 0 | `ser_rx_enh` | RO (pop) | 0x0 | 1 = enhanced message |
| SER_RX | 1 | `ser_rx_cfg` | RO (pop) | 0x0 | enhanced configuration bit C |
| SER_RX | 9:2 | `ser_rx_id` | RO (pop) | 0x0 | message ID |
| SER_RX | 25:10 | `ser_rx_data` | RO (pop) | 0x0 | message data |

### Interrupts (IRQ_STATUS, IRQ_ENABLE)

A bit is set while its source is active, stays set until written with 1, and a set in the same clock as the clear wins.

| Bit | Name | Set when |
|---|---|---|
| 0 | TX_FRAME | a frame started (TX_FRAME was taken) |
| 1 | SER_TX_DONE | the serial message went out with its last frame |
| 2 | ERR_NIBBLE | a period that is no nibble, or a calibration pulse inside a frame |
| 3 | ERR_LOW | a low part shorter than 3.5 ticks |
| 4 | ERR_CRC | wrong CRC nibble |
| 5 | ERR_PAUSE | a pause outside 12..768 ticks |
| 6 | ERR_SYNC | no calibration pulse where one was due |
| 7 | ERR_CAL | a calibration pulse more than 1/64 off the previous one (the frame is dropped) |
| 8 | SER_CRC | a serial message with a wrong CRC |
| 9 | RX_AVAIL | RX captured a beat |
| 10 | RX_OVF | beat dropped, RX was full |
| 11 | SER_RX_AVAIL | SER_RX captured a beat |
| 12 | SER_RX_OVF | beat dropped, SER_RX was full |

### FLAGS

| Bit | Name | Meaning |
|---|---|---|
| 0 | RX_AVAIL | RX holds an unread beat |
| 1 | SER_RX_AVAIL | SER_RX holds an unread beat |

### Streams

* **RX** captures `rx_status`, `rx_data`, `rx_cal_clks` when `rx_valid` is high and the register is empty (or is being read in the same clock), and sets FLAGS/IRQ RX_AVAIL. Reading RX1 pops it. A beat that arrives while the register is full is dropped and sets RX_OVF.
* **SER_RX** captures `ser_rx_enh`, `ser_rx_cfg`, `ser_rx_id`, `ser_rx_data` when `ser_rx_valid` is high and the register is empty (or is being read in the same clock), and sets FLAGS/IRQ SER_RX_AVAIL. Reading SER_RX pops it. A beat that arrives while the register is full is dropped and sets SER_RX_OVF.

## Programming sequence

1. Release PRESETN. Read ID (0x000) and check it is 0x4A320100.
2. Write 0x1FFF to IRQ_STATUS (0x004) to clear any stale bits.
3. Configure the core: write CTRL (0x014), TX_CFG (0x018), TX_PAUSE (0x01C), TX_FRAME (0x020), SER_TX (0x024), RX_CFG (0x02C). Reset values are in the register map; PSTRB selects the bytes written.
4. Write IRQ_ENABLE (0x008) with the interrupts to use (bit order as in the Interrupts table; 0x1FFF enables all).
5. To issue a command, write 1 to `ser_tx_start` (CMD bit 0) at 0x028; the core sees a one-clock pulse, and the register reads 0.
6. Read STATUS (0x030) for the core's live `ser_tx_busy`; it needs no clearing.
7. To receive on RX: wait for IRQ RX_AVAIL or FLAGS.RX_AVAIL (bit 0), then read RX0 (0x034) then RX1 (0x038). Reading the last word frees the register for the next beat; write 1 to IRQ_STATUS.RX_AVAIL (bit 9) to clear it. Read each beat before the next arrives, or it is dropped and RX_OVF is set.
8. To receive on SER_RX: wait for IRQ SER_RX_AVAIL or FLAGS.SER_RX_AVAIL (bit 1), then read SER_RX (0x03C). Reading the last word frees the register for the next beat; write 1 to IRQ_STATUS.SER_RX_AVAIL (bit 11) to clear it. Read each beat before the next arrives, or it is dropped and SER_RX_OVF is set.
9. On `irq`: read IRQ_STATUS, handle every bit that is set and enabled, then write those bits back to IRQ_STATUS to clear them. A source that is still active sets its bit again.

IP-specific use:

1. Transmit: TX_CFG, TX_PAUSE, TX_FRAME, then CTRL.tx_en; on IRQ TX_FRAME write the next TX_FRAME. Serial: write SER_TX, CMD.ser_tx_start, wait for IRQ SER_TX_DONE.
2. Receive: RX_CFG and CTRL, IRQ_ENABLE; on IRQ RX_AVAIL read RX0, RX1; on SER_RX_AVAIL read SER_RX; error bits as they come.

## Running and verifying

All commands run from the repository root. Icarus Verilog 12 and Yosys 0.33 are enough for steps 1 to 3; step 4 also needs Verilator 5.052 and pyslang (see [README, Setup](../../README.md#setup)).

| Step | Command | Pass when | Output |
|---|---|---|---|
| 1. Core test | `make -f Makefile.SENT sim` | a `TEST PASSED` line, no `ERROR` | console |
| 2. Core synthesis | `make -f Makefile.SENT syn` | Yosys ends without `ERROR`; `stat` prints the cell count | `work/SENT_top.json` |
| 3. APB wrapper test + synthesis | `make -f Makefile.SENT apb` | `TEST PASSED: SENT_apb`, then Yosys without `ERROR` | console, `work/SENT_apb.json` |
| 4. Coverage (core, wrapper) | `bash scripts/cov/run_cov.sh SENT`<br>`bash scripts/cov/run_cov.sh SENT_apb` | `RESULT: CLOSED` (all five metrics 100%) | `work/cov/SENT/score.json`, `work/cov/SENT_apb/score.json` |

Expected end of a step 4 run:

```
===== SENT =====
TEST: PASSED   SVA_FAILURES: 0
LINE ... TOGGLE ... FSM ... SVA ... FUNCTIONAL  (each n/n, 100.0%)
RESULT: CLOSED
```

**Core test** (`tb/SENT_tb.sv`): drives `SENT_top` through its own ports against a protocol peer or model and checks every result itself; any mismatch prints `ERROR`, and `TEST PASSED` is printed only when there were none.

**APB wrapper test** (`tb/SENT_apb_tb.sv`), in this order:

1. Reset values of every register, ID included.
2. Writes to read-only registers are ignored.
3. Each RW register: all ones, all zeros, then 16 random writes with every PSTRB byte-lane pattern, read back each time.
4. Unmapped and misaligned addresses, reads and writes: PSLVERR, read data 0, no side effect on other registers.
5. Back-to-back transfers with no idle cycle.
6. IP traffic through the registers only (`tb/apb/SENT_apb_func.svh`): the programming sequence above, every interrupt bit set, enabled and cleared, stream FULL/AVAIL/OVF cases (100% wrapper toggle coverage confirms each bit moved).
7. PRESETN asserted mid-run: `irq` and PRDATA go to 0, registers return to reset values.

**Checkers** (`tb/cov/SENT_sva.sv`, `tb/cov/SENT_apb_sva.sv`): SVA protocol and APB assertions plus covergroups, bound in by the coverage flow. An assertion failure prints `SVA_FAIL` and fails the run even when the test itself passed.

Whole portfolio: `bash scripts/ci_regression.sh` runs steps 1 to 3 for every IP (what CI runs), and `bash scripts/cov/run_all.sh 4` runs step 4 for every IP.

## Verification

Five-metric coverage with Verilator 5.052 (`scripts/cov/run_cov.sh`); see [COVERAGE_CLOSURE.md](../COVERAGE_CLOSURE.md) for the flow. Line and toggle count only the named RTL file.

| Scope | Test | Line | Toggle | FSM | SVA | Functional |
|---|---|---|---|---|---|---|
| core `rtl/SENT_top.sv` | not run | | | | | |
| wrapper `rtl/SENT_apb.sv` | not run | | | | | |
