# SGMII / 1000BASE-X PCS (IEEE 802.3 clause 36 / 37, Cisco SGMII MAC side): GMII to ten-bit interface with 8b/10b coding, comma alignment, synchronisation, ordered sets and auto-negotiation

Protocol IP `SGMII`, version 1.0. Apache-2.0.

| Item | Value |
|---|---|
| Core | `SGMII_top` (`rtl/SGMII_top.sv`) |
| Register interface | APB4 slave `SGMII_apb`, 32-bit data, 12-bit byte address, zero wait states |
| Clock, reset | PCLK (rising edge), PRESETN (active low, asynchronous) |
| ID register | 0x53470100 (code 0x5347, version 1.0) |
| Registers | 9 words, 0x000 to 0x020 |
| Interrupts | 3 sources into one level-high `irq` |
| Protocol pins | 8 pass-through |

## Overview

SGMII / 1000BASE-X PCS (IEEE 802.3 clause 36 and 37, Cisco SGMII MAC side) between a GMII MAC interface and a ten-bit SerDes interface, one code group per clock (125 MHz). Grown from the GMII datapath: the GMII side is the same byte-per-clock interface, now coded onto 8b/10b. * Transmit (clause 36): the 8b/10b encoder with running disparity sends /C/ ordered sets during auto-negotiation (K28.5 D21.5 or D2.2, then the 16-bit config word, low byte first), /I/ between packets (K28.5 D5.6 when the running disparity is positive, else K28.5 D16.2), and packets as /S/ (in place of the first preamble byte), data, /V/ for gtx_er, then /T/ /R/, plus a second /R/ when /T/ fell on an odd position, so the next /I/ starts on an even one. /I/ always ends at RD-: /I1/ corrects a positive disparity, /I2/ keeps a negative one. A packet that starts on an odd position loses one preamble byte. * Receive: the code-group aligner finds a comma (bits a..g = 0011111 or 1100000) at any of the ten bit offsets while sync is lost, and keeps that offset; the synchronisation state machine of figure 36-9 needs three commas on even positions, each followed by a data group, and drops sync after four bad code groups (three good ones in a row undo one bad one). An invalid code group (not in the tables, or against the running disparity) is bad, as is a comma on an odd position. * The receiver turns /S/ into a 0x55 preamble byte with grx_dv, passes data, signals /V/ and bad code groups in a packet with grx_er, ends the packet at /T/ (or, with grx_er, at a comma), and reports a stray special or bad code group outside a packet as false carrier (grx_er = 1, grxd = 0x0E, grx_dv = 0). Packets are only received while auto-negotiation is done (or off). * Auto-negotiation (clause 37): restart (config 0 for a link timer), ability detect (three matching non-zero config words), acknowledge detect (three matching with ACK, the same abilities), complete acknowledge (a link timer), idle detect (a link timer and three /I/), link OK. A restart comes from an_restart, enabling an_en, a loss of sync, or three zero config words; three /C/ while the link is OK also restart. In 1000BASE-X mode the PCS sends adv and resolves duplex as adv[5] & lp[5] at 1000 Mb/s; in SGMII mode (MAC side) it sends 0x0001 (0x4001 with ACK), uses the shorter SGMII link timer and takes speed lp[11:10], duplex lp[12] and the PHY's link lp[15] from the partner. link_up: sync and AN done (with the PHY's link bit in SGMII), or sync with an_en low. irq_link pulses when link_up changes, irq_an when AN completes, irq_err on a bad code group while in sync, a false carrier or an error in a packet. Not implemented: SGMII rate adaptation (at 10 / 100 Mb/s the MAC repeats each byte 100 / 10 times), carrier extension, EEE, the PHY side of SGMII and next pages.

Features:

- GMII (gtxd / gtx_en / gtx_er, grxd / grx_dv / grx_er) to a ten-bit interface (tx_code / rx_code, bit 9 sent first) at 125 MHz.
- 8b/10b encoder and table decoder with running disparity; /I1/ and /I2/ idles keep the disparity negative after each idle; /S/ on an even position (the preamble byte it replaces is sent as /S/), /T/R/ or /T/R/R/ so the next ordered set starts even, gtx_er sent as /V/.
- Receive: a comma aligner over a 20-bit window at any of the 10 bit offsets, the clause 36 synchronisation state machine (three commas with data between, four bad groups to lose sync, three good ones step back up), /C/ and /I/ decoding, packets from /S/ to /T/ with /V/, invalid and special groups flagged as grx_er, an early end on a comma, and false carriers reported as grx_er with 0x0E.
- Clause 37 auto-negotiation: restart, ability detect, acknowledge detect, complete acknowledge, idle detect and link OK with the link timer (LT_X in 1000BASE-X, LT_SG in SGMII mode); the partner restarting (zero config words) and config words while the link is up restart it. Matches seen while the state before was running count in ability and acknowledge detect.
- SGMII MAC side: sends 0x0001 (0x4001 when acknowledging) and takes speed, duplex and the PHY's link bit from the partner's word.

