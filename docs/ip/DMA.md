# System DMA: 4 channels of copy and fill jobs served round robin over AXI4

Protocol IP `DMA`, version 1.0. Apache-2.0.

| Item | Value |
|---|---|
| Core | `DMA_top` (`rtl/DMA_top.sv`) |
| Register interface | APB4 slave `DMA_apb`, 32-bit data, 12-bit byte address, zero wait states |
| Clock, reset | PCLK (rising edge), PRESETN (active low, asynchronous) |
| ID register | 0x5C090100 (code 0x5C09, version 1.0) |
| Registers | 26 words, 0x000 to 0x064 |
| Interrupts | 5 sources into one level-high `irq` |
| Protocol pins | 31 pass-through |

## Overview

DMA: 4-channel system DMA of the phone SoC (AXI4 manager, APB4 registers) Each channel has its own SRC, DST, LEN (32-bit words) and MODE; writing its START bit queues it. Queued channels are served one job at a time in round-robin order by the shared AXI4 data mover (rtl/soc_ss_axi_engine.sv).

- MODE 0 COPY: read LEN words at SRC and write them to DST.
- MODE 1 FILL: write LEN copies of the channel's FILL word to DST (no reads).
- A channel's DONE interrupt is set when its job ends; ERR as well when the
job saw an AXI error response (SLVERR / DECERR).
- CHECKSUM is the 32-bit sum of the words written by the last job;
CYCLES its length in clocks; STATUS shows the queued and active channels.
- AXI ID = AXI_ID; bursts of up to 16 beats, never across 4 KB.

Features:

- Per channel n: SRCn, DSTn, LENn (32-bit words), MODE.moden (0 COPY, 1 FILL with FILLn), CMD.startn queues the channel.
- Queued channels are served one job at a time in round-robin order (the first queued channel after the last one served).
- COPY: DST word i = SRC word i. FILL: DST word i = FILLn (no reads).
- CHECKSUM: 32-bit sum of the words written by the last job; STATUS.active_ch the channel being (last) served.

m_* is the AXI4 manager port (32-bit address and data, 4-bit ID, no user / QoS); it passes through unchanged. Bursts are INCR, AxSIZE = 2 (4 bytes), 1 to 16 beats, WSTRB = 4'hF, never across a 4 KB boundary; one read and one write burst are outstanding at a time. A read burst is issued only when its data has room, a write burst only when all its data is ready.

## Files

| File | Content |
|---|---|
| `rtl/DMA_top.sv` | protocol core |
| `rtl/DMA_apb.sv` | APB4 register wrapper (generated) |
| `tb/DMA_tb.sv` | core testbench |
| `tb/DMA_apb_tb.sv`, `tb/apb/DMA_apb_func.svh` | wrapper testbench (generated part + IP-specific part) |
| `tb/cov/DMA_sva.sv`, `tb/cov/DMA_apb_sva.sv` | coverage checkers (core, wrapper) |
| `scripts/apb/specs/DMA.json` | register spec the wrapper, TB, checker and this page are generated from |

