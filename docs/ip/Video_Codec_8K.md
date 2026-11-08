# 8K video decoder traffic shape: HEVC / AV1 style CTU access pattern over AXI4 for SoC bandwidth and QoS tests

Protocol IP `Video_Codec_8K`, version 1.0. Apache-2.0.

| Item | Value |
|---|---|
| Core | `Video_Codec_8K_top` (`rtl/Video_Codec_8K_top.sv`) |
| Register interface | APB4 slave `Video_Codec_8K_apb`, 32-bit data, 12-bit byte address, zero wait states |
| Clock, reset | PCLK (rising edge), PRESETN (active low, asynchronous) |
| ID register | 0x7C090100 (code 0x7C09, version 1.0) |
| Registers | 21 words, 0x000 to 0x050 |
| Interrupts | 3 sources into one level-high `irq` |
| Protocol pins | 31 pass-through |

## Overview

Video_Codec_8K: 8K video decoder traffic shape of the TV SoC (AXI4 manager, APB4 registers) Reproduces the DRAM access pattern of an HEVC / AV1 style decoder, CTU by CTU in raster order, without the pixel arithmetic, so the interconnect, memory controller and QoS settings can be tested with the codec's real traffic mix (see docs/ip/Video_Codec_8K.md for the 8K60 numbers). The pixel codec itself is c1p-codec; this block stands in for it in the SoC regressions. Per CTU: 1. Bitstream: BS_WORDS words read in order from BS_ADDR on (the read pointer runs on over the whole picture). 2. Motion compensation: for each PU (2^PU_LOG2 square) and each reference r < N_REFS (REF0_ADDR, REF1_ADDR), a 2D block of (PU + 7) rows by (PU + 7) luma pixels (8-tap interpolation) at the PU position plus a motion vector (dx, dy); each block row is one read job of the words that cover it. dx and dy are random in [-2^MV_LOG2, 2^MV_LOG2 - 1] from a xorshift32 generator seeded with SEED (one step per block: dx from bits 15:0, dy from bits 31:16). The block origin (x + dx - 3, y + dy - 3) is clamped to the picture: 0 <= bx <= W - PU - 7, the same for y. 3. Reconstruction: the CTU's luma (2^CTU_LOG2 rows of 2^CTU_LOG2 bytes) at RECON_ADDR and its 4:2:0 interleaved chroma (half the rows, same width) at CHROMA_ADDR are written, one job per row; each written word is its byte address XOR SEED, so the frame can be checked.

- Pixels are 8-bit, 4 per word; STRIDE is the line pitch in bytes of all
planes. W = PIC_W_CTU << CTU_LOG2 pixels, H likewise.
- CTU_GAP shapes the rate: a CTU takes at least CTU_GAP clocks (start to
start); a CTU that takes longer counts in LATE_CNT (a real-time miss at
that rate). 0: back to back.
- CTU_LIMIT stops the job after that many CTUs (0: the whole picture), so
an 8K geometry can be sampled in simulation.
- CFG_ERR (job ends at once): CTU_LOG2 outside 4..6, PU_LOG2 outside
3..CTU_LOG2, N_REFS above 2, PIC_W_CTU or PIC_H_CTU 0.
- RD_WORDS, WR_WORDS, RD_SUM (32-bit sum of every word read), CTUS, CYCLES
report the last job. DONE pulses at the end, ERR as well on an AXI error.

Features:

- Per CTU in raster order: BS_WORDS bitstream words read, motion-compensated reference blocks ((PU + 7) x (PU + 7) luma, 1 or 2 references, xorshift32 motion vectors in +-2^MV_LOG2) read row by row, the CTU's luma and 4:2:0 chroma written row by row.
- Written words are address ^ SEED; RD_SUM is the sum of all words read.
- CTU_GAP rate shaping: a CTU takes at least CTU_GAP clocks; a slower CTU counts in LATE_CNT (LATE interrupt).
- CTU_LIMIT samples the first CTUs of a large picture; CFG_ERR on an invalid geometry.

