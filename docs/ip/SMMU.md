# SMMU / IOMMU: 4 KB page translation with a 4-entry TLB, hardware table walk and fault reporting between AXI4 ports

Protocol IP `SMMU`, version 1.0. Apache-2.0.

| Item | Value |
|---|---|
| Core | `SMMU_top` (`rtl/SMMU_top.sv`) |
| Register interface | APB4 slave `SMMU_apb`, 32-bit data, 12-bit byte address, zero wait states |
| Clock, reset | PCLK (rising edge), PRESETN (active low, asynchronous) |
| ID register | 0x5C0A0100 (code 0x5C0A, version 1.0) |
| Registers | 12 words, 0x000 to 0x02C |
| Interrupts | 1 sources into one level-high `irq` |
| Protocol pins | 62 pass-through |

## Overview

SMMU: IOMMU / system MMU of the phone SoC, placed between a multimedia master and the interconnect (AXI4 subordinate in, AXI4 manager out, APB4 registers) Translates the 32-bit virtual address of every burst from the upstream master (s_*) into a physical address on the downstream port (m_*), with 4 KB pages and a single-level page table in memory.

- Page table: PT_BASE + 4 * VA[31:12] holds the entry of a page:
bit 0 VALID, bit 1 WRITABLE, bits 31:12 the physical page number;
PA = {PTE[31:12], VA[11:0]}. Bursts never cross 4 KB, so one
translation covers a whole burst.
- TLB: 4 fully associative entries, filled in round-robin order by the
hardware table walker (a single-beat read on m_*, ID = PTW_ID). Writing
CMD.tlb_inv empties it (do this after changing the table).
- A burst whose page is not VALID, whose walk read got an error response,
or that writes a page that is not WRITABLE, is not forwarded: it ends with
SLVERR on the upstream port (all W beats are taken first), FAULT_ADDR
records its virtual address, FAULT_INFO {walk_err, write, not_writable,
not_valid} the cause, and the FAULT interrupt is set.
- ENABLE 0: bypass, PA = VA, no walks and no faults.
- One burst is handled at a time; reads and writes alternate when both
wait. HITS and MISSES count TLB lookups (saturating).

Features:

- s_* is the AXI4 subordinate port of the upstream master, m_* the AXI4 manager port downstream; both pass through unchanged.
- PTE at PT_BASE + 4 * VA[31:12]: bit 0 VALID, bit 1 WRITABLE, bits 31:12 PPN; PA = {PPN, VA[11:0]}. Walks are single-beat reads with ID 15 (AxPROT 3'b010).
- 4-entry fully associative TLB, round-robin fill; CMD.tlb_inv empties it.
- Fault (not VALID, walk error response, write to a page that is not WRITABLE): the burst is not forwarded and ends with SLVERR upstream (all W beats taken first); FAULT_ADDR = VA, FAULT_INFO = {walk_err, write, not_writable, not_valid}.
- CTRL.enable 0: bypass (PA = VA). One burst at a time; reads and writes alternate when both wait.

m_* is the AXI4 manager port (32-bit address and data, 4-bit ID, no user / QoS); it passes through unchanged. Bursts are INCR, AxSIZE = 2 (4 bytes), 1 to 16 beats, WSTRB = 4'hF, never across a 4 KB boundary; one read and one write burst are outstanding at a time. A read burst is issued only when its data has room, a write burst only when all its data is ready.

## Files

| File | Content |
|---|---|
| `rtl/SMMU_top.sv` | protocol core |
| `rtl/SMMU_apb.sv` | APB4 register wrapper (generated) |
| `tb/SMMU_tb.sv` | core testbench |
| `tb/SMMU_apb_tb.sv`, `tb/apb/SMMU_apb_func.svh` | wrapper testbench (generated part + IP-specific part) |
| `tb/cov/SMMU_sva.sv`, `tb/cov/SMMU_apb_sva.sv` | coverage checkers (core, wrapper) |
| `scripts/apb/specs/SMMU.json` | register spec the wrapper, TB, checker and this page are generated from |

How to run the tests and the coverage flow: see [Running and verifying](#running-and-verifying).

## Parameters

`SMMU_apb` has the core's parameters and passes them to `SMMU_top` unchanged.

| Parameter | Type | Default |
|---|---|---|
| `PTW_ID` | logic [3:0] | `4'hF` |

## Wrapper pins

Pins of `SMMU_apb`. Widths of the pass-through pins are at the default parameters.

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
| `s_awprot` | input | 3 | protocol pin, core port `s_awprot` |
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
| `s_arprot` | input | 3 | protocol pin, core port `s_arprot` |
| `s_arvalid` | input | 1 | protocol pin, core port `s_arvalid` |
| `s_arready` | output | 1 | protocol pin, core port `s_arready` |
| `s_rid` | output | 4 | protocol pin, core port `s_rid` |
| `s_rdata` | output | 32 | protocol pin, core port `s_rdata` |
| `s_rresp` | output | 2 | protocol pin, core port `s_rresp` |
| `s_rlast` | output | 1 | protocol pin, core port `s_rlast` |
| `s_rvalid` | output | 1 | protocol pin, core port `s_rvalid` |
| `s_rready` | input | 1 | protocol pin, core port `s_rready` |
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
| `enable` | input | 1 | CTRL |
| `pt_base` | input | 32 | PT_BASE[31:0] |
| `tlb_inv` | input | 1 | CMD |
| `fault_addr` | output | 32 | FAULT_ADDR[31:0] |
| `fault_info` | output | 4 | FAULT_INFO[3:0] |
| `hits` | output | 16 | TLB_STATS[15:0] |
| `misses` | output | 16 | TLB_STATS[31:16] |
| `busy` | output | 1 | STATUS |
| `fault` | output | 1 | IRQ_STATUS.FAULT |
| `s_awid` | input | 4 | pin (pass-through) |
| `s_awaddr` | input | 32 | pin (pass-through) |
| `s_awlen` | input | 8 | pin (pass-through) |
| `s_awsize` | input | 3 | pin (pass-through) |
| `s_awburst` | input | 2 | pin (pass-through) |
| `s_awprot` | input | 3 | pin (pass-through) |
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
| `s_arprot` | input | 3 | pin (pass-through) |
| `s_arvalid` | input | 1 | pin (pass-through) |
| `s_arready` | output | 1 | pin (pass-through) |
| `s_rid` | output | 4 | pin (pass-through) |
| `s_rdata` | output | 32 | pin (pass-through) |
| `s_rresp` | output | 2 | pin (pass-through) |
| `s_rlast` | output | 1 | pin (pass-through) |
| `s_rvalid` | output | 1 | pin (pass-through) |
| `s_rready` | input | 1 | pin (pass-through) |
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

`SMMU_apb` is an APB4 slave (AMBA APB protocol v2.0): zero wait states, 32-bit data, 12-bit byte address, PSTRB byte lanes on every writable register, PSLVERR on an unmapped or misaligned address (reads then return 0, writes are dropped). Writes to read-only registers are ignored without an error. The core runs on PCLK and PRESETN. `irq` is level-high: `|(IRQ_STATUS & IRQ_ENABLE)`.

Pass-through pins: `s_awid`, `s_awaddr`, `s_awlen`, `s_awsize`, `s_awburst`, `s_awprot`, `s_awvalid`, `s_awready`, `s_wdata`, `s_wstrb`, `s_wlast`, `s_wvalid`, `s_wready`, `s_bid`, `s_bresp`, `s_bvalid`, `s_bready`, `s_arid`, `s_araddr`, `s_arlen`, `s_arsize`, `s_arburst`, `s_arprot`, `s_arvalid`, `s_arready`, `s_rid`, `s_rdata`, `s_rresp`, `s_rlast`, `s_rvalid`, `s_rready`, `m_awid`, `m_awaddr`, `m_awlen`, `m_awsize`, `m_awburst`, `m_awprot`, `m_awvalid`, `m_awready`, `m_wdata`, `m_wstrb`, `m_wlast`, `m_wvalid`, `m_wready`, `m_bid`, `m_bresp`, `m_bvalid`, `m_bready`, `m_arid`, `m_araddr`, `m_arlen`, `m_arsize`, `m_arburst`, `m_arprot`, `m_arvalid`, `m_arready`, `m_rid`, `m_rdata`, `m_rresp`, `m_rlast`, `m_rvalid`, `m_rready`.

### Register map

| Offset | Name | Access | Reset | Description |
|---|---|---|---|---|
| 0x000 | ID | RO | 0x5C0A0100 | IP identification: code, major and minor version |
| 0x004 | IRQ_STATUS | W1C | 0x00000000 | Sticky interrupt bits, write 1 to clear |
| 0x008 | IRQ_ENABLE | RW | 0x00000000 | Interrupt enables; irq = \|(IRQ_STATUS & IRQ_ENABLE) |
| 0x00C | FLAGS | RO | 0x00000000 | Stream holding-register state |
| 0x010 | SCRATCH | RW | 0x00000000 | Scratch register, no effect on the core |
| 0x014 | CTRL | RW | 0x00000000 | Translation control |
| 0x018 | PT_BASE | RW | 0x00000000 | Page table base |
| 0x01C | CMD | WO (pulse) | 0x00000000 | Commands (write 1) |
| 0x020 | STATUS | RO | core | State |
| 0x024 | FAULT_ADDR | RO | core | Last fault |
| 0x028 | FAULT_INFO | RO | core | Last fault cause |
| 0x02C | TLB_STATS | RO | core | TLB counters (saturating) |

Unlisted bits read 0 and ignore writes. Reset "core": the register reads the core's outputs directly, so after reset it shows the core's own reset state. WO (pulse) registers read 0. Offsets from 0x030 up to 0xFFC are unmapped (PSLVERR).

### Fields

| Register | Bits | Field | Access | Reset | Description |
|---|---|---|---|---|---|
| ID | 31:16 | CODE | RO | 0x5C0A | IP code |
| ID | 15:8 | MAJOR | RO | 0x01 | major version |
| ID | 7:0 | MINOR | RO | 0x00 | minor version |
| IRQ_STATUS | 0 | one bit per interrupt | W1C | 0x0 | see Interrupts |
| IRQ_ENABLE | 0 | one bit per interrupt | RW | 0x0 | 1 enables the IRQ_STATUS bit onto `irq` |
| SCRATCH | 31:0 | SCRATCH | RW | 0x00000000 | free for software |
| CTRL | 0 | `enable` | RW | 0x0 | 1: translate, 0: bypass |
| PT_BASE | 31:0 | `pt_base` | RW | 0x0 | byte address of the PTE of page 0 |
| CMD | 0 | `tlb_inv` | WO (pulse) | 0x0 | invalidate every TLB entry |
| STATUS | 0 | `busy` | RO | core | a burst is in progress |
| FAULT_ADDR | 31:0 | `fault_addr` | RO | core | virtual address of the last faulting burst |
| FAULT_INFO | 3:0 | `fault_info` | RO | core | {walk_err, write, not_writable, not_valid} |
| TLB_STATS | 15:0 | `hits` | RO | core | lookups that hit |
| TLB_STATS | 31:16 | `misses` | RO | core | lookups that walked |

### Interrupts (IRQ_STATUS, IRQ_ENABLE)

A bit is set while its source is active, stays set until written with 1, and a set in the same clock as the clear wins.

| Bit | Name | Set when |
|---|---|---|
| 0 | FAULT | a burst faulted |

## Programming sequence

1. Release PRESETN. Read ID (0x000) and check it is 0x5C0A0100.
2. Write 0x1 to IRQ_STATUS (0x004) to clear any stale bits.
3. Configure the core: write CTRL (0x014), PT_BASE (0x018). Reset values are in the register map; PSTRB selects the bytes written.
4. Write IRQ_ENABLE (0x008) with the interrupts to use (bit order as in the Interrupts table; 0x1 enables all).
5. To issue a command, write 1 to `tlb_inv` (CMD bit 0) at 0x01C; the core sees a one-clock pulse, and the register reads 0.
6. Read STATUS (0x020) for the core's live `busy`; it needs no clearing.
7. Read FAULT_ADDR (0x024) for the core's live `fault_addr`; it needs no clearing.
8. Read FAULT_INFO (0x028) for the core's live `fault_info`; it needs no clearing.
9. Read TLB_STATS (0x02C) for the core's live `hits`, `misses`; it needs no clearing.
10. On `irq`: read IRQ_STATUS, handle every bit that is set and enabled, then write those bits back to IRQ_STATUS to clear them. A source that is still active sets its bit again.

IP-specific use:

1. Build the page table in memory, write PT_BASE, write CMD.tlb_inv = 1.
2. Write IRQ_ENABLE.FAULT = 1 and CTRL.enable = 1.
3. On a FAULT interrupt read FAULT_ADDR and FAULT_INFO, fix the table, write CMD.tlb_inv and clear IRQ_STATUS.

## Running and verifying

All commands run from the repository root. Icarus Verilog 12 and Yosys 0.33 are enough for steps 1 to 3; step 4 also needs Verilator 5.052 and pyslang (see [README, Setup](../../README.md#setup)).

| Step | Command | Pass when | Output |
|---|---|---|---|
| 1. Core test | `make -f Makefile.SMMU sim` | a `TEST PASSED` line, no `ERROR` | console |
| 2. Core synthesis | `make -f Makefile.SMMU syn` | Yosys ends without `ERROR`; `stat` prints the cell count | `work/SMMU_top.json` |
| 3. APB wrapper test + synthesis | `make -f Makefile.SMMU apb` | `TEST PASSED: SMMU_apb`, then Yosys without `ERROR` | console, `work/SMMU_apb.json` |
| 4. Coverage (core, wrapper) | `bash scripts/cov/run_cov.sh SMMU`<br>`bash scripts/cov/run_cov.sh SMMU_apb` | `RESULT: CLOSED` (all five metrics 100%) | `work/cov/SMMU/score.json`, `work/cov/SMMU_apb/score.json` |

Expected end of a step 4 run:

```
===== SMMU =====
TEST: PASSED   SVA_FAILURES: 0
LINE ... TOGGLE ... FSM ... SVA ... FUNCTIONAL  (each n/n, 100.0%)
RESULT: CLOSED
```

**Core test** (`tb/SMMU_tb.sv`): drives `SMMU_top` through its own ports against a protocol peer or model and checks every result itself; any mismatch prints `ERROR`, and `TEST PASSED` is printed only when there were none.

**APB wrapper test** (`tb/SMMU_apb_tb.sv`), in this order:

1. Reset values of every register, ID included.
2. Writes to read-only registers are ignored.
3. Each RW register: all ones, all zeros, then 16 random writes with every PSTRB byte-lane pattern, read back each time.
4. Unmapped and misaligned addresses, reads and writes: PSLVERR, read data 0, no side effect on other registers.
5. Back-to-back transfers with no idle cycle.
6. IP traffic through the registers only (`tb/apb/SMMU_apb_func.svh`): the programming sequence above, every interrupt bit set, enabled and cleared (100% wrapper toggle coverage confirms each bit moved).
7. PRESETN asserted mid-run: `irq` and PRDATA go to 0, registers return to reset values.

**Checkers** (`tb/cov/SMMU_sva.sv`, `tb/cov/SMMU_apb_sva.sv`): SVA protocol and APB assertions plus covergroups, bound in by the coverage flow. An assertion failure prints `SVA_FAIL` and fails the run even when the test itself passed.

Whole portfolio: `bash scripts/ci_regression.sh` runs steps 1 to 3 for every IP (what CI runs), and `bash scripts/cov/run_all.sh 4` runs step 4 for every IP.

## Verification

Five-metric coverage with Verilator 5.052 (`scripts/cov/run_cov.sh`); see [COVERAGE_CLOSURE.md](../COVERAGE_CLOSURE.md) for the flow. Line and toggle count only the named RTL file.

| Scope | Test | Line | Toggle | FSM | SVA | Functional |
|---|---|---|---|---|---|---|
| core `rtl/SMMU_top.sv` | not run | | | | | |
| wrapper `rtl/SMMU_apb.sv` | not run | | | | | |
