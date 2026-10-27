# LIN 2.2A node (commander and responder)

Protocol IP `LIN`, version 2.0. Apache-2.0.

| Item | Value |
|---|---|
| Core | `LIN_top` (`rtl/LIN_top.sv`) |
| Register interface | APB4 slave `LIN_apb`, 32-bit data, 12-bit byte address, zero wait states |
| Clock, reset | PCLK (rising edge), PRESETN (active low, asynchronous) |
| ID register | 0x4C490200 (code 0x4C49, version 2.0) |
| Registers | 15 words, 0x000 to 0x038 |
| Interrupts | 15 sources into one level-high `irq` |
| Data streams | HDR (to the core), PID (from the core), RSP (to the core), RX (from the core) |
| Protocol pins | 2 pass-through |

## Overview

LIN_top v2.0: LIN 2.2A node (ISO 17987), commander and responder roles

- Bus: rxd/txd, 0 = dominant, txd open-drain style (1 = released).
Bytes are UART frames: start bit, 8 data bits LSB first, stop bit.
- Header: break (13 dominant bits, then a 1-bit delimiter), sync byte
0x55, protected identifier (6-bit ID + parity P0 = ID0^ID1^ID2^ID4,
P1 = ~(ID1^ID3^ID4^ID5)). A node with hdr_valid/hdr_ready sends one
(commander; ready when idle or when no role was taken in the current
frame); every node, the sender included, parses headers off the bus.
- Break detection: rxd dominant for 11 nominal bit times (cfg_bit
clocks per bit). Any break restarts the frame, whatever the state.
- Sync: the delimiter may last up to 14 nominal bits; the four intervals
between the five falling edges of 0x55 must each last 1.5..2.5 nominal
bits; with cfg_autobaud the bit time for the
rest of the frame is their sum / 8 (responders without a crystal),
otherwise cfg_bit (the measurement saturates at 65535). Bit 7 and
the stop bit of the sync byte are checked.
- Response: after pid_valid the host picks this node's role through
rsp_valid (rsp_ready high while undecided): publish rsp_len+1 data
bytes of rsp_data (byte 0 in bits 7:0, sent first) or subscribe to
rsp_len+1 bytes; a published response starts at the end of the PID
stop bit at the earliest. Checksum: inverted 8-bit sum with
end-around carry over the data (classic), plus the protected ID when
rsp_enh (enhanced);
IDs 60..63 always use classic. Undecided at the first response start
bit, or 126 bit times after the header (the timeout of the longest
response): the frame is ignored.
- Errors (one-clock pulses): err_bit (sent bit read back wrong; the node
stops sending), err_sync, err_parity, err_frame (stop bit dominant),
err_chk, err_timeout (subscribed response not complete within
1.4 x 10 x (bytes + 1) bit times after the header).
Not implemented: sleep and wake-up, bus-idle timeout, transport layer.

A commander writes HDR and also acts on its own header: it reads PID and writes RSP like any responder.
RSP can be written ahead: it is held (FLAGS.RSP_FULL) and taken by the next header.

## Files

| File | Content |
|---|---|
| `rtl/LIN_top.sv` | protocol core |
| `rtl/LIN_apb.sv` | APB4 register wrapper (generated) |
| `tb/LIN_tb.sv` | core testbench |
| `tb/LIN_apb_tb.sv`, `tb/apb/LIN_apb_func.svh` | wrapper testbench (generated part + IP-specific part) |
| `tb/cov/LIN_sva.sv`, `tb/cov/LIN_apb_sva.sv` | coverage checkers (core, wrapper) |
| `scripts/apb/specs/LIN.json` | register spec the wrapper, TB, checker and this page are generated from |

