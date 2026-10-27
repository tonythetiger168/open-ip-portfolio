# FlexRay 3.0.1 communication controller (single channel, static segment)

Protocol IP `FlexRay`, version 2.0. Apache-2.0.

| Item | Value |
|---|---|
| Core | `FlexRay_top` (`rtl/FlexRay_top.sv`) |
| Register interface | APB4 slave `FlexRay_apb`, 32-bit data, 12-bit byte address, zero wait states |
| Clock, reset | PCLK (rising edge), PRESETN (active low, asynchronous) |
| ID register | 0x46520200 (code 0x4652, version 2.0) |
| Registers | 17 words, 0x000 to 0x040 |
| Interrupts | 11 sources into one level-high `irq` |
| Data streams | TX (to the core), RX (from the core) |
| Protocol pins | 3 pass-through |

## Overview

FlexRay_top v2.0: FlexRay 3.0.1 communication controller, single channel, static segment

- Coding (spec ch. 3): TSS (cfg_tss LOW bits), FSS (HIGH), every byte as
BSS (HIGH, LOW) + 8 bits MSB first, FES (LOW, HIGH). txd/tx_en drive
the transceiver (tx_en = 1 while sending); idle bus reads HIGH.
- Decoding: 8 samples per bit (cfg_spc+1 clocks per sample), majority
vote over the last 5 samples, bit strobe at sample 5; the sample counter
is set to 2 at the falling edge of the voted signal at the start of the
TSS and in every BSS. Channel idle: 11 consecutive HIGH bits. Accepted
TSS: 1 .. cfg_tss+1 LOW bits; a LOW pulse shorter than a bit is ignored.
- Frame (spec ch. 4): 40-bit header {reserved, payload preamble, null
frame indicator (0 = null frame), sync, startup, frame ID[10:0],
payload length[6:0] (2-byte words), header CRC[10:0], cycle count[5:0]},
payload, 24-bit frame CRC. Header CRC x^11+x^9+x^8+x^7+x^2+1, init
0x01A, over sync, startup, ID and length. Frame CRC 0x5D6DCB, init
0xFEDCBA (channel A) or 0xABCDEF (cfg_chan_b), over header and payload.
- Timing: macrotick = 1 bit. Cycle = cfg_nslots static slots of cfg_slot
bits, then cfg_nit bits network idle time; cycle count 0..63. A node
sends one frame per cycle in slot cfg_my_slot, starting cfg_ap bits
into the slot: the queued tx_data (null frame indicator 1) or, with
nothing queued, a null frame. Payload length cfg_plen words; bytes past
tx_data[127:0] are sent as 0.
- Synchronisation: a coldstart node (cfg_cold) runs its own schedule from
reset and is the time master. Any other node integrates on the first
valid sync frame (ID 1..cfg_nslots): it takes slot = ID and the cycle
count, and sets its slot timer from the time of the frame's first BSS
edge. Every later sync frame re-phases it the same way (offset
correction); a correction beyond cfg_corr clocks, or a cycle without a
sync frame, loses synchronisation (err_sync).
- Received frames (own transmissions are ignored): rx_valid with the
header fields (rx_id: ID[5:0], always the slot number) and the first
16 payload bytes (byte 0 in bits 7:0) when synchronised and the frame
carries this slot's ID and cycle count;
otherwise err_slot. err_coding: a bit not as the coding requires;
err_hcrc / err_fcrc: header / frame CRC. Before integration only sync
frames are used.
Not implemented: dynamic segment, symbol window (CAS/MTS, WUS), wakeup,
startup with several coldstart nodes, rate correction, second channel,
bus guardian.

txd / tx_en drive the bus transceiver, rxd is its receive output.
Change CFG only while the cluster is stopped (all nodes in reset or not yet synchronised).

## Files

| File | Content |
|---|---|
| `rtl/FlexRay_top.sv` | protocol core |
| `rtl/FlexRay_apb.sv` | APB4 register wrapper (generated) |
| `tb/FlexRay_tb.sv` | core testbench |
| `tb/FlexRay_apb_tb.sv`, `tb/apb/FlexRay_apb_func.svh` | wrapper testbench (generated part + IP-specific part) |
| `tb/cov/FlexRay_sva.sv`, `tb/cov/FlexRay_apb_sva.sv` | coverage checkers (core, wrapper) |
| `scripts/apb/specs/FlexRay.json` | register spec the wrapper, TB, checker and this page are generated from |

