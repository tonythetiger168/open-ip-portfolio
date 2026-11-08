# TV panel timing controller: frame scan-out from memory over AXI4 to a V-by-One HS style 8-lane link

Protocol IP `TCON_VbyOne`, version 1.0. Apache-2.0.

| Item | Value |
|---|---|
| Core | `TCON_VbyOne_top` (`rtl/TCON_VbyOne_top.sv`) |
| Register interface | APB4 slave `TCON_VbyOne_apb`, 32-bit data, 12-bit byte address, zero wait states |
| Clock, reset | PCLK (rising edge), PRESETN (active low, asynchronous) |
| ID register | 0x7C030100 (code 0x7C03, version 1.0) |
| Registers | 12 words, 0x000 to 0x02C |
| Interrupts | 3 sources into one level-high `irq` |
| Protocol pins | 36 pass-through |

## Overview

TCON_VbyOne: timing controller / panel link transmitter of the TV SoC: a frame fetch DMA (AXI4 manager) feeding a V-by-One HS style multi-lane link (APB4 registers) Link abstraction: LANES byte lanes, 8b/10b and serialisation outside the IP. vbo_lane_d[8l+7:8l] / vbo_lane_k[l] is the symbol of lane l (k = 1: control symbol); a new symbol is presented every SYM_DIV clocks (vbo_sym marks the first clock of each symbol; SYM_DIV 0 counts as 1).

