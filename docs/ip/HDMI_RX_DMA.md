# HDMI 2.1 receiver video capture: TMDS decode and frame write to memory over AXI4

Protocol IP `HDMI_RX_DMA`, version 1.0. Apache-2.0.

| Item | Value |
|---|---|
| Core | `HDMI_RX_DMA_top` (`rtl/HDMI_RX_DMA_top.sv`) |
| Register interface | APB4 slave `HDMI_RX_DMA_apb`, 32-bit data, 12-bit byte address, zero wait states |
| Clock, reset | PCLK (rising edge), PRESETN (active low, asynchronous) |
| ID register | 0x7C010100 (code 0x7C01, version 1.0) |
| Registers | 13 words, 0x000 to 0x030 |
| Interrupts | 3 sources into one level-high `irq` |
| Protocol pins | 35 pass-through |

## Overview

HDMI_RX_DMA: HDMI 2.1 receiver video path of the TV SoC with a frame capture DMA (AXI4 manager, APB4 registers) Link abstraction (the same as the portfolio's HDMI VIP): one 10-bit TMDS character per channel per clk on tmds_ch0 / ch1 / ch2 (blue / green / red); the PHY, clock recovery and character alignment are outside this IP.

- Control period: the four TMDS control tokens on ch0 carry {VSYNC, HSYNC}
(10'h354 = 00, 10'h0AB = 01, 10'h154 = 10, 10'h2AB = 11).
- Video period: any other character. The two-character video guard band
(ch0 = ch2 = 10'h2CC, ch1 = 10'h133) right after a control period is
skipped; every following character is TMDS-decoded to 8 bits per channel,
giving one pixel {8'h00, R, G, B} (one 32-bit word).
- Data islands (TERC4 packets) are not decoded: the source must send video
and control periods only (DVI / HDMI video mode).
Frame capture (one frame per ARM command):
- ARM waits for the next VSYNC rising edge, then captures V_ACTIVE lines
(video periods). Line k is written to FB_ADDR + k * STRIDE as H_ACTIVE
words: one engine job per line, bursts of up to 16 beats.
- A line with fewer than H_ACTIVE pixels is padded with zeros and a longer
one is cut; both set LEN_ERR. A pixel that finds the line FIFO full is
dropped (the line is padded) and sets OVF.
- DONE pulses when the last line is in memory; ERR as well when an AXI
error response was seen. LINES counts the lines captured, CYCLES the
clocks from the start of the frame to DONE.
- hpd follows HPD_EN (hot-plug detect towards the source).

Features:

- TMDS 8b/10b decode of three channels (tmds_ch0..2, one 10-bit character per clock per channel); control tokens on channel 0 give HSYNC / VSYNC, video guard bands are skipped.
- Pixel word {8'h00, R (ch2), G (ch1), B (ch0)}.
- CMD.arm starts a capture at the next VSYNC: line k of V_ACTIVE goes to FB_ADDR + k * STRIDE (H_ACTIVE words).
- Short lines are padded with zeros and long lines cut (STATUS.len_err); a full line FIFO drops pixels (STATUS.ovf, OVF interrupt).
- hpd follows CTRL.hpd_en (hot-plug detect to the source).

m_* is the AXI4 manager port (32-bit address and data, 4-bit ID, no user / QoS); it passes through unchanged. Bursts are INCR, AxSIZE = 2 (4 bytes), 1 to 16 beats, WSTRB = 4'hF, never across a 4 KB boundary; one read and one write burst are outstanding at a time.
tmds_ch0..2 (in) and hpd (out) are the link pins; the TMDS clock is the core clock (one character per clock). FRL (HDMI 2.1 fixed rate link) framing is out of scope: this is the TMDS mode.
The core testbench prints one `LAT <master> dram R|W <cycles>` line per AXI burst (tb/tv_lat_mon.svh), the regression suite's latency format.

## Files

| File | Content |
|---|---|
| `rtl/HDMI_RX_DMA_top.sv` | protocol core |
| `rtl/HDMI_RX_DMA_apb.sv` | APB4 register wrapper (generated) |
| `tb/HDMI_RX_DMA_tb.sv` | core testbench |
| `tb/HDMI_RX_DMA_apb_tb.sv`, `tb/apb/HDMI_RX_DMA_apb_func.svh` | wrapper testbench (generated part + IP-specific part) |
| `tb/cov/HDMI_RX_DMA_sva.sv`, `tb/cov/HDMI_RX_DMA_apb_sva.sv` | coverage checkers (core, wrapper) |
| `scripts/apb/specs/HDMI_RX_DMA.json` | register spec the wrapper, TB, checker and this page are generated from |

How to run the tests and the coverage flow: see [Running and verifying](#running-and-verifying).

## Parameters

`HDMI_RX_DMA_apb` has the core's parameters and passes them to `HDMI_RX_DMA_top` unchanged.

| Parameter | Type | Default |
|---|---|---|
| `AXI_ID` | logic [3:0] | `4'd2` |
| `FIFO_DEPTH` | int | `64` |

## Wrapper pins

Pins of `HDMI_RX_DMA_apb`. Widths of the pass-through pins are at the default parameters.

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
| `tmds_ch0` | input | 10 | protocol pin, core port `tmds_ch0` |
| `tmds_ch1` | input | 10 | protocol pin, core port `tmds_ch1` |
| `tmds_ch2` | input | 10 | protocol pin, core port `tmds_ch2` |
| `hpd` | output | 1 | protocol pin, core port `hpd` |
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
| `tmds_ch0` | input | 10 | pin (pass-through) |
| `tmds_ch1` | input | 10 | pin (pass-through) |
| `tmds_ch2` | input | 10 | pin (pass-through) |
| `hpd` | output | 1 | pin (pass-through) |
| `hpd_en` | input | 1 | CTRL |
| `fb_addr` | input | 32 | FB_ADDR[31:0] |
| `stride` | input | 16 | GEOM[15:0] |
| `h_active` | input | 16 | GEOM[31:16] |
| `v_active` | input | 16 | V_ACTIVE[15:0] |
| `arm` | input | 1 | CMD |
| `busy` | output | 1 | STATUS[0:0] |
| `err` | output | 1 | STATUS[1:1] |
| `ovf` | output | 1 | STATUS[2:2] |
| `len_err` | output | 1 | STATUS[3:3] |
| `vsync` | output | 1 | STATUS[4:4] |
| `hsync` | output | 1 | STATUS[5:5] |
| `lines` | output | 16 | LINES[15:0] |
| `cycles` | output | 32 | CYCLES[31:0] |
| `done` | output | 1 | IRQ_STATUS.DONE |
| `err_irq` | output | 1 | IRQ_STATUS.ERR |
| `ovf_irq` | output | 1 | IRQ_STATUS.OVF |
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

`HDMI_RX_DMA_apb` is an APB4 slave (AMBA APB protocol v2.0): zero wait states, 32-bit data, 12-bit byte address, PSTRB byte lanes on every writable register, PSLVERR on an unmapped or misaligned address (reads then return 0, writes are dropped). Writes to read-only registers are ignored without an error. The core runs on PCLK and PRESETN. `irq` is level-high: `|(IRQ_STATUS & IRQ_ENABLE)`.

Pass-through pins: `tmds_ch0`, `tmds_ch1`, `tmds_ch2`, `hpd`, `m_awid`, `m_awaddr`, `m_awlen`, `m_awsize`, `m_awburst`, `m_awprot`, `m_awvalid`, `m_awready`, `m_wdata`, `m_wstrb`, `m_wlast`, `m_wvalid`, `m_wready`, `m_bid`, `m_bresp`, `m_bvalid`, `m_bready`, `m_arid`, `m_araddr`, `m_arlen`, `m_arsize`, `m_arburst`, `m_arprot`, `m_arvalid`, `m_arready`, `m_rid`, `m_rdata`, `m_rresp`, `m_rlast`, `m_rvalid`, `m_rready`.

### Register map

| Offset | Name | Access | Reset | Description |
|---|---|---|---|---|
| 0x000 | ID | RO | 0x7C010100 | IP identification: code, major and minor version |
| 0x004 | IRQ_STATUS | W1C | 0x00000000 | Sticky interrupt bits, write 1 to clear |
| 0x008 | IRQ_ENABLE | RW | 0x00000000 | Interrupt enables; irq = \|(IRQ_STATUS & IRQ_ENABLE) |
| 0x00C | FLAGS | RO | 0x00000000 | Stream holding-register state |
| 0x010 | SCRATCH | RW | 0x00000000 | Scratch register, no effect on the core |
| 0x014 | CTRL | RW | 0x00000000 | Link control |
| 0x018 | FB_ADDR | RW | 0x00000000 | Frame buffer address |
| 0x01C | GEOM | RW | 0x00000000 | Line pitch and width |
| 0x020 | V_ACTIVE | RW | 0x00000000 | Lines per frame |
| 0x024 | CMD | WO (pulse) | 0x00000000 | Commands (write 1) |
| 0x028 | STATUS | RO | core | Capture state |
| 0x02C | LINES | RO | core | Lines written |
| 0x030 | CYCLES | RO | core | Capture length in clocks |

Unlisted bits read 0 and ignore writes. Reset "core": the register reads the core's outputs directly, so after reset it shows the core's own reset state. WO (pulse) registers read 0. Offsets from 0x034 up to 0xFFC are unmapped (PSLVERR).

### Fields

| Register | Bits | Field | Access | Reset | Description |
|---|---|---|---|---|---|
| ID | 31:16 | CODE | RO | 0x7C01 | IP code |
| ID | 15:8 | MAJOR | RO | 0x01 | major version |
| ID | 7:0 | MINOR | RO | 0x00 | minor version |
| IRQ_STATUS | 2:0 | one bit per interrupt | W1C | 0x0 | see Interrupts |
| IRQ_ENABLE | 2:0 | one bit per interrupt | RW | 0x0 | 1 enables the IRQ_STATUS bit onto `irq` |
| SCRATCH | 31:0 | SCRATCH | RW | 0x00000000 | free for software |
| CTRL | 0 | `hpd_en` | RW | 0x0 | drive hpd high |
| FB_ADDR | 31:0 | `fb_addr` | RW | 0x0 | line 0, word aligned |
| GEOM | 15:0 | `stride` | RW | 0x0 | line pitch in bytes |
| GEOM | 31:16 | `h_active` | RW | 0x0 | pixels per line |
| V_ACTIVE | 15:0 | `v_active` | RW | 0x0 | lines captured per frame |
| CMD | 0 | `arm` | WO (pulse) | 0x0 | capture the next frame; ignored while busy |
| STATUS | 0 | `busy` | RO | core | a capture is armed or running |
| STATUS | 1 | `err` | RO | core | AXI error response in the last capture |
| STATUS | 2 | `ovf` | RO | core | pixels dropped (FIFO full) |
| STATUS | 3 | `len_err` | RO | core | a line was short or long |
| STATUS | 4 | `vsync` | RO | core | decoded VSYNC |
| STATUS | 5 | `hsync` | RO | core | decoded HSYNC |
| LINES | 15:0 | `lines` | RO | core | lines written by the current / last capture |
| CYCLES | 31:0 | `cycles` | RO | core | clocks from VSYNC to DONE |

### Interrupts (IRQ_STATUS, IRQ_ENABLE)

A bit is set while its source is active, stays set until written with 1, and a set in the same clock as the clear wins.

| Bit | Name | Set when |
|---|---|---|
| 0 | DONE | a job ended |
| 1 | ERR | a job ended that saw an AXI error response |
| 2 | OVF | pixels were dropped |

## Programming sequence

1. Release PRESETN. Read ID (0x000) and check it is 0x7C010100.
2. Write 0x7 to IRQ_STATUS (0x004) to clear any stale bits.
3. Configure the core: write CTRL (0x014), FB_ADDR (0x018), GEOM (0x01C), V_ACTIVE (0x020). Reset values are in the register map; PSTRB selects the bytes written.
4. Write IRQ_ENABLE (0x008) with the interrupts to use (bit order as in the Interrupts table; 0x7 enables all).
5. To issue a command, write 1 to `arm` (CMD bit 0) at 0x024; the core sees a one-clock pulse, and the register reads 0.
6. Read STATUS (0x028) for the core's live `busy`, `err`, `ovf`, `len_err`, `vsync`, `hsync`; it needs no clearing.
7. Read LINES (0x02C) for the core's live `lines`; it needs no clearing.
8. Read CYCLES (0x030) for the core's live `cycles`; it needs no clearing.
9. On `irq`: read IRQ_STATUS, handle every bit that is set and enabled, then write those bits back to IRQ_STATUS to clear them. A source that is still active sets its bit again.

IP-specific use:

1. Write CTRL.hpd_en = 1, FB_ADDR, GEOM and V_ACTIVE.
2. Write IRQ_ENABLE, then CMD.arm = 1.
3. Wait for DONE, check STATUS.len_err / ovf, write 1s to IRQ_STATUS.

## Running and verifying

All commands run from the repository root. Icarus Verilog 12 and Yosys 0.33 are enough for steps 1 to 3; step 4 also needs Verilator 5.052 and pyslang (see [README, Setup](../../README.md#setup)).

| Step | Command | Pass when | Output |
|---|---|---|---|
| 1. Core test | `make -f Makefile.HDMI_RX_DMA sim` | a `TEST PASSED` line, no `ERROR` | console |
| 2. Core synthesis | `make -f Makefile.HDMI_RX_DMA syn` | Yosys ends without `ERROR`; `stat` prints the cell count | `work/HDMI_RX_DMA_top.json` |
| 3. APB wrapper test + synthesis | `make -f Makefile.HDMI_RX_DMA apb` | `TEST PASSED: HDMI_RX_DMA_apb`, then Yosys without `ERROR` | console, `work/HDMI_RX_DMA_apb.json` |
| 4. Coverage (core, wrapper) | `bash scripts/cov/run_cov.sh HDMI_RX_DMA`<br>`bash scripts/cov/run_cov.sh HDMI_RX_DMA_apb` | `RESULT: CLOSED` (all five metrics 100%) | `work/cov/HDMI_RX_DMA/score.json`, `work/cov/HDMI_RX_DMA_apb/score.json` |

Expected end of a step 4 run:

```
===== HDMI_RX_DMA =====
TEST: PASSED   SVA_FAILURES: 0
LINE ... TOGGLE ... FSM ... SVA ... FUNCTIONAL  (each n/n, 100.0%)
RESULT: CLOSED
```

**Core test** (`tb/HDMI_RX_DMA_tb.sv`): drives `HDMI_RX_DMA_top` through its own ports against a protocol peer or model and checks every result itself; any mismatch prints `ERROR`, and `TEST PASSED` is printed only when there were none.

**APB wrapper test** (`tb/HDMI_RX_DMA_apb_tb.sv`), in this order:

1. Reset values of every register, ID included.
2. Writes to read-only registers are ignored.
3. Each RW register: all ones, all zeros, then 16 random writes with every PSTRB byte-lane pattern, read back each time.
4. Unmapped and misaligned addresses, reads and writes: PSLVERR, read data 0, no side effect on other registers.
5. Back-to-back transfers with no idle cycle.
6. IP traffic through the registers only (`tb/apb/HDMI_RX_DMA_apb_func.svh`): the programming sequence above, every interrupt bit set, enabled and cleared (100% wrapper toggle coverage confirms each bit moved).
7. PRESETN asserted mid-run: `irq` and PRDATA go to 0, registers return to reset values.

**Checkers** (`tb/cov/HDMI_RX_DMA_sva.sv`, `tb/cov/HDMI_RX_DMA_apb_sva.sv`): SVA protocol and APB assertions plus covergroups, bound in by the coverage flow. An assertion failure prints `SVA_FAIL` and fails the run even when the test itself passed.

Whole portfolio: `bash scripts/ci_regression.sh` runs steps 1 to 3 for every IP (what CI runs), and `bash scripts/cov/run_all.sh 4` runs step 4 for every IP.

## Verification

Five-metric coverage with Verilator 5.052 (`scripts/cov/run_cov.sh`); see [COVERAGE_CLOSURE.md](../COVERAGE_CLOSURE.md) for the flow. Line and toggle count only the named RTL file.

| Scope | Test | Line | Toggle | FSM | SVA | Functional |
|---|---|---|---|---|---|---|
| core `rtl/HDMI_RX_DMA_top.sv` | not run | | | | | |
| wrapper `rtl/HDMI_RX_DMA_apb.sv` | not run | | | | | |