How to run the tests and the coverage flow: see [Running and verifying](#running-and-verifying).

## Parameters

The core and the wrapper have no parameters.

## Wrapper pins

Pins of `LIN_apb`. Widths of the pass-through pins are at the default parameters.

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
| `rxd` | input | 1 | protocol pin, core port `rxd` |
| `txd` | output | 1 | protocol pin, core port `txd` |

## Core ports

| Port | Dir | Width | In the APB wrapper |
|---|---|---|---|
| `clk` | input | 1 | PCLK |
| `rst_n` | input | 1 | PRESETN |
| `rxd` | input | 1 | pin (pass-through) |
| `txd` | output | 1 | pin (pass-through) |
| `cfg_bit` | input | 16 | CFG[15:0] |
| `cfg_autobaud` | input | 1 | CFG[16:16] |
| `hdr_valid` | input | 1 | HDR commit / FLAGS |
| `hdr_ready` | output | 1 | HDR handshake |
| `hdr_id` | input | 6 | HDR[5:0] |
| `pid_valid` | output | 1 | PID capture |
| `pid_id` | output | 6 | PID[5:0] |
| `rsp_ready` | output | 1 | RSP handshake |
| `rsp_valid` | input | 1 | RSP commit / FLAGS |
| `rsp_pub` | input | 1 | RSP2[3:3] |
| `rsp_len` | input | 3 | RSP2[2:0] |
| `rsp_enh` | input | 1 | RSP2[4:4] |
| `rsp_data` | input | 64 | RSP0[31:0], RSP1[31:0] |
| `tx_done` | output | 1 | IRQ_STATUS.SENT |
| `rx_valid` | output | 1 | RX capture |
| `rx_id` | output | 6 | RX2[5:0] |
| `rx_len` | output | 3 | RX2[8:6] |
| `rx_data` | output | 64 | RX0[31:0], RX1[31:0] |
| `err_bit` | output | 1 | IRQ_STATUS.ERR_BIT |
| `err_sync` | output | 1 | IRQ_STATUS.ERR_SYNC |
| `err_parity` | output | 1 | IRQ_STATUS.ERR_PARITY |
| `err_frame` | output | 1 | IRQ_STATUS.ERR_FRAME |
| `err_chk` | output | 1 | IRQ_STATUS.ERR_CHK |
| `err_timeout` | output | 1 | IRQ_STATUS.ERR_TIMEOUT |
| `bit_time` | output | 16 | STATUS[15:0] |

## APB wrapper

`LIN_apb` is an APB4 slave (AMBA APB protocol v2.0): zero wait states, 32-bit data, 12-bit byte address, PSTRB byte lanes on every writable register, PSLVERR on an unmapped or misaligned address (reads then return 0, writes are dropped). Writes to read-only registers are ignored without an error. The core runs on PCLK and PRESETN. `irq` is level-high: `|(IRQ_STATUS & IRQ_ENABLE)`.

Pass-through pins: `rxd`, `txd`.

### Register map

| Offset | Name | Access | Reset | Description |
|---|---|---|---|---|
| 0x000 | ID | RO | 0x4C490200 | IP identification: code, major and minor version |
| 0x004 | IRQ_STATUS | W1C | 0x00000000 | Sticky interrupt bits, write 1 to clear |
| 0x008 | IRQ_ENABLE | RW | 0x00000000 | Interrupt enables; irq = \|(IRQ_STATUS & IRQ_ENABLE) |
| 0x00C | FLAGS | RO | 0x00000000 | Stream holding-register state |
| 0x010 | SCRATCH | RW | 0x00000000 | Scratch register, no effect on the core |
| 0x014 | CFG | RW | 0x00000A2C | Bit timing (static while the bus is in use) |
| 0x018 | HDR | RW | 0x00000000 | Commander: writing an ID sends a header (break, sync, protected ID) |
| 0x01C | PID | RO (pop) | 0x00000000 | Header seen on the bus (own headers included); reading frees it |
| 0x020 | RSP0 | RW | 0x00000000 | This node's role in the next response, taken once a header has been seen; writing RSP2 commits it. Not written before the response starts: the frame is ignored |
| 0x024 | RSP1 | RW | 0x00000000 | This node's role in the next response, taken once a header has been seen; writing RSP2 commits it. Not written before the response starts: the frame is ignored |
| 0x028 | RSP2 | RW | 0x00000000 | This node's role in the next response, taken once a header has been seen; writing RSP2 commits it. Not written before the response starts: the frame is ignored |
| 0x02C | RX0 | RO (pop) | 0x00000000 | Subscribed response received with a good checksum; reading RX2 frees it |
| 0x030 | RX1 | RO (pop) | 0x00000000 | Subscribed response received with a good checksum; reading RX2 frees it |
| 0x034 | RX2 | RO (pop) | 0x00000000 | Subscribed response received with a good checksum; reading RX2 frees it |
| 0x038 | STATUS | RO | core | Bit time in use |

Unlisted bits read 0 and ignore writes. Reset "core": the register reads the core's outputs directly, so after reset it shows the core's own reset state. WO (pulse) registers read 0. Offsets from 0x03C up to 0xFFC are unmapped (PSLVERR).

### Fields

| Register | Bits | Field | Access | Reset | Description |
|---|---|---|---|---|---|
| ID | 31:16 | CODE | RO | 0x4C49 | IP code |
| ID | 15:8 | MAJOR | RO | 0x02 | major version |
| ID | 7:0 | MINOR | RO | 0x00 | minor version |
| IRQ_STATUS | 14:0 | one bit per interrupt | W1C | 0x0 | see Interrupts |
| IRQ_ENABLE | 14:0 | one bit per interrupt | RW | 0x0 | 1 enables the IRQ_STATUS bit onto `irq` |
| FLAGS | 3:0 | one bit per stream flag | RO | 0x0 | see FLAGS |
| SCRATCH | 31:0 | SCRATCH | RW | 0x00000000 | free for software |
| CFG | 15:0 | `cfg_bit` | RW | 0xA2C | nominal bit time in clocks, at least 16 (2604: 19200 bit/s at 50 MHz) |
| CFG | 16 | `cfg_autobaud` | RW | 0x0 | 1 = measure the bit time of each frame on its sync byte (responder without a crystal) |
| HDR | 5:0 | `hdr_id` | RW | 0x0 | frame identifier 0..63 |
| PID | 5:0 | `pid_id` | RO (pop) | 0x0 | frame identifier |
| RSP0 | 31:0 | `rsp_data[31:0]` | RW | 0x0 | data to publish, byte 0 in bits 7:0 (sent first) |
| RSP1 | 31:0 | `rsp_data[63:32]` | RW | 0x0 | data to publish, byte 0 in bits 7:0 (sent first) |
| RSP2 | 2:0 | `rsp_len` | RW | 0x0 | data bytes - 1 |
| RSP2 | 3 | `rsp_pub` | RW | 0x0 | 1 = publish rsp_data, 0 = subscribe |
| RSP2 | 4 | `rsp_enh` | RW | 0x0 | 1 = enhanced checksum (IDs 60..63 always classic) |
| RX0 | 31:0 | `rx_data[31:0]` | RO (pop) | 0x0 | data bytes, byte 0 in bits 7:0, unused bytes 0 |
| RX1 | 31:0 | `rx_data[63:32]` | RO (pop) | 0x0 | data bytes, byte 0 in bits 7:0, unused bytes 0 |
| RX2 | 5:0 | `rx_id` | RO (pop) | 0x0 | frame identifier |
| RX2 | 8:6 | `rx_len` | RO (pop) | 0x0 | data bytes - 1 |
| STATUS | 15:0 | `bit_time` | RO | core | bit time of the current frame in clocks (measured with auto-baud) |

### Interrupts (IRQ_STATUS, IRQ_ENABLE)

A bit is set while its source is active, stays set until written with 1, and a set in the same clock as the clear wins.

| Bit | Name | Set when |
|---|---|---|
| 0 | SENT | a published response was sent completely |
| 1 | ERR_BIT | a sent bit read back wrong; the node stopped sending |
| 2 | ERR_SYNC | break delimiter too long, or sync byte wrong or off-rate |
| 3 | ERR_PARITY | protected ID parity error |
| 4 | ERR_FRAME | dominant stop bit in the PID or the response |
| 5 | ERR_CHK | response checksum error |
| 6 | ERR_TIMEOUT | subscribed response incomplete after 1.4 x its nominal length |
| 7 | HDR_DONE | HDR beat accepted by the core |
| 8 | HDR_OVF | write to HDR while full (dropped) |
| 9 | PID_AVAIL | PID captured a beat |
| 10 | PID_OVF | beat dropped, PID was full |
| 11 | RSP_DONE | RSP beat accepted by the core |
| 12 | RSP_OVF | write to RSP while full (dropped) |
| 13 | RX_AVAIL | RX captured a beat |
| 14 | RX_OVF | beat dropped, RX was full |

### FLAGS

| Bit | Name | Meaning |
|---|---|---|
| 0 | HDR_FULL | HDR holds a beat the core has not taken |
| 1 | PID_AVAIL | PID holds an unread beat |
| 2 | RSP_FULL | RSP holds a beat the core has not taken |
| 3 | RX_AVAIL | RX holds an unread beat |

### Streams

* **HDR** feeds `hdr_id`/`hdr_valid`. Writing HDR commits the beat: FLAGS.HDR_FULL is set and `hdr_valid` stays high until the core's `hdr_ready`; then HDR_DONE is set. A write while full is dropped and sets HDR_OVF.
* **PID** captures `pid_id` when `pid_valid` is high and the register is empty (or is being read in the same clock), and sets FLAGS/IRQ PID_AVAIL. Reading PID pops it. A beat that arrives while the register is full is dropped and sets PID_OVF.
* **RSP** feeds `rsp_data`, `rsp_len`, `rsp_pub`, `rsp_enh`/`rsp_valid`. Writing RSP2 commits the beat: FLAGS.RSP_FULL is set and `rsp_valid` stays high until the core's `rsp_ready`; then RSP_DONE is set. A write while full is dropped and sets RSP_OVF.
* **RX** captures `rx_data`, `rx_id`, `rx_len` when `rx_valid` is high and the register is empty (or is being read in the same clock), and sets FLAGS/IRQ RX_AVAIL. Reading RX2 pops it. A beat that arrives while the register is full is dropped and sets RX_OVF.

## Programming sequence

1. Release PRESETN. Read ID (0x000) and check it is 0x4C490200.
2. Write 0x7FFF to IRQ_STATUS (0x004) to clear any stale bits.
3. Configure the core: write CFG (0x014). Reset values are in the register map; PSTRB selects the bytes written.
4. Write IRQ_ENABLE (0x008) with the interrupts to use (bit order as in the Interrupts table; 0x7FFF enables all).
5. To send on HDR: wait until FLAGS.HDR_FULL (bit 0) is 0, or for IRQ HDR_DONE, then write HDR (0x018). The last write commits the beat. HDR_OVF means a write came while the register was full and was dropped.
6. To receive on PID: wait for IRQ PID_AVAIL or FLAGS.PID_AVAIL (bit 1), then read PID (0x01C). Reading the last word frees the register for the next beat; write 1 to IRQ_STATUS.PID_AVAIL (bit 9) to clear it. Read each beat before the next arrives, or it is dropped and PID_OVF is set.
7. To send on RSP: wait until FLAGS.RSP_FULL (bit 2) is 0, or for IRQ RSP_DONE, then write RSP0 (0x020) then RSP1 (0x024) then RSP2 (0x028). The last write commits the beat. RSP_OVF means a write came while the register was full and was dropped.
8. To receive on RX: wait for IRQ RX_AVAIL or FLAGS.RX_AVAIL (bit 3), then read RX0 (0x02C) then RX1 (0x030) then RX2 (0x034). Reading the last word frees the register for the next beat; write 1 to IRQ_STATUS.RX_AVAIL (bit 13) to clear it. Read each beat before the next arrives, or it is dropped and RX_OVF is set.
9. Read STATUS (0x038) for the core's live `bit_time`; it needs no clearing.
10. On `irq`: read IRQ_STATUS, handle every bit that is set and enabled, then write those bits back to IRQ_STATUS to clear them. A source that is still active sets its bit again.

## Running and verifying

All commands run from the repository root. Icarus Verilog 12 and Yosys 0.33 are enough for steps 1 to 3; step 4 also needs Verilator 5.052 and pyslang (see [README, Setup](../../README.md#setup)).

| Step | Command | Pass when | Output |
|---|---|---|---|
| 1. Core test | `make -f Makefile.LIN sim` | a `TEST PASSED` line, no `ERROR` | console |
| 2. Core synthesis | `make -f Makefile.LIN syn` | Yosys ends without `ERROR`; `stat` prints the cell count | `work/LIN_top.json` |
| 3. APB wrapper test + synthesis | `make -f Makefile.LIN apb` | `TEST PASSED: LIN_apb`, then Yosys without `ERROR` | console, `work/LIN_apb.json` |
| 4. Coverage (core, wrapper) | `bash scripts/cov/run_cov.sh LIN`<br>`bash scripts/cov/run_cov.sh LIN_apb` | `RESULT: CLOSED` (all five metrics 100%) | `work/cov/LIN/score.json`, `work/cov/LIN_apb/score.json` |

Expected end of a step 4 run:

```
===== LIN =====
TEST: PASSED   SVA_FAILURES: 0
LINE ... TOGGLE ... FSM ... SVA ... FUNCTIONAL  (each n/n, 100.0%)
RESULT: CLOSED
```

**Core test** (`tb/LIN_tb.sv`): drives `LIN_top` through its own ports against a protocol peer or model and checks every result itself; any mismatch prints `ERROR`, and `TEST PASSED` is printed only when there were none.

**APB wrapper test** (`tb/LIN_apb_tb.sv`), in this order:

1. Reset values of every register, ID included.
2. Writes to read-only registers are ignored.
3. Each RW register: all ones, all zeros, then 16 random writes with every PSTRB byte-lane pattern, read back each time.
4. Unmapped and misaligned addresses, reads and writes: PSLVERR, read data 0, no side effect on other registers.
5. Back-to-back transfers with no idle cycle.
6. IP traffic through the registers only (`tb/apb/LIN_apb_func.svh`): the programming sequence above, every interrupt bit set, enabled and cleared, stream FULL/AVAIL/OVF cases (100% wrapper toggle coverage confirms each bit moved).
7. PRESETN asserted mid-run: `irq` and PRDATA go to 0, registers return to reset values.

**Checkers** (`tb/cov/LIN_sva.sv`, `tb/cov/LIN_apb_sva.sv`): SVA protocol and APB assertions plus covergroups, bound in by the coverage flow. An assertion failure prints `SVA_FAIL` and fails the run even when the test itself passed.

Whole portfolio: `bash scripts/ci_regression.sh` runs steps 1 to 3 for every IP (what CI runs), and `bash scripts/cov/run_all.sh 4` runs step 4 for every IP.

## Verification

Five-metric coverage with Verilator 5.052 (`scripts/cov/run_cov.sh`); see [COVERAGE_CLOSURE.md](../COVERAGE_CLOSURE.md) for the flow. Line and toggle count only the named RTL file.

| Scope | Test | Line | Toggle | FSM | SVA | Functional |
|---|---|---|---|---|---|---|
| core `rtl/LIN_top.sv` | pass | 131/131 | 1256/1256 | 29/29 | 11/11 | 132/132 |
| wrapper `rtl/LIN_apb.sv` | pass | 52/52 | 1256/1256 | n/a | 17/17 | 115/115 |