- Handshake: while the panel's vbo_htpdn_n is high (no panel) or its
vbo_lockn_n is high (CDR not locked), every lane sends the CDR training
symbol D10.2 (8'h4A, k = 0). Locked and idle, the lanes send K28.5
(8'hBC, k = 1).
- Pixels: 4-byte mode, one pixel word per lane per 4 symbols, byte j of
the word (bits 8j+7:8j) in symbol j. Pixel p of a line goes to lane
p % LANES; a line is sent in groups of LANES pixels (the last group of a
line whose H_ACTIVE is not a multiple of LANES is padded with zero
words).
- Each line is preceded by one control symbol on all lanes: K28.2 (8'h5C)
before the first line of a frame, K28.0 (8'h1C) before the others, and
followed by HBLANK idle symbols (at least 1).
- Frame: START (when not busy) fetches V_ACTIVE lines of H_ACTIVE words,
line k from FB_ADDR + k * STRIDE (one engine job per line, prefetching
through a FIFO), and sends them once the link is locked. A line starts
only when the FIFO holds the whole line or is half full; if a group is
not ready in time the lanes send idle symbols inside the line and
UNDERRUN is set. Losing lock during a frame sets LOCK_LOST (the frame
goes on). DONE pulses after the last symbol of the frame; ERR as well
when an AXI error response was seen.

Features:

- Lane training (D10.2) until vbo_lockn_n is low; idle K28.5; K28.2 before line 0 and K28.0 before every other line.
- 4-byte mode: pixel p of a line goes to lane p % LANES, byte j in symbol j; a new symbol every SYM_DIV clocks (0 counts as 1), vbo_sym on its first clock.
- CMD.start scans out V_ACTIVE lines of H_ACTIVE pixels from FB_ADDR + k * STRIDE, HBLANK idle symbols between lines.
- A line starts once min(H_ACTIVE, FIFO_DEPTH / 2) of its words are buffered; the group register loads one word per clock, so SYM_DIV must be at least 3 with 8 lanes.
- STATUS.underrun: the next lane group was not ready inside a line (idle symbols sent); lock loss during a frame sets STATUS.lock_lost (LOCK interrupt); the frame goes on once lock returns.

m_* is the AXI4 manager port (32-bit address and data, 4-bit ID, no user / QoS); it passes through unchanged. Bursts are INCR, AxSIZE = 2 (4 bytes), 1 to 16 beats, WSTRB = 4'hF, never across a 4 KB boundary; one read and one write burst are outstanding at a time.
vbo_lane_d / vbo_lane_k / vbo_sym (out) and vbo_htpdn_n / vbo_lockn_n (in) are the link pins; serialisation and 8b/10b coding are in the PHY.
The core testbench prints one `LAT <master> dram R|W <cycles>` line per AXI burst (tb/tv_lat_mon.svh), the regression suite's latency format.

## Files

| File | Content |
|---|---|
| `rtl/TCON_VbyOne_top.sv` | protocol core |
| `rtl/TCON_VbyOne_apb.sv` | APB4 register wrapper (generated) |
| `tb/TCON_VbyOne_tb.sv` | core testbench |
| `tb/TCON_VbyOne_apb_tb.sv`, `tb/apb/TCON_VbyOne_apb_func.svh` | wrapper testbench (generated part + IP-specific part) |
| `tb/cov/TCON_VbyOne_sva.sv`, `tb/cov/TCON_VbyOne_apb_sva.sv` | coverage checkers (core, wrapper) |
| `scripts/apb/specs/TCON_VbyOne.json` | register spec the wrapper, TB, checker and this page are generated from |

How to run the tests and the coverage flow: see [Running and verifying](#running-and-verifying).

## Parameters

`TCON_VbyOne_apb` has the core's parameters and passes them to `TCON_VbyOne_top` unchanged.

| Parameter | Type | Default |
|---|---|---|
| `AXI_ID` | logic [3:0] | `4'd4` |
| `LANES` | int | `8` |
| `FIFO_DEPTH` | int | `64` |

## Wrapper pins

Pins of `TCON_VbyOne_apb`. Widths of the pass-through pins are at the default parameters.

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
| `vbo_lane_d` | output | 64 | protocol pin, core port `vbo_lane_d` |
| `vbo_lane_k` | output | 8 | protocol pin, core port `vbo_lane_k` |
| `vbo_sym` | output | 1 | protocol pin, core port `vbo_sym` |
| `vbo_htpdn_n` | input | 1 | protocol pin, core port `vbo_htpdn_n` |
| `vbo_lockn_n` | input | 1 | protocol pin, core port `vbo_lockn_n` |
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
| `vbo_lane_d` | output | 64 | pin (pass-through) |
| `vbo_lane_k` | output | 8 | pin (pass-through) |
| `vbo_sym` | output | 1 | pin (pass-through) |
| `vbo_htpdn_n` | input | 1 | pin (pass-through) |
| `vbo_lockn_n` | input | 1 | pin (pass-through) |
| `fb_addr` | input | 32 | FB_ADDR[31:0] |
| `stride` | input | 16 | GEOM[15:0] |
| `h_active` | input | 16 | GEOM[31:16] |
| `v_active` | input | 16 | TIMING[15:0] |
| `hblank` | input | 8 | TIMING[23:16] |
| `sym_div` | input | 4 | TIMING[27:24] |
| `start` | input | 1 | CMD |
| `busy` | output | 1 | STATUS[0:0] |
| `err` | output | 1 | STATUS[1:1] |
| `underrun` | output | 1 | STATUS[2:2] |
| `lock_lost` | output | 1 | STATUS[3:3] |
| `locked` | output | 1 | STATUS[4:4] |
| `lines` | output | 16 | LINES[15:0] |
| `cycles` | output | 32 | CYCLES[31:0] |
| `done` | output | 1 | IRQ_STATUS.DONE |
| `err_irq` | output | 1 | IRQ_STATUS.ERR |
| `lock_irq` | output | 1 | IRQ_STATUS.LOCK |
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

`TCON_VbyOne_apb` is an APB4 slave (AMBA APB protocol v2.0): zero wait states, 32-bit data, 12-bit byte address, PSTRB byte lanes on every writable register, PSLVERR on an unmapped or misaligned address (reads then return 0, writes are dropped). Writes to read-only registers are ignored without an error. The core runs on PCLK and PRESETN. `irq` is level-high: `|(IRQ_STATUS & IRQ_ENABLE)`.

Pass-through pins: `vbo_lane_d`, `vbo_lane_k`, `vbo_sym`, `vbo_htpdn_n`, `vbo_lockn_n`, `m_awid`, `m_awaddr`, `m_awlen`, `m_awsize`, `m_awburst`, `m_awprot`, `m_awvalid`, `m_awready`, `m_wdata`, `m_wstrb`, `m_wlast`, `m_wvalid`, `m_wready`, `m_bid`, `m_bresp`, `m_bvalid`, `m_bready`, `m_arid`, `m_araddr`, `m_arlen`, `m_arsize`, `m_arburst`, `m_arprot`, `m_arvalid`, `m_arready`, `m_rid`, `m_rdata`, `m_rresp`, `m_rlast`, `m_rvalid`, `m_rready`.

### Register map

| Offset | Name | Access | Reset | Description |
|---|---|---|---|---|
| 0x000 | ID | RO | 0x7C030100 | IP identification: code, major and minor version |
| 0x004 | IRQ_STATUS | W1C | 0x00000000 | Sticky interrupt bits, write 1 to clear |
| 0x008 | IRQ_ENABLE | RW | 0x00000000 | Interrupt enables; irq = \|(IRQ_STATUS & IRQ_ENABLE) |
| 0x00C | FLAGS | RO | 0x00000000 | Stream holding-register state |
| 0x010 | SCRATCH | RW | 0x00000000 | Scratch register, no effect on the core |
| 0x014 | FB_ADDR | RW | 0x00000000 | Frame buffer address |
| 0x018 | GEOM | RW | 0x00000000 | Line pitch and width |
| 0x01C | TIMING | RW | 0x00000000 | Frame timing |
| 0x020 | CMD | WO (pulse) | 0x00000000 | Commands (write 1) |
| 0x024 | STATUS | RO | core | State |
| 0x028 | LINES | RO | core | Lines sent |
| 0x02C | CYCLES | RO | core | Frame length in clocks |

Unlisted bits read 0 and ignore writes. Reset "core": the register reads the core's outputs directly, so after reset it shows the core's own reset state. WO (pulse) registers read 0. Offsets from 0x030 up to 0xFFC are unmapped (PSLVERR).

### Fields

| Register | Bits | Field | Access | Reset | Description |
|---|---|---|---|---|---|
| ID | 31:16 | CODE | RO | 0x7C03 | IP code |
| ID | 15:8 | MAJOR | RO | 0x01 | major version |
| ID | 7:0 | MINOR | RO | 0x00 | minor version |
| IRQ_STATUS | 2:0 | one bit per interrupt | W1C | 0x0 | see Interrupts |
| IRQ_ENABLE | 2:0 | one bit per interrupt | RW | 0x0 | 1 enables the IRQ_STATUS bit onto `irq` |
| SCRATCH | 31:0 | SCRATCH | RW | 0x00000000 | free for software |
| FB_ADDR | 31:0 | `fb_addr` | RW | 0x0 | line 0, word aligned |
| GEOM | 15:0 | `stride` | RW | 0x0 | line pitch in bytes |
| GEOM | 31:16 | `h_active` | RW | 0x0 | pixels per line |
| TIMING | 15:0 | `v_active` | RW | 0x0 | lines per frame |
| TIMING | 23:16 | `hblank` | RW | 0x0 | idle symbols between lines |
| TIMING | 27:24 | `sym_div` | RW | 0x0 | clocks per symbol (0 counts as 1) |
| CMD | 0 | `start` | WO (pulse) | 0x0 | scan out one frame; ignored while busy |
| STATUS | 0 | `busy` | RO | core | a frame is being sent |
| STATUS | 1 | `err` | RO | core | AXI error response |
| STATUS | 2 | `underrun` | RO | core | FIFO empty inside a line |
| STATUS | 3 | `lock_lost` | RO | core | lock was lost during the frame |
| STATUS | 4 | `locked` | RO | core | the receiver reports lock |
| LINES | 15:0 | `lines` | RO | core | lines sent by the current / last frame |
| CYCLES | 31:0 | `cycles` | RO | core | clocks from start to DONE |

### Interrupts (IRQ_STATUS, IRQ_ENABLE)

A bit is set while its source is active, stays set until written with 1, and a set in the same clock as the clear wins.

| Bit | Name | Set when |
|---|---|---|
| 0 | DONE | a job ended |
| 1 | ERR | a job ended that saw an AXI error response |
| 2 | LOCK | lock was lost |

## Programming sequence

1. Release PRESETN. Read ID (0x000) and check it is 0x7C030100.
2. Write 0x7 to IRQ_STATUS (0x004) to clear any stale bits.
3. Configure the core: write FB_ADDR (0x014), GEOM (0x018), TIMING (0x01C). Reset values are in the register map; PSTRB selects the bytes written.
4. Write IRQ_ENABLE (0x008) with the interrupts to use (bit order as in the Interrupts table; 0x7 enables all).
5. To issue a command, write 1 to `start` (CMD bit 0) at 0x020; the core sees a one-clock pulse, and the register reads 0.
6. Read STATUS (0x024) for the core's live `busy`, `err`, `underrun`, `lock_lost`, `locked`; it needs no clearing.
7. Read LINES (0x028) for the core's live `lines`; it needs no clearing.
8. Read CYCLES (0x02C) for the core's live `cycles`; it needs no clearing.
9. On `irq`: read IRQ_STATUS, handle every bit that is set and enabled, then write those bits back to IRQ_STATUS to clear them. A source that is still active sets its bit again.

IP-specific use:

1. Wait for STATUS.locked = 1.
2. Write FB_ADDR, GEOM, TIMING and IRQ_ENABLE.
3. Write CMD.start = 1 once per frame (on DONE).

## Running and verifying

All commands run from the repository root. Icarus Verilog 12 and Yosys 0.33 are enough for steps 1 to 3; step 4 also needs Verilator 5.052 and pyslang (see [README, Setup](../../README.md#setup)).

| Step | Command | Pass when | Output |
|---|---|---|---|
| 1. Core test | `make -f Makefile.TCON_VbyOne sim` | a `TEST PASSED` line, no `ERROR` | console |
| 2. Core synthesis | `make -f Makefile.TCON_VbyOne syn` | Yosys ends without `ERROR`; `stat` prints the cell count | `work/TCON_VbyOne_top.json` |
| 3. APB wrapper test + synthesis | `make -f Makefile.TCON_VbyOne apb` | `TEST PASSED: TCON_VbyOne_apb`, then Yosys without `ERROR` | console, `work/TCON_VbyOne_apb.json` |
| 4. Coverage (core, wrapper) | `bash scripts/cov/run_cov.sh TCON_VbyOne`<br>`bash scripts/cov/run_cov.sh TCON_VbyOne_apb` | `RESULT: CLOSED` (all five metrics 100%) | `work/cov/TCON_VbyOne/score.json`, `work/cov/TCON_VbyOne_apb/score.json` |

Expected end of a step 4 run:

```
===== TCON_VbyOne =====
TEST: PASSED   SVA_FAILURES: 0
LINE ... TOGGLE ... FSM ... SVA ... FUNCTIONAL  (each n/n, 100.0%)
RESULT: CLOSED
```

**Core test** (`tb/TCON_VbyOne_tb.sv`): drives `TCON_VbyOne_top` through its own ports against a protocol peer or model and checks every result itself; any mismatch prints `ERROR`, and `TEST PASSED` is printed only when there were none.

**APB wrapper test** (`tb/TCON_VbyOne_apb_tb.sv`), in this order:

1. Reset values of every register, ID included.
2. Writes to read-only registers are ignored.
3. Each RW register: all ones, all zeros, then 16 random writes with every PSTRB byte-lane pattern, read back each time.
4. Unmapped and misaligned addresses, reads and writes: PSLVERR, read data 0, no side effect on other registers.
5. Back-to-back transfers with no idle cycle.
6. IP traffic through the registers only (`tb/apb/TCON_VbyOne_apb_func.svh`): the programming sequence above, every interrupt bit set, enabled and cleared (100% wrapper toggle coverage confirms each bit moved).
7. PRESETN asserted mid-run: `irq` and PRDATA go to 0, registers return to reset values.

**Checkers** (`tb/cov/TCON_VbyOne_sva.sv`, `tb/cov/TCON_VbyOne_apb_sva.sv`): SVA protocol and APB assertions plus covergroups, bound in by the coverage flow. An assertion failure prints `SVA_FAIL` and fails the run even when the test itself passed.

Whole portfolio: `bash scripts/ci_regression.sh` runs steps 1 to 3 for every IP (what CI runs), and `bash scripts/cov/run_all.sh 4` runs step 4 for every IP.

## Verification

Five-metric coverage with Verilator 5.052 (`scripts/cov/run_cov.sh`); see [COVERAGE_CLOSURE.md](../COVERAGE_CLOSURE.md) for the flow. Line and toggle count only the named RTL file.

| Scope | Test | Line | Toggle | FSM | SVA | Functional |
|---|---|---|---|---|---|---|
| core `rtl/TCON_VbyOne_top.sv` | not run | | | | | |
| wrapper `rtl/TCON_VbyOne_apb.sv` | not run | | | | | |
