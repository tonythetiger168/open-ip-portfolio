# I2S audio port with an AXI4 DMA: one stereo frame per 32-bit word, TX and RX, underrun / overrun counters

Protocol IP `I2S_DMA`, version 1.0. Apache-2.0.

| Item | Value |
|---|---|
| Core | `I2S_DMA_top` (`rtl/I2S_DMA_top.sv`) |
| Register interface | APB4 slave `I2S_DMA_apb`, 32-bit data, 12-bit byte address, zero wait states |
| Clock, reset | PCLK (rising edge), PRESETN (active low, asynchronous) |
| ID register | 0x5C210100 (code 0x5C21, version 1.0) |
| Registers | 14 words, 0x000 to 0x034 |
| Interrupts | 2 sources into one level-high `irq` |
| Protocol pins | 35 pass-through |

## Overview

I2S_DMA: I2S audio port with an AXI4 DMA (AXI4 manager, APB4 registers) The unchanged I2S_top core (slave: BCLK and LRCK come from the codec), fed and drained by soc_ss_axi_engine. One 32-bit word per stereo frame: bits 15:0 left, bits 31:16 right.

- TX (TX_EN): the job reads LEN words from SRC. A word is taken at each
left-to-right LRCK change: its left half is written to the core then,
its right half at the next frame start, so word k plays in the frame
after the one it was taken in. With no word ready the frame repeats the
previous one and TX_UNDERRUN counts it.
- RX (RX_EN): the job writes LEN words to DST, one per frame received
entirely after START (the frame running at START is skipped). The
frame is taken one BCLK rise after the next frame start, when its right
word has its LSB. A word not accepted by the engine before the next
frame ends is replaced by it, and RX_OVERRUN counts the lost frame;
the job still writes LEN words.
- DONE interrupt when the job ends; ERR as well on an AXI error response.
FRAMES counts the frames played or received by the job.
- AXI ID = AXI_ID; bursts of up to 16 beats, never across 4 KB.

Features:

- The unchanged I2S_top core (16-bit Philips I2S slave) fed and drained by the shared AXI4 engine.
- One word per stereo frame: bits 15:0 left, bits 31:16 right.
- TX: word k plays in the frame after the one in which it was taken; with no word ready a frame repeats the previous one (TX_UNDERRUN).
- RX: one word per frame received entirely after START; a word not taken by the engine in time is replaced by the next frame (RX_OVERRUN).
- FRAMES counts the frames played (TX jobs) or received (RX-only jobs).

bclk, lrck, sdin and sdout are the I2S pins (slave: the codec drives BCLK and LRCK); they pass through unchanged. Each BCLK phase must last at least three clocks.
m_* is the AXI4 manager port (32-bit address and data, 4-bit ID, no user / QoS); it passes through unchanged. Bursts are INCR, AxSIZE = 2 (4 bytes), 1 to 16 beats, WSTRB = 4'hF, never across a 4 KB boundary; one read and one write burst are outstanding at a time. A read burst is issued only when its data has room, a write burst only when all its data is ready.

## Files

| File | Content |
|---|---|
| `rtl/I2S_DMA_top.sv` | protocol core |
| `rtl/I2S_DMA_apb.sv` | APB4 register wrapper (generated) |
| `tb/I2S_DMA_tb.sv` | core testbench |
| `tb/I2S_DMA_apb_tb.sv`, `tb/apb/I2S_DMA_apb_func.svh` | wrapper testbench (generated part + IP-specific part) |
| `tb/cov/I2S_DMA_sva.sv`, `tb/cov/I2S_DMA_apb_sva.sv` | coverage checkers (core, wrapper) |
| `scripts/apb/specs/I2S_DMA.json` | register spec the wrapper, TB, checker and this page are generated from |