How to run the tests and the coverage flow: see [Running and verifying](#running-and-verifying).

## Parameters

The core and the wrapper have no parameters.

## Wrapper pins

Pins of `FlexRay_apb`. Widths of the pass-through pins are at the default parameters.

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
| `tx_en` | output | 1 | protocol pin, core port `tx_en` |

## Core ports

| Port | Dir | Width | In the APB wrapper |
|---|---|---|---|
| `clk` | input | 1 | PCLK |
| `rst_n` | input | 1 | PRESETN |
| `rxd` | input | 1 | pin (pass-through) |
| `txd` | output | 1 | pin (pass-through) |
| `tx_en` | output | 1 | pin (pass-through) |
| `cfg_spc` | input | 4 | CFG0[3:0] |
| `cfg_tss` | input | 4 | CFG0[7:4] |
| `cfg_slot` | input | 10 | CFG0[17:8] |
| `cfg_ap` | input | 6 | CFG0[23:18] |
| `cfg_nslots` | input | 6 | CFG0[29:24] |
| `cfg_nit` | input | 10 | CFG1[9:0] |
| `cfg_plen` | input | 4 | CFG1[13:10] |
| `cfg_my_slot` | input | 6 | CFG1[19:14] |
| `cfg_sync` | input | 1 | CFG1[20:20] |
| `cfg_cold` | input | 1 | CFG1[21:21] |
| `cfg_chan_b` | input | 1 | CFG1[22:22] |
| `cfg_corr` | input | 8 | CFG1[30:23] |
| `tx_valid` | input | 1 | TX commit / FLAGS |
| `tx_ready` | output | 1 | TX handshake |
| `tx_data` | input | 128 | TX0[31:0], TX1[31:0], TX2[31:0], TX3[31:0] |
| `tx_done` | output | 1 | IRQ_STATUS.SENT |
| `rx_valid` | output | 1 | RX capture |
| `rx_id` | output | 6 | RX4[5:0] |
| `rx_cycle` | output | 6 | RX4[11:6] |
| `rx_len` | output | 7 | RX4[18:12] |
| `rx_null` | output | 1 | RX4[19:19] |
| `rx_sync` | output | 1 | RX4[20:20] |
| `rx_startup` | output | 1 | RX4[21:21] |
| `rx_data` | output | 128 | RX0[31:0], RX1[31:0], RX2[31:0], RX3[31:0] |
| `synced` | output | 1 | STATUS[0:0] |
| `cycle` | output | 6 | STATUS[6:1] |
| `slot` | output | 6 | STATUS[12:7] |
| `cycle_start` | output | 1 | IRQ_STATUS.CYCLE |
| `err_coding` | output | 1 | IRQ_STATUS.ERR_CODING |
| `err_hcrc` | output | 1 | IRQ_STATUS.ERR_HCRC |
| `err_fcrc` | output | 1 | IRQ_STATUS.ERR_FCRC |
| `err_slot` | output | 1 | IRQ_STATUS.ERR_SLOT |
| `err_sync` | output | 1 | IRQ_STATUS.ERR_SYNC |

## APB wrapper

`FlexRay_apb` is an APB4 slave (AMBA APB protocol v2.0): zero wait states, 32-bit data, 12-bit byte address, PSTRB byte lanes on every writable register, PSLVERR on an unmapped or misaligned address (reads then return 0, writes are dropped). Writes to read-only registers are ignored without an error. The core runs on PCLK and PRESETN. `irq` is level-high: `|(IRQ_STATUS & IRQ_ENABLE)`.

Pass-through pins: `rxd`, `txd`, `tx_en`.

### Register map

| Offset | Name | Access | Reset | Description |
|---|---|---|---|---|
| 0x000 | ID | RO | 0x46520200 | IP identification: code, major and minor version |
| 0x004 | IRQ_STATUS | W1C | 0x00000000 | Sticky interrupt bits, write 1 to clear |
| 0x008 | IRQ_ENABLE | RW | 0x00000000 | Interrupt enables; irq = \|(IRQ_STATUS & IRQ_ENABLE) |
| 0x00C | FLAGS | RO | 0x00000000 | Stream holding-register state |
| 0x010 | SCRATCH | RW | 0x00000000 | Scratch register, no effect on the core |
| 0x014 | CFG0 | RW | 0x08307850 | Cluster and node configuration (static while the cluster runs) |
| 0x018 | CFG1 | RW | 0x2000001E | Cluster and node configuration (static while the cluster runs) |
| 0x01C | TX0 | RW | 0x00000000 | Payload for the next own frame; writing TX3 commits it. With nothing queued the node sends a null frame |
| 0x020 | TX1 | RW | 0x00000000 | Payload for the next own frame; writing TX3 commits it. With nothing queued the node sends a null frame |
| 0x024 | TX2 | RW | 0x00000000 | Payload for the next own frame; writing TX3 commits it. With nothing queued the node sends a null frame |
| 0x028 | TX3 | RW | 0x00000000 | Payload for the next own frame; writing TX3 commits it. With nothing queued the node sends a null frame |
| 0x02C | RX0 | RO (pop) | 0x00000000 | Valid frame received in its slot (null frames included); reading RX4 frees it |
| 0x030 | RX1 | RO (pop) | 0x00000000 | Valid frame received in its slot (null frames included); reading RX4 frees it |
| 0x034 | RX2 | RO (pop) | 0x00000000 | Valid frame received in its slot (null frames included); reading RX4 frees it |
| 0x038 | RX3 | RO (pop) | 0x00000000 | Valid frame received in its slot (null frames included); reading RX4 frees it |
| 0x03C | RX4 | RO (pop) | 0x00000000 | Valid frame received in its slot (null frames included); reading RX4 frees it |
| 0x040 | STATUS | RO | core | Synchronisation state and position in the cycle |

Unlisted bits read 0 and ignore writes. Reset "core": the register reads the core's outputs directly, so after reset it shows the core's own reset state. WO (pulse) registers read 0. Offsets from 0x044 up to 0xFFC are unmapped (PSLVERR).

### Fields

| Register | Bits | Field | Access | Reset | Description |
|---|---|---|---|---|---|
| ID | 31:16 | CODE | RO | 0x4652 | IP code |
| ID | 15:8 | MAJOR | RO | 0x02 | major version |
| ID | 7:0 | MINOR | RO | 0x00 | minor version |
| IRQ_STATUS | 10:0 | one bit per interrupt | W1C | 0x0 | see Interrupts |
| IRQ_ENABLE | 10:0 | one bit per interrupt | RW | 0x0 | 1 enables the IRQ_STATUS bit onto `irq` |
| FLAGS | 1:0 | one bit per stream flag | RO | 0x0 | see FLAGS |
| SCRATCH | 31:0 | SCRATCH | RW | 0x00000000 | free for software |
| CFG0 | 3:0 | `cfg_spc` | RW | 0x0 | clocks per sample - 1; a bit is 8 samples (0: 8 clocks per bit, 10 Mbit/s at 80 MHz) |
| CFG0 | 7:4 | `cfg_tss` | RW | 0x5 | transmission start sequence length in bits (3..15) |
| CFG0 | 17:8 | `cfg_slot` | RW | 0x78 | static slot length in bits |
| CFG0 | 23:18 | `cfg_ap` | RW | 0xC | action point offset in bits |
| CFG0 | 29:24 | `cfg_nslots` | RW | 0x8 | static slots per cycle (1..63) |
| CFG1 | 9:0 | `cfg_nit` | RW | 0x1E | network idle time in bits |
| CFG1 | 13:10 | `cfg_plen` | RW | 0x0 | payload length of own frames in 2-byte words |
| CFG1 | 19:14 | `cfg_my_slot` | RW | 0x0 | own static slot, 0 = listen only |
| CFG1 | 20 | `cfg_sync` | RW | 0x0 | own frames are sync frames |
| CFG1 | 21 | `cfg_cold` | RW | 0x0 | coldstart node: runs its own schedule and is the time master |
| CFG1 | 22 | `cfg_chan_b` | RW | 0x0 | frame CRC initial value of channel B |
| CFG1 | 30:23 | `cfg_corr` | RW | 0x40 | largest accepted offset correction in clocks |
| TX0 | 31:0 | `tx_data[31:0]` | RW | 0x0 | payload bytes, byte 0 in bits 7:0 (sent first); bytes beyond 2 x CFG.cfg_plen are not sent |
| TX1 | 31:0 | `tx_data[63:32]` | RW | 0x0 | payload bytes, byte 0 in bits 7:0 (sent first); bytes beyond 2 x CFG.cfg_plen are not sent |
| TX2 | 31:0 | `tx_data[95:64]` | RW | 0x0 | payload bytes, byte 0 in bits 7:0 (sent first); bytes beyond 2 x CFG.cfg_plen are not sent |
| TX3 | 31:0 | `tx_data[127:96]` | RW | 0x0 | payload bytes, byte 0 in bits 7:0 (sent first); bytes beyond 2 x CFG.cfg_plen are not sent |
| RX0 | 31:0 | `rx_data[31:0]` | RO (pop) | 0x0 | first 16 payload bytes, byte 0 in bits 7:0 |
| RX1 | 31:0 | `rx_data[63:32]` | RO (pop) | 0x0 | first 16 payload bytes, byte 0 in bits 7:0 |
| RX2 | 31:0 | `rx_data[95:64]` | RO (pop) | 0x0 | first 16 payload bytes, byte 0 in bits 7:0 |
| RX3 | 31:0 | `rx_data[127:96]` | RO (pop) | 0x0 | first 16 payload bytes, byte 0 in bits 7:0 |
| RX4 | 5:0 | `rx_id` | RO (pop) | 0x0 | frame ID (= slot) |
| RX4 | 11:6 | `rx_cycle` | RO (pop) | 0x0 | cycle count |
| RX4 | 18:12 | `rx_len` | RO (pop) | 0x0 | payload length in words |
| RX4 | 19 | `rx_null` | RO (pop) | 0x0 | 1 = null frame |
| RX4 | 20 | `rx_sync` | RO (pop) | 0x0 | sync frame indicator |
| RX4 | 21 | `rx_startup` | RO (pop) | 0x0 | startup frame indicator |
| STATUS | 0 | `synced` | RO | core | 1 = synchronised to the cluster |
| STATUS | 6:1 | `cycle` | RO | core | cycle count |
| STATUS | 12:7 | `slot` | RO | core | current static slot, 0 = network idle time |

### Interrupts (IRQ_STATUS, IRQ_ENABLE)

A bit is set while its source is active, stays set until written with 1, and a set in the same clock as the clear wins.

| Bit | Name | Set when |
|---|---|---|
| 0 | CYCLE | a new communication cycle started |
| 1 | SENT | a frame carrying the queued TX payload was sent |
| 2 | ERR_CODING | coding error (TSS, BSS or FES) |
| 3 | ERR_HCRC | header CRC error |
| 4 | ERR_FCRC | frame CRC error |
| 5 | ERR_SLOT | frame ID or cycle count does not match the slot |
| 6 | ERR_SYNC | synchronisation lost: offset correction beyond CFG.cfg_corr, or a cycle without a sync frame |
| 7 | TX_DONE | TX beat accepted by the core |
| 8 | TX_OVF | write to TX while full (dropped) |
| 9 | RX_AVAIL | RX captured a beat |
| 10 | RX_OVF | beat dropped, RX was full |

### FLAGS

| Bit | Name | Meaning |
|---|---|---|
| 0 | TX_FULL | TX holds a beat the core has not taken |
| 1 | RX_AVAIL | RX holds an unread beat |

### Streams

* **TX** feeds `tx_data`/`tx_valid`. Writing TX3 commits the beat: FLAGS.TX_FULL is set and `tx_valid` stays high until the core's `tx_ready`; then TX_DONE is set. A write while full is dropped and sets TX_OVF.
* **RX** captures `rx_data`, `rx_id`, `rx_cycle`, `rx_len`, `rx_null`, `rx_sync`, `rx_startup` when `rx_valid` is high and the register is empty (or is being read in the same clock), and sets FLAGS/IRQ RX_AVAIL. Reading RX4 pops it. A beat that arrives while the register is full is dropped and sets RX_OVF.

## Programming sequence

1. Release PRESETN. Read ID (0x000) and check it is 0x46520200.
2. Write 0x7FF to IRQ_STATUS (0x004) to clear any stale bits.
3. Configure the core: write CFG0 (0x014), CFG1 (0x018). Reset values are in the register map; PSTRB selects the bytes written.
4. Write IRQ_ENABLE (0x008) with the interrupts to use (bit order as in the Interrupts table; 0x7FF enables all).
5. To send on TX: wait until FLAGS.TX_FULL (bit 0) is 0, or for IRQ TX_DONE, then write TX0 (0x01C) then TX1 (0x020) then TX2 (0x024) then TX3 (0x028). The last write commits the beat. TX_OVF means a write came while the register was full and was dropped.
6. To receive on RX: wait for IRQ RX_AVAIL or FLAGS.RX_AVAIL (bit 1), then read RX0 (0x02C) then RX1 (0x030) then RX2 (0x034) then RX3 (0x038) then RX4 (0x03C). Reading the last word frees the register for the next beat; write 1 to IRQ_STATUS.RX_AVAIL (bit 9) to clear it. Read each beat before the next arrives, or it is dropped and RX_OVF is set.
7. Read STATUS (0x040) for the core's live `synced`, `cycle`, `slot`; it needs no clearing.
8. On `irq`: read IRQ_STATUS, handle every bit that is set and enabled, then write those bits back to IRQ_STATUS to clear them. A source that is still active sets its bit again.

## Running and verifying

All commands run from the repository root. Icarus Verilog 12 and Yosys 0.33 are enough for steps 1 to 3; step 4 also needs Verilator 5.052 and pyslang (see [README, Setup](../../README.md#setup)).

| Step | Command | Pass when | Output |
|---|---|---|---|
| 1. Core test | `make -f Makefile.FlexRay sim` | a `TEST PASSED` line, no `ERROR` | console |
| 2. Core synthesis | `make -f Makefile.FlexRay syn` | Yosys ends without `ERROR`; `stat` prints the cell count | `work/FlexRay_top.json` |
| 3. APB wrapper test + synthesis | `make -f Makefile.FlexRay apb` | `TEST PASSED: FlexRay_apb`, then Yosys without `ERROR` | console, `work/FlexRay_apb.json` |
| 4. Coverage (core, wrapper) | `bash scripts/cov/run_cov.sh FlexRay`<br>`bash scripts/cov/run_cov.sh FlexRay_apb` | `RESULT: CLOSED` (all five metrics 100%) | `work/cov/FlexRay/score.json`, `work/cov/FlexRay_apb/score.json` |

Expected end of a step 4 run:

```
===== FlexRay =====
TEST: PASSED   SVA_FAILURES: 0
LINE ... TOGGLE ... FSM ... SVA ... FUNCTIONAL  (each n/n, 100.0%)
RESULT: CLOSED
```

**Core test** (`tb/FlexRay_tb.sv`): drives `FlexRay_top` through its own ports against a protocol peer or model and checks every result itself; any mismatch prints `ERROR`, and `TEST PASSED` is printed only when there were none.

**APB wrapper test** (`tb/FlexRay_apb_tb.sv`), in this order:

1. Reset values of every register, ID included.
2. Writes to read-only registers are ignored.
3. Each RW register: all ones, all zeros, then 16 random writes with every PSTRB byte-lane pattern, read back each time.
4. Unmapped and misaligned addresses, reads and writes: PSLVERR, read data 0, no side effect on other registers.
5. Back-to-back transfers with no idle cycle.
6. IP traffic through the registers only (`tb/apb/FlexRay_apb_func.svh`): the programming sequence above, every interrupt bit set, enabled and cleared, stream FULL/AVAIL/OVF cases (100% wrapper toggle coverage confirms each bit moved).
7. PRESETN asserted mid-run: `irq` and PRDATA go to 0, registers return to reset values.

**Checkers** (`tb/cov/FlexRay_sva.sv`, `tb/cov/FlexRay_apb_sva.sv`): SVA protocol and APB assertions plus covergroups, bound in by the coverage flow. An assertion failure prints `SVA_FAIL` and fails the run even when the test itself passed.

Whole portfolio: `bash scripts/ci_regression.sh` runs steps 1 to 3 for every IP (what CI runs), and `bash scripts/cov/run_all.sh 4` runs step 4 for every IP.

## Verification

Five-metric coverage with Verilator 5.052 (`scripts/cov/run_cov.sh`); see [COVERAGE_CLOSURE.md](../COVERAGE_CLOSURE.md) for the flow. Line and toggle count only the named RTL file.

| Scope | Test | Line | Toggle | FSM | SVA | Functional |
|---|---|---|---|---|---|---|
| core `rtl/FlexRay_top.sv` | pass | 147/147 | 2312/2312 | 40/40 | 8/8 | 64/64 |
| wrapper `rtl/FlexRay_apb.sv` | pass | 50/50 | 1890/1890 | n/a | 24/24 | 95/95 |
