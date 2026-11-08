# NPU: int8 4-tap 1-D convolution engine with bias, ReLU and requantization over AXI4

Protocol IP `NPU`, version 1.0. Apache-2.0.

| Item | Value |
|---|---|
| Core | `NPU_top` (`rtl/NPU_top.sv`) |
| Register interface | APB4 slave `NPU_apb`, 32-bit data, 12-bit byte address, zero wait states |
| Clock, reset | PCLK (rising edge), PRESETN (active low, asynchronous) |
| ID register | 0x5C020100 (code 0x5C02, version 1.0) |
| Registers | 14 words, 0x000 to 0x034 |
| Interrupts | 2 sources into one level-high `irq` |
| Protocol pins | 31 pass-through |

## Overview

NPU: neural processing unit of the phone SoC, an int8 1-D convolution engine (AXI4 manager, APB4 registers) Streams LEN words of int8 activations from SRC (four per word, byte 0 first) through a 4-tap convolution and writes LEN words of int8 results to DST, one result per input sample: acc[n] = BIAS + W0*x[n] + W1*x[n-1] + W2*x[n-2] + W3*x[n-3] y[n]   = sat8((RELU ? max(acc, 0) : acc) >>> SHIFT)

- Samples before the first one of a job are 0 (zero padding).
- Weights are signed 8-bit, BIAS signed 16-bit, SHIFT 0..15 (arithmetic).
- SATURATIONS counts results clipped to -128 / 127 in the last job.
- DONE interrupt when a job ends, ERR as well on an AXI error response.
- CYCLES is the length of the last job in clocks; AXI ID = AXI_ID.

Features:

- Input and output: four signed int8 samples per word, byte 0 first; sample n of the job is byte n mod 4 of word n / 4.
- acc[n] = BIAS + W0*x[n] + W1*x[n-1] + W2*x[n-2] + W3*x[n-3], with x[-1] = x[-2] = x[-3] = 0 (each job starts from zero history).
- y[n] = sat8((RELU ? max(acc[n], 0) : acc[n]) >>> SHIFT): arithmetic shift, then clip to -128..127.
- SATURATIONS counts the results that were clipped in the last job (saturating).

m_* is the AXI4 manager port (32-bit address and data, 4-bit ID, no user / QoS); it passes through unchanged. Bursts are INCR, AxSIZE = 2 (4 bytes), 1 to 16 beats, WSTRB = 4'hF, never across a 4 KB boundary; one read and one write burst are outstanding at a time. A read burst is issued only when its data has room, a write burst only when all its data is ready.

## Files

| File | Content |
|---|---|
| `rtl/NPU_top.sv` | protocol core |
| `rtl/NPU_apb.sv` | APB4 register wrapper (generated) |
| `tb/NPU_tb.sv` | core testbench |
| `tb/NPU_apb_tb.sv`, `tb/apb/NPU_apb_func.svh` | wrapper testbench (generated part + IP-specific part) |
| `tb/cov/NPU_sva.sv`, `tb/cov/NPU_apb_sva.sv` | coverage checkers (core, wrapper) |
| `scripts/apb/specs/NPU.json` | register spec the wrapper, TB, checker and this page are generated from |

