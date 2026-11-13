# AXI4 clock-domain crossing bridge: one gray-pointer asynchronous FIFO per channel, any clock ratio

Protocol IP `AXI_Async_Bridge`, version 1.0. Apache-2.0.

| Item | Value |
|---|---|
| Core | `AXI_Async_Bridge_top` (`rtl/AXI_Async_Bridge_top.sv`) |
| Register interface | APB4 slave `AXI_Async_Bridge_apb`, 32-bit data, 12-bit byte address, zero wait states |
| Clock, reset | PCLK (rising edge), PRESETN (active low, asynchronous) |
| ID register | 0x41AB0100 (code 0x41AB, version 1.0) |
| Registers | 5 words, 0x000 to 0x010 |
| Interrupts | 1 sources into one level-high `irq` |
| Protocol pins | 60 pass-through |

## Overview

AXI_Async_Bridge_top: AXI4 clock-domain crossing

- Subordinate port s_* on s_clk, manager port m_* on m_clk; the two clocks
are unrelated (any ratio).
- One axi_async_fifo per channel: AW, W and AR from s to m, B and R from
m to s, each DEPTH entries (a power of two, at least 4). Channels are
independent, so the bridge keeps AXI ordering per channel and adds no
ordering of its own. Latency: two to three clocks of the receiving side
after a beat is written.
- 32-bit data, IDW-bit IDs; the AXI4 signals the SoC fabric uses (no
QoS, region, cache, prot, lock or user). A pure pipe: no response is
generated or changed.
- RESP_ERR (s_clk) pulses for one clock after a B or R beat with SLVERR or
DECERR is handed to the s side (an error interrupt for the APB wrapper).
- Reset both sides together (s_rst_n and m_rst_n).

The bridge has no registers of its own: the wrapper adds the common ID, IRQ, FLAGS and SCRATCH words on the s_clk side, the RESP_ERR interrupt flags error responses, and every AXI4 pin of both ports (s_* on s_clk = PCLK, m_* on m_clk) passes through unchanged. m_clk and m_rst_n are wrapper pins; reset both sides together.
Clock-domain crossing: each channel is an axi_async_fifo (rtl/axi_async_fifo.sv) with binary and gray pointers and two-flop synchronizers. RTL simulation cannot see metastability; the two-flop structure is a design rule, not something the tests can prove.

## Files

| File | Content |
|---|---|
| `rtl/AXI_Async_Bridge_top.sv` | protocol core |
| `rtl/AXI_Async_Bridge_apb.sv` | APB4 register wrapper (generated) |
| `tb/AXI_Async_Bridge_tb.sv` | core testbench |
| `tb/AXI_Async_Bridge_apb_tb.sv`, `tb/apb/AXI_Async_Bridge_apb_func.svh` | wrapper testbench (generated part + IP-specific part) |
| `tb/cov/AXI_Async_Bridge_sva.sv`, `tb/cov/AXI_Async_Bridge_apb_sva.sv` | coverage checkers (core, wrapper) |
| `scripts/apb/specs/AXI_Async_Bridge.json` | register spec the wrapper, TB, checker and this page are generated from |

