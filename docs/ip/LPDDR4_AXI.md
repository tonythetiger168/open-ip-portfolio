# LPDDR4 memory controller with an AXI4 subordinate port: INCR / FIXED / WRAP bursts, narrow transfers, byte strobes by read-modify-write

Protocol IP `LPDDR4_AXI`, version 1.0. Apache-2.0.

| Item | Value |
|---|---|
| Core | `LPDDR4_AXI_top` (`rtl/LPDDR4_AXI_top.sv`) |
| Register interface | APB4 slave `LPDDR4_AXI_apb`, 32-bit data, 12-bit byte address, zero wait states |
| Clock, reset | PCLK (rising edge), PRESETN (active low, asynchronous) |
| ID register | 0x5D140100 (code 0x5D14, version 1.0) |
| Registers | 9 words, 0x000 to 0x020 |
| Interrupts | 1 sources into one level-high `irq` |
| Protocol pins | 39 pass-through |

## Overview

LPDDR4_AXI: LPDDR4_top memory controller with an AXI4 subordinate port The unchanged LPDDR4_top core behind ddr_axi_slv (see that file for the AXI rules: INCR / FIXED / WRAP, AxSIZE 0..2, WSTRB read-modify-write, SLVERR on AxSIZE > 2 or a misplaced WLAST, one transaction at a time). LPDDR4_top keeps 256 16-bit columns per channel (NCH = 2: halfword h maps onto channel h[8], column h[7:0]). A write to column 0xF0 is the core's MR7 frequency-set write (bit 0 of the halfword: 0 set A, 1 set B); it does not change the array.