How to run the tests and the coverage flow: see [Running and verifying](#running-and-verifying).

## Parameters

`NPU_apb` has the core's parameters and passes them to `NPU_top` unchanged.

| Parameter | Type | Default |
|---|---|---|
| `AXI_ID` | logic [3:0] | `4'd2` |

## Wrapper pins

Pins of `NPU_apb`. Widths of the pass-through pins are at the default parameters.

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
| `src_addr` | input | 32 | SRC_ADDR[31:0] |
| `dst_addr` | input | 32 | DST_ADDR[31:0] |
| `xfer_len` | input | 16 | LEN[15:0] |
| `w0` | input | 8 | WEIGHTS[7:0] |
| `w1` | input | 8 | WEIGHTS[15:8] |
| `w2` | input | 8 | WEIGHTS[23:16] |
| `w3` | input | 8 | WEIGHTS[31:24] |
| `bias` | input | 16 | CTRL[15:0] |
| `shift` | input | 4 | CTRL[19:16] |
| `relu` | input | 1 | CTRL[20:20] |
| `start` | input | 1 | CMD |
| `busy` | output | 1 | STATUS[0:0] |
| `err` | output | 1 | STATUS[1:1] |
| `saturations` | output | 16 | SATURATIONS[15:0] |
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

`NPU_apb` is an APB4 slave (AMBA APB protocol v2.0): zero wait states, 32-bit data, 12-bit byte address, PSTRB byte lanes on every writable register, PSLVERR on an unmapped or misaligned address (reads then return 0, writes are dropped). Writes to read-only registers are ignored without an error. The core runs on PCLK and PRESETN. `irq` is level-high: `|(IRQ_STATUS & IRQ_ENABLE)`.

Pass-through pins: `m_awid`, `m_awaddr`, `m_awlen`, `m_awsize`, `m_awburst`, `m_awprot`, `m_awvalid`, `m_awready`, `m_wdata`, `m_wstrb`, `m_wlast`, `m_wvalid`, `m_wready`, `m_bid`, `m_bresp`, `m_bvalid`, `m_bready`, `m_arid`, `m_araddr`, `m_arlen`, `m_arsize`, `m_arburst`, `m_arprot`, `m_arvalid`, `m_arready`, `m_rid`, `m_rdata`, `m_rresp`, `m_rlast`, `m_rvalid`, `m_rready`.

### Register map

| Offset | Name | Access | Reset | Description |
|---|---|---|---|---|
| 0x000 | ID | RO | 0x5C020100 | IP identification: code, major and minor version |
| 0x004 | IRQ_STATUS | W1C | 0x00000000 | Sticky interrupt bits, write 1 to clear |
| 0x008 | IRQ_ENABLE | RW | 0x00000000 | Interrupt enables; irq = \|(IRQ_STATUS & IRQ_ENABLE) |
| 0x00C | FLAGS | RO | 0x00000000 | Stream holding-register state |
| 0x010 | SCRATCH | RW | 0x00000000 | Scratch register, no effect on the core |
| 0x014 | SRC_ADDR | RW | 0x00000000 | Source address (byte address, word aligned) |
| 0x018 | DST_ADDR | RW | 0x00000000 | Destination address (byte address, word aligned) |
| 0x01C | LEN | RW | 0x00000000 | Job length |
| 0x020 | WEIGHTS | RW | 0x00000000 | Filter taps (signed 8-bit) |
| 0x024 | CTRL | RW | 0x00000000 | Bias and requantization |
| 0x028 | CMD | WO (pulse) | 0x00000000 | Commands (write 1) |
| 0x02C | STATUS | RO | core | Job state |
| 0x030 | SATURATIONS | RO | core | Clipped results |
| 0x034 | CYCLES | RO | core | Job length in clocks |

Unlisted bits read 0 and ignore writes. Reset "core": the register reads the core's outputs directly, so after reset it shows the core's own reset state. WO (pulse) registers read 0. Offsets from 0x038 up to 0xFFC are unmapped (PSLVERR).

### Fields

| Register | Bits | Field | Access | Reset | Description |
|---|---|---|---|---|---|
| ID | 31:16 | CODE | RO | 0x5C02 | IP code |
| ID | 15:8 | MAJOR | RO | 0x01 | major version |
| ID | 7:0 | MINOR | RO | 0x00 | minor version |
| IRQ_STATUS | 1:0 | one bit per interrupt | W1C | 0x0 | see Interrupts |
| IRQ_ENABLE | 1:0 | one bit per interrupt | RW | 0x0 | 1 enables the IRQ_STATUS bit onto `irq` |
| SCRATCH | 31:0 | SCRATCH | RW | 0x00000000 | free for software |
| SRC_ADDR | 31:0 | `src_addr` | RW | 0x0 | first word read by the job |
| DST_ADDR | 31:0 | `dst_addr` | RW | 0x0 | first word written by the job |
| LEN | 15:0 | `xfer_len` | RW | 0x0 | 32-bit words (0: the job ends at once) |
| WEIGHTS | 7:0 | `w0` | RW | 0x0 | tap of x[n] |
| WEIGHTS | 15:8 | `w1` | RW | 0x0 | tap of x[n-1] |
| WEIGHTS | 23:16 | `w2` | RW | 0x0 | tap of x[n-2] |
| WEIGHTS | 31:24 | `w3` | RW | 0x0 | tap of x[n-3] |
| CTRL | 15:0 | `bias` | RW | 0x0 | signed 16-bit bias |
| CTRL | 19:16 | `shift` | RW | 0x0 | right shift 0..15 |
| CTRL | 20 | `relu` | RW | 0x0 | 1: ReLU before the shift |
| CMD | 0 | `start` | WO (pulse) | 0x0 | start a job with the current registers; ignored while busy |
| STATUS | 0 | `busy` | RO | core | a job is running |
| STATUS | 1 | `err` | RO | core | the current / last job saw an AXI error response (cleared by start) |
| SATURATIONS | 15:0 | `saturations` | RO | core | results clipped in the current / last job |
| CYCLES | 31:0 | `cycles` | RO | core | clocks from start to DONE of the current / last job |

### Interrupts (IRQ_STATUS, IRQ_ENABLE)

A bit is set while its source is active, stays set until written with 1, and a set in the same clock as the clear wins.

| Bit | Name | Set when |
|---|---|---|
| 0 | DONE | a job ended |
| 1 | ERR | a job ended that saw an AXI error response |

## Programming sequence

1. Release PRESETN. Read ID (0x000) and check it is 0x5C020100.
2. Write 0x3 to IRQ_STATUS (0x004) to clear any stale bits.
3. Configure the core: write SRC_ADDR (0x014), DST_ADDR (0x018), LEN (0x01C), WEIGHTS (0x020), CTRL (0x024). Reset values are in the register map; PSTRB selects the bytes written.
4. Write IRQ_ENABLE (0x008) with the interrupts to use (bit order as in the Interrupts table; 0x3 enables all).
5. To issue a command, write 1 to `start` (CMD bit 0) at 0x028; the core sees a one-clock pulse, and the register reads 0.
6. Read STATUS (0x02C) for the core's live `busy`, `err`; it needs no clearing.
7. Read SATURATIONS (0x030) for the core's live `saturations`; it needs no clearing.
8. Read CYCLES (0x034) for the core's live `cycles`; it needs no clearing.
9. On `irq`: read IRQ_STATUS, handle every bit that is set and enabled, then write those bits back to IRQ_STATUS to clear them. A source that is still active sets its bit again.

IP-specific use:

1. Write SRC_ADDR, DST_ADDR (word aligned) and LEN (32-bit words).
2. Write CTRL with the job's options and IRQ_ENABLE with DONE (and ERR).
3. Write CMD.start = 1 (ignored while STATUS.busy is 1).
4. Wait for irq (or poll STATUS.busy = 0), read the result registers, write 1s to IRQ_STATUS to clear it.

## Running and verifying

All commands run from the repository root. Icarus Verilog 12 and Yosys 0.33 are enough for steps 1 to 3; step 4 also needs Verilator 5.052 and pyslang (see [README, Setup](../../README.md#setup)).

| Step | Command | Pass when | Output |
|---|---|---|---|
| 1. Core test | `make -f Makefile.NPU sim` | a `TEST PASSED` line, no `ERROR` | console |
| 2. Core synthesis | `make -f Makefile.NPU syn` | Yosys ends without `ERROR`; `stat` prints the cell count | `work/NPU_top.json` |
| 3. APB wrapper test + synthesis | `make -f Makefile.NPU apb` | `TEST PASSED: NPU_apb`, then Yosys without `ERROR` | console, `work/NPU_apb.json` |
| 4. Coverage (core, wrapper) | `bash scripts/cov/run_cov.sh NPU`<br>`bash scripts/cov/run_cov.sh NPU_apb` | `RESULT: CLOSED` (all five metrics 100%) | `work/cov/NPU/score.json`, `work/cov/NPU_apb/score.json` |

Expected end of a step 4 run:

```
===== NPU =====
TEST: PASSED   SVA_FAILURES: 0
LINE ... TOGGLE ... FSM ... SVA ... FUNCTIONAL  (each n/n, 100.0%)
RESULT: CLOSED
```

**Core test** (`tb/NPU_tb.sv`): drives `NPU_top` through its own ports against a protocol peer or model and checks every result itself; any mismatch prints `ERROR`, and `TEST PASSED` is printed only when there were none.

**APB wrapper test** (`tb/NPU_apb_tb.sv`), in this order:

1. Reset values of every register, ID included.
2. Writes to read-only registers are ignored.
3. Each RW register: all ones, all zeros, then 16 random writes with every PSTRB byte-lane pattern, read back each time.
4. Unmapped and misaligned addresses, reads and writes: PSLVERR, read data 0, no side effect on other registers.
5. Back-to-back transfers with no idle cycle.
6. IP traffic through the registers only (`tb/apb/NPU_apb_func.svh`): the programming sequence above, every interrupt bit set, enabled and cleared (100% wrapper toggle coverage confirms each bit moved).
7. PRESETN asserted mid-run: `irq` and PRDATA go to 0, registers return to reset values.

**Checkers** (`tb/cov/NPU_sva.sv`, `tb/cov/NPU_apb_sva.sv`): SVA protocol and APB assertions plus covergroups, bound in by the coverage flow. An assertion failure prints `SVA_FAIL` and fails the run even when the test itself passed.

Whole portfolio: `bash scripts/ci_regression.sh` runs steps 1 to 3 for every IP (what CI runs), and `bash scripts/cov/run_all.sh 4` runs step 4 for every IP.

## Verification

Five-metric coverage with Verilator 5.052 (`scripts/cov/run_cov.sh`); see [COVERAGE_CLOSURE.md](../COVERAGE_CLOSURE.md) for the flow. Line and toggle count only the named RTL file.

| Scope | Test | Line | Toggle | FSM | SVA | Functional |
|---|---|---|---|---|---|---|
| core `rtl/NPU_top.sv` | not run | | | | | |
| wrapper `rtl/NPU_apb.sv` | pass | 39/39 | 1386/1446 (+54 excl.) | n/a | 18/18 | 46/46 |