How to run the tests and the coverage flow: see [Running and verifying](#running-and-verifying).

## Parameters

`AXI_Async_Bridge_apb` has the core's parameters and passes them to `AXI_Async_Bridge_top` unchanged.

| Parameter | Type | Default |
|---|---|---|
| `IDW` | int | `8` |
| `DEPTH` | int | `8` |

## Wrapper pins

Pins of `AXI_Async_Bridge_apb`. Widths of the pass-through pins are at the default parameters.

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
| `s_awid` | input | 8 | protocol pin, core port `s_awid` |
| `s_awaddr` | input | 32 | protocol pin, core port `s_awaddr` |
| `s_awlen` | input | 8 | protocol pin, core port `s_awlen` |
| `s_awsize` | input | 3 | protocol pin, core port `s_awsize` |
| `s_awburst` | input | 2 | protocol pin, core port `s_awburst` |
| `s_awvalid` | input | 1 | protocol pin, core port `s_awvalid` |
| `s_awready` | output | 1 | protocol pin, core port `s_awready` |
| `s_wdata` | input | 32 | protocol pin, core port `s_wdata` |
| `s_wstrb` | input | 4 | protocol pin, core port `s_wstrb` |
| `s_wlast` | input | 1 | protocol pin, core port `s_wlast` |
| `s_wvalid` | input | 1 | protocol pin, core port `s_wvalid` |
| `s_wready` | output | 1 | protocol pin, core port `s_wready` |
| `s_bid` | output | 8 | protocol pin, core port `s_bid` |
| `s_bresp` | output | 2 | protocol pin, core port `s_bresp` |
| `s_bvalid` | output | 1 | protocol pin, core port `s_bvalid` |
| `s_bready` | input | 1 | protocol pin, core port `s_bready` |
| `s_arid` | input | 8 | protocol pin, core port `s_arid` |
| `s_araddr` | input | 32 | protocol pin, core port `s_araddr` |
| `s_arlen` | input | 8 | protocol pin, core port `s_arlen` |
| `s_arsize` | input | 3 | protocol pin, core port `s_arsize` |
| `s_arburst` | input | 2 | protocol pin, core port `s_arburst` |
| `s_arvalid` | input | 1 | protocol pin, core port `s_arvalid` |
| `s_arready` | output | 1 | protocol pin, core port `s_arready` |
| `s_rid` | output | 8 | protocol pin, core port `s_rid` |
| `s_rdata` | output | 32 | protocol pin, core port `s_rdata` |
| `s_rresp` | output | 2 | protocol pin, core port `s_rresp` |
| `s_rlast` | output | 1 | protocol pin, core port `s_rlast` |
| `s_rvalid` | output | 1 | protocol pin, core port `s_rvalid` |
| `s_rready` | input | 1 | protocol pin, core port `s_rready` |
| `m_clk` | input | 1 | protocol pin, core port `m_clk` |
| `m_rst_n` | input | 1 | protocol pin, core port `m_rst_n` |
| `m_awid` | output | 8 | protocol pin, core port `m_awid` |
| `m_awaddr` | output | 32 | protocol pin, core port `m_awaddr` |
| `m_awlen` | output | 8 | protocol pin, core port `m_awlen` |
| `m_awsize` | output | 3 | protocol pin, core port `m_awsize` |
| `m_awburst` | output | 2 | protocol pin, core port `m_awburst` |
| `m_awvalid` | output | 1 | protocol pin, core port `m_awvalid` |
| `m_awready` | input | 1 | protocol pin, core port `m_awready` |
| `m_wdata` | output | 32 | protocol pin, core port `m_wdata` |
| `m_wstrb` | output | 4 | protocol pin, core port `m_wstrb` |
| `m_wlast` | output | 1 | protocol pin, core port `m_wlast` |
| `m_wvalid` | output | 1 | protocol pin, core port `m_wvalid` |
| `m_wready` | input | 1 | protocol pin, core port `m_wready` |
| `m_bid` | input | 8 | protocol pin, core port `m_bid` |
| `m_bresp` | input | 2 | protocol pin, core port `m_bresp` |
| `m_bvalid` | input | 1 | protocol pin, core port `m_bvalid` |
| `m_bready` | output | 1 | protocol pin, core port `m_bready` |
| `m_arid` | output | 8 | protocol pin, core port `m_arid` |
| `m_araddr` | output | 32 | protocol pin, core port `m_araddr` |
| `m_arlen` | output | 8 | protocol pin, core port `m_arlen` |
| `m_arsize` | output | 3 | protocol pin, core port `m_arsize` |
| `m_arburst` | output | 2 | protocol pin, core port `m_arburst` |
| `m_arvalid` | output | 1 | protocol pin, core port `m_arvalid` |
| `m_arready` | input | 1 | protocol pin, core port `m_arready` |
| `m_rid` | input | 8 | protocol pin, core port `m_rid` |
| `m_rdata` | input | 32 | protocol pin, core port `m_rdata` |
| `m_rresp` | input | 2 | protocol pin, core port `m_rresp` |
| `m_rlast` | input | 1 | protocol pin, core port `m_rlast` |
| `m_rvalid` | input | 1 | protocol pin, core port `m_rvalid` |
| `m_rready` | output | 1 | protocol pin, core port `m_rready` |

## Core ports

| Port | Dir | Width | In the APB wrapper |
|---|---|---|---|
| `s_clk` | input | 1 | PCLK |
| `s_rst_n` | input | 1 | PRESETN |
| `s_awid` | input | 8 | pin (pass-through) |
| `s_awaddr` | input | 32 | pin (pass-through) |
| `s_awlen` | input | 8 | pin (pass-through) |
| `s_awsize` | input | 3 | pin (pass-through) |
| `s_awburst` | input | 2 | pin (pass-through) |
| `s_awvalid` | input | 1 | pin (pass-through) |
| `s_awready` | output | 1 | pin (pass-through) |
| `s_wdata` | input | 32 | pin (pass-through) |
| `s_wstrb` | input | 4 | pin (pass-through) |
| `s_wlast` | input | 1 | pin (pass-through) |
| `s_wvalid` | input | 1 | pin (pass-through) |
| `s_wready` | output | 1 | pin (pass-through) |
| `s_bid` | output | 8 | pin (pass-through) |
| `s_bresp` | output | 2 | pin (pass-through) |
| `s_bvalid` | output | 1 | pin (pass-through) |
| `s_bready` | input | 1 | pin (pass-through) |
| `s_arid` | input | 8 | pin (pass-through) |
| `s_araddr` | input | 32 | pin (pass-through) |
| `s_arlen` | input | 8 | pin (pass-through) |
| `s_arsize` | input | 3 | pin (pass-through) |
| `s_arburst` | input | 2 | pin (pass-through) |
| `s_arvalid` | input | 1 | pin (pass-through) |
| `s_arready` | output | 1 | pin (pass-through) |
| `s_rid` | output | 8 | pin (pass-through) |
| `s_rdata` | output | 32 | pin (pass-through) |
| `s_rresp` | output | 2 | pin (pass-through) |
| `s_rlast` | output | 1 | pin (pass-through) |
| `s_rvalid` | output | 1 | pin (pass-through) |
| `s_rready` | input | 1 | pin (pass-through) |
| `m_clk` | input | 1 | pin (pass-through) |
| `m_rst_n` | input | 1 | pin (pass-through) |
| `m_awid` | output | 8 | pin (pass-through) |
| `m_awaddr` | output | 32 | pin (pass-through) |
| `m_awlen` | output | 8 | pin (pass-through) |
| `m_awsize` | output | 3 | pin (pass-through) |
| `m_awburst` | output | 2 | pin (pass-through) |
| `m_awvalid` | output | 1 | pin (pass-through) |
| `m_awready` | input | 1 | pin (pass-through) |
| `m_wdata` | output | 32 | pin (pass-through) |
| `m_wstrb` | output | 4 | pin (pass-through) |
| `m_wlast` | output | 1 | pin (pass-through) |
| `m_wvalid` | output | 1 | pin (pass-through) |
| `m_wready` | input | 1 | pin (pass-through) |
| `m_bid` | input | 8 | pin (pass-through) |
| `m_bresp` | input | 2 | pin (pass-through) |
| `m_bvalid` | input | 1 | pin (pass-through) |
| `m_bready` | output | 1 | pin (pass-through) |
| `m_arid` | output | 8 | pin (pass-through) |
| `m_araddr` | output | 32 | pin (pass-through) |
| `m_arlen` | output | 8 | pin (pass-through) |
| `m_arsize` | output | 3 | pin (pass-through) |
| `m_arburst` | output | 2 | pin (pass-through) |
| `m_arvalid` | output | 1 | pin (pass-through) |
| `m_arready` | input | 1 | pin (pass-through) |
| `m_rid` | input | 8 | pin (pass-through) |
| `m_rdata` | input | 32 | pin (pass-through) |
| `m_rresp` | input | 2 | pin (pass-through) |
| `m_rlast` | input | 1 | pin (pass-through) |
| `m_rvalid` | input | 1 | pin (pass-through) |
| `m_rready` | output | 1 | pin (pass-through) |
| `resp_err` | output | 1 | IRQ_STATUS.RESP_ERR |

## APB wrapper

`AXI_Async_Bridge_apb` is an APB4 slave (AMBA APB protocol v2.0): zero wait states, 32-bit data, 12-bit byte address, PSTRB byte lanes on every writable register, PSLVERR on an unmapped or misaligned address (reads then return 0, writes are dropped). Writes to read-only registers are ignored without an error. The core runs on PCLK and PRESETN. `irq` is level-high: `|(IRQ_STATUS & IRQ_ENABLE)`.

Pass-through pins: `s_awid`, `s_awaddr`, `s_awlen`, `s_awsize`, `s_awburst`, `s_awvalid`, `s_awready`, `s_wdata`, `s_wstrb`, `s_wlast`, `s_wvalid`, `s_wready`, `s_bid`, `s_bresp`, `s_bvalid`, `s_bready`, `s_arid`, `s_araddr`, `s_arlen`, `s_arsize`, `s_arburst`, `s_arvalid`, `s_arready`, `s_rid`, `s_rdata`, `s_rresp`, `s_rlast`, `s_rvalid`, `s_rready`, `m_clk`, `m_rst_n`, `m_awid`, `m_awaddr`, `m_awlen`, `m_awsize`, `m_awburst`, `m_awvalid`, `m_awready`, `m_wdata`, `m_wstrb`, `m_wlast`, `m_wvalid`, `m_wready`, `m_bid`, `m_bresp`, `m_bvalid`, `m_bready`, `m_arid`, `m_araddr`, `m_arlen`, `m_arsize`, `m_arburst`, `m_arvalid`, `m_arready`, `m_rid`, `m_rdata`, `m_rresp`, `m_rlast`, `m_rvalid`, `m_rready`.

### Register map

| Offset | Name | Access | Reset | Description |
|---|---|---|---|---|
| 0x000 | ID | RO | 0x41AB0100 | IP identification: code, major and minor version |
| 0x004 | IRQ_STATUS | W1C | 0x00000000 | Sticky interrupt bits, write 1 to clear |
| 0x008 | IRQ_ENABLE | RW | 0x00000000 | Interrupt enables; irq = \|(IRQ_STATUS & IRQ_ENABLE) |
| 0x00C | FLAGS | RO | 0x00000000 | Stream holding-register state |
| 0x010 | SCRATCH | RW | 0x00000000 | Scratch register, no effect on the core |

Unlisted bits read 0 and ignore writes. Reset "core": the register reads the core's outputs directly, so after reset it shows the core's own reset state. WO (pulse) registers read 0. Offsets from 0x014 up to 0xFFC are unmapped (PSLVERR).

### Fields

| Register | Bits | Field | Access | Reset | Description |
|---|---|---|---|---|---|
| ID | 31:16 | CODE | RO | 0x41AB | IP code |
| ID | 15:8 | MAJOR | RO | 0x01 | major version |
| ID | 7:0 | MINOR | RO | 0x00 | minor version |
| IRQ_STATUS | 0 | one bit per interrupt | W1C | 0x0 | see Interrupts |
| IRQ_ENABLE | 0 | one bit per interrupt | RW | 0x0 | 1 enables the IRQ_STATUS bit onto `irq` |
| SCRATCH | 31:0 | SCRATCH | RW | 0x00000000 | free for software |

### Interrupts (IRQ_STATUS, IRQ_ENABLE)

A bit is set while its source is active, stays set until written with 1, and a set in the same clock as the clear wins.

| Bit | Name | Set when |
|---|---|---|
| 0 | RESP_ERR | a B or R beat with SLVERR or DECERR was handed to the s side |

## Programming sequence

1. Release PRESETN. Read ID (0x000) and check it is 0x41AB0100.
2. Write 0x1 to IRQ_STATUS (0x004) to clear any stale bits.
3. Write IRQ_ENABLE (0x008) with the interrupts to use (bit order as in the Interrupts table; 0x1 enables all).
4. On `irq`: read IRQ_STATUS, handle every bit that is set and enabled, then write those bits back to IRQ_STATUS to clear them. A source that is still active sets its bit again.

## Running and verifying

All commands run from the repository root. Icarus Verilog 12 and Yosys 0.33 are enough for steps 1 to 3; step 4 also needs Verilator 5.052 and pyslang (see [README, Setup](../../README.md#setup)).

| Step | Command | Pass when | Output |
|---|---|---|---|
| 1. Core test | `make -f Makefile.AXI_Async_Bridge sim` | a `TEST PASSED` line, no `ERROR` | console |
| 2. Core synthesis | `make -f Makefile.AXI_Async_Bridge syn` | Yosys ends without `ERROR`; `stat` prints the cell count | `work/AXI_Async_Bridge_top.json` |
| 3. APB wrapper test + synthesis | `make -f Makefile.AXI_Async_Bridge apb` | `TEST PASSED: AXI_Async_Bridge_apb`, then Yosys without `ERROR` | console, `work/AXI_Async_Bridge_apb.json` |
| 4. Coverage (core, wrapper) | `bash scripts/cov/run_cov.sh AXI_Async_Bridge`<br>`bash scripts/cov/run_cov.sh AXI_Async_Bridge_apb` | `RESULT: CLOSED` (all five metrics 100%) | `work/cov/AXI_Async_Bridge/score.json`, `work/cov/AXI_Async_Bridge_apb/score.json` |

Expected end of a step 4 run:

```
===== AXI_Async_Bridge =====
TEST: PASSED   SVA_FAILURES: 0
LINE ... TOGGLE ... FSM ... SVA ... FUNCTIONAL  (each n/n, 100.0%)
RESULT: CLOSED
```

**Core test** (`tb/AXI_Async_Bridge_tb.sv`): drives `AXI_Async_Bridge_top` through its own ports against a protocol peer or model and checks every result itself; any mismatch prints `ERROR`, and `TEST PASSED` is printed only when there were none.

**APB wrapper test** (`tb/AXI_Async_Bridge_apb_tb.sv`), in this order:

1. Reset values of every register, ID included.
2. Writes to read-only registers are ignored.
3. Each RW register: all ones, all zeros, then 16 random writes with every PSTRB byte-lane pattern, read back each time.
4. Unmapped and misaligned addresses, reads and writes: PSLVERR, read data 0, no side effect on other registers.
5. Back-to-back transfers with no idle cycle.
6. IP traffic through the registers only (`tb/apb/AXI_Async_Bridge_apb_func.svh`): the programming sequence above, every interrupt bit set, enabled and cleared (100% wrapper toggle coverage confirms each bit moved).
7. PRESETN asserted mid-run: `irq` and PRDATA go to 0, registers return to reset values.

**Checkers** (`tb/cov/AXI_Async_Bridge_sva.sv`, `tb/cov/AXI_Async_Bridge_apb_sva.sv`): SVA protocol and APB assertions plus covergroups, bound in by the coverage flow. An assertion failure prints `SVA_FAIL` and fails the run even when the test itself passed.

Whole portfolio: `bash scripts/ci_regression.sh` runs steps 1 to 3 for every IP (what CI runs), and `bash scripts/cov/run_all.sh 4` runs step 4 for every IP.

## Verification

Five-metric coverage with Verilator 5.052 (`scripts/cov/run_cov.sh`); see [COVERAGE_CLOSURE.md](../COVERAGE_CLOSURE.md) for the flow. Line and toggle count only the named RTL file.

| Scope | Test | Line | Toggle | FSM | SVA | Functional |
|---|---|---|---|---|---|---|
| core `rtl/AXI_Async_Bridge_top.sv` | pass | 14/14 | 1286/1286 | n/a | 18/18 | 96/96 |
| wrapper `rtl/AXI_Async_Bridge_apb.sv` | pass | 19/19 | 1220/1220 | n/a | 7/7 | 23/23 |

Core TB (tb/AXI_Async_Bridge_tb.sv): every channel driven as a random stream, a scoreboard per channel, phases with s faster, m faster, nearly equal clocks, slow and sparse sides (FIFOs full and empty), and a reset of both sides with full FIFOs.
Checker tb/cov/AXI_Async_Bridge_sva.sv: an order model per channel (each beat out equals the next beat in), no more than DEPTH beats in flight, payload held while READY is low, VALID low in reset; coverage of clock ratios crossed with stalls, full and empty FIFOs, data classes, responses and burst fields.