The AXI4 subordinate port (s_*) and the DRAM pins pass through the wrapper unchanged; the registers only read the front end's counters.
Halfword h = addr[31:1] reaches the core as haddr = {h[24:11], 7'b0, h[10:0]}: channel h[8], column h[7:0], bank h[10:9], row h[24:11]. The core keeps 256 columns of 16 bits, so the AXI space aliases above 1 KB. A write to column 0xF0 is the core's MR7 frequency-set write and leaves the array unchanged.

## Files

| File | Content |
|---|---|
| `rtl/LPDDR4_AXI_top.sv` | protocol core |
| `rtl/LPDDR4_AXI_apb.sv` | APB4 register wrapper (generated) |
| `tb/LPDDR4_AXI_tb.sv` | core testbench |
| `tb/LPDDR4_AXI_apb_tb.sv`, `tb/apb/LPDDR4_AXI_apb_func.svh` | wrapper testbench (generated part + IP-specific part) |
| `tb/cov/LPDDR4_AXI_sva.sv`, `tb/cov/LPDDR4_AXI_apb_sva.sv` | coverage checkers (core, wrapper) |
| `scripts/apb/specs/LPDDR4_AXI.json` | register spec the wrapper, TB, checker and this page are generated from |

How to run the tests and the coverage flow: see [Running and verifying](#running-and-verifying).

## Parameters

`LPDDR4_AXI_apb` has the core's parameters and passes them to `LPDDR4_AXI_top` unchanged.

| Parameter | Type | Default |
|---|---|---|
| `NCH` | int | `2` |

## Wrapper pins

Pins of `LPDDR4_AXI_apb`. Widths of the pass-through pins are at the default parameters.

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
| `s_awid` | input | 4 | protocol pin, core port `s_awid` |
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
| `s_bid` | output | 4 | protocol pin, core port `s_bid` |
| `s_bresp` | output | 2 | protocol pin, core port `s_bresp` |
| `s_bvalid` | output | 1 | protocol pin, core port `s_bvalid` |
| `s_bready` | input | 1 | protocol pin, core port `s_bready` |
| `s_arid` | input | 4 | protocol pin, core port `s_arid` |
| `s_araddr` | input | 32 | protocol pin, core port `s_araddr` |
| `s_arlen` | input | 8 | protocol pin, core port `s_arlen` |
| `s_arsize` | input | 3 | protocol pin, core port `s_arsize` |
| `s_arburst` | input | 2 | protocol pin, core port `s_arburst` |
| `s_arvalid` | input | 1 | protocol pin, core port `s_arvalid` |
| `s_arready` | output | 1 | protocol pin, core port `s_arready` |
| `s_rid` | output | 4 | protocol pin, core port `s_rid` |
| `s_rdata` | output | 32 | protocol pin, core port `s_rdata` |
| `s_rresp` | output | 2 | protocol pin, core port `s_rresp` |
| `s_rlast` | output | 1 | protocol pin, core port `s_rlast` |
| `s_rvalid` | output | 1 | protocol pin, core port `s_rvalid` |
| `s_rready` | input | 1 | protocol pin, core port `s_rready` |
| `ck_t` | output | 1 | protocol pin, core port `ck_t` |
| `ck_c` | output | 1 | protocol pin, core port `ck_c` |
| `ca` | output | 6 | protocol pin, core port `ca` |
| `cs_n` | output | 1 | protocol pin, core port `cs_n` |
| `dq` | inout | 32 | protocol pin, core port `dq` |
| `dqs` | inout | 2 | protocol pin, core port `dqs` |
| `cke` | output | 1 | protocol pin, core port `cke` |
| `trace_valid` | output | 1 | protocol pin, core port `trace_valid` |
| `trace_cmd` | output | 3 | protocol pin, core port `trace_cmd` |
| `trace_addr` | output | 32 | protocol pin, core port `trace_addr` |

## Core ports

| Port | Dir | Width | In the APB wrapper |
|---|---|---|---|
| `clk` | input | 1 | PCLK |
| `rst_n` | input | 1 | PRESETN |
| `s_awid` | input | 4 | pin (pass-through) |
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
| `s_bid` | output | 4 | pin (pass-through) |
| `s_bresp` | output | 2 | pin (pass-through) |
| `s_bvalid` | output | 1 | pin (pass-through) |
| `s_bready` | input | 1 | pin (pass-through) |
| `s_arid` | input | 4 | pin (pass-through) |
| `s_araddr` | input | 32 | pin (pass-through) |
| `s_arlen` | input | 8 | pin (pass-through) |
| `s_arsize` | input | 3 | pin (pass-through) |
| `s_arburst` | input | 2 | pin (pass-through) |
| `s_arvalid` | input | 1 | pin (pass-through) |
| `s_arready` | output | 1 | pin (pass-through) |
| `s_rid` | output | 4 | pin (pass-through) |
| `s_rdata` | output | 32 | pin (pass-through) |
| `s_rresp` | output | 2 | pin (pass-through) |
| `s_rlast` | output | 1 | pin (pass-through) |
| `s_rvalid` | output | 1 | pin (pass-through) |
| `s_rready` | input | 1 | pin (pass-through) |
| `ck_t` | output | 1 | pin (pass-through) |
| `ck_c` | output | 1 | pin (pass-through) |
| `ca` | output | 6 | pin (pass-through) |
| `cs_n` | output | 1 | pin (pass-through) |
| `dq` | inout | 32 | pin (pass-through) |
| `dqs` | inout | 2 | pin (pass-through) |
| `cke` | output | 1 | pin (pass-through) |
| `trace_valid` | output | 1 | pin (pass-through) |
| `trace_cmd` | output | 3 | pin (pass-through) |
| `trace_addr` | output | 32 | pin (pass-through) |
| `n_rd` | output | 16 | N_RD[15:0] |
| `n_wr` | output | 16 | N_WR[15:0] |
| `n_rmw` | output | 16 | N_RMW[15:0] |
| `n_err` | output | 16 | N_ERR[15:0] |
| `err_irq` | output | 1 | IRQ_STATUS.ERR |

## APB wrapper

`LPDDR4_AXI_apb` is an APB4 slave (AMBA APB protocol v2.0): zero wait states, 32-bit data, 12-bit byte address, PSTRB byte lanes on every writable register, PSLVERR on an unmapped or misaligned address (reads then return 0, writes are dropped). Writes to read-only registers are ignored without an error. The core runs on PCLK and PRESETN. `irq` is level-high: `|(IRQ_STATUS & IRQ_ENABLE)`.

Pass-through pins: `s_awid`, `s_awaddr`, `s_awlen`, `s_awsize`, `s_awburst`, `s_awvalid`, `s_awready`, `s_wdata`, `s_wstrb`, `s_wlast`, `s_wvalid`, `s_wready`, `s_bid`, `s_bresp`, `s_bvalid`, `s_bready`, `s_arid`, `s_araddr`, `s_arlen`, `s_arsize`, `s_arburst`, `s_arvalid`, `s_arready`, `s_rid`, `s_rdata`, `s_rresp`, `s_rlast`, `s_rvalid`, `s_rready`, `ck_t`, `ck_c`, `ca`, `cs_n`, `dq`, `dqs`, `cke`, `trace_valid`, `trace_cmd`, `trace_addr`.

### Register map

| Offset | Name | Access | Reset | Description |
|---|---|---|---|---|
| 0x000 | ID | RO | 0x5D140100 | IP identification: code, major and minor version |
| 0x004 | IRQ_STATUS | W1C | 0x00000000 | Sticky interrupt bits, write 1 to clear |
| 0x008 | IRQ_ENABLE | RW | 0x00000000 | Interrupt enables; irq = \|(IRQ_STATUS & IRQ_ENABLE) |
| 0x00C | FLAGS | RO | 0x00000000 | Stream holding-register state |
| 0x010 | SCRATCH | RW | 0x00000000 | Scratch register, no effect on the core |
| 0x014 | N_RD | RO | core | AXI read bursts completed |
| 0x018 | N_WR | RO | core | AXI write bursts completed (B sent) |
| 0x01C | N_RMW | RO | core | Halfword read-modify-writes (one byte strobe of two) |
| 0x020 | N_ERR | RO | core | SLVERR responses (AxSIZE above 2, misplaced WLAST) |

Unlisted bits read 0 and ignore writes. Reset "core": the register reads the core's outputs directly, so after reset it shows the core's own reset state. WO (pulse) registers read 0. Offsets from 0x024 up to 0xFFC are unmapped (PSLVERR).

### Fields

| Register | Bits | Field | Access | Reset | Description |
|---|---|---|---|---|---|
| ID | 31:16 | CODE | RO | 0x5D14 | IP code |
| ID | 15:8 | MAJOR | RO | 0x01 | major version |
| ID | 7:0 | MINOR | RO | 0x00 | minor version |
| IRQ_STATUS | 0 | one bit per interrupt | W1C | 0x0 | see Interrupts |
| IRQ_ENABLE | 0 | one bit per interrupt | RW | 0x0 | 1 enables the IRQ_STATUS bit onto `irq` |
| SCRATCH | 31:0 | SCRATCH | RW | 0x00000000 | free for software |
| N_RD | 15:0 | `n_rd` | RO | core | wraps at 0xFFFF |
| N_WR | 15:0 | `n_wr` | RO | core | wraps at 0xFFFF |
| N_RMW | 15:0 | `n_rmw` | RO | core | wraps at 0xFFFF |
| N_ERR | 15:0 | `n_err` | RO | core | wraps at 0xFFFF |

### Interrupts (IRQ_STATUS, IRQ_ENABLE)

A bit is set while its source is active, stays set until written with 1, and a set in the same clock as the clear wins.

| Bit | Name | Set when |
|---|---|---|
| 0 | ERR | an AXI burst ended with SLVERR |

## Programming sequence

1. Release PRESETN. Read ID (0x000) and check it is 0x5D140100.
2. Write 0x1 to IRQ_STATUS (0x004) to clear any stale bits.
3. Write IRQ_ENABLE (0x008) with the interrupts to use (bit order as in the Interrupts table; 0x1 enables all).
4. Read N_RD (0x014) for the core's live `n_rd`; it needs no clearing.
5. Read N_WR (0x018) for the core's live `n_wr`; it needs no clearing.
6. Read N_RMW (0x01C) for the core's live `n_rmw`; it needs no clearing.
7. Read N_ERR (0x020) for the core's live `n_err`; it needs no clearing.
8. On `irq`: read IRQ_STATUS, handle every bit that is set and enabled, then write those bits back to IRQ_STATUS to clear them. A source that is still active sets its bit again.

## Running and verifying

All commands run from the repository root. Icarus Verilog 12 and Yosys 0.33 are enough for steps 1 to 3; step 4 also needs Verilator 5.052 and pyslang (see [README, Setup](../../README.md#setup)).

| Step | Command | Pass when | Output |
|---|---|---|---|
| 1. Core test | `make -f Makefile.LPDDR4_AXI sim` | a `TEST PASSED` line, no `ERROR` | console |
| 2. Core synthesis | `make -f Makefile.LPDDR4_AXI syn` | Yosys ends without `ERROR`; `stat` prints the cell count | `work/LPDDR4_AXI_top.json` |
| 3. APB wrapper test + synthesis | `make -f Makefile.LPDDR4_AXI apb` | `TEST PASSED: LPDDR4_AXI_apb`, then Yosys without `ERROR` | console, `work/LPDDR4_AXI_apb.json` |
| 4. Coverage (core, wrapper) | `bash scripts/cov/run_cov.sh LPDDR4_AXI`<br>`bash scripts/cov/run_cov.sh LPDDR4_AXI_apb` | `RESULT: CLOSED` (all five metrics 100%) | `work/cov/LPDDR4_AXI/score.json`, `work/cov/LPDDR4_AXI_apb/score.json` |

Expected end of a step 4 run:

```
===== LPDDR4_AXI =====
TEST: PASSED   SVA_FAILURES: 0
LINE ... TOGGLE ... FSM ... SVA ... FUNCTIONAL  (each n/n, 100.0%)
RESULT: CLOSED
```

**Core test** (`tb/LPDDR4_AXI_tb.sv`): drives `LPDDR4_AXI_top` through its own ports against a protocol peer or model and checks every result itself; any mismatch prints `ERROR`, and `TEST PASSED` is printed only when there were none.

**APB wrapper test** (`tb/LPDDR4_AXI_apb_tb.sv`), in this order:

1. Reset values of every register, ID included.
2. Writes to read-only registers are ignored.
3. Each RW register: all ones, all zeros, then 16 random writes with every PSTRB byte-lane pattern, read back each time.
4. Unmapped and misaligned addresses, reads and writes: PSLVERR, read data 0, no side effect on other registers.
5. Back-to-back transfers with no idle cycle.
6. IP traffic through the registers only (`tb/apb/LPDDR4_AXI_apb_func.svh`): the programming sequence above, every interrupt bit set, enabled and cleared (100% wrapper toggle coverage confirms each bit moved).
7. PRESETN asserted mid-run: `irq` and PRDATA go to 0, registers return to reset values.

**Checkers** (`tb/cov/LPDDR4_AXI_sva.sv`, `tb/cov/LPDDR4_AXI_apb_sva.sv`): SVA protocol and APB assertions plus covergroups, bound in by the coverage flow. An assertion failure prints `SVA_FAIL` and fails the run even when the test itself passed.

Whole portfolio: `bash scripts/ci_regression.sh` runs steps 1 to 3 for every IP (what CI runs), and `bash scripts/cov/run_all.sh 4` runs step 4 for every IP.

## Verification

Five-metric coverage with Verilator 5.052 (`scripts/cov/run_cov.sh`); see [COVERAGE_CLOSURE.md](../COVERAGE_CLOSURE.md) for the flow. Line and toggle count only the named RTL file.

| Scope | Test | Line | Toggle | FSM | SVA | Functional |
|---|---|---|---|---|---|---|
| core `rtl/LPDDR4_AXI_top.sv` | not run | | | | | |
| wrapper `rtl/LPDDR4_AXI_apb.sv` | pass | 23/23 | 1068/1068 (+24 excl.) | n/a | 7/7 | 31/31 |