How to run the tests and the coverage flow: see [Running and verifying](#running-and-verifying).

## Parameters

`I2S_DMA_apb` has the core's parameters and passes them to `I2S_DMA_top` unchanged.

| Parameter | Type | Default |
|---|---|---|
| `AXI_ID` | logic [3:0] | `4'd8` |

## Wrapper pins

Pins of `I2S_DMA_apb`. Widths of the pass-through pins are at the default parameters.

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
| `bclk` | input | 1 | protocol pin, core port `bclk` |
| `lrck` | input | 1 | protocol pin, core port `lrck` |
| `sdin` | input | 1 | protocol pin, core port `sdin` |
| `sdout` | output | 1 | protocol pin, core port `sdout` |
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
| `bclk` | input | 1 | pin (pass-through) |
| `lrck` | input | 1 | pin (pass-through) |
| `sdin` | input | 1 | pin (pass-through) |
| `sdout` | output | 1 | pin (pass-through) |
| `src_addr` | input | 32 | SRC_ADDR[31:0] |
| `dst_addr` | input | 32 | DST_ADDR[31:0] |
| `xfer_len` | input | 16 | LEN[15:0] |
| `tx_en` | input | 1 | CTRL[0:0] |
| `rx_en` | input | 1 | CTRL[1:1] |
| `start` | input | 1 | CMD |
| `busy` | output | 1 | STATUS[0:0] |
| `err` | output | 1 | STATUS[1:1] |
| `frames` | output | 16 | FRAMES[15:0] |
| `tx_underrun` | output | 16 | XRUN[15:0] |
| `rx_overrun` | output | 16 | XRUN[31:16] |
| `cycles` | output | 32 | CYCLES[31:0] |
| `done` | output | 1 | IRQ_STATUS.DONE |
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

`I2S_DMA_apb` is an APB4 slave (AMBA APB protocol v2.0): zero wait states, 32-bit data, 12-bit byte address, PSTRB byte lanes on every writable register, PSLVERR on an unmapped or misaligned address (reads then return 0, writes are dropped). Writes to read-only registers are ignored without an error. The core runs on PCLK and PRESETN. `irq` is level-high: `|(IRQ_STATUS & IRQ_ENABLE)`.

Pass-through pins: `bclk`, `lrck`, `sdin`, `sdout`, `m_awid`, `m_awaddr`, `m_awlen`, `m_awsize`, `m_awburst`, `m_awprot`, `m_awvalid`, `m_awready`, `m_wdata`, `m_wstrb`, `m_wlast`, `m_wvalid`, `m_wready`, `m_bid`, `m_bresp`, `m_bvalid`, `m_bready`, `m_arid`, `m_araddr`, `m_arlen`, `m_arsize`, `m_arburst`, `m_arprot`, `m_arvalid`, `m_arready`, `m_rid`, `m_rdata`, `m_rresp`, `m_rlast`, `m_rvalid`, `m_rready`.

### Register map

| Offset | Name | Access | Reset | Description |
|---|---|---|---|---|
| 0x000 | ID | RO | 0x5C210100 | IP identification: code, major and minor version |
| 0x004 | IRQ_STATUS | W1C | 0x00000000 | Sticky interrupt bits, write 1 to clear |
| 0x008 | IRQ_ENABLE | RW | 0x00000000 | Interrupt enables; irq = \|(IRQ_STATUS & IRQ_ENABLE) |
| 0x00C | FLAGS | RO | 0x00000000 | Stream holding-register state |
| 0x010 | SCRATCH | RW | 0x00000000 | Scratch register, no effect on the core |
| 0x014 | SRC_ADDR | RW | 0x00000000 | TX buffer (byte address, word aligned) |
| 0x018 | DST_ADDR | RW | 0x00000000 | RX buffer (byte address, word aligned) |
| 0x01C | LEN | RW | 0x00000000 | Job length |
| 0x020 | CTRL | RW | 0x00000000 | Job directions |
| 0x024 | CMD | WO (pulse) | 0x00000000 | Commands (write 1) |
| 0x028 | STATUS | RO | core | Job state |
| 0x02C | FRAMES | RO | core | Frames |
| 0x030 | XRUN | RO | core | Underrun / overrun counters (cleared by start) |
| 0x034 | CYCLES | RO | core | Job length in clocks |

Unlisted bits read 0 and ignore writes. Reset "core": the register reads the core's outputs directly, so after reset it shows the core's own reset state. WO (pulse) registers read 0. Offsets from 0x038 up to 0xFFC are unmapped (PSLVERR).

### Fields

| Register | Bits | Field | Access | Reset | Description |
|---|---|---|---|---|---|
| ID | 31:16 | CODE | RO | 0x5C21 | IP code |
| ID | 15:8 | MAJOR | RO | 0x01 | major version |
| ID | 7:0 | MINOR | RO | 0x00 | minor version |
| IRQ_STATUS | 1:0 | one bit per interrupt | W1C | 0x0 | see Interrupts |
| IRQ_ENABLE | 1:0 | one bit per interrupt | RW | 0x0 | 1 enables the IRQ_STATUS bit onto `irq` |
| SCRATCH | 31:0 | SCRATCH | RW | 0x00000000 | free for software |
| SRC_ADDR | 31:0 | `src_addr` | RW | 0x0 | first word played |
| DST_ADDR | 31:0 | `dst_addr` | RW | 0x0 | first word written |
| LEN | 15:0 | `xfer_len` | RW | 0x0 | frames (32-bit words); 0: the job ends at once |
| CTRL | 0 | `tx_en` | RW | 0x0 | play LEN words from SRC_ADDR |
| CTRL | 1 | `rx_en` | RW | 0x0 | record LEN frames to DST_ADDR |
| CMD | 0 | `start` | WO (pulse) | 0x0 | start a job (TX_EN or RX_EN set); ignored while busy |
| STATUS | 0 | `busy` | RO | core | a job is running |
| STATUS | 1 | `err` | RO | core | the current / last job saw an AXI error response (cleared by start) |
| FRAMES | 15:0 | `frames` | RO | core | frames played / received by the current / last job |
| XRUN | 15:0 | `tx_underrun` | RO | core | TX frames repeated for want of data |
| XRUN | 31:16 | `rx_overrun` | RO | core | RX frames lost (replaced by a newer one) |
| CYCLES | 31:0 | `cycles` | RO | core | clocks from start to DONE of the current / last job |

### Interrupts (IRQ_STATUS, IRQ_ENABLE)

A bit is set while its source is active, stays set until written with 1, and a set in the same clock as the clear wins.

| Bit | Name | Set when |
|---|---|---|
| 0 | DONE | a job ended |
| 1 | ERR | a job ended that saw an AXI error response |

## Programming sequence

1. Release PRESETN. Read ID (0x000) and check it is 0x5C210100.
2. Write 0x3 to IRQ_STATUS (0x004) to clear any stale bits.
3. Configure the core: write SRC_ADDR (0x014), DST_ADDR (0x018), LEN (0x01C), CTRL (0x020). Reset values are in the register map; PSTRB selects the bytes written.
4. Write IRQ_ENABLE (0x008) with the interrupts to use (bit order as in the Interrupts table; 0x3 enables all).
5. To issue a command, write 1 to `start` (CMD bit 0) at 0x024; the core sees a one-clock pulse, and the register reads 0.
6. Read STATUS (0x028) for the core's live `busy`, `err`; it needs no clearing.
7. Read FRAMES (0x02C) for the core's live `frames`; it needs no clearing.
8. Read XRUN (0x030) for the core's live `tx_underrun`, `rx_overrun`; it needs no clearing.
9. Read CYCLES (0x034) for the core's live `cycles`; it needs no clearing.
10. On `irq`: read IRQ_STATUS, handle every bit that is set and enabled, then write those bits back to IRQ_STATUS to clear them. A source that is still active sets its bit again.

IP-specific use:

1. Write SRC_ADDR / DST_ADDR (word aligned) and LEN (frames).
2. Write CTRL.tx_en / rx_en and IRQ_ENABLE.
3. Write CMD.start = 1.
4. Wait for irq, read FRAMES and XRUN, write 1s to IRQ_STATUS to clear it.

## Running and verifying

All commands run from the repository root. Icarus Verilog 12 and Yosys 0.33 are enough for steps 1 to 3; step 4 also needs Verilator 5.052 and pyslang (see [README, Setup](../../README.md#setup)).

| Step | Command | Pass when | Output |
|---|---|---|---|
| 1. Core test | `make -f Makefile.I2S_DMA sim` | a `TEST PASSED` line, no `ERROR` | console |
| 2. Core synthesis | `make -f Makefile.I2S_DMA syn` | Yosys ends without `ERROR`; `stat` prints the cell count | `work/I2S_DMA_top.json` |
| 3. APB wrapper test + synthesis | `make -f Makefile.I2S_DMA apb` | `TEST PASSED: I2S_DMA_apb`, then Yosys without `ERROR` | console, `work/I2S_DMA_apb.json` |
| 4. Coverage (core, wrapper) | `bash scripts/cov/run_cov.sh I2S_DMA`<br>`bash scripts/cov/run_cov.sh I2S_DMA_apb` | `RESULT: CLOSED` (all five metrics 100%) | `work/cov/I2S_DMA/score.json`, `work/cov/I2S_DMA_apb/score.json` |

Expected end of a step 4 run:

```
===== I2S_DMA =====
TEST: PASSED   SVA_FAILURES: 0
LINE ... TOGGLE ... FSM ... SVA ... FUNCTIONAL  (each n/n, 100.0%)
RESULT: CLOSED
```

**Core test** (`tb/I2S_DMA_tb.sv`): drives `I2S_DMA_top` through its own ports against a protocol peer or model and checks every result itself; any mismatch prints `ERROR`, and `TEST PASSED` is printed only when there were none.

**APB wrapper test** (`tb/I2S_DMA_apb_tb.sv`), in this order:

1. Reset values of every register, ID included.
2. Writes to read-only registers are ignored.
3. Each RW register: all ones, all zeros, then 16 random writes with every PSTRB byte-lane pattern, read back each time.
4. Unmapped and misaligned addresses, reads and writes: PSLVERR, read data 0, no side effect on other registers.
5. Back-to-back transfers with no idle cycle.
6. IP traffic through the registers only (`tb/apb/I2S_DMA_apb_func.svh`): the programming sequence above, every interrupt bit set, enabled and cleared (100% wrapper toggle coverage confirms each bit moved).
7. PRESETN asserted mid-run: `irq` and PRDATA go to 0, registers return to reset values.

**Checkers** (`tb/cov/I2S_DMA_sva.sv`, `tb/cov/I2S_DMA_apb_sva.sv`): SVA protocol and APB assertions plus covergroups, bound in by the coverage flow. An assertion failure prints `SVA_FAIL` and fails the run even when the test itself passed.

Whole portfolio: `bash scripts/ci_regression.sh` runs steps 1 to 3 for every IP (what CI runs), and `bash scripts/cov/run_all.sh 4` runs step 4 for every IP.

## Verification

Five-metric coverage with Verilator 5.052 (`scripts/cov/run_cov.sh`); see [COVERAGE_CLOSURE.md](../COVERAGE_CLOSURE.md) for the flow. Line and toggle count only the named RTL file.

| Scope | Test | Line | Toggle | FSM | SVA | Functional |
|---|---|---|---|---|---|---|
| core `rtl/I2S_DMA_top.sv` | not run | | | | | |
| wrapper `rtl/I2S_DMA_apb.sv` | not run | | | | | |
