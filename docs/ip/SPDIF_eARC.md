# S/PDIF (IEC 60958) and HDMI eARC audio receiver: biphase decode, samples to a ring in memory over AXI4

Protocol IP `SPDIF_eARC`, version 1.0. Apache-2.0.

| Item | Value |
|---|---|
| Core | `SPDIF_eARC_top` (`rtl/SPDIF_eARC_top.sv`) |
| Register interface | APB4 slave `SPDIF_eARC_apb`, 32-bit data, 12-bit byte address, zero wait states |
| Clock, reset | PCLK (rising edge), PRESETN (active low, asynchronous) |
| ID register | 0x7C050100 (code 0x7C05, version 1.0) |
| Registers | 15 words, 0x000 to 0x038 |
| Interrupts | 4 sources into one level-high `irq` |
| Protocol pins | 32 pass-through |

## Overview

SPDIF_eARC: IEC 60958 audio receiver of the TV SoC (S/PDIF input and the HDMI eARC data channel, which carries the same biphase-mark coded subframes) with an audio ring DMA (AXI4 manager, APB4 registers) Input spdif_in is the biphase-mark line, oversampled by clk (two-flop synchroniser). UI_CLKS is the length of one UI (half a bit cell) in clks, at least 4. Intervals between line transitions are classed as 1, 2 or 3 UI (thresholds 1.5 / 2.5 / 3.5 UI); anything longer, or a 3-UI interval inside the data, is a coding error.