How to run the tests and the coverage flow: see [Running and verifying](#running-and-verifying).

## Parameters

`DMA_apb` has the core's parameters and passes them to `DMA_top` unchanged.

| Parameter | Type | Default |
|---|---|---|
| `AXI_ID` | logic [3:0] | `4'd7` |

## Wrapper pins

Pins of `DMA_apb`. Widths of the pass-through pins are at the default parameters.

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
| `src0` | input | 32 | SRC0[31:0] |
| `src1` | input | 32 | SRC1[31:0] |
| `src2` | input | 32 | SRC2[31:0] |
| `src3` | input | 32 | SRC3[31:0] |
| `dst0` | input | 32 | DST0[31:0] |
| `dst1` | input | 32 | DST1[31:0] |
| `dst2` | input | 32 | DST2[31:0] |
| `dst3` | input | 32 | DST3[31:0] |
| `len0` | input | 16 | LEN0[15:0] |
| `len1` | input | 16 | LEN1[15:0] |
| `len2` | input | 16 | LEN2[15:0] |
| `len3` | input | 16 | LEN3[15:0] |
| `mode0` | input | 1 | MODE[0:0] |
| `mode1` | input | 1 | MODE[1:1] |
| `mode2` | input | 1 | MODE[2:2] |
| `mode3` | input | 1 | MODE[3:3] |
| `fill0` | input | 32 | FILL0[31:0] |
| `fill1` | input | 32 | FILL1[31:0] |
| `fill2` | input | 32 | FILL2[31:0] |
| `fill3` | input | 32 | FILL3[31:0] |
| `start0` | input | 1 | CMD[0:0] |
| `start1` | input | 1 | CMD[1:1] |
| `start2` | input | 1 | CMD[2:2] |
| `start3` | input | 1 | CMD[3:3] |
| `pending` | output | 4 | STATUS[3:0] |
| `busy` | output | 1 | STATUS[4:4] |
| `active_ch` | output | 2 | STATUS[6:5] |
| `err` | output | 1 | STATUS[7:7] |
| `checksum` | output | 32 | CHECKSUM[31:0] |
| `cycles` | output | 32 | CYCLES[31:0] |
| `done0` | output | 1 | IRQ_STATUS.DONE0 |
| `done1` | output | 1 | IRQ_STATUS.DONE1 |
| `done2` | output | 1 | IRQ_STATUS.DONE2 |
| `done3` | output | 1 | IRQ_STATUS.DONE3 |
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

`DMA_apb` is an APB4 slave (AMBA APB protocol v2.0): zero wait states, 32-bit data, 12-bit byte address, PSTRB byte lanes on every writable register, PSLVERR on an unmapped or misaligned address (reads then return 0, writes are dropped). Writes to read-only registers are ignored without an error. The core runs on PCLK and PRESETN. `irq` is level-high: `|(IRQ_STATUS & IRQ_ENABLE)`.

Pass-through pins: `m_awid`, `m_awaddr`, `m_awlen`, `m_awsize`, `m_awburst`, `m_awprot`, `m_awvalid`, `m_awready`, `m_wdata`, `m_wstrb`, `m_wlast`, `m_wvalid`, `m_wready`, `m_bid`, `m_bresp`, `m_bvalid`, `m_bready`, `m_arid`, `m_araddr`, `m_arlen`, `m_arsize`, `m_arburst`, `m_arprot`, `m_arvalid`, `m_arready`, `m_rid`, `m_rdata`, `m_rresp`, `m_rlast`, `m_rvalid`, `m_rready`.

### Register map

| Offset | Name | Access | Reset | Description |
|---|---|---|---|---|
| 0x000 | ID | RO | 0x5C090100 | IP identification: code, major and minor version |
| 0x004 | IRQ_STATUS | W1C | 0x00000000 | Sticky interrupt bits, write 1 to clear |
| 0x008 | IRQ_ENABLE | RW | 0x00000000 | Interrupt enables; irq = \|(IRQ_STATUS & IRQ_ENABLE) |
| 0x00C | FLAGS | RO | 0x00000000 | Stream holding-register state |
| 0x010 | SCRATCH | RW | 0x00000000 | Scratch register, no effect on the core |
| 0x014 | SRC0 | RW | 0x00000000 | Channel 0 source address |
| 0x018 | DST0 | RW | 0x00000000 | Channel 0 destination address |
| 0x01C | LEN0 | RW | 0x00000000 | Channel 0 length |
| 0x020 | FILL0 | RW | 0x00000000 | Channel 0 fill word |
| 0x024 | SRC1 | RW | 0x00000000 | Channel 1 source address |
| 0x028 | DST1 | RW | 0x00000000 | Channel 1 destination address |
| 0x02C | LEN1 | RW | 0x00000000 | Channel 1 length |
| 0x030 | FILL1 | RW | 0x00000000 | Channel 1 fill word |
| 0x034 | SRC2 | RW | 0x00000000 | Channel 2 source address |
| 0x038 | DST2 | RW | 0x00000000 | Channel 2 destination address |
| 0x03C | LEN2 | RW | 0x00000000 | Channel 2 length |
| 0x040 | FILL2 | RW | 0x00000000 | Channel 2 fill word |
| 0x044 | SRC3 | RW | 0x00000000 | Channel 3 source address |
| 0x048 | DST3 | RW | 0x00000000 | Channel 3 destination address |
| 0x04C | LEN3 | RW | 0x00000000 | Channel 3 length |
| 0x050 | FILL3 | RW | 0x00000000 | Channel 3 fill word |
| 0x054 | MODE | RW | 0x00000000 | Channel modes |
| 0x058 | CMD | WO (pulse) | 0x00000000 | Commands (write 1) |
| 0x05C | STATUS | RO | core | Scheduler state |
| 0x060 | CHECKSUM | RO | core | Data checksum |
| 0x064 | CYCLES | RO | core | Job length in clocks |

Unlisted bits read 0 and ignore writes. Reset "core": the register reads the core's outputs directly, so after reset it shows the core's own reset state. WO (pulse) registers read 0. Offsets from 0x068 up to 0xFFC are unmapped (PSLVERR).

### Fields

| Register | Bits | Field | Access | Reset | Description |
|---|---|---|---|---|---|
| ID | 31:16 | CODE | RO | 0x5C09 | IP code |
| ID | 15:8 | MAJOR | RO | 0x01 | major version |
| ID | 7:0 | MINOR | RO | 0x00 | minor version |
| IRQ_STATUS | 4:0 | one bit per interrupt | W1C | 0x0 | see Interrupts |
| IRQ_ENABLE | 4:0 | one bit per interrupt | RW | 0x0 | 1 enables the IRQ_STATUS bit onto `irq` |
| SCRATCH | 31:0 | SCRATCH | RW | 0x00000000 | free for software |
| SRC0 | 31:0 | `src0` | RW | 0x0 | byte address, word aligned |
| DST0 | 31:0 | `dst0` | RW | 0x0 | byte address, word aligned |
| LEN0 | 15:0 | `len0` | RW | 0x0 | 32-bit words |
| FILL0 | 31:0 | `fill0` | RW | 0x0 | FILL mode data |
| SRC1 | 31:0 | `src1` | RW | 0x0 | byte address, word aligned |
| DST1 | 31:0 | `dst1` | RW | 0x0 | byte address, word aligned |
| LEN1 | 15:0 | `len1` | RW | 0x0 | 32-bit words |
| FILL1 | 31:0 | `fill1` | RW | 0x0 | FILL mode data |
| SRC2 | 31:0 | `src2` | RW | 0x0 | byte address, word aligned |
| DST2 | 31:0 | `dst2` | RW | 0x0 | byte address, word aligned |
| LEN2 | 15:0 | `len2` | RW | 0x0 | 32-bit words |
| FILL2 | 31:0 | `fill2` | RW | 0x0 | FILL mode data |
| SRC3 | 31:0 | `src3` | RW | 0x0 | byte address, word aligned |
| DST3 | 31:0 | `dst3` | RW | 0x0 | byte address, word aligned |
| LEN3 | 15:0 | `len3` | RW | 0x0 | 32-bit words |
| FILL3 | 31:0 | `fill3` | RW | 0x0 | FILL mode data |
| MODE | 0 | `mode0` | RW | 0x0 | channel 0: 0 COPY, 1 FILL |
| MODE | 1 | `mode1` | RW | 0x0 | channel 1: 0 COPY, 1 FILL |
| MODE | 2 | `mode2` | RW | 0x0 | channel 2: 0 COPY, 1 FILL |
| MODE | 3 | `mode3` | RW | 0x0 | channel 3: 0 COPY, 1 FILL |
| CMD | 0 | `start0` | WO (pulse) | 0x0 | queue channel 0 |
| CMD | 1 | `start1` | WO (pulse) | 0x0 | queue channel 1 |
| CMD | 2 | `start2` | WO (pulse) | 0x0 | queue channel 2 |
| CMD | 3 | `start3` | WO (pulse) | 0x0 | queue channel 3 |
| STATUS | 3:0 | `pending` | RO | core | queued channels |
| STATUS | 4 | `busy` | RO | core | a job is running |
| STATUS | 6:5 | `active_ch` | RO | core | channel of the current / last job |
| STATUS | 7 | `err` | RO | core | the current / last job saw an AXI error response |
| CHECKSUM | 31:0 | `checksum` | RO | core | sum of the words written by the current / last job |
| CYCLES | 31:0 | `cycles` | RO | core | clocks from start to DONE of the current / last job |

### Interrupts (IRQ_STATUS, IRQ_ENABLE)

A bit is set while its source is active, stays set until written with 1, and a set in the same clock as the clear wins.

| Bit | Name | Set when |
|---|---|---|
| 0 | DONE0 | a channel 0 job ended |
| 1 | DONE1 | a channel 1 job ended |
| 2 | DONE2 | a channel 2 job ended |
| 3 | DONE3 | a channel 3 job ended |
| 4 | ERR | a job ended that saw an AXI error response |

## Programming sequence

1. Release PRESETN. Read ID (0x000) and check it is 0x5C090100.
2. Write 0x1F to IRQ_STATUS (0x004) to clear any stale bits.
3. Configure the core: write SRC0 (0x014), DST0 (0x018), LEN0 (0x01C), FILL0 (0x020), SRC1 (0x024), DST1 (0x028), LEN1 (0x02C), FILL1 (0x030), SRC2 (0x034), DST2 (0x038), LEN2 (0x03C), FILL2 (0x040), SRC3 (0x044), DST3 (0x048), LEN3 (0x04C), FILL3 (0x050), MODE (0x054). Reset values are in the register map; PSTRB selects the bytes written.
4. Write IRQ_ENABLE (0x008) with the interrupts to use (bit order as in the Interrupts table; 0x1F enables all).
5. To issue a command, write 1 to `start0` (CMD bit 0), `start1` (CMD bit 1), `start2` (CMD bit 2), `start3` (CMD bit 3) at 0x058; the core sees a one-clock pulse, and the register reads 0.
6. Read STATUS (0x05C) for the core's live `pending`, `busy`, `active_ch`, `err`; it needs no clearing.
7. Read CHECKSUM (0x060) for the core's live `checksum`; it needs no clearing.
8. Read CYCLES (0x064) for the core's live `cycles`; it needs no clearing.
9. On `irq`: read IRQ_STATUS, handle every bit that is set and enabled, then write those bits back to IRQ_STATUS to clear them. A source that is still active sets its bit again.

IP-specific use:

1. Write SRCn, DSTn, LENn (and FILLn), MODE and IRQ_ENABLE.
2. Write CMD with startn = 1 for each channel to run; channels may be queued while one runs.
3. On irq read IRQ_STATUS to see which DONEn are set, then write them back to clear.

## Running and verifying

All commands run from the repository root. Icarus Verilog 12 and Yosys 0.33 are enough for steps 1 to 3; step 4 also needs Verilator 5.052 and pyslang (see [README, Setup](../../README.md#setup)).

| Step | Command | Pass when | Output |
|---|---|---|---|
| 1. Core test | `make -f Makefile.DMA sim` | a `TEST PASSED` line, no `ERROR` | console |
| 2. Core synthesis | `make -f Makefile.DMA syn` | Yosys ends without `ERROR`; `stat` prints the cell count | `work/DMA_top.json` |
| 3. APB wrapper test + synthesis | `make -f Makefile.DMA apb` | `TEST PASSED: DMA_apb`, then Yosys without `ERROR` | console, `work/DMA_apb.json` |
| 4. Coverage (core, wrapper) | `bash scripts/cov/run_cov.sh DMA`<br>`bash scripts/cov/run_cov.sh DMA_apb` | `RESULT: CLOSED` (all five metrics 100%) | `work/cov/DMA/score.json`, `work/cov/DMA_apb/score.json` |

Expected end of a step 4 run:

```
===== DMA =====
TEST: PASSED   SVA_FAILURES: 0
LINE ... TOGGLE ... FSM ... SVA ... FUNCTIONAL  (each n/n, 100.0%)
RESULT: CLOSED
```

**Core test** (`tb/DMA_tb.sv`): drives `DMA_top` through its own ports against a protocol peer or model and checks every result itself; any mismatch prints `ERROR`, and `TEST PASSED` is printed only when there were none.

**APB wrapper test** (`tb/DMA_apb_tb.sv`), in this order:

1. Reset values of every register, ID included.
2. Writes to read-only registers are ignored.
3. Each RW register: all ones, all zeros, then 16 random writes with every PSTRB byte-lane pattern, read back each time.
4. Unmapped and misaligned addresses, reads and writes: PSLVERR, read data 0, no side effect on other registers.
5. Back-to-back transfers with no idle cycle.
6. IP traffic through the registers only (`tb/apb/DMA_apb_func.svh`): the programming sequence above, every interrupt bit set, enabled and cleared (100% wrapper toggle coverage confirms each bit moved).
7. PRESETN asserted mid-run: `irq` and PRDATA go to 0, registers return to reset values.

**Checkers** (`tb/cov/DMA_sva.sv`, `tb/cov/DMA_apb_sva.sv`): SVA protocol and APB assertions plus covergroups, bound in by the coverage flow. An assertion failure prints `SVA_FAIL` and fails the run even when the test itself passed.

Whole portfolio: `bash scripts/ci_regression.sh` runs steps 1 to 3 for every IP (what CI runs), and `bash scripts/cov/run_all.sh 4` runs step 4 for every IP.

## Verification

Five-metric coverage with Verilator 5.052 (`scripts/cov/run_cov.sh`); see [COVERAGE_CLOSURE.md](../COVERAGE_CLOSURE.md) for the flow. Line and toggle count only the named RTL file.

| Scope | Test | Line | Toggle | FSM | SVA | Functional |
|---|---|---|---|---|---|---|
| core `rtl/DMA_top.sv` | not run | | | | | |
| wrapper `rtl/DMA_apb.sv` | not run | | | | | |