m_* is the AXI4 manager port (32-bit address and data, 4-bit ID, no user / QoS); it passes through unchanged. Bursts are INCR, AxSIZE = 2 (4 bytes), 1 to 16 beats, WSTRB = 4'hF, never across a 4 KB boundary; one read and one write burst are outstanding at a time.
The pixel codec is c1p-codec; this core stands in for its memory traffic in SoC regressions.
The core testbench prints one `LAT <master> dram R|W <cycles>` line per AXI burst (tb/tv_lat_mon.svh), the regression suite's latency format.

## Files

| File | Content |
|---|---|
| `rtl/Video_Codec_8K_top.sv` | protocol core |
| `rtl/Video_Codec_8K_apb.sv` | APB4 register wrapper (generated) |
| `tb/Video_Codec_8K_tb.sv` | core testbench |
| `tb/Video_Codec_8K_apb_tb.sv`, `tb/apb/Video_Codec_8K_apb_func.svh` | wrapper testbench (generated part + IP-specific part) |
| `tb/cov/Video_Codec_8K_sva.sv`, `tb/cov/Video_Codec_8K_apb_sva.sv` | coverage checkers (core, wrapper) |
| `scripts/apb/specs/Video_Codec_8K.json` | register spec the wrapper, TB, checker and this page are generated from |