- Preambles (by interval sequence): B = 3,1,1,3 (channel A, block start),
M = 3,3,1,1 (channel A), W = 3,2,1,2 (channel B). Then 28 data slots,
'1' = two 1-UI intervals, '0' = one 2-UI interval: slots 4..27 are the
24-bit sample (LSB first), then V, U, C, P (even parity over 4..31).
- Lock: LOCKED after 4 good subframes in a row; a coding error drops it;
when it was locked, the error counts in CODE_ERR_CNT and raises LOCK_LOST.
- Channel status: the C bits of channel A in frames 0..31 of a block (from
B) are collected into CS0 (frame 0 in bit 0); CS pulses when a new CS0
is complete.
- Samples (locked only) are written as words {chan_b, block_start, V, U, C,
parity_err, 2'b00, sample[23:0]} through a 64-word FIFO to the ring at
RING_BASE: chunks of 16 words (one engine job each) to RING_BASE + 4 *
WR_IDX; RING_WORDS (a multiple of 16, at least 32) words; software
consumes them and writes RD_IDX; a chunk is written only when 16 words
are free (WR_IDX + 16 must not reach RD_IDX). A sample that finds the FIFO
full is dropped (OVF_CNT). CHUNK pulses when a chunk is in memory, ERR
as well on an AXI error response. PERR_CNT counts parity errors,
SAMPLES the subframes received.
- Not implemented: the eARC common-mode (discovery / heartbeat) channel and
eARC ECC; the IEC 61937 compressed-audio payload passes through as data.

Features:

- spdif_in biphase-mark decode with a UI of UI_CLKS clocks (pulses of 1, 2 or 3 UI); preambles B, M, W.
- Locks after 4 good subframes; a bad pulse or preamble drops lock (CODE_ERR_CNT, LOCK_LOST interrupt).
- Sample word {chan_b, block_start, V, U, C, parity_err, 2'b00, sample[23:0]} per subframe, DMA'd in 16-word chunks to a ring of RING_WORDS words (a multiple of 16, at least 32).
- CS0: channel status bits 0..31 of channel A from the last block (CS interrupt when updated).

m_* is the AXI4 manager port (32-bit address and data, 4-bit ID, no user / QoS); it passes through unchanged. Bursts are INCR, AxSIZE = 2 (4 bytes), 1 to 16 beats, WSTRB = 4'hF, never across a 4 KB boundary; one read and one write burst are outstanding at a time.
spdif_in is the receiver pin (the eARC differential data channel after the PHY). The eARC common-mode channel and ECC are not implemented.
The core testbench prints one `LAT <master> dram R|W <cycles>` line per AXI burst (tb/tv_lat_mon.svh), the regression suite's latency format.

## Files

| File | Content |
|---|---|
| `rtl/SPDIF_eARC_top.sv` | protocol core |
| `rtl/SPDIF_eARC_apb.sv` | APB4 register wrapper (generated) |
| `tb/SPDIF_eARC_tb.sv` | core testbench |
| `tb/SPDIF_eARC_apb_tb.sv`, `tb/apb/SPDIF_eARC_apb_func.svh` | wrapper testbench (generated part + IP-specific part) |
| `tb/cov/SPDIF_eARC_sva.sv`, `tb/cov/SPDIF_eARC_apb_sva.sv` | coverage checkers (core, wrapper) |
| `scripts/apb/specs/SPDIF_eARC.json` | register spec the wrapper, TB, checker and this page are generated from |

How to run the tests and the coverage flow: see [Running and verifying](#running-and-verifying).

## Parameters

`SPDIF_eARC_apb` has the core's parameters and passes them to `SPDIF_eARC_top` unchanged.

| Parameter | Type | Default |
|---|---|---|
| `AXI_ID` | logic [3:0] | `4'd6` |

## Wrapper pins

Pins of `SPDIF_eARC_apb`. Widths of the pass-through pins are at the default parameters.

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
| `spdif_in` | input | 1 | protocol pin, core port `spdif_in` |
| `m_awid` | output | 4 | protocol pin, core port `m_awid` |
| `m_awaddr` | output | 32 | protocol pin, core port `m_awaddr` |
| `m_awlen` | output | 8 | protocol pin, core port `m_awlen` |
| `m_awsize` | output | 3 | protocol pin, core port `m_awsize` |
| `m_awburst` | output | 2 | protocol pin, core port `m_awburst` |
| `m_awprot` | output | 3 | protocol pin, core port `m_awprot` |
| `m_awvalid` | output | 1 | protocol pin, core port `m_awvalid` |
| `m_awready` | input | 1 | protocol pin, core port `m_awready` |
| `m_wdata` | output | 32 | protocol pin, core port `m_wdata` |
| `m_wstrb` | output | 4 | protocol pin, core port `m_wstrb` |
| `m_wlast` | output | 1 | protocol pin, core port `m_wlast` |
| `m_wvalid` | output | 1 | protocol pin, core port `m_wvalid` |
| `m_wready` | input | 1 | protocol pin, core port `m_wready` |
| `m_bid` | input | 4 | protocol pin, core port `m_bid` |
| `m_bresp` | input | 2 | protocol pin, core port `m_bresp` |
| `m_bvalid` | input | 1 | protocol pin, core port `m_bvalid` |
| `m_bready` | output | 1 | protocol pin, core port `m_bready` |
| `m_arid` | output | 4 | protocol pin, core port `m_arid` |
| `m_araddr` | output | 32 | protocol pin, core port `m_araddr` |
| `m_arlen` | output | 8 | protocol pin, core port `m_arlen` |
| `m_arsize` | output | 3 | protocol pin, core port `m_arsize` |
| `m_arburst` | output | 2 | protocol pin, core port `m_arburst` |
| `m_arprot` | output | 3 | protocol pin, core port `m_arprot` |
| `m_arvalid` | output | 1 | protocol pin, core port `m_arvalid` |
| `m_arready` | input | 1 | protocol pin, core port `m_arready` |
| `m_rid` | input | 4 | protocol pin, core port `m_rid` |
| `m_rdata` | input | 32 | protocol pin, core port `m_rdata` |
| `m_rresp` | input | 2 | protocol pin, core port `m_rresp` |
| `m_rlast` | input | 1 | protocol pin, core port `m_rlast` |
| `m_rvalid` | input | 1 | protocol pin, core port `m_rvalid` |
| `m_rready` | output | 1 | protocol pin, core port `m_rready` |

## Core ports

| Port | Dir | Width | In the APB wrapper |
|---|---|---|---|
| `clk` | input | 1 | PCLK |
| `rst_n` | input | 1 | PRESETN |
| `spdif_in` | input | 1 | pin (pass-through) |
| `enable` | input | 1 | CTRL[0:0] |
| `ui_clks` | input | 8 | CTRL[8:1] |
| `ring_base` | input | 32 | RING_BASE[31:0] |
| `ring_words` | input | 16 | RING_WORDS[15:0] |
| `rd_idx` | input | 16 | RD_IDX[15:0] |
| `locked` | output | 1 | STATUS[0:0] |
| `cs0` | output | 32 | CS0[31:0] |
| `wr_idx` | output | 16 | WR_IDX[15:0] |
| `samples` | output | 32 | SAMPLES[31:0] |
| `perr_cnt` | output | 16 | ERRS[15:0] |
| `code_err_cnt` | output | 16 | ERRS[31:16] |
| `ovf_cnt` | output | 16 | OVF_CNT[15:0] |
| `err` | output | 1 | STATUS[1:1] |
| `chunk` | output | 1 | IRQ_STATUS.CHUNK |
| `lock_lost` | output | 1 | IRQ_STATUS.LOCK_LOST |
| `cs` | output | 1 | IRQ_STATUS.CS |
| `err_irq` | output | 1 | IRQ_STATUS.ERR |
| `m_awid` | output | 4 | pin (pass-through) |
| `m_awaddr` | output | 32 | pin (pass-through) |
| `m_awlen` | output | 8 | pin (pass-through) |
| `m_awsize` | output | 3 | pin (pass-through) |
| `m_awburst` | output | 2 | pin (pass-through) |
| `m_awprot` | output | 3 | pin (pass-through) |
| `m_awvalid` | output | 1 | pin (pass-through) |
| `m_awready` | input | 1 | pin (pass-through) |
| `m_wdata` | output | 32 | pin (pass-through) |
| `m_wstrb` | output | 4 | pin (pass-through) |
| `m_wlast` | output | 1 | pin (pass-through) |
| `m_wvalid` | output | 1 | pin (pass-through) |
| `m_wready` | input | 1 | pin (pass-through) |
| `m_bid` | input | 4 | pin (pass-through) |
| `m_bresp` | input | 2 | pin (pass-through) |
| `m_bvalid` | input | 1 | pin (pass-through) |
| `m_bready` | output | 1 | pin (pass-through) |
| `m_arid` | output | 4 | pin (pass-through) |
| `m_araddr` | output | 32 | pin (pass-through) |
| `m_arlen` | output | 8 | pin (pass-through) |
| `m_arsize` | output | 3 | pin (pass-through) |
| `m_arburst` | output | 2 | pin (pass-through) |
| `m_arprot` | output | 3 | pin (pass-through) |
| `m_arvalid` | output | 1 | pin (pass-through) |
| `m_arready` | input | 1 | pin (pass-through) |
| `m_rid` | input | 4 | pin (pass-through) |
| `m_rdata` | input | 32 | pin (pass-through) |
| `m_rresp` | input | 2 | pin (pass-through) |
| `m_rlast` | input | 1 | pin (pass-through) |
| `m_rvalid` | input | 1 | pin (pass-through) |
| `m_rready` | output | 1 | pin (pass-through) |

## APB wrapper

`SPDIF_eARC_apb` is an APB4 slave (AMBA APB protocol v2.0): zero wait states, 32-bit data, 12-bit byte address, PSTRB byte lanes on every writable register, PSLVERR on an unmapped or misaligned address (reads then return 0, writes are dropped). Writes to read-only registers are ignored without an error. The core runs on PCLK and PRESETN. `irq` is level-high: `|(IRQ_STATUS & IRQ_ENABLE)`.

Pass-through pins: `spdif_in`, `m_awid`, `m_awaddr`, `m_awlen`, `m_awsize`, `m_awburst`, `m_awprot`, `m_awvalid`, `m_awready`, `m_wdata`, `m_wstrb`, `m_wlast`, `m_wvalid`, `m_wready`, `m_bid`, `m_bresp`, `m_bvalid`, `m_bready`, `m_arid`, `m_araddr`, `m_arlen`, `m_arsize`, `m_arburst`, `m_arprot`, `m_arvalid`, `m_arready`, `m_rid`, `m_rdata`, `m_rresp`, `m_rlast`, `m_rvalid`, `m_rready`.

### Register map

| Offset | Name | Access | Reset | Description |
|---|---|---|---|---|
| 0x000 | ID | RO | 0x7C050100 | IP identification: code, major and minor version |
| 0x004 | IRQ_STATUS | W1C | 0x00000000 | Sticky interrupt bits, write 1 to clear |
| 0x008 | IRQ_ENABLE | RW | 0x00000000 | Interrupt enables; irq = \|(IRQ_STATUS & IRQ_ENABLE) |
| 0x00C | FLAGS | RO | 0x00000000 | Stream holding-register state |
| 0x010 | SCRATCH | RW | 0x00000000 | Scratch register, no effect on the core |
| 0x014 | CTRL | RW | 0x00000000 | Enable and UI |
| 0x018 | RING_BASE | RW | 0x00000000 | Ring address |
| 0x01C | RING_WORDS | RW | 0x00000000 | Ring size |
| 0x020 | RD_IDX | RW | 0x00000000 | Software read index |
| 0x024 | WR_IDX | RO | core | Hardware write index |
| 0x028 | STATUS | RO | core | State |
| 0x02C | CS0 | RO | core | Channel status |
| 0x030 | SAMPLES | RO | core | Samples stored |
| 0x034 | ERRS | RO | core | Error counters |
| 0x038 | OVF_CNT | RO | core | Lost samples |

Unlisted bits read 0 and ignore writes. Reset "core": the register reads the core's outputs directly, so after reset it shows the core's own reset state. WO (pulse) registers read 0. Offsets from 0x03C up to 0xFFC are unmapped (PSLVERR).

### Fields

| Register | Bits | Field | Access | Reset | Description |
|---|---|---|---|---|---|
| ID | 31:16 | CODE | RO | 0x7C05 | IP code |
| ID | 15:8 | MAJOR | RO | 0x01 | major version |
| ID | 7:0 | MINOR | RO | 0x00 | minor version |
| IRQ_STATUS | 3:0 | one bit per interrupt | W1C | 0x0 | see Interrupts |
| IRQ_ENABLE | 3:0 | one bit per interrupt | RW | 0x0 | 1 enables the IRQ_STATUS bit onto `irq` |
| SCRATCH | 31:0 | SCRATCH | RW | 0x00000000 | free for software |
| CTRL | 0 | `enable` | RW | 0x0 | receiver on; 0 clears WR_IDX |
| CTRL | 8:1 | `ui_clks` | RW | 0x0 | clocks per unit interval |
| RING_BASE | 31:0 | `ring_base` | RW | 0x0 | word 0, 64-byte aligned |
| RING_WORDS | 15:0 | `ring_words` | RW | 0x0 | words, multiple of 16, at least 32 |
| RD_IDX | 15:0 | `rd_idx` | RW | 0x0 | next word software reads |
| WR_IDX | 15:0 | `wr_idx` | RO | core | next word the core writes |
| STATUS | 0 | `locked` | RO | core | biphase lock |
| STATUS | 1 | `err` | RO | core | AXI error response seen |
| CS0 | 31:0 | `cs0` | RO | core | channel A status bits 0..31 |
| SAMPLES | 31:0 | `samples` | RO | core | subframes written to the ring |
| ERRS | 15:0 | `perr_cnt` | RO | core | parity errors |
| ERRS | 31:16 | `code_err_cnt` | RO | core | coding errors |
| OVF_CNT | 15:0 | `ovf_cnt` | RO | core | chunks lost to a full ring |

### Interrupts (IRQ_STATUS, IRQ_ENABLE)

A bit is set while its source is active, stays set until written with 1, and a set in the same clock as the clear wins.

| Bit | Name | Set when |
|---|---|---|
| 0 | CHUNK | 16 samples were written |
| 1 | LOCK_LOST | lock was lost |
| 2 | CS | CS0 was updated |
| 3 | ERR | a job ended that saw an AXI error response |

## Programming sequence

1. Release PRESETN. Read ID (0x000) and check it is 0x7C050100.
2. Write 0xF to IRQ_STATUS (0x004) to clear any stale bits.
3. Configure the core: write CTRL (0x014), RING_BASE (0x018), RING_WORDS (0x01C), RD_IDX (0x020). Reset values are in the register map; PSTRB selects the bytes written.
4. Write IRQ_ENABLE (0x008) with the interrupts to use (bit order as in the Interrupts table; 0xF enables all).
5. Read WR_IDX (0x024) for the core's live `wr_idx`; it needs no clearing.
6. Read STATUS (0x028) for the core's live `locked`, `err`; it needs no clearing.
7. Read CS0 (0x02C) for the core's live `cs0`; it needs no clearing.
8. Read SAMPLES (0x030) for the core's live `samples`; it needs no clearing.
9. Read ERRS (0x034) for the core's live `perr_cnt`, `code_err_cnt`; it needs no clearing.
10. Read OVF_CNT (0x038) for the core's live `ovf_cnt`; it needs no clearing.
11. On `irq`: read IRQ_STATUS, handle every bit that is set and enabled, then write those bits back to IRQ_STATUS to clear them. A source that is still active sets its bit again.

IP-specific use:

1. Write CTRL.ui_clks (clock / (128 x fs)), RING_BASE, RING_WORDS, RD_IDX = 0.
2. Write CTRL.enable = 1 and IRQ_ENABLE with CHUNK.
3. On CHUNK, read the ring words RD_IDX .. WR_IDX - 1 and write RD_IDX.

## Running and verifying

All commands run from the repository root. Icarus Verilog 12 and Yosys 0.33 are enough for steps 1 to 3; step 4 also needs Verilator 5.052 and pyslang (see [README, Setup](../../README.md#setup)).

| Step | Command | Pass when | Output |
|---|---|---|---|
| 1. Core test | `make -f Makefile.SPDIF_eARC sim` | a `TEST PASSED` line, no `ERROR` | console |
| 2. Core synthesis | `make -f Makefile.SPDIF_eARC syn` | Yosys ends without `ERROR`; `stat` prints the cell count | `work/SPDIF_eARC_top.json` |
| 3. APB wrapper test + synthesis | `make -f Makefile.SPDIF_eARC apb` | `TEST PASSED: SPDIF_eARC_apb`, then Yosys without `ERROR` | console, `work/SPDIF_eARC_apb.json` |
| 4. Coverage (core, wrapper) | `bash scripts/cov/run_cov.sh SPDIF_eARC`<br>`bash scripts/cov/run_cov.sh SPDIF_eARC_apb` | `RESULT: CLOSED` (all five metrics 100%) | `work/cov/SPDIF_eARC/score.json`, `work/cov/SPDIF_eARC_apb/score.json` |

Expected end of a step 4 run:

```
===== SPDIF_eARC =====
TEST: PASSED   SVA_FAILURES: 0
LINE ... TOGGLE ... FSM ... SVA ... FUNCTIONAL  (each n/n, 100.0%)
RESULT: CLOSED
```

**Core test** (`tb/SPDIF_eARC_tb.sv`): drives `SPDIF_eARC_top` through its own ports against a protocol peer or model and checks every result itself; any mismatch prints `ERROR`, and `TEST PASSED` is printed only when there were none.

**APB wrapper test** (`tb/SPDIF_eARC_apb_tb.sv`), in this order:

1. Reset values of every register, ID included.
2. Writes to read-only registers are ignored.
3. Each RW register: all ones, all zeros, then 16 random writes with every PSTRB byte-lane pattern, read back each time.
4. Unmapped and misaligned addresses, reads and writes: PSLVERR, read data 0, no side effect on other registers.
5. Back-to-back transfers with no idle cycle.
6. IP traffic through the registers only (`tb/apb/SPDIF_eARC_apb_func.svh`): the programming sequence above, every interrupt bit set, enabled and cleared (100% wrapper toggle coverage confirms each bit moved).
7. PRESETN asserted mid-run: `irq` and PRDATA go to 0, registers return to reset values.

**Checkers** (`tb/cov/SPDIF_eARC_sva.sv`, `tb/cov/SPDIF_eARC_apb_sva.sv`): SVA protocol and APB assertions plus covergroups, bound in by the coverage flow. An assertion failure prints `SVA_FAIL` and fails the run even when the test itself passed.

Whole portfolio: `bash scripts/ci_regression.sh` runs steps 1 to 3 for every IP (what CI runs), and `bash scripts/cov/run_all.sh 4` runs step 4 for every IP.

## Verification

Five-metric coverage with Verilator 5.052 (`scripts/cov/run_cov.sh`); see [COVERAGE_CLOSURE.md](../COVERAGE_CLOSURE.md) for the flow. Line and toggle count only the named RTL file.

| Scope | Test | Line | Toggle | FSM | SVA | Functional |
|---|---|---|---|---|---|---|
| core `rtl/SPDIF_eARC_top.sv` | not run | | | | | |
| wrapper `rtl/SPDIF_eARC_apb.sv` | not run | | | | | |