gtxd, gtx_en, gtx_er, grxd, grx_dv, grx_er, tx_code and rx_code pass through unchanged; the GMII and the ten-bit interface run on PCLK (125 MHz). LT_X and LT_SG set the link timers in clocks (10 ms and 1.6 ms by default).
Not implemented: SGMII rate adaptation (at 10 / 100 Mb/s the MAC repeats each byte 100 / 10 times), carrier extension, EEE, the PHY side of SGMII and next pages.

## Files

| File | Content |
|---|---|
| `rtl/SGMII_top.sv` | protocol core |
| `rtl/SGMII_apb.sv` | APB4 register wrapper (generated) |
| `tb/SGMII_tb.sv` | core testbench |
| `tb/SGMII_apb_tb.sv`, `tb/apb/SGMII_apb_func.svh` | wrapper testbench (generated part + IP-specific part) |
| `tb/cov/SGMII_sva.sv`, `tb/cov/SGMII_apb_sva.sv` | coverage checkers (core, wrapper) |
| `scripts/apb/specs/SGMII.json` | register spec the wrapper, TB, checker and this page are generated from |

How to run the tests and the coverage flow: see [Running and verifying](#running-and-verifying).

## Parameters

`SGMII_apb` has the core's parameters and passes them to `SGMII_top` unchanged.

| Parameter | Type | Default |
|---|---|---|
| `LT_X` | int | `1250000` |
| `LT_SG` | int | `200000` |

## Wrapper pins

Pins of `SGMII_apb`. Widths of the pass-through pins are at the default parameters.

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
| `gtxd` | input | 8 | protocol pin, core port `gtxd` |
| `gtx_en` | input | 1 | protocol pin, core port `gtx_en` |
| `gtx_er` | input | 1 | protocol pin, core port `gtx_er` |
| `grxd` | output | 8 | protocol pin, core port `grxd` |
| `grx_dv` | output | 1 | protocol pin, core port `grx_dv` |
| `grx_er` | output | 1 | protocol pin, core port `grx_er` |
| `tx_code` | output | 10 | protocol pin, core port `tx_code` |
| `rx_code` | input | 10 | protocol pin, core port `rx_code` |

## Core ports

| Port | Dir | Width | In the APB wrapper |
|---|---|---|---|
| `clk` | input | 1 | PCLK |
| `rst_n` | input | 1 | PRESETN |
| `gtxd` | input | 8 | pin (pass-through) |
| `gtx_en` | input | 1 | pin (pass-through) |
| `gtx_er` | input | 1 | pin (pass-through) |
| `grxd` | output | 8 | pin (pass-through) |
| `grx_dv` | output | 1 | pin (pass-through) |
| `grx_er` | output | 1 | pin (pass-through) |
| `tx_code` | output | 10 | pin (pass-through) |
| `rx_code` | input | 10 | pin (pass-through) |
| `mode_sgmii` | input | 1 | CTRL[1:1] |
| `an_en` | input | 1 | CTRL[0:0] |
| `an_restart` | input | 1 | CMD |
| `adv` | input | 16 | CTRL[17:2] |
| `sync_ok` | output | 1 | STATUS[0:0] |
| `an_done` | output | 1 | STATUS[1:1] |
| `link_up` | output | 1 | STATUS[2:2] |
| `lp_ability` | output | 16 | LP_ABILITY[15:0] |
| `speed` | output | 2 | STATUS[4:3] |
| `full_duplex` | output | 1 | STATUS[5:5] |
| `irq_link` | output | 1 | IRQ_STATUS.LINK |
| `irq_an` | output | 1 | IRQ_STATUS.AN |
| `irq_err` | output | 1 | IRQ_STATUS.ERR |

## APB wrapper

`SGMII_apb` is an APB4 slave (AMBA APB protocol v2.0): zero wait states, 32-bit data, 12-bit byte address, PSTRB byte lanes on every writable register, PSLVERR on an unmapped or misaligned address (reads then return 0, writes are dropped). Writes to read-only registers are ignored without an error. The core runs on PCLK and PRESETN. `irq` is level-high: `|(IRQ_STATUS & IRQ_ENABLE)`.

Pass-through pins: `gtxd`, `gtx_en`, `gtx_er`, `grxd`, `grx_dv`, `grx_er`, `tx_code`, `rx_code`.

### Register map

| Offset | Name | Access | Reset | Description |
|---|---|---|---|---|
| 0x000 | ID | RO | 0x53470100 | IP identification: code, major and minor version |
| 0x004 | IRQ_STATUS | W1C | 0x00000000 | Sticky interrupt bits, write 1 to clear |
| 0x008 | IRQ_ENABLE | RW | 0x00000000 | Interrupt enables; irq = \|(IRQ_STATUS & IRQ_ENABLE) |
| 0x00C | FLAGS | RO | 0x00000000 | Stream holding-register state |
| 0x010 | SCRATCH | RW | 0x00000000 | Scratch register, no effect on the core |
| 0x014 | STATUS | RO | core | Link state |
| 0x018 | LP_ABILITY | RO | core | The partner's config word captured by auto-negotiation |
| 0x01C | CTRL | RW | 0x00000681 | Mode and advertised abilities |
| 0x020 | CMD | WO (pulse) | 0x00000000 | Commands |

Unlisted bits read 0 and ignore writes. Reset "core": the register reads the core's outputs directly, so after reset it shows the core's own reset state. WO (pulse) registers read 0. Offsets from 0x024 up to 0xFFC are unmapped (PSLVERR).

### Fields

| Register | Bits | Field | Access | Reset | Description |
|---|---|---|---|---|---|
| ID | 31:16 | CODE | RO | 0x5347 | IP code |
| ID | 15:8 | MAJOR | RO | 0x01 | major version |
| ID | 7:0 | MINOR | RO | 0x00 | minor version |
| IRQ_STATUS | 2:0 | one bit per interrupt | W1C | 0x0 | see Interrupts |
| IRQ_ENABLE | 2:0 | one bit per interrupt | RW | 0x0 | 1 enables the IRQ_STATUS bit onto `irq` |
| SCRATCH | 31:0 | SCRATCH | RW | 0x00000000 | free for software |
| STATUS | 0 | `sync_ok` | RO | core | code-group synchronisation acquired (clause 36 synchronisation in SYNC_ACQUIRED_1..4) |
| STATUS | 1 | `an_done` | RO | core | auto-negotiation in LINK_OK |
| STATUS | 2 | `link_up` | RO | core | sync and AN done (and the PHY's link bit in SGMII mode), or sync with AN disabled |
| STATUS | 4:3 | `speed` | RO | core | 00 10, 01 100, 10 1000 Mb/s (the partner's speed in SGMII mode, always 10 in 1000BASE-X) |
| STATUS | 5 | `full_duplex` | RO | core | duplex result: partner bit 12 in SGMII mode, adv[5] and partner bit 5 in 1000BASE-X |
| LP_ABILITY | 15:0 | `lp_ability` | RO | core | the partner's base page; [14] is set once it acknowledged |
| CTRL | 0 | `an_en` | RW | 0x1 | auto-negotiation enable (0: data as soon as sync is acquired) |
| CTRL | 1 | `mode_sgmii` | RW | 0x0 | 1: SGMII (MAC side, sends 0x0001, SGMII link timer), 0: 1000BASE-X |
| CTRL | 17:2 | `adv` | RW | 0x1A0 | 1000BASE-X abilities sent in /C/ ([5] FD, [6] HD, [8:7] pause, [13:12] remote fault, [15] next page); [14] is ignored |
| CMD | 0 | `an_restart` | WO (pulse) | 0x0 | write 1: restart auto-negotiation |

### Interrupts (IRQ_STATUS, IRQ_ENABLE)

A bit is set while its source is active, stays set until written with 1, and a set in the same clock as the clear wins.

| Bit | Name | Set when |
|---|---|---|
| 0 | LINK | link_up changed |
| 1 | AN | auto-negotiation completed |
| 2 | ERR | an invalid code group or a comma on an odd position while in sync, a false carrier, or an error in a received packet |

## Programming sequence

1. Release PRESETN. Read ID (0x000) and check it is 0x53470100.
2. Write 0x7 to IRQ_STATUS (0x004) to clear any stale bits.
3. Configure the core: write CTRL (0x01C). Reset values are in the register map; PSTRB selects the bytes written.
4. Write IRQ_ENABLE (0x008) with the interrupts to use (bit order as in the Interrupts table; 0x7 enables all).
5. Read STATUS (0x014) for the core's live `sync_ok`, `an_done`, `link_up`, `speed`, `full_duplex`; it needs no clearing.
6. Read LP_ABILITY (0x018) for the core's live `lp_ability`; it needs no clearing.
7. To issue a command, write 1 to `an_restart` (CMD bit 0) at 0x020; the core sees a one-clock pulse, and the register reads 0.
8. On `irq`: read IRQ_STATUS, handle every bit that is set and enabled, then write those bits back to IRQ_STATUS to clear them. A source that is still active sets its bit again.

## Running and verifying

All commands run from the repository root. Icarus Verilog 12 and Yosys 0.33 are enough for steps 1 to 3; step 4 also needs Verilator 5.052 and pyslang (see [README, Setup](../../README.md#setup)).

| Step | Command | Pass when | Output |
|---|---|---|---|
| 1. Core test | `make -f Makefile.SGMII sim` | a `TEST PASSED` line, no `ERROR` | console |
| 2. Core synthesis | `make -f Makefile.SGMII syn` | Yosys ends without `ERROR`; `stat` prints the cell count | `work/SGMII_top.json` |
| 3. APB wrapper test + synthesis | `make -f Makefile.SGMII apb` | `TEST PASSED: SGMII_apb`, then Yosys without `ERROR` | console, `work/SGMII_apb.json` |
| 4. Coverage (core, wrapper) | `bash scripts/cov/run_cov.sh SGMII`<br>`bash scripts/cov/run_cov.sh SGMII_apb` | `RESULT: CLOSED` (all five metrics 100%) | `work/cov/SGMII/score.json`, `work/cov/SGMII_apb/score.json` |

Expected end of a step 4 run:

```
===== SGMII =====
TEST: PASSED   SVA_FAILURES: 0
LINE ... TOGGLE ... FSM ... SVA ... FUNCTIONAL  (each n/n, 100.0%)
RESULT: CLOSED
```

**Core test** (`tb/SGMII_tb.sv`): drives `SGMII_top` through its own ports against a protocol peer or model and checks every result itself; any mismatch prints `ERROR`, and `TEST PASSED` is printed only when there were none.

**APB wrapper test** (`tb/SGMII_apb_tb.sv`), in this order:

1. Reset values of every register, ID included.
2. Writes to read-only registers are ignored.
3. Each RW register: all ones, all zeros, then 16 random writes with every PSTRB byte-lane pattern, read back each time.
4. Unmapped and misaligned addresses, reads and writes: PSLVERR, read data 0, no side effect on other registers.
5. Back-to-back transfers with no idle cycle.
6. IP traffic through the registers only (`tb/apb/SGMII_apb_func.svh`): the programming sequence above, every interrupt bit set, enabled and cleared (100% wrapper toggle coverage confirms each bit moved).
7. PRESETN asserted mid-run: `irq` and PRDATA go to 0, registers return to reset values.

**Checkers** (`tb/cov/SGMII_sva.sv`, `tb/cov/SGMII_apb_sva.sv`): SVA protocol and APB assertions plus covergroups, bound in by the coverage flow. An assertion failure prints `SVA_FAIL` and fails the run even when the test itself passed.

Whole portfolio: `bash scripts/ci_regression.sh` runs steps 1 to 3 for every IP (what CI runs), and `bash scripts/cov/run_all.sh 4` runs step 4 for every IP.

## Verification

Five-metric coverage with Verilator 5.052 (`scripts/cov/run_cov.sh`); see [COVERAGE_CLOSURE.md](../COVERAGE_CLOSURE.md) for the flow. Line and toggle count only the named RTL file.

| Scope | Test | Line | Toggle | FSM | SVA | Functional |
|---|---|---|---|---|---|---|
| core `rtl/SGMII_top.sv` | not run | | | | | |
| wrapper `rtl/SGMII_apb.sv` | not run | | | | | |