How to run the tests and the coverage flow: see [Running and verifying](#running-and-verifying).

## Parameters

`Video_Codec_8K_apb` has the core's parameters and passes them to `Video_Codec_8K_top` unchanged.

| Parameter | Type | Default |
|---|---|---|
| `AXI_ID` | logic [3:0] | `4'd9` |

## Wrapper pins

Pins of `Video_Codec_8K_apb`. Widths of the pass-through pins are at the default parameters.

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
| `bs_addr` | input | 32 | BS_ADDR[31:0] |
| `ref0_addr` | input | 32 | REF0_ADDR[31:0] |
| `ref1_addr` | input | 32 | REF1_ADDR[31:0] |
| `recon_addr` | input | 32 | RECON_ADDR[31:0] |
| `chroma_addr` | input | 32 | CHROMA_ADDR[31:0] |
| `stride` | input | 16 | PIC[15:0] |
| `pic_w_ctu` | input | 8 | PIC[23:16] |
| `pic_h_ctu` | input | 8 | PIC[31:24] |
| `ctu_log2` | input | 3 | CODING[2:0] |
| `pu_log2` | input | 3 | CODING[5:3] |
| `n_refs` | input | 2 | CODING[7:6] |
| `mv_log2` | input | 3 | CODING[10:8] |
| `bs_words` | input | 8 | CODING[18:11] |
| `ctu_gap` | input | 16 | RATE[15:0] |
| `ctu_limit` | input | 16 | RATE[31:16] |
| `seed` | input | 32 | SEED[31:0] |
| `start` | input | 1 | CMD |
| `busy` | output | 1 | STATUS[0:0] |
| `err` | output | 1 | STATUS[1:1] |
| `cfg_err` | output | 1 | STATUS[2:2] |
| `ctus` | output | 16 | CTUS[15:0] |
| `late_cnt` | output | 16 | CTUS[31:16] |
| `rd_words` | output | 32 | RD_WORDS[31:0] |
| `wr_words` | output | 32 | WR_WORDS[31:0] |
| `rd_sum` | output | 32 | RD_SUM[31:0] |
| `cycles` | output | 32 | CYCLES[31:0] |
| `done` | output | 1 | IRQ_STATUS.DONE |
| `late` | output | 1 | IRQ_STATUS.LATE |
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

`Video_Codec_8K_apb` is an APB4 slave (AMBA APB protocol v2.0): zero wait states, 32-bit data, 12-bit byte address, PSTRB byte lanes on every writable register, PSLVERR on an unmapped or misaligned address (reads then return 0, writes are dropped). Writes to read-only registers are ignored without an error. The core runs on PCLK and PRESETN. `irq` is level-high: `|(IRQ_STATUS & IRQ_ENABLE)`.

Pass-through pins: `m_awid`, `m_awaddr`, `m_awlen`, `m_awsize`, `m_awburst`, `m_awprot`, `m_awvalid`, `m_awready`, `m_wdata`, `m_wstrb`, `m_wlast`, `m_wvalid`, `m_wready`, `m_bid`, `m_bresp`, `m_bvalid`, `m_bready`, `m_arid`, `m_araddr`, `m_arlen`, `m_arsize`, `m_arburst`, `m_arprot`, `m_arvalid`, `m_arready`, `m_rid`, `m_rdata`, `m_rresp`, `m_rlast`, `m_rvalid`, `m_rready`.

### Register map

| Offset | Name | Access | Reset | Description |
|---|---|---|---|---|
| 0x000 | ID | RO | 0x7C090100 | IP identification: code, major and minor version |
| 0x004 | IRQ_STATUS | W1C | 0x00000000 | Sticky interrupt bits, write 1 to clear |
| 0x008 | IRQ_ENABLE | RW | 0x00000000 | Interrupt enables; irq = \|(IRQ_STATUS & IRQ_ENABLE) |
| 0x00C | FLAGS | RO | 0x00000000 | Stream holding-register state |
| 0x010 | SCRATCH | RW | 0x00000000 | Scratch register, no effect on the core |
| 0x014 | BS_ADDR | RW | 0x00000000 | Bitstream |
| 0x018 | REF0_ADDR | RW | 0x00000000 | Reference 0 luma |
| 0x01C | REF1_ADDR | RW | 0x00000000 | Reference 1 luma |
| 0x020 | RECON_ADDR | RW | 0x00000000 | Output luma |
| 0x024 | CHROMA_ADDR | RW | 0x00000000 | Output chroma |
| 0x028 | PIC | RW | 0x00000000 | Picture size |
| 0x02C | CODING | RW | 0x000005A6 | Coding shape |
| 0x030 | RATE | RW | 0x00000000 | Rate shaping |
| 0x034 | SEED | RW | 0x00000000 | Seed |
| 0x038 | CMD | WO (pulse) | 0x00000000 | Commands (write 1) |
| 0x03C | STATUS | RO | core | State |
| 0x040 | CTUS | RO | core | Progress |
| 0x044 | RD_WORDS | RO | core | Words read |
| 0x048 | WR_WORDS | RO | core | Words written |
| 0x04C | RD_SUM | RO | core | Read checksum |
| 0x050 | CYCLES | RO | core | Picture length in clocks |

Unlisted bits read 0 and ignore writes. Reset "core": the register reads the core's outputs directly, so after reset it shows the core's own reset state. WO (pulse) registers read 0. Offsets from 0x054 up to 0xFFC are unmapped (PSLVERR).

### Fields

| Register | Bits | Field | Access | Reset | Description |
|---|---|---|---|---|---|
| ID | 31:16 | CODE | RO | 0x7C09 | IP code |
| ID | 15:8 | MAJOR | RO | 0x01 | major version |
| ID | 7:0 | MINOR | RO | 0x00 | minor version |
| IRQ_STATUS | 2:0 | one bit per interrupt | W1C | 0x0 | see Interrupts |
| IRQ_ENABLE | 2:0 | one bit per interrupt | RW | 0x0 | 1 enables the IRQ_STATUS bit onto `irq` |
| SCRATCH | 31:0 | SCRATCH | RW | 0x00000000 | free for software |
| BS_ADDR | 31:0 | `bs_addr` | RW | 0x0 | first word |
| REF0_ADDR | 31:0 | `ref0_addr` | RW | 0x0 | pixel (0, 0) |
| REF1_ADDR | 31:0 | `ref1_addr` | RW | 0x0 | pixel (0, 0) |
| RECON_ADDR | 31:0 | `recon_addr` | RW | 0x0 | pixel (0, 0) |
| CHROMA_ADDR | 31:0 | `chroma_addr` | RW | 0x0 | interleaved CbCr (0, 0) |
| PIC | 15:0 | `stride` | RW | 0x0 | line pitch in bytes |
| PIC | 23:16 | `pic_w_ctu` | RW | 0x0 | CTUs across |
| PIC | 31:24 | `pic_h_ctu` | RW | 0x0 | CTUs down |
| CODING | 2:0 | `ctu_log2` | RW | 0x6 | CTU size 2^n, 4..6 |
| CODING | 5:3 | `pu_log2` | RW | 0x4 | PU size 2^n, 3..CTU |
| CODING | 7:6 | `n_refs` | RW | 0x2 | references per PU, 0..2 |
| CODING | 10:8 | `mv_log2` | RW | 0x5 | motion vector range |
| CODING | 18:11 | `bs_words` | RW | 0x0 | bitstream words per CTU |
| RATE | 15:0 | `ctu_gap` | RW | 0x0 | minimum clocks per CTU |
| RATE | 31:16 | `ctu_limit` | RW | 0x0 | stop after this many CTUs (0: all) |
| SEED | 31:0 | `seed` | RW | 0x0 | motion vectors and write data |
| CMD | 0 | `start` | WO (pulse) | 0x0 | run one picture; ignored while busy |
| STATUS | 0 | `busy` | RO | core | a picture is running |
| STATUS | 1 | `err` | RO | core | AXI error response |
| STATUS | 2 | `cfg_err` | RO | core | invalid geometry |
| CTUS | 15:0 | `ctus` | RO | core | CTUs done |
| CTUS | 31:16 | `late_cnt` | RO | core | CTUs over CTU_GAP |
| RD_WORDS | 31:0 | `rd_words` | RO | core | by the current / last picture |
| WR_WORDS | 31:0 | `wr_words` | RO | core | by the current / last picture |
| RD_SUM | 31:0 | `rd_sum` | RO | core | 32-bit sum of the words read |
| CYCLES | 31:0 | `cycles` | RO | core | clocks from start to DONE |

### Interrupts (IRQ_STATUS, IRQ_ENABLE)

A bit is set while its source is active, stays set until written with 1, and a set in the same clock as the clear wins.

| Bit | Name | Set when |
|---|---|---|
| 0 | DONE | a job ended |
| 1 | ERR | a job ended that saw an AXI error response |
| 2 | LATE | a CTU took longer than CTU_GAP |

## Programming sequence

1. Release PRESETN. Read ID (0x000) and check it is 0x7C090100.
2. Write 0x7 to IRQ_STATUS (0x004) to clear any stale bits.
3. Configure the core: write BS_ADDR (0x014), REF0_ADDR (0x018), REF1_ADDR (0x01C), RECON_ADDR (0x020), CHROMA_ADDR (0x024), PIC (0x028), CODING (0x02C), RATE (0x030), SEED (0x034). Reset values are in the register map; PSTRB selects the bytes written.
4. Write IRQ_ENABLE (0x008) with the interrupts to use (bit order as in the Interrupts table; 0x7 enables all).
5. To issue a command, write 1 to `start` (CMD bit 0) at 0x038; the core sees a one-clock pulse, and the register reads 0.
6. Read STATUS (0x03C) for the core's live `busy`, `err`, `cfg_err`; it needs no clearing.
7. Read CTUS (0x040) for the core's live `ctus`, `late_cnt`; it needs no clearing.
8. Read RD_WORDS (0x044) for the core's live `rd_words`; it needs no clearing.
9. Read WR_WORDS (0x048) for the core's live `wr_words`; it needs no clearing.
10. Read RD_SUM (0x04C) for the core's live `rd_sum`; it needs no clearing.
11. Read CYCLES (0x050) for the core's live `cycles`; it needs no clearing.
12. On `irq`: read IRQ_STATUS, handle every bit that is set and enabled, then write those bits back to IRQ_STATUS to clear them. A source that is still active sets its bit again.

IP-specific use:

1. Write the plane addresses, PIC, CODING, RATE and SEED.
2. Write IRQ_ENABLE with DONE (and LATE), then CMD.start = 1.
3. On DONE read CTUS, RD_WORDS, WR_WORDS, CYCLES.

## Running and verifying

All commands run from the repository root. Icarus Verilog 12 and Yosys 0.33 are enough for steps 1 to 3; step 4 also needs Verilator 5.052 and pyslang (see [README, Setup](../../README.md#setup)).

| Step | Command | Pass when | Output |
|---|---|---|---|
| 1. Core test | `make -f Makefile.Video_Codec_8K sim` | a `TEST PASSED` line, no `ERROR` | console |
| 2. Core synthesis | `make -f Makefile.Video_Codec_8K syn` | Yosys ends without `ERROR`; `stat` prints the cell count | `work/Video_Codec_8K_top.json` |
| 3. APB wrapper test + synthesis | `make -f Makefile.Video_Codec_8K apb` | `TEST PASSED: Video_Codec_8K_apb`, then Yosys without `ERROR` | console, `work/Video_Codec_8K_apb.json` |
| 4. Coverage (core, wrapper) | `bash scripts/cov/run_cov.sh Video_Codec_8K`<br>`bash scripts/cov/run_cov.sh Video_Codec_8K_apb` | `RESULT: CLOSED` (all five metrics 100%) | `work/cov/Video_Codec_8K/score.json`, `work/cov/Video_Codec_8K_apb/score.json` |

Expected end of a step 4 run:

```
===== Video_Codec_8K =====
TEST: PASSED   SVA_FAILURES: 0
LINE ... TOGGLE ... FSM ... SVA ... FUNCTIONAL  (each n/n, 100.0%)
RESULT: CLOSED
```

**Core test** (`tb/Video_Codec_8K_tb.sv`): drives `Video_Codec_8K_top` through its own ports against a protocol peer or model and checks every result itself; any mismatch prints `ERROR`, and `TEST PASSED` is printed only when there were none.

**APB wrapper test** (`tb/Video_Codec_8K_apb_tb.sv`), in this order:

1. Reset values of every register, ID included.
2. Writes to read-only registers are ignored.
3. Each RW register: all ones, all zeros, then 16 random writes with every PSTRB byte-lane pattern, read back each time.
4. Unmapped and misaligned addresses, reads and writes: PSLVERR, read data 0, no side effect on other registers.
5. Back-to-back transfers with no idle cycle.
6. IP traffic through the registers only (`tb/apb/Video_Codec_8K_apb_func.svh`): the programming sequence above, every interrupt bit set, enabled and cleared (100% wrapper toggle coverage confirms each bit moved).
7. PRESETN asserted mid-run: `irq` and PRDATA go to 0, registers return to reset values.

**Checkers** (`tb/cov/Video_Codec_8K_sva.sv`, `tb/cov/Video_Codec_8K_apb_sva.sv`): SVA protocol and APB assertions plus covergroups, bound in by the coverage flow. An assertion failure prints `SVA_FAIL` and fails the run even when the test itself passed.

Whole portfolio: `bash scripts/ci_regression.sh` runs steps 1 to 3 for every IP (what CI runs), and `bash scripts/cov/run_all.sh 4` runs step 4 for every IP.

## Verification

Five-metric coverage with Verilator 5.052 (`scripts/cov/run_cov.sh`); see [COVERAGE_CLOSURE.md](../COVERAGE_CLOSURE.md) for the flow. Line and toggle count only the named RTL file.

| Scope | Test | Line | Toggle | FSM | SVA | Functional |
|---|---|---|---|---|---|---|
| core `rtl/Video_Codec_8K_top.sv` | not run | | | | | |
| wrapper `rtl/Video_Codec_8K_apb.sv` | not run | | | | | |
